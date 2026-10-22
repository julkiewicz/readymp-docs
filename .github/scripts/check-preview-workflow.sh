#!/usr/bin/env bash
# Checks that the docs preview workflows still keep pull request code away from the Azure credential.
#
# Run by the Gate job in .github/workflows/preview.yml, against the default branch's copy of the workflows, before
# anything else happens. Run it by hand: bash .github/scripts/check-preview-workflow.sh .github/workflows
#
# **Why this exists.** This repository is public, so anyone can open a pull request, and a preview builds that pull
# request's code. That is only safe because of how the workflow is cut into jobs: GitHub-hosted runners give every
# job a fresh machine, and a job only receives a secret it references or an environment it declares. So the build
# job, which runs the pull request's `yarn install` and `yarn build`, must hold nothing worth stealing, and every
# other job must never run the pull request's code. Those properties live in the shape of the YAML, where one
# careless edit can quietly undo them. This reads the shape and refuses to continue if it changed.
#
# The deploy and clear jobs re-check what they can at run time, independently. Do not relax a rule here because
# the other stage has a similar one; the point is that both would have to be broken at once.
#
# It can only notice a dangerous workflow, not stop one from being merged. Review of changes under `.github/` is
# what stops that; this makes sure previews stop the moment one lands.
#
# Needs `yq` (mikefarah, v4), which GitHub's Ubuntu runner images include.
set -euo pipefail

workflows="${1:?usage: check-preview-workflow.sh <path to .github/workflows>}"
workflow="${workflows}/preview.yml"
sweep="${workflows}/preview-sweep.yml"
problems=0

problem() {
  echo "::error file=$1::$2"
  problems=$((problems + 1))
}

# Every way a workflow can name a secret: `secrets.X`, `secrets['X']`, `toJSON(secrets)`. Matched as a word rather
# than as `secrets.`, which the other two spellings walk straight past.
mentions_secrets() { grep -Ewq 'secrets'; }

# Anything that installs or runs JavaScript, which is how the pull request's code would run.
runs_package_code() { grep -Ewq '(yarn|npm|npx|node|corepack|pnpm|bun|deno)'; }

# THE JOBS. A new job could do anything, including run pull request code next to a secret, without any rule below
# noticing. So the set of jobs is fixed, and adding one means updating this check on purpose.
jobs="$(yq '.jobs | keys | .[]' "$workflow" | sort | paste -sd, -)"
if [ "$jobs" != "build,build-failed,clear,deploy,gate" ]; then
  problem "$workflow" "the jobs are '${jobs}', not exactly gate, build, build-failed, deploy and clear."
fi

# Top-level permissions apply to any job that does not set its own, and top-level env reaches every job. Neither
# may hand anything to the build job by default.
if [ "$(yq -o=json -I=0 '.permissions' "$workflow")" != "{}" ]; then
  problem "$workflow" "top-level permissions must be {} so no job gets anything it did not ask for."
fi
if yq -o=json '.env // {}, .defaults // {}' "$workflow" | mentions_secrets; then
  problem "$workflow" "a secret is referenced at the top level, which would reach every job, the build job included."
fi

# Every job on a GitHub-hosted runner. A self-hosted runner is not wiped between jobs, so the separation between
# them would not hold at all.
while IFS=$'\t' read -r job runs_on; do
  case "$runs_on" in
    ubuntu-*) ;;
    *) problem "$workflow" "job '${job}' runs on '${runs_on}'; every job must be on a GitHub-hosted ubuntu-* runner." ;;
  esac
done < <(yq '.jobs | to_entries | .[] | [.key, (.value.runs-on | tostring)] | @tsv' "$workflow")

# THE BUILD JOB runs the pull request's code. It must hold nothing: no secret, no environment, a read-only token,
# and no outputs, so the only thing that leaves it is the artifact.
if [ "$(yq -o=json -I=0 '.jobs.build.permissions' "$workflow")" != '{"contents":"read"}' ]; then
  problem "$workflow" "the build job's permissions must be exactly contents: read."
fi
if [ "$(yq '.jobs.build | has("container") or has("services")' "$workflow")" != "false" ]; then
  problem "$workflow" "the build job declares a container or services, whose credentials it would hold."
fi
if [ "$(yq '.jobs.build | has("outputs")' "$workflow")" != "false" ]; then
  problem "$workflow" "the build job declares outputs; nothing but its artifact may leave it."
fi

