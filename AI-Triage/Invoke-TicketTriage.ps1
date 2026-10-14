<#
.SYNOPSIS
    Uses a local AI model to suggest a category, priority and first step for helpdesk tickets,
    then measures how often the AI agrees with a human.

.DESCRIPTION
    For each ticket in the CSV, the script:
      1. Sends the subject and description to a local AI model running in Ollama.
      2. Gets back a category, a priority and a suggested first troubleshooting step.
      3. Compares the AI's answer with the human answer key (ExpectedCategory, ExpectedPriority).
    It then prints an accuracy report, lists every disagreement, and saves all results to CSV.

    Everything runs on your own computer. No ticket data leaves the machine.

.PARAMETER CsvPath
    CSV of tickets. Required columns: TicketId, Subject, Description.
    Optional answer-key columns: ExpectedCategory, ExpectedPriority.

.PARAMETER Model
    Ollama model to use. Default: llama3.2:3b (small enough for 8 GB of RAM).

.PARAMETER Endpoint
    Ollama address. Default: http://localhost:11434

.PARAMETER OutPath
    Where to save the results. Default: ./results/triage_<model>_<timestamp>.csv

.EXAMPLE
    ./Invoke-TicketTriage.ps1 -CsvPath ./sample_tickets.csv

.EXAMPLE
    ./Invoke-TicketTriage.ps1 -CsvPath ./sample_tickets.csv -Model llama3.1:8b
    Compare a larger model against the default.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$CsvPath,

    [string]$Model = 'llama3.2:3b',

    [string]$Endpoint = 'http://localhost:11434',

    [string]$OutPath
)

# ---------- Categories and instructions for the AI ----------

$Categories = @(
    'Password Reset',
    'Account Lockout',
    'Access Request',
    'New Hire',
    'Hardware Issue',
    'Software Issue',
    'Software Request',
    'Network Issue'
)
$Priorities = @('Low', 'Medium', 'High')

$SystemPrompt = @"
You are a helpdesk triage assistant for a small company's IT team.
Read the ticket and classify it.

Categories (pick exactly one):
- Password Reset: user forgot or needs to change a password, or it expired
- Account Lockout: account is locked, often after failed sign-in attempts
- Access Request: user needs permission to a folder, mailbox, app or system
- New Hire: setting up accounts and equipment for a new employee or intern
- Hardware Issue: a physical device is broken or misbehaving (laptop, monitor, printer, keyboard)
- Software Issue: an installed application crashes or doesn't work
- Software Request: user wants new software or a license installed
- Network Issue: internet, Wi-Fi, VPN or connectivity problems

Priority:
- High: several people affected, OR one person completely unable to work, OR an urgent deadline today/tomorrow
- Medium: one person impaired but has a workaround or the need is this week
- Low: a request or minor annoyance with no deadline

