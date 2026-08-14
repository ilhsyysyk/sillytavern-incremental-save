# SillyTavern Performance Patches

SillyTavern 性能优化补丁集，针对大型聊天记录（100MB+、900+ 条消息）场景下的三个核心瓶颈进行优化。

## 优化效果

以 110MB / 964 条消息的实际聊天记录测试：

| 指标 | 优化前 | 优化后 |
|------|--------|--------|
| 保存消息 | 全量上传 110MB，耗时数秒 | 增量追加，**~5ms** |
| 外部图片加载 | 每次从源站下载，单张 5-29s | 首次代理缓存，之后 **~8ms** |
| 发消息到 AI 响应的等待 | 50+ 次串行 token 计数，**~20s 空等** | 字符估算，**<1s** |

## 功能详解

### 1. 增量保存（Incremental Save）

**问题**：SillyTavern 每次发消息后将完整聊天记录全量上传覆写文件。110MB 的聊天每发一条消息都要传 110MB。

**方案**：检测到仅新增消息时，只上传新增部分并追加到文件末尾。

```
发一条消息 → 检测变更类型
  ├─ 仅新增消息     → save-append：只上传新消息（毫秒级）
  ├─ 仅元数据变更   → save-append：空消息 + 更新头部（毫秒级）
  └─ 编辑/删除/swipe → 回退全量保存（保证数据一致性）
```

**实现细节**：

- 前端通过消息数量 + 内容 hash 判断是否可增量保存
- 新增 `/api/chats/save-append` 和 `/api/chats/group/save-append` 端点
- `expectedLines` 校验确保客户端与服务端文件行数一致，不匹配则拒绝增量并回退全量
- 支持 header-only 更新（`saveMetadataDebounced` 等触发的仅元数据变更）
- 适配 1.18 的 `compressRequest` 请求压缩机制与 `isPathUnderParent` 路径安全校验

### 2. 外部图片代理缓存（Image Proxy Cache）

针对「命定之诗」等大量使用外部图床的角色卡做的特别优化。

**问题**：聊天中嵌入的外部图片（如 `files.catbox.moe`）没有 `Cache-Control` 头，每次加载/切换聊天都重新从源站下载。20 张图 = 32MB 重复流量。

**方案**：服务端代理 + 磁盘缓存 + 浏览器长缓存三级缓存。

```
浏览器渲染消息 → 外部图片 URL 自动改写为 /api/image-proxy?url=...
  ↓
第 1 次请求：服务端下载 → 磁盘缓存 → 返回（Cache-Control: 7天）
第 2 次请求：服务端读磁盘 → 返回（~8ms）
第 3+ 次：浏览器本地缓存直接返回（不发请求）
```

**实现细节**：

- 通过 `HTMLImageElement.prototype.src` setter 拦截 + DOMPurify 钩子双重覆盖，确保所有外部图片（包括扩展通过 `new Image()` 加载的）都走代理
- SHA256(URL) 作为缓存文件名，存储在 `data/<user>/cache/images/`
- 并发去重：同一 URL 的多个请求只发起一次远程下载
- 安全限制：仅代理 HTTP/HTTPS，单文件最大 10MB

### 3. Token 快速估算（Token Fast Estimate）

**问题**：SillyTavern 在发送 generate 请求前，需要逐条消息计算 token 数来决定上下文窗口塞多少消息。当 token 缓存为空时（首次加载、切换聊天、`squashSystemMessages` 合并消息），会串行发起 50+ 个 HTTP 请求，每个 200-500ms，累计阻塞 **15-20 秒**。

**方案**：缓存未命中时立即返回字符估算值，后台异步获取真实值并回填缓存。

```
缓存未命中 → 立刻返回 Math.ceil(text.length / 3.35)（0ms）
           → 后台异步请求真实 token 数 → 写入 IndexedDB 缓存
下次同消息 → 缓存命中 → 直接返回真实值（0ms）
```

**实现细节**：

- 估算比率 `3.35 字符/token` 与 SillyTavern 服务端 fallback 一致
- `squashSystemMessages()` 每次合并消息内容不同导致 hash 不同，永远命中不了缓存——改为估算后从 ~17s 阻塞降为 0
- 估算偏差（偏高估）可能导致首次少包含 1-2 条旧消息，第二次发消息即恢复精确值

