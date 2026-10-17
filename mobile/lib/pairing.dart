import 'dart:async';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'controller.dart';
import 'models.dart';
import 'ui.dart';

class PairingScreen extends StatefulWidget {
  const PairingScreen({super.key, required this.controller, this.initialBundle});
  final OmputerController controller;
  final String? initialBundle;
  @override
  State<PairingScreen> createState() => _PairingScreenState();
}

class _PairingScreenState extends State<PairingScreen> with WidgetsBindingObserver {
  final name = TextEditingController(text: 'Omputer Android');
  Timer? timer;
  bool busy = false, polling = false, background = true;
  String? error;
  OmputerController get controller => widget.controller;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _discover();
      if (widget.initialBundle != null) _pairQr(widget.initialBundle!);
    });
  }
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _discover();
      if (controller.pairingStatus == 'pending') _schedulePoll();
    } else if (state == AppLifecycleState.paused) { timer?.cancel(); }
  }
  Future<void> _discover() async {
    try { await controller.discover(true); }
    catch (failure) { if (mounted) setState(() => error = '$failure'); }
  }
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    timer?.cancel();
    name.dispose();
    super.dispose();
  }
  Future<void> _request(Json computer) async {
    setState(() { busy = true; error = null; });
    try {
      if (background) await controller.requestNotifications();
      await controller.requestPair('${computer['id']}', name.text, background: background);
      if (mounted) _schedulePoll();
    } catch (failure) { if (mounted) setState(() => error = '$failure'); }
    finally { if (mounted) setState(() => busy = false); }
  }
  void _schedulePoll() {
    timer?.cancel();
    timer = Timer(const Duration(seconds: 1), _poll);
  }
  Future<void> _poll() async {
    if (!mounted || polling || controller.pairingStatus != 'pending') return;
    polling = true;
    try {
      final status = await controller.pollPair();
      if (!mounted) return;
      setState(() => error = null);
      if (status == 'approved') { if (Navigator.canPop(context)) Navigator.pop(context); }
      else if (status == 'pending') _schedulePoll();
    } catch (failure) {
      if (mounted) { setState(() => error = 'Onay durumu alınamadı. Bağlantı geri geldiğinde otomatik denenecek. $failure'); _schedulePoll(); }
    } finally { polling = false; }
  }
  Future<void> _cancel() async {
    timer?.cancel();
    await perform(context, controller.cancelPair);
    if (mounted) setState(() => error = null);
  }
  Future<void> _pairQr(String value) async {
    setState(() { busy = true; error = null; });
    try {
      if (background) await controller.requestNotifications();
      await controller.cancelPair();
      await controller.pair(value, name.text);
      if (background) await controller.setBackground(true);
      if (mounted && Navigator.canPop(context)) Navigator.pop(context);
    } catch (failure) { if (mounted) setState(() => error = '$failure'); }
    finally { if (mounted) setState(() => busy = false); }
  }
  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: controller, builder: (context, _) {
    final pending = controller.pairing;
    final waiting = controller.pairingStatus == 'pending';
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Scaffold(appBar: AppBar(title: const Text('Omputer')), body: SafeArea(top: false, child: ListView(padding: const EdgeInsets.fromLTRB(24, 24, 24, 40), children: [
      Align(alignment: Alignment.centerLeft, child: Material(color: scheme.primaryContainer, borderRadius: BorderRadius.circular(24), child: Padding(padding: const EdgeInsets.all(20), child: Icon(Icons.devices_rounded, size: 42, color: scheme.onPrimaryContainer)))),
      const SizedBox(height: 28),
      Text(waiting ? 'Bilgisayarında\nonayla.' : 'Bilgisayarınla\naynı sayfada.', style: text.headlineLarge?.copyWith(fontWeight: FontWeight.w600, letterSpacing: -.8)),
      const SizedBox(height: 16),
      Text(waiting ? '${pending?['serverName']} ekranındaki kodun aşağıdaki kodla aynı olduğunu kontrol et. Yalnızca kodlar aynıysa bilgisayarında Onayla’ya bas.' : 'Bilgisayarında Omputer’ı aç. Telefonun ve bilgisayarın aynı yerel ağdayken birbirini bulur. Komut, adres veya bulut hesabı gerekmez.', style: text.bodyLarge?.copyWith(height: 1.5)),
      if (waiting && pending != null) ...[
        const SizedBox(height: 28),
        Semantics(label: 'Doğrulama kodu: ${'${pending['verificationCode']}'.split('').join(' ')}', excludeSemantics: true, child: SelectableText('${pending['verificationCode']}', style: text.displayMedium?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]))),
        const SizedBox(height: 20),
        Semantics(liveRegion: true, child: const Text('Bilgisayarında onayla · onay bekleniyor')),
        const SizedBox(height: 16),
        const Text('Kodu eşleşmeyen veya tanımadığın bir bilgisayarı onaylama. Bu ağdaki keşif bilgisi tek başına erişim yetkisi vermez.'),
        const SizedBox(height: 16),
        ExpansionTile(tilePadding: EdgeInsets.zero, title: const Text('Bilgisayarın sertifika parmak izi'), children: [SelectableText('${pending['fingerprint']}', style: text.bodySmall)]),
        const SizedBox(height: 16),
        OutlinedButton.icon(onPressed: _cancel, icon: const Icon(Icons.close_rounded), label: const Text('Eşleştirmeyi iptal et')),
      ] else ...[
        const SizedBox(height: 28),
        TextField(controller: name, enabled: !busy, decoration: const InputDecoration(labelText: 'Bu cihazın adı'), textInputAction: TextInputAction.done),
        const SizedBox(height: 16),
        SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Arka planda bağlantıyı sürdür'), subtitle: const Text('Eşleştirmeden sonra Android’de görünür bağlı-cihaz bildirimiyle çalışır. Bildirim izni senden istenir; bu tercihi Ayarlar’dan kapatabilirsin.'), value: background, onChanged: busy ? null : (value) => setState(() => background = value)),
        const SizedBox(height: 24),
        Semantics(liveRegion: true, child: Text(controller.computers.isEmpty ? (controller.scanning ? 'Yakındaki bilgisayarlar aranıyor…' : 'Yakındaki bilgisayarlar') : 'Bulunan bilgisayarlar', style: text.titleLarge)),
        const SizedBox(height: 12),
        if (controller.scanning && controller.computers.isEmpty && !MediaQuery.disableAnimationsOf(context)) const LinearProgressIndicator(),
        if (controller.computers.isEmpty) const Padding(padding: EdgeInsets.symmetric(vertical: 16), child: Text('Bilgisayar henüz görünmüyor. Omputer açık ve iki cihaz aynı Wi-Fi / yerel ağda olmalı. Misafir ağları cihazların birbirini bulmasını engelleyebilir. Arama kendiliğinden sürer.')),
        for (final computer in controller.computers) ListTile(contentPadding: const EdgeInsets.symmetric(vertical: 12), leading: const Icon(Icons.computer_rounded), title: Text('${computer['name']}'), subtitle: const Text('Yerel ağ · seç ve bilgisayarında onayla'), trailing: busy ? null : const Icon(Icons.chevron_right_rounded), enabled: !busy, onTap: () => _request(computer)),
        if (busy) Padding(padding: const EdgeInsets.symmetric(vertical: 16), child: Semantics(liveRegion: true, child: const Text('Bilgisayarın kimliği doğrulanıyor…'))),
        if (controller.discoveryError != null) ErrorNotice(controller.discoveryError!, onRetry: _discover),
        if (controller.pairingStatus == 'denied' || controller.pairingStatus == 'expired') ErrorNotice(controller.pairingStatus == 'denied' ? 'Bilgisayar eşleştirmeyi reddetti. Doğru bilgisayarı seçerek yeniden isteyebilirsin.' : 'Onayın süresi doldu. Bilgisayarı seçerek yeni bir kod oluştur.'),
        const SizedBox(height: 16),
        TextButton.icon(onPressed: busy ? null : _discover, icon: const Icon(Icons.refresh_rounded), label: const Text('Aramayı yeniden dene')),
        const SizedBox(height: 16),
        OutlinedButton.icon(onPressed: busy ? null : () async {
          final value = await Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => const ScanPairingScreen()));
          if (value != null && mounted) await _pairQr(value);
        }, icon: const Icon(Icons.qr_code_scanner_rounded), label: const Text('Alternatif: bilgisayardaki QR’ı okut')),
      ],
      if (error != null) ErrorNotice(error!),
      if (controller.error != null) ErrorNotice(controller.error!),
      const SizedBox(height: 24),
      Text('Veriler yalnızca telefonunda ve bilgisayarında kalır. Ağ kesilirse bağlantı otomatik yenilenir. Uyuyan bilgisayarda, Android zorla durdurulduğunda veya yerel ağ dışında erişim garanti edilmez.', style: text.bodySmall?.copyWith(height: 1.5, color: scheme.onSurfaceVariant)),
    ])));
  });
}

