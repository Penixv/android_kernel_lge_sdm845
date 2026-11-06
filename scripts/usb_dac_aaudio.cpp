/*
 * UAC2 capture -> AAudio blocking write (no callback).
 * Push model avoids ring underruns that sounded like stutter/silence.
 */
#include <aaudio/AAudio.h>
#include <android/log.h>
#include <tinyalsa/asoundlib.h>

#include <cerrno>
#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <fcntl.h>
#include <unistd.h>
#include <vector>

#define LOG_TAG "usb_dac"
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)
#define HB_PATH "/data/adb/usb_dac/hb"

static volatile int g_run = 1;
static void on_sig(int s) { (void)s; g_run = 0; }

static void hb(uint64_t frames, uint64_t underrun)
{
	int fd = open("/data/adb/usb_dac/hb.tmp", O_WRONLY | O_CREAT | O_TRUNC, 0644);
	if (fd < 0)
		return;
	dprintf(fd,
		"mode=shared\nbridge=aaudio\nalive=1\nframes=%llu\nunderrun=%llu\nts=%ld\n",
		(unsigned long long)frames, (unsigned long long)underrun, (long)time(nullptr));
	close(fd);
	rename("/data/adb/usb_dac/hb.tmp", HB_PATH);
}

static void apply_gain(int16_t *s, size_t n, float g)
{
	if (g == 1.0f)
		return;
	for (size_t i = 0; i < n; i++) {
		float v = (float)s[i] * g;
		if (v > 32767.f)
			v = 32767.f;
		if (v < -32768.f)
			v = -32768.f;
		s[i] = (int16_t)v;
	}
}

static pcm *open_cap(unsigned card, unsigned rate, unsigned ch)
{
	unsigned tries[][2] = { {960, 4}, {480, 8}, {480, 4}, {192, 8}, {96, 8} };
	for (unsigned t = 0; t < sizeof(tries) / sizeof(tries[0]); t++) {
		pcm_config cfg{};
		cfg.channels = ch;
		cfg.rate = rate;
		cfg.period_size = tries[t][0];
		cfg.period_count = tries[t][1];
		cfg.format = PCM_FORMAT_S16_LE;
		cfg.start_threshold = 0;
		cfg.stop_threshold = cfg.period_size * cfg.period_count;
		pcm *p = pcm_open(card, 0, PCM_IN, &cfg);
		if (p && pcm_is_ready(p)) {
			fprintf(stderr, "cap OK period=%u n=%u\n", tries[t][0], tries[t][1]);
			return p;
		}
		fprintf(stderr, "cap fail p=%u: %s\n", tries[t][0],
			p ? pcm_get_error(p) : "null");
		if (p)
			pcm_close(p);
	}
	return nullptr;
}

static void close_out(AAudioStream *&out)
{
	if (!out)
		return;
	/* Do not requestStop on DISCONNECTED — can stall on QC HAL */
	aaudio_stream_state_t st = AAudioStream_getState(out);
	if (st != AAUDIO_STREAM_STATE_DISCONNECTED &&
	    st != AAUDIO_STREAM_STATE_CLOSING &&
	    st != AAUDIO_STREAM_STATE_CLOSED) {
		AAudioStream_requestStop(out);
	}
	AAudioStream_close(out);
	out = nullptr;
}

static AAudioStream *open_out(int32_t rate, int32_t ch)
{
	AAudioStreamBuilder *b = nullptr;
	AAudioStream *out = nullptr;
	if (AAudio_createStreamBuilder(&b) != AAUDIO_OK)
		return nullptr;
	AAudioStreamBuilder_setDirection(b, AAUDIO_DIRECTION_OUTPUT);
	AAudioStreamBuilder_setSharingMode(b, AAUDIO_SHARING_MODE_SHARED);
	AAudioStreamBuilder_setSampleRate(b, rate);
	AAudioStreamBuilder_setChannelCount(b, ch);
	AAudioStreamBuilder_setFormat(b, AAUDIO_FORMAT_PCM_I16);
	/* NONE = stable shared path on QC; LOW_LATENCY disconnects/crackles here */
	AAudioStreamBuilder_setPerformanceMode(b, AAUDIO_PERFORMANCE_MODE_NONE);
	/* Let HAL pick buffer — forcing large capacity caused instant DISCONNECTED */
#if __ANDROID_API__ >= 28
	AAudioStreamBuilder_setUsage(b, AAUDIO_USAGE_MEDIA);
	AAudioStreamBuilder_setContentType(b, AAUDIO_CONTENT_TYPE_MUSIC);
#endif
	aaudio_result_t r = AAudioStreamBuilder_openStream(b, &out);
	AAudioStreamBuilder_delete(b);
	if (r != AAUDIO_OK || !out) {
		fprintf(stderr, "openStream: %s\n", AAudio_convertResultToText(r));
		return nullptr;
	}

	int32_t cap = AAudioStream_getBufferCapacityInFrames(out);
	int32_t burst = AAudioStream_getFramesPerBurst(out);
	int32_t sz = AAudioStream_getBufferSizeInFrames(out);
	fprintf(stderr, "out opened cap=%d burst=%d size=%d\n", cap, burst, sz);

	r = AAudioStream_requestStart(out);
	if (r != AAUDIO_OK) {
		fprintf(stderr, "start: %s\n", AAudio_convertResultToText(r));
		AAudioStream_close(out);
		return nullptr;
	}
	/* Do not waitForStateChange — on judyln HAL often reports DISCONNECTED
	 * immediately while writes can still succeed intermittently. */
	fprintf(stderr, "out started cap=%d burst=%d size=%d\n", cap, burst, sz);
	return out;
}

