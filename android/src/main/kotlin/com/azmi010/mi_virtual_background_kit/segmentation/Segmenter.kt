package com.azmi010.mi_virtual_background_kit.segmentation

import android.content.Context
import android.graphics.Bitmap
import com.google.mediapipe.framework.image.BitmapImageBuilder
import com.google.mediapipe.framework.image.ByteBufferExtractor
import com.google.mediapipe.tasks.core.BaseOptions
import com.google.mediapipe.tasks.core.Delegate
import com.google.mediapipe.tasks.vision.core.RunningMode
import com.google.mediapipe.tasks.vision.imagesegmenter.ImageSegmenter

/** FR-08: the segmenter engine or its model could not be prepared (modelLoadFailed). */
class SegmentationException(message: String, cause: Throwable? = null) : Exception(message, cause)

/**
 * Person mask: one alpha byte per pixel, 255 = person.
 *
 * [alpha] is the segmenter's internal buffer and is reused on the next
 * segment() call — copy it out before segmenting another frame.
 */
data class PersonMask(
    val alpha: ByteArray,
    val width: Int,
    val height: Int,
)

/**
 * Common interface for person segmenters.
 */
interface MaskSegmenter : AutoCloseable {
    fun segment(bitmap: Bitmap): PersonMask
    override fun close()
}

/**
 * Person segmentation with MediaPipe Image Segmenter and the bundled
 * model, CPU delegate (ADR 0001 §3, model per ADR 0002 §8).
 *
 * [modelAsset] exists for the T14.5 measurement hook: production always
 * loads [MODEL_ASSET], the example's test page can select the legacy
 * square model for A/B runs.
 */
class Segmenter(
    context: Context,
    modelAsset: String = MODEL_ASSET,
) : MaskSegmenter {

    private val segmenter: ImageSegmenter = try {
        ImageSegmenter.createFromOptions(
            context,
            ImageSegmenter.ImageSegmenterOptions.builder()
                .setBaseOptions(
                    BaseOptions.builder()
                        .setModelAssetPath(modelAsset)
                        .setDelegate(Delegate.CPU)
                        .build(),
                )
                .setRunningMode(RunningMode.IMAGE)
                .setOutputCategoryMask(true)
                .setOutputConfidenceMasks(false)
                .build(),
        )
    } catch (t: Throwable) {
        throw SegmentationException("segmentation model failed to load", t)
    }

    private var alpha = ByteArray(0)

    /**
     * Segments [bitmap]; mask resolution equals the bitmap size.
     * Synchronous — MediaPipe segment() blocks the calling thread.
     */
    override fun segment(bitmap: Bitmap): PersonMask {
        val result = try {
            segmenter.segment(BitmapImageBuilder(bitmap).build())
        } catch (t: Throwable) {
            throw SegmentationException("segmentation failed", t)
        }
        val mask = result.categoryMask().orElse(null)
            ?: throw SegmentationException("segmentation produced no mask")
        val width = mask.width
        val height = mask.height
        if (alpha.size < width * height) alpha = ByteArray(width * height)
        MaskCodec.toAlpha(ByteBufferExtractor.extract(mask), width, height, alpha)
        return PersonMask(alpha, width, height)
    }

    override fun close() = segmenter.close()

    companion object {
        /**
         * Production model (ADR 0002 §8): `selfie_segmenter_landscape`
         * (144×256 float16) — 34% lower inference latency than the legacy
         * square `selfie_segmenter.tflite` at equal quality on low-end
         * hardware (spike T13.4). The square model stays bundled as the
         * T14.5 A/B baseline and is removed once the swap is accepted.
         */
        const val MODEL_ASSET = "selfie_segmenter_landscape.tflite"

        /** Legacy square model, A/B baseline for T14.5 only. */
        const val LEGACY_MODEL_ASSET = "selfie_segmenter.tflite"

        /**
         * Checks whether the bundled production model asset is readable in [context].
         */
        fun isModelAssetAvailable(context: Context): Boolean {
            return try {
                context.assets.open(MODEL_ASSET).use { true }
            } catch (_: Throwable) {
                false
            }
        }
    }
}
