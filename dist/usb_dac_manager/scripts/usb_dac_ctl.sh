#!/system/bin/sh
# USB DAC Manager v4.3 — Mode A prefers kernel usb_dac_direct when present
#
MODDIR=/data/adb/modules/usb_dac_manager
[ -d "$MODDIR" ] || MODDIR=$(dirname "$(dirname "$0")")
export MODDIR
BIN=$MODDIR/bin
SCR=$MODDIR/scripts
BASE=/data/adb/usb_dac
CONF=$BASE/config
STATE=$BASE/state
STATUS_JSON=$BASE/status.json
PIDF=$BASE/bridge.pid
SUPF=$BASE/supervisor.pid
WANT=$BASE/want_enabled
LOG=$BASE/ctl.log
USB_NOTIFY_SAVE=$BASE/usb_notify.save
DISABLE_LOCK=$BASE/disable.lock
LOCK=$BASE/lock
HB=$BASE/hb
WORKER=$BASE/worker.pid
ENABLING=$BASE/enabling
MIXPROF=$BASE/mixer_profile.txt
G=/config/usb_gadget/g1
CFG=$G/configs/b.1
SAVE=$BASE/gadget.save
MODE_A_PID=0xDA06
MODE_B_PID=0xDA05
MODE_A_NAME="LG G7 DSP"
MODE_B_NAME="HIFI PLAYER"
RATE=48000
CH=2
UDD_SYS=/sys/kernel/usb_dac_direct
UDD_EN=$UDD_SYS/enable
UDD_ST=$UDD_SYS/status

mkdir -p "$BASE"
[ -f "$CONF" ] || cat >"$CONF" <<'EOF'
ASK_ON_USB=0
FORCE_HIFI=0
ASK_TIMEOUT=12
MODE=b
MODE_B_BITS=16
MODE_A_KERNEL=1
EOF
grep -q '^MODE_A_KERNEL=' "$CONF" || echo 'MODE_A_KERNEL=1' >>"$CONF"

# Migrate legacy MODE values
if grep -q '^MODE=shared' "$CONF" 2>/dev/null; then
  sed -i 's/^MODE=shared/MODE=b/' "$CONF"
fi
if grep -q '^MODE=exclusive' "$CONF" 2>/dev/null; then
  sed -i 's/^MODE=exclusive/MODE=a/' "$CONF"
fi
grep -q '^MODE=' "$CONF" || echo 'MODE=b' >>"$CONF"
grep -q '^MODE_B_BITS=' "$CONF" || echo 'MODE_B_BITS=16' >>"$CONF"

# shellcheck disable=SC1090
. "$CONF"
MODE=${MODE:-b}
case "$MODE" in
  a|A|exclusive) MODE=a ;;
  b|B|shared) MODE=b ;;
esac

[ -f "$STATE" ] || echo idle >"$STATE"

log() {
  line="$(date '+%H:%M:%S') $*"
  echo "$line" >>"$LOG"
  [ -n "$USB_DAC_QUIET" ] || echo "$line"
}

save_and_hide_usb_notifications() {
  if [ ! -f "$USB_NOTIFY_SAVE" ]; then
    {
      echo "adb=$(getprop persist.adb.notify 2>/dev/null)"
      echo "charging=$(getprop persist.charging.notify 2>/dev/null)"
    } >"$USB_NOTIFY_SAVE"
  fi
  # Android's USB manager honors these switches while keeping ADB itself active.
  setprop persist.adb.notify 0 2>/dev/null
  setprop persist.charging.notify 0 2>/dev/null
  log "suppressed USB/ADB system notifications for DAC session"
}

restore_usb_notifications() {
  [ -f "$USB_NOTIFY_SAVE" ] || return 0
  adb_notify=$(sed -n 's/^adb=//p' "$USB_NOTIFY_SAVE" | head -1)
  charging_notify=$(sed -n 's/^charging=//p' "$USB_NOTIFY_SAVE" | head -1)
  # Empty means Android default behavior (notifications enabled).
  [ -n "$adb_notify" ] || adb_notify=1
  [ -n "$charging_notify" ] || charging_notify=1
  setprop persist.adb.notify "$adb_notify" 2>/dev/null
  setprop persist.charging.notify "$charging_notify" 2>/dev/null
  rm -f "$USB_NOTIFY_SAVE"
  log "restored USB/ADB system notification settings"
}

cmd=${1:-status}

set_phase() { echo "$1" >"$STATE"; write_status_json; }

find_uac() {
  awk '/UAC2|Gadget|uac2|snd_uac/{print $1; exit}' /proc/asound/cards 2>/dev/null
}
find_play() {
  n=$(awk '/tavil|sdm845-tavil/{print $1; exit}' /proc/asound/cards 2>/dev/null)
  [ -n "$n" ] && { echo "$n"; return 0; }
  awk '!/Loopback|UAC|Gadget/ && $1 ~ /^[0-9]+$/{print $1; exit}' /proc/asound/cards 2>/dev/null
}
f1_is_uac() { echo "$(readlink "$CFG/f1" 2>/dev/null)" | grep -q 'uac2'; }
udc_bound() {
  cur=$(cat "$G/UDC" 2>/dev/null | tr -d '\n\r ')
  [ -n "$cur" ] && [ "$cur" != "none" ]
}
udc_name() {
  u=$(getprop sys.usb.controller)
  [ -n "$u" ] || u=$(ls /sys/class/udc 2>/dev/null | head -n1 | tr -d '\n\r ')
  echo "$u"
}

kernel_direct_available() { [ -f "$UDD_EN" ]; }

kernel_direct_enabled() {
  [ -f "$UDD_EN" ] || return 1
  [ "$(cat "$UDD_EN" 2>/dev/null | tr -d '\n\r ')" = "1" ]
}

# Sync userspace hb from kernel status (WebUI / supervisor)
sync_hb_from_kernel() {
  kernel_direct_enabled || return 1
  [ -f "$UDD_ST" ] || return 1
  fp=0; fc=0; xc=0; xp=0; rok=0; ru=0; ro=0; rf=0
  while IFS='=' read -r k v; do
    case "$k" in
      frames_play) fp=$v ;;
      frames_cap) fc=$v ;;
      xrun_cap) xc=$v ;;
      xrun_play) xp=$v ;;
      route_ok) rok=$v ;;
      ring_underruns) ru=$v ;;
      ring_overruns) ro=$v ;;
      ring_frames) rf=$v ;;
    esac
  done <"$UDD_ST"
  {
    echo "mode=a"
    echo "bridge=kernel_direct"
    echo "alive=1"
    echo "frames=$fc"
    echo "frames_play=$fp"
    echo "xrun_cap=$xc"
    echo "xrun_play=$xp"
    echo "skew_frames=0"
    echo "skew_ppm=0"
    echo "drift_drops=0"
    echo "drift_inserts=0"
    echo "ring_underruns=$ru"
    echo "ring_overruns=$ro"
    echo "ring_frames=$rf"
    echo "cap_fmt=S16_LE"
    echo "play_fmt=S16_LE"
    echo "rate=$RATE"
    echo "ch=$CH"
    echo "route_ok=$rok"
    echo "ts=$(date +%s)"
  } >"$HB"
}

read_hb() {
  sync_hb_from_kernel 2>/dev/null
  HB_MODE=; HB_BRIDGE=; HB_ALIVE=0; HB_FRAMES=0; HB_TS=0
  HB_XRUN_CAP=0; HB_XRUN_PLAY=0; HB_SKEW_PPM=0; HB_RING_UNDERRUNS=0; HB_RING_OVERRUNS=0; HB_RING_FRAMES=0; HB_CAP_FMT=; HB_PLAY_FMT=
  [ -f "$HB" ] || return 1
  while IFS='=' read -r k v; do
    case "$k" in
      mode) HB_MODE=$v ;;
      bridge) HB_BRIDGE=$v ;;
      alive) HB_ALIVE=$v ;;
      frames) HB_FRAMES=$v ;;
      ts) HB_TS=$v ;;
      xrun_cap) HB_XRUN_CAP=$v ;;
      xrun_play) HB_XRUN_PLAY=$v ;;
      skew_ppm) HB_SKEW_PPM=$v ;;
      ring_underruns) HB_RING_UNDERRUNS=$v ;;
      ring_overruns) HB_RING_OVERRUNS=$v ;;
      ring_frames) HB_RING_FRAMES=$v ;;
      cap_fmt) HB_CAP_FMT=$v ;;
      play_fmt) HB_PLAY_FMT=$v ;;
    esac
  done <"$HB"
}

