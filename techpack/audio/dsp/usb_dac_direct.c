/*
 * usb_dac_direct — Mode A kernel path for LG G7 (judyln / SDM845 / ES9218)
 *
 * PC USB ISO → f_uac2 capture → kthread ring → MultiMedia1 → SLIMBUS_6 →
 * tavil RX0/RX1 → HPH → ESS Bypass → 3.5mm
 *
 * Sysfs: /sys/kernel/usb_dac_direct/{enable,gain,status}
 * Boot param: usb_dac_direct.enable=0 to force disable / rollback.
 */
#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/kthread.h>
#include <linux/delay.h>
#include <linux/slab.h>
#include <linux/fs.h>
#include <linux/uaccess.h>
#include <linux/sysfs.h>
#include <linux/kobject.h>
#include <linux/mutex.h>
#include <linux/spinlock.h>
#include <linux/input.h>
#include <linux/wait.h>
#include <linux/sched.h>
#include <linux/jiffies.h>
#include <linux/string.h>
#include <linux/version.h>
#include <linux/workqueue.h>
#include <linux/sched.h>

#include <sound/core.h>
#include <sound/control.h>
#include <sound/pcm.h>
#include <sound/pcm_params.h>
#include <sound/asound.h>

#include <usb_dac_direct.h>

#define UDD_NAME		"usb_dac_direct"
#define UDD_RATE		48000
#define UDD_CH			2
/*
 * Stability over latency: play xrun death-spiral = 电流声/卡顿.
 * Auto-silence on underrun (no EPIPE storm), big ring, play RT > cap.
 */
#define UDD_PERIOD_MS		20
#define UDD_RING_MS		480
#define UDD_PREBUF_MS		40
#define UDD_PLAY_PERIODS	16
#define UDD_CAP_PERIODS		8
#define UDD_HPH_DEFAULT		16
#define UDD_HPH_MIN		0
#define UDD_HPH_MAX		20	/* tavil HPHL/HPHR hardware range */
#define UDD_HPH_STEP		1
#define UDD_RX_DIG_DEFAULT	84	/* <84 breaks on tavil (stored as 256+v) */
#define UDD_PLAY_RT_PRIO	50
#define UDD_CAP_RT_PRIO		40
#define UDD_FRAME_ALIGN(n, fb)	((size_t)(n) - ((size_t)(n) % (size_t)(fb)))
#define UDD_DRIFT_CHECK_MS	100
#define UDD_DRIFT_SLIP_MS	200
#define UDD_DRIFT_LIMIT_MS	10

/* Cmdline usb_dac_direct.enable=0 disables; default armed (enable is async). */
static bool boot_enable = true;
module_param_named(enable, boot_enable, bool, 0644);
MODULE_PARM_DESC(enable, "Allow usb_dac_direct sysfs (default Y; 0=refuse)");

/*
 * Any kctl->put / DAPM from this driver has frozen judyln vs audioserver.
 * Default: PCM bridge only. Userspace MUST run route_mm1_slim6.sh (FE+codec)
 * while MultiMedia1 is still closed, then echo 1 > enable.
 */
static bool do_fe_route;
module_param_named(fe_route, do_fe_route, bool, 0644);
MODULE_PARM_DESC(fe_route, "Put MM1→SLIM6 from kernel (default N; do in userspace)");

static bool do_codec_route;
module_param_named(codec_route, do_codec_route, bool, 0644);
MODULE_PARM_DESC(codec_route, "Also poke codec MUX/ESS (default N — unsafe)");

/*
 * Default off — userspace volkey_block + soft keepalive.
 * Kernel filter + tinymix HPH put still glitches RT play briefly.
 */
static bool do_volkeys;
module_param_named(volkeys, do_volkeys, bool, 0644);
MODULE_PARM_DESC(volkeys, "Register volume filter (default N; use volkey_block)");

static struct kobject *udd_kobj;
static DEFINE_MUTEX(udd_lock);
static atomic_t udd_enabled = ATOMIC_INIT(0);
static atomic_t udd_want = ATOMIC_INIT(0);
static struct workqueue_struct *udd_wq_sys;
static struct work_struct udd_work;
static struct delayed_work udd_requeue_work;
static atomic_t udd_route_ok = ATOMIC_INIT(0);
static atomic_t udd_hph_vol = ATOMIC_INIT(UDD_HPH_DEFAULT);
static atomic_t udd_gain = ATOMIC_INIT(100); /* percent 0..150 applied to digital */
static atomic_t udd_vol_pending = ATOMIC_INIT(0);

static struct task_struct *udd_cap_task;
static struct task_struct *udd_play_task;
static wait_queue_head_t udd_wq;
static atomic_t udd_stop = ATOMIC_INIT(1);

/* stats */
static u64 udd_frames_cap;
static u64 udd_frames_play;
static u64 udd_xrun_cap;
static u64 udd_xrun_play;
static u64 udd_drift_drops;
static u64 udd_drift_inserts;
static u64 udd_ring_underruns;
static char udd_status_msg[128] = "idle";

/* ---- ring buffer (byte) ---- */
struct udd_ring {
	u8 *data;
	size_t capacity;
	size_t r, w, count;
	u64 overruns;
	spinlock_t lock;
	wait_queue_head_t wq;
};

static struct udd_ring udd_ring;

static int udd_ring_init(struct udd_ring *rg, size_t bytes)
{
	rg->data = kzalloc(bytes, GFP_KERNEL);
	if (!rg->data)
		return -ENOMEM;
	rg->capacity = bytes;
	rg->r = rg->w = rg->count = 0;
	rg->overruns = 0;
	spin_lock_init(&rg->lock);
	init_waitqueue_head(&rg->wq);
	return 0;
}

static void udd_ring_free(struct udd_ring *rg)
{
	kfree(rg->data);
	rg->data = NULL;
	rg->capacity = 0;
	rg->r = rg->w = rg->count = 0;
	/* Keep wq valid — stop path may wake after free. */
	init_waitqueue_head(&rg->wq);
}

static void udd_ring_wake(struct udd_ring *rg)
{
	/* Only wake after init_waitqueue_head (never on BSS-zero list). */
	if (rg->wq.task_list.prev)
		wake_up_interruptible(&rg->wq);
}

/*
 * Chunked memcpy ring — old byte-at-a-time copy held spinlock for ~4k irqs-off
 * iterations per period and caused play xruns → 电流声 / mono-like garbage.
 */
static size_t udd_ring_write(struct udd_ring *rg, const void *src, size_t n)
{
	const u8 *p = src;
	size_t put = 0;
	unsigned long flags;

	if (!rg->data || !n)
		return 0;

	spin_lock_irqsave(&rg->lock, flags);
	if (n >= rg->capacity) {
		/* Keep only the last capacity bytes, frame-safe caller side. */
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
		size_t chunk = min(n - put, rg->capacity - rg->w);

		memcpy(rg->data + rg->w, p + put, chunk);
		rg->w = (rg->w + chunk) % rg->capacity;
		rg->count += chunk;
		put += chunk;
	}
	spin_unlock_irqrestore(&rg->lock, flags);
	wake_up_interruptible(&rg->wq);
	return put;
}

