#!/bin/bash

# ==========================================================
# 🔥 ImmortalWrt/OpenWrt 固件编译管理脚本 V6.2.14 (Syntax Fix & Menu Logic Restore)
# ----------------------------------------------------------
# (修复 V6.2.13 中 verify_config_signature 函数的语法错误)
# ==========================================================

# --- 1. 颜色定义与基础变量 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# --- 版本控制和兼容性检查 ---
SCRIPT_VERSION="6.2.14 (Syntax Fix)"
MIN_BASH_VERSION=4

# 核心构建根目录
BUILD_ROOT="$HOME/immortalwrt_builder_root"
SOURCE_ROOT="$HOME" 

# 定义子目录
CONFIGS_DIR="$BUILD_ROOT/profiles"
LOG_DIR="$BUILD_ROOT/logs"
USER_CONFIG_DIR="$BUILD_ROOT/user_configs"
EXTRA_SCRIPT_DIR="$BUILD_ROOT/custom_scripts"
OUTPUT_DIR="$BUILD_ROOT/output"
CCACHE_DIR="$BUILD_ROOT/ccache" 
BACKUP_DIR="$BUILD_ROOT/backup"

# 全局变量
declare -g BUILD_LOG_PATH=""
declare -g CURRENT_SOURCE_DIR=""
declare -g CCACHE_LIMIT="50G" # 初始默认值，将被实际设置覆盖
declare -g JOBS_N=1
declare -g TOTAL_MEM_KB=0

CONFIG_VAR_NAMES=(FW_TYPE REPO_URL FW_BRANCH CONFIG_FILE_NAME EXTRA_PLUGINS CUSTOM_INJECTIONS ENABLE_QMODEM)

# --- 2. 核心辅助函数 ---

# 检查bash版本
check_bash_version() {
    local bash_version=${BASH_VERSION%%.*}
    if (( bash_version < MIN_BASH_VERSION )); then
        echo -e "${RED}❌ 脚本需要 Bash ${MIN_BASH_VERSION}+，当前为 ${BASH_VERSION}${NC}"
        exit 1
    fi
}

# 检查系统类型
detect_system() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        echo "$ID $VERSION_ID"
    elif [[ -f /etc/redhat-release ]]; then
        cat /etc/redhat-release
    else
        echo "unknown"
    fi
}

# 编译环境资源信息显示
show_system_info() {
    echo -e "${BLUE}系统信息: ${NC}"
    echo -e "  系统: $(detect_system)"
    echo -e "  CPU: $(nproc 2>/dev/null || echo 1) 核心"
    
    local mem_info=$(free -h 2>/dev/null | awk '/^Mem:/ {print $2}' || echo "N/A")
    echo -e "  内存: $mem_info"
    
    local disk_info=$(df -h "$BUILD_ROOT" 2>/dev/null | awk 'NR==2 {print $4}' || echo "N/A")
    echo -e "  磁盘: $disk_info 可用"
    echo -e "  CCACHE: $CCACHE_LIMIT 上限"
}

# 进度条监控函数
monitor_progress_bar() {
    local total_targets=$1
    local log_file=$2
    
    if [ "$total_targets" -le 0 ]; then return; fi 
    
    echo -e "\n--- ${GREEN}✅ 编译进度: 0%${NC} ---"
    
    local completed_targets=0
    local last_progress=0
    local start_time=$(date +%s)
    
    local pipe_file="/tmp/progress_monitor_$$.pipe"
    if ! mkfifo "$pipe_file"; then
        echo -e "${RED}❌ 无法创建进度管道文件，跳过实时监控。${NC}"
        return
    fi
    
    tail -f "$log_file" 2>/dev/null > "$pipe_file" &
    local tail_pid=$!
    
    local timeout=3600  # 1小时超时
    local start_monitor=$(date +%s)
    
    while IFS= read -r -t 60 line; do
        if (( $(date +%s) - start_monitor > timeout )); then
            echo -e "\n${YELLOW}⚠️  进度监控超时${NC}"
            break
        fi
        
        if echo "$line" | grep -q "Package/.*\.mk.*done\|Built target \|Finished building target\|collect2:.*ld"; then
            completed_targets=$((completed_targets + 1))
            
            if [ "$completed_targets" -gt "$total_targets" ]; then
                completed_targets=$total_targets
            fi

            local current_progress=$(( (completed_targets * 100) / total_targets ))
            
            if [ "$current_progress" -gt "$last_progress" ]; then
                last_progress="$current_progress"
                
                local current_time=$(date +%s)
                local elapsed=$((current_time - start_time))
                local remaining_str=""
                
                if [ "$current_progress" -gt 5 ] && [ "$elapsed" -gt 0 ]; then
                    local total_estimated=$((elapsed * 100 / current_progress))
                    local remaining=$((total_estimated - elapsed))
                    
                    if [ "$remaining" -gt 3600 ]; then
                        remaining_str=" (~$((remaining/3600))h$(((remaining%3600)/60))m)"
                    elif [ "$remaining" -gt 60 ]; then
                        remaining_str=" (~$((remaining/60))m$((remaining%60))s)"
                    else
                        remaining_str=" (~${remaining}s)"
                    fi
                fi
                
                echo -ne "${BLUE}Building: ${NC}[${GREEN}$current_progress%${NC}] ($completed_targets/$total_targets)$remaining_str - $(date +%H:%M:%S)\r"
            fi
        fi
        
        if echo "$line" | grep -q "make\[.*\]: Leaving directory.*\.\./\.\."; then
            break
        fi
    done < "$pipe_file"
    
    # 清理
    kill "$tail_pid" 2>/dev/null
    rm -f "$pipe_file" 2>/dev/null
    
    echo -e "\n${GREEN}✅ 编译进度: 100%${NC} (或进程已结束)"
}

# 配置文件签名
generate_config_signature() {
    local config_file="$1"
    local signature_file="${config_file}.sig"
    if command -v sha256sum &> /dev/null; then
        sha256sum "$config_file" | cut -d' ' -f1 > "$signature_file"
        echo -e "${GREEN}🔑 配置文件签名已生成/更新。${NC}"
    else
        echo -e "${YELLOW}⚠️  无法生成签名：未找到 sha256sum 命令。${NC}"
    fi
}

# 验证签名 (已修复语法错误)
verify_config_signature() {
    local config_file="$1"
    local signature_file="${config_file}.sig"
    
    if [ ! -f "$signature_file" ]; then
        echo -e "${YELLOW}⚠️  警告：配置文件没有签名文件，跳过签名校验${NC}"
        return 0
    fi # <--- 修复了 V6.2.13 中的语法错误
    
    if ! command -v sha256sum &> /dev/null; then
        echo -e "${YELLOW}⚠️  警告：无法校验签名，sha256sum命令未找到${NC}"
        return 0
    fi
    
    local current_hash=$(sha256sum "$config_file" 2>/dev/null | cut -d' ' -f1)
    local stored_hash=$(cat "$signature_file" 2>/dev/null)
    
    if [ -z "$current_hash" ] || [ -z "$stored_hash" ]; then
        echo -e "${RED}❌ 错误：无法读取签名信息${NC}"
        return 1
    fi
    
    if [[ "$current_hash" != "$stored_hash" ]]; then
        echo -e "${RED}❌ 错误：配置文件签名不匹配，可能已被修改！${NC}"
        return 1
    fi
    
    echo -e "${GREEN}✅ 配置文件签名校验通过。${NC}"
    return 0
}

# 设置资源限制
set_resource_limits() {
    JOBS_N=$(nproc 2>/dev/null || echo 1)
    TOTAL_MEM_KB=$(grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $2}' || echo 0)

    # ulimit: 限制 CPU 时间 (4小时) 和 虚拟内存 (80% 物理内存)
    ulimit -t $((3600 * 4)) 2>/dev/null || true
    
    if [ "$TOTAL_MEM_KB" -gt 0 ]; then
        local max_mem_kb=$((TOTAL_MEM_KB * 80 / 100))
        ulimit -v "$max_mem_kb" 2>/dev/null || true
    fi
    
    local max_procs=$((JOBS_N * 2 + 50))
    ulimit -u "$max_procs" 2>/dev/null || true

    # 读取 CCACHE 实际限制 (持久化改进)
    if command -v ccache &> /dev/null; then
        local current_limit=$(ccache -s 2>/dev/null | grep -E "cache size \(maximum\)" | grep -oE "[0-9.]+ [A-Z]B" || echo "50G")
        CCACHE_LIMIT="$current_limit"
    fi
}

