import 'package:flutter/material.dart';
import 'controller.dart';
import 'ui.dart';
import 'models.dart';
import 'diagnostics.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.controller});
  final OmputerController controller;
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}
class _SettingsScreenState extends State<SettingsScreen> {
  bool busy = false;
  Future<void> run(Future<void> Function() action) async {
    if (busy) return;
    setState(() => busy = true);
    await perform(context, action);
    if (mounted) setState(() => busy = false);
  }
  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: widget.controller, builder: (context, _) {
    final c = widget.controller;
    final connection = c.connection;
    return ListView(padding: const EdgeInsets.only(bottom: 40), children: [
      const SectionHeading('Senin bilgisayarın'),
      ListTile(contentPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8), leading: Icon(connection.connected ? Icons.link_rounded : Icons.link_off_rounded), title: Text(connection.serverName.isEmpty ? 'Eşleştirilmiş bilgisayar' : connection.serverName), subtitle: Text('${connection.connected ? 'Bağlı' : 'Çevrimdışı · kaydedilmiş görünüm · otomatik yeniden bağlanıyor'}\n${connection.url}')),
      Padding(padding: const EdgeInsets.symmetric(horizontal: 24), child: OutlinedButton.icon(onPressed: busy ? null : () => run(c.reconnect), icon: const Icon(Icons.refresh_rounded), label: const Text('Şimdi yeniden dene'))),
      if (connection.lastError != null) ErrorNotice(connection.lastError!),
      if (c.error != null) ErrorNotice(c.error!),
      const SectionHeading('Bileşenler ve eşitleme'),
      ListTile(contentPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8), leading: const Icon(Icons.sync_rounded), title: Text(connection.cacheFresh ? 'Önbellek güncel' : 'Önbellek eski veya güncelliği bilinmiyor'), subtitle: Text('Son eşitleme: ${dateLabel(connection.lastSyncAt)}\n${connection.connected ? 'Canlı bağlantı açık' : 'Kaydedilmiş veriler gösteriliyor'}')),
      if (connection.components.isNotEmpty) Padding(padding: const EdgeInsets.symmetric(horizontal: 24), child: SelectableText(connection.components.entries.map((entry) => '${entry.key}: ${entry.value}').join('\n'))),
      ListTile(contentPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8), leading: const Icon(Icons.fact_check_outlined), title: const Text('Çalışan / kurulu bileşenler ve bakım'), subtitle: const Text('Gerçek sürümler, özetler, güncelleme engelleri, yerel yedek durumu ve içeriksiz tanı.'), trailing: const Icon(Icons.chevron_right_rounded), onTap: () => openScreen(context, DiagnosticsScreen(controller: c))),
      const SectionHeading('Arka planda erişim'),
      SwitchListTile(contentPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8), title: const Text('Arka plan bağlantısı'), subtitle: Text(connection.backgroundRunning ? 'Android’de görünür bağlı-cihaz hizmeti çalışıyor.' : connection.background ? 'Tercih açık; arka plan hizmeti şu anda çalışmıyor. Uygulama açıkken bağlantı sürer.' : 'Uygulama açıkken bağlanır. Açarsan Android’de görünür bağlı-cihaz bildirimiyle sürer.'), value: connection.background, onChanged: busy ? null : (value) => run(() async { if (value && !connection.notifications) { await c.requestNotifications(); if (!c.connection.notifications) throw ControllerFailure('Arka plan bağlantısı açılmadı. Önce Android ayarlarından bildirim izni ver, sonra yeniden dene.', 'notifications_required'); } await c.setBackground(value); })),
      ListTile(contentPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8), leading: const Icon(Icons.notifications_outlined), title: const Text('Bildirim izni'), subtitle: Text(connection.notifications ? 'İzin verilmiş' : 'İzin verilmemiş · karar bildirimleri gösterilemez'), trailing: connection.notifications ? const Icon(Icons.check_rounded) : const Icon(Icons.chevron_right_rounded), onTap: busy ? null : () => run(c.requestNotifications)),
      ListTile(contentPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8), leading: const Icon(Icons.battery_saver_outlined), title: const Text('Pil optimizasyonu'), subtitle: Text(connection.batteryExempt ? 'Optimizasyon kısıtlaması dışında' : 'Android arka plan bağlantısını kısıtlayabilir. Sistem ayarını incele.'), trailing: const Icon(Icons.open_in_new_rounded), onTap: busy ? null : () => run(c.batterySettings)),
      const Padding(padding: EdgeInsets.fromLTRB(24, 12, 24, 8), child: Text('Bildirimler doğrudan yerel bağlantıdan üretilir; FCM veya bir bulut aktarıcısı yoktur. Android’de zorla durdurma, ağ kaybı ve uyuyan bilgisayarda teslimat garanti edilmez. Ev dışı erişim için sana ait erişilebilir rota / WireGuard gerekir.')),
      const SectionHeading('Bildirim kapsamı'),
      CheckboxListTile(contentPadding: const EdgeInsets.symmetric(horizontal: 24), title: const Text('Karar bildirimlerini göster'), subtitle: const Text('Bu bilgisayar ve bu telefon eşleştirmesine özel tercih.'), value: object(object(c.localState['sections'])['notificationPreferences'])['global'] != false, onChanged: busy ? null : (value) => run(() => c.updateLocalState('notificationPreferences', 'global', value == true))),
      for (final project in c.snapshot.projects) CheckboxListTile(contentPadding: const EdgeInsets.symmetric(horizontal: 24), title: Text(project.name), subtitle: const Text('Bu projenin karar bildirimleri'), value: object(object(c.localState['sections'])['notificationPreferences'])['project:${project.id}'] != false, onChanged: busy ? null : (value) => run(() => c.updateLocalState('notificationPreferences', 'project:${project.id}', value == true))),
      const SectionHeading('Görünüm'),
      Padding(padding: const EdgeInsets.symmetric(horizontal: 24), child: DropdownButtonFormField<String>(key: ValueKey(c.theme), initialValue: c.theme, isExpanded: true, decoration: const InputDecoration(labelText: 'Tema'), items: const [DropdownMenuItem(value: 'system', child: Text('Sistemle aynı')), DropdownMenuItem(value: 'light', child: Text('Açık · serin porselen')), DropdownMenuItem(value: 'dark', child: Text('Koyu · gece mavisi'))], onChanged: busy ? null : (value) { if (value != null) run(() => c.setTheme(value)); })),
      const Padding(padding: EdgeInsets.fromLTRB(24, 16, 24, 0), child: Text('Yazı boyutu ve Animasyonları kaldır tercihi Android erişilebilirlik ayarlarından izlenir.')),
      const SectionHeading('Yetkili cihazlar'),
      if (c.snapshot.devices.isEmpty) const Padding(padding: EdgeInsets.symmetric(horizontal: 24), child: Text('Cihaz listesi henüz alınmadı. Bağlantıyı yenile.')),
      for (final device in c.snapshot.devices) ListTile(contentPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8), leading: Icon(device.revokedAt == null ? Icons.smartphone_rounded : Icons.phonelink_erase_rounded), title: Text(device.name), subtitle: Text(device.revokedAt == null ? 'Son bağlantı: ${dateLabel(device.lastSeenAt)}' : 'Erişimi kaldırıldı · ${dateLabel(device.revokedAt)}'), trailing: device.revokedAt == null ? IconButton(tooltip: '${device.name} erişimini kaldır', onPressed: busy || !connection.connected ? null : () async {
        if (await confirm(context, 'Cihaz erişimini kaldır?', '${device.name} bilgisayara artık bağlanamaz. Bu telefonun erişimini kaldırırsan yeniden eşleştirme gerekir.', action: 'Erişimi kaldır') && mounted) await run(() => c.revoke(device.id));
      }, icon: const Icon(Icons.remove_circle_outline_rounded)) : null),
      const SectionHeading('Yerel veriler'),
      ListTile(contentPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8), leading: const Icon(Icons.link_off_rounded), title: const Text('Bu bilgisayarı unut'), subtitle: const Text('Telefondaki şifreli kimlik ve önbelleği siler. Bilgisayardaki cihaz yetkisini ayrıca kaldırmalısın; çalışan oturumlar durmaz.'), onTap: busy ? null : () async {
        if (await confirm(context, 'Eşleştirmeyi ve önbelleği sil?', 'Bilgisayarındaki oturumlar ve dosyalar silinmez. Bu telefondan tekrar erişmek için yeni eşleştirme gerekir.', action: 'Unut') && mounted) await run(c.forget);
      }),
      Padding(padding: const EdgeInsets.fromLTRB(24, 24, 24, 0), child: Text('Omputer${c.appVersion == null ? '' : ' · ${c.appVersion}${c.buildNumber == null ? '' : ' (${c.buildNumber})'}'}${c.protocol == null ? '' : ' · protokol ${c.protocol}'}\nUygulama verileri yalnızca telefonunda ve bilgisayarında. OMP’nin mevcut model sağlayıcısı kullanımı değişmez.')),
    ]);
  });
}
