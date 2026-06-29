[CmdletBinding()]
param(
    [string]$InputPath = '',
    [switch]$WhatIf,
    [switch]$NoTsvUpdate
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $InputPath) {
    $InputPath = Join-Path $PSScriptRoot 'mhtml'
}

$InputPath = [System.IO.Path]::GetFullPath($InputPath)
if (-not (Test-Path -LiteralPath $InputPath -PathType Container)) {
    throw "Folder tidak ditemukan: $InputPath"
}

function Test-HtmlEntity {
    param([string]$Entity)

    if ([string]::IsNullOrEmpty($Entity)) {
        return $false
    }

    if ($Entity -match '^&#(?:\d+|x[0-9A-Fa-f]+);$') {
        return $true
    }

    return ([System.Net.WebUtility]::HtmlDecode($Entity) -ne $Entity)
}

function ConvertTo-NewEntityName {
    param([string]$Name)

    if ([string]::IsNullOrEmpty($Name)) {
        return $Name
    }

    $entityPattern = [regex]'&(?:#\d+|#x[0-9A-Fa-f]+|[A-Za-z][A-Za-z0-9]+);'
    $builder = [System.Text.StringBuilder]::new()
    $index = 0

    while ($index -lt $Name.Length) {
        $char = $Name[$index]

        if ($char -eq '&') {
            $match = $entityPattern.Match($Name, $index)
            if ($match.Success -and $match.Index -eq $index -and (Test-HtmlEntity -Entity $match.Value)) {
                if ($match.Value -match '^&#(?:\d+|x[0-9A-Fa-f]+);$') {
                    [void]$builder.Append($match.Value.Substring(0, $match.Value.Length - 1))
                    [void]$builder.Append('_')
                }
                else {
                    [void]$builder.Append($match.Value)
                }

                $index += $match.Value.Length
                continue
            }
        }

        if ($char -eq ';') {
            [void]$builder.Append('&#59_')
        }
        else {
            [void]$builder.Append($char)
        }

        $index++
    }

    return $builder.ToString()
}

