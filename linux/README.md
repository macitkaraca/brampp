# BRAMPP for Linux (Ubuntu first)

**Status: not started.**

## Why this one fits

Of the three platforms, Linux is the closest match to what BRAMPP already is. macOS has
Homebrew and `brew services`; Ubuntu has apt and systemd. Same idea, different names:

| | macOS | Ubuntu |
| --- | --- | --- |
| Packages | `brew install` | `apt install` |
| Services | `brew services start` | `systemctl start` |
| Service state | `brew services list` | `systemctl is-active` |
| Config | `/opt/homebrew/etc` | `/etc` |
| Site root | `~/Sites` | `~/Sites` (or `/var/www`) |

The product sentence needs no rewriting: it drives the packages and units already on the
machine, and removing it leaves them working.

## What is genuinely different

**Ports below 1024 need privilege.** macOS lets a user-owned Apache bind 80 through its own
launchd arrangements; on Linux binding 80 means root, a capability, or a higher port. This
affects the default port choice, not just the wording of a prompt.

**systemd is system-wide, not per-user.** `brew services` runs services as the logged-in
user. `systemctl` without `--user` touches the whole machine, and most distribution
packages install system units. Deciding between system and user units is the first real
design choice here.

**Certificate trust differs per distribution.** `mkcert` handles the common cases, but the
store lives in different places and Firefox keeps its own.

**Apache is `apache2`, not `httpd`.** Package names, binary names, config layout and the
`a2ensite`/`sites-available` convention all differ from Homebrew's. The abstraction that
already exists for Apache-versus-Nginx has to widen to cover Apache-versus-Apache.

## Still applies

- The [MCP tool contract](../spec/mcp-tools.md)
- The [update manifest](../spec/update-manifest.md) at `updates/linux/stable.json`
- MIT, published checksums, no lock-in

## Toolkit

Undecided. GTK, Qt and Tauri are all plausible; none of them share code with the macOS
build, so this is a choice about maintenance appetite rather than reuse.