static size_t udd_ring_read(struct udd_ring *rg, void *dst, size_t n, int wait_ms)
{
	u8 *p = dst;
	size_t got = 0;
	unsigned long flags;
	long timeout = msecs_to_jiffies(wait_ms);

	if (!rg->data || !n)
		return 0;

	if (wait_ms > 0) {
		wait_event_interruptible_timeout(rg->wq,
			READ_ONCE(rg->count) >= n || atomic_read(&udd_stop), timeout);
	}

	spin_lock_irqsave(&rg->lock, flags);
	if (n > rg->count)
		n = rg->count;
	while (got < n) {
		size_t chunk = min(n - got, rg->capacity - rg->r);

		memcpy(p + got, rg->data + rg->r, chunk);
		rg->r = (rg->r + chunk) % rg->capacity;
		rg->count -= chunk;
		got += chunk;
	}
	spin_unlock_irqrestore(&rg->lock, flags);
	return got;
}

static size_t udd_ring_avail(struct udd_ring *rg)
{
	size_t c;
	unsigned long flags;

	spin_lock_irqsave(&rg->lock, flags);
	c = rg->count;
	spin_unlock_irqrestore(&rg->lock, flags);
	return c;
}

static u64 udd_ring_overruns(struct udd_ring *rg)
{
	u64 n;
	unsigned long flags;

	spin_lock_irqsave(&rg->lock, flags);
	n = rg->overruns;
	spin_unlock_irqrestore(&rg->lock, flags);
	return n;
}

static void udd_ring_drop(struct udd_ring *rg, size_t n)
{
	unsigned long flags;

	spin_lock_irqsave(&rg->lock, flags);
	if (n > rg->count)
		n = rg->count;
	rg->r = (rg->r + n) % rg->capacity;
	rg->count -= n;
	spin_unlock_irqrestore(&rg->lock, flags);
}

static void udd_ring_insert_silence(struct udd_ring *rg, size_t n)
{
	static const u8 zero[16];

	if (!n)
		return;
	while (n) {
		size_t chunk = min(n, sizeof(zero));
		udd_ring_write(rg, zero, chunk);
		n -= chunk;
	}
}

/* ---- exported route lock ---- */
bool usb_dac_direct_route_locked(void)
{
	return atomic_read(&udd_enabled) != 0;
}
EXPORT_SYMBOL_GPL(usb_dac_direct_route_locked);

/* ---- ALSA helpers: find card / set controls ---- */
static struct snd_card *udd_find_card(const char *needle)
{
	int i;

	for (i = 0; i < SNDRV_CARDS; i++) {
		struct snd_card *c = snd_cards[i];

		if (!c)
			continue;
		/* id/driver/shortname/longname are char[] on this kernel */
		if (strstr(c->id, needle) || strstr(c->driver, needle) ||
		    strstr(c->shortname, needle) || strstr(c->longname, needle))
			return c;
	}
	return NULL;
}

static int udd_find_card_idx(const char *needle)
{
	int i;

	for (i = 0; i < SNDRV_CARDS; i++) {
		struct snd_card *c = snd_cards[i];

		if (!c)
			continue;
		if (strstr(c->id, needle) || strstr(c->driver, needle) ||
		    strstr(c->shortname, needle) || strstr(c->longname, needle))
			return i;
	}
	return -1;
}

static struct snd_kcontrol *udd_find_kctl(struct snd_card *card, const char *name)
{
	struct snd_ctl_elem_id id;

	memset(&id, 0, sizeof(id));
	id.iface = SNDRV_CTL_ELEM_IFACE_MIXER;
	strlcpy(id.name, name, sizeof(id.name));
	return snd_ctl_find_id(card, &id);
}

static int udd_set_int(struct snd_card *card, const char *name, long v0, long v1)
{
	struct snd_kcontrol *kctl;
	struct snd_ctl_elem_value val;
	int ret;

	kctl = udd_find_kctl(card, name);
	if (!kctl)
		return -ENOENT;
	memset(&val, 0, sizeof(val));
	val.id = kctl->id;
	val.value.integer.value[0] = v0;
	val.value.integer.value[1] = v1;
	/* No snd_ctl_notify — wakes AF into the same card lock we hold. */
	ret = kctl->put(kctl, &val);
	return ret < 0 ? ret : 0;
}

static int udd_set_enum(struct snd_card *card, const char *name, const char *item)
{
	struct snd_kcontrol *kctl;
	struct snd_ctl_elem_info info;
	struct snd_ctl_elem_value val;
	unsigned int i;
	int ret;

	kctl = udd_find_kctl(card, name);
	if (!kctl)
		return -ENOENT;

	memset(&info, 0, sizeof(info));
	info.id = kctl->id;
	ret = kctl->info(kctl, &info);
	if (ret < 0)
		return ret;

	for (i = 0; i < info.value.enumerated.items; i++) {
		info.value.enumerated.item = i;
		kctl->info(kctl, &info);
		if (!strcmp(info.value.enumerated.name, item))
			break;
	}
	if (i >= info.value.enumerated.items)
		return -EINVAL;

	memset(&val, 0, sizeof(val));
	val.id = kctl->id;
	val.value.enumerated.item[0] = i;
	ret = kctl->put(kctl, &val);
	return ret < 0 ? ret : 0;
}

static void udd_set_hph_volumes(struct snd_card *card, int vol)
{
	if (!card)
		return;
	if (vol < UDD_HPH_MIN)
		vol = UDD_HPH_MIN;
	if (vol > UDD_HPH_MAX)
		vol = UDD_HPH_MAX;
	udd_set_int(card, "HPHL Volume", vol, vol);
	udd_set_int(card, "HPHR Volume", vol, vol);
}

/* Safe: FE mixer only. DAPM here is unavoidable for sound, but single put. */
static int udd_apply_fe(struct snd_card *card, int on)
{
	int ret;

	if (!card)
		return -ENODEV;
	ret = udd_set_int(card, "SLIMBUS_6_RX Audio Mixer MultiMedia1",
			  on ? 1 : 0, on ? 1 : 0);
	pr_info(UDD_NAME ": FE MM1→SLIM6 %s ret=%d\n", on ? "on" : "off", ret);
	return ret;
}

/*
 * Optional heavy route — OFF by default. ESS / HPH Mode / many ENUMs have
 * frozen judyln when called from this driver concurrent with audioserver.
 */
