# Matt's copy of 3D Model Anything

For any agent working in this repo, `mjohnsonchung/3d-model-lidar-ios`. It's Matt's copy of [wesbos/3d-model-anything](https://github.com/wesbos/3d-model-anything), taken whole, with its history, on 27 Oct 2026 at Wes's commit `31b2dc9`. It's an iPhone app that scans rooms with LiDAR and photos, a Three.js viewer, and the `scan-to-threejs` agent skill that turns a scan into an editable 3D room. Matt made the repo on 27 Oct 2026. It's public for now, and he may make it private later. Its first commit is GitHub's starter README, and Wes's history was merged in after it.

- **How the brain uses it** (building the app, scanning, getting a scan to an agent, what it's for): the `room-scan` skill in Matt's brain, `skills/room-scan/SKILL.md` in the `big-brain` repo.
- **How to rebuild a room:** read `.agents/skills/scan-to-threejs/SKILL.md` and follow it. Wes's `README.md` and `apps/house-capture/README.md` are the reference for the viewer and the app.

## What's changed from Wes's copy
Kept small, so Wes's updates merge cleanly:
- The app's bundle ID is `com.mjohnsonchung.housecapture` (was `com.wesbos.housecapture`, in `apps/house-capture/project.yml` and its README). A bundle ID belongs to one Apple developer team, so Xcode can't sign Wes's for Matt's.
- `.github/workflows/pages.yml` runs only when started by hand. GitHub Pages isn't set up for this copy, and it needs a paid plan if the repo goes private.
- This file.

## Getting Wes's updates
```sh
git remote add upstream https://github.com/wesbos/3d-model-anything.git   # once
git fetch upstream && git merge upstream/main
```
Keep the changes above when a merge touches them. Never force-push.

## Rules
- **Licences.** The code and the skill are MIT. Files under `data/` and `docs/images/thumb-1.png` are Wes's office demo, under `ASSETS-LICENSE.md`. They're fine to run, study and keep in this copy of the repo, but not to sell or hand on as assets on their own.
- **While the repo is public, scans stay out of git.** `data/captures-in/`, `data/captures/` and `data/scans/` are ignored. Never commit a scan, its photos or a modelled room of Matt's home or a customer's here. If Matt makes the repo private, rooms can go in, with no file over 50 MB.
- **The `Check public release` workflow** is Wes's check that only his office goes public. It flags any new room under `demos/` or `data/`. That's the right warning while the repo is public.
- **No co-author or AI attribution lines** in commits or pull requests (Matt, 27 Oct 2026).
- **Commit straight to `main`** with plain messages, as Matt's brain does. Run `npm run build` before pushing a viewer change.
