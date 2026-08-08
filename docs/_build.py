#!/usr/bin/env python3
"""Site sayfası üreteci.

Ana sayfanın <style> bloğunu olduğu gibi devralır — süzmeye çalışmak :root
değişkenlerini kaçırıp sayfayı stilsiz bırakıyordu. Gövde HTML'i _pages/
altında ayrı dosyalarda tutulur; buradan yalnızca head, üst çubuk, menü ve
yapılandırılmış veri üretilir.

Menü tek yerden (NAV) tanımlanır ve göreli önek her sayfanın derinliğine göre
hesaplanır; ana sayfaların menüsü de aynı kaynaktan yamalanır (bkz. --nav).

Kullanım:  python3 docs/_build.py <slug> [<slug> …]
           python3 docs/_build.py --nav          # yalnız ana sayfaların menüsü
Gerekli:   docs/_pages/<slug>.json  +  <slug>.en.html  +  <slug>.tr.html
"""
import json, os, re, sys

ROOT = os.path.dirname(os.path.abspath(__file__))
BASE = "https://macitkaraca.github.io/brampp"

# Menü tek kaynak: (yol, EN etiketi, TR etiketi). Yol köke göredir.
NAV = [
    ("features/", "Features",    "Özellikler"),
    ("install/",  "Install",     "Kurulum"),
    ("mcp/",      "MCP",         "MCP"),
    ("compare/",  "Compare",     "Karşılaştırma"),
    ("guides/",   "Guides",      "Rehberler"),
    ("#faq",      "FAQ",         "SSS"),
]

