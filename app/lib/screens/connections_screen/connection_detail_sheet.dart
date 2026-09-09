import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/format_utils.dart';
import '../../vpn/cc_channel.dart';
import '../stats_screen/routing_section.dart';
import '../../services/l10n/locale_controller.dart';
import '../../widgets/app_bottom_sheet.dart';

/// §152 — детальный bottom sheet по одному соединению.
///
/// Тайл в [ConnectionsView] обрезает host/rule ellipsis'ом — здесь показываем
/// полный снимок `conn` (статичный, на момент тапа): сгруппированные
/// `label : value`, только непустые поля, без ellipsis. Тап по строке копирует
/// значение; footer — Copy JSON + Close.
///
/// §122 — источник = `CcConnection` (libbox CommandClient). Поля: id/network/
/// domain/destination/rule/uplink/downlink/createdAt/closedAt + §174/§178
/// chains/detours + outbound/outboundType + processPath/packageName.
/// §204 — Routing-секция (Route/Rule/Chain/Detour/Outbound/type) единая с
/// профайлером через `routingRows`.
///
/// [onClose] переиспользует `_ConnectionsViewState._closeConnection`
/// (close через CommandClient + аккумулятор сам обновит снапшот).
Future<void> showConnectionDetailSheet(
  BuildContext context,
  CcConnection conn, {
  required bool closed,
  bool oneWay = false,
  required void Function(String id) onClose,
}) {
  return showAppBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => _ConnectionDetailSheet(
      conn: conn,
      closed: closed,
      oneWay: oneWay,
      onClose: onClose,
    ),
  );
}

class _ConnectionDetailSheet extends StatelessWidget {
  const _ConnectionDetailSheet({
    required this.conn,
    required this.closed,
    required this.oneWay,
    required this.onClose,
  });

  final CcConnection conn;
  final bool closed;
  final bool oneWay;
  final void Function(String id) onClose;

