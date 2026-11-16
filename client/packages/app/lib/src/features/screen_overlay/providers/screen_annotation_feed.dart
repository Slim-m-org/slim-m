// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What a viewer knows about annotating other people's shared screens: who
/// allows it, and the marks everyone has drawn lately.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import '../../../providers/sync_controller.dart';
import '../../members/providers/blocks_controller.dart';
import '../../voice/providers/voice_flags.dart';
import 'screen_annotation_board.dart';
import 'screen_annotation_call.dart';
import 'screen_annotation_consent.dart';

bool _nobody(String userId) => false;

class ScreenAnnotationFeed extends ChangeNotifier {
  ScreenAnnotationFeed({
    required String? Function() selfId,
    required String? Function() callChannelId,
    required Iterable<String> Function() callMembers,
    bool Function(String userId)? isBlocked,
    DateTime Function()? clock,
  }) : _selfId = selfId,
       _callChannelId = callChannelId,
       _callMembers = callMembers,
       _isBlocked = isBlocked ?? _nobody,
       _clock = clock ?? annotationNow;

  final String? Function() _selfId;
  final String? Function() _callChannelId;
  final Iterable<String> Function() _callMembers;
  final bool Function(String userId) _isBlocked;
  final DateTime Function() _clock;
  final _consent = ScreenAnnotationConsent();
  final Map<String, ScreenAnnotationBoard> _boards = {};

  /// Folds in a frame from the socket. A mark counts only between two people
  /// in my call, and the relay's echo of my own marks is skipped.
  void handle(api.ServerEvent event) {
    if (event is! api.CanvasScreenAnnotation) return;
    if (event.kind != 'consent' && !_acceptsMark(event)) return;
    _fold(event);
  }

  bool _acceptsMark(api.CanvasScreenAnnotation mark) =>
      mark.userId != _selfId() &&
      !_isBlocked(mark.userId) &&
      markInCall(
        mark,
        callChannelId: _callChannelId(),
        callMembers: _callMembers(),
      );

  /// A mark this viewer is drawing, shown at once rather than after the round trip.
  void applyLocal(api.CanvasScreenAnnotation frame) => _fold(frame);

  void _fold(api.CanvasScreenAnnotation frame) {
    final now = _clock();
    if (frame.kind == 'consent') {
      _consent.apply(frame, now);
    } else if (!_applyMark(frame, now)) {
      return;
    }
    _boards.removeWhere((_, board) => board.pruneAt(now));
    notifyListeners();
  }

  /// A board exists only for my own screen or a sharer who allowed drawing, so a relayed mark aimed at anyone else costs nothing.
  bool _applyMark(api.CanvasScreenAnnotation frame, DateTime now) {
    final target = frame.targetUserId;
    var board = _boards[target];
    if (board == null) {
      final allowed = target == _selfId() || _consent.of(target, now) != null;
      if (!allowed) return false;
      board = _boards[target] = ScreenAnnotationBoard();
    }
    board.apply(frame, now);
    return true;
  }

  /// The sharer's live consent, or null when they have not allowed drawing.
  SharerConsent? consentFor(String sharerId) => _consent.of(sharerId, _clock());

  /// The marks still visible over [sharerId]'s screen.
  List<ScreenAnnotation> marksFor(String sharerId) =>
      _boards[sharerId]?.liveAt(_clock()) ?? const [];

  DateTime get now => _clock();

  @visibleForTesting
  int get boardCount => _boards.length;
}

final screenAnnotationFeedProvider = Provider<ScreenAnnotationFeed>((ref) {
  final feed = ScreenAnnotationFeed(
    selfId: () => ref
        .read(voiceParticipantsProvider)
        .where((p) => p.isLocal)
        .firstOrNull
        ?.identity,
    callChannelId: () => ref.read(voiceFlagsProvider).channelId,
    callMembers: () =>
        ref.read(voiceParticipantsProvider).map((p) => p.identity),
    isBlocked: (userId) => ref.read(blocksProvider).contains(userId),
  );
  final sub = ref
      .read(syncControllerProvider.notifier)
      .liveEvents
      .listen(feed.handle);
  ref.onDispose(() {
    sub.cancel();
    feed.dispose();
  });
  return feed;
});
