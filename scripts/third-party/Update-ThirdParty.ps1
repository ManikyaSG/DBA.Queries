<#
.SYNOPSIS
    Refreshes the third-party toolkits in this folder from their official GitHub repositories
    (latest default branch). Run from any machine with internet access, then commit the changes.

.EXAMPLE
    .\Update-ThirdParty.ps1
    .\Update-ThirdParty.ps1 -Only psblitz
#>
[CmdletBinding()]
param(
    [ValidateSet('all', 'frk', 'whoisactive', 'psblitz', 'vladscripts', 'ola')]
    [string] $Only = 'all'
)
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$tools = @(
    @{ Key = 'frk';         Repo = 'BrentOzarULTD/SQL-Server-First-Responder-Kit'; Folder = 'brent-ozar-first-responder-kit'
       Keep = @('*.sql', 'LICENSE.md', 'README.md', 'Documentation') }
    @{ Key = 'whoisactive'; Repo = 'amachanic/sp_whoisactive';                     Folder = 'adam-machanic-sp_whoisactive'
       Keep = @('sp_WhoIsActive.sql', 'LICENSE', 'README.md') }
    @{ Key = 'psblitz';     Repo = 'VladDBA/PSBlitz';                              Folder = 'vlad-drumea-psblitz'
       Keep = @('*') ; Skip = @('Screenshots', '.git*') }
    @{ Key = 'vladscripts'; Repo = 'VladDBA/SQL-Server-Scripts';                   Folder = 'vlad-drumea-sql-server-scripts'
       Keep = @('*') ; Skip = @('.git*') }
    @{ Key = 'ola';         Repo = 'olahallengren/sql-server-maintenance-solution'; Folder = 'ola-hallengren-maintenance-solution'
       Keep = @('*') ; Skip = @('.git*') }
)

$work = Join-Path $env:TEMP ('dba_thirdparty_' + (Get-Date -Format 'yyyyMMddHHmmss'))
New-Item -ItemType Directory -Path $work | Out-Null
try {
    foreach ($t in $tools | Where-Object { $Only -eq 'all' -or $_.Key -eq $Only }) {
        Write-Host "Updating $($t.Folder) from $($t.Repo)..." -ForegroundColor Cyan
        $zip = Join-Path $work ($t.Key + '.zip')
        Invoke-WebRequest -Uri "https://api.github.com/repos/$($t.Repo)/zipball" -OutFile $zip -UseBasicParsing
        $ex = Join-Path $work $t.Key
        Expand-Archive -Path $zip -DestinationPath $ex -Force
        $src = Get-ChildItem -Path $ex -Directory | Select-Object -First 1

        $dest = Join-Path $PSScriptRoot $t.Folder
        if (Test-Path $dest) { Remove-Item -Path $dest -Recurse -Force }
        New-Item -ItemType Directory -Path $dest | Out-Null

        foreach ($pattern in $t.Keep) {
            Get-ChildItem -Path $src.FullName -Filter $pattern -Force |
                Where-Object { $name = $_.Name; -not ($t.Skip | Where-Object { $name -like $_ }) } |
                ForEach-Object { Copy-Item -Path $_.FullName -Destination $dest -Recurse -Force }
        }
        $sha = ($src.Name -split '-')[-1]
        Write-Host "  -> $dest  (commit $sha)" -ForegroundColor Green
        Write-Host "     Update the 'Version in repo' column in README.md: $sha ($(Get-Date -Format 'yyyy-MM-dd'))" -ForegroundColor DarkGray
    }
}
finally { Remove-Item -Path $work -Recurse -Force -ErrorAction SilentlyContinue }
Write-Host 'Done. Review with "git status" and commit.' -ForegroundColor Green
