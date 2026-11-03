# BeanBao

BeanBao is a personal GUI assistant for a jailbroken iPhone. The first target device is an iPhone 11 running iOS 26.0.1 with Relaxin 0.5.5 and RootHide.

The current release candidate uses a restricted Bridge, an on-device Agent, and a native app. It supports typed and spoken English requests to open Settings, Maps, Contacts, or Notes; create a new note; and search Maps for a place. Existing Chinese commands remain accepted. Exact supported phrases take a fast local path; other natural requests are interpreted by the selected model into one of the same bounded tasks. App launches and note creation execute locally. Maps search can also use Claude, OpenAI, or an OpenAI-compatible HTTPS API when an action cannot be determined locally. Each model service has its own on-device key. There is no mock-model option in the app.

BeanBao checks the foreground app, screen freshness, sensitive content, and action policy at every step. It does not silently install apps, send messages, or delete content. The delivery browser has an experimental order action that requires the user to review the exact checkout and tap **Place order**; its final click has only been tested against synthetic pages because Uber Eats currently requires sign-in on the connected phone. The connected device has passed text-command and Claude Maps search tests; OpenAI and compatible endpoints still need live tests with their own keys. Other devices and jailbreak environments need separate validation.

The app has an Activity view for recent task outcomes. It derives short summaries from a private on-device audit and does not store request text, note contents, screenshots, or model replies. The separate Sessions view saves research, App Store, and delivery workflow requests, checkpoints, and artifacts in private on-device storage. Its detail view shows a read-only history of step names and states without website text or tool results. One research session can prepare a cited PDF, an addressed email draft, and a selected App Store listing for review. It reports installation only after a matching bundle is found on the device, and keeps the mail and installation reviews independent. The sandboxed delivery browser can search Uber Eats, configure an item, review a cart, and prepare a checked checkout for explicit user approval. An order attempt is never replayed automatically. Other task types remain independent and do not have conversational memory.

The offline release includes a phone-extractable `.tar` and an installer that verifies the four packages, skips matching versions, checks the running Agent version, and leaves SpringBoard reload to the owner. A Mac helper transfers the archive over paired root SSH after checking its published hash and contents. The installer has passed a same-version run and a Delivery Browser-only upgrade on the connected RootHide phone; other devices still need separate validation. There is no public package source yet.

- [Installation and configuration](docs/install-and-configure.md)
- [Current release candidate and checksums](docs/release-candidate-0.3.71.md)
- [Device test record](docs/build-and-test.md)
- [Human acceptance checklist](docs/human-acceptance.md)
- [UI and Activity design](docs/ui-and-activity.md)
- [Common requests](docs/common-cases.md)
- [Device recovery](docs/device-recovery.md)
- [Architecture and implementation plan](docs/relaxin-ios26-plan.md)
- [Palmino Harness reuse](docs/palmino-harness-reuse.md)
- [Upstream ios-mcp snapshot](vendor/UPSTREAM.md)
- [BeanBao icon assets](design/README.md)
