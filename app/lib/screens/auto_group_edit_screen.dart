import 'package:flutter/material.dart';

import '../models/auto_select.dart';
import '../models/direction.dart';
import '../models/node_spec.dart';
import '../services/l10n/locale_controller.dart';
import '../services/parser/uri_utils.dart';
import '../services/safe_regex.dart';
import '../services/ui_helpers.dart';
import '../widgets/safe_bottom.dart';

/// §322 — редактор узла автовыбора внутри папки.
///
/// Идиома проекта ([direction_edit_screen.dart]): Navigator.push + PopScope
/// back-guard (Save/Keep/Discard) + AppBar delete/save.
///
/// Отличие от Направления: членство здесь — три режима (все / правило / список),
/// и превью показывает, кто именно попал в пул. [candidates] — узлы папки
/// (без самой группы), по ним и считается превью.
class AutoGroupEditScreen extends StatefulWidget {
  const AutoGroupEditScreen({
    super.key,
    required this.initial,
    required this.candidates,
    required this.canDelete,
  });

  /// `null` — создание нового узла.
  final AutoSelectSpec? initial;

  /// Кандидаты в пул — узлы того же контейнера. Пара (ключ §321, имя).
  final List<({String key, String label})> candidates;

  final bool canDelete;

  @override
  State<AutoGroupEditScreen> createState() => _AutoGroupEditScreenState();
}

/// Что вернул экран: сохранение или удаление.
sealed class AutoGroupEditResult {
  const AutoGroupEditResult();
  const factory AutoGroupEditResult.saved(AutoSelectSpec spec) = AutoGroupSaved;
  const factory AutoGroupEditResult.deleted() = AutoGroupDeleted;
}

final class AutoGroupSaved extends AutoGroupEditResult {
  final AutoSelectSpec spec;
  const AutoGroupSaved(this.spec);
}

final class AutoGroupDeleted extends AutoGroupEditResult {
  const AutoGroupDeleted();
}

enum _MembershipMode { all, rule, explicit }

class _AutoGroupEditScreenState extends State<AutoGroupEditScreen> {
  late final TextEditingController _labelCtrl;
  late final TextEditingController _includeCtrl;
  late final TextEditingController _excludeCtrl;
  late final TextEditingController _urlCtrl;
  late final TextEditingController _intervalCtrl;
  late final TextEditingController _toleranceCtrl;
  late final TextEditingController _idleCtrl;
  late final TextEditingController _poolCtrl;
  late final TextEditingController _poolToleranceCtrl;
  late final TextEditingController _badgeCtrl; // §322 — UI-only значки

  late _MembershipMode _mode;
  late Set<String> _picked; // ключи для режима «список»
  late UrltestMode _urlMode;
  late Set<StickyHashKey> _sticky;
  late bool _interrupt; // §208 — рвать соединения при смене узла
  bool _advanced = false;

  late final String _initialUri; // снимок для сравнения «грязно ли»

  @override
  void initState() {
    super.initState();
    final s = widget.initial;
    final m = s?.membership ?? const RuleMembers();
    final p = s?.params ?? const AutoSelectParams();

    _labelCtrl = TextEditingController(text: s?.label ?? '')
      ..addListener(_onChanged);
    _includeCtrl = TextEditingController(
        text: m is RuleMembers ? m.include : '')
      ..addListener(_onChanged);
    _excludeCtrl = TextEditingController(
        text: m is RuleMembers ? m.exclude : '')
      ..addListener(_onChanged);
    _urlCtrl = TextEditingController(text: p.url)..addListener(_onChanged);
    _intervalCtrl = TextEditingController(text: p.interval)
      ..addListener(_onChanged);
    _toleranceCtrl = TextEditingController(text: '${p.tolerance}')
      ..addListener(_onChanged);
    _idleCtrl = TextEditingController(text: p.idleTimeout)
      ..addListener(_onChanged);
    _poolCtrl = TextEditingController(text: '${p.pool}')
      ..addListener(_onChanged);
    _poolToleranceCtrl = TextEditingController(text: '${p.poolTolerance}')
      ..addListener(_onChanged);
    _badgeCtrl = TextEditingController(text: s?.poolBadge ?? kDefaultPoolBadge)
      ..addListener(_onChanged);

    _mode = switch (m) {
      ExplicitMembers() => _MembershipMode.explicit,
      RuleMembers(:final include, :final exclude)
          when include.isEmpty && exclude.isEmpty =>
        _MembershipMode.all,
      RuleMembers() => _MembershipMode.rule,
    };
    _picked = m is ExplicitMembers ? m.keys.toSet() : <String>{};
    _urlMode = p.mode;
    _sticky = p.stickyHash.toSet();
    _interrupt = p.interruptExistConnections;
    _initialUri = _snapshot().toUri();
  }

