#!/bin/bash

# ==========================================================
# 🔥 ImmortalWrt/OpenWrt 固件编译管理脚本 V6.3.0 (稳定重构版)
# ----------------------------------------------------------
# 基于 V6.0.0 稳定交互逻辑进行功能整合与Bug修复
# ==========================================================

# --- 1. 颜色定义与基础变量 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# --- 版本控制和兼容性检查 ---
SCRIPT_VERSION="6.3.0 (Stable Refactor)"
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
declare -g CCACHE_LIMIT="50G" # 初始默认值
declare -g JOBS_N=1
declare -g TOTAL_MEM_KB=0

# 配置变量名称列表 (用于健壮加载和保存)
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
    echo -e "  CPU: $(nproc 2>/dev/null || echo 1) 核心"
    local mem_info=$(free -h 2>/dev/null | awk '/^Mem:/ {print $2}' || echo "N/A")
    echo -e "  内存: $mem_info"
    local disk_info=$(df -h "$BUILD_ROOT" 2>/dev/null | awk 'NR==2 {print $4}' || echo "N/A")
    echo -e "  磁盘: $disk_info 可用"
    echo -e "  CCACHE: $CCACHE_LIMIT 上限"
}

# 配置文件签名
generate_config_signature() {
    local config_file="$1"
    local signature_file="${config_file}.sig"
    if command -v sha256sum &> /dev/null; then
        sha256sum "$config_file" | cut -d' ' -f1 > "$signature_file"
    fi
}

# 验证签名 (修复后的 V6.2.13 语法)
verify_config_signature() {
    local config_file="$1"
    local signature_file="${config_file}.sig"
    
    if [ ! -f "$signature_file" ]; then return 0; fi 
    if ! command -v sha256sum &> /dev/null; then return 0; fi
    
    local current_hash=$(sha256sum "$config_file" 2>/dev/null | cut -d' ' -f1)
    local stored_hash=$(cat "$signature_file" 2>/dev/null)
    
    if [[ "$current_hash" != "$stored_hash" ]]; then
        echo -e "${RED}❌ 错误：配置文件签名不匹配，可能已被修改！${NC}"
        return 1
    fi
    return 0
}

# 设置资源限制 (优化：更智能地限制编译 J 数量)
set_resource_limits() {
    JOBS_N=$(nproc 2>/dev/null || echo 1)
    TOTAL_MEM_KB=$(grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $2}' || echo 0)

    # 限制 JOBS_N 确保不会因内存不足而失败 (每核分配 1.5GB 内存)
    local MEM_PER_JOB=1500000 
    if [ "$TOTAL_MEM_KB" -gt 0 ] && [ "$TOTAL_MEM_KB" -gt "$MEM_PER_JOB" ]; then
        local MAX_JOBS_BY_MEM=$((TOTAL_MEM_KB / MEM_PER_JOB))
        if [ "$MAX_JOBS_BY_MEM" -lt "$JOBS_N" ]; then
            JOBS_N="$MAX_JOBS_BY_MEM"
        fi
    fi
    
    # 读取 CCACHE 实际限制 
    if command -v ccache &> /dev/null; then
        local current_limit=$(ccache -s 2>/dev/null | grep -E "cache size \(maximum\)" | grep -oE "[0-9.]+ [A-Z]B" || echo "50G")
        CCACHE_LIMIT="$current_limit"
    fi
}

