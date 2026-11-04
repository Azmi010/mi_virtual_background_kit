package com.azmi010.mi_virtual_background_kit.spike

import android.graphics.Bitmap
import android.graphics.Color
import java.io.File
import java.nio.ByteBuffer

/**
 * Spike T0.6: dump a segmentation mask as a PNG overlay for visual edge
 * quality comparison.
 *
 * Person pixels are tinted green at 50% over the source frame so edge
 * behaviour (halo, holes, temporal noise) can be judged side by side.
 */
object SpikeMaskOverlay {

    /**
     * Saves an overlay for a MediaPipe category mask.
     *
     * The buffer is either UINT8 (one category byte per pixel, capacity w*h)
     * or FLOAT32 (confidence, capacity w*h*4). Any value != 0 counts as
     * "person" for UINT8; >= 0.5 for FLOAT32.
     */
    fun saveCategory(
        source: Bitmap,
        maskBuffer: ByteBuffer,
        maskWidth: Int,
        maskHeight: Int,
        outFile: File,
    ): String {
        require(maskWidth > 0 && maskHeight > 0) { "mask has no size" }
        val cap = maskBuffer.capacity()
        android.util.Log.i(
            "MiVBGSpike",
            "saveCategory cap=$cap needU8=${maskWidth * maskHeight} " +
                "needF32=${maskWidth * maskHeight * 4} " +
                "first=${(0 until minOf(8, cap)).joinToString { maskBuffer.get(it).toString() }}",
        )
        if (cap == maskWidth * maskHeight) {
            val counts = IntArray(256)
            for (i in 0 until cap) {
                counts[maskBuffer.get(i).toInt() and 0xFF]++
            }
            val others = counts.indices.filter { it != 0 && it != 1 && it != 255 }
                .filter { counts[it] > 0 }
            android.util.Log.i(
                "MiVBGSpike",
                "saveCategory hist v0=${counts[0]} v1=${counts[1]} v255=${counts[255]} " +
                    "others=${others.joinToString { "$it:${counts[it]}" }}",
            )
        }
        return when (cap) {
            maskWidth * maskHeight -> {
                // selfie_segmenter.tflite category mask empirically encodes
                // person=0, background=255 (verified via value histogram on a
                // no-person frame: all 255; head-on frame: head = 0).
                blendAndSave(source, maskWidth, maskHeight, outFile) { i ->
                    maskBuffer.get(i).toInt() == 0
                }
            }
            in (maskWidth * maskHeight * 4)..Int.MAX_VALUE -> {
                val floats = maskBuffer.asFloatBuffer()
                blendAndSave(source, maskWidth, maskHeight, outFile) { i ->
                    floats.get(i) >= 0.5f
                }
            }
            else -> throw IllegalArgumentException(
                "unexpected mask capacity $cap for ${maskWidth}x$maskHeight",
            )
        }
    }

    private inline fun blendAndSave(
        source: Bitmap,
        maskWidth: Int,
        maskHeight: Int,
        outFile: File,
        isPerson: (Int) -> Boolean,
    ): String {
        val base = if (source.width == maskWidth && source.height == maskHeight) {
            source
        } else {
            Bitmap.createScaledBitmap(source, maskWidth, maskHeight, true)
        }
        val pixels = IntArray(maskWidth * maskHeight)
        base.getPixels(pixels, 0, maskWidth, 0, 0, maskWidth, maskHeight)
        for (i in pixels.indices) {
            if (!isPerson(i)) continue
            val s = pixels[i]
            val r = Color.red(s) / 2
            val g = (Color.green(s) + 255) / 2
            val b = Color.blue(s) / 2
            pixels[i] = (s and 0xFF000000.toInt()) or (r shl 16) or (g shl 8) or b
        }
        val out = Bitmap.createBitmap(pixels, maskWidth, maskHeight, Bitmap.Config.ARGB_8888)
        outFile.parentFile?.mkdirs()
        outFile.outputStream().use { out.compress(Bitmap.CompressFormat.PNG, 100, it) }
        if (out != source) out.recycle()
        return outFile.absolutePath
    }
}
