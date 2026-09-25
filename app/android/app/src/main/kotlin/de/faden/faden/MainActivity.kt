package de.faden.faden

import android.view.WindowManager
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// M6 (docs/ARCHITEKTUR.md section 9): FlutterFragmentActivity instead of
// FlutterActivity -- the `health` package's Android side requests Health
// Connect permissions via registerForActivityResult, which requires a
// FragmentActivity (see its README's Android setup section).
class MainActivity : FlutterFragmentActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Decision E85 (lib/signals/screen_awake.dart): while the Faden
        // screen is open the display does not lock itself.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "de.faden.app/screen")
            .setMethodCallHandler { call, result ->
                if (call.method != "keepOn") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val on = call.argument<Boolean>("on") ?: false
                if (on) {
                    window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                } else {
                    window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                }
                result.success(null)
            }
    }
}
