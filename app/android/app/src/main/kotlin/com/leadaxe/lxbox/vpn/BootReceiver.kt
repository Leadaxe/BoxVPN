package com.leadaxe.lxbox.vpn

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

class BootReceiver : BroadcastReceiver() {
    companion object {
        private const val TAG = "BootReceiver"
        private const val PREF_NAME = "boxvpn_boot"
        private const val KEY_AUTO_START = "auto_start_vpn"
        private const val KEY_KEEP_ON_EXIT = "keep_vpn_on_exit"
        private const val KEY_BACKGROUND_MODE = "background_mode"
        /// §043: forwarding sing-box логов в Flutter EventChannel (см.
        /// `BoxApplication.initialize` где `SetupOptions.debug = ...`
        /// читается из этой prefs). Default false — opt-in для диагностики.
        /// Изменение применяется только после restart Service'а
        /// (Libbox.setup вызывается один раз).
        private const val KEY_CORE_LOGS = "core_logs_enabled"
        // §345 — live-переключаемый verbose (снятие TRACE/DEBUG-фильтра)
        private const val KEY_CORE_LOGS_VERBOSE = "core_logs_verbose"

        /// §049 F15 fix: разрешать app'ам обходить tun (Android `Builder.allowBypass()`).
        /// Default false — без bypass'а весь трафик уходит в tun (наша цель —
        /// strict tunnel). С bypass = true — app может явно через
        /// `ConnectivityManager.bindProcessToNetwork(network)` обойти VPN.
        /// Для большинства юзеров не нужно; opt-in для разработчиков.
        private const val KEY_ALLOW_BYPASS = "allow_bypass"

        /// §124 — root-only tproxy через nftables/iptables (`auto_redirect` в
        /// sing-tun). Работает ТОЛЬКО на рутированном Android (`redirect_linux.go`
        /// требует `su` + `/system/bin/iptables`); на не-root ядро вернёт ошибку.
        /// Default false. Проброс заведён (helper `BoxService.buildOverrideOptions`
        /// читает getter), UI-тоггла пока НЕТ — выставить можно через prefs/adb;
        /// полноценный UI + `auto_route` — отдельная таска.
        private const val KEY_AUTO_REDIRECT = "auto_redirect"

        /// §192 — есть ли TUN-inbound в текущем конфиге (производное от §119
        /// vpn_mode: vpn/vpn_proxy → true, proxy → false). Зеркало из Dart
        /// (§189 native_prefs). Гейтит `VpnService.prepare()`: в proxy-режиме
        /// (port-only, без TUN) prepare НЕ нужен и его вызов ЗРЯ забирает
        /// системный VPN-слот → отзывает чужой активный VPN (onRevoke).
        /// Default TRUE — безопасно: если ключа ещё нет (старый юзер / до
        /// первого sync), ведём себя как раньше (prepare вызывается, vpn-режим
        /// не ломается). proxy-фикс активируется только при явном has_tun=false.
        private const val KEY_HAS_TUN = "has_tun"

        /// §271 — memory limit ядра (SetupOptions.oomMemoryLimit). Wire-значения:
        /// "auto" (по RAM устройства), "off" (без лимита, oom-killer остаётся в
        /// Available-режиме), либо число мегабайт строкой ("200"/"384"/"512"/"768").
        /// Default "auto". Разрешение в байты — BoxApplication.resolveMemoryLimitBytes.
        private const val KEY_MEMORY_LIMIT = "memory_limit"

        const val MEMORY_LIMIT_AUTO = "auto"
        const val MEMORY_LIMIT_OFF = "off"

        /// §279 — язык приложения ("system" | "en" | "ru"). Derived cache от
        /// var `app_language` в lxbox_settings.json (истина — Dart-сторадж,
        /// спека 279 §6.5): пишется MethodChannel-handler'ом setAppLanguage и
        /// пере-пушится bootstrapAndSyncNativePrefs на каждом старте. Читается
        /// L10n.ctx в момент рендера нативных поверхностей (без Flutter).
        private const val KEY_APP_LANGUAGE = "app_language"

        /// §279 — зеркало последнего значения, которое МЫ запушили в
        /// LocaleManager (33+): "" = пустой список (system), "en"/"ru" — явный
        /// выбор; отсутствие ключа = ещё не пушили. Нужен трёхстороннему
        /// reconciliation на Dart-старте (спека 279 §6.4): расхождение
        /// getApplicationLocales с этим зеркалом = юзер менял язык в системных
        /// Settings → система побеждает.
        private const val KEY_LAST_PUSHED_LOCALE = "last_pushed_locale"

        /// §279 — updateShortcuts отработал под rate-limit (locale-change в
        /// background) → гарантированный retry из MainActivity.onResume
        /// (foreground, rate-limit не применяется).
        private const val KEY_SHORTCUT_RELABEL_PENDING = "shortcut_relabel_pending"
        /// §428 — предохранитель от шторма `START_STICKY`-рестартов: сколько
        /// раз система пересоздала сервис с null-intent в текущем окне и когда
        /// окно открылось. Сбрасывается успешным `Started`.
        private const val KEY_STICKY_RESTART_COUNT = "sticky_restart_count"
        private const val KEY_STICKY_RESTART_WINDOW_START = "sticky_restart_window_start"
        const val STICKY_RESTART_WINDOW_MS = 5 * 60 * 1000L
        const val STICKY_RESTART_LIMIT = 3

        /// Три режима фоновой работы tunnel'а. По умолчанию "never" — максимум
        /// стабильности, минимум экономии батареи. VPN-пользователи обычно
        /// выбирают надёжность (пуши, длинные TCP-сокеты), поэтому default
        /// именно такой.
        /// - "never": pause/wake не вызывается никогда, tunnel всегда активен
        /// - "lazy": pause при deep Doze (текущее поведение sing-box-android)
        /// - "always": pause при screen off (максимум экономии)
        const val BG_MODE_NEVER = "never"
        const val BG_MODE_LAZY = "lazy"
        const val BG_MODE_ALWAYS = "always"

        /// §279 — см. KEY_APP_LANGUAGE. Писать только через L10n.applySetting
        /// (pref + LocaleManager + relabel поверхностей одним путём).
        fun setAppLanguage(context: Context, value: String) {
            context.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
                .edit().putString(KEY_APP_LANGUAGE, value).apply()
        }

        fun getAppLanguage(context: Context): String {
            return context.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
                .getString(KEY_APP_LANGUAGE, "system") ?: "system"
        }

        /// §279 — см. KEY_LAST_PUSHED_LOCALE. null = ещё не пушили.
        fun setLastPushedLocale(context: Context, value: String) {
            context.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
                .edit().putString(KEY_LAST_PUSHED_LOCALE, value).apply()
        }

        fun getLastPushedLocale(context: Context): String? {
            return context.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
                .getString(KEY_LAST_PUSHED_LOCALE, null)
        }

        /// §279 — см. KEY_SHORTCUT_RELABEL_PENDING.
        fun setShortcutRelabelPending(context: Context, pending: Boolean) {
            context.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
                .edit().putBoolean(KEY_SHORTCUT_RELABEL_PENDING, pending).apply()
        }

        /// §428 — зафиксировать sticky-рестарт; возвращает номер рестарта в
        /// текущем окне (1 = первый). Окно старше STICKY_RESTART_WINDOW_MS
        /// открывается заново.
        fun noteStickyRestart(context: Context, now: Long = System.currentTimeMillis()): Int {
            val prefs = context.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
            val windowStart = prefs.getLong(KEY_STICKY_RESTART_WINDOW_START, 0L)
            val inWindow = windowStart > 0L && now - windowStart < STICKY_RESTART_WINDOW_MS
            val count = if (inWindow) prefs.getInt(KEY_STICKY_RESTART_COUNT, 0) + 1 else 1
            prefs.edit()
                .putInt(KEY_STICKY_RESTART_COUNT, count)
                .putLong(KEY_STICKY_RESTART_WINDOW_START, if (inWindow) windowStart else now)
                .apply()
            return count
        }

        fun resetStickyRestarts(context: Context) {
            context.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
                .edit()
                .remove(KEY_STICKY_RESTART_COUNT)
                .remove(KEY_STICKY_RESTART_WINDOW_START)
                .apply()
        }

        fun isShortcutRelabelPending(context: Context): Boolean {
            return context.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
                .getBoolean(KEY_SHORTCUT_RELABEL_PENDING, false)
        }

        fun setMemoryLimit(context: Context, value: String) {
            context.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
                .edit().putString(KEY_MEMORY_LIMIT, value).apply()
        }

        fun getMemoryLimit(context: Context): String {
            return context.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
                .getString(KEY_MEMORY_LIMIT, MEMORY_LIMIT_AUTO) ?: MEMORY_LIMIT_AUTO
        }

        fun setBackgroundMode(context: Context, mode: String) {
            context.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
                .edit().putString(KEY_BACKGROUND_MODE, mode).apply()
        }

        fun getBackgroundMode(context: Context): String {
            return context.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
                .getString(KEY_BACKGROUND_MODE, BG_MODE_NEVER) ?: BG_MODE_NEVER
        }

        fun setEnabled(context: Context, enabled: Boolean) {
            context.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
                .edit().putBoolean(KEY_AUTO_START, enabled).apply()
        }

        fun isEnabled(context: Context): Boolean {
            return context.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
                .getBoolean(KEY_AUTO_START, false)
        }

        fun setKeepOnExit(context: Context, enabled: Boolean) {
            context.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
                .edit().putBoolean(KEY_KEEP_ON_EXIT, enabled).apply()
        }

        fun isKeepOnExit(context: Context): Boolean {
            // §188 — дефолт ON (было false). keep-alive ожидаем пользователями
            // (VPN живёт при закрытии). Затрагивает существующих без явного ключа.
            return context.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
                .getBoolean(KEY_KEEP_ON_EXIT, true)
        }

        /// §043: forwarding sing-box логов в наш PlatformInterface.writeDebugMessage
        /// callback. Read by `BoxApplication.initialize` для `SetupOptions.debug`.
        /// Default false — opt-in для диагностики (сотни строк/мин на busy traffic).
        fun setCoreLogsEnabled(context: Context, enabled: Boolean) {
            context.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
                .edit().putBoolean(KEY_CORE_LOGS, enabled).apply()
        }

        fun isCoreLogsEnabled(context: Context): Boolean {
            return context.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
                .getBoolean(KEY_CORE_LOGS, false)
        }

        /// §345: verbose-режим core-логов — снимает TRACE/DEBUG-фильтр в
        /// `BoxService.writeDebugMessage`. Применяется на лету (volatile в
        /// BoxService), здесь — только persist для переживания рестарта.
        fun setCoreLogsVerbose(context: Context, enabled: Boolean) {
            context.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
                .edit().putBoolean(KEY_CORE_LOGS_VERBOSE, enabled).apply()
        }

        fun isCoreLogsVerbose(context: Context): Boolean {
            return context.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
                .getBoolean(KEY_CORE_LOGS_VERBOSE, false)
        }

        /// §049 F15 fix: opt-in toggle для VPN bypass. Reference (`Settings.allowBypass`).
        /// Default false — strict tunnel.
        fun setAllowBypass(context: Context, enabled: Boolean) {
            context.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
                .edit().putBoolean(KEY_ALLOW_BYPASS, enabled).apply()
        }

        fun isAllowBypass(context: Context): Boolean {
            return context.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
                .getBoolean(KEY_ALLOW_BYPASS, false)
        }

        /// §124 — см. KEY_AUTO_REDIRECT. Default false (strict / не-root безопасно).
        fun setAutoRedirect(context: Context, enabled: Boolean) {
            context.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
                .edit().putBoolean(KEY_AUTO_REDIRECT, enabled).apply()
        }

        fun isAutoRedirect(context: Context): Boolean {
            return context.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
                .getBoolean(KEY_AUTO_REDIRECT, false)
        }

        /// §192 — зеркало has_tun из Dart (§189). Default true (см. KEY_HAS_TUN).
        fun setHasTun(context: Context, enabled: Boolean) {
            context.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
                .edit().putBoolean(KEY_HAS_TUN, enabled).apply()
        }

        fun hasTun(context: Context): Boolean {
            return context.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
                .getBoolean(KEY_HAS_TUN, true)
        }
    }

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED) return
        if (!isEnabled(context)) return

        Log.d(TAG, "Boot completed — auto-starting VPN")
        BoxApplication.initialize(context)
        BoxVpnService.start(context)
    }
}