function Get-RelativePathFromBase {
    param(
        [string]$BasePath,
        [string]$FullPath
    )

    $baseUri = [Uri](([System.IO.Path]::GetFullPath($BasePath).TrimEnd('\') + '\'))
    $fullUri = [Uri]([System.IO.Path]::GetFullPath($FullPath))
    return [Uri]::UnescapeDataString($baseUri.MakeRelativeUri($fullUri).ToString()) -replace '/', '\'
}

function Backup-File {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return ''
    }

    $backupPath = "$Path.$(Get-Date -Format 'yyyyMMdd-HHmmss').bak"
    Copy-Item -LiteralPath $Path -Destination $backupPath -Force
    return $backupPath
}

function ConvertTo-TsvValue {
    param([string]$Value)

    return ([string]$Value -replace "`t", ' ' -replace "\r?\n", ' ').Trim()
}

function Add-Replacement {
    param(
        [System.Collections.Generic.List[object]]$Replacements,
        [hashtable]$Seen,
        [string]$OldValue,
        [string]$NewValue
    )

    if ([string]::IsNullOrEmpty($OldValue) -or $OldValue -eq $NewValue) {
        return
    }

    $key = $OldValue
    if ($Seen.ContainsKey($key)) {
        return
    }

    $Seen[$key] = $true
    $Replacements.Add([pscustomobject]@{
        OldValue = $OldValue
        NewValue = $NewValue
    }) | Out-Null
}

function Get-PathReplacements {
    param([object[]]$Renames)

    $replacements = [System.Collections.Generic.List[object]]::new()
    $seen = @{}
    $scriptRootFull = [System.IO.Path]::GetFullPath($PSScriptRoot)

    foreach ($rename in $Renames) {
        $oldFull = [string]$rename.OldPath
        $newFull = [string]$rename.NewPath
        $oldRelativeToRoot = Get-RelativePathFromBase -BasePath $scriptRootFull -FullPath $oldFull
        $newRelativeToRoot = Get-RelativePathFromBase -BasePath $scriptRootFull -FullPath $newFull
        $oldRelativeToInput = Get-RelativePathFromBase -BasePath $InputPath -FullPath $oldFull
        $newRelativeToInput = Get-RelativePathFromBase -BasePath $InputPath -FullPath $newFull

        Add-Replacement -Replacements $replacements -Seen $seen -OldValue $oldFull -NewValue $newFull
        Add-Replacement -Replacements $replacements -Seen $seen -OldValue ($oldFull -replace '\\', '/') -NewValue ($newFull -replace '\\', '/')
        Add-Replacement -Replacements $replacements -Seen $seen -OldValue $oldRelativeToRoot -NewValue $newRelativeToRoot
        Add-Replacement -Replacements $replacements -Seen $seen -OldValue ($oldRelativeToRoot -replace '\\', '/') -NewValue ($newRelativeToRoot -replace '\\', '/')
        Add-Replacement -Replacements $replacements -Seen $seen -OldValue $oldRelativeToInput -NewValue $newRelativeToInput
        Add-Replacement -Replacements $replacements -Seen $seen -OldValue ($oldRelativeToInput -replace '\\', '/') -NewValue ($newRelativeToInput -replace '\\', '/')
    }

    return @($replacements | Sort-Object { ([string]$_.OldValue).Length } -Descending)
}

function Update-TsvReferences {
    param([object[]]$Renames)

    if ($Renames.Count -eq 0 -or $NoTsvUpdate) {
        return 0
    }

    $replacements = @(Get-PathReplacements -Renames $Renames)
    if ($replacements.Count -eq 0) {
        return 0
    }

    $updatedCount = 0
    $entityFixPath = [System.IO.Path]::GetFullPath((Join-Path $InputPath 'entity-fix.tsv'))
    $tsvFiles = @(Get-ChildItem -LiteralPath $InputPath -File -Filter '*.tsv' |
        Where-Object { -not ([System.IO.Path]::GetFullPath($_.FullName)).Equals($entityFixPath, [System.StringComparison]::OrdinalIgnoreCase) } |
        Sort-Object FullName)

    foreach ($tsv in $tsvFiles) {
        $text = [System.IO.File]::ReadAllText($tsv.FullName)
        $updated = $text

        foreach ($replacement in $replacements) {
            $updated = $updated.Replace([string]$replacement.OldValue, [string]$replacement.NewValue)
        }

        if ($updated -eq $text) {
            continue
        }

        $updatedCount++
        if ($WhatIf) {
            Write-Host "DRY RUN: update TSV $($tsv.FullName)"
            continue
        }

        $backupPath = Backup-File -Path $tsv.FullName
        if ($backupPath) {
            Write-Host "Backup TSV: $backupPath"
        }

        [System.IO.File]::WriteAllText($tsv.FullName, $updated, [System.Text.UTF8Encoding]::new($false))
        Write-Host "Update TSV: $($tsv.FullName)"
    }

    return $updatedCount
}

function Write-RenameLog {
    param([object[]]$Renames)

    $logPath = Join-Path $InputPath 'entity-fix.tsv'
    $scriptRootFull = [System.IO.Path]::GetFullPath($PSScriptRoot)
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("old_file`tnew_file") | Out-Null

    foreach ($rename in $Renames) {
        $oldRelative = Get-RelativePathFromBase -BasePath $scriptRootFull -FullPath ([string]$rename.OldPath)
        $newRelative = Get-RelativePathFromBase -BasePath $scriptRootFull -FullPath ([string]$rename.NewPath)
        $lines.Add(("{0}`t{1}" -f (ConvertTo-TsvValue $oldRelative), (ConvertTo-TsvValue $newRelative))) | Out-Null
    }

    [System.IO.File]::WriteAllLines($logPath, $lines, [System.Text.UTF8Encoding]::new($false))
    return $logPath
}

$files = @(Get-ChildItem -LiteralPath $InputPath -Recurse -File -Filter '*.mhtml' | Sort-Object FullName)
$candidates = [System.Collections.Generic.List[object]]::new()

foreach ($file in $files) {
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
    $newBaseName = ConvertTo-NewEntityName -Name $baseName
    if ($newBaseName -eq $baseName) {
        continue
    }

    $newPath = Join-Path $file.DirectoryName "$newBaseName$($file.Extension)"
    $candidates.Add([pscustomobject]@{
        OldPath = $file.FullName
        NewPath = $newPath
        OldName = $file.Name
        NewName = [System.IO.Path]::GetFileName($newPath)
    }) | Out-Null
}

if ($candidates.Count -eq 0) {
    Write-Host "Tidak ada nama file .mhtml yang perlu diperbaiki di $InputPath"
    exit 0
}

$targetGroups = $candidates | Group-Object { ([System.IO.Path]::GetFullPath([string]$_.NewPath)).ToLowerInvariant() }
$blockedTargets = @{}
foreach ($group in $targetGroups) {
    if ($group.Count -gt 1) {
        $blockedTargets[$group.Name] = "target dipakai oleh $($group.Count) file"
    }
}

$renames = [System.Collections.Generic.List[object]]::new()
$skipped = 0

foreach ($candidate in $candidates) {
    $oldFull = [System.IO.Path]::GetFullPath([string]$candidate.OldPath)
    $newFull = [System.IO.Path]::GetFullPath([string]$candidate.NewPath)
    $newKey = $newFull.ToLowerInvariant()

    if ($blockedTargets.ContainsKey($newKey)) {
        $skipped++
        Write-Warning "Skip collision: $($candidate.OldPath) -> $($candidate.NewPath) ($($blockedTargets[$newKey]))"
        continue
    }

    if ((Test-Path -LiteralPath $newFull -PathType Leaf) -and -not $oldFull.Equals($newFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        $skipped++
        Write-Warning "Skip target sudah ada: $($candidate.OldPath) -> $newFull"
        continue
    }

    $renames.Add($candidate) | Out-Null
}

if ($renames.Count -eq 0) {
    Write-Host "Tidak ada file yang aman untuk direname. Skip: $skipped"
    exit 1
}

Write-Host "File .mhtml ditemukan       : $($files.Count)"
Write-Host "Perlu rename                : $($candidates.Count)"
Write-Host "Aman rename                 : $($renames.Count)"
Write-Host "Skip                        : $skipped"
Write-Host ''

foreach ($rename in $renames) {
    if ($WhatIf) {
        Write-Host "DRY RUN: $($rename.OldPath) -> $($rename.NewName)"
        continue
    }

    Rename-Item -LiteralPath ([string]$rename.OldPath) -NewName ([string]$rename.NewName)
    Write-Host "Rename: $($rename.OldName) -> $($rename.NewName)"
}

$updatedTsvCount = Update-TsvReferences -Renames ([object[]]$renames.ToArray())
$logPath = ''
if (-not $WhatIf) {
    $logPath = Write-RenameLog -Renames ([object[]]$renames.ToArray())
    Write-Host "Output list: $logPath"
}

Write-Host ''
if ($WhatIf) {
    Write-Host "Dry run selesai. File akan direname: $($renames.Count). TSV akan diupdate: $updatedTsvCount. Output list tidak ditulis saat WhatIf."
}
else {
    Write-Host "Selesai. File direname: $($renames.Count). TSV diupdate: $updatedTsvCount."
}