ARTICLE_CSS = """
main.guide{max-width:760px;margin:0 auto;padding:calc(var(--bar-h) + 48px) var(--pad) 96px}
main.page{padding-top:calc(var(--bar-h) + 40px)}
.guide h1,.page h1{font-size:clamp(30px,4.4vw,42px);line-height:1.15;letter-spacing:-.8px;margin:0 0 14px}
.guide .lede{font-size:19px;color:var(--muted);line-height:1.65;margin:0 0 12px}
.guide .meta{font-size:13px;color:var(--dim);margin:0 0 40px}
.guide h2{font-size:25px;letter-spacing:-.3px;margin:44px 0 12px;scroll-margin-top:90px}
.guide h3{font-size:19px;margin:28px 0 8px}
.guide p{margin:0 0 17px}
.guide h2+p,.guide h3+p{margin-top:0}
.guide p,.guide li{font-size:17px;line-height:1.72;color:#cfdcec}
.guide ul,.guide ol{padding-left:22px;margin:12px 0}
.guide li{margin:7px 0}
.guide strong{color:var(--fg)}
.guide pre{background:#0a1424;border:1px solid var(--line);border-radius:10px;padding:14px 16px;overflow-x:auto;margin:16px 0}
.guide pre code{background:none;padding:0;font-size:13.5px;line-height:1.6;color:#d7e5f7}
.guide code{background:rgba(255,255,255,.07);border:1px solid var(--line-soft);border-radius:5px;padding:1px 6px;font-size:14.5px}
.callout{border:1px solid var(--line);border-left:3px solid var(--amber);background:rgba(245,158,11,.06);border-radius:10px;padding:14px 18px;margin:22px 0}
.callout p{margin:0;font-size:16px}
.callout b{color:var(--amber-hi)}
.guide table{width:100%;border-collapse:collapse;margin:18px 0;font-size:15.5px}
.guide th,.guide td{border:1px solid var(--line);padding:9px 12px;text-align:left;vertical-align:top}
.guide th{background:rgba(255,255,255,.04);font-weight:600}
.backlink{display:inline-block;margin-top:48px;color:var(--muted);text-decoration:none;font-size:15px}
.backlink:hover{color:var(--amber-hi)}
.pagehead{max-width:820px;margin:0 auto 8px;padding:0 var(--pad);text-align:center}
.pagehead .lede{font-size:19px;color:var(--muted);line-height:1.65;margin:12px auto 0;max-width:660px}
.crumb{font-size:13px;color:var(--dim);margin:0 0 16px}
.crumb a{color:var(--muted);text-decoration:none}
.crumb a:hover{color:var(--amber-hi)}
.nextprev{display:grid;gap:12px;grid-template-columns:repeat(auto-fit,minmax(240px,1fr));max-width:900px;margin:56px auto 0;padding:0 var(--pad)}
.nextprev a{display:block;border:1px solid var(--line);border-radius:12px;padding:14px 16px;text-decoration:none;background:var(--card)}
.nextprev a:hover{border-color:var(--amber);background:rgba(245,158,11,.05)}
.nextprev small{display:block;color:var(--dim);font-size:12px;margin-bottom:3px}
.nextprev b{color:var(--fg);font-size:15.5px}
/* Tanıtım sayfaları: başlıklar ortalı (.shead ana sayfayla aynı), gövde metni ise
   ortalanmış 780px'lik bir sütunda sola dayalı — uzun paragraflar böyle okunuyor. */
.page .para,.page .bullets,.page .callout,.page .sub-h,.page pre{max-width:780px;margin-left:auto;margin-right:auto}
.page .para{font-size:17px;line-height:1.72;color:#cfdcec;margin-top:0;margin-bottom:17px}
.page .bullets{margin-top:14px;margin-bottom:14px;padding-left:22px}
.page .bullets li{font-size:17px;line-height:1.72;color:#cfdcec;margin:8px 0}
.page .para b,.page .bullets b{color:var(--fg)}
.page .note{max-width:780px;margin-left:auto;margin-right:auto}
/* Uzun satır içi kod ("mysqldump --single-transaction …") bölünemediği için dar
   ekranda sayfayı kendi genişliğine zorluyordu. Site CSS'i <code> için
   white-space:nowrap veriyor — onu geçmeden overflow-wrap tek başına işe
   yaramıyor. <pre> içindeki blok kod biçimini korur. */
.page code,.guide code{white-space:normal;overflow-wrap:anywhere}
.page pre code,.guide pre code{white-space:pre;overflow-wrap:normal}
.page section:first-of-type{padding-top:8px}
.page pre{background:#0a1424;border:1px solid var(--line);border-radius:10px;padding:14px 16px;overflow-x:auto;margin-top:16px;margin-bottom:16px}
.page pre code{background:none;border:0;padding:0;font-size:13.5px;line-height:1.6;color:#d7e5f7}
.page kbd{background:rgba(255,255,255,.07);border:1px solid var(--line-soft);border-radius:5px;padding:1px 6px;font-size:14px}
/* Ana sayfadaki .sub-h tablo etiketi olarak tasarlandı (13px, büyük harf, ortalı).
   Uzun metin sayfalarında ara başlık gibi okunması gerekiyor. */
.page .sub-h{font-size:21px;font-weight:650;letter-spacing:-.2px;text-transform:none;
  color:var(--fg);text-align:left;margin-top:38px;margin-bottom:10px}
"""


def wrap_tables(body):
    """Sarmalanmamış tabloları `.tscroll` içine alır.

    Dar ekranda geniş bir tablo, `overflow-x` veren bir kap olmadan sayfanın
    tamamını kendi genişliğine zorluyor ve yatay kaydırma çubuğu çıkarıyordu.
    Ana sayfa bunu elle `.tscroll` ile çözüyor; rehber gövdeleri düz `<table>`
    kullandığı için sarmalama burada yapılıyor.
    """
    out, pos = [], 0
    for m in re.finditer(r"<table\b", body):
        s = m.start()
        if body.rfind('<div class="tscroll">', 0, s) > body.rfind("</div>", 0, s):
            continue                      # zaten sarmalanmış
        e = body.index("</table>", s) + len("</table>")
        out.append(body[pos:s] + '<div class="tscroll">' + body[s:e] + "</div>")
        pos = e
    out.append(body[pos:])
    return "".join(out)


def site_css():
    home = open(os.path.join(ROOT, "index.html"), encoding="utf-8").read()
    return re.search(r"<style>(.*?)</style>", home, re.S).group(1)


