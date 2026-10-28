---
title: "Omputer — Mobil paralel oturumlar ve alt mesaj alanı"
project: omputer
type: project-report
date: "2026-10-28"
status: tamamlandi
tags:
  - proje-raporu
  - android
  - mobil-arayuz
---

# Omputer — Mobil paralel oturumlar ve alt mesaj alanı

[Proje sayfası](../README.md) · [Rapor dizini](README.md) · [Projects ana sayfası](../../README.md)

## Amaç ve sonuç

Kullanıcının iki mobil sorunu düzeltildi: aynı projedeki paralel oturumların yalnız proje adı/tek kısayolla görünmesi ve mesaj yazma bölümünün ekranın ortasında kalması. **Android 1.1.2 (6)**, mevcut yayın imzasıyla `dist/omputer-android.apk` konumunda hazırdır. Bu raporun durumu kaynak düzeltmesi, test, native emülatör kontrolü ve kurulabilir paket teslimini kapsar; fiziksel telefona kurulum yapılmadı.

- Aynı proje altındaki açık oturumlar ayrı, kimlikleri ayırt edilebilir ve doğrudan seçilebilir satırlar olarak gösteriliyor.
- Terminalde açık fakat telefon köprüsü olmayan oturumlar da listeleniyor; bunlara mesaj/sürdürme yetkisi verilmedi.
- Yazma alanı ve gönder düğmesi kullanılabilir ekranın altında, klavye açıldığında klavyenin üstünde kalıyor. Ek araçları ve görseller yazma alanından bağımsız kayıyor.
- **151 Flutter testi geçti**, analiz temiz; native Android35 emülatöründe gerçek yazılım klavyesi ve %200 sistem yazı boyutu kontrol edildi.

## Kök nedenler ve uygulanan değişiklikler

| Konu | Önceki davranış | Uygulanan çözüm |
|---|---|---|
| Proje ana listesi | `ProjectOverviewRow` bütün oturumları biliyor fakat tek `recent` kısayolu çiziyordu. | Her açık oturum kendi `Session.id` anahtarlı `LocalSessionRow` satırına sahip. Kapalı geçmiş proje detayında kalıyor; açık oturum yoksa son geçmiş kısayolu korunuyor. |
| Aynı oturum adları | Sadece ad/durum bilgisi kimlikleri ayırmayı zorlaştırıyordu. | En az sekiz karakterden başlayan ve çakışmada uzayan görünür oturum kimliği son eki gösteriliyor. Satır tam kimlikle açılıyor. |
| Terminal oturumları | `active-unbridged` kayıtları `transport: archive` nedeniyle sıradan geçmiş filtresine düşebiliyordu. | Açık liste/filtre sınıflaması terminalde açık kayıtları kapsıyor; `Session.archived`, canlı yazar, yetenek ve güvenli sürdürme modeli değiştirilmedi. |
| Mesaj alanı | Gevşek `Flexible(flex: 2)` alanı ile konuşma arasında oranlı yükseklik paylaşımı altta boşluk bırakıyordu. | Konuşma kalan alanı alıyor; boyutu sınırlı composer alta yerleşiyor. Editör/gönder kaydırılan araçlardan ayrı. |
| Küçük ekran ve klavye | Gerçek klavye + model bilgisi açıkken ilk düzeltmedeki metin kutusu fazla daralıyordu. | Başlık/durum/model bölümü sınırlı kaydırma alanına alındı; editör satırına okunabilir yükseklik bırakıldı. IME boşluğu ikinci kez eklenmedi. |

Değişen uygulama dosyaları: `mobile/lib/projects.dart`, `mobile/lib/main.dart`, `mobile/lib/session.dart`, `mobile/pubspec.yaml`. Regresyon kapsamı: `mobile/test/navigation_acceptance_test.dart`, `mobile/test/project_workflows_test.dart`. Mevcut tasarım, Türkçe metinler, Material 3 kontrolleri, taslaklar, ekler, komutlar, prompt/steer/follow-up ve kesme akışları korunuyor.

README, değişiklik günlüğü, mobil sözleşme, tasarım açıklaması ve sürüm/dağıtım metaverisi güncellendi. Bu çalışmada commit veya push yapılmadı.

## Kararlar ve ödünleşimler

