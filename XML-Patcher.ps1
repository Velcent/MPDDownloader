param(
    [string]$MhtmlRoot = (Join-Path $PSScriptRoot 'mhtml'),
    [string[]]$Keys = @('LearnUE', 'LearnMH', 'LearnFN'),
    [switch]$NoBackup,
    [switch]$NoPause
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$MhtmlRoot = [System.IO.Path]::GetFullPath($MhtmlRoot)

function Get-CanonicalUrlKey {
    param([string]$PageUrl)

    try {
        $uri = [Uri]$PageUrl
        return "$($uri.Scheme.ToLowerInvariant())://$($uri.Host.ToLowerInvariant())$($uri.AbsolutePath.TrimEnd('/'))"
    }
    catch {
        return $PageUrl.TrimEnd('/').ToLowerInvariant()
    }
}

function ConvertTo-SafeText {
    param([string]$Value)

    return (([string]$Value) -replace '\s+', ' ').Trim()
}

function ConvertTo-XmlAttributeValue {
    param([string]$Value)

    return [System.Security.SecurityElement]::Escape([string]$Value)
}

function ConvertTo-RelativeRootPath {
    param([string]$Path)

    $root = [System.IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\') + '\'
    $full = [System.IO.Path]::GetFullPath($Path)
    if ($full.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $full.Substring($root.Length)
    }

    return $full
}

function Get-DirectContentAnchor {
    param($Li)

    return $Li.SelectSingleNode("./div[contains(concat(' ', normalize-space(@class), ' '), ' contents-table-el ')]/a")
}

function Get-DirectChildItems {
    param($Li)

    return @($Li.SelectNodes("./ul[contains(concat(' ', normalize-space(@class), ' '), ' contents-table-list ')]/li"))
}

function Write-LearningXml {
    param(
        [xml]$Xml,
        [string]$Path
    )

    $rootAnchor = $Xml.SelectSingleNode("/root/div[contains(concat(' ', normalize-space(@class), ' '), ' contents-table-el ')]/a")
    if (-not $rootAnchor) {
        throw "Root anchor tidak ditemukan: $Path"
    }

    $parentLis = @($Xml.SelectNodes("/root/ul[contains(concat(' ', normalize-space(@class), ' '), ' contents-table-list ')]/li"))
    $parentKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($li in $parentLis) {
        $anchor = Get-DirectContentAnchor -Li $li
        if ($anchor) {
            $href = [string]$anchor.GetAttribute('href')
            if (-not [string]::IsNullOrWhiteSpace($href)) {
                [void]$parentKeys.Add((Get-CanonicalUrlKey -PageUrl $href))
            }
        }
    }

    $removed = 0
    $lines = New-Object System.Collections.ArrayList
    $rootHref = ConvertTo-XmlAttributeValue ([string]$rootAnchor.GetAttribute('href'))
    $rootTitle = ConvertTo-XmlAttributeValue (ConvertTo-SafeText ([string]$rootAnchor.InnerText))
    [void]$lines.Add(('<div class="contents-table-el is-active is-root-entry"><a class="contents-table-link is-parent" href="{0}">{1}</a></div>' -f $rootHref, $rootTitle))
    [void]$lines.Add('<ul class="contents-table-list">')

    foreach ($li in $parentLis) {
        $anchor = Get-DirectContentAnchor -Li $li
        if (-not $anchor) {
            continue
        }

        $href = [string]$anchor.GetAttribute('href')
        if ([string]::IsNullOrWhiteSpace($href)) {
            continue
        }

        $children = New-Object System.Collections.ArrayList
        foreach ($childLi in Get-DirectChildItems -Li $li) {
            $childAnchor = Get-DirectContentAnchor -Li $childLi
            if (-not $childAnchor) {
                continue
            }

            $childHref = [string]$childAnchor.GetAttribute('href')
            if ([string]::IsNullOrWhiteSpace($childHref)) {
                continue
            }

            if ($parentKeys.Contains((Get-CanonicalUrlKey -PageUrl $childHref))) {
                $removed++
                continue
            }

            [void]$children.Add([pscustomobject]@{
                Title = ConvertTo-SafeText ([string]$childAnchor.InnerText)
                Url = $childHref
            })
        }

        $title = ConvertTo-SafeText ([string]$anchor.InnerText)
        if ([string]::IsNullOrWhiteSpace($title)) {
            $title = $href
        }

        $safeHref = ConvertTo-XmlAttributeValue $href
        $label = ConvertTo-XmlAttributeValue $title
        $publishedAt = ConvertTo-XmlAttributeValue ([string]$anchor.ParentNode.GetAttribute('data-published-at'))
        $publishedTimestamp = ConvertTo-XmlAttributeValue ([string]$anchor.ParentNode.GetAttribute('data-published-timestamp'))
        $linkClass = if ($children.Count -gt 0) { 'contents-table-link is-parent' } else { 'contents-table-link' }

        [void]$lines.Add("`t<li class=""contents-table-item"">")
        [void]$lines.Add("`t`t<div class=""contents-table-el"" data-published-at=""$publishedAt"" data-published-timestamp=""$publishedTimestamp""><a class=""$linkClass"" href=""$safeHref"">$label</a></div>")

        if ($children.Count -gt 0) {
            [void]$lines.Add("`t`t<ul class=""contents-table-list"">")
            foreach ($child in @($children)) {
                $childHref = ConvertTo-XmlAttributeValue ([string]$child.Url)
                $childLabel = ConvertTo-XmlAttributeValue ([string]$child.Title)
                [void]$lines.Add("`t`t`t<li class=""contents-table-item"">")
                [void]$lines.Add("`t`t`t`t<div class=""contents-table-el""><a class=""contents-table-link"" href=""$childHref"">$childLabel</a></div>")
                [void]$lines.Add("`t`t`t</li>")
            }
            [void]$lines.Add("`t`t</ul>")
        }

        [void]$lines.Add("`t</li>")
    }

    [void]$lines.Add('</ul>')
    Set-Content -LiteralPath $Path -Value ([string[]]$lines.ToArray()) -Encoding UTF8
    return $removed
}

foreach ($key in $Keys) {
    $path = Join-Path $MhtmlRoot "$key.xml"
    if (-not (Test-Path -LiteralPath $path)) {
        Write-Warning "File tidak ditemukan: $(ConvertTo-RelativeRootPath $path)"
        continue
    }

    $content = Get-Content -LiteralPath $path -Raw
    [xml]$xml = "<root>$content</root>"

    if (-not $NoBackup) {
        $backupPath = "$path.bak-$(Get-Date -Format 'yyyyMMddHHmmss')"
        Copy-Item -LiteralPath $path -Destination $backupPath -Force
        Write-Host "Backup: $(ConvertTo-RelativeRootPath $backupPath)"
    }

    $removed = Write-LearningXml -Xml $xml -Path $path
    Write-Host "Patch XML: $(ConvertTo-RelativeRootPath $path) ($removed child duplikat dihapus)"
}

Write-Host ""
Write-Host "Selesai patch XML learning."
if (-not $NoPause) {
    pause
}
