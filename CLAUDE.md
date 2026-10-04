# ARCE.AI — notes for Claude

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
- Tests mirror the Kotlin `core/` tests in `test/core`; when you change `lib/core`, change them too.
- Reply to the user in Japanese, times in JST. New docs files get the suffix `Claude-MM-dd-yyyy_HH-mm-ss`. No pull request unless asked. Commit trailers: see the spec, section 11.
- Branch: the user names the branch to work on and push to (normally `main`, the default). Do not create or delete branches unless asked. `claude/great-lovelace-3lg7st` (the Flutter rewrite) and `claude/new-session-5wz0e3` (the old Kotlin app) are kept for history; both are contained in `main`.
- Do not commit signing keys.
