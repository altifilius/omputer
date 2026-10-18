import 'package:flutter/material.dart';
import 'controller.dart';
import 'models.dart';
import 'projects.dart';
import 'session.dart';
import 'ui.dart';

class ProjectFilesScreen extends StatefulWidget {
  const ProjectFilesScreen({super.key, required this.controller, required this.project});
  final OmputerController controller;
  final Project project;
  @override
  State<ProjectFilesScreen> createState() => _ProjectFilesScreenState();
}
class _ProjectFilesScreenState extends State<ProjectFilesScreen> {
  final search = TextEditingController();
  final entries = <Json>[];
  String path = '';
  String? cursor, error;
  bool changed = false, busy = false, more = false, truncated = false;
  int generation = 0;
  @override
  void initState() { super.initState(); load(); }
  @override
  void dispose() { generation++; search.dispose(); super.dispose(); }
  Future<void> load({bool append = false}) async {
    if (busy) return;
    final request = ++generation;
    setState(() { busy = true; error = null; if (!append) { entries.clear(); cursor = null; more = false; } });
    try {
      final result = changed ? await widget.controller.projectChanges(widget.project.id) : await widget.controller.projectTree(widget.project.id, path: path, query: search.text.trim(), cursor: append ? cursor : null);
      if (!mounted || request != generation) return;
      setState(() { entries.addAll(objects(result[changed ? 'files' : 'entries'])); cursor = result['nextCursor']?.toString(); more = result['hasMore'] == true; truncated = result['truncated'] == true; });
    } catch (e) { if (mounted && request == generation) setState(() => error = '$e'); }
    finally { if (mounted && request == generation) setState(() => busy = false); }
  }
  void directory(String value) { if (busy) return; setState(() => path = value); load(); }
  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: widget.controller, builder: (context, _) => Scaffold(
    appBar: AppBar(title: Text(widget.project.name), actions: [IconButton(tooltip: 'Dosya yoluyla aç', onPressed: () => openScreen(context, FilePreviewScreen(controller: widget.controller, project: widget.project)), icon: const Icon(Icons.description_outlined))]),
    body: SafeArea(top: false, child: ListView(children: [
      ConnectionBanner(widget.controller),
      Padding(padding: const EdgeInsets.fromLTRB(24, 12, 24, 8), child: const Text('Salt okunur dosyalar · git yalnızca değişiklikleri okumak için kullanılır; dosyalar ve git durumu değiştirilmez.')),
      Padding(padding: const EdgeInsets.symmetric(horizontal: 24), child: Wrap(spacing: 8, children: [ChoiceChip(label: const Text('Dosya ağacı'), selected: !changed, onSelected: busy ? null : (_) { setState(() { changed = false; }); load(); }), ChoiceChip(label: const Text('Değişen dosyalar'), selected: changed, onSelected: busy ? null : (_) { setState(() { changed = true; }); load(); })])),
      if (!changed) Padding(padding: const EdgeInsets.all(24), child: TextField(controller: search, enabled: !busy, textInputAction: TextInputAction.search, onSubmitted: (_) => load(), decoration: InputDecoration(labelText: 'Bu klasörde dosya ara', prefixIcon: const Icon(Icons.search_rounded), suffixIcon: IconButton(tooltip: 'Dosyaları ara', onPressed: busy ? null : load, icon: const Icon(Icons.arrow_forward_rounded))))),
      if (!changed) ListTile(contentPadding: const EdgeInsets.symmetric(horizontal: 24), leading: const Icon(Icons.drive_folder_upload_outlined), title: Text(path.isEmpty ? 'Proje kökü' : path), subtitle: path.isEmpty ? null : const Text('Üst klasöre dön'), onTap: path.isEmpty || busy ? null : () => directory(path.contains('/') ? path.substring(0, path.lastIndexOf('/')) : '')),
      if (busy) const LinearProgressIndicator(),
      if (error != null) ErrorNotice(error!, onRetry: load),
      if (!busy && error == null && entries.isEmpty) const Padding(padding: EdgeInsets.all(24), child: Text('Bu görünümde dosya yok.')),
      for (final entry in entries) ListTile(key: ValueKey('${changed ? 'diff' : 'tree'}:${entry['path']}'), contentPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8), leading: Icon(entry['kind'] == 'directory' ? Icons.folder_outlined : changed ? Icons.difference_outlined : Icons.description_outlined), title: Text('${entry['name'] ?? entry['path']}'), subtitle: changed ? Text('${entry['status'] ?? ''}${entry['oldPath'] == null ? '' : ' · önce: ${entry['oldPath']}'}') : null, trailing: const Icon(Icons.chevron_right_rounded), onTap: busy ? null : () {
        final target = '${entry['path']}';
        if (!changed && entry['kind'] == 'directory') { directory(target); } else if (changed) { openScreen(context, ProjectDiffScreen(controller: widget.controller, project: widget.project, path: target)); } else { openScreen(context, FilePreviewScreen(controller: widget.controller, project: widget.project, initialPath: target)); }
      }),
      if (truncated) const Padding(padding: EdgeInsets.all(24), child: Text('Değişiklik listesi boyut sınırında kesildi. Kalanını bilgisayarda incele.')),
      if (more) Padding(padding: const EdgeInsets.all(24), child: OutlinedButton(onPressed: busy ? null : () => load(append: true), child: const Text('Sonraki dosyaları yükle'))),
    ])),
  ));
}

