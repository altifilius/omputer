# Omputer implementation plan

## Outcome

An Android companion and a self-contained Linux desktop application supervising its local service. Open the PC app, select the automatically discovered PC on Android, compare codes and approve locally; normal startup requires no terminal/IP/JSON/project-registration steps. No hosted service, managed VPN, FCM, analytics, CDN, or cloud database. The PC is the authoritative executor; the phone is a securely paired controller. Existing OMP model-provider configuration is unchanged: Omputer adds no model/cloud dependency, but does not turn a remote OMP model into an offline model.

## Components

- `pc/`: Rust native desktop application, automatic user-owned installation/startup and bundled OMP runtime, supervised daemon and optional diagnostic CLI. Axum HTTPS/WSS, stable local TLS identity, SQLite journal, device/pairing management, automatic project/session discovery, project memory and authenticated Unix-domain sockets.
- `bridge/`: OMP TypeScript extension. Registers actual terminal sessions, exports events/state, handles structured commands and races local/mobile dialogs. The PC app installs a user-scoped extension loader for future normal OMP launches; existing uninstrumented processes are not injected, duplicated or silently restarted. Uses local IPC, not hosted Collab.
- `mobile/`: Flutter Android application, project-first Material 3 screens, persistent offline snapshot, source-linked project checkpoints, live transcripts, interaction inbox, model/subagent/session controls.
- `mobile/android/`: small native Kotlin service owns background WSS and Android notifications, encrypted credential storage, inline replies, action intents, connection status, battery settings. Foreground UI does not create a second controller socket.

## Security and networking

1. On first service start generate a TLS identity and random local-bridge credential in a mode-0700 state directory.
2. Untrusted local DNS-SD/bounded UDP discovery locates the PC. Strict v2 two-sided commitment/reveal binds random secrets and the certificate, then both native surfaces show a locally derived six-digit code. Only matching-code human approval on the PC permits token issuance. PC-app one-use ten-minute QR is secondary recovery; exact certificate pinning remains mandatory. Details: `PAIRING-V2.md`.
3. Successful pairing returns a random device bearer token; only its SHA-256 hash is stored in SQLite. Android stores it encrypted using Android Keystore. Revocation closes/rejects access.
4. HTTPS request and WSS upgrade both require the token. Secrets are not placed in URLs or logs. A paired controller can cause PC execution and is a high-trust device.
5. Outside-home access needs the owner's reachable IP/port or own WireGuard/router VPN. No auto port-forwarding, router changes, or third-party relay. CGNAT and a sleeping PC are genuine reachability limits.
6. Only locally registered project roots can be launched. Saved sessions are resumed only under their recorded root and never opened a second time while live.

## Event and interaction invariants

- Monotonic journal sequence; reconnect replays after the persisted cursor and refreshes the authoritative snapshot.
- Transcript pages and incremental events are separate; text updates replace by message ID, not append duplicate deltas.
- Commands carry UUID IDs. Outcomes are acknowledged; a lost acknowledgement never silently repeats a destructive operation.
- Pending interactions have stable request IDs, session ID, method, title/body/options/questions, deadline, and status. First valid desktop/mobile answer wins. Expired/cancelled/resolved answers are rejected.
- Disconnecting the phone does not interrupt OMP. Bridge loss temporarily retires non-actionable inbox entries; authoritative host-pending replay restores stable request IDs and reconciles unconsumed answer claims. A disconnect never manufactures a host answer.
- Agent turn ended, settled with no async work, explicit task completion, and project completion are not conflated.

## UI direction

Native Android navigation and controls; an ink-blue/periwinkle visual world with porcelain text, citrus decision emphasis, excellent light mode, generous readable conversation layout, and one timeline-to-session transition. Project continuity and pending human decisions lead. No terminal cosplay, decoration charts, fake data, nested cards, remote fonts, or redundant dashboards.

## Acceptance

- Open the bundled PC app without arguments; prepare/start its service, automatically import saved sessions/projects, preserve identity, reuse one daemon on repeat open, survive UI close and recover after daemon/network changes. Android finds the actual PC, compares codes, pairs after local approval, reconnects and honors revocation; QR is secondary recovery.
- Register a real terminal OMP session and start a new real `rpc-ui` session.
- Read live/history transcript, send prompt/steer/follow-up, abort, choose model, inspect todos/subagents, and resume an inactive session.
- Answer select/confirm/input/editor/ask/approval from phone; desktop answer cancels phone request; stale second answer rejected.
- Maintain/edit project checkpoint and show source plus freshness. Browse cached project data offline.
- Receive locally generated Android notifications while background connection is enabled, navigate to exact request, and reply. Expose permission/battery/connection health honestly.
- Run actual service/RPC smoke; build APK; exercise on local Android emulator or device, inspect phone screenshots, dark/light, Back, keyboard and font scale. No claim of physical-device delivery without a physical device.

## Reliability acceptance map — October 18

The required product remains the existing local-only Android companion, not a new cloud service or a terminal viewer. A capability is accepted only when its real workflow and failure boundary are exercised; earlier emulator evidence is not a physical-device pass.

| Required workflow | Current evidence / gap | Repair and acceptance boundary |
| --- | --- | --- |
| Install, open, update and auto-start PC | Bundled install/start works; a staged package can leave the old daemon running without applying new code | Show running versus installed release; apply only through an authenticated no-live-RPC update gate; never strand a native session |
| Keep LAN identity and recover network | TLS/server identity survives; ephemeral listener ports and daemon exit on route change can interrupt control | Persist a usable private endpoint and rebind the HTTPS listener/advertisements in-process, preserving App, IPC and native child ownership |
| Pair and intentionally replace trust | Matching-code pairing and exact pinning exist; unsolicited pairing links previously auto-replaced local trust/cache | External bundles remain pending until explicit identity/replacement consent; cancellation performs no network pairing or local deletion |
| Send prompt, steer, follow-up and interrupt | A real phone message path and native runtime smoke exist; stale capabilities and outcome refresh can mislead | Advertise only supported controls; acknowledge admission separately from generation; preserve drafts/errors and reject silent command replay |
| Resume work and retain history | Closed-session resume smoke passed; failed/disconnected managed sessions and archive imports can lose safe resume/identity | Recheck canonical root, native session identity and ownership lease; preserve saved source data; never create a second live writer |
| Answer questions, custom responses and approvals | Fast delivery confirmed by user; custom-plus-label payload and nested dialog owners caused failures | One source-owned request per invocation, selectable exclusive single-choice custom mode, accepted response closes exactly that request; independent identical questions remain distinct |
| Live/history transcripts and continuity | Revision paging, branch replacement and project checkpoints exist; superseded journal copies and cache work can flood the phone | Coalesce only superseded complete message revisions, preserve all unique history/decision events, bound phone queues/caches and show source/freshness honestly |
| Background decisions and notification replies | Foreground service and permissions exist; expiry, absent/stale notifications and command-error bodies require consistent handling | No stale or revoked actions; OS/Doze/force-stop limitations explicit; visible service is opt-in; replies use the same acknowledged decision path |
| Offline, reconnect, errors and accessibility | Cached projects/transcripts, native themes and Back exist; stale UI state and inaccessible/unlabeled fields need repair | Open cached data without pretending online, recover/reload safely, preserve answer drafts, label native inputs and retain keyboard/font-scale/reduced-motion behavior |
| Secure local boundaries | Public identity only, bearer auth, private Unix IPC and confined file reads are implemented | Keep exact TLS pins, one-use expiry/claims, explicit approval and revoked-device enforcement; no relaxed validation or hidden hosted fallback |
| Ship and verify the actual app | Prior workload OOM and USB debugging loss interrupted physical testing | Heavy checks run serially in separate bounded user services; publish distinct versions and same-signer packages; exercise real message/decision/reconnect/stability on hardware before claiming physical completion |

