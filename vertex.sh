#!/usr/bin/env bash
# r21 – 恢复 0/1/2/3 菜单，支持多结算账户，修复 proj 变量及密钥删除问题

set -Eeuo pipefail
trap 'printf "[错误] 在行 %d 中止 (退出码 %d)\n" "$LINENO" "$?" >&2' ERR

# ────────────────────── 配置 (可通过环境变量覆盖) ──────────────────────
BILLING_ACCOUNT="${BILLING_ACCOUNT:-000000-AAAAAA-BBBBBB}" # 默认结算账户 ID
PROJECT_PREFIX="${PROJECT_PREFIX:-vertex}"                 # 项目 ID 前缀
MAX_PROJECTS_PER_ACCOUNT=${MAX_PROJECTS_PER_ACCOUNT:-3}    # 每个结算账户的最大项目数
SERVICE_ACCOUNT_NAME="${SERVICE_ACCOUNT_NAME:-vertex-admin}" # 服务账户名称
KEY_DIR="${KEY_DIR:-./keys}"                               # 服务账户密钥存储目录
MAX_RETRY=${MAX_RETRY:-3}                                  # 命令失败最大重试次数
CONCURRENCY=${CONCURRENCY:-5}                              # 并行启用 API 的上限
ENABLE_EXTRA_ROLES=(roles/iam.serviceAccountUser roles/aiplatform.user) # 为服务账户额外启用的角色
# ───────────────────────────────────────────────────────────────────────

# 记录日志
log() { printf '[%(%F %T)T] [%s] %s\n' -1 "${1:-信息}" "${2:-}" >&2; }
# 检查命令是否存在
require_cmd() { command -v "$1" &>/dev/null || { log 错误 "缺少依赖: $1"; exit 1; }; }
# 准备密钥存储目录
prepare_keydir(){ mkdir -p "$KEY_DIR" && chmod 700 "$KEY_DIR"; }
# 生成唯一后缀 (6位字符)
unique_suffix() { date +%s%N | sha256sum | head -c6; }
# 生成新的项目 ID
new_project_id(){ echo "${PROJECT_PREFIX}-$(unique_suffix)"; }

# 重试命令直到成功，或达到最大重试次数
retry() {
  local n=1 delay
  until "$@"; do
    (( n >= MAX_RETRY )) && { log 错误 "失败: $*"; return 1; }
    delay=$(( n*10 + RANDOM%5 )) # 增加延迟时间
    log 警告 "重试 $n/$MAX_RETRY: $* (等待 ${delay}s)"
    sleep "$delay"; (( n++ ))
  done
}

# 询问用户是/否
ask_yes_no() {
  local prompt=$1 default=${2:-N} resp
  # 仅当标准输入是终端时才读取
  [[ -t 0 ]] && read -r -p "$prompt [${default}] " resp
  resp=${resp:-$default}
  [[ $resp =~ ^[Yy是的]$ ]] # 接受 Y, y, 是, 的 作为肯定回答
}

# 提示用户从选项中选择
prompt_choice() {
  local prompt=$1 opts_str=$2 def_choice=$3 user_ans
  # 仅当标准输入是终端时才读取
  [[ -t 0 ]] && read -r -p "$prompt [$opts_str] (默认 $def_choice) " user_ans
  user_ans=${user_ans:-$def_choice}
  # 检查选择是否有效，无效则使用默认值
  if [[ $opts_str =~ (^|\|)$user_ans($|\|) ]]; then
    printf '%s' "$user_ans"
  else
    printf '%s' "$def_choice"
  fi
}

# ─────────────────────── GCloud 辅助函数 ────────────────────────────────
# 检查 gcloud 环境是否就绪
check_env() {
  require_cmd gcloud
  gcloud config list account --quiet &>/dev/null || { log 错误 "请先执行 'gcloud init'"; exit 1; }
  gcloud auth list --filter=status:ACTIVE --format='value(account)' | grep -q . \
    || { log 错误 "请先执行 'gcloud auth login'"; exit 1; }
}

