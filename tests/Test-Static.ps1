$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$scripts = Get-ChildItem -LiteralPath (Join-Path $root 'src') -Filter '*.ps1' -File
foreach ($script in $scripts) {
    $tokens = $null; $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($script.FullName, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw "$($script.Name): $($errors -join '; ')" }
}
$config = Get-Content -LiteralPath (Join-Path $root 'config\schedule.example.json') -Raw | ConvertFrom-Json
if ([int]$config.selfHealHours -lt 1) { throw 'selfHealHours must be at least 1.' }
if ([int]$config.tempRetentionDays -lt 1) { throw 'tempRetentionDays must be at least 1.' }
Write-Host "Static checks passed for $($scripts.Count) scripts."

