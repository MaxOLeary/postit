# Release checklist

Run through this before `--ship`. The failures here are quiet: a build that
looks fine and gets bounced by Gatekeeper on someone else's Mac.

## 1. Code is green

```sh
cd Swift && ./build.sh
```

- [ ] Builds clean, no warnings you have not read.
- [ ] Postit relaunches and your notes come back.

## 2. Repo is clean

- [ ] `git status` clean.
- [ ] Everything pushed (`git log origin/main..main` is empty).

## 3. Ship

```sh
cd Swift && ./build.sh --ship
```

Read the three verdicts it prints:

- [ ] `Signing identity:` is `Developer ID Application: ...` or `Postit Dev`.
      Never `-`. The script refuses to ship ad-hoc, but look anyway.
- [ ] `codesign verify: OK`, then `flags=0x10000(runtime)` and an `Authority=` line.
- [ ] `spctl verdict` says `rejected` with `origin=Postit Dev` (today), or
      `accepted` once notarized. If it says `revoked`, stop. That is the
      Malware Blocked dialog nobody can click past, and it means the build
      went out unsigned.
- [ ] Commit the refreshed `Postit.app/` **and `SHIPPED.json`** with the code,
      then push. The zip on the release and the app in the repo must be the
      same build.

## 4. The committed app matches the committed source

```sh
./Swift/verify-tracked-app.sh
```

- [ ] Exits 0. It compares `Postit.app`'s binary against the digest in
      `SHIPPED.json` and checks that `Swift/main.swift` has not moved on since
      that build. This is the one check that catches the quiet failure plain
      `./build.sh` creates: it never touches the tracked app, so the repo can
      ship a binary several commits behind the source with nothing to say so.
      Run it after the commit in step 3, on a clean tree.

## 5. It survives being downloaded

- [ ] Open <https://github.com/MaxOLeary/postit/releases/latest/download/Postit.zip>
      in Safari, unzip, double-click it once.
- [ ] Until notarized: the Open Anyway path in the README still matches
      what macOS shows. If the guide is wrong, the guide is the bug.
