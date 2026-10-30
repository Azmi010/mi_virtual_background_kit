package com.azmi010.mi_virtual_background_kit

import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.mockito.Mockito
import kotlin.test.Test

/*
 * This demonstrates a simple unit test of the Kotlin portion of this plugin's implementation.
 *
 * Once you have built the plugin's example app, you can run these tests from the command
 * line by running `./gradlew testDebugUnitTest` in the `example/android/` directory, or
 * you can run them directly from IDEs that support JUnit such as Android Studio.
 */

internal class MiVirtualBackgroundKitPluginTest {

    private fun createTestBitmap(): android.graphics.Bitmap {
        val unsafeClass = Class.forName("sun.misc.Unsafe")
        val field = unsafeClass.getDeclaredField("theUnsafe")
        field.isAccessible = true
        val unsafe = field.get(null)
        val allocateMethod = unsafeClass.getMethod("allocateInstance", Class::class.java)
        return allocateMethod.invoke(unsafe, android.graphics.Bitmap::class.java) as android.graphics.Bitmap
    }

    @Test
    fun onMethodCall_getPlatformVersion_returnsExpectedValue() {
        val plugin = MiVirtualBackgroundKitPlugin()

        val call = MethodCall("getPlatformVersion", null)
        val mockResult: MethodChannel.Result = Mockito.mock(MethodChannel.Result::class.java)
        plugin.onMethodCall(call, mockResult)

        Mockito.verify(mockResult).success("Android " + android.os.Build.VERSION.RELEASE)
    }

    @Test
    fun onMethodCall_attachWithoutTrackId_errorsInvalidTrack() {
        val plugin = MiVirtualBackgroundKitPlugin()

        val call = MethodCall("attach", null)
        val mockResult: MethodChannel.Result = Mockito.mock(MethodChannel.Result::class.java)
        plugin.onMethodCall(call, mockResult)

        Mockito.verify(mockResult).error(
            Mockito.eq("invalidTrack"),
            Mockito.any(),
            Mockito.isNull(),
        )
    }

    @Test
    fun onMethodCall_detachWithoutAttach_isIdempotentSuccess() {
        val plugin = MiVirtualBackgroundKitPlugin()

        val call = MethodCall("detach", null)
        val mockResult: MethodChannel.Result = Mockito.mock(MethodChannel.Result::class.java)
        plugin.onMethodCall(call, mockResult)

        Mockito.verify(mockResult).success(null)
    }

    @Test
    fun onMethodCall_setEffectNone_succeeds() {
        val plugin = MiVirtualBackgroundKitPlugin()

        val call = MethodCall("setEffect", mapOf("type" to "none"))
        val mockResult: MethodChannel.Result = Mockito.mock(MethodChannel.Result::class.java)
        plugin.onMethodCall(call, mockResult)

        Mockito.verify(mockResult).success(null)
    }

    @Test
    fun onMethodCall_setEffectBlur_succeeds() {
        val plugin = MiVirtualBackgroundKitPlugin()

        val call = MethodCall("setEffect", mapOf("type" to "blur", "radius" to 15.0))
        val mockResult: MethodChannel.Result = Mockito.mock(MethodChannel.Result::class.java)
        plugin.onMethodCall(call, mockResult)

        Mockito.verify(mockResult).success(null)
    }

    @Test
    fun onMethodCall_setEffectColor_succeeds() {
        val plugin = MiVirtualBackgroundKitPlugin()

        val call = MethodCall("setEffect", mapOf("type" to "color", "color" to 0xFF123456))
        val mockResult: MethodChannel.Result = Mockito.mock(MethodChannel.Result::class.java)
        plugin.onMethodCall(call, mockResult)

        Mockito.verify(mockResult).success(null)
    }

    @Test
    fun onMethodCall_setEffectImage_invalidData_errorsInvalidImage() {
        val plugin = MiVirtualBackgroundKitPlugin()

        val call = MethodCall("setEffect", mapOf("type" to "image", "sourceType" to "file", "data" to "non_existent.png"))
        val mockResult: MethodChannel.Result = Mockito.mock(MethodChannel.Result::class.java)
        plugin.onMethodCall(call, mockResult)

        Mockito.verify(mockResult).error(
            Mockito.eq("invalidImage"),
            Mockito.any(),
            Mockito.isNull(),
        )
    }

    @Test
    fun onMethodCall_setEffectImage_validBytes_succeeds() {
        val plugin = MiVirtualBackgroundKitPlugin()
        val mockBitmap = createTestBitmap()
        plugin.imageDecoder = { _, _ -> mockBitmap }

        val call = MethodCall(
            "setEffect",
            mapOf("type" to "image", "sourceType" to "bytes", "fit" to "cover", "data" to byteArrayOf(1, 2, 3)),
        )
        val mockResult: MethodChannel.Result = Mockito.mock(MethodChannel.Result::class.java)
        plugin.onMethodCall(call, mockResult)

        Mockito.verify(mockResult).success(null)
    }

    @Test
    fun onMethodCall_setEffectUnknown_notImplemented() {
        val plugin = MiVirtualBackgroundKitPlugin()

        val call = MethodCall("setEffect", mapOf("type" to "unsupported_type"))
        val mockResult: MethodChannel.Result = Mockito.mock(MethodChannel.Result::class.java)
        plugin.onMethodCall(call, mockResult)

        Mockito.verify(mockResult).notImplemented()
    }
}
