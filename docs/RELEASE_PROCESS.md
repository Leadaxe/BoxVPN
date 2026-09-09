# Release protocol (L×Box)

This document describes how to ship a **stable release** `vX.Y.Z`. It is the
canonical source for the procedure: if another document contradicts it, fix it
here and bring the rest into line.

Related documents:
- **`.github/workflows/ci.yml`** — the CI mechanics: triggers, jobs, versioning, publishing the release and `docs/latest.json`.
- **`AGENTS.md`** — the agent's general scope and the rules for working with git and branches.
- **`RELEASE_NOTES.md`** — the release body (in the repo root) that CI uploads as `body_path` for the GitHub Release.
- **`docs/releases/vX.Y.Z.md`** — the archive of per-version release notes.
- **[`FDROID.md`](FDROID.md)** — publishing on F-Droid: the catalogue picks up new tags on its own; fastlane (changelogs, screenshots, descriptions) is read from the tag's commit, not from the branch, so it must be in place **before** the tag.

---

## 0. What CI changes, and what you change

CI (`.github/workflows/ci.yml`) triggers on:

| Event | What runs |
|---|---|
| push of a `v*` tag | `meta` + `checks` + `android` + `release` + `publish-manifest` (a full release) |
| push to `develop` / `main` | `checks` (analyze and tests only) |
| PR into `develop` / `main` | `checks` |
| `workflow_dispatch` + `run_mode=checks` | `checks` |
| `workflow_dispatch` + `run_mode=build` | `checks` + `android` (APK in artifacts, no release) |
| `workflow_dispatch` + `run_mode=release` | a full release (CI does not create the tag — used for emergency re-issues) |

CI takes the release body from `RELEASE_NOTES.md` (sparse checkout, the
`Create GitHub Release` step, `body_path: RELEASE_NOTES.md`). Before tagging,
make sure the file holds **exactly** the notes meant for this release.

After the release the bot step `publish-manifest` pushes a
`chore(release): update docs/latest.json ... [skip ci]` commit to `main`. That is
the only automatic commit allowed in `main` besides the release merge commits.

---

## 1. The branch model

- **`main`** — the release branch. We write here only **when preparing a release**: a merge from `develop`, final edits to `RELEASE_NOTES.md` / `app/pubspec.yaml` / tag-adjacent details, the `vX.Y.Z` tag, and the automatic `docs/latest.json` bot commit. No feature development in `main`.
- **`develop`** — the main development branch. Every feature and fix PR lands here.
- **Feature branches** — branch off `develop` and merge back into `develop`.
- **`vX.Y.Z` tags** — only on commits in `main` (typically on the merge commit from `develop`).

After every release, `main` is merged back into `develop` (§2.6); otherwise the
`docs/latest.json` bot commit and the release merge commit are not ancestors of
`develop`, and `git describe` on `develop` starts lying.

---

## 2. A stable release — `vX.Y.Z`

### 2.1. Pre-flight

0. **The core is the sing-box-lx fork, not stock.** A release with AWG/XHTTP (§097) is only valid on the fork's core (the mechanics are in [§104](spec/tasks/104-libbox-fork-ci-fetch.md)):
   - in `app/android/app/build.gradle.kts` the dependency is `implementation(files("libs/libbox.aar"))`, with **no** active Maven line `com.github.singbox-android:libbox`;
   - `ci.yml` (job `android`) has the step `Fetch sing-box-lx core (libbox.aar)`, and the pin `app/android/libbox.version` is the version the local smoke test ran on (step 4) — the pin is shared by local builds and CI, so they have nothing to diverge over;
   - the stock 1.13.11 core rejects configs carrying AWG fields (`jc`/`jmin`/…) and `type:"xhttp"` — a release built on it is defective.
