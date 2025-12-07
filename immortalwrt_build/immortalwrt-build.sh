#!/bin/bash

# ==========================================================
# 🔥 ImmortalWrt/OpenWrt 固件编译管理脚本 V4.9.15 (纯 .config 编译版)
# - 移除 make menuconfig 流程，旨在解决 "没有规则可制作目标 menuconfig" 的错误。
# - 用户必须在 $USER_CONFIG_DIR 中提供完整的 .config 或 .diffconfig 文件。
# - 修复了 clone_or_update_source 中强制全量克隆的逻辑。
# ==========================================================

# --- 变量定义 ---

# 1. 核心构建根目录
BUILD_ROOT="$HOME/immortalwrt_builder_root"

# 2. 定义所有子目录（绝对路径）
CONFIGS_DIR="$BUILD_ROOT/profiles"          # 存放 *.conf 配置文件
SOURCE_ROOT="$BUILD_ROOT/source_root"       # 源码的根目录（统一根，实际源码在子目录）
LOG_DIR="$BUILD_ROOT/logs"                  # 存放编译日志
USER_CONFIG_DIR="$BUILD_ROOT/user_configs"  # 存放用户自定义的 .config 或 .diffconfig 文件
EXTRA_SCRIPT_DIR="$BUILD_ROOT/custom_scripts" # 存放自定义注入的本地脚本
OUTPUT_DIR="$BUILD_ROOT/output"             # 存放最终固件的输出目录

# 编译日志文件名格式和时间戳 (在 execute_build 中重新定义)
BUILD_LOG_PATH=""
BUILD_TIME_STAMP=$(date +%Y%m%d_%H%M)

# 所有配置变量的名称列表
CONFIG_VAR_NAMES=(FW_TYPE FW_BRANCH CONFIG_FILE_NAME EXTRA_PLUGINS CUSTOM_INJECTIONS ENABLE_QMODEM ENABLE_TURBOACC)

# 动态变量，用于在编译和配置阶段传递当前源码目录
CURRENT_SOURCE_DIR=""


# --- 核心目录和依赖初始化 ---

# 1.1 检查并安装编译依赖
check_and_install_dependencies() {
    echo "## 检查并安装编译依赖..."
    # 添加 lscpu 和 free 等工具依赖的软件包，确保检测功能可用
    local DEPENDENCIES="ack antlr3 asciidoc autoconf automake autopoint binutils bison build-essential bzip2 ccache clang cmake cpio curl device-tree-compiler ecj fastjar flex gawk gettext gcc-multilib g++-multilib git gnutls-dev gperf haveged help2man intltool libc6-dev-i386 libelf-dev libglib2.0-dev libgmp3-dev libmpc-dev libmpfr-dev libncurses-dev libpython3-dev libreadline-dev libssl-dev libtool libyaml-dev libz-dev lld llvm lrzsz mkisofs msmtp nano ninja-build p7zip p7zip-full patch pkgconf python3 python3-pip python3-ply python3-pyelftools qemu-utils re2c rsync scons squashfs-tools subversion swig texinfo uglifyjs upx-ucl unzip vim wget xmlto xxd zlib1g-dev zstd uuid-runtime zip procps util-linux"
    
    if command -v apt-get &> /dev/null; then
        sudo apt-get update
        sudo apt-get install -y $DEPENDENCIES
    elif command -v yum &> /dev/null; then
        echo "请手动检查并安装以下依赖：$DEPENDENCIES"
    else
        echo -e "\n**警告:** 无法自动安装依赖。请确保以下软件包已安装:\n$DEPENDENCIES"
        read -p "按任意键继续 (风险自负)..."
    fi
    echo "## 依赖检查完成。"
    sleep 2
}

# 1.2 检查并创建目录
ensure_directories() {
    echo "## 检查并创建构建目录..."
    mkdir -p "$CONFIGS_DIR"
    mkdir -p "$SOURCE_ROOT" # 使用 SOURCE_ROOT
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
        echo "        🔥 ImmortalWrt 固件编译管理脚本 V4.9.15 🔥"
        echo "             (纯 .config 配置模式)"
        echo "====================================================="
        echo "1) 🌟 新建机型配置 (Create New Configuration)"
        echo "2) ⚙️ 选择/编辑/删除机型配置 (Select/Edit/Delete Configuration)"
        echo "3) 🚀 编译固件 (Start Build Process)"
        echo "4) 🚪 退出 (Exit)"
        echo "-----------------------------------------------------"
        read -p "请选择功能 (1-4): " choice
        
        case $choice in
            1) create_config ;;
            2) select_config ;;
            3) start_build_process ;;
            4) echo "退出脚本。再见！"; exit 0 ;;
            *) echo "无效选择，请重新输入。"; sleep 1 ;;
        esac
    done
}


# --- 3. 配置管理 (Create/Edit/Delete) ---

# 3.1 新建配置 (已移除 menuconfig 引导)
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
        
        # 1. 基础配置交互
        config_interaction "$new_name" "new"
        
        # 2. 移除 menuconfig 引导
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
    # 检查数组是否为空或只包含一个不存在的文件名（通配符失败的情况）
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

