# Palmino Harness reuse in BeanBao

Assessed October 30, 2026; updated October 31. Source baseline: `/Users/xnu/products/appstore/palmino` at `8a70981` and PalminoHarnessKit `v2.0.0`. Earlier detailed Chinese-language assessment notes remain in Git history through commit `b55e882`.

## Decision

BeanBao reuses the bounded step-execution design and selected Palmino Harness runtime modules. It does not copy Palmino's general-purpose app capabilities into the phone bridge. The Bridge stays a small allowlisted UI control surface, while BeanBao owns request normalization, task policy, model adapters, and device-specific verification.

The selected runtime and tool registry support three task paths:

- `TextHarness.swift` opens one of four allowed apps and checks the actual foreground bundle ID. It does not require a model or screenshot.
- `NoteHarness.swift` creates a new note through limited UI steps and checks that its complete title appears in the Notes list. It does not send the Notes screen to a model; free-form request text may be sent separately for intent interpretation.
- `MapHarness.swift` runs a bounded Maps search with a maximum of 20 tool calls and a five-minute deadline. The device-side step implementation checks foreground state, fresh observation, exact search text, UI policy, and verified result. It can ask Claude, OpenAI, or a compatible image-capable model for one proposed action when local actions are insufficient.

The Agent service runs each task in a child process, has a stop operation, and uses service and task IDs so an old result is not shown as the result of a new task. A wake lease attempts to prevent automatic screen locking during execution and is released on completion, stop, or service failure. The shortcut and voice flows remain in the app.

## Evidence and limits

Native policy, Python, and Swift Harness tests pass. Earlier installed builds completed fixed app opens, test-note creation, and Claude Maps searches on the target iPhone. One earlier build completed a task with USB physically disconnected. The current English build's results are in [build-and-test.md](build-and-test.md). OpenAI and compatible services need live tests after their own keys are configured. Physical shortcut recording, current-build reboot recovery, and other devices remain unverified.

The copied upstream source and licensing notes are recorded in [vendor/UPSTREAM.md](../vendor/UPSTREAM.md). BeanBao-specific restrictions must be preserved when updating those modules.
