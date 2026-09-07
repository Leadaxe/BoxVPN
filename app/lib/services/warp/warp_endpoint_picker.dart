import 'dart:convert';
import 'dart:math';

import 'package:flutter/services.dart' show rootBundle;

import 'scan/scan_pool.dart';
import '../usage_region.dart';

/// §136/§305 — рандом WARP-endpoint из зашитых Cloudflare-блоков. **БЕЗ пробы.**
///
/// Единственный источник истины — [_assetPath] (`assets/warp_endpoints.json`),
/// сгруппированный по транспорту (`wireguard`/`masque`). Весь пул парсится в
/// [ScanPool]; picker — тонкая обёртка над ним (рандом IP/SNI/endpoint).
///
/// WG-рандом (§136): случайный IP из `wireguard.v4_cidr`/`v6_cidr` + порт из
/// `ports`(∪`ports_extra`). Работает т.к. почти любой IP этих блоков на любом
/// порту = живой WARP anycast; DPI режет только `engage…:2408`.
class WarpEndpointPicker {
  WarpEndpointPicker._(this._scan);

  static const String _assetPath = 'assets/warp_endpoints.json';
  static final Random _rng = Random.secure();

  /// Весь пул (null если asset битый/пустой). Picker выводит из него всё.
  final ScanPool? _scan;

  static WarpEndpointPicker? _cached;
  static String? _cachedRegion;

  /// Загружает asset один раз (кэш). При ошибке — пул null (caller проверяет
  /// [hasData] / fallback на дефолтный endpoint).
  ///
  /// §425 — [region]: код страны для секции `loc.<cc>`; null → эффективный
  /// регион из настройки ([UsageRegion.effective]). Кэш привязан к региону:
  /// смена настройки → следующий load перечитывает.
  static Future<WarpEndpointPicker> load({String? region}) async {
    final r = region ?? await UsageRegion.effective();
    if (_cached != null && _cachedRegion == r) return _cached!;
    try {
      final raw = await rootBundle.loadString(_assetPath);
      final json = jsonDecode(raw) as Map<String, dynamic>;
      _cached = WarpEndpointPicker._(ScanPool.fromFullJson(json, region: r));
    } catch (_) {
      _cached = WarpEndpointPicker._(null);
    }
    _cachedRegion = r;
    return _cached!;
  }

