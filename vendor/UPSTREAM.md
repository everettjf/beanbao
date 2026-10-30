# ios-mcp source snapshot

Source: https://github.com/witchan/ios-mcp
Upstream commit: 62c4464f688c8f269419924b1a19c996de75f175
Copied: 2026-10-30

The copy at vendor/ios-mcp is a source reference. Selected UI, screen, HID, text-input, and Vision OCR files are compiled into BeanBaoBridge; the upstream package itself has not been built or installed on the connected iPhone. The upstream AGENTS.md was omitted because its Git and release workflow governs the upstream project rather than BeanBao. LICENSE, NOTICE, THIRD_PARTY_NOTICES.md, and bundled third-party license files were retained.

This is a starting snapshot for the BeanBao fork. In its present state it still contains app/package installation and other privileged features. Do not install this unmodified snapshot as BeanBao. The restricted build lives in ../bridge; follow docs/build-and-test.md for its current validation status.