# 生成编译摘要报告
generate_build_summary() {
    local config_name="$1"
    local duration="$2"
    local log_file="$3"
    local firmware_dir="$4"
    
    echo -e "\n=====================================================" | tee -a "$log_file"
    echo "         📋 编译摘要报告" | tee -a "$log_file"
    echo "=====================================================" | tee -a "$log_file"
    echo "配置名称: $config_name" | tee -a "$log_file"
    echo "编译耗时: $duration" | tee -a "$log_file"
    echo "日志文件: $log_file" | tee -a "$log_file"
    
    local target_subdir=$(find "$firmware_dir" -mindepth 2 -maxdepth 2 -type d 2>/dev/null | head -n 1)
    
    if [ -d "$target_subdir" ]; then
        echo "固件输出 (${target_subdir}):" | tee -a "$log_file"
        find "$target_subdir" -maxdepth 1 -name "*.bin" -o -name "*.img" -o -name "*.gz" 2>/dev/null | head -n 10 | while read file; do
            local size=$(du -h "$file" 2>/dev/null | cut -f1 || echo "N/A")
            echo "  - $(basename "$file") ($size)" | tee -a "$log_file"
        done
    else
        echo "警告：未找到固件输出目录" | tee -a "$log_file"
    fi
    
    local warning_count=$(grep -c -i "warning" "$log_file" 2>/dev/null || echo "0")
    local error_count=$(grep -c -i "error" "$log_file" 2>/dev/null || echo "0")
    echo "警告数量: $warning_count" | tee -a "$log_file"
    echo "错误数量: $error_count" | tee -a "$log_file"
    
    echo -e "\n--- 📊 编译性能分析 ---" | tee -a "$log_file"
    if command -v ccache &> /dev/null; then
        local ccache_stats=$(ccache -s 2>/dev/null)
        local hit_rate=$(echo "$ccache_stats" | grep -E "cache hit \(rate\)" | grep -oE "[0-9]+\.[0-9]+%" || echo "N/A")
        local cache_size=$(echo "$ccache_stats" | grep -E "cache size" | head -1 | grep -oE "[0-9]+\.[0-9]+ [A-Z]B" || echo "N/A")
        echo "缓存命中率: $hit_rate | 缓存大小: $cache_size" | tee -a "$log_file"
    else
        echo "未安装 ccache，跳过缓存分析。" | tee -a "$log_file"
    fi

    echo "=====================================================" | tee -a "$log_file"
}

# 辅助函数：获取配置摘要
get_config_summary() {
    local config_name="$1"
    local config_file="$CONFIGS_DIR/$config_name.conf"
    declare -A VARS
    if [ -f "$config_file" ]; then
        # 使用 load_config_vars 函数来加载
        load_config_vars "$config_name" VARS >/dev/null 2>&1
        
        local summary="${VARS[FW_TYPE]}/${VARS[FW_BRANCH]} - ${VARS[CONFIG_FILE_NAME]}"
        if [[ "${VARS[EXTRA_PLUGINS]}" != "none" ]] && [[ -n "${VARS[EXTRA_PLUGINS]}" ]]; then
             summary+=" [插件]"
        fi
        if [[ "${VARS[CUSTOM_INJECTIONS]}" != "none" ]] && [[ -n "${VARS[CUSTOM_INJECTIONS]}" ]]; then
             summary+=" [注入]"
        fi
        echo "$summary"
    else
        echo "未找到配置"
    fi
}

