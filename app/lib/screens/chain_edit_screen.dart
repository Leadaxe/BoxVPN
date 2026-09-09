// §393 C7 — экран правки цепочки хопов (SPEC 110).
//
// Эталон UX — вкладка «Цепочка» лаунчера (`ui/configurator/tabs/
// source_chain_tab.go` + `source_chain_hops.go`), идиома экрана — проектная
// ([direction_edit_screen.dart]): Navigator.push, PopScope back-guard
// (Save/Keep/Discard), AppBar delete/save.
//
// ПОРЯДОК ПОЗИЦИЙ ПОДПИСАН СВЕРХУ, и это не украшение. `chain` читается в
// порядке ПАКЕТА (первая позиция — от вас), а `detour` — наоборот, «кто через
// кого». Это единственное различие между двумя механизмами при чтении и
// единственное, в чём легко ошибиться (SPEC 110 T3): перепутав их, соберёшь
// РАБОТАЮЩИЙ, но не тот маршрут — ошибку, которую пользователь заметит только
// по геолокации.
//
// ФОРМА — ЕДИНСТВЕННЫЙ РУБЕЖ (§393 L4): `sing-box check` ошибки старта не
// ловит. Поэтому сохранение заперто, пока есть блокирующая находка
// [validateChainForm], — собрать конфиг, на котором ядро не стартует, отсюда
// нельзя.
//
// Позиции вписываются ТОЛЬКО выбором из существующих целей (как участники
// группы и detour-мишень): опечатка в теге — это ссылка в никуда, на которой
// ядро не стартует вовсе.

import 'package:flutter/material.dart';

import '../models/config_node.dart';
import '../models/direction.dart';
import '../models/source_chain.dart';
import '../services/l10n/locale_controller.dart';
import '../services/ui_helpers.dart';
import '../widgets/reorder_grab_strip.dart';
import 'chain_edit/chain_form_validation.dart';
import 'chain_edit/chain_hop_candidate.dart';
import 'chain_edit/chain_hop_targets.dart';
import '../widgets/app_bottom_sheet.dart';

/// Результат редактора: saved (с обновлённой цепочкой) или deleted.
class ChainEditResult {
  const ChainEditResult._({this.saved, this.wasDeleted = false});

  final SourceChain? saved;
  final bool wasDeleted;

  factory ChainEditResult.saved(SourceChain chain) =>
      ChainEditResult._(saved: chain);
  factory ChainEditResult.deleted() => const ChainEditResult._(wasDeleted: true);
}

/// Открывает редактор цепочки. null — пользователь ушёл без изменений.
Future<ChainEditResult?> openChainEditor(
  BuildContext context, {
  required SourceChain initial,
  required ParsedConfig config,
  required List<Direction> directions,
  required List<SourceChain> chains,
}) =>
    Navigator.push<ChainEditResult>(
      context,
      MaterialPageRoute(
        builder: (_) => ChainEditScreen(
          initial: initial,
          config: config,
          directions: directions,
          chains: chains,
        ),
      ),
    );

class ChainEditScreen extends StatefulWidget {
  const ChainEditScreen({
    super.key,
    required this.initial,
    required this.config,
    required this.directions,
    required this.chains,
  });

  final SourceChain initial;

  /// Последний собранный конфиг — источник ОКОНЧАТЕЛЬНЫХ тегов (см.
  /// `chain_hop_targets.dart`).
  final ParsedConfig config;

  final List<Direction> directions;

  /// Весь список цепочек в порядке объявления (включая редактируемую):
  /// порядок решает, на кого можно сослаться.
  final List<SourceChain> chains;

  @override
  State<ChainEditScreen> createState() => _ChainEditScreenState();
}

class _ChainEditScreenState extends State<ChainEditScreen> with SnackHelper {
  late final TextEditingController _labelCtrl;
  late final TextEditingController _idleCtrl;

  late List<String> _hops;
  late bool _enabled;
  late bool? _stripEvasion;
  late Map<String, bool> _strip;

  /// Раскрыт ли Advanced. Свёрнут по умолчанию: цепочка из двух позиций —
  /// подавляющее большинство, и настройки звеньев ей не нужны.
  bool _advancedOpen = false;

  late List<ChainHopCandidate> _cands;
  late Map<String, ChainHopCandidate> _lookup;

