import 'dart:math' as math;

import 'package:flutter/material.dart';

/// A bounded work indicator. Callers supply the actual session running state.
class WorkingAvatar extends StatefulWidget {
  const WorkingAvatar({super.key, this.running = true, this.size = 64})
      : assert(size > 0 && size < double.infinity);

  final bool running;
  final double size;

  @override
  State<WorkingAvatar> createState() => _WorkingAvatarState();
}

class _WorkingAvatarState extends State<WorkingAvatar>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final AnimationController _controller;
  bool _motionAllowed = false;
  bool _foreground = true;

  @override
  void initState() {
    super.initState();
    final binding = WidgetsBinding.instance;
    _foreground = binding.lifecycleState == null ||
        binding.lifecycleState == AppLifecycleState.resumed;
    binding.addObserver(this);
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _motionAllowed = !MediaQuery.disableAnimationsOf(context) &&
        !MediaQuery.accessibleNavigationOf(context) &&
        TickerMode.valuesOf(context).enabled;
    _syncAnimation();
  }

  @override
  void didUpdateWidget(covariant WorkingAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncAnimation();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _syncAnimation();
  }

  void _syncAnimation() {
    if (widget.running && _motionAllowed && _foreground) {
      if (!_controller.isAnimating) _controller.repeat();
    } else {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      label: widget.running ? 'Oturum çalışıyor' : 'Oturum çalışmıyor',
      child: ExcludeSemantics(
        child: RepaintBoundary(
          child: SizedBox.square(
            dimension: widget.size,
            child: CustomPaint(
              painter: _WorkingAvatarPainter(
                animation: _controller,
                running: widget.running,
                moving: _motionAllowed,
                color: widget.running
                    ? colors.primary
                    : colors.onSurface.withValues(alpha: 0.38),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _WorkingAvatarPainter extends CustomPainter {
  _WorkingAvatarPainter({
    required this.animation,
    required this.running,
    required this.moving,
    required this.color,
  })  : _silhouette = (Paint()..color = color),
        _strokes = (Paint()
          ..color = color.withValues(alpha: 0.55)
          ..strokeWidth = 1.5
          ..strokeCap = StrokeCap.round),
        super(repaint: animation);

  final Animation<double> animation;
  final bool running;
  final bool moving;
  final Color color;
  final Paint _silhouette;
  final Paint _strokes;

  static final Path _rider = Path()
    ..moveTo(34, 29)
    ..quadraticBezierTo(36, 25, 40, 26)
    ..lineTo(47, 30)
    ..lineTo(53, 29)
    ..quadraticBezierTo(55, 29, 54, 31)
    ..lineTo(47, 33)
    ..lineTo(40, 30)
    ..lineTo(37, 34)
    ..lineTo(46, 35)
    ..quadraticBezierTo(48, 35, 48, 37)
    ..lineTo(48, 40)
    ..lineTo(44, 40)
    ..lineTo(44, 38)
    ..lineTo(33, 37)
    ..quadraticBezierTo(30, 36, 32, 32)
    ..close();

  static final Path _speeder = Path()
    ..moveTo(23, 40)
    ..lineTo(60, 40)
    ..quadraticBezierTo(58, 45, 50, 45)
    ..lineTo(29, 45)
    ..quadraticBezierTo(25, 45, 23, 40)
    ..close();

  static const _trails = <(double, double, double)>[
    (15, 9, 0.05),
    (24, 13, 0.48),
    (34, 8, 0.23),
    (48, 14, 0.7),
    (54, 7, 0.36),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final phase = running && moving ? animation.value : 0.0;
    final scale = math.min(size.width, size.height) / 64;
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    canvas.translate((size.width - 64 * scale) / 2,
        (size.height - 64 * scale) / 2);
    if (running && moving) {
      // Logical-pixel displacement stays small even when the avatar is enlarged.
      canvas.translate(
        math.sin(phase * math.pi * 4) * 0.4,
        math.sin(phase * math.pi * 6) * 1.1,
      );
    }
    canvas.scale(scale);
    if (running) {
      for (final (y, length, offset) in _trails) {
        final right = 39 - ((phase + offset) % 1) * 52;
        if (right > 0) {
          canvas.drawLine(
            Offset(math.max(0.0, right - length), y),
            Offset(right, y),
            _strokes,
          );
        }
      }
    }
    canvas.drawCircle(const Offset(44, 20), 4, _silhouette);
    canvas.drawPath(_rider, _silhouette);
    canvas.drawPath(_speeder, _silhouette);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _WorkingAvatarPainter oldDelegate) =>
      oldDelegate.animation != animation ||
      oldDelegate.running != running ||
      oldDelegate.moving != moving ||
      oldDelegate.color != color;
}
