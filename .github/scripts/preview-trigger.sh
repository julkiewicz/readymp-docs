#!/usr/bin/env bash
# Decides whether an event asks for a docs preview, or asks for a pull request's docs previews to be deleted.
#
# A copy of the ReadyM server's script of the same name, which this repository's previews were modelled on. Kept
# apart from the workflow that acts on it so the decision can be exercised directly, by preview-trigger.test.sh.
# A deploy hands a job the Azure credential, so this decision is the gate on it and is worth being able to test
# without deploying anything. The workflow runs that test before it acts on this, so a broken decision stops the
# run rather than deciding anything.
#
# Pure by design: it reads its arguments and writes one word. Asking GitHub who someone is, resolving a pull
# request and deploying are the caller's job, and none of them belong in something a test should run freely.
#
# There is no commit message route, deliberately. The server had `[preview]` and `[clearpreview]` in commit
# messages and removed them on 2026-10-22: hardly used, and they made the decision harder to read.
set -euo pipefail

# The comment that asks for a preview of a pull request's current head.
PREVIEW_COMMAND='/preview'

# The comments that delete every preview belonging to a pull request, whether or not it has closed. Two spellings
# because both are the one somebody reaches for first, and a command that silently does nothing is a worse thing
# to have than a synonym.
CLEAR_COMMAND='/clearpreview'
CLEAR_COMMAND_PLURAL='/clearpreviews'

# A command has to be a comment's first non-empty line, on its own. Mentioning one in a sentence, which is what
# every explanation of how to use them does, must do nothing at all.
#
# Writes the command found, or nothing. Reading the line out rather than testing it against one command keeps the
# rule about where a command may appear in one place as more commands are added.
preview_comment_command() {
  local line
  while IFS= read -r line; do
    line="$(printf '%s' "$line" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [ -z "$line" ] && continue
    printf '%s' "$line"
    return
  done <<EOF
$1
EOF
}

# Writes "deploy", "clear" or "skip".
#
#   $1  event name: issue_comment or workflow_dispatch
#   $2  "true" when the person who asked passed every identity check the workflow makes: write access to THIS
#       repository, established by asking GitHub, and a place on the admin-kept allowlist
#   $3  comment body, for issue_comment
#   $4  "true" when an issue_comment came from a pull request rather than an issue
#
# The identity checks are required on every path, without exception. A deploy builds and publishes code from the
# branch under review, so the ability to start one must not be wider than the ability to push. Deleting is gated the same way and for a plainer reason: it destroys an environment somebody may be testing
# on.
preview_decision() {
  local event="$1" may_deploy="${2-}" comment_body="${3-}" on_pull_request="${4-}"

  if [ "$may_deploy" != true ]; then
    echo skip
    return
  fi

  case "$event" in
    issue_comment)
      if [ "$on_pull_request" != true ]; then
        echo skip
        return
      fi

      case "$(preview_comment_command "$comment_body")" in
        "$PREVIEW_COMMAND") echo deploy ;;
        "$CLEAR_COMMAND" | "$CLEAR_COMMAND_PLURAL") echo clear ;;
        *) echo skip ;;
      esac
      ;;
    # Dispatch is manual and names its pull request explicitly. The identity checks, above, are all that is left
    # to decide.
    workflow_dispatch) echo deploy ;;
    *) echo skip ;;
  esac
}

# Sourced by the test, run directly by the workflow.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  preview_decision "$@"
fi
