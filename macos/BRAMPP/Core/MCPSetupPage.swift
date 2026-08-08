import Foundation

/// `GET http://127.0.0.1:<port>/mcp` adresi bir tarayıcıda açıldığında gösterilen
/// karşılama + kurulum sayfası. MCP istemcileri bu adrese `POST` atar; tarayıcıdan
/// gelen (Accept: text/html) istekler buraya yönlendirilir.
///
/// Sayfa TAMAMEN kendi kendine yeter: dış CSS/JS/font/görsel isteği YOKTUR
/// (loopback'te, internet olmadan da çalışmalıdır). İki dil aynı belgede taşınır;
/// üstteki TR/EN düğmesi yalnızca görünürlüğü değiştirir. İstemci sekmeleri de
/// saf CSS'tir (gizli radio + `:checked ~` kardeş seçicisi) — JS gerektirmez.
enum MCPSetupPage {

    static func html(port: Int, toolNames: [String], languageCode: String) -> String {
        let startLang = languageCode == "tr" ? "tr" : "en"
        let endpoint  = "http://127.0.0.1:\(port)/mcp"

        // Claude Code: HTTP uç noktasını doğrudan tanır
        let mcpJSON = """
        {
          "mcpServers": {
            "brampp": {
              "type": "http",
              "url": "\(endpoint)"
            }
          }
        }
        """

        // Claude Desktop: yapılandırma şeması YALNIZCA stdio (command) girişlerini kabul
        // eder; "type": "http" girişi sessizce elenir ("Skipped invalid MCP server config
        // entries"). Bu yüzden mcp-remote köprüsü (stdio ↔ StreamableHTTP) kullanılır.
        let desktopJSON = """
        {
          "mcpServers": {
            "brampp": {
              "command": "npx",
              "args": ["-y", "mcp-remote", "\(endpoint)", "--allow-http"]
            }
          }
        }
        """

        // ChatGPT Codex: Streamable HTTP'yi DOĞRUDAN destekler — köprü gerekmez.
        // Şemada ayrı bir "transport" anahtarı YOKTUR; `url` verilmesi HTTP demektir.
        let codexTOML = """
        [mcp_servers.brampp]
        url = "\(endpoint)"
        """

        let skillFrontMatter = """
        ---
        name: mcptools
        description: BRAMPP MCP araçlarıyla yerel geliştirme ortamını (alan adları,
          servisler, veritabanları, loglar) yönetir
        ---
        """

        let curlCmd = "curl -s -X POST \(endpoint) \\\n  -H 'Content-Type: application/json' \\\n  -d '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}'"

        let toolCards = toolNames.map { name in
            "<div class=\"tool\"><code>\(escape(name))</code></div>"
        }.joined()

        return """
        <!doctype html>
        <html lang="\(startLang)">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="robots" content="noindex">
        <title>BRAMPP MCP</title>
        <style>
        :root{--bg:#0b1526;--bg2:#122540;--fg:#e8eef7;--muted:#9db1c9;--amber:#f59e0b;
              --amber2:#d97706;--card:#13233c;--line:#1e3557;--green:#34d399}
        *{box-sizing:border-box;margin:0;padding:0}
        body{font:16px/1.65 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;
             background:linear-gradient(180deg,var(--bg) 0%,var(--bg2) 100%);
             color:var(--fg);min-height:100vh;padding:0 20px 60px}
        .wrap{max-width:860px;margin:0 auto}
        header{padding:56px 0 30px;text-align:center;position:relative}
        .langbar{position:absolute;top:18px;right:0;display:flex;gap:6px}
        .langbar button{background:transparent;border:1px solid #2e4664;color:var(--muted);
             border-radius:8px;padding:5px 12px;font:600 13px/1 inherit;cursor:pointer}
        .langbar button.on{border-color:var(--amber);color:var(--amber)}
        h1{font-size:38px;letter-spacing:1px;margin:16px 0 6px}
        h1 span{color:var(--amber)}
        .sub{color:var(--muted);font-size:17px}
        .badge{display:inline-flex;align-items:center;gap:8px;margin-top:18px;
             background:rgba(52,211,153,.12);border:1px solid rgba(52,211,153,.35);
             color:var(--green);border-radius:999px;padding:6px 14px;font-size:14px;font-weight:600}
        .dot{width:9px;height:9px;border-radius:50%;background:var(--green)}
        .endpoint{margin:22px auto 0;max-width:560px;display:flex;gap:10px;align-items:center;
             background:#0a1424;border:1px solid var(--line);border-radius:12px;padding:12px 14px}
        .endpoint code{flex:1;font-size:15px;color:var(--amber);word-break:break-all;text-align:left}
        button.copy{background:linear-gradient(135deg,var(--amber2),var(--amber));color:#1a1206;
             border:0;border-radius:9px;padding:8px 14px;font:600 13px/1 inherit;cursor:pointer;
             white-space:nowrap}
        button.copy:active{transform:translateY(1px)}
        section{padding:26px 0}
        h2{font-size:22px;margin-bottom:14px}
        h2 em{font-style:normal;color:var(--amber);margin-right:10px;font-variant-numeric:tabular-nums}
        h3{font-size:17px;margin-bottom:10px}
        h3 b{color:var(--amber);font-weight:600}
        .card{background:var(--card);border:1px solid var(--line);border-radius:16px;padding:22px;margin-bottom:16px}
        .card p{color:var(--muted);font-size:15px}
        .card p + p{margin-top:8px}
        pre{background:#0a1424;border:1px solid var(--line);border-radius:12px;padding:14px 16px;
             overflow-x:auto;margin:12px 0 0;position:relative}
        pre code{font:13.5px/1.6 ui-monospace,SFMono-Regular,Menlo,monospace;color:#cfe3ff;white-space:pre}
        .pretop{display:flex;justify-content:space-between;align-items:center;gap:12px;margin-top:12px}
        .path{font:12.5px/1 ui-monospace,SFMono-Regular,Menlo,monospace;color:var(--amber);word-break:break-all}
        .tools{display:flex;flex-wrap:wrap;gap:8px;margin-top:6px}
        .tool{background:#0a1424;border:1px solid var(--line);border-radius:9px;padding:7px 12px}
        .tool code{font:13px/1 ui-monospace,SFMono-Regular,Menlo,monospace;color:var(--fg)}
        .note{border-left:3px solid var(--amber);padding-left:14px;color:var(--muted);font-size:14.5px}
        .oneclick{margin-top:16px;border-left:3px solid var(--green);padding-left:14px;
             color:var(--muted);font-size:14.5px}
        .oneclick b{color:var(--green)}
        .perm{display:grid;grid-template-columns:repeat(auto-fit,minmax(180px,1fr));gap:10px;margin-top:6px}
        /* flex sütun: dil anahtarı (display:revert) strong/span'i satır içine düşürmesin */
        .perm div{background:#0a1424;border:1px solid var(--line);border-radius:11px;padding:12px 14px;
             display:flex;flex-direction:column}
        .perm strong{font-size:14.5px;margin-bottom:3px}
        .perm span{color:var(--muted);font-size:13px}
        .levels{display:flex;flex-wrap:wrap;gap:8px;margin-top:14px}
        .lvl{border:1px solid var(--line);border-radius:999px;padding:5px 13px;font-size:13.5px;color:var(--muted)}
        .lvl.on{border-color:var(--amber);color:var(--amber)}
        /* İstemci sekmeleri — saf CSS: gizli radio + kardeş seçici */
        .clients{position:relative}
        .clients > input{position:absolute;width:1px;height:1px;opacity:0;margin:0}
        .tabbar{display:grid;grid-template-columns:repeat(3,1fr);gap:10px;margin-bottom:18px}
        .tabbar label{display:block;text-align:center;cursor:pointer;user-select:none;
             background:var(--card);border:1px solid var(--line);border-radius:14px;
             padding:13px 10px;color:var(--muted);font-weight:600;font-size:15px}
        .tabbar label small{display:block;margin-top:4px;font-weight:500;opacity:.75;
             font:500 12px/1.4 ui-monospace,SFMono-Regular,Menlo,monospace}
        .tabbar label:hover{border-color:#2e4664;color:var(--fg)}
        .panel{display:none}
        #t1:checked ~ #p1,#t2:checked ~ #p2,#t3:checked ~ #p3{display:block}
        #t1:checked ~ .tabbar label[for="t1"],
        #t2:checked ~ .tabbar label[for="t2"],
        #t3:checked ~ .tabbar label[for="t3"]{border-color:var(--amber);color:var(--amber);
             background:rgba(245,158,11,.10)}
        #t1:focus-visible ~ .tabbar label[for="t1"],
        #t2:focus-visible ~ .tabbar label[for="t2"],
        #t3:focus-visible ~ .tabbar label[for="t3"]{outline:2px solid var(--amber);outline-offset:2px}
        footer{text-align:center;color:var(--muted);font-size:13.5px;padding-top:20px;border-top:1px solid var(--line)}
        footer a{color:var(--amber)}
        [data-lang]{display:none}
        html[lang="tr"] [data-lang="tr"],html[lang="en"] [data-lang="en"]{display:revert}
        @media(max-width:600px){h1{font-size:30px}.endpoint{flex-direction:column;align-items:stretch}
             .endpoint code{text-align:center}.tabbar{grid-template-columns:1fr}
             .pretop{flex-direction:column;align-items:stretch;gap:8px}}
        </style>
        </head>
        <body>
        <div class="wrap">

        <header>
          <div class="langbar">
            <button id="btr" onclick="setLang('tr')">TR</button>
            <button id="ben" onclick="setLang('en')">EN</button>
          </div>
          <svg width="66" height="66" viewBox="0 0 64 64" aria-hidden="true">
            <rect x="10" y="12" width="44" height="12" rx="3" fill="none" stroke="#f59e0b" stroke-width="3"/>
            <rect x="10" y="26" width="44" height="12" rx="3" fill="none" stroke="#f59e0b" stroke-width="3"/>
            <rect x="10" y="40" width="44" height="12" rx="3" fill="none" stroke="#f59e0b" stroke-width="3"/>
            <circle cx="18" cy="18" r="2.4" fill="#34d399"/>
            <circle cx="18" cy="32" r="2.4" fill="#34d399"/>
            <circle cx="18" cy="46" r="2.4" fill="#34d399"/>
          </svg>
          <h1>BRA<span>MPP</span> MCP</h1>
          <p class="sub" data-lang="tr">Yapay zekâ araçları için yerel uç nokta</p>
          <p class="sub" data-lang="en">Local endpoint for AI tools</p>
          <div class="badge"><span class="dot"></span>
            <span data-lang="tr">Sunucu çalışıyor</span><span data-lang="en">Server running</span>
          </div>
          <div class="endpoint">
            <code id="ep">\(escape(endpoint))</code>
            <button class="copy" onclick="copyText(document.getElementById('ep').textContent,this)">
              <span data-lang="tr">Kopyala</span><span data-lang="en">Copy</span>
            </button>
          </div>
        </header>

        <section>
          <div class="card">
            <p data-lang="tr"><b>Bu sayfa neden görünüyor?</b> Bu adres bir MCP (Model Context Protocol)
            uç noktasıdır — tarayıcı için değil, Claude ve ChatGPT Codex gibi yapay zekâ istemcileri
            içindir. İstemciler buraya <code>POST</code> ile JSON-RPC istekleri gönderir. Aşağıdaki
            adımlar istemcinizi BRAMPP'e bağlar; bağlandıktan sonra istemci alan adı kurabilir,
            servisleri yönetebilir ve veritabanı oluşturabilir — yapılan her değişiklik BRAMPP
            arayüzüne anında yansır.</p>
            <p data-lang="en"><b>Why am I seeing this page?</b> This address is an MCP (Model Context
            Protocol) endpoint — meant for AI clients like Claude and ChatGPT Codex, not for browsers.
            Clients send JSON-RPC requests here via <code>POST</code>. The steps below connect your
            client to BRAMPP; once connected, it can create domains, control services and create
            databases — every change shows up in the BRAMPP window instantly.</p>
          </div>
        </section>

        <section>
          <h2><em>1</em><span data-lang="tr">Hangi istemciyi kullanıyorsunuz?</span><span data-lang="en">Which client are you using?</span></h2>
          <p class="sub" style="font-size:15px;margin-bottom:16px" data-lang="tr">Bir sekme seçin — her istemcinin
          yapılandırma dosyası ve biçimi farklıdır.</p>
          <p class="sub" style="font-size:15px;margin-bottom:16px" data-lang="en">Pick a tab — each client has its own
          config file and format.</p>

          <div class="clients">
            <input type="radio" name="client" id="t1" checked>
            <input type="radio" name="client" id="t2">
            <input type="radio" name="client" id="t3">

            <div class="tabbar">
              <label for="t1">Claude Code<small>.mcp.json</small></label>
              <label for="t2">Claude Desktop<small>claude_desktop_config.json</small></label>
              <label for="t3">ChatGPT Codex<small>config.toml</small></label>
            </div>

            <!-- 1) Claude Code -->
            <div class="panel" id="p1">
              <div class="card">
                <h3><b>Claude Code</b> <span data-lang="tr">— proje bazlı bağlama</span><span data-lang="en">— per-project setup</span></h3>
                <p data-lang="tr">Claude Code, Streamable HTTP uç noktasını doğrudan tanır. Projenizin kök
                dizinine <span class="path">.mcp.json</span> dosyasını ekleyin:</p>
                <p data-lang="en">Claude Code speaks Streamable HTTP directly. Add an
                <span class="path">.mcp.json</span> file to your project root:</p>
                <div class="pretop">
                  <span class="path">.mcp.json</span>
                  <button class="copy" onclick="copyPre('c1',this)">
                    <span data-lang="tr">Kopyala</span><span data-lang="en">Copy</span>
                  </button>
                </div>
                <pre><code id="c1">\(escape(mcpJSON))</code></pre>
                <p data-lang="tr" style="margin-top:12px">Dosyayı kaydedin, Claude Code'u yeniden başlatın ve
                açılışta sorulan sunucu onayını verin. Ardından <code>/mcp</code> komutuyla bağlantıyı
                doğrulayabilirsiniz.</p>
                <p data-lang="en" style="margin-top:12px">Save the file, restart Claude Code and approve the
                server when prompted at startup. Then verify the connection with <code>/mcp</code>.</p>
                <p class="oneclick" data-lang="tr"><b>Tek tıkla:</b> <span class="path">.mcp.json</span> projenize
                özel olduğu için elle eklenir; beceri dosyası ve diğer istemcilerin yapılandırması
                <b>BRAMPP → Ayarlar → MCP → Claude Entegrasyonu</b> bölümünden tek tıkla kurulabilir —
                mevcut dosya önce yedeklenir.</p>
                <p class="oneclick" data-lang="en"><b>One click:</b> <span class="path">.mcp.json</span> is
                specific to your project, so you add it by hand; the skill file and the other clients'
                configuration can be installed with a single click from
                <b>BRAMPP → Settings → MCP → Claude Integration</b> — the existing file is backed up first.</p>
              </div>
            </div>

            <!-- 2) Claude Desktop -->
            <div class="panel" id="p2">
              <div class="card">
                <h3><b>Claude Desktop</b> <span data-lang="tr">— mcp-remote köprüsü</span><span data-lang="en">— mcp-remote bridge</span></h3>
                <p data-lang="tr">Claude Desktop yapılandırma dosyası <b>yalnızca komut (stdio) tipi
                sunucuları</b> kabul eder — <code>type: http</code> girişi sessizce elenir. Bu yüzden
                <code>mcp-remote</code> köprüsü kullanılır (Node.js gerektirir):</p>
                <p data-lang="en">The Claude Desktop config file only accepts <b>command (stdio) servers</b> —
                a <code>type: http</code> entry is silently dropped. Use the <code>mcp-remote</code> bridge
                instead (requires Node.js):</p>
                <div class="pretop">
                  <span class="path">~/Library/Application Support/Claude/claude_desktop_config.json</span>
                  <button class="copy" onclick="copyPre('c2',this)">
                    <span data-lang="tr">Kopyala</span><span data-lang="en">Copy</span>
                  </button>
                </div>
                <pre><code id="c2">\(escape(desktopJSON))</code></pre>
                <p data-lang="tr" style="margin-top:12px">Değişiklik Claude Desktop yeniden başlatıldığında
                etkinleşir. <code>npx</code> PATH'te bulunamazsa tam yolunu yazın
                (<code>which npx</code> ile öğrenebilirsiniz).</p>
                <p data-lang="en" style="margin-top:12px">The change takes effect after restarting Claude
                Desktop. If <code>npx</code> is not on the PATH, use its absolute path (find it with
                <code>which npx</code>).</p>
                <p class="oneclick" data-lang="tr"><b>Tek tıkla:</b> Bu yapılandırma
                <b>BRAMPP → Ayarlar → MCP → Claude Entegrasyonu</b> bölümünden tek tıkla eklenebilir —
                mevcut dosya önce yedeklenir.</p>
                <p class="oneclick" data-lang="en"><b>One click:</b> This configuration can be added with a
                single click from <b>BRAMPP → Settings → MCP → Claude Integration</b> — the existing file is
                backed up first.</p>
              </div>
            </div>

            <!-- 3) ChatGPT Codex -->
            <div class="panel" id="p3">
              <div class="card">
                <h3><b>ChatGPT Codex</b> <span data-lang="tr">— köprü gerekmez</span><span data-lang="en">— no bridge needed</span></h3>
                <p data-lang="tr">Codex, Streamable HTTP taşımasını <b>doğrudan destekler</b>; ayrı bir köprüye
                (mcp-remote) gerek YOKTUR. Yapılandırmaya <code>url</code> yazmanız yeterlidir — ayrı bir
                taşıma (transport) anahtarı yoktur:</p>
                <p data-lang="en">Codex supports the Streamable HTTP transport <b>natively</b>; no bridge
                (mcp-remote) is needed. Just add a <code>url</code> entry — there is no separate transport
                key:</p>
                <div class="pretop">
                  <span class="path">~/.codex/config.toml</span>
                  <button class="copy" onclick="copyPre('c3',this)">
                    <span data-lang="tr">Kopyala</span><span data-lang="en">Copy</span>
                  </button>
                </div>
                <pre><code id="c3">\(escape(codexTOML))</code></pre>
                <p data-lang="tr" style="margin-top:12px">Yalnızca tek bir proje için geçerli olmasını
                isterseniz aynı bloğu proje kökündeki <span class="path">.codex/config.toml</span> dosyasına
                yazabilirsiniz. Codex, talimatları <span class="path">AGENTS.md</span> üzerinden okur —
                aşağıdaki beceri bölümüne bakın.</p>
                <p data-lang="en" style="margin-top:12px">To scope it to a single project, put the same block
                in <span class="path">.codex/config.toml</span> at the project root. Codex reads its
                instructions from <span class="path">AGENTS.md</span> — see the skill section below.</p>
                <p class="oneclick" data-lang="tr"><b>Tek tıkla:</b> Bu yapılandırma
                <b>BRAMPP → Ayarlar → MCP → Claude Entegrasyonu</b> bölümünden tek tıkla eklenebilir —
                mevcut dosya önce yedeklenir.</p>
                <p class="oneclick" data-lang="en"><b>One click:</b> This configuration can be added with a
                single click from <b>BRAMPP → Settings → MCP → Claude Integration</b> — the existing file is
                backed up first.</p>
              </div>
            </div>
          </div>
        </section>

        <section>
          <h2><em>2</em><span data-lang="tr">Beceri dosyası — önerilir</span><span data-lang="en">Skill file — recommended</span></h2>
          <div class="card">
            <p data-lang="tr">Beceri dosyası istemciye araçları <b>ne zaman ve nasıl</b> kullanacağını anlatır:
            araç listesi, argümanlar, örnekler ve <code>/etc/hosts</code> gibi onay gerektiren adımlar.
            Bu dosya olmadan da araçlar çalışır, ama istemci doğru aracı seçmekte zorlanabilir.
            <b>İki beceri kurulur:</b> genel araçlar için <code>mcptools</code>, veritabanı işleri
            (sorgu, yedek alma, geri yükleme) için <code>brampp_mysql</code>. İkincisi içe aktarmadan
            önce yedek alma gibi kuralları da anlatır.</p>
            <p data-lang="en">The skill file tells the client <b>when and how</b> to use the tools: the tool
            list, arguments, examples and steps that need approval such as <code>/etc/hosts</code> edits.
            The tools work without it, but the client may struggle to pick the right one.
            <b>Two skills are installed:</b> <code>mcptools</code> for the general tools and
            <code>brampp_mysql</code> for database work (query, dump, restore) — the latter also covers
            rules such as taking a backup before importing.</p>

            <h3 style="margin-top:20px"><b>Claude</b> <span class="path">.claude/skills/mcptools/SKILL.md</span> · <span class="path">.claude/skills/brampp_mysql/SKILL.md</span></h3>
            <p data-lang="tr">Claude Code ve Claude Desktop beceri dosyalarını bu klasörden okur:</p>
            <p data-lang="en">Claude Code and Claude Desktop read skill files from this folder:</p>
            <div class="pretop">
              <span class="path">terminal</span>
              <button class="copy" onclick="copyPre('c4',this)">
                <span data-lang="tr">Kopyala</span><span data-lang="en">Copy</span>
              </button>
            </div>
            <pre><code id="c4">mkdir -p .claude/skills/mcptools</code></pre>
            <p data-lang="tr" style="margin-top:12px">Ardından BRAMPP deposundaki hazır
            <span class="path">SKILL.md</span> dosyasını bu klasöre kopyalayın. Dosyanın ön maddesi şöyledir:</p>
            <p data-lang="en" style="margin-top:12px">Then copy the ready-made
            <span class="path">SKILL.md</span> from the BRAMPP repository into that folder. Its front matter
            looks like this:</p>
            <pre><code>\(escape(skillFrontMatter))</code></pre>

            <h3 style="margin-top:22px"><b>ChatGPT Codex</b> <span class="path">AGENTS.md</span></h3>
            <p data-lang="tr">Codex'in beceri klasörü yoktur; talimatları proje kökündeki
            <span class="path">AGENTS.md</span> dosyasından okur. Aynı <span class="path">SKILL.md</span>
            içeriğini (ön madde olmadan) <span class="path">AGENTS.md</span> içine bir başlık altında
            yapıştırın — araç adları ve kullanım kuralları aynıdır.</p>
            <p data-lang="en">Codex has no skills folder; it reads its instructions from
            <span class="path">AGENTS.md</span> at the project root. Paste the same
            <span class="path">SKILL.md</span> content (without the front matter) into
            <span class="path">AGENTS.md</span> under a heading — the tool names and usage rules are identical.</p>
            <p class="oneclick" data-lang="tr"><b>Tek tıkla:</b> Beceri
            <b>BRAMPP → Ayarlar → MCP → Claude Entegrasyonu</b> bölümünden kurulabilir —
            mevcut dosya önce yedeklenir.</p>
            <p class="oneclick" data-lang="en"><b>One click:</b> The skill can be installed from
            <b>BRAMPP → Settings → MCP → Claude Integration</b> — the existing file is backed up first.</p>
          </div>
        </section>

        <section>
          <h2><em>3</em><span data-lang="tr">Erişim İzinleri</span><span data-lang="en">Access Permissions</span></h2>
          <div class="card">
            <p data-lang="tr">Yapay zekâ istemcisinin hangi araçları görebileceğine siz karar verirsiniz.
            <b>BRAMPP → Ayarlar → MCP → Erişim İzinleri</b> bölümünde dört alanın her birine ayrı bir düzey
            atanır:</p>
            <p data-lang="en">You decide which tools the AI client can see. Under
            <b>BRAMPP → Settings → MCP → Access Permissions</b> each of the four areas gets its own level:</p>
            <div class="perm">
              <div>
                <strong data-lang="tr">Alan Adları</strong><strong data-lang="en">Domains</strong>
                <span data-lang="tr">Listeleme, oluşturma, güncelleme, etkinleştirme, uygulama başlat/durdur</span>
                <span data-lang="en">List, create, update, enable/disable, start/stop apps</span>
              </div>
              <div>
                <strong data-lang="tr">Servisler</strong><strong data-lang="en">Services</strong>
                <span data-lang="tr">Durum sorgulama, başlatma, durdurma, yeniden başlatma</span>
                <span data-lang="en">Status, start, stop, restart</span>
              </div>
              <div>
                <strong data-lang="tr">Veritabanları</strong><strong data-lang="en">Databases</strong>
                <span data-lang="tr">Listeleme, oluşturma, sorgulama</span>
                <span data-lang="en">List, create, query</span>
              </div>
              <div>
                <strong data-lang="tr">Loglar</strong><strong data-lang="en">Logs</strong>
                <span data-lang="tr">BRAMPP konsolu ve alan adı logları (hata/erişim/uygulama)</span>
                <span data-lang="en">BRAMPP console and domain logs (error/access/app)</span>
              </div>
            </div>
            <div class="levels">
              <span class="lvl" data-lang="tr">İzin yok</span><span class="lvl" data-lang="en">No access</span>
              <span class="lvl on" data-lang="tr">Okuma</span><span class="lvl on" data-lang="en">Read</span>
              <span class="lvl on" data-lang="tr">Okuma + Yazma</span><span class="lvl on" data-lang="en">Read + Write</span>
            </div>
            <p class="note" style="margin-top:16px" data-lang="tr">İzin verilmeyen araçlar istemcide
            <b>hiç görünmez</b> — <code>tools/list</code> yanıtı süzülür. Bir istemci yine de o aracı çağırırsa
            <code>tools/call</code> isteği reddedilir. Örneğin Veritabanları alanı <b>Okuma</b> düzeyindeyken
            veritabanı oluşturma aracı listede yer almaz.</p>
            <p class="note" style="margin-top:16px" data-lang="en">Tools you do not allow <b>never appear</b>
            in the client — the <code>tools/list</code> response is filtered. If a client calls one anyway, the
            <code>tools/call</code> request is rejected. For example, with Databases set to <b>Read</b>, the
            create-database tool is not listed at all.</p>
          </div>
        </section>

        <section>
          <h2><em>4</em><span data-lang="tr">Doğrulama</span><span data-lang="en">Verify</span></h2>
          <div class="card">
            <p data-lang="tr">Sunucunun yanıt verdiğini terminalden doğrulayın:</p>
            <p data-lang="en">Confirm the server responds from your terminal:</p>
            <div class="pretop">
              <span class="path">terminal</span>
              <button class="copy" onclick="copyPre('c5',this)">
                <span data-lang="tr">Kopyala</span><span data-lang="en">Copy</span>
              </button>
            </div>
            <pre><code id="c5">\(escape(curlCmd))</code></pre>
            <p data-lang="tr" style="margin-top:12px">Bağlandıktan sonra istemcinize şunu deneyin:
            <b>&ldquo;BRAMPP'te test.local adında bir PHP alan adı oluştur&rdquo;</b></p>
            <p data-lang="en" style="margin-top:12px">Once connected, try asking your client:
            <b>&ldquo;Create a PHP domain called test.local in BRAMPP&rdquo;</b></p>
          </div>
        </section>

        <section>
          <h2><span data-lang="tr">Araçlar (\(toolNames.count))</span><span data-lang="en">Tools (\(toolNames.count))</span></h2>
          <div class="card">
            <div class="tools">\(toolCards)</div>
            <p style="margin-top:14px" data-lang="tr">Bu liste tüm araçları gösterir; istemcinin gördüğü küme
            <b>Erişim İzinleri</b>'ne göre süzülür. Tam şemalar için <code>tools/list</code> çağrısını kullanın.</p>
            <p style="margin-top:14px" data-lang="en">This list shows every tool; what a client actually sees is
            filtered by <b>Access Permissions</b>. Call <code>tools/list</code> for the full schemas.</p>
          </div>
        </section>

        <section>
          <h2><span data-lang="tr">Güvenlik</span><span data-lang="en">Security</span></h2>
          <div class="card">
            <p class="note" data-lang="tr">Sunucu yalnızca <b>127.0.0.1</b> adresine bağlanır — ağdan
            erişilemez. Tarayıcı kaynaklı isteklerde <code>Origin</code> ve <code>Host</code> başlıkları
            tam eşleşmeyle doğrulanır (DNS rebinding koruması). <code>/etc/hosts</code> yazan işlemler
            uygulama içinde yönetici onayı ister. Sunucuyu istediğiniz an
            <b>Ayarlar → MCP</b>'den kapatabilirsiniz.</p>
            <p class="note" data-lang="en">The server binds to <b>127.0.0.1</b> only — it is not
            reachable from the network. Browser-originated requests are validated by exact
            <code>Origin</code> and <code>Host</code> matching (DNS rebinding protection). Operations that
            write to <code>/etc/hosts</code> ask for administrator approval inside the app. You can turn the
            server off any time from <b>Settings → MCP</b>.</p>
          </div>
        </section>

        <footer>
          <p data-lang="tr">BRAMPP · Ayarlar → MCP ·
            <a href="https://github.com/macitkaraca/brampp" target="_blank" rel="noopener">GitHub</a></p>
          <p data-lang="en">BRAMPP · Settings → MCP ·
            <a href="https://github.com/macitkaraca/brampp" target="_blank" rel="noopener">GitHub</a></p>
        </footer>

        </div>
        <script>
        function setLang(l){
          document.documentElement.lang = l;
          document.getElementById('btr').className = (l==='tr'?'on':'');
          document.getElementById('ben').className = (l==='en'?'on':'');
        }
        setLang('\(startLang)');
        function flash(btn){
          var old = btn.innerHTML;
          btn.textContent = document.documentElement.lang==='tr' ? 'Kopyalandı ✓' : 'Copied ✓';
          setTimeout(function(){ btn.innerHTML = old; }, 1500);
        }
        function copyText(text, btn){
          navigator.clipboard.writeText(text).then(function(){ flash(btn); });
        }
        function copyPre(id, btn){
          copyText(document.getElementById(id).textContent, btn);
        }
        </script>
        </body>
        </html>
        """
    }

    /// HTML'e gömülen metinlerdeki özel karakterleri kaçırır (port/araç adları kod
    /// tarafından geliyor olsa da, metin gövdeye girmeden önce daima kaçırılmalı).
    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