first_step: one short sentence with the first troubleshooting action a helpdesk technician should take.
If the request could be a security risk (for example someone asking for another person's password), say so in first_step.
"@

# JSON schema so the model must answer in a fixed shape with allowed values only
$ResponseSchema = @{
    type       = 'object'
    properties = @{
        category   = @{ type = 'string'; enum = $Categories }
        priority   = @{ type = 'string'; enum = $Priorities }
        first_step = @{ type = 'string' }
    }
    required   = @('category', 'priority', 'first_step')
}

# ---------- Check Ollama is running and the model is installed ----------

try {
    $installed = (Invoke-RestMethod -Uri "$Endpoint/api/tags" -TimeoutSec 5).models.name
}
catch {
    throw "Can't reach Ollama at $Endpoint. Open the Ollama app (or run 'ollama serve') and try again."
}
if ($installed -notcontains $Model) {
    throw "Model '$Model' isn't installed. Run: ollama pull $Model"
}

# ---------- Load tickets ----------

$tickets = @(Import-Csv -Path $CsvPath)
$columns = if ($tickets.Count -gt 0) { $tickets[0].PSObject.Properties.Name } else { @() }
$missing = @('TicketId', 'Subject', 'Description') | Where-Object { $columns -notcontains $_ }
if ($missing) { throw "CSV is missing required column(s): $($missing -join ', ')" }
$hasAnswerKey = ($columns -contains 'ExpectedCategory') -and ($columns -contains 'ExpectedPriority')

if (-not $OutPath) {
    $safeModel = $Model -replace '[^a-zA-Z0-9.-]', '_'
    $OutPath = "./results/triage_${safeModel}_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
}

Write-Host "`nAI ticket triage: $($tickets.Count) ticket(s), model $Model (running locally)`n" -ForegroundColor Cyan

# ---------- Triage each ticket ----------

$results = New-Object System.Collections.Generic.List[object]
$i = 0
foreach ($t in $tickets) {
    $i++
    Write-Progress -Activity 'Triaging tickets' -Status "$($t.TicketId) ($i of $($tickets.Count))" -PercentComplete (100 * $i / $tickets.Count)

    $body = @{
        model    = $Model
        stream   = $false
        format   = $ResponseSchema
        options  = @{ temperature = 0 }   # same input -> same answer, so results are repeatable
        messages = @(
            @{ role = 'system'; content = $SystemPrompt },
            @{ role = 'user'; content = "Subject: $($t.Subject)`nDescription: $($t.Description)" }
        )
    } | ConvertTo-Json -Depth 10

    $row = [ordered]@{
        TicketId         = $t.TicketId
        Subject          = $t.Subject
        AiCategory       = ''
        AiPriority       = ''
        ExpectedCategory = "$($t.ExpectedCategory)"
        ExpectedPriority = "$($t.ExpectedPriority)"
        CategoryMatch    = ''
        PriorityMatch    = ''
        FirstStep        = ''
        Seconds          = 0
        Error            = ''
    }

    $timer = [Diagnostics.Stopwatch]::StartNew()
    try {
        $response = Invoke-RestMethod -Method Post -Uri "$Endpoint/api/chat" -ContentType 'application/json; charset=utf-8' `
            -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 300
        $answer = $response.message.content | ConvertFrom-Json

        $row.AiCategory = $answer.category
        $row.AiPriority = $answer.priority
        $row.FirstStep  = $answer.first_step
        if ($hasAnswerKey) {
            $row.CategoryMatch = [bool]($answer.category -ieq $t.ExpectedCategory)
            $row.PriorityMatch = [bool]($answer.priority -ieq $t.ExpectedPriority)
        }
    }
    catch {
        $row.Error = $_.Exception.Message
    }
    $timer.Stop()
    $row.Seconds = [Math]::Round($timer.Elapsed.TotalSeconds, 1)

    $results.Add([pscustomobject]$row)
}
Write-Progress -Activity 'Triaging tickets' -Completed

# ---------- Report ----------

$results | Format-Table TicketId, AiCategory, AiPriority, ExpectedCategory, ExpectedPriority, CategoryMatch, PriorityMatch -AutoSize |
    Out-String -Width 200 | Write-Host

$ok = @($results | Where-Object { -not $_.Error })
$failed = @($results | Where-Object { $_.Error })

if ($hasAnswerKey -and $ok.Count -gt 0) {
    $catRight  = @($ok | Where-Object { $_.CategoryMatch -eq $true }).Count
    $prioRight = @($ok | Where-Object { $_.PriorityMatch -eq $true }).Count
    $bothRight = @($ok | Where-Object { $_.CategoryMatch -eq $true -and $_.PriorityMatch -eq $true }).Count
    $avgSec    = [Math]::Round(($ok | Measure-Object Seconds -Average).Average, 1)

    Write-Host 'Accuracy vs. human answer key:' -ForegroundColor Cyan
    Write-Host ("  Category   {0} of {1}  ({2:P0})" -f $catRight, $ok.Count, ($catRight / $ok.Count))
    Write-Host ("  Priority   {0} of {1}  ({2:P0})" -f $prioRight, $ok.Count, ($prioRight / $ok.Count))
    Write-Host ("  Both       {0} of {1}  ({2:P0})" -f $bothRight, $ok.Count, ($bothRight / $ok.Count))
    Write-Host "  Average time per ticket: $avgSec s"

    $misses = @($ok | Where-Object { $_.CategoryMatch -ne $true -or $_.PriorityMatch -ne $true })
    if ($misses.Count -gt 0) {
        Write-Host "`nWhere the AI disagreed (worth a look for your write-up):" -ForegroundColor Yellow
        foreach ($m in $misses) {
            $parts = @()
            if ($m.CategoryMatch -ne $true) { $parts += "category $($m.AiCategory) (expected $($m.ExpectedCategory))" }
            if ($m.PriorityMatch -ne $true) { $parts += "priority $($m.AiPriority) (expected $($m.ExpectedPriority))" }
            Write-Host "  $($m.TicketId) '$($m.Subject)': $($parts -join '; ')"
        }
    }
}

if ($failed.Count -gt 0) {
    Write-Host "`n$($failed.Count) ticket(s) failed:" -ForegroundColor Red
    $failed | ForEach-Object { Write-Host "  $($_.TicketId): $($_.Error)" }
}

$outDir = Split-Path -Path $OutPath -Parent
if ($outDir -and -not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir | Out-Null }
$results | Export-Csv -Path $OutPath -NoTypeInformation -Encoding utf8
Write-Host "`nFull results (including the AI's suggested first steps) saved to $OutPath`n"
