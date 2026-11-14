---
title: Omputer — HTML-form OMP sorularının Android’e iletimi
project: omputer
type: project-report
date: 2026-11-13
updated: 2026-11-14
status: kismi
---

# HTML-form OMP sorularının Android’e iletimi

[Proje](../README.md) · [Rapor dizini](README.md)

## Amaç ve sonuç

Kullanıcı PC’de üretilen çoktan seçmeli OMP sorularının Android Omputer’e ulaşmadığını bildirdi. Bağlantıyı, soru sözleşmesini ve yanıt dönüşünü inceleyip düzeltmek istedi.

**Bu rapor 13–14 Kasım’daki bridge 1.1.2 soru iletimi düzeltmesini ve kaynak yayınını kaydeder.** Kaynak düzeltildi, köprü yan yana kuruldu ve fiziksel Samsung’dan yanıt PC’deki AskTool’a döndü. İmzalı kaynak ve yayın-sonucu commit’leri `origin/main` dalına gönderildi. Son işletim kontrolünde eski modülü yüklemiş açık terminal süreçleri yeniden başlatılmamıştı; bu süreçlerde güvenli `/restart` hâlâ gerekliydi. Bu vault güncellemesi süreçlerin sonradan yeniden başlatıldığını doğrulamaz.

Bu çalışma Android APK’sını, eşleşmeyi, PC daemon binary’sini ve bundled OMP’yi değiştirmedi. Çalışmanın tamamlandığı aşamada `dist/Omputer` bridge 1.1.1 paketiydi; bu düzeltme için yeni dağıtım paketi üretilmedi. Daha sonraki eşzamanlı 1.2.0 kontrol/kuyruk çalışması ve Android palet teslimi bu raporun sonucu değildir; kendi raporlarında izlenir.

## Neden

- Kurulu terminal OMP **18.20.0**. Yerel güncelleme kaydı 18.19.0→18.20.0 geçişini gösteriyor.
- Omputer bundled RPC runtime **18.10.2**, PC **0.2.1**, eski bridge **1.1.1**. Bunlar terminal OMP sürümünden ayrı.
- Telefon mevcut eşleşmeyle **Bağlı**; eski `select` etkileşimleri serviste mevcut. Ağ kopması ana neden değil.
- Yeni AskTool önce `ui.formDialog` arıyor. Köprü sadece `select`, `confirm`, `input`, `editor`, `askDialog` yöntemlerini sarıyordu. Bütün-form yöntemi bu yüzden telefona ilan edilmeden terminalde açılıyordu.

## Uygulanan dar değişiklik

`bridge/dialogs.ts` bağlı, yönetilmeyen terminalde mevcut opsiyonel `formDialog` yöntemini getter üzerinden geçici olarak `undefined` gösteriyor. Böylece OMP’nin **kendi kanonik alan alan form yürütücüsü** mevcut köprülenmiş `select`/`input`/`editor` yöntemlerini çağırıyor. Disconnected durumda özgün tam-form yöntemi kullanılabilir; teardown özgün descriptor’ı geri getirir. Managed RPC yüzeyi değişmez, eski host’a olmayan yöntem eklenmez.

HTML ayrıştırma, seçenek etiketi→gerçek value dönüşümü, sayılar, required/min/max/pattern, önseçimler, Other ve çoklu seçim OMP’ye ait kalır. Yeni HTML/WebView yürütücüsü, uzak kaynak veya ağ servisi eklenmedi.

**Ödünleşim:** tek bütün form yerine sorular sırayla gelir. Çoklu seçimde seçenekler aç/kapa ve son Done satırı vardır. Tam-form önizleme ve seçeneğe özel not bu yolda yoktur; resmî OMP fallback davranışıdır. Bağımsız HTML parser/renderer eklemek, iki farklı doğrulama sözleşmesi yaratacağından seçilmedi.

Eklenen iki bridge regresyonu connected/disconnected/restoration, managed RPC ve legacy host sınırlarını kapsar. Paket tanımı bridge **1.1.2** olarak ayrıldı. README, PROTOCOL, CHANGELOG ve VERIFICATION güncellendi.

## Kurulum ve bütünlük

İlk doğrulama sırasında kurulu dosyaya uygulanan geçici hotfix, eski release’in içerik-hash sözleşmesini bozmasın diye özgün dosyalarıyla geri getirildi. Eski release’in tam bundle digest’i tekrar özgün kimlikle eşleşti:

`1d9b58b330239b115ab543d0d06c68b70a3224f69b3dd7a224d1f9f4c999945a`

Aynı PC binary/runtime + yeni bridge ile yan yana, özel izinli kurulum oluşturuldu. Makineye özgü kurulum yolu kamuya açık rapordan çıkarıldı.

Release marker, `install.json` ve atomik `app/current` bağlantısı aynı yeni digest’i gösteriyor; tam hash doğrulaması geçti. Kaynak/kurulu `dialogs.ts` aynı. Eski release korundu; daemon hâlâ eski release’in mevcut PID875 binary’siyle çalışıyor. Binary ve runtime byte’ları değişmedi, servis/terminal yeniden başlatılmadı. Sistem servis/desktop/loader managed hash kayıtları korundu.

## Gerçek doğrulama

| Kontrol | Gözlenen sonuç |
|---|---|
| `bun test bridge/dialogs.test.ts bridge/lifecycle.test.ts` | 10 pass, 0 fail, 74 assertion; yaklaşık 2s |
| Kurulu OMP18.20.0 gerçek AskTool, radyo+sayı formu | `choice:"two"`, `count:7`; etiket `İki` gerçek değere çevrildi, bağlam korundu |
| Gerçek UnixIPC→üretimdaemon→eşleşmişSamsung→yanıt→AskTool | `{"delivery":"received"}` döndü |
| Kalıcı komut sonucu | `interaction.respond`: status `succeeded`, success true; soru `resolved` |
| Kurulum | Yeni tam bundle digest, release marker, current ve install metadata eşleşti; özgün release bütünlüğü de doğrulandı |

Gerekli içeriksiz/sentetik kanıtlar:

- [Gerçek OMP form sonucu](../Kanitlar/2026-11-13/soru-iletimi/omp-form-sonucu.json)
- [Telefon yanıtının AskTool sonucu](../Kanitlar/2026-11-13/soru-iletimi/telefon-yanit-sonucu.json)

Telefon harness’i yalnız bu sentetik test sorusuna dokunacak şekilde sınırlandı. Son denemede test zaten yanıtlanmıştı; script beklediği seçenek yerine yeniden Gelen kutusu gördü ve ilgisiz kararları seçmeden durdu. **Son yanıtı otomasyonun bastığı iddia edilmez.** Aynı AskTool’un aldığı sonuç ve kalıcı başarılı komut dönüşü uçtan uca teslim kanıtıdır. Son seçimin tıklanma anını gösteren ekran tutulmadı; diğer oturumlara ait kişisel ekran/XML/loglar rapora eklenmedi.

Atılan harness denemeleri: headless primitive’in anında undefined dönmesi, startup-handler30s sınırı, stdin EOF ve süreç yaşam döngüsü. Ürün hatası veya başarılı test diye sayılmadı. Cua X11 erişilemez hatası verdi; ancak bundan sonra yetkili USB telefonda native ADB ekran/XML kontrolü kullanıldı. Native Wayland/kompozitör ayarı açılmadı. Tam-suite veya yeni Android kabulü yapılmadı.

## Korunanlar

- Kimlik, TLS sertifikası, paired cihaz yetkisi, tokenlar ve port değişmedi; raporda secret yok.
- Telefon uninstall/data-clear/re-pair/install/izin işlemi yok. Başka eşzamanlı oturumların UI geliştirmeleri bu işin sonucu değildir.
- Provider/model isteği yok; yalnız gerçek yerel AskTool yürütüldü.
- Üretim servisinin restartı veya canlı writer’a ikinci writer açılması yok.
- Kullanıcının kompozitörü, VPN, firewall, MCP ayarları ve OMP binary’si değiştirilmedi.
- İlk uygulama aşamasında commit/push yapılmadı. Kullanıcının sonraki yayın talebi ve bu işe ait dar kaynak kapsamı aşağıda ayrılır; eşzamanlı başka kaynak yayını kendi raporuna aittir.

## İşletim, kalan sınır ve geri alma

