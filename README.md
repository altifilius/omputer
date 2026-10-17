# Omputer

Android telefonundan kendi PC’ndeki OMP oturumlarını izle, kararları cevapla ve projede kaldığın yerden devam et.

**Bulut backend’i, hosted relay, FCM, yönetilen VPN, analitik veya uzak UI kaynağı yok.** Telefon HTTPS/WSS ile doğrudan PC’ye bağlanır. Proje hafızası ve olay günlüğü PC’de SQLite; telefon kimliği Android Keystore ile şifreli, okunan içerik telefonun özel önbelleğinde. OMP’nin mevcut model sağlayıcısı değişmez: uzaktaki modele bağlı OMP, bu uygulama sayesinde çevrimdışı model olmaz.

## Bileşenler

- `pc/`: Rust yerel servis ve native PC uygulaması; otomatik kurulum/başlangıç, yerel keşif, telefon onayı, TLS, cihaz yetkisi ve oturum yönetimi.
- `bridge/`: TypeScript OMP extension; gerçek soru/izin arayüzü, subagent kontrolü ve kaynaklı checkpoint. Hosted Collab kullanmaz.
- `mobile/`: Flutter Android uygulaması; Kotlin doğrudan bağlantı servisi, bildirim eylemleri, sertifika sabitleme ve güvenli yerel kimlik.
- `PROTOCOL.md`, `MOBILE-CONTRACT.md`, `AUTO-CONTRACT.md`, `PAIRING-V2.md`: uygulanan arabirimler ve güven sınırları.

## İlk kullanım — komut gerekmez

1. Linux x64 PC’de **`dist/Omputer` dosyasını aç**. Dosya yöneticisi gerektiriyorsa dosya özelliklerinden çalıştırma iznini etkinleştir. Uygulama kendi OMP çalışma ortamını açar, kullanıcı hesabına kurulur ve telefon bağlantısını başlatır; Cargo, Bun, Android Studio veya terminal kurulumu gerekmez.
2. Android telefona **`dist/omputer-android.apk` dosyasını kur ve aç**. Android’in bu kaynaktan uygulama kurma onayı sana aittir. İki cihaz aynı özel Wi-Fi / yerel ağda olmalı.
3. Telefonda bulunan bilgisayarı seç. **PC ve telefondaki altı haneli kodu karşılaştır**; yalnızca aynıysa PC’de karşılaştırma kutusunu işaretleyip **Telefonu onayla**’ya bas. Kod farklıysa isteği reddet.
4. Projeler ve kayıtlı oturumlar otomatik görünür. İstersen telefonun sorduğu bildirim iznini ver ve görünür bildirimli arka plan bağlantısını açık tut.

Normal kullanımda servis başlatma, IP adresi yazma, JSON yapıştırma, proje kaydetme veya runtime indirme adımı yoktur. Güvenlik onayı ve Android’in izin ekranları otomatik geçilmez. Eşleştirilmiş telefon bu kullanıcı hesabıyla kod çalıştırabilir; yalnızca kendi telefonunu onayla.

PC penceresini kapatmak arka plan hizmetini kapatmaz. Uygulama sonraki kullanıcı oturumunda otomatik başlar; servis yöneticisi kullanılamıyorsa masaüstü otomatik başlatma kullanılır. Aynı uygulamayı tekrar açmak ikinci servis oluşturmaz. Hata sonrası kurtarma sınırlı yeniden denemelerle yapılır; bağlantı durumu ve elle yeniden deneme PC uygulamasında görünür.

Keşif ağ tarafından engelleniyorsa PC uygulamasındaki **Telefon bilgisayarı bulamıyorsa** bölümünden tek kullanımlık QR oluştur; telefonda **Alternatif: bilgisayardaki QR’ı okut**’u seç. QR on dakika geçerli erişim sırrıdır; paylaşma. Misafir ağı / cihaz izolasyonu, firewall veya cihazlar arasında erişim olmaması QR ile aşılmaz.

## Kurulum ve veri konumu