bridge_alive() {
  if kernel_direct_enabled; then
    sync_hb_from_kernel 2>/dev/null
    return 0
  fi
  [ -f "$PIDF" ] || return 1
  pid=$(cat "$PIDF" 2>/dev/null)
  [ -n "$pid" ] && [ -d "/proc/$pid" ] || return 1
  # Mode B zombie: process up but AAudio DISCONNECTED → frames stuck at 0
  if [ -f "$HB" ]; then
    br=$(grep '^bridge=' "$HB" 2>/dev/null | cut -d= -f2)
    fr=$(grep '^frames=' "$HB" 2>/dev/null | cut -d= -f2)
    if [ "$br" = "aaudio" ] && [ "${fr:-0}" -le 0 ] 2>/dev/null; then
      return 1
    fi
  fi
  return 0
}

# 0 = running path matches wanted MODE and is producing audio
bridge_matches_mode() {
  want=${1:-$MODE}
  case "$want" in a|A|exclusive) want=a ;; *) want=b ;; esac
  ab=$(actual_bridge)
  if [ "$want" = "a" ]; then
    case "$ab" in
      kernel_direct|pcm_bridge|pcm) return 0 ;;
      *) return 1 ;;
    esac
  fi
  # Mode B must be aaudio with frames
  [ "$ab" = "aaudio" ] || return 1
  read_hb
  [ "${HB_FRAMES:-0}" -gt 0 ] 2>/dev/null
}

actual_bridge() {
  if kernel_direct_enabled; then
    echo kernel_direct
    return
  fi
  if ! bridge_alive; then echo none; return; fi
  comm=$(tr '\0' ' ' </proc/"$(cat "$PIDF")"/cmdline 2>/dev/null)
  echo "$comm" | grep -q usb_dac_aaudio && { echo aaudio; return; }
  echo "$comm" | grep -q usb_dac_bridge && { echo pcm_bridge; return; }
  echo "$comm" | grep -qE 'usb_dac_pcm|tinycap|usb_dac_exclusive' && { echo pcm; return; }
  pgrep -f 'usb_dac_bridge' >/dev/null 2>&1 && { echo pcm_bridge; return; }
  echo unknown
}

save_ids() {
  {
    echo "idVendor=$(cat "$G/idVendor" 2>/dev/null)"
    echo "idProduct=$(cat "$G/idProduct" 2>/dev/null)"
    echo "product=$(cat "$G/strings/0x409/product" 2>/dev/null)"
    echo "bDeviceClass=$(cat "$G/bDeviceClass" 2>/dev/null)"
    echo "bDeviceSubClass=$(cat "$G/bDeviceSubClass" 2>/dev/null)"
    echo "bDeviceProtocol=$(cat "$G/bDeviceProtocol" 2>/dev/null)"
  } >"$SAVE"
}

HIFI_SAVE=$BASE/hifi.save

# Snapshot stock HiFi prefs before DAC touches ESS/props.
save_hifi_state() {
  {
    echo "persist_hifi=$(getprop persist.vendor.audio.hifi.enabled 2>/dev/null)"
    echo "lge_hifi=$(getprop persist.vendor.lge.audio.hifi_dac 2>/dev/null)"
    echo "vendor_hifi=$(getprop vendor.audio.hifi.enabled 2>/dev/null)"
    echo "hifi_dac=$(settings get global hifi_dac 2>/dev/null)"
    echo "hifi_mode=$(settings get system hifi_mode 2>/dev/null)"
    if [ -x "$BIN/tinymix" ]; then
      play=$(find_play 2>/dev/null); play=${play:-1}
      echo "ess_state=$("$BIN/tinymix" -D "$play" get "Es9018 State" 2>/dev/null | tr ',' '\n' | grep '>' | sed 's/.*> //;s/ //g')"
      echo "hifi_fn=$("$BIN/tinymix" -D "$play" get "HiFi Function" 2>/dev/null | tr ',' '\n' | grep '>' | sed 's/.*> //;s/ //g')"
    fi
    [ -f /sys/kernel/es9218_dac/headset_type ] && \
      echo "headset_type=$(cat /sys/kernel/es9218_dac/headset_type 2>/dev/null)"
  } >"$HIFI_SAVE" 2>/dev/null
  log "hifi saved $(tr '\n' ' ' <"$HIFI_SAVE" 2>/dev/null)"
}

# Release Mode A exclusive graph so AF can own HP again.
release_mode_a_codec() {
  local play=${1:-1}
  [ -x "$BIN/tinymix" ] || return 0
  "$BIN/tinymix" -D "$play" set "SLIMBUS_6_RX Audio Mixer MultiMedia1" 0 0 >/dev/null 2>&1 || true
  "$BIN/tinymix" -D "$play" set "SLIMBUS_6_RX Audio Mixer MultiMedia1" 0 >/dev/null 2>&1 || true
  "$BIN/tinymix" -D "$play" set "SLIM_6_RX Channels" "Two" >/dev/null 2>&1 || true
  for m in "SLIM RX0 MUX" "SLIM RX1 MUX" "SLIM RX2 MUX" "SLIM RX3 MUX"; do
    "$BIN/tinymix" -D "$play" set "$m" "ZERO" >/dev/null 2>&1 || true
  done
  "$BIN/tinymix" -D "$play" set "RX INT1_1 MIX1 INP0" "ZERO" >/dev/null 2>&1 || true
  "$BIN/tinymix" -D "$play" set "RX INT2_1 MIX1 INP0" "ZERO" >/dev/null 2>&1 || true
  "$BIN/tinymix" -D "$play" set "RX INT1_1 MIX1 INP1" "ZERO" >/dev/null 2>&1 || true
  "$BIN/tinymix" -D "$play" set "RX INT2_1 MIX1 INP1" "ZERO" >/dev/null 2>&1 || true
  "$BIN/tinymix" -D "$play" set "RX INT1_2 MUX" "ZERO" >/dev/null 2>&1 || true
  "$BIN/tinymix" -D "$play" set "RX INT2_2 MUX" "ZERO" >/dev/null 2>&1 || true
  "$BIN/tinymix" -D "$play" set "RX INT1_2 INTERP" "ZERO" >/dev/null 2>&1 || true
  "$BIN/tinymix" -D "$play" set "RX INT2_2 INTERP" "ZERO" >/dev/null 2>&1 || true
  # Drop Mode A Forced Bypass so stock/HiFi can reclaim ESS
  "$BIN/tinymix" -D "$play" set "Es9218 Bypass" 0 >/dev/null 2>&1 || true
}

# After DAC off: restore HiFi *preference* only.
# LG ESS: idle = State Idle/Bypass (未激活); playing = AF sets Hifi/Active.
# Never call force_hifi / never pin Es9018 State=Hifi or TERT_TDM here.
restore_hifi_state() {
  local play=${1:-1} want=0
  persist_hifi=; lge_hifi=; vendor_hifi=; hifi_dac=; hifi_mode=; ess_state=; hifi_fn=; headset_type=
  [ -f "$HIFI_SAVE" ] && . "$HIFI_SAVE" 2>/dev/null

  # Preference from settings/props only — ignore runtime ess_state (Idle/Bypass/Hifi)
  case "${hifi_dac:-}" in 1|true|on|On) want=1 ;; esac
  case "${hifi_mode:-}" in 1|true|on|On) want=1 ;; esac
  case "${persist_hifi:-}" in 1|true|on|On) want=1 ;; esac
  case "${lge_hifi:-}" in 1|true|on|On|ON) want=1 ;; esac
  case "$(settings get global hifi_dac 2>/dev/null)" in 1) want=1 ;; esac
  case "$(settings get system hifi_mode 2>/dev/null)" in 1) want=1 ;; esac

  # Restore saved props/settings verbatim when present
  if [ -n "${persist_hifi:-}" ]; then
    setprop persist.vendor.audio.hifi.enabled "$persist_hifi" 2>/dev/null
  fi
  if [ -n "${lge_hifi:-}" ]; then
    setprop persist.vendor.lge.audio.hifi_dac "$lge_hifi" 2>/dev/null
  fi
  if [ -n "${vendor_hifi:-}" ]; then
    setprop vendor.audio.hifi.enabled "$vendor_hifi" 2>/dev/null
  fi
  [ -n "${hifi_dac:-}" ] && [ "$hifi_dac" != "null" ] && \
    settings put global hifi_dac "$hifi_dac" 2>/dev/null
  [ -n "${hifi_mode:-}" ] && [ "$hifi_mode" != "null" ] && \
    settings put system hifi_mode "$hifi_mode" 2>/dev/null
  if [ -n "${headset_type:-}" ] && [ -f /sys/kernel/es9218_dac/headset_type ]; then
    echo "$headset_type" >/sys/kernel/es9218_dac/headset_type 2>/dev/null
  fi

  if [ -x "$BIN/tinymix" ]; then
    # Undo Mode A sticky Bypass / forced TDM; leave runtime State to AF
    "$BIN/tinymix" -D "$play" set "Es9218 Bypass" 0 >/dev/null 2>&1 || true
    "$BIN/tinymix" -D "$play" set "TERT_TDM_RX_0 Audio Mixer MultiMedia1" 0 0 >/dev/null 2>&1 || true
    "$BIN/tinymix" -D "$play" set "TERT_TDM_RX_0 Audio Mixer MultiMedia1" 0 >/dev/null 2>&1 || true
    # Idle = 未激活 (stock when not playing). Do NOT set Hifi/Active here.
    "$BIN/tinymix" -D "$play" set "Es9018 State" "Idle" >/dev/null 2>&1 || \
      "$BIN/tinymix" -D "$play" set "Es9018 State" "Bypass" >/dev/null 2>&1 || true
  fi

  if [ "$want" = "1" ]; then
    log "restore HiFi preference ON (runtime idle — AF activates on play)"
    # Keep feature flag if ROM uses it; State stays Idle until playback
    if [ -x "$BIN/tinymix" ]; then
      "$BIN/tinymix" -D "$play" set "HiFi Function" "On" >/dev/null 2>&1 || true
    fi
    setprop persist.vendor.audio.hifi.enabled 1 2>/dev/null
    setprop vendor.audio.hifi.enabled 1 2>/dev/null
    settings put global hifi_dac 1 2>/dev/null
    settings put system hifi_mode 1 2>/dev/null
    case "${lge_hifi:-}" in
      OFF|off|0|false|False) ;;
      *) setprop persist.vendor.lge.audio.hifi_dac true 2>/dev/null ;;
    esac
  else
    log "restore HiFi preference OFF (runtime idle)"
    if [ -x "$BIN/tinymix" ]; then
      "$BIN/tinymix" -D "$play" set "HiFi Function" "Off" >/dev/null 2>&1 || true
    fi
  fi
}

