# `brampp.yml` — project manifest

**Version 1.0**

A file in the project folder that carries the domain's settings, so cloning the repository
on another machine sets the environment up the same way instead of by hand.

It is committed with the project. That is the whole point, and it drives most of the rules
below: anything machine-specific must not go in it.

## Example

```yaml
name: shop.test
platform: php
web_server: nginx
php: "8.4"
document_root: public
ssl: true
run: npm run dev
build: npm run build
services:
  - mariadb
  - redis
```

## Keys

| Key | Required | Meaning |
| --- | --- | --- |
| `name` | yes | Domain name, e.g. `shop.test` |
| `platform` | yes | `php` · `nodejs` · `python` · `dotnet` · `static` |
| `web_server` | no | `apache` · `nginx` |
| `php` | no | PHP version as a string, e.g. `"8.4"` |
| `document_root` | no | Sub-folder **relative to the project root** |
| `port` | no | Port the app server listens on |
| `ssl` | no | Defaults to **true** when absent |
| `run` | no | Command that starts the app |
| `build` | no | Build command |
| `services` | no | Services the project expects, by id |

## Rules an implementation has to keep

**`document_root` is relative.** An absolute path names a user and a folder layout that do
not exist on the next machine. A build that reads an absolute path here should ignore it
rather than apply it.

**`ssl` defaults to true.** BRAMPP creates domains with HTTPS; a manifest that omits the
key must not quietly downgrade the site to plain HTTP.

**Applying a manifest never renames a domain.** The `name` identifies which project the
file belongs to. Renaming touches the vhost, the hosts entry and the certificate chain, and
must not happen as a side effect of applying settings.

**Unknown keys are ignored, not fatal.** A newer build may write keys an older one does not
know. Refusing the file would make the manifest useless the moment the formats differ.

**Only report what actually changed.** Applying a manifest that already matches should say
so and touch nothing — rewriting an identical vhost triggers a reload for no reason.

## Parsing

The supported grammar is deliberately narrow: `key: value` lines and `- item` lists, with
`#` comments and inline `# comment` tails. No nested mappings, anchors or multi-line
scalars. This is small enough to parse without a YAML dependency, which matters for a build
that otherwise has none.

An implementation that already has a YAML library may use it, as long as a file written by
the narrow writer round-trips.

A file missing `name` or `platform` is invalid and must be rejected rather than
half-applied.
