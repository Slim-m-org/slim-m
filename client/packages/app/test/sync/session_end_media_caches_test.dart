// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Ending a session never throws, even when the container is going away.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/messages/providers/attachment_preview_bytes.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/sync/providers/sync_session_end.dart';
import 'package:slimm_platform/testing.dart';

import '../support/fake_voice.dart';

final _refProvider = Provider<Ref>((ref) => ref);

void main() {
  test(
    'a media cache that cannot be reached does not fail the sign-out',
    () async {
      final container = ProviderContainer(
        overrides: [
          keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
          voiceControllerProvider.overrideWith(
            (ref) => FakeVoiceController(ref),
          ),
          storeProvider.overrideWith((ref) async => throw StateError('closed')),
          attachmentPreviewCacheProvider.overrideWith(
            (ref) => throw StateError('container closed'),
          ),
        ],
      );
      addTearDown(container.dispose);

      await clearSessionState(container.read(_refProvider));
    },
  );
}
