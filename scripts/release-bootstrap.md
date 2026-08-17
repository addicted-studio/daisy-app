# Release bootstrap

One-time setup before `scripts/release.sh` can run. Walk through this
list once on the build machine; afterwards every release is just
`./scripts/release.sh <version> <build>`.

---

## 1. Sparkle SPM dependency

In Xcode:

1. **File → Add Package Dependencies…**
2. URL: `https://github.com/sparkle-project/Sparkle`
3. Dependency rule: **Up to Next Major**, starting from **2.6.0**.
4. Add to target: **Daisy**.

Xcode pulls Sparkle.framework and its XPC services. Build once
(⌘B) so the framework binaries land in DerivedData — the
`sign_update` binary lives inside the built artefact and
`release.sh` finds it by searching DerivedData.

---

## 2. EdDSA signing key

Sparkle uses an EdDSA key pair to sign updates. The private key
stays on this Mac; the public key is embedded in Daisy so clients
verify update authenticity.

In Terminal:

```sh
cd ~/Library/Developer/Xcode/DerivedData
find . -name "generate_keys" -type f | head -1
```

That prints the path to Sparkle's bootstrap binary. Run it:

```sh
/path/to/generate_keys
```

It prints:

```
A key has been generated and saved in your keychain.
Public key:
<base64 string>
```

The private key goes silently into the macOS login keychain
(Sparkle reads it from there when signing future releases). The
public key is what you paste into Daisy's build settings — copy it.

---

## 3. Daisy Build Settings (Info.plist via INFOPLIST_KEY)

Daisy uses `GENERATE_INFOPLIST_FILE = YES`, so there's no physical
Info.plist. Sparkle's keys go in via Build Settings.

In Xcode → **Daisy target** → **Build Settings** → click `+` →
**Add User-Defined Setting** for each of:

| Key                                              | Value                                |
| ------------------------------------------------ | ------------------------------------ |
| `INFOPLIST_KEY_SUFeedURL`                        | `https://mydaisy.io/appcast.xml`     |
| `INFOPLIST_KEY_SUPublicEDKey`                    | _the base64 key from step 2_         |
| `INFOPLIST_KEY_SUEnableAutomaticChecks`          | `YES`                                |
| `INFOPLIST_KEY_SUEnableInstallerLauncherService` | `YES`                                |

After adding, look at the auto-generated Info.plist at build time
(Products → right-click Daisy.app → Show in Finder → right-click →
Show Package Contents → Contents/Info.plist) — these four keys
should be there.

---

## 4. Notarisation credentials

`release.sh` calls `xcrun notarytool` with a keychain profile so it
doesn't prompt for credentials on every run. Create the profile
once:

```sh
xcrun notarytool store-credentials "daisy-notary" \
    --apple-id "your-apple-id@example.com" \
    --team-id "YOUR_TEAM_ID" \
    --password "app-specific-password-from-appleid.apple.com"
```

The password is an **app-specific password**, NOT your Apple ID
password. Generate one at
https://appleid.apple.com → Sign-In and Security → App-Specific
Passwords → +.

---

## 5. Environment variables (optional)

`release.sh` reads two env vars; either export them in your shell
profile or edit the script defaults at the top:

```sh
export DAISY_TEAM_ID="YOUR_TEAM_ID"
export DAISY_SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)"
```

You can find the exact identity string with:

```sh
security find-identity -v -p codesigning
```

---

## 6. create-dmg

```sh
brew install create-dmg
```

That's it — `release.sh` shells out to it for the actual disk
image packaging.

---

## 7. daisy-web repo layout

The release script automatically supports either layout:

```text
daisy-web/                 # website checkout
└── daisy-app/             # this repository nested inside it
```

```text
workspace/
├── daisy-app/             # this repository
└── daisy-web/             # website + appcast host
```

For any other layout, set `DAISY_WEB_REPO=/absolute/path/to/daisy-web`.

---

## First release — smoke test plan

1. Add markdown bullets to `scripts/release-notes/1.0.1.md`.
2. `cd daisy-app && ./scripts/release.sh 1.0.1 3 stable`.
   The script copies the signed DMG, injects the appcast item, updates the
   stable download pointer, and commits the website repository.
3. Review the generated daisy-web commit and push it. Set
   `DAISY_AUTO_PUSH=1` when the same command should push automatically.
4. Wait for Vercel to deploy.
5. On a Mac running the previous Daisy build: open Daisy →
   sidebar → **About → Updates → Check for Updates…**. Sparkle
   should find 1.0.1, show release notes, offer Install. Click
   Install — Daisy quits, the new DMG is mounted and copied in
   place, Daisy relaunches at 1.0.1.
6. After confirming, repeat with 1.0.2 to verify the
   auto-poll-then-prompt path (not just the manual button) — wait a
   day or set `automaticallyChecksForUpdates` + tweak the polling
   interval temporarily for testing.
