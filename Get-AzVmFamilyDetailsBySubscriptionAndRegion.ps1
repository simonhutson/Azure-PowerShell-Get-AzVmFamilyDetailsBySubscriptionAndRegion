<#
.SYNOPSIS
    List Azure VM families/series in a region that support Generation 1 (Gen1) or Generation 2 (Gen2) VMs,
    with optional filters for disk interface type and local temporary/resource disk presence.

.DESCRIPTION
    - Uses Azure PowerShell only (Get-AzComputeResourceSku).
    - Reads SKU capability metadata and keeps only VM SKUs whose HyperVGenerations includes Gen1 or Gen2.
    - Derives CPUArchitecture as Intel, AMD, or ARM from SKU metadata and Azure size naming.
    - Optionally filters by disk interface (SCSI or NVMe) using DiskControllerTypes when present.
    - Optionally requires or excludes a local temporary/resource disk by deriving it from MaxResourceVolumeMB.
    - Optionally filters by one or more CPU architectures (Intel, AMD, or ARM).
    - Optionally filters by retirement status (Available, Retirement Announced, or Retired).
    - Includes regional and zonal deployment restrictions from SKU Restrictions metadata.
    - Includes retirement status based on an optional retired sizes JSON file, or the embedded fallback list.
    - Outputs one row per VM family/series with a Skus array containing all matching SKUs.

    An Az login context is required. The script selects the subscription provided by SubscriptionId
    before querying SKU metadata, then restores the original Az context before it exits.

.NOTES
    Derived / inferred logic used by this script:
        1) Disk interface filter:
             - If DiskControllerTypes exists, the script uses it directly.
             - If DiskControllerTypes is missing and you request NVMe, the SKU is excluded because NVMe
                 cannot be inferred safely without an explicit capability value.
             - If DiskControllerTypes is missing and you request SCSI, the script treats the SKU as
                 "legacy SCSI-class" rather than excluding it.
                 This is an intentional derived rule so older Gen1-capable families without an explicit
                 DiskControllerTypes capability are still surfaced.
             - For output, missing DiskControllerTypes is shown as "SCSI (inferred)" so the column is
                 not blank while still making the derived value clear.

    2) Local temporary/resource disk filter:
       - The script derives "has local temp/resource disk" primarily from MaxResourceVolumeMB:
           > 0  => local temp/resource disk is present
           <= 0 or missing => fall back to the size-name check below
       - Fallback: newer families (for example v6/v7) do not always populate MaxResourceVolumeMB.
         The Azure size-naming convention uses the lowercase 'd' additive feature to indicate a
         local temp/resource disk, for example Standard_D2ds_v6 (has 'd') vs Standard_D2s_v6 (no 'd').
         When MaxResourceVolumeMB is missing or 0 but the size name includes the 'd' feature, the
         SKU is treated as having a local temp/resource disk.
       - This is an intentional derived rule because a simple boolean is not used here.

    3) Family/series output:
       - The script prefers the SKU Family property and normalizes it to a short family/series label
         by removing the common "standard" prefix and "Family" suffix.
       - Example: standardDsv6Family -> Dsv6
       - Casing recovery: Azure's Family metadata is sometimes mis-cased (for example DADSv5 or
         LASv3). The script recovers the documented casing from the size name (Standard_D2ads_v5 ->
         Dadsv5, Standard_L8as_v3 -> Lasv3), but only when the name-derived token matches the
         Family-derived token case-insensitively, so the family identity is never changed. A small
         override map handles known non-standard metadata values (for example DDCSv3 -> DCdsv3).
             - The Skus column contains all matching SKU names in that VM family, ordered from the
                 smallest vCPU count to the largest.

             - CPUArchitecture uses CpuArchitectureType for ARM detection. Azure reports both Intel and AMD
                 VM sizes as x64, so AMD is inferred from Azure's AMD size-series naming; remaining x64 sizes
                 are shown as Intel.

        4) Deployment restriction output:
             - RegionalDeploymentRestrictions shows Restricted when any Location restriction exists,
                 otherwise Not Restricted.
             - ZonalDeploymentRestrictions shows Not Restricted, Restricted All Zones, or
                 the specific restricted zones such as Restricted Zone 3 or Restricted Zones 1 & 2.

        5) Retirement status output:
             - RetirementStatus is based on RetiredSizesPath when provided, otherwise the embedded fallback list from:
                 https://learn.microsoft.com/azure/virtual-machines/sizes/retirement/retired-sizes-list
             - Values not listed on that page are shown as Available.