# Full post-DAC cleanup: free codec + bounce AF + restore HiFi preference.
restore_stock_playback() {
  local play
  play=$(find_play 2>/dev/null)
  play=${play:-1}
  log "restore stock playback (release DAC graph + AF bounce)"
  release_mode_a_codec "$play"
  stop_audio_stack
  sleep 1
  start_audio_stack
  sleep 1
  if [ -x "$BIN/tinymix" ]; then
    "$BIN/tinymix" -D "$play" set "SLIMBUS_6_RX Audio Mixer MultiMedia1" 0 0 >/dev/null 2>&1 || true
    "$BIN/tinymix" -D "$play" set "SLIMBUS_6_RX Audio Mixer MultiMedia1" 0 >/dev/null 2>&1 || true
  fi
  # Preference only — do not force ESS into active Hifi while idle
  restore_hifi_state "$play"
  log "restore stock playback done"
}

kill_all_dac() {
  rm -f "$WANT"
  # Prefer kernel path shutdown first
  [ -f "$UDD_EN" ] && echo 0 >"$UDD_EN" 2>/dev/null
  [ -f "$SUPF" ] && kill -TERM "$(cat "$SUPF")" 2>/dev/null
  [ -f "$PIDF" ] && kill -TERM "$(cat "$PIDF")" 2>/dev/null
  sleep 1
  [ -f "$SUPF" ] && kill -KILL "$(cat "$SUPF")" 2>/dev/null
  [ -f "$PIDF" ] && kill -KILL "$(cat "$PIDF")" 2>/dev/null
  rm -f "$SUPF" "$PIDF"
  pkill -f 'usb_dac_ctl.sh __supervisor' 2>/dev/null
  pkill -f 'usb_dac_exclusive.sh' 2>/dev/null
  killall -9 usb_dac_aaudio usb_dac_bridge usb_dac_pcm tinycap tinyplay volkey_block 2>/dev/null
  pkill -f 'route_keepalive.sh' 2>/dev/null
  rm -f "$HB"
  play=$(find_play 2>/dev/null)
  play=${play:-1}
  release_mode_a_codec "$play"
}

stop_audio_stack() {
  log "stop audioserver"
  stop audioserver 2>/dev/null
  setprop ctl.stop audioserver 2>/dev/null
  sleep 2
}
start_audio_stack() {
  start audioserver 2>/dev/null
  setprop ctl.start audioserver 2>/dev/null
}
do_hifi() { sh "$SCR/force_hifi.sh"; }

VOL_SAVE=$BASE/vol.save
# LG judyln: settings volume_music_headset often 0..40+; media CLI stream 3 is 0..15.
save_volume() {
  {
    echo "headset=$(settings get system volume_music_headset 2>/dev/null)"
    echo "speaker=$(settings get system volume_music_speaker 2>/dev/null)"
    media volume --stream 3 --get 2>/dev/null | sed -n 's/.*volume is \([0-9]*\).*/media=\1/p'
  } >"$VOL_SAVE" 2>/dev/null
  log "vol saved $(tr '\n' ' ' <"$VOL_SAVE" 2>/dev/null)"
}
# Restore the user's saved levels after DAC shutdown. Keep zero as zero.
restore_volume() {
	[ -s "$VOL_SAVE" ] || { log "vol restore skipped (no saved levels)"; return; }
	hs=; sp=; media_idx=
	v=$(grep '^headset=' "$VOL_SAVE" | cut -d= -f2)
	case "$v" in ''|null|NULL|*[!0-9]*) ;; *) [ "$v" -le 40 ] 2>/dev/null && hs=$v ;; esac
	v=$(grep '^speaker=' "$VOL_SAVE" | cut -d= -f2)
	case "$v" in ''|null|NULL|*[!0-9]*) ;; *) [ "$v" -le 40 ] 2>/dev/null && sp=$v ;; esac
	v=$(grep '^media=' "$VOL_SAVE" | cut -d= -f2)
	case "$v" in ''|null|NULL|*[!0-9]*) ;; *) [ "$v" -le 15 ] 2>/dev/null && media_idx=$v ;; esac
	[ -n "$hs$sp$media_idx" ] || { log "vol restore skipped (saved levels invalid)"; return; }

  # Retry: audioserver may not be ready immediately after start
  i=0
  while [ $i -lt 5 ]; do
		[ -n "$hs" ] && {
			settings put system volume_music_headset "$hs" 2>/dev/null
			settings put system volume_music "$hs" 2>/dev/null
		}
		[ -n "$sp" ] && settings put system volume_music_speaker "$sp" 2>/dev/null
		if [ -n "$media_idx" ]; then
			media volume --stream 3 --set "$media_idx" 2>/dev/null
			cmd media_session volume --stream 3 --set "$media_idx" 2>/dev/null
			service call audio 10 i32 3 i32 "$media_idx" i32 1 >/dev/null 2>&1
		fi
    sleep 0.4
    i=$((i + 1))
  done
	log "vol restored headset=${hs:-unchanged} speaker=${sp:-unchanged} media=${media_idx:-unchanged} (retries=5)"
}

# UAC ssize (bytes/sample): Windows shared-mode is almost always 16-bit.
# Mode A previously used 24 (c_ssize=3) → host often opens but sends no ISO → frames=0.
# Default Mode A to 16; set MODE_A_BITS=24 for 24-bit hosts.
uac_ssize() {
  if [ "$MODE" = "a" ]; then
    case "${MODE_A_BITS:-16}" in
      24|32) echo 3 ;;
      *) echo 2 ;;
    esac
  else
    case "${MODE_B_BITS:-16}" in
      24|32) echo 3 ;;
      *) echo 2 ;;
    esac
  fi
}

unbind_udc() {
  i=0
  while [ $i -lt 15 ]; do
    echo "" >"$G/UDC" 2>/dev/null
    cur=$(cat "$G/UDC" 2>/dev/null | tr -d '\n\r ')
    [ -z "$cur" ] || [ "$cur" = "none" ] && return 0
    sleep 0.4
    i=$((i + 1))
  done
  return 1
}
clear_links() {
  rm -f "$CFG/f1" "$CFG/f2" "$CFG/f3" "$CFG/f4" 2>/dev/null
  [ -e "$CFG/f1" ] || [ -L "$CFG/f1" ] && return 1
  return 0
}
setup_uac_function() {
  SS=$(uac_ssize)
  mkdir -p "$G/functions/uac2.0" || return 1
  # Capture = PC → phone (USB OUT). Stereo 48 kHz.
  printf '%s' 3 >"$G/functions/uac2.0/c_chmask"
  printf '%s' "$RATE" >"$G/functions/uac2.0/c_srate"
  printf '%s' "$SS" >"$G/functions/uac2.0/c_ssize"
  # Playback path phone→PC unused for DAC; p_chmask=0 → capture-only descriptors
  # (helps Windows shared-mode open a single render endpoint).
  printf '%s' 0 >"$G/functions/uac2.0/p_chmask" 2>/dev/null
  printf '%s' "$RATE" >"$G/functions/uac2.0/p_srate" 2>/dev/null
  printf '%s' 2 >"$G/functions/uac2.0/p_ssize" 2>/dev/null
  log "uac c_ssize=$SS rate=$RATE mode=$MODE p_chmask=0 (OUT-only)"
  return 0
}

