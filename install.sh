#!/bin/bash
#
# SillyTavern 增量保存 + 图片缓存 - 一键安装脚本
# 适用版本: SillyTavern 1.18.0
#
# 用法（三种方式任选）:
#   ./install.sh                 交互式向导: 选择 Docker / 本地安装方式, 逐步引导
#   ./install.sh --docker [容器名]   跳过选择, 直接安装到 Docker 容器(默认容器名: sillytavern)
#   ./install.sh --local [目录]      跳过选择, 直接安装到本地目录(默认: 当前目录)
#

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCHES_DIR="$SCRIPT_DIR/patches"
NEW_FILES_DIR="$SCRIPT_DIR/new-files"

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

# ─── Docker 安装流程 ─────────────────────────────────────────────────

install_docker() {
    local CONTAINER="$1"

    echo ""
    divider
    echo "  SillyTavern 性能补丁安装 (Docker 模式)"
    divider

    # 1. 检查容器是否存在
    step "第 1 步: 检查容器 '$CONTAINER'..."
    if ! docker inspect "$CONTAINER" &>/dev/null; then
        echo ""
        error "找不到容器 '$CONTAINER'。
  请先执行 docker ps 查看你实际的容器名, 然后用 --docker <容器名> 重试,
  或在交互模式下重新输入正确的容器名。"
    fi

    # 2. 检查容器是否在运行
    if [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER")" != "true" ]; then
        echo ""
        error "容器 '$CONTAINER' 当前未运行。
  请先启动它: docker start $CONTAINER
  再重新运行本脚本。"
    fi
    info "容器在线 ✓"
    divider

    # 3. 检查/安装容器内的 patch 工具(很多镜像默认没有, 会导致安装失败)
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

    # 4. 检查 SillyTavern 版本
    step "第 3 步: 检查 SillyTavern 版本..."
    VER=$(docker exec "$CONTAINER" sh -c "grep '\"version\"' /home/node/app/package.json 2>/dev/null | head -1 | grep -o '[0-9.]*'" || true)
    if [ -z "$VER" ]; then
        warn "无法读取版本号(不影响安装, 继续...)"
    elif [ "$VER" != "$EXPECTED_VERSION" ]; then
        warn "当前版本: $VER, 本补丁适配: $EXPECTED_VERSION
  版本不匹配时补丁很可能安装失败, 建议先确认版本或使用对应版本的补丁。"
    else
        info "版本 $VER ✓ (与补丁匹配)"
    fi
    divider

    # 5. 检查是否已经安装过
    step "第 4 步: 检查是否已安装过补丁..."
    ALREADY=$(docker exec "$CONTAINER" sh -c "grep -c 'save-append' /home/node/app/src/endpoints/chats.js 2>/dev/null || true" | tail -1)
    if [ -n "$ALREADY" ] && [ "$ALREADY" != "0" ]; then
        error "检测到容器中已有补丁痕迹。
  如需重装, 请先运行: ./uninstall.sh --docker $CONTAINER
  卸载完成后再运行本脚本。"
    fi
    info "未安装, 可以继续 ✓"
    divider

    # 6. 用户确认
    read -r -p "即将安装到容器 '$CONTAINER', 按回车继续, 或输入 n 取消: " CONFIRM
    if [ "$CONFIRM" = "n" ] || [ "$CONFIRM" = "N" ]; then
        echo "已取消安装。"
        exit 0
    fi

    # 7. 备份原始文件
    step "第 5 步: 备份原始文件到 backups/ 目录..."
    BACKUP_DIR="$SCRIPT_DIR/backups/$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$BACKUP_DIR"
    docker cp "$CONTAINER:/home/node/app/src/endpoints/chats.js"          "$BACKUP_DIR/chats.server.js"
    docker cp "$CONTAINER:/home/node/app/public/script.js"                "$BACKUP_DIR/script.js"
    docker cp "$CONTAINER:/home/node/app/public/scripts/group-chats.js"   "$BACKUP_DIR/group-chats.js"
    docker cp "$CONTAINER:/home/node/app/public/scripts/chats.js"         "$BACKUP_DIR/chats.js"
    docker cp "$CONTAINER:/home/node/app/src/server-startup.js"           "$BACKUP_DIR/server-startup.js"
    docker cp "$CONTAINER:/home/node/app/public/scripts/tokenizers.js"    "$BACKUP_DIR/tokenizers.js"
    info "备份已保存到: $BACKUP_DIR ✓"
    divider

    # 8. 拷贝补丁和新文件到容器
    step "第 6 步: 上传补丁文件到容器..."
    docker cp "$PATCHES_DIR" "$CONTAINER:/tmp/_inc_save_patches"
    docker cp "$NEW_FILES_DIR" "$CONTAINER:/tmp/_inc_save_new_files"
    info "上传完成 ✓"
    divider

    # 9. 逐个应用补丁(每个补丁都先预检再正式应用)
    step "第 7 步: 应用补丁..."
    PATCH_FILES=(chats.server.patch script.patch group-chats.patch server-startup.patch chats.patch tokenizers.patch)
    for pf in "${PATCH_FILES[@]}"; do
        if docker exec "$CONTAINER" sh -c "cd /home/node/app && patch -p1 --dry-run < /tmp/_inc_save_patches/$pf" &>/dev/null; then
            docker exec "$CONTAINER" sh -c "cd /home/node/app && patch -p1 < /tmp/_inc_save_patches/$pf"
            info "补丁 $pf 应用成功 ✓"
        else
            error "补丁 $pf 应用失败!
  可能原因:
    1. 已安装过(请先运行 ./uninstall.sh 再试)
    2. SillyTavern 版本不是 $EXPECTED_VERSION(请确认版本)
    3. 容器内文件被外部修改过(可在容器里执行 cat /etc/os-release 提供给管理员)"
        fi
    done

    # 10. 复制新文件(图片代理端点)
    step "第 8 步: 部署新文件(image-proxy.js)..."
    docker exec "$CONTAINER" cp /tmp/_inc_save_new_files/image-proxy.js /home/node/app/src/endpoints/image-proxy.js
    info "新文件部署完成 ✓"
    divider

    # 11. 清理临时文件
    docker exec "$CONTAINER" rm -rf /tmp/_inc_save_patches /tmp/_inc_save_new_files

    # 12. 重启容器
    step "第 9 步: 重启容器..."
    docker restart "$CONTAINER" >/dev/null
    sleep 3
    if [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER")" != "true" ]; then
        error "容器重启失败, 请查看日志: docker logs $CONTAINER"
    fi
    info "容器重启完成 ✓"
    divider

    # 13. 最终验证
    step "第 10 步: 最终验证..."
    CHK_SERVER=$(docker exec "$CONTAINER" sh -c "grep -c 'save-append' /home/node/app/src/endpoints/chats.js 2>/dev/null || true" | tail -1)
    CHK_FRONT=$(docker exec "$CONTAINER" sh -c "grep -c 'resetIncrementalSaveState' /home/node/app/public/script.js 2>/dev/null || true" | tail -1)
    if [ "${CHK_SERVER:-0}" != "0" ] && [ "${CHK_FRONT:-0}" != "0" ]; then
        info "验证通过 ✓ (服务端 $CHK_SERVER 处 / 前端 $CHK_FRONT 处补丁标记)"
        divider
        echo ""
        echo "✅ 全部完成！请用浏览器硬刷新页面 (Ctrl+Shift+R) 后再测试, 避免加载旧文件缓存。"
        echo "   第一条消息仍为全量保存(建立基线), 第二条消息起走增量 save-append。"
    else
        warn "补丁已应用但验证未通过, 请把以下输出发给管理员:
  server=$CHK_SERVER front=$CHK_FRONT"
    fi
}

