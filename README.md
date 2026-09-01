# Turn-key MitoHPC on SLURM and Open Grid Scheduler

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)

This directory wraps MitoHPC in a fault-isolated, resumable workflow for SLURM
and Open Grid Scheduler/Grid Engine. The only required run arguments are an
input alignment directory and an output directory.

## 1. One-time installation

Run this on the Linux cluster login node:

```bash
./setup_mitohpc.sh
```

The installer uses the same pinned MitoHPC revision as the historical TOPMed
workflow (`b172170323aa61dedbfb5f04002a732092843df5`) for reproducibility and
installs a checksum-verified bedtools v2.30.0 executable inside MitoHPC's own
`bin/` directory. It does **not** modify `~/.bashrc` or require modules in batch
jobs. A different compatible checkout can be selected at run time with
`--mitohpc-dir`.

Keep the complete repository on a filesystem visible from both the login and
compute nodes, and do not move it while jobs are active. Schedulers may copy
each batch entry script into a temporary spool directory without its sibling
files; the launchers therefore pass the original absolute shared-worker
directory to every job explicitly.

The default analysis profile is MitoHPC's `init.sh` (hs38DH in the pinned
release). Select another installed profile such as `init.mm39.sh` with
`--reference-profile mm39`; the launcher verifies that the requested profile
exists before submission.

## 2. Submit a cohort

Use the scheduler-specific entry point:

```bash
# SLURM
./mito_pipeline.sh /path/to/bams_or_crams /path/to/results

# Any qsub installation: identifies the dialect and currently accepts OGS/GE
./mito_pipeline_qsub.sh /path/to/bams_or_crams /path/to/results

# Detect SLURM versus qsub automatically
./mito_pipeline_auto.sh /path/to/bams_or_crams /path/to/results
```

If both scheduler clients are installed, select one explicitly:

```bash
./mito_pipeline_auto.sh --scheduler slurm INPUT OUTPUT
./mito_pipeline_auto.sh --scheduler qsub INPUT OUTPUT
```

The input directory may contain BAMs, CRAMs, or both. Alignments must be
coordinate sorted. Existing indexes in either common naming convention are
accepted (`sample.bai` and `sample.bam.bai`, likewise for CRAM). When an index
is missing, the selected launcher schedules an indexing array first and stores
the generated index under `OUTPUT/.mito-pipeline/alignments`; the source
directory is not modified. Analysis starts only after every new index succeeds.
Use
`--require-indexes` to restore fail-fast validation without automatic indexing.

Useful examples:

```bash
# Validate discovery and create a manifest without submitting jobs
./mito_pipeline.sh /data/wgs /results/mito --dry-run

# Recursively find files, limit concurrency, and use a site account/partition
./mito_pipeline.sh /data/wgs /results/mito --recursive \
  --account my_lab --partition general --max-parallel 20 --max-array-size 1000

# Call variants and also retain an indexed mitochondrial-only CRAM
./mito_pipeline.sh /data/wgs /results/mito --extract-mt \
  --reference-fasta /refs/hs38DH.fa

# Calculate copy number and extract mitochondrial CRAMs, without variant calling
./mito_pipeline.sh /data/wgs /results/copy_number_and_crams \
  --iterations 0 --extract-mt --reference-fasta /refs/hs38DH.fa

# Extract mitochondrial CRAMs only
./mito_pipeline.sh /data/wgs /results/extracted --extract-only \
  --reference-fasta /refs/hs38DH.fa

# Copy number only (skip variant calling)
./mito_pipeline.sh /data/wgs /results/copy_number --iterations 0
```

Use the selected launcher's `--help` output for all resource and analysis
options. If your cluster needs modules or other site initialization, put those
commands in a small shell file and pass
`--prologue /path/to/cluster_env.sh`.

Compute jobs automatically prefer tools installed in MitoHPC's `bin/`
directory, including bundled `samtools` and `bedtools`. A cluster module or
prologue is only needed for site-specific requirements outside the bundled
toolchain.

## Extracting mitochondrial sequences

Extraction is optional; a run without `--extract-mt` performs MitoHPC analysis
but does not retain mitochondrial-only alignment files. Add `--extract-mt` to
run analysis and extraction together. Use `--iterations 0 --extract-mt` for
copy number plus extraction without variant calling, or `--extract-only` when no
MitoHPC analysis or cohort summary is wanted.

