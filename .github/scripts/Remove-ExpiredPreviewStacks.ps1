<#
.SYNOPSIS
    Deletes preview stacks that were deployed long enough ago, or whose pull request has been closed long enough.

.DESCRIPTION
    **This enumerates from Azure, never from a list of what should exist.** Written the other way round it could
    only ever find stacks it already knew about, and the stacks worth catching are exactly the ones nothing knows
    about: a run that died before tagging, a repository that was deleted, a stack somebody deployed by hand.

    A preview stack is identified by its `preview-pull-request` tag. Shared infrastructure carries no tags at all,
    so it cannot appear in the results however this is called. That is a second, independent reason it is safe,
    alongside the delete locks on those resources and the deployment credential being scoped to one resource
    group. None of the three is relied on alone.

    Container apps only. Images stay in the registry: an app that has scaled to zero pulls its image again on the
    next cold start, so an image has to outlive its stack rather than go with it.

    Deletion is idempotent, so this overlapping with a run cleaning up after itself is harmless.

    **A stack expires on whichever comes first:** RetentionDays after it was deployed, or RetentionDays after its
    pull request closed. The first is the rule since 2026-10-22, so a preview on a pull request that stays open
    still goes; the second is the older rule, kept, and normally already covered by the first.

.PARAMETER ResourceGroup
    The one resource group previews use.

.PARAMETER Repository
    The `owner/name` whose pull requests are consulted. Stacks tagged with a pull request number are looked up
    here.

.PARAMETER RetentionDays
    How long a stack is kept after it was deployed, and after its pull request closes.

.PARAMETER DeleteForReal
    Absent, this reports what it would delete and deletes nothing. That is the default deliberately: a deletion
    loop nobody has watched make correct decisions is the riskiest thing in this system, and report-only mode
    costs nothing but patience.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $ResourceGroup,
    [Parameter(Mandatory)] [string] $Repository,
    [int] $RetentionDays = 3,
    [switch] $DeleteForReal
)

$ErrorActionPreference = 'Stop'

function Get-PreviewResource {
    param([string] $ResourceGroup, [string] $Repository)

    # Selecting on the tag rather than on the name prefix is what makes shared infrastructure unreachable from
    # here: it has no tags, so it cannot match, whatever it is called.
    #
    # **And only this repository's stacks.** Several repositories deploy into one resource group: a fork opens its
    # own working pull requests, and pull request numbers restart per repository. This sweep resolves each stack's
    # number against its OWN repository, so without this filter a fork's sweep would look up the upstream's number
    # 7, find its own long-closed 7, and delete a stack somebody is using. The filter is what makes it safe for
    # every repository to sweep, rather than requiring exactly one to.
    #
    # A stack tagged with no repository predates the tag and belongs to whoever deployed it, so it is left alone;
    # `/clearpreview` removes those by name.
    $json = az resource list --resource-group $ResourceGroup `
        --query "[?tags.\`"preview-pull-request\`" != null && tags.\`"preview-repository\`" == '$Repository']" `
        --output json

    if ($LASTEXITCODE -ne 0) { throw "Could not list resources in '$ResourceGroup'." }

    $json | ConvertFrom-Json
}

<#
    Returns the moment a pull request stopped being worked on, or $null while it is still open.

    A pull request that cannot be found at all is treated as closed long ago rather than as an error. That happens
    when a repository is renamed or a pull request is deleted, and the stack it left behind is exactly what this
    exists to collect. Crashing there would mean one unfindable pull request stops every other stack being
    cleaned up.
#>
function Get-PullRequestClosedAt {
    param([string] $Repository, [string] $Number)

    $json = gh api "repos/$Repository/pulls/$Number" 2>$null

    if ($LASTEXITCODE -ne 0) {
        Write-Host "  pull request $Number could not be found; treating its stacks as collectable."
        return [DateTimeOffset]::MinValue
    }

    $pull = $json | ConvertFrom-Json

    if ($pull.state -eq 'open') { return $null }

    # merged_at and closed_at are both set on a merged pull request, and closed_at alone on a rejected one.
    [DateTimeOffset]::Parse($pull.closed_at)
}

<#
    Returns the moment a stack was deployed, from its `preview-deployed-at` tag.

    Stacks deployed before that tag existed have none, and take the moment from their `preview-run` tag instead, by
    asking GitHub when that run was created. A run GitHub reports as not existing reads as deployed long ago, since
    runs are kept far longer than any retention period here, so a missing run means an old stack. Any other failure
    returns $null, which keeps the stack: this decision fails by deleting something it should have kept, so not
    knowing is never a reason to delete.
#>
function Get-StackDeployedAt {
    param([string] $Repository, $Tags)

    $tagged = $Tags.'preview-deployed-at'
    if ($tagged) {
        $parsed = [DateTimeOffset]::MinValue
        if ([DateTimeOffset]::TryParse($tagged, [ref] $parsed)) { return $parsed }
        Write-Warning "  preview-deployed-at '$tagged' is not a date; falling back to the run."
    }

    $run = $Tags.'preview-run'
    if (-not $run) { return $null }

    $output = gh api "repos/$Repository/actions/runs/$run" --jq '.created_at' 2>&1

    if ($LASTEXITCODE -eq 0) { return [DateTimeOffset]::Parse("$output".Trim()) }

    if ("$output" -match 'HTTP 404') {
        Write-Host "  run $run could not be found; treating its stack as deployed long ago."
        return [DateTimeOffset]::MinValue
    }

    Write-Warning "  could not ask GitHub when run $run started, so its stack is kept: $output"
    $null
}

