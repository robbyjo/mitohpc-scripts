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
# A broken system samtools proves workers prefer MitoHPC's bundled executable.
printf '%s\n' '#!/usr/bin/env bash' 'exit 99' > "$TEST_DIR/bin/samtools"

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
    'for ((i = 0; i < ${SQUEUE_TEST_ACTIVE:-0}; i++)); do printf "%s\n" "$((9000 + i))"; done' \
    > "$TEST_DIR/bin/squeue"

chmod +x "$TEST_DIR/mitohpc/scripts/"* "$TEST_DIR/mitohpc/bin/samtools" "$TEST_DIR/bin/"*

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

printf 'PASS: pipeline integration tests\n'
