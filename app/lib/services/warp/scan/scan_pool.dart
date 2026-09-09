// §284/§305 — источник пула для WARP-генерации. Структура сгруппирована по
// транспорту (`wireguard` / `masque`), парсится из assets/warp_endpoints.json.
//
// WireGuard (secion `wireguard`): v4/v6 CIDR-блоки Cloudflare-first-party
// (cloudflare.com/ips: 162.159.192/193/195; 188.114.96.0/22), порты 2408/500/
// 1701/4500 (достоверные) + ports_extra (empirical, §132 — ниже приоритетом),
// keepalive (§313 — секунды, попадает в каждый сгенерированный WG/AWG-узел).
//
// MASQUE (section `masque`): device-verified боевым тестом (пинг через рабочий
// туннель, §305) — живы только .198.0/24 и .199.0/24 (.197/.192 = 0 живых,
// убраны). Порты РАЗДЕЛЬНЫ по транспорту: h3 — 443/4443/8095, h2 — 500/4500/8443.
// h3 работает и на чужих IP блока (не только сервер реги) — прошлый вывод «h3
// привязан к server» был артефактом headless-probe (probe при остановленном VPN
// не поднимает QUIC); реальную живость мерить через боевое ядро.

import 'dart:io' show InternetAddress;
import 'dart:math';
import 'dart:typed_data';

class ScanPool {
  const ScanPool({
    required this.wgV4Cidr,
    required this.wgV6Cidr,
    this.wgEndpointsPreset = const [],
    this.wgRecommendedEndpoint = '',
    required this.wgPorts,
    required this.wgPortsExtra,
    required this.wgSniPool,
    required this.utlsFpPool,
    this.wgKeepalive = 0,
    this.masqueHostsPreset = const [],
    this.masqueRecommendedHost = '',
    required this.masqueV4Cidr,
    this.masqueH3HostsExtra = const [],
    this.masqueH2Exclude = const [],
    required this.masquePortsH3,
    required this.masquePortsH2,
    required this.masqueSniPool,
    this.masqueRecommendedSni = '',
    this.apiHosts = const [],
  });

  // --- WireGuard / AWG ---
  final List<String> wgV4Cidr;
  final List<String> wgV6Cidr;

  /// §386 — готовые `host:port` для combobox endpoint в визарде. Пусто (старый
  /// asset / JSON-override без ключа) → combobox без пунктов, только свободный
  /// ввод + кубик.
  final List<String> wgEndpointsPreset;

  /// §386 — рекомендуемое значение из [wgEndpointsPreset] (официальный
  /// `engage.cloudflareclient.com:2408`). ЯВНЫЙ ключ `recommended_endpoint` —
  /// UI помечает суффиксом пункт с этим значением, на любой позиции; порядок
  /// списка семантики не несёт. '' (нет ключа) → пометки нет.
  final String wgRecommendedEndpoint;

  /// Cloudflare-достоверные WG-порты (2408/500/1701/4500). Приоритетны.
  final List<int> wgPorts;

  /// Empirical-порты — ниже приоритетом (§132: длинный список зарублен голосованием).
  final List<int> wgPortsExtra;

  /// SNI-приманки для AWG-обфускации (junk, НЕ cloudflare-домены). В отличие от
  /// [masqueSniPool] родной домен сюда НЕ кладём: здесь SNI лежит внутри
  /// junk-приманки (§136, реального TLS нет) и cloudflare-* на device-замере
  /// резался. `recommended_sni` у WG-секции поэтому нет.
  final List<String> wgSniPool;

  final List<String> utlsFpPool;

  /// §313 — `persistent_keepalive_interval` (секунды) для сгенерированных
  /// WG/AWG-узлов. Ядро дефолт НЕ подставляет: без этой строки пир молчит при
  /// простое, NAT-маппинг оператора закрывается за 30–120с и узел деградирует.
  ///
  /// Живёт в пуле (а не константой в коде), чтобы правиться JSON-окном
  /// эксперимента (§305) без пересборки APK. `0` (и отсутствие ключа в старом/
  /// пользовательском JSON) = keepalive не писать — гейт `> 0` в
  /// [WarpAccount.toWireguardConf]. На [hasData] не влияет: keepalive — тюнинг,
  /// а не источник кандидатов.
  final int wgKeepalive;

  // --- MASQUE ---

  /// §386/§420 — общие хосты combobox MASQUE-endpoint: device-verified адреса,
  /// на которых живут ОБА транспорта (h3 и h2) — `.198.2`, `.199.2`. Их
  /// показываем при любом выборе транспорта, включая `auto` (h3 с фолбэком на
  /// h2 на том же адресе — фолбэку есть куда падать). Ключ `hosts_preset`.
  final List<String> masqueHostsPreset;