1. Everything is green on `develop`:
   ```bash
   cd app
   flutter analyze && flutter test
   dart run tool/l10n/template_check.dart --strict
   dart run tool/l10n/ui_check.dart --strict
   dart run tool/l10n/hardcoded_check.dart --strict
   dart run tool/l10n/kotlin_check.dart --strict
   dart run tool/docs/parity_check.dart --strict
   ```
   ⚠ It has to be `flutter analyze` **with no argument** — CI analyses the **whole** project, including `test/`. The local habit of `flutter analyze lib/` skips errors in the tests (especially `non_exhaustive_switch` after adding a subtype to a sealed class); they surface in CI **after** the tag is pushed and take the release down with them (this bit us on v2.8.2 / §217).

   ⚠ The l10n checkers are **not optional**: the `checks` job runs them as the “L10n checks” step, and any failure kills the release exactly like a failing test. On v2.17.0 the tag had to be re-issued because of `hardcoded_check`: two `hintText` examples in §302 (`tls.utls.fingerprint`, `chrome`). Technical identifiers in the UI (JSON paths, protocol field values) are not translatable — the cure is not “add a key to the dictionary” but a `// l10n-exempt: <reason>` annotation at the end of the line (see [l10n.md](l10n.md)).

   ⚠ `parity_check` guards the six RU/EN pairs (README, USER_GUIDE, DONATE, PRIVACY_POLICY, SECURITY, AUTOMATION). A section added to one language only fails the “Docs parity” step.
2. `develop` is a direct descendant of the last stable tag:
   ```bash
   git fetch --tags
   git describe --tags
   # Expect vX.Y.Z-N-gSHA; if it is far behind, consider whether the notes cover everything
   ```
3. Every document is in sync for the release:
   - `CHANGELOG.md` — a `## vX.Y.Z` entry has been added.
   - `docs/ARCHITECTURE.md`, `docs/DEVELOPMENT_REPORT.md` — if affected.
   - `README.md`, `README.ru.md` — if user-visible features changed.
   - Task specs (`docs/spec/features/NNN*/spec.md`) — `status: released`.
   - `docs/releases/vX.Y.Z.md` — a draft of the per-version archive (it can be prepared as development goes).
   - `fastlane/metadata/android/{en-US,ru}/changelogs/<versionCode>.txt` — see §2.3 step 4.
4. **A local smoke test of the release APK** (recommended before tagging):
   ```bash
   scripts/build-local-apk.sh   # release, arm64 only
   scripts/install-apk.sh       # auto-detects the device, installs and launches
   ```
   This catches a debug signature, a broken build and an incompatible `versionCode` **before** the tag reaches origin.

   ⚠️ **If you build from a worktree** (`.claude/worktrees/*`): `app/android/key.properties` and `upload-keystore.jks` are **absent** there. Symlink them from the main checkout before the first release build — otherwise the APK gets a debug signature and will not install over prod.

   ⚠️ **The core for the smoke test:** `app/android/app/libs/libbox.aar` is in `.gitignore` and is missing in a fresh clone or worktree; `build-local-apk.sh` downloads the version from the pin `app/android/libbox.version` on its own (`scripts/fetch-libbox.sh`, idempotently) — see [BUILD.md](BUILD.md). CI uses the same pin, so the smoke test and the release are guaranteed to run the same core version; a smoke test on a version other than the pin (a manual override of the fetch script) does not count.

### 2.2. The version — the git tag is the only source of truth

**Choosing the number: by default bump ONLY the patch (the last digit).**
`2.9.1 → 2.9.2 → 2.9.3`, rather than jumping to a minor `2.10.0` even when the
release contains new features. Minor and major are only for an explicit
maintainer decision. Do not reason your way into “there are features here, so it
must be a minor” — the default is always the next patch.

**The versionCode is computed from the version**
([§379](spec/tasks/379-version-code-from-version.md)), not from a commit count:

```
versionCode = ((major × 10000 + minor × 100 + patch) × 100 + PRE) × 10 + ABI
```

