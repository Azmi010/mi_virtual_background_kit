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
 * Person segmentation with MediaPipe Image Segmenter and the bundled
 * `selfie_segmenter.tflite` model, CPU delegate (ADR 0001 §3).
 */
class Segmenter(context: Context) {

    private val segmenter: ImageSegmenter = try {
        ImageSegmenter.createFromOptions(
            context,
            ImageSegmenter.ImageSegmenterOptions.builder()
                .setBaseOptions(
                    BaseOptions.builder()
                        .setModelAssetPath(MODEL_ASSET)
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
    fun segment(bitmap: Bitmap): PersonMask {
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

    fun close() = segmenter.close()

    companion object {
        const val MODEL_ASSET = "selfie_segmenter.tflite"
    }
}
