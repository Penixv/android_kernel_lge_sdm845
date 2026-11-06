#!/system/bin/sh
# Restore stock mtp,adb after USB DAC mode.
G=/config/usb_gadget/g1
CFG=$G/configs/b.1
SAVE=/data/local/tmp/usb_dac_gadget.save
UDC=$(getprop sys.usb.controller)
[ -n "$UDC" ] || UDC=$(ls /sys/class/udc 2>/dev/null | head -n1)

# Stop PCM bridge and bring audioserver back
for p in /sdcard/usb_dac_bridge.sh /data/local/tmp/usb_dac_bridge.sh; do
  [ -f "$p" ] && sh "$p" stop 2>/dev/null
done

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

setprop persist.usb.dac 0 2>/dev/null
rm -f /data/adb/usb_dac_enable 2>/dev/null
setprop sys.usb.ffs.ready 0 2>/dev/null
stop adbd 2>/dev/null
setprop sys.usb.config none
sleep 2
setprop sys.usb.config mtp,adb
start adbd 2>/dev/null
sleep 2
if [ -z "$(cat "$G/UDC" 2>/dev/null)" ] || [ "$(cat "$G/UDC")" = "none" ]; then
  rm -f "$CFG/f1" "$CFG/f2" "$CFG/f3"
  ln -s /config/usb_gadget/g1/functions/mtp.gs0 "$CFG/f1"
  ln -s /config/usb_gadget/g1/functions/ffs.adb "$CFG/f2"
  echo "$UDC" > "$G/UDC"
  setprop sys.usb.state mtp,adb
fi
echo "restore: config=$(getprop sys.usb.config) state=$(getprop sys.usb.state) UDC=$(cat "$G/UDC")"
echo "unplug/replug cable"
