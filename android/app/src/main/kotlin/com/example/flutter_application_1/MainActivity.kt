package com.example.flutter_application_1

import android.Manifest
import android.app.AlarmManager
import android.app.NotificationManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import android.util.Log
import android.view.WindowManager
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var pendingPermissionResult: MethodChannel.Result? = null
    private var reminderChannel: MethodChannel? = null
    private var dartAlarmHandlerReady = false
    private var runtimeAlarmReceiverRegistered = false
    private var alarmAccessFlowActive = false
    private var waitingForAlarmAccessSettings = false
    private val attemptedAlarmAccessSteps = mutableSetOf<AlarmAccessStep>()
    private val runtimeAlarmReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action != MedicationAlarmContract.ACTION_RUNTIME_EVENT) return
            deliverPendingAlarmEvents()
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        handleAlarmIntent(intent, deliverToDart = false)
        super.onCreate(savedInstanceState)
        registerRuntimeAlarmReceiver()
        configureAlarmWindow(intent)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        reminderChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            MedicationAlarmContract.CHANNEL_NAME,
        ).also { channel ->
            channel.setMethodCallHandler(::handleMethodCall)
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        configureAlarmWindow(intent)
        handleAlarmIntent(intent, deliverToDart = true)
    }

    override fun onResume() {
        super.onResume()
        if (alarmAccessFlowActive && waitingForAlarmAccessSettings) {
            waitingForAlarmAccessSettings = false
            Handler(Looper.getMainLooper()).postDelayed(
                { launchNextAlarmAccessSetting() },
                ACCESS_SETTINGS_RETURN_DELAY_MS,
            )
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == NOTIFICATION_PERMISSION_REQUEST) {
            val granted = grantResults.isNotEmpty() &&
                grantResults[0] == PackageManager.PERMISSION_GRANTED
            pendingPermissionResult?.success(
                granted && MedicationAlarmNotifications.notificationsAllowed(this),
            )
            pendingPermissionResult = null
        }
    }

    override fun onDestroy() {
        pendingPermissionResult?.success(false)
        pendingPermissionResult = null
        if (runtimeAlarmReceiverRegistered) {
            runCatching { unregisterReceiver(runtimeAlarmReceiver) }
            runtimeAlarmReceiverRegistered = false
        }
        reminderChannel = null
        super.onDestroy()
    }

    private fun handleMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "initializeChannels" -> {
                MedicationAlarmNotifications.createChannels(this)
                dartAlarmHandlerReady = true
                result.success(null)
            }

            "requestPermission" -> requestNotificationPermission(result)

            "requestAlarmAccess" -> result.success(requestAlarmAccess())

            "getAlarmAccessStatus" -> result.success(alarmAccessStatus())

            "schedule" -> {
                val payload = MedicationAlarmPayload.fromMap(call.arguments as? Map<*, *>)
                if (payload == null || payload.scheduledAt <= System.currentTimeMillis()) {
                    result.error("invalid_alarm", "Alarm payload or scheduledAt is invalid.", null)
                    return
                }
                MedicationAlarmScheduler.schedule(this, payload)
                result.success(null)
            }

            "showAlarm" -> {
                val payload = MedicationAlarmPayload.fromMap(
                    call.arguments as? Map<*, *>,
                    defaultScheduledAt = System.currentTimeMillis(),
                )
                if (payload == null) {
                    result.error("invalid_alarm", "Alarm payload is invalid.", null)
                    return
                }
                sendReminderBroadcast(payload, isAlarm = true)
                result.success(null)
            }

            // Kept as a non-alarm compatibility path for foreground FCM updates.
            "show" -> {
                val payload = MedicationAlarmPayload.fromMap(
                    call.arguments as? Map<*, *>,
                    defaultScheduledAt = System.currentTimeMillis(),
                )
                if (payload == null) {
                    result.error("invalid_notification", "Notification payload is invalid.", null)
                    return
                }
                sendReminderBroadcast(payload, isAlarm = false)
                result.success(null)
            }

            "stop" -> {
                val id = idFromArguments(call.arguments)
                if (id == null) {
                    result.error("invalid_alarm", "Alarm id is required.", null)
                    return
                }
                MedicationAlarmScheduler.cancel(this, id)
                result.success(null)
            }

            "snooze" -> {
                val arguments = call.arguments as? Map<*, *>
                val payload = payloadForAction(arguments)
                if (payload == null) {
                    result.error("missing_alarm", "Stored alarm payload was not found.", null)
                    return
                }
                val minutes = ((arguments?.get("minutes")
                    ?: arguments?.get("durationMinutes")) as? Number)?.toLong() ?: 5L
                MedicationAlarmScheduler.snooze(this, payload, minutes)
                result.success(null)
            }

            "sync" -> {
                val arguments = call.arguments as? Map<*, *>
                val activeIds = (arguments?.get("activeIds") as? List<*>)
                    .orEmpty()
                    .mapNotNull { (it as? Number)?.toInt() }
                    .toSet()
                val clearPendingEvent =
                    arguments?.get("clearPendingEvent") as? Boolean ?: false
                MedicationAlarmScheduler.sync(this, activeIds, clearPendingEvent)
                result.success(null)
            }

            "getPendingAlarmEvent" -> {
                dartAlarmHandlerReady = true
                val event = MedicationAlarmStore.pendingEvent(this)
                result.success(event?.toMap())
            }

            "getPendingAlarmEvents" -> {
                dartAlarmHandlerReady = true
                result.success(
                    MedicationAlarmStore.pendingEvents(this).map { it.toMap() },
                )
            }

            "ackAlarmEvent" -> {
                val arguments = call.arguments as? Map<*, *>
                val id = (arguments?.get("id") as? Number)?.toInt()
                val action = arguments?.get("action") as? String
                val occurredAt = (arguments?.get("occurredAt") as? Number)?.toLong()
                if (id == null || action.isNullOrBlank() || occurredAt == null) {
                    result.error(
                        "invalid_alarm_ack",
                        "Alarm id, action, and occurredAt are required.",
                        null,
                    )
                    return
                }
                result.success(
                    MedicationAlarmStore.acknowledgePendingEvent(
                        this,
                        id,
                        action,
                        occurredAt,
                    ),
                )
            }

            "setActivePatient" -> {
                val arguments = call.arguments as? Map<*, *>
                if (arguments == null || !arguments.containsKey("patientId")) {
                    result.error(
                        "invalid_active_patient",
                        "patientId must be a string or null.",
                        null,
                    )
                    return
                }
                val value = arguments["patientId"]
                if (value != null && value !is String) {
                    result.error(
                        "invalid_active_patient",
                        "patientId must be a string or null.",
                        null,
                    )
                    return
                }
                MedicationAlarmStore.setActivePatient(
                    this,
                    (value as? String)?.trim()?.takeIf { it.isNotEmpty() },
                )
                result.success(null)
            }

            else -> result.notImplemented()
        }
    }

    private fun requestNotificationPermission(result: MethodChannel.Result) {
        MedicationAlarmNotifications.createChannels(this)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            if (pendingPermissionResult != null) {
                result.error("permission_pending", "A notification permission request is already active.", null)
                return
            }
            pendingPermissionResult = result
            requestPermissions(
                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                NOTIFICATION_PERMISSION_REQUEST,
            )
            return
        }
        result.success(MedicationAlarmNotifications.notificationsAllowed(this))
    }

    private fun requestAlarmAccess(): Boolean {
        alarmAccessFlowActive = true
        waitingForAlarmAccessSettings = false
        attemptedAlarmAccessSteps.clear()
        launchNextAlarmAccessSetting()
        return alarmAccessStatus().values.all { it }
    }

    /**
     * Opens each special-access screen in sequence. A step is attempted once
     * per user-initiated flow so denying one permission cannot create a loop.
     */
    private fun launchNextAlarmAccessSetting() {
        if (!alarmAccessFlowActive || isFinishing || isDestroyed) return
        val packageUri = Uri.parse("package:$packageName")
        val stepAndIntent = when {
            !canScheduleExactAlarms() && attemptedAlarmAccessSteps.add(AlarmAccessStep.EXACT) ->
                AlarmAccessStep.EXACT to Intent(
                    Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM,
                    packageUri,
                )

            !canUseFullScreenIntent() && attemptedAlarmAccessSteps.add(AlarmAccessStep.FULL_SCREEN) ->
                AlarmAccessStep.FULL_SCREEN to Intent(
                    Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT,
                    packageUri,
                )

            !isIgnoringBatteryOptimizations() &&
                attemptedAlarmAccessSteps.add(AlarmAccessStep.BATTERY) ->
                AlarmAccessStep.BATTERY to Intent(
                    Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                    packageUri,
                )

            else -> null
        }
        if (stepAndIntent == null) {
            alarmAccessFlowActive = false
            waitingForAlarmAccessSettings = false
            Log.i(TAG, "Alarm access flow complete status=${alarmAccessStatus()}")
            if (canScheduleExactAlarms()) {
                MedicationAlarmScheduler.restoreFutureAlarms(applicationContext)
            }
            return
        }

        val (step, settingsIntent) = stepAndIntent
        Log.i(TAG, "Requesting alarm access step=$step")
        val launched = runCatching {
            waitingForAlarmAccessSettings = true
            startActivity(settingsIntent)
        }.onFailure {
            Log.w(TAG, "Unable to open alarm access step=$step", it)
        }.isSuccess
        if (!launched) {
            waitingForAlarmAccessSettings = false
            launchNextAlarmAccessSetting()
        }
    }

    private fun alarmAccessStatus(): Map<String, Boolean> = mapOf(
        "exactAlarm" to canScheduleExactAlarms(),
        "fullScreenIntent" to canUseFullScreenIntent(),
        "batteryOptimization" to isIgnoringBatteryOptimizations(),
        "notifications" to MedicationAlarmNotifications.notificationsAllowed(this),
    )

    private fun canScheduleExactAlarms(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return true
        return (getSystemService(Context.ALARM_SERVICE) as AlarmManager).canScheduleExactAlarms()
    }

    private fun canUseFullScreenIntent(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) return true
        return (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
            .canUseFullScreenIntent()
    }

    private fun isIgnoringBatteryOptimizations(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return true
        return (getSystemService(Context.POWER_SERVICE) as PowerManager)
            .isIgnoringBatteryOptimizations(packageName)
    }

    private fun sendReminderBroadcast(payload: MedicationAlarmPayload, isAlarm: Boolean) {
        val broadcast = payload.putInto(Intent(this, MedicationReminderReceiver::class.java)).apply {
            action = if (isAlarm) MedicationAlarmContract.ACTION_FIRE else ACTION_SHOW_NOTIFICATION
            data = MedicationAlarmScheduler.alarmUri(payload.id, if (isAlarm) "show" else "notification")
            putExtra(MedicationAlarmContract.EXTRA_IS_ALARM, isAlarm)
        }
        sendBroadcast(broadcast)
    }

    private fun handleAlarmIntent(incoming: Intent?, deliverToDart: Boolean) {
        val action = incoming?.action ?: return
        if (action !in alarmActivityActions) return
        val payload = MedicationAlarmPayload.fromIntent(incoming) ?: return
        val now = System.currentTimeMillis()
        val event = when (action) {
            MedicationAlarmContract.ACTION_TAKEN -> {
                MedicationAlarmScheduler.cancel(this, payload.id)
                MedicationAlarmEvent(MedicationAlarmContract.EVENT_TAKEN, payload, now)
            }

            MedicationAlarmContract.ACTION_SNOOZE -> {
                val snoozed = MedicationAlarmScheduler.snooze(this, payload, 5L)
                MedicationAlarmEvent(
                    MedicationAlarmContract.EVENT_SNOOZED,
                    payload,
                    now,
                    snoozedUntil = snoozed.scheduledAt,
                )
            }

            MedicationAlarmContract.ACTION_DISMISS -> {
                MedicationAlarmScheduler.cancel(this, payload.id)
                MedicationAlarmEvent(MedicationAlarmContract.EVENT_DISMISSED, payload, now)
            }

            else -> MedicationAlarmEvent(
                MedicationAlarmContract.EVENT_TRIGGERED,
                payload,
                incoming.getLongExtra(MedicationAlarmContract.EXTRA_TRIGGERED_AT, now),
            )
        }
        MedicationAlarmStore.savePendingEvent(this, event)
        if (deliverToDart) deliverPendingAlarmEvents()
    }

    private fun deliverPendingAlarmEvents() {
        if (!dartAlarmHandlerReady) return
        val channel = reminderChannel ?: return
        MedicationAlarmStore.pendingEvents(this).forEach { event ->
            channel.invokeMethod("alarmEvent", event.toMap())
        }
    }

    private fun registerRuntimeAlarmReceiver() {
        if (runtimeAlarmReceiverRegistered) return
        ContextCompat.registerReceiver(
            this,
            runtimeAlarmReceiver,
            IntentFilter(MedicationAlarmContract.ACTION_RUNTIME_EVENT),
            ContextCompat.RECEIVER_NOT_EXPORTED,
        )
        runtimeAlarmReceiverRegistered = true
    }

    private fun configureAlarmWindow(incoming: Intent?) {
        if (incoming?.action !in alarmActivityActions) return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        } else {
            @Suppress("DEPRECATION")
            window.addFlags(
                WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                    WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON,
            )
        }
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    }

    private fun payloadForAction(arguments: Map<*, *>?): MedicationAlarmPayload? {
        val id = (arguments?.get("id") as? Number)?.toInt() ?: return null
        return MedicationAlarmStore.payload(this, id)
            ?: MedicationAlarmPayload.fromMap(arguments, System.currentTimeMillis())
    }

    private fun idFromArguments(arguments: Any?): Int? = when (arguments) {
        is Number -> arguments.toInt()
        is Map<*, *> -> (arguments["id"] as? Number)?.toInt()
        else -> null
    }

    companion object {
        private const val TAG = "MedicationAlarm"
        private const val NOTIFICATION_PERMISSION_REQUEST = 2301
        private const val ACCESS_SETTINGS_RETURN_DELAY_MS = 350L
        private const val ACTION_SHOW_NOTIFICATION =
            "com.example.flutter_application_1.action.SHOW_MEDICATION_NOTIFICATION"
        private val alarmActivityActions = setOf(
            MedicationAlarmContract.ACTION_OPEN,
            MedicationAlarmContract.ACTION_TAKEN,
            MedicationAlarmContract.ACTION_SNOOZE,
            MedicationAlarmContract.ACTION_DISMISS,
        )
    }

    private enum class AlarmAccessStep {
        EXACT,
        FULL_SCREEN,
        BATTERY,
    }
}