No arbitrary data-retention cutoff may remove pending decisions, unconsumed notifications, unique transcript history or acknowledged command outcomes. Journal sequences are monotonic watermarks, not a promise of contiguous integers. Scope excludes router/VPN ownership, CGNAT bypass, and guaranteed Android delivery after force-stop or while the PC sleeps.

### Current integration evidence

PC 0.1.1 and same-signer Android 1.0.2 (3) built. Rust 59, Flutter 60, Bun bridge 8 and native Kotlin 14 tests passed; analyzer/Clippy clean. The two new streaming-order regressions failed before and passed after stable per-screen ID ordering. Actual bundled OMP exercised both bridge and native RPC asks, custom/multi answers, acknowledged checkpoint, controls and safe resume. Actual HTTPS pairing/revocation/file/memory and packaged desktop install/reopen/close/guarded-update/recovery passed in disposable state.

Android 1.0.2 (3) is installed on Samsung SM-G990E with an exact APK hash match and original pairing. Native UI automation verified three actual OMP session rows held identical pixel positions through eight live-update samples. The predecessor 1.0.1 (2) additionally passed actual `Mavi`, custom `morcivert`, `Yeşil`, same-pair reconnect, background `RemoteInput` reply and an uninterrupted 300-second / 11-sample stability observation. These earlier results remain version-scoped; multi-hour OEM/Doze, force-stop delivery and WAN are not certified.

The requested PC update is now active in both native window and daemon. Its sole idle managed session was backed up, retired through RPC stdin closure and resumed from the same source with its visible/native identity preserved; original journal entries after the mutable title header are byte-for-byte intact. Terminal OMP processes, phone trust, certificate and port33975 were preserved. Already-running terminal extension closures still load bridge-code changes only on normal restart. Exact evidence and limitations: `VERIFICATION.md`.

## Ürün mükemmelleştirme yol haritası — 18 Ekim 2026

**Bu bölüm yeni planın otoritesidir; yukarıdaki kabul haritası önceki onarım turunun başlangıç durumudur.** Kullanıcının EXECUTE talimatıyla uygulama başlamıştır. Aşağıdaki maddeler doğrulanan checkpoint kaydı olmadan uygulanmış özellik sayılmaz. Hedef sınırsız özellik sayısı değil: telefondan gerçek OMP yeteneklerine erişirken iş, taslak, bağlam ve güven kaybetmemek.

### 1. Korunacak ürün kararı ve mevcut başlangıç

- Android, PC'deki OMP'nin yerel çalışma kumandasıdır; terminal ekranının küçültülmüş kopyası veya ikinci bir ajan yürütücüsü değildir. PC kod/veri otoritesi, telefon eşleştirilmiş yüksek güvenli denetleyicidir.
- Mevcut Material 3 / gece mavisi–periwinkle yönü korunur. Görsel iyileştirme yoğunluğu, okunabilirliği, keşfedilebilirliği ve durum açıklığını düzeltir; baştan tasarım veya framework değişikliği yoktur.
- Bulut backend, FCM, hosted relay, uzaktan görsel/font, analitik veya yönetilen VPN eklenmez. OMP'nin seçili sağlayıcısına giden model istekleri bu yerel uygulama tarafından çevrimdışı hâle gelmez; veri gönderen/maliyetli özellikler bunu açıkça belirtir.
- Güncel başlangıç PC **0.1.1**, Android **1.0.2 (3)**. Son kayıt: Rust 59, Flutter 60, Kotlin 14, köprü 8 test. Bunlar önceki gözlenen kontrollerdir; bu plan için testler yeniden çalıştırılmadı. 1.0.2'nin fiziksel sıra testi, 1.0.1'in karar/arka plan/kararlılık kanıtından ayrı tutulur.
- Sabit canlı sıralama, ilk-geçerli-karar, tek-yazar sahipliği, tam sertifika pinleme, eşleştirme değişimi onayı, snapshot-first reconnect ve sınırlı telefon önbelleği geriye götürülemez.

### 2. Kanıta dayalı durum ve boşluklar

`Var`: kaynakta çalışan yol var; `Kısmi`: alt katman veya UI var, uçtan uca kullanım eksik; `Yok`: Omputer arayüzü/API'si sunmuyor; `Doğrulanmadı`: özellik yok demek değildir. Yeni kabiliyetlerin adları aşağıda **öneri** olarak kullanılır.

