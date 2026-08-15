// 原生音频解码：Media Foundation 能解的一切容器 → 16 kHz / 单声道 / float32。
//
// 对应 Dart 侧 `lib/src/audio/audio_decoder.dart` 的 `vsasr/audio_decoder` 通道。
// Python 端这一步是调 ffmpeg；Dart 侧没有可用的 ffmpeg 封装
//（`ffmpeg_kit_flutter` 已弃养且不支持 Windows），故三端各写一份原生解码。
//
// 与 macOS 端一样，混声道与重采样优先交给系统（IMFSourceReader 会自动插入
// Audio Resampler MFT）；系统不肯给 16 kHz 单声道时才退回自己算，
// 用与 `wav.dart` `resampleLinear` 一致的线性插值。

#include "audio_decoder.h"

// windows.h 必须在 mf*.h 之前。
#include <windows.h>

#include <mfapi.h>
#include <mferror.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <wrl/client.h>

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <cmath>
#include <cstdint>
#include <cstring>
#include <exception>
#include <memory>
#include <new>
#include <string>
#include <thread>
#include <utility>
#include <variant>
#include <vector>

namespace vsasr {

namespace {

using Microsoft::WRL::ComPtr;
using MethodResultValue = flutter::MethodResult<flutter::EncodableValue>;

constexpr char kChannelName[] = "vsasr/audio_decoder";
constexpr UINT32 kTargetSampleRate = 16000;
constexpr wchar_t kMarshalWindowClass[] = L"VsasrAudioDecoderMarshal";
constexpr UINT kMsgDecodeDone = WM_APP + 0x51;

// 一次解码请求的往返数据。error 为空表示成功。
struct DecodeJob {
  std::unique_ptr<MethodResultValue> result;
  std::string path;
  std::vector<uint8_t> pcm;
  std::string error;
};

// 解码器实际输出的格式。is_float 为假表示 16 位整型 PCM。
struct OutputInfo {
  UINT32 sample_rate = 0;
  UINT32 channels = 0;
  bool is_float = false;
};

std::wstring WidenUtf8(const std::string& utf8) {
  if (utf8.empty()) return std::wstring();
  const int size = ::MultiByteToWideChar(
      CP_UTF8, 0, utf8.data(), static_cast<int>(utf8.size()), nullptr, 0);
  if (size <= 0) return std::wstring();
  std::wstring wide(static_cast<size_t>(size), L'\0');
  ::MultiByteToWideChar(CP_UTF8, 0, utf8.data(), static_cast<int>(utf8.size()),
                        wide.data(), size);
  return wide;
}

// 与 `wav.dart` 的 `resampleLinear` 逐行等价：采样率相同时原样返回，
// 因此 16 kHz 素材不经任何插值 —— 这是两端逐字对照的前提。
std::vector<float> ResampleLinear(const std::vector<float>& samples,
                                  UINT32 from, UINT32 to) {
  if (from == to || samples.empty()) return samples;
  const size_t length = static_cast<size_t>(
      std::floor(static_cast<double>(samples.size()) * to / from));
  if (length == 0) return std::vector<float>();
  std::vector<float> out(length);
  const double step = static_cast<double>(from) / to;
  for (size_t i = 0; i < length; ++i) {
    const double position = i * step;
    const size_t left = static_cast<size_t>(std::floor(position));
    const size_t right =
        left + 1 < samples.size() ? left + 1 : samples.size() - 1;
    const double fraction = position - static_cast<double>(left);
    out[i] = static_cast<float>(samples[left] * (1.0 - fraction) +
                                samples[right] * fraction);
  }
  return out;
}

// 按帧读出各声道并算术平均（与 Python 端 `mean(axis=1)`、`wav.dart` 一致）。
void AppendMono(const BYTE* data, DWORD length, const OutputInfo& info,
                std::vector<float>* out) {
  const size_t channels = info.channels;
  const size_t bytes_per_sample = info.is_float ? 4 : 2;
  const size_t frame_bytes = bytes_per_sample * channels;
  if (frame_bytes == 0) return;
  const size_t frames = length / frame_bytes;
  // 不按 frames 精确 reserve：那会让每个缓冲都触发一次实配，
  // 半小时音轨上退化成 O(n²) 拷贝。交给 push_back 的倍增策略。
  for (size_t frame = 0; frame < frames; ++frame) {
    const BYTE* base = data + frame * frame_bytes;
    double sum = 0.0;
    for (size_t channel = 0; channel < channels; ++channel) {
      if (info.is_float) {
        float value = 0.0f;
        // memcpy 而不是解引用 float*：Lock() 给的指针未必按 4 字节对齐。
        std::memcpy(&value, base + channel * 4, sizeof(value));
        sum += value;
      } else {
        int16_t value = 0;
        std::memcpy(&value, base + channel * 2, sizeof(value));
        sum += value / 32768.0;
      }
    }
    out->push_back(static_cast<float>(sum / static_cast<double>(channels)));
  }
}

// 请求一种未压缩输出。prefer_target 为真时连采样率与声道数一起要，
// 让 IMFSourceReader 自己插重采样器；被拒绝时退一步只要编码。
bool ConfigureOutput(IMFSourceReader* reader, bool as_float,
                     bool prefer_target) {
  ComPtr<IMFMediaType> type;
  if (FAILED(MFCreateMediaType(&type))) return false;
  if (FAILED(type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio))) return false;
  if (FAILED(type->SetGUID(MF_MT_SUBTYPE, as_float ? MFAudioFormat_Float
                                                   : MFAudioFormat_PCM))) {
    return false;
  }
  if (FAILED(type->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE,
                             as_float ? 32 : 16))) {
    return false;
  }
  if (prefer_target) {
    if (FAILED(type->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND,
                               kTargetSampleRate)) ||
        FAILED(type->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, 1))) {
      return false;
    }
  }
  return SUCCEEDED(reader->SetCurrentMediaType(
      MF_SOURCE_READER_FIRST_AUDIO_STREAM, nullptr, type.Get()));
}

