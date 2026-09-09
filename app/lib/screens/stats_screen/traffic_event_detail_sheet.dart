import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/app_info_cache.dart';
import '../../services/format_utils.dart';
import '../../services/traffic_profiler.dart';
import '../../services/process_name.dart';
import 'routing_section.dart';
import '../../services/l10n/locale_controller.dart';
import '../../widgets/app_bottom_sheet.dart';

/// §160 — детальный bottom-sheet по одному [TrafficEvent] (Live-лента
/// per-app trace, в перспективе — и Stats→Live).
///
/// Аналог §152 `connection_detail_sheet.dart`, но для `TrafficEvent`
/// (исторический снимок события, не активный conn): сгруппированные
/// `label : value`, только непустые поля. Строки domain/IP/process —
/// кликабельны и зовут [onSearchKey] (значение уходит в общий поиск
/// родителя, sheet закрывается). Остальные строки — copy по тапу.
/// Footer — Copy JSON. Кнопки «Close connection» нет (событие историческое).
Future<void> showTrafficEventDetailSheet(
  BuildContext context,
  TrafficEvent event, {
  required void Function(String key) onSearchKey,
}) {
  return showAppBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) =>
        _TrafficEventDetailSheet(event: event, onSearchKey: onSearchKey),
  );
}

class _TrafficEventDetailSheet extends StatelessWidget {
  const _TrafficEventDetailSheet({
    required this.event,
    required this.onSearchKey,
  });

  final TrafficEvent event;
  final void Function(String key) onSearchKey;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final e = event;

