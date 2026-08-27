<#
    configurar-github.ps1
    Prepara esta carpeta para subir el informe a un repositorio PRIVADO de GitHub.

    Uso:
        .\configurar-github.ps1 -Usuario TU_USUARIO_GITHUB -Repo flota-mineros
#>
param(
    [Parameter(Mandatory = $true)][string]$Usuario,
    [string]$Repo = "flota-mineros"
)

$ErrorActionPreference = "Stop"
$RAIZ = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $RAIZ

Write-Host ""
Write-Host "  CONFIGURANDO EL REPOSITORIO" -ForegroundColor Cyan
Write-Host "  carpeta: $RAIZ" -ForegroundColor DarkGray
Write-Host ""

# --- .gitignore: nada de contraseñas ni basura ---
$gitignore = @"
# Nunca subir credenciales
*.password
*.secret
credenciales*
config-local*

# Ficheros temporales
*.tmp
*.bak
Thumbs.db
desktop.ini
"@
$gitignore | Out-File -FilePath (Join-Path $RAIZ ".gitignore") -Encoding utf8
Write-Host "  [ok] .gitignore creado" -ForegroundColor Green

# --- git init ---
if (-not (Test-Path (Join-Path $RAIZ ".git"))) {
    git init 2>&1 | Out-Null
    git branch -M main 2>&1 | Out-Null
    Write-Host "  [ok] repositorio git iniciado" -ForegroundColor Green
} else {
    Write-Host "  [--] ya era un repositorio git" -ForegroundColor DarkGray
}

# --- primer informe para que no este vacio ---
if (-not (Test-Path (Join-Path $RAIZ "README.md"))) {
    Write-Host "  [..] generando el primer informe..." -ForegroundColor DarkGray
    & (Join-Path $RAIZ "monitor-flota.ps1") -SinSubir | Out-Null
}

# --- remoto ---
$url = "https://github.com/$Usuario/$Repo.git"
$remotos = @(git remote 2>$null)
if ($remotos -contains "origin") {
    git remote set-url origin $url
    Write-Host "  [ok] remoto actualizado: $url" -ForegroundColor Green
} else {
    git remote add origin $url
    Write-Host "  [ok] remoto anadido: $url" -ForegroundColor Green
}

git add . 2>&1 | Out-Null
$hayCambios = git status --porcelain 2>&1
if (-not [string]::IsNullOrWhiteSpace($hayCambios)) {
    git commit -m "Monitor de la flota de mineros" 2>&1 | Out-Null
    Write-Host "  [ok] primer commit hecho" -ForegroundColor Green
}

Write-Host ""
Write-Host "  ---------------------------------------------------------" -ForegroundColor Yellow
Write-Host "   AHORA HAZ ESTO, EN ESTE ORDEN:" -ForegroundColor Yellow
Write-Host "  ---------------------------------------------------------" -ForegroundColor Yellow
Write-Host ""
Write-Host "   1. Abre:  https://github.com/new" -ForegroundColor White
Write-Host ""
Write-Host "   2. Rellena:" -ForegroundColor White
Write-Host "        Repository name .... $Repo"
Write-Host "        Visibilidad ........ PRIVATE   <-- importante" -ForegroundColor Yellow
Write-Host "        NO marques 'Add a README file'"
Write-Host ""
Write-Host "   3. Pulsa 'Create repository'" -ForegroundColor White
Write-Host ""
Write-Host "   4. Vuelve aqui y ejecuta:" -ForegroundColor White
Write-Host "        git push -u origin main" -ForegroundColor Cyan
Write-Host ""
Write-Host "      Te pedira usuario y contrasena de GitHub." -ForegroundColor DarkGray
Write-Host "      Como contrasena NO vale la del login: necesitas un token." -ForegroundColor DarkGray
Write-Host "      Sacalo en:  https://github.com/settings/tokens" -ForegroundColor DarkGray
Write-Host "      -> Generate new token (classic) -> marca solo 'repo'" -ForegroundColor DarkGray
Write-Host ""
Write-Host "   5. A partir de ahi, para actualizar el informe:" -ForegroundColor White
Write-Host "        .\monitor-flota.ps1" -ForegroundColor Cyan
Write-Host ""
Write-Host "   Tu pagina quedara en:" -ForegroundColor White
Write-Host "     https://github.com/$Usuario/$Repo" -ForegroundColor Green
Write-Host ""
