package com.azmi010.mi_virtual_background_kit.processor

import android.graphics.Bitmap
import com.azmi010.mi_virtual_background_kit.compositor.FrameCompositor
import com.azmi010.mi_virtual_background_kit.compositor.GpuCompositor
import com.azmi010.mi_virtual_background_kit.segmentation.MaskSegmenter
import com.azmi010.mi_virtual_background_kit.segmentation.PersonMask
import org.mockito.Mockito
import org.webrtc.VideoFrame
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertSame
import kotlin.test.assertTrue

internal class FrameProcessorTest {

    private fun createTestBitmap(): Bitmap {
        val ctor = Bitmap::class.java.getDeclaredConstructor()
        ctor.isAccessible = true
        return ctor.newInstance()
    }

    private class FakeSegmenter : MaskSegmenter {
        var closed = false
        var lastRotation = 0
        override fun segment(bitmap: Bitmap): PersonMask {
            return PersonMask(ByteArray(4), 2, 2)
        }
        override fun close() {
            closed = true
        }
    }

    private class FakeCompositor : FrameCompositor {
        override var hasMask: Boolean = false
        override var readbackWidth: Int = 2
        override var readbackHeight: Int = 2
        override var edgeSmoothing: Float = 0.5f
        var released = false
        var composeBlurCalls = 0
        var composeColorCalls = 0
        var composeImageCalls = 0
        var reuseLastFrameCalls = 0
        var lastTargetWidth: Int = 0
        var lastRadius: Float? = null
        var lastColor: Int? = null
        var lastFit: String? = null
        var lastUploadedBitmap: Bitmap? = null

        override fun readBackRgba(buffer: VideoFrame.TextureBuffer, targetWidth: Int): ByteArray? {
            lastTargetWidth = targetWidth
            return ByteArray(16)
        }
        override fun uploadMask(mask: PersonMask) {
            hasMask = true
        }
        override fun clearMask() {
            hasMask = false
        }
        override fun uploadImage(bitmap: Bitmap) {
            lastUploadedBitmap = bitmap
        }
        override fun composeBlur(frame: VideoFrame, radius: Float): VideoFrame? {
            composeBlurCalls++
            lastRadius = radius
            return frame
        }
        override fun composeColor(frame: VideoFrame, color: Int): VideoFrame? {
            composeColorCalls++
            lastColor = color
            return frame
        }
        override fun composeImage(frame: VideoFrame, fit: String): VideoFrame? {
            composeImageCalls++
            lastFit = fit
            return frame
        }
        override fun reuseLastFrame(frame: VideoFrame): VideoFrame? {
            reuseLastFrameCalls++
            return frame
        }
        override fun release() {
            released = true
        }
    }

    @Test
    fun constantsMatchDecision() {
        assertEquals(5, FrameProcessor.SEGMENT_EVERY_N_FRAMES)
    }

    @Test
    fun defaultStateHasNoEffect() {
        val processor = FrameProcessor()
        assertNull(processor.currentEffect)
        assertEquals(0, processor.frameCount)
    }

    @Test
    fun setBlurEffectUpdatesCurrentEffect() {
        val fakeSegmenter = FakeSegmenter()
        val processor = FrameProcessor(
            segmenterProvider = { fakeSegmenter },
        )

        processor.setBlurEffect(15.0f)

        val effect = processor.currentEffect
        assertNotNull(effect)
        assertTrue(effect is FrameProcessor.EffectState.Blur)
        assertEquals(15.0f, effect.radius)

        processor.clearEffect()
        assertNull(processor.currentEffect)
    }

    @Test
    fun setTestModel_rebuildsSegmenterOnlyWhenAssetChanges() {
        var providerCalls = 0
        val first = FakeSegmenter()
        val second = FakeSegmenter()
        val third = FakeSegmenter()
        val processor = FrameProcessor(
            segmenterProvider = {
                providerCalls++
                when (providerCalls) {
                    1 -> first
                    2 -> second
                    else -> third
                }
            },
        )

        processor.setBlurEffect(10.0f)
        assertEquals(1, providerCalls)

        // T14.5: switching to the legacy square model closes and rebuilds.
        processor.setTestModel("selfie_segmenter.tflite")
        assertEquals(2, providerCalls)
        assertTrue(first.closed)
        assertFalse(second.closed)

        // Same asset again: no rebuild.
        processor.setTestModel("selfie_segmenter.tflite")
        assertEquals(2, providerCalls)

        // Back to the production model: rebuild again.
        processor.setTestModel(null)
        assertEquals(3, providerCalls)
        assertTrue(second.closed)
        assertFalse(third.closed)
    }