Extraction runs as a separate scheduler array from the original whole-genome
BAM/CRAM files. It produces one coordinate-preserving CRAM and index per sample:

```text
OUTPUT/extracted/SAMPLE.cram
OUTPUT/extracted/SAMPLE.cram.crai
```

The extracted files are retained for backup or downstream mitochondrial work;
they are not used to estimate copy number. Copy-number calculation must use the
original whole-genome alignment so that mitochondrial read counts can be
normalized against nuclear read counts.

The launcher detects `chrM`, `MT`, or `M` independently for each sample. Use
`--mt-contig NAME` if the alignment uses another contig name. For CRAM input,
passing the exact reference used to create the source CRAM is strongly
recommended:

```bash
./mito_pipeline.sh INPUT OUTPUT --extract-mt \
  --reference-fasta /path/to/alignment_reference.fa
```

If `--reference-fasta` is omitted, extraction uses the reference installed by
the selected MitoHPC profile.

## What gets submitted

- Normally, one scheduler array task processes one sample. If the planned
  workflow would exceed the association's submit-job quota, the launcher automatically
  bundles several samples sequentially in each task. Failures are recorded per
  sample, successful samples remain resumable, and the bundled task reports a
  failure after attempting every assigned sample.
- When needed, preliminary tasks create missing BAM/CRAM indexes. Downstream
  work waits for all indexing arrays to succeed.
- With `--extract-mt`, separate extraction arrays start after MitoHPC processing
  finishes, whether or not every analysis task succeeded.
- One summary job runs only after every MitoHPC array succeeds and, when
  extraction was requested, after extraction finishes.

Every SLURM task explicitly requests one node. Grid Engine tasks request one
parallel-environment allocation. The default task request is 4 CPUs/slots,
16 GB total memory, and 2 days, with at most 20 tasks running simultaneously
and at most 1,000 tasks in each array. Change these with `--cpus`, `--memory`,
`--time`, `--max-parallel`, and `--max-array-size`. When bundling is active,
`--time` covers all samples processed sequentially by that task, so select an
appropriate queue/partition and wall time.

MitoHPC's Java heap and per-sort-thread memory are capped separately at 3 GB by
default (`--tool-memory`), preventing four sort threads from each treating the
full 16 GB SLURM allocation as their own limit.

## Scheduler concurrency limits

Schedulers limit jobs or array tasks, not physical “servers.” There are three
separate limits:

1. **Concurrent-task limit:** how many array tasks may run at once. Controlled
   by `--max-parallel`, SLURM's `%N`, or Grid Engine's `-tc N`.
2. **Array-size limit:** how many tasks one array specification may contain.
   Controlled by `--max-array-size`.
3. **Submit-job limit:** how many running plus pending tasks the user or
   association may have. Controlled here by `--max-user-jobs` and
   `--job-headroom`.

### SLURM (`sbatch`)

The array defaults match:

```text
sbatch --array=0-999%20
```

However, `%20` limits only simultaneous execution. SLURM still enforces
`MaxSubmitJobs` against every array element, including elements waiting on a
dependency. Therefore, a 1,000-sample combined MitoHPC and extraction run can
represent roughly 2,001 submitted jobs even though only 20 run at once. This is
what produces `AssocMaxSubmitJobLimit`.

The launcher now counts the user's expanded running and pending array tasks
before submission. With the defaults, it keeps total usage below a 1,000-job
association limit and reserves 20 slots for other work:

```bash
./mito_pipeline.sh INPUT OUTPUT \
  --max-parallel 20 --max-array-size 1000 \
  --max-user-jobs 1000 --job-headroom 20
```

If necessary, it reduces the number of array tasks by assigning multiple
samples to each task. For example, if analysis plus extraction would require
2,001 job slots but only 980 are available, each task processes several samples
sequentially. The run metadata records the selected bundle size. Separate
launcher invocations can still race for the same quota; if the quota fills after
preflight, the launcher stops with a targeted explanation and can be rerun.

Use the cluster's current values rather than assuming them. On NIH Biowulf,
`batchlim` reports the current maximum jobs, array size, partition wall times,
and per-user allocations:

```bash
batchlim
squeue -r -u "$USER"
```

For 5,708 indexed CRAMs and the stated NHLBI access, a combined copy-number and
mitochondrial-extraction invocation is:

```bash
./mito_pipeline.sh INPUT OUTPUT --iterations 0 --extract-mt \
  --partition nhlbi --time 10-00:00:00 \
  --max-user-jobs 1000 --job-headroom 20
```

Assuming the queue is otherwise empty, the launcher selects a bundle size of 12
for this combined run: 476 MitoHPC tasks, 476 extraction tasks, and one summary
job, or 953 submitted jobs. A MitoHPC-only run uses a bundle size of 6: 952
array tasks plus one summary job. Existing jobs or missing CRAM indexes reduce
the available slots, so the actual bundle size is recalculated at submission
and written to `OUTPUT/.mito-pipeline/runs/RUN/run.txt`.

Increase `--time` only if the measured runtime of an automatically bundled task
requires it, and never above the value currently shown by `batchlim`. The
`norm` partition's single-node restriction is compatible with this workflow:
each analysis, indexing, extraction, and summary task requests exactly one
node. Choosing `nhlbi` changes eligible nodes and wall-time policy; it does not
by itself remove an association submit-job limit.

If your cluster reports a different `MaxArraySize`, pass it with
`--max-array-size`. When permitted, inspect the SLURM configuration with:

```bash
scontrol show config | grep -i MaxArraySize
```

### Open Grid Scheduler / Grid Engine (`qsub`)

`mito_pipeline_qsub.sh` identifies the qsub dialect from `qstat --version`.
Open Grid Scheduler/GE output such as `OGS/GE 2011.11p1` is routed to the OGS
backend. PBS Pro, OpenPBS, and Torque are deliberately rejected because they use
different array, dependency, and resource syntax.

A typical OGS invocation is:

```bash
./mito_pipeline_qsub.sh INPUT OUTPUT --iterations 0 --extract-mt \
  --queue all.q --parallel-env smp \
  --memory-resource h_vmem --time-resource h_rt \
  --max-parallel 20 --max-array-size 1000 \
  --max-user-jobs 1000 --job-headroom 20
```

The defaults are `smp`, `h_vmem`, and `h_rt`. Before a real submission, the
launcher uses `qconf -spl` and `qconf -sc` when available and stops early if
those names do not exist. Obtain the site's valid values with:

```bash
qconf -spl
qconf -sc
qconf -sql
```

Override `--parallel-env`, `--memory-resource`, `--time-resource`, and
`--queue` as required by the site. Add other complex requests without shell
evaluation by repeating `--qsub-resource SPEC`, for example:

```bash
./mito_pipeline_qsub.sh INPUT OUTPUT \
  --parallel-env threaded \
  --memory-resource mem_free \
  --qsub-resource 'exclusive=true'
```

OGS memory complexes such as `h_vmem` are normally requested per slot. The
launcher treats `--memory` as total task memory and divides it across
`--cpus` slots, rounding up to MiB. Thus `--cpus 4 --memory 16G` submits
`-pe smp 4 -l h_vmem=4096M`. Wall times such as `2-00:00:00` are converted
to OGS form (`48:00:00`).

Grid Engine arrays are one-based, so a 1,000-task submission uses:

```text
qsub -t 1-1000 -tc 20
```

The compute entry wrapper converts `SGE_TASK_ID` to the workflow's internal
zero-based manifest coordinate. It also maps `JOB_ID` into scheduler-neutral
status records and writes predictable `.out`/`.err` files under
`OUTPUT/logs`.

The launcher queries `qstat -u "$USER" -g d` so array tasks are expanded when
calculating available submit slots. As with SLURM, `--max-user-jobs` must match
the site's policy; OGS does not provide Biowulf's `batchlim` helper.

OGS `-hold_jid` waits for prior jobs to finish but does not provide SLURM's
`afterok` failure propagation. Each downstream worker therefore validates its
required inputs, and the summary job independently verifies a current success
marker for every sample before building cohort summaries.

Use the full detector when the same repository may run at several institutions:

```bash
./mito_pipeline_auto.sh INPUT OUTPUT
./mito_pipeline_auto.sh --scheduler qsub INPUT OUTPUT
```

Automatic mode prefers SLURM when both client sets are visible. The explicit
override is useful on login nodes exposing more than one scheduler.

## Output and recovery

For a read-only support report on either scheduler, run:

```bash
bash diagnose_mitohpc.sh /path/to/mitohpc-scripts /path/to/output
```

