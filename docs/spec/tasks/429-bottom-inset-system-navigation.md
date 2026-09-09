# 429 — Нижний отступ под системную навигацию: шторки и экраны единообразно

| Field | Value |
|------|----------|
| Status | Done, DEVICE-VERIFIED (AVD LxBox_test, API 34, трёхкнопочная навигация, 09.09.2026): шторка DNS-правила — Save целиком над панелью, с клавиатурой поднимается без двойного зазора; владелец проверил |
| Started | 2026-09-09 |
| Trigger | 4PDA 09.09.2026 (Redmi 12s): «в добавить dns кнопка сохранить как на 3 скрине, неудобно нажимать» — кнопка «Save» шторки DNS-правила наполовину под трёхкнопочной панелью навигации. Владелец: «проверить все экраны, что внизу есть отступ, решить системно» |
| Related | [§211](211-foreign-vpn-switch-dialog.md) (первая шторка с ручным viewInsets), [§333](333-large-text-virtualization.md) (`BigTextView`/`BigTextSliver` — хвосты логов) |

## Проблема

Android рисует приложение edge-to-edge: системная панель навигации (жесты
или три кнопки, до 48dp) ложится ПОВЕРХ нижнего края окна. Flutter отдаёт её
высоту как `MediaQuery.padding.bottom`, но применяет автоматически только в
двух случаях: `Scaffold.bottomNavigationBar`/`persistentFooterButtons` и
скроллер БЕЗ явного `padding:`. Всё остальное — забота экрана.

Аудит (184 файла в `lib/screens` + `lib/widgets`) показал три сорта поведения:

| Где | Как было |
|---|---|
| 26 вызовов `showModalBottomSheet` в 22 файлах | половина — `SafeArea` внутри, четверть — только `viewInsets` (клавиатура, не панель), остальное — ничего. Шторка DNS-правила из жалобы: `viewInsets` есть, панели нет |
| 18 скроллеров/футеров с явным `padding:` | константный низ 8–32 px, панель не учтена: About, Backup, Speed test, WARP wizard, Add server (SOCKS/HTTP), Auto group / Direction edit, хвосты логов OOM/источника подписки, настройки и фильтры подписки, Stats overview, Debug profiling, список узлов главного экрана, редактор конфига, подсказка QR-сканера, `BigTextView` (crash reports) |
| ~25 мест | уже верно: паттерн `MediaQuery.of(context).padding.bottom + 24` или `SafeArea(top: false)` у футера |

## Решение

Два хелпера и два контракт-теста, чтобы правило держалось само.

**1. Шторки — `showAppBottomSheet`** (`lib/widgets/app_bottom_sheet.dart`).
Обёртка над `showModalBottomSheet` с тем же набором параметров; контент
получает `Padding(bottom: viewInsets.bottom)` (клавиатура) →
`MediaQuery.removeViewInsets(removeBottom)` (внутренние «свои» подъёмы над
клавиатурой видят ноль, двойного зазора нет) → `SafeArea(top: false)`
(панель). Все 26 вызовов переведены; четыре ручных `viewInsets` внутри
шторок (DNS-правило, home-меню, фильтр профайлера, пикер Wi-Fi) убраны.
Внутренние `SafeArea` оставлены — после внешней они прибавляют ноль.

**2. Скроллеры — `.withSafeBottom(context)`** (`lib/widgets/safe_bottom.dart`).
Расширение на `EdgeInsets` (и на `EdgeInsetsGeometry` для полей виджета):
`padding: const EdgeInsets.all(16).withSafeBottom(context)`. Безопасно
везде: если выше уже стоит `SafeArea`, он потребил padding и прибавится ноль.
Применено ко всем 18 местам из аудита; подсказка QR-сканера обёрнута в
`SafeArea(top: false)`.

**3. Контракт-тесты** (`test/contract/`):
- `bottom_sheet_helper_test.dart` — `showModalBottomSheet` встречается только
  в хелпере;
- `bottom_inset_contract_test.dart` — вертикальный скроллер с литеральным
  `padding: EdgeInsets…` обязан содержать `withSafeBottom` / `padding.bottom`
  / `paddingOf` / `bottomPad`. Пропускаются горизонтальные ленты
  (`Axis.horizontal`), вложенные `shrinkWrap`, файлы шторок. Осознанное
  исключение помечается на строке `// bottom-inset: handled — <почему>` (пять
  мест: тело под `SafeArea`, футер с `SafeArea` ниже).

## Что НЕ делается

| Не делается | Почему |
|---|---|
| `SafeArea` на корне приложения (`MaterialApp.builder`) | Полоса под панелью показывала бы фон окна, а не скрим/шторку; `bottomNavigationBar` экранов и модальные маршруты ломаются визуально |
| Отказ от edge-to-edge | targetSdk 36: опт-аут `windowOptOutEdgeToEdgeEnforcement` игнорируется |
| Переписывать уже верные `padding.bottom + 24` на расширение | Работает, тест их принимает; менять ради единообразия — шум в diff |

## Файлы

- `app/lib/widgets/app_bottom_sheet.dart`, `app/lib/widgets/safe_bottom.dart` — новые.
- 22 файла шторок, 19 файлов экранов — см. `git show`.
- `app/test/contract/bottom_sheet_helper_test.dart`, `app/test/contract/bottom_inset_contract_test.dart`.
- `CHANGELOG.md` — Fixed.

## Проверка

- `flutter analyze` чист, `flutter test` зелёный (оба контракт-теста в составе).
- Device (AVD LxBox_test, API 34, трёхкнопочная навигация через
  `cmd overlay enable com.android.internal.systemui.navbar.threebutton`):
  DNS → Add rule — кнопка «Save» целиком над панелью; About — низ списка
  докручивается над панелью.
