/*
 * fpp_audio —— ForkPlus 音频输出后端的 C ABI 垫片
 *
 * 目的：把 miniaudio（单头、跨平台）包成一层**不透明句柄**的稳定 C ABI，供 .NET 侧
 * （ForkPlus.Plugins.Media/MiniAudioNative.cs）用 NativeLibrary 显式加载后逐符号绑定。
 *
 * 为什么加这层：miniaudio 各版本之间**不保证 ABI 兼容**，直接把 miniaudio 的类型暴露给
 * .NET 会让「换一版 miniaudio」变成跨语言的破坏性变更。这里只暴露 void* 句柄 + 基本类型，
 * miniaudio 的版本、类型、后端实现全部封在 fpp_audio.c 里。
 *
 * 线程模型：
 *   - fpp_audio_open / close 由调用方串行调用；
 *   - fpp_audio_write / free_frames / reset / played_frames 由**生产者线程**调用；
 *   - fpp_audio_start / stop / set_volume 可跨线程调用；
 *   - 内部环形缓冲是单生产者单消费者（设备回调为消费者），无需调用方额外加锁。
 *
 * 许可：miniaudio 本体为 Unlicense OR MIT-0（public domain / MIT-0 二选一），
 * 本垫片同样以 MIT-0 提供（见同目录 LICENSE.miniaudio）。
 */

#ifndef FPP_AUDIO_H
#define FPP_AUDIO_H

#include <stdint.h>

#if defined(_WIN32)
#  define FPP_AUDIO_API __declspec(dllexport)
#else
#  define FPP_AUDIO_API __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

/* 打开默认输出设备。
 * sampleRate / channels 为期望的输出格式（交错 float32）；sampleRate 为 0 时取 48000。
 * 成功返回不透明句柄；失败返回 NULL，原因见 fpp_audio_last_error()。 */
FPP_AUDIO_API void* fpp_audio_open(uint32_t sampleRate, uint32_t channels);

/* 关闭设备并释放全部资源；handle 为 NULL 时为空操作。 */
FPP_AUDIO_API void fpp_audio_close(void* handle);

/* 启动 / 停止设备（停止会阻塞到当前回调返回）。成功返回 0，失败返回 -1。 */
FPP_AUDIO_API int fpp_audio_start(void* handle);
FPP_AUDIO_API int fpp_audio_stop(void* handle);

/* 设备是否处于启动状态：1 是，0 否。 */
FPP_AUDIO_API int fpp_audio_playing(void* handle);

/* 写入交错 float32；frameCount 为**每声道**帧数。返回实际写入的帧数（缓冲满则小于请求值）。 */
FPP_AUDIO_API uint32_t fpp_audio_write(void* handle, const float* frames, uint32_t frameCount);

/* 环形缓冲当前还能写入多少帧（生产者背压用）。 */
FPP_AUDIO_API uint32_t fpp_audio_free_frames(void* handle);

/* 已**真实播出**的帧数（不含欠载补的静音）：音频主时钟 = base + played / sampleRate。
 * 欠载时该计数停住，视频据此等待，不会漂移。 */
FPP_AUDIO_API uint64_t fpp_audio_played_frames(void* handle);

/* 清空缓冲并把已播帧数归零（seek 后调用）。 */
FPP_AUDIO_API void fpp_audio_reset(void* handle);

/* 主音量，0.0–1.0。 */
FPP_AUDIO_API void fpp_audio_set_volume(void* handle, float volume);

/* 最近一次失败的静态可读字符串（NUL 结尾，UTF-8）；无错误时为 NULL 或空串。 */
FPP_AUDIO_API const char* fpp_audio_last_error(void);

#ifdef __cplusplus
}
#endif

#endif /* FPP_AUDIO_H */