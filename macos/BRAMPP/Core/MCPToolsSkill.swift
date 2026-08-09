import Foundation

// MARK: - MCPToolsSkill

/// "mcptools" becerisinin metni — hem Claude becerisi (~/.claude/skills/mcptools/SKILL.md)
/// hem de Codex talimat dosyası (~/.codex/AGENTS.md) bu tek kaynaktan yazılır.
///
/// `markdown` bir ŞABLONDUR: uç nokta portu `{{PORT}}` yer tutucusuyla yazılır ve kurulum
/// sırasında `rendered(port:)` ile GERÇEK portla değiştirilir. Yoksa kullanıcı portu
/// değiştirdiğinde ajana yanlış adres anlatılırdı.
///
/// İçerik depodaki `.claude/skills/mcptools/SKILL.md` ile BİREBİR aynıdır; ikisinin
/// ayrışmadığını `testMCPToolsSkill_MatchesRepositorySkillFile` doğrular.
enum MCPToolsSkill {

    /// Beceri adı — kurulum klasörünün adıyla ve ön maddedeki `name:` ile aynı olmalı.
    static let name = "mcptools"

    /// Şablondaki port yer tutucusu.
    static let portPlaceholder = "{{PORT}}"

    /// Port bilinmiyorsa kullanılacak varsayılan (AppSettings.mcpServerPort ile aynı olmalı).
    /// `nonisolated`: varsayılan argüman olarak (installSkill(port:)) çağıranın bağlamında
    /// değerlendirilir; MainActor'a bağlı kalırsa orada uyarı/derleme hatası olur.
    nonisolated static let defaultPort = 8765

    /// Şablonu gerçek portla doldurur — kurulan/yazılan metin budur.
    static func rendered(port: Int) -> String {
        markdown.replacingOccurrences(of: portPlaceholder, with: String(port))
    }

