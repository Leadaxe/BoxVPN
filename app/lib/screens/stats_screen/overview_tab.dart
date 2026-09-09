import 'package:flutter/material.dart';

import '../../services/format_utils.dart';
import 'memory_detail_sheet.dart';
import 'overview_models.dart';
import '../../services/l10n/locale_controller.dart';
import '../../widgets/safe_bottom.dart';

/// Overview tab of StatsScreen; receives data via props on each parent refresh.
/// `_expanded` is local state of this widget.
///
/// §122 — источник = `CcConnection` (libbox CommandClient). Группировка по
/// `rule` (chains нет). Карточка «Top apps» убрана: ядро по CommandClient не
/// отдаёт processPath, per-app разбивки нет.
class OverviewTab extends StatefulWidget {
  const OverviewTab({
    super.key,
    required this.loading,
    required this.groups,
    required this.totalUp,
    required this.totalDown,
    required this.totalConns,
    required this.memory,
    required this.goroutines,
    required this.connectionsIn,
    required this.connectionsOut,
    required this.byRule,
    required this.detourChain,
  });

  final bool loading;
  final Map<String, OutboundGroup> groups;
  final int totalUp;
  final int totalDown;
  final int totalConns;
  final int memory;
  final int goroutines;
  final int connectionsIn;
  final int connectionsOut;
  final Map<String, int> byRule;
  final List<String> Function(String tag) detourChain;

  @override
  State<OverviewTab> createState() => _OverviewTabState();
}

class _OverviewTabState extends State<OverviewTab> {
  final _expanded = <String>{};

  List<String> _detourChain(String tag) => widget.detourChain(tag);

