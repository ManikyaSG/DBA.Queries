# Unit tests: no SQL Server needed. Run with Pester 5:
#   Invoke-Pester ./automation/tests/Unit.Tests.ps1 -Output Detailed
# CI runs them on Windows PowerShell 5.1 (what the VMs use) and on PowerShell 7.

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $PrePost   = Join-Path $AutomationRoot 'pre-post-check/Invoke-PrePostCheck.ps1'
    $Snapshot  = Join-Path $AutomationRoot 'pre-post-check/HC_Snapshot.sql'
    $Collector = Join-Path $AutomationRoot 'perf-check-reports/Collect-PerfCheckReports.ps1'
    $Common    = Join-Path $AutomationRoot 'common/DbaCommon.ps1'
    . $Common
    . ([scriptblock]::Create((Get-ScriptFunctionText $PrePost 'Get-CheckDefinitions', 'Test-CheckDefinitions', 'Compare-Snapshots', 'Get-FullReportHtml', 'Get-Rows', 'Get-RowKey', 'ConvertTo-Number')))
    $Config = Get-ScriptConfig $PrePost
    $SqlText = [System.IO.File]::ReadAllText($Snapshot)
    $Defs = Get-CheckDefinitions $SqlText
    $Checks = $Defs.Checks
}

Describe 'Scripts' {
    It 'every automation script parses' {
        $bad = @()
        foreach ($f in Get-ChildItem -LiteralPath $AutomationRoot -Recurse -Filter *.ps1) {
            $e = $null; [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$e)
            if ($e.Count) { $bad += "$($f.Name): $($e[0].Message) (line $($e[0].Extent.StartLineNumber))" }
        }
        $bad | Should -BeNullOrEmpty
    }
    It 'scripts, SQL and batch files are plain ASCII (Windows PowerShell 5.1 reads BOM-less files as ANSI)' {
        $bad = @()
        foreach ($f in Get-ChildItem -LiteralPath $AutomationRoot -Recurse -Include *.ps1, *.psd1, *.sql, *.bat) {
            $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
            $start = if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { 3 } else { 0 }
            for ($i = $start; $i -lt $bytes.Length; $i++) { if ($bytes[$i] -gt 127) { $bad += "$($f.Name) (byte $i)"; break } }
        }
        $bad | Should -BeNullOrEmpty
    }
}

