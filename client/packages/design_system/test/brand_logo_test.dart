// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_design_system/design_system.dart';

void main() {
  for (final service in BrandService.values) {
    testWidgets('${service.label} logo loads its bundled asset',
        (tester) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: BrandLogo(service, key: Key(service.asset), size: 24),
        ),
      );
      expect(find.byKey(Key(service.asset)), findsOneWidget);
      final picture = tester.widget<SvgPicture>(find.descendant(
          of: find.byKey(Key(service.asset)),
          matching: find.byWidgetPredicate((w) => w is SvgPicture)));
      expect(picture.width, 24);
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      expect(tester.takeException(), isNull);
    });
  }
}
