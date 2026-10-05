package com.atmosphere.ordi_audio

import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.time.OffsetDateTime
import java.util.Base64
import java.util.concurrent.CopyOnWriteArrayList
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertTrue

/**
 * The Android session code against the real Live API: token from our backend,
 * speech streamed in real time exactly as the capture thread sends it, and the
 * replies parsed by [GeminiLiveSession]. Skipped unless ORDI_LIVE_TEST=1, with
 * ORDI_BACKEND, ORDI_CLIENT_SECRET and ORDI_CLIPS (a folder of 16 kHz mono
 * WAVs) set. Never prints the token or the secret.
 */
internal class LiveIntegrationTest {

    private val enabled = System.getenv("ORDI_LIVE_TEST") == "1"
    private val backend = System.getenv("ORDI_BACKEND") ?: ""
    private val secret = System.getenv("ORDI_CLIENT_SECRET") ?: ""
    private val clips = File(System.getenv("ORDI_CLIPS") ?: ".")

    @BeforeTest
    fun setUp() {
        Codec.encode = { Base64.getEncoder().encodeToString(it) }
        Codec.decode = { Base64.getDecoder().decode(it) }
    }

    private class Run(val session: GeminiLiveSession) {
        val events = CopyOnWriteArrayList<GeminiLiveSession.Event>()
        val said get() = events.filterIsInstance<GeminiLiveSession.Event.Transcript>().joinToString("") { it.text }
        val heard get() = events.filterIsInstance<GeminiLiveSession.Event.UserTranscript>().joinToString("") { it.text }
        val audioBytes get() = events.filterIsInstance<GeminiLiveSession.Event.Audio>().sumOf { it.pcm.size }
        val tools get() = events.filterIsInstance<GeminiLiveSession.Event.ToolCalls>().flatMap { it.calls }
        val turns get() = events.count { it is GeminiLiveSession.Event.TurnComplete }
        val failed get() = events.filterIsInstance<GeminiLiveSession.Event.Failed>().map { it.message } +
            events.filterIsInstance<GeminiLiveSession.Event.Closed>().map { "closed: ${it.reason}" }
    }

    private fun open(answerTools: Boolean = true): Run {
        val body = JSONObject()
            .put("deviceId", "android-live-test")
            .put("tools", true).put("toolsV2", true).put("toolsV3", true).put("toolsV4", true)
            .put("now", OffsetDateTime.now().toString())
            .toString()
        val response = OkHttpClient().newCall(
            Request.Builder().url("$backend/session")
                .header("x-ordi-key", secret)
                .post(body.toRequestBody("application/json".toMediaType()))
                .build(),
        ).execute()
        val json = JSONObject(response.body!!.string())
        val token = json.optString("token")
        check(token.isNotEmpty()) { "no token: ${json.optString("error")}" }

        val session = GeminiLiveSession(json.getString("model"))
        val run = Run(session)
        session.onEvent = { event ->
            run.events.add(event)
            // Answer every call, as the plugin's bridge does.
            if (answerTools && event is GeminiLiveSession.Event.ToolCalls) {
                session.sendToolResponse(
                    event.calls.map { call ->
                        val result: Any = when (call.name) {
                            "create_reminder" -> mapOf("result" to "Reminder set.")
                            "list_reminders" -> mapOf("result" to mapOf("reminders" to listOf(mapOf("title" to "Drink water", "due" to "in 5 minutes"))))
                            else -> mapOf("result" to "ok")
                        }
                        mapOf("id" to call.id, "name" to call.name, "response" to result)
                    },
                )
            }
        }
        session.connect(token)
        waitFor(10_000) { run.events.any { it is GeminiLiveSession.Event.Ready } }
        return run
    }

    private fun pcm(name: String): ShortArray {
        val bytes = File(clips, "$name.wav").readBytes()
        val buffer = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
        var offset = 12
        while (offset + 8 <= bytes.size) {
            val id = String(bytes, offset, 4, Charsets.US_ASCII)
            val size = buffer.getInt(offset + 4)
            if (id == "data") {
                return ShortArray(size / 2) { buffer.getShort(offset + 8 + it * 2) }
            }
            offset += 8 + size + (size and 1)
        }
        error("no data chunk in $name.wav")
    }

