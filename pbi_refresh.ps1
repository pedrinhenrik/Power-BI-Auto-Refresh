param(
    [Parameter(Mandatory=$true)][string]$WorkspaceId,
    [Parameter(Mandatory=$true)][string]$DatasetId,
    [Parameter(Mandatory=$true)][string]$CredPath,
    [string]$LogPath,
    [string]$Name = "DATASET"
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

trap {
    $type  = $_.Exception.GetType().FullName
    $msg   = $_.Exception.Message
    $stack = $_.ScriptStackTrace
    Write-Host "❌ TRAP pbi_refresh:"
    Write-Host "• Tipo:   $type"
    Write-Host "• Mens.:  $msg"
    if ($stack) { Write-Host "• Stack:  $stack" }
    continue
}

# ============== Logging enxuto ==============
$script:_logWriter = $null
function Close-Log { try { if ($script:_logWriter) { $script:_logWriter.Dispose() } } catch {} }

function Start-Log([string]$path) {
    try {
        $dir = Split-Path -Parent $path
        if ($dir -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }

        $maxAttempts = 20
        $attempt = 0
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

        # Apontar para o fim do arquivo para append
        $fs.Seek(0, [System.IO.SeekOrigin]::End) | Out-Null

        # Writer com UTF-8 com BOM para renderizar emojis no Notepad
        $emitBom = $true
        $utf8Bom = New-Object System.Text.UTF8Encoding($emitBom)
        if ($fs.Length -eq 0) {
            $preamble = $utf8Bom.GetPreamble()
            if ($preamble.Length -gt 0) { $fs.Write($preamble, 0, $preamble.Length) }
        }

        $script:_logWriter = New-Object System.IO.StreamWriter($fs, $utf8Bom)
        $script:_logWriter.AutoFlush = $true
    } catch {
        Write-Warning "falha ao abrir log ($path): $($_.Exception.Message)"
    }
}

function Log([string]$msg) {
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $ctx = "[${ts}][$Name] "
    $line = $ctx + $msg
    Write-Host $line
    if ($script:_logWriter) { try { $script:_logWriter.WriteLine($line) } catch {} }
}

# ============== Helpers ==============
function Describe-PossibleCause($status, $body) {
    $b = [string]($body | Out-String)
    if ($b -match 'Another refresh.*in progress' -or $status -eq 409) { return 'Refresh já em andamento.' }
    if ($status -eq 401 -or $status -eq 403) { return 'Credencial inválida ou sem permissão.' }
    if ($status -eq 404) { return 'Workspace ou Dataset incorretos ou acesso negado.' }
    if ($b -match 'timeout' -or $b -match 'gateway') { return 'Timeout ou falha no gateway ou cluster.' }
    return 'Erro não classificado.'
}

function Get-HttpErrorInfo($ex) {
    $status = $null; $reason = $null; $body = $null
    try {
        if ($ex.PSObject.Properties.Name -contains 'StatusCode') { $status = $ex.StatusCode }
        if ($ex.PSObject.Properties.Name -contains 'ResponseBody') { $body = $ex.ResponseBody }
        if ($ex.PSObject.Properties.Name -contains 'Response') {
            $resp = $ex.Response
            try { if ($resp -and $resp.StatusCode)        { $status = $resp.StatusCode.value__ } } catch {}
            try { if ($resp -and $resp.StatusDescription) { $reason = $resp.StatusDescription } } catch {}
            try {
                if ($resp) {
                    $stream = $resp.GetResponseStream()
                    if ($stream) {
                        $reader = New-Object System.IO.StreamReader($stream)
                        $txt = $reader.ReadToEnd()
                        if ($txt) { $body = $txt }
                    }
                }
            } catch {}
        }
    } catch {}
    return [pscustomobject]@{ Status = $status; Reason = $reason; Body = $body }
}

# ============== Retenção de logs ==============
function Get-LogDirectory {
    if ($LogPath) {
        if ($LogPath.ToLower().EndsWith('.log')) {
            return (Split-Path -Parent $LogPath)
        } else {
            return $LogPath
        }
    }
    # Sem LogPath explícito, usar subpasta logs ao lado do script
    return (Join-Path $PSScriptRoot 'logs')
}

function Enforce-LogRetention([int]$daysToKeep = 4) {
    try {
        $logDir = Get-LogDirectory
        if (-not (Test-Path -LiteralPath $logDir)) { return }

        # Manter hoje e os últimos (daysToKeep - 1) dias
        $cutoff = (Get-Date).Date.AddDays(-($daysToKeep - 1))

        $files = Get-ChildItem -LiteralPath $logDir -Filter 'pbi_refresh_*.log' -File -ErrorAction SilentlyContinue
        if (-not $files) { return }

        $removed = 0
        foreach ($f in $files) {
            if ($f.Name -match '^pbi_refresh_(\d{8})\.log$') {
                $dateStr = $matches[1]
                try {
                    $fDate = [datetime]::ParseExact($dateStr, 'yyyyMMdd', $null)
                    if ($fDate -lt $cutoff) {
                        try {
                            Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
                            $removed++
                            if ($script:_logWriter) { Log ("🧹 Removido log antigo: {0}" -f $f.Name) }
                        } catch {
                            if ($script:_logWriter) { Log ("⚠️ Falha ao remover {0}: {1}" -f $f.Name, $_.Exception.Message) }
                        }
                    }
                } catch {
                    if ($script:_logWriter) { Log ("ℹ️ Ignorando arquivo fora do padrão: {0}" -f $f.Name) }
                }
            } else {
                if ($script:_logWriter) { Log ("ℹ️ Ignorando arquivo fora do padrão: {0}" -f $f.Name) }
            }
        }

        if ($script:_logWriter) {
            $total = @($files).Count
            Log ("📦 Retenção concluída. Total={0} Removidos={1} Cutoff>={2:yyyy-MM-dd}" -f $total, $removed, $cutoff)
        }
    } catch {
        if ($script:_logWriter) { Log ("⚠️ Erro na retenção de logs: {0}" -f $_.Exception.Message) }
    }
}

# ============== Guardrails iniciais ==============
if ($WorkspaceId -notmatch '^[0-9a-fA-F-]{36}$' -or $DatasetId -notmatch '^[0-9a-fA-F-]{36}$') {
    Log "❌ GUID inválido. Verifique WorkspaceId e DatasetId."
    exit 1
}
if (-not (Test-Path -LiteralPath $CredPath)) {
    Log "❌ CredPath não existe: $CredPath"
    exit 1
}

# ============== Import do módulo Power BI ==============
$imported = $false
foreach ($m in @('MicrosoftPowerBIMgmt.Profile','MicrosoftPowerBIMgmt')) {
    try { Import-Module $m -ErrorAction Stop; $imported = $true; break } catch {}
}
if (-not $imported) {
    Log "❌ MicrosoftPowerBIMgmt ausente. Instale: Install-Module MicrosoftPowerBIMgmt -Scope AllUsers -Force"
    exit 1
}

# ============== Configurar arquivo diário de log ==============
if ($LogPath) {
    $stamp = (Get-Date).ToString('yyyyMMdd')
    if ($LogPath.ToLower().EndsWith('.log')) {
        Start-Log -path $LogPath
    } else {
        $file = Join-Path $LogPath ("pbi_refresh_{0}.log" -f $stamp)
        Start-Log -path $file
    }
} else {
    $stamp = (Get-Date).ToString('yyyyMMdd')
    $defaultDir = Join-Path $PSScriptRoot 'logs'
    $file = Join-Path $defaultDir ("pbi_refresh_{0}.log" -f $stamp)
    Start-Log -path $file
}
if ($script:_logWriter) { Log "🧾 Logging diário habilitado." }

# Limpeza de logs antigos depois de abrir o log de hoje
Enforce-LogRetention -daysToKeep 4

# ============== Execução ==============
try {
    Log ("📊 Disparando refresh para [{0}]" -f $Name)

    $BaseUrl        = "https://api.powerbi.com/v1.0/myorg"
    $UrlRefresh     = "$BaseUrl/groups/$WorkspaceId/datasets/$DatasetId/refreshes"
    $UrlAppRefresh  = "https://app.powerbi.com/groups/$WorkspaceId/datasets/$DatasetId/refreshes"

    # Conectar
    $Cred = Import-Clixml -LiteralPath $CredPath
    try {
        Connect-PowerBIServiceAccount -Credential $Cred -ErrorAction Stop | Out-Null
        Log "✅ Power Bi conectado - ::PBI_CONNECTED"
    } catch {
        Log "❌ Falha ao conectar: $($_.Exception.Message)"
        exit 1
    }

    # Pré-check de refresh em andamento
    try {
        $current = Invoke-PowerBIRestMethod -Url $UrlRefresh -Method Get -ErrorAction Stop | ConvertFrom-Json
        $last = $current.value | Sort-Object startTime -Descending | Select-Object -First 1
        if ($last -and $last.status -eq "InProgress") {
            Log ("⛔ Já há refresh em andamento id={0}. Encerrando cedo." -f $last.id)
            exit 0
        }
    } catch {
        Log "⚠️ Falha no pré-check de status. Prosseguindo."
    }

    # Disparar refresh
    Log "🚀 Solicitando atualização..."
    $refreshId = $null
    try {
        $Body = @{ notifyOption = "MailOnFailure" } | ConvertTo-Json
        Invoke-PowerBIRestMethod -Url $UrlRefresh -Method Post -Body $Body -ContentType "application/json" -ErrorAction Stop | Out-Null
        Start-Sleep -Seconds 2
        $latest    = Invoke-PowerBIRestMethod -Url $UrlRefresh -Method Get -ErrorAction Stop | ConvertFrom-Json
        $refreshId = $latest.value | Sort-Object startTime -Descending | Select-Object -First 1 -ExpandProperty id
        Log ("🛠️ Atualização Iniciada ::PBI_REFRESH_QUEUED {0} id={1}" -f $UrlAppRefresh, $refreshId)
    } catch {
        $info = Get-HttpErrorInfo $_.Exception
        Log "❌ Falha ao solicitar atualização."
        if ($info.Status) { Log ("• Status: {0} {1}" -f $info.Status, $info.Reason) }
        if ($_.Exception.Message) { Log ("• Message: {0}" -f $_.Exception.Message) }
        if ($info.Body) {
            $txt = [string]$info.Body
            if ($txt.Length -gt 2000) { $txt = $txt.Substring(0,2000) + ' ...[truncado]' }
            Log ("• Body: {0}" -f $txt)
        }
        Log ("• Possível causa: {0}" -f (Describe-PossibleCause $info.Status $info.Body))
        exit 1
    }

    # Monitorar
    Log "⏱️ Monitorando status a cada 15s com timeout de 30min..."
    $inicio  = Get-Date
    $timeout = [TimeSpan]::FromMinutes(30)
    $Status  = "Unknown"; $i = 0

    try {
        do {
            Start-Sleep -Seconds 15
            $i++
            $Resp = Invoke-PowerBIRestMethod -Url $UrlRefresh -Method Get -ErrorAction Stop | ConvertFrom-Json
            $entry = if ($refreshId) { $Resp.value | Where-Object { $_.id -eq $refreshId } | Select-Object -First 1 } else { $Resp.value[0] }
            if ($null -eq $entry) { continue }
            $Status = $entry.status
            Log ("📊 Status atual: {0} checagem {1}" -f $Status, $i)
            if ((Get-Date) - $inicio -gt $timeout) { Log "❌ Timeout de monitoramento."; break }
        } while ($Status -in @("Unknown","InProgress"))
    } catch {
        Log "❌ Erro ao consultar status: $($_.Exception.Message)"
        exit 1
    }

    $dur = [math]::Round(((Get-Date) - $inicio).TotalSeconds, 2)
    if     ($Status -eq "Completed") { Log "✅ Atualização concluída com sucesso." }
    elseif ($Status -eq "Failed")    { Log "❌ Falha na atualização." }
    else                             { Log ("ℹ️ Status final: {0}" -f $Status) }

    Log ("⏱️ Duração total: {0}s" -f $dur)
    Log ("🔗 Acompanhe no Power BI: {0}" -f $UrlAppRefresh)
}
finally {
    Close-Log
}