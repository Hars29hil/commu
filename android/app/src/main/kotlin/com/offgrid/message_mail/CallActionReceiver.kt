package com.offgrid.message_mail

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

class CallActionReceiver : BroadcastReceiver() {
    companion object {
        const val ACTION_ACCEPT = "com.offgrid.message_mail.ACTION_ACCEPT_CALL"
        const val ACTION_DECLINE = "com.offgrid.message_mail.ACTION_DECLINE_CALL"
    }

    override fun onReceive(context: Context, intent: Intent) {
        val callId = intent.getStringExtra("callId") ?: ""
        val callerId = intent.getStringExtra("callerId") ?: ""
        val callerName = intent.getStringExtra("callerName") ?: callerId

        MeshPlatformBridge.stopIncomingCallAlert()

        when (intent.action) {
            ACTION_ACCEPT -> {
                MeshPlatformBridge.sendEventToDart(
                    mapOf(
                        "type" to "accept_call",
                        "callId" to callId,
                        "callerId" to callerId,
                        "callerName" to callerName
                    )
                )
                val launch = Intent(context, MainActivity::class.java).apply {
                    flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
                    putExtra("action", "accept_call")
                    putExtra("callId", callId)
                    putExtra("callerId", callerId)
                    putExtra("callerName", callerName)
                }
                context.startActivity(launch)
            }
            ACTION_DECLINE -> {
                MeshPlatformBridge.sendEventToDart(
                    mapOf(
                        "type" to "decline_call",
                        "callId" to callId,
                        "callerId" to callerId
                    )
                )
            }
        }
    }
}