`PRE`: `01-49` = `-rc.N`, `50` = release, `51-98` = `-hotfixN`. `ABI`: `0`
universal, `1` armv7, `2` arm64, `4` x86_64. It is computed by
[`scripts/version-code.sh`](../scripts/version-code.sh), the single home of the
formula; CI and the local script must both call it, or the codes drift apart and
`install -r` breaks.

`v2.19.8` → arm64 `21908502`, while `v2.19.8-rc.1` → `21908012`. The number
increases strictly across releases.

- **`app/pubspec.yaml`** holds a placeholder on `develop` — at release time the **real version is committed** there (§2.4), because otherwise F-Droid's `checkupdates` cannot read it and catalogue auto-updates stop working. The tag goes on that commit.
- **CI release** rewrites pubspec from the tag before `flutter build`:
  - `versionName` = `${tag#v}` (a clean `X.Y.Z` with no `-dev` suffix in the production APK).
  - `versionCode` — by the formula above, with its own ABI digit for each of the four build runs.
- **A local build** ([`scripts/build-local-apk.sh`](../scripts/build-local-apk.sh)) rewrites pubspec before `flutter build`:
  - `versionName` = `${tag#v}` on a tag, otherwise `${tag#v}-dev.${commits_since_tag}` (for example `1.8.2-dev.3`).
  - `versionCode` = the code of the **last release tag** for arm64 (pinned to the tag, §186 — to avoid the downgrade block when installing a release over a dev build; the formula strips the `-dev.N` tail).
- **About screen / UpdateChecker** read the version through `VersionInfo.I.version` (loaded from `PackageInfo.fromPlatform()` in `main()` before `runApp`) — that is, from the APK manifest rather than from the pubspec file.
- **UpdateChecker skips `-dev` versions** — dev builds never get the “X.Y.Z available” snackbar (it would always look like “update to latest”).

### Setup for a fresh clone

Nothing is required — versioning is computed entirely at build time
(`build-local-apk.sh` or CI). No git hooks are used.

### History

- Up to v1.8.2 the version was duplicated in `pubspec.yaml` and in the `about_screen.dart _version` const. v1.8.0 ▼: they diverged and the UI showed v1.7.0. v1.8.1 was a hotfix plus a CI consistency check as a guard.
- v1.8.2 ([§065](spec/tasks/065-version-from-tag.md)): the hardcoded const was removed, pubspec became a placeholder, and CI and the local script inject the version. But a manual `scripts/build-local-apk.sh` was needed for a realistic version during dev sessions.
- v1.8.3 ([§066](spec/tasks/066-pubspec-sync-hook.md)): a pre-commit hook did the sync automatically on every commit.
- v2.11.x: the pre-commit hook was **removed** (`.githooks/`, `setup-hooks.sh`, `sync-pubspec-version.sh`). All it did was bump the committed pubspec, but both builds (local and CI) rewrite the version before `flutter build` anyway, and the runtime reads it from the APK manifest — so the hook's value never survived to the APK. Instead pubspec was frozen at `0.0.0+1` and the version computed only at build time. The payoff: an end to pubspec “jitter” and merge conflicts over `version:`.
- v2.19.x ([§379](spec/tasks/379-version-code-from-version.md)): the versionCode moved from `rev-list --count` to a formula over the version, and `--split-per-abi` was dropped. The real version is committed again — but exactly once, on the merge commit into `main` rather than on every commit in `develop` (that was the cause of the jitter). The reason: F-Droid's `checkupdates` reads the version from the sources at the tag's commit, and without it catalogue auto-updates are impossible.

### 2.3. RELEASE_NOTES.md → the archive

