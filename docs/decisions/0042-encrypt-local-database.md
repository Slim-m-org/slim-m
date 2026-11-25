# 0042 - Encrypt the local device database

Status: accepted
Date: 2026-09-29

## The request

The board card asked for the local drift database to be encrypted at rest.
The owner's bar, in their words on the card: nobody should log in and find a screen of unreadable nonsense, and the key must not be trashed on a routine reinstall.

## What the database is

`slimm.sqlite` in the application support directory holds the message cache, the channel and category lists, per-channel drafts, and message rows that were sent from this device and not yet acknowledged.
Everything except the drafts and those unacknowledged rows can be fetched again from the server.
So there is durable local-only state: unsent drafts, and optimistic messages that never reached the server (they are marked failed on the next launch either way, see `failInterruptedSends`).
A reset loses those, and the reset notice says the saved messages were cleared, so the user is told.
Nothing else lives only in this file.
That fact drives most of the choices below.

## Decision

### Engine: SQLite3 Multiple Ciphers through the sqlite3 build hook

`sqlite3` 3.x bundles SQLite through Dart build hooks, and one line at the workspace root switches the build to SQLite3 Multiple Ciphers:

```yaml
hooks:
  user_defines:
    sqlite3:
      source: sqlite3mc
```

That replaces `sqlite3_flutter_libs`, which is end of life at 0.6, and it is the route the sqlite3 package documents in place of `sqlcipher_flutter_libs` (also end of life).
It needs the newer line, so this change moves `drift` 2.31.0 to 2.35.0 and `sqlite3` 2.9.4 to 3.6.0 (SQLite 3.53.4), and regenerates `database.g.dart`.
`sqlite3` is pinned to exactly 3.6.0 in `packages/data/pubspec.yaml`, not a caret range, because the native library is chosen by that version and a silent minor bump would change what ships.
The hook downloads a prebuilt library per target from the sqlite3.dart release, so no C toolchain is needed, but a build now needs network access to GitHub.
The hook checks every download against a sha256 table that ships inside the pinned pub package (`lib/src/hook/asset_hashes.dart`), and `pubspec.lock` pins that package by hash, so the chain is lockfile, package, library digest.
The Linux x64 library in a release build was compared against that table and matches: `libsqlite3mc.x64.linux.so` is `c97c88c788772b86acc7266b48e1ab76791ad7d05edd34fd9bacf76eaeb0791c`.

Stock SQLite treats `PRAGMA key` and `PRAGMA rekey` as silent no-ops, so a build that linked the wrong library would write a plaintext file and believe it was encrypted.
Encryption is therefore checked, not assumed: `prepareEncryptedDatabase` asks the library for `sqlite3mc_version()` before it touches anything, every keyed connection asks again, and the migration refuses a staging file that still begins with the plaintext header after the rekey.
Any of those failing throws `DatabaseEncryptionUnavailable` and the app shows that it will not store messages, instead of falling back.

The cipher is configured as `sqlcipher` with `legacy = 4`, which is AES-256 in the SQLCipher 4 file format, so a stock `sqlcipher` shell can open the file for debugging.
The key is passed in raw form (`PRAGMA key = "x'<64 hex>'"`), which skips the password KDF.
A random 256-bit key does not need stretching, and skipping it keeps opening the database free.

Rejected: `source: sqlcipher`.
It offers `sqlcipher_export`, which would have made migration one statement, but SQLite3 Multiple Ciphers is the variant with a wasm build, and keeping one engine family across native and web is worth more than that one function.

### Key management

One random 256-bit key per install, from the operating system's CSPRNG, stored under `slimm.database.key` in the existing platform `KeyStore`.
It is never derived from the account password: the password is not available at launch, the database has to open before sign-in, and the key must survive a password change.

A new key is written and read back before anything is sealed with it.
A key the store did not really keep would strand the database on the next launch.

