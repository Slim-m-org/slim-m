// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The sections modules add to a member's profile card, after the built-in
/// ones; absent entirely when no module has anything to say.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../modules/widgets/module_slot_view.dart';
import '../providers/module_profile_slots.dart';

class ModuleProfileSlots extends ConsumerWidget {
  const ModuleProfileSlots(this.userId, {super.key});

  final String userId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sections = ref
        .watch(moduleProfileSlotsProvider(userId))
        .valueOrNull
        ?.where((section) => !section.item.isEmpty)
        .toList(growable: false);
    if (sections == null || sections.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.s16,
        0,
        AppSpacing.s16,
        AppSpacing.s12,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: AppSpacing.s12,
        children: [for (final section in sections) _Section(section)],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section(this.section);

  final api.ModuleProfileSection section;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: AppSpacing.s4,
      children: [
        Semantics(
          header: true,
          child: Text(
            section.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppText.label.copyWith(color: tokens.textSecondary),
          ),
        ),
        SizedBox(
          width: double.infinity,
          child: ModuleSlotView(section.item, source: section.moduleId),
        ),
      ],
    );
  }
}
