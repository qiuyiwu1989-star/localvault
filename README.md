# localvault · 本地上下文

**把你指定的本机目录索引成 agent 能直接检索的本地上下文，并提供一套只读的文件治理体检。**

一句话说清它是什么：它把「这台机器上有什么」变成可查的事实 —— 索引在本机、交给 agent 查、
体检只出报告。索引库落在 `~/.localvault/`，不出这台机器。

当前版本 **1.1.1**　|　零第三方依赖（只用 Node 内置模块 + `node:sqlite`）　|　CLI 需要 Node ≥ 22.5；macOS App 不需要 Node

**装它要付出的代价，就两样：** 一次 Gatekeeper 放行（未公证的 adhoc 签名包，客观上的手动步骤），
以及一个数据目录 `~/.localvault/`（可随时整个删掉，见 [卸载.md](卸载.md)）。
你的文件**只读**，索引**不上传**。

<!-- 浅色版；深色版把 light 换成 dark。全部由 scripts/screenshot.sh 生成，用的是一份夹具数据。 -->
![界面](docs/screenshot-overview-light.png)

> 截图里的内容是**夹具数据**（11 个文件），不是任何人的真实文件。
> `sh scripts/screenshot.sh` 可以重新生成这一组图 —— 它自己造一份假 HOME、
> 用完即删，所以这些图可以随界面一起自动更新，不会停在某个旧版本上。
> 现有：`screenshot-overview-{light,dark}.png`（判断分布）、
> `screenshot-detail-{light,dark}.png`（判断依据 + 正文）、
> `screenshot-search-{light,dark}.png`（检索命中）。

---

## 它能做什么

三条，对应真实存在的命令与工具，不是方向性描述。

**1. 让 agent 查得到你的文件。**
建好索引后，agent 通过 10 个只读 MCP 工具检索文件名、路径、文档标题、各级标题和正文
（中文按子串匹配，2 个字就能命中），并能直接读正文。连上时还会自动注入一段「本机地图」：
索引了哪些根、权威入口文档、顶层目录用途、台账概况、你自己规则文档里的规则原文。

**2. 告诉你哪些文件值得读。**
一条六级的注意力梯子：

| 级 | 名 | 判据 | 典型文件 |
| --- | --- | --- | ---: |
| 0 | 务必读 | 项目入口文档（实测区分度 3.08×） | 71 |
| 1 | 值得读 | 文档笔记 + 实质正文（2.30×） | 547 |
| 2 | 值得扫 | 其余可读文档 | 118 |
| 3 | 待定 | 图片/音视频/设计稿 —— 机器读不懂，**不冒充结论** | 466 |
| 4 | 只检索 | 源码/数据/配置 —— 搜得到，不抢注意力 | 1,654 |
| 5 | 不看 | 安装包、依赖、构建产物、重复件 | 6,985 |

（数量是作者机器上的快照，见 [CHANGELOG.md](CHANGELOG.md) 的 1.1.0 一节；判定顺序与区分度证据也在那里。
看你自己的分布用 App，或跑 `node cli.js coverage`。）

**3. 告诉你哪里在浪费空间。**
六项只读体检：内容完全重复的文件、超过阈值未改动的陈旧文件、命中你配置词表的版本化命名、
收集目录积压、根目录散文件、Markdown 断链。报告只陈述事实，判定标准由你在 `policy` 配置里写。

**它不动你的文件。** 体检（`vault_audit` / `audit`）和整理方案（`propose_organize` / `organize`）
都只出报告，移动、改名、删除一律由你自己做。这是设计约束，不是当前版本的临时取舍。

---

## 60 秒上手

两条路，今天都能走。先选一条。

### 路线 A：下载 dmg 打开（图形界面，不需要 Node）

安装包在仓库里：`app/dist/本地上下文-1.1.1.dmg`（约 1.9 MB）。

