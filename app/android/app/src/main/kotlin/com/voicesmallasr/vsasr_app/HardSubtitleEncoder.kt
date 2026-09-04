package com.voicesmallasr.vsasr_app

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.SurfaceTexture
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMuxer
import android.net.Uri
import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLSurface
import android.opengl.EGLExt
import android.opengl.GLES11Ext
import android.opengl.GLES20
import android.opengl.GLUtils
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.view.Surface
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer
import java.util.concurrent.Executors
import kotlin.math.max
import kotlin.math.min

/** Android 系统视频转码：MediaCodec + OpenGL 叠加字幕，MediaMuxer 复用或生成 AAC 音轨。 */
object HardSubtitleEncoderChannel {
    const val NAME = "vsasr/hard_subtitle"

    private val worker = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())

    fun register(messenger: BinaryMessenger, context: Context) {
        MethodChannel(messenger, NAME).setMethodCallHandler { call, result ->
            if (call.method != "encode") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val inputPath = call.argument<String>("inputPath")
            val outputPath = call.argument<String>("outputPath")
            val segments = call.argument<List<Any?>>("segments")
            val style = call.argument<Map<String, Any?>>("style")
            if (inputPath.isNullOrBlank() || outputPath.isNullOrBlank() || segments == null || style == null) {
                result.error("BAD_ARGS", "硬字幕编码参数不完整", null)
                return@setMethodCallHandler
            }
            worker.execute {
                try {
                    TranscriptionService.start(context, "正在压制视频字幕...")
                    AndroidHardSubtitleEncoder(context).encode(
                        inputPath,
                        outputPath,
                        parseCues(segments),
                        SubtitleRenderStyle.fromMap(style),
                    )
                    mainHandler.post { result.success(null) }
                } catch (error: Throwable) {
                    mainHandler.post {
                        result.error(
                            "ENCODE_FAILED",
                            error.message ?: "Android 硬字幕编码失败",
                            null,
                        )
                    }
                } finally {
                    TranscriptionService.stop(context)
                }
            }
        }
    }

    private fun parseCues(raw: List<Any?>): List<SubtitleCue> = raw.mapNotNull { item ->
        val map = item as? Map<*, *> ?: return@mapNotNull null
        val start = (map["start"] as? Number)?.toDouble() ?: return@mapNotNull null
        val end = (map["end"] as? Number)?.toDouble() ?: return@mapNotNull null
        if (!start.isFinite() || !end.isFinite() || end <= start) return@mapNotNull null
        SubtitleCue(
            start,
            end,
            map["text"] as? String ?: "",
            map["translation"] as? String,
            map["speaker"] as? String,
        )
    }
}

private data class SubtitleCue(
    val start: Double,
    val end: Double,
    val text: String,
    val translation: String?,
    val speaker: String?,
)

private data class SubtitleRenderStyle(
    val fontSize: Float,
    val textColor: Int,
    val backgroundColor: Int,
    val position: Position,
) {
    enum class Position { TOP, CENTER, BOTTOM }

    companion object {
        fun fromMap(map: Map<String, Any?>): SubtitleRenderStyle {
            val fontSize = (map["fontSize"] as? Number)?.toFloat()
                ?: throw IllegalArgumentException("字幕字号无效")
            val textColor = (map["textColor"] as? Number)?.toInt()
                ?: throw IllegalArgumentException("字幕文字颜色无效")
            val backgroundColor = (map["backgroundColor"] as? Number)?.toInt()
                ?: throw IllegalArgumentException("字幕背景颜色无效")
            val position = when ((map["position"] as? String)?.lowercase()) {
                "top" -> Position.TOP
                "center" -> Position.CENTER
                "bottom" -> Position.BOTTOM
                else -> throw IllegalArgumentException("字幕位置无效")
            }
            require(fontSize in 12f..48f) { "字幕字号超出范围" }
            return SubtitleRenderStyle(fontSize, textColor, backgroundColor, position)
        }
    }
}

private class AndroidHardSubtitleEncoder(private val context: Context) {
    private companion object {
        const val TIMEOUT_US = 10_000L
        const val MAX_IDLE_ROUNDS = 3000
        const val VIDEO_MIME = "video/avc"
    }

