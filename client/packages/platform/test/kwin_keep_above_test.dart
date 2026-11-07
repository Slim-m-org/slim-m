// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_platform/src/kwin_keep_above.dart';

void main() {
  test('the script names this process and the exact title', () {
    final script = keepAboveScript(pid: 4242, caption: 'slim-m pop-out');
    expect(script, contains('w.pid === 4242'));
    expect(script, contains("w.caption === 'slim-m pop-out'"));
    expect(script, contains('w.keepAbove = true'));
  });

  test('a quote in the title cannot end the script string', () {
    final script = keepAboveScript(pid: 1, caption: "it's \\ here");
    expect(script, contains(r"w.caption === 'it\'s \\ here'"));
  });

  test('works on Plasma 5 as well as 6', () {
    expect(keepAboveScript(pid: 1, caption: 'x'),
        contains('workspace.clientList()'));
  });

  test('the full screen rule joins an existing rule list once', () {
    expect(withRule('', 'r'), 'r');
    expect(withRule('a,b', 'r'), 'a,b,r');
    expect(withRule('a, r ,b', 'r'), 'a,r,b');
  });
}
