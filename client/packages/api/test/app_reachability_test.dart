// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Gates every public `SlimmApi` method against something in the app calling
/// it, so a wired endpoint with no way to reach it fails here instead of
/// shipping.
///
/// This project has paid for that exact shape three times. `Routes.settings`
/// was registered, built and tested with nothing navigating to it, which left
/// sign-out, the device list and account deletion unreachable through a whole
/// release. `markRead` had no call site, so every channel stayed lit as
/// unread. `report` and `blockUser` had an endpoint, a wire model and an admin
/// triage screen, and no caller anywhere.
///
/// Neither existing gate can see it. `route_reachability_test.dart` reads
/// route constants out of `routes.dart` only, and `schema_coverage_test.dart`
/// compares the schema against this package's own `_send` call sites - it
/// proves the client *can* call a route, never that anything does.
///
/// The allowlist below is the point rather than an escape hatch: an entry has
/// to say why, and it fails in both directions. An allowlisted method that
/// gains a caller fails as a stale entry, and one naming a method that no
/// longer exists fails too, so a rename cannot quietly retire an exemption.
/// That is the shape `crates/slimm-server/tests/response_contract`'s
/// `UNCOVERED` already uses on the server side.
///
/// `_concatDart` runs every file through `support/code_only.dart` before
/// `_mentions` ever searches it: reproduced directly, replacing a method's
/// only real call with a trailing `// used to call kickVoiceParticipant
/// here` comment on that same line passed this gate before that existed.
library;

import 'dart:io';

import 'package:test/test.dart';

import 'support/code_only.dart';

/// Methods with no caller in `packages/app/lib`, and why that is not drift.
///
/// Each of these is a real gap rather than a decision, except the first. They
/// are listed so the gap is visible and counted, not so it is forgiven.
const Map<String, String> _allowlist = {
  'pinnedMessageCount':
      'the pins sheet lists pinned messages and shows no count beside the '
          'header, so nothing asks for one (2026-07-30)',
  'bulkDeleteMessagesByAuthor': 'the author-plus-window sibling of '
      'bulkDeleteMessages: the server route and its index exist so a raid '
      'response is not "select 64 ids by hand", but no transcript UI offers '
      '"delete this author\'s recent messages" as a single action yet. Same '
      'shape bulkDeleteMessages itself carried in this allowlist until MOD13 '
      'built the multi-select that finally called it',
  'setChannelOverwrite': 'the single-target sibling of '
      'batchSetChannelOverwrites: the permissions grid always saves through '
      'the batch route now, even for one changed column, so this binding has '
      'no in-app caller. The server route stays for any caller that wants to '
      'set exactly one overwrite without touching the rest',
  'getMessage': 'message_jump.dart\'s jumpTo pages channel_history.dart '
      'backwards and only ever renders a message once it lands in the local '
      'drift store, so a cold single-message fetch has nowhere to be shown '
      'yet - the transcript has no path for a row outside its loaded, '
      'seq-paged window. Wiring this in is a real change to that mechanism, '
      'not a caller swap, so it is tracked as its own follow-up (2026-09-24)',
};

/// Names that are not API surface, so their absence proves nothing.
const Set<String> _notApiSurface = {'close', 'dispose', 'clear'};

