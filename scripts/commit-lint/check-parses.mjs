// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0

/**
 * Gate: catch a commit body that crashes release-please's real parser,
 * without failing a PR over a commit subject that is merely not a
 * conventional commit, which under squash-merge is harmless.
 *
 * The PR title is parsed against the strict top-level grammar, because it is
 * the summary line of the squash message. Each commit is parsed as body text
 * under a synthetic `chore: placeholder` summary, so only the one production
 * that cannot recover (`scope()` on an unclosed `(`) can fail it. The parser
 * is pinned by package-lock.json to the version release-please resolves.
 * Why, and what this cannot see: docs/ci-details.md, "Commit bodies that
 * crash release-please's parser".
 */

import { execFileSync } from 'node:child_process'
import { parser } from '@conventional-commits/parser'

const CRASH_PROBE_PREFIX = 'chore: placeholder\n\n'
const CRASH_PROBE_PREFIX_LINES = 2

function commitShas(baseSha, headSha) {
  const out = execFileSync(
    'git', ['log', '--no-merges', '--reverse', '--format=%H', `${baseSha}..${headSha}`],
    { encoding: 'utf8' },
  )
  return out.split('\n').filter((line) => line.length > 0)
}

function commitMessage(sha) {
  return execFileSync('git', ['log', '-1', '--format=%B', sha], { encoding: 'utf8' })
}

function tryParse(text) {
  try {
    parser(text)
    return null
  } catch (err) {
    return err
  }
}

function shiftReportedLine(message, lines) {
  return message.replace(/at (\d+):(\d+)/, (whole, line, col) => {
    const shifted = Number(line) - lines
    return shifted > 0 ? `at ${shifted}:${col}` : whole
  })
}

function checkTitle(title) {
  const err = tryParse(title)
  return err ? `PR title: ${err.message}` : null
}

function checkCommitCrashRisk(label, message) {
  const err = tryParse(CRASH_PROBE_PREFIX + message)
  if (!err) return null
  return `${label}: ${shiftReportedLine(err.message, CRASH_PROBE_PREFIX_LINES)}`
}

function main() {
  const title = process.env.PR_TITLE
  const baseSha = process.env.BASE_SHA
  const headSha = process.env.HEAD_SHA
  if (!title || !baseSha || !headSha) {
    console.error('PR_TITLE, BASE_SHA and HEAD_SHA must all be set')
    process.exit(2)
  }

  const shas = commitShas(baseSha, headSha)
  const failures = []
  const titleFailure = checkTitle(title)
  if (titleFailure) failures.push(titleFailure)

  for (const sha of shas) {
    const message = commitMessage(sha)
    const subject = message.split('\n', 1)[0]
    const failure = checkCommitCrashRisk(`${sha.slice(0, 7)} "${subject}"`, message)
    if (failure) failures.push(failure)
  }

  if (failures.length > 0) {
    // One line each; the reasoning lives in docs/ci-details.md.
    console.error('release-please cannot parse the following, and would silently drop them from the changelog:')
    for (const failure of failures) console.error(`  - ${failure}`)
    console.error('')
    console.error('Reword the offending line (often a code fragment with nested or unbalanced parens right after a blank line) so it does not read as a malformed conventional-commit footer.')
    process.exit(1)
  }

  console.log(`commit message parse: PR title parses cleanly, and ${shas.length} commit(s) carry no parser-crashing line`)
}

main()
