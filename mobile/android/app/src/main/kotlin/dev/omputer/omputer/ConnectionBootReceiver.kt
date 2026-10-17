package dev.omputer.omputer

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

class ConnectionBootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action !in setOf(Intent.ACTION_BOOT_COMPLETED, Intent.ACTION_MY_PACKAGE_REPLACED)) return
        LocalConnection.initialize(context.applicationContext)
        if (LocalConnection.isBackground() && LocalConnection.connection()["paired"] == true) LocalConnection.startBackgroundIfAllowed()
    }
}