  /// §386 — рекомендуемый хост, ЯВНЫЙ ключ `recommended_host`; должен быть
  /// элементом [masqueHostsPreset] (§420: `162.159.198.2` — его же отдаёт
  /// регистрация). Семантика пометки как у [wgRecommendedEndpoint].
  final String masqueRecommendedHost;

  /// §305/§420 — CIDR-блоки h2 (`h2.v4_cidr`): h2 живёт по всему блоку, кроме
  /// [masqueH2Exclude]. h3 их НЕ использует.
  final List<String> masqueV4Cidr;

  /// §420 — хосты ТОЛЬКО для h3 (`h3.hosts_extra`): `.198.1`, `.199.1` — по
  /// TCP 443 там обычный CDN-edge, h2-туннель не поднимается. Полный h3-список
  /// = [masqueH3Hosts]. Рандомить h3 по блоку нельзя (живы единицы адресов).
  final List<String> masqueH3HostsExtra;

  /// §420 — адреса, исключённые из h2-рандома (`h2.exclude`): те же h3-only
  /// хосты. Иначе кубик/генератор на h2 с шансом 1/256 выдаёт мёртвый адрес.
  final List<String> masqueH2Exclude;

  /// §305 — порты MASQUE, задаются отдельными ключами на транспорт. Device-verified
  /// рабочие наборы сейчас СОВПАДАЮТ (все 7: 443/500/1701/4500/4443/8443/8095) —
  /// ключи раздельные на случай, если CF разведёт их в будущем.
  final List<int> masquePortsH3;
  final List<int> masquePortsH2;

  /// SNI для MASQUE (МОЖЕТ содержать cloudflare-домены — трафик и так идёт в CF).
  /// Включает родной `consumer-masque.cloudflareclient.com` — см. [wgSniPool]
  /// про DPI по несовпадению SNI; он же дефолт ядра при пустом поле.
  final List<String> masqueSniPool;

  /// Рекомендуемый SNI из [masqueSniPool] (ключ `recommended_sni`). Семантика
  /// как у [wgRecommendedSni] — пометка в UI, без веса в переборе.
  final String masqueRecommendedSni;

  /// §418 — хосты API регистрации (`api.hosts`) по порядку предпочтения:
  /// первый — дефолт, дальше — запасные на случай сетевой ошибки/таймаута.
  /// Пусто (старый asset / JSON-override без ключа) → клиент берёт свой
  /// зашитый список ([WarpApi.fallbackHosts]).
  final List<String> apiHosts;

  /// §420 — все h3-хосты: общие + h3-only, без дублей, порядок сохранён.
  List<String> get masqueH3Hosts {
    final seen = <String>{};
    return [
      for (final h in [...masqueHostsPreset, ...masqueH3HostsExtra])
        if (seen.add(h)) h,
    ];
  }

  /// §420 — хосты combobox для транспорта: `h3` → [masqueH3Hosts]; `h2` и
  /// `auto` → только общие [masqueHostsPreset].
  List<String> masqueHostsFor(String network) =>
      network == 'h3' ? masqueH3Hosts : masqueHostsPreset;

  /// §420 — случайный MASQUE-IP для транспорта. `h3` → из [masqueH3Hosts];
  /// `h2`/`auto` → случайный адрес блока [masqueV4Cidr], не из
  /// [masqueH2Exclude] (несколько попыток; блок из одних исключений → null).
  /// null и при пустом источнике/битом CIDR — caller оставляет endpoint
  /// регистрации.
  String? randomMasqueIp(String network, Random rng) {
    if (network == 'h3') {
      final hosts = masqueH3Hosts;
      return hosts.isEmpty ? null : hosts[rng.nextInt(hosts.length)];
    }
    if (masqueV4Cidr.isEmpty) return null;
    try {
      for (var i = 0; i < 16; i++) {
        final cidr = masqueV4Cidr[rng.nextInt(masqueV4Cidr.length)];
        final ip = randomIpInCidr(cidr, rng);
        if (!masqueH2Exclude.contains(ip)) return ip;
      }
    } catch (_) {
      return null;
    }
    return null;
  }

  /// Пул пригоден, если валиден хотя бы один транспорт. WG требует портов
  /// (иначе пробу не собрать); MASQUE — h2-блок или h3-хосты.
  bool get hasData {
    final wgOk =
        (wgV4Cidr.isNotEmpty || wgV6Cidr.isNotEmpty) && wgPorts.isNotEmpty;
    return wgOk || masqueV4Cidr.isNotEmpty || masqueH3Hosts.isNotEmpty;
  }

