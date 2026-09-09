import 'dart:async';
import 'dart:io';
import '../models/node_spec.dart';
import '../services/node_identity.dart';
import 'auto_group_edit_screen.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../controllers/subscription_controller.dart';
import '../models/direction.dart';
import '../models/server_list.dart';
import '../services/error_format.dart';
import '../services/probe/probe_controller.dart';
import '../services/probe/probe_runner.dart';
import 'probe_gate_mixin.dart';
import '../services/settings_storage.dart';
import '../services/subscription/input_helpers.dart';
import 'home/filter_widgets.dart';
import 'node_settings_screen.dart';
import 'home/node_list_presenter.dart' show protoLabel;
import 'subscription_detail_screen/detour_mode.dart';
import 'subscription_detail_screen/tag_prefix_cascade.dart';
import 'subscription_detail_screen/widgets/subscription_settings_tab.dart';
import 'subscriptions_screen/folder_picker.dart';
import '../widgets/detour_target_picker.dart';
import '../widgets/probe_badge.dart';
import '../widgets/reorder_grab_strip.dart';
import '../services/l10n/locale_controller.dart';
import '../services/file_import.dart';
import '../widgets/app_bottom_sheet.dart';

/// §234 — экран папки серверов. Зеркалит SubscriptionDetailScreen: вкладка
/// членов (per-member toggle, drag-reorder, long-press меню) + Settings
/// (общий SubscriptionSettingsTab: tag prefix / detour на всю папку).
class FolderDetailScreen extends StatefulWidget {
  const FolderDetailScreen({
    super.key,
    required this.entry,
    required this.controller,
    this.focusMemberIndex,
  });

  final SubscriptionEntry entry;
  final SubscriptionController controller;

  /// §255 — при открытии проскроллить к этому члену и мигнуть его строкой
  /// (навигация из detour-cycle sheet к ноде-виновнику). null = нет.
  final int? focusMemberIndex;

  @override
  State<FolderDetailScreen> createState() => _FolderDetailScreenState();
}

