import 'dart:async';

import 'package:flutter/material.dart';

import '../controllers/home_controller.dart';
import '../controllers/subscription_controller.dart';
import '../models/direction.dart';
import '../models/config_node.dart';
import '../models/dependency_graph.dart';
import '../services/probe/chain_layer_probe.dart';
import '../services/runtime_chain.dart';
import '../services/settings_storage.dart';
import '../vpn/cc_channel.dart';
import '../widgets/chain_positions_block.dart';
import '../widgets/node_diagnostics_tab.dart';
import '../widgets/pool_view_dialog.dart';
import 'owner_navigation.dart';
import '../services/l10n/locale_controller.dart';

/// §258 — экран деталей outbound'а («View details» из меню ноды): вкладки
/// **Overview** (основные параметры + рантайм-цепочка detour, хопы
/// кликабельны → экран владельца) и **JSON** (прежний read-only дамп §099
/// с Copy-аффордансом в AppBar). §355 — третья вкладка **Dependents**
/// (кто зависит от этой ноды по detour/Направлениям) — видна только когда
/// зависимые есть; ⚠-метка мёртвого корня в списке нод открывает экран
/// сразу на ней ([openDependents]).
class OutboundViewScreen extends StatefulWidget {
  const OutboundViewScreen({
    super.key,
    required this.tag,
    required this.kind,
    required this.json,
    required this.detourCount,
    required this.onCopy,
    required this.config,
    required this.subController,
    required this.homeController,
    this.openDependents = false,
  });

  /// §355 — открыть сразу вкладку Dependents (тап по ⚠-метке). Если
  /// зависимых нет (вкладка скрыта) — обычный Overview.
  final bool openDependents;

  final String tag;
  final String kind;
  final String json;

  /// §099 — число detour-хопов у ноды (0 = нет). Определяет вид Copy-аффорданса
  /// и лейбл «server + detour(s)».
  final int detourCount;

  /// Копирование JSON-варианта (перенесено из контекстного меню ноды, §099).
  /// `mode`: `'server'` | `'detour'` | `'both'` → `copyNodeJson`.
  final void Function(String mode) onCopy;

  /// §258 — распарсенный собранный конфиг (источник параметров и цепочки).
  final ParsedConfig config;

  /// §258 — навигация по хопам (openTagOwner) требует оба контроллера.
  final SubscriptionController subController;
  final HomeController homeController;

  @override
  State<OutboundViewScreen> createState() => _OutboundViewScreenState();
}

class _OutboundViewScreenState extends State<OutboundViewScreen> {
  late final TextEditingController _jsonCtrl;

  // §258 — Направления: подпись Направлений хопов «⚙ label» + Направление-ветка
  // навигации. Цепочка строится после загрузки (initState → _load).
  List<Direction> _directions = const [];
  List<RuntimeHop> _hops = const [];

  /// §344 — живой пул round_robin-группы (§208 `getPool`). `null` = ещё не
  /// спросили / клиент недоступен (туннель down, §209) — НЕ пустой пул.
  /// Снимается один раз при открытии: unary-RPC, дёргать на ребилд нельзя.
  List<CcPoolSlot>? _pool;

  /// §344 — режим группы (§322 §6.1: round_robin-Направление или `balancer{}` в
  /// конфиге). Не-группа — всегда false.
  bool get _isBalancer =>
      _isGroupNode && widget.homeController.isRoundRobinAuto(widget.tag);

  bool get _isGroupNode {
    final t = widget.config[widget.tag]?.type;
    return t == 'urltest' || t == 'selector';
  }

  /// §394 — позиции цепочки из СОБРАННОГО конфига (`null` = узел не цепочка).
  /// Оттуда, а не из списка источников: ядро запустило именно собранное, и
  /// послойная проба обязана мерить работающий маршрут.
  List<String>? get _chainHops =>
      chainHopsFromConfig(widget.config[widget.tag]?.raw);

  @override
  void initState() {
    super.initState();
    _jsonCtrl = TextEditingController(text: widget.json);
    _hops = runtimeChainOf(widget.tag, widget.config, directions: _directions);
    unawaited(_load());
  }

  @override
  void dispose() {
    _jsonCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final directions = await SettingsStorage.getDirections();
    if (!mounted) return;
    setState(() {
      _directions = directions;
      _hops = runtimeChainOf(widget.tag, widget.config, directions: directions);
    });
    // §344 — живой состав пула. Только для round_robin: у least_test пул
    // пуст по контракту ядра, спрашивать нечего.
    if (!_isBalancer) return;
    final pool = await widget.homeController.getPool(widget.tag);
    if (!mounted) return;
    setState(() => _pool = pool);
  }

