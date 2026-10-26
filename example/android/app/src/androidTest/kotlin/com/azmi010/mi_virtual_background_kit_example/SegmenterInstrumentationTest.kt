package com.azmi010.mi_virtual_background_kit_example

import android.graphics.BitmapFactory
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.azmi010.mi_virtual_background_kit.segmentation.Segmenter
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * T3.1: the segmenter engine loads the bundled model and produces a person
 * mask for one camera frame (frame captured in spike T0.6, overlay tint
 * reversed).
 */
@RunWith(AndroidJUnit4::class)
class SegmenterInstrumentationTest {

    @Test
    fun personMaskProducedForOneFrame() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val app = instrumentation.targetContext
        val bitmap = instrumentation.context.assets.open("person_frame.png").use {
            BitmapFactory.decodeStream(it)
        }
        assertTrue("test frame failed to decode", bitmap != null)

        val segmenter = Segmenter(app)
        try {
            val mask = segmenter.segment(bitmap!!)
            val person = mask.alpha.count { it != 0.toByte() }
            assertTrue(
                "expected a person mask, got $person person pixels of ${mask.alpha.size}",
                person > mask.alpha.size / 20,
            )
        } finally {
            segmenter.close()
        }
    }
}
