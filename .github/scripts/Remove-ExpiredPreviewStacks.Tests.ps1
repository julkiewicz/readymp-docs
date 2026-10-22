<#
    Exercises the retention decision. Run it: pwsh -File .github/scripts/Remove-ExpiredPreviewStacks.Tests.ps1

    No framework, on purpose, matching the trigger decision's test beside it. The thing under test
    answers yes or no, so a test needs nothing more than a way to say which answer it expected, and this stays
    runnable on a laptop and on a runner without installing anything.

    This decision is worth testing where most of the preview system is not. Everything else fails visibly: a
    deploy that goes wrong leaves an error and a broken stack. This one fails by quietly deleting an environment
    somebody was using, or by quietly keeping every stack forever, and neither announces itself.
#>
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot/Remove-ExpiredPreviewStacks.ps1" -ResourceGroup 'unused' -Repository 'unused'

$now = [DateTimeOffset]::Parse('2026-08-10T12:00:00Z')
$failures = 0

function Expect {
    param(
        [bool] $Expected,
        [string] $Description,
        [AllowNull()] $ClosedAt,
        [AllowNull()] $DeployedAt = $null,
        [int] $RetentionDays = 3
    )

    $actual = Test-StackExpired -ClosedAt $ClosedAt -DeployedAt $DeployedAt -RetentionDays $RetentionDays -Now $now

    if ($actual -eq $Expected) {
        Write-Host "  ok    $Description"
    } else {
        Write-Host "  FAIL  $Description : expected $Expected, got $actual"
        $script:failures++
    }
}

Write-Host 'An open pull request, with no known deploy time, is never collected:'
Expect -Expected $false -Description 'open, however long it has been open' -ClosedAt $null
Expect -Expected $false -Description 'open, with a retention period of zero' -ClosedAt $null -RetentionDays 0

Write-Host 'A stack is collected once it was deployed long enough ago, open pull request or not:'
Expect -Expected $false -Description 'open, deployed a moment ago' -ClosedAt $null -DeployedAt $now
Expect -Expected $false -Description 'open, deployed just under three days ago' -ClosedAt $null `
    -DeployedAt $now.AddDays(-3).AddMinutes(1)
Expect -Expected $true -Description 'open, deployed exactly three days ago' -ClosedAt $null -DeployedAt $now.AddDays(-3)
Expect -Expected $true -Description 'open, deployed four days ago' -ClosedAt $null -DeployedAt $now.AddDays(-4)
Expect -Expected $true -Description 'merged a moment ago, deployed four days ago' -ClosedAt $now `
    -DeployedAt $now.AddDays(-4)
Expect -Expected $true -Description 'open, deploy run not found, reported as the minimum date' -ClosedAt $null `
    -DeployedAt ([DateTimeOffset]::MinValue)
Expect -Expected $false -Description 'open, deployed four days ago, kept for seven' -ClosedAt $null `
    -DeployedAt $now.AddDays(-4) -RetentionDays 7
Expect -Expected $false -Description 'open, deployed in the future' -ClosedAt $null -DeployedAt $now.AddDays(1)

Write-Host 'Whichever comes first wins:'
Expect -Expected $true -Description 'deployed a day ago, closed four days ago (clock oddity)' `
    -ClosedAt $now.AddDays(-4) -DeployedAt $now.AddDays(-1)
Expect -Expected $false -Description 'deployed two days ago, closed one day ago' `
    -ClosedAt $now.AddDays(-1) -DeployedAt $now.AddDays(-2)

Write-Host 'A closed pull request is collected once the period has passed:'
Expect -Expected $false -Description 'closed a moment ago' -ClosedAt $now
Expect -Expected $false -Description 'closed one day ago' -ClosedAt $now.AddDays(-1)
Expect -Expected $false -Description 'closed just under three days ago' -ClosedAt $now.AddDays(-3).AddMinutes(1)
Expect -Expected $true -Description 'closed exactly three days ago' -ClosedAt $now.AddDays(-3)
Expect -Expected $true -Description 'closed four days ago' -ClosedAt $now.AddDays(-4)
Expect -Expected $true -Description 'closed a year ago' -ClosedAt $now.AddYears(-1)

Write-Host 'A pull request nothing knows about is collectable:'
Expect -Expected $true -Description 'no such pull request, reported as the minimum date' `
    -ClosedAt ([DateTimeOffset]::MinValue)

Write-Host 'The retention period is respected rather than assumed:'
Expect -Expected $false -Description 'closed four days ago, kept for seven' -ClosedAt $now.AddDays(-4) -RetentionDays 7
Expect -Expected $true -Description 'closed four days ago, kept for one' -ClosedAt $now.AddDays(-4) -RetentionDays 1
Expect -Expected $true -Description 'closed a moment ago, kept for nothing' -ClosedAt $now -RetentionDays 0

Write-Host 'A clock that has drifted backwards does not delete:'
Expect -Expected $false -Description 'closed in the future' -ClosedAt $now.AddDays(1)

Write-Host 'Moments are read as exact instants, whatever the local time zone:'
function ExpectInstant {
    param($Value, [string] $ExpectedUtc, [string] $Description)
    $actual = ConvertTo-Instant $Value
    $actualText = if ($null -eq $actual) { 'null' } else { $actual.UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ') }
    if ($actualText -eq $ExpectedUtc) {
        Write-Host "  ok    $Description"
    } else {
        Write-Host "  FAIL  $Description : expected $ExpectedUtc, got $actualText"
        $script:failures++
    }
}
ExpectInstant -Value '2026-10-20T10:00:00Z' -ExpectedUtc '2026-10-20T10:00:00Z' -Description 'an ISO string in UTC'
ExpectInstant -Value ('{"t":"2026-10-20T10:00:00Z"}' | ConvertFrom-Json).t -ExpectedUtc '2026-10-20T10:00:00Z' `
    -Description 'the same string after ConvertFrom-Json has made it a DateTime'
ExpectInstant -Value '2026-10-20T10:00:00' -ExpectedUtc '2026-10-20T10:00:00Z' -Description 'a string with no zone is UTC'
ExpectInstant -Value '2026-10-20T12:00:00+02:00' -ExpectedUtc '2026-10-20T10:00:00Z' -Description 'an explicit offset'
ExpectInstant -Value 'not a date' -ExpectedUtc 'null' -Description 'something that is not a date'

if ($failures -ne 0) {
    Write-Host "$failures failed."
    exit 1
}

Write-Host 'All passed.'