static int udd_apply_codec_route(struct snd_card *card)
{
	int ok = 0, fail = 0;
	int hph = atomic_read(&udd_hph_vol);
	int dig = (UDD_RX_DIG_DEFAULT * atomic_read(&udd_gain)) / 100;

	if (!card)
		return -ENODEV;
	if (dig < 0)
		dig = 0;
	if (dig > 124)
		dig = 124;

#define TRY(expr) do { if ((expr) == 0) ok++; else fail++; } while (0)

	TRY(udd_set_enum(card, "SLIM RX0 MUX", "AIF4_PB"));
	TRY(udd_set_enum(card, "SLIM RX1 MUX", "AIF4_PB"));
	udd_set_enum(card, "SLIM RX2 MUX", "ZERO");
	udd_set_enum(card, "SLIM RX3 MUX", "ZERO");
	udd_set_enum(card, "CDC_IF RX0 MUX", "SLIM RX0");
	udd_set_enum(card, "CDC_IF RX1 MUX", "SLIM RX1");
	udd_set_enum(card, "RX INT1_2 MUX", "ZERO");
	udd_set_enum(card, "RX INT2_2 MUX", "ZERO");
	TRY(udd_set_enum(card, "RX INT1_1 MIX1 INP0", "RX0"));
	TRY(udd_set_enum(card, "RX INT2_1 MIX1 INP0", "RX1"));
	TRY(udd_set_enum(card, "RX INT1_1 INTERP", "RX INT1_1 MIX1"));
	TRY(udd_set_enum(card, "RX INT2_1 INTERP", "RX INT2_1 MIX1"));
	udd_set_hph_volumes(card, hph);
	udd_set_int(card, "RX0 Digital Volume", dig, dig);
	udd_set_int(card, "RX1 Digital Volume", dig, dig);
	/* Intentionally skip Es9218 / Es9018 / RX HPH Mode — OEM I2C wedges. */

#undef TRY
	pr_info(UDD_NAME ": codec_route ok=%d fail=%d\n", ok, fail);
	atomic_set(&udd_route_ok, (ok >= 4) ? 1 : 0);
	return (ok >= 4) ? 0 : -EIO;
}

static void udd_teardown_route(struct snd_card *card)
{
	if (!card)
		return;
	/* Only clear FE if we set it; otherwise leave for AF recovery. */
	if (do_fe_route)
		udd_apply_fe(card, 0);
}

/* ---- hw_param helper (local copy, not exported by ALSA) ---- */
static int udd_interval_refine_set(struct snd_interval *i, unsigned int val)
{
	struct snd_interval t;

	t.empty = 0;
	t.min = t.max = val;
	t.openmin = t.openmax = 0;
	t.integer = 1;
	return snd_interval_refine(i, &t);
}

static int udd_hw_param_set(struct snd_pcm_hw_params *params,
			    snd_pcm_hw_param_t var, unsigned int val)
{
	int changed;

	if (hw_is_mask(var)) {
		changed = snd_mask_refine_set(hw_param_mask(params, var), val);
	} else if (hw_is_interval(var)) {
		changed = udd_interval_refine_set(hw_param_interval(params, var), val);
	} else {
		return -EINVAL;
	}
	if (changed) {
		params->cmask |= 1 << var;
		params->rmask |= 1 << var;
	}
	return changed;
}

static int udd_setup_hw(struct snd_pcm_substream *substream,
			snd_pcm_format_t format, unsigned int rate,
			unsigned int channels, unsigned int period_frames,
			unsigned int periods)
{
	struct snd_pcm_hw_params *params;
	struct snd_pcm_sw_params *sw;
	int ret;

	params = kzalloc(sizeof(*params), GFP_KERNEL);
	if (!params)
		return -ENOMEM;

	_snd_pcm_hw_params_any(params);
	udd_hw_param_set(params, SNDRV_PCM_HW_PARAM_ACCESS,
			 SNDRV_PCM_ACCESS_RW_INTERLEAVED);
	udd_hw_param_set(params, SNDRV_PCM_HW_PARAM_FORMAT, format);
	udd_hw_param_set(params, SNDRV_PCM_HW_PARAM_CHANNELS, channels);
	udd_hw_param_set(params, SNDRV_PCM_HW_PARAM_RATE, rate);
	udd_hw_param_set(params, SNDRV_PCM_HW_PARAM_PERIOD_SIZE, period_frames);
	udd_hw_param_set(params, SNDRV_PCM_HW_PARAM_PERIODS, periods);

	snd_pcm_kernel_ioctl(substream, SNDRV_PCM_IOCTL_DROP, NULL);
	ret = snd_pcm_kernel_ioctl(substream, SNDRV_PCM_IOCTL_HW_PARAMS, params);
	if (ret < 0) {
		pr_err(UDD_NAME ": HW_PARAMS failed %d\n", ret);
		kfree(params);
		return ret;
	}

	sw = kzalloc(sizeof(*sw), GFP_KERNEL);
	if (!sw) {
		kfree(params);
		return -ENOMEM;
	}
	sw->tstamp_mode = SNDRV_PCM_TSTAMP_NONE;
	sw->period_step = 1;
	sw->avail_min = period_frames;
	sw->start_threshold = substream->stream == SNDRV_PCM_STREAM_PLAYBACK ?
		period_frames * 2 : 1;
	/* Use explicit silence writes; recover a real XRUN with PREPARE. */
	sw->stop_threshold = substream->runtime->buffer_size;
	sw->silence_threshold = 0;
	sw->silence_size = 0;
	ret = snd_pcm_kernel_ioctl(substream, SNDRV_PCM_IOCTL_SW_PARAMS, sw);
	kfree(sw);
	if (ret < 0) {
		pr_err(UDD_NAME ": SW_PARAMS failed %d\n", ret);
		kfree(params);
		return ret;
	}

	ret = snd_pcm_kernel_ioctl(substream, SNDRV_PCM_IOCTL_PREPARE, NULL);
	kfree(params);
	return ret;
}

struct udd_pcm {
	struct file *filp;
	struct snd_pcm_substream *substream;
	snd_pcm_format_t format;
	unsigned int frame_bytes;
	unsigned int period_frames;
};

