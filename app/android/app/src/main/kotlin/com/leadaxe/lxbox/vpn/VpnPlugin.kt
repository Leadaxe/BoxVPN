package com.leadaxe.lxbox.vpn

import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.NetworkCapabilities
import android.net.VpnService
import android.os.Build
import android.os.SystemClock
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout

class VpnPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, ActivityAware,
    PluginRegistry.ActivityResultListener {

    companion object {
        private const val TAG = "VpnPlugin"
        private const val METHOD_CHANNEL = "com.leadaxe.lxbox/methods"
        private const val STATUS_CHANNEL = "com.leadaxe.lxbox/status_events"
        private const val CORE_LOG_CHANNEL = "lxbox/coreLog"   // §043
        // §122 Фаза 0 — каналы CommandClient.
        private const val CC_STATUS_CHANNEL = "lxbox/cc/status"
        private const val CC_OUTBOUNDS_CHANNEL = "lxbox/cc/outbounds"
        private const val CC_GROUPS_CHANNEL = "lxbox/cc/groups"
        private const val CC_CONNECTIONS_CHANNEL = "lxbox/cc/connections"
        private const val CC_DNS_CHANNEL = "lxbox/cc/dns" // §180
        private const val VPN_REQUEST_CODE = 24

        // §207 — allowlist имён pprof-профилей (до `?`). Пропускаем наружу
        // только их, не произвольный path. Зеркало Go net/http/pprof.
        private val PPROF_PROFILES = setOf(
            "goroutine", "profile", "heap", "allocs",
            "block", "mutex", "threadcreate",
        )

        // §047 — статические ссылки для bridge'а из LxBoxIntentReceiver (он
        // живёт вне Flutter-плагина). Заполняются в onAttachedToEngine,
        // обнуляются в onDetachedFromEngine. null = Flutter-engine не активен.
        @Volatile
        private var bridgeChannel: MethodChannel? = null
        @Volatile
        private var appContext: Context? = null
        private val bridgeHandler =
            android.os.Handler(android.os.Looper.getMainLooper())

        /// §047 incoming bridge: LxBoxIntentReceiver форвардит intent-action +
        /// extras → Dart (`box_vpn_client` `automationAction` handler) → shared
        /// action-handlers. Если engine не запущен — silently skip.
        fun handleAutomationAction(name: String, args: Map<String, Any?>) {
            val channel = bridgeChannel
            if (channel == null) {
                Log.w(TAG, "[automation] handleAutomationAction($name) — no Flutter engine, skip")
                return
            }
            bridgeHandler.post {
                runCatching {
                    channel.invokeMethod(
                        "automationAction",
                        mapOf("name" to name, "args" to args),
                    )
                }.onFailure {
                    Log.e(TAG, "[automation] invokeMethod(automationAction) failed", it)
                }
            }
        }

        /// §047 outgoing emit: Dart (`AutomationEventEmitter`) шлёт событие
        /// наружу. action — короткое имя (`VPN_CONNECTED`), namespace'ится в
        /// `com.leadaxe.lxbox.event.<action>`. Открыт всем подписчикам — события
        /// не содержат секретов (только лейблы: теги нод, группы, статус); см.
        /// §157 (permission-фильтр удалён вместе с нерабочей галкой).
        fun sendAutomationBroadcast(action: String, extras: Map<String, Any?>) {
            val ctx = appContext ?: return
            val intent = Intent("com.leadaxe.lxbox.event.$action")
            for ((k, v) in extras) {
                when (v) {
                    null -> {}
                    is String -> intent.putExtra(k, v)
                    is Boolean -> intent.putExtra(k, v)
                    is Int -> intent.putExtra(k, v)
                    is Long -> intent.putExtra(k, v)
                    is Double -> intent.putExtra(k, v)
                    else -> intent.putExtra(k, v.toString())
                }
            }
            // setPackage намеренно не выставляем — broadcast открыт всем
            // подписчикам (события без секретов, только лейблы).
            ctx.sendBroadcast(intent)
            Log.d(TAG, "[automation] emit $action (${extras.size} extras)")
        }
    }

    private lateinit var methodChannel: MethodChannel
    private lateinit var statusEventChannel: EventChannel
    private lateinit var coreLogEventChannel: EventChannel
    /// §122 Фаза 0 — EventChannel'ы нового CommandClient-канала.
    private lateinit var ccStatusEventChannel: EventChannel
    private lateinit var ccOutboundsEventChannel: EventChannel
    private lateinit var ccGroupsEventChannel: EventChannel
    private lateinit var ccConnectionsEventChannel: EventChannel
    private lateinit var ccDnsEventChannel: EventChannel // §180
    private lateinit var context: Context
    private var activity: Activity? = null
    private var statusSink: EventChannel.EventSink? = null
    private var pendingVpnResult: MethodChannel.Result? = null
    private val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())

    /// Scope для suspend-обработчиков method channel — сейчас нужен только
    /// для stopVPN (async wait на setStatus(Stopped)), но переиспользуем
    /// для любых будущих awaitable операций. Отменяется в onDetachedFromEngine.
    private val pluginScope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    private val statusReceiver = object : BroadcastReceiver() {
        override fun onReceive(ctx: Context?, intent: Intent?) {
            if (intent?.action != BoxVpnService.BROADCAST_STATUS) return
            val name = intent.getStringExtra(BoxVpnService.EXTRA_STATUS) ?: return
            val error = intent.getStringExtra("error")
            // §276 — признак перехвата слота чужим VPN (едет рядом со Stopped).
            val revoked = intent.getBooleanExtra(BoxVpnService.EXTRA_REVOKED, false)
            Log.d(TAG, "[vpn] plugin.statusReceiver.onReceive name=$name${if (error != null) " error=$error" else ""}${if (revoked) " revoked=true" else ""} sink=${statusSink != null}")
            mainHandler.post {
                val event = mutableMapOf<String, Any>("status" to name)
                if (error != null) event["error"] = error
                if (revoked) event[BoxVpnService.EXTRA_REVOKED] = true
                // §155 — sink может указывать на мёртвый Dart-engine (process
                // killed / engine detached между post и доставкой). success()
                // тогда бросает DeadObjectException на main thread → краш всего
                // приложения. Глотаем: статус всё равно пере-эмитится при
                // следующем onListen после реконнекта.
                runCatching { statusSink?.success(event) }
                    .onFailure { Log.w(TAG, "[vpn] statusSink.success failed: $it") }
            }
        }
    }

    // -------------------------------------------------------------------------
    // FlutterPlugin
    // -------------------------------------------------------------------------

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        Log.d(TAG, "onAttachedToEngine")
        context = binding.applicationContext
        BoxApplication.initialize(context)

        methodChannel = MethodChannel(binding.binaryMessenger, METHOD_CHANNEL)
        methodChannel.setMethodCallHandler(this)
        // §047 — статические bridge-ссылки для LxBoxIntentReceiver.
        bridgeChannel = methodChannel
        appContext = context

        statusEventChannel = EventChannel(binding.binaryMessenger, STATUS_CHANNEL)
        statusEventChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(args: Any?, sink: EventChannel.EventSink?) {
                Log.d(TAG, "[vpn] statusEventChannel.onListen — sink installed")
                statusSink = sink
            }
            override fun onCancel(args: Any?) {
                Log.d(TAG, "[vpn] statusEventChannel.onCancel — sink cleared")
                statusSink = null
            }
        })

        // §043: core log pump из sing-box. Sing-box логи приходят через
        // PlatformInterface.writeDebugMessage в BoxVpnService → coreLogSink
        // (Volatile companion field) → этот EventChannel → ClashLogPump в Dart.
        coreLogEventChannel = EventChannel(binding.binaryMessenger, CORE_LOG_CHANNEL)
        coreLogEventChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(args: Any?, sink: EventChannel.EventSink?) {
                Log.d(TAG, "[vpn] coreLogEventChannel.onListen — sink installed")
                BoxVpnService.coreLogSink = sink
            }
            override fun onCancel(args: Any?) {
                Log.d(TAG, "[vpn] coreLogEventChannel.onCancel — sink cleared")
                BoxVpnService.coreLogSink = null
            }
        })

        // §122 Фаза 0 — 4 канала CommandClient (status/outbounds/groups/connections).
        // BoxCommandClient.handler пушит снапшоты в BoxVpnService.cc*Sink → сюда → Dart.
        ccStatusEventChannel = EventChannel(binding.binaryMessenger, CC_STATUS_CHANNEL)
        ccStatusEventChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(args: Any?, sink: EventChannel.EventSink?) { BoxVpnService.ccStatusSink = sink }
            override fun onCancel(args: Any?) { BoxVpnService.ccStatusSink = null }
        })
        ccOutboundsEventChannel = EventChannel(binding.binaryMessenger, CC_OUTBOUNDS_CHANNEL)
        ccOutboundsEventChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(args: Any?, sink: EventChannel.EventSink?) { BoxVpnService.ccOutboundsSink = sink }
            override fun onCancel(args: Any?) { BoxVpnService.ccOutboundsSink = null }
        })
        ccGroupsEventChannel = EventChannel(binding.binaryMessenger, CC_GROUPS_CHANNEL)
        ccGroupsEventChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(args: Any?, sink: EventChannel.EventSink?) { BoxVpnService.ccGroupsSink = sink }
            override fun onCancel(args: Any?) { BoxVpnService.ccGroupsSink = null }
        })
        ccConnectionsEventChannel = EventChannel(binding.binaryMessenger, CC_CONNECTIONS_CHANNEL)
        ccConnectionsEventChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(args: Any?, sink: EventChannel.EventSink?) {
                BoxVpnService.ccConnectionsSink = sink
                // §193 — connections single-shot: ядро шлёт reset-снапшот РОВНО
                // один раз при подписке screenClient (pull в libbox нет). Новый
                // Dart-подписчик (открытие Stats при уже живом screenClient) не
                // получает нового reset → пусто. Переэмитим накопленный
                // аккумулятор сразу, чтобы Stats увидел текущие соединения.
                BoxService.commandClient?.reEmitScreenConnections()
            }
            override fun onCancel(args: Any?) { BoxVpnService.ccConnectionsSink = null }
        })
        // §180 — DNS-журнал из ядра (SPEC 018).
        ccDnsEventChannel = EventChannel(binding.binaryMessenger, CC_DNS_CHANNEL)
        ccDnsEventChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(args: Any?, sink: EventChannel.EventSink?) { BoxVpnService.ccDnsQueriesSink = sink }
            override fun onCancel(args: Any?) { BoxVpnService.ccDnsQueriesSink = null }
        })

        Log.d(TAG, "[vpn] onAttachedToEngine: registerReceiver(statusReceiver)")
        // §155 — на отдельных OEM-прошивках registerReceiver может бросить
        // (например при гонке с фоновыми ограничениями) → краш прямо в
        // onAttachedToEngine, до того как плагин готов. Симметрично к
        // runCatching на unregisterReceiver в onDetachedFromEngine.
        runCatching {
            context.registerReceiver(
                statusReceiver,
                IntentFilter(BoxVpnService.BROADCAST_STATUS),
                Context.RECEIVER_NOT_EXPORTED
            )
        }.onFailure { Log.e(TAG, "[vpn] registerReceiver(statusReceiver) failed: $it") }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        Log.d(TAG, "[vpn] onDetachedFromEngine: unregisterReceiver(statusReceiver)")
        methodChannel.setMethodCallHandler(null)
        statusEventChannel.setStreamHandler(null)
        coreLogEventChannel.setStreamHandler(null)
        ccStatusEventChannel.setStreamHandler(null)
        ccOutboundsEventChannel.setStreamHandler(null)
        ccGroupsEventChannel.setStreamHandler(null)
        ccConnectionsEventChannel.setStreamHandler(null)
        ccDnsEventChannel.setStreamHandler(null) // §180
        statusSink = null
        BoxVpnService.coreLogSink = null
        BoxVpnService.ccStatusSink = null
        BoxVpnService.ccOutboundsSink = null
        BoxVpnService.ccGroupsSink = null
        BoxVpnService.ccConnectionsSink = null
        BoxVpnService.ccDnsQueriesSink = null // §180
        // §047 — обнуляем bridge-ссылки (engine detached).
        bridgeChannel = null
        appContext = null
        runCatching { context.unregisterReceiver(statusReceiver) }
        pluginScope.cancel()
    }

    // -------------------------------------------------------------------------
    // MethodCallHandler
    // -------------------------------------------------------------------------

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        Log.d(TAG, "onMethodCall: ${call.method}")
        when (call.method) {
            "saveConfig" -> {
                val config = call.argument<String>("config") ?: ""
                result.success(ConfigManager.save(config))
            }
            "getConfig" -> result.success(ConfigManager.load())
            // §316 — РЕАЛЬНЫЙ `Context.filesDir`, куда ядро пишет краш-репорты
            // и stderr. НЕ равен Dart-овскому `getApplicationDocumentsDirectory()`
            // (у Flutter это `app_flutter`, у native — `files`): из-за этой
            // подмены §038-канал stderr и краш-репорты ядра были недостижимы.
            "getFilesDir" -> result.success(context.filesDir.path)
            "startVPN" -> startVpn(result)
            // §165 — headless-старт (Debug API / automation): без Activity, БЕЗ
            // consent-диалога. Работает ТОЛЬКО если VPN-разрешение уже выдано
            // (prepare==null). Тот же путь, что §047 LxBoxIntentReceiver/Tile.
            // Возвращает {"started":bool, "needs_consent":bool}.
            "startVpnHeadless" -> {
                // §192 — proxy-режим без TUN: prepare не нужен (и зря рвёт чужой
                // VPN). Стартуем напрямую, консент не требуется.
                val needConsent = BootReceiver.hasTun(context) &&
                    VpnService.prepare(context.applicationContext) != null
                if (needConsent) {
                    result.success(mapOf("started" to false, "needs_consent" to true))
                } else {
                    BoxVpnService.start(context)
                    result.success(mapOf("started" to true, "needs_consent" to false))
                }
            }
            "stopVPN" -> stopVpn(result)
            "forceStopVPN" -> {
                // §129 — жёсткая остановка при зависшем-вхолостую ядре. Fire-and-
                // forget: BoxService.doForceStop сам делает stopSelf() не дожидаясь
                // setStatus(Stopped) от ядра. Не ждём (в отличие от stopVPN).
                BoxVpnService.forceStop(context)
                result.success(true)
            }
            "getVpnStatus" -> {
                // Pull-метод для re-sync UI после reattach Flutter-процесса
                // (broadcast'ятся только переходы — если service уже Started,
                // новый плагин ничего не получит без явного запроса).
                // §276 — map вместо голой строки: иначе UI, вернувшийся из фона
                // после перехвата слота, потеряет revoked и покажет нейтральный
                // Disconnected вместо «Taken by another VPN».
                result.success(
                    mapOf(
                        "status" to BoxVpnService.currentStatus.name,
                        BoxVpnService.EXTRA_REVOKED to BoxVpnService.currentRevoked,
                    )
                )
            }
            // Есть ли сейчас активный ЧУЖОЙ VPN (другое приложение)? UI спрашивает
            // перед ручным стартом, чтобы показать «переключиться?» вместо молчаливого
            // отзыва чужого туннеля. prepare()==null не различает «чужого нет» и
            // «чужой активен, но наше разрешение уже выдано» — здесь различаем явно.
            "isForeignVpnActive" -> result.success(isForeignVpnActive())
            "getTunnelUptimeMs" -> {
                // §187 — прошедшие мс с реального старта туннеля (переживает
                // swipe). 0 = не запущен / только что стартовал. Dart на cold-
                // start вычисляет честный connectedSince = now - uptime, вместо
                // обнуления на «сейчас». Монотонные часы (elapsedRealtime).
                val started = BoxVpnService.tunnelStartedElapsedMs
                val uptime = if (started > 0L) SystemClock.elapsedRealtime() - started else 0L
                result.success(uptime)
            }
            "getCoreVersion" -> {
                // Libbox.version() — статический Go-side метод; возвращает
                // строку вида "1.13.11". Используется в About screen.
                // Не требует libbox.setup; safe to call в любой момент.
                try {
                    result.success(io.nekohasekai.libbox.Libbox.version())
                } catch (t: Throwable) {
                    Log.e(TAG, "getCoreVersion failed", t)
                    result.success("")
                }
            }
            "reloadVPN" -> {
                // Spec 030: in-place reload sing-box runtime через
                // CommandServer.startOrReloadService — без recreate'а Android Service.
                BoxVpnService.reload(context)
                result.success(true)
            }
            "resetNetwork" -> {
                // Spec 031 (experimental): box.Router().ResetNetwork() — gentle
                // reset network sub-state без drop'а runtime.
                BoxVpnService.resetNetwork(context)
                result.success(true)
            }
            "setQuicKnob" -> {
                // §341 — диагностические env-ручки quic-go (GSO/ECN offload).
                // Статические Libbox-вызовы (Go-side os.Setenv), эффект — на
                // следующем (ре)коннекте QUIC-аутбаундов; сервис не нужен.
                val knob = call.argument<String>("knob")
                val disabled = call.argument<Boolean>("disabled") ?: false
                val ok = try {
                    when (knob) {
                        "gso" -> {
                            io.nekohasekai.libbox.Libbox.setQuicGSODisabled(disabled)
                            true
                        }
                        "ecn" -> {
                            io.nekohasekai.libbox.Libbox.setQuicECNDisabled(disabled)
                            true
                        }
                        else -> false
                    }
                } catch (t: Throwable) {
                    // Старый AAR без экспорта — не роняем канал, отвечаем false.
                    Log.e(TAG, "setQuicKnob($knob) failed", t)
                    false
                }
                result.success(ok)
            }
            "clearDnsCache" -> {
                // §263 — удалить cache.db (FakeIP + DNS RDRC). Running → reload
                // (ядро создаст чистый cache.db); off → только delete файла.
                BoxVpnService.clearDnsCache(context)
                result.success(true)
            }
            "setNotificationTitle" -> {
                val title = call.argument<String>("title")
                    ?: context.getString(com.leadaxe.lxbox.R.string.app_name)
                // §223 — лейбл поменялся при живом туннеле → перерисовать шторку
                // (#20: раньше строка только кэшировалась, рендер был лишь на connect).
                val changed = title != ConfigManager.notificationTitle
                ConfigManager.setNotificationTitle(title)
                if (changed) BoxVpnService.updateNotification(context)
                result.success(true)
            }
            "setNotificationText" -> {
                // §123 — подтекст уведомления (тег активной ноды / route.final).
                val text = call.argument<String>("text") ?: ""
                val changed = text != ConfigManager.notificationText   // §223
                ConfigManager.setNotificationText(text)
                if (changed) BoxVpnService.updateNotification(context)
                result.success(true)
            }
            "setAutoStart" -> {
                val enabled = call.argument<Boolean>("enabled") ?: false
                BootReceiver.setEnabled(context, enabled)
                result.success(true)
            }
            "getAutoStart" -> {
                result.success(BootReceiver.isEnabled(context))
            }
            "setKeepOnExit" -> {
                val enabled = call.argument<Boolean>("enabled") ?: false
                BootReceiver.setKeepOnExit(context, enabled)
                result.success(true)
            }
            "getKeepOnExit" -> {
                result.success(BootReceiver.isKeepOnExit(context))
            }
            "setCoreLogsEnabled" -> {
                val enabled = call.argument<Boolean>("enabled") ?: false
                BootReceiver.setCoreLogsEnabled(context, enabled)
                result.success(true)
            }
            "getCoreLogsEnabled" -> {
                result.success(BootReceiver.isCoreLogsEnabled(context))
            }
            // §345 — verbose core-логи: persist + немедленное применение
            // (volatile в BoxService читается на каждой строке writeDebugMessage,
            // перезапуск VPN не нужен).
            "setCoreLogsVerbose" -> {
                val enabled = call.argument<Boolean>("enabled") ?: false
                BootReceiver.setCoreLogsVerbose(context, enabled)
                BoxService.coreLogsVerbose = enabled
                result.success(true)
            }
            "getCoreLogsVerbose" -> {
                result.success(BootReceiver.isCoreLogsVerbose(context))
            }
            // §049 F15 fix: allowBypass opt-in toggle (применяется при следующем
            // openTun → требует reload VPN после изменения).
            "setAllowBypass" -> {
                val enabled = call.argument<Boolean>("enabled") ?: false
                BootReceiver.setAllowBypass(context, enabled)
                result.success(true)
            }
            "getAllowBypass" -> {
                result.success(BootReceiver.isAllowBypass(context))
            }
            // §189 — auto_redirect (§124 root-only tproxy). Доделана Dart-обёртка
            // для зеркала native_prefs. UI-тоггла нет (root-only), но в JSON-
            // зеркале/бэкапе участвует.
            "setAutoRedirect" -> {
                val enabled = call.argument<Boolean>("enabled") ?: false
                BootReceiver.setAutoRedirect(context, enabled)
                result.success(true)
            }
            "getAutoRedirect" -> {
                result.success(BootReceiver.isAutoRedirect(context))
            }
            // §192 — зеркало has_tun (производное от vpn_mode §119): гейтит
            // VpnService.prepare() на всех точках запуска. proxy → false →
            // prepare не зовётся → чужой VPN не отзывается.
            "setHasTun" -> {
                val enabled = call.argument<Boolean>("enabled") ?: true
                BootReceiver.setHasTun(context, enabled)
                result.success(true)
            }
            // §069: runtime applied value (от последнего establish()), в отличие
            // от persisted getAllowBypass() который меняется до VPN reload.
            "getCurrentSessionAllowBypass" -> {
                result.success(BoxVpnService.currentSessionAllowBypass)
            }
            "quitApp" -> {
                // §043 follow-up: завершить процесс целиком, чтобы при следующем
                // запуске `BoxApplication.initialize` пересоздал libbox с новым
                // флагом `debug` (см. SetupOptions в BoxApplication.kt — setup
                // зовётся ровно один раз за жизнь процесса).
                //
                // 1. finishAffinity() закрывает все наши activities,
                // 2. через 200ms killProcess + exitProcess убивают процесс
                //    (некоторые OEM-launchers иначе оставляют zombie).
                //
                // VPN service ещё может быть активен — Android сам его
                // остановит как только процесс умрёт (foreground service binding
                // с процессом). KEEP_ON_EXIT не реактивируем здесь: если юзер
                // явно запросил Quit, ему нужен полный рестарт, не fall-through
                // в keep-alive путь.
                result.success(true)
                mainHandler.postDelayed({
                    activity?.finishAffinity()
                }, 50)
                mainHandler.postDelayed({
                    android.os.Process.killProcess(android.os.Process.myPid())
                    kotlin.system.exitProcess(0)
                }, 250)
            }
            "getInstalledApps" -> {
                // Lightweight metadata only — иконки лениво подгружаются
                // через getAppIcon по пакету. PNG-encode всех иконок в одном
                // проходе — 500*20ms = 10s блокировки UI, недопустимо.
                val pm = context.packageManager
                val apps = pm.getInstalledApplications(0).map { info ->
                    val isSystem = (info.flags and android.content.pm.ApplicationInfo.FLAG_SYSTEM) != 0
                    mapOf(
                        "packageName" to info.packageName,
                        "appName" to (pm.getApplicationLabel(info)?.toString() ?: info.packageName),
                        "isSystemApp" to isSystem,
                    )
                }
                result.success(apps)
            }
            "getAppIcon" -> {
                val pkg = call.argument<String>("packageName") ?: ""
                result.success(encodeAppIcon(pkg))
            }
            "getAppInfo" -> {
                // §109: metadata-only — иконку НЕ тащим (PNG-encode на main
                // thread сериализовал очередь и выбивал Dart-side timeout на
                // длинных списках; иконка грузится отдельно через getAppIcon).
                // Контракт ответа:
                //   {packageName, appName, isSystemApp} — установлен
                //   {"notFound": true}  — подтверждённо не установлен
                //   result.error(...)   — проверить не удалось, Dart считает
                //                         retryable (НЕ «не установлен»)
                val pkg = call.argument<String>("packageName") ?: ""
                val pm = context.packageManager
                try {
                    val info = pm.getApplicationInfo(pkg, 0)
                    val isSystem = (info.flags and android.content.pm.ApplicationInfo.FLAG_SYSTEM) != 0
                    result.success(mapOf(
                        "packageName" to pkg,
                        "appName" to (pm.getApplicationLabel(info)?.toString() ?: pkg),
                        "isSystemApp" to isSystem,
                    ))
                } catch (_: android.content.pm.PackageManager.NameNotFoundException) {
                    result.success(mapOf("notFound" to true))
                } catch (e: Exception) {
                    result.error("APP_INFO_ERROR", e.message, null)
                }
            }
            "isIgnoringBatteryOptimizations" -> {
                val pm = context.getSystemService(Context.POWER_SERVICE) as android.os.PowerManager
                result.success(pm.isIgnoringBatteryOptimizations(context.packageName))
            }
            "openBatteryOptimizationSettings" -> {
                // Primary — system one-tap prompt («Allow L×Box to ignore
                // battery optimizations?»). It targets exactly our package via
                // `package:` URI, requires REQUEST_IGNORE_BATTERY_OPTIMIZATIONS
                // permission (declared in manifest), and is the path used by
                // SFA / NekoBox.
                // Fallback — общая страница battery-optimization с списком
                // всех apps (юзеру нужно ткнуть в L×Box). Срабатывает на OEM
                // (ColorOS/MIUI/HyperOS), где direct-prompt молча отбрасывается.
                result.success(openSystemSettings(
                    primaryAction = android.provider.Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                    primaryWithPackage = true,
                    fallbackAction = android.provider.Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS,
                ))
            }
            "openAppDetailsSettings" -> {
                result.success(openSystemSettings(
                    primaryAction = android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                    primaryWithPackage = true,
                ))
            }
            "areNotificationsEnabled" -> {
                result.success(androidx.core.app.NotificationManagerCompat.from(context).areNotificationsEnabled())
            }
            "getBackgroundMode" -> {
                result.success(BootReceiver.getBackgroundMode(context))
            }
            "setBackgroundMode" -> {
                val mode = call.argument<String>("mode") ?: BootReceiver.BG_MODE_NEVER
                BootReceiver.setBackgroundMode(context, mode)
                result.success(null)
            }
            "getMemoryLimit" -> {
                result.success(BootReceiver.getMemoryLimit(context))
            }
            // §279 Phase 6 (спека §6.3) — язык приложения из Dart (зеркало var
            // `app_language`): pref + LocaleManager-пуш (33+, "system" = пустой
            // список) + last_pushed_locale + relabel всех нативных поверхностей
            // (канал, шторка, shortcuts, тайл, локаль ядра).
            "setAppLanguage" -> {
                val tag = call.argument<String>("tag") ?: "system"
                L10n.applySetting(context, tag)
                result.success(true)
            }
            // §279 (спека §6.4) — снимок per-app-локалей + last_pushed_locale
            // для трёхстороннего reconciliation на Dart-старте. API < 33 →
            // {"supported": false}.
            "getAppLanguageState" -> {
                result.success(L10n.appLanguageState(context))
            }
            "setMemoryLimit" -> {
                // §271 — persist + мгновенное применение к работающему ядру.
                // `reloadSetupOptions` читает ТОЛЬКО три OOM-поля (setup.go:80-96)
                // и сразу вызывает debug.SetMemoryLimit — GC-потолок меняется без
                // переподключения VPN. Порог RSS-мониторинга oom-killer-сервиса
                // защёлкнут в CommandServer текущей сессии; BoxService создаёт
                // новый CommandServer на каждый старт сервиса → порог подтянется
                // при следующем подключении VPN.
                val value = call.argument<String>("value") ?: BootReceiver.MEMORY_LIMIT_AUTO
                BootReceiver.setMemoryLimit(context, value)
                val appContext = context
                pluginScope.launch(Dispatchers.IO) {
                    runCatching {
                        BoxApplication.libboxReady.await()
                        val opts = io.nekohasekai.libbox.SetupOptions().apply {
                            oomKillerEnabled = true
                            oomMemoryLimit = BoxApplication.resolveMemoryLimitBytes(appContext)
                        }
                        io.nekohasekai.libbox.Libbox.reloadSetupOptions(opts)
                    }.onFailure { Log.w(TAG, "reloadSetupOptions failed: ${it.message}") }
                }
                result.success(null)
            }
            "openNotificationSettings" -> {
                // API 26+ имеет прямой action ACTION_APP_NOTIFICATION_SETTINGS,
                // он передаёт пакет через extra, а не через data URI.
                // Fallback — ACTION_APPLICATION_DETAILS_SETTINGS (pre-26 или
                // если прямой action не найден OEM).
                result.success(openNotificationSettings())
            }
            "openVpnSettings" -> {
                // §241 — системный экран Settings → VPN: активный VPN там
                // помечен «Connected», юзер видит, кто держит слот. Action
                // public с API 24 (minSdk), package в URI не нужен.
                result.success(openSystemSettings(
                    primaryAction = android.provider.Settings.ACTION_VPN_SETTINGS,
                    primaryWithPackage = false,
                ))
            }
            "requestAddTile" -> {
                // §032 Quick Connect. API 33+ позволяет приложению попросить
                // систему показать prompt «Add L×Box to Quick Settings?».
                // На API < 33 возвращаем "unsupported" — Dart-сторона покажет
                // текстовую инструкцию вместо кнопки.
                requestAddQuickSettingsTile(result)
            }
            // §047 Automation API — Dart → native control + outgoing emit.
            "setAutomationEnabled" -> {
                val enabled = call.argument<Boolean>("enabled") ?: false
                LxBoxIntentReceiver.setEnabled(context, enabled)
                result.success(true)
            }
            "sendAutomationBroadcast" -> {
                val action = call.argument<String>("action") ?: ""
                @Suppress("UNCHECKED_CAST")
                val extras = (call.argument<Map<String, Any?>>("extras")
                    ?: emptyMap())
                if (action.isNotEmpty()) {
                    sendAutomationBroadcast(action, extras)
                }
                result.success(true)
            }
            // §047 Шаг 2 — зеркалим активную ноду/группу + списки нод/групп в
            // native-кеш. Активное состояние нужно LocaleConditionReceiver
            // (синхронный ответ на QUERY_CONDITION); списки — edit-Activity
            // плагина (Spinner выбора ноды/группы вместо ручного ввода).
            // Flutter-engine при чтении может спать, потому именно prefs.
            "setAutomationActiveState" -> {
                val node = call.argument<String>("node")
                val group = call.argument<String>("group")
                val nodes = call.argument<List<String>>("nodes")
                val groups = call.argument<List<String>>("groups")
                val edit = context
                    .getSharedPreferences("lxbox_automation", Context.MODE_PRIVATE)
                    .edit()
                    .putString("active_node", node)
                    .putString("active_group", group)
                // Списки сериализуем как JSON-массив строк. null → не трогаем
                // (caller мог обновить только активное состояние).
                if (nodes != null) {
                    edit.putString("all_nodes", org.json.JSONArray(nodes).toString())
                }
                if (groups != null) {
                    edit.putString("all_groups", org.json.JSONArray(groups).toString())
                }
                edit.apply()
                result.success(true)
            }
            "getApplicationExitInfo" -> result.success(readApplicationExitInfo())
            "getLogcatTail" -> {
                val count = (call.argument<Int>("count") ?: 1000).coerceIn(50, 5000)
                val level = (call.argument<String>("level") ?: "E")
                    .filter { it.isLetter() }
                    .ifEmpty { "E" }
                result.success(readLogcatTail(count, level))
            }
            "showToast" -> {
                // §031 Debug API. Вызов со стороны Dart через
                // /action/toast?msg=...&duration=short|long. Безопасно на
                // любом потоке — android.widget.Toast требует main looper,
                // постим туда.
                val msg = call.argument<String>("msg") ?: ""
                val duration = when (call.argument<String>("duration")) {
                    "long" -> android.widget.Toast.LENGTH_LONG
                    else -> android.widget.Toast.LENGTH_SHORT
                }
                mainHandler.post {
                    android.widget.Toast.makeText(context, msg, duration).show()
                }
                result.success(true)
            }

            // ───── §122 Фаза 0 — CommandClient lifecycle + императивы ─────
            // §185 — cold-start после swipe-keep: ВСЕ CC-клиенты осиротели
            // (PERSISTENT поля на companion, пережили swipe; Dart-движок умер,
            // disconnect/pause не вызвались). resyncForReopen переподнимает
            // screenClient (groups/connections, сброс протухшего refcount) +
            // statusClient (трафик/память, минуя ранний return setStatusFast)
            // на свежий движок — иначе стримы привязаны к мёртвым sink'ам →
            // пустой UI. Идемпотентно при первом старте. Профайлер: чистая
            // остановка осиротевшего клиента (буфер в Dart потерян by design).
            "ccResyncForReopen" -> {
                BoxService.commandClient?.apply {
                    resyncForReopen()
                    disconnectProfiler()
                }
                result.success(true)
            }
            "ccConnectScreen" -> {
                BoxService.commandClient?.connectScreen(); result.success(true)
            }
            "ccDisconnectScreen" -> {
                BoxService.commandClient?.disconnectScreen(); result.success(true)
            }
            "ccConnectProfiler" -> {
                BoxService.commandClient?.connectProfiler(); result.success(true)
            }
            "ccDisconnectProfiler" -> {
                BoxService.commandClient?.disconnectProfiler(); result.success(true)
            }
            // §175 — отмена масс-пинга: disconnect pingClient → ядро рвёт per-call
            // ctx in-flight тестов (не дожидаясь TCPTimeout), другие стримы целы.
            "ccCancelPing" -> {
                BoxService.commandClient?.cancelPing(); result.success(true)
            }
            // §164 — энергомодель. ccSetStatusFast: FAST 0.1с (Stats открыт) /
            // NORMAL 0.5с (главный). ccPauseClients: фон — гасим status+screen
            // (profilerClient НЕ трогаем, recording живёт в фоне). ccResumeClients:
            // возврат из фона — поднимаем status(NORMAL)+screen(если refs>0).
            "ccSetStatusFast" -> {
                val fast = call.argument<Boolean>("fast") ?: false
                BoxService.commandClient?.setStatusFast(fast); result.success(true)
            }
            "ccPauseClients" -> {
                BoxService.commandClient?.apply { pauseStatus(); pauseScreen() }
                result.success(true)
            }
            "ccResumeClients" -> {
                BoxService.commandClient?.apply { resumeStatus(); resumeScreen() }
                result.success(true)
            }
            // §122 — unary CommandClient-RPC БЛОКИРУЮТ (gRPC ждёт ответ ядра до
            // timeout). Вызов прямо в handleMethodCall = на platform main thread →
            // mass-ping (worker-pool=10 блокирующих urlTestOutbound) подвешивал
            // приложение в ANR. Выносим на Dispatchers.IO; result.success обратно
            // на main (pluginScope = Dispatchers.Main).
            "ccUrlTestOutbound" -> {
                val cc = BoxService.commandClient
                if (cc == null) { result.success(mapOf("delay" to 0, "error" to "not connected")); return }
                val tag = call.argument<String>("tag") ?: ""
                val link = call.argument<String>("link") ?: ""
                val timeoutMs = call.argument<Int>("timeoutMs") ?: 0
                pluginScope.launch {
                    val r = withContext(Dispatchers.IO) { cc.urlTestOutbound(tag, link, timeoutMs) }
                    result.success(r)
                }
            }
            // §392 — диагностический GET через узел боевого ядра (kernel SPEC
            // 058). Blocking unary → Dispatchers.IO, как ccUrlTestOutbound:
            // на main thread обмен с телом ответа = гарантированный ANR.
            "ccGetUrlViaOutbound" -> {
                val cc = BoxService.commandClient
                if (cc == null) { result.success(mapOf("error" to "not connected")); return }
                val tag = call.argument<String>("tag") ?: ""
                val link = call.argument<String>("link") ?: ""
                val timeoutMs = call.argument<Int>("timeoutMs") ?: 0
                val maxBytes = call.argument<Int>("maxBytes") ?: 0
                pluginScope.launch {
                    val r = withContext(Dispatchers.IO) {
                        cc.getUrlViaOutbound(tag, link, timeoutMs, maxBytes)
                    }
                    result.success(r)
                }
            }
            // §308 — групповой URLTest (force-тест всех членов + переселект в
            // ядре). Blocking unary → Dispatchers.IO, как ccUrlTestOutbound.
            "ccUrlTestGroup" -> {
                val cc = BoxService.commandClient
                if (cc == null) { result.success(false); return }
                val tag = call.argument<String>("tag") ?: ""
                pluginScope.launch {
                    val ok = withContext(Dispatchers.IO) { cc.urlTestGroup(tag) }
                    result.success(ok)
                }
            }
            // §236 — headless probe-сессия (Test servers в папке при
            // ВЫКЛЮЧЕННОМ VPN). start/urlTest/stop; гейт «VPN не запущен» —
            // внутри ProbeSession. Все вызовы блокирующие → Dispatchers.IO.
            "probeStart" -> {
                val config = call.argument<String>("config") ?: ""
                pluginScope.launch {
                    val err = withContext(Dispatchers.IO) { ProbeSession.start(config) }
                    result.success(err)
                }
            }
            "probeUrlTest" -> {
                val tag = call.argument<String>("tag") ?: ""
                val link = call.argument<String>("link") ?: ""
                val timeoutMs = call.argument<Int>("timeoutMs") ?: 0
                pluginScope.launch {
                    val r = withContext(Dispatchers.IO) { ProbeSession.urlTest(tag, link, timeoutMs) }
                    result.success(r)
                }
            }
            // §392 — тот же диагностический GET, но в probe-сессии (VPN
            // выключен). Форма результата идентична ccGetUrlViaOutbound.
            "probeGetUrl" -> {
                val tag = call.argument<String>("tag") ?: ""
                val link = call.argument<String>("link") ?: ""
                val timeoutMs = call.argument<Int>("timeoutMs") ?: 0
                val maxBytes = call.argument<Int>("maxBytes") ?: 0
                pluginScope.launch {
                    val r = withContext(Dispatchers.IO) {
                        ProbeSession.getUrl(tag, link, timeoutMs, maxBytes)
                    }
                    result.success(r)
                }
            }
            "probeStop" -> {
                pluginScope.launch {
                    withContext(Dispatchers.IO) { runCatching { ProbeSession.stop() } }
                    result.success(null)
                }
            }
            // §209 — null = клиент недоступен (различаем от [] = правил нет).
            // Dart getRules превращает null в пустой список (диагностика —
            // отсутствие данных там не отличают от пустых, см. CcChannel.getRules).
            "ccGetRules" -> {
                val cc = BoxService.commandClient
                pluginScope.launch {
                    val r = withContext(Dispatchers.IO) { cc?.getRules() }
                    result.success(r)
                }
            }
            // §122/SPEC015 — unary pull-снапшот групп. null = не смогли прочитать
            // (не-STARTED/нет клиента) → Dart различает от пустого списка и не
            // трогает state. Закрывает потерянный стартовый push (pull-vs-push).
            "ccGetGroups" -> {
                val cc = BoxService.commandClient
                pluginScope.launch {
                    val r = withContext(Dispatchers.IO) { cc?.getGroups() }
                    result.success(r)
                }
            }
            // §311/SPEC036 — unary снапшот конфига работающего ядра. null =
            // недоступен (down / не-STARTED / attached / ядро < lx.16-rc.3) —
            // обёртка BoxCommandClient no-throw (runCatching внутри), Dart
            // различает null от строки и деградирует к saved-файлу.
            // Dispatchers.IO — unary RPC на main = ANR (§122).
            // §312/SPEC035 — unary снапшот состояния DNS-групп. null =
            // недоступен (Dart различает от [] «групп нет»); обёртка no-throw.
            // Dispatchers.IO — unary RPC на main = ANR (§122).
            "ccGetDnsGroups" -> {
                val cc = BoxService.commandClient
                pluginScope.launch {
                    val r = withContext(Dispatchers.IO) { cc?.getDnsGroups() }
                    result.success(r)
                }
            }
            "ccGetRunningConfig" -> {
                val cc = BoxService.commandClient
                pluginScope.launch {
                    val r = withContext(Dispatchers.IO) { cc?.getRunningConfig() }
                    result.success(r)
                }
            }
            // §324 — каноническая форма конфига: `Libbox.formatConfig()` прогоняет
            // текст через ТОТ ЖЕ парсер и энкодер, которым ядро делает снапшот
            // работающего конфига (kernel SPEC 037 §3). Даёт сравнимые формы без
            // клиентского списка «различий, которые игнорируем».
            //
            // Статический Go-метод: НЕ требует живого сервиса и libbox.setup —
            // safe в любой момент (как getCoreVersion выше). На Dispatchers.IO:
            // парс большого конфига на main = ANR (§122).
            //
            // КОНТРАКТ: null = ядро не смогло (невалидный конфиг, метод
            // отсутствует в старом .aar, любой throw). Caller деградирует
            // консервативно — «изменилось» (§324).
            "formatConfig" -> {
                val text = call.argument<String>("config") ?: ""
                if (text.isBlank()) {
                    result.success(null)
                } else {
                    pluginScope.launch {
                        val r = withContext(Dispatchers.IO) {
                            try {
                                io.nekohasekai.libbox.Libbox.formatConfig(text)?.value
                            } catch (t: Throwable) {
                                // Невалидный конфиг — ожидаемый случай, не шумим error'ом.
                                Log.d(TAG, "formatConfig failed: ${t.message}")
                                null
                            }
                        }
                        result.success(r)
                    }
                }
            }
            // §208/§209 — unary снапшот пула round_robin-группы. На Dispatchers.IO
            // (RPC может блокировать). КОНТРАКТ: null = клиент недоступен (сервис
            // down / pingClient не поднялся) → Dart рендерит «Pool unavailable» /
            // Debug API → 409. [] = пул пуст (не round_robin / нет данных). НЕ
            // затираем null на emptyList — различение критично (§209).
            "ccGetPool" -> {
                val cc = BoxService.commandClient
                val tag = call.argument<String>("tag") ?: ""
                pluginScope.launch {
                    val r = withContext(Dispatchers.IO) { cc?.getPool(tag) }
                    result.success(r)
                }
            }
            "ccSelectOutbound" -> {
                val cc = BoxService.commandClient
                val group = call.argument<String>("group") ?: ""
                val tag = call.argument<String>("tag") ?: ""
                pluginScope.launch {
                    val r = withContext(Dispatchers.IO) { cc?.selectOutbound(group, tag) ?: false }
                    result.success(r)
                }
            }
            "ccCloseConnection" -> {
                val cc = BoxService.commandClient
                val id = call.argument<String>("id") ?: ""
                pluginScope.launch {
                    val r = withContext(Dispatchers.IO) { cc?.closeConnection(id) ?: false }
                    result.success(r)
                }
            }
            "ccCloseConnections" -> {
                val cc = BoxService.commandClient
                pluginScope.launch {
                    val r = withContext(Dispatchers.IO) { cc?.closeConnections() ?: false }
                    result.success(r)
                }
            }

            // §207 — обобщённый pprof-снимок через встроенный libbox
            // `PProfServer` (Способ 1): по требованию поднимаем pprof-http на
            // loopback, GET /debug/pprof/<pathAndQuery>, гасим. http в проде
            // не висит. Dart передаёт готовый `pathAndQuery` (профиль + query,
            // напр. `heap?gc=1`, `goroutine?debug=1`, `profile?seconds=10`) —
            // вся query-логика в одном месте (Dart), Kotlin лишь проксирует.
            // Формат файла решает Dart по флагу text/binary (см. writeProfile).
            //
            // Безопасность: разбираем имя профиля до `?` и проверяем по
            // allowlist'у — наружу пропускаем только известные pprof-профили,
            // не произвольный path.
            //
            // CPU `profile?seconds=N` держит соединение N секунд → read-timeout
            // масштабируем (N*1000 + запас); прочие снимки мгновенны (5s).
            // result.error на ошибке (занятые порты / pprof активен). IO-поток:
            // сетевой GET (и до 60s ожидания CPU) нельзя на main.
            "pprofProfile" -> {
                val pathAndQuery = call.argument<String>("pathAndQuery")
                    ?: "goroutine?debug=2"
                val name = pathAndQuery.substringBefore('?')
                pluginScope.launch {
                    try {
                        if (name !in PPROF_PROFILES) {
                            throw IllegalArgumentException("unknown pprof profile: $name")
                        }
                        val bytes = withContext(Dispatchers.IO) {
                            // CPU держит соединение `seconds`; вытащим N из query
                            // для масштабирования read-timeout, иначе мгновенные 5s.
                            val secs = if (name == "profile") {
                                Regex("seconds=(\\d+)").find(pathAndQuery)
                                    ?.groupValues?.get(1)?.toIntOrNull()
                                    ?.coerceIn(1, 60) ?: 10
                            } else 0
                            val readTimeout =
                                if (name == "profile") secs * 1000 + 5000 else 5000
                            PProfClient.fetch(pathAndQuery, readTimeoutMs = readTimeout)
                        }
                        result.success(bytes)
                    } catch (t: Throwable) {
                        Log.e(TAG, "pprofProfile($pathAndQuery) failed", t)
                        result.error("PPROF_FAILED",
                            t.message ?: t.javaClass.simpleName, null)
                    }
                }
            }

            // Разбивка памяти процесса приложения (ядро sing-box живёт в этом
            // же процессе — VpnService без android:process). Даёт категории,
            // которых нет в CommandClient-статусе (там только RSS всего
            // процесса): native heap (сюда попадают Go-буферы ядра), Dalvik/ART,
            // graphics, code, stack, system. Значения — в байтах (Debug отдаёт
            // KB → ×1024) для единого formatBytes на Dart-стороне. summary.*
            // из Debug.MemoryInfo.getMemoryStat доступны с API 23.
            "getMemoryInfo" -> {
                try {
                    val mi = android.os.Debug.MemoryInfo()
                    android.os.Debug.getMemoryInfo(mi)
                    fun stat(key: String): Long =
                        mi.getMemoryStat(key)?.toLongOrNull()?.times(1024) ?: 0L
                    val out = hashMapOf<String, Any>(
                        "totalPss" to stat("summary.total-pss"),
                        "totalSwap" to stat("summary.total-swap"),
                        "javaHeap" to stat("summary.java-heap"),
                        "nativeHeap" to stat("summary.native-heap"),
                        "code" to stat("summary.code"),
                        "stack" to stat("summary.stack"),
                        "graphics" to stat("summary.graphics"),
                        "privateOther" to stat("summary.private-other"),
                        "system" to stat("summary.system"),
                        // Аллоцированный native heap (Go-память ядра + прочая
                        // нативка) — прямой счётчик malloc, не PSS-категория.
                        "nativeHeapAllocated" to android.os.Debug.getNativeHeapAllocatedSize(),
                        "nativeHeapSize" to android.os.Debug.getNativeHeapSize(),
                    )
                    result.success(out)
                } catch (t: Throwable) {
                    Log.e(TAG, "getMemoryInfo failed", t)
                    result.error("MEMINFO_FAILED", t.message ?: t.javaClass.simpleName, null)
                }
            }

            else -> result.notImplemented()
        }
    }

    /// §038 — `getHistoricalProcessExitReasons` lazy reader. На API <30 →
    /// пустой список (метод недоступен); на любую ошибку — тоже пустой
    /// (никогда не валим caller'а из-за этого).
    private fun readApplicationExitInfo(): List<Map<String, Any?>> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return emptyList()
        val am = context.getSystemService(Context.ACTIVITY_SERVICE) as? android.app.ActivityManager
            ?: return emptyList()
        val infos = runCatching {
            am.getHistoricalProcessExitReasons(context.packageName, 0, 5)
        }.getOrElse {
            Log.w(TAG, "getHistoricalProcessExitReasons failed: ${it.message}")
            return emptyList()
        }
        return infos.map { info ->
            mapOf(
                "timestamp" to info.timestamp,
                "reason" to exitReasonName(info.reason),
                "description" to info.description,
                "importance" to info.importance,
                "pss" to info.pss,
                "rss" to info.rss,
                "status" to info.status,
                "trace" to runCatching {
                    info.traceInputStream?.use { it.bufferedReader().readText() }
                }.getOrNull(),
            )
        }
    }

    /// §038 — снимок последних N строк logcat'а нашего процесса. logd
    /// UID-фильтрует автоматически (READ_LOGS не нужен). Timeout 2s
    /// страхует от зависания на проблемных ROM.
    private fun readLogcatTail(count: Int, level: String): String {
        return runCatching {
            val proc = ProcessBuilder("logcat", "-d", "-t", count.toString(), "*:$level")
                .redirectErrorStream(true)
                .start()
            val out = proc.inputStream.bufferedReader().readText()
            proc.waitFor(2, java.util.concurrent.TimeUnit.SECONDS)
            out
        }.getOrElse {
            Log.w(TAG, "logcat tail failed: ${it.message}")
            ""
        }
    }

    /// §038 — `ApplicationExitInfo.REASON_*` коды → читаемые имена.
    @androidx.annotation.RequiresApi(Build.VERSION_CODES.R)
    private fun exitReasonName(code: Int): String = when (code) {
        android.app.ApplicationExitInfo.REASON_UNKNOWN -> "UNKNOWN"
        android.app.ApplicationExitInfo.REASON_EXIT_SELF -> "EXIT_SELF"
        android.app.ApplicationExitInfo.REASON_SIGNALED -> "SIGNALED"
        android.app.ApplicationExitInfo.REASON_LOW_MEMORY -> "LOW_MEMORY"
        android.app.ApplicationExitInfo.REASON_CRASH -> "CRASH"
        android.app.ApplicationExitInfo.REASON_CRASH_NATIVE -> "CRASH_NATIVE"
        android.app.ApplicationExitInfo.REASON_ANR -> "ANR"
        android.app.ApplicationExitInfo.REASON_INITIALIZATION_FAILURE -> "INITIALIZATION_FAILURE"
        android.app.ApplicationExitInfo.REASON_PERMISSION_CHANGE -> "PERMISSION_CHANGE"
        android.app.ApplicationExitInfo.REASON_EXCESSIVE_RESOURCE_USAGE -> "EXCESSIVE_RESOURCE_USAGE"
        android.app.ApplicationExitInfo.REASON_USER_REQUESTED -> "USER_REQUESTED"
        android.app.ApplicationExitInfo.REASON_USER_STOPPED -> "USER_STOPPED"
        android.app.ApplicationExitInfo.REASON_DEPENDENCY_DIED -> "DEPENDENCY_DIED"
        android.app.ApplicationExitInfo.REASON_OTHER -> "OTHER"
        android.app.ApplicationExitInfo.REASON_PACKAGE_UPDATED -> "PACKAGE_UPDATED"
        else -> "REASON_$code"
    }

    /// Запуск системного settings-activity. Сперва через activity-context
    /// (если есть), иначе через app-context с FLAG_ACTIVITY_NEW_TASK.
    /// Пакет в URI добавляется автоматически для actions требующих его
    /// (REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, APPLICATION_DETAILS_SETTINGS).
    private fun openSystemSettings(
        primaryAction: String,
        primaryWithPackage: Boolean,
        fallbackAction: String? = null,
    ): Boolean {
        val act = activity
        val launchCtx: Context = act ?: context
        val useNewTask = act == null

        fun needsPackage(action: String) = action in setOf(
            android.provider.Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
            android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
        )

        fun tryLaunch(action: String, withPackage: Boolean): Boolean {
            val intent = android.content.Intent(action).apply {
                if (withPackage) {
                    data = android.net.Uri.parse("package:${context.packageName}")
                }
                if (useNewTask) addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            return try {
                launchCtx.startActivity(intent)
                Log.d(TAG, "openSystemSettings launched: $action")
                true
            } catch (e: Exception) {
                Log.e(TAG, "openSystemSettings failed for $action: ${e.message}", e)
                false
            }
        }

        if (tryLaunch(primaryAction, primaryWithPackage)) return true
        if (fallbackAction != null &&
            tryLaunch(fallbackAction, needsPackage(fallbackAction))) return true
        return false
    }

    /// Открывает per-app notification settings. На API 26+ идёт прямой action,
    /// пакет передаётся через `EXTRA_APP_PACKAGE` (не через data URI —
    /// поэтому helper `openSystemSettings` не подходит). Если активити не
    /// найдена (старый Android / OEM без экрана) — fallback на app details.
    private fun openNotificationSettings(): Boolean {
        val act = activity
        val launchCtx: Context = act ?: context
        val useNewTask = act == null
        val intent = Intent(android.provider.Settings.ACTION_APP_NOTIFICATION_SETTINGS).apply {
            putExtra(android.provider.Settings.EXTRA_APP_PACKAGE, context.packageName)
            if (useNewTask) addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        return try {
            launchCtx.startActivity(intent)
            true
        } catch (_: Exception) {
            openSystemSettings(
                primaryAction = android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                primaryWithPackage = true,
            )
        }
    }

    /// API 33+ — попросить систему показать «Add tile to Quick Settings»
    /// prompt. Async через Consumer-callback системы, success() в Dart
    /// идёт ровно один раз. Возможные значения:
    ///   "added"        — юзер согласился
    ///   "already"      — tile уже в шторке
    ///   "dismissed"    — юзер отказался
    ///   "unsupported"  — API < 33
    ///   "no_activity"  — нет attached activity
    ///   "error: ..."   — exception от системы
    private fun requestAddQuickSettingsTile(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            result.success("unsupported")
            return
        }
        val act = activity
        if (act == null) {
            result.success("no_activity")
            return
        }
        try {
            val sbm = act.getSystemService(android.app.StatusBarManager::class.java)
            if (sbm == null) {
                result.success("error: status_bar_unavailable")
                return
            }
            val component = android.content.ComponentName(
                context, com.leadaxe.lxbox.vpn.LxBoxTileService::class.java
            )
            val icon = android.graphics.drawable.Icon.createWithResource(
                context, android.R.drawable.ic_lock_lock
            )
            // Защита от двойного success() если система зовёт consumer
            // несколько раз (наблюдалось на отдельных OEM).
            val replied = java.util.concurrent.atomic.AtomicBoolean(false)
            sbm.requestAddTileService(
                component,
                context.getString(com.leadaxe.lxbox.R.string.app_name),
                icon,
                { runnable -> mainHandler.post(runnable) },
                { code ->
                    if (!replied.compareAndSet(false, true)) return@requestAddTileService
                    val mapped = when (code) {
                        android.app.StatusBarManager.TILE_ADD_REQUEST_RESULT_TILE_ADDED -> "added"
                        android.app.StatusBarManager.TILE_ADD_REQUEST_RESULT_TILE_ALREADY_ADDED -> "already"
                        android.app.StatusBarManager.TILE_ADD_REQUEST_RESULT_TILE_NOT_ADDED -> "dismissed"
                        else -> "error: result=$code"
                    }
                    mainHandler.post { result.success(mapped) }
                }
            )
        } catch (e: Exception) {
            Log.e(TAG, "requestAddTile failed", e)
            result.success("error: ${e.message}")
        }
    }

    /// PNG-base64 иконки одного приложения. Пустая строка если не удалось.
    /// Выделено в функцию чтобы переиспользовать из getAppIcon и getAppInfo.
    private fun encodeAppIcon(pkg: String): String {
        return try {
            val pm = context.packageManager
            val drawable = pm.getApplicationIcon(pkg)
            val bitmap = if (drawable is android.graphics.drawable.BitmapDrawable) {
                drawable.bitmap
            } else {
                val bmp = android.graphics.Bitmap.createBitmap(
                    48, 48, android.graphics.Bitmap.Config.ARGB_8888
                )
                val canvas = android.graphics.Canvas(bmp)
                drawable.setBounds(0, 0, 48, 48)
                drawable.draw(canvas)
                bmp
            }
            val stream = java.io.ByteArrayOutputStream()
            bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 80, stream)
            android.util.Base64.encodeToString(stream.toByteArray(), android.util.Base64.NO_WRAP)
        } catch (_: Exception) {
            ""
        }
    }

    /// true, если прямо сейчас активен VPN ДРУГОГО приложения. Наш сервис ещё
    /// не поднят (мы только собираемся стартовать) → сеть с VPN-транспортом,
    /// которой владеем НЕ мы, = чужая. Если наш сервис уже не в Stopped — это мы
    /// сами, не чужой.
    /// Источник истины: ConnectivityManager + NetworkCapabilities.TRANSPORT_VPN
    /// (тот же приём, что DefaultNetworkMonitor.isVpn).
    ///
    /// §361 — владельца проверяем ЯВНО, а не выводим из статуса сервиса. Прежнее
    /// допущение «наш сервис в Stopped ⇒ любой VPN чужой» ломается на осиротевшем
    /// tun: VpnService умер, а его интерфейс остался в системе (в dumpsys —
    /// `ni{VPN CONNECTED}` c нашим `OwnerUid`). Приложение видело собственный
    /// брошенный туннель и на каждый Start предлагало «переключиться» с самого
    /// себя. Всплыло это на §361-фиксе `stopAwait`: тот честно переводит статус в
    /// Stopped, когда сервиса нет, — и ранний `return false` по статусу перестал
    /// прикрывать дыру (раньше статус залипал в Started и метод выходил первой
    /// строкой).
    ///
    /// §427 (issue #115) — смотрим ТОЛЬКО `activeNetwork`, а не `allNetworks`.
    /// `allNetworks` отдаёт все сети фреймворка, включая VPN соседнего профиля
    /// (Shelter / work profile); Android держит по одному VPN-слоту на ПРОФИЛЬ,
    /// такой туннель нам не мешает и нашим `establish()` не отзывается, а
    /// диалог §211 на него срабатывал ложно. `activeNetwork` — дефолтная сеть
    /// для нашего uid: VPN другого профиля в неё не попадает никогда, VPN
    /// нашего профиля попадает, если не исключил нас из туннеля (тот редкий
    /// случай мы перебьём молча, как до §211 — слот всё равно один).
    /// Публичного API «относится ли сеть к моему профилю» нет, а `ownerUid`
    /// для чужих сетей редактируется в INVALID_UID.
    ///
    /// `getOwnerUid()` публичен с API 30 (в android-10 есть только скрытый
    /// `getEstablishingVpnAppUid()`): на Android 10 обращение бросает
    /// `NoSuchMethodError` — это `Error`, не `Exception`, прежний catch его не
    /// ловил и Start ронял приложение. Гейт на R, ловим Throwable. На 24-29
    /// деталь недоступна — считаем чужим (консервативно: лишний вопрос юзеру
    /// безопаснее молчаливого отзыва чужого туннеля).
    private fun isForeignVpnActive(): Boolean {
        if (BoxVpnService.currentStatus != VpnStatus.Stopped) return false
        val cm = BoxApplication.connectivity
        return try {
            val n = cm.activeNetwork ?: return false
            val caps = cm.getNetworkCapabilities(n) ?: return false
            if (!caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) return false
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R &&
                caps.ownerUid == android.os.Process.myUid()
            ) {
                Log.d(TAG, "[vpn §361] skipping our own orphaned VPN network (uid=${caps.ownerUid})")
                return false
            }
            true
        } catch (t: Throwable) {
            Log.w(TAG, "isForeignVpnActive: $t")
            false
        }
    }

    private fun startVpn(result: MethodChannel.Result) {
        val act = activity
        if (act == null) {
            result.error("NO_ACTIVITY", "No activity", null)
            return
        }
        // §192 — proxy-режим (port-only, без TUN): НЕ зовём VpnService.prepare()
        // — он зря забирает системный VPN-слот и отзывает чужой активный VPN
        // (onRevoke). Стартуем сервис напрямую; ядро в proxy не зовёт openTun.
        if (!BootReceiver.hasTun(context)) {
            BoxVpnService.start(context)
            result.success(true)
            return
        }
        val intent = VpnService.prepare(act)
        if (intent != null) {
            pendingVpnResult = result
            act.startActivityForResult(intent, VPN_REQUEST_CODE)
        } else {
            BoxVpnService.start(context)
            result.success(true)
        }
    }

    /// Blocking stop: на native-стороне ждём пока setStatus(Stopped) реально
    /// отработает (после async cleanup libbox-ресурсов), чтобы caller в Dart
    /// мог последовательно сделать `await stopVPN()` → `await startVPN()`
    /// без race'а в onStartCommand guard (`status != Stopped` → silent).
    ///
    /// §415 — бюджет `BoxVpnService.STOP_AWAIT_TIMEOUT_MS` (9с): если doStop не
    /// доиграл, возвращаем `false`. Caller (обычно reconnect) сам решит отменить
    /// или повторить. Значение — общая константа, а не литерал: связь
    /// «нативный бюджет < Dart-бюджет `_Timeouts.stopVpn`» описана там же.
    private fun stopVpn(result: MethodChannel.Result) {
        pluginScope.launch {
            val ok = try {
                withTimeout(BoxVpnService.STOP_AWAIT_TIMEOUT_MS) {
                    BoxVpnService.stopAwait(context).await()
                }
                true
            } catch (e: TimeoutCancellationException) {
                Log.w(TAG, "[vpn] stopVPN: ${BoxVpnService.STOP_AWAIT_TIMEOUT_MS}ms timeout — native did not report Stopped")
                false
            } catch (e: Exception) {
                Log.e(TAG, "[vpn] stopVPN: exception $e")
                false
            }
            result.success(ok)
        }
    }

    // -------------------------------------------------------------------------
    // ActivityAware
    // -------------------------------------------------------------------------

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        binding.addActivityResultListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() { activity = null }
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
        binding.addActivityResultListener(this)
    }
    override fun onDetachedFromActivity() { activity = null }

    // -------------------------------------------------------------------------
    // ActivityResultListener
    // -------------------------------------------------------------------------

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != VPN_REQUEST_CODE) return false
        val r = pendingVpnResult
        pendingVpnResult = null
        if (resultCode == Activity.RESULT_OK) {
            BoxVpnService.start(context)
            r?.success(true)
        } else {
            r?.success(false)
        }
        return true
    }
}