NAVJS = """<script>
(function () {
  // Açılır her şey (menü paneli + dil kutuları) tek bir listeden yönetiliyor:
  // biri açılırken diğerleri kapanmalı, sayfa boşluğuna tıklamak hepsini kapatmalı.
  var groups = [];
  var btn = document.querySelector('.navtoggle'), nav = document.getElementById('sitenav');
  if (btn && nav) groups.push([btn, nav]);
  document.querySelectorAll('.langsel').forEach(function (sel) {
    var b = sel.querySelector('.langbtn'), m = sel.querySelector('.langmenu');
    if (b && m) groups.push([b, m]);
  });
  function closeAll() {
    groups.forEach(function (g) { g[1].classList.remove('open'); g[0].setAttribute('aria-expanded', 'false'); });
  }
  groups.forEach(function (g) {
    g[0].addEventListener('click', function (e) {
      e.stopPropagation();
      var wasOpen = g[1].classList.contains('open');
      closeAll();
      if (!wasOpen) { g[1].classList.add('open'); g[0].setAttribute('aria-expanded', 'true'); }
    });
    g[1].addEventListener('click', function (e) { if (e.target.closest('a')) closeAll(); });
  });
  document.addEventListener('click', closeAll);
  document.addEventListener('keydown', function (e) { if (e.key === 'Escape') closeAll(); });
  addEventListener('resize', function () { if (innerWidth > 1024) closeAll(); });
})();
</script>"""


def lang_picker(lang, up, tail, uid):
    """Mevcut dili gösteren, tıklayınca iki seçenek açan dil kutusu.

    Önceki hâl karşı dili gösteriyordu ("EN sayfada 🇹🇷 Türkçe") — bu, etiketin
    sayfanın dilini mi bildirdiği yoksa geçiş düğmesi mi olduğu belirsizdi.
    Şimdi düğme bulunduğunuz dili söylüyor, seçim listeden yapılıyor. `uid`
    gerekli çünkü kutu hem üst çubukta hem footer'da görünüyor.
    """
    # `up` köke giden öneki verir; boş kalırsa href="" geçersiz olur.
    opts = [("en", "🇬🇧", "English", (up + tail) or "./"),
            ("tr", "🇹🇷", "Türkçe",  up + "tr/" + tail)]
    cur = next(o for o in opts if o[0] == lang)
    items = ""
    for code, flag, name, href in opts:
        mark = ' aria-current="true"' if code == lang else ""
        items += (f'<a href="{href}" hreflang="{code}" lang="{code}" role="menuitem"{mark}>'
                  f'<span aria-hidden="true">{flag}</span>{name}</a>')
    return (f'<div class="langsel">'
            f'<button class="pill langbtn" type="button" aria-haspopup="true" '
            f'aria-expanded="false" aria-controls="langmenu-{uid}">'
            f'<span aria-hidden="true">{cur[1]}</span>{cur[2]}'
            f'<span class="chev" aria-hidden="true">▾</span></button>'
            f'<div class="langmenu" id="langmenu-{uid}" role="menu">{items}</div></div>')


