import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'controller.dart';
import 'models.dart';
import 'neumorphic.dart';


ThemeData omputerTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final neo = NeoPalette.forBrightness(brightness);
  final foreground = dark ? const Color(0xfff1f3f5) : const Color(0xff252c35);
  final secondary = dark ? const Color(0xffc0c6cf) : const Color(0xff505b68);
  final accent = dark ? const Color(0xfff3ca68) : const Color(0xff775500);
  final scheme = ColorScheme.fromSeed(seedColor: const Color(0xffa87920), brightness: brightness).copyWith(
    primary: accent, onPrimary: dark ? const Color(0xff272016) : Colors.white,
    primaryContainer: dark ? const Color(0xff463c28) : const Color(0xfff1dfb5),
    onPrimaryContainer: dark ? const Color(0xffffe3a2) : const Color(0xff4a370d),
    secondary: secondary, onSecondary: neo.base,
    secondaryContainer: neo.inset, onSecondaryContainer: foreground,
    tertiary: accent, onTertiary: neo.base,
    surface: neo.base, onSurface: foreground, onSurfaceVariant: secondary,
    surfaceContainerLowest: neo.inset, surfaceContainerLow: neo.raised,
    surfaceContainer: neo.base, surfaceContainerHigh: neo.raised, surfaceContainerHighest: neo.inset,
    outline: dark ? const Color(0xff8e98a5) : const Color(0xff677482),
    outlineVariant: dark ? const Color(0xff454e5b) : const Color(0xffbdc7d1),
    shadow: neo.shadow,
  );
  final border = NeoInputBorder(palette: neo, borderSide: BorderSide(color: scheme.outlineVariant));
  final buttons = neoButtonStyle(primary: true).copyWith(
    foregroundColor: WidgetStateProperty.resolveWith((states) => states.contains(WidgetState.disabled) ? secondary : scheme.onPrimary),
  );
  final secondaryButtons = neoButtonStyle().copyWith(
    foregroundColor: WidgetStateProperty.resolveWith((states) => states.contains(WidgetState.disabled) ? secondary.withValues(alpha: .7) : foreground),
  );
  final text = Typography.material2021(platform: TargetPlatform.android).black.apply(bodyColor: foreground, displayColor: foreground);
  return ThemeData(
    useMaterial3: true, colorScheme: scheme, extensions: [neo],
    scaffoldBackgroundColor: neo.base, canvasColor: neo.base,
    appBarTheme: AppBarTheme(backgroundColor: neo.base, foregroundColor: foreground, centerTitle: false, elevation: 0, scrolledUnderElevation: 0, surfaceTintColor: Colors.transparent, titleTextStyle: text.titleLarge?.copyWith(fontWeight: FontWeight.w600)),
    navigationBarTheme: NavigationBarThemeData(backgroundColor: Colors.transparent, surfaceTintColor: Colors.transparent, elevation: 0, indicatorColor: neo.inset, indicatorShape: NeoInputBorder(palette: neo, borderRadius: BorderRadius.circular(16), borderSide: BorderSide(color: scheme.outlineVariant)), labelTextStyle: WidgetStateProperty.resolveWith((states) => text.labelMedium?.copyWith(color: states.contains(WidgetState.selected) ? accent : secondary, fontWeight: states.contains(WidgetState.selected) ? FontWeight.w600 : FontWeight.w400)), iconTheme: WidgetStateProperty.resolveWith((states) => IconThemeData(color: states.contains(WidgetState.selected) ? accent : secondary))),
    navigationRailTheme: NavigationRailThemeData(backgroundColor: Colors.transparent, indicatorColor: neo.inset, indicatorShape: NeoInputBorder(palette: neo, borderRadius: BorderRadius.circular(16)), selectedIconTheme: IconThemeData(color: accent), unselectedIconTheme: IconThemeData(color: secondary), selectedLabelTextStyle: TextStyle(color: accent)),
    inputDecorationTheme: InputDecorationTheme(filled: true, fillColor: neo.inset, border: border, enabledBorder: border, disabledBorder: border.copyWith(borderSide: BorderSide(color: scheme.outlineVariant.withValues(alpha: .5))), focusedBorder: border.copyWith(borderSide: BorderSide(color: accent, width: 2)), errorBorder: border.copyWith(borderSide: BorderSide(color: scheme.error)), focusedErrorBorder: border.copyWith(borderSide: BorderSide(color: scheme.error, width: 2)), labelStyle: TextStyle(color: secondary), hintStyle: TextStyle(color: secondary), floatingLabelStyle: TextStyle(color: accent), contentPadding: const EdgeInsets.all(16)),
    filledButtonTheme: FilledButtonThemeData(style: buttons),
    outlinedButtonTheme: OutlinedButtonThemeData(style: secondaryButtons),
    textButtonTheme: TextButtonThemeData(style: TextButton.styleFrom(minimumSize: const Size(48, 48), foregroundColor: accent, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)))),
    iconButtonTheme: IconButtonThemeData(style: neoButtonStyle(compact: true).copyWith(foregroundColor: WidgetStateProperty.resolveWith((states) => states.contains(WidgetState.disabled) ? secondary.withValues(alpha: .5) : foreground))),
    chipTheme: ChipThemeData(backgroundColor: neo.raised, selectedColor: neo.inset, disabledColor: neo.base, labelStyle: TextStyle(color: foreground), secondaryLabelStyle: TextStyle(color: accent), checkmarkColor: accent, side: BorderSide(color: scheme.outlineVariant), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)), padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8), elevation: 0, pressElevation: 0, showCheckmark: true),
    listTileTheme: ListTileThemeData(iconColor: secondary, textColor: foreground, selectedColor: accent, selectedTileColor: neo.inset, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)), minVerticalPadding: 12),
    expansionTileTheme: ExpansionTileThemeData(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)), collapsedShape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)), backgroundColor: neo.inset, collapsedBackgroundColor: neo.raised, iconColor: accent, collapsedIconColor: secondary, textColor: foreground, collapsedTextColor: foreground),
    dialogTheme: DialogThemeData(backgroundColor: neo.raised, surfaceTintColor: Colors.transparent, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24), side: BorderSide(color: scheme.outlineVariant))),
    bottomSheetTheme: BottomSheetThemeData(backgroundColor: neo.raised, surfaceTintColor: Colors.transparent, shape: RoundedRectangleBorder(borderRadius: const BorderRadius.vertical(top: Radius.circular(24)), side: BorderSide(color: scheme.outlineVariant))),
    popupMenuTheme: PopupMenuThemeData(color: neo.raised, surfaceTintColor: Colors.transparent, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: BorderSide(color: scheme.outlineVariant))),
    snackBarTheme: SnackBarThemeData(backgroundColor: foreground, contentTextStyle: TextStyle(color: neo.base), behavior: SnackBarBehavior.floating, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
    textSelectionTheme: TextSelectionThemeData(cursorColor: accent, selectionColor: accent.withValues(alpha: .24), selectionHandleColor: accent),
    dividerTheme: DividerThemeData(color: scheme.outlineVariant.withValues(alpha: .65), space: 1),
    textTheme: text,
  );
}

