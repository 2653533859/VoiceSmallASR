#ifndef RUNNER_AUDIO_DECODER_H_
#define RUNNER_AUDIO_DECODER_H_

#include <flutter/binary_messenger.h>

namespace vsasr {

// 在 `vsasr/audio_decoder` 通道上注册原生音频解码（方法 `decodeToPcm16k`、
// `decodePcm16kChunk` 以及连续 `open/read/closePcm16kStream`）。
// 必须在平台线程（创建 FlutterViewController 的线程）上调用。
void RegisterAudioDecoderChannel(flutter::BinaryMessenger* messenger);

}  // namespace vsasr

#endif  // RUNNER_AUDIO_DECODER_H_
