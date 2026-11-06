#!/system/bin/sh
# One-tap USB DAC. No arguments.
#   su -c "sh /sdcard/usb_dac.sh"
# Restore:
#   su -c "sh /sdcard/usb_dac_off.sh"
#
# IMPORTANT: does NOT stop audioserver / does NOT open tavil PCM.
# Audio goes UAC2 -> usb_dac_aaudio (AAudio) -> speaker (safe for volume keys).

export PATH=/system/bin:/vendor/bin:/system/xbin:/data/local/tmp:$PATH

G=/config/usb_gadget/g1
CFG=$G/configs/b.1
LOG=/data/local/tmp/usb_dac.log
BINDIR=/data/local/tmp/usb_dac_bin
PIDF=/data/local/tmp/usb_dac_bridge.pid
SAVE=/data/local/tmp/usb_dac_gadget.save
# New PID each major fix so Windows drops bad name/cache
DAC_PID=0xDA05
DAC_NAME="Phone USB DAC"
RATE=48000
CH=2

UDC=$(getprop sys.usb.controller)
[ -n "$UDC" ] || UDC=$(ls /sys/class/udc 2>/dev/null | head -n1)

log() { echo "$*" | tee -a "$LOG"; }

here=$(dirname "$0")
case "$here" in
  /*) ;;
  *) here=$(pwd)/$here ;;
esac

install_bin() {
  b=$1
  mkdir -p "$BINDIR"
  [ -x "$BINDIR/$b" ] && return 0
  for src in "$here/$b" "/sdcard/$b" "/sdcard/usb_dac/$b" "/data/local/tmp/$b"; do
    if [ -f "$src" ]; then
      cp -f "$src" "$BINDIR/$b"
      chmod 755 "$BINDIR/$b"
      return 0
    fi
  done
  return 1
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

find_uac() {
  awk '/UAC2|Gadget|uac2|snd_uac/{print $1; exit}' /proc/asound/cards 2>/dev/null
}

kill_bridge() {
  if [ -f "$PIDF" ]; then
    pid=$(cat "$PIDF")
    kill -TERM "$pid" 2>/dev/null
    sleep 1
    kill -KILL "$pid" 2>/dev/null
    rm -f "$PIDF"
  fi
  killall -9 usb_dac_aaudio 2>/dev/null
  killall -9 usb_dac_pcm 2>/dev/null
}

: >"$LOG"
log "=== usb_dac (AAudio, audioserver kept) ==="

[ -d "$G" ] || { log "ERROR: no gadget"; exit 1; }
[ -n "$UDC" ] || { log "ERROR: no UDC"; exit 1; }

if ! mkdir -p "$G/functions/uac2.0" 2>>"$LOG"; then
  log "ERROR: no uac2.0 — flash UAC2 kernel"
  exit 1
fi

if ! install_bin usb_dac_aaudio; then
  log "ERROR: usb_dac_aaudio missing"
  log "adb push dist/usb_dac/. /sdcard/"
  exit 1
fi
log "bin=$BINDIR/usb_dac_aaudio"

kill_bridge
save_ids

# Raise media volume (best-effort, no audioserver restart)
media volume --stream 3 --set 15 2>/dev/null
cmd media_session volume --show --stream 3 --set 15 2>/dev/null
service call audio 7 i32 3 i32 15 i32 1 2>/dev/null

setprop sys.usb.ffs.ready 0 2>/dev/null
stop adbd 2>/dev/null
setprop sys.usb.config none
i=0
while [ "$(getprop sys.usb.state)" != "none" ] && [ $i -lt 12 ]; do sleep 1; i=$((i+1)); done
echo "" > "$G/UDC" 2>/dev/null
sleep 1

echo 3 > "$G/functions/uac2.0/c_chmask"
echo "$RATE" > "$G/functions/uac2.0/c_srate"
echo 2 > "$G/functions/uac2.0/c_ssize"
echo 3 > "$G/functions/uac2.0/p_chmask"
echo "$RATE" > "$G/functions/uac2.0/p_srate"
echo 2 > "$G/functions/uac2.0/p_ssize"

rm -f "$CFG/f1" "$CFG/f2" "$CFG/f3"
mkdir -p "$CFG/strings/0x409" "$G/strings/0x409"
echo "$DAC_PID" > "$G/idProduct"
echo "$DAC_NAME" > "$G/strings/0x409/product"
echo "Phone USB DAC" > "$CFG/strings/0x409/configuration"
echo 0 > "$G/bDeviceClass"
echo 0 > "$G/bDeviceSubClass"
echo 0 > "$G/bDeviceProtocol"

ln -s /config/usb_gadget/g1/functions/uac2.0 "$CFG/f1" || {
  log "ERROR link uac2"
  exit 1
}

if ! echo "$UDC" > "$G/UDC" 2>>"$LOG"; then
  log "ERROR UDC bind"
  exit 1
fi
setprop sys.usb.state uac2
sleep 2
log "UDC=$(cat "$G/UDC") pid=$(cat "$G/idProduct") name=$(cat "$G/strings/0x409/product")"
cat /proc/asound/cards | tee -a "$LOG"

UAC=$(find_uac)
[ -n "$UAC" ] || { log "ERROR: no UAC2 card"; exit 2; }
log "start AAudio bridge UAC card=$UAC (audioserver NOT touched)"

# Do NOT stop audioserver. Do NOT open tavil with tinyalsa.
setenforce 0 2>/dev/null

"$BINDIR/usb_dac_aaudio" "$UAC" "$RATE" "$CH" >>"$LOG" 2>&1 &
echo $! >"$PIDF"
sleep 2

pid=$(cat "$PIDF" 2>/dev/null)
if [ -n "$pid" ] && [ -d "/proc/$pid" ]; then
  log "OK pid=$pid"
  log "Windows: select 'Phone USB DAC' / Speakers, play music"
  log "Phone media volume up; prefer wired headset if speaker silent"
  log "off: su -c \"sh /sdcard/usb_dac_off.sh\""
  tail -15 "$LOG"
  exit 0
fi
log "ERROR bridge died:"
cat "$LOG"
exit 3
