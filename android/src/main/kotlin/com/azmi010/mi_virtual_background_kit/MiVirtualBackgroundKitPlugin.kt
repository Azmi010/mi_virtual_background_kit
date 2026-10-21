package com.azmi010.mi_virtual_background_kit

import com.azmi010.mi_virtual_background_kit.spike.SpikeFrameProcessor
import com.azmi010.mi_virtual_background_kit.spike.SpikeGpuCompositor
import com.azmi010.mi_virtual_background_kit.spike.SpikeSegmenterBenchmark
import com.azmi010.mi_virtual_background_kit.spike.SpikeHook
import com.azmi010.mi_virtual_background_kit.spike.SpikeInvert
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result

/** MiVirtualBackgroundKitPlugin */
class MiVirtualBackgroundKitPlugin :
    FlutterPlugin,
    MethodCallHandler {
    // The MethodChannel that will the communication between Flutter and native Android
    //
    // This local reference serves to register the plugin with the Flutter Engine and unregister it
    // when the Flutter Engine is detached from the Activity
    private lateinit var channel: MethodChannel

    private var spikeProcessor: SpikeFrameProcessor? = null

    private var appContext: android.content.Context? = null

    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        appContext = flutterPluginBinding.applicationContext
        channel = MethodChannel(flutterPluginBinding.binaryMessenger, "mi_virtual_background_kit")
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(
        call: MethodCall,
        result: Result
    ) {
        when (call.method) {
            "getPlatformVersion" -> result.success("Android ${android.os.Build.VERSION.RELEASE}")
            "spikeAttach" -> {
                val trackId = call.argument<String>("trackId")
                if (trackId == null) {
                    result.error("bad_args", "trackId is required", null)
                    return
                }
                val processor = SpikeFrameProcessor { frame -> SpikeInvert.apply(frame) }
                val ok = SpikeHook.attach(trackId, processor)
                if (ok) spikeProcessor = processor
                result.success(ok)
            }
            "spikeFrameCount" -> result.success(spikeProcessor?.frameCount ?: 0)
            "spikeInfo" -> {
                val p = spikeProcessor
                result.success(
                    mapOf(
                        "frames" to (p?.frameCount ?: 0),
                        "bufferType" to (p?.bufferType ?: ""),
                        "rotation" to (p?.rotation ?: 0),
                        "width" to (p?.width ?: 0),
                        "height" to (p?.height ?: 0),
                    ),
                )
            }
            "spikeSetEnabled" -> {
                spikeProcessor?.enabled = call.argument<Boolean>("enabled") ?: true
                result.success(true)
            }
            "spikeBenchmarkReadback" -> {
                android.util.Log.i("MiVBGSpike", "benchmarkReadback requested, processor=${spikeProcessor != null}")
                spikeProcessor?.benchmarkReadback = true
                result.success(true)
            }
            "spikeEnableGpu" -> {
                val enable = call.argument<Boolean>("enabled") ?: true
                val p = spikeProcessor
                if (p == null) {
                    result.error("no_processor", "spike processor not attached", null)
                    return
                }
                if (enable) {
                    if (p.compositor == null) {
                        p.compositor = SpikeGpuCompositor()
                    }
                } else {
                    p.compositor?.release()
                    p.compositor = null
                }
                result.success(true)
            }
            "spikeGpuInfo" -> {
                val gpu = spikeProcessor?.compositor
                result.success(
                    mapOf(
                        "compositeMicros" to (gpu?.compositeMicros ?: 0L),
                        "compositeCount" to (gpu?.compositeCount ?: 0L),
                        "inputType" to (gpu?.lastInputType ?: ""),
                        "readbackMicros" to (gpu?.readbackMicros ?: 0L),
                        "readbackWidth" to (gpu?.readbackWidth ?: 0),
                        "readbackHeight" to (gpu?.readbackHeight ?: 0),
                    ),
                )
            }
            "spikeReadback" -> {
                val p = spikeProcessor
                val gpu = p?.compositor
                val frame = p?.lastFrame
                if (gpu == null || frame == null) {
                    result.error("no_frame", "no frame captured yet", null)
                    return
                }
                val buffer = frame.buffer as? org.webrtc.VideoFrame.TextureBuffer
                if (buffer == null) {
                    result.error("not_texture", "frame is not a texture buffer", null)
                    return
                }
                val bytes = gpu.readBackRgba(buffer)
                result.success(
                    mapOf(
                        "readbackMicros" to (gpu.readbackMicros),
                        "width" to gpu.readbackWidth,
                        "height" to gpu.readbackHeight,
                        "bytes" to (bytes?.size ?: 0),
                    ),
                )
            }
            "spikeSegmentBenchmark" -> {
                val p = spikeProcessor
                val gpu = p?.compositor
                val frame = p?.lastFrame
                if (gpu == null || frame == null) {
                    result.error("no_frame", "no frame captured yet", null)
                    return
                }
                val buffer = frame.buffer as? org.webrtc.VideoFrame.TextureBuffer
                if (buffer == null) {
                    result.error("not_texture", "frame is not a texture buffer", null)
                    return
                }
                val bytes = gpu.readBackRgba(buffer) ?: ByteArray(0)
                if (bytes.isEmpty()) {
                    result.error("readback_failed", "readback returned no data", null)
                    return
                }
                val bitmap = android.graphics.Bitmap.createBitmap(
                    gpu.readbackWidth, gpu.readbackHeight,
                    android.graphics.Bitmap.Config.ARGB_8888,
                )
                bitmap.copyPixelsFromBuffer(java.nio.ByteBuffer.wrap(bytes))

                val bench = SpikeSegmenterBenchmark(appContext!!, java.io.File(appContext!!.filesDir, "spike-models"))
                val setupStatus = bench.setup()
                val scaledResults = listOf(256, 144, 96).map { w ->
                    val r = bench.runMediapipeScaled(bitmap, w)
                    "w=$w t=${r.latencyMicros}us mask=${r.maskWidth}x${r.maskHeight}"
                }
                android.util.Log.i("MiVBGSpike", "scaled $scaledResults")
                val timings = bench.runMediapipeRepeated(bitmap, 3)
                val mp = bench.runMediapipe(bitmap)
                bench.release()
                result.success(
                    mapOf(
                        "setup" to setupStatus,
                        "mediapipeMicros" to mp.latencyMicros,
                        "mediapipeTimings" to timings,
                        "mediapipeMask" to "${mp.maskWidth}x${mp.maskHeight}",
                        "mediapipeError" to (mp.error ?: ""),
                        "readbackMicros" to gpu.readbackMicros,
                        "width" to gpu.readbackWidth,
                        "height" to gpu.readbackHeight,
                    ),
                )
            }
            "spikeDetach" -> {
                val trackId = call.argument<String>("trackId")
                val processor = spikeProcessor
                val ok = if (trackId != null && processor != null) {
                    SpikeHook.detach(trackId, processor)
                } else {
                    false
                }
                spikeProcessor = null
                result.success(ok)
            }
            else -> result.notImplemented()
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }
}