  /// §305 — порты для транспорта: `h2` → h2-набор, иначе h3-набор.
  List<int> masquePortsFor(String network) =>
      network == 'h2' ? masquePortsH2 : masquePortsH3;

  /// Парс полной структуры файла (`{wireguard:{...}, masque:{...}}`). Возвращает
  /// null, если структура битая/пустая (caller прячет генератор). Один парсер и
  /// для bundled asset, и для JSON-override окна эксперимента (§305).
  ///
  /// §425 — [region]: код страны (нижний регистр); секция `loc.<region>`
  /// накладывается поверх корня через [applyRegion]. Пусто/неизвестный код →
  /// корень как есть.
  static ScanPool? fromFullJson(Map<String, dynamic>? json,
      {String region = ''}) {
    if (json == null) return null;
    if (region.isNotEmpty) json = applyRegion(json, region);
    final wg = (json['wireguard'] as Map?)?.cast<String, dynamic>() ?? const {};
    final mq = (json['masque'] as Map?)?.cast<String, dynamic>() ?? const {};
    final api = (json['api'] as Map?)?.cast<String, dynamic>() ?? const {};

    List<String> strs(Map m, String k) =>
        (m[k] as List?)?.map((e) => e.toString()).toList() ?? const [];
    List<int> ints(Map m, String k) =>
        (m[k] as List?)?.map((e) => (e as num).toInt()).toList() ?? const [];
    // Нет ключа / не число (старый asset, пользовательский JSON-override) → 0 =
    // keepalive не писать. Строку тоже принимаем — JSON правит человек.
    int intOr0(Map m, String k) {
      final v = m[k];
      if (v is num) return v.toInt();
      if (v is String) return int.tryParse(v.trim()) ?? 0;
      return 0;
    }

    // §420 — секция masque по транспортам: `h3: {hosts_extra, ports}`,
    // `h2: {v4_cidr, exclude, ports}`, общие `hosts_preset`/`recommended_host`.
    // Старый плоский формат (asset до §420, пользовательский JSON-override)
    // читается как фолбэк: `v4_cidr` → h2-блок, `ports_h3`/`ports_h2` →
    // порты, `h3_v4_cidr` (/32-записи) → h3-хосты сверх `hosts_preset`.
    // Семантика старого override не меняется: его `hosts_preset` — как был.
    final h3 = (mq['h3'] as Map?)?.cast<String, dynamic>() ?? const {};
    final h2 = (mq['h2'] as Map?)?.cast<String, dynamic>() ?? const {};
    final hostsPreset = strs(mq, 'hosts_preset');
    final h2Cidr = h2.containsKey('v4_cidr') ? strs(h2, 'v4_cidr') : strs(mq, 'v4_cidr');
    final List<String> h3Extra;
    if (h3.containsKey('hosts_extra')) {
      h3Extra = strs(h3, 'hosts_extra');
    } else {
      h3Extra = [
        for (final c in strs(mq, 'h3_v4_cidr'))
          if (c.endsWith('/32') && !hostsPreset.contains(c.substring(0, c.length - 3)))
            c.substring(0, c.length - 3),
      ];
    }

    final pool = ScanPool(
      wgV4Cidr: strs(wg, 'v4_cidr'),
      wgV6Cidr: strs(wg, 'v6_cidr'),
      wgEndpointsPreset: strs(wg, 'endpoints_preset'),
      wgRecommendedEndpoint: (wg['recommended_endpoint'] as String?) ?? '',
      wgPorts: ints(wg, 'ports'),
      wgPortsExtra: ints(wg, 'ports_extra'),
      wgSniPool: strs(wg, 'sni_pool'),
      utlsFpPool: strs(wg, 'utls_fp_pool'),
      wgKeepalive: intOr0(wg, 'keepalive'),
      masqueHostsPreset: hostsPreset,
      masqueRecommendedHost: (mq['recommended_host'] as String?) ?? '',
      masqueV4Cidr: h2Cidr,
      masqueH3HostsExtra: h3Extra,
      masqueH2Exclude: strs(h2, 'exclude'),
      masquePortsH3: h3.containsKey('ports') ? ints(h3, 'ports') : ints(mq, 'ports_h3'),
      masquePortsH2: h2.containsKey('ports') ? ints(h2, 'ports') : ints(mq, 'ports_h2'),
      masqueSniPool: strs(mq, 'sni_pool'),
      masqueRecommendedSni: (mq['recommended_sni'] as String?) ?? '',
      // Пустые/не-строки отбрасываем; хвостовой `/` снимаем — URL клеится
      // как `$host/$version/reg`.
      apiHosts: strs(api, 'hosts')
          .map((h) => h.trim().replaceAll(RegExp(r'/+$'), ''))
          .where((h) => h.isNotEmpty)
          .toList(),
    );
    return pool.hasData ? pool : null;
  }

