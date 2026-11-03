# Third-party source

BeanBao keeps upstream code in `vendor/` so the source and license trail is
inspectable. The top-level Apache-2.0 license applies to BeanBao-authored code;
each upstream component retains its own license and notices.

| Component | Source revision | License | Use in BeanBao |
| --- | --- | --- | --- |
| [ios-mcp](https://github.com/witchan/ios-mcp) | `62c4464f688c8f269419924b1a19c996de75f175` | MIT; see [`vendor/ios-mcp/LICENSE`](vendor/ios-mcp/LICENSE) and [`NOTICE`](vendor/ios-mcp/NOTICE) | Selected screen, accessibility, HID, text input, and Vision OCR files are linked into Bridge. The rest of the snapshot is a source reference and is not installed as an upstream package. |
| [PalminoHarnessKit](https://github.com/everettjf/palmino) | `8a70981` (`v2.0.0` snapshot) | Apache-2.0; see [`vendor/palmino-harness-runtime/LICENSE`](vendor/palmino-harness-runtime/LICENSE) and [`NOTICE`](vendor/palmino-harness-runtime/NOTICE) | `AgentRuntime` and `AgentTools` source used by the multi-step Harness. |

The ios-mcp snapshot includes additional third-party notices and licenses under
`vendor/ios-mcp/third_party/`; those files remain with the snapshot. The package
build carries the licenses and notices for the source actually compiled into
BeanBao. See [the ios-mcp snapshot record](vendor/UPSTREAM.md) and [the Palmino
snapshot record](vendor/palmino-harness-runtime/UPSTREAM.md) for details.
