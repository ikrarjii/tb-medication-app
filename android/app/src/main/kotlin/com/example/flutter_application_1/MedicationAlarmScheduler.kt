package com.example.flutter_application_1

import android.app.AlarmManager
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.util.Log

object MedicationAlarmScheduler {
    private const val DEFAULT_SNOOZE_MINUTES = 5L

    fun schedule(context: Context, payload: MedicationAlarmPayload): Boolean {
        if (payload.scheduledAt <= System.currentTimeMillis()) {
            Log.w(TAG, "Alarm not scheduled: time is in the past id=${payload.id}")
            return false
        }

        val appContext = context.applicationContext
        MedicationAlarmStore.savePayload(appContext, payload)
        val exact = armAlarm(appContext, payload)
        MedicationAlarmStore.updateLegacyIds(appContext, MedicationAlarmStore.storedIds(appContext))
        if (exact) {
            Log.i(TAG, "Alarm scheduled exactly id=${payload.id} at=${payload.scheduledAt}")
        } else {
            Log.w(TAG, "Exact alarm permission missing; payload retained id=${payload.id}")
        }
        return exact
    }

    fun snooze(
        context: Context,
        payload: MedicationAlarmPayload,
        minutes: Long = DEFAULT_SNOOZE_MINUTES,
    ): MedicationAlarmPayload {
        stopActiveAlarm(context, payload.id)
        cancelPendingIntent(context, payload.id)
        val safeMinutes = minutes.coerceAtLeast(1L)
        val snoozed = payload.copy(scheduledAt = System.currentTimeMillis() + safeMinutes * 60_000L)
        schedule(context, snoozed)
        return snoozed
    }

    fun cancel(context: Context, id: Int, removePayload: Boolean = true) {
        cancelPendingIntent(context, id)
        stopActiveAlarm(context, id)
        if (removePayload) MedicationAlarmStore.removePayload(context, id)
        MedicationAlarmStore.updateLegacyIds(context, MedicationAlarmStore.storedIds(context) - id)
    }

    fun sync(
        context: Context,
        activeIds: Set<Int>,
        clearPendingEvent: Boolean = false,
    ) {
        val storedIds = MedicationAlarmStore.storedIds(context)
        for (id in storedIds - activeIds) {
            cancel(context, id)
        }
        if (clearPendingEvent && activeIds.isEmpty()) {
            MedicationAlarmPlaybackService.stopAll(context)
            MedicationAlarmStore.clearPendingEvents(context)
            MedicationAlarmStore.clearActiveAlarms(context)
            MedicationAlarmStore.clearRemoteScheduleStates(context)
            MedicationAlarmStore.setActivePatient(context, null)
        }
        MedicationAlarmStore.updateLegacyIds(context, activeIds)
    }

    fun restoreFutureAlarms(context: Context) {
        val now = System.currentTimeMillis()
        val futureIds = mutableSetOf<Int>()
        for (payload in MedicationAlarmStore.payloads(context)) {
            if (payload.scheduledAt > now) {
                if (armAlarm(context, payload)) {
                    futureIds.add(payload.id)
                    Log.i(TAG, "Alarm restored id=${payload.id} at=${payload.scheduledAt}")
                } else {
                    // Keep the payload durable so the permission-state receiver
                    // can retry after exact-alarm access is granted.
                    futureIds.add(payload.id)
                    Log.w(TAG, "Alarm restore waiting for exact access id=${payload.id}")
                }
            } else {
                cancelPendingIntent(context, payload.id)
                MedicationAlarmStore.removePayload(context, payload.id)
            }
        }
        MedicationAlarmStore.updateLegacyIds(context, futureIds)
    }

    fun stopActiveAlarm(context: Context, id: Int) {
        MedicationAlarmPlaybackService.stop(context, id)
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.cancel(notificationId(id))
        Log.i(TAG, "Alarm stopped id=$id")
    }

    fun notificationId(id: Int): Int = if (id == 0) 1 else id

    private fun armAlarm(context: Context, payload: MedicationAlarmPayload): Boolean {
        val manager = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val operation = firePendingIntent(context, payload, PendingIntent.FLAG_UPDATE_CURRENT)
            ?: return false

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && !manager.canScheduleExactAlarms()) {
            return false
        }

        return try {
            manager.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, payload.scheduledAt, operation)
            true
        } catch (_: SecurityException) {
            Log.e(TAG, "Exact alarm denied by Android id=${payload.id}")
            false
        }
    }

    private fun cancelPendingIntent(context: Context, id: Int) {
        val operation = firePendingIntent(
            context,
            MedicationAlarmPayload(
                id = id,
                medicineId = id.toString(),
                patientId = "",
                name = "",
                dosage = "",
                title = "",
                body = "",
                scheduledAt = 0L,
            ),
            PendingIntent.FLAG_NO_CREATE,
        ) ?: return
        val manager = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        manager.cancel(operation)
        operation.cancel()
    }

    private fun firePendingIntent(
        context: Context,
        payload: MedicationAlarmPayload,
        creationFlag: Int,
    ): PendingIntent? {
        val intent = payload.putInto(
            Intent(context, MedicationReminderReceiver::class.java).apply {
                action = MedicationAlarmContract.ACTION_FIRE
                data = alarmUri(payload.id, "fire")
                putExtra(MedicationAlarmContract.EXTRA_IS_ALARM, true)
            },
        )
        return PendingIntent.getBroadcast(
            context,
            payload.id,
            intent,
            creationFlag or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    fun alarmUri(id: Int, action: String): Uri = Uri.Builder()
        .scheme("medicine-control")
        .authority("alarm")
        .appendPath(id.toString())
        .appendPath(action)
        .build()

    private const val TAG = "MedicationAlarm"
}

class MedicationAlarmBootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        Log.i("MedicationAlarm", "Reschedule receiver action=${intent.action}")
        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED,
            Intent.ACTION_MY_PACKAGE_REPLACED,
            AlarmManager.ACTION_SCHEDULE_EXACT_ALARM_PERMISSION_STATE_CHANGED,
            -> {
                MedicationAlarmNotifications.createChannels(context)
                val manager = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
                if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S || manager.canScheduleExactAlarms()) {
                    MedicationAlarmScheduler.restoreFutureAlarms(context.applicationContext)
                } else {
                    Log.w("MedicationAlarm", "Exact access still unavailable; restore deferred")
                }
            }
        }
    }
}