bind_uac2() {
  UDC=$(udc_name)
  [ -n "$UDC" ] || { log "no UDC"; return 1; }
  # Distinct USB identities make Windows enumerate each bridge mode separately.
  if [ "$MODE" = "a" ]; then
    DAC_PID=$MODE_A_PID
    DAC_NAME=$MODE_A_NAME
  else
    DAC_PID=$MODE_B_PID
    DAC_NAME=$MODE_B_NAME
  fi
  log "bind udc=$UDC (uac2+adb)"
  # Park init USB policy so it does not rewrite configfs; keep ADB via ffs.adb
  setprop sys.usb.ffs.ready 0 2>/dev/null
  stop adbd 2>/dev/null
  setprop persist.sys.usb.config none 2>/dev/null
  setprop sys.usb.config none
  i=0
  while [ "$(getprop sys.usb.state)" != "none" ] && [ $i -lt 15 ]; do
    echo "" >"$G/UDC" 2>/dev/null
    sleep 1
    i=$((i + 1))
  done
  unbind_udc || { log "unbind UDC failed"; return 1; }
  # Let Android withdraw notifications for the previous USB function first.
  save_and_hide_usb_notifications
  sleep 0.5
  clear_links || { log "cannot clear links"; return 1; }
  setup_uac_function || { log "no uac2.0"; return 1; }
  mkdir -p "$CFG/strings/0x409" "$G/strings/0x409"
  printf '%s' 0x80 >"$CFG/bmAttributes" 2>/dev/null
  printf '%s' 250 >"$CFG/MaxPower" 2>/dev/null
  printf '%s' "$DAC_PID" >"$G/idProduct"
  printf '%s' "$DAC_NAME" >"$G/strings/0x409/product"
  printf '%s' "$DAC_NAME" >"$CFG/strings/0x409/configuration"
  printf '%s' 0 >"$G/bDeviceClass"
  printf '%s' 0 >"$G/bDeviceSubClass"
  printf '%s' 0 >"$G/bDeviceProtocol"
  ln -s /config/usb_gadget/g1/functions/uac2.0 "$CFG/f1" || return 1
  # Keep ADB so BakaSU/KSU WebUI + diagnostics survive Mode A
  if [ -d "$G/functions/ffs.adb" ]; then
    ln -s /config/usb_gadget/g1/functions/ffs.adb "$CFG/f2" || log "WARN adb link"
    start adbd 2>/dev/null
    j=0
    while [ "$(getprop sys.usb.ffs.ready)" != "1" ] && [ $j -lt 25 ]; do
      sleep 0.2
      j=$((j + 1))
    done
    log "ffs.ready=$(getprop sys.usb.ffs.ready)"
  else
    log "WARN no ffs.adb — ADB will drop"
  fi
  printf '%s' "$UDC" >"$G/UDC"
  got=$(cat "$G/UDC" 2>/dev/null | tr -d '\n\r ')
  [ "$got" = "$UDC" ] || { log "bind verify fail"; return 1; }
  setprop sys.usb.state uac2,adb
  sleep 1
  f1_is_uac || { log "f1 stolen"; return 1; }
  log "bind OK f1=$(readlink "$CFG/f1") f2=$(readlink "$CFG/f2") UDC=$got"
  return 0
}

gadget_repair() {
  UDC=$(udc_name)
  [ -n "$UDC" ] || return 1
  if f1_is_uac && udc_bound; then
    # Ensure ADB link still present
    if [ ! -e "$CFG/f2" ] && [ -d "$G/functions/ffs.adb" ]; then
      echo "" >"$G/UDC" 2>/dev/null
      ln -s /config/usb_gadget/g1/functions/ffs.adb "$CFG/f2" 2>/dev/null
      start adbd 2>/dev/null
      sleep 0.5
      printf '%s' "$UDC" >"$G/UDC" 2>/dev/null
      setprop sys.usb.state uac2,adb
    fi
    [ "$(getprop sys.usb.config)" = "none" ] || setprop sys.usb.config none 2>/dev/null
    return 0
  fi
  echo "" >"$G/UDC" 2>/dev/null
  sleep 0.3
  clear_links
  setup_uac_function
  ln -s /config/usb_gadget/g1/functions/uac2.0 "$CFG/f1" 2>/dev/null
  ln -s /config/usb_gadget/g1/functions/ffs.adb "$CFG/f2" 2>/dev/null
  start adbd 2>/dev/null
  sleep 0.5
  printf '%s' "$UDC" >"$G/UDC"
  setprop sys.usb.config none 2>/dev/null
  setprop sys.usb.state uac2,adb
  f1_is_uac && udc_bound
}

write_status_json() {
  [ -f "$CONF" ] && . "$CONF"
  MODE=${MODE:-b}
  case "$MODE" in a|A|exclusive) MODE=a ;; *) MODE=b ;; esac
  st=$(cat "$STATE" 2>/dev/null)
  uac=$(find_uac)
  play=$(find_play)
  f1=$(readlink "$CFG/f1" 2>/dev/null)
  udc=$(cat "$G/UDC" 2>/dev/null | tr -d '\n\r ')
  br=$(actual_bridge)
  read_hb
  now=$(date +%s)
  age=999
  [ -n "$HB_TS" ] && [ "$HB_TS" -gt 0 ] 2>/dev/null && age=$((now - HB_TS))
  ready=0
  sound=0
  if f1_is_uac && udc_bound && [ -n "$uac" ] && bridge_alive; then
    ready=1
  fi
  if [ "$ready" = 1 ] && [ "${HB_ALIVE:-0}" = 1 ] && [ "$age" -le 3 ]; then
    [ "${HB_FRAMES:-0}" -gt 0 ] 2>/dev/null && sound=1
  fi
	mode_a_active=0
	case "$br" in kernel_direct|pcm_bridge|pcm) mode_a_active=1 ;; esac
  audioserver_up=0
  pidof audioserver >/dev/null 2>&1 && audioserver_up=1
  mixer_profile=0
  [ -s "$MIXPROF" ] && mixer_profile=1
  bit_perfect_claim=0
  hint="—"
  case "$st" in
    starting|binding|wait-uac|hifi|stop-audio|route|start-bridge) hint="启动中: $st" ;;
    live) hint="已就绪" ;;
    idle|disabled|"") hint="已关闭" ;;
    error*) hint="$st" ;;
  esac
  [ "$MODE" = "b" ] && [ "$ready" = 1 ] && hint="Mode B HAL 路径（非 bit-perfect 声明）"
  [ "$sound" = 1 ] && hint="有音频帧 ✓"

  cat >"$STATUS_JSON.tmp" <<EOF
{
  "state": "${st:-unknown}",
  "phase": "${st:-unknown}",
  "mode": "$MODE",
  "mode_label": "$(
    if [ "$MODE" = a ]; then
      case "$br" in
	      kernel_direct|pcm_bridge|pcm) echo A_low_latency ;;
        aaudio) echo A_aaudio_not_ll ;;
        *) echo A_starting ;;
      esac
    else
      echo B_hifi_hal
    fi
  )",
  "mode_actual": "$br",
  "mode_a_active": $mode_a_active,
  "exclusive_active": $mode_a_active,
  "ready": $ready,
  "sound": $sound,
  "hint": "$hint",
  "ask_on_usb": ${ASK_ON_USB:-0},
  "force_hifi": ${FORCE_HIFI:-0},
  "running": "$(bridge_alive && echo yes || echo no)",
  "pid": "$(cat "$PIDF" 2>/dev/null)",
  "usb_config": "$(getprop sys.usb.config)",
  "usb_state": "$(getprop sys.usb.state)",
  "udc": "$udc",
  "f1": "$f1",
  "uac_card": "${uac}",
  "play_card": "${play}",
  "hb_bridge": "${HB_BRIDGE}",
  "hb_frames": ${HB_FRAMES:-0},
  "hb_age": $age,
  "xruns": $((${HB_XRUN_CAP:-0} + ${HB_XRUN_PLAY:-0})),
  "xrun_cap": ${HB_XRUN_CAP:-0},
  "xrun_play": ${HB_XRUN_PLAY:-0},
  "ring_underruns": ${HB_RING_UNDERRUNS:-0},
  "ring_overruns": ${HB_RING_OVERRUNS:-0},
  "ring_frames": ${HB_RING_FRAMES:-0},
  "skew_ppm": ${HB_SKEW_PPM:-0},
  "cap_fmt": "${HB_CAP_FMT}",
  "play_fmt": "${HB_PLAY_FMT}",
  "mixer_profile": $mixer_profile,
  "bit_perfect_claim": $bit_perfect_claim,
  "audioserver": $audioserver_up,
  "want": "$([ -f "$WANT" ] && echo 1 || echo 0)"
}
EOF
  mv "$STATUS_JSON.tmp" "$STATUS_JSON"
}

