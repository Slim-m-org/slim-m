// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// "Pictures on your screen" (decision 0121): who stamped pictures on your
/// shared screen in the last day, one row each, so a sender can still be
/// reported or blocked after their pictures faded, and a flood from one person
/// never pushes another off the list. A row opens that person's pictures.
/// A popover on a wide window, a sheet on a narrow one.
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
    show receivedScreenStampsFromProvider, receivedScreenStampsProvider;

/// The list's width as a popover.
const _popoverWidth = 400.0;

/// The tallest either list grows before it scrolls.
const _listMaxHeight = 360.0;

/// A sender's latest picture in their row.
const _thumbSide = AppSizes.controlLg;

/// One picture in a sender's own list.
const _tileSide = AppSpacing.s64;

/// Opens the list beside [anchor], or [above] it for a control in the call dock.
Future<void> showScreenStampsReceived(
  BuildContext anchor, {
  bool above = false,
}) => showAnchoredPopoverOrSheet<void>(
  anchor,
  above: above,
  semanticLabel: 'Pictures on your screen',
  popoverBuilder: (context) =>
      const AppMenu(width: _popoverWidth, children: [ScreenStampsReceived()]),
  sheetBuilder: (context) =>
      const SafeArea(top: false, child: ScreenStampsReceived()),
);

class ScreenStampsReceived extends ConsumerStatefulWidget {
  const ScreenStampsReceived({super.key});

  @override
  ConsumerState<ScreenStampsReceived> createState() =>
      _ScreenStampsReceivedState();
}

class _ScreenStampsReceivedState extends ConsumerState<ScreenStampsReceived> {
  /// The sender whose pictures are open, as their row showed them, or null for everyone.
  api.ScreenStampSender? _open;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(AppSpacing.s8),
    child: switch (_open) {
      null => _Senders(onOpen: (sender) => setState(() => _open = sender)),
      final sender => _SenderPictures(
        opened: sender,
        onBack: () => setState(() => _open = null),
      ),
    },
  );
}

class _Senders extends ConsumerWidget {
  const _Senders({required this.onOpen});

  final ValueChanged<api.ScreenStampSender> onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final senders = ref.watch(receivedScreenStampsProvider);
    return Column(
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
            'From the last day. Report or block who sent them.',
            style: AppText.caption.copyWith(color: tokens.textSecondary),
          ),
        ),
        switch (senders) {
          AsyncData(:final value) when value.isEmpty => _Note(
            'No pictures in the last day.',
            tokens: tokens,
          ),
          AsyncData(:final value) => ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: _listMaxHeight),
            child: AppStrongLabelScope(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: value.length,
                itemBuilder: (_, i) =>
                    _SenderRow(sender: value[i], onOpen: onOpen),
              ),
            ),
          ),
          AsyncError() => AppErrorState(
            message: 'Could not load the pictures.',
            onRetry: () => ref.invalidate(receivedScreenStampsProvider),
          ),
          _ => _Note('Loading the pictures...', tokens: tokens),
        },
      ],
    );
  }
}

String _senderName(WidgetRef ref, String senderId) =>
    ref.watch(userProfileProvider(senderId)).valueOrNull?.displayName ??
    'Someone';

String _pictureCount(int count) => count == 1 ? '1 picture' : '$count pictures';

class _SenderRow extends ConsumerWidget {
  const _SenderRow({required this.sender, required this.onOpen});

  final api.ScreenStampSender sender;
  final ValueChanged<api.ScreenStampSender> onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final name = _senderName(ref, sender.senderId);
    return AppListRow(
      label: name,
      subtitle:
          '${_pictureCount(sender.count)} · '
          '${formatRelativeAgeMs(sender.latest.createdAt)}',
      semanticLabel: 'Pictures from $name',
      height: _thumbSide + AppSpacing.s8,
      leading: _Thumb(
        attachmentId: sender.latest.attachmentId,
        side: _thumbSide,
      ),
      onTap: () => onOpen(sender),
      trailingExtra: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _SafetyButtons(sender: sender, name: name),
          Icon(
            AppIcons.chevronRight,
            size: AppSizes.icon16,
            color: tokens.textSecondary,
          ),
        ],
      ),
    );
  }
}

/// One sender's pictures from the last day, newest first, with Report and Block for them.
class _SenderPictures extends ConsumerWidget {
  const _SenderPictures({required this.opened, required this.onBack});

