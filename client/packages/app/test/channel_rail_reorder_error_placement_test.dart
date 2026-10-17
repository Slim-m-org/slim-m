// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A failed reorder used to render as a banner pinned under the search box,
/// above the whole channel list - displacing every row to say a drag
/// somewhere below had failed. The owner: "why is that error appearing there
/// instead of ... very unusual to embed an error where it occurred". Per
/// `docs/decisions/0018-confirmation-toasts-and-why-errors-never-are.md` and
/// `docs/design/desktop-vs-mobile.md`'s own never-rule ("errors persist as an
/// `AppErrorState` attached to what failed"), the fix keeps the persistent
/// state but overlays it on the list itself rather than displacing content
/// above it - so this asserts geometry, not just that the error exists.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/channels/providers/channel_order_controller.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/routing/routes.dart';
import 'package:slimm_app/src/features/channels/widgets/channel_rail.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

import 'ui_snapshot_support.dart';

/// [fixtureResponse] answers every route with a real fixture, but has no
/// case for a failing reorder - every test that needs one failed request
/// still needs a real success shape for everything else the rail's own
/// streams and sections fetch.
MockClient _failingReorderClient() => MockClient((request) async {
  if (request.method == 'PUT' && request.url.path == '/channels/order') {
    return http.Response(jsonEncode({'error': 'nope'}), 400);
  }
  return fixtureResponse(request);
});

Future<({ProviderContainer container, SlimmDatabase db})> _pumpRail(
  WidgetTester tester,
  double width,
) async {
  tester.view.physicalSize = Size(width, 880);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final fixture = await fixtureContainer(
    extraOverrides: [
      apiProvider.overrideWith((ref) {
        final client = api.SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          session: ref.watch(sessionProvider),
          httpClient: _failingReorderClient(),
        );
        ref.onDispose(client.close);
        return client;
      }),
    ],
  );
  final router = GoRouter(
    initialLocation: Routes.channel('c-general'),
    routes: [
      GoRoute(
        path: Routes.channelPattern,
        builder: (context, state) => const Scaffold(body: ChannelRail()),
      ),
    ],
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: fixture.container,
      child: MaterialApp.router(
        debugShowCheckedModeBanner: false,
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        routerConfig: router,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return fixture;
}

void main() {
  for (final width in [390.0, 1400.0]) {
    testWidgets(
      'at ${width.toInt()}px, a failed reorder overlays the list instead of '
      'pushing the rows down, and does not move them',
      (tester) async {
        final fixture = await _pumpRail(tester, width);

        final rowBefore = tester.getTopLeft(find.text('general'));

        await fixture.container
            .read(channelOrderControllerProvider.notifier)
            .reorder(const [
              api.ChannelOrderGroup(
                categoryId: 'cat-text',
                channelIds: ['c-design', 'c-general'],
              ),
            ]);
        await tester.pumpAndSettle();

        expect(
          find.textContaining('Could not reorder channels'),
          findsOneWidget,
        );
        expect(
          tester.getTopLeft(find.text('general')),
          rowBefore,
          reason: 'the row must not jump when the error appears',
        );

        // Attached to the list, not the search box above it: its top sits below the row, not pinned above every row.
        final errorRect = tester.getRect(find.byType(AppErrorState));
        final rowRect = tester.getRect(find.text('general'));
        expect(errorRect.top, greaterThan(rowRect.bottom));

        await tester.tap(find.text('Dismiss'));
        await tester.pumpAndSettle();

        expect(find.byType(AppErrorState), findsNothing);
        expect(tester.getTopLeft(find.text('general')), rowBefore);

        await teardownFixture(tester, fixture.container, fixture.db);
      },
    );
  }
}
