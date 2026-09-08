package com.leadaxe.lxbox.vpn

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import androidx.core.app.NotificationCompat
import com.leadaxe.lxbox.R

class ServiceNotification(private val service: Service) {
    companion object {
        // Wire: id канала стабилен между релизами и локалями — НЕ в ресурсы.
        private const val CHANNEL_ID = "boxvpn_vpn_channel"
        private const val NOTIFICATION_ID = 1
        /// §428 — отдельное (не foreground) уведомление: сервис уже остановлен,
        /// а сказать юзеру надо — UI-процесса при sticky-рестарте нет.
        private const val ALERT_NOTIFICATION_ID = 2

        /// §279 — идемпотентный (пере)сабмит канала. createNotificationChannel
        /// с тем же id обновляет имя/описание (документированный rename-путь) —
        /// зовётся из init и из L10n.refreshSurfaces при смене языка.
        fun createChannel(ctx: Context) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val channel = NotificationChannel(
                    CHANNEL_ID,
                    L10n.str(ctx, R.string.notification_channel_name),
                    NotificationManager.IMPORTANCE_LOW
                ).apply {
                    description =
                        L10n.str(ctx, R.string.notification_channel_description)
                    setShowBadge(false)
                }
                BoxApplication.notificationManager.createNotificationChannel(channel)
            }
        }
    }

    init {
        createChannel(service)
    }

    /// §182/§279 — builder реконструируется ЦЕЛИКОМ на каждый show():
    /// `addAction` НЕ идемпотентен (на переиспользуемом builder'е кнопки
    /// Stop/Reconnect стекались бы на каждый апдейт), а лейблы обязаны
    /// перечитываться из ресурсов на активной локали в момент рендера
    /// (§279: relabel при смене языка = обычный show()-путь через
    /// ACTION_UPDATE_NOTIFICATION). show() зовётся редко (connect / смена
    /// лейбла) — цена реконструкции незначима.
    private fun buildNotification(title: String, text: String)
        : android.app.Notification {
        val openIntent = service.packageManager
            .getLaunchIntentForPackage(service.packageName)
        val pendingIntent = if (openIntent != null) {
            PendingIntent.getActivity(
                service, 0, openIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
        } else null

        val builder = NotificationCompat.Builder(service, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_lock_lock)
            .setContentTitle(title)
            .setContentText(text)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setOngoing(true)

        if (pendingIntent != null) builder.setContentIntent(pendingIntent)

        // §182 — кнопки Stop / Reconnect прямо в шторке (фидбэк #180/#261).
        // icon=0: на Android 7+ action-иконки в развёрнутом уведомлении
        // compat-стиль скрывает, текст-лейбла достаточно.
        builder
            .addAction(
                0,
                L10n.str(service, R.string.notification_action_stop),
                broadcastPI(BoxVpnService.ACTION_STOP, 1),
            )
            .addAction(
                0,
                L10n.str(service, R.string.notification_action_reconnect),
                broadcastPI(BoxVpnService.ACTION_RECONNECT, 2),
            )
        return builder.build()
    }

    /// §182 — PendingIntent на explicit-broadcast (только своему пакету →
    /// receiver RECEIVER_NOT_EXPORTED извне не дёрнуть). FLAG_IMMUTABLE —
    /// требование API 31+.
    private fun broadcastPI(action: String, requestCode: Int): PendingIntent {
        val intent = Intent(action).setPackage(service.packageName)
        return PendingIntent.getBroadcast(
            service, requestCode, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    fun show(title: String, text: String) {
        val notification = buildNotification(title, text)
        // На Android 14+ (API 34) Google требует typed startForeground —
        // иначе MissingForegroundServiceTypeException на строгих OEM
        // (One UI 6, MIUI 14). На младших API typed-перегрузка отсутствует
        // в SDK или ничего не даёт — используем legacy 2-arg API.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            service.startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
            )
        } else {
            service.startForeground(NOTIFICATION_ID, notification)
        }
    }

    /// §428 — обычное уведомление на том же канале, живёт после stopSelf().
    /// Без POST_NOTIFICATIONS (API 33+) система молча его не покажет — это
    /// допустимо: сервис в любом случае остановлен, шторм прерван.
    fun showAlert(title: String, text: String) {
        val openIntent = service.packageManager
            .getLaunchIntentForPackage(service.packageName)
        val builder = NotificationCompat.Builder(service, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_lock_lock)
            .setContentTitle(title)
            .setContentText(text)
            .setStyle(NotificationCompat.BigTextStyle().bigText(text))
            .setAutoCancel(true)
        if (openIntent != null) {
            builder.setContentIntent(
                PendingIntent.getActivity(
                    service, 0, openIntent,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                )
            )
        }
        runCatching {
            BoxApplication.notificationManager.notify(ALERT_NOTIFICATION_ID, builder.build())
        }
    }

    fun stop() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            service.stopForeground(Service.STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            service.stopForeground(true)
        }
    }
}
