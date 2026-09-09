import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../controllers/subscription_controller.dart';
import '../services/ui_helpers.dart';
import '../services/warp/masquerade_params.dart';
import '../services/warp/warp_account.dart';
import '../services/warp/masque_account.dart';
import '../services/warp/warp_endpoint_picker.dart';
import '../services/warp/scan/scan_pool.dart';
import '../services/settings_storage.dart';
import 'folder_detail_screen.dart';
import 'warp_experiment_screen.dart';
import '../services/l10n/locale_controller.dart';
import '../widgets/safe_bottom.dart';

/// §025 — Full-screen визард «Get WARP». Открывается из overflow-меню
/// Subscriptions. Один тап «Register» для free; license/endpoint опциональны
/// под «Advanced».
///
/// Поведение: `subController.addWarp(...)` регистрирует устройство в Cloudflare
/// (приватный ключ генерится на телефоне) и добавляет готовый WireGuard-узел.
/// После успеха → [onAdded] (regenerate config + save в parent) → pop.
class WarpWizardScreen extends StatefulWidget {
  const WarpWizardScreen({
    super.key,
    required this.subController,
    required this.onAdded,
  });

  final SubscriptionController subController;
  final Future<void> Function() onAdded;

  @override
  State<WarpWizardScreen> createState() => _WarpWizardScreenState();
}

class _WarpWizardScreenState extends State<WarpWizardScreen> with SnackHelper {
  final _license = TextEditingController();
  final _endpoint =
      TextEditingController(text: WarpAccount.defaultEndpoint);

  // §136/§143 — masquerade-параметры (Advanced). Пустой SNI(=id) → рандом из пула.
  final _sni = TextEditingController(); // id (домен маскировки)
  List<String> _sniPool = const []; // подсказки для DropdownMenu (WG §136)
  List<String> _masqueSniPool = const []; // §130 — SNI-пул для MASQUE-комбобокса
  // §143 — ip (протокол маскировки): quic/dns/stun/sip; ib (браузер) при quic.
  String _masqIp = 'quic';
  String _masqIb = 'chrome';
  final _jc = TextEditingController(text: '4');
  final _jmin = TextEditingController(text: '40');
  final _jmax = TextEditingController(text: '70');
  // §304 — persistent keepalive (секунды) для WG/AWG-узла. Держит NAT-маппинг
  // и WG-сессию живыми при простое (иначе пинг деградирует в err). Пусто/0 =
  // выключено. Дефолт 25 (типовое значение WARP).
  final _keepalive = TextEditingController(text: '25');

  bool _forceNew = false;
  bool _busy = false;
  WarpAccount? _result;

  // §130 — транспорт WARP: 'wireguard' (дефолт) | 'masque'. MASQUE использует
  // ECDSA-регистрацию и Outbound type:masque (другой пул выходных нод).
  String _transport = 'wireguard';
  // §393/SPEC 074 — дефолт 'auto': h3-нога с бюджетом 3s, фолбэк h2 (TCP).
  // Работает там, где QUIC/UDP резан (и за TCP-хопами цепочек); нога-победитель
  // запоминается на процесс. Пулы портов h3/h2 идентичны (warp_endpoints.json),
  // поэтому один endpoint честен для обеих ног.
  String _masqueNetwork = 'auto'; // auto | h3 (QUIC) | h2 (HTTP/2)
  final _masqueSni = TextEditingController(); // опц. SNI override
  // §130 — тюнинг ресурсов: idle-suspend (минуты) и QUIC keepalive (секунды).
  // Пусто → дефолт ядра (5m / 30s). Плейсхолдеры показывают дефолт.
  final _masqueIdle = TextEditingController(); // минуты
  final _masqueKeepAlive = TextEditingController(); // секунды
  // §305 — ручной override endpoint MASQUE (IP + порт). Пусто → endpoint из
  // регистрации. Данные (блоки/порты) читаются из warp_endpoints.json через
  // _picker. Порт — combo из masque_ports_h3/h2 по транспорту + свободный ввод.
  final _masqueIp = TextEditingController();
  final _masquePort = TextEditingController();

  bool get _isMasque => _transport == 'masque';

  // §126/§136 — AmneziaWG обфускация (default off — обычный WARP).
  bool _obfuscate = false;
  // §142 — reserved (client_id): null = дефолт по галке (обфускация → off).
  // Юзер может переопределить чекбоксом в Advanced.
  bool? _includeReserved;

  WarpEndpointPicker? _picker; // §136 — для рандома endpoint/SNI
  bool _endpointAutoFilled = false; // §136 — endpoint в поле = наш авто-рандом
  // §386 — значение последнего авто-рандома. Комбобокс не даёт onChanged, поэтому
  // ручную правку/выбор из списка ловит listener на контроллере: текст ушёл от
  // последнего авто-значения → это уже не наш рандом, флаг снимается.
  String _lastAutoEndpoint = '';
  // §386 — пресеты для combobox'ов (endpoint WG / IP MASQUE), из asset.
  List<String> _endpointsPreset = const [];
  // §305 — v6-endpoint подставляем только если в системе включён IPv6.
  bool _ipv6Enabled = false;
  // §305 — сервер из последней MASQUE-регистрации (placeholder пустого IP-поля,
  // показывает КУДА пойдёт подключение, если IP не вписан). Дефолт ядра, если
  // регистрации ещё не было.
  String _masqueRegServer = MasqueAccount.defaultServer;

