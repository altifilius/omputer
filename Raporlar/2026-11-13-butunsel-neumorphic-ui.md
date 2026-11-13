---
title: "Omputer — Bütünsel neumorphic UI planı ve uygulama"
project: omputer
type: project-report
date: "2026-11-13"
status: tamamlandi
tags:
  - proje-raporu
  - android
  - tasarim-sistemi
---

# Omputer — Bütünsel neumorphic UI planı ve uygulama

[Proje sayfası](../README.md) · [Rapor dizini](README.md) · [Projects ana sayfası](../../README.md)

## Amaç ve kapsam

Kullanıcı uygulamanın bütün UI’ının neumorphic sisteme çevrilmesini, önce plan sonra execute ve ilgili tasarım becerileriyle profesyonel kalite çalışmasını istedi. Hedef mevcut Flutter Android uygulamasıdır. PC egui yönetim uygulaması/backend, protokol, veritabanı, provider, eşleştirme yetkisi ve ağ ayarları bu görsel işte değişmez. Kullanıcının son iki örneğiyle eklenen 3B proje halkası ve gerçek çalışma avatarı korunur.

## Plan — uygulamadan önce

### Yön

**Grafit çalışma yüzeyi:** koyuda nötr grafit, açıkta sis grisi. Tek amber vurgu; hata ve izin uyarıları semantik renklerini korur. Işık sol üstten gelir; kabarık yüzeylerin koyu gölgesi sağ altta, açık karşı gölgesi sol üstte. İçe gömülü alanlarda ışık ters yönde hissedilir. Parlak neon/100px hale, glass, uzaktan font/görsel veya bütün ekranı titreten motion yok.

**Derinlik sözlüğü:** 1) raised: işlem düğmesi ve seçilebilir kart, 2) inset: metin girişi/seçili kontrol/kod, 3) flat: uzun okuma ve yoğun günlük. Her öğeyi kart içine kart yapmadan aynı malzemeye bağla. Odak 2dp amber çizgiyle, seçim metin+ikonla görünür; yalnız gölge veya renk durum ayrımı değildir.

### Uygulama sırası ve dosya sahipliği

1. **Ortak temel:** `neumorphic.dart` yeni tek derinlik kaynağı, `ui.dart` tema/geri bildirim/kod. Native Filled/Outlined/IconButton içeriği ve callback’leri korunarak theme `backgroundBuilder` ile raised/pressed yüzey; global InputBorder ile gerçek inset. Yeni bağımlılık yok.
2. **Gezinme/proje/konuşma:** `main.dart`, `projects.dart`, `project_carousel.dart`, `session.dart`, `message_input.dart`. Üç hedefli native navigation, güvenli IME sabitlemesi, kararlı proje/session kimlikleri korunur. Liste satırları sığ ve ölçülü; uzun assistant metni flat.
3. **Form/karar/eşleştirme/ayar:** `interactions.dart`, `pairing.dart`, `settings.dart`, `diagnostics.dart`. Radio/checkbox/switch/QR güveni native kalır; form yuvaları ve güvenlik bağlamı tek sistem. Kimliği unutma, cihaz revoke, bildirim/pil izinleri denenmez.
4. **Dosya/geçmiş/komutlar:** `project_files.dart`, `session_file_context.dart`, `memory_history.dart`, `session_controls.dart`. Seçili komut, read-only veri, operation/error ve yükleme durumları ayrılır. Sahte veri/istek ürün varsayılanına girmez.
5. **Profesyonel geçiş:** Emil’in motion/feedback sınırı; Impeccable Operate/craft/Android/a11y; Taste mevcut-app koruma; Unslop spacing→color→icon→copy→type→layout→details→visual→motion kalite kapıları. Break-UI yönteminden gerçekçi uzun Türkçe başlık/boş/tek/çok kayıt, 320dp ve %200 yazı senaryoları. İstenen neumorphism bilinçli malzeme; slop uyarısı onu iptal etmez.
6. **Kabul:** ilgili Flutter testleri birleştikten sonra seri; light/dark kontrast, focus/pressed/disabled, büyük metin/IME ve gerçek native ekranlar. Ek davranış testi yalnız yeni belirsiz tüketici sınırlarını korur. Ürün entrypoint’inden same-signer yeni APK; telefona yükleme için exact yeni sürüm onayı ayrıca alınır.

