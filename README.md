# Leko Reader — 非官方增强版 Fork

[![release](https://img.shields.io/github/v/release/seaneasysaid/leko-reader-fixed)](https://github.com/seaneasysaid/leko-reader-fixed/releases)
[![downloads](https://img.shields.io/github/downloads/seaneasysaid/leko-reader-fixed/total)](https://github.com/seaneasysaid/leko-reader-fixed/releases)

本项目是 [`jnjnnjzch/leko-reader`](https://github.com/jnjnnjzch/leko-reader) 的非官方增强版 Fork。

> 本项目不是上游项目的官方版本。上游来源、提交历史及代码差异均通过 GitHub Fork 关系公开保留。

## 与原版的主要区别

- **适配书山聚合源（个人修改版）**：上游的 JavaScript 书源在 Kindle / Kobo 等设备的 QuickJS 环境下无法运行，本 Fork 将其改写为纯 Lua 原生实现，不再依赖 JS 引擎；内置镜像轮换、自动重登与登录态持久化，重导入书源不丢失账号。
- **段落评论（段评）**：正文段末显示评论数气泡，点击弹出富排版评论弹窗，支持翻页与继续加载；取数在子进程完成，阅读与翻页全程不冻结，等待可取消。
- **排版可调**：首行缩进、上下边距、字号、页眉页脚均可自定义。
- **刷新分层**：跨章净屏与同章翻页刷新策略分离，可独立开关。
- **源诊断**：源状态 / 源健康检查兼容原生源，避免误报。
- **搜索增强**：修复聚合源搜索只出 1 条 / 全局搜索 0 结果的问题；结果行显示真实来源站点、按同名书作者投票加权排序、过滤非小说内容。
- **稳定性修复**：Android 开书崩溃兼容、目录缓存格式版本化迁移、正文请求快速失败并透传真实失败原因（如 VIP 专享提示）等。
- **阅读统计**：对接 KOReader 的统计模块，阅读时长正常计入。

## 安装

1. 从 Release 下载 `leko.koplugin` 安装包（zip）并解压。
2. 将 `leko.koplugin` 文件夹复制到 KOReader 的 `plugins` 目录：

   - Kindle：`/koreader/plugins/`
   - Kobo：`/.adds/koreader/plugins/`
   - Android：`/sdcard/koreader/plugins/`

3. 完全退出并重新启动 KOReader。

注意目录不要多套一层：

```
koreader/plugins/leko.koplugin/main.lua   ← 正确
koreader/plugins/leko.koplugin/leko.koplugin/main.lua   ← 错误
```

## 导入书山书源

仓库内附带 [`leko-shushan-native.json`](leko-shushan-native.json)，即「书山聚合（原生）」书源：

1. 把 `leko-shushan-native.json` 拷到设备任意位置。
2. KOReader 里打开 leko → **书源管理 → 导入书源**，选择该 JSON。
3. 导入后在 **配置书源** 里填写书山账号的**邮箱**、**密码**、**设备ID**（16 位十六进制，手机书山 App「用户中心」可查；没有可先空着试。服务端会校验设备，伪造的标识会被拒绝）。
4. 点「登录书山」拿密钥，再点「检测节点」选一台可用镜像。

> 书源文件本身不含任何账号信息；登录密钥只保存在你自己设备的 leko 数据目录里。

## 段评使用说明

开启方法：阅读界面 → 排版菜单 → 打开「段评」（默认关闭，不打开不会出气泡）。

- 本章有评论的段落，末尾会出现小气泡 `[N]`（超过 99 条显示 `[99+]`），点它即读该段评论；
- 弹窗顶部是这一段原文，下面是「▸ 昵称 · ♥赞」+ 评论正文，可上下滚动；
- 点左右半屏翻页；点弹窗外或按返回键关闭；
- 评论多的时候底部有「继续加载（还剩 N 条）」；
- 取评论在后台进行，等超过半秒会浮出「正在获取段评…」，点一下即可取消；
- 需要先在「配置书源」里登录书山并选好可用节点。

## 故障排查

- **搜索无结果 / 书籍打不开**：检查网络；镜像可能整体波动，稍后重试；登录态失效时重新登录书源账号。
- **段评气泡不显示**：当前书来源不支持段评，或该章节没有评论。
- **插件没出现在菜单**：确认目录层级正确，升级 KOReader 后重试。

## 上游关系

- 上游项目：https://github.com/jnjnnjzch/leko-reader
- 本增强分支：https://github.com/seaneasysaid/leko-reader-fixed

借鉴或合并上游后续修复时，会保留可追踪的提交说明，不通过改名或打乱代码结构隐藏来源。

## 使用声明

本项目仅用于个人学习和技术研究，不代表上游项目及相关内容平台的官方立场。本项目不存储、不分发任何书籍内容，所有正文均通过用户自行配置的书源获取。使用者应自行确认适用的授权条件并自行承担风险。请尊重版权、支持正版阅读。如涉及侵权请联系删除。
