package com.azmi010.mi_virtual_background_kit.processor

import com.cloudwebrtc.webrtc.video.LocalVideoTrack
import org.mockito.Mockito
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertSame
import kotlin.test.assertTrue

/*
 * T14.1 (ADR 0002 §6): resolveWiredTrack must pick the wrapper the
 * VideoSource actually feeds, and degrade to the registry wrapper — never
 * crash — when the private flutter_webrtc layout it walks is not there.
 */

// Fakes mirror the private flutter_webrtc field layout walked by
// resolveWiredTrack. Top-level internal so reflection sees public classes,
// matching the real Java types.
internal class ProbeRoot {
    @JvmField val methodCallHandler: ProbeHandler = ProbeHandler()
}

internal class ProbeHandler {
    @JvmField val getUserMediaImpl: ProbeGum = ProbeGum()
}

internal class ProbeGum {
    var info: ProbeInfo = ProbeInfo()
    fun getCapturerInfo(trackId: String): ProbeInfo = info
}

internal class ProbeInfo {
    @JvmField var primaryTrackId: Any? = null
    @JvmField var videoSource: ProbeSource = ProbeSource()
}

internal class ProbeSource {
    @JvmField var videoProcessor: Any? = null
}

internal class SharedTrackProbeTest {

    private val registry: LocalVideoTrack = Mockito.mock(LocalVideoTrack::class.java)
    private val wired: LocalVideoTrack = Mockito.mock(LocalVideoTrack::class.java)

    private fun graph(videoProcessor: Any?, primaryTrackId: Any? = null): ProbeRoot {
        val root = ProbeRoot()
        root.methodCallHandler.getUserMediaImpl.info.let { info ->
            info.primaryTrackId = primaryTrackId
            info.videoSource.videoProcessor = videoProcessor
        }
        return root
    }

    @Test
    fun noSingleton_degradesToRegistry() {
        val result = resolveWiredTrack("t1", registry, pluginRoot = null)
        assertSame(registry, result.target)
        assertEquals("direct", result.action)
        assertFalse(result.shared)
    }

    @Test
    fun reflectionFailure_degradesToRegistry() {
        // A flutter_webrtc version without the private fields must not crash.
        val result = resolveWiredTrack("t1", registry, pluginRoot = Any())
        assertSame(registry, result.target)
        assertEquals("direct", result.action)
    }

    @Test
    fun sourceProcessorIsRegistry_direct() {
        val root = graph(videoProcessor = registry)
        val result = resolveWiredTrack("t1", registry, pluginRoot = root)
        assertSame(registry, result.target)
        assertEquals("direct", result.action)
        assertFalse(result.shared)
    }

    @Test
    fun sourceProcessorDiffers_redirectsAndFlagsShared() {
        val root = graph(videoProcessor = wired, primaryTrackId = "t1")
        val result = resolveWiredTrack("t1", registry, pluginRoot = root)
        assertSame(wired, result.target)
        assertEquals("redirect", result.action)
        assertTrue(result.shared)
    }

    @Test
    fun sourceNotWired_degradesToRegistry() {
        val root = graph(videoProcessor = null)
        val result = resolveWiredTrack("t1", registry, pluginRoot = root)
        assertSame(registry, result.target)
        assertEquals("direct", result.action)
        assertFalse(result.shared)
    }
}
