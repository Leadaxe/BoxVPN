package com.leadaxe.lxbox.vpn

import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager.NameNotFoundException
import android.net.ProxyInfo
import android.net.VpnService
import android.os.Build
import android.os.IBinder
import android.os.SystemClock
import android.util.Log
import java.io.File
import androidx.core.content.ContextCompat
import io.nekohasekai.libbox.TunOptions
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeout

/// §049 F1 split (mirror reference SagerNet 1.13.11).
///
/// `BoxVpnService` — Android `VpnService` + `PlatformInterfaceWrapper` (PI only).
/// Хранит `service: BoxService` в field initializer и форвардит Android
/// lifecycle callbacks в `service.X()`. Весь state и CSH-implementation
/// живут в `BoxService` — это даёт `CommandServer(this, platformInterface)`
/// с двумя разными Java instance, как у reference.
class BoxVpnService : VpnService(), PlatformInterfaceWrapper {

    companion object {
        private const val TAG = "BoxVpnService"
        const val ACTION_START = "com.leadaxe.lxbox.ACTION_START"
        const val ACTION_STOP = "com.leadaxe.lxbox.ACTION_STOP"
        /// §129 — force-stop при зависшем-вхолостую ядре (см. BoxService.doForceStop).
        const val ACTION_FORCE_STOP = "com.leadaxe.lxbox.ACTION_FORCE_STOP"
        const val ACTION_RELOAD = "com.leadaxe.lxbox.ACTION_RELOAD"
        const val ACTION_RESET_NETWORK = "com.leadaxe.lxbox.ACTION_RESET_NETWORK"
        /// §263 — сброс DNS-кэша: удалить cache.db + reload (если running).
        const val ACTION_CLEAR_DNS_CACHE = "com.leadaxe.lxbox.ACTION_CLEAR_DNS_CACHE"
        /// §182 — кнопка Reconnect в foreground-уведомлении: native-side
        /// reconnect (stopAwait→start), переживает убитый UI-движок.
        const val ACTION_RECONNECT = "com.leadaxe.lxbox.ACTION_RECONNECT"
        /// §223 — live-перерисовка лейблов уведомления при смене ноды (#20).
        const val ACTION_UPDATE_NOTIFICATION = "com.leadaxe.lxbox.ACTION_UPDATE_NOTIFICATION"
        /// §430 — запасной путь снятия зависшего уведомления: поднять сервис
        /// в foreground с тем же id и штатно остановить — AMS снимет сам.
        const val ACTION_CLEAR_STALE_NOTIFICATION = "com.leadaxe.lxbox.ACTION_CLEAR_STALE_NOTIFICATION"

        /// §430 — снять уведомление, зависшее от умершего сервиса (см.
        /// `ServiceNotification.isStalePresent`): короткий foreground-старт/стоп
        /// сервиса под тем же id — запись сервиса снова владеет уведомлением,
        /// и AMS снимает его в bringDownServiceLocked. Зовётся из
        /// MainActivity.onCreate: юзер открыл приложение и видит ложь в шторке.
        /// Без POST_NOTIFICATIONS (API 33+) утечки не бывает — система такое
        /// уведомление и не показывает.
        fun clearStaleNotification(context: Context) {
            if (currentStatus != VpnStatus.Stopped) return
            if (!ServiceNotification.isStalePresent()) return
            Log.w(TAG, "[vpn §430] stale FGS notification from a dead service — bouncing service so AMS cancels it")
            val intent = Intent(context, BoxVpnService::class.java)
                .apply { action = ACTION_CLEAR_STALE_NOTIFICATION }
            runCatching { ContextCompat.startForegroundService(context, intent) }
                .onFailure { Log.w(TAG, "[vpn §430] bounce start failed: $it") }
        }
        const val BROADCAST_STATUS = "com.leadaxe.lxbox.BROADCAST_STATUS"
        const val EXTRA_STATUS = "status"

        /// §415 — бюджет ожидания штатной остановки (`stopAwait` → setStatus(Stopped)).
        ///
        /// Лестница бюджетов, СТРОГО по возрастанию — иначе внешний слой объявит
        /// таймаут раньше внутреннего и юзер получит ложную ошибку при успешной
        /// остановке:
        ///
        ///   нативный `STOP_AWAIT_TIMEOUT_MS` (9с)
        ///     < Dart `_Timeouts.stopVpn` (10с, `app/lib/vpn/box_vpn_client/timeouts.dart`)
        ///
        /// Зазор в 1с — на доставку результата обратно через MethodChannel
        /// (сериализация + hop на Flutter-поток). Если бы бюджеты совпали, Dart
        /// успел бы отвалиться по таймауту ПЕРВЫМ и `stopVPN()` бросил бы
        /// TimeoutException вместо честного `false` — та же ложная ошибка,
        /// только с другой стороны.
        ///
        /// Почему 9с, а не прежние 5с: device-замер (эмулятор, AWG/WARP-эндпоинт
        /// + ~25 живых соединений) показал реальный teardown 5.2с — `closeFileDescriptor`
        /// один занимает ~1.95с, плюс завершение WireGuard-устройства. 5с резали
        /// успешную остановку на самом финише. 9с — заведомо больше худшего
        /// наблюдаемого teardown'а, но всё ещё меньше Dart-бюджета.
        const val STOP_AWAIT_TIMEOUT_MS = 9_000L

        /// §276 — признак «туннель отобрало другое VPN-приложение». Едет рядом с
        /// EXTRA_STATUS=Stopped, а НЕ отдельным значением VpnStatus: revoke —
        /// терминальное состояние, и весь teardown (stopCompleter, onStartCommand
        /// guard, isForeignVpnActive) завязан на `== Stopped`. Отдельный статус
        /// подвесил бы stopVPN до таймаута (§224: setStatus(Stopped) —
        /// единственная детерминированная точка всех teardown-путей).
        const val EXTRA_REVOKED = "revoked"

        /// Mirror of the live service status, readable from anywhere.
        /// VpnPlugin.getVpnStatus читает это чтобы Flutter мог пересинхрониться
        /// после re-attach (process killed но service выжил из-за keep-on-exit).
        @Volatile
        var currentStatus: VpnStatus = VpnStatus.Stopped
            private set

        /// §069: snapshot значения `allow_bypass` при последнем `establish()`.
        /// Отражает то что **сейчас applied** в `VpnService.Builder.allowBypass()`,
        /// в отличие от persisted `BootReceiver.isAllowBypass()` который меняется
        /// до `establish()` reload. Reset в `onDestroy()` чтобы UI warning исчезал
        /// когда service умирает.
        @Volatile
        var currentSessionAllowBypass: Boolean = false
            private set

        /// §187 — время старта туннеля (`SystemClock.elapsedRealtime()`,
        /// монотонные часы — не прыгают при смене системного времени/таймзоны).
        /// PERSISTENT companion → переживает swipe (туннель keep-alive не
        /// перезапускался) → даёт честный uptime после cold-start, когда Dart-
        /// `connectedSince` обнулился бы на «сейчас». 0 = не запущен.
        @Volatile
        var tunnelStartedElapsedMs: Long = 0L
            private set

        /// §276 — зеркало «последний Stopped пришёл из onRevoke». Нужно для
        /// pull-пути (`getVpnStatus` на resume): broadcast'ятся только переходы,
        /// и без этого поля UI, вернувшийся из фона после перехвата, увидел бы
        /// голый Stopped и показал нейтральный Disconnected (кейс, помеченный
        /// в §003 как «намеренно не покрыто»).
        @Volatile
        var currentRevoked: Boolean = false
            private set

        /// Internal — для BoxService.setStatus() обновлять companion-state.
        internal fun setCurrentStatus(s: VpnStatus, revoked: Boolean = false) {
            currentStatus = s
            // §276 — Starting/Started снимают метку: туннель снова наш. На
            // Stopped метка приходит из setStatus (true только от onRevoke).
            currentRevoked = when (s) {
                VpnStatus.Starting, VpnStatus.Started -> false
                else -> revoked
            }
            // §187 — фиксируем старт ОДИН раз на переходе в Started (не
            // перетирать при дедуп-повторе). Сброс на Stopped → uptime обнулится.
            when (s) {
                VpnStatus.Started ->
                    if (tunnelStartedElapsedMs == 0L) {
                        tunnelStartedElapsedMs = SystemClock.elapsedRealtime()
                    }
                VpnStatus.Stopped -> tunnelStartedElapsedMs = 0L
                else -> { /* Starting/Stopping — не трогаем */ }
            }
        }

        /// §361 — жив ли ACTION_STOP-приёмник (ведёт `BoxService` в паре с своим
        /// `receiverRegistered`). `stopAwait` шлёт стоп широковещательно, и без
        /// этого признака у него нет способа отличить «сервис работает, сейчас
        /// остановится» от «принимать некому» — во втором случае он честно ждал
        /// свои 5 секунд и возвращал false.
        @Volatile
        var stopReceiverAlive: Boolean = false
            private set

        internal fun setStopReceiverAlive(alive: Boolean) {
            stopReceiverAlive = alive
        }

        /// Completer для `stopAwait` — completes когда `setStatus(Stopped)`
        /// отработал, т.е. все cleanup стадии завершились.
        @Volatile
        private var stopCompleter: CompletableDeferred<Unit>? = null

        /// Internal — BoxService.setStatus() при переходе в Stopped зовёт этот.
        internal fun completeStopIfWaiting() {
            stopCompleter?.complete(Unit)
            stopCompleter = null
        }

        /// §043: Sink для core logs от sing-box → Flutter EventChannel.
        @Volatile
        var coreLogSink: io.flutter.plugin.common.EventChannel.EventSink? = null

        /// §122 Фаза 0 — sink'и нового CommandClient-канала (`BoxCommandClient`).
        /// Инвариант §2.1: эмиттер живёт во Flutter-процессе (как `coreLogSink`).
        @Volatile
        var ccStatusSink: io.flutter.plugin.common.EventChannel.EventSink? = null
        @Volatile
        var ccOutboundsSink: io.flutter.plugin.common.EventChannel.EventSink? = null
        @Volatile
        var ccGroupsSink: io.flutter.plugin.common.EventChannel.EventSink? = null
        @Volatile
        var ccConnectionsSink: io.flutter.plugin.common.EventChannel.EventSink? = null
        /// §180 — DNS-журнал из ядра (SPEC 018). Батч-доставка списком CcDnsQuery.
        @Volatile
        var ccDnsQueriesSink: io.flutter.plugin.common.EventChannel.EventSink? = null

        fun start(context: Context) {
            Log.d(TAG, "[vpn] companion.start() → startForegroundService, current status=${currentStatus.name}")
            val intent = Intent(context, BoxVpnService::class.java).apply { action = ACTION_START }
            ContextCompat.startForegroundService(context, intent)
        }

        fun stop(context: Context) {
            Log.d(TAG, "[vpn] companion.stop() → sendBroadcast(ACTION_STOP), current status=${currentStatus.name}")
            context.sendBroadcast(
                Intent(ACTION_STOP).setPackage(context.packageName)
            )
        }

        /// §129 — fire-and-forget force-stop: НЕ ждём `setStatus(Stopped)` от
        /// ядра (оно зависло вхолостую — detour AWG→WG, #2). Шлёт ACTION_FORCE_STOP;
        /// `BoxService.doForceStop` сразу делает `stopSelf()`, teardown ядра — фоном
        /// best-effort. В отличие от `stopAwait` — НЕ возвращает Deferred (ждать
        /// нечего: ядро Stopped не отдаст).
        fun forceStop(context: Context) {
            Log.w(TAG, "[vpn] companion.forceStop() → sendBroadcast(ACTION_FORCE_STOP), current status=${currentStatus.name}")
            context.sendBroadcast(
                Intent(ACTION_FORCE_STOP).setPackage(context.packageName)
            )
        }

        fun reload(context: Context) {
            Log.d(TAG, "[vpn] companion.reload() current status=${currentStatus.name}")
            context.sendBroadcast(
                Intent(ACTION_RELOAD).setPackage(context.packageName)
            )
        }

        fun resetNetwork(context: Context) {
            Log.d(TAG, "[vpn] companion.resetNetwork() current status=${currentStatus.name}")
            context.sendBroadcast(
                Intent(ACTION_RESET_NETWORK).setPackage(context.packageName)
            )
        }

        /// §263 — сброс DNS-кэша. Running: broadcast → receiver удалит cache.db
        /// в правильном окне и reload'нёт (ядро создаст чистый). Off: broadcast
        /// некому ловить (receiver жив только у работающего сервиса) → удаляем
        /// файл прямо здесь; чистый cache.db создастся при следующем старте.
        fun clearDnsCache(context: Context) {
            Log.d(TAG, "[vpn] companion.clearDnsCache() current status=${currentStatus.name}")
            if (currentStatus == VpnStatus.Started ||
                currentStatus == VpnStatus.Starting
            ) {
                context.sendBroadcast(
                    Intent(ACTION_CLEAR_DNS_CACHE).setPackage(context.packageName)
                )
            } else {
                deleteCacheDbFile()
            }
        }

        /// §263 — удалить cache.db (FakeIP-аллокации + DNS RDRC). Путь =
        /// `filesDir/cache.db` (basePath ядра, см. BoxApplication.setup).
        /// Идемпотентно: нет файла (свежая установка / уже чисто) → no-op.
        internal fun deleteCacheDbFile() {
            val f = File(BoxApplication.application.filesDir, "cache.db")
            if (!f.exists()) {
                Log.i(TAG, "[dns] cache.db absent — nothing to clear")
                return
            }
            val ok = runCatching { f.delete() }.getOrDefault(false)
            Log.i(TAG, "[dns] cache.db delete=$ok (${f.absolutePath})")
        }

        /// §223 — попросить работающий сервис перерисовать foreground-уведомление
        /// свежими лейблами из ConfigManager (#20: смена ноды без рестарта).
        /// Вне Started — no-op: receiver зарегистрирован только у живого сервиса,
        /// а его обработчик дополнительно гейтит рендер на Started; закэшированные
        /// лейблы подхватит обычный connect-рендер.
        fun updateNotification(context: Context) {
            context.sendBroadcast(
                Intent(ACTION_UPDATE_NOTIFICATION).setPackage(context.packageName)
            )
        }

        fun stopAwait(context: Context): Deferred<Unit> {
            Log.d(TAG, "[vpn] companion.stopAwait() current status=${currentStatus.name}")
            if (currentStatus == VpnStatus.Stopped) {
                return CompletableDeferred(Unit)
            }
            // §361 — статус не Stopped, но принимать ACTION_STOP некому: сервис
            // уже уничтожен, а статус остался «живым» (запоздавший setStatus от
            // отменённого старта — корень закрыт в BoxService, это второй эшелон
            // на случай другого пути рассинхрона). Broadcast ушёл бы в пустоту, а
            // вызывающий висел бы 5 секунд ради `false` и мёртвой кнопки «Стоп».
            // Приводим companion-состояние к правде и отвечаем сразу.
            if (!stopReceiverAlive) {
                Log.w(TAG, "[vpn §361] stopAwait: no live receiver (status=${currentStatus.name}) — force Stopped")
                setCurrentStatus(VpnStatus.Stopped)
                runCatching {
                    context.sendBroadcast(
                        Intent(BROADCAST_STATUS)
                            .setPackage(context.packageName)
                            .putExtra(EXTRA_STATUS, VpnStatus.Stopped.name)
                    )
                }
                completeStopIfWaiting()
                return CompletableDeferred(Unit)
            }
            val completer = CompletableDeferred<Unit>()
            stopCompleter?.cancel()
            stopCompleter = completer
            context.sendBroadcast(
                Intent(ACTION_STOP).setPackage(context.packageName)
            )
            return completer
        }

        /// §182 — process-level scope для reconnect-цепочки stopAwait→start.
        /// НЕ на serviceScope: doStop()→stopSelf()→onDestroy отменил бы serviceScope
        /// до того как мы дождёмся Stopped и сделаем новый start. Живёт на уровне
        /// процесса (companion), как stopCompleter; не отменяется нигде (лёгкий:
        /// одна короткоживущая корутина за reconnect).
        private val reconnectScope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

        /// §182 — guard от двойного reconnect'а (двойной тап по кнопке в шторке).
        @Volatile
        private var reconnecting: Boolean = false

        /// §182 — native-side reconnect для кнопки Reconnect в уведомлении.
        /// = stopAwait() (дождаться полного Stopped) → start() (новый
        /// startForegroundService). Через stopAwait, а НЕ «doStop()+сразу start()»:
        /// ранний start попал бы в onStartCommand guard (status != Stopped → silent
        /// return) и сервис не перезапустился бы (тот же race, что §002 закрыл для
        /// Dart-пути). Работает с убитым UI-движком — путь полностью native.
        ///
        /// JNI no-throw (§141/§151): зовётся из BroadcastReceiver; тело защищено,
        /// наружу не бросаем.
        fun reconnect(context: Context) {
            Log.d(TAG, "[vpn] companion.reconnect() current status=${currentStatus.name}")
            if (reconnecting) {
                Log.w(TAG, "[vpn] reconnect already in progress — ignore")
                return
            }
            if (currentStatus == VpnStatus.Stopped) {
                start(context)   // нечего останавливать — просто старт
                return
            }
            reconnecting = true
            reconnectScope.launch {
                val stopped = try {
                    // §415 — тот же teardown, что и в обычном stop ⇒ тот же бюджет
                    // (был свой литерал 6с — резал успешную остановку на 5.2с).
                    withTimeout(STOP_AWAIT_TIMEOUT_MS) { stopAwait(context).await(); true }
                } catch (t: Throwable) {
                    Log.w(TAG, "[vpn] reconnect: stop phase failed/timeout: ${t.message}")
                    false
                }
                if (stopped) {
                    start(context)   // startForegroundService(ACTION_START)
                } else {
                    // D-1: stop не подтвердился — НЕ стартуем поверх (избегаем
                    // guard-залипания). Юзер увидит что VPN не поднялся, повторит.
                    Log.w(TAG, "[vpn] reconnect aborted — stop not confirmed")
                }
                reconnecting = false
            }
        }
    }

