package com.example.video

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.Context
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import io.flutter.plugin.common.MethodChannel

/** Only aggregate counts enter this service. No film titles or source addresses. */
class SubtitleProgressService : Service() {
    companion object {
        const val CHANNEL = "subtitle_progress_v1"
        const val NOTIFICATION = 4217
        var bridge: MethodChannel? = null
        var running = false

        private fun ensureChannel(context: Context) {
            if (Build.VERSION.SDK_INT >= 26) {
                val channel = NotificationChannel(CHANNEL, "Tiến trình Sub", NotificationManager.IMPORTANCE_LOW)
                channel.setShowBadge(false)
                channel.lockscreenVisibility = Notification.VISIBILITY_PUBLIC
                context.getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
            }
        }

        fun showSummary(context: Context, intent: Intent) {
            ensureChannel(context)
            val manager = context.getSystemService(NotificationManager::class.java)
            if (intent.getIntExtra("total", 0) <= 0) manager.cancel(NOTIFICATION)
            else manager.notify(NOTIFICATION, notification(context, intent, false))
        }

        private fun notification(context: Context, intent: Intent, active: Boolean): Notification {
            val total = intent.getIntExtra("total", 0).coerceAtLeast(0)
            val completed = intent.getIntExtra("completed", 0).coerceIn(0, total)
            val progress = intent.getIntExtra("progress", 0).coerceIn(0, 10000)
            val launch = Intent(context, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
                .putExtra("open_subtitles", true)
            val pending = PendingIntent.getActivity(context, 0, launch,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(context, CHANNEL)
                else @Suppress("DEPRECATION") Notification.Builder(context)
            return builder.setSmallIcon(R.drawable.ic_subtitle_notification)
                .setContentTitle("Sub: $completed/$total hoàn thành")
                .setContentIntent(pending).setVisibility(Notification.VISIBILITY_PUBLIC)
                .setOnlyAlertOnce(true).setShowWhen(false).setOngoing(active).setAutoCancel(!active)
                .setProgress(10000, progress, false).build()
        }

    }

    private var wakeLock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        ensureChannel(this)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent == null) { stopSelf(); return START_NOT_STICKY }
        val active = intent.getBooleanExtra("active", false) && intent.getIntExtra("total", 0) > 0
        val notification = notification(this, intent, active)
        if (active) {
            if (Build.VERSION.SDK_INT >= 29) {
                val type = if (Build.VERSION.SDK_INT >= 35) ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROCESSING
                    else ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
                startForeground(NOTIFICATION, notification, type)
            } else {
                startForeground(NOTIFICATION, notification)
            }
            running = true
            if (wakeLock == null) {
                wakeLock = (getSystemService(POWER_SERVICE) as PowerManager)
                    .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "video:subtitles")
                    .apply { acquire(6 * 60 * 60 * 1000L) }
            }
        } else {
            stopForeground(STOP_FOREGROUND_DETACH)
            showSummary(this, intent)
            stopSelf()
        }
        return START_NOT_STICKY
    }

    override fun onTimeout(startId: Int, fgsType: Int) {
        bridge?.invokeMethod("cancel", null)
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    override fun onDestroy() {
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        running = false
        super.onDestroy()
    }
}
