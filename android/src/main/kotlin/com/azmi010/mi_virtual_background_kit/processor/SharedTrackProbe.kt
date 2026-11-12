package com.azmi010.mi_virtual_background_kit.processor

import android.util.Log
import com.cloudwebrtc.webrtc.FlutterWebRTCPlugin
import com.cloudwebrtc.webrtc.video.LocalVideoTrack

/** Result of [resolveWiredTrack]: where to install the frame processor. */
internal data class WiredTrack(
    val target: LocalVideoTrack,
    val action: String,
    val shared: Boolean,
)

/**
 * Finds the LocalVideoTrack whose frames actually flow for [trackId]
 * (ADR 0002 §6, spike T13.2 — doc/spike-results.md bagian T13.2).
 *
 * flutter_webrtc wires a LocalVideoTrack as its VideoSource's videoProcessor
 * only when the camera is created. Two later paths hand out fresh, unwired
 * wrappers instead: a shared track (second getUserMedia on an open camera,
 * `buildSharedVideoTrack`) and a registry replacement after Dart calls
 * `stream.getMediaTracks()`. `addProcessor` on an unwired wrapper is a silent
 * no-op — attach reports success while no frame is ever processed.
 *
 * shortcut: reaches private flutter_webrtc fields, pinned to flutter_webrtc
 * ^1.6.2 — on a version where reflection fails it returns the registry
 * wrapper (the pre-T14.1 behavior) so attach degrades instead of breaking.
 */
internal fun resolveWiredTrack(
    trackId: String,
    registry: LocalVideoTrack,
    pluginRoot: Any? = FlutterWebRTCPlugin.sharedSingleton,
): WiredTrack {
    fun degrade(reason: String, shared: Boolean = false): WiredTrack {
        Log.i("MiVBG", "T132| probe track=$trackId action=direct reason=$reason shared=$shared")
        return WiredTrack(registry, "direct", shared)
    }

    if (pluginRoot == null) return degrade("no-singleton")
    try {
        val handlerField = pluginRoot.javaClass.getDeclaredField("methodCallHandler")
        handlerField.isAccessible = true
        val handler = handlerField.get(pluginRoot) ?: return degrade("no-methodCallHandler")
        val gumField = handler.javaClass.getDeclaredField("getUserMediaImpl")
        gumField.isAccessible = true
        val gum = gumField.get(handler) ?: return degrade("no-getUserMediaImpl")
        val info = gum.javaClass
            .getMethod("getCapturerInfo", String::class.java)
            .invoke(gum, trackId) ?: return degrade("no-capturer-info")
        val shared = info.javaClass.getField("primaryTrackId").get(info) != null
        val source = info.javaClass.getField("videoSource").get(info)
            ?: return degrade("no-video-source", shared)
        val processorField = source.javaClass.getDeclaredField("videoProcessor")
        processorField.isAccessible = true
        val wired = processorField.get(source) as? LocalVideoTrack
        return when (wired) {
            null -> degrade("source-not-wired", shared)
            registry -> {
                Log.i("MiVBG", "T132| probe track=$trackId action=direct shared=$shared")
                WiredTrack(registry, "direct", shared)
            }
            else -> {
                Log.i(
                    "MiVBG",
                    "T132| probe track=$trackId action=redirect target=${wired.id()} shared=$shared",
                )
                WiredTrack(wired, "redirect", shared)
            }
        }
    } catch (e: ReflectiveOperationException) {
        return degrade("reflection-failed: $e")
    } catch (e: SecurityException) {
        return degrade("denied: $e")
    }
}
