import 'package:flutter/material.dart';

import '../../../main.dart';
import '../../../services/l10n/locale_controller.dart';
import 'update_status_row.dart';

/// General tab для App Settings.
///
/// Stateless — все значения и callback'и приходят от
/// `_AppSettingsScreenState`, который остаётся source-of-truth и делает
/// setState + side-effect внутри каждого callback'а. Поведение идентично
/// инлайн-версии (parent rebuild'ит этот widget на каждый setState).
class GeneralTab extends StatelessWidget {
  const GeneralTab({
    super.key,
    required this.loaded,
    required this.autoStart,
    required this.autoCheckUpdates,
    required this.autoPing,
    required this.haptic,
    required this.allowRotation,
    required this.autoReloadOnChange,
    required this.padding,
    required this.onAutoStartChanged,
    required this.onAutoCheckUpdatesChanged,
    required this.onAutoPingChanged,
    required this.onHapticChanged,
    required this.onAllowRotationChanged,
    required this.onAutoReloadOnChangeChanged,
    required this.onAddQuickSettingsTile,
    required this.onOpenBackup,
    required this.region,
    required this.detectedRegion,
    required this.onEditRegion,
  });

  final bool loaded;
  final bool autoStart;
  final bool autoCheckUpdates;
  final bool autoPing;
  final bool haptic;
  final bool allowRotation;

  /// §338 — автоперезапуск VPN при любом изменении конфига (жизнь без плашек).
  final bool autoReloadOnChange;
  final EdgeInsets padding;

  final ValueChanged<bool> onAutoStartChanged;
  final ValueChanged<bool> onAutoCheckUpdatesChanged;
  final ValueChanged<bool> onAutoPingChanged;
  final ValueChanged<bool> onHapticChanged;
  final ValueChanged<bool> onAllowRotationChanged;
  final ValueChanged<bool> onAutoReloadOnChangeChanged;
  final VoidCallback onAddQuickSettingsTile;
  final VoidCallback onOpenBackup;

  /// §425 — регион использования: `auto` | `none` | код страны.
  final String region;

