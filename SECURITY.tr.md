# Güvenlik

*[English](SECURITY.md)*

## Açık bildirimi

Herkese açık bir issue yerine özel olarak bildirin: [güvenlik danışmanlığı](https://github.com/macitkaraca/brampp/security/advisories/new) açın ya da **info@karacatechnology.com** adresine yazın.

Saldırganın ne kazandığını, adım adım nasıl üretildiğini ve BRAMPP sürümünü yazın. Çalışan bir kanıt kodu memnuniyetle karşılanır ama şart değil — mekanizmanın açık bir anlatımı başlamak için yeterli.

Bir hafta içinde ilk yanıtı alırsınız. Düzeltme gerekiyorsa bir sonraki sürümde çıkar ve değişiklik kaydı neyin bozuk olduğunu söyler. Düzeltme var olmadan hiçbir şey yayımlanmaz.

## Desteklenen sürümler

Yalnızca en son sürüm. BRAMPP tek geliştiricili, sık sürüm çıkan bir proje; geriye taşıma dalı yok. Düzeltme size güncelleyerek ulaşır — uygulama bunu artık yerinde yapabiliyor.

## BRAMPP makinenizde neye dokunur

Bir şeyin açık olup olmadığına karar verirken işinize yarar:

**Zaten kurulu servisleri sürer.** BRAMPP Homebrew formüllerini başlatır, durdurur ve yapılandırır — Apache, nginx, PHP-FPM, MariaDB, PostgreSQL, Redis. Homebrew ön eki altındaki yapılandırma dosyalarına ve `/etc/hosts`'a yazar. Hiçbirinin kendi kopyasını paketlemez; BRAMPP'ı kaldırınca hepsi çalışmaya devam eder.

**Yönetici hakkını tek bir yerde ister.** `/etc/hosts` düzenlemesi bunu gerektirir. Başka hiçbir şey gerektirmez — ne servis kurmak, ne uygulamanın kendini güncellemesi. Parolanızı başka bir yerde isteyen bir yapı bizim değildir.

**MCP sunucusu yalnızca loopback'e bağlanır** ve siz açana kadar kapalıdır. Beş izin alanında araç sunar; her alan ayrı ayrı erişim yok / okuma / yazma olarak ayarlanır ve paylaşım alanı varsayılan olarak **erişim yok**'tur, çünkü o araçlar bir siteyi herkese açık internete koyar. İzin vermediğiniz araç listede görünmez, yine de çağrılırsa reddedilir.

**Paylaşım geçicidir ve asla kendiliğinden olmaz.** Cloudflare Quick Tunnel yalnızca siz isteyince açılır, diske hiç yazılmaz ve BRAMPP kapanınca hepsi kapanır. Arkasında bir şey çalışmayan site paylaşılamaz.

**Güncellemeler kurulmadan önce doğrulanır.** İndirilen dosya güncelleme manifestindeki sağlamayla karşılaştırılır, imzası ve yayıncı kimliği doğrulanır, Apple onayı denetlenir. Aynı denetimler gerçekten kurulan kopyanın üzerinde tekrarlanır — çünkü doğrulanan şeyle kurulan şeyin arasında bir kopyalama vardır.

## Kapsam dışı

"Zaten sizin olarak kod çalıştırabilen bir saldırgan, sizin yapabildiğinizi yapabilir" özetine inen bildirimler BRAMPP açığı değildir. Servislerin kendi zayıf varsayılanları için de aynısı geçerli — parolasız bir veritabanı Homebrew'un varsayılanıdır, BRAMPP'ın getirdiği bir şey değil. Ama BRAMPP'ın böyle bir varsayılanı, daha önce **ulaşamayan** bir şey için ulaşılabilir kıldığı durumlarla ilgileniriz.
