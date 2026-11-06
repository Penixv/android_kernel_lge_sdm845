/*
 * Mode A: UAC2 ALSA capture -> tavil PCM play (via Qualcomm AFE).
 * Preallocated ring, XRUN recovery, simple drift drop/insert.
 *
 * usage: usb_dac_bridge <cap_card> <play_card> [play_dev] [rate] [ch] [cap_bits]
 *   cap_bits: 16 | 24 (default 24 → S24_3LE)
 */
#include <tinyalsa/asoundlib.h>

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define HB_PATH "/data/adb/usb_dac/hb"
/* Qualcomm AFE: 4ms periods often open but never leave SETUP on write.
 * 20ms periods + ~120ms ring: USB2 bandwidth is fine; jitter/keepalive was the issue. */
#define RING_MS 500
#define PREBUF_MS 100
#define CAP_PERIOD_MS 20
#define PLAY_PERIOD_MS 20
#define PLAY_PERIOD_COUNT 8
#define MAX_FRAME_BYTES 16 /* stereo s32 */
#define MAX_PERIOD_FRAMES 2048

static volatile int g_run = 1;
static void on_sig(int s) { (void)s; g_run = 0; }

/* ---- byte ring (preallocated) ---- */
struct Ring {
	uint8_t *data;
	size_t capacity;
	size_t r, w, count;
	uint64_t overruns;
	pthread_mutex_t mu;
	pthread_cond_t cv;
};

static int ring_init(struct Ring *rg, size_t bytes)
{
	rg->data = (uint8_t *)malloc(bytes);
	if (!rg->data)
		return -1;
	rg->capacity = bytes;
	rg->r = rg->w = rg->count = 0;
	pthread_mutex_init(&rg->mu, NULL);
	pthread_cond_init(&rg->cv, NULL);
	return 0;
}

static void ring_free(struct Ring *rg)
{
	free(rg->data);
	pthread_mutex_destroy(&rg->mu);
	pthread_cond_destroy(&rg->cv);
}

static size_t ring_write(struct Ring *rg, const void *src, size_t n)
{
	const uint8_t *p = (const uint8_t *)src;
	size_t put = 0;
	pthread_mutex_lock(&rg->mu);
	if (n >= rg->capacity) {
		rg->overruns++;
		p += n - rg->capacity;
		n = rg->capacity;
		rg->r = rg->w = rg->count = 0;
	} else if (rg->count + n > rg->capacity) {
		size_t drop = rg->count + n - rg->capacity;
		rg->overruns++;
		rg->r = (rg->r + drop) % rg->capacity;
		rg->count -= drop;
	}
	while (put < n) {
		size_t chunk = n - put;
		size_t space = rg->capacity - rg->w;
		if (chunk > space)
			chunk = space;
		memcpy(rg->data + rg->w, p + put, chunk);
		rg->w = (rg->w + chunk) % rg->capacity;
		rg->count += chunk;
		put += chunk;
	}
	pthread_cond_signal(&rg->cv);
	pthread_mutex_unlock(&rg->mu);
	return put;
}

static size_t ring_read(struct Ring *rg, void *dst, size_t n, int wait_ms)
{
	uint8_t *p = (uint8_t *)dst;
	size_t got = 0;
	struct timespec ts;
	pthread_mutex_lock(&rg->mu);
	if (wait_ms > 0 && rg->count < n) {
		clock_gettime(CLOCK_REALTIME, &ts);
		ts.tv_nsec += (long)wait_ms * 1000000L;
		if (ts.tv_nsec >= 1000000000L) {
			ts.tv_sec++;
			ts.tv_nsec -= 1000000000L;
		}
		while (rg->count < n && g_run)
			if (pthread_cond_timedwait(&rg->cv, &rg->mu, &ts) == ETIMEDOUT)
				break;
	}
	if (n > rg->count)
		n = rg->count;
	while (got < n) {
		size_t chunk = n - got;
		size_t space = rg->capacity - rg->r;
		if (chunk > space)
			chunk = space;
		memcpy(p + got, rg->data + rg->r, chunk);
		rg->r = (rg->r + chunk) % rg->capacity;
		rg->count -= chunk;
		got += chunk;
	}
	pthread_mutex_unlock(&rg->mu);
	return got;
}

static size_t ring_avail(struct Ring *rg)
{
	size_t c;
	pthread_mutex_lock(&rg->mu);
	c = rg->count;
	pthread_mutex_unlock(&rg->mu);
	return c;
}

