# Complex workflows: implementation plan

Updated November 2, 2026. This plan targets the on-device BeanBao Agent, App, and RootHide Bridge on the connected iOS 26 phone. The research-to-PDF, email-draft, and App Store handoff paths have initial implementations in source and offline tests; they are not yet verified on the phone. Food delivery remains planned.

## Current boundary

The existing UI task path interprets a request as one canonical action. It can open four allowed apps, search Maps, or create a note. A separate research path now executes a bounded Palmino model/tool loop and persists its checkpoints. The Bridge still has no general app installation, file, purchase, or messaging route. Activity remains a bounded audit log; Sessions holds research workflow progress and artifacts.

## Proposed execution model

Use a workflow coordinator in the mobile-owned Agent. The model may propose a typed plan and select the next available tool, while the coordinator owns execution, authorization, evidence, and persistence. Keep the SpringBoard Bridge limited to foreground observation and UI interaction. Put network research, artifact creation, and mail composition in dedicated Agent/App components instead of widening the Bridge into a general-purpose process runner.

### Reuse the copied Palmino runtime

The copied `PHKAgentRuntime` runs multi-step model/tool turns with call and time budgets, cancellation, conversation snapshots, and an execution checkpoint hook. `PHKToolRegistry` validates tool arguments against JSON schemas. BeanBao now supplies a Claude-backed `PHKModelClient`, typed research tools, and a private atomic `PHKExecutionCheckpointPersisting` journal. Tool receipts prevent duplicate local writes, and an uncertain write requires reconciliation. The policy still needs to expand one capability at a time for other workflow types.

The older `BeanBaoStepHarness` still uses `FixedStepModel` for bounded device actions. The new research route uses the actual Claude/Palmino tool loop. The service recognizes an explicit research/PDF request, creates a stable session ID, and the App exposes saved sessions, PDF preview, and optional Apple Mail compose. Other compound requests still require purpose-built tools and routing; merely raising the 20-step limit would not make them reliable.

The workflow states are `planned -> running -> waiting_for_user -> running -> completed`, with `failed`, `cancelled`, and `needs_reconciliation` terminal or recovery states. Each step records a stable workflow ID, step ID, typed input, output reference, observed postcondition, attempt count, timestamp, and policy decision. Persist this record atomically in an app-private database. Do not store API keys, raw screenshots, or full page content in the default activity log. A separate, user-deletable session may retain the user's request, plan, source links, and resulting files for a configurable period.

Step execution has a bounded deadline and a postcondition check. Read-only steps may retry. Mutating steps get an idempotency key and must inspect the current state before retrying after a crash or disconnect. If the result is uncertain, stop in `needs_reconciliation`; do not click Pay, Install, or Send twice. Re-observe the screen before every UI action and after any app switch. A lock, SpringBoard restart, network interruption, or user takeover pauses the workflow and releases the wake lease. Resuming requires a fresh observation and revalidation of pending approvals.

The planner sees a capability manifest, not an unrestricted tap or shell tool. The first manifest should include:

| Capability | Execution path | Completion evidence |
| --- | --- | --- |
| `web.search`, `web.fetch` | Claude web search/fetch where supported, or a configured HTTPS search provider | Source URL, title, retrieval time, citation mapping |
| `report.compose` | Structured report sections with claims linked to sources | Schema and citation validation |
| `pdf.render`, `pdf.preview` | UIKit PDF renderer and PDFKit in BeanBao App | File exists, readable pages, visible preview |
| `mail.prepare` | Mail compose UI with recipient, subject, body, PDF attachment | Compose view and exact attachment/recipient shown |
| `app.lookup`, `app.open_store_page`, `app.verify_installed` | App Store product page and device inventory | Exact developer, app ID, and installed bundle verified |
| `delivery.search`, `delivery.configure`, `delivery.review_cart` | Per-app or per-site adapter built on restricted UI actions | Merchant, items, options, address, fees, and final total observed |

Tool inputs and outputs must be schema-validated. Web pages, search results, product descriptions, restaurant listings, and emails are untrusted data; text in them cannot add tools, grant permissions, or change the destination. The coordinator checks app identity, domains, addresses, recipients, amounts, and transition evidence independently of model output. Model-generated summaries are not proof of completion.

## Workflow-specific scope

### Research, PDF, and email

