// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Unit coverage for the composer's drop-target wiring: what counts as
/// "attachments allowed here", and what a raw drop list turns into once
/// [ComposerAttachmentDropTarget] is reached.
///
/// Kept independent of any widget tree - both functions here are plain, so a
/// permission matrix or a folder-in-the-drop case never needs a real drag
/// event to exercise.
library;

import 'dart:typed_data';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/providers/composer_attachment_drop.dart';
import 'package:slimm_app/src/widgets/channel_attachment_drop_zone.dart';

/// Records every stage call and the last error set, standing in for the real
/// composer's own [ComposerAttachmentDropTarget.stage]/`setError`.
class _FakeTarget {
  final List<String> staged = [];
  String? lastError;

  ComposerAttachmentDropTarget get value => ComposerAttachmentDropTarget(
    stage: (bytes, filename) async => staged.add(filename),
    stageFile: (file) async => staged.add(file.name),
    setError: (message) => lastError = message,
  );
}

void main() {
  group('canDropAttachments', () {
    const both = Perm.sendMessages | Perm.attachFiles;

    test('both bits and no block allows it', () {
      expect(canDropAttachments(permissions: both, blockedDm: false), isTrue);
    });

    test('a blocked DM refuses it even with both bits', () {
      expect(canDropAttachments(permissions: both, blockedDm: true), isFalse);
    });

    test('attachFiles alone is not enough', () {
      expect(
        canDropAttachments(permissions: Perm.sendMessages, blockedDm: false),
        isFalse,
      );
    });

    test('sendMessages alone is not enough', () {
      expect(
        canDropAttachments(permissions: Perm.attachFiles, blockedDm: false),
        isFalse,
      );
    });

    test('no permissions at all refuses it', () {
      expect(canDropAttachments(permissions: 0, blockedDm: false), isFalse);
    });
  });

  group('handleComposerDrop', () {
    test('a null target (no composer mounted) is a no-op', () async {
      await handleComposerDrop([], null);
    });

    test('stages a plain file through the target', () async {
      final fake = _FakeTarget();
      final file = DropItemFile.fromData(
        Uint8List.fromList([1, 2, 3]),
        path: 'holiday.png',
      );
      await handleComposerDrop([file], fake.value);
      expect(fake.staged, ['holiday.png']);
      expect(fake.lastError, isNull);
    });

    test('a folder is refused with a reason and never staged', () async {
      final fake = _FakeTarget();
      final folder = DropItemDirectory('/some/dir', const []);
      await handleComposerDrop([folder], fake.value);
      expect(fake.staged, isEmpty);
      expect(fake.lastError, isNotNull);
    });

    test(
      'a folder dropped alongside a real file still stages the file',
      () async {
        final fake = _FakeTarget();
        final folder = DropItemDirectory('/some/dir', const []);
        final file = DropItemFile.fromData(
          Uint8List.fromList([1]),
          path: 'ok.png',
        );
        await handleComposerDrop([folder, file], fake.value);
        expect(fake.staged, ['ok.png']);
        expect(
          fake.lastError,
          isNotNull,
          reason: 'the folder in the same drop was still refused',
        );
      },
    );

    test('multiple real files all stage', () async {
      final fake = _FakeTarget();
      final a = DropItemFile.fromData(Uint8List.fromList([1]), path: 'a.png');
      final b = DropItemFile.fromData(Uint8List.fromList([2]), path: 'b.png');
      await handleComposerDrop([a, b], fake.value);
      expect(fake.staged, ['a.png', 'b.png']);
    });
  });
}
