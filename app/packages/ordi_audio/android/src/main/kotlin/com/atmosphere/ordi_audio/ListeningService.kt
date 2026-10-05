package com.atmosphere.ordi_audio

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log

/**
 * Keeps Ordinary able to hear while the app is in the background — Android's
 * counterpart of `UIBackgroundModes: audio` on iOS. Android only lets an app
 * use the microphone from the background inside a foreground service of type
 * "microphone", which must show a notification for as long as it runs.
 *
 * It holds nothing itself; the engine lives in the app process, and this only
 * keeps that process in the foreground. It must be started while the app is
 * on screen (Android 14 refuses otherwise), so [OrdiAudioPlugin] starts it
 * with the engine and keeps it through the engine's own quick restarts.
 */
class ListeningService : Service() {

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val notification = buildNotification()
        try {
            // The microphone type exists from Android 11; Android 10 would
            // reject it, and needs no type to use the microphone there.
            if (Build.VERSION.SDK_INT >= 30) {
                startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
        } catch (error: RuntimeException) {
            // Not allowed right now (started from the background, or the
            // microphone permission is missing). Ordinary still works while
            // the app is open.
            Log.w(OrdiEngine.TAG, "listening service could not start: ${error.message}")
            stopSelf()
        }
        return START_NOT_STICKY
    }

    private fun buildNotification(): Notification {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= 26 && manager.getNotificationChannel(CHANNEL_ID) == null) {
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "Listening", NotificationManager.IMPORTANCE_LOW).apply {
                    description = "Shown while Ordinary can hear you."
                    setShowBadge(false)
                },
            )
        }
        val open = packageManager.getLaunchIntentForPackage(packageName)?.let {
            PendingIntent.getActivity(
                this, 0, it,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        }
        val builder = if (Build.VERSION.SDK_INT >= 26) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setSmallIcon(R.drawable.ic_stat_ordinary)
            .setContentTitle("Ordinary is listening")
            .setContentText("Say \"Hey Ordinary\" to ask anything.")
            .setOngoing(true)
            .setShowWhen(false)
            .setContentIntent(open)
            .build()
    }

    companion object {
        private const val CHANNEL_ID = "ordinary_listening"
        private const val NOTIFICATION_ID = 0x0D1

        fun start(context: Context) {
            val intent = Intent(context, ListeningService::class.java)
            try {
                if (Build.VERSION.SDK_INT >= 26) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            } catch (error: RuntimeException) {
                Log.w(OrdiEngine.TAG, "listening service not started: ${error.message}")
            }
        }

        fun stop(context: Context) {
            try {
                context.stopService(Intent(context, ListeningService::class.java))
            } catch (_: RuntimeException) {
            }
        }
    }
}
