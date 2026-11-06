#!/system/bin/sh
# Mode A headphone path (judyln / tavil / SLIMBUS_6 / ESS Bypass):
#   MM1 → SLIM6 (2ch) → AIF4 → RX0/RX1 → INT*_1 → HPH → ESS Bypass
#
# Critical: stock slim_rx_cfg[SLIM_RX_6].channels defaults to 1 → left-only.
# Set "SLIM_6_RX Channels" = Two BEFORE opening MultiMedia1.
# Call FE mixer ONLY when MultiMedia1 PCM is closed (SKIP_FE=1 while live).
MODDIR=${MODDIR:-/data/adb/modules/usb_dac_manager}
TINYMIX=$MODDIR/bin/tinymix
[ -x "$TINYMIX" ] || TINYMIX=$(command -v tinymix)
LOG=/data/adb/usb_dac/ctl.log
CARD=${1:-1}
SKIP_FE=${SKIP_FE:-0}

log() { echo "route_mm1_slim6: $*" >>"$LOG"; }
[ -x "$TINYMIX" ] || { log "no tinymix"; exit 1; }

setc() {
  ctl=$1; shift
  if "$TINYMIX" -D "$CARD" set "$ctl" "$@" >/dev/null 2>&1; then
    log "ok: $ctl $*"
    return 0
  fi
  log "fail: $ctl $*"
  return 1
}

require_set() {
  if ! setc "$@"; then
    log "required stereo route failed; refusing to start mono playback"
    exit 1
  fi
}

log "card=$CARD skip_fe=$SKIP_FE"

# MUST be stereo BE — One = silent right ear (not a PCM copy issue)
if ! setc "SLIM_6_RX Channels" "Two"; then
  log "stereo channel setup failed; refusing mono route"
  exit 1
fi
stereo_state=$("$TINYMIX" -D "$CARD" get "SLIM_6_RX Channels" 2>/dev/null)
case "$stereo_state" in
  *Two*) ;;
  *)
    log "stereo channel readback failed: $stereo_state"
    exit 1
    ;;
esac
log "verified SLIM_6_RX Channels=Two"
setc "SLIM_6_RX SampleRate" "KHZ_48" || true
setc "SLIM_6_RX Format" "S16_LE" || true

if [ "$SKIP_FE" != "1" ]; then
  setc "SLIMBUS_6_RX Audio Mixer MultiMedia1" 1 1 || setc "SLIMBUS_6_RX Audio Mixer MultiMedia1" 1
fi

# Stereo slots: L=RX0 R=RX1 on AIF4_PB
require_set "SLIM RX0 MUX" "AIF4_PB"
require_set "SLIM RX1 MUX" "AIF4_PB"
setc "SLIM RX2 MUX" "ZERO" || true
setc "SLIM RX3 MUX" "ZERO" || true
require_set "CDC_IF RX0 MUX" "SLIM RX0"
require_set "CDC_IF RX1 MUX" "SLIM RX1"
setc "CDC_IF RX2 MUX" "SLIM RX2" || true
setc "CDC_IF RX3 MUX" "SLIM RX3" || true

# Kill secondary path (hum when AF half-enables it)
setc "RX INT1_2 MUX" "ZERO" || true
setc "RX INT2_2 MUX" "ZERO" || true
setc "RX INT1_2 INTERP" "ZERO" || true
setc "RX INT2_2 INTERP" "ZERO" || true
setc "RX INT1 SEC MIX HPHL Switch" 0 || true
setc "RX INT2 SEC MIX HPHR Switch" 0 || true

# Primary interpolators L=RX0 R=RX1
require_set "RX INT1_1 MIX1 INP0" "RX0"
require_set "RX INT2_1 MIX1 INP0" "RX1"
setc "RX INT1_1 MIX1 INP1" "ZERO" || true
setc "RX INT2_1 MIX1 INP1" "ZERO" || true
require_set "RX INT1_1 INTERP" "RX INT1_1 MIX1"
require_set "RX INT2_1 INTERP" "RX INT2_1 MIX1"
setc "RX INT1 DEM MUX" "CLSH_DSM_OUT" || true
setc "RX INT2 DEM MUX" "CLSH_DSM_OUT" || true

setc "RX HPH Mode" "CLS_AB_HIFI" || setc "RX HPH Mode" "CLS_H_HIFI" || true
setc "COMP1 Switch" 0 || true
setc "COMP2 Switch" 0 || true

# DIG must be >=84 on tavil — tinymix set <84 stores as 256+v and skews L/R.
HPH=${MODE_A_HPH:-16}
DIG=${MODE_A_DIG:-84}
ESS=${MODE_A_ESS_VOL:-180}
require_set "HPHL Volume" "$HPH"
require_set "HPHR Volume" "$HPH"
setc "RX0 Digital Volume" "$DIG" || true
setc "RX1 Digital Volume" "$DIG" || true

echo 1 >/sys/kernel/es9218_dac/headset_type 2>/dev/null
setc "Es9018 HEADSET TYPE" 1 || true
setc "Es9018 Left Volume" "$ESS" || true
setc "Es9018 Right Volume" "$ESS" || true
setc "Es9018 AVC Volume" 10 || true
setc "Es9218 Bypass" 1 || true
setc "Es9018 State" "Bypass" || true
# Final L/R match (AF may have touched mid-script)
setc "RX0 Digital Volume" "$DIG" || true
setc "RX1 Digital Volume" "$DIG" || true
setc "HPHL Volume" "$HPH"
setc "HPHR Volume" "$HPH"
setc "SLIM RX2 MUX" "ZERO" || true
setc "SLIM RX3 MUX" "ZERO" || true
setc "RX INT1_2 MUX" "ZERO" || true
setc "RX INT2_2 MUX" "ZERO" || true
log "done hph=$HPH dig=$DIG ess=$ESS slim6ch=Two"
exit 0


