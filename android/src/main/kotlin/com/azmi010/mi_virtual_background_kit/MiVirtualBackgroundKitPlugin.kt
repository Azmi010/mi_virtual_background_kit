package com.azmi010.mi_virtual_background_kit

import android.app.ActivityManager
import android.content.Context
import com.azmi010.mi_virtual_background_kit.processor.FrameProcessor
import com.azmi010.mi_virtual_background_kit.processor.attachFrameProcessor
import com.azmi010.mi_virtual_background_kit.processor.detachFrameProcessor
import com.azmi010.mi_virtual_background_kit.segmentation.Segmenter
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
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
    private var statusChannel: EventChannel? = null
    internal var statusSink: EventChannel.EventSink? = null
    private var mainHandler: android.os.Handler? = null

    internal var currentStatus: String = "idle"
        private set

    private fun runOnMainThread(action: () -> Unit) {
        val looper = try { android.os.Looper.getMainLooper() } catch (_: Throwable) { null }
        if (looper != null && android.os.Looper.myLooper() != looper) {
            if (mainHandler == null) {
                mainHandler = android.os.Handler(looper)
            }
            mainHandler?.post(action)
        } else {
            action()
        }
    }

    internal fun updateStatus(status: String) {
        currentStatus = status
        val sink = statusSink ?: return
        runOnMainThread {
            sink.success(status)
        }
    }

    internal fun sendFallbackEvent(event: Map<String, Any?>) {
        val sink = statusSink ?: return
        runOnMainThread {
            sink.success(event)
        }
    }

    // Production processor (T3.2). ADR 0001 §1: the LocalVideoTrack object
    // is cached here on attach — Dart's stream.getMediaTracks() replaces the
    // flutter_webrtc registry entry, so a re-lookup by id attaches to nothing.
    private var attachedTrack: Any? = null
    private var frameProcessor: FrameProcessor? = null

    internal var appContext: android.content.Context? = null
    private var flutterAssets: FlutterPlugin.FlutterAssets? = null

    internal var imageDecoder: (String, Any?) -> android.graphics.Bitmap? = { type, data ->
        decodeImage(type, data)
    }

    internal var trackAttacher: (String, FrameProcessor) -> Any? = { trackId, processor ->
        attachFrameProcessor(trackId, processor)
    }

    internal var trackDetacher: (Any?, FrameProcessor?) -> Unit = { track, processor ->
        detachFrameProcessor(track as? com.cloudwebrtc.webrtc.video.LocalVideoTrack, processor)
    }

    internal var frameProcessorFactory: (() -> FrameProcessor)? = null
    internal var isSupportedChecker: (() -> Boolean)? = null
    internal var glEsVersionProvider: (() -> Int)? = null
    internal var modelAssetChecker: (() -> Boolean)? = null

    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        appContext = flutterPluginBinding.applicationContext
        flutterAssets = flutterPluginBinding.flutterAssets
        channel = MethodChannel(flutterPluginBinding.binaryMessenger, "mi_virtual_background_kit")
        channel.setMethodCallHandler(this)

        val sc = EventChannel(flutterPluginBinding.binaryMessenger, "mi_virtual_background_kit/status")
        sc.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                statusSink = events
                events?.success(currentStatus)
            }

            override fun onCancel(arguments: Any?) {
                statusSink = null
            }
        })
        statusChannel = sc
    }

    override fun onMethodCall(
        call: MethodCall,
        result: Result
    ) {
        when (call.method) {
            "getPlatformVersion" -> result.success("Android ${android.os.Build.VERSION.RELEASE}")
            "isSupported" -> {
                // FR-13: Supported on Android SDK >= 24, OpenGL ES >= 2.0, and model asset available
                val custom = isSupportedChecker
                if (custom != null) {
                    result.success(custom())
                    return
                }
                val sdkOk = android.os.Build.VERSION.SDK_INT >= 24
                val glEsVersion = glEsVersionProvider?.invoke() ?: run {
                    val actManager = appContext?.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
                    actManager?.deviceConfigurationInfo?.reqGlEsVersion ?: if (appContext == null) 0x20000 else 0
                }
                val glEsOk = glEsVersion >= 0x20000
                val modelOk = modelAssetChecker?.invoke() ?: run {
                    appContext?.let { Segmenter.isModelAssetAvailable(it) } ?: true
                }
                result.success(sdkOk && glEsOk && modelOk)
            }
            "attach" -> {
                val trackId = call.argument<String>("trackId")
                if (trackId.isNullOrBlank()) {
                    updateStatus("error")
                    result.error("invalidTrack", "trackId is required", null)
                    return
                }
                updateStatus("initializing")
                // Re-attach replaces: never stack processors on one track.
                releaseFrameProcessor()
                val processor = frameProcessorFactory?.invoke() ?: FrameProcessor(
                    context = appContext,
                    onStatusChange = { status -> updateStatus(status) },
                    onFallbackEvent = { eventMap -> sendFallbackEvent(eventMap) },
                )
                processor.onStatusChange = { status -> updateStatus(status) }
                processor.onFallbackEvent = { eventMap -> sendFallbackEvent(eventMap) }
                val qualityMap = call.argument<Map<String, Any?>>("quality")
                if (qualityMap != null) {
                    val segW = (qualityMap["segmentationWidth"] as? Number)?.toInt() ?: 256
                    val edgeSm = (qualityMap["edgeSmoothing"] as? Number)?.toFloat() ?: 0.5f
                    val fps = (qualityMap["targetFps"] as? Number)?.toInt() ?: 30
                    val mts = (qualityMap["maskTemporalSmoothing"] as? Number)?.toFloat() ?: 0.7f
                    val autoRec = qualityMap["autoRecovery"] as? Boolean ?: false
                    processor.setQuality(segW, edgeSm, fps, mts, autoRec)
                }
                val track = trackAttacher(trackId, processor)
                if (track == null) {
                    updateStatus("error")
                    result.error("invalidTrack", "no local video track: $trackId", null)
                    return
                }
                attachedTrack = track
                frameProcessor = processor
                updateStatus("active")
                android.util.Log.i("MiVBG", "attached processor to $trackId")
                result.success(null)
            }
            "setEffect" -> {
                val type = call.argument<String>("type")
                when (type) {
                    "blur" -> {
                        val radius = (call.argument<Number>("radius")?.toDouble() ?: 12.0).toFloat()
                        try {
                            frameProcessor?.setBlurEffect(radius)
                            updateStatus("active")
                            result.success(null)
                        } catch (t: Throwable) {
                            updateStatus("error")
                            result.error("modelLoadFailed", t.message, null)
                        }
                    }
                    "color" -> {
                        val color = (call.argument<Number>("color")?.toLong() ?: 0xFF000000).toInt()
                        try {
                            frameProcessor?.setColorEffect(color)
                            updateStatus("active")
                            result.success(null)
                        } catch (t: Throwable) {
                            updateStatus("error")
                            result.error("modelLoadFailed", t.message, null)
                        }
                    }
                    "image" -> {
                        val fit = call.argument<String>("fit") ?: "cover"
                        val sourceType = call.argument<String>("sourceType") ?: "asset"
                        val data = call.argument<Any>("data")
                        val bitmap = try {
                            imageDecoder(sourceType, data)
                        } catch (t: Throwable) {
                            updateStatus("error")
                            result.error("invalidImage", "Failed to decode image: ${t.message}", null)
                            return
                        }
                        if (bitmap == null) {
                            updateStatus("error")
                            result.error("invalidImage", "Failed to decode image from $sourceType", null)
                            return
                        }
                        try {
                            frameProcessor?.setImageEffect(bitmap, fit)
                            updateStatus("active")
                            result.success(null)
                        } catch (t: Throwable) {
                            updateStatus("error")
                            result.error("modelLoadFailed", t.message, null)
                        }
                    }
                    "none" -> {
                        frameProcessor?.clearEffect()
                        updateStatus("active")
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
            "setQuality" -> {
                val segW = (call.argument<Number>("segmentationWidth"))?.toInt() ?: 256
                val edgeSm = (call.argument<Number>("edgeSmoothing"))?.toFloat() ?: 0.5f
                val fps = (call.argument<Number>("targetFps"))?.toInt() ?: 30
                val mts = (call.argument<Number>("maskTemporalSmoothing"))?.toFloat() ?: 0.7f
                val autoRec = call.argument<Boolean>("autoRecovery") ?: false
                frameProcessor?.setQuality(segW, edgeSm, fps, mts, autoRec)
                result.success(null)
            }
            // T14.2/T14.3 measurement hooks (example flicker-test page only).
            "testSetSmoothing" -> {
                val processor = frameProcessor
                if (processor == null) {
                    result.error("no_processor", "kit not attached", null)
                    return
                }
                val mode = call.argument<String>("mode")
                val value = (call.argument<Double>("value") ?: 0.0).toFloat()
                val d0 = call.argument<Double>("d0")?.toFloat()
                processor.setTestSmoothing(mode, value, d0)
                android.util.Log.i("MiVBG", "T133| SET_SMOOTHING m=$mode v=$value d0=$d0")
                result.success(null)
            }
            "testSetStage" -> {
                val processor = frameProcessor
                if (processor == null) {
                    result.error("no_processor", "kit not attached", null)
                    return
                }
                val stage = call.argument<String>("stage") ?: "-"
                processor.setTestStage(stage)
                android.util.Log.i("MiVBG", "T133| SET_STAGE st=$stage")
                result.success(null)
            }
            // T14.4 measurement hook: forces one performance-window evaluation
            // (fallback recovery test only, mirrors testSetSmoothing).
            "testSimulateFps" -> {
                val processor = frameProcessor
                if (processor == null) {
                    result.error("no_processor", "kit not attached", null)
                    return
                }
                val fps = call.argument<Double>("fps") ?: 0.0
                processor.simulatePerformanceDrop(fps)
                android.util.Log.i("MiVBG", "T144| SIM_FPS fps=$fps")
                result.success(null)
            }
            "detach" -> {
                val had = frameProcessor != null
                releaseFrameProcessor()
                updateStatus("idle")
                android.util.Log.i("MiVBG", "detached processor (wasAttached=$had)")
                result.success(null)
            }
            "dispose" -> {
                releaseFrameProcessor()
                updateStatus("idle")
                android.util.Log.i("MiVBG", "disposed plugin resources")
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        releaseFrameProcessor()
        channel.setMethodCallHandler(null)
        statusChannel?.setStreamHandler(null)
        statusChannel = null
        statusSink = null
        flutterAssets = null
        appContext = null
    }

    private fun decodeImage(sourceType: String, data: Any?): android.graphics.Bitmap? {
        if (data == null) return null
        return when (sourceType) {
            "asset" -> {
                val assetPath = data as? String ?: return null
                val key = flutterAssets?.getAssetFilePathByName(assetPath) ?: assetPath
                appContext?.assets?.open(key)?.use {
                    android.graphics.BitmapFactory.decodeStream(it)
                }
            }
            "file" -> {
                val path = data as? String ?: return null
                android.graphics.BitmapFactory.decodeFile(path)
            }
            "bytes" -> {
                val bytes = data as? ByteArray ?: return null
                android.graphics.BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
            }
            else -> null
        }
    }

    /** Detaches the production processor from its cached track; idempotent. */
    private fun releaseFrameProcessor() {
        val p = frameProcessor
        val track = attachedTrack
        if (p == null && track == null) return
        trackDetacher(track, p)
        p?.release()
        attachedTrack = null
        frameProcessor = null
    }

}
