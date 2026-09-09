import 'package:flutter/material.dart';

import '../../controllers/home_controller.dart';
import '../../models/home_state.dart';
import '../../services/settings_storage.dart';
import '../../services/template_loader.dart';
import '../../services/l10n/locale_controller.dart';
import '../../widgets/app_bottom_sheet.dart';

/// §070 — modal bottom sheet опций сортировки нод (long-press по sort-кнопке
/// в [NodesHeader]). Sheet остаётся открытым — можно тоггнуть несколько опций
/// подряд; `StatefulBuilder` перерисовывает чекбоксы локально. Изменения сразу
/// пишутся в [controller] (его `state` читается свежим на каждый rebuild —
/// между нашими `setSheetState` контроллер мог emit'нуть).
Future<void> showSortOptionsMenu(
  BuildContext context,
  HomeController controller,
) async {
  await showAppBottomSheet<void>(
    context: context,
    builder: (sheetCtx) => StatefulBuilder(
      builder: (sheetCtx, setSheetState) {
        final s = controller.state;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(getLocalText.s("Sort options"),
                    style: Theme.of(sheetCtx).textTheme.titleMedium),
                const SizedBox(height: 12),
                // §100 — выбор режима сортировки (incl. Custom = ручная,
                // включает видимые drag-полоски §098). Раньше manual входился
                // только через drag; теперь — явный выбор.
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    for (final m in NodeSortMode.values)
                      ChoiceChip(
                        avatar: Icon(m.icon, size: 16),
                        label: Text(m.label()),
                        selected: s.sortMode == m,
                        onSelected: (_) {
                          controller.setSortMode(m);
                          setSheetState(() {});
                        },
                      ),
                  ],
                ),
                const Divider(height: 24),
                CheckboxListTile(
                  value: s.pinDirect,
                  onChanged: (v) {
                    controller.setPinDirect(v ?? false);
                    setSheetState(() {});
                  },
                  title: Text(getLocalText.s("Pin DIRECT to top")),
                  controlAffinity: ListTileControlAffinity.leading,
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                ),
                CheckboxListTile(
                  value: s.pinAuto,
                  onChanged: (v) {
                    controller.setPinAuto(v ?? false);
                    setSheetState(() {});
                  },
                  title: Text(getLocalText.s("Pin AUTO to top")),
                  controlAffinity: ListTileControlAffinity.leading,
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                ),
                CheckboxListTile(
                  value: s.resortOnManualPing,
                  onChanged: (v) {
                    controller.setResortOnManualPing(v ?? false);
                    setSheetState(() {});
                  },
                  title: Text(getLocalText.s("Re-sort on manual ping")),
                  controlAffinity: ListTileControlAffinity.leading,
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                ),
              ],
            ),
          ),
        );
      },
    ),
  );
}

/// §040 — modal bottom sheet настроек ping (long-press по reload-кнопке).
/// Scope-переключатель All directions / текущее Направление (если у Направления есть
/// override — стартует в group-mode с его значениями). Пресеты URL из
/// template, ручные URL/timeout. Save пишет в [SettingsStorage] (глобально
/// или per-group) и дёргает `controller.reloadPingOptions()`.
Future<void> showPingSettings(
  BuildContext context,
  HomeController controller,
) async {
  // §279 — typed PingOptionsModel из локализованного шаблона (load() на
  // каждое открытие sheet'а → имена пресетов всегда на активной локали).
  final template = await TemplateLoader.load();
  final presets = template.pingOptionsModel.presets;

  if (!context.mounted) return;
  // §040: dialog scope — global / per-group. Если у текущего Направления есть
  // override → стартуем в group-mode с его значениями. Иначе global-mode
  // с глобальным URL/timeout (resolved через storage > template).
  final currentGroup = controller.state.selectedGroup ?? '';
  final allOpts = await SettingsStorage.getPingOptions();
  final groupsRaw = allOpts['groups'];
  final groupOverride =
      (groupsRaw is Map<String, dynamic>) && currentGroup.isNotEmpty
          ? (groupsRaw[currentGroup] as Map<String, dynamic>?)
          : null;
  final hasGroupOverride = groupOverride != null;

  if (!context.mounted) return;
  var applyToGroup = hasGroupOverride;
  final initialUrl = hasGroupOverride
      ? (groupOverride['url'] as String?) ?? controller.pingUrl
      : controller.pingUrl;
  final initialTimeout = hasGroupOverride
      ? ((groupOverride['timeout_ms'] as num?)?.toInt() ?? controller.pingTimeout)
      : controller.pingTimeout;

  final urlCtrl = TextEditingController(text: initialUrl);
  final timeoutCtrl = TextEditingController(text: '$initialTimeout');

  await showAppBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setSheetState) {
        final canApplyToGroup = currentGroup.isNotEmpty;
        return Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(getLocalText.s("Ping Settings"),
                  style: Theme.of(ctx).textTheme.titleMedium),
              const SizedBox(height: 8),
              if (canApplyToGroup) ...[
                SegmentedButton<bool>(
                  segments: [
                    ButtonSegment(
                        value: false, label: Text(getLocalText.s("All directions"))),
                    ButtonSegment(
                        value: true,
                        label: Text(currentGroup,
                            overflow: TextOverflow.ellipsis)),
                  ],
                  selected: {applyToGroup},
                  onSelectionChanged: (s) {
                    setSheetState(() => applyToGroup = s.first);
                  },
                ),
                const SizedBox(height: 12),
              ],
              if (presets.isNotEmpty) ...[
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: presets.map((p) {
                    final selected = urlCtrl.text == p.url;
                    return ChoiceChip(
                      label:
                          Text(p.name, style: const TextStyle(fontSize: 12)),
                      selected: selected,
                      onSelected: (_) =>
                          setSheetState(() => urlCtrl.text = p.url),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 12),
              ],
              TextField(
                controller: urlCtrl,
                decoration: InputDecoration(
                  labelText: getLocalText.s("Test URL"),
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: timeoutCtrl,
                decoration: InputDecoration(
                  labelText: getLocalText.s("Timeout (ms)"),
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
                keyboardType: TextInputType.number,
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  if (applyToGroup && hasGroupOverride)
                    Expanded(
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.restart_alt, size: 18),
                        label: Text(getLocalText.s("Reset to global")),
                        onPressed: () async {
                          await SettingsStorage.clearGroupPing(currentGroup);
                          await controller.reloadPingOptions();
                          if (ctx.mounted) Navigator.pop(ctx);
                        },
                      ),
                    ),
                  if (applyToGroup && hasGroupOverride)
                    const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton(
                      onPressed: () async {
                        final url = urlCtrl.text.trim();
                        final timeout = int.tryParse(timeoutCtrl.text) ?? 5000;
                        if (applyToGroup && currentGroup.isNotEmpty) {
                          await SettingsStorage.setGroupPing(
                            currentGroup,
                            url: url,
                            timeoutMs: timeout,
                          );
                        } else {
                          await SettingsStorage.setGlobalPingUrl(url);
                          await SettingsStorage.setGlobalPingTimeout(timeout);
                        }
                        await controller.reloadPingOptions();
                        if (ctx.mounted) Navigator.pop(ctx);
                      },
                      child: Text(getLocalText.s("Save")),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    ),
  );
  urlCtrl.dispose();
  timeoutCtrl.dispose();
}
