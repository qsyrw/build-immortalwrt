#!/bin/bash

# ==========================================================
# 🔥 ImmortalWrt/OpenWrt 固件编译管理脚本 V6.2.5 (增强版)
# ----------------------------------------------------------
# (健壮性增强 | 智能诊断 | 实时进度监控 | 增强安全和清理)
# ==========================================================

# --- 1. 颜色定义与基础变量 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# --- 版本控制和兼容性检查 ---
SCRIPT_VERSION="6.2.5"
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
declare -g CCACHE_LIMIT="50G" 
declare -g JOBS_N=1
declare -g TOTAL_MEM_KB=0

CONFIG_VAR_NAMES=(FW_TYPE REPO_URL FW_BRANCH CONFIG_FILE_NAME EXTRA_PLUGINS CUSTOM_INJECTIONS ENABLE_QMODEM)

# --- 2. 核心辅助函数 ---

# 检查bash版本 (新增)
check_bash_version() {
    local bash_version=${BASH_VERSION%.*}
    if (( ${bash_version%.*} < MIN_BASH_VERSION )); then
        echo -e "${RED}❌ 脚本需要 Bash ${MIN_BASH_VERSION}+，当前为 ${BASH_VERSION}${NC}"
        exit 1
    fi
}

# 检查系统类型 (新增)
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

# 编译环境资源信息显示 (新增)
show_system_info() {
    echo -e "${BLUE}系统信息: ${NC}"
    echo -e "  系统: $(detect_system)"
    echo -e "  CPU: $(nproc) 核心"
    echo -e "  内存: $(free -h | awk '/^Mem:/ {print $2}')"
    echo -e "  磁盘: $(df -h "$BUILD_ROOT" | awk 'NR==2 {print $4}') 可用"
}


# 进度条监控函数
monitor_progress_bar() {
    local total_targets=$1
    local log_file=$2
    
    # ... (此处省略 monitor_progress_bar 细节，与原脚本相同) ...
    if [ "$total_targets" -le 0 ]; then return; fi
    
    echo -e "\n--- ${GREEN}✅ 编译进度: 0%${NC} ---"
    
    local completed_targets=0
    local last_progress=0
    local start_time=$(date +%s)
    
    local pipe_file="/tmp/progress_monitor_$$.pipe"
    mkfifo "$pipe_file"
    
    tail -f "$log_file" 2>/dev/null > "$pipe_file" &
    local tail_pid=$!
    
    while IFS= read -r line; do
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
    rm -f "$pipe_file"
    
    echo -e "\n${GREEN}✅ 编译进度: 100%${NC} (或进程已结束)"
}


# 配置文件签名
generate_config_signature() {
    # ... (与原脚本相同) ...
    local config_file="$1"
    local signature_file="${config_file}.sig"
    if command -v sha256sum &> /dev/null; then
        sha256sum "$config_file" | cut -d' ' -f1 > "$signature_file"
        echo -e "${GREEN}🔑 配置文件签名已生成/更新。${NC}"
    else
        echo -e "${YELLOW}⚠️  无法生成签名：未找到 sha256sum 命令。${NC}"
    fi
}

# 验证签名
verify_config_signature() {
    # ... (与原脚本相同) ...
    local config_file="$1"
    local signature_file="${config_file}.sig"
    
    if [ ! -f "$signature_file" ]; then
        echo -e "${YELLOW}⚠️  警告：配置文件没有签名文件，跳过签名校验${NC}"
        return 0
    fi
    
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
    JOBS_N=$(nproc)
    TOTAL_MEM_KB=$(grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $2}' || echo 0)

    # ulimit: 限制 CPU 时间 (4小时) 和 虚拟内存 (80% 物理内存)
    ulimit -t $((3600 * 4)) 2>/dev/null
    
    if [ "$TOTAL_MEM_KB" -gt 0 ]; then
        local max_mem_kb=$((TOTAL_MEM_KB * 80 / 100))
        ulimit -v "$max_mem_kb" 2>/dev/null
    fi
    
    local max_procs=$((JOBS_N * 2 + 50))
    ulimit -u "$max_procs" 2>/dev/null
}