    /** Streams like the capture thread: 20 ms chunks, in real time, then silence. */
    private fun speak(run: Run, name: String, silenceMs: Int = 1500) {
        val samples = pcm(name)
        val frame = 320
        var i = 0
        while (i < samples.size + silenceMs * 16) {
            val bytes = ByteArray(frame * 2)
            for (j in 0 until frame) {
                val v = if (i + j < samples.size) samples[i + j].toInt() else 0
                bytes[j * 2] = (v and 0xFF).toByte()
                bytes[j * 2 + 1] = (v shr 8).toByte()
            }
            run.session.sendAudio(bytes)
            i += frame
            Thread.sleep(20)
        }
    }

    private fun waitFor(ms: Long, condition: () -> Boolean) {
        val end = System.currentTimeMillis() + ms
        while (System.currentTimeMillis() < end && !condition()) Thread.sleep(50)
    }

    private fun report(name: String, run: Run) {
        println("[$name] heard='${run.heard.trim()}' said='${run.said.trim()}' audio=${run.audioBytes}B " +
            "tools=${run.tools.map { it.name }} turns=${run.turns} failed=${run.failed}")
    }

    @Test
    fun answersASpokenQuestionOutLoud() {
        if (!enabled) return
        val run = open()
        speak(run, "ask")
        waitFor(20_000) { run.turns >= 1 && run.audioBytes > 0 }
        Thread.sleep(500)
        report("ask", run)
        run.session.close()
        assertTrue(run.failed.isEmpty(), "session failed: ${run.failed}")
        assertTrue(run.heard.contains("France", ignoreCase = true), "did not hear the question")
        assertTrue(run.audioBytes > 24_000, "no spoken answer") // > 0.5 s of 24 kHz audio
        assertTrue(run.said.contains("Paris", ignoreCase = true), "answer transcript missing")
    }

    @Test
    fun setsAReminderThroughATool() {
        if (!enabled) return
        val run = open()
        speak(run, "remind")
        waitFor(20_000) { run.tools.any { it.name == "create_reminder" } && run.audioBytes > 0 && run.turns >= 1 }
        Thread.sleep(500)
        report("remind", run)
        run.session.close()
        val call = run.tools.firstOrNull { it.name == "create_reminder" }
        assertTrue(call != null, "no create_reminder call")
        assertTrue(call.args.values.any { it.toString().contains("water", ignoreCase = true) }, "reminder args: ${call.args}")
        assertTrue(run.audioBytes > 0, "no spoken confirmation after the tool reply")
    }

    @Test
    fun staysSilentForTalkNotAddressedToIt() {
        if (!enabled) return
        val run = open()
        speak(run, "chat")
        waitFor(15_000) { run.turns >= 1 }
        Thread.sleep(1000)
        report("chat", run)
        run.session.close()
        assertTrue(run.failed.isEmpty(), "session failed: ${run.failed}")
        assertTrue(run.audioBytes == 0, "answered overheard talk")
    }

    @Test
    fun readsAppDataWithNestedToolResults() {
        if (!enabled) return
        val run = open()
        speak(run, "list")
        waitFor(20_000) { run.tools.any { it.name == "list_reminders" } && run.audioBytes > 0 && run.turns >= 1 }
        Thread.sleep(500)
        report("list", run)
        run.session.close()
        assertTrue(run.tools.any { it.name == "list_reminders" }, "no list_reminders call")
        assertTrue(run.said.contains("water", ignoreCase = true), "answer did not use the tool result")
    }

    @Test
    fun typedMessageSentBeforeReadyIsHeldAndAnswered() {
        if (!enabled) return
        // Open without waiting for ready, and send straight away — the path a
        // spoken reminder or voice sample takes on a fresh connection.
        val body = JSONObject().put("deviceId", "android-live-test").put("tools", true).put("toolsV2", true)
            .put("toolsV3", true).put("toolsV4", true).put("now", OffsetDateTime.now().toString()).toString()
        val json = JSONObject(
            OkHttpClient().newCall(
                Request.Builder().url("$backend/session").header("x-ordi-key", secret)
                    .post(body.toRequestBody("application/json".toMediaType())).build(),
            ).execute().body!!.string(),
        )
        val session = GeminiLiveSession(json.getString("model"))
        val run = Run(session)
        session.onEvent = { run.events.add(it) }
        session.connect(json.getString("token"))
        session.sendText("[ordi] remind: stretch your legs")
        waitFor(20_000) { run.turns >= 1 && run.audioBytes > 0 }
        report("pending-text", run)
        session.close()
        assertTrue(run.audioBytes > 0, "text sent before ready was dropped")
    }
}
