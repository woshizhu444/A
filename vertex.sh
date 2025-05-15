#!/usr/bin/env bash

set -Eeuo pipefail
trap 'printf "[ERROR] aborted at line %d (exit %d)\n" "${LINENO}" "$?" >&2' ERR

BILLING_ACCOUNT="000000-AAAAAA-BBBBBB"
PROJECT_PREFIX="vertex"
MAX_PROJECTS_PER_ACCOUNT=3
SERVICE_ACCOUNT_NAME="vertex-admin"
KEY_DIR="./keys"
MAX_RETRY=3
ENABLE_EXTRA_ROLES=(roles/iam.serviceAccountUser roles/aiplatform.user)

log() { printf '[%(%F %T)T] [%s] %s\n' -1 "${1:-INFO}" "${2:-}" >&2; }

retry() {
  local n=1 delay
  until "$@"; do
    (( n >= MAX_RETRY )) && { log ERROR "失败: $*"; return 1; }
    delay=$(( n*10 + RANDOM%5 ))
    log WARN "重试 $n/$MAX_RETRY: $* (等待 ${delay}s)"
    sleep "$delay"; (( n++ ))
  done
}

require_cmd() { command -v "$1" &>/dev/null || { log ERROR "缺少依赖: $1"; exit 1; }; }
ask_yes_no() {
  local p="$1" d=${2:-N} r
  [[ -t 0 ]] && read -r -p "$p [${d}] " r
  r=${r:-$d}
  [[ $r =~ ^[Yy]$ ]]
}

prompt_choice() {
  local prompt="$1" opts="$2" def="$3" ans
  [[ -t 0 ]] && read -r -p "$prompt [$opts] (默认 $def) " ans
  ans=${ans:-$def}
  [[ $opts =~ (^|\|)$ans($|\|) ]] || ans=$def
  printf '%s' "$ans"
}

check_env() {
  require_cmd gcloud
  gcloud config list account --quiet &>/dev/null || { log ERROR "请先运行 gcloud init"; exit 1; }
  gcloud auth list --filter=status:ACTIVE --format='value(account)' | grep -q . || { log ERROR "请先 gcloud auth login"; exit 1; }
}

auto_detect_billing() { gcloud billing accounts list --filter='open=true' --format='value(name)' | head -1 | sed 's|billingAccounts/||'; }

prepare_key_dir() { mkdir -p "$KEY_DIR" && chmod 700 "$KEY_DIR"; }

unique_suffix() { date +%s%N | sha256sum | head -c6; }

new_project_id() { echo "${PROJECT_PREFIX}-$(unique_suffix)"; }

enable_services() {
  local p=$1 svc; shift
  for svc in "$@"; do
    gcloud services list --enabled --project="$p" --filter="$svc" --format='value(config.name)' | grep -q . && continue
    retry gcloud services enable "$svc" --project="$p" --quiet
  done
}

link_billing() { retry gcloud beta billing projects link "$1" --billing-account="$BILLING_ACCOUNT" --quiet; }

unlink_billing() { retry gcloud beta billing projects unlink "$1" --quiet; }

create_project() {
  local pid=$(new_project_id)
  log INFO "创建项目 $pid"
  retry gcloud projects create "$pid" --name="$pid" --quiet
  link_billing "$pid"
  enable_services "$pid" aiplatform.googleapis.com
  provision_sa "$pid"
  NEW_PROJECTS+=("$pid")
}

process_projects() {
  local p pids=()
  for p in "$@"; do ( enable_services "$p" aiplatform.googleapis.com ) & pids+=("$!"); done
  for pid in "${pids[@]}"; do wait "$pid"; done
  for p in "$@"; do provision_sa "$p"; done
}

list_cloud_keys() { gcloud iam service-accounts keys list --iam-account="$1" --format='value(name)' | sed 's|.*/||'; }

latest_cloud_key() { gcloud iam service-accounts keys list --iam-account="$1" --limit=1 --sort-by=~createTime --format='value(name)' | sed 's|.*/||'; }