  /// §425 — ключ региональной секции asset'а.
  static const locKey = 'loc';

  /// §425 — коды регионов, объявленные в `loc` (включая alias-секции), в
  /// порядке файла. Для меню настроек.
  static List<String> regionsOf(Map<String, dynamic>? json) {
    final loc = json?[locKey];
    if (loc is! Map) return const [];
    return [
      for (final e in loc.entries)
        if (e.value is Map) e.key.toLowerCase(),
    ];
  }

  /// §425 — корень asset'а с наложенной секцией `loc.<region>`.
  ///
  /// Правила: Map сливается рекурсивно по ключам; всё остальное (списки,
  /// строки, числа) заменяется целиком — иначе «убрать домен для региона»
  /// невозможно. Секция вида `{"alias": "ru"}` ссылается на другую секцию
  /// (один переход, без цепочек). Неизвестный регион / нет `loc` → корень
  /// без изменений. Сам ключ `loc` из результата снимается.
  static Map<String, dynamic> applyRegion(
      Map<String, dynamic> json, String region) {
    final loc = json[locKey];
    final base = Map<String, dynamic>.from(json)..remove(locKey);
    if (loc is! Map) return base;
    // Секция с чужим типом (строка, список) — как отсутствующая: JSON правит
    // человек, ронять парсер из-за опечатки нельзя.
    Map<String, dynamic>? section(Object? v) =>
        v is Map ? v.cast<String, dynamic>() : null;
    var sec = section(loc[region.toLowerCase()]);
    final alias = sec?['alias'];
    if (alias is String) sec = section(loc[alias.toLowerCase()]);
    if (sec == null) return base;
    return deepMerge(base, sec);
  }

  /// Рекурсивное слияние Map: ключи [over] побеждают; вложенные Map сливаются,
  /// остальные значения заменяются целиком.
  static Map<String, dynamic> deepMerge(
      Map<String, dynamic> base, Map<String, dynamic> over) {
    final out = Map<String, dynamic>.from(base);
    for (final e in over.entries) {
      final b = out[e.key];
      final o = e.value;
      if (b is Map && o is Map) {
        out[e.key] = deepMerge(
            b.cast<String, dynamic>(), o.cast<String, dynamic>());
      } else {
        out[e.key] = o;
      }
    }
    return out;
  }
}

/// Возвращает случайный IP внутри CIDR (v4 или v6). Полный рандом по хостовой
/// части — не только последний октет. `rng` инъектируется для тестов.
/// Кидает FormatException на битом CIDR (caller обрабатывает выше).
String randomIpInCidr(String cidr, Random rng) {
  final slash = cidr.indexOf('/');
  if (slash < 0) throw FormatException('not a CIDR: $cidr');
  final base = InternetAddress(cidr.substring(0, slash));
  final mask = int.parse(cidr.substring(slash + 1));
  final bytes = base.rawAddress; // 4 (v4) или 16 (v6)
  final totalBits = bytes.length * 8;
  if (mask < 0 || mask > totalBits) throw FormatException('bad mask: $cidr');
  final hostBits = totalBits - mask;

  // base → BigInt, обнуляем хостовую часть, накладываем случайный host-offset.
  var value = BigInt.zero;
  for (final b in bytes) {
    value = (value << 8) | BigInt.from(b);
  }
  final full = (BigInt.one << totalBits) - BigInt.one;
  final hostMask =
      hostBits == 0 ? BigInt.zero : (BigInt.one << hostBits) - BigInt.one;
  final network = value & (full ^ hostMask);
  final offset = _randomBigInt(hostBits, rng) & hostMask;
  final result = network | offset;

  // BigInt → байты (big-endian, фиксированная длина адреса).
  final out = Uint8List(bytes.length);
  var v = result;
  for (var i = bytes.length - 1; i >= 0; i--) {
    out[i] = (v & BigInt.from(0xff)).toInt();
    v = v >> 8;
  }
  return InternetAddress.fromRawAddress(out).address;
}

/// Случайный BigInt в [0, 2^bits). Генерируем побайтно — nextInt(≤256) валиден
/// (Random.nextInt требует max ≤ 2^32).
BigInt _randomBigInt(int bits, Random rng) {
  var v = BigInt.zero;
  var remaining = bits;
  while (remaining > 0) {
    final take = remaining >= 8 ? 8 : remaining;
    final r = rng.nextInt(1 << take); // take ≤ 8 → max ≤ 256
    v = (v << take) | BigInt.from(r);
    remaining -= take;
  }
  return v;
}