### Korunan sözleşmeler

- Native Back, safe area ve Android adjustResize; min48dp dokunma hedefleri.
- Draft/session/mode/identity ve late-ACK temizleme kuralları.
- Pending/expired/offline karar durumu; hiçbir izin/komut görsel kontrol için onaylanmaz.
- Arama, filtre, seçili proje/session ID, slash ve yeni oturum erişimi.
- Reduced-motion ve background/offscreen tick durdurma.
- İmza/pairing/ilk-kurulum korunumlu güncelleme; uninstall/data clear yok.

### Kanıt ve kalite kapısı

Native uygulama tarayıcı ile kabul edilmiş sayılmaz. Bağlı Samsung16 gerçek surface için kullanılabilir; kişisel ekranlar özel geçici yerde incelenir, rapora yalnız privacy-reviewed kontrol görüntüsü girer. Erişilemeyen karar/pairing/uzun veri yüzeyleri geçici native fixture ile, gerçek ürün widget’larından açılır. Light/dark/büyük metin testleri fiziksel TalkBack, pil, frame-time veya tüm cihaz matrisi garantisi değildir.

### Tasarım sözleşmesi

- **THESIS:** Yerel PC işlerini telefondan güvenle sürdürmek; UI önce proje/oturum/durum bilgisini açık eder, dokunsal malzeme işlem yapılabilirliği destekler.
- **OWN-WORLD:** Kullanıcının açıkça istediği neumorphic grafit/sis yüzey; top-left tek ışık, nötr dual shadow, tek amber vurgu, native Roboto/Material kontrolleri. Yedi grounded malzeme yorumu içinden dördüncü—grafit/sis—brief’e uygun seçildi; alternatif görünüm dayatılmadı.
- **STORY:** Projeyi bul → gerçek session/durumunu gör → konuşmayı veya bekleyen kararı aç → açık gönder/onay sınırı. Drawer/hero/marketing topolojisi eklenmedi.
- **FIRST VIEWPORT:** Native app bar, bağlantı/freshness, arama/filtre ve kullanıcının mevcut 3B proje halkası; altındaki seçili bağlam transform dışında. Ayar/karar/konuşma yüzeyleri aynı malzemeye bağlanır.
- **FORM:** Native kod-öncelikli uygulama; seed:0e1f1de983eda07e mekanik yön kontrolü çalıştırıldı. Kullanıcının pinlediği neumorphism tüm rastlantısal alternatiflerden üstün; yoğun küçük-yazı/karakter-katalog/boarding-pass gibi kıyafetler ve kontrol topolojileri alınmadı. Saklanan disiplin yalnız durum netliği, kimlik korunumu ve tutarlı hiyerarşi. Görsel üretim veya web comp kullanılmadı.

## Başlangıç bulguları

- Yalnız message_input neumorphic; kalan uygulama blue-black/periwinkle Material, örnekler arası görsel dil ayrık.
- Shared native Material tema birçok buton/formu tek noktadan taşıyabilir; bütün field callback’lerini yeniden yazmak gereksiz risk.
- Mevcut `message_input.dart` kendi gölge/paletiyle ortak sistemden kopuk; ortak inset sisteme bağlanmalı.
- Uzun assistant/tool/file metinleri kart yığınlarına dönüşmemeli; derinlik seçilebilirlik ve giriş durumunu anlatmalı.
- Önceki fiziksel FAB çakışması giderildi; yeni tasarımda kontroller tekrar overlay altına girmemeli.

## Uygulama ve sonuç