// 读回真实生效的格式：SetCurrentMediaType 成功也不保证采样率如愿。
bool QueryOutput(IMFSourceReader* reader, OutputInfo* info) {
  ComPtr<IMFMediaType> type;
  if (FAILED(reader->GetCurrentMediaType(MF_SOURCE_READER_FIRST_AUDIO_STREAM,
                                         &type))) {
    return false;
  }
  GUID subtype = GUID_NULL;
  UINT32 bits = 0;
  if (FAILED(type->GetGUID(MF_MT_SUBTYPE, &subtype)) ||
      FAILED(type->GetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND,
                             &info->sample_rate)) ||
      FAILED(type->GetUINT32(MF_MT_AUDIO_NUM_CHANNELS, &info->channels)) ||
      FAILED(type->GetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, &bits))) {
    return false;
  }
  if (info->sample_rate == 0 || info->channels == 0) return false;
  if (subtype == MFAudioFormat_Float && bits == 32) {
    info->is_float = true;
  } else if (subtype == MFAudioFormat_PCM && bits == 16) {
    info->is_float = false;
  } else {
    return false;
  }
  return true;
}

// float 采样 → 小端字节流。Windows 一律小端，按内存布局直拷即可。
std::vector<uint8_t> ToBytes(const std::vector<float>& samples) {
  std::vector<uint8_t> bytes(samples.size() * 4);
  if (!samples.empty()) {
    std::memcpy(bytes.data(), samples.data(), bytes.size());
  }
  return bytes;
}

