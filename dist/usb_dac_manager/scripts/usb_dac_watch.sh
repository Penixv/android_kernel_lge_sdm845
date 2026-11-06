#!/system/bin/sh
# Watch USB data connection; ask (Vol+/Vol- or file) to switch USB DAC.
MODDIR=/data/adb/modules/usb_dac_manager
SCR=$MODDIR/scripts
CONF=/data/adb/usb_dac/config
STATE=/data/adb/usb_dac/state
LOG=/data/adb/usb_dac/watch.log
ASK_FLAG=/data/adb/usb_dac/ask_reply
mkdir -p /data/adb/usb_dac

log() { echo "$(date '+%F %T') $*" >>"$LOG"; }

load_conf() {
  ASK_ON_USB=0
  ASK_TIMEOUT=12
  [ -f "$CONF" ] && . "$CONF"
}

toast() {
  # best-effort toast / notification
  cmd notification post -t "USB DAC" usb_dac_mgr "$1" 2>/dev/null
  am broadcast -a net.dinglisch.android.tasker.ACTION_TASK --es toast "$1" 2>/dev/null
}

usb_data_host() {
  # Host PC attached for data (not charge-only / disconnected)
  cfg=$(getprop sys.usb.config)
  state=$(getprop sys.usb.state)
  case "$cfg" in
    none|charging*|EMPTY) return 1 ;;
  esac
  # gadget bound
  udc=$(cat /config/usb_gadget/g1/UDC 2>/dev/null)
  [ -n "$udc" ] && [ "$udc" != "none" ] || return 1
  # already in DAC mode
  [ "$(cat "$STATE" 2>/dev/null)" = "enabled" ] && return 1
  case "$state" in
    *adb*|*mtp*|*rndis*|*ptp*) return 0 ;;
  esac
  return 1
}

physical_usb_state() {
  # Prefer the UDC link state. USB_STATE/sys.usb.config can change temporarily
  # during gadget rebinding and are not reliable physical-cable indicators.
  udc=$(cat /config/usb_gadget/g1/UDC 2>/dev/null | tr -d '\n\r ')
  if [ -n "$udc" ] && [ "$udc" != "none" ] && [ -r "/sys/class/udc/$udc/state" ]; then
    link=$(cat "/sys/class/udc/$udc/state" 2>/dev/null | tr '[:upper:]' '[:lower:]' | tr -d '\n\r')
    case "$link" in
      "not attached"|disconnected|none|disabled) echo disconnected; return ;;
      attached|powered|default|address|addressed|configured|suspended) echo connected; return ;;
    esac
  fi
  present=$(cat /sys/class/power_supply/usb/present 2>/dev/null | tr -d '\n\r ')
  case "$present" in 0) echo disconnected; return ;; 1) echo connected; return ;; esac
  online=$(cat /sys/class/power_supply/usb/online 2>/dev/null | tr -d '\n\r ')
  case "$online" in 0) echo disconnected ;; 1) echo connected ;; *) echo unknown ;; esac
}

wait_volume_choice() {
  # Vol+ = yes, Vol- = no, timeout = no
  timeout_s=${ASK_TIMEOUT:-12}
  rm -f "$ASK_FLAG"
  toast "USB DAC? Vol+ = ON  Vol- = skip  (${timeout_s}s)"
  log "prompt ${timeout_s}s"

  # Background getevent watcher
  (
    getevent -l 2>/dev/null | while read -r line; do
      case "$line" in
        *KEY_VOLUMEUP*DOWN*|*VOLUME_UP*DOWN*)
          echo yes >"$ASK_FLAG"; break ;;
        *KEY_VOLUMEDOWN*DOWN*|*VOLUME_DOWN*DOWN*)
          echo no >"$ASK_FLAG"; break ;;
      esac
      [ -f "$ASK_FLAG" ] && break
    done
  ) &
  ge_pid=$!

  i=0
  while [ $i -lt "$timeout_s" ]; do
    if [ -f "$ASK_FLAG" ]; then
      kill "$ge_pid" 2>/dev/null
      reply=$(cat "$ASK_FLAG")
      rm -f "$ASK_FLAG"
      echo "$reply"
      return 0
    fi
    # also allow: echo yes > /data/adb/usb_dac/ask_reply from WebUI
    sleep 1
    i=$((i + 1))
  done
  kill "$ge_pid" 2>/dev/null
  rm -f "$ASK_FLAG"
  echo no
}

prev=0
disconnect_count=0
log "watch started"
while true; do
  load_conf
  # Skip while enable worker is tearing USB / binding
  if [ -f /data/adb/usb_dac/enabling ]; then
    sleep 2
    continue
  fi
  st_now=$(cat "$STATE" 2>/dev/null)
  if [ "$st_now" = "live" ] || [ "$st_now" = "enabled" ]; then
    link_state=$(physical_usb_state)
    if [ "$link_state" = "disconnected" ]; then
      disconnect_count=$((disconnect_count + 1))
      log "DAC active with USB link disconnected sample=$disconnect_count/3"
      if [ "$disconnect_count" -ge 3 ]; then
        log "USB cable removal confirmed; disabling DAC and restoring saved volume"
        toast "电脑已断开，正在关闭 DAC 并恢复音量"
        sh "$SCR/usb_dac_ctl.sh" disable >>"$LOG" 2>&1
        toast "DAC 已关闭，手机音量已恢复"
        disconnect_count=0
        prev=0
        skip_until_unplug=0
      fi
    else
      disconnect_count=0
    fi
  else
    disconnect_count=0
  fi
  case "$st_now" in
    live|starting|binding|wait-uac|start-bridge|hifi|stop-audio) prev=1 ;;
  esac
  if [ "${ASK_ON_USB:-1}" = "1" ] && usb_data_host; then
    if [ "$prev" = "0" ]; then
      log "USB host detected"
      # debounce cable settle
      sleep 2
      usb_data_host || { prev=0; sleep 2; continue; }
      choice=$(wait_volume_choice)
      log "choice=$choice"
      if [ "$choice" = "yes" ]; then
        toast "Enabling USB DAC…"
        sh "$SCR/usb_dac_ctl.sh" enable >>"$LOG" 2>&1
        toast "USB DAC on (use headphones for HiFi)"
        prev=1
      else
        toast "USB DAC skipped"
        prev=1
        # ignore this plug session until unplug
        skip_until_unplug=1
      fi
    fi
  else
    online=$(cat /sys/class/power_supply/usb/online 2>/dev/null)
    if [ "$online" = "0" ]; then
      prev=0
      skip_until_unplug=0
    fi
    [ "$(cat "$STATE" 2>/dev/null)" = "enabled" ] && prev=1
  fi
  # after skip, wait for cable out before asking again
  if [ "${skip_until_unplug:-0}" = "1" ]; then
    online=$(cat /sys/class/power_supply/usb/online 2>/dev/null)
    [ "$online" = "0" ] && skip_until_unplug=0 && prev=0
  fi
  sleep 2
done
