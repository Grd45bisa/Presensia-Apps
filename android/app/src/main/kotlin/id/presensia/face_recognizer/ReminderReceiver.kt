package id.presensia.face_recognizer

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Dipicu AlarmManager ketika jam pengingat tiba — bahkan jika Flutter
 * engine sudah dimatikan oleh OS. Hanya menampilkan notifikasi sistem.
 */
class ReminderReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val notifId = intent.getIntExtra("notif_id", 0)
        val channel = intent.getStringExtra("channel")
            ?: ReminderScheduler.CHANNEL_SYSTEM
        val title = intent.getStringExtra("title") ?: "Presensia"
        val body = intent.getStringExtra("body") ?: ""

        ReminderScheduler.showAlarmNotification(
            context.applicationContext,
            notifId,
            channel,
            title,
            body,
        )
    }
}
