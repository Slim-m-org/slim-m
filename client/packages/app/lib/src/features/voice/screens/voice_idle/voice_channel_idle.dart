// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A voice channel while you are not in its call (design 13, decision
/// 0066): a join bar, then the latest call's record - who was in when, what
/// happened, so far if it is still going - and the calls before it. A channel
/// with nothing to look back on gets a centred empty state instead.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../providers/voice_call_history.dart';
import '../../../../routing/breakpoints.dart';
import '../../providers/call_recap.dart';
import '../../widgets/call_recap_card.dart';
import '../voice_text_pane.dart' show voiceChatPaneVisibleProvider;
import 'call_details_sections.dart';
import 'voice_channel_empty.dart';
import 'voice_join_bar.dart';

/// How long a loading history holds the empty state back, so a fast load never flashes it.
const voiceHistoryLoadingGrace = Duration(milliseconds: 250);

class VoiceChannelIdle extends ConsumerWidget {
  const VoiceChannelIdle({
    super.key,
    required this.channelId,
    required this.onJoin,
    required this.onOpenCanvas,
    this.onJoinWithMic,
    this.onRetry,
    this.errorMessage,
    this.canRetry = true,
    this.recap,
    this.clock,
  });

  final String channelId;

  /// Joins muted; the join bar's primary button.
  final VoidCallback onJoin;

  /// Joins with the mic as the person left it, offered beside [onJoin].
  final VoidCallback? onJoinWithMic;

  /// Repeats a failed join in the mic mode it used; null retries with [onJoin].
  final VoidCallback? onRetry;
  final VoidCallback onOpenCanvas;
  final String? errorMessage;
  final bool canRetry;

  /// The call this device just hung up here, shown above the join bar.
  final CallRecap? recap;

  /// Now, in epoch milliseconds; a test pins it.
  final int Function()? clock;

  static List<api.VoiceCall> _finishedCalls(List<api.VoiceCall>? calls) => [
    for (final call in calls ?? const <api.VoiceCall>[])
      if (!call.ongoing) call,
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final compact = LayoutClass.of(context) == LayoutClass.compact;
    final now = (clock ?? () => DateTime.now().millisecondsSinceEpoch)();
    final history = ref.watch(voiceCallHistoryProvider(channelId));
    // Newest first, so a call still going (someone stayed after you left) leads.
    final calls = history.valueOrNull?.calls ?? const <api.VoiceCall>[];
    final finished = _finishedCalls(calls);
    final ended = recap;
    final recapShown = ended != null && ended.isWorthShowing;
    // After a short grace the empty state stands in while the history loads, so Join is never held back long.
    if (calls.isEmpty && !recapShown) {
      return _LoadingGrace(
        loading: !history.hasValue && !history.hasError,
        child: VoiceChannelEmpty(
          channelId: channelId,
          rejoin: ended != null,
          onJoinMuted: onJoin,
          onJoin: onJoinWithMic,
          onRetry: onRetry,
          errorMessage: errorMessage,
          canRetry: canRetry,
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        padding: EdgeInsets.all(compact ? AppSpacing.s16 : AppSpacing.s24),
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 880),
            child: CallDetailsSections(
              channelId: channelId,
              now: now,
              compact: compact,
              onOpenCanvas: onOpenCanvas,
              // A search hit's arrival opened the chat; the call it named shows here instead.
              onFocus: () =>
                  ref.read(voiceChatPaneVisibleProvider.notifier).state = false,
              lead: [
                if (recapShown)
                  CallRecapCard(recap: ended, title: 'Call ended'),
                VoiceJoinBar(
                  rejoin: ended != null,
                  channelId: channelId,
                  compact: compact,
                  lastCallAt: finished.isEmpty ? null : finished.first.endedAt,
                  now: now,
                  onJoin: errorMessage == null ? onJoin : onRetry ?? onJoin,
                  onJoinWithMic: onJoinWithMic,
                  errorMessage: errorMessage,
                  canRetry: canRetry,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Holds [child] back for [voiceHistoryLoadingGrace] while [loading], then
/// fades it in; a [child] that mounts already loaded shows at once.
class _LoadingGrace extends StatefulWidget {
  const _LoadingGrace({required this.loading, required this.child});

  final bool loading;
  final Widget child;

  @override
  State<_LoadingGrace> createState() => _LoadingGraceState();
}

class _LoadingGraceState extends State<_LoadingGrace> {
  late final bool _waited;
  late bool _held;
  Timer? _grace;

  @override
  void initState() {
    super.initState();
    _waited = _held = widget.loading;
    if (_held) {
      _grace = Timer(voiceHistoryLoadingGrace, () => setState(_release));
    }
  }

  @override
  void didUpdateWidget(_LoadingGrace oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.loading) _release();
  }

  void _release() {
    _grace?.cancel();
    _held = false;
  }

  @override
  void dispose() {
    _grace?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_held) return const SizedBox.shrink();
    return _waited ? AppFadeIn(child: widget.child) : widget.child;
  }
}
