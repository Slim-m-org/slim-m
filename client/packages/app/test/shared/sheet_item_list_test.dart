// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `SheetItemList` is what keeps a long-running pinned-messages or threads
/// sheet smooth while a live event rebuilds it: a short list still
/// shrink-wraps to its own content, but a list past
/// `sheetListShrinkWrapLimit` has to fall back to a plain bounded
/// `ListView` instead of the `shrinkWrap: true` a `ShrinkWrappingViewport`
/// needs to lay out every single item before it can even report its own
/// size.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/widgets/sheet_item_list.dart';

Widget _harness({required int itemCount, required void Function() onBuild}) {
  return MaterialApp(
    home: Scaffold(
      body: SizedBox(
        height: 400,
        width: 400,
        child: SheetItemList(
          itemCount: itemCount,
          itemBuilder: (context, i) {
            onBuild();
            return SizedBox(key: ValueKey(i), height: 56, child: Text('$i'));
          },
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('a count at or under the shrink-wrap limit still shrink-wraps', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(itemCount: sheetListShrinkWrapLimit, onBuild: () {}),
    );

    final list = tester.widget<ListView>(find.byType(ListView));
    expect(
      list.shrinkWrap,
      isTrue,
      reason: 'an ordinary short list must still size to its own content',
    );
  });

  testWidgets(
    'a count over the shrink-wrap limit uses a bounded viewport that only '
    'realizes the rows on screen',
    (tester) async {
      var builds = 0;
      await tester.pumpWidget(
        _harness(itemCount: 500, onBuild: () => builds++),
      );

      final list = tester.widget<ListView>(find.byType(ListView));
      expect(
        list.shrinkWrap,
        isFalse,
        reason:
            'a large backlog must not use shrinkWrap, which needs a full '
            'relayout of every item just to size itself',
      );
      expect(
        builds,
        lessThan(50),
        reason:
            'a bounded viewport must only build the handful of rows '
            'actually visible, not the whole 500-item backlog',
      );
    },
  );

  testWidgets(
    'growing past the limit while mounted switches away from shrinkWrap',
    (tester) async {
      var itemCount = 5;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) => Column(
                children: [
                  TextButton(
                    onPressed: () => setState(() => itemCount = 500),
                    child: const Text('grow'),
                  ),
                  SizedBox(
                    height: 400,
                    width: 400,
                    child: SheetItemList(
                      itemCount: itemCount,
                      itemBuilder: (context, i) => Text('$i'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );

      expect(tester.widget<ListView>(find.byType(ListView)).shrinkWrap, true);

      await tester.tap(find.text('grow'));
      await tester.pumpAndSettle();

      expect(tester.widget<ListView>(find.byType(ListView)).shrinkWrap, false);
    },
  );
}
