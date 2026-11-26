<#
.SYNOPSIS
    Copies automation/common/DbaCommon.ps1 into every tool script that has a DbaCommon region.

.DESCRIPTION
    The tools deploy as single .ps1 files, so the shared helpers are copied into each of them
    between these two lines:
        #region DbaCommon ...
        #endregion DbaCommon
    Edit DbaCommon.ps1, then run this script. -Check only reports (exit code 1 if a copy is
    out of date).

.EXAMPLE
    .\automation\common\Sync-DbaCommon.ps1
.EXAMPLE
    .\automation\common\Sync-DbaCommon.ps1 -Check
#>
[CmdletBinding()]
param([switch]$Check)

$ErrorActionPreference = 'Stop'
$source = Join-Path $PSScriptRoot 'DbaCommon.ps1'
$root   = Split-Path -Parent $PSScriptRoot          # automation/
$common = ([System.IO.File]::ReadAllText($source) -replace "`r`n", "`n").TrimEnd("`n")
$begin  = '#region DbaCommon - copied from automation/common/DbaCommon.ps1 by Sync-DbaCommon.ps1. Edit that file, not this copy.'
$end    = '#endregion DbaCommon'
$pattern = '(?ms)^#region DbaCommon\b[^\n]*\n.*?^#endregion DbaCommon[^\n]*'

$stale = 0
$targets = Get-ChildItem -LiteralPath $root -Recurse -Filter *.ps1 | Where-Object { $_.FullName -ne $source -and $_.DirectoryName -ne $PSScriptRoot }
foreach ($f in $targets) {
    $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
    $bom  = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    $raw  = [System.IO.File]::ReadAllText($f.FullName)
    $crlf = $raw.Contains("`r`n")
    $text = $raw -replace "`r`n", "`n"
    if ($text -notmatch '(?m)^#region DbaCommon\b') { continue }
    $new = [regex]::Replace($text, $pattern, { param($m) "$begin`n$common`n$end" })
    $rel = $f.FullName.Substring($root.Length + 1)
    if ($new -eq $text) { Write-Host "up to date : $rel" -ForegroundColor DarkGray; continue }
    $stale++
    if ($Check) { Write-Host "OUT OF DATE: $rel - run automation/common/Sync-DbaCommon.ps1" -ForegroundColor Red; continue }
    if ($crlf) { $new = $new -replace "`n", "`r`n" }
    [System.IO.File]::WriteAllText($f.FullName, $new, (New-Object System.Text.UTF8Encoding $bom))
    Write-Host "updated    : $rel" -ForegroundColor Green
}
if ($Check -and $stale) { exit 1 }
