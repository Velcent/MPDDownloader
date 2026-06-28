[CmdletBinding()]
param(
    [string]$TsvPath = '',
    [string]$RootPath = '',
    [switch]$WhatIf
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
if (-not $TsvPath) {
    $TsvPath = Join-Path $PSScriptRoot 'assets\mhtml-uuid.tsv'
}

if (-not $RootPath) {
    $tsvParent = Split-Path -Parent ([System.IO.Path]::GetFullPath($TsvPath))
    if ((Split-Path -Leaf $tsvParent) -ieq 'assets') {
        $RootPath = Split-Path -Parent $tsvParent
    }
    else {
        $RootPath = $PSScriptRoot
    }
}

$ScriptRootFull = [System.IO.Path]::GetFullPath($RootPath)

function Test-ObjectProperty {
    param(
        [AllowNull()]$Object,
        [string]$Name
    )

    if ($null -eq $Object) {
        return $false
    }

    return @($Object.PSObject.Properties.Match($Name)).Count -gt 0
}

function ConvertTo-TsvValue {
    param([AllowNull()][string]$Value)

    if ($null -eq $Value) {
        return ''
    }

    return (($Value -replace "`t", ' ') -replace "(`r`n|`r|`n)", ' ').Trim()
}

function ConvertTo-FullPath {
    param([string]$RelativePath)

    return Join-Path $ScriptRootFull ($RelativePath -replace '/', [System.IO.Path]::DirectorySeparatorChar)
}

function ConvertTo-RelativeRootPath {
    param([string]$FullPath)

    $full = [System.IO.Path]::GetFullPath($FullPath)
    $root = $ScriptRootFull.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    if ($full.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
        return ($full.Substring($root.Length) -replace '\\', '/')
    }

    return ($full -replace '\\', '/')
}

function Read-ManifestFile {
    param([string]$Path)

    $rows = New-Object System.Collections.Generic.List[object]
    $isHeader = $true
    foreach ($line in [System.IO.File]::ReadLines($Path)) {
        if ($isHeader) {
            $isHeader = $false
            continue
        }

        if ([string]::IsNullOrEmpty($line)) {
            continue
        }

        $parts = $line.Split([char]"`t")
        $rows.Add([pscustomobject]@{
            link = if ($parts.Count -gt 0) { $parts[0] } else { '' }
            path = if ($parts.Count -gt 1) { $parts[1] } else { '' }
            type = if ($parts.Count -gt 2) { $parts[2] } else { '' }
            encoding = if ($parts.Count -gt 3) { $parts[3] } else { '' }
            sha256 = if ($parts.Count -gt 4) { $parts[4] } else { '' }
            size_bytes = if ($parts.Count -gt 5) { $parts[5] } else { '' }
        }) | Out-Null
    }

    return $rows.ToArray()
}

function Get-AssetExtension {
    param([string]$ContentType)

    $type = ''
    if (-not [string]::IsNullOrWhiteSpace($ContentType)) {
        $type = (($ContentType -split ';', 2)[0]).Trim().ToLowerInvariant()
    }

    switch -Regex ($type) {
        '^image/jpeg$' { return '.jpg' }
        '^image/png$' { return '.png' }
        '^image/gif$' { return '.gif' }
        '^image/webp$' { return '.webp' }
        '^image/svg\+xml$' { return '.svg' }
        '^image/avif$' { return '.avif' }
        '^image/x-icon$|^image/vnd\.microsoft\.icon$' { return '.ico' }
        '^text/css$' { return '.css' }
        '^text/html$' { return '.html' }
        '^text/plain$' { return '.txt' }
        'javascript' { return '.js' }
        'json$' { return '.json' }
        '^video/mp4$' { return '.mp4' }
        '^video/webm$' { return '.webm' }
        '^font/woff2$' { return '.woff2' }
        '^font/woff$|^application/font-woff$' { return '.woff' }
        '^font/ttf$|^application/x-font-ttf$' { return '.ttf' }
        '^font/otf$|^application/x-font-otf$' { return '.otf' }
        '^application/pdf$' { return '.pdf' }
        '^application/wasm$' { return '.wasm' }
    }

    return '.bin'
}

function Write-ManifestFile {
    param(
        [object[]]$Rows,
        [string]$Path
    )

    $writer = $null
    try {
        $writer = [System.IO.StreamWriter]::new($Path, $false, $Utf8NoBom, 1048576)
        $writer.WriteLine("link`tpath`ttype`tencoding`tsha256`tsize_bytes")
        foreach ($row in $Rows) {
            $writer.WriteLine((@(
                ConvertTo-TsvValue $row.link
                ConvertTo-TsvValue $row.path
                ConvertTo-TsvValue $row.type
                ConvertTo-TsvValue $row.encoding
                ConvertTo-TsvValue $row.sha256
                ConvertTo-TsvValue ([string]$row.size_bytes)
            ) -join "`t"))
        }
    }
    finally {
        if ($writer) {
            $writer.Dispose()
        }
    }

    [System.IO.File]::Copy($Path, ($Path + '.bak'), $true)
}

if (-not (Test-Path -LiteralPath $TsvPath)) {
    throw "TSV tidak ditemukan: $TsvPath"
}

$rows = @(Read-ManifestFile -Path $TsvPath)
$pathToRows = @{}
foreach ($row in $rows) {
    if (-not $row.path -or [System.IO.Path]::GetExtension([string]$row.path) -ine '.bin') {
        continue
    }

    $path = [string]$row.path
    if (-not $pathToRows.ContainsKey($path)) {
        $pathToRows[$path] = New-Object System.Collections.ArrayList
    }
    [void]$pathToRows[$path].Add($row)
}

$converted = 0
$skipped = 0
$missing = 0

foreach ($oldRelativePath in ($pathToRows.Keys | Sort-Object)) {
    $oldFullPath = ConvertTo-FullPath -RelativePath $oldRelativePath
    if (-not [System.IO.File]::Exists($oldFullPath)) {
        Write-Warning "File tidak ditemukan, skip: $oldRelativePath"
        $missing++
        continue
    }

    $representative = $pathToRows[$oldRelativePath][0]
    $extension = Get-AssetExtension -ContentType ([string]$representative.type)
    if ($extension -ieq '.bin') {
        $skipped++
        continue
    }

    $newFullPath = [System.IO.Path]::ChangeExtension($oldFullPath, $extension)
    $newRelativePath = ConvertTo-RelativeRootPath -FullPath $newFullPath

    if ($newFullPath -ieq $oldFullPath) {
        $skipped++
        continue
    }

    if ([System.IO.File]::Exists($newFullPath)) {
        throw "Target sudah ada, rename dibatalkan agar tidak overwrite: $newRelativePath"
    }
    elseif (-not $WhatIf) {
        [System.IO.File]::Move($oldFullPath, $newFullPath)
    }

    foreach ($row in $pathToRows[$oldRelativePath]) {
        $row.path = $newRelativePath
    }

    $converted++
    Write-Host "Convert: $oldRelativePath -> $newRelativePath"
}

if (-not $WhatIf) {
    Write-ManifestFile -Rows $rows -Path $TsvPath
}

Write-Host ''
Write-Host 'Done.'
Write-Host "Converted path : $converted"
Write-Host "Skipped .bin   : $skipped"
Write-Host "Missing files  : $missing"
Write-Host "Manifest       : $TsvPath"
if ($WhatIf) {
    Write-Host 'Mode           : WhatIf'
}
pause
