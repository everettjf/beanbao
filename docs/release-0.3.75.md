# BeanBao 0.3.75 developer preview

Published November 3, 2026 for an already jailbroken RootHide iPhone. The
only tested device is an iPhone 11 running iOS 26.0.1 with Relaxin 0.5.5.
Other devices, jailbreaks, and iOS versions need their own validation. This is
a root-shell install, not an App Store or one-tap package-source release.

## What changed

- The second visible app is now **BeanBao Helper**, with a distinct warm icon.
  It remains a sandboxed interactive surface; its supported workflow today is
  Uber Eats item and cart review. The package and bundle IDs remain
  `dev.beanbao.deliverybrowser` so upgrades retain the existing website data.
- The main BeanBao App opens it through **Open Helper · Food delivery**.
- The English and Simplified Chinese READMEs show the two-app architecture and
  task flow. The website and installation guide use the new public name.

## Packages

| Package | Version | Role |
| --- | --- | --- |
| `dev.beanbao.bridge` | 0.2.14 | Restricted SpringBoard UI bridge and voice overlay. |
| `dev.beanbao.agent` | 0.3.118 | Local task service, policy, resumable workflows, and restricted Helper channel. |
| `dev.beanbao.deliverybrowser` | 0.1.24 | **BeanBao Helper** sandboxed app. |
| `dev.beanbao.app` | 0.3.75 | **BeanBao** text, voice, Sessions, Activity, PDF, and review UI. |

The release archives contain the four `iphoneos-arm64e` packages, `SHA256SUMS`,
`install.sh`, and `INSTALL.md`. They contain no model key, SSH credential, or
phone data.

## Archives and SHA-256

```text
cc8dbdd608cd5bcefb049731d4e03fd1a616f9c4faeceb891fbd96da039a2857  BeanBao-RootHide-b0.2.14-a0.3.118-browser0.1.24-app0.3.75.tar
1a18ea55ad741d36f58c6c01c214a1d4d0eb4628faa98b20f93e644f27ac4fa3  BeanBao-RootHide-b0.2.14-a0.3.118-browser0.1.24-app0.3.75.tar.gz
```

Use the uncompressed `.tar` for direct extraction on the phone. Compare its
SHA-256 with this record, extract it in a root shell, run
`sh install.sh --dry-run`, then `sh install.sh`. The archive checks the four
package hashes, identities, architecture, and versions before changing the
device. An upgrade from v0.3.72 changes only the two apps and requires **no
SpringBoard reload**. A first installation or Bridge update requires one
manual SpringBoard reload and unlock. See the [installation guide](install-and-configure.md).

## Verification

- The final source build passed native policy and activity checks, Python
  browser and installer tests, 90 Swift Harness tests, and the four-package
  contents, signing, dependency, and distinct-icon audit.
- The connected phone passed archive checksum and dry-run preflight. The
  installer upgraded Helper 0.1.21 → 0.1.24 and App 0.3.72 → 0.3.75 while
  retaining Bridge 0.2.14 and Agent 0.3.118. It refreshed app icons without
  reloading SpringBoard.
- `verify_device.py --expect-bundle` confirmed all four installed versions, a
  responding Agent and Bridge, and the phone unlocked with the screen on.
  Both updated app processes were started after installation.
- Earlier real-device runs passed text and spoken tasks, Maps search, PDF
  preview, a physical USB-disconnect task, reboot recovery, and bounded Uber
  Eats cart review. These flows were not all rerun on the renamed build.

## Limits

- The Helper supports the bounded Uber Eats workflow, not arbitrary website or
  native-app automation. Signed-in checkout, final order placement, and order
  history reconciliation have synthetic coverage only; no real order was
  placed. Apple Mail composition on a configured account and a fresh App Store
  installation are also unverified.
- Helper pairing still passes an Agent-lifetime token through a custom URL launch.
  Another app registering the same URL scheme could intercept that launch.
  The Agent's loopback channel restricts operations, but the handoff needs a
  stronger binding before treating website tasks as stable.
- First installation on another compatible phone has not been verified.

See the [architecture](two-app-architecture.md) and [device test record](build-and-test.md).