class _FolderDetailScreenState extends State<FolderDetailScreen>
    with SingleTickerProviderStateMixin, ProbeGateMixin<FolderDetailScreen> {
  late final TabController _tabCtrl;
  bool _editing = false;
  late TextEditingController _nameCtrl;

  // §236 — состояние Test servers. Результаты эфемерны (не персистятся).
  // §326 — ключ = идентичность узла (`ProbeController.probeKeys`), НЕ позиция:
  // удаление/вставка члена больше не сдвигает замеры соседей. Проекцию на
  // индексы для позиционных bulk-хелперов даёт `_probeByIndex()`.
  final Map<String, ProbeResult> _probe = {};
  ProbeRunner? _runner;
  // §286 — коалесцированный ребилд результатов пробы: onResult пишет в _probe
  // без setState-на-члена (у «WARP GENERATOR» ~100 членов → ~100 ребилдов
  // пачкой), а этот throttle сливает их в один setState раз в ~120мс.
  Timer? _probeFlushTimer;
  bool _testing = false;
  ProbeThresholds _thresholds = const ProbeThresholds();

  // §236 UI-rework — локальный фильтр членов (как на главном: regex +
  // протоколы). Тоже эфемерный (осознанно не сохраняется, ср. §048).
  final _filterRegexCtl = TextEditingController();
  bool _filterExpanded = false;
  bool _regexInvert = false;
  final Set<String> _selectedProtocols = {};
  bool _protocolsInvert = false;

  // §248 — Направления: секция Directions в detour-пикере + подпись «⚙ <label>»
  // Направления override-цели в Settings-вкладке.
  List<Direction> _directions = const [];

  /// §393 A6 — префикс, под который написаны фильтры Направлений: значение
  /// поля на момент последнего КОММИТА. Зеркало подписки
  /// (`subscription_detail_screen`) — вкладка Settings общая.
  late String _committedTagPrefix;

  FolderServers get _folder => widget.entry.list as FolderServers;

  // §255 — прокрутка к члену + вспышка строки (навигация из detour-cycle
  // sheet). Локальная (таймер-вспышка). Скролл с retry: в lazy-списке строка
  // за вьюпортом не смонтирована → currentContext null на первом кадре;
  // пробуем несколько кадров, подтягивая список.
  final _scrollController = ScrollController();
  final _memberKeys = <int, GlobalKey>{};
  int? _highlightedMember;
  Timer? _highlightTimer;

  GlobalKey _memberKey(int i) => _memberKeys.putIfAbsent(i, GlobalKey.new);

  /// §239 — голые теги членов, служащих интра-целью detour другого члена
  /// (⚙-бейдж; в билдере такие регистрируются по register-тогглам).
  Set<String> _chainLinkTags() {
    final folder = _folder;
    final bare = <String>{
      for (final m in folder.members)
        if (m.node != null) m.node!.tag,
    };
    final links = <String>{};
    for (final m in folder.members) {
      final d = m.detour;
      if (d.isEmpty || !bare.contains(d)) continue;
      if (d == m.node?.tag) continue; // self не считается
      links.add(d);
    }
    return links;
  }

  /// Индекс entry по ссылке — список мог сместиться (reorder/delete).
  int get _index => widget.controller.entries.indexOf(widget.entry);

  // §278 — entry может исчезнуть из controller.entries при открытом экране
  // (DELETE /folders через Debug API §238; restore из backup → init()
  // пересоздаёт все entries). Осиротевший экран выглядел рабочим, но каждое
  // действие молча умирало в гейтах `if (_index < 0) return` — тот же
  // анти-паттерн «немой гейт», что §277. Слушатель контроллера закрывает
  // экран; сами гейты остаются защитой окна в один кадр до pop'а.
  bool _leaving = false;

  void _onEntriesChanged() {
    if (_leaving || _index >= 0) return;
    _leaving = true;
    // notifyListeners может прийти во время build → pop после кадра.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final route = ModalRoute.of(context);
      if (route == null || !route.isActive) return;
      if (route.isCurrent) {
        Navigator.pop(context);
      } else {
        // Экран не верхний (диалог/шит/пикер поверх) — снимаем именно наш
        // роут, обычный pop снял бы чужой верхний.
        Navigator.of(context).removeRoute(route);
      }
    });
    // Пост-кадровый колбэк сам кадр не планирует — не полагаемся на то, что
    // кадр запросят другие слушатели контроллера (home/subs-экраны).
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(length: 2, vsync: this);
    _nameCtrl = TextEditingController(text: widget.entry.name);
    _committedTagPrefix = widget.entry.tagPrefix; // §393 A6
    widget.controller.addListener(_onEntriesChanged); // §278
    unawaited(_loadThresholds());
    unawaited(_loadDirections());
    final focus = widget.focusMemberIndex;
    if (focus != null && focus >= 0 && focus < _folder.members.length) {
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _focusMember(focus, attempt: 0));
    }
  }

  /// §255 — проскроллить к члену [i] + вспышка. Retry по кадрам: строка за
  /// пределами вьюпорта в lazy-списке не смонтирована на первом кадре
  /// (currentContext null). Грубо прыгаем ScrollController'ом по оценке
  /// позиции, ждём следующий кадр, повторяем ensureVisible — до [maxAttempts].
  void _focusMember(int i, {required int attempt}) {
    if (!mounted) return;
    if (attempt == 0) setState(() => _highlightedMember = i);
    const maxAttempts = 6;
    final ctx = _memberKeys[i]?.currentContext;
    if (ctx != null) {
      unawaited(Scrollable.ensureVisible(ctx,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOutCubic,
          alignment: 0.3));
    } else if (attempt < maxAttempts && _scrollController.hasClients) {
      // Строка ещё не смонтирована — грубый прыжок по оценке (средняя высота
      // строки ~64px), затем повтор на следующем кадре: список подтянет её.
      final target = (i * 64.0)
          .clamp(0.0, _scrollController.position.maxScrollExtent);
      _scrollController.jumpTo(target);
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _focusMember(i, attempt: attempt + 1));
      return;
    }
    _highlightTimer?.cancel();
    _highlightTimer = Timer(const Duration(milliseconds: 2200), () {
      if (mounted) setState(() => _highlightedMember = null);
    });
  }

  /// §393 A6 — префикс допечатан: переписать литеральные вхождения старого
  /// префикса в фильтрах Направлений, про неоднозначные предупредить.
  Future<void> _commitTagPrefix() async {
    final oldPrefix = _committedTagPrefix;
    final newPrefix = widget.entry.tagPrefix;
    if (oldPrefix == newPrefix) return;
    _committedTagPrefix = newPrefix;
    await _loadDirections();
    if (!mounted) return;
    final outcome = await applyTagPrefixCascade(
      directions: _directions,
      oldPrefix: oldPrefix,
      newPrefix: newPrefix,
      sub: widget.controller,
    );
    if (!mounted || outcome.isEmpty) return;
    await _loadDirections(); // переписанные фильтры — в буфер экрана
    if (!mounted) return;
    showTagPrefixCascadeSnackBar(context, outcome);
  }

  /// §248 — загрузка Направлений (initState + refresh перед пикером).
  Future<void> _loadDirections() async {
    final directions = await SettingsStorage.getDirections();
    if (!mounted) return;
    setState(() => _directions = directions);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onEntriesChanged); // §278
    // Отмена доводит run() до finally → probeStop (сессия не повисает).
    _runner?.cancel();
    _probeFlushTimer?.cancel(); // §286
    _probeFlushTimer = null;
    _tabCtrl.dispose();
    _nameCtrl.dispose();
    _filterRegexCtl.dispose();
    _scrollController.dispose();
    _highlightTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadThresholds() async {
    final t = await ProbeController.loadThresholds();
    if (!mounted) return;
    setState(() => _thresholds = t);
  }

  // ─────────────────────── §236 — Test servers ───────────────────────

  /// §286 — коалесцированный ребилд результатов пробы: trailing-throttle ~120мс.
  /// Много onResult подряд → один setState на окно, а не setState на член.
  void _scheduleProbeFlush() {
    if (_probeFlushTimer != null) return;
    _probeFlushTimer = Timer(const Duration(milliseconds: 120), () {
      _probeFlushTimer = null;
      if (mounted) setState(() {});
    });
  }

  Future<void> _toggleTest() async {
    if (_testing) {
      _runner?.cancel();
      _probeFlushTimer?.cancel();
      _probeFlushTimer = null;
      setState(() => _testing = false);
      return;
    }
    if (_folder.members.isEmpty) return;
    // §236/§296 — probe-сессия (временный CommandServer без tun) не поднимается
    // поверх живого туннеля. Общий гейт: при VPN-on показывает попап Stop VPN;
    // true = можно тестировать (VPN off или успешно остановлен).
    if (await ensureVpnStoppedForProbe()) {
      await _runProbe();
    }
  }

  /// §236 — сам прогон пробы (VPN уже выключен). Вынесен из [_toggleTest],
  /// чтобы гейт-попап мог перезапустить его после Stop VPN.
  Future<void> _runProbe() async {
    if (_folder.members.isEmpty) return;
    // §284 — опции теста самой папки (ping_url/ping_timeout_ms в объекте папки)
    // перекрывают глобальные. Папка «WARP GENERATOR» так тестируется по IP без DNS.
    final (:url, :timeoutMs) = await ProbeController.resolvePingOptions(
      overrideUrl: _folder.pingUrl,
      overrideTimeoutMs: _folder.pingTimeoutMs,
    );
    if (!mounted) return;
    // §326 — снимок ключей на старте прогона: onResult отдаёт позицию (runner
    // работает над плоским списком нод и о папках не знает, §296), переводим
    // её в ключ по этому снимку.
    final probeKeys = _memberProbeKeys();
    setState(() {
      _testing = true;
      _probe
        ..clear()
        ..addEntries([
          for (final k in probeKeys)
            MapEntry(k, const ProbeResult(ProbeStatus.pending)),
        ]);
    });
    final runner = ProbeRunner();
    _runner = runner;
    // §296 — probe над списком нод: члены папки (nullable, unfiltered, чтобы
    // выключенные/битые сохранили индекс и вердикт — НЕ _folder.nodes, тот
    // отфильтрован до enabled+parsed).
    final err = await runner.run(
      [for (final m in _folder.members) m.node],
      url: url,
      timeoutMs: timeoutMs,
      onResult: (i, r) {
        if (!mounted) return;
        // §286 — накапливаем без setState-на-члена; throttle сольёт в один
        // ребилд (~120мс). Иначе «WARP GENERATOR» (~100 членов) даёт ~100
        // setState пачкой → главный поток лагает.
        if (i < probeKeys.length) _probe[probeKeys[i]] = r;
        _scheduleProbeFlush();
      },
    );
    _probeFlushTimer?.cancel();
    _probeFlushTimer = null;
    if (!mounted) return;
    setState(() => _testing = false);
    // §236 — VPN стартовал между гейтом и probeStart (гонка): runner вернул
    // маркер → тот же гейт-попап, не текст ошибки.
    if (err == kProbeVpnRunning) {
      if (mounted && await onProbeVpnRaceGate()) await _runProbe();
      return;
    }
    if (err.isNotEmpty) {
      await _showError(err);
      return;
    }
  }

  /// §236 UI-rework — настройки теста (long-press на кнопке, как на главном):
  /// цель пинга (глобальные ping_options) + пороги цветовой шкалы.
  void _showTestSettings() {
    showAppBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.link),
              title: Text(getLocalText.s("Ping URL & timeout…")),
              subtitle: Text(getLocalText.s("Shared with the home screen ping")),
              onTap: () {
                Navigator.pop(ctx);
                unawaited(_editPingTarget());
              },
            ),
            ListTile(
              leading: const Icon(Icons.palette_outlined),
              title: Text(getLocalText.s("Ping color thresholds…")),
              onTap: () {
                Navigator.pop(ctx);
                unawaited(_editThresholds());
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _editPingTarget() async {
    final target = await ProbeController.globalPingTarget();
    if (!mounted) return;
    final urlCtl = TextEditingController(text: target.url);
    final timeoutCtl = TextEditingController(text: '${target.timeoutMs}');
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(getLocalText.s("Ping target")),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: urlCtl,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: getLocalText.s("Test URL"),
                hintText: getLocalText.s("empty = core default"),
                border: const OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: timeoutCtl,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: getLocalText.s("Timeout, ms"),
                border: const OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(getLocalText.s("Cancel"))),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(getLocalText.s("Save"))),
        ],
      ),
    );
    final url = urlCtl.text.trim();
    final timeout = int.tryParse(timeoutCtl.text.trim());
    urlCtl.dispose();
    timeoutCtl.dispose();
    if (saved != true || !mounted) return;
    await ProbeController.saveGlobalPing(url, timeoutMs: timeout);
  }

  /// Число завершённых тестов (для строки-сводки).
  ({int ok, int dead, int broken}) _probeSummary() {
    var ok = 0, dead = 0, broken = 0;
    for (final r in _probe.values) {
      switch (r.status) {
        case ProbeStatus.ok:
          ok++;
        case ProbeStatus.failed:
          dead++;
        case ProbeStatus.broken:
        case ProbeStatus.invalid:
          broken++;
        case ProbeStatus.pending:
        case ProbeStatus.group: // §336 — не тестируется, в сводке не считаем
          break;
      }
    }
    return (ok: ok, dead: dead, broken: broken);
  }

  Future<void> _disableSlowerThan() async {
    final ctl = TextEditingController(text: '${_thresholds.orangeMs}');
    final ms = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(getLocalText.s("Disable slow servers")),
        content: TextField(
          controller: ctl,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
            labelText: getLocalText.s("Slower than, ms"),
            border: const OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(getLocalText.s("Cancel"))),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, int.tryParse(ctl.text.trim())),
            child: Text(getLocalText.s("Disable")),
          ),
        ],
      ),
    );
    ctl.dispose();
    if (ms == null || !mounted) return;
    final slow = ProbeController.slowerThan(_probeByIndex(), ms);
    if (slow.isEmpty) {
      await _showError(getLocalText.s("No tested servers slower than %d ms", ms));
      return;
    }
    final idx = _index;
    if (idx < 0) return;
    await widget.controller.setMembersEnabled(idx, slow, false);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(getLocalText.plural("Disabled %1\$d servers > %2\$d ms", slow.length, ms))),
    );
    setState(() {});
  }

  /// §326 — кеш `probeKeys` текущего состава: ключ — sha256 по emit-map узла,
  /// считать его на каждый ребилд каждой строки (itemBuilder) дорого. Инвалидация
  /// по самому списку членов: `SubscriptionController` отдаёт новый `List` на
  /// любую мутацию состава, а правка члена меняет `raw` → identical() ложно.
  List<FolderMember>? _probeKeysFor;
  List<String> _probeKeysCache = const [];
  List<String> _memberProbeKeys() {
    final members = _folder.members;
    if (!identical(_probeKeysFor, members)) {
      _probeKeysFor = members;
      _probeKeysCache = ProbeController.probeKeys(members);
    }
    return _probeKeysCache;
  }

  /// §326 — проекция результатов на текущие позиции членов. Bulk-решения
  /// (`unreachableIndexes`/`slowerThan`/`pingSortOrder`) остаются индексными:
  /// их выход скармливается позиционным мутаторам контроллера
  /// (`setMembersEnabled`/`removeMembersAt`/`applyMembersOrder`). Граница
  /// «ключ → индекс» ровно здесь.
  Map<int, ProbeResult> _probeByIndex() {
    final keys = _memberProbeKeys();
    return {
      for (var i = 0; i < keys.length; i++) i: ?_probe[keys[i]],
    };
  }

  /// §389 — есть хотя бы один ЗАВЕРШЁННЫЙ вердикт теста (гейт пунктов меню
  /// «Test actions»; семантика и мотивация — как в подписке).
  bool get _hasProbeVerdict =>
      _probe.values.any((r) => r.status != ProbeStatus.pending &&
          r.status != ProbeStatus.group);

  /// §284/§296 — индексы членов, не прошедших последний тест (общий хелпер).
  Set<int> _unreachableIndexes() =>
      ProbeController.unreachableIndexes(_probeByIndex());

  /// §284 — выключить (не удалять) недоступные по последнему тесту. Узлы
  /// остаются в папке серыми; результаты теста сохраняются.
  Future<void> _disableUnreachable() async {
    final dead = _unreachableIndexes();
    if (dead.isEmpty) {
      await _showError(
          getLocalText.s("No unreachable or broken servers in last test"));
      return;
    }
    final idx = _index;
    if (idx < 0) return;
    await widget.controller.setMembersEnabled(idx, dead, false);
  }

  Future<void> _deleteUnreachable() async {
    final dead = _unreachableIndexes();
    if (dead.isEmpty) {
      await _showError(getLocalText.s("No unreachable or broken servers in last test"));
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(getLocalText.s("Delete unreachable?")),
        content: Text(getLocalText.plural("Remove %d servers that failed the test (unreachable or broken)?", dead.length)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(getLocalText.s("Cancel"))),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(
                foregroundColor: Theme.of(ctx).colorScheme.error),
            child: Text(getLocalText.s("Delete")),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final idx = _index;
    if (idx < 0) return;
    await widget.controller.removeMembersAt(idx, dead);
    if (!mounted) return;
    // §326 — результаты выживших остаются валидными: ключ = идентичность узла,
    // а не позиция. До §326 здесь стоял `_probe.clear()` (индексы съезжали).
    setState(() {});
  }

  Future<void> _sortByPing() async {
    final idx = _index;
    if (idx < 0) return;
    final order =
        ProbeController.pingSortOrder(_probeByIndex(), _folder.members.length);
    await widget.controller.applyMembersOrder(idx, order);
    if (!mounted) return;
    // §326 — перепривязка не нужна: ключи едут вместе с членами.
    setState(() {});
  }

  Future<void> _editThresholds() async {
    if (!mounted) return; // §278 — см. _editMember
    final g = TextEditingController(text: '${_thresholds.greenMs}');
    final y = TextEditingController(text: '${_thresholds.yellowMs}');
    final o = TextEditingController(text: '${_thresholds.orangeMs}');
    Widget field(TextEditingController c, String label) => Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: TextField(
            controller: c,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: label,
              border: const OutlineInputBorder(),
              isDense: true,
            ),
          ),
        );
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(getLocalText.s("Ping color thresholds")),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            field(g, getLocalText.s("Green up to, ms")),
            field(y, getLocalText.s("Yellow up to, ms")),
            field(o, getLocalText.s("Orange up to, ms")),
            Text(
              getLocalText.s("Anything above is red."),
              style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                  color: Theme.of(ctx).colorScheme.onSurfaceVariant),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(getLocalText.s("Cancel"))),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(getLocalText.s("Save"))),
        ],
      ),
    );
    final gv = int.tryParse(g.text.trim());
    final yv = int.tryParse(y.text.trim());
    final ov = int.tryParse(o.text.trim());
    g.dispose();
    y.dispose();
    o.dispose();
    if (saved != true || !mounted) return;
    final next = await ProbeController.saveThresholds(
      greenMs: gv,
      yellowMs: yv,
      orangeMs: ov,
    );
    if (!mounted) return;
    setState(() => _thresholds = next);
  }

  void _toggleEdit() {
    if (_editing) {
      final name = _nameCtrl.text.trim();
      final idx = _index;
      if (idx >= 0 && name.isNotEmpty) {
        unawaited(widget.controller.renameAt(idx, name));
      }
    }
    setState(() => _editing = !_editing);
  }

  Future<void> _delete() async {
    // Три исхода: cancel / вынести серверы одиночными / удалить всё.
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(getLocalText.s("Delete folder?")),
        content: Text(_folder.members.isEmpty
            ? getLocalText.s("Remove \"%s\"?", widget.entry.displayName)
            : getLocalText.plural("Folder \"%2\$s\" contains %1\$d servers.",
                _folder.members.length, widget.entry.displayName)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(getLocalText.s("Cancel"))),
          if (_folder.members.isNotEmpty)
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'keep'),
              child: Text(getLocalText.s("Keep servers")),
            ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'all'),
            style: TextButton.styleFrom(
                foregroundColor: Theme.of(ctx).colorScheme.error),
            child: Text(_folder.members.isEmpty
                ? getLocalText.s("Delete")
                : getLocalText.s("Delete folder & servers")),
          ),
        ],
      ),
    );
    if (choice == null || !mounted) return;
    final idx = _index;
    if (idx < 0) {
      if (mounted) Navigator.pop(context);
      return;
    }
    // §278 — свой явный pop ниже; гасим авто-pop слушателя (двойной pop
    // снял бы экран под нами).
    _leaving = true;
    try {
      await widget.controller
          .deleteFolderAt(idx, keepServers: choice == 'keep');
    } catch (_) {
      // deleteFolderAt мог упасть ПОСЛЕ removeAt (на _persist): notify и наш
      // pop ниже не случатся, а защёлка навсегда заглушила бы авто-pop —
      // экран стал бы вечным зомби с немыми гейтами. Снимаем и добираем
      // осиротение вручную (упавший вызов сам не нотифицировал).
      _leaving = false;
      _onEntriesChanged();
      rethrow;
    }
    if (mounted) Navigator.pop(context);
  }

  // ─────────────────────────── Add flows ───────────────────────────

  Future<void> _showError(String err) async {
    if (err.isEmpty || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
  }

  Future<void> _addFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted) return;
    final text = data?.text?.trim() ?? '';
    if (text.isEmpty) {
      await _showError(getLocalText.s("Clipboard is empty"));
      return;
    }
    final idx = _index;
    if (idx < 0) return;
    final err = await widget.controller.addMembersToFolder(idx, text);
    if (!mounted) return;
    if (err != null) {
      await _showError(err.render());
      return;
    }
    setState(() {});
  }

  Future<void> _addFromFiles() async {
    try {
      // §372 — Android TV без файлового менеджера: подсказка вместо тупика.
      final outcome = await pickFileSafely(allowMultiple: true);
      if (outcome is! PickedFiles) {
        final problem = pickProblemText(outcome);
        if (problem != null && mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(problem)));
        }
        return;
      }
      var added = 0;
      final errors = <String>[];
      for (final file in outcome.files) {
        String text;
        if (file.bytes != null && file.bytes!.isNotEmpty) {
          text = String.fromCharCodes(file.bytes!);
        } else if (file.path != null) {
          text = await File(file.path!).readAsString();
        } else {
          continue;
        }
        text = text.trim();
        if (text.isEmpty) continue;
        final idx = _index;
        if (idx < 0) return;
        final err = await widget.controller.addMembersToFolder(
          idx,
          text,
          nameFallback: SubscriptionController.fileBaseName(file.name),
        );
        if (err == null) {
          added++;
        } else {
          if (!mounted) return;
          errors.add('${file.name}: ${err.render()}');
        }
      }
      if (!mounted) return;
      if (errors.isNotEmpty) {
        await _showError(errors.join('\n'));
      } else if (added == 0) {
        await _showError(getLocalText.s("No servers found in selected files"));
      }
      setState(() {});
    } catch (e) {
      if (!mounted) return;
      await _showError(getLocalText.s("Error: %s", formatUserError(e).render()));
    }
  }

  /// §322 — создать узел автовыбора в этой папке. Кандидаты в пул — её же
  /// члены: группа не выходит за границы контейнера.
  Future<void> _addAutoNode() async {
    final idx = _index;
    if (idx < 0) return;
    final folder = widget.controller.entries[idx].list;
    if (folder is! FolderServers) return;

    final candidates = _poolCandidates(folder);
    final res = await Navigator.of(context).push<AutoGroupEditResult>(
      MaterialPageRoute(
        builder: (_) => AutoGroupEditScreen(
          initial: null,
          candidates: candidates,
          canDelete: false,
        ),
      ),
    );
    if (!mounted || res is! AutoGroupSaved) return;

    // Храним как обычного члена: `autogroup://`-URI парсится обратно при
    // загрузке (§322 §7), отдельной ветки в модели папки не нужно.
    final err = await widget.controller
        .addMembersToFolder(idx, res.spec.toUri());
    if (!mounted) return;
    if (err != null) {
      await _showError(err.render());
      return;
    }
    setState(() {});
  }

  /// §322 — правка существующего узла автовыбора. Кандидаты считаем без
  /// него самого: группа не может взять в пул саму себя.
  Future<void> _editAutoNode(int memberIndex, AutoSelectSpec node) async {
    final idx = _index;
    if (idx < 0) return;
    final folder = widget.controller.entries[idx].list;
    if (folder is! FolderServers) return;

    final res = await Navigator.of(context).push<AutoGroupEditResult>(
      MaterialPageRoute(
        builder: (_) => AutoGroupEditScreen(
          initial: node,
          candidates: _poolCandidates(folder),
          canDelete: true,
        ),
      ),
    );
    if (!mounted || res == null) return;

    switch (res) {
      case AutoGroupSaved(:final spec):
        final err = await widget.controller
            .updateMemberAt(idx, memberIndex, spec.toUri());
        if (!mounted) return;
        if (err != null) {
          await _showError(err.render());
          return;
        }
      case AutoGroupDeleted():
        await widget.controller.removeMemberAt(idx, memberIndex);
        if (!mounted) return;
    }
    setState(() {});
  }

  /// Члены папки, которые могут попасть в пул: обычные узлы, без групп
  /// (вложенность urltest в urltest бессмысленна) и без нечитаемых raw.
  List<({String key, String label})> _poolCandidates(FolderServers folder) {
    final out = <({String key, String label})>[];
    for (final m in folder.members) {
      final n = m.node;
      if (n == null || n.isGroup) continue;
      final k = nodeIdentityKey(n);
      if (k == null) continue;
      out.add((key: k, label: n.label.isEmpty ? n.tag : n.label));
    }
    return out;
  }

  Future<void> _addFromUrl() async {
    final ctl = TextEditingController();
    final url = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(getLocalText.s("Add servers by URL")),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: ctl,
              autofocus: true,
              decoration: InputDecoration(
                labelText: getLocalText.s("URL"),
                // l10n-exempt: URL scheme example
                hintText: 'https://…',
                border: const OutlineInputBorder(),
              ),
              keyboardType: TextInputType.url,
              autocorrect: false,
            ),
            const SizedBox(height: 8),
            Text(
              getLocalText.s("Fetched once — servers are added as a snapshot and won't auto-update. For live updates add a subscription instead."),
              style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                  color: Theme.of(ctx).colorScheme.onSurfaceVariant),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(getLocalText.s("Cancel"))),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctl.text.trim()),
            child: Text(getLocalText.s("Fetch")),
          ),
        ],
      ),
    );
    ctl.dispose();
    if (url == null || url.isEmpty || !mounted) return;
    if (!isSubscriptionUrl(url)) {
      await _showError(getLocalText.s("Enter a valid http(s):// URL"));
      return;
    }
    final idx = _index;
    if (idx < 0) return;
    final err = await widget.controller.addUrlSnapshotToFolder(idx, url);
    if (!mounted) return;
    if (err != null) {
      await _showError(err.render());
      return;
    }
    setState(() {});
  }

  // ───────────────────────── Member actions ─────────────────────────

  Future<void> _editMember(int memberIndex) async {
    // §278 — тап из шита, пережившего removeRoute экрана: State unmounted,
    // геттер context бросит на первой же строке (showDialog).
    if (!mounted) return;
    final member = _folder.members[memberIndex];

    // §322 — у узла автовыбора свой редактор: сырой `autogroup://`-URI
    // пользователю показывать нельзя (правило в percent-encoding).
    final node = member.node;
    if (node is AutoSelectSpec) {
      await _editAutoNode(memberIndex, node);
      return;
    }

    final ctl = TextEditingController(text: member.raw);
    final newRaw = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(getLocalText.s("Edit server")),
        content: TextField(
          controller: ctl,
          autofocus: true,
          maxLines: 8,
          minLines: 3,
          style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
          decoration: InputDecoration(
            border: const OutlineInputBorder(),
            hintText: getLocalText.s("Proxy link, WireGuard config or outbound JSON"),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(getLocalText.s("Cancel"))),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctl.text),
            child: Text(getLocalText.s("Save")),
          ),
        ],
      ),
    );
    ctl.dispose();
    if (newRaw == null || !mounted) return;
    final idx = _index;
    if (idx < 0) return;
    final err = await widget.controller.updateMemberAt(idx, memberIndex, newRaw);
    if (!mounted) return;
    if (err != null) {
      await _showError(err.render());
      return;
    }
    setState(() {});
  }

  Future<void> _moveMember(int memberIndex) async {
    if (!mounted) return; // §278 — см. _editMember
    final toIndex = await showFolderPicker(context, widget.controller,
        excludeId: widget.entry.id);
    if (toIndex == null || !mounted) return;
    final idx = _index;
    if (idx < 0) return;
    final err =
        await widget.controller.moveMemberToFolder(idx, memberIndex, toIndex);
    if (!mounted) return;
    if (err != null) {
      await _showError(err.render());
      return;
    }
    setState(() {});
  }

  Future<void> _ungroupMember(int memberIndex) async {
    final idx = _index;
    if (idx < 0) return;
    await widget.controller.ungroupMemberAt(idx, memberIndex);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(getLocalText.s("Moved out of folder"))),
    );
    setState(() {});
  }

  Future<void> _deleteMember(int memberIndex) async {
    if (!mounted) return; // §278 — см. _editMember
    final member = _folder.members[memberIndex];
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(getLocalText.s("Delete server?")),
        content: Text(getLocalText.s("Remove \"%s\" from this folder?", _memberTitle(member))),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(getLocalText.s("Cancel"))),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(
                foregroundColor: Theme.of(ctx).colorScheme.error),
            child: Text(getLocalText.s("Delete")),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final idx = _index;
    if (idx < 0) return;
    await widget.controller.removeMemberAt(idx, memberIndex);
    setState(() {});
  }

  void _showMemberMenu(int memberIndex) {
    showAppBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: Text(getLocalText.s("Edit…")),
              onTap: () {
                Navigator.pop(ctx);
                unawaited(_editMember(memberIndex));
              },
            ),
            ListTile(
              leading: const Icon(Icons.drive_file_move_outline),
              title: Text(getLocalText.s("Move to folder…")),
              onTap: () {
                Navigator.pop(ctx);
                unawaited(_moveMember(memberIndex));
              },
            ),
            ListTile(
              leading: const Icon(Icons.folder_off_outlined),
              title: Text(getLocalText.s("Move out of folder")),
              subtitle: Text(getLocalText.s("Becomes a standalone server")),
              onTap: () {
                Navigator.pop(ctx);
                unawaited(_ungroupMember(memberIndex));
              },
            ),
            ListTile(
              leading: Icon(Icons.delete_outline,
                  color: Theme.of(ctx).colorScheme.error),
              title: Text(getLocalText.s("Delete"),
                  style: TextStyle(color: Theme.of(ctx).colorScheme.error)),
              onTap: () {
                Navigator.pop(ctx);
                unawaited(_deleteMember(memberIndex));
              },
            ),
          ],
        ),
      ),
    );
  }

  static String _memberTitle(FolderMember m) {
    final node = m.node;
    if (node == null) {
      final line = m.raw.split('\n').first.trim();
      return line.length > 40 ? '${line.substring(0, 40)}…' : line;
    }
    return node.label.isNotEmpty ? node.label : node.tag;
  }

  // ───────────────────────────── build ─────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AnimatedBuilder(
      animation: widget.entry,
      builder: (context, _) => Scaffold(
        appBar: AppBar(
          title: _editing
              ? TextField(
                  controller: _nameCtrl,
                  autofocus: true,
                  style: theme.textTheme.titleLarge,
                  decoration: InputDecoration(
                    border: InputBorder.none,
                    hintText: getLocalText.s("Folder name"),
                  ),
                  onSubmitted: (_) => _toggleEdit(),
                )
              : Row(
                  children: [
                    const Icon(Icons.folder_outlined, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        widget.entry.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
          actions: [
            IconButton(
              tooltip: _editing ? getLocalText.s("Save") : getLocalText.s("Rename"),
              icon: Icon(_editing ? Icons.check : Icons.edit_outlined),
              onPressed: _toggleEdit,
            ),
            PopupMenuButton<String>(
              tooltip: getLocalText.s("Add servers"),
              icon: const Icon(Icons.add),
              onSelected: (v) {
                if (v == 'paste') unawaited(_addFromClipboard());
                if (v == 'file') unawaited(_addFromFiles());
                if (v == 'url') unawaited(_addFromUrl());
                if (v == 'auto') unawaited(_addAutoNode());
              },
              itemBuilder: (menuCtx) => [
                PopupMenuItem(
                    value: 'paste',
                    child: Text(getLocalText.s("Paste from clipboard"))),
                PopupMenuItem(
                    value: 'file',
                    child: Text(getLocalText.s("Import from files…"))),
                PopupMenuItem(
                    value: 'url', child: Text(getLocalText.s("Add by URL…"))),
                const PopupMenuDivider(),
                // §322 — не сервер, а пул автовыбора среди членов ЭТОЙ папки.
                PopupMenuItem(
                    value: 'auto',
                    child: Text(getLocalText.s("Add auto node…"))),
              ],
            ),
            IconButton(
              tooltip: getLocalText.s("Delete folder"),
              icon: const Icon(Icons.delete_outline),
              onPressed: _delete,
            ),
          ],
          bottom: TabBar(
            controller: _tabCtrl,
            tabs: [
              Tab(text: getLocalText.s("Servers")),
              Tab(text: getLocalText.s("Settings")),
            ],
          ),
        ),
        body: TabBarView(
          controller: _tabCtrl,
          children: [
            _buildMembersTab(theme),
            _buildSettingsTab(theme),
          ],
        ),
      ),
    );
  }

  Widget _buildMembersTab(ThemeData theme) {
    final members = _folder.members;
    if (members.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.folder_open,
                  size: 48, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(height: 12),
              Text(getLocalText.s("Folder is empty"),
                  style: theme.textTheme.titleMedium),
              const SizedBox(height: 4),
              Text(
                getLocalText.s("Add servers with the + button above, or long-press a standalone server on the Servers screen and choose \"Move to folder…\"."),
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      );
    }
    final visible = _visibleMembers();
    final Widget list;
    if (_filterActive) {
      // §236 UI-rework — при активном фильтре drag-reorder выключен (индексы
      // отфильтрованного вида не соответствуют составу папки).
      list = ListView.builder(
        controller: _scrollController,
        padding: EdgeInsets.fromLTRB(
            12, 4, 12, MediaQuery.of(context).padding.bottom + 24),
        itemCount: visible.length,
        itemBuilder: (context, vi) {
          final (i, m) = visible[vi];
          return _memberTile(i, m, reorderable: false);
        },
      );
    } else {
      list = ReorderableListView.builder(
        scrollController: _scrollController,
        padding: EdgeInsets.fromLTRB(
            12, 4, 12, MediaQuery.of(context).padding.bottom + 24),
        buildDefaultDragHandles: false,
        itemCount: members.length,
        onReorderItem: (oldIndex, newIndex) {
          // onReorderItem уже приводит newIndex к списку БЕЗ перетаскиваемого
          // элемента — ручной сдвиг «-1 при move вниз» здесь не нужен.
          final idx = _index;
          if (idx < 0) return;
          unawaited(widget.controller.reorderMember(idx, oldIndex, newIndex));
          // §326 — сдвиг ключей больше не нужен: результат привязан к узлу,
          // а не к позиции, и едет вместе со строкой.
        },
        itemBuilder: (context, i) =>
            _memberTile(i, members[i], reorderable: true),
      );
    }
    return Column(
      children: [
        _buildControlBar(theme),
        if (_filterExpanded) _buildFilterPanel(theme),
        const Divider(height: 1),
        Expanded(child: list),
      ],
    );
  }

  Widget _memberTile(int i, FolderMember m, {required bool reorderable}) {
    final cs = Theme.of(context).colorScheme;
    final highlighted = _highlightedMember == i;
    final keys = _memberProbeKeys();
    final probe = i < keys.length ? _probe[keys[i]] : null; // §326
    // §255 — reorder-key top-level (KeyedSubtree); GlobalKey + вспышка на
    // внутреннем AnimatedContainer (навигация из detour-cycle sheet).
    return KeyedSubtree(
      key: ValueKey('member-$i-${m.raw.hashCode}'),
      child: AnimatedContainer(
        key: _memberKey(i),
        duration: const Duration(milliseconds: 200),
        decoration: highlighted
            ? BoxDecoration(
                color: cs.primaryContainer.withValues(alpha: 0.5),
                border: Border(
                    left: BorderSide(color: cs.primary, width: 3)),
              )
            : null,
        child: _MemberTile(
          member: m,
      isChainLink:
          m.node != null && _chainLinkTags().contains(m.node!.tag), // §239 ⚙
      dragIndex: i,
      reorderable: reorderable,
      folderEnabled: widget.entry.enabled,
      probe: probe,
      thresholds: _thresholds,
      onToggle: () {
        final idx = _index;
        if (idx < 0) return;
        unawaited(widget.controller
            .toggleMemberAt(idx, i)
            .then((_) => mounted ? setState(() {}) : null));
      },
      onLongPress: () => _showMemberMenu(i),
      // §237 — тап открывает полный Node Settings (как у одиночного сервера);
      // битый член (ноды нет) — прежнее меню (Edit raw / Delete).
      onTap: m.node == null
          ? () => _showMemberMenu(i)
          : () {
              final idx = _index;
              if (idx < 0) return;
              Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => NodeSettingsScreen(
                    entry: widget.entry,
                    index: idx,
                    memberIndex: i,
                    subController: widget.controller,
                  ),
                ),
              ).then((_) => mounted ? setState(() {}) : null);
            },
      onProbeBadgeTap: () {
        final r = probe;
        if (r == null || r.message.isEmpty) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(r.message)),
        );
      },
        ),
      ),
    );
  }

  // ─── §236 UI-rework — полоса: инфо · действия · тест · фильтр ──────────

  /// Полоса над списком (паттерн главного экрана): слева инфо/сводка теста,
  /// справа — actions (при результатах), кнопка теста (`Icons.speed`, тап =
  /// старт/отмена, long-press = настройки) и toggle фильтра (`filter_list`).
  Widget _buildControlBar(ThemeData theme) {
    final muted = theme.colorScheme.onSurfaceVariant;
    final s = _probeSummary();
    final String info;
    if (_testing) {
      info = getLocalText.s("Testing… %d done", s.ok + s.dead);
    } else if (_probe.isNotEmpty) {
      info = [
        getLocalText.s("%d ok", s.ok),
        getLocalText.plural("%d err", s.dead),
        if (s.broken > 0) getLocalText.plural("%d broken", s.broken),
      ].join(' · ');
    } else {
      final total = _folder.members.length;
      final off = _folder.disabledCount;
      info = [
        getLocalText.plural("%d servers", total),
        if (off > 0) getLocalText.s("%d off", off),
      ].join(' · ');
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 4, 0),
      child: Row(
        children: [
          Expanded(
            child: Text(info, style: TextStyle(fontSize: 12, color: muted)),
          ),
          // Кнопка теста — как mass-ping на главном (Icons.speed / stop),
          // long-press = настройки теста (URL/timeout + пороги шкалы).
          GestureDetector(
            onTap: _folder.members.isEmpty
                ? null
                : () => unawaited(_toggleTest()),
            onLongPress: _showTestSettings,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Icon(
                _testing ? Icons.stop_circle_outlined : Icons.speed,
                size: 22,
                color: _folder.members.isEmpty
                    ? Theme.of(context).disabledColor
                    : null,
              ),
            ),
          ),
          // Toggle фильтра — как на главном (§048): primary + точка при
          // активных фильтрах.
          IconButton(
            tooltip: _filterExpanded
                ? getLocalText.s("Hide filters")
                : getLocalText.s("Show filters"),
            visualDensity: VisualDensity.compact,
            onPressed: () =>
                setState(() => _filterExpanded = !_filterExpanded),
            icon: Stack(
              clipBehavior: Clip.none,
              children: [
                Icon(
                  Icons.filter_list,
                  size: 20,
                  color: _filterActive ? theme.colorScheme.primary : null,
                ),
                if (_filterActive)
                  Positioned(
                    right: -2,
                    top: -2,
                    child: IgnorePointer(
                      child: Container(
                        width: 8,
                        height: 8,
                        decoration: const BoxDecoration(
                          color: Colors.amber,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          // §389 — кнопка на месте ВСЕГДА (не появляется/исчезает по наличию
          // результатов): без завершённого теста пункты серые и некликабельные.
          // `enabled: false` у PopupMenuItem даёт и серый текст, и отсутствие
          // реакции на тап — отдельного стиля не нужно.
          PopupMenuButton<String>(
            tooltip: getLocalText.s("Test actions"),
            icon: const Icon(Icons.more_vert, size: 20),
            onSelected: (v) {
              if (v == 'disable_slow') unawaited(_disableSlowerThan());
              if (v == 'disable_dead') unawaited(_disableUnreachable());
              if (v == 'delete_dead') unawaited(_deleteUnreachable());
              if (v == 'sort') unawaited(_sortByPing());
            },
            itemBuilder: (menuCtx) {
              final ready = _hasProbeVerdict;
              return [
                PopupMenuItem(
                    value: 'disable_slow',
                    enabled: ready,
                    child: Text(getLocalText.s("Disable slower than…"))),
                PopupMenuItem(
                    value: 'disable_dead',
                    enabled: ready,
                    child: Text(getLocalText.s("Disable unreachable"))),
                PopupMenuItem(
                    value: 'delete_dead',
                    enabled: ready,
                    child: Text(getLocalText.s("Delete unreachable"))),
                PopupMenuItem(
                    value: 'sort',
                    enabled: ready,
                    child: Text(getLocalText.s("Sort by ping"))),
              ];
            },
          ),
        ],
      ),
    );
  }

  bool get _filterActive =>
      _filterRegexCtl.text.trim().isNotEmpty || _selectedProtocols.isNotEmpty;

  bool get _regexValid {
    final t = _filterRegexCtl.text.trim();
    if (t.isEmpty) return true;
    try {
      RegExp(t);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Члены, проходящие фильтр, парами (оригинальный индекс, член) — probe и
  /// bulk-операции работают по оригинальным индексам состава.
  List<(int, FolderMember)> _visibleMembers() {
    RegExp? re;
    final pattern = _filterRegexCtl.text.trim();
    if (pattern.isNotEmpty) {
      try {
        re = RegExp(pattern, caseSensitive: false);
      } catch (_) {
        re = null; // битый regex = фильтр не применяем (поле подсветится)
      }
    }
    final out = <(int, FolderMember)>[];
    for (var i = 0; i < _folder.members.length; i++) {
      final m = _folder.members[i];
      final node = m.node;
      if (re != null) {
        final hay = node == null ? m.raw : '${node.tag} ${node.label}';
        if (re.hasMatch(hay) == _regexInvert) continue;
      }
      if (_selectedProtocols.isNotEmpty) {
        final match = _selectedProtocols.contains(node?.protocol ?? '');
        if (match == _protocolsInvert) continue;
      }
      out.add((i, m));
    }
    return out;
  }

  /// §236 UI-rework — панель фильтра: regex + протокол-чипы (виджеты главного
  /// экрана, §048/§095).
  Widget _buildFilterPanel(ThemeData theme) {
    final protocols = <String>{
      for (final m in _folder.members)
        if (m.node != null) m.node!.protocol,
    }.toList()
      ..sort();
    return Container(
      color: theme.colorScheme.surfaceContainerLow,
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          RegexFilterField(
            controller: _filterRegexCtl,
            onChanged: (_) => setState(() {}),
            valid: _regexValid,
            invert: _regexInvert,
            onInvertToggle: () => setState(() => _regexInvert = !_regexInvert),
            onClear: () {
              _filterRegexCtl.clear();
              setState(() {});
            },
          ),
          if (protocols.isNotEmpty) ...[
            const SizedBox(height: 4),
            MultiSelectChipsRow(
              options: [for (final p in protocols) (p, protoLabel(p))],
              enabled: _selectedProtocols,
              onToggle: (id) => setState(() {
                if (!_selectedProtocols.add(id)) _selectedProtocols.remove(id);
              }),
              invert: _protocolsInvert,
              onInvertToggle: () =>
                  setState(() => _protocolsInvert = !_protocolsInvert),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSettingsTab(ThemeData theme) {
    // §237 — полное detour-радио (Use / Add+Replace / None) нужно папке не
    // только при родных цепочках (§111-логика подписки), но и когда у членов
    // есть ЛИЧНЫЕ detour'ы: Replace = переписать их, append = дополнить тех,
    // у кого личного нет. Иначе Replace-тоггл недостижим.
    final hasDetour = _folder.nodes.any((n) => n.chained != null) ||
        _folder.members.any((m) => m.detour.isNotEmpty);
    return SubscriptionSettingsTab(
      entry: widget.entry,
      folderMode: true, // §239 — адаптированные тексты
      directions: _directions, // §248 — подпись Направления override-цели
      // §252 — разворот цели в цепочку «как пакет пойдёт»; интра-члены
      // папки имеют приоритет (bare-тег, зеркало FolderDetourPlan).
      detourPathHopsOf: (stored) => detourPathHops(stored,
          controller: widget.controller,
          directions: _directions,
          folder: widget.entry.list is FolderServers
              ? widget.entry.list as FolderServers
              : null),
      hasDetour: hasDetour,
      detourMode: _detourMode,
      onTagPrefixChanged: (val) {
        widget.entry.tagPrefix = val.trim();
        unawaited(widget.controller.persistSources());
      },
      // §393 A6 — каскад на regex-фильтры Направлений (см. подписку).
      onTagPrefixCommitted: (_) => unawaited(_commitTagPrefix()),
      onSetDetourMode: _setDetourMode,
      onRegisterDetourServersChanged: (val) {
        setState(() => widget.entry.registerDetourServers = val);
        unawaited(widget.controller.persistSources());
      },
      onRegisterDetourInAutoChanged: (val) {
        setState(() => widget.entry.registerDetourInAuto = val);
        unawaited(widget.controller.persistSources());
      },
      onShowOverrideDetourPicker: () => _showOverrideDetourPicker(),
      onReplaceDetourChainChanged: (val) {
        setState(() => widget.entry.replaceDetourChain = val);
        unawaited(widget.controller.persistSources());
      },
      // Subscription-only колбэки — для папки блок скрыт
      // (`entry.list is SubscriptionServers` false), no-op заглушки.
      onCopyUrl: () {},
      onShowIntervalPicker: () {},
      onShowOnUpdateActionPicker: () {}, // §323
      onRefreshNow: () {},
      onEditSource: () {},
    );
  }

  DetourMode get _detourMode {
    if (!widget.entry.useDetourServers) return DetourMode.none;
    if (widget.entry.overrideDetour.isNotEmpty) return DetourMode.override;
    return DetourMode.use;
  }

  void _setDetourMode(DetourMode mode) {
    setState(() {
      switch (mode) {
        case DetourMode.use:
          widget.entry.useDetourServers = true;
          widget.entry.overrideDetour = '';
        case DetourMode.override:
          widget.entry.useDetourServers = true;
          if (widget.entry.overrideDetour.isEmpty) {
            unawaited(_showOverrideDetourPicker());
          }
        case DetourMode.none:
          widget.entry.useDetourServers = false;
          widget.entry.overrideDetour = '';
      }
    });
    unawaited(widget.controller.persistSources());
  }

  Future<void> _showOverrideDetourPicker() async {
    // §239 — кандидаты: «свободные» одиночки + члены СВОЕЙ папки (интра-цель
    // хранится голым тегом; exempt-набор в билдере не даёт циклов через цель).
    // §248 — свежие Направления (могли измениться, пока экран открыт).
    await _loadDirections();
    if (!mounted) return;
    final chosen = await showDetourTargetPicker(
      context,
      controller: widget.controller,
      directions: _directions,
      currentFolder: _folder,
    );
    if (chosen == null || !mounted) return;
    setState(() {
      widget.entry.overrideDetour = chosen.storeValue;
      if (chosen.storeValue.isNotEmpty) widget.entry.useDetourServers = true;
    });
    unawaited(widget.controller.persistSources());
  }
}

/// Строка члена папки: toggle + имя ноды + протокол/адрес. Grab-strip слева
/// для drag-reorder (§098-паттерн).
class _MemberTile extends StatelessWidget {
  const _MemberTile({
    required this.member,
    required this.dragIndex,
    required this.folderEnabled,
    required this.onToggle,
    required this.onLongPress,
    required this.onTap,
    this.reorderable = true,
    this.isChainLink = false,
    this.onProbeBadgeTap,
    this.probe,
    this.thresholds = const ProbeThresholds(),
  });

  final FolderMember member;
  final int dragIndex;

  /// §236 UI-rework — false при активном фильтре: grab-strip скрыта (drag по
  /// индексам отфильтрованного вида ломал бы состав).
  final bool reorderable;

  /// §239 — член служит интра-целью detour другого члена (⚙ как у звеньев
  /// подписки; видимость в селекторах гейтится register-тогглами папки).
  final bool isChainLink;
  final bool folderEnabled;
  final VoidCallback onToggle;
  final VoidCallback onLongPress;
  final VoidCallback onTap;

  /// Тап по бейджу результата — показать текст ошибки (диагностика err).
  final VoidCallback? onProbeBadgeTap;

  /// §236 — результат последнего Test servers (null = не тестировался).
  final ProbeResult? probe;
  final ProbeThresholds thresholds;

  /// §236 — бейдж результата теста; общий виджет [ProbeBadge] (§339).
  Widget? _probeBadge(BuildContext context, ThemeData theme) {
    final r = probe;
    if (r == null) return null;
    return ProbeBadge(result: r, thresholds: thresholds, onTap: onProbeBadgeTap);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final node = member.node;
    final active = member.enabled && folderEnabled;
    final muted = theme.colorScheme.onSurfaceVariant;
    var title = node == null
        ? getLocalText.s("Unreadable entry")
        : (node.label.isNotEmpty ? node.label : node.tag);
    if (isChainLink) title = '⚙ $title'; // §239 — авто-маркировка звена
    final subtitle = node == null
        ? getLocalText.s("Tap to edit or delete")
        : '${node.protocol.toUpperCase()} · ${node.server}:${node.port}';

    final tile = ListTile(
      contentPadding: EdgeInsets.zero,
      leading: SizedBox(
        width: 40,
        child: Switch(
          value: member.enabled,
          onChanged: (_) => onToggle(),
        ),
      ),
      title: Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w500,
          color: active ? null : muted,
          fontStyle: node == null ? FontStyle.italic : null,
        ),
      ),
      subtitle: Text(subtitle,
          style: TextStyle(fontSize: 12, color: muted),
          maxLines: 1,
          overflow: TextOverflow.ellipsis),
      trailing: _probeBadge(context, theme),
      onLongPress: onLongPress,
      onTap: onTap,
    );
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (reorderable) ReorderGrabStrip(index: dragIndex),
          Expanded(
            child: Column(
              children: [
                tile,
                const Divider(height: 1),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
