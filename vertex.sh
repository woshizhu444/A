#!/bin/bash
# r23 – 兼容版本
# 修复语法错误，确保兼容性

set -euo pipefail
trap 'echo "[ERROR] aborted at line $LINENO (exit $?)" >&2' ERR

# ───── Config (env‑overridable) ─────
BILLING_ACCOUNT="${BILLING_ACCOUNT:-000000-AAAAAA-BBBBBB}"
PROJECT_PREFIX="${PROJECT_PREFIX:-vertex}"
MAX_PROJECTS_PER_ACCOUNT=${MAX_PROJECTS_PER_ACCOUNT:-3}
SERVICE_ACCOUNT_NAME="${SERVICE_ACCOUNT_NAME:-vertex-admin}"
KEY_DIR="${KEY_DIR:-./keys}"
MAX_RETRY=${MAX_RETRY:-3}
API_TIMEOUT=${API_TIMEOUT:-60}
STATE_FILE="${STATE_FILE:-./cloud-script-state.json}"
CACHE_DIR="${CACHE_DIR:-/tmp/cloud-script-cache}"
# CONCURRENCY auto-set later
ENABLE_EXTRA_ROLES="roles/iam.serviceAccountUser roles/aiplatform.user"
# ─────────────────────────────────────

# 初始化缓存目录
mkdir -p "$CACHE_DIR"

# log helper
log() {
  local level="$1"
  shift
  case "$level" in
    INFO) color="32m" ;; # 绿色
    WARN) color="33m" ;; # 黄色
    ERROR) color="31m" ;; # 红色
    *) color="0m" ;;
  esac
  printf "\033[${color}[%s] [%s]\033[0m %s\n" "$(date +"%F %T")" "$level" "$*" >&2
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { log ERROR "缺少依赖: $1"; exit 1; }
}

prepare_keydir() {
  mkdir -p "$KEY_DIR" && chmod 700 "$KEY_DIR"
}

unique_suffix() {
  date +%s%N | sha256sum | head -c6
}

new_project_id() {
  echo "${PROJECT_PREFIX}-$(unique_suffix)"
}

retry() {
  local n=1
  while true; do
    "$@" && break
    if [ $n -ge $MAX_RETRY ]; then
      log ERROR "失败: $*"
      return 1
    fi
    delay=$((n*10 + RANDOM % 5))
    log WARN "重试 $n/$MAX_RETRY: $* (等待 ${delay}s)"
    sleep $delay
    n=$((n+1))
  done
}

ask_yes_no() {
  local prompt="$1"
  local default="${2:-N}"
  local response
  
  if [ -t 0 ]; then
    read -r -p "$prompt [$default] " response
  fi
  
  response="${response:-$default}"
  
  case "$response" in
    [Yy]*) return 0 ;;
    *) return 1 ;;
  esac
}

prompt_choice() {
  local prompt="$1"
  local options="$2"
  local default="$3"
  local answer
  
  if [ -t 0 ]; then
    read -r -p "$prompt [$options] (默认 $default) " answer
  fi
  
  answer="${answer:-$default}"
  
  if ! echo "$options" | grep -q "\(^\||\)$answer\($\||)" ; then
    answer="$default"
  fi
  
  printf '%s' "$answer"
}

check_env() {
  require_cmd gcloud
  gcloud config list account --quiet >/dev/null 2>&1 || { log ERROR "请先 gcloud init"; exit 1; }
  gcloud auth list --filter=status:ACTIVE --format='value(account)' | grep -q . || { log ERROR "请先 gcloud auth login"; exit 1; }
}

list_open_billing() {
  gcloud billing accounts list --filter='open=true' --format='value(name,displayName)' | \
    awk '{printf "%s %s\n",$1,substr($0,index($0,$2))}' | \
    sed 's|billingAccounts/||'
}

