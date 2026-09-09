import 'dart:async';

import 'package:flutter/material.dart';

import '../../../controllers/subscription_controller.dart';
import '../../../models/import_rule.dart';
import '../../../models/node_spec.dart';
import '../../../models/server_list.dart';
import '../../../services/l10n/locale_controller.dart';
import '../../../services/subscription/import_rules.dart';
import '../../../widgets/safe_bottom.dart';

/// §302 — «Filters» tab: per-subscription import-rules (REPLACE + DISABLE +
/// ENABLE §332),
/// применяемые к телу подписки на импорте/обновлении. CRUD + drag-reorder +
/// общий тумблер набора. Правила вступают в силу на следующем refresh —
/// после каждой правки показываем snackbar с кнопкой Refresh, а редактор
/// правила даёт живой предпросмотр эффекта на тестовой строке.
///
/// Самодостаточна (как Source-tab): читает правила из `entry.list`, мутирует
/// через `entry.updateImportRules` / `entry.importRulesEnabled` и persist'ит
/// через `controller.persistSources()`. Слушает `entry` (ChangeNotifier),
/// чтобы фоновый refresh/rename не рассинхронил список.
class SubscriptionFiltersTab extends StatefulWidget {
  const SubscriptionFiltersTab({
    super.key,
    required this.entry,
    required this.controller,
  });

  final SubscriptionEntry entry;
  final SubscriptionController controller;

  @override
  State<SubscriptionFiltersTab> createState() => _SubscriptionFiltersTabState();
}

class _SubscriptionFiltersTabState extends State<SubscriptionFiltersTab> {
  SubscriptionServers? get _sub {
    final l = widget.entry.list;
    return l is SubscriptionServers ? l : null;
  }

  List<ImportRule> get _rules => _sub?.importRules ?? const [];
  bool get _setEnabled => _sub?.importRulesEnabled ?? true;

  void _persist() => unawaited(widget.controller.persistSources());

  /// Идёт применение (перезагрузка тела подписки) — блокирует кнопку Apply
  /// и показывает прогресс, чтобы двойной тап не запускал два фетча.
  bool _applying = false;

  /// Есть несохранённый эффект: правила правились после последнего применения.
  /// Подсвечивает кнопку Apply (filled вместо tonal) — визуальный намёк
  /// «нажми, чтобы увидеть результат».
  bool _dirty = false;

  /// Применить правила = перезагрузить тело подписки. Правила работают на
  /// этапе загрузки (decode → applyImportRules → parseAll), поэтому применить
  /// «на месте», не обращаясь к источнику, архитектурно невозможно: уже
  /// разобранные NodeSpec задним числом не переписываются. Тот же путь, что
  /// кнопка обновления в AppBar (`updateAt`).
  Future<void> _applyNow() async {
    if (_applying) return;
    final idx = widget.controller.entries.indexOf(widget.entry);
    if (idx < 0) return;
    setState(() => _applying = true);
    try {
      await widget.controller.updateAt(idx);
    } finally {
      if (mounted) {
        setState(() {
          _applying = false;
          _dirty = false;
        });
        _showApplyResult();
      }
    }
  }

  /// Итог применения — сколько нод пришло и сколько из них выключено
  /// правилами/вручную. Отвечает на «сработало или нет» без ухода на вкладку
  /// Nodes.
  void _showApplyResult() {
    final sub = _sub;
    if (sub == null) return;
    final total = sub.nodes.length;
    final disabled = sub.disabledHashes.length;
    final messenger = ScaffoldMessenger.of(context);
    messenger.clearSnackBars();
    messenger.showSnackBar(
      SnackBar(
        content: Text(disabled > 0
            ? getLocalText
                .s("Applied — %1\$d nodes, %2\$d disabled")
                .replaceAll(r'%1$d', '$total')
                .replaceAll(r'%2$d', '$disabled')
            : getLocalText
                .s("Applied — %d nodes")
                .replaceAll('%d', '$total')),
        duration: const Duration(seconds: 4),
      ),
    );
  }

