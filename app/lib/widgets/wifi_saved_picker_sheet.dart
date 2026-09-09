import 'package:flutter/material.dart';

import '../screens/app_settings_screen.dart';
import '../services/relative_time.dart';
import '../services/settings_storage.dart';
import '../services/app_log.dart';
import 'wifi_entry.dart';
import '../services/l10n/locale_controller.dart';
import 'app_bottom_sheet.dart';

/// §053 Stage 1 — extract bottom sheet «Pick saved Wi-Fi» из
/// `custom_rule_edit_screen.dart`. Self-contained: сам грузит данные
/// (`getCustomRules` + `getWifiHistory` + `getAutoRecordWifi`),
/// показывает modal, возвращает выбранный список.
///
/// `excludeRuleId` — текущее правило в editor. Его wifi entries уже
/// видны как chips, в picker'е не дублируются.
///
/// Returns `null` если юзер cancel'нул, либо `List<WifiEntry>` с
/// выбранными (может быть empty — но это equivalent cancel).
Future<List<WifiEntry>?> showWifiSavedPickerSheet(
  BuildContext context, {
  required String excludeRuleId,
}) async {
  // Load: "used in other rules" + history + auto-record flag.
  final allRules = await SettingsStorage.getCustomRules();
  final fromRules = <WifiEntry, List<String>>{};
  for (final r in allRules) {
    if (r.id == excludeRuleId) continue;
    final ssids = r.wifiSsids;
    final bssids = r.wifiBssids;
    final n = ssids.length > bssids.length ? ssids.length : bssids.length;
    for (var i = 0; i < n; i++) {
      final ssid = i < ssids.length ? ssids[i] : '';
      final bssid = i < bssids.length ? bssids[i] : '';
      if (ssid.isEmpty) continue;
      final entry = WifiEntry(ssid, bssid);
      fromRules.putIfAbsent(entry, () => []).add(r.name);
    }
  }
  final history = await SettingsStorage.getWifiHistory();
  final autoRecordOn = await SettingsStorage.getAutoRecordWifi();
  if (!context.mounted) return null;

  final selected = <WifiEntry>{};
  return showAppBottomSheet<List<WifiEntry>>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setSheetState) {
        bool isSelected(WifiEntry e) => selected.contains(e);
        void toggle(WifiEntry e, bool? v) {
          setSheetState(() {
            if (v == true) {
              selected.add(e);
            } else {
              selected.remove(e);
            }
          });
        }

        final entries = <Widget>[];

        // §051 Phase 3 — info-banner когда auto-record выключен.
        // Показываем всегда наверху списка (не только при пустой
        // истории), чтобы юзер видел почему «Pick saved» не растёт сам.
        if (!autoRecordOn) {
          entries.add(_autoRecordOffBanner(ctx, context));
        }

        if (fromRules.isNotEmpty) {
          entries.add(_sectionHeader(ctx, 'USED IN YOUR RULES'));
          for (final mapEntry in fromRules.entries) {
            final e = mapEntry.key;
            final ruleNames = mapEntry.value.join(', ');
            entries.add(
              CheckboxListTile(
                dense: true,
                value: isSelected(e),
                onChanged: (v) => toggle(e, v),
                title: Text(
                  e.bssid.isEmpty ? e.ssid : '${e.ssid} · ${e.bssid}',
                  style: const TextStyle(fontSize: 13),
                ),
                subtitle: Text(
                  getLocalText.s("→ in: %s", ruleNames),
                  style: const TextStyle(fontSize: 11),
                ),
              ),
            );
          }
        }

        if (history.isNotEmpty) {
          entries.add(_sectionHeader(ctx, 'HISTORY (last seen)'));
          for (final h in history) {
            final ssid = h['ssid'] ?? '';
            final bssid = h['bssid'] ?? '';
            if (ssid.isEmpty) continue;
            final e = WifiEntry(ssid, bssid);
            entries.add(
              _historyRow(
                ctx: ctx,
                entry: e,
                lastSeenIso: h['last_seen'] ?? '',
                isSelected: isSelected(e),
                onToggle: (v) => toggle(e, v),
                onRemove: () async {
                  await SettingsStorage.removeFromWifiHistory(ssid, bssid);
                  if (!ctx.mounted) return;
                  setSheetState(() {
                    history.removeWhere(
                      (x) =>
                          (x['ssid'] ?? '') == ssid &&
                          (x['bssid'] ?? '') == bssid,
                    );
                    selected.remove(e);
                  });
                },
              ),
            );
          }
        }

        // Empty (нет rules, нет history) и auto-record ON → short hint.
        // Когда auto-record OFF — banner выше уже всё объясняет.
        if (fromRules.isEmpty && history.isEmpty && autoRecordOn) {
          entries.add(
            Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                getLocalText.s(
                  "Nothing saved yet. Use \"Add current\" / \"Manual\" or stay on a Wi-Fi network for 5 minutes.",
                ),
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          );
        }

        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        getLocalText.s("Saved networks"),
                        style: Theme.of(ctx).textTheme.titleMedium,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () =>
                          Navigator.of(ctx).pop<List<WifiEntry>>(null),
                    ),
                  ],
                ),
              ),
              const Divider(height: 0),
              Flexible(child: ListView(shrinkWrap: true, children: entries)),
              const Divider(height: 0),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: Row(
                  children: [
                    const Spacer(),
                    TextButton(
                      onPressed: () =>
                          Navigator.of(ctx).pop<List<WifiEntry>>(null),
                      child: Text(getLocalText.s("Cancel")),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: selected.isEmpty
                          ? null
                          : () => Navigator.of(ctx).pop(selected.toList()),
                      child: Text(getLocalText.s("Add %d", selected.length)),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    ),
  );
}

