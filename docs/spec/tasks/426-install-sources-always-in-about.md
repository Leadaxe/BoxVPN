# 426 — About: все источники установки видны всегда, а не только при обновлении

| Field | Value |
|------|----------|
| Status | Implemented (unit-тесты, analyze, l10n-чекеры); DEVICE-PENDING: карточка на устройстве не проверена |
| Started | 2026-09-08 |
| Trigger | Запрос владельца 08.09.2026: «сделай возможность перехода на Google Play или другой источник не только когда обновления, а всегда» |
| Related | [§390](390-install-source-aware-update-notice.md) (канал установки, `InstallSource`, адреса сторов), [§036](../features/036%20update%20check/spec.md) (чекер обновлений и About-блок), [§221](221-backup-export-allowlist-asymmetry.md) (бэкап — единственный путь переезда между каналами), [§395](395-update-check-consent.md) (согласие на чек) |

## Проблема

После §390 ссылка на «свой» стор («Open in Google Play» / «View release») живёт
только внутри блока обновлений About и рисуется лишь когда `UpdateChecker`
нашёл версию новее локальной. Пока обновления нет — или чек выключен (§395,
дефолт для сторовых сборок) — из приложения нельзя ни открыть страницу своего
стора, ни узнать, что приложение есть ещё где-то. Переезд GitHub → Play (или
обратно, когда Play недоступен) требует знать адреса наизусть.

## Решение

Отдельная карточка `_SourcesCard` в About сразу под блоком обновлений — три
строки, по одной на каждое значение `InstallSource`, **всегда**:

| Строка | Адрес (`InstallSource.pageUrl`) | Фолбэк |
|---|---|---|
| GitHub | `ProjectLinks.latestRelease` (`/releases/latest`, без тега) | — |
| Google Play | `market://details?id=…` | `https://play.google.com/store/apps/details?id=…` (`updateUrlFallback`, §390) |
| F-Droid | `https://f-droid.org/packages/…/` | — |

- Текущий канал (`InstallSourceResolver.current`) помечен галочкой и подписью
  «Installed from here», но кликабелен так же — страница своего стора нужна и
  без обновления (отзыв, поделиться).
- Подвал карточки объясняет, почему нельзя просто поставить поверх: у каждого
  источника свой ключ подписи; порядок переезда — бэкап → удалить → поставить из
  нового источника → восстановить. Это единственный работающий путь (§390,
  «signatures do not match»).
- Блок обновлений (§036/§390) не меняется: его кнопка по-прежнему ведёт на
  страницу конкретного релиза своего канала.

`pageUrl` добавлен рядом с `updateUrl` в `InstallSourceX`, а не заменяет его:
у GitHub адреса разные (`latest` против `tag/<v>`), у сторов совпадают.

## Что НЕ делается

| Не делается | Почему |
|---|---|
| Скрывать GitHub-строку в Play-сборке | Владелец попросил все источники всегда. Риск: политика Play «Device and Network Abuse» запрещает обновление в обход стора; ссылка на страницу релизов — не самообновление, но если ревью зарубит, строка `github` прячется одним условием `source == InstallSource.github && current == InstallSource.play` |
| Кнопка «сделать бэкап» прямо в карточке | Backup уже в App Settings; дублировать вход ради одного сценария — шум |
| Новые ключи хранилища | нет: карточка чисто презентационная |

## Файлы

- `app/lib/services/install_source.dart` — `InstallSourceX.pageUrl`.
- `app/lib/screens/about_screen.dart` — `_SourcesCard`, вставлена после `_UpdateBlock`.
- `app/assets/l10n/ru/ui.json` — три новых ключа.
- `app/test/services/install_source_test.dart` — группа `pageUrl`.

## Проверка

- `flutter test test/services/install_source_test.dart`, `flutter analyze`,
  четыре l10n-чекера `--strict`.
- DEVICE-PENDING: About на устройстве — три строки, галочка на текущем канале,
  `market://` на устройстве без Play падает в https-фолбэк.