| Alan | Mevcut durum / kaynak | Gerekli iyileştirme |
| --- | --- | --- |
| Canlı oturumlar ve ana sayfa | Var: sabit per-screen sıra, arama/filtre. `main.dart:119-144`, `projects.dart:23-25`, `ui.dart:111-129` | Canlı oturumlara doğrudan erişim, sabitleme, okunmamış işaretleri; özetlerin satır bütçesi ve açık genişletme. Kararlar/oturumlar uzun hafızanın altına gömülmemeli. |
| `/` komutları | Kısmi: metin gönderilebilir, bazı OMP komutları çalışabilir; katalog/parametre/sonuç ekranı yok. `session.dart:30-37,127-134`, `runtime.rs:456-477` | Oturuma özgü canlı komut kataloğu, arama/tamamlama, gerçek çıktı, destek/risk açıklaması, yapılandırılmış yerel ekranlar. |
| İşlem sonucu ve tekrar deneme | PC aynı UUID'yi dedup eder; Flutter her çağrıda yeni UUID üretir. `store.rs:609-640`, `controller.dart:359-365` | Telefon kalıcı işlem kimliği tutmalı; timeout sonrası sonucu sorgulamalı. Kabul, üretim başladı ve tamamlandı farklı durumlar. Sessiz yeniden yürütme yok. |
| Taslaklar | Kısmi: açık ekran/durum içinde korunur; route controller'ı dispose edilir. `session.dart:17-29`, `interactions.dart:56-73` | Oturum+gönderme modu bazlı kalıcı taslak, cevap taslağı, Back/yeniden açma/process-death kurtarma. Önemsiz cevap-cache eviction taslakları silemez. |
| Kararlar ve izinler | Var: select/confirm/input/editor/ask/approval, özel yanıt, kaynak, süre, bildirim yanıtı | Boş çoklu seçim uyumu, sonraki bekleyen karara geçiş, kabul edilen cevabın geçmişi, taslak geri yükleme, daha açık işlem/dosya etkisi. Kör kilit-ekranı onayı yok. |
| Hatalı turdan toparlanma | Kısmi: PC tur hatasını `failed` yapar; telefon bütün `failed` durumlarını arşiv sayar. `runtime.rs:995-1002,1290-1324`, `models.dart:81-84` | **[INFERENCE; henüz yeniden üretilmedi]** Canlı yazarın başarısız turu, ölmüş runtime'dan ayrılmadığında kullanıcı salt okunur görünümde kalabilir. Sahiplik ve tur hatasını ayrı modelle; çifte resume olmadan iyileşme sağla. |
| Mesaj kuyruğu | Kısmi: gerçek steer/follow-up var; kuyruk görüntüleme/düzenleme yok | Host kuyruğu, sıradaki mesaj, kaldır/düzenle/öne al; yalnız gerçekten hâlâ kuyrukta olan öğelere işlem. Tüketilmiş steer tekrar gönderilmez. |
| Konuşma ve araç çıktıları | Var: sayfalı geçmiş, yerinde message revision, Markdown, katlanır araç/düşünme blokları. `session.dart:103-161` | Kod kopyalama, araç çağrı/sonuç eşlemesi, hata/exit bilgisi, çıktıda arama, son mesaja dön, okunmuş konum; JSON'u her işin tek arayüzü olmaktan çıkar. |
| Shell/yerel komut çıktısı | Kısmi: yürütme ve onay var; `submitAction` sonucu atıyor, `bash_output`/`command_output` Dart'ta görüntülenmiyor | Gerçek stdout/stderr/exit, işlem sürüyor/hata/sonuç ayrımı ve oturum kaynağı. Başarı ACK'si tek başına kullanıcı sonucu değildir. |
| Ekler ve bağlam | Kısmi: backend `images` iletebiliyor, görüntü görüntülenebiliyor; telefondan ekleme yok | Android sistem picker/kamera/paylaşım yoluyla görsel önizleme/kaldırma, boyut sınırları, model desteği. Proje dosyasını bağlama ekleme; genel belge yüklemeyi `images` desteği var diye mevcut sayma. |
| Model/çaba/bağlam/maliyet | Kısmi: model ve sabit çaba menüsü var; `/v1/models` herhangi bağlı oturumdan liste alabiliyor. `runtime.rs:322-346`, `session.dart:50-58` | Hedef oturuma özgü modeller ve desteklenen çaba değerleri; bağlam/token/limit/varsa gerçek ücret. Bilinmeyen maliyet sıfır gösterilmez; fast/uzun bağlam maliyeti açıklanır. |
| Ağaç/dal/oturum hayatı | Var: güvenli resume ve branch-reset altyapısı; tree/fork/rewind UI yok | Gerçek entry-ID tabanlı ağaç, seçili mesajdan dal, fork, yeni/diğer oturuma geçiş. Dosya/kimlik değişimi sahiplik protokolü çözülmeden komut paletine açılmaz. |
| Alt ajan/görev/arka plan işi | Kısmi: read-only todo, ajan sohbet/durdur/canlandır; overflow'da saklı | Ana/alt ajan ağacı, çocuk geçmişi ve görev sonucu, gerçek arka plan işleri, oturum kapsamlı iptal. İnsan cevabı bekliyor/iş sürüyor/settled ayrı gösterilir. |
| Proje hafızası | Var: kaynaklı manuel/ajan checkpoint, ACK, tazelik | Kısa süreklilik özeti + tam detay, değişiklik geçmişi ve çakışan düzenlemede uyarı; sessiz otomatik hafıza yazımı veya proje tamamlandı çıkarımı yok. |
| Dosya ve değişiklik inceleme | Kısmi: bilinmesi gereken relatif yoldan 256 KiB salt-okunur dosya. `server.rs:273-284`, `security.rs:79-131` | Kök altında dosya/dizin arama, değişen dosyalar, salt-okunur git diff, hunk/path bağlantıları. İlk kapsam mobil IDE, stage/reset/commit değildir. |
| Offline/ağ/bildirim | Var: tek native soket, pinli reconnect, önbellek, foreground service | Son başarılı sync ve cache tazeliği, hata nedeni, işlem sonuçlarını uzlaştırma; scoped bildirim tercihi. Doze/OEM/force-stop/WAN kapsamı ayrıca ölçülür. |
| PC kurulum/güncelleme/tanı | Var: otomatik kurulum, staged update, güvenli gate, kimlik koruma | PC/telefon/runtime/bridge çalışan-kurulu sürümler, engelleyen somut oturumlar, sansürlenmiş tanı dışa aktarma, yedek/geri yükleme ve kullanıcı kapsamlı kaldırma. |
| Kaynak kullanımı ve kanıt | Native queue/cache sınırlı; Dart açılan transcript'leri controller ömrünce tutuyor. `controller.dart:91,235,433-440` | **[INFERENCE]** Çok sayıda uzun konuşma açmak resident belleği büyütebilir; ölç, sonra güvenli eviction ve sayfalama uygula. Yeni görüntü/arama/çıktı sınırsız kopyalama getirmemeli. |

**Somut ilk düzeltme:** `QuestionAnswer.valid` (`mobile/lib/models.dart:211-212`) çoklu seçimde de en az bir yanıt şart koşuyor; host (`runtime.rs:1914-1919`) boş çoklu seçimi kabul ediyor. Bu mevcut uyumsuzluk planlanacak, şimdi sessizce düzeltilmiş sayılmayacak.

### 3. `/` desteği: tek palet, farklı doğru yürütme yolları

