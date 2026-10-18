use crate::{
    setup::{self, Installation, Layout},
    supervisor,
};
use anyhow::{Context, Result};
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use eframe::egui::{self, Color32, RichText, Vec2};
use fs2::FileExt;
use serde_json::{Value, json};
use std::{
    collections::HashSet,
    fs::{self, File},
    path::PathBuf,
    sync::{
        Arc, Mutex,
        mpsc::{self, Receiver, SyncSender},
    },
    thread,
    time::{Duration, Instant},
};

#[derive(Clone, Default)]
struct State {
    status: Option<Arc<Value>>,
    error: Option<String>,
    warning: Option<String>,
    phase: String,
    service_mode: String,
    installed: bool,
    busy: bool,
    notice: Option<String>,
    qr: Option<Value>,
    update_available: bool,
    resume_ids: Vec<String>,
}

enum Command {
    Retry,
    ApplyUpdate,
    SaveCloseUpdate,
    Restore(String),
    Action {
        action: &'static str,
        payload: Value,
    },
}

pub fn run(state_dir: PathBuf, bundle: Option<PathBuf>) -> Result<()> {
    let layout = Layout::discover(state_dir)?;
    setup::private_dir(&layout.state)?;
    let instance = setup::lock(&layout.state.join("desktop.lock"))?;
    if instance.try_lock_exclusive().is_err() {
        // A newly opened package may contain an update. Stage it before
        // activating the existing window; never silently ignore that package.
        setup::install(layout.clone(), bundle.as_deref())?;
        setup::atomic_write(
            &layout.state.join("desktop.activate"),
            uuid::Uuid::new_v4().to_string().as_bytes(),
            0o600,
        )?;
        return Ok(());
    }
    let (commands, commands_rx) = mpsc::sync_channel(1);
    let updates = Arc::new(Mutex::new(None));
    let updates_tx = updates.clone();
    let worker_layout = layout.clone();
    thread::Builder::new()
        .name("omputer-desktop-service".into())
        .spawn(move || {
            worker(worker_layout, bundle, commands_rx, updates_tx);
        })?;
    let options = eframe::NativeOptions {
        // A hidden Wayland surface may receive no frame callbacks. Waiting for
        // them in eglSwapBuffers stalls winit too, including compositor pings.
        // egui already schedules repaints; keep presentation non-blocking.
        vsync: false,
        viewport: egui::ViewportBuilder::default()
            .with_title("Omputer")
            .with_app_id("omputer")
            .with_inner_size([900.0, 760.0])
            .with_min_inner_size([580.0, 580.0]),
        ..Default::default()
    };
    eframe::run_native(
        "Omputer",
        options,
        Box::new(move |creation| {
            apply_theme(&creation.egui_ctx, true);
            Ok(Box::new(Desktop {
                _instance: instance,
                layout,
                commands,
                updates,
                state: State {
                    busy: true,
                    phase: "Omputer hazırlanıyor…".into(),
                    ..Default::default()
                },
                compared: HashSet::new(),
                revoke: None,
                qr: None,
                restore_confirmation: None,
                update_confirmation: false,
                dark: true,
                activation: Vec::new(),
                next_activation: Instant::now(),
            }))
        }),
    )
    .map_err(|error| anyhow::anyhow!("Cannot open native desktop application: {error}"))
}

