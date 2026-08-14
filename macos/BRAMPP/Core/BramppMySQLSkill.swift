import Foundation

/// "brampp_mysql" becerisinin metni — BRAMPP'in veritabanı MCP araçlarını anlatır.
///
/// İçerik depodaki `.claude/skills/brampp_mysql/SKILL.md` ile BİREBİR aynıdır; ikisinin
/// ayrışmadığı birim testiyle güvence altına alınır. Metni burada değiştirirsen depo
/// kopyasını da güncelle (ya da tersi) — test aksi hâlde kırılır.
///
/// NOT: Kapanış `"""` satırından ÖNCEKİ satır sonu Swift tarafından yutulur; dosyanın
/// sondaki `\n` karakteri korunsun diye literal fazladan bir satır sonuyla biter.
enum BramppMySQLSkill {

    static let name = "brampp_mysql"

    /// Şablondaki port yer tutucusu — kurulumda gerçek portla değiştirilir.
    static let portPlaceholder = MCPToolsSkill.portPlaceholder

    static let defaultPort = MCPToolsSkill.defaultPort

    static func rendered(port: Int) -> String {
        markdown.replacingOccurrences(of: portPlaceholder, with: String(port))
    }

    /// SKILL.md şablonu (ön madde dahil). Yazmadan önce `rendered(port:)`'ten geçir.
    static let markdown = """
    ---
    name: brampp_mysql
    description: Read and write MariaDB/MySQL and PostgreSQL through BRAMPP's MCP server — inspect schemas, run SELECT/INSERT/UPDATE, dump and restore; use for any BRAMPP task that touches a database
    ---

    # BRAMPP — Database Tools

    BRAMPP publishes an MCP server from inside the running app. These tools call the app's
    LIVE managers; every change shows up in the BRAMPP window immediately.

    - **Endpoint:** `http://127.0.0.1:{{PORT}}/mcp` (loopback only, JSON-RPC 2.0 over `POST`)
    - **Enable it:** BRAMPP → Settings → MCP → turn the switch on

    **Use these tools instead of the shell.** Do not reach for `mysql`, `mysqldump`, `psql`, or
    a PHP script to do something a tool here already does. The shell bypasses the permission
    model the user configured, produces output you then have to parse, and leaves no trace in
    the BRAMPP console. If a tool you need is missing, that is a permission setting to raise —
    not a reason to shell out.

    For domains, services and logs see the `mcptools` skill. This document covers the
    **Databases** scope only.

    ## Start here: look before you query

    You cannot write a correct query against a schema you have not read. The order is always
    the same, and each step is one tool call:

    1. **`db_list`** — which databases exist? Never guess a name.
    2. **`db_tables`** — which tables are in it, and how many rows?
    3. **`db_describe`** — what columns does the table have, what types, which is the key?
    4. **`db_query`** — now write the statement.

    Skipping to step 4 is where things go wrong: a column that does not exist, a name that is
    plural in one table and singular in another, a `status` column that turns out to be an
    `ENUM` and not a string. Two cheap reads prevent a wrong write.

    ## Permissions

    Every tool here belongs to the **Databases** scope, set in Settings to
    **No access / Read / Read + write**.

    | Tool | Needs |
    | --- | --- |
    | `db_list`, `db_tables`, `db_describe` | Read |
    | `db_query` — `SELECT`, `SHOW`, `DESCRIBE`, `EXPLAIN` | Read |
    | `db_query` — `INSERT`, `UPDATE`, `REPLACE` (`allow_write`) | Read + write |
    | `db_query` — `DELETE`, `DROP`, `TRUNCATE`, `ALTER`, `CREATE` (`allow_write` **and** `allow_destructive`) | Read + write |
    | `db_create`, `db_export`, `db_import` | Read + write |

    A tool that is not permitted **never appears** in `tools/list`; if called anyway it is
    refused. When a tool you should have is missing, **the problem is the settings, not you**:
    ask the user to open **Settings → MCP → Access Permissions** and raise the Databases scope.

    `db_export` looks read-only and is not: it writes the whole database to a file on disk.

    ## Writing data: three levels, on purpose

    `db_query` is read-only by default. Writing is opened in two steps, because updating a row
    and dropping a table are not the same request and must not share a switch.

    **Level 1 — read.** No flags. `SELECT`, `SHOW`, `DESCRIBE`, `EXPLAIN`, `WITH`.

    **Level 2 — `allow_write: true`.** `INSERT`, `UPDATE`, `REPLACE`, `MERGE`. Changes rows in
    existing tables. This is the level for ordinary work: seeding a table, fixing a value,
    flipping a flag.

    ```json
    {"sql": "UPDATE users SET is_active = 1 WHERE id = 42",
     "database": "shop", "allow_write": true}
    ```

    **Level 3 — `allow_write: true` **and** `allow_destructive: true`.** `DELETE`, `DROP`,
    `TRUNCATE`, `ALTER`, `CREATE`, `GRANT`. Can lose data or schema.

    ```json
    {"sql": "DELETE FROM sessions WHERE created_at < '2026-01-01'",
     "database": "shop", "allow_write": true, "allow_destructive": true}
    ```

    Sending only `allow_write` for a level-3 statement is refused with a message naming the
    keyword. That refusal is the design working — do not retry by adding flags without
    telling the user what you are about to do.

    Two rules the server enforces and you should not try to route around:

    - **One statement per call.** `"UPDATE a SET x=1; DROP TABLE b"` is rejected at every
      level. Multiple operations mean multiple calls, so each is checked on its own.
    - **No filesystem access from SQL.** `LOAD_FILE`, `INTO OUTFILE`, `pg_read_file`,
      `lo_import`, `pg_ls_*` are refused regardless of flags. Write permission on a database
      is not permission to read the disk.

    ## Tools

    ### `db_list` — *Read*
    Lists databases.

    | Argument | Type | Description |
    | --- | --- | --- |
    | `engine` | string | `mysql` (default) or `postgres` |

    ### `db_tables` — *Read*
    Lists a database's tables with row counts, approximate size and storage engine.

    | Argument | Type | Description |
    | --- | --- | --- |
    | `database` | string | **Required.** From `db_list` |
    | `engine` | string | `mysql` (default) or `postgres` |
    | `max_rows` | integer | Default 500 |

    Row counts on InnoDB are the optimiser's estimate, not exact. For an exact number use
    `SELECT COUNT(*)`. The estimate is fine for "is this table empty or huge?".

    ### `db_describe` — *Read*
    Returns a table's columns in order: name, type, nullability, key, default, extra.

    | Argument | Type | Description |
    | --- | --- | --- |
    | `database` | string | **Required.** |
    | `table` | string | **Required.** From `db_tables` |
    | `engine` | string | `mysql` (default) or `postgres` |

    Read this before writing any `INSERT` or `UPDATE`. It tells you which columns are
    `NOT NULL` without a default (you must supply them), which is `auto_increment` (do not
    supply it), and the exact `ENUM` values a status column accepts.

    ### `db_query` — *Read; writes need flags, see above*
    Runs a single SQL statement.

    | Argument | Type | Description |
    | --- | --- | --- |
    | `sql` | string | **Required.** One statement |
    | `database` | string | Database to connect to |
    | `engine` | string | `mysql` (default) or `postgres` |
    | `allow_write` | boolean | Permit `INSERT`/`UPDATE`/`REPLACE` — default `false` |
    | `allow_destructive` | boolean | Permit `DELETE`/`DROP`/`TRUNCATE`/`ALTER`/`CREATE` — default `false`, requires `allow_write` too |
    | `max_rows` | integer | Default 100, max 1000 |

    Without `allow_write` the session is additionally opened `READ ONLY` at the engine, so a
    statement that somehow slipped past the text check still cannot write.

    ### `db_create` — *Write*
    Creates a database; **leaves an existing one alone**.

    | Argument | Type | Description |
    | --- | --- | --- |
    | `name` | string | **Required.** Letters, digits and underscores only |
    | `engine` | string | `mysql` (default) or `postgres` |

    ### `db_export` — *Write*
    Dumps a database to `.sql`.

    | Argument | Type | Description |
    | --- | --- | --- |
    | `name` | string | **Required.** |
    | `engine` | string | `mysql` (default) or `postgres` |
    | `path` | string | **Absolute**, must end in `.sql`. Defaults to `~/Library/Application Support/BRAMPP/backups/<name>-<timestamp>.sql` |

    MariaDB/MySQL uses `mysqldump --single-transaction --routines --triggers`: a consistent
    snapshot without locking InnoDB tables, keeping routines and triggers. PostgreSQL uses
    `pg_dump`. The format is standard — the file restores without BRAMPP.

    It **will not overwrite** an existing file, and if the dump fails the partial file is
    **deleted**: a corrupt backup is worse than none.

    ### `db_import` — *Write, DESTRUCTIVE*
    Applies a `.sql` dump to a target database.

    | Argument | Type | Description |
    | --- | --- | --- |
    | `name` | string | **Required.** Target database |
    | `path` | string | **Required.** Absolute path of the `.sql` file |
    | `engine` | string | `mysql` (default) or `postgres` |
    | `create_if_missing` | boolean | Create the target if absent — default `true` |

    ## Worked example

    *"Mark every order older than a year as archived."*

    ```
    db_list                      → shop exists
    db_tables  database=shop     → orders (48,201 rows), order_items, customers
    db_describe database=shop table=orders
                                 → id int PK auto_increment
                                   status enum('new','paid','shipped','archived') NOT NULL
                                   created_at datetime NOT NULL
    ```

    Now you know `status` is an `ENUM` and `'archived'` is a legal value — a guess of
    `'ARCHIVED'` or `'archive'` would have failed or, worse, silently stored an empty string
    on a non-strict server.

    ```
    db_query database=shop
      sql="SELECT COUNT(*) FROM orders WHERE created_at < NOW() - INTERVAL 1 YEAR"
                                 → 12,847
    ```

    Count first. Now the user knows the size of the change before it happens — tell them, then:

    ```
    db_query database=shop allow_write=true
      sql="UPDATE orders SET status='archived' WHERE created_at < NOW() - INTERVAL 1 YEAR"
    ```

    `UPDATE` needs only `allow_write`. If the task had been `DELETE`, it would also need
    `allow_destructive` — and a backup first.

    ## Working rules

    **Count before you change.** Run the `SELECT COUNT(*)` with the same `WHERE` clause before
    an `UPDATE` or `DELETE`, and tell the user the number. "This affects 12,847 rows" is
    information they can act on; "done" after the fact is not.

    **Back up before you import.** Dumps usually contain `DROP TABLE` / `CREATE TABLE`; if the
    target holds data it changes irreversibly. The order is:

    1. `db_list` — does the target exist, is the name right?
    2. `db_export` — back up its current state
    3. `db_import` — apply the dump
    4. `db_query` — verify with `SELECT COUNT(*)`

    If the target has data, **ask first** even when the user did not mention a backup.

    **Confirm data loss in one sentence.** Before `DROP`, `TRUNCATE`, or a `DELETE`/`UPDATE`
    with no `WHERE`, say what you are about to do and get approval. Having the permission does
    not mean every write is wanted.

    **Do not invent names.** Never guess a database, table or column name — `db_list`,
    `db_tables` and `db_describe` cost one call each and are always right.

    **Path format.** `path` must be absolute, end in `.sql`, and contain no shell
    metacharacters. Relative paths are rejected; `~` is expanded.

    ## Testing sites: use HTTPS

    BRAMPP issues a local SSL certificate for every domain and installs it into the system
    trust store. When checking a site, use **the domain's HTTPS address**:

    - Right: `https://myapp.test` — Apache; `https://myapp.test:8443` — Nginx
    - Wrong: `http://127.0.0.1:3001` — the backend port, behind the reverse proxy; it skips
      the real request path and SSL

    `list_domains` (in the `mcptools` skill) returns the correct URL for each domain.

    ## Troubleshooting

    **"Is the database running?"** — MariaDB may be stopped. Check `service_status` from the
    `mcptools` skill and start `mariadb` with `start_service`.

    **A statement was refused and you believe it is read-only.** Read the message: it names the
    keyword that triggered it. `SHOW CREATE TABLE` and `SHOW CHARACTER SET` are allowed even
    though they contain `CREATE` and `SET`. If a genuinely read-only statement is refused,
    report it rather than adding `allow_write` — that flag would hide the problem, not fix it.

    **PostgreSQL port** — several versions may be installed; the tools pick the RUNNING one. An
    unexpected database list usually means a different version is up: confirm with
    `service_status`.

    **Connection identity** — Homebrew MariaDB uses `unix_socket` authentication; the tools try
    `root` first, then the logged-in user. If neither works the problem is MariaDB's
    configuration rather than BRAMPP — point the user at the TCP note on the Database tab.

    **Detailed errors** — when an operation fails the reason is usually in the BRAMPP console:
    check `read_log` from the `mcptools` skill. (If the Logs scope is *No access*, that tool
    will not be visible.)

    """
}
