import 'package:flutter/material.dart';
import 'controller.dart';
import 'models.dart';
import 'ui.dart';

/// Explicitly previews real, confined file text; never uploads a phone path.
class SessionFileContextScreen extends StatefulWidget {
  const SessionFileContextScreen({super.key, required this.controller, required this.projectId});
  final OmputerController controller;
  final String projectId;
  @override
  State<SessionFileContextScreen> createState() => _SessionFileContextScreenState();
}
class _SessionFileContextScreenState extends State<SessionFileContextScreen> {
  String path = '';
  final List<Json> entries = [];
  Object? cursor;
  bool hasMore = false, busy = false;
  String? error;
  Json? preview;
  String? selectedPath;
  @override
  void initState() { super.initState(); load(); }
  Future<void> load({bool more = false}) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      final result = await widget.controller.projectTree(widget.projectId, path: path, cursor: more ? cursor : null);
      if (mounted) setState(() { if (!more) entries.clear(); entries.addAll(objects(result['entries'])); cursor = result['nextCursor']; hasMore = result['hasMore'] == true; error = null; });
    } catch (e) { if (mounted) setState(() => error = '$e'); }
    finally { if (mounted) setState(() => busy = false); }
  }
  Future<void> select(Json entry) async {
    if (entry['kind'] == 'directory') { setState(() { path = '${entry['path']}'; preview = null; }); await load(); return; }
    setState(() => busy = true);
    try {
      final result = await widget.controller.file(widget.projectId, '${entry['path']}');
      if (result['binary'] == true) throw ControllerFailure('İkili dosya metin bağlamına eklenemez.');
      final text = '${result['text'] ?? ''}';
      if (text.length > 32000) throw ControllerFailure('Dosya bağlamı 32.000 karakter sınırını aşıyor. Daha küçük bir dosya seç.');
      if (mounted) setState(() { preview = result; selectedPath = '${entry['path']}'; error = null; });
    } catch (e) { if (mounted) setState(() => error = '$e'); }
    finally { if (mounted) setState(() => busy = false); }
  }
  @override
  Widget build(BuildContext context) => Scaffold(appBar: AppBar(title: const Text('Dosya bağlamı seç')), body: SafeArea(top: false, child: ListView(padding: const EdgeInsets.all(24), children: [
    const Text('Seçilen dosyanın gerçek metni ve proje içi yolu isteme açıkça eklenir. Dosya yüklemesi veya telefondaki bir yolun bilgisayarda okunacağı varsayılmaz. En çok 32.000 karakter.'),
    if (path.isNotEmpty) TextButton.icon(onPressed: busy ? null : () { path = path.contains('/') ? path.substring(0, path.lastIndexOf('/')) : ''; load(); }, icon: const Icon(Icons.arrow_upward_rounded), label: const Text('Üst dizin')),
    SelectableText(path.isEmpty ? 'Proje kökü' : path),
    if (busy) const LinearProgressIndicator(),
    if (error != null) ErrorNotice(error!),
    for (final entry in entries) ListTile(leading: Icon(entry['kind'] == 'directory' ? Icons.folder_outlined : Icons.description_outlined), title: Text('${entry['name']}'), onTap: busy ? null : () => select(entry)),
    if (hasMore) TextButton(onPressed: busy ? null : () => load(more: true), child: const Text('Diğer dosyaları yükle')),
    if (preview != null) ...[const Divider(), Text(selectedPath!, style: Theme.of(context).textTheme.titleMedium), if (preview!['truncated'] == true) const Text('Boyut sınırında kesilmiş metin. Yalnızca aşağıdaki kısım eklenir.'), SelectableText('${preview!['text'] ?? ''}'), const SizedBox(height: 16), FilledButton.icon(onPressed: () => Navigator.pop(context, {'type': 'fileText', 'path': selectedPath, 'text': preview!['text'], 'truncated': preview!['truncated'] == true}), icon: const Icon(Icons.attach_file_rounded), label: const Text('Görünen metni isteme ekle'))],
  ])));
}
