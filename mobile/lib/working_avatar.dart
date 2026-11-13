// The supplied GIF is decoded incrementally by Flutter's shared image stream.

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
    with WidgetsBindingObserver {
  bool _foreground = true;

  @override
  void initState() {
    super.initState();
    final binding = WidgetsBinding.instance;
    _foreground = binding.lifecycleState == null ||
        binding.lifecycleState == AppLifecycleState.resumed;
    binding.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final foreground = state == AppLifecycleState.resumed;
    if (_foreground != foreground) {
      setState(() => _foreground = foreground);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final moving = widget.running &&
        _foreground &&
        !MediaQuery.disableAnimationsOf(context) &&
        !MediaQuery.accessibleNavigationOf(context) &&
        (ModalRoute.isCurrentOf(context) ?? true);
    return Semantics(
      label: widget.running ? 'Oturum çalışıyor' : 'Oturum çalışmıyor',
      child: RepaintBoundary(
        child: TickerMode(
          // Ancestor TickerMode is still authoritative. Image removes its
          // stream listener while paused, retaining only the displayed frame.
          enabled: moving,
          child: Image.asset(
            'assets/sisyphus-working.gif',
            width: widget.size,
            height: widget.size,
            fit: BoxFit.contain,
            excludeFromSemantics: true,
            // One bounded cache key shared by every avatar, not twelve eager
            // full-resolution frame copies or a per-avatar 60 Hz controller.
            cacheWidth: 256,
            filterQuality: FilterQuality.low,
          ),
        ),
      ),
    );
  }
}