fn worker(
    layout: Layout,
    bundle: Option<PathBuf>,
    commands: Receiver<Command>,
    updates: Arc<Mutex<Option<State>>>,
) {
    let mut state = State {
        busy: true,
        phase: "Uygulama ve yerel OMP çalışma ortamı kuruluyor…".into(),
        ..Default::default()
    };
    publish(&updates, &state);
    let mut installation = None;
    prepare(
        &layout,
        bundle.as_deref(),
        false,
        &mut installation,
        &mut state,
    );
    publish(&updates, &state);
    let mut next_poll = Instant::now();
    let mut waiting_since = Instant::now();
    let mut next_prepare = Instant::now() + Duration::from_secs(30);
    loop {
        match commands.recv_timeout(Duration::from_millis(200)) {
            Ok(command) => {
                state.busy = true;
                state.notice = None;
                publish(&updates, &state);
                match command {
                    Command::ApplyUpdate => {
                        match installation
                            .as_ref()
                            .context("Uygulama henüz kurulmadı")
                            .and_then(supervisor::apply_update)
                        {
                            Ok(()) => {
                                state.status = None;
                                state.phase = "Güncelleme uygulanıyor…".into();
                                waiting_since = Instant::now();
                            }
                            Err(error) => state.error = Some(format!("{error:#}")),
                        }
                    }
                    Command::SaveCloseUpdate => {
                        let result = (|| -> Result<()> {
                            let saved =
                                supervisor::admin(&layout.state, "update.closeIdle", json!({}))?;
                            state.resume_ids = saved["savedSessionIds"]
                                .as_array()
                                .into_iter()
                                .flatten()
                                .filter_map(|v| v.as_str().map(str::to_owned))
                                .collect();
                            let install =
                                installation.as_ref().context("Uygulama henüz kurulmadı")?;
                            supervisor::apply_update(install)?;
                            Ok(())
                        })();
                        match result { Ok(()) => state.notice=Some("Kaydedilen oturumlar kapatıldı ve güncelleme uygulandı. Aşağıdaki düğmeyle devam edebilirsiniz.".into()), Err(error)=>state.error=Some(format!("{error:#}")) }
                    }
                    Command::Restore(id) => {
                        let result = (|| -> Result<()> {
                            supervisor::admin(
                                &layout.state,
                                "backup.restore",
                                json!({"backupId":id}),
                            )?;
                            let install =
                                installation.as_ref().context("Uygulama henüz kurulmadı")?;
                            if let Err(error) = supervisor::restart_owned(install) {
                                let _ = supervisor::admin(
                                    &layout.state,
                                    "backup.cancelRestore",
                                    json!({}),
                                );
                                return Err(error);
                            }
                            Ok(())
                        })();
                        match result { Ok(())=>state.notice=Some("Yedek geri yüklendi. Güncel cihaz izinleri ve TLS kimliği korundu; özgün günlükler değiştirilmedi.".into()),Err(error)=>state.error=Some(format!("{error:#}")) }
                    }
                    Command::Retry => {
                        prepare(
                            &layout,
                            bundle.as_deref(),
                            true,
                            &mut installation,
                            &mut state,
                        );
                        waiting_since = Instant::now();
                    }
                    Command::Action { action, payload } => {
                        match supervisor::admin(&layout.state, action, payload.clone()) {
                            Ok(value) => {
                                state.error = None;
                                if action == "pair.bundle" {
                                    state.qr = Some(value.clone());
                                }
                                state.notice = Some(match action {
                                    "pair.approve" => "Telefon onaylandı. Eşleştirme telefonda tamamlanıyor.".into(),
                                    "pair.deny" => "Eşleştirme isteği reddedildi.".into(),
                                    "device.revoke" => "Cihazın erişimi kaldırıldı.".into(),
                                    "rescan" => "Yerel oturumlar yeniden tarandı.".into(),
                                    "backup.create" => format!("Yedek oluşturuldu: {}", value["id"].as_str().unwrap_or_default()),
                                    "diagnosis.export" => format!("Gizli içerik içermeyen tanılama kaydedildi: {}",value["path"].as_str().unwrap_or_default()),
                                    "update.resume" => "Kaydedilen oturum devam ettirildi.".into(),
                                    _ => "Tek kullanımlık QR hazır. Bu kodu yalnızca kendi telefonunuzla tarayın.".into(),
                                });
                                if action == "update.resume" {
                                    state.resume_ids.retain(|id| {
                                        Some(id.as_str()) != payload["sessionId"].as_str()
                                    });
                                }
                            }
                            Err(error) => state.error = Some(format!("{error:#}")),
                        }
                    }
                }
                state.busy = false;
                next_poll = Instant::now();
                publish(&updates, &state);
            }
            Err(mpsc::RecvTimeoutError::Disconnected) => return,
            Err(mpsc::RecvTimeoutError::Timeout) => {}
        }
        if (installation.is_none() || state.status.is_none()) && Instant::now() >= next_prepare {
            prepare(
                &layout,
                bundle.as_deref(),
                false,
                &mut installation,
                &mut state,
            );
            next_prepare = Instant::now() + Duration::from_secs(30);
            publish(&updates, &state);
        }
        if installation.is_some() && Instant::now() >= next_poll {
            match supervisor::admin(&layout.state, "status", json!({})) {
                Ok(status) => {
                    state.phase = if status["ready"] == true {
                        if status["urls"]
                            .as_array()
                            .is_some_and(|urls| !urls.is_empty())
                        {
                            "Telefon bağlantısına hazır"
                        } else {
                            "Yerel hizmet hazır · Özel ağ bekleniyor"
                        }
                    } else {
                        "Yerel hizmet hazırlanıyor…"
                    }
                    .into();
                    state.status = Some(Arc::new(status));
                    state.update_available = installation
                        .as_ref()
                        .is_some_and(|install| supervisor::update_warning(install).is_some());
                    if state
                        .error
                        .as_ref()
                        .is_some_and(|e| e.starts_with("Hizmete bağlanılamadı"))
                    {
                        state.error = None;
                    }
                    waiting_since = Instant::now();
                }
                Err(error) => {
                    state.status = None;
                    state.phase = "Yerel hizmete yeniden bağlanılıyor…".into();
                    if let Some(error) = supervisor::last_error(&layout) {
                        state.error = Some(format!("Hizmete bağlanılamadı: {error}"));
                    } else if waiting_since.elapsed() > Duration::from_secs(20) {
                        state.error = Some(format!(
                            "Hizmete bağlanılamadı: {error:#}. Yeniden denemek için aşağıdaki düğmeyi kullanın."
                        ));
                    }
                }
            }
            next_poll = Instant::now() + Duration::from_secs(1);
            publish(&updates, &state);
        }
    }
}

