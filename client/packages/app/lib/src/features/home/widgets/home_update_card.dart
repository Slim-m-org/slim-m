// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// "What's new" on the home, shown once for the version that was installed.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../whats_new/providers/whats_new_controller.dart';
import '../../../whats_new/whats_new_content.dart';
import '../../../widgets/whats_new_sheet.dart';

const _pointsShown = 3;

/// Takes what is pending and marks it seen straight away, so leaving the home
/// and coming back never shows it twice.
class HomeUpdateCard extends ConsumerStatefulWidget {
  const HomeUpdateCard({super.key});

  @override
  ConsumerState<HomeUpdateCard> createState() => _HomeUpdateCardState();
}

class _HomeUpdateCardState extends ConsumerState<HomeUpdateCard> {
  WhatsNewEntry? _held;

  @override
  void initState() {
    super.initState();
    _take(ref.read(whatsNewControllerProvider));
  }

  void _take(List<WhatsNewEntry> pending) {
    if (pending.isEmpty || _held != null) return;
    _held = pending.last;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(whatsNewControllerProvider.notifier).markSeen();
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(whatsNewControllerProvider, (_, next) {
      if (_held == null && next.isNotEmpty) setState(() => _take(next));
    });
    final entry = _held;
    if (entry == null) return const SizedBox.shrink();
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: AppSpacing.s8,
        children: [
          Text(
            "What's new in ${entry.version}",
            style: AppText.body.copyWith(
              color: tokens.textPrimary,
              fontWeight: AppWeights.semi,
            ),
          ),
          Text(
            entry.headline,
            style: AppText.ui.copyWith(color: tokens.textPrimary),
          ),
          for (final point in entry.points.take(_pointsShown))
            Text(
              point.body,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: AppText.ui.copyWith(color: tokens.textSecondary),
            ),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            spacing: AppSpacing.s8,
            children: [
              AppButton(
                label: 'All notes',
                variant: AppButtonVariant.ghost,
                onPressed: () => showReleaseNotesSheet(context),
              ),
              AppButton(
                label: 'Got it',
                variant: AppButtonVariant.soft,
                onPressed: () => setState(() => _held = null),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