要求：**Apple Silicon（arm64）+ macOS 14.0 或更高**。这个包实测是 arm64、`LSMinimumSystemVersion = 14.0`，
Intel Mac 上跑不起来。

1. 打开 dmg，把 `本地上下文.app` 拖进 `Applications`（dmg 里就是 `/Applications` 的软链）。
2. **第一次打开会被 Gatekeeper 拦下。** 这个包是 adhoc 签名、没有公证票，拦截是预期行为，不是文件坏了。
   放行三选一：
   - **macOS 15 及以后**：先双击一次让它被拦，然后打开 **系统设置 → 隐私与安全性**，拉到底部
     「安全性」区域会出现这个 App 的提示，点 **「仍要打开」**，系统再确认一次。
   - **macOS 14 及更早**：Finder 里 **按住 Control 点（或右键）图标 → 「打开」→ 弹窗里再点一次「打开」**。
     macOS 15 起 Apple 去掉了右键这条后门，只能走上面那条。
   - **终端一条命令**（各版本等价、可脚本化）：
     ```sh
     xattr -l /Applications/本地上下文.app                                     # 先看有没有隔离属性
     xattr -d com.apple.quarantine /Applications/本地上下文.app                 # 有就删掉
     ```
     第二条报 `No such xattr` 说明隔离属性本来就没有（例如用 `ditto` 拷的，或已经放行过），不用再执行。
     **不要**用 `xattr -cr`：它会递归清掉所有扩展属性，一般不需要。
3. 放行后双击打开。机器上还没有索引时，App 直接给首次运行向导：勾目录 → 建立 → 进主界面。
   **建索引由 App 自己完成（原生索引器），不需要 Node，不需要命令行。**
   默认只列出 `~/Desktop` 与 `~/Downloads`，不会默认索引整个主目录或「文稿」。

> 为什么这一步消不掉：没有 Apple 开发者账号（$99/年）就签不出能让 Gatekeeper 放行的包。
> 本机实测 `spctl -a -vvv --type execute` → `rejected`（exit 3）、`codesign -dvv` → `Signature=adhoc`、
> `TeamIdentifier=not set`。逐项摩擦与原始输出见 [app/首次运行.md](app/首次运行.md)；
> 「下载到打开一共几步、每步卡在哪」的核对单见 [开箱即用.md](开箱即用.md)。

### 路线 B：从源码跑 CLI（需要 Node ≥ 22.5）

```sh
git clone <仓库地址待补> localvault
cd localvault/mcp-server

node --version              # 必须 ≥ 22.5；低于此版本会打印一行提示并 exit 2，不抛栈
node cli.js init            # 探测 ~/Desktop 与 ~/Downloads，写出本机配置
node cli.js index           # 建索引（首次几秒到几分钟，之后是增量的）
node cli.js search 关键词    # 命令行检索
node cli.js doctor          # 自检：Node / SQLite / 配置 / 索引 / instructions 字节数
```

> ⚠️ **仓库地址待补。** GitHub 公开仓库还没建（`git rev-list --count HEAD` = 16 个提交，
> 但一个 remote 都没配），上面的 `<仓库地址待补>` 现在填不出来。地址一旦确定，这里换成真实 URL。

要索引自己的目录，位置参数按 `路径:标签` 写：

```sh
node cli.js init ~/Documents/我的项目:工作区 ~/Desktop:桌面
```

> **位置参数一律写在 `--force` 之前。** 实测的坑：`node cli.js init --force ~/x:标签` 会把
> `~/x:标签` 当成 `--force` 的值吃掉，索引根静默退回默认的桌面与下载。
> 正确写法：`node cli.js init ~/Documents/我的项目:工作区 --force`。

已有配置时 `init` **只报告、不覆盖**（连你新给的位置参数也不会加进去），要重写必须加 `--force`；
`--force` 会先把旧配置备份成 `~/.localvault/config.json.bak-<时间戳>`。改索引范围也可以直接编辑
`~/.localvault/config.json` 的 `roots`，然后重跑 `index`。