    final domain = (e.domain ?? '').trim();
    final ip = (e.ip ?? '').trim();
    final destination = domain.isNotEmpty ? domain : ip;
    final title =
        e.port != null ? '$destination:${e.port}' : destination;

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
                _appIcon(context, packageNameFromProcess(e.process ?? '')),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title.isNotEmpty ? title : getLocalText.s("(event)"),
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w600),
                    softWrap: true,
                  ),
                ),
                _kindBadge(context, e),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView(
              controller: scrollController,
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              children: _sections(context),
            ),
          ),
          _footer(context),
        ],
      ),
    );
  }

  List<Widget> _sections(BuildContext context) {
    final e = event;
    final out = <Widget>[];

    // Destination — host/IP/port кликабельны → поиск.
    out.addAll(_group(context, 'Destination', [
      _searchRow(context, 'Host', e.domain ?? ''),
      _searchRow(context, 'Dest IP', e.ip ?? ''),
      _copyRow(context, 'Dest port', e.port?.toString() ?? ''),
    ]));

    // DNS
    // rc.10 — DNS-сервер (какой сервер резолвил) + тип (udp/tls/https/…).
    final dnsServer = e.extra?['dns_server']?.toString() ?? '';
    final dnsServerType = e.extra?['dns_server_type']?.toString() ?? '';
    final dnsServerLabel = dnsServer.isEmpty
        ? ''
        : (dnsServerType.isEmpty ? dnsServer : '$dnsServer ($dnsServerType)');
    // §315 — трасса DNS-группы (kernel SPEC 035). Строки пустые на не-групповых
    // путях → `_copyRow` их не рисует. `Group mode` собирает флаги: fanned =
    // в запросе был веер (цель сбоила и группа спаслась / выборы fastest),
    // survival = чистых членов не осталось (красный флаг здоровья группы).
    final groupMode = [
      if (e.extra?['dns_fanned'] == 'true') 'fanned',
      if (e.extra?['dns_survival'] == 'true') 'survival',
    ].join(' · ');
    out.addAll(_group(context, 'DNS', [
      _copyRow(context, 'Record', e.dnsRecordType ?? ''),
      _copyRow(context, 'CNAME', e.cnameChain.join(' → ')),
      // rc.10 — какой DNS-сервер обработал запрос (на всех путях вкл. провалы).
      _copyRow(context, 'DNS server', dnsServerLabel),
      // §315 — через какую группу шёл запрос (при вложенности: inner → outer).
      _copyRow(context, 'Group', e.extra?['dns_group_path']?.toString() ?? ''),
      // §315 — хронология проб: кто опрошен, исход, RTT.
      _copyRow(context, 'Attempts', e.extra?['dns_attempts']?.toString() ?? ''),
      _copyRow(context, 'Group mode', groupMode),
      // источник ответа: exchanged (сетевой запрос) / cached (из кэша) / …
      _copyRow(context, 'Source', e.extra?['source']?.toString() ?? ''),
    ]));

    // Network
    out.addAll(_group(context, 'Network', [
      _copyRow(context, 'Network', e.network ?? ''),
      _copyRow(context, 'Kind', e.kind.name),
    ]));

    // §044 — App: иконка + имя приложения + package, плюс атрибуция.
    // (бывш. Process — теперь с человекочитаемым именем и иконкой).
    out.addAll(_group(context, 'App', [
      _appRow(context, e.process ?? ''),
      _confidenceRow(context, e),
      _copyRow(context, 'Matched via', e.matchedVia ?? ''),
      _copyRow(context, 'Shown because', e.shownBecause ?? ''),
    ]));

    // Routing (§181/§204) — единый набор строк (routingRows), общий с Conns.
    // Outbound = outboundChain.first (для event нет отдельного поля); type из
    // §204-протаскивания. Пустые строки скрывает _copyRow.
    out.addAll(_group(
      context,
      'Routing',
      routingRows(
        route: e.routingLine,
        rule: e.rule ?? '',
        chain: e.outboundChain,
        detour: e.detourChain,
        outbound: e.outboundChain.isNotEmpty ? e.outboundChain.first : '',
        outboundType: e.outboundType ?? '',
      ).map((r) => _copyRow(context, r.label, r.value)).toList(),
    ));

    // Traffic — показываем только если есть байты.
    if (e.upBytes != null || e.downBytes != null) {
      out.addAll(_group(context, 'Traffic', [
        _copyRow(context, 'Upload',
            '${formatBytes(e.upBytes ?? 0)} (${e.upBytes ?? 0} B)'),
        _copyRow(context, 'Download',
            '${formatBytes(e.downBytes ?? 0)} (${e.downBytes ?? 0} B)'),
      ]));
    }

    // Timing
    final local = e.ts.toLocal();
    final started = formatDateTime(local);
    out.addAll(_group(context, 'Timing', [
      _copyRow(context, 'Started', started),
      _copyRow(
        context,
        'Duration',
        e.duration != null
            ? formatDuration(e.duration!, daysRollup: true)
            : '',
      ),
    ]));

    // Issues — ⚠ error-цвет.
    if (e.issues.isNotEmpty) {
      out.addAll(_group(context, 'Issues', [
        for (final a in e.issues) _issueRow(context, a),
      ]));
    }

    // Raw log line
    out.addAll(_group(context, 'Raw', [
      _copyRow(context, 'Log', e.rawLogLine ?? ''),
    ]));

    return out;
  }

  /// §160/§177 — kind-badge (цвет как в live_view: DNS tertiary / DNS-fail
  /// error / TCP primary / TCP· outline / UDP secondary). §177 — DNS = один
  /// бейдж, успех/сбой различаются ЦВЕТОМ (как TCP open/close).
  Widget _kindBadge(BuildContext context, TrafficEvent e) {
    final cs = Theme.of(context).colorScheme;
    final (Color color, String label) = switch (e.kind) {
      TrafficEventKind.dnsResolve => (cs.tertiary, 'DNS'),
      TrafficEventKind.dnsFail => (cs.error, 'DNS'),
      TrafficEventKind.tcpOpen => (cs.primary, 'TCP'),
      TrafficEventKind.tcpClose => (cs.outline, 'TCP·'),
      TrafficEventKind.udpOpen => (cs.secondary, 'UDP'),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(label,
          style: TextStyle(
              fontSize: 11,
              fontFamily: 'monospace',
              fontWeight: FontWeight.w600,
              color: color)),
    );
  }

  /// §154 — launcher-иконка приложения по package, 20×20.
  Widget _appIcon(BuildContext context, String pkg) {
    const double size = 20;
    final cs = Theme.of(context).colorScheme;
    final placeholder = Icon(Icons.apps, size: size, color: cs.onSurfaceVariant);
    if (pkg.isEmpty) return placeholder;
    AppInfoCache.ensure(pkg);
    return AnimatedBuilder(
      animation: AppInfoCache.revision,
      builder: (context, _) {
        final icon = AppInfoCache.of(pkg)?.icon;
        if (icon == null) return placeholder;
        return ClipRRect(
          borderRadius: BorderRadius.circular(5),
          child: Image.memory(icon,
              width: size, height: size, gaplessPlayback: true),
        );
      },
    );
  }

  /// §044 — строка App: иконка приложения + человекочитаемое имя (из
  /// AppInfoCache) + package мелким моноширинным. Тап → поиск по package.
  /// `null` если package пуст.
  Widget? _appRow(BuildContext context, String pkg) {
    if (pkg.isEmpty) return null;
    final cs = Theme.of(context).colorScheme;
    AppInfoCache.ensure(pkg);
    return InkWell(
      onTap: () {
        Navigator.of(context).pop();
        onSearchKey(pkg);
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: AnimatedBuilder(
          animation: AppInfoCache.revision,
          builder: (context, _) {
            final info = AppInfoCache.of(pkg);
            final name = (info?.appName.isNotEmpty ?? false)
                ? info!.appName
                : pkg.split('.').last;
            return Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                _appIcon(context, pkg),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(name,
                          style: const TextStyle(
                              fontSize: 14, fontWeight: FontWeight.w600)),
                      Text(pkg,
                          style: TextStyle(
                              fontSize: 11,
                              fontFamily: 'monospace',
                              color: cs.onSurfaceVariant)),
                    ],
                  ),
                ),
                Icon(Icons.search, size: 16, color: cs.onSurfaceVariant),
              ],
            );
          },
        ),
      ),
    );
  }

  /// Заголовок группы + непустые строки, либо `[]` если все пусты.
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

  /// `label : value`, тап копирует value. `null` если пусто.
  Widget? _copyRow(BuildContext context, String label, String value) {
    if (value.isEmpty) return null;
    return _baseRow(context, label, value, onTap: () => _copy(context, value));
  }

  /// `label : value`, тап кладёт value в общий поиск + закрывает sheet.
  /// `null` если пусто.
  Widget? _searchRow(BuildContext context, String label, String value) {
    final v = value.trim();
    if (v.isEmpty) return null;
    final cs = Theme.of(context).colorScheme;
    return _baseRow(
      context,
      label,
      v,
      valueColor: cs.primary,
      trailing: Icon(Icons.search, size: 14, color: cs.primary),
      onTap: () {
        Navigator.of(context).pop();
        onSearchKey(v);
      },
    );
  }

  Widget _confidenceRow(BuildContext context, TrafficEvent e) {
    final cs = Theme.of(context).colorScheme;
    final color = switch (e.confidence) {
      ConfidenceLevel.verified => cs.onSurface,
      ConfidenceLevel.secondary => cs.tertiary,
      ConfidenceLevel.inferred => cs.secondary,
      ConfidenceLevel.unattributed => cs.error,
    };
    return _baseRow(context, 'Confidence', e.confidence.name,
        valueColor: color, onTap: () => _copy(context, e.confidence.name))!;
  }

  Widget _issueRow(BuildContext context, ConnectionIssue a) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber, size: 14, color: cs.error),
          const SizedBox(width: 8),
          Expanded(
            child: Text(a.description,
                style: TextStyle(fontSize: 13, color: cs.error)),
          ),
        ],
      ),
    );
  }

  /// Базовая строка `label : value` с опц. цветом/иконкой/тапом.
  /// Non-null всегда (callers с пустым value отсекают раньше).
  Widget? _baseRow(
    BuildContext context,
    String label,
    String value, {
    VoidCallback? onTap,
    Color? valueColor,
    Widget? trailing,
  }) {
    if (value.isEmpty) return null;
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
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
              child: Text(
                value,
                style: TextStyle(
                  fontSize: 13,
                  fontFamily: 'monospace',
                  height: 1.3,
                  color: valueColor,
                ),
                softWrap: true,
              ),
            ),
            if (trailing != null) ...[
              const SizedBox(width: 4),
              trailing,
            ],
          ],
        ),
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
          onPressed: () => _copy(
            context,
            const JsonEncoder.withIndent('  ').convert(event.toJson()),
            message: 'JSON copied',
          ),
        ),
      ),
    );
  }

  void _copy(BuildContext context, String value, {String message = 'Copied'}) {
    Clipboard.setData(ClipboardData(text: value));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 1)),
    );
  }
}
