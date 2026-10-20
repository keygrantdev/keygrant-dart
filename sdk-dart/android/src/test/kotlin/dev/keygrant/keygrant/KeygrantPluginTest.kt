package dev.keygrant.keygrant

import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.mockito.Mockito
import kotlin.test.Test

internal class KeygrantPluginTest {
    /** A method the plugin does not know is answered as not implemented. */
    @Test
    fun onMethodCall_unknown_isNotImplemented() {
        val plugin = KeygrantPlugin()
        val result: MethodChannel.Result = Mockito.mock(MethodChannel.Result::class.java)
        plugin.onMethodCall(MethodCall("somethingElse", null), result)
        Mockito.verify(result).notImplemented()
    }

    /** Before the engine attaches it, the machine id is an error: no fingerprint this time. */
    @Test
    fun onMethodCall_machineIdUnattached_isAnError() {
        val plugin = KeygrantPlugin()
        val result: MethodChannel.Result = Mockito.mock(MethodChannel.Result::class.java)
        plugin.onMethodCall(MethodCall("machineId", null), result)
        Mockito.verify(result).error("android-id", "the plugin is not attached", null)
    }
}
