# USB DAC Mode A 修复方案集（供评估）

> 目标：LG G7 (judyln) 内核直连 USB DAC（`techpack/audio/dsp/usb_dac_direct.c`）
> 现状症状：① 切歌/长时间 → 欠载、卡顿、爆音 ② 有概率手机睡死 ③ 底噪明显
> 说明：以下方案均锚定在真实代码行号，评估时可直接对照源码核实。方案彼此可组合。

---

## 2026-11-06：A1 失败后的修订（已修改源码，待刷机实测）

用户反馈：A1 后所有音频爆音，电脑网易云切歌后持续卡顿。当前方案表为历史设想，以下源码核查结果优先；不能将方案中的推测视为已证实根因。

本轮修复 `techpack/audio/dsp/usb_dac_direct.c`：

- 原补静音分支直接 `continue`，绕过 XRUN/PREPARE 和错误休眠。若 PCM 已 XRUN，FIFO 50 线程可能持续空转。现所有块共用写入/恢复路径，出错必休眠，短写继续写余下帧。
- 原 ramp 每个 period 都淡入，20ms 周期下会反复改变正常波形；零帧时 ramp 长度又为零，实际没有淡出。现仅在静音/音频转换时处理 S16 斜坡，正常连续块保持原样，部分块尾部淡出。
- 原 `silence_threshold=0`、`silence_size=buffer_size` 小于 boundary，在本仓库 `snd_pcm_sw_params()` 中返回 `-EINVAL`，原代码未检查。现关闭 ALSA 自动静音，使用合法 SW_PARAMS 并检查返回值；capture 启动阈值设为 1，play 保留两周期。
- 播放期间不再为 USB 数据等待 35ms；空 ring 输出静音，积累到 80ms 后恢复。补缓冲期间暂停 drift 校正。

验证：驱动对象编译通过（原有 `udd_find_card` 未使用警告）；提取实际 ramp 代码做连续块不变、淡入、淡出、部分块和零帧回归，ASan/UBSan 通过（容器不支持 LeakSanitizer，已关闭 leak 检查）。`git diff --check` 通过。

设备验收：重新构建/刷入内核后，以低音量连续播放、暂停/恢复、网易云反复切歌测试；记录切歌前后 `/sys/kernel/usb_dac_direct/status` 和 dmesg 中 `play xrun` / `SW_PARAMS failed`。`ring_underruns` 可在真实断流时增加，但恢复播放后不应持续增加，`xrun_play` 不应持续暴涨。本轮未实测手机，不能宣称爆音已消除。

A2 PI 和 D1 feedback 暂未实现；现有逐帧 drop/插零漂移校正仍可能产生轻微接缝，后续需要结合实机计数判断。A2 原文“读多少写多少（不足补齐）”依然是固定输出长度，单独调整写入长度不能解决独立时钟漂移。

---

## 一、方案总览

| 编号 | 方案 | 针对症状 | 改动位置 | 成本 | 优先级 |
|---|---|---|---|---|---|
| A1 | 运行中重预缓冲（refill 状态机） | 欠载/卡顿 | `udd_play_thread` | 中 | ⭐⭐⭐ |
| A2 | 漂移校正改造（按需写 + 平滑控制） | 长时间欠载 | `udd_play_thread` drift 段 | 中 | ⭐⭐⭐ |
| A3 | capture 断流检测 + 软重置 | 切歌断流 | `udd_cap_thread`/play | 小 | ⭐⭐ |
| A4 | 静音/真实音频接缝 ramp | 爆音 | play 写静音处 | 小 | ⭐⭐ |
| B1 | 补 wakelock | 睡死 | `udd_init/enable/disable` | 小 | ⭐⭐⭐ |
| B2 | 降低 RT 优先级 | 睡死(饿死) | `udd_thread_rt` | 小 | ⭐⭐ |
| B3 | 停止路径幂等 + DROP 解阻塞 | 睡死/卡死 | `udd_stop_bridge` | 小 | ⭐⭐ |
| C1 | 数字静音门限（noise gate） | 底噪 | play 写前 | 小 | ⭐⭐ |
| C2 | 增益/HPH Mode 调参 | 底噪 | `route_mm1_slim6.sh` | 小 | ⭐⭐ |
| C3 | 位深统一 S16，去逐帧转换 | 底噪/转换误差 | 格式协商 | 小 | ⭐ |
| D1 | f_uac2 真实 feedback（异步闭环） | 欠载根治 | `f_uac2.c` + 本驱动 | 大 | 二期 |

