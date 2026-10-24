package com.azmi010.mi_virtual_background_kit.spike

import android.graphics.Bitmap
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.segmentation.Segmentation
import com.google.mlkit.vision.segmentation.SegmentationMask
import com.google.mlkit.vision.segmentation.Segmenter
import com.google.mlkit.vision.segmentation.selfie.SelfieSegmenterOptions
import java.util.concurrent.CountDownLatch

/**
 * Spike T0.6: ML Kit Selfie Segmentation benchmark, mirror of
 * [SpikeSegmenterBenchmark] so both engines get the same treatment.
 *
 * ML Kit's API is async (Task-based); the latency measured here is the full
 * call-to-result wall time, which is what a frame pipeline would pay.
 */
class SpikeMLKitBenchmark {
    private var client: Segmenter? = null

    /** Last mask, kept so the caller can dump an overlay after a run. */
    @Volatile
    var lastMask: SegmentationMask? = null
        private set

    fun setup(): String {
        return try {
            val options = SelfieSegmenterOptions.Builder()
                .setDetectorMode(SelfieSegmenterOptions.SINGLE_IMAGE_MODE)
                .enableRawSizeMask()
                .build()
            client = Segmentation.getClient(options)
            "ok"
        } catch (t: Throwable) {
            android.util.Log.e("MiVBGSpike", "mlkit setup failed: $t")
            "mlkit setup failed: $t"
        }
    }

    /** Runs ML Kit several times and reports each timing. */
    fun runRepeated(bitmap: Bitmap, times: Int): List<Long> {
        val out = mutableListOf<Long>()
        repeat(times) {
            out.add(run(bitmap).latencyMicros)
        }
        return out
    }

    /** Runs ML Kit on a downscaled copy of [bitmap]. */
    fun runScaled(bitmap: Bitmap, targetWidth: Int): EngineResult {
        val height = (bitmap.height * targetWidth.toFloat() / bitmap.width).toInt()
        val scaled = Bitmap.createScaledBitmap(bitmap, targetWidth, height, true)
        val result = run(scaled)
        if (scaled != bitmap) scaled.recycle()
        return result
    }

    /** Runs ML Kit on [bitmap] and returns the timing. */
    fun run(bitmap: Bitmap): EngineResult {
        val c = client ?: return EngineResult("mlkit", 0, 0, 0, "not initialised")
        return try {
            val image = InputImage.fromBitmap(bitmap, 0)
            val latch = CountDownLatch(1)
            var elapsedMicros = 0L
            var width = 0
            var height = 0
            var error: String? = null
            val start = System.nanoTime()
            c.process(image)
                .addOnSuccessListener { mask: SegmentationMask ->
                    elapsedMicros = (System.nanoTime() - start) / 1000
                    width = mask.width
                    height = mask.height
                    lastMask = mask
                    latch.countDown()
                }
                .addOnFailureListener { e ->
                    error = e.toString()
                    latch.countDown()
                }
            latch.await(60, java.util.concurrent.TimeUnit.SECONDS)
            if (latch.count > 0) {
                error = "timeout: ML Kit task did not complete within 60s"
            }
            android.util.Log.i("MiVBGSpike", "mlkit ${elapsedMicros}us mask=${width}x$height err=${error ?: ""}")
            EngineResult("mlkit", elapsedMicros, width, height, error)
        } catch (t: Throwable) {
            android.util.Log.e("MiVBGSpike", "mlkit run failed: $t")
            EngineResult("mlkit", 0, 0, 0, t.toString())
        }
    }

    fun release() {
        client?.close()
        client = null
        lastMask = null
    }

    /** Result of one engine run. Same shape as the MediaPipe benchmark's. */
    data class EngineResult(
        val name: String,
        val latencyMicros: Long,
        val maskWidth: Int,
        val maskHeight: Int,
        val error: String? = null,
    )
}