  /// Правила меняются — существующие ноды не переразбираются задним числом.
  /// Помечаем набор «грязным» (кнопка Apply подсвечивается) и показываем
  /// snackbar с быстрым Apply — чтобы «когда сработает» было очевидно.
  void _notifyChanged() {
    if (!mounted) return;
    setState(() => _dirty = true);
    if (!_setEnabled) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.clearSnackBars();
    messenger.showSnackBar(
      SnackBar(
        content: Text(getLocalText.s(
            "Rules changed. Refresh the subscription to apply them.")),
        duration: const Duration(seconds: 6),
        action: SnackBarAction(
          label: getLocalText.s("Apply"),
          onPressed: () {
            unawaited(_applyNow());
          },
        ),
      ),
    );
  }

  Future<void> _addRule() async {
    final rule = await _openRuleEditor(null);
    if (rule == null) return;
    widget.entry.updateImportRules([..._rules, rule]);
    _persist();
    setState(() {});
    _notifyChanged();
  }

  Future<void> _editRuleAt(int i) async {
    if (i < 0 || i >= _rules.length) return;
    final rule = await _openRuleEditor(_rules[i]);
    if (rule == null) return;
    final next = [..._rules]..[i] = rule;
    widget.entry.updateImportRules(next);
    _persist();
    setState(() {});
    _notifyChanged();
  }

  void _deleteRuleAt(int i) {
    if (i < 0 || i >= _rules.length) return;
    final next = [..._rules]..removeAt(i);
    widget.entry.updateImportRules(next);
    _persist();
    setState(() {});
    _notifyChanged();
  }

  void _toggleRuleAt(int i, bool enabled) {
    if (i < 0 || i >= _rules.length) return;
    final next = [..._rules]..[i] = _rules[i].copyWith(enabled: enabled);
    widget.entry.updateImportRules(next);
    _persist();
    setState(() {});
    _notifyChanged();
  }

  /// Вызывается из `onReorderItem`: newIndex уже нормализован под удалённый
  /// элемент, ручной сдвиг «-1 при move вниз» не нужен.
  void _reorder(int oldIndex, int newIndex) {
    final next = [..._rules];
    final moved = next.removeAt(oldIndex);
    next.insert(newIndex, moved);
    widget.entry.updateImportRules(next);
    _persist();
    setState(() {});
    _notifyChanged();
  }