  @override
  void initState() {
    super.initState();
    // §386 — см. _lastAutoEndpoint. Заменяет прежний onChanged у TextField.
    _endpoint.addListener(() {
      if (_endpointAutoFilled && _endpoint.text != _lastAutoEndpoint) {
        setState(() => _endpointAutoFilled = false);
      }
    });
    // §305 — читаем системный флаг IPv6 (гейтит v6-рандом endpoint).
    SettingsStorage.getVar('ipv6_enabled', 'false').then((v) {
      if (mounted) setState(() => _ipv6Enabled = v.toLowerCase() == 'true');
    });
    // §305 — сервер из закешированной MASQUE-реги → placeholder пустого IP-поля.
    SettingsStorage.getMasqueAccount().then((acc) {
      if (mounted && acc != null) {
        setState(() => _masqueRegServer = acc.server);
      }
    });
    // §136 — подтягиваем picker (SNI-пул для dropdown + рандом endpoint/SNI).
    WarpEndpointPicker.load().then((p) {
      if (!mounted) return;
      setState(() {
        _picker = p;
        _sniPool = p.sniPool;
        _masqueSniPool = p.masqueSniPool;
        _endpointsPreset = p.endpointsPreset; // §386
        // SNI при открытии — конкретный случайный домен (не «Random»); юзер
        // может выбрать другой/вписать свой или рерольнуть кубиком.
        if (_sni.text.trim().isEmpty) _sni.text = p.randomSni();
        // §130 — MASQUE SNI тоже предзаполняем рандомом из masque-пула (не
        // оставляем дефолт ядра): маскировка под конкретный легит-домен из
        // старта, юзер может сменить/очистить/рерольнуть.
        if (_masqueSni.text.trim().isEmpty) {
          _masqueSni.text = p.randomMasqueSni();
        }
        // §305 — дефолтный порт = первый из набора текущего транспорта.
        _syncDefaultMasquePort(p);
      });
      // Если юзер успел включить обфускацию до загрузки picker — заполняем.
      if (_obfuscate && _endpointReplaceable) _fillRandomEndpoint();
    });
  }

  /// §136 — генерирует рандомный endpoint в поле (при включении обфускации).
  /// Помечает поле как авто-заполненное.
  void _fillRandomEndpoint() {
    final ep = _picker?.randomEndpoint(allowV6: _ipv6Enabled);
    if (ep != null) {
      setState(() {
        // §386 — сперва запоминаем авто-значение, потом пишем text: иначе
        // listener контроллера примет собственный рандом за ручную правку.
        _lastAutoEndpoint = ep;
        _endpoint.text = ep;
        _endpointAutoFilled = true;
      });
    }
  }

  /// §136 — кубик 🎲 у SNI: подставляет случайный домен из пула в поле.
  void _fillRandomSni() {
    final sni = _picker?.randomSni();
    if (sni != null && sni.isNotEmpty) {
      setState(() => _sni.text = sni);
    }
  }

  /// §130 — кубик 🎲 у MASQUE SNI: случайный домен из MASQUE-пула в поле.
  void _fillRandomMasqueSni() {
    final sni = _picker?.randomMasqueSni();
    if (sni != null && sni.isNotEmpty) {
      setState(() => _masqueSni.text = sni);
    }
  }

  /// §305 — дефолтный/консистентный порт для текущего транспорта: если поле
  /// пусто ИЛИ значение не из набора этого транспорта (h3↔h2 сменили) —
  /// ставим первый порт набора. Пустой набор → не трогаем.
  void _syncDefaultMasquePort([WarpEndpointPicker? picker]) {
    final ports = (picker ?? _picker)?.masquePortsFor(_masqueNetwork) ??
        const <int>[];
    if (ports.isEmpty) return;
    final cur = int.tryParse(_masquePort.text.trim());
    if (cur == null || !ports.contains(cur)) {
      _masquePort.text = '${ports.first}';
    }
  }

  /// §420 — хосты combobox MASQUE-endpoint под текущий транспорт: h3 —
  /// общие + h3-only (`.198.1`/`.199.1`), h2/auto — только общие.
  List<String> get _masqueHostsForNetwork =>
      _picker?.masqueHostsFor(_masqueNetwork) ?? const <String>[];

