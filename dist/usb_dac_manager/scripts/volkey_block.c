/*
 * Grab every input node that has VOLUME keys and does NOT have POWER/HOME.
 * On judyln:
 *   event5 gpio-keys     = Vol+ only  → grab
 *   event7 Button Jack   = Vol+/Vol-  → grab (headset buttons)
 *   event0 qpnp_pon      = Vol- + POWER → NEVER grab (freezes phone)
 * Soft-read qpnp_pon without grab so we still see Vol- (route_keepalive
 * repairs AF wipe; this just drains our copy of the queue).
 */
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/input.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

#ifndef EVIOCGRAB
#define EVIOCGRAB _IOW('E', 0x90, int)
#endif

static volatile int running = 1;
static int grab_fds[16];
static int ngrab;
static int watch_fds[8];
static int nwatch;

static void on_sig(int s) { (void)s; running = 0; }

static int test_bit(const unsigned char *bits, int k)
{
	return bits[k / 8] & (1u << (k % 8));
}

static int has_key(int fd, int key)
{
	unsigned char keybits[(KEY_MAX + 7) / 8];
	memset(keybits, 0, sizeof(keybits));
	if (ioctl(fd, EVIOCGBIT(EV_KEY, sizeof(keybits)), keybits) < 0)
		return 0;
	return test_bit(keybits, key) ? 1 : 0;
}

static int has_powerish(int fd)
{
	return has_key(fd, KEY_POWER) || has_key(fd, KEY_POWER2) ||
	       has_key(fd, KEY_SLEEP) || has_key(fd, KEY_SUSPEND) ||
	       has_key(fd, KEY_HOMEPAGE) || has_key(fd, KEY_HOME) ||
	       has_key(fd, KEY_END) || has_key(fd, KEY_WAKEUP);
}

static void release_all(void)
{
	int i;
	for (i = 0; i < ngrab; i++) {
		if (grab_fds[i] >= 0) {
			ioctl(grab_fds[i], EVIOCGRAB, (void *)0);
			close(grab_fds[i]);
			grab_fds[i] = -1;
		}
	}
	ngrab = 0;
	for (i = 0; i < nwatch; i++) {
		if (watch_fds[i] >= 0) {
			close(watch_fds[i]);
			watch_fds[i] = -1;
		}
	}
	nwatch = 0;
}

int main(void)
{
	DIR *d;
	struct dirent *e;
	char path[128];
	int pass;

	signal(SIGINT, on_sig);
	signal(SIGTERM, on_sig);
	memset(grab_fds, -1, sizeof(grab_fds));
	memset(watch_fds, -1, sizeof(watch_fds));

	d = opendir("/dev/input");
	if (!d) {
		perror("opendir");
		return 1;
	}

	for (pass = 0; pass < 6; pass++) {
		rewinddir(d);
		while ((e = readdir(d)) != NULL && ngrab < 16) {
			int fd, i, already = 0;
			if (strncmp(e->d_name, "event", 5) != 0)
				continue;
			snprintf(path, sizeof(path), "/dev/input/%.64s", e->d_name);
			/* skip already grabbed by name via fd path compare later */
			fd = open(path, O_RDONLY | O_NONBLOCK);
			if (fd < 0)
				continue;
			if (!has_key(fd, KEY_VOLUMEUP) && !has_key(fd, KEY_VOLUMEDOWN)) {
				close(fd);
				continue;
			}
			if (has_powerish(fd)) {
				/* Soft-watch only (Vol- on qpnp_pon) */
				already = 0;
				for (i = 0; i < nwatch; i++) {
					char link[64], tgt[128];
					snprintf(link, sizeof(link), "/proc/self/fd/%d", watch_fds[i]);
					memset(tgt, 0, sizeof(tgt));
					if (readlink(link, tgt, sizeof(tgt) - 1) > 0 &&
					    strcmp(tgt, path) == 0) {
						already = 1;
						break;
					}
				}
				if (already || nwatch >= 8) {
					close(fd);
				} else {
					fprintf(stderr, "watch(no-grab) %s (vol shares power)\n", path);
					watch_fds[nwatch++] = fd;
				}
				continue;
			}
			/* already have this path? */
			for (i = 0; i < ngrab; i++) {
				char link[64], tgt[128];
				snprintf(link, sizeof(link), "/proc/self/fd/%d", grab_fds[i]);
				memset(tgt, 0, sizeof(tgt));
				if (readlink(link, tgt, sizeof(tgt) - 1) > 0 &&
				    strcmp(tgt, path) == 0) {
					already = 1;
					break;
				}
			}
			if (already) {
				close(fd);
				continue;
			}
			if (ioctl(fd, EVIOCGRAB, (void *)1) < 0) {
				fprintf(stderr, "grab %s fail: %s (retry)\n", path, strerror(errno));
				close(fd);
				continue;
			}
			fprintf(stderr, "grabbed vol-only %s\n", path);
			grab_fds[ngrab++] = fd;
		}
		if (ngrab >= 2)
			break;
		usleep(200000);
	}
	closedir(d);

	fprintf(stderr, "volkey_block: grabbed=%d watch=%d\n", ngrab, nwatch);
	if (ngrab == 0 && nwatch == 0) {
		while (running)
			sleep(1);
		return 0;
	}

	while (running) {
		struct pollfd pfd[24];
		int np = 0, i, to;
		struct input_event ev;
		for (i = 0; i < ngrab && np < 24; i++) {
			pfd[np].fd = grab_fds[i];
			pfd[np].events = POLLIN;
			pfd[np].revents = 0;
			np++;
		}
		for (i = 0; i < nwatch && np < 24; i++) {
			pfd[np].fd = watch_fds[i];
			pfd[np].events = POLLIN;
			pfd[np].revents = 0;
			np++;
		}
		to = poll(pfd, np, 200);
		if (to <= 0)
			continue;
		for (i = 0; i < np; i++) {
			if (!(pfd[i].revents & POLLIN))
				continue;
			while (read(pfd[i].fd, &ev, sizeof(ev)) == (ssize_t)sizeof(ev)) {
				if (ev.type == EV_KEY &&
				    (ev.code == KEY_VOLUMEUP || ev.code == KEY_VOLUMEDOWN) &&
				    ev.value != 0) {
					/* nudge keepalive: touch a stamp file */
					int sf = open("/data/adb/usb_dac/vol_hit",
						      O_WRONLY | O_CREAT | O_TRUNC, 0644);
					if (sf >= 0) {
						write(sf, "1", 1);
						close(sf);
					}
				}
			}
		}
	}
	release_all();
	return 0;
}