.PARAMETER Location
    Azure region to query, for example: uksouth, westeurope, eastus.

.PARAMETER SubscriptionId
    Azure subscription ID to query. Must be a valid GUID.

.PARAMETER DiskInterface
    Any   = do not filter on disk interface
    SCSI  = include SKUs that explicitly advertise SCSI, plus legacy Gen1-capable SKUs where
            DiskControllerTypes is not exposed
    NVMe  = include only SKUs that explicitly advertise NVMe

.PARAMETER LocalTemporaryDisk
    Any      = do not filter on local temp/resource disk presence
    Required = include only SKUs that have a local temp/resource disk (MaxResourceVolumeMB > 0,
               or the 'd' size-name additive feature such as Standard_D2ds_v6)
    Excluded = include only SKUs with no local temp/resource disk (MaxResourceVolumeMB <= 0 or missing,
               and no 'd' size-name additive feature)

.PARAMETER CPUArchitecture
    Accepts one or more values (comma-separated); a SKU is included if it matches any of them.
    Any   = do not filter on CPU architecture
    Intel = include Intel SKUs
    AMD   = include AMD SKUs
    ARM   = include ARM (Arm64) SKUs
    Specifying Any (alone or combined with others) includes all architectures.

.PARAMETER RetirementStatus
    Any                  = do not filter on retirement status
    Available            = include only SKUs that are not announced for retirement or retired
    Retirement Announced = include only SKUs whose retirement has been announced
    Retired              = include only SKUs that are already retired

.PARAMETER RetiredSizesPath
    Optional path to a JSON file generated by Update-RetiredAzVmSizesFile.ps1.
    When omitted, the script uses its embedded fallback retirement list.

.EXAMPLE
    .\Get-AzVmFamilyDetailsBySubscriptionAndRegion.ps1 -SubscriptionId 00000000-0000-0000-0000-000000000000 -Location uksouth -DiskInterface SCSI -LocalTemporaryDisk Required

.EXAMPLE
    .\Get-AzVmFamilyDetailsBySubscriptionAndRegion.ps1 -SubscriptionId 00000000-0000-0000-0000-000000000000 -Location uksouth

.EXAMPLE
    .\Get-AzVmFamilyDetailsBySubscriptionAndRegion.ps1 -SubscriptionId 00000000-0000-0000-0000-000000000000 -Location westeurope -DiskInterface Any -LocalTemporaryDisk Excluded 

.EXAMPLE
    .\Get-AzVmFamilyDetailsBySubscriptionAndRegion.ps1 -SubscriptionId 00000000-0000-0000-0000-000000000000 -Location uksouth -RetiredSizesPath .\retired-vm-sizes.json

.EXAMPLE
    .\Get-AzVmFamilyDetailsBySubscriptionAndRegion.ps1 -SubscriptionId 00000000-0000-0000-0000-000000000000 -Location uksouth -CPUArchitecture ARM -RetirementStatus Available

.EXAMPLE
    .\Get-AzVmFamilyDetailsBySubscriptionAndRegion.ps1 -SubscriptionId 00000000-0000-0000-0000-000000000000 -Location uksouth -CPUArchitecture Intel,AMD
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [Alias('Region')]
    [string]$Location,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [ValidateScript({
        $parsedGuid = [guid]::Empty
        if ([guid]::TryParse($_, [ref]$parsedGuid)) {
            return $true
        }

        throw 'SubscriptionId must be a valid GUID.'
    })]
    [string]$SubscriptionId,

    [ValidateSet('Any', 'SCSI', 'NVMe')]
    [string]$DiskInterface = 'Any',

    [ValidateSet('Any', 'Required', 'Excluded')]
    [string]$LocalTemporaryDisk = 'Any',

    [ValidateSet('Any', 'Intel', 'AMD', 'ARM')]
    [string[]]$CPUArchitecture = 'Any',

    [ValidateSet('Any', 'Available', 'Retirement Announced', 'Retired')]
    [string]$RetirementStatus = 'Any',

    [ValidateScript({
        if ([string]::IsNullOrWhiteSpace($_) -or (Test-Path -LiteralPath $_ -PathType Leaf)) {
            return $true
        }

        throw "RetiredSizesPath must point to an existing JSON file."
    })]
    [string]$RetiredSizesPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- Prerequisite checks ------------------------------------------------------