- **Proje gruplaması korundu.** Projeyi her oturum için tekrar etmek yerine oturumlar proje altında gösterildi. Geçmişin tamamını ana ekrana yığmak yerine proje detayına erişim korundu.
- **Oturum kimliği anahtar olmaya devam ediyor.** Aynı ad veya proje adı oturumları birleştirme ölçütü değil. Kararlı sıra mevcut `StableActivityOrder` ile korundu; token güncellemeleri satırları taşımıyor. Aramada aynı açık satır ikinci kez çizilmiyor.
- **Sunucu değişikliği yapılmadı.** Sınırlı salt okunur SQLite sorgusu Omputer projesinde iki farklı çalışan bridge kimliği ve iki farklı terminalde açık journal kaydı bulunduğunu gösterdi. Sorun mobil görünürlükteydi; üretim oturum içerikleri kopyalanmadı veya değiştirilmedi.
- **Yeni composer bileşen sistemi/animasyon eklenmedi.** Yerel Flutter kısıtları ve ayrı kaydırma alanları kullanıldı. Çok kısa ekranda konuşma/araçlara daha az yer kalabilir; öncelik metin yazıp gönderebilmek. Ek kontroller silinmedi.
- **Görsel kontrol native yapıldı.** Uygulama web değil; tarayıcı görüntüsü Android klavyesini kanıtlamaz. Geçici `NativeAdapter` yalnız bilinen test kayıtlarıyla gerçek Flutter ekranlarını Android'de çalıştırdı. Üretim varsayılanı veya yayın giriş noktası değiştirilmedi.

## Çalıştırılan doğrulama

### Otomatik kontroller

`omputer-mobile-final-checks-oct28-uTt3BL.service` içinde:

- `flutter analyze --no-pub`: sorun yok.
- `flutter test --no-pub --concurrency=2 --reporter=expanded`: **151/151 geçti**.
- Paralel aynı adlı bridge ve terminal oturumlarının tam kimlikle seçimi, kararlı sıra, filtre/arama, geçmişe erişim ve salt okunur sınırlar test edildi.
- Normal/kısa ekran, sistem üst-alt boşlukları, yüksek klavye, %200 yazı, model bilgisi, boş/uzun geçmiş, çoklu ek ve çok satırlı taslak/gönder davranışları kapsandı.
- İlk yeni test koşusunda test hedefi belirsizliği ve semantics temizliği sorunları vardı; hedefler düzeltilip son tam koşu geçirildi. Başarısız ilk koşu tamamlanmış doğrulama olarak sayılmadı.
- Impeccable manuel detector, değişen üç Dart arayüzü için `[]` döndürdü. Bu sonuç native erişilebilirlik sertifikası değildir.

### Native Android kontrolü

Sahip olunan, başsız Android35 emülatörü; 720×1280 piksel, 320 dpi. Geçici adaptörün kayıtları kişisel veri içermedi; PC bağlantısı, sağlayıcı çağrısı veya gerçek komut gönderimi yoktu.

- Aynı adlı A ve B satırları sırasıyla doğru tam oturum kimlikleriyle açıldı; ayrı metinler yazıldı ve A'ya dönünce A taslağı korundu.
- İki `active-unbridged` terminal oturumu doğru kimlikle açıldı; yazma alanı sunulmadı.
- Gerçek Android yazılım klavyesi açıldı, metin yazıldı, araç alanı kaydırıldığında editörün konumu sabit kaldı.
- Klavye açık son editör sınırları `(32,522)–(568,634)`; %200 sistem yazı boyutunda `(32,466)–(568,634)` gözlendi. Bunlar emülatör fiziksel piksel ölçüleridir, dp sabitleri değildir.
- Son uygulama PID'sinin `flutter:E` / `AndroidRuntime:E` okuması boştu. Bu, tüm Android sisteminin hatasız veya emülatörün performans garantili olduğu anlamına gelmez.
- İlk emülatör denemesi kaynak sınırı altında başarısız oldu; küçük ekranlı ikinci profil sınırlı kaynakla çalıştı. Açılış sonrası sistem arayüzü bekleme diyaloğunda **Wait** seçildi. Kullanıcının masaüstü veya compositor'ü üzerinde deney yapılmadı.
- Ek yerleşimi, geçici görselin çözücü hata durumu ile de kontrol edildi. Gerçek galeri/kamera/paylaşım ve telefon-PC görsel teslimi bu senaryoda doğrulanmadı.

### Seçilmiş ekran kanıtları

Kanıtlar yalnız yerel UI test kayıtları ve emülatörün sistem çubuğunu içerir; gerçek kullanıcı konuşması, erişim sırrı veya ağ adresi içermez. Paylaşım öncesi yine gözden geçirilmelidir.