def footer_html(lang, up, tail):
    """Alt sayfalarda site geneli footer — ana sayfadaki kısa footer'ın genişi."""
    L = {"en": dict(pages="Pages", guides="Guides", project="Project",
                    home="Home", feat="Features", inst="Install", cmp="Compare",
                    https="Local HTTPS", both="Apache and Nginx together",
                    mcpg="MCP for local development", repo="Repository",
                    rel="Latest release", lic="License",
                    credit='Built by <a href="https://github.com/macitkaraca"><b>Macit Karaca</b></a> at <a href="https://karacatechnology.com" rel="noopener"><b>Karaca Technology</b></a>',
                    fine='Pronounced "bremp". Free and open source, MIT licensed.'),
         "tr": dict(pages="Sayfalar", guides="Rehberler", project="Proje",
                    home="Ana sayfa", feat="Özellikler", inst="Kurulum", cmp="Karşılaştırma",
                    https="Yerel HTTPS", both="Apache ve Nginx birlikte",
                    mcpg="Yerel geliştirme için MCP", repo="Depo",
                    rel="Son sürüm", lic="Lisans",
                    credit='<a href="https://github.com/macitkaraca"><b>Macit Karaca</b></a> tarafından <a href="https://karacatechnology.com" rel="noopener"><b>Karaca Technology</b></a> bünyesinde geliştirildi',
                    fine='"bremp" diye okunur. Ücretsiz ve açık kaynak, MIT lisanslı.')}[lang]
    b = up + ("tr/" if lang == "tr" else "")
    gh = "https://github.com/macitkaraca/brampp"
    return f"""<footer class="sitefoot">
  <div class="wrap footgrid">
    <div>
      <h2>{L["pages"]}</h2>
      <a href="{b}">{L["home"]}</a>
      <a href="{b}features/">{L["feat"]}</a>
      <a href="{b}install/">{L["inst"]}</a>
      <a href="{b}mcp/">MCP</a>
      <a href="{b}compare/">{L["cmp"]}</a>
    </div>
    <div>
      <h2>{L["guides"]}</h2>
      <a href="{b}guides/">{L["guides"]}</a>
      <a href="{b}guides/local-https/">{L["https"]}</a>
      <a href="{b}guides/apache-nginx-together/">{L["both"]}</a>
      <a href="{b}guides/mcp-local-dev/">{L["mcpg"]}</a>
    </div>
    <div>
      <h2>{L["project"]}</h2>
      <a href="{gh}">{L["repo"]}</a>
      <a href="{gh}/releases/latest">{L["rel"]}</a>
      <a href="{gh}/blob/main/LICENSE">{L["lic"]}</a>
    </div>
    <div class="footlang">
      <h2>{"Language" if lang == "en" else "Dil"}</h2>
      {lang_picker(lang, up, tail, "foot")}
    </div>
  </div>
  <div class="wrap footbase">
    <p>{L["credit"]} · MIT © 2023–2026 Karaca Teknoloji</p>
    <p class="fine">{L["fine"]}</p>
  </div>
</footer>"""

NAVBTN = ('<button class="navtoggle" type="button" aria-label="Menu" aria-expanded="false" '
          'aria-controls="sitenav"><span></span><span></span><span></span></button>')


def nav_html(lang, up, here=""):
    """Menü bağlantıları. `up` köke giden göreli önek, `here` etkin sayfanın yolu."""
    out = []
    for path, en, tr in NAV:
        label = en if lang == "en" else tr
        href = up + path if not path.startswith("#") else up + path
        cur = ' aria-current="true"' if path and path == here else ""
        out.append(f'<a href="{href}"{cur}>{label}</a>')
    return '<div class="navlinks" id="sitenav">' + "".join(out) + "</div>"


def topbar(lang, up, here, tail):
    icon = up + "assets/icon-256.png"
    dl = "⬇ DMG"
    return f"""<nav class="topbar is-scrolled" aria-label="Site">
  <a class="brandmark" href="{up or './'}" aria-label="BRAMPP"><img src="{icon}" alt="" width="26" height="26"><b>BRA<i>MPP</i></b></a>
  {nav_html(lang, up, here)}
  <div class="barcta">
    <a class="pill pill-dl" href="https://github.com/macitkaraca/brampp/releases/latest">{dl}</a>
    {lang_picker(lang, up, tail, "bar")}
  </div>
  {NAVBTN}
</nav>"""


