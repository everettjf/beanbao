<p align="center"><img src="design/beanbao-icon-1024.png" alt="A smiling BeanBao steamed bun" width="112" /></p>
<h1 align="center">BeanBao</h1>
<p align="center"><strong>A voice and text assistant for a jailbroken iPhone.</strong><br />
Ask naturally. Review the request. Let the phone carry out a bounded task.</p>
<p align="center"><a href="README.md">English</a> · <a href="README.zh-CN.md">简体中文</a></p>
<p align="center"><a href="https://github.com/everettjf/beanbao/releases/tag/v0.3.75">Download v0.3.75</a> · <a href="#quick-start">Quick start</a> · <a href="docs/install-and-configure.md">Install guide</a> · <a href="https://xnu.app/beanbao/">Website</a></p>

BeanBao's two apps, Bridge, and task Agent run on the iPhone. A Mac is not
needed after installation.

> **Release status:** public developer preview. It has been installed and
> tested on one iPhone 11 with iOS 26.0.1, Relaxin 0.5.5, and RootHide. Other
> devices, jailbreaks, and iOS versions have not been validated. See the
> [release record](docs/release-0.3.75.md) for exact packages and checksums.

## Architecture at a glance

![Diagram showing BeanBao and BeanBao Helper as two visible iPhone apps, with an on-device Agent, SpringBoard Bridge, and optional model provider.](design/architecture.svg)

| Visible app | What it does |
| --- | --- |
| <img src="design/beanbao-icon-1024.png" alt="" width="36" /> **BeanBao** | Starts voice and text requests; shows Sessions, progress, settings, PDFs, and decisions that need your review. |
| <img src="design/beanbao-helper-icon-1024.png" alt="" width="36" /> **BeanBao Helper** | Provides a normally sandboxed interactive surface. Its current supported workflow is Uber Eats; future native or web features need separate implementation and validation. |

The **Agent** plans, checks, and records each step. The **SpringBoard Bridge**
handles the quick voice overlay and bounded actions in supported iOS apps.
BeanBao Helper uses a restricted, paired channel to the Agent; it cannot use
the main App's broader device access. A user-configured model service is used
only for requests that need it. [Read the two-app design](docs/two-app-architecture.md).

## What works today

| Request or flow | Current behavior |
| --- | --- |
| “Open Settings”, “Open Maps”, “Open Contacts”, “Open Notes” | Opens the app and verifies that it reached the foreground. |
| “Create note: BeanBao test note” | Creates a new note and checks its title in Notes. |
| “Search Maps for Golden Gate Bridge” | Searches Maps and checks the place card. The selected model may receive a Maps screenshot when needed. |
| Triple press Volume Down | Shows one bottom overlay, starts Apple speech transcription, and lets you review the text before **Run**. The shortcut is off by default. |
| “Research on-device speech recognition on iOS, create a PDF with sources” | Runs a saved multi-step research workflow and opens its sourced PDF from **Sessions**. |
| Research + addressed email draft + App Store lookup | Prepares independent review steps. The user handles sending in Apple Mail and installing in the App Store. |
| Food delivery | The separate sandboxed web app can find an Uber Eats item, configure options, and review a cart. Real checkout is unverified; a final order requires an explicit review and tap. |

BeanBao is deliberately bounded. It does not offer arbitrary-app tapping,
silent App Store installation, automatic email sending, or unattended payment.
See [common requests](docs/common-cases.md) and [complex workflow limits](docs/complex-workflows.md).

### How a task runs

```mermaid
flowchart LR
    A[Voice or text] --> B[BeanBao]
    B --> C[Agent plans and checks]
    C --> D{Supported path}
    D --> E[Bridge: iOS apps]
    D --> F[Helper: website]
    E --> G[Observe result]
    F --> G
    G --> H{Verified?}
    H -->|Yes| I[Save receipt in Sessions]
    H -->|Uncertain| J[Pause for review]
    classDef warm fill:#fff0df,stroke:#d7764c,color:#4b3029;
    classDef soft fill:#fffaf3,stroke:#cba186,color:#4b3029;
    class B,C,I warm;
    class A,D,E,F,G,H,J soft;
```

## Quick start

### 1. Check your device

You need an already jailbroken iPhone with a working **RootHide** environment,
`iphoneos-arm64e` package support, and a root shell or paired root SSH for
installation. The only verified combination is listed above. BeanBao does not
install or configure the jailbreak.

### 2. Get and verify the release archive