The store is the one the session token already uses: Keychain on iOS and macOS, Keystore on Android, the Windows credential store, and on Linux the Secret Service keyring when one answers, with the owner-only file described in `persistent_key_store.dart` as the fallback.
That last one matters for honesty.
Where no Secret Service answers, the key sits in the owner-only secrets file beside the database, so encryption there protects the database file when it is copied, backed up or read by another account, and does not protect it from a process already running as the same user, which can read the key file as easily as the database.
That file is now written through a 0600 temp file inside a 0700 directory and renamed into place, flushed first, and a failed `chmod` is an error instead of being swallowed.
A secrets file that does not parse reads as empty, so one torn write means a sign-in and a fresh database key, not a permanent lock-out.
Linux was first left on the file because a session with no secret service would fail at every launch.
It now uses the keyring when a startup probe gets an answer, keeps the file as the fallback, and moves the file's entries over (`LinuxKeyStore`).

### When the key is unavailable

Three different situations, treated differently:

1. **The store cannot be reached** (it throws): fail closed.
   A stored value that is not exactly 64 lowercase hex digits is not "unreachable", it is corrupt, and is handled as 2 without ever being interpolated into a statement.
   The file is not opened, migrated, deleted or re-keyed, no new key is minted, and the shell shows an `AppErrorState` with a Retry, saying the saved messages stay locked and nothing was deleted.
   A keychain that errors once often works on the next try, and any destructive response now would throw away data that a retry would have unlocked.
   No fallback to a plaintext database, ever.
2. **The store answers "no key" and an encrypted file exists** (a keychain wipe, or the file restored without its key): the file is unreadable by construction, so it is deleted, a new key is minted and the cache is fetched again.
   The shell says so plainly and dismissibly, in an `AppCallout`, since it is information and not a failure.
3. **The key is present but does not open the file**: the file is deleted and the cache fetched again, as in 2.
   A file that decrypts but is damaged (`SQLITE_CORRUPT`, for example a truncated copy) is not deleted: it is moved to `slimm.sqlite.corrupt`, still encrypted, one copy kept, so a fixable corruption is not made permanent.
   Only the first page is probed at launch, so damage further in surfaces later as a query error and is not handled here.

Two app instances started together are serialised by an advisory lock on `slimm.sqlite.lock`, so they cannot each mint a different key for one file.

A reinstall does not hit 2 or 3 in the way the owner feared.
iOS keeps the Keychain across a reinstall but wipes the application support directory, so the key outlives a file that is gone, and a fresh file simply reuses it.
On every other platform both go together.

Rejected: opening an in-memory database when the store is unreachable, so the app stays usable.
A keychain that fails once is usually a machine where it keeps failing, and quietly running without a persistent cache would hide a problem the user can fix.
The message says what to do instead.

### Migrating an existing plaintext database

Recognised by the `SQLite format 3` header, and migrated in place:

1. Delete any leftover `slimm.sqlite.encrypting` from a crashed run.
2. Open the plaintext file, checkpoint the write-ahead log, and `VACUUM INTO` a staging file.
   That is a consistent snapshot including anything still in the log.
3. Encrypt the staging copy in place with `PRAGMA rekey`.
4. Reopen the staging file with the key and check it reads back and matches the original's schema object count.
5. Rename the staging file over `slimm.sqlite`, an atomic replace on POSIX and, through `MoveFileEx`, on Windows.

Until step 5 the plaintext file is untouched, so a crash at any earlier point leaves the user's data exactly where it was and the next launch starts again from step 1.
Step 5 is the only step that changes what is on disk, and after it the database is encrypted.
Any failure short of an unreadable source, disk full for example, deletes the staging file, rethrows, and leaves the plaintext intact and unopened.
A source that is itself corrupt is reset like case 3, since there is nothing to preserve.

SQLite3 Multiple Ciphers has no `sqlcipher_export`, which is why this is `VACUUM INTO` plus `rekey` on a copy and not the export the brief suggested.
The end state is the same and it is checkable at each step.

Before the rename the copy is checked with `PRAGMA integrity_check` and a row count for every table against the source.
On Linux and macOS the staging file is created 0600 before the plaintext snapshot is written into it, and `temp_store` is set to memory on every keyed connection so SQLite does not spill plaintext temporary files.
The mode is not narrowed on Windows, iOS or Android.
On a phone the app's container is already closed to every other app, so there is nobody for 0600 to keep out.