Describe 'Shared core (DbaCommon)' {
    It 'every tool carries the current copy of DbaCommon.ps1' {
        $common = ([System.IO.File]::ReadAllText($Common) -replace "`r`n", "`n").TrimEnd("`n")
        $tools = @(Get-ChildItem -LiteralPath $AutomationRoot -Recurse -Filter *.ps1 | Where-Object { (Get-Content -LiteralPath $_.FullName -Raw) -match '(?m)^#region DbaCommon\b' })
        $tools.Count | Should -BeGreaterOrEqual 2
        foreach ($t in $tools) {
            $text = [System.IO.File]::ReadAllText($t.FullName) -replace "`r`n", "`n"
            $m = [regex]::Match($text, '(?ms)^#region DbaCommon\b[^\n]*\n(.*?)\n^#endregion DbaCommon')
            $m.Success | Should -BeTrue -Because "$($t.Name) has a DbaCommon region"
            $m.Groups[1].Value | Should -BeExactly $common -Because "$($t.Name) must be synced: run automation/common/Sync-DbaCommon.ps1"
        }
    }
    It 'Split-SqlBatches splits on GO lines only' {
        $b = Split-SqlBatches "SELECT 1`r`nGO`r`nSELECT 'GO' -- GO`r`n  go 5  `r`nSELECT 3`nGO -- end`n"
        $b.Count | Should -Be 3
        $b[1] | Should -Match "SELECT 'GO'"
    }
    It 'Get-Val reads hashtables, ordered and generic dictionaries and objects' {
        $o = [ordered]@{ a = ' x ' }
        $d = New-Object 'System.Collections.Generic.Dictionary[string,object]'; $d['a'] = 5
        Get-Val @{ a = 'h' } 'a' | Should -Be 'h'
        Get-Val $o 'a' | Should -Be 'x'
        Get-Val $d 'a' | Should -Be '5'
        Get-Val ([pscustomobject]@{ a = 'p' }) 'a' | Should -Be 'p'
        Get-Val @{ a = $null } 'a' | Should -Be ''
        Get-Val $o 'missing' | Should -Be ''
    }
    It 'ConvertTo-HtmlTable encodes values and colours status rows' {
        $html = ConvertTo-HtmlTable @(@{ s = 'CRITICAL'; v = '<b>' }, @{ s = 'OK'; v = 'a&b' }) @('s', 'v') '' 's'
        $html | Should -Match '&lt;b&gt;'
        $html | Should -Match 'a&amp;b'
        $html | Should -Match 'f8d7da'
        ConvertTo-HtmlTable @() @('x') | Should -Match 'None'
    }
    It 'Import-DbaSettings overrides known settings, resolves relative paths and reports unknown names' {
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ('dbaset_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir | Out-Null
        try {
            "@{ Recipients = 'me@x.com'; ExtraInstances = @('A', 'B'); ReportsFolder = 'R2'; AttachReport = `$false; NotASetting = 1 }" |
                Set-Content -LiteralPath (Join-Path $dir 'settings.psd1')
            $cfg = @{ Recipients = 'x'; ExtraInstances = @(); ReportsFolder = 'C:\R'; AttachReport = $true }
            $used = Import-DbaSettings $cfg (Join-Path $dir 'settings.psd1') 6>$null
            $used | Should -Not -BeNullOrEmpty
            $cfg.Recipients | Should -Be 'me@x.com'
            @($cfg.ExtraInstances).Count | Should -Be 2
            $cfg.ReportsFolder | Should -Be (Join-Path (Resolve-Path $dir).Path 'R2')
            $cfg.AttachReport | Should -BeFalse
            $cfg.ContainsKey('NotASetting') | Should -BeFalse
            Import-DbaSettings $cfg (Join-Path $dir 'missing.psd1') | Should -BeNullOrEmpty
        }
        finally { Remove-Item -LiteralPath $dir -Recurse -Force }
    }
}

Describe 'Check definitions in HC_Snapshot.sql' {
    BeforeAll {
        $selects = @{}
        foreach ($m in [regex]::Matches($SqlText, "(?ms)^SELECT (?:TOP \(\d+\) )?N'(\w+)' AS _section.*?;\s*$")) { $selects[$m.Groups[1].Value] = $m.Value }
    }
    It 'parse without warnings' {
        $Defs.Warnings | Should -BeNullOrEmpty
        $Checks.Count | Should -BeGreaterThan 20
    }
    It 'every SELECT has a definition and every SQL definition has a SELECT' {
        foreach ($s in $selects.Keys) { $Checks.Contains($s) | Should -BeTrue -Because "SELECT N'$s' needs --@check lines" }
        foreach ($c in $Checks.Keys) {
            if ($Checks[$c].Source -eq 'powershell') { continue }
            $selects.ContainsKey($c) | Should -BeTrue -Because "--@check $c has no SELECT N'$c' AS _section"
        }
    }
    It 'every column a definition names is returned by its SELECT' {
        foreach ($c in $Checks.Keys) {
            $d = $Checks[$c]
            if ($d.Source -eq 'powershell') { continue }
            foreach ($col in @($d.Key) + @($d.Compare) + @($d.Expected) + @($d.Drift.Keys)) {
                $selects[$c] | Should -Match "(?i)(\bAS\s+$col\b|[.\s,]$col\s*(,|\r?\n|FROM))" -Because "--@check $c names column $col"
            }
        }
    }
    It 'the issues section comes first and compare-only sections are not in the report' {
        @($Checks.Keys)[0] | Should -Be 'issues'
        $Checks['jobs'].Report | Should -BeFalse
        $Checks['files'].Email | Should -BeFalse
        $Checks['instance'].ExpectedKeys | Should -Contain 'build'
        $Checks['databases'].Drift['size_mb'] | Should -Be 'pct'
    }
    It 'reports typos in definitions' {
        $bad = Get-CheckDefinitions "--@check x: X`n--@   kee: a`n--@   drift: b=wrong`nSELECT 1;"
        @($bad.Warnings).Count | Should -Be 2
        $bad.Checks.Contains('x') | Should -BeTrue
    }
}

Describe 'Compare-Snapshots' {
    BeforeAll {
        $pre = New-TestSnapshot @{
            instance  = @(@{ property_code = 'build'; value = '16.0.4100.1' }, @{ property_code = 'sql_uptime'; value = '5d' }, @{ property_code = 'edition'; value = 'Enterprise' })
            config    = @(@{ name = 'max server memory (MB)'; value_in_use = '4096' }, @{ name = 'xp_cmdshell'; value_in_use = '0' })
            databases = @(@{ name = 'Sales'; state = 'ONLINE'; recovery_model = 'FULL'; size_mb = '1000' }, @{ name = 'Old'; state = 'ONLINE'; recovery_model = 'SIMPLE'; size_mb = '10' })
            disks     = @(@{ volume = 'C:\'; total_gb = '100'; free_gb = '50' })
            issues    = @(@{ severity = 'WARNING'; area = 'Backup'; item = 'Sales'; detail = 'old backup' })
        }
        $post = New-TestSnapshot @{
            instance  = @(@{ property_code = 'build'; value = '16.0.4200.1' }, @{ property_code = 'sql_uptime'; value = '0d' }, @{ property_code = 'edition'; value = 'Enterprise' })
            config    = @(@{ name = 'max server memory (MB)'; value_in_use = '8192' }, @{ name = 'xp_cmdshell'; value_in_use = '0' })
            databases = @(@{ name = 'Sales'; state = 'ONLINE'; recovery_model = 'FULL'; size_mb = '3000' }, @{ name = 'New'; state = 'ONLINE'; recovery_model = 'FULL'; size_mb = '10' })
            disks     = @(@{ volume = 'C:\'; total_gb = '100'; free_gb = '49' })
            issues    = @(@{ severity = 'WARNING'; area = 'Backup'; item = 'Sales'; detail = 'old backup' }, @{ severity = 'CRITICAL'; area = 'Service'; item = 'SQLAgent'; detail = 'Stopped' })
        }
        $cmp = Compare-Snapshots $pre $post
        $u = @($cmp.Unexpected | ForEach-Object { "$($_.Item)|$($_.Attribute)|$($_.After)" })
    }
    It 'finds a changed setting' { $u | Should -Contain 'max server memory (MB)|value_in_use|8192' }
    It 'finds a missing and a new row' {
        $u | Should -Contain 'Old|(row)|MISSING'
        $u | Should -Contain 'New|(row)|NEW'
    }
    It 'flags a big size change but not a small disk change' {
        $u | Should -Contain 'Sales|size_mb|3000'
        @($cmp.Unexpected | Where-Object { $_.Item -eq 'C:\' }).Count | Should -Be 0
    }
    It 'lists the build change as expected and ignores uptime' {
        @($cmp.Expected | Where-Object { $_.Item -eq 'build' }).Count | Should -Be 1
        @($cmp.Unexpected | Where-Object { $_.Item -eq 'sql_uptime' -or $_.Item -eq 'build' }).Count | Should -Be 0
    }
    It 'separates new problems from problems that already existed' {
        $cmp.NewProblems.Count | Should -Be 1
        $cmp.OldProblems.Count | Should -Be 1
    }
    It 'reports nothing when PRE and POST are the same' {
        $same = Compare-Snapshots $pre $pre
        ($same.Unexpected.Count + $same.Expected.Count + $same.NewProblems.Count) | Should -Be 0
    }
    It 'works on a PRE loaded from JSON (generic dictionaries)' {
        try { Add-Type -AssemblyName System.Web.Extensions -ErrorAction Stop } catch { }
        if (-not ('System.Web.Script.Serialization.JavaScriptSerializer' -as [type])) { Set-ItResult -Skipped -Because 'JavaScriptSerializer is Windows PowerShell only'; return }
        $js = New-Object System.Web.Script.Serialization.JavaScriptSerializer
        $preJson = $js.DeserializeObject((ConvertTo-Json -InputObject $pre -Depth 10 -Compress))
        $cmp2 = Compare-Snapshots $preJson $post
        $cmp2.Unexpected.Count | Should -Be $cmp.Unexpected.Count
    }
}

Describe 'Get-FullReportHtml' {
    BeforeAll {
        $snap = New-TestSnapshot @{
            issues   = @(@{ severity = 'WARNING'; area = 'A'; item = 'i'; detail = 'd' })
            instance = @(@{ property_code = 'build'; value = '1' })
            files    = @(@{ database_name = 'db'; logical_name = 'f'; size_mb = '1' })
            jobs     = @(@{ name = 'job1'; enabled = '1' })
            mystery  = @(@{ a = '1' })
        }
        $titles = { param($h) @([regex]::Matches($h, '<h3>(.*?)</h3>') | ForEach-Object { $_.Groups[1].Value }) }
    }
    It 'follows the definition order, leaves out report: no, and puts undefined sections last' {
        $t = & $titles (Get-FullReportHtml $snap)
        $t[0] | Should -Be 'Needs attention'
        $t | Should -Contain 'Data &amp; log files'
        $t | Should -Not -Contain 'Agent jobs'
        $t[-1] | Should -Match 'mystery'
    }
    It 'leaves email: no sections out of the email body' {
        $t = & $titles (Get-FullReportHtml $snap -ForEmail -Exclude @('issues'))
        $t | Should -Not -Contain 'Data &amp; log files'
        $t | Should -Not -Contain 'Needs attention'
    }
}

Describe 'Versions' {
    It 'Invoke-PrePostCheck.ps1, HC_Snapshot.sql and the CHANGELOG have the same version' {
        $v = Get-ScriptVariable $PrePost 'ToolVersion'
        $v | Should -Match '^\d+\.\d+\.\d+$'
        ([regex]::Match($SqlText, '(?m)^--@version\s+(\S+)').Groups[1].Value) | Should -Be $v
        Get-ChangelogVersion (Join-Path $AutomationRoot 'pre-post-check/CHANGELOG.md') | Should -Be $v
    }
    It 'Collect-PerfCheckReports.ps1 and its CHANGELOG have the same version' {
        $v = Get-ScriptVariable $Collector 'ToolVersion'
        $v | Should -Match '^\d+\.\d+\.\d+$'
        Get-ChangelogVersion (Join-Path $AutomationRoot 'perf-check-reports/CHANGELOG.md') | Should -Be $v
    }
}

Describe 'Settings examples' {
    It 'pre-post-check: settings.example.psd1 has exactly the settings of the script, with the same defaults' {
        $ex = Import-PowerShellDataFile (Join-Path $AutomationRoot 'pre-post-check/settings.example.psd1')
        @($Config.Keys | Where-Object { -not $ex.ContainsKey($_) }) | Should -BeNullOrEmpty
        @($ex.Keys | Where-Object { -not $Config.ContainsKey($_) }) | Should -BeNullOrEmpty
        foreach ($k in $ex.Keys) {
            $def = $Config[$k]; $val = $ex[$k]
            if ($def -is [string] -and $k -match '(Folder|File|Root)$') { $def = Split-Path $def -Leaf }
            (@($val) -join '|') | Should -Be (@($def) -join '|') -Because "the example shows the default of $k"
        }
    }
    It 'perf-check-reports: settings.example.psd1 only has settings the collector knows' {
        $cfg = Get-ScriptConfig $Collector
        $ex = Import-PowerShellDataFile (Join-Path $AutomationRoot 'perf-check-reports/settings.example.psd1')
        @($ex.Keys | Where-Object { -not $cfg.ContainsKey($_) }) | Should -BeNullOrEmpty
    }
}

Describe 'Update-DbaTool settings migration' {
    BeforeAll { . (Join-Path $AutomationRoot 'common/Update-DbaTool.ps1') }
    It 'keeps only the values that differ from the new defaults' {
        $old = "`$Config = @{`n  Recipients = 'team@contoso.com'`n  CleanupHours = 72`n  Encrypt = `$false`n  ExtraInstances = @('VM2\I1', 'VM3')`n  LogsFolder = Join-Path `$PSScriptRoot 'Logs'`n  Gone = 1`n}"
        $new = "`$ToolVersion = '9.9.9'`n`$Config = @{`n  Recipients = 'dba-team@yourcompany.com'`n  CleanupHours = 48`n  Encrypt = `$false`n  ExtraInstances = @()`n  LogsFolder = Join-Path `$PSScriptRoot 'Logs'`n}"
        $text = New-MigratedSettings $old $new
        $file = Join-Path ([System.IO.Path]::GetTempPath()) ('mig_' + [guid]::NewGuid().ToString('N') + '.psd1')
        try {
            [System.IO.File]::WriteAllText($file, $text)
            $d = Import-PowerShellDataFile $file
            @($d.Keys | Sort-Object) -join ',' | Should -Be 'CleanupHours,ExtraInstances,Recipients'
            $d.Recipients | Should -Be 'team@contoso.com'
            @($d.ExtraInstances) -join '|' | Should -Be 'VM2\I1|VM3'
        }
        finally { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue }
        New-MigratedSettings $new $new | Should -BeNullOrEmpty
        Get-ToolVersion $new | Should -Be '9.9.9'
    }
}
