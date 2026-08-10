# Windows — open decisions

A working list for this branch. Nothing here is settled; the point is to stop the
architecture from being chosen by accident.

## 1. What does it drive?

The three candidates are laid out in [`README.md`](README.md). Until this is answered the
rest of the list cannot be.

Worth measuring before deciding, rather than arguing about:

- How many Windows PHP developers already have Scoop or Chocolatey?
- How many already have WSL2 enabled?
- What does first run look like in each case, counted in steps and minutes?

See [`NOTES.md`](NOTES.md) for the platform facts that constrain these choices — nginx's
beta status on Windows, the absence of PHP-FPM, and how coarse elevation is compared to
macOS.

## 2. UI toolkit

Follows from (1). WinUI 3 and Avalonia both fit a native application; Tauri fits if the
back end ends up in WSL2 and the front end is thin.

## 3. Elevation

macOS asks for a password per operation and keeps no privileged helper running. Windows has
UAC, which is coarser. Editing the hosts file and binding low ports both need it. Deciding
between one elevated helper service and per-operation prompts changes the whole security
posture, and the macOS answer — never keep privilege around — should be the starting point.

## 4. Local HTTPS

`mkcert` runs on Windows and can write to the system store. Firefox keeps its own, as it
does everywhere.

## 5. Hosts file

`C:\Windows\System32\drivers\etc\hosts`, same idea as `/etc/hosts`, needs elevation to
write. The macOS build's rule applies unchanged: never leave a half-written entry, and
always show the exact change first.

## 6. Signing

Authenticode, and SmartScreen reputation takes time to build even with a valid signature.
Being open source does not remove the need to sign.

## 7. Packaging

MSI or an installer produced by WiX, plus a portable zip. Assets carry the version in the
filename so downloads do not pile up as `BRAMPP-Setup (3).exe`.

## Not up for discussion

These come from the specs and hold whatever is decided above:

- Tool names and permission scopes — [`spec/mcp-tools.md`](../spec/mcp-tools.md)
- `brampp.yml` — [`spec/brampp-yml.md`](../spec/brampp-yml.md)
- Update manifest — [`spec/update-manifest.md`](../spec/update-manifest.md)
- MIT, published SHA-256, no lock-in
