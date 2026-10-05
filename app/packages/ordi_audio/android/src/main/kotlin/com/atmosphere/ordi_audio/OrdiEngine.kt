package com.atmosphere.ordi_audio

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioFocusRequest
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.MediaRecorder
import android.media.audiofx.AcousticEchoCanceler
import android.media.audiofx.AudioEffect
import android.media.audiofx.AutomaticGainControl
import android.media.audiofx.NoiseSuppressor
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.os.Process
import android.util.Log
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import kotlin.math.max
import kotlin.math.sqrt

/**
 * The whole realtime path: microphone in, Ordinary's voice out, and the
 * barge-in that makes it feel like a conversation. The Android twin of
 * `OrdiEngine.swift` — same states, thresholds and rules; keep them in step.
 *
 * **Threading.** The capture thread only does arithmetic on samples and hands
 * them on. Every decision — voice activity, state changes, starting or
 * stopping playback — runs on [control], a single thread that owns that
 * state. Lifecycle calls ([start], [stop], [connect], [disconnect]) arrive on
 * the main thread, and every callback to the plugin is delivered there too.
 */
internal class OrdiEngine(context: Context) {

    enum class State(val wire: String) { IDLE("idle"), LISTENING("listening"), THINKING("thinking"), SPEAKING("speaking") }

    // Delivered on the main thread.
    var onState: ((State) -> Unit)? = null
    var onLevel: ((Float) -> Unit)? = null
    var onError: ((String) -> Unit)? = null
    var onTranscript: ((String) -> Unit)? = null
    var onExchangeComplete: ((String, String) -> Unit)? = null
    var onResumptionHandle: ((String) -> Unit)? = null
    var onToolCall: ((List<GeminiLiveSession.ToolCall>) -> Unit)? = null
    var onToolCancel: ((List<String>) -> Unit)? = null

    private val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private val main = Handler(Looper.getMainLooper())
    private val controlThread = HandlerThread("ordi.engine.control").apply { start() }
    private val control = Handler(controlThread.looper)

    // ---- owned by `control`
    private var state = State.IDLE
    private var userSpeaking = false
    private var framesAboveOn = 0
    private var quietFrames = 0

    /** What Ordinary is saying this turn; cleared when the next turn begins. */
    private var transcript = ""

    /** A turn completed: the next fragment starts a new reply. */
    private var answerFinished = false

    /** The server warned this connection is ending; renew at a quiet moment. */
    private var renewPending = false

    /** What the user said this turn, paired with the answer for the history. */
    private var userTranscript = ""
    private var playback: AudioPlayback? = null

    // ---- shared
    @Volatile
    private var live: GeminiLiveSession? = null
    private val running = AtomicBoolean(false)
    val isRunning: Boolean get() = running.get()

    /**
     * While a recording runs, Ordinary's audio is dropped rather than played.
     * Only a playback guard — capture, voice activity and the state machine
     * carry on, because a recording still has to hear being spoken to.
     */
    @Volatile
    var recordingMode = false

    private val taps = AtomicInteger(0)

    /** Diagnostic: buffers delivered by the microphone. */
    val tapCount: Int get() = taps.get()

    /** Whether the voice-communication input with echo cancellation is in use. */
    @Volatile
    var voiceProcessing = true
        private set

    // ---- capture, touched on the main thread
    private var record: AudioRecord? = null
    private var captureThread: Thread? = null
    private val effects = ArrayList<AudioEffect>()

    /** How many times the watchdog has rebuilt capture looking for input. */
    private var revivals = 0

    // ---- routing
    /** True while the communication audio mode is ours, not a phone call's. */
    @Volatile
    private var ownsMode = false
    /** An AudioFocusRequest (API 26+); typed loosely so older devices never load the class. */
    private var focusRequest: Any? = null
    private var watchingDevices = false

    // ---- pre-roll
    /**
     * The last few seconds of microphone audio, kept only while there is no
     * session at all. A session is released after a quiet spell and opened
     * again when someone speaks; this lets the new session hear the start of
     * that sentence. Written on the capture thread, drained on connect.
     */
    private val preRollLock = Any()
    private val preRoll = ArrayDeque<ByteArray>()
    private var preRollBytes = 0

    private fun remember(pcm: ByteArray) {
        synchronized(preRollLock) {
            preRoll.addLast(pcm)
            preRollBytes += pcm.size
            while (preRollBytes > MAX_PRE_ROLL_BYTES && preRoll.isNotEmpty()) {
                preRollBytes -= preRoll.removeFirst().size
            }
        }
    }

