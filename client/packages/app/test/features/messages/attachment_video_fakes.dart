// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Stand-ins for the parts of `media_kit` and the network that a headless test
/// cannot reach, shared by the inline video player's suites.
///
/// Not a `_test.dart` file, so `flutter test` does not try to run it.
library;

import 'dart:async';

import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/messages/widgets/attachment_video_source.dart';

const videoAttachment = api.Attachment(
  id: 'v1',
  filename: 'clip.mp4',
  contentType: 'video/mp4',
  size: 12000000,
);

/// Answers [open] from a script instead of the network, cycling its outcomes.
///
/// Only failing outcomes are scripted: `Player.open` waits on the video
/// controller's GL texture, which a headless test never gets, so a load that
/// succeeds never resolves here and the ready path stays out of reach.
class ScriptedSource implements AttachmentVideoSource {
  ScriptedSource(this._outcomes);

  final List<Object> _outcomes;
  int opens = 0;
  bool disposed = false;

  @override
  Future<Media> open({
    required api.SlimmApi apiClient,
    required api.Attachment attachment,
    required void Function(double? progress) onProgress,
  }) async {
    final next = _outcomes[opens < _outcomes.length ? opens : 0];
    opens += 1;
    if (next is Media) return next;
    throw next;
  }

  @override
  bool isStale(api.SlimmApi apiClient) => false;

  @override
  void dispose() => disposed = true;
}

/// A [Player] that records its lifecycle and lets a test fire stream events.
///
/// Only what the widget and its token reopener touch is real; anything else
/// throws, so a new dependency on the player fails loudly here.
class FakePlayer implements Player {
  final errors = StreamController<String>.broadcast();
  final playing = StreamController<bool>.broadcast();
  final buffering = StreamController<bool>.broadcast();
  final lifecycle = <String>[];
  final opened = <Playable>[];
  final autoplay = <bool>[];
  bool disposed = false;
  int pauses = 0;

  @override
  Future<void> pause() async => pauses += 1;

  @override
  late final PlayerStream stream = _FakeStream(this);

  @override
  PlayerState get state => const PlayerState();

  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    lifecycle.add('open');
    opened.add(playable);
    autoplay.add(play);
  }

  @override
  Future<void> dispose({bool synchronized = true}) async {
    disposed = true;
    await errors.close();
    await playing.close();
    await buffering.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

/// Stands in for the render context a headless test cannot create.
class FakeVideoController implements VideoController {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _FakeStream implements PlayerStream {
  _FakeStream(this._player);

  final FakePlayer _player;

  @override
  Stream<String> get error => _player.errors.stream;

  @override
  Stream<bool> get playing => _player.playing.stream;

  @override
  Stream<bool> get buffering => _player.buffering.stream;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}