The script creates a timestamped text report in the current directory. It does
not submit or cancel jobs and does not print alignment contents or `config.env`.
Review the report before forwarding it because it includes usernames,
filesystem paths, hostnames, and job IDs.

```text
OUTPUT/
  samples/SAMPLE/       MitoHPC per-sample output
  extracted/            optional mitochondrial CRAMs
  logs/                 one stdout/stderr pair per task
  .mito-pipeline/
    alignments/          normalized, read-only input symlinks
    status/              success/failure markers
    runs/                immutable manifests and run metadata
```

Rerun the same command after fixing a problem. Completed samples are skipped;
failed or interrupted samples resume through MitoHPC's own intermediate-file
checks. The cohort summary is rebuilt only after every array task succeeds.
Inspect `OUTPUT/.mito-pipeline/status/*/*.failed` and the corresponding log for
failures.

### Check for incomplete results

An empty `squeue` or `qstat` only means that no jobs are currently visible; it
does not distinguish successful jobs from jobs that already failed. First check
whether this workflow still has active jobs:

```bash
# SLURM
squeue -u "$USER"

# Open Grid Scheduler / Grid Engine
qstat -u "$USER"
```

After the jobs have left the queue, use the latest immutable run manifest and
the pipeline's status markers to validate every expected sample. The following
block prints the missing or failed sample names and exits nonzero unless all
requested stages and their minimum output files are complete. It runs in a
subshell, so it will not close an interactive login shell:

```bash
(
OUTPUT=/path/to/results

RUN=$(find "$OUTPUT/.mito-pipeline/runs" -mindepth 1 -maxdepth 1 -type d \
  -printf '%T@\t%p\n' | sort -nr | head -n 1 | cut -f 2-)
[[ -n "$RUN" && -s "$RUN/samples.tsv" && -s "$RUN/run.txt" ]] || {
  echo "ERROR: no completed run manifest found under $OUTPUT" >&2
  exit 1
}

MANIFEST="$RUN/samples.tsv"
STATUS="$OUTPUT/.mito-pipeline/status"
CHECK_TMP=$(mktemp -d)
trap 'rm -rf -- "$CHECK_TMP"' EXIT
cut -f 1 "$MANIFEST" | LC_ALL=C sort -u > "$CHECK_TMP/expected"

check_stage() {
  stage=$1
  find "$STATUS/$stage" -maxdepth 1 -type f -name '*.ok' -printf '%f\n' \
    | sed 's/[.]ok$//' | LC_ALL=C sort -u > "$CHECK_TMP/$stage.ok"
  find "$STATUS/$stage" -maxdepth 1 -type f -name '*.failed' -printf '%f\n' \
    | sed 's/[.]failed$//' | LC_ALL=C sort -u > "$CHECK_TMP/$stage.failed"
  comm -23 "$CHECK_TMP/expected" "$CHECK_TMP/$stage.ok" \
    > "$CHECK_TMP/$stage.missing"
  comm -12 "$CHECK_TMP/expected" "$CHECK_TMP/$stage.failed" \
    > "$CHECK_TMP/$stage.failed-current"

  bad=0
  if [[ -s "$CHECK_TMP/$stage.missing" ]]; then
    echo "Missing $stage results:"
    sed 's/^/  /' "$CHECK_TMP/$stage.missing"
    bad=1
  fi
  if [[ -s "$CHECK_TMP/$stage.failed-current" ]]; then
    echo "Failed $stage results:"
    sed 's/^/  /' "$CHECK_TMP/$stage.failed-current"
    bad=1
  fi
  return "$bad"
}

rc=0
if grep -q $'^mitohpc_array_job\t' "$RUN/run.txt"; then
  check_stage mitohpc || rc=1
  : > "$CHECK_TMP/mitohpc-files-missing"
  while IFS=$'\t' read -r sample alignment output_prefix; do
    [[ -s "$output_prefix.count" ]] || \
      printf '%s\n' "$sample" >> "$CHECK_TMP/mitohpc-files-missing"
  done < "$MANIFEST"
  if [[ -s "$CHECK_TMP/mitohpc-files-missing" ]]; then
    echo 'Samples missing a nonempty MitoHPC .count file:'
    sed 's/^/  /' "$CHECK_TMP/mitohpc-files-missing"
    rc=1
  fi
  if [[ ! -s "$STATUS/summary.ok" ]]; then
    echo 'Missing cohort summary success marker' >&2
    rc=1
  fi
fi

if grep -q $'^extract_array_job\t' "$RUN/run.txt"; then
  check_stage extract || rc=1
  : > "$CHECK_TMP/extract-files-missing"
  while IFS=$'\t' read -r sample alignment output_prefix; do
    [[ -s "$OUTPUT/extracted/$sample.cram" && \
       -s "$OUTPUT/extracted/$sample.cram.crai" ]] || \
      printf '%s\n' "$sample" >> "$CHECK_TMP/extract-files-missing"
  done < "$MANIFEST"
  if [[ -s "$CHECK_TMP/extract-files-missing" ]]; then
    echo 'Samples missing a nonempty extracted CRAM or CRAI:'
    sed 's/^/  /' "$CHECK_TMP/extract-files-missing"
    rc=1
  fi
fi

if ! grep -Eq $'^(mitohpc_array_job|extract_array_job)\t' "$RUN/run.txt"; then
  echo 'ERROR: latest run has no submitted analysis or extraction jobs' >&2
  rc=1
fi

if ((rc == 0)); then
  echo "COMPLETE: $(wc -l < "$CHECK_TMP/expected") samples validated"
else
  echo 'INCOMPLETE: inspect the listed samples and OUTPUT/logs' >&2
fi
exit "$rc"
)
```