    /// §049 F1 — field initializer (как `VPNService.kt:26` reference): инстанс
    /// создаётся при создании Android Service, до onCreate(). Это держит
    /// strong-ref на `platformInterface (= this)` через `private val` в
    /// BoxService — препятствует преждевременному GC Go-side wrapper'а.
    private val service = BoxService(this, this)

    /// §049 F17 — state HTTP-proxy для `BoxService.getSystemProxyStatus()`.
    @JvmField var systemProxyAvailable = false
    @JvmField var systemProxyEnabled = false

    // -------------------------------------------------------------------------
    // Android lifecycle — forward в BoxService
    // -------------------------------------------------------------------------

    override fun onCreate() {
        super.onCreate()
        service.onCreate()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        return service.onStartCommand(intent, flags, startId)
    }

    override fun onBind(intent: Intent): IBinder? = super.onBind(intent) ?: android.os.Binder()

    override fun onDestroy() {
        service.onDestroy()
        // §069: runtime applied значение больше не действует — clear snapshot
        // чтобы Stats screen warning исчез при stop VPN.
        currentSessionAllowBypass = false
        super.onDestroy()
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        service.onTaskRemoved(rootIntent)
        super.onTaskRemoved(rootIntent)
    }

    override fun onRevoke() {
        service.onRevoke()
        super.onRevoke()
    }

