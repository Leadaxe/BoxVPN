# L×Box development guide

## Project philosophy

L×Box is developed with **spec-driven vibe coding**: every capability is first
written down as a specification and only then implemented. That buys us:

- Transparency: any developer can see what is implemented and what is planned
- Quality control: acceptance criteria in every spec
- A history of decisions: why something was done this particular way
- The ability to work alongside AI assistants (Claude Code)

---

## How the documentation is laid out

```
docs/
  spec/
    features/
      003 home screen/spec.md       # Every live feature is its own folder
      006 servers ui/spec.md        # spec.md is the main document
      ...                           # plan.md, tasks.md are optional
      047 public intent api/spec.md
    tasks/
      README.md                     # When and how to keep a task log
      NNN-kebab-title.md            # One work cycle (a bug, a pass, a refactor)
      055-mobile-stack-decision/    # Demoted, historical and superseded specs live here too
      060-libbox-1-13-migration/    # (see §054 spec reorg)
  ARCHITECTURE.md                   # Project architecture
  GUARDS.md                         # Sanitiser registry: every guard, by layer
  BUILD.md                          # Build instructions
  DEVELOPMENT_REPORT.md             # Development history by stage
  DEVELOPMENT_GUIDE.md              # This document
  screenshots/                      # Screenshots for the README
README.md                           # The main documentation
CHANGELOG.md                        # Changes by version
```

### The shape of a feature spec

Every spec contains:
1. **Status**: implemented / spec / in progress
2. **Context**: why the feature is needed, what problem it solves
3. **Implementation**: how it was done (architecture, models, UI)
4. **Files**: a table of the files it touches
5. **Acceptance criteria**: a checklist

**Features versus tasks:** `docs/spec/features/` describes a capability (“what
this is and how it works”). [`docs/spec/tasks/`](./spec/tasks/README.md) is a log
of individual work cycles: a bug with a non-trivial root cause, a performance
pass, a refactor with consequences; the format and the criteria are in that
folder's `README`.

