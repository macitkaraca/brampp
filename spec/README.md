# BRAMPP specifications

Three platform builds, no shared code. macOS is SwiftUI, and whatever Windows and Linux
become, none of it compiles across. What *has* to stay identical is the contract: the tools
an assistant sees and the file an updater reads.

Without these written down, three implementations drift and the documentation stops being
true for at least two of them.

| File | What it fixes |
| --- | --- |
| [`mcp-tools.md`](mcp-tools.md) | Tool names, arguments and permission scopes exposed over MCP |
| [`update-manifest.md`](update-manifest.md) | The static JSON an installed build reads to learn about new versions |

A platform build is "BRAMPP" when it implements these. It is free to do so with different
technology, and free to leave parts unimplemented — but not free to rename a tool, add an
argument that means something else, or answer an update check in a format of its own.

## Versioning

Each spec carries a version at the top. Additive changes bump the minor; anything that
would break an existing client bumps the major and needs a note in every implementation's
changelog.
