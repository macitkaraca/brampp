# Contributing

*[Türkçe](CONTRIBUTING.tr.md)*

## What is where

```
macos/          the macOS app — SwiftUI, no third-party dependencies
  BRAMPP/       Core (pure logic) · Managers (state + shell) · Views · Models
  BRAMPPTests/  one file, XCTest
windows/        design decisions, no code yet
linux/          the same
spec/           what all three platforms must agree on
docs/           the site — _pages/ is the source, everything else is generated
.claude/skills/ the skill files the app installs, one copy of two
```

## Building and testing

```bash
xcodebuild test -project macos/BRAMPP.xcodeproj -scheme BRAMPP -destination 'platform=macOS'
```

That builds and runs everything. Release builds use `-Osize`; `-O` costs half an hour and buys nothing for an app that spends its life waiting on shell commands.

## Things that will catch you out

**`Localization.swift` is one dictionary literal.** A duplicate key crashes at runtime, not at compile time. After adding keys, run the tests — one of them walks the catalogue.

**Format specifiers must match across languages.** `String(format:)` silently swallows surplus arguments, so a Turkish string with two `%@` and an English one with three produces no error and a wrong sentence.

**The skill file exists twice.** `macos/BRAMPP/Core/MCPToolsSkill.swift` carries a `{{PORT}}` placeholder and `.claude/skills/mcptools/SKILL.md` carries the resolved port. A test compares them byte for byte, so change both or neither.

**The site is generated and the output is committed.** `docs/_build.py --check` only validates links and writes nothing; `docs/_build.py` with no arguments does nothing at all. Pass the page names:

```bash
python3 docs/_build.py features changelog
```

Forgetting this means the change is in the repository and not on the site.

**`spec/` binds all three platforms.** Renaming an MCP tool or changing what an argument means is a spec change first and a code change second.

## Style

Match the file you are editing. Two things the codebase does consistently:

Comments explain **why**, and they earn their place by recording what went wrong. `// increment the counter` is noise; `// the generation counter is bumped here because an in-flight task would otherwise write the vhost back` is the reason the line cannot be deleted.

Pure logic goes in `Core/` and is tested directly. Anything that runs a shell command, touches a file or holds state belongs in a `Manager`, and the decision it makes should be a pure function that a test can call without a machine in a particular state.

## Commits

One subject line in the imperative, then prose explaining what was wrong. The changelog is written from these, so a commit that says only "fix bug" costs someone else the work of finding out which.

No AI attribution in commit messages or anywhere else in the repository.

## Pull requests

Open an issue first for anything larger than a fix — the three-platform split and the specs mean some changes are wider than they look. Small, well-explained changes need no ceremony.
