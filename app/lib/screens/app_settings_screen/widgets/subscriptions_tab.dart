import 'package:flutter/material.dart';

import '../../../services/l10n/locale_controller.dart';

/// §118 — App Settings → Subscriptions tab. Глобальные настройки HTTP-фетча
/// подписок: авто-обновление, кастомный User-Agent, HWID + device-meta
/// (Remnawave `x-hwid`/`x-device-os`/`x-ver-os`/`x-device-model`).
///
/// Stateless — значения и колбэки приходят от `_AppSettingsScreenState`
/// (паттерн как у [GeneralTab]). Отображает **effective** значения meta
/// (override > device-дефолт); сам override правится в edit-диалоге родителя.
class SubscriptionsTab extends StatelessWidget {
  const SubscriptionsTab({
    super.key,
    required this.loaded,
    required this.padding,
    required this.autoUpdateSubs,
    required this.onAutoUpdateSubsChanged,
    required this.autoUpdateDisabledSubs,
    required this.onAutoUpdateDisabledSubsChanged,
    required this.userAgent,
    required this.defaultUserAgent,
    required this.onEditUserAgent,
    required this.sendHwid,
    required this.onSendHwidChanged,
    required this.hwid,
    required this.deviceOs,
    required this.verOs,
    required this.deviceModel,
    required this.onEditHwid,
    required this.onRegenerateHwid,
    required this.onEditDeviceOs,
    required this.onEditVerOs,
    required this.onEditDeviceModel,
  });

  final bool loaded;
  final EdgeInsets padding;

  final bool autoUpdateSubs;
  final ValueChanged<bool> onAutoUpdateSubsChanged;

  /// §337 — обновлять и выключенные подписки. Зависимая от [autoUpdateSubs].
  final bool autoUpdateDisabledSubs;
  final ValueChanged<bool> onAutoUpdateDisabledSubsChanged;

  /// Пусто = дефолтный брендированный UA (показан как плейсхолдер).
  final String userAgent;
  final String defaultUserAgent;
  final VoidCallback onEditUserAgent;

  final bool sendHwid;
  final ValueChanged<bool> onSendHwidChanged;

  /// Effective-значения заголовков (override > device-дефолт).
  final String hwid;
  final String deviceOs;
  final String verOs;
  final String deviceModel;

  final VoidCallback onEditHwid;
  final VoidCallback onRegenerateHwid;
  final VoidCallback onEditDeviceOs;
  final VoidCallback onEditVerOs;
  final VoidCallback onEditDeviceModel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return ListView(
      padding: padding,
      children: [
        Text(getLocalText.s("Auto-update"),
            style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        SwitchListTile(
          title: Text(getLocalText.s("Auto-update subscriptions")),
          subtitle: Text(getLocalText.s("Refresh on app start, after VPN connects, and periodically. Manual ⟳ works regardless.")),
          secondary: const Icon(Icons.cloud_sync_outlined),
          value: autoUpdateSubs,
          onChanged: loaded ? onAutoUpdateSubsChanged : null,
        ),
        SwitchListTile(
          title: Text(getLocalText.s("Update disabled subscriptions")),
          subtitle: Text(getLocalText.s("Keep the node list of switched-off subscriptions fresh, so it is not stale when you switch one back on. Their nodes stay out of the config either way.")),
          secondary: const Icon(Icons.cloud_off_outlined),
          value: autoUpdateDisabledSubs,
          onChanged: loaded && autoUpdateSubs
              ? onAutoUpdateDisabledSubsChanged
              : null,
        ),
        const Divider(height: 32),
        Text(getLocalText.s("Fetch identity"),
            style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        ListTile(
          leading: const Icon(Icons.badge_outlined),
          title: Text(getLocalText.s("Custom User-Agent")),
          subtitle: Text(
            userAgent.isEmpty
                ? getLocalText.s("Default · %s", defaultUserAgent)
                : userAgent,
            style: TextStyle(
              fontStyle: userAgent.isEmpty ? FontStyle.italic : null,
            ),
          ),
          trailing: const Icon(Icons.edit_outlined),
          onTap: loaded ? onEditUserAgent : null,
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(
            getLocalText.s("Some panels return the config by a substring in the User-Agent — a custom UA without the \"LxBox\" token may yield an unsupported format and break the update. Change only if you know why."),
            style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
          ),
        ),
        SwitchListTile(
          title: Text(getLocalText.s("Send HWID")),
          subtitle: Text(getLocalText.s("Send x-hwid + device headers on every subscription fetch — for panels with HWID device limits (Remnawave). Off by default.")),
          secondary: const Icon(Icons.devices_outlined),
          value: sendHwid,
          onChanged: loaded ? onSendHwidChanged : null,
        ),
        if (sendHwid) ...[
          _editRow(
            context,
            icon: Icons.tag,
            label: 'HWID · x-hwid',
            value: hwid,
            monospace: true,
            onEdit: onEditHwid,
            extra: IconButton(
              icon: const Icon(Icons.refresh, size: 20),
              tooltip: getLocalText.s("Regenerate"),
              onPressed: loaded ? onRegenerateHwid : null,
            ),
          ),
          _editRow(context,
              icon: Icons.android, label: 'x-device-os', value: deviceOs,
              onEdit: onEditDeviceOs),
          _editRow(context,
              icon: Icons.numbers, label: 'x-ver-os', value: verOs,
              onEdit: onEditVerOs),
          _editRow(context,
              icon: Icons.phone_android,
              label: 'x-device-model',
              value: deviceModel,
              onEdit: onEditDeviceModel),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              getLocalText.s("These headers identify your device to the panel. Defaults come from the device — override any of them (empty = device default)."),
              style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
            ),
          ),
        ],
      ],
    );
  }

  Widget _editRow(
    BuildContext context, {
    required IconData icon,
    required String label,
    required String value,
    required VoidCallback onEdit,
    bool monospace = false,
    Widget? extra,
  }) {
    return ListTile(
      leading: Icon(icon),
      title: Text(label),
      subtitle: Text(
        value.isEmpty ? getLocalText.s("(empty)") : value,
        style: TextStyle(
          fontFamily: monospace ? 'monospace' : null,
          fontSize: monospace ? 12 : null,
          color: value.isEmpty
              ? Theme.of(context).colorScheme.onSurfaceVariant
              : null,
        ),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ?extra,
          IconButton(
            icon: const Icon(Icons.edit_outlined, size: 20),
            tooltip: getLocalText.s("Edit"),
            onPressed: loaded ? onEdit : null,
          ),
        ],
      ),
    );
  }
}