    private fun takePreRoll(): List<ByteArray> = synchronized(preRollLock) {
        val held = preRoll.toList()
        preRoll.clear()
        preRollBytes = 0
        held
    }

    // ---- debug injection (debug builds only; see OrdiAudioPlugin)
    @Volatile
    private var injecting = false
    private val injectLock = Any()
    private var injection: ShortArray? = null
    private var injectPosition = 0

    // Hysteresis, identical to iOS: starting is harder than continuing.
    private val onThreshold = 0.14f
    private val offThreshold = 0.07f
    private val framesToStart = 2 // ~40 ms of sustained level
    private val framesToStop = 28 // ~600 ms of quiet

    // While Ordinary is talking, the bar for the user talking over it is much
    // higher, so a cough or the echo residue does not flush a queued answer.
    private val bargeInThreshold = 0.18f
    private val framesToBargeIn = 15 // ~300 ms of sustained level

    // ------------------------------------------------------------ lifecycle

    fun start() {
        revivals = 0
        start(withVoiceProcessing = true)
    }

    private fun start(withVoiceProcessing: Boolean) {
        if (isRunning) return
        voiceProcessing = withVoiceProcessing
        watchDevices()

        // Communication mode is what engages the platform's echo cancellation
        // on the voice-communication input, and the route to the loudspeaker.
        // Without it Ordinary hears itself and cuts off its own sentences.
        routeForVoice()

        val rec = openRecord(withVoiceProcessing)
            ?: throw IllegalStateException("Microphone unavailable — is another app holding it?")
        if (withVoiceProcessing) attachEffects(rec.audioSessionId)
        try {
            rec.startRecording()
        } catch (error: IllegalStateException) {
            rec.release()
            releaseEffects()
            throw IllegalStateException("Could not start the microphone.")
        }
        if (rec.recordingState != AudioRecord.RECORDSTATE_RECORDING) {
            rec.release()
            releaseEffects()
            throw IllegalStateException("The microphone did not start — is another app using it?")
        }

        val pb = AudioPlayback(
            onLevel = { level ->
                control.post { if (state == State.SPEAKING) emitLevel(level) }
            },
            onFinished = {
                control.post { if (state == State.SPEAKING) setState(State.IDLE) }
            },
            beforePlay = {
                routeForVoice()
                requestFocus()
            },
        )
        onControl { playback = pb }

        record = rec
        running.set(true)
        captureThread = Thread({ captureLoop(rec) }, "ordi.capture").also { it.start() }
        control.post {
            resetVoiceActivity()
            setState(State.IDLE)
        }
        scheduleInputWatchdog()
    }

    /**
     * Deliberately does not reset `revivals` — the watchdog restarts capture
     * through here and must remember how many attempts it has made.
     */
    fun stop() {
        if (!isRunning) return
        running.set(false)
        val rec = record
        record = null
        try {
            rec?.stop()
        } catch (_: IllegalStateException) {
        }
        try {
            captureThread?.join(300)
        } catch (_: InterruptedException) {
        }
        captureThread = null
        rec?.release()
        releaseEffects()
        takePreRoll()

        onControl {
            playback?.release()
            playback = null
            resetVoiceActivity()
            transcript = ""
            userTranscript = ""
            emitTranscript()
            setState(State.IDLE)
        }
        emitLevel(0f)
        abandonFocus()
        releaseRoute()
    }

    private fun openRecord(voice: Boolean): AudioRecord? {
        val source = if (voice) MediaRecorder.AudioSource.VOICE_COMMUNICATION else MediaRecorder.AudioSource.MIC
        val minBuffer = AudioRecord.getMinBufferSize(
            UPLINK_RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT,
        )
        if (minBuffer <= 0) return null
        return try {
            val rec = AudioRecord(
                source, UPLINK_RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT,
                max(minBuffer, UPLINK_RATE * 2 / 5),
            )
            if (rec.state == AudioRecord.STATE_INITIALIZED) {
                rec
            } else {
                rec.release()
                null
            }
        } catch (error: SecurityException) {
            null
        } catch (error: IllegalArgumentException) {
            null
        }
    }

