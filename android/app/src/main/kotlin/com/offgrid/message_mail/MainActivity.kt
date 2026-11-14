package com.offgrid.message_mail

import android.app.KeyguardManager
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    override fun provideFlutterEngine(context: Context): FlutterEngine {
        return MeshEngineHolder.getOrCreateEngine(context.applicationContext)
    }

    override fun shouldDestroyEngineWithHost(): Boolean {
        // Keep shared FlutterEngine alive in MeshForegroundService when Activity closes
        return false
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        handleCallWindowFlags(intent)
        forwardIntentToDart(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleCallWindowFlags(intent)
        forwardIntentToDart(intent)
    }

    private fun handleCallWindowFlags(intent: Intent?) {
        val action = intent?.getStringExtra("action") ?: return
        if (action == "incoming_call" || action == "accept_call") {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
                setShowWhenLocked(true)
                setTurnScreenOn(true)
                val km = getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager
                km.requestDismissKeyguard(this, null)
            } else {
                @Suppress("DEPRECATION")
                window.addFlags(
                    WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                        WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON or
                        WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON
                )
            }
        }
    }

    private fun forwardIntentToDart(intent: Intent?) {
        val action = intent?.getStringExtra("action") ?: return
        when (action) {
            "open_chat" -> {
                val chatId = intent.getStringExtra("chatId") ?: ""
                val isGroup = intent.getBooleanExtra("isGroup", false)
                MeshPlatformBridge.sendEventToDart(
                    mapOf(
                        "type" to "open_chat",
                        "chatId" to chatId,
                        "isGroup" to isGroup
                    )
                )
            }
            "incoming_call" -> {
                MeshPlatformBridge.sendEventToDart(
                    mapOf(
                        "type" to "open_incoming_call",
                        "callId" to (intent.getStringExtra("callId") ?: ""),
                        "callerId" to (intent.getStringExtra("callerId") ?: ""),
                        "callerName" to (intent.getStringExtra("callerName") ?: "")
                    )
                )
            }
            "accept_call" -> {
                MeshPlatformBridge.sendEventToDart(
                    mapOf(
                        "type" to "accept_call",
                        "callId" to (intent.getStringExtra("callId") ?: ""),
                        "callerId" to (intent.getStringExtra("callerId") ?: ""),
                        "callerName" to (intent.getStringExtra("callerName") ?: "")
                    )
                )
            }
        }
    }
}