static int udd_open_pcm(struct udd_pcm *p, int card, int device, int stream,
			snd_pcm_format_t format, unsigned int period_frames,
			unsigned int periods)
{
	char path[64];
	struct snd_pcm_file *pcm_file;
	int ret;

	snprintf(path, sizeof(path), "/dev/snd/pcmC%dD%d%c",
		 card, device, stream == SNDRV_PCM_STREAM_CAPTURE ? 'c' : 'p');

	p->filp = filp_open(path,
			    stream == SNDRV_PCM_STREAM_CAPTURE ? O_RDONLY : O_WRONLY,
			    0);
	if (IS_ERR(p->filp)) {
		ret = PTR_ERR(p->filp);
		p->filp = NULL;
		pr_err(UDD_NAME ": open %s failed %d\n", path, ret);
		return ret;
	}
	pcm_file = p->filp->private_data;
	if (!pcm_file || !pcm_file->substream) {
		filp_close(p->filp, NULL);
		p->filp = NULL;
		return -ENODEV;
	}
	p->substream = pcm_file->substream;
	p->format = format;
	p->period_frames = period_frames;
	p->frame_bytes = (snd_pcm_format_physical_width(format) / 8) * UDD_CH;

	ret = udd_setup_hw(p->substream, format, UDD_RATE, UDD_CH,
			   period_frames, periods);
	if (ret < 0) {
		filp_close(p->filp, NULL);
		p->filp = NULL;
		p->substream = NULL;
		return ret;
	}
	pr_info(UDD_NAME ": opened %s fmt=%d period=%u\n", path, (int)format,
		period_frames);
	return 0;
}

static void udd_close_pcm(struct udd_pcm *p)
{
	if (p->filp) {
		filp_close(p->filp, NULL);
		p->filp = NULL;
	}
	p->substream = NULL;
}

static snd_pcm_sframes_t udd_pcm_read(struct udd_pcm *p, void *buf,
				      snd_pcm_uframes_t frames)
{
	mm_segment_t old;
	snd_pcm_sframes_t r;

	old = get_fs();
	set_fs(KERNEL_DS);
	r = snd_pcm_lib_read(p->substream, (void __user *)buf, frames);
	set_fs(old);
	return r;
}

static snd_pcm_sframes_t udd_pcm_write(struct udd_pcm *p, void *buf,
				       snd_pcm_uframes_t frames)
{
	mm_segment_t old;
	snd_pcm_sframes_t r;

	old = get_fs();
	set_fs(KERNEL_DS);
	r = snd_pcm_lib_write(p->substream, (void __user *)buf, frames);
	set_fs(old);
	return r;
}

/* ---- format convert (s16 <-> s24_3le <-> s32) ---- */
static void udd_convert_frame(const u8 *in, snd_pcm_format_t cin,
			      u8 *out, snd_pcm_format_t cout, unsigned ch)
{
	s32 s[8];
	unsigned i;

	if (ch > 8)
		ch = 8;
	for (i = 0; i < ch; i++) {
		if (cin == SNDRV_PCM_FORMAT_S16_LE) {
			s16 v;

			memcpy(&v, in + i * 2, 2);
			s[i] = (s32)v << 16;
		} else if (cin == SNDRV_PCM_FORMAT_S24_3LE) {
			u8 b0 = in[i * 3], b1 = in[i * 3 + 1], b2 = in[i * 3 + 2];
			s32 v = (s32)((b2 << 24) | (b1 << 16) | (b0 << 8));

			s[i] = v;
		} else if (cin == SNDRV_PCM_FORMAT_S24_LE ||
			   cin == SNDRV_PCM_FORMAT_S32_LE) {
			s32 v;

			memcpy(&v, in + i * 4, 4);
			s[i] = (cin == SNDRV_PCM_FORMAT_S24_LE) ? (v << 8) : v;
		} else {
			s[i] = 0;
		}
	}
	for (i = 0; i < ch; i++) {
		if (cout == SNDRV_PCM_FORMAT_S16_LE) {
			s16 v = (s16)(s[i] >> 16);

			memcpy(out + i * 2, &v, 2);
		} else if (cout == SNDRV_PCM_FORMAT_S24_3LE) {
			u32 u = (u32)s[i];

			out[i * 3] = (u8)(u >> 8);
			out[i * 3 + 1] = (u8)(u >> 16);
			out[i * 3 + 2] = (u8)(u >> 24);
		} else {
			s32 v = (cout == SNDRV_PCM_FORMAT_S24_LE) ? (s[i] >> 8) : s[i];

			memcpy(out + i * 4, &v, 4);
		}
	}
}

/* Scale one signed PCM sample in the negotiated output format. */
static void udd_scale_sample(u8 *p, snd_pcm_format_t fmt, s32 gain,
			     s32 divisor)
{
	if (fmt == SNDRV_PCM_FORMAT_S16_LE) {
		s16 v;

		memcpy(&v, p, sizeof(v));
		v = (s16)((s32)v * gain / divisor);
		memcpy(p, &v, sizeof(v));
	} else if (fmt == SNDRV_PCM_FORMAT_S24_3LE) {
		s32 v = (s32)((p[2] << 24) | (p[1] << 16) | (p[0] << 8));
		u32 u;

		v = v * gain / divisor;
		u = (u32)v;
		p[0] = u >> 8;
		p[1] = u >> 16;
		p[2] = u >> 24;
	} else {
		s32 v;

		memcpy(&v, p, sizeof(v));
		v = v * gain / divisor;
		memcpy(p, &v, sizeof(v));
	}
}

static void udd_ramp_audio(u8 *buf, snd_pcm_format_t fmt,
			   unsigned int frame_bytes, size_t first,
			   size_t count, size_t total, bool fade_in)
{
	size_t f;
	unsigned int ch;
	unsigned int sample_bytes = frame_bytes / UDD_CH;

	if (!count || !total)
		return;
	for (f = first; f < first + count; f++) {
		s32 gain = fade_in ? f - first + 1 : total - (f - first) - 1;

		for (ch = 0; ch < UDD_CH; ch++)
			udd_scale_sample(buf + f * frame_bytes + ch * sample_bytes,
					 fmt, gain, total);
	}
}

static struct udd_pcm udd_cap;
static struct udd_pcm udd_play;
static struct snd_card *udd_play_card;

static void udd_thread_rt(int prio)
{
	struct sched_param sp = { .sched_priority = prio };

	sched_setscheduler_nocheck(current, SCHED_FIFO, &sp);
}

static int udd_cap_thread(void *data)
{
	size_t nbytes = (size_t)udd_cap.period_frames * udd_cap.frame_bytes;
	u8 *buf = kmalloc(nbytes, GFP_KERNEL);

	(void)data;
	if (!buf)
		return -ENOMEM;
	udd_thread_rt(UDD_CAP_RT_PRIO);

	while (!kthread_should_stop() && !atomic_read(&udd_stop)) {
		snd_pcm_sframes_t r = udd_pcm_read(&udd_cap, buf,
						  udd_cap.period_frames);

		if (r == -EPIPE || r == -ESTRPIPE) {
			udd_xrun_cap++;
			snd_pcm_kernel_ioctl(udd_cap.substream,
					     SNDRV_PCM_IOCTL_PREPARE, NULL);
			continue;
		}
		if (r <= 0) {
			usleep_range(200, 400);
			continue;
		}
		udd_ring_write(&udd_ring, buf, (size_t)r * udd_cap.frame_bytes);
		udd_frames_cap += (u64)r;
	}
	kfree(buf);
	return 0;
}

