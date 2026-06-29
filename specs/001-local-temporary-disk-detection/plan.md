# Implementation Plan 001: Local Temporary Disk Detection & Filtering

> Technical plan for [spec.md](./spec.md).

## Technical Context

- **Language / Runtime:** PowerShell 7+ with the Azure PowerShell `Az` modules.
- **Primary file:** `Get-AzVmFamilyDetailsBySubscriptionAndRegion.ps1`
- **Tests:** `Get-AzVmFamilyDetailsBySubscriptionAndRegion.Tests.ps1` (Pester 5)

## Approach

1. **Detection (FR-001..FR-003).** `Get-HasLocalTemporaryDisk` takes the SKU
   capability map and the SKU name. It returns `True` immediately when
   `MaxResourceVolumeMB > 0`. Otherwise it strips the `Standard_` prefix and
   matches `^[A-Za-z]+\d+(?:-\d+)?([a-z]*)` to capture the additive-feature
   letters that follow the vCPU count, returning `True` when that capture contains
   `d`. Because only the additive-feature segment is inspected, the `s` storage
   feature is never mistaken for `d`.
2. **Filtering (FR-004, FR-005).** Replace the `switch ($LocalTemporaryDisk)`
   block — whose `continue` targeted the switch rather than the `foreach` — with
   `if (...) { continue }` statements directly inside the `foreach`, so
   non-matching SKUs are skipped before emission.
3. **Family aggregation (FR-006).** When grouping SKUs into a family row,
   `HasLocalTemporaryDisk` is `True` if any SKU in the group has a local temp disk.

## Affected Components

| File / Area | Change |
| --- | --- |
| `Get-AzVmFamilyDetailsBySubscriptionAndRegion.ps1` — `Get-HasLocalTemporaryDisk` | Added `-SkuName` parameter and the `d` size-name fallback |
| `Get-AzVmFamilyDetailsBySubscriptionAndRegion.ps1` — filter loop | Replaced `switch`/`continue` with `if`/`continue` |
| `Get-AzVmFamilyDetailsBySubscriptionAndRegion.ps1` — family grouping | Aggregate `HasLocalTemporaryDisk` across SKUs |
| `Get-AzVmFamilyDetailsBySubscriptionAndRegion.ps1` — `.NOTES` / `.PARAMETER LocalTemporaryDisk` | Documented the fallback rule |
| `Get-AzVmFamilyDetailsBySubscriptionAndRegion.Tests.ps1` | New Pester 5 suite |

## Risks & Mitigations

- **Risk:** The `d`-name heuristic could misclassify an unusual size name.
  **Mitigation:** The regex inspects only the additive-feature segment; unit tests
  cover storage (`s`), constrained vCPUs, accelerator suffixes, and a lone `d`.
- **Risk:** The `continue`-in-`switch` mistake is easy to reintroduce.
  **Mitigation:** End-to-end tests assert no wrong-valued family is returned for
  `Required` / `Excluded`.

## Testing Strategy

Pester 5 suite with stubbed `Get-AzContext`, `Set-AzContext`, and
`Get-AzComputeResourceSku` (no Azure connection required):

- 8 unit tests for `Get-HasLocalTemporaryDisk`.
- 3 end-to-end tests for `-LocalTemporaryDisk Required`, `Excluded`, and `Any`.

Run with:

```powershell
Import-Module Pester -MinimumVersion 5.0.0
Invoke-Pester -Path .\Get-AzVmFamilyDetailsBySubscriptionAndRegion.Tests.ps1 -Output Detailed
```
