# Lynk for macOS

Native SwiftUI monitoring app for ACP Gateway. It does not embed the former HTML UI or use `WKWebView`.

The app provides four native surfaces:

- Dashboard: sessions, events, tasks, inbox, and Gateway state at a glance.
- Monitoring: a selectable branch timeline and pet-like live topology map built from the same Gateway subscription.
- Session windows: independent per-session event inspection.
- Settings: app-local display preferences, all 17 supported Gateway runtime options, and the official ACP agent catalog with targeted Install and On/Off controls.
- Optional Agent Status Pet integration: starts the configured `CodexPet` overlay and feeds it the same live Gateway session/Inbox snapshot without starting the pet's separate watcher. The opener is projected as a Frontdoor root and its Workers attach beneath it.

Monitoring remains read-only through Gateway's `observer` access. Explicit Gateway settings and official-agent actions use authenticated, short-lived mutation paths. Agent-update toggles apply live on a current daemon; lifecycle and resource-limit changes are staged until the user chooses safe restart. Agent Off applies to new session use without uninstalling the agent or terminating active work. Restart is blocked while sessions, Tasks, or Inbox requests are active. Closing the app stops only its Node sidecar, not Gateway or Workers.

```bash
npm run test:quick
npm test
npm run macos:test
npm run macos:build
npm run macos:dmg
npm run macos:verify
npm run macos:clean
npm run macos:run
```

Use `test:quick` while iterating; `npm test` remains the complete release gate. `macos:clean` removes only reproducible Swift build/test intermediates under `build/cache/` (plus legacy cache paths) and preserves `AgenLynk.app`, the DMG/checksum/release manifest, and the extracted Node runtime cache.

## Self-contained build

`npm run macos:build` assembles a **runtime seed** at `AgenLynk.app/Contents/Resources/runtime/`: the Swift-compiled app, Gateway fork under `src/`, AgenLynk sidecar under `sidecar/`, `package.json`/`package-lock.json`, the `skills/agent-delegator` skill, production `node_modules`, and — for a distribution build — a full official Node distribution tree (`node`, `npm`, `npx`, and their supporting `lib/`) at `runtime/node/`. Gateway and sidecar keep independent build IDs even though this phase still installs them as one verified seed. This seed is **install input only**: the app never executes Node or any script directly from inside the `.app` bundle (see "Installed runtime" below). A plain `npm run macos:build` with no Node distribution configured skips bundling Node entirely and stays a source-tree/system-Node development build (`SidecarController`/`InstallerController` fall back to `ACP_GATEWAY_NODE`/PATH in that case).

- **Node modules** — reused from the checkout's existing `node_modules` (this package declares no `devDependencies`, so it is already production-only); if absent, the script runs `npm ci --omit=dev` inside the bundled runtime directory instead.
- **Node distribution** — set `ACP_LYNK_NODE_DIST_DIR` to a directory containing executable `bin/node`, `bin/npm`, and `bin/npx` (i.e. an extracted official `node-vX.Y.Z-darwin-arm64` tarball). The script validates it is arm64, `>=22`, and **self-contained** (no external shared-library dependency such as a Homebrew `libnode.*.dylib`) before copying the whole tree in; a package-manager Node normally fails that check because npm/npx are `#!/usr/bin/env node` shims that need a real `lib/node_modules/npm` next to them, not just a single executable. `npm run macos:dmg` sets this automatically via `macos/scripts/prepare-node-runtime.sh`, which downloads and checksum-verifies a pinned version (override with `ACP_LYNK_NODE_VERSION`/`ACP_LYNK_NODE_SHA256`, cached under `ACP_LYNK_NODE_CACHE_DIR`).
- **Packaging smoke check** — after signing, if a Node distribution was bundled, the build runs `node --version`, `npm --version`, and `npx --version` with `PATH` restricted to only the bundled `node/bin` plus `/usr/bin:/bin` (no Homebrew, no other system Node), proving the runtime executes on its own.
- **Signing** — ad-hoc (`codesign --sign -`) by default; every nested Mach-O (including the bundled `node`, which gets `macos/Resources/Node.entitlements` for JIT) is signed explicitly. Set `ACP_LYNK_CODESIGN_IDENTITY` to a Developer ID identity for distribution builds, which also turns on hardened runtime + timestamp; this never needs to be hardcoded and local builds/tests require no credentials.

