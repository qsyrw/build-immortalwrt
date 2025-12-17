#!/bin/bash

# ==========================================================
# 🔥 ImmortalWrt Build Script V7.0.0 (V4.9.37 交互回归)
# ----------------------------------------------------------
# 核心说明：
# 1. UI 风格：完全回归 V4.9.37 原始菜单，无多余装饰。
# 2. 配置逻辑：支持通过序号直接选择文件，source 方式加载变量。
# 3. 性能修复：针对 20 核 CPU 自动计算最佳编译线程 (J)。
# 4. 环境修复：修复内存显示、配置文件读取失效等 V6 系列 Bug。
# ==========================================================

# --- 1. 颜色与环境初始化 ---
G='\033[0;32m'; R='\033[0;31m'; Y='\033[1;33m'; B='\033[0;34m'; N='\033[0m'

# 定义固定目录 (基于 V4 习惯)
BASE_DIR="$HOME/immortalwrt_builder"
PROFILES_DIR="$BASE_DIR/profiles"
CONFIGS_DIR="$BASE_DIR/configs"
LOGS_DIR="$BASE_DIR/logs"

mkdir -p "$PROFILES_DIR" "$CONFIGS_DIR" "$LOGS_DIR"

# --- 2. 系统信息检测 (修复内存读取) ---
update_sys_info() {
    # 修复内存显示：使用 free -m 兼容更多 Linux 发行版
    TOTAL_MEM=$(free -m | awk '/^Mem:/{print $2}')
    CPU_CORES=$(nproc)
    
    # 智能并发数计算：每 2GB 内存分配 1 个线程，防止 20 核 CPU 内存溢出
    J_NUM=$((TOTAL_MEM / 2048))
    [[ $J_NUM -gt $CPU_CORES ]] && J_NUM=$CPU_CORES
    [[ $J_NUM -lt 1 ]] && J_NUM=1
}

# --- 3. 功能函数 (完全沿用 V4.9.37 交互) ---

# [功能 1] 新建配置
create_profile() {
    clear
    echo -e "${B}=== 🌟 新建机型配置 ===${N}"
    read -p "请输入机型名称 (如 R4S): " name
    [[ -z "$name" ]] && return
    
    local pf="$PROFILES_DIR/$name.conf"
    [[ -f "$pf" ]] && { echo -e "${R}配置已存在!${N}"; sleep 1; return; }

    echo -e "\n${Y}请填写编译信息 (直接回车用默认值):${N}"
    read -p "仓库URL [https://github.com/immortalwrt/immortalwrt.git]: " url
    url=${url:-"https://github.com/immortalwrt/immortalwrt.git"}
    
    read -p "编译分支 [openwrt-21.02]: " branch
    branch=${branch:-"openwrt-21.02"}
    
    read -p ".config 文件名 [$name.config]: " cfg_name
    cfg_name=${cfg_name:-"$name.config"}

    # 写入 V4 格式的变量文件
    cat > "$pf" <<EOF
REPO_URL="$url"
FW_BRANCH="$branch"
CONFIG_FILE="$cfg_name"
EOF
    
    echo -e "\n${G}✅ 配置已保存到 profiles 文件夹${N}"
    read -p "是否现在编辑 .config 硬件配置? (y/n): " op
    [[ "$op" == "y" ]] && nano "$CONFIGS_DIR/$cfg_name"
}