# 辅助函数：加载配置变量 (健壮解析逻辑)
load_config_vars() {
    local config_name="$1"
    local -n VARS=$2
    local config_file="$CONFIGS_DIR/$config_name.conf"
    
    # 初始化所有变量为空，防止残留
    for k in "${CONFIG_VAR_NAMES[@]}"; do
        VARS["$k"]=""
    done

    if [ -f "$config_file" ]; then
        # 使用 while read 结合 Bash 正则表达式来健壮地读取变量，处理超长行和复杂内容
        while IFS= read -r line; do
            # 匹配一行: ^(变量名)="内容"$
            if [[ "$line" =~ ^([A-Z_]+)=\"(.*)\"$ ]]; then
                local k="${BASH_REMATCH[1]}"
                local v="${BASH_REMATCH[2]}"
                VARS["$k"]="$v"
            fi
        done < "$config_file"

        # 校验关键变量是否加载成功
        if [ -z "${VARS[FW_TYPE]}" ] || [ -z "${VARS[FW_BRANCH]}" ]; then
             echo "错误：配置文件 $config_file 加载关键变量失败，请检查内容是否包含不可见字符或换行符问题。" >&2
             return 1
        fi
        
        # 确保所有变量都至少有一个值，避免空字符串
        : ${VARS[EXTRA_PLUGINS]:="none"}
        : ${VARS[CUSTOM_INJECTIONS]:="none"}
        : ${VARS[ENABLE_QMODEM]:="n"}

        return 0
    fi
    return 1
}

# 辅助函数：模拟自定义注入脚本执行
run_custom_injections() {
    local injections="$1"
    local stage="$2"
    local source_dir="$3"
    
    # 只要 injections 字段不为 "none" 就尝试运行
    if [[ "$injections" == "none" ]]; then 
        return 0
    fi

    local script_path="$EXTRA_SCRIPT_DIR/build_injection_${stage}.sh"
    if [ -f "$script_path" ]; then
        echo -e "\n--- ${BLUE}⚙️  执行自定义注入脚本 (阶段 $stage)${NC} ($injections)" | tee -a "$BUILD_LOG_PATH"
        (
            cd "$source_dir" || exit 1
            # 允许脚本注入执行
            bash "$script_path" 2>&1 | tee -a "$BUILD_LOG_PATH"
        )
    fi
}

# 编译失败智能分析器
analyze_build_failure() {
    local log_file="$1"
    local error_lines=$(tail -100 "$log_file" 2>/dev/null)
    
    echo -e "\n--- ${RED}🔍 编译失败分析${NC} ---"
    
    local error_found=0
    
    # 1. 磁盘空间不足
    if echo "$error_lines" | grep -q "No space left on device\|disk full"; then
        echo -e "${YELLOW}⚠️  错误类型: 磁盘空间不足${NC}"
        echo "解决方案: 1. 清理磁盘空间; 2. 删除旧的编译输出; 3. 清理CCACHE缓存"
        error_found=1
    fi
    
    # 2. 内存不足
    if echo "$error_lines" | grep -q "Killed\|out of memory\|Cannot allocate memory"; then
        echo -e "${YELLOW}⚠️  错误类型: 内存不足${NC}"
        echo "解决方案: 1. 减少编译作业数; 2. 增加交换空间"
        error_found=1
    fi
    
    # 3. 网络下载失败
    if echo "$error_lines" | grep -q "Connection refused\|Failed to connect\|404 Not Found\|Could not resolve host"; then
        echo -e "${YELLOW}⚠️  错误类型: 网络连接问题${NC}"
        echo "解决方案: 检查网络连接和代理设置"
        error_found=1
    fi
    
    # 4. 编译依赖缺失
    if echo "$error_lines" | grep -q "No such file or directory\|command not found\|未找到命令"; then
        echo -e "${YELLOW}⚠️  错误类型: 依赖缺失${NC}"
        echo "解决方案: 安装缺失的依赖包"
        error_found=1
    fi
    
    # 5. 配置文件错误
    if echo "$error_lines" | grep -q "Invalid config option\|未知的配置选项\|Configuration failed"; then
        echo -e "${YELLOW}⚠️  错误类型: 配置文件错误${NC}"
        echo "解决方案: 检查配置文件语法或使用 make menuconfig 修复"
        error_found=1
    fi
    
    # 6. 特定包编译失败
    if echo "$error_lines" | grep -q "recipe for target.*failed\|Error [0-9]"; then
        local failed_pkg=$(echo "$error_lines" | grep -B5 "recipe for target" | grep -E "Package/|make\[.*\]: Entering directory" | tail -2 | head -1)
        if [ -n "$failed_pkg" ]; then
            echo -e "${YELLOW}⚠️  错误类型: 特定包编译失败${NC}"
            echo "失败包: $failed_pkg"
            echo "解决方案: 检查包的依赖或禁用该包"
        else
            echo -e "${YELLOW}⚠️  错误类型: 编译过程失败${NC}"
        fi
        error_found=1
    fi
    
    # 如果没有匹配到已知错误模式
    if [ "$error_found" -eq 0 ]; then
        echo -e "${YELLOW}⚠️  错误类型: 未知错误${NC}"
        echo "请查看日志文件末尾获取详细信息:"
        tail -15 "$log_file" 2>/dev/null | while read line; do
            if echo "$line" | grep -q -i "error\|fail\|致命\|错误"; then
                echo -e "${RED}$line${NC}"
            else
                echo "$line"
            fi
        done
        echo "----------------------------------------"
    fi
    
    echo -e "\n${BLUE}💡 快速修复建议:${NC}"
    echo "  1. 执行清理: cd $CURRENT_SOURCE_DIR && make clean"
    echo "  2. 重新下载依赖: make download -j$(nproc)"
    
    return 0
}


# --- 3. 核心编译流程函数 ---

# 克隆或更新源码
clone_or_update_source() {
    local REPO_URL="$1"
    local FW_BRANCH="$2"
    local FW_TYPE="$3"
    
    local TARGET_DIR_NAME="$FW_TYPE"
    if [[ "$FW_TYPE" == "custom" ]]; then
        local repo_hash=$(echo "$REPO_URL" | md5sum | cut -c1-8)
        TARGET_DIR_NAME="custom_source_$repo_hash"
    fi
    
    CURRENT_SOURCE_DIR="$SOURCE_ROOT/$TARGET_DIR_NAME"
    echo -e "--- ${BLUE}源码目录: $CURRENT_SOURCE_DIR${NC} ---" | tee -a "$BUILD_LOG_PATH"

    if [ -d "$CURRENT_SOURCE_DIR/.git" ]; then
        echo -e "${YELLOW}🔄 源码目录已存在，检查并更新 (git pull)...${NC}" | tee -a "$BUILD_LOG_PATH"
        (
            cd "$CURRENT_SOURCE_DIR" || exit 1
            git fetch origin "$FW_BRANCH" || return 1
            git reset --hard "origin/$FW_BRANCH" || return 1
            git clean -fd
        ) || {
            echo -e "${RED}❌ 源码更新失败${NC}" | tee -a "$BUILD_LOG_PATH"
            return 1
        }
    else
        echo -e "${BLUE}📥 正在克隆源码 ($REPO_URL)...${NC}" | tee -a "$BUILD_LOG_PATH"
        git clone "$REPO_URL" -b "$FW_BRANCH" "$CURRENT_SOURCE_DIR" || {
            echo -e "${RED}❌ 克隆失败，请检查 URL 或网络。${NC}" | tee -a "$BUILD_LOG_PATH"
            return 1
        }
    fi
    
    return 0
}

# 构建前检查
pre_build_checks() {
    echo -e "--- ${BLUE}环境与配置预检查${NC} ---"
    
    local available_space=$(df -BG "$BUILD_ROOT" 2>/dev/null | awk 'NR==2 {print $4}' | sed 's/G//' 2>/dev/null)
    if [ -z "$available_space" ] || [ "$available_space" -lt 30 ]; then
        echo -e "${RED}❌ 磁盘空间不足 (建议 >= 30GB)。当前可用: ${available_space}G${NC}"
        return 1
    fi
    
    set_resource_limits > /dev/null
    if [ "$TOTAL_MEM_KB" -lt 4000000 ]; then 
        echo -e "${YELLOW}⚠️  系统内存较低 (建议 >= 4GB)。${NC}"
    fi

    echo -e "${GREEN}✅ 环境预检查通过。${NC}"
    return 0
}

# 验证构建配置
validate_build_config() {
    local -n VARS=$1
    local config_name="$2"
    local error_count=0
    local warning_count=0
    
    echo -e "\n--- ${BLUE}🔍 验证配置: $config_name${NC} ---"
    
    local config_path="$USER_CONFIG_DIR/${VARS[CONFIG_FILE_NAME]}"
    if [[ ! -f "$config_path" ]]; then
        echo -e "${RED}❌ 错误：找不到配置文件: $config_path${NC}"
        error_count=$((error_count + 1))
    else
        echo -e "${GREEN}✅ 配置文件存在: $config_path${NC}"
        
        # 文件大小和内容检查
        local file_size=$(stat -c%s "$config_path" 2>/dev/null || echo "0")
        if [ "$file_size" -lt 100 ]; then
            echo -e "${YELLOW}⚠️  警告：配置文件过小（${file_size} 字节），可能为空或不完整${NC}"
            warning_count=$((warning_count + 1))
        fi
        
        # 安全性检查：检测可疑命令
        if grep -q "eval.*base64_decode\|wget.*http://.*sh\|curl.*http://.*sh" "$config_path" 2>/dev/null; then
            echo -e "${RED}⚠️  错误：配置文件中检测到可疑命令！${NC}"
            error_count=$((error_count + 1))
        fi
        
        # 签名校验
        if ! verify_config_signature "$config_path"; then
             error_count=$((error_count + 1))
        fi
    fi
    
    echo -e "\n--- ${BLUE}验证总结${NC} ---"
    echo "错误: $error_count 个 | 警告: $warning_count 个"
    
    if [ "$error_count" -gt 0 ]; then
        echo -e "${RED}🚨 发现 $error_count 个严重错误，无法继续。${NC}"
        return 1
    elif [ "$warning_count" -gt 0 ]; then
        echo -e "${YELLOW}⚠️  发现 $warning_count 个警告，建议检查后继续。${NC}"
        read -p "是否忽略警告继续？(y/n): " ignore_warnings
        if [[ "$ignore_warnings" != "y" ]]; then
            return 1
        fi
    fi
    
    echo -e "${GREEN}✅ 配置校验通过。${NC}"
    return 0
}

# 增强的依赖检查
check_and_install_dependencies() {
    echo -e "--- ${BLUE}系统环境检查与初始化...${NC} ---"
    
    local system_info=$(detect_system)
    echo -e "${GREEN}系统:${NC} $system_info"
    
    # 核心工具检查
    local core_tools=("git" "make" "bash" "gcc" "g++" "patch" "unzip" "rsync" "sha256sum")
    local build_tools=("file" "wget" "curl" "python3" "perl" "tar" "xz" "bzip2")
    
    echo -e "\n${BLUE}检查核心编译工具:${NC}"
    local missing_core=()
    for tool in "${core_tools[@]}"; do
        if ! command -v "$tool" &> /dev/null; then
            missing_core+=("$tool")
            echo -e "  ${RED}✗${NC} $tool"
        else
            local version=$("$tool" --version 2>&1 | head -1 | cut -d' ' -f1-3 2>/dev/null || echo "已安装")
            echo -e "  ${GREEN}✓${NC} $tool ($version)"
        fi
    done
    
    echo -e "\n${BLUE}检查辅助工具:${NC}"
    local missing_build=()
    for tool in "${build_tools[@]}"; do
        if ! command -v "$tool" &> /dev/null; then
            missing_build+=("$tool")
            echo -e "  ${YELLOW}⚠${NC} $tool"
        fi
    done
    
    # 如果缺少核心工具，提供安装建议
    if [ ${#missing_core[@]} -gt 0 ]; then
        echo -e "\n${RED}❌ 缺少核心编译工具:${NC}"
        printf '  %s\n' "${missing_core[@]}"
        
        # 提供安装建议
        if [[ "$system_info" == *"ubuntu"* || "$system_info" == *"debian"* ]]; then
            echo -e "\n${YELLOW}建议安装命令:${NC}"
            echo "  sudo apt update"
            echo "  sudo apt install build-essential ${missing_core[*]}"
        elif [[ "$system_info" == *"centos"* || "$system_info" == *"rhel"* ]]; then
            echo -e "\n${YELLOW}建议安装命令:${NC}"
            echo "  sudo yum groupinstall 'Development Tools'"
            echo "  sudo yum install ${missing_core[*]}"
        fi
        exit 1
    fi
    
    # 确保目录存在
    local dirs=("$CONFIGS_DIR" "$LOG_DIR" "$USER_CONFIG_DIR" "$EXTRA_SCRIPT_DIR" 
                "$OUTPUT_DIR" "$CCACHE_DIR" "$BACKUP_DIR")
    for dir in "${dirs[@]}"; do
        mkdir -p "$dir"
        chmod 755 "$dir"
    done
    
    # 设置根目录权限
    chmod 755 "$BUILD_ROOT"
    
    # 日志轮转改进
    ls -t "$LOG_DIR"/build_*.log 2>/dev/null | tail -n +11 | xargs rm -f 2>/dev/null
    find "$LOG_DIR" -name "build_*.log" -type f -mtime +7 -delete 2>/dev/null

    # 示例配置创建
    if ! ls "$CONFIGS_DIR"/*.conf 2>/dev/null; then
        echo -e "${YELLOW}ℹ️  创建示例配置: example.conf${NC}"
        cat > "$CONFIGS_DIR/example.conf" << EOF
FW_TYPE="immortalwrt"
REPO_URL="https://github.com/immortalwrt/immortalwrt.git"
FW_BRANCH="openwrt-21.02"
CONFIG_FILE_NAME="default_x86_64.config"
EXTRA_PLUGINS="none"
CUSTOM_INJECTIONS="none"
ENABLE_QMODEM="n"
EOF
        cat > "$USER_CONFIG_DIR/default_x86_64.config" << EOF
# 这是一个示例 OpenWrt 配置文件
CONFIG_TARGET_x86=y
CONFIG_TARGET_x86_64=y
CONFIG_TARGET_x86_64_DEVICE_generic=y
CONFIG_PACKAGE_bash=y
CONFIG_PACKAGE_curl=y
CONFIG_DEVEL=y
CONFIG_KALLSYMS=y
CONFIG_TESTING_KERNEL=y
EOF
        generate_config_signature "$USER_CONFIG_DIR/default_x86_64.config"
    fi
    
    echo -e "\n${GREEN}✅ 环境检查完成${NC}"
    return 0
}

# 编译前配置确认
confirm_build_settings() {
    local config_name="$1"
    local -n VARS=$2
    
    clear
    echo -e "${YELLOW}⚠️  编译配置确认${NC}"
    echo "========================================"
    echo "配置名称: $config_name"
    echo "固件类型: ${VARS[FW_TYPE]}"
    echo "仓库分支: ${VARS[FW_BRANCH]}"
    echo "配置文件: ${VARS[CONFIG_FILE_NAME]}"

    local plugins_summary="N/A (请使用 'make menuconfig' 添加插件)"
    if [[ "${VARS[EXTRA_PLUGINS]}" == "none" ]]; then
        plugins_summary="none"
    elif [[ -n "${VARS[EXTRA_PLUGINS]}" ]]; then
         # 检查用户提供的插件内容是否是脚本预期格式（逗号分隔的包名）
         if echo "${VARS[EXTRA_PLUGINS]}" | grep -q "git clone\|##"; then
              plugins_summary="${RED}非标准内容${NC} (请使用脚本注入功能)"
         else
              plugins_summary="${GREEN}已启用${NC}: ${VARS[EXTRA_PLUGINS]}"
         fi
    fi

    echo "额外插件: $plugins_summary"
    echo "脚本注入: ${VARS[CUSTOM_INJECTIONS]}"
    echo "QModem: ${VARS[ENABLE_QMODEM]}"
    echo "编译作业: $JOBS_N"
    echo "缓存限制: $CCACHE_LIMIT"
    echo "========================================"
    
    # 显示系统资源
    echo -e "\n${BLUE}系统资源:${NC}"
    echo "CPU核心: $(nproc)"
    echo "内存: $(free -h | awk '/^Mem:/ {print $2}')"
    echo "磁盘空间: $(df -h "$BUILD_ROOT" | awk 'NR==2 {print $4}') 可用"
    
    read -p "是否开始编译？(y/n): " confirm
    [[ "$confirm" == "y" || "$confirm" == "Y" ]]
}

# 编译产物归档
archive_build_artifacts() {
    local config_name="$1"
    local firmware_dir="$2"
    local log_file="$3"
    local duration="$4"
    
    local archive_base="$OUTPUT_DIR/${config_name}_$(date +%Y%m%d_%H%M%S)"
    local archive_name="${archive_base}.tar.gz"
    local temp_dir="/tmp/${config_name}_artifacts_$$"
    
    mkdir -p "$temp_dir"
    
    # 复制固件文件
    local target_subdir=$(find "$firmware_dir" -mindepth 2 -maxdepth 2 -type d 2>/dev/null | head -n 1)
    if [ -d "$target_subdir" ]; then
        cp -r "$target_subdir" "$temp_dir/firmware" 2>/dev/null
    fi
    
    # 复制日志
    cp "$log_file" "$temp_dir/build.log"
    
    # 保存环境信息
    {
        echo "编译时间: $(date)"
        echo "配置: $config_name"
        echo "耗时: $duration"
        echo "系统: $(uname -a)"
        echo "内存: $(free -h 2>/dev/null || echo 'N/A')"
        echo "磁盘: $(df -h 2>/dev/null || echo 'N/A')"
    } > "$temp_dir/environment.txt"
    
    # 创建压缩包
    tar -czf "$archive_name" -C "$temp_dir" . 2>/dev/null
    rm -rf "$temp_dir"
    
    if [ -f "$archive_name" ]; then
        echo -e "${GREEN}📦 编译产物已归档到: $archive_name${NC}"
    else
        echo -e "${YELLOW}⚠️  归档失败${NC}"
    fi
}

# 执行编译
execute_build() {
    local config_name="$1"
    local -n VARS=$2
    
    # 编译前确认
    if ! confirm_build_settings "$config_name" VARS; then
        echo -e "${YELLOW}编译已取消。${NC}"; sleep 1; return 0
    fi
    
    local FW_TYPE="${VARS[FW_TYPE]}"; local FW_BRANCH="${VARS[FW_BRANCH]}"
    local REPO_URL="${VARS[REPO_URL]}"; local CFG_FILE="${VARS[CONFIG_FILE_NAME]}"
    local BUILD_TIME_STAMP_FULL=$(date +%Y%m%d_%H%M%S) 
    BUILD_LOG_PATH="$LOG_DIR/build_${config_name}_${BUILD_TIME_STAMP_FULL}.log"

    echo -e "\n=== ${BLUE}🚀 开始编译 [$config_name] (V${SCRIPT_VERSION})${NC} ===" | tee -a "$BUILD_LOG_PATH"
    echo "日志文件: $BUILD_LOG_PATH" | tee -a "$BUILD_LOG_PATH"
    
    set_resource_limits
    
    local MEM_PER_JOB=1500000 
    
    # 限制 JOBS_N 确保不会因内存不足而失败
    if [ "$TOTAL_MEM_KB" -gt 0 ] && [ "$TOTAL_MEM_KB" -gt "$MEM_PER_JOB" ]; then
        local MAX_JOBS_BY_MEM=$((TOTAL_MEM_KB / MEM_PER_JOB))
        if [ "$MAX_JOBS_BY_MEM" -lt "$JOBS_N" ]; then
            echo -e "${YELLOW}⚠️  内存限制：从 ${JOBS_N} 作业调整为 ${MAX_JOBS_BY_MEM} 作业${NC}" | tee -a "$BUILD_LOG_PATH"
            JOBS_N="$MAX_JOBS_BY_MEM"
        fi
    fi
    echo "使用 ${JOBS_N} 个编译作业 (make -j${JOBS_N})" | tee -a "$BUILD_LOG_PATH"
    
    if ! clone_or_update_source "$REPO_URL" "$FW_BRANCH" "$FW_TYPE"; then return 1; fi
    
    local START_TIME=$(date +%s); local MAKE_RET=1; local FIRMWARE_DIR="$CURRENT_SOURCE_DIR/bin/targets"
    
    ( 
        cd "$CURRENT_SOURCE_DIR" || exit 1
        set_resource_limits 
        
        export CCACHE_DIR="$CCACHE_DIR"
        export PATH="/usr/lib/ccache:$PATH"
        ccache -z 2>/dev/null
        
        # 阶段 100: 在 feeds 更新前
        run_custom_injections "${VARS[CUSTOM_INJECTIONS]}" "100" "$CURRENT_SOURCE_DIR"
        
        # QModem 注入
        if [[ "${VARS[ENABLE_QMODEM]}" == "y" ]]; then
             if ! grep -q "qmodem" feeds.conf.default; then 
                 echo 'src-git qmodem https://github.com/FUjr/QModem.git;main' >> feeds.conf.default
             fi
        fi
        
        echo -e "\n--- ${BLUE}更新 Feeds${NC} ---" | tee -a "$BUILD_LOG_PATH"
        ./scripts/feeds update -a && ./scripts/feeds install -a || { 
            echo -e "${RED}Feeds 失败${NC}" | tee -a "$BUILD_LOG_PATH"
            exit 1
        }
        
        echo -e "\n--- ${BLUE}导入配置 ($CFG_FILE)${NC} ---" | tee -a "$BUILD_LOG_PATH"
        local src_cfg="$USER_CONFIG_DIR/$CFG_FILE"
        if [[ ! -f "$src_cfg" ]]; then 
            echo -e "${RED}❌ 错误: 配置文件丢失${NC}" | tee -a "$BUILD_LOG_PATH"
            exit 1
        fi

        cp "$src_cfg" .config
        # 第一次 defconfig: 应用目标和基本设置
        make defconfig 2>&1 | tee -a "$BUILD_LOG_PATH" || { 
            echo -e "${RED}make defconfig 失败 (初次)${NC}" | tee -a "$BUILD_LOG_PATH"
            exit 1
        }
        
        # === 处理额外插件 ===
        if [[ "${VARS[EXTRA_PLUGINS]}" != "none" ]] && [[ -n "${VARS[EXTRA_PLUGINS]}" ]]; then
            # 警告：这里假设 EXTRA_PLUGINS 已经是逗号分隔的包名
            if ! echo "${VARS[EXTRA_PLUGINS]}" | grep -q "git clone\|##"; then
                echo -e "\n--- ${BLUE}⚙️  注入额外插件: ${VARS[EXTRA_PLUGINS]}${NC} ---" | tee -a "$BUILD_LOG_PATH"
                local plugin
                IFS=',' read -ra PLUGINS_ARRAY <<< "${VARS[EXTRA_PLUGINS]}"
                for plugin in "${PLUGINS_ARRAY[@]}"; do
                    plugin=$(echo "$plugin" | xargs) # 去除空格
                    if [ -n "$plugin" ]; then
                        echo "CONFIG_PACKAGE_$plugin=y" >> .config
                        echo "  -> 添加 CONFIG_PACKAGE_$plugin=y" | tee -a "$BUILD_LOG_PATH"
                    fi
                done
                
                # 第二次 defconfig: 应用额外插件
                echo -e "\n--- ${BLUE}二次 make defconfig (应用插件)${NC} ---" | tee -a "$BUILD_LOG_PATH"
                make defconfig 2>&1 | tee -a "$BUILD_LOG_PATH" || { 
                    echo -e "${RED}make defconfig 失败 (二次)${NC}" | tee -a "$BUILD_LOG_PATH"
                    exit 1
                }
            else
                echo -e "${YELLOW}⚠️  警告: EXTRA_PLUGINS 格式错误，跳过插件注入。请使用 CUSTOM_INJECTIONS。${NC}" | tee -a "$BUILD_LOG_PATH"
            fi
        fi
        # ====================

        # 阶段 850: 下载依赖前
        run_custom_injections "${VARS[CUSTOM_INJECTIONS]}" "850" "$CURRENT_SOURCE_DIR"
        
        local download_phase_jobs=$((JOBS_N > 8 ? 8 : JOBS_N))
        echo -e "\n--- ${BLUE}🌐 下载依赖包 (make download -j$download_phase_jobs)${NC} ---" | tee -a "$BUILD_LOG_PATH"
        
        make download -j"$download_phase_jobs" V=s 2>&1 | tee -a "$BUILD_LOG_PATH"
        if [ ${PIPESTATUS[0]} -ne 0 ]; then 
            echo -e "${RED}❌ 下载失败${NC}" | tee -a "$BUILD_LOG_PATH"
            exit 1
        fi
        
        echo -e "\n--- ${BLUE}🚀 开始编译 (make -j$JOBS_N)${NC} ---" | tee -a "$BUILD_LOG_PATH"
        
        # 目标计数
        local total_targets=$(make -n V=s 2>&1 | grep -E "make\[[0-9]+\]: Entering directory.*package" | wc -l 2>/dev/null || echo 0)
        if [ "$total_targets" -eq 0 ]; then 
             echo -e "${YELLOW}⚠️  警告：无法精确统计目标，使用保守估计...${NC}" | tee -a "$BUILD_LOG_PATH"
             total_targets=$(find package -name Makefile -type f 2>/dev/null | wc -l || echo 50) 
        fi
        
        local PROGRESS_PID=0
        if [ "$total_targets" -gt 0 ]; then
            monitor_progress_bar "$total_targets" "$BUILD_LOG_PATH" &
            PROGRESS_PID=$!
        fi

        /usr/bin/time -f "MAKE_REAL_TIME=%e" make -j"$JOBS_N" V=s 2>&1 | tee -a "$BUILD_LOG_PATH"
        MAKE_RET=$?
        
        if [ "$PROGRESS_PID" -ne 0 ]; then 
            kill "$PROGRESS_PID" 2>/dev/null
            wait "$PROGRESS_PID" 2>/dev/null
        fi
        echo "--- ⏱️ 跟踪结束 ---" | tee -a "$BUILD_LOG_PATH"

        if [ $MAKE_RET -eq 0 ]; then 
            exit 0
        else 
            exit 1
        fi
    )
    
    local ret=$? 
    local END_TIME=$(date +%s)
    local DURATION=$((END_TIME - START_TIME))
    local DURATION_STR=$(printf '%dh %dm %ds' $((DURATION/3600)) $(((DURATION%3600)/60)) $((DURATION%60)))

    if [ $ret -eq 0 ]; then
        echo -e "\n${GREEN}✅ 编译成功！总耗时: $DURATION_STR${NC}"
        
        generate_build_summary "$config_name" "$DURATION_STR" "$BUILD_LOG_PATH" "$FIRMWARE_DIR"
        archive_build_artifacts "$config_name" "$FIRMWARE_DIR" "$BUILD_LOG_PATH" "$DURATION_STR"

        read -p "编译完成。按回车返回..."

    else
        echo -e "${RED}❌ 编译出错 (退出码 $ret)，请查看日志: $BUILD_LOG_PATH${NC}"
        analyze_build_failure "$BUILD_LOG_PATH"
        read -p "按回车返回..."
    fi
    return $ret
}

# --- 4. 新增功能模块 (智能管理与诊断) ---

# 编译缓存智能管理
manage_compile_cache() {
    while true; do
        clear; echo -e "## ${BLUE}🔄 编译缓存智能管理${NC}"
        
        if ! command -v ccache &> /dev/null; then
            echo -e "${RED}❌ CCACHE未安装，跳过缓存管理${NC}"; read -p "按回车返回..."; return
        fi

        # 确保 CCACHE_LIMIT 反映最新状态
        set_resource_limits > /dev/null 

        local ccache_stats=$(ccache -s 2>/dev/null)
        local hit_rate=$(echo "$ccache_stats" | grep -E "cache hit \(rate\)" | grep -oE "[0-9]+\.[0-9]+%" || echo "0%")
        local cache_size=$(echo "$ccache_stats" | grep -E "cache size" | head -1 | grep -oE "[0-9]+\.[0-9]+ [A-Z]B" || echo "0.0 GB")
        
        echo "当前 CCACHE 状态:"
        echo "  命中率: ${GREEN}$hit_rate${NC}"
        echo "  缓存大小: ${YELLOW}$cache_size${NC}"
        
        local cache_dir_size=$(du -sh "$CCACHE_DIR" 2>/dev/null | cut -f1 || echo "N/A")
        echo "  缓存目录 (实际): $cache_dir_size"

        echo -e "\n管理选项:"
        echo "1) 显示详细统计 (ccache -s -v)"
        echo "2) 清空 CCACHE 缓存 (ccache -C)"
        echo "3) 调整 CCACHE 大小限制 (当前: $CCACHE_LIMIT)"
        echo "4) 压缩 CCACHE 缓存 (ccache -c)"
        echo "5) 清理源码临时文件 (\$SRC/tmp)"
        echo "6) 清理源码下载缓存 (\$SRC/dl)"
        echo "R) 返回主菜单"
        
        read -p "选择操作: " cache_choice
        
        case $cache_choice in
            1) ccache -s -v; read -p "按回车继续..." ;;
            2) 
                read -p "确定要清空 CCACHE 缓存吗？(y/n): " confirm
                if [[ "$confirm" == "y" ]]; then
                    ccache -C
                    echo -e "${GREEN}✅ CCACHE 缓存已清空${NC}"
                fi
                sleep 1 ;;
            3)
                read -p "输入新的大小 (如 100G, 200G): " new_size
                if [[ -n "$new_size" ]]; then
                    # 实际设置 CCACHE 限制并更新全局变量 (持久化改进)
                    ccache -M "$new_size" 
                    CCACHE_LIMIT="$new_size"
                    echo -e "${GREEN}✅ 缓存大小已调整为 $new_size${NC}"
                fi
                sleep 1 ;;
            4)
                echo "正在压缩 CCACHE 缓存..."
                ccache -c
                echo -e "${GREEN}✅ 缓存压缩完成${NC}"
                sleep 1 ;;
            5)
                if [ -d "$CURRENT_SOURCE_DIR/tmp" ]; then
                    read -p "确定清理 \$SRC/tmp 临时文件目录? (y/n): " clean_tmp
                    if [[ "$clean_tmp" == "y" ]]; then
                        rm -rf "$CURRENT_SOURCE_DIR/tmp"/*
                        echo -e "${GREEN}✅ 临时文件已清理${NC}"
                    fi
                else
                    echo -e "${YELLOW}ℹ️  源码目录 $CURRENT_SOURCE_DIR/tmp 不存在。${NC}"
                fi
                sleep 1 ;;
            6)
                if [ -d "$CURRENT_SOURCE_DIR/dl" ]; then
                    read -p "${YELLOW}⚠️  警告：清理下载缓存将导致下次编译需要重新下载所有依赖。确定继续？(y/n): ${NC}" confirm_dl
                    if [[ "$confirm_dl" == "y" ]]; then
                        rm -rf "$CURRENT_SOURCE_DIR/dl"/*
                        echo -e "${GREEN}✅ 下载缓存已清理${NC}"
                    fi
                else
                    echo -e "${YELLOW}ℹ️  源码目录 $CURRENT_SOURCE_DIR/dl 不存在。${NC}"
                fi
                sleep 1 ;;
            R|r) return ;;
            *) echo -e "${RED}无效选择。${NC}"; sleep 1 ;;
        esac
    done
}

# 编译环境诊断工具
diagnose_build_environment() {
    clear; echo -e "## ${BLUE}🔧 编译环境诊断报告${NC}"
    
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    local report_file="$LOG_DIR/environment_diagnosis_$(date +%Y%m%d_%H%M%S).log"
    
    echo "诊断时间: $timestamp" | tee -a "$report_file"
    echo "========================================" | tee -a "$report_file"
    
    # 1. 系统基本信息
    echo -e "\n${GREEN}1. 系统基本信息${NC}" | tee -a "$report_file"
    echo "操作系统: $(detect_system)" | tee -a "$report_file"
    echo "内核版本: $(uname -r)" | tee -a "$report_file"
    echo "架构: $(uname -m)" | tee -a "$report_file"
    
    # 2. 硬件资源
    echo -e "\n${GREEN}2. 硬件资源${NC}" | tee -a "$report_file"
    echo "CPU核心数: $(nproc)" | tee -a "$report_file"
    
    local mem_total=$(free -h | grep Mem | awk '{print $2}' 2>/dev/null || echo "N/A")
    echo "内存总量: $mem_total" | tee -a "$report_file"
    
    # 磁盘空间
    echo -e "\n磁盘空间信息 (BUILD_ROOT):" | tee -a "$report_file"
    df -h "$BUILD_ROOT" 2>/dev/null | tee -a "$report_file" || echo "无法获取磁盘信息" | tee -a "$report_file"
    
    # 3. 编译工具版本
    echo -e "\n${GREEN}3. 编译工具版本${NC}" | tee -a "$report_file"
    
    local tools=("gcc" "g++" "make" "git" "python3" "perl" "bash" "ld" "sha256sum")
    for tool in "${tools[@]}"; do
        if command -v "$tool" &> /dev/null; then
            local version=$("$tool" --version 2>/dev/null | head -1)
            echo "$tool: $version" | tee -a "$report_file"
        else
            echo -e "${RED}$tool: 未安装${NC}" | tee -a "$report_file"
        fi
    done
    
    # 4. OpenWrt编译特定依赖
    echo -e "\n${GREEN}4. OpenWrt编译环境状态${NC}" | tee -a "$report_file"
    
    if command -v ccache &> /dev/null; then
        echo "CCACHE: 已安装。目录: $CCACHE_DIR" | tee -a "$report_file"
        ccache -s 2>/dev/null | head -10 | tee -a "$report_file"
    else
        echo -e "${RED}CCACHE: 未安装。建议安装以加速编译。${NC}" | tee -a "$report_file"
    fi
    
    # 5. 网络连接检查
    echo -e "\n${GREEN}5. 网络连接检查${NC}" | tee -a "$report_file"
    
    local test_urls=("github.com" "git.openwrt.org")
    for url in "${test_urls[@]}"; do
        if ping -c 1 -W 2 "$url" &> /dev/null; then
            echo "  $url: ${GREEN}可达${NC}" | tee -a "$report_file"
        else
            echo -e "${RED}  $url: 不可达${NC}" | tee -a "$report_file"
        fi
    done
    
    # 6. 警告和建议
    echo -e "\n${GREEN}6. 诊断建议${NC}" | tee -a "$report_file"
    
    local available_kb=$(df -k "$BUILD_ROOT" 2>/dev/null | awk 'NR==2 {print $4}' || echo "0")
    if [ "$available_kb" -lt 10485760 ]; then # 10GB
        echo -e "${RED}⚠️  警告：磁盘空间不足，建议至少10GB${NC}" | tee -a "$report_file"
    fi
    
    local mem_kb=$(grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $2}' || echo "0")
    if [ "$mem_kb" -lt 4000000 ]; then # 4GB
        echo -e "${YELLOW}⚠️  注意：内存较少，建议增加内存或交换空间${NC}" | tee -a "$report_file"
    fi
    
    echo -e "\n========================================" | tee -a "$report_file"
    echo "诊断报告已保存到: $report_file"
    
    read -p "按任意键继续..."
}

# --- 5. 菜单与流程控制 ---

# 统一选择配置的函数
select_config_from_list() {
    local configs=("$CONFIGS_DIR"/*.conf)
    if [ ${#configs[@]} -eq 0 ] || ([ ${#configs[@]} -eq 1 ] && [ ! -f "${configs[0]}" ]); then 
        echo -e "${YELLOW}无可用配置。${NC}"
        return 1
    fi
    
    local i=1; local files=();
    echo "-----------------------------------------------------"
    for file in "${configs[@]}"; do
        local fn=$(basename "$file" .conf)
        # 此处调用 get_config_summary 获取配置摘要
        local summary=$(get_config_summary "$fn")
        # 修复列表仅显示名称的问题，确保即使摘要为空也会显示配置名
        if [[ -n "$summary" ]]; then
            echo "$i) ${GREEN}$fn${NC} ($summary)"
        else
             echo "$i) ${GREEN}$fn${NC}"
        fi
        files[i]="$fn"; i=$((i+1))
    done
    echo "-----------------------------------------------------"
    
    read -p "请选择配置序号 [1-$((i-1))]: " c
    if [[ "$c" =~ ^[0-9]+$ ]] && [ "$c" -ge 1 ] && [ "$c" -lt "$i" ]; then
        echo "${files[$c]}" # 返回选中的配置名
        return 0
    fi
    echo -e "${RED}无效的选择或已取消。${NC}"
    return 1
}

# 恢复用户偏好的菜单式编辑配置函数 (核心修改点)
manage_config_vars_menu() {
    local config_name="$1"
    local config_file="$CONFIGS_DIR/$config_name.conf"
    
    # 使用健壮解析器加载配置
    declare -A VARS
    if ! load_config_vars "$config_name" VARS; then 
        read -p "配置加载失败，按回车返回..."
        return
    fi
    
    local dirty=0 # 标记是否进行了修改
    
    while true; do
        clear
        echo -e "====================================================="
        echo -e "   📝 Edit 配置: ${GREEN}$config_name${NC}"
        echo -e "  (请确保在 $USER_CONFIG_DIR 提供了配置好的 .config 文件)"
        echo -e "====================================================="
        
        # 动态计算插件和注入条目数（兼容错误格式和正确格式）
        local plugins_count=0
        if [[ "${VARS[EXTRA_PLUGINS]}" != "none" ]] && [[ -n "${VARS[EXTRA_PLUGINS]}" ]]; then
            # 兼容非标准格式的简单计数
            if echo "${VARS[EXTRA_PLUGINS]}" | grep -q "git clone\|##"; then
                plugins_count=$(echo "${VARS[EXTRA_PLUGINS]}" | awk -F'##' '{print NF}')
            else
                # 否则使用逗号分隔计数
                plugins_count=$(echo "${VARS[EXTRA_PLUGINS]}" | awk -F',' '{print NF}')
            fi
        fi
        
        local injections_count=0
        if [[ "${VARS[CUSTOM_INJECTIONS]}" != "none" ]] && [[ -n "${VARS[CUSTOM_INJECTIONS]}" ]]; then
            # 使用逗号分隔计数
            injections_count=$(echo "${VARS[CUSTOM_INJECTIONS]}" | awk -F',' '{print NF}')
        fi
        
        # 显示状态
        local qmodem_status="[${RED}N${NC}]"
        if [[ "${VARS[ENABLE_QMODEM]}" == "y" ]]; then qmodem_status="[${GREEN}Y${NC}]"; fi
        
        echo "1. 固件类型/分支: ${VARS[FW_TYPE]} / ${VARS[FW_BRANCH]}"
        echo "2. 配置 (config) 文件名: ${VARS[CONFIG_FILE_NAME]}"
        echo "3. 🧩 额外插件列表 (${plugins_count} 条): ${VARS[EXTRA_PLUGINS]}"
        echo "4. ⚙️ 脚本注入描述 (${injections_count} 条): ${VARS[CUSTOM_INJECTIONS]}"
        echo "5. $qmodem_status 内置 Qmodem"
        echo "6. 仓库 URL: ${VARS[REPO_URL]}"
        echo "7. 检查配置文件的位置和名称"
        echo "-----------------------------------------------------"
        echo "S) 保存配置并返回 | R) 放弃修改并返回"
        read -p "请选择要修改的项 (1-7, S/R): " edit_choice
        
        case $edit_choice in
            1) 
                read -p "新类型 (i: immortalwrt, o: openwrt, 当前 ${VARS[FW_TYPE]}): " new_type_choice
                local new_fw_type="${VARS[FW_TYPE]}"
                if [[ "$new_type_choice" =~ ^[Ii]$ ]]; then new_fw_type="immortalwrt"; fi
                if [[ "$new_type_choice" =~ ^[Oo]$ ]]; then new_fw_type="openwrt"; fi
                VARS[FW_TYPE]="$new_fw_type"
                
                read -p "新分支名称 (当前 ${VARS[FW_BRANCH]}): " new_branch_input
                VARS[FW_BRANCH]="${new_branch_input:-${VARS[FW_BRANCH]}}"
                dirty=1
                ;;
            2)
                read -p "新 .config 文件名 (当前 ${VARS[CONFIG_FILE_NAME]}): " new_cfg_file
                if [[ -n "$new_cfg_file" ]]; then
                    VARS[CONFIG_FILE_NAME]="$new_cfg_file"
                    dirty=1
                fi
                ;;
            3)
                echo -e "${YELLOW}当前插件列表 (逗号分隔的包名，或 'none'): ${VARS[EXTRA_PLUGINS]}${NC}"
                read -p "输入新的插件列表: " new_plugins
                if [[ -n "$new_plugins" ]]; then
                    VARS[EXTRA_PLUGINS]="$new_plugins"
                    dirty=1
                fi
                ;;
            4)
                echo -e "${YELLOW}当前注入描述 (例如: custom_repo,patch1,none): ${VARS[CUSTOM_INJECTIONS]}${NC}"
                read -p "输入新的注入描述: " new_injections
                if [[ -n "$new_injections" ]]; then
                    VARS[CUSTOM_INJECTIONS]="$new_injections"
                    dirty=1
                fi
                ;;
            5)
                read -p "启用 Qmodem (y/n, 当前 ${VARS[ENABLE_QMODEM]}): " new_qmodem_choice
                local new_qmodem="${VARS[ENABLE_QMODEM]}"
                if [[ "$new_qmodem_choice" =~ ^[Yy]$ ]]; then new_qmodem="y"; fi
                if [[ "$new_qmodem_choice" =~ ^[Nn]$ ]]; then new_qmodem="n"; fi
                if [[ "$new_qmodem" != "${VARS[ENABLE_QMODEM]}" ]]; then dirty=1; fi
                VARS[ENABLE_QMODEM]="$new_qmodem"
                ;;
            6)
                read -p "新仓库 URL (当前 ${VARS[REPO_URL]}): " new_repo_url
                if [[ -n "$new_repo_url" ]]; then
                    VARS[REPO_URL]="$new_repo_url"
                    dirty=1
                fi
                ;;
            7)
                echo -e "\n${BLUE}配置文件路径:${NC} $USER_CONFIG_DIR/${VARS[CONFIG_FILE_NAME]}"
                read -p "按回车返回..."
                ;;
            S|s) 
                # 保存并退出
                cat > "$config_file" << EOF
FW_TYPE="${VARS[FW_TYPE]}"
REPO_URL="${VARS[REPO_URL]}"
FW_BRANCH="${VARS[FW_BRANCH]}"
CONFIG_FILE_NAME="${VARS[CONFIG_FILE_NAME]}"
EXTRA_PLUGINS="${VARS[EXTRA_PLUGINS]}"
CUSTOM_INJECTIONS="${VARS[CUSTOM_INJECTIONS]}"
ENABLE_QMODEM="${VARS[ENABLE_QMODEM]}"
EOF
                echo -e "${GREEN}✅ 配置 '$config_name' 已保存。${NC}"
                read -p "按回车返回..."
                return 0
                ;;
            R|r)
                if [ "$dirty" -eq 1 ]; then
                    read -p "${YELLOW}⚠️  配置已被修改，确定放弃更改吗？(y/n): ${NC}" confirm_discard
                    if [[ "$confirm_discard" =~ ^[Yy]$ ]]; then
                        echo -e "${YELLOW}更改已放弃。${NC}"; return 0
                    fi
                else
                    return 0
                fi
                ;;
            *) echo -e "${RED}无效选择。${NC}"; sleep 1 ;;
        esac
    done
}


# 1) 新建机型配置
create_new_config() {
    clear; echo -e "## ${BLUE}🌟 新建机型配置${NC}"
    read -p "请输入新的配置名称 (例如: R4S_full): " name
    if [[ -z "$name" ]]; then echo -e "${RED}名称不能为空。${NC}"; sleep 1; return; fi

    local conf_file="$CONFIGS_DIR/$name.conf"
    if [ -f "$conf_file" ]; then echo -e "${RED}配置 '$name' 已存在。${NC}"; sleep 1; return; fi

    read -p "ImmortalWrt 或 OpenWrt (i/o): " type_choice
    local fw_type="immortalwrt"
    if [[ "$type_choice" =~ ^[Oo]$ ]]; then fw_type="openwrt"; fi
    
    read -p "请输入仓库 URL (默认: https://github.com/immortalwrt/immortalwrt.git): " repo_url
    if [[ -z "$repo_url" ]]; then repo_url="https://github.com/immortalwrt/immortalwrt.git"; fi

    read -p "请输入分支名称 (默认: openwrt-21.02): " branch
    if [[ -z "$branch" ]]; then branch="openwrt-21.02"; fi
    
    read -p "请输入配置 .config 文件名 (例如: $name.config): " cfg_file_name
    if [[ -z "$cfg_file_name" ]]; then cfg_file_name="$name.config"; fi
    
    # 额外插件
    echo -e "\n${YELLOW}额外插件提示: 逗号分隔的 OpenWrt 包名 (默认: none)${NC}"
    read -p "额外插件 (EXTRA_PLUGINS): " extra_plugins
    if [[ -z "$extra_plugins" ]]; then extra_plugins="none"; fi

    # 脚本注入
    echo -e "${YELLOW}脚本注入提示: 描述性文字 (默认: none)${NC}"
    read -p "自定义脚本注入 (CUSTOM_INJECTIONS): " custom_injections
    if [[ -z "$custom_injections" ]]; then custom_injections="none"; fi

    read -p "是否启用 QModem (y/n, 默认n): " qmodem_choice
    local enable_qmodem="n"
    if [[ "$qmodem_choice" =~ ^[Yy]$ ]]; then enable_qmodem="y"; fi

    # 创建配置文件
    cat > "$conf_file" << EOF
FW_TYPE="$fw_type"
REPO_URL="$repo_url"
FW_BRANCH="$branch"
CONFIG_FILE_NAME="$cfg_file_name"
EXTRA_PLUGINS="$extra_plugins"
CUSTOM_INJECTIONS="$custom_injections"
ENABLE_QMODEM="$enable_qmodem"
EOF

    local user_cfg_path="$USER_CONFIG_DIR/$cfg_file_name"
    echo -e "${YELLOW}请创建或导入您的 OpenWrt .config 文件到: ${user_cfg_path}${NC}"
    echo -e "${GREEN}✅ 配置 '$name' 已创建。${NC}"; sleep 1
    
    read -p "是否立即使用 nano 编辑 .config 文件? (y/n): " edit_choice
    if [[ "$edit_choice" =~ ^[Yy]$ ]]; then
        if command -v nano &> /dev/null; then
            touch "$user_cfg_path"
            nano "$user_cfg_path"
            generate_config_signature "$user_cfg_path"
        else
            echo -e "${RED}❌ 未找到 nano，请手动编辑。${NC}"
        fi
    else
        echo -e "${YELLOW}请记得使用 make menuconfig 或手动编辑 $user_cfg_path 来初始化配置！${NC}"
    fi

    read -p "按回车返回..."
}

# 2) 选择/编辑/删除配置
manage_configs_menu() {
    while true; do
        clear; echo -e "## ${BLUE}⚙️  配置管理中心${NC}"
        local config_name=$(select_config_from_list)
        
        if [ $? -ne 0 ]; then read -p "按回车返回..."; return; fi

        echo -e "\n选中配置: ${GREEN}$config_name${NC}"
        echo "1) ✏️  编辑配置 (.conf) | 2) ⚙️  编辑 .config 文件 | 3) 🗑️  删除配置 | 4) 返回"
        read -p "操作选择 (1-4): " op_choice

        case $op_choice in
            1) # 菜单式编辑 .conf
                manage_config_vars_menu "$config_name"
                ;;
            2) # 编辑 .config
                declare -A VARS
                if load_config_vars "$config_name" VARS; then
                    local cfg_path="$USER_CONFIG_DIR/${VARS[CONFIG_FILE_NAME]}"
                    if command -v nano &> /dev/null; then
                        touch "$cfg_path"
                        nano "$cfg_path"
                        generate_config_signature "$cfg_path"
                        echo -e "${GREEN}✅ .config 文件已更新签名。${NC}"
                    else
                        echo -e "${RED}未找到 nano，请手动编辑: $cfg_path${NC}"
                    fi
                fi
                read -p "按回车返回..."
                ;;
            3) # 删除配置
                read -p "${RED}警告：确认删除配置 $config_name 及其 .conf 文件? (y/n): ${NC}" del_confirm
                if [[ "$del_confirm" =~ ^[Yy]$ ]]; then
                    declare -A VARS_DEL
                    load_config_vars "$config_name" VARS_DEL
                    
                    rm -f "$CONFIGS_DIR/$config_name.conf"
                    read -p "是否同时删除关联的 .config 文件 (${VARS_DEL[CONFIG_FILE_NAME]})? (y/n): " del_cfg_confirm
                    if [[ "$del_cfg_confirm" =~ ^[Yy]$ ]]; then
                         rm -f "$USER_CONFIG_DIR/${VARS_DEL[CONFIG_FILE_NAME]}"
                         rm -f "$USER_CONFIG_DIR/${VARS_DEL[CONFIG_FILE_NAME]}.sig"
                    fi
                    
                    echo -e "${GREEN}✅ 配置 $config_name$ 已删除。${NC}"
                fi
                read -p "按回车返回..."
                ;;
            4) return ;;
            *) echo -e "${RED}无效选择。${NC}" ;;
        esac
    done
}

# 3) 启动单配置编译
start_build_process() {
    clear; echo -e "## ${BLUE}🚀 启动单配置编译${NC}"
    local config_name=$(select_config_from_list)
    
    if [ $? -ne 0 ]; then read -p "按回车返回..."; return; fi 
    
    declare -A VARS
    if load_config_vars "$config_name" VARS; then
        
        # ⚠️ 修复用户配置中的错误插件格式
        if echo "${VARS[EXTRA_PLUGINS]}" | grep -q "git clone\|##"; then
            echo -e "${RED}🚨 错误警告: ${NC}配置 ${config_name} 的 'EXTRA_PLUGINS' 字段包含非标准内容 (如 git clone 或 ##)。"
            echo -e "  该字段**仅**用于逗号分隔的 OpenWrt 包名 (如 luci-app-ssr-plus)。"
            echo -e "  外部仓库克隆/Patch 应使用 ${YELLOW}CUSTOM_INJECTIONS${NC} 功能。"
            read -p "是否忽略此错误并继续，或按 Ctrl+C 退出脚本进行修复? (y/n): " continue_anyway
            if [[ "$continue_anyway" != "y" ]]; then
                 echo -e "${YELLOW}已取消编译。请修改 $CONFIGS_DIR/$config_name.conf${NC}"
                 read -p "按回车返回主菜单..."
                 return
            fi
        fi

        if ! pre_build_checks; then
            echo -e "${RED}❌ 环境检查失败，请根据提示解决问题。${NC}"
            read -p "按回车返回主菜单..."
            return
        fi
        
        if ! validate_build_config VARS "$config_name"; then
            echo -e "${RED}❌ 配置校验失败，请根据提示修复配置。${NC}"
            read -p "按回车返回主菜单..."
            return
        fi

        execute_build "$config_name" VARS
    fi
}

# 4) 批量编译队列
build_queue_menu() {
    clear; echo -e "## ${BLUE}📦 批量编译队列${NC}"
    local configs=("$CONFIGS_DIR"/*.conf)
    if [ ${#configs[@]} -eq 0 ] || ([ ${#configs[@]} -eq 1 ] && [ ! -f "${configs[0]}" ]); then 
        echo -e "${YELLOW}无配置。${NC}"; read -p "回车..."; return; 
    fi
    
    local queue=(); local i=1; local files=()
    while true; do
        clear; echo "待选配置 (当前在队列中: ${#queue[@]} 个):"
        i=1
        for file in "${configs[@]}"; do
            local fn=$(basename "$file" .conf)
            local mk=" "; 
            for item in "${queue[@]}"; do [[ "$item" == "$fn" ]] && { mk="${GREEN}✅${NC}"; break; }; done
            
            echo "$i) $mk $fn ($(get_config_summary "$fn"))"; files[i]="$fn"; i=$((i+1))
        done
        echo "A) 切换选择  S) 开始  R) 返回"
        read -p "选择: " c
        case $c in
            A|a) 
                read -p "序号: " x; local n="${files[$x]}"; 
                if [[ -n "$n" ]]; then
                    local found=0
                    local new_queue=()
                    for item in "${queue[@]}"; do
                        if [[ "$item" == "$n" ]]; then
                            found=1
                        else
                            new_queue+=("$item")
                        fi
                    done
                    queue=("${new_queue[@]}")
                    if [ "$found" -eq 0 ]; then queue+=("$n"); fi
                fi 
                ;;
            S|s) 
                if ! pre_build_checks; then 
                    echo -e "${RED}❌ 环境校验失败，批量编译终止${NC}"
                    read -p "按回车返回..."; return
                fi
                for q in "${queue[@]}"; do 
                    [[ -n "$q" ]] && {
                        declare -A B_VARS
                        if load_config_vars "$q" B_VARS; then
                             # 批量编译时，强制跳过非标准 EXTRA_PLUGINS 的配置
                            if echo "${B_VARS[EXTRA_PLUGINS]}" | grep -q "git clone\|##"; then
                                echo -e "${RED}❌ 配置 $q 的 EXTRA_PLUGINS 格式错误，跳过批量编译。${NC}"
                                continue
                            fi

                            echo -e "\n--- ${BLUE}[批处理] 开始编译 $q${NC} ---"
                            if validate_build_config B_VARS "$q"; then
                                execute_build "$q" B_VARS
                            else
                                echo -e "${RED}❌ 配置 $q 校验失败，跳过。${NC}"
                                read -p "按回车继续下一个配置..."
                            fi
                        fi
                    }
                done
                read -p "批处理结束。" 
                ;;
            R|r) return ;;
            *) echo -e "${RED}无效选择。${NC}"; sleep 1 ;;
        esac
    done
}

# 5) 导出配置备份
export_config_backup() {
    clear; echo -e "## ${BLUE}📤 导出配置备份${NC}"
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local archive_name="immortalwrt_configs_backup_${timestamp}.zip"
    local archive_path="$BACKUP_DIR/$archive_name"

    (
        cd "$BUILD_ROOT" || exit 1
        zip -r "$archive_path" profiles user_configs custom_scripts 2>/dev/null
    )
    
    if [ -f "$archive_path" ]; then
        echo -e "${GREEN}✅ 备份成功！${NC}"
        echo "备份文件路径: $archive_path"
        echo "备份内容: profiles, user_configs, custom_scripts"
    else
        echo -e "${RED}❌ 备份失败，请检查 zip/权限。${NC}"
    fi
    read -p "按回车返回..."
}

# 6) 导入配置备份
import_config_backup() {
    clear; echo -e "## ${BLUE}📥 导入配置备份${NC}"
    read -p "请输入备份文件 (.zip) 的完整路径: " zip_path
    
    if [[ ! -f "$zip_path" ]]; then
        echo -e "${RED}❌ 错误：文件不存在或路径错误。${NC}"; read -p "按回车返回..."
        return
    fi
    
    # 使用 temp 目录解压
    local temp_dir="/tmp/immortalwrt_import_$$"
    mkdir -p "$temp_dir"
    
    echo "正在解压文件..."
    unzip -o "$zip_path" -d "$temp_dir" 2>/dev/null
    
    if [ $? -ne 0 ]; then
        echo -e "${RED}❌ 解压失败，请检查文件是否为有效的 zip 格式。${NC}"
        rm -rf "$temp_dir"
        read -p "按回车返回..."; return
    fi
    
    echo -e "${YELLOW}警告：导入将覆盖现有配置！${NC}"
    read -p "是否确认覆盖导入 profiles, user_configs, custom_scripts 目录? (y/n): " confirm_import

    if [[ "$confirm_import" =~ ^[Yy]$ ]]; then
        echo "正在执行覆盖导入..."
        cp -r "$temp_dir/profiles/." "$CONFIGS_DIR" 2>/dev/null
        cp -r "$temp_dir/user_configs/." "$USER_CONFIG_DIR" 2>/dev/null
        cp -r "$temp_dir/custom_scripts/." "$EXTRA_SCRIPT_DIR" 2>/dev/null
        
        echo -e "${GREEN}✅ 导入完成。${NC}"
    else
        echo -e "${YELLOW}导入已取消。${NC}"
    fi

    rm -rf "$temp_dir"
    read -p "按回车返回..."
}

# 主菜单
main_menu() {
    while true; do
        clear
        echo -e "====================================================="
        echo -e "   🔥 ${GREEN}ImmortalWrt 固件编译管理脚本 V${SCRIPT_VERSION}${NC} 🔥"
        echo -e "      (功能完整 | 交互式配置 | 智能诊断)"
        echo -e "====================================================="
        show_system_info
        echo -e "-----------------------------------------------------"
        echo "1) 🌟 新建机型配置 (含插件/注入)"
        echo "2) ⚙️  配置管理 (编辑/删除)"
        echo "3) 🚀 启动单配置编译"
        echo "4) 📦 批量编译队列"
        echo "5) 📊 CCACHE 及缓存管理"
        echo "6) 📤 导出配置备份"
        echo "7) 📥 导入配置备份"
        echo "8) 🔬 编译环境诊断报告"
        echo -e "-----------------------------------------------------"
        
        read -p "请选择功能 (1-8, 0/Q 退出): " choice
        
        case $choice in
            1) create_new_config ;;
            2) manage_configs_menu ;;
            3) start_build_process ;;
            4) build_queue_menu ;;
            5) manage_compile_cache ;;
            6) export_config_backup ;;
            7) import_config_backup ;;
            8) diagnose_build_environment ;;
            0|Q|q) echo -e "${BLUE}退出脚本。${NC}"; break ;;
            *) echo -e "${RED}无效选择，请重新输入。${NC}"; sleep 1 ;;
        esase
    done
}

# --- 6. 安全退出与陷阱 ---

# 安全退出函数
cleanup_on_exit() {
    echo -e "\n${BLUE}正在清理临时文件...${NC}"
    
    # 查找并删除临时管道文件
    rm -f /tmp/progress_monitor_*.pipe 2>/dev/null
    rm -f /tmp/*_artifacts_* 2>/dev/null
    rm -rf /tmp/immortalwrt_import_* 2>/dev/null
    
    # 重置ulimit
    ulimit -t unlimited 2>/dev/null || true
    ulimit -v unlimited 2>/dev/null || true
    ulimit -u unlimited 2>/dev/null || true
    
    # 保存ccache统计
    if command -v ccache &> /dev/null; then
        ccache -s > "$LOG_DIR/ccache_stats_$(date +%Y%m%d).log" 2>/dev/null
    fi
    
    echo -e "${GREEN}✅ 清理完成${NC}"
}
# 设置退出陷阱
trap cleanup_on_exit EXIT INT TERM

# --- 脚本入口 ---
# 必须先调用 set_resource_limits 来初始化 CCACHE_LIMIT
set_resource_limits
check_bash_version
check_and_install_dependencies
main_menu
