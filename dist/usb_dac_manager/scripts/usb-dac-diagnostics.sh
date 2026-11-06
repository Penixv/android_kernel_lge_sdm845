#!/system/bin/sh
# usb-dac-diagnostics.sh — READ-ONLY diagnostics for Mode A no-sound.
# Does NOT: change mixer, restart audio, alter USB gadget, clear logs, setenforce.
#
# Usage (on device, root):
#   sh /data/adb/modules/usb_dac_manager/scripts/usb-dac-diagnostics.sh
# Or:
#   adb shell su -c 'sh /data/adb/modules/usb_dac_manager/scripts/usb-dac-diagnostics.sh'
#
OUT_ROOT=/data/local/tmp/usb_dac_diag
TS=$(date +%Y%m%d_%H%M%S 2>/dev/null || echo now)
OUT="$OUT_ROOT/$TS"
mkdir -p "$OUT" || OUT=/sdcard/usb_dac_diag_$TS && mkdir -p "$OUT"

log() { echo "$*" | tee -a "$OUT/00_summary.txt"; }

run() {
  name=$1
  shift
  echo "=== $* ===" >"$OUT/$name.txt"
  "$@" >>"$OUT/$name.txt" 2>&1
  echo "saved $name.txt"
}

log "USB DAC diagnostics (READ-ONLY) $TS"
log "out=$OUT"

# --- identity ---
{
  echo "date=$(date 2>/dev/null)"
  uname -a 2>/dev/null
  getprop ro.product.device 2>/dev/null
  getprop ro.product.model 2>/dev/null
  getprop ro.build.fingerprint 2>/dev/null
  getprop ro.build.version.release 2>/dev/null
} >"$OUT/01_identity.txt"

# --- ALSA cards / pcm / nodes ---
cat /proc/asound/cards >"$OUT/02_asound_cards.txt" 2>&1
cat /proc/asound/pcm >"$OUT/03_asound_pcm.txt" 2>&1
ls -l /dev/snd/ >"$OUT/04_dev_snd.txt" 2>&1
ls -l /proc/asound/ >"$OUT/05_proc_asound.txt" 2>&1

# Per-card info if present
i=0
while [ $i -lt 8 ]; do
  if [ -d "/proc/asound/card$i" ]; then
    {
      echo "=== card$i ==="
      ls -l "/proc/asound/card$i" 2>/dev/null
      cat "/proc/asound/card$i/id" 2>/dev/null
      for s in "/proc/asound/card$i"/pcm*p/sub0/hw_params \
               "/proc/asound/card$i"/pcm*c/sub0/hw_params \
               "/proc/asound/card$i"/pcm*p/sub0/status \
               "/proc/asound/card$i"/pcm*c/sub0/status; do
        for f in $s; do
          [ -f "$f" ] || continue
          echo "--- $f ---"
          cat "$f" 2>/dev/null
        done
      done
    } >>"$OUT/06_card_detail.txt" 2>&1
  fi
  i=$((i + 1))
done

