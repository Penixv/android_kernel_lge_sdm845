#!/system/bin/sh
# Soft keepalive: lock Android media vol; aggressively kill AF hum path.
MODDIR=${MODDIR:-/data/adb/modules/usb_dac_manager}
LOG=/data/adb/usb_dac/ctl.log
PIDF=/data/adb/usb_dac/ka.pid
WANT=/data/adb/usb_dac/want_enabled
BPID=/data/adb/usb_dac/bridge.pid
UDD_EN=/sys/kernel/usb_dac_direct/enable
VOL=${MODE_A_LOCK_VOL:-10}
HPH=${MODE_A_HPH:-16}

# Mode A caps volume at a moderate value, but never raises a level the user
# had already set lower before enabling the DAC.
saved_media=$(sed -n 's/^media=//p' /data/adb/usb_dac/vol.save 2>/dev/null | head -1)
saved_headset=$(sed -n 's/^headset=//p' /data/adb/usb_dac/vol.save 2>/dev/null | head -1)
saved_speaker=$(sed -n 's/^speaker=//p' /data/adb/usb_dac/vol.save 2>/dev/null | head -1)
for saved in "$saved_media" "$saved_headset" "$saved_speaker"; do
  case "$saved" in ''|*[!0-9]*) continue ;; esac
  [ "$saved" -lt "$VOL" ] && VOL=$saved
done

echo $$ >"$PIDF"
log() { echo "route_ka: $*" >>"$LOG"; }
log "start volume-only keepalive pid=$$ vol=$VOL hph=$HPH"

lock_vol() {
  settings put system volume_music "$VOL" >/dev/null 2>&1
  settings put system volume_music_headset "$VOL" >/dev/null 2>&1
  settings put system volume_music_headphone "$VOL" >/dev/null 2>&1
  media volume --stream 3 --set "$VOL" >/dev/null 2>&1
}

hph_only() {
  if [ -f /sys/kernel/usb_dac_direct/hph ] && \
     [ "$(cat "$UDD_EN" 2>/dev/null | tr -d ' \n')" = "1" ]; then
    echo "$HPH" >/sys/kernel/usb_dac_direct/hph 2>/dev/null
  fi
}

bridge_live() {
  if [ -f "$UDD_EN" ] && [ "$(cat "$UDD_EN" 2>/dev/null | tr -d ' \n')" = "1" ]; then
    return 0
  fi
  [ -f "$BPID" ] && kill -0 "$(cat "$BPID" 2>/dev/null)" 2>/dev/null
}

while [ -f "$WANT" ]; do
  if bridge_live; then
    lock_vol
    hit=0
    [ -f /data/adb/usb_dac/vol_hit ] && { rm -f /data/adb/usb_dac/vol_hit; hit=1; }
    if [ "$hit" = "1" ]; then
      hph_only
      log "vol_hit hph_only=$HPH"
    fi
  fi
  sleep 1
done
log "exit"
rm -f "$PIDF"
exit 0
