#!/system/bin/sh
# BakaSU / KernelSU customize (hybrid mount OK) — clean install every flash
# Not Magisk-specific; module lands under /data/adb/modules via ksud.
SKIPUNZIP=0

ui_print "- USB DAC Manager (BakaSU/KSU, clean flash)"
ui_print "- Wiping previous module + /data/adb/usb_dac"

# Restore system USB notification preferences before deleting the prior session backup.
if [ -f /data/adb/usb_dac/usb_notify.save ]; then
  adb_notify=$(sed -n 's/^adb=//p' /data/adb/usb_dac/usb_notify.save | head -1)
  charging_notify=$(sed -n 's/^charging=//p' /data/adb/usb_dac/usb_notify.save | head -1)
  [ -n "$adb_notify" ] || adb_notify=1
  [ -n "$charging_notify" ] || charging_notify=1
  setprop persist.adb.notify "$adb_notify" 2>/dev/null
  setprop persist.charging.notify "$charging_notify" 2>/dev/null
fi

# Stop anything from the old install
pkill -f 'usb_dac_ctl.sh' 2>/dev/null
pkill -f 'usb_dac_watch.sh' 2>/dev/null
killall -9 usb_dac_aaudio 2>/dev/null
killall -9 usb_dac_pcm 2>/dev/null
killall -9 volkey_block 2>/dev/null

# Module dirs (active + pending update + update mirror)
for d in \
  /data/adb/modules/usb_dac_manager \
  /data/adb/modules_update/usb_dac_manager \
  /data/adb/ksu/modules/usb_dac_manager \
  /data/adb/ksu/modules_update/usb_dac_manager
do
  # Do not delete MODPATH itself while we are installing into it —
  # Magisk extracts to MODPATH first; wipe siblings / old path only if different.
  if [ -n "$MODPATH" ] && [ "$d" = "$MODPATH" ]; then
    # Wipe contents that customize may replace; keep MODPATH root
    # (full wipe of old runtime data is below)
    continue
  fi
  if [ -d "$d" ]; then
    ui_print "  rm $d"
    rm -rf "$d"
  fi
done

# If Magisk already extracted into MODPATH, clear leftover junk from old zips
# that are not in the new package (keep what unzip just placed).
# Runtime state always wiped:
ui_print "  rm /data/adb/usb_dac"
rm -rf /data/adb/usb_dac

# Also clear common leftover paths from early one-tap scripts
rm -rf /data/local/tmp/usb_dac \
       /data/local/tmp/usb_dac_bin \
       /data/local/tmp/usb_dac_bridge.pid \
       /data/local/tmp/usb_dac.log \
       /data/local/tmp/usb_dac_enable.log \
       /data/local/tmp/usb_dac_gadget.save 2>/dev/null
rm -f /data/local/tmp/usb_dac_*.pid 2>/dev/null

mkdir -p /data/adb/usb_dac
cat > /data/adb/usb_dac/config <<'EOF'
ASK_ON_USB=0
FORCE_HIFI=0
ASK_TIMEOUT=12
MODE=b
MODE_B_BITS=16
EOF
echo idle > /data/adb/usb_dac/state

chmod 755 "$MODPATH/bin"/* "$MODPATH/scripts"/* "$MODPATH"/*.sh 2>/dev/null
mkdir -p "$MODPATH/system/bin"
ln -sf /data/adb/modules/usb_dac_manager/scripts/usb_dac_ctl.sh \
  "$MODPATH/system/bin/usb_dac_ctl" 2>/dev/null || true

ui_print "- Fresh install ready. Reboot, then open WebUI"
ui_print "- FORCE_HIFI off by default (toggle in WebUI if needed)"