  @override
  void initState() {
    super.initState();
    final c = widget.initial;
    _labelCtrl = TextEditingController(text: c.label)..addListener(_onChange);
    _idleCtrl = TextEditingController(text: c.idleTimeout)
      ..addListener(_onChange);
    _hops = [...c.hops];
    _enabled = c.enabled;
    _stripEvasion = c.stripEvasion;
    _strip = {...c.strip};
    _cands = collectChainHopTargets(
      config: widget.config,
      directions: widget.directions,
      chains: widget.chains,
      selfTag: c.tag,
    );
    _lookup = chainHopLookup(_cands);
  }

  @override
  void dispose() {
    _labelCtrl.dispose();
    _idleCtrl.dispose();
    super.dispose();
  }

  void _onChange() => setState(() {});

  SourceChain _snapshot() => widget.initial.copyWith(
        label: _labelCtrl.text.trim(),
        enabled: _enabled,
        hops: _hops,
        idleTimeout: _idleCtrl.text.trim(),
        stripEvasion: _stripEvasion,
        clearStripEvasion: _stripEvasion == null,
        strip: _strip,
      );

  bool _isDirty() {
    final s = _snapshot();
    final i = widget.initial;
    return s.label != i.label ||
        s.enabled != i.enabled ||
        s.idleTimeout != i.idleTimeout ||
        s.stripEvasion != i.stripEvasion ||
        !_sameHops(s.hops, i.hops) ||
        !_sameStrip(s.strip, i.strip);
  }

