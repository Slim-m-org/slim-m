// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A deployment with a few hundred custom emoji pushes the picker grid past
/// what `Class::Asset` can absorb from one screen if every visible cell
/// fires its image fetch at once (`emoji_catalog_provider.dart`'s own doc
/// comment on `emojiImageFetchConcurrencyCap` has the budget arithmetic).
/// This pins the fix at that scale: build the real grid over a transport
/// that counts overlapping requests, and check the observed peak never
/// climbs past the cap while every cell that mounts still resolves.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/emoji/providers/emoji_catalog_provider.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/emoji/widgets/emoji_catalog.dart';
import 'package:slimm_app/src/features/emoji/widgets/emoji_picker_grid.dart';
import 'package:slimm_design_system/design_system.dart';
import '../../support/fake_api.dart';

/// A 1x1 transparent PNG, so `Image.memory` decodes rather than throwing.
final _png = Uint8List.fromList(
  base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8'
    'z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
  ),
);

/// Two packs' worth, so a lazy grid still has far more off-screen cells than
/// [emojiImageFetchConcurrencyCap] to draw the peak from.
const _emojiCount = 300;

List<DeploymentEmoji> _catalog() => [
  for (var i = 0; i < _emojiCount; i++)
    DeploymentEmoji(
      api.CustomEmoji(
        id: 'e-$i',
        name: 'emoji_$i',
        uploaderId: 'u1',
        createdAt: 1,
      ),
    ),
];

void main() {
  testWidgets(
    'never lets more than emojiImageFetchConcurrencyCap image fetches run '
    'at once, and every mounted cell still resolves rather than erroring',
    (tester) async {
      var inFlight = 0;
      var maxInFlight = 0;

      final container = ProviderContainer(
        overrides: [
          sessionProvider.overrideWithValue(
            api.SessionStore(
              tokens: const api.TokenPair(
                userId: 'u1',
                accessToken: 'a',
                refreshToken: 'r',
                accessExpiresAt: 9999999999999,
              ),
            ),
          ),
          mockApiOverride((request) async {
            inFlight++;
            maxInFlight = inFlight > maxInFlight ? inFlight : maxInFlight;
            await Future<void>.delayed(const Duration(milliseconds: 20));
            inFlight--;
            return http.Response.bytes(
              _png,
              200,
              headers: {'content-type': 'image/png'},
            );
          }),
        ],
      );
      addTearDown(container.dispose);

      await tester.runAsync(() async {
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: buildTheme(Brightness.light, AppTokens.light),
              home: Scaffold(
                body: SizedBox(
                  height: 260,
                  child: EmojiGrid(
                    emoji: _catalog(),
                    highlighted: -1,
                    onTap: (_) {},
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        // Real time for every mounted cell's fetch to clear the real MockClient delay above.
        await Future<void>.delayed(const Duration(milliseconds: 500));
      });
      // Every fetch already cleared in real time above; this just flushes it into the tree.
      await tester.pump();

      expect(
        maxInFlight,
        lessThanOrEqualTo(emojiImageFetchConcurrencyCap),
        reason:
            'a picker full of custom emoji must never fire more than the '
            'cap of concurrent fetches, no matter how many cells mount',
      );
      expect(
        maxInFlight,
        emojiImageFetchConcurrencyCap,
        reason:
            'the grid mounts well over the cap worth of cells at once, '
            'so an uncapped fetcher would have shown a higher peak here',
      );
      expect(
        find.byIcon(AppIcons.imageMissing),
        findsNothing,
        reason:
            'queued past the cap is not the same as rejected: every '
            'mounted cell must still resolve its image',
      );
      expect(find.byType(Image), findsWidgets);
    },
  );
}
