# -----------------------------------------------------------------------------
# DbaCommon: helpers shared by the automation tools (Windows PowerShell 5.1+, no modules).
# This file is the ONLY place to change them. Every tool script carries a copy between
#   #region DbaCommon ... #endregion DbaCommon
# so each tool still deploys as a single .ps1. After editing this file run
#   automation/common/Sync-DbaCommon.ps1
# (the unit tests fail if a tool's copy differs from this file.)
# -----------------------------------------------------------------------------

function Write-Step([string]$Text, [string]$Color = 'Cyan') { Write-Host $Text -ForegroundColor $Color }

function Enc([string]$Value) { return [System.Net.WebUtility]::HtmlEncode($Value) }

function Get-SafeFileName([string]$Value) { return ($Value -replace '[\\/:*?"<>|\s,]', '_') }

function Get-Val($Row, [string]$Col) {
    # Value of a column from a hashtable / dictionary / object row, trimmed; '' when missing or NULL.
    if ($null -eq $Row) { return '' }
    if ($Row -is [System.Collections.IDictionary]) {
        # IDictionary.Contains works for Hashtable, OrderedDictionary and Dictionary[string,object] (JSON)
        if (([System.Collections.IDictionary]$Row).Contains($Col) -and $null -ne $Row[$Col]) { return ([string]$Row[$Col]).Trim() }
        return ''
    }
    $p = $Row.PSObject.Properties[$Col]
    if ($p -and $null -ne $p.Value) { return ([string]$p.Value).Trim() }
    return ''
}

function Import-DbaSettings([hashtable]$Config, [string]$Path) {
    # Overrides $Config with the values in a settings .psd1 (kept when the script is updated).
    # Returns the file used, or $null when there is none. Unknown names are reported, not used.
    # Relative paths for settings ending in Folder / File / Root are relative to the settings file.
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $null }
    $data = Import-PowerShellDataFile -LiteralPath $Path
    $base = Split-Path -Parent (Resolve-Path -LiteralPath $Path).Path
    foreach ($k in @($data.Keys)) {
        if (-not $Config.ContainsKey($k)) {
            Write-Step "Settings: '$k' in $Path is not a known setting - ignored (typo?)." 'Yellow'
            continue
        }
        $v = $data[$k]
        if ($v -is [string] -and $v -and $k -match '(Folder|File|Root)$' -and -not [System.IO.Path]::IsPathRooted($v)) { $v = Join-Path $base $v }
        if ($v -is [object[]]) { $v = @($v) }
        $Config[$k] = $v
    }
    return (Resolve-Path -LiteralPath $Path).Path
}