Plan ve execute sırası uygulandı. `neumorphic.dart` tek ThemeExtension/raised-inset-flat ışık sistemi; bütün native input/button theme katmanları, NavigationBar/rail indicator, dialog/menu/sheet ve liste/context yüzeyleri bu kaynağa geçirildi. Ana/proje/konuşma, yeni oturum, karar/inbox, eşleştirme, ayarlar/tanı, dosya/diff/bağlam, hafıza/geçmiş ve komut/operation/session kontrolleri aynı malzemeyi kullanıyor. Native kontrol tipleri/callback/key/gating korundu. Eski message input’un bağımsız gölge painter’ı kaldırıldı ve ortak sisteme bağlandı.

İlk analyzer aşaması yalnız yeni testte deprecated/yanlış dışa açılmış semantics API kullanımını buldu; test güncel enabled-state conversion’a geçirildi. Son analiz **temiz**. Seri tüm Flutter suite **187/187 geçti**; yeni light/dark pressed/focus/disabled/text/submit regresyonları dahil. Ürün screen widget’larını kullanan geçici native debug harness **başarıyla derlendi**, 41,7s Gradle; bounded servis toplam1m53s, peak1,5GiB. Native telefon görsel/IME matrisi tamamlandı; gerçek Samsung kontrolü ve bağımsız inceleme sonucu aşağıda ayrı kaydedildi.

Kontrast hesabı: koyu ana metin/raised12,26:1, ikincil/base8,71:1, amber/inset9,98:1; açık ana/raised12,53:1, ikincil/inset5,60:1, amber/inset5,52:1. Bu hesaplar author token çiftleri için; fiziksel TalkBack veya bütün semantik state renklerinin ekran ölçümü değildir.

Kullanıcı exact yeni **Android1.2.0(9)** için testler sonrası same-signer kurulum ve native kontrol onayı verdi, telefonu boş bıraktığını belirtti. Başlangıç kurulu sürüm1.1.4(8), ilk kurulum17Ekim20:01:38; uninstall/data-clear/re-pair/gerçek mesaj/izin yanıtı kapsam dışı ve yapılmayacak.

Native geçici fixture kontrolü ilk turda proje, konuşma/IME, karar, ayarlar, pairing ve tanı ekranlarını açtı. Ekranın altındaki fixture menü satırı navigation-bar sınırına denk geldiğinden sürücü home’a çıktı; uygulama crash’i değildi, PID canlı ve scoped error boş. Hedef sınırı güvenli içerik bölgesine alındı. İlk `dark-files`/home yakalaması silindi; geçerli dosya capture’ı tekrar çekilip incelendi. Yanlış yakalama kabul kanıtına dahil edilmedi.

Telefon native matrix: koyu proje/konuşma/IME/karar/ayar/pairing/tanı/dosya/fark/hafıza/komut/operation/görev/ajan, açık proje/karar/ayar/yeni-oturum ve %200 koyu karar/konuşma/IME yakalanıp incelendi. Fixture yalnız yerel sentetik veri ve gerçek ürün widget’ları; production varsayılanı değil. Son app PID error okuması boş. Ana gezinmenin inset selected göstergesi ve sabit content alanı native görüntüde görüldü. Kullanıcının kapsam daraltmasından önceki tablet resize denemesinde QEMU main-loop/graphics-context hang ile owned emülatör kapandı; uygulama hatası veya tablet kabulü sayılmadı. Kullanıcı tablet kapsamını kapattı, tekrar denenmedi.

## Kullanıcı kapsam kararı — yalnız telefon

Kullanıcı tablet çalışmasını açıkça durdurdu: “tableti bosver simdi sadece telefon uzerinden yap build ve testleri”. Sonraki build/test/native kabul yalnız telefon içindir. Tablet denemesi tekrarlanmadı ve bu teslimde tablet desteği sertifikası verilmez. Bağlı Samsung üzerinde exact release APK, native gezinme/ayarlar/konuşma ve IME kontrolü tamamlandı.

## Telefon release kimliği