1. Tidy `RELEASE_NOTES.md` (in the repo root) into its final shape — this is the body CI uploads into the GitHub Release. The structure: an intro (both languages) → the English section → the Russian section → Install → a link to the previous release.

   **The notes are always bilingual — English and Russian, both versions complete.** Not “a main language plus a short summary in the second”: the content is duplicated in full, section for section. Each language section is wrapped in a spoiler so the release page does not grow twice as long:

   ```markdown
   <details open>
   <summary><h2>🇬🇧 English</h2></summary>
   …the full text…
   </details>

   <details open>
   <summary><h2>🇷🇺 Русский</h2></summary>
   …the full text…
   </details>
   ```

   `v2.17.0` is the reference for the format. Inside the sections, follow the previous releases: breaking → highlights → tools/process → tests. The Install section and the link to the previous release are shared, outside the spoilers, and duplicated in both languages.
2. Copy the finished file to `docs/releases/vX.Y.Z.md` (the per-version archive, useful for cross-links from future releases and from specs).
3. Check that nothing is left over from the previous version: the `# L×Box vX.Y.Z` heading, the number in the `adb install` command, the link at the bottom `Previous release / Предыдущий релиз: [v...](docs/releases/v...md).` And make sure both language sections describe the same set of changes (during edits it is easy to update one and forget the other).
4. F-Droid changelogs — `fastlane/metadata/android/en-US/changelogs/<versionCode>.txt` and the same under `ru/`, one file per build block (armeabi-v7a and arm64-v8a), ≤ 500 characters each, plain text, one paragraph:
   ```bash
   for abi in armeabi-v7a arm64-v8a; do
     c=$(scripts/version-code.sh X.Y.Z $abi)
     echo "$c"   # e.g. 22301501 / 22301502
   done
   ```
   F-Droid reads fastlane from the **tag's commit**. A changelog added to `develop` after the tag never reaches the catalogue: v2.23.0 and v2.23.1 show an empty "What's New" for exactly this reason. Count characters with `python3 -c 'print(len(open(f).read()))'`, not `wc -m` (bytes on macOS).
5. One commit into `develop`:
   ```
   docs(release): vX.Y.Z notes
   ```
   Push it to `origin/develop`. **No pubspec or about_screen changes in `develop`** — the version is written into pubspec once, on the merge commit into `main` (§2.4), so that it does not “jitter” in the development branch.

### 2.4. Merging into main, and the tag

CI runs the release job **only** on a tag push, and the tag needs a **separate**
command: GitHub treats `git push origin main --tags` as a branch push event and
the release job never starts.

```bash
git checkout main
git pull --ff-only

# ⚠ Two-step merge: `--no-commit` followed by an explicit `commit -m`.
# `git merge --no-ff -m "..."` fails with "empty commit message" despite the -m
# (a git CLI quirk; it caught us twice, on v1.8.1 and v1.8.2).
# If a script carries on past the failure, the push reports "up-to-date" (main
# never moved), the tag lands on the old commit, and CI builds stale code.
# Always two-step.
git merge --no-ff --no-commit develop

# §379 — the real version goes into pubspec BEFORE the commit: the tag lands on
# this commit, and F-Droid's checkupdates reads the version from exactly that
# commit. Without this step the catalogue keeps the placeholder and auto-updates
# do not work. The number after `+` is the base code (ABI=0); the ABI digit is
# added by VercodeOperation.
CODE="$(scripts/version-code.sh X.Y.Z universal)"
sed -i.bak -E "s/^version: .*/version: X.Y.Z+${CODE}/" app/pubspec.yaml
rm -f app/pubspec.yaml.bak
git add app/pubspec.yaml

git commit -m "Merge branch 'develop' into main (vX.Y.Z)"
git push origin main

# Sanity: the tag must reach the hotfix commit
git merge-base --is-ancestor <hotfix-sha> main && echo OK || echo "❌ retag needed"

# The tag goes separately
git tag -a vX.Y.Z -m "Release vX.Y.Z"
git push origin vX.Y.Z
```

> ⚠️ The tag now sits on a merge commit in `main` that is **not an ancestor** of
> `develop`. §2.6 is mandatory, otherwise the next release starts from a history
> that has fallen behind.

