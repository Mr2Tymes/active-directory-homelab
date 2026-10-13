<#
.SYNOPSIS
    Creates Active Directory user accounts in bulk from a CSV of new hires.

.DESCRIPTION
    For each row in the CSV, the script:
      1. Checks that the required fields are present and the department is valid.
      2. Builds a standard username (first.last), adding a number if it is already taken.
      3. Places the user in their department's OU and adds them to the department group.
      4. Sets a random temporary password the user must change at first logon.
    Every row is logged to a CSV file. Passwords are never written to the log.

    If the ActiveDirectory module isn't available (for example on a Mac or a PC
    that isn't a domain controller), the script runs in simulation mode. It still
    validates the data and shows exactly what it would create, without touching AD.

.PARAMETER CsvPath
    Path to the CSV file. Required columns: FirstName, LastName, Department, Title.

.PARAMETER DomainDN
    Distinguished name of the domain. Default: DC=corp,DC=lab,DC=local

.PARAMETER UpnSuffix
    Suffix for user logon names (user@suffix). Default: corp.lab.local

.PARAMETER Departments
    Departments allowed in the CSV. Each needs an OU under _CORP\Users and a GG-<Department> group.

.PARAMETER LogPath
    Where to save the results log. Default: ./logs/New-BulkUsers_<timestamp>.csv

.PARAMETER Simulate
    Show what would be created without changing Active Directory.

.EXAMPLE
    ./New-BulkUsers.ps1 -CsvPath ./new_hires_sample.csv -Simulate
    Test run on any computer, including a Mac.

.EXAMPLE
    .\New-BulkUsers.ps1 -CsvPath .\new_hires.csv -WhatIf
    On the domain controller: preview the changes first.

.EXAMPLE
    .\New-BulkUsers.ps1 -CsvPath .\new_hires.csv
    On the domain controller: create the accounts.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$CsvPath,

    [string]$DomainDN = 'DC=corp,DC=lab,DC=local',

    [string]$UpnSuffix = 'corp.lab.local',

    [string[]]$Departments = @('IT', 'HR', 'Finance', 'Sales'),

    [string]$LogPath = "./logs/New-BulkUsers_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv",

    [switch]$Simulate
)

# ---------- Helper functions ----------

function ConvertTo-UsernamePart {
    # "Zoë" -> "zoe", "O'Connor" -> "oconnor", "Montgomery-Williamson" -> "montgomerywilliamson"
    param([string]$Text)
    $decomposed = $Text.Normalize([Text.NormalizationForm]::FormD)
    $noAccents  = $decomposed -replace '\p{Mn}', ''
    return ($noAccents -replace '[^a-zA-Z]', '').ToLower()
}

function New-TempPassword {
    # Random password with at least one upper, lower, digit and symbol.
    # Uses a cryptographic random generator (works in Windows PowerShell 5.1 and PowerShell 7).
    param([int]$Length = 14)
    $sets = @(
        'ABCDEFGHJKLMNPQRSTUVWXYZ',   # no I or O, so they aren't mistaken for 1 and 0
        'abcdefghijkmnopqrstuvwxyz',  # no l
        '23456789',
        '!@#$%^&*?'
    )
    $all = -join $sets
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $getIndex = {
        param([int]$Max)
        $bytes = New-Object byte[] 4
        $rng.GetBytes($bytes)
        return [int]([BitConverter]::ToUInt32($bytes, 0) % [uint32]$Max)
    }

    $chars = New-Object System.Collections.Generic.List[char]
    foreach ($set in $sets) { $chars.Add($set[(& $getIndex $set.Length)]) }
    while ($chars.Count -lt $Length) { $chars.Add($all[(& $getIndex $all.Length)]) }

    # Shuffle so the guaranteed characters aren't always at the start
    for ($i = $chars.Count - 1; $i -gt 0; $i--) {
        $j = & $getIndex ($i + 1)
        $tmp = $chars[$i]; $chars[$i] = $chars[$j]; $chars[$j] = $tmp
    }
    $rng.Dispose()
    return -join $chars
}

function Get-UniqueSamAccountName {
    # sAMAccountName is limited to 20 characters. Adds 2, 3, ... if the name is taken.
    param(
        [string]$First,
        [string]$Last,
        [System.Collections.Generic.HashSet[string]]$UsedInThisRun,
        [bool]$CheckAD
    )
    $base = "$First.$Last"
    $n = 1
    while ($true) {
        $suffix = if ($n -eq 1) { '' } else { "$n" }
        $maxBase = 20 - $suffix.Length
        $candidate = $base.Substring(0, [Math]::Min($base.Length, $maxBase)).TrimEnd('.') + $suffix

        $takenInAD = $false
        if ($CheckAD) {
            $takenInAD = [bool](Get-ADUser -Filter "SamAccountName -eq '$candidate'" -ErrorAction SilentlyContinue)
        }
        if (-not $takenInAD -and -not $UsedInThisRun.Contains($candidate)) {
            [void]$UsedInThisRun.Add($candidate)
            return $candidate
        }
        $n++
    }
}

# ---------- Setup ----------

if (-not $Simulate) {
    if (Get-Module -ListAvailable -Name ActiveDirectory) {
        Import-Module ActiveDirectory -ErrorAction Stop
    }
    else {
        Write-Warning 'ActiveDirectory module not found. Running in simulation mode (no changes will be made).'
        $Simulate = $true
    }
}