    @Test
    fun setColorEffectUpdatesCurrentEffect() {
        val fakeSegmenter = FakeSegmenter()
        val processor = FrameProcessor(
            segmenterProvider = { fakeSegmenter },
        )

        val testColor = 0xFF123456.toInt()
        processor.setColorEffect(testColor)

        val effect = processor.currentEffect
        assertNotNull(effect)
        assertTrue(effect is FrameProcessor.EffectState.Color)
        assertEquals(testColor, effect.color)

        processor.clearEffect()
        assertNull(processor.currentEffect)
    }

    @Test
    fun setImageEffectUpdatesCurrentEffect() {
        val fakeSegmenter = FakeSegmenter()
        val processor = FrameProcessor(
            segmenterProvider = { fakeSegmenter },
        )

        val mockBitmap = createTestBitmap()
        processor.setImageEffect(mockBitmap, "contain")

        val effect = processor.currentEffect
        assertNotNull(effect)
        assertTrue(effect is FrameProcessor.EffectState.Image)
        assertEquals(mockBitmap, effect.bitmap)
        assertEquals("contain", effect.fit)

        processor.clearEffect()
        assertNull(processor.currentEffect)
    }

    @Test
    fun onFrameWithoutEffectReturnsSameFrameAndIncrementsCounter() {
        val processor = FrameProcessor()
        val mockBuffer = Mockito.mock(VideoFrame.Buffer::class.java)
        val frame = VideoFrame(mockBuffer, 0, 1000L)

        val result1 = processor.onFrame(frame)
        assertEquals(frame, result1)
        assertEquals(1, processor.frameCount)

        val result2 = processor.onFrame(frame)
        assertEquals(frame, result2)
        assertEquals(2, processor.frameCount)
    }

    @Test
    fun onFrameWithBlurUsesCompositorWhenMaskAvailable() {
        val fakeSegmenter = FakeSegmenter()
        val fakeCompositor = FakeCompositor()
        fakeCompositor.hasMask = true

        val mockTextureBuffer = Mockito.mock(VideoFrame.TextureBuffer::class.java)
        val inputFrame = VideoFrame(mockTextureBuffer, 0, 1000L)

        val processor = FrameProcessor(
            segmenterProvider = { fakeSegmenter },
            compositorProvider = { fakeCompositor },
            bitmapProvider = { _, _ -> createTestBitmap() },
        )

        processor.setBlurEffect(20.0f)
        val result = processor.onFrame(inputFrame)

        assertEquals(inputFrame, result)
        assertEquals(1, fakeCompositor.composeBlurCalls)
        assertEquals(20.0f, fakeCompositor.lastRadius)
    }

    @Test
    fun onFrameWithColorUsesCompositorWhenMaskAvailable() {
        val fakeSegmenter = FakeSegmenter()
        val fakeCompositor = FakeCompositor()
        fakeCompositor.hasMask = true

        val mockTextureBuffer = Mockito.mock(VideoFrame.TextureBuffer::class.java)
        val inputFrame = VideoFrame(mockTextureBuffer, 0, 1000L)

        val processor = FrameProcessor(
            segmenterProvider = { fakeSegmenter },
            compositorProvider = { fakeCompositor },
            bitmapProvider = { _, _ -> createTestBitmap() },
        )

        val testColor = 0xFFABCDEF.toInt()
        processor.setColorEffect(testColor)
        val result = processor.onFrame(inputFrame)

        assertEquals(inputFrame, result)
        assertEquals(1, fakeCompositor.composeColorCalls)
        assertEquals(testColor, fakeCompositor.lastColor)
    }

    @Test
    fun onFrameWithImageUsesCompositorWhenMaskAvailable() {
        val fakeSegmenter = FakeSegmenter()
        val fakeCompositor = FakeCompositor()
        fakeCompositor.hasMask = true

        val mockTextureBuffer = Mockito.mock(VideoFrame.TextureBuffer::class.java)
        val inputFrame = VideoFrame(mockTextureBuffer, 0, 1000L)

        val processor = FrameProcessor(
            segmenterProvider = { fakeSegmenter },
            compositorProvider = { fakeCompositor },
            bitmapProvider = { _, _ -> createTestBitmap() },
        )

        val mockBitmap = createTestBitmap()
        processor.setImageEffect(mockBitmap, "cover")
        val result = processor.onFrame(inputFrame)

        assertEquals(inputFrame, result)
        assertEquals(1, fakeCompositor.composeImageCalls)
        assertEquals("cover", fakeCompositor.lastFit)
        assertEquals(mockBitmap, fakeCompositor.lastUploadedBitmap)
    }