    // -------------------------------------------------------------------------
    // PlatformInterfaceWrapper overrides — VPN-specific
    // -------------------------------------------------------------------------

    override fun autoDetectInterfaceControl(fd: Int) {
        protect(fd)
    }

    override fun openTun(options: TunOptions): Int {
        if (prepare(this) != null) error("android: missing vpn permission")

        val builder = Builder()
            .setSession("sing-box")
            .setMtu(options.mtu)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) builder.setMetered(false)

        // §049 F15: allowBypass opt-in toggle.
        // §069: snapshot runtime applied value для UI warning + Debug API.
        val allowBypass = BootReceiver.isAllowBypass(this)
        currentSessionAllowBypass = allowBypass
        if (allowBypass) {
            builder.allowBypass()
        }

        val inet4 = options.inet4Address
        while (inet4.hasNext()) { val a = inet4.next(); builder.addAddress(a.address(), a.prefix()) }
        val inet6 = options.inet6Address
        while (inet6.hasNext()) { val a = inet6.next(); builder.addAddress(a.address(), a.prefix()) }

        if (options.autoRoute) {
            // libbox 1.14: dnsServerAddress стал StringIterator (раньше — одиночный
            // OptionalString с .value). Добавляем все объявленные ядром DNS-сервера.
            val dnsServers = options.dnsServerAddress
            while (dnsServers.hasNext()) {
                val dns = dnsServers.next()
                if (dns.isNotEmpty()) builder.addDnsServer(dns)
            }

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                val r4 = options.inet4RouteAddress
                if (r4.hasNext()) { while (r4.hasNext()) builder.addRoute(r4.next().toIpPrefix()) }
                else if (options.inet4Address.hasNext()) builder.addRoute("0.0.0.0", 0)

                val r6 = options.inet6RouteAddress
                if (r6.hasNext()) { while (r6.hasNext()) builder.addRoute(r6.next().toIpPrefix()) }
                else if (options.inet6Address.hasNext()) builder.addRoute("::", 0)

                val x4 = options.inet4RouteExcludeAddress
                while (x4.hasNext()) builder.excludeRoute(x4.next().toIpPrefix())
                val x6 = options.inet6RouteExcludeAddress
                while (x6.hasNext()) builder.excludeRoute(x6.next().toIpPrefix())
            } else {
                val r4 = options.inet4RouteRange
                if (r4.hasNext()) { while (r4.hasNext()) { val a = r4.next(); builder.addRoute(a.address(), a.prefix()) } }
                val r6 = options.inet6RouteRange
                if (r6.hasNext()) { while (r6.hasNext()) { val a = r6.next(); builder.addRoute(a.address(), a.prefix()) } }
            }