#### Doğrulanmış host gerçekleri

- Bundled OMP **18.10.2**, RPC v1/v2; native `get_available_commands` ve `available_commands_update` sunuyor. Katalog adı, alias, kaynak, açıklama, input hint ve subcommand bilgisi taşıyor. `available-commands.ts:11-109`, `rpc-mode.ts:1742-1756,2110-2111`.
- Özel HOME/XDG ve ağ erişimi kapalı namespace içinde gerçek paketle yapılan probe: 49 katalog girdisi (iki geçici probe komutu dâhil), `/session info` ve `/context` için `command_output` + `agentInvoked:false`, uzantı komutunda literal argüman sonucu. Model üretimi başlamadı; hiçbir üretim oturumu veya sağlayıcı ayarı değiştirilmedi. **49 bir ürün limiti veya bütün kullanıcı kurulumlarının komut sayısı değildir.**
- `/context` çıktısında ANSI terminal renk dizileri görüldü. Telefon metin çıktısını güvenli normalize etmeli; terminal escape/control kodlarını çalıştırmamalı veya kullanıcıya ham olarak basmamalı.
- RPC `prompt` ortak builtin dispatch'ini kullanıyor; `steer`/`follow_up` önce kendi kuyruk yoluna gidiyor. `/` paleti seçili mesaj moduna körü körüne string yapıştırmamalı. `rpc-mode.ts:1782-1848`.
- Ortak kataloğa yalnız text-mode handler'ı olan builtin'ler giriyor. `/tree`, `/branch`, `/fork`, `/new`, `/plan`, `/btw` gibi TUI komutlarının bazıları listelenmez veya ayrı RPC/SDK adaptörü ister. `available-commands.ts:46-61`, `builtin-session.ts:598-654`, `builtin-modes.ts:326-355`, `builtin-lifecycle.ts:159-165,439-448`.
- Omputer'de `get_available_commands` dış API'si yok. Runtime genel olayları journal'a yazabilse de `command_output`/katalog/config/queue olaylarını telefon kullanışlı bir sonuç olarak göstermiyor (`runtime.rs:1346-1357`, `controller.dart:204-230`).
- Terminal bridge `AgentSession.prompt()` çağırıyor; bu yol extension/custom komutları ve Markdown/template genişletmesini yapar, builtin veya `/skill:` dispatch'ini yapmaz (`agent-session.ts:7299-7330`). Native RPC ile eşdeğerliği varsayılmaz. Her komut için terminal ve managed desteği ayrı kanıtlanır; ortak host dispatcher/SDK kullanılır, OMP komut mantığı Flutter'da yeniden yazılmaz.
- Mevcut katalog argüman ipuçları taşısa da güvenlik/idle/UI/sonuç gereksinimlerini açıklamıyor; prompt-template envanteri de eksik. Komut listesi tek başına izin, tamamlanma veya bütün TUI yeteneklerinin paritesi değildir.
- **[INFERENCE; kaynakla tanımlı, runtime repro bekliyor]** OMP `AgentSession.sessionId` sağlayıcı oturum kimliğidir; journal ID'den ayrılabilir ve `/fresh` bunu döndürür (`agent-session.ts:5354-5356,5850-5858,6696-6699`). RPC `get_state.sessionId` bunu taşırken Omputer immutable `runtimeSessionId` sanıyor (`runtime.rs:865-880`). `/fresh` ve lifecycle açılmadan görünür oturum, süreç binding'i, journal ID/file/leaf ve sağlayıcı session ID ayrı tutulmalıdır.
- `agentInvoked:false` yalnız bu komutun model turu başlatmadığını söyleyebilir; arka planda compact/handoff/otomatik rename işinin bittiğini garanti etmez. Uzantı hatası `extension_error` olarak gelirken dış prompt tamamlanabilir. ACK, arka plan işlem sonu ve hata korelasyonu ayrı kanıt ister.

#### Kullanıcı deneyimi

1. Mesaj alanının başına `/` yazınca klavyenin üzerinde aranan komut listesi açılır; ayrıca keşfedilebilir bir **Komutlar** düğmesi bulunur. Sırf palet açıldığı için prompt/model isteği yapılmaz.
2. Satırda gerçek komut adı, kısa Türkçe açıklama/host açıklaması, kaynağı (yerleşik/uzantı/skill/dosya/MCP prompt), argüman ipucu ve gerekiyorsa desteklenmeme nedeni gösterilir. Sık/son kullanılanlar yalnız keşfi kolaylaştırır; yürütme sırasını veya host anlamını değiştirmez.
3. `/model`, `/effort`, `/new`, `/tree` gibi yerel ekranı olan eylem ilgili picker/sayfayı açar. Ham metin argümanı gereken komut formda tamamlanır; seçmek otomatik yürütmek değildir. Enter/Back/IME ve TalkBack davranışı deterministiktir.
4. Hedef proje/oturum ve yan etki son gönderimden önce bellidir. Silme, durdurma, dosya/çalışma kökü değişimi, sağlayıcıya veri gönderme veya maliyet etkisi ilgili **alt komut** seviyesinde açıklanır; `/memory view` ile `/memory clear` aynı izin sayılmaz.
5. Sonuç komut adı/kaynak/gerçek çıktı ve durumuyla konuşmada veya işlem panelinde görünür. Komut çıktısı assistant cevabı gibi etiketlenmez; kopyalanabilir ve yeniden bağlanınca erişilebilirdir.
6. Bilinmeyen, artık kaldırılmış veya sadece PC'de kullanılabilen komut açık hata/veri verir. Yanlış `/komut` sessizce modele gönderilmez. Normal metin olarak gönderme istenirse komut olarak yorumlanmayacak açık bir yol ayrıca doğrulanır.

#### Komut aileleri ve doğru kapsam

