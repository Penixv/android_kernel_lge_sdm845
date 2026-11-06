#!/system/bin/sh
# Apply ONLY active FE→BE bits from a captured profile (or known LG PowerAmp path).
# Avoids full 3000-line tinymix apply (hangs / USB flap).
MODDIR=${MODDIR:-/data/adb/modules/usb_dac_manager}
TINYMIX=$MODDIR/bin/tinymix
[ -x "$TINYMIX" ] || TINYMIX=$(command -v tinymix)
PROF=${1:-/data/adb/usb_dac/mixer_profile.txt}
LOG=/data/adb/usb_dac/ctl.log
CARD=$(awk '/tavil|sdm845-tavil/{print $1; exit}' /proc/asound/cards 2>/dev/null)
[ -n "$CARD" ] || CARD=1

log() { echo "route_min: $*" | tee -a "$LOG"; }
[ -x "$TINYMIX" ] || { log "no tinymix"; exit 1; }

mix() {
  ctl=$1; shift
  if "$TINYMIX" -D "$CARD" set "$ctl" "$@" >/dev/null 2>&1 || \
     "$TINYMIX" -D "$CARD" "$ctl" "$@" >/dev/null 2>&1; then
    log "ok: $ctl $*"
    return 0
  fi
  log "fail: $ctl $*"
  return 1
}

log "card=$CARD prof=$PROF"

# 1) From profile: every "Audio Mixer MultiMedia* ... On"
if [ -f "$PROF" ]; then
  grep "Audio Mixer MultiMedia" "$PROF" | grep On | while IFS= read -r line; do
    name=$(echo "$line" | sed -n 's/^[[:space:]]*[0-9]*[[:space:]]*[A-Z]*[[:space:]]*[0-9]*[[:space:]]*\(.*\)[[:space:]]\{1\}0On.*/\1/p' | sed 's/[[:space:]]*$//')
    [ -n "$name" ] || continue
    # BOOL×2 often needs "1 1" or "On On"; try On first then 1 1
    mix "$name" On On 2>/dev/null || mix "$name" 1 1 2>/dev/null || mix "$name" On || mix "$name" 1
  done
fi

# 2) Known PowerAmp / LG path fallback (seen live)
mix "SLIMBUS_6_RX Audio Mixer MultiMedia1" 1 1 || mix "SLIMBUS_6_RX Audio Mixer MultiMedia1" On On
mix "SLIM RX2 MUX" "AIF4_PB"
mix "SLIM RX3 MUX" "AIF4_PB"

# 3) HPH volumes (safe)
mix "HPHL Volume" 20
mix "HPHR Volume" 20

# 4) Do NOT touch Es9018 State / HiFi Function — system owns those; tinymix often lies Bypass while settings hifi_dac=1

log "done"
exit 0
