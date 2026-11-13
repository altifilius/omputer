---
title: "Omputer — Dönen projeler ve çalışan oturum avatarı"
project: omputer
type: project-report
date: "2026-11-13"
status: tamamlandi
tags:
  - proje-raporu
  - android
  - animasyon
---

# Omputer — Dönen projeler ve çalışan oturum avatarı

[Proje sayfası](../README.md) · [Rapor dizini](README.md) · [Projects ana sayfası](../../README.md)

## Amaç ve kapsam

Kullanıcı, [neumorphic mesaj alanından](2026-11-13-neumorphic-mesaj-alani.md) sonra iki yeni native değişiklik istedi: projeleri liste yerine verdiği CSS örneğine benzer 3B dönen kart halkasında görmek; çalışan session bulunan projede hız çizgili uçan/avatar göstergesi. Ardından fiziksel Samsung telefonu bağlayıp kullanılabileceğini söyledi. Üç arayüz değişikliği **Android1.1.4(8)** ile tamamlandı, özgün imzayla telefona kuruldu ve gerçek ekranda doğrulandı.

## Mevcut uygulama kararı

- **Yüzey:** yalnız Projeler ana ekranı; inbox/ayarların Material gezinmesi korunur. Kullanıcının “menüler” talebindeki somut hedef proje kartlarıdır; diğer ekranlar döndürülmez.
- **Malzeme:** gerçek başlık/hedef/durum içeren native perspektif kartları; boş/renkli demo görselleri yok. Uygulamanın mevcut koyu/açık renk rolleri ve Türkçe metinleri korunur.
- **Etkileşim:** 20s tur, duraklat/başlat, sürükle ve önceki/sonraki proje; seçili ön karttan gerçek ProjectScreen. Klavye ve azaltılmış hareket anlık/statik seçim kullanır.
- **Devamlılık:** proje sırası stable ID ile korunur; stream güncellemeleri seçili projeyi oynatmaz. Yalnız seçili projenin bağlamı ve açık session kısayolları düz alanda gösterilir. Arama/filtre ve diğer eşleşen session sonuçları kaybolmaz.
- **Avatar:** canlı bağlantı + bağlı writer + `workState=running/background`. Human wait, settled ve disconnected çalışma sayılmaz. Bildirim veya provider çağrısı başlatılmaz. Animasyon küçük repaint alanıyla sınırlıdır; azaltılmış hareket, app lifecycle, TickerMode/offscreen sınırları gözetilir.

## Uygulanan kaynak alanları

`mobile/lib/main.dart`: seçili proje kimliği, filtrelenmiş gerçek projeler, halka ve seçili proje ayrıntıları; yazı ararken hareket durur. `projects.dart`: eski tüm-proje liste satırı yerine seçili-proje bağlamı, mevcut session erişimi ve ProjectScreen çalışma göstergesi. `working_avatar.dart`: native, küçük speeder çizimi. `project_carousel.dart`: 3B halka ve hareket/erişilebilirlik etkileşimleri. `pubspec.yaml`: Android1.1.4+8. `DESIGN.md`, `MOBILE-CONTRACT.md`, `CHANGELOG.md`, `VERIFICATION.md` ve dist metaverisi güncellendi.

Son dağıtım dosyası `dist/omputer-android.apk`, **55.972.009 byte**, SHA256 **`df7279dfd2d1c023da2d9ff3d7e1a49ce4430b23edb82e17f4f6e4b5fd9ae736`**. Telefonda geri okunan base APK aynı hash; sürüm1.1.4/code8 ve ilk kurulum zamanı korunuyor. PC/bridge paketi/servisi değiştirilmedi.

## Fiziksel telefon başlangıç kanıtı

Bağlanan tek yetkili USB cihaz Samsung **SM-G990E / Android16**, ekran **1080×2340**. Kurulu Omputer **1.1.3 / code7**; ilk kurulum **2026-10-17 20:01:38**, son güncelleme **2026-11-04 20:49:24**. Kurulu base APK özel geçici dizine alınıp doğrulandı:

