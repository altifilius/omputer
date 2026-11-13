import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import 'controller.dart';
import 'models.dart';
import 'project_cards.dart';
import 'projects.dart';
import 'ui.dart';

/// A finite upright project deck. Hidden time never advances its dwell clock.
class ProjectCarousel extends StatefulWidget {
  const ProjectCarousel({
    super.key,
    required this.controller,
    required this.projects,
    required this.selectedProjectId,
    required this.onSelected,
    this.autoAdvance = true,
    this.height = 248,
    this.pauseSignal = 0,
    this.initiallyPaused = true,
  }) : assert(height >= 96 && height < double.infinity);

  final OmputerController controller;
  final List<Project> projects;
  final String selectedProjectId;
  final ValueChanged<String> onSelected;
  final bool autoAdvance;
  /// Total height of the layered stage and its right-hand controls.
  final double height;
  final int pauseSignal;
  final bool initiallyPaused;

  @override
  State<ProjectCarousel> createState() => _ProjectCarouselState();
}

class _ProjectCarouselState extends State<ProjectCarousel>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  static const _dwell = Duration(seconds: 6);
  static const _transition = Duration(milliseconds: 280);
  static const _curve = Cubic(.16, 1, .3, 1);
  static const _layerStep = 24.0;
  final _stage = GlobalKey();
  final _cards = <int, Widget>{};
  late AnimationController _phase;
  late List<Project> _projects;
  late List<String> _ids;
  late Map<String, int> _indices;
  late Map<String, ProjectSummary> _summaries;
  late int _index;
  Timer? _timer;
  ScrollPosition? _ancestorScroll;
  bool _paused = false;
  bool _moving = false;
  bool _foreground = true;
  bool _motionAllowed = false;
  bool _staticMode = false;
  bool _visible = false;
  bool _visibilityScheduled = false;
  bool? _cachedAnimation;
  int _motionEpoch = 0;
  double _dragOrigin = 0;
  double _dragDistance = 0;
  String? _reportedSelection;

  bool get _canAnimate => _foreground && _motionAllowed && _visible && !_staticMode;
  bool get _canAuto => _canAnimate && widget.autoAdvance && !_paused && _index < _ids.length - 1;

  @override
  void initState() {
    super.initState();
    _paused = widget.initiallyPaused;
    _cacheSource();
    _index = _indices[widget.selectedProjectId] ?? 0;
    _phase = AnimationController.unbounded(vsync: this, value: _index.toDouble())
      ..addListener(_phaseChanged);
    final binding = WidgetsBinding.instance;
    _foreground = binding.lifecycleState == null || binding.lifecycleState == AppLifecycleState.resumed;
    binding.addObserver(this);
    widget.controller.addListener(_dataChanged);
  }

  void _cacheSource() {
    // Copy the source so even an in-place list edit invalidates the cache.
    _projects = List<Project>.of(widget.projects, growable: false);
    _ids = _projects.map((project) => project.id).toList(growable: false);
    _indices = {for (var i = 0; i < _ids.length; i++) _ids[i]: i};
    _summaries = projectSummaries(widget.controller, _projects);
    _cards.clear();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _staticMode = MediaQuery.disableAnimationsOf(context) || MediaQuery.accessibleNavigationOf(context);
    _motionAllowed = TickerMode.valuesOf(context).enabled && (ModalRoute.isCurrentOf(context) ?? true);
    final ancestor = Scrollable.maybeOf(context)?.position;
    if (_ancestorScroll != ancestor) {
      _ancestorScroll?.removeListener(_scheduleVisibility);
      _ancestorScroll = ancestor;
      _ancestorScroll?.addListener(_scheduleVisibility);
    }
    _syncAuto();
    _scheduleVisibility();
  }

  @override
  void didUpdateWidget(ProjectCarousel oldWidget) {
    super.didUpdateWidget(oldWidget);
    final controllerChanged = oldWidget.controller != widget.controller;
    if (controllerChanged) {
      oldWidget.controller.removeListener(_dataChanged);
      widget.controller.addListener(_dataChanged);
    }
    final selectedId = _ids.isEmpty ? null : _ids[_index];
    final sourceChanged = controllerChanged || !listEquals(_projects, widget.projects);
    final previousIds = _ids;
    if (sourceChanged) _cacheSource();
    final reordered = !listEquals(previousIds, _ids);
    final parentChanged = oldWidget.selectedProjectId != widget.selectedProjectId;
    final acknowledged = parentChanged && widget.selectedProjectId == _reportedSelection;
    if (acknowledged) _reportedSelection = null;
    if (reordered || (parentChanged && !acknowledged)) {
      final desired = parentChanged && !acknowledged ? widget.selectedProjectId : selectedId;
      _reconcile(_indices[desired] ?? 0);
    }
    if (oldWidget.pauseSignal != widget.pauseSignal) {
      _paused = true;
      _stopMotion();
    }
    _syncAuto();
    _scheduleVisibility();
  }

  void _reconcile(int index) {
    _timer?.cancel();
    _timer = null;
    _motionEpoch++;
    _phase.stop();
    _moving = false;
    // Set the index first: source/parent reconciliation never emits selection.
    _index = index;
    _phase.value = index.toDouble();
    _cards.clear();
    _reportedSelection = null;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final foreground = state == AppLifecycleState.resumed;
    if (_foreground != foreground) setState(() => _foreground = foreground);
    _syncAuto();
    if (foreground) _scheduleVisibility();
  }

  void _dataChanged() {
    setState(() {
      if (!listEquals(_projects, widget.projects)) {
        final selectedId = _ids.isEmpty ? null : _ids[_index];
        final previousIds = _ids;
        _cacheSource();
        if (!listEquals(previousIds, _ids)) _reconcile(_indices[selectedId] ?? 0);
      } else {
        _summaries = projectSummaries(widget.controller, _projects);
        _cards.clear();
      }
    });
    _syncAuto();
  }

  void _stopMotion() {
    _timer?.cancel();
    _timer = null;
    _motionEpoch++;
    _phase.stop();
    if (_moving) _phase.value = _index.toDouble();
    _moving = false;
  }

  void _syncAuto() {
    if (!_canAuto) {
      _timer?.cancel();
      _timer = null;
      if (!_canAnimate || !widget.autoAdvance) _stopMotion();
      return;
    }
    if (_timer != null || _moving) return;
    _timer = Timer(_dwell, () {
      _timer = null;
      if (!_canAuto || !_isHalfVisible()) {
        _scheduleVisibility();
        return;
      }
      _go(_index + 1);
    });
  }

  void _pause() {
    _stopMotion();
    if (!_paused) setState(() => _paused = true);
  }

  void _toggleAuto() {
    if (!_paused) {
      _pause();
    } else {
      setState(() => _paused = false);
      _syncAuto();
    }
  }

  void _phaseChanged() {
    if (_ids.isEmpty) return;
    final index = _phase.value.round().clamp(0, _ids.length - 1);
    if (index == _index) return;
    final previous = _index;
    setState(() {
      _index = index;
      _cards.remove(previous);
      _cards.remove(index);
    });
    final id = _ids[index];
    _reportedSelection = id;
    widget.onSelected(id);
  }

  void _select(int index, {bool instant = false}) {
    _pause();
    if (_ids.isNotEmpty) _go(index.clamp(0, _ids.length - 1), instant: instant);
  }

  void _scrub(double phase) {
    _pause();
    final value = _staticMode ? phase.roundToDouble() : phase;
    _phase.value = value.clamp(0.0, (_ids.length - 1).toDouble());
  }

  void _go(int index, {bool instant = false}) {
    if (_phase.value == index) return;
    _timer?.cancel();
    _timer = null;
    final epoch = ++_motionEpoch;
    if (instant || !_canAnimate) {
      _phase.value = index.toDouble();
      _syncAuto();
      return;
    }
    _moving = true;
    _phase.animateTo(index.toDouble(), duration: _transition, curve: _curve).whenCompleteOrCancel(() {
      if (!mounted || epoch != _motionEpoch) return;
      setState(() => _moving = false);
      _syncAuto();
    });
  }

  void _openProject(String id) {
    if (_moving || _ids[_index] != id) return;
    _pause();
    openScreen(context, ProjectScreen(controller: widget.controller, projectId: id));
  }

  void _scheduleVisibility() {
    if (_visibilityScheduled) return;
    _visibilityScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _visibilityScheduled = false;
      if (!mounted) return;
      final visible = _isHalfVisible();
      if (_visible != visible) setState(() => _visible = visible);
      _syncAuto();
    });
  }

  bool _isHalfVisible() {
    final box = _stage.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize || box.size.isEmpty) return false;
    final bounds = MatrixUtils.transformRect(box.getTransformTo(null), Offset.zero & box.size);
    var visible = bounds.intersect(Offset.zero & MediaQuery.sizeOf(context));
    RenderObject child = box;
    for (RenderObject? ancestor = child.parent; ancestor != null; ancestor = child.parent) {
      if (ancestor is RenderOffstage && ancestor.offstage) return false;
      if (ancestor is RenderOpacity && ancestor.opacity == 0) return false;
      if (ancestor is RenderAnimatedOpacity && ancestor.opacity.value == 0) return false;
      if (ancestor is RenderIndexedStack) {
        final children = ancestor.getChildrenAsList();
        if (ancestor.index == null || children[ancestor.index!] != child) return false;
      }
      final clip = ancestor.describeApproximatePaintClip(child);
      if (clip != null) visible = visible.intersect(MatrixUtils.transformRect(ancestor.getTransformTo(null), clip));
      child = ancestor;
    }
    return !visible.isEmpty && visible.width * visible.height >= bounds.width * bounds.height * .5;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ancestorScroll?.removeListener(_scheduleVisibility);
    widget.controller.removeListener(_dataChanged);
    _timer?.cancel();
    _phase.dispose();
    super.dispose();
  }

  void _cacheCards() {
    if (_cachedAnimation != _canAnimate) {
      _cachedAnimation = _canAnimate;
      _cards.clear();
    }
    final first = math.max(0, _index - 2);
    final last = math.min(_ids.length - 1, _index + 2);
    _cards.removeWhere((index, _) => index < first || index > last);
    for (var index = first; index <= last; index++) {
      final id = _ids[index];
      final front = index == _index;
      _cards.putIfAbsent(index, () => RepaintBoundary(
        child: TickerMode(enabled: front && _canAnimate, child: ProjectOverviewCard(
          controller: widget.controller,
          project: _projects[index],
          summary: _summaries[id]!,
          selected: front,
          dense: true,
          animateAvatar: front && _canAnimate,
          onTap: () => _openProject(id),
        )),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_ids.isEmpty) return const SizedBox.shrink();
    _cacheCards();
    final last = _index == _ids.length - 1;
    final canPlay = _ids.length > 1 && widget.autoAdvance && _motionAllowed && !_staticMode;
    final cardHeight = math.max(40.0, widget.height - 56);
    return Focus(
      key: const ValueKey('project-carousel-focus'),
      onKeyEvent: (_, event) {
        if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
        final key = event.logicalKey;
        if (key == LogicalKeyboardKey.arrowDown || key == LogicalKeyboardKey.pageDown) {
          _select(_index + 1, instant: true);
        } else if (key == LogicalKeyboardKey.arrowUp || key == LogicalKeyboardKey.pageUp) {
          _select(_index - 1, instant: true);
        } else if (key == LogicalKeyboardKey.home) {
          _select(0, instant: true);
        } else if (key == LogicalKeyboardKey.end) {
          _select(_ids.length - 1, instant: true);
        } else {
          _pause();
          return KeyEventResult.ignored;
        }
        return KeyEventResult.handled;
      },
      child: SizedBox(height: widget.height, child: _DeckVisibility(
        key: _stage,
        onGeometryChanged: _scheduleVisibility,
        child: Row(children: [
          Expanded(child: Listener(
            key: const ValueKey('project-carousel-stage'),
            behavior: HitTestBehavior.opaque,
            onPointerDown: (_) => _pause(),
            onPointerSignal: (_) => _pause(),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onVerticalDragStart: (_) {
                _pause();
                _dragOrigin = _phase.value;
                _dragDistance = 0;
              },
              onVerticalDragUpdate: (details) {
                _dragDistance += details.delta.dy;
                if (!_staticMode) {
                  _phase.value = (_dragOrigin + (_dragDistance / cardHeight).clamp(-1.0, 1.0))
                      .clamp(0.0, (_ids.length - 1).toDouble());
                }
              },
              onVerticalDragEnd: (details) {
                final velocity = details.primaryVelocity ?? 0;
                final direction = _dragDistance == 0 ? velocity : _dragDistance;
                final step = _dragDistance.abs() >= 48 || velocity.abs() > 100
                    ? (direction > 0 ? 1 : -1) : 0;
                _go((_dragOrigin.round() + step).clamp(0, _ids.length - 1), instant: _staticMode);
              },
              onVerticalDragCancel: () => _go(_index, instant: true),
              // Full-sized bounds own hit testing; the translated cards never
              // rely on an out-of-bounds Positioned child to receive input.
              child: ClipRect(child: AnimatedBuilder(
                animation: _phase,
                builder: (context, _) {
                  final phase = _phase.value.clamp(0.0, (_ids.length - 1).toDouble());
                  final layers = _cards.keys.toList()
                    ..sort((a, b) => (phase - b).abs().compareTo((phase - a).abs()));
                  return Stack(fit: StackFit.expand, children: [
                    for (final index in layers)
                      Align(key: ValueKey('project-layer:${_ids[index]}'), child: Transform.translate(
                        offset: Offset(0, (phase - index) * _layerStep),
                        child: Transform.scale(
                          scale: 1 - .06 * (phase - index).abs().clamp(0.0, 2.0),
                          child: Opacity(
                            opacity: (1 - .22 * (phase - index).abs()).clamp(0.0, 1.0),
                            child: Padding(padding: const EdgeInsets.symmetric(horizontal: 4), child: SizedBox(
                              height: cardHeight,
                              width: double.infinity,
                              child: ExcludeFocus(excluding: index != _index, child: ExcludeSemantics(
                                excluding: index != _index,
                                child: IgnorePointer(ignoring: index != _index || _moving,
                                  child: KeyedSubtree(key: ValueKey('project-card:${_ids[index]}'), child: _cards[index]!),
                                ),
                              )),
                            )),
                          ),
                        ),
                      )),
                  ]);
                },
              )),
            ),
          )),
          SizedBox(width: 48, child: Column(children: [
            SizedBox(height: 40, child: Center(child: Semantics(
              label: 'Proje ${_index + 1} / ${_ids.length}',
              child: ExcludeSemantics(child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Text('${_index + 1}/${_ids.length}', style: Theme.of(context).textTheme.labelLarge
                    ?.copyWith(fontFeatures: const [FontFeature.tabularFigures()])),
              )),
            ))),
            Expanded(child: _ProjectRail(count: _ids.length, index: _index, phase: _phase, onSelected: _scrub)),
            IconButton(
              key: const ValueKey('project-carousel-auto'),
              tooltip: last && _ids.length > 1 ? 'Başa dön' : !_paused && canPlay ? 'Duraklat' : 'Oynat',
              constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
              onPressed: last && _ids.length > 1 ? () => _select(0, instant: true) : canPlay ? _toggleAuto : null,
              icon: Icon(last && _ids.length > 1 ? Icons.replay_rounded : !_paused && canPlay ? Icons.pause_rounded : Icons.play_arrow_rounded),
            ),
          ])),
        ]),
      )),
    );
  }
}

