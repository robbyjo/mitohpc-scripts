#!/usr/bin/env bash
set -uo pipefail
IFS=$'\n\t'

usage() {
    cat <<'EOF'
Usage:
  diagnose_mitohpc.sh PIPELINE_DIR [OUTPUT_DIR] [REPORT_FILE]

Examples:
  bash diagnose_mitohpc.sh /data/$USER/mitohpc-scripts
  bash diagnose_mitohpc.sh /data/$USER/mitohpc-scripts /data/$USER/mito-results

This script is read-only except for creating REPORT_FILE. It does not submit,
cancel, or modify SLURM jobs, pipeline output, input alignments, or indexes.
EOF
}

if (($# < 1 || $# > 3)); then
    usage >&2
    exit 2
fi

pipeline_dir=$1
output_dir=${2:-}
report=${3:-"mitohpc_diagnostic_$(date -u +'%Y%m%dT%H%M%SZ')_$(hostname -s).txt"}

if [[ ! -d "$pipeline_dir" ]]; then
    printf 'ERROR: pipeline directory does not exist: %s\n' "$pipeline_dir" >&2
    exit 2
fi
pipeline_dir=$(cd -- "$pipeline_dir" && pwd -P)

if [[ -n "$output_dir" ]]; then
    if [[ ! -d "$output_dir" ]]; then
        printf 'ERROR: output directory does not exist: %s\n' "$output_dir" >&2
        exit 2
    fi
    output_dir=$(cd -- "$output_dir" && pwd -P)
fi

report_parent=$(dirname -- "$report")
mkdir -p -- "$report_parent" || exit 2
if [[ -e "$report" ]]; then
    printf 'ERROR: refusing to overwrite existing report: %s\n' "$report" >&2
    exit 2
fi

exec > >(tee "$report") 2>&1

section() {
    printf '\n===== %s =====\n' "$*"
}

show_command() {
    printf '\n$'
    printf ' %q' "$@"
    printf '\n'
    "$@"
    local rc=$?
    if ((rc != 0)); then
        printf '[exit status: %s]\n' "$rc"
    fi
    return 0
}

count_files() {
    local root=$1 pattern=$2
    find "$root" -type f -name "$pattern" -printf '.' 2>/dev/null | wc -c
}

section 'Diagnostic notice'
printf '%s\n' \
    'This report contains usernames, hostnames, filesystem paths, and SLURM job IDs.' \
    'It does not intentionally print environment variables, alignment contents, or config.env.' \
    'Review the report before forwarding it.'

section 'Host and time'
show_command date -u
show_command hostname -f
show_command id
show_command uname -a
printf 'working_directory=%s\n' "$PWD"
printf 'pipeline_directory=%s\n' "$pipeline_dir"
printf 'output_directory=%s\n' "${output_dir:-not supplied}"

section 'Pipeline files'
for file in \
    mito_pipeline.sh \
    setup_mitohpc.sh \
    slurm/bundle_array.sh \
    slurm/job_common.sh \
    slurm/mitohpc_array.sh \
    slurm/extract_array.sh \
    slurm/summary.sh; do
    path="$pipeline_dir/$file"
    if [[ -e "$path" ]]; then
        ls -l -- "$path"
        file -- "$path" 2>/dev/null || true
    else
        printf 'MISSING: %s\n' "$path"
    fi
done

section 'Pipeline syntax'
syntax_files=()
for path in "$pipeline_dir/mito_pipeline.sh" "$pipeline_dir"/slurm/*.sh; do
    [[ -f "$path" ]] && syntax_files+=("$path")
done
if ((${#syntax_files[@]})); then
    if bash -n "${syntax_files[@]}"; then
        printf 'PASS: bash syntax check\n'
    else
        printf 'FAIL: bash syntax check\n'
    fi
else
    printf 'FAIL: no pipeline shell scripts found\n'
fi

section 'Required fix markers'
if grep -q -- '--max-user-jobs' "$pipeline_dir/mito_pipeline.sh" 2>/dev/null; then
    printf 'PASS: quota-aware launcher option is present\n'
else
    printf 'FAIL: quota-aware launcher option is absent (old launcher)\n'
fi
if grep -q -- 'bundle_array.sh.*SCRIPT_DIR/slurm' "$pipeline_dir/mito_pipeline.sh" 2>/dev/null; then
    printf 'PASS: launcher passes the shared slurm directory to bundle jobs\n'
else
    printf 'FAIL: shared slurm directory argument is absent (spool-path bug likely)\n'
fi
if grep -q -- 'summary.sh.*SCRIPT_DIR/slurm' "$pipeline_dir/mito_pipeline.sh" 2>/dev/null; then
    printf 'PASS: launcher passes the shared slurm directory to summary jobs\n'
else
    printf 'FAIL: summary shared-directory argument is absent\n'
fi
if [[ -r "$pipeline_dir/slurm/bundle_array.sh" ]]; then
    printf 'PASS: bundle worker is readable\n'
else
    printf 'FAIL: bundle worker is missing or unreadable\n'
fi

section 'Git revision'
if command -v git >/dev/null 2>&1 && git -C "$pipeline_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    show_command git -C "$pipeline_dir" log -1 --oneline
    show_command git -C "$pipeline_dir" status --short --branch
    show_command git -C "$pipeline_dir" remote -v
else
    printf 'Pipeline directory is not a Git working tree, or git is unavailable.\n'
fi

section 'SLURM commands and limits'
for command_name in sbatch squeue sacct batchlim jobhist samtools; do
    if command -v "$command_name" >/dev/null 2>&1; then
        printf '%s=%s\n' "$command_name" "$(command -v "$command_name")"
    else
        printf 'MISSING_COMMAND=%s\n' "$command_name"
    fi
done
command -v sbatch >/dev/null 2>&1 && show_command sbatch --version
command -v batchlim >/dev/null 2>&1 && show_command batchlim
bundled_samtools="$pipeline_dir/software/MitoHPC/bin/samtools"
if [[ -x "$bundled_samtools" ]]; then
    printf 'bundled_samtools=%s\n' "$bundled_samtools"
    show_command "$bundled_samtools" --version
else
    printf 'MISSING_BUNDLED_SAMTOOLS=%s\n' "$bundled_samtools"
fi

section 'Currently pending or running jobs'
if command -v squeue >/dev/null 2>&1; then
    show_command squeue -r -u "${USER:-$(id -un)}" -o '%.24i %.18j %.10P %.10T %.30R %.12M %.12l'
else
    printf 'squeue is unavailable.\n'
fi

section 'Recent accounting records (last 100 lines since today)'
if command -v sacct >/dev/null 2>&1; then
    sacct -S today -u "${USER:-$(id -un)}" -X \
        --format=JobIDRaw,JobName,Partition,State,ExitCode,Elapsed,Reason 2>&1 | tail -n 100
    printf 'sacct_exit_status=%s\n' "${PIPESTATUS[0]}"
else
    printf 'sacct is unavailable.\n'
fi

latest_run=''
if [[ -n "$output_dir" ]]; then
    section 'Output inventory'
    printf 'count_files=%s\n' "$(count_files "$output_dir" '*.count')"
    printf 'extracted_crams=%s\n' "$(count_files "$output_dir" '*.cram')"
    printf 'extracted_crais=%s\n' "$(count_files "$output_dir" '*.crai')"
    printf 'nonempty_error_logs=%s\n' "$(find "$output_dir/logs" -type f -name '*.err' -size +0c -printf '.' 2>/dev/null | wc -c)"

    section 'Latest run record'
    if [[ -d "$output_dir/.mito-pipeline/runs" ]]; then
        latest_run=$(find "$output_dir/.mito-pipeline/runs" -mindepth 1 -maxdepth 1 \
            -type d -printf '%T@\t%p\n' 2>/dev/null | sort -nr | head -n 1 | cut -f 2-)
    fi
    if [[ -n "$latest_run" && -r "$latest_run/run.txt" ]]; then
        printf 'latest_run=%s\n' "$latest_run"
        cat -- "$latest_run/run.txt"
        if grep -q $'^bundle_size\t' "$latest_run/run.txt"; then
            printf 'PASS: latest run was created by the quota-aware launcher\n'
        else
            printf 'FAIL: latest run has no bundle_size and was created by an older launcher\n'
        fi

        section 'Latest run job accounting'
        if command -v sacct >/dev/null 2>&1; then
            while IFS=$'\t' read -r key job_id; do
                case "$key" in
                    index_array_job|mitohpc_array_job|extract_array_job|summary_job)
                        [[ "$job_id" =~ ^[0-9]+$ ]] || continue
                        printf '\n--- %s %s ---\n' "$key" "$job_id"
                        sacct -X -j "$job_id" \
                            --format=JobIDRaw,JobName,Partition,State,ExitCode,Elapsed,Reason 2>&1 | head -n 30
                        ;;
                esac
            done < "$latest_run/run.txt"
        fi

        input_dir=$(awk -F '\t' '$1 == "input_dir" {print $2; exit}' "$latest_run/run.txt")
        if [[ -n "$input_dir" && -d "$input_dir" ]]; then
            section 'Input inventory from latest run'
            printf 'input_directory=%s\n' "$input_dir"
            printf 'bam_files=%s\n' "$(count_files "$input_dir" '*.bam')"
            printf 'cram_files=%s\n' "$(count_files "$input_dir" '*.cram')"
            printf 'bai_files=%s\n' "$(count_files "$input_dir" '*.bai')"
            printf 'crai_files=%s\n' "$(count_files "$input_dir" '*.crai')"
        fi
    else
        printf 'No readable run.txt was found below %s/.mito-pipeline/runs\n' "$output_dir"
    fi

    section 'Five newest non-empty error logs (first 120 lines each)'
    error_list=''
    if [[ -d "$output_dir/logs" ]]; then
        error_list=$(find "$output_dir/logs" -type f -name '*.err' -size +0c \
            -printf '%T@\t%p\n' 2>/dev/null | sort -nr | head -n 5 | cut -f 2-)
    fi
    if [[ -n "$error_list" ]]; then
        while IFS= read -r error_file; do
            [[ -n "$error_file" ]] || continue
            printf '\n--- %s ---\n' "$error_file"
            sed -n '1,120p' "$error_file"
        done <<< "$error_list"
    else
        printf 'No non-empty .err logs found.\n'
    fi
fi

section 'Automatic findings'
if [[ -n "$output_dir" ]] && grep -R -m 1 -q -- 'job_common.sh: No such file or directory' "$output_dir/logs" 2>/dev/null; then
    printf 'DETECTED: historical SLURM spool-path failure for job_common.sh\n'
fi
if [[ -n "$output_dir" && -n "$latest_run" && -r "$latest_run/run.txt" ]] && \
    ! grep -q $'^bundle_size\t' "$latest_run/run.txt"; then
    printf 'DETECTED: latest recorded run used the old launcher; do not resubmit it\n'
fi
if ! grep -q -- 'bundle_array.sh.*SCRIPT_DIR/slurm' "$pipeline_dir/mito_pipeline.sh" 2>/dev/null; then
    printf 'ACTION: replace the complete pipeline directory with Git commit 4e39d92 or newer\n'
else
    printf 'PASS: installed launcher contains the shared-directory spool fix\n'
fi

section 'End'
printf 'Report written to: %s\n' "$(cd -- "$report_parent" && pwd -P)/$(basename -- "$report")"
