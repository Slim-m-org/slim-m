// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The running call's transcript, newest line at the bottom (decision 0113):
/// it follows what is said until the reader scrolls up, then offers a way back.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../messages/widgets/jump_to_latest_button.dart';
import '../providers/call_transcript.dart';
import 'transcript_line_row.dart';

const liveTranscriptJumpKey = Key('live-transcript-jump');

/// How far from the end still counts as following the newest line.
const _followSlack = 24.0;

class LiveTranscriptView extends ConsumerStatefulWidget {
  const LiveTranscriptView({super.key, required this.transcriptId});

  final String transcriptId;

  @override
  ConsumerState<LiveTranscriptView> createState() => _LiveTranscriptViewState();
}

class _LiveTranscriptViewState extends ConsumerState<LiveTranscriptView> {
  final _scroll = ScrollController();
  bool _following = true;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    unawaited(Future<void>.microtask(_readOn));
  }

  /// The pane shows the whole call, so it reads on past the first page.
  void _readOn() {
    if (!mounted) return;
    final model = ref.read(callTranscriptProvider(widget.transcriptId));
    if (!model.loaded || !model.hasMore || model.busy || model.error != null) {
      return;
    }
    unawaited(
      ref.read(callTranscriptProvider(widget.transcriptId).notifier).loadMore(),
    );
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final position = _scroll.position;
    final following =
        position.maxScrollExtent - position.pixels <= _followSlack;
    if (following != _following) setState(() => _following = following);
  }

  void _toEnd({bool animate = false}) {
    if (!_scroll.hasClients) return;
    final end = _scroll.position.maxScrollExtent;
    if (animate && !MediaQuery.disableAnimationsOf(context)) {
      unawaited(
        _scroll.animateTo(
          end,
          duration: AppMotion.base,
          curve: AppMotion.entrance,
        ),
      );
    } else {
      _scroll.jumpTo(end);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final model = ref.watch(callTranscriptProvider(widget.transcriptId));
    ref.listen(
      callTranscriptProvider(widget.transcriptId).select((m) => m.busy),
      (_, busy) {
        if (!busy) unawaited(Future<void>.microtask(_readOn));
      },
    );
    ref.listen(
      callTranscriptProvider(widget.transcriptId).select((m) => m.lines.length),
      (_, _) {
        if (!_following) return;
        WidgetsBinding.instance.addPostFrameCallback((_) => _toEnd());
      },
    );
    if (model.error != null && model.lines.isEmpty) {
      return AppErrorState(
        message: model.error!,
        onRetry: () => ref
            .read(callTranscriptProvider(widget.transcriptId).notifier)
            .loadMore(),
      );
    }
    if (model.loaded && model.lines.isEmpty) {
      return Center(
        child: Text(
          'Nothing said yet.',
          style: AppText.caption.copyWith(color: tokens.textSecondary),
        ),
      );
    }
    return Stack(
      children: [
        ListView.builder(
          controller: _scroll,
          padding: const EdgeInsets.all(AppSpacing.s16),
          itemCount: model.lines.length,
          itemBuilder: (context, i) => TranscriptLineRow(
            key: ValueKey(model.lines[i].seq),
            line: model.lines[i],
            highlighted: false,
          ),
        ),
        Align(
          alignment: Alignment.bottomCenter,
          child: JumpToLatestButton(
            key: liveTranscriptJumpKey,
            visible: !_following,
            onTap: () => _toEnd(animate: true),
          ),
        ),
      ],
    );
  }
}
