#!/system/bin/sh
# Lightweight FE→BE route for Mode A. NO dumpsys (hangs on 2nd enable / USB flap).
MODDIR=${MODDIR:-/data/adb/modules/usb_dac_manager}
TINYMIX=$MODDIR/bin/tinymix
[ -x "$TINYMIX" ] || TINYMIX=$(command -v tinymix)
LOG=/data/adb/usb_dac/ctl.log
CARD=${1:-1}
OK=0
FAIL=0

log() { echo "route: $*" | tee -a "$LOG"; }
[ -x "$TINYMIX" ] || { log "no tinymix"; exit 0; }
log "card=$CARD tinymix=$TINYMIX"

TM_SET=0
if "$TINYMIX" -D "$CARD" get "Es9218 Bypass" >/dev/null 2>&1; then
  TM_SET=1
elif "$TINYMIX" -h 2>&1 | grep -q 'set NAME'; then
  TM_SET=1
fi
log "tinymix_set_api=$TM_SET"

mix() {
  ctl=$1
  shift
  if [ "$TM_SET" = "1" ]; then
    if "$TINYMIX" -D "$CARD" set "$ctl" "$@" >/dev/null 2>&1; then
      OK=$((OK + 1)); return 0
    fi
  else
    if "$TINYMIX" -D "$CARD" "$ctl" "$@" >/dev/null 2>&1; then
      OK=$((OK + 1)); return 0
    fi
  fi
  FAIL=$((FAIL + 1))
  return 1
}

# Jack: sysfs only (never dumpsys — blocks for minutes / freezes WebUI)
HS=0
HT=0
[ -f /sys/kernel/es9218_dac/headset_type ] && HT=$(cat /sys/kernel/es9218_dac/headset_type 2>/dev/null)
[ -n "$HT" ] && [ "$HT" != "0" ] && HS=1
[ -f /sys/class/switch/h2w/state ] && [ "$(cat /sys/class/switch/h2w/state 2>/dev/null)" != "0" ] && HS=1
FH=$(grep '^FORCE_HIFI=' /data/adb/usb_dac/config 2>/dev/null | cut -d= -f2)
log "headset_guess=$HS ht=$HT force_hifi=$FH"

# MM1 + MM2 → SLIM / TERT_TDM (BOOL×2 → 1 1)
mix "SLIMBUS_0_RX Audio Mixer MultiMedia1" 1 1
mix "SLIMBUS_0_RX Audio Mixer MultiMedia2" 1 1
mix "TERT_TDM_RX_0 Audio Mixer MultiMedia1" 1 1
mix "TERT_TDM_RX_0 Audio Mixer MultiMedia2" 1 1
mix "QUAT_MI2S_RX Audio Mixer MultiMedia1" 1 1
mix "QUAT_MI2S_RX Audio Mixer MultiMedia2" 1 1
mix "PRI_RX Audio Mixer MultiMedia1" 1
mix "PRI_RX Audio Mixer MultiMedia2" 1 1

mix "SLIM RX0 MUX" "AIF1_PB"
mix "SLIM RX1 MUX" "AIF1_PB"
mix "SLIM RX2 MUX" "AIF2_PB"
mix "SLIM RX3 MUX" "AIF2_PB"

mix "RX INT1_1 MIX1 INP0" "RX0"
mix "RX INT2_1 MIX1 INP0" "RX1"
mix "RX INT1 DEM MUX" "CLSH_DSM_OUT"
mix "RX INT2 DEM MUX" "CLSH_DSM_OUT"
mix "RX0 Digital Volume" 84
mix "RX1 Digital Volume" 84
mix "HPHL Volume" 12
mix "HPHR Volume" 12

if [ "$FH" = "1" ] && [ "$HS" = "1" ]; then
  case "$HT" in 0|"") echo 1 >/sys/kernel/es9218_dac/headset_type 2>/dev/null ;; esac
  mix "Es9018 HEADSET TYPE" 1
  mix "Es9018 AVC Volume" 14
  mix "Es9018 Master Volume" 0
  mix "HiFi Function" "On"
  mix "Es9018 State" "Hifi"
  log "ESS Hifi (FORCE_HIFI=1 + jack)"
else
  log "skip ESS Hifi (force_hifi=$FH jack=$HS)"
fi

log "done ok=$OK fail=$FAIL"
exit 0