    fun encode(
        inputPath: String,
        outputPath: String,
        cues: List<SubtitleCue>,
        style: SubtitleRenderStyle,
    ) {
        val input = File(inputPath)
        require(input.isFile) { "输入视频不存在" }
        if (!outputPath.startsWith("content://")) {
            val output = File(outputPath)
            require(input.canonicalFile != output.canonicalFile) {
                "输出视频不能覆盖输入视频"
            }
            require(output.extension.equals("mp4", ignoreCase = true)) {
                "Android 硬字幕输出目前只支持 .mp4 文件"
            }
        }

        val extractor = MediaExtractor()
        var decoder: MediaCodec? = null
        var encoder: MediaCodec? = null
        var renderer: GlVideoRenderer? = null
        var audioExtractor: MediaExtractor? = null
        var muxerHandle: MuxerHandle? = null
        try {
            extractor.setDataSource(inputPath)
            val videoTrack = selectTrack(extractor, "video/")
            require(videoTrack >= 0) { "文件里没有视频轨道" }
            extractor.selectTrack(videoTrack)
            val inputFormat = extractor.getTrackFormat(videoTrack)
            val sourceWidth = inputFormat.getInteger(MediaFormat.KEY_WIDTH)
            val sourceHeight = inputFormat.getInteger(MediaFormat.KEY_HEIGHT)
            val width = sourceWidth and 0xFFFFFFFE.toInt()
            val height = sourceHeight and 0xFFFFFFFE.toInt()
            require(width > 0 && height > 0) { "视频尺寸无效：${sourceWidth}x${sourceHeight}" }
            val videoMime = inputFormat.getString(MediaFormat.KEY_MIME)
                ?: throw IllegalArgumentException("视频轨道缺少 MIME 类型")
            val durationUs = readLong(inputFormat, MediaFormat.KEY_DURATION, 0L)
            val rotation = readInteger(inputFormat, MediaFormat.KEY_ROTATION, 0)
            val frameRate = readInteger(inputFormat, MediaFormat.KEY_FRAME_RATE, 30)
                .coerceIn(1, 120)

            val audioInfo = findAudioTrack(inputPath)
            var audioFormat: MediaFormat? = null
            var audioSamples: List<EncodedAudioSample>? = null
            if (audioInfo != null) {
                val audioMime = audioInfo.format.getString(MediaFormat.KEY_MIME).orEmpty()
                if (audioMime == "audio/mp4a-latm" || audioMime == "audio/aac") {
                    audioFormat = audioInfo.format
                    audioExtractor = audioInfo.extractor
                } else {
                    // 非 AAC 音轨不能直接交给 MediaMuxer，先用系统编解码器转成 AAC。
                    audioInfo.extractor.release()
                    val transcodedAudio = transcodeAudio(
                        inputPath,
                        audioInfo.trackIndex,
                        audioInfo.format,
                    )
                    audioFormat = transcodedAudio.format
                    audioSamples = transcodedAudio.samples
                }
            }

            val outputFormat = MediaFormat.createVideoFormat(VIDEO_MIME, width, height)
            outputFormat.setInteger(
                MediaFormat.KEY_COLOR_FORMAT,
                MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface,
            )
            outputFormat.setInteger(MediaFormat.KEY_BIT_RATE, videoBitrate(width, height))
            outputFormat.setInteger(MediaFormat.KEY_FRAME_RATE, frameRate)
            outputFormat.setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 2)

            encoder = MediaCodec.createEncoderByType(VIDEO_MIME)
            encoder.configure(outputFormat, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            val encoderSurface = encoder.createInputSurface()
            renderer = GlVideoRenderer(encoderSurface, width, height)
            decoder = MediaCodec.createDecoderByType(videoMime)
            decoder.configure(inputFormat, renderer.decoderSurface, null, 0)

            muxerHandle = openMuxer(outputPath)
            if (rotation == 90 || rotation == 180 || rotation == 270) {
                muxerHandle.muxer.setOrientationHint(rotation)
            }
            encoder.start()
            decoder.start()

            val state = EncodeState(
                muxerHandle.muxer,
                audioFormat,
                audioExtractor,
                audioSamples,
            )
            var lastCueIndex = -1
            var inputDone = false
            var decoderDone = false
            var idleRounds = 0
            val decoderInfo = MediaCodec.BufferInfo()

            while (!decoderDone) {
                if (!inputDone) {
                    val inputIndex = decoder.dequeueInputBuffer(TIMEOUT_US)
                    if (inputIndex >= 0) {
                        val buffer = decoder.getInputBuffer(inputIndex)
                            ?: throw IllegalStateException("取不到视频解码输入缓冲")
                        buffer.clear()
                        val size = extractor.readSampleData(buffer, 0)
                        if (size < 0) {
                            decoder.queueInputBuffer(
                                inputIndex,
                                0,
                                0,
                                0,
                                MediaCodec.BUFFER_FLAG_END_OF_STREAM,
                            )
                            inputDone = true
                        } else {
                            decoder.queueInputBuffer(
                                inputIndex,
                                0,
                                size,
                                extractor.sampleTime,
                                extractor.sampleFlags,
                            )
                            extractor.advance()
                        }
                    }
                }

                when (val outputIndex = decoder.dequeueOutputBuffer(decoderInfo, TIMEOUT_US)) {
                    MediaCodec.INFO_OUTPUT_FORMAT_CHANGED,
                    MediaCodec.INFO_OUTPUT_BUFFERS_CHANGED,
                    MediaCodec.INFO_TRY_AGAIN_LATER -> {
                        if (outputIndex == MediaCodec.INFO_TRY_AGAIN_LATER) {
                            idleRounds++
                            if (idleRounds > MAX_IDLE_ROUNDS) {
                                throw IllegalStateException("视频解码超时，文件可能已损坏")
                            }
                        } else {
                            idleRounds = 0
                        }
                    }
                    else -> {
                        idleRounds = 0
                        if (decoderInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) {
                            decoder.releaseOutputBuffer(outputIndex, false)
                            decoderDone = true
                        } else {
                            val timestampUs = decoderInfo.presentationTimeUs
                            decoder.releaseOutputBuffer(outputIndex, true)
                            val cueIndex = cueIndexAt(cues, timestampUs / 1_000_000.0)
                            if (cueIndex != lastCueIndex) {
                                val cue = cues.getOrNull(cueIndex)
                                if (cue != null) {
                                    val overlay = renderer.acquireOverlay()
                                    drawOverlayToBitmap(cue, style, width, height, overlay)
                                    renderer.pushOverlay()
                                } else {
                                    renderer.clearOverlay()
                                }
                                lastCueIndex = cueIndex
                            }
                            renderer.drawFrame(timestampUs)
                            state.drain(encoder, false)
                        }
                    }
                }
            }

            encoder.signalEndOfInputStream()
            while (!state.drain(encoder, true)) {
                // drain() blocks in short intervals until the encoder emits EOS.
            }
            require(state.started) { "视频编码器没有产生输出格式" }
            require(durationUs <= 0L || state.wroteVideo) { "视频编码没有产生有效帧" }
        } finally {
            runCatching { decoder?.stop() }
            runCatching { encoder?.stop() }
            renderer?.close()
            decoder?.release()
            encoder?.release()
            muxerHandle?.close()
            audioExtractor?.release()
            extractor.release()
        }
    }

