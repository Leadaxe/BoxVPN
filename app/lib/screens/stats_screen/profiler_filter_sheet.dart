import 'package:flutter/material.dart';

import '../../services/app_info_cache.dart';
import '../../services/traffic_profiler.dart';
import '../per_app_trace_tab/app_multi_picker.dart';
import 'profiler_filter.dart';
import '../../services/l10n/locale_controller.dart';
import '../../widgets/app_bottom_sheet.dart';

/// §044/new-profiler — фильтр-окно профайлера. Bottom-sheet, паттерн
/// `home/widgets/filter_panel.dart`: TabBar с amber-точкой на табе с активным
/// фильтром + контент таба.
///
/// Две вкладки (порядок по решению юзера):
/// 1. **Protocol** — чипы DNS / TCP / UDP (по семейству §177).
/// 2. **App** — галочки замеченных в трафике пакетов ([seenApps]) + «потеряшки»
///    (unattributed) + кнопка пикера (добавить app, которого ещё не было).
///
/// [showAppTab] — в App-вкладке (`per_app_trace`) target зафиксирован сессией,
/// App-таб скрыт. [seenApps] — пакеты, реально засветившиеся в текущих событиях.
Future<void> showProfilerFilterSheet(
  BuildContext context, {
  required ProfilerFilter filter,
  required bool showAppTab,
  required Set<String> seenApps,
  required bool hasUnattributed,
  Set<String> seenRules = const {},
  Set<String> seenOutbounds = const {},
}) {
  return showAppBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _ProfilerFilterSheet(
      filter: filter,
      showAppTab: showAppTab,
      seenApps: seenApps,
      hasUnattributed: hasUnattributed,
      seenRules: seenRules,
      seenOutbounds: seenOutbounds,
    ),
  );
}

class _ProfilerFilterSheet extends StatefulWidget {
  const _ProfilerFilterSheet({
    required this.filter,
    required this.showAppTab,
    required this.seenApps,
    required this.hasUnattributed,
    required this.seenRules,
    required this.seenOutbounds,
  });

  final ProfilerFilter filter;
  final bool showAppTab;
  final Set<String> seenApps;
  final bool hasUnattributed;
  final Set<String> seenRules;
  final Set<String> seenOutbounds;

  @override
  State<_ProfilerFilterSheet> createState() => _ProfilerFilterSheetState();
}