int main(int argc, char **argv)
{
	if (argc < 2) {
		fprintf(stderr, "usage: %s <uac_card> [rate] [ch]\n", argv[0]);
		return 1;
	}
	unsigned card = (unsigned)atoi(argv[1]);
	unsigned rate = argc > 2 ? (unsigned)atoi(argv[2]) : 48000;
	unsigned ch = argc > 3 ? (unsigned)atoi(argv[3]) : 2;
	/* gain>1 clips full-scale USB PCM ("炸"); keep unity */
	float gain = 1.0f;

	signal(SIGINT, on_sig);
	signal(SIGTERM, on_sig);
	signal(SIGHUP, SIG_IGN);

	/* Let audioserver settle after volume / USB rebind */
	usleep(500000);

	pcm *cap = nullptr;
	for (int i = 0; i < 60 && !cap; i++) {
		cap = open_cap(card, rate, ch);
		if (!cap) {
			fprintf(stderr, "UAC open try %d\n", i + 1);
			usleep(250000);
		}
	}
	if (!cap) {
		fprintf(stderr, "UAC open fail\n");
		return 2;
	}

	AAudioStream *out = nullptr;
	for (int i = 0; i < 10 && !out; i++) {
		out = open_out((int32_t)rate, (int32_t)ch);
		if (!out) {
			fprintf(stderr, "open_out try %d failed\n", i + 1);
			usleep(500000);
		}
	}
	if (!out) {
		fprintf(stderr, "open_out give up — will keep trying in loop\n");
	}

	int32_t burst = out ? AAudioStream_getFramesPerBurst(out) : 0;
	if (out) {
		fprintf(stderr, "AAudio blocking write %d Hz %d ch burst=%d (UAC %u)\n",
			AAudioStream_getSampleRate(out),
			AAudioStream_getChannelCount(out), burst, card);
	} else {
		fprintf(stderr, "AAudio not open yet — bridging when HAL allows (UAC %u)\n",
			card);
	}

	/* Prefer one HAL burst per write; clamp if HAL reports huge burst */
	unsigned period = 960;
	if (burst > 0 && burst <= 2048)
		period = (unsigned)burst;
	else if (burst > 2048)
		period = 960; /* QC sometimes reports burst=4800 — don't write 100ms+ */
	std::vector<int16_t> buf(period * ch);
	uint64_t frames_ok = 0, underrun = 0, disc_count = 0;
	time_t last_hb = 0;
	int disc_backoff_ms = 200;
	int stable_writes = 0;

	fprintf(stderr, "OK bridging (blocking) period=%u — play on PC\n", period);
	fflush(stderr);
	hb(0, 0);

	while (g_run) {
		int r = pcm_readi(cap, buf.data(), period);
		if (r < 0) {
			if (r == -EPIPE)
				pcm_prepare(cap);
			memset(buf.data(), 0, buf.size() * sizeof(int16_t));
			r = (int)period;
			underrun++;
			usleep(1000);
		} else if (r == 0) {
			usleep(1000);
			continue;
		}

		if (!out) {
			/* Drain stale UAC while waiting — avoid backlog glitch */
			usleep((useconds_t)disc_backoff_ms * 1000);
			fprintf(stderr, "reopen AAudio (backoff %dms disc=%llu)\n",
				disc_backoff_ms, (unsigned long long)disc_count);
			fflush(stderr);
			out = open_out((int32_t)rate, (int32_t)ch);
			if (!out) {
				if (disc_backoff_ms < 2000)
					disc_backoff_ms =
						disc_backoff_ms < 1000 ? disc_backoff_ms * 2 : 2000;
				continue;
			}
			stable_writes = 0;
			/* drop this period after reconnect */
			continue;
		}

		apply_gain(buf.data(), (size_t)r * ch, gain);

		int32_t written = 0;
		bool failed = false;
		while (written < r && g_run) {
			aaudio_result_t w = AAudioStream_write(
				out, buf.data() + written * ch, r - written,
				300000000); /* 0.3s */
			if (w < 0) {
				fprintf(stderr, "write err %s (stable=%d)\n",
					AAudio_convertResultToText(w), stable_writes);
				fflush(stderr);
				close_out(out);
				disc_count++;
				stable_writes = 0;
				if (disc_backoff_ms < 2000)
					disc_backoff_ms =
						disc_backoff_ms < 1000 ? disc_backoff_ms * 2 : 2000;
				failed = true;
				break;
			}
			written += w;
		}
		if (failed)
			continue;

		frames_ok += (uint64_t)written;
		stable_writes++;
		if (stable_writes > 50) /* ~1s of 20ms periods */
			disc_backoff_ms = 200;

		time_t now = time(nullptr);
		if (now != last_hb) {
			last_hb = now;
			hb(frames_ok, underrun);
		}

		if (out && AAudioStream_getState(out) == AAUDIO_STREAM_STATE_DISCONNECTED) {
			fprintf(stderr, "state DISCONNECTED — close\n");
			fflush(stderr);
			close_out(out);
			disc_count++;
			stable_writes = 0;
			if (disc_backoff_ms < 2000)
				disc_backoff_ms =
					disc_backoff_ms < 1000 ? disc_backoff_ms * 2 : 2000;
		}
	}

	close_out(out);
	pcm_close(cap);
	return 0;
}