    private fun findAudioTrack(inputPath: String): AudioTrackInfo? {
        val extractor = MediaExtractor()
        return try {
            extractor.setDataSource(inputPath)
            val track = selectTrack(extractor, "audio/")
            if (track < 0) {
                extractor.release()
                null
            } else {
                extractor.selectTrack(track)
                AudioTrackInfo(extractor, track, extractor.getTrackFormat(track))
            }
        } catch (error: Throwable) {
            extractor.release()
            throw error
        }
    }

    private fun selectTrack(extractor: MediaExtractor, prefix: String): Int {
        for (index in 0 until extractor.trackCount) {
            val mime = extractor.getTrackFormat(index).getString(MediaFormat.KEY_MIME)
            if (mime?.startsWith(prefix) == true) return index
        }
        return -1
    }

    /** 将系统可解码但不是 AAC 的音轨转成可由 MediaMuxer 写入的 AAC 样本。 */
    private fun transcodeAudio(
        inputPath: String,
        trackIndex: Int,
        inputFormat: MediaFormat,
    ): TranscodedAudio {
        val extractor = MediaExtractor()
        var decoder: MediaCodec? = null
        var encoder: MediaCodec? = null
        try {
            extractor.setDataSource(inputPath)
            extractor.selectTrack(trackIndex)
            val mime = inputFormat.getString(MediaFormat.KEY_MIME)
                ?: throw IllegalArgumentException("音轨缺少 MIME 类型")
            val sampleRate = readInteger(inputFormat, MediaFormat.KEY_SAMPLE_RATE, 0)
            val channelCount = readInteger(inputFormat, MediaFormat.KEY_CHANNEL_COUNT, 0)
            require(sampleRate > 0 && channelCount > 0) {
                "音轨采样率或声道数无效：${sampleRate}Hz/${channelCount}ch"
            }

            val outputFormat = MediaFormat.createAudioFormat(
                "audio/mp4a-latm",
                sampleRate,
                channelCount,
            ).apply {
                setInteger(
                    MediaFormat.KEY_AAC_PROFILE,
                    MediaCodecInfo.CodecProfileLevel.AACObjectLC,
                )
                setInteger(MediaFormat.KEY_BIT_RATE, audioBitrate(sampleRate, channelCount))
                setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 16 * 1024)
            }
            decoder = try {
                MediaCodec.createDecoderByType(mime)
            } catch (error: Exception) {
                throw IllegalArgumentException("系统没有 $mime 的解码器")
            }
            encoder = try {
                MediaCodec.createEncoderByType("audio/mp4a-latm")
            } catch (error: Exception) {
                throw IllegalArgumentException("系统没有 AAC 音频编码器")
            }
            decoder.configure(inputFormat, null, null, 0)
            encoder.configure(outputFormat, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            decoder.start()
            encoder.start()

            val state = AudioEncodeState()
            val decoderInfo = MediaCodec.BufferInfo()
            var extractorDone = false
            var decoderDone = false
            var encoderDone = false
            var encoderEosQueued = false
            var idleRounds = 0
            while (!encoderDone) {
                var madeProgress = false
                if (!extractorDone) {
                    val inputIndex = decoder.dequeueInputBuffer(TIMEOUT_US)
                    if (inputIndex >= 0) {
                        val buffer = decoder.getInputBuffer(inputIndex)
                            ?: throw IllegalStateException("取不到音频解码输入缓冲")
                        buffer.clear()
                        val size = extractor.readSampleData(buffer, 0)
                        if (size < 0) {
                            decoder.queueInputBuffer(
                                inputIndex,
                                0,
                                0,
                                0,
                                MediaCodec.BUFFER_FLAG_END_OF_STREAM,
                            )
                            extractorDone = true
                        } else {
                            decoder.queueInputBuffer(
                                inputIndex,
                                0,
                                size,
                                extractor.sampleTime,
                                extractor.sampleFlags,
                            )
                            extractor.advance()
                        }
                        madeProgress = true
                    }
                }

                when (val outputIndex = decoder.dequeueOutputBuffer(decoderInfo, TIMEOUT_US)) {
                    MediaCodec.INFO_OUTPUT_FORMAT_CHANGED,
                    MediaCodec.INFO_OUTPUT_BUFFERS_CHANGED,
                    MediaCodec.INFO_TRY_AGAIN_LATER -> Unit
                    else -> {
                        madeProgress = true
                        val outputIsEos =
                            decoderInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0
                        if (decoderInfo.size > 0) {
                            val decoded = decoder.getOutputBuffer(outputIndex)
                                ?: throw IllegalStateException("取不到音频解码输出缓冲")
                            state.queuePcm(
                                encoder,
                                decoded,
                                decoderInfo.offset,
                                decoderInfo.size,
                                decoderInfo.presentationTimeUs,
                            )
                        }
                        decoder.releaseOutputBuffer(outputIndex, false)
                        if (outputIsEos) decoderDone = true
                    }
                }

                if (decoderDone && !encoderEosQueued) {
                    state.signalEndOfStream(encoder)
                    encoderEosQueued = true
                    madeProgress = true
                }
                if (state.drain(encoder, false)) {
                    encoderDone = true
                    madeProgress = true
                }
                if (madeProgress) {
                    idleRounds = 0
                } else if (++idleRounds > MAX_IDLE_ROUNDS) {
                    throw IllegalStateException("音频转码超时，文件可能已损坏")
                }
            }
            val encodedFormat = state.format
                ?: throw IllegalStateException("音频编码器没有产生输出格式")
            require(state.samples.isNotEmpty()) { "音轨为空" }
            return TranscodedAudio(encodedFormat, state.samples.toList())
        } finally {
            runCatching { decoder?.stop() }
            runCatching { encoder?.stop() }
            decoder?.release()
            encoder?.release()
            extractor.release()
        }
    }