static int udd_play_thread(void *data)
{
	size_t cap_need = (size_t)udd_play.period_frames * udd_cap.frame_bytes;
	size_t play_bytes = (size_t)udd_play.period_frames * udd_play.frame_bytes;
	u8 *capbuf = kmalloc(cap_need, GFP_KERNEL);
	u8 *playbuf = kmalloc(play_bytes, GFP_KERNEL);
	size_t prebuf = (UDD_RATE * UDD_PREBUF_MS / 1000) * udd_cap.frame_bytes;
	size_t fb = udd_cap.frame_bytes;
	unsigned long last_drift = jiffies;
	unsigned long last_slip = jiffies;
	unsigned long last_xrun_log = 0;
	bool audio_active = false;
	bool starved = false;

	(void)data;
	if (!capbuf || !playbuf) {
		kfree(capbuf);
		kfree(playbuf);
		return -ENOMEM;
	}
	/* Play must outrank cap — otherwise ring fills while ALSA underruns. */
	udd_thread_rt(UDD_PLAY_RT_PRIO);

	while (!kthread_should_stop() && !atomic_read(&udd_stop) &&
	       udd_ring_avail(&udd_ring) < prebuf)
		msleep(2);

	pr_info(UDD_NAME ": play start prebuf=%zu cap_fmt=%d play_fmt=%d\n",
		udd_ring_avail(&udd_ring), (int)udd_cap.format,
		(int)udd_play.format);

	while (!kthread_should_stop() && !atomic_read(&udd_stop)) {
		size_t got, frames, i;
		snd_pcm_sframes_t w;

		/* PCM writes provide pacing. Never wait for USB data while the
		 * playback DMA is running: a host pause must produce silence.
		 */
		frames = 0;
		if (starved && udd_ring_avail(&udd_ring) >= prebuf)
			starved = false;
		if (!starved) {
			got = udd_ring_read(&udd_ring, capbuf, cap_need, 0);
			frames = UDD_FRAME_ALIGN(got, fb) / fb;
			if (frames < udd_play.period_frames) {
				udd_ring_underruns++;
				starved = true;
			}
		}

		memset(playbuf, 0, play_bytes);
		if (frames > 0) {
			if (udd_cap.format == udd_play.format &&
			    udd_cap.frame_bytes == udd_play.frame_bytes) {
				memcpy(playbuf, capbuf,
				       frames * udd_play.frame_bytes);
			} else {
				for (i = 0; i < frames; i++) {
					u8 fin[16], fout[16];

					memcpy(fin, capbuf + i * fb, fb);
					udd_convert_frame(fin, udd_cap.format, fout,
							  udd_play.format, UDD_CH);
					memcpy(playbuf + i * udd_play.frame_bytes, fout,
					       udd_play.frame_bytes);
				}
			}
		}
		/* A partial USB period is a discontinuity. Fade the valid tail;
		 * when data resumes, fade its head for every supported PCM format.
		 */
		{
			size_t ramp_frames = min_t(size_t,
						   udd_play.period_frames, 96);

			if (frames && !audio_active)
				udd_ramp_audio(playbuf, udd_play.format,
						udd_play.frame_bytes, 0,
						min(frames, ramp_frames),
						ramp_frames, true);
			if (frames && starved &&
			    frames < udd_play.period_frames) {
				size_t n = min(frames, ramp_frames);

				udd_ramp_audio(playbuf, udd_play.format,
						udd_play.frame_bytes, frames - n,
						n, n, false);
			}
		}
		/* A gap always breaks continuity, including one that refills
		 * immediately on the next period.
		 */
		audio_active = frames == udd_play.period_frames && !starved;

		/* All blocks, including refill silence, share error recovery.
		 * Preserve a short write's remaining samples before reading again.
		 */
		for (i = 0; i < udd_play.period_frames; ) {
			if (kthread_should_stop() || atomic_read(&udd_stop))
				break;
			w = udd_pcm_write(&udd_play,
				playbuf + i * udd_play.frame_bytes,
				udd_play.period_frames - i);
			if (w > 0) {
				i += w;
				udd_frames_play += (u64)w;
				continue;
			}
			if (w == -EPIPE || w == -ESTRPIPE) {
				int ret;

				udd_xrun_play++;
				ret = snd_pcm_kernel_ioctl(udd_play.substream,
						SNDRV_PCM_IOCTL_PREPARE, NULL);
				if (time_after(jiffies, last_xrun_log + HZ)) {
					pr_warn(UDD_NAME ": play xrun=%llu prepare=%d\n",
						udd_xrun_play, ret);
					last_xrun_log = jiffies;
				}
				starved = true;
				audio_active = false;
			}
			/* An error must yield even under SCHED_FIFO. */
			usleep_range(1000, 2000);
			break;
		}

		/*
		 * Correct the independent USB and AFE clocks from queue depth. The old
		 * cumulative-frame comparison included the 80 ms startup prebuffer,
		 * then discarded 5 ms of audio once per second to "correct" that fixed
		 * offset. That caused a periodic audible skip during otherwise healthy
		 * long playback.
		 */
		if (!starved && audio_active &&
		    (udd_xrun_play == 0 ||
		     time_after(jiffies, last_xrun_log + 2 * HZ))) {
			if (time_after(jiffies, last_drift +
					msecs_to_jiffies(UDD_DRIFT_CHECK_MS))) {
				s64 queued = (s64)(udd_ring_avail(&udd_ring) / fb);
				s64 target = UDD_RATE * UDD_PREBUF_MS / 1000;
				s64 skew = queued - target;
				unsigned long slip = msecs_to_jiffies(UDD_DRIFT_SLIP_MS);
				last_drift = jiffies;

				if (time_after(jiffies, last_slip + slip) &&
				    skew > (s64)(UDD_RATE * UDD_DRIFT_LIMIT_MS / 1000)) {
					udd_ring_drop(&udd_ring, fb);
					udd_drift_drops++;
					last_slip = jiffies;
				} else if (time_after(jiffies, last_slip + slip) &&
					   skew < -(s64)(UDD_RATE * UDD_DRIFT_LIMIT_MS / 1000)) {
					udd_ring_insert_silence(&udd_ring, fb);
					udd_drift_inserts++;
					last_slip = jiffies;
				}
			}
		}
	}
	kfree(capbuf);
	kfree(playbuf);
	return 0;
}

/* ---- volume key filter (opt-in; never attach power-combo nodes) ---- */
static void udd_vol_apply_work(struct work_struct *work)
{
	struct snd_card *card;
	int vol;

	(void)work;
	if (!atomic_read(&udd_enabled))
		return;
	vol = atomic_read(&udd_hph_vol);
	card = udd_play_card;
	if (card)
		udd_set_hph_volumes(card, vol);
}