  static bool _sameHops(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static bool _sameStrip(Map<String, bool> a, Map<String, bool> b) {
    if (a.length != b.length) return false;
    for (final e in a.entries) {
      if (b[e.key] != e.value) return false;
    }
    return true;
  }

  List<ChainFormIssue> _issues() => validateChainForm(
        ChainFormState.of(_snapshot()),
        ChainFormContext(
          candidates: _lookup,
          targetsKnown: chainTargetsKnown(widget.config),
          // Тег цепочки immutable (форма его не правит), но занятым он мог
          // стать ПОСЛЕ создания — вторым источником мутаций (Debug API,
          // restore из бэкапа), пока окно открыто. Тогда сборка деградирует
          // цепочку с «имя уже занято», и узнать об этом здесь дешевле, чем
          // по факту пропавшего маршрута.
          takenTags: _takenTags(),
          originalTag: widget.initial.tag,
        ),
      );

  /// Теги, занятые кем-то ДРУГИМ: Направлениями, узлами конфига и прочими
  /// цепочками. Свой тег сюда не попадает — цепочка занимает своё же имя.
  Set<String> _takenTags() => {
        for (final d in widget.directions) d.tag,
        for (final c in widget.chains)
          if (c.tag != widget.initial.tag) c.tag,
        for (final t in widget.config.byTag.keys)
          if (t != widget.initial.tag) t,
      };

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

  /// Сохранение заперто блокирующими находками (§393 L4): цепочка, на которой
  /// ядро не стартует, отвергает конфиг ЦЕЛИКОМ — пользователь остался бы без
  /// VPN, а не без одного маршрута.
  void _save() {
    final blockers = _issues().where((i) => i.blocks).toList();
    if (blockers.isNotEmpty) {
      showSnack(blockers.first.message);
      return;
    }
    Navigator.pop(context, ChainEditResult.saved(_snapshot()));
  }

  Future<void> _delete() async {
    final confirmed = await showDeleteConfirmDialog(
      context,
      title: getLocalText.s("Delete hop chain?"),
      message: getLocalText.s(
          "Remove \"%s\"? Other chains using it as a position will stop building until you fix them.",
          widget.initial.displayLabel),
    );
    if (confirmed == true && mounted) {
      Navigator.pop(context, ChainEditResult.deleted());
    }
  }

  /// Кандидаты пересобираются на КАЖДОЕ открытие пикера: галка detour у
  /// Направления могла измениться, пока форма открыта (второе окно, Debug
  /// API) — initState-снимок протухает (полевая находка оператора 25.08).
  void _refreshCandidates() {
    _cands = collectChainHopTargets(
      config: widget.config,
      directions: widget.directions,
      chains: widget.chains,
      selfTag: widget.initial.tag,
    );
    _lookup = chainHopLookup(_cands);
  }

  Future<void> _addHop() async {
    setState(_refreshCandidates);
    final chosen = _hops.toSet();
    final options = [
      for (final c in _cands)
        if (!chosen.contains(c.tag) && c.offered) c,
    ];
    if (options.isEmpty) {
      showSnack(getLocalText.s(
          "Nothing left to add: every available target is already in the chain."));
      return;
    }
    final picked = await showAppBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      // Кандидатов у живого профиля сотни (все узлы подписок) — без потолка
      // лист накрывал весь экран. Директива оператора 24.08: не выше 3/4;
      // внутри — собственный скролл листа.
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.75,
      ),
      builder: (ctx) => _HopPickerSheet(options: options),
    );
    if (picked == null || !mounted) return;
    setState(() => _hops = [..._hops, picked]);
  }

  void _removeHop(int index) {
    setState(() {
      final next = [..._hops]..removeAt(index);
      _hops = next;
    });
  }

  /// Reorder-колбэк `ReorderableListView` (§098-идиома: grab-strip слева,
  /// как у правил роутинга/подписок). Порядок позиций — это маршрут пакета,
  /// поэтому перестановка проходит через тот же `setState`, что и
  /// добавление/удаление: дифф формы и находки пересчитываются на месте.
  ///
  /// Колбэк — `onReorderItem` (не устаревший `onReorder`): newIndex здесь уже
  /// приведён к списку БЕЗ перетаскиваемого элемента, ручной сдвиг «-1 при
  /// move вниз» не нужен.
  /// Колбэк — `onReorderItem` (не устаревший `onReorder`): newIndex здесь уже
  /// приведён к списку БЕЗ перетаскиваемого элемента, поэтому ручного сдвига
  /// «-1 при move вниз» быть не должно — с ним позиция уезжала бы мимо места,
  /// куда её отпустили. Порядок позиций и есть маршрут, так что ошибка на
  /// единицу молча поменяла бы цепочку.
  void _reorderHop(int oldIndex, int newIndex) {
    if (oldIndex == newIndex) return;
    setState(() {
      final next = [..._hops];
      final tag = next.removeAt(oldIndex);
      next.insert(newIndex, tag);
      _hops = next;
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final c = widget.initial;
    final issues = _issues();
    final canSave = chainFormCanSave(issues);
    final dirty = _isDirty();

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _handleBack();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(getLocalText.s("Hop chain · %s", c.tag)),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: _handleBack,
          ),
          actions: [
            IconButton(
              tooltip: getLocalText.s("Delete hop chain"),
              icon: Icon(Icons.delete_outline, color: cs.error),
              onPressed: _delete,
            ),
            IconButton(
              tooltip: getLocalText.s("Save"),
              icon: Icon(Icons.check,
                  color: !canSave
                      ? cs.onSurfaceVariant.withValues(alpha: 0.4)
                      : (dirty ? cs.primary : cs.onSurfaceVariant)),
              onPressed: canSave ? _save : null,
            ),
          ],
        ),
        body: ListView(
          padding: EdgeInsets.fromLTRB(
              16, 12, 16, MediaQuery.of(context).padding.bottom + 32),
          children: [
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
                hintText: getLocalText.s("optional — defaults to the tag"),
                border: const OutlineInputBorder(),
                isDense: true,
              ),
              style: const TextStyle(fontSize: 14),
            ),
            SwitchListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(getLocalText.s("Enabled"),
                  style: const TextStyle(fontSize: 14)),
              subtitle: Text(
                  getLocalText.s("A disabled chain is not built and cannot be used as a position"),
                  style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
              value: _enabled,
              onChanged: (v) => setState(() => _enabled = v),
            ),

            const SizedBox(height: 8),
            ..._issueBanners(issues, cs),

            const SizedBox(height: 8),
            Text(getLocalText.s("Positions"),
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            // Подпись порядка — единственная защита от путаницы с detour
            // (SPEC 110 T3): у одного стрелка смотрит от клиента, у другого
            // к нему.
            Text(
                getLocalText.s(
                    "In packet order: the first position is the hop closest to you, the last one is what the destination sees."),
                style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
            const SizedBox(height: 6),
            _hopsList(cs),
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _addHop,
                icon: const Icon(Icons.add, size: 18),
                label: Text(getLocalText.s("Add position")),
              ),
            ),

            const SizedBox(height: 8),
            _advancedSection(cs),
          ],
        ),
      ),
    );
  }

  List<Widget> _issueBanners(List<ChainFormIssue> issues, ColorScheme cs) {
    if (issues.isEmpty) return const [];
    return [
      for (final i in issues)
        Container(
          margin: const EdgeInsets.only(bottom: 6),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: switch (i.level) {
              ChainIssueLevel.blocking => cs.errorContainer,
              ChainIssueLevel.warning => cs.tertiaryContainer,
              ChainIssueLevel.info => cs.surfaceContainerHighest,
            },
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                switch (i.level) {
                  ChainIssueLevel.blocking => Icons.error_outline,
                  ChainIssueLevel.warning => Icons.warning_amber_outlined,
                  ChainIssueLevel.info => Icons.info_outline,
                },
                size: 18,
                color: i.level == ChainIssueLevel.blocking
                    ? cs.onErrorContainer
                    : cs.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  i.message,
                  style: TextStyle(
                    fontSize: 12,
                    color: i.level == ChainIssueLevel.blocking
                        ? cs.onErrorContainer
                        : cs.onSurface,
                  ),
                ),
              ),
            ],
          ),
        ),
    ];
  }

  Widget _hopsList(ColorScheme cs) {
    if (_hops.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(getLocalText.s("No positions yet — add at least two."),
            style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
      );
    }
    // Вложенный в скроллируемую форму список — как таб правил
    // ([routing_tabs.dart]) и список DNS-правил: shrinkWrap + отключённый
    // собственный скролл, drag-старт только с grab-strip.
    return ReorderableListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      buildDefaultDragHandles: false,
      itemCount: _hops.length,
      onReorderItem: _reorderHop,
      itemBuilder: (ctx, i) =>
          KeyedSubtree(key: ValueKey('hop-${_hops[i]}'), child: _hopTile(i, cs)),
    );
  }

  Widget _hopTile(int index, ColorScheme cs) {
    final tag = _hops[index];
    final cand = describeChainHop(tag, _lookup,
        targetsKnown: chainTargetsKnown(widget.config));
    final lost = cand.kind == ChainHopKind.unknown;
    final tile = ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: CircleAvatar(
        radius: 13,
        backgroundColor: lost ? cs.errorContainer : cs.secondaryContainer,
        child: Text('${index + 1}',
            style: TextStyle(
                fontSize: 12,
                color: lost ? cs.onErrorContainer : cs.onSecondaryContainer)),
      ),
      // Строка позиции — ТОЛЬКО тег. Позиция это ссылка на тег, и именно его
      // пользователь увидит в конфиге и в логе ядра; имя рядом удваивало бы
      // строку почти дословно.
      title: Text(tag,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
              fontSize: 13,
              fontFamily: 'monospace',
              color: lost ? cs.error : null)),
      subtitle: Text(chainHopKindText(cand.kind),
          style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
      trailing: IconButton(
        tooltip: getLocalText.s("Remove position"),
        icon: Icon(Icons.close, size: 18, color: cs.error),
        onPressed: () => _removeHop(index),
      ),
    );
    // §098 — grab-strip первым ребёнком Row внутри IntrinsicHeight: полоса
    // тянется на высоту строки (тот же приём, что в custom_rule_tile).
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ReorderGrabStrip(index: index),
          Expanded(child: tile),
        ],
      ),
    );
  }

  Widget _advancedSection(ColorScheme cs) {
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        initiallyExpanded: _advancedOpen,
        onExpansionChanged: (v) => _advancedOpen = v,
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(bottom: 8),
        title: Text(getLocalText.s("Advanced"),
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        children: [
          TextField(
            controller: _idleCtrl,
            decoration: InputDecoration(
              labelText: getLocalText.s("Idle timeout"),
              hintText: getLocalText.s("empty = core default (5m); 0s = keep until stop"),
              helperMaxLines: 2,
              border: const OutlineInputBorder(),
              isDense: true,
            ),
            style: const TextStyle(fontSize: 14),
          ),
          const SizedBox(height: 8),
          SwitchListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(getLocalText.s("Strip evasion tricks from links"),
                style: const TextStyle(fontSize: 14)),
            subtitle: Text(
                getLocalText.s(
                    "One-way DPI tricks make no sense on a link that dials through the previous hop."),
                style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
            // Трёхзначность модели наружу не течёт: пользователю показываем
            // действующее значение (умолчание ядра = включено), а `null`
            // остаётся только пока он к тумблеру не притронулся.
            value: _snapshot().stripEvasionEnabled,
            onChanged: (v) => setState(() => _stripEvasion = v),
          ),
          const SizedBox(height: 4),
          Text(getLocalText.s("Per-key overrides"),
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
          for (final key in kChainStripKeys) _stripTile(key, cs),
        ],
      ),
    );
  }

  /// Строка каталога strip. Трёхзначная, как и данные: галка не тронута →
  /// значение берётся из `strip_evasion` и умолчания каталога ядра; тронута →
  /// уезжает в `strip` явным ключом. Двузначная галка не отличила бы «как
  /// сейчас у ядра» от «я так решил» и молча меняла бы смысл при смене
  /// умолчания ядра.
  Widget _stripTile(String key, ColorScheme cs) {
    final explicit = _strip[key];
    final effective = explicit ??
        ((_stripEvasion ?? true) && (kChainStripDefault[key] ?? false));
    return CheckboxListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      controlAffinity: ListTileControlAffinity.leading,
      visualDensity: VisualDensity.compact,
      tristate: true,
      title: Text(key,
          style: const TextStyle(fontSize: 13, fontFamily: 'monospace')),
      subtitle: Text(_stripHint(key),
          style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
      // null = «не тронуто»: действующее значение показано подписью справа.
      value: explicit,
      onChanged: (v) => setState(() {
        final next = {..._strip};
        if (v == null) {
          next.remove(key);
        } else {
          next[key] = v;
        }
        _strip = next;
      }),
      secondary: Text(
          effective
              ? getLocalText.s("stripped")
              : getLocalText.s("kept"),
          style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
    );
  }

  /// Расшифровка ключа каталога: сами ключи ядра непрозрачны, а выбор без
  /// понимания последствий — не выбор.
  static String _stripHint(String key) => switch (key) {
        kChainStripTlsFragment => getLocalText.s("ClientHello fragmentation"),
        kChainStripMultiplexPadding => getLocalText.s("multiplex padding"),
        kChainStripXhttpPadding => getLocalText.s("XHTTP padding"),
        kChainStripTlsUtls => getLocalText.s(
            "ClientHello fingerprint — must not be stripped on reality nodes"),
        _ => '',
      };

}

