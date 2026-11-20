# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Unit coverage for scripts/check-error-surface.py.

Drives the real script against a real temp git repo, the same technique
test_check_release_tag_lag.py already uses, because the thing under test
reads `git ls-files` and a file's own text rather than anything a stub
could fake convincingly.

The regression this exists for: an adversarial pass found that `on
api.ApiException { ... }` - valid Dart, catching by type with no bound
variable - was invisible to the gate's original regex, which hard-required
the literal word `catch`. That shape already exists unremarkably several
times in this codebase (presence_controller.dart, blocks_controller.dart,
and others all silently swallow a failure this way), so the blind spot was
not hypothetical: a `ScaffoldMessenger` call dropped into any one of them
would have shipped past this gate exactly the way the three regressions
this gate exists to catch once did.
"""
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "check-error-surface.py"


class CheckErrorSurfaceTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.repo = Path(self._tmp.name)
        self._git("init", "-q")
        self._git("config", "user.email", "test@example.invalid")
        self._git("config", "user.name", "test")
        self.lib = self.repo / "client" / "packages" / "app" / "lib"
        self.lib.mkdir(parents=True)

    def _git(self, *args):
        subprocess.run(
            ["git", *args], cwd=self.repo, check=True,
            capture_output=True, text=True)

    def _write(self, name, body):
        path = self.lib / name
        path.write_text(body)
        self._git("add", str(path.relative_to(self.repo)))

    def _run(self):
        return subprocess.run(
            [sys.executable, str(SCRIPT)], cwd=self.repo,
            capture_output=True, text=True)

    def test_a_guarded_catch_with_no_snackbar_is_fine(self):
        self._write("ok.dart", """
class Foo {
  Future<void> go() async {
    try {
      await api.thing();
    } on api.ApiException catch (e) {
      setState(() => _error = describeApiFailure('do the thing', e));
    }
  }
}
""")
        result = self._run()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("0 offender(s)", result.stdout)

    def test_a_bound_catch_showing_a_snackbar_is_still_caught(self):
        """The original three regressions this gate was built for."""
        self._write("bad_bound.dart", """
class Foo {
  Future<void> go() async {
    try {
      await api.thing();
    } on api.ApiException catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }
}
""")
        result = self._run()
        self.assertEqual(result.returncode, 1)
        self.assertIn("file=client/packages/app/lib/bad_bound.dart,line=6",
                       result.stdout + result.stderr)

    def test_an_unbound_catch_showing_a_snackbar_is_caught(self):
        """`on api.ApiException { ... }`, no `catch (e)` at all - valid
        Dart, and the exact shape the original regex could not see."""
        self._write("bad_unbound.dart", """
class Foo {
  Future<void> go() async {
    try {
      await api.thing();
    } on api.ApiException {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Failed.')));
    }
  }
}
""")
        result = self._run()
        self.assertEqual(result.returncode, 1)
        self.assertIn("file=client/packages/app/lib/bad_unbound.dart,line=6",
                       result.stdout + result.stderr)

    def test_an_unbound_catch_that_swallows_silently_is_fine(self):
        """The common, correct shape: nothing to show, nothing shown."""
        self._write("ok_unbound.dart", """
class Foo {
  Future<void> go() async {
    try {
      await api.thing();
    } on api.ApiException {
      // nothing useful to do
    }
  }
}
""")
        result = self._run()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("0 offender(s)", result.stdout)

    def test_a_bare_unaliased_catch_showing_a_snackbar_is_caught(self):
        """`on ApiException catch (e)` with no `api.` prefix - an unaliased
        `import 'package:slimm_api/api.dart';` writes it exactly this way,
        and roughly a fifth of the real app does. The original `CATCH_HEADER`
        hard-required the prefix and missed this shape entirely; there is no
        `exceptions.dart` in this test's own synthetic repo, so this also
        proves the fallback name list alone is enough to catch the one name
        every call site used before the fix could read the real hierarchy."""
        self._write("bad_bare.dart", """
