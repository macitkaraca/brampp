# Security

*[Türkçe](SECURITY.tr.md)*

## Reporting a vulnerability

Report privately, not in a public issue: open a [security advisory](https://github.com/macitkaraca/brampp/security/advisories/new), or email **info@karacatechnology.com**.

Please include what an attacker gains, the steps to reproduce it, and the BRAMPP version. A working proof of concept is welcome but not required — a clear description of the mechanism is enough to start.

You will get a first reply within a week. If a fix is warranted it ships in the next release, and the changelog says what was wrong. Nothing is published before a fix exists.

## Supported versions

Only the latest release. BRAMPP is a single-developer project with frequent releases and no backport branches; a fix reaches you by updating, which the app can now do in place.

## What BRAMPP touches on your machine

Worth knowing when judging whether something is a vulnerability:

**It drives services that are already installed.** BRAMPP starts, stops and configures Homebrew formulae — Apache, nginx, PHP-FPM, MariaDB, PostgreSQL, Redis. It writes to their configuration files under the Homebrew prefix and to `/etc/hosts`. It does not bundle its own copies of any of them, and removing BRAMPP leaves them working.

**It asks for administrator rights in exactly one place.** Editing `/etc/hosts` needs them. Nothing else does — not installing services, not updating the app itself. A build that asks for your password anywhere else is not one of ours.

**The MCP server binds to loopback only** and is off until you turn it on. It exposes tools in five permission areas, each independently set to no access, read or write, and the sharing area defaults to no access because those tools put a site on the public internet. A tool you have not permitted is not listed and is refused if called anyway.

**Sharing is temporary and never automatic.** Cloudflare Quick Tunnels are started only when you ask, are never written to disk, and all of them close when BRAMPP quits. A site with nothing running behind it cannot be shared.

**Updates are verified before they are installed.** The download is checked against the checksum in the update manifest, its signature and publisher identity are confirmed, and Apple's notarization is checked. The same checks run again on the copy that actually gets installed, because the thing that was verified and the thing that gets installed are separated by a copy.

## Out of scope

Reports that amount to "an attacker who already runs code as you can do what you can do" are not vulnerabilities in BRAMPP. The same goes for weak defaults in the services themselves — a database with no password is Homebrew's default, not something BRAMPP introduces, though we are interested in cases where BRAMPP makes such a default *reachable* by something that could not reach it before.
