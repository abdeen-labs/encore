# Releasing

How a release of Encore is cut. Xcode builds, signs, and notarizes the app; `scripts/publish-release.sh` checks,
packages, and publishes it.

## How updates reach people

- Sparkle in Encore checks `https://updates.abdeen.industries/encore/appcast.xml` (`Config/Info.plist`'s
  `SUFeedURL`) once a day, after asking on the second launch, and on Encore ▸ Check for Updates…. Only Release
  builds check.
- The update host answers `/encore/<file>` with the bucket's object `encore/<file>`. The bucket holds the appcast
  and every release's DMG, `encore/Encore-<version>.dmg`.
- New users download from `https://encore.abdeen.dev/download`, which the README and the site link to. The site
  ([abdeen-labs/encore.abdeen.dev](https://github.com/abdeen-labs/encore.abdeen.dev)) reads the appcast every
  10 minutes and sends that link to the newest DMG it lists, so a release needs no link changed anywhere.
- Sparkle's EdDSA key signs the appcast (`SURequireSignedFeed`) and each DMG, and Encore checks both against
  `SUPublicEDKey`, the DMG before unpacking it (`SUVerifyUpdateBeforeExtraction`). Once a release is out,
  `SUPublicEDKey` never changes: copies with it can't verify anything signed with another key.
- Gatekeeper's side is Apple's: Xcode signs the app with Developer ID, notarizes it, and staples the ticket. The
  DMG around it isn't notarized.
- Homebrew installs the same DMG through the tap `abdeen-labs/homebrew-tap`
  (`brew install --cask abdeen-labs/tap/encore`). `Casks/encore.rb` pins the version and the DMG's SHA-256, and
  the script moves both on each release. Sparkle updates copies installed this way like any other.

## What's in the app

- **The Python runtime.** The app target's Embed Python build phase (`scripts/embed-python-runtime.sh`) copies
  `PythonHelper/.runtime/python` and the helper into `Contents/Resources`, precompiles them, and signs every
  Mach-O file in them with the hardened runtime. When Xcode archives, it signs them with the team's Developer ID
  Application certificate and a secure timestamp: Xcode's export re-signs the app and its frameworks, but not code
  under `Resources`. Debug builds skip the phase and run the repo-local runtime. The phase needs the target's
  `ENABLE_USER_SCRIPT_SANDBOXING = NO`.
- **Sparkle**, linked through the `EncoreUpdates` product of `Packages/EncoreCore`. Xcode's export signs its
  helpers with Developer ID.

## The DMG

The DMG opens a styled window: "Places, please." over Encore's dark ground, Encore and Applications side by side,
and a lit arrow between them. [dmgbuild](https://dmgbuild.readthedocs.io) writes the window's layout from
`Config/dmg-settings.py`, without driving Finder; `publish-release.sh` installs it in a venv under `build/` the first
time, so a Python 3 must be on `PATH` (or in `PYTHON`). The background is `Config/dmg-background.tiff`, rendered by
`swift scripts/render-dmg-background.swift`. The two files share the window size and the icon positions; change
them together, and render again after changing the script. Finder draws the names black in light mode and white in
dark mode, so they sit on mid-tone capsules that read in both.

## One-time setup

1. **Developer ID Application certificate** in the login Keychain: Xcode ▸ Settings ▸ Accounts ▸ the team ▸
   Manage Certificates ▸ + ▸ Developer ID Application.
2. **Sparkle key**, under its own Keychain account. Sparkle's tools are in Xcode's DerivedData once Xcode has
   opened the project: `~/Library/Developer/Xcode/DerivedData/Encore-*/SourcePackages/artifacts/sparkle/Sparkle/bin`.
   - `generate_keys --account encore` creates the key and prints its public half. Put that in `Config/Info.plist`
     as `SUPublicEDKey` (a string) and commit it.
   - Back up the private key: `generate_keys --account encore -x <file>`, keep the file's contents in your
     password manager, and delete the file. Without it, no update reaches installed copies again. On another Mac,
     `generate_keys --account encore -f <file>` imports it.
3. **Railway CLI**, signed in (`railway login`) to the account with the `updates` project, and this checkout
   linked to it: `railway link` in the checkout's root, then the `updates` project, the `production` environment,
   and the `updates` service. The link is kept in the CLI's settings, not the repo. The script runs each upload
   through `railway run`, which gives it the bucket's credentials from the update host's service.
4. **Push access to the tap** over SSH: `git@github.com:abdeen-labs/homebrew-tap.git`.
5. **The Python runtime**: `scripts/setup-python-runtime.sh`. It installs the latest packages that satisfy
   `PythonHelper/requirements.txt`; run it again before a release to ship newer ones, and test a build with them.

## Cutting a release

1. **Release notes** go in `CHANGELOG.md` under `## [<version>] - <date>`, e.g. `## [1.0.1] - 2026-12-02`,
   written for the people updating: they're what the update window shows. `scripts/changelog.sh <version>` prints
   what will ship.
2. **Version**: raise `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in the Encore target (General ▸
   Identity). The build number must be higher than every published one; Sparkle compares it.
3. **Commit and push** `main`.
4. **Archive**: Product ▸ Archive. The first time, macOS asks to let `codesign` use the Developer ID key: Always
   Allow.
5. **Export**: in the Organizer, Distribute App ▸ Direct Distribution. Xcode notarizes and staples the app. Export
   `Encore.app` to `~/Developer/exports`.
6. **Publish**: `scripts/publish-release.sh`. The first release runs with `FIRST_RELEASE=1`, since the feed has
   no appcast yet. `UPLOAD=0` stops after making `dist/Encore-<version>.dmg` and the signed `dist/appcast.xml`,
   to look at them first.
7. **Check**: an installed older release finds the update with Check for Updates…, shows the notes, installs it,
   and relaunches.

## What the script checks

`publish-release.sh` stops before making anything when:

- the app's version isn't the project's, or it isn't notarized and stapled, or Gatekeeper rejects it;
- the app's feed isn't Encore's, or it has no public key;
- the app's bundled Python helper doesn't start and answer;
- the checkout has changes, or HEAD isn't `origin/main`;
- the version's tag names another commit;
- the tap can't be reached;
- the Keychain's Sparkle key isn't the app's;
- the build number isn't higher than every one in the feed.

It refuses to replace a published DMG with different contents, uploads the DMG before the appcast, reads each back
through the update host, tags `v<version>`, and then sets the cask's version and SHA-256 and pushes the tap.

## When publishing stops partway

Fix the cause and run `scripts/publish-release.sh` again. The DMG in `dist/` is reused while it holds the same
app, a DMG already uploaded is kept when it matches, the appcast's entry for the version is replaced, the tag is
made when it's missing, and the cask is left alone when it's already at the version. A published DMG is never
replaced: to ship a different build, raise the version and archive again.
