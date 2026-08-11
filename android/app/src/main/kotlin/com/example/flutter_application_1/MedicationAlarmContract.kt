package com.example.flutter_application_1

import android.annotation.SuppressLint
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import org.json.JSONArray
import org.json.JSONObject

data class MedicationAlarmPayload(
    val id: Int,
    val medicineId: String,
    val patientId: String,
    val name: String,
    val dosage: String,
    val title: String,
    val body: String,
    val scheduledAt: Long,
    val scheduleRevision: Long? = null,
) {
    fun toMap(): Map<String, Any> = mutableMapOf<String, Any>(
        "id" to id,
        "medicineId" to medicineId,
        "patientId" to patientId,
        "name" to name,
        "dosage" to dosage,
        "title" to title,
        "body" to body,
        "scheduledAt" to scheduledAt,
    ).apply {
        scheduleRevision?.let { put("scheduleRevision", it) }
    }

    fun putInto(intent: Intent): Intent = intent.apply {
        putExtra(MedicationAlarmContract.EXTRA_ID, id)
        putExtra(MedicationAlarmContract.EXTRA_MEDICINE_ID, medicineId)
        putExtra(MedicationAlarmContract.EXTRA_PATIENT_ID, patientId)
        putExtra(MedicationAlarmContract.EXTRA_NAME, name)
        putExtra(MedicationAlarmContract.EXTRA_DOSAGE, dosage)
        putExtra(MedicationAlarmContract.EXTRA_TITLE, title)
        putExtra(MedicationAlarmContract.EXTRA_BODY, body)
        putExtra(MedicationAlarmContract.EXTRA_SCHEDULED_AT, scheduledAt)
        scheduleRevision?.let {
            putExtra(MedicationAlarmContract.EXTRA_SCHEDULE_REVISION, it)
        }
    }

    fun toJson(): JSONObject = JSONObject().apply {
        put("id", id)
        put("medicineId", medicineId)
        put("patientId", patientId)
        put("name", name)
        put("dosage", dosage)
        put("title", title)
        put("body", body)
        put("scheduledAt", scheduledAt)
        scheduleRevision?.let { put("scheduleRevision", it) }
    }

    companion object {
        fun fromMap(values: Map<*, *>?, defaultScheduledAt: Long = 0L): MedicationAlarmPayload? {
            if (values == null) return null
            val id = (values["id"] as? Number)?.toInt() ?: return null
            val title = values["title"] as? String ?: "Pengingat obat"
            val body = values["body"] as? String ?: "Waktunya minum obat."
            return MedicationAlarmPayload(
                id = id,
                medicineId = (values["medicineId"] as? String).orEmpty().ifEmpty { id.toString() },
                patientId = (values["patientId"] as? String).orEmpty(),
                name = (values["name"] as? String).orEmpty().ifEmpty { title },
                dosage = (values["dosage"] as? String).orEmpty(),
                title = title,
                body = body,
                scheduledAt = (values["scheduledAt"] as? Number)?.toLong() ?: defaultScheduledAt,
                scheduleRevision = (values["scheduleRevision"] as? Number)?.toLong(),
            )
        }

        fun fromIntent(intent: Intent?): MedicationAlarmPayload? {
            if (intent == null || !intent.hasExtra(MedicationAlarmContract.EXTRA_ID)) return null
            val id = intent.getIntExtra(MedicationAlarmContract.EXTRA_ID, 0)
            return MedicationAlarmPayload(
                id = id,
                medicineId = intent.getStringExtra(MedicationAlarmContract.EXTRA_MEDICINE_ID)
                    .orEmpty().ifEmpty { id.toString() },
                patientId = intent.getStringExtra(MedicationAlarmContract.EXTRA_PATIENT_ID).orEmpty(),
                name = intent.getStringExtra(MedicationAlarmContract.EXTRA_NAME)
                    .orEmpty().ifEmpty { "Obat" },
                dosage = intent.getStringExtra(MedicationAlarmContract.EXTRA_DOSAGE).orEmpty(),
                title = intent.getStringExtra(MedicationAlarmContract.EXTRA_TITLE)
                    ?: "Pengingat obat",
                body = intent.getStringExtra(MedicationAlarmContract.EXTRA_BODY)
                    ?: "Waktunya minum obat.",
                scheduledAt = intent.getLongExtra(
                    MedicationAlarmContract.EXTRA_SCHEDULED_AT,
                    System.currentTimeMillis(),
                ),
                scheduleRevision = if (intent.hasExtra(
                        MedicationAlarmContract.EXTRA_SCHEDULE_REVISION,
                    )
                ) {
                    intent.getLongExtra(MedicationAlarmContract.EXTRA_SCHEDULE_REVISION, 0L)
                } else {
                    null
                },
            )
        }

        fun fromJson(json: JSONObject): MedicationAlarmPayload = MedicationAlarmPayload(
            id = json.getInt("id"),
            medicineId = json.optString("medicineId", json.getInt("id").toString()),
            patientId = json.optString("patientId"),
            name = json.optString("name", "Obat"),
            dosage = json.optString("dosage"),
            title = json.optString("title", "Pengingat obat"),
            body = json.optString("body", "Waktunya minum obat."),
            scheduledAt = json.getLong("scheduledAt"),
            scheduleRevision = if (json.has("scheduleRevision")) {
                json.optLong("scheduleRevision")
            } else {
                null
            },
        )
    }
}

