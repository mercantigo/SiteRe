[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Mensagem = "",

    [string]$RemoteUrl = "https://github.com/mercantigo/sitere.git",

    [string]$Branch = "main",

    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = (Resolve-Path -LiteralPath (Join-Path $ToolsDir "..")).Path
$PublishDir = Join-Path $ProjectRoot ".publish-cache"

$ExcludedDirs = @(
    ".git",
    ".publish-cache",
    "temporary screenshots",
    "node_modules",
    ".vercel",
    ".claude"
)

$ExcludedFiles = @(
    ".env",
    ".env.*",
    "*.log",
    ".DS_Store",
    "Thumbs.db"
)

function Write-Step {
    param([string]$Text)
    Write-Host ""
    Write-Host "==> $Text" -ForegroundColor Cyan
}

function Write-Ok {
    param([string]$Text)
    Write-Host "OK  $Text" -ForegroundColor Green
}

function Assert-Command {
    param([string]$Name)

    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Comando '$Name' nao encontrado. Instale-o e tente novamente."
    }
}

function Assert-PathInside {
    param(
        [string]$Child,
        [string]$Parent
    )

    $childFull = [System.IO.Path]::GetFullPath($Child)
    $parentFull = [System.IO.Path]::GetFullPath($Parent)

    if (-not $parentFull.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
        $parentFull += [System.IO.Path]::DirectorySeparatorChar
    }

    if (-not $childFull.StartsWith($parentFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Caminho inseguro para publicacao: $childFull"
    }
}

function Invoke-Checked {
    param(
        [string]$File,
        [string[]]$Arguments,
        [string]$WorkingDirectory,
        [int[]]$AllowedExitCodes = @(0)
    )

    $effectiveArguments = $Arguments
    if ($File -ieq "git") {
        $effectiveArguments = @(
            "-c", "safe.directory=$PublishDir",
            "-c", "core.excludesFile="
        ) + $Arguments
    }

    Push-Location -LiteralPath $WorkingDirectory
    try {
        & $File @effectiveArguments
        $exitCode = $LASTEXITCODE
    }
    finally {
        Pop-Location
    }

    if ($AllowedExitCodes -notcontains $exitCode) {
        throw "Comando falhou ($exitCode): $File $($effectiveArguments -join ' ')"
    }
}

function Test-Checked {
    param(
        [string]$File,
        [string[]]$Arguments,
        [string]$WorkingDirectory
    )

    $effectiveArguments = $Arguments
    if ($File -ieq "git") {
        $effectiveArguments = @(
            "-c", "safe.directory=$PublishDir",
            "-c", "core.excludesFile="
        ) + $Arguments
    }

    Push-Location -LiteralPath $WorkingDirectory
    try {
        & $File @effectiveArguments *> $null
        return ($LASTEXITCODE -eq 0)
    }
    finally {
        Pop-Location
    }
}

try {
    Assert-Command "git"
    Assert-Command "robocopy"
    Assert-PathInside -Child $PublishDir -Parent $ProjectRoot

    if ([string]::IsNullOrWhiteSpace($Branch)) {
        throw "Informe um branch valido."
    }

    if ($DryRun) {
        Write-Step "Simulacao de publicacao"
        Write-Host "Pasta do site: $ProjectRoot"
        Write-Host "Repositorio: $RemoteUrl"
        Write-Host "Branch: $Branch"
        Write-Host "Cache local: $PublishDir"
        Write-Host "Pastas ignoradas: $($ExcludedDirs -join ', ')"
        Write-Host "Arquivos ignorados: $($ExcludedFiles -join ', ')"
        Write-Ok "Nada foi enviado."
        exit 0
    }

    Write-Step "Preparando cache local do GitHub"
    $publishGitDir = Join-Path $PublishDir ".git"

    if (-not (Test-Path -LiteralPath $publishGitDir)) {
        if (Test-Path -LiteralPath $PublishDir) {
            $existingItems = @(Get-ChildItem -LiteralPath $PublishDir -Force)
            if ($existingItems.Count -gt 0) {
                throw "A pasta .publish-cache existe, mas nao e um clone Git. Renomeie ou remova essa pasta e tente de novo."
            }
        }

        Invoke-Checked -File "git" -Arguments @("clone", $RemoteUrl, $PublishDir) -WorkingDirectory $ProjectRoot
    }
    else {
        Write-Ok "Cache ja existe."
    }

    Write-Step "Atualizando branch $Branch"
    Invoke-Checked -File "git" -Arguments @("remote", "set-url", "origin", $RemoteUrl) -WorkingDirectory $PublishDir
    Invoke-Checked -File "git" -Arguments @("fetch", "origin", "--prune") -WorkingDirectory $PublishDir

    $hasLocalBranch = Test-Checked -File "git" -Arguments @("show-ref", "--verify", "--quiet", "refs/heads/$Branch") -WorkingDirectory $PublishDir
    $hasRemoteBranch = Test-Checked -File "git" -Arguments @("show-ref", "--verify", "--quiet", "refs/remotes/origin/$Branch") -WorkingDirectory $PublishDir

    if ($hasLocalBranch) {
        Invoke-Checked -File "git" -Arguments @("switch", $Branch) -WorkingDirectory $PublishDir
    }
    elseif ($hasRemoteBranch) {
        Invoke-Checked -File "git" -Arguments @("switch", "--track", "-c", $Branch, "origin/$Branch") -WorkingDirectory $PublishDir
    }
    else {
        Invoke-Checked -File "git" -Arguments @("switch", "-c", $Branch) -WorkingDirectory $PublishDir
    }

    if ($hasRemoteBranch) {
        Invoke-Checked -File "git" -Arguments @("pull", "--ff-only", "origin", $Branch) -WorkingDirectory $PublishDir
    }

    Write-Step "Espelhando arquivos atuais do site"
    $robocopyArgs = @(
        $ProjectRoot,
        $PublishDir,
        "/MIR",
        "/FFT",
        "/R:2",
        "/W:2",
        "/XD"
    ) + $ExcludedDirs + @("/XF") + $ExcludedFiles

    Invoke-Checked -File "robocopy" -Arguments $robocopyArgs -WorkingDirectory $ProjectRoot -AllowedExitCodes @(0, 1, 2, 3, 4, 5, 6, 7)

    Write-Step "Criando commit"
    Invoke-Checked -File "git" -Arguments @("add", "-A") -WorkingDirectory $PublishDir

    $hasChanges = -not (Test-Checked -File "git" -Arguments @("diff", "--cached", "--quiet") -WorkingDirectory $PublishDir)
    if (-not $hasChanges) {
        Write-Ok "Nenhuma alteracao para publicar."
        exit 0
    }

    if ([string]::IsNullOrWhiteSpace($Mensagem)) {
        $Mensagem = "Atualiza site $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
    }

    Invoke-Checked -File "git" -Arguments @("commit", "-m", $Mensagem) -WorkingDirectory $PublishDir

    Write-Step "Enviando para o GitHub"
    Invoke-Checked -File "git" -Arguments @("push", "-u", "origin", $Branch) -WorkingDirectory $PublishDir

    Write-Ok "Publicado. A Vercel deve iniciar o deploy automaticamente."
}
catch {
    Write-Host ""
    Write-Host "ERRO: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Se o erro for de login, faca autenticao no GitHub pelo navegador/Git Credential Manager e rode de novo."
    exit 1
}
