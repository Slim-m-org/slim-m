// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A gif the server answers with a first-frame still costs only that still
/// until it plays; the moving original is fetched when it starts to.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/messages/providers/attachment_bytes.dart';
import 'package:slimm_app/src/features/messages/providers/attachment_preview_bytes.dart';
import 'package:slimm_app/src/features/messages/providers/media_preferences.dart';
import 'package:slimm_app/src/features/messages/widgets/attachment_reveal.dart';
import 'package:slimm_app/src/features/messages/widgets/attachment_view.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';

const _gif = api.Attachment(
  id: 'g1',
  filename: 'loop.gif',
  contentType: 'image/gif',
  size: 4000000,
);

final _original = base64Decode(
  'R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7',
);

final _still = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60'
  'e6kgAAAABJRU5ErkJggg==',
);

class _Requests {
  int stills = 0;
  int originals = 0;
}

ProviderContainer _container(_Requests requests) {
  SharedPreferences.setMockInitialValues({});
  final container = ProviderContainer(
    overrides: [
      preferencesProvider.overrideWith(
        (ref) => SharedPreferences.getInstance(),
      ),
      attachmentPreviewBytesProvider.overrideWith((ref, key) async {
        requests.stills++;
        return Uint8List.fromList(_still);
      }),
      attachmentBytesProvider(_gif.id).overrideWith((ref) async {
        requests.originals++;
        return Uint8List.fromList(_original);
      }),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

Future<void> _pump(WidgetTester tester, ProviderContainer container) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: const Scaffold(body: AttachmentView(attachment: _gif)),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a gif held for a tap requests only the still until it plays', (
    tester,
  ) async {
    final requests = _Requests();
    final container = _container(requests);
    await container
        .read(gifAutoplayControllerProvider.notifier)
        .select(GifAutoplay.tapToPlay);

    await _pump(tester, container);

    expect(requests.stills, 1);
    expect(requests.originals, 0, reason: 'held: no need for the animation');

    await tester.tap(find.byIcon(AppIcons.play));
    await tester.pumpAndSettle();

    expect(requests.originals, 1, reason: 'the tap plays it');
  });

  testWidgets('a gif that plays on sight fetches the original', (tester) async {
    final requests = _Requests();
    final container = _container(requests);

    await _pump(tester, container);

    expect(requests.originals, 1);
  });

  testWidgets('an unfocused window holds the still and asks for nothing more', (
    tester,
  ) async {
    final requests = _Requests();
    final container = _container(requests);
    final binding = TestWidgetsFlutterBinding.instance;
    addTearDown(
      () => binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed),
    );
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);

    await _pump(tester, container);

    expect(requests.originals, 0);
    expect(find.byType(AttachmentFirstFrame), findsOneWidget);

    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();

    expect(requests.originals, 1, reason: 'focus back, so it plays');
  });
}