static DECLARE_WORK(udd_vol_work, udd_vol_apply_work);

static bool udd_vol_filter(struct input_handle *handle, unsigned int type,
			   unsigned int code, int value)
{
	int vol;

	(void)handle;
	if (!atomic_read(&udd_enabled))
		return false;
	if (type != EV_KEY)
		return false;
	if (code != KEY_VOLUMEUP && code != KEY_VOLUMEDOWN)
		return false;

	/* Never mixer-put from input path — softirq vs card lock = freeze. */
	if (value == 1) {
		vol = atomic_read(&udd_hph_vol);
		if (code == KEY_VOLUMEUP)
			vol += UDD_HPH_STEP;
		else
			vol -= UDD_HPH_STEP;
		if (vol < UDD_HPH_MIN)
			vol = UDD_HPH_MIN;
		if (vol > UDD_HPH_MAX)
			vol = UDD_HPH_MAX;
		atomic_set(&udd_hph_vol, vol);
		atomic_set(&udd_vol_pending, 1);
		if (udd_wq_sys)
			queue_work(udd_wq_sys, &udd_vol_work);
	}
	return true;
}

static bool udd_dev_has_powerish(struct input_dev *dev)
{
	return test_bit(KEY_POWER, dev->keybit) ||
	       test_bit(KEY_POWER2, dev->keybit) ||
	       test_bit(KEY_SLEEP, dev->keybit) ||
	       test_bit(KEY_SUSPEND, dev->keybit) ||
	       test_bit(KEY_WAKEUP, dev->keybit) ||
	       test_bit(KEY_HOMEPAGE, dev->keybit) ||
	       test_bit(KEY_HOME, dev->keybit);
}

static int udd_vol_connect(struct input_handler *handler, struct input_dev *dev,
			   const struct input_device_id *id)
{
	struct input_handle *handle;
	int err;

	(void)id;
	if (!test_bit(EV_KEY, dev->evbit))
		return -ENODEV;
	if (!test_bit(KEY_VOLUMEUP, dev->keybit) &&
	    !test_bit(KEY_VOLUMEDOWN, dev->keybit))
		return -ENODEV;
	/*
	 * judyln: qpnp_pon = Vol- + POWER. Attaching ANY handler that opens
	 * that node has hard-frozen the phone. Skip entirely.
	 */
	if (udd_dev_has_powerish(dev)) {
		pr_info(UDD_NAME ": skip input '%s' (power combo)\n",
			dev->name ? dev->name : "?");
		return -ENODEV;
	}

	handle = kzalloc(sizeof(*handle), GFP_KERNEL);
	if (!handle)
		return -ENOMEM;
	handle->dev = dev;
	handle->handler = handler;
	handle->name = UDD_NAME;
	err = input_register_handle(handle);
	if (err)
		goto err_free;
	err = input_open_device(handle);
	if (err)
		goto err_unreg;
	pr_info(UDD_NAME ": volkeys on '%s'\n",
		dev->name ? dev->name : "?");
	return 0;
err_unreg:
	input_unregister_handle(handle);
err_free:
	kfree(handle);
	return err;
}

static void udd_vol_disconnect(struct input_handle *handle)
{
	input_close_device(handle);
	input_unregister_handle(handle);
	kfree(handle);
}

static const struct input_device_id udd_vol_ids[] = {
	{
		.flags = INPUT_DEVICE_ID_MATCH_EVBIT,
		.evbit = { BIT_MASK(EV_KEY) },
	},
	{ },
};

static struct input_handler udd_vol_handler = {
	.filter = udd_vol_filter,
	.connect = udd_vol_connect,
	.disconnect = udd_vol_disconnect,
	.name = UDD_NAME,
	.id_table = udd_vol_ids,
};

static bool udd_vol_registered;

/* ---- enable / disable ---- */
static int udd_try_open_play(int play_card)
{
	static const snd_pcm_format_t play_fmts[] = {
		SNDRV_PCM_FORMAT_S16_LE,
		SNDRV_PCM_FORMAT_S24_LE,
		SNDRV_PCM_FORMAT_S24_3LE,
		SNDRV_PCM_FORMAT_S32_LE,
	};
	/* After Mode B, AF may leave BE picky — try several period layouts. */
	static const unsigned int periods_try[] = { 8, 4, 16 };
	/* Prefer 10ms latency; retain 20/40ms fallbacks for picky backends. */
	static const unsigned int period_ms_try[] = { 10, 20, 40 };
	int fi, pi, qi;

	for (qi = 0; qi < ARRAY_SIZE(period_ms_try); qi++) {
		unsigned int period = UDD_RATE * period_ms_try[qi] / 1000;

		if (period < 160)
			period = 160;
		for (pi = 0; pi < ARRAY_SIZE(periods_try); pi++) {
			for (fi = 0; fi < ARRAY_SIZE(play_fmts); fi++) {
				if (udd_open_pcm(&udd_play, play_card, 0,
						 SNDRV_PCM_STREAM_PLAYBACK,
						 play_fmts[fi], period,
						 periods_try[pi]) == 0) {
					pr_info(UDD_NAME
						": play OK fmt=%d period=%u n=%u\n",
						(int)play_fmts[fi], period,
						periods_try[pi]);
					return 0;
				}
			}
		}
	}
	return -EIO;
}

static int udd_try_open_cap(int uac_card)
{
	static const snd_pcm_format_t cap_fmts[] = {
		SNDRV_PCM_FORMAT_S16_LE,
		SNDRV_PCM_FORMAT_S24_3LE,
		SNDRV_PCM_FORMAT_S24_LE,
		SNDRV_PCM_FORMAT_S32_LE,
	};
	unsigned int period = udd_play.period_frames ?
			      udd_play.period_frames :
			      (UDD_RATE * UDD_PERIOD_MS / 1000);
	int i;

	for (i = 0; i < ARRAY_SIZE(cap_fmts); i++) {
		if (udd_open_pcm(&udd_cap, uac_card, 0,
				 SNDRV_PCM_STREAM_CAPTURE, cap_fmts[i],
				 period, UDD_CAP_PERIODS) == 0)
			return 0;
	}
	return -EIO;
}

static void udd_stop_bridge(void)
{
	atomic_set(&udd_stop, 1);
	/* Must not wake uninitialized waitqueue (BSS-zero → panic in __wake_up). */
	udd_ring_wake(&udd_ring);

	if (udd_cap_task) {
		kthread_stop(udd_cap_task);
		udd_cap_task = NULL;
	}
	if (udd_play_task) {
		kthread_stop(udd_play_task);
		udd_play_task = NULL;
	}
	udd_close_pcm(&udd_cap);
	udd_close_pcm(&udd_play);
	udd_ring_free(&udd_ring);
}