  /// Открывает полноэкранный редактор правила (add/edit). Возвращает
  /// `ImportRule` или `null` (отмена/системный back).
  Future<ImportRule?> _openRuleEditor(ImportRule? initial) {
    return Navigator.of(context).push<ImportRule>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => _RuleEditorScreen(
          initial: initial,
          nodes: _sub?.nodes ?? const [],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (_sub == null) {
      return Center(child: Text(getLocalText.s("No nodes found")));
    }
    final rules = _rules;
    return Column(
      children: [
        Expanded(child: _body(context, rules, theme)),
        _bottomBar(context, theme),
      ],
    );
  }

  /// Нижняя панель: «Apply rules» (перезагрузка тела подписки) + «Add rule».
  /// Закреплена под списком — обе кнопки всегда на виду и ничего не
  /// перекрывают (раньше FAB висел поверх последнего правила).
  Widget _bottomBar(BuildContext context, ThemeData theme) {
    final applyLabel = _applying
        ? getLocalText.s("Applying…")
        : getLocalText.s("Apply rules");
    return Material(
      elevation: 8,
      color: theme.colorScheme.surface,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: Row(
            children: [
              Expanded(
                child: _dirty
                    ? FilledButton.icon(
                        onPressed: _applying ? null : _applyNow,
                        icon: _applyIcon(theme, onPrimary: true),
                        label: Text(applyLabel),
                      )
                    : FilledButton.tonalIcon(
                        onPressed: _applying ? null : _applyNow,
                        icon: _applyIcon(theme, onPrimary: false),
                        label: Text(applyLabel),
                      ),
              ),
              const SizedBox(width: 8),
              IconButton.filledTonal(
                onPressed: _applying ? null : _addRule,
                icon: const Icon(Icons.add),
                tooltip: getLocalText.s("Add rule"),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _applyIcon(ThemeData theme, {required bool onPrimary}) {
    if (!_applying) return const Icon(Icons.play_arrow);
    return SizedBox(
      width: 16,
      height: 16,
      child: CircularProgressIndicator(
        strokeWidth: 2,
        color: onPrimary
            ? theme.colorScheme.onPrimary
            : theme.colorScheme.onSecondaryContainer,
      ),
    );
  }

  Widget _body(BuildContext context, List<ImportRule> rules, ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Общий тумблер набора.
        SwitchListTile(
          value: _setEnabled,
          onChanged: (v) {
            widget.entry.importRulesEnabled = v;
            _persist();
            setState(() {});
            _notifyChanged();
          },
          title: Text(getLocalText.s("Enable import rules")),
          subtitle: Text(getLocalText.s(
              "Rewrite or disable nodes when the subscription is imported")),
        ),
        const Divider(height: 1),
        // Правила применяются на импорте — существующие ноды не меняются
        // задним числом. Подсказываем, что нужно обновить.
        Container(
          width: double.infinity,
          color: theme.colorScheme.surfaceContainerHighest,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              Icon(Icons.info_outline,
                  size: 16, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  getLocalText.s(
                      "Rules run when the subscription body is loaded. Tap Apply rules to reload it now."),
                  style: TextStyle(
                      fontSize: 12, color: theme.colorScheme.onSurfaceVariant),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: rules.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      getLocalText.s(
                          "No rules yet. Add one to fix broken params or hide nodes."),
                      textAlign: TextAlign.center,
                      style:
                          TextStyle(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ),
                )
              : ReorderableListView.builder(
                  // Нижний отступ под FAB больше не нужен — кнопки уехали в
                  // закреплённую панель под списком.
                  padding: EdgeInsets.zero, // bottom-inset: handled — ниже bottom bar с SafeArea
                  itemCount: rules.length,
                  onReorderItem: _reorder,
                  itemBuilder: (context, i) =>
                      _ruleTile(context, rules[i], i, key: ValueKey('rule-$i')),
                ),
        ),
      ],
    );
  }

  Widget _ruleTile(BuildContext context, ImportRule rule, int i,
      {required Key key}) {
    final theme = Theme.of(context);
    final invalid =
        rule.enabled && rule.conditions.isNotEmpty && !rule.isUsable;
    final isReplace = rule.action == ImportRuleAction.replace;
    // Цвет бейджа действия: Replace — синий, Disable — оранжевый,
    // Enable (§332) — зелёный.
    final badgeColor = switch (rule.action) {
      ImportRuleAction.replace => Colors.blue,
      ImportRuleAction.disable => Colors.orange,
      ImportRuleAction.enable => Colors.green,
    };
    final badgeText = switch (rule.action) {
      ImportRuleAction.replace => getLocalText.s("Replace"),
      ImportRuleAction.disable => getLocalText.s("Disable"),
      ImportRuleAction.enable => getLocalText.s("Enable"),
    };
    // Сводка условий: «tag contains ⚡», несколько — через AND/OR.
    final condText = rule.conditions.isEmpty
        ? getLocalText.s("(no conditions)")
        : rule.conditions
            .map((c) =>
                '${c.path.isEmpty ? '*' : c.path} ${c.negate ? '!' : ''}${c.op.name} ${c.pattern}')
            .join(rule.matchMode == ImportRuleMatchMode.all
                ? '  AND  '
                : '  OR  ');
    return ListTile(
      key: key,
      leading: Switch(
        value: rule.enabled,
        onChanged: (v) => _toggleRuleAt(i, v),
      ),
      title: Row(
        children: [
          // Бейдж действия.
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: badgeColor.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              badgeText,
              style: TextStyle(fontSize: 10, color: badgeColor),
            ),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              condText,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ),
        ],
      ),
      subtitle: Text(
        [
          if (isReplace)
            // Пустая цель = замена по всему узлу, показываем как `*` (§307).
            '${rule.targetPath.isEmpty ? '*' : rule.targetPath} = ${rule.replacement.isEmpty ? getLocalText.s("(remove)") : rule.replacement}',
          if (invalid) getLocalText.s("invalid pattern — skipped"),
        ].join('  ·  '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontFamily: isReplace ? 'monospace' : null,
          fontSize: 11,
          color: invalid
              ? theme.colorScheme.error
              : theme.colorScheme.onSurfaceVariant,
        ),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.delete_outline, size: 20),
            tooltip: getLocalText.s("Delete"),
            onPressed: () => _deleteRuleAt(i),
          ),
          ReorderableDragStartListener(
            index: i,
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 4),
              child: Icon(Icons.drag_handle, size: 20),
            ),
          ),
        ],
      ),
      onTap: () => _editRuleAt(i),
    );
  }
}

