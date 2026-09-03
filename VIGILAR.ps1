<#
    VIGILAR.ps1
    Vigilancia CONTINUA de la flota. Lee las siete maquinas en paralelo y
    redibuja varias veces por segundo, sin parpadeo.

    Como consigue ir continuo:
      - un solo comando por maquina (summary+fans+temps+tunerstatus) en una
        unica conexion TCP, en vez de cuatro conexiones seguidas
      - las siete maquinas se leen a la vez en runspaces, no una detras de otra
      - la pantalla se reescribe sobre si misma, sin Clear-Host

    NO toca nada: no manda correos, no sube a GitHub, no escribe datos.json.

    Uso:
        .\VIGILAR.ps1              -> refresco continuo (4 veces por segundo)
        .\VIGILAR.ps1 -Ms 1000     -> una vez por segundo
        .\VIGILAR.ps1 -Ms 0        -> tan rapido como responda la red

    Para salir: Ctrl+C
#>
param(
    [int]$Ms = 250
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
$DESEQ     = 0.6

# ------------------------------------------------------------
#  Lectura de una maquina (se ejecuta en su propio runspace)
# ------------------------------------------------------------
$sbLeer = {
    param($Nombre, $IP)

    $r = @{
        nombre = $Nombre; ip = $IP; online = $false
        hashrate = 0.0; vatios = 0; uptime = 0
        placasOk = 0; tempMax = 0.0; ventiladores = @(); ms = 0
    }
    $crono = [Diagnostics.Stopwatch]::StartNew()
    try {
        $c = New-Object System.Net.Sockets.TcpClient
        $c.ReceiveTimeout = 1500; $c.SendTimeout = 1500
        $t = $c.ConnectAsync($IP, 4028)
        if (-not ($t.Wait(1200) -and $c.Connected)) { try { $c.Close() } catch {}; $r.ms = $crono.ElapsedMilliseconds; return $r }

        $s = $c.GetStream()
        $b = [Text.Encoding]::ASCII.GetBytes('{"command":"summary+fans+temps+tunerstatus"}')
        $s.Write($b, 0, $b.Length); $s.Flush()
        $sr = New-Object IO.StreamReader($s)
        $raw = $sr.ReadToEnd(); $c.Close()
        $d = ($raw.Replace([string][char]0, "").Trim() | ConvertFrom-Json)

        if ($d.summary -and $d.summary.SUMMARY) {
            $r.online   = $true
            $r.hashrate = [math]::Round(($d.summary.SUMMARY[0].'MHS av' / 1000000), 2)
            $r.uptime   = [int]$d.summary.SUMMARY[0].Elapsed
        }
        if ($d.fans -and $d.fans.FANS) {
            $r.ventiladores = @($d.fans.FANS | Where-Object { $_.RPM -gt 0 } | ForEach-Object { [int]$_.RPM })
        }
        if ($d.temps -and $d.temps.TEMPS) {
            foreach ($x in $d.temps.TEMPS) {
                if ($x.Chip -gt $r.tempMax) { $r.tempMax = [math]::Round([double]$x.Chip, 1) }
            }
        }
        if ($d.tunerstatus -and $d.tunerstatus.TUNERSTATUS) {
            $r.vatios = [int]$d.tunerstatus.TUNERSTATUS[0].ApproximateMinerPowerConsumption
            foreach ($ch in $d.tunerstatus.TUNERSTATUS[0].TunerChainStatus) {
                if ($ch.ApproximatePowerConsumptionWatt -gt 0) { $r.placasOk++ }
            }
        }
    } catch { }
    $r.ms = $crono.ElapsedMilliseconds
    return $r
}

# ------------------------------------------------------------
#  Pintado sin parpadeo: se reescribe encima, no se borra
# ------------------------------------------------------------
$script:fila = 0
$script:consola = $true
try { $null = [Console]::CursorTop } catch { $script:consola = $false }

function Inicio-Cuadro {
    $script:fila = 0
    if ($script:consola) {
        try { [Console]::SetCursorPosition(0, 0) } catch { $script:consola = $false }
    }
}

function Linea {
    param([string]$Texto = "", [string]$Color = "Gray")
    $ancho = 100
    if ($script:consola) {
        try { $ancho = [Console]::WindowWidth - 1 } catch { }
    }
    if ($Texto.Length -gt $ancho) { $Texto = $Texto.Substring(0, $ancho) }
    Write-Host $Texto.PadRight($ancho) -ForegroundColor $Color
    $script:fila++
}

function Duracion {
    param([int]$Seg)
    if ($Seg -le 0) { return "-" }
    $h = [math]::Floor($Seg / 3600); $m = [math]::Floor(($Seg % 3600) / 60)
    if ($h -gt 0) { return ("{0}h{1:00}m" -f $h, $m) }
    return ("{0}m" -f $m)
}

# ------------------------------------------------------------
#  Registro de sucesos
# ------------------------------------------------------------
$sucesos = New-Object System.Collections.ArrayList
function Anota {
    param([string]$Texto, [string]$Color = "Gray")
    [void]$sucesos.Add(@{ hora = (Get-Date -Format "HH:mm:ss"); texto = $Texto; color = $Color })
    while ($sucesos.Count -gt 10) { $sucesos.RemoveAt(0) }
}

# ------------------------------------------------------------
#  Arranque
# ------------------------------------------------------------
$pool = [runspacefactory]::CreateRunspacePool(1, ($MINEROS.Count + 1))
$pool.Open()

$anterior  = @{}
$ciclo     = 0
$arranque  = Get-Date
$flotaCaida = $false
$hz        = 0.0
$msCiclo   = 0

try { [Console]::CursorVisible = $false } catch { }
try { Clear-Host } catch { }
Anota "Vigilancia continua iniciada. Ctrl+C para salir." "Cyan"

try {
    while ($true) {
        $crono = [Diagnostics.Stopwatch]::StartNew()
        $ciclo++

        # --- lanzar las siete lecturas a la vez ---
        $trabajos = @()
        foreach ($m in $MINEROS) {
            $ps = [powershell]::Create()
            $ps.RunspacePool = $pool
            [void]$ps.AddScript($sbLeer).AddArgument($m.Nombre).AddArgument($m.IP)
            $trabajos += [pscustomobject]@{ ps = $ps; handle = $ps.BeginInvoke(); nombre = $m.Nombre }
        }

        $lect = @()
        foreach ($t in $trabajos) {
            try { $lect += $t.ps.EndInvoke($t.handle) } catch { }
            $t.ps.Dispose()
        }
        # mantener el orden de la lista original
        $lect = @($MINEROS | ForEach-Object { $n = $_.Nombre; $lect | Where-Object { $_.nombre -eq $n } | Select-Object -First 1 })

        $online = @($lect | Where-Object { $_.online })
        $totTh = 0.0; $totW = 0; $totOk = 0
        foreach ($o in $online) {
            $totTh += [double]$o.hashrate
            $totW  += [int]$o.vatios
            $totOk += [int]$o.placasOk
        }
        $totTh = [math]::Round($totTh, 2)

        # ---------- cambios ----------
        if ($online.Count -eq 0 -and -not $flotaCaida) {
            Anota "APAGON: la flota entera dejo de responder." "Red"; $flotaCaida = $true
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
                    if ($l.uptime -lt $a.uptime) { Anota ("{0} SE REINICIO (llevaba {1})." -f $l.nombre, (Duracion $a.uptime)) "Red" }
                    if ($l.placasOk -lt $a.placasOk) { Anota ("{0} perdio una placa: {1} -> {2}." -f $l.nombre, $a.placasOk, $l.placasOk) "Red" }
                    if ($l.placasOk -gt $a.placasOk) { Anota ("{0} recupero una placa: {1} -> {2}." -f $l.nombre, $a.placasOk, $l.placasOk) "Green" }
                    if ($a.tempMax -lt $TEMP_CRIT -and $l.tempMax -ge $TEMP_CRIT) { Anota ("{0} a {1} grados." -f $l.nombre, $l.tempMax) "Red" }
                    if ($a.hashrate -gt 1 -and $l.hashrate -lt ($a.hashrate * 0.75)) { Anota ("{0} cayo de {1} a {2} TH/s." -f $l.nombre, $a.hashrate, $l.hashrate) "Yellow" }
                }
            }
            $anterior[$l.nombre] = $l
        }

        # ---------- pintar ----------
        Inicio-Cuadro
        Linea ""
        Linea ("  VIGILANCIA CONTINUA      {0}      ciclo {1}      {2:N1} lecturas/s      {3} ms/ciclo" -f `
            (Get-Date -Format "HH:mm:ss"), $ciclo, $hz, $msCiclo) "Cyan"
        Linea ""

        $colTot = "Yellow"
        if ($online.Count -eq $MINEROS.Count) { $colTot = "Green" }
        Linea ("   {0,8:N2} TH/s      {1,6} W      {2}/{3} maquinas      {4} placas      abierta desde {5}" -f `
            $totTh, $totW, $online.Count, $MINEROS.Count, $totOk, $arranque.ToString("HH:mm")) $colTot
        Linea ""
        Linea "   MINERO      TH/s       W    TEMP  PLACAS  VENTILADORES         ENC     MS" "DarkGray"
        Linea "   ----------------------------------------------------------------------------" "DarkGray"

        foreach ($l in $lect) {
            if (-not $l.online) {
                Linea ("   {0,-9}   sin respuesta" -f $l.nombre) "Red"
                continue
            }
            $col = "Green"
            if ($l.placasOk -lt 3) { $col = "Yellow" }
            if ($l.tempMax -ge $TEMP_CRIT) { $col = "Red" }

            $vent = "-"; $marca = ""
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
            Linea ("   {0,-9} {1,6:N2} {2,7} {3,6:N1}   {4}/3   {5,-18} {6,6} {7,5}{8}" -f `
                $l.nombre, $l.hashrate, $l.vatios, $l.tempMax, $l.placasOk, $vent, (Duracion $l.uptime), $l.ms, $marca) $col
        }

        Linea ""
        Linea "   SUCESOS" "DarkGray"
        Linea "   ----------------------------------------------------------------------------" "DarkGray"
        if ($sucesos.Count -eq 0) {
            Linea "   Sin novedad." "DarkGray"
        } else {
            foreach ($s in $sucesos) { Linea ("   {0}  {1}" -f $s.hora, $s.texto) $s.color }
        }
        for ($i = $sucesos.Count; $i -lt 10; $i++) { Linea "" }
        Linea ""
        Linea "   Ctrl+C para salir." "DarkGray"

        if ($Ms -gt 0) { Start-Sleep -Milliseconds $Ms }

        $crono.Stop()
        $msCiclo = [int]$crono.ElapsedMilliseconds
        if ($msCiclo -gt 0) { $hz = [math]::Round(1000 / $msCiclo, 1) }
    }
}
finally {
    try { [Console]::CursorVisible = $true } catch { }
    try { $pool.Close(); $pool.Dispose() } catch { }
    Write-Host ""
    Write-Host "  Vigilancia detenida." -ForegroundColor Yellow
    Write-Host ""
}
