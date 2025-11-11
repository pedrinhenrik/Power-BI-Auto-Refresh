# =========================
# PCódigo cmd:
# =========================
# schtasks /query /fo TABLE | findstr /i bi_
# =========================

param(
    [Parameter(Mandatory = $true)]
    [string]$TaskKey,
    [switch]$Passthru = $false
)

# =========================
# Paths
# =========================
$Root       = Split-Path -Parent $PSCommandPath
$Ps1Refresh = Join-Path $Root 'pbi_refresh.ps1'
$Registry   = Join-Path $Root 'registry.json'
$CredPath   = Join-Path $Root '.cred\global_pbi.cred'
$LogsDir    = Join-Path $Root 'logs'

New-Item -ItemType Directory -Force -Path $LogsDir | Out-Null

# Daily log (shared)
$LogFile = Join-Path $LogsDir ("pbi_refresh_" + (Get-Date -Format 'yyyyMMdd') + ".log")

# =========================
# Concurrency-safe logger (UTF-8 with BOM), minimal ASCII lines
# =========================
$script:_logWriter = $null
function Close-Log { try { if ($script:_logWriter) { $script:_logWriter.Dispose() } } catch {} }

function Start-Log([string]$path) {
    try {
        $dir = Split-Path -Parent $path
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

        # Open with sharing and small retry/backoff
        $maxAttempts = 20; $attempt = 0
        while ($true) {
            try {
                $fs = [System.IO.File]::Open($path,
                                             [System.IO.FileMode]::OpenOrCreate,
                                             [System.IO.FileAccess]::ReadWrite,
                                             [System.IO.FileShare]::ReadWrite)
                break
            } catch {
                if ($attempt -ge $maxAttempts) { throw }
                Start-Sleep -Milliseconds 100
                $attempt++
            }
        }

        # Seek end for append
        $fs.Seek(0, [System.IO.SeekOrigin]::End) | Out-Null

        # UTF-8 with BOM so Notepad detects encoding; only write BOM if file is empty
        $utf8Bom = New-Object System.Text.UTF8Encoding($true)
        if ($fs.Length -eq 0) {
            $preamble = $utf8Bom.GetPreamble()
            if ($preamble.Length -gt 0) { $fs.Write($preamble, 0, $preamble.Length) }
        }

        $script:_logWriter = New-Object System.IO.StreamWriter($fs, $utf8Bom)
        $script:_logWriter.AutoFlush = $true
    } catch {
        Write-Warning ("run_task: failed to open log: " + $_.Exception.Message)
    }
}

function LogRT([string]$msg) {
    # ASCII-only monitoring lines to avoid mojibake; child script prints rich lines
    $ts   = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[${ts}][run_task|$TaskKey] $msg"
    if ($script:_logWriter) { try { $script:_logWriter.WriteLine($line) } catch {} }
}

Start-Log -path $LogFile

# =========================
# Registry & task resolution
# =========================
if (-not (Test-Path $Registry)) { LogRT "ERROR: registry.json not found: $Registry"; throw "registry.json not found." }
$json = Get-Content $Registry -Raw -Encoding UTF8 | ConvertFrom-Json
if (-not $json.paineis) { LogRT "ERROR: 'paineis' missing in registry.json"; throw "registry.json invalid." }

function SafeKey($n) {
    $formD   = $n.Normalize([Text.NormalizationForm]::FormD)
    $noMarks = [regex]::Replace($formD, '\p{Mn}', '')
    return ($noMarks -replace '[^\p{L}\p{Nd}-_]', '_').ToLower()
}
$target = $null
foreach ($p in $json.paineis) {
    if ((SafeKey $p.name) -eq $TaskKey.ToLower()) { $target = $p; break }
}
if (-not $target) { LogRT ("ERROR: painel not found for TaskKey=" + $TaskKey); throw "Painel not found." }

# =========================
# Resolve PowerShell
# =========================
$psExe = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
if (-not (Test-Path $psExe)) { $psExe = "powershell.exe" }

# =========================
# Build argument string (quoted)
# =========================
function Quote-Arg([string]$s) {
    if ($null -eq $s) { return '""' }
    if ($s -match '[\s"`$'']') {
        $s = $s -replace '"','`"'
        return '"' + $s + '"'
    }
    return $s
}

$argsRaw = @(
    "-NoProfile",
    "-ExecutionPolicy","Bypass",
    "-File", $Ps1Refresh,
    "-WorkspaceId", $target.workspace_id,
    "-DatasetId",   $target.dataset_id,
    "-CredPath",    $CredPath,
    "-Name",        $target.name,
    "-LogPath",     $LogsDir
)
$argString = ($argsRaw | ForEach-Object { Quote-Arg $_ }) -join ' '

# =========================
# Execute (no mirroring to file)
# =========================
try {
    LogRT "starting"
    if ($Passthru) {
        # Interactive: show child output on console; child writes to the daily log.
        & $psExe @argsRaw
        $code = $LASTEXITCODE
        LogRT ("exitcode=" + $code)
        if ($code -ne 0) { throw "refresh failed with exitcode=$code" }
    } else {
        # Scheduler-friendly: hidden window; child writes to the daily log.
        $proc = Start-Process -FilePath $psExe -ArgumentList $argString -WindowStyle Hidden -Wait -PassThru
        LogRT ("exitcode=" + $proc.ExitCode)
        if ($proc.ExitCode -ne 0) { throw "refresh failed with exitcode=$($proc.ExitCode)" }
    }
}
catch {
    LogRT ("ERROR: " + $_.Exception.Message)
    throw
}
finally {
    Close-Log
}