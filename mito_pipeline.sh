#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly VERSION="0.1.0"

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

log() {
    printf '[mito-pipeline] %s\n' "$*" >&2
}

usage() {
    cat <<'EOF'
Usage:
  mito_pipeline.sh INPUT_DIR OUTPUT_DIR [options]

Required positional arguments:
  INPUT_DIR                 Directory containing coordinate-sorted BAM/CRAM files
  OUTPUT_DIR                Directory for results, logs, and resumable state

Common options:
  --mitohpc-dir DIR         MitoHPC checkout (default: software/MitoHPC beside this script)
  --reference-profile NAME  MitoHPC init profile: default or init.NAME.sh (default: default)
  --recursive               Find alignments recursively below INPUT_DIR
  --extract-mt              Also create one mitochondrial CRAM per sample
  --extract-only            Create mitochondrial CRAMs without running MitoHPC
  --reference-fasta FILE    Alignment reference used when reading/writing CRAM
  --mt-contig NAME          Input mitochondrial contig, or auto (default: auto)
  --caller NAME             mutect2, mutserve, or freebayes (default: mutect2)
  --iterations N            MitoHPC iterations: 0, 1, or 2 (default: 2)
  --max-mt-reads N          Reads retained by MitoHPC; 0 means all (default: 222000)
  --min-depth N             Minimum variant depth (default: 100)

SLURM options:
  --cpus N                  CPUs per sample (default: 4)
  --memory SIZE             Memory per sample, e.g. 16G (default: 16G)
  --tool-memory SIZE        Per-process/tool memory limit (default: 3G)
  --time D-HH:MM:SS         Time per sample (default: 2-00:00:00)
  --max-parallel N          Maximum simultaneous array tasks (default: 50)
  --partition NAME          SLURM partition
  --account NAME            SLURM account
  --qos NAME                SLURM QoS
  --mail-user ADDRESS       SLURM notification address
  --mail-type TYPES         SLURM mail types (default: FAIL)
  --prologue FILE           Shell file sourced in every compute job (e.g. module loads)

Control options:
  --dry-run                 Validate and prepare a run, but do not call sbatch
  --version                 Print version
  -h, --help                Show this help

Rerunning the same command is safe: samples with a success marker are skipped.
EOF
}

absolute_dir() {
    local path=$1
    (cd -- "$path" 2>/dev/null && pwd -P) || return 1
}

absolute_file() {
    local path=$1 parent base
    parent=$(dirname -- "$path")
    base=$(basename -- "$path")
    parent=$(absolute_dir "$parent") || return 1
    printf '%s/%s\n' "$parent" "$base"
}

write_env() {
    local name=$1 value=$2
    printf '%s=%q\n' "$name" "$value"
}

find_index() {
    local alignment=$1 stem=${1%.*}
    case "$alignment" in
        *.bam)
            [[ -s "${alignment}.bai" ]] && { printf '%s\n' "${alignment}.bai"; return; }
            [[ -s "${stem}.bai" ]] && { printf '%s\n' "${stem}.bai"; return; }
            ;;
        *.cram)
            [[ -s "${alignment}.crai" ]] && { printf '%s\n' "${alignment}.crai"; return; }
            [[ -s "${stem}.crai" ]] && { printf '%s\n' "${stem}.crai"; return; }
            ;;
    esac
    return 1
}

find_idxstats() {
    local alignment=$1 stem=${1%.*}
    [[ -s "${stem}.idxstats" ]] && { printf '%s\n' "${stem}.idxstats"; return; }
    [[ -s "${alignment}.idxstats" ]] && { printf '%s\n' "${alignment}.idxstats"; return; }
    return 1
}

ensure_link() {
    local source=$1 target=$2 existing
    if [[ -L "$target" ]]; then
        existing=$(readlink -f -- "$target")
        [[ "$existing" == "$(readlink -f -- "$source")" ]] || \
            die "staging link already points elsewhere: $target"
    elif [[ -e "$target" ]]; then
        die "refusing to replace non-symlink staging path: $target"
    else
        ln -s -- "$source" "$target"
    fi
}

