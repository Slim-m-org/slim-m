// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Stamp tool on a shared screen's tile (decision 0121): offered only when
/// the server and the sharer's client both take stamps, a tap places the
/// default size, a drag sizes it, nothing is sent mid-drag, and a refusal
/// takes the stamp back off with its reason on the tile.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/canvas/providers/armed_stamp.dart';
import 'package:slimm_app/src/features/canvas/widgets/screen_annotate_layer.dart';
import 'package:slimm_app/src/features/screen_overlay/providers/screen_annotation_board.dart';
import 'package:slimm_app/src/features/screen_overlay/providers/screen_annotation_feed.dart';
import 'package:slimm_app/src/features/screen_overlay/providers/screen_stamp_timing.dart';
import 'package:slimm_app/src/features/screen_overlay/providers/stamp_content.dart';
import 'package:slimm_app/src/features/screen_overlay/providers/stamp_images.dart';
import 'package:slimm_app/src/features/voice/providers/voice_flags.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/server_info.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import '../../support/fake_api.dart';
import '../../support/fake_sync.dart';
import '../../ui_snapshot_support.dart';

const _me = VoiceParticipant(
  identity: 'me',
  name: 'Me',
  isSpeaking: false,
  isMuted: false,
  isLocal: true,
  isScreenSharing: false,
);
const _sharer = VoiceParticipant(
  identity: 'sharer',
  name: 'Ada',
  isSpeaking: false,
  isMuted: false,
  isLocal: false,
  isScreenSharing: true,
);

const _party = EmojiStamp('\u{1F389}');
const _tile = Rect.fromLTWH(100, 100, 640, 360);

class _Rig {
  _Rig(this.tester);

  final WidgetTester tester;
  var now = DateTime(2026, 11, 16, 12);
  late final feed = ScreenAnnotationFeed(selfId: () => 'me', clock: () => now);
  final posts = <Map<String, dynamic>>[];
  final paths = <String>[];
  http.Response Function() answer = () => http.Response('', 204);
  late ProviderContainer container;

  void allow({bool stamps = true}) => feed.handle(
    api.CanvasScreenAnnotation(
      channelId: 'call',
      userId: 'sharer',
      targetUserId: 'sharer',
      kind: 'consent',
      points: const [],
      ended: false,
      allowed: true,
      aspect: 16 / 9,
      stamps: stamps,
    ),
  );

