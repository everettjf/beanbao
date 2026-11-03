# Public release checklist

BeanBao 0.3.72 is a public developer preview. This record distinguishes the
verified first-use path from remaining engineering and device-validation work.

## Prepared

- Apache-2.0 license for BeanBao-authored code and preserved upstream notices.
- English README, complete install guide, static GitHub Pages source, and a
  Pages workflow that skips deployment while the repository is private.
- Four-package RootHide archive with a checked installer and recorded SHA-256.
- Source build, offline tests, package audit, one-device installation, reboot
  recovery, and USB-disconnect task verified. See [the test record](build-and-test.md).

## Remaining work after the preview

1. The Bridge screen-content scope issue was fixed in 0.2.14 and tested on the
   paired phone. Replace the Delivery Browser pairing token's custom-URL
   transport before treating delivery as a stable feature.
2. Test installation from the published instructions on a second compatible
   RootHide phone. The existing device is the only validated combination.
3. Verify the published archive's release-note SHA-256 from a fresh download
   and keep the prior candidate's hashes and device test record intact.
4. Confirm the public README, website, and release notes remain aligned with
   the archive after every update.

Signed-in checkout, Apple Mail composition, and other jailbreak/iOS combinations
remain explicitly unverified. They are not prerequisites for the bounded first
use shown in the README, but must stay labeled as such in public copy.