| Aile / örnek | Omputer yolu | Açma koşulu |
| --- | --- | --- |
| `/model`, `/models`, `/effort`, açık başlıklı `/rename`, `/compact` | Var olan structured model/thinking/rename/compact eylemlerini palete bağla; aynı menünün ikinci, çelişkili uygulamasını yapma | Model/çaba hedef oturumdan; compact canlı işi kesebilir, dolayısıyla idle şartı veya açık kesme onayı gerekir. Provider-backed compact ve isimsiz rename için yan etki/maliyet bilgisi |
| `/session info`, `/context`, `/tools`, `/changelog`, `/dirs` | Doğrulanmış text handler veya safe structured sorgu; gerçek `command_output` gösterimi | Yalnız hedef runtime destekliyorsa; kontrol kodları normalize, hassas veri sansürü |
| `/usage`, `/fast`, `/slow`, `/fresh`, `/retry`, `/shake`, `/handoff` | Host semantiğiyle yerel form/komut; durum ve sonucu göster | Alt komut bazlı salt-okunur/değiştirici ayrımı; retry yeni model/araç çalışmasıdır, ağ retry'si değildir; üretim/maliyet belirtilir |
| Uzantı, custom/file, `skill:*`, MCP prompt komutları | Hedef oturumun dinamik kaydından argümanlı yürütme; metadata güncellenince yenile | Alias/collision önceliği host ile aynı; skill/MCP prompt model üretimi başlatabilir; özel TUI bileşeni kullanan uzantı için açık destek sınırı |
| `/new`, `/resume`, `/tree`, `/branch`/`/rewind`, `/fork` | Yeni/önceki oturum picker'ı, ağaç okuyucu ve ayrı branch/fork/navigation adaptörleri | `/new` önce mevcut ayrı `session.start` yolunu açar. In-process new/switch mevcut işi ve owned async işleri kesebilir; açık idle/precondition gerekir. Branch yeni journal yaratır, tree aynı dosyada leaf değiştirir; eşanlamlı değiller. `/fork pane/window` telefon eylemi değildir |
| `/btw` | Native `btw`, `btw_cancel`, `get_btw_history` üzerinden ayrı yan soru akışı | Ana işi kesmediği, yanıt/geçmiş/durumları ve sağlayıcı kullanımı gerçek akışta doğrulanır; düz `/btw ...` prompt'a bırakılmaz |
| `/plan`, `/plan-review`, goal/modlar | Host destekli mod + plan inceleme/onay ekranı; goal varsa ayrı capability | TUI-only handler'ın yerine eşdeğer RPC/SDK kontratı ve gerçek plan→onay→uygulama geçişi gerekir; prompt'a 'plan yap' eklemek plan modu sayılmaz |
| `/todo`, `/jobs`, ajanlar | Var olan görev/ajan ekranlarını geliştir; host todo/job sorgu/iptal yolları | Salt-okunur görünüm önce; düzenleme ve cancel yalnız gerçekten sahip olunan öğe/kapsam için |
| `/pin` ve `/session pin` | `/pin` OMP resume-list sabitlemesidir; `/session pin` sağlayıcı OAuth hesabı seçer | İki farklı anlam aynı 'sabitle' düğmesine eşlenmez. Yerel telefon favorisi ile host pin'i varsa ayrı kaynak bilgisi |
| `/mcp`, `/skills`, `/plugins`, `/reload-plugins` | Önce kurulu durum/kaynak/health görüntüleme; seçilmiş mutasyonlar sonra | Yükleme/yeniden yetkilendirme kod/ağ/kimlik etkisi taşır; PC yerel onayı ve mevcut host sözleşmesi; erişim yoksa dürüst disabled |
| `/login`, `/logout`, `/settings`, `/debug`, `/quit`, `/pause`, ekran kayıt komutları | Uygun yerel ayar/panel veya açıkça **PC'de tamamla** | Credential/OTP anahtarı snapshot'a taşınmaz; `/quit` telefon bağlantısını kesmekle eşdeğer değildir; kanıtlanmamış global pause/kill yok |
| `/share`, `/dump`, export, `/move`, `/wt`, `/add-dir`, session/memory delete | Başlangıçta güvenli önizleme veya PC'de tamamla; gereken parçalara scoped adaptör | Katalogda görünmek yürütme izni değildir. Hosted paylaşım ürünün local-only sınırını aşar; raw dump sır açığa çıkarabilir; dosya/kök/silme işlemi açık kapsam ve onay ister |

#### Önerilen minimum teknik sözleşme — henüz mevcut API değildir

- `GET /v1/sessions/:id/commands` → oturuma/runtime'a bağlı katalog + `catalogRevision`. Kayıtta canonical command ID/ad/alias, kaynak, argüman hint/subcommand, yürütme yolu, destek durumu/nedeni ve audited yan etki sınıfı. İlk katalog mevcut host metadata'sı üzerine dar bir adapter ekler; genel plugin sistemi kurulmaz.
- Mevcut UUID'li `/v1/commands` zarfına önerilen `session.command`: `{commandId,args,catalogRevision,expectedJournalId,expectedBindingRevision}`. İstemci native RPC frame, shell string veya keypress seçemez. PC hedef canlı oturumun capability'sini, mevcut katalog/ownership revision'ını ve argümanı tekrar doğrular; ardından shared builtin/extension dispatcher veya mevcut structured eylemi seçer.
- `GET /v1/commands/:uuid` → aynı işleme ait gerçek kabul/sonuç bilgisi; aynı kimliği sorgulama/uzlaştırma yeniden yürütme değildir. Host süreci öldüyse 'bilinmiyor' korunabilir; exactly-once completion garantisi uydurulmaz.
- Kalıcı, sayfalı işlem/komut-çıktısı görünümü; olaylar operation UUID + görünür oturum ID + runtime/branch generation'a bağlanır. Mevcut raw `command_output` her zaman request ID taşımıyor (`rpc-mode.ts:1810`): host korelasyonu sağlanmadan eşzamanlı çıktıyı tahminî 'son komuta' bağlama. En dar resmi adapter/runtime export'u tercih edilir.
- `available_commands_update`, model/çaba/config, kuyruk ve oturum-kimlik olaylarını normalize et; yeniden bağlanma snapshot'ı katalog/operation durumuyla uzlaşsın. Komut kaynağı açıklamaları güvenilmez metindir; UI/host instruction olarak çalıştırılmaz.
- Terminal ve managed dispatch ortak yeteneği sunamadığında o komut için ayrı açık `unavailableReason`. `SessionManager` ID/path değiştiren raw `/new`/branch istekleri, mevcut `apply_state` kimlik uyumsuzluğu denetimi gevşetilerek çalıştırılmaz.

### 4. Aşamalı uygulama sırası ve bitiş koşulları

Her aşama uçtan uca teslimdir. Çalışma sırası **A0 → A1**, ardından bağımsız ekran dilimleri; ortak kontrat oturmadan büyük UI/backend paralel değişimi yapılmaz. Ağır build'ler tek sırada ve ayrı kaynak-sınırlı servislerde çalışır.

#### A0 — P0 doğruluk ve capability temeli

**İş:** native/bridge/phone için görünür oturum–süreç binding'i–journal ID/file/leaf–provider session ID ayrımını kur; sahiplik–tur durumu–pending async–capability ayrımını doğrula; boş multi seçimi düzelt; operasyon kimliği ve bilinmeyen sonuç durumunu tasarla/uygula; shell/local komut sonuçlarını görünür yap. Runtime sürümü ve destek kümesi oturuma bağlı olsun.