  /// §420 — при смене транспорта пресет-хост, которого нет в списке нового
  /// транспорта (выбрали h3 + `.198.1`, переключились на h2), сбрасываем:
  /// пустое поле = endpoint регистрации (placeholder), он живёт на обоих.
  /// Ручной IP (не из пресетов) не трогаем — это выбор юзера.
  void _syncMasqueHostForNetwork() {
    final cur = _masqueIp.text.trim();
    if (cur.isEmpty) return;
    final known = _picker?.masqueH3Hosts ?? const <String>[];
    if (known.contains(cur) && !_masqueHostsForNetwork.contains(cur)) {
      _masqueIp.clear();
    }
  }

  /// §305 — 🎲 у endpoint IP: случайный MASQUE-IP из блока + случайный порт из
  /// набора текущего транспорта.
  void _fillRandomMasqueIp() {
    // §305 — IP по текущему транспорту (h3 — только 4 живых хоста).
    final ip = _picker?.randomMasqueIp(network: _masqueNetwork);
    if (ip == null) return;
    final port = _picker?.randomMasquePortFor(_masqueNetwork);
    setState(() {
      _masqueIp.text = ip;
      if (port != null) _masquePort.text = '$port';
    });
  }

  /// §386 — пункт combobox-пресетов. Пометку "(recommended)" получает пункт,
  /// чьё значение равно ЯВНОМУ recommended-ключу asset'а (recommended_endpoint /
  /// recommended_host) — на любой позиции. Пустой [recommended] → без пометок.
  DropdownMenuEntry<String> _presetEntry(String value, String recommended) =>
      warpPresetEntry(value, recommended, getLocalText.s("(recommended)"));

  /// true если в поле endpoint — дефолт/пусто/наш авто-рандом (не вписан юзером
  /// вручную → можно перезаписать).
  bool get _endpointReplaceable {
    final v = _endpoint.text.trim();
    return v.isEmpty || v == WarpAccount.defaultEndpoint || _endpointAutoFilled;
  }

  /// §136 — снятие галки обфускации → все обфускация-поля в стандарт.
  /// Endpoint возвращаем к дефолту только если он был НАШИМ авто-рандомом
  /// (вписанный юзером свой IP:port не трогаем). QUIC-параметры (скрытые без
  /// галки) сбрасываем к дефолтам, чтобы повторное включение стартовало чисто.
  void _resetObfuscationFields() {
    setState(() {
      if (_endpointAutoFilled) {
        _endpoint.text = WarpAccount.defaultEndpoint;
        _endpointAutoFilled = false;
      }
      _includeReserved = null; // §142 — вернуть к дефолту по галке
      _sni.text = _picker?.randomSni() ?? ''; // свежий случайный домен
      _masqIp = 'quic'; // §143
      _masqIb = 'chrome';
      _jc.text = '4';
      _jmin.text = '40';
      _jmax.text = '70';
    });
  }

  @override
  void dispose() {
    _license.dispose();
    _endpoint.dispose();
    _sni.dispose();
    _masqueSni.dispose();
    _masqueIdle.dispose();
    _masqueKeepAlive.dispose();
    _masqueIp.dispose();
    _masquePort.dispose();
    _jc.dispose();
    _jmin.dispose();
    _jmax.dispose();
    _keepalive.dispose();
    super.dispose();
  }

  // ───────────────────────── §284 — WARP GENERATOR ─────────────────────────