- SHA256: `cae38ff4c2c0a7cd41ff33660cb14c04a9b31234ede7b09765f2491f72d41ef8`; mevcut dist APK ile aynı.
- Sertifika SHA256: `6ed5f72965a3a883055898632494cdd23f2f0aa50393ac10959caeecd0e2f2a1`; özgün yerel release imzası.
- Başlangıç tercihi: font1.0, gece modu açık, animator duration scale0.5. Bu tercihler bu okuma için değiştirilmedi.

Kullanıcı yapılandırılmış onayda **1.1.4(8)’i test/build/imza doğrulamasından sonra kur ve görsel kontrol yap** seçeneğini seçti; ayrıca telefonu bu kontrol için boş bıraktığını belirtti. Aynı-imzalı `install -r` uygulandı; uninstall/data-clear/re-pair/izin verme/mesaj gönderme yapılmadı.

## Güvenlik ve korunacak sınırlar

PC0.2.1/bridge1.1.1, çalışan servis, üretim veritabanı ve gerçek session yürütmesi değiştirilmedi. Canlı çalışma göstergesi gerçek bağlı session’dan geldi; sahte çalışma/provider isteği üretilmedi. Şifre/anahtar, imzalama parolası, token ve ham kişisel log rapora eklenmedi. Tam telefon ekranları özel geçici dizinde incelendi ve temizlendi; yalnız kişisel içerik taşımayan kırpılmış kontrol kanıtları tutuldu. Font1.0, gece modu açık ve animator scale0.5 aynen kaldı; eşleştirme/tema ayarları değiştirilmedi.

## Doğrulama ve kalan işler

İlk başarılı birleşik release gate: analyzer **5 dosyada temiz**, **39 hedefli Flutter testi geçti**; native Gradle release **429,8 saniyede başarılı**, servis tepe belleği **2,5 GiB / swap0**. Kapsam: home arama/filtre/kimlik/same-name terminal sınırları, 3B next/side tap/drag, 20s otomatik tur ve duraklatma, offscreen/nonopaque route/lifecycle, 280dp/%200 metin, klavye/semantics seçim, çalışma/bekleme/çevrimdışı avatar, piksel bazlı reduced-motion ve taslak input semantics. Ürün `lib/main.dart` ile arm64+x86_64 release derlendi. İlk ara APK1.1.4/code8 özgün **APK v2** imzalıydı, SHA256 `9cfb2e44206078859e858dc354111c7a999a136aa37b90fdf076fd6acedf6ecc`; fiziksel kontrolden sonraki düzeltme için son paket ve ek regresyon sonucu aşağıdadır. Impeccable manuel detector **`[]`**. Geçmiş backend testleri bu çalışmada tekrar koşulmadı.

### Entegrasyon kontrollerindeki ilk sonuçlar

İlk analyzer çalışması yeni dosyalarda kurulu Flutter API farklarını buldu: nullable viewport promotion, aynı callback scope’unda yinelenen `_` parametreleri ve deprecated TickerMode.of. Kaynak düzeltildi; sonraki analyzer **sorunsuz**. İlk test geçişleri yeni yüksek carousel yüzeyi nedeniyle ekran dışı kalan eski test etkileşimlerini, semantics handle temizliğini ve sonlu animasyonda ilk frame timing gereksinimini buldu. Beklentiler kaldırılmadı; gerçek seçili proje, kaydırma/yerleşim ve test kaynak temizliği güncellendi. Geçmeyen koşular release kabulü değildir; başarılı gate ve nihai fiziksel sonuç bu raporda ayrı kaydedildi.

### İlk fiziksel kurulum ve görsel bulgu

Onaylı `adb install -r` **Success**; telefonda **1.1.4/code8**, ilk kurulum zamanı aynı. Geri okunan base APK SHA256 ilk stage ile birebir `9cfb…6ecc`. Gerçek native ekranda 18 projeli 3B halka ve canlı Omputer projesinin speeder avatarı görüldü; bağlantı yeniden açık. Kişisel proje metinleri özel geçici alanda incelendi, kalıcı ham görüntü yapılmadı.

