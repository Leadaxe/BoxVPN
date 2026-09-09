import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../models/node_spec.dart';
import '../../../models/node_warning.dart';
import '../../../models/ui_msg.dart';
import '../../../services/probe/probe_runner.dart';
import '../../../widgets/probe_badge.dart';
import 'node_warning_row.dart';
import '../node_inspect_screen.dart';
import '../../../services/l10n/locale_controller.dart';
import '../../../widgets/app_bottom_sheet.dart';

/// Nodes-tab list: actionable-warning banner + node rows with §283 toggle,
/// label/tag, protocol + server:port subtitle, inline warning and a
/// long-press copy menu.
class SubscriptionNodeList extends StatelessWidget {
  const SubscriptionNodeList({
    super.key,
    required this.nodes,
    required this.loading,
    required this.error,
    this.togglableNodes = const {},
    this.disabledNodes = const {},
    this.chainHops = const {},
    this.onToggleNode,
    this.probe = const {},
    this.probeThresholds = ProbeThresholds.defaults,
    this.tagPrefix = '',
  });

  /// §392 — префикс тегов контейнера, нужен экрану разбора: диагностика при
  /// включённом VPN адресует узел его display-тегом из боевого конфига.
  final String tagPrefix;

  final List<NodeSpec>? nodes;
  final bool loading;
  final UiMsg? error;

  /// §283 — top-level ноды подписки (identity-set): у них есть toggle.
  /// Chained-дети (развёрнутые строки) управляются родителем — без toggle.
  /// Пусто = не подписка (UserServer) — тогглов нет вовсе.
  final Set<NodeSpec> togglableNodes;

  /// §283 — выключенные ноды (identity-subset [togglableNodes]). Дубли по
  /// хешу приходят выключенными синхронно — состояние считает экран от
  /// `disabledHashes`, не по-строчно.
  final Set<NodeSpec> disabledNodes;

  /// §404 — строки-звенья цепочки (identity-set). Тег звена с D-085 — это
  /// собственный тег релея из конфига провайдера, без украшений, поэтому в
  /// списке звено ничем не отличалось бы от самостоятельного узла. Значок
  /// `⚙` вешаем ЗДЕСЬ, на отрисовке: он про то, как строка читается, а не
  /// про то, что уедет в конфиг ядра.
  final Set<NodeSpec> chainHops;

  final void Function(NodeSpec node)? onToggleNode;

  /// §339 — результаты Test servers (identity-map по инстансам top-level
  /// нод; chained-дети без бейджа). Пусто = теста не было.
  final Map<NodeSpec, ProbeResult> probe;
  final ProbeThresholds probeThresholds;

