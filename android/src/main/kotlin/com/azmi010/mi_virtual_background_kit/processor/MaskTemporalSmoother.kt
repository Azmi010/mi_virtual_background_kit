package com.azmi010.mi_virtual_background_kit.processor

/**
 * Temporal smoothing of the person mask between segmentation runs (FR-20,
 * ADR 0002 §7), plus flicker/ghosting metrics for the `T133|` log lines.
 *
 * Modes:
 * - `none`      upload the raw mask unchanged (v0.1 baseline).
 * - `ema`       `out = prev * s + raw * (1 - s)`; s = 0 behaves like `none`.
 * - `adaptive`  like `ema` but the history weight drops toward 0 while the mask
 *   is changing fast (measured as mean |raw - prevOut|), so fast motion pulls
 *   the fresh mask in and avoids ghosting.
 *
 * Metrics per mask (for the `T133|` log lines, parsed by
 * `tool/smoothing_metrics.py`):
 * - [Result.rev]  pixels whose class went A -> B -> A across the last three
 *   masks (edge flicker signature; sustained motion moves in one direction).
 * - [Result.chg]  pixels whose class changed vs the previous mask (motion +
 *   flicker upper bound).
 * - [Result.dPct] mean |raw - prevOut| in percent of 0..255 (innovation: how
 *   far the fresh mask is from what is displayed).
 * - [Result.lagPct] mean |out - raw| in percent (ghosting proxy).
 *
 * All buffers are allocated once per mask size; steady state allocates nothing.
 * [Result.alpha] aliases an internal buffer valid until the next [process] call.
 */
class MaskTemporalSmoother {

    data class Result(
        val alpha: ByteArray,
        val rev: Int,
        val chg: Int,
        val dPct: Float,
        val lagPct: Float,
        val us: Long,
    )

    private var prevOut: FloatArray? = null
    private var binPrev: ByteArray? = null
    private var binPrev2: ByteArray? = null
    private var out: ByteArray? = null
    private var valid = false

    /** Drops history so the next mask re-establishes state (effect/quality switch). */
    @Synchronized
    fun reset() {
        valid = false
    }

    @Synchronized
    fun process(raw: ByteArray, mode: String, value: Float, d0: Float = ADAPTIVE_D0): Result {
        val startNs = System.nanoTime()
        val size = raw.size
        if (prevOut?.size != size) {
            prevOut = FloatArray(size)
            binPrev = ByteArray(size)
            binPrev2 = ByteArray(size)
            out = ByteArray(size)
            valid = false
        }
        val prev = prevOut!!
        val b1 = binPrev!!
        val b2 = binPrev2!!
        val o = out!!

        // d: innovation of the raw mask vs the currently displayed output.
        // Alpha bytes are unsigned (0..255); Kotlin Byte is signed.
        var dPct = -1f
        if (valid) {
            var dSum = 0.0
            for (i in 0 until size) {
                dSum += kotlin.math.abs((raw[i].toInt() and 0xFF) - prev[i])
            }
            dPct = ((dSum / size) / 255.0 * 100.0).toFloat()
        }

        val s = value.coerceIn(0f, 1f)
        val sEff = when {
            !valid || mode == "none" -> 0f
            mode == "adaptive" -> {
                val dNorm = dPct / 100f
                (s * (1f - (dNorm / d0.coerceAtLeast(1e-6f)).coerceIn(0f, 1f))).coerceIn(0f, 1f)
            }
            else -> s
        }

        var rev = 0
        var chg = 0
        var lagSum = 0.0
        for (i in 0 until size) {
            val r = (raw[i].toInt() and 0xFF).toFloat()
            val f = if (valid) prev[i] + (r - prev[i]) * (1f - sEff) else r
            val ob = if (valid) {
                (f + 0.5f).toInt().coerceIn(0, 255).toByte()
            } else {
                raw[i]
            }
            o[i] = ob
            prev[i] = f
            if (valid) {
                val c0 = (ob.toInt() and 0xFF) >= 128
                val c1 = (b1[i].toInt() and 0xFF) >= 128
                val c2 = (b2[i].toInt() and 0xFF) >= 128
                if (c1 != c0) chg++
                if (c2 == c0 && c1 != c0) rev++
                lagSum += kotlin.math.abs(f - r)
                // t-2 slot holds stale data; it becomes the new t bin below.
                b2[i] = ob
            } else {
                b1[i] = ob
                b2[i] = ob
            }
        }
        if (valid) {
            // Rotate: bins written above (old b2) now hold t; b1 holds t-1.
            val oldPrev = binPrev
            binPrev = binPrev2
            binPrev2 = oldPrev
        }
        valid = true

        val lagPct = if (size > 0) (lagSum / size) / 255.0 * 100.0 else 0.0
        return Result(
            alpha = o,
            rev = rev,
            chg = chg,
            dPct = dPct,
            lagPct = lagPct.toFloat(),
            us = (System.nanoTime() - startNs) / 1_000,
        )
    }

    companion object {
        /** Innovation (0..1 mean abs diff) above which `adaptive` stops smoothing. */
        const val ADAPTIVE_D0 = 0.06f
    }
}