---

## 二、欠载 / 爆音

### 方案 A1：运行中重预缓冲（refill 状态机）⭐核心

- **根因**：预缓冲只在启动做一次（`udd_play_thread` L735-737）。切歌把 ring 抽空后 play 线程不重缓冲，贴着空 ring 跑，反复 `frames < period` → `udd_ring_underruns++` → 写整周期静音，接缝无过渡。
- **改动位置**：`udd_play_thread`（L713-830）。
- **改法要点**：
  1. 增加状态：`NORMAL` / `STARVED`。
  2. 连续 N 次（建议 3 次）`frames < udd_play.period_frames` 判定进入 `STARVED`。
  3. `STARVED` 期间：仍写静音维持 ALSA stream 不 stop（避免 stop/start 的 pop），但**暂停 drift 校正**。
  4. ring 深度恢复到 `prebuf` 阈值后退出 `STARVED`，恢复正常播放。
- **预期效果**：切歌/断流后不再长期贴空跑，恢复干净，欠载计数大幅下降。
- **风险**：进入 STARVED 期间是纯静音（几 ms~几十 ms），极端情况下可能被感知为短暂停顿；阈值需实测调。
- **验证**：切歌时看 `/sys/kernel/usb_dac_direct/status` 的 `ring_underruns` 是否在切歌后停止增长、`xrun_play` 是否下降。

### 方案 A2：漂移校正改造（按需写 + 平滑控制）⭐核心

- **根因**：长时间欠载的真正主因是 USB 时钟与 tavil 时钟的**双异步漂移**，现有 drift 校正（L796-825）是 bang-bang：偏差超 `UDD_DRIFT_LIMIT_MS=10`（10ms）才 drop/insert 一帧，且每 200ms 最多一次，跟不上持续偏差。play 又**固定写 20ms**，与 capture 实际到达速率脱节。
- **改动位置**：`udd_play_thread` 主循环 + drift 校正段。
- **改法要点**：
  1. play 改为"**读多少写多少**"：按 `udd_ring_read` 实际返回的帧数写（不足部分静音补齐），不再固定写 `period_frames`。
  2. drift 校正改为平滑：对 ring 深度做低通（如 EMA），用 PI 控制器算 drop/insert 量，限制每周期最多 ±1 帧，去掉 bang-bang 阈值抖动。
  3. STARVED 期间（见 A1）挂起校正。
- **预期效果**：长期播放 ring 深度稳定在 target 附近，欠载/过载周期性消失。
- **风险**：PI 增益需要实测整定，增益过大会振荡；建议先加可调模块参数便于现场调。
- **验证**：连续播 1h+，观察 `status` 里 `drift_drops`/`drift_inserts` 是否低频、`ring_frames` 是否稳定。

### 方案 A3：capture 断流检测 + 软重置

- **根因**：`udd_cap_thread`（L682-711）对 `-EPIPE` 只做 PREPARE，对"数据稀疏但无错误"无感知，play 侧被动挨饿。
- **改动位置**：`udd_cap_thread` + 全局原子标志。
- **改法要点**：
  1. capture 连续 K 次（建议 3 次）`r <= 0` 或 xrun，置 `atomic udd_cap_stalled=1`；恢复读到时清零。
  2. play 线程检测到 stalled：清空 ring + 重新预缓冲（软重置）。
- **预期效果**：对真实断流（exclusive/采样率切换）快速软重置，替代被动抽干。
- **风险**：K 太小会误触发；需与 A1 协同，避免两套逻辑打架。
- **验证**：先在 `status` 里暴露 capture 的 xrun/读空计数，确认切歌到底断不断流，再决定是否启用本方案。

### 方案 A4：静音/真实音频接缝 ramp

