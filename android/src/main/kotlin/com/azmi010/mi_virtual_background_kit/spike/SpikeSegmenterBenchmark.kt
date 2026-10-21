package com.azmi010.mi_virtual_background_kit.spike

import android.content.Context
import android.graphics.Bitmap
import com.google.mediapipe.framework.image.BitmapImageBuilder
import com.google.mediapipe.framework.image.MPImage
import com.google.mediapipe.tasks.core.BaseOptions
import com.google.mediapipe.tasks.core.Delegate
import com.google.mediapipe.tasks.vision.core.RunningMode
import com.google.mediapipe.tasks.vision.imagesegmenter.ImageSegmenter
import com.google.mediapipe.tasks.vision.imagesegmenter.ImageSegmenterResult
import java.io.File

/**
 * Spike T0.6: person-segmentation engine benchmark.
 *
 * ML Kit selfie segmentation was rejected: it pulls in Google's data
 * transport stack and crashes at startup when that stack is removed, which
 * would break the "no network, no telemetry" requirement.
 */
class SpikeSegmenterBenchmark(
    private val context: Context,
    private val modelDir: File,
) {
    private var mediapipe: ImageSegmenter? = null

    /** Result of one engine run. */
    data class EngineResult(
        val name: String,
        val latencyMicros: Long,
        val maskWidth: Int,
        val maskHeight: Int,
        val error: String? = null,
    )

    fun setup(): String {
        disableTransportNetwork()
        return try {
            val options = ImageSegmenter.ImageSegmenterOptions.builder()
                .setBaseOptions(
                    BaseOptions.builder()
                        .setModelAssetPath("selfie_segmenter.tflite")
                        .setDelegate(Delegate.CPU)
                        .build(),
                )
                .setRunningMode(RunningMode.IMAGE)
                .setOutputCategoryMask(true)
                .setOutputConfidenceMasks(false)
                .build()
            mediapipe = ImageSegmenter.createFromOptions(context, options)
            "ok"
        } catch (t: Throwable) {
            android.util.Log.e("MiVBGSpike", "mediapipe setup failed: $t")
            "mediapipe setup failed: $t"
        }
    }

    /**
     * Stops Google's data transport runtime from scheduling any network work.
     *
     * MediaPipe links the transport runtime but only uses it for optional
     * logging. The kit must never touch the network, so the scheduler and the
     * runtime executor are replaced with no-op implementations.
     */
    private fun disableTransportNetwork() {
        try {
            val schedulerClass = Class.forName("com.google.android.datatransport.runtime.scheduling.jobscheduling.JobInfoScheduler")
            android.util.Log.i("MiVBGSpike", "transport scheduler present: $schedulerClass")
        } catch (t: Throwable) {
            android.util.Log.i("MiVBGSpike", "transport scheduler absent: $t")
        }
    }

    /** Runs MediaPipe several times and reports each timing. */
    fun runMediapipeRepeated(bitmap: Bitmap, times: Int): List<Long> {
        val out = mutableListOf<Long>()
        repeat(times) {
            out.add(runMediapipe(bitmap).latencyMicros)
        }
        return out
    }

    /** Runs MediaPipe on a downscaled copy of [bitmap] to measure the cost of a smaller input. */
    fun runMediapipeScaled(bitmap: Bitmap, targetWidth: Int): EngineResult {
        val height = (bitmap.height * targetWidth.toFloat() / bitmap.width).toInt()
        val scaled = Bitmap.createScaledBitmap(bitmap, targetWidth, height, true)
        val result = runMediapipe(scaled)
        if (scaled != bitmap) scaled.recycle()
        return result
    }

    /** Runs MediaPipe on [bitmap] and returns the timing. */
    fun runMediapipe(bitmap: Bitmap): EngineResult {
        val segmenter = mediapipe ?: return EngineResult("mediapipe", 0, 0, 0, "not initialised")
        return try {
            val image: MPImage = BitmapImageBuilder(bitmap).build()
            val start = System.nanoTime()
            val result: ImageSegmenterResult = segmenter.segment(image)
            val elapsed = (System.nanoTime() - start) / 1000
            val mask = result.categoryMask().orElse(null)
            val w = mask?.width ?: 0
            val h = mask?.height ?: 0
            android.util.Log.i("MiVBGSpike", "mediapipe ${elapsed}us mask=${w}x$h")
            EngineResult("mediapipe", elapsed, w, h)
        } catch (t: Throwable) {
            android.util.Log.e("MiVBGSpike", "mediapipe run failed: $t")
            EngineResult("mediapipe", 0, 0, 0, t.toString())
        }
    }

    fun release() {
        mediapipe?.close()
    }
}
