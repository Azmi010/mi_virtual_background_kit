package com.azmi010.mi_virtual_background_kit

import com.azmi010.mi_virtual_background_kit.spike.SpikeFrameProcessor
import com.azmi010.mi_virtual_background_kit.spike.SpikeGpuCompositor
import com.azmi010.mi_virtual_background_kit.spike.SpikeMLKitBenchmark
import com.azmi010.mi_virtual_background_kit.spike.SpikeMaskOverlay
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
                if (p == null || gpu == null) {
                    result.error("no_frame", "no frame captured yet", null)
                    return
                }
                if (!p.requestReadback()) {
                    result.error("readback_timeout", "capture thread did not deliver a frame in 3s", null)
                    return
                }
                val bytes = p.readbackBytes
                if (bytes == null) {
                    result.error("readback_failed", "readback returned no data", null)
                    return
                }
                result.success(
                    mapOf(
                        "readbackMicros" to (gpu.readbackMicros),
                        "width" to gpu.readbackWidth,
                        "height" to gpu.readbackHeight,
                        "bytes" to bytes.size,
                    ),
                )
            }
            "spikeSegmentBenchmark" -> {
                val p = spikeProcessor
                val gpu = p?.compositor
                if (p == null || gpu == null) {
                    result.error("no_frame", "no frame captured yet", null)
                    return
                }
                // Readback must happen on the capture thread (EGL context
                // owner); request it and wait for the next frame.
                if (!p.requestReadback()) {
                    result.error("readback_timeout", "capture thread did not deliver a frame in 3s", null)
                    return
                }
                val bytes = p.readbackBytes
                if (bytes == null || bytes.isEmpty()) {
                    result.error("readback_failed", "readback returned no data", null)
                    return
                }
                val bitmap = android.graphics.Bitmap.createBitmap(
                    gpu.readbackWidth, gpu.readbackHeight,
                    android.graphics.Bitmap.Config.ARGB_8888,
                )
                bitmap.copyPixelsFromBuffer(java.nio.ByteBuffer.wrap(bytes))

                val modelsDir = java.io.File(appContext!!.filesDir, "spike-models")
                val overlayDir = java.io.File(appContext!!.filesDir, "spike-overlays")
                val scales = listOf(256, 144, 96)

                val mpBench = SpikeSegmenterBenchmark(appContext!!, modelsDir)
                val mpStatus = mpBench.setup()
                val mpScaled = scales.map { w ->
                    val r = mpBench.runMediapipeScaled(bitmap, w)
                    "w=$w t=${r.latencyMicros}us mask=${r.maskWidth}x${r.maskHeight}"
                }
                val mpTimings = mpBench.runMediapipeRepeated(bitmap, 3)
                val mp = mpBench.runMediapipe(bitmap)
                val mpOverlay = try {
                    val mask = mpBench.lastCategoryMask
                    if (mask == null) {
                        "no mask"
                    } else {
                        val maskBuffer =
                            com.google.mediapipe.framework.image.ByteBufferExtractor.extract(mask)
                        SpikeMaskOverlay.saveCategory(
                            bitmap, maskBuffer, mask.width, mask.height,
                            java.io.File(overlayDir, "overlay_mp_640.png"),
                        )
                    }
                } catch (t: Throwable) {
                    "failed: $t"
                }
                mpBench.release()
                android.util.Log.i("MiVBGSpike", "scaled MP $mpScaled")
                android.util.Log.i("MiVBGSpike", "MP timings=$mpTimings overlay=$mpOverlay")

                // ML Kit delivers its Task listeners on the main looper, so the
                // wait must happen on a background thread or it deadlocks the
                // platform thread and the whole app stops ticking.
                Thread {
                    val mlBench = SpikeMLKitBenchmark()
                    val mlStatus = mlBench.setup()
                    val mlScaled = scales.map { w ->
                        val r = mlBench.runScaled(bitmap, w)
                        "w=$w t=${r.latencyMicros}us mask=${r.maskWidth}x${r.maskHeight}"
                    }
                    val mlTimings = mlBench.runRepeated(bitmap, 3)
                    val ml = mlBench.run(bitmap)
                    val mlOverlay = try {
                        val mask = mlBench.lastMask
                        if (mask == null) {
                            "no mask"
                        } else {
                            SpikeMaskOverlay.saveFloat(
                                bitmap, mask.buffer, mask.width, mask.height,
                                java.io.File(overlayDir, "overlay_ml_640.png"),
                            )
                        }
                    } catch (t: Throwable) {
                        "failed: $t"
                    }
                    mlBench.release()
                    android.util.Log.i("MiVBGSpike", "scaled ML $mlScaled")
                    android.util.Log.i("MiVBGSpike", "ML timings=$mlTimings overlay=$mlOverlay")
                    bitmap.recycle()
                    android.os.Handler(android.os.Looper.getMainLooper()).post {
                        result.success(
                            mapOf(
                                "mpSetup" to mpStatus,
                                "mpMicros" to mp.latencyMicros,
                                "mpTimings" to mpTimings,
                                "mpMask" to "${mp.maskWidth}x${mp.maskHeight}",
                                "mpError" to (mp.error ?: ""),
                                "mpOverlay" to mpOverlay,
                                "mlSetup" to mlStatus,
                                "mlMicros" to ml.latencyMicros,
                                "mlTimings" to mlTimings,
                                "mlMask" to "${ml.maskWidth}x${ml.maskHeight}",
                                "mlError" to (ml.error ?: ""),
                                "mlOverlay" to mlOverlay,
                                "mpScaled" to mpScaled,
                                "mlScaled" to mlScaled,
                                "readbackMicros" to gpu.readbackMicros,
                                "width" to gpu.readbackWidth,
                                "height" to gpu.readbackHeight,
                            ),
                        )
                    }
                }.start()
            }
            "spikeCompositeBench" -> {
                val p = spikeProcessor
                val gpu = p?.compositor
                if (p == null || gpu == null) {
                    result.error("no_processor", "spike processor not attached", null)
                    return
                }
                Thread {
                    val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())
                    try {
                        if (!p.requestReadback()) throw IllegalStateException("readback timeout")
                        val bytes = p.readbackBytes
                            ?: throw IllegalStateException("readback empty")
                        val w = gpu.readbackWidth
                        val h = gpu.readbackHeight
                        val readbackUs = gpu.readbackMicros
                        val bitmap = android.graphics.Bitmap.createBitmap(
                            w, h, android.graphics.Bitmap.Config.ARGB_8888,
                        )
                        bitmap.copyPixelsFromBuffer(java.nio.ByteBuffer.wrap(bytes))

                        val assetBmp = appContext!!.assets.open("bench_bg.png").use {
                            android.graphics.BitmapFactory.decodeStream(it)
                        } ?: throw IllegalStateException("bench_bg.png missing")
                        val imgOk = p.requestImage(bitmapToRgba(assetBmp), assetBmp.width, assetBmp.height)

                        fun window(name: String, frames: Int = 90): Map<String, Any> {
                            val c0 = p.arrivalCount
                            val gc0 = gpu.compositeCount
                            val gs0 = gpu.compositeTotalMicros
                            val cpu0 = cpuTicks()
                            val t0 = System.nanoTime()
                            var c1 = c0
                            while (c1 - c0 < frames &&
                                (System.nanoTime() - t0) / 1_000_000_000.0 < 10.0
                            ) {
                                Thread.sleep(10)
                                c1 = p.arrivalCount
                            }
                            val wall = (System.nanoTime() - t0) / 1e9
                            val cpu1 = cpuTicks()
                            val fps = (c1 - c0) / wall
                            val cpuPct = ((cpu1 - cpu0) / 100.0) / wall * 100.0
                            val dc = gpu.compositeCount - gc0
                            val avgUs = if (dc > 0) (gpu.compositeTotalMicros - gs0) / dc else -1L
                            android.util.Log.i(
                                "MiVBGSpike",
                                "BENCH $name fps=%.1f cpuPct=%.1f avgUs=%d frames=%d wall=%.2f"
                                    .format(fps, cpuPct, avgUs, c1 - c0, wall),
                            )
                            return mapOf(
                                "fps" to Math.round(fps * 10) / 10.0,
                                "cpuPct" to Math.round(cpuPct * 10) / 10.0,
                                "avgUs" to avgUs,
                            )
                        }

                        p.enabled = false
                        val off = window("off")
                        p.enabled = true

                        gpu.effectMode = 1
                        Thread.sleep(500)
                        val blur = window("blur")

                        val imageWindow: Map<String, Any> = if (imgOk && gpu.imageUploaded) {
                            gpu.effectMode = 2
                            Thread.sleep(300)
                            window("image")
                        } else {
                            mapOf("error" to "image not uploaded")
                        }
                        gpu.effectMode = 0

                        val javaBlurUs = (1..3).map { timeUs { javaBoxBlur(bitmap) } }.sorted()[1]
                        val assetScaled = android.graphics.Bitmap.createScaledBitmap(assetBmp, w, h, true)
                        val javaImgUs = (1..3).map { timeUs { javaLerp(bitmap, assetScaled) } }.sorted()[1]

                        bitmap.recycle()
                        if (assetScaled != assetBmp) assetScaled.recycle()
                        assetBmp.recycle()

                        android.util.Log.i(
                            "MiVBGSpike",
                            "BENCH javaBlurUs=$javaBlurUs javaImgUs=$javaImgUs res=${w}x$h readbackUs=$readbackUs",
                        )
                        mainHandler.post {
                            result.success(
                                mapOf(
                                    "w" to w,
                                    "h" to h,
                                    "readbackUs" to readbackUs,
                                    "imgUploadOk" to imgOk,
                                    "off" to off,
                                    "blur" to blur,
                                    "image" to imageWindow,
                                    "javaBlurUs" to javaBlurUs,
                                    "javaImgUs" to javaImgUs,
                                ),
                            )
                        }
                    } catch (t: Throwable) {
                        android.util.Log.e("MiVBGSpike", "composite bench failed: $t")
                        mainHandler.post { result.error("bench_failed", t.toString(), null) }
                    }
                }.start()
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

    /** Process CPU ticks (utime+stime), CLK_TCK = 100 on Android. */
    private fun cpuTicks(): Long {
        val text = java.io.File("/proc/self/stat").readText()
        val parts = text.substringAfterLast(')').trim().split(Regex("\\s+"))
        return parts[11].toLong() + parts[12].toLong()
    }

    private inline fun timeUs(block: () -> Unit): Long {
        val t0 = System.nanoTime()
        block()
        return (System.nanoTime() - t0) / 1000
    }

    private fun bitmapToRgba(src: android.graphics.Bitmap): ByteArray {
        val w = src.width
        val h = src.height
        val px = IntArray(w * h)
        src.getPixels(px, 0, w, 0, 0, w, h)
        val out = ByteArray(w * h * 4)
        for (i in px.indices) {
            val c = px[i]
            val o = i * 4
            out[o] = ((c shr 16) and 0xFF).toByte()
            out[o + 1] = ((c shr 8) and 0xFF).toByte()
            out[o + 2] = (c and 0xFF).toByte()
            out[o + 3] = ((c ushr 24) and 0xFF).toByte()
        }
        return out
    }

    /** In-place 3x3 box blur, weights 4/2/1 — the CPU counterpart of the GPU shader. */
    private fun javaBoxBlur(src: android.graphics.Bitmap) {
        val w = src.width
        val h = src.height
        if (w < 3 || h < 3) return
        val px = IntArray(w * h)
        src.getPixels(px, 0, w, 0, 0, w, h)
        val out = px.copyOf()
        for (y in 1 until h - 1) {
            for (x in 1 until w - 1) {
                var r = 0
                var g = 0
                var b = 0
                for (dy in -1..1) {
                    val row = (y + dy) * w
                    for (dx in -1..1) {
                        val c = px[row + x + dx]
                        val weight = if (dx == 0 && dy == 0) 4 else if (dx == 0 || dy == 0) 2 else 1
                        r += ((c shr 16) and 0xFF) * weight
                        g += ((c shr 8) and 0xFF) * weight
                        b += (c and 0xFF) * weight
                    }
                }
                out[y * w + x] = (0xFF shl 24) or ((r shr 4) shl 16) or
                    ((g shr 4) shl 8) or (b shr 4)
            }
        }
        src.setPixels(out, 0, w, 0, 0, w, h)
    }

    /** 50/50 lerp of [dst] with [src] — the CPU counterpart of the image mix. */
    private fun javaLerp(dst: android.graphics.Bitmap, src: android.graphics.Bitmap) {
        val w = dst.width
        val h = dst.height
        val a = IntArray(w * h)
        val b = IntArray(w * h)
        dst.getPixels(a, 0, w, 0, 0, w, h)
        src.getPixels(b, 0, w, 0, 0, w, h)
        for (i in a.indices) {
            val ca = a[i]
            val cb = b[i]
            val r = (((ca shr 16) and 0xFF) + ((cb shr 16) and 0xFF)) / 2
            val g = (((ca shr 8) and 0xFF) + ((cb shr 8) and 0xFF)) / 2
            val bl = ((ca and 0xFF) + (cb and 0xFF)) / 2
            a[i] = (0xFF shl 24) or (r shl 16) or (g shl 8) or bl
        }
        dst.setPixels(a, 0, w, 0, 0, w, h)
    }
}
