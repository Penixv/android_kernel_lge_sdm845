#!/system/bin/sh
# =============================================================================
# HAL 预热 → mixer-capture → apply → Mode A PCM  测试方案
#
# 目的：用系统播放器建好的 DSP 图，验证 Mode A 独占 PCM 能否稳定出声。
#
# 用法（手机 su 或 adb）：
#   sh /data/adb/modules/usb_dac_manager/scripts/test_hal_mixer_pcm.sh
#
# 交互：按提示操作；每步完成后执行：
#   touch /data/adb/usb_dac/test_go
# 或直接回车（脚本若在有 tty 时会 read）。
#
# 报告：/data/adb/usb_dac/test_hal_pcm_report.txt
# =============================================================================
MOD=${MODDIR:-/data/adb/modules/usb_dac_manager}
CTL=$MOD/scripts/usb_dac_ctl.sh
BASE=/data/adb/usb_dac
GO=$BASE/test_go
REP=$BASE/test_hal_pcm_report.txt
PROF=$BASE/mixer_profile.txt
LOG=$BASE/ctl.log
mkdir -p "$BASE"
rm -f "$GO"
: >"$REP"

log() { echo "$*" | tee -a "$REP" "$LOG"; }
fail() { log "FAIL: $*"; echo "RESULT=FAIL" >>"$REP"; exit 1; }
pass() { log "PASS: $*"; }

wait_user() {
  msg=$1
  rm -f "$GO"
  log ""
  log ">>> $msg"
  log ">>> 完成后执行:  touch $GO"
  # tty?
  if [ -t 0 ]; then
    printf "按回车继续（或另开 shell touch test_go）… "
    read -r _ || true
    touch "$GO"
  else
    i=0
    while [ ! -f "$GO" ]; do
      sleep 1
      i=$((i + 1))
      [ $((i % 15)) -eq 0 ] && log "(仍在等 test_go… ${i}s)"
      [ "$i" -ge 600 ] && fail "等待用户超时 600s"
    done
  fi
  rm -f "$GO"
}

chk_no_bridge() {
  if pgrep -f 'usb_dac_bridge|usb_dac_pcm|usb_dac_aaudio' >/dev/null 2>&1; then
    return 1
  fi
  return 0
}

