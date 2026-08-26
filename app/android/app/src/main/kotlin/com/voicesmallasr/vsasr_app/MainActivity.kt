package com.voicesmallasr.vsasr_app

import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.Executors
import kotlin.math.floor

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        AudioDecoderChannel.register(flutterEngine.dartExecutor.binaryMessenger)
        HardSubtitleEncoderChannel.register(
            flutterEngine.dartExecutor.binaryMessenger,
            applicationContext,
        )
    }
}

/// 原生音频解码：MediaExtractor 能解封装、MediaCodec 能解码的一切容器
/// → 16 kHz / 单声道 / float32。
///
/// 对应 Dart 侧 `lib/src/audio/audio_decoder.dart` 的 `vsasr/audio_decoder` 通道。
/// Python 端这一步是调 ffmpeg；Dart 侧没有可用的 ffmpeg 封装
/// （`ffmpeg_kit_flutter` 已弃养且不支持 Windows），故三端各写一份原生解码。
///
/// 与 macOS 端（AVFoundation 帮忙混声道 + 重采样）不同，Android 的 MediaCodec
/// 只吐原始 PCM，混声道与重采样都得自己做 —— 重采样用与 `wav.dart`
/// `resampleLinear` 完全一致的线性插值，两端结果才对得上。
object AudioDecoderChannel {
    const val NAME = "vsasr/audio_decoder"

    /// 模型要求的采样率，与 Dart 的 `kSampleRate` 一致。
    const val TARGET_SAMPLE_RATE = 16000

    private const val TIMEOUT_US = 10_000L

    /// 连续这么多轮拿不到输出就认输（每轮等 TIMEOUT_US，合计约 10 秒）。
    private const val MAX_IDLE_ROUNDS = 1000

