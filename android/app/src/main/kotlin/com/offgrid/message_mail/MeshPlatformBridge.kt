package com.offgrid.message_mail

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.media.MediaPlayer
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.provider.Settings
import androidx.core.app.NotificationCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

object MeshPlatformBridge {
    const val CHANNEL_NAME = "com.offgrid.message_mail/mesh_platform"
    const val CHANNEL_SERVICE_ID = "offgrid_radar_service"
    const val CHANNEL_MSG_ID = "offgrid_messages_v2"
    const val CHANNEL_CALL_ID = "offgrid_calls_v2"

    const val NOTIF_SERVICE_ID = 1001
    const val NOTIF_CALL_ID = 2002

    private var methodChannel: MethodChannel? = null
    private lateinit var appContext: Context

    private var ringtonePlayer: MediaPlayer? = null
    private var ringbackPlayer: MediaPlayer? = null
    private var audioTrack: AudioTrack? = null
    private val audioExecutor = Executors.newSingleThreadExecutor()
    @Volatile private var isAudioTrackRunning = false
    private var pendingEvent: Map<String, Any?>? = null

    fun attach(context: Context, messenger: BinaryMessenger) {
        appContext = context.applicationContext
        ensureNotificationChannels(appContext)

        val channel = MethodChannel(messenger, CHANNEL_NAME)
        methodChannel = channel
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "startMeshService" -> {
                    val username = call.argument<String>("username") ?: ""
                    val statusText = call.argument<String>("statusText") ?: "Off-Grid Radar Active"
                    saveOnboarded(username.isNotEmpty())
                    MeshForegroundService.start(appContext, statusText)
                    result.success(true)
                }
                "updateServiceStatus" -> {
                    val statusText = call.argument<String>("statusText") ?: "Off-Grid Radar Active"
                    MeshForegroundService.updateStatus(appContext, statusText)
                    result.success(true)
                }
                "stopMeshService" -> {
                    saveOnboarded(false)
                    MeshForegroundService.stop(appContext)
                    result.success(true)
                }
                "isIgnoringBatteryOptimizations" -> {
                    val pm = appContext.getSystemService(Context.POWER_SERVICE) as PowerManager
                    result.success(pm.isIgnoringBatteryOptimizations(appContext.packageName))
                }
                "requestIgnoreBatteryOptimizations" -> {
                    try {
                        val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
                            data = Uri.parse("package:${appContext.packageName}")
                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        }
                        appContext.startActivity(intent)
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }
                "showMessageNotification" -> {
                    val chatId = call.argument<String>("chatId") ?: ""
                    val title = call.argument<String>("title") ?: "New Message"
                    val body = call.argument<String>("body") ?: ""
                    val isGroup = call.argument<Boolean>("isGroup") ?: false
                    showMessageNotification(chatId, title, body, isGroup)
                    result.success(true)
                }
                "showIncomingCall" -> {
                    val callId = call.argument<String>("callId") ?: ""
                    val callerId = call.argument<String>("callerId") ?: ""
                    val callerName = call.argument<String>("callerName") ?: callerId
                    showIncomingCall(callId, callerId, callerName)
                    result.success(true)
                }
                "stopIncomingCallAlert" -> {
                    stopIncomingCallAlert()
                    result.success(true)
                }
                "startRingbackTone" -> {
                    startRingbackTone()
                    result.success(true)
                }
                "stopRingbackTone" -> {
                    stopRingbackTone()
                    result.success(true)
                }
                "startCallAudioTrack" -> {
                    val sampleRate = call.argument<Int>("sampleRate") ?: 8000
                    val speakerOn = call.argument<Boolean>("speakerOn") ?: false
                    startCallAudioTrack(sampleRate, speakerOn)
                    result.success(true)
                }
                "writeCallAudioPcm" -> {
                    val pcm = call.argument<ByteArray>("pcm")
                    if (pcm != null && isAudioTrackRunning) {
                        audioExecutor.execute {
                            try {
                                audioTrack?.write(pcm, 0, pcm.size)
                            } catch (_: Exception) {}
                        }
                    }
                    result.success(true)
                }
                "setSpeakerphone" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: false
                    val am = appContext.getSystemService(Context.AUDIO_SERVICE) as AudioManager
                    applySpeakerRouting(am, enabled)
                    result.success(true)
                }
                "stopCallAudioTrack" -> {
                    stopCallAudioTrack()
                    result.success(true)
                }
                "consumePendingEvent" -> {
                    result.success(pendingEvent)
                    pendingEvent = null
                }
                else -> result.notImplemented()
            }
        }
    }

    fun sendEventToDart(event: Map<String, Any?>) {
        val ch = methodChannel
        if (ch != null) {
            android.os.Handler(android.os.Looper.getMainLooper()).post {
                ch.invokeMethod("onNativeEvent", event)
            }
        } else {
            pendingEvent = event
        }
    }

    fun saveOnboarded(onboarded: Boolean) {
        val prefs = appContext.getSharedPreferences("offgrid_prefs", Context.MODE_PRIVATE)
        prefs.edit().putBoolean("onboarded", onboarded).apply()
    }

    fun isOnboarded(context: Context): Boolean {
        val prefs = context.getSharedPreferences("offgrid_prefs", Context.MODE_PRIVATE)
        return prefs.getBoolean("onboarded", false)
    }

    fun ensureNotificationChannels(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

        // 1. Silent ongoing radar service channel
        if (nm.getNotificationChannel(CHANNEL_SERVICE_ID) == null) {
            val svcCh = NotificationChannel(
                CHANNEL_SERVICE_ID,
                "Off-Grid Mesh Radar",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Keeps Bluetooth mesh link active in background"
                setShowBadge(false)
            }
            nm.createNotificationChannel(svcCh)
        }

        // 2. High-priority messages channel with custom unique offgrid_msg_chime
        if (nm.getNotificationChannel(CHANNEL_MSG_ID) == null) {
            val soundUri = Uri.parse("android.resource://${context.packageName}/raw/offgrid_msg_chime")
            val attrs = AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_NOTIFICATION)
                .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                .build()
            val msgCh = NotificationChannel(
                CHANNEL_MSG_ID,
                "Off-Grid Messages",
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "Incoming off-grid text and voice messages"
                setSound(soundUri, attrs)
                enableVibration(true)
                vibrationPattern = longArrayOf(0, 120, 80, 120)
                lockscreenVisibility = Notification.VISIBILITY_PUBLIC
            }
            nm.createNotificationChannel(msgCh)
        }

        // 3. High-priority incoming call channel (ringtone managed explicitly via MediaPlayer)
        if (nm.getNotificationChannel(CHANNEL_CALL_ID) == null) {
            val callCh = NotificationChannel(
                CHANNEL_CALL_ID,
                "Off-Grid Voice Calls",
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "Live incoming off-grid voice calls"
                setSound(null, null)
                enableVibration(false)
                lockscreenVisibility = Notification.VISIBILITY_PUBLIC
            }
            nm.createNotificationChannel(callCh)
        }
    }

    private fun showMessageNotification(chatId: String, title: String, body: String, isGroup: Boolean) {
        val nm = appContext.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val intent = Intent(appContext, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            putExtra("action", "open_chat")
            putExtra("chatId", chatId)
            putExtra("isGroup", isGroup)
        }
        val pi = PendingIntent.getActivity(
            appContext,
            chatId.hashCode(),
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val soundUri = Uri.parse("android.resource://${appContext.packageName}/raw/offgrid_msg_chime")
        val notif = NotificationCompat.Builder(appContext, CHANNEL_MSG_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setCategory(NotificationCompat.CATEGORY_MESSAGE)
            .setAutoCancel(true)
            .setSound(soundUri)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setContentIntent(pi)
            .build()

        nm.notify(3000 + (chatId.hashCode() and 0x0FFF), notif)
    }

    fun showIncomingCall(callId: String, callerId: String, callerName: String) {
        val nm = appContext.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

        val fullScreenIntent = Intent(appContext, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            putExtra("action", "incoming_call")
            putExtra("callId", callId)
            putExtra("callerId", callerId)
            putExtra("callerName", callerName)
        }
        val fullScreenPi = PendingIntent.getActivity(
            appContext,
            9001,
            fullScreenIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val acceptIntent = Intent(appContext, CallActionReceiver::class.java).apply {
            action = CallActionReceiver.ACTION_ACCEPT
            putExtra("callId", callId)
            putExtra("callerId", callerId)
            putExtra("callerName", callerName)
        }
        val acceptPi = PendingIntent.getBroadcast(
            appContext,
            9002,
            acceptIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val declineIntent = Intent(appContext, CallActionReceiver::class.java).apply {
            action = CallActionReceiver.ACTION_DECLINE
            putExtra("callId", callId)
            putExtra("callerId", callerId)
        }
        val declinePi = PendingIntent.getBroadcast(
            appContext,
            9003,
            declineIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val notif = NotificationCompat.Builder(appContext, CHANNEL_CALL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("Off-Grid Mesh Call")
            .setContentText("$callerName is calling...")
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setOngoing(true)
            .setAutoCancel(false)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setFullScreenIntent(fullScreenPi, true)
            .setContentIntent(fullScreenPi)
            .addAction(android.R.drawable.ic_menu_call, "Answer", acceptPi)
            .addAction(android.R.drawable.ic_menu_close_clear_cancel, "Decline", declinePi)
            .build()

        nm.notify(NOTIF_CALL_ID, notif)
        startUniqueRingtone()
    }

    fun stopIncomingCallAlert() {
        val nm = appContext.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.cancel(NOTIF_CALL_ID)
        stopUniqueRingtone()
    }

    private fun startUniqueRingtone() {
        stopUniqueRingtone()
        try {
            val uri = Uri.parse("android.resource://${appContext.packageName}/raw/offgrid_ringtone")
            val mp = MediaPlayer().apply {
                setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .build()
                )
                setDataSource(appContext, uri)
                isLooping = true
                prepare()
                start()
            }
            ringtonePlayer = mp
        } catch (_: Exception) {}

        try {
            val pattern = longArrayOf(0, 400, 200, 400, 800)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                val vm = appContext.getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as VibratorManager
                vm.defaultVibrator.vibrate(VibrationEffect.createWaveform(pattern, 0))
            } else {
                @Suppress("DEPRECATION")
                val v = appContext.getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    v.vibrate(VibrationEffect.createWaveform(pattern, 0))
                } else {
                    @Suppress("DEPRECATION")
                    v.vibrate(pattern, 0)
                }
            }
        } catch (_: Exception) {}
    }

    private fun stopUniqueRingtone() {
        try {
            ringtonePlayer?.stop()
            ringtonePlayer?.release()
        } catch (_: Exception) {}
        ringtonePlayer = null

        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                val vm = appContext.getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as VibratorManager
                vm.defaultVibrator.cancel()
            } else {
                @Suppress("DEPRECATION")
                val v = appContext.getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
                v.cancel()
            }
        } catch (_: Exception) {}
    }

    private var ringbackHandler: android.os.Handler? = null
    private var ringbackRunnable: Runnable? = null

    private fun startRingbackTone() {
        stopRingbackTone()
        val handler = android.os.Handler(android.os.Looper.getMainLooper())
        ringbackHandler = handler
        val playOnce = object : Runnable {
            override fun run() {
                if (ringbackHandler == null) return
                try {
                    ringbackPlayer?.release()
                    val uri = Uri.parse("android.resource://${appContext.packageName}/raw/offgrid_msg_chime")
                    ringbackPlayer = MediaPlayer().apply {
                        setAudioAttributes(
                            AudioAttributes.Builder()
                                .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                                .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                                .build()
                        )
                        setDataSource(appContext, uri)
                        setVolume(0.35f, 0.35f)
                        isLooping = false
                        prepare()
                        start()
                    }
                } catch (_: Exception) {}
                handler.postDelayed(this, 2400L)
            }
        }
        ringbackRunnable = playOnce
        handler.post(playOnce)
    }

    private fun stopRingbackTone() {
        ringbackRunnable?.let { ringbackHandler?.removeCallbacks(it) }
        ringbackRunnable = null
        ringbackHandler = null
        try {
            ringbackPlayer?.stop()
            ringbackPlayer?.release()
        } catch (_: Exception) {}
        ringbackPlayer = null
    }

    private fun startCallAudioTrack(sampleRate: Int, speakerOn: Boolean) {
        stopCallAudioTrack()
        try {
            val am = appContext.getSystemService(Context.AUDIO_SERVICE) as AudioManager
            am.mode = AudioManager.MODE_IN_COMMUNICATION
            applySpeakerRouting(am, speakerOn)

            val minBuf = AudioTrack.getMinBufferSize(
                sampleRate,
                AudioFormat.CHANNEL_OUT_MONO,
                AudioFormat.ENCODING_PCM_16BIT
            ).coerceAtLeast(1280)

            val track = AudioTrack.Builder()
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                        .build()
                )
                .setAudioFormat(
                    AudioFormat.Builder()
                        .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                        .setSampleRate(sampleRate)
                        .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                        .build()
                )
                .setBufferSizeInBytes(minBuf * 2)
                .setTransferMode(AudioTrack.MODE_STREAM)
                .build()

            track.play()
            audioTrack = track
            isAudioTrackRunning = true
        } catch (_: Exception) {
            isAudioTrackRunning = false
        }
    }

    private fun stopCallAudioTrack() {
        isAudioTrackRunning = false
        try {
            audioTrack?.pause()
            audioTrack?.flush()
            audioTrack?.stop()
            audioTrack?.release()
        } catch (_: Exception) {}
        audioTrack = null

        try {
            val am = appContext.getSystemService(Context.AUDIO_SERVICE) as AudioManager
            applySpeakerRouting(am, false)
            am.mode = AudioManager.MODE_NORMAL
        } catch (_: Exception) {}
    }

    @Suppress("DEPRECATION")
    private fun applySpeakerRouting(am: AudioManager, enabled: Boolean) {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                if (enabled) {
                    val speakerDevice = am.availableCommunicationDevices.firstOrNull {
                        it.type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER
                    }
                    if (speakerDevice != null) {
                        am.setCommunicationDevice(speakerDevice)
                    } else {
                        am.isSpeakerphoneOn = true
                    }
                } else {
                    am.clearCommunicationDevice()
                    am.isSpeakerphoneOn = false
                }
            } else {
                am.isSpeakerphoneOn = enabled
            }
        } catch (_: Exception) {
            try {
                am.isSpeakerphoneOn = enabled
            } catch (_: Exception) {}
        }
    }
}
