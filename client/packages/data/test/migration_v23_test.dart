// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests the schema-23 migration: `pending_attachments.mention_reply` arrives
/// on an upgrading client, null on every send it already queued.
library;

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_data/src/database.dart';

import 'support/v23_columns.dart';
import 'support/v24_columns.dart';

Future<void> _downgradeToV22(File file) async {
  final db = SlimmDatabase(NativeDatabase(file));
  await dropV23Columns(db);
  await dropV24Columns(db);
  await db.customStatement('PRAGMA user_version = 22');
  await db.close();
}

void main() {
  late Directory dir;
  late File file;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('slimm-migration-v23');
    file = File('${dir.path}/slimm.sqlite');
    await _downgradeToV22(file);
  });

  tearDown(() => dir.delete(recursive: true));

  test('an upgrading client gains the mention_reply column', () async {
    final db = SlimmDatabase(NativeDatabase(file));
    addTearDown(db.close);
    final columns =
        await db.customSelect('PRAGMA table_info(pending_attachments)').get();
    expect(
      columns.map((r) => r.read<String>('name')),
      contains('mention_reply'),
    );
  });

  test('a send queued after the upgrade leaves the mention unset', () async {
    final db = SlimmDatabase(NativeDatabase(file));
    addTearDown(db.close);
    await db.into(db.pendingAttachments).insert(
          PendingAttachmentsCompanion.insert(
            messageId: 'm1',
            attachmentIds: const ['a'],
          ),
        );
    final row = await db.select(db.pendingAttachments).getSingle();
    expect(row.mentionReply, isNull);
    expect(db.schemaVersion, greaterThanOrEqualTo(23));
  });
}
