package id.presensia.face_recognizer

import android.app.AlarmManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationCompat
import java.util.Calendar

/**
 * Native helper yang menjadwalkan alarm presensi via AlarmManager dan
 * menampilkan notifikasi saat alarm terpicu. Dipakai oleh:
 *
 *  - [BootReceiver]   : re-arm alarm setelah HP reboot (Flutter belum jalan).
 *  - [MainActivity]   : menerima snapshot jam pengingat dari Flutter lewat
 *                       MethodChannel, dan memproses broadcast alarm.
 *
 * Snapshot jam pengingat disimpan di SharedPreferences agar dapat dibaca
 * BootReceiver tanpa menyalakan engine Flutter.
 */
object ReminderScheduler {

    private const val PREFS = "presensia_reminder_prefs"
    private const val KEY_ENABLED = "enabled"
    private const val KEY_CHECK_IN = "check_in_time"
    private const val KEY_CHECK_OUT = "check_out_time"
    private const val KEY_TRACKER = "tracker_time"
    private const val KEY_OFF_DAYS = "off_days"

    const val CHANNEL_ATTENDANCE = "attendance"
    const val CHANNEL_TRACKER = "tracker"
    const val CHANNEL_REMINDERS = "reminders"
    const val CHANNEL_SYSTEM = "system"

    // Notification request codes, terpisah dari notification ID (boleh sama).
    private const val RC_CHECK_IN = 1000
    private const val RC_TRACKER = 2000
    private const val RC_CHECK_OUT = 3000

    // ── Notification channels ───────────────────────────────────────────────

    fun ensureChannels(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE)
            as NotificationManager

