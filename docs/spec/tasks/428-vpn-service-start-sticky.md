# 428 — Туннель возвращается после смерти процесса: `START_STICKY` + сторож

| Field | Value |
|------|----------|
| Status | Done, DEVICE-VERIFIED (AVD LxBox_test, API 34, 09.09.2026): `kill -9` при Started → sticky-рестарта нет (гонка ниже), сторож поднял туннель за 3м00с (интервал 2 мин); ручной Stop → `vpn_desired=false`, alarm снят, 6 мин без воскрешения. Шторм-предохранитель — по коду |
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

В обоих случаях штатный механизм воскрешения started-сервиса —
`START_STICKY`: ActivityManager сам пересоздаёт сервис и зовёт
`onStartCommand(null, …)`. Мы от него отказались.

### Находка device-прогона: `START_STICKY` на VpnService ненадёжен

Воспроизведено на AVD LxBox_test (API 34): `kill -9` процесса при поднятом
туннеле → `am_proc_died` есть, `am_schedule_service_restart` нет, запись
сервиса остаётся в `dumpsys activity services` с `app=null`,
`startRequested=true`, `stopIfKilled=false`, `startCommandResult=1` и никогда
не поднимается. Причина в порядке событий внутри system_server
([ActiveServices.java, android-14.0.0_r1](https://android.googlesource.com/platform/frameworks/base/+/refs/tags/android-14.0.0_r1/services/core/java/com/android/server/am/ActiveServices.java)):

1. Ядро закрывает tun-fd мёртвого процесса → netd `interfaceRemoved` →
   `Vpn.interfaceRemoved` → `unbindService` нашего сервиса (система держит
   BIND_AUTO_CREATE-binding на любой VpnService).
2. Binder уже мёртв → `scheduleUnbindService` бросает `DeadObjectException`
   → `removeConnectionLocked` ловит («Exception when unbinding service») и
   зовёт `serviceProcessGoneLocked` → `serviceDoneExecutingLocked(finishing)`
   → `psr.stopService(r)`, `r.setProcess(null)`.
3. Следом приходит binder-death → `killServicesLocked` перебирает сервисы
   процесса, нашей записи там уже нет → `scheduleServiceRestartLocked` не
   вызывается. `bringDownServiceIfNeededLocked` запись не сносит, потому что
   `startRequested=true` = «сервис нужен». Лимбо.

На эмуляторе unbind опередил death на 14 мс. Если death приходит первым,
sticky-рестарт работает штатно. Порядок недетерминирован и от нас не
зависит, поэтому `START_STICKY` остаётся (бесплатный быстрый путь), а
гарантию даёт сторож.

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

4. **Сторож `VpnWatchdog`** (`vpn/VpnWatchdog.kt`), схема «мёртвой руки»:
   - `setStatus(Started)` → prefs `vpn_desired=true`, alarm
     `AlarmManager.set(ELAPSED_REALTIME, now+2 мин)` на
     `VpnWatchdogReceiver`, тикер на `serviceScope` переставляет alarm каждую
     минуту. Живой сервис до срабатывания не доводит: в здоровом состоянии
     alarm не стреляет.
   - Процесс умер → alarm срабатывает: inexact-окно у `set` = 75 % задержки,
     худший случай ≈ 3,5 мин (замер на AVD с интервалом 3 мин: 4м52с) →
     receiver в свежем процессе: `vpn_desired && currentStatus==Stopped` →
     общий счётчик шторма (`noteStickyRestart`) → `BoxVpnService.start`.
     Если процесс жив (тикер проспал) — просто переставить.
   - `setStatus(Stopped)` из любого явного пути → `vpn_desired=false`, alarm
     снят. Тип не-WAKEUP: спящий телефон не будим, при первом пробуждении
     (экран, push) alarm стреляет сразу — «утром после ночи» туннель
     возвращается в момент разблокировки. В Doze обычный `set` откладывается
     до maintenance-окна — то же поведение.
   - Старт FGS из alarm-receiver'а на API 31+ разрешён по exemption
     `OP_ACTIVATE_VPN` (приложение, которому юзер выдал VPN-consent).

Явные Stop-пути (`doStop`, `doForceStop`, `onRevoke`, `stopAndAlert`,
`exit` при `keep_vpn_on_exit=false`) все проходят через `setStatus(Stopped)`
и заканчиваются `stopSelf()`: started-состояние снято, сторож снят, ни AMS,
ни alarm ничего не воскрешают. Ручная остановка не пострадает.

Что меняется для юзера:

| Было | Стало |
|---|---|
| OOM/чистилка убила процесс при поднятом VPN → туннеля нет до ручного Start | Если AMS успел запланировать sticky-рестарт — через ~1 с; иначе сторож поднимает в пределах ~3 мин (в Doze — при пробуждении) |
| Always-on + смерть процесса → «Always-on VPN disconnected» до ручного запуска | То же восстановление; Always-on-уведомление системы гаснет |
| OEM swipe-kill (§185) при `keep_vpn_on_exit=true` → туннель мёртв, шторка врёт | Туннель возвращается; на стоковом Android swipe FGS не убивает, так что поведение приближается к норме |
| Краш на старте → тишина | Не более двух автоперезапусков за 5 мин, потом стоп с уведомлением |

## Что НЕ делается

| Не делается | Почему |
|---|---|
| Вынос VPN в `:vpn`-процесс, как у Husi/NekoBox | Манифестной правкой не обходится: `BoxVpnService.currentStatus`, `currentRevoked`, `stopReceiverAlive`, состояние MethodChannel/EventChannel-моста — всё process-local. Нужен IPC-контракт статуса и команд. Отдельная фича после §291, когда `START_STICKY` закроет 90 % жалоб |
| Только `START_STICKY`, без сторожа | Первая версия спеки так и планировала («AMS делает бесплатно»); device-прогон показал гонку выше — sticky срабатывает не всегда |
| WAKEUP-alarm / `setAndAllowWhileIdle` / exact | Будили бы спящий телефон каждые 2 мин ради проверки, которая спящему не нужна; exact ещё и требует SCHEDULE_EXACT_ALARM |
| `setWindow` с коротким окном | На API 31+ окно короче 10 мин клампится к 10 мин — хуже, чем 75 % у `set` |
| JobScheduler вместо alarm | Периодика ≥15 мин, квоты по standby-bucket — восстановление растянулось бы на десятки минут |
| `START_REDELIVER_INTENT` | Интент нам не нужен, а redeliver держит очередь intent-ов на каждую доставку |

## Файлы

- `app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/BoxService.kt` — оба `return`, предохранитель, `setStatus` → desired/сторож.
- `app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/VpnWatchdog.kt` — сторож + receiver (новый).
- `app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/BootReceiver.kt` — prefs счётчика и `vpn_desired`.
- `app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/ServiceNotification.kt` — `showAlert(ctx, …)` в companion.
- `app/android/app/src/main/AndroidManifest.xml` — `VpnWatchdogReceiver`.
- `app/android/app/src/main/res/values/strings.xml` (+ ru) — строка уведомления.
- `CHANGELOG.md` — Fixed.

## Проверка

Device (AVD LxBox_test, API 34):

1. Start (`adb root` + `am start-foreground-service -n
   com.leadaxe.lxbox/.vpn.BoxVpnService -a com.leadaxe.lxbox.ACTION_START`),
   дождаться Started, `kill -9 <pid>` (не `force-stop`: force-stop переводит
   пакет в stopped state и глушит любые рестарты по дизайну платформы; `am
   kill` FGS-процесс не трогает). Ожидание: либо sticky-рестарт через ~1 с,
   либо сторож в пределах ~3,5 мин: `VpnWatchdog: … service dead — restart #1`
   в logcat, сервис пересоздан, tun0 вернулся, UI при открытии показывает
   Connected.
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