## 适用版本

- SillyTavern **1.18.0**

## 安装

### 交互式向导（最简单，推荐小白使用）

```bash
git clone https://github.com/ransxd/sillytavern-incremental-save.git
cd sillytavern-incremental-save/1.8
./install.sh
```

直接运行后出现菜单，选择 Docker 或本地安装，脚本会一步步引导：

```
==============================================
  SillyTavern 性能补丁安装脚本
  适用版本: 1.18.0
==============================================

请选择安装方式:

  [1] Docker 安装 —— 安装到运行中的 Docker 容器
  [2] 本地安装   —— 安装到服务器磁盘上的 SillyTavern 目录
  [3] 退出

请输入数字 [1/2/3]:
```

- 选择 **1（Docker）**：输入容器名（直接回车用默认 `sillytavern`）→ 确认后自动完成全部步骤
- 选择 **2（本地）**：脚本**自动搜索**本机常见位置的 SillyTavern 安装目录（当前目录、`/opt`、`/srv`、`/var/www`、`/usr/local`、`/home/*`、`/root` 下的 `SillyTavern`/`sillytavern` 等）：
  - 找到 1 个 → 直接确认使用（可改手动输入）
  - 找到多个 → 列出编号让您选择
  - 没找到 → 手动输入路径（必填，路径为空或找不到 `server.js` 会循环重输）→ 确认后自动完成全部步骤

也可用参数跳过菜单直接指定方式（适合脚本化/非交互终端）：

```bash
./install.sh --docker [容器名]    # 直接装 Docker（默认容器名 sillytavern）
./install.sh --local [目录]       # 直接装本地（默认当前目录）
```

### Docker 安装

```bash
./install.sh --docker sillytavern
```

容器名默认 `sillytavern`，不同则替换最后的参数。

安装脚本会自动执行以下步骤（每一步都有中文提示，出错会给出具体解决指引）：

1. **检查容器**：容器不存在或未运行时给出明确提示（先 `docker ps` 查看容器名 / `docker start` 启动）
2. **自动安装 `patch` 工具**：Alpine（`apk`）/ Debian（`apt`）镜像自动识别安装，无需手动干预
3. **版本检查**：读取容器内 `package.json`，与补丁适配版本 `1.18.0` 比对，不匹配时提前警告
4. **重复安装检测**：发现已有补丁痕迹时提示先运行 `uninstall.sh`，避免重复打补丁
5. **备份原始文件**：全部 6 个源文件备份到 `backups/20260814_xxx/` 时间戳目录
6. **逐个应用补丁**：每个补丁先 `--dry-run` 预检再正式应用，失败时提示三种常见原因
7. **部署新文件**：复制 `image-proxy.js` 图片代理端点
8. **重启容器**并**最终验证**：自动检查前后端补丁标记，确认安装成功

### 本地安装

```bash
./install.sh --local /path/to/SillyTavern
```

与 Docker 模式相同，自动检查目录合法性、安装缺失的 `patch`（Debian/Ubuntu 用 `apt`，Alpine 用 `apk`，CentOS 用 `yum`）、版本比对、重复安装检测、备份与逐补丁预检。应用后需**手动重启 SillyTavern**（脚本会提示）。

## 卸载

```bash
# 交互式向导（选择 Docker 或本地）
./uninstall.sh

# 或参数直接指定
./uninstall.sh --docker sillytavern   # Docker
./uninstall.sh --local /path/to/SillyTavern   # 本地
```

卸载脚本与安装脚本同样交互式引导，自动检查容器/目录、自动安装缺失的 `patch` 工具，然后按安装的逆序逐个反向还原补丁（`patch -R`），删除新增的 `image-proxy.js` 文件，重启容器（Docker 模式）并最终验证。未安装过的补丁会友好跳过，不会报错中断；全部补丁反向还原后不残留任何修改。

## 验证方法

安装后打开浏览器 DevTools → Network 面板：

