package com.azmi010.mi_virtual_background_kit.compositor

import kotlin.test.Test
import kotlin.test.assertEquals
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
}