Download the uncompressed `BeanBao-RootHide-*.tar` from the [GitHub Releases
page](https://github.com/everettjf/beanbao/releases). Compare its SHA-256 with
the value in that release's notes:

```sh
shasum -a 256 BeanBao-RootHide-*.tar
```

The current package versions and archive hashes are in the
[release record](docs/release-0.3.75.md).

### 3. Install from a root shell on the phone

Transfer the verified `.tar` to the phone, then run these commands in the
directory containing it. Substitute its exact filename for `RELEASE.tar`:

```sh
mkdir -p beanbao-release
tar -xf RELEASE.tar -C beanbao-release
cd beanbao-release
sh install.sh --dry-run
sh install.sh
```

The installer checks all four package hashes, package IDs, architecture, and
versions before changing the device. It installs only changed packages. If you
already have paired root SSH, the [Mac transfer helper](docs/install-and-configure.md#packages)
can verify, transfer, preflight, and install the same archive in one command.

### 4. Activate and configure

After a new or updated **Bridge** package, reload SpringBoard once and unlock
the phone. Upgrading from v0.3.72 changes only the two apps and needs no
SpringBoard reload. The installer does not reload it automatically. Open BeanBao, tap
**Change** on the **Model service** card, and enter your own Claude API key and
model name. Keep the key out of chat, screenshots, release archives, and shell
history. App opening and note creation run locally; research and delivery
planning require Claude. OpenAI or a compatible HTTPS model can be selected for
bounded UI interpretation.

Start with **Open Settings** in the text field and tap **Start**. Then try
**Create note: BeanBao test note** or **Search Maps for Golden Gate Bridge**.
Enable **Quick launch** in BeanBao if you want the Volume Down shortcut.

For model settings, voice setup, Sessions, recovery, and the food-delivery
review flow, follow the [complete installation and configuration guide](docs/install-and-configure.md).

## Build from source

On macOS, install Xcode, Swift, Python 3, and a
[RootHide-compatible Theos checkout](https://github.com/roothide/Developer).
Set `THEOS` to that checkout. The build runs the native, Python, browser, and
Swift Harness checks before auditing and packaging four RootHide `.deb` files:

```sh
git clone https://github.com/everettjf/beanbao.git
cd beanbao
THEOS=/absolute/path/to/roothide-theos ./scripts/build_packages.sh
python3 scripts/prepare_release_bundle.py
```

The archives appear in ignored `dist/`. The package build requires the RootHide
Theos toolchain; stock Theos or rootless packages are not interchangeable with
this `iphoneos-arm64e` release. See [build and device tests](docs/build-and-test.md).

## How it is put together

| Directory | Purpose |
| --- | --- |
| `bridge/` | Restricted SpringBoard observation, input actions, and voice overlay. |
| `agent-native/` and `harness/` | On-device task service, model clients, policy, and resumable workflows. |
| `app/` | BeanBao UI, Apple speech transcription, model settings, Sessions, Activity, and review screens. |
| `delivery-browser/` | BeanBao Helper, a sandboxed app currently limited to the experimental Uber Eats flow. The source directory keeps its historical name to preserve package identity and website data. |
| `vendor/` | Pinned ios-mcp and PalminoHarnessKit source snapshots with their original notices. |
| `scripts/` and `tests/` | Build, package audit, installer, and acceptance tooling. |
| `web/` | Buildless GitHub Pages website. |

The Bridge accepts one action per fresh observation and checks the unlocked
state, foreground app, action bounds, and supported app list. Workflow records
survive an Agent restart; uncertain external actions stop for review rather
than being repeated. The Agent's private audit stores bounded event metadata,
while saved **Sessions** also contain the original workflow request and
artifacts. Model-assisted steps can send task text and selected screen content
to the configured provider. See [UI and data details](docs/ui-and-activity.md).

## Current limits and testing

- A physical USB-disconnect text task and reboot recovery passed on the paired
  phone. Text and spoken overlay tasks, Claude Maps search, a six-step research
  workflow, and PDF preview also passed. See the [device test record](docs/build-and-test.md).
- Apple Mail composition remains untested on a configured mail account; no
  email was sent in acceptance testing.
- Uber Eats required sign-in before a real checkout. The final order click and
  order-history path have synthetic tests only; no real order was placed.
- iOS 26 accessibility coordinates for some scrolling rows differ from the
  visible screen. Arbitrary-app UI automation is not released.
- This is a developer install, not a one-tap package source. First installation
  on another phone still needs validation.

## License and upstream code

BeanBao-authored code is [Apache-2.0](LICENSE), copyright 2026 everettjf.
Vendored code keeps its own licenses and notices; see [THIRD_PARTY.md](THIRD_PARTY.md)
and [NOTICE](NOTICE). The ios-mcp snapshot is retained as source reference;
BeanBao builds only selected files into its restricted Bridge.