for job in $(yq '.jobs | keys | .[]' "$workflow"); do
  # Only the deploy and clear jobs may hold a secret or an environment.
  case "$job" in
    deploy | clear) ;;
    *)
      if [ "$(yq ".jobs.\"${job}\".environment" "$workflow")" != "null" ]; then
        problem "$workflow" "the ${job} job declares an environment; only deploy and clear may."
      fi
      if yq -o=json ".jobs.\"${job}\"" "$workflow" | mentions_secrets; then
        problem "$workflow" "the ${job} job references a secret; only deploy and clear may."
      fi
      ;;
  esac

  # Only the build job may run the pull request's code. Every other job holds either the credential or a token that
  # can write to pull requests, so it checks out only the default branch and never runs a package manager.
  [ "$job" = build ] && continue

  checkouts="$(yq ".jobs.\"${job}\".steps[] | select(.uses // \"\" | test(\"^actions/checkout@\")) | [(.with.ref // \"\"), (.with.repository // \"\")] | join(\",\")" "$workflow")"
  while IFS= read -r checkout; do
    [ -z "$checkout" ] && continue
    if [ "$checkout" != "," ]; then
      problem "$workflow" "the ${job} job checks out '${checkout}'; only the build job may check out anything but the default branch."
    fi
  done <<< "$checkouts"

  if yq ".jobs.\"${job}\".steps[].uses // \"\"" "$workflow" | grep -Eq '(setup-node|^\./)'; then
    problem "$workflow" "the ${job} job sets up Node or uses a local action; only the build job may run anything of the pull request's."
  fi
  if yq ".jobs.\"${job}\".steps[].run // \"\"" "$workflow" | runs_package_code; then
    problem "$workflow" "the ${job} job runs a package manager or Node; only the build job may."
  fi
done

# THE CREDENTIAL JOBS. An allowlist rather than a denylist, because the list of ways to run something is endless.
for job in deploy clear; do
  if [ "$(yq ".jobs.${job}.environment" "$workflow")" != "Preview" ]; then
    problem "$workflow" "the ${job} job must declare the Preview environment, which is restricted to the default branch."
  fi

  while IFS= read -r uses; do
    [ -z "$uses" ] && continue
    case "$uses" in
      actions/checkout@* | actions/download-artifact@* | azure/login@*) ;;
      *) problem "$workflow" "the ${job} job uses '${uses}'; it may only use actions/checkout, actions/download-artifact and azure/login." ;;
    esac
  done < <(yq ".jobs.${job}.steps[].uses // \"\"" "$workflow")

  # Nothing here may start an interpreter or make something executable: the built site sits in this workspace,
  # and none of it is to be run.
  if yq ".jobs.${job}.steps[].run // \"\"" "$workflow" \
    | grep -Ewq '(bash|sh|zsh|dash|source|eval|exec|python|python3|perl|ruby|pwsh|php|chmod)'; then
    problem "$workflow" "the ${job} job starts an interpreter or makes something executable."
  fi
  if yq ".jobs.${job}.steps[].run // \"\"" "$workflow" | grep -Eq '(^|[[:space:];|&(])\./'; then
    problem "$workflow" "the ${job} job runs something by relative path."
  fi

  # The build job's results, by any spelling. It has no outputs, but nothing here should be reading them anyway.
  if yq -o=json ".jobs.${job}" "$workflow" | grep -Eq "needs\.build\b|needs\[|toJSON\(needs"; then
    problem "$workflow" "the ${job} job reads from the build job; only its artifact may cross."
  fi
done

# EVERY OTHER WORKFLOW. A new workflow could declare the Preview environment and check out a pull request, and
# nothing above would look at it. Only the sweep may hold the credential besides preview.yml, and it may not be
# started by a pull request or a comment. `pull_request_target` runs as the default branch, so the environment's
# branch restriction does not help against it; nothing in this repository may use it.
for file in "$workflows"/*.yml "$workflows"/*.yaml; do
  [ -e "$file" ] || continue

  if yq -o=json '.on' "$file" | grep -q '"pull_request_target"' \
    || [ "$(yq -o=json -I=0 '.on' "$file")" = '"pull_request_target"' ]; then
    problem "$file" "uses pull_request_target, which runs pull request events with the default branch's secrets."
  fi

  [ "$file" = "$workflow" ] && continue

  holds_credential=false
  if yq -o=json '.jobs[] | .environment' "$file" | grep -q 'Preview' \
    || grep -q 'AZURE_PREVIEW_CREDENTIALS' "$file"; then
    holds_credential=true
  fi

  [ "$holds_credential" = false ] && continue

  if [ "$file" != "$sweep" ]; then
    problem "$file" "uses the Preview environment or the Azure credential; only preview.yml and preview-sweep.yml may."
    continue
  fi

  triggers="$(yq '.on | keys | .[]' "$file" | sort | paste -sd, -)"
  if [ "$triggers" != "schedule,workflow_dispatch" ]; then
    problem "$file" "is triggered by '${triggers}'; the sweep may only run on its schedule or by hand."
  fi
  checkouts="$(yq '.jobs[].steps[] | select(.uses // "" | test("^actions/checkout@")) | [(.with.ref // ""), (.with.repository // "")] | join(",")' "$file")"
  while IFS= read -r checkout; do
    [ -z "$checkout" ] && continue
    [ "$checkout" = "," ] || problem "$file" "checks out '${checkout}'; the sweep may only check out the default branch."
  done <<< "$checkouts"
  if yq '.jobs[].steps[].run // ""' "$file" | runs_package_code; then
    problem "$file" "runs a package manager or Node."
  fi
done

if [ "$problems" -ne 0 ]; then
  echo "${problems} problem(s). The preview workflows no longer keep pull request code away from the credential."
  exit 1
fi

echo "The preview workflows keep pull request code away from the credential."