**Önemli risk:** Android `callTimeout` 45 saniye (`LocalConnection.kt:456`), PC host ACK bekleme süresi 120 saniye (`runtime.rs:247`). Sadece timeout uzatmak çözüm değil; uzun işin ACK/sonuç sorgusunu ayırmak ve UUID'yi korumak gerekir.

**Hedef dosyalar:** `pc/src/{runtime,server,store}.rs`, `bridge/{index,ipc,wire}.ts`, `mobile/lib/{controller,models,session,interactions}.dart`, native request/cache katmanı.

**Çıkış kapısı:**
- Host'un izin verdiği boş multi gönderilir; single-choice/custom/notes/deadline kuralları bozulmaz.
- Kasıtlı kayıp ACK/timeout/reconnect'te tek UUID ile tek yürütme; yeni UUID üretip shell/prompt/approval'ı sessiz yineleme yok. Yeniden gönderme yalnız gerçek unsent/rejected veya açık kullanıcı kararıyla yeni işlem olur.
- Canlı runtime'da sağlayıcı hatası üretilir; kullanıcı aynı yazarda desteklenen refresh/model/retry yoluyla toparlanır; 'failed → ikinci resume' yapılmaz. Önce riskin gerçek repro'su yazılır, varsayım fix'i değil.
- Zararsız `printf` sonucu gerçek metin + exit/error bilgisiyle görünür. İnsan bekliyor, queued, arka plan sürüyor, settled, tur hatası ve disconnected ayrı UI durumlarıdır.
- `/fresh` sonrası provider ID değişse de journal/lease/telefon görünür kimliği değişmez; gerçek state refresh identity mismatch üretmez. Bu kabul gerçekleşmeden `/fresh` paletten yürütülemez.

#### A1 — P1 `/` paleti ve ilk gerçek komut dilimi

**İş:** session-specific discovery + revision, metadata güncellemeleri, literal args, risk sınıflaması, çıktının görüntülenmesi ve operation correlation. Aynı altyapıya mevcut model/çaba/rename/compact ekranlarını bağla; `/session info`, `/context`, `/tools` ve güvenli bir uzantı/skill/file örneğiyle uçtan uca bitir.

**Bağımlılık:** A0. Terminal ve managed runtime aynı komutta farklıysa destek matrisi UI'ya yansır; eksik resmi dispatcher/export araştırması uygulamadan önce kapanır.

**Çıkış kapısı:**
- `/` filtreleme/klavye/Back/TalkBack çalışır; önerilen hedef, önbellekteki katalogda p95 filtreleme **100 ms altında** (ölçülecek hedef, bugünkü performans iddiası değil).
- Komut seçmek kendi başına üretim veya mutation başlatmaz; argüman/gönderim açık. Prompt/steer/follow-up menüsü yanlışlıkla slash anlamını değiştirmez.
- Alias collision, bilinmeyen komut, kaldırılmış/reload edilmiş uzantı, eski katalog, bağlantı kopması ve unsupported TUI komutu deterministik yanıt verir; hiçbirini fark ettirmeden modele prompt yapmaz.
- `/context`/`session info` gerçek çıktısı görünür; iki farklı oturumdan eşzamanlı komut çıktıları karışmaz. Yeniden bağlanınca tamamlanan/unknown durum aynı işlemle uzlaşır.
- Managed ve fresh terminal OMP ile gerçek kabul; secrets/ANSI kontrol kodları/shell quoting sınırı gözlenir. Menü metni test etmek yerine kullanıcının gördüğü davranış ve komut sonucu doğrulanır.

#### A2 — P1 doğru işe hızla ulaşma ve yoğunluk

**İş:** mevcut üç-destinasyon yapısını koru; Projeler içinde ulaşılabilir canlı oturum bölümü, doğrudan eşleşen oturum sonuçları, kısa proje satırları, pin/okunmamış/son okunan. Proje detayında kararlar ve oturumlar ilk erişimde; uzun hafıza/son yanıt varsayılan katlı veya ayrı detayda. Satır sırası token güncellemesiyle değişmez; yeni yanıt göstergesi sırayı değiştirmek zorunda değildir.

**Hedefler:** `main.dart`, `projects.dart`, `ui.dart`, local identity-scoped preferences/read markers; PC tarafında ileride sayfalı arama.

**Çıkış kapısı:**
- Başlangıç ekranından görünen canlı oturuma en fazla iki açık dokunuş; tekil oturum adını aramak doğrudan o oturumu açar, uzun hafıza boyunca kaydırmaz.
- Uzun Markdown/listelerle ev ekranı satır yüksekliği sınırlıdır; tam detay seçilebilir olarak korunur. Metni küçülterek veya veri kesip gizleyerek çözme.
- Pin/read konumu app relaunch'ta korunur; PC değişince eski kayda uygulanmaz. Okunmamış işaret token delta adedi değil gerçek görünür mesaj/karar revision semantiğidir.
- Eski geçmişi okurken canlı token gelmesi viewport'u çekmez; 'son mesaja dön' açık eylemdir. Filtre/arama/pin ve scroll anchor birlikte sınanır.

#### A3 — P1/P2 güvenilir yazma, taslaklar, ekler ve kuyruk

**İş:** kalıcı session+mode taslakları, uzun metin düzenleme, açık discard, operation durumları, gerçek host mesaj kuyruğu. Android sistem fotoğraf picker/kamera/share-intent ile görsel önizle/kaldır; desteklenen proje dosyası referansını bağlama ekle.

**Bağımlılık:** A0/A1 operasyon/kabiliyet kontratı. `images` byte yolu genel document/URI yüklemesi sayılmaz. Oturum kabuğu dışına keyfi path/URL aktarma yok.

**Çıkış kapısı:** iki oturumda farklı taslak → Back → background/process death → offline açılış → taslak/mode/ekler doğru geri gelir; ACK yalnız gönderilen taslağı temizler. Görselde MIME/çözünürlük/boyut/model desteği belirgin; gerçek OMP'ye gönderilen görsel kanıtlanır. Kuyruk edit/remove/promote yalnız host'un gerçekten sahip olduğu sıradaki mesajlara uygulanır; tüketilmiş öğe yeniden yürütülmez. Approval/kararlar offline outbox'a otomatik alınmaz.

#### A4 — P2 tam oturum ve ajan kontrolü

