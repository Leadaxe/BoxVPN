import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/format_utils.dart';
import '../../services/traffic_profiler.dart';
import '../per_app_trace_tab/widgets/aggregate_axis.dart';
import '../per_app_trace_tab/widgets/aggregated_view.dart';
import '../per_app_trace_tab/widgets/ip_chip.dart';
import 'traffic_event_detail_sheet.dart';
import '../../services/l10n/locale_controller.dart';
import '../../widgets/app_bottom_sheet.dart';

/// §160 — детальный bottom-sheet по одному агрегату (домен или IP).
///
/// Развязан от `Session`: принимает напрямую [events] (таймлайн —
/// session.events ИЛИ globalRollingBuffer) + посчитанные агрегаты
/// [byDomain]/[byIp]. Так sheet работает и в per-app trace, и в Stats→Live.
///
/// Свод (из [DomainStats]/[IpStats]) + список **всех соединений** по этому
/// ключу (drill-down): тап по conn-строке открывает [showTrafficEventDetailSheet]
/// поверх. Поля domain/IP кликабельны → [onSearchKey] (значение в общий
/// поиск, sheet закрывается). Footer — Copy JSON свода.
Future<void> showAggregateDetailSheet(
  BuildContext context, {
  required List<TrafficEvent> events,
  required Map<String, DomainStats> byDomain,
  required Map<String, IpStats> byIp,
  required AggAxis axis,
  required String key,
  required void Function(String key) onSearchKey,
}) {
  return showAppBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => _AggregateDetailSheet(
      events: events,
      byDomain: byDomain,
      byIp: byIp,
      axis: axis,
      aggKey: key,
      onSearchKey: onSearchKey,
    ),
  );
}

class _AggregateDetailSheet extends StatelessWidget {
  const _AggregateDetailSheet({
    required this.events,
    required this.byDomain,
    required this.byIp,
    required this.axis,
    required this.aggKey,
    required this.onSearchKey,
  });

  final List<TrafficEvent> events;
  final Map<String, DomainStats> byDomain;
  final Map<String, IpStats> byIp;
  final AggAxis axis;
  final String aggKey;
  final void Function(String key) onSearchKey;