Kurulum yalnızca mevcut kullanıcı hesabına yapılır: uygulama ve gömülü runtime `$XDG_DATA_HOME/omputer/app` (varsayılan `~/.local/share/omputer/app`), özel servis verisi `$XDG_DATA_HOME/omputer`, uygulama menüsü `$XDG_DATA_HOME/applications/omputer.desktop`. Kullanıcı servisi `$XDG_CONFIG_HOME/systemd/user/omputer.service`; fallback otomatik başlangıç `$XDG_CONFIG_HOME/autostart/omputer.desktop`. Yalnızca uygulamanın kendi sahiplik kaydındaki dosyalar güncellenir; ilgisiz veya elle değiştirilmiş dosyalar ezilmez.

PC uygulaması özel IPv4 LAN arayüzünü ve boş bir portu seçer; genel Internet adresine veya bütün arayüzlere otomatik dinleyici açmaz. Özel ağ yoksa yerel hizmet loopback’te çalışır; ağ gelince yeniden bağlanır. Router, firewall ve VPN ayarlarını değiştirmez. Sertifika/PC kimliği yeniden açılışta korunur; adres değişikliği ancak kayıtlı sertifika birebir doğrulandıktan sonra kabul edilir.

## Mevcut ve yeni OMP oturumları

PC uygulaması OMP’nin yapılandırılmış veri dizinlerini ve profillerini tarar; geçmiş JSONL dosyalarını kaynağı değiştirmeden salt okunur içeri alır ve proje yollarını otomatik kaydeder. Yeni normal OMP açılışlarında kullanıcıya ait extension yükleyicisi köprüyü bağlar. Sistem `omp` çalıştırılabilir dosyası değiştirilmez.

**Önceden köprüsüz açılmış süreç sonradan enjekte edilmez veya yeniden başlatılmaz.** Böyle bir canlı oturum geçmiş olarak görünür ve köprüsüz durumu belirtilir; canlı kontrolü varmış gibi gösterilmez. İnaktif kayıt telefondan güvenle sürdürülebilir; canlı sahiplik lease’i varken ikinci resume reddedilir. Telefon bağlantısının kopması PC’deki işi durdurmaz.

## Projede kaldığın yer

İki farklı bilgi kaynağı gösterilir:

1. **Son etkinlik:** normal kullanıcı hedefi, son final asistan yanıtı, görevlerde sıradaki iş; kaynak oturum ve zaman ile. Turun bitmesi projeyi tamamlandı saymaz.
2. **Kalıcı hafıza:** hedef, özet, sonraki adım ve kararlar. `omputer_checkpoint` araç çağrısı yerel kaydı onay aldıktan sonra bildirir; telefonda elle düzenlenebilir ve kaynak oturumu seçilebilir. Yeni model çağrısı/otomatik bulut özeti yok.

## Bildirim ve bağlantı sınırları

Android uygulamasında **Bildirim izni** ve **Arka plan bağlantısı** aç. Bağlı-cihaz foreground service’i kalıcı görünür bildirimle doğrudan WSS bağlantısını sürdürür. Metin/editor isteklerine Android bildiriminden kısa cevap; çoklu seçim ve izinler uygulamada bağlamıyla açılır. İzin bildirimi kilit ekranında kör onay sunmaz.

Doze sırasında ağ/CPU erişimi kısıtlanabilir. Uygulama içinden pil optimizasyonu ayarını incele; sürekli gerçek zamanlı erişim pil maliyeti taşır. Zorla durdurulmuş uygulama, ağsız telefon, kapanmış/uyuyan PC için teslimat garantisi yok. Bağlantı geri gelince olaylar ve güncel durum alınır; eski cevap tekrar çalıştırılmaz.

Ev dışı erişim için kendine ait WireGuard/router VPN’i veya güvenli erişilebilir adres gerekir. Uygulama router portlarını, firewall’u veya VPN’i değiştirmez. CGNAT arkasındaki erişilemeyen PC’ye üçüncü taraf relay olmadan bağlantı kurulamaz. Public Internet’e doğrudan port açmak yerine kendi VPN’ini kullan.