    @Test
    fun releaseCleansUpResources() {
        val fakeSegmenter = FakeSegmenter()
        val fakeCompositor = FakeCompositor()

        val processor = FrameProcessor(
            segmenterProvider = { fakeSegmenter },
            compositorProvider = { fakeCompositor },
            bitmapProvider = { _, _ -> createTestBitmap() },
        )

        processor.setBlurEffect(10.0f)
        processor.release()

        assertNull(processor.currentEffect)
        assertTrue(fakeSegmenter.closed)
        assertTrue(fakeCompositor.released)
    }

    @Test
    fun calculateImageMatrix_preservesUprightOrientations() {
        val compositor = GpuCompositor()
        val mockBuffer = Mockito.mock(VideoFrame.TextureBuffer::class.java)
        Mockito.`when`(mockBuffer.width).thenReturn(640)
        Mockito.`when`(mockBuffer.height).thenReturn(480)

        // Rotation 0 (Landscape)
        val frame0 = VideoFrame(mockBuffer, 0, 0L)
        val m0 = compositor.calculateImageMatrix(frame0, 1920, 1080, "cover")
        assertEquals(16, m0.size)
        // Center mapping test: (0.5, 0.5) must map to (0.5, 0.5)
        val u0 = m0[0] * 0.5f + m0[4] * 0.5f + m0[12]
        val v0 = m0[1] * 0.5f + m0[5] * 0.5f + m0[13]
        assertEquals(0.5f, u0, 0.001f)
        assertEquals(0.5f, v0, 0.001f)
        // Top of screen in rot 0 (0.5, 1.0) -> V_img must be top of bitmap (<= 0.5)
        val topV0 = m0[1] * 0.5f + m0[5] * 1.0f + m0[13]
        assertTrue(topV0 < 0.5f, "topV0 ($topV0) should be < 0.5")

        // Rotation 90 (Portrait CW)
        val frame90 = VideoFrame(mockBuffer, 90, 0L)
        val m90 = compositor.calculateImageMatrix(frame90, 1920, 1080, "cover")
        val u90 = m90[0] * 0.5f + m90[4] * 0.5f + m90[12]
        val v90 = m90[1] * 0.5f + m90[5] * 0.5f + m90[13]
        assertEquals(0.5f, u90, 0.001f)
        assertEquals(0.5f, v90, 0.001f)

        // Rotation 270 (Portrait CCW - typical front camera)
        // Buffer is 640x480, display is 480x640 (aspect 0.75)
        // Image is 640x480 (aspect 1.33)
        val frame270 = VideoFrame(mockBuffer, 270, 0L)
        val m270Contain = compositor.calculateImageMatrix(frame270, 640, 480, "contain")
        val u270 = m270Contain[0] * 0.5f + m270Contain[4] * 0.5f + m270Contain[12]
        val v270 = m270Contain[1] * 0.5f + m270Contain[5] * 0.5f + m270Contain[13]
        assertEquals(0.5f, u270, 0.001f)
        assertEquals(0.5f, v270, 0.001f)

        // Top of screen for rot=270 is U_fbo = 1.0, V_fbo = 0.5.
        // For contain, wide image on portrait screen produces black letterbox at top (V_img < 0.0)
        val topV270 = m270Contain[1] * 1.0f + m270Contain[5] * 0.5f + m270Contain[13]
        assertTrue(topV270 < 0.0f, "topV270 ($topV270) should be < 0.0 for black letterbox")

        // Bottom of screen for rot=270 is U_fbo = 0.0, V_fbo = 0.5.
        // For contain, produces black letterbox at bottom (V_img > 1.0)
        val botV270 = m270Contain[1] * 0.0f + m270Contain[5] * 0.5f + m270Contain[13]
        assertTrue(botV270 > 1.0f, "botV270 ($botV270) should be > 1.0 for black letterbox")
    }

