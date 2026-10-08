/*
 * fpp_audio —— ForkPlus 音频输出后端（miniaudio 的 C ABI 垫片）
 *
 * 见 fpp_audio.h 的说明。本文件把 miniaudio 编进来（MINIAUDIO_IMPLEMENTATION），用
 * ma_device（交错 float32 播放）+ ma_pcm_rb（生产者环形缓冲）实现一个极简的输出设备：
 *
 *   生产者线程 --fpp_audio_write--> [ma_pcm_rb] --data_callback--> 设备
 *
 * 时钟语义（与 MiniAudioNative / MediaPlayback 约定一致）：
 *   fpp_audio_played_frames 只累计**真实从缓冲取走**的帧数，欠载补的静音不计。
 *   于是缓冲空时计数停住 —— 音频主时钟冻结，视频跟着等，不漂。
 */

#define MINIAUDIO_IMPLEMENTATION
#include "miniaudio.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "fpp_audio.h"

typedef struct fpp_audio_device {
	ma_device device;
	ma_pcm_rb rb;
	ma_uint32 channels;
	ma_uint32 sample_rate;
	volatile ma_uint64 played_frames;
} fpp_audio_device;

static char g_error[512];

static void fpp_set_error(const char* text)
{
	if (text == NULL) {
		g_error[0] = '\0';
		return;
	}
	snprintf(g_error, sizeof(g_error), "%s", text);
	g_error[sizeof(g_error) - 1] = '\0';
}

static void fpp_set_error_result(const char* what, ma_result result)
{
	snprintf(g_error, sizeof(g_error), "%s (ma_result=%d)", what, (int)result);
	g_error[sizeof(g_error) - 1] = '\0';
}

/* 设备回调：从环形缓冲取尽可能多的帧；不足则补静音（不计入已播帧数）。 */
static void fpp_data_callback(ma_device* pDevice, void* pOutput, const void* pInput, ma_uint32 frameCount)
{
	fpp_audio_device* h = (fpp_audio_device*)pDevice->pUserData;
	ma_uint32 bytesPerFrame;
	ma_uint8* out;
	ma_uint32 remaining;

	(void)pInput;

	if (h == NULL) {
		if (pOutput != NULL) {
			memset(pOutput, 0, (size_t)frameCount * ma_get_bytes_per_frame(pDevice->playback.format, pDevice->playback.channels));
		}
		return;
	}

	bytesPerFrame = ma_get_bytes_per_frame(ma_format_f32, h->channels);
	out = (ma_uint8*)pOutput;
	remaining = frameCount;

	while (remaining > 0) {
		ma_uint32 want = remaining;
		void* pRead = NULL;

		if (ma_pcm_rb_acquire_read(&h->rb, &want, &pRead) != MA_SUCCESS || want == 0 || pRead == NULL) {
			break;
		}
		memcpy(out, pRead, (size_t)want * bytesPerFrame);
		ma_pcm_rb_commit_read(&h->rb, want);
		out += (size_t)want * bytesPerFrame;
		remaining -= want;
	}

	if (remaining > 0 && out != NULL) {
		/* 欠载：补静音，不推进时钟。 */
		memset(out, 0, (size_t)remaining * bytesPerFrame);
	}

	/* 只累计真实取走的帧数：欠载补静音时时钟停住，视频跟着等。 */
	h->played_frames += (ma_uint64)(frameCount - remaining);
}

FPP_AUDIO_API void* fpp_audio_open(uint32_t sampleRate, uint32_t channels)
{
	fpp_audio_device* h;
	ma_device_config config;
	ma_uint32 capacityFrames;

	fpp_set_error(NULL);

	if (channels == 0) {
		fpp_set_error("channels must be greater than 0");
		return NULL;
	}
	if (sampleRate == 0) {
		sampleRate = 48000;
	}

	h = (fpp_audio_device*)calloc(1, sizeof(fpp_audio_device));
	if (h == NULL) {
		fpp_set_error("out of memory");
		return NULL;
	}
	h->channels = channels;
	h->sample_rate = sampleRate;

	config = ma_device_config_init(ma_device_type_playback);
	config.playback.format = ma_format_f32;
	config.playback.channels = channels;
	config.sampleRate = sampleRate;
	config.dataCallback = fpp_data_callback;
	config.pUserData = h;

	{
		ma_result result = ma_device_init(NULL, &config, &h->device);
		if (result != MA_SUCCESS) {
			fpp_set_error_result("ma_device_init failed", result);
			free(h);
			return NULL;
		}
	}

	/* 约 0.5 秒的环形缓冲：够吸收调度抖动，又不至于让 seek / 起播的延迟过大。 */
	capacityFrames = sampleRate / 2;
	if (capacityFrames < 4096) {
		capacityFrames = 4096;
	}
	{
		ma_result result = ma_pcm_rb_init(ma_format_f32, channels, capacityFrames, NULL, NULL, &h->rb);
		if (result != MA_SUCCESS) {
			fpp_set_error_result("ma_pcm_rb_init failed", result);
			ma_device_uninit(&h->device);
			free(h);
			return NULL;
		}
	}
	h->played_frames = 0;

	return h;
}