# 3.3 实际配置交互界面 (已移除 menuconfig 选项)
config_interaction() {
    local CONFIG_NAME="$1"
    local MODE="$2"
    local CONFIG_FILE="$CONFIGS_DIR/$CONFIG_NAME.conf"
    
    # 使用关联数组存储变量
    declare -A config_vars
    
    # 临时数组用于从配置文件加载
    if [ "$MODE" == "edit" ] && [ -f "$CONFIG_FILE" ]; then
        # 逐行读取配置文件并赋值给关联数组
        while IFS='=' read -r key value; do
            if [[ "$key" =~ ^[A-Z_]+$ ]]; then
                # 去除引号并赋值
                config_vars["$key"]=$(echo "$value" | sed 's/^"//;s/"$//')
            fi
        done < "$CONFIG_FILE"
    fi
    
    # 默认值设置 
    : ${config_vars[FW_TYPE]:="immortalwrt"}
    : ${config_vars[FW_BRANCH]:="master"}
    # 默认使用 .config 引导用户
    : ${config_vars[CONFIG_FILE_NAME]:="$CONFIG_NAME.config"} 
    : ${config_vars[EXTRA_PLUGINS]:=""}
    : ${config_vars[CUSTOM_INJECTIONS]:=""}
    : ${config_vars[ENABLE_QMODEM]:="n"}
    : ${config_vars[ENABLE_TURBOACC]:="n"}
    
    # 交互循环
    while true; do
        clear
        echo "====================================================="
        echo "     📝 ${MODE^} 配置: ${CONFIG_NAME}"
        echo "   (请确保在 $USER_CONFIG_DIR 提供了配置好的 .config 文件)"
        echo "====================================================="
        
        # --- 主配置 ---
        echo "1. 固件类型/版本: ${config_vars[FW_TYPE]} / ${config_vars[FW_BRANCH]}"
        echo "2. **配置 (config) 文件名**: ${config_vars[CONFIG_FILE_NAME]}"
        local plugin_count=0
        if [[ -n "${config_vars[EXTRA_PLUGINS]}" ]]; then
            plugin_count=$(echo "${config_vars[EXTRA_PLUGINS]}" | grep -o '##' | wc -l | awk '{print $1 + 1}')
        fi
        echo "3. 额外插件列表: $plugin_count 条"
        
        echo "4. 🧩 脚本注入管理: $(echo "${config_vars[CUSTOM_INJECTIONS]}" | tr '##' '\n' | grep -v '^$' | wc -l) 条"
        
        # --- 内置功能 ---
        echo "5. [${config_vars[ENABLE_QMODEM]^^}] 内置 Qmodem"
        echo "6. [${config_vars[ENABLE_TURBOACC]^^}] 内置 Turboacc"
        
        # --- 新增功能项 (已移除 7) ---
        echo -e "\n7. ⚠️ **检查配置文件的位置和名称**"

        echo "-----------------------------------------------------"
        echo "S) 保存配置并返回 | R) 放弃修改并返回"
        read -p "请选择要修改的项 (1-7, S/R): " sub_choice
        
        case $sub_choice in
            1) # 固件类型/版本
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
            2) # 配置差异文件名
                echo "文件必须存放在 $USER_CONFIG_DIR 目录下。"
                echo "**请确保文件名以 .config 或 .diffconfig 结尾。**"
                read -p "请输入配置文件名称 (当前: ${config_vars[CONFIG_FILE_NAME]}): " config_file_input
                config_vars[CONFIG_FILE_NAME]="${config_file_input:-$CONFIG_NAME.config}"
                ;;
            3) # 额外插件列表
                echo -e "\n--- 额外插件地址列表 (请使用 '##' 分隔) ---"
                echo "格式范例: git clone.../plugin1 package/target1##git clone.../plugin2 package/target2"
                echo "当前列表:"
                echo "${config_vars[EXTRA_PLUGINS]}"
                echo "---"
                read -p "请输入新的插件命令，使用 '##' 分隔（或留空清空）: " new_plugins_input
                # 清理输入内容以确保它适合单行存储
                new_plugins_input=$(echo "$new_plugins_input" | sed 's/^"//;s/"$//')
                # 统一分隔符，并去除多余的空格
                new_plugins_input=$(echo "$new_plugins_input" | tr -d '\n' | sed 's/  */ /g' | sed 's/##/##/g' | sed 's/ *##/##/g')

                config_vars[EXTRA_PLUGINS]="$new_plugins_input"
                ;;
            4) # 脚本注入管理 
                echo -e "\n--- 🧩 自定义脚本注入列表 ---"
                echo "请输入注入命令，格式: [脚本路径/URL] [阶段ID (如 100/850)] (一行一个, 输入 'END' 结束输入):"
                local new_injections=""
                # 打印当前已有的注入命令供参考
                if [[ -n "${config_vars[CUSTOM_INJECTIONS]}" ]]; then
                    echo "--- 当前已配置 ---"
                    echo "${config_vars[CUSTOM_INJECTIONS]}" | tr '##' '\n'
                    echo "--------------------"
                fi
                echo "请输入新内容 (或留空表示清空):"
                
                # 读取多行输入并收集到 new_injections 变量
                local current_line=""
                while IFS= read -r current_line; do
                    if [[ "$current_line" == "END" ]]; then
                        break
                    fi
                    if [[ -n "$current_line" ]]; then
                        new_injections+="$current_line"$'\n'
                    fi
                done </dev/stdin

                # 将多行输入转换为 '##' 分隔的单行字符串
                config_vars[CUSTOM_INJECTIONS]=$(echo "$new_injections" | sed '/^$/d' | tr '\n' '##' | sed 's/##$//')
                ;;
            5) config_vars[ENABLE_QMODEM]=$([[ "${config_vars[ENABLE_QMODEM]}" == "y" ]] && echo "n" || echo "y") ;;
            6) config_vars[ENABLE_TURBOACC]=$([[ "${config_vars[ENABLE_TURBOACC]}" == "y" ]] && echo "n" || echo "y") ;;
            7) # 检查配置文件的位置和名称
                local config_path="$USER_CONFIG_DIR/${config_vars[CONFIG_FILE_NAME]}"
                if [ -f "$config_path" ]; then
                    echo -e "\n✅ 文件存在: $config_path"
                    echo "文件类型: $(grep -q "^CONFIG_" "$config_path" && echo ".config/.diffconfig" || echo "未知")"
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
            *)
                echo "无效选择，请重新输入。"
                sleep 1
                ;;
        esac
    done
}