- **根因**：`memset(playbuf,0)` 后直接 write（L756/L775），音频恢复瞬间从 0 跳变 → 爆音。
- **改动位置**：play 线程写前。
- **改法要点**：在静音块与真实音频块之间做 1~2ms 线性淡入淡出（对首/尾各一两个周期做斜坡）。
- **预期效果**：消除切歌/恢复瞬间的 "pop"。
- **风险**：极低；注意 ramp 长度要短于一个 period，避免引入可闻淡入。
- **验证**：切歌时听爆音是否消失。

---

## 三、睡死

### 方案 B1：补 wakelock ⭐最优先（改动最小、收益最大）

- **根因**：`struct wakeup_source wl_sleep, wl_shutdown;` 已声明（L109-110），但全文件**没有任何** `wakeup_source_init` / `__pm_stay_awake` / `__pm_relax`（已 grep 确认零匹配）。bridge 运行期间不持 wakelock，长时间播放设备进 suspend，RT kthread + `set_fs(KERNEL_DS)` 直驱 PCM 还挂在 ALSA 锁上 → suspend 死锁 → 睡死。
- **改动位置**：`udd_init`（L1371）/`udd_enable`（L1162）/`udd_disable`（L1195）/`udd_exit`（L1402）。
- **改法要点**：
  1. `udd_init`：`wakeup_source_init(&wl_sleep, "usb_dac_direct")`。
  2. `udd_enable` 成功后：`__pm_stay_awake(&wl_sleep)`。
  3. `udd_disable`：`__pm_relax(&wl_sleep)`。
  4. `udd_exit`：`wakeup_source_trash(&wl_sleep)`。
- **预期效果**：bridge 激活期间系统不 suspend，最可能根治"长时间接收睡死"。
- **风险**：极低；副作用是 DAC 激活期间更耗电（本来就是 USB 供电，可接受）。
- **验证**：`/sys/kernel/debug/wakeup_sources` 或 `dumpsys power` 确认 `usb_dac_direct` 持续持有 wakelock；挂机过夜看是否还睡死。

### 方案 B2：降低 RT 优先级

- **根因**：`SCHED_FIFO` 优先级 play=50/cap=40（`udd_thread_rt` L675-680）偏高，可能饿死 suspend/watchdog 等系统关键任务。
- **改动位置**：`udd_thread_rt` 调用处。
- **改法要点**：降到 20 左右，或改用 `SCHED_RR`；甚至用普通优先级 + 靠大 ring 吸收抖动（ring 已 480ms）。
- **预期效果**：降低对系统调度器的干扰，减少卡死诱因。
- **风险**：过低可能引入 play 侧 xrun，需配合 A2 实测。
- **验证**：压力测试下观察是否还有调度导致的异常。

### 方案 B3：停止路径幂等 + DROP 解阻塞

- **根因**：`udd_stop_bridge`（L1021-1038）直接 `kthread_stop`，若 kthread 正阻塞在 ALSA 读/写（DMA 等待）会死等。
- **改动位置**：`udd_stop_bridge`。
- **改法要点**：置 `udd_stop` + 唤醒 ring 后，对 cap/play 的 substream 各发一次 `SNDRV_PCM_IOCTL_DROP` 再 `kthread_stop`；`kthread_stop` 前后加幂等判断。
- **预期效果**：停止/禁用不再卡死，避免一次失败带崩后续。
- **风险**：低。
- **验证**：反复 enable/disable 几十次，看是否偶发卡死。

---

## 四、底噪

### 方案 C1：数字静音门限（noise gate）

- **根因**：Mode A 下 ESS 是 Bypass（`route_mm1_slim6.sh` L104），耳机由 tavil/WCD9340 HPH 驱动；PC 端与 USB 地回路的低电平噪声被原样放大播放。
- **改动位置**：play 线程写前。
- **改法要点**：写前算一帧 RMS，低于阈值（如 -90dBFS）直接输出纯 0（数字静音），抹掉低电平噪声底。
- **预期效果**：无信号时嘶嘶声明显下降。
- **风险**：阈值过高会切掉弱音尾音；需实测调。
- **验证**：暂停播放时听底噪是否消失。

