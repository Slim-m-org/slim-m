// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A run that has proved its own version stops counting as a pending start even while a successor installs.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_app/src/desktop/self_update/self_update_controller.dart';
import 'package:slimm_app/src/desktop/self_update/self_update.dart';
import 'package:slimm_platform/platform.dart';

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('slimm-running-proven-');
    for (final name in ['slimm_app', 'slim-m']) {
      File('${root.path}/0.88.0/$name')
        ..createSync(recursive: true)
        ..writeAsStringSync('#!/bin/sh\nexit 0\n');
    }
    Link('${root.path}/current').createSync('0.88.0');
  });
  tearDown(() => root.deleteSync(recursive: true));

  ProviderContainer containerWith(FetchUpdate fetch) {
    final container = ProviderContainer(
      overrides: [
        selfUpdateProvider.overrideWith(
          (ref) => SelfUpdateController(
            ref,
            fetch: fetch,
            newClient: http.Client.new,
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  test(
    'confirmStart clears the marker of the running version while its successor installs',
    () async {
      File('${root.path}/pending').writeAsStringSync('0.88.0');
      File('${root.path}/pending.tries').writeAsStringSync('1');
      final release = Completer<VerifiedUpdate?>();
      final container = containerWith(
        ({
          required currentVersion,
          required platformKey,
          required stagingDir,
          required client,
        }) => release.future,
      );
      final controller = container.read(selfUpdateProvider);
      final install = controller.install(
        currentVersion: '0.88.0',
        format: InstallFormat.tarball,
        resolvedExecutable: '${root.path}/0.88.0/slimm_app',
        os: 'linux',
      );

      final settled = controller.confirmStart(
        resolvedExecutable: '${root.path}/0.88.0/slimm_app',
        os: 'linux',
        settle: const Duration(milliseconds: 20),
      );
      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(File('${root.path}/pending').existsSync(), isFalse);
      expect(File('${root.path}/pending.tries').existsSync(), isFalse);
      release.complete(null);
      await install;
      await settled;
    },
  );
}
