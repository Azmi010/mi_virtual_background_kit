package com.azmi010.mi_virtual_background_kit.processor

import android.util.Log
import com.cloudwebrtc.webrtc.LocalTrack
import com.cloudwebrtc.webrtc.video.LocalVideoTrack
import org.webrtc.VideoFrame
import java.util.concurrent.atomic.AtomicInteger

/**
 * Frame processor for local camera tracks, installed at the flutter_webrtc
 * hook point proven in spike T0.4 (Android `addProcessor`, frame arrives on
 * the capture thread as a GPU texture buffer).
 *
 * v0.1 shape: counts frames and passes them through untouched; the effect
 * pipeline (segmentation + GPU composite, T3.3+) plugs in here per frame.
 * Never blocks: onFrame must return within the capture budget.
 */
class FrameProcessor : LocalVideoTrack.ExternalVideoFrameProcessing {

    private val frames = AtomicInteger(0)

    val frameCount: Int get() = frames.get()

    override fun onFrame(frame: VideoFrame): VideoFrame {
        val n = frames.incrementAndGet()
        if (n == 1 || n % 150 == 0) {
            Log.i(
                TAG,
                "frame pass #$n ${frame.rotatedWidth}x${frame.rotatedHeight} " +
                    "rot=${frame.rotation} buffer=${frame.buffer.javaClass.simpleName}",
            )
        }
        return frame
    }

    companion object {
        private const val TAG = "MiVBG"
    }
}

/**
 * Installs [processor] on the flutter_webrtc local track with [trackId].
 *
 * ADR 0001 §1 contract: the returned [LocalVideoTrack] must be cached by the
 * caller — `stream.getMediaTracks()` from Dart replaces the registry entry
 * with a fresh object, so re-looking the track up by id afterwards attaches
 * to nothing (silent no-op).
 */
internal fun attachFrameProcessor(trackId: String, processor: FrameProcessor): LocalVideoTrack? {
    val plugin = com.cloudwebrtc.webrtc.FlutterWebRTCPlugin.sharedSingleton
        ?: return null
    val track = plugin.getLocalTrack(trackId)
    if (track !is LocalVideoTrack) return null
    track.addProcessor(processor)
    return track
}

/** Removes [processor] from [track]; no-op when either side is gone. */
internal fun detachFrameProcessor(track: LocalVideoTrack?, processor: FrameProcessor?) {
    if (track != null && processor != null) track.removeProcessor(processor)
}
