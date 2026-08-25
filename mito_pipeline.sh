#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly VERSION="0.1.1"

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
  --time D-HH:MM:SS         Time per array task (default: 2-00:00:00)
  --max-parallel N          Maximum simultaneous array tasks (default: 20)
  --max-array-size N        Maximum tasks in one array (default: 1000)
  --max-user-jobs N         Association submit-job limit (default: 1000)
  --job-headroom N          Job slots reserved for other work (default: 20)
  --partition NAME          SLURM partition
  --account NAME            SLURM account
  --qos NAME                SLURM QoS
  --mail-user ADDRESS       SLURM notification address
  --mail-type TYPES         SLURM mail types (default: FAIL)
  --prologue FILE           Shell file sourced in every compute job (e.g. module loads)

Control options:
  --require-indexes         Fail instead of scheduling creation of missing indexes
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
max_parallel=20
max_array_size=1000
max_user_jobs=1000
job_headroom=20
partition=''
account=''
qos=''
mail_user=''
mail_type='FAIL'
prologue=''
dry_run=0
create_indexes=1

positional=()
while (($#)); do
    case "$1" in
        --mitohpc-dir|--reference-profile|--reference-fasta|--mt-contig|--caller|--iterations|--max-mt-reads|--min-depth|--cpus|--memory|--tool-memory|--time|--max-parallel|--max-array-size|--max-user-jobs|--job-headroom|--partition|--account|--qos|--mail-user|--mail-type|--prologue)
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
                --max-array-size) max_array_size=$value ;;
                --max-user-jobs) max_user_jobs=$value ;;
                --job-headroom) job_headroom=$value ;;
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
        --require-indexes) create_indexes=0; shift ;;
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
[[ "$max_array_size" =~ ^[1-9][0-9]*$ ]] || die 'max-array-size must be a positive integer'
[[ "$max_user_jobs" =~ ^[1-9][0-9]*$ ]] || die 'max-user-jobs must be a positive integer'
[[ "$job_headroom" =~ ^[0-9]+$ ]] || die 'job-headroom must be a non-negative integer'
((job_headroom < max_user_jobs)) || die 'job-headroom must be smaller than max-user-jobs'
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
for helper in bundle_array.sh job_common.sh mitohpc_array.sh extract_array.sh summary.sh; do
    [[ -r "$SCRIPT_DIR/slurm/$helper" ]] || die "required pipeline helper is not readable: $SCRIPT_DIR/slurm/$helper"
done

state_dir="$output_dir/.mito-pipeline"
staging_dir="$state_dir/alignments"
status_dir="$state_dir/status"
runs_dir="$state_dir/runs"
samples_dir="$output_dir/samples"
logs_dir="$output_dir/logs"
extracted_dir="$output_dir/extracted"
mkdir -p -- "$staging_dir" "$status_dir/mitohpc" "$status_dir/extract" "$runs_dir" "$samples_dir" "$logs_dir"
mkdir -p -- "$status_dir/index"
((extract_mt)) && mkdir -p -- "$extracted_dir"

