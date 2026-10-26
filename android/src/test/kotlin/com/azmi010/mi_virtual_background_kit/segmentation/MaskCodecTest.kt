package com.azmi010.mi_virtual_background_kit.segmentation

import java.nio.ByteBuffer
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith

internal class MaskCodecTest {

    @Test
    fun uint8_personZero_marksPersonOpaque() {
        // person=0, background=255 encoding: only value 0 counts as person.
        val src = ByteBuffer.wrap(byteArrayOf(0, 1, 0xFF.toByte(), 42))
        val out = MaskCodec.toAlpha(src, 2, 2, ByteArray(4))
        assertEquals(listOf(0xFF.toByte(), 0, 0, 0), out.toList())
    }

    @Test
    fun float32_thresholdHalf_marksPersonOpaque() {
        val src = ByteBuffer.allocate(2 * 2 * 4)
        src.asFloatBuffer().apply {
            put(0f)
            put(0.49f)
            put(0.5f)
            put(1f)
        }
        val out = MaskCodec.toAlpha(src, 2, 2, ByteArray(4))
        assertEquals(listOf(0, 0, 0xFF.toByte(), 0xFF.toByte()), out.toList())
    }

    @Test
    fun unexpectedCapacity_throws() {
        assertFailsWith<IllegalArgumentException> {
            MaskCodec.toAlpha(ByteBuffer.allocate(5), 2, 2, ByteArray(4))
        }
    }

    @Test
    fun zeroSize_throws() {
        assertFailsWith<IllegalArgumentException> {
            MaskCodec.toAlpha(ByteBuffer.allocate(0), 0, 0, ByteArray(0))
        }
    }

    @Test
    fun reusesOutputBuffer() {
        val out = ByteArray(4)
        MaskCodec.toAlpha(ByteBuffer.wrap(byteArrayOf(0, 0, 0, 0)), 2, 2, out)
        val same = MaskCodec.toAlpha(ByteBuffer.wrap(byteArrayOf(-1, -1, -1, -1)), 2, 2, out)
        assertEquals(out, same)
        assertEquals(listOf<Byte>(0, 0, 0, 0), same.toList())
    }
}
