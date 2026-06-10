<#
.SYNOPSIS
    Fetch the Microsoft Learn retired Azure VM size series list and write a JSON data file.

.DESCRIPTION
    Downloads the raw Microsoft Learn markdown source for the retired Azure VM size series page,
    parses rows with a Retired or Announced retirement status, normalizes size series names to the
    VM family names used by Get-AzVmFamilyDetailsBySubscriptionAndRegion.ps1, and writes a JSON file that can be passed to
    Get-AzVmFamilyDetailsBySubscriptionAndRegion.ps1 with -RetiredSizesPath.

.PARAMETER OutputPath
    Path of the JSON file to write.

.PARAMETER SourceUrl
    Raw markdown URL for the Microsoft Learn retired sizes article.

.EXAMPLE
    .\Update-RetiredAzVmSizesFile.ps1 -OutputPath .\retired-vm-sizes.json
#>

[CmdletBinding()]
param(
    [string]$OutputPath = (Join-Path $PSScriptRoot 'retired-vm-sizes.json'),

    [string]$SourceUrl = 'https://raw.githubusercontent.com/MicrosoftDocs/azure-compute-docs/main/articles/virtual-machines/sizes/retirement/retired-sizes-list.md'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertFrom-MarkdownText {
    param(
        [AllowNull()]
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return ''
    }

    $text = [System.Net.WebUtility]::HtmlDecode($Value)
    $text = [regex]::Replace($text, '\[([^\]]+)\]\([^\)]+\)', '$1')
    $text = $text -replace '\*\*|\*|`', ''
    $text = $text -replace '\s+', ' '
    return $text.Trim()
}

function Get-RetiredSizeNames {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SeriesName
    )

    $name = ConvertFrom-MarkdownText -Value $SeriesName

    if ($name -match '^(?i)Standard_') {
        return @(
            [pscustomobject]@{
                Type = 'Sku'
                Name = $name
            }
        )
    }

    $name = $name -replace '\s*\([^\)]*\)', ''
    $name = $name -replace '(?i)\s*-?\s*series$', ''
    $name = $name -replace '\s+', ''

    $familyNameMap = @{
        'Amv2'       = 'Av2'
        'B'          = 'BS'
        'Ds'         = 'DS'
        'Dsv2'       = 'DSv2'
        'Fs'         = 'FS'
        'Fsv2'       = 'FSv2'
        'Gs'         = 'GS'
        'Ls'         = 'LS'
        'Lsv2'       = 'LSv2'
        'NCv3'       = 'NCSv3'
        'NCv3-NC24rs' = 'NCSv3'
        'NVv3'       = 'NVSv3'
        'NVv4'       = 'NVSv4'
        'NP'         = 'NPS'
    }

    return @(
        foreach ($part in ($name -split '/')) {
            if ([string]::IsNullOrWhiteSpace($part)) {
                continue
            }

            $normalizedName = $part
            if ($familyNameMap.ContainsKey($part)) {
                $normalizedName = $familyNameMap[$part]
            }

            [pscustomobject]@{
                Type = 'Family'
                Name = $normalizedName
            }
        }
    ) | Sort-Object Type, Name -Unique
}

Write-Verbose "Fetching retired Azure VM size series data from '$SourceUrl'..."
$markdown = (Invoke-WebRequest -Uri $SourceUrl -UseBasicParsing -ErrorAction Stop).Content
$rows = @()

foreach ($line in ($markdown -split "`r?`n")) {
    if ($line -notmatch '^\s*\|') {
        continue
    }

    $cells = @(
        $line.Trim().Trim('|') -split '\|' |
        ForEach-Object { ConvertFrom-MarkdownText -Value $_ }
    )

    if ($cells.Count -lt 4 -or $cells[1] -notin @('Announced', 'Retired')) {
        continue
    }

    foreach ($normalizedSize in (Get-RetiredSizeNames -SeriesName $cells[0])) {
        $rows += [pscustomobject]@{
            Type                       = $normalizedSize.Type
            Name                       = $normalizedSize.Name
            Status                     = $cells[1]
            SourceName                 = $cells[0]
            RetirementAnnouncement     = $cells[2]
            PlannedRetirementDate      = $cells[3]
        }
    }
}

if ($rows.Count -eq 0) {
    throw "No retired size rows were parsed from '$SourceUrl'."
}

$families = @($rows | Where-Object { $_.Type -eq 'Family' } | Sort-Object Name -Unique)
$skus = @($rows | Where-Object { $_.Type -eq 'Sku' } | Sort-Object Name -Unique)

$output = [pscustomobject]@{
    SourceUrl      = $SourceUrl
    LearnUrl       = 'https://learn.microsoft.com/azure/virtual-machines/sizes/retirement/retired-sizes-list'
    GeneratedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    Families       = $families
    Skus           = $skus
}

$resolvedOutputPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
$outputDirectory = Split-Path -Path $resolvedOutputPath -Parent

if (-not [string]::IsNullOrWhiteSpace($outputDirectory) -and -not (Test-Path -LiteralPath $outputDirectory -PathType Container)) {
    New-Item -Path $outputDirectory -ItemType Directory -Force | Out-Null
}

$output | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $resolvedOutputPath -Encoding UTF8
Write-Host "Wrote $($families.Count) retired VM families and $($skus.Count) retired VM SKUs to '$resolvedOutputPath'."