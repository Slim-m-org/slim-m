// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `pickGif`'s own race: its second fetch (the newly staged tile's local
/// preview bytes) can still be in flight when whatever hosted the picker is
/// torn down. Nothing here goes through `Composer` - only the seam
/// `pickGif` itself owns, so the race is driven directly rather than raced
/// against a real widget's own timing.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/widgets/composer_attachments.dart';
import 'package:slimm_app/src/widgets/gif_picker.dart';
import 'package:slimm_design_system/design_system.dart';

const _tokens = api.TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

final _gifBytes = base64Decode(
  'R0lGODlhAQABAAAAACH5BAEKAAEALAAAAAABAAEAAAICTAEAOw==',
);

/// Search, preview and select all answer immediately; only the final
/// attachment fetch - the one `pickGif` makes after `onPicked` runs - waits
/// on [gate], so a test can dispose the picker's host while it is pending.
api.SlimmApi Function(Ref) _gatedGifApi(Completer<void> gate) =>
    (ref) => api.SlimmApi(
      baseUrl: Uri.parse('http://localhost:8080'),
      session: ref.watch(sessionProvider),
      httpClient: MockClient((request) async {
        final path = request.url.path;
        if (request.method == 'GET' && path == '/gifs/trending') {
          return http.Response(
            jsonEncode({'results': <Object?>[]}),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (request.method == 'GET' && path == '/gifs/search') {
          return http.Response(
            jsonEncode({
              'results': [
                {
                  'id': 'tok-1',
                  'title': 'a cat waving',
                  'width': 200,
                  'height': 150,
                },
              ],
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (request.method == 'GET' && path == '/gifs/preview/tok-1') {
          return http.Response.bytes(
            _gifBytes,
            200,
            headers: {'content-type': 'image/gif'},
          );
        }
        if (request.method == 'POST' && path == '/gifs/select') {
          return http.Response(
            jsonEncode({
              'id': 'gif-attachment-id',
              'filename': 'gif.gif',
              'content_type': 'image/gif',
              'size': _gifBytes.length,
            }),
            201,
            headers: {'content-type': 'application/json'},
          );
        }
        if (request.method == 'GET' &&
            path == '/attachments/gif-attachment-id') {
          await gate.future;
          return http.Response.bytes(
            _gifBytes,
            200,
            headers: {'content-type': 'image/gif'},
          );
        }
        return http.Response(
          '{}',
          404,
          headers: {'content-type': 'text/plain'},
        );
      }),
    );

/// A minimal host that owns both the [BuildContext] and the
/// [AttachmentStagingController] `pickGif` is handed, exactly the way
/// `Composer` owns both of them for real - so removing this widget from the
/// tree disposes the controller and unmounts the context together.
class _Host extends ConsumerStatefulWidget {
  const _Host({required this.onError});

  final ValueChanged<String?> onError;

  @override
  ConsumerState<_Host> createState() => _HostState();
}

class _HostState extends ConsumerState<_Host> {
  late final attachments = AttachmentStagingController(
    upload: (bytes, filename, _) async => throw UnimplementedError(),
  );

  @override
  void dispose() {
    attachments.dispose();
    super.dispose();
  }

  Future<void> _open() => pickGif(
    context: context,
    ref: ref,
    attachments: attachments,
    onError: widget.onError,
  );

  @override
  Widget build(BuildContext context) => ElevatedButton(
    onPressed: () => unawaited(_open()),
    child: const Text('open'),
  );
}

/// Lets the test remove [_Host] from the tree on demand, the same way a
/// route pop or a channel switch removes the real composer.
class _ToggleHost extends StatefulWidget {
  const _ToggleHost({super.key, required this.child});

  final Widget child;

  @override
  State<_ToggleHost> createState() => _ToggleHostState();
}

class _ToggleHostState extends State<_ToggleHost> {
  bool _show = true;

  void hide() => setState(() => _show = false);

  @override
  Widget build(BuildContext context) =>
      _show ? widget.child : const SizedBox.shrink();
}

void main() {
  testWidgets(
    'a fetch that resolves after the host is disposed is dropped, not thrown',
    (tester) async {
      final gate = Completer<void>();
      String? reportedError;
      final toggleKey = GlobalKey<_ToggleHostState>();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sessionProvider.overrideWithValue(
              api.SessionStore(tokens: _tokens),
            ),
            apiProvider.overrideWith(_gatedGifApi(gate)),
          ],
          child: MaterialApp(
            theme: buildTheme(Brightness.dark, AppTokens.dark),
            home: Scaffold(
              body: _ToggleHost(
                key: toggleKey,
                child: _Host(onError: (message) => reportedError = message),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'cat');
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();

      final tile = find.byWidgetPredicate(
        (w) => w is Semantics && w.properties.label == 'Pick: a cat waving',
      );
      expect(tile, findsOneWidget);
      await tester.tap(tile);
      // Past selectGif and the sheet's own closing animation, leaving the gated attachment fetch as the only thing still in flight.
      await tester.pumpAndSettle();

      toggleKey.currentState!.hide();
      await tester.pump();

      gate.complete();
      await tester.pump();
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(reportedError, isNull);
    },
  );
}