fn publish(updates: &Mutex<Option<State>>, state: &State) {
    *updates.lock().unwrap_or_else(|error| error.into_inner()) = Some(state.clone());
}

fn prepare(
    layout: &Layout,
    bundle: Option<&std::path::Path>,
    retry: bool,
    installation: &mut Option<Installation>,
    state: &mut State,
) {
    let result = (|| -> Result<()> {
        if installation.is_none() {
            let installed =
                setup::install(layout.clone(), bundle).context("Uygulama kurulamadı")?;
            *installation = Some(installed);
            state.installed = true;
        }
        let startup = supervisor::ensure_running(installation.as_ref().unwrap(), retry)
            .context("Yerel hizmet başlatılamadı")?;
        state.service_mode = startup.mode;
        state.warning = startup.warning;
        state.update_available =
            supervisor::update_warning(installation.as_ref().unwrap()).is_some();
        state.phase = "Güvenli yerel bağlantı başlatılıyor…".into();
        Ok(())
    })();
    state.busy = false;
    match result {
        Ok(()) => state.error = None,
        Err(error) => {
            state.error = Some(format!("{error:#}"));
            state.phase = if state.installed {
                "Yerel hizmet çevrimdışı"
            } else {
                "Kurulum tamamlanamadı"
            }
            .into();
        }
    }
}

struct Desktop {
    _instance: File,
    layout: Layout,
    commands: SyncSender<Command>,
    updates: Arc<Mutex<Option<State>>>,
    state: State,
    compared: HashSet<String>,
    revoke: Option<(String, String)>,
    qr: Option<(String, qrcode::QrCode)>,
    dark: bool,
    activation: Vec<u8>,
    next_activation: Instant,
    restore_confirmation: Option<String>,
    update_confirmation: bool,
}

#[derive(Clone, Copy)]
struct Palette {
    surface: Color32,
    container: Color32,
    text: Color32,
    secondary: Color32,
    primary: Color32,
    on_primary: Color32,
    waiting: Color32,
    on_waiting: Color32,
    error: Color32,
    on_error: Color32,
}
fn palette(dark: bool) -> Palette {
    if dark {
        Palette {
            surface: Color32::from_rgb(16, 23, 42),
            container: Color32::from_rgb(27, 35, 58),
            text: Color32::from_rgb(238, 239, 248),
            secondary: Color32::from_rgb(187, 192, 215),
            primary: Color32::from_rgb(184, 185, 255),
            on_primary: Color32::from_rgb(21, 29, 55),
            waiting: Color32::from_rgb(53, 62, 40),
            on_waiting: Color32::from_rgb(224, 237, 139),
            error: Color32::from_rgb(76, 36, 45),
            on_error: Color32::from_rgb(255, 218, 220),
        }
    } else {
        Palette {
            surface: Color32::from_rgb(248, 248, 255),
            container: Color32::from_rgb(235, 235, 248),
            text: Color32::from_rgb(21, 29, 55),
            secondary: Color32::from_rgb(76, 81, 106),
            primary: Color32::from_rgb(73, 75, 176),
            on_primary: Color32::WHITE,
            waiting: Color32::from_rgb(231, 239, 188),
            on_waiting: Color32::from_rgb(49, 59, 14),
            error: Color32::from_rgb(255, 218, 220),
            on_error: Color32::from_rgb(100, 24, 34),
        }
    }
}

fn apply_theme(context: &egui::Context, dark: bool) {
    let colors = palette(dark);
    let mut style = egui::Style {
        visuals: if dark {
            egui::Visuals::dark()
        } else {
            egui::Visuals::light()
        },
        ..Default::default()
    };
    style.visuals.panel_fill = colors.surface;
    style.visuals.window_fill = colors.container;
    style.visuals.override_text_color = Some(colors.text);
    style.visuals.selection.bg_fill = colors.primary;
    style.visuals.selection.stroke = egui::Stroke::new(1.5_f32, colors.on_primary);
    style.visuals.widgets.inactive.bg_fill = colors.container;
    style.visuals.widgets.hovered.bg_fill = if dark {
        Color32::from_rgb(51, 59, 88)
    } else {
        Color32::from_rgb(216, 216, 240)
    };
    style.visuals.widgets.active.bg_fill = colors.primary;
    style.visuals.widgets.active.fg_stroke = egui::Stroke::new(1.5_f32, colors.text);
    style.visuals.widgets.hovered.bg_stroke = egui::Stroke::new(1.5_f32, colors.primary);
    style.visuals.widgets.active.bg_stroke = egui::Stroke::new(2.0_f32, colors.primary);
    style.spacing.item_spacing = Vec2::new(12.0, 12.0);
    style.spacing.button_padding = Vec2::new(20.0, 14.0);
    style.spacing.interact_size.y = 48.0;
    style.animation_time = 0.0;
    style
        .text_styles
        .insert(egui::TextStyle::Heading, egui::FontId::proportional(30.0));
    style
        .text_styles
        .insert(egui::TextStyle::Body, egui::FontId::proportional(16.0));
    style
        .text_styles
        .insert(egui::TextStyle::Button, egui::FontId::proportional(16.0));
    style
        .text_styles
        .insert(egui::TextStyle::Small, egui::FontId::proportional(13.0));
    context.set_style(style);
}