# 编译失败智能分析器
analyze_build_failure() {
    local log_file="$1"
    local error_lines=$(tail -100 "$log_file" 2>/dev/null)
    
    echo -e "\n--- ${RED}🔍 编译失败分析${NC} ---"
    
    if echo "$error_lines" | grep -q "No space left on device\|disk full"; then
        echo -e "${YELLOW}⚠️  错误类型: 磁盘空间不足${NC}"
    elif echo "$error_lines" | grep -q "Killed\|out of memory\|Cannot allocate memory"; then
        echo -e "${YELLOW}⚠️  错误类型: 内存不足 (OOM)${NC}"
    elif echo "$error_lines" | grep -q "Connection refused\|Failed to connect\|404 Not Found"; then
        echo -e "${YELLOW}⚠️  错误类型: 网络下载失败${NC}"
    elif echo "$error_lines" | grep -q "Invalid config option\|Configuration failed"; then
        echo -e "${YELLOW}⚠️  错误类型: 配置文件错误${NC}"
    elif echo "$error_lines" | grep -q "recipe for target.*failed\|Error [0-9]"; then
        local failed_pkg=$(echo "$error_lines" | grep -B5 "recipe for target" | grep -E "Package/|make\[.*\]: Entering directory" | tail -2 | head -1)
        echo -e "${YELLOW}⚠️  错误类型: 特定包编译失败${NC}"
        echo "失败包: $failed_pkg"
    else
        echo -e "${YELLOW}⚠️  错误类型: 未知错误${NC}"
        tail -10 "$log_file" 2>/dev/null
    fi
    
    echo -e "\n${BLUE}💡 快速修复建议:${NC}"
    echo "  1. 检查磁盘空间和内存使用。"
    echo "  2. 尝试执行清理: cd $CURRENT_SOURCE_DIR && make clean"
    echo "  3. 检查您的配置是否引入了不兼容的软件包或补丁。"
    return 0
}

