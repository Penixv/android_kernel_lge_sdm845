#!/system/bin/sh
# Magisk/KSU module uninstall cleanup
pkill -f 'usb_dac_ctl.sh' 2>/dev/null
pkill -f 'usb_dac_watch.sh' 2>/dev/null
killall -9 usb_dac_aaudio 2>/dev/null
killall -9 usb_dac_pcm 2>/dev/null
killall -9 volkey_block 2>/dev/null
if [ -f /data/adb/usb_dac/usb_notify.save ]; then
  adb_notify=$(sed -n 's/^adb=//p' /data/adb/usb_dac/usb_notify.save | head -1)
  charging_notify=$(sed -n 's/^charging=//p' /data/adb/usb_dac/usb_notify.save | head -1)
  [ -n "$adb_notify" ] || adb_notify=1
  [ -n "$charging_notify" ] || charging_notify=1
  setprop persist.adb.notify "$adb_notify" 2>/dev/null
  setprop persist.charging.notify "$charging_notify" 2>/dev/null
fi
rm -rf /data/adb/usb_dac
rm -rf /data/local/tmp/usb_dac /data/local/tmp/usb_dac_bin 2>/dev/null