## Android derleme

Flutter stable, JDK17, Android SDK36/NDK28.2.13676358. Bu çalışma makinesindeki izole araçlar `~/.local/share/omputer-tools/` altında; proje/sistem runtime’ı değiştirilmez.

```sh
sh scripts/build-android.sh
# Standart Flutter kurulumu olan başka bir makinede:
cd mobile
flutter pub get
flutter analyze
flutter test
flutter build apk --debug
```

Debug APK: `mobile/build/app/outputs/flutter-apk/app-debug.apk`.
Optimize edilmiş APK: `mobile/build/app/outputs/flutter-apk/app-release.apk`.

Hazır teslim dosyaları: `dist/omputer-android.apk` (arm64 + x86_64, optimize ve yerel release imzalı) ve `dist/Omputer` (Linux x64, runtime/köprü gömülü native uygulama). Kontrol toplamları `dist/SHA256SUMS` içinde.

Bu makinede ayrı yerel release imza kimliği `~/.local/share/omputer-signing/android-release.p12` altında oluşturuldu; dizin 0700, anahtar/parola dosyaları ve gitignore’daki `mobile/android/key.properties` 0600. Anahtar başka bir servise yüklenmez. Uygulama güncellemeleri için bu dizini güvenli yedekle; anahtar kaybolursa mevcut kurulumun üzerine aynı kimlikle güncelleme yapılamaz. Debug ve release imzaları farklıdır; debug sürümünden geçerken uygulamayı kaldırıp yeniden eşleştirmen gerekir.

Başka bir makinede release için `mobile/android/key.properties` içinde `storeFile`, `storePassword`, `keyAlias`, `keyPassword` belirt ve `sh scripts/build-android.sh --release` kullan. Debug anahtarı release diye gizlice kullanılmaz.

## Geliştirici derlemesi ve tanılama

Bu bölüm kullanıcı kurulumu değildir. Linux, Rust/Cargo, Bun >=1.3.14 ve OMP 18.10.2 kaynakları derleme sırasında gerekir:

```sh
sh scripts/package-desktop.sh
sh scripts/build-android.sh --release --target-platform android-arm64,android-x64
```

Masaüstü paketleme script’i gömülü OMP runtime ve köprü arşivini oluşturur; sonuç `dist/Omputer` dosyasıdır. Gömülü kaynak olmadan düz Cargo build yalnızca geliştirme içindir. `omputer --help` içindeki açık CLI alt komutları isteğe bağlı tanılama içindir; komutsuz açılış native uygulamadır. Özel test verisi için `OMPUTER_STATE_DIR` / `--state-dir` kullanılabilir. Eski elle servis kurma script’i kaldırıldı; uygulama kurulum ve başlangıcın tek sahibidir.

## Güvenlik ve doğrulama

Keşif bilgisi yetki değildir. İlk bağlantı iki taraflı v2 commit/reveal ve insanın kod karşılaştırmasını gerektirir; QR alternatifi tek kullanımlık gizli erişim kodu taşır. Sonraki bağlantılarda TLS sertifikası birebir sabitlenir; arbitrary self-signed kabul edilmez ve sertifika sessizce yenilenmez. Token PC’de yalnızca hash; cihaz iptali akışı kapatır. Dosya okumaları Linux `openat2 RESOLVE_BENEATH` ile köke hapsedilir. Soru kimliği/deadline ve ilk-geçerli-cevap kuralı masaüstü/telefon yarışını sınırlar. API key ve provider transport ayrıntıları snapshot’a gönderilmez; kullanıcı konuşmasının içeriği eşleştirilmiş telefona gider.

Gerçek makine ve Android emülatörü üzerinde yapılan doğrulamanın güncel kapsamı `VERIFICATION.md` içinde. Fiziksel telefon pil/Doze davranışı emülatör kanıtıyla eşdeğer değildir.
