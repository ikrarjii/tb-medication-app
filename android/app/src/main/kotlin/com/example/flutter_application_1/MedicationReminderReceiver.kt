package com.example.flutter_application_1

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.PowerManager
import android.util.Log

class MedicationReminderReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val payload = MedicationAlarmPayload.fromIntent(intent) ?: legacyPayload(intent) ?: return
        val isAlarm = intent.getBooleanExtra(
            MedicationAlarmContract.EXTRA_IS_ALARM,
            intent.action == MedicationAlarmContract.ACTION_FIRE,
        )
        if (!isAlarm) {
            MedicationAlarmNotifications.postStandardNotification(context, payload)
            return
        }

        val powerManager = context.getSystemService(Context.POWER_SERVICE) as PowerManager
        val wakeLock = powerManager.newWakeLock(
            PowerManager.PARTIAL_WAKE_LOCK,
            "${context.packageName}:medication-alarm-receiver",
        ).apply { setReferenceCounted(false) }
        try {
            wakeLock.acquire(RECEIVER_WAKE_LOCK_TIMEOUT_MS)
            Log.i(TAG, "Alarm triggered id=${payload.id} scheduledAt=${payload.scheduledAt}")
            fireAlarm(context, payload)
        } finally {
            if (wakeLock.isHeld) wakeLock.release()
        }
    }

    private fun legacyPayload(intent: Intent): MedicationAlarmPayload? {
        if (!intent.hasExtra("notificationId")) return null
        val id = intent.getIntExtra("notificationId", 0)
        val title = intent.getStringExtra("title") ?: "Pengingat obat"
        return MedicationAlarmPayload(
            id = id,
            medicineId = id.toString(),
            patientId = "",
            name = title,
            dosage = "",
            title = title,
            body = intent.getStringExtra("body") ?: "Waktunya minum obat.",
            scheduledAt = System.currentTimeMillis(),
        )
    }

    companion object {
        private const val TAG = "MedicationAlarm"
        private const val RECEIVER_WAKE_LOCK_TIMEOUT_MS = 60_000L

        fun fireAlarm(
            context: Context,
            payload: MedicationAlarmPayload,
            triggeredAt: Long = System.currentTimeMillis(),
        ) {
            MedicationAlarmStore.savePendingEvent(
                context,
                MedicationAlarmEvent(
                    action = MedicationAlarmContract.EVENT_TRIGGERED,
                    payload = payload,
                    occurredAt = triggeredAt,
                ),
            )
            MedicationAlarmNotifications.postAlarm(context, payload, triggeredAt)
            val runtimeEvent = payload.putInto(
                Intent(MedicationAlarmContract.ACTION_RUNTIME_EVENT).apply {
                    setPackage(context.packageName)
                    putExtra(MedicationAlarmContract.EXTRA_TRIGGERED_AT, triggeredAt)
                    putExtra(MedicationAlarmContract.EXTRA_IS_ALARM, true)
                },
            )
            context.sendBroadcast(runtimeEvent)
        }
    }
}

/** Handles notification actions without depending on a running Flutter engine. */
class MedicationAlarmActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val payload = MedicationAlarmPayload.fromIntent(intent) ?: return
        val now = System.currentTimeMillis()
        val event = when (intent.action) {
            MedicationAlarmContract.ACTION_TAKEN -> {
                MedicationAlarmScheduler.cancel(context, payload.id)
                MedicationAlarmEvent(MedicationAlarmContract.EVENT_TAKEN, payload, now)
            }

            MedicationAlarmContract.ACTION_SNOOZE -> {
                val snoozed = MedicationAlarmScheduler.snooze(context, payload, 5L)
                MedicationAlarmEvent(
                    MedicationAlarmContract.EVENT_SNOOZED,
                    payload,
                    now,
                    snoozedUntil = snoozed.scheduledAt,
                )
            }

            MedicationAlarmContract.ACTION_DISMISS -> {
                MedicationAlarmScheduler.cancel(context, payload.id)
                MedicationAlarmEvent(MedicationAlarmContract.EVENT_DISMISSED, payload, now)
            }

            else -> return
        }
        MedicationAlarmStore.savePendingEvent(context, event)
        Log.i("MedicationAlarm", "Alarm stopped id=${payload.id} action=${event.action}")
        context.sendBroadcast(
            Intent(MedicationAlarmContract.ACTION_RUNTIME_EVENT).apply {
                setPackage(context.packageName)
            },
        )
    }
}