The cohort `summary.ok` marker is written only after MitoHPC verifies current
success markers for every manifest sample and the summary command exits zero.
Extraction is checked separately because it is allowed to finish independently
of cohort summarization. After correcting a failure, rerun the original
launcher command; valid samples will be skipped.

For historical scheduler details, collect the job IDs from the latest
`run.txt`. On SLURM, pass the comma-separated IDs to `sacct -X -j`; on Grid
Engine, inspect each with `qacct -j`. The diagnostic report shown above does
this automatically when the relevant accounting command is available.

### Package a validated result set

Run the validation block above immediately before packaging and continue only
after it prints `COMPLETE`. Create the archive outside `OUTPUT`; otherwise tar
may try to include the archive while it is still being written. This recipe
keeps scientific outputs, logs, manifests, and status records, but omits
`.mito-pipeline/alignments`, which contains staging links and any regenerated
input indexes rather than final results:

```bash
(
set -euo pipefail
OUTPUT=/path/to/results
PACKAGE_DIR=/path/to/packages

mkdir -p "$PACKAGE_DIR"
OUTPUT=$(cd "$OUTPUT" && pwd -P)
PACKAGE_DIR=$(cd "$PACKAGE_DIR" && pwd -P)
case "$PACKAGE_DIR/" in
  "$OUTPUT/"*)
    echo 'ERROR: PACKAGE_DIR must be outside OUTPUT' >&2
    exit 1
    ;;
esac
OUTPUT_PARENT=$(dirname "$OUTPUT")
OUTPUT_NAME=$(basename "$OUTPUT")
STAMP=$(date -u +'%Y%m%dT%H%M%SZ')
ARCHIVE="$PACKAGE_DIR/${OUTPUT_NAME}_${STAMP}.tar.gz"

# Do not use tar --dereference: staged alignments point to the original inputs.
tar -C "$OUTPUT_PARENT" \
  --exclude="$OUTPUT_NAME/.mito-pipeline/alignments" \
  -czf "$ARCHIVE" "$OUTPUT_NAME"
tar -tzf "$ARCHIVE" > "$ARCHIVE.contents.txt"
(
  cd "$PACKAGE_DIR"
  sha256sum "$(basename "$ARCHIVE")" > "$(basename "$ARCHIVE").sha256"
  sha256sum -c "$(basename "$ARCHIVE").sha256"
)

printf 'Archive:  %s\nContents: %s\nChecksum: %s\n' \
  "$ARCHIVE" "$ARCHIVE.contents.txt" "$ARCHIVE.sha256"
)
```

Retain the `.sha256` and `.contents.txt` files beside the archive. On the
receiving system, place all three files in one directory and run
`sha256sum -c ARCHIVE_NAME.tar.gz.sha256` before extracting. Use
`tar -xzf ARCHIVE_NAME.tar.gz` to unpack it. For very large result sets, verify
that `PACKAGE_DIR` has enough free space with `df -h "$PACKAGE_DIR"` first.

