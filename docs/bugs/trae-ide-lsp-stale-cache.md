Bug: Trae IDE LSP stale diagnostics on file delete
Severity: Medium

Symptom
Problems panel lists diagnostics for deleted files; status bar shows 1 error. CLI says "No issues found!" — inconsistent with IDE.

Repro Steps
1. Open Trae IDE with Dart/Flutter workspace.
2. Create lib/web/foo.dart with undefined symbol.
3. Wait LSP analyze, then delete the file.
4. Open Problems panel: status bar still shows error; deleted file listed.

Root Cause
LSP file watcher handles delete incompletely: stale Document/URI cache, lost inotify IN_DELETE, no refresh push to client. Verified: Glob file gone, dart analyze clean, LSP still stale.

Workaround
1. Developer: Reload Window (1s reset).
2. rm -rf .dart_tool/ && flutter pub get + Reload.
3. Edit-and-save any file (partial rescan).

Fix
LSP: emit didClose + clear diagnostics on delete; validate URI on refresh. Client: listen workspace/diagnostic/refresh, drop stale.

Evidence: debug-libcimbar-js-interop-write-fail.md. Ref: textDocument_didClose.
