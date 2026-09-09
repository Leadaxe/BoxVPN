import 'package:flutter_test/flutter_test.dart';
import 'package:lxbox/services/install_source.dart';
import 'package:lxbox/services/project_links.dart';

/// §390 — канал установки: маппинг installer → [InstallSource] и адрес
/// обновления. Чистые функции, без `MethodChannel` и без device.
void main() {
  group('installSourceFromInstaller', () {
    test('Play Store', () {
      expect(installSourceFromInstaller('com.android.vending'),
          InstallSource.play);
    });

    test('клиенты F-Droid', () {
      expect(installSourceFromInstaller('org.fdroid.fdroid'),
          InstallSource.fdroid);
      expect(installSourceFromInstaller('org.fdroid.basic'),
          InstallSource.fdroid);
      expect(installSourceFromInstaller('com.looker.droidify'),
          InstallSource.fdroid);
    });

    test('null (файловый менеджер / adb install) → github', () {
      expect(installSourceFromInstaller(null), InstallSource.github);
    });

    test('adb install → github', () {
      expect(
          installSourceFromInstaller('com.android.shell'), InstallSource.github);
    });

    test('системный installer → github', () {
      expect(installSourceFromInstaller('com.android.packageinstaller'),
          InstallSource.github);
      expect(installSourceFromInstaller('com.google.android.packageinstaller'),
          InstallSource.github);
    });

    test('неизвестный пакет → github (дефолт)', () {
      expect(installSourceFromInstaller('com.example.whatever'),
          InstallSource.github);
    });

    test('Obtainium ставит APK с GitHub → github, не fdroid', () {
      // Ключевой кейс: «сторонний стор», но подпись наша и обновление
      // нужно именно с GitHub.
      expect(installSourceFromInstaller('dev.imranr.obtainium'),
          InstallSource.github);
    });
  });

  group('installSourceFromDefine', () {
    test('валидные значения', () {
      expect(installSourceFromDefine('github'), InstallSource.github);
      expect(installSourceFromDefine('play'), InstallSource.play);
      expect(installSourceFromDefine('fdroid'), InstallSource.fdroid);
    });

    test('регистр и пробелы не важны', () {
      expect(installSourceFromDefine('  PLAY '), InstallSource.play);
      expect(installSourceFromDefine('FDroid'), InstallSource.fdroid);
    });

    test('мусор → null (caller логирует и остаётся на дефолте)', () {
      expect(installSourceFromDefine('xyz'), isNull);
      expect(installSourceFromDefine(''), isNull);
    });
  });

  group('updateUrl — куда вести за новой версией', () {
    test('github → страница релиза', () {
      expect(InstallSource.github.updateUrl('v2.18.0'),
          ProjectLinks.releaseTag('v2.18.0'));
      expect(InstallSource.github.updateUrlFallback, isNull);
    });

    test('play → market:// + https-фолбэк', () {
      expect(InstallSource.play.updateUrl('v2.18.0'), ProjectLinks.playPage);
      expect(InstallSource.play.updateUrl('v2.18.0'), startsWith('market://'));
      // Фолбэк обязателен: без Play на устройстве intent не резолвится.
      expect(InstallSource.play.updateUrlFallback, ProjectLinks.playPageWeb);
      expect(InstallSource.play.updateUrlFallback, startsWith('https://'));
    });

    test('fdroid → страница пакета, фолбэк не нужен', () {
      expect(InstallSource.fdroid.updateUrl('v2.18.0'), ProjectLinks.fdroidPage);
      expect(InstallSource.fdroid.updateUrlFallback, isNull);
    });

    test('тег подставляется только у github (у сторов — страница приложения)',
        () {
      expect(InstallSource.play.updateUrl('v2.18.0'),
          InstallSource.play.updateUrl('v9.9.9'));
      expect(InstallSource.github.updateUrl('v2.18.0'),
          isNot(InstallSource.github.updateUrl('v9.9.9')));
    });
  });

  group('pageUrl (§426 — источники в About всегда)', () {
    test('github → latest, без тега', () {
      expect(InstallSource.github.pageUrl, ProjectLinks.latestRelease);
      expect(InstallSource.github.pageUrl, isNot(contains('/tag/')));
    });

    test('сторы → та же страница приложения, что и updateUrl', () {
      expect(InstallSource.play.pageUrl, InstallSource.play.updateUrl('v0'));
      expect(InstallSource.fdroid.pageUrl, InstallSource.fdroid.updateUrl('v0'));
    });

    test('у каждого источника свой адрес', () {
      final urls = InstallSource.values.map((s) => s.pageUrl).toSet();
      expect(urls.length, InstallSource.values.length);
    });
  });

  group('label', () {
    test('имена каналов', () {
      expect(InstallSource.github.label, 'GitHub');
      expect(InstallSource.play.label, 'Google Play');
      expect(InstallSource.fdroid.label, 'F-Droid');
    });
  });

  group('InstallSourceResolver', () {
    tearDown(InstallSourceResolver.resetForTest);

    test('дефолт до init — github (безопасный)', () {
      InstallSourceResolver.resetForTest();
      expect(InstallSourceResolver.current, InstallSource.github);
    });

    test('setForTest подменяет канал', () {
      InstallSourceResolver.setForTest(InstallSource.play);
      expect(InstallSourceResolver.current, InstallSource.play);
    });
  });
}
