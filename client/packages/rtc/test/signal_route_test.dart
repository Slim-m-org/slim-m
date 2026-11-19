// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The call's signalling dials through the app's own way when it has one, so
/// on the server's network it skips the public route, and LiveKit runs over
/// that socket exactly as over its own; anything else is LiveKit's to dial.
library;

// ignore_for_file: invalid_use_of_internal_member

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
// ignore: implementation_imports
import 'package:livekit_client/src/internal/events.dart' as lk_events;
// ignore: implementation_imports
import 'package:livekit_client/src/proto/livekit_rtc.pb.dart' as lk_rtc;
// ignore: implementation_imports
import 'package:livekit_client/src/support/websocket.dart' as lk_ws;
import 'package:slimm_rtc/rtc.dart' show InputGateMonitor;
import 'package:slimm_rtc/src/signal_route.dart';
import 'package:slimm_rtc/src/start_bitrate_room.dart';
import 'package:slimm_rtc/src/voice_session_core.dart';
import 'package:slimm_test_support/slimm_test_support.dart';
import 'package:web_socket_channel/io.dart';

import 'support/no_audio_devices.dart';

/// A loopback signalling server: it sends [greeting] on connect and keeps what it hears.
class _Sfu {
  late HttpServer _server;
  final heard = <List<int>>[];
  final closed = Completer<void>();
  final sockets = <WebSocket>[];
  List<int> greeting = const [1, 2, 3];