def render(lang, meta, body, css):
    path = meta["path"]                       # "guides" | "guides/local-https" | "features"
    tail = (path + "/") if path else ""
    en_url, tr_url = f"{BASE}/{tail}", f"{BASE}/tr/{tail}"
    canonical = en_url if lang == "en" else tr_url
    depth = len([s for s in path.split("/") if s]) + (0 if lang == "en" else 1)
    up = "../" * depth
    here = meta.get("nav", "")

    ld = {
        "@context": "https://schema.org", "@type": meta.get("type", "TechArticle"),
        "headline": meta[lang]["title"], "name": meta[lang]["title"],
        "description": meta[lang]["desc"],
        "inLanguage": lang, "datePublished": meta["published"],
        "image": f"{BASE}/assets/og-cover.png",
        "author": {"@type": "Person", "name": "Macit Karaca",
                   "url": "https://github.com/macitkaraca"},
        "publisher": {"@type": "Organization", "name": "Karaca Teknoloji"},
        "mainEntityOfPage": canonical,
    }
    if meta.get("type") == "WebPage":
        ld.pop("headline")
    else:
        ld.pop("name")

    extra = meta.get("ld_" + lang)
    ld_blocks = "\n".join(
        f'<script type="application/ld+json">\n{json.dumps(x, ensure_ascii=False, indent=1)}\n</script>'
        for x in ([ld] + ([extra] if extra else []))
    )
    cls = "page" if meta.get("type") == "WebPage" else "guide"
    return f"""<!doctype html>
<html lang="{lang}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>{meta[lang]["title"]}</title>
<meta name="description" content="{meta[lang]["desc"]}">
<link rel="canonical" href="{canonical}">
<link rel="alternate" hreflang="en" href="{en_url}">
<link rel="alternate" hreflang="tr" href="{tr_url}">
<link rel="alternate" hreflang="x-default" href="{en_url}">
<link rel="icon" type="image/png" href="{up}assets/icon-256.png">
<meta property="og:type" content="article">
<meta property="og:title" content="{meta[lang]["title"]}">
<meta property="og:description" content="{meta[lang]["desc"]}">
<meta property="og:url" content="{canonical}">
<meta property="og:image" content="{BASE}/assets/og-cover.png">
<meta property="og:image:width" content="1200">
<meta property="og:image:height" content="630">
<meta name="twitter:card" content="summary_large_image">
{ld_blocks}
<style>{css}{ARTICLE_CSS}</style>
</head>
<body>
{topbar(lang, up, here, tail)}
<main class="{cls}">
{body.replace("{{UP}}", up)}
</main>
{footer_html(lang, up, tail)}
{NAVJS}
</body>
</html>
"""


def build(slug):
    src = os.path.join(ROOT, "_pages")
    meta = json.load(open(os.path.join(src, slug + ".json"), encoding="utf-8"))
    meta.setdefault("path", slug)
    css = site_css()
    for lang in ("en", "tr"):
        body = wrap_tables(open(os.path.join(src, f"{slug}.{lang}.html"), encoding="utf-8").read())
        out = meta["path"] if lang == "en" else "tr/" + meta["path"]
        d = os.path.join(ROOT, out)
        os.makedirs(d, exist_ok=True)
        p = os.path.join(d, "index.html")
        open(p, "w", encoding="utf-8").write(render(lang, meta, body, css))
        print(f"  ✓ docs/{out}/index.html  {os.path.getsize(p) // 1024} KB")


def patch_home_nav():
    """Ana sayfaların menüsünü NAV ile eşitler.

    İki ana sayfa da kendi dil kökündedir (docs/ ve docs/tr/), dolayısıyla ikisi
    için de önek boştur — `../` vermek TR menüsünü İngilizce sayfalara gönderir.
    """
    for f, lang, up in (("index.html", "en", ""), ("tr/index.html", "tr", "")):
        p = os.path.join(ROOT, f)
        t = open(p, encoding="utf-8").read()
        new = nav_html(lang, up)
        t2, n = re.subn(r'<div class="navlinks">.*?</div>', new, t, count=1, flags=re.S)
        if n == 0:
            print(f"  ! {f}: menü bulunamadı")
            continue
        if t2 == t:
            print(f"  = {f}: menü zaten güncel")
            continue
        open(p, "w", encoding="utf-8").write(t2)
        print(f"  ✓ {f}: menü eşitlendi ({len(NAV)} bağlantı)")


if __name__ == "__main__":
    args = sys.argv[1:]
    if "--nav" in args:
        patch_home_nav()
        args = [a for a in args if a != "--nav"]
    for s in args:
        build(s)