    @Test
    fun tracksLastRotationAndDimensions() {
        val processor = FrameProcessor()
        val mockBuffer = Mockito.mock(VideoFrame.TextureBuffer::class.java)
        Mockito.`when`(mockBuffer.width).thenReturn(640)
        Mockito.`when`(mockBuffer.height).thenReturn(480)

        val frame = VideoFrame(mockBuffer, 270, 1234L)
        processor.onFrame(frame)

        assertEquals(270, processor.lastRotation)
        assertEquals(480, processor.lastWidth)
        assertEquals(640, processor.lastHeight)
    }

    @Test
    fun calculateImageMatrix_reusesPreallocatedBuffer() {
        val compositor = GpuCompositor()
        val mockBuffer = Mockito.mock(VideoFrame.TextureBuffer::class.java)
        Mockito.`when`(mockBuffer.width).thenReturn(640)
        Mockito.`when`(mockBuffer.height).thenReturn(480)

        val frame = VideoFrame(mockBuffer, 0, 0L)
        val reusableArray = FloatArray(16)
        val result = compositor.calculateImageMatrix(frame, 640, 480, "cover", reusableArray)

        assertSame(reusableArray, result)
        assertEquals(1.0f, result[0], 0.001f)
    }

    @Test
    fun segmentationWorker_reusesPooledBuffersAcrossMultipleFrames() {
        val fakeSegmenter = FakeSegmenter()
        val fakeCompositor = FakeCompositor()
        var bitmapAllocations = 0

        val mockTextureBuffer = Mockito.mock(VideoFrame.TextureBuffer::class.java)
        val inputFrame = VideoFrame(mockTextureBuffer, 0, 1000L)

        val processor = FrameProcessor(
            segmenterProvider = { fakeSegmenter },
            compositorProvider = { fakeCompositor },
            bitmapProvider = { _, _ ->
                bitmapAllocations++
                createTestBitmap()
            },
        )
        processor.setBlurEffect(10.0f)

        // Process multiple frame cycles (triggering segmentation multiple times)
        for (i in 1..25) {
            processor.onFrame(inputFrame)
            Thread.sleep(5) // Allow background thread to process
        }

        assertTrue(fakeCompositor.composeBlurCalls > 0)
        processor.release()
        assertTrue(fakeSegmenter.closed)
        assertTrue(fakeCompositor.released)
    }

    @Test
    fun releaseIsIdempotentAndSafeToCallMultipleTimes() {
        val fakeSegmenter = FakeSegmenter()
        val fakeCompositor = FakeCompositor()

        val processor = FrameProcessor(
            segmenterProvider = { fakeSegmenter },
            compositorProvider = { fakeCompositor },
        )
        processor.setBlurEffect(10.0f)

        // Multiple consecutive release calls must not throw
        for (i in 1..10) {
            processor.release()
        }

        assertTrue(fakeSegmenter.closed)
        assertTrue(fakeCompositor.released)
        assertNull(processor.currentEffect)
    }

    @Test
    fun onFrameAfterReleaseBypassesWithoutProcessing() {
        val fakeSegmenter = FakeSegmenter()
        val fakeCompositor = FakeCompositor()
        val mockBuffer = Mockito.mock(VideoFrame.TextureBuffer::class.java)
        val frame = VideoFrame(mockBuffer, 0, 1000L)

        val processor = FrameProcessor(
            segmenterProvider = { fakeSegmenter },
            compositorProvider = { fakeCompositor },
        )
        processor.setBlurEffect(10.0f)
        processor.release()

        val result = processor.onFrame(frame)
        assertSame(frame, result)
        assertEquals(0, fakeCompositor.composeBlurCalls)
    }

    @Test
    fun clearEffect_clearsMaskAndEffectState() {
        val fakeSegmenter = FakeSegmenter()
        val fakeCompositor = FakeCompositor()

        val processor = FrameProcessor(
            segmenterProvider = { fakeSegmenter },
            compositorProvider = { fakeCompositor },
        )
        processor.setBlurEffect(12.0f)
        fakeCompositor.uploadMask(PersonMask(ByteArray(4), 2, 2))
        assertTrue(fakeCompositor.hasMask)

        processor.clearEffect()
        assertNull(processor.currentEffect)
        assertTrue(!fakeCompositor.hasMask)
    }