That exception exists because the first version did not have it.
It narrowed the mode by running `chmod`, on every platform but Windows, and iOS does not let an app start a process.
So on iOS the migration threw before it copied anything, on every launch, and an install with data from before encryption showed "The channel list saved on this device could not be opened" with a Retry that could only fail the same way.
A fresh install never has a plaintext file to migrate, which is why CI and a clean TestFlight install both passed while every existing tester was locked out of 0.89.0.
Nothing was lost: the plaintext file is untouched until the rename, so the fixed build migrates it on its first launch.
`scripts/lib/test_client_process_spawns_are_guarded.py` now fails a client file that starts a process outside a `desktop/` directory without naming what keeps a phone away from it.
An error from a statement that carried the key is rethrown without the statement text, because `SqliteException.toString` would otherwise print the key into a log.

The replaced plaintext file's blocks are not scrubbed from the disk.
The old file is renamed over, not overwritten in place, so its freed blocks may hold the plaintext until the filesystem reuses them, and SSD wear levelling and journaling can keep them longer.
Filesystem-level remnants of the old file are outside what an in-app migration can promise, and this is stated here so nobody assumes otherwise.
Dropping the plaintext file and resyncing was the alternative and is the safer failure mode, but it costs the drafts and interrupted-send rows that exist only locally, so migration is preferred and reset is the fallback.

### Web

Not encrypted, and documented as such.
The web build stores the database in OPFS or IndexedDB through `sqlite3.wasm`, and the only place a browser can keep a key is storage the same origin's script can read.
An encrypted browser database would be theatre.
`flutter_secure_storage` on web already says the same thing about itself.
The web build is a test surface, not a distribution target (`packages/app/web/README.md`), and it keeps the plain `sqlite3.wasm`.
The pinned versions and sha256 digests in `tool/fetch_web_assets.sh` move with the upgrade.

## Packaging without a network

The hook downloads its prebuilt library while `flutter build linux` runs, so that step needs network.
Every packaging path only repackages the bundle that step produced, and none of them builds Dart itself.
`flatpak-ci.yml` and `release.yml` run `flutter build linux` online before `flatpak-builder`, whose manifest takes the bundle as a `dir` source, and the rpm spec has an empty `%build` and unpacks the release tarball that COPR receives as an srpm.
So `flatpak-builder` and mock never reach the hook and need no offline source.
`libsqlite3mc.so` links only libc and carries `RUNPATH $ORIGIN`, so it needs nothing the flatpak runtime or the rpm lacks.
The remaining exposure is a GitHub outage during an online `flutter build`, the same class of failure as `pub get`, and the hook caches the download under `.dart_tool/hooks_runner/shared`.
Only a CI run can prove the flatpak and rpm results; the reading above is from the manifest, the spec and the workflows, and a local Fedora flatpak build is not authoritative.

## Cost

Measured with the same 50,000-row, 16 MB table on this machine, raw `sqlite3`, plain against the Multiple Ciphers build with a key:

- Open: no measurable difference, because there is no KDF.
- Bulk insert in one transaction: about 2x (roughly 36 to 51 ms against 73 ms).
- A 16 MB full-table `LIKE` scan, the worst case: about 4x (roughly 40 to 50 ms against 200 ms).
- File size: about 1.5% larger.

The app's queries are indexed point and range reads over a per-channel window, so the day-to-day cost sits far nearer the open figure than the scan.
Everything already runs on drift's background isolate.
These are one machine's numbers, not a budget, and phones were not measured.

## Licences

`sqlite3` is MIT and already allowed.
SQLite3 Multiple Ciphers is MIT (checked against its repository's `LICENSE`), and it is a downloaded native library, not a pub package, so `scripts/check-dart-licenses.py` does not see it.
`sqlite3_flutter_libs` leaves the tree.
`scripts/check-dart-licenses.py` passes on the upgraded lockfile.

## What was not verified

Android and iOS linking cannot be checked from this Linux box; CI and TestFlight are the first real builds of the hook on those targets.
The macOS and Windows hook builds are likewise CI-only.
