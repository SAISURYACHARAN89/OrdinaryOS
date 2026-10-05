package com.atmosphere.ordi_audio

import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/**
 * One live conversation with Gemini. The Android twin of
 * `GeminiLiveSession.swift`; keep the two in step.
 *
 * The phone talks to Google directly — the backend only mints the short-lived
 * token this is opened with. Nothing about the audio path goes through our own
 * server, because a relay hop on every chunk is exactly the latency the
 * product is trying not to have.
 */
internal class GeminiLiveSession(private val model: String) {

    sealed class Event {
        object Ready : Event()

        /** Raw 16-bit little-endian PCM at 24 kHz, ready to play. */
        class Audio(val pcm: ByteArray) : Event()

        /** A fragment of what Ordinary is saying, as it says it. */
        class Transcript(val text: String) : Event()

        /** A fragment of what the *user* said, transcribed by the server. */
        class UserTranscript(val text: String) : Event()

        /** The user cut Ordinary off. Anything already buffered must be thrown away. */
        object Interrupted : Event()

        /** Ordinary finished its turn. */
        object TurnComplete : Event()

        /** A fresh, resumable checkpoint for continuing on a new connection. */
        class ResumptionHandle(val handle: String) : Event()

        /**
         * The model wants the app to do something. The conversation is frozen
         * until every one of these is answered: function calling on this model
         * is synchronous only.
         */
        class ToolCalls(val calls: List<ToolCall>) : Event()

        /** Calls the server has withdrawn (normally barge-in). Must not be answered. */
        class ToolCallCancelled(val ids: List<String>) : Event()

        /** The server will end this connection shortly (about 50 s notice). */
        object GoAway : Event()

        class Closed(val reason: String?) : Event()
        class Failed(val message: String) : Event()
    }

    data class ToolCall(val id: String, val name: String, val args: Map<String, Any?>)

    /** Set to null by [close], after which nothing more is reported. */
    @Volatile
    var onEvent: ((Event) -> Unit)? = null

    /**
     * Outbound messages are serialised off the audio thread. Encoding and
     * sending must never happen on the capture loop.
     */
    private val sendQueue: ExecutorService =
        Executors.newSingleThreadExecutor { r -> Thread(r, "ordi.gemini.send") }

    /** Typed messages waiting for the session to become ready. Only touched on [sendQueue]. */
    private val pendingText = ArrayList<String>()

    /**
     * Microphone audio that arrived before the server acknowledged setup, in
     * order, capped at the most recent few seconds. Only touched on
     * [sendQueue]. See [sendAudio].
     */
    private val pendingAudio = ArrayDeque<ByteArray>()
    private var pendingAudioBytes = 0

    private val isOpen = AtomicBoolean(false)
    private val didSendSetup = AtomicBoolean(false)
    private val reportedClose = AtomicBoolean(false)

    @Volatile
    private var socket: WebSocket? = null

    // ------------------------------------------------------------ connecting

    /** [token] is the ephemeral token from our backend, not the API key. */
    fun connect(token: String) {
        // The same three load-bearing details as on iOS: v1alpha, the
        // *Constrained* method (the only one that accepts a token), and the
        // token interpolated raw — it contains a slash that must not be
        // percent-encoded.
        val url = ENDPOINT + "?access_token=" + token
        val request = try {
            Request.Builder().url(url).build()
        } catch (error: IllegalArgumentException) {
            emit(Event.Failed("Could not build the Live API URL."))
            return
        }
        socket = client.newWebSocket(request, listener)
        sendSetup()
    }

    fun close() {
        // Drop the callback first: everything that follows produces
        // cancellations, and none of it is news to anyone.
        onEvent = null
        isOpen.set(false)
        didSendSetup.set(false)
        sendQueue.execute {
            pendingText.clear()
            pendingAudio.clear()
            pendingAudioBytes = 0
        }
        socket?.close(1001, null)
        socket = null
        sendQueue.shutdown()
    }

    // --------------------------------------------------------------- sending

    private fun sendSetup() {
        // The token already pins the model, modalities and system instruction
        // server-side; this states the same thing rather than contradicting it.
        val setup = JSONObject().put(
            "setup",
            JSONObject()
                .put("model", "models/$model")
                .put("generationConfig", JSONObject().put("responseModalities", JSONArray().put("AUDIO")))
                .put("outputAudioTranscription", JSONObject())
                .put("inputAudioTranscription", JSONObject()),
        )
        execute {
            // OkHttp queues frames sent before the socket opens and delivers
            // them in order once it does, so setup always goes first.
            if (write(setup)) didSendSetup.set(true)
        }
    }

