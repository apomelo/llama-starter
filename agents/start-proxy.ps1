# Starts the schema-simplifying proxy in front of llama-server.
# Point Claude Code / Codex at http://localhost:9998 instead of :9999.
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$listen = 9998
$target = 9999
if (!(Get-Command node -ErrorAction SilentlyContinue)) {
    Write-Host "[ERROR] Node.js not found in PATH. Install Node.js to run the proxy." -ForegroundColor Red
    pause; exit 1
}
Write-Host "Starting schema-proxy: http://localhost:$listen  ->  http://127.0.0.1:$target" -ForegroundColor Cyan
Write-Host "Set ANTHROPIC_BASE_URL=http://localhost:$listen  (Codex base_url=http://localhost:$listen/v1)" -ForegroundColor DarkGray
node (Join-Path $root "schema-proxy.js") $listen $target
