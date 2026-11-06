/*
 * UAC2 (tinyalsa capture) -> OpenSL ES playback (via Android audioserver).
 * Does NOT open tavil PCM directly — avoids SDM845 freezes.
 *
 * Build (NDK):
 *   $NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android28-clang \
 *     -O2 -I third_party/tinyalsa/include \
 *     scripts/usb_dac_opensles.c third_party/tinyalsa/src/libtinyalsa.a \
 *     -lOpenSLES -llog -o usb_dac_opensles
 */
#include <SLES/OpenSLES.h>
#include <SLES/OpenSLES_Android.h>
#include <android/log.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <tinyalsa/asoundlib.h>

#define LOG_TAG "usb_dac"
#define ALOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define ALOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

static volatile int running = 1;
static struct pcm *cap;
static SLObjectItf engineObject;
static SLEngineItf engineEngine;
static SLObjectItf playerObject;
static SLPlayItf playerPlay;
static SLAndroidSimpleBufferQueueItf bq;
static char *bufs[2];
static unsigned int buf_bytes;
static unsigned int buf_frames;
static int next_buf;

static void on_sig(int s)
{
	(void)s;
	running = 0;
}

static void bq_callback(SLAndroidSimpleBufferQueueItf q, void *ctx)
{
	(void)ctx;
	int idx = next_buf;
	next_buf ^= 1;
	if (!running || !cap)
		return;
	/* pcm_read returns 0 on success in tinyalsa deprecated API, or bytes */
	int r = pcm_read(cap, bufs[idx], buf_bytes);
	if (r < 0) {
		memset(bufs[idx], 0, buf_bytes);
	}
	(*q)->Enqueue(q, bufs[idx], buf_bytes);
}

int main(int argc, char **argv)
{
	unsigned int card = 2, rate = 48000, ch = 2, bits = 16;
	unsigned int period = 960, periods = 4;
	struct pcm_config cfg;
	SLresult res;
	SLDataLocator_AndroidSimpleBufferQueue loc_bq =
		{ SL_DATALOCATOR_ANDROIDSIMPLEBUFFERQUEUE, 2 };
	SLDataFormat_PCM fmt;
	SLDataSource audioSrc;
	SLDataLocator_OutputMix loc_outmix = { SL_DATALOCATOR_OUTPUTMIX, NULL };
	SLDataSink audioSnk;
	SLObjectItf outputMix;
	SLInterfaceID ids[1] = { SL_IID_ANDROIDSIMPLEBUFFERQUEUE };
	SLboolean req[1] = { SL_BOOLEAN_TRUE };

	if (argc > 1)
		card = (unsigned)atoi(argv[1]);
	if (argc > 2)
		rate = (unsigned)atoi(argv[2]);

	signal(SIGINT, on_sig);
	signal(SIGTERM, on_sig);

	memset(&cfg, 0, sizeof(cfg));
	cfg.channels = ch;
	cfg.rate = rate;
	cfg.period_size = period;
	cfg.period_count = periods;
	cfg.format = PCM_FORMAT_S16_LE;
	cfg.start_threshold = period;
	cfg.stop_threshold = period * periods;
	cfg.silence_threshold = period * periods;

	cap = pcm_open(card, 0, PCM_IN, &cfg);
	if (!cap || !pcm_is_ready(cap)) {
		ALOGE("pcm_open card %u failed: %s", card,
		      cap ? pcm_get_error(cap) : "null");
		fprintf(stderr, "pcm_open fail\n");
		return 1;
	}
	buf_frames = period;
	buf_bytes = pcm_frames_to_bytes(cap, buf_frames);
	bufs[0] = calloc(1, buf_bytes);
	bufs[1] = calloc(1, buf_bytes);
	if (!bufs[0] || !bufs[1])
		return 1;

	res = slCreateEngine(&engineObject, 0, NULL, 0, NULL, NULL);
	if (res != SL_RESULT_SUCCESS)
		return 2;
	(*engineObject)->Realize(engineObject, SL_BOOLEAN_FALSE);
	(*engineObject)->GetInterface(engineObject, SL_IID_ENGINE, &engineEngine);
	(*engineEngine)->CreateOutputMix(engineEngine, &outputMix, 0, NULL, NULL);
	(*outputMix)->Realize(outputMix, SL_BOOLEAN_FALSE);

	fmt.formatType = SL_DATAFORMAT_PCM;
	fmt.numChannels = ch;
	fmt.samplesPerSec = rate * 1000; /* milliHz */
	fmt.bitsPerSample = SL_PCMSAMPLEFORMAT_FIXED_16;
	fmt.containerSize = 16;
	fmt.channelMask = SL_SPEAKER_FRONT_LEFT | SL_SPEAKER_FRONT_RIGHT;
	fmt.endianness = SL_BYTEORDER_LITTLEENDIAN;

	audioSrc.pLocator = &loc_bq;
	audioSrc.pFormat = &fmt;
	loc_outmix.outputMix = outputMix;
	audioSnk.pLocator = &loc_outmix;
	audioSnk.pFormat = NULL;

	res = (*engineEngine)->CreateAudioPlayer(engineEngine, &playerObject,
						 &audioSrc, &audioSnk, 1, ids, req);
	if (res != SL_RESULT_SUCCESS) {
		ALOGE("CreateAudioPlayer %d", (int)res);
		return 3;
	}
	(*playerObject)->Realize(playerObject, SL_BOOLEAN_FALSE);
	(*playerObject)->GetInterface(playerObject, SL_IID_PLAY, &playerPlay);
	(*playerObject)->GetInterface(playerObject, SL_IID_ANDROIDSIMPLEBUFFERQUEUE, &bq);
	(*bq)->RegisterCallback(bq, bq_callback, NULL);

	/* prime queue with silence */
	(*bq)->Enqueue(bq, bufs[0], buf_bytes);
	(*bq)->Enqueue(bq, bufs[1], buf_bytes);
	(*playerPlay)->SetPlayState(playerPlay, SL_PLAYSTATE_PLAYING);

	ALOGI("bridging UAC card %u -> OpenSL %uHz", card, rate);
	fprintf(stderr, "bridging UAC card %u -> OpenSL (audioserver)\n", card);

	while (running)
		sleep(1);

	(*playerPlay)->SetPlayState(playerPlay, SL_PLAYSTATE_STOPPED);
	if (playerObject)
		(*playerObject)->Destroy(playerObject);
	if (outputMix)
		(*outputMix)->Destroy(outputMix);
	if (engineObject)
		(*engineObject)->Destroy(engineObject);
	pcm_close(cap);
	free(bufs[0]);
	free(bufs[1]);
	return 0;
}