/// One adjustable native accessibility node, not one widget per project.
class _ProjectRail extends StatefulWidget {
  const _ProjectRail({required this.count, required this.index, required this.phase, required this.onSelected});
  final int count, index;
  final Animation<double> phase;
  final ValueChanged<double> onSelected;

  @override
  State<_ProjectRail> createState() => _ProjectRailState();
}

class _ProjectRailState extends State<_ProjectRail> {
  _RailTicksPainter? _ticks;

  @override
  Widget build(BuildContext context) {
    final count = widget.count;
    final index = widget.index;
    final onSelected = widget.onSelected;
    final colors = Theme.of(context).colorScheme;
    if (_ticks?.count != count || _ticks?.color != colors.outlineVariant) {
      _ticks = _RailTicksPainter(count, colors.outlineVariant);
    }
    return Semantics(
      key: const ValueKey('project-carousel-rail'),
      slider: true,
      label: 'Proje seçimi',
      value: '${index + 1}/$count',
      increasedValue: index < count - 1 ? '${index + 2}/$count' : null,
      decreasedValue: index > 0 ? '$index/$count' : null,
      onIncrease: index < count - 1 ? () => onSelected((index + 1).toDouble()) : null,
      onDecrease: index > 0 ? () => onSelected((index - 1).toDouble()) : null,
      child: SizedBox(width: 48, child: LayoutBuilder(builder: (context, constraints) {
        final travel = math.max(1.0, constraints.maxHeight - 32);
        double phaseAt(double y) => ((y - 16) / travel).clamp(0.0, 1.0) * (count - 1);
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          dragStartBehavior: DragStartBehavior.down,
          onTapDown: (details) => onSelected(phaseAt(details.localPosition.dy).roundToDouble()),
          onVerticalDragStart: (details) => onSelected(phaseAt(details.localPosition.dy)),
          onVerticalDragUpdate: (details) => onSelected(phaseAt(details.localPosition.dy)),
          onVerticalDragEnd: (_) => onSelected(widget.phase.value.roundToDouble()),
          onVerticalDragCancel: () => onSelected(widget.phase.value.roundToDouble()),
          child: ExcludeSemantics(child: Stack(children: [
            Positioned.fill(child: RepaintBoundary(child: CustomPaint(painter: _ticks))),
            Positioned.fill(child: AnimatedBuilder(
              animation: widget.phase,
              builder: (context, _) => Align(alignment: Alignment.topLeft, child: Transform.translate(
                offset: Offset(14, 8 + (count == 1 ? 0 : widget.phase.value / (count - 1)) * travel),
                child: Container(width: 20, height: 16, decoration: BoxDecoration(
                  color: colors.primary,
                  borderRadius: BorderRadius.circular(8),
                )),
              )),
            )),
          ])),
        );
      })),
    );
  }
}

