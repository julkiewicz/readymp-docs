#!/usr/bin/env bash
# Checks that the docs preview workflow still keeps pull request code away from the Azure credential.
#
# Run by the Gate job in .github/workflows/preview.yml, against the default branch's copy of that file, before
# anything else happens. Run it by hand: bash .github/scripts/check-preview-workflow.sh .github/workflows/preview.yml
#
# **Why this exists.** This repository is public, so anyone can open a pull request, and a preview builds that pull
# request's code. That is only safe because of how the workflow is cut into jobs: GitHub-hosted runners give every
# job a fresh machine, and a job only receives a secret it references or an environment it declares. So the build
# job, which runs the pull request's `yarn install` and `yarn build`, must hold nothing worth stealing, and the jobs
# that do hold the credential must never run the pull request's code. Those properties live in the shape of the
# YAML, where one careless edit can quietly undo them. This reads the shape and refuses to continue if it changed.
#
# The deploy and clear jobs re-check what they can at run time, independently. Do not relax a rule here because
# the other stage has a similar one; the point is that both would have to be broken at once.
#
# Needs `yq` (mikefarah, v4), which GitHub's Ubuntu runner images include.
set -euo pipefail

workflow="${1:?usage: check-preview-workflow.sh <path to preview.yml>}"
problems=0

problem() {
  echo "::error file=${workflow}::$*"
  problems=$((problems + 1))
}

# A new job could do anything, including run pull request code next to a secret, without any rule below noticing.
# So the set of jobs is fixed, and adding one means updating this check on purpose.
jobs="$(yq '.jobs | keys | .[]' "$workflow" | sort | paste -sd, -)"
if [ "$jobs" != "build,build-failed,clear,deploy,gate" ]; then
  problem "the jobs are '${jobs}', not exactly gate, build, build-failed, deploy and clear."
fi

# Top-level permissions apply to any job that does not set its own, and top-level env reaches every job. Neither
# may hand anything to the build job by default.
if [ "$(yq -o=json -I=0 '.permissions' "$workflow")" != "{}" ]; then
  problem "top-level permissions must be {} so no job gets anything it did not ask for."
fi
if yq -o=json '.env // {}, .defaults // {}' "$workflow" | grep -q 'secrets\.'; then
  problem "a secret is referenced at the top level, which would reach every job, the build job included."
fi

# Every job on a GitHub-hosted runner. A self-hosted runner is not wiped between jobs, so the separation between
# them would not hold at all.
while IFS=$'\t' read -r job runs_on; do
  case "$runs_on" in
    ubuntu-*) ;;
    *) problem "job '${job}' runs on '${runs_on}'; every job must be on a GitHub-hosted ubuntu-* runner." ;;
  esac
done < <(yq '.jobs | to_entries | .[] | [.key, (.value.runs-on | tostring)] | @tsv' "$workflow")

# THE BUILD JOB runs the pull request's code. It must hold nothing: no secret, no environment, a read-only token.
if [ "$(yq '.jobs.build.environment' "$workflow")" != "null" ]; then
  problem "the build job declares an environment, which would hand it that environment's secrets."
fi
if [ "$(yq -o=json -I=0 '.jobs.build.permissions' "$workflow")" != '{"contents":"read"}' ]; then
  problem "the build job's permissions must be exactly contents: read."
fi
if yq -o=json '.jobs.build' "$workflow" | grep -q 'secrets\.'; then
  problem "the build job references a secret."
fi
if [ "$(yq '.jobs.build | has("container") or has("services")' "$workflow")" != "false" ]; then
  problem "the build job declares a container or services, whose credentials it would hold."
fi

# Only the deploy and clear jobs may hold a secret or an environment. Everything else, the gate and the job that
# reports a failed build included, gets neither.
for job in $(yq '.jobs | keys | .[]' "$workflow"); do
  case "$job" in deploy | clear) continue ;; esac
  if [ "$(yq ".jobs.\"${job}\".environment" "$workflow")" != "null" ]; then
    problem "the ${job} job declares an environment; only deploy and clear may."
  fi
  if yq -o=json ".jobs.\"${job}\"" "$workflow" | grep -q 'secrets\.'; then
    problem "the ${job} job references a secret; only deploy and clear may."
  fi
done

# THE CREDENTIAL JOBS must never run the pull request's code. They check out only the default branch, take
# nothing from the build job but its artifact, and never run a package manager or Node.
for job in deploy clear; do
  if [ "$(yq ".jobs.${job}.environment" "$workflow")" != "Preview" ]; then
    problem "the ${job} job must declare the Preview environment, which is restricted to the default branch."
  fi

  checkouts="$(yq ".jobs.${job}.steps[] | select(.uses // \"\" | test(\"^actions/checkout@\")) | [(.with.ref // \"\"), (.with.repository // \"\")] | join(\",\")" "$workflow")"
  while IFS= read -r checkout; do
    [ -z "$checkout" ] && continue
    if [ "$checkout" != "," ]; then
      problem "the ${job} job checks out '${checkout}'; it may only check out the default branch, with no ref."
    fi
  done <<< "$checkouts"

  if yq ".jobs.${job}.steps[].uses // \"\"" "$workflow" | grep -Eq 'setup-node'; then
    problem "the ${job} job sets up Node, which it has no reason to run."
  fi
  if yq ".jobs.${job}.steps[].run // \"\"" "$workflow" | grep -Ewq '(yarn|npm|npx|node|corepack|pnpm)'; then
    problem "the ${job} job runs a package manager or Node, which could run the pull request's code."
  fi
  if yq -o=json ".jobs.${job}" "$workflow" | grep -q 'needs\.build\.'; then
    problem "the ${job} job reads something from the build job other than its artifact."
  fi
done

if [ "$problems" -ne 0 ]; then
  echo "${problems} problem(s). The preview workflow no longer keeps pull request code away from the credential."
  exit 1
fi

echo "The preview workflow keeps pull request code away from the credential."
