// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A channel settings row mounted over an in-memory store, for tests that
/// change the stored channel under it the way a socket frame would.
library;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_data/data.dart' show MessageStore, SlimmDatabase;
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

import '../../support/async_wait.dart';
import '../../support/fake_api.dart';
import 'channel_management_harness.dart' show tokens;

/// Mounts [child] with an api answered by [handler] and a store of its own.
Widget channelRowScope(
  Widget child,
  Future<http.Response> Function(http.Request) handler,
) => ProviderScope(
  overrides: [
    keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
    sessionProvider.overrideWithValue(api.SessionStore(tokens: tokens)),
    mockApiOverride(handler),
    storeProvider.overrideWith((ref) async {
      final db = SlimmDatabase(NativeDatabase.memory());
      ref.onDispose(db.close);
      return MessageStore(db);
    }),
  ],
  child: MaterialApp(
    theme: buildTheme(Brightness.light, AppTokens.light),
    home: Scaffold(body: SingleChildScrollView(child: child)),
  ),
);

/// The store [channelRowScope] built, read through the widget at [anchor].
Future<MessageStore> storeBehind(WidgetTester tester, Finder anchor) async {
  final container = ProviderScope.containerOf(tester.element(anchor));
  return (await tester.runAsync(() => container.read(storeProvider.future)))!;
}

/// Stores channel `c1` as [name], [topic] and [restricted], and lets its stream reach the row.
Future<void> emitChannel(
  WidgetTester tester,
  MessageStore store, {
  String name = 'general',
  String? topic,
  bool? restricted,
}) async {
  await tester.runAsync(() async {
    await store.upsertChannels([
      api.Channel(
        id: 'c1',
        name: name,
        kind: 'text',
        createdAt: 0,
        topic: topic,
        restricted: restricted,
      ),
    ]);
    await Future<void>.delayed(const Duration(milliseconds: 50));
  });
  await pumpFrames(tester);
}

/// Unmounts the row and lets the store's stream-cache timer run out.
Future<void> unmountRow(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 1));
}
