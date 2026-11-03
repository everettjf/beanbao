# Public release checklist

BeanBao is currently a private developer release candidate. This checklist
separates source and installation preparation from a public launch. The current
draft assets remain available only to repository collaborators.

## Prepared

- Apache-2.0 license for BeanBao-authored code and preserved upstream notices.
- English README, complete install guide, static GitHub Pages source, and a
  Pages workflow that skips deployment while the repository is private.
- Four-package RootHide archive with a checked installer and recorded SHA-256.
- Source build, offline tests, package audit, one-device installation, reboot
  recovery, and USB-disconnect task verified. See [the test record](build-and-test.md).

## Before publishing

1. Resolve the two open security review items: scope Bridge screen-content
   observation to approved apps, and replace the Delivery Browser pairing
   token's custom-URL transport. Rebuild, audit, and test the changed packages.
2. Test installation from the published instructions on a second compatible
   RootHide phone. The existing device is the only validated combination.
3. Publish a new archive and verify its release-note SHA-256 from a fresh
   download. Keep the prior candidate's hashes and device test record intact.
4. Review the public README, site, and release notes against that archive.
   Then make the repository public, publish the release, select GitHub Actions
   in Pages settings, and confirm the public install and site links work.

Signed-in checkout, Apple Mail composition, and other jailbreak/iOS combinations
remain explicitly unverified. They are not prerequisites for the bounded first
use shown in the README, but must stay labeled as such in public copy.
