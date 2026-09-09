import 'package:flutter/material.dart';

import '../models/direction.dart';
import '../services/ui_helpers.dart';
import 'home/filter_widgets.dart' show NegateToggle;
import '../services/l10n/locale_controller.dart';
import '../widgets/safe_bottom.dart';

/// §125 — полноэкранный редактор Направления роутинга. Идиома проекта
/// ([custom_rule_edit_screen.dart], [dns_server_edit_screen.dart]):
/// Navigator.push + PopScope back-guard (Save/Keep/Discard) + AppBar
/// delete/save. tag read-only (системный), label — единственное «имя».
///
/// Live-превью regex: [allNodeTags] — снимок тегов нод подписки (из ccGroups).
/// Пусто (туннель не поднят) → превью показывает «no node snapshot».
class DirectionEditScreen extends StatefulWidget {
  const DirectionEditScreen({
    super.key,
    required this.initial,
    required this.canDelete,
    required this.allNodeTags,
    this.directionsAbove = const [],
  });

  final Direction initial;

  /// vpn-1 неудаляем → false. Прочие → true.
  final bool canDelete;

  /// Снимок тегов нод подписки для live-превью фильтров.
  final List<String> allNodeTags;

  /// §393 A3 — Направления, стоящие ВЫШЕ редактируемого по списку: только их
  /// законно взять опцией (`include`). Порядок исключает циклы по построению,
  /// поэтому форма кандидатов ниже не предлагает вовсе (эталон —
  /// `tagsAbove` лаунчера). У самого верхнего список пуст, и секция не
  /// рисуется.
  final List<Direction> directionsAbove;

  @override
  State<DirectionEditScreen> createState() => _DirectionEditScreenState();
}

class _DirectionEditScreenState extends State<DirectionEditScreen> {
  late final TextEditingController _labelCtrl;
  late final TextEditingController _nodeFilterCtrl;
  late final TextEditingController _defaultFilterCtrl;
  late final TextEditingController _autoUrlCtrl;
  late final TextEditingController _autoIntervalCtrl;
  late final TextEditingController _autoToleranceCtrl;
  late final TextEditingController _autoIdleCtrl;
  // §208 — balancer-поля (round_robin)
  late final TextEditingController _autoPoolCtrl;
  late final TextEditingController _autoPoolToleranceCtrl;

  late bool _includeDirect;
  late bool _includeBlock;

  /// §393 A3 — выбранные теги других Направлений. Set для O(1) галок; в
  /// снапшот уезжает списком в порядке [DirectionEditScreen.directionsAbove]
  /// (детерминизм diff/JSON — как со sticky_hash).
  late Set<String> _include;
  late bool _isDetour;
  late bool _interrupt;
  late bool _nodeFilterInvert;
  late bool _autoEnabled;
  late bool _autoInterrupt;
  // §208 — режим балансировки + набор sticky-ключей (round_robin)
  late UrltestMode _autoMode;
  late Set<StickyHashKey> _autoSticky;

  @override
  void initState() {
    super.initState();
    final c = widget.initial;
    _labelCtrl = TextEditingController(text: c.label);
    _nodeFilterCtrl = TextEditingController(text: c.nodeFilter);
    _defaultFilterCtrl = TextEditingController(text: c.defaultFilter);
    _includeDirect = c.includeDirect;
    _includeBlock = c.includeBlock;
    _include = c.include.toSet();
    _isDetour = c.isDetour;
    _interrupt = c.interruptExistConnections;
    _nodeFilterInvert = c.nodeFilterInvert;
    _autoEnabled = c.auto != null;

    final a = c.auto ?? const DirectionAuto();
    _autoUrlCtrl = TextEditingController(text: a.url);
    _autoIntervalCtrl = TextEditingController(text: a.interval);
    _autoToleranceCtrl = TextEditingController(text: a.tolerance.toString());
    _autoIdleCtrl = TextEditingController(text: a.idleTimeout);
    _autoInterrupt = a.interruptExistConnections;
    // §208 — balancer
    _autoMode = a.mode;
    _autoPoolCtrl = TextEditingController(text: a.pool.toString());
    _autoPoolToleranceCtrl =
        TextEditingController(text: a.poolTolerance.toString());
    _autoSticky = a.stickyHash.toSet();

    for (final ctrl in [
      _labelCtrl,
      _nodeFilterCtrl,
      _defaultFilterCtrl,
      _autoUrlCtrl,
      _autoIntervalCtrl,
      _autoToleranceCtrl,
      _autoIdleCtrl,
      _autoPoolCtrl,
      _autoPoolToleranceCtrl,
    ]) {
      ctrl.addListener(_onAnyChange);
    }
  }

