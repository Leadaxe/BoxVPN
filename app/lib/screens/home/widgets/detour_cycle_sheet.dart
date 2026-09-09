import 'package:flutter/material.dart';

import '../../../models/validation.dart';
import '../../../services/builder/validator.dart' show kMaxDetourCulprits;
import '../../../services/l10n/locale_controller.dart';
import '../../../widgets/app_bottom_sheet.dart';

/// §254/§255 — bottom sheet «Routing loop — VPN not started».
///
/// Показывается при попытке старта, когда пересборка конфига упала на fatal
/// [DetourCycle]: список нод-виновников (минимальный набор — алгоритм окраски
/// в validator.dart, НЕ все члены кольца) + раскрытие полного цикла. Конфиг
/// не правится и не собирается — устранение за пользователем (spec 254).
/// §255 — тап по виновнику ведёт к владельцу в списке серверов
/// ([onCulpritTap]). Паттерн — grabber/header/divider/ListView.
Future<void> showDetourCycleSheet(
  BuildContext context,
  List<DetourCycle> issues, {
  required void Function(String culpritTag) onCulpritTap,
}) {
  return showAppBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => _DetourCycleSheet(issues: issues, onCulpritTap: onCulpritTap),
  );
}

class _DetourCycleSheet extends StatelessWidget {
  const _DetourCycleSheet({required this.issues, required this.onCulpritTap});

  final List<DetourCycle> issues;
  final void Function(String culpritTag) onCulpritTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final culpritCount = issues.fold<int>(0, (n, i) => n + i.culprits.length);
    // §254 — детектор обрывает окраску на kMaxDetourCulprits: если набралось
    // ровно столько, могут быть ещё циклы за кадром — честно предупреждаем.
    final maybeMore = culpritCount >= kMaxDetourCulprits;
    return DraggableScrollableSheet(
      initialChildSize: 0.5,
      minChildSize: 0.3,
      maxChildSize: 0.95,
      expand: false,
      builder: (ctx, scrollController) => Column(
        children: [
          // Grabber
          Container(
            width: 36,
            height: 4,
            margin: const EdgeInsets.symmetric(vertical: 10),
            decoration: BoxDecoration(
              color: cs.onSurfaceVariant.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          // Header
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Row(
              children: [
                Icon(Icons.link_off, color: cs.error, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    getLocalText.s("Routing loop — VPN not started"),
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView(
              controller: scrollController,
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              children: [
                // Короткая ошибка + требование (решение владельца: списком,
                // без авто-действий). Tap → к владельцу.
                Text(
                  _leadText(context, culpritCount),
                  style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
                ),
                const SizedBox(height: 12),
                for (final issue in issues) ...[
                  if (issue.culprits.isEmpty)
                    // Кольцо из одних групп (только ручная правка JSON) —
                    // culprit-нод нет, показываем message как есть.
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(issue.message(),
                          style: const TextStyle(fontSize: 13)),
                    )
                  else
                    for (final c in issue.culprits)
                      _CulpritTile(
                        tag: c.tag,
                        detour: c.detour,
                        onTap: () => onCulpritTap(c.tag),
                      ),
                  // Полный цикл — при раскрытии (решение владельца).
                  ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    childrenPadding: const EdgeInsets.only(bottom: 12),
                    shape: const Border(),
                    title: Text(getLocalText.s("Show loop"),
                        style: TextStyle(
                            fontSize: 13, color: cs.onSurfaceVariant)),
                    children: [
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          '${issue.cycle.join(' → ')} → ${issue.cycle.first}',
                          style: const TextStyle(
                              fontSize: 12, fontFamily: 'monospace'),
                        ),
                      ),
                    ],
                  ),
                ],
                if (maybeMore) ...[
                  const SizedBox(height: 4),
                  Text(
                    getLocalText.s("More loops may remain — fix these and try again."),
                    style: TextStyle(
                        fontSize: 12,
                        fontStyle: FontStyle.italic,
                        color: cs.onSurfaceVariant),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _leadText(BuildContext context, int culpritCount) {
    if (culpritCount == 0) {
      // Кольцо только из групп (selector/urltest ссылаются друг на друга) —
      // виновных нод нет, править состав групп.
      return getLocalText.s("A routing loop was found between groups. Review the loop below and break it, then start again.");
    }
    if (culpritCount == 1) return getLocalText.s("One node routes traffic back into its own chain. Tap it to open its source, change or remove its detour, then start again.");
    return getLocalText.plural("%d nodes route traffic back into their own chain. Tap a node to open its source, change or remove its detour, then start again.", culpritCount);
  }
}

class _CulpritTile extends StatelessWidget {
  const _CulpritTile({
    required this.tag,
    required this.detour,
    required this.onTap,
  });

  final String tag;
  final String detour;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              border: Border.all(color: cs.error.withValues(alpha: 0.5)),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(tag,
                          style: const TextStyle(
                              fontSize: 14, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 2),
                      Text(getLocalText.s("detour → %s", detour),
                          style: TextStyle(
                              fontSize: 12,
                              fontFamily: 'monospace',
                              color: cs.error)),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right,
                    size: 18, color: cs.onSurfaceVariant),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
