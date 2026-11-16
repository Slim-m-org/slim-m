// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What the Themes gallery does: apply, import, export, publish, save to Mine,
/// delete, remove and the Space default, one at a time, with the failure kept
/// on the page.
library;

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../../api_failure.dart';
import '../../../providers/providers.dart' show AppThemeChoice;
import 'my_themes.dart';
import 'stored_theme.dart';
import 'theme_draft.dart';
import 'theme_file_io.dart';
import 'theme_gallery.dart';
import 'theme_labels.dart';
import 'theme_source.dart';
import 'theme_store_actions.dart';

/// A failure shown at the top of the gallery until it is dismissed.
class ThemeGalleryError {
  const ThemeGalleryError(this.message, {this.detail});

  final String message;

  /// The problems a file had, one per line.
  final String? detail;
}

class ThemeGalleryStatus {
  const ThemeGalleryStatus({this.busy = false, this.error});

  /// True while an action runs; every card and button waits for it.
  final bool busy;
  final ThemeGalleryError? error;
}

class ThemeGalleryStatusController
    extends AutoDisposeNotifier<ThemeGalleryStatus> {
  var _disposed = false;

  @override
  ThemeGalleryStatus build() {
    ref.onDispose(() => _disposed = true);
    return const ThemeGalleryStatus();
  }

  /// Starts an action, clearing the last failure; false while one runs.
  bool _begin() {
    if (_disposed || state.busy) return false;
    state = const ThemeGalleryStatus(busy: true);
    return true;
  }

  void _end(ThemeGalleryError? error) {
    if (!_disposed) state = ThemeGalleryStatus(error: error);
  }

  void dismiss() => state = ThemeGalleryStatus(busy: state.busy);
}

final themeGalleryStatusProvider =
    NotifierProvider.autoDispose<
      ThemeGalleryStatusController,
      ThemeGalleryStatus
    >(ThemeGalleryStatusController.new);

const _full = ThemeGalleryError(
  'This device holds $myThemesMax themes. Delete one first.',
);

/// The first three problems a file had, then how many more.
ThemeGalleryError themeImportError(String fileName, List<String> problems) =>
    ThemeGalleryError(
      'Could not import $fileName.',
      detail: [
        ...problems.take(3),
        if (problems.length > 3) 'And ${problems.length - 3} more.',
      ].join('\n'),
    );

/// The gallery's actions, run through the page's own [ref] so one outlives
/// the card that started it.
class ThemeGalleryActions {
  ThemeGalleryActions(this.ref);

  final WidgetRef ref;

  ThemeGalleryStatusController get _status =>
      ref.read(themeGalleryStatusProvider.notifier);

  Future<void> _run(
    String whatFailed,
    Future<ThemeGalleryError?> Function() action,
  ) async {
    final status = _status;
    if (!status._begin()) return;
    ThemeGalleryError? error;
    try {
      error = await action();
    } catch (e, stack) {
      error = ThemeGalleryError(
        reportFailureSentence(api.LogTag.ui, whatFailed, e, stack),
      );
    }
    status._end(error);
  }

  /// Applies [entry]; the card in use and a broken one do nothing.
  Future<void> apply(ThemeGalleryEntry entry) async {
    if (entry.inUse || entry.broken != null) return;
    final document = entry.document;
    await _run('apply the theme', () async {
      switch (entry.source) {
        case BuiltInThemeSource(:final choice):
          await applyThemeChoice(ref, choice);
        case MineThemeSource() when document != null:
          await applyThemeDocument(ref, document, source: entry.source);
        case SpaceThemeSource(:final id) when document != null:
          await applySpaceTheme(
            ref,
            id,
            document,
            hasPicture: entry.pictureId != null,
          );
        case _:
          break;
      }
      return null;
    });
  }

  Future<void> importFile() => _run('import the theme', () async {
    final pick = await ref.read(themeFilePickerProvider)();
    if (pick == null) return null;
    final parsed = readThemeFile(pick.bytes);
    final document = parsed.document;
    if (document == null) {
      return themeImportError(pick.fileName, parsed.problems);
    }
    final id = await ref.read(myThemesProvider.notifier).save(document);
    return id == null ? _full : null;
  });

  Future<void> export(ThemeDocument document) => _run('export', () async {
    try {
      await ref.read(themeFileSaverProvider)(
        themeFileName(document.name),
        utf8.encode(document.toJsonText()),
      );
      return null;
    } on Object catch (error, stack) {
      api.reportFailure(
        api.LogTag.platform,
        'save the theme file',
        error,
        stack,
      );
      return const ThemeGalleryError('Could not save the file.');
    }
  });

  Future<void> publish(ThemeDocument document) =>
      _run('publish the theme', () async {
        await publishTheme(ref, document);
        return null;
      });

  /// Keeps [document] in Mine; when it is the theme in use, that now comes from Mine.
  Future<void> saveToMine(ThemeDocument document) =>
      _run('save the theme', () async {
        final id = await ref.read(myThemesProvider.notifier).save(document);
        if (id == null) return _full;
        final applied = ref.read(customThemeProvider);
        if (applied != null &&
            themeMatchText(applied) == themeMatchText(document)) {
          await ref
              .read(customThemeSourceProvider.notifier)
              .set(MineThemeSource(id));
        }
        return null;
      });

  /// On follows the Space default and its changes; off keeps [current] as a
  /// Space theme, so nothing repaints.
  Future<void> follow(bool on, ThemeGalleryEntry current) => _run(
    on ? 'follow the Space default' : 'stop following the Space default',
    () async {
      final document = current.document;
      if (on) {
        await applyThemeChoice(ref, AppThemeChoice.spaceDefault);
      } else if (document != null) {
        await applyThemeDocument(
          ref,
          document,
          source: current.source,
          background: false,
        );
      }
      return null;
    },
  );

  Future<void> delete(String mineId) => _run('delete the theme', () async {
    await ref.read(myThemesProvider.notifier).remove(mineId);
    return null;
  });

  Future<void> remove(String spaceId) => _run('remove the theme', () async {
    await removeStoreTheme(ref, spaceId);
    return null;
  });

  /// A null [spaceId] clears the Space default.
  Future<void> setDefault(String? spaceId) => _run(
    spaceId == null ? 'clear the default theme' : 'set the default theme',
    () async {
      await setSpaceDefaultTheme(ref, spaceId);
      return null;
    },
  );
}

/// A new theme that starts as a copy of the built-in [choice], or null for
/// System, which is not one palette.
ThemeEditorSeed? customiseSeed(AppThemeChoice choice) {
  final base = themeBaseOf(choice);
  if (base == null) return null;
  return _copy(ThemeEditorSeed.fromBase(base).document, themeLabel(choice));
}

/// A copy of [entry]'s file under a new name, or null when it cannot be read.
ThemeEditorSeed? editCopySeed(ThemeGalleryEntry entry) {
  final document = entry.document;
  return document == null ? null : _copy(document, entry.name);
}

ThemeEditorSeed _copy(ThemeDocument source, String name) =>
    ThemeEditorSeed(source.copyWith(name: themeCopyName(name), author: ''));
