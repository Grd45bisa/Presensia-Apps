package id.presensia.face_recognizer

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Dipicu setelah HP reboot, setelah package di-update, atau saat waktu/
 * zona waktu sistem berubah. Flutter engine belum berjalan pada saat ini,
 * jadi re-arm alarm presensi dilakukan native via [ReminderScheduler].
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED,
            "android.intent.action.QUICKBOOT_POWERON",
            "com.htc.intent.action.QUICKBOOT_POWERON",
            Intent.ACTION_MY_PACKAGE_REPLACED,
            Intent.ACTION_TIME_CHANGED,
            Intent.ACTION_TIMEZONE_CHANGED -> {
                // Re-arm all scheduled reminders from the persisted snapshot.
                ReminderScheduler.ensureChannels(context.applicationContext)
                ReminderScheduler.armAll(context.applicationContext)
            }
        }
    }
}
