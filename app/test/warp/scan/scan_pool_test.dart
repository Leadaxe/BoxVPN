import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/warp/scan/scan_pool.dart';

/// §284 — пул скана: парс `scan`-блока + CIDR→random IP в границах подсети.
void main() {
  /// Истинно, если [ip] попадает в [cidr] (bitmask-сравнение, v4+v6).
  bool inCidr(String ip, String cidr) {
    final parts = cidr.split('/');
    final net = InternetAddress(parts[0]).rawAddress;
    final a = InternetAddress(ip).rawAddress;
    if (net.length != a.length) return false;
    var bits = int.parse(parts[1]);
    for (var i = 0; i < net.length; i++) {
      if (bits >= 8) {
        if (net[i] != a[i]) return false;
        bits -= 8;
      } else if (bits > 0) {
        final m = (0xff << (8 - bits)) & 0xff;
        if ((net[i] & m) != (a[i] & m)) return false;
        bits = 0;
      } else {
        break;
      }
    }
    return true;
  }

  group('randomIpInCidr', () {
    final rng = Random(42);
    for (final cidr in [
      '162.159.192.0/24',
      '188.114.96.0/22',
      '2606:4700:d0::/64',
    ]) {
      test('$cidr → все 500 адресов внутри подсети', () {
        for (var i = 0; i < 500; i++) {
          final ip = randomIpInCidr(cidr, rng);
          expect(inCidr(ip, cidr), isTrue, reason: '$ip not in $cidr');
        }
      });
    }

    test('/32 возвращает сам адрес', () {
      expect(randomIpInCidr('162.159.192.7/32', Random(1)), '162.159.192.7');
    });

    test('битый CIDR → FormatException', () {
      expect(() => randomIpInCidr('162.159.192.0', Random(1)),
          throwsFormatException);
    });
  });

  group('ScanPool.fromFullJson', () {
    test('парсит wireguard+masque секции и hasData', () {
      final pool = ScanPool.fromFullJson({
        'wireguard': {
          'v4_cidr': ['162.159.192.0/24'],
          'ports': [2408, 500],
          'ports_extra': [7156],
          'sni_pool': ['a'],
          'utls_fp_pool': ['chrome'],
        },
        'masque': {
          'v4_cidr': ['162.159.198.0/24', '162.159.199.0/24'],
          'ports_h3': [443, 4443, 8095],
          'ports_h2': [500, 4500, 8443],
          'sni_pool': ['b'],
        },
      });
      expect(pool, isNotNull);
      expect(pool!.hasData, isTrue);
      expect(pool.wgPorts, [2408, 500]);
      expect(pool.wgPortsExtra, [7156]);
      expect(pool.wgSniPool, ['a']);
      expect(pool.masqueV4Cidr, ['162.159.198.0/24', '162.159.199.0/24']);
      expect(pool.masquePortsH3, [443, 4443, 8095]);
      expect(pool.masquePortsH2, [500, 4500, 8443]);
      expect(pool.masqueSniPool, ['b']);
    });

    test('§386 — endpoints_preset + recommended-ключи; отсутствие → пусто', () {
      final pool = ScanPool.fromFullJson({
        'wireguard': {
          'v4_cidr': ['162.159.192.0/24'],
          'ports': [2408],
          'endpoints_preset': [
            'engage.cloudflareclient.com:2408',
            '162.159.192.192:934',
          ],
          'recommended_endpoint': 'engage.cloudflareclient.com:2408',
        },
        'masque': {
          'v4_cidr': ['162.159.198.0/24'],
          'hosts_preset': ['consumer-masque.cloudflareclient.com'],
          'recommended_host': 'consumer-masque.cloudflareclient.com',
        },
      });
      expect(pool!.wgEndpointsPreset, [
        'engage.cloudflareclient.com:2408',
        '162.159.192.192:934',
      ]);
      expect(pool.wgRecommendedEndpoint, 'engage.cloudflareclient.com:2408');
      expect(pool.masqueHostsPreset,
          ['consumer-masque.cloudflareclient.com']);
      expect(pool.masqueRecommendedHost,
          'consumer-masque.cloudflareclient.com');

      final noKey = ScanPool.fromFullJson({
        'wireguard': {
          'v4_cidr': ['162.159.192.0/24'],
          'ports': [2408],
        },
      });
      expect(noKey!.wgEndpointsPreset, isEmpty);
      expect(noKey.wgRecommendedEndpoint, isEmpty);
      expect(noKey.masqueHostsPreset, isEmpty);
      expect(noKey.masqueRecommendedHost, isEmpty);
    });

    test('§305 — masquePortsFor разделяет h3/h2', () {
      final pool = ScanPool.fromFullJson({
        'masque': {
          'v4_cidr': ['162.159.198.0/24'],
          'ports_h3': [443, 4443],
          'ports_h2': [500, 8443],
        },
      });
      expect(pool!.masquePortsFor('h3'), [443, 4443]);
      expect(pool.masquePortsFor('h2'), [500, 8443]);
      // Неизвестный транспорт → h3-набор дефолтом.
      expect(pool.masquePortsFor('foo'), [443, 4443]);
    });

    test('§313 — keepalive: число/строка/мусор/отсутствие', () {
      ScanPool? pool(Object? keepalive) => ScanPool.fromFullJson({
            'wireguard': {
              'v4_cidr': ['162.159.192.0/24'],
              'ports': [2408],
              'keepalive': ?keepalive,
            },
          });

      expect(pool(25)!.wgKeepalive, 25);
      // JSON правит человек — строку принимаем.
      expect(pool('25')!.wgKeepalive, 25);
      expect(pool('nope')!.wgKeepalive, 0, reason: 'мусор → 0 = не писать');
      final noKey = pool(null)!;
      expect(noKey.wgKeepalive, 0, reason: 'старый asset без ключа');
      expect(noKey.hasData, isTrue,
          reason: 'keepalive на пригодность пула не влияет');
    });

    test('null / пустой → null', () {
      expect(ScanPool.fromFullJson(null), isNull);
      expect(
        ScanPool.fromFullJson({}),
        isNull,
        reason: 'нет диапазонов → hasData=false → null',
      );
    });

    test('masque-only (без wg) → hasData true, не null', () {
      final pool = ScanPool.fromFullJson({
        'masque': {
          'v4_cidr': ['162.159.198.0/24'],
          'ports_h3': [443],
          'ports_h2': [500],
          'sni_pool': ['y'],
        },
      });
      expect(pool, isNotNull);
      expect(pool!.hasData, isTrue);
      expect(pool.wgPorts, isEmpty);
    });

    test('§420 masque по транспортам: hosts_preset общий, h3.hosts_extra, '
        'h2.v4_cidr+exclude, порты в секциях', () {
      final pool = ScanPool.fromFullJson({
        'masque': {
          'hosts_preset': ['162.159.198.2', '162.159.199.2'],
          'recommended_host': '162.159.198.2',
          'h3': {
            'hosts_extra': ['162.159.198.1', '162.159.199.1'],
            'ports': [443, 4443],
          },
          'h2': {
            'v4_cidr': ['162.159.198.0/24'],
            'exclude': ['162.159.198.1'],
            'ports': [500, 8443],
          },
        },
      })!;
      expect(pool.masqueHostsPreset, ['162.159.198.2', '162.159.199.2']);
      expect(pool.masqueRecommendedHost, '162.159.198.2');
      expect(pool.masqueH3HostsExtra, ['162.159.198.1', '162.159.199.1']);
      expect(pool.masqueH3Hosts, [
        '162.159.198.2',
        '162.159.199.2',
        '162.159.198.1',
        '162.159.199.1',
      ]);
      expect(pool.masqueV4Cidr, ['162.159.198.0/24']);
      expect(pool.masqueH2Exclude, ['162.159.198.1']);
      expect(pool.masquePortsH3, [443, 4443]);
      expect(pool.masquePortsH2, [500, 8443]);
      expect(pool.masqueHostsFor('h3'), pool.masqueH3Hosts);
      expect(pool.masqueHostsFor('h2'), ['162.159.198.2', '162.159.199.2']);
      expect(pool.masqueHostsFor('auto'), ['162.159.198.2', '162.159.199.2']);
      expect(pool.hasData, isTrue);
    });

    test('§420 старый плоский формат (override до §420) читается как фолбэк', () {
      final pool = ScanPool.fromFullJson({
        'masque': {
          'v4_cidr': ['162.159.198.0/24', '162.159.199.0/24'],
          'hosts_preset': ['consumer-masque.cloudflareclient.com', '162.159.198.2'],
          'h3_v4_cidr': ['162.159.198.1/32', '162.159.198.2/32', '10.0.0.0/8'],
          'ports_h3': [443],
          'ports_h2': [500],
        },
      })!;
      expect(pool.masqueV4Cidr, ['162.159.198.0/24', '162.159.199.0/24']);
      // hosts_preset старого override — как был (семантика не меняется).
      expect(pool.masqueHostsPreset,
          ['consumer-masque.cloudflareclient.com', '162.159.198.2']);
      // /32 из h3_v4_cidr → h3-хосты сверх пресета; не-/32 отбрасываются.
      expect(pool.masqueH3HostsExtra, ['162.159.198.1']);
      expect(pool.masqueH2Exclude, isEmpty);
      expect(pool.masquePortsH3, [443]);
      expect(pool.masquePortsH2, [500]);
    });

    test('§420 randomMasqueIp: h3 — только из h3-хостов; h2 — блок минус exclude; '
        'пустой источник → null', () {
      final pool = ScanPool.fromFullJson({
        'masque': {
          'hosts_preset': ['162.159.198.2'],
          'h3': {'hosts_extra': ['162.159.198.1']},
          'h2': {
            'v4_cidr': ['162.159.198.0/30'],
            'exclude': ['162.159.198.1'],
          },
        },
      })!;
      final rng = Random(42);
      for (var i = 0; i < 200; i++) {
        expect(pool.randomMasqueIp('h3', rng),
            anyOf('162.159.198.2', '162.159.198.1'));
        final h2 = pool.randomMasqueIp('h2', rng);
        expect(h2, isNotNull);
        expect(h2, isNot('162.159.198.1'));
        expect(h2!.startsWith('162.159.198.'), isTrue);
      }
      // Блок из одних исключений → null, не бесконечный цикл.
      final allExcluded = ScanPool.fromFullJson({
        'masque': {
          'h2': {'v4_cidr': ['162.159.198.1/32'], 'exclude': ['162.159.198.1']},
        },
      })!;
      expect(allExcluded.randomMasqueIp('h2', rng), isNull);
      // Только h3-хосты, без h2-блока: пул валиден, h2-рандом пуст.
      final h3only = ScanPool.fromFullJson({
        'masque': {'hosts_preset': ['162.159.198.2']},
      })!;
      expect(h3only.hasData, isTrue);
      expect(h3only.randomMasqueIp('h2', rng), isNull);
      expect(h3only.randomMasqueIp('auto', rng), isNull);
    });

    test('§418 api.hosts: порядок сохраняется, хвостовой / и пустые срезаются',
        () {
      final pool = ScanPool.fromFullJson({
        'api': {
          'hosts': [
            'https://api.devices.cloudflare.com/',
            '',
            ' https://api.cloudflareclient.com ',
          ],
        },
        'wireguard': {
          'v4_cidr': ['162.159.192.0/24'],
          'ports': [2408],
        },
      });
      expect(pool!.apiHosts, [
        'https://api.devices.cloudflare.com',
        'https://api.cloudflareclient.com',
      ]);
    });

    test('§418 api.hosts отсутствует (старый asset/override) → пусто', () {
      final pool = ScanPool.fromFullJson({
        'wireguard': {
          'v4_cidr': ['162.159.192.0/24'],
          'ports': [2408],
        },
      });
      expect(pool!.apiHosts, isEmpty);
    });
  });

  group('§425 loc-регионы', () {
    final json = <String, dynamic>{
      'wireguard': {
        'v4_cidr': ['162.159.192.0/24'],
        'ports': [2408],
        'sni_pool': ['a', 'b'],
      },
      'masque': {
        'v4_cidr': ['162.159.198.0/24'],
        'sni_pool': ['m'],
        'recommended_sni': 'm',
      },
      'loc': {
        'ru': {
          'wireguard': {'sni_pool': ['x']},
        },
        'by': {'alias': 'ru'},
        'broken': 'not-a-map',
      },
    };

    test('regionsOf — ключи loc, только Map-секции', () {
      expect(ScanPool.regionsOf(json), ['ru', 'by']);
      expect(ScanPool.regionsOf({'wireguard': {}}), isEmpty);
      expect(ScanPool.regionsOf(null), isEmpty);
    });

    test('override по ключу; не переопределённое — из корня; список целиком',
        () {
      final ru = ScanPool.fromFullJson(json, region: 'ru')!;
      expect(ru.wgSniPool, ['x']);
      expect(ru.wgPorts, [2408]);
      expect(ru.masqueSniPool, ['m']);
      expect(ru.masqueRecommendedSni, 'm');
    });

    test('alias — один переход на другую секцию', () {
      expect(ScanPool.fromFullJson(json, region: 'by')!.wgSniPool, ['x']);
    });

    test('пустой/неизвестный/битый регион = корень; регистр не важен', () {
      expect(ScanPool.fromFullJson(json)!.wgSniPool, ['a', 'b']);
      expect(ScanPool.fromFullJson(json, region: 'zz')!.wgSniPool, ['a', 'b']);
      expect(ScanPool.fromFullJson(json, region: 'broken')!.wgSniPool,
          ['a', 'b']);
      expect(ScanPool.fromFullJson(json, region: 'RU')!.wgSniPool, ['x']);
    });

    test('asset без loc парсится как раньше', () {
      final noLoc = Map<String, dynamic>.from(json)..remove('loc');
      expect(ScanPool.fromFullJson(noLoc, region: 'ru')!.wgSniPool, ['a', 'b']);
    });

    test('applyRegion снимает ключ loc и не трогает исходник', () {
      final out = ScanPool.applyRegion(json, 'ru');
      expect(out.containsKey('loc'), isFalse);
      expect((out['wireguard'] as Map)['sni_pool'], ['x']);
      expect((json['wireguard'] as Map)['sni_pool'], ['a', 'b']);
    });
  });
}
