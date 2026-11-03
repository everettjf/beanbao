# BeanBao's two-app design

The phone shows two BeanBao icons:

| App | Responsibility | Privilege |
| --- | --- | --- |
| **BeanBao** | Requests, voice input, Sessions, model settings, task progress, and review of PDFs, email drafts, App Store listings, and order outcomes. | Existing privileged RootHide app; it can reach the on-device Agent and the SpringBoard voice handoff. |
| **BeanBao Companion** | A normal iOS app surface for interactive workflows. Its first supported workflow is a visible Uber Eats website session with bounded item selection and cart review. | Sandboxed app. It receives only a short-lived pairing token and a restricted Agent operation set. |

The Agent and SpringBoard Bridge remain installed as background components. They are
not extra Home Screen apps. Both visible apps are installed from the same RootHide
release archive; a second Apple ID or App Store account is not required.

## User flow

1. Start a request in BeanBao. For the supported website workflow, tap **Open Companion · Food delivery**.
2. BeanBao obtains a fresh pairing token from the Agent and opens BeanBao Companion.
3. BeanBao Companion retains its own website cookies, shows the page, and asks the Agent to plan one bounded step from a fresh page observation.
4. Before a web action, the Agent checks the workflow, site and proposed action. BeanBao Companion checks the page again, acts on one unique visible control, and reports the result.
5. Task state and review gates stay with the Agent and appear in BeanBao Sessions. An uncertain add-to-cart or order outcome stops for manual reconciliation.

The current implementation is **not a general browser automation API**. It allows
the supported Uber Eats hosts and delivery operations. Other websites would need
their own bounded adapter, permissions, tests, and review rules. No website gets
access to the Agent's full Unix socket or to BeanBao's model credentials.

The Companion can also host future workflows that require normal iOS app APIs:
document or photo pickers, system share sheets, website sign-in, and UI for a
permission request are plausible examples. Each feature still needs its own
entitlements, usage descriptions, user consent where required, and device tests.
The Companion cannot inherit BeanBao's privileged filesystem or SpringBoard
access through its name; any needed Agent operation must be narrowly defined.

## Why keep two apps

On the tested iOS 26 RootHide phone, the in-app WebView displayed a blank viewport
when hosted by the privileged BeanBao app. A sandboxed build rendered the WebView,
but the main app then lost direct access to its Agent socket and shared files. The
separate sandboxed app keeps the working WebKit path while BeanBao retains its
existing voice, task, session, model, and PDF paths. This is an observed build
comparison, not a diagnosis of the internal WebKit failure.

## Naming and upgrade

The second app's Home Screen and package display name is **BeanBao Companion** in
the current source build. Its existing package ID (`dev.beanbao.deliverybrowser`), bundle
ID, executable, and URL scheme stay in place so an update replaces the existing
app and preserves its website session. Internal source paths still say
`delivery-browser`; they are implementation identifiers, not user-facing names.
The public v0.3.72 archive still displays the old name until a newer package is
built, verified, and released.

An app update does not require a SpringBoard reload. Reopen BeanBao and BeanBao
Companion after updating their packages. A new Bridge installation or update still
requires a SpringBoard reload and manual unlock.

## Next security and product work

- Replace the custom URL pairing-token handoff before treating website workflows
  as stable. A competing app could register the same URL scheme. Keep the Agent's
  website channel restricted and bind a session to the intended app.
- Give BeanBao Companion a distinct icon so the two apps are easy to tell apart on the
  Home Screen. The current source build changes the name only.
- Add another website adapter only after its allowed hosts, observable actions,
  and external-action review gate are specified and tested on a phone.

See [complex workflow evidence](complex-workflows.md) and the
[public release record](release-0.3.72.md) for current validation limits.