### npm 装？现在不行

这个包**还没有发布到 npm**。实测（2026-10-03）两个源都是 404：

```sh
$ curl -s -o /dev/null -w '%{http_code}\n' https://registry.npmjs.org/localvault
404
$ curl -s -o /dev/null -w '%{http_code}\n' https://registry.npmmirror.com/localvault
404
```

所以 `npm i -g localvault` / `npx localvault` **现在都不成立**，别照着写。包上线后会改这一节。

---

## 接进 agent（MCP）

localvault 是一个标准 **stdio MCP server**，服务器名 `localvault`，入口是 `mcp-server/server.js`。
接上以后，agent 会多出 `mcp__localvault__*` 前缀的 10 个只读工具（清单见下），
并且 `initialize` 返回的 `instructions`（本机地图，默认上限 32768 字节）会成为系统提示词的一部分 ——
「什么时候该去查本地上下文」不用你每次提醒。DSH 用户可以直接跑
`node cli.js setup-dsh` 生成本机挂载补丁；其他客户端手工配 stdio 命令即可。

**完整的接入步骤（DSH / Claude / Cursor 各怎么写、路径怎么填、装完怎么验证）见 [接进-agent.md](接进-agent.md)。**
这一节不重复它的内容。

---

## 常见问题

**第一次打开被 Gatekeeper 拦？**
见上面「路线 A」的三条放行办法。这是未公证 + 带隔离属性的组合导致的，跟包本身坏没坏无关；
清掉隔离属性后系统只校验签名完整性，而 adhoc 签名是自洽的（`codesign --verify --deep --strict` 实测 valid）。

**需要什么 Node 版本？**
CLI 需要 **≥ 22.5**。硬要求，原因是索引库用 Node 内置的 `node:sqlite`；低于此版本会给出明确提示
并 `exit 2`。**只用 App 的话完全不需要 Node**。

**索引库在哪？**
`~/.localvault/`：索引本体 `vault.db`，配置 `config.json`。数据目录可以用环境变量
`LOCALVAULT_DATA_DIR` 改（`setup-dsh` 生成的补丁里会带上它）。完整清单见下面「数据位置」。

**索引有多快、占多大？**
作者机器上的**带日期快照**，不是你能直接套用的数字：工作区 9,336 个文件 / 16.7GB 建出的
`vault.db` = 101,289,984 字节（约 97 MiB，2026-10-03，另加约 16 MiB 的 `-wal`）；
2026-10-01 那次快照里，扫描 9,443 个文件用 2.6 秒、增量 0.4 秒。
索引是活的，看你自己的跑 `node cli.js doctor`。

**App 和 CLI 是什么关系？**
两边都能建索引：App 用原生 Swift 索引器，CLI 用 Node。两边建出的库字段一致（有一条对拍断言守着，
23 文件树与 3,013 文件树各比对 18 列，0 处不一致）。
一个已知缺口：**App 向导建的库里没有「地图」和 MCP 的 `instructions`** —— 这两样目前只有 CLI 会写。
所以用向导建完索引后，界面里的地图面板在干净机器上会是空的（检索、提炼正常）。
要地图、或要把索引接给 agent，用 CLI 再跑一次 `index`。

**Linux / Windows 能用吗？**
CLI 是 Node，跨平台。图形界面是 SwiftUI、macOS 14+ 专用，没有 Linux / Windows 版。

**怎么彻底删掉？**
见 [卸载.md](卸载.md)：删索引库、配置、App、CLI 与 skill —— 以及**删完还剩什么**。

---

## 它不做什么

