package com.azmi010.mi_virtual_background_kit.spike

import com.cloudwebrtc.webrtc.LocalTrack
import com.cloudwebrtc.webrtc.video.LocalVideoTrack
import org.webrtc.VideoFrame
import java.nio.ByteBuffer

/**
 * Spike T0.4: prove that a frame processor can be installed on a local camera
 * track created by flutter_webrtc and that transformed frames reach the
 * renderer.
 *
 * The transform inverts the U and V planes of an I420 frame, which produces a
 * visible colour shift in the preview.
 */
class SpikeFrameProcessor(
    private val onFrame: (VideoFrame) -> VideoFrame = { it },
) : LocalVideoTrack.ExternalVideoFrameProcessing {

    var frameCount: Int = 0
        private set

    override fun onFrame(frame: VideoFrame): VideoFrame {
        frameCount++
        return try {
            onFrame(frame)
        } catch (t: Throwable) {
            frame
        }
    }
}

/** Installs [processor] on the flutter_webrtc local track with [trackId]. */
object SpikeHook {
    fun attach(trackId: String, processor: SpikeFrameProcessor): Boolean {
        val plugin = com.cloudwebrtc.webrtc.FlutterWebRTCPlugin.sharedSingleton ?: return false
        val track: LocalTrack? = plugin.getLocalTrack(trackId)
        if (track !is LocalVideoTrack) return false
        track.addProcessor(processor)
        return true
    }

    fun detach(trackId: String, processor: SpikeFrameProcessor): Boolean {
        val plugin = com.cloudwebrtc.webrtc.FlutterWebRTCPlugin.sharedSingleton ?: return false
        val track: LocalTrack? = plugin.getLocalTrack(trackId)
        if (track !is LocalVideoTrack) return false
        track.removeProcessor(processor)
        return true
    }
}

/** Inverts the chroma planes of an I420 frame in place. */
object SpikeInvert {
    fun apply(frame: VideoFrame): VideoFrame {
        val buffer = frame.buffer
        if (buffer !is VideoFrame.I420Buffer) return frame
        val width = buffer.getWidth()
        invert(buffer.dataU, buffer.strideU, width)
        invert(buffer.dataV, buffer.strideV, width)
        return frame
    }

    private fun invert(data: ByteBuffer, stride: Int, width: Int) {
        if (!data.isAccessible) return
        val rowBytes = width / 2
        val rows = width / 2
        for (row in 0 until rows) {
            val offset = row * stride
            for (i in 0 until rowBytes) {
                val index = offset + i
                if (index >= data.limit()) continue
                data.put(index, (0xFF - data.get(index).toInt()).toByte())
            }
        }
    }
}
