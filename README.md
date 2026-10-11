# Provisions

WoW Forever addon: one-button macros and an item bar for your best food, drink, potions, bandages and healthstones.
See [CURSEFORGE.html](CURSEFORGE.html) for the CurseForge description (paste into the editor's source view) and [CHANGELOG.md](CHANGELOG.md) for changes.

## Releasing
1. Update `CHANGELOG.md`.
2. Put the new version as the first `## v1.6` heading in `CHANGELOG.md`, commit and push to main.
3. GitHub Actions tags the commit, packages the addon and uploads it to CurseForge.

Needs the repository secret `CF_API_KEY`. CurseForge project: https://www.curseforge.com/projects/1738354