data class MedicationAlarmEvent(
    val action: String,
    val payload: MedicationAlarmPayload,
    val occurredAt: Long,
    val snoozedUntil: Long? = null,
) {
    fun toMap(): Map<String, Any> = payload.toMap().toMutableMap().apply {
        put("action", action)
        put("occurredAt", occurredAt)
        snoozedUntil?.let { put("snoozedUntil", it) }
    }

    fun toJson(): JSONObject = payload.toJson().apply {
        put("action", action)
        put("occurredAt", occurredAt)
        snoozedUntil?.let { put("snoozedUntil", it) }
    }

    companion object {
        fun fromJson(json: JSONObject): MedicationAlarmEvent = MedicationAlarmEvent(
            action = json.getString("action"),
            payload = MedicationAlarmPayload.fromJson(json),
            occurredAt = json.getLong("occurredAt"),
            snoozedUntil = if (json.has("snoozedUntil")) json.getLong("snoozedUntil") else null,
        )
    }
}

object MedicationAlarmContract {
    const val CHANNEL_NAME = "medicine_control/reminders"

    const val ACTION_FIRE = "com.example.flutter_application_1.action.FIRE_MEDICATION_ALARM"
    const val ACTION_OPEN = "com.example.flutter_application_1.action.OPEN_MEDICATION_ALARM"
    const val ACTION_TAKEN = "com.example.flutter_application_1.action.TAKEN_MEDICATION_ALARM"
    const val ACTION_SNOOZE = "com.example.flutter_application_1.action.SNOOZE_MEDICATION_ALARM"
    const val ACTION_DISMISS = "com.example.flutter_application_1.action.DISMISS_MEDICATION_ALARM"
    const val ACTION_RUNTIME_EVENT =
        "com.example.flutter_application_1.action.RUNTIME_MEDICATION_ALARM_EVENT"

    const val EVENT_TRIGGERED = "triggered"
    const val EVENT_TAKEN = "taken"
    const val EVENT_SNOOZED = "snoozed"
    const val EVENT_DISMISSED = "dismissed"

    const val EXTRA_ID = "medication_alarm.id"
    const val EXTRA_MEDICINE_ID = "medication_alarm.medicine_id"
    const val EXTRA_PATIENT_ID = "medication_alarm.patient_id"
    const val EXTRA_NAME = "medication_alarm.name"
    const val EXTRA_DOSAGE = "medication_alarm.dosage"
    const val EXTRA_TITLE = "medication_alarm.title"
    const val EXTRA_BODY = "medication_alarm.body"
    const val EXTRA_SCHEDULED_AT = "medication_alarm.scheduled_at"
    const val EXTRA_SCHEDULE_REVISION = "medication_alarm.schedule_revision"
    const val EXTRA_TRIGGERED_AT = "medication_alarm.triggered_at"
    const val EXTRA_IS_ALARM = "medication_alarm.is_alarm"
}

