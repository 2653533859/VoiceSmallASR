# M13 macOS FFmpeg 硬字幕兼容性验收

> 验收日期：2026-08-18

## 结论

本机普通 Homebrew FFmpeg 8.1.1 不包含 `ass/libass` 滤镜，因此不能执行桌面硬字幕编码；应用会拒绝编码并提示安装包含 `libass` 的完整 FFmpeg（例如 `ffmpeg-full`）。这属于明确的运行时前置条件，不会把失败误报为成功。

包含 `ass` 滤镜的 `ffmpeg-full 9.0.1` 正向编码验收已通过，记录见 `app/tool/hard_subtitle_ffmpeg_acceptance_test.dart` 的既有验收结果。

## 负向验收

环境：macOS 26.5.2 arm64，`/opt/homebrew/bin/ffmpeg`，FFmpeg 8.1.1。

使用普通 FFmpeg 生成 2 秒 H.264/AAC MP4 后，运行：

```bash
cd app
VSASR_FFMPEG_PATH=/opt/homebrew/bin/ffmpeg \
VSASR_HARD_SUBTITLE_EXPECT_UNSUPPORTED=1 \
VSASR_HARD_SUBTITLE_TEST_VIDEO=/path/to/input.mp4 \
flutter test tool/hard_subtitle_ffmpeg_acceptance_test.dart --reporter expanded
```

结果：测试通过，并确认错误信息包含：

```text
当前 FFmpeg 未包含 libass/ass 字幕滤镜，请安装带 libass 的完整构建（如 ffmpeg-full）
```

验收脚本默认仍验证正常硬字幕编码；只有显式设置 `VSASR_HARD_SUBTITLE_EXPECT_UNSUPPORTED=1` 时才验证“缺少滤镜应失败”的兼容性边界。

## 未覆盖范围

- Android 真机和厂商 Codec 差异仍待真实设备。
- Windows 用户桌面安装、启动和本机 FFmpeg 配置仍待用户环境。
