// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The sheet the "edited" marker opens: every version a message has held,
/// oldest first, ending with its current content, each labelled with when it
/// became the message's text.
///
/// Each entry after the first shows a word-level diff against the version
/// immediately before it, not against the original - see `edit_history_diff.dart`
/// for why consecutive steps, not original-vs-current, are the pair worth
/// showing once there are three or more edits.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../providers/display_preferences.dart';
import '../providers/edit_history_provider.dart';
import 'edit_history_diff.dart';
import 'message_code_lexer.dart';
import 'message_row_identity.dart' show formatMessageDay, formatMessageTime;

/// Sizes the sheet body, so a test measures it directly rather than inferring
/// the layout from a screenshot - the shape `pinnedMessagesBodyBoxKey` uses.
const editHistoryBodyBoxKey = Key('edit_history_body_box');

/// Opens the edit-history sheet for one message.
Future<void> showMessageEditHistorySheet(
  BuildContext context,
  String channelId,
  String messageId,
) {
  return showAppSheet<void>(
    context,
    maxWidth: 560,
    scrolls: true,
    builder: (context) =>
        _EditHistorySheet(channelId: channelId, messageId: messageId),
  );
}

class _EditHistorySheet extends ConsumerWidget {
  const _EditHistorySheet({required this.channelId, required this.messageId});

  final String channelId;
  final String messageId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final history = ref.watch(
      messageEditHistoryProvider((channelId: channelId, messageId: messageId)),
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.s16,
            0,
            AppSpacing.s16,
            AppSpacing.s12,
          ),
          child: Row(
            children: [
              Icon(
                AppIcons.activityLog,
                size: AppSizes.icon16,
                color: tokens.textSecondary,
              ),
              const SizedBox(width: AppSpacing.s8),
              Text(
                'Edit history',
                style: AppText.body.copyWith(
                  color: tokens.textPrimary,
                  fontWeight: AppWeights.semi,
                ),
              ),
            ],
          ),
        ),
        Flexible(
          child: KeyedSubtree(
            key: editHistoryBodyBoxKey,
            child: AppAsyncView<List<api.MessageRevision>>(
              value: AppAsyncState(
                data: history.valueOrNull,
                // Cleared while loading so a retry (reloaded with the error retained) shows the spinner, not a frozen banner.
                error: history.isLoading ? null : history.error,
              ),
              errorMessage: 'Could not load edit history.',
              onRetry: () => ref.invalidate(
                messageEditHistoryProvider((
                  channelId: channelId,
                  messageId: messageId,
                )),
              ),
              isEmpty: (versions) => versions.isEmpty,
              emptyMessage: 'This message has no recorded history.',
              data: (context, versions) => _Versions(versions: versions),
            ),
          ),
        ),
      ],
    );
  }
}

class _Versions extends ConsumerWidget {
  const _Versions({required this.versions});

  final List<api.MessageRevision> versions;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final use24Hour = watchUse24Hour(ref, context);
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.s16,
        0,
        AppSpacing.s16,
        AppSpacing.s16,
      ),
      shrinkWrap: true,
      itemCount: versions.length,
      separatorBuilder: (_, __) => const Divider(height: AppSpacing.s24),
      itemBuilder: (context, i) => _VersionTile(
        version: versions[i],
        previous: i == 0 ? null : versions[i - 1],
        label: _label(i, versions.length),
        ordinal: _ordinal(i, versions.length),
        use24Hour: use24Hour,
      ),
    );
  }

  static String _label(int index, int count) {
    // Last first, so a single-element list reads as the current content it is, not a lone "Original".
    if (index == count - 1) return 'Current';
    if (index == 0) return 'Original';
    return 'Edited';
  }

  /// Only shown once there is real order to lose: with two versions,
  /// "Original" and "Current" already say which is which, and a third badge
  /// is noise. With three or more, the middle rows are all "Edited" and this
  /// is the only thing distinguishing them.
  static String? _ordinal(int index, int count) =>
      count > 2 ? '${index + 1} of $count' : null;
}

class _VersionTile extends StatefulWidget {
  const _VersionTile({
    required this.version,
    required this.previous,
    required this.label,
    required this.ordinal,
    required this.use24Hour,
  });

  final api.MessageRevision version;

  /// The version immediately before this one, or null for the first entry -
  /// which then renders plainly, with nothing yet to diff against.
  final api.MessageRevision? previous;
  final String label;
  final String? ordinal;
  final bool use24Hour;

