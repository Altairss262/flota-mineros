<#
    VIGILAR.ps1
    Vigilancia en vivo de la flota. Se queda corriendo en la terminal y
    redibuja el estado cada pocos segundos, avisando de cada cambio.

    NO toca nada: no manda correos, no sube a GitHub, no escribe datos.json.
    Solo mira. Puedes tenerlo abierto a la vez que el recolector automatico.

    Uso:
        .\VIGILAR.ps1                 -> refresca cada 20 segundos
        .\VIGILAR.ps1 -Segundos 10    -> refresca cada 10 segundos

    Para salir: Ctrl+C
#>
param(
    [int]$Segundos = 20
)

$ErrorActionPreference = "Continue"

$MINEROS = @(
    @{ Nombre = "kiwi01"; IP = "192.168.0.137" }
    @{ Nombre = "kiwi02"; IP = "192.168.0.237" }
    @{ Nombre = "kiwi03"; IP = "192.168.0.176" }
    @{ Nombre = "Sara00"; IP = "192.168.0.145" }
    @{ Nombre = "Sara02"; IP = "192.168.0.200" }
    @{ Nombre = "Sara03"; IP = "192.168.0.195" }
    @{ Nombre = "Sara04"; IP = "192.168.0.235" }
)

$TEMP_CRIT = 95
$VENT_BAJO = 2000
$DESEQ     = 0.6      # un ventilador por debajo del 60% del otro

# ------------------------------------------------------------
#  API
# ------------------------------------------------------------
function Invoke-MinerApi {
    param([string]$IP, [string]$Comando)
    try {
        $c = New-Object System.Net.Sockets.TcpClient
        $c.ReceiveTimeout = 4000; $c.SendTimeout = 4000
        $t = $c.ConnectAsync($IP, 4028)
        if (-not ($t.Wait(2000) -and $c.Connected)) { try { $c.Close() } catch {}; return $null }
        $s = $c.GetStream()
        $b = [Text.Encoding]::ASCII.GetBytes('{"command":"' + $Comando + '"}')
        $s.Write($b, 0, $b.Length); $s.Flush()
        $sr = New-Object IO.StreamReader($s)
        $raw = $sr.ReadToEnd(); $c.Close()
        $limpio = $raw.Replace([string][char]0, "").Trim()
        return ($limpio | ConvertFrom-Json)
    } catch { return $null }
}

function Leer-Minero {
    param($M)
    $r = [ordered]@{
        nombre = $M.Nombre; ip = $M.IP; online = $false
        hashrate = 0.0; vatios = 0; uptime = 0
        placasOk = 0; tempMax = 0.0; ventiladores = @()
    }
    $sum = Invoke-MinerApi $M.IP "summary"
    if ($null -eq $sum -or $null -eq $sum.SUMMARY) { return $r }

    $r.online   = $true
    $r.hashrate = [math]::Round(($sum.SUMMARY[0].'MHS av' / 1000000), 2)
    $r.uptime   = [int]$sum.SUMMARY[0].Elapsed

    $fans = Invoke-MinerApi $M.IP "fans"
    if ($fans -and $fans.FANS) {
        $r.ventiladores = @($fans.FANS | Where-Object { $_.RPM -gt 0 } | ForEach-Object { [int]$_.RPM })
    }

    $temps = Invoke-MinerApi $M.IP "temps"
    if ($temps -and $temps.TEMPS) {
        foreach ($t in $temps.TEMPS) {
            if ($t.Chip -gt $r.tempMax) { $r.tempMax = [math]::Round([double]$t.Chip, 1) }
        }
    }

    $tun = Invoke-MinerApi $M.IP "tunerstatus"
    if ($tun -and $tun.TUNERSTATUS) {
        $r.vatios = [int]$tun.TUNERSTATUS[0].ApproximateMinerPowerConsumption
        foreach ($c in $tun.TUNERSTATUS[0].TunerChainStatus) {
            if ($c.ApproximatePowerConsumptionWatt -gt 0) { $r.placasOk++ }
        }
    }
    return $r
}

# ------------------------------------------------------------
#  Registro de sucesos
# ------------------------------------------------------------
$sucesos = New-Object System.Collections.ArrayList

function Anota {
    param([string]$Texto, [string]$Color = "Gray")
    $linea = [ordered]@{ hora = (Get-Date -Format "HH:mm:ss"); texto = $Texto; color = $Color }
    [void]$sucesos.Add($linea)
    while ($sucesos.Count -gt 14) { $sucesos.RemoveAt(0) }
}

function Duracion {
    param([int]$Seg)
    if ($Seg -le 0) { return "-" }
    $h = [math]::Floor($Seg / 3600); $m = [math]::Floor(($Seg % 3600) / 60)
    if ($h -gt 0) { return ("{0}h{1:00}m" -f $h, $m) }
    return ("{0}m" -f $m)
}

# ------------------------------------------------------------
#  Bucle
# ------------------------------------------------------------
$anterior = @{}
$ciclo = 0
$arranque = Get-Date
$flotaCaida = $false

Anota "Vigilancia iniciada. Ctrl+C para salir." "Cyan"

