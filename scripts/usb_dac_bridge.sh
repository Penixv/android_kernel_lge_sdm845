#!/system/bin/sh
# Compat wrapper — just run usb_dac.sh (no args).
here=$(dirname "$0")
case "$here" in
  /*) ;;
  *) here=$(pwd)/$here ;;
esac
for p in "$here/usb_dac.sh" /sdcard/usb_dac.sh /sdcard/usb_dac/usb_dac.sh; do
  [ -f "$p" ] && exec sh "$p"
done
echo "ERROR: usb_dac.sh not found — adb push dist/usb_dac/* /sdcard/"
exit 1