  Uri get url => Uri.parse('ws://127.0.0.1:${_server.port}');

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      sockets.add(socket);
      socket.add(greeting);
      socket.listen(
        (data) => heard.add(data as List<int>),
        onDone: () {
          if (!closed.isCompleted) closed.complete();
        },
      );
    });
    addTearDown(() => _server.close(force: true));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _Sfu sfu;
  late List<Uri> opened;
  late List<Map<String, String>?> openHeaders;
  late List<Uri> fallbackDials;

  setUp(() async {
    sfu = _Sfu();
    await sfu.start();
    opened = [];
    openHeaders = [];
    fallbackDials = [];
  });

  Future<IOWebSocketChannel?> openDirect(
    Uri url,
    Map<String, String>? headers,
  ) async {
    opened.add(url);
    openHeaders.add(headers);
    return IOWebSocketChannel(await WebSocket.connect(sfu.url.toString()));
  }

  Future<lk_ws.LiveKitWebSocket> fallback(
    Uri uri, {
    lk_ws.WebSocketEventHandlers? options,
    Map<String, String>? headers,
    lk.NetworkOptions? networkOptions,
  }) {
    fallbackDials.add(uri);
    return Future.error(const SocketException('the public route, in a test'));
  }

  test(
      'a socket the app opens carries the signalling both ways, and closes '
      'like LiveKit expects', () async {
    final route = SignalRoute(openDirect, fallback: fallback);
    final data = <dynamic>[];
    final disposed = Completer<void>();

    final socket = await route.connect(
      Uri.parse('wss://livekit.example.com/rtc'),
      headers: {'Authorization': 'Bearer t'},
      options: lk_ws.WebSocketEventHandlers(
        onData: data.add,
        onDispose: disposed.complete,
      ),
    );

    expect(route.direct, isTrue);
    expect(opened.single.host, 'livekit.example.com');
    expect(openHeaders.single, {'Authorization': 'Bearer t'});
    expect(fallbackDials, isEmpty);
    await pollUntil(() => data.isNotEmpty);
    expect(data.single, [1, 2, 3]);

    socket.send([4, 5]);
    await pollUntil(() => sfu.heard.isNotEmpty);
    expect(sfu.heard.single, [4, 5]);

    await socket.dispose();
    await sfu.closed.future;
    await disposed.future;
    socket.send([6]);
  });

  test('a socket the far end closes tells LiveKit and stops sending', () async {
    final route = SignalRoute(openDirect, fallback: fallback);
    final disposed = Completer<void>();
    final socket = await route.connect(
      Uri.parse('wss://livekit.example.com/rtc'),
      options: lk_ws.WebSocketEventHandlers(onDispose: disposed.complete),
    );
    await pollUntil(() => sfu.sockets.isNotEmpty);

    await sfu.sockets.single.close();
    await disposed.future;
    socket.send([7]);
    await socket.dispose();
    expect(sfu.heard, isEmpty);
  });

  test('no socket from the app, or a failing one, leaves the dial to LiveKit',
      () async {
    final url = Uri.parse('wss://livekit.example.com/rtc');
    final declining = SignalRoute((_, __) async => null, fallback: fallback);
    await expectLater(declining.connect(url), throwsA(isA<SocketException>()));
    expect(declining.direct, isFalse);

    final failing = SignalRoute(
      (_, __) => Future.error(StateError('broken')),
      fallback: fallback,
    );
    await expectLater(failing.connect(url), throwsA(isA<SocketException>()));
    expect(failing.direct, isFalse);
    expect(fallbackDials, [url, url]);
  });

  test('the route says the socket went public once a reconnect does', () async {
    var direct = true;
    final route = SignalRoute(
      (url, headers) async => direct ? openDirect(url, headers) : null,
      fallback: fallback,
    );
    final url = Uri.parse('wss://livekit.example.com/rtc');
    final first = await route.connect(url);
    expect(route.direct, isTrue);
    await first.dispose();

    direct = false;
    await expectLater(route.connect(url), throwsA(anything));
    expect(route.direct, isFalse);
  });

  test(
      'a call room built with a route runs LiveKit signalling over it, '
      'with the token in the header', () async {
    // A token refresh, because a join answer would start real peer connections.
    sfu.greeting = lk_rtc.SignalResponse(refreshToken: 'tok2').writeToBuffer();
    final route = SignalRoute(openDirect, fallback: fallback);
    final room =
        buildRoomWithStartBitrate(const lk.RoomOptions(), signal: route);
    addTearDown(room.dispose);
    final signal = room.engine.signalClient;
    final refreshed = signal.events.waitFor<lk_events.SignalTokenUpdatedEvent>(
      duration: const Duration(seconds: 5),
    );

    await signal.connect(
      'wss://livekit.example.com',
      'tok',
      connectOptions: const lk.ConnectOptions(),
      roomOptions: const lk.RoomOptions(),
    );

    expect((await refreshed).token, 'tok2');
    expect(opened.single.path, '/rtc');
    expect(openHeaders.single, {'Authorization': 'Bearer tok'});
    expect(fallbackDials, isEmpty);
    await signal.sendLeave();
    await pollUntil(() => sfu.heard.isNotEmpty);
    expect(lk_rtc.SignalRequest.fromBuffer(sfu.heard.last).hasLeave(), isTrue);
  });

  test(
      'a session given an opener builds its call rooms on it, and its link '
      'readings say the signalling went direct', () async {
    sfu.greeting = lk_rtc.SignalResponse(refreshToken: 'tok2').writeToBuffer();
    final core = VoiceSessionCore(
      signalOpen: openDirect,
      audioDevices: const NoAudioDevices(),
      inputGate: InputGateMonitor.disabled(),
    );
    addTearDown(core.flow.dispose);
    final room = core.createRoom();
    // The session's teardown disconnects and disposes it.
    core.flow.room = room;
    final signal = room.engine.signalClient;
    final refreshed = signal.events.waitFor<lk_events.SignalTokenUpdatedEvent>(
      duration: const Duration(seconds: 5),
    );

    await signal.connect(
      'wss://livekit.example.com',
      'tok',
      connectOptions: const lk.ConnectOptions(),
      roomOptions: const lk.RoomOptions(),
    );
    await refreshed;
    expect(opened.single.host, 'livekit.example.com');

    await core.healthWatch.localVoiceStats();
    expect(core.healthWatch.health.link.value?.signalDirect, isTrue);
  });
}