impl Desktop {
    fn action(&mut self, action: &'static str, payload: Value) {
        if self
            .commands
            .try_send(Command::Action { action, payload })
            .is_ok()
        {
            self.state.busy = true;
        }
    }
    fn retry(&mut self) {
        if self.commands.try_send(Command::Retry).is_ok() {
            self.state.busy = true;
            self.state.error = None;
        }
    }
    fn pending(&mut self, ui: &mut egui::Ui, status: &Value, colors: Palette) {
        let requests = status["pendingPairs"]
            .as_array()
            .cloned()
            .unwrap_or_default();
        let ids: HashSet<String> = requests
            .iter()
            .filter_map(|v| v["requestId"].as_str().map(str::to_owned))
            .collect();
        self.compared.retain(|id| ids.contains(id));
        section_title(ui, "Telefon eşleştirme");
        if requests.is_empty() {
            ui.label(
                "Telefonunuzda Omputer’ı açın. Aynı yerel ağdaki bu bilgisayar otomatik görünür.",
            );
            ui.label(RichText::new("Eşleştirme isteği geldiğinde telefondaki altı haneli kodu burada karşılaştırıp onaylayın.").color(colors.secondary));
        }
        for request in requests {
            let Some(id) = request["requestId"].as_str() else {
                continue;
            };
            let name = request["name"].as_str().unwrap_or("Telefon");
            let code = request["verificationCode"].as_str().unwrap_or("");
            egui::Frame::new().fill(colors.waiting).corner_radius(20).inner_margin(20).show(ui, |ui| {
                ui.set_width((ui.available_width() - 40.0).max(0.0));
                ui.label(RichText::new(format!("{name} bağlanmak istiyor")).size(21.0).strong().color(colors.on_waiting));
                ui.label(RichText::new("Bu kod telefondaki kodla aynı mı?").color(colors.on_waiting));
                ui.label(RichText::new(code).monospace().size(40.0).strong().color(colors.on_waiting));
                ui.label(RichText::new(format!("Son geçerlilik: {}", display_time(&request["expiresAt"]))).small().color(colors.on_waiting));
                let mut compared = self.compared.contains(id);
                ui.add_enabled_ui(!self.state.busy, |ui| { ui.checkbox(&mut compared, "Telefondaki kodun aynı olduğunu kontrol ettim"); });
                if compared { self.compared.insert(id.into()); } else { self.compared.remove(id); }
                ui.horizontal_wrapped(|ui| {
                    if ui.add_enabled(compared && !self.state.busy && code.len() == 6, primary("Telefonu onayla", colors)).clicked() {
                        self.action("pair.approve", json!({"requestId":id}));
                        self.compared.remove(id);
                    }
                    if ui.add_enabled(!self.state.busy, egui::Button::new("Reddet").min_size(Vec2::new(100.0, 48.0))).clicked() {
                        self.action("pair.deny", json!({"requestId":id}));
                    }
                });
                ui.label(RichText::new("Onayladığınız telefon bu kullanıcı hesabıyla kod çalıştırabilir. Tanımadığınız bir isteği reddedin.").small().color(colors.on_waiting));
            });
        }
    }
    fn devices(&mut self, ui: &mut egui::Ui, status: &Value, colors: Palette) {
        section_title(ui, "Erişimi olan cihazlar");
        let devices = status["devices"].as_array().cloned().unwrap_or_default();
        let active: Vec<_> = devices
            .iter()
            .filter(|v| v["revokedAt"].is_null())
            .collect();
        if active.is_empty() {
            ui.label(RichText::new("Henüz eşleştirilmiş telefon yok.").color(colors.secondary));
        }
        for device in active {
            ui.horizontal_wrapped(|ui| {
                ui.vertical(|ui| {
                    ui.label(RichText::new(device["name"].as_str().unwrap_or("Telefon")).strong());
                    ui.label(
                        RichText::new(format!(
                            "Eşleştirildi: {}",
                            display_time(&device["createdAt"])
                        ))
                        .small()
                        .color(colors.secondary),
                    );
                });
                if ui
                    .add_enabled(
                        !self.state.busy,
                        egui::Button::new("Erişimi kaldır").min_size(Vec2::new(140.0, 48.0)),
                    )
                    .clicked()
                {
                    self.revoke = Some((
                        device["id"].as_str().unwrap_or_default().into(),
                        device["name"].as_str().unwrap_or("Telefon").into(),
                    ));
                }
            });
            ui.separator();
        }
    }
    fn fallback(&mut self, ui: &mut egui::Ui, colors: Palette) {
        ui.add_space(20.0);
        egui::CollapsingHeader::new("Telefon bilgisayarı bulamıyorsa").show(ui, |ui| {
            ui.label("İki cihazın aynı özel Wi-Fi/LAN ağında olduğunu kontrol edin. Misafir ağları cihazların birbirini görmesini engelleyebilir.");
            ui.label("Güvenlik duvarı kullanıyorsanız yalnızca bu bilgisayarın aşağıdaki TCP bağlantı noktasına kendi yerel ağınızdan erişime izin verin. Keşif için UDP 5353 ve 47878 kullanılır. Omputer güvenlik duvarını veya yönlendiricinizi değiştirmez; QR güvenlik duvarını aşmaz.");
            if let Some(status) = &self.state.status {
                ui.label(format!("Yerel HTTPS TCP bağlantı noktası: {}", status["port"]));
            }
            ui.label("Otomatik keşif engelleniyorsa telefonun eşleştirme ekranından bu tek kullanımlık QR’ı tarayın. Adres yazmanız gerekmez.");
            let ready = self.state.status.as_ref().is_some_and(|s| s["ready"] == true);
            if ui.add_enabled(ready && !self.state.busy, egui::Button::new("Tek kullanımlık QR oluştur").min_size(Vec2::new(220.0, 48.0))).clicked() { self.action("pair.bundle", json!({})); }
            if let Some(bundle) = self.state.qr.as_ref() {
                let expires = &bundle["expiresAt"];
                let expired = expires.as_str().and_then(|s| chrono::DateTime::parse_from_rfc3339(s).ok()).is_some_and(|time| time < chrono::Utc::now());
                if expired { ui.colored_label(colors.on_error, "QR’ın süresi doldu. Yeni bir QR oluşturun."); return; }
                let uri = bundle["uri"].as_str().map(str::to_owned).unwrap_or_else(|| format!("omputer://pair?data={}", URL_SAFE_NO_PAD.encode(bundle.to_string())));
                if self.qr.as_ref().is_none_or(|(key, _)| key != &uri) {
                    match qrcode::QrCode::new(uri.as_bytes()) {
                        Ok(code) => self.qr = Some((uri, code)),
                        Err(error) => { ui.colored_label(colors.on_error, format!("QR oluşturulamadı: {error}. Otomatik telefon keşfini kullanın.")); }
                    }
                }
                if let Some((_, code)) = &self.qr {
                    let modules = code.width();
                    let count = modules + 8;
                    let module = (ui.available_width().min(420.0) / count as f32).floor().max(1.0);
                    let side = count as f32 * module;
                    let (rect, _) = ui.allocate_exact_size(Vec2::splat(side), egui::Sense::hover());
                    ui.painter().rect_filled(rect, 0, Color32::WHITE);
                    for y in 0..modules { for x in 0..modules {
                        if code[(x,y)] == qrcode::Color::Dark {
                            let min = rect.min + Vec2::new((x+4) as f32 * module, (y+4) as f32 * module);
                            ui.painter().rect_filled(egui::Rect::from_min_size(min, Vec2::splat(module)), 0, Color32::BLACK);
                        }
                    }}
                    ui.label(RichText::new(format!("Tek kullanımlık · Son geçerlilik: {}", display_time(expires))).small().color(colors.secondary));
                    ui.label("Bu QR bir erişim sırrıdır. Ekran görüntüsünü paylaşmayın.");
                }
            }
        });
    }
}

