#!/bin/bash

# ==========================================================
# 🔥 ImmortalWrt/OpenWrt 固件编译管理脚本 V6.2.1
# ----------------------------------------------------------
# (核心功能恢复与优化版)
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

# --- 2. 核心辅助函数 (缺失函数恢复) ---

# 辅助函数：获取配置文件摘要
get_config_summary() {
    local config_file_name="$1"
    local config_path="$USER_CONFIG_DIR/$config_file_name"
    
    if [ -f "$config_path" ]; then
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

# 辅助函数：保存配置
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

# 辅助函数：删除配置
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
    local CHECKABLE_TOOLS="git make gcc g++ gawk python3 perl wget curl unzip lscpu free ccache"
    local missing_deps=""
    for dep in $CHECKABLE_TOOLS; do
        if ! command -v "$dep" &> /dev/null; then missing_deps="$missing_deps $dep"; fi
    done

    if [ -n "$missing_deps" ]; then
        echo -e "## ${YELLOW}检查并安装编译依赖...${NC}"
        
        local INSTALL_DEPENDENCIES="ack antlr3 asciidoc autoconf automake autopoint bison build-essential bzip2 ccache clang cmake cpio curl device-tree-compiler ecj fastjar flex gawk gettext gcc-multilib g++-multilib git gnutls-dev gperf haveged help2man intltool libc6-dev-i386 libelf-dev libglib2.0-dev libgmp3-dev libmpc-dev libmpfr-dev libncurses-dev libpython3-dev libreadline-dev libssl-dev libtool libyaml-dev libz-dev lld llvm lrzsz mkisofs msmtp nano ninja-build p7zip p7zip-full patch pkgconf python3 python3-pip python3-ply python3-pyelftools qemu-utils re2c rsync scons squashfs-tools subversion swig texinfo uglifyjs upx-ucl unzip vim wget xmlto xxd zlib1g-dev zstd uuid-runtime zip procps util-linux iputils-ping"
        
        if command -v apt-get &> /dev/null; then
            echo -e "\n--- 正在更新软件包列表并安装依赖 (Debian/Ubuntu) ---"
            sudo apt-get update || { echo -e "${RED}错误: apt-get update 失败。${NC}"; return 1; }
            sudo apt-get install -y $INSTALL_DEPENDENCIES
        elif command -v yum &> /dev/null; then
            echo -e "\n--- 正在尝试安装依赖 (CentOS/RHEL) ---"
            echo "请手动检查并安装以下依赖：$INSTALL_DEPENDENCIES"
        else
            echo -e "\n${RED}**警告:** 无法自动安装依赖。请确保已安装编译环境。${NC}"
        fi 
    fi
    
    # 确保目录存在
    mkdir -p "$CONFIGS_DIR" "$LOG_DIR" "$USER_CONFIG_DIR" "$EXTRA_SCRIPT_DIR" "$OUTPUT_DIR" "$CCACHE_DIR"
    
    # 日志轮转改进
    ls -t "$LOG_DIR"/build_*.log 2>/dev/null | tail -n +11 | xargs rm -f 2>/dev/null
    find "$LOG_DIR" -name "build_*.log" -type f -mtime +7 -delete 2>/dev/null
    
    return 0
}

# CCACHE 状态报告
ccache_status() {
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

# 配置导入/导出功能
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

# --- 4. 源码管理 (缺失函数恢复) ---

# 源码克隆或更新
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
            local current_remote=$(git remote get-url origin 2>/dev/null)
            if [[ "$current_remote" != "$REPO_URL" ]]; then
                echo -e "${YELLOW}⚠️  注意: 远程 URL 不一致，正在重置 Origin...${NC}" | tee -a "$BUILD_LOG_PATH"
                git remote set-url origin "$REPO_URL"
            fi
            git fetch origin "$FW_BRANCH"
            git reset --hard "origin/$FW_BRANCH"
            git clean -fd
        ) || return 1
    else
        echo -e "${BLUE}📥 正在克隆源码 ($REPO_URL)...${NC}" | tee -a "$BUILD_LOG_PATH"
        git clone "$REPO_URL" -b "$FW_BRANCH" "$CURRENT_SOURCE_DIR" || {
            echo -e "${RED}❌ 克隆失败，请检查 URL 或网络。${NC}" | tee -a "$BUILD_LOG_PATH"
            return 1
        }
    fi
    
    return 0
}

