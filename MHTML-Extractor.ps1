[CmdletBinding()]
param(
    [string]$InputPath = '',
    [string]$AssetsRoot = '',
    [string]$StrippedMhtmlRoot = '',
    [string]$TsvPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Latin1 = [System.Text.Encoding]::GetEncoding(28591)
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

if (-not $InputPath) {
    $InputPath = Join-Path $PSScriptRoot 'mhtml'
}

if (-not $AssetsRoot) {
    $AssetsRoot = Join-Path $PSScriptRoot 'assets'
}

if (-not $StrippedMhtmlRoot) {
    $StrippedMhtmlRoot = Join-Path $AssetsRoot 'mhtml'
}

if (-not $TsvPath) {
    $TsvPath = Join-Path $PSScriptRoot 'mhtml-uuid.tsv'
}

$BinRoot = Join-Path $AssetsRoot 'bin'
$ScriptRootFull = [System.IO.Path]::GetFullPath($PSScriptRoot)

function ConvertTo-TsvValue {
    param([AllowNull()][string]$Value)

    if ($null -eq $Value) {
        return ''
    }

    return (($Value -replace "`t", ' ') -replace "(`r`n|`r|`n)", ' ').Trim()
}

function Get-RelativeAssetPath {
    param([string]$Uuid)

    return "assets/bin/$Uuid.bin"
}

function ConvertTo-FullPath {
    param([string]$RelativePath)

    return Join-Path $ScriptRootFull ($RelativePath -replace '/', [System.IO.Path]::DirectorySeparatorChar)
}

function New-UuidV7 {
    $bytes = New-Object byte[] 16
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $rng.GetBytes($bytes)
    }
    finally {
        $rng.Dispose()
    }

    $timestamp = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    for ($i = 5; $i -ge 0; $i--) {
        $bytes[$i] = [byte]($timestamp -band 0xff)
        $timestamp = [Int64][Math]::Floor($timestamp / 256)
    }

    $bytes[6] = [byte](($bytes[6] -band 0x0f) -bor 0x70)
    $bytes[8] = [byte](($bytes[8] -band 0x3f) -bor 0x80)

    $hex = -join ($bytes | ForEach-Object { $_.ToString('x2') })
    return '{0}-{1}-{2}-{3}-{4}' -f `
        $hex.Substring(0, 8),
        $hex.Substring(8, 4),
        $hex.Substring(12, 4),
        $hex.Substring(16, 4),
        $hex.Substring(20, 12)
}

function Get-Sha256Hex {
    param([byte[]]$Bytes)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

function Get-UnfoldedHeaderValue {
    param(
        [hashtable]$Headers,
        [string]$Name,
        [switch]$Url
    )

    $key = $Name.ToLowerInvariant()
    if (-not $Headers.ContainsKey($key)) {
        return ''
    }

    if ($Url) {
        $value = [regex]::Replace([string]$Headers[$key], "\r?\n[ \t]+", '')
        return [System.Net.WebUtility]::HtmlDecode($value.Trim())
    }

    return ([regex]::Replace([string]$Headers[$key], "\r?\n[ \t]+", ' ')).Trim()
}

function Read-MimeHeaders {
    param([string]$HeaderText)

    $headers = @{}
    $lastName = $null
    foreach ($line in [regex]::Split($HeaderText, "\r?\n")) {
        if ($line -match '^[ \t]' -and $lastName) {
            $headers[$lastName] = [string]$headers[$lastName] + "`r`n" + $line
            continue
        }

        $match = [regex]::Match($line, '^(?<name>[^:]+):\s*(?<value>.*)$')
        if ($match.Success) {
            $lastName = $match.Groups['name'].Value.Trim().ToLowerInvariant()
            $headers[$lastName] = $match.Groups['value'].Value
        }
    }

    return $headers
}

function Get-MimeBoundary {
    param([string]$ContentType)

    $match = [regex]::Match($ContentType, '(?i)(?:^|;)\s*boundary=(?:"(?<quoted>[^"]+)"|(?<plain>[^;\s]+))')
    if ($match.Success) {
        if ($match.Groups['quoted'].Success) {
            return $match.Groups['quoted'].Value
        }

        return $match.Groups['plain'].Value
    }

    return ''
}

function Get-InitialHeaderText {
    param([string]$Text)

    $separator = [regex]::Match($Text, "\r?\n\r?\n")
    if (-not $separator.Success) {
        return $Text
    }

    return $Text.Substring(0, $separator.Index)
}

function Get-MhtmlParts {
    param(
        [string]$Text,
        [string]$Boundary
    )

    $pattern = '(?m)^--' + [regex]::Escape($Boundary) + '(?<closing>--)?[ \t]*\r?$'
    $boundaryMatches = [regex]::Matches($Text, $pattern)
    if ($boundaryMatches.Count -lt 2) {
        return @()
    }

    $parts = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt ($boundaryMatches.Count - 1); $i++) {
        if ($boundaryMatches[$i].Groups['closing'].Success) {
            break
        }

        $start = $boundaryMatches[$i].Index + $boundaryMatches[$i].Length
        if ($start + 1 -lt $Text.Length -and $Text.Substring($start, 2) -eq "`r`n") {
            $start += 2
        }
        elseif ($start -lt $Text.Length -and $Text[$start] -eq "`n") {
            $start += 1
        }

        $end = $boundaryMatches[($i + 1)].Index
        $length = $end - $start
        if ($length -lt 0) {
            continue
        }

        $segment = $Text.Substring($start, $length)
        $separator = [regex]::Match($segment, "\r?\n\r?\n")
        if (-not $separator.Success) {
            continue
        }

        $headerText = $segment.Substring(0, $separator.Index)
        $bodyText = $segment.Substring($separator.Index + $separator.Length)
        if ($bodyText.EndsWith("`r`n")) {
            $bodyText = $bodyText.Substring(0, $bodyText.Length - 2)
        }
        elseif ($bodyText.EndsWith("`n")) {
            $bodyText = $bodyText.Substring(0, $bodyText.Length - 1)
        }

        $headers = Read-MimeHeaders -HeaderText $headerText

        $parts.Add([pscustomobject]@{
            Headers = $headers
            Body = $bodyText
        }) | Out-Null
    }

    return $parts
}