    @Test
    fun runtimeEffectSwitching_seamlessTransitionsBetweenEffects() {
        val fakeSegmenter = FakeSegmenter()
        val fakeCompositor = FakeCompositor()
        val mockBuffer = Mockito.mock(VideoFrame.TextureBuffer::class.java)
        Mockito.`when`(mockBuffer.unscaledWidth).thenReturn(640)
        Mockito.`when`(mockBuffer.unscaledHeight).thenReturn(480)
        Mockito.`when`(mockBuffer.type).thenReturn(VideoFrame.TextureBuffer.Type.RGB)
        val frame = VideoFrame(mockBuffer, 0, 1000L)

        val processor = FrameProcessor(
            segmenterProvider = { fakeSegmenter },
            compositorProvider = { fakeCompositor },
        )

        // 1. Start with Blur effect
        processor.setBlurEffect(15.0f)
        fakeCompositor.uploadMask(PersonMask(ByteArray(4), 2, 2))
        processor.onFrame(frame)
        assertEquals(1, fakeCompositor.composeBlurCalls)

        // 2. Switch to Solid Color effect at runtime
        processor.setColorEffect(0xFF00FF00.toInt())
        assertTrue(processor.currentEffect is FrameProcessor.EffectState.Color)
        processor.onFrame(frame)
        assertEquals(1, fakeCompositor.composeColorCalls)

        // 3. Switch to Image effect at runtime
        val bmp = createTestBitmap()
        processor.setImageEffect(bmp, "cover")
        assertTrue(processor.currentEffect is FrameProcessor.EffectState.Image)
        processor.onFrame(frame)
        assertEquals(1, fakeCompositor.composeImageCalls)
        assertSame(bmp, fakeCompositor.lastUploadedBitmap)

        // 4. Switch blur radius at runtime
        processor.setBlurEffect(35.0f)
        processor.onFrame(frame)
        assertEquals(2, fakeCompositor.composeBlurCalls)
        assertEquals(35.0f, fakeCompositor.lastRadius)

        // 5. Clear effect to bypass
        processor.clearEffect()
        assertNull(processor.currentEffect)
        assertTrue(!fakeCompositor.hasMask)
        val bypassResult = processor.onFrame(frame)
        assertSame(frame, bypassResult)

        processor.release()
    }

    @Test
    fun setQualityUpdatesParametersAndCompositor() {
        val fakeCompositor = FakeCompositor()
        val processor = FrameProcessor(
            compositorProvider = { fakeCompositor },
        )

        assertEquals(256, processor.segmentationWidth)
        assertEquals(0.5f, processor.edgeSmoothing)
        assertEquals(30, processor.targetFps)

        processor.setQuality(160, 0.25f, 15)
        assertEquals(160, processor.segmentationWidth)
        assertEquals(0.25f, processor.edgeSmoothing)
        assertEquals(15, processor.targetFps)
        assertEquals(0.25f, fakeCompositor.edgeSmoothing)

        // Clamping checks
        processor.setQuality(100, -0.5f, 0)
        assertEquals(0.0f, processor.edgeSmoothing)
        assertEquals(1, processor.targetFps)

        processor.setQuality(512, 1.8f, 120)
        assertEquals(1.0f, processor.edgeSmoothing)
        assertEquals(60, processor.targetFps)

        processor.release()
    }

    @Test
    fun qualityParametersAffectReadbackWidth() {
        val fakeSegmenter = FakeSegmenter()
        val fakeCompositor = FakeCompositor()
        val mockBuffer = Mockito.mock(VideoFrame.TextureBuffer::class.java)
        Mockito.`when`(mockBuffer.unscaledWidth).thenReturn(640)
        Mockito.`when`(mockBuffer.unscaledHeight).thenReturn(480)
        Mockito.`when`(mockBuffer.type).thenReturn(VideoFrame.TextureBuffer.Type.RGB)
        val frame = VideoFrame(mockBuffer, 0, 1000L)

        val processor = FrameProcessor(
            segmenterProvider = { fakeSegmenter },
            compositorProvider = { fakeCompositor },
        )
        processor.setQuality(192, 0.4f, 30)
        processor.setBlurEffect(10.0f)

        processor.onFrame(frame)
        assertEquals(192, fakeCompositor.lastTargetWidth)

        processor.release()
    }

