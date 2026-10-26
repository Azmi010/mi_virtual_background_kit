package com.azmi010.mi_virtual_background_kit.segmentation

import java.nio.ByteBuffer

/**
 * Converts a MediaPipe category mask into alpha bytes (255 = person).
 *
 * selfie_segmenter.tflite encodes UINT8 person=0, background=255 — verified
 * by histogram on frames with and without a person (ADR 0001 §3). A FLOAT32
 * confidence mask uses person >= 0.5. The predicate must not be inverted:
 * `value != 0` marks the background.
 */
internal object MaskCodec {

    /** Writes the mask into [out] and returns it; [out].size must be >= w*h. */
    fun toAlpha(src: ByteBuffer, width: Int, height: Int, out: ByteArray): ByteArray {
        require(width > 0 && height > 0) { "mask has no size ${width}x$height" }
        val pixels = width * height
        require(out.size >= pixels) { "output buffer too small for ${width}x$height" }
        when {
            src.capacity() == pixels -> {
                for (i in 0 until pixels) {
                    out[i] = if (src.get(i).toInt() == 0) 0xFF.toByte() else 0
                }
            }
            src.capacity() >= pixels * 4 -> {
                val floats = src.asFloatBuffer()
                for (i in 0 until pixels) {
                    out[i] = if (floats.get(i) >= 0.5f) 0xFF.toByte() else 0
                }
            }
            else -> throw IllegalArgumentException(
                "unexpected mask capacity ${src.capacity()} for ${width}x$height",
            )
        }
        return out
    }
}