  // §219 — _destPort вынесен в format_utils (portOf).

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    final destination =
        conn.domain.isNotEmpty ? conn.domain : conn.destination;
    final port = portOf(conn.destination);
    final title = (conn.domain.isNotEmpty && port.isNotEmpty)
        ? '$destination:$port'
        : destination;

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
                Icon(Icons.link, size: 20, color: cs.onSurfaceVariant),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title.isNotEmpty ? title : getLocalText.s("(connection)"),
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w600),
                    softWrap: true,
                  ),
                ),
                if (oneWay)
                  Container(
                    margin: const EdgeInsets.only(right: 6),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: Color.alphaBlend(
                          Colors.pink.withValues(alpha: 0.22), cs.surface),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(getLocalText.s("One-way"),
                        style: const TextStyle(
                            fontSize: 11, fontWeight: FontWeight.w600)),
                  ),
                if (closed)
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: cs.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(getLocalText.s("closed"),
                        style: TextStyle(
                            fontSize: 11, color: cs.onSurfaceVariant)),
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
                if (oneWay) _oneWayBanner(context),
                ..._sections(context),
              ],
            ),
          ),
          _footer(context, conn.id),
        ],
      ),
    );
  }

  List<Widget> _sections(BuildContext context) {
    final out = <Widget>[];

    // Поля по контракту libbox CommandClient (`CcConnection`):
    // domain/destination/network/rule/uplink/downlink/createdAt/closedAt +
    // §122 ProcessInfo (process/package) + outbound/outboundType/protocol.

    // App (§122 — из getProcessInfo). Показываем только если есть данные.
    if (conn.processPath.isNotEmpty || conn.packageName.isNotEmpty) {
      out.addAll(_group(context, 'App', [
        if (conn.processPath.isNotEmpty)
          _row(context, 'Process', conn.processPath),
        if (conn.packageName.isNotEmpty)
          _row(context, 'Package', conn.packageName),
      ]));
    }

    // Destination
    out.addAll(_group(context, 'Destination', [
      _row(context, 'Host', conn.domain),
      _row(context, 'Destination', conn.destination),
      _row(context, 'Dest port', portOf(conn.destination)),
    ]));

    // Network
    out.addAll(_group(context, 'Network', [
      _row(context, 'Network', conn.network),
      if (conn.protocol.isNotEmpty) _row(context, 'Protocol', conn.protocol),
    ]));

    // Routing (§204) — единый набор строк (routingRows), общий с профайлером:
    // Route (§181) + Rule + Chain + Detour + Outbound + Outbound type. Пустые
    // строки скрывает _row.
    out.addAll(_group(
      context,
      'Routing',
      routingRows(
        route: conn.routingLineOf(),
        rule: conn.rule,
        chain: conn.chains,
        detour: conn.detours,
        outbound: conn.outbound,
        outboundType: conn.outboundType,
      ).map((r) => _row(context, r.label, r.value)).toList(),
    ));

    // Traffic
    out.addAll(_group(context, 'Traffic', [
      _row(context, 'Upload', '${formatBytes(conn.uplink)} (${conn.uplink} B)'),
      _row(context, 'Download',
          '${formatBytes(conn.downlink)} (${conn.downlink} B)'),
    ]));

    // Timing
    String timingStart = '';
    String timingDuration = '';
    if (conn.createdAt > 0) {
      final startTime =
          DateTime.fromMillisecondsSinceEpoch(conn.createdAt);
      final local = startTime.toLocal();
      timingStart = formatDateTime(local);
      final end = closed && conn.closedAt > 0
          ? DateTime.fromMillisecondsSinceEpoch(conn.closedAt)
          : DateTime.now();
      final diff = end.difference(startTime);
      if (!diff.isNegative) {
        timingDuration = formatDuration(diff, daysRollup: true);
      }
    }
    out.addAll(_group(context, 'Timing', [
      _row(context, 'Started', timingStart),
      _row(context, 'Duration', timingDuration),
    ]));

    // ID
    out.addAll(_group(context, 'ID', [
      _row(context, 'ID', conn.id),
    ]));

    return out;
  }

  /// Плашка-пояснение для однобокого (зависшего) соединения.
  Widget _oneWayBanner(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final detail = conn.uplink > 0 && conn.downlink == 0
        ? 'Data sent (↑), no reply (↓0) — the stream looks stuck.'
        : 'Data received (↓), nothing sent (↑0) — the stream looks stuck.';
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Color.alphaBlend(
            Colors.pink.withValues(alpha: 0.14), cs.surface),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber_rounded, size: 18, color: cs.error),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(getLocalText.s("One-way traffic"),
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(detail,
                    style: TextStyle(
                        fontSize: 12, color: cs.onSurfaceVariant)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Возвращает заголовок + непустые строки группы, либо `[]` если все
  /// строки группы пустые (группа целиком скрывается).
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

  /// `label : value` строка. `null` если value пустое (не рендерится).
  /// Тап копирует value в буфер.
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
              child: Text(
                label,
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                value,
                style: const TextStyle(
                    fontSize: 13,
                    fontFamily: 'monospace',
                    height: 1.3),
                softWrap: true,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _footer(BuildContext context, String id) {
    final cs = Theme.of(context).colorScheme;
    final canClose = !closed && id.isNotEmpty;
    return Container(
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        border: Border(top: BorderSide(color: cs.outlineVariant)),
      ),
      padding: EdgeInsets.fromLTRB(
          12, 8, 12, 8 + MediaQuery.of(context).padding.bottom),
      child: Row(
        children: [
          Expanded(
            child: OutlinedButton.icon(
              icon: const Icon(Icons.copy, size: 16),
              label: Text(getLocalText.s("Copy JSON")),
              onPressed: () => _copy(
                context,
                const JsonEncoder.withIndent('  ').convert(_toJson()),
                message: 'JSON copied',
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: FilledButton.tonalIcon(
              icon: const Icon(Icons.close, size: 16),
              label: Text(getLocalText.s("Close")),
              onPressed: canClose
                  ? () {
                      onClose(id);
                      Navigator.of(context).pop();
                    }
                  : null,
            ),
          ),
        ],
      ),
    );
  }

  Map<String, dynamic> _toJson() => {
        'id': conn.id,
        'network': conn.network,
        'domain': conn.domain,
        'destination': conn.destination,
        'rule': conn.rule,
        'uplink': conn.uplink,
        'downlink': conn.downlink,
        'createdAt': conn.createdAt,
        'closedAt': conn.closedAt,
      };

  void _copy(BuildContext context, String value, {String message = 'Copied'}) {
    Clipboard.setData(ClipboardData(text: value));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 1)),
    );
  }
}
