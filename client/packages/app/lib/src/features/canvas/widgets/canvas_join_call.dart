// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Joins a canvas channel's call from its bar and stays on the board.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../widgets/confirm_dialog.dart';
import '../../channels/providers/channel_by_id_provider.dart';
import '../../voice/providers/voice_controller.dart';
import '../../voice/providers/voice_flags.dart';
import '../../voice/providers/voice_roster.dart';
import '../../voice/widgets/confirmed_join.dart';

/// Whether [channelId] is a canvas channel hosting a call this device is not in, so its bar offers to join it.
final canvasJoinCallOfferedProvider = Provider.autoDispose.family<bool, String>(
  (ref, channelId) {
    final hosts = ref.watch(
      channelByIdProvider(channelId).select((c) {
        final row = c.valueOrNull;
        return row != null && row.isCanvasChannel && row.hostsCall;
      }),
    );
    return hosts &&
        !ref.watch(
          voiceFlagsProvider.select((voice) => voice.inCallStageFor(channelId)),
        );
  },
);

/// The bar's Join call: a labelled button at pointer widths, a touch-sized icon below [compact].
class CanvasJoinCall extends ConsumerStatefulWidget {
  const CanvasJoinCall({
    super.key,
    required this.channelId,
    this.compact = false,
  });

  final String channelId;
  final bool compact;

  @override
  ConsumerState<CanvasJoinCall> createState() => _CanvasJoinCallState();
}

class _CanvasJoinCallState extends ConsumerState<CanvasJoinCall> {
  bool _checking = false;
  int _check = 0;

  Future<void> _press() async {
    final channelId = widget.channelId;
    final controller = ref.read(voiceControllerProvider.notifier);
    Future<void> join() => controller.join(channelId);
    if (callBusyElsewhere(ref.read(voiceFlagsProvider), channelId)) {
      final switching = await confirmChoice(
        context,
        title: switchCallTitle,
        message: switchCallMessage,
        confirmLabel: switchCallConfirm,
      );
      if (switching && mounted) await join();
      return;
    }
    final check = ++_check;
    await runConfirmedJoin(
      context,
      ref,
      channelId: channelId,
      isDm: false,
      join: join,
      host: ConfirmedJoinHost(
        dropped: () => !mounted || check != _check,
        checking: (checking) => setState(() => _checking = checking),
        askJoinHere: (elsewhere, proceed) =>
            unawaited(_askJoinHere(elsewhere, proceed)),
      ),
    );
    _announceJoined();
  }

  Future<void> _askJoinHere(String elsewhere, VoidCallback proceed) async {
    final name = ref.read(channelByIdProvider(elsewhere)).valueOrNull?.name;
    final here = await confirmChoice(
      context,
      title: joinHereTitle,
      message: joinHereMessage(name),
      confirmLabel: joinHereConfirm,
    );
    if (here && mounted) proceed();
  }

  void _announceJoined() {
    if (!mounted ||
        !ref.read(voiceFlagsProvider).inCallStageFor(widget.channelId)) {
      return;
    }
    final view = View.maybeOf(context);
    if (view == null) return;
    final direction = Directionality.maybeOf(context) ?? TextDirection.ltr;
    unawaited(
      SemanticsService.sendAnnouncement(view, 'Joined the call', direction),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!ref.watch(canvasJoinCallOfferedProvider(widget.channelId))) {
      return const SizedBox.shrink();
    }
    final inCall =
        ref.watch(voiceRosterProvider(widget.channelId)).valueOrNull?.length ??
        0;
    final label = inCall > 0 ? 'Join call, $inCall in the call' : 'Join call';
    if (widget.compact) {
      return AppIconButton(
        icon: AppIcons.startCall,
        semanticLabel: label,
        tooltip: 'Join call',
        size: AppIconButtonSize.touch,
        busy: _checking,
        onPressed: _checking ? null : _press,
      );
    }
    return AppButton(
      label: 'Join call',
      semanticLabel: label,
      icon: AppIcons.startCall,
      variant: AppButtonVariant.soft,
      size: AppButtonSize.sm,
      busy: _checking,
      onPressed: _checking ? null : _press,
    );
  }
}
