# Palmino Harness reuse in BeanBao

Assessed October 30, 2026; updated November 2. Source baseline: [Palmino](https://github.com/everettjf/palmino) at `8a70981` and PalminoHarnessKit `v2.0.0`. Earlier detailed Chinese-language assessment notes remain in Git history through commit `b55e882`.

## Decision

BeanBao reuses the bounded step-execution design and selected Palmino Harness runtime modules. It does not copy Palmino's general-purpose app capabilities into the phone bridge. The Bridge stays a small allowlisted UI control surface, while BeanBao owns request normalization, task policy, model adapters, and device-specific verification.

The selected runtime and tool registry support these task paths:

- `TextHarness.swift` opens one of four allowed apps and checks the actual foreground bundle ID. It does not require a model or screenshot.
- `NoteHarness.swift` creates a new note through limited UI steps and checks that its complete title appears in the Notes list. It does not send the Notes screen to a model; free-form request text may be sent separately for intent interpretation.
- `MapHarness.swift` runs a bounded Maps search with a maximum of 20 tool calls and a five-minute deadline. The device-side step implementation checks foreground state, fresh observation, exact search text, UI policy, and verified result. It can ask Claude, OpenAI, or a compatible image-capable model for one proposed action when local actions are insufficient.
- The research workflow uses the actual `PHKAgentRuntime` model/tool loop, private checkpoints, source and citation validation, on-device PDF creation, and an optional email draft. Sessions exposes progress and the resulting files.
- Natural comparison and analysis requests can now enter that research workflow through model intent classification when they explicitly request a PDF. The source request and any email recipient are passed through unchanged; unrelated extra operations are rejected.
- An explicit request to research a topic, make a PDF, prepare an addressed email draft, and find one App Store app now runs all three outputs in one Palmino session. The Agent requires completed tool receipts and readable artifacts before it reports the session ready for review. The App exposes the PDF, draft, and listing; an Agent restart restores the same pending session. Mail queueing and exact installed-bundle verification are independent review gates. This route does not send mail or silently install the app.
- `DeliveryPlanner.swift` uses a Claude-backed Palmino `delivery_choose` tool to propose one page-bound Uber Eats action at a time. The Agent persists the action receipt, while a separate sandboxed browser checks the visible page and executes only a small action list. Two uninterrupted live phone runs found a meal, selected a required option, added it, opened the cart, and completed read-only review. The final run also checked the previously executed merchant, item, and option targets against the fresh cart page.

This is a working foundation for multi-step tasks: the Palmino loop can sequence typed tools, save receipts, and resume after interruption. Each additional domain still needs its own validated tool, review gate, and outcome check. The delivery order gate now checks all saved sessions before another delivery plan or final click, so switching sessions cannot bypass an uncertain order attempt. Research/PDF, App Store handoff, and delivery are bounded workflows; arbitrary app downloads or purchases are not general-purpose Palmino capabilities.

The order receipt can be resolved only when the user explicitly reports finding the exact reviewed order in Uber Eats history. The report is labeled as user evidence, persists in the workflow, and does not authorize a second click in that session. BeanBao cannot yet independently verify Uber Eats order status.

The model chooses the next visible step; the stored user request now sets an additional limit for option selection, adding to cart, and checkout navigation. A review-only request cannot gain those actions through page text, a model proposal, or a saved proposal from an older version. Ambiguous requests stop before these transitions. This is an authorization boundary around the Palmino loop, not a fixed sequence of taps.

The Agent service runs each task in a child process, has a stop operation, and uses service and task IDs so an old result is not shown as the result of a new task. A wake lease attempts to prevent automatic screen locking during execution and is released on completion, stop, or service failure. The shortcut and voice flows remain in the app.

## Evidence and limits

Native policy, Python, and Swift Harness tests pass. Earlier installed builds completed fixed app opens, test-note creation, Claude Maps searches, research PDF creation, and App Store listing handoff on the target iPhone. The food-delivery sequence above passed on the connected phone without checkout or ordering. One earlier build completed a task with USB physically disconnected. The current English build's results are in [build-and-test.md](build-and-test.md). OpenAI and compatible services need live tests after their own keys are configured. Current-build reboot recovery and other devices remain unverified.

The copied upstream source and licensing notes are recorded in [vendor/UPSTREAM.md](../vendor/UPSTREAM.md). BeanBao-specific restrictions must be preserved when updating those modules.