$requiredCommands = @('Get-AzComputeResourceSku', 'Get-AzContext', 'Set-AzContext')

foreach ($requiredCommand in $requiredCommands) {
    if (-not (Get-Command $requiredCommand -ErrorAction SilentlyContinue)) {
        throw "$requiredCommand was not found. Install/import the required Az PowerShell modules first."
    }
}

$azContext = Get-AzContext -ErrorAction SilentlyContinue
if (-not $azContext) {
    throw "No active Azure PowerShell context was found. Run Connect-AzAccount first."
}

$originalAzContext = $azContext

Write-Verbose "Selecting Azure subscription '$SubscriptionId'..."
try {
    $azContext = Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop
}
catch {
    $accountId = $originalAzContext.Account.Id
    $availableSubscriptions = @(Get-AzSubscription -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)

    if ($availableSubscriptions.Count -gt 0) {
        $availableMessage = "Subscriptions currently accessible to '$accountId': $($availableSubscriptions -join ', ')."
    }
    else {
        $availableMessage = "No subscriptions are currently accessible to '$accountId'."
    }

    throw "Unable to select subscription '$SubscriptionId'. It may belong to a different Azure AD tenant, or the signed-in account may not have access to it. $availableMessage If the subscription lives in another tenant, run 'Connect-AzAccount -Tenant <tenantId>' to sign in there, then retry. Original error: $($_.Exception.Message)"
}

# --- Helper functions ---------------------------------------------------------

function Get-CapabilityMap {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Sku
    )

    $map = @{}

    if ($null -ne $Sku.Capabilities) {
        foreach ($cap in $Sku.Capabilities) {
            if ($null -ne $cap.Name -and $null -ne $cap.Value) {
                $map[[string]$cap.Name] = [string]$cap.Value
            }
        }
    }

    return $map
}

function Split-CapabilityTokens {
    param(
        [AllowNull()]
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return @()
    }

    return @(
        $Value -split '\s*,\s*' |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object { $_.Trim() }
    )
}

function Get-ObjectPropertyValue {
    param(
        [AllowNull()]
        [object]$InputObject,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if ($null -eq $InputObject) {
        return $null
    }

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }

    return $property.Value
}

function ConvertTo-StringList {
    param(
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value) {
        return @()
    }

    if ($Value -is [string]) {
        if ([string]::IsNullOrWhiteSpace($Value)) {
            return @()
        }

        return @($Value)
    }

    return @(
        foreach ($item in $Value) {
            if (-not [string]::IsNullOrWhiteSpace([string]$item)) {
                [string]$item
            }
        }
    )
}

function Join-ValueList {
    param(
        [AllowNull()]
        [object]$Value
    )

    $values = ConvertTo-StringList -Value $Value
    return (@($values | Select-Object -Unique) -join ',')
}

function Join-UniqueText {
    param(
        [AllowNull()]
        [object]$Value
    )

    $values = ConvertTo-StringList -Value $Value |
        Where-Object { $_ -ne 'None' }

    if (-not $values) {
        return 'None'
    }

    return (@($values | Select-Object -Unique) -join '; ')
}

function Join-RetirementStatus {
    param(
        [AllowNull()]
        [object]$Value
    )

    $values = @(ConvertTo-StringList -Value $Value | Select-Object -Unique)

    if ($values -contains 'Retired') {
        return 'Retired'
    }

    if ($values -contains 'Announced' -or $values -contains 'Retirement Announced') {
        return 'Retirement Announced'
    }

    return 'Available'
}

function Join-RestrictionStatus {
    param(
        [AllowNull()]
        [object]$Value
    )

    $values = @(ConvertTo-StringList -Value $Value | Select-Object -Unique)

    if ($values -contains 'Restricted') {
        return 'Restricted'
    }

    $restrictionDetails = @($values | Where-Object { $_ -notin @('None', 'Not Restricted') })
    if ($restrictionDetails) {
        return 'Restricted'
    }

    return 'Not Restricted'
}