static int udd_start_bridge(void)
{
	int uac, play;
	size_t ring_bytes;
	unsigned int period = UDD_RATE * UDD_PERIOD_MS / 1000;
	int ret, try;

	uac = udd_find_card_idx("UAC2");
	if (uac < 0)
		uac = udd_find_card_idx("uac2");
	if (uac < 0)
		uac = udd_find_card_idx("Gadget");
	play = udd_find_card_idx("tavil");
	if (play < 0)
		play = udd_find_card_idx("sdm845");

	if (uac < 0 || play < 0) {
		snprintf(udd_status_msg, sizeof(udd_status_msg),
			 "no cards uac=%d play=%d", uac, play);
		pr_err(UDD_NAME ": %s\n", udd_status_msg);
		return -ENODEV;
	}

	udd_play_card = snd_cards[play];

	/*
	 * Freeze-safe: NO mixer puts here by default.
	 * Open MM1 FIRST (after Mode B AF may hold BE — don't hold UAC during
	 * long play retries; that left gadget PREPARED and timed out WebUI).
	 */
	if (do_codec_route)
		udd_apply_codec_route(udd_play_card);
	if (do_fe_route) {
		snprintf(udd_status_msg, sizeof(udd_status_msg), "fe before open");
		if (udd_apply_fe(udd_play_card, 1) == 0)
			atomic_set(&udd_route_ok, 1);
	} else {
		atomic_set(&udd_route_ok, 1);
	}

	snprintf(udd_status_msg, sizeof(udd_status_msg), "open play=%d", play);
	ret = -EBUSY;
	for (try = 0; try < 10; try++) {
		if (atomic_read(&udd_want) == 0)
			return -ECANCELED;
		ret = udd_try_open_play(play);
		if (ret == 0)
			break;
		pr_warn(UDD_NAME ": play open try %d: %d\n", try, ret);
		snprintf(udd_status_msg, sizeof(udd_status_msg),
			 "open play=%d try=%d err=%d", play, try, ret);
		msleep(100 + try * 80);
	}
	if (ret) {
		snprintf(udd_status_msg, sizeof(udd_status_msg),
			 "play open fail %d", ret);
		return ret;
	}

	snprintf(udd_status_msg, sizeof(udd_status_msg), "open uac=%d", uac);
	ret = udd_try_open_cap(uac);
	if (ret) {
		udd_close_pcm(&udd_play);
		snprintf(udd_status_msg, sizeof(udd_status_msg),
			 "cap open fail %d", ret);
		return ret;
	}

	{
		unsigned int pms = udd_play.period_frames ?
			(udd_play.period_frames * 1000 / UDD_RATE) : UDD_PERIOD_MS;

		if (pms < 1)
			pms = UDD_PERIOD_MS;
		ring_bytes = (size_t)udd_play.period_frames * udd_cap.frame_bytes *
			     (UDD_RING_MS / pms);
		if (ring_bytes < 8192)
			ring_bytes = 8192;
	}
	(void)period;
	ret = udd_ring_init(&udd_ring, ring_bytes);
	if (ret) {
		udd_close_pcm(&udd_cap);
		udd_close_pcm(&udd_play);
		return ret;
	}

	udd_frames_cap = udd_frames_play = 0;
	udd_xrun_cap = udd_xrun_play = 0;
	udd_drift_drops = udd_drift_inserts = 0;
	udd_ring_underruns = 0;
	atomic_set(&udd_stop, 0);

	udd_cap_task = kthread_run(udd_cap_thread, NULL, "usb_dac_cap");
	if (IS_ERR(udd_cap_task)) {
		ret = PTR_ERR(udd_cap_task);
		udd_cap_task = NULL;
		goto fail;
	}
	udd_play_task = kthread_run(udd_play_thread, NULL, "usb_dac_play");
	if (IS_ERR(udd_play_task)) {
		ret = PTR_ERR(udd_play_task);
		udd_play_task = NULL;
		atomic_set(&udd_stop, 1);
		udd_ring_wake(&udd_ring);
		kthread_stop(udd_cap_task);
		udd_cap_task = NULL;
		goto fail;
	}

	snprintf(udd_status_msg, sizeof(udd_status_msg),
		 "live uac=%d play=%d", uac, play);
	pr_info(UDD_NAME ": bridge live %s\n", udd_status_msg);
	return 0;
fail:
	udd_close_pcm(&udd_cap);
	udd_close_pcm(&udd_play);
	udd_ring_free(&udd_ring);
	atomic_set(&udd_stop, 1);
	return ret;
}

static int udd_enable(void)
{
	int ret;

	if (!boot_enable) {
		pr_warn(UDD_NAME ": blocked by boot param enable=0\n");
		return -EPERM;
	}
	if (atomic_read(&udd_enabled))
		return 0;

	ret = udd_start_bridge();
	if (ret) {
		snprintf(udd_status_msg, sizeof(udd_status_msg),
			 "start failed %d", ret);
		return ret;
	}
	atomic_set(&udd_enabled, 1);

	/* Apply HPH once after PCM is up (volume put is light vs DAPM MUX). */
	if (udd_play_card)
		udd_set_hph_volumes(udd_play_card, atomic_read(&udd_hph_vol));

	if (do_volkeys && !udd_vol_registered) {
		ret = input_register_handler(&udd_vol_handler);
		if (ret)
			pr_warn(UDD_NAME ": input handler %d\n", ret);
		else
			udd_vol_registered = true;
	}
	return 0;
}

static void udd_disable(void)
{
	if (!atomic_read(&udd_enabled) && atomic_read(&udd_stop)) {
		/* still allow stop if partially started */
	}
	atomic_set(&udd_enabled, 0);
	udd_stop_bridge();
	if (udd_play_card)
		udd_teardown_route(udd_play_card);
	udd_play_card = NULL;
	atomic_set(&udd_route_ok, 0);
	snprintf(udd_status_msg, sizeof(udd_status_msg), "disabled");
}

/* ---- sysfs (never run mixer/PCM in store context — schedules work) ---- */
static void udd_requeue_fn(struct work_struct *work)
{
	(void)work;
	if (udd_wq_sys)
		queue_work(udd_wq_sys, &udd_work);
}

static void udd_work_fn(struct work_struct *work)
{
	int want = atomic_read(&udd_want);

	(void)work;
	if (!mutex_trylock(&udd_lock)) {
		/* Do not spin — retry after 100ms */
		if (udd_wq_sys)
			queue_delayed_work(udd_wq_sys, &udd_requeue_work,
					   msecs_to_jiffies(100));
		return;
	}
	if (want) {
		if (!atomic_read(&udd_enabled)) {
			snprintf(udd_status_msg, sizeof(udd_status_msg),
				 "starting");
			if (udd_enable())
				pr_err(UDD_NAME ": enable work failed\n");
		}
	} else {
		udd_disable();
	}
	mutex_unlock(&udd_lock);
}