Ürün `lib/main.dart` entrypoint’inden Android1.2.0/code9 release başarılı: Gradle278,6s; bounded servispeak2,5GiB. Özgün APKv2 signer `6ed5f72965a3a883055898632494cdd23f2f0aa50393ac10959caeecd0e2f2a1`; paket55.971.889byte, SHA256 `f2515a1e402a2603a9cbdd8c7165935e001d8d35f537cf33be2ffdd53e46ddfc`. Kullanıcının exact onayıyla Samsung’a `install -r` Success. Kurulu base APK geri çekilip hash birebir doğrulandı;1.2.0(9), son güncelleme13Kasım14:03:41, ilk kurulum17Ekim20:01:38 aynı. Eşleştirme/app verisi silinmedi. Aynı byte’lar `dist/omputer-android.apk` konumuna kabul sonrası kondu; SHA256SUMS ve build-info güncellendi.

## Bağımsız profesyonel inceleme ve fiziksel telefon kabulü

Bağımsız read-only reviewer **ship — phone-only finish review** döndürdü:20 gerekli phone screenshot’u, native floor/platform ve kaynak örnekleri üzerinde maddi blocker bulmadı. İnceleme; type/material/ground, açık-koyu tutarlılık,48dp hedeflerin kaynak karşılığı, native kontrol tipleri ve %200/IME ilk viewport’larını kapsar. Reviewer gerçek Samsung’u kullanmadı; aşağıdaki fiziksel sonuçlar bu ana çalışmanın doğrudan gözlemidir. %200 karar görüntüsü ilk viewport’tur, büyük yazıyla submit akışının tamamının fiziksel kabulü değildir. Statik görüntü motion smoothness veya TalkBack sertifikası değildir.

Samsung16’da güncel gruplu Ayarlar ekranı **Bağlı / Önbellek güncel / Canlı bağlantı açık** gösterdi. Gelen kutusu ve inset arama/switch yüzeyi incelendi. Proje aramasına yalnız `omputer` yazılarak gerçek session tam kimliğiyle açıldı; arama sonradan temizlendi. Konuşmanın boş taslağına yalnız odak verildi: native IME görünür, editör `[56,1097][855,1254]`, `focused=true`, metin boş kaldı. Girdi/gönder klavye üstündeydi. Son app PID kapsamlı Flutter/AndroidRuntime error okuması boş. Back ile dönüldü. Gerçek mesaj, karar, izin, komut veya yeni session gönderilmedi; eşleştirme ve native izinler değiştirilmedi. Font1.0/gece modu açık/animator0.5 aynen korundu.

### Seçilmiş kanıt

- [Telefon kabulü ve exact paket](../Kanitlar/2026-11-13/neumorphic-system/fiziksel-kabul.json)
- [Test/native inceleme özeti](../Kanitlar/2026-11-13/neumorphic-system/sonuclar.json)
- [Fiziksel giriş ve IME kontrolü — içeriksiz crop](../Kanitlar/2026-11-13/neumorphic-system/fiziksel-input-ime.png)
- [Fiziksel inbox kontrolleri — içeriksiz crop](../Kanitlar/2026-11-13/neumorphic-system/fiziksel-inbox-kontrolleri.png)
- [Koyu ayarlar — sentetik native](../Kanitlar/2026-11-13/neumorphic-system/dark-settings.png)
- [Açık karar — sentetik native](../Kanitlar/2026-11-13/neumorphic-system/light-decision.png)
- [%200 klavye — sentetik native](../Kanitlar/2026-11-13/neumorphic-system/dark-large-session-ime.png)

Tam fiziksel ekranlarda kişisel proje/oturum/ağ bilgileri vardı; yalnız özel geçici yerde incelendi ve silindi. Kalıcı native örnekler sentetik; fiziksel crops konuşma, iç adres, cihaz seri veya credential içermez. Yeni rapor/evidence izinleri özel, mevcut proje kökü izinleri değişmedi.

## İşletim, korunmuş sınırlar ve kalan kapsam

