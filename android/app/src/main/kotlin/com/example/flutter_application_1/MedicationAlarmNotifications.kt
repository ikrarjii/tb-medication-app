package com.example.flutter_application_1

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.RingtoneManager
import android.os.Build
import androidx.core.app.NotificationCompat
import android.util.Log

object MedicationAlarmNotifications {
    const val ALARM_CHANNEL_ID = "medication_alarm_v3"
    private const val FALLBACK_CHANNEL_ID = "medication_alarm_fallback_v3"
    private const val UPDATE_CHANNEL_ID = "medication_schedule"
    private val vibrationPattern = longArrayOf(0L, 900L, 450L, 900L)

    fun createChannels(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val alarmAttributes = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_ALARM)
            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
            .build()
        val alarmChannel = NotificationChannel(
            ALARM_CHANNEL_ID,
            "Alarm obat",
            NotificationManager.IMPORTANCE_HIGH,
        ).apply {
            description = "Alarm layar penuh untuk jadwal minum obat"
            lockscreenVisibility = Notification.VISIBILITY_PUBLIC
            setSound(null, alarmAttributes)
            enableVibration(true)
            vibrationPattern = MedicationAlarmNotifications.vibrationPattern
        }
        val fallbackChannel = NotificationChannel(
            FALLBACK_CHANNEL_ID,
            "Alarm obat (cadangan)",
            NotificationManager.IMPORTANCE_HIGH,
        ).apply {
            description = "Suara cadangan jika layanan alarm tidak dapat berjalan"
            lockscreenVisibility = Notification.VISIBILITY_PUBLIC
            setSound(defaultAlarmSound(), alarmAttributes)
            enableVibration(true)
            vibrationPattern = MedicationAlarmNotifications.vibrationPattern
        }
        val updateChannel = NotificationChannel(
            UPDATE_CHANNEL_ID,
            "Medication schedule",
            NotificationManager.IMPORTANCE_HIGH,
        ).apply {
            description = "Reminders for approved medication schedules"
        }
        manager.createNotificationChannels(listOf(alarmChannel, fallbackChannel, updateChannel))
    }

    fun notificationsAllowed(context: Context): Boolean {
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (!manager.areNotificationsEnabled()) return false
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = manager.getNotificationChannel(ALARM_CHANNEL_ID)
            if (channel != null && channel.importance == NotificationManager.IMPORTANCE_NONE) return false
        }
        return true
    }

    fun postAlarm(context: Context, payload: MedicationAlarmPayload, triggeredAt: Long) {
        createChannels(context)
        MedicationAlarmStore.saveActiveAlarm(context, payload, triggeredAt)
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val notificationPosted = runCatching {
            manager.notify(
                MedicationAlarmScheduler.notificationId(payload.id),
                buildAlarmNotification(context, payload, triggeredAt, useFallbackChannel = false),
            )
        }.onSuccess {
            Log.i(TAG, "Alarm notification displayed id=${payload.id}")
        }.onFailure {
            Log.w(TAG, "Alarm notification could not be posted id=${payload.id}", it)
        }.isSuccess
        if (!MedicationAlarmPlaybackService.start(context, payload, triggeredAt) && notificationPosted) {
            postFallbackAlarm(context, payload, triggeredAt)
        }
    }

    fun postFallbackAlarm(context: Context, payload: MedicationAlarmPayload, triggeredAt: Long) {
        createChannels(context)
        if (!notificationsAllowed(context)) return
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val notification = buildAlarmNotification(
            context,
            payload,
            triggeredAt,
            useFallbackChannel = true,
        ).apply {
            flags = flags or Notification.FLAG_INSISTENT or Notification.FLAG_NO_CLEAR
        }
        manager.notify(MedicationAlarmScheduler.notificationId(payload.id), notification)
    }

    fun buildAlarmNotification(
        context: Context,
        payload: MedicationAlarmPayload,
        triggeredAt: Long,
        useFallbackChannel: Boolean,
    ): Notification {
        val openIntent = activityIntent(context, payload, MedicationAlarmContract.ACTION_OPEN, triggeredAt)
        val takenIntent = actionIntent(context, payload, MedicationAlarmContract.ACTION_TAKEN, triggeredAt)
        val snoozeIntent = actionIntent(context, payload, MedicationAlarmContract.ACTION_SNOOZE, triggeredAt)
        val dismissIntent = actionIntent(context, payload, MedicationAlarmContract.ACTION_DISMISS, triggeredAt)
        val channelId = if (useFallbackChannel) FALLBACK_CHANNEL_ID else ALARM_CHANNEL_ID

        val builder = NotificationCompat.Builder(context, channelId)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(payload.title)
            .setContentText(payload.body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(payload.body))
            .setCategory(NotificationCompat.CATEGORY_ALARM)
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setWhen(payload.scheduledAt)
            .setShowWhen(true)
            .setOngoing(true)
            .setAutoCancel(false)
            .setOnlyAlertOnce(false)
            .setContentIntent(openIntent)
            .setFullScreenIntent(openIntent, true)
            .addAction(android.R.drawable.checkbox_on_background, "I Have Taken the Medicine", takenIntent)
            .addAction(android.R.drawable.ic_lock_idle_alarm, "Snooze 5m", snoozeIntent)
            .addAction(android.R.drawable.ic_menu_close_clear_cancel, "Stop Alarm", dismissIntent)

        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O && useFallbackChannel) {
            builder
                .setSound(defaultAlarmSound())
                .setVibrate(vibrationPattern)
        }
        return builder.build().apply {
            flags = flags or Notification.FLAG_NO_CLEAR or Notification.FLAG_ONGOING_EVENT
        }
    }

    fun postStandardNotification(context: Context, payload: MedicationAlarmPayload) {
        createChannels(context)
        val openApp = context.packageManager.getLaunchIntentForPackage(context.packageName)
            ?: Intent(context, MainActivity::class.java)
        val contentIntent = PendingIntent.getActivity(
            context,
            MedicationAlarmScheduler.notificationId(payload.id),
            openApp,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val notification = NotificationCompat.Builder(context, UPDATE_CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(payload.title)
            .setContentText(payload.body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(payload.body))
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setAutoCancel(true)
            .setContentIntent(contentIntent)
            .build()
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.notify(MedicationAlarmScheduler.notificationId(payload.id), notification)
    }

    private fun activityIntent(
        context: Context,
        payload: MedicationAlarmPayload,
        action: String,
        triggeredAt: Long,
    ): PendingIntent {
        val intent = payload.putInto(Intent(context, MainActivity::class.java)).apply {
            this.action = action
            data = MedicationAlarmScheduler.alarmUri(payload.id, action.substringAfterLast('.'))
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
            putExtra(MedicationAlarmContract.EXTRA_TRIGGERED_AT, triggeredAt)
            putExtra(MedicationAlarmContract.EXTRA_IS_ALARM, true)
        }
        return PendingIntent.getActivity(
            context,
            payload.id,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private fun actionIntent(
        context: Context,
        payload: MedicationAlarmPayload,
        action: String,
        triggeredAt: Long,
    ): PendingIntent {
        val intent = payload.putInto(Intent(context, MedicationAlarmActionReceiver::class.java)).apply {
            this.action = action
            data = MedicationAlarmScheduler.alarmUri(payload.id, action.substringAfterLast('.'))
            putExtra(MedicationAlarmContract.EXTRA_TRIGGERED_AT, triggeredAt)
        }
        return PendingIntent.getBroadcast(
            context,
            payload.id,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private fun defaultAlarmSound() =
        RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM)
            ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION)

    private const val TAG = "MedicationAlarm"
}