This is the first end-to-end target. Search current sources, fetch and deduplicate them, preserve source URLs and dates, draft a report with cited claims, render a multi-page PDF on the phone, and let the user inspect it. Prepare an email with the requested recipient and PDF attached. Apple Message UI presents a composer for the user to edit and send; its completion callback reports queueing in Mail, not delivery to the recipient. If Mail is not configured, leave the PDF available for export and mark the email step waiting for setup. An optional configured mail-provider API can be added later, with a separate explicit send approval and delivery status semantics.

Acceptance: a text request such as “Research on-device speech recognition on iOS, create a PDF with sources, and prepare an email to a specified address” creates one visible session. The PDF opens on the phone, has readable text and working citations, and matches the attachment in the compose screen. Canceling the composer does not mark the workflow sent. A network failure resumes from saved sources without restarting the whole workflow.

### App acquisition

Resolve the exact App Store app using its name, developer, and product ID; show the candidate before handoff. The native StoreKit product view displays the listing. Installing may require the user's App Store, Face ID, or password interaction. After the user finishes, query the installed bundle and verify that it is the selected app. Treat a paid app, subscription, sign-in, or unavailable regional listing as a user decision. Do not infer installation from the StoreKit view closing. Direct arbitrary IPA installation is a separate feature with different provenance and device risk; it is outside this workflow.

Acceptance: BeanBao identifies an exact free app, opens its official listing, waits without duplicating an install action, and reports success only after bundle verification. It reports a declined or unavailable install accurately.

### Food delivery

Start with one selected delivery app or mobile site. Implement its search, item/options, cart, and checkout review as a versioned adapter with screen checks; there is no universal reliable cross-app checkout path. At the review checkpoint show merchant, each item and option, delivery address, tax, fees, tip, total, and estimated arrival if available. Require an explicit, fresh approval tied to that exact snapshot before any order placement. If any amount, address, item, or merchant changes, invalidate approval. If confirmation is ambiguous, stop and ask the user to inspect order history; never repeat the final action automatically.

Acceptance: a scripted request reaches a correct cart and review screen without placing an order. A changed price or address blocks the approval. Only a later separately accepted live test may exercise final placement.

## Delivery sequence

As of November 2, source implementation and offline verification cover the workflow core, research-to-PDF path, email draft, App Store candidate selection and StoreKit handoff, and Sessions list/select/resume/delete controls. The tests use scripted Claude replies and web-search/App Store responses; they verify citation rejection, PDF readability, checkpoint recovery, duplicate prevention, Mail result state, exact App Store candidate identity, and the rule that closing a listing cannot prove installation. The App Store search endpoint was also probed live and returned current software listings. A persistent delivery review gate has tests for changed merchant, item total, address, screen, approval expiry, and uncertain outcome after restart. It is not connected to a delivery service yet. A phone run against a live Claude account, Mail composer, StoreKit listing, and installed-bundle check is still required before calling this release complete.

1. **Workflow core:** typed plan schema, capability registry, persistent checkpoints, session and step status in App, stop/resume, deadlines, and a fake-tool integration test for interruption and duplicate prevention. Keep the existing single-task path unchanged while this is developed.
2. **Research to PDF:** source-aware web search/fetch, citation checks, structured report, on-device PDF rendering and preview. Test with a fixed research topic and inspect the generated PDF.
3. **Email draft:** recipient validation, attachment verification, native compose screen, cancel/send/queue state handling. Use a test mailbox for a separately approved send test; never use a real recipient from a research prompt without review.
4. **App Store handoff:** exact product resolution, listing display, installed-bundle verification, and clear pending states.
5. **Delivery adapter:** one named service, cart construction, exact total review, approval gate, and order-history reconciliation. Expand to other services only after each adapter is verified.

For the first release, the phone remains sufficient to execute a workflow once it has network access and an API key. A Mac is only a build and debugging tool. The model provides planning and interpretation; device-side code owns permissions and tool execution.

## External API evidence

- [Claude web search](https://platform.claude.com/docs/en/agents-and-tools/tool-use/web-search-tool) can return current results with citations; capability and account availability must be checked at runtime.
- [Core Graphics PDF contexts](https://developer.apple.com/documentation/coregraphics/cgcontext) and [Core Text frames](https://developer.apple.com/documentation/coretext/ctframegetvisiblestringrange) render and paginate the on-device PDF. Quick Look previews it in the app.
- [MFMailComposeViewController](https://developer.apple.com/documentation/messageui/mfmailcomposeviewcontroller) supports a prepared message and attachment for user review, and does not guarantee delivery.
- [SKStoreProductViewController](https://developer.apple.com/documentation/storekit/skstoreproductviewcontroller) displays an App Store product page. This supports an installation handoff, not a promise of silent installation.