# 辅助函数：加载配置变量
load_config_vars() {
    local config_name="$1"
    local -n VARS=$2
    local config_file="$CONFIGS_DIR/$config_name.conf"
    
    # 初始化所有变量为空
    for k in "${CONFIG_VAR_NAMES[@]}"; do VARS["$k"]=""; done

    if [ -f "$config_file" ]; then
        while IFS= read -r line; do
            if [[ "$line" =~ ^([A-Z_]+)=\"(.*)\"$ ]]; then
                local k="${BASH_REMATCH[1]}"
                local v="${BASH_REMATCH[2]}"
                VARS["$k"]="$v"
            fi
        done < "$config_file"

        # 确保变量不为空
        : ${VARS[EXTRA_PLUGINS]:="none"}
        : ${VARS[CUSTOM_INJECTIONS]:="none"}
        : ${VARS[ENABLE_QMODEM]:="n"}

        return 0
    fi
    return 1
}

# 辅助函数：获取配置摘要
get_config_summary() {
    local config_name="$1"
    declare -A VARS
    if load_config_vars "$config_name" VARS >/dev/null 2>&1; then
        local summary="${VARS[FW_TYPE]}/${VARS[FW_BRANCH]} - ${VARS[CONFIG_FILE_NAME]}"
        if [[ "${VARS[EXTRA_PLUGINS]}" != "none" ]] && [[ -n "${VARS[EXTRA_PLUGINS]}" ]]; then
             summary+=" [插件]"
        fi
        if [[ "${VARS[CUSTOM_INJECTIONS]}" != "none" ]] && [[ -n "${VARS[CUSTOM_INJECTIONS]}" ]]; then
             summary+=" [注入]"
        fi
        echo "$summary"
    else
        echo "配置加载失败"
    fi
}

# 辅助函数：模拟自定义注入脚本执行
run_custom_injections() {
    local injections="$1"
    local stage="$2"
    local source_dir="$3"
    
    if [[ "$injections" == "none" ]]; then return 0; fi

    local script_path="$EXTRA_SCRIPT_DIR/build_injection_${stage}.sh"
    if [ -f "$script_path" ]; then
        echo -e "\n--- ${BLUE}⚙️  执行自定义注入脚本 (阶段 $stage)${NC}" | tee -a "$BUILD_LOG_PATH"
        (
            cd "$source_dir" || exit 1
            bash "$script_path" 2>&1 | tee -a "$BUILD_LOG_PATH"
        )
    fi
}

# --- 3. 初始化与预检查 ---

check_and_install_dependencies() {
    echo -e "--- ${BLUE}环境检查与初始化...${NC} ---"
    
    # 核心工具检查
    local core_tools=("git" "make" "bash" "gcc" "g++" "patch" "unzip" "rsync" "sha256sum")
    local missing_core=()
    for tool in "${core_tools[@]}"; do
        if ! command -v "$tool" &> /dev/null; then
            missing_core+=("$tool")
        fi
    done
    
    if [ ${#missing_core[@]} -gt 0 ]; then
        echo -e "${RED}❌ 缺少核心编译工具:${NC} ${missing_core[*]}"
        echo "请安装这些依赖包后重试。"
        exit 1
    fi
    
    # 确保目录存在
    local dirs=("$CONFIGS_DIR" "$LOG_DIR" "$USER_CONFIG_DIR" "$EXTRA_SCRIPT_DIR" 
                "$OUTPUT_DIR" "$CCACHE_DIR" "$BACKUP_DIR")
    for dir in "${dirs[@]}"; do
        mkdir -p "$dir"
        chmod 755 "$dir"
    done
    
    # 创建示例配置
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
EOF
        generate_config_signature "$USER_CONFIG_DIR/default_x86_64.config"
    fi
    
    echo -e "${GREEN}✅ 环境检查完成${NC}"
    return 0
}

# --- 4. 核心编译流程 ---

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
        echo -e "${YELLOW}🔄 源码目录已存在，检查并更新...${NC}" | tee -a "$BUILD_LOG_PATH"
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
        echo -e "${BLUE}📥 正在克隆源码...${NC}" | tee -a "$BUILD_LOG_PATH"
        git clone "$REPO_URL" -b "$FW_BRANCH" "$CURRENT_SOURCE_DIR" || {
            echo -e "${RED}❌ 克隆失败，请检查 URL 或分支。${NC}" | tee -a "$BUILD_LOG_PATH"
            return 1
        }
    fi
    
    return 0
}

# 核心编译执行函数
execute_build() {
    local config_name="$1"
    local -n VARS=$2
    
    local FW_TYPE="${VARS[FW_TYPE]}"; local FW_BRANCH="${VARS[FW_BRANCH]}"
    local REPO_URL="${VARS[REPO_URL]}"; local CFG_FILE="${VARS[CONFIG_FILE_NAME]}"
    local BUILD_TIME_STAMP_FULL=$(date +%Y%m%d_%H%M%S) 
    BUILD_LOG_PATH="$LOG_DIR/build_${config_name}_${BUILD_TIME_STAMP_FULL}.log"

    echo -e "\n=== ${BLUE}🚀 开始编译 [$config_name] (V${SCRIPT_VERSION})${NC} ===" | tee -a "$BUILD_LOG_PATH"
    echo "日志文件: $BUILD_LOG_PATH" | tee -a "$BUILD_LOG_PATH"
    set_resource_limits

    if ! clone_or_update_source "$REPO_URL" "$FW_BRANCH" "$FW_TYPE"; then return 1; fi
    
    local START_TIME=$(date +%s); local MAKE_RET=1
    
    ( 
        cd "$CURRENT_SOURCE_DIR" || exit 1
        export CCACHE_DIR="$CCACHE_DIR"
        export PATH="/usr/lib/ccache:$PATH"
        ccache -z 2>/dev/null 

        run_custom_injections "${VARS[CUSTOM_INJECTIONS]}" "100" "$CURRENT_SOURCE_DIR" # 阶段 100
        
        # QModem 注入
        if [[ "${VARS[ENABLE_QMODEM]}" == "y" ]]; then
             if ! grep -q "qmodem" feeds.conf.default; then 
                 echo 'src-git qmodem https://github.com/FUjr/QModem.git;main' >> feeds.conf.default
             fi
        fi
        
        echo -e "\n--- ${BLUE}更新 Feeds${NC} ---" | tee -a "$BUILD_LOG_PATH"
        ./scripts/feeds update -a && ./scripts/feeds install -a || { 
            echo -e "${RED}Feeds 更新/安装失败${NC}" | tee -a "$BUILD_LOG_PATH"
            exit 1
        }
        
        echo -e "\n--- ${BLUE}导入配置 ($CFG_FILE)${NC} ---" | tee -a "$BUILD_LOG_PATH"
        local src_cfg="$USER_CONFIG_DIR/$CFG_FILE"
        if [[ ! -f "$src_cfg" ]]; then 
            echo -e "${RED}❌ 错误: 配置文件 $CFG_FILE 丢失或路径错误。${NC}" | tee -a "$BUILD_LOG_PATH"
            exit 1
        fi
        cp "$src_cfg" .config
        
        make defconfig 2>&1 | tee -a "$BUILD_LOG_PATH" || { 
            echo -e "${RED}make defconfig 失败 (初次)${NC}" | tee -a "$BUILD_LOG_PATH"
            exit 1
        }
        
        # 处理额外插件
        if [[ "${VARS[EXTRA_PLUGINS]}" != "none" ]] && [[ -n "${VARS[EXTRA_PLUGINS]}" ]]; then
            echo -e "\n--- ${BLUE}⚙️  注入额外插件${NC} ---" | tee -a "$BUILD_LOG_PATH"
            local plugin
            IFS=',' read -ra PLUGINS_ARRAY <<< "${VARS[EXTRA_PLUGINS]}"
            for plugin in "${PLUGINS_ARRAY[@]}"; do
                plugin=$(echo "$plugin" | xargs)
                if [ -n "$plugin" ]; then
                    echo "CONFIG_PACKAGE_$plugin=y" >> .config
                fi
            done
            make defconfig 2>&1 | tee -a "$BUILD_LOG_PATH" || { 
                echo -e "${RED}make defconfig 失败 (二次插件配置)${NC}" | tee -a "$BUILD_LOG_PATH"
                exit 1
            }
        fi

        run_custom_injections "${VARS[CUSTOM_INJECTIONS]}" "850" "$CURRENT_SOURCE_DIR" # 阶段 850
        
        local download_phase_jobs=$((JOBS_N > 8 ? 8 : JOBS_N))
        echo -e "\n--- ${BLUE}🌐 下载依赖包 (make download -j$download_phase_jobs)${NC} ---" | tee -a "$BUILD_LOG_PATH"
        
        make download -j"$download_phase_jobs" V=s 2>&1 | tee -a "$BUILD_LOG_PATH"
        if [ ${PIPESTATUS[0]} -ne 0 ]; then 
            echo -e "${RED}❌ 下载失败${NC}" | tee -a "$BUILD_LOG_PATH"
            exit 1
        fi
        
        echo -e "\n--- ${BLUE}🚀 开始编译 (make -j$JOBS_N)${NC} ---" | tee -a "$BUILD_LOG_PATH"
        
        /usr/bin/time -f "MAKE_REAL_TIME=%e" make -j"$JOBS_N" V=s 2>&1 | tee -a "$BUILD_LOG_PATH"
        MAKE_RET=$?
        
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
        echo "固件输出目录: $CURRENT_SOURCE_DIR/bin/targets"
    else
        echo -e "${RED}❌ 编译出错 (退出码 $ret)，请查看日志: $BUILD_LOG_PATH${NC}"
        analyze_build_failure "$BUILD_LOG_PATH"
    fi
    read -p "按回车返回主菜单..."
    return $ret
}

# --- 5. 菜单与配置管理函数 ---

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
        local summary=$(get_config_summary "$fn")
        echo "$i) ${GREEN}$fn${NC} ($summary)"
        files[i]="$fn"; i=$((i+1))
    done
    echo "-----------------------------------------------------"
    
    read -p "请选择配置序号 [1-$((i-1))]: " c
    if [[ "$c" =~ ^[0-9]+$ ]] && [ "$c" -ge 1 ] && [ "$c" -lt "$i" ]; then
        echo "${files[$c]}"
        return 0
    fi
    return 1
}

# 1) 新建机型配置 (已修复)
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
    
    echo -e "\n${YELLOW}额外插件提示: 逗号分隔的 OpenWrt 包名 (默认: none)${NC}"
    read -p "额外插件 (EXTRA_PLUGINS): " extra_plugins
    if [[ -z "$extra_plugins" ]]; then extra_plugins="none"; fi

    echo -e "${YELLOW}脚本注入提示: 描述性文字 (默认: none)${NC}"
    read -p "自定义脚本注入 (CUSTOM_INJECTIONS): " custom_injections
    if [[ -z "$custom_injections" ]]; then custom_injections="none"; fi

    read -p "是否启用 QModem (y/n, 默认n): " qmodem_choice
    local enable_qmodem="n"
    if [[ "$qmodem_choice" =~ ^[Yy]$ ]]; then enable_qmodem="y"; fi

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
    fi
    read -p "按回车返回..."
}

# 菜单式编辑配置 (已修复)
manage_config_vars_menu() {
    local config_name="$1"
    local config_file="$CONFIGS_DIR/$config_name.conf"
    
    declare -A VARS
    if ! load_config_vars "$config_name" VARS; then 
        read -p "配置加载失败，按回车返回..."
        return
    fi
    
    while true; do
        clear
        echo -e "====================================================="
        echo -e "   📝 编辑配置: ${GREEN}$config_name${NC}"
        echo -e "====================================================="
        
        local qmodem_status="[${RED}N${NC}]"
        if [[ "${VARS[ENABLE_QMODEM]}" == "y" ]]; then qmodem_status="[${GREEN}Y${NC}]"; fi
        
        echo "1. 固件类型/分支: ${VARS[FW_TYPE]} / ${VARS[FW_BRANCH]}"
        echo "2. 仓库 URL: ${VARS[REPO_URL]}"
        echo "3. 配置 (.config) 文件名: ${VARS[CONFIG_FILE_NAME]}"
        echo "4. 🧩 额外插件列表: ${VARS[EXTRA_PLUGINS]}"
        echo "5. ⚙️ 脚本注入描述: ${VARS[CUSTOM_INJECTIONS]}"
        echo "6. $qmodem_status 内置 Qmodem"
        echo "7. ⚙️ 编辑关联的 .config 文件"
        echo "S) 保存并返回 | R) 返回 (不保存) | D) 删除此配置"
        echo "-----------------------------------------------------"
        
        read -p "请选择要修改的项 (1-7, S/R/D): " edit_choice
        
        case $edit_choice in
            1) 
                read -p "新类型 (i: immortalwrt, o: openwrt, 当前 ${VARS[FW_TYPE]}): " new_type_choice
                if [[ "$new_type_choice" =~ ^[Ii]$ ]]; then VARS[FW_TYPE]="immortalwrt"; fi
                if [[ "$new_type_choice" =~ ^[Oo]$ ]]; then VARS[FW_TYPE]="openwrt"; fi
                read -p "新分支名称 (当前 ${VARS[FW_BRANCH]}): " new_branch_input
                VARS[FW_BRANCH]="${new_branch_input:-${VARS[FW_BRANCH]}}"
                ;;
            2)
                read -p "新仓库 URL (当前 ${VARS[REPO_URL]}): " new_repo_url
                VARS[REPO_URL]="${new_repo_url:-${VARS[REPO_URL]}}"
                ;;
            3)
                read -p "新 .config 文件名 (当前 ${VARS[CONFIG_FILE_NAME]}): " new_cfg_file
                VARS[CONFIG_FILE_NAME]="${new_cfg_file:-${VARS[CONFIG_FILE_NAME]}}"
                ;;
            4)
                echo -e "${YELLOW}当前插件列表 (逗号分隔的包名，或 'none'): ${VARS[EXTRA_PLUGINS]}${NC}"
                read -p "输入新的插件列表: " new_plugins
                VARS[EXTRA_PLUGINS]="${new_plugins:-${VARS[EXTRA_PLUGINS]}}"
                ;;
            5)
                echo -e "${YELLOW}当前注入描述 (例如: custom_repo,patch1,none): ${VARS[CUSTOM_INJECTIONS]}${NC}"
                read -p "输入新的注入描述: " new_injections
                VARS[CUSTOM_INJECTIONS]="${new_injections:-${VARS[CUSTOM_INJECTIONS]}}"
                ;;
            6)
                read -p "启用 Qmodem (y/n, 当前 ${VARS[ENABLE_QMODEM]}): " new_qmodem_choice
                if [[ "$new_qmodem_choice" =~ ^[Yy]$ ]]; then VARS[ENABLE_QMODEM]="y"; fi
                if [[ "$new_qmodem_choice" =~ ^[Nn]$ ]]; then VARS[ENABLE_QMODEM]="n"; fi
                ;;
            7) 
                local cfg_path="$USER_CONFIG_DIR/${VARS[CONFIG_FILE_NAME]}"
                if command -v nano &> /dev/null; then
                    touch "$cfg_path"
                    nano "$cfg_path"
                    generate_config_signature "$cfg_path"
                    echo -e "${GREEN}✅ .config 文件已更新签名。${NC}"
                else
                    echo -e "${RED}未找到 nano，请手动编辑: $cfg_path${NC}"
                fi
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
                echo -e "${YELLOW}返回主菜单，未保存任何更改。${NC}"; return 0
                ;;
            D|d)
                read -p "${RED}警告：确认删除配置 $config_name 及其 .conf 文件? (y/n): ${NC}" del_confirm
                if [[ "$del_confirm" =~ ^[Yy]$ ]]; then
                    rm -f "$CONFIGS_DIR/$config_name.conf"
                    read -p "是否同时删除关联的 .config 文件 (${VARS[CONFIG_FILE_NAME]})? (y/n): " del_cfg_confirm
                    if [[ "$del_cfg_confirm" =~ ^[Yy]$ ]]; then
                         rm -f "$USER_CONFIG_DIR/${VARS[CONFIG_FILE_NAME]}"
                         rm -f "$USER_CONFIG_DIR/${VARS[CONFIG_FILE_NAME]}.sig"
                    fi
                    echo -e "${GREEN}✅ 配置 $config_name$ 已删除。${NC}"
                    read -p "按回车返回..."
                    return 0
                fi
                ;;
            *) echo -e "${RED}无效选择。${NC}"; sleep 1 ;;
        esac
    done
}