# 生成编译摘要报告
generate_build_summary() {
    # ... (与原脚本相同，但移除了归档部分，交由新函数处理) ...
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
        find "$target_subdir" -maxdepth 1 -name "*.bin" -o -name "*.img" -o -name "*.gz" | head -n 10 | while read file; do
             echo "  - $(basename "$file") ($(du -h "$file" | cut -f1))" | tee -a "$log_file"
        done
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

# 辅助函数：加载配置变量
load_config_vars() {
    # ... (与原脚本相同) ...
    local config_name="$1"
    local -n VARS=$2
    local config_file="$CONFIGS_DIR/$config_name.conf"
    if [ -f "$config_file" ]; then
        while IFS='=' read -r k v; do 
            [[ "$k" =~ ^[A-Z_]+$ ]] && VARS["$k"]=$(echo "$v" | sed 's/^"//;s/"$//'); 
        done < "$config_file"
        return 0
    fi
    return 1
}

# 辅助函数：模拟自定义注入脚本执行
run_custom_injections() {
    # ... (与原脚本相同) ...
    local injections="$1"
    local stage="$2"
    local source_dir="$3"
    
    if [[ "$injections" == "none" ]]; then 
        return 0
    fi

    local script_path="$EXTRA_SCRIPT_DIR/build_injection_${stage}.sh"
    if [ -f "$script_path" ]; then
        echo -e "\n--- ${BLUE}⚙️  执行自定义注入脚本 (阶段 $stage)${NC} ---" | tee -a "$BUILD_LOG_PATH"
        (
            cd "$source_dir" || exit 1
            bash "$script_path" 2>&1 | tee -a "$BUILD_LOG_PATH"
        )
    fi
}

# 编译失败智能分析器
analyze_build_failure() {
    # ... (与原脚本相同) ...
    local log_file="$1"
    local error_lines=$(tail -100 "$log_file" 2>/dev/null)
    
    echo -e "\n--- ${RED}🔍 编译失败分析${NC} ---"
    
    local error_found=0
    
    # 1. 磁盘空间不足
    if echo "$error_lines" | grep -q "No space left on device\|disk full"; then
        echo -e "${YELLOW}⚠️  错误类型: 磁盘空间不足${NC}"
        echo "解决方案:"
        echo "  1. 清理磁盘空间: df -h"
        echo "  2. 删除旧的编译输出: rm -rf $BUILD_ROOT/output/*"
        echo "  3. 清理CCACHE缓存: ccache -C"
        error_found=1
    fi
    # ... (省略其余分析逻辑，与原脚本相同) ...
    
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


# 增强的依赖检查 (替换原有函数)
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
            echo -e "  ${GREEN}✓${NC} $tool ($("$tool" --version 2>&1 | head -1 | cut -d' ' -f1-3))"
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
    
    # 日志轮转改进 (保留)
    ls -t "$LOG_DIR"/build_*.log 2>/dev/null | tail -n +11 | xargs rm -f 2>/dev/null
    find "$LOG_DIR" -name "build_*.log" -type f -mtime +7 -delete 2>/dev/null

    # 示例配置创建 (保留)
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


# 编译前配置确认 (新增)
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

# 编译产物归档 (新增)
archive_build_artifacts() {
    local config_name="$1"
    local firmware_dir="$2"
    local log_file="$3"
    local duration="$4"
    
    local archive_base="$OUTPUT_DIR/${config_name}_$(date +%Y%m%d_%H%M%S)"
    local archive_name="${archive_base}.tar.gz"
    local temp_dir="/tmp/${config_name}_artifacts_$$"
    
    mkdir -p "$temp_dir"
    
    # 复制固件文件 (仅复制目标架构子目录的内容)
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
        echo "内存: $(free -h)"
        echo "磁盘: $(df -h)"
    } > "$temp_dir/environment.txt"
    
    # 创建压缩包
    tar -czf "$archive_name" -C "$temp_dir" . 2>/dev/null
    rm -rf "$temp_dir"
    
    echo -e "${GREEN}📦 编译产物已归档到: $archive_name${NC}"
}


execute_build() {
    local config_name="$1"
    local -n VARS=$2
    
    # 编译前确认 (调用新增函数)
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
    
    # 限制 JOBS_N 确保不会因内存不足而失败 (保留原逻辑)
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
        
        # ... (省略中间 Feeds 和 defconfig 逻辑) ...
        
        export CCACHE_DIR="$CCACHE_DIR"
        export PATH="/usr/lib/ccache:$PATH"
        ccache -z 2>/dev/null
        
        run_custom_injections "${VARS[CUSTOM_INJECTIONS]}" "100" "$CURRENT_SOURCE_DIR"
        
        if [[ "${VARS[ENABLE_QMODEM]}" == "y" ]]; then
             if ! grep -q "qmodem" feeds.conf.default; then echo 'src-git qmodem https://github.com/FUjr/QModem.git;main' >> feeds.conf.default; fi
        fi
        
        echo -e "\n--- ${BLUE}更新 Feeds${NC} ---" | tee -a "$BUILD_LOG_PATH"
        ./scripts/feeds update -a && ./scripts/feeds install -a || { echo -e "${RED}Feeds 失败${NC}"; exit 1; }
        
        echo -e "\n--- ${BLUE}导入配置 ($CFG_FILE)${NC} ---" | tee -a "$BUILD_LOG_PATH"
        local src_cfg="$USER_CONFIG_DIR/$CFG_FILE"
        if [[ ! -f "$src_cfg" ]]; then echo -e "${RED}❌ 错误: 配置文件丢失${NC}" | tee -a "$BUILD_LOG_PATH"; exit 1; fi

        cp "$src_cfg" .config
        make defconfig 2>&1 | tee -a "$BUILD_LOG_PATH" || { echo -e "${RED}make defconfig 失败${NC}"; exit 1; }
        
        run_custom_injections "${VARS[CUSTOM_INJECTIONS]}" "850" "$CURRENT_SOURCE_DIR"
        
        local download_phase_jobs=$((JOBS_N > 8 ? 8 : JOBS_N))
        echo -e "\n--- ${BLUE}🌐 下载依赖包 (make download -j$download_phase_jobs)${NC} ---" | tee -a "$BUILD_LOG_PATH"
        
        # 修复用户指出的冗余语法错误 (第1点)
        make download -j"$download_phase_jobs" V=s 2>&1 | tee -a "$BUILD_LOG_PATH"
        if [ ${PIPESTATUS[0]} -ne 0 ]; then echo -e "${RED}❌ 下载失败${NC}" | tee -a "$BUILD_LOG_PATH"; exit 1; fi
        
        echo -e "\n--- ${BLUE}🚀 开始编译 (make -j$JOBS_N)${NC} ---" | tee -a "$BUILD_LOG_PATH"
        
        # 目标计数
        local total_targets=$(make -n V=s 2>/dev/null | grep -c "^Building target \|^make\[.*\]: Entering directory.*package/")
        if [ "$total_targets" -eq 0 ]; then 
             total_targets=$(find package -name Makefile 2>/dev/null | wc -l) 
        fi
        
        local PROGRESS_PID=0
        if [ "$total_targets" -gt 0 ]; then
            monitor_progress_bar "$total_targets" "$BUILD_LOG_PATH" &
            PROGRESS_PID=$!
        fi

        /usr/bin/time -f "MAKE_REAL_TIME=%e" make -j"$JOBS_N" V=s 2>&1 | tee -a "$BUILD_LOG_PATH"
        MAKE_RET=$?
        
        if [ "$PROGRESS_PID" -ne 0 ]; then kill $PROGRESS_PID 2>/dev/null; wait $PROGRESS_PID 2>/dev/null; fi
        echo "--- ⏱️ 跟踪结束 ---" | tee -a "$BUILD_LOG_PATH"

        if [ $MAKE_RET -eq 0 ]; then exit 0; else exit 1; fi
    )
    
    local ret=$? 
    local END_TIME=$(date +%s)
    local DURATION=$((END_TIME - START_TIME))
    local DURATION_STR=$(printf '%dh %dm %ds' $((DURATION/3600)) $(((DURATION%3600)/60)) $((DURATION%60)))

    if [ $ret -eq 0 ]; then
        echo -e "\n${GREEN}✅ 编译成功！总耗时: $DURATION_STR${NC}"
        
        generate_build_summary "$config_name" "$DURATION_STR" "$BUILD_LOG_PATH" "$FIRMWARE_DIR"
        
        # 移除原脚本中的 zip 归档，改为调用增强函数
        archive_build_artifacts "$config_name" "$FIRMWARE_DIR" "$BUILD_LOG_PATH" "$DURATION_STR"

        read -p "编译完成。按回车返回..."

    else
        echo -e "${RED}❌ 编译出错 (退出码 $ret)，请查看日志: $BUILD_LOG_PATH${NC}"
        analyze_build_failure "$BUILD_LOG_PATH"
        read -p "按回车返回..."
    fi
    return $ret
}