  @override
  void dispose() {
    for (final c in [
      _labelCtrl, _includeCtrl, _excludeCtrl, _urlCtrl, _intervalCtrl,
      _toleranceCtrl, _idleCtrl, _poolCtrl, _poolToleranceCtrl, _badgeCtrl,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  void _onChanged() => setState(() {});

  // ── Сборка результата ──

  AutoSelectMembership _membership() => switch (_mode) {
        _MembershipMode.all => const RuleMembers(),
        _MembershipMode.rule => RuleMembers(
            include: _includeCtrl.text.trim(),
            exclude: _excludeCtrl.text.trim(),
          ),
        // Порядок — как в списке папки, а не как кликали чекбоксы.
        _MembershipMode.explicit => ExplicitMembers([
            for (final c in widget.candidates)
              if (_picked.contains(c.key)) c.key,
          ]),
      };

  AutoSelectSpec _snapshot() {
    final label = _labelCtrl.text.trim().isEmpty
        ? getLocalText.s("Auto")
        : _labelCtrl.text.trim();
    const d = AutoSelectParams();
    return AutoSelectSpec(
      id: widget.initial?.id ?? newUuidV4(),
      tag: tagFromLabel(label, 'urltest', 'auto', 0),
      label: label,
      membership: _membership(),
      params: AutoSelectParams(
        url: _urlCtrl.text.trim().isEmpty ? d.url : _urlCtrl.text.trim(),
        interval:
            _intervalCtrl.text.trim().isEmpty ? d.interval : _intervalCtrl.text.trim(),
        tolerance: int.tryParse(_toleranceCtrl.text.trim()) ?? d.tolerance,
        idleTimeout:
            _idleCtrl.text.trim().isEmpty ? d.idleTimeout : _idleCtrl.text.trim(),
        mode: _urlMode,
        pool: int.tryParse(_poolCtrl.text.trim()) ?? d.pool,
        poolTolerance: clampPoolTolerance(
            int.tryParse(_poolToleranceCtrl.text.trim()) ?? d.poolTolerance),
        stickyHash: [
          for (final k in StickyHashKey.values)
            if (_sticky.contains(k)) k,
        ],
        interruptExistConnections: _interrupt,
      ),
      // Синонимы — производное от подписки; у папочной группы их нет, у
      // приехавшей из подписки сохраняем как есть (правка их не меняет).
      tagSynonyms: widget.initial?.tagSynonyms ?? const {},
      poolBadge: _badgeCtrl.text.trim(),
    );
  }

  bool _isDirty() => _snapshot().toUri() != _initialUri;

  // ── Превью состава ──

  /// Кандидаты, попавшие в пул при текущих настройках. Повторяет логику
  /// `resolveAutoSelectMembers`, но по именам: синонимов у папочной группы
  /// нет, а у приехавшей из подписки превью всё равно показывает имена.
  List<({String key, String label})> _matched() {
    switch (_mode) {
      case _MembershipMode.all:
        return widget.candidates;
      case _MembershipMode.explicit:
        return [
          for (final c in widget.candidates)
            if (_picked.contains(c.key)) c
        ];
      case _MembershipMode.rule:
        final inc = tryCompileRegex(_includeCtrl.text.trim());
        final exc = tryCompileRegex(_excludeCtrl.text.trim());
        return [
          for (final c in widget.candidates)
            if (ruleAccepts([c.label], inc, exc)) c
        ];
    }
  }

  // ── Навигация ──

  Future<void> _handleBack() async {
    if (!_isDirty()) {
      Navigator.pop(context);
      return;
    }
    final action = await showUnsavedChangesDialog(context);
    if (!mounted) return;
    if (action == 'save') {
      _save();
    } else if (action == 'discard') {
      Navigator.pop(context);
    }
  }

  void _save() =>
      Navigator.pop(context, AutoGroupEditResult.saved(_snapshot()));

  Future<void> _delete() async {
    final ok = await showDeleteConfirmDialog(
      context,
      title: getLocalText.s("Delete auto node?"),
      message: getLocalText.s(
          "The servers it selects from stay in the folder."),
    );
    if (!mounted || ok != true) return;
    Navigator.pop(context, const AutoGroupEditResult.deleted());
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final dirty = _isDirty();
    final matched = _matched();
    final includeText = _includeCtrl.text.trim();
    final excludeText = _excludeCtrl.text.trim();
    final includeValid = includeText.isEmpty || tryCompileRegex(includeText) != null;
    final excludeValid = excludeText.isEmpty || tryCompileRegex(excludeText) != null;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _handleBack();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.initial == null
              ? getLocalText.s("New auto node")
              : getLocalText.s("Edit auto node")),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: _handleBack,
          ),
          actions: [
            if (widget.canDelete)
              IconButton(
                tooltip: getLocalText.s("Delete"),
                icon: Icon(Icons.delete_outline, color: cs.error),
                onPressed: _delete,
              ),
            IconButton(
              tooltip: getLocalText.s("Save"),
              icon: Icon(Icons.check,
                  color: dirty ? cs.primary : cs.onSurfaceVariant),
              onPressed: _save,
            ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 32).withSafeBottom(context),
          children: [
            TextField(
              controller: _labelCtrl,
              decoration: InputDecoration(
                labelText: getLocalText.s("Name"),
                hintText: getLocalText.s("Auto"),
                border: const OutlineInputBorder(),
                isDense: true,
              ),
              style: const TextStyle(fontSize: 14),
            ),
            const Divider(height: 28),

            // ── Членство ──
            Text(getLocalText.s("Servers in the pool"),
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
            const SizedBox(height: 6),
            SegmentedButton<_MembershipMode>(
              segments: [
                ButtonSegment(
                  value: _MembershipMode.all,
                  label: Text(getLocalText.s("All")),
                  icon: const Icon(Icons.select_all, size: 16),
                ),
                ButtonSegment(
                  value: _MembershipMode.rule,
                  label: Text(getLocalText.s("Rule")),
                  icon: const Icon(Icons.filter_alt_outlined, size: 16),
                ),
                ButtonSegment(
                  value: _MembershipMode.explicit,
                  label: Text(getLocalText.s("Pick")),
                  icon: const Icon(Icons.checklist, size: 16),
                ),
              ],
              selected: {_mode},
              showSelectedIcon: false,
              style: const ButtonStyle(
                visualDensity: VisualDensity.compact,
                textStyle: WidgetStatePropertyAll(TextStyle(fontSize: 12)),
              ),
              onSelectionChanged: (s) => setState(() {
                final next = s.first;
                // Переключение «правило → список» разворачивает текущий
                // результат в галочки: пользователь видит то же самое и может
                // подправить руками, а не начинает с нуля.
                if (next == _MembershipMode.explicit &&
                    _mode != _MembershipMode.explicit) {
                  _picked = _matched().map((c) => c.key).toSet();
                }
                _mode = next;
              }),
            ),
            const SizedBox(height: 10),

            if (_mode == _MembershipMode.rule) ...[
              TextField(
                controller: _includeCtrl,
                decoration: InputDecoration(
                  labelText: getLocalText.s("Include (regex)"),
                  hintText: getLocalText.s("empty = all servers"),
                  border: const OutlineInputBorder(),
                  isDense: true,
                  errorText: includeValid ? null : 'Invalid regex',
                  errorStyle: const TextStyle(fontSize: 10),
                ),
                style: const TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _excludeCtrl,
                decoration: InputDecoration(
                  labelText: getLocalText.s("Exclude (regex)"),
                  hintText: getLocalText.s("applied after include"),
                  border: const OutlineInputBorder(),
                  isDense: true,
                  errorText: excludeValid ? null : 'Invalid regex',
                  errorStyle: const TextStyle(fontSize: 10),
                ),
                style: const TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 8),
            ],

            // Превью состава — общее для всех режимов.
            _previewLine(
              cs,
              getLocalText.s("%s of %s servers", '${matched.length}',
                  '${widget.candidates.length}'),
            ),
            const SizedBox(height: 6),
            _memberList(cs, matched),

            const Divider(height: 28),

            // ── Режим выбора ──
            Text(getLocalText.s("Mode"),
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
            const SizedBox(height: 6),
            SegmentedButton<UrltestMode>(
              segments: [
                ButtonSegment(
                  value: UrltestMode.leastTest,
                  label: Text(getLocalText.s("Fastest")),
                  icon: const Icon(Icons.bolt, size: 16),
                ),
                ButtonSegment(
                  value: UrltestMode.roundRobin,
                  label: Text(getLocalText.s("Load balance")),
                  icon: const Icon(Icons.hub_outlined, size: 16),
                ),
              ],
              selected: {_urlMode},
              showSelectedIcon: false,
              style: const ButtonStyle(
                visualDensity: VisualDensity.compact,
                textStyle: WidgetStatePropertyAll(TextStyle(fontSize: 12)),
              ),
              onSelectionChanged: (s) => setState(() => _urlMode = s.first),
            ),
            const SizedBox(height: 4),
            _previewLine(
              cs,
              _urlMode == UrltestMode.leastTest
                  ? getLocalText.s("single best server by latency")
                  : getLocalText
                      .s("spread connections across a pool of servers"),
            ),

            if (_urlMode == UrltestMode.roundRobin) ..._balancerControls(cs),

            const Divider(height: 28),

            // ── Advanced ──
            InkWell(
              onTap: () => setState(() => _advanced = !_advanced),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    Icon(
                      _advanced ? Icons.expand_less : Icons.expand_more,
                      size: 18,
                      color: cs.onSurfaceVariant,
                    ),
                    const SizedBox(width: 6),
                    Text(getLocalText.s("Advanced"),
                        style:
                            TextStyle(fontSize: 13, color: cs.onSurfaceVariant)),
                  ],
                ),
              ),
            ),
            if (_advanced) ..._advancedControls(cs),
          ],
        ),
      ),
    );
  }

  Widget _previewLine(ColorScheme cs, String text) => Text(
        text,
        style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
      );

  /// Список кандидатов. В режиме «список» — с чекбоксами; иначе только
  /// показывает, кто попал (галочка) и кто нет (приглушённый).
  Widget _memberList(
      ColorScheme cs, List<({String key, String label})> matched) {
    if (widget.candidates.isEmpty) {
      return _previewLine(cs, getLocalText.s("Folder has no servers yet"));
    }
    final hit = matched.map((c) => c.key).toSet();
    return Container(
      constraints: const BoxConstraints(maxHeight: 240),
      decoration: BoxDecoration(
        border: Border.all(color: cs.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      child: ListView.builder(
        shrinkWrap: true,
        itemCount: widget.candidates.length,
        itemBuilder: (_, i) {
          final c = widget.candidates[i];
          final inPool = hit.contains(c.key);
          if (_mode == _MembershipMode.explicit) {
            return CheckboxListTile(
              dense: true,
              visualDensity: VisualDensity.compact,
              controlAffinity: ListTileControlAffinity.leading,
              title: Text(c.label,
                  style: const TextStyle(fontSize: 13),
                  overflow: TextOverflow.ellipsis),
              value: _picked.contains(c.key),
              onChanged: (v) => setState(() {
                if (v ?? false) {
                  _picked.add(c.key);
                } else {
                  _picked.remove(c.key);
                }
              }),
            );
          }
          return ListTile(
            dense: true,
            visualDensity: VisualDensity.compact,
            leading: Icon(
              inPool ? Icons.check_circle_outline : Icons.remove_circle_outline,
              size: 18,
              color: inPool ? cs.primary : cs.onSurfaceVariant.withValues(alpha: .5),
            ),
            title: Text(
              c.label,
              style: TextStyle(
                fontSize: 13,
                color: inPool ? null : cs.onSurfaceVariant.withValues(alpha: .5),
              ),
              overflow: TextOverflow.ellipsis,
            ),
          );
        },
      ),
    );
  }

  /// §208 — pool size / tolerance + sticky-чипы. Только под Load balance.
  List<Widget> _balancerControls(ColorScheme cs) {
    final n = widget.candidates.length;
    return [
      const SizedBox(height: 10),
      Row(
        children: [
          Expanded(
            child: TextField(
              controller: _poolCtrl,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: getLocalText.s("Pool size"),
                border: const OutlineInputBorder(),
                isDense: true,
                helperText:
                    n > 0 ? getLocalText.plural("of %d nodes", n) : null,
                helperStyle: const TextStyle(fontSize: 10),
              ),
              style: const TextStyle(fontSize: 13),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _poolToleranceCtrl,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: getLocalText.s("Pool tolerance (ms)"),
                border: const OutlineInputBorder(),
                isDense: true,
                helperText: getLocalText.s("0 = keep pool full"),
                helperStyle: const TextStyle(fontSize: 10),
              ),
              style: const TextStyle(fontSize: 13),
            ),
          ),
        ],
      ),
      const SizedBox(height: 10),
      Text(getLocalText.s("Sticky session by"),
          style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
      const SizedBox(height: 4),
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (final k in StickyHashKey.values)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: FilterChip(
                  label: Text(_stickyLabel(k),
                      style: const TextStyle(fontSize: 12)),
                  selected: _sticky.contains(k),
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  onSelected: (sel) => setState(() {
                    if (sel) {
                      _sticky.add(k);
                    } else {
                      _sticky.remove(k);
                    }
                  }),
                ),
              ),
          ],
        ),
      ),
      const SizedBox(height: 4),
      _previewLine(
        cs,
        _sticky.isEmpty
            ? getLocalText.s("no stickiness — every connection re-picks")
            : getLocalText.s("connections with the same key keep one server"),
      ),
    ];
  }

  List<Widget> _advancedControls(ColorScheme cs) => [
        const SizedBox(height: 8),
        TextField(
          controller: _urlCtrl,
          decoration: InputDecoration(
            labelText: getLocalText.s("Test URL"),
            border: const OutlineInputBorder(),
            isDense: true,
          ),
          style: const TextStyle(fontSize: 13),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _intervalCtrl,
                decoration: InputDecoration(
                  labelText: getLocalText.s("Interval"),
                  border: const OutlineInputBorder(),
                  isDense: true,
                  helperText: getLocalText.s("e.g. 15m"),
                  helperStyle: const TextStyle(fontSize: 10),
                ),
                style: const TextStyle(fontSize: 13),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _idleCtrl,
                decoration: InputDecoration(
                  labelText: getLocalText.s("Idle timeout"),
                  border: const OutlineInputBorder(),
                  isDense: true,
                  helperText: getLocalText.s("e.g. 30m"),
                  helperStyle: const TextStyle(fontSize: 10),
                ),
                style: const TextStyle(fontSize: 13),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        CheckboxListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          visualDensity: VisualDensity.compact,
          title: Text(getLocalText.s("Interrupt connections on switch"),
              style: const TextStyle(fontSize: 14)),
          subtitle: Text(
              getLocalText.s(
                  "off: open connections finish on the old server"),
              style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
          value: _interrupt,
          onChanged: (v) => setState(() => _interrupt = v ?? false),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _badgeCtrl,
          decoration: InputDecoration(
            labelText: getLocalText.s("Badge in list (regex)"),
            border: const OutlineInputBorder(),
            isDense: true,
            helperText: getLocalText.s(
                "taken from member names; empty = no badges. Display only — not sent to the core"),
            helperMaxLines: 3,
            helperStyle: const TextStyle(fontSize: 10),
          ),
          style: const TextStyle(fontSize: 13),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _toleranceCtrl,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
            labelText: getLocalText.s("Switch tolerance (ms)"),
            border: const OutlineInputBorder(),
            isDense: true,
            helperText:
                getLocalText.s("how much faster a rival must be to win"),
            helperStyle: const TextStyle(fontSize: 10),
          ),
          style: const TextStyle(fontSize: 13),
        ),
      ];

  // Названия ключей — как в §208-редакторе Направления: технические термины
  // config'а, не переводим (l10n-exempt по тому же основанию).
  String _stickyLabel(StickyHashKey k) => switch (k) {
        StickyHashKey.process => 'process',
        StickyHashKey.domain => 'domain',
        StickyHashKey.sourceIp => 'source ip',
        StickyHashKey.destIp => 'dest ip',
        StickyHashKey.destPort => 'dest port',
      };
}