    private fun openMuxer(outputPath: String): MuxerHandle {
        if (!outputPath.startsWith("content://")) {
            return MuxerHandle(
                MediaMuxer(outputPath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4),
                null,
            )
        }
        require(Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            "Android 8.0 或更高版本才支持 SAF 硬字幕视频输出"
        }
        val descriptor = context.contentResolver.openFileDescriptor(Uri.parse(outputPath), "rwt")
            ?: throw IllegalStateException("无法打开硬字幕输出文件")
        return try {
            MuxerHandle(
                MediaMuxer(descriptor.fileDescriptor, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4),
                descriptor,
            )
        } catch (error: Throwable) {
            descriptor.close()
            throw error
        }
    }

    private fun videoBitrate(width: Int, height: Int): Int =
        (width.toLong() * height.toLong() * 5L).coerceIn(2_000_000L, 20_000_000L).toInt()

    private fun audioBitrate(sampleRate: Int, channelCount: Int): Int =
        (sampleRate.toLong() * channelCount * 2L).coerceIn(64_000L, 256_000L).toInt()

    private fun readInteger(format: MediaFormat, key: String, fallback: Int): Int =
        runCatching { format.getInteger(key) }.getOrDefault(fallback)

    private fun readLong(format: MediaFormat, key: String, fallback: Long): Long =
        runCatching { format.getLong(key) }.getOrDefault(fallback)

    private fun cueIndexAt(cues: List<SubtitleCue>, seconds: Double): Int =
        cues.indexOfFirst { seconds >= it.start && seconds < it.end }

    private fun drawOverlayToBitmap(
        cue: SubtitleCue,
        style: SubtitleRenderStyle,
        width: Int,
        height: Int,
        bitmap: Bitmap,
    ) {
        val lines = buildList {
            cue.speaker?.trim()?.takeIf { it.isNotEmpty() }?.let { add("【$it】") }
            cue.text.trim().takeIf { it.isNotEmpty() }?.let(::add)
            cue.translation?.trim()?.takeIf { it.isNotEmpty() }?.let(::add)
        }
        if (lines.isEmpty()) return

        val scale = max(0.5f, min(width / 1920f, height / 1080f))
        val textPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = style.textColor
            textSize = style.fontSize * scale
            typeface = android.graphics.Typeface.create(
                android.graphics.Typeface.DEFAULT,
                android.graphics.Typeface.NORMAL,
            )
            textAlign = Paint.Align.CENTER
        }
        val maxTextWidth = width * 0.86f
        val wrappedLines = lines.flatMap { wrapText(it, textPaint, maxTextWidth) }
        if (wrappedLines.isEmpty()) return
        val metrics = textPaint.fontMetrics
        val lineHeight = (metrics.bottom - metrics.top) * 1.05f
        val padding = textPaint.textSize * 0.65f
        val blockWidth = min(
            width * 0.92f,
            wrappedLines.maxOf { textPaint.measureText(it) } + padding * 2,
        )
        val blockHeight = wrappedLines.size * lineHeight + padding * 2
        val top = when (style.position) {
            SubtitleRenderStyle.Position.TOP -> height * 0.07f
            SubtitleRenderStyle.Position.CENTER -> (height - blockHeight) / 2f
            SubtitleRenderStyle.Position.BOTTOM -> height * 0.93f - blockHeight
        }.coerceIn(0f, max(0f, height - blockHeight))

