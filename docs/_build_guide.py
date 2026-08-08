#!/usr/bin/env python3
"""Rehber sayfası üreteci.

Ana sayfanın <style> bloğunu olduğu gibi devralır — süzmeye çalışmak :root
değişkenlerini kaçırıp sayfayı stilsiz bırakıyordu. Gövde HTML'i ayrı dosyalarda
tutulur; buradan yalnızca head, üst çubuk ve yapılandırılmış veri üretilir.

Kullanım:  python3 docs/_build_guide.py <slug>
Gerekli:   docs/_guides/<slug>.en.html  ve  docs/_guides/<slug>.tr.html
           docs/_guides/<slug>.json     (başlık/açıklama/tarih)
"""
import json, os, re, sys

ROOT = os.path.dirname(os.path.abspath(__file__))
BASE = "https://macitkaraca.github.io/brampp"

ARTICLE_CSS = """
main.guide{max-width:760px;margin:0 auto;padding:calc(var(--bar-h) + 48px) var(--pad) 96px}
.guide h1{font-size:clamp(30px,4.4vw,42px);line-height:1.15;letter-spacing:-.8px;margin:0 0 14px}
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
"""

def site_css():
    home = open(os.path.join(ROOT, "index.html"), encoding="utf-8").read()
    return re.search(r"<style>(.*?)</style>", home, re.S).group(1)


def render(lang, meta, body, css):
    slug = meta["slug"]
    en_url, tr_url = f"{BASE}/guides/{slug}/", f"{BASE}/tr/guides/{slug}/"
    canonical = en_url if lang == "en" else tr_url
    # Türkçe sayfa docs/tr/guides/<slug>/ altında → köke üç seviye
    up = "../../" if lang == "en" else "../../../"
    alt_href = (f"{up}tr/guides/{slug}/" if lang == "en" else f"{up}guides/{slug}/")
    alt_label = "🇹🇷 Türkçe" if lang == "en" else "🇬🇧 English"
    alt_lang = "tr" if lang == "en" else "en"
    icon = up + "assets/icon-256.png"

    ld = {
        "@context": "https://schema.org", "@type": "TechArticle",
        "headline": meta[lang]["title"], "description": meta[lang]["desc"],
        "inLanguage": lang, "datePublished": meta["published"],
        "image": f"{BASE}/assets/og-cover.png",
        "author": {"@type": "Person", "name": "Macit Karaca",
                   "url": "https://github.com/macitkaraca"},
        "publisher": {"@type": "Organization", "name": "Karaca Teknoloji"},
        "mainEntityOfPage": canonical,
    }
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
<link rel="icon" type="image/png" href="{icon}">
<meta property="og:type" content="article">
<meta property="og:title" content="{meta[lang]["title"]}">
<meta property="og:description" content="{meta[lang]["desc"]}">
<meta property="og:url" content="{canonical}">
<meta property="og:image" content="{BASE}/assets/og-cover.png">
<meta property="og:image:width" content="1200">
<meta property="og:image:height" content="630">
<meta name="twitter:card" content="summary_large_image">
<script type="application/ld+json">
{json.dumps(ld, ensure_ascii=False, indent=1)}
</script>
<style>{css}{ARTICLE_CSS}</style>
</head>
<body>
<nav class="topbar is-scrolled" aria-label="Site">
  <a class="brandmark" href="{up}" aria-label="BRAMPP"><img src="{icon}" alt="" width="26" height="26"><b>BRA<i>MPP</i></b></a>
  <div class="barcta">
    <a class="pill pill-dl" href="https://github.com/macitkaraca/brampp/releases/latest">⬇ DMG</a>
    <a class="pill" href="{alt_href}" hreflang="{alt_lang}" lang="{alt_lang}">{alt_label}</a>
  </div>
</nav>
<main class="guide">
{body}
</main>
</body>
</html>
"""


def build(slug):
    src = os.path.join(ROOT, "_guides")
    meta = json.load(open(os.path.join(src, slug + ".json"), encoding="utf-8"))
    meta["slug"] = slug
    css = site_css()
    for lang, out in (("en", f"guides/{slug}"), ("tr", f"tr/guides/{slug}")):
        body = open(os.path.join(src, f"{slug}.{lang}.html"), encoding="utf-8").read()
        d = os.path.join(ROOT, out)
        os.makedirs(d, exist_ok=True)
        p = os.path.join(d, "index.html")
        open(p, "w", encoding="utf-8").write(render(lang, meta, body, css))
        print(f"  ✓ docs/{out}/index.html  {os.path.getsize(p)//1024} KB")


if __name__ == "__main__":
    for s in sys.argv[1:]:
        build(s)
