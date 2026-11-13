import 'package:flutter/material.dart';
import 'neumorphic.dart';

// Neumorphic treatment adapted from Uiverse.io by coslac / Smit-Prajapati.
class NeumorphicMessageInput extends StatelessWidget {
  const NeumorphicMessageInput({super.key, required this.controller, required this.enabled});
  final TextEditingController controller;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return NeoSurface(
      radius: 20, padding: const EdgeInsets.all(4),
      child: MergeSemantics(child: Semantics(label: 'OMP’ye mesaj', child: TextField(
        controller: controller, enabled: enabled,
        minLines: 1, maxLines: 6, textCapitalization: TextCapitalization.sentences,
        style: Theme.of(context).textTheme.bodyLarge?.copyWith(color: enabled ? scheme.onSurface : scheme.onSurfaceVariant),
        decoration: const InputDecoration(hintText: 'OMP’ye yaz… / ile komut aç', contentPadding: EdgeInsets.all(16)),
      ))),
    );
  }
}