  @override
  State<_VersionTile> createState() => _VersionTileState();
}

class _VersionTileState extends State<_VersionTile> {
  late List<DiffBlock> _blocks = _diff();

  List<DiffBlock> _diff() => widget.previous == null
      ? plainBlocks(widget.version.content)
      : diffMessage(widget.previous!.content, widget.version.content);

  @override
  void didUpdateWidget(_VersionTile old) {
    super.didUpdateWidget(old);
    if (old.version.content != widget.version.content ||
        old.previous?.content != widget.previous?.content) {
      _blocks = _diff();
    }
  }

  @override
  Widget build(BuildContext context) {
    final version = widget.version;
    final label = widget.label;
    final ordinal = widget.ordinal;
    final blocks = _blocks;
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final when =
        '${formatMessageDay(version.at)} at '
        '${formatMessageTime(version.at, use24Hour: widget.use24Hour)}';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              label,
              style: AppText.caption.copyWith(
                color: tokens.textPrimary,
                fontWeight: AppWeights.semi,
              ),
            ),
            if (ordinal != null) ...[
              const SizedBox(width: AppSpacing.s8),
              Text(
                ordinal,
                style: AppText.micro.copyWith(color: tokens.textSecondary),
              ),
            ],
            const SizedBox(width: AppSpacing.s8),
            Expanded(
              child: Align(
                alignment: Alignment.centerRight,
                child: Text(
                  when,
                  style: AppText.micro.copyWith(color: tokens.textSecondary),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.s8),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(AppSpacing.s12),
          decoration: BoxDecoration(
            color: tokens.surfaceSunken,
            border: Border.all(color: tokens.borderSubtle),
            borderRadius: BorderRadius.circular(AppRadii.card),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var i = 0; i < blocks.length; i++) ...[
                if (i > 0) const SizedBox(height: AppSpacing.s4),
                _buildDiffBlock(blocks[i], tokens),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

Widget _buildDiffBlock(DiffBlock block, AppTokens tokens) => switch (block) {
  DiffTextBlock() => _DiffText(block: block, tokens: tokens),
  DiffCodeBlock() => _DiffCode(block: block, tokens: tokens),
};

class _DiffText extends StatelessWidget {
  const _DiffText({required this.block, required this.tokens});

  final DiffTextBlock block;
  final AppTokens tokens;

  @override
  Widget build(BuildContext context) {
    return SelectableText.rich(
      TextSpan(
        children: [
          for (final span in block.spans)
            TextSpan(text: span.text, style: _spanStyle(span.kind, tokens)),
        ],
      ),
    );
  }
}

/// Additions and removals are marked by decoration and weight, not colour
/// alone: strikethrough versus underline is a shape difference that survives
/// full desaturation, the same rule `#1292` pinned for the rail's mention dot.
/// Colour only reinforces the two states here, it never carries them alone.
TextStyle _spanStyle(DiffKind kind, AppTokens tokens) => switch (kind) {
  DiffKind.equal => AppText.body.copyWith(color: tokens.textPrimary),
  DiffKind.added => AppText.body.copyWith(
    color: tokens.textPrimary,
    fontWeight: AppWeights.semi,
    decoration: TextDecoration.underline,
    decorationColor: tokens.textPrimary,
  ),
  DiffKind.removed => AppText.body.copyWith(
    color: tokens.textSecondary,
    decoration: TextDecoration.lineThrough,
    decorationColor: tokens.textSecondary,
  ),
};

class _DiffCode extends StatelessWidget {
  const _DiffCode({required this.block, required this.tokens});

  final DiffCodeBlock block;
  final AppTokens tokens;

  @override
  Widget build(BuildContext context) {
    final rendered = AppCodeBlock(
      lines: lexCodeBlock(block.code, block.language),
      language: block.language,
    );
    if (block.kind == DiffKind.equal) return rendered;

    final removed = block.kind == DiffKind.removed;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          removed ? 'Removed' : 'Added',
          style: AppText.micro.copyWith(
            color: removed ? tokens.textSecondary : tokens.textPrimary,
            fontWeight: AppWeights.semi,
            decoration: removed
                ? TextDecoration.lineThrough
                : TextDecoration.underline,
          ),
        ),
        const SizedBox(height: AppSpacing.s4),
        Opacity(opacity: removed ? 0.7 : 1, child: rendered),
      ],
    );
  }
}
