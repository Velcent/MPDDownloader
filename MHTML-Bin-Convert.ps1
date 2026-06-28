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

function Test-OctetStreamType {
    param([string]$ContentType)

    if ([string]::IsNullOrWhiteSpace($ContentType)) {
        return $true
    }

    $type = (($ContentType -split ';', 2)[0]).Trim()
    return $type -match '(?i)^application/octet-?stream$'
}

function Get-ContentTypeFromUrl {
    param([string]$Url)

    if ([string]::IsNullOrWhiteSpace($Url)) {
        return ''
    }

    try {
        $path = ([Uri]$Url).AbsolutePath.ToLowerInvariant()
    }
    catch {
        $path = $Url.ToLowerInvariant()
    }

    switch -Regex ($path) {
        '\.png$' { return 'image/png' }
        '\.(jpg|jpeg)$' { return 'image/jpeg' }
        '\.gif$' { return 'image/gif' }
        '\.webp$' { return 'image/webp' }
        '\.svg$' { return 'image/svg+xml' }
        '\.avif$' { return 'image/avif' }
        '\.(ico|cur)$' { return 'image/x-icon' }
        '\.css$' { return 'text/css' }
        '\.html?$' { return 'text/html' }
        '\.txt$' { return 'text/plain' }
        '\.m?js$' { return 'application/javascript' }
        '\.json$' { return 'application/json' }
        '\.mp4$' { return 'video/mp4' }
        '\.webm$' { return 'video/webm' }
        '\.woff2$' { return 'font/woff2' }
        '\.woff$' { return 'font/woff' }
        '\.ttf$' { return 'font/ttf' }
        '\.otf$' { return 'font/otf' }
        '\.pdf$' { return 'application/pdf' }
        '\.wasm$' { return 'application/wasm' }
    }

    return ''
}

function Get-ContentTypeFromFileHeader {
    param([string]$Path)

    $bufferSize = 4096
    $buffer = [byte[]]::new($bufferSize)
    $stream = $null
    try {
        $stream = [System.IO.FileStream]::new(
            $Path,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::Read,
            $bufferSize,
            [System.IO.FileOptions]::SequentialScan
        )
        $read = $stream.Read($buffer, 0, $buffer.Length)
    }
    finally {
        if ($stream) {
            $stream.Dispose()
        }
    }

    if ($read -lt 4) {
        return ''
    }

    if ($read -ge 8 -and $buffer[0] -eq 0x89 -and $buffer[1] -eq 0x50 -and $buffer[2] -eq 0x4e -and $buffer[3] -eq 0x47) { return 'image/png' }
    if ($buffer[0] -eq 0xff -and $buffer[1] -eq 0xd8 -and $buffer[2] -eq 0xff) { return 'image/jpeg' }
    if ($buffer[0] -eq 0x47 -and $buffer[1] -eq 0x49 -and $buffer[2] -eq 0x46) { return 'image/gif' }
    if ($read -ge 12 -and $buffer[0] -eq 0x52 -and $buffer[1] -eq 0x49 -and $buffer[2] -eq 0x46 -and $buffer[3] -eq 0x46 -and $buffer[8] -eq 0x57 -and $buffer[9] -eq 0x45 -and $buffer[10] -eq 0x42 -and $buffer[11] -eq 0x50) { return 'image/webp' }
    if ($read -ge 4 -and $buffer[0] -eq 0x25 -and $buffer[1] -eq 0x50 -and $buffer[2] -eq 0x44 -and $buffer[3] -eq 0x46) { return 'application/pdf' }
    if ($read -ge 4 -and $buffer[0] -eq 0x00 -and $buffer[1] -eq 0x00 -and $buffer[2] -eq 0x01 -and $buffer[3] -eq 0x00) { return 'image/x-icon' }
    if ($read -ge 4 -and $buffer[0] -eq 0x77 -and $buffer[1] -eq 0x4f -and $buffer[2] -eq 0x46 -and $buffer[3] -eq 0x32) { return 'font/woff2' }
    if ($read -ge 4 -and $buffer[0] -eq 0x77 -and $buffer[1] -eq 0x4f -and $buffer[2] -eq 0x46 -and $buffer[3] -eq 0x46) { return 'font/woff' }
    if ($read -ge 4 -and $buffer[0] -eq 0x00 -and $buffer[1] -eq 0x61 -and $buffer[2] -eq 0x73 -and $buffer[3] -eq 0x6d) { return 'application/wasm' }
    if ($read -ge 4 -and $buffer[0] -eq 0x00 -and $buffer[1] -eq 0x01 -and $buffer[2] -eq 0x00 -and $buffer[3] -eq 0x00) { return 'font/ttf' }
    if ($read -ge 4 -and $buffer[0] -eq 0x4f -and $buffer[1] -eq 0x54 -and $buffer[2] -eq 0x54 -and $buffer[3] -eq 0x4f) { return 'font/otf' }

    $prefix = [System.Text.Encoding]::ASCII.GetString($buffer, 0, $read)
    if ($prefix -match '(?is)^\s*(<\?xml\b[^>]*>\s*)?<svg\b') { return 'image/svg+xml' }
    if ($prefix -match '(?is)^\s*(<!doctype\s+html\b|<html\b)') { return 'text/html' }

    if ($read -ge 12 -and $prefix.Substring(4, 4) -eq 'ftyp') {
        $brandText = $prefix.Substring(8, [Math]::Min($read - 8, 64))
        if ($brandText -match 'avif|avis') { return 'image/avif' }
        if ($brandText -match 'mp4|isom|iso2|avc1|m4v') { return 'video/mp4' }
    }

    return ''
}

function Get-ResolvedContentType {
    param(
        [object]$Row,
        [string]$FullPath
    )

    $rowType = if ($Row -and (Test-ObjectProperty -Object $Row -Name 'type')) { [string]$Row.type } else { '' }
    if (-not (Test-OctetStreamType -ContentType $rowType)) {
        return (($rowType -split ';', 2)[0]).Trim()
    }

    $detectedType = Get-ContentTypeFromFileHeader -Path $FullPath
    if ($detectedType) {
        return $detectedType
    }

    $urlType = if ($Row -and (Test-ObjectProperty -Object $Row -Name 'link')) { Get-ContentTypeFromUrl -Url ([string]$Row.link) } else { '' }
    if ($urlType) {
        return $urlType
    }

    return 'application/octet-stream'
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
    $resolvedContentType = Get-ResolvedContentType -Row $representative -FullPath $oldFullPath
    $extension = Get-AssetExtension -ContentType $resolvedContentType
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
        if (Test-OctetStreamType -ContentType ([string]$row.type)) {
            $row.type = $resolvedContentType
        }
    }

    $converted++
    Write-Host "Convert: $oldRelativePath -> $newRelativePath ($resolvedContentType)"
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
