// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The source-reading rules that keep presence and avatars from fragmenting
/// again, as a function over a `packages/` root so a test can run it on the
/// real tree and on code shaped like the old one.
///
/// Every file is read through [codeOnly] first, so a comment or a string that
/// merely names a widget cannot trip a rule or hide a violation.
library;

import 'dart:io';

import 'code_only.dart';

const _statusDotHomes = {
  'design_system/lib/src/components/core/status_dot.dart',
  'design_system/lib/src/components/core/avatar.dart',
  'app/lib/src/features/members/widgets/presence_indicator.dart',
};

const _avatarHomes = {
  'design_system/lib/src/components/core/avatar.dart',
  'app/lib/src/features/members/widgets/user_avatar.dart',
};

const _ringHomes = {
  'design_system/lib/src/components/core/speaking_ring.dart',
  'design_system/lib/src/components/core/avatar.dart',
};

const _pictureHomes = {
  'app/lib/src/features/members/providers/avatar_bytes.dart',
  'app/lib/src/features/members/widgets/user_avatar.dart',
};

/// The only code that may read the raw presence map, the shared providers and
/// each feature's own; widgets and screens get a state from `presenceForProvider`.
final _presenceMapReaders = RegExp(r'^app/lib/src/(features/\w+/)?providers/');

/// The painter is deliberately not covered: the Space's connection dot draws
/// with it, and that is a link to a server rather than a person.
///
/// Every rule a library file under [packagesRoot] breaks, one line each.
List<String> presenceGateViolations(Directory packagesRoot) {
  final found = <String>[];
  for (final entity in packagesRoot.listSync(recursive: true)) {
    if (entity is! File || !entity.path.endsWith('.dart')) continue;
    final path = entity.path.substring(packagesRoot.path.length + 1);
    if (!path.contains('/lib/') || path.endsWith('.g.dart')) continue;
    final code = codeOnly(entity.readAsStringSync());
    void forbid(Pattern pattern, Set<String> homes, String why) {
      if (!homes.contains(path) && code.contains(pattern)) {
        found.add('$path: $why');
      }
    }

    forbid(
      RegExp(r'\bAppStatusDot\b'),
      _statusDotHomes,
      'draws a presence dot; use UserAvatar(presence: true) or PresenceIndicator',
    );
    forbid(
      RegExp(r'\bAppAvatar\s*\('),
      _avatarHomes,
      'builds an avatar from raw pieces; use UserAvatar',
    );
    forbid(
      RegExp(r'\bAppSpeakingRing\b'),
      _ringHomes,
      'draws a speaking ring outside the avatar',
    );
    forbid(
      RegExp(r'\bCircleAvatar\b'),
      const {},
      'uses CircleAvatar; use UserAvatar',
    );
    forbid(
      RegExp(r'\bavatarBytesProvider\b'),
      _pictureHomes,
      'fetches a picture outside UserAvatar',
    );
    if (path.startsWith('app/lib/') && !_presenceMapReaders.hasMatch(path)) {
      forbid(
        RegExp(r'\bpresenceControllerProvider\b'),
        const {},
        'reads the raw presence map; use presenceForProvider',
      );
      forbid(
        RegExp(r'\bresolvePresence\b'),
        const {},
        'maps presence by hand; use presenceForProvider',
      );
    }
    for (final literal in _literalAvatarSizes(code)) {
      found.add('$path: UserAvatar size $literal is not an AppAvatarSize');
    }
  }
  return found;
}

/// The numeric `size:` literals passed to `UserAvatar(` and `UserAvatar.known(`.
Iterable<String> _literalAvatarSizes(String code) sync* {
  final call = RegExp(r'\bUserAvatar(\.known)?\s*\(');
  for (final match in call.allMatches(code)) {
    var depth = 1;
    var i = match.end;
    while (i < code.length && depth > 0) {
      if (code[i] == '(') depth++;
      if (code[i] == ')') depth--;
      i++;
    }
    final args = code.substring(match.end, i);
    final size = RegExp(r'(?:^|[\s,])size:\s*(\d[\d.]*)').firstMatch(args);
    if (size != null) yield size.group(1)!;
  }
}

void main(List<String> args) {
  final violations = presenceGateViolations(Directory(args.first));
  violations.forEach(stdout.writeln);
  stdout.writeln('${violations.length} violations');
}
