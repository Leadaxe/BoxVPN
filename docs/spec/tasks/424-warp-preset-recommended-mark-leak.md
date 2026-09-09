# 424 — WARP wizard: пометка «(recommended)» утекала из combobox в конфиг

| Field | Value |
|------|----------|
| Status | Implemented (unit + widget test) |
| Started | 2026-09-06 |
| Trigger | Отчёт k-dmitriy (4PDA, 06.09.2026): после выбора рекомендованного SNI в генераторе WARP узел получает `"server_name": "consumer-masque.cloudflareclient.com (recommended)"`. |
| Related | [§386](386-warp-endpoint-preset-combobox.md) (пометка recommended в пресетах), [§130](../features/130%20masque-warp-transport/spec.md) (MASQUE-визард), [§420](420-masque-pool-per-transport.md) (пул хостов по транспорту) |

## Причина

`_presetEntry` в `warp_wizard_screen.dart` клал пометку в `DropdownMenuEntry.label`.
`DropdownMenu` Flutter при выборе пункта пишет в контроллер **`entry.label`**,
а не `value` (`dropdown_menu.dart`, обработчик `onPressed` пункта). Дальше
текст контроллера без очистки уходит в `addMasque` / `addWarp`.

Затронуты все три combobox-а с пометкой: MASQUE SNI, MASQUE Endpoint IP,
WG endpoint. Кубик и ручной ввод не затронуты — только выбор помеченного
пункта из меню.

## Решение

Вынесен `warpPresetEntry(value, recommended, mark)` (top-level, тестируемый):
`label` всегда равен чистому значению, пометка — только в
`DropdownMenuEntry.labelWidget` (виден в меню, в поле не попадает). Пустой
`recommended` → пометок нет. Строка перевода `"(recommended)"` та же.

Очистка на стороне чтения (`_masqueSni.text` и т.п.) намеренно не добавлена:
единственный источник пометки — сам пункт меню, и он больше её не отдаёт.

## Тесты

`test/screens/warp_wizard_preset_entry_test.dart`:
- `label` = значение, `labelWidget` только у recommended, пустой recommended — ни у кого;
- widget-тест: тап по пункту с пометкой → в контроллере чистое значение.
  `DropdownMenu` держит невидимую копию пунктов для замера ширины, поэтому
  видимость пометки проверяется `findsWidgets`.

## Не сделано

Замечание того же отчёта про `deepseek.com` внутри «российского» хвоста
`sni_pool` не правилось: обсуждается региональная секция `loc.<country>`
asset'а `warp_endpoints.json` с фолбэком на корень (отдельная спека).