  final api.ScreenStampSender opened;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final sender =
        ref
            .watch(receivedScreenStampsProvider)
            .valueOrNull
            ?.where((s) => s.senderId == opened.senderId)
            .firstOrNull ??
        opened;
    final name = _senderName(ref, sender.senderId);
    final pictures = ref.watch(
      receivedScreenStampsFromProvider(sender.senderId),
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            AppIconButton(
              icon: AppIcons.back,
              semanticLabel: 'Back to everyone',
              tooltip: 'Back',
              size: AppIconButtonSize.sm,
              onPressed: onBack,
            ),
            const SizedBox(width: AppSpacing.s4),
            Expanded(
              child: Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.ui.copyWith(
                  fontWeight: AppWeights.semi,
                  color: tokens.textPrimary,
                ),
              ),
            ),
            _SafetyButtons(sender: sender, name: name),
          ],
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.s4,
            AppSpacing.s4,
            AppSpacing.s4,
            AppSpacing.s8,
          ),
          child: Text(
            '${_pictureCount(sender.count)} in the last day.',
            style: AppText.caption.copyWith(color: tokens.textSecondary),
          ),
        ),
        switch (pictures) {
          AsyncData(:final value) when value.isEmpty => _Note(
            'No pictures from them in the last day.',
            tokens: tokens,
          ),
          AsyncData(:final value) => ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: _listMaxHeight),
            child: GridView.builder(
              shrinkWrap: true,
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s4),
              gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: _tileSide + AppSpacing.s16,
                mainAxisExtent: _tileHeight(context),
                mainAxisSpacing: AppSpacing.s8,
                crossAxisSpacing: AppSpacing.s8,
              ),
              itemCount: value.length,
              itemBuilder: (_, i) => _PictureTile(stamp: value[i], name: name),
            ),
          ),
          AsyncError() => AppErrorState(
            message: 'Could not load their pictures.',
            onRetry: () => ref.invalidate(
              receivedScreenStampsFromProvider(sender.senderId),
            ),
          ),
          _ => _Note('Loading their pictures...', tokens: tokens),
        },
      ],
    );
  }

  /// A tile and its age caption, grown with the text size so the caption never clips.
  static double _tileHeight(BuildContext context) =>
      _tileSide +
      AppSpacing.s4 +
      MediaQuery.textScalerOf(context).scale(AppText.caption.fontSize!) *
          AppText.caption.height!;
}

class _PictureTile extends StatelessWidget {
  const _PictureTile({required this.stamp, required this.name});

  final api.ReceivedScreenStamp stamp;
  final String name;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final age = formatRelativeAgeMs(stamp.createdAt);
    return Column(
      children: [
        _Thumb(
          attachmentId: stamp.attachmentId,
          side: _tileSide,
          semanticLabel: 'Picture from $name, $age',
        ),
        const SizedBox(height: AppSpacing.s4),
        ExcludeSemantics(
          child: Text(
            age,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppText.caption.copyWith(color: tokens.textSecondary),
          ),
        ),
      ],
    );
  }
}

class _Thumb extends StatelessWidget {
  const _Thumb({
    required this.attachmentId,
    required this.side,
    this.semanticLabel,
  });

  final String attachmentId;
  final double side;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: tokens.surfaceSunken,
        borderRadius: BorderRadius.circular(AppRadii.control),
      ),
      child: SizedBox.square(
        dimension: side,
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.s4),
          child: StampView(
            content: PictureStamp(attachmentId),
            semanticLabel: semanticLabel,
          ),
        ),
      ),
    );
  }
}

/// Report and Block for one sender: a report names their latest picture and takes all of theirs.
class _SafetyButtons extends ConsumerWidget {
  const _SafetyButtons({required this.sender, required this.name});

  final api.ScreenStampSender sender;
  final String name;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final blocked = ref.watch(blocksProvider).contains(sender.senderId);
    final container = ProviderScope.containerOf(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        AppButton(
          label: sender.reported ? 'Reported' : 'Report',
          size: AppButtonSize.sm,
          variant: AppButtonVariant.ghost,
          disabled: sender.reported,
          semanticLabel: 'Report the pictures from $name',
          onPressed: () async {
            await fileReport(
              context,
              container,
              subject: api.ReportSubject.screenStamp,
              subjectId: sender.latest.id,
              subjectLabel: 'their pictures',
            );
            container
              ..invalidate(receivedScreenStampsProvider)
              ..invalidate(receivedScreenStampsFromProvider(sender.senderId));
          },
        ),
        AppButton(
          label: blocked ? 'Blocked' : 'Block',
          size: AppButtonSize.sm,
          variant: AppButtonVariant.ghost,
          disabled: blocked,
          semanticLabel: 'Block $name',
          onPressed: () => blockUser(context, container, sender.senderId),
        ),
      ],
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
