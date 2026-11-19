// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What happens during a soak: a seeded script of traffic and of the things
/// the person at the desk does, in simulated time.
///
/// One [epoch] is ten simulated minutes, the retention sweep's own period:
/// sixty steps of ten seconds. Every account receives traffic, on screen or
/// not, the way a signed-in server out of view still does.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/routing/router.dart';

import 'soak_app.dart';
import 'soak_world.dart';

const stepsPerEpoch = 60;
const stepLength = Duration(seconds: 10);

class SoakDriver {
  SoakDriver(this.tester, this.app, {required int seed})
    : _random = Random(seed) {
    for (final origin in app.origins) {
      _open[origin] = app.worlds[origin]!.textChannelIds.first;
    }
  }

  final WidgetTester tester;
  final SoakApp app;
  final Random _random;
  final _open = <String, String>{};
  var _steps = 0;

  /// Frames delivered since the run began, for the report.
  var delivered = 0;

  String get activeOrigin => app.host.active!.account!.origin;

  T _pick<T>(List<T> from) => from[_random.nextInt(from.length)];

  Future<void> _deliver(String origin, Map<String, dynamic> frame) async {
    final event = api.ServerEvent.parse(jsonEncode(frame));
    if (event == null) throw StateError('unparsed soak frame ${frame['type']}');
    await app.sync(origin).deliver(event);
    delivered++;
  }

  /// Shows every account once on its first channel, so what an account builds
  /// the first time it is on screen is there before the first sample.
  Future<void> open() async {
    for (final origin in app.origins.reversed) {
      await app.host.switchTo(origin);
      app.go(origin, '/channels/${_open[origin]}');
      await tester.pump(const Duration(seconds: 2));
    }
  }

  Future<void> steps(int count) async {
    for (var i = 0; i < count; i++) {
      await step();
    }
  }

  Future<void> step() async {
    _steps++;
    for (final origin in app.origins) {
      final world = app.worlds[origin]!..nowMs += stepLength.inMilliseconds;
      await _traffic(origin, world, busy: origin == activeOrigin);
    }
    if (_steps % 6 == 0) await _switchChannel();
    if (_steps % stepsPerEpoch == 10) await _hangUpElsewhere();
    if (_steps % stepsPerEpoch == 20) await _call();
    if (_steps % stepsPerEpoch == 40) await _visitSettings();
    if (_steps % stepsPerEpoch == 55) await _joinAndStay();
    if (_steps % stepsPerEpoch == 0) await _switchAccount();
    await tester.pump(stepLength);
  }

  String? _inCall;

  /// The person joins a call and leaves it running, so the next switch shows it from another account.
  Future<void> _joinAndStay() async {
    final origin = activeOrigin;
    final world = app.worlds[origin]!;
    final channel = _pick(world.voiceChannelIds);
    world.voice[channel]!.add(world.selfId);
    await app.voice(origin).join(channel);
    await _deliver(origin, {'type': 'voice.activity', 'channel_id': channel});
    _inCall = origin;
    await tester.pump(const Duration(seconds: 1));
  }

  /// Ends the call left running in an account that is no longer on screen.
  Future<void> _hangUpElsewhere() async {
    final origin = _inCall;
    if (origin == null) return;
    _inCall = null;
    final world = app.worlds[origin]!;
    for (final room in world.voice.values) {
      room.remove(world.selfId);
    }
    await app.voice(origin).leave();
    await tester.pump(const Duration(seconds: 1));
  }

  /// A step's worth of other people: messages, typing, presence, reactions, edits, calls.
  Future<void> _traffic(
    String origin,
    SoakWorld world, {
    required bool busy,
  }) async {
    final open = _open[origin]!;
    // One channel is busy enough to cross the store's per-channel ceiling within a couple of hours.
    for (var i = 0; i < 2; i++) {
      await _deliver(origin, {
        'type': 'message.created',
        'message': world.nextMessage(world.textChannelIds[1]),
      });
    }
    for (var i = 0; i < (busy ? 3 : 1); i++) {
      final channel = _random.nextInt(4) == 0
          ? open
          : _pick(world.textChannelIds);
      await _deliver(origin, {
        'type': 'message.created',
        'message': world.nextMessage(channel),
      });
    }
    final typist = world.randomMember();
    await _deliver(origin, {
      'type': 'typing.started',
      'channel_id': _random.nextBool() ? open : _pick(world.textChannelIds),
      'user_id': typist,
    });
    final member = world.randomMember();
    final status = _pick(const ['online', 'away', 'offline']);
    world.presence[member] = status;
    await _deliver(origin, {
      'type': 'presence.changed',
      'user_id': member,
      'status': status,
    });
    if (_steps % 3 == 0) await _react(origin, world, open);
    if (_steps % 7 == 0) await _edit(origin, world, open);
    if (_steps % 11 == 0) await _delete(origin, world);
    if (_steps % 5 == 0) await _voiceChurn(origin, world);
  }

  Future<void> _react(String origin, SoakWorld world, String open) async {
    final channel = _random.nextBool() ? open : _pick(world.textChannelIds);
    final target = world.recentMessage(channel);
    if (target == null) return;
    await _deliver(origin, {
      'type': 'reactions.changed',
      'channel_id': channel,
      'message_id': target['id'],
      'reactions': [
        {'emoji': '\u{1F44D}', 'count': 1 + _random.nextInt(5)},
      ],
    });
  }

