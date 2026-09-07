import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'app_log.dart';
import 'platform_channels.dart';
import 'project_links.dart';

/// §390 — откуда установлено приложение. Один и тот же код и одна и та же
/// версия уезжают в три канала (GitHub Releases, Google Play, F-Droid), и у
/// каждого своя подпись: APK с GitHub не встанет поверх Play-сборки
/// («signatures do not match»), F-Droid подписывает третьим ключом. Значит и
/// «где взять новую версию» у каждого канала своё — отсюда [updateUrl].
///
/// Резолв гибридный: build-time `--dart-define` первичен (в момент сборки мы
/// точно знаем адресата артефакта), рантайм-детект по installer'у — фолбэк для
/// локальных и dev-сборок, где define не задан.
enum InstallSource { github, play, fdroid }

/// Резолвер канала. [init] зовётся один раз в `main()` перед `runApp` (паттерн
/// [VersionInfo]) — после этого [current] синхронно доступен из любого места.
class InstallSourceResolver {
  InstallSourceResolver._();

  static const _channel = MethodChannel(PlatformChannels.utils);

  /// Значение из `--dart-define=LXBOX_DISTRIBUTION=play|fdroid|github`.
  /// Ставится в CI (github/play) и в рецепте fdroiddata (fdroid).
  ///
  /// Это НЕ откат §065/§066: там убирались *версионные* маркеры — версия
  /// переехала в pubspec, у факта появился единственный источник истины.
  /// Канал доставки в pubspec выразить нельзя.
  static const _define = String.fromEnvironment('LXBOX_DISTRIBUTION');

  static InstallSource _current = InstallSource.github;
  static bool _initialized = false;

  /// Канал установки. До [init] — дефолт `github` (самый безопасный: ошибочно
  /// замолчать хуже, чем ошибочно показать GitHub-ссылку).
  static InstallSource get current => _current;

  /// Idempotent — повторный вызов no-op.
  static Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    if (_define.isNotEmpty) {
      final parsed = installSourceFromDefine(_define);
      if (parsed != null) {
        _current = parsed;
        return;
      }
      AppLog.I.warning(
          'InstallSource: unknown LXBOX_DISTRIBUTION="$_define" — using github');
      return;
    }
    String? installer;
    try {
      installer = await _channel.invokeMethod<String>('installSource');
    } catch (e) {
      // Не Android / канал недоступен (тесты) — остаёмся на дефолте.
      AppLog.I.warning('InstallSource: native lookup failed ($e) — using github');
      return;
    }
    _current = installSourceFromInstaller(installer);
    AppLog.I.info(
        'InstallSource: installer=${installer ?? '<null>'} → ${_current.name}');
  }

  /// Тестовый сеттер — прод-код резолвит только через [init].
  @visibleForTesting
  static void setForTest(InstallSource source) {
    _current = source;
    _initialized = true;
  }

  @visibleForTesting
  static void resetForTest() {
    _current = InstallSource.github;
    _initialized = false;
  }
}

/// Парсит значение `--dart-define`. `null` — значение не распознано (caller
/// логирует и остаётся на дефолте).
InstallSource? installSourceFromDefine(String raw) {
  switch (raw.trim().toLowerCase()) {
    case 'github':
      return InstallSource.github;
    case 'play':
      return InstallSource.play;
    case 'fdroid':
      return InstallSource.fdroid;
    default:
      return null;
  }
}

/// Маппинг package name установщика → канал. Вынесен чистой функцией: вся
/// таблица тестируется без `MethodChannel` и без device.
///
/// Дефолт для всего неизвестного — [InstallSource.github] (sideload). Он же
/// для `null`: установка из файлового менеджера или `adb install` installer'а
/// не проставляет.
InstallSource installSourceFromInstaller(String? pkg) {
  switch (pkg) {
    case 'com.android.vending':
      return InstallSource.play;
    // Клиенты каталога F-Droid — приложение подписано ключом F-Droid.
    // ⚠ Obtainium (dev.imranr.obtainium) сюда НЕ входит: он ставит APK с
    // GitHub, подпись наша, значит и обновление ему нужно с GitHub.
    case 'org.fdroid.fdroid':
    case 'org.fdroid.basic':
    case 'com.looker.droidify':
      return InstallSource.fdroid;
    default:
      return InstallSource.github;
  }
}

extension InstallSourceX on InstallSource {
  /// Человекочитаемое имя канала — About + дамп версии (§378). Не переводится:
  /// это имена собственные.
  String get label => switch (this) {
        InstallSource.github => 'GitHub',
        InstallSource.play => 'Google Play',
        InstallSource.fdroid => 'F-Droid',
      };

  /// Куда вести пользователя за новой версией. Один метод вместо булева флага
  /// «показывать ли GitHub-ссылку»: вызывающему не нужно знать канал.
  ///
  /// Для Play — `market://`, чтобы открылся сам клиент стора. Если Play на
  /// устройстве нет (а это ровно наша аудитория), intent не резолвится —
  /// фолбэк [updateUrlFallback] обрабатывается в native `openUrl`.
  ///
  /// Ссылка в СВОЙ стор политику Play не нарушает: Device and Network Abuse
  /// запрещает обновление в обход стора, здесь обновление идёт через стор.
  String updateUrl(String tag) => switch (this) {
        InstallSource.github => ProjectLinks.releaseTag(tag),
        InstallSource.play => ProjectLinks.playPage,
        InstallSource.fdroid => ProjectLinks.fdroidPage,
      };

  /// Https-форма для каналов, где основной URL — custom scheme. `null` если
  /// фолбэк не нужен.
  String? get updateUrlFallback => switch (this) {
        InstallSource.play => ProjectLinks.playPageWeb,
        InstallSource.github || InstallSource.fdroid => null,
      };

  /// §426 — страница канала БЕЗ привязки к релизу: About показывает все три
  /// источника всегда, а не только когда чекер нашёл новую версию. У сторов
  /// это та же страница приложения, что и в [updateUrl]; у GitHub — «latest»
  /// вместо конкретного тега. Фолбэк тот же — [updateUrlFallback].
  String get pageUrl => switch (this) {
        InstallSource.github => ProjectLinks.latestRelease,
        InstallSource.play => ProjectLinks.playPage,
        InstallSource.fdroid => ProjectLinks.fdroidPage,
      };
}
