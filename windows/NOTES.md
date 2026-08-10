# Windows — platform notes

Findings that constrain the design, kept separate from [`DECISIONS.md`](DECISIONS.md)
because these are facts to design around rather than choices to make.

Sources are linked. Anything not verified is marked as such.

## nginx on Windows is a beta build

nginx's own documentation classifies the Windows version as beta, and the limitations are
not cosmetic:

- Only `select()` and `poll()` are used, so "high performance and scalability should not be
  expected"
- Multiple workers can be started but **only one actually does any work**
- No UDP, and therefore no QUIC
- No XSLT filter, image filter, GeoIP module or embedded Perl

Source: <https://nginx.org/en/docs/windows.html>

**What this changes.** On macOS, Apache and nginx are peers and the user picks per domain.
On Windows they are not peers, and offering them as though they were would be misleading.
Apache — or IIS, which is already on the machine — is the honest default, with nginx
available and labelled for what it is. For local development the limitations rarely bite,
but the UI should not imply parity that the upstream project itself denies.

## PHP has no FPM on Windows

There is no `php-fpm.exe`. The equivalent is a pool of `php-cgi.exe` processes behind
FastCGI, one pool per version, each on its own loopback port. Apache reaches them with
`mod_proxy_fcgi`, nginx with `fastcgi_pass`, IIS with its FastCGI handler.

Non-thread-safe builds are the ones to use for FastCGI; thread-safe builds exist for
in-process handlers.

**What this changes.** The macOS build asks "is PHP-FPM running for this version". The
Windows build has to own the pool itself: start it, supervise it, restart it, and know how
many workers are alive. That is a supervisor BRAMPP writes, not a service it observes.

## Killing processes by name is not acceptable

`taskkill /IM php-cgi.exe` ends every `php-cgi.exe` on the machine, including ones BRAMPP
did not start.

The macOS build already refuses to work this way — it verifies that the PID holding a port
belongs to the service before signalling anything. Windows needs the same guarantee, which
means recording what was started: PID, executable path, arguments, and which runtime and
port it belongs to.

This is the single rule most likely to be broken by a quick first implementation, and the
consequence is killing a developer's unrelated work.

## Elevation is coarser than on macOS

macOS asks per operation and keeps no privileged helper. Windows has UAC, which is
all-or-nothing per process.

Editing `hosts`, binding 80 and 443, writing to the machine certificate store and managing
services all need it. The two shapes are: prompt for every operation, or install a small
privileged service once and talk to it over a named pipe.

**Unresolved, and it is the security decision of the project.** A long-lived privileged
service is a larger attack surface than macOS BRAMPP has ever had; a prompt per operation
is what the macOS build does and what its users already accept. Whichever is chosen, the
macOS rule stands: show the exact command first, and never leave privilege running longer
than the operation needs.

## Redis has no first-party Windows build

Redis does not ship a native Windows server. The practical options are WSL, a
Windows-compatible reimplementation, or an external server.

Not verified: which of those Redis currently points to. Check before naming any of them in
the UI, and do not present a compatible reimplementation as "Redis" — behavioural parity is
not guaranteed and a cache that differs subtly is worse than one that is absent.

## What carries over unchanged

- `hosts` edits fenced by markers, so other software's entries are never touched
- `mkcert` for local certificates, into the system trust store
- Projects live in the user's own folder, never inside the application's data directory
- The [MCP tool contract](../spec/mcp-tools.md) and [`brampp.yml`](../spec/brampp-yml.md)

The manifest is the one that matters most here: the same file, written on a Mac and applied
on Windows, is the clearest evidence the spec was worth writing.