impl eframe::App for Desktop {
    fn update(&mut self, context: &egui::Context, _frame: &mut eframe::Frame) {
        if let Some(update) = self
            .updates
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .take()
        {
            self.state = update;
        }
        if Instant::now() >= self.next_activation {
            let marker = fs::read(self.layout.state.join("desktop.activate")).unwrap_or_default();
            if marker != self.activation {
                self.activation = marker;
                context.send_viewport_cmd(egui::ViewportCommand::Minimized(false));
                context.send_viewport_cmd(egui::ViewportCommand::Focus);
            }
            self.next_activation = Instant::now() + Duration::from_millis(400);
        }
        let colors = palette(self.dark);
        let status = self.state.status.clone();
        let online = status.as_ref().is_some_and(|s| s["ready"] == true);
        egui::TopBottomPanel::bottom("footer")
            .frame(
                egui::Frame::new()
                    .fill(colors.surface)
                    .inner_margin(egui::Margin::symmetric(24, 14)),
            )
            .show(context, |ui| {
                ui.horizontal_wrapped(|ui| {
                    ui.label(
                        RichText::new(if self.state.installed {
                            "Pencereyi kapatsanız da yerel hizmet çalışmaya devam eder."
                        } else {
                            "Kurulum bu kullanıcı hesabında yapılır; yönetici yetkisi gerekmez."
                        })
                        .small()
                        .color(colors.secondary),
                    );
                    if ui
                        .button(if self.dark {
                            "Açık tema"
                        } else {
                            "Koyu tema"
                        })
                        .clicked()
                    {
                        self.dark = !self.dark;
                        apply_theme(context, self.dark);
                    }
                });
            });
        egui::CentralPanel::default().frame(egui::Frame::new().fill(colors.surface).inner_margin(24)).show(context, |ui| {
            egui::ScrollArea::vertical().auto_shrink([false, false]).show(ui, |ui| {
                ui.set_width(ui.available_width().min(920.0));
                ui.heading("Omputer");
                ui.label(RichText::new("Bilgisayarında çalışır. Kontrol sende kalır.").color(colors.secondary));
                ui.add_space(16.0);
                egui::Frame::new().fill(colors.container).corner_radius(24).inner_margin(20).show(ui, |ui| {
                    ui.set_width((ui.available_width() - 40.0).max(0.0));
                    ui.label(RichText::new(&self.state.phase).size(24.0).strong());
                    ui.label(if online && status.as_ref().is_some_and(|s| s["urls"].as_array().is_some_and(|urls| !urls.is_empty())) { "Çevrimiçi · Yalnızca yerel ağ · Şifreli bağlantı" } else if online { "Yerel hizmet çalışıyor · Telefon için aynı özel ağa bağlanın" } else if self.state.busy { "Hazırlanıyor · Bu işlem için terminal gerekmez" } else { "Çevrimdışı · Telefon kontrolü şu anda kullanılamıyor" });
                    if let Some(status) = &status {
                        ui.add_space(8.0);
                        ui.label(format!("{} proje · {} oturum", count(&status["projects"]), count(&status["sessions"])));
                        let archives = &status["discovery"]["archives"];
                        if archives.is_object() {
                            ui.label(RichText::new(format!("{} kayıtlı geçmiş · {} açık, henüz köprüsüz oturum (salt okunur)", count(&archives["archived"]), count(&archives["activeUnbridged"]))).small().color(colors.secondary));
                        }
                    } else if self.state.busy { ui.label("Uygulama kendi çalışma ortamını ve arka plan bağlantısını hazırlıyor."); }
                    if !self.state.service_mode.is_empty() { ui.label(RichText::new(&self.state.service_mode).small().color(colors.secondary)); }
                });
                if let Some(error) = self.state.error.clone() {
                    ui.add_space(12.0);
                    egui::Frame::new().fill(colors.error).corner_radius(16).inner_margin(16).show(ui, |ui| {
                        ui.label(RichText::new("İşlem tamamlanamadı").strong().color(colors.on_error));
                        ui.label(RichText::new(error).color(colors.on_error));
                        if ui.add_enabled(!self.state.busy, egui::Button::new("Yeniden dene").min_size(Vec2::new(150.0,48.0))).clicked() { self.retry(); }
                    });
                } else if !online && !self.state.busy && ui.add(primary("Yeniden bağlan", colors)).clicked() {
                    self.retry();
                }
                if let Some(warning) = &self.state.warning {
                    ui.add_space(12.0);
                    ui.label(RichText::new(warning).color(colors.on_waiting));
                }
                if self.state.update_available {
                    ui.label("Yeni sürüm hazır. Etkin iş kesilmez. Terminal OMP oturumlarını kendi pencerelerinden kapatın; yalnızca uygulamanın yönettiği boş oturumlar açık onayınızla kaydedilip kapatılabilir.");
                    if ui.add_enabled(online && !self.state.busy, primary("Güncelleme seçenekleri", colors)).clicked() { self.update_confirmation = true; }
                }
                if let Some(notice) = &self.state.notice { ui.add_space(8.0); ui.label(RichText::new(notice).color(colors.primary)); }
                if online {
                    let status = status.as_ref().unwrap();
                    self.pending(ui, status, colors);
                    self.devices(ui, status, colors);
                } else if !self.state.installed {
                    section_title(ui, "İlk açılışta hazırlanır");
                    ui.label("Omputer bu kullanıcı hesabına kurulur; oturum açtığınızda yerel bağlantıyı otomatik başlatır. Sistem OMP kurulumunuz değiştirilmez.");
                }
                for id in self.state.resume_ids.clone() {
                    ui.horizontal_wrapped(|ui| { ui.label(format!("Kaydedilen oturum: {id}")); if ui.add_enabled(online && !self.state.busy,egui::Button::new("Oturuma devam et")).clicked() { self.action("update.resume",json!({"sessionId":id})); } });
                }
                if let Some(status) = &status {
                    egui::CollapsingHeader::new("Sürümler, yedekler ve kurtarma").show(ui, |ui| {
                        for scope in ["installed","running"] {
                            ui.label(if scope=="installed" { "Kurulu bileşenler" } else { "Çalışan hizmetin başlangıç bileşenleri" });
                            for key in ["native","omp","bridge"] { let item=&status["components"][scope][key]; ui.label(format!("{key}: {}",item["version"].as_str().unwrap_or("sürüm bilgisi yok"))); ui.add(egui::Label::new(RichText::new(item["sha256"].as_str().unwrap_or("SHA-256 alınamadı")).small().monospace()).wrap().selectable(true)); }
                        }
                        if let Some(blockers)=status["update"]["blockers"].as_array() { for blocker in blockers { ui.label(format!("Güncelleme engeli: {} · {}",blocker["sessionId"].as_str().unwrap_or("hizmet"),blocker["reason"].as_str().unwrap_or("Etkin iş var"))); } }
                        ui.label("Yedekler konuşma ve kaynak günlüklerini içerir; bu bilgisayarın özel klasöründe saklanır. Etkin yazıcı varsa işlem reddedilir. TLS anahtarı ve köprü belirteci yedeklenmez. Geri yükleme güncel cihaz izinlerini korur; eski erişimleri canlandırmaz ve özgün günlükleri değiştirmez.");
                        if ui.add_enabled(online && !self.state.busy,egui::Button::new("Özel yedek oluştur")).clicked() { self.action("backup.create",json!({})); }
                        if let Some(items)=status["backups"]["items"].as_array() { if items.is_empty() { ui.label("Henüz özel yedek yok."); } for item in items { ui.horizontal_wrapped(|ui| { ui.label(format!("{} · {} günlük · {} bayt",display_time(&item["createdAt"]),count(&item["journals"]),item["bytes"])); if ui.add_enabled(!self.state.busy,egui::Button::new("Bu yedeği geri yükle…")).clicked() { self.restore_confirmation=item["id"].as_str().map(str::to_owned); } }); } }
                        if ui.add_enabled(online && !self.state.busy,egui::Button::new("İçeriksiz tanılama dışa aktar")).clicked() { self.action("diagnosis.export",json!({})); }
                    });
                }
                self.fallback(ui, colors);
                ui.add_space(16.0);
                egui::CollapsingHeader::new("Yerel bağlantı ve oturum bilgileri").show(ui, |ui| {
                    if let Some(warning) = &self.state.warning { ui.label(warning); }
                    if let Some(status) = &status {
                        ui.label(format!("Bilgisayar: {}", status["serverName"].as_str().unwrap_or("Omputer")));
                        ui.label("Sertifika parmak izi");
                        ui.add(egui::Label::new(RichText::new(status["fingerprint"].as_str().unwrap_or("—")).monospace().small()).wrap().selectable(true));
                        if let Some(urls) = status["urls"].as_array() { for url in urls { if let Some(url) = url.as_str() { ui.label(RichText::new(url).monospace().small()); } } }
                        let discovery = &status["discovery"];
                        if let Some(error) = discovery["error"].as_str() { ui.colored_label(colors.on_error, error); }
                        if let Some(error) = discovery["listenerError"].as_str() { ui.colored_label(colors.on_error, error); }
                        let archives = &discovery["archives"];
                        if let Some(errors) = archives["errors"].as_array() { for error in errors.iter().take(5) { if let Some(error) = error.as_str() { ui.colored_label(colors.on_error, error); } } }
                        if let Some(roots) = archives["missingRoots"].as_array() && !roots.is_empty() { ui.label(RichText::new(format!("{} oturum klasörü henüz yok; oluştuğunda otomatik taranır.", roots.len())).small()); }
                        if let Some(error) = discovery["mdns"]["error"].as_str() { ui.colored_label(colors.on_error, format!("Yerel ağ keşfi: {error}")); }
                        if let Some(error) = discovery["udp"]["error"].as_str() { ui.colored_label(colors.on_error, format!("Ek yerel ağ keşfi: {error}")); }
                        if ui.add_enabled(!self.state.busy, egui::Button::new("Oturumları yeniden tara").min_size(Vec2::new(180.0,48.0))).clicked() { self.action("rescan", json!({})); }
                    }
                    ui.label("Yeni terminal OMP oturumları kurulan uzantıyı otomatik yükler. Zaten açık OMP süreçleri köprü güncellemesini kendi normal yeniden açılışlarında yükler; yeniden başlatılmaz veya bellekte değiştirilmez.");
                    ui.label("Ajan yaşam döngüsü kontrolü, destekleyen derlenmiş çalışma ortamındaki yeni oturumlarda kullanılabilir. Sisteminizdeki omp komutu değiştirilmez.");
                    ui.label("Bulut, aktarıcı ve bildirim sağlayıcısı yoktur. Bilgisayar uyurken veya ağ yokken telefon bağlanamaz.");
                });
                ui.add_space(24.0);
            });
        });
        if let Some((id, name)) = self.revoke.clone() {
            egui::Window::new("Cihaz erişimini kaldır").collapsible(false).resizable(false).anchor(egui::Align2::CENTER_CENTER, [0.0, 0.0]).show(context, |ui| {
                ui.set_max_width(420.0);
                ui.label(format!("{name} artık bu bilgisayara bağlanamayacak. Yeniden bağlanmak için tekrar eşleştirmeniz gerekir."));
                ui.horizontal_wrapped(|ui| {
                    if ui.add(primary("Erişimi kaldır", colors)).clicked() { self.action("device.revoke", json!({"deviceId":id})); self.revoke = None; }
                    if ui.add(egui::Button::new("Vazgeç").min_size(Vec2::new(100.0,48.0))).clicked() { self.revoke = None; }
                });
            });
            if context.input(|input| input.key_pressed(egui::Key::Escape)) {
                self.revoke = None;
            }
        }
        if self.update_confirmation {
            egui::Window::new("Güvenli güncelleme").collapsible(false).resizable(false).anchor(egui::Align2::CENTER_CENTER,[0.0,0.0]).show(context,|ui| {
                ui.set_max_width(470.0); ui.label("Etkin işlem, bekleyen soru, kuyruk veya terminal yazıcısı varsa güncelleme reddedilir. Boş yönetilen oturumları kaydedip kapatmak ayrıca onay gerektirir; kapatılan oturumlara güncellemeden sonra devam edebilirsiniz.");
                if ui.add_enabled(!self.state.busy,primary("Oturum kapatmadan güncelle",colors)).clicked() && self.commands.try_send(Command::ApplyUpdate).is_ok() { self.state.busy=true;self.update_confirmation=false; }
                if ui.add_enabled(!self.state.busy,egui::Button::new("Boş oturumları kaydet, kapat ve güncelle")).clicked() && self.commands.try_send(Command::SaveCloseUpdate).is_ok() { self.state.busy=true;self.update_confirmation=false; }
                if ui.button("Vazgeç").clicked() { self.update_confirmation=false; }
            });
        }
        if let Some(id) = self.restore_confirmation.clone() {
            egui::Window::new("Yedeği geri yükle").collapsible(false).resizable(false).anchor(egui::Align2::CENTER_CENTER,[0.0,0.0]).show(context,|ui| {
                ui.set_max_width(470.0);ui.label(format!("Yedek: {id}"));ui.label("Bu bilgisayarın kayıtları yedekteki tarihe dönecek. Mevcut veritabanı geri dönüş kopyası olarak saklanır. Hizmet yeniden başlar; etkin yazıcı varsa işlem reddedilir. Özgün OMP günlükleri ve güncel cihaz iptalleri korunur. Başka bilgisayara kimlik taşıma desteklenmez.");
                if ui.add_enabled(!self.state.busy,primary("Onayla ve geri yükle",colors)).clicked() && self.commands.try_send(Command::Restore(id)).is_ok() { self.state.busy=true;self.restore_confirmation=None; }
                if ui.button("Vazgeç").clicked() {self.restore_confirmation=None;}
            });
        }
        if context.input(|input| input.key_pressed(egui::Key::Escape)) {
            self.restore_confirmation = None;
            self.update_confirmation = false;
        }
        context.request_repaint_after(Duration::from_millis(250));
    }
}

