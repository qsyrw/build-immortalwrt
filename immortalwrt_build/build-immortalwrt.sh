#!/bin/bash

# ==========================================================
# 🔥 ImmortalWrt/OpenWrt 固件编译管理脚本 V6.2.0
# ----------------------------------------------------------
# (高级优化与健壮性增强版)
# ==========================================================

# --- 1. 颜色定义与基础变量 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

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

BUILD_LOG_PATH=""
CONFIG_VAR_NAMES=(FW_TYPE REPO_URL FW_BRANCH CONFIG_FILE_NAME EXTRA_PLUGINS CUSTOM_INJECTIONS ENABLE_QMODEM)

# 动态变量
declare -g CURRENT_SOURCE_DIR=""
declare -g CCACHE_LIMIT="50G" 

# --- 2. 核心辅助函数 ---

# 辅助函数：获取配置文件摘要 (修复 1: 使用更健壮的 sed 提取)
get_config_summary() {
    local config_file_name="$1"
    local config_path="$USER_CONFIG_DIR/$config_file_name"
    
    if [ -f "$config_path" ]; then
        # 修复 1: 使用 sed 确保提取正确，并避免 cut -d'"' 的兼容性问题
        local target=$(grep "^CONFIG_TARGET_BOARD=" "$config_path" | head -1 | sed -n 's/^CONFIG_TARGET_BOARD="\([^"]*\)"/\1/p')
        local subtarget=$(grep "^CONFIG_TARGET_SUBTARGET=" "$config_path" | head -1 | sed -n 's/^CONFIG_TARGET_SUBTARGET="\([^"]*\)"/\1/p')
        
        if [ -n "$target" ]; then
            echo -e "${BLUE}[$target/$subtarget]${NC}"
        else
            if [[ "$config_file_name" == *.diffconfig ]]; then
                echo "[Diff 配置]"
            else
                echo "[未知架构]"
            fi
        fi
    else
        echo -e "${RED}[❌ 文件缺失]${NC}"
    fi
}

# 辅助函数：保存配置 (不变)
save_config_from_array() {
    local config_name="$1"
    local -n vars_array="$2"
    local CONFIG_FILE="$CONFIGS_DIR/$config_name.conf"
    
    > "$CONFIG_FILE"
    
    for key in "${CONFIG_VAR_NAMES[@]}"; do
        if [[ -n "${vars_array[$key]+x}" ]]; then
            echo "$key=\"${vars_array[$key]}\"" >> "$CONFIG_FILE"
        fi
    done
    
    echo -e "${GREEN}✅ 配置已保存到: $CONFIG_FILE${NC}"
    return 0
}

# 辅助函数：删除配置 (不变)
delete_config() {
    local config_name="$1"
    local config_file="$CONFIGS_DIR/$config_name.conf"
    
    if [ -f "$config_file" ]; then
        read -p "确定要删除配置 '$config_name' 吗？(y/n): " confirm
        if [[ "$confirm" == "y" ]]; then
            rm -f "$config_file"
            echo -e "${GREEN}✅ 配置 '$config_name' 已删除。${NC}"
        else
            echo "操作取消。"
        fi
    else
        echo -e "${RED}❌ 配置文件不存在: $config_file${NC}"
    fi
    read -p "按任意键继续..."
}


# --- 3. 初始化与依赖 ---

# 检查并安装编译依赖 (日志轮转优化)
check_and_install_dependencies() {
    # ... (依赖检查逻辑不变)
    
    # 确保目录存在
    mkdir -p "$CONFIGS_DIR" "$LOG_DIR" "$USER_CONFIG_DIR" "$EXTRA_SCRIPT_DIR" "$OUTPUT_DIR" "$CCACHE_DIR"
    
    # 日志轮转改进：保留最近 10 个，并删除 7 天前的
    ls -t "$LOG_DIR"/build_*.log 2>/dev/null | tail -n +11 | xargs rm -f 2>/dev/null
    find "$LOG_DIR" -name "build_*.log" -type f -mtime +7 -delete 2>/dev/null
    
    return 0
}

