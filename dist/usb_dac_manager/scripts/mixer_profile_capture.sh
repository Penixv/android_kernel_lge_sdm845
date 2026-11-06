#!/system/bin/sh
# Capture tavil mixer while system music plays through headphones.
# MUST NOT run while Mode A bridge holds MultiMedia1 — tinymix contents
# deadlocks on Qualcomm ASoC mixer lock (whole device freeze).
MODDIR=${MODDIR:-/data/adb/modules/usb_dac_manager}
TINYMIX=$MODDIR/bin/tinymix
[ -x "$TINYMIX" ] || TINYMIX=$(command -v tinymix)
OUT=/data/adb/usb_dac/mixer_profile.txt
TMP=/data/adb/usb_dac/mixer_profile.txt.tmp
LOG=/data/adb/usb_dac/ctl.log
mkdir -p /data/adb/usb_dac

CARD=$(awk '/tavil|sdm845-tavil/{print $1; exit}' /proc/asound/cards 2>/dev/null)
[ -n "$CARD" ] || CARD=1

log() { echo "mixer_capture: $*" | tee -a "$LOG"; }

mode_a_bridge() {
  pgrep -f 'usb_dac_bridge' >/dev/null 2>&1 && return 0
  pgrep -f 'usb_dac_pcm' >/dev/null 2>&1 && return 0
  if [ -f /data/adb/usb_dac/status.json ]; then
    grep -qE '"mode_a_active": *1|"exclusive_active": *1|"mode_actual": *"pcm' \
      /data/adb/usb_dac/status.json 2>/dev/null && return 0
  fi
  return 1
}

if mode_a_bridge; then
  log "REFUSED — Mode A bridge running. Disable DAC, play music + headset, then capture."
  echo "ERROR: 请先关闭 USB DAC，再用系统播放器+耳机播歌后捕获（Mode A 下 tinymix 会卡死）"
  exit 3
fi

log "card=$CARD -> $OUT"
[ -x "$TINYMIX" ] || { log "no tinymix"; exit 1; }

rm -f "$TMP"
(
  echo "# usb_dac mixer profile $(date)"
  echo "# card=$CARD"
  echo "# Mode A OFF + wired headset + system music"
  "$TINYMIX" -D "$CARD" contents
) >"$TMP" 2>>"$LOG" &
pid=$!
i=0
while [ $i -lt 15 ]; do
  kill -0 "$pid" 2>/dev/null || break
  sleep 1
  i=$((i + 1))
done
if kill -0 "$pid" 2>/dev/null; then
  log "TIMEOUT — killing tinymix (pid=$pid)"
  kill -9 "$pid" 2>/dev/null
  pkill -9 -f "tinymix -D ${CARD} contents" 2>/dev/null
  wait "$pid" 2>/dev/null
  rm -f "$TMP"
  echo "ERROR: tinymix contents timed out"
  exit 4
fi
wait "$pid"

[ -f "$TMP" ] || { log "no output"; exit 2; }
lines=$(wc -l <"$TMP" 2>/dev/null || echo 0)
if [ "$lines" -lt 20 ]; then
  log "too few lines ($lines)"
  rm -f "$TMP"
  exit 2
fi
mv "$TMP" "$OUT"
log "wrote $lines lines"
exit 0
