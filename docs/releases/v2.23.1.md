# L×Box v2.23.1

**A maintenance release around issue #115.** The tunnel now comes back on its
own after the process is killed — `START_STICKY` plus an AlarmManager watchdog,
because on a `VpnService` the sticky restart alone loses a race inside
system_server. A VPN running in a work profile (Shelter) is no longer mistaken
for a conflicting one, and Start no longer crashes on Android 10. On top of
that: a Region setting next to the language, all three install sources always
visible in About, the “(recommended)” mark no longer leaking into WARP configs,
and `RECORD_AUDIO` removed from the APK.

**Ремонтный релиз вокруг issue #115.** Туннель возвращается сам после гибели
процесса — `START_STICKY` плюс сторож на AlarmManager, потому что у `VpnService`
один sticky-рестарт проигрывает гонку внутри system_server. VPN в рабочем
профиле (Shelter) больше не считается конфликтующим, а Start не падает на
Android 10. Сверх того: настройка Region рядом с языком, все три источника
установки всегда видны в About, пометка «(recommended)» больше не утекает в
конфиги WARP и `RECORD_AUDIO` убран из APK.

---

<details open>
<summary><h2>🇬🇧 English</h2></summary>

## 🛟 The tunnel returns after the process dies ([docs/spec/tasks/428](docs/spec/tasks/428-vpn-service-start-sticky.md), issue #115)

After an OOM kill, lmkd, an OEM cleaner or sometimes a night-time reboot,
Always-on did not bring the tunnel back until the app was opened by hand.
`BoxService.onStartCommand` returned `START_NOT_STICKY` from both of its exits —
an explicit request to the system *not* to recreate the service.

The fix is `START_STICKY` from both exits **plus** a watchdog, because on a
`VpnService` sticky alone is not enough. Reproduced on an AVD (API 34): after
`kill -9` of a running tunnel there is an `am_proc_died` but no
`am_schedule_service_restart` — the kernel closes the dead process's tun fd,
netd reports `interfaceRemoved`, and the framework's `unbindService` on its
`BIND_AUTO_CREATE` binding races ahead of the binder-death handling, so
ActiveServices wipes the service record before it would have been rescheduled.

The watchdog is a “dead man's” alarm: `ELAPSED_REALTIME` every two minutes,
re-armed by the service ticker while the tunnel is up. If the receiver fires and
finds `vpn_desired && status == Stopped`, it starts the service. It is armed
only while the tunnel is meant to be up, so a healthy device is not woken;
a manual Stop clears `vpn_desired` and the alarm with it. A storm fuse stops the
cycle after two automatic restarts in five minutes and posts a notification.

Device-verified on an AVD: recovery in 3m00s after `kill -9`, and six minutes of
silence after a manual Stop.

## 🧩 A work-profile VPN is not a conflict; Start no longer crashes on Android 10 ([docs/spec/tasks/427](docs/spec/tasks/427-foreign-vpn-active-network-api30.md), issue #115)

Two independent holes in `isForeignVpnActive()`:

| Before | Now |
|---|---|
| The check walked `ConnectivityManager.allNetworks` and called any `TRANSPORT_VPN` network that was not ours a foreign VPN — including the VPN of a neighbouring profile. A user with a tunnel inside Shelter got the “Another VPN is active” dialog on every manual Start | Only `activeNetwork` — the default network **for our uid**. Android keeps one VPN slot per profile, so a work-profile tunnel never lands there and never gets revoked by our `establish()` |
| `caps.ownerUid` was gated on API 29 with a comment claiming it exists there. It does not: `getOwnerUid()` is public only from API 30, and on Android 10 the call throws `NoSuchMethodError` — an `Error`, which `catch (e: Exception)` does not catch, so it escaped the MethodChannel handler on the main thread and killed the app | The gate is API 30, and the whole block catches `Throwable`. On Android 10 the Start button no longer crashes in exactly the situation §361 was meant to fix |

Device-verified: an L×Box VPN inside a managed profile, Start in the personal
profile with no dialog, tun0 and tun1 alive at the same time.

## 🌍 Region — an app-wide setting ([docs/spec/tasks/425](docs/spec/tasks/425-warp-pool-region-loc.md))

