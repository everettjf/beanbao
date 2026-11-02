# Install and configure BeanBao

Updated November 2, 2026. This is a developer installation procedure for a compatible Relaxin / RootHide jailbreak. The tested device is an iPhone 11 running iOS 26.0.1 and Relaxin 0.5.5. Other devices require their own validation.

## Packages

Install these RootHide `iphoneos-arm64e` packages in order:

1. `dev.beanbao.bridge` 0.2.13: restricted SpringBoard observation, UI actions, and quick voice overlay.
2. `dev.beanbao.agent` 0.3.66: on-device task service, model interpretation, resumable research and App Store workflows, and a delivery page classifier/review gate.
3. `dev.beanbao.app` 0.3.33: native text, Apple voice transcription, Sessions, App Store review, a food-delivery browser with page checks, Activity, shortcut, and model settings UI.

The packages are under `bridge/packages/`, `agent-native/packages/`, and `app/packages/`. Build from source on a Mac with the RootHide Theos toolchain:

```sh
THEOS=/absolute/path/to/roothide-theos ./scripts/build_packages.sh
python3 scripts/prepare_release_bundle.py
```

The build script runs native policy, Python, and Swift Harness tests and audits package contents, dependencies, architectures, signatures, and launch identity. The bundle script creates a portable archive with the three `.deb` files, `SHA256SUMS`, and an English `INSTALL.md`. It contains no model keys, SSH credentials, or device data.

With a root shell on the jailbroken phone, copy over the packages and install them in this order:

```sh
dpkg -i dev.beanbao.bridge_0.2.13_iphoneos-arm64e.deb
dpkg -i dev.beanbao.agent_0.3.66_iphoneos-arm64e.deb
dpkg -i dev.beanbao.app_0.3.33_iphoneos-arm64e.deb
dpkg-query -W dev.beanbao.bridge dev.beanbao.agent dev.beanbao.app
```

After installing or updating Bridge, reload SpringBoard to enable its injection, then unlock the phone. Updating only Agent or App does not require a SpringBoard reload. BeanBao does not provide an installer for other apps. A public software source and one-tap installer are not available yet.

To check the connected development device, run `python3 scripts/verify_device.py --host 127.0.0.1 --port <forwarded-port> --identity <private-key-path> --known-hosts <known-hosts-path> --expect-bundle`. This checks versions, the Agent service, and Bridge observation; it does not replace a real task test.

## First use

1. Unlock the phone and open BeanBao. Tap **Change** on the **Model service** card. Choose **Claude** for research and App Store workflows, and enter your own key and model name. The older bounded UI tasks can also use OpenAI or a Compatible API. For a compatible service, enter its HTTPS base URL, such as `https://example.com/v1`, and choose a model that accepts images. Each service has a separate key file owned by the mobile user with mode `0600`. A key is needed for model-assisted Maps search, while opening apps and creating notes work locally.
2. Tap a quick action or enter **Open Maps**, **Open Settings**, **Open Contacts**, or **Open Notes**, then tap **Start**. The app reports completion only after checking the actual foreground app. Chinese commands from earlier versions remain accepted.
3. Try **Create note: BeanBao test note**. BeanBao creates a new note, returns to the list, and checks for its complete title. It will not edit an existing note. Avoid reusing the same test title.
4. Try **Search Maps for Golden Gate Bridge**. BeanBao may send a Maps screenshot to the selected model when local actions are insufficient. It searches and checks the place marker and card; it does not start navigation. It stops if the phone locks, the UI changes unexpectedly, or possible credentials appear on screen.
5. Tap **Voice input**, speak an English request, then tap **Stop recording**. Check or edit the transcript before tapping **Start**. iOS 26 uses on-device English dictation where available and may download a language asset on first use. Audio is removed after transcription. Recording stops automatically after 30 seconds.
6. For a multi-step research test, enter **Research on-device speech recognition on iOS, create a PDF with sources**. Open **Sessions** to revisit the result and **View PDF report** to inspect it. The current Claude workflow can also prepare an email draft addressed to an explicit recipient. Apple Mail must have an account configured before **Review email draft** can open its native composer; review the recipient and attachment there before sending.
7. For an App Store handoff, enter **Find app Apple Pages**. Review the exact name, developer, product ID, bundle ID, and price before opening the official listing. Installing is a separate user action in the App Store. After that, **Check installation** verifies the matching bundle; simply closing the listing leaves the workflow pending.
8. Tap **Browse food delivery** to open Uber Eats inside BeanBao. The browser keeps its own website session. Tap **Check** to classify the visible page through the on-device Agent. It does not read the Uber sign-in page or place an order. The model-driven search, cart construction, and exact checkout review are still in development.

The **Quick launch** Volume Down triple-press switch is off by default. A normal press still changes volume. Triple press opens the quick overlay and asks the BeanBao app to start recording. On the tested phone, a real spoken request completed from both an app and the unlocked Home screen. From Home, the overlay started recording and **Open Settings** brought Settings to the foreground.

## Data and limits

Keys and settings stay on the phone. The Agent audit file records a limited set of task events and results, without request text, note content, screenshots, model replies, or keys. On the tested RootHide device, the SSH view of this file is `/rootfs/private/var/mobile/Library/Application Support/BeanBao/audit.jsonl`.

BeanBao cannot silently install apps or send email without the user's action in the system interface. It cannot make payments, place orders, or delete content. The delivery review gate and Uber Eats page contract exist, but the site is not yet driven by the workflow coordinator. BeanBao runs on the phone without a Mac, iCTRL, or Frida; those tools are used for development and verification. One previous version passed a physical USB-disconnect test. The current version still needs that test, a reboot recovery test, and validation on other devices. See [device tests](build-and-test.md) and [human acceptance](human-acceptance.md).
