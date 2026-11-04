# Public release checklist

BeanBao 0.3.75 is a public developer preview. This record distinguishes the
verified first-use path from remaining engineering and device-validation work.

## Prepared

- Apache-2.0 license for BeanBao-authored code and preserved upstream notices.
- English and Simplified Chinese READMEs with a warm architecture diagram,
  complete install guide, and bilingual GitHub Pages source.
- Two visible apps with distinct icons: BeanBao and the sandboxed BeanBao
  Helper. The Agent and Bridge are on-device background components.
- Four-package RootHide archive with a checked installer and recorded SHA-256.
- Source build, offline tests, package audit, one-device installation, reboot
  recovery, and USB-disconnect task verified. See [the test record](build-and-test.md).

## Remaining work after the preview

1. Replace BeanBao Helper's pairing-token custom-URL transport before treating
   delivery as a stable feature. The Bridge screen-content scope issue was
   fixed in 0.2.14 and tested on the paired phone.
2. Test installation from the published instructions on a second compatible
   RootHide phone. The existing device is the only validated combination.
3. Confirm the public README, website, and release notes remain aligned with
   the archive after every update.

The public v0.3.75 `.tar.gz` was freshly downloaded after publication and its
SHA-256 matched the release record. The release's `.tar` and `.tar.gz` assets
were also freshly downloaded through GitHub Releases and checked against the
published `SHA256SUMS` file.

Signed-in checkout, Apple Mail composition, and other jailbreak/iOS combinations
remain explicitly unverified. They are not prerequisites for the bounded first
use shown in the README, but must stay labeled as such in public copy.
