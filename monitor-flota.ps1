<#
    monitor-flota.ps1
    Lee el estado de todos los mineros y publica un informe en GitHub.

    Uso:
        .\monitor-flota.ps1              -> lee, genera informe y sube a GitHub
        .\monitor-flota.ps1 -SinSubir    -> solo genera el informe, no sube nada
        .\monitor-flota.ps1 -Test        -> muestra el informe por pantalla

    No necesita contraseñas: usa la API del minero (puerto 4028), que no pide auth.
#>
param(
    [switch]$SinSubir,
    [switch]$Test
)

$ErrorActionPreference = "Continue"

# ============================================================
#  CONFIGURACION - edita esta lista si cambian tus mineros
# ============================================================

$MINEROS = @(
    @{ Nombre = "kiwi01"; Host = "Gabriel01"; IP = "192.168.0.138" }
    @{ Nombre = "kiwi02"; Host = "Gabriel02"; IP = "192.168.0.237" }
    @{ Nombre = "kiwi03"; Host = "Gabriel03"; IP = "192.168.0.176" }
    @{ Nombre = "kiwi04"; Host = "Gabriel00"; IP = "192.168.0.165" }
    @{ Nombre = "Sara00"; Host = "Sara00";    IP = "192.168.0.145" }
    @{ Nombre = "Sara02"; Host = "Sara02";    IP = "192.168.0.200" }
    @{ Nombre = "Sara03"; Host = "Sara03";    IP = "192.168.0.195" }
    @{ Nombre = "Sara04"; Host = "Sara04";    IP = "192.168.0.235" }
)

# Umbrales de aviso
$TEMP_AVISO   = 90    # grados: por encima, aviso amarillo
$TEMP_ALERTA  = 95    # grados: por encima, alerta roja
$VENT_AVISO   = 90    # % de ventilador: por encima, aviso

$RAIZ = Split-Path -Parent $MyInvocation.MyCommand.Path

# ============================================================
#  LECTURA DE LOS MINEROS
# ============================================================

function Invoke-MinerApi {
    param([string]$IP, [string]$Comando)
    try {
        $c = New-Object System.Net.Sockets.TcpClient
        $c.ReceiveTimeout = 5000
        $c.SendTimeout = 5000
        $t = $c.ConnectAsync($IP, 4028)
        if (-not ($t.Wait(2500) -and $c.Connected)) { try { $c.Close() } catch {}; return $null }
        $s = $c.GetStream()
        $b = [Text.Encoding]::ASCII.GetBytes('{"command":"' + $Comando + '"}')
        $s.Write($b, 0, $b.Length); $s.Flush()
        $sr = New-Object IO.StreamReader($s)
        $raw = $sr.ReadToEnd()
        $c.Close()
        return (($raw -replace "`0", "").Trim() | ConvertFrom-Json)
    } catch { return $null }
}