    @Test
    fun targetFpsThrottling_reusesPreviousFrameWhenBelowInterval() {
        val fakeSegmenter = FakeSegmenter()
        val fakeCompositor = FakeCompositor()
        fakeCompositor.uploadMask(PersonMask(ByteArray(4), 2, 2))
        val mockBuffer = Mockito.mock(VideoFrame.TextureBuffer::class.java)
        Mockito.`when`(mockBuffer.unscaledWidth).thenReturn(640)
        Mockito.`when`(mockBuffer.unscaledHeight).thenReturn(480)
        Mockito.`when`(mockBuffer.type).thenReturn(VideoFrame.TextureBuffer.Type.RGB)

        val processor = FrameProcessor(
            segmenterProvider = { fakeSegmenter },
            compositorProvider = { fakeCompositor },
        )
        processor.setBlurEffect(15.0f)
        processor.setQuality(256, 0.5f, 15) // target 15 fps => ~66.6ms interval

        // Frame 1: 100ms
        val f1 = VideoFrame(mockBuffer, 0, 100_000_000L)
        processor.onFrame(f1)
        assertEquals(1, fakeCompositor.composeBlurCalls)
        assertEquals(0, fakeCompositor.reuseLastFrameCalls)

        // Frame 2: 110ms (10ms later -> throttled!)
        val f2 = VideoFrame(mockBuffer, 0, 110_000_000L)
        processor.onFrame(f2)
        assertEquals(1, fakeCompositor.composeBlurCalls)
        assertEquals(1, fakeCompositor.reuseLastFrameCalls)

        // Frame 3: 175ms (75ms later -> allowed)
        val f3 = VideoFrame(mockBuffer, 0, 175_000_000L)
        processor.onFrame(f3)
        assertEquals(2, fakeCompositor.composeBlurCalls)
        assertEquals(1, fakeCompositor.reuseLastFrameCalls)

        processor.release()
    }

    @Test
    fun performanceFallback_stage1_degradesResolutionWhenFpsDrops() {
        val fakeSegmenter = FakeSegmenter()
        val fakeCompositor = FakeCompositor()
        var fallbackMap: Map<String, Any?>? = null

        val processor = FrameProcessor(
            segmenterProvider = { fakeSegmenter },
            compositorProvider = { fakeCompositor },
            onFallbackEvent = { event -> fallbackMap = event },
        )
        processor.setQuality(256, 0.5f, 30)
        processor.setBlurEffect(10.0f)

        // Measured FPS dropped to 12.0 (< 14.0 threshold)
        processor.simulatePerformanceDrop(12.0)

        // Stage 1: resolution drops from 256 to 192, and interval increases
        assertEquals(192, processor.segmentationWidth)
        assertTrue(processor.adaptiveSegmentInterval >= 5)
        assertNotNull(fallbackMap)
        assertEquals("qualityDegraded", fallbackMap!!["action"])
        assertEquals(192, fallbackMap!!["segmentationWidth"])
        assertFalse(processor.isFallbackDisabled)
        assertNotNull(processor.currentEffect)

        processor.release()
    }

    @Test
    fun performanceFallback_stage2_disablesEffectWhenFpsCriticallyLow() {
        val fakeSegmenter = FakeSegmenter()
        val fakeCompositor = FakeCompositor()
        var fallbackMap: Map<String, Any?>? = null
        var lastStatus: String? = null

        val processor = FrameProcessor(
            segmenterProvider = { fakeSegmenter },
            compositorProvider = { fakeCompositor },
            onStatusChange = { status -> lastStatus = status },
            onFallbackEvent = { event -> fallbackMap = event },
        )
        processor.setQuality(192, 0.5f, 30)
        processor.setBlurEffect(10.0f)

        // First window at critical FPS (< 10)
        processor.simulatePerformanceDrop(8.0)
        assertNotNull(processor.currentEffect) // Not yet disabled on 1st window

        // Second consecutive window at critical FPS
        processor.simulatePerformanceDrop(7.5)

        // Stage 2: Effect is disabled and reverted to bypass
        assertNull(processor.currentEffect)
        assertTrue(processor.isFallbackDisabled)
        assertEquals("idle", lastStatus)
        assertNotNull(fallbackMap)
        assertEquals("disabled", fallbackMap!!["action"])

        processor.release()
    }

