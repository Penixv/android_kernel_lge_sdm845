#!/system/bin/sh
# Force LG G7 ESS9218P Quad DAC path (wired headphones only).
# Speakers never go through ESS.

MODDIR=${MODDIR:-/data/adb/modules/usb_dac_manager}
TINYMIX=$MODDIR/bin/tinymix
[ -x "$TINYMIX" ] || TINYMIX=$(command -v tinymix)
LOG=/data/adb/usb_dac/ctl.log

log() { echo "hifi: $*" | tee -a "$LOG"; }

# Prefer Lineage / LG properties
setprop persist.vendor.audio.hifi.enabled 1 2>/dev/null
setprop persist.vendor.lge.audio.hifi_dac true 2>/dev/null
setprop vendor.audio.hifi.enabled 1 2>/dev/null
settings put global hifi_dac 1 2>/dev/null
settings put system hifi_mode 1 2>/dev/null

# Sysfs — do not overwrite non-zero headset_type (2=hi-z is valid)
ESS=/sys/kernel/es9218_dac
if [ -d "$ESS" ]; then
  if [ -f "$ESS/headset_type" ]; then
    cur=$(cat "$ESS/headset_type" 2>/dev/null)
    [ "$cur" = "0" ] || [ -z "$cur" ] && echo 1 >"$ESS/headset_type" 2>/dev/null
  fi
  log "sysfs $ESS ht=$(cat $ESS/headset_type 2>/dev/null)"
else
  log "no $ESS (ROM/kernel may still route via HAL props)"
fi

mix_set() {
  card=$1
  shift
  if "$TINYMIX" -D "$card" set "$@" >/dev/null 2>&1; then
    log "ok card=$card set $*"
    return 0
  fi
  # legacy tinymix
  if "$TINYMIX" -D "$card" "$@" >/dev/null 2>&1; then
    log "ok card=$card (legacy) $*"
    return 0
  fi
  return 1
}

# Mixer: Es9018 State=Hifi exits BYPASS (Bypass BOOL alone is ignored/rejected)
if [ -x "$TINYMIX" ]; then
  for card in 1 0 2; do
    mix_set "$card" "Es9018 AVC Volume" 14
    mix_set "$card" "Es9018 Master Volume" 0
    mix_set "$card" "HiFi Function" "On"
    mix_set "$card" "TERT_TDM_RX_0 Audio Mixer MultiMedia1" 1 1
    mix_set "$card" "Es9018 State" "Hifi"
  done
else
  log "tinymix missing — props/sysfs only"
fi

media volume --stream 3 --get >/dev/null 2>&1
log "done — plug wired headphones for ESS path"
