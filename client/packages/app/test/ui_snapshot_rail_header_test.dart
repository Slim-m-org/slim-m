// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Captures of the rail header: the connection dot as a badge on a Space icon,
/// and alone when the Space has none.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_app/src/widgets/channel_rail_frame.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

import 'ui_snapshot_support.dart';

class _StubSync extends SyncController {
  _StubSync(super.ref, SyncStatus status) {
    state = status;
  }

  @override
  Future<void> start() async {}
}

final _icons = <String, List<int>>{
  'colour': base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAABgAAAAYCAIAAABvFaqvAAAENklEQVR4nAXBsQpFYACAUY+jlFJKKaWUUkopJeovulGKwWAwGAwGg8FgMBgMBoPB4JG+57jnSCQyiUKikmgkOolBYpJYJDaJQ+KSeCQ+SUASkkQkMUlKIkgykh9JSVKR1BJCRigIFaEhdISBMBEWwkY4CBfhIXxEgAgRESJGpAiByBA/RImoELVELpMr5Cq5Rq6TG+QmuUVukzvkLrlH7pMH5CF5RB6Tp+SCPCP/kZfkFXktUcgUCoVKoVHoFAaFSWFR2BQOhUvhUfgUAUVIEVHEFCmFoMgofhQlRUVRS1QylUKlUmlUOpVBZVJZVDaVQ+VSeVQ+VUAVUkVUMVVKJagyqh9VSVVR1RKNTKPQqDQajU5j0Jg0Fo1N49C4NB6NTxPQhDQRTUyT0giajOZHU9JUNLVEK9MqtCqtRqvTGrQmrUVr0zq0Lq1H69MGtCFtRBvTprSCNqP90Za0FW0t0cl0Cp1Kp9HpdAadSWfR2XQOnUvn0fl0AV1IF9HFdCmdoMvofnQlXUVXS/QyvUKv0mv0Or1Bb9Jb9Da9Q+/Se/Q+fUAf0kf0MX1KL+gz+h99SV/R1xKDzKAwqAwag85gMJgMFoPN4DC4DB6DzxAwhAwRQ8yQMgiGjOHHUDJUDLXEKDMqjCqjxqgzGowmo8VoMzqMLqPH6DMGjCFjxBgzpoyCMWP8MZaMFWMtMclMCpPKpDHpTAaTyWQx2UwOk8vkMflMAVPIFDHFTCmTYMqYfkwlU8VUS8wys8KsMmvMOrPBbDJbzDazw+wye8w+c8AcMkfMMXPKLJgz5h9zyVwx1xKLzKKwqCwai85isJgsFovN4rC4LB6LzxKwhCwRS8ySsgiWjOXHUrJULLXEKrMqrCqrxqqzGqwmq8VqszqsLqvH6rMGrCFrxBqzpqyCNWP9sZasFWstsclsCpvKprHpbAabyWax2WwOm8vmsflsAVvIFrHFbCmbYMvYfmwlW8VWS+wyu8KusmvsOrvBbrJb7Da7w+6ye+w+e8AeskfsMXvKLtgz9h97yV6x1xKHzKFwqBwah85hcJgcFofN4XC4HB6HzxFwhBwRR8yRcgiOjOPHUXJUHLXEKXMqnCqnxqlzGpwmp8VpczqcLqfH6XMGnCFnxBlzppyCM+P8cZacFWctcclcCpfKpXHpXAaXyWVx2VwOl8vlcflcAVfIFXHFXCmX4Mq4flwlV8VVS9wyt8KtcmvcOrfBbXJb3Da3w+1ye9w+d8AdckfcMXfKLbgz7h93yV1x1xKPzKPwqDwaj85j8Jg8Fo/N4/C4PB6PzxPwhDwRT8yT8giejOfHU/JUPLXEK/MqvCqvxqvzGrwmr8Vr8zq8Lq/H6/MGvCFvxBvzpryCN+P98Za8FW8t8cl8Cp/Kp/HpfAafyWfx2XwOn8vn8fl8AV/IF/HFfCmf4Mv4fnwlX8VX/wHiBt9O/5z/HQAAAABJRU5ErkJggg==',
  ),
  'pale': base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAABgAAAAYCAIAAABvFaqvAAAAHUlEQVR4nGP4SiXAMGrQqEGjBo0aNGrQqEEDbxAAP3x2G7vgRmwAAAAASUVORK5CYII=',
  ),
};

/// The rail's own surface, which the dot's cut-out has to match.
class _RailBackdrop extends StatelessWidget {
  const _RailBackdrop({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 280,
    child: ColoredBox(
      color: Theme.of(context).extension<AppTokens>()!.surfaceSunken,
      child: child,
    ),
  );
}

Future<void> _capture(
  WidgetTester tester,
  String viewport,
  String theme,
  SyncStatus status,
  String? icon,
) async {
  SharedPreferences.setMockInitialValues(const {});
  tester.view.physicalSize = viewports[viewport]!;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(
        api.SessionStore(tokens: fixtureTokens),
      ),
      syncControllerProvider.overrideWith((ref) => _StubSync(ref, status)),
      apiProvider.overrideWith((ref) {
        final client = api.SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          session: ref.watch(sessionProvider),
          httpClient: MockClient((request) async {
            if (request.url.path == '/space/icon') {
              return http.Response.bytes(_icons[icon]!, 200);
            }
            return http.Response(
              jsonEncode({
                'name': 'Home',
                'version': '1',
                'protocol': 1,
                'icon_updated_at': ?(icon == null ? null : 5),
              }),
              200,
              headers: {'content-type': 'application/json'},
            );
          }),
        );
        ref.onDispose(client.close);
        return client;
      }),
    ],
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: RepaintBoundary(
        key: snapshotBoundary,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: theme == 'dark'
              ? buildTheme(Brightness.dark, AppTokens.dark)
              : buildTheme(Brightness.light, AppTokens.light),
          home: const Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: _RailBackdrop(child: RailHeader()),
            ),
          ),
        ),
      ),
    ),
  );
  for (var i = 0; i < 4; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    await tester.pump(const Duration(milliseconds: 200));
  }
  await writeSnapshot(
    tester,
    'rail-header-${icon ?? 'none'}-${status.name}-$viewport-$theme',
  );
  expect(tester.takeException(), isNull);

  container.dispose();
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  setUpAll(loadRealFonts);

  for (final theme in const ['dark', 'light']) {
    for (final viewport in phoneAndDesktop) {
      for (final icon in const [null, 'colour', 'pale']) {
        for (final status in SyncStatus.values) {
          testWidgets(
            'rail header, ${icon ?? 'no icon'}, ${status.name}, at $viewport ($theme)',
            (tester) => _capture(tester, viewport, theme, status, icon),
          );
        }
      }
    }
  }
}
