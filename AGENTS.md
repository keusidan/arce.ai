# ARCE.AI — notes for coding agents

Flutter app (Android, iOS, Windows, macOS, Linux). Local AI chat and coding assistant; on-device inference is Android only.

**Read first:** `docs/ARCE_AI_flutter-spec_Claude-10-04-2026_09-58-53.md` (architecture, decisions, what is and is not verified, environment limits). Release procedure: `docs/ARCE_AI_flutter-release_Claude-10-04-2026_08-46-00.md`.

## Commands

```bash
flutter pub get
flutter analyze && flutter test      # CI runs both; keep them clean
flutter build linux --release        # needs the Linux packages listed in README.md
```

## Rules that are easy to break

- Android: keep the package `ai.arce.app.engine` (JNI names depend on it) and `applicationId` `ai.arce.app`. Keep the Android release tag plain `vX.Y.Z` and marked "latest" — the earlier native app reads it.
- Android `versionCode` comes from the version (`major*1000000 + minor*1000 + patch`), never from a run number.
- Release versions are `X.Y.Z` only (Windows).
- Every device (Android, iOS, Windows, macOS, Linux) is built and released in parallel, each by its own workflow (`.github/workflows/release-<os>.yml`). Keep them independent: no `needs:` or `workflow_run` between platforms, and no shared concurrency group. One platform failing, being re-run or being edited must never stop or delay another. A change to one device's workflow or native code must not be a prerequisite for another's.
- **Everything except secrets is a setting.** API keys, the GitHub token and MCP tokens are the only things that are not: they live in the secure storage and never in the settings JSON, a backup or the chat. Every other value (limits, timeouts, counts, sampling, prompts, model choices, provider headers and body) must be changeable in the settings screen, and from the chat through `AgentSettings` (`lib/core/settings_spec.dart`) unless it is in `blocked` for a stated reason. Do not add a new fixed number or timeout without a setting for it. The device model and the online models have separate settings (`local*` / `online*`).
- Big binary blobs (a saved KV cache, model files) are files, never SQLite rows: the file lives under the app's data folder and only its index is a row of `assets`. History and its full-text search stay in SQLite (`docs/ARCE_AI_kv-cache_*.md` says why).
- Model-specific defaults (`lib/ai/model_hints.dart`) come only from what the maker publishes (the model card), only for the versions it describes, and are used only where the user set nothing. Cite the card in the code and in `docs/`. Never build on third-party write-ups or unofficial re-implementations of a vendor's tooling.
- Tests mirror the Kotlin `core/` tests in `test/core`; when you change `lib/core`, change them too.
- Reply to the user in Japanese, times in JST. New docs files get the suffix `Claude-MM-dd-yyyy_HH-mm-ss` (this file keeps its fixed name). No pull request unless asked. Commit trailers: see the spec, section 11.
- Branch: the user names the branch to work on and push to (normally `main`, the default). Do not create or delete branches unless asked. `claude/great-lovelace-3lg7st` (the Flutter rewrite) and `claude/new-session-5wz0e3` (the old Kotlin app) are kept for history; both are contained in `main`.
- Do not commit signing keys.
