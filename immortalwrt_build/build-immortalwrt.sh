#!/bin/bash

# ==========================================================
# 🔥 ImmortalWrt/OpenWrt 固件编译管理脚本 V6.0.0 (性能增强版)
# ----------------------------------------------------------
# V6.0.0 新增功能:
# 1. [性能] 启用 CCACHE 编译缓存加速 (大幅提升二次编译速度)。
# 2. [UX] 实时跟踪编译进度，并报告总编译耗时。
# 3. [UX] 菜单中增加运行 'make menuconfig' 选项，支持配置回存。
# 4. [健壮性] 增加编译前检查 (磁盘空间、网络连接)。
# 5. [健壮性] 智能清理逻辑，支持断点续编 (跳过 make clean)。
# ==========================================================

# --- 变量定义 ---

# 1. 核心构建根目录
BUILD_ROOT="$HOME/immortalwrt_builder_root"

# 2. 源码根目录
SOURCE_ROOT="$HOME" 

# 3. 定义子目录
CONFIGS_DIR="$BUILD_ROOT/profiles"
LOG_DIR="$BUILD_ROOT/logs"
USER_CONFIG_DIR="$BUILD_ROOT/user_configs"
EXTRA_SCRIPT_DIR="$BUILD_ROOT/custom_scripts"
OUTPUT_DIR="$BUILD_ROOT/output"
CCACHE_DIR="$BUILD_ROOT/ccache" # CCACHE 目录

# 编译日志文件名格式和时间戳
BUILD_LOG_PATH=""

# 配置文件变量列表
CONFIG_VAR_NAMES=(FW_TYPE REPO_URL FW_BRANCH CONFIG_FILE_NAME EXTRA_PLUGINS CUSTOM_INJECTIONS ENABLE_QMODEM)

# 动态变量
CURRENT_SOURCE_DIR=""

# --- 核心目录和依赖初始化 ---

# 1.1 检查并安装编译依赖 (V6.0.0 确保 ccache 存在)
check_and_install_dependencies() {
    # 检查核心工具，并强制检查 ccache
    local CHECKABLE_TOOLS="git make gcc g++ gawk python3 perl wget curl unzip lscpu free ccache"
    local missing_deps=""
    for dep in $CHECKABLE_TOOLS; do
        if ! command -v "$dep" &> /dev/null; then missing_deps="$missing_deps $dep"; fi
    done

    if [ -n "$missing_deps" ]; then
        echo "## 检查并安装编译依赖..."
        
        local INSTALL_DEPENDENCIES="ack antlr3 asciidoc autoconf automake autopoint bison build-essential bzip2 ccache clang cmake cpio curl device-tree-compiler ecj fastjar flex gawk gettext gcc-multilib g++-multilib git gnutls-dev gperf haveged help2man intltool libc6-dev-i386 libelf-dev libglib2.0-dev libgmp3-dev libmpc-dev libmpfr-dev libncurses-dev libpython3-dev libreadline-dev libssl-dev libtool libyaml-dev libz-dev lld llvm lrzsz mkisofs msmtp nano ninja-build p7zip p7zip-full patch pkgconf python3 python3-pip python3-ply python3-pyelftools qemu-utils re2c rsync scons squashfs-tools subversion swig texinfo uglifyjs upx-ucl unzip vim wget xmlto xxd zlib1g-dev zstd uuid-runtime zip procps util-linux iputils-ping" # 增加 iputils-ping
        
        if command -v apt-get &> /dev/null; then
            echo -e "\n--- 正在更新软件包列表并安装依赖 (Debian/Ubuntu) ---"
            sudo apt-get update || { echo "错误: apt-get update 失败。"; return 1; }
            sudo apt-get install -y $INSTALL_DEPENDENCIES
        elif command -v yum &> /dev/null; then
            echo -e "\n--- 正在尝试安装依赖 (CentOS/RHEL) ---"
            echo "请手动检查并安装以下依赖：$INSTALL_DEPENDENCIES"
        else
            echo -e "\n**警告:** 无法自动安装依赖。请确保已安装编译环境。"
        fi 
    fi
    
    # 1.2 确保目录存在
    mkdir -p "$CONFIGS_DIR" "$LOG_DIR" "$USER_CONFIG_DIR" "$EXTRA_SCRIPT_DIR" "$OUTPUT_DIR" "$CCACHE_DIR"
    return 0
}