# CCACHE 状态报告 (不变)
ccache_status() {
    # ... (逻辑不变)
    clear
    echo "## 📊 CCACHE 编译缓存状态"
    echo "缓存目录: $CCACHE_DIR"
    echo "缓存上限: $CCACHE_LIMIT"
    echo "-----------------------------------------------------"
    if command -v ccache &> /dev/null; then
        ccache -s
        read -p "是否清空 CCACHE 缓存？(y/n): " clear_cache
        if [[ "$clear_cache" == "y" ]]; then
            ccache -C
            echo -e "${GREEN}✅ CCACHE 缓存已清空。${NC}"
        fi
    else
        echo -e "${RED}❌ 警告: 未检测到 ccache 命令。${NC}"
    fi
    read -p "按任意键返回主菜单..."
}

# 配置导入/导出功能 (体验优化 3)
export_configs() {
    local backup_dir="$BUILD_ROOT/configs_backup"
    mkdir -p "$backup_dir"
    local backup_file="$backup_dir/configs_backup_$(date +%Y%m%d_%H%M%S).tar.gz"
    
    echo "--- 📦 导出配置 ---"
    tar -czf "$backup_file" -C "$BUILD_ROOT" profiles user_configs custom_scripts --exclude='logs' --exclude='ccache' --exclude='output'
    echo -e "${GREEN}✅ 配置已导出到: $backup_file${NC}"
    read -p "按任意键继续..."
}

import_configs() {
    echo "--- 📥 导入配置 ---"
    read -p "请输入备份文件 (.tar.gz) 路径: " backup_path
    
    if [ ! -f "$backup_path" ]; then
        echo -e "${RED}❌ 文件不存在: $backup_path${NC}"
        read -p "按任意键继续..."
        return
    fi
    
    read -p "警告：这将覆盖当前的配置、用户配置和自定义脚本！确定继续？(y/n): " confirm
    if [[ "$confirm" != "y" ]]; then
        echo "操作取消。"
        return
    fi
    
    # 临时解压，确保结构正确
    local tmp_dir=$(mktemp -d)
    tar -xzf "$backup_path" -C "$tmp_dir"
    
    if [ -d "$tmp_dir/profiles" ]; then
        cp -r "$tmp_dir/"* "$BUILD_ROOT/"
        echo -e "${GREEN}✅ 配置导入成功。${NC}"
    else
        echo -e "${RED}❌ 导入失败：备份文件结构似乎不正确。${NC}"
    fi
    rm -rf "$tmp_dir"
    read -p "按任意键继续..."
}


# --- 4. 菜单与交互 ---

main_menu() {
    check_and_install_dependencies
    if command -v ccache &> /dev/null; then
        ccache -M "$CCACHE_LIMIT" 2>/dev/null
    fi
    
    while true; do
        clear
        echo "====================================================="
        echo "    🔥 ImmortalWrt 固件编译管理脚本 V6.2.0 🔥"
        echo "   (高级优化 | CCACHE: $CCACHE_LIMIT 上限)"
        echo "====================================================="
        echo "1) 🌟 新建机型配置 (Create New Configuration)"
        echo "2) ⚙️ 选择/编辑/删除配置 (Select/Edit/Delete)"
        echo "3) 🚀 编译固件 (Start Build Process)"
        echo "4) 📦 批量编译队列 (Build Queue)"
        echo "5) 📊 CCACHE 状态报告"
        echo "6) 📤 导出配置备份"
        echo "7) 📥 导入配置备份"
        echo "-----------------------------------------------------"
        echo "Q/q) 🚪 快速退出" # 体验优化 2
        read -p "请选择功能 (1-7, Q): " choice
        
        case $choice in
            1) create_config ;;
            2) select_config ;;
            3) start_build_process ;;
            4) build_queue_menu ;;
            5) ccache_status ;;
            6) export_configs ;;
            7) import_configs ;;
            Q|q) echo "退出脚本。再见！"; exit 0 ;; # 体验优化 2
            *) echo -e "${RED}无效选择。${NC}"; sleep 1 ;;
        esac
    done
}


