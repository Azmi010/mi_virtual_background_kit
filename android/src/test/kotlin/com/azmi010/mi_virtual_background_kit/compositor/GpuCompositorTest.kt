package com.azmi010.mi_virtual_background_kit.compositor

import android.graphics.Matrix
import android.os.Looper
import org.mockito.Mockito
import org.webrtc.TextureBufferImpl
import org.webrtc.VideoFrame
import org.webrtc.YuvConverter
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertSame
import kotlin.test.assertTrue

internal class GpuCompositorTest {

    @Test
    fun progressiveBlurSteps_reconstructSigmaRadiusPixels() {
        // sigma^2 at half-res chain = 5.3588 * (s^2 + (2s)^2 + (4s)^2);
        // full-res equivalent sigma = 2 * sigma_half must equal the API radius,
        // the same semantics as iOS CIImage.applyingGaussianBlur(sigma:).
        for (radius in floatArrayOf(5f, 10f, 20f, 50f, 100f)) {
            val steps = GpuCompositor.progressiveBlurSteps(radius)
            assertEquals(3, steps.size)
            val sigmaHalfSquared = 5.3588f * steps[0] * steps[0] * 21f
            val sigmaFull = 2f * kotlin.math.sqrt(sigmaHalfSquared)
            assertEquals(radius, sigmaFull, radius * 0.01f, "radius=$radius")
        }
    }

    @Test
    fun progressiveBlurSteps_doubleProgressionAndMonotonicGrowth() {
        val small = GpuCompositor.progressiveBlurSteps(5f)
        val large = GpuCompositor.progressiveBlurSteps(50f)

        assertEquals(small[0] * 2f, small[1], 1e-6f)
        assertEquals(small[0] * 4f, small[2], 1e-6f)
        assertTrue(small[0] > 0f)
        assertTrue(large[0] > small[0] * 9f)
    }

    // --- T14.7: encoder-path regression (T7.4 crash) ---

    /**
     * Reproduces the T7.4 root cause: an output buffer with a null
     * toI420Handler NPEs inside `ThreadUtils.invokeAtFrontUninterruptibly`
     * (first instruction: `handler.getLooper()`) — over JNI in production
     * this aborts the native encoder. The NPE happens before any GL work, so
     * the detector runs fine on the JVM.
     */
    @Test
    fun toI420_withNullHandler_throwsNpe_insteadOfSilentlyPassing() {
        val buffer = TextureBufferImpl(
            640,
            480,
            VideoFrame.TextureBuffer.Type.RGB,
            1,
            Matrix(),
            null,
            YuvConverter(),
            Runnable {},
        )
        assertNull(buffer.getToI420Handler())

        assertFailsWith<NullPointerException> { buffer.toI420() }
    }

    /**
     * The fix: every composited output buffer is built via
     * `GpuCompositor.createOutBuffer`, which binds a non-null handler from
     * `outBufferHandler()` — the exact property the encoder requires.
     */
    @Test
    fun createOutBuffer_bindsNonNullHandler() {
        val mockedStatic = Mockito.mockStatic(Looper::class.java)
        try {
            val looper = Mockito.mock(Looper::class.java)
            mockedStatic.`when`<Looper> { Looper.myLooper() }.thenReturn(looper)

            val compositor = GpuCompositor()
            val buffer = compositor.createOutBuffer(640, 480, 7)

            assertNotNull(buffer.getToI420Handler())
            assertEquals(640, buffer.width)
            assertEquals(480, buffer.height)
            assertEquals(7, buffer.getTextureId())
        } finally {
            mockedStatic.close()
        }
    }

    /**
     * Without a Looper on the calling thread `outBufferHandler()` degrades to
     * null rather than crashing the compositor itself; the detector test above
     * documents what a null handler means for `toI420()`.
     */
    @Test
    fun createOutBuffer_withoutLooper_returnsNullHandlerWithoutCrashing() {
        val compositor = GpuCompositor()
        val buffer = compositor.createOutBuffer(320, 240, 3)

        assertNull(buffer.getToI420Handler())
        assertEquals(320, buffer.width)
    }
}
