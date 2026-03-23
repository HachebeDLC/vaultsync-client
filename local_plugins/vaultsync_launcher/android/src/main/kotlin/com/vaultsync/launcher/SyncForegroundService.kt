package com.vaultsync.launcher

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat

class SyncForegroundService : Service() {
    companion object {
        const val CHANNEL_ID = "vaultsync_background_channel"
        const val NOTIFICATION_ID = 4040
    }

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        startForeground(NOTIFICATION_ID, createNotification())
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // Keep the service running
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? {
        return null
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "VaultSync Background Sync",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Keeps VaultSync running to prevent connection drops"
            }
            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            manager.createNotificationChannel(channel)
        }
    }

    private fun createNotification(): Notification {
        // Try to get launcher icon
        val iconResId = resources.getIdentifier("launcher_icon", "mipmap", packageName)
        val validIcon = if (iconResId != 0) iconResId else android.R.drawable.ic_popup_sync

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("VaultSync")
            .setContentText("Synchronization in progress...")
            .setSmallIcon(validIcon)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setOngoing(true)
            .build()
    }
}
