#!/usr/bin/env bash

job_die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

load_job_config() {
    (($# == 1)) || job_die 'internal error: expected config path'
    local config=$1
    [[ -r "$config" ]] || job_die "run configuration is not readable: $config"
    # The launcher creates this file with shell-escaped values and mode 0600.
    # shellcheck disable=SC1090
    source "$config"
    if [[ -n "${PROLOGUE:-}" ]]; then
        # shellcheck disable=SC1090
        set +u
        source "$PROLOGUE"
        set -u
    fi
    # setup_mitohpc.sh installs MitoHPC prerequisites under ../bin. Put those
    # pinned tools ahead of anything loaded by the optional cluster prologue.
    local mitohpc_bin
    mitohpc_bin=$(cd -- "$MITOHPC_SCRIPTS/../bin" 2>/dev/null && pwd -P) || mitohpc_bin=''
    if [[ -n "$mitohpc_bin" ]]; then
        export PATH="$mitohpc_bin:$PATH"
    fi
}

load_manifest_row() {
    local task_id=${SLURM_ARRAY_TASK_ID:-}
    local offset=${1:-0}
    [[ "$task_id" =~ ^[0-9]+$ ]] || job_die 'SLURM_ARRAY_TASK_ID is missing or invalid'
    [[ "$offset" =~ ^[0-9]+$ ]] || job_die 'manifest offset is invalid'
    local manifest_index=$((task_id + offset))
    local row
    row=$(sed -n "$((manifest_index + 1))p" "$MANIFEST")
    [[ -n "$row" ]] || job_die "array index $task_id with offset $offset is outside the manifest"
    IFS=$'\t' read -r SAMPLE ALIGNMENT OUTPUT_PREFIX <<< "$row"
    [[ -n "$SAMPLE" && -n "$ALIGNMENT" && -n "$OUTPUT_PREFIX" ]] || job_die "malformed manifest row for task $task_id with offset $offset"
}

initialize_mitohpc() {
    local init_script="$INIT_SCRIPT"
    [[ -r "$init_script" ]] || job_die "MitoHPC init script not found: $init_script"
    mkdir -p -- "$RUN_DIR/work"
    cd -- "$RUN_DIR/work"
    export HP_SDIR="$MITOHPC_SCRIPTS"
    set +u
    # shellcheck disable=SC1090
    source "$init_script"
    set -u
    if [[ -n "${HP_BDIR:-}" && -d "$HP_BDIR" ]]; then
        export PATH="$HP_BDIR:$PATH"
    fi
    export HP_IN="$MANIFEST"
    export HP_ODIR="$OUTPUT_DIR"
    export HP_ADIR="$(dirname -- "$ALIGNMENT")"
    export HP_M="$CALLER"
    export HP_I="$ITERATIONS"
    export HP_L="$MAX_MT_READS"
    export HP_DP="$MIN_DEPTH"
    export HP_P="$CPUS"
    export HP_MM="$TOOL_MEMORY"
    export HP_JOPT="-Xms$TOOL_MEMORY -Xmx$TOOL_MEMORY -XX:ParallelGCThreads=$CPUS"
}

detect_mt_contig() {
    local alignment=$1 requested=$2
    if [[ "$requested" != auto ]]; then
        printf '%s\n' "$requested"
        return
    fi
    local stats candidate
    stats=$(samtools idxstats "$alignment") || job_die "samtools idxstats failed for $alignment"
    for candidate in chrM MT M; do
        if awk -F '\t' -v name="$candidate" '$1 == name && $3 > 0 {found=1} END {exit !found}' <<< "$stats"; then
            printf '%s\n' "$candidate"
            return
        fi
    done
    job_die "could not detect a mitochondrial contig with mapped reads in $alignment; use --mt-contig"
}

acquire_sample_lock() {
    local stage=$1 sample=$2
    command -v flock >/dev/null 2>&1 || job_die 'flock is required on compute nodes'
    LOCK_FILE="$STATUS_DIR/$stage/$sample.lock"
    exec {LOCK_FD}> "$LOCK_FILE"
    flock -n "$LOCK_FD" || job_die "another job is processing $stage/$sample"
}

alignment_signature() {
    local index
    case "$ALIGNMENT" in
        *.bam) index="$ALIGNMENT.bai" ;;
        *.cram) index="$ALIGNMENT.crai" ;;
        *) job_die "unsupported staged alignment: $ALIGNMENT" ;;
    esac
    [[ -s "$ALIGNMENT" && -s "$index" ]] || job_die "alignment or index disappeared for $SAMPLE"
    printf '%s|%s\n' "$(stat -Lc '%s:%Y' "$ALIGNMENT")" "$(stat -Lc '%s:%Y' "$index")"
}