    /**
     * The platform usually applies these itself on the voice-communication
     * input; asking explicitly covers devices that only do so on request.
     */
    private fun attachEffects(session: Int) {
        try {
            if (AcousticEchoCanceler.isAvailable()) AcousticEchoCanceler.create(session)?.let { it.enabled = true; effects.add(it) }
            if (NoiseSuppressor.isAvailable()) NoiseSuppressor.create(session)?.let { it.enabled = true; effects.add(it) }
            if (AutomaticGainControl.isAvailable()) AutomaticGainControl.create(session)?.let { it.enabled = true; effects.add(it) }
        } catch (error: RuntimeException) {
            Log.w(TAG, "audio effects unavailable: ${error.message}")
        }
    }

    private fun releaseEffects() {
        for (effect in effects) {
            try {
                effect.release()
            } catch (_: RuntimeException) {
            }
        }
        effects.clear()
    }

    // ------------------------------------------------------------ recovery

    /** Capture died underneath us (the read failed). Rebuild it. */
    private fun rebuildIfStoppedUnderneath(reason: String) {
        if (!isRunning) return
        Log.e(TAG, "audio stopped underneath us ($reason) — rebuilding")
        val vp = voiceProcessing
        stop()
        try {
            start(withVoiceProcessing = vp)
        } catch (error: Exception) {
            onError?.invoke("Ordinary lost the microphone. Try reopening the app.")
        }
    }

    /**
     * The microphone should deliver about fifty buffers a second. If none
     * arrive, capture is running but deaf: rebuild, and drop echo cancellation
     * only as a last resort.
     */
    private fun scheduleInputWatchdog() {
        val before = tapCount
        main.postDelayed({
            if (!isRunning) return@postDelayed
            if (tapCount != before) {
                revivals = 0
                return@postDelayed
            }
            revivals += 1
            when (revivals) {
                1, 2 -> {
                    Log.e(TAG, "microphone silent — rebuilding (attempt $revivals)")
                    val vp = voiceProcessing
                    stop()
                    try { start(withVoiceProcessing = vp) } catch (_: Exception) {}
                }
                3 -> {
                    Log.e(TAG, "microphone still silent — dropping voice processing")
                    stop()
                    try { start(withVoiceProcessing = false) } catch (_: Exception) {}
                }
                else -> {
                    Log.e(TAG, "microphone will not produce input")
                    onError?.invoke("Ordinary cannot hear the microphone. Try reopening the app.")
                }
            }
        }, 1200)
    }

    // --------------------------------------------------------- conversation

    fun connect(token: String, model: String) {
        control.post { renewPending = false }
        // Reconnecting on top of a working session costs a fresh token for no
        // gain; the app can call this more than once, so absorb it here.
        if (live != null) {
            Log.i(TAG, "connect ignored — a session is already open")
            return
        }
        Log.i(TAG, "opening a session")
        val session = GeminiLiveSession(model)
        session.onEvent = { event -> control.post { handle(event, session) } }
        session.connect(token)
        // What was said just before and while this session opens goes first;
        // the session holds it until the server is ready.
        for (chunk in takePreRoll()) session.sendAudio(chunk)
        live = session
    }

