#!/usr/bin/env bash
# Exercises the preview trigger decision. Run it: bash .github/scripts/preview-trigger.test.sh
#
# No framework, on purpose. The thing under test writes one word, so a test needs nothing more than a way to say
# which word it expected, and this stays runnable on a laptop and on a runner without installing anything.
#
# The preview workflow runs this before it acts on a decision, so a failure here stops every preview.
set -uo pipefail

# shellcheck source=preview-trigger.sh
. "$(dirname "$0")/preview-trigger.sh"

# The file just sourced turns on exit-on-error, which is right for it and wrong here: a failing case has to be
# reported and the remaining cases still run.
set +e

failures=0

expect() {
  local expected="$1" description="$2"
  shift 2
  local actual
  actual="$(preview_decision "$@")"
  if [ "$actual" = "$expected" ]; then
    echo "  ok    $description"
  else
    echo "  FAIL  $description: expected '$expected', got '$actual'"
    failures=$((failures + 1))
  fi
}

echo "Comment:"
expect deploy "the command alone" \
  issue_comment true '/preview' true
expect deploy "the command with surrounding whitespace" \
  issue_comment true '
   /preview
' true
expect deploy "the command followed by more text on later lines" \
  issue_comment true '/preview

for the checkout bug' true
expect skip "the command mentioned in prose" \
  issue_comment true 'You can comment /preview to get one of these.' true
expect skip "a comment on an issue rather than a pull request" \
  issue_comment true '/preview' false
expect skip "an empty comment" \
  issue_comment true '' true

echo "Clearing by comment:"
expect clear "the singular spelling" \
  issue_comment true '/clearpreview' true
expect clear "the plural spelling" \
  issue_comment true '/clearpreviews' true
expect clear "the command with surrounding whitespace" \
  issue_comment true '
   /clearpreviews
' true
expect clear "the command followed by more text on later lines" \
  issue_comment true '/clearpreview

these are stale now' true
expect skip "the command mentioned in prose" \
  issue_comment true 'Comment /clearpreview when you are done with it.' true
expect skip "a near miss that is not a command" \
  issue_comment true '/clearpreviewss' true
expect skip "clearing from a comment on an issue rather than a pull request" \
  issue_comment true '/clearpreview' false

echo "Dispatch:"
expect deploy "manual dispatch" workflow_dispatch true '' ''

echo "Without passing the identity checks, nothing happens:"
expect skip "the command from outside the team" \
  issue_comment false '/preview' true
expect skip "dispatch by someone without write access" \
  workflow_dispatch false '' ''
expect skip "clearing from outside the team" \
  issue_comment false '/clearpreview' true
expect skip "identity that could not be established at all" \
  issue_comment '' '/preview' true

echo "There is no commit message route:"
# A pull request event is not a trigger here, but if one ever reaches this it must not deploy.
expect skip "a pull request event" \
  pull_request_target true '' ''
expect skip "the old token written as a comment" \
  issue_comment true '[preview]' true

echo "Anything else:"
expect skip "an event nothing asked for" schedule true '' ''

if [ "$failures" -ne 0 ]; then
  echo "$failures failed."
  exit 1
fi

echo "All passed."