function Get-EstadoMinero {
    param($Minero)

    $r = [ordered]@{
        Nombre = $Minero.Nombre; Host = $Minero.Host; IP = $Minero.IP
        Online = $false; Hashrate = 0.0; Vatios = 0; Limite = 0
        Uptime = 0; Aceptadas = 0; Rechazadas = 0
        PlacasOk = 0; PlacasVistas = 0; TempMax = 0
        VentMax = 0; VentRpm = @(); Placas = @(); Avisos = @()
    }

    $sum = Invoke-MinerApi $Minero.IP "summary"
    if ($null -eq $sum) { return [pscustomobject]$r }

    $r.Online     = $true
    $r.Hashrate   = [math]::Round($sum.SUMMARY[0].'MHS 5m' / 1000000, 2)
    $r.Uptime     = [int]$sum.SUMMARY[0].Elapsed
    $r.Aceptadas  = [int]$sum.SUMMARY[0].Accepted
    $r.Rechazadas = [int]$sum.SUMMARY[0].Rejected

    $devs  = Invoke-MinerApi $Minero.IP "devs"
    $dd    = Invoke-MinerApi $Minero.IP "devdetails"
    $tun   = Invoke-MinerApi $Minero.IP "tunerstatus"
    $temps = Invoke-MinerApi $Minero.IP "temps"
    $fans  = Invoke-MinerApi $Minero.IP "fans"

    if ($tun) {
        $r.Vatios = [int]$tun.TUNERSTATUS[0].ApproximateMinerPowerConsumption
        $r.Limite = [int]$tun.TUNERSTATUS[0].PowerLimit
    }

    if ($fans) {
        $activos = @($fans.FANS | Where-Object { $_.RPM -gt 0 })
        $r.VentRpm = @($activos | ForEach-Object { [int]$_.RPM })
        if ($fans.FANS.Count -gt 0) { $r.VentMax = [int](($fans.FANS | Measure-Object -Property Speed -Maximum).Maximum) }
        if ($activos.Count -lt 2) { $r.Avisos += "solo $($activos.Count) ventilador activo" }
    }

    foreach ($idx in 6, 7, 8) {
        $d = $null; if ($devs)  { $d  = $devs.DEVS | Where-Object { $_.ID -eq $idx } | Select-Object -First 1 }
        $ch = $null; if ($dd)   { $ch = $dd.DEVDETAILS | Where-Object { $_.ID -eq $idx } | Select-Object -First 1 }
        $tp = $null; if ($temps){ $tp = $temps.TEMPS | Where-Object { $_.ID -eq $idx } | Select-Object -First 1 }
        $tc = $null; if ($tun)  { $tc = $tun.TUNERSTATUS[0].TunerChainStatus | Where-Object { $_.HashchainIndex -eq $idx } | Select-Object -First 1 }

        $p = [ordered]@{ Id = $idx; Estado = "ausente"; Chips = 0; Hashrate = 0.0; Vatios = 0; Temp = 0 }

        if ($null -ne $d) {
            $r.PlacasVistas++
            $p.Hashrate = [math]::Round($d.'MHS 5m' / 1000000, 2)
            if ($ch) { $p.Chips = [int]$ch.Chips }
            if ($tc) { $p.Vatios = [int]$tc.ApproximatePowerConsumptionWatt }
            if ($tp) { $p.Temp = [math]::Round([double]$tp.Chip, 1) }

            if ($p.Hashrate -gt 0.05) {
                $p.Estado = "minando"; $r.PlacasOk++
                if ($p.Temp -gt $r.TempMax) { $r.TempMax = $p.Temp }
            }
            elseif ($p.Vatios -gt 0) { $p.Estado = "sin producir" }
            else { $p.Estado = "sin corriente" }
        }
        $r.Placas += [pscustomobject]$p
    }

    if ($r.TempMax -ge $TEMP_ALERTA) { $r.Avisos += "temperatura $($r.TempMax) grados" }
    elseif ($r.TempMax -ge $TEMP_AVISO) { $r.Avisos += "temperatura alta $($r.TempMax) grados" }
    if ($r.VentMax -ge $VENT_AVISO -and $r.TempMax -ge $TEMP_AVISO) { $r.Avisos += "ventiladores al $($r.VentMax)% sin margen" }
    if ($r.PlacasOk -lt 3) { $r.Avisos += "$($r.PlacasOk) de 3 placas minando" }

    return [pscustomobject]$r
}

# ============================================================
#  RECOGIDA
# ============================================================

Write-Host "Leyendo mineros..." -ForegroundColor Cyan
$estados = @()
foreach ($m in $MINEROS) { $estados += Get-EstadoMinero $m }

$online   = @($estados | Where-Object { $_.Online })
$totalTh  = [math]::Round((($online | Measure-Object Hashrate -Sum).Sum), 2)
$totalW   = [int](($online | Measure-Object Vatios -Sum).Sum)
$totalOk  = [int](($online | Measure-Object PlacasOk -Sum).Sum)
$jth = 0; if ($totalTh -gt 0) { $jth = [math]::Round($totalW / $totalTh, 1) }
$ahora = Get-Date

# ============================================================
#  HISTORIAL (para la tendencia)
# ============================================================

$csv = Join-Path $RAIZ "historial.csv"
if (-not (Test-Path $csv)) { "fecha,hashrate,vatios,mineros,placas" | Out-File $csv -Encoding utf8 }
("{0},{1},{2},{3},{4}" -f $ahora.ToString("yyyy-MM-dd HH:mm"), $totalTh, $totalW, $online.Count, $totalOk) |
    Add-Content $csv -Encoding utf8

# sparkline con los ultimos 24 registros
$historia = @(Get-Content $csv -Encoding utf8 | Select-Object -Skip 1 | Select-Object -Last 24)
$spark = ""
if ($historia.Count -gt 1) {
    $vals = @($historia | ForEach-Object { [double](($_ -split ',')[1]) })
    $min = ($vals | Measure-Object -Minimum).Minimum
    $max = ($vals | Measure-Object -Maximum).Maximum
    $blocks = @([char]0x2581,[char]0x2582,[char]0x2583,[char]0x2584,[char]0x2585,[char]0x2586,[char]0x2587,[char]0x2588)
    foreach ($v in $vals) {
        $i = 0
        if ($max -gt $min) { $i = [int][math]::Round((($v - $min) / ($max - $min)) * 7) }
        $spark += $blocks[$i]
    }
}