class _RailTicksPainter extends CustomPainter {
  _RailTicksPainter(this.count, this.color);
  final int count;
  final Color color;
  Path? _ticks;
  Size? _size;

  @override
  void paint(Canvas canvas, Size size) {
    if (_size != size) {
      _size = size;
      final path = Path();
      final travel = math.max(1.0, size.height - 32);
      for (var i = 0; i < count; i++) {
        final y = 16 + (count == 1 ? 0 : i / (count - 1)) * travel;
        path.moveTo(size.width / 2 - 6, y);
        path.lineTo(size.width / 2 + 6, y);
      }
      _ticks = path;
    }
    canvas.drawPath(_ticks!, Paint()..color = color..strokeWidth = 2..style = PaintingStyle.stroke);
  }

  @override
  bool shouldRepaint(_RailTicksPainter oldDelegate) => count != oldDelegate.count || color != oldDelegate.color;
}

/// Geometry notifications do not tick or rebuild while the deck is stationary.
class _DeckVisibility extends SingleChildRenderObjectWidget {
  const _DeckVisibility({super.key, required this.onGeometryChanged, required super.child});
  final VoidCallback onGeometryChanged;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderDeckVisibility(onGeometryChanged);

  @override
  void updateRenderObject(BuildContext context, _RenderDeckVisibility renderObject) {
    renderObject.onGeometryChanged = onGeometryChanged;
  }
}

class _RenderDeckVisibility extends RenderProxyBox {
  _RenderDeckVisibility(this.onGeometryChanged);
  VoidCallback onGeometryChanged;

  @override
  void performLayout() {
    super.performLayout();
    onGeometryChanged();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    super.paint(context, offset);
    onGeometryChanged();
  }
}
