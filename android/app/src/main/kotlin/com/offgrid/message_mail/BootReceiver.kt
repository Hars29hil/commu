package com.offgrid.message_mail

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == Intent.ACTION_BOOT_COMPLETED ||
            intent.action == Intent.ACTION_MY_PACKAGE_REPLACED) {
            if (MeshPlatformBridge.isOnboarded(context)) {
                try {
                    MeshForegroundService.start(context, "Off-Grid Radar Active")
                } catch (_: Exception) {}
            }
        }
    }
}