<#
    The retention decision on its own, with no knowledge of Azure, GitHub or time. Separated so it can be
    exercised directly by Remove-ExpiredPreviewStacks.Tests.ps1, which matters more here than anywhere else in
    this system: everything else fails visibly, and this fails by deleting something it should have kept.

    Expired when either moment is at least RetentionDays ago. $null means that moment is not known, or has not
    happened: $ClosedAt is $null while the pull request is open, $DeployedAt when it could not be established.
    DateTimeOffset.MinValue means long ago, and therefore collectable.
#>
function Test-StackExpired {
    param(
        [AllowNull()] [Nullable[DateTimeOffset]] $ClosedAt,
        [AllowNull()] [Nullable[DateTimeOffset]] $DeployedAt,
        [int] $RetentionDays,
        [DateTimeOffset] $Now
    )

    foreach ($moment in @($DeployedAt, $ClosedAt)) {
        if ($null -ne $moment -and ($Now - $moment).TotalDays -ge $RetentionDays) { return $true }
    }

    $false
}

# Sourced by the test, run directly by the workflow.
if ($MyInvocation.InvocationName -eq '.') { return }

Write-Host "Reconciling preview stacks in '$ResourceGroup' against pull requests in '$Repository'."
Write-Host "Retention: $RetentionDays day(s) after a stack was deployed, or after its pull request closes."
if (-not $DeleteForReal) { Write-Host 'REPORT ONLY. Nothing will be deleted.' }

$resources = @(Get-PreviewResource -ResourceGroup $ResourceGroup -Repository $Repository)

if ($resources.Count -eq 0) {
    Write-Host 'No preview stacks exist.'
    return
}

# Grouped by stack rather than by pull request, so the report reads the way somebody thinks about it, and so one
# pull request's stacks can be reported separately even though they share a fate.
$stacks = $resources | Group-Object { "$($_.tags.'preview-pull-request')/$($_.tags.'preview-sha')" }

Write-Host "$($stacks.Count) stack(s), $($resources.Count) resource(s)."

# One lookup per pull request, not per stack: a busy pull request can have many stacks and the answer is the same
# for all of them.
$closedAt = @{}
$deleted = 0

foreach ($stack in $stacks) {
    $number = $stack.Group[0].tags.'preview-pull-request'
    $sha = $stack.Group[0].tags.'preview-sha'
    $short = if ($sha) { $sha.Substring(0, [Math]::Min(7, $sha.Length)) } else { 'unknown' }
    # The stack's real name prefix, from its tag. Only the server ever had stacks without one, all named `pr-`.
    $label = if ($stack.Group[0].tags.'preview-stack') { $stack.Group[0].tags.'preview-stack' } else { "pr-$number-$short" }

    if (-not $closedAt.ContainsKey($number)) {
        $closedAt[$number] = Get-PullRequestClosedAt -Repository $Repository -Number $number
    }

    $closed = $closedAt[$number]
    $deployed = Get-StackDeployedAt -Repository $Repository -Tags $stack.Group[0].tags
    $now = [DateTimeOffset]::UtcNow

    $why = @(
        if ($null -eq $deployed) { 'deployed at an unknown time' }
        elseif ($deployed -eq [DateTimeOffset]::MinValue) { 'deployed long ago' }
        else { 'deployed {0:N1} day(s) ago' -f ($now - $deployed).TotalDays }

        if ($null -eq $closed) { 'pull request open' }
        elseif ($closed -eq [DateTimeOffset]::MinValue) { 'pull request not found' }
        else { 'closed {0:N1} day(s) ago' -f ($now - $closed).TotalDays }
    ) -join ', '

    if (-not (Test-StackExpired -ClosedAt $closed -DeployedAt $deployed -RetentionDays $RetentionDays -Now $now)) {
        Write-Host "  keep    $label : $why"
        continue
    }

    if (-not $DeleteForReal) {
        Write-Host ("  WOULD DELETE {0} : {1}, {2} resource(s)" -f $label, $why, $stack.Group.Count)
        continue
    }

    Write-Host ("  delete  {0} : {1}, {2} resource(s)" -f $label, $why, $stack.Group.Count)

    foreach ($resource in $stack.Group) {
        az resource delete --ids $resource.id --only-show-errors --output none

        if ($LASTEXITCODE -ne 0) {
            # One resource refusing to go is not a reason to abandon every other stack. The next run tries again,
            # and a stack half deleted is still less than a stack fully alive.
            Write-Warning "Could not delete '$($resource.name)'. Leaving the rest of this stack for the next run."
            continue
        }

        $deleted++
    }
}

if ($DeleteForReal) {
    Write-Host "Deleted $deleted resource(s)."
} else {
    Write-Host 'Reported only. Re-run with -DeleteForReal to act on this.'
}
