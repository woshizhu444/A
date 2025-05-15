#!/usr/bin/env bash
# r20 – fixes proj variable, gen_key arg check, key‑delete precondition, empty‑ID guard

set -Eeuo pipefail
trap 'printf "[ERROR] aborted at line %d (exit %d)\n" "$LINENO" "$?" >&2' ERR

# ─────────── Config (env‑overridable) ────────────
BILLING_ACCOUNT="${BILLING_ACCOUNT:-000000-AAAAAA-BBBBBB}"
PROJECT_PREFIX="${PROJECT_PREFIX:-vertex}"
MAX_PROJECTS_PER_ACCOUNT=${MAX_PROJECTS_PER_ACCOUNT:-3}
SERVICE_ACCOUNT_NAME="${SERVICE_ACCOUNT_NAME:-vertex-admin}"
KEY_DIR="${KEY_DIR:-./keys}"
MAX_RETRY=${MAX_RETRY:-3}
CONCURRENCY=${CONCURRENCY:-5}  # max parallel enable_api
ENABLE_EXTRA_ROLES=(roles/iam.serviceAccountUser roles/aiplatform.user)
# ────────────────────────────────────────────────

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
  local p=$1 d=${2:-N} r
  [[ -t 0 ]] && read -r -p "$p [${d}] " r
  r=${r:-$d}
  [[ $r =~ ^[Yy]$ ]]
}

prompt_choice() {
  local p=$1 opts=$2 def=$3 a
  [[ -t 0 ]] && read -r -p "$p [$opts] (默认 $def) " a
  a=${a:-$def}
  [[ $opts =~ (^|\|)$a($|\|) ]] || a=$def
  printf '%s' "$a"
}

check_env() {
  require_cmd gcloud
  gcloud config list account --quiet &>/dev/null || { log ERROR "请先 gcloud init"; exit 1; }
  gcloud auth list --filter=status:ACTIVE --format='value(account)' | grep -q . || { log ERROR "请先 gcloud auth login"; exit 1; }
}

list_open_billing() {
  gcloud billing accounts list --filter='open=true' --format='value(name,displayName)' |
    awk '{printf "%s %s\n", $1, substr($0,index($0,$2))}' | sed 's|billingAccounts/||'
}