Görsel kontrol yeni-oturum FAB’ının döndürme kontrollerini örttüğünü buldu. Yanlış hedefe dokunuş yalnız boş Yeni oturum formunu açtı; hiçbir metin girilmedi/oturum başlatılmadı ve Back ile dönüldü. Ürün çözümü: yeni oturum aksiyonu AppBar’a taşındı; halka ve session içerikleri artık overlay altında değil. 393dp ekranda gerçek next hedefinin erişilebilirliğini ve aynı new-session yolunu koruyan ek regresyon **geçti**. Son artımlı release **72,0 saniyede** derlendi, **1,9GiB peak/swap0**; özgün APKv2 imzası doğrulandı ve aynı-imzalı yeniden kurulum **Success**. Son paket hash’i yukarıdaki `df7279…e736`; ilk fiziksel `9cfb…6ecc` paketi nihai teslim değildir.

## Nihai fiziksel kabul

- 18 gerçek proje kartı, yan yüzler, otomatik dönüş ve görünür kontroller ekranda incelendi. Next ile gerçek Omputer projesi seçildi; ön karta dokununca doğru proje açıldı. Session satırından bu gerçek konuşmaya geçildi. Avatar hem kartta hem proje detayında canlı çalışma durumu ile göründü.
- Native Samsung klavyesi yalnız boş girişe odaklanarak açıldı. TextField kapalı klavyede `[56,2138][855,2295]`, açık klavyede `[56,1097][855,1254]`; `focused=true`, `mInputShown=true` ve `mIsInputViewShown=true`. Sarı odak/derinlik ve gönder hedefi klavye üstünde görüldü. Taslak boş kaldı; metin yazılmadı/gönderilmedi. Back ile ana ekrana dönüldü.
- Son app PID kapsamındaki Flutter/AndroidRuntime error okuması boş. Sürekli hareket sırasında UIAutomator “could not get idle state” verdi; dönüşü durduran gerçek kontrollerden sonra bounded native hiyerarşi okundu. Bu OS aracı sınırı test sonucu uydurularak aşılmadı.
- Fiziksel kurulum zamanı **2026-11-13 13:18:05**; ilk kurulum **2026-10-17 20:01:38**. İki paket de tek versionCode8 milestone’unda doğrulama öncesi/sonrası düzeltmeydi; dağıtım yalnız son kabul edilmiş APK.
- Native bilgisayar aynası X11 yolu kullanılamadı; Wayland read-only scrcpy açıldı fakat host native capture keşfi bu pencereyi sunmadı. Android’e açık seri hedefli ADB capture/input kullanıldı, kullanıcı masaüstüne foreground giriş gönderilmedi. Owned mirror/özel sürücüler kapatıldı.

### Gizlilikten geçirilmiş kanıt

- [Neumorphic giriş ve odak](../Kanitlar/2026-11-13/proje-halkasi/fiziksel-neumorphic-input.png)
- [Gerçek çalışma avatarı](../Kanitlar/2026-11-13/proje-halkasi/fiziksel-calisan-avatar.png)
- [Halka ve erişilebilir seçim kontrolleri](../Kanitlar/2026-11-13/proje-halkasi/fiziksel-proje-kart-kontrolleri.png)
- [Same-APK kurulum ve native sınır sonucu](../Kanitlar/2026-11-13/proje-halkasi/fiziksel-kabul.json)

## Sınırlar, işletim ve geri alma

Kullanıcının üç görsel isteği ve onaylı telefona kurulum tamamlandı. Fiziksel TalkBack, %200/light/tablet/yatay/reduced-motion donanım matrisi, pil/Doze ve performans profili yapılmadı; bu sınırların bir kısmı hedefli widget testleriyle kapsanır, fiziksel kabul yerine sunulmaz. Yeni native loop performansı için FPS ölçümü veya güç garantisi verilmez. Model/izin/karar teslimi çalıştırılmadı; önceki backend testleri yeni tarihli sayılmadı.

Proje kaynakları ve `dist/omputer-android.apk` gerçek çalışma yerlerinde. Normal same-signer upgrade veriyi korur; sürüm düşürme Android tarafından reddedilebilir. Geri alma test edilmedi; uninstall/data-clear geri alma yöntemi değildir. Bu iş için açık kalan zorunlu adım yok; kapsam dışı kabuller yukarıda ayrıldı. Commit/push veya bulut paylaşımı yapılmadı.
