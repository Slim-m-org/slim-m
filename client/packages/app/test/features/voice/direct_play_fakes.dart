// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A player, a media server and an environment the direct play tests share, so
/// the controller's decisions run without libmpv or a network. See
/// docs/decisions/0050-watch-party-sync-authority-and-direct-play.md.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/voice/providers/direct_play_controller.dart';
import 'package:slimm_app/src/features/voice/providers/direct_player.dart';
import 'package:slimm_app/src/features/voice/providers/jellyfin_direct_client.dart';
import 'package:slimm_app/src/features/voice/providers/watch_room.dart';
import 'package:slimm_test_support/slimm_test_support.dart';

const jellyUrl = 'http://10.0.0.5:8096';

class FakePlayer implements DirectPlayer {
  @override
  Duration position = Duration.zero;
  @override
  bool isPlaying = false;
  @override
  bool isBuffering = false;
  double rate = 1.0;
  String? openedUrl;
  Map<String, String>? openedHeaders;
  Duration? openedAt;
  final List<Duration> seeks = [];
  bool disposed = false;
  Object? openError;

  @override
  Future<void> open(
    String url,
    Map<String, String> headers,
    Duration start,
  ) async {
    if (openError != null) throw openError!;
    openedUrl = url;
    openedHeaders = headers;
    openedAt = start;
    position = start;
  }

  @override
  Future<void> play() async => isPlaying = true;

  @override
  Future<void> pause() async => isPlaying = false;

  @override
  Future<void> seek(Duration to) async {
    seeks.add(to);
    position = to;
  }

  @override
  Future<void> setRate(double value) async => rate = value;

  @override
  Widget buildVideo() => const ColoredBox(color: Color(0xFF223344));

  @override
  Future<void> dispose() async => disposed = true;
}

class Rig {
  Rig({
    this.reachable = true,
    this.canSee = true,
    this.credential = true,
    DateTime? start,
  }) : now = start ?? DateTime.utc(2026, 10, 31, 20) {
    media = MockClient((request) async {
      mediaCalls.add('${request.method} ${request.url.path}');
      if (request.url.path == '/System/Info/Public') {
        return http.Response(reachable ? '{}' : 'no', reachable ? 200 : 503);
      }
      if (request.url.path.startsWith('/Users/u-jelly/Items/')) {
        return http.Response('{}', canSee ? 200 : 404);
      }
      if (request.url.path == '/Users/AuthenticateByName') {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        return body['Pw'] == 'right'
            ? http.Response(
                jsonEncode({
                  'AccessToken': 'tok',
                  'User': {'Id': 'u-jelly'},
                }),
                200,
              )
            : http.Response('', 401);
      }
      return http.Response('', 404);
    });
    slimm = testApi((request) async {
      if (request.url.path.endsWith('/watch-session/viewing')) {
        reports.add((jsonDecode(request.body) as Map)['direct'] as bool);
      }
      return http.Response('', 204);
    });
  }

  final bool reachable;
  bool canSee;
  final bool credential;
  DateTime now;
  late final MockClient media;
  late final api.SlimmApi slimm;
  final List<String> mediaCalls = [];
  final List<bool> reports = [];
  final List<FakePlayer> players = [];
  final List<String> events = [];
  JellyfinSession? saved;
  bool enabledSaved = false;
  Object? openError;

  FakePlayer get player => players.last;

  DirectPlayEnvironment env({bool supported = true}) => DirectPlayEnvironment(
    slimm: slimm,
    selfId: 'me',
    clock: () => now,
    client: JellyfinDirectClient(media, deviceId: 'test'),
    makePlayer: () {
      events.add('player');
      final p = FakePlayer()..openError = openError;
      players.add(p);
      return p;
    },
    loadCredential: (_) async => credential
        ? (saved ?? const JellyfinSession(token: 'tok', userId: 'u-jelly'))
        : saved,
    saveCredential: (_, session) async => saved = session,
    saveEnabled: (on) async => enabledSaved = on,
    holdShare: (id) => events.add('hold:$id'),
    releaseShare: (id) => events.add('release:$id'),
    directPlaySupported: supported,
  );
}

/// A room at [positionMs] as of the rig's clock, offering direct play unless [offer] is null.
WatchRoom room(
  Rig rig, {
  bool playing = true,
  int positionMs = 60000,
  int epoch = 1,
  String itemId = 'item-1',
  api.WatchDirectPlay? offer = const api.WatchDirectPlay(
    baseUrl: jellyUrl,
    verifiedUserIds: ['me'],
  ),
}) => WatchRoom(
  botUserId: 'jelly',
  itemId: itemId,
  title: 'A Film',
  playing: playing,
  position: Duration(milliseconds: positionMs),
  sampledAtMs: rig.now.millisecondsSinceEpoch,
  epoch: epoch,
  ttl: const Duration(seconds: 30),
  clockOffset: Duration.zero,
  duration: const Duration(hours: 2),
  directPlay: offer,
);
