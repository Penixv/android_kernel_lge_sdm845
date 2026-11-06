# Mode A: kernel `usb_dac_direct` (BakaSU)

Root stack: **BakaSU + hybrid mount** (not Magisk).  
`usb_dac_direct` is **built into the kernel** (`CONFIG_USB_DAC_DIRECT=y`), same Image as `CONFIG_KSU=y`. It is not a `.ko` / Magisk module.

## Sysfs (after flash + reboot)

| Path | Meaning |
|------|---------|
| `/sys/kernel/usb_dac_direct/enable` | `1` start / `0` stop |
| `/sys/kernel/usb_dac_direct/gain` | digital gain percent 0–150 |
| `/sys/kernel/usb_dac_direct/status` | frames / xruns / route_ok |

Boot param: `usb_dac_direct.enable=0` blocks sysfs enable (rollback).

## Userspace helper (`usb_dac_manager`)

Install via **BakaSU** module manager (`/data/adb/modules/…`, hybrid mount OK).  
`usb_dac_ctl.sh` Mode A:

1. Bind UAC2+ADB
2. Pre-route with `route_mm1_slim6.sh` (PCM still closed)
3. `echo 1 > enable` — kernel opens UAC+MM1 only (no DAPM/volkeys by default)
4. userspace `volkey_block` + volume-only `route_keepalive` protect volume; no mixer access occurs while PCM is open
5. Else → legacy `usb_dac_bridge` fallback

`MODE_A_KERNEL=0` in `/data/adb/usb_dac/config` forces userspace.

## Flash

1. `build_judyln.sh` → `out/arch/arm64/boot/Image.gz-dtb`
2. Copy into `AnyKernel3/` → zip `AnyKernel3-judyln-UAC2-BakaSU-*.zip`
3. Flash zip in recovery / Kernel Flasher
4. Reboot; install/update `usb_dac_manager` zip in BakaSU; enable Mode A