// 解码主流程。失败时把可直接展示的中文说明写进 *error 并返回空。
std::vector<uint8_t> Decode(const std::string& path, std::string* error) {
  const std::wstring wide_path = WidenUtf8(path);
  if (::GetFileAttributesW(wide_path.c_str()) == INVALID_FILE_ATTRIBUTES) {
    *error = "音频文件不存在";
    return {};
  }

  ComPtr<IMFSourceReader> reader;
  if (FAILED(MFCreateSourceReaderFromURL(wide_path.c_str(), nullptr,
                                         reader.GetAddressOf()))) {
    *error = "系统无法解析该文件（缺少对应的解码器）";
    return {};
  }
  // 视频容器里可能有画面与字幕轨，只留第一条音轨。
  reader->SetStreamSelection(MF_SOURCE_READER_ALL_STREAMS, FALSE);
  if (FAILED(reader->SetStreamSelection(MF_SOURCE_READER_FIRST_AUDIO_STREAM,
                                        TRUE))) {
    *error = "文件里没有音轨";
    return {};
  }

  // 逐档降级：float+16k单声道 → float 原样 → 16 位+16k单声道 → 16 位原样。
  if (!ConfigureOutput(reader.Get(), true, true) &&
      !ConfigureOutput(reader.Get(), true, false) &&
      !ConfigureOutput(reader.Get(), false, true) &&
      !ConfigureOutput(reader.Get(), false, false)) {
    *error = "系统无法把该音轨解成 PCM";
    return {};
  }

  OutputInfo info;
  if (!QueryOutput(reader.Get(), &info)) {
    *error = "取不到解码输出格式";
    return {};
  }

  std::vector<float> mono;
  for (;;) {
    DWORD flags = 0;
    ComPtr<IMFSample> sample;
    if (FAILED(reader->ReadSample(MF_SOURCE_READER_FIRST_AUDIO_STREAM, 0,
                                  nullptr, &flags, nullptr,
                                  sample.GetAddressOf()))) {
      *error = "读取解码结果失败";
      return {};
    }
    if (flags & MF_SOURCE_READERF_CURRENTMEDIATYPECHANGED) {
      // 采样率若在流中途变化，这里只更新 info，末尾按最后一档重采样 ——
      // 这种流极罕见，不为它引入分段重采样的复杂度。
      if (!QueryOutput(reader.Get(), &info)) {
        *error = "解码输出格式中途变成了不支持的形式";
        return {};
      }
    }
    if (flags & MF_SOURCE_READERF_ENDOFSTREAM) break;
    if (!sample) continue;  // 有间隙但没结束，继续读

    ComPtr<IMFMediaBuffer> buffer;
    if (FAILED(sample->ConvertToContiguousBuffer(buffer.GetAddressOf()))) {
      *error = "读取解码结果失败";
      return {};
    }
    BYTE* data = nullptr;
    DWORD length = 0;
    if (FAILED(buffer->Lock(&data, nullptr, &length))) {
      *error = "读取解码结果失败";
      return {};
    }
    AppendMono(data, length, info, &mono);
    buffer->Unlock();
  }

  if (mono.empty()) {
    *error = "音轨为空";
    return {};
  }
  return ToBytes(ResampleLinear(mono, info.sample_rate, kTargetSampleRate));
}

// 在工作线程上跑：COM 与 Media Foundation 都是按线程初始化的。
void ExecuteJob(DecodeJob* job) {
  const HRESULT com = ::CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  if (SUCCEEDED(MFStartup(MF_VERSION))) {
    try {
      job->pcm = Decode(job->path, &job->error);
    } catch (const std::bad_alloc&) {
      job->error = "解码音频时内存不足";
    } catch (const std::exception&) {
      job->error = "音频解码线程发生异常";
    } catch (...) {
      job->error = "音频解码线程发生未知异常";
    }
    MFShutdown();
  } else {
    job->error = "Media Foundation 初始化失败";
  }
  // CoInitializeEx 返回 RPC_E_CHANGED_MODE 时 COM 已被别人初始化过，
  // 这种情况不能配对调用 CoUninitialize。
  if (SUCCEEDED(com)) ::CoUninitialize();
}

// 只能在平台线程上调用。
void Reply(std::unique_ptr<DecodeJob> job) {
  if (job->error.empty()) {
    job->result->Success(flutter::EncodableValue(std::move(job->pcm)));
  } else {
    job->result->Error("DECODE_FAILED", job->error,
                       flutter::EncodableValue(job->path));
  }
}