  /// §425 — регионы, объявленные в asset'е (`loc`), для меню настроек.
  static Future<List<String>> availableRegions() async {
    try {
      final raw = await rootBundle.loadString(_assetPath);
      return ScanPool.regionsOf(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return const [];
    }
  }

  bool get hasData => _scan?.hasData ?? false;

  /// §136 — случайный WG-endpoint `ip:port`. IP из v4/v6-блока, порт из
  /// `ports`∪`ports_extra`. null если нет WG-данных (caller оставляет дефолт).
  ///
  /// §305 — [allowV6]: подставлять v6-блок разрешено ТОЛЬКО если в системе
  /// включён IPv6 (`ipv6_enabled`). Иначе v6-endpoint мёртв (нет маршрута).
  /// Дефолт false — безопасный (v4-only).
  String? randomEndpoint({bool allowV6 = false}) {
    final s = _scan;
    if (s == null) return null;
    final useV6 = allowV6 && s.wgV6Cidr.isNotEmpty && _rng.nextBool();
    final blocks = useV6 ? s.wgV6Cidr : s.wgV4Cidr;
    final ports = [...s.wgPorts, ...s.wgPortsExtra];
    if (blocks.isEmpty || ports.isEmpty) return null;
    try {
      final ip = randomIpInCidr(blocks[_rng.nextInt(blocks.length)], _rng);
      final port = ports[_rng.nextInt(ports.length)];
      // v6-литерал в скобках для host:port.
      final host = ip.contains(':') ? '[$ip]' : ip;
      return '$host:$port';
    } catch (_) {
      return null;
    }
  }

  /// Случайный SNI-приманка для AWG (WG-пул). '' если пуст.
  String randomSni() {
    final p = _scan?.wgSniPool ?? const [];
    return p.isEmpty ? '' : p[_rng.nextInt(p.length)];
  }

  List<String> get sniPool => List.unmodifiable(_scan?.wgSniPool ?? const []);

  /// §386 — пресеты `host:port` для combobox WG-endpoint. Пусто, если ключа
  /// нет в asset/override.
  List<String> get endpointsPreset =>
      List.unmodifiable(_scan?.wgEndpointsPreset ?? const []);

  /// §386 — рекомендуемый WG-endpoint (ключ `recommended_endpoint` asset'а).
  /// UI помечает совпадающий пункт списка. '' → пометки нет.
  String get recommendedEndpoint => _scan?.wgRecommendedEndpoint ?? '';

  /// §386 — рекомендуемый MASQUE-хост (ключ `recommended_host` asset'а).
  String get recommendedMasqueHost => _scan?.masqueRecommendedHost ?? '';

  /// §386/§420 — общие хосты combobox MASQUE-endpoint (оба транспорта).
  List<String> get masqueHostsPreset =>
      List.unmodifiable(_scan?.masqueHostsPreset ?? const <String>[]);

  /// §420 — хосты combobox для транспорта (`h3` добавляет h3-only адреса,
  /// `h2`/`auto` — только общие). Пусто, если нет пула.
  List<String> masqueHostsFor(String network) =>
      List.unmodifiable(_scan?.masqueHostsFor(network) ?? const <String>[]);

  /// §420 — все известные пресет-хосты (общие + h3-only): по ним визард
  /// понимает, что в поле стоит пресет, а не ручной IP.
  List<String> get masqueH3Hosts =>
      List.unmodifiable(_scan?.masqueH3Hosts ?? const <String>[]);

  /// §130 — случайный SNI из MASQUE-пула. '' если пуст.
  String randomMasqueSni() {
    final p = _scan?.masqueSniPool ?? const [];
    return p.isEmpty ? '' : p[_rng.nextInt(p.length)];
  }

  /// §130 — MASQUE SNI-пул (может содержать cloudflare-домены).
  List<String> get masqueSniPool =>
      List.unmodifiable(_scan?.masqueSniPool ?? const []);

  /// Рекомендуемый MASQUE SNI (ключ `recommended_sni`) — пометка пункта в UI.
  String get recommendedMasqueSni => _scan?.masqueRecommendedSni ?? '';

  /// §418 — хосты API регистрации по порядку предпочтения. Пусто, если asset
  /// битый/старый — [WarpClient] тогда берёт [WarpApi.fallbackHosts].
  List<String> get apiHosts =>
      List.unmodifiable(_scan?.apiHosts ?? const <String>[]);

  /// §284 — весь пул (null если asset отсутствует/битый).
  ScanPool? get scan => _scan;

  /// §305 — MASQUE CIDR-блоки для выбора endpoint. Пусто если нет пула.
  List<String> get masqueV4Cidr =>
      List.unmodifiable(_scan?.masqueV4Cidr ?? const []);

  /// §305 — device-verified MASQUE-порты для транспорта (`h3`/`h2`). Пусто если
  /// нет пула.
  List<int> masquePortsFor(String network) =>
      _scan?.masquePortsFor(network) ?? const [];

  /// §305 — случайный MASQUE-порт для транспорта. null если набор пуст.
  int? randomMasquePortFor(String network) {
    final ports = masquePortsFor(network);
    return ports.isEmpty ? null : ports[_rng.nextInt(ports.length)];
  }

  /// §305/§420 — случайный MASQUE-IP для транспорта (h3 — из живых h3-хостов,
  /// h2 — по блоку минус исключения). null если пусто/битый CIDR (caller
  /// оставляет endpoint из регистрации).
  String? randomMasqueIp({String network = 'h3'}) =>
      _scan?.randomMasqueIp(network, _rng);

  /// §305 — сырой JSON asset'а (для дефолта JSON-окна эксперимента). '' при сбое.
  static Future<String> loadRawJson() async {
    try {
      return await rootBundle.loadString(_assetPath);
    } catch (_) {
      return '';
    }
  }

  /// Сброс кэша (тесты; смена региона через настройку перечитывает сама).
  static void resetForTest() {
    _cached = null;
    _cachedRegion = null;
  }
}
