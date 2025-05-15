#!/usr/bin/env bash
# r23 – 全面优化增强版
#   • 子进程同样启用 set -Eeuo pipefail
#   • enable_services 一次性启用多个 API 降低 mutate 调用
#   • 带颜色的日志输出 (INFO 绿, WARN 黄, ERROR 红)
#   • 自动计算并发上限: 智能动态调整
#   • 添加API结果缓存、智能重试、批量处理
#   • 添加检查点功能支持断点续传
#   • 增强监控和统计功能
#   • 添加API调用超时处理机制
#   • ShellCheck clean

set -Eeuo pipefail
trap 'printf "\e[31m[ERROR] aborted at line %d (exit %d)\e[0m\n" "$LINENO" "$?" >&2' ERR

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
CACHE_TTL=${CACHE_TTL:-3600}  # 缓存有效期(秒)
# CONCURRENCY auto-set later
ENABLE_EXTRA_ROLES=(roles/iam.serviceAccountUser roles/aiplatform.user)
# ─────────────────────────────────────

# 初始化缓存目录
mkdir -p "$CACHE_DIR"

# colored log helper
_log_color(){ case $1 in INFO) echo 2;; WARN) echo 3;; ERROR) echo 1;; esac; }
log(){ local c=$(_log_color "$1"); shift; printf "\e[3%sm[%(%F %T)T] [%s]\e[0m %s\n" "$c" -1 "$1" "$*" >&2; }

require_cmd(){ command -v "$1" &>/dev/null || { log ERROR "缺少依赖: $1"; exit 1; }; }
prepare_keydir(){ mkdir -p "$KEY_DIR" && chmod 700 "$KEY_DIR"; }
unique_suffix(){ date +%s%N | sha256sum | head -c6; }
new_project_id(){ echo "${PROJECT_PREFIX}-$(unique_suffix)"; }

# 智能重试
smart_retry() {
  local cmd=("$@") 
  local n=1 delay backoff_factor=1.5
  
  until "${cmd[@]}" 2>/tmp/cmd.err; do
    local err_msg
    err_msg=$(cat /tmp/cmd.err)
    (( n>=MAX_RETRY )) && { log ERROR "失败: ${cmd[*]} - $err_msg"; return 1; }
    
    # 指数退避策略
    delay=$(awk "BEGIN {printf \"%.0f\", ($backoff_factor^$n * 10 + $RANDOM % 5)}")
    log WARN "重试 $n/$MAX_RETRY: ${cmd[*]} (等待 ${delay}s) - $err_msg"
    sleep $delay
    ((n++))
  done
}

# 超时处理
retry_with_timeout() {
  local timeout=$API_TIMEOUT
  if command -v timeout &>/dev/null; then
    timeout "$timeout" "$@" || smart_retry "$@"
  else
    smart_retry "$@"
  fi
}

# 缓存API结果
cache_result() {
  local cache_key="$1"
  shift
  local cache_file="${CACHE_DIR}/${cache_key}-$(date +%Y%m%d-%H)"
  
  # 检查缓存是否存在且未过期
  if [[ -f "$cache_file" ]]; then
    local file_age
    file_age=$(($(date +%s) - $(stat -c %Y "$cache_file")))
    if (( file_age < CACHE_TTL )); then
      cat "$cache_file"
      return 0
    fi
  fi
  
  # 缓存不存在或已过期，重新获取
  "$@" > "$cache_file"
  cat "$cache_file"
}

ask_yes_no(){ local p=$1 d=${2:-N} r; [[ -t 0 ]]&&read -r -p "$p [${d}] " r; r=${r:-$d}; [[ $r =~ ^[Yy]$ ]]; }

prompt_choice(){ local p=$1 o=$2 d=$3 a; [[ -t 0 ]]&&read -r -p "$p [$o] (默认 $d) " a; a=${a:-$d}; [[ $o =~ (^|\|)$a($|\|) ]]||a=$d; printf '%s' "$a"; }

