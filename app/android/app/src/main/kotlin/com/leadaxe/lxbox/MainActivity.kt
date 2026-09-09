package com.leadaxe.lxbox

import android.app.Activity
import android.content.ContentValues
import android.content.Intent
import android.net.Uri
import android.net.VpnService
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.provider.MediaStore
import android.telephony.TelephonyManager
import android.util.Log
import android.widget.Toast
import com.leadaxe.lxbox.vpn.BootReceiver
import com.leadaxe.lxbox.vpn.BoxApplication
import com.leadaxe.lxbox.vpn.BoxVpnService
import com.leadaxe.lxbox.vpn.L10n
import com.leadaxe.lxbox.vpn.PermissionUtils
import com.leadaxe.lxbox.vpn.QuickShortcuts
import com.leadaxe.lxbox.vpn.VpnPlugin
import com.leadaxe.lxbox.vpn.VpnStatus
import com.leadaxe.lxbox.vpn.WifiHistoryBridge
import com.leadaxe.lxbox.vpn.WifiInfoReader
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterShellArgs
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    companion object {
        private const val TAG = "MainActivity"
        private const val VPN_REQUEST_CODE_QUICK = 7032
        private const val NOTIFICATION_PERMISSION_REQUEST = 7033
        private const val NEARBY_WIFI_PERMISSION_REQUEST = 7034
        private const val GET_CONTENT_REQUEST_CODE = 7035

        const val EXTRA_ACTION = "action"

        const val ACTION_CONNECT = "connect"
        const val ACTION_DISCONNECT = "disconnect"
        const val ACTION_TOGGLE = "toggle"
    }

    /// Если activity была открыта именно из tile/shortcut (через extras),
    /// после успешного consent'а закрываемся, чтобы юзер вернулся на хоум —
    /// он не просил открывать app, он просил подключить VPN.
    private var finishAfterConsent = false

    /// §383 — `MethodChannel.Result` незавершённого GET_CONTENT-пика.
    /// Ответ приходит асинхронно, в `onActivityResult`. Ненулевое значение =
    /// пик уже идёт: второй запрос отклоняем, чтобы не потерять первый result
    /// (Flutter падает на повторном ответе в один и тот же Result).
    private var pendingPickResult: MethodChannel.Result? = null

    /// §131 — Impeller crash на старых GPU (Adreno 3xx, Android 10).
    ///
    /// Flutter (stable, Dart 3.11) по умолчанию рендерит через Impeller. Его
    /// GLES-шейдеры валят драйвер `libsc-a3xx.so` на старых Adreno: SIGSEGV в
    /// потоке `1.raster` сразу при работе с UI (tombstone — см. §131). На API
    /// < 31 откатываемся на Skia, добавляя shell-флаг `--enable-impeller=false`
    /// — ровно тот аргумент, который штатно генерит manifest-флаг
    /// `EnableImpeller=false` (FlutterLoader.java:420), только условно по
    /// версии Android. На API ≥ 31 (primary-tier, современные GPU) Impeller
    /// остаётся включённым — поведение не меняется.
    ///
    /// Override `getFlutterShellArgs` вместо кастомного FlutterEngine: движок
    /// по-прежнему создаёт сам FlutterActivity (plugin registration, deep
    /// links, lifecycle — без изменений), мы лишь дописываем shell-флаг к тем,
    /// что активити и так передаёт в native init.
    ///
    /// Гейт по `SDK_INT`, а не по реальному GPU — у Flutter нет чистого
    /// рантайм-детекта GPU; на старом Android с хорошим GPU Impeller
    /// отключится «зря», но для простого UI (списки/тогглы/формы) разница
    /// Skia↔Impeller незначима.
    override fun getFlutterShellArgs(): FlutterShellArgs {
        val args = super.getFlutterShellArgs()
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
            Log.d(TAG, "API ${Build.VERSION.SDK_INT} < 31 — disabling Impeller (Skia renderer)")
            args.add("--enable-impeller=false")
        }
        return args
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        Log.d(TAG, "configureFlutterEngine — registering VpnPlugin")
        super.configureFlutterEngine(flutterEngine)
        flutterEngine.plugins.add(VpnPlugin())

        // §051 Phase 3 — channel для auto-record wifi history. Native side
        // вызывает invokeMethod("onWifiSeen", ...) когда юзер пробыл на
        // сети ≥ 60 сек. Dart-side handler пишет в SettingsStorage.
        // Attach сразу в configureFlutterEngine — поскольку Dart будет
        // регистрировать handler через тот же channel name.
        val wifiHistoryChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.leadaxe.lxbox/wifi_history",
        )
        WifiHistoryBridge.attach(wifiHistoryChannel)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.leadaxe.lxbox/utils")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "openUrl" -> {
                        val url = call.argument<String>("url")
                        if (url != null) {
                            // §390 — `fallbackUrl` для custom-scheme ссылок:
                            // `market://` не резолвится на устройствах без
                            // Play (а это ровно наша аудитория) и роняет
                            // startActivity. Тогда открываем https-форму.
                            val fallback = call.argument<String>("fallbackUrl")
                            if (openUrlOrFallback(url, fallback)) {
                                result.success(null)
                            } else {
                                result.error("NO_ACTIVITY", "No handler for $url", null)
                            }
                        } else {
                            result.error("INVALID_URL", "URL is null", null)
                        }
                    }
                    "networkCountry" -> {
                        // §425 — страна текущей сети (MCC оператора), затем
                        // страна SIM; null без телефонии (Wi-Fi-only, TV).
                        result.success(networkCountryIso())
                    }
                    "installSource" -> {
                        // §390 — package name установщика (сырой; маппинг в
                        // канал живёт на Dart-стороне, одним местом).
                        result.success(installerPackageName())
                    }
                    "openAppSettings" -> {
                        // §050 — open Android Settings directly to App permissions.
                        val opened = openAppPermissions()
                        result.success(opened)
                    }
                    "hasRealFilePicker" -> {
                        // §372 — есть ли на устройстве НАСТОЯЩИЙ файловый пикер.
                        result.success(hasRealFilePicker())
                    }
                    "filePickerAction" -> {
                        // §383 — КАКОЙ action обслуживает реальный пикер:
                        // "android.intent.action.OPEN_DOCUMENT" (штатный путь
                        // через плагин), "…GET_CONTENT" (свой пик) или null.
                        result.success(filePickerAction())
                    }
                    "pickFileViaGetContent" -> {
                        // §383 — свой GET_CONTENT-пик для устройств, где
                        // OPEN_DOCUMENT не обслуживается (плагин умеет только его).
                        startGetContentPick(
                            call.argument<Boolean>("allowMultiple") ?: false,
                            result,
                        )
                    }
                    "hasCamera" -> {
                        // §375 — есть ли камера (для QR-сканера).
                        result.success(hasCamera())
                    }
                    "canSaveToDownloads" -> {
                        // §374 — MediaStore-запись в Downloads без разрешений
                        // доступна с API 29 (scoped storage).
                        result.success(Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q)
                    }
                    "saveToDownloads" -> {
                        // §374 — fallback экспорта там, где нет SAF-диалога.
                        val name = call.argument<String>("fileName")
                        val content = call.argument<String>("content")
                        if (name.isNullOrEmpty() || content == null) {
                            result.error("INVALID_ARGS", "fileName/content is null", null)
                        } else {
                            result.success(saveToDownloads(name, content))
                        }
                    }
                    "checkNotificationPermission" -> {
                        // POST_NOTIFICATIONS — runtime permission на API 33+.
                        // На pre-33 концепта не было → implicit grant.
                        result.success(PermissionUtils.has(
                            this, "android.permission.POST_NOTIFICATIONS",
                            minSdk = 33,
                        ))
                    }
                    "requestNotificationPermission" -> {
                        // Trigger system permission dialog for POST_NOTIFICATIONS on API 33+.
                        // result.success(null) immediately — the user will see the dialog
                        // asynchronously. Re-check permission status afterward.
                        if (android.os.Build.VERSION.SDK_INT >= 33) {
                            requestPermissions(
                                arrayOf("android.permission.POST_NOTIFICATIONS"),
                                NOTIFICATION_PERMISSION_REQUEST,
                            )
                        }
                        result.success(null)
                    }
                    "checkNearbyWifiPermission" -> {
                        // API 33+ canonical permission для `WifiInfo.ssid`.
                        // Pre-33 → implicit grant (covered by location-perms).
                        result.success(PermissionUtils.has(
                            this, "android.permission.NEARBY_WIFI_DEVICES",
                            minSdk = 33,
                        ))
                    }
                    "checkBackgroundLocationPermission" -> {
                        // API 29+ требуется BACKGROUND_LOCATION для wifi info
                        // из background. Pre-Q → fallback на FINE_LOCATION
                        // (implicit чтение из foreground).
                        val name = if (android.os.Build.VERSION.SDK_INT >= 29) {
                            "android.permission.ACCESS_BACKGROUND_LOCATION"
                        } else {
                            "android.permission.ACCESS_FINE_LOCATION"
                        }
                        result.success(PermissionUtils.has(this, name))
                    }
                    "requestNearbyWifiPermission" -> {
                        // Trigger system runtime prompt for NEARBY_WIFI_DEVICES.
                        // Async — Flutter must re-check via `checkNearbyWifiPermission`.
                        if (android.os.Build.VERSION.SDK_INT >= 33) {
                            requestPermissions(
                                arrayOf("android.permission.NEARBY_WIFI_DEVICES"),
                                NEARBY_WIFI_PERMISSION_REQUEST,
                            )
                        }
                        result.success(null)
                    }
                    "getCurrentWifiInfo" -> {
                        // §051 Phase 2 — return current Wi-Fi SSID/BSSID для UI
                        // editor'а. Reuses `WifiManager.connectionInfo` (та же
                        // path что sing-box использует для match'а).
                        // Returns Map: {ssid?, bssid?, error?}.
                        // Errors: "permission_missing", "no_wifi", "unknown_ssid".
                        result.success(getCurrentWifiInfoMap())
                    }
                    "setAutoRecordWifi" -> {
                        // §051 Phase 3 — start/stop WifiNetworkObserver
                        // (auto-record history). Toggle гейтится storage
                        // var `auto_record_wifi_history`; Dart-side читает
                        // его на init и при tap toggle, синкает сюда.
                        val enable = call.argument<Boolean>("enable") ?: false
                        if (enable) {
                            BoxApplication.wifiObserver.start()
                        } else {
                            BoxApplication.wifiObserver.stop()
                        }
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        handleQuickAction(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleQuickAction(intent)
    }

    override fun onResume() {
        super.onResume()
        // §279 — гарантированный retry relabel'а shortcuts, отложенного из-за
        // rate-limit'а (смена языка в background): foreground-вызовы
        // ShortcutManager rate-limit не применяет. No-op без pending-флага.
        QuickShortcuts.retryPendingRelabel(applicationContext)
    }

    private fun handleQuickAction(intent: Intent?) {
        val action = intent?.getStringExtra(EXTRA_ACTION) ?: return
        Log.d(TAG, "handleQuickAction action=$action currentStatus=${BoxVpnService.currentStatus.name}")
        // `extras.action` ставится только из tile или shortcut'а — поэтому
        // если мы здесь, мы пришли не через обычный launcher-tap. Закрываемся
        // после обработки, чтобы юзер вернулся на хоум.
        finishAfterConsent = true
        // Один раз обработали — счищаем extras, иначе любая ротация / возврат
        // на activity дёргает снова.
        intent.removeExtra(EXTRA_ACTION)

        when (action) {
            ACTION_CONNECT -> startVpnWithConsent()
            ACTION_DISCONNECT -> {
                BoxVpnService.stop(applicationContext)
                if (finishAfterConsent) finish()
            }
            ACTION_TOGGLE -> {
                val s = BoxVpnService.currentStatus
                if (s == VpnStatus.Started) {
                    BoxVpnService.stop(applicationContext)
                    if (finishAfterConsent) finish()
                } else if (s == VpnStatus.Stopped) {
                    startVpnWithConsent()
                } else {
                    Log.d(TAG, "toggle ignored in transient state ${s.name}")
                    if (finishAfterConsent) finish()
                }
            }
            else -> Log.w(TAG, "Unknown quick action: $action")
        }
    }

    private fun startVpnWithConsent() {
        // §192 — proxy-режим без TUN: prepare не нужен (и зря рвёт чужой VPN).
        if (!BootReceiver.hasTun(applicationContext)) {
            BoxVpnService.start(applicationContext)
            if (finishAfterConsent) finish()
            return
        }
        val prep = VpnService.prepare(applicationContext)
        if (prep == null) {
            BoxVpnService.start(applicationContext)
            if (finishAfterConsent) finish()
            return
        }
        // Покажем тост ровно если activity «просто открылась» под consent —
        // обычный запуск через UI и так показывает диалог как часть flow.
        if (finishAfterConsent) {
            // §279 — текст через L10n (in-app язык может отличаться от системного).
            Toast.makeText(
                applicationContext,
                L10n.str(applicationContext, R.string.qc_first_open),
                Toast.LENGTH_SHORT,
            ).show()
        }
        try {
            startActivityForResult(prep, VPN_REQUEST_CODE_QUICK)
        } catch (e: Exception) {
            Log.e(TAG, "VPN consent prepare failed: ${e.message}", e)
            if (finishAfterConsent) finish()
        }
    }

    /// §050 — open Settings directly на App permissions screen.
    /// Try `MANAGE_APP_PERMISSIONS` first — this is the action used by
    /// PermissionController to show the permissions UI for a specific app.
    /// If that fails (very old OEMs without PermissionController), fall back
    /// to the generic App info page.
    /// §372 — есть ли на устройстве настоящий файловый менеджер.
    ///
    /// На Android TV DocumentsUI не ставится, но intent НЕ остаётся без
    /// обработчика: framework подкладывает заглушку
    /// `com.android.tv.frameworkpackagestubs/.Stubs$DocumentsStub` на
    /// OPEN_DOCUMENT / GET_CONTENT / CREATE_DOCUMENT. Она показывает тост и
    /// сразу finish'ится с RESULT_CANCELED — для приложения неотличимо от
    /// «юзер передумал», поэтому импорт выглядел как немая кнопка
    /// (жалоба 4PDA). `resolveActivity` тут не помогает: он находит заглушку
    /// и возвращает не-null.
    ///
    /// Поэтому проверяем не «есть ли обработчик», а «есть ли обработчик,
    /// который не является заглушкой». Устройство-verified на эмуляторе
    /// Android TV (API 31): единственный кандидат — frameworkpackagestubs;
    /// на телефоне — com.google.android.documentsui.
    private fun hasRealFilePicker(): Boolean = filePickerAction() != null

    /// §383 — какой intent-action обслуживает НАСТОЯЩИЙ (не-заглушка) пикер.
    ///
    /// §372 спрашивал только про `ACTION_OPEN_DOCUMENT` — это SAF, и
    /// регистрируются на него DocumentsProvider-приложения. Файловые
    /// менеджеры старой школы (Total Commander и аналоги, массовые на 7.x)
    /// объявляют себя обработчиками `ACTION_GET_CONTENT` и на OPEN_DOCUMENT
    /// не отвечают. На устройстве такого юзера детект возвращал «пикера нет»
    /// при установленном менеджере (репорт 4PDA, Android TV 7.1.1) — и импорт
    /// был закрыт наглухо, хотя рабочий обработчик в системе есть.
    ///
    /// Возвращает `ACTION_OPEN_DOCUMENT` (приоритет — постоянный доступ к Uri
    /// и штатный путь через плагин), иначе `ACTION_GET_CONTENT`, иначе null.
    /// Фильтр заглушек применяется к ОБОИМ спискам: TV-framework подкладывает
    /// `frameworkpackagestubs` и на GET_CONTENT (`Stubs$MediaStub`), без
    /// фильтра §372 сломался бы.
    private fun filePickerAction(): String? {
        for (action in listOf(Intent.ACTION_OPEN_DOCUMENT, Intent.ACTION_GET_CONTENT)) {
            val intent = Intent(action)
                .addCategory(Intent.CATEGORY_OPENABLE)
                .setType("*/*")
            val candidates = packageManager.queryIntentActivities(intent, 0)
            if (candidates.any { !isStubHandler(it.activityInfo?.packageName) }) {
                return action
            }
        }
        return null
    }

    /// §383 — собственный `ACTION_GET_CONTENT`-пик.
    ///
    /// Нужен потому, что `file_picker` 11.0.2 для `FileType.any` жёстко
    /// строит `ACTION_OPEN_DOCUMENT` (`FileUtils.kt:202`, ветка else), а
    /// параметра для смены action у плагина нет: подбором аргументов
    /// `pickFiles` этот случай не чинится.
    ///
    /// Результат приводим к тому, что уже ждёт `pickFileSafely`: имя + байты.
    /// Читаем именно БАЙТЫ — у `content://` Uri реального пути, как правило,
    /// нет, а все наши call-site'ы и так зовут пик с `withData: true`.
    private fun startGetContentPick(allowMultiple: Boolean, result: MethodChannel.Result) {
        if (pendingPickResult != null) {
            result.error("PICK_IN_PROGRESS", "Another pick is already running", null)
            return
        }
        val intent = Intent(Intent.ACTION_GET_CONTENT)
            .addCategory(Intent.CATEGORY_OPENABLE)
            .setType("*/*")
            .putExtra(Intent.EXTRA_ALLOW_MULTIPLE, allowMultiple)
        try {
            pendingPickResult = result
            startActivityForResult(intent, GET_CONTENT_REQUEST_CODE)
        } catch (e: Exception) {
            pendingPickResult = null
            Log.e(TAG, "startGetContentPick failed", e)
            result.error("PICK_FAILED", e.message, null)
        }
    }

    /// §383 — читает выбранный Uri в пару «имя + байты».
    /// null — прочитать не удалось (провайдер отдал закрытый поток и т.п.).
    private fun readPickedUri(uri: Uri): Map<String, Any>? {
        return try {
            val bytes = contentResolver.openInputStream(uri)?.use { it.readBytes() }
                ?: return null
            var name: String? = null
            runCatching {
                contentResolver.query(uri, null, null, null, null)?.use { c ->
                    val idx = c.getColumnIndex(android.provider.OpenableColumns.DISPLAY_NAME)
                    if (idx >= 0 && c.moveToFirst()) name = c.getString(idx)
                }
            }
            mapOf(
                "name" to (name ?: uri.lastPathSegment ?: "config"),
                "bytes" to bytes,
            )
        } catch (e: Exception) {
            Log.e(TAG, "readPickedUri failed", e)
            null
        }
    }

    /// §375 — есть ли на устройстве камера, пригодная для сканирования QR.
    ///
    /// FEATURE_CAMERA_ANY (API 17+) покрывает заднюю, фронтальную и внешнюю
    /// USB-камеру. На Android TV — false (камеры нет, пункт меню прячем);
    /// на приставке с подключённой веб-камерой — true, и сканер там работает.
    private fun hasCamera(): Boolean =
        packageManager.hasSystemFeature(android.content.pm.PackageManager.FEATURE_CAMERA_ANY)

    /// Пакеты-заглушки, которыми TV-framework затыкает отсутствующие
    /// системные приложения. Матчим по префиксу — имя различается между
    /// Android TV и Google TV сборками.
    private fun isStubHandler(pkg: String?): Boolean =
        pkg != null && pkg.contains("frameworkpackagestubs")

    /// §390 — package name того, кто установил приложение
    /// (`com.android.vending` для Play, `org.fdroid.fdroid` для F-Droid,
    /// null/менеджер файлов/`com.android.shell` для sideload'а).
    ///
    /// Возвращаем СЫРОЕ значение: маппинг в канал живёт на Dart-стороне одним
    /// местом и покрыт unit-тестами без device.
    ///
    /// minSdk проекта — 24, поэтому ветка с deprecated API обязательна:
    /// `getInstallSourceInfo` появился только в API 30.
    /// §425 — ISO-код страны сети в нижнем регистре. Разрешения не нужны:
    /// networkCountryIso/simCountryIso открыты любому приложению.
    private fun networkCountryIso(): String? = try {
        val tm = getSystemService(TELEPHONY_SERVICE) as? TelephonyManager
        val net = tm?.networkCountryIso?.takeIf { it.length == 2 }
        val sim = tm?.simCountryIso?.takeIf { it.length == 2 }
        (net ?: sim)?.lowercase()
    } catch (e: Throwable) {
        Log.w("MainActivity", "networkCountryIso failed", e)
        null
    }

    private fun installerPackageName(): String? = try {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            packageManager.getInstallSourceInfo(packageName).installingPackageName
        } else {
            @Suppress("DEPRECATION")
            packageManager.getInstallerPackageName(packageName)
        }
    } catch (e: Throwable) {
        // NameNotFoundException и пр. — канал неизвестен, Dart уйдёт в дефолт.
        Log.w("MainActivity", "installerPackageName failed", e)
        null
    }

    /// §390 — открывает [url], при отсутствии обработчика пробует
    /// [fallbackUrl]. Нужно для `market://`: на устройствах без Play intent не
    /// резолвится и `startActivity` бросает ActivityNotFoundException.
    ///
    /// Возвращает false, если не открылось ничем — Dart-сторона тогда
    /// копирует ссылку в буфер (существующий фолбэк `UrlLauncher.open`).
    private fun openUrlOrFallback(url: String, fallbackUrl: String?): Boolean {
        if (tryOpenUrl(url)) return true
        if (fallbackUrl != null && tryOpenUrl(fallbackUrl)) return true
        return false
    }

    private fun tryOpenUrl(url: String): Boolean = try {
        startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)))
        true
    } catch (e: Throwable) {
        Log.w("MainActivity", "openUrl failed for $url", e)
        false
    }

    /// §374 — пишет текст в публичную папку Downloads через MediaStore.
    ///
    /// Fallback экспорта бэкапа для устройств, где системного диалога
    /// сохранения (SAF `ACTION_CREATE_DOCUMENT`) нет — на Android TV его
    /// перехватывает та же заглушка, что и пикер (§372).
    ///
    /// Только API 29+: до scoped storage запись в public Downloads требует
    /// WRITE_EXTERNAL_STORAGE, которое приложение сознательно не просит.
    /// Гейт — в `canSaveToDownloads`; здесь дублируется ранним возвратом.
    ///
    /// Возвращает фактическое DISPLAY_NAME сохранённого файла — MediaStore
    /// сам разводит коллизии, дописывая ` (1)` к имени, и юзеру в снекбаре
    /// надо показать то имя, которое он реально найдёт в папке.
    /// null — любой сбой (места нет, запись отклонена).
    private fun saveToDownloads(fileName: String, content: String): String? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return null
        return try {
            val values = ContentValues().apply {
                put(MediaStore.Downloads.DISPLAY_NAME, fileName)
                put(MediaStore.Downloads.MIME_TYPE, "application/json")
                put(MediaStore.Downloads.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS)
                put(MediaStore.Downloads.IS_PENDING, 1)
            }
            val resolver = contentResolver
            val uri = resolver.insert(
                MediaStore.Downloads.EXTERNAL_CONTENT_URI, values,
            ) ?: return null
            resolver.openOutputStream(uri)?.use { it.write(content.toByteArray()) }
                ?: run {
                    resolver.delete(uri, null, null)
                    return null
                }
            // Снимаем IS_PENDING — до этого файл не виден другим приложениям.
            resolver.update(
                uri,
                ContentValues().apply { put(MediaStore.Downloads.IS_PENDING, 0) },
                null, null,
            )
            resolver.query(
                uri, arrayOf(MediaStore.Downloads.DISPLAY_NAME), null, null, null,
            )?.use { c ->
                if (c.moveToFirst()) c.getString(0) else fileName
            } ?: fileName
        } catch (t: Throwable) {
            Log.w(TAG, "saveToDownloads failed: ${t.message}")
            null
        }
    }

    private fun openAppPermissions(): Boolean {
        // Strategy 1: direct permissions UI
        val direct = Intent("android.intent.action.MANAGE_APP_PERMISSIONS")
            .putExtra("android.intent.extra.PACKAGE_NAME", packageName)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        if (direct.resolveActivity(packageManager) != null) {
            runCatching { startActivity(direct); return true }
                .onFailure { Log.w(TAG, "MANAGE_APP_PERMISSIONS failed: ${it.message}") }
        }
        // Strategy 2: APP_PERMISSION (singular) — alternate action на некоторых OEM
        val singular = Intent("android.intent.action.MANAGE_PERMISSION_APPS")
            .putExtra("android.intent.extra.PACKAGE_NAME", packageName)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        if (singular.resolveActivity(packageManager) != null) {
            runCatching { startActivity(singular); return true }
                .onFailure { Log.w(TAG, "MANAGE_PERMISSION_APPS failed: ${it.message}") }
        }
        // Strategy 3: generic App info (юзеру нужно tap на Permissions)
        val fallback = Intent(android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
            .setData(Uri.fromParts("package", packageName, null))
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        runCatching { startActivity(fallback); return true }
            .onFailure { Log.e(TAG, "openAppSettings (all strategies) failed: ${it.message}") }
        return false
    }

    /// §051 Phase 2 — return current Wi-Fi info как Map для Flutter
    /// MethodChannel. Тонкая обёртка над `WifiInfoReader.read()` — same
    /// defensive логика что у sing-box callback и auto-record observer.
    private fun getCurrentWifiInfoMap(): Map<String, String> {
        return when (val r = WifiInfoReader.read(this)) {
            is WifiInfoReader.Result.Success ->
                mapOf("ssid" to r.ssid, "bssid" to r.bssid)
            is WifiInfoReader.Result.PermissionMissing ->
                mapOf("error" to "permission_missing")
            is WifiInfoReader.Result.NoWifi ->
                mapOf("error" to "no_wifi")
            is WifiInfoReader.Result.UnknownSsid ->
                mapOf("error" to "unknown_ssid")
            is WifiInfoReader.Result.RuntimeError ->
                mapOf("error" to "runtime_error")
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == GET_CONTENT_REQUEST_CODE) {
            // §383 — результат своего GET_CONTENT-пика. Result забираем ДО
            // ветвлений и обнуляем поле: любой выход обязан ответить ровно раз.
            val pending = pendingPickResult ?: return
            pendingPickResult = null
            if (resultCode != Activity.RESULT_OK || data == null) {
                // Отмена — не ошибка: Dart-сторона разберёт null как PickCancelled.
                pending.success(null)
                return
            }
            // Множественный выбор приходит в `clipData`, одиночный — в `data`.
            // Менеджер может проигнорировать EXTRA_ALLOW_MULTIPLE и ответить
            // одним файлом: это законный исход, а не ошибка.
            val uris = mutableListOf<Uri>()
            val clip = data.clipData
            if (clip != null) {
                for (i in 0 until clip.itemCount) {
                    clip.getItemAt(i).uri?.let { uris.add(it) }
                }
            } else {
                data.data?.let { uris.add(it) }
            }
            if (uris.isEmpty()) {
                pending.success(null)
                return
            }
            val picked = uris.mapNotNull { readPickedUri(it) }
            if (picked.isEmpty()) {
                pending.error("PICK_READ_FAILED", "Cannot read the selected file", null)
            } else {
                pending.success(picked)
            }
            return
        }
        if (requestCode != VPN_REQUEST_CODE_QUICK) return
        if (resultCode == Activity.RESULT_OK) {
            BoxVpnService.start(applicationContext)
            if (finishAfterConsent) finish()
        } else {
            // §279 — текст через L10n (in-app язык может отличаться от системного).
            Toast.makeText(
                applicationContext,
                L10n.str(applicationContext, R.string.qc_consent_denied),
                Toast.LENGTH_SHORT,
            ).show()
            if (finishAfterConsent) finish()
        }
    }
}