  Future<void> pump({
    bool capability = true,
    Size view = const Size(1280, 800),
    Brightness brightness = Brightness.light,
  }) async {
    tester.view.physicalSize = view;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final cache = StampImageCache(
      fetchStill: (_) => throw UnimplementedError(),
      fetchOriginal: (_) => throw UnimplementedError(),
      customEmojiBytes: (_) => throw UnimplementedError(),
      customIndex: () => const {},
    );
    await tester.runAsync(() => cache.load(_party));
    container = ProviderContainer(
      overrides: [
        screenAnnotationFeedProvider.overrideWithValue(feed),
        voiceParticipantsProvider.overrideWithValue(const [_me, _sharer]),
        voiceFlagsProvider.overrideWithValue(
          const VoiceFlags(channelId: 'call'),
        ),
        syncControllerProvider.overrideWith(NoopSyncController.new),
        stampImageCacheProvider.overrideWithValue(cache),
        serverInfoProvider.overrideWith(
          (ref) async => api.Version.fromJson({
            'name': 'slim-m',
            'version': '0.130.0',
            'protocol': 1,
            'capabilities': [if (capability) 'screen_stamps'],
          }),
        ),
        sessionProvider.overrideWithValue(
          api.SessionStore(
            tokens: const api.TokenPair(
              userId: 'me',
              accessToken: 'a',
              refreshToken: 'r',
              accessExpiresAt: 4102444800000,
            ),
          ),
        ),
        mockApiOverride((request) async {
          paths.add(request.url.path);
          if (request.url.path.endsWith('/voice/screen-stamps')) {
            posts.add(jsonDecode(request.body) as Map<String, dynamic>);
            return answer();
          }
          return http.Response('{}', 200);
        }),
      ],
    );
    addTearDown(container.dispose);
    container.listen(serverInfoProvider, (_, _) {});
    final tokens = brightness == Brightness.light
        ? AppTokens.light
        : AppTokens.dark;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: RepaintBoundary(
          key: snapshotBoundary,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: buildTheme(brightness, tokens),
            home: Scaffold(
              body: Stack(
                children: [
                  Positioned.fromRect(
                    rect: _tile,
                    child: const ColoredBox(color: Color(0xFF20252B)),
                  ),
                  const ScreenAnnotateLayer(
                    sharerId: 'sharer',
                    sharerName: 'Ada',
                    tileRect: _tile,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  void arm() => container.read(armedStampProvider.notifier).arm(_party);

  Finder get stampButton => find.bySemanticsLabel("Stamp on Ada's screen");
}

void main() {
  setUpAll(loadRealFonts);

  testWidgets('the pill offers Stamp when the sharer and server take it', (
    tester,
  ) async {
    final rig = _Rig(tester)..allow();
    await rig.pump();
    expect(rig.stampButton, findsOneWidget);
  });

  testWidgets('an older sharer client gets no Stamp button', (tester) async {
    final rig = _Rig(tester)..allow(stamps: false);
    await rig.pump();
    expect(find.bySemanticsLabel("Draw on Ada's screen"), findsOneWidget);
    expect(rig.stampButton, findsNothing);
  });

  testWidgets('a server without stamps gets no Stamp button', (tester) async {
    final rig = _Rig(tester)..allow();
    await rig.pump(capability: false);
    expect(rig.stampButton, findsNothing);
  });

  testWidgets('with nothing armed, Stamp opens the picker', (tester) async {
    final rig = _Rig(tester)..allow();
    await rig.pump();
    await tester.tap(rig.stampButton);
    await tester.pump();
    await tester.pump(AppMotion.base);
    expect(find.text('Picture'), findsOneWidget);
    expect(find.text('Emoji'), findsOneWidget);
  });

  testWidgets('a tap places the default size at the tap, as a fraction', (
    tester,
  ) async {
    final rig = _Rig(tester)..allow();
    await rig.pump();
    rig.arm();
    await tester.tap(rig.stampButton);
    await tester.pump();
    await tester.tapAt(_tile.topLeft + const Offset(160, 90));
    await tester.pump();
    expect(rig.posts, hasLength(1));
    final body = rig.posts.single;
    expect(body['target_user_id'], 'sharer');
    expect(body['x'], closeTo(0.25, 1e-9));
    expect(body['y'], closeTo(0.25, 1e-9));
    expect(body['size'], stampDefaultSize);
    expect(body['emoji'], '\u{1F389}');
    expect(body.containsKey('attachment_id'), isFalse);
    expect(rig.feed.marksFor('sharer'), hasLength(1));
    expect(
      rig.paths.where((p) => p.contains('/canvas')),
      isEmpty,
      reason: 'a stamp on a share leaves nothing on the board',
    );
    await tester.pump(const Duration(seconds: 10));
  });

  testWidgets('a drag sizes around the press and sends only on release', (
    tester,
  ) async {
    final rig = _Rig(tester)..allow();
    await rig.pump();
    rig.arm();
    await tester.tap(rig.stampButton);
    await tester.pump();
    final gesture = await tester.startGesture(_tile.center);
    await gesture.moveBy(const Offset(20, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(16, 0));
    await tester.pump();
    expect(rig.posts, isEmpty);
    await gesture.up();
    await tester.pump();
    expect(rig.posts.single['size'], closeTo(2 * 36 / 360, 1e-9));
    expect(rig.posts.single['x'], closeTo(0.5, 1e-9));
    await tester.pump(const Duration(seconds: 10));
  });

  testWidgets('a long drag stops at the size cap', (tester) async {
    final rig = _Rig(tester)..allow();
    await rig.pump();
    rig.arm();
    await tester.tap(rig.stampButton);
    await tester.pump();
    await tester.dragFrom(_tile.center, const Offset(300, 0));
    await tester.pump();
    expect(rig.posts.single['size'], stampMaxSize);
    await tester.pump(const Duration(seconds: 10));
  });

  testWidgets('a refused stamp comes back off with its reason on the tile', (
    tester,
  ) async {
    final rig = _Rig(tester)..allow();
    rig.answer = () => http.Response(
      jsonEncode({'error': 'Their screen is not taking stamps right now'}),
      409,
      headers: const {'content-type': 'application/json'},
    );
    await rig.pump();
    rig.arm();
    await tester.tap(rig.stampButton);
    await tester.pump();
    await tester.tapAt(_tile.center);
    await tester.pump();
    await tester.pump();
    expect(rig.feed.marksFor('sharer'), isEmpty);
    expect(
      find.text('Their screen is not taking stamps right now.'),
      findsOneWidget,
    );
    await tester.pump(const Duration(seconds: 20));
  });

  testWidgets('a rate-limited stamp says to wait', (tester) async {
    final rig = _Rig(tester)..allow();
    rig.answer = () => http.Response(
      jsonEncode({'error': 'slow down'}),
      429,
      headers: const {'content-type': 'application/json'},
    );
    await rig.pump();
    rig.arm();
    await tester.tap(rig.stampButton);
    await tester.pump();
    await tester.tapAt(_tile.center);
    await tester.pump();
    await tester.pump();
    expect(find.text('Wait a moment before stamping again.'), findsOneWidget);
    await tester.pump(const Duration(seconds: 20));
  });

  testWidgets('a stamp from someone else pops in, holds and fades', (
    tester,
  ) async {
    final rig = _Rig(tester)..allow();
    await rig.pump();
    rig.feed.handle(
      const api.CanvasScreenAnnotation(
        channelId: 'call',
        userId: 'viewer-2',
        targetUserId: 'sharer',
        kind: 'stamp',
        annotationId: 's9',
        points: [0.5, 0.5],
        size: 0.2,
        emoji: '\u{1F389}',
        ended: true,
        allowed: false,
      ),
    );
    await tester.pump();
    await tester.pump();
    final mark = rig.feed.marksFor('sharer').single;
    expect(mark.readyAt, isNotNull);
    final box = tester.getRect(find.byKey(const ValueKey('s9')));
    expect(box.center, _tile.center);
    expect(box.size, const Size(72, 72));
    rig.now = rig.now.add(annotationStampHold + annotationFade);
    await tester.pump(const Duration(milliseconds: 50));
    expect(rig.feed.marksFor('sharer'), isEmpty);
    expect(find.byKey(const ValueKey('s9')), findsNothing);
  });
}