# 3.3 配置交互界面 (GitHub URL转换优化)
config_interaction() {
    # ... (配置加载逻辑不变)
    local CONFIG_NAME="$1"
    local CONFIG_FILE="$CONFIGS_DIR/$CONFIG_NAME.conf"
    
    declare -A config_vars
    if [ -f "$CONFIG_FILE" ]; then
        while read -r line; do
            if [[ "$line" =~ ^([A-Z_]+)=\"(.*)\"$ ]]; then
                local key="${BASH_REMATCH[1]}"
                local value="${BASH_REMATCH[2]}"
                config_vars["$key"]="$value"
            fi
        done < "$CONFIG_FILE"
    fi
    
    : ${config_vars[FW_TYPE]:="immortalwrt"}
    : ${config_vars[REPO_URL]:="https://github.com/immortalwrt/immortalwrt"}
    : ${config_vars[FW_BRANCH]:="master"}
    : ${config_vars[CONFIG_FILE_NAME]:="$CONFIG_NAME.config"}
    
    while true; do
        clear
        echo "====================================================="
        echo "     📝 编辑配置: ${CONFIG_NAME}"
        # ... (菜单显示逻辑不变)
        
        # ... (选项 1 源码修改逻辑)
        case $sub_choice in
            # ... (1/2/3/4/5/6 逻辑不变)
            4) manage_plugins_menu config_vars ;;
            5) manage_injections_menu config_vars ;;
            6) config_vars[ENABLE_QMODEM]=$([[ "${config_vars[ENABLE_QMODEM]}" == "y" ]] && echo "n" || echo "y") ;;
            7) 
                if save_config_from_array "$CONFIG_NAME" config_vars; then
                    if ! clone_or_update_source "${config_vars[REPO_URL]}" "${config_vars[FW_BRANCH]}" "${config_vars[FW_TYPE]}"; then
                        echo -e "${RED}源码更新失败，无法运行 menuconfig。${NC}"
                        sleep 3
                        continue
                    fi
                    run_menuconfig "$CURRENT_SOURCE_DIR" "$USER_CONFIG_DIR/${config_vars[CONFIG_FILE_NAME]}"
                fi
                ;;
            S|s) save_config_from_array "$CONFIG_NAME" config_vars; return ;;
            R|r) return ;;
            *) echo -e "${RED}无效选择。${NC}"; sleep 1 ;;
        esac
    done
}


# --- 5. 编译流程 ---

