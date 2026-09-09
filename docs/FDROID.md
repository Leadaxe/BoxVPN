# Publishing on F-Droid

Related: [`RELEASE_PROCESS.md`](RELEASE_PROCESS.md), [`BUILD.md`](BUILD.md).

| What | Where |
|---|---|
| Recipe | `metadata/com.leadaxe.lxbox.yml` in `fdroid/fdroiddata` (merged 2026-09-06) |
| Fork for CI runs | `gitlab.com/leadaxe/fdroiddata`, branch `com.leadaxe.lxbox` |
| MR | [fdroiddata!44731](https://gitlab.com/fdroid/fdroiddata/-/merge_requests/44731) |
| RFP | [rfp#4218](https://gitlab.com/fdroid/rfp/-/work_items/4218) |

F-Droid builds from source at `commit:`, including `libbox.aar` from
`Leadaxe/sing-box-lx` and `libcronet.a` from Chromium. It then compares the
result byte for byte with the release APK from GitHub and publishes our APK
under our signature.

GitLab token: `~/.gitlab-token`, mode `600`, scope `api`. Pass it inline in the
push URL; never store it in the `remote`.

## Per release

Auto-update is on: `checkupdates` reads the version from `app/pubspec.yaml` at
the new tag and opens the MR itself. Edit the recipe by hand only when the
recipe itself must change.

Checklist for a manual edit:

1. `commit:` — the full commit hash of the tag, not the tag name.
   `git rev-parse v2.X.Y^{commit}`.
2. `versionCode` per block: `scripts/version-code.sh 2.X.Y arm64-v8a`.
3. `srclibs`: the core's ref does not matter, `prebuild:` checks out the tag
   from `app/android/libbox.version`. `cronet-go@<sha>` must be the commit the
   core's `go.mod` requires; if it is not, the Chromium `cmp` step fails.
   Reachability check: `git ls-remote https://github.com/SagerNet/cronet-go | grep <sha>`.
4. `CurrentVersion` / `CurrentVersionCode`.
5. Toolchain versions are read from the sources (`android/flutter.version`,
   the core's `go.version`, `android/libbox.version`). No version literals in
   the recipe.
6. `fdroid lint com.leadaxe.lxbox && fdroid rewritemeta com.leadaxe.lxbox && git diff --quiet metadata/com.leadaxe.lxbox.yml`
   (`pip install fdroidserver`). `rewritemeta` is a separate CI job; it fails on
   key order and on a missing trailing newline. Apply the diff it prints.
7. Push; the pipeline starts on its own. The verdict is in the `fdroid build`
   log: `compared built binary to supplied reference binary successfully`.
   `check apk` only scans for non-free classes and extra signing blocks.

Changelog for the new version goes into the **release commit**
(`fastlane/metadata/android/<locale>/changelogs/<versionCode>.txt`, ≤ 500
characters). Fastlane is read from the build commit, not from the branch.

## Fastlane

`fastlane/metadata/android/{en-US,ru}/` in the repository root, not under `app/`.

| What | File |
|---|---|
| Title | `title.txt` |
| Short description (≤ 80 characters) | `short_description.txt` |
| Full description | `full_description.txt` |
| Icon | `images/icon.png` |
| Screenshots | `images/phoneScreenshots/N.png`, ordered by N |
| Changelog | `changelogs/<versionCode>.txt` |

The changelog file name must equal the recipe's `versionCode`. Screenshots must
not show the Servers screen (personal subscriptions); use servers from
`public-servers-manifest.json`.

## Recipe

| What | Why |
|---|---|
| `libbox.aar` built from source | prebuilt binaries are not allowed |
| `libcronet.a` built from Chromium, `cmp` against the blob in `cronet-go` | same; ~50 min per ABI |
| One build block per ABI, each with `--target-platform` and `LXBOX_ABI_FILTER` | `--target-platform` narrows only the Flutter engine and the Dart snapshot; the AAR's `.so` for all ABIs would land in the APK (31 MB → 71 MB). `LXBOX_ABI_FILTER` in [build.gradle.kts](../app/android/app/build.gradle.kts) clears `ndk.abiFilters` and excludes foreign ABIs in `packaging.jniLibs` |
| JDK 17 check removed from the core build script | their image is Debian trixie, JDK 21 |
| Legacy AAR variant removed | gomobile needs an SDK platform per variant |
| No `--dart-define=LXBOX_DISTRIBUTION` | any define ends up in the compiled Dart code and breaks the byte comparison. The install channel is detected at runtime from `installingPackageName` (§390). The define stays only for the AAB |

Both core patches are one `sed` over `cmd/internal/build_libbox/main.go`.

### Buildserver

1. `make.bash` needs a bootstrap Go: `apt-get install golang-go` and `GOROOT_BOOTSTRAP`.
2. The scanner runs between `prebuild:` and `build:`. Build the core in
   `build:`, otherwise its output needs `scanignore`.
3. `git -C $$srclib$$ checkout -f`: fdroidserver removes the signing configs in
   the Flutter clone and a plain checkout refuses to switch.
4. The core needs the submodules `sing-tun`, `wireguard-go`, `gvisor`. Take the
   list from `go.mod` (`grep -A15 '^replace' go.mod | grep '=> \./'`), not from
   `.gitmodules`.
5. `rewritemeta` key order follows their schema: `Binaries` after `Repo`,
   `AllowedAPKSigningKeys` before `MaintainerNotes`.
6. Job limit: `build_timeout` raised to 5 h in the project API, but the shared
   runner kills a job at **3 h**. Two ABIs take 73 min, three took 2 h 45 min
   and hit the limit. x86_64 was dropped on 2026-09-06; GitHub releases still
   ship it. Runner variance: the same Chromium build took 25 min once and 50 min
   another time.
7. The first CI run on GitLab needs account verification (phone or card),
   otherwise the pipeline fails as "yaml invalid" with zero jobs.
8. `DEPENDENCY METADATA` in the APK Signing Block fails `check apk`
   (`Found extra signing block`). Disabled with `dependenciesInfo { includeInApk = false }`
   in [`app/android/app/build.gradle.kts`](../app/android/app/build.gradle.kts).
   Left on for the AAB.
9. A pinned commit can become unreachable when upstream rewrites history
   (`cronet-go`, 2026-08-06 and 2026-08-31: `unable to read tree`). fdroidserver
   clones a branch and checks out the SHA, so the SHA must be reachable from a
   branch. Fix: bump the core so `go.mod` points at a live commit.
10. A kernel bump needs no recipe change: `prebuild:` runs
    `git -C $$sing-box-lx$$ checkout -f $(cat android/libbox.version)`. Only a
    change of the cronet-go version in the core's `go.mod` needs one (once
    between lx.28 and lx.35).

### Reviewer threads

Remarks are threads. A text reply does not close one; someone must press
**Resolve**, otherwise `blocking_discussions_resolved: false` keeps the
`waiting-for-upstream` label on.

```bash
curl -sS --header "PRIVATE-TOKEN: $(cat ~/.gitlab-token)" \
  "https://gitlab.com/api/v4/projects/36528/merge_requests/44731/discussions?per_page=100" \
  | python3 -c "import sys,json; print(sum(1 for d in json.load(sys.stdin) for n in d['notes'] if n.get('resolvable') and not n.get('resolved')), 'unresolved')"
```

Close one: `PUT .../discussions/<id>?resolved=true`.

## Reproducibility

`Binaries` (release APK URL per block) and `AllowedAPKSigningKeys` are set.
This is irreversible: Android does not update an app under a different key, so
dropping `Binaries` would make the catalogue entry a different application to
the system. Losing `upload-keystore.jks` ends updates.

Every release must match byte for byte or it never reaches the catalogue.

| File | Cause | Fix |
|---|---|---|
| `libapp.so` | absolute build path in the Dart AOT snapshot | `mv` into `/home/runner/work/LxBox/LxBox` at the start of `build:`, the path our CI uses |
| `libflutter_zxing.so` | different linker flags on the two sides | flag set once in `build.gradle.kts`, removed from the recipe |
| `libdartjni.so` | `.note.gnu.build-id` (20 bytes at `0x2e0`) | `-Wl,--build-id=none` |
| APK Signing Block | `DEPENDENCY METADATA`, 7185 bytes | `dependenciesInfo.includeInApk = false` |

The NDK adds `-Wl,--build-id=sha1` unconditionally (`build/cmake/flags.cmake:72`).
lld hashes the output before strip, including debug info with absolute paths, so
identical shipped libraries get different ids. The flag lives in
[`app/android/build.gradle.kts`](../app/android/build.gradle.kts) (the root
file) as `-DCMAKE_SHARED_LINKER_FLAGS`, so both builds share it. `-D` replaces
the whole cache variable; verified by building: the section is gone, the section
set is otherwise unchanged. `--filesystem-root` does not work with `flutter build apk`.

### Compare

```bash
scripts/verify-fdroid-apk.sh <apk-from-fdroid> <apk-from-github>
scripts/verify-fdroid-apk.sh --blocks <apk>     # signing blocks only
```

Both are needed. `META-INF/` is compared separately: besides the signature it
holds ~76 androidx version files. A file-by-file diff does not see the APK
Signing Block, which sits outside the zip structure. Our APK is ~12 KB larger
because of the v2/v3 block; there is no `.RSA` file, use
`apksigner verify --print-certs`.

## versionCode

§379, one formula for both channels, ABI last:

```
versionCode = ((major × 10000 + minor × 100 + patch) × 100 + PRE) × 10 + ABI
```

`PRE`: `01-49` = `-rc.N`, `50` = release, `51-98` = `-hotfixN`.
`ABI`: `0` universal, `1` armeabi-v7a, `2` arm64-v8a, `4` x86_64.

The formula exists only in [`scripts/version-code.sh`](../scripts/version-code.sh).
Details: [§379](spec/tasks/379-version-code-from-version.md). The ABI goes last
because the catalogue sorts by versionCode; Flutter's `--split-per-abi`
(`ABI × 1000 + code`) is not used, GitHub builds one run per target.

```yaml
AutoUpdateMode: Version
UpdateCheckMode: Tags
VercodeOperation:
  - '%c + 1'
  - '%c + 2'
UpdateCheckData: app/pubspec.yaml|version:\s.+\+(\d+)|.|version:\s(.+)\+
```

`UpdateCheckData` reads the ABI=0 code from pubspec (`2.23.0+22300500`);
`VercodeOperation` adds each block's ABI digit, one operation per block.
It is `%c + ABI`, not `%c * 10 + ABI`: the `× 10` is already in the formula.
`AutoUpdateMode` is `Version` without `v%v`; under `Tags` the tag is put into
`commit:` as is. Pending: anchor the regexes as `(?m)^version:` so a commented
`version:` line in pubspec cannot match first.

## Network requests and consent

The first-run prompt "Check for updates?" sets `auto_check_updates`
(default **false**).

| Request | When | Gated |
|---|---|---|
| GitHub Releases API, fallback `docs/latest.json` | launch, ≤ once per 24 h | yes (§379) |
| `app/assets/support.json`, message feed (bundled copy in the APK) | home screen with the tunnel up, once per process | yes (§422); without consent: last cached copy, else the bundled one |
| `app/assets/donate.json` (bundled copy) | About → Support, on tap | no, user action |
| `public-servers-manifest.json` | that screen, on open | no, user action |

With "Skip" the app makes no request to `raw.githubusercontent.com` on its own.

## Permissions

| Permission | Reason |
|---|---|
| `QUERY_ALL_PACKAGES` | Per-app routing: the "Tunnel apps" list uses `PackageManager.getInstalledApplications()` in `VpnPlugin.kt`. Since Android 11 the call returns only system packages and `<queries>` entries without it. Install-time, no prompt. |
| `ACCESS_BACKGROUND_LOCATION`, fine, coarse | Current Wi-Fi SSID/BSSID for `wifi_ssid` / `wifi_bssid` rules; `WifiManager.getConnectionInfo()` requires it on API 29+. Declared only, never prompted; users of those rules grant it in Settings. Everything else works without it. |
| `RECORD_AUDIO` | Not ours. It came from the manifest of `camera_android_camerax` (via `camera`, a dependency of the `flutter_zxing` QR scanner). Removed at manifest merge with `tools:node="remove"` after v2.23.0. |