            val incl = options.includePackage
            if (incl.hasNext()) { while (incl.hasNext()) { try { builder.addAllowedApplication(incl.next()) } catch (_: NameNotFoundException) {} } }
            val excl = options.excludePackage
            if (excl.hasNext()) { while (excl.hasNext()) { try { builder.addDisallowedApplication(excl.next()) } catch (_: NameNotFoundException) {} } }
        }

        // §049 F17: треккаем state HTTP-proxy для CommandServerHandler.getSystemProxyStatus.
        if (options.isHTTPProxyEnabled && Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            systemProxyAvailable = true
            systemProxyEnabled = true
            builder.setHttpProxy(
                ProxyInfo.buildDirectProxy(
                    options.httpProxyServer,
                    options.httpProxyServerPort,
                    options.httpProxyBypassDomain.toList()
                )
            )
        } else {
            systemProxyAvailable = false
            systemProxyEnabled = false
        }

        val pfd = builder.establish() ?: error("android: the application is not prepared or is revoked")
        // §329 — номер fd + монотонная метка. Ядро дуплицирует этот fd
        // (`libbox/service.go` dup) и раздаёт номера дальше; при переиспользовании
        // номера чужой close бьёт в Go-сокет листенера sing-tun (§047). Пара
        // «выдан / закрыт» по номеру и времени — единственный способ это увидеть:
        // fdsan молчит, жертва нетегирована. Уровень `w`: виден под дефолтным
        // порогом logcat, ничего не надо помнить про фильтр при разборе случая.
        Log.w(TAG, "[fd §329] openTun fd=${pfd.fd} at=${SystemClock.elapsedRealtime()}ms")
        // **§049 F1**: state живёт в BoxService — храним там.
        // §329 — ЗАКРЫТЬ предыдущий PFD, а не просто затереть ссылку. Reload идёт
        // мимо путей остановки (`closeFileDescriptor` зовётся только из
        // doStop/doForceStop/onRevoke/onDestroy): ядро в `StartOrReloadService`
        // само закрывает старый instance и сразу зовёт `openTun` заново. При
        // простом `set` старый PFD осиротевал незакрытым, и его закрывал
        // CloseGuard-финализатор при GC — по номеру и в произвольный момент,
        // когда номер уже принадлежит листенеру НОВОГО стека (§047: листенер
        // умирает, `accept4` → EINVAL, весь новый TCP получает RST). Плюс это
        // была утечка fd на каждом reload. Паттерн — как в `closeFileDescriptor`
        // (§049 F2): порядок безопасен, `oldInstance.Close()` завершается
        // синхронно до `openTun`, т.е. ядро свой dup уже отпустило.
        service.fileDescriptor.getAndSet(pfd)?.runCatching { close() }
            ?.onFailure { Log.w(TAG, "[fd §329] stale pfd close failed: ${it.message}") }
        return pfd.fd
    }

    override fun protect(fd: Int): Boolean = super.protect(fd)

    /// `sendNotification` форвард в `service` — там логика построения Android Notification.
    override fun sendNotification(notification: io.nekohasekai.libbox.Notification) {
        service.sendNotification(notification)
    }

    /// `cancelNotification` — парный форвард (PlatformInterface ядра lx.27-rc.2).
    override fun cancelNotification(identifier: String, typeID: Int) {
        service.cancelNotification(identifier, typeID)
    }
}
