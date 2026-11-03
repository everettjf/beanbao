# BeanBao 0.3.72 developer preview

Published November 3, 2026 for an already jailbroken RootHide iPhone. The only tested device is an iPhone 11 running iOS 26.0.1 with Relaxin 0.5.5. Other devices, jailbreaks, and iOS versions need their own validation. This is a root-shell installation, not an App Store or one-tap package-source install.

## Packages

| Package | Version | Role |
| --- | --- | --- |
| `dev.beanbao.bridge` | 0.2.14 | Restricted SpringBoard UI bridge and quick voice overlay. Screen content is withheld when the phone is locked or the foreground app is outside the supported list. |
| `dev.beanbao.agent` | 0.3.118 | On-device task service, model routing, resumable workflows, and delivery channel. |
| `dev.beanbao.deliverybrowser` | 0.1.21 | Sandboxed Uber Eats browser for experimental delivery tasks. |
| `dev.beanbao.app` | 0.3.72 | Text/voice input, model settings, Sessions, Activity, PDF and review UI. |

The release contains these four `iphoneos-arm64e` packages, `SHA256SUMS`, `install.sh`, and `INSTALL.md`. It does not contain a model key, SSH credential, or phone data.

## Archives and SHA-256

```text
ff451a380b54dba4ad70d9e3c612d8324291afb45bddc629c6337e182f7fa0c0  BeanBao-RootHide-b0.2.14-a0.3.118-browser0.1.21-app0.3.72.tar
3c03f81607dc3cdb2a56e3099b0f259fb53722f1a86a9c6f4996effe0af44a23  BeanBao-RootHide-b0.2.14-a0.3.118-browser0.1.21-app0.3.72.tar.gz
```

Use the uncompressed `.tar` for direct extraction on the phone. Compare the downloaded SHA-256 with this record, extract it in a root shell, run `sh install.sh --dry-run`, then run `sh install.sh`. A new or updated Bridge needs one manual SpringBoard reload and unlock; the installer does not do this. Follow [the full guide](install-and-configure.md).

## Verification

- The November 3 source build passed native policy checks, 90 Swift Harness tests, Python and browser tests, the Bridge content audit, and the four-package audit.
- The current archive passed its phone-side checksum and package preflight; all four matching versions were retained without changing the service.
- `verify_device.py --expect-bundle` confirmed the four installed versions, Agent 0.3.118 responding, a responsive Bridge, and an unlocked, screen-on BeanBao App.
- Prior same-path device runs passed text and spoken tasks, Maps searches, PDF preview, a physical USB-disconnect text task, reboot recovery, and a bounded Uber Eats cart review. See [the device record](build-and-test.md). A fresh full scenario run on every package byte of this archive was not performed.

## Limits

- The experimental delivery browser is a separate sandboxed app. An attempted in-app WebView rendered a blank viewport on the tested iOS 26 phone while the main App retained its current no-sandbox entitlement, so that build was not released.
- Real signed-in delivery checkout, final order placement, Apple Mail composition on a configured account, and a fresh App Store installation remain unverified. No purchase, mail send, or app install was performed for this release.
- The delivery browser currently receives an in-memory pairing token through its custom URL launch. A static review identified a possible competing URL handler interception on a phone with another app registered for that scheme. The loopback channel has a restricted operation set, but this handoff should be replaced before treating delivery as a stable feature. See [the public release record](public-release-checklist.md).
- Arbitrary-app UI tapping is not released. The current Bridge limits observation and action to supported foreground apps and checks fresh screen state.