  /// §404 — подпись строки. Звено цепочки помечается `⚙` на отрисовке (в
  /// теге узла этого маркера больше нет, см. [chainHops]).
  String _rowTitle(NodeSpec node) {
    final base = node.label.isNotEmpty ? node.label : node.tag;
    return chainHops.contains(node) ? '⚙ $base' : base;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(error!.render(),
              style: TextStyle(color: theme.colorScheme.error)),
        ),
      );
    }

    final nodes = this.nodes;
    if (nodes == null && !loading) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(getLocalText.s("Update subscription to see nodes")),
        ),
      );
    }

    if (nodes == null || nodes.isEmpty) {
      if (loading) return const SizedBox.shrink();
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(getLocalText.s("No nodes found")),
        ),
      );
    }

    // Считаем только actionable (warning/error). Info (TLS-insecure) тут
    // не учитываем — это часто намеренный выбор провайдера, чтобы не пугать.
    final actionableCount = nodes
        .where((n) => n.warnings
            .any((w) => w.severity != WarningSeverity.info))
        .length;
    return Column(
      children: [
        if (actionableCount > 0)
          Container(
            width: double.infinity,
            color: Colors.orange.withValues(alpha: 0.15),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                const Icon(Icons.warning_amber, size: 16, color: Colors.orange),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    getLocalText.plural("%d nodes with warnings (XHTTP fallback etc.)", actionableCount),
                    style: const TextStyle(fontSize: 12, color: Colors.orange),
                  ),
                ),
              ],
            ),
          ),
        Expanded(
          child: ListView.separated(
      // Bottom safe-area: последняя нода не должна прятаться за системной
      // навигацией Android. Паттерн проекта — padding.bottom + 24.
      padding: EdgeInsets.fromLTRB(
          12, 0, 12, MediaQuery.of(context).padding.bottom + 24),
      itemCount: nodes.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final node = nodes[i];
        // §283 — per-node toggle (только top-level ноды подписки).
        final togglable =
            onToggleNode != null && togglableNodes.contains(node);
        final disabled = disabledNodes.contains(node);
        final probeResult = probe[node]; // §339
        return ListTile(
          contentPadding: EdgeInsets.zero,
          // §283 — Switch слева, как per-member toggle папок (§234). Иконки
          // протокола нет (решение пользователя): протокол виден в подстроке.
          // Строки без тоггла (chained-дети) получают placeholder той же
          // ширины — выравнивание не пляшет; UserServer — без leading вовсе.
          leading: togglable
              ? SizedBox(
                  width: 40,
                  child: Switch(
                    value: !disabled,
                    onChanged: (_) => onToggleNode!(node),
                  ),
                )
              : (togglableNodes.isEmpty ? null : const SizedBox(width: 40)),
          title: Row(
            children: [
              Flexible(
                child: Text(
                  _rowTitle(node),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    // Выключенная — глушим цветом (паттерн folder_detail §234).
                    color:
                        disabled ? theme.colorScheme.onSurfaceVariant : null,
                  ),
                ),
              ),
              // §302/§307 — значок «тело изменено import-rules» (REPLACE).
              // Ключ — ruleTrail: контроллер заполняет его при каждом
              // применении правил (refresh И регидрация из кэша), поэтому
              // значок переживает рестарты. Прежний ключ originLine никогда
              // не проставлялся — значок был мёртв. Сами замены — во вкладке
              // Replacements экрана разбора (тап по строке).
              if (node.ruleTrail.isNotEmpty) ...[
                const SizedBox(width: 6),
                Tooltip(
                  message: getLocalText.s("Modified by import rules"),
                  child: Icon(Icons.edit_note,
                      size: 16, color: theme.colorScheme.primary),
                ),
              ],
            ],
          ),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${node.protocol}  ${node.server}:${node.port}',
                style: TextStyle(fontSize: 11, color: theme.colorScheme.onSurfaceVariant),
              ),
              if (node.warnings.isNotEmpty) NodeWarningRow(node.warnings),
            ],
          ),
          // §339 — бейдж результата теста; тап по err — текст ошибки.
          trailing: probeResult == null
              ? null
              : ProbeBadge(
                  result: probeResult,
                  thresholds: probeThresholds,
                  onTap: () {
                    if (probeResult.message.isEmpty) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(probeResult.message)),
                    );
                  },
                ),
          dense: true,
          // §302 — короткий тап открывает разбор ноды (JSON + исходник):
          // самое частое действие, ради него не надо лезть в меню. Включение/
          // выключение узла живёт на Switch слева, так что тап по строке
          // свободен. Долгий тап — меню (копирование, diff замен).
          onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
            builder: (_) => NodeInspectScreen(node: node, tagPrefix: tagPrefix),
          )),
          onLongPress: () => _showNodeMenu(context, node),
        );
      },
          ),
        ),
      ],
    );
  }

  void _showNodeMenu(BuildContext context, NodeSpec node) {
    final info = node.rawUri.isNotEmpty
        ? node.rawUri
        : '${node.protocol}://${node.server}:${node.port}';
    showAppBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.copy),
              title: Text(getLocalText.s("Copy node info")),
              subtitle: Text(info, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11)),
              onTap: () {
                Clipboard.setData(ClipboardData(text: info));
                Navigator.pop(ctx);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(getLocalText.s("Node info copied"))),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.label_outline),
              title: Text(getLocalText.s("Copy tag")),
              subtitle: Text(node.tag, style: const TextStyle(fontSize: 11)),
              onTap: () {
                Clipboard.setData(ClipboardData(text: node.tag));
                Navigator.pop(ctx);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(getLocalText.s("Tag copied"))),
                );
              },
            ),
            // §302 — экран разбора ноды: JSON (результат парсинга) + Source
            // (исходный фрагмент подписки, для JSON-тел с переключателем
            // Compact/Extended). Заменил попап «View JSON» — в попапе не
            // помещался ни источник, ни переключение вида.
            ListTile(
              leading: const Icon(Icons.data_object),
              title: Text(getLocalText.s("Inspect node")),
              // §307 — у пропатченных нод там же третья вкладка Replacements.
              subtitle: Text(getLocalText.s("JSON, source and replacements"),
                  style: const TextStyle(fontSize: 11)),
              onTap: () {
                Navigator.pop(ctx);
                Navigator.of(context).push(MaterialPageRoute<void>(
                  builder: (_) => NodeInspectScreen(node: node, tagPrefix: tagPrefix),
                ));
              },
            ),
          ],
        ),
      ),
    );
  }
}
