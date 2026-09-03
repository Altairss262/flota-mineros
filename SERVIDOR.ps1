<#
    SERVIDOR.ps1
    Sirve el dashboard desde este PC con datos EN VIVO.

    GitHub Pages no puede ir continuo: cada actualizacion es un commit y su CDN
    cachea minutos. Este servidor no tiene ese limite: lee los mineros en el
    momento en que el navegador pide los datos, asi que el dashboard se refresca
    cada segundo en vez de cada dos minutos.

    Se abre en el PC y tambien desde el movil, por wifi.

    NO toca nada: no manda correos, no sube a GitHub, no escribe datos.json.
    Puede convivir con el recolector automatico y con VIGILAR.ps1.

    Uso:
        .\SERVIDOR.ps1              -> puerto 8080
        .\SERVIDOR.ps1 -Puerto 9000

    Para salir: Ctrl+C
#>
param(
    [int]$Puerto = 8080,
    [int]$CacheMs = 600
)

$ErrorActionPreference = "Continue"
$RAIZ = Split-Path -Parent $MyInvocation.MyCommand.Path

$MINEROS = @(
    @{ Nombre = "kiwi01"; Host = "Gabriel01"; IP = "192.168.0.137" }
    @{ Nombre = "kiwi02"; Host = "Gabriel02"; IP = "192.168.0.237" }
    @{ Nombre = "kiwi03"; Host = "Gabriel03"; IP = "192.168.0.176" }
    @{ Nombre = "Sara00"; Host = "Sara00";    IP = "192.168.0.145" }
    @{ Nombre = "Sara02"; Host = "Sara02";    IP = "192.168.0.200" }
    @{ Nombre = "Sara03"; Host = "Sara03";    IP = "192.168.0.195" }
    @{ Nombre = "Sara04"; Host = "Sara04";    IP = "192.168.0.235" }
)

$MAX_HISTORIAL = 720

