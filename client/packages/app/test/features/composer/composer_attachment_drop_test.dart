// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A mounted [Composer] registers a [ComposerAttachmentDropTarget] for its
/// own channel id, and staging through it lands in the exact same place a
/// picked file does - the defect this pins is a drop inventing a second,
/// silently different attachment path.
///
/// The registry is probed with a `Consumer` sibling in the same
/// `ProviderScope` `composerHarness` builds, rather than mounting the real
/// `ChannelAttachmentDropZone`/`DropTarget`: those are covered on their own
/// terms in `channel_attachment_drop_zone_test.dart` and `app_drop_zone_test.dart`.
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/features/composer/providers/composer_attachment_drop.dart';

import 'composer_harness.dart';

/// Watches the registry for [channelId] and exposes the latest value through
/// [onChanged], which fires on every rebuild including the very first -
/// mirrors what a real caller (`ChannelAttachmentDropZone`'s own `ref.read`)
/// would see if it read right now.
class _RegistryProbe extends ConsumerWidget {
  const _RegistryProbe({required this.channelId, required this.onChanged});

  final String channelId;
  final ValueChanged<ComposerAttachmentDropTarget?> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    onChanged(ref.watch(composerAttachmentDropProvider(channelId)));
    return const SizedBox.shrink();
  }
}

void main() {
  late TextEditingController controller;
  late Sends sends;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    controller = TextEditingController();
    sends = Sends();
  });

  tearDown(() => controller.dispose());

  testWidgets(
    'a mounted composer registers a drop target for its own channel',
    (tester) async {
      ComposerAttachmentDropTarget? target;
      await tester.pumpWidget(
        composerHarness(
          controller: controller,
          sends: sends,
          platform: TargetPlatform.linux,
          channelId: 'c1',
          extra: _RegistryProbe(
            channelId: 'c1',
            onChanged: (value) => target = value,
          ),
        ),
      );
      await tester.pump();

      expect(
        target,
        isNotNull,
        reason: 'the composer should have registered itself by now',
      );
    },
  );

  testWidgets(
    'staging through the registered target lands in the same attachment '
    'list a picked file would',
    (tester) async {
      ComposerAttachmentDropTarget? target;
      await tester.pumpWidget(
        composerHarness(
          controller: controller,
          sends: sends,
          platform: TargetPlatform.linux,
          channelId: 'c1',
          extra: _RegistryProbe(
            channelId: 'c1',
            onChanged: (value) => target = value,
          ),
        ),
      );
      await tester.pump();

      await target!.stage(Uint8List.fromList([1, 2, 3]), 'dropped.png');
      await tester.pumpAndSettle();

      expect(
        find.text('dropped.png'),
        findsOneWidget,
        reason: 'a drop must reach the same staged-attachment tile a pick does',
      );
    },
  );

  testWidgets('a directory-only drop reports its error through the same '
      "attachment banner the picker's own failures use", (tester) async {
    ComposerAttachmentDropTarget? target;
    await tester.pumpWidget(
      composerHarness(
        controller: controller,
        sends: sends,
        platform: TargetPlatform.linux,
        channelId: 'c1',
        extra: _RegistryProbe(
          channelId: 'c1',
          onChanged: (value) => target = value,
        ),
      ),
    );
    await tester.pump();

    target!.setError("Folders can't be attached - drop a file instead.");
    await tester.pumpAndSettle();

    expect(
      find.text("Folders can't be attached - drop a file instead."),
      findsOneWidget,
    );
  });

  testWidgets(
    'the registration follows the composer to a new channel, and the old '
    "channel's slot clears",
    (tester) async {
      ComposerAttachmentDropTarget? c1Target;
      ComposerAttachmentDropTarget? c2Target;
      Widget harness(String channelId) => composerHarness(
        controller: controller,
        sends: sends,
        platform: TargetPlatform.linux,
        channelId: channelId,
        extra: Column(
          children: [
            _RegistryProbe(
              channelId: 'c1',
              onChanged: (value) => c1Target = value,
            ),
            _RegistryProbe(
              channelId: 'c2',
              onChanged: (value) => c2Target = value,
            ),
          ],
        ),
      );

      await tester.pumpWidget(harness('c1'));
      await tester.pump();
      expect(c1Target, isNotNull);
      expect(c2Target, isNull);

      await tester.pumpWidget(harness('c2'));
      await tester.pump();

      expect(
        c1Target,
        isNull,
        reason: 'c1 no longer has a composer mounted for it',
      );
      expect(c2Target, isNotNull);
    },
  );

  testWidgets('unmounting the composer clears its own registration', (
    tester,
  ) async {
    ComposerAttachmentDropTarget? target;
    Widget harness({required bool mountComposer}) => composerHarness(
      controller: controller,
      sends: sends,
      platform: TargetPlatform.linux,
      channelId: 'c1',
      mountComposer: mountComposer,
      extra: _RegistryProbe(
        channelId: 'c1',
        onChanged: (value) => target = value,
      ),
    );

    await tester.pumpWidget(harness(mountComposer: true));
    await tester.pump();
    expect(target, isNotNull);

    await tester.pumpWidget(harness(mountComposer: false));
    await tester.pump();

    expect(
      target,
      isNull,
      reason:
          'a composer that is gone must not leave a stale registration '
          'a later drop could land in unseen',
    );
  });
}
