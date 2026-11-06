#!/system/bin/sh
# Late start: USB DAC ask-on-connect watcher
MODDIR=${0%/*}
SCR=$MODDIR/scripts
mkdir -p /data/adb/usb_dac
# wait for boot
while [ "$(getprop sys.boot_completed)" != "1" ]; do sleep 2; done
sleep 5
# Install/update the bundled companion app after Android's package manager is ready.
APK="$MODDIR/app/USB_DAC_Manager-v1.1.3.apk"
if [ -f "$APK" ]; then
  if dumpsys package com.twtter.usbdacmanager 2>/dev/null | grep -q 'versionName=1.1.3'; then
    :
  else
    pm install -r "$APK" >/data/adb/usb_dac/app-install.log 2>&1
  fi
fi
# reset state if leftover bridge from crash
if [ -f /data/adb/usb_dac/bridge.pid ]; then
  pid=$(cat /data/adb/usb_dac/bridge.pid)
  [ -d "/proc/$pid" ] || rm -f /data/adb/usb_dac/bridge.pid /data/adb/usb_dac/state
fi
# Persistent notification suppression must never survive a rebooted DAC session.
sh "$SCR/usb_dac_ctl.sh" restore-usb-notifications >/dev/null 2>&1
chmod 755 "$SCR"/* "$MODDIR/bin"/* 2>/dev/null
# start watcher (one instance)
pkill -f usb_dac_watch.sh 2>/dev/null
nohup sh "$SCR/usb_dac_watch.sh" >/data/adb/usb_dac/watch.nohup 2>&1 &
echo $! >/data/adb/usb_dac/watch.pid
