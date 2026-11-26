<#
.SYNOPSIS
    Updates the tool in this folder (pre-post check or perf check collector) to a release
    from GitHub, keeping your settings, snapshots, reports and logs.

.DESCRIPTION
    Shipped in every release zip as Update-Tool.ps1. Run it in the tool's folder:
      1. Finds the release: the newest '<tool>/vX.Y.Z' tag, or -Version. With -ZipFile it uses
         a zip you downloaded yourself (no internet needed on the VM).
      2. First update to a version with settings.psd1: the values you changed in the old
         script's $Config block are written to settings.psd1 (anything that differs from the
         new version's defaults), so nothing you set is lost.
      3. The files it replaces are copied to _previous\<old version>_<time>\ first.
      4. Copies the new files. settings.psd1, db_mail_setup.sql, servers.txt, credential files
         and the Snapshots / Reports / Logs folders are never touched.

.EXAMPLE
    .\Update-Tool.ps1                      # newest release of the tool in this folder
.EXAMPLE
    .\Update-Tool.ps1 -Version 3.0.1
.EXAMPLE
    .\Update-Tool.ps1 -ZipFile C:\Temp\pre-post-check-3.0.1.zip   # offline
.EXAMPLE
    .\Update-Tool.ps1 -WhatIf              # show what would change, change nothing
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $Version,                         # e.g. 3.0.1 (default: newest release)
    [string] $ZipFile,                         # use this release zip instead of downloading
    [string] $Folder = $PSScriptRoot,          # the tool's folder
    [string] $Repository = 'ManikyaSG/DBA.Queries'
)

$ErrorActionPreference = 'Stop'

# Which tool lives in this folder: its main script and the GitHub tag prefix of its releases
$Tools = @(
    @{ Name = 'pre-post-check';     Script = 'Invoke-PrePostCheck.ps1' }
    @{ Name = 'perf-check-reports'; Script = 'Collect-PerfCheckReports.ps1' }
)
# Never replaced or removed by an update
$KeepNames = @('settings.psd1', 'db_mail_setup.sql', 'servers.txt')
$KeepPatterns = @('*.cred', '*.handoff')

function Get-ConfigLiterals([string]$ScriptText) {
    # The $Config = @{ ... } block of a script as name -> value, for values that are plain
    # constants (strings, numbers, $true / $false, arrays of those). Computed values
    # (e.g. Join-Path $PSScriptRoot ...) are skipped.
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($ScriptText, [ref]$tokens, [ref]$errors)
    $assign = $ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.AssignmentStatementAst] -and $a.Left.Extent.Text -eq '$Config' }, $false) | Select-Object -First 1
    $result = [ordered]@{}
    if (-not $assign) { return $result }
    $table = $assign.Right.Expression
    if ($table -isnot [System.Management.Automation.Language.HashtableAst]) { return $result }
    foreach ($kv in $table.KeyValuePairs) {
        $name = [string]$kv.Item1.SafeGetValue()
        $stmt = $kv.Item2
        $expr = if ($stmt -is [System.Management.Automation.Language.PipelineAst] -and $stmt.PipelineElements.Count -eq 1 -and $stmt.PipelineElements[0] -is [System.Management.Automation.Language.CommandExpressionAst]) { $stmt.PipelineElements[0].Expression } else { $null }
        if (-not $expr) { continue }
        try { $result[$name] = $expr.SafeGetValue() } catch { }    # not a constant
    }
    return $result
}

function ConvertTo-Psd1Literal($Value) {
    if ($null -eq $Value) { return '$null' }
    if ($Value -is [bool]) { if ($Value) { return '$true' } else { return '$false' } }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal]) { return [string]$Value }
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        return '@(' + ((@($Value) | ForEach-Object { ConvertTo-Psd1Literal $_ }) -join ', ') + ')'
    }
    return "'" + ([string]$Value).Replace("'", "''") + "'"
}

function New-MigratedSettings([string]$OldScriptText, [string]$NewScriptText) {
    # settings.psd1 text with the old script's values that differ from the new defaults
    # (only names the new version still has). Returns $null when nothing differs.
    $old = Get-ConfigLiterals $OldScriptText
    $new = Get-ConfigLiterals $NewScriptText
    $lines = @()
    foreach ($k in $old.Keys) {
        if (-not $new.Contains($k)) { continue }
        $o = ConvertTo-Psd1Literal $old[$k]; $n = ConvertTo-Psd1Literal $new[$k]
        if ($o -ne $n) { $lines += ('    {0,-22} = {1}' -f $k, $o) }
    }
    if (-not $lines) { return $null }
    return (@(
        "# Settings migrated from the previous version's script on $(Get-Date -Format 'yyyy-MM-dd HH:mm')."
        '# Only values that differ from the new defaults are here; see settings.example.psd1 for all of them.'
        '@{'
    ) + $lines + '}') -join "`r`n"
}

function Get-ToolVersion([string]$ScriptText) {
    if ($ScriptText -match "(?m)^\`$ToolVersion\s*=\s*'([^']+)'") { return $Matches[1] }
    return 'unversioned'
}

if ($MyInvocation.InvocationName -eq '.') { return }   # dot-sourced (tests): functions only