### 方案 C2：增益 / HPH Mode 调参

- **根因**：`route_mm1_slim6.sh` 里 `DIG=84`（L92）数字增益偏高、`RX HPH Mode=CLS_AB_HIFI`（L86）、`Es9018 Volume=180`（L101，bypass 下语义混乱）。
- **改动位置**：`route_mm1_slim6.sh`。
- **改法要点**：
  1. `DIG` 从 84 下调，增益尽量放 HPH 模拟音量（`HPH=16`）而非数字域。
  2. `RX HPH Mode` 试 `CLS_H_HIFI` 对比底噪（脚本 L86 已有 fallback 分支）。
  3. 清理 bypass 下不生效的 `Es9018 Left/Right Volume=180`。
- **预期效果**：降低对底噪的放大。
- **风险**：低；纯调参，可 A/B 对比。
- **验证**：DIG 分别取 60/70/84 对比底噪与响度。

### 方案 C3：位深统一 S16，去逐帧转换

- **根因**：`udd_convert_frame`（L623-669）逐帧做 s16/s24_3le/s24_LE/s32 移位转换，有量化误差。
- **改动位置**：capture/play 格式协商（`udd_try_open_cap/play`）。
- **改法要点**：capture 与 play 都固定 S16_LE（脚本 SLIM Format 已是 `S16_LE`），命中 `udd_cap.format == udd_play.format` 的 memcpy 快路径，跳过转换。
- **预期效果**：减少转换噪声，顺便省 CPU。
- **风险**：低。
- **验证**：确认两路都 S16 后，`status` 无异常、底噪略降。

---

## 五、根治方向（二期）

### 方案 D1：f_uac2 真实 feedback（异步闭环）

- **根因**：双异步时钟是欠载的物理根源。Linux `f_uac2` 有异步模式开关，但默认 feedback 是占位值，未真正闭环。
- **改动位置**：`drivers/usb/gadget/function/f_uac2.c` + 本驱动。
- **改法要点**：
  1. 启用 f_uac2 feedback endpoint（IN 等时）。
  2. 用 **ring 深度**（或 tavil 实际消费采样数）作为误差，换算成 feedback 值（期望每帧采样数）上报。
  3. 主机（Windows `USBAudio2.sys`）据此调整发送速率 → 形成负反馈闭环，ring 深度恒定。
- **预期效果**：从源头消除长期欠载/过载，等效小尾巴的异步方案。
- **风险**：大。Windows 对 feedback 的尊重程度/调速幅度因版本而异；feedback 需低通滤波+限幅，否则抖动会反噬；闭环增益需整定。
- **验证**：先在 Windows 不同版本上实测 feedback 是否被驱动响应。
- **成本**：大，建议二期。

---

## 六、推荐组合与分期

**一期（先压症状，改动小、可快速验证）**：
- `B1 wakelock`（睡死，几乎零风险）
- `A1 refill 状态机` + `A4 ramp`（切歌欠载/爆音）
- `A2 漂移校正改造`（长时间欠载）
- `C1 noise gate` + `C2 调参`（底噪）

**二期（根治）**：
- `A3 capture 软重置`（确认断流后再上）
- `D1 真实 feedback`（治本，需 Windows 兼容性验证）
- `B2/B3`（随稳定性测试结果决定是否上）

---

## 七、给评估 agent 的关键问题

1. A1（refill）与 A2（按需写）是否会互相冲突？更优的合并方式？
2. A2 的 PI 控制器在"USB 1ms 帧 + 主机调速延迟"下，增益/滤波参数怎么整定才不振荡？
3. `set_fs(KERNEL_DS)` 直驱 PCM（L596-620）是否本身就是睡死隐患？是否有更安全的内核态 PCM 操作方式？
4. D1 的 feedback 值，用 ring 深度反推 vs 用 tavil 消费计数反推，哪个更稳？Windows `USBAudio2.sys` 的 feedback 响应行为是否有已知坑？
5. C1 noise gate 的 RMS 阈值与起控/释放时间，对音乐弱音段落是否有可闻损伤？
