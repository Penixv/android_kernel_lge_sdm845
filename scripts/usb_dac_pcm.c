/*
 * Exclusive ALSA: UAC2 capture -> codec playback.
 * Same period for cap/play; soft gain; silence fill when host idle.
 * Heartbeat -> /data/adb/usb_dac/hb
 *
 * usage: usb_dac_pcm <cap> <play> [play_dev] [rate] [ch] [bits]
 */
#include <tinyalsa/asoundlib.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define HB_PATH "/data/adb/usb_dac/hb"
#define GAIN 1.8f

static volatile int running = 1;
static void on_sig(int sig) { (void)sig; running = 0; }

struct try_cfg {
	unsigned period;
	unsigned periods;
};

static void hb(unsigned long long frames, unsigned long long nonzero)
{
	int fd = open("/data/adb/usb_dac/hb.tmp", O_WRONLY | O_CREAT | O_TRUNC, 0644);
	if (fd < 0)
		return;
	dprintf(fd,
		"mode=exclusive\nbridge=pcm\nalive=1\nframes=%llu\nnonzero=%llu\nts=%ld\n",
		frames, nonzero, (long)time(NULL));
	close(fd);
	rename("/data/adb/usb_dac/hb.tmp", HB_PATH);
}

static void apply_gain(int16_t *s, size_t n)
{
	size_t i;
	for (i = 0; i < n; i++) {
		float v = (float)s[i] * GAIN;
		if (v > 32767.f)
			v = 32767.f;
		if (v < -32768.f)
			v = -32768.f;
		s[i] = (int16_t)v;
	}
}

static int sample_energy(const int16_t *s, size_t n)
{
	size_t i;
	for (i = 0; i < n; i++)
		if (s[i] > 64 || s[i] < -64)
			return 1;
	return 0;
}

static int open_cap(unsigned card, unsigned rate, unsigned ch, enum pcm_format fmt,
		    unsigned period, unsigned periods, struct pcm **out)
{
	struct pcm_config cfg;
	struct pcm *p;

	memset(&cfg, 0, sizeof(cfg));
	cfg.channels = ch;
	cfg.rate = rate;
	cfg.period_size = period;
	cfg.period_count = periods;
	cfg.format = fmt;
	cfg.start_threshold = 0;
	cfg.stop_threshold = period * periods;
	cfg.silence_threshold = 0;

	p = pcm_open(card, 0, PCM_IN, &cfg);
	if (!p || !pcm_is_ready(p)) {
		fprintf(stderr, "  cap %u:0 p=%u n=%u fail: %s\n", card, period, periods,
			p ? pcm_get_error(p) : "null");
		if (p)
			pcm_close(p);
		return -1;
	}
	*out = p;
	return 0;
}

static int open_play(unsigned card, unsigned dev, unsigned rate, unsigned ch,
		     enum pcm_format fmt, unsigned period, unsigned periods,
		     struct pcm **out)
{
	struct pcm_config cfg;
	struct pcm *p;

	memset(&cfg, 0, sizeof(cfg));
	cfg.channels = ch;
	cfg.rate = rate;
	cfg.period_size = period;
	cfg.period_count = periods;
	cfg.format = fmt;
	cfg.start_threshold = period * 2;
	cfg.stop_threshold = period * periods;
	cfg.silence_threshold = 0;