# ------------------------------------------------------------
#  Lectura de una maquina (corre en su propio runspace)
# ------------------------------------------------------------
$sbLeer = {
    param($Nombre, $MHost, $IP)

    $r = [ordered]@{
        nombre = $Nombre; host = $MHost; ip = $IP; online = $false
        hashrate = 0.0; vatios = 0; limite = 0; uptimeSeg = 0
        aceptadas = 0; rechazadas = 0; placasOk = 0; placasVistas = 0
        tempMax = 0.0; ventiladores = @(); ventPct = 0
        estado = "apagado"; avisos = @(); placas = @()
    }
    try {
        $c = New-Object System.Net.Sockets.TcpClient
        $c.ReceiveTimeout = 1500; $c.SendTimeout = 1500
        $t = $c.ConnectAsync($IP, 4028)
        if (-not ($t.Wait(1200) -and $c.Connected)) { try { $c.Close() } catch {}; return $r }

        $s = $c.GetStream()
        $cmd = '{"command":"summary+fans+temps+tunerstatus+devs+devdetails"}'
        $b = [Text.Encoding]::ASCII.GetBytes($cmd)
        $s.Write($b, 0, $b.Length); $s.Flush()
        $sr = New-Object IO.StreamReader($s)
        $raw = $sr.ReadToEnd(); $c.Close()
        $d = ($raw.Replace([string][char]0, "").Trim() | ConvertFrom-Json)

        if (-not ($d.summary -and $d.summary.SUMMARY)) { return $r }

        $su = $d.summary.SUMMARY[0]
        $r.online     = $true
        $r.hashrate   = [math]::Round(($su.'MHS av' / 1000000), 2)
        $r.uptimeSeg  = [int]$su.Elapsed
        $r.aceptadas  = [int]$su.Accepted
        $r.rechazadas = [int]$su.Rejected

        if ($d.fans -and $d.fans.FANS) {
            $r.ventiladores = @($d.fans.FANS | Where-Object { $_.RPM -gt 0 } | ForEach-Object { [int]$_.RPM })
            $vel = @($d.fans.FANS | ForEach-Object { [int]$_.Speed })
            if ($vel.Count -gt 0) { $r.ventPct = ($vel | Measure-Object -Maximum).Maximum }
        }

        $temps = @{}
        if ($d.temps -and $d.temps.TEMPS) { foreach ($x in $d.temps.TEMPS) { $temps[[int]$x.ID] = $x } }
        $devs = @{}
        if ($d.devs -and $d.devs.DEVS) { foreach ($x in $d.devs.DEVS) { $devs[[int]$x.ID] = $x } }
        $dd = @{}
        if ($d.devdetails -and $d.devdetails.DEVDETAILS) { foreach ($x in $d.devdetails.DEVDETAILS) { $dd[[int]$x.ID] = $x } }
        $tc = @{}
        if ($d.tunerstatus -and $d.tunerstatus.TUNERSTATUS) {
            $r.vatios = [int]$d.tunerstatus.TUNERSTATUS[0].ApproximateMinerPowerConsumption
            $r.limite = [int]$d.tunerstatus.TUNERSTATUS[0].PowerLimit
            foreach ($x in $d.tunerstatus.TUNERSTATUS[0].TunerChainStatus) { $tc[[int]$x.HashchainIndex] = $x }
        }

        $placas = @()
        foreach ($idx in 6, 7, 8) {
            $p = [ordered]@{ id = $idx; estado = "ausente"; chips = 0; hashrate = 0.0; vatios = 0; temp = 0.0 }

            if ($dd.ContainsKey($idx) -and $dd[$idx].Chips) { $p.chips = [int]$dd[$idx].Chips }
            if ($devs.ContainsKey($idx)) { $p.hashrate = [math]::Round(($devs[$idx].'MHS av' / 1000000), 2) }
            if ($temps.ContainsKey($idx)) { $p.temp = [math]::Round([double]$temps[$idx].Chip, 1) }
            if ($tc.ContainsKey($idx)) { $p.vatios = [int]$tc[$idx].ApproximatePowerConsumptionWatt }

            if ($p.chips -gt 0 -and $p.hashrate -gt 0) {
                $p.estado = "minando"; $r.placasOk++; $r.placasVistas++
            } elseif ($p.vatios -gt 0) {
                $p.estado = "sin_producir"; $r.placasVistas++
            } elseif ($tc.ContainsKey($idx)) {
                $p.estado = "sin_corriente"
            }
            if ($p.temp -gt $r.tempMax) { $r.tempMax = $p.temp }
            $placas += $p
        }
        $r.placas = $placas

        if ($r.placasOk -eq 3) { $r.estado = "ok" }
        elseif ($r.placasOk -gt 0) { $r.estado = "parcial" }
        else { $r.estado = "parado" }

    } catch { }
    return $r
}

# ------------------------------------------------------------
#  Estado compartido
# ------------------------------------------------------------
$pool = [runspacefactory]::CreateRunspacePool(1, ($MINEROS.Count + 1))
$pool.Open()

$script:cacheJson = $null
$script:cacheHora = [DateTime]::MinValue
$script:historial = New-Object System.Collections.ArrayList
$script:ultimoHist = [DateTime]::MinValue
$script:peticiones = 0

function Leer-Flota {
    $trabajos = @()
    foreach ($m in $MINEROS) {
        $ps = [powershell]::Create()
        $ps.RunspacePool = $pool
        [void]$ps.AddScript($sbLeer).AddArgument($m.Nombre).AddArgument($m.Host).AddArgument($m.IP)
        $trabajos += [pscustomobject]@{ ps = $ps; handle = $ps.BeginInvoke(); nombre = $m.Nombre }
    }
    $lect = @()
    foreach ($t in $trabajos) {
        try { $lect += $t.ps.EndInvoke($t.handle) } catch { }
        $t.ps.Dispose()
    }
    # respetar el orden de la lista
    return @($MINEROS | ForEach-Object { $n = $_.Nombre; $lect | Where-Object { $_.nombre -eq $n } | Select-Object -First 1 })
}

