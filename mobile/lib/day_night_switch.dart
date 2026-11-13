import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'neumorphic.dart';

/// Controlled theme action: the drawing follows [dark], never the last tap.
class DayNightSwitch extends StatefulWidget {
  const DayNightSwitch({super.key, required this.dark, required this.onChanged});

  final bool dark;
  final ValueChanged<bool>? onChanged;

  @override
  State<DayNightSwitch> createState() => _DayNightSwitchState();
}

class _DayNightSwitchState extends State<DayNightSwitch>
    with SingleTickerProviderStateMixin {
  late final AnimationController _position = AnimationController(
    vsync: this,
    value: widget.dark ? 1 : 0,
    duration: const Duration(milliseconds: 240),
  );
  bool _focused = false;
  bool _immediateNextChange = false;

  bool get _reduceMotion => MediaQuery.disableAnimationsOf(context) ||
      MediaQuery.accessibleNavigationOf(context);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_reduceMotion) _position.value = widget.dark ? 1 : 0;
  }

  @override
  void didUpdateWidget(DayNightSwitch oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.dark != widget.dark) {
      final target = widget.dark ? 1.0 : 0.0;
      if (_reduceMotion || _immediateNextChange) {
        _position.value = target;
      } else {
        // animateTo starts at the current painted position, including reversals.
        _position.animateTo(target, curve: const Cubic(.16, 1, .3, 1));
      }
      _immediateNextChange = false;
    }
  }

  void _activate({required bool immediate}) {
    if (widget.onChanged == null) return;
    _immediateNextChange = immediate;
    widget.onChanged!(!widget.dark);
  }

  @override
  void dispose() {
    _position.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onChanged != null;
    return Semantics(
      label: 'Karanlık mod',
      toggled: widget.dark,
      enabled: enabled,
      focused: enabled ? _focused : null,
      onTap: enabled ? () => _activate(immediate: true) : null,
      excludeSemantics: true,
      child: FocusableActionDetector(
        enabled: enabled,
        includeFocusSemantics: false,
        mouseCursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onShowFocusHighlight: (value) => setState(() => _focused = value),
        shortcuts: const <ShortcutActivator, Intent>{
          SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
        },
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) {
            _activate(immediate: true);
            return null;
          }),
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          excludeFromSemantics: true,
          onTap: enabled ? () => _activate(immediate: false) : null,
          child: SizedBox(
            width: 72,
            height: 48,
            child: CustomPaint(
              painter: _DayNightPainter(
                position: _position,
                palette: NeoPalette.of(context),
                focusColor: Theme.of(context).colorScheme.primary,
                focused: enabled && _focused,
                enabled: enabled,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DayNightPainter extends CustomPainter {
  _DayNightPainter({required this.position, required this.palette,
    required this.focusColor, required this.focused, required this.enabled})
      : super(repaint: position);

  final Animation<double> position;
  final NeoPalette palette;
  final Color focusColor;
  final bool focused, enabled;

  @override
  void paint(Canvas canvas, Size size) {
    final t = position.value;
    final opacity = enabled ? 1.0 : .45;
    final paint = Paint();
    final track = RRect.fromRectAndRadius(
      Rect.fromLTWH(0, (size.height - 32) / 2, size.width, 32),
      const Radius.circular(16),
    );
    canvas.drawRRect(track.shift(const Offset(2, 2)), paint
      ..color = palette.shadow.withValues(alpha: .55 * opacity)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2));
    canvas.drawRRect(track.shift(const Offset(-2, -2)), paint
      ..color = palette.light.withValues(alpha: .65 * opacity));
    paint.maskFilter = null;
    canvas.drawRRect(track, paint..color = Color.lerp(
      const Color(0xff3d7eae), const Color(0xff1d1f2c), t,
    )!.withValues(alpha: opacity));
    canvas.save();
    canvas.clipRRect(track);
    final center = Offset(16 + (size.width - 32) * t, size.height / 2);
    // The reference's three translucent discs travel with the thumb.
    paint.color = Colors.white.withValues(alpha: .10 * opacity);
    for (final radius in const [35.0, 27.0, 20.0]) {
      canvas.drawCircle(center, radius, paint);
    }
    // Cloud banks descend out of the clipped track instead of dissolving.
    canvas.save();
    canvas.translate(0, 36 * t);
    paint.color = const Color(0xffaacadf).withValues(alpha: opacity);
    canvas.drawCircle(const Offset(22, 41), 10, paint);
    canvas.drawCircle(const Offset(35, 37), 11, paint);
    canvas.drawCircle(const Offset(48, 34), 12, paint);
    canvas.drawCircle(const Offset(61, 29), 12, paint);
    canvas.drawCircle(const Offset(74, 22), 12, paint);
    canvas.drawRect(const Rect.fromLTWH(12, 37, 66, 16), paint);
    paint.color = const Color(0xfff3fdff).withValues(alpha: opacity);
    canvas.drawCircle(const Offset(18, 46), 10, paint);
    canvas.drawCircle(const Offset(31, 43), 11, paint);
    canvas.drawCircle(const Offset(44, 40), 11, paint);
    canvas.drawCircle(const Offset(57, 36), 11, paint);
    canvas.drawCircle(const Offset(71, 29), 11, paint);
    canvas.drawRect(const Rect.fromLTWH(10, 43, 68, 12), paint);
    canvas.restore();
    // Concave four-point stars enter from above, like the supplied SVG.
    canvas.save();
    canvas.translate(0, -32 * (1 - t));
    paint.color = Colors.white.withValues(alpha: opacity);
    for (final star in const [
      (Offset(10, 17), 2.2), (Offset(20, 29), 2.6),
      (Offset(28, 15), 1.5), (Offset(37, 23), 2.0),
      (Offset(9, 32), 1.2), (Offset(31, 34), 1.1),
    ]) {
      final x = star.$1.dx;
      final y = star.$1.dy;
      final r = star.$2;
      final path = Path()
        ..moveTo(x, y - r)
        ..quadraticBezierTo(x, y, x + r, y)
        ..quadraticBezierTo(x, y, x, y + r)
        ..quadraticBezierTo(x, y, x - r, y)
        ..quadraticBezierTo(x, y, x, y - r)
        ..close();
      canvas.drawPath(path, paint);
    }
    canvas.restore();
    // Keep the thumb and its sliding moon inside the track's inset lip.
    canvas.drawCircle(center + const Offset(1.5, 2), 13, paint
      ..color = palette.shadow.withValues(alpha: .55 * opacity)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2));
    paint.maskFilter = null;
    canvas.drawCircle(center, 13, paint
      ..color = const Color(0xffecca2f).withValues(alpha: opacity));
    canvas.save();
    canvas.clipPath(Path()..addOval(Rect.fromCircle(center: center, radius: 13)));
    // A silver disc slides over the sun; no crossfade or host theme involved.
    final moon = center + Offset(26 * (1 - t), 0);
    canvas.drawCircle(moon, 13, paint
      ..color = const Color(0xffc4c9d1).withValues(alpha: opacity));
    paint.color = const Color(0xff959db1).withValues(alpha: opacity);
    canvas.drawCircle(moon + const Offset(-4.5, 2.5), 4, paint);
    canvas.drawCircle(moon + const Offset(4, -5), 2.5, paint);
    canvas.drawCircle(moon + const Offset(5, 5), 2, paint);
    canvas.restore();
    paint
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = Colors.white.withValues(alpha: .45 * opacity);
    canvas.drawArc(Rect.fromCircle(center: center, radius: 12.5),
      3.14, 1.57, false, paint);
    paint
      ..strokeWidth = 1.5
      ..color = palette.shadow.withValues(alpha: .4 * opacity);
    canvas.drawRRect(track.shift(const Offset(1, 1)), paint);
    canvas.restore();
    paint.style = PaintingStyle.fill;
    if (focused) {
      canvas.drawRRect(RRect.fromRectAndRadius(
        Rect.fromLTWH(1, 3, size.width - 2, size.height - 6),
        const Radius.circular(20)), paint
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = focusColor);
    }
  }

  @override
  bool shouldRepaint(_DayNightPainter oldDelegate) =>
      oldDelegate.position != position || oldDelegate.palette != palette ||
      oldDelegate.focusColor != focusColor || oldDelegate.focused != focused ||
      oldDelegate.enabled != enabled;
}