# --- 6. 菜单与流程控制 (保留其他功能) ---

# 主菜单 (替换原有函数，添加 show_system_info)
main_menu() {
    while true; do
        clear
        echo -e "====================================================="
        echo -e "   🔥 ${GREEN}ImmortalWrt 固件编译管理脚本 V${SCRIPT_VERSION}${NC} 🔥"
        echo -e "      (智能诊断 | 实时进度 | CCACHE: ${CCACHE_LIMIT} 上限)"
        echo -e "====================================================="
        show_system_info  # 显示系统信息 (第2点)
        echo -e "-----------------------------------------------------"
        echo "1) 🌟 新建机型配置"
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
        esac
    done
}


# --- 7. 安全退出与陷阱 ---

# 安全退出函数 (新增)
cleanup_on_exit() {
    echo -e "\n${BLUE}正在清理临时文件...${NC}"
    
    # 查找并删除临时管道文件
    rm -f /tmp/progress_monitor_*.pipe 2>/dev/null
    
    # 重置ulimit
    ulimit -t unlimited 2>/dev/null
    ulimit -v unlimited 2>/dev/null
    ulimit -u unlimited 2>/dev/null
    
    # 保存ccache统计
    if command -v ccache &> /dev/null; then
        ccache -s > "$LOG_DIR/ccache_stats_$(date +%Y%m%d).log" 2>/dev/null
    fi
    
    echo -e "${GREEN}✅ 清理完成${NC}"
}

# 设置退出陷阱 (第6点)
trap cleanup_on_exit EXIT

# --- 脚本入口 ---
check_bash_version # 检查 Bash 版本 (第2点)
check_and_install_dependencies # 增强的依赖检查 (第3点)
main_menu