class _ProfilerFilterSheetState extends State<_ProfilerFilterSheet>
    with TickerProviderStateMixin {
  late final TabController _tab;
  // §230 — поле поиска (domain/ip/process, substring, не regex). Засеяно из
  // f.search (клик по домену в детали ставит его туда), редактируется/чистится
  // юзером прямо здесь. Живёт над вкладками — видно на любой оси.
  late final TextEditingController _searchCtrl;

  // Protocol-чипы: (label, представитель-семейство §177).
  static const _protocols = <(String, TrafficEventKind)>[
    ('DNS', TrafficEventKind.dnsResolve),
    ('TCP', TrafficEventKind.tcpOpen),
    ('UDP', TrafficEventKind.udpOpen),
  ];

  ProfilerFilter get f => widget.filter;

  // Пакеты, добавленные через пикер (которых не было в seenApps) — показываем
  // их в App-табе тоже, чтобы галочка была видна.
  final Set<String> _extraApps = {};

  // §230 — какие табы показываем. Protocol всегда; App по флагу; Rule/Outbound
  // — если есть что показать (значения в трафике ИЛИ уже выбранные в фильтре).
  bool get _showRuleTab => widget.seenRules.isNotEmpty || f.rules.isNotEmpty;
  bool get _showOutboundTab =>
      widget.seenOutbounds.isNotEmpty || f.outbounds.isNotEmpty;

  @override
  void initState() {
    super.initState();
    var len = 1; // Protocol
    if (widget.showAppTab) len++;
    if (_showRuleTab) len++;
    if (_showOutboundTab) len++;
    _tab = TabController(length: len, vsync: this);
    _searchCtrl = TextEditingController(text: f.search);
    // app'ы из фильтра, которых нет в seen, — изначально extra (например из
    // прошлого пикера).
    _extraApps.addAll(f.apps.where((p) => !widget.seenApps.contains(p)));
    f.addListener(_onChanged);
  }

  @override
  void dispose() {
    f.removeListener(_onChanged);
    _searchCtrl.dispose();
    _tab.dispose();
    super.dispose();
  }

  void _onChanged() {
    // Внешние изменения фильтра (напр. «Reset all») отражаем в поле.
    if (_searchCtrl.text != f.search) _searchCtrl.text = f.search;
    if (mounted) setState(() {});
  }

  String _appLabel(String pkg) {
    final name = AppInfoCache.of(pkg)?.appName;
    if (name != null && name.isNotEmpty) return name;
    final seg = pkg.split('.');
    return seg.isNotEmpty ? seg.last : pkg;
  }

  Widget _dotTab(String label, bool active) => Tab(
    height: 40,
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label),
        if (active) ...[
          const SizedBox(width: 5),
          Container(
            width: 7,
            height: 7,
            decoration: const BoxDecoration(
              color: Colors.amber,
              shape: BoxShape.circle,
            ),
          ),
        ],
      ],
    ),
  );

  // ── Protocol-таб ──
  Widget _protocolTab() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Wrap(
        spacing: 8,
        runSpacing: 4,
        children: [
          for (final (label, kind) in _protocols)
            FilterChip(
              label: Text(label),
              selected: f.hasKind(kind),
              onSelected: (v) => f.toggleKind(kind, v),
            ),
        ],
      ),
    );
  }

  // ── App-таб ──
  Widget _appTab() {
    // Замеченные + extra (из пикера), отсортированы: выбранные наверх.
    final all = <String>{...widget.seenApps, ..._extraApps}.toList();
    all.sort((a, b) {
      final sa = f.hasApp(a) ? 0 : 1;
      final sb = f.hasApp(b) ? 0 : 1;
      if (sa != sb) return sa - sb;
      return _appLabel(a).toLowerCase().compareTo(_appLabel(b).toLowerCase());
    });
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Кнопка пикера — В НАЧАЛЕ (просьба юзера): добавить app, которого ещё
        // не было в трафике, без скролла до конца списка.
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: OutlinedButton.icon(
            icon: const Icon(Icons.add, size: 18),
            label: Text(getLocalText.s("Add app from full list")),
            onPressed: _openPicker,
          ),
        ),
        // «Потеряшки» — события без owner'а.
        if (widget.hasUnattributed || f.includeUnattributed)
          CheckboxListTile(
            value: f.includeUnattributed,
            onChanged: (v) => f.includeUnattributed = v ?? false,
            controlAffinity: ListTileControlAffinity.leading,
            dense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 4),
            secondary: Icon(
              Icons.help_outline,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            title: Text(
              getLocalText.s("Unattributed (no owner)"),
              style: const TextStyle(fontSize: 13),
            ),
            subtitle: Text(
              getLocalText.s("Events with no owning app"),
              style: const TextStyle(fontSize: 10),
            ),
          ),
        if (all.isEmpty && !widget.hasUnattributed)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Text(
              getLocalText.s(
                "No apps seen yet — traffic will populate this list.",
              ),
              style: const TextStyle(fontSize: 12),
            ),
          ),
        for (final pkg in all)
          CheckboxListTile(
            value: f.hasApp(pkg),
            onChanged: (v) => f.toggleApp(pkg, v ?? false),
            controlAffinity: ListTileControlAffinity.leading,
            dense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 4),
            secondary: _appIcon(pkg),
            title: Text(_appLabel(pkg), style: const TextStyle(fontSize: 13)),
            subtitle: Text(
              pkg,
              style: const TextStyle(fontSize: 10, fontFamily: 'monospace'),
            ),
          ),
      ],
    );
  }

  // ── Rule-таб (§230) — по сматчившему route-правилу; '' = «final» ──
  Widget _ruleTab() {
    // seenRules + уже выбранные (могли осесть в фильтре из прошлой сессии).
    // '' нормализуем в псевдо-пункт «final».
    final all = <String>{...widget.seenRules, ...f.rules}.toList()
      ..sort((a, b) {
        final sa = f.hasRule(a) ? 0 : 1;
        final sb = f.hasRule(b) ? 0 : 1;
        if (sa != sb) return sa - sb;
        return a.compareTo(b);
      });
    if (all.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Text(
          getLocalText.s(
            "No rules seen yet — traffic will populate this list.",
          ),
          style: const TextStyle(fontSize: 12),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Wrap(
        spacing: 8,
        runSpacing: 4,
        children: [
          for (final r in all)
            FilterChip(
              label: Text(r.isEmpty ? getLocalText.s("final") : r),
              selected: f.hasRule(r),
              onSelected: (v) => f.toggleRule(r, v),
            ),
        ],
      ),
    );
  }

  // ── Outbound-таб (§230) — любое звено outboundChain ∪ detourChain ──
  Widget _outboundTab() {
    final all = <String>{...widget.seenOutbounds, ...f.outbounds}.toList()
      ..sort((a, b) {
        final sa = f.hasOutbound(a) ? 0 : 1;
        final sb = f.hasOutbound(b) ? 0 : 1;
        if (sa != sb) return sa - sb;
        return a.compareTo(b);
      });
    if (all.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Text(
          getLocalText.s(
            "No outbounds seen yet — traffic will populate this list.",
          ),
          style: const TextStyle(fontSize: 12),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Wrap(
        spacing: 8,
        runSpacing: 4,
        children: [
          for (final o in all)
            FilterChip(
              label: Text(o),
              selected: f.hasOutbound(o),
              onSelected: (v) => f.toggleOutbound(o, v),
            ),
        ],
      ),
    );
  }

  Widget _appIcon(String pkg) {
    AppInfoCache.ensure(pkg);
    return AnimatedBuilder(
      animation: AppInfoCache.revision,
      builder: (_, _) {
        final info = AppInfoCache.of(pkg);
        if (info?.icon != null) {
          return ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: Image.memory(
              info!.icon!,
              width: 28,
              height: 28,
              gaplessPlayback: true,
            ),
          );
        }
        final cs = Theme.of(context).colorScheme;
        final label = _appLabel(pkg);
        return SizedBox(
          width: 28,
          height: 28,
          child: CircleAvatar(
            backgroundColor: cs.surfaceContainerHighest,
            child: Text(
              label.isEmpty ? '?' : label.characters.first.toUpperCase(),
              style: TextStyle(fontSize: 11, color: cs.onSurface),
            ),
          ),
        );
      },
    );
  }

  Future<void> _openPicker() async {
    await showAppBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _PickerSheet(
        filter: f,
        onPicked: (pkg) {
          // добавленный пакет показываем в App-табе даже если его не было в seen.
          setState(() => _extraApps.add(pkg));
        },
      ),
    );
  }

  // §230 — определения табов (label, есть-ли-активный-фильтр, builder). Порядок
  // и состав ДОЛЖНЫ совпадать с длиной _tab (initState): Protocol [· App]
  // [· Rule] [· Outbound]. Условия те же, что в _show*Tab / showAppTab.
  List<(String, bool, Widget Function())> get _tabDefs => [
    ('Protocol', f.kinds.isNotEmpty, _protocolTab),
    if (widget.showAppTab) ('App', f.appAxisActive, _appTab),
    if (_showRuleTab) ('Rule', f.rules.isNotEmpty, _ruleTab),
    if (_showOutboundTab) ('Outbound', f.outbounds.isNotEmpty, _outboundTab),
  ];

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: mq.size.height * 0.8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    getLocalText.s("Filter events"),
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (f.isActive)
                  TextButton(
                    onPressed: f.clearAll,
                    child: Text(getLocalText.s("Reset all")),
                  ),
              ],
            ),
            // §230 — поиск по domain/ip/process (substring). Клик по домену в
            // детали соединения кладёт значение сюда; юзер видит/правит/чистит.
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: TextField(
                controller: _searchCtrl,
                onChanged: (v) => f.search = v.trim(),
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  isDense: true,
                  hintText: getLocalText.s("Search domain / IP / app"),
                  prefixIcon: const Icon(Icons.search, size: 18),
                  suffixIcon: _searchCtrl.text.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.close, size: 18),
                          tooltip: getLocalText.s("Clear"),
                          onPressed: () {
                            _searchCtrl.clear();
                            f.search = '';
                          },
                        ),
                  border: const OutlineInputBorder(),
                ),
              ),
            ),
            TabBar(
              controller: _tab,
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              tabs: [
                for (final (label, active, _) in _tabDefs)
                  _dotTab(label, active),
              ],
            ),
            const SizedBox(height: 4),
            Flexible(
              child: SingleChildScrollView(
                child: AnimatedBuilder(
                  animation: _tab,
                  builder: (_, _) {
                    final defs = _tabDefs;
                    final i = _tab.index.clamp(0, defs.length - 1);
                    return defs[i].$3();
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Полный пикер приложений (за кнопкой «Add app»). Мульти-select поверх
/// [AppMultiPicker]; выбор сразу пишется в [filter.apps] + дёргается [onPicked]
/// чтобы родитель показал пакет в App-табе.
class _PickerSheet extends StatefulWidget {
  const _PickerSheet({required this.filter, required this.onPicked});
  final ProfilerFilter filter;
  final void Function(String pkg) onPicked;

  @override
  State<_PickerSheet> createState() => _PickerSheetState();
}

class _PickerSheetState extends State<_PickerSheet> {
  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: mq.size.height * 0.85),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                getLocalText.s("Add app to filter"),
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Flexible(
              child: AppMultiPicker(
                selected: widget.filter.apps,
                onToggle: (pkg, on) {
                  widget.filter.toggleApp(pkg, on);
                  if (on) widget.onPicked(pkg);
                  setState(() {});
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
