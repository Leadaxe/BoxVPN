# 305 — MASQUE endpoint: новая схема пула, порт-сплит h3/h2, ручной IP:port

> **§420 (2026-09-05):** секция `masque` asset'а переложена по транспортам (`hosts_preset` общий, `h3.hosts_extra`, `h2.v4_cidr`+`exclude`); `h3_v4_cidr`/`ports_h3`/`ports_h2` — фолбэк для старого JSON. Рекомендуемый хост — `162.159.198.2`, не домен. См. [tasks/420](420-masque-pool-per-transport.md).


Статус: **реализовано** (коммиты `1ab043fc`, `3565fe62`), device-verified на CPH2411.

## Мотивация

Жалоба: генератор WARP («Make experiment») плодит MASQUE-ноды, из которых **h3
почти все мёртвые** (1 живая из 62), при этом h2 и AWG работают.

Разбор дал два независимых корня — один в данных пула, второй в **методике
измерения** (из-за неё же ранние выводы были ложными).

## ⚠️ Методика измерения живости нод (иначе результаты врут)

Это главная грабля таски. Все ранние выводы «h3 мёртв» оказались артефактами
измерения, а не свойством нод.

| Способ | Годен для h3? | Почему |
|---|---|---|
| `/folders/{id}/probe` при **остановленном** VPN (headless) | **НЕТ** | headless probe-сессия НЕ поднимает QUIC → все h3 дают 0 живых (ложь). h2/TCP при этом меряется нормально |
| `/folders/{id}/probe` при **запущенном** VPN | не работает | отказывает: `probe failed to start: __vpn_running__` |
| `rebuild-config` + `urltest` **без reconnect** | **НЕТ** | ядро продолжает работать на старой сессии → живые ноды показывают `-1` |
| `rebuild-config` + **`/action/reconnect`** + `urltest` **по одной** | **ДА** | единственный достоверный путь |

Дополнительно: **mass-ping даёт ложные `-1` для h3** — параллельные QUIC-хендшейки
конкурируют. Мерить по одной ноде с паузами (~5-6с).

## Device-verified факты (эталон пула)

