import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'neumorphic.dart';

@immutable
class JoinedTab {
  const JoinedTab({
    required this.id,
    required this.label,
    this.icon,
    this.count = 0,
    this.action = false,
    this.enabled = true,
  });

  final String id;
  final String label;
  final IconData? icon;
  final int count;
  final bool action;
  final bool enabled;
}

/// A local panel's tabs and a matching full-width panel strip.
/// Place matching [panelColor] content below, or above with [panelAbove].
class NeoJoinedTabs extends StatelessWidget {
  const NeoJoinedTabs({
    super.key,
    required this.tabs,
    required this.selectedId,
    required this.onSelected,
    this.panelColor,
    this.panelAbove = false,
  });

  final List<JoinedTab> tabs;
  final String selectedId;
  final ValueChanged<String> onSelected;
  final Color? panelColor;
  final bool panelAbove;

  @override
  Widget build(BuildContext context) => _JoinedTabsBody(
    tabs: tabs,
    selectedId: selectedId,
    onSelected: onSelected,
    panelColor: panelColor ?? NeoPalette.of(context).raised,
    panelAbove: panelAbove,
  );
}

class _MoveJoinedFocus extends Intent {
  const _MoveJoinedFocus(this.step);
  final int step;
}

class _JoinedTabsBody extends StatefulWidget {
  const _JoinedTabsBody({
    required this.tabs,
    required this.selectedId,
    required this.onSelected,
    required this.panelColor,
    required this.panelAbove,
  });

  final List<JoinedTab> tabs;
  final String selectedId;
  final ValueChanged<String> onSelected;
  final Color panelColor;
  final bool panelAbove;

  @override
  State<_JoinedTabsBody> createState() => _JoinedTabsBodyState();
}

class _JoinedTabsBodyState extends State<_JoinedTabsBody> {
  final _focusNodes = <String, FocusNode>{};

  @override
  void initState() {
    super.initState();
    _syncFocusNodes();
  }

  @override
  void didUpdateWidget(_JoinedTabsBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncFocusNodes();
  }

  void _syncFocusNodes() {
    final ids = widget.tabs.map((tab) => tab.id).toSet();
    assert(ids.length == widget.tabs.length, 'Joined tab IDs must be unique.');
    for (final id in _focusNodes.keys.toList()) {
      if (!ids.contains(id)) _focusNodes.remove(id)!.dispose();
    }
    for (final tab in widget.tabs) {
      final node = _focusNodes.putIfAbsent(tab.id,
        () => FocusNode(debugLabel: 'Joined tab: ${tab.id}'));
      node.canRequestFocus = tab.enabled;
    }
  }

  @override
  void dispose() {
    for (final node in _focusNodes.values) {
      node.dispose();
    }
    super.dispose();
  }

  void _moveFocus(int step) {
    final enabled = widget.tabs.where((tab) => tab.enabled).toList();
    if (enabled.isEmpty) return;
    final index = enabled.indexWhere((tab) => _focusNodes[tab.id]!.hasFocus);
    final next = index < 0 ? (step > 0 ? 0 : enabled.length - 1)
      : (index + step) % enabled.length;
    _focusNodes[enabled[next].id]!.requestFocus();
  }