    private fun handle(event: GeminiLiveSession.Event, from: GeminiLiveSession) {
        // Events from a session that has since been replaced mean nothing.
        if (from !== live && event !is GeminiLiveSession.Event.Closed && event !is GeminiLiveSession.Event.Failed) return
        when (event) {
            is GeminiLiveSession.Event.Ready -> setState(State.IDLE)

            is GeminiLiveSession.Event.Audio -> {
                // Taking notes, not talking: drop it before the state change
                // too, so the waveform doesn't announce a reply nobody hears.
                if (recordingMode) return
                if (state != State.SPEAKING) setState(State.SPEAKING)
                playback?.enqueue(event.pcm)
            }

            is GeminiLiveSession.Event.Transcript -> {
                // The first words of a new reply replace the last one.
                if (answerFinished) {
                    transcript = ""
                    answerFinished = false
                }
                transcript += event.text
                emitTranscript()
            }

            is GeminiLiveSession.Event.UserTranscript -> userTranscript += event.text

            is GeminiLiveSession.Event.ResumptionHandle -> {
                val handle = event.handle
                main.post { onResumptionHandle?.invoke(handle) }
            }

            is GeminiLiveSession.Event.ToolCalls -> {
                val calls = event.calls
                main.post { onToolCall?.invoke(calls) }
            }

            is GeminiLiveSession.Event.ToolCallCancelled -> {
                val ids = event.ids
                main.post { onToolCancel?.invoke(ids) }
            }

            is GeminiLiveSession.Event.Interrupted -> {
                // The server noticed the user talking over Ordinary. Usually
                // already flushed locally; this covers the cases we missed.
                playback?.flush()
                setState(if (userSpeaking) State.LISTENING else State.IDLE)
            }

            is GeminiLiveSession.Event.TurnComplete -> {
                // A turn that ends while still thinking produced no audio —
                // the normal outcome for anything not addressed to Ordinary.
                if (state == State.THINKING) setState(State.IDLE)
                // Emitted whenever the user said anything, answered or not.
                if (userTranscript.isNotEmpty()) {
                    val question = userTranscript
                    val answer = transcript
                    userTranscript = ""
                    emitExchange(question, answer)
                }
                // The reply stays on screen; the next one starts clean.
                answerFinished = true
            }

            is GeminiLiveSession.Event.GoAway -> {
                renewPending = true
                renewIfQuiet()
            }

            is GeminiLiveSession.Event.Closed -> {
                if (from !== live) return
                Log.e(TAG, "session closed: ${event.reason ?: "no reason"}")
                live = null
                setState(State.IDLE)
                // Always reported, reason or not: the app reconnects on this.
                val message = event.reason?.let { "Connection closed: $it" } ?: "Connection closed"
                main.post { onError?.invoke(message) }
            }

            is GeminiLiveSession.Event.Failed -> {
                if (from !== live) return
                Log.e(TAG, "session failed: ${event.message}")
                live = null
                setState(State.IDLE)
                val message = event.message
                main.post { onError?.invoke(message) }
            }
        }
    }

    /** Hands tool results back to the model, unblocking its turn. */
    fun respond(toolResponses: List<Map<String, Any?>>) {
        control.post { live?.sendToolResponse(toolResponses) }
    }

    /** Ask in text rather than speech. Ordinary still answers out loud. */
    fun ask(text: String) {
        control.post {
            if (live == null) return@post
            setState(State.THINKING)
            live?.sendText(text)
        }
    }

    fun disconnect() {
        live?.close()
        live = null
        control.post {
            playback?.flush()
            // Start listening for a voice afresh: left set, "they are speaking"
            // only clears after a spell of real quiet, and until then nothing
            // new would count as someone starting to talk.
            resetVoiceActivity()
            setState(State.IDLE)
        }
    }

    private val isConnected: Boolean get() = live != null

    // -------------------------------------------------------- capture thread

    private fun captureLoop(rec: AudioRecord) {
        Process.setThreadPriority(Process.THREAD_PRIORITY_URGENT_AUDIO)
        val frame = UPLINK_RATE / 50 // 20 ms, matching the iOS tap cadence
        val samples = ShortArray(frame)
        while (running.get() && record === rec) {
            val n = try {
                rec.read(samples, 0, frame)
            } catch (_: Exception) {
                AudioRecord.ERROR_INVALID_OPERATION
            }
            if (n <= 0) {
                if (!running.get()) break
                if (n == AudioRecord.ERROR_DEAD_OBJECT || n == AudioRecord.ERROR_INVALID_OPERATION) {
                    main.post { rebuildIfStoppedUnderneath("read failed ($n)") }
                    break
                }
                continue
            }
            taps.incrementAndGet()
            if (injecting) mixInjection(samples, n)

            var sum = 0.0
            for (i in 0 until n) {
                val s = samples[i] / 32768.0
                sum += s * s
            }
            val level = AudioPlayback.normalise(sqrt(sum / n).toFloat())

            val bytes = ByteArray(n * 2)
            for (i in 0 until n) {
                val v = samples[i].toInt()
                bytes[i * 2] = (v and 0xFF).toByte()
                bytes[i * 2 + 1] = (v shr 8).toByte()
            }
            val session = live
            if (session != null) session.sendAudio(bytes) else remember(bytes)
            control.post { consider(level) }
        }
    }

    /**
     * Debug builds only: plays [pcm] (16 kHz mono) into the uplink in place of
     * the microphone, in real time, through exactly the same path as speech.
     */
    fun inject(pcm: ShortArray) {
        synchronized(injectLock) {
            injection = pcm
            injectPosition = 0
            injecting = true
        }
    }

