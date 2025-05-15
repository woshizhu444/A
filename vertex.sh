#!/usr/bin/env bash
set -Eeuo pipefail
trap 'printf "[ERROR] aborted at line %d (exit %d)\n" "$LINENO" "$?" >&2' ERR

# ─────────── Config (可用环境变量覆盖) ─────────────────────
BILLING_ACCOUNT="${BILLING_ACCOUNT:-000000-AAAAAA-BBBBBB}"
PROJECT_PREFIX="${PROJECT_PREFIX:-vertex}"
MAX_PROJECTS_PER_ACCOUNT=${MAX_PROJECTS_PER_ACCOUNT:-3}
SERVICE_ACCOUNT_NAME="${SERVICE_ACCOUNT_NAME:-vertex-admin}"
KEY_DIR="${KEY_DIR:-./keys}"
MAX_RETRY=${MAX_RETRY:-3}
CONCURRENCY=${CONCURRENCY:-5}          # 并行 enable API 上限
ENABLE_EXTRA_ROLES=(roles/iam.serviceAccountUser roles/aiplatform.user)
# ───────────────────────────────────────────────────────────

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
  local prompt=$1 default=${2:-N} resp
  [[ -t 0 ]] && read -r -p "$prompt [$default] " resp
  resp=${resp:-$default}
  [[ $resp =~ ^[Yy]$ ]]
}

prompt_choice() {
  local prompt=$1 opts=$2 def=$3 ans
  [[ -t 0 ]] && read -r -p "$prompt [$opts] (默认 $def) " ans
  ans=${ans:-$def}
  [[ $opts =~ (^|\|)$ans($|\|) ]] || ans=$def
  printf '%s' "$ans"
}

check_env() {
  require_cmd gcloud
  gcloud config list account --quiet &>/dev/null || { log ERROR "请先 gcloud init"; exit 1; }
  gcloud auth list --filter=status:ACTIVE --format='value(account)' | grep -q . || { log ERROR "请先 gcloud auth login"; exit 1; }
}

list_open_billing() {
  gcloud billing accounts list --filter='open=true' --format='value(name,displayName)' |
    awk '{printf "%s %s\n", $1, substr($0,index($0,$2))}' |
    sed 's|billingAccounts/||'
}