    /// 解码是 CPU 密集型且一次只处理一个文件，单线程串行即可；
    /// 关键是别占用主线程 —— 几十分钟的音轨会把界面卡死。
    private val worker = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())
    private val streams = mutableMapOf<String, StreamingDecoder>()
    private var nextStreamId = 0L

    fun register(messenger: BinaryMessenger) {
        MethodChannel(messenger, NAME).setMethodCallHandler { call, result ->
            when (call.method) {
                "openPcm16kStream" -> openStream(call, result)
                "readPcm16kStream" -> readStream(call, result)
                "closePcm16kStream" -> closeStream(call, result)
                "decodeToPcm16k", "decodePcm16kChunk" -> decodeOnce(call, result)
                else -> result.notImplemented()
            }
        }
    }

    private fun decodeOnce(call: MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("path")
        if (path == null) {
            result.error("BAD_ARGS", "缺少 path 参数", null)
            return
        }
        worker.execute {
            try {
                val startMs = call.argument<Number>("startMs")?.toLong()
                val durationMs = call.argument<Number>("durationMs")?.toLong()
                val chunked = call.method == "decodePcm16kChunk"
                if (chunked && (startMs == null || startMs < 0 || durationMs == null || durationMs <= 0)) {
                    throw DecodeException("分块解码时间范围无效")
                }
                val decoded = decode(
                    path,
                    startUs = if (chunked) startMs!! * 1000 else null,
                    durationUs = if (chunked) durationMs!! * 1000 else null,
                )
                // MethodChannel 的回包必须在主线程发。
                mainHandler.post {
                    if (chunked) {
                        result.success(mapOf("pcm" to decoded.pcm, "eof" to decoded.eof))
                    } else {
                        result.success(decoded.pcm)
                    }
                }
            } catch (error: Throwable) {
                // 必须连 Error 一起兜住：长录音在手机上很容易 OutOfMemoryError
                // （采样数组扩容 + 再来一份 size*4 的字节缓冲）。漏掉它，
                // 这个线程就死在这里、永远不回包，Dart 侧的 future 挂死，
                // 界面卡在「正在解码音频…」且所有按钮禁用，只能杀进程。
                mainHandler.post {
                    result.error("DECODE_FAILED", error.message ?: "解码失败", path)
                }
            }
        }
    }

    private fun openStream(call: MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("path")
        val startMs = call.argument<Number>("startMs")?.toLong() ?: 0L
        if (path == null || startMs < 0) {
            result.error("BAD_ARGS", "连续解码参数无效", null)
            return
        }
        worker.execute {
            try {
                val decoder = StreamingDecoder(path, startUs = startMs * 1000)
                val id = "stream-${++nextStreamId}"
                streams[id] = decoder
                mainHandler.post { result.success(id) }
            } catch (error: Throwable) {
                mainHandler.post {
                    result.error("DECODE_FAILED", error.message ?: "解码失败", path)
                }
            }
        }
    }

    private fun readStream(call: MethodCall, result: MethodChannel.Result) {
        val sessionId = call.argument<String>("sessionId")
        val maxSamples = call.argument<Number>("maxSamples")?.toInt() ?: 0
        if (sessionId.isNullOrEmpty() || maxSamples <= 0) {
            result.error("BAD_ARGS", "连续解码读取参数无效", null)
            return
        }
        worker.execute {
            try {
                val decoder = streams[sessionId]
                    ?: throw DecodeException("原生音频解码会话不存在")
                val decoded = decoder.read(maxSamples)
                if (decoded.eof) streams.remove(sessionId)?.close()
                mainHandler.post {
                    result.success(mapOf("pcm" to decoded.pcm, "eof" to decoded.eof))
                }
            } catch (error: Throwable) {
                streams.remove(sessionId)?.close()
                mainHandler.post {
                    result.error("DECODE_FAILED", error.message ?: "解码失败", sessionId)
                }
            }
        }
    }

    private fun closeStream(call: MethodCall, result: MethodChannel.Result) {
        val sessionId = call.argument<String>("sessionId")
        if (sessionId.isNullOrEmpty()) {
            result.error("BAD_ARGS", "连续解码会话参数无效", null)
            return
        }
        worker.execute {
            streams.remove(sessionId)?.close()
            mainHandler.post { result.success(null) }
        }
    }

    /// 返回 float32 小端字节流；Dart 侧按 `Uint8List` 收下再转成 `Float32List`
    /// （与 macOS 端同一种回传形式）。
    private data class DecodeResult(val pcm: ByteArray, val eof: Boolean)

    private fun decode(
        path: String,
        startUs: Long? = null,
        durationUs: Long? = null,
    ): DecodeResult {
        if (!File(path).isFile) throw DecodeException("音频文件不存在")

        val extractor = MediaExtractor()
        try {
            extractor.setDataSource(path)
            val track = selectAudioTrack(extractor)
            extractor.selectTrack(track)

            val inputFormat = extractor.getTrackFormat(track)
            val trackDurationUs = runCatching {
                inputFormat.getLong(MediaFormat.KEY_DURATION)
            }.getOrNull()
            if (startUs != null && trackDurationUs != null && startUs >= trackDurationUs) {
                return DecodeResult(ByteArray(0), true)
            }
            if (startUs != null) {
                extractor.seekTo(startUs, MediaExtractor.SEEK_TO_CLOSEST_SYNC)
            }
            val mime = inputFormat.getString(MediaFormat.KEY_MIME)
                ?: throw DecodeException("音轨缺少 MIME 类型")
            val codec = try {
                MediaCodec.createDecoderByType(mime)
            } catch (error: Exception) {
                throw DecodeException("系统没有 $mime 的解码器")
            }
            try {
                codec.configure(inputFormat, null, null, 0)
                codec.start()
                return drain(
                    extractor,
                    codec,
                    inputFormat,
                    startUs = startUs,
                    endUs = if (startUs != null && durationUs != null) startUs + durationUs else null,
                    trackDurationUs = trackDurationUs,
                )
            } finally {
                // 出错路径上 stop() 自己也可能抛，不能盖掉真正的异常。
                runCatching { codec.stop() }
                codec.release()
            }
        } finally {
            extractor.release()
        }
    }

    /// 视频容器里可能有多条轨（画面、字幕、多语言音轨），取第一条音轨。
    private fun selectAudioTrack(extractor: MediaExtractor): Int {
        for (index in 0 until extractor.trackCount) {
            val mime = extractor.getTrackFormat(index).getString(MediaFormat.KEY_MIME)
            if (mime != null && mime.startsWith("audio/")) return index
        }
        throw DecodeException("文件里没有音轨")
    }

    /// 同步 API 的收发循环：喂输入、取输出，直到拿到 end-of-stream。
    private fun drain(
        extractor: MediaExtractor,
        codec: MediaCodec,
        inputFormat: MediaFormat,
        startUs: Long?,
        endUs: Long?,
        trackDurationUs: Long?,
    ): DecodeResult {
        var sampleRate = inputFormat.getInteger(MediaFormat.KEY_SAMPLE_RATE)
        var channels = inputFormat.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
        // 不主动请求 ENCODING_PCM_FLOAT：部分解码器会因此 configure 失败，
        // 而 16 位与 wav 直读路径的精度本来就一样。实际编码以输出格式为准。
        var encoding = AudioFormat.ENCODING_PCM_16BIT
        val mono = FloatChunks()
        val info = MediaCodec.BufferInfo()
        var inputDone = false
        var outputDone = false
        var reachedSourceEnd = false
        // 坏文件可能让解码器一直只回 INFO_TRY_AGAIN_LATER，得有个兜底出口。
        var idleRounds = 0

        while (!outputDone) {
            if (!inputDone) {
                val index = codec.dequeueInputBuffer(TIMEOUT_US)
                if (index >= 0) {
                    val buffer = codec.getInputBuffer(index)
                        ?: throw DecodeException("取不到解码器输入缓冲")
                    val sampleTime = extractor.sampleTime
                    val read = if (endUs != null && sampleTime >= endUs) {
                        -1
                    } else {
                        extractor.readSampleData(buffer, 0)
                    }
                    if (read < 0) {
                        codec.queueInputBuffer(
                            index, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM,
                        )
                        inputDone = true
                        reachedSourceEnd = sampleTime < 0
                    } else {
                        codec.queueInputBuffer(index, 0, read, extractor.sampleTime, 0)
                        extractor.advance()
                    }
                }
            }

            val index = codec.dequeueOutputBuffer(info, TIMEOUT_US)
            if (index >= 0) {
                idleRounds = 0
                if (info.size > 0 && (startUs == null || info.presentationTimeUs >= startUs)) {
                    val buffer = codec.getOutputBuffer(index)
                        ?: throw DecodeException("取不到解码器输出缓冲")
                    // 先 clear 再定位：不假设 MediaCodec 交还时 position/limit 是什么。
                    buffer.clear()
                    buffer.position(info.offset)
                    buffer.limit(info.offset + info.size)
                    appendMono(buffer, channels, encoding, mono)
                }
                codec.releaseOutputBuffer(index, false)
                if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) outputDone = true
            } else if (index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                idleRounds = 0
                // 真实的采样率/声道数/PCM 编码要以输出格式为准：容器头里写的
                // 未必对，且这个事件总在第一块数据之前到达。
                val outputFormat = codec.outputFormat
                sampleRate = outputFormat.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                channels = outputFormat.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                encoding = pcmEncodingOf(outputFormat)
            } else if (++idleRounds > MAX_IDLE_ROUNDS) {
                // 每轮已等 TIMEOUT_US，连续空转这么多次就是真出不来了。
                throw DecodeException("解码超时，文件可能已损坏")
            }
            // INFO_TRY_AGAIN_LATER / INFO_OUTPUT_BUFFERS_CHANGED：继续下一轮。
        }

        val samples = mono.toArray()
        if (samples.isEmpty() && startUs == null) throw DecodeException("音轨为空")
        val eof = reachedSourceEnd ||
            (endUs != null && trackDurationUs != null && endUs >= trackDurationUs)
        return DecodeResult(
            toLittleEndianBytes(resampleLinear(samples, sampleRate, TARGET_SAMPLE_RATE)),
            eof,
        )
    }

    /// `KEY_PCM_ENCODING` 是可选键，缺省即 16 位。
    ///
    /// 用 runCatching 而不是 `containsKey` / `getInteger(key, default)`：
    /// 那两个都是 API 29 才有的，minSdk 比它低，直接调会 NoSuchMethodError；
    /// 键不存在时 `getInteger` 抛 NullPointerException，各版本都如此。
    private fun pcmEncodingOf(format: MediaFormat): Int =
        runCatching { format.getInteger(MediaFormat.KEY_PCM_ENCODING) }
            .getOrDefault(AudioFormat.ENCODING_PCM_16BIT)

    /// 按帧读出各声道并算术平均（与 Python 端 `mean(axis=1)`、`wav.dart` 一致）。
    private fun appendMono(buffer: ByteBuffer, channels: Int, encoding: Int, out: FloatChunks) {
        buffer.order(ByteOrder.LITTLE_ENDIAN)
        val bytesPerSample = when (encoding) {
            AudioFormat.ENCODING_PCM_8BIT -> 1
            AudioFormat.ENCODING_PCM_16BIT -> 2
            AudioFormat.ENCODING_PCM_FLOAT, AudioFormat.ENCODING_PCM_32BIT -> 4
            else -> throw DecodeException("不支持的 PCM 编码（$encoding）")
        }
        val frameBytes = bytesPerSample * channels
        if (frameBytes <= 0) throw DecodeException("声道数非法（$channels）")
        val frames = buffer.remaining() / frameBytes
        for (frame in 0 until frames) {
            var sum = 0.0
            for (channel in 0 until channels) {
                sum += readSample(buffer, encoding)
            }
            out.add((sum / channels).toFloat())
        }
    }

    /// 从当前 position 读一个采样并前进，归一化到 [-1, 1]。
    private fun readSample(buffer: ByteBuffer, encoding: Int): Double = when (encoding) {
        // Android 的 8 位 PCM 与 wav 一样按无符号解读，128 为静音。
        AudioFormat.ENCODING_PCM_8BIT -> (buffer.get().toInt() and 0xFF) / 128.0 - 1.0
        AudioFormat.ENCODING_PCM_16BIT -> buffer.short / 32768.0
        AudioFormat.ENCODING_PCM_FLOAT -> buffer.float.toDouble()
        AudioFormat.ENCODING_PCM_32BIT -> buffer.int / 2147483648.0
        else -> throw DecodeException("不支持的 PCM 编码（$encoding）")
    }

    /// 与 `wav.dart` 的 `resampleLinear` 逐行等价：采样率相同时原样返回，
    /// 因此 16 kHz 素材不经任何插值 —— 这是两端逐字对照的前提。
    private fun resampleLinear(samples: FloatArray, from: Int, to: Int): FloatArray {
        if (from <= 0 || to <= 0) throw DecodeException("采样率非法：from=$from to=$to")
        if (from == to || samples.isEmpty()) return samples
        val length = floor(samples.size.toDouble() * to / from).toInt()
        if (length <= 0) return FloatArray(0)
        val out = FloatArray(length)
        val step = from.toDouble() / to
        for (i in 0 until length) {
            val position = i * step
            val left = floor(position).toInt()
            val right = if (left + 1 < samples.size) left + 1 else samples.size - 1
            val fraction = position - left
            out[i] = (samples[left] * (1 - fraction) + samples[right] * fraction).toFloat()
        }
        return out
    }

    private fun toLittleEndianBytes(samples: FloatArray): ByteArray {
        val bytes = ByteBuffer.allocate(samples.size * 4).order(ByteOrder.LITTLE_ENDIAN)
        for (sample in samples) bytes.putFloat(sample)
        return bytes.array()
    }

    /// 一个连续的 MediaExtractor/MediaCodec 会话。所有方法都只由 [worker] 调用，
    /// 因此 native 解码器不会在每个 10 秒块之间反复创建和销毁。
    private class StreamingDecoder(
        path: String,
        startUs: Long,
    ) {
        private val extractor = MediaExtractor()
        private val startUs: Long
        private var codec: MediaCodec? = null
        private var sampleRate = TARGET_SAMPLE_RATE
        private var channels = 1
        private var encoding = AudioFormat.ENCODING_PCM_16BIT
        private val pending = FloatChunks()
        private var inputDone = false
        private var outputDone = false
        private var closed = false
        private var sourceBase = 0L
        private var outputSamples = 0L

        init {
            try {
                if (!File(path).isFile) throw DecodeException("音频文件不存在")
                extractor.setDataSource(path)
                val track = AudioDecoderChannel.selectAudioTrack(extractor)
                extractor.selectTrack(track)
                val inputFormat = extractor.getTrackFormat(track)
                val mime = inputFormat.getString(MediaFormat.KEY_MIME)
                    ?: throw DecodeException("音轨缺少 MIME 类型")
                extractor.seekTo(startUs, MediaExtractor.SEEK_TO_CLOSEST_SYNC)
                val decoder = try {
                    MediaCodec.createDecoderByType(mime)
                } catch (error: Exception) {
                    throw DecodeException("系统没有 $mime 的解码器")
                }
                codec = decoder
                decoder.configure(inputFormat, null, null, 0)
                decoder.start()
            } catch (error: Throwable) {
                close()
                throw error
            }
            this.startUs = startUs
        }

        fun read(maxSamples: Int): DecodeResult {
            if (closed) throw DecodeException("原生音频解码会话已关闭")
            if (maxSamples <= 0) throw DecodeException("读取采样数必须大于 0")
            val output = FloatArray(maxSamples)
            var count = 0
            var idleRounds = 0
            while (count < maxSamples && !outputDone) {
                count = produce(output, count, maxSamples)
                if (count >= maxSamples || outputDone) break

                if (!inputDone) {
                    val inputIndex = codec!!.dequeueInputBuffer(TIMEOUT_US)
                    if (inputIndex >= 0) {
                        val buffer = codec!!.getInputBuffer(inputIndex)
                            ?: throw DecodeException("取不到解码器输入缓冲")
                        val sampleTime = extractor.sampleTime
                        val size = extractor.readSampleData(buffer, 0)
                        if (size < 0) {
                            codec!!.queueInputBuffer(
                                inputIndex,
                                0,
                                0,
                                0,
                                MediaCodec.BUFFER_FLAG_END_OF_STREAM,
                            )
                            inputDone = true
                        } else {
                            codec!!.queueInputBuffer(inputIndex, 0, size, sampleTime, 0)
                            extractor.advance()
                        }
                    }
                }

                val info = MediaCodec.BufferInfo()
                val outputIndex = codec!!.dequeueOutputBuffer(info, TIMEOUT_US)
                when {
                    outputIndex >= 0 -> {
                        idleRounds = 0
                        if (info.size > 0 && info.presentationTimeUs >= startUs) {
                            val buffer = codec!!.getOutputBuffer(outputIndex)
                                ?: throw DecodeException("取不到解码器输出缓冲")
                            buffer.clear()
                            buffer.position(info.offset)
                            buffer.limit(info.offset + info.size)
                            AudioDecoderChannel.appendMono(
                                buffer,
                                channels,
                                encoding,
                                pending,
                            )
                        }
                        codec!!.releaseOutputBuffer(outputIndex, false)
                        if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) {
                            outputDone = true
                        }
                    }
                    outputIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                        idleRounds = 0
                        val outputFormat = codec!!.outputFormat
                        sampleRate = outputFormat.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                        channels = outputFormat.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                        encoding = AudioDecoderChannel.pcmEncodingOf(outputFormat)
                    }
                    else -> {
                        if (++idleRounds > MAX_IDLE_ROUNDS) {
                            throw DecodeException("解码超时，文件可能已损坏")
                        }
                    }
                }
            }
            count = produce(output, count, maxSamples)
            val eof = outputDone && count == 0
            return DecodeResult(
                AudioDecoderChannel.toLittleEndianBytes(output.copyOf(count)),
                eof,
            )
        }

        private fun produce(output: FloatArray, offset: Int, maxSamples: Int): Int {
            var written = offset
            if (pending.size == 0 || written >= maxSamples) return written
            if (sampleRate == TARGET_SAMPLE_RATE) {
                val count = minOf(pending.size, maxSamples - written)
                pending.copyTo(output, written, count)
                pending.consume(count)
                sourceBase += count
                outputSamples += count
                return written + count
            }

            val sourceRate = sampleRate.toDouble()
            val targetRate = TARGET_SAMPLE_RATE.toDouble()
            val sourceEnd = sourceBase + pending.size
            val totalOutput = floor(sourceEnd.toDouble() * targetRate / sourceRate).toLong()
            while (written < maxSamples && outputSamples < totalOutput) {
                val position = outputSamples * sourceRate / targetRate
                val left = floor(position).toLong()
                if (left < sourceBase || left >= sourceEnd) break
                if (!outputDone && left + 1 >= sourceEnd) break
                val leftOffset = (left - sourceBase).toInt()
                val rightOffset = if (left + 1 < sourceEnd) leftOffset + 1 else leftOffset
                val fraction = position - left
                output[written++] = (
                    pending[leftOffset] * (1.0 - fraction) +
                        pending[rightOffset] * fraction
                    ).toFloat()
                outputSamples++
                val nextLeft = floor(outputSamples * sourceRate / targetRate).toLong()
                if (nextLeft > sourceBase) {
                    val remove = minOf((nextLeft - sourceBase).toInt(), pending.size)
                    pending.consume(remove)
                    sourceBase += remove
                }
            }
            return written
        }

        fun close() {
            if (closed) return
            closed = true
            runCatching { codec?.stop() }
            codec?.release()
            codec = null
            extractor.release()
        }
    }

    /// 可增长的 float 缓冲。不用 `ArrayList<Float>`：那会给每个采样装箱，
    /// 半小时音轨约 2900 万个采样，手机上直接 OOM。
    private class FloatChunks {
        private var data = FloatArray(1 shl 16)
        private var start = 0
        private var count = 0

        val size: Int
            get() = count

        fun add(value: Float) {
            if (start + count == data.size) {
                if (start > 0) {
                    data.copyInto(data, destinationOffset = 0, startIndex = start, endIndex = start + count)
                    start = 0
                } else {
                    data = data.copyOf(data.size * 2)
                }
            }
            data[start + count++] = value
        }

        operator fun get(index: Int): Float = data[start + index]

        fun copyTo(target: FloatArray, targetOffset: Int, count: Int) {
            data.copyInto(
                target,
                destinationOffset = targetOffset,
                startIndex = start,
                endIndex = start + count,
            )
        }

        fun consume(count: Int) {
            require(count in 0..this.count)
            start += count
            this.count -= count
            if (this.count == 0) start = 0
        }

        fun toArray(): FloatArray = data.copyOfRange(start, start + count)
    }

    private class DecodeException(message: String) : Exception(message)
}
