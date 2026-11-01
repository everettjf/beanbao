# BeanBao implementation plan for Relaxin / iOS 26

Updated October 31, 2026. The first target is the connected iPhone 11 running iOS 26.0.1 with Relaxin 0.5.5 and RootHide. Earlier detailed research notes are available in Git history through commit `b55e882`.

## Goal and architecture

BeanBao is an on-device assistant that accepts a short typed or spoken request, performs a bounded GUI task, and reports a result only after checking the phone's actual UI. It uses three RootHide packages:

| Component | Role |
| --- | --- |
| Bridge | A minimal SpringBoard component that observes the screen and performs restricted launch, tap, swipe, key, and text actions. It has no general shell, file, app-install, payment, or message route. |
| Agent | A mobile-owned launchd service with a private Unix socket. It interprets natural requests into bounded tasks, runs local tasks or model-assisted Maps steps through Palmino Harness, enforces per-step policy, and records a limited audit. |
| App | Native UIKit home, text and voice input, progress and stop controls, Volume Down shortcut switch, and settings for Claude, OpenAI, or an OpenAI-compatible HTTPS API. |

The Agent allows only opening Settings, Maps, Contacts, or Notes; creating a new note; and searching Maps for a place. It requires the phone to be unlocked, the screen to be on, and observations to be fresh. Exact supported phrases use a local fast path; other natural requests are interpreted by the selected model into a canonical task and validated against the same allowlist. Fixed app openings and note creation execute locally. Maps search uses local actions where possible and invokes the selected model when it needs to interpret the current Maps UI. A screenshot is considered only after a sensitive-content check. Model output is validated before any action. A task can stop if the screen changes or the result cannot be verified.

The UI and default examples are English. The Agent maps English phrases to its existing restricted task representation. Chinese commands remain accepted for compatibility. On iOS 26, voice uses an English `DictationTranscriber` asset; the editable transcript must be confirmed before execution. The Volume Down triple-press shortcut is optional and off by default.

## Delivery stages

1. **Text control:** Build and install the three packages; verify app openings, note creation, Maps search, forbidden-request rejection, task identity, and actual foreground state on the target phone. This stage passed with Claude in previous builds. The current English build has passed service-level opening commands; its app-level acceptance is recorded in [device tests](build-and-test.md).
2. **Voice and shortcut:** Accept a real spoken English command and confirm transcript, task execution, and temporary-audio cleanup. Verify physical Volume Down single and triple presses, including automatic recording. The shortcut has opened the app before but recording was intermittent.
3. **Independent operation:** Repeat a physical USB-disconnect task and reboot recovery on the current build. Earlier builds provided one successful unplugged task and a limited service-restart sample.
4. **Additional model services:** Configure each provider with its own on-device key and run real Maps searches. OpenAI and compatible API request formatting and response parsing pass local tests; their live service results are not yet accepted.
5. **Distribution:** Test more devices and jailbreak versions, then provide a package source and simpler installation. The current archive is a developer release candidate for compatible RootHide devices.

## Security and privacy boundaries

Keys are stored separately per provider in mobile-owned `0600` files, never in packages or the repository. Compatible endpoints must use HTTPS and cannot contain URL credentials, query parameters, or fragments. Redirects are blocked before a key could be forwarded. Agent status and audit output use fixed categories rather than model-generated text. A key-like pattern in the request or visible UI stops a model step. Free-form request text, including new note content, may be sent to the selected model for intent interpretation. Existing Notes content and contact details are not sent to that interpreter.

Installation and recovery instructions are in [install-and-configure.md](install-and-configure.md) and [device-recovery.md](device-recovery.md). Detailed package and phone evidence is in [build-and-test.md](build-and-test.md). The selected Palmino code is described in [palmino-harness-reuse.md](palmino-harness-reuse.md).
