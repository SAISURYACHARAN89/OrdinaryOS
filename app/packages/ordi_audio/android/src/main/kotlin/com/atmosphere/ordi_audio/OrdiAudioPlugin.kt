package com.atmosphere.ordi_audio

import android.Manifest
import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Flutter's view of the audio engine. The Android twin of
 * `OrdiAudioPlugin.swift`: the same three channels and the same payloads, so
 * the Dart side does not know which platform it is on.
 */
class OrdiAudioPlugin :
    FlutterPlugin,
    MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler,
    ActivityAware,
    PluginRegistry.RequestPermissionsResultListener {

    private lateinit var context: Context
    private lateinit var engine: OrdiEngine
    private lateinit var classic: ClassicBluetooth
    private lateinit var methods: MethodChannel
    private lateinit var events: EventChannel

    /**
     * Tool calls go over their own method channel rather than the event
     * stream, because a tool call is a request that must receive a reply.
     */
    private lateinit var toolChannel: MethodChannel
    private val main = Handler(Looper.getMainLooper())

    // Touched only on the main thread.
    private var eventSink: EventChannel.EventSink? = null
    private var lastState = OrdiEngine.State.IDLE
    private var lastLevel = 0f
    private var lastTranscript = ""
    private val pendingTools = HashSet<String>()
    private val cancelledTools = HashSet<String>()

    private var activity: Activity? = null
    private var activityBinding: ActivityPluginBinding? = null
    private val permissionResults = HashMap<Int, (Boolean) -> Unit>()

    /** Asked once per launch; after a refusal, only the current answer is reported. */
    private var askedForMicrophone = false

    private var debugReceiver: BroadcastReceiver? = null
    private val stopService = Runnable { ListeningService.stop(context) }

    // ----------------------------------------------------------- registration

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        engine = OrdiEngine(context)
        classic = ClassicBluetooth(context)

        methods = MethodChannel(binding.binaryMessenger, "ordi/audio")
        methods.setMethodCallHandler(this)
        events = EventChannel(binding.binaryMessenger, "ordi/audio/events")
        events.setStreamHandler(this)
        toolChannel = MethodChannel(binding.binaryMessenger, "ordi/audio/tools")

        wire()
        registerDebugHooks()
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methods.setMethodCallHandler(null)
        events.setStreamHandler(null)
        classic.dispose()
        debugReceiver?.let {
            try {
                context.unregisterReceiver(it)
            } catch (_: IllegalArgumentException) {
            }
        }
        debugReceiver = null
        engine.disconnect()
        engine.stop()
        main.removeCallbacks(stopService)
        ListeningService.stop(context)
    }

    private fun wire() {
        engine.onState = { state ->
            lastState = state
            emit()
        }
        engine.onLevel = { level ->
            lastLevel = level
            emit()
        }
        engine.onTranscript = { text ->
            lastTranscript = text
            emit()
        }
        engine.onError = { message -> emit(error = message) }
        engine.onExchangeComplete = { question, answer -> emit(exchange = question to answer) }
        engine.onResumptionHandle = { handle -> emit(resumptionHandle = handle) }
        engine.onToolCall = { calls -> dispatch(calls) }
        engine.onToolCancel = { ids ->
            // Withdrawn calls must not be answered. Whatever already ran, ran.
            for (id in ids) {
                if (pendingTools.remove(id)) cancelledTools.add(id)
            }
        }
    }

    // ------------------------------------------------------------ tool bridge

    /**
     * Hands each call to Dart and guarantees a reply goes back to the model.
     * Function calling is synchronous: an unanswered call is a dead
     * conversation, so every call is answered within four seconds whatever
     * happens on the Dart side.
     */
    private fun dispatch(calls: List<GeminiLiveSession.ToolCall>) {
        for (call in calls) {
            pendingTools.add(call.id)
            var replied = false
            val finish: (Map<String, Any?>) -> Unit = { response ->
                if (!replied) {
                    replied = true
                    settle(call, response)
                }
            }
            main.postDelayed({ finish(mapOf("error" to "Timed out.")) }, 4000)
            toolChannel.invokeMethod(
                "invoke",
                mapOf("id" to call.id, "name" to call.name, "args" to call.args),
                object : MethodChannel.Result {
                    override fun success(result: Any?) {
                        @Suppress("UNCHECKED_CAST")
                        val map = (result as? Map<*, *>)?.mapKeys { it.key.toString() } as? Map<String, Any?>
                        finish(map ?: mapOf("error" to "Tool not handled."))
                    }

                    override fun error(code: String, message: String?, details: Any?) {
                        finish(mapOf("error" to (message ?: "Tool failed.")))
                    }

                    override fun notImplemented() {
                        finish(mapOf("error" to "Tool not handled."))
                    }
                },
            )
        }
    }

    private fun settle(call: GeminiLiveSession.ToolCall, response: Map<String, Any?>) {
        if (cancelledTools.remove(call.id)) return
        if (!pendingTools.remove(call.id)) return
        engine.respond(listOf(mapOf("id" to call.id, "name" to call.name, "response" to response)))
    }

    // ---------------------------------------------------------- method channel

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "requestPermission" -> requestMicrophone { result.success(it) }

            "start" -> {
                try {
                    engine.start()
                    main.removeCallbacks(stopService)
                    if (hasMicrophone()) ListeningService.start(context)
                    result.success(true)
                } catch (error: Exception) {
                    result.error("start_failed", "Could not start the audio engine: ${error.message}", null)
                }
            }

            "stop" -> {
                engine.stop()
                // Kept briefly: the app restarts capture straight after a stop
                // when reviving it, and Android will not let the service be
                // started again from the background.
                main.removeCallbacks(stopService)
                main.postDelayed(stopService, 5000)
                result.success(null)
            }

            "connect" -> {
                val token = call.argument<String>("token")
                val model = call.argument<String>("model")
                if (token == null || model == null) {
                    result.error("bad_args", "connect needs a token and a model.", null)
                    return
                }
                engine.connect(token, model)
                result.success(null)
            }

            "disconnect" -> {
                engine.disconnect()
                result.success(null)
            }

            "setRecording" -> {
                engine.recordingMode = call.argument<Boolean>("recording") ?: false
                result.success(null)
            }

            "ask" -> {
                val text = call.argument<String>("text")
                if (text == null) {
                    result.error("bad_args", "ask needs text.", null)
                    return
                }
                engine.ask(text)
                result.success(null)
            }

            // Siri hands questions over on iOS; Android has no equivalent yet.
            "takePendingQuestion" -> result.success(mapOf("text" to "", "intentRanAt" to 0.0))

            "isRunning" -> result.success(engine.isRunning)

            "stats" -> result.success(
                mapOf(
                    "taps" to engine.tapCount,
                    "running" to engine.isRunning,
                    "hasSink" to (eventSink != null),
                    "state" to lastState.wire,
                    "vp" to engine.voiceProcessing,
                ),
            )

            // Android only: Bluetooth needs a runtime permission before the
            // Ordinary glasses and Band can be found.
            "requestBluetooth" -> requestBluetooth { result.success(it) }

            "bluetoothAudio" -> result.success(bluetoothAudio(call.argument<String>("batteryFor")))

            // Finding and pairing a headset from inside the app.
            "bluetoothSearch" -> result.success(classic.search())
            "bluetoothFound" -> result.success(classic.found())
            "bluetoothPair" -> {
                val address = call.argument<String>("address")
                if (address == null) {
                    result.success(false)
                } else {
                    classic.pair(address) { result.success(it) }
                }
            }

            "openAppSettings" -> {
                try {
                    val intent = Intent(
                        Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                        Uri.fromParts("package", context.packageName, null),
                    ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    context.startActivity(intent)
                    result.success(true)
                } catch (error: Exception) {
                    result.success(false)
                }
            }

            else -> result.notImplemented()
        }
    }

    // ------------------------------------------------------------ permissions

    private fun hasMicrophone(): Boolean =
        context.checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED

    private fun requestMicrophone(done: (Boolean) -> Unit) {
        if (hasMicrophone()) return done(true)
        if (askedForMicrophone) return done(false)
        askedForMicrophone = true
        ask(arrayOf(Manifest.permission.RECORD_AUDIO), REQUEST_MICROPHONE, done)
    }

    /**
     * The Bluetooth headsets the phone itself is connected to, by name, and
     * the battery level of the one called [batteryFor] (-1 if it reports
     * none). Android keeps a headset's level but offers no public way to read
     * it; the hidden getter is asked and any refusal is simply "no level".
     */
    @android.annotation.SuppressLint("MissingPermission")
    private fun bluetoothAudio(batteryFor: String?): Map<String, Any> {
        val names = mutableListOf<String>()
        var battery = -1
        try {
            val audio = context.getSystemService(Context.AUDIO_SERVICE) as android.media.AudioManager
            val bluetooth = setOf(
                android.media.AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
                android.media.AudioDeviceInfo.TYPE_BLUETOOTH_A2DP,
                26, // TYPE_BLE_HEADSET, API 31
                27, // TYPE_BLE_SPEAKER, API 31
            )
            for (device in audio.getDevices(
                android.media.AudioManager.GET_DEVICES_INPUTS or android.media.AudioManager.GET_DEVICES_OUTPUTS)) {
                val name = device.productName?.toString().orEmpty()
                if (device.type in bluetooth && name.isNotEmpty() && name !in names) names.add(name)
            }
            val allowed = Build.VERSION.SDK_INT < 31 ||
                context.checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) ==
                PackageManager.PERMISSION_GRANTED
            if (batteryFor != null && allowed && names.any { it.equals(batteryFor, ignoreCase = true) }) {
                val manager = context.getSystemService(Context.BLUETOOTH_SERVICE) as android.bluetooth.BluetoothManager
                for (device in manager.adapter?.bondedDevices.orEmpty()) {
                    if (!device.name.orEmpty().equals(batteryFor, ignoreCase = true)) continue
                    val level = device.javaClass.getMethod("getBatteryLevel").invoke(device) as? Int ?: -1
                    if (level in 0..100) battery = level
                }
            }
        } catch (error: Exception) {
            // No Bluetooth, no permission, or the getter is gone: no level.
        }
        return mapOf("names" to names, "battery" to battery, "gatt" to emptyList<String>())
    }

    private fun requestBluetooth(done: (Boolean) -> Unit) {
        val needed = if (Build.VERSION.SDK_INT >= 31) {
            arrayOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT)
        } else {
            arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)
        }
        val missing = needed.filter {
            context.checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED
        }
        if (missing.isEmpty()) return done(true)
        ask(missing.toTypedArray(), REQUEST_BLUETOOTH, done)
    }

    private fun ask(permissions: Array<String>, code: Int, done: (Boolean) -> Unit) {
        val current = activity ?: return done(false)
        // A second request while one is showing answers the first with the
        // same outcome rather than stacking dialogs.
        val previous = permissionResults[code]
        permissionResults[code] = { granted ->
            previous?.invoke(granted)
            done(granted)
        }
        if (previous == null) current.requestPermissions(permissions, code)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ): Boolean {
        val done = permissionResults.remove(requestCode) ?: return false
        done(grantResults.isNotEmpty() && grantResults.all { it == PackageManager.PERMISSION_GRANTED })
        return true
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        activityBinding = binding
        binding.addRequestPermissionsResultListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) =
        onAttachedToActivity(binding)

    override fun onDetachedFromActivity() {
        activityBinding?.removeRequestPermissionsResultListener(this)
        activityBinding = null
        activity = null
        // Nobody can answer these now.
        val waiting = permissionResults.values.toList()
        permissionResults.clear()
        for (done in waiting) done(false)
    }

    // ----------------------------------------------------------- event channel

    private fun emit(
        error: String? = null,
        exchange: Pair<String, String>? = null,
        resumptionHandle: String? = null,
    ) {
        val sink = eventSink ?: return
        val payload = HashMap<String, Any>()
        payload["state"] = lastState.wire
        payload["amplitude"] = lastLevel.toDouble()
        payload["transcript"] = lastTranscript
        if (error != null) payload["error"] = error
        // Present only on the frame an exchange finished, never as empty strings.
        if (exchange != null) {
            payload["exchangeQuestion"] = exchange.first
            payload["exchangeAnswer"] = exchange.second
        }
        if (resumptionHandle != null) payload["resumptionHandle"] = resumptionHandle
        sink.success(payload)
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    // ------------------------------------------------------------ debug hooks

    /**
     * Debug builds only, never in a release: lets a test drive the engine
     * without a person talking.
     *
     *   adb shell am broadcast -a com.atmosphere.ordi_audio.DEBUG_INJECT \
     *       --es file q1.wav        (a 16 kHz mono WAV in the app's files dir)
     *   adb shell am broadcast -a com.atmosphere.ordi_audio.DEBUG_ASK --es text "..."
     *
     * An injected clip replaces the microphone for its length and goes
     * through exactly the path speech does: levels, voice activity, uplink.
     */
    @android.annotation.SuppressLint("UnspecifiedRegisterReceiverFlag") // debug builds only; adb must reach it
    private fun registerDebugHooks() {
        val debuggable = (context.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0
        if (!debuggable) return
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(c: Context, intent: Intent) {
                when (intent.action) {
                    ACTION_INJECT -> {
                        val name = intent.getStringExtra("file") ?: return
                        val pcm = readWav(File(context.filesDir, name))
                        if (pcm == null) {
                            Log.e(OrdiEngine.TAG, "debug inject: could not read $name")
                        } else {
                            Log.i(OrdiEngine.TAG, "debug inject: $name (${pcm.size} samples)")
                            engine.inject(pcm)
                        }
                    }
                    ACTION_ASK -> intent.getStringExtra("text")?.let { engine.ask(it) }
                }
            }
        }
        val filter = IntentFilter().apply {
            addAction(ACTION_INJECT)
            addAction(ACTION_ASK)
        }
        if (Build.VERSION.SDK_INT >= 26) {
            context.registerReceiver(receiver, filter, Context.RECEIVER_EXPORTED)
        } else {
            context.registerReceiver(receiver, filter)
        }
        debugReceiver = receiver
    }

    /** 16-bit mono 16 kHz WAV -> samples, finding the chunks rather than assuming a header size. */
    private fun readWav(file: File): ShortArray? {
        if (!file.exists()) return null
        val bytes = file.readBytes()
        if (bytes.size < 12) return null
        val buffer = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
        var offset = 12
        var rate = 0
        var channels = 0
        var bits = 0
        while (offset + 8 <= bytes.size) {
            val id = String(bytes, offset, 4, Charsets.US_ASCII)
            val size = buffer.getInt(offset + 4)
            val body = offset + 8
            if (id == "fmt ") {
                channels = buffer.getShort(body + 2).toInt()
                rate = buffer.getInt(body + 4)
                bits = buffer.getShort(body + 14).toInt()
            } else if (id == "data") {
                if (rate != OrdiEngine.UPLINK_RATE || channels != 1 || bits != 16) {
                    Log.e(OrdiEngine.TAG, "debug inject: need 16 kHz mono 16-bit, got $rate Hz x$channels ${bits}-bit")
                    return null
                }
                val count = minOf(size, bytes.size - body) / 2
                val out = ShortArray(count)
                for (i in 0 until count) out[i] = buffer.getShort(body + i * 2)
                return out
            }
            offset = body + size + (size and 1)
        }
        return null
    }

    companion object {
        private const val REQUEST_MICROPHONE = 7401
        private const val REQUEST_BLUETOOTH = 7402
        private const val ACTION_INJECT = "com.atmosphere.ordi_audio.DEBUG_INJECT"
        private const val ACTION_ASK = "com.atmosphere.ordi_audio.DEBUG_ASK"
    }
}