    /// SKILL.md şablonu (ön madde dahil). Yazmadan önce `rendered(port:)`'ten geçir.
    static let markdown = """
    ---
    name: mcptools
    description: Manage a local development environment through BRAMPP's MCP tools — domains, services, databases and logs; use whenever you are working with the BRAMPP MCP server
    ---

    # BRAMPP MCP Server

    BRAMPP (a Homebrew-based XAMPP alternative) publishes an MCP server from inside the
    running app. The tools call the app's LIVE managers — every change you make shows up in
    the BRAMPP window immediately.

    - **Endpoint:** `http://127.0.0.1:{{PORT}}/mcp` (loopback only; JSON-RPC 2.0 over `POST`)
    - **Enable it:** BRAMPP → Settings → MCP → turn the switch on
      (the port is configurable on that screen; default 8765)

    ## When you cannot connect

    If the tools do not respond there are two possibilities, and **the user resolves both**.
    Do not try to launch the app yourself, and do not fall back to another route (shell
    commands, editing files) to do the same job.

    1. **BRAMPP is closed.** Ask the user to open it. The MCP server runs *inside* the app;
       with BRAMPP closed there is no endpoint at all.
    2. **The server is off.** If BRAMPP is open, ask the user to enable **Settings → MCP**.

    If this keeps happening, tell them the permanent fix: **Settings → General → "Launch
    BRAMPP at login"**. The app then registers as a system login item, starts with the
    session and MCP is always ready. One mechanism, and it works for every client (Claude
    Code, Claude Desktop, ChatGPT Codex).

    ## Access permissions — check here first when a tool is missing

    Tools are grouped into five scopes: **Domains**, **Services**, **Databases**, **Logs**,
    **Sharing**.
    Each scope is set in Settings to **No access / Read / Read + write**.

    A tool that is not permitted **never appears** in the `tools/list` response; if it is
    called anyway the request is refused. So when a tool described here is missing from your
    list, or a call is refused on permission grounds, **the problem is not you — it is the
    settings**: ask the user to open **Settings → MCP → Access Permissions** and raise the
    relevant scope. Do not try to accomplish the same thing another way.

    | Scope | Read tools | Write tools |
    | --- | --- | --- |
    | Domains | `list_domains` | `create_domain`, `update_domain`, `set_domain_enabled`, `start_app`, `stop_app` |
    | Services | `service_status`, `health_check`, `app_status` | `start_service`, `stop_service`, `restart_service` |
    | Databases | `db_list`, `db_query` | `db_create`, `db_export`, `db_import` |
    | Logs | `read_log`, `read_domain_log` | — |
    | Sharing | `list_shares` | `start_share`, `stop_share` |

    **Sharing defaults to No access**, unlike the other scopes. Its tools put a local site
    on the public internet, so the user turns it on deliberately.

    Database work (queries, dumps, restores) has its own, more detailed skill:
    **`brampp_mysql`**. Read that one first for any task that touches a database — rules such
    as taking a backup before importing live there.

    ## Tools

    ### `list_domains`
    Returns every registered domain (name, platform, web server, port, enabled/running, SSL).
    Takes no arguments. — *Domains: read*

    > Example: "List the domains in BRAMPP" → `list_domains`

    ### `create_domain`
    Creates a domain: site folder, vhost, SSL certificate and `/etc/hosts` entry.
    — *Domains: write*

    | Argument | Type | Description |
    | --- | --- | --- |
    | `name` | string | **Required.** e.g. `myapp.test` |
    | `platform` | string | `php` (default), `nodejs`, `python`, `dotnet`, `static` |
    | `web_server` | string | `apache` (default), `nginx` |
    | `port` | integer | Backend port (nodejs/python/dotnet); a free one is assigned if omitted |
    | `ssl` | boolean | Default `true` |

    > Example: `{"name": "api.test", "platform": "nodejs", "web_server": "nginx"}`

    ### `set_domain_enabled`
    Enables or disables a domain. While disabled the record and site files are kept; only the
    vhost and hosts entry are removed. — *Domains: write*

    | Argument | Type | Description |
    | --- | --- | --- |
    | `name` | string | **Required.** Domain name |
    | `enabled` | boolean | **Required.** `true`/`false` |

    > Example: `{"name": "api.test", "enabled": false}`

    ### `service_status`
    Returns the status of every service (`id`, name, state, port, version). No arguments.
    — *Services: read*

    > Example: "Is MariaDB running?" → `service_status`

    ### `start_service`
    Starts a brew service. — *Services: write*

    | Argument | Type | Description |
    | --- | --- | --- |
    | `id` | string | **Required.** e.g. `httpd`, `nginx`, `mariadb`, `php@8.3`, `redis` |

    > Example: `{"id": "mariadb"}`

    ### `stop_service`
    Stops a brew service. Same argument as `start_service`. — *Services: write*

    > Example: `{"id": "nginx"}`

    Note: start/stop are asynchronous — call `service_status` a few seconds later to confirm
    the result.

    ### `read_log`
    Returns the most recent lines from the BRAMPP console (for debugging). — *Logs: read*

    | Argument | Type | Description |
    | --- | --- | --- |
    | `lines` | integer | Default 50, max 500 |
    | `level` | string | `all` (default), `error`, `warning`. `warning` includes errors |
    | `search` | string | Keep only lines containing this text (case-insensitive) |
    | `since_minutes` | integer | Keep only the last N minutes |
    | `source` | string | `memory` (default) or `file` |

    > Example: `{"lines": 100}` · `{"level": "error", "since_minutes": 15}`

    `memory` is the live buffer — the last ~300 lines, which a noisy `brew install` can sweep
    away on its own. `file` reads the daily log on disk and is the only way to see anything
    older, including lines from before the app was last restarted. Reach for `file` whenever
    the question is "what happened earlier"; the buffer probably no longer holds it.

    If `file` reports an empty log, disk logging is switched off in
    **Settings → Console → Save the console to disk**.

    ### `read_domain_log`
    Reads a domain's web server error/access log, or (for nodejs/python/dotnet) its
    application log. — *Logs: read*

    | Argument | Type | Description |
    | --- | --- | --- |
    | `name` | string | **Required.** Domain name |

    ### `list_shares`
    Lists the Cloudflare tunnels that are open right now, with their public addresses.
    — *Sharing: read*

    ### `start_share`
    Opens a Cloudflare Quick Tunnel for a domain and returns a **public**
    `https://<random>.trycloudflare.com` address. — *Sharing: write*

    | Argument | Type | Description |
    | --- | --- | --- |
    | `name` | string | **Required.** Domain name |

    **Do not call this unless the user asked for it.** It takes a site that was reachable only
    on this machine and puts it on the open internet: anyone holding the address can browse it,
    and if the site has no authentication — as local development sites usually do not — they
    can read its data too. There is no password on the tunnel itself.

    Before calling it, say plainly what will become public and get a yes. Afterwards, give the
    user the address and remind them it stays open until `stop_share`, or until BRAMPP quits.

    ### `stop_share`
    Closes the domain's tunnel; the public address dies immediately. — *Sharing: write*

    | Argument | Type | Description |
    | --- | --- | --- |
    | `name` | string | **Required.** Domain name |

    ### Database tools
    `db_list`, `db_query`, `db_create`, `db_export`, `db_import` — see the **`brampp_mysql`**
    skill for full argument tables, safety rules and workflows.

    ## Testing sites: use HTTPS

    BRAMPP issues a local SSL certificate for every domain and installs it into the system
    trust store. When you check a site in a browser or with `curl`, use **the domain's HTTPS
    address**:

    - Right: `https://myapp.test` — Apache; `https://myapp.test:8443` — Nginx
    - Wrong: `http://127.0.0.1:3001` (the app's backend port — that is behind the reverse
      proxy and skips both the real request path and SSL)

    Hitting the backend port directly does not test what the user actually sees: vhost
    rewrites, headers and the certificate are all out of the picture. The correct URL for
    each domain is in the `url` field of the `list_domains` response — use that.

    ## Notes

    - If your tool list is shorter than this document, the missing tools were **filtered out
      by permissions**: point the user to **Settings → MCP → Access Permissions**.
    - `create_domain` and `set_domain_enabled` write to `/etc/hosts`; that step **may ask for
      an administrator password inside the app**. If it is declined the domain is still
      created — only the hosts entry is missing — so tell the user to check the BRAMPP window.
    - Every change goes through the live managers; the BRAMPP window updates instantly.
    - If the database tools cannot reach MariaDB, start it first with `start_service`.
    - When something fails, the detailed reason is usually in the console: check `read_log`.
      (If the Logs scope is *No access*, that tool will not be visible either.)

    """
}
