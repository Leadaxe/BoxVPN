# 430 — Зависшее уведомление от умершего сервиса: снимать при открытии

| Field | Value |
|------|----------|
| Status | Done, DEVICE-VERIFIED (AVD LxBox_test, API 34, 09.09.2026): после `kill -9` id=1 flags=0x62 висит; открытие MainActivity → `bouncing … bounce done`, уведомлений по пакету 0, foreground отдельно не остался, процесс жив, tun=0; живой туннель + открытие → ветка молчит, уведомление на месте; без POST_NOTIFICATIONS утечки нет |
| Started | 2026-09-09 |
| Trigger | 4PDA 09.09.2026 (Redmi 12s): «приложение показывает что работает в фоне (реально работает) и тут же просит запустить» — в шторке уведомление «L×Box [final = vpn-1] • 14 ч.», в приложении Start. Владелец: «у нас поголовно жалуются» |
| Related | [§428](428-vpn-service-start-sticky.md) (сторож, там же найдена гонка), [§361](361-late-started-status-after-service-destroy.md) (осиротевший tun — родственный симптом), [§185](185-cold-start-cc-resync.md) (swipe-kill на OEM) |

## Проблема

Процесс LxBox убит (MIUI, OOM, lmkd). Сервис и туннель мертвы, интернет идёт
напрямую — «реально работает». Приложение при открытии спрашивает статус у
`BoxVpnService.currentStatus` в свежем процессе, получает Stopped и честно
показывает Start. А уведомление foreground-сервиса остаётся висеть в шторке
с кнопками Stop/Reconnect, которые ведут в никуда.

**Почему не снялось.** Гонка в system_server (воспроизведена на AVD API 34,
`ActiveServices.java` android-14): при гибели процесса fd туннеля закрывается
→ netd: `interfaceRemoved` → `Vpn.interfaceRemoved` → `unbindService`
мёртвого сервиса → `DeadObjectException` → `removeConnectionLocked` →
`serviceProcessGoneLocked` → `serviceDoneExecutingLocked(finishing)` стирает
запись сервиса из процесса. В этом пути `cancelForegroundNotificationLocked`
нет. Когда следом приходит binder-death, `killServicesLocked` записи уже не
видит — ни рестарта, ни снятия уведомления. На AVD unbind опередил death на
22 мс; порядок недетерминирован, отсюда «иногда».

Гонку убрать нельзя: оба сигнала (netd про интерфейс, ядро про binder) идут
в system_server независимо, приложение не управляет ни закрытием fd при
смерти, ни их порядком. Разнос UI/VPN по процессам её не убирает.

**Почему не снять напрямую.** NMS отбрасывает `cancel()` приложения на
уведомление с `FLAG_FOREGROUND_SERVICE` (`mustNotHaveFlags`) — снимать его
имеет право только ActiveServices при остановке сервиса.

## Решение

`BoxVpnService.clearStaleNotification(ctx)` из `MainActivity.onCreate`: если
`currentStatus == Stopped`, а в `activeNotifications` есть id=1 — это утечка.
`startForegroundService(ACTION_CLEAR_STALE_NOTIFICATION)`: сервис в
`onStartCommand` при Stopped делает `startForeground` под тем же id (запись
сервиса снова владеет уведомлением), `stopForeground(REMOVE)`,
`stopSelf(startId)` и возвращает NOT_STICKY — AMS снимает уведомление
штатно в `bringDownServiceLocked`. Если сервис уже стартовал по-настоящему,
ветка ничего не трогает; `stopSelf(startId)` не гасит старт, пришедший
следом. Туннель при этом не поднимается — это делает сторож §428 или юзер.

Со сторожем это две линии: сторож возвращает туннель и уведомление в течение
~3 мин (если MIUI даёт автозапуск), bounce снимает ложь из шторки сразу при
открытии.

## Что НЕ делается

| Не делается | Почему |
|---|---|
| Подменить уведомление обычным под тем же id и `cancel()` (без старта сервиса) | Проверено на AVD: NMS переносит FLAG_FOREGROUND_SERVICE на подменное (flags 0x62 → 0x48, бит 0x40 остаётся), `cancel()` по-прежнему отброшен |
| Вызов из `Application.onCreate` (любой процесс) | В headless-процессе (сторож, boot, tile) сервис вот-вот стартует по-настоящему и сам перепишет уведомление; bounce там — лишний старт и гонка со штатным |
| `setTimeoutAfter` на foreground-уведомлении как «мёртвая рука» | NMS-таймаут тоже идёт с `mustNotHaveFlags = FLAG_FOREGROUND_SERVICE` — на FGS-уведомление не действует |
| Периодическая проверка шторки из живого процесса | Утечка возникает только при смерти процесса — проверять её может только следующий процесс; Application.onCreate и есть эта точка |

## Файлы

- `app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/ServiceNotification.kt` — `isStalePresent`.
- `app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/BoxVpnService.kt` — `ACTION_CLEAR_STALE_NOTIFICATION`, `clearStaleNotification`.
- `app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/BoxService.kt` — ветка bounce в `onStartCommand`.
- `app/android/app/src/main/kotlin/com/leadaxe/lxbox/MainActivity.kt` — вызов в `onCreate`.
- `CHANGELOG.md` — Fixed.

## Проверка (AVD LxBox_test, API 34)

1. VPN up → `kill -9 <pid>` → `dumpsys notification`: id=1 с flags=0x62 висит
   (утечка воспроизведена).
2. `am start MainActivity` в течение минуты → в логе `[vpn §430] … bouncing`,
   `bounce done — foreground shown and removed`, `dumpsys notification` по
   пакету пуст, отдельного foreground-уведомления нет, UI показывает
   Disconnected.
3. `pm revoke … POST_NOTIFICATIONS` → после `kill -9` уведомлений 0: без
   разрешения система foreground-уведомление не показывает, утечки нет.
4. Живой туннель + открытие приложения → ветка не срабатывает (статус не
   Stopped), уведомление не мигает.
