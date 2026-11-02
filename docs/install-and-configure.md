# Install and configure BeanBao

Updated November 1, 2026. This is a developer installation procedure for a compatible Relaxin / RootHide jailbreak. The tested device is an iPhone 11 running iOS 26.0.1 and Relaxin 0.5.5. Other devices require their own validation.

## Packages

Install these RootHide `iphoneos-arm64e` packages in order:

1. `dev.beanbao.bridge` 0.2.11: restricted SpringBoard observation, UI actions, and quick voice overlay.
2. `dev.beanbao.agent` 0.3.59: on-device task service and model interpretation of natural requests.
3. `dev.beanbao.app` 0.3.27: native text, Apple voice transcription, activity, shortcut, and model settings UI.

The packages are under `bridge/packages/`, `agent-native/packages/`, and `app/packages/`. Build from source on a Mac with the RootHide Theos toolchain:

```sh
THEOS=/absolute/path/to/roothide-theos ./scripts/build_packages.sh
python3 scripts/prepare_release_bundle.py
```

The build script runs native policy, Python, and Swift Harness tests and audits package contents, dependencies, architectures, signatures, and launch identity. The bundle script creates a portable archive with the three `.deb` files, `SHA256SUMS`, and an English `INSTALL.md`. It contains no model keys, SSH credentials, or device data.

With a root shell on the jailbroken phone, copy over the packages and install them in this order:

```sh
dpkg -i dev.beanbao.bridge_0.2.11_iphoneos-arm64e.deb
dpkg -i dev.beanbao.agent_0.3.59_iphoneos-arm64e.deb
dpkg -i dev.beanbao.app_0.3.27_iphoneos-arm64e.deb
dpkg-query -W dev.beanbao.bridge dev.beanbao.agent dev.beanbao.app
```

After installing or updating Bridge, reload SpringBoard to enable its injection, then unlock the phone. Updating only Agent or App does not require a SpringBoard reload. BeanBao does not provide an installer for other apps. A public software source and one-tap installer are not available yet.

To check the connected development device, run `python3 scripts/verify_device.py --host 127.0.0.1 --port <forwarded-port> --identity <private-key-path> --known-hosts <known-hosts-path> --expect-bundle`. This checks versions, the Agent service, and Bridge observation; it does not replace a real task test.

## First use

1. Unlock the phone and open BeanBao. Tap **Manage** on the **Current model** card. Choose **Claude**, **OpenAI**, or **Compatible API**. Enter a model name and your own key. For a compatible service, also enter its HTTPS base URL, such as `https://example.com/v1`, and choose a model that accepts images. Each service has a separate key file owned by the mobile user with mode `0600`. The existing Claude key from previous BeanBao versions remains usable. A key is needed for model-assisted Maps search, while opening apps and creating notes work locally.
2. Tap a quick action or enter **Open Maps**, **Open Settings**, **Open Contacts**, or **Open Notes**, then tap **Start**. The app reports completion only after checking the actual foreground app. Chinese commands from earlier versions remain accepted.
3. Try **Create note: BeanBao test note**. BeanBao creates a new note, returns to the list, and checks for its complete title. It will not edit an existing note. Avoid reusing the same test title.
4. Try **Search Maps for Golden Gate Bridge**. BeanBao may send a Maps screenshot to the selected model when local actions are insufficient. It searches and checks the place marker and card; it does not start navigation. It stops if the phone locks, the UI changes unexpectedly, or possible credentials appear on screen.
5. Tap **Voice input**, speak an English request, then tap **Stop recording**. Check or edit the transcript before tapping **Start**. iOS 26 uses on-device English dictation where available and may download a language asset on first use. Audio is removed after transcription. Recording stops automatically after 30 seconds.

The **Quick launch** Volume Down triple-press switch is off by default. A normal press still changes volume. Triple press opens the quick overlay and asks the BeanBao app to start recording. The physical button has opened the overlay on the tested phone, but automatic recording is still under acceptance testing.

## Data and limits

Keys and settings stay on the phone. The Agent audit file records a limited set of task events and results, without request text, note content, screenshots, model replies, or keys. On the tested RootHide device, the SSH view of this file is `/rootfs/private/var/mobile/Library/Application Support/BeanBao/audit.jsonl`.

BeanBao cannot install apps, send messages, make payments, or delete content. It runs on the phone without a Mac, iCTRL, or Frida; those tools are used for development and verification. One previous version passed a physical USB-disconnect test. The current version still needs that test, a reboot recovery test, and broader Maps and voice acceptance. See [device tests](build-and-test.md) and [human acceptance](human-acceptance.md).
