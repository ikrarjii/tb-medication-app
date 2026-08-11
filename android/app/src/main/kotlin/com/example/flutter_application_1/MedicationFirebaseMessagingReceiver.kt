package com.example.flutter_application_1

import android.content.Context
import android.content.Intent
import android.util.Log
import io.flutter.plugins.firebase.messaging.FlutterFirebaseMessagingReceiver

/**
 * Extends firebase_messaging's public receiver so its foreground LiveData and
 * background isolate delivery remain authoritative for Flutter. Native alarm
 * projection is then applied synchronously for schedule data messages, which
 * also works when no Flutter engine is running.
 */
class MedicationFirebaseMessagingReceiver : FlutterFirebaseMessagingReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        runCatching { super.onReceive(context, intent) }
            .onFailure { Log.w(TAG, "firebase_messaging receiver failed", it) }
        runCatching { handleMedicationData(context.applicationContext, intent) }
            .onFailure { Log.w(TAG, "Native medication push handling failed", it) }
    }

    private fun handleMedicationData(context: Context, intent: Intent) {
        val type = intent.stringData("type") ?: return
        if (type !in MEDICATION_TYPES) return
        val patientId = intent.stringData("patientId") ?: return
        if (MedicationAlarmStore.activePatient(context) != patientId) return
        val medicineId = intent.stringData("medicineId") ?: return
        if (medicineId.isBlank()) return
        val revision = intent.stringData("scheduleRevision")
            ?.toLongOrNull()
            ?.takeIf { it >= 0L }

        when (type) {
            TYPE_SCHEDULE_CREATED,
            TYPE_SCHEDULE_UPDATED,
            -> applyScheduleMutation(
                context,
                intent,
                medicineId,
                patientId,
                revision,
            )

            TYPE_SCHEDULE_DELETED -> applyScheduleDeletion(
                context,
                medicineId,
                revision,
            )

            TYPE_DUE -> applyDueAlarm(
                context,
                intent,
                medicineId,
                patientId,
                revision,
            )
        }
    }

    private fun applyScheduleMutation(
        context: Context,
        intent: Intent,
        medicineId: String,
        patientId: String,
        revision: Long?,
    ) {
        if (!MedicationAlarmStore.acceptRemoteScheduleMutation(
                context,
                medicineId,
                revision,
                deleted = false,
            )
        ) {
            return
        }
        val id = MedicationReminderId.forMedicine(medicineId)
        val scheduledAt = intent.stringData("scheduledAt")?.toLongOrNull()
        if (scheduledAt == null || scheduledAt <= 0L) {
            MedicationAlarmScheduler.cancel(context, id)
            MedicationAlarmStore.removePendingEventsForMedicine(context, medicineId, id)
            return
        }
        val payload = intent.medicationPayload(
            id = id,
            medicineId = medicineId,
            patientId = patientId,
            scheduledAt = scheduledAt,
            revision = revision,
        )
        if (MedicationAlarmStore.hasMatchingPendingTrigger(context, payload)) return

        if (!MedicationAlarmStore.hasMatchingStoredPayload(context, payload)) {
            MedicationAlarmScheduler.cancel(context, id)
            MedicationAlarmStore.removePendingEventsForMedicine(context, medicineId, id)
        }
        if (scheduledAt > System.currentTimeMillis()) {
            MedicationAlarmScheduler.schedule(context, payload)
        }
    }

    private fun applyScheduleDeletion(
        context: Context,
        medicineId: String,
        revision: Long?,
    ) {
        if (!MedicationAlarmStore.acceptRemoteScheduleMutation(
                context,
                medicineId,
                revision,
                deleted = true,
            )
        ) {
            return
        }
        val id = MedicationReminderId.forMedicine(medicineId)
        MedicationAlarmScheduler.cancel(context, id)
        MedicationAlarmStore.removePendingEventsForMedicine(context, medicineId, id)
    }

    private fun applyDueAlarm(
        context: Context,
        intent: Intent,
        medicineId: String,
        patientId: String,
        revision: Long?,
    ) {
        if (!MedicationAlarmStore.remoteDueAllowed(context, medicineId, revision)) return
        val id = MedicationReminderId.forMedicine(medicineId)
        val payload = intent.medicationPayload(
            id = id,
            medicineId = medicineId,
            patientId = patientId,
            scheduledAt = intent.stringData("scheduledAt")?.toLongOrNull()
                ?: System.currentTimeMillis(),
            revision = revision,
        )
        if (MedicationAlarmStore.hasMatchingStoredPayload(context, payload) ||
            MedicationAlarmStore.hasMatchingPendingTrigger(context, payload)
        ) {
            return
        }

        // A differently revised/timed local entry must not fire after this
        // server-authoritative due event.
        MedicationAlarmScheduler.cancel(context, id)
        MedicationAlarmStore.removePendingEventsForMedicine(context, medicineId, id)
        MedicationReminderReceiver.fireAlarm(context, payload)
    }

    private fun Intent.medicationPayload(
        id: Int,
        medicineId: String,
        patientId: String,
        scheduledAt: Long,
        revision: Long?,
    ): MedicationAlarmPayload {
        val name = stringData("medicineName")
            ?: stringData("name")
            ?: "Obat"
        val dosage = stringData("dosage").orEmpty()
        return MedicationAlarmPayload(
            id = id,
            medicineId = medicineId,
            patientId = patientId,
            name = name,
            dosage = dosage,
            title = "Waktunya minum $name",
            body = if (dosage.isNotEmpty()) {
                "Minum $dosage sesuai jadwal."
            } else {
                "Jadwal minum obat Anda sudah tiba."
            },
            scheduledAt = scheduledAt,
            scheduleRevision = revision,
        )
    }

    private fun Intent.stringData(key: String): String? = extras
        ?.get(key)
        ?.toString()
        ?.takeIf { it.isNotBlank() }

    companion object {
        private const val TAG = "MedicationFCM"
        private const val TYPE_SCHEDULE_CREATED = "schedule_created"
        private const val TYPE_SCHEDULE_UPDATED = "schedule_updated"
        private const val TYPE_SCHEDULE_DELETED = "schedule_deleted"
        private const val TYPE_DUE = "due"
        private val MEDICATION_TYPES = setOf(
            TYPE_SCHEDULE_CREATED,
            TYPE_SCHEDULE_UPDATED,
            TYPE_SCHEDULE_DELETED,
            TYPE_DUE,
        )
    }
}

object MedicationReminderId {
    /** FNV-1a over UTF-16 code units, exactly matching Dart's codeUnits loop. */
    fun forMedicine(medicineId: String): Int {
        var hash = 0x811c9dc5L
        medicineId.forEach { codeUnit ->
            hash = hash xor codeUnit.code.toLong()
            hash = (hash * 0x01000193L) and 0xffffffffL
        }
        val positive = (hash and 0x7fffffffL).toInt()
        return if (positive == 0) 1 else positive
    }
}
