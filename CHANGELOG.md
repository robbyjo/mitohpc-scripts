# Changelog

All notable changes to this project are documented here.

## v0.1.1 — 2026-08-25

- Automatically create missing BAM/CRAM indexes in a preliminary SLURM array.
- Keep generated indexes in pipeline staging so input directories remain
  untouched, and gate downstream jobs on successful indexing.
- Add `--require-indexes` for the previous fail-fast behavior.

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