  @override
  void dispose() {
    for (final ctrl in [
      _labelCtrl,
      _nodeFilterCtrl,
      _defaultFilterCtrl,
      _autoUrlCtrl,
      _autoIntervalCtrl,
      _autoToleranceCtrl,
      _autoIdleCtrl,
      _autoPoolCtrl,
      _autoPoolToleranceCtrl,
    ]) {
      ctrl.dispose();
    }
    super.dispose();
  }

  void _onAnyChange() => setState(() {}); // live-превью + dirty-индикатор

  /// Собирает редактируемое состояние в [Direction] (tag/enabled immutable —
  /// берутся из initial).
  Direction _snapshot() {
    final c = widget.initial;
    return c.copyWith(
      label: _labelCtrl.text.trim().isEmpty
          ? c.tag
          : _labelCtrl.text.trim(),
      includeDirect: _includeDirect,
      includeBlock: _includeBlock,
      // §393 A3 — сохраняем ТОЛЬКО живых кандидатов сверху: галка снятая
      // потому, что Направление уехало вниз, честно уходит из данных, а не
      // висит битой ссылкой. Порядок — по списку кандидатов.
      include: [
        for (final d in widget.directionsAbove)
          if (_include.contains(d.tag)) d.tag,
      ],
      isDetour: _isDetour,
      nodeFilter: _nodeFilterCtrl.text.trim(),
      nodeFilterInvert: _nodeFilterInvert,
      defaultFilter: _defaultFilterCtrl.text.trim(),
      interruptExistConnections: _interrupt,
      clearAuto: !_autoEnabled,
      auto: _autoEnabled
          ? DirectionAuto(
              url: _autoUrlCtrl.text.trim(),
              interval: _autoIntervalCtrl.text.trim().isEmpty
                  ? '5m'
                  : _autoIntervalCtrl.text.trim(),
              // §219/§221 — tolerance/pool/poolTolerance клэмпим ЗДЕСЬ (как в
              // DirectionAuto.toJson/copyWith): прямой конструктор не клэмпит,
              // иначе снапшот в памяти (для _isDirty) расходился бы с тем, что
              // реально персистится (uint16 [0,65535], pool≥1).
              tolerance: clampDirectionTolerance(
                  int.tryParse(_autoToleranceCtrl.text.trim()) ?? 50),
              idleTimeout: _autoIdleCtrl.text.trim().isEmpty
                  ? '30m'
                  : _autoIdleCtrl.text.trim(),
              interruptExistConnections: _autoInterrupt,
              // §208 — balancer (значимы только при round_robin, но храним всегда
              // — переключение режима не теряет настройки пула).
              mode: _autoMode,
              pool: clampDirectionPool(
                  int.tryParse(_autoPoolCtrl.text.trim()) ?? 3),
              poolTolerance: clampDirectionTolerance(
                  int.tryParse(_autoPoolToleranceCtrl.text.trim()) ?? 0),
              // Set→List в фиксированном порядке enum (детерминизм diff/JSON).
              stickyHash: StickyHashKey.values
                  .where(_autoSticky.contains)
                  .toList(),
            )
          : null,
    );
  }

