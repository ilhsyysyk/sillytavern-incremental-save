#!/bin/bash
#
# SillyTavern 增量保存 + 图片缓存 - 一键卸载脚本
# 适用版本: SillyTavern 1.18.0
#
# 用法（三种方式任选）:
#   ./uninstall.sh                 交互式向导: 选择 Docker / 本地卸载方式, 逐步引导
#   ./uninstall.sh --docker [容器名]   跳过选择, 直接从 Docker 容器卸载(默认容器名: sillytavern)
#   ./uninstall.sh --local [目录]      跳过选择, 直接从本地目录卸载(默认: 当前目录)
#

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCHES_DIR="$SCRIPT_DIR/patches"

EXPECTED_VERSION="1.18.0"

info()  { echo -e "${GREEN}[信息]${NC} $1"; }
warn()  { echo -e "${YELLOW}[注意]${NC} $1"; }
error() { echo -e "${RED}[错误]${NC} $1"; exit 1; }
step()  { echo -e "${CYAN}┌─▶ $1${NC}"; }
divider() { echo "----------------------------------------------"; }

# 自动搜索本机可能的 SillyTavern 安装目录(以 server.js + public/script.js 为识别标志)
find_st_dirs() {
    local -a candidates=(
        "$PWD" "$PWD/SillyTavern" "$PWD/sillytavern" "$PWD/SillyTavern-release" "$PWD/sillytavern-release"
        "$SCRIPT_DIR/SillyTavern" "$SCRIPT_DIR/sillytavern"
        /opt/SillyTavern /opt/sillytavern
        /srv/SillyTavern /srv/sillytavern
        /var/www/SillyTavern /var/www/sillytavern
        /usr/local/SillyTavern /usr/local/sillytavern
        /home/*/SillyTavern /home/*/sillytavern
        /root/SillyTavern /root/sillytavern
    )
    local d norm
    local -a found=()
    for d in "${candidates[@]}"; do
        if [ -f "$d/server.js" ] && [ -f "$d/public/script.js" ]; then
            norm="$(cd "$d" 2>/dev/null && pwd)" && found+=("$norm")
        fi
    done
    printf '%s\n' "${found[@]}" | sort -u
}

# ─── Docker 卸载流程 ─────────────────────────────────────────────────

