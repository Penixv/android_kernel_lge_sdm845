#!/system/bin/sh
# Exclusive bridge: tinycap (UAC) | tinyplay (tavil)
# Args: <uac_card> <play_card> [rate] [ch]
MODDIR=${MODDIR:-/data/adb/modules/usb_dac_manager}
BIN=$MODDIR/bin
SCR=$MODDIR/scripts
LOG=/data/adb/usb_dac/ctl.log
HB=/data/adb/usb_dac/hb
PIDF=/data/adb/usb_dac/bridge.pid

UAC=${1:?}
PLAY=${2:?}
RATE=${3:-48000}
CH=${4:-2}
PERIOD=480
NPER=8

CAP=$BIN/tinycap
PLAYBIN=$BIN/tinyplay
PCM=$BIN/usb_dac_pcm
[ -x "$CAP" ] || CAP=$(command -v tinycap)
[ -x "$PLAYBIN" ] || PLAYBIN=$(command -v tinyplay)

log() { echo "$(date '+%H:%M:%S') excl: $*" >>"$LOG"; echo "excl: $*"; }

trap 'kill $CAP_PID $PLAY_PID $PCM_PID $HB_PID 2>/dev/null; exit 0' INT TERM HUP

hb_loop() {
  n=0
  while kill -0 "$1" 2>/dev/null; do
    n=$((n + PERIOD))
    echo "mode=exclusive
bridge=tinycap
alive=1
frames=$n
ts=$(date +%s)" >"$HB.tmp"
    mv "$HB.tmp" "$HB"
    sleep 1
  done
}

sh "$SCR/route_playback.sh" "$PLAY" >>"$LOG" 2>&1

# Prefer dedicated pcm binary if present (same process, better accounting)
if [ -x "$PCM" ]; then
  log "try usb_dac_pcm UAC=$UAC PLAY=$PLAY"
  "$PCM" "$UAC" "$PLAY" 0 "$RATE" "$CH" 16 >>"$LOG" 2>&1 &
  PCM_PID=$!
  echo $PCM_PID >"$PIDF"
  sleep 2
  if kill -0 "$PCM_PID" 2>/dev/null; then
    log "pcm bridge up pid=$PCM_PID"
    wait "$PCM_PID"
    log "pcm bridge exit $?"
    exit $?
  fi
  log "pcm died immediately — fall back tinycap|tinyplay"
  kill -9 "$PCM_PID" 2>/dev/null
fi

if [ ! -x "$CAP" ] || [ ! -x "$PLAYBIN" ]; then
  log "ERROR need tinycap+tinyplay in $BIN"
  exit 2
fi

log "tinycap -D $UAC | tinyplay -D $PLAY  ${RATE}Hz ${CH}ch p=$PERIOD n=$NPER"
# shell pipeline: capture exit of either
"$CAP" -D "$UAC" -d 0 -c "$CH" -r "$RATE" -b 16 -p "$PERIOD" -n "$NPER" 2>>"$LOG" \
  | "$PLAYBIN" -D "$PLAY" -d 0 -c "$CH" -r "$RATE" -b 16 -p "$PERIOD" -n "$NPER" 2>>"$LOG" &
PIPE_PID=$!
echo $PIPE_PID >"$PIDF"
hb_loop "$PIPE_PID" &
HB_PID=$!
wait "$PIPE_PID"
rc=$?
kill "$HB_PID" 2>/dev/null
log "pipe exit $rc"
exit $rc
