import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/settings_storage.dart';
import 'package:lxbox/services/usage_region.dart';

/// §425 — регион использования: настройка + автодетект.
void main() {
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  late Directory tmp;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tmp = await Directory.systemTemp.createTemp('lxbox_usage_region_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getApplicationDocumentsDirectory' ||
          call.method == 'getApplicationDocumentsPath') {
        return tmp.path;
      }
      return null;
    });
    SettingsStorage.resetCacheForTesting();
    UsageRegion.resetForTest();
    UsageRegion.detectorOverride = null;
  });

  tearDown(() async {
    UsageRegion.detectorOverride = null;
    await tmp.delete(recursive: true);
  });

  test('normalizeRegion: auto/default/cc; мусор → auto', () {
    expect(SettingsStorage.normalizeRegion('auto'), 'auto');
    expect(SettingsStorage.normalizeRegion('None'), 'none');
    expect(SettingsStorage.normalizeRegion(' RU '), 'ru');
    expect(SettingsStorage.normalizeRegion('rus'), 'auto');
    expect(SettingsStorage.normalizeRegion(''), 'auto');
  });

  test('дефолт настройки — auto; set/get нормализуют', () async {
    expect(await SettingsStorage.getRegion(), 'auto');
    await SettingsStorage.setRegion('IL');
    expect(await SettingsStorage.getRegion(), 'il');
    expect(SettingsStorage.allowedVarKeys(const []), contains('region'));
  });

  test('effective: auto → детект; none → корень; явный → как есть',
      () async {
    UsageRegion.detectorOverride = () async => 'RU';
    expect(await UsageRegion.effective(), 'ru');

    await SettingsStorage.setRegion('none');
    expect(await UsageRegion.effective(), '');

    await SettingsStorage.setRegion('il');
    expect(await UsageRegion.effective(), 'il');
  });

  test('detected: мусор от нативки → локаль/пусто, кэш на процесс', () async {
    UsageRegion.detectorOverride = () async => 'xyz';
    final d = await UsageRegion.detected();
    // Фолбэк на Platform.localeName: либо 2-буквенный код, либо пусто.
    expect(d.isEmpty || RegExp(r'^[a-z]{2}$').hasMatch(d), isTrue);
    UsageRegion.detectorOverride = () async => 'ru';
    expect(await UsageRegion.detected(), d, reason: 'кэш не сброшен');
    UsageRegion.resetForTest();
    expect(await UsageRegion.detected(), 'ru');
  });
}
