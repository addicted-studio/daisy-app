# Releasing Daisy

Branch model: **trunk + a stable line**, with audience separation handled by the
Sparkle appcast channel (not by the branch).

- **`main`** — trunk. All work lands here and ships as **beta** by default.
- **`stable`** — points at the last release promoted to the stable channel. The
  base for hotfixes to what everyone currently runs. Lags `main` on purpose.
- **tags** — `v<version>` on every release: rollback points + a version→commit map.

The Sparkle **channel** (who receives a build) is independent of the git branch
(the source). One file — `../Daisy-web/public/appcast.xml` — holds every release;
beta items carry `<sparkle:channel>beta</sparkle:channel>`, stable items don't.
The site's two buttons read `lib/latestVersion.ts` (stable) and `lib/betaVersion.ts`
(beta). Users opt into beta in-app via About → "Get beta updates".

Current pointers (2026-06-14): stable = **1.0.7.18 (b59)** @ `0e5db73`;
beta = **1.0.7.20 (b61)** on `main`.

---

## 1. Cut a beta — the default

From `main`, build green on device:

```sh
cd ~/Develop/Daisy
rm -f .git/index.lock                              # sandbox can leave a stale lock
DAISY_AUTO_PUSH=1 ./scripts/release.sh <version> <build> beta
#   builds / signs / notarizes, copies the DMG into Daisy-web, injects the
#   appcast beta <item>, rewrites lib/betaVersion.ts, commits + pushes Daisy-web.
#   It does NOT push daisy-app.
git add Daisy.xcodeproj/project.pbxproj            # release.sh bumps it (step 7)
git commit -m "<version> (b<build>)"
git push
git tag v<version> && git push origin v<version>
```

`<build>` must exceed the highest build already in `appcast.xml`.

## 2. Promote a soaked beta → stable — no rebuild

```sh
cd ~/Develop/Daisy
DAISY_AUTO_PUSH=1 ./scripts/release.sh promote <version>
#   strips the beta channel tag from that appcast <item> and points
#   lib/latestVersion.ts at it. Same DMG — everyone now gets it.
git switch stable && git merge --ff-only v<version> && git push   # advance the stable source pointer
git switch main
```

## 3. Hotfix a shipped stable — when `main` has already moved on

This is the whole reason the `stable` branch exists.

```sh
cd ~/Develop/Daisy
git switch stable
git switch -c hotfix/<short-desc>
#   … fix …
DAISY_AUTO_PUSH=1 ./scripts/release.sh <version>.<patch> <build> stable
git switch stable && git merge --ff-only hotfix/<short-desc>
git tag v<version>.<patch> && git push origin stable v<version>.<patch>
git switch main && git merge stable                # carry the fix forward into the beta line
```

## Notes

- Claude (the sandbox) can commit from `~/Develop/Daisy` but **cannot build,
  sign, notarize, or push** — those run on this Mac. Claude also tends to leave a
  stale `.git/index.lock`; if git complains, `rm -f .git/index.lock` before
  `add`/`commit`. `git push` itself doesn't use the lock.
- Tagging had lapsed at `v1.0.6.1`; it resumes here. Tag **every** release
  (stable and beta).
- Optional automation (not yet wired): teach `release.sh` to tag the app repo on
  each release and to fast-forward `stable` during `promote`. Until then the two
  `git` lines above do it by hand.
