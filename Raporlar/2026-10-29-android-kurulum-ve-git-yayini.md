---
title: "Omputer — Fiziksel Android kurulumu ve Git yayını"
project: omputer
type: project-report
date: "2026-10-29"
status: kurulum-tamamlandi
---

# Omputer — Fiziksel Android kurulumu ve Git yayını

[Proje sayfası](../README.md) · [Rapor dizini](README.md)

## Amaç ve kurulum sonucu

Kullanıcı USB ile bağlı telefona önceki mobil düzeltmelerin kurulmasını, ardından commit ve push yapılmasını istedi. **Samsung SM-G990E, Android 1.1.0 (4) sürümünden 1.1.2 (6) sürümüne veri koruyan güncelleme ile geçirildi.** Mevcut uygulama kaldırılmadı; veri temizliği, yeniden eşleştirme veya yeni izin verme işlemi yapılmadı.

Önceki çalışma: [28 Ekim — paralel oturumlar ve alt mesaj alanı](2026-10-28-mobil-oturumlar-ve-mesaj-alani.md). O raporun kurulmamış durum kaydı tarihsel olarak korunur; bu rapor fiziksel kurulumun sonraki kanıtıdır.

## Doğrulama

| Kontrol | Gözlenen sonuç |
|---|---|
| Güncelleme | `adb install -r dist/omputer-android.apk` → `Success` |
| Kurulu sürüm | Package Manager: `1.1.2`, sürüm kodu `6` |
| Tam kurulu APK | SHA-256 `ae2844ef7e802fed97936f38fd9a770fd333a4518f3aced3e825cc718b44fdcd`; yayımlanan APK ile birebir aynı |
| İmza ve uygulama verisi | Özgün yayın sertifikası doğrulandı; ilk kurulum kaydı aynı; kayıtlı projeler uygulamada açıldı |
| Oturum seçimi | Aynı projedeki iki mevcut canlı oturum kısa kimlikleriyle ayrı seçildi ve sohbet ekranları açıldı |
| Gerçek Samsung klavyesi | Yazma alanı klavye kapalıyken `(45,2149)–(866,2306)`, açıkken `(45,1108)–(866,1265)`; ekran 1080×2340 piksel |
| Taslak/mesaj | Mevcut taslak değiştirilmedi; metin girilmedi, model istemi veya başka komut gönderilmedi |
| Hata gözlemi | İncelenen uygulama PID'sinin `flutter:E` / `AndroidRuntime:E` okuması boş |
| Telefon ayarları | Yazı ölçeği 1.0 kaldı; ağ/VPN, arka plan ve eşleştirme ayarları değiştirilmedi |

Telefonun ilk açılışı kısa süre kayıtlı/çevrimdışı görünüm gösterdi. İki canlı oturumun gerçek ekranları açıldı; bu kontrol ağ teslimi, yeniden bağlanma süresi veya soğuk başlangıç sertifikası değildir. Samsung klavyesi açık/kapalı ekranları incelendi; kişisel konuşmaları ve cihaz kimliklerini içerdikleri için görüntüler ve ham UI ağaçları kalıcı rapora veya herkese açık GitHub deposuna alınmadı.

## USB bağlantısı ve güvenlik kararı

Telefon USB aygıt listesinde ve ADB arabiriminde görünüyordu, fakat ortak sistem ADB sunucusu cihazı listelemiyordu. Dosya izinleri yeterliydi. Ortak sunucuyu öldürmek veya bütün USB aygıtlarını sıfırlamak yerine, mevcut SDK'nın belgelenmiş libusb backend'iyle yalnız bu telefona sınırlı, özel Unix soketli bir ADB sunucusu kullanıldı. Var olan ADB güven ilişkisiyle yetkili bağlantı kuruldu; USB hata ayıklama güvenliği değiştirilmedi.

PC servisi, üretim OMP oturumları, TLS kimliği, cihaz yetkileri, firewall ve VPN değiştirilmedi. Uygulama güncellemesi dışında telefon verisine bakım uygulanmadı. Test bitiminde telefonda yalnız bize ait geçici UI dökümü kaldırıldı; özel ADB sunucusu kapatıldı ve yerel kişisel ekran dökümleri temizlendi. Ortak ADB sunucusu korundu.

## Git yayın kapsamı

Depo kayıtları ve GitHub API ile doğrulanan hedef: **[altifilius/omputer](https://github.com/altifilius/omputer)**; dal **`main`**, görünürlük **public**. Push adresi `git@github.com:altifilius/omputer.git`. Kullanıcı commit/push talimatını bu çalışma için açıkça verdi.

Commit kapsamı mobil oturum/composer düzeltmeleri, sürüm ve ilgili test/doküman/kurulum kayıtlarıdır. Önceden değişmiş `PLAN.md` ve geçici `.playwright-mcp/` dosyaları kapsam dışıdır; silinmez veya başka değişikliklerle birleştirilmez. `dist/` mevcut Git dışlama kuralı nedeniyle kaynak commit'ine eklenmez; kullanıcı GitHub Release yüklemesi istemedi. Yerel APK telefona kurulmuştur.

Bu kayıt kurulumdan sonra, Git yayın komutundan önce hazırlanmıştır. Git teslim sonucu komut çıktısı ve uzak dal kimliği ile ayrıca kaydedilir; bu cümle henüz gerçekleşmemiş push'u başarılı diye sunmaz.

## Doğrulama sınırları

- APK yeniden derlenmedi; bu, önceki analiz ve 151 testlik koşudan geçen dosyanın birebir kendisidir. Önceki testler bugün yeniden çalıştırılmış gibi sayılmadı.
- Bu sürümle gerçek istem/ek gönderimi, bildirim, Doze, pil, fiziksel %200 yazı, yatay/tablet/TalkBack ve soğuk başlangıç zamanı denenmedi.
- İlk kurulum kaydı ve kayıtlı görünüm korunması gözlendi; tüm özel uygulama dosyalarının byte-byte karşılaştırması yapılmadı.
- Geri alma kurulumu denenmedi. Android sürüm düşürmeyi engelleyebilir; kaldırma/veri temizleme varsayılan geri alma yolu değildir.

## İlgili kayıtlar

- [Önceki mobil düzeltme raporu](2026-10-28-mobil-oturumlar-ve-mesaj-alani.md)
- [Doğrulama kaydı](../VERIFICATION.md)
- [Değişiklik günlüğü](../CHANGELOG.md)