LRESULT CALLBACK MarshalWndProc(HWND window, UINT message, WPARAM wparam,
                                LPARAM lparam) {
  if (message == kMsgDecodeDone) {
    Reply(std::unique_ptr<DecodeJob>(reinterpret_cast<DecodeJob*>(lparam)));
    return 0;
  }
  return ::DefWindowProcW(window, message, wparam, lparam);
}

// 回包必须在平台线程上发，用一个 message-only 窗口把结果搬回来。
HWND EnsureMarshalWindow() {
  static const HWND window = []() -> HWND {
    WNDCLASSEXW cls = {};
    cls.cbSize = sizeof(cls);
    cls.lpfnWndProc = MarshalWndProc;
    cls.hInstance = ::GetModuleHandleW(nullptr);
    cls.lpszClassName = kMarshalWindowClass;
    ::RegisterClassExW(&cls);
    return ::CreateWindowExW(0, kMarshalWindowClass, L"", 0, 0, 0, 0, 0,
                             HWND_MESSAGE, nullptr, cls.hInstance, nullptr);
  }();
  return window;
}

void RunJob(DecodeJob* raw_job, HWND window) {
  std::unique_ptr<DecodeJob> job(raw_job);
  try {
    ExecuteJob(job.get());
  } catch (...) {
    // ExecuteJob 已覆盖解码异常；这里兜住未来新增代码或资源操作抛出的异常，
    // 保证 detached 线程不会 terminate，Dart 侧也不会永远等不到回包。
    job->error = "音频解码线程发生未知异常";
  }
  // 交出所有权，由窗口过程取走并回包。
  DecodeJob* pending = job.release();
  if (::PostMessageW(window, kMsgDecodeDone, 0,
                     reinterpret_cast<LPARAM>(pending))) {
    return;
  }
  // 窗口已销毁（进程正在退出）或消息队列满：搬不回平台线程了。就地回包并不
  // 干净，但绝不能把 job 丢掉 —— 那样 Dart 侧的 future 永远不会完成，
  // 界面会一直卡在「正在解码音频…」且所有按钮禁用。
  Reply(std::unique_ptr<DecodeJob>(pending));
}

// 取 path 参数；缺失或类型不对时返回空串。
std::string PathArgument(const flutter::MethodCall<flutter::EncodableValue>& call) {
  const auto* arguments = std::get_if<flutter::EncodableMap>(call.arguments());
  if (arguments == nullptr) return std::string();
  const auto entry = arguments->find(flutter::EncodableValue("path"));
  if (entry == arguments->end()) return std::string();
  const auto* value = std::get_if<std::string>(&entry->second);
  return value == nullptr ? std::string() : *value;
}

}  // namespace

void RegisterAudioDecoderChannel(flutter::BinaryMessenger* messenger) {
  const HWND window = EnsureMarshalWindow();
  // 通道对象要活到进程结束，函数局部 static 正好。
  static auto channel =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          messenger, kChannelName,
          &flutter::StandardMethodCodec::GetInstance());
  channel->SetMethodCallHandler(
      [window](const flutter::MethodCall<flutter::EncodableValue>& call,
               std::unique_ptr<MethodResultValue> result) {
        if (call.method_name() != "decodeToPcm16k") {
          result->NotImplemented();
          return;
        }
        const std::string path = PathArgument(call);
        if (path.empty()) {
          result->Error("BAD_ARGS", "缺少 path 参数");
          return;
        }
        auto job = std::make_unique<DecodeJob>();
        job->result = std::move(result);
        job->path = path;
        if (window == nullptr) {
          // 没有搬运窗口就只能同步解（会卡界面），但绝不能不回包。
          ExecuteJob(job.get());
          Reply(std::move(job));
          return;
        }
        // 几十分钟的音轨会把界面卡死，必须挪到工作线程。
        // 先转成裸指针，线程创建失败时本线程仍能收回所有权并回包。
        DecodeJob* raw_job = job.release();
        try {
          std::thread(RunJob, raw_job, window).detach();
        } catch (...) {
          job.reset(raw_job);
          job->error = "无法启动音频解码线程";
          Reply(std::move(job));
        }
      });
}

}  // namespace vsasr
