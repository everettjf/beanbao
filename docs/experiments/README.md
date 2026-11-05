# Retained experiment source

`single-app-webview-text.patch.gz` preserves the source and configuration changes
from the earlier attempt to put the Uber Eats `WKWebView` inside the privileged
BeanBao app. That build displayed a blank viewport on the tested iOS 26
RootHide phone and was reverted. See
[`../two-app-architecture.md`](../two-app-architecture.md) for the observed
comparison and the released two-app design.

This is an archival text-only extraction of the experiment patch. Generated
PNG diffs were omitted because the original icon artwork is already tracked
under `design/`. It is based on an earlier tree and is **not** a patch to apply
to current `main` or a supported build variant. Use `gzip -dc` to read it.