  /// Все conn-события (tcp/udp open/close) по этому ключу, newest-first.
  List<TrafficEvent> _connEvents() {
    bool matches(TrafficEvent e) =>
        axis == AggAxis.domain ? e.domain == aggKey : e.ip == aggKey;
    return events
        .where((e) =>
            matches(e) &&
            (e.kind == TrafficEventKind.tcpOpen ||
                e.kind == TrafficEventKind.tcpClose ||
                e.kind == TrafficEventKind.udpOpen))
        .toList()
        .reversed
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final conns = _connEvents();

    return DraggableScrollableSheet(
      initialChildSize: 0.6,
      minChildSize: 0.4,
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
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: cs.secondary.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                      axis == AggAxis.domain
                          ? getLocalText.s("Domain")
                          : getLocalText.s("IP"),
                      style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: cs.secondary)),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    aggKey,
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w600),
                    softWrap: true,
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
                ..._summary(context),
                _connHeader(context, conns.length),
                if (conns.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(getLocalText.s("No connections."),
                        style: TextStyle(
                            fontSize: 12, color: cs.onSurfaceVariant)),
                  )
                else
                  for (final e in conns) _connTile(context, e),
              ],
            ),
          ),
          _footer(context),
        ],
      ),
    );
  }

  List<Widget> _summary(BuildContext context) {
    final active = AggregatedView.activeByKey(events, axis)[aggKey] ?? 0;
    if (axis == AggAxis.domain) {
      final d = byDomain[aggKey];
      if (d == null) return const [];
      return _group(context, 'Summary', [
        _row(context, 'Connections', '$active/${d.connections}'),
        _row(context, 'Traffic',
            '↑${formatBytes(d.upBytes)} ↓${formatBytes(d.downBytes)}'),
        if (d.cnameTargets.isNotEmpty)
          _row(context, 'CNAME', d.cnameTargets.join(' → ')),
        if (d.ips.isNotEmpty) _ipsRow(context, 'IPs', d.ips),
        if (d.outbounds.isNotEmpty)
          _row(context, 'Outbound', d.outbounds.join(' / ')),
        if (d.firstSeen != null)
          _row(context, 'First', formatTime(d.firstSeen!)),
        if (d.lastSeen != null) _row(context, 'Last', formatTime(d.lastSeen!)),
      ]);
    } else {
      final ip = byIp[aggKey];
      if (ip == null) return const [];
      return _group(context, 'Summary', [
        _row(context, 'Connections', '$active/${ip.connections}'),
        _row(context, 'Traffic',
            '↑${formatBytes(ip.upBytes)} ↓${formatBytes(ip.downBytes)}'),
        if (ip.ports.isNotEmpty)
          _row(context, 'Ports', (ip.ports.toList()..sort()).join(', ')),
        if (ip.outbounds.isNotEmpty)
          _row(context, 'Outbound', ip.outbounds.join(' / ')),
        if (ip.firstSeen != null)
          _row(context, 'First', formatTime(ip.firstSeen!)),
        if (ip.lastSeen != null)
          _row(context, 'Last', formatTime(ip.lastSeen!)),
      ]);
    }
  }

  Widget _connHeader(BuildContext context, int count) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 14, bottom: 2),
      child: Text(
        getLocalText.s("CONNECTIONS (%d)", count),
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.5,
          color: cs.primary,
        ),
      ),
    );
  }

  /// Компактная conn-строка → drill-down в детали события.
  Widget _connTile(BuildContext context, TrafficEvent e) {
    final cs = Theme.of(context).colorScheme;
    final closed = e.kind == TrafficEventKind.tcpClose;
    final hostPort = (e.domain != null && e.domain!.isNotEmpty)
        ? '${e.domain}:${e.port ?? "?"}'
        : '[${e.ip ?? "?"}]:${e.port ?? "?"}';
    return InkWell(
      onTap: () => showTrafficEventDetailSheet(context, e,
          onSearchKey: onSearchKey),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Text(formatTime(e.ts),
                style: TextStyle(
                    fontSize: 11,
                    fontFamily: 'monospace',
                    color: cs.onSurfaceVariant)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                hostPort,
                style: TextStyle(
                    fontSize: 12,
                    color: closed ? cs.onSurfaceVariant : null),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Text(
              '↑${formatBytes(e.upBytes ?? 0)} ↓${formatBytes(e.downBytes ?? 0)}',
              style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
            ),
            if (e.issues.isNotEmpty) ...[
              const SizedBox(width: 4),
              Icon(Icons.warning_amber, size: 13, color: cs.error),
            ],
            Icon(Icons.chevron_right, size: 16, color: cs.onSurfaceVariant),
          ],
        ),
      ),
    );
  }

  List<Widget> _group(BuildContext context, String title, List<Widget?> rows) {
    final visible = rows.whereType<Widget>().toList();
    if (visible.isEmpty) return const [];
    final cs = Theme.of(context).colorScheme;
    return [
      Padding(
        padding: const EdgeInsets.only(top: 12, bottom: 4),
        child: Text(
          title.toUpperCase(),
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.5,
            color: cs.primary,
          ),
        ),
      ),
      ...visible,
    ];
  }

  Widget? _row(BuildContext context, String label, String value) {
    if (value.isEmpty) return null;
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      onTap: () => _copy(context, value),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 96,
              child: Text(label,
                  style:
                      TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(value,
                  style: const TextStyle(
                      fontSize: 13, fontFamily: 'monospace', height: 1.3),
                  softWrap: true),
            ),
          ],
        ),
      ),
    );
  }

  /// IP-вариант строки: chips, тап по IP → общий поиск + закрыть sheet.
  Widget _ipsRow(BuildContext context, String label, Iterable<String> ips) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 96,
            child: Text(label,
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: ipChipList(context, ips, (ip) {
              Navigator.of(context).pop();
              onSearchKey(ip);
            }),
          ),
        ],
      ),
    );
  }

  Widget _footer(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        border: Border(top: BorderSide(color: cs.outlineVariant)),
      ),
      padding: EdgeInsets.fromLTRB(
          12, 8, 12, 8 + MediaQuery.of(context).padding.bottom),
      child: SizedBox(
        width: double.infinity,
        child: OutlinedButton.icon(
          icon: const Icon(Icons.copy, size: 16),
          label: Text(getLocalText.s("Copy JSON")),
          onPressed: () => _copy(context, _summaryJson(), message: 'JSON copied'),
        ),
      ),
    );
  }

  String _summaryJson() {
    final Object? data = axis == AggAxis.domain
        ? byDomain[aggKey]?.toJson()
        : byIp[aggKey]?.toJson();
    return const JsonEncoder.withIndent('  ').convert(data ?? {});
  }

  void _copy(BuildContext context, String value, {String message = 'Copied'}) {
    Clipboard.setData(ClipboardData(text: value));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 1)),
    );
  }
}