- [Aynı proje altında iki ayrı oturum](../Kanitlar/2026-10-28/home-two-same-project-sessions.png)
- [Klavye kapalı alt yazma alanı](../Kanitlar/2026-10-28/final-composer-keyboard-closed.png)
- [Klavye açık alt yazma alanı](../Kanitlar/2026-10-28/final-composer-keyboard-open.png)
- [%200 yazı ve gerçek yazılım klavyesi](../Kanitlar/2026-10-28/final-200font-keyboard.png)
- [İki ayrı terminalde açık salt okunur oturum](../Kanitlar/2026-10-28/final-terminal-parallel-rows.png)

## Paket ve kurulum

`omputer-android-112-oct28-uTt3BL.service`, üretim `lib/main.dart` giriş noktasından `flutter build apk --release --no-pub --target-platform android-arm64,android-x64 --target lib/main.dart` çalıştırdı. Gradle 268,2 saniyede tamamlandı; gözlenen bellek tepe değeri 2,3 GiB. Derlemeler, testler ve emülatör kaynak baskısını azaltmak için sırayla yürütüldü.

| Özellik | Gözlenen değer |
|---|---|
| Dosya | `dist/omputer-android.apk` |
| Android sürümü | `1.1.2`, kod `6` |
| Paket | `dev.omputer.omputer` |
| Boyut | 55.840.617 bayt |
| SHA-256 | `ae2844ef7e802fed97936f38fd9a770fd333a4518f3aced3e825cc718b44fdcd` |
| İmza | Önceki özgün yayın sertifikasıyla aynı; `apksigner verify` başarılı |
| Fiziksel telefon | ADB'ye bağlı cihaz yok; kurulum yapılmadı |

APK mevcut uygulamanın üzerine aynı imzayla güncellenebilir; kaldırma/veri temizleme gerekmez. Doğru telefona kurup sürümün **1.1.2 (6)** olduğunu kontrol etmek ve iki gerçek oturum/klavye akışını cihazda denemek kalan fiziksel kabul adımıdır. Burada yapılmış gibi sunulmadı.

## Korunan ayarlar, temizlik ve riskler

PC 0.2.0, bridge 1.1.0, model sağlayıcı ayarları, telefon eşleştirmesi, TLS sabitleme, cihaz yetkilendirmeleri, geçmişler, NetBird/VPN ve firewall değiştirilmedi. Üretim servis veya gerçek OMP oturumları durdurulmadı/yeniden başlatılmadı. Üretim veri tabanına yazılmadı. Yalnız mobil kaynak ve paket güncellendi.

Sahip olunan emülatör kapatıldı ve özel AVD kaydı silindi. Geçici debug uygulaması/adaptör/sürücüler yayın paketine dahil edilmedi; geçici dosyalar temizlendi. Kalıcı kanıt yalnız yukarıdaki seçilmiş görüntülerdir. Yeni rapor ve kanıt dizinleri `0700`, dosyaları `0600` tutulur; proje kökü veya diğer kaynakların izinleri değiştirilmez.

Geri alma gerekiyorsa aynı yayın imzasına ait önceki güvenilir paket/kaynak kullanılmalı; Android sürüm düşürmeyi varsayılan olarak engelleyebilir. Veri temizleme veya kaldırma bu çalışmanın geri alma yöntemi değildir. Geri alma kurulumu denenmedi. Önce gerekli yerel verinin korunması sağlanmalıdır.

## Test edilmeyenler ve kalan işler

- Fiziksel telefonda aynı-imzalı kurulum ve kurulu APK hash/sürüm okuması; gerçek OEM klavye ve jestler.
- Bu sürümle canlı telefon-PC mesaj teslimi, fiziksel galeri/kamera/paylaşım, tablet/yatay ekran, TalkBack ve sistem animasyon azaltma kabulü.
- Değişmeyen Rust/Kotlin/bridge testleri bu mobil arayüz düzeltmesi için yeniden koşulmadı; önceki kayıtlar yeni doğrulama değildir.
- Impeccable tasarım yan dosyası önceden güncel değildi; bu kapsamda yeniden üretilmedi. Global tasarım aracının güncellemesi yapılmadı.

## İlgili kayıtlar

- [Sürüm doğrulama kaydı](../VERIFICATION.md)
- [Değişiklik günlüğü](../CHANGELOG.md)
- [Mobil sözleşme](../MOBILE-CONTRACT.md)
- [Projects kök vault kararı](../../Raporlar/2026-10-28-projects-kok-vault-duzeni.md)