**增量保存**：
1. 发送第一条消息 → 看到 `/api/chats/save`（全量，初始化跟踪状态）
2. 再发一条 → 看到 `/api/chats/save-append`（增量），状态码 `200`
3. 编辑旧消息 → 回退到 `/api/chats/save`（全量）
4. Console 中会打印 `Incremental save: appending N new message(s)` 或 `header-only update`

**图片缓存**：
1. 打开包含外部图片的聊天
2. 图片请求 URL 变为 `/api/image-proxy?url=...`
3. 响应头 `X-Image-Cache: HIT`（命中）或 `MISS`（首次）
4. 刷新页面 → 图片瞬间加载

**Token 快速估算**：
1. 发送消息后，`save-append` 和 `generate` 之间间隔应 <2s（之前 ~20s）
2. `tokenizers/openai/count` 请求出现在 `generate` 请求之后（异步后台执行）
3. 第二次发消息 → `tokenizers/openai/count` 请求大幅减少（缓存命中）

## 常见问题

**Q1：安装后发消息看不到 `save-append` 请求？**
- 先确认**第一条**消息是全量 `/save`（这是正常的，用于建立跟踪基线），**第二条**才会增量
- 如果一直只有 `/save`，多半是浏览器缓存了旧的 `script.js`，按 **Ctrl+Shift+R** 硬刷新后再试
- 可用 `docker exec <容器名> sh -c "grep -c resetIncrementalSaveState /home/node/app/public/script.js"` 确认容器内文件已打补丁（输出 ≥1 为正常）

**Q2：Docker 安装时报错或补丁没生效？**
- 老版本镜像（Alpine 系）默认没有 `patch` 命令，会导致补丁全部静默失败。新版 install.sh 已自动检测并安装；手动执行 `docker exec <容器名> sh -c "apk add --no-cache patch"` 即可
- 注意：**容器重建后 `patch` 会丢失**，重装前需重新安装 patch 或直接重跑 install.sh
- 容器名不对、容器未运行、重复安装都会给出明确报错，按提示处理即可

**Q3：控制台 `typeof resetIncrementalSaveState` 返回 `undefined`？**
- 这是**正常现象**。`script.js` 是 ES Module，`export` 的函数不会挂到 `window` 全局，无法用 `typeof` 验证。判断补丁是否生效请直接看 Network 里是否出现 `save-append` 请求

**Q4：手动 `fetch('/api/chats/save-append')` 返回 403？**
- 正常。SillyTavern 有 CSRF 保护，裸 fetch 缺少 `X-CSRF-Token` 头会被拒绝。真实前端代码通过 `getRequestHeaders()` 携带令牌，不受影响；只有 404 才说明后端补丁未生效

**Q5：安装后提示版本不匹配？**
- 本补丁仅适配 SillyTavern **1.18.0**。安装脚本会自动读取容器/本地 `package.json` 版本号并提醒，版本不一致时补丁可能失败，请使用对应版本的补丁或升级/降级 ST

## 修改的文件

```
patches/
  chats.server.patch      → src/endpoints/chats.js         增量保存服务端端点
  script.patch             → public/script.js               增量保存前端逻辑 + Image.src 拦截器
  group-chats.patch        → public/scripts/group-chats.js  群组聊天增量保存
  server-startup.patch     → src/server-startup.js          注册图片代理路由
  chats.patch              → public/scripts/chats.js        DOMPurify 图片 URL 改写
  tokenizers.patch         → public/scripts/tokenizers.js   Token 快速估算

new-files/
  image-proxy.js           → src/endpoints/image-proxy.js   图片代理缓存端点（新文件）
```

## 安全性

- 增量保存失败时**自动回退**全量保存，不会丢数据
- `expectedLines` 校验确保客户端与服务端数据一致，不匹配拒绝增量
- `isPathUnderParent` 校验服务端路径安全，防止路径穿越
- 原有的 integrity check、backup 机制完全保留
- 编辑/删除/swipe 等操作不受影响，自动触发全量保存
- 图片代理仅允许 HTTP/HTTPS 协议，单文件限制 10MB
- 图片缓存跟随用户数据目录，Docker volume 持久化

## License

MIT