static uint64_t ring_overruns(struct Ring *rg)
{
	uint64_t n;
	pthread_mutex_lock(&rg->mu);
	n = rg->overruns;
	pthread_mutex_unlock(&rg->mu);
	return n;
}

static void ring_drop_bytes(struct Ring *rg, size_t n)
{
	pthread_mutex_lock(&rg->mu);
	if (n > rg->count)
		n = rg->count;
	rg->r = (rg->r + n) % rg->capacity;
	rg->count -= n;
	pthread_mutex_unlock(&rg->mu);
}

static void ring_insert_silence(struct Ring *rg, size_t n)
{
	pthread_mutex_lock(&rg->mu);
	if (n > rg->capacity)
		n = rg->capacity;
	if (rg->count + n > rg->capacity) {
		size_t drop = rg->count + n - rg->capacity;
		rg->r = (rg->r + drop) % rg->capacity;
		rg->count -= drop;
		rg->overruns++;
	}
	while (n) {
		size_t chunk = n < rg->capacity - rg->w ? n : rg->capacity - rg->w;
		memset(rg->data + rg->w, 0, chunk);
		rg->w = (rg->w + chunk) % rg->capacity;
		rg->count += chunk;
		n -= chunk;
	}
	pthread_cond_signal(&rg->cv);
	pthread_mutex_unlock(&rg->mu);
}

/* ---- bridge state ---- */
struct Bridge {
	struct Ring ring;
	struct pcm *cap;
	struct pcm *play;
	unsigned rate;
	unsigned ch;
	unsigned play_card;
	unsigned play_dev;
	unsigned cap_frame_bytes;
	unsigned play_frame_bytes;
	enum pcm_format cap_fmt;
	enum pcm_format play_fmt;
	unsigned cap_period;
	unsigned play_period;
	size_t prebuf_bytes;
	size_t frame_bytes_ring; /* stored as cap format in ring */

	pthread_t cap_th, play_th;
	uint64_t frames_cap;
	uint64_t frames_play;
	uint64_t xrun_cap;
	uint64_t xrun_play;
	uint64_t drift_drops;
	uint64_t drift_inserts;
	uint64_t ring_underruns;
	char cap_fmt_name[16];
	char play_fmt_name[16];
};

static const char *fmt_name(enum pcm_format f)
{
	switch (f) {
	case PCM_FORMAT_S16_LE: return "S16_LE";
	case PCM_FORMAT_S24_3LE: return "S24_3LE";
	case PCM_FORMAT_S24_LE: return "S24_LE";
	case PCM_FORMAT_S32_LE: return "S32_LE";
	default: return "UNK";
	}
}

static unsigned fmt_bytes(enum pcm_format f)
{
	return pcm_format_to_bits(f) / 8;
}

static void hb_write(struct Bridge *b)
{
	int64_t skew = 0;
	int fd;
	if (b->frames_play > 1000)
		skew = (int64_t)b->frames_cap - (int64_t)b->frames_play;
	fd = open("/data/adb/usb_dac/hb.tmp", O_WRONLY | O_CREAT | O_TRUNC, 0644);
	if (fd < 0)
		return;
	dprintf(fd,
		"mode=a\nbridge=pcm_bridge\nalive=1\n"
		"frames=%llu\nframes_play=%llu\n"
		"xrun_cap=%llu\nxrun_play=%llu\n"
		"skew_frames=%lld\nskew_ppm=%lld\n"
		"drift_drops=%llu\ndrift_inserts=%llu\n"
		"ring_underruns=%llu\nring_overruns=%llu\nring_frames=%zu\n"
		"cap_fmt=%s\nplay_fmt=%s\n"
		"rate=%u\nch=%u\nts=%ld\n",
		(unsigned long long)b->frames_cap,
		(unsigned long long)b->frames_play,
		(unsigned long long)b->xrun_cap,
		(unsigned long long)b->xrun_play,
		(long long)skew,
		b->frames_play ? (long long)(skew * 1000000 / (int64_t)b->frames_play) : 0LL,
		(unsigned long long)b->drift_drops,
		(unsigned long long)b->drift_inserts,
		(unsigned long long)b->ring_underruns,
		(unsigned long long)ring_overruns(&b->ring),
		ring_avail(&b->ring) / b->cap_frame_bytes,
		b->cap_fmt_name, b->play_fmt_name,
		b->rate, b->ch, (long)time(NULL));
	close(fd);
	rename("/data/adb/usb_dac/hb.tmp", HB_PATH);
}