# 3.4 清理源码目录 (使用 cd)
clean_source_dir() {
    local CONFIG_NAME="$1"
    local CONFIG_FILE="$CONFIGS_DIR/$CONFIG_NAME.conf"
    
    # 从配置文件读取类型和分支
    local FW_TYPE=$(grep 'FW_TYPE="' "$CONFIG_FILE" | cut -d'"' -f2)
    local FW_BRANCH=$(grep 'FW_BRANCH="' "$CONFIG_FILE" | cut -d'"' -f2)
    local CURRENT_SOURCE_DIR="$SOURCE_ROOT/$FW_TYPE/$FW_BRANCH"

    if [ ! -d "$CURRENT_SOURCE_DIR" ]; then
        echo "警告: 源码目录不存在，无需清理。"
        return 0
    fi
    
    # 使用子 Shell 隔离 cd 操作
    (
        cd "$CURRENT_SOURCE_DIR" || { echo "错误: 无法进入源码目录进行清理。"; return 1; }

        while true; do
            clear
            echo "## 🛡️ 源码清理模式选择"
            echo "当前源码目录: $CURRENT_SOURCE_DIR"
            echo "-----------------------------------------------------"
            echo "1) 🧹 **标准清理 (make clean)**:"
            echo "   - 建议用于同一目标平台/配置的快速重新编译。"
            echo "2) 彻底清理 (make dirclean):"
            echo "   - 建议用于切换目标平台或主要固件版本。"
            echo "3) 🔄 跳过清理，直接开始编译。"
            echo "-----------------------------------------------------"
            read -p "请选择清理模式 (1/2/3): " clean_choice

            case $clean_choice in
                1)
                    echo -e "\n--- 正在执行 [make clean] 标准清理 ---"
                    if command -v make &> /dev/null && [ -f Makefile ]; then
                        make clean || { echo "错误: make clean 失败。"; exit 1; }
                        echo "✅ 标准清理完成。"
                    else
                        echo "警告: 源码目录似乎不完整，跳过 make clean。"
                    fi
                    exit 0
                    ;;
                2)
                    echo -e "\n--- 正在执行 [make dirclean] 彻底清理 ---"
                    if command -v make &> /dev/null && [ -f Makefile ]; then
                        make dirclean || { echo "错误: make dirclean 失败。"; exit 1; }
                        echo "✅ 彻底清理完成。"
                    else
                        echo "警告: 源码目录似乎不完整，跳过 make dirclean。"
                    fi
                    exit 0
                    ;;
                3)
                    echo "--- 跳过清理，继续编译 ---"
                    exit 0
                    ;;
                *)
                    echo "无效选择，请重新输入。"
                    sleep 1
                    ;;
            esac
        done
    ) # 子 Shell 结束

    return $?
}

# 3.6 保存配置到文件 (兼容增强版，不使用 local -n)
save_config_from_array() {
    local config_name="$1"
    local -n vars_array="$2" # 使用命名引用获取关联数组内容
    local config_file="$CONFIGS_DIR/$config_name.conf"
    
    > "$config_file"
    
    # 遍历所有预设的变量名，从关联数组中获取值并写入文件
    for key in "${CONFIG_VAR_NAMES[@]}"; do
        if [[ -n "${vars_array[$key]+x}" ]]; then
            local value="${vars_array[$key]}"
            echo "$key=\"$value\"" >> "$config_file"
        fi
    done
}

# 3.7 删除配置
delete_config() {
    local CONFIG_NAME="$1"
    local CONFIG_FILE="$CONFIGS_DIR/$CONFIG_NAME.conf"
    
    clear
    echo "## 🗑️ 确认删除配置"
    echo "您确定要永久删除配置文件: **$CONFIG_FILE** 吗?"
    
    read -p "请再次输入配置名称 [$CONFIG_NAME] 进行确认: " confirm_name
    
    if [[ "$confirm_name" == "$CONFIG_NAME" ]]; then
        if [ -f "$CONFIG_FILE" ]; then
            rm -f "$CONFIG_FILE"
            # 清理用户配置文件夹中以 CONFIG_NAME 开头的所有 config 或 diffconfig 文件
            find "$USER_CONFIG_DIR" -maxdepth 1 -type f -name "$CONFIG_NAME.*config" -delete
            
            echo -e "\n✅ 配置 **[$CONFIG_NAME]** (和对应的配置差异文件) 已成功删除。"
        else
            echo -e "\n❌ 错误: 配置文件不存在。"
        fi
    else
        echo -e "\n操作取消：输入名称不匹配。"
    fi
    read -p "按任意键返回..."
}