# ============================================================
#  GENERAR EL INFORME
# ============================================================

function Barra {
    param([double]$Valor, [double]$Max, [int]$Ancho = 10)
    if ($Max -le 0) { return ("." * $Ancho) }
    $n = [int][math]::Round(($Valor / $Max) * $Ancho)
    if ($n -lt 0) { $n = 0 }; if ($n -gt $Ancho) { $n = $Ancho }
    return ("#" * $n) + ("." * ($Ancho - $n))
}

$md = New-Object System.Text.StringBuilder
$nl = [Environment]::NewLine

[void]$md.AppendLine("# Flota Altairss")
[void]$md.AppendLine("")
[void]$md.AppendLine("**$($ahora.ToString('dd/MM/yyyy HH:mm'))**")
[void]$md.AppendLine("")

$estadoGlobal = "OK"
if ($online.Count -eq 0) { $estadoGlobal = "SIN CORRIENTE" }
elseif ($online.Count -lt $MINEROS.Count) { $estadoGlobal = "$($MINEROS.Count - $online.Count) minero(s) caido(s)" }

[void]$md.AppendLine("## $totalTh TH/s &nbsp;&nbsp;|&nbsp;&nbsp; $([math]::Round($totalW/1000,2)) kW &nbsp;&nbsp;|&nbsp;&nbsp; $($online.Count)/$($MINEROS.Count) mineros")
[void]$md.AppendLine("")
[void]$md.AppendLine("| | |")
[void]$md.AppendLine("|---|---|")
[void]$md.AppendLine("| **Estado** | $estadoGlobal |")
[void]$md.AppendLine("| **Placas minando** | $totalOk de 24 |")
[void]$md.AppendLine("| **Eficiencia** | $jth J/TH |")
if ($spark) { [void]$md.AppendLine("| **Ultimas horas** | ``$spark`` |") }
[void]$md.AppendLine("")

# ---- LA TIRA: temperatura y hashrate de un vistazo ----
[void]$md.AppendLine("## Resumen")
[void]$md.AppendLine("")
[void]$md.AppendLine("| | Minero | Hashrate | | Temp | | Placas | W |")
[void]$md.AppendLine("|---|---|---|---|---|---|---|---|")

foreach ($e in ($estados | Sort-Object -Property @{Expression={$_.Hashrate}} -Descending)) {
    if (-not $e.Online) {
        [void]$md.AppendLine("| :black_circle: | **$($e.Nombre)** | apagado | | | | | |")
        continue
    }
    $icono = ":green_circle:"
    if ($e.Avisos.Count -gt 0) { $icono = ":yellow_circle:" }
    if ($e.PlacasOk -eq 0 -or $e.TempMax -ge $TEMP_ALERTA) { $icono = ":red_circle:" }

    $barH = Barra $e.Hashrate 13.0 10
    $barT = Barra ($e.TempMax - 60) 40 6
    $t = "-"
    if ($e.TempMax -gt 0) { $t = "$($e.TempMax) C" }

    [void]$md.AppendLine("| $icono | **$($e.Nombre)** | **$($e.Hashrate)** TH/s | ``$barH`` | $t | ``$barT`` | $($e.PlacasOk)/3 | $($e.Vatios) |")
}
[void]$md.AppendLine("")

# ---- AVISOS ----
$conAvisos = @($estados | Where-Object { $_.Online -and $_.Avisos.Count -gt 0 })
$caidos = @($estados | Where-Object { -not $_.Online })
if ($conAvisos.Count -gt 0 -or $caidos.Count -gt 0) {
    [void]$md.AppendLine("## Avisos")
    [void]$md.AppendLine("")
    foreach ($e in $caidos) { [void]$md.AppendLine("- :black_circle: **$($e.Nombre)** ($($e.IP)) no responde") }
    foreach ($e in $conAvisos) {
        foreach ($a in $e.Avisos) { [void]$md.AppendLine("- :warning: **$($e.Nombre)**: $a") }
    }
    [void]$md.AppendLine("")
}

