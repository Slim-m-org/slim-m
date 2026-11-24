// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Structure readers for source-reading gates, shared so no gate hand-rolls one.
library;

import 'code_only.dart';

final _directive = RegExp(
  r'''^[ \t]*(?:import|export)\s+(?:(?:'[^']*'|"[^"]*")(?:\s+if\s*\([^)]*\)\s*(?:'[^']*'|"[^"]*"))*)''',
  multiLine: true,
);
final _uri = RegExp(r'''(?:'([^']*)'|"([^"]*)")''');
final _ifCondition = RegExp(r'if\s*\([^)]*\)');

/// Every URI named by an import or export in [source], including each
/// alternate of a conditional directive, with either quote style.
List<String> directiveUris(String source) {
  final code = stripComments(source);
  return [
    for (final directive in _directive.allMatches(code))
      for (final uri in _uri.allMatches(
        directive[0]!.replaceAll(_ifCondition, ' '),
      ))
        uri[1] ?? uri[2]!,
  ];
}

/// The text between the parenthesis at [openAt] in [code] and its match, or
/// null when it never closes. Run it on [codeOnly] output so strings cannot
/// unbalance it.
String? callArguments(String code, int openAt) {
  var depth = 0;
  for (var i = openAt; i < code.length; i++) {
    final c = code[i];
    if (c == '(') {
      depth++;
    } else if (c == ')') {
      depth--;
      if (depth == 0) return code.substring(openAt + 1, i);
    }
  }
  return null;
}