# ─── 本地安装流程 ────────────────────────────────────────────────────

install_local() {
    local ST_DIR="$1"

    echo ""
    divider
    echo "  SillyTavern 性能补丁安装 (本地模式)"
    divider

    # 1. 检查目录是否像 SillyTavern
    step "第 1 步: 检查目录 '$ST_DIR'..."
    if [ ! -f "$ST_DIR/server.js" ] || [ ! -f "$ST_DIR/public/script.js" ]; then
        echo ""
        error "'$ST_DIR' 不是 SillyTavern 安装目录。
  请用 --local <SillyTavern目录> 指定正确路径,
  或在交互模式下重新输入正确的目录路径。"
    fi
    info "目录确认 ✓"
    divider

    # 2. 检查本机是否有 patch 命令
    step "第 2 步: 检查 patch 命令..."
    if ! command -v patch &>/dev/null; then
        warn "本机缺少 patch 命令, 正在尝试安装..."
        if command -v apt-get &>/dev/null; then
            apt-get update -qq && apt-get install -y -qq patch
        elif command -v apk &>/dev/null; then
            apk add --no-cache patch
        elif command -v yum &>/dev/null; then
            yum install -y patch
        else
            error "无法自动安装 patch, 请手动安装后重试:
  Debian/Ubuntu: sudo apt-get install -y patch
  Alpine:        apk add patch
  CentOS:        sudo yum install -y patch"
        fi
        info "patch 安装完成 ✓"
    else
        info "本机已有 patch ✓"
    fi
    divider

    # 3. 检查 SillyTavern 版本
    step "第 3 步: 检查 SillyTavern 版本..."
    VER=$(grep '"version"' "$ST_DIR/package.json" 2>/dev/null | head -1 | grep -o '[0-9.]*' || true)
    if [ -z "$VER" ]; then
        warn "无法读取版本号(不影响安装, 继续...)"
    elif [ "$VER" != "$EXPECTED_VERSION" ]; then
        warn "当前版本: $VER, 本补丁适配: $EXPECTED_VERSION
  版本不匹配时补丁很可能安装失败, 建议先确认版本或使用对应版本的补丁。"
    else
        info "版本 $VER ✓ (与补丁匹配)"
    fi
    divider

    # 4. 检查是否已安装
    step "第 4 步: 检查是否已安装过补丁..."
    if grep -q 'save-append' "$ST_DIR/src/endpoints/chats.js" 2>/dev/null; then
        error "检测到目录中已有补丁痕迹。
  如需重装, 请先运行: ./uninstall.sh --local $ST_DIR
  卸载完成后再运行本脚本。"
    fi
    info "未安装, 可以继续 ✓"
    divider

    # 5. 用户确认
    read -r -p "即将安装到目录 '$ST_DIR', 按回车继续, 或输入 n 取消: " CONFIRM
    if [ "$CONFIRM" = "n" ] || [ "$CONFIRM" = "N" ]; then
        echo "已取消安装。"
        exit 0
    fi

    # 6. 备份原始文件
    step "第 5 步: 备份原始文件到 backups/ 目录..."
    BACKUP_DIR="$SCRIPT_DIR/backups/$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$BACKUP_DIR"
    cp "$ST_DIR/src/endpoints/chats.js"          "$BACKUP_DIR/chats.server.js"
    cp "$ST_DIR/public/script.js"                "$BACKUP_DIR/script.js"
    cp "$ST_DIR/public/scripts/group-chats.js"   "$BACKUP_DIR/group-chats.js"
    cp "$ST_DIR/public/scripts/chats.js"         "$BACKUP_DIR/chats.js"
    cp "$ST_DIR/src/server-startup.js"           "$BACKUP_DIR/server-startup.js"
    cp "$ST_DIR/public/scripts/tokenizers.js"    "$BACKUP_DIR/tokenizers.js"
    info "备份已保存到: $BACKUP_DIR ✓"
    divider

    # 7. 逐个应用补丁
    step "第 6 步: 应用补丁..."
    PATCH_FILES=(chats.server.patch script.patch group-chats.patch server-startup.patch chats.patch tokenizers.patch)
    for pf in "${PATCH_FILES[@]}"; do
        if (cd "$ST_DIR" && patch -p1 --dry-run < "$PATCHES_DIR/$pf") &>/dev/null; then
            (cd "$ST_DIR" && patch -p1 < "$PATCHES_DIR/$pf")
            info "补丁 $pf 应用成功 ✓"
        else
            error "补丁 $pf 应用失败!
  可能原因:
    1. 已安装过(请先运行 ./uninstall.sh 再试)
    2. SillyTavern 版本不是 $EXPECTED_VERSION(请确认版本)
    3. 源码被外部修改过(请检查是否用了其他补丁/插件)"
        fi
    done

    # 8. 部署新文件
    step "第 7 步: 部署新文件(image-proxy.js)..."
    cp "$NEW_FILES_DIR/image-proxy.js" "$ST_DIR/src/endpoints/image-proxy.js"
    info "新文件部署完成 ✓"
    divider

    # 9. 最终验证
    step "第 8 步: 最终验证..."
    CHK_SERVER=$(grep -c 'save-append' "$ST_DIR/src/endpoints/chats.js" 2>/dev/null || true)
    CHK_FRONT=$(grep -c 'resetIncrementalSaveState' "$ST_DIR/public/script.js" 2>/dev/null || true)
    if [ "${CHK_SERVER:-0}" != "0" ] && [ "${CHK_FRONT:-0}" != "0" ]; then
        info "验证通过 ✓ (服务端 $CHK_SERVER 处 / 前端 $CHK_FRONT 处补丁标记)"
        divider
        echo ""
        echo "✅ 全部完成！请手动重启 SillyTavern, 并用浏览器硬刷新 (Ctrl+Shift+R) 后测试。"
        echo "   第一条消息仍为全量保存(建立基线), 第二条消息起走增量 save-append。"
    else
        warn "补丁已应用但验证未通过, 请把以下输出发给管理员:
  server=$CHK_SERVER front=$CHK_FRONT"
    fi
}

