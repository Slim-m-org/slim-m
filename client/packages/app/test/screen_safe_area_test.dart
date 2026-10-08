// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Every full-screen body keeps its content clear of the home indicator.
///
/// The rail and the composer got this and nothing else did, so on a notched
/// phone the last row of every settings, admin, onboarding and in-call screen
/// painted under the indicator. These pump each screen on a view that reports
/// real insets and assert on the bottom-most thing actually drawn, not on the
/// [SafeArea] itself: asserting on the widget that owns the inset is how the
/// rail's first attempt at this passed against the mistake it named.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/voice_roster.dart';
import 'package:slimm_app/src/providers/voice_controller.dart';
import 'package:slimm_app/src/screens/admin/channel_permissions_screen.dart';
import 'package:slimm_app/src/screens/admin/emoji_screen.dart';
import 'package:slimm_app/src/screens/admin/invites_screen.dart';
import 'package:slimm_app/src/screens/admin/reports_screen.dart';
import 'package:slimm_app/src/screens/admin/roles_screen.dart';
import 'package:slimm_app/src/screens/onboarding_screen.dart';
import 'package:slimm_app/src/screens/sign_in_screen.dart';
import 'package:slimm_app/src/screens/voice_screen.dart';
import 'package:slimm_app/src/screens/personal_settings_screen.dart';
import 'package:slimm_app/src/widgets/floating_dock_card.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';
import 'package:slimm_rtc/rtc.dart';

/// An iPhone with a notch, in logical points.
const double _topInset = 59;
const double _bottomInset = 34;
const double _dpr = 3;
const Size _view = Size(390, 400);