while ($true) {
    $ciclo++
    $lect = @()
    foreach ($m in $MINEROS) { $lect += Leer-Minero $m }

    $online = @($lect | Where-Object { $_.online })
    $totTh = 0.0; $totW = 0; $totOk = 0
    foreach ($o in $online) {
        $totTh += [double]$o.hashrate
        $totW  += [int]$o.vatios
        $totOk += [int]$o.placasOk
    }
    $totTh = [math]::Round($totTh, 2)

    # ---------- detectar cambios ----------
    if ($online.Count -eq 0 -and -not $flotaCaida) {
        Anota "APAGON: la flota entera dejo de responder." "Red"
        $flotaCaida = $true
    } elseif ($online.Count -gt 0 -and $flotaCaida) {
        Anota ("VOLVIO LA LUZ: {0} de {1} maquinas arrancaron." -f $online.Count, $MINEROS.Count) "Green"
        $flotaCaida = $false
    }

    foreach ($l in $lect) {
        $a = $anterior[$l.nombre]
        if ($null -ne $a) {

            if ($a.online -and -not $l.online) { Anota ("{0} dejo de responder." -f $l.nombre) "Red" }
            if (-not $a.online -and $l.online) { Anota ("{0} volvio ({1} TH/s)." -f $l.nombre, $l.hashrate) "Green" }

            if ($l.online -and $a.online) {
                # un uptime que baja = la maquina se reinicio
                if ($l.uptime -lt $a.uptime) {
                    Anota ("{0} SE REINICIO (llevaba {1})." -f $l.nombre, (Duracion $a.uptime)) "Red"
                }
                if ($l.placasOk -lt $a.placasOk) {
                    Anota ("{0} perdio una placa: {1} -> {2}." -f $l.nombre, $a.placasOk, $l.placasOk) "Red"
                }
                if ($l.placasOk -gt $a.placasOk) {
                    Anota ("{0} recupero una placa: {1} -> {2}." -f $l.nombre, $a.placasOk, $l.placasOk) "Green"
                }
                if ($a.tempMax -lt $TEMP_CRIT -and $l.tempMax -ge $TEMP_CRIT) {
                    Anota ("{0} a {1} grados." -f $l.nombre, $l.tempMax) "Red"
                }
                if ($a.hashrate -gt 1 -and $l.hashrate -lt ($a.hashrate * 0.75)) {
                    Anota ("{0} cayo de {1} a {2} TH/s." -f $l.nombre, $a.hashrate, $l.hashrate) "Yellow"
                }
            }
        }
        $anterior[$l.nombre] = $l
    }

    # ---------- pintar ----------
    # Clear-Host revienta si la salida esta redirigida (sin consola real)
    try { Clear-Host } catch { Write-Host "" }
    Write-Host ""
    Write-Host "  VIGILANCIA DE FLOTA" -ForegroundColor Cyan -NoNewline
    Write-Host ("      {0}      ciclo {1}      abierta desde {2}" -f (Get-Date -Format "HH:mm:ss"), $ciclo, $arranque.ToString("HH:mm")) -ForegroundColor DarkGray
    Write-Host ""

    $colTot = "Yellow"
    if ($online.Count -eq $MINEROS.Count) { $colTot = "Green" }
    Write-Host ("   {0,8:N2} TH/s      {1,6} W      {2}/{3} maquinas      {4} placas" -f $totTh, $totW, $online.Count, $MINEROS.Count, $totOk) -ForegroundColor $colTot
    Write-Host ""
    Write-Host "   MINERO      TH/s       W    TEMP  PLACAS  VENTILADORES         ENC" -ForegroundColor DarkGray
    Write-Host "   --------------------------------------------------------------------" -ForegroundColor DarkGray

    foreach ($l in $lect) {
        if (-not $l.online) {
            Write-Host ("   {0,-9}   sin respuesta" -f $l.nombre) -ForegroundColor Red
            continue
        }
        $col = "Green"
        if ($l.placasOk -lt 3) { $col = "Yellow" }
        if ($l.tempMax -ge $TEMP_CRIT) { $col = "Red" }

        $vent = "-"
        $marca = ""
        if ($l.ventiladores.Count -gt 0) {
            $vent = ($l.ventiladores -join " / ")
            $mn = ($l.ventiladores | Measure-Object -Minimum).Minimum
            $mx = ($l.ventiladores | Measure-Object -Maximum).Maximum
            if ($l.ventiladores.Count -gt 1 -and $mx -gt 0 -and ($mn / $mx) -lt $DESEQ) {
                $marca = "  <- desequilibrio"
                if ($col -eq "Green") { $col = "Yellow" }
            }
            if ($mn -lt $VENT_BAJO) { $col = "Red" }
        }

        Write-Host ("   {0,-9} {1,6:N2} {2,7} {3,6:N1}   {4}/3   {5,-18} {6,6}{7}" -f $l.nombre, $l.hashrate, $l.vatios, $l.tempMax, $l.placasOk, $vent, (Duracion $l.uptime), $marca) -ForegroundColor $col
    }

    Write-Host ""
    Write-Host "   SUCESOS" -ForegroundColor DarkGray
    Write-Host "   --------------------------------------------------------------------" -ForegroundColor DarkGray
    if ($sucesos.Count -eq 0) {
        Write-Host "   Sin novedad." -ForegroundColor DarkGray
    } else {
        foreach ($s in $sucesos) {
            Write-Host ("   {0}  {1}" -f $s.hora, $s.texto) -ForegroundColor $s.color
        }
    }
    Write-Host ""
    Write-Host ("   Refrescando cada {0}s.  Ctrl+C para salir." -f $Segundos) -ForegroundColor DarkGray

    Start-Sleep -Seconds $Segundos
}
