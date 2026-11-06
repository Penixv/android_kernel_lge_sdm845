Phone USB DAC (judyln) — enumerate + hear sound

Windows showing "扬声器 (Source/Sink)" / "USB Audio DAC" only means
USB descriptors work. Sound needs a PCM bridge on the phone:

  UAC2 capture (PC -> phone)  ==bridge==>  tavil playback (speaker/HP)

1) Flash AnyKernel3-judyln-UAC2-ADA-*.zip, reboot

2) Push scripts:
     adb push enable_usb_dac.sh disable_usb_dac.sh usb_dac_bridge.sh /sdcard/

3) From phone local root (Termux):
     su -c "sh /sdcard/enable_usb_dac.sh"
   enable auto-starts the bridge. Or manually:
     su -c "sh /sdcard/usb_dac_bridge.sh start"

4) On Windows: set default playback to that USB speaker, play music.
   Phone needs tinycap+tinyplay (/system/bin on Lineage).
   Bridge stops audioserver so it can open tavil.

5) If still silent: plug wired headset and retry (speaker mixer is picky).
   Check: su -c "sh /sdcard/usb_dac_bridge.sh status"
   Log: /data/local/tmp/usb_dac_bridge.log

6) Restore:
     su -c "sh /sdcard/disable_usb_dac.sh"
   or reboot.
