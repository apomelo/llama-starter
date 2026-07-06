<#
    Universal GGUF llama-server Launcher
    ------------------------------------
    - Auto-detects every quantization format (Q2..Q8, IQ1..IQ4, K_S/K_M/K_L, NL, XS, F16 ...)
    - Sorts models by recommended quality order (best first) instead of a hard-coded list
    - Auto-generates a full alias (family + quant + mode)
    - Prints a full configuration summary before launch
    - Detects one or many mmproj files (optional, vision models)
    - Detects llama-server.exe version
    - Probes --help to decide whether flags like --flash-attn / --slots are supported
    - Centralized configuration: add new modes/quants without touching the logic
    - Colorized menus
    - Works for any GGUF model family (Qwen / DeepSeek / Llama / GLM / Gemma ...)

    PowerShell 5.1+ compatible.
#>

$ErrorActionPreference = "Stop"

# ============================================================================
#  1. Centralized configuration  (edit here to extend behaviour)
# ============================================================================
$Config = [ordered]@{
    BindHost    = "127.0.0.1"
    Port        = 9999
    NGpuLayers  = 999          # -ngl
    CtxSize     = 131072       # -c   (default context = 128k)
    Predict     = 8192         # -n
    UseJinja    = $true        # --jinja
    KvCacheType = "q8_0"       # --cache-type-k/-v  (quantized KV cache; "" = disabled/f16)
    ShortAlias  = $true        # trim fine-tune descriptor tags from the alias family name
}

# Sampler presets. Add / edit modes freely - the launcher discovers them.
# Params keys are the exact llama-server CLI flags.
$Modes = @(
    [ordered]@{
        Key = "Default"; Label = "Default"; AliasTag = "";
        Params = [ordered]@{}
    }
    [ordered]@{
        Key = "Thinking-General"; Label = "Thinking / General"; AliasTag = "Thinking-General";
        Params = [ordered]@{ "--temp" = "1.0"; "--top-p" = "0.95"; "--top-k" = "20"; "--min-p" = "0"; "--presence-penalty" = "1.5" }
    }
    [ordered]@{
        Key = "Thinking-Coding"; Label = "Thinking / Coding"; AliasTag = "Thinking-Coding";
        Params = [ordered]@{ "--temp" = "0.6"; "--top-p" = "0.95"; "--top-k" = "20"; "--min-p" = "0"; "--presence-penalty" = "0" }
    }
    [ordered]@{
        Key = "NonThinking-General"; Label = "Non-Thinking / General"; AliasTag = "NonThinking-General";
        Params = [ordered]@{ "--temp" = "0.7"; "--top-p" = "0.8"; "--top-k" = "20"; "--min-p" = "0"; "--presence-penalty" = "1.5" }
    }
    [ordered]@{
        Key = "NonThinking-Reasoning"; Label = "Non-Thinking / Reasoning"; AliasTag = "NonThinking-Reasoning";
        Params = [ordered]@{ "--temp" = "1.0"; "--top-p" = "1.0"; "--top-k" = "40"; "--min-p" = "0"; "--presence-penalty" = "2.0" }
    }
)

# Approximate bits-per-weight per quant type (used only for recommended ordering).
$QuantBpw = @{
    "F32" = 32; "F16" = 16; "BF16" = 16
    "Q8_0" = 8.50; "Q6_K" = 6.56
    "Q5_1" = 6.00; "Q5_K_M" = 5.68; "Q5_K_S" = 5.52; "Q5_0" = 5.50
    "Q4_1" = 5.00; "Q4_K_M" = 4.85; "Q4_K_S" = 4.58; "Q4_0" = 4.55; "Q4_K_P" = 4.50
    "IQ4_NL" = 4.50; "IQ4_XS" = 4.25
    "Q3_K_L" = 4.27; "Q3_K_M" = 3.91; "Q3_K_S" = 3.50
    "IQ3_M" = 3.70; "IQ3_S" = 3.44; "IQ3_XS" = 3.30; "IQ3_XXS" = 3.06
    "Q2_K" = 3.35; "Q2_K_S" = 2.96
    "IQ2_M" = 2.70; "IQ2_S" = 2.50; "IQ2_XS" = 2.31; "IQ2_XXS" = 2.06
    "IQ1_M" = 1.75; "IQ1_S" = 1.56
}