/* Convert one frame cap→play into out (max MAX_FRAME_BYTES) */
static void convert_frame(const uint8_t *in, enum pcm_format cin,
			  uint8_t *out, enum pcm_format cout, unsigned ch)
{
	int32_t s[8];
	unsigned i;
	if (ch > 8)
		ch = 8;
	/* unpack to s32 */
	for (i = 0; i < ch; i++) {
		if (cin == PCM_FORMAT_S16_LE) {
			int16_t v;
			memcpy(&v, in + i * 2, 2);
			s[i] = (int32_t)v << 16;
		} else if (cin == PCM_FORMAT_S24_3LE) {
			uint8_t b0 = in[i * 3], b1 = in[i * 3 + 1], b2 = in[i * 3 + 2];
			int32_t v = (int32_t)((b2 << 24) | (b1 << 16) | (b0 << 8));
			s[i] = v;
		} else if (cin == PCM_FORMAT_S24_LE || cin == PCM_FORMAT_S32_LE) {
			int32_t v;
			memcpy(&v, in + i * 4, 4);
			s[i] = (cin == PCM_FORMAT_S24_LE) ? (v << 8) : v;
		} else {
			s[i] = 0;
		}
	}
	for (i = 0; i < ch; i++) {
		if (cout == PCM_FORMAT_S16_LE) {
			int16_t v = (int16_t)(s[i] >> 16);
			memcpy(out + i * 2, &v, 2);
		} else if (cout == PCM_FORMAT_S24_3LE) {
			uint32_t u = (uint32_t)s[i];
			out[i * 3] = (uint8_t)(u >> 8);
			out[i * 3 + 1] = (uint8_t)(u >> 16);
			out[i * 3 + 2] = (uint8_t)(u >> 24);
		} else if (cout == PCM_FORMAT_S32_LE || cout == PCM_FORMAT_S24_LE) {
			int32_t v = (cout == PCM_FORMAT_S24_LE) ? (s[i] >> 8) : s[i];
			memcpy(out + i * 4, &v, 4);
		}
	}
}

static void *capture_thread(void *arg)
{
	struct Bridge *b = (struct Bridge *)arg;
	size_t nbytes = (size_t)b->cap_period * b->cap_frame_bytes;
	uint8_t *buf = (uint8_t *)malloc(nbytes);
	if (!buf)
		return NULL;

	while (g_run) {
		int r = pcm_readi(b->cap, buf, b->cap_period);
		if (r < 0) {
			if (r == -EPIPE) {
				b->xrun_cap++;
				pcm_prepare(b->cap);
			}
			usleep(500);
			continue;
		}
		if (r == 0)
			continue;
		ring_write(&b->ring, buf, (size_t)r * b->cap_frame_bytes);
		b->frames_cap += (uint64_t)r;
	}
	free(buf);
	return NULL;
}

static int try_open_play_dev(struct Bridge *b, unsigned card, unsigned dev,
			     enum pcm_format fmt);

