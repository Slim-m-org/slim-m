// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// "Pictures on your screen" (decision 0121): the pictures viewers stamped on
/// your shared screen in the last day, so one can still be reported or its
/// sender blocked after it faded. A popover on a wide window, a sheet on a narrow one.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../../format.dart';
import '../../../widgets/anchored_popover_or_sheet.dart';
import '../../canvas/widgets/stamp_view.dart';
import '../../members/providers/blocks_controller.dart';
import '../../members/providers/user_profiles.dart';
import '../../members/widgets/safety_actions.dart';
import '../../screen_overlay/providers/stamp_actions.dart';
import '../../screen_overlay/providers/stamp_content.dart';

export '../../screen_overlay/providers/stamp_actions.dart'
    show receivedScreenStampsProvider;

/// The list's width as a popover.
const _popoverWidth = 360.0;

/// A picture's square in its row.
const _thumbSide = AppSizes.controlLg;

/// Opens the list beside [anchor].
Future<void> showScreenStampsReceived(BuildContext anchor) =>
    showAnchoredPopoverOrSheet<void>(
      anchor,
      semanticLabel: 'Pictures on your screen',
      popoverBuilder: (context) => const AppMenu(
        width: _popoverWidth,
        children: [ScreenStampsReceived()],
      ),
      sheetBuilder: (context) =>
          const SafeArea(top: false, child: ScreenStampsReceived()),
    );

class ScreenStampsReceived extends ConsumerWidget {
  const ScreenStampsReceived({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final stamps = ref.watch(receivedScreenStampsProvider);
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.s8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.s4,
              0,
              AppSpacing.s4,
              AppSpacing.s4,
            ),
            child: Text(
              'Pictures on your screen',
              style: AppText.ui.copyWith(
                fontWeight: AppWeights.semi,
                color: tokens.textPrimary,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.s4,
              0,
              AppSpacing.s4,
              AppSpacing.s8,
            ),
            child: Text(
              'From the last day. Report one or block who sent it.',
              style: AppText.caption.copyWith(color: tokens.textSecondary),
            ),
          ),
          switch (stamps) {
            AsyncData(:final value) when value.isEmpty => _Note(
              'No pictures in the last day.',
              tokens: tokens,
            ),
            AsyncData(:final value) => ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 360),
              child: ListView(
                shrinkWrap: true,
                children: [for (final stamp in value) _Row(stamp: stamp)],
              ),
            ),
            AsyncError() => AppErrorState(
              message: 'Could not load the pictures.',
              onRetry: () => ref.invalidate(receivedScreenStampsProvider),
            ),
            _ => _Note('Loading the pictures...', tokens: tokens),
          },
        ],
      ),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note(this.text, {required this.tokens});

  final String text;
  final AppTokens tokens;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(AppSpacing.s12),
    child: Text(
      text,
      textAlign: TextAlign.center,
      style: AppText.ui.copyWith(color: tokens.textSecondary),
    ),
  );
}

class _Row extends ConsumerWidget {
  const _Row({required this.stamp});

  final api.ReceivedScreenStamp stamp;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final sender = ref.watch(userProfileProvider(stamp.senderId)).valueOrNull;
    final name = sender?.displayName ?? 'Someone';
    final blocked = ref.watch(blocksProvider).contains(stamp.senderId);
    final container = ProviderScope.containerOf(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.s4),
      child: Row(
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              color: tokens.surfaceSunken,
              borderRadius: BorderRadius.circular(AppRadii.control),
            ),
            child: SizedBox.square(
              dimension: _thumbSide,
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.s4),
                child: StampView(
                  content: PictureStamp(stamp.attachmentId),
                  semanticLabel: 'Picture from $name',
                ),
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.s8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.ui.copyWith(color: tokens.textPrimary),
                ),
                Text(
                  formatRelativeAgeMs(stamp.createdAt),
                  style: AppText.caption.copyWith(color: tokens.textSecondary),
                ),
              ],
            ),
          ),
          AppButton(
            label: stamp.reported ? 'Reported' : 'Report',
            size: AppButtonSize.sm,
            variant: AppButtonVariant.ghost,
            disabled: stamp.reported,
            semanticLabel: 'Report the picture from $name',
            onPressed: () async {
              await fileReport(
                context,
                container,
                subject: api.ReportSubject.screenStamp,
                subjectId: stamp.id,
                subjectLabel: 'this picture',
              );
              container.invalidate(receivedScreenStampsProvider);
            },
          ),
          AppButton(
            label: blocked ? 'Blocked' : 'Block',
            size: AppButtonSize.sm,
            variant: AppButtonVariant.ghost,
            disabled: blocked,
            semanticLabel: 'Block $name',
            onPressed: () => blockUser(context, container, stamp.senderId),
          ),
        ],
      ),
    );
  }
}