- **不动你的文件。** 不移动、不改名、不删除。体检出报告，整理方案是 dry-run。
- **不联网上传、不是云盘、不做云同步。** 索引只写本机 `~/.localvault/`；没有账号、没有服务器、
  没有遥测，也没有跨设备同步。**全部代码只有一个网络出口**：`node cli.js upstream push` 与
  `upstream compensate`（上游对接，首版只做归档）。它必须同时满足两条才会发请求 —— 环境变量
  `LOCALVAULT_MEMORY_TOKEN` 已设置（只从环境读，代码里没有任何地方能传 Token 参数），
  并且你手敲了这两个子命令。没设 Token 时一个请求都不发：这条有测试守着
  （`node test/no-network.js`，26 条断言，把 `globalThis.fetch` 换成会记账的守卫来证明 0 是真的）。
  索引、检索、体检、10 个 MCP 工具全程本机。
- **不做 LLM 提炼。** 没有摘要、没有结论生成、不调用任何模型。
- **不做语义检索。** 检索是子串匹配，不是向量检索。搜「我当年怎么开始创业的」这类意图查询会落空；
  向量检索有价值，但它的代价（常驻服务 + 向量模型）不是这一层该背的。
- **不索引非文本正文。** 图片、音视频、扫描件 PDF 只记元数据，内容不可搜。它不假装解决了这块。

---

## 架构

`mcp-server/` 是一个零依赖的 Node 程序，CLI（`cli.js`）和 MCP server（`server.js`）共用同一套 lib：
`walk.js` 遍历文件系统 → `extract.js` 抽标题与正文 → `store.js` 写进 `node:sqlite`
（`~/.localvault/vault.db`）→ `vault.js` 结合库和磁盘生成「地图」与 `instructions` →
`mcp.js` 把工具和资源按 JSON-RPC 暴露到 stdio。`governance.js` 与 `coverage.js` 全是只读统计。
`config.js` 里的默认值不含任何具体工作区的路径、目录名或文档名 —— 零配置时只探测系统标准目录
（`~/Desktop`、`~/Downloads`；Linux 上读 `~/.config/user-dirs.dirs`），其余靠自动发现或你显式配置。
App 是 SwiftUI 前端，读索引库时以只读模式打开；只有首次运行向导建索引那一次会写 `vault.db`。

```
本地上下文MCP/
├── README.md              本文（门面：是什么、怎么装、边界）
├── 接进-agent.md          怎么接进 agent（MCP 配置）
├── 卸载.md                怎么彻底删掉，以及删完还剩什么
├── 隐私.md                隐私边界（唯一网络出口的触发条件、索引里存了什么）
├── 开箱即用.md            「下载到打开」逐项摩擦核对单与实际卡点
├── CHANGELOG.md           更新日志（六级梯子、事故与修复的来龙去脉）
├── 上游对接-核查与方案.md / 下一步工作计划.md   内部规划与核查记录（只用工具的话不用读）
├── LICENSE                MIT
├── docs/                  门面图与按页面命名的浅/深色界面截图
├── mcp-server/            零依赖 MCP server + CLI
│   ├── server.js          stdio 入口
│   ├── cli.js             15 个命令（见下）
│   ├── lib/               config / discover / walk / extract / store / indexer / search /
│   │                      coverage / governance / vault / mcp
│   ├── lib/upstream/      上游对接（默认不生效，见「它不做什么」）
│   └── test/              smoke / clean-machine / ignore-lists / upstream / mcp-handshake / no-network
├── app/                   macOS 图形界面（SwiftUI）
│   ├── Sources/LocalVault/ 界面与原生索引器
│   ├── docs/              界面截图（约 16 MB，含改版过程稿 —— 只看用法的话可以跳过）
│   ├── dist/              构建产物（.dmg 与 .app，未进版本库）
│   ├── 首次运行.md        别的电脑上怎么装（含 Gatekeeper 的原始判定输出）
│   └── 设计契约.md        界面层的冻结约定
├── bundle/                DSH 插件补丁（cordis.patch.yml 是生成物）
├── skill/local-context-mcp/  给 agent 的 skill（告诉模型「什么时候」该查本地上下文）
├── scripts/               install-skill.sh / install-bundle.sh / CI 与断言扫描
└── .github/workflows/     CI
```