# 3.8 配置校验和防呆功能 
validate_build_config() {
    local -n VARS=$1
    local config_name="$2"
    local error_count=0
    
    echo -e "\n--- 🔍 开始验证配置: $config_name ---"
    
    local valid_types=("openwrt" "immortalwrt" "lede")
    if ! printf '%s\n' "${valid_types[@]}" | grep -q "^${VARS[FW_TYPE]}$"; then
        echo "❌ 错误：无效的固件类型: ${VARS[FW_TYPE]}"
        error_count=$((error_count + 1))
    fi
    if [[ -z "${VARS[FW_BRANCH]}" ]]; then
        echo "❌ 错误：固件分支 (FW_BRANCH) 不能为空。"
        error_count=$((error_count + 1))
    fi

    if [[ -z "${VARS[CONFIG_FILE_NAME]}" ]]; then
        echo "❌ 错误：配置文件名 (CONFIG_FILE_NAME) 不能为空。"
        error_count=$((error_count + 1))
    else
        local config_path="$USER_CONFIG_DIR/${VARS[CONFIG_FILE_NAME]}"
        if [[ ! -f "$config_path" ]]; then
            echo "❌ 错误：找不到配置/差异配置 (.config 或 .diffconfig) 文件: $config_path"
            echo "请确保该文件已存在于 $USER_CONFIG_DIR 中。"
            error_count=$((error_count + 1))
        else
            echo "✅ 配置 (.config/.diffconfig) 文件存在: $config_path"
        fi
    fi
    
    if [[ -n "${VARS[CUSTOM_INJECTIONS]}" ]]; then
        local injections_array_string=$(echo "${VARS[CUSTOM_INJECTIONS]}" | tr '##' '\n')
        
        # 修复 IFS 导致的数组读取问题
        local injections
        IFS=$'\n' read -rd '' -a injections <<< "$injections_array_string"
        
        for injection in "${injections[@]}"; do
            if [[ -z "$injection" ]]; then continue; fi
            local script_path_url=$(echo "$injection" | awk '{print $1}')
            
            if [[ ! "$script_path_url" =~ ^(http|https):// ]]; then
                local full_script_path="$EXTRA_SCRIPT_DIR/$script_path_url"
                if [[ ! -f "$full_script_path" ]]; then
                    echo "❌ 错误：本地注入脚本不存在: $full_script_path"
                    error_count=$((error_count + 1))
                fi
            fi
        done
    fi

    echo -e "\n--- 校验结果 ---"
    if [ "$error_count" -gt 0 ]; then
        echo "🚨 发现 $error_count 个严重错误，编译无法开始。"
        return 1
    else
        echo "✅ 配置校验通过，一切就绪。"
        return 0
    fi
}

# 4.0 源码管理和拉取 (强制全量浅克隆 V4.9.15)
clone_or_update_source() {
    local FW_TYPE="$1"
    local FW_BRANCH="$2"
    local config_name="$3"

    local REPO=""
    case $FW_TYPE in
        openwrt) REPO="https://github.com/openwrt/openwrt" ;;
        immortalwrt) REPO="https://github.com/immortalwrt/immortalwrt" ;;
        lede) REPO="https://github.com/coolsnowwolf/lede" ;;
        *) echo "错误: 固件类型未知 ($FW_TYPE)。" >> "$BUILD_LOG_PATH" && return 1 ;;
    esac

    # --- 核心修改：动态生成当前源码目录 ---
    local CURRENT_SOURCE_DIR="$SOURCE_ROOT/$FW_TYPE/$FW_BRANCH"
    echo "--- 源码将被隔离到: $CURRENT_SOURCE_DIR ---"
    # ----------------------------------------
    
    echo -e "\n--- 4.0 源码拉取/更新 (模式: **全量浅克隆**) ---"

    if [ -d "$CURRENT_SOURCE_DIR/.git" ]; then
        echo "源码目录已存在，尝试切换/更新分支..."
        
        (
            cd "$CURRENT_SOURCE_DIR" || exit 1
            git fetch origin "$FW_BRANCH" --depth 1 || echo "警告: 浅拉取失败，尝试常规拉取..."
            git checkout "$FW_BRANCH" || (echo "错误: 分支切换失败。" >> "$BUILD_LOG_PATH" && exit 1)
            
            # 使用 git pull 来更新
            git pull origin "$FW_BRANCH" || echo "警告: Git pull 失败，但继续。"
        ) || return 1

    else
        # 确保父目录存在
        mkdir -p "$SOURCE_ROOT/$FW_TYPE"
        
        # 如果目标目录存在但不是 Git 仓库，先清空它（防止旧目录残留）
        if [ -d "$CURRENT_SOURCE_DIR" ]; then
             rm -rf "$CURRENT_SOURCE_DIR"
        fi

        echo "正在进行 **全量浅克隆 (git clone --depth 1)** 到 $CURRENT_SOURCE_DIR..."
        
        # **关键修复：强制使用全量浅克隆来确保文件完整性**
        git clone "$REPO" -b "$FW_BRANCH" "$CURRENT_SOURCE_DIR" --depth 1 || (echo "错误: Git 克隆失败。" >> "$BUILD_LOG_PATH" && return 1)
    fi
    
    # --- 增加验证步骤 ---
    if [ ! -f "$CURRENT_SOURCE_DIR/Makefile" ]; then
        echo "🚨 严重错误: 在源码目录 ($CURRENT_SOURCE_DIR) 中未找到核心 Makefile。"
        return 1
    fi
    if [ ! -d "$CURRENT_SOURCE_DIR/scripts" ]; then
        echo "🚨 严重错误: 源码目录 ($CURRENT_SOURCE_DIR) 中缺少 scripts 目录。"
        return 1
    fi
    echo "✅ 源码拉取/更新完成，核心文件校验通过。"
    
    # 将动态路径导出，供后续函数使用
    export CURRENT_SOURCE_DIR
    return 0
}