static void *playback_thread(void *arg)
{
	struct Bridge *b = (struct Bridge *)arg;
	size_t cap_need = (size_t)b->play_period * b->cap_frame_bytes;
	size_t play_bytes = (size_t)b->play_period * b->play_frame_bytes;
	uint8_t *capbuf = (uint8_t *)malloc(cap_need);
	uint8_t *playbuf = (uint8_t *)malloc(play_bytes);
	uint8_t frame_in[MAX_FRAME_BYTES];
	uint8_t frame_out[MAX_FRAME_BYTES];
	uint64_t last_check_ns = 0, last_slip_ns = 0;

	if (!capbuf || !playbuf) {
		free(capbuf);
		free(playbuf);
		return NULL;
	}

	/* prebuffer */
	while (g_run && ring_avail(&b->ring) < b->prebuf_bytes)
		usleep(1000);

	fprintf(stderr, "play start prebuf=%zu period=%u\n", ring_avail(&b->ring),
		b->play_period);
	fflush(stderr);

	while (g_run) {
		size_t got = ring_read(&b->ring, capbuf, cap_need, 80);
		size_t frames = got / b->cap_frame_bytes;
		size_t i;
		int w;
		static unsigned err_logs;

		/* Always feed a full hardware period (QC rejects short writes). */
		memset(playbuf, 0, play_bytes);
		if (frames > b->play_period)
			frames = b->play_period;
		if (frames < b->play_period)
			b->ring_underruns++;

		if (frames > 0) {
			if (b->cap_fmt == b->play_fmt) {
				memcpy(playbuf, capbuf, frames * b->play_frame_bytes);
			} else {
				for (i = 0; i < frames; i++) {
					memcpy(frame_in, capbuf + i * b->cap_frame_bytes,
					       b->cap_frame_bytes);
					convert_frame(frame_in, b->cap_fmt, frame_out,
						      b->play_fmt, b->ch);
					memcpy(playbuf + i * b->play_frame_bytes, frame_out,
					       b->play_frame_bytes);
				}
			}
		}

		w = pcm_writei(b->play, playbuf, b->play_period);
		if (w < 0) {
			const char *err = pcm_get_error(b->play);
			b->xrun_play++;
			if (err_logs < 16) {
				fprintf(stderr, "play write err: %s\n", err ? err : "?");
				fflush(stderr);
				err_logs++;
			}
			/* DISCONNECTED / not recoverable → must reopen FE */
			if (err && (strstr(err, "not recoverable") ||
				    strstr(err, "DISCONNECTED") ||
				    strstr(err, "disconnected"))) {
				unsigned card = b->play_card, dev = b->play_dev;
				enum pcm_format fmt = b->play_fmt;
				pcm_close(b->play);
				b->play = NULL;
				usleep(50000);
				if (try_open_play_dev(b, card, dev, fmt) != 0) {
					fprintf(stderr, "play reopen fail — exit\n");
					fflush(stderr);
					g_run = 0;
					break;
				}
				fprintf(stderr, "play reopened %u:%u\n", card, dev);
				fflush(stderr);
			} else {
				pcm_prepare(b->play);
			}
		} else {
			b->frames_play += (uint64_t)(w > 0 ? w : (int)b->play_period);
		}

		/* Keep ring occupancy near the startup target; compare queue depth, not
		 * cumulative frame counters (which include the initial prebuffer offset).
		 * A single-frame slip at most every 200ms corrects independent USB/AFE
		 * clocks without audible bursts during long playback.
		 */
		{
			struct timespec ts;
			uint64_t now_ns, target, queued;
			clock_gettime(CLOCK_MONOTONIC, &ts);
			now_ns = (uint64_t)ts.tv_sec * 1000000000ULL + ts.tv_nsec;
			target = b->prebuf_bytes / b->cap_frame_bytes;
			if (!last_check_ns || now_ns - last_check_ns >= 100000000ULL) {
				int64_t skew;
				queued = ring_avail(&b->ring) / b->cap_frame_bytes;
				skew = (int64_t)queued - (int64_t)target;
				last_check_ns = now_ns;
				if (now_ns - last_slip_ns >= 200000000ULL &&
				    skew > (int64_t)(b->rate / 100)) {
					ring_drop_bytes(&b->ring, b->cap_frame_bytes);
					b->drift_drops++;
					last_slip_ns = now_ns;
				} else if (now_ns - last_slip_ns >= 200000000ULL &&
					   skew < -(int64_t)(b->rate / 100)) {
					ring_insert_silence(&b->ring, b->cap_frame_bytes);
					b->drift_inserts++;
					last_slip_ns = now_ns;
				}
				hb_write(b);
			}
		}
	}
	free(capbuf);
	free(playbuf);
	return NULL;
}

static int open_cap(struct Bridge *b, unsigned card)
{
	struct pcm_config cfg;
	memset(&cfg, 0, sizeof(cfg));
	cfg.channels = b->ch;
	cfg.rate = b->rate;
	cfg.period_size = b->cap_period;
	cfg.period_count = 4;
	cfg.format = b->cap_fmt;
	cfg.start_threshold = 0;
	cfg.stop_threshold = cfg.period_size * cfg.period_count;
	b->cap = pcm_open(card, 0, PCM_IN, &cfg);
	if (!b->cap || !pcm_is_ready(b->cap)) {
		fprintf(stderr, "cap open fail: %s\n",
			b->cap ? pcm_get_error(b->cap) : "null");
		if (b->cap)
			pcm_close(b->cap);
		b->cap = NULL;
		return -1;
	}
	return 0;
}

