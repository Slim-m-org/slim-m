// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A thread is left out of the channel list on purpose, so a push for a thread
/// reply, or a link into one, names an id the list does not hold. The pane used
/// to read that as not found; it now asks the server whether it is a thread and
/// opens it under its parent channel.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_app/src/screens/channel_not_found.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

import 'home_shell_harness.dart';

/// The shell's quiet server, with `/channels/<id>/thread-parent` answered by
/// [threadParent]: a parent channel id for a thread, null for anything else,
/// and a 500 while [failing] is set.
class _Server {
  _Server({this.threadParent});

  final String? threadParent;
  bool failing = false;
  final requests = <String>[];
  final _quiet = quietClient();

  Future<http.Response> handle(http.Request request) async {
    requests.add(request.url.path);
    if (!request.url.path.endsWith('/thread-parent')) {
      return _quiet.get(request.url);
    }
    if (failing) return http.Response('boom', 500);
    return http.Response(
      jsonEncode({
        if (threadParent != null) ...{
          'parent_channel_id': threadParent,
          'parent_message_id': 'm1',
        },
        'parent_deleted': false,
      }),
      200,
      headers: {'content-type': 'application/json'},
    );
  }
}

Future<({ProviderContainer container, SlimmDatabase db, _Server server})> _open(
  WidgetTester tester,
  String location, {
  String? threadParent,
  bool failing = false,
}) async {
  final server = _Server(threadParent: threadParent)..failing = failing;
  final s = setup(
    httpClient: MockClient(server.handle),
    signedIn: true,
    extraOverrides: [initialSyncCompleteProvider.overrideWith((ref) => true)],
  );
  await MessageStore(s.db).upsertChannels([
    const api.Channel(id: 'c1', name: 'general', kind: 'text', createdAt: 0),
  ]);
  await pumpAtWidth(tester, s.container, 1400, location: location);
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump(const Duration(milliseconds: 50));
  return (container: s.container, db: s.db, server: server);
}

/// Where the app's own router is, read from the tree: the harness builds its
/// own router rather than using routerProvider.
String _location(WidgetTester tester) => GoRouter.of(
  tester.element(find.byType(Navigator).first),
).routerDelegate.currentConfiguration.last.matchedLocation;

void main() {
  testWidgets('a thread id opens the thread over its parent channel', (
    tester,
  ) async {
    final s = await _open(tester, '/channels/t1', threadParent: 'c1');

    expect(_location(tester), '/thread/t1');
    expect(find.byType(ChannelNotFound), findsNothing);
    await teardown(tester, s.container, s.db);
  });

  testWidgets('an id that is not a thread is still not found', (tester) async {
    final s = await _open(tester, '/channels/hidden');

    expect(find.byType(ChannelNotFound), findsOneWidget);
    expect(_location(tester), '/channels/hidden');
    await teardown(tester, s.container, s.db);
  });

  testWidgets('a failed lookup says so with Retry, and Retry recovers', (
    tester,
  ) async {
    final s = await _open(
      tester,
      '/channels/t1',
      threadParent: 'c1',
      failing: true,
    );
    expect(find.byType(ChannelNotFound), findsNothing);
    expect(find.text('Could not open this channel.'), findsOneWidget);

    s.server.failing = false;
    await tester.tap(find.text('Retry'));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));

    expect(_location(tester), '/thread/t1');
    await teardown(tester, s.container, s.db);
  });

  testWidgets('a listed channel never asks', (tester) async {
    final s = await _open(tester, '/channels/c1');

    expect(
      s.server.requests.where((path) => path.endsWith('/thread-parent')),
      isEmpty,
    );
    expect(find.byType(AppErrorState), findsNothing);
    await teardown(tester, s.container, s.db);
  });
}
