// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Brings back the call this device was in when the app went away: straight
/// back in after the app restarted itself, and after asking when it crashed.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../providers/call_restore.dart';
import '../providers/voice_controller.dart';
import '../providers/voice_flags.dart';

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
    if (!call.restart) {
      final rejoin = await showAppSheet<bool>(
        context,
        builder: (context) => _RejoinSheet(channelName: channelName),
      );
      if (rejoin != true || !mounted) return;
      if (ref.read(voiceFlagsProvider).channelId != null) return;
    }
    final voice = ref.read(voiceControllerProvider.notifier);
    await (call.muted
        ? voice.joinMuted(call.channelId)
        : voice.join(call.channelId));
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(callRestoreWatchProvider);
    return widget.child;
  }
}

class _RejoinSheet extends StatelessWidget {
  const _RejoinSheet({required this.channelName});

  final String channelName;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.s16,
        0,
        AppSpacing.s16,
        AppSpacing.s16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Rejoin the call?',
            style: AppText.body.copyWith(
              color: tokens.textPrimary,
              fontWeight: AppWeights.semi,
            ),
          ),
          const SizedBox(height: AppSpacing.s8),
          Text(
            'slim-m closed while you were in $channelName.',
            style: AppText.body.copyWith(color: tokens.textSecondary),
          ),
          const SizedBox(height: AppSpacing.s16),
          Row(
            children: [
              Expanded(
                child: AppButton(
                  key: callRestoreDismissKey,
                  label: 'Not now',
                  variant: AppButtonVariant.ghost,
                  onPressed: () => Navigator.of(context).pop(false),
                ),
              ),
              const SizedBox(width: AppSpacing.s8),
              Expanded(
                child: AppButton(
                  key: callRestoreRejoinKey,
                  label: 'Rejoin',
                  variant: AppButtonVariant.primary,
                  onPressed: () => Navigator.of(context).pop(true),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
