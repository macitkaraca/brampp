---
name: brampp_mysql
description: Manage MariaDB/MySQL and PostgreSQL databases through BRAMPP's MCP server — list, create, query, dump and restore; use for any BRAMPP task that touches a database
---

# BRAMPP — Database Tools

BRAMPP publishes an MCP server from inside the running app. These tools call the app's
LIVE managers; every change you make shows up in the BRAMPP window immediately.

- **Endpoint:** `http://127.0.0.1:8765/mcp` (loopback only, JSON-RPC 2.0 over `POST`)
- **Enable it:** BRAMPP → Settings → MCP → turn the switch on

If the tools do not respond, either BRAMPP is closed or the server is off — the user
opens both. If it keeps happening, the permanent fix is **Settings → General → "Launch
BRAMPP at login"**.

For the general BRAMPP tools (domains, services, logs) see the `mcptools` skill. This
document covers the **Databases** scope only.

## Read this first: permissions

All five tools belong to the **Databases** scope, which is set in Settings to
**No access / Read / Read + write**.

| Tool | Permission needed |
| --- | --- |
| `db_list` | Read |
| `db_query` (default) | Read |
| `db_query` (`allow_write=true`) | Read + write |
| `db_create` | Read + write |
| `db_export` | Read + write |
| `db_import` | Read + write |

A tool that is not permitted **never appears** in the `tools/list` response; if it is
called anyway the request is refused. When a tool you should have is missing, **the
problem is not you — it is the settings**: ask the user to open **Settings → MCP → Access
Permissions** and raise the Databases scope. Do **not** try to do the same job with shell
commands (`mysql`, `mysqldump`) — that circumvents the permission model.

`db_export` may look read-only, but it **requires write permission**: it writes the entire
database to a file on disk, which is a real side effect.

## Tools

### `db_list`
Lists databases. — *Read*

| Argument | Type | Description |
| --- | --- | --- |
| `engine` | string | `mysql` (default) or `postgres` |

### `db_create`
Creates a database; **leaves an existing one alone**. — *Write*

| Argument | Type | Description |
| --- | --- | --- |
| `name` | string | **Required.** Letters, digits and underscores only |
| `engine` | string | `mysql` (default) or `postgres` |

### `db_query`
Runs a single SQL statement. — *Read; `allow_write=true` needs Write*

| Argument | Type | Description |
| --- | --- | --- |
| `sql` | string | **Required.** One statement |
| `engine` | string | `mysql` (default) or `postgres` |
| `database` | string | Database to connect to |
| `allow_write` | boolean | Permit data-modifying statements — default `false` |
| `max_rows` | integer | Default 100, max 1000 |

Read-only by default: `SELECT`, `SHOW`, `DESCRIBE`, `EXPLAIN`, `WITH`. Queries whose body
contains a data-modifying command — including data-modifying CTEs — and functions that
reach the filesystem (`LOAD_FILE`, `pg_read_file`, `lo_import`, `pg_ls_*`) are rejected.
This is a security boundary; do not try to work around it.

### `db_export`
Dumps a database to `.sql`. — *Write*

| Argument | Type | Description |
| --- | --- | --- |
| `name` | string | **Required.** Database to dump |
| `engine` | string | `mysql` (default) or `postgres` |
| `path` | string | **Absolute** path for the target file, must end in `.sql`. Defaults to `~/Library/Application Support/BRAMPP/backups/<name>-<timestamp>.sql` |

MariaDB/MySQL uses `mysqldump --single-transaction --routines --triggers`: a consistent
snapshot without locking tables on InnoDB, keeping stored routines and triggers in the
dump. PostgreSQL uses `pg_dump`. The format is standard — the file restores fine without
BRAMPP in the picture.

It **will not overwrite** an existing file. If the dump fails the partial file is
**deleted**: a corrupt backup is worse than no backup.

### `db_import`
Applies a `.sql` dump to a target database. — *Write, DESTRUCTIVE*

| Argument | Type | Description |
| --- | --- | --- |
| `name` | string | **Required.** Target database |
| `path` | string | **Required.** Absolute path of the `.sql` file to read |
| `engine` | string | `mysql` (default) or `postgres` |
| `create_if_missing` | boolean | Create the target if absent — default `true` |

## Working rules

**Back up before you import.** Dump files usually contain `DROP TABLE` / `CREATE TABLE`;
if the target holds data it changes irreversibly. The order is always:

1. `db_list` — does the target exist, is the name right?
2. `db_export` — back up the target's current state
3. `db_import` — apply the dump
4. `db_query` — verify with a few `SELECT COUNT(*)`

If the target database has data, **ask first** even when the user did not request a
backup. Do not skip the "this will be overwritten" warning.

**Confirm destructive SQL with the user.** Before running `DROP`, `TRUNCATE`, or a
`DELETE`/`UPDATE` without a `WHERE` under `allow_write=true`, state in one sentence what
you are about to do and get approval. Having write permission does not mean every write
is wanted.

**Do not invent names.** Never guess a database name; confirm it with `db_list`. Names may
contain only letters, digits and underscores — anything else is rejected at the boundary.

**Path format.** `path` must be absolute, end in `.sql`, and contain no shell
metacharacters. A relative path is rejected; `~` is expanded.

## Testing sites: use HTTPS

BRAMPP issues a local SSL certificate for every domain it creates and installs it into the
system trust store. When you check a site in a browser or with `curl`, use **the domain's
HTTPS address**:

- Right: `https://myapp.local` — Apache; `https://myapp.local:8443` — Nginx
- Wrong: `http://127.0.0.1:3001` (the app's backend port — that is behind the reverse
  proxy and skips both the real request path and SSL)

Hitting the backend port directly does not test what the user actually sees: vhost
rewrites, headers and the certificate are all out of the picture. `list_domains` (in the
`mcptools` skill) returns the correct URL for each domain.

## Troubleshooting

**"Is the database running?" errors** — MariaDB may be stopped. Check with
`service_status` from the `mcptools` skill and start `mariadb` with `start_service`.

**PostgreSQL port** — several versions may be installed; the tools pick the RUNNING one.
If you see an unexpected database list, confirm which version is up with `service_status`.

**Connection identity** — Homebrew MariaDB uses `unix_socket` authentication; the tools try
`root` first, then the logged-in user. If neither works the problem is MariaDB's
configuration rather than BRAMPP — point the user at the TCP note on the Database tab.

**Detailed errors** — when an operation fails the reason is usually in the BRAMPP console:
check `read_log` from the `mcptools` skill. (If the Logs scope is *No access*, that tool
will not be visible.)