if ((!dry_run)); then
    command -v squeue >/dev/null 2>&1 || die 'squeue is not available'
    while IFS= read -r previous_metadata; do
        for job_key in index_array_job mitohpc_array_job extract_array_job; do
            while IFS= read -r previous_job; do
                [[ "$previous_job" =~ ^[0-9]+$ ]] || continue
                previous_state=$(squeue -h -j "$previous_job" -o '%T' 2>/dev/null | head -n 1)
                [[ -z "$previous_state" ]] || \
                    die "job $previous_job is still $previous_state for this output directory; wait before resubmitting"
            done < <(awk -F '\t' -v key="$job_key" '$1 == key {print $2}' "$previous_metadata")
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
index_manifest="$run_dir/indexes.tsv"
: > "$index_manifest"
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

    extension=${alignment##*.}
    staged_alignment="$staging_dir/$sample.$extension"
    staged_index="$staged_alignment.$([[ "$extension" == bam ]] && printf bai || printf crai)"
    ensure_link "$alignment" "$staged_alignment"
    if index=$(find_index "$alignment"); then
        ensure_link "$index" "$staged_index"
    else
        missing_indexes+=("$alignment")
        if ((create_indexes)); then
            [[ ! -L "$staged_index" ]] || die "refusing dangling staged index link: $staged_index"
            printf '%s\t%s\t%s\n' "$sample" "$staged_alignment" "$staged_index" >> "$index_manifest"
        fi
    fi
    if idxstats=$(find_idxstats "$alignment"); then
        ensure_link "$idxstats" "$staging_dir/$sample.idxstats"
    fi
    output_prefix="$samples_dir/$sample/$sample"
    printf '%s\t%s\t%s\n' "$sample" "$staged_alignment" "$output_prefix" >> "$manifest"
done

if ((${#missing_indexes[@]})); then
    if ((!create_indexes)); then
        printf 'ERROR: missing BAM/CRAM indexes for:\n' >&2
        printf '  %s\n' "${missing_indexes[@]}" >&2
        die 'create the missing indexes or omit --require-indexes and submit again'
    fi
    log "will create ${#missing_indexes[@]} missing index(es) in $staging_dir"
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
    write_env INDEX_MANIFEST "$index_manifest"
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

log "validated $sample_count sample(s)"
log "run record: $run_dir"
if ((dry_run)); then
    log 'dry run complete; no jobs submitted'
    printf 'Manifest: %s\n' "$manifest"
    exit 0
fi

planned_jobs_for_bundle() {
    local size=$1 planned=0
    ((${#missing_indexes[@]} == 0)) || planned=$((planned + (${#missing_indexes[@]} + size - 1) / size))
    ((extract_only)) || planned=$((planned + (sample_count + size - 1) / size + 1))
    ((extract_mt)) && planned=$((planned + (sample_count + size - 1) / size))
    printf '%s\n' "$planned"
}

queue_user=${USER:-}
[[ -n "$queue_user" ]] || queue_user=$(id -un)
active_job_count=$(squeue -h -r -u "$queue_user" -o '%i' 2>/dev/null | awk 'NF {count++} END {print count + 0}')
available_job_slots=$((max_user_jobs - job_headroom - active_job_count))
minimum_pipeline_jobs=$(planned_jobs_for_bundle "$sample_count")
if ((available_job_slots < minimum_pipeline_jobs)); then
    die "only $available_job_slots submit-job slot(s) remain ($active_job_count active, limit $max_user_jobs, headroom $job_headroom); wait for jobs to finish or lower --job-headroom"
fi

low=1
high=$sample_count
while ((low < high)); do
    middle=$(((low + high) / 2))
    if (($(planned_jobs_for_bundle "$middle") <= available_job_slots)); then
        high=$middle
    else
        low=$((middle + 1))
    fi
done
bundle_size=$low
planned_job_count=$(planned_jobs_for_bundle "$bundle_size")
printf 'bundle_size\t%s\nactive_jobs_at_submit\t%s\nplanned_jobs\t%s\n' \
    "$bundle_size" "$active_job_count" "$planned_job_count" >> "$metadata"
if ((bundle_size > 1)); then
    log "submit-job quota: bundling up to $bundle_size samples per task ($planned_job_count new jobs, $active_job_count already active, limit $max_user_jobs)"
    log "--time applies to the whole bundle; use --partition nhlbi and a suitable --time if bundled samples need longer"
fi

common_sbatch=(--parsable --export=ALL --nodes=1 --cpus-per-task="$cpus" --mem="$memory" --time="$walltime")
[[ -z "$partition" ]] || common_sbatch+=(--partition="$partition")
[[ -z "$account" ]] || common_sbatch+=(--account="$account")
[[ -z "$qos" ]] || common_sbatch+=(--qos="$qos")
if [[ -n "$mail_user" ]]; then
    common_sbatch+=(--mail-user="$mail_user" --mail-type="$mail_type")
fi

run_sbatch() {
    local output
    if ! output=$(sbatch "$@" 2>&1); then
        printf 'ERROR: sbatch failed: %s\n' "$output" >&2
        if [[ "$output" == *AssocMaxSubmitJobLimit* ]]; then
            printf 'ERROR: the association submit-job quota changed or filled after preflight; wait for jobs to finish or lower --max-user-jobs.\n' >&2
        fi
        return 1
    fi
    printf '%s\n' "$output"
}

make_array_spec() {
    local count=$1 parallel=$max_parallel
    ((parallel <= count)) || parallel=$count
    if ((count == 1)); then
        printf '0%%%s\n' "$parallel"
    else
        printf '0-%s%%%s\n' "$((count - 1))" "$parallel"
    fi
}

join_job_ids() {
    local separator=$1
    shift
    (IFS="$separator"; printf '%s' "$*")
}

submit_chunked_arrays() {
    local -n result_jobs=$1
    local total=$2 stage=$3 job_name=$4 log_prefix=$5 metadata_key=$6 base_dependency=$7
    local offset items count array_spec dependency job_id previous_job=''
    local dependency_arg=()
    local max_items_per_array=$((max_array_size * bundle_size))
    for ((offset = 0; offset < total; offset += max_items_per_array)); do
        items=$((total - offset))
        ((items <= max_items_per_array)) || items=$max_items_per_array
        count=$(((items + bundle_size - 1) / bundle_size))
        array_spec=$(make_array_spec "$count")
        dependency=$base_dependency
        if [[ -n "$previous_job" ]]; then
            [[ -z "$dependency" ]] || dependency+=','
            dependency+="afterany:$previous_job"
        fi
        dependency_arg=()
        [[ -z "$dependency" ]] || dependency_arg+=(--dependency="$dependency")
        job_id=$(run_sbatch "${common_sbatch[@]}" "${dependency_arg[@]}" \
            --job-name="$job_name" \
            --array="$array_spec" \
            --output="$logs_dir/${log_prefix}_%A_%a.out" \
            --error="$logs_dir/${log_prefix}_%A_%a.err" \
            "$SCRIPT_DIR/slurm/bundle_array.sh" "$SCRIPT_DIR/slurm" "$stage" "$config" "$offset" "$bundle_size" "$total")
        job_id=${job_id%%;*}
        [[ "$job_id" =~ ^[0-9]+$ ]] || die "could not parse $job_name job ID: $job_id"
        result_jobs+=("$job_id")
        printf '%s\t%s\n' "$metadata_key" "$job_id" >> "$metadata"
        log "submitted $job_name array job $job_id: --array=$array_spec, manifest offset $offset, bundle size $bundle_size"
        previous_job=$job_id
    done
}

index_jobs=()
mitohpc_jobs=()
extract_jobs=()
summary_job=''
if ((${#missing_indexes[@]})); then
    submit_chunked_arrays index_jobs "${#missing_indexes[@]}" index alignment_index index index_array_job ''
fi

index_afterok=''
((${#index_jobs[@]} == 0)) || index_afterok="afterok:$(join_job_ids : "${index_jobs[@]}")"
if ((!extract_only)); then
    submit_chunked_arrays mitohpc_jobs "$sample_count" mitohpc mitohpc mitohpc mitohpc_array_job "$index_afterok"
fi

if ((extract_mt)); then
    extract_dependencies=()
    [[ -z "$index_afterok" ]] || extract_dependencies+=("$index_afterok")
    ((extract_only)) || extract_dependencies+=("afterany:${mitohpc_jobs[-1]}")
    extract_base_dependency=$(join_job_ids , "${extract_dependencies[@]}")
    submit_chunked_arrays extract_jobs "$sample_count" extract extract_mt extract extract_array_job "$extract_base_dependency"
fi
if ((!extract_only)); then
    summary_sbatch=(--parsable --export=ALL --nodes=1 --cpus-per-task=1 --mem=8G --time=04:00:00)
    [[ -z "$partition" ]] || summary_sbatch+=(--partition="$partition")
    [[ -z "$account" ]] || summary_sbatch+=(--account="$account")
    [[ -z "$qos" ]] || summary_sbatch+=(--qos="$qos")
    if [[ -n "$mail_user" ]]; then
        summary_sbatch+=(--mail-user="$mail_user" --mail-type="$mail_type")
    fi
    summary_dependency="afterok:$(join_job_ids : "${mitohpc_jobs[@]}")"
    ((extract_mt)) && summary_dependency+=",afterany:${extract_jobs[-1]}"
    summary_job=$(run_sbatch "${summary_sbatch[@]}" \
        --dependency="$summary_dependency" \
        --job-name=mitohpc_summary \
        --output="$logs_dir/summary_%j.out" \
        --error="$logs_dir/summary_%j.err" \
        "$SCRIPT_DIR/slurm/summary.sh" "$SCRIPT_DIR/slurm" "$config")
    summary_job=${summary_job%%;*}
    [[ "$summary_job" =~ ^[0-9]+$ ]] || die "could not parse summary job ID: $summary_job"
    printf 'summary_job\t%s\n' "$summary_job" >> "$metadata"
    log "submitted dependent summary job $summary_job"
fi
printf 'Submitted %s samples.' "$sample_count"
(( ${#index_jobs[@]} == 0 )) || printf ' Indexing jobs: %s;' "$(join_job_ids , "${index_jobs[@]}")"
((extract_only)) || printf ' MitoHPC jobs: %s; summary job: %s' "$(join_job_ids , "${mitohpc_jobs[@]}")" "$summary_job"
((extract_mt)) && printf '; extraction jobs: %s' "$(join_job_ids , "${extract_jobs[@]}")"
printf '\nResults: %s\nLogs: %s\n' "$output_dir" "$logs_dir"