static void collect_play_devs(unsigned play_card, unsigned *devs, int *ndevs, int max)
{
	DIR *d = opendir("/dev/snd");
	char prefix[32];
	struct dirent *e;
	snprintf(prefix, sizeof(prefix), "pcmC%uD", play_card);
	*ndevs = 0;
	if (!d) {
		devs[(*ndevs)++] = 0;
		return;
	}
	while ((e = readdir(d)) != NULL && *ndevs < max) {
		unsigned dev;
		char suffix;
		if (strncmp(e->d_name, prefix, strlen(prefix)) != 0)
			continue;
		if (sscanf(e->d_name + strlen(prefix), "%u%c", &dev, &suffix) != 2)
			continue;
		if (suffix != 'p')
			continue;
		devs[(*ndevs)++] = dev;
	}
	closedir(d);
	if (*ndevs == 0)
		devs[(*ndevs)++] = 0;
}

/* Qualcomm MultiMedia FEs that can feed SLIMBUS0 / TERT_TDM (headphones).
 * Avoid Dual-audio / hostless nodes that accept S24 but do not hit HPH/ESS. */
static int is_primary_play_dev(unsigned d)
{
	switch (d) {
	case 0:  /* MultiMedia1 */
	case 1:  /* MultiMedia2 */
	case 4:  /* MultiMedia3 */
	case 13: /* MultiMedia5 */
	case 16: /* MultiMedia10 */
	case 27: /* MultiMedia9 */
	case 38: /* MultiMedia6 */
	case 41: /* MultiMedia21 */
	case 42: /* MultiMedia22 */
		return 1;
	default:
		return 0;
	}
}

static int try_open_play_dev(struct Bridge *b, unsigned card, unsigned dev,
			     enum pcm_format fmt)
{
	struct pcm_config cfg;
	struct pcm *p;

	memset(&cfg, 0, sizeof(cfg));
	cfg.channels = b->ch;
	cfg.rate = b->rate;
	cfg.period_size = b->play_period;
	cfg.period_count = PLAY_PERIOD_COUNT;
	cfg.format = fmt;
	/* No PCM_NORESTART: allow ALSA recovery; start after one period */
	cfg.start_threshold = cfg.period_size;
	cfg.stop_threshold = cfg.period_size * cfg.period_count;
	cfg.avail_min = 1;
	p = pcm_open(card, dev, PCM_OUT, &cfg);
	if (p && pcm_is_ready(p)) {
		b->play = p;
		b->play_card = card;
		b->play_dev = dev;
		b->play_fmt = fmt;
		b->play_frame_bytes = fmt_bytes(b->play_fmt) * b->ch;
		snprintf(b->play_fmt_name, sizeof(b->play_fmt_name), "%s",
			 fmt_name(b->play_fmt));
		fprintf(stderr, "play OK dev=%u fmt=%s period=%u\n", dev,
			b->play_fmt_name, b->play_period);
		return 0;
	}
	fprintf(stderr, "  play %u:%u fmt=%s fail: %s\n", card, dev, fmt_name(fmt),
		p ? pcm_get_error(p) : "null");
	if (p)
		pcm_close(p);
	return -1;
}

static int open_play(struct Bridge *b, unsigned card, unsigned prefer_dev)
{
	unsigned devs[32];
	int ndevs = 0, di, fi, pass;
	enum pcm_format try_fmt[] = {
		/* MM1 on judyln often rejects S24_3LE — try S16 early for primary FEs */
		PCM_FORMAT_S16_LE, PCM_FORMAT_S24_3LE, PCM_FORMAT_S32_LE,
		PCM_FORMAT_S24_LE
	};

	collect_play_devs(card, devs, &ndevs, 32);

	/* Pass 0: prefer_dev × all formats (usually MultiMedia1).
	 * Pass 1: other primary MultiMedia FEs × all formats.
	 * Pass 2: remaining devices (hostless/dual) last — last resort only. */
	for (pass = 0; pass < 3; pass++) {
		for (fi = 0; fi < (int)(sizeof(try_fmt) / sizeof(try_fmt[0])); fi++) {
			for (di = 0; di < ndevs; di++) {
				unsigned d = devs[di];
				if (pass == 0 && d != prefer_dev)
					continue;
				if (pass == 1 && (d == prefer_dev || !is_primary_play_dev(d)))
					continue;
				if (pass == 2 && (d == prefer_dev || is_primary_play_dev(d)))
					continue;
				if (try_open_play_dev(b, card, d, try_fmt[fi]) == 0)
					return 0;
			}
		}
	}
	return -1;
}

