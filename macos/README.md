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

`npm run macos:build` creates two isolated resource roots. `Contents/Resources/gateway-seed/` contains the SHA-256-verified Gateway 1.4.0 release artifact under `gateway/`, one official Node distribution under `node/`, and AgenLynk-owned install/activation tooling under `app-runtime/`. `Contents/Resources/sidecar/` contains only the app-owned Monitor sidecar. The build never copies AgenLynk's repository `src/`, Gateway skills, or Gateway package metadata as a source fork.

- **Gateway artifact** — `gateway.lock.json` pins version, API major, tag, source commit, asset URL/name, and SHA-256. `scripts/fetch-gateway-runtime.js` verifies both the archive digest and its release manifest. Set `ACP_LYNK_GATEWAY_ARTIFACT` or pass `--artifact` for an explicit offline/local asset. `npm run gateway:fetch` writes the verified tree to `build/cache/gateway-runtime`.
- **Source-tree Gateway resolution** — unpackaged `swift run` does not look at a sibling `../ACP` checkout. It uses `ACP_LYNK_GATEWAY_DEVELOPMENT_ROOT` if set, then a verified installed `~/.acp-gateway/runtime/current` when present, then `build/cache/gateway-runtime` from `npm run gateway:fetch`.
- **Node distribution** — set `ACP_LYNK_NODE_DIST_DIR` to a directory containing executable `bin/node`, `bin/npm`, and `bin/npx` (i.e. an extracted official `node-vX.Y.Z-darwin-arm64` tarball). The script validates it is arm64, `>=22`, and **self-contained** (no external shared-library dependency such as a Homebrew `libnode.*.dylib`) before copying the whole tree in; a package-manager Node normally fails that check because npm/npx are `#!/usr/bin/env node` shims that need a real `lib/node_modules/npm` next to them, not just a single executable. `npm run macos:dmg` sets this automatically via `macos/scripts/prepare-node-runtime.sh`, which downloads and checksum-verifies a pinned version (override with `ACP_LYNK_NODE_VERSION`/`ACP_LYNK_NODE_SHA256`, cached under `ACP_LYNK_NODE_CACHE_DIR`).
- **Packaging smoke check** — after signing, the build runs `node`, `npm`, and `npx` with a restricted PATH. `npm run package:smoke` additionally launches the official Gateway daemon and app sidecar from their distinct roots.
- **Signing** — ad-hoc (`codesign --sign -`) by default. The bundled official `node` is signed with `macos/Resources/Node.entitlements` (JIT). The official Claude helper inside the Gateway artifact is always sealed with the app's signing identity, without Node/JIT entitlements, and that codesign-only byte transform is recorded for manifest verification. The helper's nested signature is verified and its `--version` smoke is executed. The finished app still runs `codesign --verify --deep --strict`. Set `ACP_LYNK_CODESIGN_IDENTITY` to a Developer ID identity for distribution builds, which also turns on hardened runtime + timestamp; this never needs to be hardcoded and local builds/tests require no credentials.

`npm run macos:dmg` runs `macos:build` (with a prepared Node distribution) and then packages `build/AgenLynk.dmg` (AgenLynk.app + an `Applications` symlink) with `hdiutil`. It verifies the final image read-only, checks the app signature and bundled runtime inventory, runs bundled node/npm/npx with a system-Node-free `PATH`, and emits `build/AgenLynk.dmg.sha256` plus `build/AgenLynk.release.json`. Run `npm run macos:verify` to repeat those checks against the finished artifacts, or `npm run macos:verify -- /path/to/AgenLynk.dmg` for another image. Set `ACP_LYNK_APP_VERSION` and `ACP_LYNK_BUILD_NUMBER` to override the staged Info.plist values for a release build; the checked-in version remains the default.

Notarization is opt-in and parameterized, never automatic for local builds: set `ACP_LYNK_NOTARIZE=1` and `ACP_LYNK_NOTARIZE_PROFILE=<notarytool keychain profile>` (configured beforehand with `xcrun notarytool store-credentials`) to submit and staple. Public distribution still requires Developer ID signing and notarization; local/dev builds stay ad-hoc.

## Installed runtime

A distribution build's `gateway-seed` is install input only. On startup, `RuntimeProvisioner` runs `app-runtime/runtime-installer-cli.js` with the seed's Node and copies the composite tree into `~/.acp-gateway/runtime/versions/<gatewayVersion>-<runtimeBuildId>/`. Activation updates `current.json` and the stable `current` symlink. The composite manifest verifies `gateway.lock.json`, the official artifact manifest, Node, app runtime tooling, and every payload checksum. `~/.acp-gateway/install.json` remains untouched.

`BundledRuntime` resolves Node and Gateway scripts from the verified installed target. `SidecarController` separately resolves `Contents/Resources/sidecar/src/server/monitor.js` and passes the installed `gateway/gateway-client/index.js` as its only Gateway code entrypoint. First-run bootstrap uses `runtime/current` paths so registered MCP commands continue to follow later runtime activation.

Lynk also refuses to activate a runtime seed while running from a non-stable location (a mounted DMG under `/Volumes/`, a Gatekeeper `AppTranslocation` path, or anywhere outside `/Applications`) — move `AgenLynk.app` to `/Applications` first; the onboarding screen surfaces this directly.

## First run

On launch the app runs `RuntimeProvisioner.ensureInstalled()` (see above) before anything else; failures surface as an actionable "Gateway runtime 설치 실패" screen with a retry button. Once the runtime is ready, the app checks `~/.acp-gateway/install.json` (or `ACP_GATEWAY_INSTALL_STATE`) for a valid existing installation (matching version and Control identity). If it is missing or invalid, Lynk shows a first-run installation screen instead of the dashboard: pick a Frontdoor (Codex/Claude/Grok), then Lynk runs the *installed* runtime's `acp-gateway-bootstrap --install-all --front-door <target> --refresh-registry` with bounded live output. Monitoring only starts after the installer reports a health-verified success; failures show an actionable message and let the user retry. An existing valid installation skips onboarding and goes straight to the dashboard, as before.
