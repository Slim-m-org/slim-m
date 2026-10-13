// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests for the voice session, driven through the room-injection seam.
///
/// None of this needs an SFU, which is the point of the seam: the branches
/// worth pinning are the unhappy ones, and a real signalling server can only
/// reliably produce the happy one.
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:slimm_rtc/rtc.dart';

/// A room that fails to connect, standing in for a bad token, an unreachable
/// SFU, or a network that went away mid-handshake. All three arrive here the
/// same way.
class _FailingRoom extends lk.Room {
  _FailingRoom(this.error);
  final Object error;

  @override
  Future<void> connect(
    String url,
    String token, {
    lk.ConnectOptions? connectOptions,
    lk.RoomOptions? roomOptions,
    lk.FastConnectOptions? fastConnectOptions,
  }) async {
    throw error;
  }
}

/// A room that connects without an SFU behind it. Its `localParticipant`
/// stays null, which is exactly the shape iOS produces on a share request:
/// the call returns having published nothing.
class _EmptyRoom extends lk.Room {
  @override
  Future<void> connect(
    String url,
    String token, {
    lk.ConnectOptions? connectOptions,
    lk.RoomOptions? roomOptions,
    lk.FastConnectOptions? fastConnectOptions,
  }) async {}
}

/// A room whose `connect` blocks on [gate] rather than resolving on its own,
/// standing in for a slow network so a test can race a leave against a join
/// still in flight.
class _GatedRoom extends lk.Room {
  _GatedRoom(this.gate);
  final Future<void> gate;

  @override
  Future<void> connect(
    String url,
    String token, {
    lk.ConnectOptions? connectOptions,
    lk.RoomOptions? roomOptions,
    lk.FastConnectOptions? fastConnectOptions,
  }) =>
      gate;
}

/// Stands in for the iOS host. [available] is what the app reports about its
/// broadcast extension. The iOS hand-off itself has its own dedicated tests
/// in `screen_share_control_test.dart`; these only need enough of the seam to
/// prove `VoiceSession` wires it up.
class _FakeBridge implements BroadcastBridge {
  _FakeBridge({this.available = true});

  final bool available;
  int stopRequests = 0;

  @override
  bool get usesBroadcastExtension => true;

  @override
  Future<bool> isAvailable() async => available;

  @override
  Future<void> requestStop() async => stopRequests++;

  @override
  set autoPublishEnabled(bool enabled) {}

  @override
  Stream<bool> get broadcastingChanges => const Stream.empty();
}