# 4.3 核心编译执行 (性能优化 2/3, 体验优化 1)
execute_build() {
    local CONFIG_NAME="$1"
    local -n VARS=$2
    
    local FW_TYPE="${VARS[FW_TYPE]}"
    local FW_BRANCH="${VARS[FW_BRANCH]}"
    local REPO_URL="${VARS[REPO_URL]}"
    local CFG_FILE="${VARS[CONFIG_FILE_NAME]}"
    
    local BUILD_TIME_STAMP_FULL=$(date +%Y%m%d_%H%M%S) 
    BUILD_LOG_PATH="$LOG_DIR/build_${CONFIG_NAME}_${BUILD_TIME_STAMP_FULL}.log"

    echo -e "\n=== ${BLUE}🚀 开始编译 [$CONFIG_NAME] (V6.2.0)${NC} ===" | tee -a "$BUILD_LOG_PATH"
    
    # 性能优化 2: 自动调整编译作业数
    local JOBS_N=$(nproc) 
    local TOTAL_MEM_KB=$(grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $2}' || echo 0)
    local MEM_PER_JOB=1500000  # 1.5GB
    
    if [ "$TOTAL_MEM_KB" -gt 0 ] && [ "$TOTAL_MEM_KB" -gt "$MEM_PER_JOB" ]; then
        local MAX_JOBS_BY_MEM=$((TOTAL_MEM_KB / MEM_PER_JOB))
        if [ "$MAX_JOBS_BY_MEM" -lt "$JOBS_N" ]; then
            echo -e "${YELLOW}⚠️  内存限制：从 ${JOBS_N} 作业调整为 ${MAX_JOBS_BY_MEM} 作业${NC}" | tee -a "$BUILD_LOG_PATH"
            JOBS_N="$MAX_JOBS_BY_MEM"
        fi
    fi
    echo "使用 ${JOBS_N} 个编译作业 (make -j${JOBS_N})" | tee -a "$BUILD_LOG_PATH"
    
    # 1. 源码准备
    if ! clone_or_update_source "$REPO_URL" "$FW_BRANCH" "$FW_TYPE"; then
        return 1
    fi
    
    local START_TIME=$(date +%s)
    
    (
        cd "$CURRENT_SOURCE_DIR" || exit 1
        
        # ... (CCACHE 和 PATH 设置不变)

        # 1.5 智能清理/断点续编 (交互颜色优化)
        # ... (清理逻辑不变)
        
        # 2. Feeds & 插件 (安全性增强 1 & 体验优化 1)
        # ... (feeds update/install 逻辑不变)
        
        local plugin_string="${VARS[EXTRA_PLUGINS]}"
        if [[ -n "$plugin_string" ]]; then
            echo -e "\n--- ${BLUE}安装额外插件${NC} ---" | tee -a "$BUILD_LOG_PATH"
            local plugins_array_string=$(echo "$plugin_string" | tr '##' '\n')
            local plugins
            IFS=$'\n' read -rd '' -a plugins <<< "$plugins_array_string"
            for p in "${plugins[@]}"; do 
                [[ -z "$p" ]] && continue
                
                # 安全性增强 1: 简单恶意命令检查
                if [[ "$p" =~ "rm\s+-rf\s+/" || "$p" =~ ":(){:|:&};:" ]]; then
                    echo -e "${RED}❌ 安全警告：跳过潜在危险命令: $p${NC}" | tee -a "$BUILD_LOG_PATH"
                    continue
                fi
                
                echo "执行: $p"
                eval "$p" || echo -e "${YELLOW}警告: 插件命令失败，忽略。${NC}" | tee -a "$BUILD_LOG_PATH"
            done
        fi
        
        # 3. 配置文件处理 (不变)
        # ...
        
        # 4. 后期注入 (阶段 850)
        run_custom_injections "${VARS[CUSTOM_INJECTIONS]}" "850" "$CURRENT_SOURCE_DIR"
        
        # 5. 下载与编译
        local DOWNLOAD_JOBS=$((JOBS_N > 8 ? 8 : JOBS_N)) # 性能优化 1: 限制最大并行下载数
        echo -e "\n--- ${BLUE}🌐 下载依赖包 (make download -j$DOWNLOAD_JOBS)${NC} ---" | tee -a "$BUILD_LOG_PATH"
        make download -j"$DOWNLOAD_JOBS" V=s 2>&1 | tee -a "$BUILD_LOG_PATH"
        if [ ${PIPESTATUS[0]} -ne 0 ]; then
             echo -e "${RED}❌ 下载失败，请检查网络。${NC}" | tee -a "$BUILD_LOG_PATH"
             exit 1
        fi
        
        echo -e "\n--- ${BLUE}🚀 开始编译 (make -j$JOBS_N)${NC} ---" | tee -a "$BUILD_LOG_PATH"
        
        # 进度跟踪 (修复 2: 进度条构建简化)
        local total_targets=$(make -n -j1 V=s 2>/dev/null | grep -c '^make\[.*\]: Entering directory .*package/')
        
        (
            sleep 5 
            local compiled_count=0
            
            if [ "$total_targets" -gt 0 ]; then
                # ... (估算总目标数显示不变)
                
                tail -f "$BUILD_LOG_PATH" 2>/dev/null | while read LINE; do
                    if echo "$LINE" | grep -q "^Built target "; then
                        compiled_count=$((compiled_count + 1))
                        local percentage=$((compiled_count * 100 / total_targets))
                        local bar_length=30
                        local filled=$((percentage * bar_length / 100))
                        local empty=$((bar_length - filled))
                        
                        # 修复 2: 进度条构建简化
                        local progress_bar=""
                        progress_bar=$(printf "%${filled}s" | sed 's/ /=/g')
                        progress_bar+=$(printf "%${empty}s" | sed 's/ /-/g')

                        echo -ne "\r${GREEN}✅ 编译进度: [${progress_bar}] ${percentage}% (${compiled_count}/${total_targets})${NC}" >&2
                    fi
                    
                    if echo "$LINE" | grep -q "make\[.*\]: Leaving directory"; then break; fi
                done
                echo "" >&2 
            fi
        ) &
        PROGRESS_PID=$!

        # 执行编译
        /usr/bin/time -f "MAKE_REAL_TIME=%e" make -j"$JOBS_N" V=s 2>&1 | tee -a "$BUILD_LOG_PATH"
        
        # 停止后台进度监控进程
        kill $PROGRESS_PID 2>/dev/null
        wait $PROGRESS_PID 2>/dev/null 
        echo "--- ⏱️ 跟踪结束 ---" | tee -a "$BUILD_LOG_PATH"

        # ... (成功/失败处理)
        if [ ${PIPESTATUS[0]} -eq 0 ]; then
            # ... (耗时计算不变)
            echo -e "\n${GREEN}✅ 编译成功！总耗时: $DURATION_STR${NC}" | tee -a "$BUILD_LOG_PATH"
            # ... (归档逻辑不变)
            exit 0
        else
            echo -e "\n${RED}❌ 编译失败${NC}" | tee -a "$BUILD_LOG_PATH"
            exit 1
        fi
    )
    
    local ret=$?
    if [ $ret -ne 0 ]; then
        echo -e "${RED}请查看日志: $BUILD_LOG_PATH${NC}"
        read -p "编译出错。按回车返回..."
    else
        read -p "编译完成。按回车返回..."
    fi
}