function Clear-MhtmlExternalPartBodies {
    param(
        [string]$Text,
        [string]$Boundary,
        [string]$SnapshotLocation,
        [System.Collections.Generic.Dictionary[string,object]]$UrlRows
    )

    $pattern = '(?m)^--' + [regex]::Escape($Boundary) + '(?<closing>--)?[ \t]*\r?$'
    $boundaryMatches = [regex]::Matches($Text, $pattern)
    if ($boundaryMatches.Count -lt 2) {
        return [pscustomobject]@{
            Text = $Text
            Cleared = 0
        }
    }

    $builder = New-Object System.Text.StringBuilder
    $builder.Append($Text.Substring(0, $boundaryMatches[0].Index)) | Out-Null
    $cleared = 0

    for ($i = 0; $i -lt ($boundaryMatches.Count - 1); $i++) {
        $current = $boundaryMatches[$i]
        $next = $boundaryMatches[($i + 1)]
        $builder.Append($current.Value) | Out-Null

        $start = $current.Index + $current.Length
        if ($start + 1 -lt $Text.Length -and $Text.Substring($start, 2) -eq "`r`n") {
            $builder.Append("`r`n") | Out-Null
            $start += 2
        }
        elseif ($start -lt $Text.Length -and $Text[$start] -eq "`n") {
            $builder.Append("`n") | Out-Null
            $start += 1
        }

        $segment = $Text.Substring($start, $next.Index - $start)
        $separator = [regex]::Match($segment, "\r?\n\r?\n")
        if (-not $separator.Success) {
            $builder.Append($segment) | Out-Null
            continue
        }

        $headerText = $segment.Substring(0, $separator.Index)
        $headers = Read-MimeHeaders -HeaderText $headerText
        $location = Get-UnfoldedHeaderValue -Headers $headers -Name 'Content-Location' -Url
        $canClear = (
            $location -and
            [regex]::IsMatch($location, '^https://') -and
            (-not $SnapshotLocation -or $location -ne $SnapshotLocation) -and
            $UrlRows.ContainsKey($location)
        )

        if ($canClear) {
            $builder.Append($headerText) | Out-Null
            $builder.Append($separator.Value) | Out-Null
            $cleared++
        }
        else {
            $builder.Append($segment) | Out-Null
        }
    }

    $last = $boundaryMatches[($boundaryMatches.Count - 1)]
    $builder.Append($Text.Substring($last.Index)) | Out-Null

    return [pscustomobject]@{
        Text = $builder.ToString()
        Cleared = $cleared
    }
}