/// §302 — полноэкранный редактор одного правила (add/edit). Возвращает
/// `ImportRule` через `Navigator.pop` или `null` (Cancel/системный back).
///
/// Правило: условия (`путь оператор паттерн`, объединённые AND/OR) → действие
/// (Disable либо Replace `путь = значение`). Работает над готовым JSON узла
/// (`NodeSpec.emit`), поэтому пути одинаковы для всех форматов подписки.
///
/// Вкладка «Matches» прогоняет правило по узлам подписки тем же движком, что
/// и импорт (`applyRulesToNode`) — предпросмотр совпадает с результатом.
class _RuleEditorScreen extends StatefulWidget {
  const _RuleEditorScreen({this.initial, this.nodes = const []});

  final ImportRule? initial;

  /// Узлы подписки — для предпросмотра и подсказок по путям.
  final List<NodeSpec> nodes;

  @override
  State<_RuleEditorScreen> createState() => _RuleEditorScreenState();
}

class _RuleEditorScreenState extends State<_RuleEditorScreen> {
  late List<_CondDraft> _conds;
  late ImportRuleMatchMode _matchMode;
  late ImportRuleAction _action;
  late TextEditingController _targetPath;
  late TextEditingController _replacement;
  late TextEditingController _substitute;
  late ImportRuleReplaceMode _replaceMode;

  @override
  void initState() {
    super.initState();
    final r = widget.initial;
    _conds = [
      for (final c in r?.conditions ?? const <ImportRuleCondition>[])
        _CondDraft.from(c, _onChanged),
    ];
    if (_conds.isEmpty) _conds.add(_CondDraft.empty(_onChanged));
    _matchMode = r?.matchMode ?? ImportRuleMatchMode.all;
    _action = r?.action ?? ImportRuleAction.disable;
    _targetPath = TextEditingController(text: r?.targetPath ?? '')
      ..addListener(_onChanged);
    _replacement = TextEditingController(text: r?.replacement ?? '')
      ..addListener(_onChanged);
    _substitute = TextEditingController(text: r?.substitutePattern ?? '')
      ..addListener(_onChanged);
    _replaceMode = r?.replaceMode ?? ImportRuleReplaceMode.set;
  }

  void _onChanged() => setState(() {});

  @override
  void dispose() {
    for (final c in _conds) {
      c.dispose();
    }
    _targetPath.dispose();
    _replacement.dispose();
    _substitute.dispose();
    super.dispose();
  }

  ImportRule _current() => ImportRule(
        conditions: [for (final c in _conds) c.toCondition()],
        matchMode: _matchMode,
        action: _action,
        targetPath:
            _action == ImportRuleAction.replace ? _targetPath.text.trim() : '',
        replacement:
            _action == ImportRuleAction.replace ? _replacement.text : '',
        replaceMode: _replaceMode,
        substitutePattern:
            _replaceMode == ImportRuleReplaceMode.substitute
                ? _substitute.text
                : '',
        enabled: widget.initial?.enabled ?? true,
      );

  /// null = сохранять можно; иначе причина, по которой Save заблокирован.
  String? get _saveBlocker {
    final rule = _current();
    // Условие определяется паттерном, а не путём: пустой путь = поиск по
    // всему JSON узла (валидный сценарий «не знаю, в каком поле искать»).
    if (!rule.conditions.any((c) => c.pattern.isNotEmpty)) {
      return getLocalText.s("Add at least one condition");
    }
    for (final c in rule.conditions) {
      if (c.pattern.isEmpty && c.path.isEmpty) continue;
      if (c.pattern.isEmpty) return getLocalText.s("Condition needs a value");
      if (c.op == ImportRuleOperator.matches && c.compiledPattern == null) {
        return getLocalText.s("Invalid regular expression");
      }
    }
    if (rule.action == ImportRuleAction.replace && rule.targetPath.isEmpty) {
      // §307 — пустая цель валидна в substitute: замена по всему узлу.
      // «Set whole value» с пустой целью затирал бы весь узел — запрещено.
      if (rule.replaceMode != ImportRuleReplaceMode.substitute) {
        return getLocalText.s("Set whole value needs a target path");
      }
      final hasNeedle = rule.substitutePattern.isNotEmpty ||
          rule.conditions.any((c) => c.path.isEmpty && c.pattern.isNotEmpty);
      if (!hasNeedle) {
        return getLocalText.s("Whole-node replace needs a pattern to find");
      }
    }
    return null;
  }