        bitmap.eraseColor(android.graphics.Color.TRANSPARENT)
        val canvas = Canvas(bitmap)
        val backgroundPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = style.backgroundColor
        }
        canvas.drawRoundRect(
            RectF(
                (width - blockWidth) / 2f,
                top,
                (width + blockWidth) / 2f,
                top + blockHeight,
            ),
            padding * 0.35f,
            padding * 0.35f,
            backgroundPaint,
        )
        var baseline = top + padding - metrics.top
        for (line in wrappedLines) {
            canvas.drawText(line, width / 2f, baseline, textPaint)
            baseline += lineHeight
        }
    }

    private fun wrapText(text: String, paint: Paint, maxWidth: Float): List<String> {
        val result = mutableListOf<String>()
        for (rawLine in text.replace("\r", "").split('\n')) {
            var remaining = rawLine
            if (remaining.isEmpty()) {
                result.add("")
                continue
            }
            while (remaining.isNotEmpty()) {
                val count = paint.breakText(remaining, true, maxWidth, null).coerceAtLeast(1)
                result.add(remaining.substring(0, count))
                remaining = remaining.substring(count)
            }
        }
        return result
    }
}

private data class AudioTrackInfo(
    val extractor: MediaExtractor,
    val trackIndex: Int,
    val format: MediaFormat,
)

private data class EncodedAudioSample(
    val data: ByteArray,
    val presentationTimeUs: Long,
    val flags: Int,
)

private data class TranscodedAudio(
    val format: MediaFormat,
    val samples: List<EncodedAudioSample>,
)

private class MuxerHandle(
    val muxer: MediaMuxer,
    private val descriptor: ParcelFileDescriptor?,
) {
    fun close() {
        runCatching { muxer.release() }
        runCatching { descriptor?.close() }
    }
}

private class EncodeState(
    private val muxer: MediaMuxer,
    private val audioFormat: MediaFormat?,
    private val audioExtractor: MediaExtractor?,
    private val audioSamples: List<EncodedAudioSample>?,
) {
    var started = false
        private set
    var wroteVideo = false
        private set
    private var videoTrack = -1
    private var audioTrack = -1
    private var audioCopied = false
    private var idleRounds = 0

    fun drain(encoder: MediaCodec, endOfStream: Boolean): Boolean {
        val info = MediaCodec.BufferInfo()
        while (true) {
            when (val index = encoder.dequeueOutputBuffer(info, TIMEOUT_US)) {
                MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    check(!started) { "视频编码器重复产生输出格式" }
                    videoTrack = muxer.addTrack(encoder.outputFormat)
                    if (audioFormat != null) audioTrack = muxer.addTrack(audioFormat)
                    muxer.start()
                    started = true
                    copyAudioIfNeeded()
                    idleRounds = 0
                }
                MediaCodec.INFO_TRY_AGAIN_LATER -> {
                    if (!endOfStream) return false
                    if (++idleRounds > MAX_IDLE_ROUNDS) {
                        throw IllegalStateException("视频编码超时，文件可能已损坏")
                    }
                }
                MediaCodec.INFO_OUTPUT_BUFFERS_CHANGED -> Unit
                else -> {
                    idleRounds = 0
                    val buffer = encoder.getOutputBuffer(index)
                    if (buffer != null && info.size > 0 && started && info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG == 0) {
                        buffer.position(info.offset)
                        buffer.limit(info.offset + info.size)
                        muxer.writeSampleData(videoTrack, buffer, info)
                        wroteVideo = true
                    }
                    val eos = info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0
                    encoder.releaseOutputBuffer(index, false)
                    if (eos) return true
                }
            }
        }
    }

    private fun copyAudioIfNeeded() {
        if (audioCopied || audioTrack < 0) return
        if (audioSamples != null) {
            val info = MediaCodec.BufferInfo()
            for (sample in audioSamples) {
                val buffer = ByteBuffer.wrap(sample.data)
                info.set(0, sample.data.size, sample.presentationTimeUs, sample.flags)
                muxer.writeSampleData(audioTrack, buffer, info)
            }
            audioCopied = true
            return
        }
        if (audioExtractor == null) return
        val info = MediaCodec.BufferInfo()
        var buffer = ByteBuffer.allocateDirect(initialAudioBufferSize())
            .order(ByteOrder.nativeOrder())
        while (true) {
            val sampleSize = audioExtractor.sampleSize
            if (sampleSize < 0) break
            if (sampleSize > buffer.capacity()) {
                buffer = ByteBuffer.allocateDirect(sampleSize.toInt()).order(ByteOrder.nativeOrder())
            }
            buffer.clear()
            val read = audioExtractor.readSampleData(buffer, 0)
            if (read <= 0) break
            info.set(0, read, audioExtractor.sampleTime, audioExtractor.sampleFlags)
            buffer.position(0)
            buffer.limit(read)
            muxer.writeSampleData(audioTrack, buffer, info)
            audioExtractor.advance()
        }
        audioCopied = true
    }

    private fun initialAudioBufferSize(): Int = 1 shl 20

    private companion object {
        const val TIMEOUT_US = 10_000L
        const val MAX_IDLE_ROUNDS = 3000
    }
}