const _tokens = TokenPair(
  userId: 'user-1',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

const _me = Me(
  id: 'user-1',
  username: 'admin',
  displayName: 'Admin',
  createdAt: 0,
  permissions: -1,
);

/// Every list endpoint these screens reach for, answered empty; the layout
/// question here is the same whether a list has rows in it or not. The voice
/// token is the one object body, since a call has to connect to have controls.
http.Client _emptyApi() => MockClient((request) async {
  final body = request.url.path.endsWith('/voice/token')
      ? jsonEncode({
          'url': 'wss://sfu.example.com',
          'room': 'channel-1',
          'token': 'jwt',
          'expires_at': 0,
          'can_publish': true,
        })
      : '[]';
  return http.Response(
    body,
    200,
    headers: const {'content-type': 'application/json'},
  );
});

/// The minimum [VoiceSession] the controller needs, connecting on join so the
/// in-call surface (and its bottom control bar) actually renders.
class _FakeSession implements VoiceSession {
  @override
  bool get supportsParticipantVolume => true;

  @override
  bool get supportsScreenShareAudio => true;

  final Map<String, double> _volumes = {};

  @override
  double volumeFor(String identity) => _volumes[identity] ?? 1.0;

  @override
  Future<void> setVolumeFor(String identity, double volume) async {
    _volumes[identity] = volume.clamp(0.0, 2.0);
  }

  final _states = StreamController<VoiceSessionState>.broadcast();
  final _participants = StreamController<List<VoiceParticipant>>.broadcast();

  VoiceSessionState _state = VoiceSessionState.idle;

  @override
  bool deafened = false;

  @override
  VoiceSessionState get state => _state;

  @override
  Stream<VoiceSessionState> get states => _states.stream;

  @override
  List<VoiceParticipant> get participants => const [];

  @override
  Stream<List<VoiceParticipant>> get participantChanges => _participants.stream;

  @override
  Object? get lastError => null;

  @override
  VoiceDisconnect? get lastDisconnect => null;

  @override
  bool get screenShareNeedsSource => false;

  @override
  bool get screenShareSourcePickerUseful => true;

  @override
  Future<List<ScreenShareSource>> screenShareSources() async => const [];

  final Set<String> _locallyMuted = {};

  @override
  bool isLocallyMuted(String identity) => _locallyMuted.contains(identity);

  @override
  Future<void> setLocallyMuted(String identity, bool muted) async {
    muted ? _locallyMuted.add(identity) : _locallyMuted.remove(identity);
  }

  @override
  Widget screenShareViewFor(String identity) =>
      SizedBox.shrink(key: Key('fake-share-view-$identity'));

  @override
  Widget cameraViewFor(String identity) =>
      SizedBox.shrink(key: Key('fake-camera-view-$identity'));
  @override
  void setVideoInterest(Set<String>? tileKeys) {}

  @override
  void setSpeakingSensitivity(double sensitivity) {}

  @override
  bool get canFlipCamera => false;

  @override
  bool get cameraNeedsSelection => false;

  @override
  Future<List<CameraDevice>> cameraDevices() async => const [];

  @override
  Future<bool> flipCamera() async => false;

  @override
  Future<bool> selectCameraDevice(CameraDevice device) async => false;

  @override
  bool get supportsAudioInputSelection => false;

  @override
  bool get supportsAudioOutputSelection => false;

  @override
  Stream<void> get audioDeviceChanges => const Stream.empty();

  @override
  Future<List<AudioDevice>> audioInputDevices() async => const [];

  @override
  Future<List<AudioDevice>> audioOutputDevices() async => const [];

  @override
  Future<bool> selectAudioInputDevice(AudioDevice? device) async => false;

  @override
  Future<bool> selectAudioOutputDevice(AudioDevice? device) async => false;

  @override
  Future<void> join({
    required String url,
    required String token,
    bool microphoneEnabled = true,
    bool cameraEnabled = false,
  }) async {
    _state = VoiceSessionState.connected;
    _states.add(_state);
  }

  @override
  Future<void> leave() async {
    _state = VoiceSessionState.idle;
    _states.add(_state);
  }

  @override
  Future<bool> setMicrophoneEnabled(bool enabled) async => true;

  @override
  Future<bool> setCameraEnabled(bool enabled) async => true;

  @override
  Future<ScreenShareOutcome> setScreenShareEnabled(
    bool enabled, {
    ScreenShareQuality quality = ScreenShareQuality.balanced,
    String? sourceId,
    bool includeAudio = false,
    int? maxHeight,
  }) async => enabled ? ScreenShareOutcome.started : ScreenShareOutcome.stopped;

  @override
  Future<bool> setDeafened(bool value) async => true;

  @override
  Future<void> dispose() async {
    await _states.close();
    await _participants.close();
  }
}

/// Pumps [home] on a view reporting notch and home-indicator insets.
Future<ProviderContainer> _pump(
  WidgetTester tester,
  Widget home, {
  List<Override> overrides = const [],
  Size size = _view,
}) async {
  tester.view.physicalSize = size * _dpr;
  tester.view.devicePixelRatio = _dpr;
  tester.view.padding = FakeViewPadding(
    top: _topInset * _dpr,
    bottom: _bottomInset * _dpr,
  );
  tester.view.viewPadding = FakeViewPadding(
    top: _topInset * _dpr,
    bottom: _bottomInset * _dpr,
  );
  addTearDown(tester.view.reset);

  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
      meProvider.overrideWith((ref) async => _me),
      apiProvider.overrideWith((ref) {
        final api = SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          session: ref.watch(sessionProvider),
          httpClient: _emptyApi(),
        );
        ref.onDispose(api.close);
        return api;
      }),
      ...overrides,
    ],
  );
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: home,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