# 批量编译菜单 (健壮性增强 4)
build_queue_menu() {
    clear; echo "## ${BLUE}📦 批量编译队列${NC}"
    # ... (列表显示逻辑不变)
    
    while true; do
        # ... (菜单显示逻辑不变)
        
        read -p "选择: " c
        case $c in
            A|a) read -p "序号: " x; local n="${files[$x]}"; 
                 if [[ " ${queue[*]} " =~ " ${n} " ]]; then 
                    # 健壮性增强 4: 使用 grep -v 确保删除
                    queue=($(printf "%s\n" "${queue[@]}" | grep -v "^${n}$"))
                 else queue+=("$n"); fi ;;
            S|s) 
                 # ... (校验逻辑不变)
                 for q in "${queue[@]}"; do [[ -n "$q" ]] && {
                     # ... (变量加载逻辑不变)
                     execute_build "$q" B_VARS
                 }; done; read -p "批处理结束。" ;;
            R|r) return ;;
            *) echo -e "${RED}无效选择。${NC}"; sleep 1 ;;
        esac
    done
}


# --- 6. 验证与管理 ---

# 3.8 配置校验 (安全性增强 2)
validate_build_config() {
    local -n VARS=$1
    local config_name="$2"
    local error_count=0
    
    echo -e "\n--- ${BLUE}🔍 验证配置: $config_name${NC} ---"
    
    local config_path="$USER_CONFIG_DIR/${VARS[CONFIG_FILE_NAME]}"
    if [[ ! -f "$config_path" ]]; then
        echo -e "${RED}❌ 错误：找不到配置文件: $config_path${NC}"
        error_count=$((error_count + 1))
    else
        # 安全性增强 2: 检查配置文件是否包含恶意代码
        if grep -q "eval.*base64_decode\|wget.*http://.*sh\|curl.*http://.*sh" "$config_path" 2>/dev/null; then
            echo -e "${RED}⚠️  警告：配置文件中检测到可疑命令！${NC}"
            error_count=$((error_count + 1))
        fi
        # ... (其他检查逻辑不变)
    fi
    
    # ... (脚本注入检查逻辑不变)

    if [ "$error_count" -gt 0 ]; then
        echo -e "${RED}🚨 发现 $error_count 个严重错误，无法继续。${NC}"
        return 1
    fi
    echo -e "${GREEN}✅ 配置校验通过。${NC}"
    return 0
}

# 辅助模块 (Plugins/Injections)
manage_injections_menu() {
    local -n vars_array=$1
    # ... (菜单显示逻辑不变)
    
    case $choice in
        # ... (A/a, D/d 逻辑不变)
        U|u)
            read -p "输入 URL: " url
            if [[ -z "$url" ]]; then return; fi
            
            # 安全性增强 3: GitHub URL 转换优化
            if [[ "$url" =~ github.com.*blob ]]; then
                # 转换包含 /blob/ 的链接
                url=$(echo "$url" | sed 's|github.com|raw.githubusercontent.com|; s|/blob/|/|')
                echo -e "${YELLOW}转换为 Raw URL: $url${NC}"
            elif [[ "$url" =~ github.com ]] && [[ ! "$url" =~ raw.githubusercontent.com ]]; then
                echo -e "${YELLOW}⚠️  警告：检测到非 Raw GitHub URL，请确认是否需要手动转换。${NC}"
            fi
            
            local fname=$(basename "$url")
            curl -sSL "$url" -o "$EXTRA_SCRIPT_DIR/$fname" && echo -e "${GREEN}✅ 下载成功${NC}" || echo -e "${RED}❌ 失败${NC}"
            read -p "执行阶段 (100/850): " stage
            local new="$fname $stage"
            if [[ -z "$current" ]]; then vars_array[CUSTOM_INJECTIONS]="$new"; else vars_array[CUSTOM_INJECTIONS]="${current}##${new}"; fi
            ;;
        R|r) return ;;
        *) echo -e "${RED}无效选择。${NC}"; sleep 1 ;;
    esac
    # ...
}

# ... (其他函数不变)

# --- 脚本入口 ---
check_and_install_dependencies
main_menu
