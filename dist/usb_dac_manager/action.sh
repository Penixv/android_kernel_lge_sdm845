#!/system/bin/sh
# KSU / Magisk Manager action button: toggle DAC
MODDIR=${0%/*}
SCR=$MODDIR/scripts
STATE=/data/adb/usb_dac/state
st=$(cat "$STATE" 2>/dev/null)
case "$st" in
  live|enabled|enabled-*|starting|binding|wait-uac|start-bridge)
    sh "$SCR/usb_dac_ctl.sh" disable
    echo "USB DAC OFF"
    ;;
  *)
    sh "$SCR/usb_dac_ctl.sh" enable
    echo "USB DAC ON (async — check WebUI ready/sound)"
    ;;
esac
