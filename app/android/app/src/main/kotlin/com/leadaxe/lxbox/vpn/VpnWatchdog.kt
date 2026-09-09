package com.leadaxe.lxbox.vpn

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.SystemClock
import android.util.Log
import com.leadaxe.lxbox.R
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

/// §428 — сторож «мёртвой руки» для туннеля.
///
/// `START_STICKY` на VpnService НЕ гарантирует рестарт после гибели процесса:
/// при смерти процесса ядро закрывает tun-fd → netd шлёт interfaceRemoved →
/// `Vpn.interfaceRemoved` делает `unbindService` нашего сервиса → binder уже
/// мёртв → `DeadObjectException` → `ActiveServices.removeConnectionLocked`
/// зовёт `serviceProcessGoneLocked` → `serviceDoneExecutingLocked(finishing)`
/// вычищает запись из процесса (`psr.stopService`, `app=null`). Когда следом
/// приходит binder-death, `killServicesLocked` в процессе нашей записи уже не
/// видит и рестарт не планирует (нет `am_schedule_service_restart`). Запись
/// остаётся в лимбо: `startRequested=true, app=null`, никто её не поднимает.
/// Гонка воспроизведена на AVD API 34 (unbind опередил death на 14 мс). Если
/// death приходит первым — sticky работает; порядок недетерминирован.
///
/// Поэтому страховка вне процесса: пока туннель «желателен» (Started и не
/// было явного Stop), сервис каждые [PERIOD_MS] переставляет одноразовый
/// alarm на now+[INTERVAL_MS]. Живой сервис до alarm-а не доводит — в здоровом
/// состоянии ни одного пробуждения. Мёртвый процесс перестаёт переставлять →
/// alarm срабатывает → [VpnWatchdogReceiver] в свежем процессе видит
/// `desired && Stopped` и стартует сервис.
///
/// Тип alarm-а — `ELAPSED_REALTIME` (не WAKEUP) через обычный `set`:
/// спящий телефон не будим ради проверки — туннель спящему не нужен, а при
/// первом же пробуждении (экран, push) alarm срабатывает сразу. Inexact-окно
/// у `set` = 75 % задержки, поэтому при INTERVAL 2 мин худший случай ≈ 3,5
/// мин (замер на AVD: при 3 мин было 4м52с). `setWindow` с малым окном на
/// API 31+ клампится к 10 мин, exact требует SCHEDULE_EXACT_ALARM —
/// не подходят.
///
/// Явные Stop-пути все проходят через `setStatus(Stopped)` → `desired=false`
/// + `disarm`, поэтому ручную остановку, onRevoke и stopAndAlert сторож не
/// перебивает. Шторм-предохранитель общий с sticky-путём
/// (`BootReceiver.noteStickyRestart`).
object VpnWatchdog {
    private const val TAG = "VpnWatchdog"
    const val INTERVAL_MS = 2 * 60 * 1000L
    const val PERIOD_MS = INTERVAL_MS / 2
    private const val REQUEST_CODE = 428

    private fun pendingIntent(ctx: Context): PendingIntent =
        PendingIntent.getBroadcast(
            ctx, REQUEST_CODE,
            Intent(ctx, VpnWatchdogReceiver::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

    /// Переставить alarm на now+INTERVAL (идемпотентно: тот же PendingIntent
    /// заменяет предыдущий).
    fun arm(ctx: Context) {
        val am = ctx.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        runCatching {
            am.set(
                AlarmManager.ELAPSED_REALTIME,
                SystemClock.elapsedRealtime() + INTERVAL_MS,
                pendingIntent(ctx),
            )
        }.onFailure { Log.w(TAG, "arm failed: $it") }
    }

    fun disarm(ctx: Context) {
        val am = ctx.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        runCatching { am.cancel(pendingIntent(ctx)) }
            .onFailure { Log.w(TAG, "disarm failed: $it") }
    }

    /// Тикер живого сервиса: переставляет alarm каждые PERIOD_MS, пока scope
    /// жив и [isStarted] истинно. Возвращает Job, чтобы вызывающий мог
    /// отменить при смене scope.
    fun startTicker(ctx: Context, scope: CoroutineScope, isStarted: () -> Boolean): Job {
        arm(ctx)
        return scope.launch {
            while (isActive) {
                delay(PERIOD_MS)
                if (isStarted()) arm(ctx)
            }
        }
    }
}

class VpnWatchdogReceiver : BroadcastReceiver() {
    companion object {
        private const val TAG = "VpnWatchdog"
    }

    override fun onReceive(context: Context, intent: Intent?) {
        val ctx = context.applicationContext
        if (!BootReceiver.isVpnDesired(ctx)) {
            Log.d(TAG, "[vpn §428] alarm fired, VPN not desired — ignore")
            return
        }
        val status = BoxVpnService.currentStatus
        if (status != VpnStatus.Stopped) {
            // Процесс жив (тикер не успел из-за Doze) — просто переставить.
            Log.d(TAG, "[vpn §428] alarm fired, service alive (status=${status.name}) — re-arm")
            VpnWatchdog.arm(ctx)
            return
        }
        val n = BootReceiver.noteStickyRestart(ctx)
        Log.w(TAG, "[vpn §428] alarm fired, VPN desired but service dead — restart #$n")
        if (n >= BootReceiver.STICKY_RESTART_LIMIT) {
            BootReceiver.setVpnDesired(ctx, false)
            ServiceNotification.showAlert(
                ctx,
                L10n.str(ctx, R.string.sticky_restart_storm_title),
                L10n.str(ctx, R.string.sticky_restart_storm_text),
            )
            return
        }
        BoxVpnService.start(ctx)
    }
}
