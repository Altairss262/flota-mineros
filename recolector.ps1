<#
    recolector.ps1
    Lee los mineros, genera datos.json para el dashboard, evalua alertas
    y sube todo a GitHub.

    Uso:
        .\recolector.ps1              -> normal (lee, avisa, sube)
        .\recolector.ps1 -SinSubir    -> no sube a GitHub
        .\recolector.ps1 -SinAvisos   -> no manda correos
        .\recolector.ps1 -Ver         -> muestra el resumen por pantalla

    Configuracion de avisos: alertas.config.json
#>
param(
    [switch]$SinSubir,
    [switch]$SinAvisos,
    [switch]$Ver
)

$ErrorActionPreference = "Continue"
$RAIZ = Split-Path -Parent $MyInvocation.MyCommand.Path

# ============================================================
#  MINEROS
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

$MAX_HISTORIAL = 720   # puntos guardados (a 2 min = 24 horas)

# ============================================================
#  LECTURA
# ============================================================

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
        return (($raw -replace "`0", "").Trim() | ConvertFrom-Json)
    } catch { return $null }
}

function Leer-Minero {
    param($M)

    $r = [ordered]@{
        nombre = $M.Nombre; host = $M.Host; ip = $M.IP
        online = $false; hashrate = 0.0; vatios = 0; limite = 0
        uptimeSeg = 0; aceptadas = 0; rechazadas = 0
        placasOk = 0; placasVistas = 0; tempMax = 0.0
        ventiladores = @(); ventPct = 0
        estado = "apagado"; avisos = @(); placas = @()
    }

    $sum = Invoke-MinerApi $M.IP "summary"
    if ($null -eq $sum) { return $r }

    $r.online     = $true
    $r.hashrate   = [math]::Round($sum.SUMMARY[0].'MHS 5m' / 1000000, 2)
    $r.uptimeSeg  = [int]$sum.SUMMARY[0].Elapsed
    $r.aceptadas  = [int]$sum.SUMMARY[0].Accepted
    $r.rechazadas = [int]$sum.SUMMARY[0].Rejected

    $devs  = Invoke-MinerApi $M.IP "devs"
    $dd    = Invoke-MinerApi $M.IP "devdetails"
    $tun   = Invoke-MinerApi $M.IP "tunerstatus"
    $temps = Invoke-MinerApi $M.IP "temps"
    $fans  = Invoke-MinerApi $M.IP "fans"

    if ($tun) {
        $r.vatios = [int]$tun.TUNERSTATUS[0].ApproximateMinerPowerConsumption
        $r.limite = [int]$tun.TUNERSTATUS[0].PowerLimit
    }
    if ($fans) {
        $r.ventiladores = @($fans.FANS | Where-Object { $_.RPM -gt 0 } | ForEach-Object { [int]$_.RPM })
        if ($fans.FANS.Count -gt 0) { $r.ventPct = [int](($fans.FANS | Measure-Object Speed -Maximum).Maximum) }
    }

    foreach ($idx in 6, 7, 8) {
        $d  = $null; if ($devs)  { $d  = $devs.DEVS       | Where-Object { $_.ID -eq $idx } | Select-Object -First 1 }
        $ch = $null; if ($dd)    { $ch = $dd.DEVDETAILS   | Where-Object { $_.ID -eq $idx } | Select-Object -First 1 }
        $tp = $null; if ($temps) { $tp = $temps.TEMPS     | Where-Object { $_.ID -eq $idx } | Select-Object -First 1 }
        $tc = $null; if ($tun)   { $tc = $tun.TUNERSTATUS[0].TunerChainStatus | Where-Object { $_.HashchainIndex -eq $idx } | Select-Object -First 1 }

        $p = [ordered]@{ id = $idx; estado = "ausente"; chips = 0; hashrate = 0.0; vatios = 0; temp = 0.0 }

        if ($null -ne $d) {
            $r.placasVistas++
            $p.hashrate = [math]::Round($d.'MHS 5m' / 1000000, 2)
            if ($ch) { $p.chips  = [int]$ch.Chips }
            if ($tc) { $p.vatios = [int]$tc.ApproximatePowerConsumptionWatt }
            if ($tp) { $p.temp   = [math]::Round([double]$tp.Chip, 1) }

            if ($p.hashrate -gt 0.05) {
                $p.estado = "minando"; $r.placasOk++
                if ($p.temp -gt $r.tempMax) { $r.tempMax = $p.temp }
            }
            elseif ($p.vatios -gt 0) { $p.estado = "sin_producir" }
            else { $p.estado = "sin_corriente" }
        }
        $r.placas += $p
    }

    if     ($r.placasOk -eq 3) { $r.estado = "ok" }
    elseif ($r.placasOk -eq 0) { $r.estado = "critico" }
    else                       { $r.estado = "parcial" }

    return $r
}