/// Пикер позиции: список существующих целей с видом. Уже занятые исключены —
/// ядро отвергает цепочку с дублем.
class _HopPickerSheet extends StatelessWidget {
  const _HopPickerSheet({required this.options});

  final List<ChainHopCandidate> options;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(getLocalText.s("Add position"),
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w600)),
            ),
          ),
          Flexible(
            // Секции как в detour-пикере (директива оператора 25.08):
            // Направления / встроенные / цепочки / группы / серверы, у каждой
            // строки человеческая подпись + сабстрока с данными.
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final section in _sections(context))
                  ...section,
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Секции в порядке пикера. Пустые не рисуются вовсе (ни заголовка, ни
  /// отступа) — как подсекция Направлений в форме.
  List<List<Widget>> _sections(BuildContext context) {
    // Типографика — байт-в-байт как у detour-пикера (§239/§248): секция
    // titleSmall+primary, строки стандартного ListTile (не dense), сабстрока
    // 12/muted — директива оператора 25.08 «как в detour».
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    List<Widget> group(String title, List<ChainHopCandidate> items) {
      if (items.isEmpty) return const [];
      return [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(title,
              style: theme.textTheme.titleSmall
                  ?.copyWith(color: theme.colorScheme.primary)),
        ),
        for (final c in items)
          ListTile(
            title: Text(c.displayLabel.isNotEmpty ? c.displayLabel : c.tag,
                maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: c.subline.isEmpty
                ? null
                : Text(
                    c.kind == ChainHopKind.chain
                        ? getLocalText.plural('%d hops', int.tryParse(c.subline) ?? 0)
                        : c.subline,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: muted)),
            onTap: () => Navigator.pop(context, c.tag),
          ),
      ];
    }

    List<ChainHopCandidate> of(ChainHopKind k) =>
        [for (final c in options) if (c.kind == k) c];
    // Директива оператора 25.08: в предложениях только detour-Направления и
    // серверы; direct-out/группы/цепочки отфильтрованы offered-флагом ещё в
    // targets — секции им не нужны.
    return [
      group(getLocalText.s("Directions"), of(ChainHopKind.direction)),
      group(getLocalText.s("Servers"), [
        ...of(ChainHopKind.node),
        ...of(ChainHopKind.unknown),
        ...of(ChainHopKind.pending),
      ]),
    ];
  }
}

/// Подпись вида позиции. Для чтения списка важен не только тег, но и ЧТО за
/// ним стоит: группа выбирает участника на лету, а вложенная цепочка законна
/// только первой позицией.
String chainHopKindText(ChainHopKind kind) => switch (kind) {
      ChainHopKind.node => getLocalText.s("node"),
      ChainHopKind.group => getLocalText.s("group"),
      ChainHopKind.direction => getLocalText.s("direction"),
      ChainHopKind.chain => getLocalText.s("chain"),
      ChainHopKind.builtin => getLocalText.s("built-in"),
      ChainHopKind.pending => getLocalText.s("loading…"),
      ChainHopKind.unknown => getLocalText.s("not found"),
    };
