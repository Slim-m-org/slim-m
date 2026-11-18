// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What a stalled boot splash asks: it names other tabs only when one is open.
library;

import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/desktop/startup_screen.dart';
import 'package:slimm_app/src/widgets/mobile_boot_gate.dart';

class _Rig {
  _Rig({required bool anotherTab}) {
    watch = BootStallWatch(
      prompt: prompt,
      stillCovered: () => true,
      openAnyway: () {},
      reload: () => reloads++,
      anotherTabIsOpen: () async => anotherTab,
    );
  }

  final prompt = StateController<StartupPrompt?>(null);
  late final BootStallWatch watch;
  var reloads = 0;

  StartupPrompt stalled(FakeAsync async) {
    watch.arm();
    async.elapse(bootSplashPatience);
    return prompt.state!;
  }
}

void main() {
  test('with another tab open it asks to close it and reload', () {
    fakeAsync((async) {
      final rig = _Rig(anotherTab: true);
      final asked = rig.stalled(async);

      expect(asked.detail, 'Close slim-m in other tabs, then reload.');
      expect(asked.primaryLabel, 'Reload');
      asked.onPrimary();
      expect(rig.reloads, 1);
    });
  });

  test('with no other tab it never mentions tabs and keeps waiting rather '
      'than reloading', () {
    fakeAsync((async) {
      final rig = _Rig(anotherTab: false);
      final asked = rig.stalled(async);

      expect(asked.detail, isNot(contains('tab')));
      expect(asked.primaryLabel, 'Keep waiting');
      asked.onPrimary();
      expect(rig.prompt.state, isNull);
      expect(rig.reloads, 0);

      async.elapse(bootSplashPatience);
      expect(rig.prompt.state?.title, 'Still connecting');
    });
  });
}