choose_billing() {
  mapfile -t ACCS < <(list_open_billing)
  (( ${#ACCS[@]} == 0 )) && { log ERROR "未找到 OPEN 结算账户"; exit 1; }
  (( ${#ACCS[@]} == 1 )) && { BILLING_ACCOUNT="${ACCS[0]%% *}"; return; }

  printf "可用结算账户：\n"
  local i; for i in "${!ACCS[@]}"; do printf "  %d) %s\n" "$i" "${ACCS[$i]}"; done
  local sel
  while true; do
    read -r -p "输入编号 [0-$((${#ACCS[@]}-1))] (默认 0): " sel
    sel=${sel:-0}
    [[ $sel =~ ^[0-9]+$ ]] && (( sel>=0 && sel<${#ACCS[@]} )) && break
    echo "无效输入，请重新输入。"
  done
  BILLING_ACCOUNT="${ACCS[$sel]%% *}"
}

prepare_key_dir() { mkdir -p "$KEY_DIR" && chmod 700 "$KEY_DIR"; }
unique_suffix() { date +%s%N | sha256sum | head -c6; }
new_project_id() { echo "${PROJECT_PREFIX}-$(unique_suffix)"; }

enable_services() {
  local proj=$1; shift
  local svc
  for svc in "$@"; do
    gcloud services list --enabled --project="$proj" --filter="$svc" --format='value(config.name)' |
      grep -q . && continue
    retry gcloud services enable "$svc" --project="$proj" --quiet
  done
}

link_billing()   { retry gcloud beta billing projects link   "$1" --billing-account="$BILLING_ACCOUNT" --quiet; }
unlink_billing() { retry gcloud beta billing projects unlink "$1" --quiet; }

create_project() {
  local pid
  pid=$(new_project_id)
  log INFO "[$BILLING_ACCOUNT] 创建项目 $pid"
  retry gcloud projects create "$pid" --name="$pid" --quiet
  link_billing "$pid"
  enable_services "$pid" aiplatform.googleapis.com
  provision_sa "$pid"
  PROJECTS+=("$pid")        # ★ 新建成功后写回数组，供后续状态查看
}

# ────── 并行 enable API（限 CONCURRENCY）+ 顺序 SA/Key ──────
process_projects() {
  local proj pids=() running=0
  for proj in "$@"; do
    [[ -z $proj ]] && continue            # ★ 过滤空元素，防止传空字符串
    (
      sleep $((RANDOM%3))
      enable_services "$proj" aiplatform.googleapis.com
    ) & pids+=("$!")
    (( ++running >= CONCURRENCY )) && { wait -n; ((running--)); }
  done
  wait
  for proj in "$@"; do
    [[ -z $proj ]] && continue            # ★ 再次过滤保险
    provision_sa "$proj"
  done
}

list_cloud_keys()   { gcloud iam service-accounts keys list --iam-account="$1" --format='value(name)' | sed 's|.*/||'; }
latest_cloud_key()  { gcloud iam service-accounts keys list --iam-account="$1" --limit=1 --sort-by=~createTime --format='value(name)' | sed 's|.*/||'; }

gen_key() {
  local proj=$1 sa=${2:-} ts
  [[ -z $sa ]] && { log ERROR "gen_key 调用缺少 service-account 参数"; return 1; }   # ★ 参数校验
  ts=$(date +%Y%m%d-%H%M%S)
  local key_file="${KEY_DIR}/${proj}-${SERVICE_ACCOUNT_NAME}-${ts}.json"
  retry gcloud iam service-accounts keys create "$key_file" --iam-account="$sa" --project="$proj" --quiet
  chmod 600 "$key_file"
  log INFO "[$proj] 新密钥已创建 → $key_file"
}

provision_sa() {
  local proj=$1 sa="${SERVICE_ACCOUNT_NAME}@${proj}.iam.gserviceaccount.com"
  gcloud iam service-accounts describe "$sa" --project "$proj" &>/dev/null ||
    retry gcloud iam service-accounts create "$SERVICE_ACCOUNT_NAME" --display-name="Vertex Admin" --project "$proj" --quiet

  local roles=(roles/aiplatform.admin "${ENABLE_EXTRA_ROLES[@]}") r
  for r in "${roles[@]}"; do
    retry gcloud projects add-iam-policy-binding "$proj" --member="serviceAccount:$sa" --role="$r" --quiet || true
  done

  local local_keys=("${KEY_DIR}/${proj}-${SERVICE_ACCOUNT_NAME}-"*.json)
  [[ -e "${local_keys[0]-}" ]] || local_keys=()

  if (( ${#local_keys[@]} )); then
    if ask_yes_no "[$proj] 本地已有密钥 (${#local_keys[@]}). 生成新密钥?" Y; then
      gen_key "$proj" "$sa"
      if ask_yes_no "[$proj] 删除云端旧密钥(保留最新)?" N; then
        local latest; latest=$(latest_cloud_key "$sa")
        mapfile -t key_ids < <(list_cloud_keys "$sa")
        for k in "${key_ids[@]}"; do
          [[ $k == "$latest" ]] && continue
          retry gcloud iam service-accounts keys delete "$k" --iam-account="$sa" --quiet
          log INFO "[$proj] 删除云端旧密钥 $k"
        done
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
    gcloud services list --enabled --project="$proj" --filter='aiplatform.googleapis.com' --format='value(config.name)' |
      grep -q . && api="ON" || api="OFF"
    printf " • %-28s | Vertex API: %-3s | 本地密钥: %s\n" "$proj" "$api" "$keycount"
  done
  printf "\n"
}

handle_billing() {
  BILLING_ACCOUNT="$1"
  mapfile -t PROJECTS < <(gcloud beta billing projects list --billing-account="$BILLING_ACCOUNT" --format='value(projectId)')
  show_status
  log INFO "使用结算账户: $BILLING_ACCOUNT (已绑定 ${#PROJECTS[@]} / $MAX_PROJECTS_PER_ACCOUNT 项目)"
  process_projects "${PROJECTS[@]}"
  while (( ${#PROJECTS[@]} < MAX_PROJECTS_PER_ACCOUNT )); do create_project; done
  show_status
}

main() {
  check_env
  mapfile -t ALL_BILLING < <(list_open_billing)

  # 单账单账户 → 直接处理；多账单账户 → 让用户选批量或单个
  if (( ${#ALL_BILLING[@]} == 1 )); then
    BILLING_ACCOUNT="${ALL_BILLING[0]%% *}"
    handle_billing "$BILLING_ACCOUNT"
    exit 0
  fi

  printf "检测到 %d 个结算账户：\n" "${#ALL_BILLING[@]}"
  for i in "${!ALL_BILLING[@]}"; do printf "  %d) %s\n" "$i" "${ALL_BILLING[$i]}"; done

  local mode
  mode=$(prompt_choice "选择模式：1) 单一账户  2) 批量全部" "1|2" "1")

  if [[ $mode == 2 ]]; then
    for acc in "${ALL_BILLING[@]}"; do handle_billing "${acc%% *}"; done
    exit 0
  fi

  choose_billing
  handle_billing "$BILLING_ACCOUNT"
}

main "$@"