function Decode-QuotedPrintable {
    param([string]$Text)

    $output = New-Object System.IO.MemoryStream
    try {
        for ($i = 0; $i -lt $Text.Length; $i++) {
            $ch = $Text[$i]
            if ($ch -eq '=') {
                if ($i + 2 -lt $Text.Length -and $Text[$i + 1] -eq "`r" -and $Text[$i + 2] -eq "`n") {
                    $i += 2
                    continue
                }

                if ($i + 1 -lt $Text.Length -and $Text[$i + 1] -eq "`n") {
                    $i += 1
                    continue
                }

                if ($i + 2 -lt $Text.Length) {
                    $hex = $Text.Substring($i + 1, 2)
                    if ($hex -match '^[0-9A-Fa-f]{2}$') {
                        $output.WriteByte([Convert]::ToByte($hex, 16))
                        $i += 2
                        continue
                    }
                }
            }

            $output.WriteByte([byte][char]$ch)
        }

        return $output.ToArray()
    }
    finally {
        $output.Dispose()
    }
}

function Decode-MimeBody {
    param(
        [string]$Body,
        [string]$Encoding
    )

    switch ($Encoding.ToLowerInvariant()) {
        'base64' {
            $base64 = [regex]::Replace($Body, '\s+', '')
            return [Convert]::FromBase64String($base64)
        }
        'quoted-printable' {
            return Decode-QuotedPrintable -Text $Body
        }
        default {
            return $Latin1.GetBytes($Body)
        }
    }
}

function Get-InputMhtmlFiles {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "InputPath tidak ditemukan: $Path"
    }

    $item = Get-Item -LiteralPath $Path
    if (-not $item.PSIsContainer) {
        if ($item.Extension -ieq '.mhtml') {
            return @($item)
        }

        throw "InputPath bukan file .mhtml: $Path"
    }

    return @(Get-ChildItem -LiteralPath $item.FullName -Recurse -File -Filter '*.mhtml')
}

function Get-RelativePathFromBase {
    param(
        [string]$BasePath,
        [string]$FullPath
    )

    $baseFull = [System.IO.Path]::GetFullPath($BasePath).TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    )
    $targetFull = [System.IO.Path]::GetFullPath($FullPath)

    if ($targetFull.StartsWith($baseFull + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $targetFull.Substring($baseFull.Length + 1)
    }

    return [System.IO.Path]::GetFileName($FullPath)
}

function Import-ExistingHashMap {
    param([string]$ManifestPath)

    $map = New-Object 'System.Collections.Generic.Dictionary[string,string]'
    if (-not (Test-Path -LiteralPath $ManifestPath)) {
        return $map
    }

    $rows = Import-Csv -LiteralPath $ManifestPath -Delimiter "`t"
    foreach ($row in $rows) {
        if (-not $row.sha256 -or -not $row.path) {
            continue
        }

        $fullPath = ConvertTo-FullPath -RelativePath $row.path
        if (-not (Test-Path -LiteralPath $fullPath)) {
            continue
        }

        $size = $null
        if ($row.PSObject.Properties.Name -contains 'size_bytes' -and $row.size_bytes) {
            $size = [Int64]$row.size_bytes
        }
        else {
            $size = (Get-Item -LiteralPath $fullPath).Length
        }

        $key = "$($row.sha256.ToLowerInvariant())`t$size"
        if (-not $map.ContainsKey($key)) {
            $map[$key] = $row.path
        }
    }

    return $map
}

