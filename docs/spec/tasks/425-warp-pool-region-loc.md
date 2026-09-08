# 425 — Регион использования (App Settings → General) + секции `loc.<cc>` пула WARP

| Field | Value |
|------|----------|
| Status | Implemented, device-verified (AVD LxBox_test, 08.09.2026, 2.23.0-dev.13: плитка App Settings → General → Region показывает «Auto · US» — нативный `networkCountry` отдал страну SIM эмулятора; диалог Auto / Not set / RU / Other country code…) |
| Started | 2026-09-06 |
| Trigger | Отчёт k-dmitriy (4PDA, 06.09.2026): `deepseek.com` лежит внутри «российского» хвоста `sni_pool` «и в генераторе, и в экспериментальном». Разбор показал, что дело не в порядке: российские домены в пуле полезны только за российским DPI (§143 — ТСПУ режет по несовпадению SNI с блоком), а для юзера в Израиле или ЕС они шум. |
| Related | [§136](136-warp-quic-i1-generator.md) (WG SNI-пул), [§130](../features/130%20masque-warp-transport/spec.md) (MASQUE SNI-пул), [§305](305-masque-endpoint-h2-pool-and-override.md) (JSON-окно эксперимента, один парсер), [§418](418-warp-api-host-failover.md) (последнее расширение пулов), [§424](424-warp-preset-recommended-mark-leak.md) (первая половина того же отчёта) |

## Формат asset'а (`assets/warp_endpoints.json`)

```json
{
  "wireguard": { "sni_pool": ["www.google.com", …, "deepseek.com"] },
  "masque":    { "sni_pool": ["consumer-masque.cloudflareclient.com", …] },
  "loc": {
    "ru": {
      "wireguard": { "sni_pool": ["yandex.ru", "gosuslugi.ru", …, "www.google.com", …] },
      "masque":    { "sni_pool": ["consumer-masque.cloudflareclient.com", "yandex.ru", …] }
    },
    "by": { "alias": "ru" }
  }
}
```

- Корень = «остальной мир»: международные SNI, без `.ru`. `deepseek.com` остаётся в корне.
- `loc.<cc>` — код страны ISO 3166 в нижнем регистре. Секция накладывается на корень
  (`ScanPool.applyRegion`): Map сливается рекурсивно по ключам, **всё остальное
  (списки, строки, числа) заменяется целиком**. Иначе «убрать домен для региона»
  невозможно. Не переопределённое берётся из корня.
- `{"alias": "xx"}` — ссылка на другую секцию, один переход, без цепочек.
- Неизвестный регион, отсутствие `loc`, секция не-Map → корень без изменений.
  Старый asset и пользовательский JSON без `loc` парсятся как раньше.
- Секции только там, где содержимое реально отличается: `eu`/`us`/`il` не заводятся
  (совпали бы с корнем), `cn`/`ir` — когда появится подтверждённый набор
  (решение владельца 2026-09-06).

## Регион использования (общая настройка)

Решение владельца 2026-09-08: регион — не WARP-настройка, а общая, рядом с языком.
Потребители: сегодня пул WARP (`loc.<cc>`), дальше региональные дефолты правил
маршрутизации. Сервис `UsageRegion` (`lib/services/usage_region.dart`).

Настройка `region` (vars, в allowlist бэкапа): `auto` (дефолт) | `none` | `<cc>`.

- `auto` → `UsageRegion.detected()`: нативный `networkCountry` (`TelephonyManager.networkCountryIso`,
  затем `simCountryIso`; разрешений не требует) → страна из `Platform.localeName` → `''`.
  Код страны, а не UI-язык: русскоязычный юзер в Израиле сидит не за ТСПУ.
  Кэш на процесс; смена SIM в рантайме не отслеживается.
- `none` → без региона (для WARP — корень asset'а).
- Явный код → как есть; потребитель без секции для этого кода берёт свой дефолт.

UI: App Settings → General → блок «Region» → «Usage region». Диалог: Auto (с показом
определённой страны) / Not set / известные регионы (сегодня — ключи `loc` пула WARP)
/ «Other country code…» — произвольный двухбуквенный код. Новая секция в JSON
появляется в меню без правки Dart.

## Где применяется

- `WarpEndpointPicker.load({region})` (регион из `UsageRegion.effective()`) — визард WARP, `generateWarp`, API-хосты. Кэш
  пикера привязан к региону: смена настройки → следующий `load` перечитывает.
- Экран эксперимента (§305): JSON-окно показывает asset целиком, вместе с `loc`;
  `_parsePool` накладывает регион по той же настройке. Юзер правит один формат.

## Тесты

- `test/warp/scan/scan_pool_test.dart` — `regionsOf`, override по ключу с фолбэком
  на корень, замена списка целиком, alias, неизвестный/битый регион, asset без `loc`,
  `applyRegion` не мутирует исходник.
- `test/services/warp_endpoint_picker_test.dart` — корень без `.ru`, `loc.ru` с ними,
  регион не трогает блоки/порты/пресеты, `availableRegions`, кэш по региону.
- `test/services/usage_region_test.dart` — нормализация настройки, `effective` для
  трёх режимов, кэш детекта.

## Не сделано

- Debug API `GET /device` не отдаёт регион; добавить `warp_region`/`detected`, если
  понадобится для разбора отчётов.