function Join-ZonalRestrictionStatus {
    param(
        [AllowNull()]
        [object]$Value
    )

    $values = @(ConvertTo-StringList -Value $Value | Select-Object -Unique)

    if ($values -contains 'Restricted All Zones') {
        return 'Restricted All Zones'
    }

    $restrictionDetails = @($values | Where-Object { $_ -notin @('None', 'Not Restricted') })
    if (-not $restrictionDetails) {
        return 'Not Restricted'
    }

    $restrictedZones = @()

    foreach ($restrictionDetail in $restrictionDetails) {
        $zoneMatch = [regex]::Match($restrictionDetail, '(?i)zones:\s*([0-9,\s]+)')
        if ($zoneMatch.Success) {
            $zones = @(
                $zoneMatch.Groups[1].Value -split ',' |
                ForEach-Object { $_.Trim() } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                Select-Object -Unique
            )

            if ($zones.Count -eq 3 -and $zones -contains '1' -and $zones -contains '2' -and $zones -contains '3') {
                return 'Restricted All Zones'
            }

            $restrictedZones += $zones
        }

        $formattedZoneMatch = [regex]::Match($restrictionDetail, '(?i)^Restricted Zones?\s+([0-9,&\s]+)$')
        if ($formattedZoneMatch.Success) {
            $restrictedZones += @(
                $formattedZoneMatch.Groups[1].Value -split '[,&]' |
                ForEach-Object { $_.Trim() } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
            )
        }
    }

    $restrictedZones = @($restrictedZones | Sort-Object { [int]$_ } -Unique)

    if ($restrictedZones.Count -eq 3 -and $restrictedZones -contains '1' -and $restrictedZones -contains '2' -and $restrictedZones -contains '3') {
        return 'Restricted All Zones'
    }

    if ($restrictedZones.Count -eq 1) {
        return "Restricted Zone $($restrictedZones[0])"
    }

    if ($restrictedZones.Count -gt 1) {
        return "Restricted Zones $($restrictedZones -join ' & ')"
    }

    return 'Restricted'
}

$retirementStatusByFamily = @{
    'Av2'       = 'Announced'
    'BS'        = 'Announced'
    'D'         = 'Announced'
    'DS'        = 'Announced'
    'DSv2'      = 'Announced'
    'DSv2Promo' = 'Announced'
    'Dv2'       = 'Announced'
    'Dv2Promo'  = 'Announced'
    'F'         = 'Announced'
    'FS'        = 'Announced'
    'FSv2'      = 'Announced'
    'G'         = 'Announced'
    'GS'        = 'Announced'
    'LS'        = 'Announced'
    'LSv2'      = 'Announced'
    'NCSv3'     = 'Retired'
    'NPS'       = 'Announced'
    'NVSv3'     = 'Announced'
    'NVSv4'     = 'Announced'
}

$retirementStatusBySku = @{
    'Standard_M192idms_v2' = 'Announced'
    'Standard_M192ids_v2'  = 'Announced'
    'Standard_M192ims_v2'  = 'Announced'
    'Standard_M192is_v2'   = 'Announced'
}

function Get-RetirementStatus {
    param(
        [Parameter(Mandatory = $true)]
        [string]$VMFamily,

        [Parameter(Mandatory = $true)]
        [string]$SkuName
    )

    if ($retirementStatusBySku.ContainsKey($SkuName)) {
        return $retirementStatusBySku[$SkuName]
    }

    if ($retirementStatusByFamily.ContainsKey($VMFamily)) {
        return $retirementStatusByFamily[$VMFamily]
    }

    return 'Available'
}

function Import-RetiredSizesFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $resolvedPath = Resolve-Path -LiteralPath $Path -ErrorAction Stop
    $retiredSizesData = Get-Content -LiteralPath $resolvedPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    $familyStatusByName = @{}
    $skuStatusByName = @{}

    foreach ($family in @($retiredSizesData.Families)) {
        if ($null -eq $family -or [string]::IsNullOrWhiteSpace([string]$family.Name)) {
            continue
        }

        $familyStatusByName[[string]$family.Name] = [string]$family.Status
    }

    foreach ($sku in @($retiredSizesData.Skus)) {
        if ($null -eq $sku -or [string]::IsNullOrWhiteSpace([string]$sku.Name)) {
            continue
        }

        $skuStatusByName[[string]$sku.Name] = [string]$sku.Status
    }

    if ($familyStatusByName.Count -eq 0 -and $skuStatusByName.Count -eq 0) {
        throw "Retired sizes file '$resolvedPath' did not contain any Families or Skus entries."
    }

    $script:retirementStatusByFamily = $familyStatusByName
    $script:retirementStatusBySku = $skuStatusByName

    Write-Verbose "Loaded retirement data from '$resolvedPath' ($($familyStatusByName.Count) families, $($skuStatusByName.Count) SKUs)."
}