function Import-ExistingUrlMap {
    param([string]$ManifestPath)

    $map = New-Object 'System.Collections.Generic.Dictionary[string,object]'
    if (-not (Test-Path -LiteralPath $ManifestPath)) {
        return $map
    }

    $rows = Import-Csv -LiteralPath $ManifestPath -Delimiter "`t"
    foreach ($row in $rows) {
        if (-not $row.link -or -not $row.path) {
            continue
        }

        if (-not $map.ContainsKey($row.link)) {
            $map[$row.link] = [pscustomobject]@{
                link = $row.link
                path = $row.path
                encoding = $row.encoding
                sha256 = $row.sha256
                size_bytes = $row.size_bytes
            }
        }
    }

    return $map
}

New-Item -ItemType Directory -Force -Path $BinRoot | Out-Null
New-Item -ItemType Directory -Force -Path $StrippedMhtmlRoot | Out-Null

$files = Get-InputMhtmlFiles -Path $InputPath
$inputItem = Get-Item -LiteralPath $InputPath
if ($inputItem.PSIsContainer) {
    $inputBasePath = $inputItem.FullName
}
else {
    $inputBasePath = $inputItem.DirectoryName
}
$hashToPath = Import-ExistingHashMap -ManifestPath $TsvPath
$urlToRow = Import-ExistingUrlMap -ManifestPath $TsvPath
$rows = New-Object System.Collections.Generic.List[object]
$seenRows = New-Object 'System.Collections.Generic.Dictionary[string,bool]'
$stats = [ordered]@{
    Files = 0
    ExtractedParts = 0
    WrittenFiles = 0
    ReusedFiles = 0
    ClearedPartBodies = 0
    StrippedMhtmlFiles = 0
    SkippedExistingUrls = 0
    SkippedSnapshotParts = 0
    SkippedNonHttpsParts = 0
}

