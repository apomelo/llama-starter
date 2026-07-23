# Starts the schema-simplifying proxy in front of llama-server, with a supervisor
# loop: it keeps the Node proxy alive and monitors the backend (:9999) so the proxy
# transparently recovers when llama-server is stopped and restarted.
#
#   - The proxy keeps LISTENING on :9998 even while :9999 is down (requests get a
#     502 until the backend returns; each new request re-connects automatically).
#   - Up/down transitions of :9999 are printed so you can see when it's ready.
#   - If the Node process itself ever dies, it is restarted.
#
# Point Claude Code / Codex at http://localhost:9998 instead of :9999.
param(
    [int]$Listen = 9998,
    [int]$Target = 9999,
    [string]$TargetHost = "127.0.0.1",
    [int]$PollSeconds = 2
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$proxyScript = Join-Path $root "schema-proxy.js"

if (!(Get-Command node -ErrorAction SilentlyContinue)) {
    Write-Host "[ERROR] Node.js not found in PATH. Install Node.js to run the proxy." -ForegroundColor Red
    pause; exit 1
}
if (!(Test-Path $proxyScript)) {
    Write-Host "[ERROR] schema-proxy.js not found next to this script." -ForegroundColor Red
    pause; exit 1
}

# Quick, non-blocking TCP reachability test (short timeout).
function Test-Backend([string]$h, [int]$p) {
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $client.BeginConnect($h, $p, $null, $null)
        if ($iar.AsyncWaitHandle.WaitOne(3000) -and $client.Connected) {
            $client.EndConnect($iar); return $true
        }
        return $false
    }
    catch { return $false }
    finally { $client.Close() }
}

function Start-ProxyNode {
    Start-Process -FilePath "node" `
        -ArgumentList @($proxyScript, "$Listen", "$Target", $TargetHost) `
        -NoNewWindow -PassThru
}

Write-Host "Starting schema-proxy: http://localhost:$Listen  ->  http://${TargetHost}:$Target" -ForegroundColor Cyan
Write-Host "Set ANTHROPIC_BASE_URL=http://localhost:$Listen  (Codex base_url=http://localhost:$Listen/v1)" -ForegroundColor DarkGray
Write-Host "Supervisor active: proxy stays up while :$Target is down and recovers when it returns. Ctrl+C to stop." -ForegroundColor DarkGray

$nodeProc = Start-ProxyNode
$lastUp = $null
try {
    while ($true) {
        # Restart the Node proxy if it ever exits unexpectedly.
        if ($nodeProc.HasExited) {
            Write-Host "[proxy] node exited (code $($nodeProc.ExitCode)); restarting in 1s..." -ForegroundColor Yellow
            Start-Sleep -Seconds 1
            $nodeProc = Start-ProxyNode
        }
        # Report backend up/down transitions.
        $up = Test-Backend $TargetHost $Target
        if ($up -ne $lastUp) {
            if ($up) {
                Write-Host "[proxy] backend :$Target available  -> proxy ready on :$Listen" -ForegroundColor Green
            }
            else {
                Write-Host "[proxy] backend :$Target unavailable -> waiting (proxy still listening on :$Listen)" -ForegroundColor Yellow
            }
            $lastUp = $up
        }
        Start-Sleep -Seconds $PollSeconds
    }
}
finally {
    if ($nodeProc -and -not $nodeProc.HasExited) {
        Write-Host "[proxy] stopping node..." -ForegroundColor DarkGray
        try { $nodeProc.Kill() } catch { }
    }
}