if (-not [string]::IsNullOrWhiteSpace($RetiredSizesPath)) {
    Import-RetiredSizesFile -Path $RetiredSizesPath
}

function ConvertTo-HyperVGenerationLabel {
    param(
        [AllowNull()]
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $Value
    }

    return ($Value -replace '^(?i)V([12])$', 'Gen$1')
}

function Get-NormalizedVmFamily {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Sku
    )

    # Some Azure SKUs report a non-standard Family metadata value whose normalized form does not
    # match the documented size-series name. Map those known quirks to the documented series name.
    # Example: the confidential DCdsv3 series is reported with a Family value that normalizes to
    # 'DDCSv3' (an anagram of DCDSv3) rather than 'DCdsv3'.
    $familyDisplayOverrides = @{
        'DDCSv3' = 'DCdsv3'
    }

    # Prefer the Family property because the request is for VM families/series, not individual sizes.
    if ($Sku.PSObject.Properties.Name -contains 'Family' -and -not [string]::IsNullOrWhiteSpace($Sku.Family)) {
        $family = [string]$Sku.Family
        $family = $family -replace '^(?i)standard', ''
        $family = $family -replace '(?i)family$', ''
        # Trim whitespace left behind by the prefix/suffix removal. Some SKUs (for example the
        # GPU accelerator families NCASv3_T4 and NDAMSv4_A100) expose a Family value with spaces,
        # such as "Standard NCASv3_T4 Family", which would otherwise leave a leading/trailing space.
        $family = $family.Trim()
        if (-not [string]::IsNullOrWhiteSpace($family)) {
            if ($familyDisplayOverrides.ContainsKey($family)) {
                return $familyDisplayOverrides[$family]
            }

            # Azure's Family metadata is sometimes mis-cased (for example DADSv5 or LASv3) while the
            # size name carries the documented casing (Standard_D2ads_v5 -> Dadsv5,
            # Standard_L8as_v3 -> Lasv3). Recover the correct casing from the SKU name, but only when
            # the name-derived token matches the Family-derived token case-insensitively, so the
            # family identity is never changed (only its casing). Structurally different labels, such
            # as the accelerator families (NCASv3_T4), do not match and keep the Azure-derived label.
            $skuName = [string]$Sku.Name
            if (-not [string]::IsNullOrWhiteSpace($skuName)) {
                $normalizedName = $skuName -replace '^(?i)Standard_', ''
                $nameMatch = [regex]::Match($normalizedName, '^([A-Za-z]+)\d+(?:-\d+)?(.*)$')
                if ($nameMatch.Success) {
                    $nameFamily = ($nameMatch.Groups[1].Value + $nameMatch.Groups[2].Value) -replace '_', ''
                    if ($nameFamily -ieq $family) {
                        return $nameFamily
                    }
                }
            }

            return $family
        }
    }

    # Best-effort fallback if Family is unexpectedly absent.
    # This fallback is intentionally conservative and still returns a non-empty identifier.
    return ([string]$Sku.Name -replace '^(?i)Standard_', '')
}

function Get-CpuArchitectureOutput {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$CapabilityMap,

        [Parameter(Mandatory = $true)]
        [string]$VMFamily,

        [Parameter(Mandatory = $true)]
        [string]$SkuName
    )

    $architectureType = [string]$CapabilityMap['CpuArchitectureType']
    if ($architectureType -match '^(?i)Arm64$') {
        return 'ARM'
    }

    $normalizedSkuName = $SkuName -replace '^(?i)Standard_', ''
    $amdFamilyPattern = '(?i)^[A-Z]+a(?:l)?(?:d)?s?(?:[A-Z0-9]+)?v\d+(?:_[A-Z0-9]+)?$'
    $amdSkuPattern = '(?i)^[A-Z]+\d+[A-Z]*a(?:l)?(?:d)?s?(?:[A-Z0-9]+)?(?:_[A-Z0-9]+)?_v\d+$'

    if ($VMFamily -match $amdFamilyPattern -or $normalizedSkuName -match $amdSkuPattern) {
        return 'AMD'
    }

    return 'Intel'
}