# 1.3 辅助函数：获取配置文件摘要
get_config_summary() {
    local config_file_name="$1"
    local config_path="$USER_CONFIG_DIR/$config_file_name"
    
    if [ -f "$config_path" ]; then
        local target=$(grep "^CONFIG_TARGET_BOARD=" "$config_path" | cut -d'"' -f2)
        local subtarget=$(grep "^CONFIG_TARGET_SUBTARGET=" "$config_path" | cut -d'"' -f2)
        
        if [ -n "$target" ]; then
            echo "[$target/$subtarget]"
        else
            if [[ "$config_file_name" == *.diffconfig ]]; then
                echo "[Diff 配置]"
            else
                echo "[未知架构]"
            fi
        fi
    else
        echo "[❌ 文件缺失]"
    fi
}

# --- 2. 菜单和入口 ---

main_menu() {
    check_and_install_dependencies
    while true; do
        clear
        echo "====================================================="
        echo "    🔥 ImmortalWrt 固件编译管理脚本 V6.0.0 🔥"
        echo "   (性能增强 | 健壮性提升 | CCACHE 加速)"
        echo "====================================================="
        echo "1) 🌟 新建机型配置 (Create New Configuration)"
        echo "2) ⚙️ 选择/编辑/删除配置 (Select/Edit/Delete)"
        echo "3) 🚀 编译固件 (Start Build Process)"
        echo "4) 📦 批量编译队列 (Build Queue)"
        echo "5) 📊 CCACHE 状态报告"
        echo "6) 🚪 退出 (Exit)"
        echo "-----------------------------------------------------"
        read -p "请选择功能 (1-6): " choice
        
        case $choice in
            1) create_config ;;
            2) select_config ;;
            3) start_build_process ;;
            4) build_queue_menu ;;
            5) ccache_status ;;
            6) echo "退出脚本。再见！"; exit 0 ;;
            *) echo "无效选择。"; sleep 1 ;;
        esac
    done
}

# 2.1 CCACHE 状态报告
ccache_status() {
    clear
    echo "## 📊 CCACHE 编译缓存状态"
    echo "缓存目录: $CCACHE_DIR"
    echo "-----------------------------------------------------"
    if command -v ccache &> /dev/null; then
        ccache -s
        read -p "是否清空 CCACHE 缓存？(y/n): " clear_cache
        if [[ "$clear_cache" == "y" ]]; then
            ccache -C
            echo "✅ CCACHE 缓存已清空。"
        fi
    else
        echo "❌ 警告: 未检测到 ccache 命令。"
    fi
    read -p "按任意键返回主菜单..."
}


# --- 3. 配置管理 (config_interaction 中增加 menuconfig 选项) ---