1. **Açık eski OMP terminalinde iş durulduğunda `/restart` çalıştır.** Resmî komut normal teardown/flush ardından aynı launch flags ve kayıtlı session’ı restore ederek yeni modülü yükler. Çalışan işleri/asistanları kesmemek için otomatik uygulanmadı.
2. Yeni soru formu Gelen kutusuna alan alan gelir; yanıt sonraki alanı açar, son alandan sonra OMP sonuç JSON’unu alır.
3. Daha önce açılıp iptal olmuş/kapanmış sorular otomatik yeniden gönderilmez. Yeni soruda doğrula; stale kararları canlandırma.
4. Eski `dist/Omputer` açılıp tekrar kurulum yapılırsa eski bridge’i yeniden etkinleştirebilir. Yerel1.1.2 kurulumunu koru; dağıtım paketinin yeniden build’i bu oturumda yapılmadı.
5. Geri alma gerekirse bakım kilidi altında current/install metadata eski korunmuş release’e birlikte dönmeli; eski terminal modülleri yine normal restart ister. SQLite veya eşleşmeyi geri almak gerekmez. Geri alma uygulanmadı/test edilmedi.

Doze, arka planda gece boyunca bildirim, WAN, tüm form türleri ve platform matrisi bu dar kontrolün kapsamı değildir. Çoklu seçim/default doğruluğu kanonik host koduna dayanır; fiziksel telefonda bu tur yalnız tek radyo alanı yanıt dönüşü kanıtlandı.

## Kaynaklar