  /// §425 — автоопределённая страна (`''` — не определилась).
  final String detectedRegion;
  final VoidCallback onEditRegion;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: padding,
      children: [
        Text(getLocalText.s("Appearance"),
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        RadioGroup<ThemeMode>(
          groupValue: themeNotifier.mode,
          onChanged: (v) { if (v != null) themeNotifier.setMode(v); },
          child: Column(
            children: ThemeMode.values.map((mode) {
              final label = switch (mode) {
                ThemeMode.system => 'System',
                ThemeMode.light => 'Light',
                ThemeMode.dark => 'Dark',
              };
              final icon = switch (mode) {
                ThemeMode.system => Icons.brightness_auto,
                ThemeMode.light => Icons.light_mode,
                ThemeMode.dark => Icons.dark_mode,
              };
              return RadioListTile<ThemeMode>(
                value: mode,
                title: Text(label),
                secondary: Icon(icon),
              );
            }).toList(),
          ),
        ),
        const SizedBox(height: 8),
        // §279 — выбор языка приложения; смена применяется мгновенно через
        // LocaleController (полный пайплайн: ARB + template + rebuild).
        Text(getLocalText.s("Language"),
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        RadioGroup<String>(
          groupValue: LocaleController.I.setting,
          onChanged: (v) { if (v != null) LocaleController.I.set(v); },
          child: Column(
            children: [
              RadioListTile<String>(
                value: 'system',
                title: Text(getLocalText.s("System default")),
                secondary: const Icon(Icons.language),
              ),
              // Эндонимы: каждая метка на своём языке, сознательно не из ARB
              // текущей локали.
              const RadioListTile<String>(
                value: 'en',
                title: Text('English'), // l10n-exempt: endonym
              ),
              const RadioListTile<String>(
                value: 'ru',
                title: Text('Русский'), // l10n-exempt: endonym
              ),
            ],
          ),
        ),
        const Divider(height: 32),
        // §425 — регион использования: общая настройка, потребители — пулы
        // WARP (loc.<cc>), дальше региональные дефолты правил.
        Text(getLocalText.s("Region"),
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        ListTile(
          leading: const Icon(Icons.public_outlined),
          title: Text(getLocalText.s("Usage region")),
          subtitle: Text(regionLabel(region, detectedRegion)),
          trailing: const Icon(Icons.edit_outlined),
          onTap: loaded ? onEditRegion : null,
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(
            getLocalText.s("The country you use the app in. Drives region-specific defaults: today the WARP SNI pool, later routing rule presets. Auto = country of the mobile network, then of the device locale."),
            style: TextStyle(
                fontSize: 11,
                color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
        ),
        const Divider(height: 32),
        Text(getLocalText.s("Behavior"),
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        SwitchListTile(
          title: Text(getLocalText.s("Auto-start on boot")),
          subtitle: Text(getLocalText.s("Start VPN when device turns on")),
          secondary: const Icon(Icons.power_settings_new),
          value: autoStart,
          onChanged: loaded ? onAutoStartChanged : null,
        ),
        // §220 — снятие портретной фиксации (планшетный фидбэк). Применяется
        // сразу, без рестарта; уважает системный auto-rotate.
        SwitchListTile(
          title: Text(getLocalText.s("Allow rotation")),
          subtitle: Text(getLocalText.s("Rotate to landscape when the device turns — handy on tablets. Follows the system auto-rotate setting.")),
          secondary: const Icon(Icons.screen_rotation),
          value: allowRotation,
          onChanged: loaded ? onAllowRotationChanged : null,
        ),
        // §338 — автоприменение изменений конфига к живому туннелю. Настройка
        // не про подписки: источник изменения любой (узел, detour, DNS,
        // routing, per-app), поэтому живёт в Behavior, а не в Subscriptions.
        SwitchListTile(
          title: Text(getLocalText.s("Auto-restart VPN on settings change")),
          subtitle: Text(getLocalText.s("Apply every config change to the running tunnel by itself, so no banner is left to tap. Each apply drops the tunnel for about 3 seconds and kills open connections.")),
          secondary: const Icon(Icons.restart_alt),
          value: autoReloadOnChange,
          onChanged: loaded ? onAutoReloadOnChangeChanged : null,
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(
            getLocalText.s("While this is on, the per-subscription \"On update\" setting is hidden — everything is applied immediately. Turning it off brings each subscription's own choice back."),
            style: TextStyle(
              fontSize: 11,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        const Divider(height: 32),
        Text(getLocalText.s("Quick connect"),
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        ListTile(
          leading: const Icon(Icons.dashboard_customize_outlined),
          title: Text(getLocalText.s("Quick Settings tile")),
          subtitle: Text(getLocalText.s("Add to status-bar shade for one-tap toggle. Android 13+ shows a system prompt; on older versions edit the shade manually.")),
          trailing: TextButton(
            onPressed: onAddQuickSettingsTile,
            child: Text(getLocalText.s("Add")),
          ),
        ),
        ListTile(
          leading: const Icon(Icons.touch_app_outlined),
          title: Text(getLocalText.s("Home-screen shortcut")),
          subtitle: Text(getLocalText.s("Long-press the L×Box icon on your home screen → choose \"Toggle VPN\".")),
        ),
        const Divider(height: 32),
        Text(getLocalText.s("Updates"),
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        SwitchListTile(
          title: Text(getLocalText.s("Check for updates on launch")),
          subtitle: Text(getLocalText.s("Pings github.com once a day to check for new releases. \"View\" opens the release page in browser; install is manual.")),
          secondary: const Icon(Icons.system_update_alt),
          value: autoCheckUpdates,
          onChanged: loaded ? onAutoCheckUpdatesChanged : null,
        ),
        const UpdateStatusRow(),
        const Divider(height: 32),
        Text(getLocalText.s("Feedback"),
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        SwitchListTile(
          title: Text(getLocalText.s("Auto-ping after connect")),
          subtitle: Text(getLocalText.s("Ping nodes of active group 5s after VPN starts (once per connect)")),
          secondary: const Icon(Icons.network_ping),
          value: autoPing,
          onChanged: loaded ? onAutoPingChanged : null,
        ),
        SwitchListTile(
          title: Text(getLocalText.s("Haptic feedback")),
          subtitle: Text(getLocalText.s("Vibrate on connect, disconnect and errors. Respects system \"Touch feedback\" setting")),
          secondary: const Icon(Icons.vibration),
          value: haptic,
          onChanged: loaded ? onHapticChanged : null,
        ),
        const Divider(height: 32),
        Text(getLocalText.s("Backup & restore"),
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        ListTile(
          leading: const Icon(Icons.import_export),
          title: Text(getLocalText.s("Backup & restore")),
          subtitle: Text(getLocalText.s("Export subscriptions, routing setup and preferences as JSON.")),
          trailing: const Icon(Icons.chevron_right),
          contentPadding: EdgeInsets.zero,
          onTap: onOpenBackup,
        ),
      ],
    );
  }

  /// §425 — подпись значения региона для плитки и диалога.
  static String regionLabel(String region, String detected) {
    if (region == 'none') return getLocalText.s("Not set");
    if (region == 'auto') {
      return detected.isEmpty
          ? getLocalText.s("Auto · country not detected")
          : getLocalText.s("Auto · %s", detected.toUpperCase());
    }
    return region.toUpperCase();
  }
}
