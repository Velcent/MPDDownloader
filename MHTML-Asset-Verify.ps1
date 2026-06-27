[CmdletBinding()]
param(
    [string]$MhtmlRoot = '',
    [string]$TsvPath = '',
    [string]$DetailOutputPath = '',
    [switch]$NoAssetFileCheck
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Latin1 = [System.Text.Encoding]::GetEncoding(28591)
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$ScriptRootFull = [System.IO.Path]::GetFullPath($PSScriptRoot)

if (-not $MhtmlRoot) {
    $MhtmlRoot = Join-Path $PSScriptRoot 'assets\mhtml'
}

if (-not $TsvPath) {
    $TsvPath = Join-Path $PSScriptRoot 'assets\mhtml-uuid.tsv'
}

if (-not $DetailOutputPath) {
    $DetailOutputPath = Join-Path $PSScriptRoot 'assets\mhtml-missing.tsv'
}

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

function Read-MimeHeaders {
    param([string]$HeaderText)

    $headers = New-Object 'System.Collections.Generic.Dictionary[string,System.Collections.Generic.List[string]]' ([System.StringComparer]::OrdinalIgnoreCase)
    $currentName = ''
    $currentValue = New-Object System.Text.StringBuilder

    foreach ($line in ($HeaderText -split "`r?`n")) {
        if ($line -match '^[ \t]+' -and $currentName) {
            [void]$currentValue.Append(' ')
            [void]$currentValue.Append($line.Trim())
            continue
        }

        if ($currentName) {
            if (-not $headers.ContainsKey($currentName)) {
                $headers[$currentName] = New-Object 'System.Collections.Generic.List[string]'
            }
            $headers[$currentName].Add($currentValue.ToString()) | Out-Null
        }

        $currentName = ''
        $currentValue.Clear() | Out-Null

        $idx = $line.IndexOf(':')
        if ($idx -le 0) {
            continue
        }

        $currentName = $line.Substring(0, $idx).Trim()
        [void]$currentValue.Append($line.Substring($idx + 1).Trim())
    }

    if ($currentName) {
        if (-not $headers.ContainsKey($currentName)) {
            $headers[$currentName] = New-Object 'System.Collections.Generic.List[string]'
        }
        $headers[$currentName].Add($currentValue.ToString()) | Out-Null
    }

    return $headers
}

function Get-UnfoldedHeaderValue {
    param(
        [System.Collections.Generic.Dictionary[string,System.Collections.Generic.List[string]]]$Headers,
        [string]$Name,
        [switch]$Url
    )

    if (-not $Headers.ContainsKey($Name) -or $Headers[$Name].Count -eq 0) {
        return ''
    }

    $value = $Headers[$Name][0].Trim()
    if ($Url) {
        $value = [System.Net.WebUtility]::HtmlDecode($value)
    }

    return $value
}

function Get-MimeBoundary {
    param([string]$ContentType)

    if ([string]::IsNullOrWhiteSpace($ContentType)) {
        return ''
    }

    $match = [regex]::Match($ContentType, '(?i)(?:^|;)\s*boundary\s*=\s*(?:"(?<q>[^"]+)"|(?<b>[^;]+))')
    if (-not $match.Success) {
        return ''
    }

    if ($match.Groups['q'].Success) {
        return $match.Groups['q'].Value
    }

    return $match.Groups['b'].Value.Trim()
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

    $parts = New-Object System.Collections.ArrayList
    $pattern = '(?m)^--' + [regex]::Escape($Boundary) + '(?<closing>--)?[ \t]*\r?$'
    $boundaryMatches = [regex]::Matches($Text, $pattern)
    if ($boundaryMatches.Count -lt 2) {
        return @()
    }

    for ($i = 0; $i -lt ($boundaryMatches.Count - 1); $i++) {
        $current = $boundaryMatches[$i]
        $next = $boundaryMatches[($i + 1)]

        if ($current.Groups['closing'].Success) {
            continue
        }

        $start = $current.Index + $current.Length
        if ($start + 1 -lt $Text.Length -and $Text.Substring($start, 2) -eq "`r`n") {
            $start += 2
        }
        elseif ($start -lt $Text.Length -and $Text[$start] -eq "`n") {
            $start += 1
        }

        $length = $next.Index - $start
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

    return [object[]]$parts
}

function Decode-QuotedPrintable {
    param([string]$Text)

    $normalized = $Text -replace "=\r?\n", ''
    $output = New-Object System.IO.MemoryStream
    try {
        for ($i = 0; $i -lt $normalized.Length; $i++) {
            $ch = $normalized[$i]
            if ($ch -eq '=' -and $i + 2 -lt $normalized.Length) {
                $hex = $normalized.Substring($i + 1, 2)
                if ($hex -match '^[0-9A-Fa-f]{2}$') {
                    $output.WriteByte([Convert]::ToByte($hex, 16))
                    $i += 2
                    continue
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

    switch -Regex ($Encoding.Trim().ToLowerInvariant()) {
        '^base64$' {
            $clean = ($Body -replace '\s+', '')
            if ([string]::IsNullOrWhiteSpace($clean)) {
                return [byte[]]::new(0)
            }
            return [Convert]::FromBase64String($clean)
        }
        '^quoted-printable$' {
            return Decode-QuotedPrintable -Text $Body
        }
        default {
            return $Latin1.GetBytes($Body)
        }
    }
}

function Resolve-AssetLink {
    param(
        [string]$RawUrl,
        [string]$BaseUrl,
        [switch]$AllowRelative
    )

    if ([string]::IsNullOrWhiteSpace($RawUrl)) {
        return ''
    }

    $value = [System.Net.WebUtility]::HtmlDecode($RawUrl.Trim())
    if ($value -match '(?i)^(data|cid|blob|javascript|mailto):') {
        return ''
    }

    try {
        if ($value.StartsWith('//')) {
            if (-not [string]::IsNullOrWhiteSpace($BaseUrl)) {
                $baseUri = [Uri]$BaseUrl
                return "$($baseUri.Scheme):$value"
            }

            return "https:$value"
        }

        if ([Uri]::IsWellFormedUriString($value, [UriKind]::Absolute)) {
            return ([Uri]$value).AbsoluteUri
        }

        if ($AllowRelative) {
            return $value
        }

        if (-not [string]::IsNullOrWhiteSpace($BaseUrl)) {
            return ([Uri]::new([Uri]$BaseUrl, $value)).AbsoluteUri
        }
    }
    catch {
    }

    return ''
}

function Resolve-ExternalUrl {
    param(
        [string]$RawUrl,
        [string]$BaseUrl
    )

    if ([string]::IsNullOrWhiteSpace($RawUrl)) {
        return ''
    }

    $value = [System.Net.WebUtility]::HtmlDecode($RawUrl.Trim())
    if ($value -match '(?i)^(data|cid|blob|javascript|mailto):') {
        return ''
    }

    try {
        if ($value.StartsWith('//')) {
            $baseUri = [Uri]$BaseUrl
            return "$($baseUri.Scheme):$value"
        }

        if ([Uri]::IsWellFormedUriString($value, [UriKind]::Absolute)) {
            return ([Uri]$value).AbsoluteUri
        }

        if (-not [string]::IsNullOrWhiteSpace($BaseUrl)) {
            return ([Uri]::new([Uri]$BaseUrl, $value)).AbsoluteUri
        }
    }
    catch {
    }

    return ''
}

function Get-HtmlBaseUrl {
    param(
        [string]$Html,
        [string]$FallbackUrl
    )

    $match = [regex]::Match($Html, '(?is)<base\b[^>]*\bhref\s*=\s*(?:"(?<dq>[^"]*)"|''(?<sq>[^'']*)''|(?<bare>[^\s>]+))')
    if ($match.Success) {
        foreach ($name in @('dq', 'sq', 'bare')) {
            if ($match.Groups[$name].Success) {
                $base = Resolve-AssetLink -RawUrl $match.Groups[$name].Value -BaseUrl $FallbackUrl
                if ($base) {
                    return $base
                }
            }
        }
    }

    return $FallbackUrl
}

function Get-ImgUrlsFromHtml {
    param(
        [string]$Html,
        [string]$BaseUrl
    )

    $urls = New-Object 'System.Collections.Generic.List[string]'
    $seen = New-Object 'System.Collections.Generic.Dictionary[string,bool]'

    foreach ($img in [regex]::Matches($Html, '(?is)<img\b(?<attrs>[^>]*)>')) {
        $attrs = $img.Groups['attrs'].Value

        foreach ($attr in [regex]::Matches($attrs, '(?is)\bsrc\s*=\s*(?:"(?<dq>[^"]*)"|''(?<sq>[^'']*)''|(?<bare>[^\s>]+))')) {
            foreach ($name in @('dq', 'sq', 'bare')) {
                if ($attr.Groups[$name].Success) {
                    $url = Resolve-ExternalUrl -RawUrl $attr.Groups[$name].Value -BaseUrl $BaseUrl
                    if ($url -and $url -match '^https://' -and -not $seen.ContainsKey($url)) {
                        $seen[$url] = $true
                        $urls.Add($url) | Out-Null
                    }
                    break
                }
            }
        }

        foreach ($attr in [regex]::Matches($attrs, '(?is)\bsrcset\s*=\s*(?:"(?<dq>[^"]*)"|''(?<sq>[^'']*)''|(?<bare>[^\s>]+))')) {
            $srcset = ''
            foreach ($name in @('dq', 'sq', 'bare')) {
                if ($attr.Groups[$name].Success) {
                    $srcset = $attr.Groups[$name].Value
                    break
                }
            }

            foreach ($candidate in ($srcset -split ',')) {
                $raw = (($candidate.Trim() -split '\s+', 2)[0])
                $url = Resolve-ExternalUrl -RawUrl $raw -BaseUrl $BaseUrl
                if ($url -and $url -match '^https://' -and -not $seen.ContainsKey($url)) {
                    $seen[$url] = $true
                    $urls.Add($url) | Out-Null
                }
            }
        }
    }

    return @($urls)
}

function Add-AssetReference {
    param(
        [System.Collections.ArrayList]$Results,
        [hashtable]$Seen,
        [string]$Link,
        [string]$Source
    )

    if ([string]::IsNullOrWhiteSpace($Link) -or $Link -notmatch '^https://') {
        return
    }

    if ($Seen.ContainsKey($Link)) {
        return
    }

    $Seen[$Link] = $true
    [void]$Results.Add([pscustomobject]@{
        link = $Link
        source = $Source
    })
}

function Get-HttpsBackgroundUrlsFromCss {
    param(
        [string]$CssText,
        [string]$BaseUrl
    )

    $urls = New-Object System.Collections.ArrayList
    $seen = @{}

    foreach ($declaration in [regex]::Matches($CssText, '(?is)\bbackground(?:-image)?\s*:\s*(?<value>[^;{}]+)')) {
        $value = $declaration.Groups['value'].Value
        foreach ($urlMatch in [regex]::Matches($value, '(?is)url\(\s*(?:"(?<dq>[^"]*)"|''(?<sq>[^'']*)''|(?<bare>[^)\s]+))\s*\)')) {
            foreach ($name in @('dq', 'sq', 'bare')) {
                if ($urlMatch.Groups[$name].Success) {
                    $url = Resolve-ExternalUrl -RawUrl $urlMatch.Groups[$name].Value -BaseUrl $BaseUrl
                    if ($url -and $url -match '^https://' -and -not $seen.ContainsKey($url)) {
                        $seen[$url] = $true
                        [void]$urls.Add($url)
                    }
                    break
                }
            }
        }
    }

    return [object[]]$urls
}

function Get-AssetReferencesFromHtml {
    param(
        [string]$Html,
        [string]$BaseUrl
    )

    $results = New-Object System.Collections.ArrayList
    $seen = @{}

    foreach ($imgUrl in Get-ImgUrlsFromHtml -Html $Html -BaseUrl $BaseUrl) {
        Add-AssetReference -Results $results -Seen $seen -Link $imgUrl -Source 'img'
    }

    foreach ($video in [regex]::Matches($Html, '(?is)<video\b(?<attrs>[^>]*)>')) {
        $attrs = $video.Groups['attrs'].Value
        foreach ($attr in [regex]::Matches($attrs, '(?is)\bposter\s*=\s*(?:"(?<dq>[^"]*)"|''(?<sq>[^'']*)''|(?<bare>[^\s>]+))')) {
            foreach ($name in @('dq', 'sq', 'bare')) {
                if ($attr.Groups[$name].Success) {
                    $url = Resolve-ExternalUrl -RawUrl $attr.Groups[$name].Value -BaseUrl $BaseUrl
                    if ($url -and $url -match '^https://') {
                        Add-AssetReference -Results $results -Seen $seen -Link $url -Source 'video-poster'
                    }
                    break
                }
            }
        }
    }

    foreach ($styleBlock in [regex]::Matches($Html, '(?is)<style\b[^>]*>(?<css>.*?)</style>')) {
        foreach ($cssUrl in Get-HttpsBackgroundUrlsFromCss -CssText $styleBlock.Groups['css'].Value -BaseUrl $BaseUrl) {
            Add-AssetReference -Results $results -Seen $seen -Link $cssUrl -Source 'style-block'
        }
    }

    foreach ($styleAttr in [regex]::Matches($Html, '(?is)\bstyle\s*=\s*(?:"(?<dq>[^"]*)"|''(?<sq>[^'']*)'')')) {
        foreach ($name in @('dq', 'sq')) {
            if ($styleAttr.Groups[$name].Success) {
                foreach ($cssUrl in Get-HttpsBackgroundUrlsFromCss -CssText $styleAttr.Groups[$name].Value -BaseUrl $BaseUrl) {
                    Add-AssetReference -Results $results -Seen $seen -Link $cssUrl -Source 'style-attr'
                }
                break
            }
        }
    }

    return [object[]]$results
}

function Import-ManifestMap {
    param([string]$Path)

    $map = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([System.StringComparer]::Ordinal)
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Manifest tidak ditemukan: $Path"
    }

    foreach ($row in (Import-Csv -LiteralPath $Path -Delimiter "`t")) {
        if (-not $row.link) {
            continue
        }

        if (-not $map.ContainsKey([string]$row.link)) {
            $map[[string]$row.link] = $row
        }
    }

    return $map
}

function Add-MissingRow {
    param(
        [System.Collections.ArrayList]$Rows,
        [hashtable]$Seen,
        [string]$MhtmlPath,
        [string]$RelativeMhtmlPath,
        [string]$AssetUrl,
        [string]$Reason,
        [string]$Source,
        [string]$ManifestPath = ''
    )

    $key = "$RelativeMhtmlPath`t$AssetUrl`t$Reason`t$Source"
    if ($Seen.ContainsKey($key)) {
        return
    }

    $Seen[$key] = $true
    [void]$Rows.Add([pscustomobject]@{
        mhtml_file = $MhtmlPath
        relative_mhtml_file = $RelativeMhtmlPath
        asset_url = $AssetUrl
        reason = $Reason
        source = $Source
        manifest_path = $ManifestPath
    })
}

function Test-ManifestAsset {
    param(
        [System.Collections.Generic.Dictionary[string,object]]$ManifestMap,
        [string]$AssetUrl
    )

    if (-not $ManifestMap.ContainsKey($AssetUrl)) {
        return [pscustomobject]@{
            Ok = $false
            Reason = 'missing_manifest_url'
            ManifestPath = ''
        }
    }

    $row = $ManifestMap[$AssetUrl]
    $path = if ((Test-ObjectProperty -Object $row -Name 'path') -and $row.path) { [string]$row.path } else { '' }
    if (-not $NoAssetFileCheck -and -not [string]::IsNullOrWhiteSpace($path)) {
        $fullPath = ConvertTo-FullPath -RelativePath $path
        if (-not (Test-Path -LiteralPath $fullPath)) {
            return [pscustomobject]@{
                Ok = $false
                Reason = 'missing_asset_file'
                ManifestPath = $path
            }
        }
    }

    return [pscustomobject]@{
        Ok = $true
        Reason = ''
        ManifestPath = $path
    }
}

if (-not (Test-Path -LiteralPath $MhtmlRoot)) {
    throw "Folder MHTML tidak ditemukan: $MhtmlRoot"
}

Write-Host "Load manifest: $TsvPath"
$manifestMap = Import-ManifestMap -Path $TsvPath
Write-Host "Manifest URL : $($manifestMap.Count)"

$mhtmlFiles = @(Get-ChildItem -LiteralPath $MhtmlRoot -Recurse -File -Filter '*.mhtml' | Sort-Object FullName)
Write-Host "Scan MHTML   : $($mhtmlFiles.Count) file"

$missingRows = New-Object System.Collections.ArrayList
$seenMissing = @{}
$filesWithMissing = New-Object 'System.Collections.Generic.Dictionary[string,bool]' ([System.StringComparer]::OrdinalIgnoreCase)
$stats = [ordered]@{
    Files = 0
    FilesWithMissing = 0
    MissingManifestUrls = 0
    MissingAssetFiles = 0
    ParseWarnings = 0
}

foreach ($file in $mhtmlFiles) {
    $stats.Files++
    $relativeFile = Get-RelativePathFromBase -BasePath $MhtmlRoot -FullPath $file.FullName
    Write-Host "Verify $relativeFile"

    try {
        $text = [System.IO.File]::ReadAllText($file.FullName, $Latin1)
        $rootHeaders = Read-MimeHeaders -HeaderText (Get-InitialHeaderText -Text $text)
        $snapshotLocation = Get-UnfoldedHeaderValue -Headers $rootHeaders -Name 'Snapshot-Content-Location' -Url
        $contentType = Get-UnfoldedHeaderValue -Headers $rootHeaders -Name 'Content-Type'
        $boundary = Get-MimeBoundary -ContentType $contentType
        if (-not $boundary) {
            Write-Warning "Boundary tidak ditemukan: $($file.FullName)"
            $stats.ParseWarnings++
            continue
        }

        $parts = @(Get-MhtmlParts -Text $text -Boundary $boundary)
        foreach ($part in $parts) {
            $location = Get-UnfoldedHeaderValue -Headers $part.Headers -Name 'Content-Location' -Url
            if ($location -and $location -match '^https://' -and (-not $snapshotLocation -or $location -ne $snapshotLocation)) {
                $result = Test-ManifestAsset -ManifestMap $manifestMap -AssetUrl $location
                if (-not $result.Ok) {
                    Add-MissingRow -Rows $missingRows -Seen $seenMissing -MhtmlPath $file.FullName -RelativeMhtmlPath $relativeFile -AssetUrl $location -Reason $result.Reason -Source 'mime-part' -ManifestPath $result.ManifestPath
                    $filesWithMissing[$file.FullName] = $true
                    if ($result.Reason -eq 'missing_asset_file') { $stats.MissingAssetFiles++ } else { $stats.MissingManifestUrls++ }
                }
            }

            $partContentType = Get-UnfoldedHeaderValue -Headers $part.Headers -Name 'Content-Type'
            if ($partContentType) {
                $partContentType = (($partContentType -split ';', 2)[0]).Trim()
            }

            if ($partContentType -notmatch '(?i)^text/(html|css)\b' -or [string]::IsNullOrEmpty($part.Body)) {
                continue
            }

            $encoding = Get-UnfoldedHeaderValue -Headers $part.Headers -Name 'Content-Transfer-Encoding'
            if (-not $encoding) {
                $encoding = '7bit'
            }

            try {
                $bytes = Decode-MimeBody -Body $part.Body -Encoding $encoding
                $partText = [System.Text.Encoding]::UTF8.GetString($bytes)
            }
            catch {
                $stats.ParseWarnings++
                Write-Warning "Gagal decode text part: $($file.FullName) - $($_.Exception.Message)"
                continue
            }

            $partLocation = Get-UnfoldedHeaderValue -Headers $part.Headers -Name 'Content-Location' -Url
            if ($partContentType -match '(?i)^text/html\b') {
                $fallbackUrl = if ($partLocation) { $partLocation } else { $snapshotLocation }
                $baseUrl = Get-HtmlBaseUrl -Html $partText -FallbackUrl $fallbackUrl
                $refs = @(Get-AssetReferencesFromHtml -Html $partText -BaseUrl $baseUrl)
            }
            else {
                $baseUrl = if ($partLocation) { $partLocation } else { $snapshotLocation }
                $refs = @()
                foreach ($link in Get-HttpsBackgroundUrlsFromCss -CssText $partText -BaseUrl $baseUrl) {
                    $refs += [pscustomobject]@{
                        link = $link
                        source = 'css-ref'
                    }
                }
            }

            foreach ($ref in $refs) {
                if (-not $ref.link -or [string]$ref.link -notmatch '^https://') {
                    continue
                }

                $result = Test-ManifestAsset -ManifestMap $manifestMap -AssetUrl ([string]$ref.link)
                if (-not $result.Ok) {
                    Add-MissingRow -Rows $missingRows -Seen $seenMissing -MhtmlPath $file.FullName -RelativeMhtmlPath $relativeFile -AssetUrl ([string]$ref.link) -Reason $result.Reason -Source ([string]$ref.source) -ManifestPath $result.ManifestPath
                    $filesWithMissing[$file.FullName] = $true
                    if ($result.Reason -eq 'missing_asset_file') { $stats.MissingAssetFiles++ } else { $stats.MissingManifestUrls++ }
                }
            }
        }
    }
    catch {
        $stats.ParseWarnings++
        Write-Warning "Gagal verify $($file.FullName): $($_.Exception.Message)"
    }
}

$stats.FilesWithMissing = $filesWithMissing.Count

$detailLines = New-Object System.Collections.Generic.List[string]
$detailLines.Add("mhtml_file`trelative_mhtml_file`tasset_url`treason`tsource`tmanifest_path") | Out-Null
foreach ($row in $missingRows) {
    $detailLines.Add((@(
        ConvertTo-TsvValue $row.mhtml_file
        ConvertTo-TsvValue $row.relative_mhtml_file
        ConvertTo-TsvValue $row.asset_url
        ConvertTo-TsvValue $row.reason
        ConvertTo-TsvValue $row.source
        ConvertTo-TsvValue $row.manifest_path
    ) -join "`t")) | Out-Null
}

New-Item -ItemType Directory -Force -Path (Split-Path -Parent $DetailOutputPath) | Out-Null
[System.IO.File]::WriteAllLines($DetailOutputPath, $detailLines, $Utf8NoBom)

Write-Host ''
Write-Host 'Done.'
Write-Host "Files checked        : $($stats.Files)"
Write-Host "Files with missing   : $($stats.FilesWithMissing)"
Write-Host "Missing manifest URL : $($stats.MissingManifestUrls)"
Write-Host "Missing asset file   : $($stats.MissingAssetFiles)"
Write-Host "Parse warnings       : $($stats.ParseWarnings)"
Write-Host "Output TSV           : $DetailOutputPath"
pause