Write-Host "Leyendo mineros..." -ForegroundColor Cyan
$lecturas = @()
foreach ($m in $MINEROS) { $lecturas += Leer-Minero $m }

$online  = @($lecturas | Where-Object { $_.online })
$totalTh = [math]::Round((($online | Measure-Object hashrate -Sum).Sum), 2)
$totalW  = [int](($online | Measure-Object vatios -Sum).Sum)
$totalOk = [int](($online | Measure-Object placasOk -Sum).Sum)
$jth = 0; if ($totalTh -gt 0) { $jth = [math]::Round($totalW / $totalTh, 1) }
$ahora = Get-Date
$unix  = [int][double]::Parse((Get-Date -Date $ahora.ToUniversalTime() -UFormat %s))

# ============================================================
#  HISTORIAL
# ============================================================

$fHist = Join-Path $RAIZ "historial.json"
$historial = @()
if (Test-Path $fHist) {
    try { $historial = @(Get-Content $fHist -Raw -Encoding utf8 | ConvertFrom-Json) } catch { $historial = @() }
}
$historial += [ordered]@{ t = $unix; th = $totalTh; w = $totalW; m = $online.Count }
if ($historial.Count -gt $MAX_HISTORIAL) {
    $historial = @($historial | Select-Object -Last $MAX_HISTORIAL)
}
($historial | ConvertTo-Json -Depth 4 -Compress) | Out-File $fHist -Encoding utf8

# ============================================================
#  ALERTAS
# ============================================================

# El selector de avisos se puede editar desde GitHub (movil, otro PC, lo que sea).
# Antes de leerlo, miramos si hay una version mas nueva en el repositorio.
$fCfg = Join-Path $RAIZ "alertas.config.json"
$cfg = $null
$origenCfg = "local"

if (Test-Path (Join-Path $RAIZ ".git")) {
    Push-Location $RAIZ
    try {
        git fetch origin main --quiet 2>&1 | Out-Null
        $remoto = git show origin/main:alertas.config.json 2>$null
        if (-not [string]::IsNullOrWhiteSpace($remoto)) {
            $prueba = $null
            try { $prueba = $remoto | ConvertFrom-Json } catch { }
            if ($prueba -and $prueba.avisos) {
                $cfg = $prueba
                $origenCfg = "GitHub"
                # guardamos una copia local para que coincidan
                $remoto | Out-File $fCfg -Encoding utf8
            }
        }
    } catch { } finally { Pop-Location }
}

if ($null -eq $cfg -and (Test-Path $fCfg)) {
    try { $cfg = Get-Content $fCfg -Raw -Encoding utf8 | ConvertFrom-Json } catch { }
}

# Credenciales del correo: fichero aparte, fuera de git
$correo = $null
$fCorreo = Join-Path $RAIZ "correo.local.json"
if (Test-Path $fCorreo) { try { $correo = Get-Content $fCorreo -Raw -Encoding utf8 | ConvertFrom-Json } catch { } }

$fEstado = Join-Path $RAIZ ".estado-anterior.json"
$anterior = $null
if (Test-Path $fEstado) { try { $anterior = Get-Content $fEstado -Raw -Encoding utf8 | ConvertFrom-Json } catch { } }

$alertas = @()

function Add-Alerta {
    param([string]$Nivel, [string]$Minero, [string]$Texto)
    $script:alertas += [ordered]@{ nivel = $Nivel; minero = $Minero; texto = $Texto }
}

