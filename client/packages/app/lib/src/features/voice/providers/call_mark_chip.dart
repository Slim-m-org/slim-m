// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The short-lived chip in a call's header that says a moment was just marked,
/// or why it was not. Fed by `call.transcript_mark`, which only reaches the
/// people in the call who may read the transcript, and by this device's own
/// mark action.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import '../../../providers/live_events.dart';

/// How long the chip stays.
const callMarkChipFor = Duration(seconds: 5);

/// A kept mark by [authorId], or a [notice] when nothing was marked.
class CallMarkChip {
  const CallMarkChip.mark({required String this.authorId, required this.note})
    : notice = null;

  const CallMarkChip.notice(String this.notice) : authorId = null, note = false;

  final String? authorId;
  final bool note;
  final String? notice;
}

class CallMarkChipController
    extends AutoDisposeFamilyNotifier<CallMarkChip?, String> {
  late String channelId;
  Timer? _clear;

  @override
  CallMarkChip? build(String arg) {
    channelId = arg;
    final events = ref.read(liveEventsProvider).listen(_onEvent);
    ref.onDispose(() {
      _clear?.cancel();
      unawaited(events.cancel());
    });
    return null;
  }

  void _onEvent(api.ServerEvent event) {
    if (event case api.CallTranscriptMarkChanged(
      :final channelId,
      :final mark?,
    ) when channelId == this.channelId) {
      shown(mark);
    }
  }

  /// Says [mark] was kept.
  void shown(api.TranscriptMark mark) => _show(
    CallMarkChip.mark(
      authorId: mark.authorId,
      note: mark.kind == api.TranscriptMarkKind.note,
    ),
  );

  /// Says why nothing was marked.
  void notice(String text) => _show(CallMarkChip.notice(text));

  void _show(CallMarkChip chip) {
    _clear?.cancel();
    state = chip;
    _clear = Timer(callMarkChipFor, () => state = null);
  }
}

final callMarkChipProvider = NotifierProvider.autoDispose
    .family<CallMarkChipController, CallMarkChip?, String>(
      CallMarkChipController.new,
    );
