#!/bin/bash

# ==========================================================
# 🔥 ImmortalWrt/OpenWrt 固件编译管理脚本 V4.9.27 (工作目录修正版)
# - 修复: 在 execute_build 中，在执行 scripts/feeds 前强制检查并切换到源码目录，解决 Feeds 找不到的问题。
# - 修复: 彻底重写 execute_build 中配置文件导入逻辑，增加错误检查。
# - 修复: run_custom_injections 函数中 if 语句的语法错误。
# - 功能: 纯 .config 模式，支持批量编译、插件管理、脚本注入、固件清理。
# ==========================================================

# --- 变量定义 ---

# 1. 核心构建根目录 (用于存放配置、日志、产物)
BUILD_ROOT="$HOME/immortalwrt_builder_root"

# 2. 源码根目录 (直接指向用户主目录)
SOURCE_ROOT="$HOME" 

# 3. 定义子目录
CONFIGS_DIR="$BUILD_ROOT/profiles"          # 存放 *.conf 配置文件
LOG_DIR="$BUILD_ROOT/logs"                  # 存放编译日志
USER_CONFIG_DIR="$BUILD_ROOT/user_configs"  # 存放用户自定义的 .config 或 .diffconfig 文件
EXTRA_SCRIPT_DIR="$BUILD_ROOT/custom_scripts" # 存放自定义注入的本地脚本
OUTPUT_DIR="$BUILD_ROOT/output"             # 存放最终固件的输出目录

# 编译日志文件名格式和时间戳
BUILD_LOG_PATH=""
BUILD_TIME_STAMP=$(date +%Y%m%d_%H%M)

# 配置变量名称列表
CONFIG_VAR_NAMES=(FW_TYPE FW_BRANCH CONFIG_FILE_NAME EXTRA_PLUGINS CUSTOM_INJECTIONS ENABLE_QMODEM ENABLE_TURBOACC)

# 动态变量
CURRENT_SOURCE_DIR=""


# --- 核心目录和依赖初始化 ---

# 1.1 检查并安装编译依赖
check_and_install_dependencies() {
    echo "## 检查并安装编译依赖..."
    
    # 核心依赖列表，用于最终安装提示
    local CORE_DEPENDENCIES="build-essential git make gcc g++ binutils zlib1g-dev libncurses5-dev gawk python3 perl wget curl unzip procps lscpu free ccache"
    local INSTALL_DEPENDENCIES="ack antlr3 asciidoc autoconf automake autopoint bison build-essential bzip2 ccache clang cmake cpio curl device-tree-compiler ecj fastjar flex gawk gettext gcc-multilib g++-multilib git gnutls-dev gperf haveged help2man intltool libc6-dev-i386 libelf-dev libglib2.0-dev libgmp3-dev libmpc-dev libmpfr-dev libncurses-dev libpython3-dev libreadline-dev libssl-dev libtool libyaml-dev libz-dev lld llvm lrzsz mkisofs msmtp nano ninja-build p7zip p7zip-full patch pkgconf python3 python3-pip python3-ply python3-pyelftools qemu-utils re2c rsync scons squashfs-tools subversion swig texinfo uglifyjs upx-ucl unzip vim wget xmlto xxd zlib1g-dev zstd uuid-runtime zip procps util-linux"
    
    if command -v ccache &> /dev/null; then
        echo "✅ ccache 已安装。"
    else
        echo "⚠️ ccache 未安装。将尝试安装..."
        INSTALL_DEPENDENCIES="$INSTALL_DEPENDENCIES ccache"
    fi

    local missing_deps=""
    
    # 🌟 优化点：明确指定需要通过 command -v 检测的工具，排除元软件包和库文件
    local CHECKABLE_TOOLS="git make gcc g++ gawk python3 perl wget curl unzip procps lscpu free"
    
    # 循环检测可执行工具
    for dep in $CHECKABLE_TOOLS; do
        if ! command -v "$dep" &> /dev/null; then
            missing_deps="$missing_deps $dep"
        fi
    done

    # 特殊处理：如果核心工具缺失
    if [ -n "$missing_deps" ]; then
        echo "❌ 警告: 缺少关键工具: $missing_deps。"
        echo "尝试安装所有依赖以解决潜在的库文件缺失问题..."
    else
        echo "✅ 核心工具校验通过。"
    fi
    
    # 脚本主体：安装依赖
    if command -v apt-get &> /dev/null; then
        echo -e "\n--- 正在更新软件包列表并安装依赖 (Debian/Ubuntu) ---"
        sudo apt-get update || { echo "错误: apt-get update 失败。请检查网络。"; return 1; }
        # 运行这一步保证库文件和元包的完整性
        sudo apt-get install -y $INSTALL_DEPENDENCIES
        if [ $? -ne 0 ]; then
             echo "❌ 错误: 依赖安装失败。请手动检查并安装。"
             return 1
        fi
    elif command -v yum &> /dev/null; then
        echo -e "\n--- 正在尝试安装依赖 (CentOS/RHEL) ---"
        # yum 不支持 -y 的软件包列表
        echo "请手动检查并安装以下依赖：$INSTALL_DEPENDENCIES"
    else
        echo -e "\n**警告:** 无法自动安装依赖。请确保以下软件包已安装:\n$INSTALL_DEPENDENCIES"
        read -p "按任意键继续 (风险自负)..."
    fi 

    echo "## 依赖检查完成。"
    sleep 2
    return 0
}

# 1.2 检查并创建目录
ensure_directories() {
    mkdir -p "$CONFIGS_DIR"
    mkdir -p "$LOG_DIR"
    mkdir -p "$USER_CONFIG_DIR"
    mkdir -p "$EXTRA_SCRIPT_DIR"
    mkdir -p "$OUTPUT_DIR"
}