- [Resmî v18.20.0 AskTool](https://github.com/can1357/oh-my-pi/blob/v18.20.0/packages/coding-agent/src/tools/ask.ts)
- [Resmî v18.20.0 form veri kuralları](https://github.com/can1357/oh-my-pi/blob/v18.20.0/packages/tui/src/html-form/data.ts)
- [Resmî uzantı yükleme/yeniden yükleme sınırları](https://github.com/can1357/oh-my-pi/blob/v18.20.0/docs/extension-loading.md)
- [Resmî restart yaşam döngüsü](https://github.com/can1357/oh-my-pi/blob/v18.20.0/packages/coding-agent/src/modes/interactive-mode.ts)
- Önceki PC aktivasyonu: yerel `Raporlar/2026-11-05-pc-aktivasyonu-ve-telefon-kabulu.md`; bu soru düzeltmesinin kaynak yayın kapsamına alınmadı.

## 14 Kasım — Kullanıcının commit ve push talebi

Kullanıcı bu değişikliğin ilgili Markdown raporuna işlenmesini, ardından commit ve push yapılmasını açıkça istedi. Hedef mevcut `origin/main` — `altifilius/omputer`; GPG imzalama ayarı korunur, force-push veya amend yapılmaz.

Yayın kapsamı yalnız bu düzeltmedir: `bridge/dialogs.ts` içindeki bağlı-terminal `formDialog` yönlendirmesi, iki ilgili regresyon, bridge1.1.2 paket tanımı, PROTOCOL/README/CHANGELOG/VERIFICATION’ın bu işe ait bölümleri, bu rapor ve iki yalnız-sentetik JSON kanıtı. Rapor indeksine yalnız bu çalışma satırı alınır. Eşzamanlı bridge1.2.0 controls/secret-input/queued-prompt, Android paletleri, PC relocation ve diğer tamamlanmamış değişiklikler çalışma ağacında korunur; bu commit’e katılmaz.

Ortak dosyaların tümü körlemesine stage edilmez. Kaynak yayını temiz HEAD tabanı üzerine bu işe ait parçalar seçilerek hazırlanır; böylece bağımsız bridge1.1.2 commit’i daha sonraki1.2.0 geliştirmelerine bağımlı olmaz. Yerel kurulum ve tarihsel fiziksel doğrulama yukarıdaki kapsamıyla kalır; yayın yeni APK/PC paketi oluşturmaz ve açık terminal modüllerini yeniden başlatmaz.

Yayın öncesi HEAD tabanından ayrılan gerçek1.1.2 içeriğinde `bun test bridge/dialogs.test.ts bridge/lifecycle.test.ts` yeniden çalıştı: **10/10**, **74 assertion**, yaklaşık **2,19s**. Bu kontrol eşzamanlı1.2.0 değişikliklerini kullanmaz; önceki fiziksel telefon kabulü tekrar edilmiş gibi sunulmaz.

Yayımlanan iki JSON kanıtında kullanıcı konuşması, cihaz/oturum kimliği, özel adres, parola veya token yoktur. Makineye özgü kurulum hash’leri gizli erişim değeri değildir. Ham ekran/XML/log, APK/dist ve imzalama dosyaları bu yayına alınmadı. Gerçekleşen commit/push sonuçları aşağıda kayıtlıdır.

### Tamamlanan kaynak yayını

**[`d37f7a23dd31398242e1f9332b7761eb5e887338`](https://github.com/altifilius/omputer/commit/d37f7a23dd31398242e1f9332b7761eb5e887338)** — `fix(bridge): forward HTML-form questions to Android`. **11 dosya, 252 ekleme / 3 silme**; yukarıdaki dar kaynak, rapor ve yalnız-sentetik kanıt kapsamı. Commit GPG ile imzalandı; `git verify-commit` **Good signature** döndü. Bu yerel kriptografik doğrulamadır; GitHub Verified rozeti ayrıca sorgulanmadı.

SSH push **`58ca2ac..d37f7a2` → `origin/main`** başarılı. Bağımsız `git ls-remote origin refs/heads/main` aynı tam SHA’yı verdi; sonuç **14 Kasım 2026 01:13 +03:00** itibarıyla doğrulandı. Force-push, amend veya farklı uzak dal yok. İlk imza denemesi kilitli anahtar/pinentry ortamı nedeniyle zaman aşımına uğradı; HEAD değişmedi ve yalnız o denemenin boş index kilidi kaldırıldı. Mevcut imzalama ayarı kapatılmadan doğru terminal ortamıyla sonraki deneme başarılı oldu; parola alınmadı/kaydedilmedi.

Eşzamanlı1.2.0/Android/PC çalışma dosyaları ve index’teki ilgisiz kayıtlar korunarak yalnız seçili içerik yayımlandı. Bu kaynak yayını üretim daemon’ı, telefon verisi, kurulu APK veya açık OMP süreçlerini değiştirmedi. Açık eski terminal süreçleri için `/restart` ve eski `dist/Omputer` sınırları, son işletim kontrolünün açık kalan maddeleridir.

**[`9ff59d567e83969c78b62224f74177c68cb5f9bb`](https://github.com/altifilius/omputer/commit/9ff59d567e83969c78b62224f74177c68cb5f9bb)** — `docs: record signed question delivery source publication`. Kaynak commit’inin gerçekleşmiş yayın sonucunu aynı rapor ve proje rapor indeksine kaydeden ek belge commit’i. GPG **Good signature** doğrulandı; SSH push **`d37f7a2..9ff59d5` → `origin/main`** başarılı oldu. Push sonrasındaki bağımsız uzak dal sorgusu **01:14 +03:00** itibarıyla bu tam SHA’yla eşleşti. Bu, o andaki yayın kanıtıdır; uzak dalın daha sonra ilerlemediği iddia edilmez.

### Vault kapanış kaydı

Bu dosya çalışmanın tek kanonik raporudur. Projenin `Raporlar/README.md` indeksi ve yerel vault ana indeksi bu kayda bağlanır. Makineye özgü mutlak yollar kamuya açık rapordan çıkarıldı. İkinci rapor kopyası veya yeni proje dizini oluşturulmadı.

**Raporlama ve önceki commit/push talebi tamamlandı.** Genel `status: kismi` korunur: eski açık terminal modüllerinin etkinleşmesi ve yeni dağıtım paketi bu işte tamamlanmış gösterilmez. Yerel Obsidian Sync/Publish ayarları, üretim servisleri, telefon ve diğer oturumların çalışmaları değiştirilmedi. Bu son vault talebinde yalnız belge/indeks güncellemesi ve bağlantı/kanıt gizliliği kontrolü yapılır; yeni build, test-suite, commit veya push kapsamı açılmaz.


Vault kayıt kontrolü tamamlandı: rapor ve iki indeksteki bu çalışmaya ait **7 yerel bağlantı/başlık hedefi** mevcut; iki commit’in tam kimliği kayıtlı. İki sentetik JSON kanıtı ayrıştırıldı, hassas belirteç/kişisel adres kontrolü geçti. Rapor ve kanıt dosyalarının `0600`, kanıt dizininin `0700` izinleri korundu. Yeni ürün testi, canlı kurulum/uzak dal sorgusu veya commit/push yapılmadı; önceki doğrulama ve yayın sonuçları tarihsel kanıt olarak tutuldu.