/** 收集 AAC 编码器输出，并在输入缓冲暂时不可用时主动排空输出。 */
private class AudioEncodeState {
    var format: MediaFormat? = null
        private set
    val samples = mutableListOf<EncodedAudioSample>()

    fun queuePcm(
        encoder: MediaCodec,
        source: ByteBuffer,
        offset: Int,
        size: Int,
        presentationTimeUs: Long,
    ) {
        val pcm = source.duplicate().apply {
            clear()
            position(offset)
            limit(offset + size)
        }
        var idleRounds = 0
        while (true) {
            val inputIndex = encoder.dequeueInputBuffer(TIMEOUT_US)
            if (inputIndex >= 0) {
                val buffer = encoder.getInputBuffer(inputIndex)
                    ?: throw IllegalStateException("取不到 AAC 编码输入缓冲")
                buffer.clear()
                require(pcm.remaining() <= buffer.remaining()) {
                    "音频解码帧超过 AAC 编码器输入缓冲"
                }
                buffer.put(pcm)
                encoder.queueInputBuffer(inputIndex, 0, size, presentationTimeUs, 0)
                return
            }
            drain(encoder, false)
            if (++idleRounds > MAX_IDLE_ROUNDS) {
                throw IllegalStateException("AAC 编码器输入超时")
            }
        }
    }

    fun signalEndOfStream(encoder: MediaCodec) {
        var idleRounds = 0
        while (true) {
            val inputIndex = encoder.dequeueInputBuffer(TIMEOUT_US)
            if (inputIndex >= 0) {
                encoder.queueInputBuffer(
                    inputIndex,
                    0,
                    0,
                    0,
                    MediaCodec.BUFFER_FLAG_END_OF_STREAM,
                )
                return
            }
            drain(encoder, false)
            if (++idleRounds > MAX_IDLE_ROUNDS) {
                throw IllegalStateException("AAC 编码器结束超时")
            }
        }
    }

    fun drain(encoder: MediaCodec, endOfStream: Boolean): Boolean {
        val info = MediaCodec.BufferInfo()
        while (true) {
            when (val index = encoder.dequeueOutputBuffer(info, TIMEOUT_US)) {
                MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    check(format == null) { "AAC 编码器重复产生输出格式" }
                    format = encoder.outputFormat
                }
                MediaCodec.INFO_TRY_AGAIN_LATER -> {
                    if (!endOfStream) return false
                }
                MediaCodec.INFO_OUTPUT_BUFFERS_CHANGED -> Unit
                else -> {
                    val buffer = encoder.getOutputBuffer(index)
                    if (
                        buffer != null &&
                        info.size > 0 &&
                        info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG == 0
                    ) {
                        val data = ByteArray(info.size)
                        val sample = buffer.duplicate().apply {
                            position(info.offset)
                            limit(info.offset + info.size)
                        }
                        sample.get(data)
                        samples.add(
                            EncodedAudioSample(data, info.presentationTimeUs, info.flags),
                        )
                    }
                    val eos = info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0
                    encoder.releaseOutputBuffer(index, false)
                    if (eos) return true
                }
            }
        }
    }

    private companion object {
        const val TIMEOUT_US = 10_000L
        const val MAX_IDLE_ROUNDS = 3000
    }
}

