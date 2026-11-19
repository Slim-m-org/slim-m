// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A call's details while you are in it: the idle page's record of the
/// channel's calls (`CallDetailsSections`), live as the call goes on.
///
/// Docked beside the stage where `LayoutClass.fitsThreadPane` has room, in
/// the slot the call's chat uses (`voice_text_pane.dart`); narrower, a sheet
/// over the call (desktop-vs-mobile.md rule 3), as the canvas's chat does.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../../routing/breakpoints.dart';
import '../../canvas/screens/canvas_pane.dart' show canvasOpenProvider;
import '../providers/voice_call_history.dart';
import 'voice_idle/call_details_sections.dart';

/// How often an open panel moves a call still going up to now.
const callDetailsNowRefresh = Duration(seconds: 30);

const callDetailsPanelKey = Key('call-details-panel');
const callDetailsSheetKey = Key('call-details-sheet');

/// Whether this width docks the details beside the call instead of sheeting them.
bool callDetailsDocks(BuildContext context) =>
    LayoutClass.of(context).fitsThreadPane(MediaQuery.sizeOf(context).width);

/// The details over the call, for a width with no room to dock them.
Future<void> showCallDetailsSheet(BuildContext context, String channelId) =>
    showAppSheet<void>(
      context,
      scrolls: true,
      semanticLabel: 'Call details',
      builder: (context) => ConstrainedBox(
        key: callDetailsSheetKey,
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.8,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const AppSheetHeader('Call details'),
            Flexible(
              child: _CallDetailsBody(channelId: channelId, inSheet: true),
            ),
          ],
        ),
      ),
    );

/// The docked panel's content, beside the stage.
class CallDetailsPanel extends StatelessWidget {
  const CallDetailsPanel({super.key, required this.channelId});

  final String channelId;

  @override
  Widget build(BuildContext context) => Semantics(
    key: callDetailsPanelKey,
    container: true,
    explicitChildNodes: true,
    label: 'Call details',
    child: _CallDetailsBody(channelId: channelId, inSheet: false),
  );
}

class _CallDetailsBody extends ConsumerStatefulWidget {
  const _CallDetailsBody({required this.channelId, required this.inSheet});

  final String channelId;
  final bool inSheet;

  @override
  ConsumerState<_CallDetailsBody> createState() => _CallDetailsBodyState();
}

class _CallDetailsBodyState extends ConsumerState<_CallDetailsBody> {
  late final Timer _refresh;

  @override
  void initState() {
    super.initState();
    _refresh = Timer.periodic(callDetailsNowRefresh, (_) => setState(() {}));
  }

  @override
  void dispose() {
    _refresh.cancel();
    super.dispose();
  }

  void _openCanvas() {
    if (widget.inSheet) Navigator.of(context).pop();
    ref.read(canvasOpenProvider.notifier).state = widget.channelId;
  }

  @override
  Widget build(BuildContext context) {
    final channelId = widget.channelId;
    final history = ref.watch(voiceCallHistoryProvider(channelId));
    final calls = history.valueOrNull?.calls ?? const <api.VoiceCall>[];
    if (calls.isEmpty) {
      final placeholder = _Placeholder(
        loading: !history.hasValue && !history.hasError,
        failed: history.hasError,
        onRetry: () => ref.invalidate(voiceCallHistoryProvider(channelId)),
      );
      // A sheet is as tall as what it holds; the panel has its whole height to centre in.
      return Center(
        heightFactor: widget.inSheet ? 1 : null,
        child: placeholder,
      );
    }
    return SingleChildScrollView(
      padding: widget.inSheet
          ? const EdgeInsets.fromLTRB(
              AppSpacing.s16,
              0,
              AppSpacing.s16,
              AppSpacing.s16,
            )
          : const EdgeInsets.all(AppSpacing.s16),
      child: CallDetailsSections(
        channelId: channelId,
        now: DateTime.now().millisecondsSinceEpoch,
        compact: true,
        onOpenCanvas: _openCanvas,
      ),
    );
  }
}

/// Loading, a failed load, or a call nothing has been recorded for yet.
class _Placeholder extends StatelessWidget {
  const _Placeholder({
    required this.loading,
    required this.failed,
    required this.onRetry,
  });

  final bool loading;
  final bool failed;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    if (loading) return const AppSpinner(size: AppSpinnerSize.md);
    if (failed) {
      return Padding(
        padding: const EdgeInsets.all(AppSpacing.s16),
        child: AppErrorState(
          message: 'Could not load the call history.',
          onRetry: onRetry,
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.s24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            AppIcons.activityLog,
            size: AppSizes.icon24,
            color: tokens.textSecondary,
          ),
          const SizedBox(height: AppSpacing.s12),
          Text(
            'Nothing recorded yet',
            textAlign: TextAlign.center,
            style: AppText.body.copyWith(
              color: tokens.textPrimary,
              fontWeight: AppWeights.semi,
            ),
          ),
          const SizedBox(height: AppSpacing.s4),
          Text(
            'Who joins, what is shared and what is said show up here.',
            textAlign: TextAlign.center,
            style: AppText.caption.copyWith(color: tokens.textSecondary),
          ),
        ],
      ),
    );
  }
}