The workflow records signatures for the alignment, its index, MitoHPC code, and
scientifically relevant options. If an input or analysis setting changes after
work has begun, the run stops instead of mixing incompatible results. Use a new
output directory for the changed analysis. A second submission is also blocked
while an earlier MitoHPC array for that output directory is still active.

## Troubleshooting

### Start with evidence, not another large submission

Test changes with `--dry-run` and then a directory containing no more than five
alignments before resubmitting a cohort. For an existing run, create the
read-only diagnostic report first:

```bash
PIPELINE=/path/to/mitohpc-scripts
OUTPUT=/path/to/results

bash "$PIPELINE/diagnose_mitohpc.sh" "$PIPELINE" "$OUTPUT"
```

Then find the latest run record, failed markers, and newest nonempty logs:

```bash
RUN=$(find "$OUTPUT/.mito-pipeline/runs" -mindepth 1 -maxdepth 1 -type d \
  -printf '%T@\t%p\n' | sort -nr | head -n 1 | cut -f 2-)
printf 'Latest run: %s\n' "$RUN"
cat "$RUN/run.txt"
find "$OUTPUT/.mito-pipeline/status" -type f -name '*.failed' -print
find "$OUTPUT/logs" -type f -size +0c -printf '%T@\t%p\n' \
  | sort -nr | head -n 20 | cut -f 2-
```

An empty live queue is not proof of success. Use the job IDs stored in
`run.txt` to query scheduler history:

```bash
JOB_IDS=$(awk -F '\t' \
  '$1 ~ /^(index_array_job|mitohpc_array_job|extract_array_job|summary_job)$/ \
   && $2 ~ /^[0-9]+$/ {print $2}' "$RUN/run.txt" | paste -sd, -)
printf 'Job IDs: %s\n' "${JOB_IDS:-none}"
```

For SLURM:

```bash
sacct -X -j "$JOB_IDS" \
  --format=JobIDRaw,JobName,Partition,State,ExitCode,Elapsed,Reason
```

For Open Grid Scheduler / Grid Engine, `qacct` accepts one job at a time:

```bash
tr ',' '\n' <<< "$JOB_IDS" | while read -r job_id; do
  qacct -j "$job_id"
done
```

The completion checker in the previous section remains authoritative after
scheduler accounting records expire.

### Common symptoms

| Symptom | Likely cause and action |
| --- | --- |
| `sbatch: Invalid job array specification` | The requested array is larger than the site's limit. Use the current launcher with `--max-array-size` no larger than `MaxArraySize`; it splits the cohort automatically. On Biowulf, `--max-array-size 1000 --max-parallel 20` produces arrays such as `0-999%20`. |
| `AssocMaxSubmitJobLimit` or a QOS submit-limit error | Running and pending array elements exhausted the user or association quota. Wait for capacity, set `--max-user-jobs` to the real site limit, and retain headroom. The launcher then bundles samples automatically; lowering only `--max-parallel` does not reduce submitted elements. |
| Jobs vanish from `squeue` or `qstat` | Completed and failed jobs normally leave the live queue. Check `sacct` or `qacct`, `.failed` markers, and task logs. Do not immediately submit the full cohort again. |
| Thousands of jobs fail within seconds | Usually a shared-path, missing-helper, command, permission, or configuration failure affecting every task. Stop further large submissions, reproduce with at most five samples, and inspect the first task's `.err` log. |
| `/var/spool/.../job_common.sh: No such file or directory` | An obsolete worker tried to find helpers beside the scheduler's temporary script copy. Keep the complete repository on a compute-visible filesystem and submit through a current top-level launcher; do not invoke or copy an individual file from `slurm/` or `ogs/`. |
| `required compute command 'samtools' is unavailable` | Rerun `setup_mitohpc.sh` if the bundled tools are absent. If the site requires modules, load them through `--prologue` so loading occurs inside every compute job. |
| `existing ... outputs ... were made from different inputs/settings` | The output directory contains provenance from another alignment, index, reference, MitoHPC revision, or scientific option set. Use a new output directory; do not delete individual `.attempt` or `.ok` markers to bypass this check. |
| `job ... is still ... for this output directory` | An earlier array using the same output directory remains active. Wait for it to finish. Use a different output directory only for a genuinely separate analysis. |
| `refusing cohort summary: ... sample(s) are incomplete` | At least one MitoHPC marker is missing or stale. Inspect the listed samples and logs, correct the underlying issue, and rerun the original launcher command. Successful samples will be skipped. |
| `could not identify the qsub implementation` | Capture `qstat --version 2>&1`. OGS/GE 2011.11 is supported even when that command returns nonzero; PBS Pro, OpenPBS, and Torque are intentionally rejected because their syntax differs. |
| Grid Engine reports an unknown PE, resource, or queue | Inspect `qconf -spl`, `qconf -sc`, and `qconf -sql`, then set `--parallel-env`, `--memory-resource`, `--time-resource`, and `--queue` to site-valid names. |
| No BAM/CRAM files are found | Inputs are searched only at the top level by default. Add `--recursive` for nested directories and confirm filenames end in `.bam` or `.cram`. |
| `could not detect a mitochondrial contig with mapped reads` | Check `samtools idxstats` for the sample and pass the correct name with `--mt-contig`, commonly `chrM`, `MT`, or `M`. Also confirm the file actually contains mapped mitochondrial reads. |
| CRAM decoding or extraction reports reference errors | Pass the exact reference used to create the CRAM with `--reference-fasta`; verify it is readable and has a matching `.fai`. A reference with the same contig names but different sequence is not interchangeable. |
| `TIMEOUT`, `OUT_OF_MEMORY`, or disk-write errors | Inspect scheduler accounting and logs. Increase `--time` only within the selected queue/partition limit; adjust `--memory` or `--tool-memory` for memory failures; check `df -h`, quota, and output permissions for write failures. |