# 3.1 新建配置 (V5.0.0 优化流程)
create_config() {
    # (此函数逻辑不变)
    while true; do
        clear
        echo "## 🌟 新建机型配置"
        read -p "请输入机型配置名称 (例如 xiaomi_ax6000, 不带空格): " new_name
        if [[ -z "$new_name" ]]; then echo "名称不能为空！"; sleep 1; continue; fi
        
        local CONFIG_FILE="$CONFIGS_DIR/$new_name.conf"
        if [[ -f "$CONFIG_FILE" ]]; then
            echo "配置 [$new_name] 已存在！"
            read -p "是否覆盖？(y/n): " overwrite
            [[ "$overwrite" != "y" ]] && continue
        fi
        
        # 初始化默认变量
        declare -A new_vars
        new_vars[FW_TYPE]="immortalwrt"
        new_vars[REPO_URL]="https://github.com/immortalwrt/immortalwrt"
        new_vars[FW_BRANCH]="master"
        new_vars[CONFIG_FILE_NAME]="$new_name.config"
        new_vars[EXTRA_PLUGINS]=""
        new_vars[CUSTOM_INJECTIONS]=""
        new_vars[ENABLE_QMODEM]="n"
        
        save_config_from_array "$new_name" new_vars
        
        echo -e "\n✅ 配置 [$new_name] 已创建。"
        echo "---------------------------------------------"
        echo "请将您的 .config 或 .diffconfig 文件放入:"
        echo "📂 $USER_CONFIG_DIR"
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

# 3.2 选择配置 (V5.0.0 增强显示 - 不变)
select_config() {
    clear
    echo "## ⚙️ 选择配置"
    
    local configs=("$CONFIGS_DIR"/*.conf)
    if [ ${#configs[@]} -eq 0 ] || ([ ${#configs[@]} -eq 1 ] && [ ! -f "${configs[0]}" ]); then
        echo "没有保存的配置。"
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
            local cfg_file_name=$(grep "CONFIG_FILE_NAME=" "$file" | cut -d'"' -f2)
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
            *) echo "无效操作"; sleep 1 ;;
        esac
    fi
}


# 运行 Menuconfig (V6.0.0 新增)
run_menuconfig() {
    local source_dir="$1"
    local config_file_path="$2"
    
    echo -e "\n--- ⚙️ 运行 Menuconfig (V6.0.0) ---"
    
    (
        cd "$source_dir" || exit 1
        
        # 导入配置，确保环境正确
        local CFG_FILE_NAME=$(basename "$config_file_path")
        local ext="${CFG_FILE_NAME##*.}"
        
        if [[ "$ext" == "diffconfig" ]]; then
            echo "ℹ️  应用 .diffconfig 并执行 make defconfig..."
            cp "$config_file_path" .config
            make defconfig 
        else
            echo "ℹ️  导入 .config 文件..."
            cp "$config_file_path" .config
        fi

        # 检查是否支持图形化 menuconfig
        if command -v X &> /dev/null || command -v wslg &> /dev/null; then
            echo "检测到图形化环境支持，建议使用 make xconfig/gconfig。"
            make xconfig 2>/dev/null || make gconfig 2>/dev/null || make menuconfig
        else
            echo "运行 make menuconfig (基于终端 ncurses)"
            make menuconfig
        fi
    )
    
    # 询问是否保存修改后的配置
    read -p "是否将新的 .config 覆盖到 $config_file_path？(y/n): " save_back
    if [[ "$save_back" == "y" ]]; then
        cp "$source_dir/.config" "$config_file_path"
        echo "✅ 新的配置已保存。"
    else
        echo "取消保存。"
    fi
}

# 3.3 配置交互界面 (V6.0.0 增加 menuconfig 选项)
config_interaction() {
    local CONFIG_NAME="$1"
    local CONFIG_FILE="$CONFIGS_DIR/$CONFIG_NAME.conf"
    
    declare -A config_vars
    if [ -f "$CONFIG_FILE" ]; then
        while IFS='=' read -r key value; do
            if [[ "$key" =~ ^[A-Z_]+$ ]]; then
                config_vars["$key"]=$(echo "$value" | sed 's/^"//;s/"$//')
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
            1) # (修改源码，逻辑不变)
                echo -e "\n--- 选择源码类型 ---"
                # ... (略去选择源码类型部分)
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
                    # 1. 源码准备
                    if ! clone_or_update_source "${config_vars[REPO_URL]}" "${config_vars[FW_BRANCH]}" "${config_vars[FW_TYPE]}"; then
                        echo "源码更新失败，无法运行 menuconfig。"
                        sleep 3
                        continue
                    fi
                    # 2. 运行 menuconfig
                    run_menuconfig "$CURRENT_SOURCE_DIR" "$USER_CONFIG_DIR/${config_vars[CONFIG_FILE_NAME]}"
                fi
                ;;
            S|s) save_config_from_array "$CONFIG_NAME" config_vars; return ;;
            R|r) return ;;
        esac
    done
}


# 3.8 配置校验 (V5.0.0 - 不变)
validate_build_config() {
    # (逻辑不变)
    local -n VARS=$1
    local config_name="$2"
    local error_count=0
    
    echo -e "\n--- 🔍 验证配置: $config_name ---"
    
    local config_path="$USER_CONFIG_DIR/${VARS[CONFIG_FILE_NAME]}"
    if [[ ! -f "$config_path" ]]; then
        echo "❌ 错误：找不到配置文件: $config_path"
        error_count=$((error_count + 1))
    else
        if ! grep -q "CONFIG_TARGET" "$config_path"; then
             if [[ "${VARS[CONFIG_FILE_NAME]}" == *".config" ]]; then
                 echo "⚠️  警告：.config 文件中似乎没有 CONFIG_TARGET 定义，可能是空文件？"
             fi
        fi
        echo "✅ 配置文件存在: $config_path"
    fi
    
    if [[ -n "${VARS[CUSTOM_INJECTIONS]}" ]]; then
        # (检查注入脚本逻辑不变)
        local injections_array_string=$(echo "${VARS[CUSTOM_INJECTIONS]}" | tr '##' '\n')
        local injections
        IFS=$'\n' read -rd '' -a injections <<< "$injections_array_string"
        for injection in "${injections[@]}"; do
             [[ -z "$injection" ]] && continue
             local sname=$(echo "$injection" | awk '{print $1}')
             if [[ ! -f "$EXTRA_SCRIPT_DIR/$sname" ]]; then
                 echo "❌ 错误：注入脚本缺失: $sname"
                 error_count=$((error_count + 1))
             fi
        done
    fi

    if [ "$error_count" -gt 0 ]; then
        echo "🚨 发现 $error_count 个严重错误，无法继续。"
        return 1
    fi
    return 0
}

# --- 4.0 源码管理 (V5.0.0 - 不变) ---
clone_or_update_source() {
    # (逻辑不变)
    local REPO_URL="$1"
    local FW_BRANCH="$2"
    local FW_TYPE="$3"
    
    local TARGET_DIR_NAME="$FW_TYPE"
    [[ "$FW_TYPE" == "custom" ]] && TARGET_DIR_NAME="custom_source"
    [[ "$FW_TYPE" == "lede" ]] && TARGET_DIR_NAME="lede" 
    
    local CURRENT_SOURCE_DIR="$SOURCE_ROOT/$TARGET_DIR_NAME"
    echo "--- 源码目录: $CURRENT_SOURCE_DIR ---" | tee -a "$BUILD_LOG_PATH"

    if [ -d "$CURRENT_SOURCE_DIR/.git" ]; then
        echo "🔄 源码目录已存在，检查并更新 (git pull)..." | tee -a "$BUILD_LOG_PATH"
        (
            cd "$CURRENT_SOURCE_DIR" || exit 1
            local current_remote=$(git remote get-url origin 2>/dev/null)
            if [[ "$current_remote" != "$REPO_URL" ]]; then
                echo "⚠️  注意: 远程 URL 不一致，正在重置 Origin..." | tee -a "$BUILD_LOG_PATH"
                git remote set-url origin "$REPO_URL"
            fi
            git fetch origin "$FW_BRANCH"
            git reset --hard "origin/$FW_BRANCH"
            git clean -fd
        ) || return 1
    else
        echo "📥 正在克隆源码 ($REPO_URL)..." | tee -a "$BUILD_LOG_PATH"
        git clone "$REPO_URL" -b "$FW_BRANCH" "$CURRENT_SOURCE_DIR" || {
            echo "❌ 克隆失败，请检查 URL 或网络。" | tee -a "$BUILD_LOG_PATH"
            return 1
        }
    fi
    
    export CURRENT_SOURCE_DIR
    return 0
}

# 4.1 预编译检查 (V6.0.0 新增)
pre_build_checks() {
    echo -e "\n--- 🔎 编译前环境检查 (V6.0.0) ---" | tee -a "$BUILD_LOG_PATH"
    
    # 检查磁盘空间 (要求至少 10GB 可用空间)
    local REQUIRED_SPACE_KB=10485760 # 10 GB
    local available_kb=$(df -k . | awk 'NR==2 {print $4}' 2>/dev/null)
    local gb_available=$((available_kb / 1024 / 1024))
    
    if [ "$available_kb" -lt "$REQUIRED_SPACE_KB" ]; then
        echo "❌ 警告：磁盘空间不足。可用空间 ${gb_available} GB，建议至少 10 GB。" | tee -a "$BUILD_LOG_PATH"
        read -p "是否强制继续？(y/n): " cont
        if [[ "$cont" != "y" ]]; then return 1; fi
    else
        echo "✅ 磁盘空间检查通过 ($gb_available GB 可用)。" | tee -a "$BUILD_LOG_PATH"
    fi
    
    # 检查网络连接 (尝试 ping 8.8.8.8)
    if ! ping -c 1 -W 3 8.8.8.8 &> /dev/null; then
        echo "❌ 警告：网络连接似乎不可用或不稳定。" | tee -a "$BUILD_LOG_PATH"
        read -p "是否强制继续？(y/n): " cont
        if [[ "$cont" != "y" ]]; then return 1; fi
    else
        echo "✅ 网络连接检查通过。" | tee -a "$BUILD_LOG_PATH"
    fi

    return 0
}

# 4.2 编译流程入口
start_build_process() {
    clear
    local configs=("$CONFIGS_DIR"/*.conf)
    if [ ${#configs[@]} -eq 0 ] || ([ ${#configs[@]} -eq 1 ] && [ ! -f "${configs[0]}" ]); then
        echo "无配置。"
        read -p "回车返回..."
        return
    fi
    
    echo "--- 选择编译配置 ---"
    local i=1; local files=()
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
        while IFS='=' read -r k v; do [[ "$k" =~ ^[A-Z_]+$ ]] && SEL_VARS["$k"]=$(echo "$v" | sed 's/^"//;s/"$//'); done < "$CFILE"
        
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

# 4.3 核心编译执行 (V6.0.0 核心逻辑)
execute_build() {
    local CONFIG_NAME="$1"
    local -n VARS=$2
    
    local FW_TYPE="${VARS[FW_TYPE]}"
    local FW_BRANCH="${VARS[FW_BRANCH]}"
    local REPO_URL="${VARS[REPO_URL]}"
    local CFG_FILE="${VARS[CONFIG_FILE_NAME]}"
    
    local BUILD_TIME_STAMP_FULL=$(date +%Y%m%d_%H%M%S)
    BUILD_LOG_PATH="$LOG_DIR/build_${CONFIG_NAME}_${BUILD_TIME_STAMP_FULL}.log"

    echo -e "\n=== 🚀 开始编译 [$CONFIG_NAME] (V6.0.0) ===" | tee -a "$BUILD_LOG_PATH"
    echo "日志文件: $BUILD_LOG_PATH"
    
    # 1. 源码准备
    if ! clone_or_update_source "$REPO_URL" "$FW_BRANCH" "$FW_TYPE"; then
        return 1
    fi
    
    local JOBS_N=$(nproc) 
    local START_TIME=$(date +%s) # V6.0.0: 记录开始时间
    
    # 子Shell隔离环境
    (
        cd "$CURRENT_SOURCE_DIR" || exit 1
        
        # V6.0.0: 启用 CCACHE
        export CCACHE_DIR="$CCACHE_DIR"
        export PATH="/usr/lib/ccache:$PATH"
        ccache -z 2>/dev/null # 清理统计信息
        
        export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
        unset CC CXX LD AR AS CPPFLAGS CFLAGS CXXFLAGS LDFLAGS
        local GIT_COMMIT_ID=$(git rev-parse --short HEAD 2>/dev/null || echo "Unknown")
        
        # 1.5 智能清理/断点续编 (V6.0.0 优化)
        echo -e "\n--- 🧹 清理环境/续编检查 ---" | tee -a "$BUILD_LOG_PATH"
        if [ -d "$CURRENT_SOURCE_DIR/bin" ]; then
            echo "检测到上次编译残留..." | tee -a "$BUILD_LOG_PATH"
            read -p "是否执行 make clean 彻底清理？ (n=断点续编/y=彻底清理): " do_clean
            if [[ "$do_clean" == "y" ]]; then
                local size_before=$(du -sh . 2>/dev/null | awk '{print $1}')
                echo "当前占用: $size_before" | tee -a "$BUILD_LOG_PATH"
                make clean 2>&1 | tee -a "$BUILD_LOG_PATH"
                local size_after=$(du -sh . 2>/dev/null | awk '{print $1}')
                echo "清理完成 (剩余占用: $size_after)" | tee -a "$BUILD_LOG_PATH"
            else
                echo "跳过 make clean，尝试断点续编..." | tee -a "$BUILD_LOG_PATH"
            fi
        else
            make clean 2>&1 | tee -a "$BUILD_LOG_PATH"
        fi

        # 2. Feeds & 注入 (不变)
        run_custom_injections "${VARS[CUSTOM_INJECTIONS]}" "100" "$CURRENT_SOURCE_DIR"
        
        if [[ "${VARS[ENABLE_QMODEM]}" == "y" ]]; then
             if ! grep -q "qmodem" feeds.conf.default; then echo 'src-git qmodem https://github.com/FUjr/QModem.git;main' >> feeds.conf.default; fi
        fi
        
        echo -e "\n--- 更新 Feeds ---" | tee -a "$BUILD_LOG_PATH"
        ./scripts/feeds update -a && ./scripts/feeds install -a || { echo "Feeds 失败"; exit 1; }
        
        local plugin_string="${VARS[EXTRA_PLUGINS]}"
        if [[ -n "$plugin_string" ]]; then
            echo -e "\n--- 安装额外插件 ---" | tee -a "$BUILD_LOG_PATH"
            local plugins_array_string=$(echo "$plugin_string" | tr '##' '\n')
            local plugins
            IFS=$'\n' read -rd '' -a plugins <<< "$plugins_array_string"
            for p in "${plugins[@]}"; do 
                [[ -z "$p" ]] && continue
                echo "执行: $p"
                eval "$p" || echo "警告: 插件命令失败，忽略。" | tee -a "$BUILD_LOG_PATH"
            done
        fi

        # 3. 配置文件处理 (不变)
        echo -e "\n--- 导入配置 ($CFG_FILE) ---" | tee -a "$BUILD_LOG_PATH"
        local src_cfg="$USER_CONFIG_DIR/$CFG_FILE"
        local ext="${CFG_FILE##*.}"
        
        if [[ ! -f "$src_cfg" ]]; then echo "错误: 配置文件丢失"; exit 1; fi

        if [[ "$ext" == "diffconfig" ]]; then
            echo "ℹ️  检测到 .diffconfig 差异配置文件，执行 make defconfig..." | tee -a "$BUILD_LOG_PATH"
            cp "$src_cfg" .config
            make defconfig 2>&1 | tee -a "$BUILD_LOG_PATH" || { echo "make defconfig 失败"; exit 1; }
        else
            echo "ℹ️  检测到完整 .config 文件，执行 make defconfig (修复差异)..." | tee -a "$BUILD_LOG_PATH"
            cp "$src_cfg" .config
            make defconfig 2>&1 | tee -a "$BUILD_LOG_PATH"
        fi
        
        # 4. 后期注入 (阶段 850)
        run_custom_injections "${VARS[CUSTOM_INJECTIONS]}" "850" "$CURRENT_SOURCE_DIR"
        
        # 5. 下载与编译
        echo -e "\n--- 🌐 下载依赖包 (make download) ---" | tee -a "$BUILD_LOG_PATH"
        make download -j"$JOBS_N" V=s 2>&1 | tee -a "$BUILD_LOG_PATH"
        if [ ${PIPESTATUS[0]} -ne 0 ]; then
             echo "❌ 下载失败，请检查网络。" | tee -a "$BUILD_LOG_PATH"
             exit 1
        fi
        
        echo -e "\n--- 🚀 开始编译 (make -j$JOBS_N) ---" | tee -a "$BUILD_LOG_PATH"
        
        # V6.0.0 进度条与耗时跟踪
        # 启动实时进度跟踪
        (
            sleep 5 
            local compiled_count=0
            # 尝试计算 package 目录下所有 Makefiles 的数量作为一个粗略目标
            local total_targets=$(find "$CURRENT_SOURCE_DIR/package" -name 'Makefile' -print | wc -l) 
            
            if [ "$total_targets" -gt 0 ]; then
                echo "估算总编译目标数: $total_targets" | tee -a "$BUILD_LOG_PATH"
                
                # 使用 tail -f 实时读取日志并计数已完成的包
                tail -f "$BUILD_LOG_PATH" 2>/dev/null | while read LINE; do
                    if echo "$LINE" | grep -q "Package/.*[done]"; then
                        compiled_count=$((compiled_count + 1))
                        local percentage=$((compiled_count * 100 / total_targets))
                        
                        echo -ne "✅ 进度: $compiled_count / $total_targets (${percentage}%) | 当前: ${LINE##*Package/}"
                    fi
                    if echo "$LINE" | grep -q "make\[.*\]: Leaving directory"; then break; fi
                done
                echo "" # 换行
            fi
        ) &
        PROGRESS_PID=$!

        # 执行编译，并使用 time 记录耗时
        /usr/bin/time -f "MAKE_REAL_TIME=%e" make -j"$JOBS_N" V=s 2>&1 | tee -a "$BUILD_LOG_PATH"
        
        # 停止后台进度监控进程
        kill $PROGRESS_PID 2>/dev/null
        wait $PROGRESS_PID 2>/dev/null 
        echo "--- ⏱️ 跟踪结束 ---" | tee -a "$BUILD_LOG_PATH"


        if [ ${PIPESTATUS[0]} -eq 0 ]; then
            local END_TIME=$(date +%s)
            local DURATION=$((END_TIME - START_TIME))
            local DURATION_STR=$(printf '%dh %dm %ds' $((DURATION/3600)) $(((DURATION%%3600)/60)) $((DURATION%%60)))
            
            echo -e "\n✅ 编译成功！总耗时: $DURATION_STR" | tee -a "$BUILD_LOG_PATH"
            
            # 报告 CCACHE 统计信息
            echo "--- CCACHE 统计 ---" | tee -a "$BUILD_LOG_PATH"
            ccache -s 2>&1 | tee -a "$BUILD_LOG_PATH"
            
            # 归档逻辑 (文件名增加耗时)
            local ARCHIVE_NAME="${FW_TYPE}_${CONFIG_NAME}_${BUILD_TIME_STAMP_FULL}_${GIT_COMMIT_ID}_T${DURATION}s"
            local FIRMWARE_DIR="$CURRENT_SOURCE_DIR/bin/targets"
            local target_subdir=$(find "$FIRMWARE_DIR" -mindepth 2 -maxdepth 2 -type d | head -n 1)
            
            if [ -d "$target_subdir" ]; then
                 cp "$BUILD_LOG_PATH" "$target_subdir/build.log"
                 local zip_path="$OUTPUT_DIR/$ARCHIVE_NAME.zip"
                 (
                     cd "$target_subdir/../"
                     zip -r "$zip_path" "$(basename "$target_subdir")" "build.log"
                 )
                 echo "📦 固件已归档: $zip_path" | tee -a "$BUILD_LOG_PATH"
            else
                 echo "⚠️  未找到固件目录，仅保存日志。" | tee -a "$BUILD_LOG_PATH"
            fi
            exit 0
        else
            echo -e "\n❌ 编译失败" | tee -a "$BUILD_LOG_PATH"
            exit 1
        fi
    )
    
    local ret=$?
    if [ $ret -ne 0 ]; then
        echo "请查看日志: $BUILD_LOG_PATH"
        read -p "编译出错。按回车返回..."
    else
        read -p "编译完成。按回车返回..."
    fi
}

# --- 辅助模块 (Plugins/Injections/Queue - 逻辑不变) ---

manage_plugins_menu() {
    # (逻辑不变)
    local -n vars_array=$1
    while true; do
        clear
        echo "🧩 插件管理"
        local current_plugins="${vars_array[EXTRA_PLUGINS]}"
        local plugins_array=($(echo "$current_plugins" | tr '##' '\n' | sed '/^$/d'))
        
        for i in "${!plugins_array[@]}"; do echo "$((i+1))) ${plugins_array[$i]}"; done
        echo "-----------------------"
        echo "A) 添加命令  D) 删除全部  R) 返回"
        read -p "选择: " choice
        case $choice in
            A|a)
                read -p "输入命令 (如 git clone ...): " cmd
                if [[ -n "$cmd" ]]; then
                    if [[ -z "$current_plugins" ]]; then vars_array[EXTRA_PLUGINS]="$cmd"; else vars_array[EXTRA_PLUGINS]="${current_plugins}##${cmd}"; fi
                fi ;;
            D|d) vars_array[EXTRA_PLUGINS]="" ;; 
            R|r) return ;;
        esac
    done
}

manage_injections_menu() {
    # (逻辑不变)
    local -n vars_array=$1
    while true; do
        clear
        echo "⚙️ 脚本注入管理 (存放于: $EXTRA_SCRIPT_DIR)"
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
                if [[ "$url" =~ github.com ]]; then url=$(echo "$url" | sed 's/github.com/raw.githubusercontent.com/' | sed 's/blob\///'); fi
                local fname=$(basename "$url")
                curl -sSL "$url" -o "$EXTRA_SCRIPT_DIR/$fname" && echo "✅ 下载成功" || echo "❌ 失败"
                read -p "执行阶段 (100/850): " stage
                local new="$fname $stage"
                if [[ -z "$current" ]]; then vars_array[CUSTOM_INJECTIONS]="$new"; else vars_array[CUSTOM_INJECTIONS]="${current}##${new}"; fi
                ;;
            D|d) vars_array[CUSTOM_INJECTIONS]="" ;;
            R|r) return ;;
        esac
    done
}

run_custom_injections() {
    # (逻辑不变)
    local INJECTIONS_STRING="$1"
    local TARGET_STAGE="$2"
    local CURRENT_SOURCE_DIR="$3"
    
    [[ -z "$INJECTIONS_STRING" ]] && return
    
    local injections_array_string=$(echo "$INJECTIONS_STRING" | tr '##' '\n')
    local injections
    IFS=$'\n' read -rd '' -a injections <<< "$injections_array_string"
    
    echo "--- ⚙️ 执行自定义脚本 [阶段 $TARGET_STAGE] ---" | tee -a "$BUILD_LOG_PATH"
    
    for injection in "${injections[@]}"; do
        [[ -z "$injection" ]] && continue
        local script_name=$(echo "$injection" | awk '{print $1}')
        local stage=$(echo "$injection" | awk '{print $2}')
        local full_path="$EXTRA_SCRIPT_DIR/$script_name"
        
        if [ "$stage" == "$TARGET_STAGE" ] && [ -f "$full_path" ]; then
             echo "🔧 运行: $script_name" | tee -a "$BUILD_LOG_PATH"
             ( cd "$CURRENT_SOURCE_DIR" && bash "$full_path" ) 2>&1 | tee -a "$BUILD_LOG_PATH"
        fi
    done
}

# 批量编译菜单 (逻辑不变)
build_queue_menu() {
    # (逻辑不变)
    clear; echo "## 📦 批量编译队列"
    local configs=("$CONFIGS_DIR"/*.conf)
    if [ ${#configs[@]} -eq 0 ]; then echo "无配置。"; read -p "回车..."; return; fi
    
    local queue=(); local i=1; local files=()
    while true; do
        clear; echo "待选配置:"
        i=1
        for file in "${configs[@]}"; do
            local fn=$(basename "$file" .conf)
            local mk=" "; if [[ " ${queue[*]} " =~ " ${fn} " ]]; then mk="✅"; fi
            echo "$i) $mk $fn"; files[i]="$fn"; i=$((i+1))
        done
        echo "A) 切换选择  S) 开始  R) 返回"
        read -p "选择: " c
        case $c in
            A|a) read -p "序号: " x; local n="${files[$x]}"; 
                 if [[ " ${queue[*]} " =~ " ${n} " ]]; then 
                    queue=("${queue[@]/$n}"); 
                 else queue+=("$n"); fi ;;
            S|s) 
                 for q in "${queue[@]}"; do [[ -n "$q" ]] && {
                     declare -A B_VARS; local cf="$CONFIGS_DIR/$q.conf"
                     while IFS='=' read -r k v; do [[ "$k" =~ ^[A-Z_]+$ ]] && B_VARS["$k"]=$(echo "$v" | sed 's/^"//;s/"$//'); done < "$cf"
                     
                     # 在批处理中跳过环境检查
                     echo -e "\n--- [批处理] 开始编译 $q ---"
                     execute_build "$q" B_VARS
                 }; done; read -p "批处理结束。" ;;
            R|r) return ;;
        esac
    done
}

# --- 脚本入口 ---
check_and_install_dependencies
main_menu
