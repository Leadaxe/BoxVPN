# L×Box — documentation index

A table of contents for the whole project documentation. This is the entry point
for navigation: start here rather than grepping through files.

## Automation and control

Beyond the UI itself, L×Box can be driven in **two** ways. Which one you want
depends on who is in control and from where:

| Channel | What for | Document |
|---|---|---|
| **Public Intent API** (§047) | Background automation on the device — Tasker / MacroDroid / a Locale plugin. Broadcast commands and events (Wi-Fi triggers, auto on/off, switch-node, reacting to a failed subscription). No root, no USB. | [AUTOMATION.md](AUTOMATION.md) · [RU](AUTOMATION.ru.md) |
| **Debug API** (HTTP) | Programmatic or scripted control and diagnostics — full CRUD over subscriptions and rules, start/stop, config, logs, profiler. Bearer token, port 9269, usually over adb-forward or Wi-Fi. For CI, debugging, and automation from a computer. | [api/debug-api-reference.md](api/debug-api-reference.md) · the live `GET /help` |

> **The Clash API is gone (§122).** The UI and diagnostics go through the libbox
> CommandClient (push streams out of the core); the core is built without
> `with_clash_api`, and `experimental.clash_api` in a config kills the start. See
> the historical note in [api/clash-api-reference.md](api/clash-api-reference.md).

The difference in one line: **Public Intent** is “the phone automates itself” from
events; **Debug API** is “I drive the phone from outside with a script or by
hand”. Both describe the same operations from opposite sides.

## Core documentation

| Document | Description |
|---|---|
| [ARCHITECTURE.md](ARCHITECTURE.md) | Tech stack, supported Android versions, source tree, the Parser v2 pipeline, data flows, the native side (Kotlin) |
| [STORAGE.md](STORAGE.md) | The full `lxbox_settings.json` schema, per-key semantics, migration history |
| [TEMPLATE.md](TEMPLATE.md) | The `wizard_template.json` schema (presets/vars/sections) plus the var substitution syntax |
| [PROTOCOLS.md](PROTOCOLS.md) | VPN protocol details (vless/vmess/trojan/…): URI formats, parameters, sing-box mapping |
| [KERNEL.md](KERNEL.md) | The sing-box-lx fork: build tags, the gotchas of a version bump, rc history |
| [SECURITY.md](SECURITY.md) · [RU](SECURITY.ru.md) | Threat model — protection against traffic leaks, the local attack surface, on-device secrets |
| [PRIVACY_POLICY.md](PRIVACY_POLICY.md) · [RU](PRIVACY_POLICY.ru.md) | What the app stores, which requests it makes on its own, and which permissions it needs |

## Development and operations

| Document | Description |
|---|---|
| [DEVELOPMENT_GUIDE.md](DEVELOPMENT_GUIDE.md) | Philosophy, principles, critical gotchas, how specs are organised |
| [BUILD.md](BUILD.md) | flutter build commands, CI, signing, the local-build marker |
| [RELEASE_PROCESS.md](RELEASE_PROCESS.md) | Versions, tags, GitHub Releases, post-flight |
| [FDROID.md](FDROID.md) | Publishing in the F-Droid catalogue: metadata, reproducible builds, the versionCode scheme |
| [GOOGLE_PLAY.md](GOOGLE_PLAY.md) | Publishing on Google Play: closed testing, IARC rating, per-release steps — and the testers who made the closed test possible |
| [DIAGNOSTICS.md](DIAGNOSTICS.md) | The on-device diagnostics playbook: Debug API plus CommandClient/profiler endpoints, TCP/DNS analysis, `scripts/lxbox-diag.sh` |
| [l10n.md](l10n.md) | Localization (§279/§285): natural keys, the dictionary format, adding a language, the checkers |
| [USER_GUIDE.md](USER_GUIDE.md) · [RU](USER_GUIDE.ru.md) | User guide — how it all works: the stages traffic goes through, directions, chains of hops, detour, DNS, recipes, regex |
| [DONATE.md](DONATE.md) · [RU](DONATE.ru.md) | Supporting the project (§362): crypto, Boosty, and how to help without money. The in-app popup is sourced from `app/assets/donate.json` |

> **RU/EN pairing (§360).** Six documents are kept as pairs: README, USER_GUIDE,
> DONATE, PRIVACY_POLICY, SECURITY and AUTOMATION. The translation is named
> `X.ru.md`. On every push and PR, CI compares the pair's skeleton — the number
> and levels of sections, and the code blocks: a section added in one language
> only fails the “Docs parity” step. Locally: `dart run
> tool/docs/parity_check.dart --strict` from `app/`. Details in
> [app/tool/docs/README.md](../app/tool/docs/README.md).
>
> Everything else is English-only. Development documentation changes together
> with the code in almost every task, and a second language there would mean
> doing the work twice — with the lagging side failing silently.

## API references

| Document | Description |
|---|---|
| [api/debug-api-reference.md](api/debug-api-reference.md) | Debug API — the full endpoint list (mirrors the live `GET /help`) |
| [api/clash-api-reference.md](api/clash-api-reference.md) | Clash API — **removed in §122**, kept as a historical note on the sing-box clash-api |

## Specifications

| Kind | Where |
|---|---|
| **Features** (large concepts, sections of the app) | [spec/features/](spec/features/) — folders named `NNN name/spec.md` |
| **Tasks** (small changes, bug fixes, cleanups) | [spec/tasks/](spec/tasks/) — `NNN-name.md` |
| **Processes** (night work and the like) | [spec/processes/](spec/processes/) |
| **Conventions** for writing specs | [spec/README.md](spec/README.md) |

## Everything else

| Directory | Contents |
|---|---|
| [releases/](releases/) | Per-version release notes (EN + RU) |
| [features/](features/) | Deep-dive notes on individual features (per-app-trace, wifi-aware-routing) |
| [research/](research/) | Research (code audit, audience, 4pda feedback) |
| [examples/](examples/) | Example configs (`minimal_local_test.json`) |
| [DEVELOPMENT_REPORT.md](DEVELOPMENT_REPORT.md) | A historical chronicle of development (up to v1.9.0) — no longer maintained |