# --- 4. 编译流程 (Build) ---

# 4.1 编译入口
start_build_process() {
    clear
    echo "## 🚀 编译固件"
    
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
            
            # 传递数组引用
            if validate_build_config SELECTED_VARS "$SELECTED_NAME"; then
                 read -p "配置校验通过，按任意键开始编译..."
                 execute_build "$SELECTED_NAME" "${SELECTED_VARS[FW_TYPE]}" "${SELECTED_VARS[FW_BRANCH]}" SELECTED_VARS
            else
                 echo "配置校验失败，请修改后重试。"
                 read -p "按任意键返回..."
            fi
        fi
    else
        echo "无效选择。返回主菜单。"
        sleep 1
    fi
}


# 4.3 实际执行编译的函数
execute_build() {
    local CONFIG_NAME="$1"
    local FW_TYPE="$2"
    local FW_BRANCH="$3"
    local -n VARS=$4 # 引用配置变量数组
    
    # 在函数开始时重新定义日志路径以包含时间戳
    local BUILD_TIME_STAMP_FULL=$(date +%Y%m%d_%H%M%S)
    BUILD_LOG_PATH="$LOG_DIR/immortalwrt_build_${CONFIG_NAME}_${BUILD_TIME_STAMP_FULL}.log"

    echo -e "\n================== 编译开始 =================="
    echo "日志文件: $BUILD_LOG_PATH"
    
    # --- 1. 源码拉取/更新 ---
    echo -e "\n--- 1. 源码拉取/更新 ---"
    
    # 运行源码拉取，会导出 CURRENT_SOURCE_DIR
    if ! clone_or_update_source "$FW_TYPE" "$FW_BRANCH" "$CONFIG_NAME"; then
        echo "错误: 源码拉取/更新失败，编译中止。" >> "$BUILD_LOG_PATH"
        error_handler 1
        return 1
    fi
    
    # 获取 CURRENT_SOURCE_DIR 变量
    local CURRENT_SOURCE_DIR_LOCAL="$CURRENT_SOURCE_DIR"

    # 1.5 插入清理步骤
    if ! clean_source_dir "$CONFIG_NAME"; then
        error_handler 1
        return 1
    fi
    
    # 获取智能线程数
    local JOBS_N=$(determine_compile_jobs)
    
    # 使用子 shell 执行所有编译相关操作
    (
        # 在子shell中重新定义 CURRENT_SOURCE_DIR
        local CURRENT_SOURCE_DIR="$CURRENT_SOURCE_DIR_LOCAL"
        
        if ! cd "$CURRENT_SOURCE_DIR"; then
            echo "错误: 无法进入源码目录进行配置/编译。" >> "$BUILD_LOG_PATH"
            exit 1
        fi

        # 获取 Git Commit ID 用于固件命名
        local GIT_COMMIT_ID=$(git rev-parse --short HEAD 2>/dev/null || echo "UnknownCommit")
        
        # --- 2. 注入点: Stage 100 (源码拉取后) ---
        run_custom_injections "${VARS[CUSTOM_INJECTIONS]}" "100" "$CURRENT_SOURCE_DIR"
        
        # --- 3. 配置 QModem feed (如果启用) ---
        if [[ "${VARS[ENABLE_QMODEM]}" == "y" ]]; then
            echo -e "\n--- 3. 配置 QModem feed ---"
            if ! grep -q "qmodem" feeds.conf.default; then
                echo 'src-git qmodem https://github.com/FUjr/QModem.git;main' >> feeds.conf.default
            else
                echo "QModem feed 已存在，跳过添加。"
            fi
        fi
        
        # --- 4. 更新/安装 feeds ---
        echo -e "\n--- 4. 更新 feeds ---"
        ./scripts/feeds update -a || (echo "错误: feeds update 失败。" >> "$BUILD_LOG_PATH" && exit 1)
        ./scripts/feeds install -a || (echo "错误: feeds install 失败。" >> "$BUILD_LOG_PATH" && exit 1)
        
        # --- 5. 拉取额外插件 ---
        echo -e "\n--- 5. 拉取额外插件 ---"
        local plugin_string="${VARS[EXTRA_PLUGINS]}"
        local plugins_array_string=$(echo "$plugin_string" | tr '##' '\n')
        
        local plugins
        IFS=$'\n' read -rd '' -a plugins <<< "$plugins_array_string"

        for plugin_cmd in "${plugins[@]}"; do
            if [[ -z "$plugin_cmd" ]]; then continue; fi
            
            if [[ "$plugin_cmd" =~ git\ clone\ (.*)\ (.*) ]]; then
                repo_url="${BASH_REMATCH[1]}"
                target_path="${BASH_REMATCH[2]}"
                
                if [ -d "$target_path" ]; then
                    echo "插件目录 $target_path 已存在，尝试更新..."
                    (cd "$target_path" && git pull) || echo "警告: 插件 $target_path 更新失败，跳过。"
                else
                    echo "正在拉取插件: $plugin_cmd"
                    $plugin_cmd || echo "警告: 插件拉取失败，跳过。"
                fi
            else
                echo "警告: 插件命令格式不规范，直接执行: $plugin_cmd"
                eval "$plugin_cmd" || echo "警告: 插件命令执行失败，跳过。"
            fi
        done

        # --- 6. 配置 Turboacc ---
        if [[ "${VARS[ENABLE_TURBOACC]}" == "y" ]]; then
            echo -e "\n--- 6. 配置 Turboacc ---"
            local turboacc_script="$EXTRA_SCRIPT_DIR/add_turboacc.sh"
            if [ ! -f "$turboacc_script" ]; then
                curl -sSL https://raw.githubusercontent.com/chenmozhijin/turboacc/luci/add_turboacc.sh -o "$turboacc_script"
            fi
            (bash "$turboacc_script") || (echo "错误: Turboacc 配置失败。" >> "$BUILD_LOG_PATH" && exit 1)
        fi

        # --- 7. 导入用户配置重建 .config ---
        local config_file_name="${VARS[CONFIG_FILE_NAME]}"
        local source_config_path="$USER_CONFIG_DIR/$config_file_name"
        
        echo -e "\n--- 7. 导入用户配置 ($(basename "$source_config_path")) 重建 .config ---"
        
        local CONFIG_FILE_EXTENSION="${config_file_name##*.}"
        
        if [[ "$CONFIG_FILE_EXTENSION" == "config" ]]; then
            # 导入完整的 .config
            echo "导入类型: 完整的 .config 文件。将复制到 .config 并运行 make defconfig 修复依赖。"
            cp "$source_config_path" ".config"
            make defconfig || (echo "错误: make defconfig 失败。" >> "$BUILD_LOG_PATH" && exit 1)
        elif [[ "$CONFIG_FILE_EXTENSION" == "diffconfig" ]]; then
            # 导入差异配置 .diffconfig
            echo "导入类型: .diffconfig 文件。将复制到 defconfig 并运行 make defconfig。"
            cp "$source_config_path" "defconfig"
            make defconfig || (echo "错误: make defconfig 失败。" >> "$BUILD_LOG_PATH" && exit 1)
        else
            # 默认视为 .config 导入
            echo "警告: 配置文件后缀未知，默认视为 .config 处理。"
            cp "$source_config_path" ".config"
            make defconfig || (echo "错误: make defconfig 失败。" >> "$BUILD_LOG_PATH" && exit 1)
        fi

        
        # --- 8. 注入点: Stage 850 (导入 config 后) ---
        run_custom_injections "${VARS[CUSTOM_INJECTIONS]}" "850" "$CURRENT_SOURCE_DIR"
        
        # --- 8.5 强制清除 NAT 冲突配置 ---
        echo -e "\n--- 8.5 强制清除 NAT 冲突配置 ---"
        
        # 兼容性处理：防止 kmod-ipt-fullconenat 和 kmod-nat-fullconenat 冲突
        sed -i 's/CONFIG_PACKAGE_kmod-ipt-fullconenat=y/# CONFIG_PACKAGE_kmod-ipt-fullconenat is not set/g' .config
        sed -i 's/CONFIG_PACKAGE_kmod-nat-fullconenat=y/# CONFIG_PACKAGE_kmod-nat-fullconenat is not set/g' .config
        sed -i 's/CONFIG_PACKAGE_luci-app-fullconenat=y/# CONFIG_PACKAGE_luci-app-fullconenat is not set/g' .config

        # --- 9. 配置/编译 ---
        echo -e "\n--- 9. 开始编译 (线程数: $JOBS_N) ---"
        
        # 核心编译命令，输出到日志文件
        # V4.9.15 确保在编译前运行 make oldconfig 来修复配置依赖
        echo "正在运行 make oldconfig 修复依赖关系..."
        make oldconfig || (echo "警告: make oldconfig 失败，但继续。" >> "$BUILD_LOG_PATH")
        
        make -j"$JOBS_N" V=s 2>&1 | tee "$BUILD_LOG_PATH"
        
        local BUILD_STATUS=${PIPESTATUS[0]}

        if [ "$BUILD_STATUS" -ne 0 ]; then
            echo -e "\n================== 编译失败 ❌ =================="
            exit 1
        else
            echo -e "\n================== 编译成功 ✅ =================="
            # 调用归档函数 (在子 shell 中完成归档工作)
            archive_firmware_and_logs "$CONFIG_NAME" "$FW_TYPE" "$FW_BRANCH" "$BUILD_TIME_STAMP_FULL" "$GIT_COMMIT_ID" "$BUILD_LOG_PATH"
            exit 0
        fi
    ) # 子 Shell 结束

    local EXECUTE_STATUS=$?
    if [ "$EXECUTE_STATUS" -ne 0 ]; then
        error_handler "$EXECUTE_STATUS"
        return 1
    fi
    return 0
}

