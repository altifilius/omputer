import 'dart:ui' as ui;
import 'package:flutter/material.dart';

enum NeoDepth { flat, raised, inset }

/// One lighting model for the native application; semantics stay in its controls.
@immutable
class NeoPalette extends ThemeExtension<NeoPalette> {
  const NeoPalette({required this.base, required this.raised, required this.inset, required this.light, required this.shadow});
  final Color base, raised, inset, light, shadow;

  static NeoPalette of(BuildContext context) => Theme.of(context).extension<NeoPalette>() ?? forBrightness(Theme.of(context).brightness);
  static NeoPalette forBrightness(Brightness brightness) => brightness == Brightness.dark
      ? const NeoPalette(base: Color(0xff23272f), raised: Color(0xff292e37), inset: Color(0xff20242b), light: Color(0xff383e49), shadow: Color(0xff13161c))
      : const NeoPalette(base: Color(0xffe8edf2), raised: Color(0xffeef2f6), inset: Color(0xffe2e8ee), light: Color(0xffffffff), shadow: Color(0xffbdc6d0));

  @override
  NeoPalette copyWith({Color? base, Color? raised, Color? inset, Color? light, Color? shadow}) => NeoPalette(base: base ?? this.base, raised: raised ?? this.raised, inset: inset ?? this.inset, light: light ?? this.light, shadow: shadow ?? this.shadow);
  @override
  NeoPalette lerp(covariant NeoPalette? other, double t) => other == null ? this : NeoPalette(base: Color.lerp(base, other.base, t)!, raised: Color.lerp(raised, other.raised, t)!, inset: Color.lerp(inset, other.inset, t)!, light: Color.lerp(light, other.light, t)!, shadow: Color.lerp(shadow, other.shadow, t)!);
}

class NeoSurface extends StatelessWidget {
  const NeoSurface({super.key, required this.child, this.depth = NeoDepth.raised, this.radius = 20, this.padding = EdgeInsets.zero, this.color, this.borderColor, this.compact = false});
  final Widget child;
  final NeoDepth depth;
  final double radius;
  final EdgeInsetsGeometry padding;
  final Color? color, borderColor;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final palette = NeoPalette.of(context);
    final fill = color ?? switch (depth) { NeoDepth.raised => palette.raised, NeoDepth.inset => palette.inset, NeoDepth.flat => palette.base };
    final border = BorderRadius.circular(radius);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: fill, borderRadius: border,
        border: borderColor == null ? null : Border.all(color: borderColor!),
        boxShadow: depth == NeoDepth.raised ? [
          BoxShadow(color: palette.shadow.withValues(alpha: .7), offset: Offset(compact ? 2 : 4, compact ? 2 : 4), blurRadius: compact ? 5 : 10),
          BoxShadow(color: palette.light.withValues(alpha: .55), offset: Offset(compact ? -2 : -4, compact ? -2 : -4), blurRadius: compact ? 5 : 10),
        ] : null,
      ),
      child: CustomPaint(
        painter: depth == NeoDepth.inset ? _InsetPainter(palette: palette, radius: radius) : null,
        child: Material(type: MaterialType.transparency, borderRadius: border, textStyle: DefaultTextStyle.of(context).style, child: Padding(padding: padding, child: child)),
      ),
    );
  }
}

void _paintInset(Canvas canvas, Rect bounds, RRect shape, NeoPalette palette) {
  final paint = Paint()..maskFilter = const ui.MaskFilter.blur(ui.BlurStyle.normal, 3);
  canvas.save();
  canvas.clipRRect(shape);
  for (final shadow in [(color: palette.shadow.withValues(alpha: .6), offset: const Offset(3, 3)), (color: palette.light.withValues(alpha: .65), offset: const Offset(-3, -3))]) {
    final path = Path()..fillType = PathFillType.evenOdd..addRect(bounds.inflate(20))..addRRect(shape.shift(shadow.offset));
    canvas.drawPath(path, paint..color = shadow.color);
  }
  canvas.restore();
}

class _InsetPainter extends CustomPainter {
  const _InsetPainter({required this.palette, required this.radius});
  final NeoPalette palette;
  final double radius;
  @override
  void paint(Canvas canvas, Size size) => _paintInset(canvas, Offset.zero & size, RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(radius)), palette);
  @override
  bool shouldRepaint(_InsetPainter oldDelegate) => palette != oldDelegate.palette || radius != oldDelegate.radius;
}

/// Native InputDecorator keeps its floating label, selection, IME and semantics.
class NeoInputBorder extends OutlineInputBorder {
  const NeoInputBorder({required this.palette, super.borderSide = BorderSide.none, super.borderRadius = const BorderRadius.all(Radius.circular(16)), super.gapPadding = 4});
  final NeoPalette palette;
  @override
  NeoInputBorder copyWith({BorderSide? borderSide, BorderRadius? borderRadius, double? gapPadding}) => NeoInputBorder(palette: palette, borderSide: borderSide ?? this.borderSide, borderRadius: borderRadius ?? this.borderRadius, gapPadding: gapPadding ?? this.gapPadding);
  @override
  NeoInputBorder scale(double t) => NeoInputBorder(palette: palette, borderSide: borderSide.scale(t), borderRadius: borderRadius * t, gapPadding: gapPadding * t);
  @override
  void paint(Canvas canvas, Rect rect, {double? gapStart, double gapExtent = 0, double gapPercentage = 0, TextDirection? textDirection}) {
    _paintInset(canvas, rect, borderRadius.toRRect(rect), palette);
    super.paint(canvas, rect, gapStart: gapStart, gapExtent: gapExtent, gapPercentage: gapPercentage, textDirection: textDirection);
  }
  @override
  ShapeBorder? lerpFrom(ShapeBorder? a, double t) => a is NeoInputBorder ? NeoInputBorder(palette: a.palette.lerp(palette, t), borderSide: BorderSide.lerp(a.borderSide, borderSide, t), borderRadius: BorderRadius.lerp(a.borderRadius, borderRadius, t)!, gapPadding: ui.lerpDouble(a.gapPadding, gapPadding, t)!) : super.lerpFrom(a, t);
  @override
  ShapeBorder? lerpTo(ShapeBorder? b, double t) => b is NeoInputBorder ? b.lerpFrom(this, t) : super.lerpTo(b, t);
}

ButtonStyle neoButtonStyle({bool primary = false, bool compact = false}) => ButtonStyle(
  minimumSize: WidgetStatePropertyAll(Size(48, compact ? 48 : 52)),
  shape: const WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(16)))),
  elevation: const WidgetStatePropertyAll(0),
  backgroundColor: const WidgetStatePropertyAll(Colors.transparent),
  surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
  shadowColor: const WidgetStatePropertyAll(Colors.transparent),
  side: const WidgetStatePropertyAll(BorderSide.none),
  backgroundBuilder: (context, states, child) {
    final scheme = Theme.of(context).colorScheme;
    final disabled = states.contains(WidgetState.disabled);
    final pressed = states.contains(WidgetState.pressed) || states.contains(WidgetState.selected);
    return NeoSurface(
      radius: 16, compact: true,
      depth: disabled ? NeoDepth.flat : pressed ? NeoDepth.inset : NeoDepth.raised,
      color: primary && !disabled ? scheme.primary : null,
      borderColor: states.contains(WidgetState.focused) ? scheme.primary : disabled ? scheme.outlineVariant.withValues(alpha: .4) : scheme.outlineVariant.withValues(alpha: .55),
      child: child ?? const SizedBox.shrink(),
    );
  },
);
