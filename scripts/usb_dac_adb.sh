#!/system/bin/sh
# USB DAC: mtp + adb + uac2 without fighting init.usb.configfs.rc
#
# Stock rules only know mtp,adb / adb / ... — after UDC bind they rewrite
# configs and delete f3. Fix: switch to a *custom* sys.usb.config value
# that has NO init rule (mtp,adb,uac2), and bind ourselves.
#
#   sh /sdcard/usb_dac_adb.sh           # background
#   sh /sdcard/usb_dac_adb.sh status
#   sh /sdcard/usb_dac_adb.sh unlock
#   sh /sdcard/usb_dac_adb.sh watch

G="${G:-/config/usb_gadget/g1}"
CFG="$G/configs/b.1"
LOG="${LOG:-/sdcard/usb_dac.log}"
LOCK="${LOCK:-/data/local/tmp/usb_dac.lock}"
# Must NOT match any on property: sys.usb.config=... in init*.rc
MYCFG="${MYCFG:-mtp,adb,uac2}"

CTRL="$(getprop sys.usb.controller)"
[ -n "$CTRL" ] || CTRL="$(ls /sys/class/udc 2>/dev/null | head -n1)"
UDC="${UDC:-$CTRL}"

log() { echo "usb_dac: $*" | tee -a "$LOG"; }
die() { log "ERROR: $*"; exit 1; }

status() {
	echo "config=$(getprop sys.usb.config) state=$(getprop sys.usb.state) ffs=$(getprop sys.usb.ffs.ready)"
	echo "UDC_file=$(cat "$G/UDC" 2>/dev/null) controller=$CTRL"
	echo "links:"; ls -la "$CFG" 2>/dev/null
	echo "alsa:"; cat /proc/asound/cards 2>/dev/null
	echo "log:"; tail -50 "$LOG" 2>/dev/null
}

clear_lock() { rm -f "$LOCK" 2>/dev/null || true; }

take_lock() {
	mkdir -p "$(dirname "$LOCK")" 2>/dev/null || true
	if [ -f "$LOCK" ]; then
		opid=$(cat "$LOCK" 2>/dev/null || true)
		[ -n "$opid" ] && [ -d "/proc/$opid" ] && die "another usb_dac pid=$opid — sh $0 unlock"
		rm -f "$LOCK"
	fi
	echo $$ >"$LOCK"
	trap 'rm -f "$LOCK"' EXIT HUP INT TERM
}


restore_stock() {
	log "restore stock mtp,adb"
	echo "" > "$G/UDC" 2>/dev/null || true
	sleep 1
	# wipe our links; init will recreate on setprop
	for n in "$CFG"/f[0-9] "$CFG"/f[0-9][0-9]; do
		[ -e "$n" ] || [ -L "$n" ] || continue
		rm -f "$n"
	done
	setprop sys.usb.ffs.ready 0 2>/dev/null || true
	stop adbd 2>/dev/null || true
	setprop sys.usb.config none
	sleep 2
	setprop sys.usb.config mtp,adb
	start adbd 2>/dev/null || true
	i=0
	while [ "$(getprop sys.usb.ffs.ready)" != "1" ] && [ "$i" -lt 20 ]; do sleep 1; i=$((i+1)); done
	# if still no UDC, force controller bind like init would
	if [ -z "$(cat "$G/UDC" 2>/dev/null)" ] && [ -n "$UDC" ]; then
		ln -s /config/usb_gadget/g1/functions/mtp.gs0 "$CFG/f1" 2>/dev/null || true
		ln -s /config/usb_gadget/g1/functions/ffs.adb "$CFG/f2" 2>/dev/null || true
		echo "$UDC" > "$G/UDC" 2>/dev/null || true
	fi
	setprop sys.usb.state mtp,adb
	log "config=$(getprop sys.usb.config) state=$(getprop sys.usb.state) UDC=$(cat "$G/UDC" 2>/dev/null)"
	echo "usb_dac: stock restore attempted — unplug/replug cable"
}