  void _activate(JoinedTab tab) {
    if (tab.enabled && (tab.action || tab.id != widget.selectedId)) {
      widget.onSelected(tab.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.tabs.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final palette = NeoPalette.of(context);
    final rtl = Directionality.of(context) == TextDirection.rtl;
    final selected = widget.tabs.indexWhere((tab) =>
      !tab.action && tab.id == widget.selectedId);
    final visualIndex = selected < 0 ? -1
      : rtl ? widget.tabs.length - 1 - selected : selected;
    return FocusTraversalGroup(
      policy: WidgetOrderTraversalPolicy(),
      child: Shortcuts(
        shortcuts: <ShortcutActivator, Intent>{
          SingleActivator(LogicalKeyboardKey.arrowRight): _MoveJoinedFocus(rtl ? -1 : 1),
          SingleActivator(LogicalKeyboardKey.arrowLeft): _MoveJoinedFocus(rtl ? 1 : -1),
          const SingleActivator(LogicalKeyboardKey.arrowDown): const _MoveJoinedFocus(1),
          const SingleActivator(LogicalKeyboardKey.arrowUp): const _MoveJoinedFocus(-1),
        },
        child: Actions(
          actions: <Type, Action<Intent>>{
            _MoveJoinedFocus: CallbackAction<_MoveJoinedFocus>(
              onInvoke: (intent) { _moveFocus(intent.step); return null; },
            ),
          },
          child: CustomPaint(
            painter: _JoinedTabsPainter(
              palette: palette,
              panelColor: widget.panelColor,
              count: widget.tabs.length,
              selectedIndex: visualIndex,
              panelAbove: widget.panelAbove,
            ),
            child: Padding(
              padding: EdgeInsets.only(
                top: widget.panelAbove ? _JoinedTabsPainter.stripHeight : 0,
                bottom: widget.panelAbove ? 0 : _JoinedTabsPainter.stripHeight,
              ),
              child: Material(
                type: MaterialType.transparency,
                child: IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final tab in widget.tabs)
                        Expanded(child: _buildButton(context, tab, theme)),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildButton(BuildContext context, JoinedTab tab, ThemeData theme) {
    final selected = !tab.action && tab.id == widget.selectedId;
    final node = _focusNodes[tab.id]!;
    final foreground = !tab.enabled ? theme.disabledColor
      : selected ? theme.colorScheme.primary : theme.colorScheme.onSurface;
    final label = tab.count > 0 ? '${tab.label}, ${tab.count} öğe' : tab.label;
    return ListenableBuilder(
      listenable: node,
      builder: (context, child) => Semantics(
        container: true,
        excludeSemantics: true,
        label: label,
        button: true,
        enabled: tab.enabled,
        focused: tab.enabled ? node.hasFocus : null,
        selected: tab.action ? null : selected,
        inMutuallyExclusiveGroup: !tab.action,
        onTap: tab.enabled ? () => _activate(tab) : null,
        child: child,
      ),
      child: TextButton(
        key: ValueKey('joined-tab:${tab.id}'),
        focusNode: node,
        onPressed: tab.enabled ? () => _activate(tab) : null,
        style: ButtonStyle(
          minimumSize: const WidgetStatePropertyAll(Size(48, 48)),
          padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 8, vertical: 12)),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          visualDensity: VisualDensity.standard,
          animationDuration: Duration.zero,
          foregroundColor: WidgetStatePropertyAll(foreground),
          backgroundColor: const WidgetStatePropertyAll(Colors.transparent),
          backgroundBuilder: (context, states, child) => child ?? const SizedBox.shrink(),
          elevation: const WidgetStatePropertyAll(0),
          shadowColor: const WidgetStatePropertyAll(Colors.transparent),
          surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
          overlayColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.pressed)
              ? theme.colorScheme.onSurface.withValues(alpha: .08)
              : states.contains(WidgetState.hovered)
                ? theme.colorScheme.onSurface.withValues(alpha: .04)
                : Colors.transparent),
          side: WidgetStateProperty.resolveWith((states) => BorderSide(
            color: states.contains(WidgetState.focused)
              ? theme.colorScheme.primary : Colors.transparent,
            width: 2,
          )),
          shape: const WidgetStatePropertyAll(RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(12)),
          )),
          textStyle: WidgetStatePropertyAll(theme.textTheme.labelLarge),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (tab.icon != null) ...[
              Icon(tab.icon, size: 20),
              const SizedBox(height: 4),
            ],
            Text(tab.label, textAlign: TextAlign.center, softWrap: true),
            if (tab.count > 0) ...[
              const SizedBox(height: 4),
              Text('${tab.count}', textAlign: TextAlign.center,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: foreground,
                  fontFeatures: const [ui.FontFeature.tabularFigures()],
                )),
            ],
          ],
        ),
      ),
    );
  }
}