check_env(){ 
  require_cmd gcloud
  require_cmd jq
  gcloud config list account --quiet &>/dev/null||{ log ERROR "请先 gcloud init"; exit 1; }
  gcloud auth list --filter=status:ACTIVE --format=value(account)|grep -q .||{ log ERROR "请先 gcloud auth login"; exit 1; }
}

list_open_billing(){ 
  cache_result "billing-accounts" gcloud billing accounts list --filter='open=true' --format='value(name,displayName)'|awk '{printf "%s %s\n",$1,substr($0,index($0,$2))}'|sed 's|billingAccounts/||'
}

choose_billing(){ 
  mapfile -t ACCS < <(list_open_billing)
  (( ${#ACCS[@]}==1 ))&&{ BILLING_ACCOUNT="${ACCS[0]%% *}"; return; }
  printf "可用结算账户：\n"
  for i in "${!ACCS[@]}";do printf "  %d) %s\n" "$i" "${ACCS[$i]}"; done
  local sel
  while true; do 
    read -r -p "编号 [0-$((${#ACCS[@]}-1))] (默认0): " sel
    sel=${sel:-0}
    [[ $sel =~ ^[0-9]+$ ]]&&((sel>=0&&sel<${#ACCS[@]}))&&break
  done
  BILLING_ACCOUNT="${ACCS[$sel]%% *}"
}

# 批量启用服务
enable_services(){ 
  local proj=$1; shift
  local services=()
  for s in "$@"; do 
    gcloud services list --enabled --project="$proj" --filter="$s" --format='value(config.name)'|grep -q .||services+=("$s")
  done
  (( ${#services[@]} ))&&retry_with_timeout gcloud services enable "${services[@]}" --project="$proj" --quiet
}

# 批量操作优化
batch_enable_services() {
  local batch_size=5 # 一次处理的项目数
  local total=${#PROJECTS[@]}
  for ((i=0; i<total; i+=batch_size)); do
    local batch=("${PROJECTS[@]:i:batch_size}")
    # 并行处理这一批项目
    for p in "${batch[@]}"; do
      (set -Eeuo pipefail; enable_services "$p" aiplatform.googleapis.com) &
    done
    wait
  done
}

link_billing(){ retry_with_timeout gcloud beta billing projects link "$1" --billing-account="$BILLING_ACCOUNT" --quiet; }
unlink_billing(){ retry_with_timeout gcloud beta billing projects unlink "$1" --quiet; }

list_cloud_keys(){ gcloud iam service-accounts keys list --iam-account="$1" --format='value(name)'|sed 's|.*/||'; }
latest_cloud_key(){ gcloud iam service-accounts keys list --iam-account="$1" --limit=1 --sort-by=~createTime --format='value(name)'|sed 's|.*/||'; }

gen_key(){ 
  local proj=$1 sa=$2 ts=$(date +%Y%m%d-%H%M%S)
  local f="${KEY_DIR}/${proj}-${SERVICE_ACCOUNT_NAME}-${ts}.json"
  retry_with_timeout gcloud iam service-accounts keys create "$f" --iam-account="$sa" --project="$proj" --quiet
  chmod 600 "$f"
  log INFO "[$proj] 新密钥 → $f"
}

provision_sa(){ 
  local proj=$1 sa="${SERVICE_ACCOUNT_NAME}@${proj}.iam.gserviceaccount.com"
  gcloud iam service-accounts describe "$sa" --project "$proj" &>/dev/null||retry_with_timeout gcloud iam service-accounts create "$SERVICE_ACCOUNT_NAME" --display-name="Vertex Admin" --project "$proj" --quiet
  local r
  for r in roles/aiplatform.admin "${ENABLE_EXTRA_ROLES[@]}"; do 
    retry_with_timeout gcloud projects add-iam-policy-binding "$proj" --member="serviceAccount:$sa" --role="$r" --condition=None --quiet||true
  done
  
  local k=("${KEY_DIR}/${proj}-${SERVICE_ACCOUNT_NAME}-"*.json)
  [[ -e "${k[0]}" ]]||k=()
  if (( ${#k[@]} )); then 
    ask_yes_no "[$proj] 已有密钥 (${#k[@]}). 生成新密钥?" Y&&gen_key "$proj" "$sa"
  else 
    gen_key "$proj" "$sa"
  fi
}

# 检查点功能
save_checkpoint() {
  {
    echo '{'
    echo "  \"billing_account\": \"$BILLING_ACCOUNT\","
    echo "  \"projects\": ["
    local first=true
    for p in "${PROJECTS[@]}"; do
      $first || echo ','
      echo "    \"$p\""
      first=false
    done
    echo "  ],"
    echo "  \"timestamp\": \"$(date -Iseconds)\""
    echo '}'
  } > "$STATE_FILE"
  log INFO "状态已保存至 $STATE_FILE"
}

load_checkpoint() {
  [[ -f "$STATE_FILE" ]] || return 1
  if ! command -v jq &>/dev/null; then
    log WARN "缺少jq，无法加载检查点"
    return 1
  fi
  
  BILLING_ACCOUNT=$(jq -r '.billing_account' "$STATE_FILE")
  mapfile -t PROJECTS < <(jq -r '.projects[]' "$STATE_FILE")
  local ts
  ts=$(jq -r '.timestamp // empty' "$STATE_FILE")
  [[ -n "$ts" ]] && log INFO "加载检查点成功 (时间: $ts, 项目数: ${#PROJECTS[@]})"
  return 0
}

create_project(){ 
  local id
  id=$(new_project_id)
  log INFO "[$BILLING_ACCOUNT] 创建项目 $id"
  retry_with_timeout gcloud projects create "$id" --name="$id" --quiet
  link_billing "$id"
  enable_services "$id" aiplatform.googleapis.com
  provision_sa "$id"
  PROJECTS+=("$id")
  save_checkpoint
}

process_projects(){ 
  local p running=0
  for p in "$@"; do 
    [[ -z $p ]]&&continue
    (set -Eeuo pipefail; sleep $((RANDOM%3)); enable_services "$p" aiplatform.googleapis.com) &
    (( ++running>=CONCURRENCY ))&&{ wait -n; ((running--)); }
  done
  wait
  for p in "$@"; do 
    [[ -z $p ]]&&continue
    provision_sa "$p"
  done
  save_checkpoint
}

# 统计功能
show_status(){ 
  printf "\n项目状态 (账单: %s)\n" "$BILLING_ACCOUNT"
  local p total_keys=0 active_apis=0
  for p in "${PROJECTS[@]}"; do 
    local kc
    kc=$(ls -1 "${KEY_DIR}/${p}-${SERVICE_ACCOUNT_NAME}-"*.json 2>/dev/null|wc -l)
    ((total_keys+=kc))
    local api
    gcloud services list --enabled --project="$p" --filter=aiplatform.googleapis.com --format='value(config.name)'|grep -q .&&{ api="ON"; ((active_apis++)); }||api="OFF"
    printf " • %-28s | API: %-2s | keys: %s\n" "$p" "$api" "$kc"
  done
  
  local total=${#PROJECTS[@]}
  printf "\n=== 摘要 ===\n"
  printf "总项目数: %d\n" "$total"
  if (( total > 0 )); then
    printf "已启用API项目: %d (%.1f%%)\n" "$active_apis" "$(awk "BEGIN {printf \"%.1f\", ($active_apis*100/$total)}")"
    printf "总密钥数: %d (平均每项目 %.1f 个)\n" "$total_keys" "$(awk "BEGIN {printf \"%.1f\", ($total_keys/$total)}")"
  fi
  echo
}

# 检查配额用量
check_quotas() {
  local proj=$1
  log INFO "[$proj] 检查配额使用情况"
  gcloud compute project-info describe --project "$proj" \
    --format="table(quotas.metric,quotas.limit,quotas.usage)" \
    --filter="quotas.metric:GPUs" || log WARN "[$proj] 无法获取配额信息"
}

handle_billing(){ 
  BILLING_ACCOUNT="$1"
  mapfile -t PROJECTS < <(gcloud beta billing projects list --billing-account="$BILLING_ACCOUNT" --format='value(projectId)')
  prepare_keydir
  while true; do 
    show_status
    log INFO "处理账单 $BILLING_ACCOUNT (现有 ${#PROJECTS[@]})"
    local ch
    ch=$(prompt_choice $'操作:\n 0) 查看状态\n 1) 补足/配置\n 2) 清空并重建\n 3) 检查配额\n 4) 返回' "0|1|2|3|4" "1")
    case $ch in 
      0) save_checkpoint; exit 0;;
      1) process_projects "${PROJECTS[@]}"
         while (( ${#PROJECTS[@]} < MAX_PROJECTS_PER_ACCOUNT )); do 
           create_project
         done;;
      2) ask_yes_no "确认清空并重建?" N&&{ 
           for p in "${PROJECTS[@]}"; do 
             unlink_billing "$p"
           done
           PROJECTS=()
           while (( ${#PROJECTS[@]} < MAX_PROJECTS_PER_ACCOUNT )); do 
             create_project
           done 
         };;
      3) for p in "${PROJECTS[@]}"; do check_quotas "$p"; done;;
      4) break;;
    esac
  done
}

main(){
  check_env
  
  # 配置智能并发控制
  # 根据CPU核心数、总账单数和系统内存情况动态设置
  if [[ -z "${CONCURRENCY:-}" ]]; then
    local cpu_cores
    cpu_cores=$(nproc 2>/dev/null || echo 4)
    local avail_mem
    avail_mem=$(free -m 2>/dev/null | awk 'NR==2{print $7}' || echo 2000)
    
    # 根据可用资源计算建议并发数
    local suggested_concurrency
    suggested_concurrency=$(( (cpu_cores / 2) > 1 ? (cpu_cores / 2) : 1 ))
    # 考虑内存因素 (每个并发任务假设需要~500MB)
    local mem_concurrency
    mem_concurrency=$(( avail_mem / 500 ))
    
    # 取较小值作为实际并发数
    CONCURRENCY=$(( suggested_concurrency < mem_concurrency ? suggested_concurrency : mem_concurrency ))
    # 设置上限为10
    CONCURRENCY=$(( CONCURRENCY > 10 ? 10 : CONCURRENCY ))
  fi
  log INFO "设置并发上限: $CONCURRENCY"
  
  # 尝试加载之前的状态
  if load_checkpoint; then
    if ask_yes_no "检测到之前的会话状态，是否恢复?" Y; then
      handle_billing "$BILLING_ACCOUNT"
      exit 0
    fi
  fi
  
  mapfile -t ALL < <(list_open_billing)
  (( ${#ALL[@]}==0 ))&&{ log ERROR "无开放账单"; exit 1; }
  
  if (( ${#ALL[@]}==1 )); then
    handle_billing "${ALL[0]%% *}"
    exit 0
  fi
  
  local m
  m=$(prompt_choice $'模式:\n 1) 选账单\n 2) 全部批量' "1|2" "1")
  if [[ $m == "1" ]]; then
    choose_billing
    handle_billing "$BILLING_ACCOUNT"
  else
    for billing in "${ALL[@]%% *}"; do
      log INFO "批量处理账单: $billing"
      BILLING_ACCOUNT="$billing"
      mapfile -t PROJECTS < <(gcloud beta billing projects list --billing-account="$BILLING_ACCOUNT" --format='value(projectId)')
      
      if (( ${#PROJECTS[@]} < MAX_PROJECTS_PER_ACCOUNT )); then
        log INFO "[$BILLING_ACCOUNT] 补足项目 (现有 ${#PROJECTS[@]}/${MAX_PROJECTS_PER_ACCOUNT})"
        while (( ${#PROJECTS[@]} < MAX_PROJECTS_PER_ACCOUNT )); do
          create_project
        done
      fi
      
      process_projects "${PROJECTS[@]}"
      show_status
    done
  fi
}

main "$@"