Проверено на устройстве через боевое ядро (reconnect + urltest по одной);
независимо подтверждено внешним исследованием [net4people/bbs#418](https://github.com/net4people/bbs/issues/418).

**MASQUE h2 (HTTP/2, TCP):**
- Живёт по **всему блоку** `162.159.198.0/24` и `162.159.199.0/24` (десятки IP).

**MASQUE h3 (QUIC):**
- Живёт **ТОЛЬКО на 4 адресах**: `162.159.198.1`, `162.159.198.2`,
  `162.159.199.1`, `162.159.199.2`. На остальных IP блока QUIC не встаёт.
- Отсюда главный баг: рандом h3-IP по /24 давал попадание ~1% → мёртвые ноды.

**Общее:**
- **Порты — все 7 для обоих транспортов**: `443, 500, 1701, 4500, 4443, 8443, 8095`.
- **SNI для h3 не важен** — работает даже несуществующий домен (проверено
  `zzz.random123.xyz`). Ограничений по SNI нет.
- Блоки `162.159.197.0/24` и `162.159.192.0/24` для MASQUE — **0 живых**, убраны.
- **ОПРОВЕРГНУТО:** прежнее «h3 поднимается только на сервере регистрации
  (`acc.server`), на чужом IP → `CRYPTO_ERROR x509`». Это был артефакт
  headless-probe. Форсинг h3→`acc.server` в `scan_node_builder` **снят**.
- **IPv6 h3-эндпоинт** `[2606:4700:103::2]` (из того же исследования) —
  проверить не удалось: у тест-девайса нет глобального v6 (только ULA `fdff::`).
  В пул не внесён.

---

## A. Схема `app/assets/warp_endpoints.json`

> §425 — поверх этой схемы добавлена секция `loc.<cc>` (региональные
> переопределения с фолбэком на корень, alias). Формат и правила слияния —
> в [§425](425-warp-pool-region-loc.md); тот же парсер, тот же JSON-override.

Файл переписан **по транспорту** (была плоская мешанина: root `prefixes`/`ports`/
`sni_pool`/`masque_sni_pool` + вложенный блок `scan` со всем остальным).

```json
{
  "wireguard": {
    "v4_cidr": [...], "v6_cidr": [...],
    "ports": [2408, 500, 1701, 4500],
    "ports_extra": [...],
    "sni_pool": [...],
    "utls_fp_pool": [...]
  },
  "masque": {
    "v4_cidr":    ["162.159.198.0/24", "162.159.199.0/24"],
    "h3_v4_cidr": ["162.159.198.1/32", "162.159.198.2/32",
                   "162.159.199.1/32", "162.159.199.2/32"],
    "ports_h3": [443, 500, 1701, 4500, 4443, 8443, 8095],
    "ports_h2": [443, 500, 1701, 4500, 4443, 8443, 8095],
    "sni_pool": [...]
  }
}
```

**`masque.h3_v4_cidr`** — ключевое: отдельный узкий источник IP для h3.
Записан CIDR'ами (`/32`), а не голыми IP — единообразно с остальными полями и на
будущее (если найдётся живой под-диапазон). `masque.v4_cidr` остаётся широким —
он для h2.

Переименования: `wg_ports_empirical` → `wireguard.ports_extra`,
`sni_pool` (root) → `wireguard.sni_pool`, `masque_sni_pool` → `masque.sni_pool`,
`masque_port` (скаляр) → `masque.ports_h3`/`ports_h2` (списки).

## B. Пул и генератор

### `scan_pool.dart`
- Единый парсер новой структуры: **`ScanPool.fromFullJson(json)`** (заменил
  `fromJson(scanBlock, sniPool:, masqueSniPool:)`). Используется и для bundled
  asset, и для JSON-override окна эксперимента.
- Поля: `wgV4Cidr`/`wgV6Cidr`/`wgPorts`/`wgPortsExtra`/`wgSniPool`/`utlsFpPool`,
  `masqueV4Cidr`/**`masqueH3V4Cidr`**/`masquePortsH3`/`masquePortsH2`/`masqueSniPool`.
- Геттеры по транспорту:
  - `masquePortsFor(net)` — `h2` → h2-набор, иначе h3-набор.
  - **`masqueV4CidrFor(net)`** — `h2` → `masqueV4Cidr` (блок); `h3` →
    `masqueH3V4Cidr`, с фолбэком на блок если h3-список пуст.

### `candidate_generator.dart`
- `_masqueCandidate(proto)` — IP берётся **по транспорту** через
  `masqueV4CidrFor(net)`; порт — через `_pickMasquePort(proto)`.
- `_variationOne` (фаза 2) — та же развилка по порту.
- `allowV6` (дефолт `false`) — v6-кандидаты только при системном IPv6 (см. D).

### `scan_node_builder.dart`
- Форсинг h3 на `acc.server:acc.port` **снят** — h3 и h2 оба берут `c.ip:c.port`.

### `warp_endpoint_picker.dart`
- Тонкая обёртка над `ScanPool`: `randomEndpoint({allowV6})`,
  `randomMasqueIp()`, `randomMasquePortFor(net)`, `masquePortsFor(net)`,
  `masqueV4Cidr`, `loadRawJson()` (сырой asset для JSON-редактора).

## C. Визард — ручной override endpoint MASQUE

`warp_wizard_screen.dart`, MASQUE-блок (standalone `Card` при `_isMasque`):

- **Endpoint IP** (`_masqueIp`) — ручной ввод + 🎲 (случайный IP из блока +
  случайный порт транспорта). Пусто → сервер из регистрации; placeholder
  показывает его реальный адрес (подтягивается из закешированного
  `MasqueAccount.server`, дефолт `MasqueAccount.defaultServer`).
- **Port** (`_masquePort`) — `DropdownButtonFormField` из
  `masquePortsFor(_masqueNetwork)`; предзаполняется первым портом набора,
  пересинхронизируется при смене h3↔h2 (`_syncDefaultMasquePort`).
- Поля видны для **обоих** транспортов (h3 больше не привязан к серверу реги).

Проброс: `_registerMasque` → `addMasque(server:, port:)` →
пересборка `MasqueAccount` полным конструктором (`copyWith` не несёт
server/port) при заданном **server ИЛИ port** (порт-only override не теряется).
Override применяется **только к узлу** — в `SettingsStorage.setMasqueAccount`
пишется канонический аккаунт с сервером регистрации.

## D. Окно эксперимента → отдельный экран

`WarpExperimentScreen` (`warp_experiment_screen.dart`) заменил `AlertDialog`:
число нод + **редактируемый JSON пула** (дефолт — bundled asset через
`loadRawJson`), кнопка **Reset**, inline-валидация (битый JSON → `errorText`,
не роняет экран). Результат `(count, pool)` → `generateWarp(poolOverride:)`.

Навигация: после генерации папка «WARP GENERATOR» открывается через
**`pushReplacement`** — «назад» из папки ведёт на Servers, а не обратно в визард.

## E. IPv6-гейт

v6-endpoint подставляется только при включённом системном IPv6 (глобальная
template-var **`ipv6_enabled`**, дефолт `false`) — иначе v6-нода мертва (нет
маршрута). Гейт в трёх точках: `randomEndpoint(allowV6:)`,
`CandidateGenerator(allowV6:)`, проброс из `addWarp`/`generateWarp`/визарда.

---

## Тесты

- `scan_pool_test` — парс новой структуры; `masquePortsFor` разделяет h3/h2;
  masque-only пул валиден; null/пустой → null.
- `candidate_generator_test` — порт согласован с протоколом (h3≠h2);
  **h3-IP только из h3-списка, h2-IP из блока**; фолбэк при пустом h3-списке.
- `warp_endpoint_picker_test` — asset несёт `.198`/`.199`, `h3_v4_cidr` = 4 хоста,
  порты = все 7; `randomMasqueIp` в известных блоках.
- `scan_node_builder_test` — h3 И h2 несут IP:port кандидата (форсинг снят).

## Границы / известные хвосты

- IPv6 h3-хост `[2606:4700:103::2]` не проверен (нет глобального v6 на девайсе).
- Нет теста на `addMasque(server:, port:)` — в тест-дереве отсутствует
  fake/mock `WarpClient`, нужен для драйва этого пути.
- Эффективность генератора (доля h3 vs h2 в посеве) не тюнилась.

## Связанное

- §304 — `persistent_keepalive` в Advanced ручной регистрации WARP (тот же круг).
- §284 — WARP GENERATOR (папка/посев), §130 — MASQUE-транспорт.
