// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The profile sections modules contribute for one member.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart';

import '../../../providers/providers.dart';

/// Fetched when a card opens. A failure reads as no sections: a module's
/// panel is a nicety, never worth an error state on the card.
final moduleProfileSlotsProvider = FutureProvider.autoDispose
    .family<List<ModuleProfileSection>, String>((ref, userId) async {
      try {
        return await ref.watch(apiProvider).moduleProfileSlots(userId);
      } catch (error, stack) {
        reportFailure(LogTag.ui, 'load module profile slots', error, stack);
        return const [];
      }
    });
