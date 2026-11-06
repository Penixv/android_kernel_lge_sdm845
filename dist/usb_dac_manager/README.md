# USB DAC Manager

## Clean flash
Every install (customize.sh / update-binary):
1. Stops old `usb_dac_*` / watch processes
2. Deletes previous module dirs (`modules` + `modules_update`)
3. Deletes `/data/adb/usb_dac` runtime state
4. Writes fresh default `config` + `state=idle`

Uninstall also clears `/data/adb/usb_dac` via `uninstall.sh`.

## Install
Flash `usb_dac_manager-v4.5.8.zip`, **reboot**, open the USB DAC Manager app or module WebUI. The bundled app v1.1.3 is installed after Android finishes booting.

## v4.5.8 changes

- Windows sees Mode A as “LG G7 DSP” (PID DA06) and Mode B as “HIFI PLAYER” (PID DA05). Mode switching unbinds and rebinds the gadget with the selected identity.

## v4.5.7 changes

- Disable lock ownership now checks the running manager script and disable action, so stale locks left by interrupted shutdowns are recovered safely. Cleanup removes only the lock PID marker and empty directory.

## v4.5.6 changes

- Increased the Mode A PCM ring buffer from 120 ms to 500 ms and startup prebuffer from 40 ms to 100 ms to absorb USB/AFE scheduling jitter.
- Replaced once-per-second cumulative-frame drift correction with queue-depth correction that ignores startup prebuffer offset and gently slips one frame at most every 200 ms.
- Exposed ring-buffer underruns, overruns, and current occupancy in WebUI status for diagnosis. A fixed UAC2 endpoint is still configured for stereo 48 kHz; high-resolution PC sources are resampled by the host audio engine.

## v4.5.5 changes

- Bundled USB DAC Manager app v1.1.3 and install/update it after boot if the same version is not already installed.

## v4.5.4 changes

- A hot switch from the Mode B AAudio bridge to Mode A now restarts audioserver after stopping AAudio, then rebuilds the stereo route.

## v4.5.3 changes

- APK actions wait for a background status read instead of silently dropping taps.
- Mode A startup aborts if a required left or right stereo mixer route cannot be applied.

## v4.5.2 changes

- Manual and unplug-triggered shutdowns share an atomic lock. Duplicate requests wait for or detect the first cleanup instead of racing audio, USB, notification, or volume restoration.
- Completed shutdown is recognized from the idle state plus inactive bridge checks, so a later duplicate disable is a no-op.

## v4.5.1 changes

- If the UDC reports the USB host link disconnected for three consecutive 2-second checks, automatically disable the DAC and restore saved media/headset/speaker volume. USB configfs rebinding states do not trigger this guard.

## v4.5.0 changes

- USB connect prompts are handled by the APK notification; the module's volume-key USB prompt is off by default.
- Hide Android USB charging and USB ADB notices during a DAC session, then restore the previous settings on disable or next boot. ADB transport itself remains enabled.
- Removed manual refresh/reconnect and mixer profile buttons from WebUI; status already refreshes automatically.

## v4.4.9 changes

- Verify `SLIM_6_RX Channels=Two` before opening the Mode A kernel PCM; abort startup if stereo routing cannot be confirmed.

## v4.4.8 changes

- Removed periodic `tinymix` reads/writes while Mode A PCM is open; playback keepalive now uses the kernel sysfs volume control only.
- Mixer capture/apply commands also refuse to run while the kernel direct bridge is active.

## v4.4.7 changes

- Changing Mode A/B while enabled replaces the running supervisor and bridge, so the active path follows the WebUI selection.
- Mode A kernel-direct is reported as Mode A in status.
- Mode B no longer forces media/headset volume to maximum. Mode A's volume lock caps at 10 and never raises a lower pre-DAC setting. Disable restores the saved headset, speaker, and media levels, including a saved mute.
