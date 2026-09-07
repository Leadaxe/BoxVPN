import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../main.dart';
import '../services/debug/bootstrap.dart';
import '../services/debug/transport/server.dart';
import '../services/haptic_service.dart';
import '../services/l10n/locale_controller.dart';
import '../services/settings_storage.dart';
import '../services/subscription/subscription_identity.dart';
import '../services/subscription/user_agent.dart';
import '../services/url_launcher.dart' as ul;
import '../services/usage_region.dart';
import '../services/warp/warp_endpoint_picker.dart';
import '../services/wifi_history_listener.dart';
import '../widgets/wifi_permission_dialog.dart';
import '../vpn/box_vpn_client.dart';
import 'app_settings_screen/app_settings_dialogs.dart';
import 'app_settings_screen/widgets/automation_tab.dart';
import 'app_settings_screen/widgets/diagnostics_tab.dart';
import 'app_settings_screen/widgets/general_tab.dart';
import 'app_settings_screen/widgets/subscriptions_tab.dart';
import 'backup_screen.dart';

class AppSettingsScreen extends StatefulWidget {
  const AppSettingsScreen({
    super.key,
    this.initialTab = 0,
    this.highlightCoreLogs = false,
  });

  /// 0 = General, 1 = Subscriptions, 2 = Diagnostics, 3 = Automation.
  /// Used by deep-links.
  final int initialTab;

  /// Если true — после первого render'а скроллим к «Forward sing-box logs»
  /// SwitchListTile и пульсируем подсветку 2.5s. Используется banner'ом
  /// в Live tab чтобы юзер сразу увидел нужный toggle.
  final bool highlightCoreLogs;

  @override
  State<AppSettingsScreen> createState() => _AppSettingsScreenState();
}

class _AppSettingsScreenState extends State<AppSettingsScreen> with WidgetsBindingObserver {
  final _vpn = BoxVpnClient();
  bool _autoStart = false;
  bool _haptic = true;
  bool _batteryWhitelisted = false;
  bool _notificationsEnabled = true;
  bool _backgroundLocationGranted = false;
  bool _nearbyWifiGranted = false;
  bool _autoPing = true;
  bool _autoUpdateSubs = true;
  bool _autoUpdateDisabledSubs = false;
  bool _autoReloadOnChange = false;
  bool _autoCheckUpdates = true;
  // §220 — снятие портретной фиксации (default OFF = портрет).
  bool _allowRotation = false;
  bool _loaded = false;
  // §207 — pprof capture in flight (goroutine dump / CPU profile). Guards
  // both buttons so a double-tap can't spin two servers on the same port.

  bool _debugEnabled = false;
  String _debugToken = '';
  int _debugPort = SettingsStorage.debugPortDefault;
  late final TextEditingController _debugPortCtl;
  String _debugPortError = '';

  bool _coreLogsEnabled = false;
  bool _configLocked = false;

  // Для deep-link «highlightCoreLogs» из Live tab banner'а — скроллим
  // к этому tile'у после первого render'а и пульсируем background 2.5s.
  final GlobalKey _coreLogsTileKey = GlobalKey();
  bool _coreLogsHighlighted = false;
  Timer? _coreLogsHighlightTimer;
  // §051 Phase 3 — auto-record visited Wi-Fi networks (default off).
  bool _autoRecordWifi = false;