do_status() {
  write_status_json
  cat "$STATUS_JSON"
  echo
  echo "--- cards ---"
  cat /proc/asound/cards 2>/dev/null
  echo "--- hb ---"
  cat "$HB" 2>/dev/null
}

# Mode A left AIF4/SLIM RX MUXes + ESS Bypass → Mode B AAudio DISCONNECTED loop.
prepare_mode_b_hal() {
  local play=${1:-1}
  log "Mode B HAL clean (release Mode A codec graph)"
  [ -f "$UDD_EN" ] && echo 0 >"$UDD_EN" 2>/dev/null
  killall -9 usb_dac_bridge usb_dac_pcm volkey_block 2>/dev/null
  pkill -f 'route_keepalive.sh' 2>/dev/null
  if [ -x "$BIN/tinymix" ]; then
    "$BIN/tinymix" -D "$play" set "SLIMBUS_6_RX Audio Mixer MultiMedia1" 0 0 >/dev/null 2>&1 || true
    # Free AIF4 slots so AF can reclaim RX for stock HP (often SLIM0)
    for m in "SLIM RX0 MUX" "SLIM RX1 MUX" "SLIM RX2 MUX" "SLIM RX3 MUX"; do
      "$BIN/tinymix" -D "$play" set "$m" "ZERO" >/dev/null 2>&1 || true
    done
    "$BIN/tinymix" -D "$play" set "RX INT1_1 MIX1 INP0" "ZERO" >/dev/null 2>&1 || true
    "$BIN/tinymix" -D "$play" set "RX INT2_1 MIX1 INP0" "ZERO" >/dev/null 2>&1 || true
    "$BIN/tinymix" -D "$play" set "RX INT1_2 MUX" "ZERO" >/dev/null 2>&1 || true
    "$BIN/tinymix" -D "$play" set "RX INT2_2 MUX" "ZERO" >/dev/null 2>&1 || true
    # Do not force ESS Bypass/State — let AF/hifi props own Mode B
  fi
  # Bounce AF so it rebuilds headphone DAPM (fixes AAUDIO_ERROR_DISCONNECTED)
  stop_audio_stack
  sleep 1
  start_audio_stack
  sleep 1
  log "Mode B HAL clean done"
}

# After Mode B AAudio, AF leaves SLIM6/MM1 sticky → Mode A HW_PARAMS -EINVAL.
prepare_mode_a_clean() {
  local play=${1:-1} i
  log "Mode A clean after B/AAudio"
  killall -9 usb_dac_aaudio usb_dac_bridge usb_dac_pcm tinycap tinyplay 2>/dev/null
  [ -f "$UDD_EN" ] && echo 0 >"$UDD_EN" 2>/dev/null
  # Drop FE so BE can reconfigure channels/format
  if [ -x "$BIN/tinymix" ]; then
    "$BIN/tinymix" -D "$play" set "SLIMBUS_6_RX Audio Mixer MultiMedia1" 0 0 >/dev/null 2>&1 || true
    "$BIN/tinymix" -D "$play" set "SLIMBUS_6_RX Audio Mixer MultiMedia1" 0 >/dev/null 2>&1 || true
    "$BIN/tinymix" -D "$play" set "SLIM_6_RX Channels" "Two" >/dev/null 2>&1 || true
    "$BIN/tinymix" -D "$play" set "SLIM_6_RX SampleRate" "KHZ_48" >/dev/null 2>&1 || true
    "$BIN/tinymix" -D "$play" set "SLIM_6_RX Format" "S16_LE" >/dev/null 2>&1 || true
  fi
  # Wait PCM free (Mode B / stale kernel hold)
  i=0
  while [ $i -lt 20 ]; do
    st1=$(cat /proc/asound/card"${play}"/pcm0p/sub0/status 2>/dev/null | head -1)
    st2=$(cat /proc/asound/card2/pcm0c/sub0/status 2>/dev/null | head -1)
    echo "$st1" | grep -q closed || true
    case "$st1$st2" in
      *running*|*PREPARED*|*SETUP*|*XRUN*) sleep 0.25; i=$((i+1)); continue ;;
    esac
    break
  done
  # Ensure kernel status settled
  i=0
  while [ $i -lt 10 ]; do
    en=$(cat "$UDD_EN" 2>/dev/null | tr -d '\n\r ')
    msg=$(grep '^msg=' "$UDD_ST" 2>/dev/null | cut -d= -f2-)
    [ "$en" = "0" ] || [ -z "$en" ] || { sleep 0.2; i=$((i+1)); continue; }
    case "$msg" in
      open\ *|starting|queued\ *) sleep 0.2; i=$((i+1)); continue ;;
    esac
    break
  done
  sleep 0.3
}

