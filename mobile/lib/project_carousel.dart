import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import 'controller.dart';
import 'models.dart';
import 'projects.dart';
import 'ui.dart';
import 'working_avatar.dart';
import 'neumorphic.dart';

/// A parent-controlled project ring. Only deliberate selections and automatic
/// front-card changes call [onSelected], never individual animation frames.
class ProjectCarousel extends StatefulWidget {
  const ProjectCarousel({
    super.key,
    required this.controller,
    required this.projects,
    required this.selectedProjectId,
    required this.onSelected,
    this.autoRotate = true,
  });

  final OmputerController controller;
  final List<Project> projects;
  final String selectedProjectId;
  final ValueChanged<String> onSelected;
  final bool autoRotate;

  @override
  State<ProjectCarousel> createState() => _ProjectCarouselState();
}

class _ProjectCarouselState extends State<ProjectCarousel>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  static const _turn = math.pi * 2;
  static const _snapDuration = Duration(milliseconds: 240);
  static const _snapCurve = Cubic(.16, 1, .3, 1);
  late final AnimationController _rotation;
  late final ValueNotifier<String?> _foreground;
  late bool _paused;
  bool _autoRunning = false;
  bool _visible = false;
  bool _resumed = true;
  bool _tickerEnabled = true;
  bool _reduceMotion = false;
  bool _accessibleNavigation = false;
  bool _routeCurrent = true;
  bool _visibilityScheduled = false;
  bool _selectionScheduled = false;
  ScrollPosition? _scrollPosition;
  String? _requestedId;
  List<String> _ids = const [];

  int get _selectedIndex {
    final index = widget.projects.indexWhere((p) => p.id == widget.selectedProjectId);
    return index < 0 ? 0 : index;
  }

  double get _step => widget.projects.isEmpty ? _turn : _turn / widget.projects.length;
  int get _frontIndex => widget.projects.isEmpty
      ? 0
      : (-_rotation.value / _step).round() % widget.projects.length;
  bool get _motionAllowed => _resumed && _visible && _tickerEnabled && _routeCurrent && !_reduceMotion;
  bool get _canAuto => _motionAllowed && !_accessibleNavigation && !_paused && widget.projects.length > 1;

  @override
  void initState() {
    super.initState();
    _paused = !widget.autoRotate;
    _ids = widget.projects.map((p) => p.id).toList();
    _rotation = AnimationController.unbounded(vsync: this, value: -_selectedIndex * _step)
      ..addListener(_rotationChanged);
    _foreground = ValueNotifier(widget.projects.isEmpty ? null : widget.projects[_selectedIndex].id);
    _resumed = WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
    widget.controller.addListener(_dataChanged);
    _reconcileSelection();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _tickerEnabled = TickerMode.valuesOf(context).enabled;
    _reduceMotion = MediaQuery.disableAnimationsOf(context);
    _accessibleNavigation = MediaQuery.accessibleNavigationOf(context);
    _routeCurrent = ModalRoute.isCurrentOf(context) ?? true;
    final position = Scrollable.maybeOf(context)?.position;
    if (position != _scrollPosition) {
      _scrollPosition?.removeListener(_scheduleVisibility);
      _scrollPosition = position;
      position?.addListener(_scheduleVisibility);
    }
    _scheduleVisibility();
    _syncMotion();
  }

  @override
  void didUpdateWidget(ProjectCarousel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_dataChanged);
      widget.controller.addListener(_dataChanged);
    }
    final ids = widget.projects.map((p) => p.id).toList();
    var reordered = ids.length != _ids.length;
    if (!reordered) {
      for (var i = 0; i < ids.length; i++) {
        if (ids[i] != _ids[i]) {
          reordered = true;
          break;
        }
      }
    }
    final changedSelection = oldWidget.selectedProjectId != widget.selectedProjectId;
    if (reordered || (changedSelection && widget.selectedProjectId != _requestedId)) {
      _autoRunning = false;
      _rotation.stop();
      _rotation.value = -_selectedIndex * _step;
    }
    _ids = ids;
    _rotationChanged();
    if (oldWidget.autoRotate != widget.autoRotate) _paused = !widget.autoRotate;
    _reconcileSelection();
    _syncMotion();
    _scheduleVisibility();
  }

  void _dataChanged() {
    if (mounted) setState(() {});
  }

  void _reconcileSelection() {
    if (widget.projects.isEmpty || widget.projects.any((p) => p.id == widget.selectedProjectId)) return;
    final fallback = widget.projects.first.id;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || widget.projects.isEmpty || widget.projects.first.id != fallback ||
          widget.projects.any((p) => p.id == widget.selectedProjectId)) return;
      _requestedId = fallback;
      widget.onSelected(fallback);
    });
  }

  void _rotationChanged() {
    if (widget.projects.isEmpty) {
      _foreground.value = null;
      return;
    }
    final id = widget.projects[_frontIndex].id;
    _foreground.value = id;
    if (_autoRunning && id != widget.selectedProjectId && id != _requestedId) {
      if (_selectionScheduled) return;
      _selectionScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _selectionScheduled = false;
        if (!mounted || !_autoRunning || widget.projects.isEmpty) return;
        final frontId = widget.projects[_frontIndex].id;
        if (frontId == widget.selectedProjectId) return;
        _requestedId = frontId;
        widget.onSelected(frontId);
      });
    }
  }

  void _syncMotion() {
    if (!_motionAllowed || _accessibleNavigation) {
      _autoRunning = false;
      _rotation.stop();
      if (_reduceMotion || _accessibleNavigation) _rotation.value = -_selectedIndex * _step;
      return;
    }
    if (_canAuto) {
      if (!_autoRunning) {
        _autoRunning = true;
        _rotation.repeat(min: _rotation.value, max: _rotation.value + _turn, period: const Duration(seconds: 20));
      }
    } else if (_autoRunning) {
      _autoRunning = false;
      _rotation.stop();
    }
  }

  void _scheduleVisibility() {
    if (_visibilityScheduled) return;
    _visibilityScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _visibilityScheduled = false;
      if (!mounted) return;
      final render = context.findRenderObject();
      var visible = false;
      if (render is RenderBox && render.attached && render.hasSize) {
        final rect = render.localToGlobal(Offset.zero) & render.size;
        var viewport = Offset.zero & MediaQuery.sizeOf(context);
        final scrollViewport = context.findAncestorRenderObjectOfType<RenderAbstractViewport>() as RenderBox?;
        if (scrollViewport is RenderBox && scrollViewport.attached && scrollViewport.hasSize) {
          viewport = viewport.intersect(scrollViewport.localToGlobal(Offset.zero) & scrollViewport.size);
        }
        visible = rect.overlaps(viewport) && !viewport.isEmpty;
      }
      if (_visible != visible) {
        setState(() => _visible = visible);
        _syncMotion();
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    setState(() => _resumed = state == AppLifecycleState.resumed);
    _syncMotion();
    if (_resumed) _scheduleVisibility();
  }

  void _pause() {
    _autoRunning = false;
    _rotation.stop();
    if (!_paused) setState(() => _paused = true);
  }

  double _nearestAngle(int index) {
    final target = -index * _step;
    return target + ((_rotation.value - target) / _turn).round() * _turn;
  }

  void _select(int index, {bool instant = false}) {
    if (widget.projects.isEmpty) return;
    _pause();
    index %= widget.projects.length;
    final id = widget.projects[index].id;
    _requestedId = id;
    if (id != widget.selectedProjectId) widget.onSelected(id);
    final target = _nearestAngle(index);
    if (instant || !_motionAllowed || _accessibleNavigation) {
      _rotation.value = target;
    } else {
      _rotation.animateTo(target, duration: _snapDuration, curve: _snapCurve);
    }
  }

  void _tapCard(int index) {
    final project = widget.projects[index];
    final opens = index == _frontIndex && project.id == widget.selectedProjectId;
    _select(index);
    if (opens) openScreen(context, ProjectScreen(controller: widget.controller, projectId: project.id));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.controller.removeListener(_dataChanged);
    _scrollPosition?.removeListener(_scheduleVisibility);
    _rotation.dispose();
    _foreground.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.projects.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final selected = _selectedIndex;
    final staticMode = _reduceMotion || _accessibleNavigation;
    final summaries = _projectSummaries(widget.controller, widget.projects);
    return Focus(
      key: const ValueKey('project-carousel-focus'),
      onFocusChange: (focused) {
        if (focused) _pause();
        _syncMotion();
      },
      onKeyEvent: (_, event) {
        if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
        if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
          _select(selected + 1, instant: true);
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
          _select(selected - 1, instant: true);
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: LayoutBuilder(builder: (context, constraints) {
        final available = constraints.maxWidth.isFinite ? constraints.maxWidth : MediaQuery.sizeOf(context).width;
        final width = math.min(200.0, math.max(48.0, available - 48));
        final height = _cardHeight(context, width, summaries);
        final radius = math.min(available * .40, 176.0);
        final depth = math.min(112.0, available * .26);
        final stageHeight = height + 88;
        final cards = <Widget>[
          for (var i = 0; i < widget.projects.length; i++)
            RepaintBoundary(
              key: ValueKey('project-card-content:${widget.projects[i].id}'),
              child: _ProjectCard(
                project: widget.projects[i],
                summary: summaries[widget.projects[i].id]!,
                foreground: _foreground,
                animationsEnabled: _motionAllowed && !staticMode,
                accent: [theme.colorScheme.primary, theme.colorScheme.secondary, theme.colorScheme.tertiary][i % 3],
              ),
            ),
        ];
        return Column(mainAxisSize: MainAxisSize.min, children: [
          GestureDetector(
            key: const ValueKey('project-carousel-stage'),
            behavior: HitTestBehavior.opaque,
            onHorizontalDragStart: (_) => _pause(),
            onHorizontalDragUpdate: (details) {
              if (!staticMode) _rotation.value += details.delta.dx / math.max(radius, 48);
            },
            onHorizontalDragEnd: (details) {
              if (staticMode) {
                if (details.primaryVelocity != null && details.primaryVelocity!.abs() > 100) {
                  _select(selected + (details.primaryVelocity! < 0 ? 1 : -1), instant: true);
                }
              } else {
                _select(_frontIndex);
              }
            },
            onHorizontalDragCancel: () => _select(_frontIndex),
            child: SizedBox(
              height: stageHeight,
              width: available,
              child: ClipRect(child: AnimatedBuilder(
                animation: _rotation,
                builder: (context, _) {
                  final order = List.generate(widget.projects.length, (i) => i)
                    ..sort((a, b) => math.cos(a * _step + _rotation.value)
                        .compareTo(math.cos(b * _step + _rotation.value)));
                  return Stack(clipBehavior: Clip.none, children: [
                    for (final i in order)
                      if (!staticMode || i == selected)
                        _positionCard(
                          index: i,
                          selected: selected,
                          width: width,
                          height: height,
                          stageWidth: available,
                          stageHeight: stageHeight,
                          radius: radius,
                          depth: depth,
                          staticMode: staticMode,
                          child: cards[i],
                        ),
                  ]);
                },
              )),
            ),
          ),
          Wrap(
            alignment: WrapAlignment.center,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 8,
            children: [
              IconButton(
                key: const ValueKey('project-carousel-previous'),
                tooltip: 'Önceki proje',
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                onPressed: widget.projects.length > 1 ? () => _select(selected - 1) : null,
                icon: const Icon(Icons.chevron_left_rounded),
              ),
              Semantics(
                label: 'Proje ${selected + 1} / ${widget.projects.length}',
                child: ExcludeSemantics(child: Text('${selected + 1} / ${widget.projects.length}', style: theme.textTheme.labelLarge)),
              ),
              IconButton(
                key: const ValueKey('project-carousel-next'),
                tooltip: 'Sonraki proje',
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                onPressed: widget.projects.length > 1 ? () => _select(selected + 1) : null,
                icon: const Icon(Icons.chevron_right_rounded),
              ),
              IconButton(
                key: const ValueKey('project-carousel-play'),
                tooltip: _canAuto ? 'Döndürmeyi duraklat' : 'Döndürmeyi başlat',
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                onPressed: !staticMode && widget.projects.length > 1 ? () {
                  if (_autoRunning) {
                    _pause();
                  } else {
                    setState(() => _paused = false);
                    _syncMotion();
                  }
                } : null,
                icon: Icon(_canAuto ? Icons.pause_rounded : Icons.play_arrow_rounded),
              ),
            ],
          ),
        ]);
      }),
    );
  }

  double _cardHeight(BuildContext context, double width, Map<String, _ProjectSummary> summaries) {
    final theme = Theme.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    double textHeight(String text, TextStyle? style, int lines, double maxWidth) {
      final painter = TextPainter(
        text: TextSpan(text: text, style: style),
        textDirection: Directionality.of(context),
        textScaler: scaler,
        maxLines: lines,
        ellipsis: '…',
      )..layout(maxWidth: math.max(1, maxWidth));
      final measured = painter.height;
      painter.dispose();
      return measured;
    }
    var height = 260.0;
    for (final project in widget.projects) {
      final summary = summaries[project.id]!;
      final contentWidth = width - 32;
      final goal = project.goal.trim().isNotEmpty ? project.goal : project.activity?.goal ?? '';
      final statusHeight = textHeight(summary.status, theme.textTheme.labelLarge, 3, contentWidth - 56);
      final measured = 32 + 24 +
          textHeight(project.name, theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600), 2, contentWidth) +
          textHeight(goal.isEmpty ? 'Henüz hedef kaydedilmedi' : goal, theme.textTheme.bodyMedium, 2, contentWidth) +
          math.max(48, statusHeight) +
          textHeight('${summary.open} açık oturum', theme.textTheme.labelMedium, 2, contentWidth) +
          (summary.pending > 0 ? textHeight('${summary.pending} karar bekliyor', theme.textTheme.labelMedium, 2, contentWidth) : 0);
      height = math.max(height, measured + 8);
    }
    return (height / 4).ceil() * 4.0;
  }

  Widget _positionCard({
    required int index,
    required int selected,
    required double width,
    required double height,
    required double stageWidth,
    required double stageHeight,
    required double radius,
    required double depth,
    required bool staticMode,
    required Widget child,
  }) {
    final angle = index * _step + _rotation.value;
    final cosine = math.cos(angle);
    final front = staticMode ? index == selected : index == _frontIndex;
    final readableSide = staticMode || cosine > .08;
    final semanticFront = front && index == selected;
    final project = widget.projects[index];
    final transform = Matrix4.identity();
    if (!staticMode) {
      transform
        ..setEntry(3, 2, .0014)
        ..rotateX(-math.pi / 12)
        ..translateByDouble(radius * math.sin(angle), 0, depth * (cosine - 1), 1)
        ..rotateY(angle);
    }
    return Positioned(
      key: ValueKey('project-card-position:${project.id}'),
      left: (stageWidth - width) / 2,
      top: (stageHeight - height) / 2,
      width: width,
      height: height,
      child: Transform(
        alignment: Alignment.center,
        transform: transform,
        child: IgnorePointer(
          ignoring: !readableSide,
          child: ExcludeSemantics(
            excluding: !semanticFront,
            child: Semantics(
              key: ValueKey('project-card:${project.id}'),
              container: true,
              button: true,
              selected: semanticFront,
              label: project.name,
              hint: 'Projeyi aç',
              onTap: semanticFront ? () => _tapCard(index) : null,
              onIncrease: semanticFront && widget.projects.length > 1 ? () => _select(selected + 1, instant: true) : null,
              onDecrease: semanticFront && widget.projects.length > 1 ? () => _select(selected - 1, instant: true) : null,
              child: GestureDetector(
                excludeFromSemantics: true,
                onTap: () => _tapCard(index),
                child: Stack(fit: StackFit.expand, children: [
                  Offstage(offstage: !readableSide, child: child),
                  if (!readableSide) _CardBack(accent: Theme.of(context).colorScheme.outlineVariant),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ProjectSummary {
  int open = 0;
  int pending = 0;
  bool working = false;
  bool foregroundWork = false;
  bool waiting = false;
  bool writer = false;
  String status = '';
}

Map<String, _ProjectSummary> _projectSummaries(OmputerController controller, List<Project> projects) {
  final summaries = {for (final p in projects) p.id: _ProjectSummary()};
  for (final session in controller.snapshot.sessions) {
    final summary = summaries[session.projectId];
    if (summary == null) continue;
    if (!session.archived || session.activeUnbridged) summary.open++;
    summary.writer |= session.writerConnected;
    final state = session.workState;
    summary.waiting |= state == 'human_wait' || session.status == 'waiting';
    final working = session.writerConnected && (state == 'running' || state == 'background');
    summary.working |= working;
    summary.foregroundWork |= working && state == 'running';
  }
  for (final interaction in controller.snapshot.pending) {
    final summary = summaries[interaction.projectId];
    if (summary != null) summary.pending++;
  }
  for (final project in projects) {
    final summary = summaries[project.id]!;
    summary.pending = math.max(summary.pending, math.max(project.pendingCount, project.activity?.pendingCount ?? 0));
    summary.working &= controller.connection.connected;
    summary.status = !controller.connection.connected ? 'Bağlantı kesik'
        : summary.working ? (summary.foregroundWork ? 'Çalışıyor' : 'Arka plan işi sürüyor')
        : summary.waiting || summary.pending > 0 ? 'Yanıt bekliyor'
        : summary.open == 0 ? 'Açık oturum yok'
        : !summary.writer ? 'Oturum bağlantısı kesik'
        : 'Tur tamamlandı';
  }
  return summaries;
}

class _ProjectCard extends StatelessWidget {
  const _ProjectCard({required this.project, required this.summary, required this.foreground, required this.animationsEnabled, required this.accent});
  final Project project;
  final _ProjectSummary summary;
  final ValueListenable<String?> foreground;
  final bool animationsEnabled;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final goal = project.goal.trim().isNotEmpty ? project.goal : project.activity?.goal ?? '';
    return NeoSurface(
      radius: 20, borderColor: accent.withValues(alpha: .35),
      padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(project.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600, color: theme.colorScheme.onSurface)),
          const SizedBox(height: 12),
          Text(goal.isEmpty ? 'Henüz hedef kaydedilmedi' : goal, maxLines: 2, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          const Spacer(),
          Row(children: [
            ExcludeSemantics(child: ValueListenableBuilder<String?>(
              valueListenable: foreground,
              builder: (context, id, child) => summary.working && id == project.id
                  ? TickerMode(enabled: animationsEnabled, child: const WorkingAvatar(size: 48))
                  : SizedBox.square(dimension: 48, child: Icon(
                      summary.waiting || summary.pending > 0 ? Icons.hourglass_empty_rounded : Icons.folder_outlined,
                      color: theme.colorScheme.onSurfaceVariant,
                    )),
            )),
            const SizedBox(width: 8),
            Expanded(child: Text(summary.status, maxLines: 3, overflow: TextOverflow.ellipsis, style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.onSurface))),
          ]),
          const SizedBox(height: 12),
          Text('${summary.open} açık oturum', maxLines: 2, overflow: TextOverflow.ellipsis, style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          if (summary.pending > 0) Text('${summary.pending} karar bekliyor', maxLines: 2, overflow: TextOverflow.ellipsis, style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurface)),
        ]),
    );
  }
}

class _CardBack extends StatelessWidget {
  const _CardBack({required this.accent});
  final Color accent;

  @override
  Widget build(BuildContext context) => DecoratedBox(decoration: BoxDecoration(
    color: Theme.of(context).colorScheme.surfaceContainer,
    borderRadius: BorderRadius.circular(20),
    border: Border.all(color: accent),
  ));
}