  Future<void> _edit(String origin, SoakWorld world, String open) async {
    final target = world.recentMessage(open);
    if (target == null) return;
    target['content'] = '${target['content']} (edited)';
    target['edited_at'] = world.nowMs;
    await _deliver(origin, {'type': 'message.edited', 'message': target});
  }

  Future<void> _delete(String origin, SoakWorld world) async {
    final channel = _pick(world.textChannelIds);
    final target = world.recentMessage(channel);
    if (target == null) return;
    world.forget(channel, target['id'] as String);
    await _deliver(origin, {
      'type': 'message.deleted',
      'channel_id': channel,
      'message_id': target['id'],
    });
  }

  /// Someone else joins or leaves a voice channel.
  Future<void> _voiceChurn(String origin, SoakWorld world) async {
    final channel = _pick(world.voiceChannelIds);
    final room = world.voice[channel]!;
    final leaving = room.length > 3 || (room.isNotEmpty && _random.nextBool());
    final who = leaving ? room.first : world.randomMember();
    leaving ? room.remove(who) : room.add(who);
    await _deliver(origin, {
      'type': leaving ? 'voice.participant_left' : 'voice.participant_joined',
      'channel_id': channel,
      'user_id': who,
    });
    await _deliver(origin, {'type': 'voice.activity', 'channel_id': channel});
  }

  Future<void> _switchChannel() async {
    final origin = activeOrigin;
    final next = _pick(app.worlds[origin]!.textChannelIds);
    _open[origin] = next;
    app.go(origin, '/channels/$next');
    await tester.pump(const Duration(milliseconds: 400));
  }

  /// The person joins a voice channel, stays a while, and hangs up.
  Future<void> _call() async {
    final origin = activeOrigin;
    final world = app.worlds[origin]!;
    final channel = _pick(world.voiceChannelIds);
    world.voice[channel]!.add(world.selfId);
    await app.voice(origin).join(channel);
    app.go(origin, '/channels/$channel');
    await tester.pump(const Duration(seconds: 2));
    await _deliver(origin, {'type': 'voice.activity', 'channel_id': channel});
    await tester.pump(const Duration(seconds: 30));
    world.voice[channel]!.remove(world.selfId);
    await app.voice(origin).leave();
    await _deliver(origin, {'type': 'voice.activity', 'channel_id': channel});
    app.go(origin, '/channels/${_open[origin]}');
    await tester.pump(const Duration(seconds: 2));
  }

  Future<void> _visitSettings() async {
    final router = app.runtime(activeOrigin).container.read(routerProvider);
    unawaited(router.push('/settings'));
    await tester.pump(const Duration(seconds: 2));
    if (router.canPop()) router.pop();
    await tester.pump(const Duration(seconds: 1));
  }

  Future<void> _switchAccount() async {
    final origins = app.origins;
    if (origins.length < 2) return;
    final next = origins[(origins.indexOf(activeOrigin) + 1) % origins.length];
    await app.host.switchTo(next);
    await tester.pump(const Duration(seconds: 1));
  }

  /// The same screen every time a sample is taken: the first account, on its first channel.
  Future<void> rest() async {
    await _hangUpElsewhere();
    final origin = app.origins.first;
    if (activeOrigin != origin) await app.host.switchTo(origin);
    _open[origin] = app.worlds[origin]!.textChannelIds.first;
    app.go(origin, '/channels/${_open[origin]}');
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(seconds: 2));
  }

  /// The same frames as the other benches with nothing arriving, as their floor.
  Future<void> benchIdle(int count) async {
    for (var i = 0; i < count; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
  }

  /// Microseconds of real time to take one message into the open channel and draw it.
  Future<int> benchOpenChannel(int count) async {
    final origin = activeOrigin;
    final world = app.worlds[origin]!;
    final watch = Stopwatch()..start();
    for (var i = 0; i < count; i++) {
      await _deliver(origin, {
        'type': 'message.created',
        'message': world.nextMessage(_open[origin]!),
      });
      await tester.pump(const Duration(milliseconds: 16));
    }
    return watch.elapsedMicroseconds ~/ count;
  }

  /// The same for a message in a channel of an account that is not on screen.
  Future<int> benchBackground(int count) async {
    final origin = app.origins.last;
    final world = app.worlds[origin]!;
    final watch = Stopwatch()..start();
    for (var i = 0; i < count; i++) {
      await _deliver(origin, {
        'type': 'message.created',
        'message': world.nextMessage(world.textChannelIds.last),
      });
      await tester.pump(const Duration(milliseconds: 16));
    }
    return watch.elapsedMicroseconds ~/ count;
  }

  /// Milliseconds of real time to open another channel and come back.
  Future<int> benchChannelSwitch() async {
    final origin = activeOrigin;
    final ids = app.worlds[origin]!.textChannelIds;
    final watch = Stopwatch()..start();
    for (final id in [ids[1], ids[0]]) {
      app.go(origin, '/channels/$id');
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 400));
    }
    return watch.elapsedMilliseconds;
  }
}