  void _save() {
    if (_saveBlocker != null) return;
    Navigator.of(context).pop(_current());
  }

  @override
  Widget build(BuildContext context) {
    final blocker = _saveBlocker;
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.close),
            tooltip: getLocalText.s("Cancel"),
            onPressed: () => Navigator.of(context).pop(),
          ),
          title: Text(widget.initial == null
              ? getLocalText.s("Add rule")
              : getLocalText.s("Edit rule")),
          actions: [
            TextButton(
              onPressed: blocker != null ? null : _save,
              child: Text(getLocalText.s("Save")),
            ),
          ],
          bottom: TabBar(
            tabs: [
              Tab(text: getLocalText.s("Rule")),
              Tab(text: getLocalText.s("Matches")),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _ruleForm(context, blocker),
            _matchesTab(context),
          ],
        ),
      ),
    );
  }

  Widget _ruleForm(BuildContext context, String? blocker) {
    final theme = Theme.of(context);
    final isReplace = _action == ImportRuleAction.replace;
    return ListView(
      padding: const EdgeInsets.all(16).withSafeBottom(context),
      children: [
        // ─── Условия ───────────────────────────────────────────────────────
        Row(
          children: [
            Text(getLocalText.s("Conditions"),
                style: theme.textTheme.titleSmall),
            const Spacer(),
            if (_conds.length > 1)
              SegmentedButton<ImportRuleMatchMode>(
                style: const ButtonStyle(visualDensity: VisualDensity.compact),
                segments: [
                  ButtonSegment(
                    value: ImportRuleMatchMode.all,
                    label: Text(getLocalText.s("AND")),
                  ),
                  ButtonSegment(
                    value: ImportRuleMatchMode.any,
                    label: Text(getLocalText.s("OR")),
                  ),
                ],
                selected: {_matchMode},
                onSelectionChanged: (s) =>
                    setState(() => _matchMode = s.first),
              ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          getLocalText.s(
              "Paths point into the node JSON: tag, server, tls.utls.fingerprint. Leave a path empty to search the whole node."),
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 8),
        for (var i = 0; i < _conds.length; i++)
          _conditionCard(context, i),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () =>
                setState(() => _conds.add(_CondDraft.empty(_onChanged))),
            icon: const Icon(Icons.add, size: 18),
            label: Text(getLocalText.s("Add condition")),
          ),
        ),

        const Divider(height: 32),

        // ─── Действие ──────────────────────────────────────────────────────
        Text(getLocalText.s("Action"), style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        SegmentedButton<ImportRuleAction>(
          segments: [
            ButtonSegment(
              value: ImportRuleAction.disable,
              label: Text(getLocalText.s("Disable")),
              icon: const Icon(Icons.block, size: 18),
            ),
            // §332 — Enable: снять disable-отметку (включая ручную).
            ButtonSegment(
              value: ImportRuleAction.enable,
              label: Text(getLocalText.s("Enable")),
              icon: const Icon(Icons.check_circle_outline, size: 18),
            ),
            ButtonSegment(
              value: ImportRuleAction.replace,
              label: Text(getLocalText.s("Replace")),
              icon: const Icon(Icons.find_replace, size: 18),
            ),
          ],
          selected: {_action},
          onSelectionChanged: (s) => setState(() => _action = s.first),
        ),
        const SizedBox(height: 8),
        Text(
          switch (_action) {
            ImportRuleAction.replace =>
              getLocalText.s("Writes a new value into the matching nodes."),
            ImportRuleAction.disable => getLocalText.s(
                "Hides matching nodes from routing. They stay visible, struck through."),
            // §332 — правила последовательные: Enable первым в списке
            // сбрасывает прошлые отключения перед новыми Disable-правилами.
            ImportRuleAction.enable => getLocalText.s(
                "Re-enables matching nodes, clearing disable marks from rules and manual toggles. Later rules can still disable them."),
          },
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),

        if (isReplace) ...[
          const SizedBox(height: 16),
          TextField(
            controller: _targetPath,
            style: const TextStyle(fontFamily: 'monospace'),
            decoration: InputDecoration(
              labelText: getLocalText.s("Target path"),
              hintText: 'tls.utls.fingerprint', // l10n-exempt: JSON path example
              // §307 — пустая цель = substitute по всему узлу.
              helperText: _replaceMode == ImportRuleReplaceMode.substitute
                  ? getLocalText
                      .s("Leave empty to substitute across the whole node")
                  : null,
              border: const OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 12),
          SegmentedButton<ImportRuleReplaceMode>(
            segments: [
              ButtonSegment(
                value: ImportRuleReplaceMode.set,
                label: Text(getLocalText.s("Set whole value")),
              ),
              ButtonSegment(
                value: ImportRuleReplaceMode.substitute,
                label: Text(getLocalText.s("Substitute part")),
              ),
            ],
            selected: {_replaceMode},
            onSelectionChanged: (s) => setState(() => _replaceMode = s.first),
          ),
          if (_replaceMode == ImportRuleReplaceMode.substitute) ...[
            const SizedBox(height: 12),
            TextField(
              controller: _substitute,
              style: const TextStyle(fontFamily: 'monospace'),
              decoration: InputDecoration(
                labelText: getLocalText.s("Find inside the value"),
                helperText:
                    getLocalText.s("Empty reuses the condition pattern"),
                border: const OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ],
          const SizedBox(height: 12),
          TextField(
            controller: _replacement,
            style: const TextStyle(fontFamily: 'monospace'),
            decoration: InputDecoration(
              labelText: getLocalText.s("New value"),
              hintText: 'chrome', // l10n-exempt: uTLS fingerprint value
              helperText: getLocalText.s(r"Use $1, $2 for regex capture groups"),
              border: const OutlineInputBorder(),
              isDense: true,
            ),
          ),
        ],

        if (blocker != null) ...[
          const SizedBox(height: 16),
          Row(
            children: [
              Icon(Icons.error_outline,
                  size: 16, color: theme.colorScheme.error),
              const SizedBox(width: 6),
              Expanded(
                child: Text(blocker,
                    style: TextStyle(
                        fontSize: 12, color: theme.colorScheme.error)),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _conditionCard(BuildContext context, int i) {
    final theme = Theme.of(context);
    final c = _conds[i];
    final badRegex = c.op == ImportRuleOperator.matches &&
        c.pattern.text.isNotEmpty &&
        c.toCondition().compiledPattern == null;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 4, 12),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: c.path,
                    style: const TextStyle(fontFamily: 'monospace'),
                    decoration: InputDecoration(
                      labelText: getLocalText.s("Path"),
                      // Пусто — валидный ввод: ищем по всему узлу.
                      hintText: getLocalText.s("whole node"),
                      border: const OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
                if (_conds.length > 1)
                  IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    tooltip: getLocalText.s("Delete"),
                    onPressed: () => setState(() {
                      _conds.removeAt(i).dispose();
                    }),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  flex: 4,
                  child: DropdownButtonFormField<ImportRuleOperator>(
                    initialValue: c.op,
                    isDense: true,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      isDense: true,
                      contentPadding:
                          EdgeInsets.symmetric(horizontal: 8, vertical: 12),
                    ),
                    items: [
                      DropdownMenuItem(
                        value: ImportRuleOperator.contains,
                        child: Text(getLocalText.s("contains")),
                      ),
                      DropdownMenuItem(
                        value: ImportRuleOperator.equals,
                        child: Text(getLocalText.s("equals")),
                      ),
                      DropdownMenuItem(
                        value: ImportRuleOperator.matches,
                        child: Text(getLocalText.s("matches")),
                      ),
                    ],
                    onChanged: (v) => setState(
                        () => c.op = v ?? ImportRuleOperator.contains),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 6,
                  child: TextField(
                    controller: c.pattern,
                    style: const TextStyle(fontFamily: 'monospace'),
                    decoration: InputDecoration(
                      labelText: getLocalText.s("Value"),
                      errorText: badRegex
                          ? getLocalText.s("Invalid regular expression")
                          : null,
                      border: const OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
              ],
            ),
            Row(
              children: [
                Expanded(
                  child: CheckboxListTile(
                    value: c.negate,
                    onChanged: (v) => setState(() => c.negate = v ?? false),
                    controlAffinity: ListTileControlAffinity.leading,
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: Text(getLocalText.s("Not"),
                        style: const TextStyle(fontSize: 12)),
                  ),
                ),
                Expanded(
                  child: CheckboxListTile(
                    value: c.caseSensitive,
                    onChanged: (v) =>
                        setState(() => c.caseSensitive = v ?? false),
                    controlAffinity: ListTileControlAffinity.leading,
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: Text(getLocalText.s("Case-sensitive"),
                        style: const TextStyle(fontSize: 12)),
                  ),
                ),
              ],
            ),
            if (c.op == ImportRuleOperator.matches)
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  getLocalText
                      .s(r"Capture groups are available as $1, $2 in Replace"),
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// Вкладка «Matches» — прогон правила по узлам подписки ТЕМ ЖЕ движком, что
  /// и импорт: что показано здесь, то и произойдёт при Apply.
  Widget _matchesTab(BuildContext context) {
    final theme = Theme.of(context);
    final nodes = widget.nodes;
    if (nodes.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            getLocalText.s("No nodes loaded yet. Apply rules to load them."),
            textAlign: TextAlign.center,
            style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
      );
    }

    final rule = _current();
    if (!rule.isUsable) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            getLocalText.s("Finish the rule to see what it matches."),
            textAlign: TextAlign.center,
            style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
      );
    }

    final hits = <(NodeSpec, NodeRuleOutcome)>[];
    for (final n in nodes) {
      final outcome = applyRulesToNode(n, [rule]);
      if (outcome.changed) hits.add((n, outcome));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          color: theme.colorScheme.surfaceContainerHighest,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              Icon(
                hits.isEmpty
                    ? Icons.remove_circle_outline
                    : Icons.check_circle_outline,
                size: 18,
                color: hits.isEmpty
                    ? theme.colorScheme.outline
                    : theme.colorScheme.primary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  getLocalText
                      .s("%1\$d of %2\$d nodes match")
                      .replaceAll(r'%1$d', '${hits.length}')
                      .replaceAll(r'%2$d', '${nodes.length}'),
                  style: theme.textTheme.bodyMedium,
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: hits.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      getLocalText.s(
                          "No nodes match. Check the path against a node's JSON."),
                      textAlign: TextAlign.center,
                      style:
                          TextStyle(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ),
                )
              : ListView.separated(
                  itemCount: hits.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final (node, outcome) = hits[i];
                    final title =
                        node.label.isNotEmpty ? node.label : node.tag;
                    // §332 — тристейт: true=Disable, false=Enable, null=Replace
                    // (в превью одного правила ровно одно из трёх).
                    final (icon, color, subtitle) = switch (outcome.disabled) {
                      true => (
                          Icons.block,
                          Colors.orange,
                          getLocalText.s("Will be disabled"),
                        ),
                      false => (
                          Icons.check_circle_outline,
                          Colors.green,
                          getLocalText.s("Will be enabled"),
                        ),
                      null => (
                          Icons.find_replace,
                          Colors.blue,
                          outcome.replacements.join('\n'),
                        ),
                    };
                    return ListTile(
                      dense: true,
                      leading: Icon(icon, size: 20, color: color),
                      title: Text(
                        title.isEmpty ? node.server : title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        subtitle,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily:
                              outcome.disabled == null ? 'monospace' : null,
                          fontSize: 11,
                          color: outcome.disabled == null
                              ? theme.colorScheme.onSurfaceVariant
                              : color,
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

/// Черновик условия в редакторе: контроллеры полей + не-текстовые флаги.
class _CondDraft {
  final TextEditingController path;
  final TextEditingController pattern;
  ImportRuleOperator op;
  bool negate;
  bool caseSensitive;

  _CondDraft({
    required this.path,
    required this.pattern,
    required this.op,
    required this.negate,
    required this.caseSensitive,
  });

  factory _CondDraft.empty(VoidCallback onChanged) => _CondDraft(
        path: TextEditingController()..addListener(onChanged),
        pattern: TextEditingController()..addListener(onChanged),
        op: ImportRuleOperator.contains,
        negate: false,
        caseSensitive: false,
      );

  factory _CondDraft.from(ImportRuleCondition c, VoidCallback onChanged) =>
      _CondDraft(
        path: TextEditingController(text: c.path)..addListener(onChanged),
        pattern: TextEditingController(text: c.pattern)..addListener(onChanged),
        op: c.op,
        negate: c.negate,
        caseSensitive: c.caseSensitive,
      );

  ImportRuleCondition toCondition() => ImportRuleCondition(
        path: path.text.trim(),
        op: op,
        pattern: pattern.text,
        negate: negate,
        caseSensitive: caseSensitive,
      );

  void dispose() {
    path.dispose();
    pattern.dispose();
  }
}