function Construye-Datos {
    $lect = Leer-Flota
    $online = @($lect | Where-Object { $_.online })

    $totTh = 0.0; $totW = 0; $totOk = 0
    foreach ($o in $online) {
        $totTh += [double]$o.hashrate
        $totW  += [int]$o.vatios
        $totOk += [int]$o.placasOk
    }
    $totTh = [math]::Round($totTh, 2)
    $jth = 0.0
    if ($totTh -gt 0) { $jth = [math]::Round($totW / $totTh, 1) }

    $ahora = Get-Date
    $unix = [int][double]::Parse((Get-Date -Date $ahora.ToUniversalTime() -UFormat %s))

    # historial: un punto cada 10 segundos como mucho
    if (($ahora - $script:ultimoHist).TotalSeconds -ge 10) {
        [void]$script:historial.Add([ordered]@{ t = $unix; th = $totTh; w = $totW; m = $online.Count })
        while ($script:historial.Count -gt $MAX_HISTORIAL) { $script:historial.RemoveAt(0) }
        $script:ultimoHist = $ahora
    }

    # alertas en vivo
    $alertas = @()
    foreach ($l in $lect) {
        if (-not $l.online) { continue }
        foreach ($p in $l.placas) {
            if ($p.estado -eq "sin_corriente") {
                $alertas += [ordered]@{ nivel = "grave"; minero = $l.nombre; texto = "Placa $($p.id) sin corriente." }
            }
        }
        if ($l.tempMax -ge 95) {
            $alertas += [ordered]@{ nivel = "grave"; minero = $l.nombre; texto = "Temperatura de $($l.tempMax) grados." }
        }
        if ($l.ventiladores.Count -gt 1) {
            $mn = ($l.ventiladores | Measure-Object -Minimum).Minimum
            $mx = ($l.ventiladores | Measure-Object -Maximum).Maximum
            if ($mn -lt 2000) {
                $alertas += [ordered]@{ nivel = "grave"; minero = $l.nombre; texto = "Un ventilador a $mn rpm." }
            } elseif ($mx -gt 0 -and ($mn / $mx) -lt 0.6) {
                $pc = [int]((1 - $mn / $mx) * 100)
                $alertas += [ordered]@{ nivel = "aviso"; minero = $l.nombre; texto = "Ventiladores descompensados un $pc%: $mn contra $mx rpm." }
            }
        }
    }

    $d = [ordered]@{
        actualizado     = $ahora.ToString("yyyy-MM-ddTHH:mm:sszzz")
        actualizadoUnix = $unix
        enVivo          = $true
        total = [ordered]@{
            hashrate     = $totTh
            vatios       = $totW
            kw           = [math]::Round($totW / 1000, 2)
            minerosOnline = $online.Count
            minerosTotal  = $MINEROS.Count
            placasOk      = $totOk
            placasTotal   = ($MINEROS.Count * 3)
            jth           = $jth
        }
        mineros   = $lect
        alertas   = $alertas
        historial = @($script:historial)
        selector  = @()
    }
    return ($d | ConvertTo-Json -Depth 8 -Compress)
}

function Datos-Json {
    $ahora = Get-Date
    if ($null -eq $script:cacheJson -or ($ahora - $script:cacheHora).TotalMilliseconds -gt $CacheMs) {
        $script:cacheJson = Construye-Datos
        $script:cacheHora = $ahora
    }
    return $script:cacheJson
}

# ------------------------------------------------------------
#  Servidor
# ------------------------------------------------------------
$tipos = @{
    ".html" = "text/html; charset=utf-8"
    ".json" = "application/json; charset=utf-8"
    ".css"  = "text/css; charset=utf-8"
    ".js"   = "application/javascript; charset=utf-8"
    ".svg"  = "image/svg+xml"
    ".ico"  = "image/x-icon"
    ".png"  = "image/png"
}

$listener = $null
$abierto = $false
$prefijo = ""

# Escuchar en toda la red hace falta permisos de administrador. Si no los hay,
# se cae a localhost y el movil no podra entrar (se avisa por pantalla).
# Un HttpListener al que le falla Start() queda inservible: hace falta uno
# nuevo en cada intento.
foreach ($p in @("http://+:$Puerto/", "http://localhost:$Puerto/")) {
    try {
        $cand = New-Object System.Net.HttpListener
        $cand.Prefixes.Add($p)
        $cand.Start()
        $listener = $cand; $abierto = $true; $prefijo = $p
        break
    } catch {
        try { $cand.Close() } catch { }
    }
}
if (-not $abierto) {
    Write-Host ""
    Write-Host "  No pude abrir el puerto $Puerto." -ForegroundColor Red
    Write-Host "  Puede que ya este ocupado. Prueba con:  .\SERVIDOR.ps1 -Puerto 9000" -ForegroundColor DarkGray
    Write-Host ""
    exit 1
}

