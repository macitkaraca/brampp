# Katkı

*[English](CONTRIBUTING.md)*

## Ne nerede

```
macos/          macOS uygulaması — SwiftUI, hiç dış bağımlılık yok
  BRAMPP/       Core (saf mantık) · Managers (durum + kabuk) · Views · Models
  BRAMPPTests/  tek dosya, XCTest
windows/        tasarım kararları, henüz kod yok
linux/          aynısı
spec/           üç platformun da uyması gereken sözleşmeler
docs/           site — kaynak `_pages/`, gerisi üretilir
.claude/skills/ uygulamanın kurduğu beceri dosyaları, ikisinin birer kopyası
```

## Derleme ve test

```bash
xcodebuild test -project macos/BRAMPP.xcodeproj -scheme BRAMPP -destination 'platform=macOS'
```

Hepsini derler ve koşturur. Yayın derlemeleri `-Osize` kullanır; `-O` yarım saate mal oluyor ve ömrünü kabuk komutlarını bekleyerek geçiren bir uygulamaya hiçbir şey kazandırmıyor.

## Sizi çelmeleyecek şeyler

**`Localization.swift` tek bir sözlük değişmezi.** Yinelenen anahtar derleme anında değil, **çalışma anında** çöker. Anahtar ekledikten sonra testleri koşun — biri kataloğu baştan sona geziyor.

**Biçim belirteçleri diller arasında eşleşmeli.** `String(format:)` fazla argümanı sessizce yutar; iki `%@` taşıyan bir Türkçe metinle üç taşıyan bir İngilizce metin hata vermez, yalnızca yanlış cümle üretir.

**Beceri dosyası iki kez var.** `macos/BRAMPP/Core/MCPToolsSkill.swift` `{{PORT}}` yer tutucusunu, `.claude/skills/mcptools/SKILL.md` ise çözülmüş portu taşır. Bir test ikisini bayt bayt karşılaştırır — ya ikisini değiştirin ya hiçbirini.

**Site üretilir ve çıktısı depoya işlenir.** `docs/_build.py --check` yalnızca bağlantıları denetler, hiçbir şey yazmaz; `docs/_build.py` argümansız çağrılınca da hiçbir şey yapmaz. Sayfa adlarını verin:

```bash
python3 docs/_build.py features changelog
```

Bunu unutmak, değişikliğin depoda olup sitede olmaması demektir.

**`spec/` üç platformu birden bağlar.** Bir MCP aracını yeniden adlandırmak ya da bir argümanın anlamını değiştirmek önce bir şartname değişikliğidir, sonra kod.

## Biçem

Düzenlediğiniz dosyaya uyun. Kod tabanının tutarlı yaptığı iki şey:

Yorumlar **nedenini** anlatır ve yerlerini neyin ters gittiğini kaydederek hak ederler. `// sayacı artır` gürültüdür; `// nesil sayacı burada ilerletilir, yoksa uçuştaki bir görev vhost'u geri yazar` o satırın neden silinemeyeceğidir.

Saf mantık `Core/` altına girer ve doğrudan test edilir. Kabuk komutu çalıştıran, dosyaya dokunan ya da durum tutan her şey bir `Manager`'a aittir; verdiği karar ise, makinenin belirli bir hâlde olmasını gerektirmeden testin çağırabileceği saf bir işlev olmalıdır.

## Commit'ler

Emir kipinde tek bir konu satırı, ardından neyin bozuk olduğunu anlatan düz metin. Değişiklik kaydı bunlardan yazılıyor; yalnızca "hata düzeltildi" diyen bir commit, hangisi olduğunu bulma işini başkasına bırakır.

Commit mesajlarında ve deponun hiçbir yerinde yapay zekâ atfı bulunmaz.

## Pull request

Düzeltmeden büyük her şey için önce bir issue açın — üç platformlu ayrım ve şartnameler yüzünden bazı değişiklikler göründüğünden geniştir. Küçük ve gerekçesi açık değişiklikler tören istemez.