/** 将解码器的 SurfaceTexture 画到编码器 Surface，并叠加一张透明字幕位图。 */
private class GlVideoRenderer(
    encoderSurface: Surface,
    private val width: Int,
    private val height: Int,
) : AutoCloseable {
    val decoderSurface: Surface

    private val display: EGLDisplay
    private val context: EGLContext
    private val eglSurface: EGLSurface
    private val surfaceTexture: SurfaceTexture
    private val oesTexture: Int
    private val overlayTexture: Int
    private val oesProgram: Int
    private val overlayProgram: Int
    private val vertices: FloatBuffer = floatBuffer(
        floatArrayOf(-1f, -1f, 1f, -1f, -1f, 1f, 1f, 1f),
    )
    private val textureCoordinates: FloatBuffer = floatBuffer(
        floatArrayOf(0f, 1f, 1f, 1f, 0f, 0f, 1f, 0f),
    )
    private val transform = FloatArray(16)
    private var hasOverlay = false
    private val overlayBitmap: Bitmap by lazy {
        Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
    }

    init {
        val egl = createEgl(encoderSurface)
        display = egl.display
        context = egl.context
        eglSurface = egl.surface
        makeCurrent()
        val textures = IntArray(2)
        GLES20.glGenTextures(2, textures, 0)
        oesTexture = textures[0]
        overlayTexture = textures[1]
        bindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, oesTexture)
        bindTexture(GLES20.GL_TEXTURE_2D, overlayTexture)
        surfaceTexture = SurfaceTexture(oesTexture)
        surfaceTexture.setDefaultBufferSize(width, height)
        decoderSurface = Surface(surfaceTexture)
        oesProgram = createProgram(OES_VERTEX_SHADER, OES_FRAGMENT_SHADER)
        overlayProgram = createProgram(OVERLAY_VERTEX_SHADER, OVERLAY_FRAGMENT_SHADER)
    }

    fun acquireOverlay(): Bitmap {
        return overlayBitmap
    }

    fun pushOverlay() {
        makeCurrent()
        hasOverlay = true
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, overlayTexture)
        GLUtils.texImage2D(GLES20.GL_TEXTURE_2D, 0, overlayBitmap, 0)
    }

    fun clearOverlay() {
        hasOverlay = false
    }

    fun drawFrame(presentationTimeUs: Long) {
        makeCurrent()
        surfaceTexture.updateTexImage()
        surfaceTexture.getTransformMatrix(transform)
        GLES20.glViewport(0, 0, width, height)
        GLES20.glClearColor(0f, 0f, 0f, 1f)
        GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)
        drawTexture(oesProgram, GLES11Ext.GL_TEXTURE_EXTERNAL_OES, oesTexture, transform)
        if (hasOverlay) {
            GLES20.glEnable(GLES20.GL_BLEND)
            GLES20.glBlendFunc(GLES20.GL_SRC_ALPHA, GLES20.GL_ONE_MINUS_SRC_ALPHA)
            drawTexture(overlayProgram, GLES20.GL_TEXTURE_2D, overlayTexture, null)
            GLES20.glDisable(GLES20.GL_BLEND)
        }
        EGLExt.eglPresentationTimeANDROID(display, eglSurface, presentationTimeUs * 1000L)
        check(EGL14.eglSwapBuffers(display, eglSurface)) { "视频编码 Surface 提交失败" }
    }

    private fun drawTexture(program: Int, target: Int, texture: Int, matrix: FloatArray?) {
        GLES20.glUseProgram(program)
        val position = GLES20.glGetAttribLocation(program, "aPosition")
        val coordinates = GLES20.glGetAttribLocation(program, "aTexCoord")
        GLES20.glEnableVertexAttribArray(position)
        GLES20.glVertexAttribPointer(position, 2, GLES20.GL_FLOAT, false, 0, vertices)
        GLES20.glEnableVertexAttribArray(coordinates)
        GLES20.glVertexAttribPointer(coordinates, 2, GLES20.GL_FLOAT, false, 0, textureCoordinates)
        val matrixLocation = GLES20.glGetUniformLocation(program, "uTexMatrix")
        if (matrixLocation >= 0) {
            GLES20.glUniformMatrix4fv(matrixLocation, 1, false, matrix ?: IDENTITY_MATRIX, 0)
        }
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        GLES20.glBindTexture(target, texture)
        GLES20.glUniform1i(GLES20.glGetUniformLocation(program, "uTexture"), 0)
        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
        GLES20.glDisableVertexAttribArray(position)
        GLES20.glDisableVertexAttribArray(coordinates)
    }

    override fun close() {
        runCatching {
            makeCurrent()
            decoderSurface.release()
            surfaceTexture.release()
            GLES20.glDeleteTextures(2, intArrayOf(oesTexture, overlayTexture), 0)
            GLES20.glDeleteProgram(oesProgram)
            GLES20.glDeleteProgram(overlayProgram)
            if (!overlayBitmap.isRecycled) overlayBitmap.recycle()
            EGL14.eglMakeCurrent(
                display,
                EGL14.EGL_NO_SURFACE,
                EGL14.EGL_NO_SURFACE,
                EGL14.EGL_NO_CONTEXT,
            )
            EGL14.eglDestroySurface(display, eglSurface)
            EGL14.eglDestroyContext(display, context)
            EGL14.eglTerminate(display)
        }
    }

    private fun makeCurrent() {
        check(EGL14.eglMakeCurrent(display, eglSurface, eglSurface, context)) {
            "无法切换视频编码 EGL 上下文"
        }
    }

    private fun bindTexture(target: Int, texture: Int) {
        GLES20.glBindTexture(target, texture)
        GLES20.glTexParameteri(target, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
        GLES20.glTexParameteri(target, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
        GLES20.glTexParameteri(target, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
        GLES20.glTexParameteri(target, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)
    }

    private data class EglState(
        val display: EGLDisplay,
        val context: EGLContext,
        val surface: EGLSurface,
    )

    private fun createEgl(window: Any): EglState {
        val display = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
        check(display != EGL14.EGL_NO_DISPLAY) { "无法创建 EGL display" }
        val version = IntArray(2)
        check(EGL14.eglInitialize(display, version, 0, version, 1)) { "无法初始化 EGL" }
        val configAttributes = intArrayOf(
            EGL14.EGL_RED_SIZE, 8,
            EGL14.EGL_GREEN_SIZE, 8,
            EGL14.EGL_BLUE_SIZE, 8,
            EGL14.EGL_ALPHA_SIZE, 8,
            EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT,
            EGL14.EGL_NONE,
        )
        val configs = arrayOfNulls<EGLConfig>(1)
        val count = IntArray(1)
        check(EGL14.eglChooseConfig(display, configAttributes, 0, configs, 0, 1, count, 0)) {
            "无法选择 EGL 配置"
        }
        val config = configs[0] ?: error("没有可用的 EGL 配置")
        val contextAttributes = intArrayOf(
            EGL14.EGL_CONTEXT_CLIENT_VERSION, 2,
            EGL14.EGL_NONE,
        )
        val context = EGL14.eglCreateContext(
            display,
            config,
            EGL14.EGL_NO_CONTEXT,
            contextAttributes,
            0,
        )
        check(context != EGL14.EGL_NO_CONTEXT) { "无法创建 EGL context" }
        val surface = EGL14.eglCreateWindowSurface(
            display,
            config,
            window,
            intArrayOf(EGL14.EGL_NONE),
            0,
        )
        check(surface != EGL14.EGL_NO_SURFACE) { "无法创建 EGL window surface" }
        return EglState(display, context, surface)
    }

    private fun createProgram(vertexSource: String, fragmentSource: String): Int {
        val vertex = compileShader(GLES20.GL_VERTEX_SHADER, vertexSource)
        val fragment = compileShader(GLES20.GL_FRAGMENT_SHADER, fragmentSource)
        val program = GLES20.glCreateProgram()
        check(program != 0) { "无法创建 OpenGL program" }
        GLES20.glAttachShader(program, vertex)
        GLES20.glAttachShader(program, fragment)
        GLES20.glLinkProgram(program)
        val status = IntArray(1)
        GLES20.glGetProgramiv(program, GLES20.GL_LINK_STATUS, status, 0)
        check(status[0] != 0) { "OpenGL program 链接失败：${GLES20.glGetProgramInfoLog(program)}" }
        GLES20.glDeleteShader(vertex)
        GLES20.glDeleteShader(fragment)
        return program
    }

    private fun compileShader(type: Int, source: String): Int {
        val shader = GLES20.glCreateShader(type)
        check(shader != 0) { "无法创建 OpenGL shader" }
        GLES20.glShaderSource(shader, source)
        GLES20.glCompileShader(shader)
        val status = IntArray(1)
        GLES20.glGetShaderiv(shader, GLES20.GL_COMPILE_STATUS, status, 0)
        check(status[0] != 0) { "OpenGL shader 编译失败：${GLES20.glGetShaderInfoLog(shader)}" }
        return shader
    }

    private fun floatBuffer(values: FloatArray): FloatBuffer =
        ByteBuffer.allocateDirect(values.size * 4)
            .order(ByteOrder.nativeOrder())
            .asFloatBuffer()
            .apply {
                put(values)
                position(0)
            }

    private companion object {
        val IDENTITY_MATRIX = floatArrayOf(
            1f, 0f, 0f, 0f,
            0f, 1f, 0f, 0f,
            0f, 0f, 1f, 0f,
            0f, 0f, 0f, 1f,
        )
        const val OES_VERTEX_SHADER = """
            attribute vec4 aPosition;
            attribute vec4 aTexCoord;
            uniform mat4 uTexMatrix;
            varying vec2 vTexCoord;
            void main() {
                gl_Position = aPosition;
                vTexCoord = (uTexMatrix * aTexCoord).xy;
            }
        """
        const val OES_FRAGMENT_SHADER = """
            #extension GL_OES_EGL_image_external : require
            precision mediump float;
            varying vec2 vTexCoord;
            uniform samplerExternalOES uTexture;
            void main() { gl_FragColor = texture2D(uTexture, vTexCoord); }
        """
        const val OVERLAY_VERTEX_SHADER = """
            attribute vec4 aPosition;
            attribute vec4 aTexCoord;
            varying vec2 vTexCoord;
            void main() {
                gl_Position = aPosition;
                vTexCoord = aTexCoord.xy;
            }
        """
        const val OVERLAY_FRAGMENT_SHADER = """
            precision mediump float;
            varying vec2 vTexCoord;
            uniform sampler2D uTexture;
            void main() { gl_FragColor = texture2D(uTexture, vTexCoord); }
        """
    }
}