int main(int argc, char **argv)
{
	struct Bridge b;
	unsigned cap_card, play_card, play_dev = 0;
	unsigned bits = 24;
	size_t ring_bytes;

	if (argc < 3) {
		fprintf(stderr,
			"usage: %s <cap> <play> [dev] [rate] [ch] [cap_bits]\n",
			argv[0]);
		return 1;
	}
	memset(&b, 0, sizeof(b));
	cap_card = (unsigned)atoi(argv[1]);
	play_card = (unsigned)atoi(argv[2]);
	if (argc > 3)
		play_dev = (unsigned)atoi(argv[3]);
	b.rate = argc > 4 ? (unsigned)atoi(argv[4]) : 48000;
	b.ch = argc > 5 ? (unsigned)atoi(argv[5]) : 2;
	bits = argc > 6 ? (unsigned)atoi(argv[6]) : 24;

	b.cap_fmt = (bits >= 24) ? PCM_FORMAT_S24_3LE : PCM_FORMAT_S16_LE;
	b.cap_frame_bytes = fmt_bytes(b.cap_fmt) * b.ch;
	b.cap_period = b.rate * CAP_PERIOD_MS / 1000;
	b.play_period = b.rate * PLAY_PERIOD_MS / 1000;
	if (b.cap_period < 32)
		b.cap_period = 32;
	if (b.play_period < 32)
		b.play_period = 32;
	if (b.cap_period > MAX_PERIOD_FRAMES)
		b.cap_period = MAX_PERIOD_FRAMES;
	if (b.play_period > MAX_PERIOD_FRAMES)
		b.play_period = MAX_PERIOD_FRAMES;

	snprintf(b.cap_fmt_name, sizeof(b.cap_fmt_name), "%s", fmt_name(b.cap_fmt));

	ring_bytes = (size_t)b.rate * RING_MS / 1000 * b.cap_frame_bytes;
	b.prebuf_bytes = (size_t)b.rate * PREBUF_MS / 1000 * b.cap_frame_bytes;
	if (ring_init(&b.ring, ring_bytes) != 0) {
		fprintf(stderr, "ring alloc fail\n");
		return 1;
	}

	signal(SIGINT, on_sig);
	signal(SIGTERM, on_sig);
	signal(SIGHUP, SIG_IGN);

	fprintf(stderr,
		"Mode A bridge: cap=%u play=%u rate=%u ch=%u bits=%u "
		"cap_period=%u play_period=%u ring=%ums pre=%ums\n",
		cap_card, play_card, b.rate, b.ch, bits, b.cap_period, b.play_period,
		RING_MS, PREBUF_MS);

	if (open_cap(&b, cap_card) != 0) {
		/* fallback 16-bit if 24 fails */
		if (bits >= 24) {
			fprintf(stderr, "retry cap as S16\n");
			b.cap_fmt = PCM_FORMAT_S16_LE;
			b.cap_frame_bytes = fmt_bytes(b.cap_fmt) * b.ch;
			snprintf(b.cap_fmt_name, sizeof(b.cap_fmt_name), "S16_LE");
			if (open_cap(&b, cap_card) != 0) {
				ring_free(&b.ring);
				return 2;
			}
		} else {
			ring_free(&b.ring);
			return 2;
		}
	}

	if (open_play(&b, play_card, play_dev) != 0) {
		fprintf(stderr, "FATAL: no play PCM (audioserver holding device?)\n");
		pcm_close(b.cap);
		ring_free(&b.ring);
		return 3;
	}

	hb_write(&b);
	pthread_create(&b.cap_th, NULL, capture_thread, &b);
	pthread_create(&b.play_th, NULL, playback_thread, &b);

	fprintf(stderr, "OK Mode A bridging %s -> %s\n", b.cap_fmt_name, b.play_fmt_name);
	fflush(stderr);

	while (g_run)
		sleep(1);

	g_run = 0;
	pthread_cond_broadcast(&b.ring.cv);
	pthread_join(b.cap_th, NULL);
	pthread_join(b.play_th, NULL);
	pcm_close(b.cap);
	pcm_close(b.play);
	ring_free(&b.ring);
	return 0;
}