    /**
     * Queues one chunk of microphone audio: raw 16-bit little-endian PCM,
     * 16 kHz mono. Called from the capture thread, so it does no work here.
     */
    fun sendAudio(pcm: ByteArray) {
        if (pcm.isEmpty()) return
        execute {
            // A session is opened the moment someone starts talking after a
            // quiet spell, and takes a second or two to become usable. What
            // they say in that gap — the "Hey Ordinary" included — is held
            // here and sent the moment the session is ready, rather than lost.
            if (!isOpen.get() || !didSendSetup.get()) {
                pendingAudio.addLast(pcm)
                pendingAudioBytes += pcm.size
                while (pendingAudioBytes > MAX_PENDING_AUDIO_BYTES && pendingAudio.isNotEmpty()) {
                    pendingAudioBytes -= pendingAudio.removeFirst().size
                }
                return@execute
            }
            // Audio is realtime: if the network has stalled, drop chunks rather
            // than build a backlog. OkHttp closes a socket whose queue passes
            // 16 MiB, which would turn a slow network into a dead session.
            if ((socket?.queueSize() ?: 0L) > MAX_QUEUED_BYTES) return@execute
            writeAudio(pcm)
        }
    }

    /** Must be called on [sendQueue]. */
    private fun writeAudio(pcm: ByteArray) {
        write(
            JSONObject().put(
                "realtimeInput",
                JSONObject().put(
                    "audio",
                    JSONObject()
                        .put("mimeType", "audio/pcm;rate=16000")
                        .put("data", Codec.encode(pcm)),
                ),
            ),
        )
    }

    /** Sends the audio held while the session was opening. Must be called on [sendQueue]. */
    private fun flushPendingAudio() {
        if (!isOpen.get() || !didSendSetup.get()) return
        while (pendingAudio.isNotEmpty()) writeAudio(pendingAudio.removeFirst())
        pendingAudioBytes = 0
    }

    /** Sends a typed question, as if the user had spoken it. */
    fun sendText(text: String) {
        if (text.isEmpty()) return
        execute {
            // Held until the server has acknowledged setup, then sent — a typed
            // message sent earlier is silently dropped by the server.
            if (!isOpen.get() || !didSendSetup.get()) {
                if (pendingText.size < 4) pendingText.add(text)
                return@execute
            }
            write(textTurn(text))
        }
    }

    /**
     * Answers one or more tool calls. Until this lands the model generates
     * nothing at all, so it must be sent for every call received.
     */
    fun sendToolResponse(responses: List<Map<String, Any?>>) {
        if (responses.isEmpty()) return
        execute {
            if (!isOpen.get() || !didSendSetup.get()) return@execute
            val list = JSONArray()
            for (response in responses) list.put(JsonBridge.toJson(response))
            write(JSONObject().put("toolResponse", JSONObject().put("functionResponses", list)))
        }
    }

    /** Must be called on [sendQueue]. */
    private fun flushPendingText() {
        if (!isOpen.get() || !didSendSetup.get()) return
        val waiting = ArrayList(pendingText)
        pendingText.clear()
        for (text in waiting) write(textTurn(text))
    }

    private fun textTurn(text: String): JSONObject = JSONObject().put(
        "clientContent",
        JSONObject()
            .put(
                "turns",
                JSONArray().put(
                    JSONObject()
                        .put("role", "user")
                        .put("parts", JSONArray().put(JSONObject().put("text", text))),
                ),
            )
            .put("turnComplete", true),
    )

    /** Must be called on [sendQueue]. */
    private fun write(message: JSONObject): Boolean = socket?.send(message.toString()) ?: false

    private fun execute(block: () -> Unit) {
        try {
            sendQueue.execute(block)
        } catch (_: java.util.concurrent.RejectedExecutionException) {
            // Closed. Nothing to send it on.
        }
    }

    private fun emit(event: Event) {
        onEvent?.invoke(event)
    }

    // ------------------------------------------------------------- receiving

    private val listener = object : WebSocketListener() {
        override fun onMessage(webSocket: WebSocket, text: String) {
            handle(text)
        }

        override fun onMessage(webSocket: WebSocket, bytes: ByteString) {
            handle(bytes.utf8())
        }

        override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
            isOpen.set(false)
            webSocket.close(1000, null)
            if (reportedClose.compareAndSet(false, true)) {
                emit(Event.Closed(reason.ifEmpty { null }))
            }
        }