### Compute-node commands and modules

`module load samtools` in the login shell before submission is not sufficient on
clusters that start batch jobs with a clean environment. The preferred setup is
the pinned `software/MitoHPC/bin/samtools` installed by:

```bash
./setup_mitohpc.sh
software/MitoHPC/bin/samtools --version
```

If local policy requires a module, create a readable prologue file:

```bash
#!/usr/bin/env bash
module load samtools
```

Then submit it with the original command:

```bash
./mito_pipeline_auto.sh INPUT OUTPUT --prologue /path/to/cluster_env.sh
```

The prologue is sourced inside indexing, analysis, extraction, and summary
jobs. Bundled tools under MitoHPC's `bin/` directory are placed first in
`PATH`, making runs independent of whichever modules happened to be loaded at
submission time.

### Shared paths, permissions, and versions

The repository, MitoHPC installation, input files, output directory, reference,
and optional prologue must be visible from compute nodes. Do not move or rename
the repository while jobs are active. Paths to the repository, MitoHPC, and
output directory must not contain whitespace.

Before a large retry, record the exact repository state and verify its scripts:

```bash
git -C /path/to/mitohpc-scripts status --short --branch
git -C /path/to/mitohpc-scripts describe --tags --always --dirty
bash -n /path/to/mitohpc-scripts/*.sh \
  /path/to/mitohpc-scripts/slurm/*.sh \
  /path/to/mitohpc-scripts/ogs/*.sh
```

If the checkout is clean but behind GitHub, update it with `git pull --ff-only`.
If it has local changes, preserve or commit them before updating rather than
overwriting them. A useful support bundle contains the diagnostic report, exact
launcher command, relevant `.failed` marker, matching `.err`/`.out` log, and
scheduler accounting output. Review usernames, hostnames, job IDs, and paths
before sharing; never include alignment contents or credentials.

## Deliberate safety checks

The launcher automatically schedules missing indexes unless `--require-indexes`
is used. It fails before submission for duplicate or unsafe sample names, no
alignments, an invalid resource request, or an incomplete MitoHPC installation.
Output and MitoHPC installation paths containing
whitespace are rejected because the pinned MitoHPC internals do not quote paths
consistently. Input paths are normalized through safe staging links.

Mitochondrial contigs are detected per sample from `chrM`, `MT`, or `M`. Override
this with `--mt-contig NAME` for another naming convention. CRAM extraction uses
the explicit `--reference-fasta` when supplied; otherwise it uses the reference
installed by the selected MitoHPC profile.

For `--iterations 0`, the wrapper deliberately bypasses MitoHPC v1's worker:
that worker mistakenly continues into variant calling on a sample's first
copy-number-only run. The wrapper creates the same `.idxstats` and `.count`
inputs directly, then uses MitoHPC's cohort copy-number summarizer.

## License

This project is distributed under the GNU General Public License, version 3.
See [LICENSE](LICENSE) for the complete license text.