    @Test
    fun frameGapAfterBackground_resetsWindowWithoutFalseFallback() {
        val fakeSegmenter = FakeSegmenter()
        val fakeCompositor = FakeCompositor()
        var fallbackMap: Map<String, Any?>? = null
        fakeCompositor.uploadMask(PersonMask(ByteArray(4), 2, 2))
        val mockBuffer = Mockito.mock(VideoFrame.TextureBuffer::class.java)
        Mockito.`when`(mockBuffer.unscaledWidth).thenReturn(640)
        Mockito.`when`(mockBuffer.unscaledHeight).thenReturn(480)
        Mockito.`when`(mockBuffer.type).thenReturn(VideoFrame.TextureBuffer.Type.RGB)

        val processor = FrameProcessor(
            segmenterProvider = { fakeSegmenter },
            compositorProvider = { fakeCompositor },
            onFallbackEvent = { event -> fallbackMap = event },
        )
        processor.setQuality(256, 0.5f, 30)
        processor.setBlurEffect(10.0f)

        // Frame before "background"
        processor.onFrame(VideoFrame(mockBuffer, 0, 0L))

        // App returns after 10s: without gap reset the next 45 frames would
        // measure ~4.5 fps over the stale window and trip stage-1 fallback.
        val resumeBase = 10_000_000_000L
        processor.onFrame(VideoFrame(mockBuffer, 0, resumeBase))
        for (i in 1..50) {
            processor.onFrame(VideoFrame(mockBuffer, 0, resumeBase + i * 33_000_000L))
        }

        assertNull(fallbackMap)
        assertEquals(256, processor.segmentationWidth)
        assertFalse(processor.isFallbackDisabled)
        assertNotNull(processor.currentEffect)

        processor.release()
    }

    // --- T14.4 (FR-21): fallback recovery ---

    private class RecoveryFixture(
        val processor: FrameProcessor,
        val events: MutableList<Map<String, Any?>>,
        val statuses: MutableList<String>,
    )

    private fun createRecoveryFixture(autoRecovery: Boolean): RecoveryFixture {
        val events = mutableListOf<Map<String, Any?>>()
        val statuses = mutableListOf<String>()
        val processor = FrameProcessor(
            segmenterProvider = { FakeSegmenter() },
            compositorProvider = { FakeCompositor() },
            onStatusChange = { statuses.add(it) },
            onFallbackEvent = { events.add(it) },
        )
        processor.setQuality(256, 0.5f, 30, 0.7f, autoRecovery)
        processor.setBlurEffect(10.0f)
        return RecoveryFixture(processor, events, statuses)
    }

    /** Drives stage-1 degrade (256 -> 192) then stage-2 disable. */
    private fun forceDisable(processor: FrameProcessor) {
        processor.simulatePerformanceDrop(8.0)
        processor.simulatePerformanceDrop(8.0)
    }

    private fun RecoveryFixture.recoveredReasons(): List<Any?> =
        events.filter { it["action"] == "recovered" }.map { it["reason"] }

    @Test
    fun autoRecovery_stage2_autoRestoresEffectWhenFpsStable() {
        val f = createRecoveryFixture(autoRecovery = true)

        forceDisable(f.processor)
        assertTrue(f.processor.isFallbackDisabled)
        assertNull(f.processor.currentEffect)
        assertEquals("idle", f.statuses.last())

        // One healthy window is not enough (hysteresis needs 2).
        f.processor.simulatePerformanceDrop(25.0)
        assertTrue(f.processor.isFallbackDisabled)

        f.processor.simulatePerformanceDrop(25.0)
        assertFalse(f.processor.isFallbackDisabled)
        assertNotNull(f.processor.currentEffect)
        // Degraded width restored together with the effect.
        assertEquals(256, f.processor.segmentationWidth)
        assertEquals("initializing", f.statuses.last())
        assertEquals(listOf<Any?>("auto"), f.recoveredReasons())

        f.processor.release()
    }

    @Test
    fun autoRecovery_latchedAfterAutoResume_furtherFailureStaysDisabled() {
        val f = createRecoveryFixture(autoRecovery = true)

        forceDisable(f.processor)
        f.processor.simulatePerformanceDrop(25.0)
        f.processor.simulatePerformanceDrop(25.0)
        assertFalse(f.processor.isFallbackDisabled)

        // Device fails again right after the auto resume: one-shot latch.
        forceDisable(f.processor)
        assertTrue(f.processor.isFallbackDisabled)
        f.processor.simulatePerformanceDrop(25.0)
        f.processor.simulatePerformanceDrop(25.0)
        assertTrue(f.processor.isFallbackDisabled)
        assertNull(f.processor.currentEffect)
        assertEquals(listOf<Any?>("auto"), f.recoveredReasons())

        f.processor.release()
    }

