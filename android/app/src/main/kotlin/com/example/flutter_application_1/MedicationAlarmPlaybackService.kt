package com.example.flutter_application_1

import android.app.Service
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.MediaPlayer
import android.media.RingtoneManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.util.Log

class MedicationAlarmPlaybackService : Service() {
    private var mediaPlayer: MediaPlayer? = null
    private var vibrator: Vibrator? = null
    private var wakeLock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        runningInstance = this
        val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = powerManager.newWakeLock(
            PowerManager.PARTIAL_WAKE_LOCK,
            "$packageName:medication-alarm-playback",
        ).apply { setReferenceCounted(false) }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val payload = MedicationAlarmPayload.fromIntent(intent)
        if (payload != null) {
            val triggeredAt = intent?.getLongExtra(
                MedicationAlarmContract.EXTRA_TRIGGERED_AT,
                System.currentTimeMillis(),
            ) ?: System.currentTimeMillis()
            MedicationAlarmStore.saveActiveAlarm(this, payload, triggeredAt)
        }
        if (!reconcileActiveAlarms()) {
            stopSelf(startId)
            return START_NOT_STICKY
        }
        return START_STICKY
    }

    override fun onDestroy() {
        if (runningInstance === this) runningInstance = null
        stopRepeatingAlarm()
        stopForeground(STOP_FOREGROUND_REMOVE)
        releaseWakeLock()
        Log.i(TAG, "Foreground alarm service stopped")
        super.onDestroy()
    }

    private fun reconcileActiveAlarms(): Boolean {
        val activeAlarm = MedicationAlarmStore.activeAlarms(this).lastOrNull()
        if (activeAlarm == null) {
            stopRepeatingAlarm()
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
            return false
        }
        MedicationAlarmNotifications.createChannels(this)
        startForeground(
            MedicationAlarmScheduler.notificationId(activeAlarm.payload.id),
            MedicationAlarmNotifications.buildAlarmNotification(
                this,
                activeAlarm.payload,
                activeAlarm.occurredAt,
                useFallbackChannel = false,
            ),
        )
        Log.i(TAG, "Foreground service started id=${activeAlarm.payload.id}")
        Log.i(TAG, "Alarm notification displayed id=${activeAlarm.payload.id}")
        if (!startRepeatingAlarm()) {
            MedicationAlarmNotifications.postFallbackAlarm(
                this,
                activeAlarm.payload,
                activeAlarm.occurredAt,
            )
        }
        acquireWakeLock()
        return true
    }

    private fun startRepeatingAlarm(): Boolean {
        if (mediaPlayer?.isPlaying == true) return true
        stopRepeatingAlarm()
        val alarmUri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM)
            ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION)
            ?: return false
        val player = MediaPlayer()
        val playerStarted = runCatching {
            player.also {
                player.setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_ALARM)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .build(),
                )
                player.setWakeMode(this, PowerManager.PARTIAL_WAKE_LOCK)
                player.setDataSource(this, alarmUri)
                player.isLooping = true
                player.prepare()
                player.start()
                mediaPlayer = player
            }
        }.onFailure {
            runCatching { player.release() }
        }.isSuccess

        runCatching {
            vibrator = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                getSystemService(VibratorManager::class.java).defaultVibrator
            } else {
                @Suppress("DEPRECATION")
                getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
            }
            vibrator?.let { alarmVibrator ->
                if (alarmVibrator.hasVibrator()) {
                    val pattern = longArrayOf(0L, 900L, 450L, 900L)
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        alarmVibrator.vibrate(VibrationEffect.createWaveform(pattern, 0))
                    } else {
                        @Suppress("DEPRECATION")
                        alarmVibrator.vibrate(pattern, 0)
                    }
                }
            }
        }
        return playerStarted
    }

    private fun stopRepeatingAlarm() {
        mediaPlayer?.runCatching {
            if (isPlaying) stop()
            reset()
            release()
        }
        mediaPlayer = null
        vibrator?.cancel()
        vibrator = null
        releaseWakeLock()
    }

    private fun acquireWakeLock() {
        val lock = wakeLock ?: return
        if (!lock.isHeld) lock.acquire()
    }

    private fun releaseWakeLock() {
        wakeLock?.let { if (it.isHeld) it.release() }
    }

    companion object {
        private const val TAG = "MedicationAlarm"
        @Volatile
        private var runningInstance: MedicationAlarmPlaybackService? = null

        fun start(
            context: Context,
            payload: MedicationAlarmPayload,
            triggeredAt: Long,
        ): Boolean {
            val serviceIntent = payload.putInto(
                Intent(context, MedicationAlarmPlaybackService::class.java).apply {
                    putExtra(MedicationAlarmContract.EXTRA_TRIGGERED_AT, triggeredAt)
                },
            )
            return try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(serviceIntent)
                } else {
                    context.startService(serviceIntent)
                }
                true
            } catch (error: Exception) {
                Log.e(TAG, "Unable to start foreground alarm service id=${payload.id}", error)
                false
            }
        }

        fun stop(context: Context, id: Int) {
            val remaining = MedicationAlarmStore.removeActiveAlarm(context, id)
            val service = runningInstance
            if (service != null) {
                service.reconcileActiveAlarms()
            } else if (remaining.isEmpty()) {
                runCatching {
                    context.stopService(Intent(context, MedicationAlarmPlaybackService::class.java))
                }
            } else {
                val next = remaining.last()
                start(context, next.payload, next.occurredAt)
            }
        }

        fun stopAll(context: Context) {
            MedicationAlarmStore.clearActiveAlarms(context)
            val service = runningInstance
            if (service != null) {
                service.reconcileActiveAlarms()
            } else {
                runCatching {
                    context.stopService(Intent(context, MedicationAlarmPlaybackService::class.java))
                }
            }
        }
    }
}