  void _onHopTap(RuntimeHop hop) => _onTagTap(hop.tag);

  void _onTagTap(String tag) {
    unawaited(openTagOwner(
      context,
      tag,
      subController: widget.subController,
      homeController: widget.homeController,
      directions: _directions,
      onOwnerNotFound: () {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(getLocalText.s("Source not found in your lists"))),
        );
      },
    ));
  }

  @override
  Widget build(BuildContext context) {
    // §099 — лейбл «both»: единственное «detour» или «detours(N)» при N>1.
    final bothLabel = widget.detourCount > 1
        ? 'Copy server + detours(${widget.detourCount})'
        : 'Copy server + detour';
    // §355 — вкладка Dependents: sick-срез (транзитивные жертвы мёртвого
    // корня) приоритетнее статического «кто через меня ходит». Пусто → нет
    // вкладки (не показываем пустую).
    final sickDependents =
        widget.homeController.state.sickRoots[widget.tag];
    final dependents = sickDependents ??
        widget.homeController.directDependentsOf(widget.tag);
    final hasDependents = dependents.isNotEmpty;
    return DefaultTabController(
      // §392 — +1 вкладка Diagnostics; Dependents по-прежнему условная, и
      // индекс её открытия (openDependents) не меняется — она перед новой.
      length: hasDependents ? 4 : 3,
      initialIndex: (widget.openDependents && hasDependents) ? 2 : 0,
      child: Scaffold(
        appBar: AppBar(
          title: Text('${widget.kind} · ${widget.tag}',
              overflow: TextOverflow.ellipsis),
          bottom: TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: [
              Tab(text: getLocalText.s("Overview")),
              // l10n-exempt: acronym, same in all locales
              const Tab(text: 'JSON'),
              if (hasDependents) Tab(text: getLocalText.s("Dependents")),
              Tab(text: getLocalText.s("Diagnostics")),
            ],
          ),
          actions: [
            // §099 — без detour: простая кнопка Copy (JSON ноды). С detour:
            // выпадашка (Copy server JSON / Copy detour / Copy server + detour(s)).
            if (widget.detourCount > 0)
              PopupMenuButton<String>(
                tooltip: getLocalText.s("Copy"),
                icon: const Icon(Icons.content_copy),
                onSelected: widget.onCopy,
                itemBuilder: (_) => [
                  PopupMenuItem(
                    value: 'server',
                    child: ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.content_copy, size: 20),
                      title: Text(getLocalText.s("Copy server JSON")),
                    ),
                  ),
                  PopupMenuItem(
                    value: 'detour',
                    child: ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.alt_route, size: 20),
                      title: Text(getLocalText.s("Copy detour")),
                    ),
                  ),
                  PopupMenuItem(
                    value: 'both',
                    child: ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.copy_all, size: 20),
                      title: Text(bothLabel),
                    ),
                  ),
                ],
              )
            else
              IconButton(
                tooltip: getLocalText.s("Copy JSON"),
                icon: const Icon(Icons.content_copy),
                onPressed: () => widget.onCopy('server'),
              ),
          ],
        ),
        body: SafeArea(
          child: TabBarView(
            children: [
              _buildOverviewTab(context),
              _buildJsonTab(context),
              if (hasDependents)
                _buildDependentsTab(
                    context, dependents, sick: sickDependents != null),
              // §392 — экран знает узел ТОЛЬКО по тегу собранного конфига
              // (NodeSpec тут нет), поэтому probe-ветка недоступна: при
              // выключенном VPN вкладка объяснит, откуда проверять.
              // §394 — у цепочки сверху свой блок: послойная проба.
              NodeDiagnosticsTab(
                liveTag: widget.tag,
                header: _chainHops == null
                    ? null
                    : ChainPositionsBlock(
                        chainTag: widget.tag, hops: _chainHops!),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ─── Dependents (§355) ─────────────────────────────────────────────────

  /// Список зависимых: при [sick] — транзитивные жертвы мёртвого корня
  /// (warning-тон), иначе — статический срез «кто через меня ходит».
  /// Тап по ноде — навигация к владельцу (как хопы Overview); DNS-серверы
  /// не кликабельны (у них нет экрана-владельца).
  Widget _buildDependentsTab(
    BuildContext context,
    List<DependentRef> dependents, {
    required bool sick,
  }) {
    final cs = Theme.of(context).colorScheme;
    // DNS-жертвы сверху — они самые коварные (§355: тихо не резолвятся).
    final sorted = [...dependents]
      ..sort((a, b) {
        if (a.isDns != b.isDns) return a.isDns ? -1 : 1;
        return a.tag.compareTo(b.tag);
      });
    String subtitleOf(DependentRef d) {
      final via = d.via;
      if (via == null) {
        return d.isDns
            ? getLocalText.s("DNS server — direct detour")
            : getLocalText.s("Node — direct detour");
      }
      final label = _directions
          .where((c) => c.tag == via)
          .map((c) => c.label)
          .firstOrNull ??
          via;
      return d.isDns
          ? getLocalText.s('DNS server — via "%1\$s"', label)
          : getLocalText.s('Node — via "%1\$s"', label);
    }

    return ListView(
      padding: const EdgeInsets.only(bottom: 24), // bottom-inset: handled — body в SafeArea
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Row(
            children: [
              Icon(
                sick ? Icons.warning_amber_rounded : Icons.account_tree_outlined,
                size: 20,
                color: sick ? cs.error : cs.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  sick
                      ? getLocalText.s(
                          'These depend on dead node "%1\$s" and are not working:',
                          widget.tag)
                      : getLocalText.s("These route through this node:"),
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: cs.onSurfaceVariant),
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        for (final d in sorted)
          ListTile(
            dense: true,
            leading: Icon(
              d.isDns ? Icons.dns_outlined : Icons.lan_outlined,
              size: 20,
              color: sick ? cs.error : cs.onSurfaceVariant,
            ),
            title:
                Text(d.tag, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(subtitleOf(d),
                maxLines: 1, overflow: TextOverflow.ellipsis),
            onTap: d.isDns ? null : () => _onTagTap(d.tag),
          ),
      ],
    );
  }

  // ─── Overview ──────────────────────────────────────────────────────────

  Widget _buildOverviewTab(BuildContext context) {
    final node = widget.config[widget.tag];
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24), // bottom-inset: handled — body в SafeArea
      children: [
        _sectionHeader(context, 'Parameters'),
        ..._paramRows(context, node),
        const SizedBox(height: 16),
        _sectionHeader(context, 'Route'),
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(
            getLocalText.s("Live path in packet order. Tap a hop to open its source."),
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        ..._routeRows(context),
      ],
    );
  }

  Widget _sectionHeader(BuildContext context, String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }

  /// Основные параметры из `ConfigNode` (§091/§102/§103): без ре-парса JSON.
  List<Widget> _paramRows(BuildContext context, ConfigNode? node) {
    if (node == null) {
      return [_kvRow(context, 'Type', 'not in current config')];
    }
    final raw = node.raw;
    final server = raw['server'];
    final port = raw['server_port'];
    final members = raw['outbounds'];
    final typeLabel =
        node.kind == 'endpoint' ? '${node.type} · endpoint' : node.type;
    // §344 — режим группы: least_test («один быстрейший») и round_robin
    // («пул») ведут себя противоположно, а выглядели одинаково. Параметры
    // балансировщика — из raw, они эмитятся только под round_robin (§208).
    final balancer = raw['balancer'];
    final pool = balancer is Map ? balancer['pool'] : null;
    final poolTolerance =
        balancer is Map ? balancer['pool_tolerance'] : null;
    return [
      _kvRow(context, 'Type', typeLabel),
      if (server is String && server.isNotEmpty)
        _kvRow(context, 'Server', port == null ? server : '$server:$port'),
      if (node.transportLabel != null)
        _kvRow(context, 'Transport', node.transportLabel!),
      if (node.securityLabel != null)
        _kvRow(context, 'Security', node.securityLabel!),
      if (_isGroupNode)
        _kvRow(
            context,
            'Mode',
            _isBalancer
                ? getLocalText.s("Load balance")
                : getLocalText.s("Fastest")),
      if (_isBalancer && pool != null) _kvRow(context, 'Pool', '$pool'),
      if (_isBalancer && poolTolerance is int && poolTolerance > 0)
        _kvRow(context, 'Pool tolerance', '$poolTolerance ms'),
      if (members is List) _membersTile(context, members),
    ];
  }

  /// §344 — состав группы разворачиваемым списком (было мёртвое число).
  ///
  /// Источников ДВА и путать их нельзя (§322 §6.1): в конфиге весь состав,
  /// а в работе у round_robin только `pool` штук. Показываем состав из
  /// конфига и помечаем тех, кто сейчас в живом пуле (`getPool`) — показать
  /// одно вместо другого было бы враньём.
  Widget _membersTile(BuildContext context, List<dynamic> members) {
    final cs = Theme.of(context).colorScheme;
    final slots = _pool ?? const <CcPoolSlot>[];
    final byTag = {for (final s in slots) s.tag: s};
    return Theme(
      // убираем разделители ExpansionTile — раздел плотный, kv-строки рядом
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(bottom: 4),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        title: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 90,
              child: Text(getLocalText.s("Members"),
                  style:
                      TextStyle(fontSize: 13, color: cs.onSurfaceVariant)),
            ),
            Expanded(
              child: Text(
                // под балансировщиком — «состав · сколько в работе»
                _isBalancer && slots.isNotEmpty
                    ? '${members.length} · '
                        '${getLocalText.plural("%d in pool", slots.length)}'
                    : '${members.length}',
                style: const TextStyle(fontSize: 13, fontFamily: 'monospace'),
              ),
            ),
          ],
        ),
        children: [
          for (final m in members)
            _memberRow(context, '$m', inPool: byTag['$m']),
        ],
      ),
    );
  }

  /// Строка участника: галка «сейчас в пуле» + тег + delay живого слота.
  ///
  /// Номера слотов здесь НЕ показываем (решение юзера 02.08.2026) — слот
  /// это деталь ротации, она к месту в попапе «View pool», а в составе
  /// группы важно лишь «в работе или нет». Клик ведёт на владельца.
  Widget _memberRow(BuildContext context, String tag, {CcPoolSlot? inPool}) {
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      onTap: () => _onTagTap(tag),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(
          children: [
            SizedBox(
              width: 24,
              child: inPool == null
                  ? null
                  : Icon(Icons.check, size: 15, color: cs.onSurfaceVariant),
            ),
            Expanded(
              child: Text(tag,
                  style: TextStyle(
                      fontSize: 13,
                      color:
                          inPool == null ? cs.onSurfaceVariant : cs.onSurface),
                  overflow: TextOverflow.ellipsis),
            ),
            if (inPool != null && inPool.delay > 0) ...[
              const SizedBox(width: 8),
              // l10n-exempt: unit symbol, same in all locales
              Text('${inPool.delay} ms',
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: poolDelayColor(context, inPool.delay))),
            ],
          ],
        ),
      ),
    );
  }

  Widget _kvRow(BuildContext context, String k, String v) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 90,
            child: Text(k,
                style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant)),
          ),
          Expanded(
            child: Text(v,
                style:
                    const TextStyle(fontSize: 13, fontFamily: 'monospace')),
          ),
        ],
      ),
    );
  }

  /// Цепочка «по ходу пакета»: Phone → хопы → Internet. Обрыв на
  /// неразрешённом селекторе (туннель down) / битом теге — строка-эллипсис
  /// сразу после Phone (обрыв всегда на глубоком, Phone-краю цепочки).
  /// Первый хоп-группа = выбор не разрешён: при известном выборе глубже
  /// лежал бы сам pick. Битый тег (`isUnknown`) эллипсиса не получает — его
  /// хоп-строка сама говорит «not in config» (и §172 такие detour лечит ещё
  /// при сборке).
  List<Widget> _routeRows(BuildContext context) {
    // §344 — у балансировщика одного выбранного НЕТ (§322 §6.3), поэтому
    // цепочка обрывается на самой группе, и это не «обрыв» в смысле §258:
    // эллипсис «подключитесь» тут был бы враньём — путь известен, он просто
    // не единственный. Вместо него — свёрнутый хоп пула.
    // §344 — под балансировщиком «выбранного» узла нет (§322 §6.3): хоп,
    // добытый через выбор группы, из цепочки убираем — иначе экран говорит
    // разом «трафик размазан по слотам» и «идёт вот через этот».
    final hops = _isBalancer
        ? [for (final h in _hops) if (!h.viaSelection) h]
        : _hops;
    final truncated = !_isBalancer && hops.isNotEmpty && hops.first.isGroup;
    return [
      _endpointRow(context, Icons.smartphone, 'Phone'),
      if (truncated) _ellipsisRow(context),
      for (var i = 0; i < hops.length; i++)
        _hopRow(context, hops[i], isSelf: i == hops.length - 1),
      // Пул — ПОСЛЕ группы: пакет идёт Phone → группа → её пул → Internet.
      if (_isBalancer) _poolHopTile(context),
      _endpointRow(context, Icons.public, 'Internet'),
    ];
  }

  /// §344 — пул как ОДНО звено пути с раскрытием (решение юзера 02.08.2026).
  ///
  /// Ветками слоты не рисуем: раздел обещает «живой путь в порядке следования
  /// пакета», а пакет идёт через ОДИН узел пула — ветвление ломало бы это
  /// обещание. Плюс на пулах в 20–30 узлов ветки растянули бы раздел на
  /// несколько экранов, а большие пулы — целевой сценарий §208.
  Widget _poolHopTile(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final slots = _pool;
    // Туннель down (§209 `null`) или пул пуст — состав неизвестен; звено
    // всё равно показываем, оно часть пути.
    final count = slots?.length ?? 0;
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(left: 28, bottom: 4),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        leading: Icon(Icons.account_tree_outlined,
            size: 20, color: cs.onSurfaceVariant),
        title: Text(
          count > 0
              ? getLocalText.plural("%d nodes in pool", count)
              : getLocalText.s("Pool"),
          style: const TextStyle(fontSize: 14),
        ),
        subtitle: Text(
          slots == null
              ? getLocalText.s("connect to see the live pool")
              : getLocalText.s("traffic is spread across slots"),
          style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
        ),
        children: [
          for (final s in slots ?? const <CcPoolSlot>[])
            poolSlotRow(context, s, onTap: () => _onTagTap(s.tag)),
        ],
      ),
    );
  }

  Widget _endpointRow(BuildContext context, IconData icon, String label) {
    final cs = Theme.of(context).colorScheme;
    return ListTile(
      dense: true,
      visualDensity: VisualDensity.compact,
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon, size: 20, color: cs.onSurfaceVariant),
      title: Text(label,
          style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant)),
    );
  }

  Widget _ellipsisRow(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ListTile(
      dense: true,
      visualDensity: VisualDensity.compact,
      contentPadding: EdgeInsets.zero,
      leading: Icon(Icons.more_vert, size: 20, color: cs.onSurfaceVariant),
      title: Text(
        getLocalText.s("connect to see the full path"),
        style: TextStyle(
            fontSize: 12,
            fontStyle: FontStyle.italic,
            color: cs.onSurfaceVariant),
      ),
    );
  }

  Widget _hopRow(BuildContext context, RuntimeHop hop,
      {required bool isSelf}) {
    final cs = Theme.of(context).colorScheme;
    // §274 — ⚙ по флагу Направления (displayLabel), а не по факту «хоп — Направление»:
    // единый source-of-truth маркера.
    final ch = hop.direction;
    final title = ch != null ? ch.displayLabel : hop.tag;
    final subtitle = [
      if (hop.isUnknown) 'not in config' else hop.type,
      if (hop.viaSelection) 'current pick',
      if (isSelf) 'this node',
    ].join(' · ');
    final icon = hop.isUnknown
        ? Icons.help_outline
        : hop.isGroup
            ? Icons.hub_outlined
            : Icons.dns_outlined;
    return ListTile(
      dense: true,
      visualDensity: VisualDensity.compact,
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon, size: 20,
          color: isSelf ? cs.primary : cs.onSurfaceVariant),
      title: Text(
        title,
        style: TextStyle(
          fontSize: 14,
          fontWeight: isSelf ? FontWeight.w600 : FontWeight.w400,
        ),
      ),
      subtitle: Text(subtitle,
          style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
      trailing: Icon(Icons.chevron_right, size: 18, color: cs.onSurfaceVariant),
      onTap: () => _onHopTap(hop),
    );
  }

  // ─── JSON ───────────────────────────────────────────────────────────────

  Widget _buildJsonTab(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(12),
      child: TextField(
        controller: _jsonCtrl,
        readOnly: true,
        maxLines: null,
        expands: true,
        textAlignVertical: TextAlignVertical.top,
        style: TextStyle(
          fontFamily: 'monospace',
          fontSize: 12,
          color: theme.colorScheme.onSurface,
        ),
        decoration: InputDecoration(
          border: const OutlineInputBorder(),
          contentPadding: const EdgeInsets.all(10),
          filled: true,
          fillColor: theme.colorScheme.surfaceContainerLow,
        ),
      ),
    );
  }
}