fn primary(label: &str, colors: Palette) -> egui::Button<'_> {
    egui::Button::new(RichText::new(label).color(colors.on_primary))
        .fill(colors.primary)
        .corner_radius(24)
        .min_size(Vec2::new(140.0, 52.0))
}
fn section_title(ui: &mut egui::Ui, title: &str) {
    ui.add_space(24.0);
    ui.label(RichText::new(title).size(21.0).strong());
}
fn count(value: &Value) -> usize {
    value
        .as_u64()
        .map(|n| n as usize)
        .or_else(|| value.as_array().map(Vec::len))
        .unwrap_or(0)
}
fn display_time(value: &Value) -> String {
    value
        .as_str()
        .and_then(|time| chrono::DateTime::parse_from_rfc3339(time).ok())
        .map(|time| {
            time.with_timezone(&chrono::Local)
                .format("%d.%m.%Y %H:%M")
                .to_string()
        })
        .unwrap_or_else(|| "Bilinmiyor".into())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn suspended_window_receives_only_latest_snapshot() {
        let updates = Mutex::new(None);
        for value in 0..1000 {
            publish(
                &updates,
                &State {
                    status: Some(Arc::new(json!({"sequence":value}))),
                    ..Default::default()
                },
            );
        }
        let latest = updates.lock().unwrap().take().unwrap();
        assert_eq!(latest.status.unwrap()["sequence"], 999);
        assert!(updates.lock().unwrap().is_none());
    }
}