# --- 5. 工具和辅助函数 (省略未修改的辅助函数) ---

# 5.1 智能确定编译线程数
determine_compile_jobs() {
    echo -e "\n--- 🧠 性能检测与线程数自适应 ---"
    
    # 1. 获取 CPU 核心数
    local cpu_cores=1
    if command -v nproc &> /dev/null; then
        cpu_cores=$(nproc)
    elif command -v lscpu &> /dev/null; then
        cpu_cores=$(lscpu | grep '^CPU(s):' | awk '{print $2}')
    fi
    
    # 2. 获取系统总内存 (GB)
    local total_mem_bytes=0
    if command -v free &> /dev/null; then
        # 'free -b' 输出的第二行是 Total Memory (Bytes)
        total_mem_bytes=$(free -b | awk 'NR==2{print $2}')
    else
        echo "警告: 缺少 'free' 命令，无法检测内存。将使用保守线程数 1。"
        echo "计算结果: make -j1"
        return 1
    fi
    
    # 转换为 GB
    local total_mem_gb=$(echo "scale=2; $total_mem_bytes / 1024 / 1024 / 1024" | bc)
    
    # 3. 计算基于 CPU 的线程数 (核心数 * 1.5, 向上取整)
    local cpu_jobs=$(echo "($cpu_cores * 1.5) / 1" | bc) # 整数除法，近似向上取整
    if (( $(echo "$cpu_cores * 1.5 > $cpu_jobs" | bc -l) )); then
        cpu_jobs=$((cpu_jobs + 1))
    fi
    
    # 4. 计算基于内存的线程数 (总内存(GB) / 2 GB/线程, 向下取整)
    local mem_jobs=$(echo "$total_mem_gb / 2" | bc)
    
    # 5. 取两者中的最小值作为最终的安全线程数
    local final_jobs="$cpu_jobs"
    if [ "$mem_jobs" -lt "$cpu_jobs" ]; then
        final_jobs="$mem_jobs"
    fi
    
    # 确保线程数不低于 1
    if [ "$final_jobs" -lt 1 ]; then
        final_jobs=1
    fi
    
    echo "系统信息: 核心数: **$cpu_cores** | 总内存: **$total_mem_gb GB**"
    echo "CPU 建议线程数 (N * 1.5): $cpu_jobs"
    echo "内存限制线程数 (M / 2GB): $mem_jobs"
    echo "最终安全线程数: **make -j$final_jobs**"
    
    echo "$final_jobs"
}