$ipLan = "127.0.0.1"
try {
    $cand = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
            Where-Object { $_.IPAddress -like "192.168.*" -or $_.IPAddress -like "10.*" } |
            Select-Object -First 1
    if ($cand) { $ipLan = $cand.IPAddress }
} catch { }

$enRed = $prefijo.StartsWith("http://+")

Clear-Host
Write-Host ""
Write-Host "  DASHBOARD EN VIVO" -ForegroundColor Green
Write-Host ""
Write-Host "     En este PC:   " -NoNewline; Write-Host ("http://localhost:{0}/" -f $Puerto) -ForegroundColor Cyan
if ($enRed) {
    Write-Host "     Desde movil:  " -NoNewline; Write-Host ("http://{0}:{1}/" -f $ipLan, $Puerto) -ForegroundColor Cyan
    Write-Host "                   (mismo wifi)" -ForegroundColor DarkGray
} else {
    Write-Host "     Desde movil:  no disponible" -ForegroundColor DarkYellow
    Write-Host "                   Para abrirlo a la red, cierra esto y arranca" -ForegroundColor DarkGray
    Write-Host "                   PowerShell como administrador." -ForegroundColor DarkGray
}
Write-Host ""
Write-Host ("     Los datos se releen como mucho cada {0} ms." -f $CacheMs) -ForegroundColor DarkGray
Write-Host "     El dashboard se refresca cada segundo al verlo desde aqui." -ForegroundColor DarkGray
Write-Host ""
Write-Host "  Ctrl+C para parar." -ForegroundColor DarkGray
Write-Host ""

try {
    while ($listener.IsListening) {
        $tarea = $listener.GetContextAsync()
        # Wait con tiempo para que Ctrl+C siga respondiendo
        while (-not $tarea.Wait(400)) { }
        $ctx = $tarea.Result

        $ruta = $ctx.Request.Url.AbsolutePath
        if ($ruta -eq "/") { $ruta = "/index.html" }
        $res = $ctx.Response
        $res.Headers.Add("Cache-Control", "no-store, no-cache, must-revalidate")

        try {
            if ($ruta -eq "/datos.json") {
                $script:peticiones++
                $cuerpo = [Text.Encoding]::UTF8.GetBytes((Datos-Json))
                $res.ContentType = $tipos[".json"]
                $res.OutputStream.Write($cuerpo, 0, $cuerpo.Length)

                $l = $script:cacheHora.ToString("HH:mm:ss")
                Write-Host ("   {0}  datos servidos  (peticion {1})" -f $l, $script:peticiones) -ForegroundColor DarkGray
            }
            else {
                $archivo = Join-Path $RAIZ ($ruta.TrimStart("/") -replace "/", "\")
                # no salir de la carpeta del proyecto
                $completo = [IO.Path]::GetFullPath($archivo)
                if (-not $completo.StartsWith([IO.Path]::GetFullPath($RAIZ))) {
                    $res.StatusCode = 403
                }
                elseif (Test-Path $completo -PathType Leaf) {
                    $ext = [IO.Path]::GetExtension($completo).ToLower()
                    $res.ContentType = if ($tipos.ContainsKey($ext)) { $tipos[$ext] } else { "application/octet-stream" }
                    $bytes = [IO.File]::ReadAllBytes($completo)
                    $res.OutputStream.Write($bytes, 0, $bytes.Length)
                }
                else {
                    $res.StatusCode = 404
                    $msg = [Text.Encoding]::UTF8.GetBytes("No encontrado: $ruta")
                    $res.OutputStream.Write($msg, 0, $msg.Length)
                }
            }
        } catch {
            try { $res.StatusCode = 500 } catch { }
        } finally {
            try { $res.OutputStream.Close() } catch { }
        }
    }
}
finally {
    try { $listener.Stop(); $listener.Close() } catch { }
    try { $pool.Close(); $pool.Dispose() } catch { }
    Write-Host ""
    Write-Host "  Servidor detenido." -ForegroundColor Yellow
    Write-Host ""
}
