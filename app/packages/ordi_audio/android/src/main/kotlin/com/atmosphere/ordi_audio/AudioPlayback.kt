package com.atmosphere.ordi_audio

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.os.Process
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import kotlin.math.log10
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sqrt

/**
 * Plays Ordinary's voice, and — more importantly — stops it instantly. The
 * Android twin of `AudioPlayback.swift`.
 *
 * Gemini streams 24 kHz PCM back in chunks, faster than it is spoken, so most
 * of an answer sits queued here. When the user interrupts, [flush] throws that
 * queue away rather than letting it drain: the trailing second is what makes an
 * assistant feel like a walkie-talkie.
 *
 * Chunks are written from a dedicated thread in 20 ms pieces, so a flush from
 * the engine's control thread takes effect within one piece.
 */
internal class AudioPlayback(
    /** Playback level, 0..1, from the audio as it is written to the device. */
    private val onLevel: (Float) -> Unit,
    /** The queue emptied and everything written has actually been played. */
    private val onFinished: () -> Unit,
    /** Called just before sound starts, to (re)claim the speaker route. */
    private val beforePlay: () -> Unit,
) {
    private class Chunk(val samples: ShortArray, val era: Int)

    private val track: AudioTrack
    private val queue = LinkedBlockingQueue<Chunk>()

    /** Bumped on every flush so stale chunks and completions are ignored. */
    private val generation = AtomicInteger(0)

    /** Chunks queued or being written in the current generation. */
    private val pending = AtomicInteger(0)

    /** Frames written since the last flush; compared with the play head. */
    private val written = AtomicLong(0)

    @Volatile
    private var alive = true

    @Volatile
    private var playing = false

    private val thread: Thread

    init {
        val minBuffer = AudioTrack.getMinBufferSize(
            SAMPLE_RATE, AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_16BIT,
        )
        track = AudioTrack.Builder()
            .setAudioAttributes(
                // Voice communication, so the platform's echo canceller has
                // this as its reference and Ordinary does not hear itself.
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                    .build(),
            )
            .setAudioFormat(
                AudioFormat.Builder()
                    .setSampleRate(SAMPLE_RATE)
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                    .build(),
            )
            .setBufferSizeInBytes(max(minBuffer, SAMPLE_RATE / 10 * 2))
            .setTransferMode(AudioTrack.MODE_STREAM)
            .build()

        thread = Thread({ run() }, "ordi.playback").apply { start() }
    }

    /** Queues one chunk of raw 16-bit little-endian PCM at 24 kHz. */
    fun enqueue(pcm16: ByteArray) {
        val count = pcm16.size / 2
        if (count == 0) return
        val samples = ShortArray(count)
        for (i in 0 until count) {
            val lo = pcm16[i * 2].toInt() and 0xFF
            val hi = pcm16[i * 2 + 1].toInt()
            samples[i] = ((hi shl 8) or lo).toShort()
        }
        pending.incrementAndGet()
        queue.put(Chunk(samples, generation.get()))
    }

    /** Drops everything queued and not yet heard. This is barge-in. */
    fun flush() {
        generation.incrementAndGet()
        queue.clear()
        pending.set(0)
        try {
            track.pause()
            track.flush()
        } catch (_: IllegalStateException) {
        }
        written.set(0)
        playing = false
        onLevel(0f)
    }

    val isSpeaking: Boolean
        get() = pending.get() > 0 || (playing && !drained())

    // The play head, and when it last moved. Touched from the playback and
    // control threads; a stale read only delays "finished" by one check.
    @Volatile
    private var lastHead = -1L

    @Volatile
    private var headMovedAt = 0L

    /**
     * Everything written has been heard. Normally the play head reaches the
     * frames written; some devices stop it a few frames short, so a head that
     * has not moved for [STALL_MS] with nothing queued counts as done too —
     * otherwise Ordinary could sit in "speaking" for good.
     */
    private fun drained(): Boolean {
        val head = headPosition()
        val now = System.nanoTime() / 1_000_000
        if (head != lastHead) {
            lastHead = head
            headMovedAt = now
        }
        return head >= written.get() || now - headMovedAt > STALL_MS
    }

    fun release() {
        alive = false
        flush()
        thread.interrupt()
        try {
            thread.join(500)
        } catch (_: InterruptedException) {
        }
        track.release()
    }

    private fun headPosition(): Long = try {
        track.playbackHeadPosition.toLong() and 0xFFFFFFFFL
    } catch (_: IllegalStateException) {
        0L
    }

    private fun run() {
        Process.setThreadPriority(Process.THREAD_PRIORITY_URGENT_AUDIO)
        val piece = SAMPLE_RATE / 50 // 20 ms
        while (alive) {
            val chunk = try {
                queue.poll(20, TimeUnit.MILLISECONDS)
            } catch (_: InterruptedException) {
                null
            }

            if (chunk == null) {
                // Nothing left to write. Report the end once the device has
                // actually played everything, not when the last write returned.
                if (playing && pending.get() == 0 && drained()) {
                    playing = false
                    val era = generation.get()
                    try {
                        track.pause()
                    } catch (_: IllegalStateException) {
                    }
                    if (era == generation.get()) {
                        onLevel(0f)
                        onFinished()
                    }
                }
                continue
            }

            if (chunk.era != generation.get()) continue

            if (!playing) {
                beforePlay()
                try {
                    track.play()
                } catch (_: IllegalStateException) {
                    continue
                }
                playing = true
                headMovedAt = System.nanoTime() / 1_000_000
            }

            var offset = 0
            while (offset < chunk.samples.size && alive) {
                if (chunk.era != generation.get()) break
                val length = min(piece, chunk.samples.size - offset)
                val n = track.write(chunk.samples, offset, length, AudioTrack.WRITE_BLOCKING)
                if (n <= 0) break
                if (chunk.era != generation.get()) {
                    // Flushed while this piece was being written: make sure it
                    // is not heard either.
                    try {
                        track.pause()
                        track.flush()
                    } catch (_: IllegalStateException) {
                    }
                    written.set(0)
                    break
                }
                written.addAndGet(n.toLong())
                headMovedAt = System.nanoTime() / 1_000_000
                onLevel(level(chunk.samples, offset, n))
                offset += n
            }
            if (chunk.era == generation.get()) pending.decrementAndGet()
        }
    }

    companion object {
        /** Gemini's output rate. Note it differs from the 16 kHz sent up. */
        const val SAMPLE_RATE = 24_000

        /** A play head still for this long, with nothing queued, has finished. */
        private const val STALL_MS = 500L

        /** Same dBFS mapping as the microphone side. */
        fun level(samples: ShortArray, offset: Int, count: Int): Float {
            if (count <= 0) return 0f
            var sum = 0.0
            for (i in offset until offset + count) {
                val s = samples[i] / 32768.0
                sum += s * s
            }
            return normalise(sqrt(sum / count).toFloat())
        }

        fun normalise(rms: Float): Float {
            if (rms <= 0f) return 0f
            val db = 20f * log10(rms)
            return (min(max(db, -52f), -12f) + 52f) / 40f
        }
    }
}
