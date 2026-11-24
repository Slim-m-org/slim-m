// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Renaming somebody else from the member card (decision 0055): the row only
/// where the gate allows it, the request it sends, and a failure that stays on
/// the sheet as a persistent error rather than a SnackBar.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/members/providers/member_presence.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/members/widgets/member_rename_sheet.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';
import '../../support/fake_api.dart';
import '../../support/toast_host.dart';

const _tokens = api.TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

api.UserProfile _profile({String? nickname}) => api.UserProfile(
  id: 'user-maya',
  username: 'maya',
  displayName: nickname ?? 'Maya',
  accountDisplayName: 'Maya',
  nickname: nickname,
  createdAt: 0,
);

Future<List<String>> _open(
  WidgetTester tester, {
  required api.UserProfile profile,
  int status = 204,
  Future<void>? hold,
  List<int>? memberReads,
}) async {
  tester.view.physicalSize = const Size(900, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final seen = <String>[];
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
        membersProvider.overrideWith((ref) async {
          memberReads?.add(memberReads.length);
          return [profile];
        }),
        mockApiOverride((request) async {
          seen.add('${request.method} ${request.url.path} ${request.body}');
          await hold;
          return http.Response(
            status == 204 ? '' : jsonEncode({'error': 'no'}),
            status,
            headers: {'content-type': 'application/json'},
          );
        }),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: Column(
            children: [
              Builder(
                builder: (context) => AppButton(
                  label: 'Open',
                  onPressed: () =>
                      showRenameMemberSheet(context, profile: profile),
                ),
              ),
              // A reader that outlives the sheet, so an invalidate refetches.
              Consumer(
                builder: (context, ref, _) {
                  ref.watch(membersProvider);
                  return const SizedBox.shrink();
                },
              ),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open'));
  await tester.pumpAndSettle();
  return seen;
}

void main() {
  testWidgets('saving puts the trimmed name and closes the sheet', (
    tester,
  ) async {
    final seen = await _open(tester, profile: _profile());

    await tester.enterText(find.byType(EditableText), '  House DJ ');
    await tester.pump();
    await tester.tap(find.text('Save name'));
    await tester.pumpAndSettle();

    expect(seen, [
      'PUT /members/user-maya/nickname ${jsonEncode({'nickname': 'House DJ'})}',
    ]);
    expect(find.text('Rename Maya'), findsNothing);
  });

  testWidgets('a save answered after the sheet closed still refreshes the '
      'members', (tester) async {
    final hold = Completer<void>();
    final reads = <int>[];
    final seen = await _open(
      tester,
      profile: _profile(),
      hold: hold.future,
      memberReads: reads,
    );
    await tester.enterText(
      find.byWidgetPredicate((w) => w is EditableText),
      'House DJ',
    );
    await tester.pump();
    await tester.tap(find.text('Save name'));
    await tester.runAsync(() async {
      while (seen.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    });
    final before = reads.length;

    await tester.tap(find.byTooltip('Close'));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('Rename Maya'), findsNothing);
    hold.complete();
    for (var i = 0; i < 200 && reads.length == before; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump();
    }

    expect(tester.takeException(), isNull);
    expect(reads.length, greaterThan(before));
  });

  testWidgets('says that their own name is untouched', (tester) async {
    await _open(tester, profile: _profile());

    expect(find.textContaining('Their own name, Maya'), findsOneWidget);
  });

  testWidgets('a refusal stays on the sheet as an error with no SnackBar', (
    tester,
  ) async {
    await _open(tester, profile: _profile(), status: 403);

    await tester.enterText(find.byType(EditableText), 'House DJ');
    await tester.pump();
    await tester.tap(find.text('Save name'));
    await tester.pumpAndSettle();

    expect(find.byType(AppErrorState), findsOneWidget);
    expect(errorToasts(tester), isEmpty);
    expect(find.text('Rename Maya'), findsOneWidget);
  });

  testWidgets('a renamed member offers Remove nickname, which deletes it', (
    tester,
  ) async {
    final seen = await _open(tester, profile: _profile(nickname: 'House DJ'));

    await tester.tap(find.text('Remove nickname'));
    await tester.pumpAndSettle();

    expect(seen, ['DELETE /members/user-maya/nickname ']);
  });

  testWidgets('a member with no nickname offers no Remove', (tester) async {
    await _open(tester, profile: _profile());

    expect(find.text('Remove nickname'), findsNothing);
  });

  testWidgets('an empty name cannot be saved', (tester) async {
    final seen = await _open(tester, profile: _profile());

    await tester.tap(find.text('Save name'));
    await tester.pumpAndSettle();

    expect(seen, isEmpty);
  });

  testWidgets('40 astral characters count as 40 and can be saved', (
    tester,
  ) async {
    final seen = await _open(tester, profile: _profile());

    await tester.enterText(find.byType(EditableText), '\u{1F600}' * 40);
    await tester.pump();
    expect(find.text('40/64'), findsOneWidget);
    await tester.tap(find.text('Save name'));
    await tester.pumpAndSettle();

    expect(seen, hasLength(1));
  });
}
