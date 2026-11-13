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
    final working = session.writerConnected && session.status != 'waiting' &&
        (state == 'running' || state == 'background');
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
    final foreground = colors.onSurface;
    final secondary = colors.onSurfaceVariant;
    final pinned = object(object(controller.localState['sections'])['pins'])['project:${project.id}'] == true;
    final goal = project.goal.trim().isNotEmpty ? project.goal : project.activity?.goal ?? '';
    return Semantics(
      container: true,
      button: true,
      selected: selected,
      hint: 'Projeyi aç',
      child: NeoSurface(
        radius: 20,
        compact: !expanded,
        color: summary.working ? Color.alphaBlend(colors.primary.withValues(alpha: .06), NeoPalette.of(context).raised) : null,
        borderColor: selected ? colors.primary : summary.working ? colors.primary.withValues(alpha: .45) : colors.outlineVariant,
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: onTap,
          child: Padding(
            padding: EdgeInsets.all(dense ? 8 : 20),
            child: dense ? _denseContent(context, goal, pinned) : Column(
              mainAxisSize: expanded ? MainAxisSize.max : MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(child: Text(
                    project.name,
                    style: (expanded ? theme.textTheme.titleLarge : theme.textTheme.titleMedium)
                        ?.copyWith(fontWeight: FontWeight.w600, color: foreground),
                  )),
                  if (selected) ...[
                    const SizedBox(width: 8),
                    ExcludeSemantics(child: Icon(Icons.check_rounded, size: 20, color: foreground)),
                  ],
                ]),
                const SizedBox(height: 8),
                Text(
                  goal.isEmpty ? 'Henüz hedef kaydedilmedi' : goal,
                  maxLines: expanded ? 4 : 3,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(color: secondary),
                ),
                if (expanded) const Spacer(),
                const SizedBox(height: 12),
                Row(children: [
                  ExcludeSemantics(child: summary.working && animateAvatar
                      ? const WorkingAvatar(size: 32)
                      : SizedBox.square(dimension: 32, child: Icon(
                          summary.working ? Icons.sync_rounded
                              : summary.pending > 0 || summary.status == 'Yanıt bekliyor'
                                  ? Icons.hourglass_empty_rounded : Icons.folder_outlined,
                          size: 20,
                          color: secondary,
                        ))),
                  const SizedBox(width: 8),
                  Expanded(child: Text(
                    summary.status,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelLarge?.copyWith(color: summary.working ? colors.primary : foreground),
                  )),
                ]),
                const SizedBox(height: 8),
                Row(children: [
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${summary.open} açık oturum', style: theme.textTheme.labelMedium?.copyWith(color: secondary)),
                    if (summary.pending > 0)
                      Text('${summary.pending} karar bekliyor', style: theme.textTheme.labelMedium?.copyWith(color: foreground)),
                    Text('Projeyi aç', style: theme.textTheme.labelMedium?.copyWith(color: foreground)),
                  ])),
                  const SizedBox(width: 8),
                  IconButton(
                    key: ValueKey('project-pin:${project.id}'),
                    tooltip: pinned ? 'Proje sabitlemesini kaldır' : 'Projeyi sabitle',
                    constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                    color: foreground,
                    onPressed: () => perform(context, () => controller.updateLocalState('pins', 'project:${project.id}', !pinned)),
                    icon: Icon(pinned ? Icons.push_pin_rounded : Icons.push_pin_outlined),
                  ),
                ]),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _denseContent(BuildContext context, String goal, bool pinned) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return SingleChildScrollView(
      key: ValueKey('project-card-scroll:${project.id}'),
      primary: false,
      // Do not claim vertical gestures when this bounded preview fits. Large
      // type still gets a real internal scroll extent and native scrolling.
      physics: const ClampingScrollPhysics(),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: Text(project.name, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600))),
          if (selected) ...[
            const SizedBox(width: 8),
            const ExcludeSemantics(child: Icon(Icons.check_rounded, size: 20)),
          ],
        ]),
        const SizedBox(height: 4),
        Text(
          goal.isEmpty ? 'Henüz hedef kaydedilmedi' : goal,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant),
        ),
        const SizedBox(height: 8),
        Row(children: [
          ExcludeSemantics(child: summary.working && animateAvatar
              ? const WorkingAvatar(size: 24)
              : Icon(summary.working ? Icons.sync_rounded
                  : summary.pending > 0 || summary.status == 'Yanıt bekliyor'
                      ? Icons.hourglass_empty_rounded : Icons.folder_outlined,
                  size: 20, color: colors.onSurfaceVariant)),
          const SizedBox(width: 8),
          Expanded(child: Text(summary.status, style: theme.textTheme.labelLarge?.copyWith(
            color: summary.working ? colors.primary : colors.onSurface,
          ))),
        ]),
        Row(children: [
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${summary.open} açık oturum', style: theme.textTheme.labelMedium?.copyWith(color: colors.onSurfaceVariant)),
            if (summary.pending > 0)
              Text('${summary.pending} karar bekliyor', style: theme.textTheme.labelMedium),
          ])),
          IconButton(
            key: ValueKey('project-pin:${project.id}'),
            tooltip: pinned ? 'Proje sabitlemesini kaldır' : 'Projeyi sabitle',
            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
            onPressed: () => perform(context, () => controller.updateLocalState('pins', 'project:${project.id}', !pinned)),
            icon: Icon(pinned ? Icons.push_pin_rounded : Icons.push_pin_outlined),
          ),
        ]),
      ]),
    );
  }
}
