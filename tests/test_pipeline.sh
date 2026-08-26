#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

readonly ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly TEST_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TEST_DIR"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_file() { [[ -e "$1" ]] || fail "missing $1"; }
assert_grep() { grep -F -- "$1" "$2" >/dev/null || fail "'$1' not found in $2"; }

mkdir -p "$TEST_DIR/input" "$TEST_DIR/out" "$TEST_DIR/mitohpc/scripts" "$TEST_DIR/mitohpc/RefSeq" "$TEST_DIR/mitohpc/bin" "$TEST_DIR/bin"
printf 'bam-data\n' > "$TEST_DIR/input/alpha.bam"
printf 'index-data\n' > "$TEST_DIR/input/alpha.bai"
printf '>chrM\nACGT\n' > "$TEST_DIR/mitohpc/RefSeq/hs38DH.fa"

printf '%s\n' \
    '#!/usr/bin/env bash' \
    'export HP_HDIR="$(cd -- "$HP_SDIR/.." && pwd -P)"' \
    'export HP_BDIR="$HP_HDIR/bin"' \
    'export HP_RDIR="$HP_HDIR/RefSeq"' \
    'export HP_RNAME=hs38DH' \
    'export HP_RMT=chrM' \
    'export HP_RNUMT="chr1:1-2"' \
    'export HP_MT=chrM' \
    'export HP_MTLEN=16569' \
    'export HP_NUMT=NUMT' \
    'export HP_CN=1' \
    'export HP_E=300' \
    'export HP_FOPT=' \
    'export HP_DOPT=' \
    'export HP_GOPT=' \
    'export HP_T1=03; export HP_T2=05; export HP_T3=10' \
    'export HP_V=' \
    'export HP_FRULE=tee' \
    'export HP_O=Human' \
    'export PATH="$HP_SDIR:$PATH"' \
    > "$TEST_DIR/mitohpc/scripts/init.sh"

printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -Eeuo pipefail' \
    '[[ -s "$2.bai" || -s "$2.crai" ]]' \
    '[[ "$(bedtools --version)" == "bedtools v2.30.0" ]]' \
    'mkdir -p "$(dirname -- "$3")"' \
    'printf "filter-called\\n" > "$3.filter-called"' \
    > "$TEST_DIR/mitohpc/scripts/filter.sh"

printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -Eeuo pipefail' \
    'printf "summary-called\\n" > "$1/summary-called"' \
    > "$TEST_DIR/mitohpc/scripts/getSummary.sh"

printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -Eeuo pipefail' \
    'sample=unknown; chr=chrM' \
    'while (($#)); do case "$1" in -sample) sample=$2; shift 2;; -chrM) chr=$2; shift 2;; *) shift;; esac; done' \
    'awk -F "\t" -v sample="$sample" -v chr="$chr" '\''BEGIN {OFS="\t"; all=0; mapped=0; mt=0} $1!="*" {all+=$3+$4; mapped+=$3} $1==chr {mt=$3} END {print "Run","all","mapped","MT"; print sample,all,mapped,mt}'\'' ' \
    > "$TEST_DIR/mitohpc/scripts/idxstats2count.pl"

printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -Eeuo pipefail' \
    'case "$1" in' \
    '  idxstats) printf "chr1\t1000\t100\t0\nchrM\t16569\t25\t0\n*\t0\t0\t0\n" ;;' \
    '  view) out=""; while (($#)); do if [[ "$1" == -o ]]; then out=$2; shift 2; else shift; fi; done; printf "cram\\n" > "$out" ;;' \
    '  index) shift; while (($#)); do case "$1" in -@) shift 2;; *) break;; esac; done; input=$1; output=${2:-"$input.crai"}; printf "index\\n" > "$output" ;;' \
    '  *) exit 2 ;;' \
    'esac' \
    > "$TEST_DIR/bin/samtools"
cp "$TEST_DIR/bin/samtools" "$TEST_DIR/mitohpc/bin/samtools"
printf '%s\n' '#!/usr/bin/env bash' 'printf "bedtools v2.30.0\\n"' > "$TEST_DIR/mitohpc/bin/bedtools"
# Broken system tools prove workers prefer MitoHPC's bundled executables.
printf '%s\n' '#!/usr/bin/env bash' 'exit 99' > "$TEST_DIR/bin/samtools"
printf '%s\n' '#!/usr/bin/env bash' 'exit 99' > "$TEST_DIR/bin/bedtools"

printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -Eeuo pipefail' \
    'log=${SBATCH_TEST_LOG:?}' \
    'printf "%s\\n" "$*" >> "$log"' \
    'counter=${SBATCH_TEST_COUNTER:?}' \
    'n=$(<"$counter")' \
    'n=$((n + 1))' \
    'printf "%s\\n" "$n" > "$counter"' \
    'printf "%s;mockcluster\\n" "$n"' \
    > "$TEST_DIR/bin/sbatch"

# Git Bash on Windows does not ship util-linux flock. The production workflow
# requires the real command on Linux; this mock lets the portable test exercise
# all non-concurrency behavior.
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'exit 0' \
    > "$TEST_DIR/bin/flock"

printf '%s\n' \
    '#!/usr/bin/env bash' \
    'for argument in "$@"; do [[ "$argument" != -j ]] || exit 88; done' \
    'for ((i = 0; i < ${SQUEUE_TEST_ACTIVE:-0}; i++)); do printf "%s|RUNNING\n" "$((9000 + i))"; done' \
    > "$TEST_DIR/bin/squeue"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -Eeuo pipefail' \
    'log=${QSUB_TEST_LOG:?}' \
    'printf "%s\n" "$*" >> "$log"' \
    'counter=${QSUB_TEST_COUNTER:?}' \
    'n=$(<"$counter")' \
    'n=$((n + 1))' \
    'printf "%s\n" "$n" > "$counter"' \
    'range=""' \
    'while (($#)); do if [[ "$1" == -t ]]; then range=$2; break; fi; shift; done' \
    'if [[ -n "$range" ]]; then printf "%s.%s:1\n" "$n" "$range"; else printf "%s\n" "$n"; fi' \
    > "$TEST_DIR/bin/qsub"

printf '%s\n' \
    '#!/usr/bin/env bash' \
    'if [[ "${1:-}" == --version ]]; then printf "%s\n" "${QSTAT_TEST_VERSION:-OGS/GE 2011.11p1}"; exit 1; fi' \
    'printf "job-ID prior name user state submit/start at queue slots ja-task-ID\n"' \
    'printf "--------------------------------------------------------------------------------\n"' \
    'for ((i = 0; i < ${QSTAT_TEST_ACTIVE:-0}; i++)); do printf "%s 0.5 mock %s qw now 1 %s\n" "$((9100 + i))" "${USER:-tester}" "$((i + 1))"; done' \
    > "$TEST_DIR/bin/qstat"

printf '%s\n' \
    '#!/usr/bin/env bash' \
    'case "${1:-}" in' \
    '  -spl) printf "smp\nserial\n" ;;' \
    '  -sc) printf "h_vmem h_vmem MEMORY <= YES JOB 0 0\nh_rt h_rt TIME <= YES JOB 0 0\n" ;;' \
    '  *) exit 2 ;;' \
    'esac' \
    > "$TEST_DIR/bin/qconf"

chmod +x "$TEST_DIR/mitohpc/scripts/"* "$TEST_DIR/mitohpc/bin/"* "$TEST_DIR/bin/"*

# Submission test: accepts the alternate sample.bai name, stages the canonical
# name MitoHPC needs, and submits worker + summary + extraction.
printf '1000\n' > "$TEST_DIR/sbatch.counter"
: > "$TEST_DIR/sbatch.log"
PATH="$TEST_DIR/bin:$PATH" SBATCH_TEST_LOG="$TEST_DIR/sbatch.log" SBATCH_TEST_COUNTER="$TEST_DIR/sbatch.counter" \
    "$ROOT/mito_pipeline.sh" "$TEST_DIR/input" "$TEST_DIR/out" \
    --mitohpc-dir "$TEST_DIR/mitohpc" --extract-mt --reference-fasta "$TEST_DIR/mitohpc/RefSeq/hs38DH.fa" \
    > "$TEST_DIR/submit.stdout"

assert_file "$TEST_DIR/out/.mito-pipeline/alignments/alpha.bam"
assert_file "$TEST_DIR/out/.mito-pipeline/alignments/alpha.bam.bai"
[[ $(wc -l < "$TEST_DIR/sbatch.log") -eq 3 ]] || fail 'expected three sbatch calls'
assert_grep '--dependency=afterany:1001' "$TEST_DIR/sbatch.log"
assert_grep '--dependency=afterok:1001,afterany:1002' "$TEST_DIR/sbatch.log"
assert_grep 'MitoHPC jobs: 1001; summary job: 1003; extraction jobs: 1002' "$TEST_DIR/submit.stdout"

# A missing source index is created in output staging by a preliminary array;
# MitoHPC and summary jobs wait for that array to succeed.
mkdir -p "$TEST_DIR/input-auto"
printf 'bam-data\n' > "$TEST_DIR/input-auto/beta.bam"
: > "$TEST_DIR/sbatch.log"
PATH="$TEST_DIR/bin:$PATH" SBATCH_TEST_LOG="$TEST_DIR/sbatch.log" SBATCH_TEST_COUNTER="$TEST_DIR/sbatch.counter" \
    "$ROOT/mito_pipeline.sh" "$TEST_DIR/input-auto" "$TEST_DIR/out-auto" \
    --mitohpc-dir "$TEST_DIR/mitohpc" > "$TEST_DIR/auto.stdout"
[[ $(wc -l < "$TEST_DIR/sbatch.log") -eq 3 ]] || fail 'expected indexing, MitoHPC, and summary submissions'
assert_grep '--job-name=alignment_index' "$TEST_DIR/sbatch.log"
assert_grep '--dependency=afterok:1004' "$TEST_DIR/sbatch.log"
assert_grep 'Indexing jobs: 1004; MitoHPC jobs: 1005; summary job: 1006' "$TEST_DIR/auto.stdout"
auto_run_dir=$(find "$TEST_DIR/out-auto/.mito-pipeline/runs" -mindepth 1 -maxdepth 1 -type d | head -n 1)
auto_config="$auto_run_dir/config.env"
PATH="$TEST_DIR/bin:$PATH" SLURM_ARRAY_TASK_ID=0 SLURM_JOB_ID=2000 \
    "$ROOT/slurm/mitohpc_array.sh" --index "$auto_config"
assert_file "$TEST_DIR/out-auto/.mito-pipeline/alignments/beta.bam.bai"
PATH="$TEST_DIR/bin:$PATH" SLURM_ARRAY_TASK_ID=0 SLURM_JOB_ID=2001 \
    "$ROOT/slurm/mitohpc_array.sh" "$auto_config"
assert_file "$TEST_DIR/out-auto/samples/beta/beta.filter-called"

# Opting out retains strict validation.
if PATH="$TEST_DIR/bin:$PATH" "$ROOT/mito_pipeline.sh" "$TEST_DIR/input-auto" "$TEST_DIR/out-require" \
    --mitohpc-dir "$TEST_DIR/mitohpc" --require-indexes --dry-run \
    > "$TEST_DIR/require.stdout" 2> "$TEST_DIR/require.stderr"; then
    fail '--require-indexes accepted a missing index'
fi
assert_grep 'create the missing indexes or omit --require-indexes' "$TEST_DIR/require.stderr"

# Extraction-only submission creates one unblocked array and no summary.
: > "$TEST_DIR/sbatch.log"
PATH="$TEST_DIR/bin:$PATH" SBATCH_TEST_LOG="$TEST_DIR/sbatch.log" SBATCH_TEST_COUNTER="$TEST_DIR/sbatch.counter" \
    "$ROOT/mito_pipeline.sh" "$TEST_DIR/input" "$TEST_DIR/out-extract-only" \
    --mitohpc-dir "$TEST_DIR/mitohpc" --extract-only --reference-fasta "$TEST_DIR/mitohpc/RefSeq/hs38DH.fa" \
    > "$TEST_DIR/extract-only.stdout"
[[ $(wc -l < "$TEST_DIR/sbatch.log") -eq 1 ]] || fail 'extraction-only mode should submit one array'
assert_grep 'extraction jobs: 1007' "$TEST_DIR/extract-only.stdout"

# A cohort larger than the site's 1,000-task array limit is split into
# sequential arrays. The manifest offset passed to each worker preserves the
# sample mapping, while %20 limits the total number of concurrent tasks.
mkdir -p "$TEST_DIR/input-chunked"
for sample_number in $(seq -w 0 1000); do
    printf 'bam-data\n' > "$TEST_DIR/input-chunked/sample${sample_number}.bam"
    printf 'index-data\n' > "$TEST_DIR/input-chunked/sample${sample_number}.bam.bai"
done
: > "$TEST_DIR/sbatch.log"
PATH="$TEST_DIR/bin:$PATH" SBATCH_TEST_LOG="$TEST_DIR/sbatch.log" SBATCH_TEST_COUNTER="$TEST_DIR/sbatch.counter" \
    "$ROOT/mito_pipeline.sh" "$TEST_DIR/input-chunked" "$TEST_DIR/out-chunked" \
    --mitohpc-dir "$TEST_DIR/mitohpc" --max-array-size 1000 --max-parallel 20 --max-user-jobs 5000 \
    > "$TEST_DIR/chunked.stdout"
[[ $(wc -l < "$TEST_DIR/sbatch.log") -eq 3 ]] || fail 'expected two MitoHPC arrays and one summary submission'
assert_grep '--array=0-999%20' "$TEST_DIR/sbatch.log"
assert_grep '--array=0%1' "$TEST_DIR/sbatch.log"
assert_grep '--dependency=afterany:1008' "$TEST_DIR/sbatch.log"
assert_grep '--dependency=afterok:1008:1009' "$TEST_DIR/sbatch.log"
assert_grep 'MitoHPC jobs: 1008,1009; summary job: 1010' "$TEST_DIR/chunked.stdout"
chunked_run_dir=$(find "$TEST_DIR/out-chunked/.mito-pipeline/runs" -mindepth 1 -maxdepth 1 -type d | head -n 1)
chunked_config="$chunked_run_dir/config.env"
PATH="$TEST_DIR/bin:$PATH" SLURM_ARRAY_TASK_ID=0 SLURM_JOB_ID=2010 \
    "$ROOT/slurm/mitohpc_array.sh" "$chunked_config" 1000
assert_file "$TEST_DIR/out-chunked/samples/sample1000/sample1000.filter-called"

# MaxSubmitJobs counts every array element, including dependent stages. Bundle
# samples so a combined analysis/extraction run fits within the available quota.
mkdir -p "$TEST_DIR/input-quota"
for sample_number in $(seq 0 5); do
    printf 'bam-data\n' > "$TEST_DIR/input-quota/quota${sample_number}.bam"
    printf 'index-data\n' > "$TEST_DIR/input-quota/quota${sample_number}.bam.bai"
done
: > "$TEST_DIR/sbatch.log"
PATH="$TEST_DIR/bin:$PATH" SQUEUE_TEST_ACTIVE=2 SBATCH_TEST_LOG="$TEST_DIR/sbatch.log" SBATCH_TEST_COUNTER="$TEST_DIR/sbatch.counter" \
    "$ROOT/mito_pipeline.sh" "$TEST_DIR/input-quota" "$TEST_DIR/out-quota" \
    --mitohpc-dir "$TEST_DIR/mitohpc" --extract-mt \
    --reference-fasta "$TEST_DIR/mitohpc/RefSeq/hs38DH.fa" \
    --max-user-jobs 10 --job-headroom 2 > "$TEST_DIR/quota.stdout" 2> "$TEST_DIR/quota.stderr"
[[ $(wc -l < "$TEST_DIR/sbatch.log") -eq 3 ]] || fail 'quota-aware run should submit analysis, extraction, and summary'
[[ $(grep -c -- '--array=0-1%2' "$TEST_DIR/sbatch.log") -eq 2 ]] || fail 'quota-aware arrays were not bundled to two tasks each'
assert_grep "$ROOT/slurm mitohpc" "$TEST_DIR/sbatch.log"
assert_grep "$ROOT/slurm extract" "$TEST_DIR/sbatch.log"
assert_grep 'bundling up to 3 samples per task' "$TEST_DIR/quota.stderr"
assert_grep '2 already active, limit 10' "$TEST_DIR/quota.stderr"
assert_grep '--dependency=afterok:1011,afterany:1012' "$TEST_DIR/sbatch.log"
quota_run_dir=$(find "$TEST_DIR/out-quota/.mito-pipeline/runs" -mindepth 1 -maxdepth 1 -type d | head -n 1)
quota_config="$quota_run_dir/config.env"
PATH="$TEST_DIR/bin:$PATH" SLURM_ARRAY_TASK_ID=1 SLURM_JOB_ID=2011 \
    "$ROOT/slurm/bundle_array.sh" "$ROOT/slurm" mitohpc "$quota_config" 0 3 6
assert_file "$TEST_DIR/out-quota/samples/quota3/quota3.filter-called"
assert_file "$TEST_DIR/out-quota/samples/quota4/quota4.filter-called"
assert_file "$TEST_DIR/out-quota/samples/quota5/quota5.filter-called"

# SLURM copies submitted scripts into a spool directory without their sibling
# files. Simulate that behavior and verify explicit repository-path resolution.
mkdir -p "$TEST_DIR/spool"
cp "$ROOT/slurm/bundle_array.sh" "$TEST_DIR/spool/slurm_script"
cp "$ROOT/slurm/summary.sh" "$TEST_DIR/spool/summary_script"
chmod +x "$TEST_DIR/spool/slurm_script" "$TEST_DIR/spool/summary_script"
PATH="$TEST_DIR/bin:$PATH" SLURM_ARRAY_TASK_ID=0 SLURM_JOB_ID=2012 \
    "$TEST_DIR/spool/slurm_script" "$ROOT/slurm" mitohpc "$quota_config" 0 1 6
assert_file "$TEST_DIR/out-quota/samples/quota0/quota0.filter-called"
# Complete the remaining mocked bundle so the summary's scheduler-independent
# completeness guard sees a scientifically valid cohort.
PATH="$TEST_DIR/bin:$PATH" SLURM_ARRAY_TASK_ID=0 SLURM_JOB_ID=2012 \
    "$TEST_DIR/spool/slurm_script" "$ROOT/slurm" mitohpc "$quota_config" 1 2 6
assert_file "$TEST_DIR/out-quota/samples/quota1/quota1.filter-called"
assert_file "$TEST_DIR/out-quota/samples/quota2/quota2.filter-called"
PATH="$TEST_DIR/bin:$PATH" SLURM_JOB_ID=2013 \
    "$TEST_DIR/spool/summary_script" "$ROOT/slurm" "$quota_config"
assert_file "$TEST_DIR/out-quota/summary-called"

run_dir=$(find "$TEST_DIR/out/.mito-pipeline/runs" -mindepth 1 -maxdepth 1 -type d | head -n 1)
config="$run_dir/config.env"
assert_file "$config"

# Full MitoHPC worker and dependent summary paths.
PATH="$TEST_DIR/bin:$PATH" SLURM_ARRAY_TASK_ID=0 SLURM_JOB_ID=2001 \
    "$ROOT/slurm/mitohpc_array.sh" "$config"
assert_file "$TEST_DIR/out/samples/alpha/alpha.filter-called"
assert_file "$TEST_DIR/out/.mito-pipeline/status/mitohpc/alpha.ok"
PATH="$TEST_DIR/bin:$PATH" SLURM_JOB_ID=2002 "$ROOT/slurm/summary.sh" "$ROOT/slurm" "$config"
assert_file "$TEST_DIR/out/summary-called"
assert_file "$TEST_DIR/out/.mito-pipeline/status/summary.ok"

# Extraction writes both final files atomically and records success.
PATH="$TEST_DIR/bin:$PATH" SLURM_ARRAY_TASK_ID=0 SLURM_JOB_ID=3001 \
    "$ROOT/slurm/extract_array.sh" "$config"
assert_file "$TEST_DIR/out/extracted/alpha.cram"
assert_file "$TEST_DIR/out/extracted/alpha.cram.crai"
assert_file "$TEST_DIR/out/.mito-pipeline/status/extract/alpha.ok"

# Copy-number-only mode must bypass filter.sh and produce a count.
PATH="$TEST_DIR/bin:$PATH" "$ROOT/mito_pipeline.sh" "$TEST_DIR/input" "$TEST_DIR/out-copy" \
    --mitohpc-dir "$TEST_DIR/mitohpc" --iterations 0 --dry-run > "$TEST_DIR/copy.stdout"
copy_run_dir=$(find "$TEST_DIR/out-copy/.mito-pipeline/runs" -mindepth 1 -maxdepth 1 -type d | head -n 1)
copy_config="$copy_run_dir/config.env"
PATH="$TEST_DIR/bin:$PATH" SLURM_ARRAY_TASK_ID=0 SLURM_JOB_ID=4001 \
    "$ROOT/slurm/mitohpc_array.sh" "$copy_config"
assert_file "$TEST_DIR/out-copy/samples/alpha/alpha.count"
assert_file "$TEST_DIR/out-copy/.mito-pipeline/status/mitohpc/alpha.ok"
[[ ! -e "$TEST_DIR/out-copy/samples/alpha/alpha.filter-called" ]] || fail 'copy-number-only mode called filter.sh'

# A second invocation must be a no-op.
before=$(stat -c %Y "$TEST_DIR/out-copy/samples/alpha/alpha.count")
PATH="$TEST_DIR/bin:$PATH" SLURM_ARRAY_TASK_ID=0 SLURM_JOB_ID=4002 \
    "$ROOT/slurm/mitohpc_array.sh" "$copy_config"
after=$(stat -c %Y "$TEST_DIR/out-copy/samples/alpha/alpha.count")
[[ "$before" == "$after" ]] || fail 'completed sample was not skipped'

# Changed input/index provenance must stop rather than reuse stale output.
# Git Bash may emulate symlinks as copies, so mutate the staged index that the
# worker actually sees. On Linux this path is a symlink to the source index.
printf 'changed-index\n' >> "$TEST_DIR/out-copy/.mito-pipeline/alignments/alpha.bam.bai"
if PATH="$TEST_DIR/bin:$PATH" SLURM_ARRAY_TASK_ID=0 SLURM_JOB_ID=4003 \
    "$ROOT/slurm/mitohpc_array.sh" "$copy_config" > "$TEST_DIR/stale.stdout" 2> "$TEST_DIR/stale.stderr"; then
    fail 'changed input provenance was accepted'
fi
assert_grep 'different inputs/settings' "$TEST_DIR/stale.stderr"

# Expired SLURM job IDs can make `squeue -j ID` return nonzero. Resubmission
# must compare historical IDs against a successful snapshot of the active queue
# instead of querying each stale ID and exiting silently under pipefail.
mkdir -p "$TEST_DIR/input-stale-job" "$TEST_DIR/out-stale-job/.mito-pipeline/runs/old"
printf 'bam-data\n' > "$TEST_DIR/input-stale-job/stale.bam"
printf 'index-data\n' > "$TEST_DIR/input-stale-job/stale.bam.bai"
printf 'mitohpc_array_job\t99999999\n' > "$TEST_DIR/out-stale-job/.mito-pipeline/runs/old/run.txt"
: > "$TEST_DIR/sbatch.log"
PATH="$TEST_DIR/bin:$PATH" SBATCH_TEST_LOG="$TEST_DIR/sbatch.log" SBATCH_TEST_COUNTER="$TEST_DIR/sbatch.counter" \
    "$ROOT/mito_pipeline.sh" "$TEST_DIR/input-stale-job" "$TEST_DIR/out-stale-job" \
    --mitohpc-dir "$TEST_DIR/mitohpc" > "$TEST_DIR/stale-job.stdout"
[[ $(wc -l < "$TEST_DIR/sbatch.log") -eq 2 ]] || fail 'stale historical job ID prevented resubmission'
assert_grep 'Submitted 1 samples.' "$TEST_DIR/stale-job.stdout"

# Open Grid Scheduler 2011.11 submission: qsub uses one-based arrays, -tc
# throttling, -hold_jid dependencies, per-slot memory, and normalized job IDs.
printf '5000\n' > "$TEST_DIR/qsub.counter"
: > "$TEST_DIR/qsub.log"
PATH="$TEST_DIR/bin:$PATH" QSUB_TEST_LOG="$TEST_DIR/qsub.log" QSUB_TEST_COUNTER="$TEST_DIR/qsub.counter" \
    QSTAT_TEST_ACTIVE=2 "$ROOT/mito_pipeline_qsub.sh" "$TEST_DIR/input" "$TEST_DIR/out-ogs" \
    --mitohpc-dir "$TEST_DIR/mitohpc" --extract-mt \
    --reference-fasta "$TEST_DIR/mitohpc/RefSeq/hs38DH.fa" \
    --queue all.q --project mito --parallel-env smp \
    --memory-resource h_vmem --time-resource h_rt --qsub-resource exclusive=true \
    --max-user-jobs 100 --job-headroom 5 > "$TEST_DIR/ogs-submit.stdout"

[[ $(wc -l < "$TEST_DIR/qsub.log") -eq 3 ]] || fail 'expected three qsub calls'
assert_grep '-pe smp 4' "$TEST_DIR/qsub.log"
assert_grep '-l h_vmem=4096M' "$TEST_DIR/qsub.log"
assert_grep '-l h_rt=48:00:00' "$TEST_DIR/qsub.log"
assert_grep '-q all.q' "$TEST_DIR/qsub.log"
assert_grep '-P mito' "$TEST_DIR/qsub.log"
assert_grep '-l exclusive=true' "$TEST_DIR/qsub.log"
assert_grep '-t 1-1 -tc 1' "$TEST_DIR/qsub.log"
assert_grep '-hold_jid 5001' "$TEST_DIR/qsub.log"
assert_grep '-hold_jid 5001,5002' "$TEST_DIR/qsub.log"
assert_grep 'MitoHPC jobs: 5001; summary job: 5003; extraction jobs: 5002' "$TEST_DIR/ogs-submit.stdout"

# Grid Engine chunk chaining and missing-index dependencies use completion
# holds, while workers and the summary enforce scientific success explicitly.
mkdir -p "$TEST_DIR/input-ogs-chunk"
for sample_number in 0 1 2; do
    printf 'bam-data\n' > "$TEST_DIR/input-ogs-chunk/chunk${sample_number}.bam"
    printf 'index-data\n' > "$TEST_DIR/input-ogs-chunk/chunk${sample_number}.bam.bai"
done
: > "$TEST_DIR/qsub.log"
PATH="$TEST_DIR/bin:$PATH" QSUB_TEST_LOG="$TEST_DIR/qsub.log" QSUB_TEST_COUNTER="$TEST_DIR/qsub.counter" \
    "$ROOT/mito_pipeline_qsub.sh" "$TEST_DIR/input-ogs-chunk" "$TEST_DIR/out-ogs-chunk" \
    --mitohpc-dir "$TEST_DIR/mitohpc" --max-array-size 2 \
    --max-user-jobs 100 --job-headroom 5 > "$TEST_DIR/ogs-chunk.stdout"
[[ $(wc -l < "$TEST_DIR/qsub.log") -eq 3 ]] || fail 'expected two chunked qsub arrays and one summary'
assert_grep '-t 1-2 -tc 2' "$TEST_DIR/qsub.log"
assert_grep '-t 1-1 -tc 1 -o' "$TEST_DIR/qsub.log"
assert_grep '-hold_jid 5004' "$TEST_DIR/qsub.log"
assert_grep '-hold_jid 5004,5005' "$TEST_DIR/qsub.log"

mkdir -p "$TEST_DIR/input-ogs-index"
printf 'bam-data\n' > "$TEST_DIR/input-ogs-index/indexme.bam"
: > "$TEST_DIR/qsub.log"
PATH="$TEST_DIR/bin:$PATH" QSUB_TEST_LOG="$TEST_DIR/qsub.log" QSUB_TEST_COUNTER="$TEST_DIR/qsub.counter" \
    "$ROOT/mito_pipeline_qsub.sh" "$TEST_DIR/input-ogs-index" "$TEST_DIR/out-ogs-index" \
    --mitohpc-dir "$TEST_DIR/mitohpc" --max-user-jobs 100 --job-headroom 5 \
    > "$TEST_DIR/ogs-index.stdout"
[[ $(wc -l < "$TEST_DIR/qsub.log") -eq 3 ]] || fail 'expected Grid Engine index, analysis, and summary submissions'
assert_grep '-N alignment_index -t 1-1 -tc 1' "$TEST_DIR/qsub.log"
assert_grep '-hold_jid 5007' "$TEST_DIR/qsub.log"
assert_grep '-hold_jid 5008' "$TEST_DIR/qsub.log"
ogs_run_dir=$(find "$TEST_DIR/out-ogs/.mito-pipeline/runs" -mindepth 1 -maxdepth 1 -type d | head -n 1)
ogs_config="$ogs_run_dir/config.env"
assert_grep $'scheduler\togs' "$ogs_run_dir/run.txt"
assert_grep $'active_jobs_at_submit\t2' "$ogs_run_dir/run.txt"

# The Grid Engine entry wrapper converts SGE's one-based task ID to the
# zero-based worker coordinate used by the shared manifest implementation.
PATH="$TEST_DIR/bin:$PATH" SGE_TASK_ID=1 JOB_ID=6001 \
    bash "$ROOT/ogs/bundle_array.sh" "$ROOT/slurm" mitohpc "$ogs_config" 0 1 1 \
    "$TEST_DIR/out-ogs/logs" mitohpc
PATH="$TEST_DIR/bin:$PATH" SGE_TASK_ID=1 JOB_ID=6002 \
    bash "$ROOT/ogs/bundle_array.sh" "$ROOT/slurm" extract "$ogs_config" 0 1 1 \
    "$TEST_DIR/out-ogs/logs" extract
PATH="$TEST_DIR/bin:$PATH" JOB_ID=6003 \
    bash "$ROOT/ogs/summary.sh" "$ROOT/slurm" "$ogs_config" "$TEST_DIR/out-ogs/logs" summary
assert_file "$TEST_DIR/out-ogs/samples/alpha/alpha.filter-called"
assert_file "$TEST_DIR/out-ogs/extracted/alpha.cram"
assert_file "$TEST_DIR/out-ogs/summary-called"
assert_file "$TEST_DIR/out-ogs/logs/mitohpc_6001_0.out"
assert_file "$TEST_DIR/out-ogs/logs/mitohpc_6001_0.err"
assert_grep $'job_id\t6001' "$TEST_DIR/out-ogs/.mito-pipeline/status/mitohpc/alpha.ok"
assert_grep $'array_task_id\t0' "$TEST_DIR/out-ogs/.mito-pipeline/status/mitohpc/alpha.ok"

# The top-level detector can be overridden on hosts exposing both scheduler
# clients, and the qsub detector refuses PBS instead of using Grid Engine flags.
PATH="$TEST_DIR/bin:$PATH" QSUB_TEST_LOG="$TEST_DIR/qsub.log" QSUB_TEST_COUNTER="$TEST_DIR/qsub.counter" \
    "$ROOT/mito_pipeline_auto.sh" --scheduler qsub "$TEST_DIR/input" "$TEST_DIR/out-auto-ogs" \
    --mitohpc-dir "$TEST_DIR/mitohpc" --dry-run > "$TEST_DIR/auto-ogs.stdout"
auto_ogs_run=$(find "$TEST_DIR/out-auto-ogs/.mito-pipeline/runs" -mindepth 1 -maxdepth 1 -type d | head -n 1)
assert_grep $'scheduler\togs' "$auto_ogs_run/run.txt"
if PATH="$TEST_DIR/bin:$PATH" QSTAT_TEST_VERSION='PBSPro_2024' \
    "$ROOT/mito_pipeline_qsub.sh" "$TEST_DIR/input" "$TEST_DIR/out-pbs" \
    --mitohpc-dir "$TEST_DIR/mitohpc" > "$TEST_DIR/pbs.stdout" 2> "$TEST_DIR/pbs.stderr"; then
    fail 'PBS qsub was incorrectly accepted as Grid Engine'
fi
assert_grep 'detected a PBS/Torque qsub implementation' "$TEST_DIR/pbs.stderr"

printf 'PASS: pipeline integration tests\n'