status_value() {
    local file=$1 key=$2
    awk -F '\t' -v key="$key" '$1 == key {print $2; exit}' "$file"
}

success_is_current() {
    local stage=$1 sample=$2 workflow_signature=$3 input_signature=$4
    local ok="$STATUS_DIR/$stage/$sample.ok"
    [[ -s "$ok" ]] || return 1
    [[ "$(status_value "$ok" workflow_signature)" == "$workflow_signature" && \
       "$(status_value "$ok" input_signature)" == "$input_signature" ]]
}

record_or_validate_attempt() {
    local stage=$1 sample=$2 workflow_signature=$3 input_signature=$4
    local attempt="$STATUS_DIR/$stage/$sample.attempt" tmp="$STATUS_DIR/$stage/.$sample.attempt.$$"
    if [[ -s "$attempt" ]]; then
        if [[ "$(status_value "$attempt" workflow_signature)" != "$workflow_signature" || \
              "$(status_value "$attempt" input_signature)" != "$input_signature" ]]; then
            job_die "existing $stage outputs for $sample were made from different inputs/settings; use a new output directory"
        fi
        return
    fi
    {
        printf 'started_utc\t%s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
        printf 'workflow_signature\t%s\n' "$workflow_signature"
        printf 'input_signature\t%s\n' "$input_signature"
    } > "$tmp"
    mv -f -- "$tmp" "$attempt"
}

release_sample_lock() {
    if [[ -n "${LOCK_FD:-}" ]]; then
        flock -u "$LOCK_FD" 2>/dev/null || true
        exec {LOCK_FD}>&-
    fi
}

write_failure_status() {
    local stage=$1 sample=$2 rc=$3
    local failed="$STATUS_DIR/$stage/$sample.failed" tmp="$STATUS_DIR/$stage/.$sample.failed.$$"
    {
        printf 'failed_utc\t%s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
        printf 'exit_code\t%s\n' "$rc"
        printf 'job_id\t%s\n' "${SLURM_JOB_ID:-unknown}"
        printf 'array_task_id\t%s\n' "${MITO_PIPELINE_ARRAY_TASK_ID:-${SLURM_ARRAY_TASK_ID:-unknown}}"
        printf 'manifest_index\t%s\n' "${MITO_PIPELINE_MANIFEST_INDEX:-unknown}"
        printf 'host\t%s\n' "$(hostname)"
    } > "$tmp"
    mv -f -- "$tmp" "$failed"
}

write_success_status() {
    local stage=$1 sample=$2 workflow_signature=$3 input_signature=$4
    local ok="$STATUS_DIR/$stage/$sample.ok" tmp="$STATUS_DIR/$stage/.$sample.ok.$$"
    rm -f -- "$STATUS_DIR/$stage/$sample.failed"
    {
        printf 'completed_utc\t%s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
        printf 'workflow_signature\t%s\n' "$workflow_signature"
        printf 'input_signature\t%s\n' "$input_signature"
        printf 'job_id\t%s\n' "${SLURM_JOB_ID:-unknown}"
        printf 'array_task_id\t%s\n' "${MITO_PIPELINE_ARRAY_TASK_ID:-${SLURM_ARRAY_TASK_ID:-unknown}}"
        printf 'manifest_index\t%s\n' "${MITO_PIPELINE_MANIFEST_INDEX:-unknown}"
        printf 'host\t%s\n' "$(hostname)"
    } > "$tmp"
    mv -f -- "$tmp" "$ok"
}