**İş:** tree/entry/fork/rewind; bağımsız yeni/resume akışı; `/btw` yan soru paneli; host-backed plan/goal modları; görev/alt ajan/async job görünümü; hedef runtime'ın çaba/model/bağlam/varsa usage ve limit ekranları.

**Bağımlılık:** A0/A1 ve her host adapter'ın sürüm/sahiplik sözleşmesi. `/plan` ve plan-review için mevcut RPC yetersizse sınırlı resmi runtime genişletmesi önce yapılır; sahte plan modu veya generic terminal emülasyonu yoktur.

**Çıkış kapısı:** kaynak oturum kaybolmadan branch/fork; aynı source'ta ikinci yazar reddi; pending karar/katalog/başlık/mesaj sayfaları doğru generation ile taşınır. Branch seçili kullanıcı mesajının parent'ına kadar yeni journal üretir ve metni taslağa döndürür; çekirdeğin döndürdüğü image eklerini RPC bugün düşürdüğünden attachment restore kontratı tamamlanır. Tree navigation aynı dosyada leaf taşır; mevcut native `get_tree/get_entries` okuması navigation desteği sayılmaz, yeni adapter ve gerekiyorsa iki-aşamalı ask re-answer gerekir. New/switch/branch/compact'ın owned async veya aktif işi kesebilen etkileri gösterilir; kullanıcı onayı olmadan noninterrupting diye sunulmaz. Yan soru ana çalışmayı iptal etmez; cancellation yalnız kendi scope'unu etkiler. Ajanın gerçek alt geçmişi açılır, parent/sibling sahipliği kontrol edilir. Todo mutation varsa provenance açık; ajan tur sonu proje tamamlandı sayılmaz. Sağlayıcı maliyeti bilinmiyorsa 'bilinmiyor' gösterilir.

Bildirimden veya başka ekrandan oturuma geçerken mevcut taslak/okuma konumu korunur; bildirim yalnız kendi kaynak soru/oturumunu açar. Çoklu cihaz ilk-geçerli yanıt yarışı ve farklı oturumlarda eşzamanlı komutlar gerçek native akışta sınanır.

#### A5 — P2 iş ürününü inceleme ve proje sürekliliği

**İş:** kayıtlı kökte salt-okunur dosya/dizin arama, dosya/line linkleri, changed-files ve git diff, hunk gezinme; checkpoint değişiklik geçmişi ve stale-edit çakışması; mesaj/kod/araç sonucu kopyalama ve izinli yerel dışa aktarma.

**Bağımlılık:** A2 navigasyon + A0 operasyon/kimlik. Arama indeksi PC'de yerel, sayfalı ve iptal edilebilir; dosya okuma kanıtlı kök confinement'ını korur.

**Çıkış kapısı:** gerçek repo diff'i → dosya/hunk → konuşmaya dönüş aynı okuma konumunu korur; binary/büyük/symlink/traversal/redaction sınırları açık sonuç verir. Yazma/stage/reset/commit yok. İki cihaz veya ajan checkpoint'i değiştirince eski editör sessiz overwrite yapmaz. Export hedefi ve içeriği kullanıcıya gösterilir; secrets içeren raw dump güvenli paylaşım diye sunulmaz.

#### A6 — P1 kalite kapısı, P2 işletim ve dağıtım

Bu iş yalnız sona bırakılmaz: her aşama aşağıdaki kapıdan geçer. Son aşamada bütün senaryo matrisi birlikte kapatılır.

- **Bağlantı/tanı:** son sync, cache'den okuma, pin/kimlik değişimi, yetki iptali, servis yok/PC uyuyor/ağ yok ayrımı; uygulama/runtime/bridge/daemon kurulu ve çalışan sürümleri. Tanı kopyalama varsayılan sansürlüdür; kullanıcı içeriği/secret gönderilmez.
- **Güncelleme/yaşam döngüsü:** engelleyen oturum ve komutları isimleriyle göster; güvenli idle-close/resume, snapshot+journal yedeği/geri yükleme ve migration rollback. Otomatik güncelleme active OMP'yi kesmez; user scope dışına dokunulmaz. Android signing key/token/sertifika kurtarma kuralları birbirinden ayrıdır; restore yeni telefonda kör credential kopyalama değildir.
- **Performans:** önerilen deterministik sahne 1.000 oturum + 50.000 mesaj + büyük araç sonuçları, önce disposable yerel fixture'da; üretim RAM/swap'ını tüketerek stres yok. Uzun konuşmalar arasında 30 dakikalık gezinmede memory profili alınır; son üç eşit yük döngüsünde sürekli artış kalmaması hedefi, eviction/limits gerçek ölçümle seçilir. Yeni FTS, resim, sonuç kaydı ana/UI thread'i ve sınırsız transcript map'i büyütemez.
- **Native erişilebilirlik:** gerçek Android'de 200% font + klavye, TalkBack, predictive Back, Remove animations, light/dark, yatay/dar pencere; ses/gesture-only zorunluluk yok. Tablet desteği iddia edilecekse gerçek tablet sınıfı layout kabulü ayrı yapılır.
- **Ağ/bildirim matrisi:** LAN reconnect ve kendi WireGuard rotası, PC restart, Android background/ekran kapalı, OEM battery/Doze, force-stop sonrası kullanıcı açılışı, stale bildirim ve revoke. Ekran kapalı/gece boyunca ölçüm ve pil maliyeti fiziksel cihazda raporlanır; Android'in yasakladığı durumda 'garantili' teslimat sözü verilmez.
- **Yayın:** core API sınırlarının davranış regresyonları, gerçek bundled-runtime smoke, same-signer `install -r`, çalışan sürüm/read-back hash, retained pairing/history, actual native screenshots ve console/runtime hataları. Build/analyze/test/package tek ağır iş sırasıyla cgroup sınırlarında. Raporlar build hash'i ve cihaz/akış kapsamıyla işaretlenir; eski test sayısı yeni sürüme otomatik taşınmaz.

### 5. İlk uygulanacak teslim ve bağımlılık kararı

**İlk teslim A0 + A1'in dar uçtan uca dilimidir:** boş multi / live-error repro ve işlem UUID durumları; ardından `/` kataloğu, `/session info`, `/context`, mevcut model/çaba eylemleri, bir gerçek uzantı/skill komutu ve görünür/korelasyonlu sonuç. Bu, en önemli kullanıcı isteğini çözerken güvenilmez bir 'her şeyi çalıştır' kumandası üretmez. Sonraki kullanıcı-değerli teslim A2 + kalıcı taslaklardır; ağaç/diff ve ileri modlar onların ardından gelir.