start_bridge_once() {
  mode=$1
  UAC=$(find_uac)
  [ -n "$UAC" ] || { log "no UAC"; return 1; }
  setenforce 0 2>/dev/null
  if [ "$mode" = "a" ]; then
    PLAY=$(find_play)
    [ -n "$PLAY" ] || { log "no play"; return 1; }
    killall -9 usb_dac_aaudio usb_dac_bridge volkey_block 2>/dev/null
    pkill -f 'route_keepalive.sh' 2>/dev/null
    rm -f "$HB" "$PIDF" "$BASE/ka.pid"
    am force-stop com.maxmpz.audioplayer 2>/dev/null
    am force-stop com.lge.music 2>/dev/null
    am force-stop com.google.android.apps.youtube.music 2>/dev/null
    pgrep -x audioserver >/dev/null 2>&1 || start_audio_stack
    prepare_mode_a_clean "$PLAY"

    # Default: in-kernel usb_dac_direct (PCM only). MODE_A_KERNEL=0 → userspace.
    # Route MUST happen in userspace while MM1 is closed — kernel DAPM freezes.
    if kernel_direct_available && [ "${MODE_A_KERNEL:-1}" = "1" ]; then
      log "Mode A kernel usb_dac_direct UAC=$UAC PLAY=$PLAY"
      log "Mode A pre-route (userspace, PCM closed)"
      timeout 8 sh "$SCR/route_mm1_slim6.sh" "$PLAY" >>"$LOG" 2>&1 || {
        log "Mode A stereo pre-route failed; refusing kernel Mode A start"
        return 1
      }
      if echo 1 >"$UDD_EN" 2>/dev/null; then
        echo kernel >"$PIDF"
        [ -x "$BIN/volkey_block" ] && "$BIN/volkey_block" >>"$LOG" 2>&1 &
        sh "$SCR/route_keepalive.sh" >>"$LOG" 2>&1 &
        i=0
        while [ $i -lt 30 ]; do
          sync_hb_from_kernel
          fp=$(grep '^frames_play=' "$HB" 2>/dev/null | cut -d= -f2)
          fp=${fp:-0}
          msg=$(grep '^msg=' "$UDD_ST" 2>/dev/null | cut -d= -f2-)
          if [ "$fp" -gt 2000 ] 2>/dev/null; then
            log "Mode A kernel OK frames_play=$fp msg=$msg"
            return 0
          fi
          echo "$msg" | grep -qE 'fail|refused' && break
          en=$(cat "$UDD_EN" 2>/dev/null | tr -d '\n\r ')
          case "$msg" in
            queued\ start|starting|open\ uac=*|open\ play=*|fe\ *|live\ *) ;;
            *) [ "$en" = "1" ] || break ;;
          esac
          sleep 0.5
          i=$((i + 1))
        done
        log "Mode A kernel not ready (msg=$msg) — retry once after clean"
        echo 0 >"$UDD_EN" 2>/dev/null
        killall -9 volkey_block 2>/dev/null
        pkill -f route_keepalive.sh 2>/dev/null
        prepare_mode_a_clean "$PLAY"
        sleep 0.5
        timeout 8 sh "$SCR/route_mm1_slim6.sh" "$PLAY" >>"$LOG" 2>&1 || {
          log "Mode A stereo pre-route retry failed; aborting retry"
          return 1
        }
        if echo 1 >"$UDD_EN" 2>/dev/null; then
          echo kernel >"$PIDF"
          [ -x "$BIN/volkey_block" ] && "$BIN/volkey_block" >>"$LOG" 2>&1 &
          sh "$SCR/route_keepalive.sh" >>"$LOG" 2>&1 &
          i=0
          while [ $i -lt 24 ]; do
            sync_hb_from_kernel
            fp=$(grep '^frames_play=' "$HB" 2>/dev/null | cut -d= -f2)
            fp=${fp:-0}
            msg=$(grep '^msg=' "$UDD_ST" 2>/dev/null | cut -d= -f2-)
            [ "$fp" -gt 2000 ] 2>/dev/null && {
              log "Mode A kernel OK (retry) frames_play=$fp"
              return 0
            }
            echo "$msg" | grep -qE 'fail|refused' && break
            sleep 0.5
            i=$((i + 1))
          done
          log "Mode A kernel retry failed (msg=$msg) — fallback userspace"
          echo 0 >"$UDD_EN" 2>/dev/null
          prepare_mode_a_clean "$PLAY"
          killall -9 volkey_block 2>/dev/null
          pkill -f route_keepalive.sh 2>/dev/null
        fi
      else
        log "Mode A kernel refused/unavailable — fallback userspace"
      fi
    else
      log "Mode A userspace path (MODE_A_KERNEL=${MODE_A_KERNEL:-1})"
      [ -f "$UDD_EN" ] && echo 0 >"$UDD_EN" 2>/dev/null
    fi

    # Userspace fallback (old pcm_bridge)
    USE_PCM=${MODE_A_PCM:-1}
    if [ "$USE_PCM" = "1" ] && [ -x "$BIN/usb_dac_bridge" ]; then
      BITS=${MODE_A_BITS:-16}
      case "$BITS" in 24|32) BITS=24 ;; *) BITS=16 ;; esac
      PLAY_DEV=${MODE_A_PLAY_DEV:-0}
      log "Mode A userspace route_mm1_slim6 + usb_dac_bridge"
      # Detect TLS-broken / non-executable bridge early (Bionic abort)
      if ! "$BIN/usb_dac_bridge" 2>&1 | head -1 | grep -q usage; then
        log "Mode A bridge binary broken (TLS/exec) — skip userspace"
      else
      sh "$SCR/route_mm1_slim6.sh" "$PLAY" >>"$LOG" 2>&1
      "$BIN/usb_dac_bridge" "$UAC" "$PLAY" "$PLAY_DEV" "$RATE" "$CH" "$BITS" >>"$LOG" 2>&1 &
      echo $! >"$PIDF"
      sleep 0.4
      if ! kill -0 "$(cat "$PIDF" 2>/dev/null)" 2>/dev/null; then
        log "Mode A bridge died at exec — skip userspace"
        rm -f "$PIDF"
      else
      [ -x "$BIN/volkey_block" ] && "$BIN/volkey_block" >>"$LOG" 2>&1 &
      sh "$SCR/route_keepalive.sh" >>"$LOG" 2>&1 &
      sleep 5
      sh "$SCR/route_mm1_slim6.sh" "$PLAY" >>"$LOG" 2>&1
      fp=$(grep '^frames_play=' "$HB" 2>/dev/null | cut -d= -f2)
      fp=${fp:-0}
      if [ "$fp" -gt 2000 ] 2>/dev/null; then
        log "Mode A PCM OK frames_play=$fp"
        return 0
      fi
      log "Mode A PCM weak (frames_play=$fp)"
      killall -9 usb_dac_bridge 2>/dev/null
      rm -f "$PIDF"
      if [ "${MODE_A_ALLOW_AAUDIO:-0}" != "1" ]; then
        return 1
      fi
      start_audio_stack
      fi
      fi
    fi
    [ -x "$BIN/usb_dac_aaudio" ] || { log "no aaudio fallback"; return 1; }
    start_audio_stack
    log "Mode A aaudio fallback UAC=$UAC (not low-latency)"
    "$BIN/usb_dac_aaudio" "$UAC" "$RATE" "$CH" >>"$LOG" 2>&1 &
    echo $! >"$PIDF"
  else
    [ -f "$UDD_EN" ] && echo 0 >"$UDD_EN" 2>/dev/null
    [ -x "$BIN/usb_dac_aaudio" ] || { log "no aaudio"; return 1; }
    PLAY=$(find_play)
    PLAY=${PLAY:-1}
    prepare_mode_b_hal "$PLAY"
    log "Mode B aaudio UAC=$UAC"
    "$BIN/usb_dac_aaudio" "$UAC" "$RATE" "$CH" >>"$LOG" 2>&1 &
    echo $! >"$PIDF"
    # Wait for frames — DISCONNECTED loop reports alive but frames=0
    i=0
    while [ $i -lt 12 ]; do
      sleep 1
      fp=$(grep '^frames=' "$HB" 2>/dev/null | cut -d= -f2)
      fp=${fp:-0}
      [ "$fp" -gt 500 ] 2>/dev/null && {
        log "Mode B aaudio OK frames=$fp"
        return 0
      }
      kill -0 "$(cat "$PIDF" 2>/dev/null)" 2>/dev/null || {
        log "Mode B aaudio died"
        return 1
      }
      i=$((i + 1))
    done
    fp=$(grep '^frames=' "$HB" 2>/dev/null | cut -d= -f2)
    fp=${fp:-0}
    if [ "$fp" -gt 0 ] 2>/dev/null; then
      log "Mode B aaudio weak frames=$fp (continue)"
      return 0
    fi
    log "Mode B aaudio silent frames=0 (DISCONNECTED?)"
    return 1
  fi
  sleep 3
  bridge_alive
}

supervisor_loop() {
  mode=$1
  log "supervisor mode=$mode"
  touch "$WANT"
  fail=0
  while [ -f "$WANT" ]; do
    gadget_repair
    write_status_json
    if ! bridge_alive; then
      if ! start_bridge_once "$mode"; then
        fail=$((fail + 1))
        [ "$fail" -ge 8 ] && set_phase "error-bridge"
        sleep 2
        continue
      fi
      fail=0
      set_phase "live"
      log "bridge up pid=$(cat "$PIDF") actual=$(actual_bridge)"
    fi
    while [ -f "$WANT" ] && bridge_alive; do
      gadget_repair
      write_status_json
      sleep 1
    done
    [ -f "$WANT" ] || break
    log "bridge died — restart"
    rm -f "$PIDF"
    sleep 1
  done
  rm -f "$PIDF"
  log "supervisor exit"
}

enable_inner() {
  trap '' HUP PIPE
  trap 'rm -f "$ENABLING"; [ "$(cat "$STATE" 2>/dev/null)" = live ] || restore_usb_notifications' EXIT
  . "$CONF"
  MODE=${MODE:-b}
  case "$MODE" in a|A|exclusive) MODE=a ;; *) MODE=b ;; esac
  log "ENABLE-WORKER mode=$MODE"
  touch "$ENABLING"
  [ -d "$G" ] || { set_phase "error-no-gadget"; return 1; }

  kill_all_dac
  save_ids
  save_hifi_state
  set_phase "binding"

  if [ "$MODE" = "a" ]; then
    [ -x "$BIN/usb_dac_bridge" ] || [ -x "$BIN/tinycap" ] || {
      set_phase "error-no-bin"; return 1
    }
  else
    [ -x "$BIN/usb_dac_aaudio" ] || { set_phase "error-no-bin"; return 1; }
    start_audio_stack
  fi

  try=1
  while [ $try -le 4 ]; do
    set_phase "binding"
    bind_uac2 && break
    try=$((try + 1))
    sleep 1
  done
  [ $try -le 4 ] || { set_phase "error-bind"; start_audio_stack; return 1; }

  set_phase "wait-uac"
  uac=""; i=0
  while [ $i -lt 40 ]; do
    gadget_repair
    uac=$(find_uac)
    [ -n "$uac" ] && break
    sleep 0.5
    i=$((i + 1))
  done
  [ -n "$uac" ] || { set_phase "error-uac"; start_audio_stack; return 1; }
  log "UAC=$uac"

  if [ "${FORCE_HIFI:-0}" = "1" ]; then
    set_phase "hifi"
    do_hifi
  fi

  PLAY=$(find_play)
  if [ "$MODE" = "a" ]; then
    # Skip tinymix route by default — was hanging WebUI on "route".
    # PCM dev=0 works without it; set MODE_A_ROUTE=1 to force mixer graph.
    if [ "${MODE_A_ROUTE:-0}" = "1" ]; then
      set_phase "route"
      (
        sh "$SCR/route_playback.sh" "$PLAY" >>"$LOG" 2>&1
      ) &
      rp=$!
      ri=0
      while [ $ri -lt 8 ]; do
        kill -0 "$rp" 2>/dev/null || break
        sleep 1
        ri=$((ri + 1))
      done
      if kill -0 "$rp" 2>/dev/null; then
        log "WARN route timeout — kill"
        kill -9 "$rp" 2>/dev/null
        # kill by pid only — never pkill pattern that matches this shell
        kill -9 "$rp" 2>/dev/null
      fi
      wait "$rp" 2>/dev/null
    else
      log "Mode A skip route (PCM; MODE_A_ROUTE=1 to enable tinymix)"
    fi
    # Do NOT touch media/settings volume — AF will wipe Mode A DSP route.
    save_volume
    sleep 0.2
  else
    # Preserve the user's chosen level; never jump to maximum on DAC enable.
    save_volume
    sleep 0.2
  fi

  set_phase "start-bridge"
  touch "$WANT"
  sh "$SCR/usb_dac_ctl.sh" __supervisor "$MODE" >>"$LOG" 2>&1 &
  echo $! >"$SUPF"

  i=0
  got=0
  while [ $i -lt 20 ]; do
    write_status_json
    ready=$(grep -o '"ready": *[01]' "$STATUS_JSON" 2>/dev/null | head -1 | grep -o '[01]')
    [ "$ready" = "1" ] && { got=1; break; }
    sleep 1
    i=$((i + 1))
  done

  if [ "$got" = "1" ]; then
    set_phase "live"
    log "LIVE mode=$MODE actual=$(actual_bridge)"
    write_status_json
    return 0
  fi

  if [ "$MODE" = "b" ]; then
    i=0
    while [ $i -lt 25 ]; do
      write_status_json
      ready=$(grep -o '"ready": *[01]' "$STATUS_JSON" 2>/dev/null | head -1 | grep -o '[01]')
      [ "$ready" = "1" ] && { set_phase "live"; return 0; }
      sleep 1
      i=$((i + 1))
    done
  fi
  set_phase "error-timeout"
  return 1
}