### 2.5. Wait for CI

```bash
RUN_ID="$(gh run list --workflow=ci.yml --limit 1 --json databaseId -q '.[0].databaseId')"
gh run watch "$RUN_ID" --exit-status
```

At the finish line, expect:
- The release is published (`draft=false`).
- Four APKs are attached: `LxBox-vX.Y.Z-arm64-v8a.apk` / `-armeabi-v7a` / `-x86_64` / `-universal` (signed **release**, not debug; otherwise installing over prod fails).
- The release body is the content of `RELEASE_NOTES.md` as of the tag.
- `docs/latest.json` has been updated by the bot commit in `main` (`[skip ci]`).

### 2.6. Post-flight: bring main back into develop

After a release there are two commits in `main` that are not ancestors of
`develop`:
1. The merge commit from §2.4.
2. The bot commit `chore(release): update docs/latest.json → vX.Y.Z [skip ci]`.

Merge them back:

```bash
git checkout develop
git fetch origin
# ⚠ The same two-step quirk as in §2.4: `merge --no-ff -m` fails with
# «empty commit message» (it caught us on v2.11.1) — always --no-commit + commit -m.
git merge --no-ff --no-commit origin/main

# ⚠ §379 — the merge drags the real version out of main into pubspec. `develop`
# must keep the placeholder, otherwise the version starts to "jitter" in the
# development branch again (exactly what v2.11.x moved away from). Revert it
# BEFORE committing:
git checkout HEAD -- app/pubspec.yaml
git status --short   # expect only docs/latest.json

git commit -m "chore: merge main (vX.Y.Z tag) back into develop"
git push origin develop

# Forgetting this revert is not fatal: the `checks` job on a push to develop
# fails at the "Pubspec version is a placeholder (develop only)" step and names
# the cure. It never broke a build (both builds rewrite the version before
# `flutter build`), which is precisely why the mistake used to pass silently —
# no test catches it.

# Verify:
git describe --tags
# Should show vX.Y.Z or vX.Y.Z-N-g<SHA>
```

⚠ **This step is skipped often.** It has already been repaired after the fact
twice — `bc9d934d` after v2.20.6, and again after v2.20.8. The merge itself is
clean and nothing in the build breaks, so the only signal is the CI guard on the
*next* push to `develop`. If the guard does fire, the cure is the same: put the
placeholder back (`X.Y.Z-dev.N+<code>`, where N is the number of commits since
the tag) in a separate `fix(ci)` commit.

### 2.7. Verify

```bash
gh release view vX.Y.Z --json isLatest,isDraft,isPrerelease
# → {"isLatest":true, "isDraft":false, "isPrerelease":false}

curl -sL https://raw.githubusercontent.com/Leadaxe/LxBox/main/docs/latest.json | jq '.tag'
# → "vX.Y.Z"
```

- The APK downloads from the release page and `scripts/install-apk.sh` installs it over prod without `INSTALL_FAILED_UPDATE_INCOMPATIBLE` (which proves the signature is release).
- The links from the app to documents in `main` return 200 (the APK hardcodes them to `blob/main`, and a file only gets there through a merge — §361):

  ```bash
  grep -oE 'https://github\.com/Leadaxe/LxBox/blob/main/[^'"'"']+' app/lib/services/project_links.dart | sort -u | while read -r u; do
    printf '%s → ' "${u##*/}"
    curl -s -o /dev/null -w '%{http_code}\n' "$u"
  done
  # → all 200; a 404 means the document is not merged into main and the button in
  # About/Automation leads nowhere.
  # The list comes from ProjectLinks (§358), so a new doc link joins the check by itself.
  ```