        override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
            isOpen.set(false)
            if (reportedClose.compareAndSet(false, true)) {
                emit(Event.Closed(reason.ifEmpty { null }))
            }
        }

        override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
            isOpen.set(false)
            if (reportedClose.compareAndSet(false, true)) {
                emit(Event.Failed(t.message ?: "Connection failed"))
            }
        }
    }

    /** Parses one server message. Internal so the parsing can be unit-tested. */
    internal fun handle(text: String) {
        val root = try {
            JSONObject(text)
        } catch (_: Exception) {
            return
        }

        if (root.has("setupComplete")) {
            isOpen.set(true)
            // Speech first, in the order it was said; then anything typed.
            execute {
                flushPendingAudio()
                flushPendingText()
            }
            emit(Event.Ready)
            return
        }

        // A sibling of `serverContent`, not nested inside it.
        root.optJSONObject("sessionResumptionUpdate")?.let { update ->
            val handle = update.optString("newHandle", "")
            if (update.optBoolean("resumable", false) && handle.isNotEmpty()) {
                emit(Event.ResumptionHandle(handle))
            }
        }

        if (root.has("goAway")) {
            emit(Event.GoAway)
            return
        }

        // Also siblings of `serverContent`, checked before it.
        val functions = root.optJSONObject("toolCall")?.optJSONArray("functionCalls")
        if (functions != null) {
            val calls = ArrayList<ToolCall>()
            for (i in 0 until functions.length()) {
                val fn = functions.optJSONObject(i) ?: continue
                val name = fn.optString("name", "")
                // A call without an id cannot be answered, so it is dropped.
                val id = fn.optString("id", "")
                if (name.isEmpty() || id.isEmpty()) continue
                val args = fn.optJSONObject("args")?.let { JsonBridge.toMap(it) } ?: emptyMap()
                calls.add(ToolCall(id, name, args))
            }
            if (calls.isNotEmpty()) emit(Event.ToolCalls(calls))
            return
        }

        val cancelled = root.optJSONObject("toolCallCancellation")?.optJSONArray("ids")
        if (cancelled != null) {
            val ids = (0 until cancelled.length()).map { cancelled.optString(it) }.filter { it.isNotEmpty() }
            emit(Event.ToolCallCancelled(ids))
            return
        }

        val content = root.optJSONObject("serverContent") ?: return

        // Order matters: an interruption invalidates audio that may be sitting
        // in the same message, so act on it before queueing anything.
        if (content.optBoolean("interrupted", false)) emit(Event.Interrupted)

        content.optJSONObject("outputTranscription")?.optString("text", "")
            ?.takeIf { it.isNotEmpty() }?.let { emit(Event.Transcript(it)) }

        content.optJSONObject("inputTranscription")?.optString("text", "")
            ?.takeIf { it.isNotEmpty() }?.let { emit(Event.UserTranscript(it)) }

        content.optJSONObject("modelTurn")?.optJSONArray("parts")?.let { parts ->
            for (i in 0 until parts.length()) {
                val encoded = parts.optJSONObject(i)?.optJSONObject("inlineData")
                    ?.optString("data", "") ?: continue
                if (encoded.isEmpty()) continue
                val audio = try {
                    Codec.decode(encoded)
                } catch (_: IllegalArgumentException) {
                    continue
                }
                emit(Event.Audio(audio))
            }
        }

        if (content.optBoolean("turnComplete", false)) emit(Event.TurnComplete)
    }

    companion object {
        private const val ENDPOINT = "wss://generativelanguage.googleapis.com/ws/" +
            "google.ai.generativelanguage.v1alpha.GenerativeService" +
            ".BidiGenerateContentConstrained"

        private const val MAX_QUEUED_BYTES = 2L * 1024 * 1024

        /** 8 seconds of 16 kHz 16-bit mono. */
        private const val MAX_PENDING_AUDIO_BYTES = 16_000 * 2 * 8

        /** Shared: one connection pool and dispatcher for every session. */
        private val client: OkHttpClient by lazy {
            OkHttpClient.Builder()
                .connectTimeout(30, TimeUnit.SECONDS)
                .readTimeout(0, TimeUnit.MILLISECONDS)
                // No pings, like URLSession on iOS: audio flows continuously,
                // and an unanswered ping would fail a healthy socket.
                .build()
        }
    }
}

/** Base64, swappable so parsing can be tested on the JVM without Android. */
internal object Codec {
    var encode: (ByteArray) -> String = { android.util.Base64.encodeToString(it, android.util.Base64.NO_WRAP) }
    var decode: (String) -> ByteArray = { android.util.Base64.decode(it, android.util.Base64.DEFAULT) }
}

/** org.json <-> the plain maps and lists Flutter's codec carries. */
internal object JsonBridge {
    fun toMap(json: JSONObject): Map<String, Any?> {
        val out = LinkedHashMap<String, Any?>()
        val keys = json.keys()
        while (keys.hasNext()) {
            val key = keys.next()
            out[key] = fromJson(json.opt(key))
        }
        return out
    }

    private fun fromJson(value: Any?): Any? = when (value) {
        null, JSONObject.NULL -> null
        is JSONObject -> toMap(value)
        is JSONArray -> (0 until value.length()).map { fromJson(value.opt(it)) }
        else -> value
    }

    fun toJson(value: Any?): Any = when (value) {
        null -> JSONObject.NULL
        is Map<*, *> -> JSONObject().also { obj ->
            for ((k, v) in value) obj.put(k.toString(), toJson(v))
        }
        is List<*> -> JSONArray().also { arr -> for (v in value) arr.put(toJson(v)) }
        is Array<*> -> JSONArray().also { arr -> for (v in value) arr.put(toJson(v)) }
        else -> value
    }
}
