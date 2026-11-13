---
title: "Omputer — Neumorphic mesaj alanı"
project: omputer
type: project-report
date: "2026-11-13"
status: tamamlandi
tags:
  - proje-raporu
  - android
  - arayuz
---

# Omputer — Neumorphic mesaj alanı

[Proje sayfası](../README.md) · [Rapor dizini](README.md) · [Projects ana sayfası](../../README.md)

## Amaç ve kapsam

Kullanıcının coslac / Smit-Prajapati imzalı Uiverse CSS örneğini mevcut Android konuşma girişine uyarlamak. Uygulama Flutter/native; CSS veya web önizlemesi ürünün yerine eklenmedi. Arama, karar, ayar ve yeni-oturum formları kapsam dışında tutuldu.

## Uygulanan değişiklik

- `mobile/lib/message_input.dart`: yalnız mesaj girişinde kullanılan native bileşen. Koyu dış yüzey `#23272f` → `#14161a`; karşı yönlü yumuşak gölgeler ve gerçek içe gömülü gölge çizimi.
- Dış köşe 16dp, iç köşe 12dp, arada 4dp; içeride 16dp boşluk. Açık tema mevcut `ColorScheme` yüzeylerini kullanıyor.
- Odak: 2dp amber çizgi, uyumlu imleç ve metin seçimi. Koyu amber `#ffd43b`, açık amber `#846000`. 100px renk halesi ve sürekli/yerleşim animasyonu eklenmedi.
- `mobile/lib/session.dart`: mevcut TextField yerine bileşen kullanılıyor; aynı `TextEditingController`, enabled koşulu ve 1–6 satır sınırı korundu. Gönder, slash, prompt/steer/follow-up, ekler, taslak sahipliği ve ayrı araç kaydırması değiştirilmedi.
- “OMP’ye mesaj” adı placeholder’dan bağımsız semantics etiketi; `MergeSemantics` ile doğrudan editör düğümüne birleştiriliyor. Dolu taslak ve odakta adı/değeri koruyan regresyon testi eklendi. Üstte araçlara taşan floating etiket kaldırıldı.
- `DESIGN.md`, `CHANGELOG.md` ve rapor bağlantıları güncellendi. Paylaşılan tema değişmedi; sürüm artırımı veya dağıtım paketinin değiştirilmesi yapılmadı.

## Tasarım kararı ve ödünleşimler

**Ürün:** kişisel PC’deki OMP oturumlarını Android’den sürdürme aracı. **Karakter:** sakin, teknik, dokunsal. **Malzeme:** kullanıcının istediği grafit kontrol yuvası. **Vurgu:** yalnız mesaj alanındaki iç/dış derinlik ve amber odak. **İmza:** mevcut `/` komut ve prompt/steer/follow-up akışı.

Unslop/Emil/Impeccable/Taste yönlendirmeleri dar kapsamda uygulandı: istenen neumorphic malzeme bilinçli istisna; bütün uygulama yeniden tasarlanmadı. Türkçe metinler, sistem yazı ölçeği, Material kontrolleri ve en az 48dp etkileşim hedefleri korunuyor. Bütün temayı koyuya zorlamak ve CSS’in geniş renk halesini birebir taşımak yerine tema uyumu ve okunur odak seçildi. Yeni bağımlılık, özel font veya uzaktan kaynak yok.

## Çalıştırılan doğrulama

- İlk kaynak analizi: `lib/message_input.dart lib/session.dart`, **sorun yok**.
- İlk iki hedefli test dosyası: **19 geçti, 3 başarısız**. Üçünün nedeni dolu taslakta semantics adının kaybolmasıydı. Test beklentisi gevşetilmedi; bileşenin kalıcı erişilebilir adı düzeltildi.
- Düzeltme sonrası analiz: `lib/message_input.dart lib/neumorphic_preview.dart`, **sorun yok**.
- `project_workflows_test.dart --plain-name "keeps editable and send at bottom"`: **6/6 geçti**. Boş/uzun geçmiş, görsel+dosya ekleri, 360dp kısa ekran, %200 metin, yüksek klavye, çok satırlı yazma, odak, taslak/gönder ve alt konum dahil.
- Son `message_input_test.dart`: **1/1 geçti**. Ad doğrudan `EditableText` semantics düğümünde hem dolu taslakta hem odakta mevcut; alanın gerçek değeri korunuyor. Bu ek kontrol, yalnız üst kapsayıcıdaki adı bulan eski testin kapsamadığı tüketici görünür sınırı koruyor.
- Impeccable manuel detector, iki değişen ürün Dart dosyası için **`[]`**. Bu native erişilebilirlik veya görsel kabul yerine geçmez.
- Geçici native entrypoint’ten x86_64 debug APK derlendi; ilk Gradle **117,8 saniye**, son semantics birleştirmesiyle ikinci build **32,9 saniye**, ikisi başarılı. Sınırlı ilk serviste bellek tepe değeri **2,5 GiB**, sonuncuda **1,5 GiB**. Harness kaynak dosyası doğrulama sonrası kaldırıldı; `dist/` ve fiziksel telefon değişmedi.
- Koyu amber / giriş yüzeyi kontrastı **10,50:1**; koyu ana metin / giriş yüzeyi **13,07:1**. Açık amber / uygulama yüzeyi **5,44:1**; son değer açık giriş yüzeyinin ayrıca ölçüldüğü iddiası değildir.

