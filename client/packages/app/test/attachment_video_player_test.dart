// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [AttachmentVideoPlayer] constructs a real `media_kit` [Player] the moment
/// it mounts (see the widget's own field initializer), so every test here
/// needs [MediaKit.ensureInitialized] and a real libmpv on the machine
/// running it - `client-ci.yml`'s test job installs the runtime `libmpv2` for exactly
/// this. What is tested never needs that player to actually open anything:
/// a caller with no access token fails inside `AttachmentVideoSource.open`
/// itself, before `Player.open` is ever reached, so this is deterministic
/// rather than dependent on a real network fetch settling in time.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/widgets/attachment_video_player.dart';
import 'package:slimm_app/src/widgets/attachment_video_source.dart';
import 'package:slimm_design_system/design_system.dart';

const _video = api.Attachment(
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
class _ScriptedSource implements AttachmentVideoSource {
  _ScriptedSource(this._outcomes);

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

Future<void> _pumpPlayer(WidgetTester tester, _ScriptedSource source) {
  return tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiProvider.overrideWithValue(
          api.SlimmApi(baseUrl: Uri.parse('http://localhost:1')),
        ),
        attachmentVideoSourceProvider.overrideWithValue(() => source),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: const Scaffold(body: AttachmentVideoPlayer(attachment: _video)),
      ),
    ),
  );
}

void main() {
  setUpAll(MediaKit.ensureInitialized);

  testWidgets(
    'a failed load offers Retry, and retrying opens the source again',
    (tester) async {
      final source = _ScriptedSource([Exception('boom')]);
      await _pumpPlayer(tester, source);
      await tester.pump();
      await tester.pump();

      expect(find.text('Could not load ${_video.filename}.'), findsOneWidget);
      final retry = find.text('Retry');
      expect(retry, findsOneWidget);

      await tester.tap(retry);
      await tester.pump();

      expect(source.opens, 2);
    },
  );

  testWidgets('disposing the player disposes its source', (tester) async {
    final source = _ScriptedSource([Exception('boom')]);
    await _pumpPlayer(tester, source);
    await tester.pump();
    expect(source.disposed, isFalse);

    await tester.pumpWidget(const SizedBox());

    expect(source.disposed, isTrue);
  });

  testWidgets('signed out surfaces the load failure through AppErrorState', (
    tester,
  ) async {
    final signedOut = api.SlimmApi(baseUrl: Uri.parse('http://localhost:1'));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [apiProvider.overrideWithValue(signedOut)],
        child: MaterialApp(
          theme: buildTheme(Brightness.light, AppTokens.light),
          home: const Scaffold(body: AttachmentVideoPlayer(attachment: _video)),
        ),
      ),
    );
    await tester.pump();

    // Still loading here (the failure lands on the next pump).
    expect(
      find.byWidgetPredicate(
        (w) => w is CircularProgressIndicator && w.value == null,
      ),
      findsNothing,
    );
    expect(find.text('Loading video…'), findsOneWidget);

    await tester.pump();

    expect(
      find.text(
        'Could not load ${_video.filename}: you are signed out. '
        'Sign in and try again.',
      ),
      findsOneWidget,
    );
    expect(find.byType(Video), findsNothing);
  });
}
