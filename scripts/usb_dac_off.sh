#!/system/bin/sh
# Restore MTP+ADB. No arguments.
#   su -c "sh /sdcard/usb_dac_off.sh"

G=/config/usb_gadget/g1
CFG=$G/configs/b.1
SAVE=/data/local/tmp/usb_dac_gadget.save
PIDF=/data/local/tmp/usb_dac_bridge.pid
UDC=$(getprop sys.usb.controller)
[ -n "$UDC" ] || UDC=$(ls /sys/class/udc 2>/dev/null | head -n1)

if [ -f "$PIDF" ]; then
  pid=$(cat "$PIDF")
  kill -TERM "$pid" 2>/dev/null
  sleep 1
  kill -KILL "$pid" 2>/dev/null
  rm -f "$PIDF"
fi
killall -9 usb_dac_aaudio 2>/dev/null
killall -9 usb_dac_pcm 2>/dev/null

echo "" > "$G/UDC" 2>/dev/null
rm -f "$CFG/f1" "$CFG/f2" "$CFG/f3" 2>/dev/null

if [ -f "$SAVE" ]; then
  # shellcheck disable=SC1090
  . "$SAVE"
  [ -n "${idVendor:-}" ] && echo "$idVendor" > "$G/idVendor"
  [ -n "${idProduct:-}" ] && echo "$idProduct" > "$G/idProduct"
  [ -n "${product:-}" ] && echo "$product" > "$G/strings/0x409/product"
  [ -n "${bDeviceClass:-}" ] && echo "$bDeviceClass" > "$G/bDeviceClass"
  [ -n "${bDeviceSubClass:-}" ] && echo "$bDeviceSubClass" > "$G/bDeviceSubClass"
  [ -n "${bDeviceProtocol:-}" ] && echo "$bDeviceProtocol" > "$G/bDeviceProtocol"
fi

setprop sys.usb.ffs.ready 0 2>/dev/null
stop adbd 2>/dev/null
setprop sys.usb.config none
sleep 2
setprop sys.usb.config mtp,adb
start adbd 2>/dev/null
# ensure audio stack up (in case an older script killed it)
start audioserver 2>/dev/null
setprop ctl.start audioserver 2>/dev/null
sleep 2
if [ -z "$(cat "$G/UDC" 2>/dev/null)" ] || [ "$(cat "$G/UDC")" = "none" ]; then
  rm -f "$CFG/f1" "$CFG/f2" "$CFG/f3"
  ln -s /config/usb_gadget/g1/functions/mtp.gs0 "$CFG/f1"
  ln -s /config/usb_gadget/g1/functions/ffs.adb "$CFG/f2"
  echo "$UDC" > "$G/UDC"
  setprop sys.usb.state mtp,adb
fi
echo "restored: $(getprop sys.usb.config) UDC=$(cat "$G/UDC")"
echo "unplug/replug if needed"