object MedicationAlarmStore {
    private const val PREFERENCES = "medicine_reminders"
    private const val PAYLOAD_PREFIX = "payload_v2_"
    private const val PENDING_EVENT_LEGACY = "pending_alarm_event_v2"
    private const val PENDING_EVENTS = "pending_alarm_events_v3"
    private const val ACTIVE_ALARMS = "active_alarm_events_v1"
    private const val ACTIVE_PATIENT = "active_patient_v1"
    private const val REMOTE_REVISION_PREFIX = "remote_revision_v1_"
    private const val REMOTE_DELETED_PREFIX = "remote_deleted_v1_"
    private const val LEGACY_IDS = "scheduled_ids"
    private const val MAX_PENDING_EVENTS = 64
    private const val MAX_ACTIVE_ALARMS = 32
    private val lock = Any()

    private fun preferences(context: Context): SharedPreferences =
        context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)

    fun savePayload(context: Context, payload: MedicationAlarmPayload) {
        synchronized(lock) {
            val preferences = preferences(context)
            val editor = preferences.edit()
                .putString(PAYLOAD_PREFIX + payload.id, payload.toJson().toString())
            payload.scheduleRevision?.let { revision ->
                val revisionKey = REMOTE_REVISION_PREFIX + payload.medicineId
                val currentRevision = if (preferences.contains(revisionKey)) {
                    preferences.getLong(revisionKey, 0L)
                } else {
                    null
                }
                if (currentRevision == null || revision > currentRevision) {
                    editor.putLong(revisionKey, revision)
                    editor.putBoolean(REMOTE_DELETED_PREFIX + payload.medicineId, false)
                }
            }
            editor.commit()
        }
    }

    fun payload(context: Context, id: Int): MedicationAlarmPayload? = synchronized(lock) {
        val encoded = preferences(context).getString(PAYLOAD_PREFIX + id, null)
            ?: return@synchronized null
        runCatching { MedicationAlarmPayload.fromJson(JSONObject(encoded)) }.getOrNull()
    }

    fun payloads(context: Context): List<MedicationAlarmPayload> = synchronized(lock) {
        preferences(context).all
            .asSequence()
            .filter { (key, _) -> key.startsWith(PAYLOAD_PREFIX) }
            .mapNotNull { (_, value) ->
                (value as? String)?.let { encoded ->
                    runCatching { MedicationAlarmPayload.fromJson(JSONObject(encoded)) }.getOrNull()
                }
            }
            .toList()
    }

    fun removePayload(context: Context, id: Int) {
        synchronized(lock) {
            preferences(context).edit().remove(PAYLOAD_PREFIX + id).commit()
        }
    }

    fun storedIds(context: Context): Set<Int> = synchronized(lock) {
        val current = payloads(context).mapTo(mutableSetOf()) { it.id }
        val legacy = preferences(context).getStringSet(LEGACY_IDS, emptySet())
            .orEmpty()
            .mapNotNull { it.toIntOrNull() }
        current.addAll(legacy)
        current
    }

    fun updateLegacyIds(context: Context, ids: Set<Int>) {
        synchronized(lock) {
            preferences(context).edit()
                .putStringSet(LEGACY_IDS, ids.mapTo(mutableSetOf()) { it.toString() })
                .commit()
        }
    }

    @SuppressLint("ApplySharedPref")
    fun savePendingEvent(context: Context, event: MedicationAlarmEvent) {
        synchronized(lock) {
            val preferences = preferences(context)
            val events = readPendingEventsLocked(preferences)
            if (events.any { it.sameIdentity(event) }) return
            events.add(event)
            while (events.size > MAX_PENDING_EVENTS) events.removeAt(0)
            persistEventsLocked(preferences, PENDING_EVENTS, events, removeLegacy = true)
        }
    }

    fun pendingEvents(context: Context): List<MedicationAlarmEvent> = synchronized(lock) {
        readPendingEventsLocked(preferences(context)).toList()
    }

    fun pendingEvent(context: Context): MedicationAlarmEvent? = pendingEvents(context).firstOrNull()

    fun clearPendingEvents(context: Context) {
        synchronized(lock) {
            preferences(context).edit()
                .remove(PENDING_EVENTS)
                .remove(PENDING_EVENT_LEGACY)
                .commit()
        }
    }

    fun clearPendingEvent(context: Context) = clearPendingEvents(context)

    fun acknowledgePendingEvent(
        context: Context,
        id: Int,
        action: String,
        occurredAt: Long,
    ): Boolean = synchronized(lock) {
        val preferences = preferences(context)
        val events = readPendingEventsLocked(preferences)
        val index = events.indexOfFirst {
            it.payload.id == id && it.action == action && it.occurredAt == occurredAt
        }
        if (index < 0) return@synchronized false
        events.removeAt(index)
        persistEventsLocked(preferences, PENDING_EVENTS, events, removeLegacy = true)
        true
    }

    fun removePendingEventsForMedicine(context: Context, medicineId: String, id: Int) {
        synchronized(lock) {
            val preferences = preferences(context)
            val events = readPendingEventsLocked(preferences)
            val changed = events.removeAll {
                it.payload.id == id || it.payload.medicineId == medicineId
            }
            if (changed) {
                persistEventsLocked(preferences, PENDING_EVENTS, events, removeLegacy = true)
            }
        }
    }

    fun hasMatchingPendingTrigger(
        context: Context,
        payload: MedicationAlarmPayload,
    ): Boolean = pendingEvents(context).any {
        it.action == MedicationAlarmContract.EVENT_TRIGGERED && schedulesMatch(it.payload, payload)
    }

    fun hasMatchingStoredPayload(
        context: Context,
        payload: MedicationAlarmPayload,
    ): Boolean = payloads(context).any { schedulesMatch(it, payload) }

    fun saveActiveAlarm(context: Context, payload: MedicationAlarmPayload, triggeredAt: Long) {
        synchronized(lock) {
            val preferences = preferences(context)
            val alarms = readEventArrayLocked(preferences, ACTIVE_ALARMS)
            alarms.removeAll { it.payload.id == payload.id }
            alarms.add(
                MedicationAlarmEvent(
                    MedicationAlarmContract.EVENT_TRIGGERED,
                    payload,
                    triggeredAt,
                ),
            )
            while (alarms.size > MAX_ACTIVE_ALARMS) alarms.removeAt(0)
            persistEventsLocked(preferences, ACTIVE_ALARMS, alarms)
        }
    }

    fun activeAlarms(context: Context): List<MedicationAlarmEvent> = synchronized(lock) {
        readEventArrayLocked(preferences(context), ACTIVE_ALARMS).toList()
    }

    fun removeActiveAlarm(context: Context, id: Int): List<MedicationAlarmEvent> =
        synchronized(lock) {
            val preferences = preferences(context)
            val alarms = readEventArrayLocked(preferences, ACTIVE_ALARMS)
            alarms.removeAll { it.payload.id == id }
            persistEventsLocked(preferences, ACTIVE_ALARMS, alarms)
            alarms.toList()
        }

    fun clearActiveAlarms(context: Context) {
        synchronized(lock) {
            preferences(context).edit().remove(ACTIVE_ALARMS).commit()
        }
    }

    fun setActivePatient(context: Context, patientId: String?) {
        synchronized(lock) {
            val editor = preferences(context).edit()
            if (patientId.isNullOrBlank()) editor.remove(ACTIVE_PATIENT)
            else editor.putString(ACTIVE_PATIENT, patientId)
            editor.commit()
        }
    }

    fun activePatient(context: Context): String? = synchronized(lock) {
        preferences(context).getString(ACTIVE_PATIENT, null)?.takeIf { it.isNotBlank() }
    }

    fun acceptRemoteScheduleMutation(
        context: Context,
        medicineId: String,
        revision: Long?,
        deleted: Boolean,
    ): Boolean = synchronized(lock) {
        if (medicineId.isBlank()) return@synchronized false
        if (revision == null) return@synchronized true
        val preferences = preferences(context)
        val revisionKey = REMOTE_REVISION_PREFIX + medicineId
        val deletedKey = REMOTE_DELETED_PREFIX + medicineId
        val hasCurrent = preferences.contains(revisionKey)
        val currentRevision = if (hasCurrent) preferences.getLong(revisionKey, 0L) else null
        val currentDeleted = preferences.getBoolean(deletedKey, false)
        if (currentRevision != null && revision < currentRevision) return@synchronized false
        if (currentRevision == revision && currentDeleted && !deleted) return@synchronized false
        preferences.edit()
            .putLong(revisionKey, revision)
            .putBoolean(deletedKey, deleted)
            .commit()
        true
    }

    fun remoteDueAllowed(context: Context, medicineId: String, revision: Long?): Boolean =
        synchronized(lock) {
            if (medicineId.isBlank()) return@synchronized false
            if (revision == null) return@synchronized true
            val preferences = preferences(context)
            val revisionKey = REMOTE_REVISION_PREFIX + medicineId
            if (!preferences.contains(revisionKey)) {
                preferences.edit()
                    .putLong(revisionKey, revision)
                    .putBoolean(REMOTE_DELETED_PREFIX + medicineId, false)
                    .commit()
                return@synchronized true
            }
            val currentRevision = preferences.getLong(revisionKey, 0L)
            if (revision < currentRevision) return@synchronized false
            if (revision == currentRevision) {
                return@synchronized !preferences.getBoolean(
                    REMOTE_DELETED_PREFIX + medicineId,
                    false,
                )
            }
            preferences.edit()
                .putLong(revisionKey, revision)
                .putBoolean(REMOTE_DELETED_PREFIX + medicineId, false)
                .commit()
            true
        }

    fun clearRemoteScheduleStates(context: Context) {
        synchronized(lock) {
            val preferences = preferences(context)
            val editor = preferences.edit()
            preferences.all.keys
                .filter {
                    it.startsWith(REMOTE_REVISION_PREFIX) ||
                        it.startsWith(REMOTE_DELETED_PREFIX)
                }
                .forEach(editor::remove)
            editor.commit()
        }
    }

    private fun readPendingEventsLocked(
        preferences: SharedPreferences,
    ): MutableList<MedicationAlarmEvent> {
        val encoded = preferences.getString(PENDING_EVENTS, null)
        val events = readEventArray(encoded)
        var needsWrite = encoded != null && runCatching { JSONArray(encoded) }.isFailure
        val legacyEncoded = preferences.getString(PENDING_EVENT_LEGACY, null)
        if (legacyEncoded != null) {
            val legacy = runCatching {
                MedicationAlarmEvent.fromJson(JSONObject(legacyEncoded))
            }.getOrNull()
            if (legacy != null && events.none { it.sameIdentity(legacy) }) {
                events.add(0, legacy)
            }
            needsWrite = true
        }
        while (events.size > MAX_PENDING_EVENTS) {
            events.removeAt(0)
            needsWrite = true
        }
        if (needsWrite) {
            persistEventsLocked(preferences, PENDING_EVENTS, events, removeLegacy = true)
        }
        return events
    }

    private fun readEventArrayLocked(
        preferences: SharedPreferences,
        key: String,
    ): MutableList<MedicationAlarmEvent> = readEventArray(preferences.getString(key, null))

    private fun readEventArray(encoded: String?): MutableList<MedicationAlarmEvent> {
        if (encoded == null) return mutableListOf()
        return runCatching {
            val array = JSONArray(encoded)
            MutableList(array.length()) { index ->
                MedicationAlarmEvent.fromJson(array.getJSONObject(index))
            }
        }.getOrElse { mutableListOf() }
    }

    private fun persistEventsLocked(
        preferences: SharedPreferences,
        key: String,
        events: List<MedicationAlarmEvent>,
        removeLegacy: Boolean = false,
    ) {
        val editor = preferences.edit()
        if (events.isEmpty()) {
            editor.remove(key)
        } else {
            val array = JSONArray()
            events.forEach { array.put(it.toJson()) }
            editor.putString(key, array.toString())
        }
        if (removeLegacy) editor.remove(PENDING_EVENT_LEGACY)
        editor.commit()
    }

    private fun schedulesMatch(
        first: MedicationAlarmPayload,
        second: MedicationAlarmPayload,
    ): Boolean {
        val sameMedicine = first.id == second.id ||
            (first.medicineId.isNotBlank() && first.medicineId == second.medicineId)
        if (!sameMedicine || first.scheduledAt != second.scheduledAt) return false
        return first.scheduleRevision == null || second.scheduleRevision == null ||
            first.scheduleRevision == second.scheduleRevision
    }

    private fun MedicationAlarmEvent.sameIdentity(other: MedicationAlarmEvent): Boolean =
        payload.id == other.payload.id && action == other.action && occurredAt == other.occurredAt
}