void main() {
  final repoRoot = _findRepoRoot(Directory.current);
  final apiSrc = Directory('${repoRoot.path}/client/packages/api/lib/src');
  final appLib = Directory('${repoRoot.path}/client/packages/app/lib');

  final declared = _publicSlimmApiMethods(apiSrc);
  final appSource = _concatDart(appLib);

  /// Guards the two scans themselves. Both assertions below are "this name
  /// does not appear", which a scanner returning nothing would satisfy for
  /// every name at once.
  test('both sides of the comparison actually parsed', () {
    expect(
      declared.length,
      greaterThan(60),
      reason: 'only ${declared.length} SlimmApi methods parsed; the extractor '
          'has probably stopped matching a declaration shape',
    );
    for (final known in ['sendMessage', 'listChannels', 'login', 'sync']) {
      expect(
        declared.keys,
        contains(known),
        reason: '$known is unmistakably a SlimmApi method and was not found',
      );
    }
    expect(appSource.length, greaterThan(100000));
    expect(appSource, contains('sendMessage'));
  });

  test('every public SlimmApi method has a caller in the app', () {
    final unreachable = <String>[];
    for (final entry in declared.entries) {
      if (_allowlist.containsKey(entry.key)) continue;
      if (_notApiSurface.contains(entry.key)) continue;
      if (!_mentions(appSource, entry.key)) {
        unreachable.add('${entry.key} (${entry.value})');
      }
    }
    expect(
      unreachable,
      isEmpty,
      reason:
          'these SlimmApi methods have no caller under packages/app/lib, so '
          'whatever they do cannot be reached by anyone using the app:\n'
          '  ${unreachable.join('\n  ')}\n'
          'Either wire one up, or add it to _allowlist in this file with the '
          'reason it is deliberately unreachable.',
    );
  });

  test('no allowlist entry has quietly become reachable', () {
    final stale =
        _allowlist.keys.where((m) => _mentions(appSource, m)).toList();
    expect(
      stale,
      isEmpty,
      reason: 'these are allowlisted as unreachable and now have a caller: '
          '${stale.join(', ')}. Delete their entries; an exemption that is no '
          'longer true is how the next real gap gets hidden.',
    );
  });

  test('no allowlist entry names a method that no longer exists', () {
    final unknown =
        _allowlist.keys.where((m) => !declared.containsKey(m)).toList();
    expect(
      unknown,
      isEmpty,
      reason: 'these are allowlisted but are not SlimmApi methods: '
          '${unknown.join(', ')}. A rename or a deletion left the entry '
          'behind, and a stale exemption silently covers whatever takes the '
          'old name next.',
    );
  });
}

/// Whether [source] uses [name] as an identifier rather than as a substring
/// of a longer one, so `report` does not match `reportPushLifecycle`.
bool _mentions(String source, String name) =>
    RegExp('(?<![A-Za-z0-9_])${RegExp.escape(name)}(?![A-Za-z0-9_])')
        .hasMatch(source);

/// Public method names declared on `SlimmApi` itself or on one of the
/// extensions in its `part` files, mapped to the file declaring each.
///
/// Scoped by walking the top-level declarations rather than matching every
/// indented method in the package: `models.dart` and `events.dart` have their
/// own `toJson`, `parse` and `close`, none of which is API surface.
Map<String, String> _publicSlimmApiMethods(Directory apiSrc) {
  final onSlimmApi = RegExp(r'^(class SlimmApi\b|extension \w+ on SlimmApi\b)');
  final topLevel = RegExp(r'^(class |extension |mixin |enum )');
  final declaration = RegExp(
    r'^  (?!return\b|await\b|final\b|const\b|var\b|if\b|for\b)'
    r'[A-Za-z_][\w<>,\s?\[\]]*?\s+([a-z][A-Za-z0-9_]*)\s*\(',
  );

  final found = <String, String>{};
  for (final file in apiSrc.listSync().whereType<File>()) {
    if (!file.path.endsWith('.dart')) continue;
    final text = file.readAsStringSync();
    if (!text.contains("part of 'client.dart'") &&
        !file.path.endsWith('/client.dart')) {
      continue;
    }
    var inside = false;
    for (final line in text.split('\n')) {
      if (onSlimmApi.hasMatch(line)) {
        inside = true;
        continue;
      }
      if (topLevel.hasMatch(line)) {
        inside = false;
        continue;
      }
      if (!inside) continue;
      final match = declaration.firstMatch(line);
      final name = match?.group(1);
      if (name != null && !name.startsWith('_')) {
        found[name] = file.uri.pathSegments.last;
      }
    }
  }
  return found;
}

String _concatDart(Directory dir) => dir
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => f.path.endsWith('.dart'))
    .map((f) => codeOnly(f.readAsStringSync()))
    .join('\n');

/// Walks upward looking for schema/openapi.yaml, so this does not depend on
/// whether it was invoked from the repo root, from client/, or from
/// client/packages/api.
Directory _findRepoRoot(Directory start) {
  var dir = start.absolute;
  for (var i = 0; i < 10; i++) {
    if (File('${dir.path}/schema/openapi.yaml').existsSync()) return dir;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  fail(
    'could not find schema/openapi.yaml walking up from ${start.path}; is '
    'this test running from somewhere inside the slim-m repo?',
  );
}
