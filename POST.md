✨ 【性能优化】【告别卡顿】SillyTavern 增量保存补丁 —— 让大型聊天保存从龟速变闪电！

LZ

🤯 你是否遇到过这些"血压拉满"的时刻？

聊天记录越来越长，每次发消息保存都要转好几秒圈圈？
明明只发了一句话，后台却要把几千条消息全部重新上传一遍？
长篇剧情玩到后期，光是等保存就能把沉浸感打断？
群聊记录越积越多，保存一次比加载还慢？

-

✨ 别忍了！「增量保存补丁」来帮你解决！
它让 SillyTavern 只上传你新发的消息，而不是每次都把整个聊天记录从头传到尾！

-

🔥 【问题根源】

SillyTavern 原版的保存逻辑：

```
发一条消息 → 把全部聊天记录打包 → 整个上传到服务端 → 覆写文件
```

聊天越长，每次保存的数据量越大。你只说了一句"好的"，它却要把几百轮对话全部重传一遍。聊天记录大了之后，这个等待时间会越来越离谱。

-

⚡ 【解决方案】

```
发一条消息 → 检测：只是新增了消息吗？
  ├─ 是 → 只上传新增的那几条消息（毫秒级完成）
  └─ 否 → 回退全量保存（编辑/删除/swipe等场景，保证数据安全）
```

-

🔥 【核心亮点】

🚀 智能增量检测
自动判断是否只有新消息追加，无需手动切换。
旧消息没动？只传新的。改了旧消息？自动回退全量保存，零风险。

⚡ 保存速度质变
原本要传输整个聊天文件，现在只传新增的几条消息。
聊天越长，提升越明显。长篇剧情党狂喜。

🛡️ 安全回退机制
编辑旧消息、swipe、删除、重排消息 → 自动检测到变化，回退全量保存。
客户端与服务端行数校验，数据不一致立刻回退，绝不丢数据。
原版的 integrity check、备份机制全部保留，零破坏。

👥 群聊也支持
个人聊天和群组聊天都做了增量优化，一视同仁。

-

🎬 【实际效果】

假设你有一个长篇剧情聊天，已经聊了好几百轮：

📝 发一条新消息 → 以前：整个聊天记录全部重传（好几秒） → 现在：只传这一条新消息（瞬间完成）✅
✏️ 编辑了之前某条消息 → 自动回退全量保存（保证数据完整）✅
🔄 swipe 切换回复 → 自动回退全量保存（安全第一）✅
💬 切换到另一个聊天 → 自动重置状态，下次保存重新建立跟踪 ✅

-

🚀 【安装方法，一键搞定】

Docker 用户：
```bash
git clone https://github.com/ransxd/sillytavern-incremental-save.git
cd sillytavern-incremental-save/1.8
./install.sh --docker sillytavern
```
脚本自动备份原文件 → 打补丁 → 重启容器，全程无脑。

本地部署用户：
```bash
git clone https://github.com/ransxd/sillytavern-incremental-save.git
cd sillytavern-incremental-save/1.8
./install.sh --local /你的SillyTavern路径
```
打完补丁手动重启即可。

不想用了？一键卸载：
```bash
./uninstall.sh --docker sillytavern
# 或
./uninstall.sh --local /你的SillyTavern路径
```

-

🔍 【怎么确认生效了？】

打开浏览器 F12 → Network 面板：
1️⃣ 发第一条消息 → 看到 `/api/chats/save`（全量保存，正常，首次需要建立跟踪基线）
2️⃣ 再发一条 → 看到 `/api/chats/save-append`（增量保存，生效了！）
3️⃣ 编辑旧消息 → 自动回退 `/api/chats/save`（安全机制正常工作）

Console 里还会打印 `Incremental save: appending N new message(s)` 日志。

-

📋 【技术细节】

适用版本：SillyTavern 1.18.0
修改文件：6 个（服务端 2 个 + 前端 4 个）
实现方式：patch 补丁，不侵入原始代码仓库

为什么不做成扩展/插件？
→ 这个功能需要同时修改前后端的核心保存逻辑，ST 的扩展系统暂时没有提供拦截 saveChat 的钩子，所以只能用 patch 方式实现。安装卸载都是一键脚本，也很方便。

-

🔗 GitHub 仓库
https://github.com/ransxd/sillytavern-incremental-save

有问题欢迎反馈 Issue！