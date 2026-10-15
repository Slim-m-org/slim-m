// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A retry resumes a staged upload under the same key, and removing a failed
/// one lets the server copy go.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/widgets/composer_attachments.dart';

void main() {
  test('a retry resumes under the same key, and removing a failed upload '
      'abandons it', () async {
    final keys = <String>[];
    final abandoned = <String>[];
    final staging = AttachmentStagingController(
      upload: (body, filename, report) async {
        keys.add(report.resumeKey);
        throw const api.UnavailableException('down');
      },
      onAbandon: abandoned.add,
    );
    addTearDown(staging.dispose);

    await staging.stage(Uint8List(10), 'a.bin');
    await pumpEventQueue();
    final id = staging.items.single.localId;
    staging.retry(id);
    await pumpEventQueue();
    expect(keys, hasLength(2));
    expect(keys.toSet(), hasLength(1), reason: 'one file, one resume key');

    staging.remove(id);
    expect(abandoned, [keys.first]);
  });
}
