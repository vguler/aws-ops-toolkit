#!/usr/bin/env bash
set -euo pipefail

# -------- defaults
MODE="mock"           # mock | real
FORMAT="table"        # table | json
PROFILE=""
REGION=""
VERBOSE="0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

die() { echo "ERROR: $*" >&2; exit 2; }
info() { [[ "$VERBOSE" == "1" ]] && echo "[info] $*" >&2 || true; }

usage() {
  cat <<'USAGE'
AWS Ops Toolkit (dual-mode)

Usage:
  ./ops.sh doctor
  ./ops.sh ec2 list [--mock|--real] [--profile P] [--region R] [--format table|json] [-v]
  ./ops.sh ec2 health [--mock|--real] [--profile P] [--region R] [--format table|json] [-v]
  ./ops.sh s3 clean <bucket> --older-than DAYS [--dry-run|--apply] [--mock|--real] [--profile P] [--region R] [--format table|json] [-v]
  ./ops.sh logs analyze <path> [--since-min MIN] [--top N] [--format table|json] [-v]

Notes:
  - Default mode is --mock (no AWS credentials required).
  - In --real mode, requires AWS CLI configured.
USAGE
}

need_aws_cli() {
  command -v aws >/dev/null 2>&1 || die "AWS CLI not found. Install awscli or run with --mock."
}

aws_base_args() {
  local args=()
  [[ -n "$PROFILE" ]] && args+=(--profile "$PROFILE")
  [[ -n "$REGION"  ]] && args+=(--region "$REGION")
  args+=(--output json)
  echo "${args[@]}"
}

# -------- global flag parsing (shared)
parse_global_flags() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --mock) MODE="mock"; shift ;;
      --real) MODE="real"; shift ;;
      --format) FORMAT="${2:-}"; shift 2 ;;
      --profile) PROFILE="${2:-}"; shift 2 ;;
      --region) REGION="${2:-}"; shift 2 ;;
      -v|--verbose) VERBOSE="1"; shift ;;
      --help|-h) usage; exit 0 ;;
      *) break ;;
    esac
  done
  echo "$@"
}

run_py_file_or_stdin() {
  # $1 = python script, $2 = mock file, then extra args...
  local script="$1"; shift
  local mock_file="$1"; shift

  if [[ "$MODE" == "mock" ]]; then
    [[ -f "$mock_file" ]] || die "Mock file not found: $mock_file"
    info "mode=mock source=$mock_file"
    "$PYTHON_BIN" "$script" --source "$mock_file" --format "$FORMAT" "$@"
  else
    need_aws_cli
    info "mode=real source=stdin"
    "$PYTHON_BIN" "$script" --from-stdin --format "$FORMAT" "$@"
  fi
}

# -------- commands
cmd_doctor() {
  "$PYTHON_BIN" "$ROOT_DIR/python/doctor.py"
}

cmd_ec2_list() {
  if [[ "$MODE" == "real" ]]; then
    need_aws_cli
    local base; base="$(aws_base_args)"
    info "aws ec2 describe-instances $base"
    aws ec2 describe-instances $base | run_py_file_or_stdin \
      "$ROOT_DIR/python/ec2_list.py" "$ROOT_DIR/data/ec2_describe_instances.json"
  else
    run_py_file_or_stdin "$ROOT_DIR/python/ec2_list.py" "$ROOT_DIR/data/ec2_describe_instances.json"
  fi
}

cmd_ec2_health() {
  if [[ "$MODE" == "real" ]]; then
    need_aws_cli
    local base; base="$(aws_base_args)"
    info "aws ec2 describe-instances $base"
    aws ec2 describe-instances $base | run_py_file_or_stdin \
      "$ROOT_DIR/python/ec2_health.py" "$ROOT_DIR/data/ec2_describe_instances.json"
  else
    run_py_file_or_stdin "$ROOT_DIR/python/ec2_health.py" "$ROOT_DIR/data/ec2_describe_instances.json"
  fi
}

cmd_s3_clean() {
  local bucket="${1:-}"; shift || true
  [[ -n "$bucket" ]] || die "Missing bucket. Example: ./ops.sh s3 clean my-bucket --older-than 30"

  local older=""
  local apply="0"   # default dry-run
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --older-than) older="${2:-}"; shift 2 ;;
      --apply) apply="1"; shift ;;
      --dry-run) apply="0"; shift ;;
      *) break ;;
    esac
  done
  [[ -n "$older" ]] || die "Missing --older-than DAYS"

  if [[ "$MODE" == "real" ]]; then
    need_aws_cli
    local base; base="$(aws_base_args)"
    info "aws s3api list-objects-v2 --bucket $bucket $base"
    aws s3api list-objects-v2 --bucket "$bucket" $base | run_py_file_or_stdin \
      "$ROOT_DIR/python/s3_clean.py" "$ROOT_DIR/data/s3_list_objects.json" \
      --bucket "$bucket" --older-than "$older" --apply "$apply" --profile "$PROFILE" --region "$REGION"
  else
    run_py_file_or_stdin "$ROOT_DIR/python/s3_clean.py" "$ROOT_DIR/data/s3_list_objects.json" \
      --bucket "$bucket" --older-than "$older" --apply "$apply"
  fi
}

cmd_logs_analyze() {
  local path="${1:-}"; shift || true
  [[ -n "$path" ]] || die "Missing log path. Example: ./ops.sh logs analyze logs/app.log"
  [[ -f "$path" ]] || die "Log file not found: $path"

  local since_min="0"
  local top="10"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --since-min) since_min="${2:-0}"; shift 2 ;;
      --top) top="${2:-10}"; shift 2 ;;
      *) break ;;
    esac
  done

  "$PYTHON_BIN" "$ROOT_DIR/python/log_analyzer.py" \
    --path "$path" --since-min "$since_min" --top "$top" --format "$FORMAT"
}

# -------- main
main() {
  [[ $# -gt 0 ]] || { usage; exit 2; }

  local cmd="$1"; shift
  case "$cmd" in
    doctor)
      cmd_doctor
      ;;
    ec2)
      [[ $# -gt 0 ]] || die "Missing ec2 subcommand (list|health)"
      local sub="$1"; shift
      set -- $(parse_global_flags "$@")
      case "$sub" in
        list) cmd_ec2_list ;;
        health) cmd_ec2_health ;;
        *) die "Unknown ec2 subcommand: $sub" ;;
      esac
      ;;
    s3)
      [[ $# -gt 0 ]] || die "Missing s3 subcommand (clean)"
      local sub="$1"; shift
      case "$sub" in
        clean)
          # parse globals AFTER bucket+flags? We'll parse globals first to allow anywhere
          # simple approach: parse globals first if they appear early
          # users can put --real/--mock before "s3 clean" too, but not necessary now
          set -- $(parse_global_flags "$@")
          cmd_s3_clean "$@"
          ;;
        *) die "Unknown s3 subcommand: $sub" ;;
      esac
      ;;
    logs)
      [[ $# -gt 0 ]] || die "Missing logs subcommand (analyze)"
      local sub="$1"; shift
      set -- $(parse_global_flags "$@")
      case "$sub" in
        analyze) cmd_logs_analyze "$@" ;;
        *) die "Unknown logs subcommand: $sub" ;;
      esac
      ;;
    help|--help|-h) usage ;;
    *) die "Unknown command: $cmd" ;;
  esac
}

main "$@"