$DbaHtmlHead = @'
<html><head><meta charset="utf-8"><style>
body{font-family:Segoe UI,Arial,sans-serif;font-size:12px;color:#222}
h1{color:#fff;background:#1f4e79;padding:6px 10px;font-size:18px;margin:24px 0 6px 0} h2{color:#1f4e79;margin-bottom:2px} h3{color:#1f4e79;margin:18px 0 4px 0;border-bottom:1px solid #1f4e79}
table{border-collapse:collapse;margin-bottom:8px} th{background:#1f4e79;color:#fff;padding:4px 6px;text-align:left;font-weight:600}
td{border:1px solid #d0d0d0;padding:3px 6px;vertical-align:top}
.banner{padding:10px 14px;font-size:14px;font-weight:600;margin:8px 0}
.footer{color:#777;font-size:11px;margin-top:24px}
</style></head><body>
'@

function ConvertTo-HtmlTable($Rows, [string[]]$Columns, [string]$RowStyle = '', [string]$StatusColumn = '') {
    # Rows -> HTML table. With -StatusColumn, CRITICAL rows are red and WARNING rows amber.
    $rowsArr = @($Rows)
    if ($rowsArr.Count -eq 0) { return '<div style="color:#2e7d32">None</div>' }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('<table><tr>')
    foreach ($c in $Columns) { [void]$sb.Append('<th>' + (Enc $c) + '</th>') }
    [void]$sb.Append('</tr>')
    foreach ($r in $rowsArr) {
        $style = $RowStyle
        if ($StatusColumn) {
            switch (Get-Val $r $StatusColumn) { 'CRITICAL' { $style = 'background-color:#f8d7da' } 'WARNING' { $style = 'background-color:#fff3cd' } }
        }
        if ($style) { [void]$sb.Append('<tr style="' + $style + '">') } else { [void]$sb.Append('<tr>') }
        foreach ($c in $Columns) { [void]$sb.Append('<td>' + (Enc (Get-Val $r $c)) + '</td>') }
        [void]$sb.Append('</tr>')
    }
    [void]$sb.Append('</table>')
    return $sb.ToString()
}

function Split-SqlBatches([string]$Text) {
    # Splits a script on GO lines (like SSMS / sqlcmd). 'GO' inside a line or a string is not a separator.
    # GO <count> also separates, but the batch runs once.
    return @([regex]::Split($Text, '(?im)^[ \t]*GO(?:[ \t]+\d+)?[ \t]*(?:--.*)?\r?$') | Where-Object { $_ -match '\S' })
}

function Get-SqlErrorMessage($ErrorRecord) {
    # The SQL Server message from a failed ExecuteNonQuery / ExecuteReader (not the PowerShell wrapper text).
    $ex = $ErrorRecord.Exception
    while ($ex) { if ($ex -is [System.Data.SqlClient.SqlException]) { return $ex.Message }; $ex = $ex.InnerException }
    if ($ErrorRecord.Exception.InnerException) { return $ErrorRecord.Exception.InnerException.Message }
    return $ErrorRecord.Exception.Message
}

function Send-DbMailItem {
    # msdb.dbo.sp_send_dbmail with the return code checked (it can fail with only a return code).
    # Returns the mailitem_id. Attachments need a Windows login (SQL logins can't use @file_attachments).
    param(
        [Parameter(Mandatory)] $Connection,
        [Parameter(Mandatory)] [string] $ProfileName,
        [Parameter(Mandatory)] [string] $Recipients,
        [string] $CopyRecipients = '',
        [string] $FromAddress = '',
        [string] $ReplyTo = '',
        [Parameter(Mandatory)] [string] $Subject,
        [Parameter(Mandatory)] [string] $Body,
        [ValidateSet('Low', 'Normal', 'High')] [string] $Importance = 'Normal',
        [string[]] $Attachments = @(),
        [int] $TimeoutSec = 120
    )
    $nz = { param($v) if ([string]::IsNullOrWhiteSpace($v)) { [DBNull]::Value } else { $v } }
    $cmd = $Connection.CreateCommand(); $cmd.CommandTimeout = $TimeoutSec
    $cmd.CommandText = 'EXEC @rc = msdb.dbo.sp_send_dbmail @profile_name = @p, @recipients = @to, @copy_recipients = @cc, @from_address = @from, @reply_to = @reply, @subject = @subj, @body = @body, @body_format = ''HTML'', @importance = @imp, @file_attachments = @files, @mailitem_id = @id OUTPUT;'
    [void]$cmd.Parameters.AddWithValue('@p', $ProfileName)
    [void]$cmd.Parameters.AddWithValue('@to', $Recipients)
    [void]$cmd.Parameters.AddWithValue('@cc', (& $nz $CopyRecipients))
    [void]$cmd.Parameters.AddWithValue('@from', (& $nz $FromAddress))
    [void]$cmd.Parameters.AddWithValue('@reply', (& $nz $ReplyTo))
    [void]$cmd.Parameters.AddWithValue('@subj', $Subject)
    $pb = $cmd.Parameters.Add('@body', [System.Data.SqlDbType]::NVarChar, -1); $pb.Value = $Body
    [void]$cmd.Parameters.AddWithValue('@imp', $Importance)
    $files = @($Attachments | Where-Object { $_ })
    [void]$cmd.Parameters.AddWithValue('@files', $(if ($files.Count) { $files -join ';' } else { [DBNull]::Value }))
    $pid_ = $cmd.Parameters.Add('@id', [System.Data.SqlDbType]::Int); $pid_.Direction = [System.Data.ParameterDirection]::Output
    $prc = $cmd.Parameters.Add('@rc', [System.Data.SqlDbType]::Int); $prc.Direction = [System.Data.ParameterDirection]::Output
    [void]$cmd.ExecuteNonQuery()
    if ($prc.Value -isnot [DBNull] -and [int]$prc.Value -ne 0) { throw "sp_send_dbmail returned $($prc.Value)" }
    if ($pid_.Value -is [DBNull] -or $null -eq $pid_.Value) { return $null }
    return [int]$pid_.Value
}

function Get-DbMailItemStatus($Connection, [int]$MailItemId) {
    # 'sent' / 'unsent' / 'retrying' / 'failed - <reason from the Database Mail log>' / 'not found'
    $cmd = $Connection.CreateCommand(); $cmd.CommandTimeout = 60
    $cmd.CommandText = @"
SELECT a.sent_status + CASE WHEN a.sent_status = 'failed'
       THEN ' - ' + ISNULL((SELECT TOP (1) LEFT(l.description, 300) FROM msdb.dbo.sysmail_event_log AS l WHERE l.mailitem_id = a.mailitem_id ORDER BY l.log_id DESC), '') ELSE '' END
FROM msdb.dbo.sysmail_allitems AS a WHERE a.mailitem_id = @id;
"@
    [void]$cmd.Parameters.AddWithValue('@id', $MailItemId)
    $r = $cmd.ExecuteScalar()
    if ($null -eq $r -or $r -is [DBNull]) { return 'not found' }
    return [string]$r
}
