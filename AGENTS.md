# Project agent memory

This file is the project's committed home for project-intrinsic agent knowledge: build, test, release, architecture, and sharp-edge notes that should travel with the code.

- Add durable project-specific notes here as they are discovered through real work.

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.

## Project commands

- Service tests: `cd service && pytest`; runtime settings and the 30-day JWT policy are documented in `service/README.md` and `.env.example`.
- Regenerate the checked-in iOS project after changing `ios/project.yml` with `cd ios && xcodegen generate`; build with the `xcodebuild` command documented by the Xcode project/scheme.