  bool _isDirty() {
    final s = _snapshot();
    final i = widget.initial;
    return s.label != i.label ||
        s.includeDirect != i.includeDirect ||
        s.includeBlock != i.includeBlock ||
        !_sameTags(s.include, i.include) ||
        s.isDetour != i.isDetour ||
        s.nodeFilter != i.nodeFilter ||
        s.nodeFilterInvert != i.nodeFilterInvert ||
        s.defaultFilter != i.defaultFilter ||
        s.interruptExistConnections != i.interruptExistConnections ||
        (s.auto == null) != (i.auto == null) ||
        (s.auto != null &&
            i.auto != null &&
            (s.auto!.url != i.auto!.url ||
                s.auto!.interval != i.auto!.interval ||
                s.auto!.tolerance != i.auto!.tolerance ||
                s.auto!.idleTimeout != i.auto!.idleTimeout ||
                s.auto!.interruptExistConnections !=
                    i.auto!.interruptExistConnections ||
                // §208 — balancer-поля
                s.auto!.mode != i.auto!.mode ||
                s.auto!.pool != i.auto!.pool ||
                s.auto!.poolTolerance != i.auto!.poolTolerance ||
                !_sameSticky(s.auto!.stickyHash, i.auto!.stickyHash)));
  }

  /// §393 A3 — подсекция «Other directions» внутри блока состава: чекбокс на
  /// каждое Направление ВЫШЕ текущего. Пустой список кандидатов → подсекции
  /// нет вовсе, вместе с разделителем и заголовком (у самого верхнего
  /// включать нечего, и заголовок над пустотой только сбивал бы с толку).
  List<Widget> _includeSection(ColorScheme cs) {
    if (widget.directionsAbove.isEmpty) return const [];
    return [
      const Divider(height: 20),
      Text(getLocalText.s("Other directions"),
          style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
      Text(getLocalText.s("only directions listed above this one"),
          style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
      const SizedBox(height: 4),
      for (final d in widget.directionsAbove)
        CheckboxListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          visualDensity: VisualDensity.compact,
          title: Text(d.displayLabel, style: const TextStyle(fontSize: 14)),
          subtitle: Text(d.tag,
              style: TextStyle(
                  fontSize: 11,
                  fontFamily: 'monospace',
                  color: cs.onSurfaceVariant)),
          value: _include.contains(d.tag),
          onChanged: (v) => setState(() {
            if (v ?? false) {
              _include.add(d.tag);
            } else {
              _include.remove(d.tag);
            }
          }),
        ),
    ];
  }

  /// §393 A3 — равенство include-наборов (порядок детерминирован снапшотом,
  /// но сравниваем как последовательности: порядок опций в селекторе значим).
  static bool _sameTags(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// §208 — равенство sticky-наборов (порядок детерминирован в _snapshot, но
  /// сравниваем как множества — безопаснее).
  static bool _sameSticky(List<StickyHashKey> a, List<StickyHashKey> b) =>
      a.length == b.length && a.toSet().containsAll(b);

  Future<void> _handleBack() async {
    if (!_isDirty()) {
      Navigator.pop(context);
      return;
    }
    final action = await showUnsavedChangesDialog(context); // §219
    if (!mounted) return;
    if (action == 'save') {
      _save();
    } else if (action == 'discard') {
      Navigator.pop(context);
    }
  }

  void _save() {
    Navigator.pop(context, DirectionEditResult.saved(_snapshot()));
  }

  Future<void> _delete() async {
    final confirmed = await showDeleteConfirmDialog(
      context,
      title: getLocalText.s("Delete direction?"),
      message: getLocalText.s(
          "Remove \"%1\$s\" (%2\$s)? References to it fall back to vpn-1.",
          widget.initial.label,
          widget.initial.tag),
    ); // §219
    if (confirmed == true && mounted) {
      Navigator.pop(context, DirectionEditResult.deleted());
    }
  }

  // ── live-превью regex ──

  /// Компиляция regex, null при невалидном.
  RegExp? _compile(String pattern) {
    if (pattern.isEmpty) return null;
    try {
      // §301 — node-filter regex регистронезависимы во всех точках (основное
      // окно, превью, подсчёт, билдер). Юзер вводит `warp`, ждёт единого
      // поведения; Dart RegExp не понимает inline `(?i)`, только этот флаг.
      return RegExp(pattern, caseSensitive: false);
    } catch (_) {
      return null;
    }
  }
  // §219 — _isValidRegex удалён: валидность выводится из _compile()!=null,
  // не компилируем один паттерн дважды за build.

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final c = widget.initial;
    final dirty = _isDirty();

    final nodeFilterText = _nodeFilterCtrl.text.trim();
    // §219 — компилируем RegExp ОДИН раз за build. Валидность выводим из
    // результата (раньше _isValidRegex + _compile компилили один паттерн дважды).
    final re = _compile(nodeFilterText);
    final nodeFilterValid = nodeFilterText.isEmpty || re != null;
    // §197 — превью учитывает инверсию (как билдер): invert → ноды НЕ матчащие.
    final matchedNodes = nodeFilterText.isEmpty
        ? widget.allNodeTags
        : (re == null
            ? widget.allNodeTags
            : widget.allNodeTags
                .where((t) => re.hasMatch(t) != _nodeFilterInvert)
                .toList());

    final defaultText = _defaultFilterCtrl.text.trim();
    final defaultRe = _compile(defaultText);
    final defaultValid = defaultText.isEmpty || defaultRe != null;
    final defaultPick = (defaultText.isEmpty || defaultRe == null)
        ? null
        : _firstMatch(matchedNodes, defaultRe);

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _handleBack();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(getLocalText.s("Edit direction · %s", c.tag)),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: _handleBack,
          ),
          actions: [
            if (widget.canDelete)
              IconButton(
                tooltip: getLocalText.s("Delete direction"),
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
        // Бледный hint во всех полях формы — чтобы placeholder не сливался с
        // вводимым текстом (один источник через InputDecorationTheme).
        body: Theme(
          data: Theme.of(context).copyWith(
            inputDecorationTheme:
                Theme.of(context).inputDecorationTheme.copyWith(
                      hintStyle: TextStyle(
                        fontSize: 13,
                        color: cs.onSurfaceVariant.withAlpha(110),
                      ),
                    ),
          ),
          child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 32).withSafeBottom(context),
          children: [
            // системный tag (read-only)
            Text(c.tag,
                style: TextStyle(
                    fontSize: 12,
                    fontFamily: 'monospace',
                    color: cs.onSurfaceVariant)),
            const SizedBox(height: 8),
            TextField(
              controller: _labelCtrl,
              decoration: InputDecoration(
                labelText: getLocalText.s("Title"),
                border: const OutlineInputBorder(),
                isDense: true,
              ),
              style: const TextStyle(fontSize: 14),
            ),
            const SizedBox(height: 8),

            // ── Блок 1: СОСТАВ. Всё, что окажется опциями селектора этого
            // Направления, — одним блоком и в порядке сверху вниз:
            // direct-out, block, другие Направления. Раньше эти три галки
            // шли вперемешку с ролью (detour) и поведением при switch, и
            // юзер не видел, что это один и тот же список опций.
            _sectionHeader(
                theme,
                getLocalText.s("What goes into this direction"),
                getLocalText.s("options offered in the selector")),
            CheckboxListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              visualDensity: VisualDensity.compact,
              title: Text(getLocalText.s("Include direct-out"),
                  style: const TextStyle(fontSize: 14)),
              subtitle: Text(getLocalText.s("direct connection option in the selector"),
                  style: const TextStyle(fontSize: 11)),
              value: _includeDirect,
              onChanged: (v) => setState(() => _includeDirect = v ?? false),
            ),
            CheckboxListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              visualDensity: VisualDensity.compact,
              title: Text(getLocalText.s("Include block"),
                  style: const TextStyle(fontSize: 14)),
              subtitle: Text(getLocalText.s("drop traffic option in the selector"),
                  style: const TextStyle(fontSize: 11)),
              value: _includeBlock,
              onChanged: (v) => setState(() => _includeBlock = v ?? false),
            ),
            // §393 A3 — другие Направления опциями этого. Показываем ТОЛЬКО
            // стоящие выше по списку: порядок эмиссии исключает циклы, а
            // ссылка вниз была бы forward-ref, который ядро не принимает.
            // У самого верхнего Направления кандидатов нет → подсекции нет.
            ...(_includeSection(cs)),
            const SizedBox(height: 12),

            // ── Блок 2: ПОВЕДЕНИЕ. Роль самого Направления (detour-мишень) и
            // что происходит с живыми соединениями при переключении — другая
            // ось, чем состав, поэтому отдельной секцией.
            _sectionHeader(theme, getLocalText.s("Behavior"),
                getLocalText.s("how this direction acts when used")),
            // §248/§274 — detour-флаг = разрешение выбирать Направление как
            // detour-мишень; роль в правилах ортогональна. vpn-1 — главный
            // Направление и heal-резерв, detour для него запрещён → галку не
            // показываем вовсе. Include block с detour совместим (§274 снял
            // запрет Q1).
            if (!c.isRequired)
              CheckboxListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                visualDensity: VisualDensity.compact,
                title: Text(getLocalText.s("Use as detour"),
                    style: const TextStyle(fontSize: 14)),
                subtitle: Text(getLocalText.s("can be picked as a detour target for servers and folders"),
                    style: const TextStyle(fontSize: 11)),
                value: _isDetour,
                // §274 — ⚙ живёт в самом label: переименовываем поле СРАЗУ,
                // не дожидаясь Save (нормализация в _snapshot/copyWith —
                // страховка). Пустой label не трогаем: display-фолбэк на tag.
                onChanged: (v) => setState(() {
                  _isDetour = v ?? false;
                  _labelCtrl.text = Direction.normalizeLabel(
                      _labelCtrl.text.trim(), _isDetour);
                }),
              ),
            CheckboxListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              visualDensity: VisualDensity.compact,
              title: Text(getLocalText.s("Interrupt connections on switch"),
                  style: const TextStyle(fontSize: 14)),
              value: _interrupt,
              onChanged: (v) => setState(() => _interrupt = v ?? false),
            ),
            const Divider(height: 24),