| Birlikte tasarlanması gereken kontrat | Sonra bağımsız çalışabilecek dilimler |
| --- | --- |
| Session/runtime identity, capability ve katalog revision; operasyon UUID/sonuç olayı; risk/confirmation politikası | Slash UI ve PC dispatcher; persisted drafts; compact navigation; transcript renderer |
| Branch/session transition ownership ve native message/entry ID eşlemesi | Tree/fork UI, çocuk transcript'i, history search |
| Kayıtlı kökte dosya/link/boyut/redaction sözleşmesi | Dosya browser, read-only diff, mesaj path linkleri |

Her teslimde `PROTOCOL.md` ve `MOBILE-CONTRACT.md` yalnız gerçekten uygulanmış API ile güncellenir; bu yol haritasındaki öneri adları şimdiden sözleşme sayılmaz. `VERIFICATION.md`'deki tarihsel 'pending/excluded' satırları sürüm kapsamıyla netleştirilir; en güncel kanıt, eski fiziksel kurulum iddialarıyla karıştırılmaz.

### 6. Şimdilik yapılmayacaklar

- Bulut/FCM/hosted paylaşım, kullanıcı hesabı backend'i, uzak asset veya otomatik router/CGNAT çözümü.
- Genel mobil terminal/IDE, keyfi native RPC passthrough, compositor/PC süreç kontrol paneli veya terminale keypress enjekte etme.
- Sessiz shell/prompt retry, offline approval kuyruğu, toplu kör izin, otomatik memory rewrite veya token/tur sonundan proje tamamlandı çıkarımı.
- İhtiyaç kanıtlanmadan çok-PC senkronizasyonu, genel workflow/plugin çerçevesi, kendi skill marketplace'i veya OMP sağlayıcı kimlik deposunun telefonda kopyası.
- Gerçek host/controller semantiği yerine aynı isimli sahte `/plan`, `/pause`, `/retry`, `/fork` uygulamaları. Remote-only destek gelene kadar görünür neden + PC'de tamamla daha doğrudur.

### 7. Kanıt ve öneri ayrımı

Bu plan kaynak incelemesi, iki read-only araştırma dilimi, mevcut sürüm-sınırlı fiziksel kanıt ve özel ağsız bundled-runtime komut probe'una dayanır. Yeni özelliklerin hiçbiri bu planla uygulanmış sayılmaz. Sağlayıcı/live-error, provider/journal kimliği ve uzun Dart resident-memory konuları açıkça **[INFERENCE]** olarak işaretlendi; A0/A6 önce ölçüm/repro ister. Komut-discovery ve üç yerel slash yolunun çalışması gerçek süreç çıktısıyla gözlendi; bütün katalog komutları çalıştırılmadı, haricî servis çağrısı ve üretim oturumu mutation'ı yapılmadı.

## Uygulama checkpointleri — yürütme başladı

| Checkpoint | Kapsam | Durum / kapı |
| --- | --- | --- |
| CP0 | Sahiplik ve ortak API/yerel state sözleşmeleri | Uygulandı; bütün çağıranlar güncel sözleşmeye taşındı, 27 dosyalı runtime patch ve üretilmiş SDK eşleşmesi doğrulandı |
| CP1 | A0 kimlik, sonuç/ACK, karar doğruluğu | Geçti: Rust 81, Flutter 140, Kotlin 24, bridge 12, host 30 test. Gerçek derlenmiş OMP/HTTPS'de UUID dedup/çıktı, aynı yazarda provider hata kurtarma, `/fresh` kimlik ayrımı, boş multi/custom-only ve kalıcı mesaj kimliği regresyonları geçti |
| CP2 | A1 / discovery/dispatch/palet | Gerçek managed ve fresh PTY terminalde builtin/literal uzantı/proje skill'i; unknown/stale/unsupported ve palet/Back/argüman testleri geçti. Final APK'nın fiziksel palet/TalkBack/p95 ölçümü açık |
| CP3 | A2/A3 gezinme, kalıcı taslak/ek/queue | Kaynak, 140 Flutter/24 Kotlin ve gerçek host image/queue kabulü geçti. Idle share olayları route/taslak koruyor; son imzalı APK'nın fiziksel picker/kamera/share/process-death/offline kabulü USB yokluğu nedeniyle açık |
| CP4 | A4 tree/branch/fork/btw/plan/goal/ajan | Gerçek derlenmiş OMP'de plan review/approve, goal yaşam döngüsü, bağımsız BTW, queue promote/edit/remove, branch/fork ve kaynak journal korunması geçti. Gerçek alt ajan geçmişi (2 mesaj, cursor 9317), owned job iptali ve yabancı çocuk ret geçti; native branch draft davranış regresyonları geçti |
| CP5 | A5 dosya/diff/hafıza geçmişi | Gerçek HTTPS tree/file/diff, traversal/symlink ret, revision çakışması/checkpoint ACK; Flutter inceleme/kopyalama/export sözleşmeleri geçti. Fiziksel dosya → diff → geri okuma/export chooser akışı son native matriste açık |
| CP6 | A6 tanı/güncelleme/kurtarma/kaynak/erişilebilirlik | Final PC paketinde native kurulum/reopen/close/focus, yedek/tanı geçti. 1.000 journal / 50.000 mesaj, 1.800 s PC profili ve gerçek 7,1 GB kopyada 55.717 mesajın migration/FTS korunması geçti. Gerçek Android erişilebilirlik, Dart 30 dk, OEM/WAN/pil kapıları açık |
| CP7 | İmzalı paketler ve teslim | Final Android 1.1.0 (4) ve self-contained PC 0.2.0 üretildi; tam hash/signer `VERIFICATION.md` / `dist/build-info.json` içinde. PC 0.2.0 canlıya alındı; aynı session/journal/sertifika/port ve 537 özgün journal entry korundu. Samsung'a önceki 1.1.0 (4) paket yüklendi/read-back geçti; son ekran çevrimdışı ve USB sonradan koptu. Final APK kurulum/kabulü henüz yok |

İşlem kabulü kalıcı UUID ile kayıt altına alınır; HTTP beklemesi işin ömrünü sahiplenmez. Session journal/provider/process kimliği ayrı tutulur. Üretim hizmeti/telefon yalnız entegrasyon sahibi tarafından değiştirilebilir. Ağır kontroller ve build tek sırada, sınırlı kullanıcı servislerinde yürütülür. Her kapı yalnız gözlenen test/smoke kanıtıyla kapanır; alt dilimlerin kaynak teslimi checkpoint tamamlandı anlamına gelmez.