  /// Генерирует случайные WARP-узлы (WG/AWG/h3/h2) в папку «WARP GENERATOR»
  /// и открывает её. Пробы не гоняет — пользователь тестирует штатной кнопкой
  /// Test в папке. Повторный запуск пересоздаёт папку.
  Future<void> _runGenerate() async {
    if (_picker?.scan == null || _busy) return;

    // §305 — параметры эксперимента (число нод + JSON-пул) на отдельном экране.
    final exp = await Navigator.of(context).push<({int count, ScanPool pool})>(
      MaterialPageRoute(builder: (_) => const WarpExperimentScreen()),
    );
    if (exp == null || !mounted) return;

    setState(() => _busy = true);
    int? folderIdx;
    try {
      folderIdx = await widget.subController.generateWarp(
          seedCount: exp.count, poolOverride: exp.pool);
    } catch (e) {
      if (mounted) {
        showSnack(getLocalText.s("Generation failed — no WARP account."));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted) return;

    if (folderIdx == null) {
      showSnack(widget.subController.lastScanNote ??
          getLocalText.s("Generation failed — no WARP account."));
      return;
    }
    // Замечание при частичном результате (напр. MASQUE выпал — только WG в папке).
    final note = widget.subController.lastScanNote;
    if (note != null) showSnack(note);
    // §305 — открываем папку «WARP GENERATOR» ЗАМЕНОЙ визарда в стеке
    // (pushReplacement): после генерации визард не нужен, «назад» из папки
    // должен вести на Servers, а не обратно в визард.
    final entry = widget.subController.entries[folderIdx];
    await Navigator.of(context).pushReplacement(MaterialPageRoute(
      builder: (_) => FolderDetailScreen(
        entry: entry,
        controller: widget.subController,
      ),
    ));
  }

  /// Собирает [QuicParams] из Advanced-полей (с дефолтами при пустых/битых).
  /// SNI-поле обычно содержит конкретный домен; пустое → register подставит
  /// рандом из пула (fallback в контроллере).
  QuicParams _buildQuicParams() {
    return QuicParams(
      sni: _sni.text.trim(),
      ip: _masqIp,
      ib: _masqIb,
      jc: int.tryParse(_jc.text.trim()) ?? 4,
      jmin: int.tryParse(_jmin.text.trim()) ?? 40,
      jmax: int.tryParse(_jmax.text.trim()) ?? 70,
    );
  }

  Future<void> _register() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      if (_isMasque) {
        await _registerMasque();
        return;
      }
      final endpoint = _endpoint.text.trim().isEmpty
          ? WarpAccount.defaultEndpoint
          : _endpoint.text.trim();
      final license = _license.text.trim();

      final account = await widget.subController.addWarp(
        licenseKey: license.isEmpty ? null : license,
        endpoint: endpoint,
        forceNew: _forceNew,
        obfuscate: _obfuscate,
        quicParams: _buildQuicParams(),
        includeReserved: _includeReserved,
        // §304 — пусто/битое → null (keepalive не пишется); 0 явно выключает.
        persistentKeepalive: int.tryParse(_keepalive.text.trim()),
      );

      if (!mounted) return;
      final err = widget.subController.lastError;
      if (account == null || err != null) {
        showSnack(err != null
            ? err.render()
            : getLocalText.s("WARP registration failed"));
        return;
      }
      setState(() => _result = account);
      await widget.onAdded();
      if (!mounted) return;
      showSnack(account.warpPlus
          ? getLocalText.s("Added WARP+ node")
          : getLocalText.s("Added WARP node"));
      Navigator.of(context).pop();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// §130 — регистрация MASQUE-транспорта (ECDSA + enroll).
  Future<void> _registerMasque() async {
    final sni = _masqueSni.text.trim();
    final ip = _masqueIp.text.trim();
    final account = await widget.subController.addMasque(
      vhttp: _masqueNetwork,
      sni: sni.isEmpty ? null : sni,
      idleTimeout: _durationOrNull(_masqueIdle.text, 'm'),
      keepAlive: _durationOrNull(_masqueKeepAlive.text, 's'),
      // §305 — ручной override endpoint. Пусто → сервер из регистрации.
      server: ip.isEmpty ? null : ip,
      port: int.tryParse(_masquePort.text.trim()),
      forceNew: _forceNew,
    );
    if (!mounted) return;
    final err = widget.subController.lastError;
    if (account == null || err != null) {
      showSnack(err != null
          ? err.render()
          : getLocalText.s("MASQUE registration failed"));
      return;
    }
    await widget.onAdded();
    if (!mounted) return;
    showSnack(getLocalText.s("Added MASQUE node"));
    Navigator.of(context).pop();
  }

  /// §130 — число из поля + единица → Go-duration (`"5m"`, `"30s"`). Пусто/ноль
  /// → null (ядро возьмёт свой дефолт). Только положительные целые.
  String? _durationOrNull(String raw, String unit) {
    final n = int.tryParse(raw.trim());
    if (n == null || n <= 0) return null;
    return '$n$unit';
  }

  // §219 — _showSnack вынесен в SnackHelper.showSnack (services/ui_helpers.dart).

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(getLocalText.s("Get WARP")),
        actions: [
          TextButton(
            onPressed: _busy ? null : () => Navigator.of(context).pop(),
            child: Text(getLocalText.s("Cancel")),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 24, 16, 32).withSafeBottom(context),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // §025 — официальный двухтональный логотип-облако Cloudflare
            // (Wikimedia Commons, ~2.8:1). Ширина = доля экрана (≈40%,
            // зажата 120..200 px), чтобы масштабировалось под любой телефон;
            // BoxFit.contain сохраняет пропорции и не обрезает макушку.
            Builder(builder: (context) {
              final w = MediaQuery.of(context).size.width;
              final logoW = (w * 0.40).clamp(120.0, 200.0);
              return Image.asset('assets/icons/cloudflare.png',
                  width: logoW, fit: BoxFit.contain);
            }),
            const SizedBox(height: 16),
            Text(
              // l10n-exempt: brand name heading
              'Cloudflare WARP',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            Text(
              getLocalText.s("Registers a free WireGuard tunnel on Cloudflare. The private key is generated on this device and never leaves it."),
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: cs.onSurfaceVariant,
                  ),
            ),
            const SizedBox(height: 16),
            // §130 — выбор транспорта WARP. WireGuard (дефолт) или MASQUE
            // (CONNECT-IP over HTTP/3/2 — другой пул выходных нод, иностранные IP).
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(
                    value: 'wireguard',
                    // l10n-exempt: protocol name
                    label: Text('WireGuard'),
                    icon: Icon(Icons.vpn_key_outlined)),
                ButtonSegment(
                    value: 'masque',
                    // l10n-exempt: protocol name
                    label: Text('MASQUE'),
                    icon: Icon(Icons.hub_outlined)),
              ],
              selected: {_transport},
              onSelectionChanged: _busy
                  ? null
                  : (sel) => setState(() => _transport = sel.first),
            ),
            // §284 — GENERATE: 100 случайных WARP-узлов → папка «WARP GENERATOR».
            // Виден только если в asset есть scan-пул.
            if (_picker?.scan != null) ...[
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _busy ? null : _runGenerate,
                icon: _busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.science_outlined),
                label: Text(getLocalText.s("Make experiment")),
              ),
            ],
            const SizedBox(height: 16),
            // §130 — MASQUE: транспорт h3/h2 + опц. SNI. Обфускация и WG-Advanced
            // не применяются (MASQUE сам маскируется под HTTPS/QUIC).
            if (_isMasque) ...[
              Card(
                margin: EdgeInsets.zero,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        getLocalText.s("MASQUE tunnels IP over HTTP/3 (QUIC) to Cloudflare — standard HTTPS transport, and the exit IP is often in another country."),
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: cs.onSurfaceVariant,
                            ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          _label('Transport'),
                          const SizedBox(width: 16),
                          Expanded(
                            child: DropdownButtonFormField<String>(
                              initialValue: _masqueNetwork,
                              isDense: true,
                              decoration: const InputDecoration(
                                isDense: true,
                                border: OutlineInputBorder(),
                                contentPadding: EdgeInsets.symmetric(
                                    horizontal: 12, vertical: 8),
                              ),
                              items: const [
                                DropdownMenuItem(
                                    value: 'auto',
                                    // l10n-exempt: protocol name
                                    child: Text('Auto (h3 → h2)')),
                                DropdownMenuItem(
                                    value: 'h3',
                                    // l10n-exempt: protocol name
                                    child: Text('HTTP/3 (QUIC)')),
                                DropdownMenuItem(
                                    value: 'h2',
                                    // l10n-exempt: protocol name
                                    child: Text('HTTP/2 (TCP)')),
                              ],
                              onChanged: _busy
                                  ? null
                                  : (v) => setState(() {
                                        _masqueNetwork = v ?? 'auto';
                                        // §305 — порт h3≠h2: пересинхронизируем
                                        // под новый транспорт.
                                        _syncDefaultMasquePort();
                                        _syncMasqueHostForNetwork(); // §420
                                      }),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        _masqueNetwork == 'h2'
                            ? getLocalText.s("HTTP/2 over TCP — use where QUIC/UDP is blocked.")
                            : _masqueNetwork == 'auto'
                                ? getLocalText.s("Tries HTTP/3 first, falls back to HTTP/2 where QUIC/UDP is blocked — best for hop chains.")
                                : getLocalText.s("HTTP/3 over QUIC — the default, fastest path."),
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: cs.onSurfaceVariant,
                            ),
                      ),
                      // §305 — ручной endpoint IP:port. Пусто → сервер из
                      // регистрации. Порты РАЗДЕЛЬНЫ по транспорту (h3/h2 живут
                      // на разных) — combo подтягивает нужный набор из asset.
                      const SizedBox(height: 12),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          // §386 — combobox: device-verified h3-хосты + свободный
                          // ввод; кубик рядом (рандом IP из блока + порт).
                          Expanded(
                            flex: 3,
                            child: LayoutBuilder(
                              builder: (ctx, c) => DropdownMenu<String>(
                                controller: _masqueIp,
                                enabled: !_busy,
                                width: c.maxWidth,
                                requestFocusOnTap: true,
                                menuHeight: 280,
                                label: Text(getLocalText.s("Endpoint IP")),
                                hintText: _masqueRegServer,
                                dropdownMenuEntries: [
                                  for (final h in _masqueHostsForNetwork)
                                    _presetEntry(h,
                                        _picker?.recommendedMasqueHost ?? ''),
                                ],
                              ),
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.casino_outlined),
                            tooltip: getLocalText.s("Pick another random IP:port"),
                            onPressed: _busy ? null : _fillRandomMasqueIp,
                          ),
                          const SizedBox(width: 8),
                          // Порт — editable-combo той же высоты, что IP-поле
                          // (DropdownButtonFormField isDense = высота TextField).
                          Expanded(
                            flex: 2,
                            child: DropdownButtonFormField<String>(
                              // Текущее значение порта; если его нет в наборе
                              // транспорта — всё равно валидно (custom).
                              initialValue: _masquePort.text.isEmpty
                                  ? null
                                  : _masquePort.text,
                              isExpanded: true,
                              decoration: _input('443').copyWith(
                                labelText: getLocalText.s("Port"),
                              ),
                              items: [
                                for (final p in (_picker
                                        ?.masquePortsFor(_masqueNetwork) ??
                                    const <int>[]))
                                  DropdownMenuItem(
                                      value: '$p', child: Text('$p')),
                              ],
                              onChanged: _busy
                                  ? null
                                  : (v) => setState(
                                      () => _masquePort.text = v ?? ''),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        getLocalText.s("Leave IP empty to use the server from registration. HTTP/3 only works on a few Cloudflare addresses, HTTP/2 works across the whole block."),
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: cs.onSurfaceVariant,
                            ),
                      ),
                      const SizedBox(height: 12),
                      _label('SNI'),
                      // combo-box: пункты из sni_pool + свободный ввод. Пусто →
                      // дефолт ядра (consumer-masque.cloudflareclient.com); он
                      // же ПЕРВЫМ пунктом пула и помечен recommended — DPI
                      // умеет резать по несовпадению SNI с блоком (§143), так
                      // что родной домен перебирается наравне, включая кубик.
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Expanded(
                            child: LayoutBuilder(
                              builder: (ctx, c) => DropdownMenu<String>(
                                controller: _masqueSni,
                                enabled: !_busy,
                                width: c.maxWidth,
                                requestFocusOnTap: true,
                                menuHeight: 280,
                                hintText: getLocalText.s("Leave empty for the default SNI"),
                                dropdownMenuEntries: [
                                  for (final s in _masqueSniPool)
                                    _presetEntry(s,
                                        _picker?.recommendedMasqueSni ?? ''),
                                ],
                              ),
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.casino_outlined),
                            tooltip: getLocalText.s("Pick another random domain"),
                            onPressed: _busy ? null : _fillRandomMasqueSni,
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _masqueIdle,
                              enabled: !_busy,
                              keyboardType: TextInputType.number,
                              inputFormatters: [
                                FilteringTextInputFormatter.digitsOnly
                              ],
                              decoration: _input('5').copyWith(
                                labelText: getLocalText.s("Idle timeout (min)"),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: TextField(
                              controller: _masqueKeepAlive,
                              // keep-alive осмыслен для h3-ноги (QUIC) — есть
                              // и у 'h3', и у 'auto'.
                              enabled: !_busy && _masqueNetwork != 'h2',
                              keyboardType: TextInputType.number,
                              inputFormatters: [
                                FilteringTextInputFormatter.digitsOnly
                              ],
                              decoration: _input('30').copyWith(
                                labelText: getLocalText.s("Keep-alive (sec)"),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        getLocalText.s("Idle timeout suspends the tunnel after inactivity to save battery (default 5 min). Keep-alive pings the QUIC link (default 30 sec, HTTP/3 only). Leave empty for defaults."),
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: cs.onSurfaceVariant,
                            ),
                      ),
                      const SizedBox(height: 8),
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        value: _forceNew,
                        onChanged: _busy
                            ? null
                            : (v) => setState(() => _forceNew = v ?? false),
                        title: Text(getLocalText.s("Re-register (force new account)")),
                        subtitle: Text(getLocalText.s("Ignore the cached account and register a fresh one.")),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
            ],
            // §126 — значимая опция (не прячем в Advanced): обфускация под DPI.
            if (!_isMasque)
            Card(
              margin: EdgeInsets.zero,
              child: Column(
                children: [
                  CheckboxListTile(
                    value: _obfuscate,
                    onChanged: _busy
                        ? null
                        : (v) {
                            final on = v ?? false;
                            setState(() => _obfuscate = on);
                            if (on) {
                              // Включение → сразу рандомный endpoint в поле
                              // (если там дефолт/пусто/прошлый авто-рандом, но
                              // НЕ вписанный юзером вручную).
                              if (_endpointReplaceable) _fillRandomEndpoint();
                            } else {
                              // Выключение → всё в стандарт (без галки обфускация
                              // не применяется, поля не должны вводить в
                              // заблуждение).
                              _resetObfuscationFields();
                            }
                          },
                    title: Text(getLocalText.s("Add Amnezia obfuscation")),
                    subtitle: Text(getLocalText.s("Adds padding traffic so the WireGuard handshake carries no fixed size signature. Enable if the plain tunnel does not connect.")),
                  ),
                  // §143 — masquerade под выбранный протокол (id/ip/ib, ядро
                  // 009 генерит i1). Протокол/домен/браузер — в Advanced.
                  if (_obfuscate)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                      child: Text(
                        getLocalText.s("Junk traffic masquerades as a real protocol. Pick protocol/domain in Advanced."),
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: cs.onSurfaceVariant,
                            ),
                      ),
                    ),
                ],
              ),
            ),
            // §130 — WG-Advanced (license/endpoint/masquerade) только для
            // WireGuard-транспорта; MASQUE имеет свой блок выше.
            if (!_isMasque) ...[
            const SizedBox(height: 16),
            ExpansionPanelList.radio(
              elevation: 0,
              expandedHeaderPadding: EdgeInsets.zero,
              children: [
                ExpansionPanelRadio(
                  value: 'advanced',
                  canTapOnHeader: true,
                  headerBuilder: (_, _) =>
                      ListTile(title: Text(getLocalText.s("Advanced"))),
                  body: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _label('WARP+ license key'),
                        TextField(
                          controller: _license,
                          enabled: !_busy,
                          decoration: _input('Leave empty for free WARP'),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          getLocalText.s("WARP+ adds Argo Smart Routing (lower latency). Privacy is the same as free. Leave empty for free WARP."),
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: cs.onSurfaceVariant,
                              ),
                        ),
                        const SizedBox(height: 12),
                        _label('Endpoint'),
                        // §386 — combobox: пункты из endpoints_preset (первый —
                        // рекомендуемый) + свободный ввод. Ручную правку/выбор
                        // ловит listener на _endpoint (initState).
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            Expanded(
                              child: LayoutBuilder(
                                builder: (ctx, c) => DropdownMenu<String>(
                                  controller: _endpoint,
                                  enabled: !_busy,
                                  width: c.maxWidth,
                                  requestFocusOnTap: true,
                                  menuHeight: 280,
                                  hintText: WarpAccount.defaultEndpoint,
                                  dropdownMenuEntries: [
                                    for (final e in _endpointsPreset)
                                      _presetEntry(e,
                                          _picker?.recommendedEndpoint ?? ''),
                                  ],
                                ),
                              ),
                            ),
                            // §136 — кубик: реролл рандомного endpoint (только
                            // его). Виден при обфускации.
                            if (_obfuscate)
                              IconButton(
                                icon: const Icon(Icons.casino_outlined),
                                tooltip: getLocalText.s("Pick another random IP:port"),
                                onPressed: _busy ? null : _fillRandomEndpoint,
                              ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Text(
                          getLocalText.s("host:port of the Cloudflare peer. With obfuscation a random working IP:port is filled in — tap the dice to reroll, or type your own to pin a specific one."),
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: cs.onSurfaceVariant,
                              ),
                        ),
                        // §304 — persistent keepalive. Держит туннель живым при
                        // простое (без него пинг WARP деградирует в err и коннект
                        // отваливается). Виден и для plain, и для AWG.
                        const SizedBox(height: 12),
                        _label('Persistent keepalive (s)'),
                        TextField(
                          controller: _keepalive,
                          enabled: !_busy,
                          keyboardType: TextInputType.number,
                          decoration: _input('25'),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          getLocalText.s("Keeps the tunnel alive while idle so it doesn't rot to timeouts (default 25). 0 = off."),
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: cs.onSurfaceVariant,
                              ),
                        ),
                        // §142 — reserved (client_id) опция. Дефолт по галке:
                        // обфускация → off (привязка к устройству режется).
                        CheckboxListTile(
                          contentPadding: EdgeInsets.zero,
                          value: _includeReserved ?? !_obfuscate,
                          onChanged: _busy
                              ? null
                              : (v) =>
                                  setState(() => _includeReserved = v),
                          title: Text(getLocalText.s("Bind to this device (reserved)")),
                          subtitle: Text(getLocalText.s("Sends the Cloudflare client_id. Off for obfuscation (the device binding tends to get blocked).")),
                        ),
                        // §143 — masquerade id/ip/ib (ядро 009 генерит i1).
                        if (_obfuscate) ...[
                          const SizedBox(height: 16),
                          // ip — протокол маскировки.
                          Row(
                            children: [
                              _label('Masquerade protocol'),
                              const SizedBox(width: 16),
                              Expanded(
                                child: DropdownButtonFormField<String>(
                                  initialValue: _masqIp,
                                  isDense: true,
                                  decoration: const InputDecoration(
                                    isDense: true,
                                    border: OutlineInputBorder(),
                                    contentPadding: EdgeInsets.symmetric(
                                        horizontal: 12, vertical: 8),
                                  ),
                                  items: const [
                                    DropdownMenuItem(
                                        // l10n-exempt: protocol name
                                        value: 'quic', child: Text('QUIC')),
                                    DropdownMenuItem(
                                        // l10n-exempt: protocol name
                                        value: 'dns', child: Text('DNS')),
                                    DropdownMenuItem(
                                        // l10n-exempt: protocol name
                                        value: 'stun', child: Text('STUN')),
                                    DropdownMenuItem(
                                        // l10n-exempt: protocol name
                                        value: 'sip', child: Text('SIP')),
                                  ],
                                  onChanged: _busy
                                      ? null
                                      : (v) => setState(
                                          () => _masqIp = v ?? 'quic'),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Text(
                            _masqIp == 'dns' || _masqIp == 'sip'
                                // Имена полей протокола (wire-термины) —
                                // подставляются как payload, не переводятся.
                                ? getLocalText.s("Domain (below) is visible on the wire as the %s.", _masqIp == 'dns' ? 'DNS QNAME' : 'SIP host')
                                : getLocalText.s("QUIC/STUN decoy carries no hostname — the domain below is cosmetic for this protocol."),
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(color: cs.onSurfaceVariant),
                          ),
                          const SizedBox(height: 12),
                          _label('Masquerade domain (id)'),
                          // combo-box (пункты из sni_pool + свободный ввод) +
                          // свой кубик: реролл случайного домена из пула.
                          // Cloudflare-доменов тут НЕТ намеренно: SNI живёт
                          // внутри junk-приманки (не TLS), и на замере они
                          // резались — в отличие от MASQUE-пула, см. §136.
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              Expanded(
                                child: LayoutBuilder(
                                  builder: (ctx, c) => DropdownMenu<String>(
                                    controller: _sni,
                                    enabled: !_busy,
                                    width: c.maxWidth,
                                    requestFocusOnTap: true,
                                    menuHeight: 280,
                                    dropdownMenuEntries: [
                                      for (final s in _sniPool)
                                        DropdownMenuEntry(value: s, label: s),
                                    ],
                                  ),
                                ),
                              ),
                              IconButton(
                                icon: const Icon(Icons.casino_outlined),
                                tooltip: getLocalText.s("Pick another random domain"),
                                onPressed: _busy ? null : _fillRandomSni,
                              ),
                            ],
                          ),
                          // ib — браузер (только при quic).
                          if (_masqIp == 'quic') ...[
                            const SizedBox(height: 12),
                            Row(
                              children: [
                                _label('Browser (ib)'),
                                const SizedBox(width: 16),
                                Expanded(
                                  child: DropdownButtonFormField<String>(
                                    initialValue: _masqIb,
                                    isDense: true,
                                    decoration: const InputDecoration(
                                      isDense: true,
                                      border: OutlineInputBorder(),
                                      contentPadding: EdgeInsets.symmetric(
                                          horizontal: 12, vertical: 8),
                                    ),
                                    items: const [
                                      DropdownMenuItem(
                                          value: 'chrome',
                                          // l10n-exempt: brand name
                                          child: Text('Chrome')),
                                      DropdownMenuItem(
                                          value: 'firefox',
                                          // l10n-exempt: brand name
                                          child: Text('Firefox')),
                                      DropdownMenuItem(
                                          value: 'curl',
                                          // l10n-exempt: brand name
                                          child: Text('cURL')),
                                    ],
                                    onChanged: _busy
                                        ? null
                                        : (v) => setState(
                                            () => _masqIb = v ?? 'chrome'),
                                  ),
                                ),
                              ],
                            ),
                          ],
                          const SizedBox(height: 12),
                          Row(
                            children: [
                              Expanded(
                                child: _numField(_jc, 'Jc'),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: _numField(_jmin, 'Jmin'),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: _numField(_jmax, 'Jmax'),
                              ),
                            ],
                          ),
                        ],
                        const SizedBox(height: 8),
                        CheckboxListTile(
                          contentPadding: EdgeInsets.zero,
                          value: _forceNew,
                          onChanged: _busy
                              ? null
                              : (v) => setState(() => _forceNew = v ?? false),
                          title: Text(getLocalText.s("Re-register (force new account)")),
                          subtitle: Text(getLocalText.s("Ignore the cached account and register a fresh one.")),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            ],
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _busy ? null : _register,
              icon: _busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.bolt),
              label: Text(_busy
                  ? getLocalText.s("Registering…")
                  : getLocalText.s("Register")),
            ),
            if (_result != null) ...[
              const SizedBox(height: 16),
              _StatusCard(account: _result!),
            ],
          ],
        ),
      ),
    );
  }

  Widget _label(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Text(text,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                )),
      );

  InputDecoration _input(String hint) => InputDecoration(
        hintText: hint,
        border: const OutlineInputBorder(),
        isDense: true,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      );

  /// §136 — компактное числовое поле для Jc/Jmin/Jmax.
  Widget _numField(TextEditingController c, String label) => TextField(
        controller: c,
        enabled: !_busy,
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
          isDense: true,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        ),
      );
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.account});
  final WarpAccount account;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
                account.warpPlus
                    ? getLocalText.s("Registered: WARP+")
                    : getLocalText.s("Registered: WARP"),
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            _row('Account', account.accountId),
            _row('Device', account.deviceId),
            _row('Address', account.clientV4),
            _row('Endpoint', account.endpoint),
            if (account.awg != null) _row('Obfuscation', 'Amnezia 1.5'),
          ],
        ),
      ),
    );
  }

  Widget _row(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            SizedBox(width: 80, child: Text(k)),
            Expanded(
              child: Text(v,
                  style: const TextStyle(
                      fontFamily: 'monospace', fontSize: 12)),
            ),
          ],
        ),
      );
}

/// §424 — пункт combobox-пресетов визарда WARP. `label` ВСЕГДА равен чистому
/// значению: [DropdownMenu] при выборе пункта пишет в контроллер именно
/// `entry.label`, и любая пометка в нём утекала бы в конфиг
/// (`"server_name": "consumer-masque.cloudflareclient.com (recommended)"`).
/// Пометка живёт только в [DropdownMenuEntry.labelWidget] — виден в меню,
/// в поле не попадает. [mark] — уже локализованная строка «(recommended)».
DropdownMenuEntry<String> warpPresetEntry(
    String value, String recommended, String mark) {
  final marked = recommended.isNotEmpty && value == recommended;
  return DropdownMenuEntry(
    value: value,
    label: value,
    labelWidget: marked ? Text('$value $mark') : null,
  );
}