### 命令（`node cli.js <命令>`，15 个）

| 命令 | 做什么 |
| --- | --- |
| `init [路径:标签 …] [--force]` | 探测这台机器，写出本机配置。已有配置时只报告 |
| `index [--full] [--root <路径>]` | 建索引（默认增量） |
| `reindex-cache` | 只重建缓存的「地图 + instructions」，不扫盘 |
| `map` | 打印工作区地图 |
| `instructions` | 打印注入系统提示词的那段文字（字节数写到 stderr） |
| `search <关键词…>` | 命令行检索 |
| `project <关键词>` | 用名称/域名/仓库/编号反查项目 |
| `audit [检查项]` | 文件治理体检（六项） |
| `organize` | 整理方案，**dry-run** |
| `coverage` | 覆盖度：暗区按「变亮要付什么代价」分层 |
| `doctor` | 自检 |
| `setup-dsh [--out <目录>]` | 生成本机 DSH 挂载补丁（默认写到 `bundle/`） |
| `ledger` | 台账概况（项目数、分组、基线） |
| `upstream <子命令>` | 上游对接；默认什么都不做，没有授权清单时连一个字节都不出去 |
| `help` | 列出全部命令（`node cli.js --help`、`-h`、不带参数同效） |

### MCP 工具（10 个，全部只读）

| 工具 | 用途 |
| --- | --- |
| `vault_map` | 完整地图：索引范围、入口文档、目录用途、台账、类型分布、规则摘要 |
| `disk_coverage` | 覆盖度：暗区按代价分层（白捡 / 格式解析 / OCR / 转录 / 不必变亮） |
| `find_files` | 子串检索文件名/路径/标题/各级标题/正文，可按类型、时间、体积过滤 |
| `find_project` | 项目名/域名/仓库名/编号反查台账条目、卡片与资料目录 |
| `read_text` | 读索引内文本文件正文（带行号与上限） |
| `list_directory` | 列目录条目 |
| `recent_changes` | 最近改动（默认 7 天），按顶层目录聚合 |
| `vault_audit` | 六项只读体检：duplicates / stale / naming / inbox / root_clutter / links |
| `propose_organize` | 整理方案（dry-run，不动文件） |
| `refresh_index` | 增量重建索引（默认后台跑，不阻塞对话） |

资源：`vault://map`、`vault://guide`、`vault://projects`、`vault://recent`，模板 `vault://file/{path}`。
（另有别名 `vault://overview`，与 `vault://map` 同源，但不出现在资源列表里。）

### 开发者：跑测试

```sh
cd mcp-server
node test/smoke.js              # 端到端：真实索引 + 真实检索 + 真实 stdio 握手 + 通用性守卫
node test/clean-machine.js      # 「另一台电脑装完配一下就能用」：造一个别人的主目录真跑一遍
node test/no-network.js         # 没配 Token 时零网络请求（把 fetch 换成会记账的守卫来证明）
```

> 实测（假 HOME）：`smoke.js` 通过 96 项 / 失败 0 项；`clean-machine.js` 通过 31 项 / 失败 0 项；
> `no-network.js` 通过 26 项 / 失败 0 项。
> `smoke.js` 要求你的 HOME 下真实存在 `~/Desktop` 或 `~/Downloads`（有一条断言要求默认索引根存在），
> 缺了会报一条红 —— 那是环境问题，不是回归。

---

## 数据位置

| 内容 | 路径 | 能否删 |
| --- | --- | --- |
| 索引本体 | `~/.localvault/vault.db` | 能，重跑 `index` 或 App 向导会重建 |
| 配置 | `~/.localvault/config.json` | 别手删，删了要重新认一遍目录 |
| 配置备份 | `~/.localvault/config.json.bak-<时间戳>` | 能 |
| 索引日志 | `~/.localvault/index.log` | 能 |
| 判断/签字记录 | `~/.localvault/claims.db` | **不能**，App 用，它不可重建 |
| 上游清单/账本 | `~/.localvault/upstream-manifest.json`、`upstream-ledger.db` | 只在用过 `upstream` 时出现 |