            // node-filter regex + live-превью. §197 — `!`-тогл слева
            // (NegateToggle, как §048): инвертирует фильтр (ноды НЕ матчащие).
            Text(getLocalText.s("Node filter (regex)"),
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
            const SizedBox(height: 4),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: NegateToggle(
                    active: _nodeFilterInvert,
                    onToggle: () => setState(
                        () => _nodeFilterInvert = !_nodeFilterInvert),
                    tooltip: getLocalText.s("Exclude matching (invert)"),
                  ),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: TextField(
                    controller: _nodeFilterCtrl,
                    decoration: InputDecoration(
                      hintText: getLocalText.s("e.g. 🇩🇪|🇳🇱 — empty = all nodes"),
                      border: const OutlineInputBorder(),
                      isDense: true,
                      errorText: nodeFilterValid ? null : 'Invalid regex',
                      errorStyle: const TextStyle(fontSize: 10),
                    ),
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            _previewLine(
              cs,
              widget.allNodeTags.isEmpty
                  ? 'No node snapshot (connect to preview)'
                  : '${_nodeFilterInvert ? "excluded → " : ""}matched: '
                      '${matchedNodes.length} / ${widget.allNodeTags.length} nodes',
            ),
            const SizedBox(height: 16),

            // default-filter regex + live-превью
            Text(getLocalText.s("Default (regex)"),
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
            const SizedBox(height: 4),
            TextField(
              controller: _defaultFilterCtrl,
              decoration: InputDecoration(
                hintText: getLocalText.s("first matching node becomes default"),
                border: const OutlineInputBorder(),
                isDense: true,
                errorText: defaultValid ? null : 'Invalid regex',
                errorStyle: const TextStyle(fontSize: 10),
              ),
              style: const TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 4),
            if (defaultText.isNotEmpty)
              _previewLine(
                cs,
                defaultPick == null
                    ? 'no match → first option used'
                    : '→ "$defaultPick"',
              ),
            const Divider(height: 24),

            // auto-двойник (urltest)
            CheckboxListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              visualDensity: VisualDensity.compact,
              title: Text(getLocalText.s("Include auto (urltest)"),
                  style: const TextStyle(fontSize: 14)),
              subtitle: Text(getLocalText.s("latency-tested twin of this direction"),
                  style: const TextStyle(fontSize: 11)),
              value: _autoEnabled,
              onChanged: (v) => setState(() => _autoEnabled = v ?? false),
            ),
            if (_autoEnabled) ...[
              const SizedBox(height: 8),
              TextField(
                controller: _autoUrlCtrl,
                decoration: InputDecoration(
                  labelText: getLocalText.s("Test URL"),
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
                style: const TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 8),
              Row(
                // §279 — выравнивание по верху: у полей разная высота helper'а
                // (у Interval он всегда есть, у Tolerance — только в round-robin),
                // дефолтный center разносил сами инпуты по высоте.
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _autoIntervalCtrl,
                      decoration: InputDecoration(
                        labelText: getLocalText.s("Interval"),
                        // l10n-exempt: duration literal, locale-independent
                        hintText: '15m',
                        // §272 — каждый цикл дайлит серверы (будит спящие
                        // туннели): большие значения экономят батарею.
                        helperText: getLocalText.s("Larger values save battery"),
                        border: const OutlineInputBorder(),
                        isDense: true,
                      ),
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _autoToleranceCtrl,
                      keyboardType: TextInputType.number,
                      // §208 — в Load balance апстрим-tolerance ядром игнорится
                      // (за гистерезис отвечает Pool tolerance) → гасим.
                      enabled: _autoMode == UrltestMode.leastTest,
                      decoration: InputDecoration(
                        labelText: getLocalText.s("Tolerance (ms)"),
                        border: const OutlineInputBorder(),
                        isDense: true,
                        helperText: _autoMode == UrltestMode.roundRobin
                            ? getLocalText.s("used in Fastest mode")
                            : null,
                        helperStyle: const TextStyle(fontSize: 10),
                      ),
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _autoIdleCtrl,
                decoration: InputDecoration(
                  labelText: getLocalText.s("Idle timeout"),
                  // l10n-exempt: duration literal, locale-independent
                  hintText: '30m',
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
                style: const TextStyle(fontSize: 13),
              ),
              // §208 — advisory: interval > idle_timeout роняет старт ядра.
              if (_intervalExceedsIdle()) ...[
                const SizedBox(height: 4),
                Row(
                  children: [
                    Icon(Icons.warning_amber_rounded,
                        size: 14, color: cs.error),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(getLocalText.s("Interval must be ≤ idle timeout"),
                          style: TextStyle(fontSize: 11, color: cs.error)),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 12),

              // §208 — режим выбора узла (Fastest = least_test / Load balance =
              // round_robin). Балансировщик-поля показываются только под Load
              // balance.
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
                selected: {_autoMode},
                showSelectedIcon: false,
                style: const ButtonStyle(
                  visualDensity: VisualDensity.compact,
                  textStyle: WidgetStatePropertyAll(TextStyle(fontSize: 12)),
                ),
                onSelectionChanged: (s) =>
                    setState(() => _autoMode = s.first),
              ),
              const SizedBox(height: 4),
              _previewLine(
                cs,
                _autoMode == UrltestMode.leastTest
                    ? 'single best server by latency'
                    : 'spread connections across a pool of servers',
              ),
              if (_autoMode == UrltestMode.roundRobin) ..._balancerControls(cs),
              const SizedBox(height: 4),

              CheckboxListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                visualDensity: VisualDensity.compact,
                title: Text(getLocalText.s("Interrupt connections on switch"),
                    style: const TextStyle(fontSize: 14)),
                value: _autoInterrupt,
                onChanged: (v) => setState(() => _autoInterrupt = v ?? false),
              ),
            ],
          ],
          ),
        ),
      ),
    );
  }

  Widget _previewLine(ColorScheme cs, String text) => Text(
        text,
        style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
      );

  /// Заголовок смысловой группы формы. Идиома проекта — та же, что в
  /// [node_settings_screen.dart] и `custom_rule_edit/widgets/section_header`:
  /// titleSmall в primary + подпись onSurfaceVariant + Divider под ними.
  /// Отступы свои: тут ListView уже даёт горизонтальный padding 16.
  Widget _sectionHeader(ThemeData theme, String title, String description) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: theme.textTheme.titleSmall?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.bold,
              ),
            ),
            Text(
              description,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const Divider(),
          ],
        ),
      );

  // ── §208 — balancer-контролы (round_robin) ──

  /// Pool size / Pool tolerance + ряд sticky-чипов. Рендерится только под
  /// Load balance.
  List<Widget> _balancerControls(ColorScheme cs) {
    final nodeCount = widget.allNodeTags.length;
    return [
      const SizedBox(height: 10),
      _previewLine(cs, '15m interval recommended for large pools'),
      const SizedBox(height: 8),
      Row(
        children: [
          Expanded(
            child: TextField(
              controller: _autoPoolCtrl,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: getLocalText.s("Pool size"),
                border: const OutlineInputBorder(),
                isDense: true,
                helperText: nodeCount > 0
                    ? getLocalText.plural("of %d nodes", nodeCount)
                    : null,
                helperStyle: const TextStyle(fontSize: 10),
              ),
              style: const TextStyle(fontSize: 13),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _autoPoolToleranceCtrl,
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
      // §208 — чипы в один ряд с горизонтальной прокруткой (не Wrap-перенос:
      // юзер просил листать лево-право). 5 ключей не влезают в узкий экран.
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
                  selected: _autoSticky.contains(k),
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  onSelected: (sel) => setState(() {
                    if (sel) {
                      _autoSticky.add(k);
                    } else {
                      _autoSticky.remove(k);
                    }
                  }),
                ),
              ),
          ],
        ),
      ),
      const SizedBox(height: 2),
      _previewLine(
        cs,
        _autoSticky.isEmpty
            ? 'none selected → no stickiness (pure rotation)'
            : 'sessions stick to a server by the selected keys',
      ),
    ];
  }

  /// Человекочитаемый лейбл sticky-ключа (wire — snake_case, в UI — пробелы).
  static String _stickyLabel(StickyHashKey k) {
    switch (k) {
      case StickyHashKey.process:
        return 'process';
      case StickyHashKey.domain:
        return 'domain';
      case StickyHashKey.sourceIp:
        return 'source ip';
      case StickyHashKey.destIp:
        return 'dest ip';
      case StickyHashKey.destPort:
        return 'dest port';
    }
  }

  /// §208 — advisory: interval > idle_timeout (ядро роняет старт). true →
  /// показываем предупреждение. Обе строки парсимы и interval строго больше.
  bool _intervalExceedsIdle() {
    final iv = _parseDuration(_autoIntervalCtrl.text.trim());
    final idle = _parseDuration(_autoIdleCtrl.text.trim());
    if (iv == null || idle == null) return false; // непарсимо → не мешаем
    return iv > idle;
  }

  /// Минимальный парсер duration (`90s`/`5m`/`2h`/`1h30m` — простые суффиксы) →
  /// секунды. null если не распознано. Не претендует на полноту Go time.Duration
  /// — только для advisory-сравнения interval≤idle.
  static int? _parseDuration(String s) {
    if (s.isEmpty) return null;
    final re = RegExp(r'(\d+)\s*([smhd])', caseSensitive: false);
    final matches = re.allMatches(s);
    if (matches.isEmpty) return null;
    var total = 0;
    for (final m in matches) {
      final n = int.tryParse(m.group(1)!);
      if (n == null) return null;
      switch (m.group(2)!.toLowerCase()) {
        case 's':
          total += n;
          break;
        case 'm':
          total += n * 60;
          break;
        case 'h':
          total += n * 3600;
          break;
        case 'd':
          total += n * 86400;
          break;
      }
    }
    return total;
  }

  static String? _firstMatch(List<String> tags, RegExp re) {
    for (final t in tags) {
      if (re.hasMatch(t)) return t;
    }
    return null;
  }
}

/// Результат редактора: saved (с обновлённым Направлением) или deleted.
class DirectionEditResult {
  const DirectionEditResult._({this.saved, this.wasDeleted = false});
  final Direction? saved;
  final bool wasDeleted;

  factory DirectionEditResult.saved(Direction direction) =>
      DirectionEditResult._(saved: direction);
  factory DirectionEditResult.deleted() =>
      const DirectionEditResult._(wasDeleted: true);
}

/// Открывает редактор Направления. Возвращает null если юзер ушёл без изменений.
Future<DirectionEditResult?> openDirectionEditor(
  BuildContext context, {
  required Direction initial,
  required bool canDelete,
  required List<String> allNodeTags,
  List<Direction> directionsAbove = const [],
}) =>
    Navigator.push<DirectionEditResult>(
      context,
      MaterialPageRoute(
        builder: (_) => DirectionEditScreen(
          initial: initial,
          canDelete: canDelete,
          allNodeTags: allNodeTags,
          directionsAbove: directionsAbove,
        ),
      ),
    );
