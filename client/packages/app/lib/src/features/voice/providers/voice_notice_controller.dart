// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Shows the server's `voice.notice` frames (decision 0107): a banner while the app is in front,
/// an OS notification on a desktop whose window is not.
///
/// The server already applied the opt-in, the time limit and every exclusion, so this only
/// decides where to show it. A phone in the background is woken by the push instead.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_platform/platform.dart';

import '../../accounts/providers/account_slot.dart';
import '../../accounts/providers/notification_target.dart';
import '../../members/providers/member_presence.dart';
import '../../../providers/live_events.dart';
import '../../../providers/providers.dart';
import '../../../push/providers/push_controller.dart';

/// How long the banner stays up unless it is answered.
const voiceNoticeBannerDuration = Duration(seconds: 12);

/// What the banner and the notification say.
String voiceNoticeText(
  api.VoiceActivity activity,
  String actor,
  String channel,
) => switch (activity) {
  api.VoiceActivity.callStarted => '$actor started a call in #$channel',
  api.VoiceActivity.joined => '$actor joined #$channel',
  api.VoiceActivity.streaming => '$actor is streaming in #$channel',
};

class VoiceNoticeItem {
  const VoiceNoticeItem({required this.channelId, required this.text});

  final String channelId;
  final String text;
}

class VoiceNoticeController extends StateNotifier<VoiceNoticeItem?> {
  VoiceNoticeController(this._ref) : super(null) {
    _sub = _ref.read(liveEventsProvider).listen(_onEvent);
  }

  final Ref _ref;
  late final StreamSubscription<api.ServerEvent> _sub;
  Timer? _timer;

  void _onEvent(api.ServerEvent event) {
    if (event is api.VoiceNotice) unawaited(_show(event));
  }

  Future<void> _show(api.VoiceNotice notice) async {
    final text = await _textFor(notice);
    if (!mounted) return;
    final foreground =
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed &&
        _ref.read(accountActiveProvider);
    if (foreground) {
      _timer?.cancel();
      state = VoiceNoticeItem(channelId: notice.channelId, text: text);
      _timer = Timer(voiceNoticeBannerDuration, dismiss);
    } else if (isDesktopHost) {
      _notifyDesktop(notice.channelId, text);
    }
  }

  Future<String> _textFor(api.VoiceNotice notice) async {
    var actor = 'Someone';
    var channel = 'voice';
    try {
      final members = await _ref.read(membersProvider.future);
      final match = members.where((m) => m.id == notice.actorId);
      if (match.isNotEmpty) actor = match.first.displayName;
      final row = await (await _ref.read(
        storeProvider.future,
      )).channelRow(notice.channelId);
      if (row != null) channel = row.name;
    } catch (error, stack) {
      api.AppLog.swallowed(
        api.LogTag.ui,
        'A voice notice could not name who or where; showing it plainly',
        error,
        stack,
      );
    }
    return voiceNoticeText(notice.activity, actor, channel);
  }

  void _notifyDesktop(String channelId, String text) {
    final origin = _ref.read(accountSlotProvider)?.account?.origin;
    final payload = origin == null
        ? null
        : NotificationTarget(origin: origin, channelId: channelId).encode();
    // Fire-and-forget: a failed notification must never break event handling.
    unawaited(
      _ref
          .read(localNotificationsProvider)
          .show(text, channel: LocalAlertChannel.voice, payload: payload),
    );
  }

  void dismiss() {
    _timer?.cancel();
    if (mounted) state = null;
  }

  @override
  void dispose() {
    _timer?.cancel();
    unawaited(_sub.cancel());
    super.dispose();
  }
}

final voiceNoticeProvider =
    StateNotifierProvider<VoiceNoticeController, VoiceNoticeItem?>(
      (ref) => VoiceNoticeController(ref),
    );