# ─── 主入口 ──────────────────────────────────────────────────────────

if [ "$1" = "--docker" ] || [ "$1" = "-d" ]; then
    install_docker "${2:-sillytavern}"
    exit 0
elif [ "$1" = "--local" ] || [ "$1" = "-l" ]; then
    install_local "${2:-.}"
    exit 0
fi

# ─── 交互式向导 ──────────────────────────────────────────────────────

if [ ! -t 0 ]; then
    echo "检测到非交互终端(无法读取输入)。"
    echo "请使用参数直接指定安装方式:"
    echo "  ./install.sh --docker [容器名]"
    echo "  ./install.sh --local [目录]"
    exit 1
fi

echo ""
echo "=============================================="
echo "  SillyTavern 性能补丁安装脚本"
echo "  适用版本: $EXPECTED_VERSION"
echo "=============================================="
echo ""
echo "本脚本包含三项优化: 增量保存 / 图片代理缓存 / Token 快速估算"
echo ""
echo "请选择安装方式:"
echo ""
echo "  [1] Docker 安装 —— 安装到运行中的 Docker 容器"
echo "  [2] 本地安装   —— 安装到服务器磁盘上的 SillyTavern 目录"
echo "  [3] 退出"
echo ""
read -r -p "请输入数字 [1/2/3]: " CHOICE
echo ""

case "$CHOICE" in
    1)
        echo "您选择了 Docker 安装"
        echo ""
        read -r -p "请输入容器名(直接回车使用默认值 sillytavern): " CONTAINER
        CONTAINER="${CONTAINER:-sillytavern}"
        install_docker "$CONTAINER"
        ;;
    2)
        echo "您选择了本地安装"
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
        install_local "$ST_DIR"
        ;;
    *)
        echo "已退出。"
        exit 0
        ;;
esac