# 批量编译队列 (已修复)
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
                for q in "${queue[@]}"; do 
                    [[ -n "$q" ]] && {
                        declare -A B_VARS
                        if load_config_vars "$q" B_VARS; then
                            echo -e "\n--- ${BLUE}[批处理] 开始编译 $q${NC} ---"
                            execute_build "$q" B_VARS
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

# 编译缓存智能管理 (已修复)
manage_compile_cache() {
    while true; do
        clear; echo -e "## ${BLUE}🔄 编译缓存智能管理${NC}"
        
        if ! command -v ccache &> /dev/null; then
            echo -e "${RED}❌ CCACHE未安装，跳过缓存管理${NC}"; read -p "按回车返回..."; return
        fi
        
        set_resource_limits > /dev/null 

        local ccache_stats=$(ccache -s 2>/dev/null)
        local hit_rate=$(echo "$ccache_stats" | grep -E "cache hit \(rate\)" | grep -oE "[0-9]+\.[0-9]+%" || echo "0%")
        local cache_size=$(echo "$ccache_stats" | grep -E "cache size" | head -1 | grep -oE "[0-9]+\.[0-9]+ [A-Z]B" || echo "0.0 GB")
        
        echo "当前 CCACHE 状态:"
        echo "  命中率: ${GREEN}$hit_rate${NC}"
        echo "  缓存大小: ${YELLOW}$cache_size${NC} / ${CCACHE_LIMIT}"
        
        echo -e "\n管理选项:"
        echo "1) 显示详细统计"
        echo "2) 清空 CCACHE 缓存"
        echo "3) 调整 CCACHE 大小限制 (当前: $CCACHE_LIMIT)"
        echo "4) 清理源码下载缓存 (\$SRC/dl)"
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
                    ccache -M "$new_size" 
                    CCACHE_LIMIT="$new_size"
                    echo -e "${GREEN}✅ 缓存大小已调整为 $new_size${NC}"
                fi
                sleep 1 ;;
            4)
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

# 编译环境诊断工具 (已修复)
diagnose_build_environment() {
    clear; echo -e "## ${BLUE}🔧 编译环境诊断报告${NC}"
    
    local report_file="$LOG_DIR/environment_diagnosis_$(date +%Y%m%d_%H%M%S).log"
    
    echo "操作系统: $(detect_system)" | tee -a "$report_file"
    echo "CPU核心数: $(nproc)" | tee -a "$report_file"
    local mem_total=$(free -h | grep Mem | awk '{print $2}' 2>/dev/null || echo "N/A")
    echo "内存总量: $mem_total" | tee -a "$report_file"
    
    echo -e "\n磁盘空间信息 (BUILD_ROOT):" | tee -a "$report_file"
    df -h "$BUILD_ROOT" 2>/dev/null | tee -a "$report_file" || echo "无法获取磁盘信息" | tee -a "$report_file"
    
    echo -e "\n编译工具版本:" | tee -a "$report_file"
    local tools=("gcc" "make" "git" "python3" "ccache")
    for tool in "${tools[@]}"; do
        if command -v "$tool" &> /dev/null; then
            local version=$("$tool" --version 2>/dev/null | head -1)
            echo "$tool: $version" | tee -a "$report_file"
        else
            echo -e "${RED}$tool: 未安装${NC}" | tee -a "$report_file"
        fi
    done
    
    echo "诊断报告已保存到: $report_file"
    
    read -p "按任意键继续..."
}

# 导出配置备份 (已修复)
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
    else
        echo -e "${RED}❌ 备份失败，请检查 zip/权限。${NC}"
    fi
    read -p "按回车返回..."
}