# ---------------------------------------------------------------------------------------
$Folder = (Resolve-Path -LiteralPath $Folder).Path
$tool = $Tools | Where-Object { Test-Path -LiteralPath (Join-Path $Folder $_.Script) } | Select-Object -First 1
if (-not $tool) { throw "No known tool in $Folder (looked for $(($Tools | ForEach-Object { $_.Script }) -join ', '))." }
$mainPath = Join-Path $Folder $tool.Script
$oldText = [System.IO.File]::ReadAllText($mainPath)
$oldVersion = Get-ToolVersion $oldText
Write-Host "Tool      : $($tool.Name) in $Folder (installed version $oldVersion)" -ForegroundColor Cyan

$work = Join-Path ([System.IO.Path]::GetTempPath()) ("dba_update_" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
try {
    if (-not $ZipFile) {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $releases = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repository/releases?per_page=100" -UseBasicParsing -Headers @{ 'User-Agent' = 'DBA-Update-Tool' }
        $prefix = "$($tool.Name)/v"
        $candidates = @($releases | Where-Object { $_.tag_name -like "$prefix*" -and -not $_.draft } | ForEach-Object {
            $v = $_.tag_name.Substring($prefix.Length)
            [pscustomobject]@{ Version = $v; Sortable = [version]($v -replace '[^\d.].*$', ''); Release = $_ } })
        if ($Version) { $pick = $candidates | Where-Object { $_.Version -eq $Version } | Select-Object -First 1 }
        else { $pick = $candidates | Where-Object { -not $_.Release.prerelease } | Sort-Object Sortable -Descending | Select-Object -First 1 }
        if (-not $pick) { throw "No release $(if ($Version) { "$Version " })found for $($tool.Name) in $Repository." }
        $asset = $pick.Release.assets | Where-Object { $_.name -like '*.zip' } | Select-Object -First 1
        if (-not $asset) { throw "Release $($pick.Release.tag_name) has no zip file." }
        $ZipFile = Join-Path $work $asset.name
        Write-Host "Download  : $($asset.browser_download_url)" -ForegroundColor Cyan
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $ZipFile -UseBasicParsing -Headers @{ 'User-Agent' = 'DBA-Update-Tool' }
    }
    $extract = Join-Path $work 'new'
    Expand-Archive -LiteralPath $ZipFile -DestinationPath $extract -Force
    # the zip has the files at the top, or in one folder
    $src = $extract
    if (-not (Test-Path -LiteralPath (Join-Path $src $tool.Script))) {
        $sub = Get-ChildItem -LiteralPath $extract -Directory | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName $tool.Script) } | Select-Object -First 1
        if (-not $sub) { throw "$ZipFile does not contain $($tool.Script) - not a $($tool.Name) release." }
        $src = $sub.FullName
    }
    $newText = [System.IO.File]::ReadAllText((Join-Path $src $tool.Script))
    $newVersion = Get-ToolVersion $newText
    Write-Host "Release   : $newVersion" -ForegroundColor Cyan

    # 1. settings.psd1 from the old script's values (first update to a version that uses it)
    $settingsPath = Join-Path $Folder 'settings.psd1'
    if (-not (Test-Path -LiteralPath $settingsPath) -and $newText -match 'Import-DbaSettings') {
        $migrated = New-MigratedSettings $oldText $newText
        if ($migrated) {
            if ($PSCmdlet.ShouldProcess($settingsPath, 'write settings migrated from the old script')) {
                [System.IO.File]::WriteAllText($settingsPath, $migrated, (New-Object System.Text.UTF8Encoding $false))
            }
            Write-Host "Settings  : your values from the old script saved to $settingsPath - check it:" -ForegroundColor Green
            Write-Host $migrated -ForegroundColor DarkGray
        }
        else { Write-Host 'Settings  : the old script used the defaults - no settings.psd1 needed.' -ForegroundColor DarkGray }
    }

    # 2. back up, then copy the new files
    $files = @(Get-ChildItem -LiteralPath $src -File | Where-Object {
        $n = $_.Name; ($KeepNames -notcontains $n) -and -not ($KeepPatterns | Where-Object { $n -like $_ }) })
    $backup = Join-Path $Folder ("_previous\{0}_{1}" -f $oldVersion, (Get-Date -Format 'yyyyMMdd_HHmmss'))
    foreach ($f in $files) {
        $target = Join-Path $Folder $f.Name
        $existed = Test-Path -LiteralPath $target
        if ($existed) {
            if ($PSCmdlet.ShouldProcess($target, "back up to $backup")) {
                if (-not (Test-Path -LiteralPath $backup)) { New-Item -ItemType Directory -Path $backup -Force | Out-Null }
                Copy-Item -LiteralPath $target -Destination $backup -Force
            }
        }
        if ($PSCmdlet.ShouldProcess($target, 'replace with the new version')) { Copy-Item -LiteralPath $f.FullName -Destination $target -Force }
        Write-Host ("  {0,-34} {1}" -f $f.Name, $(if ($existed) { 'updated' } else { 'new' })) -ForegroundColor DarkGray
    }
    Write-Host "Done      : $($tool.Name) $oldVersion -> $newVersion$(if (Test-Path -LiteralPath $backup) { ". Previous files: $backup" })" -ForegroundColor Green
}
finally { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