choose_billing() {
  local ACCS
  ACCS=$(list_open_billing)
  local COUNT
  COUNT=$(echo "$ACCS" | wc -l)
  
  if [ "$COUNT" -eq 1 ]; then
    BILLING_ACCOUNT=$(echo "$ACCS" | awk '{print $1}')
    return
  fi
  
  printf "可用结算账户：\n"
  local i=0
  echo "$ACCS" | while read -r line; do
    printf "  %d) %s\n" "$i" "$line"
    i=$((i+1))
  done
  
  local sel
  while true; do
    read -r -p "编号 [0-$((COUNT-1))] (默认0): " sel
    sel=${sel:-0}
    if [[ "$sel" =~ ^[0-9]+$ ]] && [ "$sel" -ge 0 ] && [ "$sel" -lt "$COUNT" ]; then
      break
    fi
  done
  
  BILLING_ACCOUNT=$(echo "$ACCS" | sed -n "$((sel+1))p" | awk '{print $1}')
}

enable_services() {
  local proj="$1"
  shift
  local services_to_enable=""
  
  for s in "$@"; do
    if ! gcloud services list --enabled --project="$proj" --filter="$s" --format='value(config.name)' | grep -q .; then
      services_to_enable="$services_to_enable $s"
    fi
  done
  
  if [ -n "$services_to_enable" ]; then
    retry gcloud services enable $services_to_enable --project="$proj" --quiet
  fi
}

link_billing() {
  retry gcloud beta billing projects link "$1" --billing-account="$BILLING_ACCOUNT" --quiet
}

unlink_billing() {
  retry gcloud beta billing projects unlink "$1" --quiet
}

list_cloud_keys() {
  gcloud iam service-accounts keys list --iam-account="$1" --format='value(name)' | sed 's|.*/||'
}

gen_key() {
  local proj="$1" 
  local sa="$2" 
  local ts
  ts=$(date +%Y%m%d-%H%M%S)
  local f="${KEY_DIR}/${proj}-${SERVICE_ACCOUNT_NAME}-${ts}.json"
  retry gcloud iam service-accounts keys create "$f" --iam-account="$sa" --project="$proj" --quiet
  chmod 600 "$f"
  log INFO "[$proj] 新密钥 → $f"
}

provision_sa() {
  local proj="$1" 
  local sa="${SERVICE_ACCOUNT_NAME}@${proj}.iam.gserviceaccount.com"
  
  if ! gcloud iam service-accounts describe "$sa" --project "$proj" >/dev/null 2>&1; then
    retry gcloud iam service-accounts create "$SERVICE_ACCOUNT_NAME" --display-name="Vertex Admin" --project "$proj" --quiet
  fi
  
  for r in roles/aiplatform.admin $ENABLE_EXTRA_ROLES; do
    retry gcloud projects add-iam-policy-binding "$proj" --member="serviceAccount:$sa" --role="$r" --condition=None --quiet || true
  done
  
  # 检查是否已有密钥
  local key_count
  key_count=$(ls -1 "${KEY_DIR}/${proj}-${SERVICE_ACCOUNT_NAME}-"*.json 2>/dev/null | wc -l || echo 0)
  
  if [ "$key_count" -gt 0 ]; then
    if ask_yes_no "[$proj] 已有密钥 ($key_count). 生成新密钥?" "Y"; then
      gen_key "$proj" "$sa"
    fi
  else
    gen_key "$proj" "$sa"
  fi
}

save_checkpoint() {
  # 只在存在jq的情况下保存检查点
  if command -v jq >/dev/null 2>&1; then
    local temp_file="${STATE_FILE}.tmp"
    echo "{" > "$temp_file"
    echo "  \"billing_account\": \"$BILLING_ACCOUNT\"," >> "$temp_file"
    echo "  \"projects\": [" >> "$temp_file"
    
    local first=true
    for p in "${PROJECTS[@]}"; do
      if $first; then
        first=false
      else
        echo "," >> "$temp_file"
      fi
      echo "    \"$p\"" >> "$temp_file" 
    done
    
    echo "  ]," >> "$temp_file"
    echo "  \"timestamp\": \"$(date -Iseconds)\"" >> "$temp_file"
    echo "}" >> "$temp_file"
    
    mv "$temp_file" "$STATE_FILE"
    log INFO "状态已保存至 $STATE_FILE"
  fi
}

