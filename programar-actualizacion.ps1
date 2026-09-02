<#
    programar-actualizacion.ps1
    Hace que el informe se actualice solo cada X minutos, sin que tengas que hacer nada.

    Uso:
        .\programar-actualizacion.ps1                 -> cada 10 minutos
        .\programar-actualizacion.ps1 -Minutos 2      -> cada 2 minutos
        .\programar-actualizacion.ps1 -Estado         -> ver si esta viva y cuando corrio
        .\programar-actualizacion.ps1 -Quitar         -> desactiva la actualizacion automatica

    Pensado para un sitio con cortes de luz: la tarea se relanza sola al
    encender el PC, repite indefinidamente y reintenta si falla.
#>
param(
    [int]$Minutos = 10,
    [switch]$Quitar,
    [switch]$Estado
)

$ErrorActionPreference = "Stop"
$RAIZ = Split-Path -Parent $MyInvocation.MyCommand.Path
$SCRIPT = Join-Path $RAIZ "recolector.ps1"
$TAREA = "MonitorFlotaMineros"

# ------------------------------------------------------------
#  Ver estado
# ------------------------------------------------------------
if ($Estado) {
    $t = Get-ScheduledTask -TaskName $TAREA -ErrorAction SilentlyContinue
    Write-Host ""
    if ($null -eq $t) {
        Write-Host "  El monitor NO esta programado." -ForegroundColor Red
        Write-Host "  Actívalo con:  .\ENCENDER.bat" -ForegroundColor DarkGray
        Write-Host ""
        exit 1
    }
    $i = Get-ScheduledTaskInfo -TaskName $TAREA
    $col = if ($t.State -eq "Ready" -or $t.State -eq "Running") { "Green" } else { "Red" }
    Write-Host "  MONITOR: $($t.State)" -ForegroundColor $col
    Write-Host ""
    Write-Host "     Ultima ejecucion:  $($i.LastRunTime)"
    Write-Host "     Resultado:         $($i.LastTaskResult)  (0 = correcto)"
    Write-Host "     Proxima ejecucion: $($i.NextRunTime)"
    Write-Host "     Disparadores:      $($t.Triggers.Count)"

    $datos = Join-Path $RAIZ "datos.json"
    if (Test-Path $datos) {
        $edad = (New-TimeSpan -Start (Get-Item $datos).LastWriteTime -End (Get-Date)).TotalMinutes
        $c = if ($edad -lt 15) { "Green" } elseif ($edad -lt 60) { "Yellow" } else { "Red" }
        Write-Host ("     Datos de hace:     {0:N0} minutos" -f $edad) -ForegroundColor $c
    }
    Write-Host ""
    exit 0
}

# ------------------------------------------------------------
#  Quitar
# ------------------------------------------------------------
if ($Quitar) {
    try {
        Unregister-ScheduledTask -TaskName $TAREA -Confirm:$false
        Write-Host ""
        Write-Host "  Actualizacion automatica DESACTIVADA." -ForegroundColor Yellow
        Write-Host ""
    } catch {
        Write-Host ""
        Write-Host "  No habia ninguna tarea programada." -ForegroundColor DarkGray
        Write-Host ""
    }
    exit 0
}

if (-not (Test-Path $SCRIPT)) { throw "No encuentro recolector.ps1 en $RAIZ" }

# Si ya existe, la quitamos para volver a crearla limpia
try { Unregister-ScheduledTask -TaskName $TAREA -Confirm:$false -ErrorAction Stop } catch { }

$accion = New-ScheduledTaskAction `
    -Execute "powershell.exe" `
    -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$SCRIPT`"" `
    -WorkingDirectory $RAIZ

# --- Disparador 1: cada X minutos, para siempre ---
# Sin -RepetitionDuration la repeticion puede caducar sola. MaxValue = indefinida.
$intervalo = New-TimeSpan -Minutes $Minutos
# Sin -RepetitionDuration, el Programador de tareas lo toma como indefinido.
# Ponerle [TimeSpan]::MaxValue genera P99999999D y lo rechaza.
$dispTiempo = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
    -RepetitionInterval $intervalo

# --- Disparador 2: al iniciar sesion, para sobrevivir a los apagones ---
$dispArranque = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$dispArranque.Repetition = $dispTiempo.Repetition

$ajustes = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 10) `
    -MultipleInstances IgnoreNew `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 2)

try {
    Register-ScheduledTask `
        -TaskName $TAREA `
        -Action $accion `
        -Trigger @($dispTiempo, $dispArranque) `
        -Settings $ajustes `
        -Description "Lee el estado de los mineros y publica el informe en GitHub" `
        -User $env:USERNAME -ErrorAction Stop | Out-Null
} catch {
    Write-Host ""
    Write-Host "  NO SE PUDO PROGRAMAR LA TAREA" -ForegroundColor Red
    Write-Host "     $($_.Exception.Message)" -ForegroundColor DarkGray
    Write-Host ""
    exit 1
}

# Comprobar de verdad que quedo registrada
$ok = Get-ScheduledTask -TaskName $TAREA -ErrorAction SilentlyContinue
if ($null -eq $ok) {
    Write-Host ""
    Write-Host "  La tarea no aparece tras registrarla. Revisa permisos." -ForegroundColor Red
    Write-Host ""
    exit 1
}

Write-Host ""
Write-Host "  ACTUALIZACION AUTOMATICA ACTIVADA" -ForegroundColor Green
Write-Host ""
Write-Host "     Se ejecuta cada $Minutos minutos, indefinidamente" -ForegroundColor White
Write-Host "     Se relanza sola al encender el PC (sobrevive a los apagones)"
Write-Host "     Reintenta hasta 3 veces si falla"
Write-Host "     Funciona en segundo plano, sin ventanas"
Write-Host ""
Write-Host "  Para comprobar que sigue viva:" -ForegroundColor DarkGray
Write-Host "     .\programar-actualizacion.ps1 -Estado" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  Para desactivarla:" -ForegroundColor DarkGray
Write-Host "     .\programar-actualizacion.ps1 -Quitar" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  OJO: el PC tiene que estar encendido para que se actualice." -ForegroundColor Yellow
Write-Host "  Si esta apagado, veras la ultima lectura buena con su fecha." -ForegroundColor Yellow
Write-Host ""
