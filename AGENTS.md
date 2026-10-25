# ARCE.AI — notes for coding agents

Flutter app (Android, iOS, Windows, macOS, Linux). Local AI chat and coding assistant; on-device inference is Android only.

**Read first:** `docs/ARCE_AI_docs_Claude-10-26-2026_02-16-25.md` — the one documentation file (architecture, decisions, release procedure, what is and is not verified, environment limits, designs). Update it in place instead of adding new docs files; its name stays fixed.

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
- **Every release is checked on all five platforms.** A push that raises the version starts the five release workflows; after it, read the result of each (Android, iOS, Windows, macOS, Linux), not only Android's. A red platform is fixed in the next patch version before more work, because it silently stops that platform's users from updating (Windows stayed red from 0.8.8 to 0.8.15 because its tests use Windows paths and nobody looked). Tests must not assume `/` as the path separator or a path that was typed to equal one that was listed.
- Do not add a workflow that downloads and applies a patch (or any code) from outside the repository, or one that pushes commits: `apply-version.yml` did (it fetched a patch from an anonymous file host and pushed it), failed on every push, and was removed.
- **`main` is kept current.** Once a version is green on all five platforms (see above), fast-forward `main` to it (`git push origin HEAD:main`, never forced). Do it after the releases finish, not at the same time as the first push: a push to `main` that raises the version starts the release workflows again, and two runs of the same version would build it twice.
- **Everything except secrets is a setting.** API keys, the GitHub token and MCP tokens are the only things that are not: they live in the secure storage and never in the settings JSON, a backup or the chat. Every other value (limits, timeouts, counts, sampling, prompts, model choices, provider headers and body) must be changeable in the settings screen, and from the chat through `AgentSettings` (`lib/core/settings_spec.dart`) unless it is in `blocked` for a stated reason. Providers are the one list the chat may only *add to* (`add_provider`, with a confirmation card and no key field); changing an existing provider's address or headers from a chat message would let an injected instruction send its key elsewhere. Do not add a new fixed number or timeout without a setting for it. The device model and the online models have separate settings (`local*` / `online*`).
- Big binary blobs (a saved KV cache, model files) are files, never SQLite rows: the file lives under the app's data folder and only its index is a row of `assets`. History and its full-text search stay in SQLite (the docs file, section 6, says why).
- Model-specific defaults (`lib/ai/model_hints.dart`) come only from what the maker publishes (the model card), only for the versions it describes, and are used only where the user set nothing. Cite the card in the code and in `docs/`. Never build on third-party write-ups or unofficial re-implementations of a vendor's tooling.
- Tests mirror the Kotlin `core/` tests in `test/core`; when you change `lib/core`, change them too.
- Reply to the user in Japanese, times in JST. Docs live in the one file named above (edit it, do not add more); any other new file gets the suffix `Claude-MM-dd-yyyy_HH-mm-ss`. No pull request unless asked. Commit trailers: see section 2 of the docs file.
- Branch: the user names the branch to work on and push to (normally `main`, the default). Do not create or delete branches unless asked. `claude/great-lovelace-3lg7st` (the Flutter rewrite) and `claude/new-session-5wz0e3` (the old Kotlin app) are kept for history; both are contained in `main`.
- Do not commit signing keys.
