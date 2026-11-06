#!/system/bin/sh
# Light repair while PCM open. Kill AF secondary path (RX2/INT*_2 = 电流声).
# Rebalance L/R digital + ESS volumes (AF often skews RX0 / zeros ESS).
MODDIR=${MODDIR:-/data/adb/modules/usb_dac_manager}
TINYMIX=$MODDIR/bin/tinymix
[ -x "$TINYMIX" ] || TINYMIX=$(command -v tinymix)
CARD=${1:-1}
HPH=${2:-16}
DIG=${3:-84}
ESS=${4:-180}

[ -x "$TINYMIX" ] || exit 0
setc() { "$TINYMIX" -D "$CARD" set "$1" "$2" >/dev/null 2>&1 || true; }

setc "SLIM_6_RX Channels" "Two"

# Primary stereo
setc "SLIM RX0 MUX" "AIF4_PB"
setc "SLIM RX1 MUX" "AIF4_PB"
# AF loves to turn these on → hum / current noise
setc "SLIM RX2 MUX" "ZERO"
setc "SLIM RX3 MUX" "ZERO"
setc "CDC_IF RX0 MUX" "SLIM RX0"
setc "CDC_IF RX1 MUX" "SLIM RX1"
setc "RX INT1_2 MUX" "ZERO"
setc "RX INT2_2 MUX" "ZERO"
setc "RX INT1_2 INTERP" "ZERO"
setc "RX INT2_2 INTERP" "ZERO"
setc "RX INT1 SEC MIX HPHL Switch" 0
setc "RX INT2 SEC MIX HPHR Switch" 0
setc "RX INT1_1 MIX1 INP0" "RX0"
setc "RX INT2_1 MIX1 INP0" "RX1"
setc "RX INT1_1 INTERP" "RX INT1_1 MIX1"
setc "RX INT2_1 INTERP" "RX INT2_1 MIX1"

# Matched L/R — never leave RX0 skewed
setc "HPHL Volume" "$HPH"
setc "HPHR Volume" "$HPH"
setc "RX0 Digital Volume" "$DIG"
setc "RX1 Digital Volume" "$DIG"
setc "Es9018 Left Volume" "$ESS"
setc "Es9018 Right Volume" "$ESS"
setc "COMP1 Switch" 0
setc "COMP2 Switch" 0
exit 0