FPP_AUDIO_API void fpp_audio_close(void* handle)
{
	fpp_audio_device* h = (fpp_audio_device*)handle;
	if (h == NULL) {
		return;
	}
	/* 先停设备（uninit 内部会停），再拆环形缓冲，最后释放句柄。 */
	ma_device_uninit(&h->device);
	ma_pcm_rb_uninit(&h->rb);
	free(h);
}

FPP_AUDIO_API int fpp_audio_start(void* handle)
{
	fpp_audio_device* h = (fpp_audio_device*)handle;
	ma_result result;
	if (h == NULL) {
		return -1;
	}
	result = ma_device_start(&h->device);
	if (result != MA_SUCCESS) {
		fpp_set_error_result("ma_device_start failed", result);
		return -1;
	}
	return 0;
}

FPP_AUDIO_API int fpp_audio_stop(void* handle)
{
	fpp_audio_device* h = (fpp_audio_device*)handle;
	if (h == NULL) {
		return -1;
	}
	/* 停止会阻塞到当前回调返回，之后才允许生产者安全地 Reset / 写。 */
	ma_device_stop(&h->device);
	return 0;
}

FPP_AUDIO_API int fpp_audio_playing(void* handle)
{
	fpp_audio_device* h = (fpp_audio_device*)handle;
	if (h == NULL) {
		return 0;
	}
	return ma_device_is_started(&h->device) ? 1 : 0;
}

FPP_AUDIO_API uint32_t fpp_audio_write(void* handle, const float* frames, uint32_t frameCount)
{
	fpp_audio_device* h = (fpp_audio_device*)handle;
	ma_uint32 bytesPerFrame;
	const ma_uint8* src;
	ma_uint32 written = 0;

	if (h == NULL || frames == NULL || frameCount == 0) {
		return 0;
	}
	bytesPerFrame = ma_get_bytes_per_frame(ma_format_f32, h->channels);
	src = (const ma_uint8*)frames;

	while (written < frameCount) {
		ma_uint32 want = frameCount - written;
		void* pWrite = NULL;

		if (ma_pcm_rb_acquire_write(&h->rb, &want, &pWrite) != MA_SUCCESS || want == 0 || pWrite == NULL) {
			break;
		}
		memcpy(pWrite, src + (size_t)written * bytesPerFrame, (size_t)want * bytesPerFrame);
		ma_pcm_rb_commit_write(&h->rb, want);
		written += want;
	}

	return written;
}

FPP_AUDIO_API uint32_t fpp_audio_free_frames(void* handle)
{
	fpp_audio_device* h = (fpp_audio_device*)handle;
	if (h == NULL) {
		return 0;
	}
	return ma_pcm_rb_available_write(&h->rb);
}

FPP_AUDIO_API uint64_t fpp_audio_played_frames(void* handle)
{
	fpp_audio_device* h = (fpp_audio_device*)handle;
	if (h == NULL) {
		return 0;
	}
	return (uint64_t)h->played_frames;
}

FPP_AUDIO_API void fpp_audio_reset(void* handle)
{
	fpp_audio_device* h = (fpp_audio_device*)handle;
	if (h == NULL) {
		return;
	}
	/* 清空缓冲并归零已播帧数（seek 后由调用方把时钟基准设到目标秒）。 */
	ma_pcm_rb_reset(&h->rb);
	h->played_frames = 0;
}

FPP_AUDIO_API void fpp_audio_set_volume(void* handle, float volume)
{
	fpp_audio_device* h = (fpp_audio_device*)handle;
	if (h == NULL) {
		return;
	}
	if (volume < 0.0f) {
		volume = 0.0f;
	}
	if (volume > 1.0f) {
		volume = 1.0f;
	}
	ma_device_set_master_volume(&h->device, volume);
}

FPP_AUDIO_API const char* fpp_audio_last_error(void)
{
	return g_error[0] != '\0' ? g_error : NULL;
}