input_dir=''
output_dir=''
mitohpc_dir="$SCRIPT_DIR/software/MitoHPC"
reference_profile='default'
recursive=0
extract_mt=0
extract_only=0
reference_fasta=''
mt_contig='auto'
caller='mutect2'
iterations=2
max_mt_reads=222000
min_depth=100
cpus=4
memory='16G'
tool_memory='3G'
walltime='2-00:00:00'
max_parallel=50
partition=''
account=''
qos=''
mail_user=''
mail_type='FAIL'
prologue=''
dry_run=0

positional=()
while (($#)); do
    case "$1" in
        --mitohpc-dir|--reference-profile|--reference-fasta|--mt-contig|--caller|--iterations|--max-mt-reads|--min-depth|--cpus|--memory|--tool-memory|--time|--max-parallel|--partition|--account|--qos|--mail-user|--mail-type|--prologue)
            (($# >= 2)) || die "$1 requires a value"
            option=$1
            value=$2
            shift 2
            case "$option" in
                --mitohpc-dir) mitohpc_dir=$value ;;
                --reference-profile) reference_profile=$value ;;
                --reference-fasta) reference_fasta=$value ;;
                --mt-contig) mt_contig=$value ;;
                --caller) caller=$value ;;
                --iterations) iterations=$value ;;
                --max-mt-reads) max_mt_reads=$value ;;
                --min-depth) min_depth=$value ;;
                --cpus) cpus=$value ;;
                --memory) memory=$value ;;
                --tool-memory) tool_memory=$value ;;
                --time) walltime=$value ;;
                --max-parallel) max_parallel=$value ;;
                --partition) partition=$value ;;
                --account) account=$value ;;
                --qos) qos=$value ;;
                --mail-user) mail_user=$value ;;
                --mail-type) mail_type=$value ;;
                --prologue) prologue=$value ;;
            esac
            ;;
        --recursive) recursive=1; shift ;;
        --extract-mt) extract_mt=1; shift ;;
        --extract-only) extract_mt=1; extract_only=1; shift ;;
        --dry-run) dry_run=1; shift ;;
        --version) printf '%s\n' "$VERSION"; exit 0 ;;
        -h|--help) usage; exit 0 ;;
        --) shift; positional+=("$@"); break ;;
        -*) die "unknown option: $1 (use --help)" ;;
        *) positional+=("$1"); shift ;;
    esac
done