Widget _sectionHeader(BuildContext ctx, String text) => Padding(
  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
  child: Text(
    text,
    style: TextStyle(
      fontSize: 11,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.5,
      color: Theme.of(ctx).colorScheme.onSurfaceVariant,
    ),
  ),
);

/// Info-banner: «Auto-record off → enable in Settings».
/// `outerCtx` нужен для Navigator.push (sheet ctx умрёт после pop).
Widget _autoRecordOffBanner(BuildContext ctx, BuildContext outerCtx) {
  return Container(
    margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: Theme.of(ctx).colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(8),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          Icons.info_outline,
          size: 16,
          color: Theme.of(ctx).colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                getLocalText.s("Auto-record is off"),
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Theme.of(ctx).colorScheme.onSurface,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                getLocalText.s(
                  "Enable it in Settings → Diagnostics to grow this list as you stay on Wi-Fi networks.",
                ),
                style: TextStyle(
                  fontSize: 11,
                  color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 6),
              OutlinedButton.icon(
                icon: const Icon(Icons.settings, size: 14),
                label: Text(getLocalText.s("Open Settings")),
                onPressed: () {
                  Navigator.of(ctx).pop<List<WifiEntry>>(null);
                  Navigator.of(outerCtx).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const AppSettingsScreen(initialTab: 2),
                    ),
                  );
                },
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(0, 28),
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  textStyle: const TextStyle(fontSize: 11),
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

Widget _historyRow({
  required BuildContext ctx,
  required WifiEntry entry,
  required String lastSeenIso,
  required bool isSelected,
  required void Function(bool?) onToggle,
  required Future<void> Function() onRemove,
}) {
  // Explicit row: Checkbox + текст + IconButton. CheckboxListTile с
  // `secondary: IconButton` имел hit-testing issues — IconButton ловил
  // тап но event пробулькивал к ListTile parent. Phase 3: ручная
  // разметка с clear bounds на каждый control.
  return InkWell(
    onTap: () => onToggle(!isSelected),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          Checkbox(
            value: isSelected,
            onChanged: onToggle,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  entry.bssid.isEmpty
                      ? entry.ssid
                      : '${entry.ssid} · ${entry.bssid}',
                  style: const TextStyle(fontSize: 13),
                ),
                const SizedBox(height: 2),
                Text(
                  humanLastSeen(lastSeenIso),
                  style: const TextStyle(fontSize: 11),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: getLocalText.s("Remove from history"),
            icon: const Icon(Icons.close, size: 18),
            visualDensity: VisualDensity.compact,
            onPressed: () async {
              await onRemove();
            },
          ),
        ],
      ),
    ),
  );
}

/// `5 минут назад` / `Yesterday` / `Mar 15` для wifi_history
/// `last_seen`. Empty input → `never`; malformed ISO → `unknown` +
/// AppLog warning (traceable malformed entries).
String humanLastSeen(String iso) {
  if (iso.isEmpty) return getLocalText.s("never");
  final dt = DateTime.tryParse(iso);
  if (dt == null) {
    // AppLog — machine-поверхность, остаётся английской (спека §4.4).
    AppLog.I.warning(
      '[wifi_history] humanLastSeen: malformed ISO timestamp "$iso"',
    );
    return getLocalText.s("unknown");
  }
  return relativeTime(DateTime.now(), dt);
}
