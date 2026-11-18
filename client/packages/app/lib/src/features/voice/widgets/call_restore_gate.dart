// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Brings back the call this device was in when the app went away: straight
/// back in after the app restarted itself, and after asking when it crashed.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../widgets/confirm_dialog.dart';
import '../providers/call_restore.dart';
import '../providers/voice_flags.dart';
import 'transcription_notice.dart';

const callRestoreRejoinKey = Key('call-restore-rejoin');
const callRestoreDismissKey = Key('call-restore-dismiss');

class CallRestoreGate extends ConsumerStatefulWidget {
  const CallRestoreGate({required this.child, super.key});

  final Widget child;

  @override
  ConsumerState<CallRestoreGate> createState() => _CallRestoreGateState();
}

class _CallRestoreGateState extends ConsumerState<CallRestoreGate> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_restore()));
  }

  Future<void> _restore() async {
    final found = await ref.read(callToRestoreProvider)();
    if (found == null || !mounted) return;
    final (:call, :channelName) = found;
    final rejoin = call.restart || await _askToRejoin(channelName);
    if (!mounted) return;
    await ref.read(answerCallToRestoreProvider)();
    if (!rejoin || !mounted) return;
    if (!await confirmTranscriptionNotice(context, ref)) return;
    if (!mounted || ref.read(voiceFlagsProvider).channelId != null) return;
    await ref.read(rejoinRestoredCallProvider)(call);
  }

  Future<bool> _askToRejoin(String channelName) => confirmChoice(
    context,
    title: 'Rejoin the call?',
    message: 'slim-m closed while you were in $channelName.',
    confirmLabel: 'Rejoin',
    cancelLabel: 'Not now',
    confirmKey: callRestoreRejoinKey,
    cancelKey: callRestoreDismissKey,
  );

  @override
  Widget build(BuildContext context) {
    ref.watch(callRestoreWatchProvider);
    return widget.child;
  }
}