# ============================================================================
#  2. Helpers
# ============================================================================
function Write-Title($text) {
    Write-Host ""
    Write-Host ("=" * 60) -ForegroundColor DarkCyan
    Write-Host "  $text" -ForegroundColor Cyan
    Write-Host ("=" * 60) -ForegroundColor DarkCyan
}

function Write-KV($key, $value) {
    Write-Host ("  {0,-14}" -f $key) -ForegroundColor Gray -NoNewline
    Write-Host $value -ForegroundColor White
}

function Fail($msg) {
    Write-Host ""
    Write-Host "  [ERROR] $msg" -ForegroundColor Red
    Write-Host ""
    pause
    exit 1
}

# Extract the quant token (e.g. IQ3_M, Q4_K_M) from a file base name.
function Get-QuantToken($baseName) {
    $pattern = '(?i)(?<![A-Za-z0-9])(IQ[1-4](?:_(?:XXS|XS|S|M|NL|L))?|Q[2-8](?:_(?:0|1|K(?:_(?:XS|XL|S|M|L|P))?))?|BF16|F16|F32)(?![A-Za-z0-9])'
    $m = [regex]::Matches($baseName, $pattern)
    if ($m.Count -gt 0) { return $m[$m.Count - 1].Value.ToUpper() }
    return "UNKNOWN"
}

# Quality score for ordering (higher = better quality).
function Get-QuantScore($quant) {
    if ($QuantBpw.ContainsKey($quant)) { return [double]$QuantBpw[$quant] }
    if ($quant -match '(\d+)') { return [double]$matches[1] }  # fallback: use bit count
    return 0
}

# Derive the model family name by stripping the quant token (and trailing separators).
function Get-FamilyName($baseName, $quant) {
    $name = $baseName
    if ($quant -ne "UNKNOWN") {
        $name = [regex]::Replace($name, '(?i)[-_\. ]*' + [regex]::Escape($quant) + '[-_\. ]*', '-')
    }
    return $name.Trim('-', '_', '.', ' ')
}

# Shorten the family name by keeping everything up to the last parameter-size
# token (35B, A3B, 8x7B, 1.5B ...) and dropping fine-tune descriptor tags, e.g.
# "Qwen3.6-35B-A3B-Uncensored-HauhauCS-Aggressive" -> "Qwen3.6-35B-A3B".
function Get-ShortFamily($family) {
    $segs = $family -split '-'
    $lastSize = -1
    for ($i = 0; $i -lt $segs.Count; $i++) {
        if ($segs[$i] -match '^(?i)(a?\d+(\.\d+)?b|\d+x\d+b)$') { $lastSize = $i }
    }
    if ($lastSize -ge 0) { return ($segs[0..$lastSize] -join '-') }
    return $family
}

# Read a validated menu selection.
function Read-Choice($prompt, $count) {
    while ($true) {
        $raw = Read-Host $prompt
        $n = 0
        if ([int]::TryParse($raw, [ref]$n) -and $n -ge 1 -and $n -le $count) { return $n }
        Write-Host "  Please enter a number between 1 and $count." -ForegroundColor Yellow
    }
}

# ============================================================================
#  3. Environment discovery
# ============================================================================
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $root
$modelDir = Join-Path $root "models"
$llama = Join-Path $root "llama-server.exe"

if (!(Test-Path $llama))    { Fail "llama-server.exe not found in $root" }
if (!(Test-Path $modelDir)) { Fail "models folder not found: $modelDir" }

# llama-server version
$versionText = "unknown"
try {
    $vout = & $llama --version 2>&1 | Out-String
    if ($vout -match 'version[:\s]+([^\r\n]+)') { $versionText = $matches[1].Trim() }
    elseif ($vout -match '(\d+)\b') { $versionText = "build $($matches[1])" }
} catch { }