# --- 2. 菜单和入口 ---

# 2.1 首页菜单
main_menu() {
    ensure_directories
    while true; do
        clear
        echo "====================================================="
        echo "        🔥 ImmortalWrt 固件编译管理脚本 V4.9.26 🔥"
        echo "             (纯 .config 配置模式)"
        echo "====================================================="
        echo "1) 🌟 新建机型配置 (Create New Configuration)"
        echo "2) ⚙️ 选择/编辑/删除机型配置 (Select/Edit/Delete Configuration)"
        echo "3) 🚀 编译固件 (Start Build Process)"
        echo "4) 📦 **批量编译队列 (Build Queue)**"
        echo "5) 🗑️ **固件清理工具 (Cleanup Utility)**"
        echo "6) 🚪 退出 (Exit)"
        echo "-----------------------------------------------------"
        read -p "请选择功能 (1-6): " choice
        
        case $choice in
            1) create_config ;;
            2) select_config ;;
            3) start_build_process ;;
            4) build_queue_menu ;;
            5) cleanup_menu ;;
            6) echo "退出脚本。再见！"; exit 0 ;;
            *) echo "无效选择，请重新输入。"; sleep 1 ;;
        esac
    done
}

# --- 3. 配置管理 ---

# 3.1 新建配置
create_config() {
    while true; do
        clear
        echo "## 🌟 新建机型配置"
        read -p "请输入机型配置名称 (用于保存): " new_name
        if [[ -z "$new_name" ]]; then
            echo "配置名称不能为空！"
            sleep 1
            continue
        fi
        local CONFIG_FILE="$CONFIGS_DIR/$new_name.conf"
        if [[ -f "$CONFIG_FILE" ]]; then
            echo "配置 [$new_name] 已存在！"
            read -p "是否要覆盖它？(y/n): " overwrite
            [[ "$overwrite" != "y" ]] && continue
        fi
        
        config_interaction "$new_name" "new"
        
        if [ -f "$CONFIG_FILE" ]; then
            echo ""
            echo "ℹ️ **提醒:** 请手动将您的 **.config** 或 **.diffconfig** 文件放入以下目录:"
            echo "**$USER_CONFIG_DIR**"
            echo "文件名应与配置变量中的 **${new_name}.config** 或 **${new_name}.diffconfig** 匹配。"
            read -p "配置已保存。按任意键返回..."
        fi
        return
    done
}

