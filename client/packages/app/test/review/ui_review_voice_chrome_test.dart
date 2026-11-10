// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The voice chrome that lives outside the call stage: the collapsed call
/// strip on a phone (and its keyboard pill), the call stats screen, and the
/// banner that says someone started a call.
///
/// The strip exists only on a phone, so it writes the phone viewport only.
/// PNGs are written only under SLIMM_UI_SNAPSHOTS=1; otherwise this asserts
/// each one lays out without overflow.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/providers/voice_notice_controller.dart';
import 'package:slimm_app/src/features/voice/screens/call_stats_screen.dart';
import 'package:slimm_app/src/routing/modal_page.dart';
import 'package:slimm_rtc/rtc.dart';

import '../ui_snapshot_support.dart';
import 'ui_review_voice_support.dart';

VoiceState _call(List<VoiceParticipant> people) => VoiceState(
  channelId: 'c-main',
  state: VoiceSessionState.connected,
  connectedAt: callStartedAgo(),
  participants: people,
);

final _people = [
  reviewPerson('user-nick', 'Nick', local: true),
  reviewPerson('user-ada', 'Ada Lovelace', speaking: true),
  reviewPerson('user-grace', 'Grace Hopper', muted: true),
];

class _FixedStats extends CallStatsSampler {
  _FixedStats(this._samples) : super(targets: () => const []);

  final List<VideoStatsSample> _samples;

  @override
  CallStatsSnapshot get latest => _samples;

  @override
  Stream<CallStatsSnapshot> get snapshots => Stream.value(_samples);
}

class _FixedHealth extends VoiceHealth {
  _FixedHealth(this._windows);

  final List<NamedWindow> _windows;

  @override
  List<NamedWindow> recentWindows() => _windows;
}

NamedWindow _heard(
  String name, {
  double concealed = 0,
  double lost = 0,
  double jitter = 12,
}) => NamedWindow(
  name,
  HealthWindow(const Duration(seconds: 60))..add(
    HealthInterval(
      seconds: 60,
      samples: 1000,
      concealedSamples: concealed,
      lostPackets: lost,
      receivedPackets: 100 - lost,
      jitterMs: jitter,
      bufferMs: 40,
      rttMs: 42,
    ),
  ),
);

final _sending = NamedWindow(
  'You',
  HealthWindow(const Duration(seconds: 60))
    ..add(const HealthInterval(seconds: 60, kbps: 32.4, rttMs: 40)),
  local: true,
);

VideoStatsSample _share({bool poor = false}) => VideoStatsSample(
  identity: 'user-ada',
  name: 'Ada Lovelace',
  source: CallStatsSource.screenShare,
  local: false,
  streams: [
    VideoStreamStats(
      id: 'in-1',
      width: poor ? 1280 : 1920,
      height: poor ? 720 : 1080,
      fps: poor ? 11.2 : 59.6,
      bitrateBps: poor ? 900000 : 4200000,
      codec: 'VP8',
      implementation: 'libvpx',
      freezeCount: poor ? 9 : 0,
      freezeSeconds: poor ? 6.5 : 0,
      framesDropped: poor ? 212 : 3,
      jitterMs: poor ? 64 : 10,
    ),
  ],
  transport: TransportStats(
    rttMs: poor ? 310 : 42,
    localType: poor ? 'relay' : 'host',
    protocol: poor ? 'tcp' : 'udp',
  ),
);

const _camera = VideoStatsSample(
  identity: 'user-nick',
  name: 'Nick',
  source: CallStatsSource.camera,
  local: true,
  streams: [
    VideoStreamStats(
      id: 'out-1',
      rid: 'h',
      width: 1280,
      height: 720,
      fps: 30,
      bitrateBps: 1500000,
      targetBitrateBps: 1700000,
    ),
    VideoStreamStats(
      id: 'out-2',
      rid: 'q',
      width: 320,
      height: 180,
      fps: 15,
      bitrateBps: 150000,
      targetBitrateBps: 200000,
      limitationReason: 'bandwidth',
      limitationResolutionChanges: 3,
    ),
  ],
  transport: TransportStats(rttMs: 40, localType: 'host', protocol: 'udp'),
);

final _statsRoute = GoRoute(
  path: '/settings/call-stats',
  pageBuilder: (context, state) => modalPage(context, const CallStatsScreen()),
);

Future<void> _stats(
  WidgetTester tester, {
  required String state,
  required String viewport,
  required VoiceState call,
  List<NamedWindow> audio = const [],
  List<VideoStatsSample> video = const [],
}) => renderReview(
  tester,
  surface: 'settings-call-stats',
  state: state,
  viewport: viewport,
  route: '/settings/call-stats',
  modal: true,
  extraRoutes: [_statsRoute],
  overrides: [
    reviewVoice(
      call,
      session: ReviewVoiceSession()
        ..health = _FixedHealth(audio)
        ..callStats = _FixedStats(video),
    ),
  ],
);

void main() {
  setUpAll(loadRealFonts);

  testWidgets('call strip at phone', (tester) async {
    await renderReview(
      tester,
      surface: 'voice-strip-indicator',
      state: 'strip',
      viewport: 'phone',
      route: '/channels/c-general',
      overrides: [reviewVoice(_call(_people))],
    );
  });

  testWidgets('call strip with the keyboard up at phone', (tester) async {
    await renderReview(
      tester,
      surface: 'voice-strip-indicator',
      state: 'keyboard-pill',
      viewport: 'phone',
      route: '/channels/c-general',
      overrides: [reviewVoice(_call(_people))],
      step: (tester, _) async {
        addTearDown(tester.view.resetViewInsets);
        tester.view.viewInsets = const FakeViewPadding(bottom: 300);
        await reviewFrames(tester);
      },
    );
  });

  for (final viewport in reviewViewports) {
    testWidgets('call stats, no call, at $viewport', (tester) async {
      await _stats(
        tester,
        state: 'no-call',
        viewport: viewport,
        call: const VoiceState(),
      );
    });

    testWidgets('call stats, audio only, at $viewport', (tester) async {
      await _stats(
        tester,
        state: 'audio',
        viewport: viewport,
        call: _call(_people),
        audio: [_heard('Ada Lovelace'), _heard('Grace Hopper'), _sending],
      );
    });

    testWidgets('call stats, video, at $viewport', (tester) async {
      await _stats(
        tester,
        state: 'video',
        viewport: viewport,
        call: _call(_people),
        audio: [_heard('Ada Lovelace'), _sending],
        video: [_share(), _camera],
      );
    });

    testWidgets('call stats, poor connection, at $viewport', (tester) async {
      await _stats(
        tester,
        state: 'poor',
        viewport: viewport,
        call: _call(_people),
        audio: [
          _heard('Ada Lovelace', concealed: 380, lost: 12, jitter: 78),
          _sending,
        ],
        video: [_share(poor: true), _camera],
      );
    });

    testWidgets('voice notice banner at $viewport', (tester) async {
      await renderReview(
        tester,
        surface: 'banner-voice-notice',
        viewport: viewport,
        route: '/channels/c-general',
        step: (tester, container) async {
          container
              .read(voiceNoticeProvider.notifier)
              .state = const VoiceNoticeItem(
            channelId: 'c-main',
            text: 'Ada Lovelace started a call in #main',
          );
          await reviewFrames(tester);
        },
      );
    });
  }
}