The live specs run from `docs/spec/features/003 home screen/` to
`130 masque-warp-transport/` and beyond — the full, never-stale index is
[`docs/spec/features/README.md`](spec/features/README.md). Demoted and superseded
specs moved to `docs/spec/tasks/055..061` through
[§054 spec reorg](spec/tasks/054-spec-reorg-features-vs-tasks.md). The full list
with descriptions is in
[`ARCHITECTURE.md → Feature Specs`](ARCHITECTURE.md#feature-specs). The big
landmarks:
- **026** — Parser v2 (a sealed `NodeSpec`, a three-layer pipeline) — the v1.3.0 refactor.
- **027** — Subscription auto-update (four triggers plus hard gates against spam).
- **033** — Preset bundles (selectable rules with a `preset_id`, expansion and merge).
- **039** — libbox 1.13 migration (1.12.12 → 1.13.11, single-CommandServer architecture).
- **041** — DNS rules refactor (named/toggleable/multi-source, kind: user/template/preset/srs).
- **042** — Health watchdog (heartbeat metrics plus auto-recovery, *draft*).

---

## Architectural principles

### 1. One source of settings: wizard_template.json

**Every** baseline value in the application is defined in
`assets/wizard_template.json`:

| Section | What it holds |
|--------|-----------|
| `dns_options` | DNS servers (16 presets) plus rules |
| `ping_options` | URL, timeout, ping presets |
| `speed_test_options` | Servers, streams, ping URLs |
| `group_templates` + `default_directions` | §125/§267/§393 — the SEED for `directions[]` (directions live in storage, not in the template) |
| `vars` | Every configuration variable |
| `selectable_rules` | Routing rules with SRS |
| `config` | The skeleton of the sing-box config |

**The rule**: when you need a new default, add it to wizard_template.json — do
not hardcode it in Dart.

User overrides are kept in `lxbox_settings.json` (through SettingsStorage).

### 2. Autosave instead of Apply

**The base rule:** on simple settings screens (lists of toggles, fields with no
“draft” state) use a debounce timer of 500 ms. On a change:
1. `_scheduleSave()` cancels the previous timer and starts a new one
2. 500 ms later `_apply()` writes to storage and rebuilds the config
3. If the VPN is running, it shows “Restart VPN to apply changes”

**The exception — complex forms** (many interdependent fields, a high risk of
accidental edits or of a half-filled state): those get an **explicit save** (a
Save / Apply button in the action bar or at the bottom of the screen) and a
**dialog when navigating back** if there are unsaved changes (“discard / stay”).
The example in the code is the custom-rule editor
(`custom_rule_edit_screen.dart` — `PopScope` plus “Discard changes?”).

On such screens we do **not** rely on debounce autosave for each field — the user
confirms a finished set of parameters with a single action.

### 3. Offline-first

The application has to work without the internet:
- Subscriptions are cached to disk (`sub_cache/`)
- The node filter reads from configRaw (the already-generated config)
- The config is generated from cache when the network fails
- DNS servers from the template are always available

**The internet is needed only for**: downloading subscriptions (via the refresh
button), SRS rule sets, and the speed test.

### 4. Config generation pipeline (Parser v2)

```
SettingsStorage (server_lists) + WizardTemplate
        ↓
buildConfig(lists, settings)  ─  spec 026
  1. Load template, substitute @vars
  2. For each ServerList: list.build(ctx: EmitContext)
      ├─ per-node emit(vars) → SingboxEntry (Outbound | Endpoint)
      ├─ allocateTag with tagPrefix
      └─ apply detour policy (register/use/override)
  3. Post-steps (ordered):
      ├─ applyPresetBundles     — expand `CustomRule(kind: preset)` → rule_set/dns/route (spec 033)
      ├─ applyCustomRules       — user inline + local-SRS rules (spec 030)
      ├─ applyTlsFragment       — first-hop only, skip on detour
      ├─ applyMixedCaseSni      — randomise server_name case (spec 028)
      └─ applyCustomDns         — DNS-rules + servers (spec 041: `dns_options.rules` named/toggleable; multi-kind: user/template/preset/srs)
  4. Cache remote SRS (parallel)
  5. validator → ValidationResult{ fatal[], warnings[] }
  6. → BuildResult{ config, configJson, validation, emitWarnings }
```

Subscriptions are **not** fetched over HTTP inside this pipeline — that is
`AutoUpdater`'s job (spec 027). Rebuilding the config is a purely local assembly
from nodes that have already been downloaded.

### 5. Interface language: English is the key

**English is the base language of the interface**, and since §285 the English
text at a call site literally *is* the translation key. Every user-facing string
— screen titles, menus, buttons, labels, hints, dialogs, snackbars, push
notifications, error messages, empty states — is written **in English only**.

**The rule:** new UI text goes in through `getLocalText.s("English text")`, never
as a hardcoded literal in a display position (`hardcoded_check` fails the build
on those) and never in another language. Translations live in
`assets/l10n/<tag>/ui.json` keyed by that same English text.

The full guide — adding a language, plurals, collisions, `// l10n-exempt` — is
[`l10n.md`](l10n.md).

> This rule is about **product text inside the application**. Documentation and
> specs are in English; code comments, commit messages and chat can be in
> Russian.

---

## What to watch out for

### Critical risks

#### 1. sing-box dependency resolution
At startup sing-box verifies that every outbound referenced by a group exists. If
`auto-proxy-out` is empty (or was never created because Include Auto is off)
while `vpn-1` points at it — **crash**. Worse, the error names the outbound that
*referenced* the missing tag, not the one at fault.

The guards that prevent this (empty groups never emitted, `default` dropped when
it points nowhere, dangling detours stripped, cycles untied) live in the graph
sanitiser and the validator. **Do not restate them here** — the full list, with
`file:line` and the exact core error each prevents, is
[`GUARDS.md`](GUARDS.md#layer-4--config-assembly).

**What to do:** when you add a code path that emits an outbound, a group or a
reference to one, check that path against the layer-4 table before shipping.
Test it: disable every subscription → start the VPN → it must not crash.

#### 2. local.properties sdk.dir
Flutter overwrites `sdk.dir` on every run. You need either:
- `ANDROID_HOME` and `ANDROID_SDK_ROOT` in `~/.zprofile`, or
- a `sed` before building: `sed -i '' 's|sdk.dir=.*|sdk.dir=/usr/local/share/android-commandlinetools|'`

#### 3. APK signing
Debug and release APKs carry different signatures. `adb install -r` will not work
across a signature change — that needs `adb uninstall` followed by
`adb install`, and **all settings are lost** in the process.

#### 4. VPN permissions
Android asks for VPN permission on first launch. If the user refuses, the
VpnService gets `onRevoke`. That case has to be handled properly.

#### 5. CommandClient, not the Clash API
The Clash API was removed entirely in §122 (the CommandClient migration): there
is no HTTP port, and `experimental.clash_api` is **not** injected into the config
— its presence is a fatal startup failure (“clash api is not included in this
build”). Control and the streams (groups/status/connections/dns) go through the
libbox CommandClient. The risk: do not merge the three CC clients
(status/screen/profiler) into one, and push to an EventSink only from the main
thread — one native sink per channel, with fan-out through a broadcast.

### Common mistakes

| Mistake | Cause | Fix |
|--------|---------|---------|
| `dependency not found for outbound` | An empty group, or a reference to a non-existent outbound | Validate knownTags, fall back to direct-out |
| `INSTALL_FAILED_UPDATE_INCOMPATIBLE` | Switching between debug and release | `adb uninstall` before installing |
| `Failed to start service` | A stale libbox resource was not cleaned up | Clean up stale resources before starting |
| Endless loading | `_loading = true` in initState with no actual load | Set `_loading = false` or call load |
| Empty node filter | configRaw is empty (first run) | Show “Generate config first” |
| A subscription never updates | `enabled = false` | Check enabled before fetching |

### Testing

#### Mandatory scenarios before a release
1. **Clean install**: uninstall → install → Get Free VPN → Start → it works
2. **Update**: install -r (same signature) → settings survived
3. **Offline**: turn off the internet → open the app → config from cache → the node filter works
4. **Every subscription disabled**: turn them all off → Start → no crash (vpn-1 with the direct-out fallback)
5. **Every node excluded**: clear the node filter → `auto-proxy-out` is not created → vpn-1 still works
5a. **Include Auto off**: untick it → the `auto-proxy-out` section is not generated, `vpn-*` do not carry it in add_outbounds, and vpn-1's default is cleared
6. **Speed test**: VPN on → speed test → it shows the proxy and a result above 0
7. **DNS settings**: change the servers → restart the VPN → DNS resolves
8. **App routing**: create a group → add applications → their traffic goes through the outbound

#### Pre-commit gates

Before every commit:
```bash
cd app && flutter analyze
cd app && flutter test
```

⚠ Run `flutter analyze` **without a path argument**, exactly as CI does.
Narrowing it to `flutter analyze lib/ test/` skips files outside those
directories and lets errors through that CI will then catch.

`flutter analyze` and `flutter test` are **not** the whole gate: the `checks` job
also runs the four l10n checkers with `--strict`, and warnings there are fatal.
Run them too before pushing:

```bash
cd app && dart run tool/l10n/ui_check.dart --strict
cd app && dart run tool/l10n/template_check.dart --strict
cd app && dart run tool/l10n/hardcoded_check.dart --strict
cd app && dart run tool/l10n/kotlin_check.dart --strict
cd app && dart run tool/docs/parity_check.dart --strict
```

**0 issues** in analyze, **all tests green** and **zero failures in the checkers**
are all mandatory.

There are roughly 3000 test cases across 227 files (the count moves as tests are
added; the source of truth is the `flutter test` summary):
- `test/models/` — sealed hierarchies (NodeSpec, NodeWarning, ServerList JSON, CustomRule)
- `test/parser/` — URI/JSON/INI parsers plus round-trips (parseUri → toUri → parseUri)
- `test/builder/` — build_config, validator, mixed-case SNI, preset_expand, applyCustomDns, dns_rules_resolver
- `test/subscription/` — sources (UrlSource/InlineSource/QrSource/File), content-disposition, inline headers
- `test/migration/` — proxy_sources → server_lists, one-shot
- `test/services/` — haptic_service, rule_set_downloader and others
- `test/vpn/` — the BoxVpnClient wrapper
- `test/pipeline_e2e_test.dart` — full InlineSource → parseFromSource → buildConfig

---

## The development process

### 1. Spec first
Before implementing, create `docs/spec/features/NNN name/spec.md` — even for
small features. For non-trivial bug fixes and one-off work (with no new “feature”
in the product sense) write a report in `docs/spec/tasks/NNN-title.md` from the
template in [`docs/spec/tasks/README.md`](./spec/tasks/README.md) when it is
warranted. This:
- Pins the decision down before any code is written
- Gives an AI assistant its context
- Serves as documentation once the work is done

### 2. Incremental commits
One commit is one logical unit:
- `feat:` — a new feature
- `fix:` — a bug fix
- `refactor:` — refactoring with no behaviour change
- `docs:` — documentation
- `ci:` — CI/CD
- `release:` — a version

### 3. Building and deploying
```bash
# Local release build (recommended for dev)
./scripts/build-local-apk.sh
adb install -r app/build/app/outputs/flutter-apk/app-release.apk

# Release build (the way CI does it)
cd app && flutter build apk --release
```

### 4. The release process

The canonical release protocol is [`docs/RELEASE_PROCESS.md`](RELEASE_PROCESS.md)
— the single source of truth. In short: `app/pubspec.yaml` carries a placeholder
on `develop`, but the **real version is committed** to it when a release is cut
(§379) — without that, F-Droid's `checkupdates` cannot read the version and
automatic updates in the catalogue stop working. The tag then goes on that
commit. CI and `build-local-apk.sh` rewrite pubspec before `flutter build`, and
About reads the version from the APK manifest through `PackageInfo`, not from the
pubspec file. The branch model is develop → main → tag, with a mandatory
post-flight merge of main back into develop. Every step, the checklist and the
gotchas are in RELEASE_PROCESS.md and are not duplicated here.

### 5. Versioning
- `pubspec.yaml`: `version: X.Y.Z+<code>`
- Git tag: `vX.Y.Z`
- X — major (breaking changes)
- Y — minor (new features)
- Z — patch (fixes)
- The build code is derived from the version by
  [`scripts/version-code.sh`](../scripts/version-code.sh) (§379) and is never
  bumped by hand

---

## Working with an AI assistant (Claude Code)

### CLAUDE.md
`app/CLAUDE.md` holds the project context for AI sessions (build commands, paths,
gradle quirks, spec layout). It is **in `.gitignore`** — every developer or agent
keeps their own local copy, and there is no reference file in the repository. If
you need a template, ask another developer or generate one with `/init` in Claude
Code.

### Memory
Persistent memory in `~/.claude/projects/` holds:
- Build settings (SDK paths, ADB)
- Preferences (local builds rather than CI)
- The current session's context

### Effective patterns
- Build in the background (`run_in_background`) while you work on something else
- Watch CI and the local build in parallel
- Auto-install the APK over ADB once it is built
- Run the pre-commit gates above before every commit
- Write specs through an Agent so they can be written in parallel

---

## Detour server management

The full specification is
[018 detour server management](./spec/features/018%20detour%20server%20management/spec.md).

### What detour servers are

Detour servers are intermediate (chained) proxies that traffic passes through on
its way to the final server. The UI marks them with a **⚙** prefix. In Parser v2
they are NodeSpecs attached through the `chained` field (a full nested spec) or
through `overrideDetour` at the `ServerList.detourPolicy` level.

### Per-subscription settings (`ServerList.detourPolicy`)

| Setting | Field | Description |
|-----------|------|----------|
| **Register** | `registerDetourServers` | Add the ⚙ nodes to the selector groups (visible in the list) |
| **Register in Auto** | `registerDetourInAuto` | Add the ⚙ nodes to the auto-proxy-out urltest |
| **Use** | `useDetourServers` | Use this subscription's `chained` node chains; when off, the detour is removed |
| **Override** | `overrideDetour` | Force a detour tag for every node of the subscription — overwrites main.map['detour'] |

Defaults: `registerDetourServers=false`, `useDetourServers=true`, the rest
false/empty (v1.3.0).

### How the builder handles detours (Parser v2)

`ServerList.build(ctx)` in
[`services/builder/server_list_build.dart`](../app/lib/services/builder/server_list_build.dart):

1. `skipDetour = !useDetourServers || overrideDetour.isNotEmpty`
2. `server.getEntries(ctx, skipDetour)` — when skipping, `NodeEntries.detours` is empty.
3. Detours go first (allocateTag with a prefix), then main.
4. **Detour policy** on main:
   - `overrideDetour.isNotEmpty` → `main.map['detour'] = overrideDetour`
   - `!useDetourServers` → `main.map.remove('detour')`
   - `detours.isNotEmpty` → `main.map['detour'] = detours.first.tag`
   - otherwise leave it as emitted (it may come from `NodeSpec.chained`).
5. Registration: main goes to the selector and auto; the detours follow
   `registerDetourServers` / `registerDetourInAuto`.

### A persistent detour reference for a single-node UserServer

For a `UserServer` (a single added server) the detour is set through a dropdown in
`NodeSettingsScreen`, which writes to `entry.detourPolicy.overrideDetour` (not
into the node's JSON), then `persistSources` runs and the builder applies it.

Why not into the JSON: `parseSingboxEntry` does not restore the `detour` field on
save → reparse, so it would be lost. Fixed in v1.3.1.

---

## Dependencies and updates

### Critical dependencies

| Dependency | Version | Where | Risk of updating |
|------------|--------|-----|----------------|
| sing-box-lx (fork, libbox) | see `app/android/libbox.version` | the pin in `app/android/libbox.version` plus `libs/libbox.aar` (downloaded from the fork's GH Releases by `scripts/fetch-libbox.sh`); the Maven/JitPack line is gone | The API can change — test the native code. The gotchas of a version bump are in [`KERNEL.md`](KERNEL.md) |
| Flutter | see `app/android/flutter.version` (3.47.1 today) | the SDK; CI reads the pin file | Usually safe; watch for deprecations |
| Gradle | 9.3.1 | wrapper | Compatibility with AGP |
| AGP | 9.1.0 | settings.gradle.kts | Compatibility with Gradle and Flutter |
| Java | 17 | Temurin | Do not change without a reason |

### When updating libbox
The core is the sing-box-lx fork, wired in as `libs/libbox.aar` (not Maven). The
procedure and the build-tag gotchas are in
[`KERNEL.md`](KERNEL.md). In short:
1. Check the API changes in the fork's changelog
2. Bump the pin in `app/android/libbox.version` and pull the AAR through `scripts/fetch-libbox.sh`
3. Check the native code in `vpn/` — the methods may have changed
4. Test it fully: start/stop, the CommandClient streams (groups/status/connections)
