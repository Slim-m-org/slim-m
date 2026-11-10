// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The second half of "Share to": the conversations the share may go to.
///
/// Picking one does not send. It saves any shared text as that conversation's
/// draft and hands the files to its composer, which stages them once it is on
/// screen; the person reads it over and sends.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../routing/routes.dart';
import '../../channels/providers/channel_drafts.dart';
import '../../messages/providers/forward_targets.dart';
import '../../messages/widgets/destination_picker.dart';
import '../providers/incoming_share.dart';
import 'share_summary.dart';

/// Which text a draft holds once [shared] joins what was already there.
String draftWithShared(String existing, String shared) =>
    existing.trim().isEmpty ? shared : '$existing\n$shared';

class ShareDestinationStep extends ConsumerStatefulWidget {
  const ShareDestinationStep({super.key, required this.share});

  final IncomingShare share;

  static const searchKey = Key('share_search');

  @override
  ConsumerState<ShareDestinationStep> createState() =>
      _ShareDestinationStepState();
}

class _ShareDestinationStepState extends ConsumerState<ShareDestinationStep> {
  String _search = '';

  Future<void> _pick(ForwardTarget target) async {
    final share = widget.share;
    final text = share.text;
    if (text != null) {
      final drafts = ref.read(channelDraftsProvider);
      await drafts.restored;
      drafts.save(
        target.channelId,
        draftWithShared(drafts.draftFor(target.channelId), text),
      );
    }
    if (!mounted) return;
    if (share.hasFiles || share.unreadable > 0) {
      ref.read(shareHandoffProvider.notifier).state = (
        channelId: target.channelId,
        share: share,
      );
    }
    // Cleared before leaving: the router sends the person back here while a share is pending.
    ref.read(pendingShareProvider.notifier).state = null;
    context.go(Routes.channel(target.channelId, openChat: target.isVoice));
  }

  @override
  Widget build(BuildContext context) {
    final ForwardTargetsQuery query = (
      excludeChannelId: '',
      hasAttachments: widget.share.hasFiles,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(AppSpacing.s16),
          child: ShareSummary(share: widget.share),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s16),
          child: DestinationSearchField(
            key: ShareDestinationStep.searchKey,
            onChanged: (value) => setState(() => _search = value),
            semanticLabel: 'Search where to share this',
          ),
        ),
        const SizedBox(height: AppSpacing.s8),
        Expanded(
          child: DestinationList(
            query: query,
            search: _search,
            onPick: (target) => unawaited(_pick(target)),
            errorMessage: 'Could not load where you can share this.',
            emptyMessage: 'Nowhere to share this to yet.',
          ),
        ),
      ],
    );
  }
}