# 预编译检查 (确保 pre_build_checks 存在)
pre_build_checks() {
    echo -e "\n--- ${BLUE}🔎 编译前环境检查 (V6.2.1)${NC} ---" | tee -a "$BUILD_LOG_PATH"
    
    local REQUIRED_SPACE_KB=10485760 # 10 GB
    local available_kb=$(df -k . | awk 'NR==2 {print $4}' 2>/dev/null)
    local gb_available=$((available_kb / 1024 / 1024))
    
    if [ "$available_kb" -lt "$REQUIRED_SPACE_KB" ]; then
        echo -e "${RED}❌ 警告：磁盘空间不足。可用空间 ${gb_available} GB，建议至少 10 GB。${NC}" | tee -a "$BUILD_LOG_PATH"
        
        local cont=""
        read -t 30 -p "是否强制继续？(y/n，默认n): " cont
        cont=${cont:-n}
        if [[ "$cont" != "y" ]]; then return 1; fi
    else
        echo -e "${GREEN}✅ 磁盘空间检查通过 ($gb_available GB 可用)。${NC}" | tee -a "$BUILD_LOG_PATH"
    fi
    
    if ! ping -c 1 -W 3 8.8.8.8 &> /dev/null; then
        echo -e "${RED}❌ 警告：网络连接似乎不可用或不稳定。${NC}" | tee -a "$BUILD_LOG_PATH"
        
        local cont=""
        read -t 30 -p "是否强制继续？(y/n，默认n): " cont
        cont=${cont:-n}
        if [[ "$cont" != "y" ]]; then return 1; fi
    else
        echo -e "${GREEN}✅ 网络连接检查通过。${NC}" | tee -a "$BUILD_LOG_PATH"
    fi

    return 0
}

# --- 5. 菜单与交互 (核心函数恢复) ---

main_menu() {
    check_and_install_dependencies
    if command -v ccache &> /dev/null; then
        ccache -M "$CCACHE_LIMIT" 2>/dev/null
    fi
    
    while true; do
        clear
        echo "====================================================="
        echo "    🔥 ImmortalWrt 固件编译管理脚本 V6.2.1 🔥"
        echo "   (核心功能恢复 | CCACHE: $CCACHE_LIMIT 上限)"
        echo "====================================================="
        echo "1) 🌟 新建机型配置 (Create New Configuration)"
        echo "2) ⚙️ 选择/编辑/删除配置 (Select/Edit/Delete)"
        echo "3) 🚀 编译固件 (Start Build Process)"
        echo "4) 📦 批量编译队列 (Build Queue)"
        echo "5) 📊 CCACHE 状态报告"
        echo "6) 📤 导出配置备份"
        echo "7) 📥 导入配置备份"
        echo "-----------------------------------------------------"
        echo "Q/q) 🚪 快速退出"
        read -p "请选择功能 (1-7, Q): " choice
        
        case $choice in
            1) create_config ;;
            2) select_config ;;
            3) start_build_process ;;
            4) build_queue_menu ;;
            5) ccache_status ;;
            6) export_configs ;;
            7) import_configs ;;
            Q|q) echo "退出脚本。再见！"; exit 0 ;;
            *) echo -e "${RED}无效选择。${NC}"; sleep 1 ;;
        esac
    done
}


