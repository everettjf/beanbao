# PalminoHarnessKit AgentRuntime and AgentTools snapshot

- Source: `https://github.com/everettjf/palmino`
- Source commit: `8a70981`
- Source paths: `Packages/PalminoHarnessKit/Sources/AgentRuntime/` and
  `Packages/PalminoHarnessKit/Sources/AgentTools/`
- Package release at snapshot: `v2.0.0`
- License: Apache-2.0; see `LICENSE` and `NOTICE` in this directory.
- Scope: the six `AgentRuntime` Swift source files and six `AgentTools` Swift
  source files. Palmino App, iSH, MCP, UI, and other package products are not included.

`AgentRuntime` source files are copied without changes. In `AgentTools`, the six
`import AgentRuntime` lines are conditional on `SWIFT_PACKAGE`, because Theos
compiles both directories as one Swift module. `AgentTools/PublicAPI.swift` is
named `AgentToolsPublicAPI.swift` here to avoid a duplicate Swift filename in
the same Theos compile. Other source content is unchanged. BeanBao integration
code belongs outside this directory.
