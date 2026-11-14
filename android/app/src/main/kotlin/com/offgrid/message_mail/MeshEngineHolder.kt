package com.offgrid.message_mail

import android.content.Context
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor

object MeshEngineHolder {
    const val ENGINE_ID = "mesh_engine"

    @Synchronized
    fun getOrCreateEngine(context: Context): FlutterEngine {
        val cache = FlutterEngineCache.getInstance()
        val existing = cache.get(ENGINE_ID)
        if (existing != null) {
            return existing
        }

        val appContext = context.applicationContext
        val engine = FlutterEngine(appContext)
        MeshPlatformBridge.attach(appContext, engine.dartExecutor.binaryMessenger)
        engine.dartExecutor.executeDartEntrypoint(
            DartExecutor.DartEntrypoint.createDefault()
        )
        cache.put(ENGINE_ID, engine)
        return engine
    }
}

