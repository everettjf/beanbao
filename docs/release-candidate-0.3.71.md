# BeanBao RootHide 0.3.71 release candidate

This is a developer release candidate for a Relaxin / RootHide iPhone. It has been installed and tested on one iPhone 11 running iOS 26.0.1 with Relaxin 0.5.5. Other devices and jailbreak versions need their own validation.

## Included versions

- Bridge 0.2.13
- Agent 0.3.117
- Delivery Browser 0.1.20
- App 0.3.71

The offline archive contains these four `iphoneos-arm64e` packages, `SHA256SUMS`, `install.sh`, and `INSTALL.md`. It contains no model key, SSH credential, or device data.

## Verified on the paired phone

- English text tasks open Settings, Maps, Contacts, and Notes; create a new note; and search Maps with Claude. A physical Volume Down triple press opens one bottom voice panel, starts Apple speech transcription, and can run a reviewed request.
- A text task completed after USB was physically unplugged. After a reboot and re-enabling Relaxin, Agent started without a manual service restart; Notes and a Claude Maps search passed.
- A saved six-step research workflow retained its sourced PDF, email draft, App Store review, and step journal through reboot. The PDF opened in BeanBao.
- The sandboxed Uber Eats browser completed a bounded item search, required option selection, one add-to-cart, and read-only cart review on this phone. A separate interrupted add test stopped for reconciliation instead of repeating the click.
- The release archive passed package audits and the phone's `install.sh --dry-run` preflight. The preflight kept all four matching installed versions and changed no service.

## Limits

- Apple Mail native composition was deferred by the owner. No email was sent.
- Uber Eats sign-in blocks real checkout review on the test phone. No order was placed. Final checkout and order-history handling have only synthetic test coverage.
- App Store acquisition opens the official listing for user review. BeanBao cannot silently install an App Store app.
- This is a bounded assistant. Arbitrary-app UI tapping is not released: iOS 26 accessibility coordinates for scroll content can disagree with the screen by more than 100 points. The current Maps adapter uses OCR corroboration for known shifted rows.

## Archives and SHA-256

```text
6a157cba69c431f605b84daaef5829fd5a649f0adf1e5ff80d609bd5ecf1d0c0  BeanBao-RootHide-b0.2.13-a0.3.117-browser0.1.20-app0.3.71.tar
e7e0d492cbcb664abb90e2a632d8112cb00a7c4a4d384f746d562f15823a9df8  BeanBao-RootHide-b0.2.13-a0.3.117-browser0.1.20-app0.3.71.tar.gz
```

Use the uncompressed `.tar` for direct phone extraction. Verify its SHA-256, run `sh install.sh --dry-run`, then `sh install.sh` from a root shell in the extracted directory. A new Bridge installation requires one SpringBoard reload and manual unlock. Follow the [complete installation and configuration guide](install-and-configure.md) for SSH transfer, model setup, and recovery.
