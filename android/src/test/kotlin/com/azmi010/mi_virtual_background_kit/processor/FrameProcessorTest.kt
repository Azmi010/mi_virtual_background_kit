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
import kotlin.test.assertNotNull
import kotlin.test.assertNull
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
        var released = false
        var composeBlurCalls = 0
        var composeColorCalls = 0
        var composeImageCalls = 0
        var lastRadius: Float? = null
        var lastColor: Int? = null
        var lastFit: String? = null
        var lastUploadedBitmap: Bitmap? = null

        override fun readBackRgba(buffer: VideoFrame.TextureBuffer): ByteArray? = ByteArray(16)
        override fun uploadMask(mask: PersonMask) {
            hasMask = true
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
}
