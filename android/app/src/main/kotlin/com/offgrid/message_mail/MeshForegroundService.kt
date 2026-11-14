package com.offgrid.message_mail

import android.app.Notification
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.NotificationCompat

class MeshForegroundService : Service() {
    private var wakeLock: PowerManager.WakeLock? = null

    companion object {
        private const val EXTRA_STATUS = "statusText"

        fun start(context: Context, statusText: String = "Off-Grid Mesh Radar Active") {
            val intent = Intent(context, MeshForegroundService::class.java).apply {
                putExtra(EXTRA_STATUS, statusText)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun updateStatus(context: Context, statusText: String) {
            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            val pi = buildLaunchIntent(context)
            val notif = buildNotification(context, statusText, pi)
            nm.notify(MeshPlatformBridge.NOTIF_SERVICE_ID, notif)
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, MeshForegroundService::class.java))
        }

        private fun buildLaunchIntent(context: Context): PendingIntent {
            val launchIntent = Intent(context, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
            }
            return PendingIntent.getActivity(
                context,
                1001,
                launchIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
        }

        private fun buildNotification(
            context: Context,
            statusText: String,
            pi: PendingIntent
        ): Notification {
            return NotificationCompat.Builder(context, MeshPlatformBridge.CHANNEL_SERVICE_ID)
                .setSmallIcon(R.mipmap.ic_launcher)
                .setContentTitle("Message Mail • Off-Grid Mesh")
                .setContentText(statusText)
                .setOngoing(true)
                .setSilent(true)
                .setPriority(NotificationCompat.PRIORITY_LOW)
                .setContentIntent(pi)
                .build()
        }
    }

    override fun onCreate() {
        super.onCreate()
        MeshPlatformBridge.ensureNotificationChannels(this)
        MeshEngineHolder.getOrCreateEngine(applicationContext)

        try {
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "MessageMail::MeshRadarLock").apply {
                setReferenceCounted(false)
                acquire()
            }
        } catch (_: Exception) {}
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val statusText = intent?.getStringExtra(EXTRA_STATUS) ?: "Off-Grid Mesh Radar Active"
        val notif = buildNotification(this, statusText, buildLaunchIntent(this))

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                MeshPlatformBridge.NOTIF_SERVICE_ID,
                notif,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE
            )
        } else {
            startForeground(MeshPlatformBridge.NOTIF_SERVICE_ID, notif)
        }
        return START_STICKY
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        // Keep radar alive even when user swipes app out of Recents
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        try {
            if (wakeLock?.isHeld == true) {
                wakeLock?.release()
            }
        } catch (_: Exception) {}
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}

