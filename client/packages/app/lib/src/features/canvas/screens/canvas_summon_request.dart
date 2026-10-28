// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The prompt a summon becomes: nobody is moved until they accept it.
library;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:slimm_design_system/design_system.dart';

import 'canvas_view_relay.dart';

/// Leaves full screen, then waits out the two frames the focused fit needs to put the camera back, so the move that follows is not undone.
Future<void> leaveFullscreenThenSettle(VoidCallback leave) async {
  leave();
  final binding = SchedulerBinding.instance;
  await binding.endOfFrame;
  await binding.endOfFrame;
}

class CanvasSummonRequestCard extends StatelessWidget {
  const CanvasSummonRequestCard({
    super.key,
    required this.relay,
    required this.nameOf,
    required this.onAccept,
  });

  final CanvasViewRelay relay;
  final String? Function(String userId) nameOf;

  /// Moves to the summoner's view; the caller decides what must happen first.
  final VoidCallback onAccept;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<SummonRequest?>(
    valueListenable: relay.summonRequest,
    builder: (context, request, _) {
      if (request == null) return const SizedBox.shrink();
      final name = nameOf(request.userId) ?? 'Someone';
      return _Card(
        message: '$name wants to bring you to their view',
        onAccept: onAccept,
        onDecline: relay.declineSummon,
      );
    },
  );
}

class _Card extends StatelessWidget {
  const _Card({
    required this.message,
    required this.onAccept,
    required this.onDecline,
  });

  final String message;
  final VoidCallback onAccept;
  final VoidCallback onDecline;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Semantics(
      container: true,
      liveRegion: true,
      label: message,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: tokens.surfaceRaised,
            borderRadius: BorderRadius.circular(AppRadii.card),
            border: Border.all(color: tokens.borderSubtle),
          ),
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.s12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ExcludeSemantics(
                  child: Text(
                    message,
                    style: AppText.ui.copyWith(color: tokens.textPrimary),
                  ),
                ),
                const SizedBox(height: AppSpacing.s8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    AppButton(
                      label: 'Decline',
                      size: AppButtonSize.sm,
                      onPressed: onDecline,
                    ),
                    const SizedBox(width: AppSpacing.s8),
                    AppButton(
                      label: 'Accept',
                      size: AppButtonSize.sm,
                      variant: AppButtonVariant.primary,
                      onPressed: onAccept,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