`npm run macos:dmg` runs `macos:build` (with a prepared Node distribution) and then packages `build/AgenLynk.dmg` (AgenLynk.app + an `Applications` symlink) with `hdiutil`. It verifies the final image read-only, checks the app signature and bundled runtime inventory, runs bundled node/npm/npx with a system-Node-free `PATH`, and emits `build/AgenLynk.dmg.sha256` plus `build/AgenLynk.release.json`. Run `npm run macos:verify` to repeat those checks against the finished artifacts, or `npm run macos:verify -- /path/to/AgenLynk.dmg` for another image. Set `ACP_LYNK_APP_VERSION` and `ACP_LYNK_BUILD_NUMBER` to override the staged Info.plist values for a release build; the checked-in version remains the default.

Notarization is opt-in and parameterized, never automatic for local builds: set `ACP_LYNK_NOTARIZE=1` and `ACP_LYNK_NOTARIZE_PROFILE=<notarytool keychain profile>` (configured beforehand with `xcrun notarytool store-credentials`) to submit and staple. Public distribution still requires Developer ID signing and notarization; local/dev builds stay ad-hoc.

## Installed runtime

A distribution build's app bundle is seed input only. On startup, `RuntimeProvisioner` spawns the bundled seed's own Node against the bundled `src/runtime-installer-cli.js` (the only Node available before anything is installed) to copy that seed into `~/.acp-gateway/runtime/versions/<gatewayVersion>-<gatewayBuildId>/` and atomically activate it via `~/.acp-gateway/runtime/current.json`. `runtime-manifest.json` records the Gateway version/build/API version, Node version, and a SHA-256 inventory of every runtime file and confined symlink after nested code signing. It is used to reject an incomplete or corrupted copy before activation and to skip re-copying on later launches once a version is already installed and verified. `~/.acp-gateway/install.json` (Control identity/state) is never touched by this step, so existing installs — including a prior CLI checkout install — keep their identity.

From then on, `BundledRuntime.locateNode`/`resourceURL` resolve Node and every script (`sidecar/src/server/monitor.js`, `src/bootstrap.js`, and therefore the Control/Guide MCP command paths the installer registers with Codex/Claude/Grok) from that **installed** runtime root — never the app bundle — for as long as the app bundle carries a seed at all. A Settings/`ACP_GATEWAY_NODE` override cannot bypass this in a packaged build; those overrides only take effect when running from a source-tree checkout with no bundled seed. The installed runtime's own `node/bin` is always first on the `PATH` handed to sidecar/installer subprocesses, so codex/claude/grok CLI adapter installs resolve the bundled npm/npx too.

Lynk also refuses to activate a runtime seed while running from a non-stable location (a mounted DMG under `/Volumes/`, a Gatekeeper `AppTranslocation` path, or anywhere outside `/Applications`) — move `AgenLynk.app` to `/Applications` first; the onboarding screen surfaces this directly.

## First run

On launch the app runs `RuntimeProvisioner.ensureInstalled()` (see above) before anything else; failures surface as an actionable "Gateway runtime 설치 실패" screen with a retry button. Once the runtime is ready, the app checks `~/.acp-gateway/install.json` (or `ACP_GATEWAY_INSTALL_STATE`) for a valid existing installation (matching version and Control identity). If it is missing or invalid, Lynk shows a first-run installation screen instead of the dashboard: pick a Frontdoor (Codex/Claude/Grok), then Lynk runs the *installed* runtime's `acp-gateway-bootstrap --install-all --front-door <target> --refresh-registry` with bounded live output. Monitoring only starts after the installer reports a health-verified success; failures show an actionable message and let the user retry. An existing valid installation skips onboarding and goes straight to the dashboard, as before.