class Foo {
  Future<void> go() async {
    try {
      await api.thing();
    } on ApiException catch (e) {
      showMenuFailure(context, e.toString());
    }
  }
}
""")
        result = self._run()
        self.assertEqual(result.returncode, 1)
        self.assertIn("file=client/packages/app/lib/bad_bare.dart,line=6",
                       result.stdout + result.stderr)

    def test_a_bare_sealed_subtype_is_caught_via_the_real_hierarchy(self):
        """Plants a minimal `exceptions.dart` so the gate reads a subtype
        name (`ForbiddenException`) rather than falling back, proving the
        dynamic read - not just the hardcoded `ApiException` fallback -
        is what closes the gap for the sealed hierarchy's other members."""
        exceptions_dir = self.repo / "client" / "packages" / "api" / "lib" / "src"
        exceptions_dir.mkdir(parents=True)
        (exceptions_dir / "exceptions.dart").write_text("""
sealed class ApiException implements Exception {}
class ForbiddenException extends ApiException {}
""")
        self._git("add", "client/packages/api/lib/src/exceptions.dart")
        self._write("bad_subtype.dart", """
class Foo {
  Future<void> go() async {
    try {
      await api.thing();
    } on ForbiddenException catch (e) {
      showMenuFailure(context, e.toString());
    }
  }
}
""")
        result = self._run()
        self.assertEqual(result.returncode, 1)
        self.assertIn("file=client/packages/app/lib/bad_subtype.dart,line=6",
                       result.stdout + result.stderr)

    def test_an_unrelated_typed_exception_showing_a_snackbar_stays_out_of_scope(self):
        """`PlatformException` is not in the sealed `ApiException` hierarchy,
        so a typed catch of it stays outside this gate even when it shows a
        SnackBar - this gate is about a failure caught from the server, not
        every typed catch in the app; a fully bare `catch (e)` already covers
        the native-picker case some of these represent."""
        self._write("ok_unrelated_typed.dart", """
class Foo {
  Future<void> pick() async {
    try {
      await plugin.thing();
    } on PlatformException catch (e) {
      showMenuFailure(context, e.toString());
    }
  }

  Future<void> go() async {
    try {
      await api.thing();
    } on api.ApiException catch (e) {
      setState(() => _error = describeApiFailure('do the thing', e));
    }
  }
}
""")
        result = self._run()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("0 offender(s)", result.stdout)

    def test_a_catcherror_callback_showing_a_snackbar_is_caught(self):
        """A Future's own `.catchError((e) { ... })`, not a `catch` block at
        all - reproduced by an adversarial pass, which found the gate said
        nothing while this exact shape sat in a tracked file."""
        self._write("bad_catcherror.dart", """
class Foo {
  void go() {
    api.thing().catchError((e) {
      showMenuFailure(context, e.toString());
    });
  }
}
""")
        result = self._run()
        self.assertEqual(result.returncode, 1)
        self.assertIn(
            "file=client/packages/app/lib/bad_catcherror.dart,line=4",
            result.stdout + result.stderr)

    def test_a_catcherror_callback_that_swallows_silently_is_fine(self):
        """The idiom this codebase already uses elsewhere
        (sync_controller.dart, providers.dart) to drop a failure on the
        floor on purpose - must not become an offender just for existing.
        Multi-line on purpose: a one-line `.catchError((_) {});` closes on
        the header's own line and is never recognised as a block at all,
        which would make this test pass for the wrong reason."""
        self._write("ok_catcherror.dart", """
class Foo {
  void go() {
    api.thing().catchError((_) {
      // nothing useful to do
    });
  }
}
""")
        result = self._run()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("0 offender(s)", result.stdout)


    def _assert_flagged(self, name, line):
        result = self._run()
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn(
            f"file=client/packages/app/lib/{name},line={line}",
            result.stdout + result.stderr)

    def test_a_runguarded_sentence_shown_as_a_snackbar_is_caught(self):
        """runGuarded catches internally, so the caller has no catch block at
        all; the bulk member actions shipped this shape past the gate."""
        self._write("bad_guarded.dart", """
Future<void> remove(WidgetRef ref, BuildContext context) async {
  final failure = await runGuarded(
    whatFailed: 'remove the member',
    action: () => ref.read(apiProvider).removeMember(),
  );
  if (failure != null) {
    if (context.mounted) showMenuFailure(context, failure);
    return;
  }
}
""")
        self._assert_flagged("bad_guarded.dart", 8)

    def test_a_runguarded_sentence_through_the_outcome_helper_is_caught(self):
        self._write("bad_outcome.dart", """
Future<void> toggle(BuildContext context) async {
  final failure = await runGuarded(
    whatFailed: 'change it',
    action: () => api.thing(),
  );
  if (!context.mounted) return;
  showMenuOutcome(context, failure: failure, succeeded: 'Changed.');
}
""")
        self._assert_flagged("bad_outcome.dart", 8)

    def test_a_caught_failure_through_the_outcome_helper_is_caught(self):
        self._write("bad_outcome_catch.dart", """
class Foo {
  Future<void> go() async {
    try {
      await api.thing();
    } on ApiException catch (e) {
      showMenuOutcome(context, failure: e.toString(), succeeded: 'x');
    }
  }
}
""")
        self._assert_flagged("bad_outcome_catch.dart", 6)

    def test_a_then_bound_runguarded_sentence_is_caught(self):
        self._write("bad_then.dart", """
Future<void> remove(BuildContext host, ProviderContainer container) async {
  await runGuarded(
    whatFailed: 'remove them',
    action: () => container.read(apiProvider).removeMember(),
  ).then((failure) {
    if (failure != null) {
      showMenuFailure(host, failure);
    }
  });
}
""")
        self._assert_flagged("bad_then.dart", 8)

    def test_a_class_member_runguarded_sentence_is_caught(self):
        self._write("bad_member.dart", """
class Foo {
  Future<void> _eject(BuildContext host) async {
    final failure = await runGuarded(
      whatFailed: 'eject',
      action: () => api.kick(),
    );
    if (failure != null && host.mounted) {
      showMenuFailure(host, failure);
    }
  }
}
""")
        self._assert_flagged("bad_member.dart", 9)

    def test_a_runguarded_sentence_held_for_an_error_state_is_fine(self):
        self._write("ok_guarded.dart", """
Future<void> remove(WidgetRef ref) async {
  final failure = await runGuarded(
    whatFailed: 'remove the member',
    action: () => ref.read(apiProvider).removeMember(),
  );
  if (failure != null) {
    ref.read(errorProvider.notifier).state = failure;
  }
}
""")
        result = self._run()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("0 offender(s)", result.stdout)

    def test_a_snackbar_in_another_function_is_not_this_ones_failure(self):
        """The variable is only the failure inside the function that bound
        it; a same-named local elsewhere in the file is not."""
        self._write("ok_scope.dart", """
Future<void> remove(WidgetRef ref) async {
  final failure = await runGuarded(
    whatFailed: 'remove the member',
    action: () => ref.read(apiProvider).removeMember(),
  );
  if (failure != null) {
    ref.read(errorProvider.notifier).state = failure;
  }
}

void copy(BuildContext context) {
  final failure = 'copied';
  showMenuFailure(context, failure);
}
""")
        result = self._run()
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_a_literal_snackbar_beside_runguarded_is_fine(self):
        self._write("ok_literal.dart", """
Future<void> save(WidgetRef ref, BuildContext context) async {
  final failure = await runGuarded(
    whatFailed: 'save',
    action: () => ref.read(apiProvider).save(),
  );
  if (failure != null) return;
  showMenuFailure(context, 'Saved.');
}
""")
        result = self._run()
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_a_commented_out_guarded_snackbar_is_ignored(self):
        self._write("ok_comment.dart", """
Future<void> remove(WidgetRef ref, BuildContext context) async {
  final failure = await runGuarded(
    whatFailed: 'remove',
    action: () => ref.read(apiProvider).removeMember(),
  );
  // showMenuFailure(context, failure);
  if (failure != null) ref.read(errorProvider.notifier).state = failure;
}
""")
        result = self._run()
        self.assertEqual(result.returncode, 0, result.stdout)


if __name__ == "__main__":
    unittest.main()
