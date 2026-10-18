// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Settings follow the Space on a real switch; device-wide ones do not.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/features/messages/providers/image_cache_preference.dart';
import 'package:slimm_app/src/features/settings/providers/display_density.dart';
import 'package:slimm_app/src/providers/startup_restores.dart';
import 'package:slimm_design_system/design_system.dart' show AppDensity;

import 'account_host_harness.dart';

const _a = 'https://first.example';
const _b = 'https://second.example';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('a switch shows each Space\'s own values', () async {
    final h = AccountHarness();
    await h.seed(_a, user: 'ann', active: true);
    await h.seed(_b, user: 'bea');
    await h.boot();
    addTearDown(h.dispose);

    final a = h.host.runtimeFor(_a)!.container;
    final b = h.host.runtimeFor(_b)!.container;
    await a
        .read(messageDensityControllerProvider.notifier)
        .select(AppDensity.compact);
    await b
        .read(messageDensityControllerProvider.notifier)
        .select(AppDensity.spacious);
    await a.read(imageCacheLimitControllerProvider.notifier).select(200);

    await h.host.switchTo(_b);
    await resyncSharedPreferences(h.host.active!.container);
    expect(
      h.host.active!.container.read(messageDensityControllerProvider),
      AppDensity.spacious,
    );
    expect(
      h.host.active!.container.read(imageCacheLimitControllerProvider),
      200,
    );

    await h.host.switchTo(_a);
    await resyncSharedPreferences(h.host.active!.container);
    expect(
      h.host.active!.container.read(messageDensityControllerProvider),
      AppDensity.compact,
    );
    expect(
      h.host.active!.container.read(imageCacheLimitControllerProvider),
      200,
    );
  });
}
