import 'dart:convert';
import 'package:flutter/material.dart';
import 'controller.dart';
import 'models.dart';
import 'ui.dart';

class DiagnosticsScreen extends StatefulWidget {
  const DiagnosticsScreen({super.key, required this.controller});
  final OmputerController controller;
  @override
  State<DiagnosticsScreen> createState() => _DiagnosticsScreenState();
}
class _DiagnosticsScreenState extends State<DiagnosticsScreen> {
  Json? diagnosis;
  String? error;
  bool busy = false;
  @override
  void initState() { super.initState(); load(); }
  Future<void> load() async {
    if (busy) return;
    setState(() { busy = true; error = null; diagnosis = null; });
    try { final value = await widget.controller.request('GET', '/v1/diagnostics'); if (mounted) setState(() => diagnosis = value); }
    catch (e) { if (mounted) setState(() => error = '$e'); }
    finally { if (mounted) setState(() => busy = false); }
  }
  @override
  Widget build(BuildContext context) {
    final update = object(diagnosis?['update']);
    final backups = object(diagnosis?['backups']);
    final components = object(diagnosis?['components']);
    final blockers = objects(update['blockers']);
    return Scaffold(appBar: AppBar(title: const Text('Yerel tanı ve bakım'), actions: [IconButton(tooltip: 'Tanıyı yenile', onPressed: busy ? null : load, icon: const Icon(Icons.refresh_rounded))]), body: SafeArea(top: false, child: ListView(padding: const EdgeInsets.all(24), children: [
      ConnectionBanner(widget.controller),
      const Text('Bilgisayardan salt okunur tanı. Konuşmalar, dosya içerikleri, kimlik anahtarları ve erişim belirteçleri dışa aktarılmaz. Güncelleme ve geri yükleme bilgisayar uygulamasından açık onayla yapılır.'),
      const SizedBox(height: 24),
      if (busy) const LinearProgressIndicator(),
      if (error != null) ErrorNotice(error!, onRetry: load),
      if (diagnosis != null) ...[
        Text('Bileşenler', style: Theme.of(context).textTheme.titleLarge),
        if (components.isEmpty) const Text('Bileşen bilgisi bilgisayardan gelmedi.'),
        for (final component in components.entries) Padding(padding: const EdgeInsets.symmetric(vertical: 12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(component.key, style: Theme.of(context).textTheme.titleMedium), SelectableText(_display(component.value))])),
        const SizedBox(height: 24),
        Text('Güncelleme durumu', style: Theme.of(context).textTheme.titleLarge),
        Text(update['updatePending'] == true ? 'Güncelleme bekliyor' : 'Bekleyen güncelleme yok'),
        if (blockers.isNotEmpty) ...[const Text('Güncellemeyi engelleyen işler:'), for (final blocker in blockers) SelectableText('${blocker['reason'] ?? blocker['kind'] ?? 'Etkin iş'}${blocker['sessionId'] == null ? '' : '\nOturum: ${blocker['sessionId']}'}')] else const Text('Bilgisayarın bildirdiği etkin iş engeli yok.'),
        for (final key in ['managedRpcSessions', 'admittedCommands', 'inflightResponses']) if (update.containsKey(key)) SelectableText('$key: ${_display(update[key])}'),
        const SizedBox(height: 24),
        Text('Yerel yedekler', style: Theme.of(context).textTheme.titleLarge),
        if (objects(backups['items']).isEmpty) const Text('Bilgisayarın bildirdiği yedek yok.'),
        for (final item in objects(backups['items'])) ListTile(contentPadding: EdgeInsets.zero, leading: const Icon(Icons.backup_outlined), title: Text('${item['id']}'), subtitle: Text('${dateLabel(instant(item['createdAt']))} · ${item['bytes'] ?? '?'} bayt · ${item['journals'] ?? '?'} günlük')),
        if (backups['identityPolicy'] != null) SelectableText('${backups['identityPolicy']}'),
        const SizedBox(height: 24),
        OutlinedButton.icon(onPressed: () => copyText(context, const JsonEncoder.withIndent('  ').convert(diagnosis)), icon: const Icon(Icons.copy_rounded), label: const Text('İçeriksiz tanıyı kopyala')),
      ],
    ])));
  }
  String _display(Object? value) => value is Map || value is List ? const JsonEncoder.withIndent('  ').convert(value) : '$value';
}