uninstall_docker() {
    local CONTAINER="$1"

    echo ""
    divider
    echo "  SillyTavern 性能补丁卸载 (Docker 模式)"
    divider

    # 1. 检查容器是否存在
    step "第 1 步: 检查容器 '$CONTAINER'..."
    if ! docker inspect "$CONTAINER" &>/dev/null; then
        echo ""
        error "找不到容器 '$CONTAINER'。
  请先执行 docker ps 查看你实际的容器名, 然后用 --docker <容器名> 重试,
  或在交互模式下重新输入正确的容器名。"
    fi
    info "容器在线 ✓"
    divider

    # 2. 检查/安装容器内的 patch 工具
    step "第 2 步: 检查容器内的 patch 工具..."
    if docker exec "$CONTAINER" sh -c "command -v patch" &>/dev/null; then
        info "容器已有 patch ✓"
    else
        warn "容器缺少 patch 命令, 正在自动安装..."
        if docker exec "$CONTAINER" sh -c "command -v apk" &>/dev/null; then
            docker exec "$CONTAINER" sh -c "apk add --no-cache patch"
        elif docker exec "$CONTAINER" sh -c "command -v apt-get" &>/dev/null; then
            docker exec "$CONTAINER" sh -c "apt-get update -qq && apt-get install -y -qq patch"
        else
            error "无法自动安装 patch, 请手动执行以下命令后重试:
  docker exec $CONTAINER sh -c \"apk add --no-cache patch\""
        fi
        info "patch 安装完成 ✓"
    fi
    divider

    # 3. 检查是否安装了补丁
    step "第 3 步: 检查补丁是否存在..."
    ALREADY=$(docker exec "$CONTAINER" sh -c "grep -c 'save-append' /home/node/app/src/endpoints/chats.js 2>/dev/null || true" | tail -1)
    if [ -z "$ALREADY" ] || [ "$ALREADY" = "0" ]; then
        warn "容器中未检测到补丁痕迹(可能已经卸载过), 脚本将继续执行清理。"
    else
        info "检测到补丁, 开始卸载 ✓"
    fi
    divider

    # 4. 用户确认
    read -r -p "即将从容器 '$CONTAINER' 卸载, 按回车继续, 或输入 n 取消: " CONFIRM
    if [ "$CONFIRM" = "n" ] || [ "$CONFIRM" = "N" ]; then
        echo "已取消卸载。"
        exit 0
    fi

    # 5. 上传补丁文件到容器
    step "第 4 步: 上传补丁文件到容器..."
    docker cp "$PATCHES_DIR" "$CONTAINER:/tmp/_inc_save_patches"
    info "上传完成 ✓"
    divider

    # 6. 反向应用补丁(每个失败都只是警告, 不中断)
    step "第 5 步: 反向应用补丁..."
    PATCH_FILES=(tokenizers.patch chats.patch server-startup.patch group-chats.patch script.patch chats.server.patch)
    for pf in "${PATCH_FILES[@]}"; do
        if docker exec "$CONTAINER" sh -c "cd /home/node/app && patch -R -p1 --dry-run < /tmp/_inc_save_patches/$pf" &>/dev/null; then
            docker exec "$CONTAINER" sh -c "cd /home/node/app && patch -R -p1 < /tmp/_inc_save_patches/$pf"
            info "补丁 $pf 已还原 ✓"
        else
            warn "补丁 $pf 无需还原(可能未安装过)"
        fi
    done

    # 7. 删除新增的文件(图片代理端点)
    step "第 6 步: 删除新增文件(image-proxy.js)..."
    docker exec "$CONTAINER" rm -f /home/node/app/src/endpoints/image-proxy.js
    info "已删除 ✓"
    divider

    # 8. 清理临时文件
    docker exec "$CONTAINER" rm -rf /tmp/_inc_save_patches

    # 9. 重启容器
    step "第 7 步: 重启容器..."
    docker restart "$CONTAINER" >/dev/null
    sleep 3
    if [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER")" = "true" ]; then
        info "容器已重启 ✓"
    else
        error "容器重启失败, 请查看日志: docker logs $CONTAINER"
    fi
    divider

    # 10. 最终验证
    step "第 8 步: 最终验证..."
    CHK=$(docker exec "$CONTAINER" sh -c "grep -c 'save-append' /home/node/app/src/endpoints/chats.js 2>/dev/null || true" | tail -1)
    if [ -z "$CHK" ] || [ "$CHK" = "0" ]; then
        info "验证通过 ✓ 补丁已完全卸载, 请浏览器硬刷新 (Ctrl+Shift+R) 确认。"
    else
        warn "仍然检测到 $CHK 处补丁痕迹, 请手动检查或联系管理员。"
    fi
}

# ─── 本地卸载流程 ────────────────────────────────────────────────────

uninstall_local() {
    local ST_DIR="$1"

    echo ""
    divider
    echo "  SillyTavern 性能补丁卸载 (本地模式)"
    divider

    # 1. 检查目录
    step "第 1 步: 检查目录 '$ST_DIR'..."
    if [ ! -f "$ST_DIR/server.js" ]; then
        echo ""
        error "'$ST_DIR' 不是 SillyTavern 安装目录。
  请用 --local <SillyTavern目录> 指定正确路径,
  或在交互模式下重新输入正确的目录路径。"
    fi
    info "目录确认 ✓"
    divider

    # 2. 检查本机 patch
    step "第 2 步: 检查 patch 命令..."
    if ! command -v patch &>/dev/null; then
        error "本机缺少 patch 命令, 请先安装:
  Debian/Ubuntu: sudo apt-get install -y patch
  Alpine:        apk add patch
  CentOS:        sudo yum install -y patch"
    fi
    info "本机已有 patch ✓"
    divider

    # 3. 检查是否安装了补丁
    step "第 3 步: 检查补丁是否存在..."
    if grep -q 'save-append' "$ST_DIR/src/endpoints/chats.js" 2>/dev/null; then
        info "检测到补丁, 开始卸载 ✓"
    else
        warn "未检测到补丁痕迹(可能已经卸载过), 脚本将继续执行清理。"
    fi
    divider

    # 4. 用户确认
    read -r -p "即将从目录 '$ST_DIR' 卸载, 按回车继续, 或输入 n 取消: " CONFIRM
    if [ "$CONFIRM" = "n" ] || [ "$CONFIRM" = "N" ]; then
        echo "已取消卸载。"
        exit 0
    fi

    # 5. 反向应用补丁
    step "第 4 步: 反向应用补丁..."
    PATCH_FILES=(tokenizers.patch chats.patch server-startup.patch group-chats.patch script.patch chats.server.patch)
    for pf in "${PATCH_FILES[@]}"; do
        if (cd "$ST_DIR" && patch -R -p1 --dry-run < "$PATCHES_DIR/$pf") &>/dev/null; then
            (cd "$ST_DIR" && patch -R -p1 < "$PATCHES_DIR/$pf")
            info "补丁 $pf 已还原 ✓"
        else
            warn "补丁 $pf 无需还原(可能未安装过)"
        fi
    done

    # 6. 删除新增文件
    step "第 5 步: 删除新增文件(image-proxy.js)..."
    rm -f "$ST_DIR/src/endpoints/image-proxy.js"
    info "已删除 ✓"
    divider

    # 7. 最终验证
    step "第 6 步: 最终验证..."
    if ! grep -q 'save-append' "$ST_DIR/src/endpoints/chats.js" 2>/dev/null; then
        info "验证通过 ✓ 补丁已完全卸载, 请重启 SillyTavern 并浏览器硬刷新 (Ctrl+Shift+R)。"
    else
        warn "仍然检测到补丁痕迹, 请手动检查或联系管理员。"
    fi
}

