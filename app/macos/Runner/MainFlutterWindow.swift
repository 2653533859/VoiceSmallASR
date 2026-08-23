import AVFoundation
import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    AudioDecoderChannel.register(messenger: flutterViewController.engine.binaryMessenger)

    super.awakeFromNib()
  }
}

/// 原生音频解码：任意 AVFoundation 能读的容器 → 16 kHz / 单声道 / float32。
///
/// 对应 Dart 侧 `lib/src/audio/audio_decoder.dart` 的 `vsasr/audio_decoder` 通道。
/// Python 端这一步是调 ffmpeg；Dart 侧没有可用的 ffmpeg 封装
/// （`ffmpeg_kit_flutter` 已弃养且不支持 Windows），故三端各写一份原生解码。
///
/// 代码放在本文件而不是单独的 `.swift`：新增源文件必须同时改 Xcode 的
/// `project.pbxproj`，手改容易把工程文件弄坏。等有 Xcode 时再拆出去。
enum AudioDecoderChannel {
  static let name = "vsasr/audio_decoder"

  /// 模型要求的采样率，与 Dart 的 `kSampleRate` 一致。
  static let targetSampleRate = 16000.0

  static func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: name, binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      guard call.method == "decodeToPcm16k" || call.method == "decodePcm16kChunk" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard let arguments = call.arguments as? [String: Any],
            let path = arguments["path"] as? String
      else {
        result(FlutterError(code: "BAD_ARGS", message: "缺少 path 参数", details: nil))
        return
      }
      // 解一段几十分钟的音轨会占满主线程，必须挪到后台队列。
      DispatchQueue.global(qos: .userInitiated).async {
        do {
          if call.method == "decodePcm16kChunk" {
            guard let startMs = arguments["startMs"] as? NSNumber,
                  let durationMs = arguments["durationMs"] as? NSNumber,
                  startMs.int64Value >= 0,
                  durationMs.int64Value > 0
            else {
              throw DecodeError.invalidRange
            }
            let decoded = try decodeChunk(
              path: path,
              startSeconds: startMs.doubleValue / 1000.0,
              durationSeconds: durationMs.doubleValue / 1000.0)
            DispatchQueue.main.async {
              result([
                "pcm": FlutterStandardTypedData(bytes: decoded.pcm),
                "eof": decoded.eof,
              ])
            }
          } else {
            let pcm = try decode(path: path)
            DispatchQueue.main.async { result(FlutterStandardTypedData(bytes: pcm)) }
          }
        } catch {
          DispatchQueue.main.async {
            result(
              FlutterError(
                code: "DECODE_FAILED",
                message: error.localizedDescription,
                details: path))
          }
        }
      }
    }
  }

  /// 返回 float32 小端字节流；Dart 侧按 `Uint8List` 收下再转成 `Float32List`
  /// （按字节回传比直接回 `Float32List` 更不依赖 Flutter SDK 版本）。
  private static func decode(path: String) throws -> Data {
    return try decode(path: path, timeRange: nil, allowEmpty: false)
  }

  private static func decodeChunk(
    path: String,
    startSeconds: Double,
    durationSeconds: Double
  ) throws -> (pcm: Data, eof: Bool) {
    let asset = AVURLAsset(url: URL(fileURLWithPath: path))
    let assetSeconds = CMTimeGetSeconds(asset.duration)
    if assetSeconds.isFinite && startSeconds >= assetSeconds {
      return (Data(), true)
    }
    let range = CMTimeRange(
      start: CMTime(seconds: startSeconds, preferredTimescale: 1_000_000),
      duration: CMTime(seconds: durationSeconds, preferredTimescale: 1_000_000))
    let pcm = try decode(path: path, timeRange: range, allowEmpty: true)
    let eof = assetSeconds.isFinite && startSeconds + durationSeconds >= assetSeconds
    return (pcm, eof)
  }

  private static func decode(
    path: String,
    timeRange: CMTimeRange?,
    allowEmpty: Bool
  ) throws -> Data {
    let asset = AVURLAsset(url: URL(fileURLWithPath: path))
    let tracks = asset.tracks(withMediaType: .audio)
    guard !tracks.isEmpty else { throw DecodeError.noAudioTrack }

    let reader = try AVAssetReader(asset: asset)
    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVSampleRateKey: targetSampleRate,
      AVNumberOfChannelsKey: 1,
      AVLinearPCMBitDepthKey: 32,
      AVLinearPCMIsFloatKey: true,
      AVLinearPCMIsBigEndianKey: false,
      AVLinearPCMIsNonInterleaved: false,
    ]
    // 用 AudioMix 而不是单轨输出：多声道由 AVFoundation 按标准矩阵混成单声道，
    // 重采样也一并交给它，不自己写插值 —— 这是选原生解码而非纯 Dart 的主要理由。
    // 但只喂**第一条**音轨：双语 mp4/mkv 有多条音轨，全喂进去会被混成一条，
    // 拿混音去识别就成了鸡尾酒会。Android 取第一条、Windows 用
    // FIRST_AUDIO_STREAM、Python 端 ffmpeg 默认选流，三处都是单轨。
    let output = AVAssetReaderAudioMixOutput(audioTracks: [tracks[0]], audioSettings: settings)
    guard reader.canAdd(output) else { throw DecodeError.unsupportedFormat }
    reader.add(output)
    if let timeRange { reader.timeRange = timeRange }
    guard reader.startReading() else { throw reader.error ?? DecodeError.unsupportedFormat }

    var pcm = Data()
    while let buffer = output.copyNextSampleBuffer() {
      if let block = CMSampleBufferGetDataBuffer(buffer) {
        let length = CMBlockBufferGetDataLength(block)
        if length > 0 {
          var chunk = Data(count: length)
          let status = chunk.withUnsafeMutableBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return kCMBlockBufferBadPointerParameterErr }
            return CMBlockBufferCopyDataBytes(
              block, atOffset: 0, dataLength: length, destination: base)
          }
          guard status == kCMBlockBufferNoErr else { throw DecodeError.copyFailed }
          pcm.append(chunk)
        }
      }
      CMSampleBufferInvalidate(buffer)
    }

    if reader.status == .failed { throw reader.error ?? DecodeError.unsupportedFormat }
    if !allowEmpty && pcm.isEmpty { throw DecodeError.emptyTrack }
    return pcm
  }

  enum DecodeError: LocalizedError {
    case noAudioTrack
    case unsupportedFormat
    case copyFailed
    case emptyTrack
    case invalidRange

    var errorDescription: String? {
      switch self {
      case .noAudioTrack: return "文件里没有音轨"
      case .unsupportedFormat: return "系统无法解码该格式（mkv / webm 需先转码）"
      case .copyFailed: return "读取解码结果失败"
      case .emptyTrack: return "音轨为空"
      case .invalidRange: return "分块解码时间范围无效"
      }
    }
  }
}