### Native doğrulama durumu

Özel **Android35 x86_64, 720×1280 / 320dpi** emülatöründe ürünün gerçek `SessionScreen` ve mesaj bileşeni açıldı. Veriler yalnız geçici yerel adaptördü; üretim backend/model çağrısı yapılmadı. Son native koşu tamamlandı: koyu normal görünüm, koyu klavye+metin, %200 koyu klavye+metin ve %200 açık klavye+metin. UIAutomator gerçek yazıyı ve `focused=true` durumunu okudu; giriş sınırları klavye kapalı normalde `[40,1040][560,1152]`, klavye açık `[40,474][560,626]`. Bunlar emülatör fiziksel piksel ölçüleridir, ürün dp sabiti değildir. Koyu/açık görüntüler incelendi; sarı/amber odak, iç gölge, kullanılabilir editör ve gönder hedefi görünür. Son PID kapsamlı `flutter:E` / `AndroidRuntime:E` okuması boş. Native sistem font ayarı 1,0 ve gece modu başlangıçtaki kapalı duruma döndürüldü; emülatör normal `emu kill` ile kapatıldı.

İlk iki emülatör denemesi başarı sayılmadı: ilkinde RAM otomatik 2560MiB’ye çıktı ve HangDetector crash; ikincisi boot+APK kurulumundan sonra QEMU CPU thread hang ile kapandı. Üçüncü düşük-RAM denemesi gerçek görsel kontrolü çalıştırdı fakat `qemu_thread_create: Resource temporarily unavailable` ile kapandı. Özel servisin görev sınırı 256→512 yapılarak dördüncü koşu tamamlandı; küresel kaynak/masaüstü ayarı değiştirilmedi. İlklerinin nedenini OOM veya uygulama hatası olarak kesinleştirmiyoruz. Masaüstü aynasının arka plan klavye sürücüsü de başarısız oldu; yalnız sahip olunan emülatörde ADB giriş/çekim yoluna geçildi. Masaüstüne foreground giriş gönderilmedi.

### Seçilmiş native kanıt

- [Koyu neumorphic mesaj alanı](../Kanitlar/2026-11-13/neumorphic-input/dark-default-final.png)
- [Koyu odak ve gerçek klavye](../Kanitlar/2026-11-13/neumorphic-input/dark-focus-ime-final.png)
- [%200 koyu metin ve klavye](../Kanitlar/2026-11-13/neumorphic-input/dark-200-ime-final.png)
- [%200 açık metin ve klavye](../Kanitlar/2026-11-13/neumorphic-input/light-200-ime-final.png)
- [Native senaryo sonuçları](../Kanitlar/2026-11-13/neumorphic-input/native-results.json)

Görüntüler sentetik metin ve emülatör çubuklarını içerir; kullanıcı konuşması veya kimlik bilgisi yok. Debug bandı ve emülatörün sistem vurguları ürün stilinin parçası değildir.

## Korunan ayarlar ve güvenlik

PC/bridge/Rust/Kotlin ürün kodu, çalışan PC servisi, üretim veritabanı, eşleştirme, izinler, VPN/firewall ve compositor ayarları değiştirilmedi. Fiziksel cihaz bağlı değildi. Paylaşılan ADB servisi durdurulmadı; özel AVD’ye tam seri numarasıyla hedefleniyor. Test adaptörü gerçek ağ veya model çağrısı yapmıyor ve komut göndermeyi reddediyor. Kanıt dizini özel izinlerle oluşturuldu; ham log, anahtar ve kullanıcı konuşması rapora eklenmedi.

## İşletim, geri alma ve kalan iş

Bu kaynak değişikliği henüz telefona dağıtılmış değildir. Normal Android build/deploy süreci ayrı; eski kurulu uygulamanın görünümünün değiştiği iddia edilmez. Geri alma yalnız mesaj bileşeni ve çağrısını önceki native alana döndürmeyi gerektirir; veri temizleme, uninstall veya PC servisi geri alma yok. Geri alma çalıştırılmadı.

İstenen kaynak değişikliği, hedefli davranış testleri ve native görsel kontrol tamamlandı. Geçici harness, özel AVD/sürücüler ve ara görüntüler temizlendi; yalnız seçilmiş kanıtlar tutuldu. Son kullanıcı dağıtımı/telefona kurulum istenmedi ve yapılmadı. Fiziksel telefon, TalkBack, tablet/yatay ekran ve donanım performansı kabulü bu dar çalışmadan çıkarılamaz.

## Aynı gün devamı

Kullanıcı daha sonra projeler için dönen 3B kart halkası, gerçek çalışma avatarı ve bağlı telefonun kullanılmasını istedi. Bu genişleyen işin sürüm/kurulum ve birleşik kabul kaydı [Dönen projeler ve çalışan avatarı](2026-11-13-donen-projeler-ve-calisan-avatar.md) raporunda sürdürülür; yukarıdaki “telefon/dağıtım değişmedi” ifadesi ilk mesaj alanı milestone’unun sonucudur.