if ($cfg) {
    $av = $cfg.avisos
    foreach ($l in $lecturas) {
        $ant = $null
        if ($anterior) { $ant = $anterior.mineros | Where-Object { $_.nombre -eq $l.nombre } | Select-Object -First 1 }

        # --- minero caido ---
        if ($av.minero_caido.activado -and $ant -and $ant.online -and -not $l.online) {
            Add-Alerta "critico" $l.nombre "El minero ha dejado de responder."
        }

        if (-not $l.online) { continue }

        # --- placa perdida ---
        if ($av.placa_perdida.activado -and $ant -and $ant.online) {
            foreach ($p in $l.placas) {
                $pa = $ant.placas | Where-Object { $_.id -eq $p.id } | Select-Object -First 1
                if ($pa -and $pa.estado -eq "minando" -and $p.estado -ne "minando") {
                    Add-Alerta "critico" $l.nombre "La placa $($p.id) ha dejado de minar (antes daba $($pa.hashrate) TH/s)."
                }
                if ($av.recuperado.activado -and $pa -and $pa.estado -ne "minando" -and $p.estado -eq "minando") {
                    Add-Alerta "bueno" $l.nombre "La placa $($p.id) vuelve a minar ($($p.hashrate) TH/s)."
                }
            }
        }

        # --- temperatura ---
        if ($av.temperatura_alta.activado) {
            $lim = [double]$av.temperatura_alta.grados
            foreach ($p in $l.placas) {
                if ($p.temp -ge $lim) {
                    Add-Alerta "aviso" $l.nombre "Placa $($p.id) a $($p.temp) grados (limite $lim)."
                }
            }
        }

        # --- ventiladores ---
        if ($av.ventilador_parado.activado -and $l.ventiladores.Count -gt 0) {
            if ($l.ventiladores.Count -lt 2) {
                Add-Alerta "aviso" $l.nombre "Solo $($l.ventiladores.Count) ventilador girando."
            } elseif ($l.ventiladores.Count -ge 2) {
                $mn = ($l.ventiladores | Measure-Object -Minimum).Minimum
                $mx = ($l.ventiladores | Measure-Object -Maximum).Maximum
                if ($mx -gt 0 -and ($mn / $mx) -lt 0.5) {
                    Add-Alerta "aviso" $l.nombre "Un ventilador rinde muy poco: $mn rpm contra $mx rpm."
                }
            }
        }

        # --- caida de hashrate ---
        if ($av.caida_de_hashrate.activado -and $ant -and $ant.online -and $ant.hashrate -gt 1) {
            $caida = (1 - ($l.hashrate / $ant.hashrate)) * 100
            if ($caida -ge [double]$av.caida_de_hashrate.porcentaje) {
                Add-Alerta "aviso" $l.nombre ("Hashrate ha caido un {0}%: de {1} a {2} TH/s." -f [math]::Round($caida), $ant.hashrate, $l.hashrate)
            }
        }

        # --- chips incompletos ---
        if ($av.chips_incompletos.activado) {
            foreach ($p in $l.placas) {
                if ($p.estado -eq "minando" -and $p.chips -gt 0 -and $p.chips -lt 63) {
                    Add-Alerta "aviso" $l.nombre "Placa $($p.id) mina con solo $($p.chips) chips de 63."
                }
            }
        }
    }
}

# ============================================================
#  ENVIO DE CORREO
# ============================================================

function Enviar-Correo {
    param($Cfg, $Alertas)
    if ($null -eq $Cfg) { return "sin fichero de correo" }
    if (-not $Cfg.activado) { return "desactivado" }
    if ([string]::IsNullOrWhiteSpace($Cfg.remitente) -or
        [string]::IsNullOrWhiteSpace($Cfg.clave_de_aplicacion)) { return "sin configurar" }

    # anti-spam
    $fUlt = Join-Path $RAIZ ".ultimo-correo.txt"
    if (Test-Path $fUlt) {
        try {
            $ult = [datetime]::Parse((Get-Content $fUlt -Raw).Trim())
            $mins = [int]$Cfg.minutos_entre_correos
            if ((Get-Date) -lt $ult.AddMinutes($mins)) { return "en espera" }
        } catch { }
    }

    $criticas = @($Alertas | Where-Object { $_.nivel -eq "critico" })
    $asunto = if ($criticas.Count -gt 0) { "[MINEROS] $($criticas.Count) problema(s)" } else { "[MINEROS] Aviso" }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("<html><body style='font-family:system-ui,sans-serif;color:#0b0b0b'>")
    [void]$sb.AppendLine("<h2>Estado de la flota</h2>")
    [void]$sb.AppendLine("<p><b>$totalTh TH/s</b> &middot; $totalW W &middot; $($online.Count)/$($MINEROS.Count) mineros &middot; $totalOk placas</p>")
    [void]$sb.AppendLine("<h3>Lo que ha pasado</h3><ul>")
    foreach ($a in $Alertas) {
        $col = switch ($a.nivel) { "critico" { "#d03b3b" } "aviso" { "#b8860b" } default { "#0ca30c" } }
        [void]$sb.AppendLine("<li style='color:$col'><b>$($a.minero)</b>: $($a.texto)</li>")
    }
    [void]$sb.AppendLine("</ul>")
    [void]$sb.AppendLine("<p style='color:#666;font-size:13px'>$(Get-Date -Format 'dd/MM/yyyy HH:mm')</p>")
    [void]$sb.AppendLine("</body></html>")

    try {
        $msg = New-Object System.Net.Mail.MailMessage
        $msg.From = New-Object System.Net.Mail.MailAddress($Cfg.remitente, "Monitor de mineros")
        $msg.To.Add($Cfg.para)
        $msg.Subject = $asunto
        $msg.Body = $sb.ToString()
        $msg.IsBodyHtml = $true

        $smtp = New-Object System.Net.Mail.SmtpClient($Cfg.servidor, [int]$Cfg.puerto)
        $smtp.EnableSsl = $true
        $smtp.Credentials = New-Object System.Net.NetworkCredential($Cfg.remitente, $Cfg.clave_de_aplicacion)
        $smtp.Send($msg)
        $msg.Dispose()

        (Get-Date).ToString("o") | Out-File $fUlt -Encoding utf8
        return "enviado"
    } catch {
        return "error: $($_.Exception.Message)"
    }
}