# ---------- 0. 配置 ----------
log "==== test_hal_mixer_pcm $(date) ===="
CONF=$BASE/config
touch "$CONF"
for kv in MODE=a MODE_A_PCM=1 MODE_A_PLAY_DEV=0 MODE_A_ALLOW_AAUDIO=0 MODE_A_KEEP_AUDIOSERVER=0 MODE_A_USE_PROFILE=1 FORCE_HIFI=0; do
  k=${kv%%=*}; v=${kv#*=}
  grep -q "^${k}=" "$CONF" && sed -i "s|^${k}=.*|${k}=${v}|" "$CONF" || echo "${k}=${v}" >>"$CONF"
done
log "config: MODE=a PCM=1 PLAY_DEV=0 ALLOW_AAUDIO=0 USE_PROFILE=1"

# ---------- 1. 关闭 DAC ----------
log "---- STEP1 disable DAC ----"
sh "$CTL" disable >>"$LOG" 2>&1 || true
killall -9 usb_dac_bridge usb_dac_aaudio usb_dac_pcm 2>/dev/null
[ -f $BASE/sup.pid ] && kill -9 "$(cat $BASE/sup.pid)" 2>/dev/null
rm -f $BASE/want $BASE/sup.pid $BASE/bridge.pid $BASE/worker $BASE/enabling
# 确保 audioserver 在（capture 需要 HAL 播歌）
pgrep -x audioserver >/dev/null 2>&1 || start audioserver
sleep 2
chk_no_bridge || fail "仍有 bridge 进程，请手动 kill 后重跑"
pass "DAC 已关，无 bridge"

# ---------- 2. 用户：耳机 + 系统播歌 ----------
wait_user "请：①插上 3.5mm 耳机  ②用系统播放器/网易云等开始播歌并确认耳机有声  ③音量开大一点"

# 粗检：jack
HS=0
[ -f /sys/class/switch/h2w/state ] && [ "$(cat /sys/class/switch/h2w/state)" != "0" ] && HS=1
[ -f /sys/kernel/es9218_dac/headset_type ] && [ "$(cat /sys/kernel/es9218_dac/headset_type)" != "0" ] && HS=1
log "headset_guess=$HS (1=可能已插；0 也不阻断，继续)"
pgrep -x audioserver >/dev/null || fail "audioserver 不在，无法依赖 HAL 建图"
pass "用户确认播歌中"

# ---------- 3. mixer-capture ----------
log "---- STEP3 mixer-capture（播歌中，Mode A 必须关闭）----"
chk_no_bridge || fail "capture 前发现 bridge — 禁止，会卡死"
rm -f "$PROF"
sh "$MOD/scripts/mixer_profile_capture.sh"
rc=$?
[ "$rc" = "0" ] || fail "mixer-capture rc=$rc"
lines=$(wc -l <"$PROF" 2>/dev/null || echo 0)
[ "$lines" -ge 50 ] || fail "profile 行数过少 ($lines) — 播歌/tinymix 可能失败"
# 备份带时间戳
cp "$PROF" "$BASE/mixer_profile_$(date +%Y%m%d_%H%M%S).txt"
log "profile lines=$lines -> $PROF"
# 抽查关键控件是否出现在 dump 里
for key in "SLIMBUS_0_RX Audio Mixer" "MultiMedia" "HPHL" "Es9018" "SLIM RX"; do
  if grep -q "$key" "$PROF" 2>/dev/null; then
    log "  profile has: $key"
  else
    log "  profile MISS: $key (未必致命)"
  fi
done
pass "mixer-capture OK ($lines lines)"

# ---------- 4. 停播放 ----------
wait_user "请：完全停止系统播放器（回到桌面/暂停），确认耳机不再出系统音乐"

# ---------- 5. apply（audioserver 仍在）----------
log "---- STEP5 mixer-apply（bridge 未起）----"
chk_no_bridge || fail "apply 前仍有 bridge"
sh "$MOD/scripts/mixer_profile_apply.sh" "$PROF" >>"$LOG" 2>&1
log "apply done (see ctl.log mixer_apply:)"
pass "mixer-apply 完成"

# ---------- 6. 启用 Mode A PCM（会停 audioserver + 再 apply + bridge）----------
log "---- STEP6 enable Mode A ----"
# 标记：start_bridge 会读 MODE_A_USE_PROFILE
sh "$CTL" mode-a >>"$LOG" 2>&1
sh "$CTL" enable >>"$LOG" 2>&1
# 等 live
ok=0
i=0
while [ $i -lt 45 ]; do
  sleep 1
  i=$((i + 1))
  st=$(cat $BASE/status.json 2>/dev/null)
  echo "$st" | grep -q '"ready": 1' && echo "$st" | grep -q 'pcm_bridge\|"mode_actual": "pcm' && {
    ok=1
    break
  }
  echo "$st" | grep -q 'error-bridge' && break
  # 相位
  ph=$(echo "$st" | grep -o '"phase": "[^"]*"' | head -1)
  [ $((i % 5)) -eq 0 ] && log "  wait… $ph"
done

cat $BASE/status.json >>"$REP" 2>/dev/null
echo "" >>"$REP"
cat $BASE/hb >>"$REP" 2>/dev/null

if [ "$ok" != "1" ]; then
  log "status=$(cat $BASE/status.json 2>/dev/null | tr '\n' ' ')"
  log "hb=$(cat $BASE/hb 2>/dev/null | tr '\n' ' ')"
  fail "Mode A 未进入 pcm_bridge ready（见上）"
fi

fp=$(grep '^frames_play=' $BASE/hb 2>/dev/null | cut -d= -f2)
fp=${fp:-0}
xp=$(grep '^xrun_play=' $BASE/hb 2>/dev/null | cut -d= -f2)
xp=${xp:-0}
log "frames_play=$fp xrun_play=$xp actual=$(grep mode_actual $BASE/status.json)"

[ "$fp" -gt 5000 ] 2>/dev/null || fail "frames_play=$fp 过低 — PCM 可能无声/卡死边缘"
pass "PCM bridge live frames_play=$fp xrun_play=$xp"

# ---------- 7. 听感确认 ----------
wait_user "请在 PC 上选手机 UAC 声卡播放，听耳机是否正常、有无爆音卡顿。听完后继续"

log "==== RESULT=PASS $(date) ===="
echo "RESULT=PASS" >>"$REP"
log "报告: $REP"
log "profile: $PROF"
exit 0
