# Helpers for the automation tests (dot-source from a test file).
# The tools are single scripts that start working when run, so tests load only their
# functions (and their default $Config) through the PowerShell parser, without running them.

$AutomationRoot = Split-Path -Parent $PSScriptRoot

function Get-ScriptAst([string]$Path) {
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw "$Path does not parse: $($errors[0].Message) (line $($errors[0].Extent.StartLineNumber))" }
    return $ast
}

function Get-ScriptFunctionText([string]$Path, [string[]]$Name) {
    # Source text of the named top-level functions (all of them when -Name is empty), ready to dot-source:
    #   . ([scriptblock]::Create((Get-ScriptFunctionText $ps1 'Compare-Snapshots', 'Get-Rows')))
    $ast = Get-ScriptAst $Path
    $defs = $ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)
    $found = @($defs | Where-Object { -not $Name -or $Name -contains $_.Name })
    foreach ($n in $Name) { if (-not ($found | Where-Object { $_.Name -eq $n })) { throw "function $n not found in $Path" } }
    return (($found | ForEach-Object { $_.Extent.Text }) -join "`n`n")
}

function Get-ScriptConfig([string]$Path) {
    # The script's default $Config hashtable ($PSScriptRoot in it = the script's folder).
    $ast = Get-ScriptAst $Path
    $assign = $ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.AssignmentStatementAst] -and $a.Left.Extent.Text -eq '$Config' }, $false) | Select-Object -First 1
    if (-not $assign) { throw "no `$Config = @{ ... } in $Path" }
    $folder = Split-Path -Parent $Path
    $text = $assign.Right.Extent.Text -replace '\$PSScriptRoot', ("'" + $folder.Replace("'", "''") + "'")
    return (& ([scriptblock]::Create($text)))
}

function Get-ScriptVariable([string]$Path, [string]$Name) {
    # Value of a top-level '$Name = <constant>' line, e.g. $ToolVersion.
    $ast = Get-ScriptAst $Path
    $assign = $ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.AssignmentStatementAst] -and $a.Left.Extent.Text -eq "`$$Name" }, $false) | Select-Object -First 1
    if (-not $assign) { return $null }
    return $assign.Right.Expression.SafeGetValue()
}

function Get-ChangelogVersion([string]$Path) {
    # Version of the first '## x.y.z' heading in a CHANGELOG.md.
    $m = [regex]::Match([System.IO.File]::ReadAllText($Path), '(?m)^##\s+\[?(\d+\.\d+\.\d+)')
    if ($m.Success) { return $m.Groups[1].Value }
    return $null
}

function New-TestSnapshot([hashtable]$Sections) {
    # Snapshot in the shape Get-Snapshot returns: sections = name -> list of row hashtables, columns = name -> names.
    $sec = @{}; $cols = @{}
    foreach ($k in $Sections.Keys) {
        $rows = New-Object System.Collections.ArrayList
        foreach ($r in @($Sections[$k])) { [void]$rows.Add($r) }
        $sec[$k] = $rows
        $cols[$k] = if ($rows.Count) { @($rows[0].Keys) } else { @() }
    }
    return @{ sections = $sec; columns = $cols }
}