# --- UDC / gadget (read only) ---
ls -l /sys/class/udc/ >"$OUT/10_udc.txt" 2>&1
ls -l /config/usb_gadget/ >"$OUT/11_gadget_root.txt" 2>&1
ls -l /sys/kernel/config/usb_gadget/ >"$OUT/11b_sys_gadget.txt" 2>&1
for g in /config/usb_gadget/* /sys/kernel/config/usb_gadget/*; do
  [ -d "$g" ] || continue
  {
    echo "=== $g ==="
    echo -n "UDC="; cat "$g/UDC" 2>/dev/null; echo
    echo -n "idVendor="; cat "$g/idVendor" 2>/dev/null; echo
    echo -n "idProduct="; cat "$g/idProduct" 2>/dev/null; echo
    echo -n "product="; cat "$g/strings/0x409/product" 2>/dev/null; echo
    ls -la "$g/configs" 2>/dev/null
    for c in "$g/configs"/*; do
      [ -d "$c" ] || continue
      echo "config $c:"
      ls -la "$c" 2>/dev/null
    done
    ls -la "$g/functions" 2>/dev/null
    if [ -d "$g/functions/uac2.0" ]; then
      echo "uac2.0 attrs:"
      for a in c_chmask c_srate c_ssize p_chmask p_srate p_ssize; do
        echo -n "  $a="; cat "$g/functions/uac2.0/$a" 2>/dev/null; echo
      done
    fi
  } >>"$OUT/12_gadget_detail.txt" 2>&1
done

# USB props (read)
{
  echo "sys.usb.config=$(getprop sys.usb.config)"
  echo "sys.usb.state=$(getprop sys.usb.state)"
  echo "persist.sys.usb.config=$(getprop persist.sys.usb.config)"
  echo "sys.usb.controller=$(getprop sys.usb.controller)"
  echo "sys.usb.configfs=$(getprop sys.usb.configfs)"
  echo "sys.usb.ffs.ready=$(getprop sys.usb.ffs.ready)"
} >"$OUT/13_usb_props.txt"

# --- dmesg slice (does not clear) ---
dmesg 2>/dev/null | grep -iE 'usb|uac|gadget|audio|alsa|snd|q6|dsp|es9218|i2s|dwc3|configfs' | tail -n 200 >"$OUT/20_dmesg_audio.txt"

# --- Android audio dumps (read) ---
dumpsys media.audio_flinger >"$OUT/30_audio_flinger.txt" 2>&1
dumpsys media.audio_policy >"$OUT/31_audio_policy.txt" 2>&1
dumpsys audio >"$OUT/32_dumpsys_audio.txt" 2>&1

# --- tinymix READ ONLY (list / contents — no set) ---
MODDIR=/data/adb/modules/usb_dac_manager
TINYMIX=
[ -x "$MODDIR/bin/tinymix" ] && TINYMIX=$MODDIR/bin/tinymix
[ -z "$TINYMIX" ] && TINYMIX=$(command -v tinymix 2>/dev/null)
if [ -n "$TINYMIX" ] && [ -x "$TINYMIX" ]; then
  CARD=$(awk '/tavil|sdm845-tavil/{print $1; exit}' /proc/asound/cards 2>/dev/null)
  [ -n "$CARD" ] || CARD=1
  echo "tinymix card=$CARD" >"$OUT/40_tinymix_meta.txt"
  "$TINYMIX" -D "$CARD" controls >"$OUT/41_tinymix_list.txt" 2>&1
  "$TINYMIX" -D "$CARD" contents >"$OUT/42_tinymix_contents.txt" 2>&1
else
  echo "tinymix not found" >"$OUT/40_tinymix_meta.txt"
fi

if command -v tinypcminfo >/dev/null 2>&1; then
  tinypcminfo >"$OUT/43_tinypcminfo.txt" 2>&1
fi

# --- ESS sysfs read ---
{
  ls -la /sys/kernel/es9218_dac 2>/dev/null
  for f in /sys/kernel/es9218_dac/*; do
    [ -f "$f" ] || continue
    echo -n "$f="; cat "$f" 2>/dev/null; echo
  done
  getprop persist.vendor.audio.hifi.enabled 2>/dev/null
  getprop persist.vendor.lge.audio.hifi_dac 2>/dev/null
  getprop vendor.audio.hifi.enabled 2>/dev/null
} >"$OUT/50_ess_sysfs.txt" 2>&1

# Headset jack guess (read)
{
  for f in /sys/class/switch/h2w/state \
           /sys/devices/virtual/switch/h2w/state \
           /sys/kernel/debug/gpio; do
    [ -e "$f" ] || continue
    echo -n "$f="; cat "$f" 2>/dev/null | head -c 200; echo
  done
} >"$OUT/51_headset.txt" 2>&1

# --- module / bridge state (read) ---
{
  echo "=== /data/adb/usb_dac ==="
  ls -la /data/adb/usb_dac 2>/dev/null
  echo "=== state ==="; cat /data/adb/usb_dac/state 2>/dev/null; echo
  echo "=== config ==="; cat /data/adb/usb_dac/config 2>/dev/null; echo
  echo "=== status.json ==="; cat /data/adb/usb_dac/status.json 2>/dev/null; echo
  echo "=== hb ==="; cat /data/adb/usb_dac/hb 2>/dev/null; echo
  echo "=== ctl.log tail ==="; tail -n 80 /data/adb/usb_dac/ctl.log 2>/dev/null
  echo "=== processes ==="
  ps -A 2>/dev/null | grep -iE 'usb_dac|tinycap|tinyplay|audioserver' || true
  pgrep -af 'usb_dac|tinycap|tinyplay' 2>/dev/null || true
} >"$OUT/60_module_state.txt" 2>&1

# Identify UAC capture card/device candidates (parse only)
{
  echo "# Candidate cards from /proc/asound/cards + pcm"
  echo "## cards"
  cat /proc/asound/cards 2>/dev/null
  echo "## pcm (c=capture p=playback)"
  cat /proc/asound/pcm 2>/dev/null
  echo
  echo "# Heuristic: UAC/Gadget capture lines"
  grep -iE 'UAC|Gadget|uac' /proc/asound/cards /proc/asound/pcm 2>/dev/null || true
  echo
  echo "# Heuristic: tavil playback"
  grep -iE 'tavil|sdm845' /proc/asound/cards /proc/asound/pcm 2>/dev/null || true
  echo
  echo "# NOTE: This script does NOT run tinycap/tinyplay (would open PCM)."
  echo "# For stage-2 capture test (manual, after review):"
  echo "#   Identify CARD/DEV from 03_asound_pcm.txt then:"
  echo "#   tinycap /data/local/tmp/uac2_cap.wav -D CARD -d DEV -c 2 -r 48000 -b 16 -T 5"
} >"$OUT/70_pcm_candidates.txt"

# Pack list
ls -la "$OUT" >"$OUT/99_index.txt"
log "DONE files in $OUT"
log "Pull with: adb pull $OUT ."
echo "$OUT"
