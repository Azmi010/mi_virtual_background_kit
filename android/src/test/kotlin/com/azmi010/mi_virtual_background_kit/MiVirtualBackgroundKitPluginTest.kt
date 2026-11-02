package com.azmi010.mi_virtual_background_kit

import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.mockito.Mockito
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

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

    @Test
    fun onMethodCall_isSupported_returnsExpectedValue() {
        val plugin = MiVirtualBackgroundKitPlugin()

        val call = MethodCall("isSupported", null)
        val mockResult: MethodChannel.Result = Mockito.mock(MethodChannel.Result::class.java)
        plugin.onMethodCall(call, mockResult)

        val expected = android.os.Build.VERSION.SDK_INT >= 24
        Mockito.verify(mockResult).success(expected)
    }

    @Test
    fun onMethodCall_dispose_succeedsAndSetsIdle() {
        val plugin = MiVirtualBackgroundKitPlugin()

        val call = MethodCall("dispose", null)
        val mockResult: MethodChannel.Result = Mockito.mock(MethodChannel.Result::class.java)
        plugin.onMethodCall(call, mockResult)

        Mockito.verify(mockResult).success(null)
        assertEquals("idle", plugin.currentStatus)
    }

    @Test
    fun statusStream_updatesSinkOnStatusChange() {
        val plugin = MiVirtualBackgroundKitPlugin()
        val mockSink: EventChannel.EventSink = Mockito.mock(EventChannel.EventSink::class.java)
        plugin.statusSink = mockSink

        assertEquals("idle", plugin.currentStatus)

        plugin.updateStatus("initializing")
        Mockito.verify(mockSink).success("initializing")
        assertEquals("initializing", plugin.currentStatus)

        plugin.updateStatus("active")
        Mockito.verify(mockSink).success("active")
        assertEquals("active", plugin.currentStatus)

        plugin.updateStatus("error")
        Mockito.verify(mockSink).success("error")
        assertEquals("error", plugin.currentStatus)
    }

    @Test
    fun attachAndDetach_100Times_completesWithoutLeaksOrErrors() {
        val plugin = MiVirtualBackgroundKitPlugin()
        val dummyTrack = Any()
        var attachCount = 0
        var detachCount = 0

        plugin.trackAttacher = { _, _ ->
            attachCount++
            dummyTrack
        }
        plugin.trackDetacher = { _, _ ->
            detachCount++
        }

        for (i in 1..100) {
            val attachCall = MethodCall("attach", mapOf("trackId" to "track-$i"))
            val attachResult: MethodChannel.Result = Mockito.mock(MethodChannel.Result::class.java)
            plugin.onMethodCall(attachCall, attachResult)
            Mockito.verify(attachResult).success(null)
            assertEquals("active", plugin.currentStatus)

            val detachCall = MethodCall("detach", null)
            val detachResult: MethodChannel.Result = Mockito.mock(MethodChannel.Result::class.java)
            plugin.onMethodCall(detachCall, detachResult)
            Mockito.verify(detachResult).success(null)
            assertEquals("idle", plugin.currentStatus)
        }

        assertEquals(100, attachCount)
        assertEquals(100, detachCount)
    }

    @Test
    fun dispose_cleansUpAttachedTrackAndProcessor() {
        val plugin = MiVirtualBackgroundKitPlugin()
        val dummyTrack = Any()
        var detached = false

        plugin.trackAttacher = { _, _ -> dummyTrack }
        plugin.trackDetacher = { _, _ -> detached = true }

        val attachCall = MethodCall("attach", mapOf("trackId" to "track-1"))
        val attachResult: MethodChannel.Result = Mockito.mock(MethodChannel.Result::class.java)
        plugin.onMethodCall(attachCall, attachResult)
        assertEquals("active", plugin.currentStatus)

        val disposeCall = MethodCall("dispose", null)
        val disposeResult: MethodChannel.Result = Mockito.mock(MethodChannel.Result::class.java)
        plugin.onMethodCall(disposeCall, disposeResult)

        Mockito.verify(disposeResult).success(null)
        assertTrue(detached)
        assertEquals("idle", plugin.currentStatus)
    }

    @Test
    fun reattachReplacesOldProcessor() {
        val plugin = MiVirtualBackgroundKitPlugin()
        var detachCount = 0
        plugin.trackAttacher = { _, _ -> Any() }
        plugin.trackDetacher = { _, _ -> detachCount++ }

        val attach1 = MethodCall("attach", mapOf("trackId" to "track-1"))
        val result1: MethodChannel.Result = Mockito.mock(MethodChannel.Result::class.java)
        plugin.onMethodCall(attach1, result1)
        Mockito.verify(result1).success(null)
        assertEquals(0, detachCount)

        val attach2 = MethodCall("attach", mapOf("trackId" to "track-2"))
        val result2: MethodChannel.Result = Mockito.mock(MethodChannel.Result::class.java)
        plugin.onMethodCall(attach2, result2)
        Mockito.verify(result2).success(null)
        assertEquals(1, detachCount)
        assertEquals("active", plugin.currentStatus)
    }

    @Test
    fun onMethodCall_setQuality_succeeds() {
        val plugin = MiVirtualBackgroundKitPlugin()
        val dummyTrack = Any()
        plugin.trackAttacher = { _, _ -> dummyTrack }

        // Attach with quality
        val attachCall = MethodCall(
            "attach",
            mapOf(
                "trackId" to "track-1",
                "quality" to mapOf(
                    "segmentationWidth" to 160,
                    "edgeSmoothing" to 0.3,
                    "targetFps" to 15,
                ),
            ),
        )
        val attachResult: MethodChannel.Result = Mockito.mock(MethodChannel.Result::class.java)
        plugin.onMethodCall(attachCall, attachResult)
        Mockito.verify(attachResult).success(null)

        // Set quality at runtime
        val qualityCall = MethodCall(
            "setQuality",
            mapOf(
                "segmentationWidth" to 256,
                "edgeSmoothing" to 0.8,
                "targetFps" to 24,
            ),
        )
        val qualityResult: MethodChannel.Result = Mockito.mock(MethodChannel.Result::class.java)
        plugin.onMethodCall(qualityCall, qualityResult)
        Mockito.verify(qualityResult).success(null)
    }

    @Test
    fun sendFallbackEvent_deliversPayloadToSink() {
        val plugin = MiVirtualBackgroundKitPlugin()
        val mockSink = Mockito.mock(EventChannel.EventSink::class.java)
        plugin.statusSink = mockSink

        val fallbackMap = mapOf(
            "event" to "fallback",
            "action" to "qualityDegraded",
            "reason" to "fps_drop_11.5",
            "segmentationWidth" to 192,
        )
        plugin.sendFallbackEvent(fallbackMap)

        Mockito.verify(mockSink).success(fallbackMap)
    }

    @Test
    fun onMethodCall_isSupported_checkerOverrides() {
        val plugin = MiVirtualBackgroundKitPlugin()

        plugin.isSupportedChecker = { true }
        val call = MethodCall("isSupported", null)
        val mockResultTrue: MethodChannel.Result = Mockito.mock(MethodChannel.Result::class.java)
        plugin.onMethodCall(call, mockResultTrue)
        Mockito.verify(mockResultTrue).success(true)

        plugin.isSupportedChecker = { false }
        val mockResultFalse: MethodChannel.Result = Mockito.mock(MethodChannel.Result::class.java)
        plugin.onMethodCall(call, mockResultFalse)
        Mockito.verify(mockResultFalse).success(false)
    }

    @Test
    fun onMethodCall_isSupported_checksGlEsAndModelAsset() {
        val plugin = MiVirtualBackgroundKitPlugin()

        // Case 1: GLES < 2.0 (e.g. 0x10000)
        plugin.glEsVersionProvider = { 0x10000 }
        plugin.modelAssetChecker = { true }
        val mockResultGlesFail: MethodChannel.Result = Mockito.mock(MethodChannel.Result::class.java)
        plugin.onMethodCall(MethodCall("isSupported", null), mockResultGlesFail)
        Mockito.verify(mockResultGlesFail).success(false)

        // Case 2: GLES >= 2.0 but asset missing
        plugin.glEsVersionProvider = { 0x20000 }
        plugin.modelAssetChecker = { false }
        val mockResultAssetFail: MethodChannel.Result = Mockito.mock(MethodChannel.Result::class.java)
        plugin.onMethodCall(MethodCall("isSupported", null), mockResultAssetFail)
        Mockito.verify(mockResultAssetFail).success(false)

        // Case 3: GLES >= 2.0 and asset available
        plugin.glEsVersionProvider = { 0x20000 }
        plugin.modelAssetChecker = { true }
        val mockResultSuccess: MethodChannel.Result = Mockito.mock(MethodChannel.Result::class.java)
        plugin.onMethodCall(MethodCall("isSupported", null), mockResultSuccess)
        val expected = android.os.Build.VERSION.SDK_INT >= 24
        Mockito.verify(mockResultSuccess).success(expected)
    }
}