A new tile in App Settings → General, next to the language: `Auto` (the
network's country, falling back to the locale), `Not set`, or an explicit
country code. The region is not a WARP setting — WARP is merely its first
consumer, rules come next.

In `assets/warp_endpoints.json` the pool now takes regional `loc.<cc>` sections
that are merged over the root: maps merge key by key, everything else (lists,
strings, numbers) is replaced wholesale — otherwise “drop this domain for this
region” would be impossible. `{"alias": "xx"}` points at another section (one
hop, no chains); an unknown region, a missing `loc` or a non-map section leaves
the root untouched, so an old asset and a user JSON without `loc` parse exactly
as before.

Russian domains (`yandex.ru`, `gosuslugi.ru`, …) moved into `loc.ru`: they are
useful behind Russian DPI, where the ТСПУ cuts on an SNI mismatch, and are noise
for a user in Israel or the EU. `deepseek.com` stays in the root. Sections are
created only where the content actually differs — `eu`/`us`/`il` would repeat
the root, `cn`/`ir` wait for a confirmed set.

## 📦 About: every install source, always ([docs/spec/tasks/426](docs/spec/tasks/426-install-sources-always-in-about.md))

A “Where to get L×Box” card sits right under the update block and lists all
three channels — GitHub, Google Play, F-Droid — at all times, not only when the
checker has found a newer version. The current channel is ticked and captioned
“Installed from here” but stays clickable: the store page is worth opening
without an update too, for a review or to share. Google Play opens through
`market://` with an `https://play.google.com/...` fallback when no Play client
is installed.

The footer explains why you cannot simply install one channel's build over
another's: each source signs with its own key, so the move is backup → uninstall
→ install from the new source → restore.

## 🎛 WARP wizard: “(recommended)” stopped leaking into the config ([docs/spec/tasks/424](docs/spec/tasks/424-warp-preset-recommended-mark-leak.md))

Picking the recommended entry in a combobox wrote
`"server_name": "consumer-masque.cloudflareclient.com (recommended)"` into the
node. Flutter's `DropdownMenu` writes `entry.label` — not `value` — into the
controller when an item is chosen. The label is now always the clean value and
the mark lives in `labelWidget`, visible in the menu and never in the field. All
three marked comboboxes were affected: MASQUE SNI, MASQUE Endpoint IP, WG
endpoint.

## 🔇 `RECORD_AUDIO` removed from the APK

The permission leaked into the manifest from `camera_android_camerax` (the QR
scanner). The app does not use the microphone — the permission is stripped with
`tools:node="remove"`.

## 🛠 Toolchain and docs

- Gradle 8.14 → 9.3.1, AGP 8.11.1 → 9.1.0, Kotlin 2.2.20 → 2.3.21
  (`kotlinOptions` → `compilerOptions`).
- `docs/FDROID.md` rewritten to match the recipe as it stands (two ABIs, srclib
  pins to commits, the 3-hour job ceiling, a Permissions section). The core pin
  in `srclibs` does not affect the build — prebuild checks out by
  `libbox.version` on its own, so bumping the core needs a tag and no recipe
  edit.
- `docs/GOOGLE_PLAY.md` — a page on publishing to Play, with thanks to the
  testers.

## 🧪 Tests

`flutter analyze` (0 issues), the full test suite (4197 tests), all four l10n
checkers and the docs parity check.

</details>

<details open>
<summary><h2>🇷🇺 Русский</h2></summary>

## 🛟 Туннель возвращается после гибели процесса ([docs/spec/tasks/428](docs/spec/tasks/428-vpn-service-start-sticky.md), issue #115)

После OOM-kill, lmkd, OEM-чистилки или иногда ночного ребута Always-on не
поднимал туннель, пока юзер не откроет приложение руками.
`BoxService.onStartCommand` возвращал `START_NOT_STICKY` из обоих выходов —
явная просьба к системе **не** пересоздавать сервис.

Лечение — `START_STICKY` из обоих выходов **плюс** сторож, потому что на
`VpnService` одного sticky мало. Воспроизведено на AVD (API 34): после `kill -9`
при поднятом туннеле есть `am_proc_died`, но нет
`am_schedule_service_restart` — ядро закрывает tun-fd мёртвого процесса, netd
сообщает `interfaceRemoved`, и `unbindService` фреймворка по его
`BIND_AUTO_CREATE`-биндингу обгоняет обработку смерти binder-а, так что
ActiveServices вычищает запись сервиса раньше, чем поставил бы его в очередь на
рестарт.

Сторож — alarm «мёртвой руки»: `ELAPSED_REALTIME` каждые две минуты, тикер
сервиса его переставляет, пока туннель поднят. Если receiver сработал и видит
`vpn_desired && status == Stopped` — стартует сервис. Взводится только пока
туннель должен быть поднят, поэтому здоровый телефон не будит; ручной Stop
снимает `vpn_desired`, а вместе с ним и alarm. Предохранитель от шторма
останавливает цикл после двух автоперезапусков за пять минут и шлёт
уведомление.

Проверено на устройстве (AVD): восстановление за 3м00с после `kill -9` и шесть
минут тишины после ручного Stop.

## 🧩 VPN рабочего профиля — не конфликт; Start не падает на Android 10 ([docs/spec/tasks/427](docs/spec/tasks/427-foreign-vpn-active-network-api30.md), issue #115)

Две независимые дыры в `isForeignVpnActive()`:

| Было | Стало |
|---|---|
| Проверка перебирала `ConnectivityManager.allNetworks` и считала чужой любую сеть с `TRANSPORT_VPN`, владелец которой не мы, — включая VPN соседнего профиля. У юзера с туннелем внутри Shelter каждый ручной Start показывал диалог «Another VPN is active» | Только `activeNetwork` — дефолтная сеть **для нашего uid**. Android держит по одному VPN-слоту на профиль, поэтому туннель рабочего профиля туда не попадает и нашим `establish()` не отзывается |
| `caps.ownerUid` стоял под гейтом API 29 с комментарием, что он там есть. Его там нет: публичный `getOwnerUid()` появился только с API 30, и на Android 10 вызов бросает `NoSuchMethodError` — это `Error`, а не `Exception`, и `catch (e: Exception)` его не ловит: исключение улетало из хендлера MethodChannel на main thread и роняло приложение | Гейт — API 30, весь блок ловит `Throwable`. На Android 10 кнопка Start больше не падает ровно в той ситуации, которую чинил §361 |

Проверено на устройстве: VPN L×Box в managed-профиле, Start в личном профиле
без диалога, tun0 и tun1 живут одновременно.

## 🌍 Регион — общая настройка приложения ([docs/spec/tasks/425](docs/spec/tasks/425-warp-pool-region-loc.md))

Новая плитка в App Settings → General, рядом с языком: `Auto` (страна сети, а
если её нет — локаль), `Not set` или явный код страны. Регион — не
WARP-настройка: WARP просто первый её потребитель, дальше правила.

В `assets/warp_endpoints.json` пул теперь принимает региональные секции
`loc.<cc>`, которые накладываются на корень: Map сливается по ключам, всё
остальное (списки, строки, числа) заменяется целиком — иначе «убрать домен для
региона» было бы невозможно. `{"alias": "xx"}` ссылается на другую секцию (один
переход, без цепочек); неизвестный регион, отсутствие `loc` или секция не-Map
оставляют корень нетронутым, так что старый asset и пользовательский JSON без
`loc` парсятся как раньше.

Российские домены (`yandex.ru`, `gosuslugi.ru`, …) уехали в `loc.ru`: они
полезны за российским DPI, где ТСПУ режет по несовпадению SNI, а для юзера в
Израиле или ЕС это шум. `deepseek.com` остался в корне. Секции заводятся только
там, где содержимое реально отличается: `eu`/`us`/`il` повторили бы корень,
`cn`/`ir` ждут подтверждённого набора.

## 📦 About: все источники установки, всегда ([docs/spec/tasks/426](docs/spec/tasks/426-install-sources-always-in-about.md))

Карточка «Where to get L×Box» стоит сразу под блоком обновлений и перечисляет
все три канала — GitHub, Google Play, F-Droid — постоянно, а не только когда
чекер нашёл версию новее. Текущий канал помечен галочкой и подписью «Installed
from here», но остаётся кликабельным: страница своего стора нужна и без
обновления — оставить отзыв, поделиться. Google Play открывается через
`market://` с фолбэком на `https://play.google.com/...`, если клиента Play нет.

Подвал объясняет, почему нельзя просто поставить сборку одного канала поверх
другого: у каждого источника свой ключ подписи, поэтому переезд — бэкап →
удалить → поставить из нового источника → восстановить.

## 🎛 WARP-визард: «(recommended)» больше не утекает в конфиг ([docs/spec/tasks/424](docs/spec/tasks/424-warp-preset-recommended-mark-leak.md))

Выбор рекомендованного пункта в combobox писал в узел
`"server_name": "consumer-masque.cloudflareclient.com (recommended)"`.
`DropdownMenu` во Flutter при выборе кладёт в контроллер `entry.label`, а не
`value`. Теперь label — всегда чистое значение, а пометка живёт в
`labelWidget`: видна в меню и никогда не попадает в поле. Затронуты были все три
combobox-а с пометкой: MASQUE SNI, MASQUE Endpoint IP, WG endpoint.

## 🔇 `RECORD_AUDIO` убран из APK

Разрешение просачивалось в манифест из `camera_android_camerax` (сканер QR).
Микрофон приложение не использует — разрешение снято через
`tools:node="remove"`.

## 🛠 Тулчейн и документация

- Gradle 8.14 → 9.3.1, AGP 8.11.1 → 9.1.0, Kotlin 2.2.20 → 2.3.21
  (`kotlinOptions` → `compilerOptions`).
- `docs/FDROID.md` переписан по актуальному состоянию рецепта (два ABI, пины
  srclib к коммитам, потолок джоба 3 ч, раздел Permissions). Пин ядра в
  `srclibs` на сборку не влияет — prebuild сам делает checkout по
  `libbox.version`, так что бамп ядра требует только тега, без правки рецепта.
- `docs/GOOGLE_PLAY.md` — страница про публикацию в Play и благодарность
  тестировщикам.

## 🧪 Тесты

`flutter analyze` (0 issues), полный набор тестов (4197 штук), все четыре
l10n-чекера и проверка паритета документации.

</details>

---

## Install / Установка

```bash
adb install -r LxBox-v2.23.1-arm64-v8a.apk
```

Без uninstall! Поверх существующей установки. Настройки и подписки сохранятся.

No uninstall needed — install over the existing one. Settings and
subscriptions are preserved.

---

Previous release / Предыдущий релиз: [v2.23.0](docs/releases/v2.23.0.md).
