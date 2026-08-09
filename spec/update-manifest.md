# Update manifest

**Version 1.0**

A small static JSON file, served from GitHub Pages, that an installed build reads to learn
whether a newer version exists.

```
https://macitkaraca.github.io/brampp/updates/<platform>/<channel>.json
```

`platform` is `macos`, `windows` or `linux`. `channel` is `stable`, `beta` or `nightly`.

## Example

```json
{
  "version": "1.4.0",
  "channel": "stable",
  "published": "2026-08-10",
  "release": "https://github.com/macitkaraca/brampp/releases/tag/v1.4.0",
  "minimumOS": "14.0",
  "mandatory": false,
  "blockedVersions": [],
  "downloads": {
    "arm64": {
      "url": "https://github.com/macitkaraca/brampp/releases/download/v1.4.0/BRAMPP-1.4.0.dmg",
      "sha256": "…"
    }
  }
}
```

## Why not just ask the GitHub API

The API answers "what is the latest release", which is less than an updater needs. It
cannot say *this version is mandatory*, *that version is known-bad*, or *you are on a
channel*. Those live here.

There is also a rate limit — 60 requests an hour per address, unauthenticated. A single
developer never notices; an office behind one address, all launching the same app, can.

A static file has neither problem, and costs a couple of kilobytes. GitHub Pages has a
100 GB monthly soft limit, which a 2 KB manifest reaches at around fifty million checks.

The binaries stay on Releases, which publishes no bandwidth limit.

## Rules

**Compare numerically, not as text.** `1.10.0` is newer than `1.9.0`. A string comparison
says otherwise and would tell every user on 1.9 that they are up to date forever.

**Never update silently.** BRAMPP tells the user and hands them the download. An app that
manages someone's development environment does not replace itself while they are working.

**Verify before installing.** The `sha256` in the manifest is the one to check, not a
checksum fetched from beside the binary — a single compromised host should not be able to
supply both the file and the hash that vouches for it.

**A missing manifest is not an error.** No file, unreachable host, unparseable JSON: report
"could not check" and carry on. An update check that blocks startup is worse than no update
check.

**`blockedVersions` outranks `mandatory`.** A user on a version listed there is told to
move regardless of the channel's mandatory flag; that list exists for the case where a
release turned out to be harmful.
