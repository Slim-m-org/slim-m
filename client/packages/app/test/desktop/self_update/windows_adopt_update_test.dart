// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_app/src/desktop/relaunch.dart';
import 'package:slimm_app/src/desktop/self_update/self_update.dart';
import 'package:slimm_app/src/desktop/self_update/self_update_controller.dart';
import 'package:slimm_app/src/desktop/self_update/self_update_failure.dart';
import 'package:slimm_app/src/desktop/self_update/windows_adopt.dart';
import 'package:slimm_app/src/desktop/update_action.dart';
import 'package:slimm_app/src/desktop/update_check.dart';
import 'package:slimm_app/src/desktop/windows_adopt_confirm.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

const _release = 'https://example.test/release';

String? _read(Directory root, String name) {
  final file = File('${root.path}/$name');
  return file.existsSync() ? file.readAsStringSync() : null;
}

Future<void> _fakeUnpack(File archive, Directory into) async =>
    File('${into.path}/slimm_app.exe').writeAsStringSync('new');

void main() {
  late Directory temp;
  late Directory bundle;
  late Directory root;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('slimm-windows-adopt-update-');
    bundle = Directory('${temp.path}/unzipped')..createSync();
    File('${bundle.path}/slimm_app.exe').writeAsStringSync('app');
    File('${bundle.path}/slim-m.exe').writeAsStringSync('launcher');
    root = Directory('${temp.path}/local/slim-m');
  });
  tearDown(() {
    relaunchLauncherOverride = null;
    temp.deleteSync(recursive: true);
  });

  const update = ClientUpdate(
    version: '0.90.0',
    releaseUrl: _release,
    format: InstallFormat.tarball,
  );

  group('which action a bare windows copy gets', () {
    test('adopts and installs, then restarts once staged', () {
      expect(
        updateMenuAction(update, adoptable: true),
        UpdateMenuAction.adoptAndInstall,
      );
      expect(
        updateMenuAction(update, adoptable: true, staged: '0.90.0'),
        UpdateMenuAction.restartToUpdate,
      );
    });

    test('a copy already in the layout installs without adopting', () {
      expect(
        updateMenuAction(update, selfApplies: true),
        UpdateMenuAction.installAndRestart,
      );
    });

    test('a copy that cannot adopt keeps the release page', () {
      expect(updateMenuAction(update), UpdateMenuAction.openRelease);
    });

    test('says what it is doing in the label', () {
      expect(
        updateActionLabel(
          update,
          UpdateMenuAction.adoptAndInstall,
          installing: false,
        ),
        'Install 0.90.0',
      );
      expect(
        updateActionLabel(
          update,
          UpdateMenuAction.adoptAndInstall,
          installing: true,
        ),
        'Installing 0.90.0',
      );
    });
  });

  group('SelfUpdateController.adoptAndInstall', () {
    ProviderContainer containerWith(FetchUpdate fetch, {List<String>? order}) {
      final container = ProviderContainer(
        overrides: [
          selfUpdateProvider.overrideWith(
            (ref) => SelfUpdateController(
              ref,
              fetch: fetch,
              unpack: _fakeUnpack,
              newClient: http.Client.new,
              adopt:
                  ({
                    required executable,
                    required version,
                    required root,
                  }) async {
                    order?.add('adopt');
                    return adoptWindowsInstall(
                      executable: executable,
                      version: version,
                      root: root,
                      createShortcut: (_) async {},
                    );
                  },
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    test('moves the copy into the layout, then updates from there', () async {
      final order = <String>[];
      final container = containerWith(({
        required currentVersion,
        required platformKey,
        required stagingDir,
        required client,
      }) async {
        order.add('fetch');
        expect(stagingDir.path, '${root.path}/.staging');
        final file = File('${stagingDir.path}/pkg.zip')
          ..createSync(recursive: true);
        return VerifiedUpdate.forTest(
          version: '0.90.0',
          tag: 'client-v0.90.0',
          file: file,
        );
      }, order: order);

      final version = await container
          .read(selfUpdateProvider)
          .adoptAndInstall(
            currentVersion: '0.89.0',
            releaseUrl: _release,
            executable: '${bundle.path}/slimm_app.exe',
            root: root,
          );

      expect(version, '0.90.0');
      expect(order, ['adopt', 'fetch']);
      expect(_read(root, 'current'), '0.90.0');
      expect(_read(root, 'previous'), '0.89.0');
      expect(File('${root.path}/app-0.89.0/slimm_app.exe').existsSync(), true);
      expect(File('${root.path}/app-0.90.0/slimm_app.exe').existsSync(), true);
      expect(container.read(stagedUpdateVersionProvider), '0.90.0');
      expect(relaunchLauncherOverride, '${root.path}/slim-m.exe');
      expect(container.read(selfUpdateFailureProvider), isNull);
      expect(container.read(selfUpdateInstallingProvider), isFalse);
    });

    test('a copy that cannot move falls back to the release page', () async {
      File('${bundle.path}/slim-m.exe').deleteSync();
      var fetched = false;
      final container = containerWith(({
        required currentVersion,
        required platformKey,
        required stagingDir,
        required client,
      }) async {
        fetched = true;
        return null;
      });

      final version = await container
          .read(selfUpdateProvider)
          .adoptAndInstall(
            currentVersion: '0.89.0',
            releaseUrl: _release,
            executable: '${bundle.path}/slimm_app.exe',
            root: root,
          );

      final failure = container.read(selfUpdateFailureProvider);
      expect(version, isNull);
      expect(fetched, isFalse);
      expect(failure?.kind, SelfUpdateFailureKind.unsupportedInstall);
      expect(failure?.releaseUrl, _release);
      expect(
        root.existsSync() && File('${root.path}/current').existsSync(),
        false,
      );
      expect(relaunchLauncherOverride, isNull);
      expect(container.read(selfUpdateInstallingProvider), isFalse);
    });

    test('a failed download leaves the adopted copy and shows why', () async {
      final container = containerWith(
        ({
          required currentVersion,
          required platformKey,
          required stagingDir,
          required client,
        }) async => throw const SelfUpdateFailure(
          SelfUpdateFailureKind.checksumMismatch,
          'The download did not match.',
        ),
      );

      final version = await container
          .read(selfUpdateProvider)
          .adoptAndInstall(
            currentVersion: '0.89.0',
            releaseUrl: _release,
            executable: '${bundle.path}/slimm_app.exe',
            root: root,
          );

      expect(version, isNull);
      expect(
        container.read(selfUpdateFailureProvider)?.kind,
        SelfUpdateFailureKind.checksumMismatch,
      );
      expect(_read(root, 'current'), '0.89.0');
      expect(container.read(stagedUpdateVersionProvider), isNull);
    });
  });

  group('the confirmation', () {
    Future<bool?> ask(WidgetTester tester, String button) async {
      bool? answer;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(Brightness.dark, AppTokens.dark),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async =>
                    answer = await confirmWindowsAdopt(context),
                child: const Text('go'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      expect(find.text('Move slim-m to update it?'), findsOneWidget);
      await tester.tap(find.text(button));
      await tester.pumpAndSettle();
      return answer;
    }

    testWidgets('moving is a yes', (tester) async {
      expect(await ask(tester, 'Move and update'), isTrue);
    });

    testWidgets('cancel leaves everything alone', (tester) async {
      expect(await ask(tester, 'Cancel'), isFalse);
    });
  });
}