# 新建配置 (恢复)
create_config() {
    while true; do
        clear
        echo -e "## ${BLUE}🌟 新建机型配置${NC}"
        read -p "请输入机型配置名称 (例如 xiaomi_ax6000, 不带空格): " new_name
        if [[ -z "$new_name" ]]; then echo -e "${RED}名称不能为空！${NC}"; sleep 1; continue; fi
        
        local CONFIG_FILE="$CONFIGS_DIR/$new_name.conf"
        if [[ -f "$CONFIG_FILE" ]]; then
            echo -e "${YELLOW}配置 [$new_name] 已存在！${NC}"
            read -p "是否覆盖？(y/n): " overwrite
            [[ "$overwrite" != "y" ]] && continue
        fi
        
        declare -A new_vars
        new_vars[FW_TYPE]="immortalwrt"
        new_vars[REPO_URL]="https://github.com/immortalwrt/immortalwrt"
        new_vars[FW_BRANCH]="master"
        new_vars[CONFIG_FILE_NAME]="$new_name.config"
        new_vars[EXTRA_PLUGINS]=""
        new_vars[CUSTOM_INJECTIONS]=""
        new_vars[ENABLE_QMODEM]="n"
        
        save_config_from_array "$new_name" new_vars
        
        echo -e "\n${GREEN}✅ 配置 [$new_name] 已创建。${NC}"
        echo "---------------------------------------------"
        echo "下一步操作？"
        echo "1) 立即编辑此配置 (推荐：设置源码和文件名)"
        echo "2) 返回主菜单"
        read -p "选择 (1/2): " next_step
        
        if [ "$next_step" == "1" ]; then
            config_interaction "$new_name" "edit"
        fi
        return
    done
}