load_checkpoint() {
  if [ ! -f "$STATE_FILE" ]; then
    return 1
  fi
  
  if ! command -v jq >/dev/null 2>&1; then
    log WARN "缺少jq，无法加载检查点"
    return 1
  fi
  
  BILLING_ACCOUNT=$(jq -r '.billing_account' "$STATE_FILE")
  
  # 清空现有项目列表
  PROJECTS=()
  
  # 加载项目列表
  while read -r proj; do
    if [ -n "$proj" ]; then
      PROJECTS+=("$proj")
    fi
  done < <(jq -r '.projects[]' "$STATE_FILE")
  
  local ts
  ts=$(jq -r '.timestamp // empty' "$STATE_FILE")
  
  if [ -n "$ts" ]; then
    log INFO "加载检查点成功 (时间: $ts, 项目数: ${#PROJECTS[@]})"
  fi
  
  return 0
}

create_project() {
  local id
  id=$(new_project_id)
  log INFO "[$BILLING_ACCOUNT] 创建项目 $id"
  retry gcloud projects create "$id" --name="$id" --quiet
  link_billing "$id"
  enable_services "$id" aiplatform.googleapis.com
  provision_sa "$id"
  PROJECTS+=("$id")
  save_checkpoint
}

process_projects() {
  local p
  local running=0
  
  for p in "$@"; do
    [ -z "$p" ] && continue
    
    (
      set -euo pipefail
      sleep $((RANDOM % 3))
      enable_services "$p" aiplatform.googleapis.com
    ) &
    
    running=$((running + 1))
    if [ "$running" -ge "$CONCURRENCY" ]; then
      wait -n
      running=$((running - 1))
    fi
  done
  
  wait
  
  for p in "$@"; do
    [ -z "$p" ] && continue
    provision_sa "$p"
  done
  
  save_checkpoint
}

show_status() {
  printf "\n项目状态 (账单: %s)\n" "$BILLING_ACCOUNT"
  local total_keys=0
  local active_apis=0
  local total=${#PROJECTS[@]}
  
  for p in "${PROJECTS[@]}"; do
    local key_count
    key_count=$(ls -1 "${KEY_DIR}/${p}-${SERVICE_ACCOUNT_NAME}-"*.json 2>/dev/null | wc -l || echo 0)
    total_keys=$((total_keys + key_count))
    
    local api_status="OFF"
    if gcloud services list --enabled --project="$p" --filter=aiplatform.googleapis.com --format='value(config.name)' | grep -q .; then
      api_status="ON"
      active_apis=$((active_apis + 1))
    fi
    
    printf " • %-28s | API: %-2s | keys: %s\n" "$p" "$api_status" "$key_count"
  done
  
  printf "\n=== 摘要 ===\n"
  printf "总项目数: %d\n" "$total"
  
  if [ "$total" -gt 0 ]; then
    local api_percent=$((active_apis * 100 / total))
    local avg_keys=$((total_keys / total))
    printf "已启用API项目: %d (%d%%)\n" "$active_apis" "$api_percent"
    printf "总密钥数: %d (平均每项目 %d 个)\n" "$total_keys" "$avg_keys"
  fi
  
  echo
}

check_quotas() {
  local proj="$1"
  log INFO "[$proj] 检查配额使用情况"
  gcloud compute project-info describe --project="$proj" \
    --format="table(quotas.metric,quotas.limit,quotas.usage)" \
    --filter="quotas.metric:GPUs" || log WARN "[$proj] 无法获取配额信息"
}

handle_billing() {
  BILLING_ACCOUNT="$1"
  
  # 获取所有关联的项目
  PROJECTS=()
  while read -r p; do
    if [ -n "$p" ]; then
      PROJECTS+=("$p")
    fi
  done < <(gcloud beta billing projects list --billing-account="$BILLING_ACCOUNT" --format='value(projectId)')
  
  prepare_keydir
  
  while true; do
    show_status
    log INFO "处理账单 $BILLING_ACCOUNT (现有 ${#PROJECTS[@]})"
    
    local ch
    ch=$(prompt_choice $'操作:\n 0) 查看状态\n 1) 补足/配置\n 2) 清空并重建\n 3) 检查配额\n 4) 返回' "0|1|2|3|4" "1")
    
    case "$ch" in
      0) save_checkpoint; exit 0 ;;
      1) process_projects "${PROJECTS[@]}"
         while [ "${#PROJECTS[@]}" -lt "$MAX_PROJECTS_PER_ACCOUNT" ]; do
           create_project
         done
         ;;
      2) if ask_yes_no "确认清空并重建?" "N"; then
           for p in "${PROJECTS[@]}"; do
             unlink_billing "$p"
           done
           PROJECTS=()
           save_checkpoint
           while [ "${#PROJECTS[@]}" -lt "$MAX_PROJECTS_PER_ACCOUNT" ]; do
             create_project
           done
         fi
         ;;
      3) for p in "${PROJECTS[@]}"; do 
           check_quotas "$p"
         done
         ;;
      4) break ;;
    esac
  done
}

