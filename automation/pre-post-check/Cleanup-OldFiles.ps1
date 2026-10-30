<#
.SYNOPSIS
    Deletes old files from the Reports, Logs and Snapshots folders next to this script.

    Reports, Logs : files older than -Hours (default 48) are deleted.
    Snapshots     : a ticket folder's files older than -Hours are deleted ONLY if that ticket
                    already has a POST snapshot (the change is finished). A PRE without a POST is
                    kept for -KeepPreWithoutPostDays (default 7) so a change done later can still
                    be compared. Empty ticket folders are removed.

.EXAMPLE
    .\Cleanup-OldFiles.ps1                  # 48 hours
    .\Cleanup-OldFiles.ps1 -Hours 72 -WhatIf  # show what would be deleted, delete nothing
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [int] $Hours = 48,
    [int] $KeepPreWithoutPostDays = 7
)

$ErrorActionPreference = 'Continue'
$cutoff     = (Get-Date).AddHours(-$Hours)
$preCutoff  = (Get-Date).AddDays(-$KeepPreWithoutPostDays)
$deleted    = 0
$kept       = 0

function Remove-OldFile([System.IO.FileInfo]$File) {
    if ($PSCmdlet.ShouldProcess($File.FullName, 'Delete')) {
        try { Remove-Item -LiteralPath $File.FullName -Force -ErrorAction Stop; $script:deleted++; Write-Host "Deleted  $($File.FullName)" }
        catch { Write-Warning "Could not delete $($File.FullName): $($_.Exception.Message)" }
    }
}

Write-Host "Cleaning files older than $Hours hours (before $($cutoff.ToString('yyyy-MM-dd HH:mm'))) in $PSScriptRoot" -ForegroundColor Cyan

foreach ($folder in 'Reports', 'Logs') {
    $path = Join-Path $PSScriptRoot $folder
    if (-not (Test-Path $path)) { continue }
    Get-ChildItem -Path $path -File -Recurse | Where-Object { $_.LastWriteTime -lt $cutoff } | ForEach-Object { Remove-OldFile $_ }
}

$snapRoot = Join-Path $PSScriptRoot 'Snapshots'
if (Test-Path $snapRoot) {
    foreach ($ticketDir in Get-ChildItem -Path $snapRoot -Directory) {
        $files   = @(Get-ChildItem -Path $ticketDir.FullName -File)
        $hasPost = @($files | Where-Object { $_.Name -like '*_POST_*' }).Count -gt 0
        foreach ($f in $files) {
            $limit = if ($hasPost) { $cutoff } else { $preCutoff }
            if ($f.LastWriteTime -lt $limit) { Remove-OldFile $f }
            elseif (-not $hasPost -and $f.LastWriteTime -lt $cutoff) {
                $kept++; Write-Host "Kept     $($f.FullName)  (PRE without POST - kept $KeepPreWithoutPostDays days)" -ForegroundColor Yellow
            }
        }
        if (-not (Get-ChildItem -Path $ticketDir.FullName -Force) -and $PSCmdlet.ShouldProcess($ticketDir.FullName, 'Remove empty folder')) {
            Remove-Item -LiteralPath $ticketDir.FullName -Force
        }
    }
}

Write-Host "Done. Deleted $deleted file(s); kept $kept PRE snapshot(s) still waiting for POST." -ForegroundColor Green