# Capability probe from --help
$helpText = ""
try { $helpText = & $llama --help 2>&1 | Out-String } catch { }
$supportsFlashAttn = $helpText -match '--flash-attn'
$flashAttnTakesValue = $helpText -match '--flash-attn\s+\['   # newer builds: --flash-attn [on|off|auto]
$supportsSlots = $helpText -match '--slots'
$supportsCacheType = $helpText -match '--cache-type-k'

# ============================================================================
#  4. Model discovery
# ============================================================================
$models = @(Get-ChildItem "$modelDir\*.gguf" | Where-Object { $_.Name -notmatch '(?i)^mmproj' })
if ($models.Count -eq 0) { Fail "No .gguf models found in $modelDir" }

$modelInfo = foreach ($f in $models) {
    $quant = Get-QuantToken $f.BaseName
    [pscustomobject]@{
        File   = $f
        Base   = $f.BaseName
        Quant  = $quant
        Family = Get-FamilyName $f.BaseName $quant
        SizeGB = [math]::Round($f.Length / 1GB, 2)
        Score  = Get-QuantScore $quant
    }
}
$modelInfo = @($modelInfo | Sort-Object -Property Score -Descending)

Write-Title "Universal GGUF Launcher   (llama-server $versionText)"
Write-Host "  Available models (recommended order):" -ForegroundColor Green
for ($i = 0; $i -lt $modelInfo.Count; $i++) {
    $mi = $modelInfo[$i]
    Write-Host ("  {0}. " -f ($i + 1)) -ForegroundColor Yellow -NoNewline
    Write-Host ("{0}" -f $mi.Base) -ForegroundColor White -NoNewline
    Write-Host ("   [{0}, {1} GB]" -f $mi.Quant, $mi.SizeGB) -ForegroundColor DarkGray
}
$sel = Read-Choice "  Select model" $modelInfo.Count
$model = $modelInfo[$sel - 1]

# ============================================================================
#  5. mmproj discovery (optional, may be several)
# ============================================================================
$mmList = @(Get-ChildItem "$modelDir\mmproj*.gguf" -ErrorAction SilentlyContinue)
$mmproj = $null
if ($mmList.Count -eq 1) {
    $mmproj = $mmList[0]
    Write-Host "  Vision projector: $($mmproj.Name)" -ForegroundColor DarkGray
}
elseif ($mmList.Count -gt 1) {
    Write-Host ""
    Write-Host "  Multiple mmproj projectors found:" -ForegroundColor Green
    for ($i = 0; $i -lt $mmList.Count; $i++) {
        Write-Host ("  {0}. {1}" -f ($i + 1), $mmList[$i].Name) -ForegroundColor White
    }
    $mmSel = Read-Choice "  Select mmproj" $mmList.Count
    $mmproj = $mmList[$mmSel - 1]
}

# ============================================================================
#  6. Mode selection
# ============================================================================
Write-Host ""
Write-Host "  Modes:" -ForegroundColor Green
for ($i = 0; $i -lt $Modes.Count; $i++) {
    Write-Host ("  {0}. " -f ($i + 1)) -ForegroundColor Yellow -NoNewline
    Write-Host $Modes[$i].Label -ForegroundColor White
}
$modeSel = Read-Choice "  Select mode" $Modes.Count
$mode = $Modes[$modeSel - 1]

# ============================================================================
#  7. Context size (entered in k; blank = default)
# ============================================================================
Write-Host ""
$ctxDefaultK = [int]($Config.CtxSize / 1024)
$rawCtx = Read-Host "  Context size in k (blank = $ctxDefaultK)"
if ([string]::IsNullOrWhiteSpace($rawCtx)) {
    $ctxK = $ctxDefaultK
}
else {
    $parsedK = 0
    if ([int]::TryParse($rawCtx.Trim(), [ref]$parsedK) -and $parsedK -gt 0) {
        $ctxK = $parsedK
    }
    else {
        Write-Host "  Invalid value, using default ${ctxDefaultK}k." -ForegroundColor Yellow
        $ctxK = $ctxDefaultK
    }
}
$ctxSize = $ctxK * 1024