static ssize_t enable_show(struct kobject *kobj, struct kobj_attribute *attr,
			   char *buf)
{
	return sprintf(buf, "%d\n", atomic_read(&udd_enabled));
}

static ssize_t enable_store(struct kobject *kobj, struct kobj_attribute *attr,
			    const char *buf, size_t count)
{
	int val;

	if (kstrtoint(buf, 0, &val))
		return -EINVAL;
	if (val && !boot_enable) {
		pr_warn(UDD_NAME ": refused (param enable=0); userspace fallback\n");
		snprintf(udd_status_msg, sizeof(udd_status_msg),
			 "refused enable=0");
		return -EPERM;
	}
	atomic_set(&udd_want, val ? 1 : 0);
	snprintf(udd_status_msg, sizeof(udd_status_msg),
		 val ? "queued start" : "queued stop");
	if (udd_wq_sys)
		queue_work(udd_wq_sys, &udd_work);
	/* Return immediately so WebUI/ctl never block in DAPM */
	return count;
}

static ssize_t gain_show(struct kobject *kobj, struct kobj_attribute *attr,
			 char *buf)
{
	(void)kobj;
	(void)attr;
	return sprintf(buf, "%d\n", atomic_read(&udd_gain));
}

static ssize_t gain_store(struct kobject *kobj, struct kobj_attribute *attr,
			  const char *buf, size_t count)
{
	int val;

	(void)kobj;
	(void)attr;
	if (kstrtoint(buf, 0, &val))
		return -EINVAL;
	if (val < 0)
		val = 0;
	if (val > 150)
		val = 150;
	atomic_set(&udd_gain, val);
	return count;
}

static ssize_t hph_show(struct kobject *kobj, struct kobj_attribute *attr,
			char *buf)
{
	(void)kobj;
	(void)attr;
	return sprintf(buf, "%d\n", atomic_read(&udd_hph_vol));
}

static ssize_t hph_store(struct kobject *kobj, struct kobj_attribute *attr,
			 const char *buf, size_t count)
{
	int val;

	(void)kobj;
	(void)attr;
	if (kstrtoint(buf, 0, &val))
		return -EINVAL;
	if (val < UDD_HPH_MIN)
		val = UDD_HPH_MIN;
	if (val > UDD_HPH_MAX)
		val = UDD_HPH_MAX;
	atomic_set(&udd_hph_vol, val);
	/* Apply via workqueue — never mixer-put in sysfs context. */
	if (udd_wq_sys)
		queue_work(udd_wq_sys, &udd_vol_work);
	return count;
}

static ssize_t status_show(struct kobject *kobj, struct kobj_attribute *attr,
			   char *buf)
{
	return sprintf(buf,
		"enabled=%d\nroute_ok=%d\nmsg=%s\n"
		"frames_cap=%llu\nframes_play=%llu\n"
		"xrun_cap=%llu\nxrun_play=%llu\n"
		"drift_drops=%llu\ndrift_inserts=%llu\n"
		"ring_underruns=%llu\nring_overruns=%llu\nring_frames=%zu\n"
		"hph=%d\ngain=%d\n",
		atomic_read(&udd_enabled),
		atomic_read(&udd_route_ok),
		udd_status_msg,
		(unsigned long long)udd_frames_cap,
		(unsigned long long)udd_frames_play,
		(unsigned long long)udd_xrun_cap,
		(unsigned long long)udd_xrun_play,
		(unsigned long long)udd_drift_drops,
		(unsigned long long)udd_drift_inserts,
		(unsigned long long)udd_ring_underruns,
		(unsigned long long)udd_ring_overruns(&udd_ring),
		udd_ring_avail(&udd_ring) /
			(udd_cap.frame_bytes ? udd_cap.frame_bytes : 1),
		atomic_read(&udd_hph_vol),
		atomic_read(&udd_gain));
}

static struct kobj_attribute enable_attr =
	__ATTR(enable, 0644, enable_show, enable_store);
static struct kobj_attribute gain_attr =
	__ATTR(gain, 0644, gain_show, gain_store);
static struct kobj_attribute hph_attr =
	__ATTR(hph, 0644, hph_show, hph_store);
static struct kobj_attribute status_attr =
	__ATTR(status, 0444, status_show, NULL);

static struct attribute *udd_attrs[] = {
	&enable_attr.attr,
	&gain_attr.attr,
	&hph_attr.attr,
	&status_attr.attr,
	NULL,
};

static struct attribute_group udd_attr_group = {
	.attrs = udd_attrs,
};

static int __init udd_init(void)
{
	int ret;

	init_waitqueue_head(&udd_wq);
	/* Ring wq must be valid before any enable/disable work runs. */
	spin_lock_init(&udd_ring.lock);
	init_waitqueue_head(&udd_ring.wq);
	INIT_WORK(&udd_work, udd_work_fn);
	INIT_DELAYED_WORK(&udd_requeue_work, udd_requeue_fn);
	udd_wq_sys = alloc_ordered_workqueue("usb_dac_direct", WQ_MEM_RECLAIM);
	if (!udd_wq_sys)
		return -ENOMEM;
	udd_kobj = kobject_create_and_add(UDD_NAME, kernel_kobj);
	if (!udd_kobj) {
		destroy_workqueue(udd_wq_sys);
		udd_wq_sys = NULL;
		return -ENOMEM;
	}
	ret = sysfs_create_group(udd_kobj, &udd_attr_group);
	if (ret) {
		kobject_put(udd_kobj);
		destroy_workqueue(udd_wq_sys);
		udd_wq_sys = NULL;
		return ret;
	}
	pr_info(UDD_NAME ": ready armed=%d fe=%d codec=%d volkeys=%d\n",
		boot_enable, do_fe_route, do_codec_route, do_volkeys);
	return 0;
}

static void __exit udd_exit(void)
{
	atomic_set(&udd_want, 0);
	if (udd_wq_sys) {
		cancel_delayed_work_sync(&udd_requeue_work);
		cancel_work_sync(&udd_vol_work);
		cancel_work_sync(&udd_work);
		destroy_workqueue(udd_wq_sys);
		udd_wq_sys = NULL;
	}
	mutex_lock(&udd_lock);
	udd_disable();
	mutex_unlock(&udd_lock);
	if (udd_vol_registered) {
		input_unregister_handler(&udd_vol_handler);
		udd_vol_registered = false;
	}
	if (udd_kobj) {
		sysfs_remove_group(udd_kobj, &udd_attr_group);
		kobject_put(udd_kobj);
		udd_kobj = NULL;
	}
}

module_init(udd_init);
module_exit(udd_exit);

MODULE_DESCRIPTION("USB DAC Direct: UAC2 gadget to tavil MM1/SLIM6/ESS");
MODULE_AUTHOR("twtter");
MODULE_LICENSE("GPL v2");
