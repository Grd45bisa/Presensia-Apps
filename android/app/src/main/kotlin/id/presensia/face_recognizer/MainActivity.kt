package id.presensia.face_recognizer

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val channel =
        "id.presensia.face_recognizer/notifications"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Pastikan notification channels selalu ada saat app pertama jalan.
        ReminderScheduler.ensureChannels(applicationContext)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "saveSnapshot" -> {
                        try {
                            val enabled = call.argument<Boolean>("enabled")
                                ?: false
                            val checkIn =
                                call.argument<String>("check_in_time")
                            val checkOut =
                                call.argument<String>("check_out_time")
                            val tracker =
                                call.argument<String>("tracker_time")
                            val offDays =
                                call.argument<List<Int>>("off_days")
                                    ?: listOf(6, 7)
                            ReminderScheduler.saveSnapshot(
                                applicationContext,
                                enabled,
                                checkIn,
                                checkOut,
                                tracker,
                                offDays,
                            )
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("SNAPSHOT_ERROR", e.message, null)
                        }
                    }
                    "rearmReminders" -> {
                        try {
                            ReminderScheduler.armAll(applicationContext)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("REARM_ERROR", e.message, null)
                        }
                    }
                    "isIgnoringBatteryOpt" -> {
                        result.success(isIgnoringBatteryOptimizations())
                    }
                    "requestIgnoreBatteryOpt" -> {
                        try {
                            requestIgnoreBatteryOptimizations()
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("BATTERY_OPT_ERROR", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun isIgnoringBatteryOptimizations(): Boolean {
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        return pm.isIgnoringBatteryOptimizations(packageName)
    }

    private fun requestIgnoreBatteryOptimizations() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return
        val intent = Intent().apply {
            action = Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS
            data = Uri.parse("package:$packageName")
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        startActivity(intent)
    }
}
