import 'dart:io' show Platform;

import 'package:flutter/services.dart';

import 'app_log.dart';
import 'platform_channels.dart';
import 'settings_storage.dart';

/// §425 — регион использования приложения: страна, в которой юзер сидит за
/// сетью. Общая настройка (App Settings → General, рядом с языком), а не
/// WARP-специфичная: сегодня по ней выбирается секция `loc.<cc>` пула WARP,
/// дальше — региональные дефолты правил маршрутизации.
///
/// Настройка `region`: `auto` — страна определяется сама, `none` — без региона,
/// иначе явный код страны. Автоопределение: страна текущей сети (MCC оператора
/// / SIM, нативно) → страна из локали устройства → пусто. Код страны, а не
/// UI-язык: русскоязычный юзер в Израиле сидит не за ТСПУ, и российские
/// дефолты ему ни к чему.
class UsageRegion {
  UsageRegion._();

  static const _channel = MethodChannel(PlatformChannels.utils);

  /// Автоопределённая страна (кэш на процесс; `''` — не определилась).
  static String? _detected;

  /// Для тестов / инъекции: подмена нативного детекта.
  static Future<String?> Function()? detectorOverride;

  /// Эффективный код региона (`''` = корень). Учитывает настройку.
  static Future<String> effective() async {
    final setting = await SettingsStorage.getRegion();
    if (setting == SettingsStorage.regionNone) return '';
    if (setting != SettingsStorage.regionAuto) return setting;
    return detected();
  }

  /// Страна по сети/локали (нижний регистр, 2 буквы; `''` если неизвестна).
  static Future<String> detected() async {
    final cached = _detected;
    if (cached != null) return cached;
    String? cc;
    try {
      cc = detectorOverride != null
          ? await detectorOverride!()
          : await _channel.invokeMethod<String>('networkCountry');
    } catch (e) {
      // Не Android / канал недоступен (тесты) — идём в локаль.
      AppLog.I.debug('UsageRegion: native lookup failed ($e)');
    }
    cc ??= _localeCountry();
    final norm = cc.trim().toLowerCase();
    return _detected = RegExp(r'^[a-z]{2}$').hasMatch(norm) ? norm : '';
  }

  /// Страна из `Platform.localeName` (`ru_RU`, `en-US`, `he_IL`).
  static String _localeCountry() {
    try {
      final m = RegExp(r'^[A-Za-z]{2,3}[_-]([A-Za-z]{2})\b')
          .firstMatch(Platform.localeName);
      return m?.group(1) ?? '';
    } catch (_) {
      return '';
    }
  }

  /// Сброс кэша детекта (тесты; смена SIM в рантайме не отслеживается).
  static void resetForTest() => _detected = null;
}
