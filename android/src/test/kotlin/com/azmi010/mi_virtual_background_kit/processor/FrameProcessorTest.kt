package com.azmi010.mi_virtual_background_kit.processor

import android.graphics.Bitmap
import com.azmi010.mi_virtual_background_kit.compositor.FrameCompositor
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

    private class FakeSegmenter : MaskSegmenter {
        var closed = false
        override fun segment(bitmap: Bitmap): PersonMask = PersonMask(ByteArray(4), 2, 2)
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
        var lastRadius: Float? = null

        override fun readBackRgba(buffer: VideoFrame.TextureBuffer): ByteArray? = ByteArray(16)
        override fun uploadMask(mask: PersonMask) {
            hasMask = true
        }
        override fun composeBlur(frame: VideoFrame, radius: Float): VideoFrame? {
            composeBlurCalls++
            lastRadius = radius
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
        )

        processor.setBlurEffect(20.0f)
        val result = processor.onFrame(inputFrame)

        assertEquals(inputFrame, result)
        assertEquals(1, fakeCompositor.composeBlurCalls)
        assertEquals(20.0f, fakeCompositor.lastRadius)
    }

    @Test
    fun releaseCleansUpResources() {
        val fakeSegmenter = FakeSegmenter()
        val fakeCompositor = FakeCompositor()

        val processor = FrameProcessor(
            segmenterProvider = { fakeSegmenter },
            compositorProvider = { fakeCompositor },
        )

        processor.setBlurEffect(10.0f)
        processor.release()

        assertNull(processor.currentEffect)
        assertTrue(fakeSegmenter.closed)
        assertTrue(fakeCompositor.released)
    }
}
