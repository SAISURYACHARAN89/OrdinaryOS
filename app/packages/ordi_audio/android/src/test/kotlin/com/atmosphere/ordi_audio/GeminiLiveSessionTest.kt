package com.atmosphere.ordi_audio

import java.util.Base64
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertTrue

/**
 * The server-message parser, against the message shapes the Live API sends.
 * Mirrors the cases GeminiLiveSession.swift handles.
 */
internal class GeminiLiveSessionTest {

    private val events = ArrayList<GeminiLiveSession.Event>()
    private lateinit var session: GeminiLiveSession

    @BeforeTest
    fun setUp() {
        Codec.encode = { Base64.getEncoder().encodeToString(it) }
        Codec.decode = { Base64.getDecoder().decode(it) }
        session = GeminiLiveSession("test-model")
        session.onEvent = { events.add(it) }
    }

    @Test
    fun setupCompleteMeansReady() {
        session.handle("""{"setupComplete":{}}""")
        assertIs<GeminiLiveSession.Event.Ready>(events.single())
    }

    @Test
    fun audioTranscriptsAndTurnCompleteInOrder() {
        val pcm = byteArrayOf(1, 0, -1, -1)
        val b64 = Base64.getEncoder().encodeToString(pcm)
        session.handle(
            """{"serverContent":{"outputTranscription":{"text":"Hi"},"inputTranscription":{"text":"hey ordinary"},
               "modelTurn":{"parts":[{"inlineData":{"mimeType":"audio/pcm;rate=24000","data":"$b64"}}]},
               "turnComplete":true}}""",
        )
        assertEquals(4, events.size)
        assertEquals("Hi", (events[0] as GeminiLiveSession.Event.Transcript).text)
        assertEquals("hey ordinary", (events[1] as GeminiLiveSession.Event.UserTranscript).text)
        assertTrue((events[2] as GeminiLiveSession.Event.Audio).pcm.contentEquals(pcm))
        assertIs<GeminiLiveSession.Event.TurnComplete>(events[3])
    }

    @Test
    fun interruptionComesBeforeAudioInTheSameMessage() {
        val b64 = Base64.getEncoder().encodeToString(byteArrayOf(0, 0))
        session.handle("""{"serverContent":{"modelTurn":{"parts":[{"inlineData":{"data":"$b64"}}]},"interrupted":true}}""")
        assertIs<GeminiLiveSession.Event.Interrupted>(events[0])
        assertIs<GeminiLiveSession.Event.Audio>(events[1])
    }

    @Test
    fun toolCallsCarryIdsNamesAndNestedArgs() {
        session.handle(
            """{"toolCall":{"functionCalls":[
                {"id":"a1","name":"add_reminder","args":{"title":"Water","in_minutes":2,"tags":["x",null],"when":{"time":"10:00"}}},
                {"name":"no_id"}]}}""",
        )
        val calls = (events.single() as GeminiLiveSession.Event.ToolCalls).calls
        assertEquals(1, calls.size) // the call without an id cannot be answered
        assertEquals("a1", calls[0].id)
        assertEquals("add_reminder", calls[0].name)
        assertEquals("Water", calls[0].args["title"])
        assertEquals(2, calls[0].args["in_minutes"])
        assertEquals(listOf("x", null), calls[0].args["tags"])
        assertEquals(mapOf("time" to "10:00"), calls[0].args["when"])
    }

    @Test
    fun cancellationResumptionAndGoAway() {
        session.handle("""{"toolCallCancellation":{"ids":["a1","b2"]}}""")
        session.handle("""{"sessionResumptionUpdate":{"newHandle":"h1","resumable":true}}""")
        session.handle("""{"sessionResumptionUpdate":{"newHandle":"h2","resumable":false}}""")
        session.handle("""{"goAway":{"timeLeft":"50s"}}""")
        assertEquals(listOf("a1", "b2"), (events[0] as GeminiLiveSession.Event.ToolCallCancelled).ids)
        assertEquals("h1", (events[1] as GeminiLiveSession.Event.ResumptionHandle).handle)
        assertIs<GeminiLiveSession.Event.GoAway>(events[2])
        assertEquals(3, events.size) // the non-resumable handle is not forwarded
    }

    @Test
    fun malformedAndUnknownMessagesAreIgnored() {
        session.handle("not json")
        session.handle("""{"usageMetadata":{"promptTokenCount":10}}""")
        session.handle("""{"serverContent":{"outputTranscription":{"text":""}}}""")
        assertTrue(events.isEmpty())
    }

    @Test
    fun toolResponsesSerialiseNestedValues() {
        val json = JsonBridge.toJson(
            mapOf("id" to "a1", "response" to mapOf("result" to "ok", "items" to listOf(1, "two", null))),
        ).toString()
        assertEquals("""{"id":"a1","response":{"result":"ok","items":[1,"two",null]}}""".length, json.length)
        assertTrue(json.contains("\"items\":[1,\"two\",null]"))
    }

    @Test
    fun levelMappingMatchesIos() {
        assertEquals(0f, AudioPlayback.normalise(0f))
        assertEquals(0f, AudioPlayback.normalise(0.0001f)) // below -52 dBFS
        assertEquals(1f, AudioPlayback.normalise(0.5f)) // above -12 dBFS
        assertEquals(0.3f, AudioPlayback.normalise(0.01f), 0.001f) // -40 dBFS
    }
}
