package com.azmi010.mi_virtual_background_kit.processor

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/** T14.2 (FR-20): temporal mask smoothing math and metrics. */
class MaskTemporalSmootherTest {

    private fun mask(fill: Int, size: Int = 16): ByteArray = ByteArray(size) { fill.toByte() }

    @Test
    fun firstMaskIsWarmup_outputEqualsRaw() {
        val s = MaskTemporalSmoother()
        val res = s.process(mask(0), "ema", 0.5f)
        assertEquals(-1f, res.dPct, 0.001f)
        assertTrue(res.alpha.contentEquals(mask(0)))
        assertEquals(0, res.rev)
        assertEquals(0, res.chg)
    }

    @Test
    fun noneMode_uploadsRawUnchanged() {
        val s = MaskTemporalSmoother()
        s.process(mask(0), "none", 0.0f)
        val res = s.process(mask(200), "none", 0.0f)
        assertTrue(res.alpha.contentEquals(mask(200)))
        assertEquals(0f, res.lagPct, 0.001f)
    }

    @Test
    fun reversalCountedOnABAFlicker() {
        val s = MaskTemporalSmoother()
        s.process(mask(0), "none", 0.0f)   // warmup: t0 = background
        s.process(mask(255), "none", 0.0f) // t1 = person (chg, no rev yet)
        val res = s.process(mask(0), "none", 0.0f) // t2 = back to t0 -> flicker
        assertEquals(16, res.chg)
        assertEquals(16, res.rev)
    }

    @Test
    fun emaS0_equalsNone() {
        val s = MaskTemporalSmoother()
        s.process(mask(0), "ema", 0.0f)
        val res = s.process(mask(180), "ema", 0.0f)
        assertTrue(res.alpha.contentEquals(mask(180)))
    }

    @Test
    fun emaHalfWeightMovesHalfwayEachMask() {
        val s = MaskTemporalSmoother()
        s.process(mask(0), "ema", 0.5f)
        // alpha aliases the reused output buffer: read it before the next call.
        val first = s.process(mask(200), "ema", 0.5f)
        val firstVal = first.alpha[0].toInt()
        val firstLag = first.lagPct
        val second = s.process(mask(200), "ema", 0.5f)
        // 0 -> 100 -> 150: converges on the raw value from below.
        assertEquals(100, firstVal)
        assertEquals(150, second.alpha[0].toInt() and 0xFF)
        assertTrue(second.lagPct < firstLag)
    }

    @Test
    fun adaptiveDropsSmoothingOnLargeMotion() {
        val ema = MaskTemporalSmoother()
        val adaptive = MaskTemporalSmoother()
        ema.process(mask(0), "ema", 0.9f)
        adaptive.process(mask(0), "adaptive", 0.9f)
        val emaRes = ema.process(mask(255), "ema", 0.9f)
        val adRes = adaptive.process(mask(255), "adaptive", 0.9f)
        // Full-range jump: adaptive trusts the fresh mask, EMA lags behind it.
        assertTrue(adRes.lagPct < emaRes.lagPct)
        assertTrue(emaRes.lagPct > 50f)
    }

    @Test
    fun largerD0_keepsSmoothingLongerOnMotion() {
        // d for a full-range jump is ~100%: D0 = 0.06 releases smoothing
        // immediately, D0 = 0.12 is no different here — so probe the band
        // between them with a moderate innovation instead (d ~ 10%).
        val strict = MaskTemporalSmoother()
        val loose = MaskTemporalSmoother()
        strict.process(mask(0), "adaptive", 0.9f, d0 = 0.06f)
        loose.process(mask(0), "adaptive", 0.9f, d0 = 0.12f)
        // Jump to 26: d = 26/255 ~ 10.2% > 0.06 but < 0.12.
        val strictRes = strict.process(mask(26), "adaptive", 0.9f, d0 = 0.06f)
        val looseRes = loose.process(mask(26), "adaptive", 0.9f, d0 = 0.12f)
        assertTrue(strictRes.lagPct < looseRes.lagPct)
    }

    @Test
    fun resetRestartsWarmup() {
        val s = MaskTemporalSmoother()
        s.process(mask(0), "ema", 0.5f)
        s.process(mask(100), "ema", 0.5f)
        s.reset()
        val res = s.process(mask(30), "ema", 0.5f)
        assertEquals(-1f, res.dPct, 0.001f)
        assertTrue(res.alpha.contentEquals(mask(30)))
    }

    @Test
    fun metricCostStaysTiny() {
        val s = MaskTemporalSmoother()
        val raw = ByteArray(256 * 192) { (it % 256).toByte() }
        s.process(raw, "ema", 0.5f)
        // Generous bound: 49k pixels of scalar math must stay well under 10 ms.
        assertTrue(s.process(raw, "ema", 0.5f).us < 10_000)
    }
}
