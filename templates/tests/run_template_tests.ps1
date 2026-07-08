<#
    Chat template test runner
    --------------------------
    Renders each case in test_cases.json against a RUNNING llama-server via the
    POST /apply-template endpoint (uses the exact minja engine + loaded template),
    then verifies the returned prompt contains every 'expect' substring and none
    of the 'notExpect' substrings.

    Prerequisite: start llama-server with THIS template, e.g.

        .\start-llama.ps1        # and pick chat_template.jinja
        # or
        llama-server.exe -m <model.gguf> --jinja `
            --chat-template-file .\templates\chat_template.jinja `
            --host 127.0.0.1 --port 9999

    Usage:
        .\templates\tests\run_template_tests.ps1
        .\templates\tests\run_template_tests.ps1 -Endpoint http://127.0.0.1:9999
#>
param(
    [string]$Endpoint = "http://127.0.0.1:9999",
    [string]$CasesFile = (Join-Path $PSScriptRoot "test_cases.json")
)

$ErrorActionPreference = "Stop"

function Write-Result($ok, $name, $detail) {
    if ($ok) {
        Write-Host "  [PASS] " -ForegroundColor Green -NoNewline
        Write-Host $name
    }
    else {
        Write-Host "  [FAIL] " -ForegroundColor Red -NoNewline
        Write-Host $name
        if ($detail) { Write-Host "         $detail" -ForegroundColor DarkYellow }
    }
}

if (!(Test-Path $CasesFile)) { Write-Host "Cases file not found: $CasesFile" -ForegroundColor Red; exit 1 }

# Verify server reachable
try { $null = Invoke-RestMethod -Uri "$Endpoint/health" -TimeoutSec 5 }
catch {
    Write-Host "Cannot reach llama-server at $Endpoint" -ForegroundColor Red
    Write-Host "Start it first with --chat-template-file pointing at chat_template.jinja." -ForegroundColor Yellow
    exit 1
}

$data = Get-Content $CasesFile -Raw | ConvertFrom-Json
$total = 0; $passed = 0

Write-Host ""
Write-Host "Running $($data.cases.Count) template test case(s) against $Endpoint" -ForegroundColor Cyan
Write-Host ""

foreach ($case in $data.cases) {
    $total++

    # Build request body (only include fields that are present on the case)
    $body = @{ messages = $case.messages }
    if ($null -ne $case.tools) { $body.tools = $case.tools }
    if ($null -ne $case.add_generation_prompt) { $body.add_generation_prompt = $case.add_generation_prompt }
    if ($null -ne $case.enable_thinking) { $body.enable_thinking = $case.enable_thinking }
    if ($null -ne $case.chat_template_kwargs) { $body.chat_template_kwargs = $case.chat_template_kwargs }
    if ($null -ne $case.response_format) { $body.response_format = $case.response_format }

    $json = $body | ConvertTo-Json -Depth 30

    try {
        $resp = Invoke-RestMethod -Uri "$Endpoint/apply-template" -Method Post -Body $json -ContentType "application/json"
        $prompt = [string]$resp.prompt
    }
    catch {
        Write-Result $false $case.name "request error: $($_.Exception.Message)"
        continue
    }

    $ok = $true
    $detail = ""

    foreach ($sub in @($case.expect)) {
        if ($sub -and -not $prompt.Contains([string]$sub)) {
            $ok = $false
            $detail = "missing expected: " + ($sub -replace "`n", "\n")
            break
        }
    }
    if ($ok -and $case.notExpect) {
        foreach ($sub in @($case.notExpect)) {
            if ($sub -and $prompt.Contains([string]$sub)) {
                $ok = $false
                $detail = "found forbidden: " + ($sub -replace "`n", "\n")
                break
            }
        }
    }

    if ($ok) { $passed++ }
    Write-Result $ok $case.name $detail
}

Write-Host ""
$color = if ($passed -eq $total) { "Green" } else { "Red" }
Write-Host ("Result: {0}/{1} passed" -f $passed, $total) -ForegroundColor $color
Write-Host ""
if ($passed -ne $total) { exit 1 }
