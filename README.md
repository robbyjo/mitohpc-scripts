# Turn-key MitoHPC on SLURM

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)

This directory wraps MitoHPC in a fault-isolated, resumable SLURM workflow. The
only required run arguments are an input alignment directory and an output
directory.

## 1. One-time installation

Run this on the Linux cluster login node:

```bash
./setup_mitohpc.sh
```

The installer uses the same pinned MitoHPC revision as the historical TOPMed
workflow (`b172170323aa61dedbfb5f04002a732092843df5`) for reproducibility. It
does **not** modify `~/.bashrc`. A different compatible checkout can be selected
at run time with `--mitohpc-dir`.

Keep the complete repository on a filesystem visible from both the login and
compute nodes, and do not move it while jobs are active. SLURM copies each batch
entry script into a temporary spool directory without its sibling files; the
launcher therefore passes the original absolute `slurm/` directory to every
job explicitly.

The default analysis profile is MitoHPC's `init.sh` (hs38DH in the pinned
release). Select another installed profile such as `init.mm39.sh` with
`--reference-profile mm39`; the launcher verifies that the requested profile
exists before submission.

## 2. Submit a cohort

```bash
./mito_pipeline.sh /path/to/bams_or_crams /path/to/results
```

The input directory may contain BAMs, CRAMs, or both. Alignments must be
coordinate sorted. Existing indexes in either common naming convention are
accepted (`sample.bai` and `sample.bam.bai`, likewise for CRAM). When an index
is missing, the launcher schedules a SLURM indexing array first and stores the
generated index under `OUTPUT/.mito-pipeline/alignments`; the source directory
is not modified. Analysis starts only after every new index succeeds. Use
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

Use `./mito_pipeline.sh --help` for all resource and analysis options. If your
cluster needs modules or other site initialization, put those commands in a
small shell file and pass `--prologue /path/to/cluster_env.sh`.

## Extracting mitochondrial sequences

Extraction is optional; a run without `--extract-mt` performs MitoHPC analysis
but does not retain mitochondrial-only alignment files. Add `--extract-mt` to
run analysis and extraction together. Use `--iterations 0 --extract-mt` for
copy number plus extraction without variant calling, or `--extract-only` when no
MitoHPC analysis or cohort summary is wanted.

Extraction runs as a separate SLURM array from the original whole-genome
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

- Normally, one SLURM array task processes one sample. If the planned workflow
  would exceed the association's submit-job quota, the launcher automatically
  bundles several samples sequentially in each task. Failures are recorded per
  sample, successful samples remain resumable, and the bundled task reports a
  failure after attempting every assigned sample.
- When needed, preliminary tasks create missing BAM/CRAM indexes. Downstream
  work waits for all indexing arrays to succeed.
- With `--extract-mt`, separate extraction arrays start after MitoHPC processing
  finishes, whether or not every analysis task succeeded.
- One summary job runs only after every MitoHPC array succeeds and, when
  extraction was requested, after extraction finishes.

Every task explicitly requests one node. The default task request is 4 CPUs,
16 GB, and 2 days, with at most 20 tasks running simultaneously and at most
1,000 tasks in each array. Change these with `--cpus`, `--memory`, `--time`,
`--max-parallel`, and `--max-array-size`. When bundling is active, `--time`
covers all samples processed sequentially by that task, so select an appropriate
partition and wall time.

MitoHPC's Java heap and per-sort-thread memory are capped separately at 3 GB by
default (`--tool-memory`), preventing four sort threads from each treating the
full 16 GB SLURM allocation as their own limit.

## Scheduler concurrency limits

Schedulers limit jobs or array tasks, not physical “servers.” There are three
separate limits:

1. **Concurrent-task limit:** how many array tasks may run at once. Controlled
   by `--max-parallel` and SLURM's `%N` syntax.
2. **Array-size limit:** how many tasks one array specification may contain.
   Controlled by `--max-array-size`.
3. **Submit-job limit:** how many running plus pending jobs the association may
   have. Controlled here by `--max-user-jobs` and `--job-headroom`.

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

### Grid Engine-style `qsub`

This workflow submits only with SLURM `sbatch`. In a separate Grid Engine
workflow, comparable array concurrency control is commonly
`qsub -t 1-N -tc 20`. Other schedulers also use a command named `qsub`, notably
PBS, and their syntax can differ. Check the scheduler's site documentation; do
not pass `qsub` options to `mito_pipeline.sh`.

## Output and recovery

For a read-only support report on Biowulf, run:

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

The workflow records signatures for the alignment, its index, MitoHPC code, and
scientifically relevant options. If an input or analysis setting changes after
work has begun, the run stops instead of mixing incompatible results. Use a new
output directory for the changed analysis. A second submission is also blocked
while an earlier MitoHPC array for that output directory is still active.

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
