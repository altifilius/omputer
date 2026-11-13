import 'package:flutter/material.dart';
import 'controller.dart';
import 'models.dart';
import 'neumorphic.dart';
import 'session.dart';
import 'ui.dart';

class MemoryHistoryScreen extends StatefulWidget {
  const MemoryHistoryScreen({super.key, required this.controller, required this.project});
  final OmputerController controller;
  final Project project;
  @override
  State<MemoryHistoryScreen> createState() => _MemoryHistoryScreenState();
}
class _MemoryHistoryScreenState extends State<MemoryHistoryScreen> {
  final entries = <Json>[];
  int? before;
  String? error;
  bool busy = false, more = false;
  @override
  void initState() { super.initState(); load(); }
  Future<void> load({bool append = false}) async {
    if (busy) return;
    setState(() { busy = true; error = null; if (!append) { entries.clear(); before = null; } });
    try {
      final value = await widget.controller.memoryHistory(widget.project.id, before: append ? before : null);
      if (mounted) setState(() { entries.addAll(objects(value['entries'])); before = int.tryParse('${value['nextCursor'] ?? ''}'); more = value['hasMore'] == true; });
    } catch (e) { if (mounted) setState(() => error = '$e'); }
    finally { if (mounted) setState(() => busy = false); }
  }
  @override
  Widget build(BuildContext context) => Scaffold(appBar: AppBar(title: const Text('Hafıza sürüm geçmişi'), actions: [IconButton(tooltip: 'Geçmişi yenile', onPressed: busy ? null : load, icon: const Icon(Icons.refresh_rounded))]), body: SafeArea(top: false, child: ListView(children: [
    ConnectionBanner(widget.controller),
    Padding(padding: const EdgeInsets.all(24), child: Text('${widget.project.name}\nSalt okunur geçmiş. Eski sürümü açmak güncel hafızayı değiştirmez.')),
    if (busy) const LinearProgressIndicator(),
    if (error != null) ErrorNotice(error!, onRetry: load),
    if (!busy && error == null && entries.isEmpty) const Padding(padding: EdgeInsets.all(24), child: Text('Kaydedilmiş hafıza sürümü yok.')),
    for (final entry in entries) Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6), child: NeoSurface(radius: 20, compact: true, child: ExpansionTile(key: ValueKey('revision:${entry['sequence']}'), tilePadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4), childrenPadding: const EdgeInsets.fromLTRB(20, 0, 20, 20), expandedCrossAxisAlignment: CrossAxisAlignment.stretch, shape: const Border(), collapsedShape: const Border(), title: Text('Sürüm ${entry['revision']} · ${entry['origin'] == 'agent' ? 'Ajan kaydı' : 'Elle düzenleme'}'), subtitle: Text(dateLabel(instant(entry['createdAt']))), children: [
      for (final field in [('goal', 'Hedef'), ('summary', 'Durum özeti'), ('nextStep', 'Sonraki adım')]) ...[
        Align(alignment: Alignment.centerLeft, child: Text(field.$2, style: Theme.of(context).textTheme.titleSmall)),
        Align(alignment: Alignment.centerLeft, child: LocalMarkdown(data: '${object(entry['memory'])[field.$1] ?? ''}')),
        const SizedBox(height: 16),
      ],
      for (final decision in strings(object(entry['memory'])['decisions'])) Align(alignment: Alignment.centerLeft, child: LocalMarkdown(data: decision)),
      if (entry['sourceSessionId'] != null) TextButton.icon(onPressed: () => openScreen(context, SessionScreen(controller: widget.controller, sessionId: '${entry['sourceSessionId']}')), icon: const Icon(Icons.commit_rounded), label: const Text('Kaynak oturumu aç')),
    ]))),
    if (more) Padding(padding: const EdgeInsets.all(24), child: OutlinedButton(onPressed: busy ? null : () => load(append: true), child: const Text('Önceki sürümler'))),
  ])));
}