  // §118 — subscription fetch identity (UA override + HWID + device-meta).
  // _deviceOs/_verOs/_deviceModel — OVERRIDE-значения (пусто = device-дефолт).
  String _userAgent = '';
  bool _sendHwid = false;
  String _hwid = '';
  String _deviceOs = '';
  String _verOs = '';
  String _deviceModel = '';
  // §425 — регион использования + автоопределённая страна.
  String _region = SettingsStorage.regionAuto;
  String _detectedRegion = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _debugPortCtl = TextEditingController();
    unawaited(_loadAutoStart());
    if (widget.highlightCoreLogs) {
      // Tile живёт в Diagnostics tab (initialTab=2). Tab сам строит
      // children когда юзер на нём — postFrame этого build'а гарантирует
      // что _coreLogsTileKey.currentContext доступен.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollToAndHighlightCoreLogs();
      });
    }
  }

  void _scrollToAndHighlightCoreLogs() {
    final ctx = _coreLogsTileKey.currentContext;
    if (ctx == null) return;
    Scrollable.ensureVisible(
      ctx,
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeOutCubic,
      alignment: 0.3, // tile в верхней трети viewport'а — так юзер сразу видит
    );
    setState(() => _coreLogsHighlighted = true);
    _coreLogsHighlightTimer?.cancel();
    _coreLogsHighlightTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _coreLogsHighlighted = false);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _debugPortCtl.dispose();
    _coreLogsHighlightTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Юзер вернулся из системных настроек — перечитать whitelist-статус.
    if (state == AppLifecycleState.resumed) {
      unawaited(_refreshBatteryStatus());
    }
  }

  Future<void> _loadAutoStart() async {
    // §189 — auto_start / core_logs читаем из JSON-зеркала native_prefs.
    final auto = await SettingsStorage.getNativeBool(NativePrefsKeys.autoStart);
    final haptic = await SettingsStorage.getVar(HapticService.prefsKey, 'true');
    final autoPing = await SettingsStorage.getVar('auto_ping_on_start', 'true');
    final battery = await _vpn.isIgnoringBatteryOptimizations();
    final notifications = await _vpn.areNotificationsEnabled();
    final bgLocation = await ul.UrlLauncher.checkBackgroundLocationPermission();
    final nearbyWifi = await ul.UrlLauncher.checkNearbyWifiPermission();
    final autoUpdateSubs = await SettingsStorage.getAutoUpdateSubs();
    final autoUpdateDisabledSubs =
        await SettingsStorage.getAutoUpdateDisabledSubs();
    final autoReloadOnChange = await SettingsStorage.getAutoReloadOnChange();
    final autoCheckUpdates = await SettingsStorage.getAutoCheckUpdates();
    final allowRotation = await SettingsStorage.getAllowRotation();
    final debugEnabled = await SettingsStorage.getDebugEnabled();
    final debugToken = await SettingsStorage.getDebugToken();
    final debugPort = await SettingsStorage.getDebugPort();
    final coreLogsEnabled =
        await SettingsStorage.getNativeBool(NativePrefsKeys.coreLogsEnabled);
    final configLocked = await SettingsStorage.getConfigLockedForDebug();
    final autoRecordWifi = await SettingsStorage.getAutoRecordWifi();
    final userAgent =
        await SettingsStorage.getVar(SubscriptionIdentity.varUserAgent, '');
    final sendHwid =
        (await SettingsStorage.getVar(SubscriptionIdentity.varSendHwid,
            'false')) ==
            'true';
    final hwid =
        await SettingsStorage.getVar(SubscriptionIdentity.varHwid, '');
    final deviceOs =
        await SettingsStorage.getVar(SubscriptionIdentity.varDeviceOs, '');
    final verOs =
        await SettingsStorage.getVar(SubscriptionIdentity.varVerOs, '');
    final deviceModel =
        await SettingsStorage.getVar(SubscriptionIdentity.varDeviceModel, '');
    final region = await SettingsStorage.getRegion();
    final detectedRegion = await UsageRegion.detected();
    if (mounted) {
      setState(() {
        _region = region;
        _detectedRegion = detectedRegion;
        _userAgent = userAgent;
        _sendHwid = sendHwid;
        _hwid = hwid;
        _deviceOs = deviceOs;
        _verOs = verOs;
        _deviceModel = deviceModel;
        _autoStart = auto;
        _haptic = haptic != 'false';
        _autoPing = autoPing != 'false';
        _batteryWhitelisted = battery;
        _notificationsEnabled = notifications;
        _backgroundLocationGranted = bgLocation;
        _nearbyWifiGranted = nearbyWifi;
        _autoUpdateSubs = autoUpdateSubs;
        _autoUpdateDisabledSubs = autoUpdateDisabledSubs;
        _autoReloadOnChange = autoReloadOnChange;
        _autoCheckUpdates = autoCheckUpdates;
        _allowRotation = allowRotation;
        _debugEnabled = debugEnabled;
        _debugToken = debugToken;
        _debugPort = debugPort;
        _debugPortCtl.text = debugPort.toString();
        _coreLogsEnabled = coreLogsEnabled;
        _configLocked = configLocked;
        _autoRecordWifi = autoRecordWifi;
        _loaded = true;
      });
    }
  }

  /// §037 — toggle config_locked_for_debug.
  /// Когда true — `SubscriptionController.generateConfig()` тихо skip'ает
  /// rebuild при UI-действиях, и pinned config.json (например, отправленный
  /// через Debug API `PUT /config`) остаётся в живых.
  Future<void> _toggleConfigLocked(bool locked) async {
    setState(() => _configLocked = locked);
    await SettingsStorage.setConfigLockedForDebug(locked);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(locked
            ? getLocalText.s("Config locked. UI actions will not rebuild config.")
            : getLocalText.s("Config unlocked. Next UI action will rebuild from settings.")),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // §031 Debug API — toggle / token / port handlers.
  //
  // Все изменения ведут к [applyDebugApiSettings], который читает SettingsStorage
  // и приводит DebugServer в соответствие (start/stop/rebind).
  // ---------------------------------------------------------------------------

  Future<void> _toggleDebugApi(bool enable) async {
    setState(() => _debugEnabled = enable);
    await SettingsStorage.setDebugEnabled(enable);
    if (enable && _debugToken.isEmpty) {
      final token = DebugServer.generateToken();
      await SettingsStorage.setDebugToken(token);
      if (mounted) setState(() => _debugToken = token);
    }
    // §037 — config lock is a debug-only feature. Disabling Debug API
    // implicitly unlocks: иначе юзер останется с pinned config'ом без
    // UI-способа его разблокировать (lock toggle живёт под Debug API
    // блоком и спрятан, когда API выключен).
    if (!enable && _configLocked) {
      await SettingsStorage.setConfigLockedForDebug(false);
      if (mounted) setState(() => _configLocked = false);
    }
    await applyDebugApiSettings();
  }

  Future<void> _regenerateDebugToken() async {
    final token = DebugServer.generateToken();
    await SettingsStorage.setDebugToken(token);
    if (mounted) setState(() => _debugToken = token);
    await applyDebugApiSettings();
  }

  Future<void> _copyDebugToken() async {
    await Clipboard.setData(ClipboardData(text: _debugToken));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(getLocalText.s("Token copied")),
        duration: const Duration(seconds: 1),
      ),
    );
  }

  Future<void> _applyDebugPort(String raw) async {
    final port = int.tryParse(raw);
    if (port == null ||
        port < SettingsStorage.debugPortMin ||
        port > SettingsStorage.debugPortMax) {
      setState(() => _debugPortError =
          'port must be ${SettingsStorage.debugPortMin}..${SettingsStorage.debugPortMax}');
      return;
    }
    if (port == _debugPort) {
      setState(() => _debugPortError = '');
      return;
    }
    setState(() {
      _debugPort = port;
      _debugPortError = '';
    });
    await SettingsStorage.setDebugPort(port);
    await applyDebugApiSettings();
  }

  /// §043: toggle forwarding sing-box логов в наш AppLog как `DebugSource.core`.
  /// Изменение применяется ТОЛЬКО после полного рестарта процесса — `Libbox.setup`
  /// с флагом `debug` вызывается один раз в `BoxApplication.initialize` (см.
  /// гард `if (initialized) return`). Stop/start VPN не помогает (service-level,
  /// не process-level), нужен force-stop + relaunch. Кнопка «Quit & reopen»
  /// рядом с toggle делает это вызовом `quitApp()` (finishAffinity + killProcess
  /// в Kotlin); юзер сам тапает иконку и получает свежий процесс.
  Future<void> _toggleCoreLogs(bool enable) async {
    setState(() => _coreLogsEnabled = enable);
    // §189 — через NativePrefs (JSON-истина + зеркало в native).
    await SettingsStorage.setNativeBool(
        NativePrefsKeys.coreLogsEnabled, enable);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(getLocalText.s("Saved. Force-stop & reopen app to apply.")),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  /// §043 follow-up: confirm-диалог + `BoxVpnClient.quitApp()`. Process умрёт
  /// через ~250ms; Future от quitApp в норме не ресолвится — поэтому ничего
  /// не делаем после await.
  Future<void> _confirmQuitApp() async {
    final ok = await AppSettingsDialogs.confirmQuitApp(context);
    if (ok != true) return;
    await _vpn.quitApp();
  }

  /// §220 — toggle «Allow rotation». Применяется мгновенно (helper дёргает
  /// SystemChrome.setPreferredOrientations), рестарт не нужен.
  Future<void> _toggleAllowRotation(bool allow) async {
    setState(() => _allowRotation = allow);
    await SettingsStorage.setAllowRotation(allow);
    await applyAllowRotationSetting();
  }

  /// §032 Quick Connect — кнопка «Add tile» в General-табе.
  /// На API 33+ система сама покажет prompt; на более старых — даём
  /// текстовую инструкцию (drag через шторку).
  Future<void> _addQuickSettingsTile() async {
    final result = await _vpn.requestAddTile();
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final msg = switch (result) {
      'added' => 'Tile added to Quick Settings.',
      'already' => 'Tile is already in Quick Settings.',
      'dismissed' => 'Add tile dismissed.',
      'unsupported' =>
        'Your Android version doesn\'t support an in-app prompt. '
            'Pull down the status bar → edit tiles → drag L×Box to active tiles.',
      'no_activity' => 'Cannot show prompt right now — try again.',
      _ => 'Could not request tile add ($result). '
            'Pull down the status bar → edit tiles → drag L×Box manually.',
    };
    final duration = (result == 'unsupported' ||
            result.startsWith('error') ||
            result == 'no_activity')
        ? const Duration(seconds: 6)
        : const Duration(seconds: 3);
    messenger.showSnackBar(SnackBar(content: Text(msg), duration: duration));
  }

  /// Tap on the Notifications row in Background → System setup.
  ///
  /// — granted   → open per-app notification settings (toggle categories etc.)
  /// — denied    → try the runtime POST_NOTIFICATIONS prompt; if that returns
  ///               with permission still denied (user picked "Don't allow", or
  ///               had previously selected "Don't ask again"), fall back to
  ///               the App Permissions screen.
  Future<void> _onNotificationsTap() async {
    final granted = await ul.UrlLauncher.checkNotificationPermission();
    if (granted) {
      await _vpn.openNotificationSettings();
      return;
    }
    await ul.UrlLauncher.requestNotificationPermission();
    // Re-check; system dialog is async, but on API 33+ it resolves before the
    // call returns. If "Don't ask again" was previously chosen, the prompt
    // is silently skipped — push the user to Settings instead.
    final after = await ul.UrlLauncher.checkNotificationPermission();
    if (mounted) {
      setState(() => _notificationsEnabled = after);
    }
    if (!after) {
      await ul.UrlLauncher.openAppSettings();
    }
  }

  Future<void> _refreshBatteryStatus() async {
    final battery = await _vpn.isIgnoringBatteryOptimizations();
    final notifications = await _vpn.areNotificationsEnabled();
    final bgLocation = await ul.UrlLauncher.checkBackgroundLocationPermission();
    final nearbyWifi = await ul.UrlLauncher.checkNearbyWifiPermission();
    if (mounted) {
      setState(() {
        _batteryWhitelisted = battery;
        _notificationsEnabled = notifications;
        _backgroundLocationGranted = bgLocation;
        _nearbyWifiGranted = nearbyWifi;
      });
    }
  }

  /// §051 — tap на «Nearby Wi-Fi» row. Симметрично Notifications row:
  /// - granted → App Permissions screen (юзер видит/может revoke)
  /// - denied  → shared `WifiPermissionDialog` (объяснение + runtime prompt
  ///             + Settings fallback)
  /// State после возврата из Settings рефрешится через
  /// `didChangeAppLifecycleState` → `_refreshBatteryStatus`.
  Future<void> _onNearbyWifiTap() async {
    final granted = await ul.UrlLauncher.checkNearbyWifiPermission();
    if (granted) {
      await ul.UrlLauncher.openAppSettings();
      return;
    }
    if (!mounted) return;
    await WifiPermissionDialog.show(
      context,
      missing: const ['android.permission.NEARBY_WIFI_DEVICES'],
    );
    final after = await ul.UrlLauncher.checkNearbyWifiPermission();
    if (mounted) setState(() => _nearbyWifiGranted = after);
  }

  /// §051 — tap на «Location (background)» row.
  /// - granted → App Permissions screen
  /// - denied  → shared `WifiPermissionDialog` (для BACKGROUND_LOCATION
  ///             runtime prompt бесполезен на API 30+, dialog покажет
  ///             только «Open Settings»).
  Future<void> _onBackgroundLocationTap() async {
    final granted =
        await ul.UrlLauncher.checkBackgroundLocationPermission();
    if (granted) {
      await ul.UrlLauncher.openAppSettings();
      return;
    }
    if (!mounted) return;
    await WifiPermissionDialog.show(
      context,
      missing: const ['android.permission.ACCESS_BACKGROUND_LOCATION'],
    );
    final after =
        await ul.UrlLauncher.checkBackgroundLocationPermission();
    if (mounted) setState(() => _backgroundLocationGranted = after);
  }

  /// Preset-инструкции перед переходом в system App info — OEM'ы прячут
  /// нужные тоглы в разных местах, юзер без подсказки теряется.
  Future<void> _openAppInfoWithHint() async {
    final proceed = await AppSettingsDialogs.openAppInfoHint(context);
    if (proceed == true) await _vpn.openAppDetailsSettings();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      // §279 — слушаем и LocaleController: этот экран показан как pushed route,
      // rebuild корневого MaterialApp его не перестраивает (Navigator держит
      // route поверх). Без подписки смена языка не двигала radio-галку picker'а
      // и не перерисовывала строки самого экрана настроек.
      animation: Listenable.merge([themeNotifier, LocaleController.I]),
      builder: (context, _) {
        return DefaultTabController(
          length: 4,
          initialIndex: widget.initialTab.clamp(0, 3),
          child: Scaffold(
            appBar: AppBar(
              title: Text(getLocalText.s("App Settings")),
              bottom: _FadingTabBar(
                tabs: [
                  Tab(text: getLocalText.s("General")),
                  Tab(text: getLocalText.s("Subscriptions")),
                  Tab(text: getLocalText.s("Diagnostics")),
                  Tab(text: getLocalText.s("Automation")),
                ],
              ),
            ),
            body: TabBarView(
              children: [
                _buildGeneralTab(context),
                _buildSubscriptionsTab(context),
                _buildDiagnosticsTab(context),
                AutomationTab(padding: _tabPadding(context)),
              ],
            ),
          ),
        );
      },
    );
  }

  EdgeInsets _tabPadding(BuildContext context) => EdgeInsets.fromLTRB(
      12, 12, 12, MediaQuery.of(context).padding.bottom + 24);

  // ─── §118 subscription fetch identity (UA override + HWID + meta) ──────

  Future<String?> _editIdentityText({
    required String title,
    required String initial,
    String? hint,
    bool monospace = false,
  }) async {
    final ctl = TextEditingController(text: initial);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctl,
          autofocus: true,
          maxLines: null,
          style: monospace
              ? const TextStyle(fontFamily: 'monospace', fontSize: 13)
              : null,
          decoration: InputDecoration(
            hintText: hint,
            border: const OutlineInputBorder(),
            isDense: true,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(getLocalText.s("Cancel")),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ctl.text),
            child: Text(getLocalText.s("Save")),
          ),
        ],
      ),
    );
    ctl.dispose();
    return result;
  }

  Future<void> _editUserAgent() async {
    final v = await _editIdentityText(
      title: 'Custom User-Agent',
      initial: _userAgent,
      hint: resolveSubscriptionUserAgent(),
    );
    if (v == null) return;
    final trimmed = v.trim();
    setState(() => _userAgent = trimmed);
    await SettingsStorage.setVar(SubscriptionIdentity.varUserAgent, trimmed);
    SubscriptionIdentity.apply(userAgentOverride: trimmed);
  }

  void _setSendHwid(bool val) {
    // §118 — лениво генерим UUID при первом включении (решение №2/№3).
    if (val && _hwid.isEmpty) {
      _hwid = generateUuidV4();
      unawaited(SettingsStorage.setVar(SubscriptionIdentity.varHwid, _hwid));
      SubscriptionIdentity.apply(hwid: _hwid);
    }
    setState(() => _sendHwid = val);
    unawaited(SettingsStorage.setVar(
        SubscriptionIdentity.varSendHwid, val.toString()));
    SubscriptionIdentity.apply(sendHwid: val);
  }

  Future<void> _editHwid() async {
    final v = await _editIdentityText(
      title: 'HWID',
      initial: _hwid,
      monospace: true,
    );
    if (v == null) return;
    final trimmed = v.trim();
    setState(() => _hwid = trimmed);
    await SettingsStorage.setVar(SubscriptionIdentity.varHwid, trimmed);
    SubscriptionIdentity.apply(hwid: trimmed);
  }

  void _regenerateHwid() {
    final v = generateUuidV4();
    setState(() => _hwid = v);
    unawaited(SettingsStorage.setVar(SubscriptionIdentity.varHwid, v));
    SubscriptionIdentity.apply(hwid: v);
  }

  Future<void> _editDeviceOs() async {
    final v = await _editIdentityText(
      title: 'x-device-os',
      initial: _deviceOs,
      hint: SubscriptionIdentity.deviceOsDefault,
    );
    if (v == null) return;
    final t = v.trim();
    setState(() => _deviceOs = t);
    await SettingsStorage.setVar(SubscriptionIdentity.varDeviceOs, t);
    SubscriptionIdentity.apply(deviceOsOverride: t);
  }

  Future<void> _editVerOs() async {
    final v = await _editIdentityText(
      title: 'x-ver-os',
      initial: _verOs,
      hint: SubscriptionIdentity.osVersion,
    );
    if (v == null) return;
    final t = v.trim();
    setState(() => _verOs = t);
    await SettingsStorage.setVar(SubscriptionIdentity.varVerOs, t);
    SubscriptionIdentity.apply(verOsOverride: t);
  }

  Future<void> _editDeviceModel() async {
    final v = await _editIdentityText(
      title: 'x-device-model',
      initial: _deviceModel,
      hint: SubscriptionIdentity.deviceModel,
    );
    if (v == null) return;
    final t = v.trim();
    setState(() => _deviceModel = t);
    await SettingsStorage.setVar(SubscriptionIdentity.varDeviceModel, t);
    SubscriptionIdentity.apply(deviceModelOverride: t);
  }

  Widget _buildSubscriptionsTab(BuildContext context) {
    return SubscriptionsTab(
      loaded: _loaded,
      padding: _tabPadding(context),
      autoUpdateSubs: _autoUpdateSubs,
      onAutoUpdateSubsChanged: (val) {
        setState(() => _autoUpdateSubs = val);
        unawaited(SettingsStorage.setAutoUpdateSubs(val));
      },
      autoUpdateDisabledSubs: _autoUpdateDisabledSubs,
      onAutoUpdateDisabledSubsChanged: (val) {
        setState(() => _autoUpdateDisabledSubs = val);
        unawaited(SettingsStorage.setAutoUpdateDisabledSubs(val));
      },
      userAgent: _userAgent,
      defaultUserAgent: resolveSubscriptionUserAgent(),
      onEditUserAgent: () => unawaited(_editUserAgent()),
      sendHwid: _sendHwid,
      onSendHwidChanged: _setSendHwid,
      hwid: _hwid,
      deviceOs: SubscriptionIdentity.effectiveDeviceOs,
      verOs: SubscriptionIdentity.effectiveVerOs,
      deviceModel: SubscriptionIdentity.effectiveDeviceModel,
      onEditHwid: () => unawaited(_editHwid()),
      onRegenerateHwid: _regenerateHwid,
      onEditDeviceOs: () => unawaited(_editDeviceOs()),
      onEditVerOs: () => unawaited(_editVerOs()),
      onEditDeviceModel: () => unawaited(_editDeviceModel()),
    );
  }

  Widget _buildGeneralTab(BuildContext context) {
    return GeneralTab(
      loaded: _loaded,
      autoStart: _autoStart,
      autoCheckUpdates: _autoCheckUpdates,
      autoPing: _autoPing,
      haptic: _haptic,
      allowRotation: _allowRotation,
      autoReloadOnChange: _autoReloadOnChange, // §338
      padding: _tabPadding(context),
      onAutoStartChanged: (val) {
        setState(() => _autoStart = val);
        // §189 — через NativePrefs (JSON-истина + зеркало в native).
        unawaited(
            SettingsStorage.setNativeBool(NativePrefsKeys.autoStart, val));
      },
      onAllowRotationChanged: (val) => unawaited(_toggleAllowRotation(val)),
      // §338 — автоприменение изменений конфига (любой источник, не подписки).
      onAutoReloadOnChangeChanged: (val) {
        setState(() => _autoReloadOnChange = val);
        unawaited(SettingsStorage.setAutoReloadOnChange(val));
      },
      onAutoCheckUpdatesChanged: (val) {
        setState(() => _autoCheckUpdates = val);
        unawaited(SettingsStorage.setAutoCheckUpdates(val));
      },
      onAutoPingChanged: (val) {
        setState(() => _autoPing = val);
        unawaited(SettingsStorage.setVar(
            'auto_ping_on_start', val.toString()));
      },
      onHapticChanged: (val) {
        setState(() => _haptic = val);
        HapticService.I.enabled = val;
        unawaited(SettingsStorage.setVar(HapticService.prefsKey, val.toString()));
        if (val) {
          HapticService.I.onConnectTap();
        }
      },
      onAddQuickSettingsTile: () => unawaited(_addQuickSettingsTile()),
      onOpenBackup: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const BackupScreen()),
      ),
      region: _region,
      detectedRegion: _detectedRegion,
      onEditRegion: () => unawaited(_editRegion()),
    );
  }

  /// §425 — выбор региона использования: auto / none / известные регионы
  /// (сегодня — ключи `loc` пула WARP) / произвольный код страны.
  Future<void> _editRegion() async {
    const other = '__other__';
    final known = await WarpEndpointPicker.availableRegions();
    if (!mounted) return;
    final options = [
      SettingsStorage.regionAuto,
      SettingsStorage.regionNone,
      ...known,
      // Явно выбранный код вне известного списка — показать, не терять.
      if (_region != SettingsStorage.regionAuto &&
          _region != SettingsStorage.regionNone &&
          !known.contains(_region))
        _region,
    ];
    var picked = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(getLocalText.s("Usage region")),
        children: [
          for (final o in options)
            RadioListTile<String>(
              value: o,
              // ignore: deprecated_member_use
              groupValue: _region,
              title: Text(GeneralTab.regionLabel(o, _detectedRegion)),
              // ignore: deprecated_member_use
              onChanged: (v) => Navigator.of(ctx).pop(v),
            ),
          ListTile(
            leading: const Icon(Icons.edit_outlined),
            title: Text(getLocalText.s("Other country code…")),
            onTap: () => Navigator.of(ctx).pop(other),
          ),
        ],
      ),
    );
    if (picked == other && mounted) {
      final ctl = TextEditingController(
          text: options.contains(_region) ? '' : _region.toUpperCase());
      picked = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(getLocalText.s("Country code (2 letters)")),
          content: TextField(
            controller: ctl,
            autofocus: true,
            maxLength: 2,
            textCapitalization: TextCapitalization.characters,
            decoration: const InputDecoration(hintText: 'IL'), // l10n-exempt
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text(getLocalText.s("Cancel")),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(ctl.text),
              child: Text(getLocalText.s("Save")),
            ),
          ],
        ),
      );
      if (picked != null &&
          SettingsStorage.normalizeRegion(picked) ==
              SettingsStorage.regionAuto) {
        picked = null; // мусор вместо кода — не сохраняем
      }
    }
    if (picked == null || !mounted) return;
    final norm = SettingsStorage.normalizeRegion(picked);
    setState(() => _region = norm);
    await SettingsStorage.setRegion(norm);
  }

  Widget _buildDiagnosticsTab(BuildContext context) {
    return DiagnosticsTab(
      loaded: _loaded,
      padding: _tabPadding(context),
      batteryWhitelisted: _batteryWhitelisted,
      notificationsEnabled: _notificationsEnabled,
      backgroundLocationGranted: _backgroundLocationGranted,
      nearbyWifiGranted: _nearbyWifiGranted,
      debugEnabled: _debugEnabled,
      debugPort: _debugPort,
      debugToken: _debugToken,
      debugPortError: _debugPortError,
      debugPortCtl: _debugPortCtl,
      configLocked: _configLocked,
      coreLogsEnabled: _coreLogsEnabled,
      coreLogsHighlighted: _coreLogsHighlighted,
      coreLogsTileKey: _coreLogsTileKey,
      autoRecordWifi: _autoRecordWifi,
      onBatteryTap: () async {
        await _vpn.openBatteryOptimizationSettings();
      },
      onNotificationsTap: _onNotificationsTap,
      onBackgroundLocationTap: _onBackgroundLocationTap,
      onNearbyWifiTap: _onNearbyWifiTap,
      onAppInfoTap: _openAppInfoWithHint,
      onDebugApiChanged: (val) => unawaited(_toggleDebugApi(val)),
      onCopyDebugToken: _copyDebugToken,
      onRegenerateDebugToken: () => unawaited(_regenerateDebugToken()),
      onDebugPortSubmitted: (v) => unawaited(_applyDebugPort(v)),
      onConfigLockedChanged: (val) => unawaited(_toggleConfigLocked(val)),
      onCoreLogsChanged: (val) => unawaited(_toggleCoreLogs(val)),
      onQuitApp: () => unawaited(_confirmQuitApp()),
      onAutoRecordWifiChanged: (val) => unawaited(_toggleAutoRecordWifi(val)),
    );
  }

  /// §051 Phase 3 — toggle для auto-record. Сразу sync'ит state в native
  /// observer (start/stop NetworkCallback). Существующая история не
  /// чистится при OFF — это user data, явный поход в Pick saved.
  Future<void> _toggleAutoRecordWifi(bool enabled) async {
    setState(() => _autoRecordWifi = enabled);
    await SettingsStorage.setAutoRecordWifi(enabled);
    await WifiHistoryListener.I.setEnabled(enabled);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 2),
        content: Text(enabled
            ? getLocalText.s("Auto-record on. Networks added after 5 min of stay.")
            : getLocalText.s("Auto-record off. Existing history kept.")),
      ),
    );
  }
}

/// Centered scrollable [TabBar] whose left & right edges fade to transparent,
/// so a tab clipped by the screen edge dissolves instead of being cut off —
/// a soft hint that the bar scrolls. The fade is a fixed-width edge gradient
/// (no scroll-metrics tracking) so it always renders on the first frame.
class _FadingTabBar extends StatelessWidget implements PreferredSizeWidget {
  const _FadingTabBar({required this.tabs});

  final List<Widget> tabs;

  // Width of each edge fade, in px.
  static const double _fadeWidth = 32;

  @override
  Size get preferredSize => const TabBar(tabs: []).preferredSize;

  @override
  Widget build(BuildContext context) {
    return ShaderMask(
      blendMode: BlendMode.dstIn,
      shaderCallback: (rect) {
        final stop = (_fadeWidth / rect.width).clamp(0.0, 0.5);
        return LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: const [
            Colors.transparent,
            Colors.white,
            Colors.white,
            Colors.transparent,
          ],
          stops: [0.0, stop, 1.0 - stop, 1.0],
        ).createShader(rect);
      },
      child: TabBar(
        isScrollable: true,
        tabAlignment: TabAlignment.center,
        tabs: tabs,
      ),
    );
  }
}
