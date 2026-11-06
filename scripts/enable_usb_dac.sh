#!/system/bin/sh
# USB DAC (UAC2 only, exclusive — no ADB).
#
#   su -c "sh /sdcard/enable_usb_dac.sh"     # DAC mode
#   su -c "sh /sdcard/disable_usb_dac.sh"    # restore mtp,adb
#
# Prefer Termux/local root. USB will disconnect from PC.

MODE="${1:-uac2}"
[ "$MODE" = "__inner" ] && MODE="${2:-uac2}"

G=/config/usb_gadget/g1
CFG=$G/configs/b.1
LOG=/data/local/tmp/usb_dac_enable.log
SAVE=/data/local/tmp/usb_dac_gadget.save
UDC=$(getprop sys.usb.controller)
[ -n "$UDC" ] || UDC=$(ls /sys/class/udc 2>/dev/null | head -n1)

# Distinct PID so Windows does not reuse a failed "G7 ThinQ" driver cache
DAC_PID=0xDA02
DAC_NAME="USB Audio DAC"

log() { echo "$*" | tee -a "$LOG"; }

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

restore_mtp_adb() {
  log "RESTORE mtp,adb"
  echo "" > "$G/UDC" 2>/dev/null
  rm -f "$CFG/f1" "$CFG/f2" "$CFG/f3"
  if [ -f "$SAVE" ]; then
    . "$SAVE"
    [ -n "$idVendor" ] && echo "$idVendor" > "$G/idVendor"
    [ -n "$idProduct" ] && echo "$idProduct" > "$G/idProduct"
    [ -n "$product" ] && echo "$product" > "$G/strings/0x409/product"
    [ -n "$bDeviceClass" ] && echo "$bDeviceClass" > "$G/bDeviceClass"
    [ -n "$bDeviceSubClass" ] && echo "$bDeviceSubClass" > "$G/bDeviceSubClass"
    [ -n "$bDeviceProtocol" ] && echo "$bDeviceProtocol" > "$G/bDeviceProtocol"
  fi
  setprop sys.usb.ffs.ready 0 2>/dev/null
  stop adbd 2>/dev/null
  setprop sys.usb.config none
  sleep 2
  setprop sys.usb.config mtp,adb
  start adbd 2>/dev/null
  sleep 2
  if [ -z "$(cat "$G/UDC" 2>/dev/null)" ] || [ "$(cat "$G/UDC")" = "none" ]; then
    ln -s /config/usb_gadget/g1/functions/mtp.gs0 "$CFG/f1" 2>/dev/null
    ln -s /config/usb_gadget/g1/functions/ffs.adb "$CFG/f2" 2>/dev/null
    echo "$UDC" > "$G/UDC" 2>/dev/null
    setprop sys.usb.state mtp,adb
  fi
  log "restored config=$(getprop sys.usb.config) UDC=$(cat "$G/UDC")"
}

if [ "$1" != "__inner" ]; then
  echo "usb_dac: exclusive DAC (no adb). log=$LOG"
  if command -v nohup >/dev/null 2>&1; then
    nohup sh "$0" __inner "$MODE" >/dev/null 2>&1 &
  else
    sh "$0" __inner "$MODE" >/dev/null 2>&1 &
  fi
  echo "usb_dac: started pid $! — wait ~8s, check Windows Sound"
  exit 0
fi

: >"$LOG"
log "=== enable DAC-only udc=$UDC ==="
[ -d "$G" ] || { log "ERROR no gadget"; exit 1; }
[ -n "$UDC" ] || { log "ERROR no UDC"; exit 1; }

if ! mkdir -p "$G/functions/uac2.0" 2>>"$LOG"; then
  log "ERROR no uac2.0 — flash UAC2-DAConly kernel first"
  exit 1
fi

save_ids

# Tear down completely; do NOT setprop to unknown "uac2" (init fights it)
setprop sys.usb.ffs.ready 0 2>/dev/null
stop adbd 2>/dev/null
setprop sys.usb.config none
i=0
while [ "$(getprop sys.usb.state)" != "none" ] && [ $i -lt 12 ]; do sleep 1; i=$((i+1)); done
echo "" > "$G/UDC" 2>/dev/null
sleep 1

# 48k / 16-bit / stereo USB-OUT (host -> phone DAC)
echo 3 > "$G/functions/uac2.0/c_chmask"
echo 48000 > "$G/functions/uac2.0/c_srate"
echo 2 > "$G/functions/uac2.0/c_ssize"
# playback path unused in DAC-only kernel build, keep sane values
echo 3 > "$G/functions/uac2.0/p_chmask"
echo 48000 > "$G/functions/uac2.0/p_srate"
echo 2 > "$G/functions/uac2.0/p_ssize"

rm -f "$CFG/f1" "$CFG/f2" "$CFG/f3"
mkdir -p "$CFG/strings/0x409" "$G/strings/0x409"

echo "$DAC_PID" > "$G/idProduct"
echo "$DAC_NAME" > "$G/strings/0x409/product"
echo "uac2" > "$CFG/strings/0x409/configuration"
# Per-interface class (UAC2 has its own IAD)
echo 0 > "$G/bDeviceClass"
echo 0 > "$G/bDeviceSubClass"
echo 0 > "$G/bDeviceProtocol"

ln -s /config/usb_gadget/g1/functions/uac2.0 "$CFG/f1" || {
  log "ERROR link uac2"
  restore_mtp_adb
  exit 1
}

log "links:"; ls -la "$CFG" | tee -a "$LOG"
log "ids: vid=$(cat "$G/idVendor") pid=$(cat "$G/idProduct") name=$(cat "$G/strings/0x409/product")"

if ! echo "$UDC" > "$G/UDC" 2>>"$LOG"; then
  log "ERROR bind failed"
  restore_mtp_adb
  exit 1
fi
setprop sys.usb.state uac2
sleep 2
log "UDC=$(cat "$G/UDC") state=$(getprop sys.usb.state)"
cat /proc/asound/cards | tee -a "$LOG"

if cat /proc/asound/cards | grep -qi uac; then
  log "OK: UAC2 card up — Windows should show USB Audio / Speakers (not G7 bang)"
  # Host PCM lands in ALSA capture; must bridge to tavil or there is no sound
  BRIDGE=""
  for p in /sdcard/usb_dac_bridge.sh /data/local/tmp/usb_dac_bridge.sh \
           "$(dirname "$0")/usb_dac_bridge.sh"; do
    [ -f "$p" ] && BRIDGE=$p && break
  done
  if [ -n "$BRIDGE" ]; then
    log "starting PCM bridge $BRIDGE"
    sh "$BRIDGE" start >>"$LOG" 2>&1 || log "WARN: bridge failed — run: sh $BRIDGE start"
  else
    log "WARN: no usb_dac_bridge.sh — push it and: su -c 'sh /sdcard/usb_dac_bridge.sh start'"
  fi
  exit 0
fi
log "WARN: no UAC2 card — restoring"
restore_mtp_adb
exit 2
