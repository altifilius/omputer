import 'dart:convert';
import 'package:flutter/material.dart';
import 'controller.dart';
import 'models.dart';
import 'neumorphic.dart';
import 'ui.dart';
import 'session.dart' show textDialog;
import 'session_controls.dart' show OperationsScreen;

/// Every write uses the session's catalog and writer identity, never a shell.
class SessionAdminScreen extends StatefulWidget {
  const SessionAdminScreen({super.key, required this.controller, required this.sessionId, required this.view});
  final OmputerController controller;
  final String sessionId, view;
  @override
  State<SessionAdminScreen> createState() => _SessionAdminScreenState();
}

class _SessionAdminScreenState extends State<SessionAdminScreen> {
  final search = TextEditingController();
  Json? data;
  String? error;
  bool busy = false;
  bool savedScope = false;
  @override
  void initState() { super.initState(); search.addListener(_searchChanged); load(); }
  @override
  void dispose() { search.removeListener(_searchChanged); search.dispose(); super.dispose(); }
  void _searchChanged() { if (mounted) setState(() {}); }
  String get title => switch (widget.view) {
    'settings' => 'OMP ayarları', 'skills' => 'Beceriler',
    'logout' => 'Hesap oturumları', _ => 'Sağlayıcı kurulumu',
  };
  Future<void> load({Json arguments = const {}}) async {
    if (busy) return;
    setState(() { busy = true; error = null; });
    try {
      final result = await widget.controller.controls(widget.sessionId, widget.view, arguments: arguments);
      if (mounted) setState(() => data = result);
    } catch (failure) { if (mounted) setState(() => error = '$failure'); }
    finally { if (mounted) setState(() => busy = false); }
  }
  Future<void> run(Json arguments, String description) async {
    if (busy || !await confirm(context, 'Bilgisayarda değişikliği uygula?', description, action: 'Uygula') || !mounted) return;
    setState(() { busy = true; error = null; });
    try {
      final catalog = await widget.controller.controls(widget.sessionId, 'commands');
      final name = arguments['action'] == 'login' ? 'login' : arguments['action'] == 'logout' ? 'logout' : widget.view;
      final command = objects(catalog['commands']).where((item) => item['name'] == name).firstOrNull;
      if (command == null || command['available'] != true) throw ControllerFailure('Bu oturum işlemi sunmuyor. Komut kataloğunu yenile.');
      final result = await widget.controller.executeCommand(widget.sessionId, '${command['id']}', jsonEncode(arguments), catalogRevision: catalog['catalogRevision'], confirmed: true);
      if (mounted) {
        if (result['id'] is String) await Navigator.push<void>(context, MaterialPageRoute(builder: (_) => OperationsScreen(controller: widget.controller, sessionId: widget.sessionId, operationId: result['id'])));
        if (mounted) setState(() => busy = false);
        await load();
      }
    } on CommandAccepted catch (accepted) {
      if (mounted) await Navigator.push<void>(context, MaterialPageRoute(builder: (_) => OperationsScreen(controller: widget.controller, sessionId: widget.sessionId, operationId: accepted.id)));
    } on CommandUncertain catch (uncertain) {
      if (mounted) await Navigator.push<void>(context, MaterialPageRoute(builder: (_) => OperationsScreen(controller: widget.controller, sessionId: widget.sessionId, operationId: uncertain.id)));
    } catch (failure) { if (mounted) setState(() => error = '$failure'); }
    finally { if (mounted) setState(() => busy = false); }
  }
  Future<void> setting(Json item, {bool reset = false}) async {
    final key = '${item['key']}';
    final scope = savedScope ? 'saved' : 'session';
    Object? value;
    if (!reset && item['credential'] != true) {
      if (item['type'] == 'boolean') {
        value = item['value'] != true;
      } else if (strings(item['choices']).isNotEmpty) {
        value = await showDialog<String>(context: context, builder: (context) => SimpleDialog(title: Text('${item['label'] ?? key}'), children: [for (final choice in strings(item['choices'])) SimpleDialogOption(onPressed: () => Navigator.pop(context, choice), child: Text(choice))]));
        if (value == null) return;
      } else {
        final text = await textDialog(context, '${item['label'] ?? key}', item['type'] == 'string' ? 'Değer' : 'JSON değeri', initial: item['type'] == 'string' ? '${item['value'] ?? ''}' : jsonEncode(item['value']), message: '${item['description'] ?? key}\nKapsam: ${savedScope ? 'Kalıcı bilgisayar ayarı' : 'Yalnız bu oturum'}');
        if (text == null) return;
        try { value = item['type'] == 'string' ? text : jsonDecode(text); }
        catch (_) { if (mounted) setState(() => error = 'Değer geçerli JSON değil. Önceki ayar korunuyor.'); return; }
      }
    }
    if (!mounted) return;
    await run({'action': reset ? 'reset' : 'set', 'key': key, 'scope': scope, if (!reset && item['credential'] != true) 'value': value}, '${reset ? 'Varsayılana dön' : 'Ayarı değiştir'}: $key\nKapsam: ${savedScope ? 'Kalıcı bilgisayar ayarı' : 'Yalnız bu oturum'}\n${item['credential'] == true ? 'Gizli değer ayrı korumalı girişte sorulacak; işlem geçmişine yazılmaz.' : reset ? '' : 'Yeni değer: ${jsonEncode(value)}'}');
  }
  @override
  Widget build(BuildContext context) {
    final enabled = !busy && widget.controller.connection.connected;
    return Scaffold(appBar: AppBar(title: Text(title), actions: [IconButton(tooltip: 'Güncel bilgileri al', onPressed: busy ? null : () => load(), icon: const Icon(Icons.refresh_rounded))]), body: SafeArea(top: false, child: ListView(padding: const EdgeInsets.all(24), children: [
      if (busy) const LinearProgressIndicator(),
      if (error != null) ErrorNotice(error!, onRetry: busy ? null : () => load()),
      if (widget.view == 'settings') ...[
        TextField(controller: search, onChanged: (_) => setState(() {}), decoration: const InputDecoration(labelText: 'Ayar ara', prefixIcon: Icon(Icons.search_rounded))),
        const SizedBox(height: 16),
        NeoSurface(depth: NeoDepth.inset, child: SwitchListTile(contentPadding: const EdgeInsets.symmetric(horizontal: 16), title: const Text('Kalıcı bilgisayar ayarı'), subtitle: const Text('Kapalıyken yalnız bu oturumu değiştirir'), value: savedScope, onChanged: enabled ? (value) => setState(() => savedScope = value) : null)),
        const SizedBox(height: 24),
        for (final item in objects(data?['settings']).where((item) => '${item['key']} ${item['label']} ${item['description']}'.toLowerCase().contains(search.text.toLowerCase()))) Padding(padding: const EdgeInsets.only(bottom: 16), child: NeoSurface(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('${item['label'] ?? item['key']}', style: Theme.of(context).textTheme.titleMedium), const SizedBox(height: 8), Text('${item['description'] ?? item['key']}'),
          const SizedBox(height: 8), Text(item['credential'] == true ? 'Gizli değer · gösterilmez' : '${item['value']}'), Text('Kaynak: ${item['provenance'] ?? 'bilinmiyor'}', style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 12), Wrap(spacing: 8, runSpacing: 8, children: [OutlinedButton(onPressed: enabled ? () => setting(item) : null, child: const Text('Değiştir')), TextButton(onPressed: enabled ? () => setting(item, reset: true) : null, child: const Text('Varsayılana dön'))]),
        ]))),
      ] else if (widget.view == 'skills') ...[
        TextField(controller: search, decoration: const InputDecoration(labelText: 'Beceri adı veya arama sözcüğü'), onSubmitted: (value) => load(arguments: {'action': 'search', 'query': value})), const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 8, children: [OutlinedButton(onPressed: enabled && search.text.trim().isNotEmpty ? () => load(arguments: {'action': 'search', 'query': search.text.trim()}) : null, child: const Text('Ara')), OutlinedButton(onPressed: enabled ? () async { final names = await textDialog(context, 'Beceri kur', '@kapsam/ad veya @kapsam/ad@sürüm'); if (names != null && names.trim().isNotEmpty) await run({'action': 'install', 'targets': names.trim().split(RegExp(r'\s+')), 'global': savedScope}, 'Becerileri ${savedScope ? 'kullanıcı geneline' : 'bu projeye'} kur:\n$names'); } : null, child: const Text('Kur')), OutlinedButton(onPressed: enabled ? () => run({'action': 'update', 'targets': <String>[], 'global': savedScope}, '${savedScope ? 'Kullanıcı genelindeki' : 'Bu projedeki'} kayıtlı becerileri tanımlı sürüm aralıklarında güncelle') : null, child: const Text('Güncelle'))]),
        const SizedBox(height: 16), SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Kullanıcı geneli'), subtitle: const Text('Kapalıyken yalnız bu proje'), value: savedScope, onChanged: enabled ? (value) => setState(() => savedScope = value) : null),
        const SizedBox(height: 16), if (data != null) SelectableText(const JsonEncoder.withIndent('  ').convert(data)),
      ] else ...[
        const Text('Hesap girişi tarayıcıda kullanıcı onayı gerektirir. Gizli değerler ayrı korumalı alanda sorulur; konuşmaya veya taslağa kaydedilmez.'), const SizedBox(height: 24),
        for (final provider in objects(data?['providers'])) Padding(padding: const EdgeInsets.only(bottom: 16), child: NeoSurface(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('${provider['name'] ?? provider['id']}', style: Theme.of(context).textTheme.titleMedium), const SizedBox(height: 8), Text(provider['authenticated'] == true ? 'Kayıtlı hesap mevcut' : 'Giriş yapılmamış'),
          const SizedBox(height: 12), OutlinedButton(onPressed: enabled && provider['available'] != false ? () => run({'action': 'login', 'providerId': provider['id']}, '${provider['name'] ?? provider['id']} hesabına giriş başlat') : null, child: const Text('Hesap ekle')),
          for (final account in objects(provider['accounts'])) ListTile(contentPadding: EdgeInsets.zero, title: Text('${account['label'] ?? account['credentialId']}'), subtitle: Text('${account['detail'] ?? account['type'] ?? ''}'), trailing: IconButton(tooltip: 'Bu hesaptan çık', onPressed: enabled ? () => run({'action': 'logout', 'providerId': provider['id'], 'credentialId': account['credentialId']}, '${provider['name'] ?? provider['id']}\nHesap: ${account['label'] ?? account['credentialId']}\nBu kayıtlı kimlik bilgisini bilgisayardan kaldır') : null, icon: const Icon(Icons.logout_rounded))),
        ]))),
      ],
      if (data == null && !busy && error == null) const Text('Bilgi alınamadı. Güncel bilgileri yeniden al.'),
    ])));
  }
}
