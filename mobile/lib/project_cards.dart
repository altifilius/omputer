import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'controller.dart';
import 'models.dart';
import 'neumorphic.dart';
import 'ui.dart';
import 'working_avatar.dart';

/// A snapshot-derived project overview shared by the list and snap deck.
class ProjectSummary {
  ProjectSummary._();

  int _open = 0;
  int _pending = 0;
  bool _working = false;
  bool _foregroundWork = false;
  bool _waiting = false;
  bool _writer = false;
  String _status = '';

  int get open => _open;
  int get pending => _pending;
  bool get working => _working;
  String get status => _status;
}

Map<String, ProjectSummary> projectSummaries(
  OmputerController controller,
  List<Project> projects,
) {
  final summaries = {for (final project in projects) project.id: ProjectSummary._()};
  for (final session in controller.snapshot.sessions) {
    final summary = summaries[session.projectId];
    if (summary == null) continue;
    if (!session.archived || session.activeUnbridged) summary._open++;
    summary._writer |= session.writerConnected;
    final state = session.workState;
    summary._waiting |= state == 'human_wait' || session.status == 'waiting';
    final working = session.isWorking;
    summary._working |= working;
    summary._foregroundWork |= working && state == 'running';
  }
  final now = DateTime.now();
  for (final interaction in controller.snapshot.interactions) {
    if (!interaction.pendingAt(now)) continue;
    final summary = summaries[interaction.projectId];
    if (summary != null) summary._pending++;
  }
  for (final project in projects) {
    final summary = summaries[project.id]!;
    summary._pending = math.max(summary._pending,
        math.max(project.pendingCount, project.activity?.pendingCount ?? 0));
    summary._working &= controller.connection.connected;
    summary._status = !controller.connection.connected ? 'Bağlantı kesik'
        : summary._working ? (summary._foregroundWork ? 'Çalışıyor' : 'Arka plan işi sürüyor')
        : summary._waiting || summary._pending > 0 ? 'Yanıt bekliyor'
        : summary._open == 0 ? 'Açık oturum yok'
        : !summary._writer ? 'Oturum bağlantısı kesik'
        : 'Tur tamamlandı';
  }
  return summaries;
}

String _continuationPreview(Project project) {
  final activity = project.activity;
  final activityIsNewer = activity != null && activity.updatedAt != null &&
      (project.memoryUpdatedAt == null || activity.updatedAt!.isAfter(project.memoryUpdatedAt!));
  final candidates = activityIsNewer
      ? [activity.nextStep, activity.lastAssistantText, project.summary, project.nextStep]
      : [project.summary, project.nextStep, activity?.nextStep ?? '', activity?.lastAssistantText ?? ''];
  final source = candidates.where((value) => value.trim().isNotEmpty).firstOrNull;
  if (source == null) return 'Son durum henüz kaydedilmedi';
  return source
      .replaceAllMapped(RegExp(r'\[([^\]]+)\]\([^\)]+\)'), (match) => match[1]!)
      .replaceAll(RegExp(r'^\s{0,3}(?:#{1,6}\s+|[-*+]\s+|>\s*)', multiLine: true), '')
      .replaceAll(RegExp(r'[`*_]'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

class ProjectOverviewCard extends StatelessWidget {
  const ProjectOverviewCard({
    super.key,
    required this.controller,
    required this.project,
    required this.summary,
    required this.onTap,
    this.selected = false,
    this.expanded = false,
    this.animateAvatar = true,
    this.dense = false,
  });

  final OmputerController controller;
  final Project project;
  final ProjectSummary summary;
  final VoidCallback onTap;
  final bool selected;
  final bool expanded;
  final bool animateAvatar;
  /// A bounded Home preview; large text scrolls inside rather than growing it.
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final palette = NeoPalette.of(context);
    final pinned = object(object(controller.localState['sections'])['pins'])['project:${project.id}'] == true;
    final fill = selected
        ? Color.lerp(palette.raised, palette.light, theme.brightness == Brightness.dark ? .16 : .3)!
        : palette.inset;
    final content = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (summary.working && animateAvatar) ...[
            const ExcludeSemantics(child: WorkingAvatar(size: 64)),
            const SizedBox(width: 12),
          ],
          Expanded(child: Padding(padding: const EdgeInsets.only(top: 8), child: Text(
            project.name,
            style: (expanded ? theme.textTheme.headlineSmall : theme.textTheme.titleLarge)
                ?.copyWith(fontWeight: FontWeight.w600, color: colors.onSurface),
          ))),
          const SizedBox(width: 8),
          IconButton(
            key: ValueKey('project-pin:${project.id}'),
            tooltip: pinned ? 'Proje sabitlemesini kaldır' : 'Projeyi sabitle',
            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
            color: colors.onSurfaceVariant,
            onPressed: () => perform(context, () => controller.updateLocalState('pins', 'project:${project.id}', !pinned)),
            icon: Icon(pinned ? Icons.push_pin_rounded : Icons.push_pin_outlined, size: 20),
          ),
        ]),
        const SizedBox(height: 8),
        Text(
          _continuationPreview(project),
          maxLines: expanded ? 5 : 3,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodyMedium?.copyWith(color: colors.onSurfaceVariant, height: 1.4),
        ),
      ],
    );
    return Semantics(
      container: true,
      button: true,
      selected: selected,
      value: summary.status,
      hint: 'Projeyi aç',
      child: NeoSurface(
        radius: 20,
        compact: !selected,
        color: fill,
        borderColor: selected ? colors.outline : colors.outlineVariant,
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: onTap,
          child: Padding(
            padding: EdgeInsets.all(dense ? 12 : 20),
            child: dense ? SingleChildScrollView(
              key: ValueKey('project-card-scroll:${project.id}'),
              primary: false,
              physics: const ClampingScrollPhysics(),
              child: content,
            ) : content,
          ),
        ),
      ),
    );
  }
}
