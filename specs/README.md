# Specs

Versioned [Spec Kit](https://github.com/github/spec-kit)-style specification
artifacts for this repository. Each feature or notable change gets its own
numbered folder so the intent (spec), approach (plan), and work (tasks) are
captured alongside the code.

## Layout

```
specs/
├── _template-lightweight/   # Copy this to start a new spec
│   ├── spec.md              # WHAT & WHY
│   ├── plan.md              # HOW
│   └── tasks.md             # Task breakdown
└── NNN-short-slug/          # One folder per feature/change
    ├── spec.md
    ├── plan.md
    └── tasks.md
```

## Conventions

- **Folder name:** `NNN-short-slug`, where `NNN` is a zero-padded, incrementing
  number (`001`, `002`, `003`, ...) and `short-slug` is a lowercase, hyphenated
  summary of the feature (for example `001-local-temporary-disk-detection`).
- **Authoring order:** write `spec.md` first, then `plan.md`, then `tasks.md`.
- **Requirements** are uniquely numbered (`FR-001`, `FR-002`, ...) so tests and
  tasks can reference them.

## Creating a new spec

1. Copy `_template-lightweight/` to the next number, e.g. `002-my-feature/`.
2. Replace the `NNN`/placeholder values and fill in `spec.md`.
3. Capture the technical approach in `plan.md`, then break it down in `tasks.md`.

## Index

| Spec | Title | Status |
| --- | --- | --- |
| [001](./001-local-temporary-disk-detection/spec.md) | Local Temporary Disk Detection & Filtering | Complete |