Plan→execute→native test→bağımsız review→onaylı telefon güncellemesi tamamlandı. Ortak sistem `DESIGN.md` ve `.impeccable/design.json` içinde authored token’larla kaydedildi. İlgili Emil/Impeccable/Taste/Unslop ve motion/performance/native/a11y/stress rehberleri tek yönde uygulandı; pazarlama görseli, ücretli üretim, yeni dependency/MCP ve browser ayarı yok. Değişmeyen PC/bridge/Rust/Kotlin ürün kodu ve çalışan daemon aynı kaldı. Ek güvenlik/model işlemi yapılmadı; bu yerel vault bir backup/şifreleme veya cloud sync iddiası değildir.

Geçici harness `neo_preview.dart`, özel AVD/test sürücüleri ve özel fiziksel raw ekranlar temizlendi; üretim entrypoint `main.dart`. Commit/push yapılmadı. Geri alma çalıştırılmadı: Android downgrade reddedilebilir, uninstall/data-clear önerilen geri alma değildir. Mevcut veriyi korumadan sürüm düşürme denenmemelidir.

İstenen telefon kapsamı için açık zorunlu adım yok. Fiziksel TalkBack/Doze/pil/FPS, tam reduced-motion donanım akışı ve model-backed teslim kabulü yapılmadı; tablet kullanıcı isteğiyle kapsam dışı.187 test ve reviewer ship bu sınırların yerine sunulmaz.

## Kullanıcının commit/push talebi

Sonradan verilen açık commit/push isteğinin hedefi mevcut `origin/main` (`altifilius/omputer`). Yayın kapsamı bu çalışmanın neumorphic UI, dönen proje/çalışan avatar bileşenleri, ilgili testleri, tasarım sistemi ve bu üç UI raporunun gizlilikten geçirilmiş kanıtlarıdır. Önceden bekleyen PC/Rust/bridge/Kotlin güvenilirlik, controller/model/restore/yeni-session taslak düzeltmeleri, PLAN ve eski inceleme/altyapı raporları dahil edilmez; çalışma ağacında korunur. Aynı dosyaya karışmış önceki hunk’lar index’te ayrılır, kullanıcı dosyaları geri alınmaz.

Yukarıdaki187 test ve telefona kurulan APK gerçek birleşik çalışma ağacına aittir; yalnız seçilen UI commit’inin temiz checkout’u ile yeniden build/test yapıldığı veya byte-byte APK üretildiği iddia edilmez. `dist/`, signing key/config, geçici browser logları, tam kişisel telefon ekranları/ham dump’lar gönderilmez. Git yayını APK GitHub Release yüklemesi değildir. Commit imzalama mevcut ayarla korunur; push sonucu tamamlandıktan sonra bu kayda bağlanır.

### Gerçek yayın sonucu

Kaynak/tasarım commit’i **[`3c0d38a9557a5ecac9fbdbefc9f32bde4e99d1c8`](https://github.com/altifilius/omputer/commit/3c0d38a9557a5ecac9fbdbefc9f32bde4e99d1c8)** — `feat(android): unify neumorphic UI and rotating project navigation`. Toplam67 seçili dosya; mevcut GPG imzası doğrulama durumu **G**. `git push origin main` başarılı; bağımsız `git ls-remote origin refs/heads/main` aynı tam hash’i verdi.

Eklenen satırlar hassas-işaret kontrolünden, staged JSON/rapor/capture bağlantıları bütünlük kontrolünden geçti. Daha önce HEAD’de bulunan eski özel-IP satırları yeni içerik değildir ve bu dar commit’te yeniden yazılmadı. Önceki backend, Kotlin/bridge, controller/model, restore/yeni-session ve PLAN değişiklikleri commit’e alınmadı; kullanıcı çalışma ağacında kaldı. Build/testler yalnız commit/push için tekrar çalıştırılmadı; önceki doğrulama kapsamı aynen yukarıdadır. Bu sonuç kaydı ayrı imzalı dokümantasyon commit’iyle aynı dala gönderilir; kaynak commit’i amend edilmez.