$rows = @(Import-Csv -Path $CsvPath)
$requiredColumns = @('FirstName', 'LastName', 'Department', 'Title')
$csvColumns = if ($rows.Count -gt 0) { $rows[0].PSObject.Properties.Name } else { @() }
$missingColumns = $requiredColumns | Where-Object { $csvColumns -notcontains $_ }
if ($missingColumns) {
    throw "CSV is missing required column(s): $($missingColumns -join ', ')"
}

$usedNames  = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
$results    = New-Object System.Collections.Generic.List[object]
$newLogins  = New-Object System.Collections.Generic.List[object]
$mode       = if ($Simulate) { 'SIMULATION' } else { 'LIVE' }

Write-Host "`nNew-BulkUsers ($mode mode): $($rows.Count) row(s) from $CsvPath`n" -ForegroundColor Cyan

# ---------- Process each new hire ----------

$rowNumber = 1
foreach ($row in $rows) {
    $rowNumber++  # row 1 is the header, so data starts on row 2
    $first = "$($row.FirstName)".Trim()
    $last  = "$($row.LastName)".Trim()
    $dept  = "$($row.Department)".Trim()
    $title = "$($row.Title)".Trim()

    $result = [ordered]@{
        Row            = $rowNumber
        FirstName      = $first
        LastName       = $last
        Department     = $dept
        SamAccountName = ''
        UPN            = ''
        OU             = ''
        Group          = ''
        Status         = ''
        Reason         = ''
    }

    # Validate the row
    $empty = @('FirstName', 'LastName', 'Department', 'Title') | Where-Object { -not "$($row.$_)".Trim() }
    $matchedDept = $Departments | Where-Object { $_ -ieq $dept } | Select-Object -First 1
    $firstPart = ConvertTo-UsernamePart $first
    $lastPart  = ConvertTo-UsernamePart $last

    if ($empty) {
        $result.Status = 'Skipped'
        $result.Reason = "Missing: $($empty -join ', ')"
    }
    elseif (-not $matchedDept) {
        $result.Status = 'Skipped'
        $result.Reason = "Unknown department '$dept' (allowed: $($Departments -join ', '))"
    }
    elseif (-not $firstPart -or -not $lastPart) {
        $result.Status = 'Skipped'
        $result.Reason = 'Name has no letters usable in a username'
    }
    else {
        $dept = $matchedDept
        $sam  = Get-UniqueSamAccountName -First $firstPart -Last $lastPart -UsedInThisRun $usedNames -CheckAD (-not $Simulate)
        $ou   = "OU=$dept,OU=Users,OU=_CORP,$DomainDN"
        $group = "GG-$dept"
        # The object name must be unique inside an OU, so add the username when it was bumped (john.smith2)
        $cn = if ($sam -match '\d$') { "$first $last ($sam)" } else { "$first $last" }

        $result.Department     = $dept
        $result.SamAccountName = $sam
        $result.UPN            = "$sam@$UpnSuffix"
        $result.OU             = $ou
        $result.Group          = $group

        $password = New-TempPassword

        if ($Simulate) {
            $result.Status = 'Simulated'
            $newLogins.Add([pscustomobject]@{ SamAccountName = $sam; TempPassword = $password })
        }
        elseif ($PSCmdlet.ShouldProcess("$sam ($first $last)", "Create user in $ou and add to $group")) {
            try {
                $userParams = @{
                    Name                  = $cn
                    GivenName             = $first
                    Surname               = $last
                    DisplayName           = "$first $last"
                    SamAccountName        = $sam
                    UserPrincipalName     = "$sam@$UpnSuffix"
                    Title                 = $title
                    Department            = $dept
                    Path                  = $ou
                    AccountPassword       = (ConvertTo-SecureString $password -AsPlainText -Force)
                    ChangePasswordAtLogon = $true
                    Enabled               = $true
                    ErrorAction           = 'Stop'
                }
                New-ADUser @userParams
                Add-ADGroupMember -Identity $group -Members $sam -ErrorAction Stop
                $result.Status = 'Created'
                $newLogins.Add([pscustomobject]@{ SamAccountName = $sam; TempPassword = $password })
            }
            catch {
                $result.Status = 'Failed'
                $result.Reason = $_.Exception.Message
            }
        }
        else {
            $result.Status = 'WhatIf'
        }
    }

    $results.Add([pscustomobject]$result)
}

# ---------- Report ----------

$results | Format-Table Row, FirstName, LastName, Department, SamAccountName, Group, Status, Reason -AutoSize | Out-String -Width 200 | Write-Host

$logDir = Split-Path -Path $LogPath -Parent
if ($logDir -and -not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }
$results | Export-Csv -Path $LogPath -NoTypeInformation
Write-Host "Log saved to $LogPath (no passwords included)."

Write-Host "`nSummary:" -ForegroundColor Cyan
$results | Group-Object Status | ForEach-Object { Write-Host ("  {0,-10} {1}" -f $_.Name, $_.Count) }

if ($newLogins.Count -gt 0) {
    $label = if ($Simulate) { 'Sample temporary passwords (simulation, not real accounts)' } else { 'Temporary passwords: give these to each user securely, then clear the screen' }
    Write-Host "`n$label`:" -ForegroundColor Yellow
    $newLogins | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
}