$estadoCorreo = "sin alertas"
if ($alertas.Count -gt 0 -and $cfg -and -not $SinAvisos) {
    $estadoCorreo = Enviar-Correo $correo $alertas
}

# ============================================================
#  datos.json
# ============================================================

$datos = [ordered]@{
    actualizado     = $ahora.ToString("yyyy-MM-ddTHH:mm:ssK")
    actualizadoUnix = $unix
    total = [ordered]@{
        hashrate      = $totalTh
        vatios        = $totalW
        kw            = [math]::Round($totalW / 1000, 2)
        minerosOnline = $online.Count
        minerosTotal  = $MINEROS.Count
        placasOk      = $totalOk
        placasTotal   = $MINEROS.Count * 3
        jth           = $jth
    }
    mineros   = $lecturas
    alertas   = $alertas
    historial = $historial
    selector  = $null
}

# El selector de avisos, para mostrarlo en el dashboard
if ($cfg -and $cfg.avisos) {
    $sel = @()
    $nombres = [ordered]@{
        minero_caido      = "Minero deja de responder"
        placa_perdida     = "Una placa deja de minar"
        temperatura_alta  = "Temperatura alta"
        ventilador_parado = "Ventilador parado o flojo"
        caida_de_hashrate = "Caida de hashrate"
        chips_incompletos = "Placa con menos de 63 chips"
        recuperado        = "Avisar de recuperaciones"
    }
    foreach ($k in $nombres.Keys) {
        $a = $cfg.avisos.$k
        if ($null -eq $a) { continue }
        $detalle = ""
        if ($null -ne $a.grados)     { $detalle = "por encima de $($a.grados) grados" }
        if ($null -ne $a.porcentaje) { $detalle = "caida de mas del $($a.porcentaje)%" }
        $sel += [ordered]@{
            clave    = $k
            nombre   = $nombres[$k]
            activado = [bool]$a.activado
            detalle  = $detalle
        }
    }
    $datos.selector = $sel
}

$fDatos = Join-Path $RAIZ "datos.json"
($datos | ConvertTo-Json -Depth 8) | Out-File $fDatos -Encoding utf8

# guardar estado para la proxima comparacion (fuera de git)
([ordered]@{ mineros = $lecturas } | ConvertTo-Json -Depth 8 -Compress) | Out-File $fEstado -Encoding utf8

Write-Host ("  {0} TH/s   {1} W   {2}/{3} mineros   {4} placas   {5} alertas   correo: {6}" -f `
    $totalTh, $totalW, $online.Count, $MINEROS.Count, $totalOk, $alertas.Count, $estadoCorreo) -ForegroundColor Cyan
Write-Host ("  selector de avisos: leido de {0}" -f $origenCfg) -ForegroundColor DarkGray

if ($Ver) {
    foreach ($l in $lecturas) {
        $ic = switch ($l.estado) { "ok" { "[OK]" } "parcial" { "[!!]" } "critico" { "[XX]" } default { "[--]" } }
        Write-Host ("   {0} {1,-8} {2,6} TH/s  {3}/3 placas  {4,4} W" -f $ic, $l.nombre, $l.hashrate, $l.placasOk, $l.vatios)
    }
    foreach ($a in $alertas) { Write-Host ("   ! {0}: {1}" -f $a.minero, $a.texto) -ForegroundColor Yellow }
}

# ============================================================
#  SUBIR
# ============================================================

if ($SinSubir) { exit 0 }

Push-Location $RAIZ
try {
    if (-not (Test-Path (Join-Path $RAIZ ".git"))) { exit 0 }

    git add datos.json historial.json 2>&1 | Out-Null
    $cambios = git status --porcelain datos.json historial.json 2>&1
    if ([string]::IsNullOrWhiteSpace($cambios)) { exit 0 }

    # Para no llenar el historial de git de miles de commits, si el ultimo
    # commit ya era de datos lo reescribimos en vez de crear uno nuevo.
    $ultimo = git log -1 --pretty=%s 2>&1
    $msg = "Datos: {0} TH/s - {1}" -f $totalTh, $ahora.ToString("dd/MM HH:mm")

    if ($ultimo -like "Datos:*") {
        git commit --amend -m $msg 2>&1 | Out-Null
        $push = git push --force-with-lease 2>&1
    } else {
        git commit -m $msg 2>&1 | Out-Null
        $push = git push 2>&1
    }

    if ($LASTEXITCODE -eq 0) { Write-Host "  Subido." -ForegroundColor Green }
    else { Write-Host "  No se pudo subir: $push" -ForegroundColor DarkGray }
} finally { Pop-Location }
