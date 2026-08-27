<#
    programar-actualizacion.ps1
    Hace que el informe se actualice solo cada X minutos, sin que tengas que hacer nada.

    Uso:
        .\programar-actualizacion.ps1                 -> cada 10 minutos
        .\programar-actualizacion.ps1 -Minutos 5      -> cada 5 minutos
        .\programar-actualizacion.ps1 -Quitar         -> desactiva la actualizacion automatica
#>
param(
    [int]$Minutos = 10,
    [switch]$Quitar
)

$ErrorActionPreference = "Stop"
$RAIZ = Split-Path -Parent $MyInvocation.MyCommand.Path
$SCRIPT = Join-Path $RAIZ "recolector.ps1"
$TAREA = "MonitorFlotaMineros"

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

$disparador = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
    -RepetitionInterval (New-TimeSpan -Minutes $Minutos)

$ajustes = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 5) `
    -MultipleInstances IgnoreNew

Register-ScheduledTask `
    -TaskName $TAREA `
    -Action $accion `
    -Trigger $disparador `
    -Settings $ajustes `
    -Description "Lee el estado de los mineros y publica el informe en GitHub" `
    -User $env:USERNAME | Out-Null

Write-Host ""
Write-Host "  ACTUALIZACION AUTOMATICA ACTIVADA" -ForegroundColor Green
Write-Host ""
Write-Host "     Se ejecuta cada $Minutos minutos" -ForegroundColor White
Write-Host "     Empieza dentro de 1 minuto"
Write-Host "     Funciona en segundo plano, sin ventanas"
Write-Host ""
Write-Host "  Para desactivarla:" -ForegroundColor DarkGray
Write-Host "     .\programar-actualizacion.ps1 -Quitar" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  Para verla en Windows:" -ForegroundColor DarkGray
Write-Host "     Programador de tareas -> $TAREA" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  OJO: el PC tiene que estar encendido para que se actualice." -ForegroundColor Yellow
Write-Host "  Si esta apagado, veras la ultima lectura buena con su fecha." -ForegroundColor Yellow
Write-Host ""
