// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A track re-attached while its first renderer is still initializing must not
/// leave that first native renderer behind.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:slimm_rtc/src/track_tile_state.dart';

class _Track implements lk.VideoTrack {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Tile extends StatefulWidget {
  const _Tile(this.room, this.track);

  final lk.Room room;
  final ValueNotifier<lk.VideoTrack?> track;

  @override
  State<_Tile> createState() => _TileState();
}

class _TileState extends State<_Tile> with TrackTileState<_Tile> {
  @override
  lk.Room get tileRoom => widget.room;
  @override
  String get tileIdentity => 'me';
  @override
  lk.VideoTrack? currentTrack() => widget.track.value;

  @override
  void initState() {
    super.initState();
    startTrackTile();
  }

  @override
  void dispose() {
    stopTrackTile();
    super.dispose();
  }

  void resync() => syncTrackTileForTest();

  @override
  Widget build(BuildContext context) => const SizedBox();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the same track re-attached mid-initialize leaks no renderer', (
    tester,
  ) async {
    var created = 0;
    var disposed = 0;
    final gates = <Completer<void>>[];
    const channel = MethodChannel('FlutterWebRTC.Method');
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'createVideoRenderer') {
        final gate = Completer<void>();
        gates.add(gate);
        await gate.future;
        return {'textureId': ++created};
      }
      if (call.method == 'videoRendererDispose') disposed++;
      return null;
    });
    final quiet = [
      for (final name in const [
        'FlutterWebRTC.Event',
        'FlutterWebRTC/Texture1',
        'FlutterWebRTC/Texture2',
      ])
        MethodChannel(name),
    ];
    for (final c in quiet) {
      messenger.setMockMethodCallHandler(c, (call) async => null);
    }
    addTearDown(() {
      messenger.setMockMethodCallHandler(channel, null);
      for (final c in quiet) {
        messenger.setMockMethodCallHandler(c, null);
      }
    });

    final room = lk.Room();
    final track = ValueNotifier<lk.VideoTrack?>(_Track());
    final same = track.value;
    await tester.pumpWidget(MaterialApp(home: _Tile(room, track)));
    final state = tester.state<_TileState>(find.byType(_Tile));

    track.value = null;
    state.resync();
    track.value = same;
    state.resync();
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    expect(gates, hasLength(2));
    for (final gate in gates) {
      gate.complete();
    }
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump();

    expect(state.ownedRenderer, isNotNull);
    expect(created - disposed, 1, reason: 'one renderer may stay alive');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 30));
    await tester.runAsync(room.dispose);
  });
}
