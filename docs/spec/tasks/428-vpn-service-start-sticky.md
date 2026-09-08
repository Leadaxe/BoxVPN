# 428 — `START_STICKY`: туннель возвращается после смерти процесса

| Field | Value |
|------|----------|
| Status | Spec (не начато) |
| Started | 2026-09-08 |
| Trigger | [Issue #115](https://github.com/Leadaxe/LxBox/issues/115) (Alex01d, 08.09.2026): после OOM-kill / чистилки / иногда после ночного ребута Always-on не восстанавливает туннель, пока юзер не откроет приложение; Husi и NekoBox в той же ситуации переживают |
| Related | [§427](427-foreign-vpn-active-network-api30.md) (первый баг из того же issue), [§185](185-cold-start-cc-resync.md) (swipe-kill на OEM), [§361](361-late-started-status-after-service-destroy.md) (рассинхрон статуса при смерти сервиса), [§012](../features/012%20native%20vpn%20service/spec.md) (архитектура сервиса), [§291](../features/291%20layered-architecture-facades/spec.md) (почему `:vpn`-процесс — не сейчас) |

## Проблема

`BoxService.onStartCommand`
([BoxService.kt:264](../../../app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/BoxService.kt))
возвращает `Service.START_NOT_STICKY` из обоих выходов: из guard-а
`status != Stopped` и после успешного старта. Это явная просьба к системе
**не** пересоздавать сервис, если процесс убит.

UI и VPN живут в одном процессе (`BoxVpnService` без `android:process`).
Когда Android (OOM, lmkd) или OEM-чистилка убивает процесс, умирает и сервис,
и tun. Дальше:

- Always-on: система стартует наш сервис через `startServiceAsUser` с action
  `android.net.VpnService` (фильтр в манифесте есть), но делает это только на
  boot, unlock профиля и package-события. На смерть VPN-приложения фреймворк
  не реагирует перезапуском, он лишь показывает «Always-on VPN disconnected».
- Без Always-on: то же самое, просто без уведомления.

В обоих случаях единственный штатный механизм воскрешения started-сервиса —
`START_STICKY`: ActivityManager сам пересоздаёт сервис и зовёт
`onStartCommand(null, …)`. Мы от него отказались.

Отдельно: третий пункт issue («Always-on не должен зависеть от Flutter UI») уже
так и есть — `BoxService.onCreate` вызывает `BoxApplication.initialize`
идемпотентно, свежий процесс без Activity поднимает libbox сам. Диалог §211
в headless-путях не участвует.

## Решение

1. `onStartCommand` возвращает `START_STICKY` из **обоих** выходов (у системы
   запоминается результат последнего вызова, guard-выход тоже должен быть
   sticky).
2. Интент при sticky-рестарте `null`; код его не читает (только логирует
   `intent?.action`), менять нечего.
3. **Предохранитель от шторма.** Если сам старт валит процесс (Go-паника на
   конфиге, SIGABRT в ядре — прецедент v2.12.0 `force_ipv4×FakeIP`),
   `START_STICKY` превращает один краш в цикл «рестарт → краш → рестарт» с
   бэкоффом AMS. Гейт в prefs (`BootReceiver`, `PREF_NAME`):
   - при `intent == null` (это и есть sticky-рестарт) инкрементировать счётчик
     `sticky_restart_count` с меткой времени первого рестарта в окне;
   - окно 5 минут, порог 3: на третьем рестарте в окне не стартовать —
     `stopSelf()` и уведомление «VPN restarted too many times, start it
     manually» (строка EN, ключ для ru);
   - успешный `Started` (ядро поднялось, tun установлен) сбрасывает счётчик;
   - ручной Start из UI/tile/automation (intent с action) счётчик не трогает.

Явные Stop-пути (`doStop`, `doForceStop`, `onRevoke`, `stopAndAlert`,
`exit` при `keep_vpn_on_exit=false`) все заканчиваются `stopSelf()`, после
него started-состояние снято и AMS ничего не воскрешает. Ручная остановка не
пострадает.

Что меняется для юзера:

| Было | Стало |
|---|---|
| OOM/чистилка убила процесс при поднятом VPN → туннеля нет до ручного Start | Через ~1 с система пересоздаёт сервис, туннель поднимается сам |
| Always-on + смерть процесса → «Always-on VPN disconnected» до ручного запуска | То же восстановление; Always-on-уведомление системы гаснет |
| OEM swipe-kill (§185) при `keep_vpn_on_exit=true` → туннель мёртв, шторка врёт | Туннель возвращается; на стоковом Android swipe FGS не убивает, так что поведение приближается к норме |
| Краш на старте → тишина | Не более двух автоперезапусков за 5 мин, потом стоп с уведомлением |

## Что НЕ делается

| Не делается | Почему |
|---|---|
| Вынос VPN в `:vpn`-процесс, как у Husi/NekoBox | Манифестной правкой не обходится: `BoxVpnService.currentStatus`, `currentRevoked`, `stopReceiverAlive`, состояние MethodChannel/EventChannel-моста — всё process-local. Нужен IPC-контракт статуса и команд. Отдельная фича после §291, когда `START_STICKY` закроет 90 % жалоб |
| Свой watchdog/alarm на проверку живости сервиса | Дублирует то, что AMS делает бесплатно через `START_STICKY` |
| `START_REDELIVER_INTENT` | Интент нам не нужен, а redeliver держит очередь intent-ов на каждую доставку |

## Файлы

- `app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/BoxService.kt` — оба `return`, предохранитель.
- `app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/BootReceiver.kt` — prefs счётчика.
- `app/android/app/src/main/res/values/strings.xml` (+ ru) — строка уведомления.
- `CHANGELOG.md` — Fixed.

## Проверка

Device (AVD LxBox_test, API 34):

1. Start из UI, дождаться Connected, `adb shell am kill com.leadaxe.lxbox`
   (не `force-stop`: force-stop переводит пакет в stopped state и глушит любые
   рестарты по дизайну платформы). Ожидание: через 1-2 с сервис пересоздан,
   шторка «Connected», трафик идёт, UI при открытии показывает Connected.
2. То же с Always-on в системных настройках: системное «disconnected» не
   зависает.
3. Ручной Stop → `dumpsys activity services com.leadaxe.lxbox` пуст, через
   минуту ничего не воскресло.
4. `keep_vpn_on_exit=false`, свайп приложения → туннель остановлен и не
   вернулся.
5. Шторм: подсунуть конфиг, роняющий ядро на старте, → после третьего рестарта
   уведомление и тишина; после ручного Start счётчик сброшен.
6. Ребут AVD с включённым Always-on → после unlock подключается без открытия
   UI (регресс-проверка, поведение не должно измениться).