String dateLabel(DateTime? time) {
  if (time == null) return 'Zaman bilgisi yok';
  final local = time.toLocal();
  final delta = DateTime.now().difference(local);
  if (delta.isNegative || delta.inMinutes < 1) return 'Az önce';
  if (delta.inMinutes < 60) return '${delta.inMinutes} dk önce';
  if (delta.inHours < 24) return '${delta.inHours} sa önce';
  return '${local.day.toString().padLeft(2, '0')}.${local.month.toString().padLeft(2, '0')}.${local.year} ${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
}

Future<bool> perform(BuildContext context, Future<void> Function() action, {String? success}) async {
  try {
    await action();
    if (context.mounted && success != null) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(success)));
    return true;
  } catch (e) {
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e'), duration: const Duration(seconds: 8), showCloseIcon: true));
    return false;
  }
}

Future<bool> confirm(BuildContext context, String title, String message, {String action = 'Onayla'}) async => await showDialog<bool>(context: context, builder: (context) => AlertDialog(title: Text(title), content: SingleChildScrollView(child: Text(message)), actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Vazgeç')), FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(action))])) ?? false;

void openScreen(BuildContext context, Widget screen, {bool checkpoint = false}) {
  final reduced = MediaQuery.disableAnimationsOf(context);
  Navigator.of(context).push(PageRouteBuilder<void>(
    transitionDuration: reduced ? Duration.zero : const Duration(milliseconds: 220),
    reverseTransitionDuration: reduced ? Duration.zero : const Duration(milliseconds: 180),
    pageBuilder: (context, animation, secondary) => screen,
    transitionsBuilder: (context, animation, secondary, child) {
      if (reduced) return child;
      final eased = CurvedAnimation(parent: animation, curve: const Cubic(.16, 1, .3, 1));
      return FadeTransition(opacity: eased, child: SlideTransition(position: Tween<Offset>(begin: Offset(checkpoint ? .045 : .025, 0), end: Offset.zero).animate(eased), child: child));
    },
  ));
}

class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.title, required this.message, this.action});
  final IconData icon;
  final String title, message;
  final Widget? action;
  @override
  Widget build(BuildContext context) => Padding(padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 40), child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [Icon(icon, size: 40, color: Theme.of(context).colorScheme.primary), const SizedBox(height: 24), Text(title, style: Theme.of(context).textTheme.headlineSmall), const SizedBox(height: 12), Text(message, style: Theme.of(context).textTheme.bodyLarge?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant, height: 1.5)), if (action != null) ...[const SizedBox(height: 24), action!]]));
}