# 3.2 选择并编辑配置
select_config() {
    clear
    echo "## ⚙️ 选择/编辑/删除 机型配置"
    
    local configs=("$CONFIGS_DIR"/*.conf)
    if [ ${#configs[@]} -eq 0 ] || ([ ${#configs[@]} -eq 1 ] && [ ! -f "${configs[0]}" ]); then
        echo "当前没有保存的配置。请先新建配置。"
        read -p "按任意键返回主菜单..."
        return
    fi
    
    echo "--- 可用配置 ---"
    local i=1
    local files=()
    for file in "${configs[@]}"; do
        if [ -f "$file" ]; then
            filename=$(basename "$file" .conf)
            echo "$i) $filename"
            files[i]="$filename"
            i=$((i + 1))
        fi
    done
    echo "----------------"
    local return_index=$i
    echo "$return_index) 返回主菜单"
    
    read -p "请选择配置序号 (1-$return_index): " choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "$return_index" ]; then
        if [ "$choice" -eq "$return_index" ]; then
            return
        else
            local SELECTED_NAME="${files[$choice]}"
            echo ""
            echo "当前选择: **$SELECTED_NAME**"
            read -p "选择操作：1) 编辑配置 | 2) 删除配置 | 3) 返回主菜单: " action
            case "$action" in   
                1) config_interaction "$SELECTED_NAME" "edit" ;;
                2) delete_config "$SELECTED_NAME" ;;
                3) return ;;
                *) echo "无效操作。返回主菜单。"; sleep 1 ;;
            esac
        fi
    else
        echo "无效选择。返回主菜单。"
        sleep 1
    fi
}

# 3.3 实际配置交互界面
config_interaction() {
    local CONFIG_NAME="$1"
    local MODE="$2"
    local CONFIG_FILE="$CONFIGS_DIR/$CONFIG_NAME.conf"
    
    declare -A config_vars
    
    if [ "$MODE" == "edit" ] && [ -f "$CONFIG_FILE" ]; then
        while IFS='=' read -r key value; do
            if [[ "$key" =~ ^[A-Z_]+$ ]]; then
                config_vars["$key"]=$(echo "$value" | sed 's/^"//;s/"$//')
            fi
        done < "$CONFIG_FILE"
    fi
    
    : ${config_vars[FW_TYPE]:="immortalwrt"}
    : ${config_vars[FW_BRANCH]:="master"}
    : ${config_vars[CONFIG_FILE_NAME]:="$CONFIG_NAME.config"} 
    : ${config_vars[EXTRA_PLUGINS]:=""}
    : ${config_vars[CUSTOM_INJECTIONS]:=""}
    : ${config_vars[ENABLE_QMODEM]:="n"}
    : ${config_vars[ENABLE_TURBOACC]:="n"}
    
    while true; do
        clear
        echo "====================================================="
        echo "     📝 ${MODE^} 配置: ${CONFIG_NAME}"
        echo "   (请确保在 $USER_CONFIG_DIR 提供了配置好的 .config 文件)"
        echo "====================================================="
        
        echo "1. 固件类型/版本: ${config_vars[FW_TYPE]} / ${config_vars[FW_BRANCH]}"
        echo "2. **配置 (config) 文件名**: ${config_vars[CONFIG_FILE_NAME]}"
        local plugin_count=0
        if [[ -n "${config_vars[EXTRA_PLUGINS]}" ]]; then
            plugin_count=$(echo "${config_vars[EXTRA_PLUGINS]}" | grep -o '##' | wc -l | awk '{print $1 + 1}')
        fi
        echo "3. 🧩 **额外插件列表** (管理): $plugin_count 条" 
        
        local injection_count=0
        if [[ -n "${config_vars[CUSTOM_INJECTIONS]}" ]]; then
            injection_count=$(echo "${config_vars[CUSTOM_INJECTIONS]}" | grep -o '##' | wc -l | awk '{print $1 + 1}')
        fi
        echo "4. ⚙️ **脚本注入管理** (管理): $injection_count 条"
        
        echo "5. [${config_vars[ENABLE_QMODEM]^^}] 内置 Qmodem"
        echo "6. [${config_vars[ENABLE_TURBOACC]^^}] 内置 Turboacc"
        echo -e "\n7. ⚠️ **检查配置文件的位置和名称**"

        echo "-----------------------------------------------------"
        echo "S) 保存配置并返回 | R) 放弃修改并返回"
        read -p "请选择要修改的项 (1-7, S/R): " sub_choice
        
        case $sub_choice in
            1) 
                echo -e "\n--- 选择固件类型 ---"
                echo "1: openwrt"
                echo "2: immortalwrt"
                echo "3: lede"
                read -p "请选择固件类型 (1/2/3, 默认为 immortalwrt): " fw_type_choice
                case $fw_type_choice in
                    1) config_vars[FW_TYPE]="openwrt" ;;
                    2) config_vars[FW_TYPE]="immortalwrt" ;;
                    3) config_vars[FW_TYPE]="lede" ;;
                    *) config_vars[FW_TYPE]="immortalwrt" ;;
                esac
                read -p "请输入固件版本/分支 (当前: ${config_vars[FW_BRANCH]}): " branch_input
                config_vars[FW_BRANCH]="${branch_input:-${config_vars[FW_BRANCH]}}"
                ;;
            2) 
                echo "文件必须存放在 $USER_CONFIG_DIR 目录下。"
                read -p "请输入配置文件名称 (当前: ${config_vars[CONFIG_FILE_NAME]}): " config_file_input
                config_vars[CONFIG_FILE_NAME]="${config_file_input:-$CONFIG_NAME.config}"
                ;;
            3) manage_plugins_menu config_vars ;;
            4) manage_injections_menu config_vars ;;
            5) config_vars[ENABLE_QMODEM]=$([[ "${config_vars[ENABLE_QMODEM]}" == "y" ]] && echo "n" || echo "y") ;;
            6) config_vars[ENABLE_TURBOACC]=$([[ "${config_vars[ENABLE_TURBOACC]}" == "y" ]] && echo "n" || echo "y") ;;
            7) 
                local config_path="$USER_CONFIG_DIR/${config_vars[CONFIG_FILE_NAME]}"
                if [ -f "$config_path" ]; then
                    echo -e "\n✅ 文件存在: $config_path"
                else
                    echo -e "\n❌ 文件不存在。请手动创建或上传到: $config_path"
                fi
                read -p "按任意键返回..."
                ;;
            S|s)
                save_config_from_array "$CONFIG_NAME" config_vars
                echo "配置 [$CONFIG_NAME] 已保存！"
                sleep 2
                return
                ;;
            R|r)
                echo "放弃修改，返回主菜单。"
                sleep 2
                return
                ;;
            *) echo "无效选择，请重新输入。"; sleep 1 ;;
        esac
    done
}

# 3.4 清理源码目录
clean_source_dir() {
    local CONFIG_NAME="$1"
    local CONFIG_FILE="$CONFIGS_DIR/$CONFIG_NAME.conf"
    
    local FW_TYPE=$(grep 'FW_TYPE="' "$CONFIG_FILE" | cut -d'"' -f2)
    local TARGET_DIR_NAME="$FW_TYPE"
    if [ "$FW_TYPE" == "lede" ]; then TARGET_DIR_NAME="lede"; fi
    
    local CURRENT_SOURCE_DIR="$SOURCE_ROOT/$TARGET_DIR_NAME"

    if [ ! -d "$CURRENT_SOURCE_DIR" ]; then
        echo "警告: 源码目录不存在，无需清理。"
        return 0
    fi
    
    (
        cd "$CURRENT_SOURCE_DIR" || { echo "错误: 无法进入源码目录进行清理。"; return 1; }

        while true; do
            clear
            echo "## 🛡️ 源码清理模式选择"
            echo "当前源码目录: $CURRENT_SOURCE_DIR"
            echo "-----------------------------------------------------"
            echo "1) 🧹 **标准清理 (make clean)**"
            echo "2) 彻底清理 (make dirclean)"
            echo "3) 🔄 跳过清理"
            echo "-----------------------------------------------------"
            read -p "请选择清理模式 (1/2/3): " clean_choice

            case $clean_choice in
                1) make clean || { echo "错误: make clean 失败。"; exit 1; }; echo "✅ 标准清理完成。"; exit 0 ;;
                2) make dirclean || { echo "错误: make dirclean 失败。"; exit 1; }; echo "✅ 彻底清理完成。"; exit 0 ;;
                3) echo "--- 跳过清理 ---"; exit 0 ;;
                *) echo "无效选择。"; sleep 1 ;;
            esac
        done
    ) 
    return $?
}

# 3.6 保存配置到文件
save_config_from_array() {
    local config_name="$1"
    local -n vars_array="$2"
    local config_file="$CONFIGS_DIR/$config_name.conf"
    
    > "$config_file"
    for key in "${CONFIG_VAR_NAMES[@]}"; do
        if [[ -n "${vars_array[$key]+x}" ]]; then
            echo "$key=\"${vars_array[$key]}\"" >> "$config_file"
        fi
    done
}

# 3.7 删除配置
delete_config() {
    local CONFIG_NAME="$1"
    local CONFIG_FILE="$CONFIGS_DIR/$CONFIG_NAME.conf"
    
    clear
    echo "## 🗑️ 确认删除配置"
    read -p "请再次输入配置名称 [$CONFIG_NAME] 进行确认: " confirm_name
    
    if [[ "$confirm_name" == "$CONFIG_NAME" ]]; then
        if [ -f "$CONFIG_FILE" ]; then
            rm -f "$CONFIG_FILE"
            find "$USER_CONFIG_DIR" -maxdepth 1 -type f -name "$CONFIG_NAME.*config" -delete
            echo -e "\n✅ 配置 **[$CONFIG_NAME]** 已删除。"
        else
            echo -e "\n❌ 错误: 配置文件不存在。"
        fi
    else
        echo -e "\n操作取消。"
    fi
    read -p "按任意键返回..."
}

# 3.8 配置校验
validate_build_config() {
    local -n VARS=$1
    local config_name="$2"
    local error_count=0
    
    echo -e "\n--- 🔍 开始验证配置: $config_name ---"
    
    local config_path="$USER_CONFIG_DIR/${VARS[CONFIG_FILE_NAME]}"
    if [[ ! -f "$config_path" ]]; then
        echo "❌ 错误：找不到配置文件: $config_path"
        error_count=$((error_count + 1))
    else
        echo "✅ 配置文件存在: $config_path"
    fi
    
    if [[ -n "${VARS[CUSTOM_INJECTIONS]}" ]]; then
        local injections_array_string=$(echo "${VARS[CUSTOM_INJECTIONS]}" | tr '##' '\n')
        local injections
        IFS=$'\n' read -rd '' -a injections <<< "$injections_array_string"
        
        for injection in "${injections[@]}"; do
            if [[ -z "$injection" ]]; then continue; fi
            local script_path_url=$(echo "$injection" | awk '{print $1}')
            local full_script_path="$EXTRA_SCRIPT_DIR/$script_path_url"
            if [[ ! -f "$full_script_path" ]]; then
                echo "❌ 错误：本地注入脚本不存在: $full_script_path"
                error_count=$((error_count + 1))
            fi
        done
    fi

    echo -e "\n--- 校验结果 ---"
    if [ "$error_count" -gt 0 ]; then
        echo "🚨 发现 $error_count 个严重错误。"
        return 1
    else
        echo "✅ 校验通过。"
        return 0
    fi
}

# 4.0 源码管理 (简单粗暴版 V4.9.19)
clone_or_update_source() {
    local FW_TYPE="$1"
    local FW_BRANCH="$2"
    
    local REPO=""
    local TARGET_DIR_NAME="$FW_TYPE"
    
    case $FW_TYPE in
        openwrt) REPO="https://github.com/openwrt/openwrt" ;;
        immortalwrt) REPO="https://github.com/immortalwrt/immortalwrt" ;;
        lede) REPO="https://github.com/coolsnowwolf/lede" ; TARGET_DIR_NAME="lede" ;;
        *) echo "错误: 固件类型未知 ($FW_TYPE)。" >> "$BUILD_LOG_PATH" && return 1 ;;
    esac

    local CURRENT_SOURCE_DIR="$SOURCE_ROOT/$TARGET_DIR_NAME"
    echo "--- 源码目录: $CURRENT_SOURCE_DIR ---"
    echo -e "\n--- 4.0 源码拉取/更新 ---"

    if [ -d "$CURRENT_SOURCE_DIR/.git" ]; then
        echo "源码目录已存在，尝试更新..."
        (
            cd "$CURRENT_SOURCE_DIR" || exit 1
            git checkout "$FW_BRANCH" || (echo "错误: 分支切换失败。" >> "$BUILD_LOG_PATH" && exit 1)
            git pull origin "$FW_BRANCH" || echo "警告: Git pull 失败，但继续。"
        ) || return 1
    else
        echo "正在进行 **全量克隆 (git clone)**..."
        git clone "$REPO" -b "$FW_BRANCH" "$CURRENT_SOURCE_DIR" || (echo "错误: Git 克隆失败。" >> "$BUILD_LOG_PATH" && return 1)
    fi
    
    if [ ! -f "$CURRENT_SOURCE_DIR/Makefile" ]; then
        echo "🚨 严重错误: 源码目录无效 (缺少 Makefile)。"
        return 1
    fi
    echo "✅ 源码准备就绪。"
    
    export CURRENT_SOURCE_DIR
    return 0
}

# --- 4. 编译流程 ---

# 4.1 编译入口
start_build_process() {
    clear
    echo "## 🚀 编译固件"
    
    local configs=("$CONFIGS_DIR"/*.conf)
    if [ ${#configs[@]} -eq 0 ] || ([ ${#configs[@]} -eq 1 ] && [ ! -f "${configs[0]}" ]); then
        echo "当前没有保存的配置。"
        read -p "按任意键返回..."
        return
    fi 
    
    echo "--- 可用配置 ---"
    local i=1
    local files=()
    for file in "${configs[@]}"; do
        if [ -f "$file" ]; then
            filename=$(basename "$file" .conf)
            echo "$i) $filename"
            files[i]="$filename"
            i=$((i + 1))
        fi
    done
    echo "----------------"
    local return_index=$i
    echo "$return_index) 返回主菜单"
    
    read -p "请选择要编译的配置序号 (1-$return_index): " choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "$return_index" ]; then
        if [ "$choice" -eq "$return_index" ]; then
            return
        else
            local SELECTED_NAME="${files[$choice]}"
            declare -A SELECTED_VARS
            local CONFIG_FILE="$CONFIGS_DIR/$SELECTED_NAME.conf"
            
            while IFS='=' read -r key value; do
                if [[ "$key" =~ ^[A-Z_]+$ ]]; then
                    SELECTED_VARS["$key"]=$(echo "$value" | sed 's/^"//;s/"$//')
                fi
            done < "$CONFIG_FILE"
            
            if validate_build_config SELECTED_VARS "$SELECTED_NAME"; then
                 read -p "配置校验通过，按任意键开始编译..."
                 execute_build "$SELECTED_NAME" "${SELECTED_VARS[FW_TYPE]}" "${SELECTED_VARS[FW_BRANCH]}" SELECTED_VARS
            else
                 echo "配置校验失败。"
                 read -p "按任意键返回..."
            fi
        fi
    else
        echo "无效选择。"
        sleep 1
    fi
}

# 4.4 批量编译菜单
build_queue_menu() {
    clear
    echo "## 📦 批量编译队列管理"
    
    local configs=("$CONFIGS_DIR"/*.conf)
    if [ ${#configs[@]} -eq 0 ] || ([ ${#configs[@]} -eq 1 ] && [ ! -f "${configs[0]}" ]); then
        echo "当前没有保存的配置。"
        read -p "按任意键返回..."
        return
    fi
    
    local queue=()
    local i=1
    local files=()
    
    while true; do
        clear
        echo "====================================================="
        echo "        📦 批量编译队列 (共 ${#queue[@]} 个任务)"
        echo "====================================================="
        
        echo "--- 待选配置 ---"
        i=1
        for file in "${configs[@]}"; do
            if [ -f "$file" ]; then
                local filename=$(basename "$file" .conf)
                local marker=" "
                if [[ " ${queue[*]} " =~ " ${filename} " ]]; then marker="✅"; fi
                echo "$i) $marker $filename"
                files[i]="$filename"
                i=$((i + 1))
            fi
        done
        echo "----------------"
        echo "A) 添加/移除配置 (输入序号)"
        echo "S) 🚀 启动编译队列"
        echo "C) 清空队列"
        echo "R) 返回主菜单"
        
        read -p "请选择操作 (A/S/C/R): " choice
        
        case $choice in
            A|a)
                read -p "请输入配置序号: " idx
                local config_name_to_toggle="${files[$idx]}"
                if [[ -n "$config_name_to_toggle" ]]; then
                    if [[ " ${queue[*]} " =~ " ${config_name_to_toggle} " ]]; then
                        local new_queue=()
                        for item in "${queue[@]}"; do
                            if [ "$item" != "$config_name_to_toggle" ]; then new_queue+=("$item"); fi
                        done
                        queue=("${new_queue[@]}")
                        echo "配置已移除。"
                    else
                        queue+=("$config_name_to_toggle")
                        echo "配置已添加。"
                    fi
                else
                    echo "无效序号。"
                fi
                sleep 1
                ;;
            S|s)
                if [ ${#queue[@]} -eq 0 ]; then echo "队列为空。"; sleep 1; continue; fi
                start_batch_build queue
                return
                ;;
            C|c) queue=(); echo "队列已清空。"; sleep 1 ;;
            R|r) return ;;
            *) echo "无效选择。"; sleep 1 ;;
        esac
    done
}

# 4.3 实际执行编译 (V4.9.27 最终修正版)
execute_build() {
    local CONFIG_NAME="$1"
    local FW_TYPE="$2"
    local FW_BRANCH="$3"
    local -n VARS=$4 
    
    local BUILD_TIME_STAMP_FULL=$(date +%Y%m%d_%H%M%S)
    BUILD_LOG_PATH="$LOG_DIR/immortalwrt_build_${CONFIG_NAME}_${BUILD_TIME_STAMP_FULL}.log"

    echo -e "\n================== 编译开始 =================="
    echo "日志文件: $BUILD_LOG_PATH"
    
    local TARGET_DIR_NAME="${FW_TYPE}"
    if [ "$FW_TYPE" == "lede" ]; then TARGET_DIR_NAME="lede"; fi
    local CURRENT_SOURCE_DIR_LOCAL="$SOURCE_ROOT/$TARGET_DIR_NAME"

    # --- 1.5 编译前清理提示 (源码目录存在则询问) ---
    if [ -d "$CURRENT_SOURCE_DIR_LOCAL" ]; then
        if [[ -z "${IS_BATCH_BUILD+x}" ]]; then
            while true; do
                echo -e "\n--- 1.5 编译前清理/重置 ---"
                echo "检测到现有源码目录: $CURRENT_SOURCE_DIR_LOCAL"
                read -p "是否删除该目录，以进行全新拉取 (y/n, 默认为 n)? " should_delete
                
                if [[ "$should_delete" =~ ^[Yy]$ ]]; then
                    echo "正在删除源码目录..."
                    rm -rf "$CURRENT_SOURCE_DIR_LOCAL"
                    echo "✅ 删除完成。"
                    break
                elif [[ "$should_delete" =~ ^[Nn]$ ]] || [[ -z "$should_delete" ]]; then
                    echo "跳过删除，将对现有源码进行 Git Pull 更新。"
                    break
                else
                    echo "无效输入。"
                fi
            done
        fi
    fi
    
    # --- 2. 源码拉取/更新 ---
    if ! clone_or_update_source "$FW_TYPE" "$FW_BRANCH"; then
        echo "错误: 源码拉取/更新失败。" >> "$BUILD_LOG_PATH"
        error_handler 1
        return 1
    fi
    
    # 确定编译线程数
    local JOBS_N=$(determine_compile_jobs)
    
    # 🔥 V4.9.27 核心修正：所有编译相关操作都在这个唯一的子 Shell 内完成
    (
        local CURRENT_SOURCE_DIR="$CURRENT_SOURCE_DIR_LOCAL"
        # 强制切换到源码目录，确保后续所有相对路径操作的正确性
        if ! cd "$CURRENT_SOURCE_DIR"; then echo "错误: 无法进入源码目录。"; exit 1; fi

        # V4.9.16: 环境隔离
        export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" 
        unset CC CXX LD AR AS CPPFLAGS CFLAGS CXXFLAGS LDFLAGS
        
        local GIT_COMMIT_ID=$(git rev-parse --short HEAD 2>/dev/null || echo "UnknownCommit")
        
        # --- 2.5 编译前源码清理 (内嵌并强制在子Shell内执行) ---
        while true; do
            echo -e "\n## 🛡️ 源码清理模式选择 (在当前目录: $PWD)"
            echo "-----------------------------------------------------"
            echo "1) 🧹 **标准清理 (make clean)**"
            echo "2) 彻底清理 (make dirclean)"
            echo "3) 🔄 跳过清理"
            echo "-----------------------------------------------------"
            # 注意：在子 Shell 中，交互式读取用户输入可能需要 /dev/tty
            read -p "请选择清理模式 (1/2/3): " clean_choice
            
            case $clean_choice in
                1) make clean || { echo "❌ 错误: make clean 失败。"; exit 1; }; echo "✅ 标准清理完成。"; break ;;
                2) make dirclean || { echo "❌ 错误: make dirclean 失败。"; exit 1; }; echo "✅ 彻底清理完成。"; break ;;
                3) echo "--- 跳过清理 ---"; break ;;
                *) echo "无效选择。请重新输入。"; sleep 1 ;;
            esac
        done
        
        # --- 3. Feeds/插件/配置阶段开始 ---
        run_custom_injections "${VARS[CUSTOM_INJECTIONS]}" "100" "$CURRENT_SOURCE_DIR"
        
        if [[ "${VARS[ENABLE_QMODEM]}" == "y" ]]; then
            echo -e "\n--- 配置 QModem feed ---"
            if ! grep -q "qmodem" feeds.conf.default; then
                echo 'src-git qmodem https://github.com/FUjr/QModem.git;main' >> feeds.conf.default
            fi
        fi
        
        echo -e "\n--- 更新 feeds ---"
        # 目录已经在 $CURRENT_SOURCE_DIR，无需再次检查
        chmod +x ./scripts/feeds 2>/dev/null # 强制授权
        ./scripts/feeds update -a && ./scripts/feeds install -a || { echo "❌ 错误: feeds 更新/安装失败。"; exit 1; }
        
        echo -e "\n--- 拉取额外插件 ---"
        local plugin_string="${VARS[EXTRA_PLUGINS]}"
        local plugins_array_string=$(echo "$plugin_string" | tr '##' '\n')
        local plugins
        IFS=$'\n' read -rd '' -a plugins <<< "$plugins_array_string"

        for plugin_cmd in "${plugins[@]}"; do
            [[ -z "$plugin_cmd" ]] && continue
            
            if [[ "$plugin_cmd" =~ git\ clone\ (.*)\ (.*) ]]; then
                repo_url="${BASH_REMATCH[1]}"
                target_path="${BASH_REMATCH[2]}"
                if [ -d "$target_path" ]; then
                    (cd "$target_path" && git pull) || echo "警告: 插件 $target_path git pull 失败，但继续。"
                else
                    $plugin_cmd || { echo "❌ 错误: 插件 $target_path 克隆失败。"; exit 1; }
                fi
            else
                eval "$plugin_cmd" || { echo "❌ 错误: 插件命令执行失败。"; exit 1; }
            fi
        done

        if [[ "${VARS[ENABLE_TURBOACC]}" == "y" ]]; then
            echo -e "\n--- 配置 Turboacc ---"
            local turboacc_script="$EXTRA_SCRIPT_DIR/add_turboacc.sh"
            if [ ! -f "$turboacc_script" ]; then
                curl -sSL https://raw.githubusercontent.com/chenmozhijin/turboacc/luci/add_turboacc.sh -o "$turboacc_script"
            fi
            # 确保在源码目录下运行
            bash "$turboacc_script" || echo "❌ 警告: Turboacc 配置脚本执行失败。继续编译。"
        fi

        # ----------------------------------------------------------------
        # 配置文件导入逻辑
        # ----------------------------------------------------------------
        echo -e "\n--- 导入用户配置 ---"
        local config_file_name="${VARS[CONFIG_FILE_NAME]}"
        local source_config_path="$USER_CONFIG_DIR/$config_file_name"
        local CONFIG_FILE_EXTENSION="${config_file_name##*.}"
        
        if [ ! -f "$source_config_path" ]; then
            echo "❌ 致命错误：用户配置文件不存在！路径：$source_config_path"
            exit 1
        fi

        if [[ "$CONFIG_FILE_EXTENSION" == "diffconfig" ]]; then
            echo "正在复制 $config_file_name 到 defconfig..."
            cp "$source_config_path" "defconfig" || { echo "❌ 错误: 复制 defconfig 失败。"; exit 1; }
            echo "正在执行 make defconfig 以扩展 diffconfig 配置..."
            make defconfig || { echo "❌ 错误: make defconfig 失败。"; exit 1; }
        else
            echo "正在复制 $config_file_name 到 .config..."
            cp "$source_config_path" ".config" || { echo "❌ 错误: 复制 .config 失败。"; exit 1; }
            echo "正在执行 make defconfig 以确认配置..."
            make defconfig || { echo "❌ 错误: make defconfig 失败。"; exit 1; }
        fi
        
        if [ ! -f .config ]; then
            echo "❌ 致命错误：导入配置后 .config 文件未生成！"
            exit 1
        fi
        # ----------------------------------------------------------------

        run_custom_injections "${VARS[CUSTOM_INJECTIONS]}" "850" "$CURRENT_SOURCE_DIR"
        
        # 强制清除 NAT 冲突
        sed -i 's/CONFIG_PACKAGE_kmod-ipt-fullconenat=y/# CONFIG_PACKAGE_kmod-ipt-fullconenat is not set/g' .config
        sed -i 's/CONFIG_PACKAGE_kmod-nat-fullconenat=y/# CONFIG_PACKAGE_kmod-nat-fullconenat is not set/g' .config
        sed -i 's/CONFIG_PACKAGE_luci-app-fullconenat=y/# CONFIG_PACKAGE_luci-app-fullconenat is not set/g' .config

        echo -e "\n--- 开始编译 (线程: $JOBS_N) ---"
        echo "最终运行 make defconfig 确保所有依赖正确..."
        make defconfig || { echo "❌ 错误: 最终 make defconfig 失败。"; exit 1; }
        
        local CCACHE_SETTINGS=""
        if command -v ccache &> /dev/null; then
            CCACHE_SETTINGS="CC=\"ccache gcc\" CXX=\"ccache g++\""
        fi
        
        make -j"$JOBS_N" V=s $CCACHE_SETTINGS 2>&1 | tee "$BUILD_LOG_PATH"
        
        if [ ${PIPESTATUS[0]} -ne 0 ]; then
            echo -e "\n================== 编译失败 ❌ =================="
            exit 1
        else
            echo -e "\n================== 编译成功 ✅ =================="
            archive_firmware_and_logs "$CONFIG_NAME" "$FW_TYPE" "$FW_BRANCH" "$BUILD_TIME_STAMP_FULL" "$GIT_COMMIT_ID" "$BUILD_LOG_PATH"
            exit 0
        fi
    )
    
    local EXECUTE_STATUS=$?
    if [ "$EXECUTE_STATUS" -ne 0 ]; then
        error_handler "$EXECUTE_STATUS"
        return 1
    fi
    return 0
}

# --- 5. 工具 ---

determine_compile_jobs() {
    local cpu_cores=$(nproc)
    local total_mem_gb=$(free -g | awk 'NR==2{print $2}')
    local cpu_jobs=$(( (cpu_cores * 3) / 2 ))
    local mem_jobs=$(( total_mem_gb / 2 ))
    
    local final_jobs="$cpu_jobs"
    if [ "$mem_jobs" -lt "$cpu_jobs" ] && [ "$mem_jobs" -gt 0 ]; then
        final_jobs="$mem_jobs"
    fi
    if [ "$final_jobs" -lt 1 ]; then final_jobs=1; fi
    echo "$final_jobs"
}

error_handler() {
    local exit_code=$1
    if [ "$exit_code" -ne 0 ]; then
        echo -e "\n🚨 错误 (Code: $exit_code)"
        local FAILED_TARGET=$(grep -E "make\[[0-9]+\]: \*\*\* \[.*\] Error [0-9]" "$BUILD_LOG_PATH" | tail -n 1 | sed -E 's/^.*\[(.*)\] Error [0-9].*$/\1/')
        if [ -n "$FAILED_TARGET" ]; then
            echo "🔥 失败目标: **$FAILED_TARGET**"
            grep -B 5 -A 5 -F "$FAILED_TARGET" "$BUILD_LOG_PATH" | tail -n 10
        else
            tail -n 10 "$BUILD_LOG_PATH"
        fi
        echo "日志: $BUILD_LOG_PATH"
        
        if [[ -z "${IS_BATCH_BUILD+x}" ]]; then
            read -p "按回车返回菜单，或输入 'debug' 进入 Shell: " action
            if [[ "$action" == "debug" ]]; then
                cd "$CURRENT_SOURCE_DIR" && /bin/bash
            fi
        else
            return 1
        fi
    fi
    return 0
}

manage_plugins_menu() {
    local -n vars_array=$1
    while true; do
        clear
        echo "🧩 插件管理"
        local current_plugins="${vars_array[EXTRA_PLUGINS]}"
        local plugins_array=($(echo "$current_plugins" | tr '##' '\n' | sed '/^$/d'))
        
        for i in "${!plugins_array[@]}"; do echo "$((i+1))) ${plugins_array[$i]}"; done
        echo "A) 添加  D) 删除  R) 返回"
        read -p "选择: " choice
        case $choice in
            A|a)
                read -p "输入 Git 命令: " cmd
                if [[ -n "$cmd" ]]; then
                    if [[ -z "$current_plugins" ]]; then vars_array[EXTRA_PLUGINS]="$cmd"; else vars_array[EXTRA_PLUGINS]="${current_plugins}##${cmd}"; fi
                fi ;;
            D|d)
                read -p "序号: " idx
                if [[ "$idx" =~ ^[0-9]+$ ]] && [ "$idx" -le "${#plugins_array[@]}" ]; then
                    unset plugins_array[$((idx-1))]
                    local new_str=""; local first=true
                    for item in "${plugins_array[@]}"; do
                        if $first; then new_str="$item"; first=false; else new_str="${new_str}##${item}"; fi
                    done
                    vars_array[EXTRA_PLUGINS]="$new_str"
                fi ;;
            R|r) return ;;
        esac
    done
}

manage_injections_menu() {
    local -n vars_array=$1
    while true; do
        clear
        echo "🧩 脚本注入管理"
        local current="${vars_array[CUSTOM_INJECTIONS]}"
        local inj_array=($(echo "$current" | tr '##' '\n' | sed '/^$/d'))
        
        for i in "${!inj_array[@]}"; do echo "$((i+1))) ${inj_array[$i]}"; done
        echo "A) 添加本地  U) 添加远程  D) 删除  R) 返回"
        read -p "选择: " choice
        
        case $choice in
            A|a)
                local files=("$EXTRA_SCRIPT_DIR"/*.sh); local i=1; local file_list=()
                for f in "${files[@]}"; do
                    if [ -f "$f" ]; then echo "$i) $(basename "$f")"; file_list[$i]="$(basename "$f")"; i=$((i+1)); fi
                done
                
                read -p "脚本序号: " idx; local sname="${file_list[$idx]}"
                if [[ -n "$sname" ]]; then
                    read -p "阶段 (100/850): " stage
                    local new="$sname $stage"
                    if [[ -z "$current" ]]; then vars_array[CUSTOM_INJECTIONS]="$new"; else vars_array[CUSTOM_INJECTIONS]="${current}##${new}"; fi
                fi ;;
            U|u)
                read -p "URL: " url
                if [[ "$url" =~ ^http ]]; then
                    local fname=$(basename "$url")
                    curl -sSL "$url" -o "$EXTRA_SCRIPT_DIR/$fname" && echo "下载成功"
                    read -p "阶段 (100/850): " stage
                    local new="$fname $stage"
                    if [[ -z "$current" ]]; then vars_array[CUSTOM_INJECTIONS]="$new"; else vars_array[CUSTOM_INJECTIONS]="${current}##${new}"; fi
                fi ;;
            D|d)
                read -p "序号: " idx
                if [[ "$idx" =~ ^[0-9]+$ ]] && [ "$idx" -le "${#inj_array[@]}" ]; then
                    unset inj_array[$((idx-1))]
                    local new_str=""; local first=true
                    for item in "${inj_array[@]}"; do
                        if $first; then new_str="$item"; first=false; else new_str="${new_str}##${item}"; fi
                    done
                    vars_array[CUSTOM_INJECTIONS]="$new_str"
                fi ;;
            R|r) return ;;
        esac
    done
}

archive_firmware_and_logs() {
    local CONFIG_NAME="$1"
    local FW_TYPE="$2"
    local FW_BRANCH="$3"
    local BUILD_TIME_STAMP_FULL="$4"
    local GIT_COMMIT_ID="$5"
    local BUILD_LOG_PATH="$6"

    echo -e "\n--- 归档固件和日志 ---"
    
    local TARGET_DIR_NAME="${FW_TYPE}"
    if [ "$FW_TYPE" == "lede" ]; then TARGET_DIR_NAME="lede"; fi
    local CURRENT_SOURCE_DIR="$SOURCE_ROOT/$TARGET_DIR_NAME"

    # 查找固件文件
    local FIRMWARE_DIR="$CURRENT_SOURCE_DIR/bin/targets/"
    
    # 尝试找到唯一的子目录作为实际的固件目录
    local target_subdir=$(find "$FIRMWARE_DIR" -mindepth 2 -maxdepth 2 -type d | head -n 1)

    if [ -d "$target_subdir" ]; then
        local ARCHIVE_NAME="${FW_TYPE}_${CONFIG_NAME}_${FW_BRANCH}_${BUILD_TIME_STAMP_FULL}_${GIT_COMMIT_ID}"
        local FINAL_OUTPUT_ZIP="$OUTPUT_DIR/$ARCHIVE_NAME.zip"
        
        # 复制日志到固件目录
        cp "$BUILD_LOG_PATH" "$target_subdir/build.log"
        
        # 压缩固件目录和日志
        (
            cd "$target_subdir/../"
            zip -r "$FINAL_OUTPUT_ZIP" "$(basename "$target_subdir")" "build.log"
        )
        
        echo "✅ 固件包已归档到: $FINAL_OUTPUT_ZIP"
    else
        echo "❌ 警告: 找不到固件输出目录 ($FIRMWARE_DIR)。仅保存日志。"
        cp "$BUILD_LOG_PATH" "$LOG_DIR/${ARCHIVE_NAME}_log_only.log"
    fi
}

run_custom_injections() {
    local INJECTIONS_STRING="$1"
    local TARGET_STAGE="$2"
    local CURRENT_SOURCE_DIR="$3"
    
    if [[ -z "$INJECTIONS_STRING" ]]; then 
        return
    fi
    
    local injections_array_string=$(echo "$INJECTIONS_STRING" | tr '##' '\n')
    local injections
    IFS=$'\n' read -rd '' -a injections <<< "$injections_array_string"
    
    for injection in "${injections[@]}"; do
        if [[ -z "$injection" ]]; then continue; fi
        
        local script_name=$(echo "$injection" | awk '{print $1}')
        local stage=$(echo "$injection" | awk '{print $2}')
        local full_script_path="$EXTRA_SCRIPT_DIR/$script_name"
        
        if [ "$stage" == "$TARGET_STAGE" ] && [ -f "$full_script_path" ]; then
            echo -e "\n--- ⚙️ 运行脚本注入 [阶段 $stage]: $script_name ---"
            (
                cd "$CURRENT_SOURCE_DIR" || exit 1
                bash "$full_script_path" || { echo "❌ 注入脚本 $script_name 执行失败。"; exit 1; }
            )
            if [ $? -ne 0 ]; then
                echo "🚨 致命错误：脚本注入失败，停止编译。"
                exit 1
            fi
        fi
    done
}

# --- 脚本入口 ---
check_and_install_dependencies
main_menu