function Test-HyperVGenerationSupport {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$CapabilityMap
    )

    $generations = Split-CapabilityTokens -Value $CapabilityMap['HyperVGenerations'] |
        ForEach-Object { ConvertTo-HyperVGenerationLabel -Value $_ }

    return ($generations -contains 'Gen1' -or $generations -contains 'Gen2')
}

function Get-HyperVGenerationsOutput {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$CapabilityMap
    )

    $generations = Split-CapabilityTokens -Value $CapabilityMap['HyperVGenerations'] |
        ForEach-Object { ConvertTo-HyperVGenerationLabel -Value $_ }

    return (@($generations) -join ',')
}

function Test-DiskInterfaceMatch {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$CapabilityMap,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Any', 'SCSI', 'NVMe')]
        [string]$RequestedInterface
    )

    if ($RequestedInterface -eq 'Any') {
        return $true
    }

    $controllers = Split-CapabilityTokens -Value $CapabilityMap['DiskControllerTypes']
    $controllers = @($controllers | ForEach-Object { $_.ToUpperInvariant() })

    switch ($RequestedInterface) {
        'NVMe' {
            # Strict rule:
            # Only include SKUs that explicitly advertise NVMe in DiskControllerTypes.
            return ($controllers -contains 'NVME')
        }

        'SCSI' {
            if ($controllers.Count -gt 0) {
                return ($controllers -contains 'SCSI')
            }

            # Derived script rule:
            # If DiskControllerTypes is absent, treat the SKU as legacy SCSI-class
            # instead of excluding it. This preserves older Gen1-capable families that
            # do not expose DiskControllerTypes explicitly in SKU metadata.
            return $true
        }
    }

    return $true
}

function Get-DiskControllerTypesOutput {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$CapabilityMap
    )

    $diskControllerTypes = $CapabilityMap['DiskControllerTypes']

    if (-not [string]::IsNullOrWhiteSpace($diskControllerTypes)) {
        return $diskControllerTypes
    }

    return 'SCSI (inferred)'
}

function Get-HasLocalTemporaryDisk {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$CapabilityMap,

        [Parameter(Mandatory = $true)]
        [string]$SkuName
    )

    # Derived script rule:
    # Use MaxResourceVolumeMB as the primary presence signal for a local temp/resource disk.
    # > 0 means the SKU exposes local temp/resource disk capacity.
    [long]$maxResourceVolumeMb = 0

    if ($CapabilityMap.ContainsKey('MaxResourceVolumeMB')) {
        [void][long]::TryParse($CapabilityMap['MaxResourceVolumeMB'], [ref]$maxResourceVolumeMb)
    }

    if ($maxResourceVolumeMb -gt 0) {
        return $true
    }

    # Fallback for newer VM families (for example v6/v7) where Azure does not populate
    # MaxResourceVolumeMB. The Azure size-naming convention uses the lowercase 'd' additive
    # feature to indicate a local temp/resource disk is present, for example:
    #   Standard_D2ds_v6 (has 'd') => local temp disk present
    #   Standard_D2s_v6  (no 'd')  => no local temp disk
    # Additive features are the lowercase letters immediately after the vCPU count.
    $normalizedSkuName = $SkuName -replace '^(?i)Standard_', ''
    $additiveMatch = [regex]::Match($normalizedSkuName, '^[A-Za-z]+\d+(?:-\d+)?([a-z]*)')
    if ($additiveMatch.Success -and $additiveMatch.Groups[1].Value -match 'd') {
        return $true
    }

    return $false
}

function Get-VcpuCount {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$CapabilityMap
    )

    [int]$vcpuCount = [int]::MaxValue

    if ($CapabilityMap.ContainsKey('vCPUs')) {
        [int]$parsedVcpuCount = 0
        if ([int]::TryParse($CapabilityMap['vCPUs'], [ref]$parsedVcpuCount)) {
            $vcpuCount = $parsedVcpuCount
        }
    }

    return $vcpuCount
}