- In the APK installed from the release, the core version (About/Debug, `Libbox.version()`) carries the `-lx` suffix and matches the pin in `app/android/libbox.version` at the tag (check against the file, not from memory) — **not** the stock `1.13.11`: that is the guarantee that CI built the fork core and that AWG/XHTTP/MASQUE configs work.
- On a device running the previous L×Box version, UpdateChecker shows a snackbar about the new release (§390: the snackbar appears **only at startup**, not while the app is running — if you are testing on a live app, restart it).

### Google Play (AAB)

For every release CI builds an `.aab` (the “Build AAB (Google Play)” step) and
puts it in the run's artifacts. Uploading to the Play Console is **manual**:
download the `android-aab-release` artifact and upload it to the right track.

⚠ **Three channels mean three incompatible signatures.**

| Channel | Signed with | Updated by |
|---|---|---|
| GitHub Releases | our key (`7987aec4/CN=BoxVPN`) | manually, from the release page's APK |
| Google Play | Google's key (Play App Signing; ours is only the upload key) | Play itself |
| F-Droid | F-Droid's key | the F-Droid client |

An APK from one channel **will not install** over another — “signatures do not
match”. Hence §390: the app knows its own channel and points its update notice at
the same store it came from.

⚠ The flag `--dart-define=LXBOX_DISTRIBUTION=play` is set **only on the AAB
step**. APKs are deliberately built without it: F-Droid compares the bytes of its
build against the APK from GitHub Releases (reproducible builds — the signature
stays ours), and the define would end up in the compiled Dart and break the
comparison. For APKs the channel is determined at runtime from the installer.
When editing `ci.yml`, do not add the flag to the APK steps.

---

## 3. Troubleshooting

### CI fails on the release job — “No APK found”

The `android` job produced no artifact — read its logs. A common cause is
`flutter build apk --release` failing because the keystore secrets are missing.
See `scripts/bootstrap-android-signing-for-ci.sh` and
`scripts/setup-android-ci-secrets.sh`.

### The APK in the release has a debug signature

That means `ANDROID_KEYSTORE_BASE64` / `..._PASSWORD` / `..._ALIAS` are not set in
the GitHub secrets. The log of the `Android release keystore (optional)` step will
say:
```
No ANDROID_KEYSTORE_BASE64 secret; release APK will use debug signing.
```
This must **not** be ignored — users with a prod install will not be able to
update. Fill in the secrets and re-issue (see “The tag already exists” below).

### The release APK was built on the stock core (AWG/XHTTP are rejected)

The symptom: Start fails with a core error on configs carrying AWG fields
(`jc`/`jmin`/…) or `type:"xhttp"`; the core version in About/Debug reads
`1.13.11` with no `-lx`.

The cause: CI built the stock Maven libbox — either the Maven line came back into
`build.gradle.kts`, or the `Fetch sing-box-lx core` step in `ci.yml` was removed
or did not run (or the pin `app/android/libbox.version` points somewhere wrong).

This is a defective release. Fix `ci.yml`, gradle or the pin and re-issue the tag
(see “The tag already exists”). ⚠ Do **not** substitute a locally built APK
through `gh release upload` — releases are CI-built only.

### I pushed `main` and the tag in one command, and no build started

GitHub treats `git push origin main --tags` as a branch push and the release
never starts. Push the tag separately:
```bash
git push origin vX.Y.Z
```

### The release body is wrong or empty

CI reads `RELEASE_NOTES.md` as of the tag. If the tag sits on an old commit, the
body comes from the previous release. The quick fix:
```bash
gh release edit vX.Y.Z --notes-file RELEASE_NOTES.md
```

### `git describe` on develop has fallen behind

§2.6 was not done. Do it now:
```bash
git checkout develop && git merge --no-ff origin/main && git push origin develop
```

### The tag already exists and has to be re-issued

First work out whether CI got as far as creating the Release — that decides how
safe a re-tag is:

```bash
gh release view vX.Y.Z --json isDraft,createdAt 2>/dev/null || echo "release not found"
```

#### Case (a): CI failed BEFORE `Create GitHub Release` (`release not found`)

