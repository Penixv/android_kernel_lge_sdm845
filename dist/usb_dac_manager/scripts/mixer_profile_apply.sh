#!/system/bin/sh
# Apply captured tinymix contents dump (CTL name = value lines).
MODDIR=${MODDIR:-/data/adb/modules/usb_dac_manager}
TINYMIX=$MODDIR/bin/tinymix
SCR=$MODDIR/scripts
[ -x "$TINYMIX" ] || TINYMIX=$(command -v tinymix)
PROF=${1:-/data/adb/usb_dac/mixer_profile.txt}
LOG=/data/adb/usb_dac/ctl.log

CARD=$(awk '/tavil|sdm845-tavil/{print $1; exit}' /proc/asound/cards 2>/dev/null)
[ -n "$CARD" ] || CARD=1

log() { echo "mixer_apply: $*" | tee -a "$LOG"; }

if [ ! -f "$PROF" ] || [ ! -s "$PROF" ]; then
  log "no profile — fallback route_playback.sh"
  sh "$SCR/route_playback.sh" "$CARD"
  exit 0
fi

[ -x "$TINYMIX" ] || { log "no tinymix"; exit 1; }
log "applying $PROF card=$CARD"

# tinymix contents format varies; handle common:
#   1 CTL_NAME is ENUM value / value=...
#   CTL_NAME: values=...
applied=0
while IFS= read -r line; do
  case "$line" in
    \#*|"") continue ;;
  esac
  # "  Foo Bar: values=1" or "Foo Bar = 1"
  name=
  val=
  if echo "$line" | grep -q 'values='; then
    name=$(echo "$line" | sed -n 's/^[[:space:]]*\([^:]*\):.*/\1/p' | sed 's/[[:space:]]*$//')
    val=$(echo "$line" | sed -n 's/.*values=\(.*\)/\1/p' | awk '{print $1}' | tr -d ',')
  elif echo "$line" | grep -q '='; then
    name=$(echo "$line" | sed -n 's/^[[:space:]]*\([^=]*\)=.*/\1/p' | sed 's/[[:space:]]*$//')
    val=$(echo "$line" | sed -n 's/.*=[[:space:]]*\(.*\)/\1/p' | awk '{print $1}')
  fi
  [ -n "$name" ] && [ -n "$val" ] || continue
  # skip huge binary / irrelevant
  case "$name" in
    *TLV*|*Bytes*|*IEC*) continue ;;
  esac
  if "$TINYMIX" -D "$CARD" set "$name" $val >/dev/null 2>&1 || \
     "$TINYMIX" -D "$CARD" "$name" $val >/dev/null 2>&1; then
    applied=$((applied + 1))
  fi
done <"$PROF"

log "applied=$applied controls"
# Always reinforce ESS + volumes
sh "$SCR/route_playback.sh" "$CARD" >/dev/null 2>&1
exit 0