  @override
  Widget build(BuildContext context) {
    // §219 — loading-guard ДО сортировки (не сортируем впустую при спиннере);
    // Theme.of(context) один раз (было 5 обходов дерева за build).
    if (widget.loading) {
      return const Center(child: CircularProgressIndicator());
    }
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final sorted = widget.groups.values.toList()
      ..sort((a, b) => (b.upload + b.download).compareTo(a.upload + a.download));
    return ListView(
      padding: const EdgeInsets.all(12).withSafeBottom(context),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _totalChip(context, 'Upload', formatBytes(widget.totalUp, spaced: true), Icons.arrow_upward, cs.primary),
                _totalChip(context, 'Download', formatBytes(widget.totalDown, spaced: true), Icons.arrow_downward, cs.tertiary),
                // Тап → вкладка Conns (индекс 1 в DefaultTabController родителя).
                _totalChip(
                  context, 'Connections', '${widget.totalConns}', Icons.link, cs.secondary,
                  onTap: () => DefaultTabController.of(context).animateTo(1),
                ),
                // Подпись — LxBox, а не sing-box: это RSS всего процесса
                // приложения (ядро в том же процессе), не только ядра. Тап →
                // попап с разбивкой памяти.
                _totalChip(
                  context, 'LxBox', formatBytes(widget.memory, spaced: true), Icons.memory, cs.secondary,
                  onTap: () => showMemoryDetailSheet(
                    context,
                    rss: widget.memory,
                    goroutines: widget.goroutines,
                    connectionsIn: widget.connectionsIn,
                    connectionsOut: widget.connectionsOut,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Text(getLocalText.s("Traffic by Rule"), style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        if (sorted.isEmpty)
          Center(child: Text(getLocalText.s("No active connections")))
        else
          ...sorted.map(_buildOutboundCard),
        const SizedBox(height: 8),
        _buildByRuleCard(context),
      ],
    );
  }

  Widget _totalChip(
    BuildContext context,
    String label,
    String value,
    IconData icon,
    Color color, {
    VoidCallback? onTap,
  }) {
    final chip = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: color, size: 24),
        const SizedBox(height: 4),
        Text(
          value,
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: color),
        ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label, style: const TextStyle(fontSize: 11)),
            // Affordance: интерактивные чипы помечаем стрелкой.
            if (onTap != null) ...[
              const SizedBox(width: 2),
              Icon(Icons.chevron_right, size: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant),
            ],
          ],
        ),
      ],
    );
    if (onTap == null) return chip;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: chip,
      ),
    );
  }

  Widget _buildOutboundCard(OutboundGroup group) {
    final isExpanded = _expanded.contains(group.name);
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    // §219 — chain один раз (было 2 вызова _detourChain на итерацию цикла,
    // каждый обходит дерево конфига byTag).
    final chain = _detourChain(group.name);

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          ListTile(
            onTap: () => setState(() {
              if (isExpanded) {
                _expanded.remove(group.name);
              } else {
                _expanded.add(group.name);
              }
            }),
            title: Text(group.name, style: const TextStyle(fontWeight: FontWeight.w500)),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var i = 0; i < chain.length; i++)
                  Padding(
                    padding: EdgeInsets.only(left: 8.0 + i * 12.0, top: 2),
                    child: Text(
                      getLocalText.s("↳ via %s", chain[i]),
                      style: TextStyle(
                        fontSize: 11,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    getLocalText.plural("%d connections", group.connections.length),
                    style: const TextStyle(fontSize: 11),
                  ),
                ),
              ],
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text('↑ ${formatBytes(group.upload, spaced: true)}', style: const TextStyle(fontSize: 12)),
                    Text('↓ ${formatBytes(group.download, spaced: true)}', style: const TextStyle(fontSize: 12)),
                  ],
                ),
                const SizedBox(width: 4),
                Icon(
                  isExpanded ? Icons.expand_less : Icons.expand_more,
                  color: cs.onSurfaceVariant,
                ),
              ],
            ),
          ),
          if (isExpanded) ...[
            const Divider(height: 1),
            ...group.connections.map((c) => _buildConnectionTile(c, cs)),
          ],
        ],
      ),
    );
  }

  Widget _buildConnectionTile(Connection c, ColorScheme cs) {
    final hostPort = c.destPort.isNotEmpty ? '${c.host}:${c.destPort}' : c.host;
    final duration = _formatDuration(c.start);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                c.network == 'udp' ? Icons.swap_horiz : Icons.arrow_forward,
                size: 14,
                color: cs.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  hostPort,
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(
                '↑${formatBytes(c.upload, spaced: true)} ↓${formatBytes(c.download, spaced: true)}',
                style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(left: 20, top: 2),
            child: Text(
              '${c.network.toUpperCase()} · ${c.rule.isNotEmpty ? c.rule : 'final'} · $duration',
              style: TextStyle(fontSize: 10, color: cs.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildByRuleCard(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final entries = widget.byRule.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final total = entries.fold<int>(0, (s, e) => s + e.value);
    return Card(
      child: ExpansionTile(
        initiallyExpanded: true,
        title: Text(getLocalText.s("By routing rule"), style: theme.textTheme.titleSmall),
        subtitle: Text(getLocalText.s("%d conns", total),
            style: const TextStyle(fontSize: 11)),
        tilePadding: const EdgeInsets.symmetric(horizontal: 16),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        children: entries.isEmpty
            ? [
                Text(getLocalText.s("No rule data"),
                    style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant))
              ]
            : [
                for (final e in entries)
                  _distributionRow(cs, e.key, e.value, total),
              ],
      ),
    );
  }

  Widget _distributionRow(ColorScheme cs, String label, int count, int total) {
    final pct = total == 0 ? 0.0 : count / total;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(
            child: Text(label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13)),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 70,
            child: LinearProgressIndicator(
              value: pct,
              minHeight: 6,
              backgroundColor: cs.surfaceContainerHighest,
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 60,
            child: Text(
              '$count (${(pct * 100).toStringAsFixed(0)}%)',
              textAlign: TextAlign.right,
              style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }

  // §122 — `start` теперь epoch ms (`CcConnection.createdAt`), не ISO-строка.
  // delta от now → compact duration через format_utils.
  String _formatDuration(int startEpochMs) {
    if (startEpochMs <= 0) return '';
    final diff = DateTime.now().difference(
        DateTime.fromMillisecondsSinceEpoch(startEpochMs));
    if (diff.isNegative) return '';
    return formatDuration(diff);
  }
}
