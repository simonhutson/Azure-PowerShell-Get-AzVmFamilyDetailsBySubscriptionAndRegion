#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Pester tests for the -LocalTemporaryDisk behaviour of
    Get-AzVmFamilyDetailsBySubscriptionAndRegion.ps1.

.DESCRIPTION
    These tests stub the Azure PowerShell cmdlets (Get-AzContext, Set-AzContext,
    Get-AzComputeResourceSku) so the script can run end-to-end without an Azure
    connection. Synthetic VM SKUs exercise the two ways the script detects a local
    temporary/resource disk:
        1. MaxResourceVolumeMB > 0 (older families).
        2. The lowercase 'd' additive feature in the size name (newer v6/v7 families
           where Azure does not populate MaxResourceVolumeMB).

    Run with:
        Invoke-Pester -Path .\Get-AzVmFamilyDetailsBySubscriptionAndRegion.Tests.ps1
#>

Describe 'Get-AzVmFamilyDetailsBySubscriptionAndRegion -LocalTemporaryDisk' {

    BeforeAll {
        $script:ScriptUnderTest = Join-Path $PSScriptRoot 'Get-AzVmFamilyDetailsBySubscriptionAndRegion.ps1'
        $script:TestSubscriptionId = '00000000-0000-0000-0000-000000000000'
        $script:MockContext = [pscustomobject]@{
            Subscription = [pscustomobject]@{ Id = $script:TestSubscriptionId }
        }

        # Builds a synthetic object shaped like the output of Get-AzComputeResourceSku.
        function New-MockSku {
            param(
                [Parameter(Mandatory)][string]$Name,
                [Parameter(Mandatory)][string]$Family,
                [string]$HyperVGenerations = 'V1,V2',
                [string]$DiskControllerTypes,
                [Nullable[long]]$MaxResourceVolumeMB,
                [string]$Vcpus = '2',
                [string]$CpuArchitectureType = 'x64'
            )

            $capabilities = [System.Collections.Generic.List[object]]::new()
            $capabilities.Add([pscustomobject]@{ Name = 'HyperVGenerations'; Value = $HyperVGenerations })

            if (-not [string]::IsNullOrWhiteSpace($DiskControllerTypes)) {
                $capabilities.Add([pscustomobject]@{ Name = 'DiskControllerTypes'; Value = $DiskControllerTypes })
            }

            if ($null -ne $MaxResourceVolumeMB) {
                $capabilities.Add([pscustomobject]@{ Name = 'MaxResourceVolumeMB'; Value = [string]$MaxResourceVolumeMB })
            }

            $capabilities.Add([pscustomobject]@{ Name = 'vCPUs'; Value = $Vcpus })
            $capabilities.Add([pscustomobject]@{ Name = 'CpuArchitectureType'; Value = $CpuArchitectureType })

            [pscustomobject]@{
                ResourceType = 'virtualMachines'
                Name         = $Name
                Family       = $Family
                Capabilities = $capabilities.ToArray()
                Restrictions = @()
            }
        }

        # Stub Azure cmdlets so the script runs without Azure. [CmdletBinding()] makes the
        # common parameters (for example -ErrorAction) bind without being declared explicitly.
        function Get-AzContext { [CmdletBinding()] param() $script:MockContext }
        function Set-AzContext { [CmdletBinding()] param($Context, $SubscriptionId) $script:MockContext }
        function Get-AzComputeResourceSku { [CmdletBinding()] param($Location) $script:MockSkus }

        # Synthetic SKUs covering every local-temp-disk detection path. Family labels use the
        # documented casing recovered from the size name (Azure metadata is all-uppercase).
        #   Dsv3  : two SKUs, temp disk via MaxResourceVolumeMB (older family)  -> True
        #   Ddsv6 : 'd' in name, no MaxResourceVolumeMB (newer NVMe family)     -> True
        #   Edsv5 : 'd' in a constrained-vCPU name, no MaxResourceVolumeMB      -> True
        #   Dsv6  : no 'd', no MaxResourceVolumeMB                              -> False
        #   Dasv5 : no 'd', MaxResourceVolumeMB = 0                            -> False
        $script:FullMockSkus = @(
            New-MockSku -Name 'Standard_D2s_v3'    -Family 'standardDSv3Family'  -MaxResourceVolumeMB 16384
            New-MockSku -Name 'Standard_D4s_v3'    -Family 'standardDSv3Family'  -MaxResourceVolumeMB 32768 -Vcpus '4'
            New-MockSku -Name 'Standard_D2ds_v6'   -Family 'standardDDSv6Family' -DiskControllerTypes 'NVMe'
            New-MockSku -Name 'Standard_E8-2ds_v5' -Family 'standardEDSv5Family' -Vcpus '8'
            New-MockSku -Name 'Standard_D2s_v6'    -Family 'standardDSv6Family'  -DiskControllerTypes 'NVMe'
            New-MockSku -Name 'Standard_D2as_v5'   -Family 'standardDASv5Family' -MaxResourceVolumeMB 0
        )

        # Synthetic SKUs for the CPU-architecture and retirement-status filters. Family labels use
        # the documented casing recovered from the size name.
        #   Dsv5  : Intel, Available
        #   Dasv5 : AMD,   Available
        #   Dpsv6 : ARM,   Available
        #   Fsv2  : Intel, Retirement Announced (embedded retirement map)
        #   NCsv3 : Intel, Retired              (embedded retirement map)
        $script:FilterMockSkus = @(
            New-MockSku -Name 'Standard_D2s_v5'  -Family 'standardDSv5Family'  -MaxResourceVolumeMB 16384 -CpuArchitectureType 'x64'
            New-MockSku -Name 'Standard_D2as_v5' -Family 'standardDASv5Family' -MaxResourceVolumeMB 16384 -CpuArchitectureType 'x64'
            New-MockSku -Name 'Standard_D2ps_v6' -Family 'standardDPSv6Family' -DiskControllerTypes 'NVMe' -CpuArchitectureType 'Arm64'
            New-MockSku -Name 'Standard_F2s_v2'  -Family 'standardFSv2Family'  -MaxResourceVolumeMB 8192  -CpuArchitectureType 'x64'
            New-MockSku -Name 'Standard_NC6s_v3' -Family 'standardNCSv3Family' -MaxResourceVolumeMB 8192  -CpuArchitectureType 'x64'
        )

        # Dot-source the script once with no SKUs so its functions (for example
        # Get-HasLocalTemporaryDisk) are available to the unit tests below.
        $script:MockSkus = @()
        . $script:ScriptUnderTest -Location 'uksouth' -SubscriptionId $script:TestSubscriptionId -WarningAction SilentlyContinue

        # Helper that runs the full script pipeline against $script:FullMockSkus and
        # returns the family-level result objects for a given -LocalTemporaryDisk value.
        function Invoke-ScriptForLocalTemporaryDisk {
            param([Parameter(Mandatory)][string]$LocalTemporaryDisk)

            $script:MockSkus = $script:FullMockSkus

            # Dot-source so the script's $result variable lands in this scope. Discard the
            # script's own pipeline output (the Format-Table view) so only $result is returned.
            $null = . $script:ScriptUnderTest `
                -Location 'uksouth' `
                -SubscriptionId $script:TestSubscriptionId `
                -LocalTemporaryDisk $LocalTemporaryDisk `
                -WarningAction SilentlyContinue
            return $result
        }

        # Runs the full script pipeline against a given SKU set and parameter splat,
        # returning the family-level result objects. Discards the Format-Table output.
        function Invoke-ScriptResult {
            param(
                [Parameter(Mandatory)][object[]]$Skus,
                [hashtable]$Parameters = @{}
            )

            $script:MockSkus = $Skus
            $splat = @{
                Location       = 'uksouth'
                SubscriptionId = $script:TestSubscriptionId
                WarningAction  = 'SilentlyContinue'
            }
            foreach ($key in $Parameters.Keys) { $splat[$key] = $Parameters[$key] }

            $null = . $script:ScriptUnderTest @splat
            return $result
        }
    }

    Context 'Get-HasLocalTemporaryDisk (unit)' {
        It 'returns True when MaxResourceVolumeMB > 0 even without a d in the name' {
            Get-HasLocalTemporaryDisk -CapabilityMap @{ MaxResourceVolumeMB = '16384' } -SkuName 'Standard_D2s_v3' | Should -BeTrue
        }

        It 'returns True when the size name has the d feature but MaxResourceVolumeMB is missing' {
            Get-HasLocalTemporaryDisk -CapabilityMap @{} -SkuName 'Standard_D2ds_v6' | Should -BeTrue
        }

        It 'returns True for a d feature even when MaxResourceVolumeMB is 0 (newer NVMe families)' {
            Get-HasLocalTemporaryDisk -CapabilityMap @{ MaxResourceVolumeMB = '0' } -SkuName 'Standard_D2ds_v6' | Should -BeTrue
        }

        It 'returns False when there is no d feature and no MaxResourceVolumeMB' {
            Get-HasLocalTemporaryDisk -CapabilityMap @{} -SkuName 'Standard_D2s_v6' | Should -BeFalse
        }

        It 'does not mistake the s (premium storage) feature for d' {
            Get-HasLocalTemporaryDisk -CapabilityMap @{} -SkuName 'Standard_D2as_v5' | Should -BeFalse
        }

        It 'detects the d feature in a constrained-vCPU size name' {
            Get-HasLocalTemporaryDisk -CapabilityMap @{} -SkuName 'Standard_E8-2ds_v5' | Should -BeTrue
        }

        It 'detects the d feature in a name with an accelerator suffix' {
            Get-HasLocalTemporaryDisk -CapabilityMap @{} -SkuName 'Standard_NC24ads_A100_v4' | Should -BeTrue
        }

        It 'detects a lone d feature' {
            Get-HasLocalTemporaryDisk -CapabilityMap @{} -SkuName 'Standard_D2d_v6' | Should -BeTrue
        }
    }

    Context 'Get-NormalizedVmFamily (unit)' {
        It 'recovers the documented casing from the SKU name (DSv3 -> Dsv3)' {
            $sku = [pscustomobject]@{ Name = 'Standard_D2s_v3'; Family = 'standardDSv3Family' }
            Get-NormalizedVmFamily -Sku $sku | Should -BeExactly 'Dsv3'
        }

        It 'recovers the documented casing for an AMD family (DADSv5 -> Dadsv5)' {
            $sku = [pscustomobject]@{ Name = 'Standard_D2ads_v5'; Family = 'standardDADSv5Family' }
            Get-NormalizedVmFamily -Sku $sku | Should -BeExactly 'Dadsv5'
        }

        It 'recovers the documented casing for a constrained-vCPU name (LASv3 -> Lasv3)' {
            $sku = [pscustomobject]@{ Name = 'Standard_L8as_v3'; Family = 'standardLASv3Family' }
            Get-NormalizedVmFamily -Sku $sku | Should -BeExactly 'Lasv3'
        }

        It 'preserves an uppercase subfamily letter (NV16as_v4 -> NVasv4)' {
            $sku = [pscustomobject]@{ Name = 'Standard_NV16as_v4'; Family = 'standardNVASv4Family' }
            Get-NormalizedVmFamily -Sku $sku | Should -BeExactly 'NVasv4'
        }

        It 'preserves a confidential subfamily letter (DC2ads_v5 -> DCadsv5)' {
            $sku = [pscustomobject]@{ Name = 'Standard_DC2ads_v5'; Family = 'standardDCADSv5Family' }
            Get-NormalizedVmFamily -Sku $sku | Should -BeExactly 'DCadsv5'
        }

        It 'keeps the memory-bandwidth b of the Eb family (E96bds_v5 -> Ebdsv5)' {
            $sku = [pscustomobject]@{ Name = 'Standard_E96bds_v5'; Family = 'standardEBDSv5Family' }
            Get-NormalizedVmFamily -Sku $sku | Should -BeExactly 'Ebdsv5'
        }

        It 'keeps the Azure family label when the SKU name differs by more than case' {
            # Accelerator families (Azure metadata "NCASv3_T4") do not match the size-name token
            # case-insensitively, so the Azure-derived label is preserved unchanged.
            $sku = [pscustomobject]@{ Name = 'Standard_NC4as_T4_v3'; Family = 'standardNCASv3_T4Family' }
            Get-NormalizedVmFamily -Sku $sku | Should -BeExactly 'NCASv3_T4'
        }

        It 'trims whitespace left by stripping the standard/family tokens' {
            $sku = [pscustomobject]@{ Name = 'Standard_NC4as_T4_v3'; Family = 'Standard NCASv3_T4 Family' }
            $normalized = Get-NormalizedVmFamily -Sku $sku
            $normalized | Should -BeExactly 'NCASv3_T4'
            $normalized | Should -Not -Match '^\s'
            $normalized | Should -Not -Match '\s$'
        }

        It 'falls back to the SKU name when Family is absent' {
            $sku = [pscustomobject]@{ Name = 'Standard_D2s_v3' }
            Get-NormalizedVmFamily -Sku $sku | Should -BeExactly 'D2s_v3'
        }

        It 'maps the non-standard DDCSv3 Azure family metadata to the documented DCdsv3 series' {
            $sku = [pscustomobject]@{ Name = 'Standard_DC2ds_v3'; Family = 'standardDDCSv3Family' }
            Get-NormalizedVmFamily -Sku $sku | Should -BeExactly 'DCdsv3'
        }
    }

    Context 'End-to-end -LocalTemporaryDisk filtering' {
        It 'Required returns only families that have a local temporary disk' {
            $result = Invoke-ScriptForLocalTemporaryDisk -LocalTemporaryDisk 'Required'
            $families = @($result | ForEach-Object { $_.VMFamily })

            $families | Should -Contain 'Dsv3'
            $families | Should -Contain 'Ddsv6'
            $families | Should -Contain 'Edsv5'
            $families | Should -Not -Contain 'Dsv6'
            $families | Should -Not -Contain 'Dasv5'

            # Every returned family must actually have a local temporary disk.
            @($result | Where-Object { -not $_.HasLocalTemporaryDisk }) | Should -BeNullOrEmpty
        }

        It 'Excluded returns only families that have no local temporary disk' {
            $result = Invoke-ScriptForLocalTemporaryDisk -LocalTemporaryDisk 'Excluded'
            $families = @($result | ForEach-Object { $_.VMFamily })

            $families | Should -Contain 'Dsv6'
            $families | Should -Contain 'Dasv5'
            $families | Should -Not -Contain 'Dsv3'
            $families | Should -Not -Contain 'Ddsv6'
            $families | Should -Not -Contain 'Edsv5'

            # Every returned family must actually lack a local temporary disk.
            @($result | Where-Object { $_.HasLocalTemporaryDisk }) | Should -BeNullOrEmpty
        }

        It 'Any returns all families with the correct HasLocalTemporaryDisk value' {
            $result = Invoke-ScriptForLocalTemporaryDisk -LocalTemporaryDisk 'Any'
            $byFamily = @{}
            foreach ($row in $result) { $byFamily[$row.VMFamily] = $row }

            $byFamily.Keys | Should -Contain 'Dsv3'
            $byFamily.Keys | Should -Contain 'Ddsv6'
            $byFamily.Keys | Should -Contain 'Edsv5'
            $byFamily.Keys | Should -Contain 'Dsv6'
            $byFamily.Keys | Should -Contain 'Dasv5'

            $byFamily['Dsv3'].HasLocalTemporaryDisk  | Should -BeTrue
            $byFamily['Ddsv6'].HasLocalTemporaryDisk | Should -BeTrue
            $byFamily['Edsv5'].HasLocalTemporaryDisk | Should -BeTrue
            $byFamily['Dsv6'].HasLocalTemporaryDisk  | Should -BeFalse
            $byFamily['Dasv5'].HasLocalTemporaryDisk | Should -BeFalse
        }
    }

    Context 'End-to-end -CPUArchitecture filtering' {
        It 'AMD returns only AMD families' {
            $result = Invoke-ScriptResult -Skus $script:FilterMockSkus -Parameters @{ CPUArchitecture = 'AMD' }
            $families = @($result | ForEach-Object { $_.VMFamily })

            $families | Should -Contain 'Dasv5'
            $families | Should -Not -Contain 'Dsv5'
            $families | Should -Not -Contain 'Dpsv6'
            @($result | Where-Object { $_.CPUArchitecture -ne 'AMD' }) | Should -BeNullOrEmpty
        }

        It 'ARM returns only ARM families' {
            $result = Invoke-ScriptResult -Skus $script:FilterMockSkus -Parameters @{ CPUArchitecture = 'ARM' }
            $families = @($result | ForEach-Object { $_.VMFamily })

            $families | Should -Contain 'Dpsv6'
            $families | Should -Not -Contain 'Dasv5'
            @($result | Where-Object { $_.CPUArchitecture -ne 'ARM' }) | Should -BeNullOrEmpty
        }

        It 'Intel returns only Intel families' {
            $result = Invoke-ScriptResult -Skus $script:FilterMockSkus -Parameters @{ CPUArchitecture = 'Intel' }
            $families = @($result | ForEach-Object { $_.VMFamily })

            $families | Should -Contain 'Dsv5'
            $families | Should -Not -Contain 'Dasv5'
            $families | Should -Not -Contain 'Dpsv6'
            @($result | Where-Object { $_.CPUArchitecture -ne 'Intel' }) | Should -BeNullOrEmpty
        }

        It 'accepts multiple architectures and returns families matching any of them' {
            $result = Invoke-ScriptResult -Skus $script:FilterMockSkus -Parameters @{ CPUArchitecture = @('Intel', 'AMD') }
            $families = @($result | ForEach-Object { $_.VMFamily })

            $families | Should -Contain 'Dsv5'
            $families | Should -Contain 'Dasv5'
            $families | Should -Not -Contain 'Dpsv6'
            @($result | Where-Object { $_.CPUArchitecture -notin @('Intel', 'AMD') }) | Should -BeNullOrEmpty
        }
    }

    Context 'End-to-end -RetirementStatus filtering' {
        It 'Retired returns only retired families' {
            $result = Invoke-ScriptResult -Skus $script:FilterMockSkus -Parameters @{ RetirementStatus = 'Retired' }
            $families = @($result | ForEach-Object { $_.VMFamily })

            $families | Should -Contain 'NCsv3'
            $families | Should -Not -Contain 'Fsv2'
            $families | Should -Not -Contain 'Dsv5'
            @($result | Where-Object { $_.RetirementStatus -ne 'Retired' }) | Should -BeNullOrEmpty
        }

        It 'Retirement Announced returns only announced families' {
            $result = Invoke-ScriptResult -Skus $script:FilterMockSkus -Parameters @{ RetirementStatus = 'Retirement Announced' }
            $families = @($result | ForEach-Object { $_.VMFamily })

            $families | Should -Contain 'Fsv2'
            $families | Should -Not -Contain 'NCsv3'
            $families | Should -Not -Contain 'Dsv5'
            @($result | Where-Object { $_.RetirementStatus -ne 'Retirement Announced' }) | Should -BeNullOrEmpty
        }

        It 'Available excludes announced and retired families' {
            $result = Invoke-ScriptResult -Skus $script:FilterMockSkus -Parameters @{ RetirementStatus = 'Available' }
            $families = @($result | ForEach-Object { $_.VMFamily })

            $families | Should -Contain 'Dsv5'
            $families | Should -Contain 'Dasv5'
            $families | Should -Contain 'Dpsv6'
            $families | Should -Not -Contain 'Fsv2'
            $families | Should -Not -Contain 'NCsv3'
            @($result | Where-Object { $_.RetirementStatus -ne 'Available' }) | Should -BeNullOrEmpty
        }
    }

    Context 'End-to-end combined filtering' {
        It 'CPUArchitecture and RetirementStatus together narrow the result' {
            $result = Invoke-ScriptResult -Skus $script:FilterMockSkus -Parameters @{ CPUArchitecture = 'Intel'; RetirementStatus = 'Retired' }
            $families = @($result | ForEach-Object { $_.VMFamily })

            $families | Should -Contain 'NCsv3'
            $families | Should -Not -Contain 'Fsv2'
            $families | Should -Not -Contain 'Dsv5'
            $families | Should -Not -Contain 'Dasv5'
            $families | Should -Not -Contain 'Dpsv6'
        }
    }
}