# ============================================================================
#  8. Build alias + argument list
# ============================================================================
$aliasFamily = $model.Family
if ($Config.ShortAlias) { $aliasFamily = Get-ShortFamily $model.Family }
$aliasParts = @($aliasFamily, $model.Quant)
# if ($mode.AliasTag) { $aliasParts += $mode.AliasTag }
$alias = ($aliasParts | Where-Object { $_ -and $_ -ne "UNKNOWN" }) -join '-'

$serverArgs = @(
    "-m",     $model.File.FullName,
    "-ngl",   "$($Config.NGpuLayers)",
    "-c",     "$ctxSize",
    "-n",     "$($Config.Predict)",
    "--host", $Config.BindHost,
    "--port", "$($Config.Port)",
    "--alias", $alias
)
if ($Config.UseJinja) { $serverArgs += "--jinja" }
if ($mmproj)          { $serverArgs += @("--mmproj", $mmproj.FullName) }

if ($supportsFlashAttn) {
    if ($flashAttnTakesValue) { $serverArgs += @("--flash-attn", "on") }
    else { $serverArgs += "--flash-attn" }
}
if ($supportsSlots) { $serverArgs += "--slots" }

# Quantized KV cache (q8_0). V-cache quantization needs flash attention.
$kvCacheActive = $false
if ($supportsCacheType -and $Config.KvCacheType) {
    $serverArgs += @("--cache-type-k", $Config.KvCacheType, "--cache-type-v", $Config.KvCacheType)
    $kvCacheActive = $true
}

# CPU threads = 1/4 of physical cores (min 1). Physical cores are preferred for
# LLM inference; hyper-threaded logical cores rarely help and can hurt.
$physicalCores = 0
try { $physicalCores = [int](Get-CimInstance Win32_Processor | Measure-Object -Property NumberOfCores -Sum).Sum } catch { }
if ($physicalCores -lt 1) { $physicalCores = [int][math]::Floor([Environment]::ProcessorCount / 2) }  # fallback
if ($physicalCores -lt 1) { $physicalCores = [Environment]::ProcessorCount }
$threadCount = [math]::Max(1, [int][math]::Floor($physicalCores / 4))
$serverArgs += @("--threads", "$threadCount", "--threads-batch", "$threadCount")

foreach ($k in $mode.Params.Keys) {
    $serverArgs += @($k, $mode.Params[$k])
}

# ============================================================================
#  9. Configuration summary
# ============================================================================
Write-Title "Launch Configuration"
Write-KV "Model"       $model.Base
Write-KV "Family"      $model.Family
Write-KV "Quant"       $model.Quant
Write-KV "Size"        "$($model.SizeGB) GB"
Write-KV "Mode"        $mode.Label
Write-KV "Alias"       $alias
Write-KV "mmproj"      $(if ($mmproj) { $mmproj.Name } else { "(none)" })
Write-KV "Endpoint"    "http://$($Config.BindHost):$($Config.Port)"
Write-KV "Context"     "$ctxSize  (${ctxK}k)"
Write-KV "GPU layers"  $Config.NGpuLayers
Write-KV "flash-attn"  $(if ($supportsFlashAttn) { "enabled" } else { "unsupported" })
Write-KV "slots"       $(if ($supportsSlots) { "enabled" } else { "unsupported" })
Write-KV "KV cache"    $(if ($kvCacheActive) { $Config.KvCacheType } elseif ($supportsCacheType) { "f16 (disabled)" } else { "unsupported" })
Write-KV "Threads"     "$threadCount / $physicalCores physical"
if ($mode.Params.Count -gt 0) {
    $sampler = ($mode.Params.Keys | ForEach-Object { "$_ $($mode.Params[$_])" }) -join "  "
    Write-KV "Sampler" $sampler
}
Write-Host ""

Write-Host "  Starting llama-server..." -ForegroundColor Green
Write-Host ""
& $llama @serverArgs