# [功能 2] 编辑/删除配置
edit_profile() {
    clear
    echo -e "${B}=== 📝 编辑/删除配置 ===${N}"
    local files=($(ls "$PROFILES_DIR"/*.conf 2>/dev/null))
    if [ ${#files[@]} -eq 0 ]; then
        echo "暂无配置文件。"
        sleep 1; return
    fi

    for i in "${!files[@]}"; do
        echo -e "$((i+1))) ${G}$(basename "${files[$i]}" .conf)${N}"
    done
    read -p "请选择序号 (0返回): " num
    [[ "$num" == "0" || -z "$num" ]] && return
    
    local target="${files[$((num-1))]}"
    [[ ! -f "$target" ]] && return

    # 加载变量
    source "$target"

    echo -e "\n${Y}正在操作: $(basename "$target" .conf)${N}"
    echo "1. 编辑变量 (.conf)"
    echo "2. 编辑硬件配置 (.config)"
    echo "3. 🗑️  删除整个配置"
    read -p "请输入指令: " op
    
    case $op in
        1) nano "$target" ;;
        2) nano "$CONFIGS_DIR/$CONFIG_FILE" ;;
        3) rm "$target" && echo "已删除"; sleep 1 ;;
    esac
}

# [功能 3] 启动执行编译
run_build() {
    clear
    echo -e "${B}=== 🚀 启动机型编译 ===${N}"
    local files=($(ls "$PROFILES_DIR"/*.conf 2>/dev/null))
    [[ ${#files[@]} -eq 0 ]] && { echo "无配置"; sleep 1; return; }

    for i in "${!files[@]}"; do
        echo -e "$((i+1))) ${G}$(basename "${files[$i]}" .conf)${N}"
    done
    read -p "请选择要编译的机型序号: " num
    
    local target="${files[$((num-1))]}"
    [[ ! -f "$target" ]] && return

    # 加载配置变量
    source "$target"
    
    # 源码存放路径
    local build_dir="$HOME/immortalwrt_source"
    local log_file="$LOGS_DIR/build_$(basename "$target" .conf)_$(date +%Y%m%d).log"

    echo -e "\n${G}>>> 步骤 1: 检查源码环境...${N}"
    if [ ! -d "$build_dir" ]; then
        git clone "$REPO_URL" -b "$FW_BRANCH" "$build_dir"
    fi
    
    cd "$build_dir" || { echo "无法进入目录"; return; }
    
    echo -e "${G}>>> 步骤 2: 同步源码与 Feeds...${N}"
    git pull
    ./scripts/feeds update -a && ./scripts/feeds install -a

    echo -e "${G}>>> 步骤 3: 加载配置文件...${N}"
    if [ -f "$CONFIGS_DIR/$CONFIG_FILE" ]; then
        cp "$CONFIGS_DIR/$CONFIG_FILE" .config
        make defconfig
    else
        echo -e "${Y}未发现 .config，将进入默认编译模式${N}"
        make defconfig
    fi

    echo -e "\n${Y}>>> 步骤 4: 开始全速编译 (线程数: $J_NUM)${N}"
    echo -e "日志监控: tail -f $log_file\n"
    
    # 核心编译指令
    make -j$J_NUM V=s 2>&1 | tee "$log_file"

    if [ ${PIPESTATUS[0]} -eq 0 ]; then
        echo -e "\n${G}⭐ 编译完成！固件在 bin/targets 目录下。${N}"
    else
        echo -e "\n${R}❌ 编译失败，请查看日志分析原因。${N}"
    fi
    read -p "按回车键返回..."
}

# --- 4. 主菜单 (完全还原 V4.9.37 UI) ---
while true; do
    update_sys_info
    clear
    echo -e "${G}========================================${N}"
    echo -e "${G}    ImmortalWrt 编译工具 V7.0.0 Stable  ${N}"
    echo -e "${G}========================================${N}"
    echo -e " CPU核心: $CPU_CORES    |  系统内存: ${TOTAL_MEM}MB"
    echo -e " 推荐并发: $J_NUM线程  |  状态: 正常运行"
    echo -e "----------------------------------------"
    echo -e "  1) 🌟 新建机型配置"
    echo -e "  2) 📝 编辑/删除配置"
    echo -e "  3) 🚀 启动执行编译"
    echo -e "  4) 🛠️  环境依赖安装"
    echo -e "  0) 🚪 退出脚本"
    echo -e "----------------------------------------"
    read -p "请输入功能序号: " cmd

    case $cmd in
        1) create_profile ;;
        2) edit_profile ;;
        3) run_build ;;
        4) 
            echo "正在安装编译所需环境..."
            sudo apt update && sudo apt install -y build-essential libncurses5-dev gawk git gettext libssl-dev xsltproc wget unzip python3
            read -p "环境准备就绪，按回车继续..."
            ;;
        0|q|Q) exit 0 ;;
        *) echo -e "${R}输入错误!${N}"; sleep 1 ;;
    esac
done