class SectionHeading extends StatelessWidget {
  const SectionHeading(this.text, {super.key, this.action});
  final String text;
  final Widget? action;
  @override
  Widget build(BuildContext context) => Padding(padding: const EdgeInsets.fromLTRB(24, 28, 16, 12), child: Row(children: [Expanded(child: Text(text, style: Theme.of(context).textTheme.titleLarge)), if (action != null) action!]));
}

class ConnectionBanner extends StatelessWidget {
  const ConnectionBanner(this.controller, {super.key});
  final OmputerController controller;
  @override
  Widget build(BuildContext context) {
    final connection = controller.connection;
    final color = Theme.of(context).colorScheme;
    return Padding(padding: const EdgeInsets.fromLTRB(24, 8, 24, 12), child: NeoSurface(depth: NeoDepth.inset, radius: 14, padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8), child: Semantics(liveRegion: true, child: Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [Icon(connection.connected ? Icons.link_rounded : Icons.link_off_rounded, size: 18, color: connection.connected ? color.primary : color.error), Text(connection.connected ? (connection.serverName.isEmpty ? 'Bilgisayara bağlı' : connection.serverName) : 'Çevrimdışı · kayıtlı görünüm', style: Theme.of(context).textTheme.labelLarge), if (!connection.connected) TextButton(onPressed: () => perform(context, controller.reconnect), child: const Text('Yeniden bağlan'))]))));
  }
}

class ErrorNotice extends StatelessWidget {
  const ErrorNotice(this.message, {super.key, this.onRetry});
  final String message;
  final VoidCallback? onRetry;
  @override
  Widget build(BuildContext context) => Padding(padding: const EdgeInsets.all(16), child: NeoSurface(depth: NeoDepth.inset, radius: 16, color: Theme.of(context).colorScheme.errorContainer, borderColor: Theme.of(context).colorScheme.error.withValues(alpha: .5), padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(message, style: TextStyle(color: Theme.of(context).colorScheme.onErrorContainer)), if (onRetry != null) TextButton(onPressed: onRetry, child: const Text('Yeniden dene'))])));
}

/// Activity refreshes update content, not the position of an existing row.
class StableActivityOrder {
  final _positions = <String, int>{};
  var _next = 0;

  void apply<T>(List<T> items, String Function(T) id, DateTime? Function(T) updatedAt) {
    final ids = items.map(id).toSet();
    _positions.removeWhere((key, _) => !ids.contains(key));
    final added = items.where((item) => !_positions.containsKey(id(item))).toList()
      ..sort((a, b) {
        final date = (updatedAt(b) ?? DateTime(1970)).compareTo(updatedAt(a) ?? DateTime(1970));
        return date != 0 ? date : id(a).compareTo(id(b));
      });
    for (final item in added.reversed) {
      _positions[id(item)] = --_next;
    }
    items.sort((a, b) => _positions[id(a)]!.compareTo(_positions[id(b)]!));
  }
}

class SessionRow extends StatelessWidget {
  const SessionRow(this.session, {super.key, required this.onTap});
  final Session session;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => ListTile(contentPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8), leading: Icon(session.archived ? Icons.history_rounded : session.status == 'waiting' ? Icons.pending_actions_rounded : Icons.chat_bubble_outline_rounded, color: Theme.of(context).colorScheme.primary), title: Text(session.name.isEmpty ? 'Adsız oturum' : session.name), subtitle: Text('${session.statusLabel} · ${dateLabel(session.updatedAt)}', maxLines: 2), trailing: const Icon(Icons.chevron_right_rounded), onTap: onTap);
}

Future<void> copyText(BuildContext context, String text) => perform(context, () async { await Clipboard.setData(ClipboardData(text: text)); }, success: 'Panoya kopyalandı').then((_) {});