do_enable() {
  write_status_json
  . "$CONF" 2>/dev/null
  MODE=${MODE:-b}
  case "$MODE" in a|A|exclusive) MODE=a ;; *) MODE=b ;; esac
  # Already correct path with sound — no-op
  if bridge_alive && f1_is_uac && bridge_matches_mode "$MODE"; then
    set_phase "live"
    do_status
    exit 0
  fi
  # Wrong mode / silent aaudio / sticky Mode A → force full rearm
  if bridge_alive || kernel_direct_enabled; then
    ab=$(actual_bridge)
    log "ENABLE: rearm mode=$MODE actual=$ab (mismatch or silent)"
    kill_all_dac
    [ -f "$UDD_EN" ] && echo 0 >"$UDD_EN" 2>/dev/null
  fi
  # Stale worker stuck in route/binding blocks 2nd enable — clear it
  if [ -f "$WORKER" ]; then
    wpid=$(cat "$WORKER" 2>/dev/null)
    if [ -n "$wpid" ] && [ -d "/proc/$wpid" ]; then
      st=$(cat "$STATE" 2>/dev/null)
      case "$st" in
        route|binding|wait-uac|hifi|starting|stop-audio|start-bridge|live)
          log "ENABLE: kill worker pid=$wpid state=$st (rearm)"
          kill -9 "$wpid" 2>/dev/null
          pkill -9 -f 'usb_dac_ctl.sh __enable_worker' 2>/dev/null
          pkill -9 -f 'usb_dac_ctl.sh __supervisor' 2>/dev/null
          pkill -9 -f 'route_playback.sh' 2>/dev/null
          pkill -9 -f 'mixer_profile_apply' 2>/dev/null
          rm -f "$WORKER" "$ENABLING" "$SUPF"
          ;;
        *)
          log "ENABLE: kill worker pid=$wpid state=$st"
          kill -9 "$wpid" 2>/dev/null
          pkill -9 -f 'usb_dac_ctl.sh __enable_worker' 2>/dev/null
          pkill -9 -f 'usb_dac_ctl.sh __supervisor' 2>/dev/null
          rm -f "$WORKER" "$ENABLING" "$SUPF"
          ;;
      esac
    else
      rm -f "$WORKER" "$ENABLING"
    fi
  fi
  echo starting >"$STATE"
  touch "$ENABLING"
  write_status_json
  log "ENABLE queued mode=$MODE"
  if command -v setsid >/dev/null 2>&1; then
    setsid nohup sh "$SCR/usb_dac_ctl.sh" __enable_worker >>"$LOG" 2>&1 &
  elif command -v nohup >/dev/null 2>&1; then
    nohup sh "$SCR/usb_dac_ctl.sh" __enable_worker >>"$LOG" 2>&1 &
  else
    sh "$SCR/usb_dac_ctl.sh" __enable_worker >>"$LOG" 2>&1 &
  fi
  echo $! >"$WORKER"
  sleep 0.3
  do_status
  exit 0
}

# Soft drop UAC2 → stock mtp,adb. Prefer re-link without sys.usb.config none
# (hard none↔mtp,adb often leaves Windows with no device until unplug).
restore_stock_usb() {
  UDC=$(udc_name)
  log "restore stock USB (soft drop UAC)"
  if [ -f "$SAVE" ]; then
    # shellcheck disable=SC1090
    . "$SAVE"
    [ -n "${idVendor:-}" ] && echo "$idVendor" >"$G/idVendor"
    [ -n "${idProduct:-}" ] && echo "$idProduct" >"$G/idProduct"
    [ -n "${product:-}" ] && echo "$product" >"$G/strings/0x409/product"
    [ -n "${bDeviceClass:-}" ] && echo "$bDeviceClass" >"$G/bDeviceClass"
    [ -n "${bDeviceSubClass:-}" ] && echo "$bDeviceSubClass" >"$G/bDeviceSubClass"
    [ -n "${bDeviceProtocol:-}" ] && echo "$bDeviceProtocol" >"$G/bDeviceProtocol"
  fi
  # Unbind → mtp+adb only → bind (keep adbd running when possible)
  echo "" >"$G/UDC" 2>/dev/null
  echo none >"$G/UDC" 2>/dev/null
  rm -f "$CFG/f1" "$CFG/f2" "$CFG/f3" "$CFG/f4" 2>/dev/null
  ln -s /config/usb_gadget/g1/functions/mtp.gs0 "$CFG/f1" 2>/dev/null
  ln -s /config/usb_gadget/g1/functions/ffs.adb "$CFG/f2" 2>/dev/null
  setprop persist.sys.usb.config mtp,adb 2>/dev/null
  setprop sys.usb.config mtp,adb 2>/dev/null
  setprop sys.usb.state mtp,adb 2>/dev/null
  [ -n "$UDC" ] && echo "$UDC" >"$G/UDC" 2>/dev/null
  sleep 1
  if ! udc_bound; then
    log "soft USB bind failed — fallback full reset"
    setprop sys.usb.ffs.ready 0 2>/dev/null
    stop adbd 2>/dev/null
    setprop persist.sys.usb.config none 2>/dev/null
    setprop sys.usb.config none
    sleep 1
    setprop persist.sys.usb.config mtp,adb 2>/dev/null
    setprop sys.usb.config mtp,adb
    start adbd 2>/dev/null
    sleep 2
    ln -s /config/usb_gadget/g1/functions/mtp.gs0 "$CFG/f1" 2>/dev/null
    ln -s /config/usb_gadget/g1/functions/ffs.adb "$CFG/f2" 2>/dev/null
    [ -n "$UDC" ] && echo "$UDC" >"$G/UDC" 2>/dev/null
    setprop sys.usb.state mtp,adb
  fi
  log "stock USB done state=$(getprop sys.usb.state) udc=$(cat "$G/UDC" 2>/dev/null)"
}

do_disable() {
  if disable_is_done; then
    log "DISABLE ignored: already idle with no bridge"
    [ -f "$STATUS_JSON" ] && cat "$STATUS_JSON"
    return 0
  fi
  acquire_disable_lock
  lock_result=$?
  if [ "$lock_result" = "2" ]; then
    log "DISABLE ignored: another disable completed cleanup"
    [ -f "$STATUS_JSON" ] && cat "$STATUS_JSON"
    return 0
  fi
  if [ "$lock_result" != "0" ]; then
    log "DISABLE failed: timed out waiting for disable lock"
    return 1
  fi
  trap 'release_disable_lock' EXIT
  if disable_is_done; then
    log "DISABLE ignored: already cleaned up"
    [ -f "$STATUS_JSON" ] && cat "$STATUS_JSON"
    release_disable_lock
    trap - EXIT
    return 0
  fi

  log "DISABLE"
  rm -f "$ENABLING" "$WANT"
  [ -f "$WORKER" ] && kill -TERM "$(cat "$WORKER")" 2>/dev/null
  rm -f "$WORKER"
  kill_all_dac
  # Free AIF4/ESS Bypass, bounce AF, restore user HiFi — before USB (adb may die)
  restore_stock_playback
  restore_volume
  restore_usb_notifications
  # Mark idle BEFORE USB rebind so a killed adb session cannot leave state=live
  set_phase "idle"
  write_status_json
  # May drop adb — audio/HiFi already restored above
  restore_stock_usb
  do_status
  release_disable_lock
  trap - EXIT
}