class _JoinedTabsPainter extends CustomPainter {
  const _JoinedTabsPainter({
    required this.palette,
    required this.panelColor,
    required this.count,
    required this.selectedIndex,
    required this.panelAbove,
  });

  static const stripHeight = 12.0;
  final NeoPalette palette;
  final Color panelColor;
  final int count;
  final int selectedIndex;
  final bool panelAbove;

  @override
  void paint(Canvas canvas, Size size) {
    final panelY = size.height - stripHeight;
    final bounds = Offset.zero & size;
    double y(double value) => panelAbove ? size.height - value : value;
    final rail = RRect.fromRectAndRadius(
      Rect.fromLTWH(0, panelAbove ? stripHeight : 0, size.width, panelY),
      const Radius.circular(16));
    final paint = Paint()..color = palette.inset;
    canvas.drawRRect(rail, paint);
    canvas.save();
    canvas.clipRRect(rail);
    paint.maskFilter = const ui.MaskFilter.blur(ui.BlurStyle.normal, 3);
    for (final edge in [
      (color: palette.shadow.withValues(alpha: .6), offset: const Offset(3, 3)),
      (color: palette.light.withValues(alpha: .65), offset: const Offset(-3, -3)),
    ]) {
      final inset = Path()..fillType = PathFillType.evenOdd
        ..addRect(bounds.inflate(20))..addRRect(rail.shift(edge.offset));
      canvas.drawPath(inset, paint..color = edge.color);
    }
    canvas.restore();
    paint.maskFilter = null;

    // Mirror geometry only; text, traversal and the lighting stay upright.
    final joined = Path()..moveTo(0, y(panelY));
    Path? topEdge;
    if (selectedIndex >= 0 && count > 0) {
      final width = size.width / count;
      final shoulder = math.min(8.0, width / 8);
      final radius = math.min(12.0, width / 6);
      final left = selectedIndex * width + shoulder;
      final right = (selectedIndex + 1) * width - shoulder;
      topEdge = Path()
        ..moveTo(left - shoulder, y(panelY))
        ..quadraticBezierTo(left, y(panelY), left, y(panelY - shoulder))
        ..lineTo(left, y(4 + radius))
        ..quadraticBezierTo(left, y(4), left + radius, y(4))
        ..lineTo(right - radius, y(4))
        ..quadraticBezierTo(right, y(4), right, y(4 + radius))
        ..lineTo(right, y(panelY - shoulder))
        ..quadraticBezierTo(right, y(panelY), right + shoulder, y(panelY));
      joined..lineTo(left - shoulder, y(panelY))..extendWithPath(topEdge, Offset.zero);
    }
    joined..lineTo(size.width, y(panelY))..lineTo(size.width, y(size.height))
      ..lineTo(0, y(size.height))..close();
    canvas.save();
    canvas.clipRect(bounds);
    canvas.drawPath(joined.shift(const Offset(2, 2)), Paint()
      ..color = palette.shadow.withValues(alpha: .5)
      ..maskFilter = const ui.MaskFilter.blur(ui.BlurStyle.normal, 3));
    canvas.drawPath(joined, paint..color = panelColor);
    if (topEdge != null) {
      canvas.drawPath(topEdge, Paint()
        ..color = panelAbove
          ? palette.shadow.withValues(alpha: .5)
          : palette.light.withValues(alpha: .55)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_JoinedTabsPainter oldDelegate) =>
    palette != oldDelegate.palette || panelColor != oldDelegate.panelColor ||
    count != oldDelegate.count || selectedIndex != oldDelegate.selectedIndex ||
    panelAbove != oldDelegate.panelAbove;
}