gen_key() {
  local proj=$1 sa=$2 ts=$(date +%Y%m%d-%H%M%S)
  local key_file="${KEY_DIR}/${proj}-${SERVICE_ACCOUNT_NAME}-${ts}.json"
  retry gcloud iam service-accounts keys create "$key_file" --iam-account="$sa" --project="$proj" --quiet
  chmod 600 "$key_file"
  log INFO "[$proj] 新密钥已创建 → $key_file"
}

provision_sa() {
  local proj=$1
  local sa="${SERVICE_ACCOUNT_NAME}@${proj}.iam.gserviceaccount.com"
  gcloud iam service-accounts describe "$sa" --project "$proj" &>/dev/null || \
    retry gcloud iam service-accounts create "$SERVICE_ACCOUNT_NAME" --display-name="Vertex Admin" --project "$proj" --quiet
  local roles=(roles/aiplatform.admin "${ENABLE_EXTRA_ROLES[@]}")
  for r in "${roles[@]}"; do retry gcloud projects add-iam-policy-binding "$proj" --member="serviceAccount:$sa" --role="$r" --quiet || true; done
  local local_keys=("${KEY_DIR}/${proj}-${SERVICE_ACCOUNT_NAME}-"*.json)
  [[ -e "${local_keys[0]}" ]] || local_keys=()
  if (( ${#local_keys[@]} )); then
    if ask_yes_no "[$proj] 本地已有密钥 (${#local_keys[@]}). 生成新密钥?" Y; then
      gen_key "$proj" "$sa"
      if ask_yes_no "[$proj] 删除云端旧密钥(保留最新)?" N; then
        local latest=$(latest_cloud_key "$sa")
        mapfile -t key_ids < <(list_cloud_keys "$sa")
        for k in "${key_ids[@]}"; do [[ $k == "$latest" ]] && continue; retry gcloud iam service-accounts keys delete "$k" --iam-account="$sa" --quiet; log INFO "[$proj] 删除云端旧密钥 $k"; done
      fi
    else
      log INFO "[$proj] 跳过新密钥生成"
    fi
  else
    gen_key "$proj" "$sa"
  fi
}

show_status() {
  printf "\n当前项目状态 (Billing: %s)\n" "$BILLING_ACCOUNT"
  local proj sa keycount api
  for proj in "${PROJECTS[@]}"; do
    sa="${SERVICE_ACCOUNT_NAME}@${proj}.iam.gserviceaccount.com"
    keycount=$(ls -1 ${KEY_DIR}/${proj}-${SERVICE_ACCOUNT_NAME}-*.json 2>/dev/null | wc -l || true)
    gcloud services list --enabled --project="$proj" --filter='aiplatform.googleapis.com' --format='value(config.name)' | grep -q . && api="ON" || api="OFF"
    printf " • %-28s | Vertex API: %-3s | 本地密钥: %s\n" "$proj" "$api" "$keycount"
  done
  printf "\n"
}

main() {
  check_env
  [[ $BILLING_ACCOUNT == 000000-AAAAAA-BBBBBB ]] && BILLING_ACCOUNT=$(auto_detect_billing)
  [[ -z $BILLING_ACCOUNT ]] && { log ERROR "未找到 OPEN 结算账户"; exit 1; }
  prepare_key_dir
  mapfile -t PROJECTS < <(gcloud beta billing projects list --billing-account="$BILLING_ACCOUNT" --format='value(projectId)')
  local count=${#PROJECTS[@]}
  log INFO "使用结算账户: $BILLING_ACCOUNT (已绑定 $count / $MAX_PROJECTS_PER_ACCOUNT 项目)"
  declare -a NEW_PROJECTS
  show_status
  case $(prompt_choice "请选择操作: 0) 仅查看状态  1) 新建/补足项目  2) 清空并重建  3) 退出" "0|1|2|3" "1") in
    0) exit 0;;
    1)
      process_projects "${PROJECTS[@]}"
      while (( count < MAX_PROJECTS_PER_ACCOUNT )); do create_project; ((count++)); done;;
    2)
      for p in "${PROJECTS[@]}"; do unlink_billing "$p"; done
      PROJECTS=()
      count=0
      while (( count < MAX_PROJECTS_PER_ACCOUNT )); do create_project; ((count++)); done;;
    3) exit 0;;
  esac
  show_status
}

main "$@"