# ─── 主入口 ──────────────────────────────────────────────────────────

if [ "$1" = "--docker" ] || [ "$1" = "-d" ]; then
    uninstall_docker "${2:-sillytavern}"
    exit 0
elif [ "$1" = "--local" ] || [ "$1" = "-l" ]; then
    uninstall_local "${2:-.}"
    exit 0
fi

# ─── 交互式向导 ──────────────────────────────────────────────────────

if [ ! -t 0 ]; then
    echo "检测到非交互终端(无法读取输入)。"
    echo "请使用参数直接指定卸载方式:"
    echo "  ./uninstall.sh --docker [容器名]"
    echo "  ./uninstall.sh --local [目录]"
    exit 1
fi

echo ""
echo "=============================================="
echo "  SillyTavern 性能补丁卸载脚本"
echo "  适用版本: $EXPECTED_VERSION"
echo "=============================================="
echo ""
echo "请选择卸载方式:"
echo ""
echo "  [1] Docker 卸载 —— 从运行中的 Docker 容器卸载"
echo "  [2] 本地卸载   —— 从服务器磁盘上的 SillyTavern 目录卸载"
echo "  [3] 退出"
echo ""
read -r -p "请输入数字 [1/2/3]: " CHOICE
echo ""

case "$CHOICE" in
    1)
        echo "您选择了 Docker 卸载"
        echo ""
        read -r -p "请输入容器名(直接回车使用默认值 sillytavern): " CONTAINER
        CONTAINER="${CONTAINER:-sillytavern}"
        uninstall_docker "$CONTAINER"
        ;;
    2)
        echo "您选择了本地卸载"
        echo ""
        step "正在自动搜索本机的 SillyTavern 安装目录..."
        mapfile -t FOUND < <(find_st_dirs)
        ST_DIR=""
        if [ "${#FOUND[@]}" -eq 1 ]; then
            ST_DIR="${FOUND[0]}"
            info "已找到: $ST_DIR"
            read -r -p "使用该目录? 按回车确认, 输入 n 改为手动输入: " CONFIRM
            if [ "$CONFIRM" = "n" ] || [ "$CONFIRM" = "N" ]; then
                ST_DIR=""
            fi
        elif [ "${#FOUND[@]}" -gt 1 ]; then
            echo "找到多个 SillyTavern 安装目录:"
            for i in "${!FOUND[@]}"; do
                echo "  [$((i + 1))] ${FOUND[$i]}"
            done
            read -r -p "请输入编号选择(输入 0 改为手动输入): " SEL
            if [[ "$SEL" =~ ^[0-9]+$ ]] && [ "$SEL" -ge 1 ] && [ "$SEL" -le "${#FOUND[@]}" ]; then
                ST_DIR="${FOUND[$((SEL - 1))]}"
            else
                ST_DIR=""
            fi
        else
            warn "未自动搜索到 SillyTavern 安装目录, 请手动输入路径。"
        fi

        while [ -z "$ST_DIR" ]; do
            read -r -p "请输入 SillyTavern 的完整路径: " ST_DIR
            if [ -z "$ST_DIR" ]; then
                warn "路径不能为空, 请重新输入。"
                ST_DIR=""
                continue
            fi
            if [ ! -f "$ST_DIR/server.js" ]; then
                warn "'$ST_DIR' 不是 SillyTavern 安装目录(未找到 server.js), 请重新输入。"
                ST_DIR=""
                continue
            fi
        done
        ST_DIR="$(cd "$ST_DIR" && pwd)"
        uninstall_local "$ST_DIR"
        ;;
    *)
        echo "已退出。"
        exit 0
        ;;
esac