# ---- DETALLE POR MAQUINA ----
[void]$md.AppendLine("## Detalle por maquina")
[void]$md.AppendLine("")
foreach ($e in $estados) {
    if (-not $e.Online) {
        [void]$md.AppendLine("<details><summary>:black_circle: <b>$($e.Nombre)</b> - apagado</summary>")
        [void]$md.AppendLine("")
        [void]$md.AppendLine("Sin respuesta en $($e.IP)")
        [void]$md.AppendLine("")
        [void]$md.AppendLine("</details>")
        [void]$md.AppendLine("")
        continue
    }
    $up = [timespan]::FromSeconds($e.Uptime)
    $upTxt = "{0}h {1}m" -f [int]$up.TotalHours, $up.Minutes
    $ic = ":green_circle:"; if ($e.Avisos.Count -gt 0) { $ic = ":yellow_circle:" }
    if ($e.PlacasOk -eq 0) { $ic = ":red_circle:" }

    [void]$md.AppendLine("<details><summary>$ic <b>$($e.Nombre)</b> - $($e.Hashrate) TH/s, $($e.PlacasOk)/3 placas</summary>")
    [void]$md.AppendLine("")
    [void]$md.AppendLine("`$($e.Host)` &middot; $($e.IP) &middot; encendido $upTxt &middot; $($e.Vatios) W de $($e.Limite) W")
    [void]$md.AppendLine("")
    [void]$md.AppendLine("| Placa | Estado | Chips | Hashrate | Vatios | Temp |")
    [void]$md.AppendLine("|---|---|---|---|---|---|")
    foreach ($p in $e.Placas) {
        $et = switch ($p.Estado) {
            "minando"       { ":green_circle: minando" }
            "sin producir"  { ":yellow_circle: con corriente, sin producir" }
            "sin corriente" { ":red_circle: sin corriente" }
            default         { ":black_circle: no conectada" }
        }
        $chips = "-"; if ($p.Chips -gt 0) { $chips = $p.Chips }
        $temp = "-"; if ($p.Temp -gt 0) { $temp = "$($p.Temp) C" }
        $hr = "-"; if ($p.Hashrate -gt 0) { $hr = "$($p.Hashrate) TH/s" }
        [void]$md.AppendLine("| $($p.Id) | $et | $chips | $hr | $($p.Vatios) | $temp |")
    }
    [void]$md.AppendLine("")
    if ($e.VentRpm.Count -gt 0) {
        [void]$md.AppendLine("Ventiladores: $($e.VentRpm -join ' / ') rpm (pedido $($e.VentMax)%)")
        [void]$md.AppendLine("")
    }
    [void]$md.AppendLine("Compartidas: $($e.Aceptadas) aceptadas / $($e.Rechazadas) rechazadas")
    [void]$md.AppendLine("")
    [void]$md.AppendLine("</details>")
    [void]$md.AppendLine("")
}

[void]$md.AppendLine("---")
[void]$md.AppendLine("")
[void]$md.AppendLine("<sub>Generado automaticamente por ``monitor-flota.ps1``. Si la fecha de arriba es vieja, el PC que recoge los datos esta apagado.</sub>")

$texto = $md.ToString()

if ($Test) { Write-Host $texto; exit 0 }

$readme = Join-Path $RAIZ "README.md"
$texto | Out-File -FilePath $readme -Encoding utf8
Write-Host "Informe generado: $readme" -ForegroundColor Green
Write-Host ("  {0} TH/s   {1} W   {2}/{3} mineros" -f $totalTh, $totalW, $online.Count, $MINEROS.Count) -ForegroundColor Cyan

# ============================================================
#  SUBIR A GITHUB
# ============================================================

if ($SinSubir) { Write-Host "(-SinSubir: no se sube nada)" -ForegroundColor DarkGray; exit 0 }

Push-Location $RAIZ
try {
    if (-not (Test-Path (Join-Path $RAIZ ".git"))) {
        Write-Host "Esta carpeta no es un repositorio git todavia." -ForegroundColor Yellow
        Write-Host "Ejecuta primero:  .\configurar-github.ps1" -ForegroundColor Yellow
        exit 1
    }
    git add README.md historial.csv 2>&1 | Out-Null
    $cambios = git status --porcelain 2>&1
    if ([string]::IsNullOrWhiteSpace($cambios)) {
        Write-Host "Sin cambios que subir." -ForegroundColor DarkGray
    } else {
        $msg = "Flota: {0} TH/s - {1}" -f $totalTh, $ahora.ToString("dd/MM HH:mm")
        git commit -m $msg 2>&1 | Out-Null
        $push = git push 2>&1
        if ($LASTEXITCODE -eq 0) { Write-Host "Subido a GitHub." -ForegroundColor Green }
        else { Write-Host "No se pudo subir:" -ForegroundColor Red; Write-Host $push -ForegroundColor DarkGray }
    }
} finally { Pop-Location }
