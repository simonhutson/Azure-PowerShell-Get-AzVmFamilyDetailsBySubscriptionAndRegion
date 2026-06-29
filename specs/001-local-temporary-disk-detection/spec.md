# Feature Spec 001: Local Temporary Disk Detection & Filtering

- **Status:** Complete
- **Created:** 2026-06-29
- **Owner:** simonhutson
- **Related:**
  - `Get-AzVmFamilyDetailsBySubscriptionAndRegion.ps1`
  - `Get-AzVmFamilyDetailsBySubscriptionAndRegion.Tests.ps1`

## Summary

Report and filter Azure VM families by whether they expose a local temporary/
resource disk, correctly handling both legacy families and newer (v6/v7) families
where Azure does not populate the `MaxResourceVolumeMB` capability.

## Problem / Motivation

The `HasLocalTemporaryDisk` column and the `-LocalTemporaryDisk` filter were
unreliable:

1. **Detection gap.** Newer families such as `Dadsv7`, `Dadv6`, `Daldsv7`,
   `Daldv6`, `Ddsv6`, `Dldsv6`, `Dndv6`, and `Dnldv6` were reported as `False`
   even though they have a local temp disk. Azure does not populate
   `MaxResourceVolumeMB` for these SKUs, so the sole detection signal failed.
2. **Broken filter.** `-LocalTemporaryDisk Required` still returned families whose
   `HasLocalTemporaryDisk` value was `False`. The filter used `continue` inside a
   `switch`, which in PowerShell targets the switch (itself a looping construct)
   rather than the enclosing `foreach`, so non-matching SKUs were emitted instead
   of skipped.

## Goals

- Accurately detect local temp/resource disk presence for all current VM families.
- Ensure `-LocalTemporaryDisk Required` / `Excluded` filter correctly.
- Lock the behavior in with automated tests.

## Non-Goals

- Special-casing storage-optimized series (for example `Lsv4` / `Lasv4`) that
  carry NVMe data disks without the `d` size-name additive feature.
- Changing any other output column or filter behavior.

## Requirements

- **FR-001:** The script MUST report `HasLocalTemporaryDisk = True` when the SKU
  capability `MaxResourceVolumeMB` is greater than 0.
- **FR-002:** When `MaxResourceVolumeMB` is missing or 0, the script MUST infer
  local temp disk presence from the Azure size-name `d` additive feature — the
  lowercase letters immediately after the vCPU count (for example
  `Standard_D2ds_v6`).
- **FR-003:** The script MUST NOT treat the `s` (premium storage) feature as `d`.
- **FR-004:** `-LocalTemporaryDisk Required` MUST return only families where every
  displayed family has a local temp disk.
- **FR-005:** `-LocalTemporaryDisk Excluded` MUST return only families with no
  local temp disk.
- **FR-006:** At family level, `HasLocalTemporaryDisk` MUST be `True` if any SKU in
  the family exposes a local temp disk.

## Acceptance Scenarios

1. **Given** a `Dadsv7` family with NVMe and no `MaxResourceVolumeMB`, **When** the
   script runs, **Then** `HasLocalTemporaryDisk` is `True` (inferred from the `d`
   name). _(FR-002)_
2. **Given** a `Dsv6` family (no `d`, no `MaxResourceVolumeMB`), **When** the script
   runs, **Then** `HasLocalTemporaryDisk` is `False`. _(FR-003)_
3. **Given** `-LocalTemporaryDisk Required`, **When** the script runs, **Then**
   every returned family has `HasLocalTemporaryDisk = True`. _(FR-004)_
4. **Given** `-LocalTemporaryDisk Excluded`, **When** the script runs, **Then**
   every returned family has `HasLocalTemporaryDisk = False`. _(FR-005)_

## Edge Cases

- Constrained-vCPU names (`Standard_E8-2ds_v5`) — `d` detected after the `-2`
  constraint segment.
- Accelerator suffixes (`Standard_NC24ads_A100_v4`) — `d` detected before the
  `_A100` suffix.
- Lone `d` feature (`Standard_D2d_v6`).

## Review & Acceptance Checklist

- [x] Requirements are testable and unambiguous
- [x] Acceptance scenarios cover the primary flows and edge cases
- [x] Non-goals are explicit
- [x] Implementation captured in `plan.md`
- [x] Tasks tracked in `tasks.md`

## Open Questions

- Should storage-optimized series without a `d` feature (for example `Lsv4` /
  `Lasv4`) be surfaced as having a local disk? Deferred — see Non-Goals.
