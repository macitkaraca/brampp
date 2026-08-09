# BRAMPP for Windows

**Status: not started.** This directory holds the design decision that has to be made
before any code is written.

## The question this platform has to answer

BRAMPP is not a bundle. On macOS it drives the Homebrew services already on the machine —
that is the product, and it is what separates it from the bundled stacks, which ship their
own Apache, their own PHP and their own MySQL.

Windows has no equivalent of `brew services`: no system-wide package manager, already
installed, that developers use and that supervises services. So "drive what is already
there" needs a different answer here, and the answer changes what gets built.

### Option A — Scoop or Chocolatey

Treat one of them the way macOS treats Homebrew.

Keeps the philosophy intact and the shape of the app familiar. The cost is the assumption:
most Windows developers do not already have Scoop or Chocolatey, so for them BRAMPP becomes
"install this package manager first", which is a worse first run than the competition.

### Option B — WSL2

Drive services inside a WSL2 Ubuntu, which does have apt and systemd.

Philosophically the cleanest, and it shares almost everything with the Linux build rather
than duplicating it. The Windows side becomes a native front end over a Linux back end.
The cost is WSL2 itself — its own install, its own filesystem boundary, and networking
between Windows and the VM that will surprise people.

### Option C — Bundle the binaries

Ship Apache, PHP and MariaDB.

The easiest first run by a distance, and the reason bundled stacks are popular. It also
makes BRAMPP the thing it currently defines itself against, and the positioning has to
change with it — on Windows it would compete on quality, not on architecture.

## Not decided yet

Pick before writing code. Each option produces a different application, and the wrong order
is to start building and let the architecture choose itself.

Whatever is chosen, these still hold:

- The [MCP tool contract](../spec/mcp-tools.md), so an assistant works the same everywhere.
- [`brampp.yml`](../spec/brampp-yml.md), so a project moves between machines and platforms.
- The [update manifest](../spec/update-manifest.md) at `updates/windows/stable.json`.
- MIT, signed builds, published checksums.
- No lock-in: removing BRAMPP leaves the services, the projects and the databases working.

## What is not shared

Nothing compiles across. The macOS build is SwiftUI and stays that way. A Windows build is
its own codebase — the specs above are the only thing holding the three together, which is
why they are written down rather than assumed.
