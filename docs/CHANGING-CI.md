<!-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0 -->
# Changing CI safely

Six incidents showed that a workflow change can pass every check and still break a release or a deploy.
Each section says what happened, why nothing caught it, the rule, and the gate that exists now, if one does.
[ci.md](ci.md) stays the reference for what each workflow does, and this page is only about how to change them.

## 1. A composite action cannot read `vars` or `secrets`

What happened: the Linux tarball step needed the Spotify client id, which is a repository variable.
The tarball is built by the composite action `.github/actions/linux-tarball`, which read `vars.SLIMM_SPOTIFY_CLIENT_ID` directly.
A composite action has no `vars` context, so the template failed to load and took the `linux-client` job down with it.

Why no gate caught it: `actionlint` does not model that, so the file passed review and the failure appeared only when the job ran.

The rule: read `vars` and `secrets` in the calling workflow, and pass them to a composite action as inputs.
`linux-tarball` takes `spotify_client_id`, and `main-builds.yml` passes `${{ vars.SLIMM_SPOTIFY_CLIENT_ID }}` (PR #1531).

Gate: `scripts/lib/test_composite_actions_read_only_what_they_can.py` refuses `vars`, `secrets`, `needs`, `jobs`, `matrix` and `strategy` in any composite action, and a `run:` step with no `shell:`.
It returns `vars.SLIMM_SPOTIFY_CLIENT_ID` when run on the version of `linux-tarball` that broke the build.

## 2. A green `main-builds` run is not a deploy

What happened: on 2026-09-10 a server fix was merged, a later merge cancelled the run that carried it, and every run after that reported `server-image: skipped`.
GHCR `latest` stayed on an old commit and the live instance ran it for 16 hours.
A fix merged during a merge storm can still fail to deploy for the same reason.

Why no gate caught it: a skipped job counts as a successful one, and a cancelled job's `changes` output is empty, so re-running it skips too.
Every run was green.

The rule: judge a deploy by the job list and by what GHCR holds, not by the run's colour.
Check `server-image` ran and succeeded for your commit, or inspect the image.
`workflow_dispatch` on `main-builds` has three booleans, `server`, `client` and `packaging`, and a manual run builds exactly the sides you set, so it forces the jobs a path filter skipped.

```bash
gh run view <run-id> --json jobs --jq '.jobs[] | [.name, .conclusion] | @tsv'
docker buildx imagetools inspect ghcr.io/slim-m-org/slim-m-server:latest
gh workflow run main-builds.yml --ref main -f server=true -f client=false -f packaging=false
```

Gate: partly.
`scripts/server-image-needed.sh` decides the server side from what has changed since the last image that really built, so the next push of any kind picks up a cancelled build (`scripts/lib/test_server_image_base.py`).
`scripts/web-image-needed.sh` does the same for the web image.
`client` and `packaging` still decide from the push diff alone and keep the hole, by design.
See "Concurrency" in the `main-builds` section of [ci.md](ci.md).

## 3. A workflow that runs only on a tag is first run by the release

What happened: `desktop-clients.yml` runs on a `client-v*` tag push and by hand, and nowhere else.
A change to it moved the Windows build to `shell: bash`.
On Windows, Git Bash rewrites an environment value that begins with a slash into a path before handing it to a native program, and the job sets `CL` to such a value.
The compiler was no longer found, the Windows zip was not built, and the manifest job skipped.
Client 0.89.0 shipped without the zip and without `manifest.json`.

Why no gate caught it: the pull request could not fail, because the workflow did not run on it.
Nothing compares a published release with the assets it should have, so the release page looked finished.

The rule: run a tag-only workflow from your branch against the newest existing tag before you merge.
It rebuilds and re-attaches the same assets with `--clobber`, which is harmless.
Do not run a Windows build under `shell: bash`.
After the release, check the asset list against [RELEASING.md](RELEASING.md).

```bash
gh workflow run desktop-clients.yml --ref <branch> -f tag=client-v<newest>
```

Gate: `scripts/lib/test_windows_builds_do_not_run_under_bash.py` refuses `flutter build` under `shell: bash` in a Windows job.
It closes that one door only.
`release-asset-watchdog.yml` runs `scripts/check-release-assets.py` hourly, which compares every release of the last three days with the asset set its kind always carries and opens an issue labelled `release-incomplete` when one is short.
It gives a release 90 minutes to finish attaching before it counts.
A release that is known to be short and has been superseded goes in `scripts/release-asset-exempt.txt`, one line per tag: the tag, then why.
Exempt a tag only when a later release replaces it, since an exemption silences the issue for good and the file is meant to stay short.
`client-v0.91.0` is there because its macOS build crashed and `client-v0.91.1` replaced it.

## 4. A merge storm cancels `main-builds`

What happened: on 2026-09-25 four `main-builds` runs were cancelled before their `copr` job finished.
COPR stayed on 0.84.0 while `main` reached 0.86.0, and nothing was red.
The same cancellation is what left the server fix in section 2 undeployed.

Why no gate caught it: `main-builds` sets `cancel-in-progress: true` on purpose, and a cancelled run is not a failure.
Release publishing is the opposite, and a storm can also starve a release commit's own checks until `verify-release-checks` times out.

The rule: after a burst of merges, confirm the outcomes and not the runs.
Check GHCR `latest` for the server and `dnf upgrade --refresh slim-m-client` or `scripts/copr-behind.sh` for COPR.
If a release's verify timed out, rerun it once the checks pass.

Gate: `copr-catch-up.yml` asks COPR's own API whether it is behind `client/pubspec.yaml` after each `main-builds` run and every six hours, and submits if so.
`release-tag-watchdog.yml` re-dispatches a release whose verify timed out.
Nothing equivalent exists for the web image or the Android artifact.

## 5. Two green pull requests can break main

What happened: twice, two pull requests that were each green merged one after the other and `main` went red, once on a file budget (507 lines) and once on a shared test.

Why no gate caught it: a pull request runs against the base it branched from, and `main` has no branch protection or ruleset, so nothing tests the merge result before it lands.

The rule: a required workflow must also trigger on `merge_group`, which ignores `paths:` filters, and a ruleset may only require checks that run for every pull request and every queue entry.
Do not add a path-gated job's name to the ruleset: it never reports on an unrelated PR and the PR waits forever.

Gate: `scripts/lib/test_merge_queue_ruleset_matches_the_workflows.py` fails when a required context is not a job in a workflow with `merge_group`, or one of the five queue workflows loses the trigger.
`scripts/lib/test_pr_workflows_cancel_superseded_runs_but_main_never.py` keeps superseded PR runs cancelling and `main` runs never cancelling.

What the owner does in GitHub (the repository does not change settings itself):

1. Settings, Rules, Rulesets, New ruleset, Import a ruleset, choose `.github/rulesets/main-merge-queue.json`.
2. Check the target is the default branch, enforcement is Active, and the bypass list is Repository admin.
3. Open a throwaway PR, wait for `hygiene`, press "Merge when ready", and watch the queue entry run `hygiene` (and `client-ci` and `server-ci` if it touched their paths) on the `gh-readonly-queue/main/...` branch.
4. If a path-gated PR sits at "Expected" forever, remove the ruleset's required check and tell whoever is changing CI; that is the failure the rule above is about.
5. Release PRs go through the queue like any other PR; confirm the next one merges.

## 6. Landing a stack of pull requests

Every pull request runs the full client or server suite, and a merge to `main` can deploy.
Merging a stack one by one therefore costs one full run and one `main-builds` per pull request, and a later one can break on an earlier one that was never tested beside it ([section 5](#5-two-green-pull-requests-can-break-main)).
Instead, branch from `origin/main`, merge each pull request's branch into it in order, and fix any conflict once.
Run the gates on that integration branch, then open it as one pull request and let CI run once.
Merge that, close the originals, and read `git diff --stat origin/main` first, since a stale base would revert work.
The cost of a run is in [ci.md](ci.md#where-a-pull-requests-time-goes-measured-2026-10-02): a client pull request is about 150 runner-minutes, most of it the eight app shards and the dart2js job.
The `libmpv` apt step was the tail there, and the shards now install `libmpv2` with retries and a step timeout.

## After any workflow change

1. Run `actionlint` and `shellcheck` at the digests pinned in `hygiene.yml`, not whatever is on your PATH.
2. Run `(cd scripts/lib && python3 -m unittest discover -p 'test_*.py')` after `git add`, since gates skip untracked files.
3. Update the workflow's row in the `docs/ci.md` table, including every trigger it has (`scripts/check-ci-docs.py` and `scripts/lib/test_ci_docs_triggers.py`).
4. If it runs only on a tag or by hand, dispatch it from the branch against an existing tag and read the job list.
5. If it reads `vars` or `secrets`, make sure each is read in a workflow and passed down as an input.
6. After merging, open the next `main-builds` run and read which jobs ran and which skipped.
7. After the next release, compare its assets with [RELEASING.md](RELEASING.md).
