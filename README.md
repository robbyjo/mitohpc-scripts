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
  --account my_lab --partition general --max-parallel 100

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

- One SLURM array task per sample. A failed sample does not cancel successful
  samples.
- When needed, one preliminary SLURM array task per missing BAM/CRAM index.
  Downstream work waits for the entire indexing array to succeed.
- With `--extract-mt`, a separate extraction array that starts after the
  MitoHPC array finishes, whether or not every analysis task succeeded.
- One summary job that runs only after the MitoHPC array succeeds and, when
  extraction was requested, after the extraction array finishes.

The default per-sample request is 4 CPUs, 16 GB, and 2 days, with at most 50
tasks running simultaneously. Change these with `--cpus`, `--memory`, `--time`,
and `--max-parallel`. MitoHPC's Java heap and per-sort-thread memory are capped
separately at 3 GB by default (`--tool-memory`), preventing four sort threads
from each treating the full 16 GB SLURM allocation as their own limit.

## Scheduler concurrency limits

Schedulers normally limit jobs or array tasks, not physical “servers.” Multiple
tasks may share a node, and one task may reserve several CPUs. There are two
different limits to consider:

1. **Concurrent-task limit:** how many array tasks may run at the same time.
2. **Array-size limit:** how many total tasks may be submitted in one array.

### SLURM (`sbatch`)

Use `--max-parallel` to stay within the concurrent-task limit. For a site limit
of 1,000 simultaneous tasks:

```bash
./mito_pipeline.sh INPUT OUTPUT --max-parallel 1000
```

For `N` samples, the launcher submits an array equivalent to
`--array=0-(N-1)%1000`. All samples remain in the array, but SLURM runs no more
than 1,000 of its tasks simultaneously. The remaining tasks stay pending and
start as earlier tasks finish. This is throttling, not an attempt to bypass the
cluster policy.

For a combined `--extract-mt` run, the analysis and extraction arrays are
sequenced rather than run concurrently. Therefore, `--max-parallel 1000` does
not turn into 2,000 simultaneous array tasks. Separate launcher invocations use
separate throttles and are not coordinated with one another; choose their
individual limits so the total across all active runs remains within policy.

If the 1,000-job limit includes other jobs owned by the same user, leave some
headroom—for example, use `--max-parallel 900`. SLURM may apply an even lower
account, partition, or QoS limit; in that case tasks simply remain pending. Use
these commands to inspect the array and pending reasons:

```bash
squeue -u "$USER"
squeue -j ARRAY_JOB_ID -o '%.18i %.9T %.30R'
```

The `%1000` throttle does **not** solve a maximum-array-size error. If the cohort
contains more samples than the site's `MaxArraySize`, `sbatch` rejects the whole
array before it starts. Check the configured value, when permitted, with:

```bash
scontrol show config | grep -i MaxArraySize
```

For a cohort larger than that value, divide the input into multiple directories
with at most `MaxArraySize` alignments each and use a different output directory
for each submission. Set the `--max-parallel` values so their combined
concurrency remains below the 1,000-task site limit. Alternatively, ask the
cluster administrators whether a larger array is permitted.

### Grid Engine-style `qsub`

This workflow submits with SLURM `sbatch`; the retained `.qsub` filename is only
a compatibility entry point and still calls the SLURM launcher. On a separate
Grid Engine workflow, the comparable array concurrency control is usually
`qsub -t 1-N -tc 1000`. Other systems also use a command named `qsub`—notably
PBS—and their throttling syntax can differ, so check that scheduler's site
documentation. Do not pass `qsub` options to `mito_pipeline.sh`.

## Output and recovery

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