/// Markdown never fetches remote images or follows a URL from Dart. References
/// remain readable/copyable; embedded image bytes are rendered locally.
class LocalMarkdown extends StatelessWidget {
  const LocalMarkdown({super.key, required this.data, this.styleSheet, this.onOpenFile});
  final String data;
  final MarkdownStyleSheet? styleSheet;
  final void Function(String path, int? line)? onOpenFile;
  @override
  Widget build(BuildContext context) {
    final fences = RegExp(r'^```([^\n]*)\n([\s\S]*?)^```[ \t]*$', multiLine: true).allMatches(data).toList();
    if (fences.isEmpty) return _markdown(context, data);
    final children = <Widget>[];
    var end = 0;
    for (final match in fences) {
      if (match.start > end) children.add(_markdown(context, data.substring(end, match.start)));
      children.add(CopyableCode(text: match.group(2)!, language: match.group(1)!.trim()));
      end = match.end;
    }
    if (end < data.length) children.add(_markdown(context, data.substring(end)));
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: children);
  }
  Widget _markdown(BuildContext context, String text) => MarkdownBody(
    data: text,
    selectable: true,
    styleSheet: styleSheet,
    onTapLink: (text, href, title) {
      if (href == null) return;
      final reference = localFileReference(href);
      if (reference != null && onOpenFile != null) { onOpenFile!(reference.$1, reference.$2); } else { copyText(context, href); }
    },
    sizedImageBuilder: (image) {
      final uri = image.uri;
      final title = image.title;
      final alt = image.alt;
      if (uri.scheme == 'data') {
        try {
          final bytes = uri.data?.contentAsBytes();
          if (bytes != null) return Image.memory(bytes, semanticLabel: alt ?? title, errorBuilder: (context, error, stack) => const Text('Görsel verisi açılamadı.'));
        } catch (error) {
          return const Text('Görsel verisi okunamadı.');
        }
      }
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(alt?.isNotEmpty == true ? alt! : 'Uzak görsel referansı'), SelectableText('$uri'), TextButton.icon(onPressed: () => copyText(context, '$uri'), icon: const Icon(Icons.copy_rounded), label: const Text('Görsel adresini kopyala'))]);
    },
  );
}

Widget embeddedImage(String data) {
  try {
    return Image.memory(base64Decode(data), semanticLabel: 'Konuşmaya eklenmiş görsel', errorBuilder: (context, error, stack) => const Text('Görsel çözümlenemedi. Bilgisayarda asıl konuşmayı incele.'));
  } catch (error) {
    return const Text('Görsel verisi geçerli değil. Bilgisayarda asıl konuşmayı incele.');
  }
}

/// Only relative project references are navigable; remote and absolute links
/// remain copy-only. The PC independently enforces the canonical root boundary.
(String, int?)? localFileReference(String href) {
  final match = RegExp(r'^(.*?)(?:#L(\d+)(?:-L?\d+)?|:(\d+)(?::\d+)?)?$').firstMatch(href);
  if (match == null) return null;
  final raw = match.group(1)!;
  String path;
  try { path = Uri.decodeComponent(raw); } catch (_) { return null; }
  if (path.isEmpty || path.startsWith('/') || path.startsWith('\\') || path.contains('://') || path.contains(':') || path.contains('?') || path.contains('#') || path.split('/').contains('..')) return null;
  return (path.replaceFirst(RegExp(r'^\./'), ''), int.tryParse(match.group(2) ?? match.group(3) ?? ''));
}

class CopyableCode extends StatefulWidget {
  const CopyableCode({super.key, required this.text, this.language = '', this.initialLine});
  final String text, language;
  final int? initialLine;
  @override
  State<CopyableCode> createState() => _CopyableCodeState();
}
class _CopyableCodeState extends State<CopyableCode> {
  final target = GlobalKey();
  @override
  void initState() {
    super.initState();
    if (widget.initialLine != null) WidgetsBinding.instance.addPostFrameCallback((_) { final context = target.currentContext; if (context != null) Scrollable.ensureVisible(context, alignment: .2, duration: Duration.zero); });
  }
  @override
  Widget build(BuildContext context) {
    final lines = widget.text.split('\n');
    final line = widget.initialLine ?? 0;
    final valid = line > 0 && line <= lines.length;
    final style = Theme.of(context).textTheme.bodyMedium?.copyWith(fontFamily: 'monospace', height: 1.5);
    return Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: NeoSurface(depth: NeoDepth.inset, radius: 16, padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [Expanded(child: Text(widget.language.isEmpty ? 'Kod / metin' : widget.language, style: Theme.of(context).textTheme.labelMedium)), IconButton(tooltip: 'Kodu kopyala', onPressed: () => copyText(context, widget.text), icon: const Icon(Icons.copy_rounded))]),
      if (!valid) SelectableText(widget.text, style: style) else ...[
        if (line > 1) SelectableText(lines.take(line - 1).join('\n'), style: style),
        Container(key: target, width: double.infinity, color: Theme.of(context).colorScheme.secondaryContainer, child: SelectableText(lines[line - 1], style: style)),
        if (line < lines.length) SelectableText(lines.skip(line).join('\n'), style: style),
      ],
    ])));
  }
}
