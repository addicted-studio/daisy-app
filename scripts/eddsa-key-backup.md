# EdDSA signing key — off-machine backup & disaster recovery

> **Why this matters.** Sparkle accepts a DMG update only if its
> `sparkle:edSignature` verifies against the EdDSA public key compiled
> into the previous version of the app (`SUPublicEDKey` in
> `Info.plist`). If we lose the private half:
>
> 1. We can mint a new keypair and ship it in the next release, BUT
> 2. Every existing install on the old `SUPublicEDKey` will reject
>    every future DMG until the user manually re-downloads from
>    mydaisy.io. Auto-update is permanently broken for that cohort.
>
> Right now the private key lives in **two places on one machine**:
>   - macOS Login keychain (used by Sparkle's `sign_update` CLI)
>   - 1Password "Daisy / Sparkle EdDSA" item (manual copy)
>
> Both copies vanish if the MacBook Air dies, is stolen, or the disk
> is wiped before 1Password syncs. This SOP eliminates the single
> point of failure by writing the key to **physical media stored
> outside the laptop** — encrypted, with the passphrase recorded
> separately.

---

## Backup procedure (do this once)

### 1 — Export the private key safely (no stdout)

Open **Keychain Access.app** (`open -a "Keychain Access"`).

In the search box: `sparkle`.
- Service / account: `https://sparkle-project.org` / `ed25519`
  (Sparkle's generate_keys default).
- Double-click the entry → tick **Show password** → Touch ID auth →
  the password field shows the base64 private key.
- ⌘C to copy.

**Important:** do NOT use `security find-generic-password -w` from
the terminal. That command emits the raw key to stdout — same way
the key leaked into a Cowork transcript on 2026-05-19. Keychain
Access keeps the key in the Pasteboard only; we'll move it to an
encrypted DMG next and then clear the clipboard.

### 2 — Stage the key into a one-line text file

```bash
mkdir -p ~/Downloads/daisy-key-staging
pbpaste > ~/Downloads/daisy-key-staging/sparkle_ed25519_private.b64
ls -la ~/Downloads/daisy-key-staging/
```

The file should be a single line, ~88 characters (base64-encoded
ed25519 private key + `==` padding). Verify:

```bash
wc -c ~/Downloads/daisy-key-staging/sparkle_ed25519_private.b64
# expect ~88-89 bytes
```

Also drop a tiny README into the same folder so future-you knows
what this thing is:

```bash
cat > ~/Downloads/daisy-key-staging/README.txt <<EOF
Daisy.app — Sparkle EdDSA private signing key.
Public counterpart lives in Daisy/Info.plist as SUPublicEDKey.
If lost, every existing Daisy install loses auto-update permanently.

To restore: paste the contents of sparkle_ed25519_private.b64 back
into Login keychain via Keychain Access → File → New Password Item:
  Keychain Item Name : https://sparkle-project.org
  Account Name       : ed25519
  Password           : <paste the b64 line>

To verify: ./scripts/release.sh runs sign_update which reads from
this keychain entry.
EOF
```

### 3 — Encrypt into a DMG

```bash
hdiutil create \
    -encryption AES-256 \
    -stdinpass \
    -volname "DaisySigningKey" \
    -srcfolder ~/Downloads/daisy-key-staging \
    -format UDBZ \
    -fs HFS+ \
    ~/Downloads/daisy-signing-key-backup.dmg
```

`-stdinpass` reads the passphrase from stdin so it never appears in
the shell history. Type a fresh passphrase (NOT your login password
and NOT your 1Password master). 12+ chars, mixed.

Verify by mounting:

```bash
hdiutil attach ~/Downloads/daisy-signing-key-backup.dmg
ls /Volumes/DaisySigningKey
hdiutil detach /Volumes/DaisySigningKey
```

### 4 — Wipe the unencrypted staging copy + clipboard

```bash
rm -rf ~/Downloads/daisy-key-staging
pbcopy < /dev/null    # clear pasteboard
```

### 5 — Move the encrypted DMG off the laptop

Two copies, two locations:

- **Copy A:** USB drive, kept in a physical drawer / safe / parents'
  house — somewhere a fire or theft of the laptop doesn't also take
  this with it. Plain `cp ~/Downloads/daisy-signing-key-backup.dmg
  /Volumes/<usb>/`.
- **Copy B:** a second USB at a different physical location, OR a
  trusted family member's house, OR a bank safe deposit box.

After both copies confirmed-readable on the target machines:

```bash
rm ~/Downloads/daisy-signing-key-backup.dmg
```

### 6 — Record the DMG passphrase

Two independent stores so loss of either still leaves recovery:

- Write the passphrase on paper, store with **Copy A** USB (but in a
  separate envelope inside the same drawer).
- Add to 1Password as a NEW item titled "Daisy / Sparkle backup DMG
  passphrase" — distinct from the existing "Daisy / Sparkle EdDSA"
  entry. Tag both with `daisy-release-critical` so they show up
  together on search.

---

## Restore procedure (if MacBook dies)

1. Get one of the USB drives.
2. `hdiutil attach /Volumes/<usb>/daisy-signing-key-backup.dmg` →
   enter passphrase.
3. Open Keychain Access on the new machine → File → New Password Item:
   - Keychain Item Name: `https://sparkle-project.org`
   - Account Name: `ed25519`
   - Password: paste the contents of
     `/Volumes/DaisySigningKey/sparkle_ed25519_private.b64`
4. Run `./scripts/release.sh 1.0.X N` end-to-end. The
   `sign_update` step pulls the key back out of keychain
   automatically — no further config.

---

## Verification cadence

- **Each major release** — confirm both USB copies are still readable
  (mount + ls). Drives die silently; we want to catch dead media
  before we need it.
- **Annually (May)** — rotate USB drives if older than 5 years. Flash
  cells decay even without use.

---

## What NOT to do

- Don't store the unencrypted key in iCloud Drive, Dropbox, GitHub,
  email, or any chat app (Slack, Discord, Telegram, Cowork). The
  2026-05-19 exposure of this exact key in a Cowork transcript is on
  the timeline; if it happens a second time we'll have to rotate and
  break every existing install's auto-update.
- Don't `cat` the key to terminal, don't `echo`, don't `security
  find-generic-password -w`. Anything that puts the key in your
  shell history is broken.
- Don't store the DMG passphrase in the same place as the DMG — that
  defeats the encryption. Paper-in-drawer + 1Password is fine because
  the attacker would need both.

---

Related memory entries:
- `feedback_eddsa_key_chat_exposure.md` — what happened on 2026-05-19
- `project_daisy_sparkle_setup.md` — Sparkle pipeline overview