# 列出所有状态为 OPEN (开放) 的结算账户
list_open_billing() {
  gcloud billing accounts list --filter='open=true' \
    --format='value(name,displayName)' \
  | awk '{printf "%s %s\n",$1,substr($0,index($0,$2))}' \
  | sed 's|billingAccounts/||' # 移除前缀
}

# 允许用户选择一个结算账户
choose_billing() {
  mapfile -t ACCS < <(list_open_billing)
  # 如果只有一个开放的结算账户，则直接使用
  (( ${#ACCS[@]} == 1 )) && { BILLING_ACCOUNT="${ACCS[0]%% *}"; return; }

  printf "可用的结算账户：\n"
  local i; for i in "${!ACCS[@]}"; do printf "  %d) %s\n" "$i" "${ACCS[$i]}"; done
  local sel
  while true; do
    read -r -p "请输入编号 [0-$((${#ACCS[@]}-1))] (默认 0): " sel
    sel=${sel:-0}
    # 校验输入是否为有效数字且在范围内
    [[ $sel =~ ^[0-9]+$ ]] && (( sel>=0 && sel<${#ACCS[@]} )) && break
    echo "无效输入，请重试。"
  done
  BILLING_ACCOUNT="${ACCS[$sel]%% *}" # 获取选中的结算账户 ID
}

# 为指定项目启用所需的服务 API
enable_services() {
  local proj_id=$1; shift # 第一个参数是项目 ID
  if [[ -z "$proj_id" ]]; then
    log 错误 "enable_services 调用时缺少项目 ID 参数"
    return 1
  fi
  local service_name
  for service_name in "$@"; do # 遍历剩余参数 (服务名称)
    # 检查服务是否已启用
    gcloud services list --enabled --project="$proj_id" --filter="$service_name" \
      --format='value(config.name)' | grep -q . && continue # 已启用则跳过
    log 信息 "[$proj_id] 正在启用服务: $service_name"
    retry gcloud services enable "$service_name" --project="$proj_id" --quiet
  done
}

# 将项目链接到结算账户
link_billing() { retry gcloud beta billing projects link "$1" --billing-account="$BILLING_ACCOUNT" --quiet; }
# 将项目与结算账户解绑
unlink_billing() { retry gcloud beta billing projects unlink "$1" --quiet; }

# 列出服务账户的所有云端密钥 ID
list_cloud_keys() { gcloud iam service-accounts keys list --iam-account="$1" --format='value(name)' | sed 's|.*/||'; }
# 获取服务账户最新的云端密钥 ID
latest_cloud_key() { gcloud iam service-accounts keys list --iam-account="$1" --limit=1 --sort-by=~createTime --format='value(name)' | sed 's|.*/||'; }

# ───────────────────────  核心操作  ────────────────────────────────
# 为指定项目和服务账户生成新的密钥文件
gen_key() {
  local proj_id=$1 sa_email=${2:-} # 第一个参数是项目 ID，第二个是服务账户邮箱
  if [[ -z "$proj_id" ]]; then
    log 错误 "gen_key 调用时缺少项目 ID 参数"
    return 1
  fi
  if [[ -z "$sa_email" ]]; then
    log 错误 "[$proj_id] gen_key 调用时缺少服务账户邮箱参数"
    return 1
  fi

  local timestamp=$(date +%Y%m%d-%H%M%S)
  local key_file_path="${KEY_DIR}/${proj_id}-${SERVICE_ACCOUNT_NAME}-${timestamp}.json"
  
  log 信息 "[$proj_id] 正在为服务账户 $sa_email 创建新密钥..."
  retry gcloud iam service-accounts keys create "$key_file_path" \
        --iam-account="$sa_email" --project="$proj_id" --quiet
  chmod 600 "$key_file_path" # 设置密钥文件权限
  log 信息 "[$proj_id] 新密钥已创建 → $key_file_path"
}

# 配置服务账户 (创建、授权、管理密钥)
provision_sa() {
  local proj_id=$1 # 第一个参数是项目 ID
  if [[ -z "$proj_id" ]]; then
    log 错误 "provision_sa 调用时缺少项目 ID 参数"
    return 1
  fi
  local sa_email="${SERVICE_ACCOUNT_NAME}@${proj_id}.iam.gserviceaccount.com"

  # 检查服务账户是否存在，不存在则创建
  if ! gcloud iam service-accounts describe "$sa_email" --project "$proj_id" &>/dev/null; then
    log 信息 "[$proj_id] 正在创建服务账户: $SERVICE_ACCOUNT_NAME"
    retry gcloud iam service-accounts create "$SERVICE_ACCOUNT_NAME" \
            --display-name="Vertex Admin" --project "$proj_id" --quiet
  else
    log 信息 "[$proj_id] 服务账户 $SERVICE_ACCOUNT_NAME 已存在"
  fi

  # 为服务账户绑定 IAM 角色
  local role_to_add
  for role_to_add in roles/aiplatform.admin "${ENABLE_EXTRA_ROLES[@]}"; do
    log 信息 "[$proj_id] 正在为 $sa_email 添加角色: $role_to_add"
    # 使用 --condition=None 避免因已有绑定条件导致策略更新失败，同时允许重复执行
    retry gcloud projects add-iam-policy-binding "$proj_id" \
            --member="serviceAccount:$sa_email" --role="$role_to_add" --condition=None --quiet || true 
            # || true 允许在角色已存在时静默处理，避免因重复添加导致脚本中断
  done

  # 管理本地和服务账户密钥
  local local_key_pattern="${KEY_DIR}/${proj_id}-${SERVICE_ACCOUNT_NAME}-*.json"
  local local_keys_found
  mapfile -t local_keys_found < <(ls $local_key_pattern 2>/dev/null) # 查找本地密钥文件

  if (( ${#local_keys_found[@]} > 0 )); then
    if ask_yes_no "[$proj_id] 本地已存在密钥 (${#local_keys_found[@]} 个). 是否生成新密钥?" Y; then
      gen_key "$proj_id" "$sa_email"
      if ask_yes_no "[$proj_id] 是否删除云端旧密钥 (仅保留最新一个)?" N; then
        local latest_key_id; latest_key_id=$(latest_cloud_key "$sa_email")
        mapfile -t cloud_key_ids < <(list_cloud_keys "$sa_email")
        local k_id
        for k_id in "${cloud_key_ids[@]}"; do
          [[ "$k_id" == "$latest_key_id" ]] && continue # 跳过最新的密钥
          log 信息 "[$proj_id] 正在删除云端旧密钥: $k_id"
          gcloud iam service-accounts keys delete "$k_id" \
                 --iam-account="$sa_email" --project="$proj_id" --quiet \
          || log 警告 "[$proj_id] 跳过无法删除的密钥 $k_id (可能已被手动删除或权限不足)"
        done
      fi
    else
      log 信息 "[$proj_id] 跳过生成新密钥的操作"
    fi
  else
    log 信息 "[$proj_id] 本地无密钥，将生成新密钥"
    gen_key "$proj_id" "$sa_email"
  fi
}

# 创建新项目并进行基础配置
create_project() {
  local new_proj_id; new_proj_id=$(new_project_id)
  log 信息 "[$BILLING_ACCOUNT] 正在创建新项目: $new_proj_id"
  retry gcloud projects create "$new_proj_id" --name="$new_proj_id" --quiet
  log 信息 "[$new_proj_id] 正在链接到结算账户: $BILLING_ACCOUNT"
  link_billing "$new_proj_id"
  # 首先启用核心API，例如aiplatform
  enable_services "$new_proj_id" aiplatform.googleapis.com
  # 然后配置服务账户
  provision_sa "$new_proj_id"
  PROJECTS+=("$new_proj_id") # 将新项目 ID 添加回全局 PROJECTS 数组，供 show_status 使用
}

# 处理项目列表：并行启用 API，然后顺序配置服务账户
process_projects() {
  local current_proj_id
  local running_jobs=0
  
  log 信息 "开始并行处理项目 (启用 API)..."
  for current_proj_id in "$@"; do
    [[ -z "$current_proj_id" ]] && continue # 跳过空的项目 ID
    (
      # 添加少量随机延迟，避免同时发起过多请求
      sleep $((RANDOM % 3))
      log 信息 "[$current_proj_id] (并行任务) 开始启用 aiplatform.googleapis.com 服务"
      enable_services "$current_proj_id" aiplatform.googleapis.com
      log 信息 "[$current_proj_id] (并行任务) aiplatform.googleapis.com 服务处理完成"
    ) & # 后台执行
    (( ++running_jobs >= CONCURRENCY )) && { wait -n; ((running_jobs--)); } # 控制并发数
  done
  wait # 等待所有后台的 enable_services 完成
  log 信息 "所有项目的 API 并行启用处理完成。"

  log 信息 "开始顺序处理项目 (配置服务账户)..."
  for current_proj_id in "$@"; do
    [[ -z "$current_proj_id" ]] && continue # 跳过空的项目 ID
    log 信息 "[$current_proj_id] (顺序任务) 开始配置服务账户"
    provision_sa "$current_proj_id"
    log 信息 "[$current_proj_id] (顺序任务) 服务账户配置完成"
  done
  log 信息 "所有项目的服务账户顺序配置完成。"
}

# 显示当前项目状态
show_status() {
  printf "\n当前项目状态 (结算账户: %s)\n" "$BILLING_ACCOUNT"
  local proj_id api_status key_count_str
  if (( ${#PROJECTS[@]} == 0 )); then
    printf "  此结算账户下没有通过本脚本管理的项目。\n"
  fi
  for proj_id in "${PROJECTS[@]}"; do
    # 统计本地密钥数量
    key_count_str=$(ls -1 "${KEY_DIR}/${proj_id}-${SERVICE_ACCOUNT_NAME}-"*.json 2>/dev/null | wc -l | tr -d ' ')
    [[ -z "$key_count_str" ]] && key_count_str="0" # 处理 wc -l 可能的空输出

    # 检查 Vertex AI API 是否启用
    if gcloud services list --enabled --project="$proj_id" --filter='aiplatform.googleapis.com' \
       --format='value(config.name)' | grep -q '.'; then
      api_status="已启用"
    else
      api_status="未启用"
    fi
    printf " • %-30s | Vertex AI API: %-5s | 本地密钥数: %s\n" "$proj_id" "$api_status" "$key_count_str"
  done; echo # 输出一个空行
}

# ─────────────────── 按结算账户处理的主逻辑 ───────────────────────
handle_billing() {
  # 函数参数 $1 即为要处理的结算账户 ID
  BILLING_ACCOUNT="$1" 
  # 清空并重新加载当前结算账户下的项目列表
  PROJECTS=() 
  mapfile -t PROJECTS < <(gcloud beta billing projects list \
                            --billing-account="$BILLING_ACCOUNT" \
                            --filter="projectId:$PROJECT_PREFIX-" \ # 仅列出由此脚本创建的项目
                            --format='value(projectId)')
  prepare_keydir # 确保密钥目录存在

  while true; do
    show_status # 显示当前状态
    log 信息 "当前操作的结算账户: $BILLING_ACCOUNT (已绑定 ${#PROJECTS[@]} / $MAX_PROJECTS_PER_ACCOUNT 个由此脚本管理的项目)"

    local choice
    choice=$(prompt_choice $'请选择操作：\n  0) 仅查看状态\n  1) 检查/补足项目至上限 (推荐)\n  2) 清空当前结算账户下所有由此脚本创建的项目并重建至上限\n  3) 返回上级或退出' \
                           "0|1|2|3" "1") # 默认选项为 1
    
    case $choice in
      0) continue ;; # 仅查看状态，循环继续
      1) # 检查/补足项目
        log 信息 "开始处理现有项目并补足至 $MAX_PROJECTS_PER_ACCOUNT 个..."
        process_projects "${PROJECTS[@]}" # 处理已存在的项目
        while (( ${#PROJECTS[@]} < MAX_PROJECTS_PER_ACCOUNT )); do
          create_project # 创建新项目直到达到上限
        done
        log 信息 "项目检查/补足完成。"
        ;;
      2) # 清空并重建
        if ask_yes_no "[$BILLING_ACCOUNT] 警告：此操作将解绑并忽略此结算账户下所有由脚本管理的项目，然后重新创建 $MAX_PROJECTS_PER_ACCOUNT 个新项目。确定吗?" N; then
          log 信息 "正在解绑当前结算账户下的项目..."
          local p_to_unlink
          for p_to_unlink in "${PROJECTS[@]}"; do
            log 信息 "[$BILLING_ACCOUNT] 正在解绑项目: $p_to_unlink"
            unlink_billing "$p_to_unlink"
          done
          PROJECTS=() # 清空项目列表
          log 信息 "开始重新创建 $MAX_PROJECTS_PER_ACCOUNT 个新项目..."
          while (( ${#PROJECTS[@]} < MAX_PROJECTS_PER_ACCOUNT )); do
            create_project
          done
          log 信息 "项目清空并重建完成。"
        else
          log 信息 "已取消清空并重建操作。"
        fi
        ;;
      3) break ;; # 退出当前结算账户的处理循环
    esac
  done
}

# ───────────────────────────── 主函数 ────────────────────────────────────
main() {
  check_env # 检查环境
  mapfile -t ALL_BILLING_ACCOUNTS < <(list_open_billing) # 获取所有开放的结算账户

  if (( ${#ALL_BILLING_ACCOUNTS[@]} == 0 )); then
    log 错误 "未找到任何开放的结算账户。请检查您的GCP账户权限或是否存在结算账户。"
    exit 1
  fi

  # 若只有一个结算账户，则直接进入该账户的处理逻辑
  if (( ${#ALL_BILLING_ACCOUNTS[@]} == 1 )); then
    local single_billing_id="${ALL_BILLING_ACCOUNTS[0]%% *}"
    log 信息 "检测到唯一的开放结算账户: $single_billing_id"
    handle_billing "$single_billing_id"
    exit 0
  fi

  # 若有多个结算账户，让用户选择处理模式
  log 信息 "检测到 ${#ALL_BILLING_ACCOUNTS[@]} 个开放的结算账户。"
  local mode
  mode=$(prompt_choice $'选择操作模式：\n  1) 选择单个结算账户进行管理\n  2) 批量处理所有检测到的结算账户' "1|2" "1")
  
  if [[ $mode == 2 ]]; then # 批量处理所有账户
    log 信息 "开始批量处理所有 ${#ALL_BILLING_ACCOUNTS[@]} 个结算账户..."
    local acc_info
    for acc_info in "${ALL_BILLING_ACCOUNTS[@]}"; do
      local current_billing_id="${acc_info%% *}"
      log 信息 "--- 开始处理结算账户: $current_billing_id (${acc_info#* }) ---"
      handle_billing "$current_billing_id"
      log 信息 "--- 结算账户: $current_billing_id 处理完毕 ---"
    done
    log 信息 "所有结算账户批量处理完成。"
    exit 0
  fi

  # 单一账户模式：让用户选择具体哪个账户
  log 信息 "请选择要管理的结算账户："
  choose_billing # 用户选择 BILLING_ACCOUNT
  handle_billing "$BILLING_ACCOUNT"
  log 信息 "结算账户 $BILLING_ACCOUNT 处理完毕。"
}

# 执行主函数，并将所有参数传递给它
main "$@"