class ScanPairingScreen extends StatefulWidget {
  const ScanPairingScreen({super.key});
  @override
  State<ScanPairingScreen> createState() => _ScanPairingScreenState();
}
class _ScanPairingScreenState extends State<ScanPairingScreen> {
  final scanner = MobileScannerController(formats: [BarcodeFormat.qrCode]);
  bool accepted = false;
  @override
  void dispose() { scanner.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) => Scaffold(appBar: AppBar(title: const Text('Eşleştirme QR’ı')), body: SafeArea(top: false, child: Column(children: [const Padding(padding: EdgeInsets.all(24), child: Text('Bilgisayarındaki Omputer uygulamasının eşleştirme QR’ını çerçeveye al.')), Expanded(child: MobileScanner(controller: scanner, errorBuilder: (context, error) => EmptyState(icon: Icons.no_photography_outlined, title: 'Kamera açılamadı.', message: '${error.errorDetails?.message ?? 'Kamera iznini Android ayarlarından ver veya yakındaki bilgisayar aramasına geri dön.'}'), onDetect: (capture) {
    if (accepted) return;
    final value = capture.barcodes.map((b) => b.rawValue).whereType<String>().where((s) => s.startsWith('omputer://pair') || s.trimLeft().startsWith('{')).firstOrNull;
    if (value == null) return;
    accepted = true;
    Navigator.pop(context, value);
  }))])));
}