function Get-DeploymentRestrictionsOutput {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Sku
    )

    $regionalRestrictions = @()
    $zonalRestrictions = @()
    $restrictions = Get-ObjectPropertyValue -InputObject $Sku -Name 'Restrictions'

    foreach ($restriction in @($restrictions)) {
        if ($null -eq $restriction) {
            continue
        }

        $type = [string](Get-ObjectPropertyValue -InputObject $restriction -Name 'Type')
        if ($type -notin @('Location', 'Zone')) {
            continue
        }

        $reasonCode = [string](Get-ObjectPropertyValue -InputObject $restriction -Name 'ReasonCode')
        if ([string]::IsNullOrWhiteSpace($reasonCode)) {
            $reasonCode = 'Unknown'
        }

        $restrictionInfo = Get-ObjectPropertyValue -InputObject $restriction -Name 'RestrictionInfo'
        $locations = Join-ValueList -Value (Get-ObjectPropertyValue -InputObject $restrictionInfo -Name 'Locations')
        $zones = Join-ValueList -Value (Get-ObjectPropertyValue -InputObject $restrictionInfo -Name 'Zones')
        $values = Get-ObjectPropertyValue -InputObject $restriction -Name 'Values'

        if ([string]::IsNullOrWhiteSpace($locations) -and $type -eq 'Location') {
            $locations = Join-ValueList -Value $values
        }

        if ([string]::IsNullOrWhiteSpace($zones) -and $type -eq 'Zone') {
            $zones = Join-ValueList -Value $values
        }

        $parts = @($reasonCode, "type: $type")
        if (-not [string]::IsNullOrWhiteSpace($locations)) {
            $parts += "locations: $locations"
        }

        if (-not [string]::IsNullOrWhiteSpace($zones)) {
            $parts += "zones: $zones"
        }

        $restrictionText = $parts -join ', '

        switch ($type) {
            'Location' { $regionalRestrictions += $restrictionText }
            'Zone' { $zonalRestrictions += $restrictionText }
        }
    }

    [pscustomobject]@{
        Regional = Join-RestrictionStatus -Value $regionalRestrictions
        Zonal    = Join-ZonalRestrictionStatus -Value $zonalRestrictions
    }
}

# --- Query SKU metadata -------------------------------------------------------