foreach ($file in $files) {
    $stats.Files++
    Write-Host "Parsing $($file.FullName)"

    $text = [System.IO.File]::ReadAllText($file.FullName, $Latin1)
    $rootHeaders = Read-MimeHeaders -HeaderText (Get-InitialHeaderText -Text $text)
    $snapshotLocation = Get-UnfoldedHeaderValue -Headers $rootHeaders -Name 'Snapshot-Content-Location' -Url
    $contentType = Get-UnfoldedHeaderValue -Headers $rootHeaders -Name 'Content-Type'
    $boundary = Get-MimeBoundary -ContentType $contentType

    if (-not $boundary) {
        Write-Warning "Boundary tidak ditemukan: $($file.FullName)"
        continue
    }

    foreach ($part in Get-MhtmlParts -Text $text -Boundary $boundary) {
        $location = Get-UnfoldedHeaderValue -Headers $part.Headers -Name 'Content-Location' -Url
        if (-not $location -or $location -notmatch '^https://') {
            $stats.SkippedNonHttpsParts++
            continue
        }

        if ($snapshotLocation -and $location -eq $snapshotLocation) {
            $stats.SkippedSnapshotParts++
            continue
        }

        if ($urlToRow.ContainsKey($location)) {
            if (-not $seenRows.ContainsKey($location)) {
                $seenRows[$location] = $true
                $rows.Add($urlToRow[$location]) | Out-Null
            }

            $stats.SkippedExistingUrls++
            continue
        }

        $transferEncoding = Get-UnfoldedHeaderValue -Headers $part.Headers -Name 'Content-Transfer-Encoding'
        if (-not $transferEncoding) {
            $transferEncoding = '7bit'
        }

        if ([string]::IsNullOrEmpty($part.Body)) {
            Write-Warning "Body kosong dan URL belum ada di manifest, skip: $location"
            continue
        }

        try {
            $bytes = Decode-MimeBody -Body $part.Body -Encoding $transferEncoding
        }
        catch {
            Write-Warning "Gagal decode $location ($transferEncoding) di $($file.Name): $($_.Exception.Message)"
            continue
        }

        $sha256 = Get-Sha256Hex -Bytes $bytes
        $size = [Int64]$bytes.LongLength
        $contentKey = "$sha256`t$size"

        if ($hashToPath.ContainsKey($contentKey)) {
            $relativePath = $hashToPath[$contentKey]
            $stats.ReusedFiles++
        }
        else {
            do {
                $uuid = New-UuidV7
                $relativePath = Get-RelativeAssetPath -Uuid $uuid
                $fullPath = ConvertTo-FullPath -RelativePath $relativePath
            } while (Test-Path -LiteralPath $fullPath)

            [System.IO.File]::WriteAllBytes($fullPath, $bytes)
            $hashToPath[$contentKey] = $relativePath
            $stats.WrittenFiles++
        }

        $stats.ExtractedParts++
        $newRow = [pscustomobject]@{
            link = $location
            path = $relativePath
            encoding = $transferEncoding
            sha256 = $sha256
            size_bytes = $size
        }
        $urlToRow[$location] = $newRow
        $seenRows[$location] = $true
        $rows.Add($newRow) | Out-Null
    }

    $clearedResult = Clear-MhtmlExternalPartBodies -Text $text -Boundary $boundary -SnapshotLocation $snapshotLocation -UrlRows $urlToRow
    if ($clearedResult.Cleared -gt 0) {
        $relativeMhtmlPath = Get-RelativePathFromBase -BasePath $inputBasePath -FullPath $file.FullName
        $outputMhtmlPath = Join-Path $StrippedMhtmlRoot $relativeMhtmlPath
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $outputMhtmlPath) | Out-Null
        [System.IO.File]::WriteAllText($outputMhtmlPath, $clearedResult.Text, $Latin1)
        $stats.ClearedPartBodies += $clearedResult.Cleared
        $stats.StrippedMhtmlFiles++
    }
}

$tsvLines = New-Object System.Collections.Generic.List[string]
$tsvLines.Add("link`tpath`tencoding`tsha256`tsize_bytes") | Out-Null
foreach ($row in ($rows | Sort-Object link, path)) {
    $tsvLines.Add((
        (ConvertTo-TsvValue $row.link),
        (ConvertTo-TsvValue $row.path),
        (ConvertTo-TsvValue $row.encoding),
        (ConvertTo-TsvValue $row.sha256),
        (ConvertTo-TsvValue ([string]$row.size_bytes))
    ) -join "`t") | Out-Null
}

[System.IO.File]::WriteAllLines($TsvPath, $tsvLines, $Utf8NoBom)

Write-Host ''
Write-Host "Done."
Write-Host "Files parsed          : $($stats.Files)"
Write-Host "Parts extracted      : $($stats.ExtractedParts)"
Write-Host "Files written        : $($stats.WrittenFiles)"
Write-Host "Files reused         : $($stats.ReusedFiles)"
Write-Host "Part bodies cleared  : $($stats.ClearedPartBodies)"
Write-Host "Stripped MHTML files : $($stats.StrippedMhtmlFiles)"
Write-Host "Skipped existing URL : $($stats.SkippedExistingUrls)"
Write-Host "Skipped snapshot URL : $($stats.SkippedSnapshotParts)"
Write-Host "Skipped non-HTTPS    : $($stats.SkippedNonHttpsParts)"
Write-Host "Manifest             : $TsvPath"
Write-Host "Asset folder         : $BinRoot"
Write-Host "Stripped MHTML folder: $StrippedMhtmlRoot"
pause