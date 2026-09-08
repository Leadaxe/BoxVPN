# 427 — Чужой VPN: смотреть `activeNetwork`, а не все сети; `ownerUid` только с API 30

| Field | Value |
|------|----------|
| Status | Done (код), DEVICE-PENDING: прогон на AVD LxBox_test не сделан |
| Started | 2026-09-08 |
| Trigger | [Issue #115](https://github.com/Leadaxe/LxBox/issues/115) (Alex01d, 08.09.2026): VPN из рабочего профиля Shelter ловится как конфликтующий; там же замечание про `getOwnerUid()` на Android 10 |
| Related | [§211](211-foreign-vpn-switch-dialog.md) (сам диалог «активен другой VPN»), [§224](224-foreign-vpn-revoke-ux.md) (UX отзыва), [§361](361-late-started-status-after-service-destroy.md) (осиротевший tun, ради него добавили проверку `ownerUid`), [§428](428-vpn-service-start-sticky.md) (второй баг из того же issue) |

## Проблема

Две независимые дыры в `VpnPlugin.isForeignVpnActive()`
([VpnPlugin.kt:1275](../../../app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/VpnPlugin.kt)).

**1. Проверка не различает профили.** Метод перебирает
`ConnectivityManager.allNetworks` и считает чужой любую сеть с `TRANSPORT_VPN`,
владелец которой не мы. Но `allNetworks` отдаёт все сети, которые отслеживает
фреймворк, включая VPN соседнего профиля (Shelter / work profile). Android
держит по одному VPN-слоту **на профиль**, а не на устройство: туннель из
рабочего профиля нам не мешает и при нашем `establish()` не отзывается. Итог:
у юзера с VPN внутри Shelter каждый ручной Start показывает диалог §211
«Another VPN is active», хотя переключаться не с чего.

**2. `getOwnerUid()` не существует на Android 10.** Гейт в коде стоит на
`Build.VERSION_CODES.Q` (29), комментарий утверждает «`ownerUid` доступен с
API 29». Проверено по AOSP: в `android-10.0.0_r1` у `NetworkCapabilities` есть
только скрытый `getEstablishingVpnAppUid()`, публичный `getOwnerUid()` появился
в `android-11.0.0_r1` (API 30). На Android 10 обращение `caps.ownerUid` бросает
`NoSuchMethodError`. Это `Error`, а не `Exception`, и `catch (e: Exception)`
его не ловит: исключение улетает из хендлера MethodChannel на main thread и
роняет приложение. Срабатывает при любой VPN-сети в `allNetworks`, в том числе
на нашем собственном осиротевшем tun из §361. То есть на Android 10 кнопка
Start падает ровно в той ситуации, которую §361 чинил.

## Решение

```kotlin
private fun isForeignVpnActive(): Boolean {
    if (BoxVpnService.currentStatus != VpnStatus.Stopped) return false
    val cm = BoxApplication.connectivity
    return try {
        // activeNetwork = дефолтная сеть ДЛЯ НАШЕГО uid. VPN другого профиля
        // в неё не попадает никогда; VPN нашего профиля — попадает, если он
        // нас не исключил из своего туннеля.
        val n = cm.activeNetwork ?: return false
        val caps = cm.getNetworkCapabilities(n) ?: return false
        if (!caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) return false
        // §361: свой осиротевший tun — не чужой. getOwnerUid() публичен с API 30;
        // ниже деталь недоступна, считаем чужим (консервативно, лишний вопрос
        // безопаснее молчаливого отзыва).
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R &&
            caps.ownerUid == android.os.Process.myUid()
        ) return false
        true
    } catch (t: Throwable) {   // NoSuchMethodError — Error, не Exception
        Log.w(TAG, "isForeignVpnActive: $t")
        false
    }
}
```

Почему `activeNetwork`, а не фильтр поверх `allNetworks`: публичного API
«относится ли эта сеть к моему uid / профилю» нет. `ownerUid` для чужих сетей
редактируется в `INVALID_UID` по соображениям приватности (javadoc API 30:
поле заполнено только для владельца), профиль по нему не узнать. Единственный
источник, который уже учитывает наш uid и профиль, — дефолтная сеть
приложения.

Комментарий над методом («доступен с API 29») исправить на API 30.

## Компромисс

VPN **нашего** профиля, который через per-app список исключил LxBox из своего
туннеля, в `activeNetwork` не виден. Такой туннель мы перебьём молча, как было
до §211 (наш `establish()` всё равно его отозвал бы, слот один на профиль).
Случай редкий, принимается. На API 24-29 наш собственный осиротевший tun (§361)
снова будет считаться чужим и вызовет лишний диалог; это то же поведение, что
сейчас на 24-28, только теперь без краша на 29.

## Что НЕ делается

| Не делается | Почему |
|---|---|
| Убрать диалог §211 целиком и положиться на `prepare()` | `prepare()` не различает «слот свободен» и «слот занят другим приложением нашего профиля» (см. §211) — диалог остаётся единственным предупреждением перед отзывом чужого туннеля |
| `registerDefaultNetworkCallback` вместо разового `activeNetwork` | Проверка нужна один раз перед Start; callback — лишняя сущность |

## Файлы

- `app/android/app/src/main/kotlin/com/leadaxe/lxbox/vpn/VpnPlugin.kt` — `isForeignVpnActive`.
- `CHANGELOG.md` — Fixed.

## Проверка

- Kotlin-юнита на `ConnectivityManager` нет; проверка кодом (`R`-гейт, `Throwable`).
- Device (AVD LxBox_test, API 34): поднять сторонний VPN в рабочем профиле
  (Shelter или `pm create-user --profileOf`), в личном профиле нажать Start —
  диалога нет, оба туннеля живы. Затем сторонний VPN в личном профиле — диалог
  есть.
- Образа API 29 на стенде нет; краш на Android 10 закрывается только по коду.
