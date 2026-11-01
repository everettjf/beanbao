# BeanBao

BeanBao is a personal GUI assistant for a jailbroken iPhone. The first target device is an iPhone 11 running iOS 26.0.1 with Relaxin 0.5.5 and RootHide.

The current release candidate uses a restricted Bridge, an on-device Agent, and a native app. It supports typed and spoken English requests to open Settings, Maps, Contacts, or Notes; create a new note; and search Maps for a place. Existing Chinese commands remain accepted. App launches and note creation run locally. Maps search can use Claude, OpenAI, or an OpenAI-compatible HTTPS API when an action cannot be determined locally. Each model service has its own on-device key. There is no mock-model option in the app.

BeanBao checks the foreground app, screen freshness, sensitive content, and action policy at every step. It cannot install apps, send messages, make payments, or delete content. The connected device has passed text-command and Claude Maps search tests; OpenAI and compatible endpoints still need live tests with their own keys. Other devices and jailbreak environments need separate validation.

- [Installation and configuration](docs/install-and-configure.md)
- [Device test record](docs/build-and-test.md)
- [Human acceptance checklist](docs/human-acceptance.md)
- [Common requests](docs/common-cases.md)
- [Device recovery](docs/device-recovery.md)
- [Architecture and implementation plan](docs/relaxin-ios26-plan.md)
- [Palmino Harness reuse](docs/palmino-harness-reuse.md)
- [Upstream ios-mcp snapshot](vendor/UPSTREAM.md)
- [BeanBao icon assets](design/README.md)