choose_billing() {
  mapfile -t ACCS < <(list_open_billing)
  (( ${#ACCS[@]} == 1 )) && { BILLING_ACCOUNT="${ACCS[0]%% *}"; return; }
  printf "可用结算账户：\n"; local i; for i in "${!ACCS[@]}";do printf "  %d) %s\n" "$i" "${ACCS[$i]}"; done
  local sel; while true; do read -r -p "输入编号 [0-$((${#ACCS[@]}-1))] (默认 0): " sel; sel=${sel:-0}; [[ $sel =~ ^[0-9]+$ ]] && (( sel>=0 && sel<${#ACCS[@]} )) && break; done
  BILLING_ACCOUNT="${ACCS[$sel]%% *}"
}

prepare_key_dir(){ mkdir -p "$KEY_DIR" && chmod 700 "$KEY_DIR"; }
unique_suffix(){ date +%s%N | sha256sum | head -c6; }
new_project_id(){ echo "${PROJECT_PREFIX}-$(unique_suffix)"; }

enable_services(){ local p=$1; shift; local s; for s in "$@";do gcloud services list --enabled --project="$p" --filter="$s" --format='value(config.name)'|grep -q .&&continue; retry gcloud services enable "$s" --project="$p" --quiet; done; }

link_billing(){ retry gcloud beta billing projects link "$1" --billing-account="$BILLING_ACCOUNT" --quiet; }
unlink_billing(){ retry gcloud beta billing projects unlink "$1" --quiet; }

create_project(){ local pid=$(new_project_id); log INFO "[$BILLING_ACCOUNT] 创建项目 $pid"; retry gcloud projects create "$pid" --name="$pid" --quiet; link_billing "$pid"; enable_services "$pid" aiplatform.googleapis.com; provision_sa "$pid"; PROJECTS+=("$pid"); }

process_projects(){ local p running=0; for p in "$@"; do [[ -z $p ]]&&continue; ( sleep $((RANDOM%3)); enable_services "$p" aiplatform.googleapis.com ) & (( ++running>=CONCURRENCY )) && { wait -n; ((running--)); }; done; wait; for p in "$@"; do [[ -z $p ]]&&continue; provision_sa "$p"; done; }

list_cloud_keys(){ gcloud iam service-accounts keys list --iam-account="$1" --format='value(name)' | sed 's|.*/||'; }
latest_cloud_key(){ gcloud iam service-accounts keys list --iam-account="$1" --limit=1 --sort-by=~createTime --format='value(name)' | sed 's|.*/||'; }

gen_key(){ local proj=$1 sa=${2:-}; [[ -z $sa ]] && { log ERROR "gen_key 缺少 service-account 参数"; return 1; }; local ts=$(date +%Y%m%d-%H%M%S) key_file="${KEY_DIR}/${proj}-${SERVICE_ACCOUNT_NAME}-${ts}.json"; retry gcloud iam service-accounts keys create "$key_file" --iam-account="$sa" --project="$proj" --quiet; chmod 600 "$key_file"; log INFO "[$proj] 新密钥已创建 → $key_file"; }

provision_sa(){ local proj=$1 sa="${SERVICE_ACCOUNT_NAME}@${proj}.iam.gserviceaccount.com"; gcloud iam service-accounts describe "$sa" --project "$proj" &>/dev/null || retry gcloud iam service-accounts create "$SERVICE_ACCOUNT_NAME" --display-name="Vertex Admin" --project "$proj" --quiet; local r; for r in roles/aiplatform.admin "${ENABLE_EXTRA_ROLES[@]}"; do retry gcloud projects add-iam-policy-binding "$proj" --member="serviceAccount:$sa" --role="$r" --quiet||true; done; local local_keys=("${KEY_DIR}/${proj}-${SERVICE_ACCOUNT_NAME}-"*.json); [[ -e "${local_keys[0]-}" ]]||local_keys=(); if (( ${#local_keys[@]} )); then if ask_yes_no "[$proj] 本地已有密钥 (${#local_keys[@]}). 生成新密钥?" Y; then gen_key "$proj" "$sa"; if ask_yes_no "[$proj] 删除云端旧密钥(保留最新)?" N; then local latest=$(latest_cloud_key "$sa"); mapfile -t key_ids < <(list_cloud_keys "$sa"); for k in "${key_ids[@]}"; do [[ $k == "$latest" ]]&&continue; gcloud iam service-accounts keys delete "$k" --iam-account="$sa" --quiet || log WARN "[$proj] 跳过无法删除的密钥 $k"; done; fi; else log INFO "[$proj] 跳过新密钥生成"; fi; else gen_key "$proj" "$sa"; fi; }

show_status(){ printf "\n当前项目状态 (Billing: %s)\n" "$BILLING_ACCOUNT"; local proj api keycount; for proj in "${PROJECTS[@]}"; do keycount=$(ls -1 ${KEY_DIR}/${proj}-${SERVICE_ACCOUNT_NAME}-*.json 2>/dev/null | wc -l || true); gcloud services list --enabled --project="$proj" --filter='aiplatform.googleapis.com' --format='value(config.name)'|grep -q .&&api="ON"||api="OFF"; printf " • %-28s | Vertex API: %-3s | 本地密钥: %s\n" "$proj" "$api" "$keycount"; done; printf "\n"; }

handle_billing(){ BILLING_ACCOUNT="$1"; mapfile -t PROJECTS < <(gcloud beta billing projects list --billing-account="$BILLING_ACCOUNT" --format='value(projectId)'); show_status; log INFO "使用结算账户: $BILLING_ACCOUNT (已绑定 ${#PROJECTS[@]} / $MAX_PROJECTS_PER_ACCOUNT 项目)"; process_projects "${PROJECTS[@]}"; while (( ${#PROJECTS[@]} < MAX_PROJECTS_PER_ACCOUNT )); do create_project; done; show_status; }

main(){ check_env; mapfile -t ALL_BILLING < <(list_open_billing); if (( ${#ALL_BILLING[@]}==1 )); then BILLING_ACCOUNT="${ALL_BILLING[0]%% *}"; handle_billing "$BILLING_ACCOUNT"; exit 0; fi; printf "检测到 %d 个结算账户：\n" "${#ALL_BILLING[@]}"; local i; for i in "${!ALL_BILLING[@]}"; do printf "  %d) %s\n" "$i" "${ALL_BILLING[$i]}"; done; local mode=$(prompt_choice "选择模式：1) 单一账户  2) 批量全部" "1|2" "1"); if [[ $mode == 2 ]]; then for acc in "${ALL_BILLING[@]}"; do handle_billing "${acc%% *}"; done; else choose_billing; handle_billing "$BILLING_ACCOUNT"; fi; }

main "$@"
