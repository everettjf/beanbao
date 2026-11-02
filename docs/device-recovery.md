# Device recovery and retesting

Target: the paired iPhone 11 running iOS 26.0.1 with Relaxin / RootHide. BeanBao packages remain installed after a reboot, but jailbreak injection and SSH may need to be re-enabled. This file does not contain the device UDID, private key, host key, or model key.

## After a reboot

1. Connect USB, unlock the phone, and confirm Xcode CoreDevice can see it.
2. Through copyapp's USB iCTRL channel, open the installed Relaxin app and inspect its current screen. Run Jailbreak, then wait for `jailbreakd` and `hookd` to return. Do not reuse button coordinates from an old screenshot.
3. In the copyapp environment, run `pymobiledevice3 usbmux forward <local-port> 22 --serial <device-UDID>`. Use its paired SSH identity and fixed `known_hosts` file, with `IdentitiesOnly` and strict host-key checking.
4. As mobile, run `beanbaoagentctl status`. As root, check `dpkg-query -W dev.beanbao.bridge dev.beanbao.agent dev.beanbao.deliverybrowser dev.beanbao.app` and `launchctl print user/501/dev.beanbao.agent`.
5. With the phone unlocked and screen on, run **Open Settings** from BeanBao. Require Agent phase `done` and foreground bundle ID `com.apple.Preferences`. For a Maps search, start from a screen without possible credentials.

RootHide's SSH shell and app/launchd see different `/var/mobile` paths. `beanbaoagentctl` checks both Agent socket paths. Do not reinstall packages just because the first socket path is invisible from SSH. The audit file appears in the SSH view at `/rootfs/private/var/mobile/Library/Application Support/BeanBao/audit.jsonl`. If the Agent is not running, inspect `launchctl print user/501/dev.beanbao.agent` before considering `launchctl kickstart -k user/501/dev.beanbao.agent`.

## USB retest commands

Use the paired files from the copyapp project. Do not copy the SSH private key into this repository.

```sh
python3 scripts/verify_device.py --host 127.0.0.1 --port <forwarded-port> \
  --identity <private-key-path> --known-hosts <known-hosts-path> --expect-bundle
python3 scripts/accept_text_device.py --host 127.0.0.1 --port <forwarded-port> \
  --identity <private-key-path> --known-hosts <known-hosts-path>
python3 scripts/accept_app_text_device.py --host 127.0.0.1 --port <forwarded-port> \
  --identity <private-key-path> --known-hosts <known-hosts-path>
```

Frida was used only during an earlier, temporary investigation of SpringBoard Volume Down events. It is not a BeanBao runtime dependency. That investigation ended after a client/server protocol mismatch and device reboot; the cause of the reboot was not established. The physical shortcut still needs acceptance using real button presses, normal volume behavior, and the app's recording state.