class ProjectDiffScreen extends StatefulWidget {
  const ProjectDiffScreen({super.key, required this.controller, required this.project, required this.path});
  final OmputerController controller;
  final Project project;
  final String path;
  @override
  State<ProjectDiffScreen> createState() => _ProjectDiffScreenState();
}
class _ProjectDiffScreenState extends State<ProjectDiffScreen> {
  Json? result;
  String? error;
  bool busy = false;
  @override
  void initState() { super.initState(); load(); }
  Future<void> load() async {
    if (busy) return;
    setState(() { busy = true; error = null; result = null; });
    try { final value = await widget.controller.projectDiff(widget.project.id, widget.path); if (mounted) setState(() => result = value); }
    catch (e) { if (mounted) setState(() => error = '$e'); }
    finally { if (mounted) setState(() => busy = false); }
  }
  @override
  Widget build(BuildContext context) => Scaffold(appBar: AppBar(title: const Text('Salt okunur fark')), body: SafeArea(top: false, child: ListView(padding: const EdgeInsets.all(24), children: [
    SelectableText(widget.path),
    TextButton.icon(onPressed: () => openScreen(context, FilePreviewScreen(controller: widget.controller, project: widget.project, initialPath: widget.path)), icon: const Icon(Icons.description_outlined), label: const Text('Güncel dosyayı aç')),
    if (busy) const LinearProgressIndicator(),
    if (error != null) ErrorNotice(error!, onRetry: load),
    if (result?['binary'] == true) const Text('İkili dosya · metin farkı gösterilemez.'),
    if (result?['truncated'] == true) const Text('Fark boyut sınırında kesildi. Tam farkı bilgisayarda incele.'),
    if (result != null && result?['binary'] != true) CopyableCode(text: '${result!['text'] ?? ''}', language: 'diff'),
    if (result != null && result?['binary'] != true) for (final hunk in RegExp(r'^@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@.*$', multiLine: true).allMatches('${result!['text'] ?? ''}')) TextButton.icon(onPressed: () => openScreen(context, FilePreviewScreen(controller: widget.controller, project: widget.project, initialPath: widget.path, initialLine: int.parse(hunk.group(1)!))), icon: const Icon(Icons.subdirectory_arrow_right_rounded), label: Text('Güncel dosyada ${hunk.group(1)}. satıra git')),
  ])));
}

class SessionSearchScreen extends StatefulWidget {
  const SessionSearchScreen({super.key, required this.controller, this.projectId, this.sessionId, this.initialQuery = ''});
  final OmputerController controller;
  final String? projectId, sessionId;
  final String initialQuery;
  @override
  State<SessionSearchScreen> createState() => _SessionSearchScreenState();
}
class _SessionSearchScreenState extends State<SessionSearchScreen> {
  late final query = TextEditingController(text: widget.initialQuery);
  final results = <Json>[];
  String? cursor, error;
  bool busy = false, more = false;
  String loadedQuery = '';
  @override
  void initState() { super.initState(); if (widget.initialQuery.trim().isNotEmpty) load(); }
  @override
  void dispose() { query.dispose(); super.dispose(); }
  Future<void> load({bool append = false}) async {
    if (busy || query.text.trim().isEmpty) return;
    final text = append ? loadedQuery : query.text.trim();
    setState(() { busy = true; error = null; if (!append) { results.clear(); cursor = null; more = false; loadedQuery = text; } });
    try {
      final page = await widget.controller.search(text, projectId: widget.projectId, sessionId: widget.sessionId, cursor: append ? cursor : null);
      if (mounted) setState(() { results.addAll(objects(page['results'])); cursor = page['nextCursor']?.toString(); more = page['hasMore'] == true; });
    } catch (e) { if (mounted) setState(() => error = '$e'); }
    finally { if (mounted) setState(() => busy = false); }
  }
  @override
  Widget build(BuildContext context) => Scaffold(appBar: AppBar(title: const Text('Konuşmalarda ara')), body: SafeArea(top: false, child: ListView(children: [
    ConnectionBanner(widget.controller),
    Padding(padding: const EdgeInsets.all(24), child: TextField(controller: query, enabled: !busy, autofocus: widget.initialQuery.isEmpty, textInputAction: TextInputAction.search, onSubmitted: (_) => load(), decoration: InputDecoration(labelText: 'Yerel konuşma içeriği', prefixIcon: const Icon(Icons.search_rounded), suffixIcon: IconButton(tooltip: 'Ara', onPressed: busy ? null : load, icon: const Icon(Icons.arrow_forward_rounded))))),
    if (busy) const LinearProgressIndicator(),
    if (error != null) ErrorNotice(error!, onRetry: load),
    if (!busy && loadedQuery.isNotEmpty && error == null && results.isEmpty) const Padding(padding: EdgeInsets.all(24), child: Text('Eşleşen konuşma bulunamadı.')),
    for (final result in results) ListTile(contentPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12), title: Text('${result['title'] ?? widget.controller.snapshot.session('${result['sessionId']}')?.name ?? 'Konuşma'}'), subtitle: Text('${result['snippet'] ?? ''}', maxLines: 4, overflow: TextOverflow.ellipsis), trailing: const Icon(Icons.arrow_forward_rounded), onTap: () => openScreen(context, SessionScreen(controller: widget.controller, sessionId: '${result['sessionId']}', initialMessageId: result['messageId']?.toString()))),
    if (more) Padding(padding: const EdgeInsets.all(24), child: OutlinedButton(onPressed: busy ? null : () => load(append: true), child: const Text('Daha fazla sonuç'))),
  ])));
}
