// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A database that exists but will not open is retried, then replaced when it
/// is only a cache, and reported plainly when a live process holds it.
library;

import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:slimm_data/data.dart';
import 'package:slimm_data/src/connection/encrypted_database.dart';
import 'package:slimm_data/src/connection/native.dart'
    show slimmDatabaseFileName;
import 'package:slimm_data/src/connection/open_recovery.dart';
import 'package:sqlite3/sqlite3.dart';

class _Keys implements DatabaseKeyStore {
  String? key;

  @override
  Future<String?> read() async => key;

  @override
  Future<void> write(String value) async => key = value;
}

OpenFailure _failure(int code) => OpenFailure(code, 'simulated $code');

void main() {
  late Directory dir;
  late File file;
  late _Keys keys;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('open-recovery-');
    file = File(p.join(dir.path, slimmDatabaseFileName));
    keys = _Keys();
  });

  tearDown(() => dir.deleteSync(recursive: true));

  Future<SlimmDatabase> open(
          {void Function(DatabaseResetReason)? onReset}) async =>
      SlimmDatabase(await openSlimmDatabase(
        keys: keys,
        directoryPath: dir.path,
        onReset: onReset,
      ));

  Future<void> expectUsable(SlimmDatabase db) async {
    await MessageStore(db).replaceCategories(const []);
    await db.close();
  }

  Future<void> seedEncrypted() async {
    final db = await open();
    await expectUsable(db);
  }

  group('through openSlimmDatabase', () {
    test('a corrupt file starts a fresh cache and says so', () async {
      await seedEncrypted();
      final bytes = Random(1).nextInt(255);
      file.writeAsBytesSync(List.filled(8192, bytes));
      DatabaseResetReason? reset;
      final db = await open(onReset: (r) => reset = r);
      await expectUsable(db);
      expect(reset, DatabaseResetReason.unreadable);
    });

    test('a file sealed with another cipher starts a fresh cache', () async {
      await seedEncrypted();
      file.deleteSync();
      final foreign = sqlite3.open(file.path)
        ..execute("PRAGMA cipher = 'chacha20'")
        ..execute('''PRAGMA key = "x'${keys.key}'"''')
        ..execute('CREATE TABLE t (a)');
      foreign.close();
      DatabaseResetReason? reset;
      final db = await open(onReset: (r) => reset = r);
      await expectUsable(db);
      expect(reset, DatabaseResetReason.unreadable);
    });

    test('a healthy file is untouched', () async {
      await seedEncrypted();
      DatabaseResetReason? reset;
      final db = await open(onReset: (r) => reset = r);
      await expectUsable(db);
      expect(reset, isNull);
    });
  });

  group('a database another process holds', () {
    Database hold(String key) {
      final holder = sqlite3.open(file.path);
      applyDatabaseKey(holder, key);
      holder
        ..execute('CREATE TABLE IF NOT EXISTS held (a)')
        ..execute('BEGIN EXCLUSIVE');
      return holder;
    }

    test('a lock that lets go in time opens without clearing anything',
        () async {
      await seedEncrypted();
      final holder = hold(keys.key!);
      var pauses = 0;
      final host = OpenRecoveryHost(
        backoff: const [Duration(milliseconds: 1), Duration(milliseconds: 1)],
        probe: (f, k) {
          final result = probeOpen(f, k);
          if (++pauses == 2) holder.execute('ROLLBACK');
          return result;
        },
      );
      final prepared =
          await prepareOpenableDatabase(file: file, keys: keys, host: host);
      expect(prepared.reset, isNull);
      expect(pauses, 3);
      holder.close();
    });

    test('a lock that never lets go is reported, not cleared', () async {
      await seedEncrypted();
      final holder = hold(keys.key!);
      final before = file.readAsBytesSync();
      const host = OpenRecoveryHost(backoff: [Duration(milliseconds: 1)]);
      await expectLater(
        prepareOpenableDatabase(file: file, keys: keys, host: host),
        throwsA(isA<DatabaseInUseElsewhere>()),
      );
      expect(file.existsSync(), isTrue);
      expect(file.readAsBytesSync(), before);
      holder.close();
    });
  });

  group('a file Windows will not let us open', () {
    OpenRecoveryHost host({
      required List<OpenFailure?> probes,
      void Function(File)? setAside,
    }) =>
        OpenRecoveryHost(
          backoff: const [Duration(milliseconds: 1)],
          probe: (f, k) => probes.isEmpty ? null : probes.removeAt(0),
          setAside: setAside ?? setDatabaseAside,
        );

    test('a refused open that clears is replaced by a fresh cache', () async {
      await seedEncrypted();
      final prepared = await prepareOpenableDatabase(
        file: file,
        keys: keys,
        host: host(probes: [_failure(14), _failure(14), null]),
      );
      expect(prepared.reset, DatabaseResetReason.unreadable);
      expect(File('${file.path}.unopenable').existsSync(), isTrue);
    });

    test('a sharing violation on the move means another copy holds it',
        () async {
      await seedEncrypted();
      await expectLater(
        prepareOpenableDatabase(
          file: file,
          keys: keys,
          host: host(
            probes: [_failure(14), _failure(14)],
            setAside: (f) => throw FileSystemException(
                'in use', f.path, const OSError('sharing violation', 32)),
          ),
        ),
        throwsA(isA<DatabaseInUseElsewhere>()),
      );
    });

    test('a file that cannot be moved for another reason is unopenable',
        () async {
      await seedEncrypted();
      await expectLater(
        prepareOpenableDatabase(
          file: file,
          keys: keys,
          host: host(
            probes: [_failure(14), _failure(14)],
            setAside: (f) => throw FileSystemException(
                'denied', f.path, const OSError('access denied', 5)),
          ),
        ),
        throwsA(isA<DatabaseUnopenable>()),
      );
    });

    test('a fresh file that also fails to open is unopenable', () async {
      await seedEncrypted();
      await expectLater(
        prepareOpenableDatabase(
          file: file,
          keys: keys,
          host: host(probes: [_failure(11), _failure(11)]),
        ),
        throwsA(isA<DatabaseUnopenable>()),
      );
    });

    test('a damaged file is not retried', () async {
      await seedEncrypted();
      var probes = 0;
      await prepareOpenableDatabase(
        file: file,
        keys: keys,
        host: OpenRecoveryHost(
          backoff: const [Duration(seconds: 30)],
          probe: (f, k) => ++probes == 1 ? _failure(11) : null,
        ),
      );
      expect(probes, 2);
    });
  });
}
