# ACP Monitor for macOS

Native SwiftUI monitoring app for ACP Gateway. It does not embed the former HTML UI or use `WKWebView`.

The app provides four native surfaces:

- Dashboard: sessions, events, tasks, inbox, and Gateway state at a glance.
- Live Graph: Frontdoor trunks and Worker branches on a live time axis.
- Session windows: independent per-session event inspection.
- Settings: app-local display preferences, all 17 supported Gateway runtime options, and Worker-advertised session config controls.
- Optional Agent Status Pet integration: starts the configured `CodexPet` overlay and feeds it the same live Gateway session/Inbox snapshot without starting the pet's separate watcher. The opener is projected as a Frontdoor root and its Workers attach beneath it.

Monitoring remains read-only through Gateway's `observer` access. Explicit Gateway or session config edits open a separate, short-lived `control` connection. Agent-update toggles apply live on a current daemon; lifecycle and resource-limit changes are staged until the user chooses safe restart. Restart is blocked while sessions, Tasks, or Inbox requests are active. Closing the app stops only its Node sidecar, not Gateway or Workers.

```bash
npm run macos:test
npm run macos:build
npm run macos:run
```

The local build is ad-hoc signed. Public distribution still requires Developer ID signing and notarization. Node 22+ and an existing ACP Gateway installation are required for v1.