	p = pcm_open(card, dev, PCM_OUT, &cfg);
	if (!p || !pcm_is_ready(p)) {
		fprintf(stderr, "  play %u:%u p=%u n=%u fail: %s\n", card, dev, period,
			periods, p ? pcm_get_error(p) : "null");
		if (p)
			pcm_close(p);
		return -1;
	}
	*out = p;
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

int main(int argc, char **argv)
{
	unsigned cap_card, play_card, play_dev_pref = 0;
	unsigned rate = 48000, ch = 2, bits = 16;
	enum pcm_format fmt;
	struct pcm *cap = NULL, *play = NULL;
	char *buf = NULL;
	unsigned frames = 0, bytes;
	unsigned devs[32];
	int ndevs = 0, di, ti, i;
	int rc = 1;
	unsigned long long total = 0, nonzero = 0;
	time_t last_hb = 0;
	/* Same period both sides — 480 matches working AAudio UAC open */
	struct try_cfg tries[] = {
		{480, 8}, {480, 4}, {960, 4}, {960, 8}, {256, 8}, {192, 8},
	};

	if (argc < 3) {
		fprintf(stderr, "usage: %s <cap> <play> [dev] [rate] [ch] [bits]\n", argv[0]);
		return 1;
	}
	cap_card = (unsigned)atoi(argv[1]);
	play_card = (unsigned)atoi(argv[2]);
	if (argc > 3)
		play_dev_pref = (unsigned)atoi(argv[3]);
	if (argc > 4)
		rate = (unsigned)atoi(argv[4]);
	if (argc > 5)
		ch = (unsigned)atoi(argv[5]);
	if (argc > 6)
		bits = (unsigned)atoi(argv[6]);

	switch (bits) {
	case 32: fmt = PCM_FORMAT_S32_LE; break;
	case 24: fmt = PCM_FORMAT_S24_3LE; break;
	default: fmt = PCM_FORMAT_S16_LE; bits = 16; break;
	}

	signal(SIGINT, on_sig);
	signal(SIGTERM, on_sig);
	signal(SIGHUP, SIG_IGN);

	collect_play_devs(play_card, devs, &ndevs, 32);
	/* Prefer MultMedia1 (usually 0), then others */
	if (ndevs < 32) {
		int found = 0;
		for (di = 0; di < ndevs; di++)
			if (devs[di] == play_dev_pref)
				found = 1;
		if (!found) {
			memmove(devs + 1, devs, (size_t)ndevs * sizeof(unsigned));
			devs[0] = play_dev_pref;
			ndevs++;
		} else {
			for (di = 0; di < ndevs; di++) {
				if (devs[di] == play_dev_pref && di > 0) {
					unsigned t = devs[0];
					devs[0] = play_dev_pref;
					devs[di] = t;
					break;
				}
			}
		}
	}

	fprintf(stderr, "exclusive: cap=%u play=%u rate=%u ch=%u nodes=%d\n",
		cap_card, play_card, rate, ch, ndevs);
	fflush(stderr);

	for (ti = 0; ti < (int)(sizeof(tries) / sizeof(tries[0])) && !cap; ti++) {
		struct pcm *c = NULL;
		if (open_cap(cap_card, rate, ch, fmt, tries[ti].period, tries[ti].periods,
			     &c) != 0)
			continue;
		for (di = 0; di < ndevs; di++) {
			struct pcm *p = NULL;
			if (open_play(play_card, devs[di], rate, ch, fmt, tries[ti].period,
				      tries[ti].periods, &p) != 0)
				continue;
			cap = c;
			play = p;
			frames = tries[ti].period;
			fprintf(stderr, "OK exclusive play_dev=%u period=%u n=%u\n",
				devs[di], tries[ti].period, tries[ti].periods);
			fflush(stderr);
			break;
		}
		if (!play)
			pcm_close(c);
	}

	if (!cap || !play) {
		fprintf(stderr, "FATAL: no exclusive PCM pair\n");
		return 2;
	}

	bytes = pcm_frames_to_bytes(cap, frames);
	buf = malloc(bytes);
	if (!buf)
		goto out;

	/* Prime playback with a little silence so DMA starts */
	memset(buf, 0, bytes);
	for (i = 0; i < 4; i++)
		(void)pcm_writei(play, buf, frames);

	fprintf(stderr, "bridging exclusive… (gain=%.1f)\n", (double)GAIN);
	fflush(stderr);
	hb(0, 0);

	while (running) {
		int r = pcm_readi(cap, buf, frames);
		if (r < 0) {
			if (r == -EPIPE)
				pcm_prepare(cap);
			/* Keep play clock alive with silence */
			memset(buf, 0, bytes);
			(void)pcm_writei(play, buf, frames);
			usleep(1000);
			continue;
		}
		if (r == 0) {
			memset(buf, 0, bytes);
			(void)pcm_writei(play, buf, frames);
			continue;
		}
		total += (unsigned long long)r;
		if (sample_energy((int16_t *)buf, (size_t)r * ch))
			nonzero += (unsigned long long)r;
		apply_gain((int16_t *)buf, (size_t)r * ch);
		{
			int w = pcm_writei(play, buf, (unsigned)r);
			if (w < 0) {
				if (w == -EPIPE)
					pcm_prepare(play);
				usleep(1000);
			}
		}
		{
			time_t now = time(NULL);
			if (now != last_hb) {
				last_hb = now;
				hb(total, nonzero);
			}
		}
	}
	rc = 0;
out:
	free(buf);
	if (cap)
		pcm_close(cap);
	if (play)
		pcm_close(play);
	return rc;
}