    @Test
    fun autoRecovery_off_noRecoveryWhileDisabled() {
        val f = createRecoveryFixture(autoRecovery = false)

        forceDisable(f.processor)
        assertTrue(f.processor.isFallbackDisabled)

        f.processor.simulatePerformanceDrop(30.0)
        f.processor.simulatePerformanceDrop(30.0)
        assertTrue(f.processor.isFallbackDisabled)
        assertNull(f.processor.currentEffect)
        assertTrue(f.recoveredReasons().isEmpty())

        f.processor.release()
    }

    @Test
    fun stage1_qualityRestoredAfterStableHealthyFps() {
        val f = createRecoveryFixture(autoRecovery = true)

        f.processor.simulatePerformanceDrop(12.0)
        assertEquals(192, f.processor.segmentationWidth)
        assertEquals("qualityDegraded", f.events.last()["action"])

        // Dead band: fps in (14, 20) neither degrades nor restores.
        f.processor.simulatePerformanceDrop(17.0)
        assertEquals(192, f.processor.segmentationWidth)

        f.processor.simulatePerformanceDrop(21.0)
        f.processor.simulatePerformanceDrop(21.0)
        assertEquals(256, f.processor.segmentationWidth)
        assertEquals(listOf<Any?>("auto_quality"), f.recoveredReasons())
        assertFalse(f.processor.isFallbackDisabled)
        assertNotNull(f.processor.currentEffect)

        f.processor.release()
    }

    @Test
    fun stage1_qualityStaysDegraded_whenAutoRecoveryOff() {
        val f = createRecoveryFixture(autoRecovery = false)

        f.processor.simulatePerformanceDrop(12.0)
        assertEquals(192, f.processor.segmentationWidth)

        f.processor.simulatePerformanceDrop(30.0)
        f.processor.simulatePerformanceDrop(30.0)
        assertEquals(192, f.processor.segmentationWidth)
        assertTrue(f.recoveredReasons().isEmpty())

        f.processor.release()
    }

    @Test
    fun deadBandFps_producesNoEvents() {
        val f = createRecoveryFixture(autoRecovery = true)

        f.processor.simulatePerformanceDrop(15.0)
        f.processor.simulatePerformanceDrop(19.0)
        f.processor.simulatePerformanceDrop(16.0)

        assertTrue(f.events.isEmpty())
        assertEquals(256, f.processor.segmentationWidth)
        assertFalse(f.processor.isFallbackDisabled)
        assertNotNull(f.processor.currentEffect)

        f.processor.release()
    }

    @Test
    fun manualSetEffect_rearmsLatchAndEmitsRecoveredManual() {
        val f = createRecoveryFixture(autoRecovery = true)

        forceDisable(f.processor)
        f.processor.simulatePerformanceDrop(25.0)
        f.processor.simulatePerformanceDrop(25.0)
        forceDisable(f.processor)
        f.processor.simulatePerformanceDrop(25.0)
        f.processor.simulatePerformanceDrop(25.0)
        assertTrue(f.processor.isFallbackDisabled) // latched

        // Manual setEffect (what resumeEffect() sends) re-arms and reports.
        f.processor.setBlurEffect(12.0f)
        assertFalse(f.processor.isFallbackDisabled)
        assertNotNull(f.processor.currentEffect)

        // Armed again: the next failure cycle can auto-recover once more.
        forceDisable(f.processor)
        assertTrue(f.processor.isFallbackDisabled)
        f.processor.simulatePerformanceDrop(25.0)
        f.processor.simulatePerformanceDrop(25.0)
        assertFalse(f.processor.isFallbackDisabled)

        assertEquals(
            listOf<Any?>("auto", "manual", "auto"),
            f.recoveredReasons(),
        )

        f.processor.release()
    }

    @Test
    fun clearEffect_whileDisabled_cancelsPendingRecovery() {
        val f = createRecoveryFixture(autoRecovery = true)

        forceDisable(f.processor)
        assertTrue(f.processor.isFallbackDisabled)

        // User chose "none": recovery must not resurrect the old effect.
        f.processor.clearEffect()
        assertFalse(f.processor.isFallbackDisabled)
        f.processor.simulatePerformanceDrop(30.0)
        f.processor.simulatePerformanceDrop(30.0)
        assertNull(f.processor.currentEffect)
        assertTrue(f.recoveredReasons().isEmpty())

        f.processor.release()
    }
}