        fun create(id: String, name: String, desc: String, importance: Int) {
            if (nm.getNotificationChannel(id) == null) {
                val ch = NotificationChannel(id, name, importance).apply {
                    description = desc
                }
                nm.createNotificationChannel(ch)
            }
        }
        create(CHANNEL_ATTENDANCE, "Absensi",
            "Pengingat check-in dan check-out harian",
            NotificationManager.IMPORTANCE_HIGH)
        create(CHANNEL_TRACKER, "Tracker",
            "Pengingat pencatatan aktivitas harian",
            NotificationManager.IMPORTANCE_DEFAULT)
        create(CHANNEL_REMINDERS, "Pengingat",
            "Notifikasi pengingat acara kalender",
            NotificationManager.IMPORTANCE_HIGH)
        create(CHANNEL_SYSTEM, "Sistem",
            "Notifikasi umum aplikasi",
            NotificationManager.IMPORTANCE_DEFAULT)
    }

    // ── Snapshot persistence ────────────────────────────────────────────────

    fun saveSnapshot(
        context: Context,
        enabled: Boolean,
        checkIn: String?,
        checkOut: String?,
        tracker: String?,
        offDays: List<Int>,
    ) {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        prefs.edit()
            .putBoolean(KEY_ENABLED, enabled)
            .putString(KEY_CHECK_IN, checkIn)
            .putString(KEY_CHECK_OUT, checkOut)
            .putString(KEY_TRACKER, tracker)
            .putString(KEY_OFF_DAYS, offDays.joinToString(","))
            .apply()
        if (enabled) armAll(context) else cancelAll(context)
    }

    private fun readOffDays(context: Context): Set<Int> {
        val raw = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getString(KEY_OFF_DAYS, "6,7") ?: "6,7"
        return raw.split(",").mapNotNull { it.trim().toIntOrNull() }.toSet()
    }

    // ── Alarm scheduling (next 7 days) ──────────────────────────────────────

    /**
     * Re-arm ulang seluruh alarm presensi untuk 7 hari ke depan berdasarkan
     * snapshot yang tersimpan. Aman dipanggil dari BootReceiver.
     */
    fun armAll(context: Context) {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        if (!prefs.getBoolean(KEY_ENABLED, false)) return

        ensureChannels(context.applicationContext)
        val offDays = readOffDays(context)
        val now = Calendar.getInstance()

        val checkIn = parseTime(prefs.getString(KEY_CHECK_IN, "08:00"))
        val checkOut = parseTime(prefs.getString(KEY_CHECK_OUT, "17:00"))
        val tracker = parseTime(prefs.getString(KEY_TRACKER, "13:00"))

        for (offset in 0 until 7) {
            val day = (now.clone() as Calendar).apply {
                add(Calendar.DAY_OF_YEAR, offset)
                // Reset to midnight of that day first.
                val y = get(Calendar.YEAR)
                val m = get(Calendar.MONTH)
                val d = get(Calendar.DAY_OF_MONTH)
                clear()
                set(Calendar.YEAR, y)
                set(Calendar.MONTH, m)
                set(Calendar.DAY_OF_MONTH, d)
            }
            if (offDays.contains(day.get(Calendar.DAY_OF_WEEK))) continue

            scheduleAt(context, day, checkIn, RC_CHECK_IN,
                CHANNEL_ATTENDANCE, "Jangan lupa check-in",
                "Mulai hari kerja dengan presensi wajah.")
            scheduleAt(context, day, tracker, RC_TRACKER,
                CHANNEL_TRACKER, "Tracker aktivitas belum diisi?",
                "Catat progres kerja hari ini supaya laporan tetap rapi.")
            scheduleAt(context, day, checkOut, RC_CHECK_OUT,
                CHANNEL_ATTENDANCE, "Jangan lupa check-out",
                "Selesaikan presensi saat pekerjaan hari ini sudah berakhir.")
        }
    }

    private fun scheduleAt(
        context: Context,
        day: Calendar,
        time: Pair<Int, Int>,
        requestCodeBase: Int,
        channel: String,
        title: String,
        body: String,
    ) {
        val trigger = (day.clone() as Calendar).apply {
            set(Calendar.HOUR_OF_DAY, time.first)
            set(Calendar.MINUTE, time.second)
            set(Calendar.SECOND, 0)
            set(Calendar.MILLISECOND, 0)
        }
        if (trigger.timeInMillis <= System.currentTimeMillis()) return

        val intent = Intent(context, ReminderReceiver::class.java).apply {
            putExtra("channel", channel)
            putExtra("title", title)
            putExtra("body", body)
            putExtra("notif_id", requestCodeBase + dayIndex(day))
        }
        val pi = PendingIntent.getBroadcast(
            context,
            requestCodeBase + dayIndex(day),
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        try {
            am.setExactAndAllowWhileIdle(
                AlarmManager.RTC_WAKEUP, trigger.timeInMillis, pi)
        } catch (_: SecurityException) {
            // Fallback: exact alarm not permitted (Android 14+ restrictions).
            am.setAndAllowWhileIdle(
                AlarmManager.RTC_WAKEUP, trigger.timeInMillis, pi)
        }
    }

    private fun cancelAll(context: Context) {
        val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val now = Calendar.getInstance()
        for (offset in -1..8) {
            val day = (now.clone() as Calendar).apply {
                add(Calendar.DAY_OF_YEAR, offset)
            }
            for (rc in listOf(RC_CHECK_IN, RC_TRACKER, RC_CHECK_OUT)) {
                val intent = Intent(context, ReminderReceiver::class.java)
                val pi = PendingIntent.getBroadcast(
                    context,
                    rc + dayIndex(day),
                    intent,
                    PendingIntent.FLAG_NO_CREATE or PendingIntent.FLAG_IMMUTABLE,
                )
                if (pi != null) {
                    am.cancel(pi)
                    pi.cancel()
                }
            }
        }
    }

    /** Index stabil per hari untuk request code (supaya unik antar-hari). */
    private fun dayIndex(day: Calendar): Int {
        val epoch = day.timeInMillis / (24L * 60L * 60L * 1000L)
        return (epoch % 100_000L).toInt()
    }

    private fun parseTime(value: String?): Pair<Int, Int> {
        val parts = (value ?: "08:00").split(":")
        val h = parts.getOrNull(0)?.toIntOrNull() ?: 8
        val m = parts.getOrNull(1)?.toIntOrNull() ?: 0
        return h.coerceIn(0, 23) to m.coerceIn(0, 59)
    }

    // ── Notification display (called by ReminderReceiver) ───────────────────

    fun showAlarmNotification(
        context: Context,
        notifId: Int,
        channel: String,
        title: String,
        body: String,
    ) {
        ensureChannels(context.applicationContext)
        val notif = NotificationCompat.Builder(context, channel)
            .setSmallIcon(context.applicationInfo.icon)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setPriority(if (channel == CHANNEL_TRACKER)
                NotificationCompat.PRIORITY_DEFAULT
            else NotificationCompat.PRIORITY_HIGH)
            .setAutoCancel(true)
            .build()
        val service = context.getSystemService(Context.NOTIFICATION_SERVICE)
        (service as NotificationManager).notify(notifId, notif)
    }
}
