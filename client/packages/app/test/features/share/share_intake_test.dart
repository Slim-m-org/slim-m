// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What the OS share sheet hands over, and which account receives it.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/share/providers/incoming_share.dart';
import 'package:slimm_app/src/features/share/providers/share_intake.dart';
import 'package:slimm_app/src/features/share/providers/share_source.dart';
import 'package:slimm_app/src/features/share/widgets/share_destination_step.dart';
import 'package:slimm_app/src/features/share/widgets/share_summary.dart';

import '../accounts/account_host_harness.dart';

const _photo = SharedFile(
  path: '/cache/1/a.jpg',
  name: 'a.jpg',
  length: 2048,
  mimeType: 'image/jpeg',
);
const _clip = SharedFile(
  path: '/cache/2/b.mp4',
  name: 'b.mp4',
  length: 4096,
  mimeType: 'video/mp4',
);
const _pdf = SharedFile(
  path: '/cache/3/c.pdf',
  name: 'c.pdf',
  length: 100,
  mimeType: 'application/pdf',
);

/// A [Ref] that outlives provider creation, like the one the intake controller holds.
final _refProvider = Provider<Ref>((ref) => ref);

class _FakeSource implements ShareSource {
  _FakeSource([this.waiting]);

  IncomingShare? waiting;
  final arrived = StreamController<void>.broadcast();

  @override
  Stream<void> get arrivals => arrived.stream;

  @override
  Future<IncomingShare?> take() async {
    final share = waiting;
    waiting = null;
    return share;
  }
}

void main() {
  group('the wire form', () {
    test('reads files and text, keeping what the platform said', () {
      final share = IncomingShare.fromWire({
        'files': [
          {
            'path': '/cache/1/a.jpg',
            'name': 'a.jpg',
            'mimeType': 'image/jpeg',
            'length': 2048,
          },
        ],
        'text': 'look at this',
        'unreadable': 1,
      })!;

      expect(share.files.single.name, 'a.jpg');
      expect(share.files.single.isImage, isTrue);
      expect(share.files.single.length, 2048);
      expect(share.text, 'look at this');
      expect(share.unreadable, 1);
    });

    test('drops malformed entries instead of failing the whole share', () {
      final share = IncomingShare.fromWire({
        'files': [
          'not a map',
          {'name': 'no-path.jpg'},
          {'path': '/cache/ok.png', 'name': 'ok.png'},
        ],
      })!;

      expect(share.files.map((f) => f.name), ['ok.png']);
    });

    test('a stray intent with nothing usable opens no picker', () {
      expect(IncomingShare.fromWire(null), isNull);
      expect(
        IncomingShare.fromWire({'files': <Object>[], 'text': '   '}),
        isNull,
      );
    });

    test('a share where every item was unreadable is still reported', () {
      final share = IncomingShare.fromWire({
        'files': <Object>[],
        'unreadable': 2,
      })!;

      expect(share.hasFiles, isFalse);
      expect(share.unreadable, 2);
    });
  });

  group('the summary words', () {
    test('name what was shared', () {
      String title(List<SharedFile> files, {String? text}) =>
          shareSummaryTitle(IncomingShare(files: files, text: text));

      expect(title(const <SharedFile>[], text: 'hi'), 'Text');
      expect(title(const [_pdf]), 'c.pdf');
      expect(title(const [_photo, _photo]), '2 photos');
      expect(title(const [_clip, _clip, _clip]), '3 videos');
      expect(title(const [_photo, _pdf]), '2 files');
      expect(title(const [_pdf], text: 'see attached'), 'c.pdf and text');
    });

    test('the detail is the text, else the combined size', () {
      expect(shareSummaryDetail(const IncomingShare(text: ' hello ')), 'hello');
      expect(
        shareSummaryDetail(const IncomingShare(files: [_photo, _clip])),
        '6.0 KB',
      );
      expect(shareSummaryDetail(const IncomingShare()), isNull);
    });
  });

  test('shared text joins an existing draft on its own line', () {
    expect(draftWithShared('', 'link'), 'link');
    expect(draftWithShared('  ', 'link'), 'link');
    expect(draftWithShared('half a thought', 'link'), 'half a thought\nlink');
  });

  group('which account receives a share', () {
    late AccountHarness h;
    tearDown(() async => h.dispose());

    PendingShare? pendingIn(String origin) =>
        h.host.runtimeFor(origin)!.container.read(pendingShareProvider);

    void deliver(IncomingShare share) =>
        deliverShare(h.host.active!.container.read(_refProvider), share);

    const share = IncomingShare(text: 'hello');

    test('a signed-in active account keeps it', () async {
      h = AccountHarness();
      final a = await h.seed('https://first.example', user: 'me', active: true);
      final b = await h.seed('https://second.example', user: 'me2');
      await h.boot();

      deliver(share);

      expect(pendingIn(a.origin)?.share, share);
      expect(pendingIn(a.origin)?.serverChosen, isFalse);
      expect(pendingIn(b.origin), isNull);
      expect(h.host.active?.account?.origin, a.origin);
    });

    test(
      'a signed-out active account yields to one that is signed in',
      () async {
        h = AccountHarness();
        final a = await h.seed('https://first.example', active: true);
        final b = await h.seed('https://second.example', user: 'me2');
        await h.boot();

        deliver(share);
        await pumpEventQueueTimes();

        expect(pendingIn(b.origin)?.share, share);
        expect(pendingIn(a.origin), isNull);
        expect(h.host.active?.account?.origin, b.origin);
      },
    );

    test(
      'nobody signed in: it waits in the active account for sign-in',
      () async {
        h = AccountHarness();
        final a = await h.seed('https://first.example', active: true);
        await h.boot();

        deliver(share);

        expect(pendingIn(a.origin)?.share, share);
      },
    );
  });

  group('the intake controller', () {
    test('takes the launching share at startup and later arrivals', () async {
      final source = _FakeSource(const IncomingShare(text: 'cold'));
      final container = ProviderContainer(
        overrides: [shareSourceProvider.overrideWithValue(source)],
      );
      addTearDown(container.dispose);

      container.read(shareIntakeControllerProvider);
      await pumpEventQueueTimes();
      expect(container.read(pendingShareProvider)?.share.text, 'cold');

      container.read(pendingShareProvider.notifier).state = null;
      source.waiting = const IncomingShare(text: 'warm');
      source.arrived.add(null);
      await pumpEventQueueTimes();
      expect(container.read(pendingShareProvider)?.share.text, 'warm');
    });

    test('nothing waiting leaves nothing pending', () async {
      final container = ProviderContainer(
        overrides: [shareSourceProvider.overrideWithValue(_FakeSource())],
      );
      addTearDown(container.dispose);

      container.read(shareIntakeControllerProvider);
      await pumpEventQueueTimes();

      expect(container.read(pendingShareProvider), isNull);
    });
  });
}