# 导入配置备份 (已修复)
import_config_backup() {
    clear; echo -e "## ${BLUE}📥 导入配置备份${NC}"
    read -p "请输入备份文件 (.zip) 的完整路径: " zip_path
    
    if [[ ! -f "$zip_path" ]]; then
        echo -e "${RED}❌ 错误：文件不存在或路径错误。${NC}"; read -p "按回车返回..."
        return
    fi
    
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

# 维护和诊断菜单 (将复杂功能隔离)
maintenance_menu() {
    while true; do
        clear; echo -e "## ${BLUE}🛠️ 维护与诊断中心${NC}"
        echo "1) 🔬 编译环境诊断报告"
        echo "2) 📊 CCACHE 及缓存管理"
        echo "3) 📤 导出配置备份"
        echo "4) 📥 导入配置备份"
        echo "R) 返回主菜单"
        
        read -p "选择操作: " m_choice
        
        case $m_choice in
            1) diagnose_build_environment ;;
            2) manage_compile_cache ;;
            3) export_config_backup ;;
            4) import_config_backup ;;
            R|r) return ;;
            *) echo -e "${RED}无效选择。${NC}"; sleep 1 ;;
        esac
    done
}

# 主菜单 (V6.0.0 的简洁风格，已修复逻辑 Bug)
main_menu() {
    while true; do
        clear
        echo -e "====================================================="
        echo -e "   🔥 ${GREEN}ImmortalWrt 编译脚本 V${SCRIPT_VERSION}${NC} (稳定版) 🔥"
        echo -e "====================================================="
        show_system_info
        echo -e "-----------------------------------------------------"
        echo "1) 🌟 新建机型配置"
        echo "2) 📝 编辑/删除现有配置"
        echo "3) 🚀 启动编译"
        echo "4) 📦 批量编译队列"
        echo "5) 🛠️ 维护与诊断 (CCACHE, 备份等)"
        echo -e "-----------------------------------------------------"
        
        read -p "请选择功能 (1-5, 0/Q 退出): " choice
        
        case $choice in
            1) create_new_config ;; 
            2) 
                local config_name=$(select_config_from_list)
                [ $? -eq 0 ] && manage_config_vars_menu "$config_name"
                ;;
            3) 
                local config_name=$(select_config_from_list)
                [ $? -eq 0 ] && {
                    declare -A VARS
                    if load_config_vars "$config_name" VARS; then
                         # 签名校验
                         if ! verify_config_signature "$USER_CONFIG_DIR/${VARS[CONFIG_FILE_NAME]}"; then
                            echo -e "${RED}❌ 配置文件签名校验失败，请检查文件是否被篡改。${NC}"
                            read -p "按回车返回主菜单..."
                            continue
                         fi
                         execute_build "$config_name" VARS
                    fi
                }
                ;;
            4) build_queue_menu ;; 
            5) maintenance_menu ;;
            0|Q|q) echo -e "${BLUE}退出脚本。${NC}"; break ;;
            *) echo -e "${RED}无效选择，请重新输入。${NC}"; sleep 1 ;;
        esac
    done
}

# --- 6. 安全退出与陷阱 ---

# 安全退出函数
cleanup_on_exit() {
    echo -e "\n${BLUE}正在清理临时文件...${NC}"
    rm -f /tmp/progress_monitor_*.pipe 2>/dev/null
    rm -f /tmp/*_artifacts_* 2>/dev/null
    rm -rf /tmp/immortalwrt_import_* 2>/dev/null
    
    # 保存ccache统计
    if command -v ccache &> /dev/null; then
        ccache -s > "$LOG_DIR/ccache_stats_$(date +%Y%m%d).log" 2>/dev/null
    fi
    
    echo -e "${GREEN}✅ 清理完成${NC}"
}
# 设置退出陷阱
trap cleanup_on_exit EXIT INT TERM

# --- 脚本入口 ---
set_resource_limits
check_bash_version
check_and_install_dependencies
main_menu