数据目录整体可以被环境变量 `LOCALVAULT_DATA_DIR` 指到别处。删除步骤见 [卸载.md](卸载.md)。

## 隐私

**索引只写本机，不上传、不同步、不遥测。** 你的文件是只读的；密钥类文件
（`.env`、`*.pem`、`*.key`、`*credential*`、`*secret*`、`id_rsa*`、`*kubeconfig*` 等）**只留元数据**：
它们仍会在索引里占一行（路径、文件名、大小、时间），但标题与正文是空的，`read_text` 会明确拒绝
读取并说明原因。

**这条防线只认文件名，得知道它的天花板**：一个名字无害、内容却是密钥的文件挡不住
（实测 `集群.yaml` 会被正常索引）。所以别把密钥写进一个「看起来没关系」的文件里然后指望它被挡住 ——
真正管用的边界是下面那句「不防本机」。另外 `.ssh` / `.gnupg` / `.kube` / `.docker` / `.aws`
这几个目录是**整体跳过**的，连元数据都不记。

符号链接不跟随（只记一条元数据）；
`node_modules`、`.git`、`dist`、`build`、`.build`、`.venv` 等 66 个机器生成目录跳过；
`.app` / `.framework` 这类 bundle 只记一条元数据、不展开内部文件。

要装之前值得知道的一条：**索引库是明文 SQLite，没有加密**，`~/.localvault/` 目录也没有改权限。
「不上传」防的是网络，不防本机 —— 同一台 Mac 上能读到这个文件的进程或本地账户就能读到里面的正文。

完整的隐私边界（唯一网络出口的触发条件、`denyRead` 的 28 条清单、索引里到底存了什么、
上游账本会存正文副本这几条）见 [隐私.md](隐私.md)。

## 已知限制

- **无语义检索**：只有子串匹配。
- **不索引非文本**：图片、音视频、扫描件 PDF 只记元数据。
- **mtime 会被设备迁移污染**：`stale` 检查基于 mtime，迁移过的盘上会失真。
- **正文上限**：单文件抽取上限 2MB，入库正文上限 400,000 字符，超出截断并标注。
- **重名文件**：以绝对路径为唯一键，同名不同目录是两条记录（有意的；体检会另外报同名簇）。

## 待补与未实测（别当成事实）

1. **GitHub 公开仓库地址** —— 一个 remote 都没配，`git clone` 那行填不出来。
2. **npm 发布状态** —— 2026-10-03 实测为 404。包一旦发布，本节与「npm 装？现在不行」都要改。
3. ~~**门面图缺失**~~ —— **已解决**：截图现在由 `scripts/screenshot.sh` 生成（夹具数据、可重复），
   本文引用的文件名与 `docs/` 里的文件一一对上。旧记录：`docs/` 里当时已有按页面命名的浅/深色截图，
   见文件开头那条说明）。门面图用哪张、叫什么名字，还没定。
4. **`npm i -g .` / `npm rm -g localvault`** —— 开发这套代码的机器上没有 npm，**没有实测过**；
   第一次在别的机器上装时如果 `bin` 软链或命令名有问题，请提 issue。
5. **`upstream push` 的真实提交** —— 没有端点凭据，只跑过「没有授权清单就退出」这条路，
   以及 `test/no-network.js` 里「没 Token 时零请求」那一组。
6. **App 首次运行向导的完整体验** —— 没在第二台干净的 Mac 上走过（本机也没有把「点仍要打开」的
   交互实测过，那一节是机制说明）。细则与免责范围见 [app/首次运行.md](app/首次运行.md)。

## 许可

MIT，见 [LICENSE](LICENSE)。
