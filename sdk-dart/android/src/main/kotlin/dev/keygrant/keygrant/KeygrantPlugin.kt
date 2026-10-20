package dev.keygrant.keygrant

import android.annotation.SuppressLint
import android.content.Context
import android.provider.Settings
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result

/**
 * The KeyGrant plugin's Android side (the SDK contract, section 4.1), over the channel
 * `dev.keygrant/keygrant`:
 *
 * - `machineId`: `Settings.Secure.ANDROID_ID` as Android gives it (one per app signing key, user
 *   and device since Android 8; it survives a reinstall and changes with a factory reset), or null
 *   when there is none. The Dart side lower-cases it, and keeps an install id of its own for an
 *   empty one or the value some old builds share. A read that throws answers an error: no
 *   fingerprint this time.
 *
 * Nothing an app writes outlives it on Android, so there is no trial stash here.
 */
class KeygrantPlugin : FlutterPlugin, MethodCallHandler {
    private var channel: MethodChannel? = null
    private var context: Context? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL).also { it.setMethodCallHandler(this) }
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "machineId" -> {
                val attached = context
                if (attached == null) {
                    result.error("android-id", "the plugin is not attached", null)
                    return
                }
                try {
                    // Null is the settings provider giving no answer this time (not ready, a restricted
                    // profile): an error, so the SDK reads it as "cannot tell" and asks again, never as a
                    // device with no id, whose install id would be another device to its seat.
                    val id = androidId(attached)
                    if (id == null) result.error("android-id", "ANDROID_ID gave no answer", null) else result.success(id)
                } catch (e: Exception) {
                    result.error("android-id", e.message, null)
                }
            }
            else -> result.notImplemented()
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        context = null
    }

    companion object {
        const val CHANNEL = "dev.keygrant/keygrant"

        /** `ANDROID_ID`, read as an app may read it: the id of this app's signing key, user and device. */
        @SuppressLint("HardwareIds")
        fun androidId(context: Context): String? =
            Settings.Secure.getString(context.contentResolver, Settings.Secure.ANDROID_ID)
    }
}
