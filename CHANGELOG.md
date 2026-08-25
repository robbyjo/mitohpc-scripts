# Changelog

All notable changes to this project are documented here.

## v0.1.1 — 2026-08-25

- Automatically create missing BAM/CRAM indexes in a preliminary SLURM array.
- Keep generated indexes in pipeline staging so input directories remain
  untouched, and gate downstream jobs on successful indexing.
- Add `--require-indexes` for the previous fail-fast behavior.
- Split cohorts into sequential SLURM arrays with `--max-array-size`, avoiding
  invalid array specifications while preserving the global concurrency cap.
- Set scheduler-aware defaults of 1,000 tasks per array and 20 concurrent tasks.
- Preflight active jobs and automatically bundle samples to respect
  `AssocMaxSubmitJobLimit`, with configurable quota and headroom.
- Explicitly request one node per SLURM task and improve policy-error reporting.
- Resolve helper scripts from the shared repository path instead of SLURM's
  temporary spool directory.
- Prefer MitoHPC's bundled `bin/samtools` in compute jobs and verify it during
  setup, avoiding a dependency on cluster module state.

## v0.1.0 — 2026-08-25

Initial public release:

- Turn-key BAM/CRAM discovery and validation.
- Resumable, per-sample SLURM arrays for MitoHPC processing.
- Copy-number-only mode that avoids MitoHPC v1's unintended variant calling.
- Optional mitochondrial CRAM extraction with automatic contig detection.
- Normalized alignment-index staging and provenance protection.
- Scheduler throttling, dependency management, logs, and cohort summaries.
- Pinned MitoHPC installer that does not modify the user's shell profile.
- Integration tests covering submission, processing, extraction, recovery, and
  stale-input rejection.