    private fun mixInjection(samples: ShortArray, n: Int) {
        synchronized(injectLock) {
            val clip = injection ?: return
            for (i in 0 until n) {
                samples[i] = if (injectPosition < clip.size) clip[injectPosition++] else 0
            }
            if (injectPosition >= clip.size) {
                injection = null
                injecting = false
            }
        }
    }

    // -------------------------------------------------------- control thread

    private fun consider(level: Float) {
        // Stuck in speaking is the worst failure: the orb stops following the
        // user and looks deaf. Check the queue itself rather than trusting a
        // completion to arrive.
        if (state == State.SPEAKING && playback?.isSpeaking != true) {
            Log.i(TAG, "playback drained without a completion — recovering to idle")
            setState(State.IDLE)
        }
        updateVoiceActivity(level)
        // During playback the orb follows Ordinary's voice instead.
        if (state != State.SPEAKING) emitLevel(level)
    }

    private fun updateVoiceActivity(level: Float) {
        if (userSpeaking) {
            quietFrames = if (level < offThreshold) quietFrames + 1 else 0
            if (quietFrames >= framesToStop) {
                userSpeaking = false
                quietFrames = 0
                // They stopped. If a session is live, the model is composing.
                if (isConnected && state == State.LISTENING) setState(State.THINKING)
            }
        } else {
            val talkingOver = state == State.SPEAKING
            val threshold = if (talkingOver) bargeInThreshold else onThreshold
            val needed = if (talkingOver) framesToBargeIn else framesToStart
            framesAboveOn = if (level > threshold) framesAboveOn + 1 else 0
            if (framesAboveOn >= needed) {
                userSpeaking = true
                framesAboveOn = 0
                beginListening()
            }
        }
    }

    /** Barge-in: cut playback the moment the user starts talking. */
    private fun beginListening() {
        if (state == State.SPEAKING) playback?.flush()
        // A new question replaces the last answer on screen.
        if (transcript.isNotEmpty()) {
            transcript = ""
            emitTranscript()
        }
        setState(State.LISTENING)
    }

    private fun resetVoiceActivity() {
        userSpeaking = false
        framesAboveOn = 0
        quietFrames = 0
    }

    private fun setState(next: State) {
        if (next == state) return
        Log.i(TAG, "state ${state.wire} -> ${next.wire}")
        val was = state
        state = next
        main.post { onState?.invoke(next) }
        if (was == State.SPEAKING) abandonFocus()
        if (next == State.IDLE) renewIfQuiet()
    }

    /**
     * Moves to a fresh connection once the server has warned this one is
     * ending and nothing is being said or played — a second or two at a quiet
     * moment instead of the server's hard cut mid-answer.
     */
    private fun renewIfQuiet() {
        if (!renewPending || state != State.IDLE || userSpeaking || live == null) return
        renewPending = false
        Log.i(TAG, "renewing the session before the server ends it")
        live?.close()
        live = null
        main.post { onError?.invoke("Session renewing") }
    }

    private fun emitLevel(level: Float) {
        main.post { onLevel?.invoke(level) }
    }

    private fun emitTranscript() {
        val text = transcript
        main.post { onTranscript?.invoke(text) }
    }

    private fun emitExchange(question: String, answer: String) {
        main.post { onExchangeComplete?.invoke(question, answer) }
    }

    private fun onControl(block: () -> Unit) {
        if (Looper.myLooper() == controlThread.looper) {
            block()
            return
        }
        val done = CountDownLatch(1)
        control.post {
            try {
                block()
            } finally {
                done.countDown()
            }
        }
        done.await(2, TimeUnit.SECONDS)
    }

    // --------------------------------------------------------------- routing