((${#positional[@]} == 2)) || { usage >&2; die 'INPUT_DIR and OUTPUT_DIR are required'; }
input_dir=${positional[0]}
output_dir=${positional[1]}

[[ "$caller" =~ ^(mutect2|mutserve|freebayes)$ ]] || die 'caller must be mutect2, mutserve, or freebayes'
[[ "$iterations" =~ ^[012]$ ]] || die 'iterations must be 0, 1, or 2'
[[ "$max_mt_reads" =~ ^[0-9]+$ ]] || die 'max-mt-reads must be a non-negative integer'
[[ "$min_depth" =~ ^[1-9][0-9]*$ ]] || die 'min-depth must be a positive integer'
[[ "$cpus" =~ ^[1-9][0-9]*$ ]] || die 'cpus must be a positive integer'
[[ "$max_parallel" =~ ^[1-9][0-9]*$ ]] || die 'max-parallel must be a positive integer'
[[ "$memory" =~ ^[1-9][0-9]*([KMGTP])?$ ]] || die 'memory must look like 16000M or 16G'
[[ "$tool_memory" =~ ^[1-9][0-9]*([KMGTP])?$ ]] || die 'tool-memory must look like 3000M or 3G'
[[ "$walltime" =~ ^([0-9]+-)?[0-9]{1,2}:[0-9]{2}(:[0-9]{2})?$ ]] || die 'time must look like HH:MM:SS or D-HH:MM:SS'
[[ "$mt_contig" != *$'\t'* && "$mt_contig" != *$'\n'* ]] || die 'mt-contig contains an invalid character'
[[ "$reference_profile" =~ ^[A-Za-z0-9._-]+$ ]] || die 'reference-profile contains unsafe characters'

[[ -d "$input_dir" ]] || die "input directory does not exist: $input_dir"
input_dir=$(absolute_dir "$input_dir")
mkdir -p -- "$output_dir"
output_dir=$(absolute_dir "$output_dir")

# MitoHPC v1 internally expands several paths without quotes. Fail early instead
# of allowing a long compute job to fail or, worse, write to the wrong location.
[[ "$output_dir" != *[[:space:]]* ]] || die 'MitoHPC cannot safely use an output path containing whitespace'

if [[ -d "$mitohpc_dir/scripts" ]]; then
    mitohpc_scripts=$(absolute_dir "$mitohpc_dir/scripts")
elif [[ -f "$mitohpc_dir/filter.sh" && -f "$mitohpc_dir/init.sh" ]]; then
    mitohpc_scripts=$(absolute_dir "$mitohpc_dir")
    mitohpc_dir=$(absolute_dir "$mitohpc_scripts/..")
else
    die "MitoHPC is not installed at $mitohpc_dir; run $SCRIPT_DIR/setup_mitohpc.sh"
fi
[[ -f "$mitohpc_scripts/filter.sh" ]] || die "missing MitoHPC worker: $mitohpc_scripts/filter.sh"
[[ -f "$mitohpc_scripts/getSummary.sh" ]] || die "missing MitoHPC summary script"
[[ -f "$mitohpc_scripts/idxstats2count.pl" ]] || die "missing MitoHPC count helper"
if [[ "$reference_profile" == default ]]; then
    init_script="$mitohpc_scripts/init.sh"
else
    init_script="$mitohpc_scripts/init.$reference_profile.sh"
fi
[[ -f "$init_script" ]] || die "MitoHPC reference profile not found: $init_script"
[[ "$mitohpc_scripts" != *[[:space:]]* ]] || die 'MitoHPC cannot safely run from a path containing whitespace'

if [[ -n "$reference_fasta" ]]; then
    [[ -s "$reference_fasta" ]] || die "reference FASTA does not exist or is empty: $reference_fasta"
    reference_fasta=$(absolute_file "$reference_fasta")
fi
if [[ -n "$prologue" ]]; then
    [[ -r "$prologue" ]] || die "prologue is not readable: $prologue"
    prologue=$(absolute_file "$prologue")
fi
((dry_run)) || command -v sbatch >/dev/null 2>&1 || die 'sbatch is not available; use --dry-run off-cluster'
command -v find >/dev/null 2>&1 || die 'find is required'
command -v cksum >/dev/null 2>&1 || die 'cksum is required'
command -v stat >/dev/null 2>&1 || die 'GNU stat is required'
command -v awk >/dev/null 2>&1 || die 'awk is required'

state_dir="$output_dir/.mito-pipeline"
staging_dir="$state_dir/alignments"
status_dir="$state_dir/status"
runs_dir="$state_dir/runs"
samples_dir="$output_dir/samples"
logs_dir="$output_dir/logs"
extracted_dir="$output_dir/extracted"
mkdir -p -- "$staging_dir" "$status_dir/mitohpc" "$status_dir/extract" "$runs_dir" "$samples_dir" "$logs_dir"
((extract_mt)) && mkdir -p -- "$extracted_dir"

if ((!dry_run)); then
    command -v squeue >/dev/null 2>&1 || die 'squeue is not available'
    while IFS= read -r previous_metadata; do
        for job_key in mitohpc_array_job extract_array_job; do
            previous_job=$(awk -F '\t' -v key="$job_key" '$1 == key {print $2; exit}' "$previous_metadata")
            [[ "$previous_job" =~ ^[0-9]+$ ]] || continue
            previous_state=$(squeue -h -j "$previous_job" -o '%T' 2>/dev/null | head -n 1)
            [[ -z "$previous_state" ]] || \
                die "job $previous_job is still $previous_state for this output directory; wait before resubmitting"
        done
    done < <(find "$runs_dir" -mindepth 2 -maxdepth 2 -name run.txt -type f -print)
fi

alignments=()
find_depth=(-maxdepth 1)
((recursive)) && find_depth=()
while IFS= read -r -d '' alignment; do
    alignments+=("$alignment")
done < <(find "$input_dir" "${find_depth[@]}" \( -type f -o -type l \) \( -name '*.bam' -o -name '*.cram' \) -print0)
((${#alignments[@]} > 0)) || die "no .bam or .cram files found in $input_dir"
IFS=$'\n' alignments=($(printf '%s\n' "${alignments[@]}" | LC_ALL=C sort)); unset IFS

run_stamp=$(date -u +'%Y%m%dT%H%M%SZ')
run_dir="$runs_dir/${run_stamp}-$$"
mkdir -p -- "$run_dir/work"
manifest="$run_dir/samples.tsv"
: > "$manifest"
declare -A seen_samples=()
missing_indexes=()

for alignment in "${alignments[@]}"; do
    [[ "$alignment" != *$'\t'* && "$alignment" != *$'\n'* ]] || die "input path contains a tab or newline: $alignment"
    filename=$(basename -- "$alignment")
    sample=${filename%.bam}
    sample=${sample%.cram}
    [[ "$sample" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || \
        die "unsafe sample name '$sample'; use only letters, digits, dot, underscore, and hyphen"
    [[ -z "${seen_samples[$sample]:-}" ]] || die "duplicate sample name '$sample' (filenames must be unique)"
    seen_samples[$sample]=1

    if ! index=$(find_index "$alignment"); then
        missing_indexes+=("$alignment")
        continue
    fi
    extension=${alignment##*.}
    staged_alignment="$staging_dir/$sample.$extension"
    staged_index="$staged_alignment.$([[ "$extension" == bam ]] && printf bai || printf crai)"
    ensure_link "$alignment" "$staged_alignment"
    ensure_link "$index" "$staged_index"
    if idxstats=$(find_idxstats "$alignment"); then
        ensure_link "$idxstats" "$staging_dir/$sample.idxstats"
    fi
    output_prefix="$samples_dir/$sample/$sample"
    printf '%s\t%s\t%s\n' "$sample" "$staged_alignment" "$output_prefix" >> "$manifest"
done

if ((${#missing_indexes[@]})); then
    printf 'ERROR: missing BAM/CRAM indexes for:\n' >&2
    printf '  %s\n' "${missing_indexes[@]}" >&2
    die 'create the missing indexes and submit again'
fi

sample_count=$(wc -l < "$manifest")
((sample_count > 0)) || die 'no usable indexed alignments were found'

code_signature=$(cksum "$init_script" "$mitohpc_scripts/filter.sh" \
    "$mitohpc_scripts/idxstats2count.pl" "$mitohpc_scripts/getSummary.sh" | cksum | awk '{print $1 "-" $2}')
mitohpc_signature=$(printf '%s\n' "$code_signature|$caller|$iterations|$max_mt_reads|$min_depth|$mt_contig" | \
    cksum | awk '{print $1 "-" $2}')
if [[ -n "$reference_fasta" ]]; then
    reference_signature=$(stat -Lc '%s:%Y' "$reference_fasta")
else
    reference_signature='mitohpc-default'
fi
extract_signature=$(printf '%s\n' "$mt_contig|$reference_fasta|$reference_signature" | cksum | awk '{print $1 "-" $2}')

config="$run_dir/config.env"
{
    write_env RUN_DIR "$run_dir"
    write_env MANIFEST "$manifest"
    write_env MITOHPC_SCRIPTS "$mitohpc_scripts"
    write_env INIT_SCRIPT "$init_script"
    write_env OUTPUT_DIR "$output_dir"
    write_env STATUS_DIR "$status_dir"
    write_env EXTRACTED_DIR "$extracted_dir"
    write_env REFERENCE_FASTA "$reference_fasta"
    write_env MT_CONTIG "$mt_contig"
    write_env CALLER "$caller"
    write_env ITERATIONS "$iterations"
    if ((max_mt_reads == 0)); then write_env MAX_MT_READS ''; else write_env MAX_MT_READS "$max_mt_reads"; fi
    write_env MIN_DEPTH "$min_depth"
    write_env CPUS "$cpus"
    write_env MEMORY "$memory"
    write_env TOOL_MEMORY "$tool_memory"
    write_env PROLOGUE "$prologue"
    write_env MITOHPC_SIGNATURE "$mitohpc_signature"
    write_env EXTRACT_SIGNATURE "$extract_signature"
} > "$config"
chmod 600 "$config"

metadata="$run_dir/run.txt"
{
    printf 'version\t%s\n' "$VERSION"
    printf 'created_utc\t%s\n' "$run_stamp"
    printf 'input_dir\t%s\n' "$input_dir"
    printf 'output_dir\t%s\n' "$output_dir"
    printf 'mitohpc_dir\t%s\n' "$mitohpc_dir"
    printf 'reference_profile\t%s\n' "$reference_profile"
    printf 'samples\t%s\n' "$sample_count"
    if command -v git >/dev/null 2>&1 && git -C "$mitohpc_dir" rev-parse HEAD >/dev/null 2>&1; then
        printf 'mitohpc_commit\t%s\n' "$(git -C "$mitohpc_dir" rev-parse HEAD)"
    fi
} > "$metadata"

log "validated $sample_count indexed sample(s)"
log "run record: $run_dir"
if ((dry_run)); then
    log 'dry run complete; no jobs submitted'
    printf 'Manifest: %s\n' "$manifest"
    exit 0
fi

common_sbatch=(--parsable --export=ALL --cpus-per-task="$cpus" --mem="$memory" --time="$walltime")
[[ -z "$partition" ]] || common_sbatch+=(--partition="$partition")
[[ -z "$account" ]] || common_sbatch+=(--account="$account")
[[ -z "$qos" ]] || common_sbatch+=(--qos="$qos")
if [[ -n "$mail_user" ]]; then
    common_sbatch+=(--mail-user="$mail_user" --mail-type="$mail_type")
fi

array_range="0-$((sample_count - 1))%$max_parallel"
mitohpc_job=''
extract_job=''
summary_job=''
if ((!extract_only)); then
    mitohpc_job=$(sbatch "${common_sbatch[@]}" \
        --job-name=mitohpc \
        --array="$array_range" \
        --output="$logs_dir/mitohpc_%A_%a.out" \
        --error="$logs_dir/mitohpc_%A_%a.err" \
        "$SCRIPT_DIR/slurm/mitohpc_array.sh" "$config")
    mitohpc_job=${mitohpc_job%%;*}
    [[ "$mitohpc_job" =~ ^[0-9]+$ ]] || die "could not parse MitoHPC job ID: $mitohpc_job"
    printf 'mitohpc_array_job\t%s\n' "$mitohpc_job" >> "$metadata"
    log "submitted MitoHPC array job $mitohpc_job"
fi

if ((extract_mt)); then
    extract_dependency=()
    ((extract_only)) || extract_dependency+=(--dependency="afterany:$mitohpc_job")
    extract_job=$(sbatch "${common_sbatch[@]}" "${extract_dependency[@]}" \
        --job-name=extract_mt \
        --array="$array_range" \
        --output="$logs_dir/extract_%A_%a.out" \
        --error="$logs_dir/extract_%A_%a.err" \
        "$SCRIPT_DIR/slurm/extract_array.sh" "$config")
    extract_job=${extract_job%%;*}
    [[ "$extract_job" =~ ^[0-9]+$ ]] || die "could not parse extraction job ID: $extract_job"
    printf 'extract_array_job\t%s\n' "$extract_job" >> "$metadata"
    if ((extract_only)); then
        log "submitted mitochondrial extraction array job $extract_job"
    else
        log "submitted extraction array job $extract_job after MitoHPC job $mitohpc_job"
    fi
fi

if ((!extract_only)); then
    summary_sbatch=(--parsable --export=ALL --cpus-per-task=1 --mem=8G --time=04:00:00)
    [[ -z "$partition" ]] || summary_sbatch+=(--partition="$partition")
    [[ -z "$account" ]] || summary_sbatch+=(--account="$account")
    [[ -z "$qos" ]] || summary_sbatch+=(--qos="$qos")
    if [[ -n "$mail_user" ]]; then
        summary_sbatch+=(--mail-user="$mail_user" --mail-type="$mail_type")
    fi
    summary_dependency="afterok:$mitohpc_job"
    ((extract_mt)) && summary_dependency+=",afterany:$extract_job"
    summary_job=$(sbatch "${summary_sbatch[@]}" \
        --dependency="$summary_dependency" \
        --job-name=mitohpc_summary \
        --output="$logs_dir/summary_%j.out" \
        --error="$logs_dir/summary_%j.err" \
        "$SCRIPT_DIR/slurm/summary.sh" "$config")
    summary_job=${summary_job%%;*}
    [[ "$summary_job" =~ ^[0-9]+$ ]] || die "could not parse summary job ID: $summary_job"
    printf 'summary_job\t%s\n' "$summary_job" >> "$metadata"
    log "submitted dependent summary job $summary_job"
fi

printf 'Submitted %s samples.' "$sample_count"
((extract_only)) || printf ' MitoHPC job: %s; summary job: %s' "$mitohpc_job" "$summary_job"
((extract_mt)) && printf '; extraction job: %s' "$extract_job"
printf '\nResults: %s\nLogs: %s\n' "$output_dir" "$logs_dir"
