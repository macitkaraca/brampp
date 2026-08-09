# MCP tool contract

**Version 1.0**

The tools an assistant sees. A build may implement a subset — a Linux build with no
Homebrew equivalent for some service can omit it — but a tool that *is* present must
carry this name, these arguments and this permission scope.

Transport is JSON-RPC 2.0 over HTTP `POST`, bound to loopback only, off until the user
enables it.

## Permission scopes

Each scope is set independently to **no access**, **read**, or **read + write**.
Two layers, both required:

1. A tool the user has not permitted is **absent from `tools/list`**.
2. If it is called anyway, `tools/call` refuses it.

Filtering the list alone is not enough — a client that remembers tool names from an
earlier session would otherwise still reach them.

### Domains

| Tool | Access |
| --- | --- |
| `list_domains` | read |
| `create_domain` | write |
| `update_domain` | write, destructive |
| `set_domain_enabled` | write, destructive |
| `health_check` | read |
| `start_app` | write |
| `stop_app` | write, destructive |
| `app_status` | read |

Creating or changing a domain writes a vhost, an `/etc/hosts` entry and a certificate. All three must succeed or none of them may be left behind.

### Services

| Tool | Access |
| --- | --- |
| `service_status` | read |
| `start_service` | write |
| `stop_service` | write, destructive |
| `install_service` | write |
| `restart_service` | write, destructive |

Starting and stopping must verify that the process on the port is the one being managed. Killing whatever holds a port is not acceptable.

### Databases

| Tool | Access |
| --- | --- |
| `db_list` | read |
| `db_create` | write |
| `db_export` | write |
| `db_import` | write, destructive |
| `db_query` | read, destructive |

`db_query` is read-only unless `allow_write` is set. Statements that modify data or reach the filesystem are refused even then — the boundary is not advisory.

### Logs

| Tool | Access |
| --- | --- |
| `read_log` | read |
| `read_domain_log` | read |

`read_log` reads the application's own console. `source: "file"` must reach further back than the in-memory buffer.

### Sharing

| Tool | Access |
| --- | --- |
| `list_shares` | read |
| `start_share` | write |
| `stop_share` | write, destructive |

Defaults to **no access** — the only scope that does. These tools put a local site on the public internet.

## What a refusal must say

When a call is refused on permission grounds the message names the scope and the level
it needs. An assistant that is told only "denied" will retry, or try to reach the same
end another way — usually by shelling out, which is exactly what the permission was for.

## Skills

Two skill files ship with the app and describe these tools to the assistant:
`mcptools` (general) and `brampp_mysql` (databases). They are part of the contract —
a build that changes tool behaviour updates them in the same commit.
