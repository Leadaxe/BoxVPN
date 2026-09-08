package com.leadaxe.lxbox.vpn

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.Uri
import android.os.Build
import android.os.ParcelFileDescriptor
import android.os.PowerManager
import android.os.SystemClock
import android.util.Log
import androidx.annotation.RequiresApi
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import com.leadaxe.lxbox.R
import io.nekohasekai.libbox.CommandServer
import io.nekohasekai.libbox.CommandServerHandler
import io.nekohasekai.libbox.Libbox
import io.nekohasekai.libbox.OverrideOptions
import io.nekohasekai.libbox.PlatformInterface
import io.nekohasekai.libbox.SystemProxyStatus
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import io.nekohasekai.libbox.StringIterator
import org.json.JSONObject
import java.util.concurrent.atomic.AtomicReference

/// §049 F1 split — port из reference SagerNet
/// (`bg/BoxService.kt` commit 3b3883e, libbox 1.13.11).
///
/// `BoxService` — plain class, implements **только** `CommandServerHandler`.
/// Владеет state'ом (`fileDescriptor`, `commandServer`, `serviceScope`, etc.)
/// и lifecycle'ом libbox-runtime'а.
///
/// `BoxVpnService` (Android Service + `PlatformInterfaceWrapper`) держит
/// `private val service = BoxService(this, this)` в **field initializer** и
/// форвардит все Android lifecycle callbacks в `service.X()`.
///
/// `CommandServer(this, platformInterface)` создаётся с 2 разных Java
/// instance: `this` = CSH=BoxService, `platformInterface` = PI=BoxVpnService.
class BoxService(
    private val service: Service,
    private val platformInterface: PlatformInterface,
) : CommandServerHandler {

    companion object {
        private const val TAG = "BoxService"

        /// §345 — live-режим verbose core-логов: true = TRACE/DEBUG-фильтр в
        /// `writeDebugMessage` снят. Меняется на лету из VpnPlugin
        /// (setCoreLogsVerbose) без перезапуска VPN; при старте сервиса
        /// подтягивается из prefs (переживает рестарт процесса).
        @Volatile
        @JvmStatic
        var coreLogsVerbose: Boolean = false

        /// §223 Часть B (#23) — задержка перед native-snapshot'ом подтекста
        /// уведомления при старте без UI. Даём ядру устаканить `selected` у
        /// selector'ов после Started, прежде чем читать getGroups().
        private const val NOTIFICATION_SNAPSHOT_DELAY_MS = 3000L

        /// §122 Фаза 0 — статическая ссылка на активный `BoxCommandClient`, чтобы
        /// `VpnPlugin` (Flutter-процесс) дёргал императивы (urlTestOutbound/getRules/
        /// selectOutbound/closeConnection) и lifecycle (screen/profiler connect/disconnect).
        /// @Volatile: пишется из service-потока, читается из Flutter MethodChannel-потока.
        @Volatile
        var commandClient: BoxCommandClient? = null
            private set
    }

    /// Scoped to service lifetime — all child coroutines are cancelled in onDestroy / doStop.
    /// Recreated on each start since cancel() is terminal for a scope.
    private var serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    /// §428 — тикер сторожа (VpnWatchdog.startTicker) на serviceScope.
    private var watchdogJob: kotlinx.coroutines.Job? = null

    /// §140 — отдельный scope ТОЛЬКО для `doForceStop`-teardown'а. КРИТИЧНО, что
    /// его НЕ отменяет `onDestroy`: `doForceStop` вызывает `stopSelf()` → onDestroy
    /// → `serviceScope.cancel()`, и если teardown крутился бы на `serviceScope`, он
    /// был бы отменён на полпути, не успев закрыть Clash-порт 63130 (`bind: address
    /// already in use` на след. старте — см. §129 регресс, §140). Этот scope живёт
    /// независимо: teardown сам делает `stopSelf()` ПОСЛЕ закрытия порта.
    /// Пересоздаётся в `resetScope` вместе с `serviceScope`.
    private var forceStopScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    private fun resetScope() {
        serviceScope.cancel()
        serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        forceStopScope.cancel()
        forceStopScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    }

    /// §049 F2 — `AtomicReference` вместо `@Volatile`. `getAndSet(null)?.close()`
    /// гарантирует что только один поток выполнит close(); остальные — no-op.
    /// Главный fix для §047 race condition на mutations `fileDescriptor`.
    /// Public для `BoxVpnService.openTun()` которому нужен `set(pfd)`.
    val fileDescriptor = AtomicReference<ParcelFileDescriptor?>(null)

    /// §049 F2/F3 — same atomic CAS pattern для commandServer.
    private val commandServer = AtomicReference<CommandServer?>(null)
    /// §155 — `@Volatile`: читается/пишется из binder-потока (`receiver.onReceive`)
    /// и из service main thread (`onStartCommand`/`onDestroy`/`doStop`/`doForceStop`).
    /// Без барьера видимости поток может прочитать устаревшее значение и дважды
    /// (un)register'нуть receiver.
    /// §361 — зеркалим значение в companion (`BoxVpnService.stopReceiverAlive`):
    /// `stopAwait` живёт там и должен знать, есть ли кому принять ACTION_STOP.
    /// Зеркало в сеттере, а не на шести сайтах присваивания (register + пять
    /// путей снятия: onDestroy/onRevoke/doStop/doForceStop/exit) — иначе
    /// достаточно забыть один, чтобы страховка молча перестала работать.
    @Volatile
    private var receiverRegistered = false
        set(value) {
            field = value
            BoxVpnService.setStopReceiverAlive(value)
        }
    private var status = VpnStatus.Stopped

    private val notification: ServiceNotification by lazy { ServiceNotification(service) }

    private val receiver = object : BroadcastReceiver() {
        /// §373 — увести тело обработчика с main-потока.
        ///
        /// `onReceive` Android исполняет на main. Всё, что доходит до
        /// `cs.startOrReloadService` / unary-RPC в ядро, блокирует его на время
        /// вызова: reload пересобирает весь box-инстанс (на подписке в ~700
        /// outbound'ов — секунды), и при превышении 5с прилетает ANR по вводу.
        ///
        /// `goAsync()` — а не «просто launch»: без него Android считает broadcast
        /// обработанным сразу по возврату из `onReceive` и вправе понизить
        /// приоритет процесса ровно посреди reload'а. `PendingResult.finish()`
        /// строго в `finally`, иначе утечка (и ANR самого broadcast'а по таймауту).
        ///
        /// Тело — `serviceScope` (`Dispatchers.IO`): вместе с сервисом умирает и
        /// работа. Отмена scope НЕ прерывает уже начатый JNI-вызов (см. §361), но
        /// `finish()` в `finally` отработает в любом случае.
        private fun offloadFromMain(action: String, block: () -> Unit) {
            val pending = goAsync()
            serviceScope.launch {
                try {
                    block()
                } catch (t: Throwable) {
                    Log.e(TAG, "$action failed", t)
                } finally {
                    runCatching { pending.finish() }
                        .onFailure { Log.e(TAG, "$action: finish() failed", it) }
                }
            }
        }

        override fun onReceive(context: Context, intent: Intent) {
            Log.d(TAG, "[vpn] service.receiver.onReceive action=${intent.action} status=${status.name} registered=$receiverRegistered")
            when (intent.action) {
                BoxVpnService.ACTION_STOP -> doStop()
                BoxVpnService.ACTION_FORCE_STOP -> doForceStop()
                BoxVpnService.ACTION_RECONNECT -> {
                    // §182 — кнопка Reconnect в уведомлении. Через companion (а не
                    // локальный метод): reconnect переживает stopSelf этого инстанса.
                    Log.d(TAG, "[vpn] receiver: ACTION_RECONNECT → BoxVpnService.reconnect()")
                    runCatching { BoxVpnService.reconnect(service.applicationContext) }
                        .onFailure { Log.e(TAG, "ACTION_RECONNECT failed", it) }
                }
                BoxVpnService.ACTION_RELOAD -> {
                    // §373 — СТРОГО off-main: `onReceive` крутится на main-потоке, а
                    // `serviceReload` упирается в блокирующий `startOrReloadService`
                    // (пересборка всех outbound'ов). На большой подписке это уходит
                    // за 5с = ANR «Приложение не отвечает».
                    Log.d(TAG, "[vpn] receiver: ACTION_RELOAD → serviceReload() (off-main)")
                    offloadFromMain("ACTION_RELOAD") { serviceReload() }
                }
                BoxVpnService.ACTION_RESET_NETWORK -> {
                    // §373 — unary-RPC в ядро, тоже не на main (см. ACTION_RELOAD).
                    Log.d(TAG, "[vpn] receiver: ACTION_RESET_NETWORK → cs.resetNetwork() (off-main)")
                    offloadFromMain("ACTION_RESET_NETWORK") {
                        commandServer.get()?.resetNetwork()
                    }
                }
                BoxVpnService.ACTION_CLEAR_DNS_CACHE -> {
                    // §263 — удалить cache.db, затем serviceReload: startOrReloadService
                    // закрывает старый box-инстанс (освобождает fd cache.db) и
                    // поднимает новый, который создаёт чистый cache.db. Delete
                    // перед reload — старый инстанс ещё держит unlink'нутый inode,
                    // новый пишет в свежий файл. Тоннель дропается ~3с (как reload).
                    //
                    // §373 — весь блок off-main: тот же reload внутри. Delete едет в
                    // ту же корутину, чтобы порядок delete→reload не разъехался.
                    Log.d(TAG, "[vpn] receiver: ACTION_CLEAR_DNS_CACHE → delete cache.db + serviceReload() (off-main)")
                    offloadFromMain("ACTION_CLEAR_DNS_CACHE") {
                        BoxVpnService.deleteCacheDbFile()
                        serviceReload()
                    }
                }
                BoxVpnService.ACTION_UPDATE_NOTIFICATION -> {
                    // §223 — live-перерисовка лейблов (#20) тем же show()-путём,
                    // что и connect-рендер (builder переиспользуется → кнопки §182
                    // не стекаются). СТРОГО в Started: в Starting держим
                    // "Starting..." (connect-рендер сам подхватит кэш), а после
                    // notification.stop() повторный show() воскресил бы шторку.
                    if (status == VpnStatus.Started) {
                        runCatching {
                            notification.show(
                                ConfigManager.notificationTitle,
                                ConfigManager.notificationText.ifEmpty {
                                    L10n.str(service, R.string.status_connected)
                                },
                            )
                        }.onFailure { Log.e(TAG, "ACTION_UPDATE_NOTIFICATION failed", it) }
                    }
                }
                PowerManager.ACTION_DEVICE_IDLE_MODE_CHANGED -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) onIdleModeChanged()
                }
                Intent.ACTION_SCREEN_OFF -> {
                    Log.d(TAG, "[vpn] SCREEN_OFF → pause")
                    commandServer.get()?.pause()
                }
                Intent.ACTION_SCREEN_ON -> {
                    // wake() — только в BG_MODE_ALWAYS: пара к SCREEN_OFF → pause
                    // (§215). В прочих режимах pause не звучал, будить нечего.
                    if (BootReceiver.getBackgroundMode(service) == BootReceiver.BG_MODE_ALWAYS) {
                        Log.d(TAG, "[vpn] SCREEN_ON → wake")
                        commandServer.get()?.wake()
                    }
                    // §340 — wake-нудж SPEC 041 v2: ядро ребиндит только доказуемо
                    // стухшие WG/AWG-сессии (стале-предикат + дебаунс 90 с — в ядре,
                    // вызов неблокирующий). Именно SCREEN_ON, а не USER_PRESENT:
                    // приложения лезут в сеть сразу по включению экрана, и нудж
                    // обязан успеть ДО первого спроса трафика — иначе ретраи
                    // начинаются раньше и сессию чинит досрочный rebind ядра
                    // (device-наблюдение 02.08: USER_PRESENT стабильно опаздывал).
                    Log.d(TAG, "[vpn] SCREEN_ON → rebindStaleEndpoints")
                    runCatching { commandServer.get()?.rebindStaleEndpoints() }
                        .onFailure { Log.e(TAG, "rebindStaleEndpoints failed", it) }
                }
            }
        }
    }

    // -------------------------------------------------------------------------
    // Android lifecycle (forwarded from BoxVpnService)
    // -------------------------------------------------------------------------

    fun onCreate() {
        // Сервис может стартануть в свежем процессе без UI (через QS-tile
        // или launcher shortcut, после того как Android прибил предыдущий
        // процесс из-за SIGABRT/OOM). В таком процессе VpnPlugin не
        // подключается, и `BoxApplication.initialize` сам по себе не
        // вызовется — а `application` lateinit, libbox setup отсутствует
        // → onStartCommand упадёт с UninitializedPropertyAccessException.
        // initialize() идемпотентен (if (initialized) return).
        BoxApplication.initialize(service.applicationContext)
    }

    /// §428 (issue #115) — `START_STICKY` из ОБОИХ выходов (система запоминает
    /// результат последнего вызова, guard-выход тоже обязан быть sticky).
    /// Раньше было `START_NOT_STICKY`: OOM/lmkd/OEM-чистилка убивала процесс
    /// (UI и VPN живут в одном), tun умирал и никто его не поднимал — Always-on
    /// перезапускает VPN-приложение только на boot/unlock/package-событиях, а
    /// на смерть процесса лишь вешает «Always-on VPN disconnected». Со sticky
    /// AMS пересоздаёт сервис сам и зовёт onStartCommand(null): статус в новом
    /// процессе Stopped, `onCreate` уже поднял `BoxApplication.initialize`,
    /// старт идёт штатно по persist-конфигу. Явные Stop-пути (doStop /
    /// doForceStop / onRevoke / stopAndAlert / exit) все заканчиваются
    /// `stopSelf()` — started-состояние снято, ручную остановку AMS не
    /// воскрешает.
    ///
    /// Предохранитель от шторма: если старт сам валит процесс (Go-паника на
    /// конфиге, прецедент v2.12.0 force_ipv4×FakeIP), sticky превратил бы один
    /// краш в цикл «рестарт → краш». null-intent = sticky-рестарт; считаем их
    /// в prefs, с STICKY_RESTART_LIMIT-го в окне STICKY_RESTART_WINDOW_MS не
    /// стартуем: уведомление + stopSelf + NOT_STICKY. Успешный `Started`
    /// сбрасывает счётчик (setStatus). Ручные старты (intent с action) счётчик
    /// не трогают.
    fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        Log.d(TAG, "[vpn] onStartCommand action=${intent?.action} status=${status.name} startId=$startId receiverRegistered=$receiverRegistered")
        if (intent == null) {
            val n = BootReceiver.noteStickyRestart(service)
            Log.w(TAG, "[vpn §428] sticky restart #$n (limit=${BootReceiver.STICKY_RESTART_LIMIT} per ${BootReceiver.STICKY_RESTART_WINDOW_MS / 1000}s)")
            if (n >= BootReceiver.STICKY_RESTART_LIMIT) {
                notification.showAlert(
                    L10n.str(service, R.string.sticky_restart_storm_title),
                    L10n.str(service, R.string.sticky_restart_storm_text),
                )
                service.stopSelf()
                return Service.START_NOT_STICKY
            }
        }
        try {
            notification.show(
                ConfigManager.notificationTitle,
                L10n.str(service, R.string.notification_status_starting),
            )
        } catch (t: Throwable) {
            // §428 — на API 31+ startForeground из фона может бросить
            // ForegroundServiceStartNotAllowedException. Раньше это был краш
            // процесса; со sticky краш = ещё один рестарт. Останавливаемся тихо.
            Log.e(TAG, "[vpn §428] startForeground failed — stopSelf", t)
            service.stopSelf()
            return Service.START_NOT_STICKY
        }

        if (status != VpnStatus.Stopped) {
            Log.w(TAG, "[vpn] onStartCommand GUARD — status=${status.name} != Stopped, silent return")
            return Service.START_STICKY
        }
        resetScope()
        setStatus(VpnStatus.Starting)
        // §345 — подтянуть persist-значение verbose (live-изменения дальше
        // приходят напрямую в volatile из VpnPlugin).
        coreLogsVerbose = BootReceiver.isCoreLogsVerbose(service)

        if (!receiverRegistered) {
            val mode = BootReceiver.getBackgroundMode(service)
            Log.d(TAG, "[vpn] registerReceiver from onStartCommand mode=$mode")
            ContextCompat.registerReceiver(service, receiver, IntentFilter().apply {
                addAction(BoxVpnService.ACTION_STOP)
                addAction(BoxVpnService.ACTION_FORCE_STOP)
                addAction(BoxVpnService.ACTION_RECONNECT)   // §182
                addAction(BoxVpnService.ACTION_RELOAD)
                addAction(BoxVpnService.ACTION_RESET_NETWORK)
                addAction(BoxVpnService.ACTION_CLEAR_DNS_CACHE)   // §263
                addAction(BoxVpnService.ACTION_UPDATE_NOTIFICATION)   // §223
                // §340 — вне when(mode): нудж на пробуждение экрана нужен в любом
                // фоновом режиме (стухший NAT от энергорежима не зависит).
                // SCREEN_OFF остаётся режимным — он пара к wake() из §215.
                addAction(Intent.ACTION_SCREEN_ON)

                when (mode) {
                    BootReceiver.BG_MODE_LAZY -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                            addAction(PowerManager.ACTION_DEVICE_IDLE_MODE_CHANGED)
                        }
                    }
                    BootReceiver.BG_MODE_ALWAYS -> {
                        addAction(Intent.ACTION_SCREEN_OFF)
                    }
                }
            }, ContextCompat.RECEIVER_NOT_EXPORTED)
            receiverRegistered = true
        }

        serviceScope.launch {
            try {
                BoxApplication.libboxReady.await()
                startCommandServer()
                startSingbox()
            } catch (t: Throwable) {
                Log.e(TAG, "Start failed", t)
                // Payload (t.message) — OS/kernel passthrough, не переводится.
                stopAndAlert(t.message
                    ?: L10n.str(service, R.string.stop_alert_unknown_error))
            }
        }
        return Service.START_STICKY
    }

    fun onDestroy() {
        Log.d(TAG, "[vpn] onDestroy status=${status.name} receiverRegistered=$receiverRegistered")
        serviceScope.cancel()
        if (receiverRegistered) {
            runCatching { service.unregisterReceiver(receiver) }
            receiverRegistered = false
        }
        if (BoxVpnService.currentStatus != VpnStatus.Stopped) {
            BoxVpnService.setCurrentStatus(VpnStatus.Stopped)
            runCatching { LxBoxTileService.refreshTile(service.applicationContext) }
                .onFailure { Log.w(TAG, "refreshTile in onDestroy failed: ${it.message}") }
        }
    }

    fun onTaskRemoved(rootIntent: Intent?) {
        if (!BootReceiver.isKeepOnExit(service)) {
            Log.d(TAG, "App removed from recents — stopping VPN")
            doStop()
        }
    }

    fun onRevoke() {
        Log.d(TAG, "onRevoke — VPN taken by another app")
        // §049 F5 — atomic close, безопасно на любом thread'е.
        closeFileDescriptor("onRevoke")
        closeCommandServerAtomic("revoke")

        if (receiverRegistered) {
            runCatching { service.unregisterReceiver(receiver) }
            receiverRegistered = false
        }
        notification.stop()
        // §276 — revoked=true поднимает TunnelStatus.revoked в Dart (SnackBar со
        // Start + чип «Taken by another VPN»). §224 — текст самодостаточный:
        // Dart его перекрывает, но native-строка уходит в lastStartError и
        // Debug API (§250), сырой оставлять нельзя.
        // §279 — намеренно НЕ локализуется (wire-only): display перекрывает
        // Dart, а Debug API / lastStartError — английские навсегда (спека §8).
        setStatus(
            VpnStatus.Stopped,
            error = "Another VPN app took the system VPN slot " +
                "(e.g. an always-on VPN). Start again to reconnect.",
            revoked = true,
        )
        serviceScope.cancel()
        service.stopSelf()
    }

    // -------------------------------------------------------------------------
    // Start / stop sing-box
    // -------------------------------------------------------------------------

    /// §329 — `reason` называет teardown-путь, из которого пришло закрытие.
    /// Четыре вызывающих (`onRevoke` / `doStop` / `doForceStop` / `stopAndAlert`)
    /// раньше были неразличимы в логах, а именно источник и порядок закрытия —
    /// предмет поиска триггера §047. `onDestroy` сюда НЕ приходит: он делает
    /// `serviceScope.cancel()`, что может снять in-flight `doStop`-корутину ДО
    /// её `closeFileDescriptor` — тогда fd остаётся незакрытым, и в логе будет
    /// `[vpn] onDestroy` без парного `[fd §329] close(doStop)`. Такая пара (или
    /// её отсутствие) — отдельный сигнал при разборе. Номер fd + монотонная метка
    /// сопоставляются с `[fd §329] openTun` и с warn'ом ядра о смерти acceptLoop.
    /// Единообразно с соседним `closeCommandServerAtomic(reason)`.
    private fun closeFileDescriptor(reason: String) {
        val pfd = fileDescriptor.getAndSet(null)
        // Номер читаем ДО close() — после закрытия `pfd.fd` уже невалиден.
        // no-op (уже закрыт другим потоком) логируем тоже: он говорит, что
        // этот путь пришёл вторым, и называет победителя гонки по времени.
        val fd = pfd?.runCatching { fd }?.getOrNull()
        // Уровень `w` — см. парный лог в `BoxVpnService.openTun`.
        Log.w(TAG, "[fd §329] close($reason) fd=${fd ?: "already-closed"} at=${SystemClock.elapsedRealtime()}ms")
        pfd?.runCatching { close() }
            ?.onFailure { Log.w(TAG, "closeFileDescriptor($reason): close failed: ${it.message}") }
    }

    private fun closeCommandServerAtomic(reason: String) {
        // §122 Фаза 0 — сначала закрыть CommandClient-канал (его сокет-соединения к
        // CommandServer), потом сам сервер. Идемпотентно (getAndSet-паттерн внутри).
        runCatching { commandClient?.shutdownAll() }
            .onFailure { Log.w(TAG, "closeCommandServerAtomic($reason): commandClient shutdown failed: ${it.message}") }
        commandClient = null
        val cs = commandServer.getAndSet(null) ?: return

        // §330 — `close()` идёт ПЕРЕД `closeService()`, а не после. Причина: на
        // force-пути `closeService()` под `withTimeout(2с)`, а этот таймаут
        // кооперативен — блокирующий JNI-вызов он НЕ прерывает, только отпускает
        // корутину. При старом порядке залипший `closeService()` (10-17с на
        // конфигах с многими WG, §287) не отдавал управление следующей строке, и
        // `close()` не вызывался вовсе — слушающий сокет (Clash-порт 63130 +
        // command.sock) оставался занят на всё это время, хотя `stopSelf()` уже
        // прошёл. Отсюда жалобы «порт не освобождается, другая программа его
        // открыть не может» (§287 отпустила это как «WG биндит эфемерные сокеты» —
        // верно для WG, но не для фиксированного 63130).
        //
        // Развязка безопасна — проверено по ядру (v1.14.0-lx.17-rc.4):
        // `CommandServer.Close()` (command_server.go:180) трогает только
        // grpcServer/listener/subscriber'ы и НЕ берёт `serviceAccess`, тогда как
        // `CloseService()` (daemon/started_service.go:245) держит этот мьютекс на
        // всё время `instance.Close()`. Общего состояния нет, порядок между ними
        // ядру безразличен.
        //
        // Обратный порядок ничего не ломает и на штатном `doStop`: `closeService()`
        // не ходит в gRPC-транспорт, а CommandClient-канал уже разорван выше.
        runCatching { cs.close() }
            .onFailure { Log.w(TAG, "closeCommandServerAtomic($reason): close failed: ${it.message}") }
        Log.w(TAG, "[fd §330] listener closed($reason) at=${SystemClock.elapsedRealtime()}ms")

        runCatching { cs.closeService() }.onFailure {
            Log.e(TAG, "closeCommandServerAtomic($reason): closeService failed", it)
            runCatching { cs.setError("android: $reason close service: ${it.message}") }
        }
    }

    private suspend fun startSingbox() {
        try {
            BoxApplication.libboxReady.await()
        } catch (t: Throwable) {
            stopAndAlert(L10n.str(
                service, R.string.stop_alert_libbox_init_failed, t.message ?: ""))
            return
        }

        val config = ConfigManager.load()
        if (config.isBlank() || config == "{}") {
            stopAndAlert(L10n.str(service, R.string.stop_alert_empty_config))
            return
        }

        // §087 — на genuine смену интерфейса (WiFi↔LTE) дёргаем resetNetwork()
        // (ядро CloseAll + flush DNS + rebind): закрывает стейл-сокеты на мёртвом
        // NIC, иначе app виснет на них до TCP-таймаута. См. docs/spec/tasks/087.
        DefaultNetworkMonitor.start(serviceScope) {
            Log.d(TAG, "[vpn] interface switch → resetNetwork()")
            runCatching { commandServer.get()?.resetNetwork() }
                .onFailure { Log.e(TAG, "auto resetNetwork failed", it) }
        }
        // libbox 1.14: `Libbox.setMemoryLimit` удалён — управление OOM killer'ом
        // переехало в SetupOptions (oomKillerEnabled / oomMemoryLimit), задаётся
        // один раз в BoxApplication.setupLibbox.

        val cs = commandServer.get() ?: run {
            stopAndAlert(L10n.str(service, R.string.stop_alert_no_command_server))
            return
        }

        try {
            cs.startOrReloadService(config, buildOverrideOptions(config))
        } catch (t: Throwable) {
            stopAndAlert(L10n.str(
                service, R.string.stop_alert_start_failed, t.message ?: ""))
            return
        }

        // §050 — port from reference SagerNet BoxService.kt 1.13.11
        // (`needWIFIState` block after startOrReloadService).
        //
        // Sing-box config may contain DNS/route rules with `wifi_ssid:`
        // or `wifi_bssid:` conditions. After config parse, sing-box exposes
        // whether wifi state is needed via `needWIFIState()`. If yes AND
        // Location permission is not granted (`ACCESS_BACKGROUND_LOCATION`
        // on API 29+, `ACCESS_FINE_LOCATION` on API 28-), then
        // `WifiManager.getConnectionInfo()` throws SecurityException which
        // propagates through JNI → process abort.
        //
        // Stop service with a structured alert prefix (`alert:permission:...`).
        // Flutter side detects prefix and shows native AlertDialog with
        // "Open Settings" button (see HomeController._handleStatusEvent).
        if (runCatching { cs.needWIFIState() }.getOrDefault(false)) {
            // Permission matrix for `WifiManager.connectionInfo`:
            //  - API 28-:  ACCESS_FINE_LOCATION
            //  - API 29-32: ACCESS_BACKGROUND_LOCATION (background access required)
            //  - API 33+:  ACCESS_BACKGROUND_LOCATION + NEARBY_WIFI_DEVICES
            //              (без NEARBY ssid возвращается как "<unknown ssid>"
            //               когда targetSdk >= 33).
            val needed = mutableListOf<String>()
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
                needed += android.Manifest.permission.ACCESS_FINE_LOCATION
            } else {
                needed += android.Manifest.permission.ACCESS_BACKGROUND_LOCATION
            }
            if (Build.VERSION.SDK_INT >= 33) {
                needed += "android.permission.NEARBY_WIFI_DEVICES"
            }
            val missing = needed.filter {
                service.checkSelfPermission(it) !=
                    android.content.pm.PackageManager.PERMISSION_GRANTED
            }
            if (missing.isNotEmpty()) {
                Log.e(TAG, "[vpn] config requires WIFI state but missing: $missing")
                // Structured alert: `alert:<type>:<details>` — Flutter parses
                // type and shows AlertDialog with "Open Settings" button.
                stopAndAlert("alert:permission_location:${missing.joinToString(",")}")
                return
            }
            Log.d(TAG, "[vpn] sing-box uses WIFI state, all permissions granted: $needed")
        }

        // §361 — старт мог быть отменён, пока мы висели в блокирующем
        // `startOrReloadService` (нода не отвечает — вызов держит секунды, а то
        // и до таймаута). `doForceStop`/`onDestroy` за это время сносят сервис и
        // отменяют `serviceScope`, но JNI-вызов отмену не чувствует: корутина
        // возвращается и идёт дальше по прямой. Без этой проверки она ставила
        // `Started` НА УЖЕ МЁРТВОМ сервисе, перезаписывая `Stopped`, выставленный
        // в `onDestroy` секундой раньше.
        //
        // Последствие было ровно такое: `currentStatus=Started` при снятом
        // receiver'е → `stopAwait` шлёт ACTION_STOP принимать некому → 5с таймаут
        // → `stopVPN` возвращает false. Кнопка «Стоп» мертва, UI держит
        // «Подключено» с тикающим таймером, CommandClient стучится в отсутствующее
        // ядро (`getGroups still unavailable`) — список узлов пуст.
        //
        // Проверяем контекст СВОЕЙ корутины, а не поле `serviceScope`: последнее
        // пересоздаётся в `resetScope`, и новый (живой) scope соврал бы про нашу
        // отменённую корутину. §122-дедуп здесь не помогает — там гасится повтор
        // ОДНОГО статуса, а тут два разных (Stopped → Started).
        if (!currentCoroutineContext().isActive) {
            Log.w(TAG, "[vpn §361] start cancelled while blocked — skip setStatus(Started)")
            return
        }
        // §387 — парный к §361 guard для другого ordering'а: `doForceStop` успел
        // пройти (setStatus(Stopped) уже разослан), но его teardown упёрся в тот
        // же занятый ядром JNI-вызов → `stopSelf()`/`onDestroy` ещё не было и
        // корутина НЕ отменена — §361 такой поздний return не ловит. Признак
        // смерти сессии здесь — состояние: любой stop-путь (doStop/doForceStop/
        // stopAndAlert/onRevoke) уводит `status` из Starting ДО teardown'а.
        // Поздний `Started` поверх — зомби: Dart принял бы его за живой туннель
        // (prev=disconnected), а сервис умирает → все RPC виснут, UI держит
        // «Connected», стоп не работает. Добивать ядро не нужно — teardown
        // stop-пути уже в полёте и разблокируется этим же возвратом из JNI.
        if (status != VpnStatus.Starting) {
            Log.w(TAG, "[vpn §387] status=${status.name} after start returned — skip setStatus(Started)")
            return
        }
        setStatus(VpnStatus.Started)

        // §122 Фаза 0 — поднять CommandClient-канал. ПОСЛЕ startCommandServer()
        // и Started: command.sock существует только когда сервер запущен. statusClient
        // always-on (watchdog + скорость); screen/profiler — по сигналам из Dart.
        runCatching {
            val cc = BoxCommandClient()
            commandClient = cc
            cc.startStatus()
        }.onFailure { Log.w(TAG, "BoxCommandClient.startStatus failed: ${it.message}") }

        // §223 Часть B (#23) — если UI не открывался (старт с QS-плитки → нет
        // Flutter-движка → Dart не прислал лейбл), через ~3с сами читаем
        // выбранную ноду одним unary-pull'ом и рисуем подтекст. serviceScope:
        // отменяется в onDestroy/stop → не рисуем шторку мёртвого туннеля.
        serviceScope.launch {
            delay(NOTIFICATION_SNAPSHOT_DELAY_MS)
            // Stop/reload успел / Dart уже прислал лейбл (UI открыт) → молчим:
            // Dart-источник авторитетнее (знает selectedGroup, ловит и смены).
            if (status != VpnStatus.Started) return@launch
            if (ConfigManager.notificationText.isNotEmpty()) return@launch
            val label = commandClient?.selectedNodeLabel(ConfigManager.load())
            if (label.isNullOrEmpty()) return@launch
            ConfigManager.setNotificationText(label)
            withContext(Dispatchers.Main) {
                if (status == VpnStatus.Started) {
                    notification.show(ConfigManager.notificationTitle, label)
                }
            }
        }

        withContext(Dispatchers.Main) {
            // §123 — подтекст = тег активной ноды / route.final (из Dart через
            // setNotificationText). Пусто → fallback на статус "Connected".
            notification.show(
                ConfigManager.notificationTitle,
                ConfigManager.notificationText.ifEmpty {
                    L10n.str(service, R.string.status_connected)
                },
            )
        }
    }

    /// §049 F1 — `CommandServer(handler=this, platform=platformInterface)`
    /// с двумя разными Java instances (port из reference 1.13.11).
    private fun startCommandServer() {
        // §236 — VPN приоритетнее probe-сессии: если юзер запускает туннель
        // при живом Test servers, глушим probe (он держит command.sock —
        // второй CommandServer на том же basePath не поднимется).
        runCatching { ProbeSession.stop() }
        val cs = CommandServer(this, platformInterface)
        cs.start()
        commandServer.set(cs)
    }

    private fun doStop() {
        Log.d(TAG, "[vpn] doStop ENTER status=${status.name} receiverRegistered=$receiverRegistered")
        if (status == VpnStatus.Stopped || status == VpnStatus.Stopping) {
            Log.w(TAG, "[vpn] doStop GUARD — already ${status.name}, return without action")
            return
        }
        setStatus(VpnStatus.Stopping)

        if (receiverRegistered) {
            Log.d(TAG, "[vpn] unregisterReceiver from doStop")
            runCatching { service.unregisterReceiver(receiver) }
            receiverRegistered = false
        }
        notification.stop()

        serviceScope.launch {
            closeFileDescriptor("doStop")
            DefaultNetworkMonitor.stop()
            closeCommandServerAtomic("doStop")

            withContext(Dispatchers.Main) {
                Log.d(TAG, "[vpn] doStop cleanup done → setStatus(Stopped) + stopSelf()")
                setStatus(VpnStatus.Stopped)
                service.stopSelf()
            }
        }
    }

    /// §129 — жёсткая остановка, когда ядро ЗАВИСЛО вхолостую (detour AWG→WG, #2):
    /// dial наружу заклинило, `setStatus(Stopped)` от ядра не приходит, обычный
    /// `doStop` повисает на teardown-вызовах в Go (`closeFileDescriptor` /
    /// `closeCommandServerAtomic`) и НЕ доходит до `stopSelf()`. Сервис остаётся
    /// жить и роутить вхолостую (tun0 поднят, 0 трафика).
    ///
    /// §140 — порядок ИСПРАВЛЕН: раньше `stopSelf()` шёл ДО фонового teardown'а на
    /// `serviceScope`. `stopSelf()` → `onDestroy` → `serviceScope.cancel()` отменял
    /// teardown на полпути, не успев закрыть Clash-порт 63130 → след. старт падал с
    /// `bind: address already in use` (см. `stopAndAlert`). Теперь:
    ///   1. UI/нотификацию гасим синхронно на Main СРАЗУ (`unregisterReceiver`,
    ///      `notification.stop()`, `setStatus(Stopped)`) — кнопка разблокируется
    ///      немедленно, НЕ ждём ядро (замысел §129 сохранён).
    ///   2. teardown ядра + `stopSelf()` — на `forceStopScope` (его `onDestroy` НЕ
    ///      отменяет!). `stopSelf()` вызывается ПОСЛЕ `closeCommandServerAtomic`,
    ///      как в `doStop`. Зависший Go-вызов отваливается по `withTimeout(2с)` и
    ///      не блокирует ни `stopSelf()`, ни уже разблокированный UI.
    ///   3. НЕТ guard'а на `Stopping` — force обязан пройти, даже когда `doStop`
    ///      уже застрял в `Stopping`.
    ///
    /// Идемпотентно: если уже `Stopped` — no-op. Teardown-функции тоже идемпотентны
    /// (`AtomicReference.getAndSet(null)`), повторный вызов безопасен.
    private fun doForceStop() {
        Log.w(TAG, "[vpn] doForceStop ENTER status=${status.name} receiverRegistered=$receiverRegistered")
        if (status == VpnStatus.Stopped) {
            Log.d(TAG, "[vpn] doForceStop — already Stopped, no-op")
            return
        }

        // 1. UI/нотификацию гасим синхронно на Main СРАЗУ — это дёшево и не виснет.
        // Кнопка разблокируется немедленно, не дожидаясь teardown'а ядра.
        if (receiverRegistered) {
            runCatching { service.unregisterReceiver(receiver) }
            receiverRegistered = false
        }
        notification.stop()
        setStatus(VpnStatus.Stopped)
        Log.w(TAG, "[vpn] doForceStop — UI/notification stopped, teardown+stopSelf on forceStopScope")

        // 2. Teardown ядра, затем stopSelf() — на forceStopScope (onDestroy его НЕ
        // отменяет). stopSelf() ПОСЛЕ закрытия Clash-порта 63130, иначе он зависнет
        // на след. старте (§140 регресс-фикс; порядок как в doStop). Зависший
        // Go-вызов отвалится по withTimeout и не заблокирует stopSelf().
        forceStopScope.launch {
            runCatching {
                withTimeout(2_000) { closeFileDescriptor("doForceStop") }
            }.onFailure { Log.w(TAG, "doForceStop: closeFileDescriptor timeout/fail: ${it.message}") }
            runCatching {
                withTimeout(2_000) { DefaultNetworkMonitor.stop() }
            }.onFailure { Log.w(TAG, "doForceStop: DefaultNetworkMonitor.stop timeout/fail: ${it.message}") }
            runCatching {
                withTimeout(2_000) { closeCommandServerAtomic("doForceStop") }
            }.onFailure { Log.w(TAG, "doForceStop: closeCommandServer timeout/fail: ${it.message}") }
            Log.d(TAG, "[vpn] doForceStop — teardown done → stopSelf()")
            withContext(Dispatchers.Main) { service.stopSelf() }
        }
    }

    private suspend fun stopAndAlert(message: String) {
        Log.e(TAG, "stopAndAlert: $message")
        // CRITICAL: full sing-box teardown ДО stopSelf'а. Раньше пропускали
        // closeFileDescriptor / closeCommandServerAtomic / DefaultNetworkMonitor.stop —
        // CommandServer держал binding на Clash API port (63130) даже после
        // service stop, и retry start VPN failed с
        // `external controller listen error: bind: address already in use`.
        // Same teardown sequence что и `doStop`, но в Main thread без
        // serviceScope.launch (мы уже в suspend) и с error message в
        // `setStatus(Stopped)` вместо silent stop.
        closeFileDescriptor("stopAndAlert")
        DefaultNetworkMonitor.stop()
        closeCommandServerAtomic("stopAndAlert: $message")

        withContext(Dispatchers.Main) {
            notification.show(
                L10n.str(service, R.string.notification_error_title), message)
            if (receiverRegistered) {
                runCatching { service.unregisterReceiver(receiver) }
                receiverRegistered = false
            }
            notification.stop()
            setStatus(VpnStatus.Stopped, error = message)
            service.stopSelf()
        }
    }

    /// §276 — [revoked] = «Stopped пришёл из onRevoke» (слот забрало другое
    /// VPN-приложение). Не отдельное значение VpnStatus: см. EXTRA_REVOKED.
    /// Всегда идёт в паре с [error], поэтому dedup-guard ниже его не глотает.
    private fun setStatus(
        newStatus: VpnStatus,
        error: String? = null,
        revoked: Boolean = false,
    ) {
        // §122 — дедупликация. Несколько teardown-путей (doStop/doForceStop/
        // onRevoke/exit) могут выстрелить `setStatus(Stopped)` повторно, в т.ч.
        // запоздалый `Stopped` ПОСЛЕ нового `Started` при быстром reconnect.
        // Без guard'а такой stale-broadcast долетал в Dart как `disconnected` и
        // обнулял live-state (groups/nodes пустели «иногда»). Идемпотентный
        // повтор того же статуса без error — no-op (не шлём broadcast, не дёргаем
        // плитку/shortcuts). error-несущий повтор пропускаем (важно для UI).
        if (status == newStatus && error == null) {
            Log.d(TAG, "[vpn] setStatus(${newStatus.name}) — same status, dedup (no broadcast)")
            return
        }
        Log.d(TAG, "[vpn] setStatus(${newStatus.name})${if (error != null) " error=$error" else ""} — sendBroadcast")
        status = newStatus
        BoxVpnService.setCurrentStatus(newStatus, revoked)
        // §428 — туннель поднялся: окно sticky-рестартов закрыто, туннель
        // «желателен», сторож взведён. Stopped (любой явный путь: doStop /
        // doForceStop / onRevoke / stopAndAlert / exit) — желание снято,
        // сторож снят. Гибель процесса сюда не приходит — на то и сторож.
        val appCtx = service.applicationContext
        when (newStatus) {
            VpnStatus.Started -> {
                BootReceiver.resetStickyRestarts(appCtx)
                BootReceiver.setVpnDesired(appCtx, true)
                watchdogJob?.cancel()
                watchdogJob = VpnWatchdog.startTicker(appCtx, serviceScope) {
                    status == VpnStatus.Started
                }
            }
            VpnStatus.Stopped -> {
                BootReceiver.setVpnDesired(appCtx, false)
                watchdogJob?.cancel()
                watchdogJob = null
                VpnWatchdog.disarm(appCtx)
            }
            else -> {}
        }

        // §276 — revoke НЕ меняет teardown: статус остаётся Stopped, поэтому
        // stopCompleter разблокируется как обычно (stopVPN/reconnect/force-stop
        // не виснут).
        if (newStatus == VpnStatus.Stopped) {
            BoxVpnService.completeStopIfWaiting()
        }
        service.sendBroadcast(
            Intent(BoxVpnService.BROADCAST_STATUS).apply {
                `package` = service.packageName
                putExtra(BoxVpnService.EXTRA_STATUS, newStatus.name)
                if (error != null) putExtra("error", error)
                if (revoked) putExtra(BoxVpnService.EXTRA_REVOKED, true)
            }
        )
        runCatching { LxBoxTileService.refreshTile(service.applicationContext) }
            .onFailure { Log.w(TAG, "refreshTile failed: ${it.message}") }
        runCatching { QuickShortcuts.refresh(service.applicationContext) }
            .onFailure { Log.w(TAG, "QuickShortcuts.refresh failed: ${it.message}") }
    }

    @RequiresApi(Build.VERSION_CODES.M)
    private fun onIdleModeChanged() {
        val cs = commandServer.get() ?: return
        if (BoxApplication.powerManager.isDeviceIdleMode) cs.pause() else cs.wake()
    }

    // -------------------------------------------------------------------------
    // CommandServerHandler overrides
    // -------------------------------------------------------------------------

    /// §049 F4 — без status-flap (Started → Starting → Started) при reload.
    /// Match reference (`BoxService.kt:192-249 serviceReload0`).
    ///
    /// §141 P1.1a — JNI no-throw (§050/§128): этот метод зовётся Go-ядром через
    /// `CommandServerHandler`. Раньше runCatching покрывал только
    /// `cs.startOrReloadService`, а внешнее тело (`notification.stop()`,
    /// `setStatus`, `ConfigManager.load`, `serviceScope.launch`) — нет: любой их
    /// throw пролетел бы через JNI = `Runtime::Abort` всего процесса. Оборачиваем
    /// всё тело внешним runCatching.
    override fun serviceReload() {
        runCatching {
            val cs = commandServer.get() ?: run {
                Log.w(TAG, "serviceReload: commandServer == null, treating as fresh start")
                notification.stop()
                setStatus(VpnStatus.Starting)
                serviceScope.launch { startSingbox() }
                return@runCatching
            }
            val config = ConfigManager.load()
            if (config.isBlank() || config == "{}") {
                Log.e(TAG, "serviceReload: empty config")
                return@runCatching
            }
            runCatching { cs.startOrReloadService(config, buildOverrideOptions(config)) }
                .onFailure {
                    Log.e(TAG, "serviceReload failed", it)
                    runCatching { cs.setError("android: reload: ${it.message}") }
                }
        }.onFailure { Log.e(TAG, "serviceReload: unexpected error (swallowed)", it) }
    }

    override fun serviceStop() { doStop() }

    /// §124 — «тень» поверх конфига: докрутки, которых НЕ должно быть в
    /// сохранённом конфиге (диагностируемом через `GET /config`). OverrideOptions
    /// модифицирует только in-memory parsed options ядра (`daemon/instance.go`
    /// `parseConfig` → append), сам `singbox_config.json` не трогает.
    ///
    /// Что кладём:
    /// - **self** (`com.leadaxe.lxbox`) → `includePackage`, **ТОЛЬКО в allow-режиме**.
    ///   В allow наш UID иначе выпадает из tun по whitelist'у; добавляем себя,
    ///   чтобы egress ядра (вместе с `protect(fd)`) гарантированно проходил.
    ///   ⛔ В deny self НЕ добавляем: иначе include(self из override) +
    ///   exclude(юзер из конфига) в одном tun → Android `Builder` получит и
    ///   `addAllowedApplication`, и `addDisallowedApplication` →
    ///   `UnsupportedOperationException`. Режим выводим из самого конфига:
    ///   наличие `include_package` = allow (его пишет post-step `tun_packages.dart`).
    /// - **autoRedirect** — root-only tproxy-фича (`auto_redirect` в sing-tun,
    ///   работает лишь на рутированном Android). Провод из persistent-флага
    ///   `BootReceiver.isAutoRedirect` (default false); UI-тоггла пока нет.
    private fun buildOverrideOptions(config: String): OverrideOptions {
        val options = OverrideOptions()

        // §124 — autoRedirect: root-only tproxy. Провод из persistent-флага
        // (default false). UI-тоггла пока нет — флаг управляется через prefs/adb;
        // на не-root устройстве ядро вернёт ошибку, поэтому дефолт false безопасен.
        options.autoRedirect = BootReceiver.isAutoRedirect(service)

        val isAllowMode = runCatching {
            val inbounds = JSONObject(config).optJSONArray("inbounds") ?: return@runCatching false
            for (i in 0 until inbounds.length()) {
                val inb = inbounds.optJSONObject(i) ?: continue
                if (inb.optString("type") == "tun") {
                    return@runCatching inb.has("include_package")
                }
            }
            false
        }.getOrDefault(false)

        if (isAllowMode) {
            options.includePackage = singleStringIterator(service.packageName)
            Log.d(TAG, "[vpn] override: +self (${service.packageName}) — allow-mode")
        }
        return options
    }

    /// Минимальный `StringIterator` на один элемент — для self-пакета в
    /// `OverrideOptions.includePackage` (см. §124).
    private fun singleStringIterator(value: String): StringIterator =
        object : StringIterator {
            private var consumed = false
            override fun len(): Int = 1
            override fun hasNext(): Boolean = !consumed
            // §151 F1 — JNI no-throw: `StringIterator.Next()` — Go-метод БЕЗ
            // `error`, throw = `Runtime::Abort`. За концом отдаём "", не бросаем
            // (хотя текущая реализация и не бросала — фиксируем инвариант явно).
            override fun next(): String {
                if (consumed) return ""
                consumed = true
                return value
            }
        }

    /// §049 F17 — реальный state HTTP-proxy для Clash dashboard.
    /// Match reference: cast service → VPNService и читаем флаги (у нас
    /// `BoxVpnService` хранит их как `@JvmField`-properties).
    ///
    /// §141 P1.1a — JNI no-throw: геттер зовётся Go-ядром через
    /// `CommandServerHandler`. На любой сбой возвращаем пустой `SystemProxyStatus()`
    /// (available=false/enabled=false), а не даём исключению пролететь в JNI.
    override fun getSystemProxyStatus(): SystemProxyStatus = runCatching {
        SystemProxyStatus().apply {
            if (service is BoxVpnService) {
                available = service.systemProxyAvailable
                enabled = service.systemProxyEnabled
            }
        }
    }.getOrElse {
        Log.e(TAG, "getSystemProxyStatus failed (fail-safe empty)", it)
        SystemProxyStatus()
    }

    // §141 P1.1a — делегирует в serviceReload(), который теперь сам no-throw.
    override fun setSystemProxyEnabled(isEnabled: Boolean) { serviceReload() }

    // ─── libbox 1.14: новые методы CommandServerHandler ──────────────────
    // sing-box 1.14 влил SSH-агент и debug-хук намеренного краша. Для Android
    // VPN-клиента не используем.

    /** SSH-agent forwarding не поддерживаем на Android. Error-метод — gomobile
     *  ловит исключение, до JNI Runtime::Abort не доходит. */
    override fun connectSSHAgent(): Int =
        throw UnsupportedOperationException("SSH agent not supported on Android")

    /** Debug-хук намеренного краша ядра — нам не нужен, no-op. */
    override fun triggerNativeCrash() {}

    /// §043: sing-box log lines проходят сюда независимо от `log.level`
    /// в конфиге. INFO+ пушим в Flutter через EventChannel "lxbox/coreLog".
    ///
    /// **F22 part 2 — производственный pipeline:**
    /// - Никакого `@Synchronized`: `LinkedBlockingQueue.offer` thread-safe сам,
    ///   а `@Synchronized` сериализовал бы sing-box goroutines на mutex и
    ///   не давал ничего полезного.
    /// - **Back-pressure cap** `LOG_QUEUE_MAX = 4096`: при slow Dart consumer'е
    ///   очередь не растёт без предела. Drop newest когда полно — потеря
    ///   visibility одного-двух batch'ей лучше OOM.
    /// - Single lazy `coreLogDrainer` Runnable. Никаких per-call lambda /
    ///   anonymous class allocations.
    /// - **Batching**: drainer отдаёт `List<String>` в `sink.success(list)` —
    ///   один JNI marshal на N строк вместо N marshall'ов. Dart side
    ///   принимает `List<dynamic>` (см. `clash_log_pump.dart`).
    /// - **Yield** каждые `DRAIN_BATCH_MAX = 200` строк: re-post Runnable если
    ///   queue ещё не пуст. Длинный burst не блочит main looper > одного frame.
    override fun writeDebugMessage(message: String) {
        // §141 P3.2c — null-sink guard ПЕРВОЙ строкой: пока Flutter не подписан
        // на coreLog (или отписался), нет смысла гонять два regex (ansi-strip +
        // trace-фильтр) на каждой строке sing-box лога. Раньше оба regex
        // выполнялись до этой проверки и работа выбрасывалась впустую.
        if (BoxVpnService.coreLogSink == null) return
        val plain = ansiEscapeRe.replace(message, "")
        // §345 — в verbose-режиме TRACE/DEBUG проходят (диагностика on-demand);
        // back-pressure ниже (LOG_QUEUE_MAX, drop newest) защищает от потопа.
        if (!coreLogsVerbose && traceDebugRe.containsMatchIn(plain)) return
        // Back-pressure: drop newest, не блокируем sing-box producer thread.
        if (coreLogQueue.size >= LOG_QUEUE_MAX) {
            coreLogDrops.incrementAndGet()
            return
        }
        coreLogQueue.offer(plain)
        if (drainerScheduled.compareAndSet(false, true)) {
            coreLogMainHandler.post(coreLogDrainer)
        }
    }

    // §171 — ANSI-strip. Sing-box оборачивает уровень и conn_id в ГОЛЫЕ
    // ESC-байты (`<ESC>`), НЕ в классические CSI-цвета: реальная строка =
    // `<ESC>INFO<ESC>[0617] [<ESC>759645927<ESC> 20ms] dns: exchanged ...`.
    // Старый паттерн `\[[0-9;]*[A-Za-z]` искал `[…<letter>` — голый ESC не ловил
    // вообще, и `<ESC>` доезжали до Dart, ломая DNS-regex профайлера
    // (`\[(\d+)` не матчит `[` + ESC). Теперь срезаем: полные CSI-последователь-
    // ности (`ESC[…m`) И любые одиночные ESC-байты. Скобки `[0617]`/`[connId ms]`
    // (НЕ ANSI, нужны парсеру) сохраняются.
    private val ansiEscapeRe = Regex("\\u001B\\[[0-9;]*[A-Za-z]|\\u001B")
    private val traceDebugRe = Regex("\\b(TRACE|DEBUG)\\b")

    /// Cap размера очереди — `4096 * ~80 chars ≈ 320KB` worst case в queue.
    /// Drop newest при переполнении (sing-box producer thread не блокируется).
    private val LOG_QUEUE_MAX = 4096

    /// Сколько строк drainer отдаёт за один main-looper run перед yield'ом.
    /// 200 строк ≈ 1 frame (~16ms) при типичной marshal-цене.
    private val DRAIN_BATCH_MAX = 200

    private val coreLogQueue: java.util.concurrent.LinkedBlockingQueue<String> by lazy {
        java.util.concurrent.LinkedBlockingQueue()
    }
    private val drainerScheduled = java.util.concurrent.atomic.AtomicBoolean(false)
    private val coreLogDrops = java.util.concurrent.atomic.AtomicLong(0)

    /// **F22 single Runnable** — создаётся ОДИН раз при first access (lazy),
    /// reused на каждый `Handler.post(coreLogDrainer)`. Никаких per-call
    /// Lambda/anonymous class allocations. Hold strong ref в field.
    ///
    /// Drains до `DRAIN_BATCH_MAX` строк, эмитит как `List<String>` одним
    /// JNI вызовом, потом если queue не пустой — re-post (yield для frame).
    private val coreLogDrainer: Runnable by lazy {
        Runnable {
            drainerScheduled.set(false)
            val sink = BoxVpnService.coreLogSink ?: run { coreLogQueue.clear(); return@Runnable }
            val batch = ArrayList<String>(DRAIN_BATCH_MAX.coerceAtMost(64))
            var taken = 0
            while (taken < DRAIN_BATCH_MAX) {
                val line = coreLogQueue.poll() ?: break
                batch.add(line)
                taken++
            }
            if (batch.isNotEmpty()) {
                runCatching { sink.success(batch) }
            }
            // Если queue ещё что-то держит — re-schedule, не блочим main looper.
            if (coreLogQueue.isNotEmpty() &&
                drainerScheduled.compareAndSet(false, true)) {
                coreLogMainHandler.post(coreLogDrainer)
            }
        }
    }

    private val coreLogMainHandler by lazy {
        android.os.Handler(android.os.Looper.getMainLooper())
    }

    /// `sendNotification` (spec §036) — system notification с clickable ссылкой.
    /// Sing-box зовёт `sendNotification` через PlatformInterface (на BoxVpnService),
    /// который форвардит сюда.
    fun sendNotification(notification: io.nekohasekai.libbox.Notification) {
        val context = service.applicationContext
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

        val channelId = notification.identifier.ifBlank { "lxbox-core" }
        val channelName = notification.typeName.ifBlank {
            L10n.str(context, R.string.core_channel_fallback_name)
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                channelId,
                channelName,
                NotificationManager.IMPORTANCE_HIGH,
            )
            nm.createNotificationChannel(channel)
        }

        val pendingIntent: PendingIntent? = if (notification.openURL.isNotBlank()) {
            runCatching {
                val intent = Intent(Intent.ACTION_VIEW, Uri.parse(notification.openURL)).apply {
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
                PendingIntent.getActivity(
                    context,
                    notification.typeID,
                    intent,
                    PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
                )
            }.getOrNull()
        } else null

        val builder = NotificationCompat.Builder(context, channelId)
            .setSmallIcon(android.R.drawable.ic_lock_lock)
            .setContentTitle(notification.title)
            .setContentText(notification.body)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setAutoCancel(true)
        if (notification.subtitle.isNotBlank()) {
            builder.setSubText(notification.subtitle)
        }
        if (pendingIntent != null) {
            builder.setContentIntent(pendingIntent)
        }

        runCatching {
            nm.notify(notification.typeID, builder.build())
        }.onFailure {
            Log.e(TAG, "sendNotification.notify failed", it)
        }

        Log.d(TAG, "Notification: ${notification.title} → ${notification.openURL}")
        commandServer.get()?.writeMessage(
            0,
            "platform notification: ${notification.title} (${notification.openURL})",
        )
    }

    /// `cancelNotification` — парный к [sendNotification] (появился в
    /// PlatformInterface ядра lx.27-rc.2 вслед за апстримом). Снимаем ровно то
    /// уведомление, которое поставил `sendNotification`: там `nm.notify` берёт
    /// `typeID` как id, значит и отменяем по `typeID`. `identifier` (id канала)
    /// ядро передаёт для платформ, где отмена адресуется иначе; на Android он
    /// в адресации не участвует.
    fun cancelNotification(identifier: String, typeID: Int) {
        val context = service.applicationContext
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        runCatching {
            nm.cancel(typeID)
        }.onFailure {
            Log.e(TAG, "cancelNotification failed", it)
        }
        Log.d(TAG, "Notification cancelled: $identifier/$typeID")
    }
}