have_uac2_link() {
	for n in "$CFG"/*; do
		[ -L "$n" ] || continue
		case "$(readlink "$n" 2>/dev/null)" in *uac2*) return 0;; esac
	done
	return 1
}

wait_prop() {
	# wait_prop name want [max_sec]
	name=$1; want=$2; max=${3:-10}
	i=0
	while [ "$(getprop "$name")" != "$want" ] && [ "$i" -lt "$max" ]; do
		sleep 1
		i=$((i + 1))
	done
	[ "$(getprop "$name")" = "$want" ]
}

unbind_udc() {
	echo "" > "$G/UDC" 2>/dev/null || true
	sleep 1
}

setup_functions() {
	mkdir -p "$G/functions/uac2.0" || die "no uac2.0 (kernel?)"
	echo 0x3 > "$G/functions/uac2.0/p_chmask" 2>/dev/null || true
	echo 48000 > "$G/functions/uac2.0/p_srate" 2>/dev/null || true
	echo 2 > "$G/functions/uac2.0/p_ssize" 2>/dev/null || true
	echo 0x3 > "$G/functions/uac2.0/c_chmask" 2>/dev/null || true
	echo 48000 > "$G/functions/uac2.0/c_srate" 2>/dev/null || true
	echo 2 > "$G/functions/uac2.0/c_ssize" 2>/dev/null || true

	mkdir -p "$CFG/strings/0x409" 2>/dev/null || true
	echo "mtp_adb_uac2" > "$CFG/strings/0x409/configuration" 2>/dev/null || true

	# wipe config function links only
	for n in "$CFG"/f[0-9] "$CFG"/f[0-9][0-9] "$CFG"/mtp* "$CFG"/ffs* "$CFG"/uac*; do
		[ -e "$n" ] || [ -L "$n" ] || continue
		rm -f "$n"
	done

	# absolute symlinks (cwd-safe)
	ln -s /config/usb_gadget/g1/functions/mtp.gs0 "$CFG/f1" || die "f1"
	ln -s /config/usb_gadget/g1/functions/ffs.adb "$CFG/f2" || die "f2"
	ln -s /config/usb_gadget/g1/functions/uac2.0 "$CFG/f3" || die "f3"
	log "linked f1=mtp f2=adb f3=uac2"
	ls -la "$CFG" >>"$LOG"
}

apply_inner() {
	take_lock
	: >"$LOG"
	log "start want_config=$MYCFG udc=$UDC"

	[ -d "$G" ] || die "missing $G"
	[ -n "$UDC" ] || die "no UDC"

	# 1) drop stock composition so init finishes its teardown
	log "set config none"
	setprop sys.usb.ffs.ready 0 2>/dev/null || true
	setprop sys.usb.config none
	wait_prop sys.usb.state none 8 || log "WARN state!=none ($(getprop sys.usb.state))"
	unbind_udc
	stop adbd 2>/dev/null || true
	sleep 1

	# 2) build our composition while unbound
	setup_functions

	# 3) use custom config name BEFORE adbd/bind — init has no rule for it
	setprop sys.usb.config "$MYCFG"
	log "config now $(getprop sys.usb.config)"

	# 4) start adbd ourselves (init will not, because config!=adb/mtp,adb)
	start adbd 2>/dev/null || true
	i=0
	while [ "$(getprop sys.usb.ffs.ready)" != "1" ] && [ "$i" -lt 25 ]; do
		sleep 1
		i=$((i + 1))
	done
	log "ffs.ready=$(getprop sys.usb.ffs.ready) t=${i}s"
	[ "$(getprop sys.usb.ffs.ready)" = "1" ] || die "ffs not ready"

	# re-assert links (init none path may have raced)
	setup_functions

	# 5) bind
	if ! echo "$UDC" > "$G/UDC" 2>>"$LOG"; then
		die "bind failed"
	fi
	setprop sys.usb.state "$MYCFG"
	sleep 1

	if ! have_uac2_link; then
		die "f3 vanished after bind"
	fi
	log "OK composition up"
	cat /proc/asound/cards | tee -a "$LOG"
	ls -la "$CFG" | tee -a "$LOG"
	log "done — leave config=$MYCFG; don't open USB prefs"
}

apply_bg() {
	echo "usb_dac: bg apply → $LOG (USB adb will drop; wait ~8s)"
	if command -v nohup >/dev/null 2>&1; then
		nohup sh "$0" __apply_inner >/dev/null 2>&1 &
	else
		sh "$0" __apply_inner >/dev/null 2>&1 &
	fi
	echo "usb_dac: pid $!"
}

watch() {
	log "watch MYCFG=$MYCFG"
	while true; do
		cfg=$(getprop sys.usb.config)
		if [ "$cfg" != "$MYCFG" ] || ! have_uac2_link; then
			log "drift config=$cfg or no f3 — repair"
			apply_inner
		fi
		sleep 4
	done
}

case "${1:-apply}" in
	status) status ;;
	restore|stock) : >"$LOG"; restore_stock ;;
	unlock)
		for p in $(ps -A 2>/dev/null | grep '[u]sb_dac_adb' | awk '{print $2}'); do
			kill -9 "$p" 2>/dev/null || true
		done
		clear_lock
		echo "usb_dac: unlocked"
		;;
	foreground|__apply_inner) apply_inner ;;
	watch) watch ;;
	apply|"") apply_bg ;;
	*) echo "usage: $0 [apply|status|restore|unlock|foreground|watch]"; exit 1 ;;
esac