# 5.2 错误处理函数
error_handler() {
    local exit_code=$1
    if [ "$exit_code" -ne 0 ]; then
        echo -e "\n🚨 编译过程发生错误 (Exit Code: $exit_code)!"
        
        echo -e "\n--- 详细错误日志 (最后100行) ---"
        # 查找错误行并在其上下输出 5 行上下文
        tail -n 100 "$BUILD_LOG_PATH" | grep -E "ERROR|Failed|fatal|make\[[0-9]+\]: \*\*\* \[.*\] Error [0-9]" -A 5 -B 5
        echo -e "\n--------------------------------------------------"
        echo "**请查看日志文件 '$BUILD_LOG_PATH' 获取详细信息。**"
        
        # 检查是否在批处理模式下
        if [[ -z "${CONFIGS_TO_BUILD+x}" ]]; then
            while true; do
                echo -e "\n请选择下一步操作："
                echo "1) 🔙 返回主菜单 (Return to Main Menu)"
                echo "2) 🐚 进入 Shell 调试 (Jump to $CURRENT_SOURCE_DIR for debugging)"
                read -p "选择 (1/2): " action
                
                case "$action" in
                    1) 
                        return 1
                        ;;
                    2)
                        echo -e "\n进入 Shell 调试模式。调试完成后，输入 'exit' 返回主菜单。"
                        if [ -d "$CURRENT_SOURCE_DIR" ]; then
                            cd "$CURRENT_SOURCE_DIR"
                        fi
                        /bin/bash
                        return 1
                        ;;
                    *)
                        echo "无效选择，请重新输入。"
                        ;;
                esac
            done
        else
            return 1
        fi
    fi
    return 0
}
# 5.3 运行自定义注入脚本 (使用 cd)
run_custom_injections() {
    local all_injections="$1"
    local target_stage_id="$2"
    local CURRENT_SOURCE_DIR="$3" # 接收动态源码目录
    local executed_count=0
    
    if [[ -z "$all_injections" ]]; then return 0; fi
    
    echo -e "\n--- [Stage $target_stage_id] 执行自定义注入脚本 ---"
    
    (
    # 传递 $CURRENT_SOURCE_DIR 变量给子脚本
    
    cd "$EXTRA_SCRIPT_DIR" || exit 1
    
    local injections_array_string=$(echo "$all_injections" | tr '##' '\n')
    
    local injections
    IFS=$'\n' read -rd '' -a injections <<< "$injections_array_string"
    
    for injection in "${injections[@]}"; do
        if [[ -z "$injection" ]]; then continue; fi
        
        local script_command=$(echo "$injection" | awk '{print $1}')
        local stage_id=$(echo "$injection" | awk '{print $2}')
        
        if [[ "$stage_id" != "$target_stage_id" ]]; then continue; fi
        
        executed_count=$((executed_count + 1))
        local script_name
        local full_command
        
        # 使用 sed 替换命令中的 $CURRENT_SOURCE_DIR 变量
        # 脚本路径/URL 必须是命令的第一个参数，因此需要额外处理
        full_command=$(echo "$injection" | sed "s/\$CURRENT_SOURCE_DIR/$CURRENT_SOURCE_DIR/g")
        local command_prefix=$(echo "$full_command" | awk '{print $1}')
        
        if [[ "$command_prefix" =~ ^(http|https):// ]]; then
            script_name=$(basename "$command_prefix")
            echo "Stage $stage_id: 正在拉取远程脚本: $command_prefix"
            curl -sSL "$command_prefix" -o "$script_name" || (echo "警告: 远程脚本 $script_name 拉取失败，跳过。" && continue)
            chmod +x "$script_name"
            # 提取除 URL 和 Stage ID 以外的所有参数
            local script_args=$(echo "$full_command" | cut -d' ' -f 3-)
            
            echo "Stage $stage_id: 正在执行远程脚本: $script_name $script_args"
            # 子脚本会在 $EXTRA_SCRIPT_DIR 中运行
            ./"$script_name" $script_args || echo "警告: 远程脚本 $script_name 执行失败。"
        else
            script_name="$command_prefix"
            if [ -f "$script_name" ]; then
                # 提取除脚本名和 Stage ID 以外的所有参数
                local script_args=$(echo "$full_command" | cut -d' ' -f 3-)
                
                echo "Stage $stage_id: 正在执行本地脚本: $script_name $script_args"
                chmod +x "$script_name"
                # 直接执行整个命令 (例如: bash inject_autorun_a.sh 192.168.1.1 /path/to/source 850)
                eval "$full_command" || echo "警告: 本地脚本 $script_name 执行失败。"
            else
                echo "警告: Stage $stage_id: 本地脚本 $script_name 不存在，跳过。"
            fi
        fi 
    done
    
    if [ "$executed_count" -eq 0 ]; then
        echo "Stage $target_stage_id: 没有匹配的自定义脚本执行。"
    fi
    )
}

# 5.5 归档固件和日志文件 (使用 cd)
archive_firmware_and_logs() {
    local CONFIG_NAME="$1"
    local FW_TYPE="$2"
    local FW_BRANCH="$3"
    local BUILD_TIME_STAMP="$4"
    local GIT_COMMIT_ID="$5"
    local BUILD_LOG_PATH="$6"

    local CURRENT_SOURCE_DIR="$SOURCE_ROOT/$FW_TYPE/$FW_BRANCH"
    local TIMESTAMP_COMMIT="${BUILD_TIME_STAMP}_${GIT_COMMIT_ID}"
    local TARGET_DIR="$CURRENT_SOURCE_DIR/bin/targets" # 使用隔离的源码目录

    echo -e "\n--- 10. 固件文件管理与归档 ---"
    
    local ARCH_SUBDIR=""
    # 查找 targets 目录下第一级子目录（平台）和第二级子目录（子平台/固件类型）
    ARCH_SUBDIR=$(find "$TARGET_DIR" -maxdepth 2 -type d ! -name "packages" -name "*" | tail -n 1)
    
    local TEMP_ARCHIVE_ROOT="$BUILD_ROOT/temp_archive"
    local TEMP_ARCHIVE_DIR="$TEMP_ARCHIVE_ROOT/$CONFIG_NAME-$TIMESTAMP_COMMIT"
    mkdir -p "$TEMP_ARCHIVE_DIR/firmware"
    
    local FIRMWARE_COUNT=0
    
    if [ -d "$ARCH_SUBDIR" ]; then
        # 查找目标目录下所有常见的固件格式文件
        local FIRMWARE_FILES=$(find "$ARCH_SUBDIR" -maxdepth 1 -type f \
            -name "*.bin" -o -name "*.img" -o -name "*.itb" -o -name "*.trx" \
            -o -name "*.elf" -o -name "*.tar.gz" -o -name "*.ipk" -o -name "*.iso" \
            ! -name "*buildinfo*" -a ! -name "*manifest*" -a ! -name "*signatures*" -a ! -name "*ext4-factory*" -a ! -name "*metadata*")
        
        for file in $FIRMWARE_FILES; do
            FIRMWARE_COUNT=$((FIRMWARE_COUNT + 1))
            local FILENAME=$(basename "$file")
            
            # 使用更规范的命名方式：FWTYPE_BRANCH_CONFIGNAME_COMMITID_ORIGINALFILENAME
            local NEW_FILENAME="${FW_TYPE}_${FW_BRANCH}_${CONFIG_NAME}_${GIT_COMMIT_ID}_${FILENAME}" 
            
            echo "发现固件: $FILENAME"

            cp "$file" "$TEMP_ARCHIVE_DIR/firmware/$NEW_FILENAME" || echo "警告: 复制文件失败: $FILENAME"
        done
        
        if [ "$FIRMWARE_COUNT" -eq 0 ]; then
             echo "⚠️ 警告: 未找到任何有效的固件文件。"
        fi
    else
        echo "❌ 错误: 找不到目标固件目录 ($TARGET_DIR 的子目录)。"
    fi
    
    echo "复制编译日志文件..."
    cp "$BUILD_LOG_PATH" "$TEMP_ARCHIVE_DIR/" || echo "警告: 复制日志文件失败。"

    local ARCHIVE_NAME="${FW_TYPE}_${FW_BRANCH}_${CONFIG_NAME}_${TIMESTAMP_COMMIT}.zip"
    local FINAL_ARCHIVE_PATH="$OUTPUT_DIR/$ARCHIVE_NAME"
    
    echo "开始创建归档文件: $ARCHIVE_NAME"
    
    (
        if cd "$TEMP_ARCHIVE_ROOT"; then
            # 压缩临时目录
            zip -r "$FINAL_ARCHIVE_PATH" "$(basename "$TEMP_ARCHIVE_DIR")" > /dev/null
            rm -rf "$TEMP_ARCHIVE_ROOT"
            exit 0
        else
            echo "错误: 无法进入临时目录进行打包。"
            exit 1
        fi
    )
    
    if [ -f "$FINAL_ARCHIVE_PATH" ]; then
        echo -e "\n✅ 固件和日志已成功打包到归档文件:"
        echo "**$FINAL_ARCHIVE_PATH**"
        echo "共归档 $FIRMWARE_COUNT 个固件文件。"
        return 0
    else
        echo "❌ 错误: zip 文件创建失败。"
        return 1
    fi
}


# --- 脚本执行入口 ---

check_and_install_dependencies
main_menu
