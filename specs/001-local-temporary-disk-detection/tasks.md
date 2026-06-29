# Tasks 001: Local Temporary Disk Detection & Filtering

> Task list for [plan.md](./plan.md).

- [x] T001 Add `-SkuName` parameter to `Get-HasLocalTemporaryDisk` _(FR-002)_
- [x] T002 Add the `d` size-name fallback when `MaxResourceVolumeMB` is missing/0 _(FR-002, FR-003)_
- [x] T003 Replace the `switch`/`continue` filter with `if`/`continue` in the foreach _(FR-004, FR-005)_
- [x] T004 Aggregate `HasLocalTemporaryDisk` across SKUs at family level _(FR-006)_
- [x] T005 Update `.NOTES` and `.PARAMETER LocalTemporaryDisk` documentation
- [x] T006 [P] Add Pester unit tests for `Get-HasLocalTemporaryDisk`
- [x] T007 [P] Add Pester end-to-end tests for `-LocalTemporaryDisk`

## Definition of Done

- [x] All tasks complete
- [x] Tests pass (11/11)
- [x] Acceptance scenarios in `spec.md` verified