void main() {
  test('a fresh session is idle and holds no error', () {
    final session = VoiceSession(roomFactory: () => lk.Room());
    addTearDown(session.dispose);
    expect(session.state, VoiceSessionState.idle);
    expect(session.participants, isEmpty);
    expect(session.lastError, isNull);
    expect(session.deafened, isFalse);
  });

  test('a refused connection fails the session rather than hanging', () async {
    final session = VoiceSession(
      roomFactory: () => _FailingRoom(StateError('invalid token')),
    );
    addTearDown(session.dispose);

    final seen = <VoiceSessionState>[];
    session.states.listen(seen.add);

    await session.join(url: 'wss://example.invalid', token: 'nope');
    // states is a broadcast stream, so its events land a microtask later than
    // the synchronous state field. Pump before asserting what a listener got.
    await pumpEventQueue();

    expect(session.state, VoiceSessionState.failed);
    expect(session.lastError.toString(), contains('invalid token'));
    expect(
      seen,
      containsAllInOrder([
        VoiceSessionState.connecting,
        VoiceSessionState.failed,
      ]),
      reason: 'the UI needs to see connecting before it sees the failure',
    );
  });

  test('a camera pre-toggle does not fail a join with nothing to publish to',
      () async {
    // Mirrors the microphone case: _EmptyRoom's localParticipant stays null,
    // so there is nothing to publish a camera track to, and that must not
    // fail the join - a call with no camera track is still a call.
    final session = VoiceSession(roomFactory: _EmptyRoom.new);
    addTearDown(session.dispose);

    await session.join(
      url: 'wss://a.invalid',
      token: 't',
      cameraEnabled: true,
    );
    expect(session.state, VoiceSessionState.connected);
  });

  test('a failed join leaves nothing to clean up behind it', () async {
    final session = VoiceSession(
      roomFactory: () => _FailingRoom(StateError('unreachable')),
    );
    addTearDown(session.dispose);

    await session.join(url: 'wss://example.invalid', token: 'nope');
    expect(session.participants, isEmpty);

    // These must not act on a torn-down room, and must say so rather than
    // throwing into whatever called them. Deafening follows the same rule.
    expect(await session.setMicrophoneEnabled(true), isFalse);
    expect(
      await session.setScreenShareEnabled(true),
      ScreenShareOutcome.failed,
    );
    expect(await session.setDeafened(true), isFalse);
    expect(session.deafened, isFalse);
  });

  group('screen share outcome', () {
    // A bool cannot say what iOS does: the call returns with nothing
    // published, and reporting that as success lit the share button anyway.

    test('publishing nothing reports a pending broadcast, not success',
        () async {
      final session = VoiceSession(
        roomFactory: _EmptyRoom.new,
        broadcast: _FakeBridge(),
      );
      addTearDown(session.dispose);

      await session.join(url: 'wss://a.invalid', token: 't');
      expect(
        await session.setScreenShareEnabled(true),
        ScreenShareOutcome.pendingBroadcast,
        reason: 'no screen track is published, so nobody can see a screen',
      );
    });

    test('a host with no broadcast extension is refused up front', () async {
      final session = VoiceSession(
        roomFactory: _EmptyRoom.new,
        broadcast: _FakeBridge(available: false),
      );
      addTearDown(session.dispose);

      await session.join(url: 'wss://a.invalid', token: 't');
      expect(
        await session.setScreenShareEnabled(true),
        ScreenShareOutcome.unsupported,
        reason: 'waiting on a picker that cannot appear helps nobody',
      );
    });

    // Teardown coverage for every path a call can end lives in
    // voice_session_screen_share_teardown_test.dart, split out for the budget.
  });

  group('deafen', () {
    test('has no effect and reports failure with no room to act on', () async {
      final session = VoiceSession(roomFactory: () => lk.Room());
      addTearDown(session.dispose);

      expect(await session.setDeafened(true), isFalse);
      expect(session.deafened, isFalse);
    });

    test('leaving resets state back to idle without deafen surviving it',
        () async {
      final session = VoiceSession(roomFactory: () => lk.Room());
      addTearDown(session.dispose);

      await session.leave();
      expect(session.state, VoiceSessionState.idle);
      expect(session.deafened, isFalse);
    });
  });

  test('leaving an idle session is safe and stays idle', () async {
    final session = VoiceSession(roomFactory: () => lk.Room());
    addTearDown(session.dispose);
    await session.leave();
    expect(session.state, VoiceSessionState.idle);
  });

  test('a second failed join does not stack a second connection', () async {
    var built = 0;
    final session = VoiceSession(roomFactory: () {
      built++;
      return _FailingRoom(StateError('nope'));
    });
    addTearDown(session.dispose);

    await session.join(url: 'wss://a.invalid', token: 't1');
    await session.join(url: 'wss://a.invalid', token: 't2');

    expect(built, 2, reason: 'each attempt builds its own room');
    expect(session.state, VoiceSessionState.failed);
  });

  test('overlapping joins serialize instead of racing one room slot', () async {
    var built = 0;
    final session = VoiceSession(
      roomFactory: () {
        built++;
        return _EmptyRoom();
      },
    );
    addTearDown(session.dispose);

    // Unawaited on purpose: both are in flight at once, which used to let
    // both pass the room-null check and fight over the session's one slot.
    final first = session.join(url: 'wss://a.invalid', token: 't1');
    final second = session.join(url: 'wss://a.invalid', token: 't2');
    await Future.wait([first, second]);

    expect(built, 2,
        reason: 'the second join runs after, not inside, the first');
    expect(session.state, VoiceSessionState.connected);
  });

  test(
      'leaving while a join is still connecting is not undone once that '
      'connect finally resolves', () async {
    final gate = Completer<void>();
    final session = VoiceSession(roomFactory: () => _GatedRoom(gate.future));
    addTearDown(session.dispose);

    final joining = session.join(url: 'wss://a.invalid', token: 't');
    // Let _join reach its `await room.connect(...)` before racing it.
    await pumpEventQueue();
    expect(session.state, VoiceSessionState.connecting);

    await session.leave();
    expect(session.state, VoiceSessionState.idle);

    // The stale connect resolves late; it must not resurrect the call.
    gate.complete();
    await joining;
    await pumpEventQueue();

    expect(
      session.state,
      VoiceSessionState.idle,
      reason: 'a join superseded by an explicit leave must stay left',
    );
  });

  test('dispose is idempotent and survives never having joined', () async {
    final session = VoiceSession(roomFactory: () => lk.Room());
    await session.dispose();
    await session.dispose();
    // Calls after disposal must be inert rather than throwing into a widget
    // tree that is already being torn down.
    await session.join(url: 'wss://a.invalid', token: 't');
    expect(session.state, VoiceSessionState.idle);
  });

  group('screen share ceilings', () {
    test('every quality is bounded on all four axes', () {
      // The point of the enum is that no path publishes an unbounded share: 4K
      // at 60fps saturates a home upload and starves the audio it accompanies.
      for (final q in ScreenShareQuality.all) {
        expect(q.width, greaterThan(0));
        expect(q.height, greaterThan(0));
        expect(q.fps, inInclusiveRange(1, 60));
        expect(q.maxBitrate, inInclusiveRange(1, 5000000),
            reason: '${q.id} must stay inside a home upload');
      }
    });

    test('the bitrate ceiling never falls as resolution or frame rate rise',
        () {
      for (final r in ScreenShareResolution.values) {
        for (final f in ScreenShareFps.values) {
          final q = ScreenShareQuality(r, f);
          for (final r2 in ScreenShareResolution.values) {
            for (final f2 in ScreenShareFps.values) {
              if (r2.index >= r.index && f2.index >= f.index) {
                expect(ScreenShareQuality(r2, f2).maxBitrate,
                    greaterThanOrEqualTo(q.maxBitrate));
              }
            }
          }
        }
      }
    });

    test('the default stays 1080p30 at 2.4 Mbps', () {
      expect(ScreenShareQuality.standard.id, '1080p30');
      expect(ScreenShareQuality.standard.maxBitrate, 2400000);
    });

    test('an id round-trips and an unknown one is null', () {
      for (final q in ScreenShareQuality.all) {
        expect(ScreenShareQuality.fromId(q.id), q);
      }
      expect(ScreenShareQuality.fromId('crisp'), isNull);
    });
  });

  group('VoiceParticipant', () {
    test('compares by value, so an unchanged roster does not rebuild', () {
      const a = VoiceParticipant(
        identity: 'u1',
        name: 'alice',
        isSpeaking: false,
        isMuted: true,
        isLocal: true,
        isScreenSharing: false,
      );
      const b = VoiceParticipant(
        identity: 'u1',
        name: 'alice',
        isSpeaking: false,
        isMuted: true,
        isLocal: true,
        isScreenSharing: false,
      );
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });

    test('a change in speaking state is a different participant', () {
      const quiet = VoiceParticipant(
        identity: 'u1',
        name: 'alice',
        isSpeaking: false,
        isMuted: false,
        isLocal: false,
        isScreenSharing: false,
      );
      const talking = VoiceParticipant(
        identity: 'u1',
        name: 'alice',
        isSpeaking: true,
        isMuted: false,
        isLocal: false,
        isScreenSharing: false,
      );
      expect(quiet, isNot(equals(talking)));
    });

    test('a camera coming on is a different participant', () {
      const off = VoiceParticipant(
        identity: 'u1',
        name: 'alice',
        isSpeaking: false,
        isMuted: false,
        isLocal: false,
        isScreenSharing: false,
      );
      const on = VoiceParticipant(
        identity: 'u1',
        name: 'alice',
        isSpeaking: false,
        isMuted: false,
        isLocal: false,
        isScreenSharing: false,
        isCameraOn: true,
      );
      expect(off, isNot(equals(on)));
      expect(off.hashCode, isNot(equals(on.hashCode)));
    });
  });

  // Capture-options and iOS hand-off tests live in
  // screen_share_control_test.dart now, next to ScreenShareControl itself.
  test(
      'screen share sources are listed through the injected seam, never a global',
      () async {
    final session = VoiceSession(
      roomFactory: _EmptyRoom.new,
      desktopSources: _FakeSources(const [
        ScreenShareSource(id: '1', name: 'Screen 1'),
      ]),
    );
    addTearDown(session.dispose);

    expect(session.screenShareNeedsSource, isTrue);
    expect((await session.screenShareSources()).single.id, '1');
  });

  test(
      'whether several sources are worth their own picker reaches the '
      'session unchanged', () async {
    final session = VoiceSession(
      roomFactory: _EmptyRoom.new,
      desktopSources: _FakeSources(const [], sourcePickerUseful: false),
    );
    addTearDown(session.dispose);

    expect(session.screenShareSourcePickerUseful, isFalse);
  });
}

class _FakeSources implements DesktopSources {
  const _FakeSources(this._sources, {this.sourcePickerUseful = true});

  final List<ScreenShareSource> _sources;

  @override
  bool get required => true;

  @override
  final bool sourcePickerUseful;

  @override
  Future<List<ScreenShareSource>> list() async => _sources;
}
