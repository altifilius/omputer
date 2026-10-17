package dev.omputer.omputer

import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager

class ConnectionService : Service() {
    private var wakeLock: PowerManager.WakeLock? = null
    override fun onCreate() {
        super.onCreate()
        LocalConnection.initialize(applicationContext)
        val notification = LocalNotifications.connection(this)
        if (Build.VERSION.SDK_INT >= 29) startForeground(LocalNotifications.CONNECTION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
        else startForeground(LocalNotifications.CONNECTION_ID, notification)
        LocalConnection.serviceRunning(true)
        LocalConnection.onConnectionChanged = {
            if (LocalConnection.isBackground()) {
                getSystemService(android.app.NotificationManager::class.java).notify(LocalNotifications.CONNECTION_ID, LocalNotifications.connection(this))
                updateWakeLock()
            }
        }
    }
    private fun updateWakeLock() {
        val power = getSystemService(PowerManager::class.java)
        if (LocalConnection.isBackground() && power.isIgnoringBatteryOptimizations(packageName)) {
            if (wakeLock?.isHeld != true) {
                wakeLock = power.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "Omputer:directConnection").apply {
                    setReferenceCounted(false)
                    acquire(10 * 60 * 1000L)
                }
            }
        } else releaseWakeLock()
    }
    private val handler = android.os.Handler(android.os.Looper.getMainLooper())
    private val renewal = object : Runnable {
        override fun run() {
            updateWakeLock()
            if (LocalConnection.isBackground()) handler.postDelayed(this, 5 * 60 * 1000L)
        }
    }
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (!LocalConnection.isBackground() || LocalConnection.connection()["paired"] != true) {
            stopSelf(); return START_NOT_STICKY
        }
        LocalConnection.connect()
        handler.removeCallbacks(renewal)
        renewal.run()
        return START_STICKY
    }
    private fun releaseWakeLock() { wakeLock?.let { if (it.isHeld) it.release() }; wakeLock = null }
    override fun onDestroy() {
        handler.removeCallbacks(renewal)
        releaseWakeLock()
        LocalConnection.onConnectionChanged = null
        LocalConnection.serviceRunning(false)
        if (!LocalConnection.isBackground() && !LocalConnection.activityVisible) LocalConnection.disconnect()
        super.onDestroy()
    }
    override fun onBind(intent: Intent?): IBinder? = null
}