try {

Write-Verbose "Querying VM SKU metadata for location '$Location' using subscription '$($azContext.Subscription.Id)'..."

$vmSkus = Get-AzComputeResourceSku -Location $Location |
    Where-Object { $_.ResourceType -eq 'virtualMachines' }

# --- Apply requested filters --------------------------------------------------

$filteredVmSkus = foreach ($sku in $vmSkus) {
    $capabilityMap = Get-CapabilityMap -Sku $sku

    # Must explicitly support Gen1 or Gen2.
    if (-not (Test-HyperVGenerationSupport -CapabilityMap $capabilityMap)) {
        continue
    }

    # Disk interface filter (Any / SCSI / NVMe).
    if (-not (Test-DiskInterfaceMatch -CapabilityMap $capabilityMap -RequestedInterface $DiskInterface)) {
        continue
    }

    # Local temporary/resource disk filter.
    $skuName = [string]$sku.Name
    $hasTempDisk = Get-HasLocalTemporaryDisk -CapabilityMap $capabilityMap -SkuName $skuName

    # Use if/continue here rather than a switch. In PowerShell, 'continue' inside a switch
    # targets the switch (which is itself a looping construct), not the enclosing foreach,
    # so a switch-based filter would emit non-matching SKUs instead of skipping them.
    if ($LocalTemporaryDisk -eq 'Required' -and -not $hasTempDisk) {
        continue
    }

    if ($LocalTemporaryDisk -eq 'Excluded' -and $hasTempDisk) {
        continue
    }

    $vmFamily = Get-NormalizedVmFamily -Sku $sku

    # CPU architecture filter (Any / Intel / AMD / ARM). Accepts one or more values;
    # a SKU is kept if its architecture matches any requested value (or 'Any' is requested).
    $skuCpuArchitecture = Get-CpuArchitectureOutput -CapabilityMap $capabilityMap -VMFamily $vmFamily -SkuName $skuName
    if ($CPUArchitecture -notcontains 'Any' -and $skuCpuArchitecture -notin $CPUArchitecture) {
        continue
    }

    # Retirement status filter (Any / Available / Retirement Announced / Retired).
    # Normalize the per-SKU status with Join-RetirementStatus so it matches the displayed value.
    $skuRetirementStatus = Get-RetirementStatus -VMFamily $vmFamily -SkuName $skuName
    if ($RetirementStatus -ne 'Any' -and (Join-RetirementStatus -Value $skuRetirementStatus) -ne $RetirementStatus) {
        continue
    }

    $deploymentRestrictions = Get-DeploymentRestrictionsOutput -Sku $sku

    [pscustomobject]@{
        VMFamily                       = $vmFamily
        CPUArchitecture                = $skuCpuArchitecture
        SkuName                        = $skuName
        VcpuCount                      = Get-VcpuCount -CapabilityMap $capabilityMap
        HyperVGenerations              = Get-HyperVGenerationsOutput -CapabilityMap $capabilityMap
        DiskControllerTypes            = Get-DiskControllerTypesOutput -CapabilityMap $capabilityMap
        HasLocalTemporaryDisk          = $hasTempDisk
        RetirementStatus               = $skuRetirementStatus
        RegionalDeploymentRestrictions = $deploymentRestrictions.Regional
        ZonalDeploymentRestrictions    = $deploymentRestrictions.Zonal
    }
}

$result = $filteredVmSkus |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_.VMFamily) } |
    Sort-Object VMFamily |
    Group-Object VMFamily |
    ForEach-Object {
        $familySkus = @($_.Group)
        $sortedFamilySkus = @(
            $familySkus |
            Sort-Object VcpuCount, SkuName
        )
        $representativeSku = $sortedFamilySkus | Select-Object -First 1

        [pscustomobject]@{
            VMFamily                       = $representativeSku.VMFamily
            CPUArchitecture                = Join-UniqueText -Value $familySkus.CPUArchitecture
            HyperVGenerations              = $representativeSku.HyperVGenerations
            DiskControllerTypes            = $representativeSku.DiskControllerTypes
            HasLocalTemporaryDisk          = if (@($familySkus.HasLocalTemporaryDisk | Where-Object { $_ -eq $true }).Count -gt 0) { $true } else { $false }
            RetirementStatus               = Join-RetirementStatus -Value $familySkus.RetirementStatus
            RegionalDeploymentRestrictions = Join-RestrictionStatus -Value $familySkus.RegionalDeploymentRestrictions
            ZonalDeploymentRestrictions    = Join-ZonalRestrictionStatus -Value $familySkus.ZonalDeploymentRestrictions
            Skus                           = @($sortedFamilySkus | ForEach-Object { $_.SkuName } | Select-Object -Unique)
        }
    }

if (-not $result) {
    Write-Warning "No matching Gen1- or Gen2-capable VM families were found in location '$Location' for DiskInterface='$DiskInterface', LocalTemporaryDisk='$LocalTemporaryDisk', CPUArchitecture='$($CPUArchitecture -join ', ')', and RetirementStatus='$RetirementStatus'."
    return
}

# CLI-style table output
$tableColumns = @(
    @{ Label = 'VMFamily'; Expression = { $_.VMFamily }; Alignment = 'Left' }
    @{ Label = 'CPUArchitecture'; Expression = { $_.CPUArchitecture }; Alignment = 'Left' }
    @{ Label = 'HyperVGenerations'; Expression = { $_.HyperVGenerations }; Alignment = 'Left' }
    @{ Label = 'DiskControllerTypes'; Expression = { $_.DiskControllerTypes }; Alignment = 'Left' }
    @{ Label = 'HasLocalTemporaryDisk'; Expression = { $_.HasLocalTemporaryDisk }; Alignment = 'Left' }
    @{ Label = 'RetirementStatus'; Expression = { $_.RetirementStatus }; Alignment = 'Left' }
    @{ Label = 'RegionalDeploymentRestrictions'; Expression = { $_.RegionalDeploymentRestrictions }; Alignment = 'Left' }
    @{ Label = 'ZonalDeploymentRestrictions'; Expression = { $_.ZonalDeploymentRestrictions }; Alignment = 'Left' }
    @{ Label = 'Skus'; Expression = { $_.Skus }; Alignment = 'Left' }
)

$result | Format-Table -Property $tableColumns -AutoSize

}
finally {
    Write-Verbose "Restoring Azure subscription '$($originalAzContext.Subscription.Id)'..."
    [void](Set-AzContext -Context $originalAzContext -ErrorAction SilentlyContinue)
}