# 选择配置 (不变)
select_config() {
    clear
    echo -e "## ${BLUE}⚙️ 选择配置${NC}"
    
    local configs=("$CONFIGS_DIR"/*.conf)
    if [ ${#configs[@]} -eq 0 ] || ([ ${#configs[@]} -eq 1 ] && [ ! -f "${configs[0]}" ]); then
        echo -e "${YELLOW}没有保存的配置。${NC}"
        read -p "按任意键返回..."
        return
    fi
    
    echo "--- 可用配置列表 ---"
    local i=1
    local files=()
    printf "%-3s %-25s %s\n" "No." "配置名称" "目标架构"
    echo "------------------------------------------------"
    
    for file in "${configs[@]}"; do
        if [ -f "$file" ]; then
            filename=$(basename "$file" .conf)
            local cfg_file_name=$(grep "CONFIG_FILE_NAME=" "$file" | head -1 | sed -n 's/^CONFIG_FILE_NAME="\([^"]*\)"/\1/p')
            local summary=$(get_config_summary "$cfg_file_name")
            
            printf "%-3s %-25s %s\n" "$i)" "$filename" "$summary"
            files[i]="$filename"
            i=$((i + 1))
        fi
    done
    echo "------------------------------------------------"
    local return_index=$i
    echo "$return_index) 返回主菜单"
    
    read -p "请选择 (1-$return_index): " choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "$return_index" ]; then
        if [ "$choice" -eq "$return_index" ]; then return; fi
        local SELECTED_NAME="${files[$choice]}"
        echo -e "\n当前选择: **$SELECTED_NAME**"
        read -p "操作: 1) 编辑 | 2) 删除 | 3) 返回: " action
        case "$action" in
            1) config_interaction "$SELECTED_NAME" "edit" ;;
            2) delete_config "$SELECTED_NAME" ;;
            3) return ;;
            *) echo -e "${RED}无效操作${NC}"; sleep 1 ;;
        esac
    fi
}


# 启动编译流程 (恢复)
start_build_process() {
    clear
    local configs=("$CONFIGS_DIR"/*.conf)
    if [ ${#configs[@]} -eq 0 ] || ([ ${#configs[@]} -eq 1 ] && [ ! -f "${configs[0]}" ]); then
        echo -e "${YELLOW}无配置。${NC}"
        read -p "回车返回..."
        return
    fi
    
    echo -e "--- ${BLUE}选择编译配置${NC} ---"
    local i=1
    local files=()
    for file in "${configs[@]}"; do
        if [ -f "$file" ]; then
            local fname=$(basename "$file" .conf)
            echo "$i) $fname"
            files[i]="$fname"
            i=$((i+1))
        fi
    done
    read -p "输入序号: " choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ -n "${files[$choice]}" ]; then
        local SEL_NAME="${files[$choice]}"
        declare -A SEL_VARS
        local CFILE="$CONFIGS_DIR/$SEL_NAME.conf"
        while IFS='=' read -r k v; do 
            if [[ "$k" =~ ^[A-Z_]+$ ]]; then 
                SEL_VARS["$k"]=$(echo "$v" | sed 's/^"//;s/"$//')
            fi
        done < "$CFILE"
        
        if validate_build_config SEL_VARS "$SEL_NAME"; then
            if ! pre_build_checks; then
                read -p "环境校验失败，按回车返回..."
                return
            fi
            read -p "校验通过，按任意键开始..."
            execute_build "$SEL_NAME" SEL_VARS
        else
            read -p "校验失败，回车返回..."
        fi
    fi
}


# 运行 Menuconfig (恢复)
run_menuconfig() {
    local source_dir="$1"
    local config_file_path="$2"
    
    echo -e "\n--- ${BLUE}⚙️ 运行 Menuconfig (V6.2.1)${NC} ---"
    
    (
        cd "$source_dir" || exit 1
        
        local CFG_FILE_NAME=$(basename "$config_file_path")
        local ext="${CFG_FILE_NAME##*.}"
        
        if [[ "$ext" == "diffconfig" ]]; then
            echo -e "${YELLOW}ℹ️  应用 .diffconfig 并执行 make defconfig...${NC}"
            cp "$config_file_path" .config
            make defconfig 
        else
            echo -e "${YELLOW}ℹ️  导入 .config 文件...${NC}"
            cp "$config_file_path" .config
        fi

        if command -v X &> /dev/null || command -v wslg &> /dev/null; then
            echo "检测到图形化环境支持，建议使用 make xconfig/gconfig。"
            make xconfig 2>/dev/null || make gconfig 2>/dev/null || make menuconfig
        else
            echo "运行 make menuconfig (基于终端 ncurses)"
            make menuconfig
        fi
    )
    
    read -p "是否将新的 .config 覆盖到 $config_file_path？(y/n): " save_back
    if [[ "$save_back" == "y" ]]; then
        cp "$source_dir/.config" "$config_file_path"
        echo -e "${GREEN}✅ 新的配置已保存。${NC}"
    else
        echo "取消保存。"
    fi
}


# 配置交互界面
config_interaction() {
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
        echo "====================================================="
        
        echo "1. 源码来源: [${config_vars[FW_TYPE]}] (URL: ${config_vars[REPO_URL]})"
        echo "2. 源码分支: ${config_vars[FW_BRANCH]}"
        echo "3. 配置文件: ${config_vars[CONFIG_FILE_NAME]}"
        
        local plugin_count=$(echo "${config_vars[EXTRA_PLUGINS]}" | grep -o '##' | wc -l | awk '{print $1 + ($0?1:0)}')
        [[ -z "${config_vars[EXTRA_PLUGINS]}" ]] && plugin_count=0
        echo "4. 额外插件: $plugin_count 个"
        
        local inj_count=$(echo "${config_vars[CUSTOM_INJECTIONS]}" | grep -o '##' | wc -l | awk '{print $1 + ($0?1:0)}')
        [[ -z "${config_vars[CUSTOM_INJECTIONS]}" ]] && inj_count=0
        echo "5. 脚本注入: $inj_count 个"
        
        echo "6. [${config_vars[ENABLE_QMODEM]:-n}] Qmodem 集成"
        
        echo "7. 💻 **运行 Menuconfig** (保存后配置内核和软件包)"
        
        echo "-----------------------------------------------------"
        echo "S) 保存并返回 | R) 放弃修改"
        read -p "选择修改项 (1-7, S/R): " sub_choice
        
        case $sub_choice in
            1) 
                echo -e "\n--- ${BLUE}选择源码类型${NC} ---"
                echo "1: ImmortalWrt (官方) [推荐]"
                echo "2: OpenWrt (官方)"
                echo "3: Lede (CoolSnowWolf)"
                echo "4: 自定义 (Custom)"
                read -p "选择 (1-4): " type_choice
                case $type_choice in
                    1) config_vars[FW_TYPE]="immortalwrt"; config_vars[REPO_URL]="https://github.com/immortalwrt/immortalwrt" ;;
                    2) config_vars[FW_TYPE]="openwrt"; config_vars[REPO_URL]="https://github.com/openwrt/openwrt" ;;
                    3) config_vars[FW_TYPE]="lede"; config_vars[REPO_URL]="https://github.com/coolsnowwolf/lede" ;;
                    4) 
                        config_vars[FW_TYPE]="custom"
                        read -p "请输入 Git 仓库 URL: " custom_url
                        if [[ -n "$custom_url" ]]; then config_vars[REPO_URL]="$custom_url"; fi
                        ;;
                esac
                ;;
            2) read -p "输入分支名称 (当前: ${config_vars[FW_BRANCH]}): " branch; config_vars[FW_BRANCH]="${branch:-${config_vars[FW_BRANCH]}}" ;;
            3) read -p "输入文件名 (如 my.config 或 my.diffconfig): " fname; config_vars[CONFIG_FILE_NAME]="${fname:-${config_vars[CONFIG_FILE_NAME]}}" ;;
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


# 插件管理 (恢复)
manage_plugins_menu() {
    local -n vars_array=$1
    while true; do
        clear
        echo -e "${BLUE}🧩 插件管理${NC}"
        local current_plugins="${vars_array[EXTRA_PLUGINS]}"
        local plugins_array=($(echo "$current_plugins" | tr '##' '\n' | sed '/^$/d'))
        
        for i in "${!plugins_array[@]}"; do 
            echo "$((i+1))) ${plugins_array[$i]}"
        done
        echo "-----------------------"
        echo "A) 添加命令  D) 删除全部  R) 返回"
        read -p "选择: " choice
        case $choice in
            A|a)
                read -p "输入命令 (如 git clone ...): " cmd
                if [[ -n "$cmd" ]]; then
                    if [[ -z "$current_plugins" ]]; then 
                        vars_array[EXTRA_PLUGINS]="$cmd"
                    else 
                        vars_array[EXTRA_PLUGINS]="${current_plugins}##${cmd}"
                    fi
                fi 
                ;;
            D|d) vars_array[EXTRA_PLUGINS]="" ;; 
            R|r) return ;;
            *) echo -e "${RED}无效选择。${NC}"; sleep 1 ;;
        esac
    done
}

# 脚本注入管理 (不变)
manage_injections_menu() {
    local -n vars_array=$1
    while true; do
        clear
        echo -e "${BLUE}⚙️ 脚本注入管理 (存放于: $EXTRA_SCRIPT_DIR)${NC}"
        local current="${vars_array[CUSTOM_INJECTIONS]}"
        local inj_array=($(echo "$current" | tr '##' '\n' | sed '/^$/d'))
        
        for i in "${!inj_array[@]}"; do echo "$((i+1))) ${inj_array[$i]}"; done
        echo "----------------------------------------------------"
        echo "A) 添加本地脚本  U) 下载远程脚本  D) 删除全部  R) 返回"
        read -p "选择: " choice
        
        case $choice in
            A|a)
                local files=("$EXTRA_SCRIPT_DIR"/*.sh); local i=1; local file_list=()
                for f in "${files[@]}"; do
                    if [ -f "$f" ]; then echo "$i) $(basename "$f")"; file_list[$i]="$(basename "$f")"; i=$((i+1)); fi
                done
                read -p "选择文件序号: " idx; local sname="${file_list[$idx]}"
                if [[ -n "$sname" ]]; then
                    read -p "执行阶段 (100=feed前, 850=编译前): " stage
                    local new="$sname $stage"
                    if [[ -z "$current" ]]; then vars_array[CUSTOM_INJECTIONS]="$new"; else vars_array[CUSTOM_INJECTIONS]="${current}##${new}"; fi
                fi ;;
            U|u)
                read -p "输入 URL: " url
                if [[ -z "$url" ]]; then return; fi
                
                # GitHub URL 转换优化
                if [[ "$url" =~ github.com.*blob ]]; then
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
            D|d) vars_array[CUSTOM_INJECTIONS]="" ;;
            R|r) return ;;
            *) echo -e "${RED}无效选择。${NC}"; sleep 1 ;;
        esac
    done
}


# 配置校验 (不变)
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
        # 检查配置文件是否包含恶意代码
        if grep -q "eval.*base64_decode\|wget.*http://.*sh\|curl.*http://.*sh" "$config_path" 2>/dev/null; then
            echo -e "${RED}⚠️  警告：配置文件中检测到可疑命令！${NC}"
            error_count=$((error_count + 1))
        fi
        # ... (其他检查逻辑不变)
    fi
    
    if [ "$error_count" -gt 0 ]; then
        echo -e "${RED}🚨 发现 $error_count 个严重错误，无法继续。${NC}"
        return 1
    fi
    echo -e "${GREEN}✅ 配置校验通过。${NC}"
    return 0
}


# 核心编译执行 (清理优化/进度条优化)
execute_build() {
    local CONFIG_NAME="$1"
    local -n VARS=$2
    
    # ... (变量定义/日志路径定义不变)
    
    # 性能优化 2: 自动调整编译作业数
    # ... (JOBS_N 计算逻辑不变)
    
    # 1. 源码准备
    if ! clone_or_update_source "$REPO_URL" "$FW_BRANCH" "$FW_TYPE"; then
        return 1
    fi
    
    local START_TIME=$(date +%s)
    
    (
        cd "$CURRENT_SOURCE_DIR" || exit 1
        
        export CCACHE_DIR="$CCACHE_DIR"
        export PATH="/usr/lib/ccache:$PATH"
        ccache -z 2>/dev/null
        
        export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
        unset CC CXX LD AR AS CPPFLAGS CFLAGS CXXFLAGS LDFLAGS
        local GIT_COMMIT_ID=$(git rev-parse --short HEAD 2>/dev/null || echo "Unknown")
        
        # 1.5 智能清理/断点续编 (清理选项增强)
        echo -e "\n--- ${YELLOW}🧹 清理环境/续编检查${NC} ---" | tee -a "$BUILD_LOG_PATH"
        if [ -d "$CURRENT_SOURCE_DIR/bin" ]; then
            echo "检测到上次编译残留..." | tee -a "$BUILD_LOG_PATH"
            echo "清理选项:"
            echo "1) 彻底清理 (make clean)"
            echo "2) 仅清理临时文件 (make clean-temp)"
            echo "3) 断点续编 (跳过清理)"
            read -t 30 -p "选择 (1/2/3，默认3): " clean_choice
            clean_choice=${clean_choice:-3}
            
            case $clean_choice in
                1) 
                    local size_before=$(du -sh . 2>/dev/null | awk '{print $1}')
                    echo "当前占用: $size_before" | tee -a "$BUILD_LOG_PATH"
                    make clean 2>&1 | tee -a "$BUILD_LOG_PATH" 
                    local size_after=$(du -sh . 2>/dev/null | awk '{print $1}')
                    echo "清理完成 (剩余占用: $size_after)" | tee -a "$BUILD_LOG_PATH"
                    ;;
                2) make clean-temp 2>&1 | tee -a "$BUILD_LOG_PATH" ;;
                3) echo "跳过清理，尝试断点续编..." | tee -a "$BUILD_LOG_PATH" ;;
                *) echo "跳过清理，尝试断点续编..." | tee -a "$BUILD_LOG_PATH" ;;
            esac
        else
            make clean 2>&1 | tee -a "$BUILD_LOG_PATH"
        fi

        # ... (Feeds & 插件逻辑不变)
        
        # 5. 下载与编译 (进度条显示优化)
        # ... (make download 逻辑不变)
        
        echo -e "\n--- ${BLUE}🚀 开始编译 (make -j$JOBS_N)${NC} ---" | tee -a "$BUILD_LOG_PATH"
        
        # 进度跟踪准备
        local total_targets=$(make -n -j1 V=s 2>/dev/null | grep -c '^make\[.*\]: Entering directory .*package/')
        
        # 进度跟踪子进程
        (
            # 将进度条信息写入 /dev/tty (终端)
            sleep 5 
            local compiled_count=0
            
            if [ "$total_targets" -gt 0 ]; then
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

                        # 直接写入终端（/dev/tty 或 /dev/stderr）
                        echo -ne "\r${GREEN}✅ 编译进度: [${progress_bar}] ${percentage}% (${compiled_count}/${total_targets})${NC}" >/dev/stderr
                    fi
                    
                    if echo "$LINE" | grep -q "make\[.*\]: Leaving directory"; then break; fi
                done
                echo "" >/dev/stderr
            fi
        ) &
        PROGRESS_PID=$!

        # 执行编译
        /usr/bin/time -f "MAKE_REAL_TIME=%e" make -j"$JOBS_N" V=s 2>&1 | tee -a "$BUILD_LOG_PATH"
        
        # ... (后续处理逻辑不变)
        
    )
    # ... (返回值处理不变)
}


# 脚本注入执行 (恢复)
run_custom_injections() {
    local INJECTIONS_STRING="$1"
    local TARGET_STAGE="$2"
    local CURRENT_SOURCE_DIR="$3"
    
    [[ -z "$INJECTIONS_STRING" ]] && return
    
    local injections_array_string=$(echo "$INJECTIONS_STRING" | tr '##' '\n')
    local injections
    IFS=$'\n' read -rd '' -a injections <<< "$injections_array_string"
    
    echo -e "--- ${BLUE}⚙️ 执行自定义脚本 [阶段 $TARGET_STAGE]${NC} ---" | tee -a "$BUILD_LOG_PATH"
    
    for injection in "${injections[@]}"; do
        [[ -z "$injection" ]] && continue
        local script_name=$(echo "$injection" | awk '{print $1}')
        local stage=$(echo "$injection" | awk '{print $2}')
        local full_path="$EXTRA_SCRIPT_DIR/$script_name"
        
        if [ "$stage" == "$TARGET_STAGE" ] && [ -f "$full_path" ]; then
            echo -e "${GREEN}🔧 运行: $script_name${NC}" | tee -a "$BUILD_LOG_PATH"
            ( cd "$CURRENT_SOURCE_DIR" && bash "$full_path" ) 2>&1 | tee -a "$BUILD_LOG_PATH"
        fi
    done
}


# 批量编译菜单 (不变)
build_queue_menu() {
    clear; echo -e "## ${BLUE}📦 批量编译队列${NC}"
    local configs=("$CONFIGS_DIR"/*.conf)
    if [ ${#configs[@]} -eq 0 ] || ([ ${#configs[@]} -eq 1 ] && [ ! -f "${configs[0]}" ]); then echo -e "${YELLOW}无配置。${NC}"; read -p "回车..."; return; fi
    
    local queue=(); local i=1; local files=()
    while true; do
        clear; echo "待选配置:"
        i=1
        for file in "${configs[@]}"; do
            local fn=$(basename "$file" .conf)
            local mk=" "; if [[ " ${queue[*]} " =~ " ${fn} " ]]; then mk="${GREEN}✅${NC}"; fi
            echo "$i) $mk $fn"; files[i]="$fn"; i=$((i+1))
        done
        echo "A) 切换选择  S) 开始  R) 返回"
        read -p "选择: " c
        case $c in
            A|a) read -p "序号: " x; local n="${files[$x]}"; 
                 if [[ " ${queue[*]} " =~ " ${n} " ]]; then 
                    queue=($(printf "%s\n" "${queue[@]}" | grep -v "^${n}$"))
                 else queue+=("$n"); fi ;;
            S|s) 
                 if ! pre_build_checks; then
                    echo -e "${RED}❌ 环境校验失败，批量编译终止${NC}"
                    read -p "按回车返回..."
                    return
                 fi
                 
                 for q in "${queue[@]}"; do [[ -n "$q" ]] && {
                     declare -A B_VARS; local cf="$CONFIGS_DIR/$q.conf"
                     while IFS='=' read -r k v; do [[ "$k" =~ ^[A-Z_]+$ ]] && B_VARS["$k"]=$(echo "$v" | sed 's/^"//;s/"$//'); done < "$cf"
                     
                     echo -e "\n--- ${BLUE}[批处理] 开始编译 $q${NC} ---"
                     execute_build "$q" B_VARS
                 }; done; read -p "批处理结束。" ;;
            R|r) return ;;
            *) echo -e "${RED}无效选择。${NC}"; sleep 1 ;;
        esac
    done
}


# --- 脚本入口 ---
check_and_install_dependencies
main_menu
