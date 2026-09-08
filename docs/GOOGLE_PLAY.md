# Publishing on Google Play

Related: [`RELEASE_PROCESS.md`](RELEASE_PROCESS.md), [`FDROID.md`](FDROID.md), [`BUILD.md`](BUILD.md).

| What | Where |
|---|---|
| Package | `com.leadaxe.lxbox` |
| Developer account | `leadaxe` (personal; migration to an organization account is pending a D-U-N-S number) |
| Console mail | `lxboxvpnclient@gmail.com`, `leadaxe@gmail.com` |
| Artifact | AAB — `flutter build appbundle`, see [`BUILD.md`](BUILD.md) |
| Store listing | `fastlane/metadata/android/{en-US,ru}/`, shared with F-Droid |

Unlike F-Droid, Google Play does not build from source: an AAB signed with our
upload key is uploaded, and Play re-signs it with the app signing key. The
install channel is detected at runtime from `installingPackageName` (§390), so
the same source tree produces the GitHub, F-Droid and Play builds without a
build-time define.

## Milestones

| Date | What |
|---|---|
| 2026-08-08 … 08-12 | Closed testing group signed up — 30 testers, see [Testers](#testers) |
| 2026-08-28 | Production access granted; closed testing requirements met |
| 2026-09-04 | IARC age rating live. Global Rating ID `1287b51d-d8a5-84b4-8420-3f8ac03cebb6` |

The IARC rating ID is reusable: any other store under an IARC licence
(Microsoft Store, Nintendo, …) takes the same ID instead of a new
questionnaire. Fill the questionnaire again only when an update changes what
the answers were based on — user-generated content, chat, or payments.

## Closed testing

Google requires a closed test with a group of testers before production access
is granted. Testers opt in through a link, install the build from Play, and
keep it on a personal device for the whole test period.

| What | Value |
|---|---|
| Opt-in link | `play.google.com/apps/testing/com.leadaxe.lxbox` |
| Group size | 30 testers |
| Recruiting | A form on 4PDA and in the project channels |
| Outcome | Production access granted 2026-08-28 |

Participants who asked for one received a personal certificate of
participation; the template and its generator live in
[`design/certificate/`](design/certificate/).

## Testers

Closed testing is the one step that cannot be done alone — Google wants real
people on real devices, and thirty of them showed up. Thank you.

Listed below are the testers who agreed to be named. Everyone else took part
just as much; they simply preferred not to be listed.

| | | |
|---|---|---|
| Tayaere | 9ghtX | Wildgraf |
| AlexxD | Aiurat | Игорь Борисов |
| bogggi | Дмитрий Орлов | akella111 |
| Сергей | Юляша | Алёна |
| ginger | Яша! | MaxInNotion |

## Per release

1. Bump the version, tag, and let CI produce the AAB (see
   [`RELEASE_PROCESS.md`](RELEASE_PROCESS.md)).
2. Upload the AAB to the release track in the Play Console.
3. Changelog per locale goes into
   `fastlane/metadata/android/<locale>/changelogs/<versionCode>.txt`, ≤ 500
   characters — the same files F-Droid reads.
4. Screenshots must not show the Servers screen with personal subscriptions;
   use servers from `public-servers-manifest.json`.

## Gotchas

| What | Why |
|---|---|
| VPN apps get extra review | Play treats `VpnService` as a sensitive permission. The listing must state plainly what the app does with traffic; see [`PRIVACY_POLICY.md`](PRIVACY_POLICY.md) |
| The Play badge is licensed narrowly | The "Get it on Google Play" badge may be used to link to the app, unmodified. It may not be used to imply that Google endorses or certifies anything — see the note in [`design/certificate/README.md`](design/certificate/README.md) |
| Personal → organization account | Play now requires an organization account for most new developers; the migration needs a D-U-N-S number, which is issued separately and takes weeks |