main() {
  check_env
  
  # 设置并发度
  if [ -z "${CONCURRENCY:-}" ]; then
    # 尝试获取CPU核心数，默认为4
    local cpu_cores=4
    if command -v nproc >/dev/null 2>&1; then
      cpu_cores=$(nproc)
    fi
    
    # 简单计算建议并发数
    CONCURRENCY=$((cpu_cores / 2))
    if [ "$CONCURRENCY" -lt 1 ]; then
      CONCURRENCY=1
    elif [ "$CONCURRENCY" -gt 10 ]; then
      CONCURRENCY=10
    fi
  fi
  
  log INFO "设置并发上限: $CONCURRENCY"
  
  # 尝试加载之前的状态
  if load_checkpoint; then
    if ask_yes_no "检测到之前的会话状态，是否恢复?" "Y"; then
      handle_billing "$BILLING_ACCOUNT"
      exit 0
    fi
  fi
  
  # 获取所有可用的账单账户
  ALL_BILLINGS=$(list_open_billing)
  if [ -z "$ALL_BILLINGS" ]; then
    log ERROR "无开放账单"
    exit 1
  fi
  
  # 计算账单数量
  BILLING_COUNT=$(echo "$ALL_BILLINGS" | wc -l)
  
  if [ "$BILLING_COUNT" -eq 1 ]; then
    handle_billing "$(echo "$ALL_BILLINGS" | awk '{print $1}')"
    exit 0
  fi
  
  local m
  m=$(prompt_choice $'模式:\n 1) 选账单\n 2) 全部批量' "1|2" "1")
  
  if [ "$m" = "1" ]; then
    choose_billing
    handle_billing "$BILLING_ACCOUNT"
  else
    echo "$ALL_BILLINGS" | while read -r billing_line; do
      local billing_id
      billing_id=$(echo "$billing_line" | awk '{print $1}')
      
      log INFO "批量处理账单: $billing_id"
      BILLING_ACCOUNT="$billing_id"
      
      # 重置项目列表
      PROJECTS=()
      while read -r p; do
        if [ -n "$p" ]; then
          PROJECTS+=("$p")
        fi
      done < <(gcloud beta billing projects list --billing-account="$BILLING_ACCOUNT" --format='value(projectId)')
      
      if [ "${#PROJECTS[@]}" -lt "$MAX_PROJECTS_PER_ACCOUNT" ]; then
        log INFO "[$BILLING_ACCOUNT] 补足项目 (现有 ${#PROJECTS[@]}/${MAX_PROJECTS_PER_ACCOUNT})"
        while [ "${#PROJECTS[@]}" -lt "$MAX_PROJECTS_PER_ACCOUNT" ]; do
          create_project
        done
      fi
      
      process_projects "${PROJECTS[@]}"
      show_status
    done
  fi
}

main "$@"