disable_is_done() {
  case "$(cat "$STATE" 2>/dev/null)" in idle|disabled) ;; *) return 1 ;; esac
  [ ! -f "$WANT" ] || return 1
  [ ! -f "$USB_NOTIFY_SAVE" ] || return 1
  bridge_alive && return 1
  kernel_direct_enabled && return 1
  return 0
}

release_disable_lock() {
  [ "$(cat "$DISABLE_LOCK/pid" 2>/dev/null)" = "$$" ] || return 0
  rm -f "$DISABLE_LOCK/pid"
  rmdir "$DISABLE_LOCK" 2>/dev/null || true
}

# PID existence alone is insufficient: after a crash it may have been reused.
valid_disable_owner() {
  owner_pid=$1
  [ -r "/proc/$owner_pid/cmdline" ] || return 1
  owner_cmd=$(tr '\000' '\n' <"/proc/$owner_pid/cmdline" 2>/dev/null)
  printf '%s\n' "$owner_cmd" | grep -Eq '(^|/)usb_dac_ctl\.sh$' || return 1
  printf '%s\n' "$owner_cmd" | grep -Eq '^(disable|off|stop)$'
}

# Only remove the known PID marker, then rmdir; never recursively delete a
# lock directory that another process may currently own.
remove_stale_disable_lock() {
  stale_pid=$(cat "$DISABLE_LOCK/pid" 2>/dev/null)
  if [ -n "$stale_pid" ] && valid_disable_owner "$stale_pid"; then
    return 1
  fi
  rm -f "$DISABLE_LOCK/pid" 2>/dev/null
  rmdir "$DISABLE_LOCK" 2>/dev/null
}

acquire_disable_lock() {
  attempts=0
  while [ "$attempts" -lt 300 ]; do
    if mkdir "$DISABLE_LOCK" 2>/dev/null; then
      if ! printf '%s\n' "$$" >"$DISABLE_LOCK/pid"; then
        rmdir "$DISABLE_LOCK" 2>/dev/null || true
        return 1
      fi
      return 0
    fi
    remove_stale_disable_lock && continue
    disable_is_done && return 2
    sleep 0.2
    attempts=$((attempts + 1))
  done
  log "DISABLE lock timeout owner=$(cat "$DISABLE_LOCK/pid" 2>/dev/null)"
  return 1
}

do_restart_bridge() {
  [ -f "$WANT" ] || bridge_alive || kernel_direct_enabled || { do_status; exit 1; }
  old_bridge=$(actual_bridge)
  . "$CONF" 2>/dev/null
  MODE=${MODE:-b}
  case "$MODE" in a|A|exclusive) MODE=a ;; *) MODE=b ;; esac
  log "restart-bridge mode=$MODE (replacing supervisor)"
  # Stop the old supervisor first: it owns a fixed mode argument from launch.
  rm -f "$WANT"
  if [ -f "$SUPF" ]; then
    old_sup=$(cat "$SUPF" 2>/dev/null)
    [ -n "$old_sup" ] && kill -TERM "$old_sup" 2>/dev/null
    i=0
    while [ $i -lt 15 ] && [ -n "$old_sup" ] && kill -0 "$old_sup" 2>/dev/null; do
      sleep 0.2
      i=$((i + 1))
    done
    [ -n "$old_sup" ] && kill -KILL "$old_sup" 2>/dev/null
  fi
  killall -9 usb_dac_aaudio usb_dac_bridge usb_dac_pcm tinycap tinyplay volkey_block 2>/dev/null
  pkill -f 'route_keepalive.sh' 2>/dev/null
  [ -f "$UDD_EN" ] && echo 0 >"$UDD_EN" 2>/dev/null
  rm -f "$PIDF" "$HB" "$SUPF" "$BASE/ka.pid"
  sleep 0.3
  # Mode B's AAudio client leaves the HAL/DAPM headphone graph active. Reset
  # audioserver after that client is gone so Mode A can establish both RX
  # channels from a clean graph before opening the kernel PCM.
  if [ "$MODE" = "a" ] && [ "$old_bridge" = "aaudio" ]; then
    log "Mode B AAudio -> Mode A: rebuilding audio HAL before stereo route"
    stop_audio_stack
    start_audio_stack
    sleep 1
  fi
  touch "$WANT"
  set_phase "start-bridge"
  sh "$SCR/usb_dac_ctl.sh" __supervisor "$MODE" >>"$LOG" 2>&1 &
  echo $! >"$SUPF"
  # The new supervisor sets up the selected mode on the existing UAC gadget.
  do_status
}

set_conf() {
  key=$1; val=$2
  if [ "$key" = "MODE" ]; then
    case "$val" in
      a|A|exclusive|mode-a) val=a ;;
      b|B|shared|mode-b) val=b ;;
    esac
  fi
  if grep -q "^${key}=" "$CONF"; then
    sed -i "s|^${key}=.*|${key}=${val}|" "$CONF"
  else
    echo "${key}=${val}" >>"$CONF"
  fi
  echo "${key}=${val}"
  write_status_json
}

set_mode() {
  val=$1
  set_conf MODE "$val"
  if [ -f "$WANT" ] || bridge_alive || kernel_direct_enabled; then
    do_restart_bridge
  else
    do_status
  fi
}

do_mixer_capture() {
  # Never dump tinymix while Mode A holds PCM — Qualcomm mixer lock freeze.
  if kernel_direct_enabled || pgrep -f 'usb_dac_bridge|usb_dac_pcm' >/dev/null 2>&1; then
    log "mixer-capture REFUSED (Mode A bridge running — disable first)"
    echo "ERROR: 请先关闭 USB DAC，用系统播放器+耳机播歌后再点「捕获混音器」"
    write_status_json
    do_status
    return 3
  fi
  sh "$SCR/mixer_profile_capture.sh"
  rc=$?
  write_status_json
  do_status
  return $rc
}

do_mixer_apply() {
  if kernel_direct_enabled || pgrep -f 'usb_dac_bridge|usb_dac_pcm' >/dev/null 2>&1; then
    log "mixer-apply REFUSED (Mode A bridge running)"
    echo "ERROR: 请先关闭 Mode A 再应用混音器（或启用时会自动 apply）"
    return 3
  fi
  sh "$SCR/mixer_profile_apply.sh"
}

if [ "$cmd" = "__supervisor" ]; then
  USB_DAC_QUIET=1; export USB_DAC_QUIET
  trap '' HUP PIPE
  supervisor_loop "${2:-b}"
  exit 0
fi
if [ "$cmd" = "__enable_worker" ]; then
  USB_DAC_QUIET=1; export USB_DAC_QUIET
  trap '' HUP PIPE
  enable_inner
  rm -f "$ENABLING" "$WORKER"
  exit $?
fi

case "$cmd" in
  enable|on|start) do_enable ;;
  disable|off|stop) do_disable ;;
  status) do_status ;;
  restart-bridge|rearm) do_restart_bridge ;;
  hifi) do_hifi; do_status ;;
  ask-on) set_conf ASK_ON_USB 1; do_status ;;
  ask-off) set_conf ASK_ON_USB 0; do_status ;;
  restore-usb-notifications) restore_usb_notifications ;;
  hifi-on) set_conf FORCE_HIFI 1; do_status ;;
  hifi-off) set_conf FORCE_HIFI 0; do_status ;;
  mode-a|mode-a-low|a|exclusive) set_mode a ;;
  mode-b|mode-b-hifi|b|shared) set_mode b ;;
  mode-shared) set_mode b ;;
  mode-exclusive) set_mode a ;;
  mixer-capture|capture-mixer) do_mixer_capture ;;
  mixer-apply) do_mixer_apply; do_status ;;
  test-hal-pcm|test-mixer-pcm)
    sh "$SCR/test_hal_mixer_pcm.sh"
    ;;
  *)
    echo "usage: enable|disable|status|mode-a|mode-b|mixer-capture|mixer-apply|test-hal-pcm|…"
    exit 1
    ;;
esac