/// The whole point: nothing drawn may reach past the home indicator's edge.
void _expectClearOfIndicator(WidgetTester tester, Finder finder, String what) {
  expect(
    tester.getRect(finder).bottom,
    lessThanOrEqualTo(_view.height - _bottomInset),
    reason: '$what runs under the home indicator',
  );
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('personal settings insets its list above the home indicator', (
    tester,
  ) async {
    await _pump(
      tester,
      const PersonalSettingsScreen(),
      overrides: [
        voiceControllerProvider.overrideWith(
          (ref) => VoiceController(ref, session: _FakeSession()),
        ),
        // The preview polls this every 15 seconds now that it shows who is
        // already in the call; without a stub the timer outlives the test.
        voiceRosterProvider.overrideWith(
          (ref, channelId) =>
              const Stream<List<VoiceRosterParticipant>>.empty(),
        ),
      ],
    );

    _expectClearOfIndicator(
      tester,
      find.byType(ListView),
      "voice settings' list",
    );
  });

  testWidgets('the invites list is inset', (tester) async {
    // Wider on purpose: the four-option expiry AppSegmentedControl.inline
    // overflows by 114px at 390, which is a separate defect from this inset.
    await _pump(tester, const InvitesScreen(), size: const Size(540, 400));

    _expectClearOfIndicator(tester, find.byType(ListView), 'the invite list');
  });

  testWidgets('the roles list is inset even when it is empty', (tester) async {
    await _pump(tester, const RolesScreen());

    // An empty list still renders the roles column, so its ListView fills the body.
    _expectClearOfIndicator(
      tester,
      find.byType(ListView),
      'the empty roles list',
    );
  });

  testWidgets('the reports body is inset even when the queue is empty', (
    tester,
  ) async {
    await _pump(tester, const ReportsScreen());

    // The list fills the body, so its box reports the inset.
    _expectClearOfIndicator(
      tester,
      find
          .ancestor(
            of: find.text('The queue is empty.'),
            matching: find.byType(ListView),
          )
          .first,
      "the reports queue's empty state",
    );
  });

  testWidgets('the emoji list is inset', (tester) async {
    await _pump(tester, const EmojiScreen());

    _expectClearOfIndicator(tester, find.byType(ListView), 'the emoji list');
  });

  testWidgets('the channel permissions picker is inset', (tester) async {
    await _pump(tester, const ChannelPermissionsScreen());

    // No channel chosen yet: the pane is a plain "Choose a channel" row, not
    // a ListView - `ChannelPermissionsPane` is `scrollable: false` and the
    // grid itself only mounts once a channel is picked.
    _expectClearOfIndicator(
      tester,
      find.byType(AppListRow),
      'the channel picker',
    );
  });

  testWidgets('sign-in clears both the notch and the home indicator', (
    tester,
  ) async {
    await _pump(tester, const SignInScreen());

    final form = find.byType(SingleChildScrollView);
    expect(
      tester.getRect(form).top,
      greaterThanOrEqualTo(_topInset),
      reason: 'sign-in has no AppBar, so nothing else clears the notch',
    );
    _expectClearOfIndicator(tester, form, "sign-in's form");
  });

  testWidgets('onboarding clears both the notch and the home indicator', (
    tester,
  ) async {
    await _pump(tester, OnboardingScreen(onServerChosen: (_, __) {}));

    final body = find.byType(SingleChildScrollView);
    expect(
      tester.getRect(body).top,
      greaterThanOrEqualTo(_topInset),
      reason: 'onboarding has no AppBar, so nothing else clears the notch',
    );
    _expectClearOfIndicator(tester, body, "onboarding's entry list");
  });

  testWidgets('the in-call controls float clear of the home indicator, and the '
      "screen's own background still reaches the true edge behind them", (
    tester,
  ) async {
    final container = await _pump(
      tester,
      const Scaffold(body: VoiceScreen(channelId: 'channel-1')),
      overrides: [
        voiceControllerProvider.overrideWith(
          (ref) => VoiceController(ref, session: _FakeSession()),
        ),
        // The preview polls this every 15 seconds now that it shows who is
        // already in the call; without a stub the timer outlives the test.
        voiceRosterProvider.overrideWith(
          (ref, channelId) =>
              const Stream<List<VoiceRosterParticipant>>.empty(),
        ),
      ],
    );
    await container.read(voiceControllerProvider.notifier).join('channel-1');
    await tester.pumpAndSettle();

    _expectClearOfIndicator(
      tester,
      find.byIcon(AppIcons.leaveCall),
      'the leave-call button',
    );

    // The dock is a floating card now, not a full-width bar; it must still clear the indicator.
    final card = find.byType(FloatingDockCard);
    _expectClearOfIndicator(tester, card, 'the floating dock card');

    // The screen's own background, not the old bar's, is what must still reach the true edge.
    final background = find
        .ancestor(of: card, matching: find.byType(ColoredBox))
        .last;
    expect(
      tester.getRect(background).bottom,
      _view.height,
      reason: "the screen's own background must still reach the edge",
    );
    // Clears the heartbeat timer a connected call now keeps running.
    await container.read(voiceControllerProvider.notifier).leave();
  });
}
