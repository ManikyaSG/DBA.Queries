# Integration tests against a real SQL Server (CI starts one in a container per version).
#   $env:SQLCI_SERVER   = 'localhost,1433'
#   $env:SQLCI_PASSWORD = '<sa password>'
#   Invoke-Pester ./automation/tests/Integration.Tests.ps1 -Output Detailed
# They run the SQL exactly as the tools do (System.Data.SqlClient, one connection),
# with SQL authentication because the containers are Linux.

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    if (-not $env:SQLCI_SERVER -or -not $env:SQLCI_PASSWORD) { throw 'Set SQLCI_SERVER and SQLCI_PASSWORD.' }
    $PrePost = Join-Path $AutomationRoot 'pre-post-check/Invoke-PrePostCheck.ps1'
    . (Join-Path $AutomationRoot 'common/DbaCommon.ps1')
    . ([scriptblock]::Create((Get-ScriptFunctionText $PrePost 'Get-Snapshot', 'Get-CheckDefinitions', 'Test-CheckDefinitions', 'Compare-Snapshots',
        'Get-FullReportHtml', 'Get-Rows', 'Get-RowKey', 'ConvertTo-Number', 'Invoke-Scalar', 'Get-MailProfileName', 'Get-DbMailState', 'Find-QueuedMail')))
    $Config = Get-ScriptConfig $PrePost
    $SqlText = [System.IO.File]::ReadAllText((Join-Path $AutomationRoot 'pre-post-check/HC_Snapshot.sql'))
    $Checks = (Get-CheckDefinitions $SqlText).Checks
    $script:RunStart = Get-Date

    function New-CiConnection([string]$Database = 'master') {
        $cs = "Server=$($env:SQLCI_SERVER);Database=$Database;User ID=sa;Password=$($env:SQLCI_PASSWORD);Encrypt=False;TrustServerCertificate=True;Connect Timeout=30;Application Name=DBA automation CI"
        $c = New-Object System.Data.SqlClient.SqlConnection $cs
        $c.Open()
        return $c
    }
    function Invoke-CiBatches($Connection, [string]$Text, [int]$TimeoutSec = 600) {
        # Runs a GO-separated script batch by batch; returns the PRINT / info messages. Stops at the first error.
        $msgs = New-Object System.Collections.ArrayList
        $h = [System.Data.SqlClient.SqlInfoMessageEventHandler] { param($s, $e) [void]$msgs.Add($e.Message) }
        $Connection.add_InfoMessage($h)
        try {
            $n = 0
            foreach ($b in (Split-SqlBatches $Text)) {
                $n++
                $cmd = $Connection.CreateCommand(); $cmd.CommandText = $b; $cmd.CommandTimeout = $TimeoutSec
                try { [void]$cmd.ExecuteNonQuery() }
                catch { throw "batch $n failed: $(Get-SqlErrorMessage $_)`n--- messages:`n$($msgs -join "`n")`n--- batch:`n$($b.Substring(0, [Math]::Min(400, $b.Length)))" }
            }
        }
        finally { $Connection.remove_InfoMessage($h) }
        return $msgs
    }
    $Conn = New-CiConnection
    Write-Host ("SQL Server: " + (Invoke-Scalar $Conn "SELECT @@VERSION"))
}

AfterAll { if ($Conn) { $Conn.Dispose() } }

Describe 'pre-post-check: HC_Snapshot.sql' {
    BeforeAll {
        $script:Snap1 = Get-Snapshot $Conn $SqlText
    }
    It 'runs without errors and returns the core sections' {
        foreach ($s in 'instance', 'config', 'databases', 'logins', 'files', 'vitals') {
            $script:Snap1.sections.ContainsKey($s) | Should -BeTrue -Because "section $s should have rows"
        }
    }
    It 'returns every column the --@check definitions name' {
        Test-CheckDefinitions $script:Snap1 $env:SQLCI_SERVER | Should -BeNullOrEmpty
    }
    It 'shows no differences when nothing changed between PRE and POST' {
        $snap2 = Get-Snapshot $Conn $SqlText
        $cmp = Compare-Snapshots $script:Snap1 $snap2
        $detail = ($cmp.Unexpected | ForEach-Object { "$($_.Section) / $($_.Item) / $($_.Attribute): $($_.Before) -> $($_.After)" }) -join '; '
        $cmp.Unexpected.Count | Should -Be 0 -Because $detail
        $newP = ($cmp.NewProblems | ForEach-Object { "$($_['area']) / $($_['item'])" }) -join '; '
        $cmp.NewProblems.Count | Should -Be 0 -Because $newP
    }
    It 'finds a new database, a changed setting and a new login made between PRE and POST' {
        $ctp = [int](Invoke-Scalar $Conn "SELECT CAST(value_in_use AS int) FROM sys.configurations WHERE name = N'cost threshold for parallelism'")
        try {
            [void](Invoke-CiBatches $Conn @"
CREATE DATABASE CI_PrePost_New;
GO
EXEC sys.sp_configure N'show advanced options', 1; RECONFIGURE;
EXEC sys.sp_configure N'cost threshold for parallelism', $($ctp + 7); RECONFIGURE;
GO
CREATE LOGIN ci_prepost_login WITH PASSWORD = N'Ci_Pre_Post_9f3!x', CHECK_POLICY = OFF;
"@)
            $after = Get-Snapshot $Conn $SqlText
            $cmp = Compare-Snapshots $script:Snap1 $after
            $u = @($cmp.Unexpected | ForEach-Object { "$($_.Section)|$($_.Item)|$($_.Attribute)|$($_.After)" })
            $u | Should -Contain "$($Checks['databases'].Title)|CI_PrePost_New|(row)|NEW"
            $u | Should -Contain "$($Checks['config'].Title)|cost threshold for parallelism|value_in_use|$($ctp + 7)"
            $u | Should -Contain "$($Checks['logins'].Title)|ci_prepost_login|(row)|NEW"
        }
        finally {
            [void](Invoke-CiBatches $Conn @"
IF DB_ID(N'CI_PrePost_New') IS NOT NULL DROP DATABASE CI_PrePost_New;
IF SUSER_ID(N'ci_prepost_login') IS NOT NULL DROP LOGIN ci_prepost_login;
EXEC sys.sp_configure N'cost threshold for parallelism', $ctp; RECONFIGURE;
"@)
        }
    }
    It 'renders the report' {
        $html = Get-FullReportHtml $script:Snap1
        $html | Should -Match '<h3>Instance</h3>'
        $html | Should -Match '<h3>sp_configure</h3>'
        $html | Should -Not -Match 'no --@check definition'
    }
}

Describe 'Database Mail (setup script, profile detection, sending)' {
    BeforeAll {
        $script:MailSkip = $null
        try {
            $setup = [System.IO.File]::ReadAllText((Join-Path $AutomationRoot 'perf-check-reports/database_mail_setup.sql'))
            $script:MailMsgs = Invoke-CiBatches $Conn $setup 300
        }
        catch { $script:MailSkip = $_.Exception.Message }
    }
    It 'database_mail_setup.sql runs batch by batch (as Invoke-PrePostCheck runs db_mail_setup.sql)' {
        if ($script:MailSkip -match 'not supported|platform|Linux') { Set-ItResult -Skipped -Because $script:MailSkip; return }
        $script:MailSkip | Should -BeNullOrEmpty
    }
    It 'Get-MailProfileName and Get-DbMailState see the profile' {
        if ($script:MailSkip) { Set-ItResult -Skipped -Because 'Database Mail setup did not run'; return }
        $st = Get-DbMailState $Conn
        $st.XpsOn | Should -BeTrue
        $st.Usable | Should -BeGreaterOrEqual 1
        Get-MailProfileName $Conn | Should -Not -BeNullOrEmpty
    }
    It 'Send-DbMailItem queues a mail item and Get-DbMailItemStatus reads it back' {
        if ($script:MailSkip) { Set-ItResult -Skipped -Because 'Database Mail setup did not run'; return }
        $prof = Get-MailProfileName $Conn
        $id = Send-DbMailItem -Connection $Conn -ProfileName $prof -Recipients 'ci@example.invalid' -Subject "CI test $(Get-Date -Format o)" -Body '<b>CI</b>'
        $id | Should -BeGreaterThan 0
        Get-DbMailItemStatus $Conn $id | Should -Match '^(unsent|sent|retrying|failed)'
    }
}

Describe 'perf-check-reports: HealthPerfCheck_AgentJob.sql' {
    BeforeAll {
        $text = [System.IO.File]::ReadAllText((Join-Path $AutomationRoot 'perf-check-reports/HealthPerfCheck_AgentJob.sql'))
        $cut = $text.IndexOf("/*=============================================================================`n  PART 3")
        if ($cut -lt 0) { $cut = $text.IndexOf("/*=============================================================================`r`n  PART 3") }
        $script:Part12 = $text.Substring(0, $cut)     # PART 3 (the collector job) needs the coordinator's name
        [void](Invoke-CiBatches $Conn "IF DB_ID(N'DBAdmin') IS NULL CREATE DATABASE DBAdmin;")
    }
    It 'PART 1 (objects) and PART 2 (job) install without errors' {
        $msgs = Invoke-CiBatches $Conn $script:Part12 600
        ($msgs -join "`n") | Should -Match 'PART 1 done'
        Invoke-Scalar $Conn "SELECT COUNT(*) FROM msdb.dbo.sysjobs WHERE name = N'DBA - Health & Performance Check'" | Should -Be 1
    }
    It 'PART 1 and PART 2 can run again (upgrade in place)' {
        { Invoke-CiBatches $Conn $script:Part12 600 } | Should -Not -Throw
    }
    It 'the check runs as the Agent job runs it (ODBC / sqlcmd) and saves a finished report' {
        # SQL Agent runs T-SQL job steps through ODBC, so this is the production path.
        if (-not $env:SQLCI_CONTAINER) { Set-ItResult -Skipped -Because 'SQLCI_CONTAINER (docker container name) not set'; return }
        $sqlcmd = (docker exec $env:SQLCI_CONTAINER bash -c 'ls /opt/mssql-tools18/bin/sqlcmd /opt/mssql-tools/bin/sqlcmd 2>/dev/null | head -n 1')
        if (-not $sqlcmd) { Set-ItResult -Skipped -Because 'no sqlcmd in this SQL Server image'; return }
        $sqlcmdArgs = @('-S', 'localhost', '-U', 'sa', '-P', $env:SQLCI_PASSWORD, '-d', 'DBAdmin', '-b', '-I',
                        '-Q', "EXEC dbo.usp_DBA_HealthPerfCheck @SampleSec = 5, @DurationMin = 1, @SendEmail = 0, @SaveToTable = 1, @PrimaryOnly = 1, @Label = N'CI-ODBC';")
        if ($sqlcmd -like '*tools18*') { $sqlcmdArgs = @('-C') + $sqlcmdArgs }
        $out = docker exec $env:SQLCI_CONTAINER $sqlcmd @sqlcmdArgs 2>&1
        $rc = $LASTEXITCODE
        Write-Host "sqlcmd exit code $rc"; Write-Host (($out | Select-Object -Last 5) -join "`n")
        $rc | Should -Be 0 -Because (($out | Out-String).Trim())
        $r = [string](Invoke-Scalar $Conn "SELECT TOP (1) status + '|' + CAST(LEN(report_html) AS varchar(20)) FROM DBAdmin.dbo.DBA_PerfCheck_Report WHERE label = N'CI-ODBC' ORDER BY run_id DESC;")
        $r | Should -Match '^(OK|WARNING|CRITICAL)\|\d{4,}' -Because $r
    }
    It 'the check called from .NET (System.Data.SqlClient, as in SSMS / PowerShell) saves a finished report' {
        $c = New-CiConnection 'DBAdmin'
        $clientError = $null
        try {
            $cmd = $c.CreateCommand(); $cmd.CommandTimeout = 600
            $cmd.CommandText = 'EXEC dbo.usp_DBA_HealthPerfCheck @SampleSec = 5, @DurationMin = 1, @SendEmail = 0, @SaveToTable = 1, @PrimaryOnly = 1, @Label = N''CI'';'
            try { [void]$cmd.ExecuteNonQuery() } catch { $clientError = Get-SqlErrorMessage $_ }
        }
        finally { $c.Dispose() }
        $r = [string](Invoke-Scalar $Conn "SELECT TOP (1) status + '|' + CAST(LEN(report_html) AS varchar(20)) + '|' + ISNULL(error_message, '') FROM DBAdmin.dbo.DBA_PerfCheck_Report WHERE label = N'CI' ORDER BY run_id DESC;")
        Write-Host "Result row: $r"
        $r | Should -Match '^(OK|WARNING|CRITICAL)\|\d{4,}\|' -Because $r
        if ($clientError) {
            # Known: SqlClient can end with 'A severe error occurred' after the procedure has finished and saved
            # its row (the server logs no error). Reported as a warning, not a failure, while it is looked into.
            $first = ($clientError -split "`n")[0]
            Write-Host "::warning title=SqlClient error after usp_DBA_HealthPerfCheck finished::$first"
            $clientError | Should -Match 'severe error' -Because "any other client error is a real failure: $clientError"
        }
    }
}
