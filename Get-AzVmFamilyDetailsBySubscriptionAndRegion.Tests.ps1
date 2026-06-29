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

        # Synthetic SKUs covering every local-temp-disk detection path.
        #   DSv3  : two SKUs, temp disk via MaxResourceVolumeMB (older family)  -> True
        #   DDSv6 : 'd' in name, no MaxResourceVolumeMB (newer NVMe family)     -> True
        #   EDSv5 : 'd' in a constrained-vCPU name, no MaxResourceVolumeMB      -> True
        #   DSv6  : no 'd', no MaxResourceVolumeMB                              -> False
        #   DASv5 : no 'd', MaxResourceVolumeMB = 0                            -> False
        $script:FullMockSkus = @(
            New-MockSku -Name 'Standard_D2s_v3'    -Family 'standardDSv3Family'  -MaxResourceVolumeMB 16384
            New-MockSku -Name 'Standard_D4s_v3'    -Family 'standardDSv3Family'  -MaxResourceVolumeMB 32768 -Vcpus '4'
            New-MockSku -Name 'Standard_D2ds_v6'   -Family 'standardDDSv6Family' -DiskControllerTypes 'NVMe'
            New-MockSku -Name 'Standard_E8-2ds_v5' -Family 'standardEDSv5Family' -Vcpus '8'
            New-MockSku -Name 'Standard_D2s_v6'    -Family 'standardDSv6Family'  -DiskControllerTypes 'NVMe'
            New-MockSku -Name 'Standard_D2as_v5'   -Family 'standardDASv5Family' -MaxResourceVolumeMB 0
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

    Context 'End-to-end -LocalTemporaryDisk filtering' {
        It 'Required returns only families that have a local temporary disk' {
            $result = Invoke-ScriptForLocalTemporaryDisk -LocalTemporaryDisk 'Required'
            $families = @($result | ForEach-Object { $_.VMFamily })

            $families | Should -Contain 'DSv3'
            $families | Should -Contain 'DDSv6'
            $families | Should -Contain 'EDSv5'
            $families | Should -Not -Contain 'DSv6'
            $families | Should -Not -Contain 'DASv5'

            # Every returned family must actually have a local temporary disk.
            @($result | Where-Object { -not $_.HasLocalTemporaryDisk }) | Should -BeNullOrEmpty
        }

        It 'Excluded returns only families that have no local temporary disk' {
            $result = Invoke-ScriptForLocalTemporaryDisk -LocalTemporaryDisk 'Excluded'
            $families = @($result | ForEach-Object { $_.VMFamily })

            $families | Should -Contain 'DSv6'
            $families | Should -Contain 'DASv5'
            $families | Should -Not -Contain 'DSv3'
            $families | Should -Not -Contain 'DDSv6'
            $families | Should -Not -Contain 'EDSv5'

            # Every returned family must actually lack a local temporary disk.
            @($result | Where-Object { $_.HasLocalTemporaryDisk }) | Should -BeNullOrEmpty
        }

        It 'Any returns all families with the correct HasLocalTemporaryDisk value' {
            $result = Invoke-ScriptForLocalTemporaryDisk -LocalTemporaryDisk 'Any'
            $byFamily = @{}
            foreach ($row in $result) { $byFamily[$row.VMFamily] = $row }

            $byFamily.Keys | Should -Contain 'DSv3'
            $byFamily.Keys | Should -Contain 'DDSv6'
            $byFamily.Keys | Should -Contain 'EDSv5'
            $byFamily.Keys | Should -Contain 'DSv6'
            $byFamily.Keys | Should -Contain 'DASv5'

            $byFamily['DSv3'].HasLocalTemporaryDisk  | Should -BeTrue
            $byFamily['DDSv6'].HasLocalTemporaryDisk | Should -BeTrue
            $byFamily['EDSv5'].HasLocalTemporaryDisk | Should -BeTrue
            $byFamily['DSv6'].HasLocalTemporaryDisk  | Should -BeFalse
            $byFamily['DASv5'].HasLocalTemporaryDisk | Should -BeFalse
        }
    }
}