    /**
     * Voice goes to a headset when one is connected, otherwise the
     * loudspeaker — never the earpiece, which is where communication audio
     * lands by default (the Study Mode earpiece bug on iOS, avoided here).
     * Never takes over the audio mode from a phone or VoIP call.
     */
    fun routeForVoice() {
        try {
            when (audioManager.mode) {
                AudioManager.MODE_NORMAL -> {
                    audioManager.mode = AudioManager.MODE_IN_COMMUNICATION
                    ownsMode = true
                }
                AudioManager.MODE_IN_COMMUNICATION -> Unit
                else -> return // a call is in progress
            }
            if (!ownsMode) return
            if (Build.VERSION.SDK_INT >= 31) {
                val devices = audioManager.availableCommunicationDevices
                val target = devices.firstOrNull { it.type in headsetTypes() }
                    ?: devices.firstOrNull { it.type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER }
                if (target != null && audioManager.communicationDevice?.id != target.id) {
                    audioManager.setCommunicationDevice(target)
                }
            } else {
                @Suppress("DEPRECATION")
                run {
                    val outputs = audioManager.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
                    val sco = outputs.any { it.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO }
                    val wired = outputs.any {
                        it.type == AudioDeviceInfo.TYPE_WIRED_HEADSET ||
                            it.type == AudioDeviceInfo.TYPE_WIRED_HEADPHONES ||
                            it.type == AudioDeviceInfo.TYPE_USB_HEADSET
                    }
                    if (sco) {
                        if (!audioManager.isBluetoothScoOn) {
                            audioManager.startBluetoothSco()
                            audioManager.isBluetoothScoOn = true
                        }
                        audioManager.isSpeakerphoneOn = false
                    } else {
                        audioManager.isSpeakerphoneOn = !wired
                    }
                }
            }
        } catch (error: RuntimeException) {
            Log.w(TAG, "routing failed: ${error.message}")
        }
    }

    private fun releaseRoute() {
        if (!ownsMode) return
        ownsMode = false
        try {
            if (Build.VERSION.SDK_INT >= 31) {
                audioManager.clearCommunicationDevice()
            } else {
                @Suppress("DEPRECATION")
                run {
                    if (audioManager.isBluetoothScoOn) {
                        audioManager.isBluetoothScoOn = false
                        audioManager.stopBluetoothSco()
                    }
                    audioManager.isSpeakerphoneOn = false
                }
            }
            if (audioManager.mode == AudioManager.MODE_IN_COMMUNICATION) {
                audioManager.mode = AudioManager.MODE_NORMAL
            }
        } catch (error: RuntimeException) {
            Log.w(TAG, "releasing the route failed: ${error.message}")
        }
    }

    private fun headsetTypes(): Set<Int> {
        val types = mutableSetOf(
            AudioDeviceInfo.TYPE_WIRED_HEADSET,
            AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
            AudioDeviceInfo.TYPE_USB_HEADSET,
            AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
        )
        if (Build.VERSION.SDK_INT >= 31) types.add(AudioDeviceInfo.TYPE_BLE_HEADSET)
        return types
    }

    /** Re-route when headphones or a headset come and go. */
    private fun watchDevices() {
        if (watchingDevices) return
        watchingDevices = true
        audioManager.registerAudioDeviceCallback(object : AudioDeviceCallback() {
            override fun onAudioDevicesAdded(addedDevices: Array<out AudioDeviceInfo>) {
                if (isRunning) routeForVoice()
            }

            override fun onAudioDevicesRemoved(removedDevices: Array<out AudioDeviceInfo>) {
                if (isRunning) routeForVoice()
            }
        }, main)
        if (Build.VERSION.SDK_INT >= 31) {
            // A phone or VoIP call ending puts the mode back to normal; take
            // the voice route back so Ordinary is not left on the earpiece.
            audioManager.addOnModeChangedListener({ it.run() }) { mode ->
                if (mode != AudioManager.MODE_IN_COMMUNICATION) ownsMode = false
                if (mode == AudioManager.MODE_NORMAL && isRunning) main.post { routeForVoice() }
            }
        }
    }

    /**
     * Other apps' sound is lowered while Ordinary speaks and restored after,
     * instead of being stopped for as long as Ordinary is listening.
     */
    private fun requestFocus() {
        if (Build.VERSION.SDK_INT < 26) return
        try {
            val attributes = AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                .build()
            val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK)
                .setAudioAttributes(attributes)
                .setOnAudioFocusChangeListener { }
                .build()
            focusRequest = request
            audioManager.requestAudioFocus(request)
        } catch (error: RuntimeException) {
            Log.w(TAG, "audio focus unavailable: ${error.message}")
        }
    }

    private fun abandonFocus() {
        if (Build.VERSION.SDK_INT < 26) return
        val request = focusRequest as? AudioFocusRequest ?: return
        focusRequest = null
        try {
            audioManager.abandonAudioFocusRequest(request)
        } catch (_: RuntimeException) {
        }
    }

    companion object {
        const val TAG = "Ordinary"

        /** What the Live API wants: 16 kHz mono 16-bit. */
        const val UPLINK_RATE = 16_000

        /** 3 seconds of 16 kHz 16-bit mono. */
        private const val MAX_PRE_ROLL_BYTES = UPLINK_RATE * 2 * 3
    }
}
