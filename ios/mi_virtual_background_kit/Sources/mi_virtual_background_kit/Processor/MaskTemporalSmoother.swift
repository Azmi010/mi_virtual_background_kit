import Foundation

/// Temporal smoothing of the person mask between segmentation runs (FR-20,
/// ADR 0002 §7), plus flicker/ghosting metrics for the `T133|` log lines.
///
/// Mirror of Android's `MaskTemporalSmoother` — keep formulas in sync.
///
/// Modes:
/// - `none`: upload the raw mask unchanged (v0.1 baseline).
/// - `ema`: `out = prev * s + raw * (1 - s)`; s = 0 behaves like `none`.
/// - `adaptive`: like `ema`, but the history weight drops toward 0 while the
///   mask changes fast (mean |raw - prevOut|), so fast motion pulls the fresh
///   mask in and avoids ghosting.
///
/// Metrics per mask (for the `T133|` log lines, parsed by
/// `tool/smoothing_metrics.py`); `dPct < 0` marks the warmup mask after a
/// reset (metrics not comparable yet):
/// - `rev`: pixels whose class went A -> B -> A across the last three masks
///   (edge flicker signature; sustained motion moves in one direction).
/// - `chg`: pixels whose class changed vs the previous mask.
/// - `dPct`: mean |raw - prevOut| in percent of 0..255 (innovation).
/// - `lagPct`: mean |out - raw| in percent (ghosting proxy).
///
/// Steady state allocates nothing; the returned `alpha` must be consumed
/// before the next `process` call (upload happens synchronously).
final class MaskTemporalSmoother {

    struct Result {
        let alpha: [UInt8]
        let rev: Int
        let chg: Int
        let dPct: Float
        let lagPct: Float
        let us: UInt64
    }

    /// Innovation (0..1 mean abs diff) above which `adaptive` stops smoothing.
    static let adaptiveD0: Float = 0.06

    private let lock = NSLock()
    private var prevOut: [Float] = []
    private var binPrev: [UInt8] = []
    private var binPrev2: [UInt8] = []
    private var valid = false

    /// Drops history so the next mask re-establishes state (effect/quality switch).
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        valid = false
    }

    func process(raw: [UInt8], mode: String, value: Float, d0: Float = MaskTemporalSmoother.adaptiveD0) -> Result {
        lock.lock()
        defer { lock.unlock() }
        let startNs = DispatchTime.now().uptimeNanoseconds
        let size = raw.count
        if prevOut.count != size {
            prevOut = [Float](repeating: 0, count: size)
            binPrev = [UInt8](repeating: 0, count: size)
            binPrev2 = [UInt8](repeating: 0, count: size)
            valid = false
        }

        // d: innovation of the raw mask vs the currently displayed output.
        var dPct: Float = -1
        if valid {
            var dSum = 0.0
            for i in 0..<size {
                dSum += abs(Double(raw[i]) - Double(prevOut[i]))
            }
            dPct = Float(dSum / Double(size) / 255.0 * 100.0)
        }

        let s = min(max(value, 0), 1)
        let sEff: Float
        if !valid || mode == "none" {
            sEff = 0
        } else if mode == "adaptive" {
            let dNorm = dPct / 100
            let clipped = min(max(dNorm / max(d0, 0.000001), 0), 1)
            sEff = min(max(s * (1 - clipped), 0), 1)
        } else {
            sEff = s
        }

        var rev = 0
        var chg = 0
        var lagSum = 0.0
        if valid {
            for i in 0..<size {
                let r = Float(raw[i])
                let f = prevOut[i] + (r - prevOut[i]) * (1 - sEff)
                var ob = Int(f + 0.5)
                if ob < 0 { ob = 0 } else if ob > 255 { ob = 255 }
                let c0 = ob >= 128
                let c1 = Int(binPrev[i]) >= 128
                let c2 = Int(binPrev2[i]) >= 128
                if c1 != c0 { chg += 1 }
                if c2 == c0 && c1 != c0 { rev += 1 }
                lagSum += abs(Double(f - r))
                prevOut[i] = f
                // t-2 slot holds stale data; it becomes the new t bin below.
                binPrev2[i] = UInt8(ob)
            }
            swap(&binPrev, &binPrev2)
        } else {
            for i in 0..<size {
                let r = Float(raw[i])
                prevOut[i] = r
                binPrev[i] = raw[i]
                binPrev2[i] = raw[i]
            }
        }
        valid = true

        let lagPct = size > 0 ? Float(lagSum / Double(size) / 255.0 * 100.0) : 0
        let us = (DispatchTime.now().uptimeNanoseconds - startNs) / 1000
        // After the swap binPrev holds the new bins; in the warmup branch those
        // bins were filled from the raw mask, so both cases return the output.
        return Result(alpha: binPrev, rev: rev, chg: chg, dPct: dPct, lagPct: lagPct, us: us)
    }
}