The most common path — `checks`/`analyze`/`android` failed before the `release`
job created anything (for example `flutter analyze` on `test/`, see pre-flight
step 1, or a flaky test — that is how the first v2.8.2 and v2.9.0 tags died). The
GitHub Release and `docs/latest.json` are **untouched**, so a re-tag is safe:

```bash
# gh release view above should have said "release not found"
git push --delete origin vX.Y.Z
git tag -d vX.Y.Z
# fix the cause, redo §2.4 with the same vX.Y.Z
```

#### Case (b): the Release is already published

A last resort. `docs/latest.json` has already been updated by the bot commit and
may need to be rolled back by hand.

```bash
gh release delete vX.Y.Z --yes
git push --delete origin vX.Y.Z
git tag -d vX.Y.Z
# fix the cause, redo §2.4
```

If users have already downloaded the bad APK, you will have to bump `+build` and
ship `vX.Y.(Z+1)`, because a release build will not install over an installed
debug build without a clean reinstall.

---

## 4. Checklist for the agent

### Stable vX.Y.Z

- [ ] `develop` is green (`cd app && flutter analyze && flutter test` **plus the four `dart run tool/l10n/*_check.dart --strict` and `parity_check`** — CI runs them as the “L10n checks” and “Docs parity” steps, see §2.1 step 1) and a descendant of the previous stable tag.
- [ ] **The core:** `app/android/app/build.gradle.kts` → `implementation(files("libs/libbox.aar"))` (no active Maven line for the stock libbox); `ci.yml` job `android` has the `Fetch sing-box-lx core` step; the pin `app/android/libbox.version` is the version of the local smoke test. The stock 1.13.11 rejects AWG/XHTTP configs — do not ship such a release.
- [ ] The release docs are in sync: `CHANGELOG.md`, `ARCHITECTURE.md` / `DEVELOPMENT_REPORT.md` (if affected), `README.md` + `README.ru.md` (if features are user-visible), specs → `status: released`.
- [ ] `app/pubspec.yaml` in `develop` is **untouched** — the real version goes in on the merge commit into `main` (§2.4/§379), and the tag lands on that commit.
- [ ] `RELEASE_NOTES.md` is polished into its final form and copied to `docs/releases/vX.Y.Z.md`. **Both language versions (EN + RU) are complete and in sync**, each inside its own `<details>` spoiler (§2.3, `v2.17.0` is the reference).
- [ ] Local smoke: `scripts/build-local-apk.sh` plus `scripts/install-apk.sh` — it installs over prod without `INSTALL_FAILED_UPDATE_INCOMPATIBLE` (when working from a worktree, do not forget the keystore symlinks).
- [ ] The commit `docs(release): vX.Y.Z notes` is pushed to `develop` (doc changes only; no pubspec or code bumps).
- [ ] `main` ← merge `--no-ff --no-commit develop` → `commit -m "Merge ..."` → push; the tag `vX.Y.Z` is pushed **as a separate command**. **NB:** it must be `--no-commit` plus an explicit `commit -m`, not `--no-ff -m` — the latter breaks on “empty commit message” and the tag ends up on the old commit.
- [ ] `gh run watch` is green; the release holds four APKs `LxBox-vX.Y.Z-{arm64-v8a,armeabi-v7a,x86_64,universal}.apk`, signed release; the core version in the APK carries the `-lx` suffix and matches the pin in `app/android/libbox.version` at the tag (check against the file, not from memory).
- [ ] `publish-manifest` ran — `docs/latest.json` is updated in `main`.
- [ ] `main` is merged back into `develop` (§2.6) and pushed — **including the `git checkout HEAD -- app/pubspec.yaml` revert before the commit**.
- [ ] `git describe` on `develop` shows `vX.Y.Z`.
- [ ] `gh release view vX.Y.Z --json isLatest` → `{"isLatest":true}`.
