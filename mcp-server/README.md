# localvault

把**你自己指定的本机目录**索引成 **agent 可以直接查的上下文**，并提供一套**只读**的文件治理体检。

它想解决的问题只有一句话：**让「本机有什么」变成可查的事实，而不是靠印象猜。**

- **零 runtime 依赖** —— 只用 Node 内置模块 + 内置 `node:sqlite`，`dependencies` 是空的。
- **完全离线** —— 不联网、不上传、没有云、没有服务端。索引只落在本机。
- **只读** —— 不移动、不重命名、不删除任何文件。整理只是报告，动文件永远由你确认后手动做。

---

## 要求

**Node >= 22.5.0**（`engines.node` 已声明）。硬要求的原因是索引库用的是 Node 内置的 `node:sqlite`；
低于这个版本启动时会给出明确提示并退出，而不是抛一个看不懂的栈。

```sh
node --version
```

---

## 安装

**这个包还没有发布到 npm。** `registry.npmjs.org/localvault` 与 `registry.npmmirror.com/localvault`
**现在都是 404**，所以下面的 `npx localvault …` / `npm i -g localvault` **暂时都用不了**。

包上线后这里就是两行：

```sh
npm i -g localvault   # npm 上线后可用；现在还不是
```

### 现在怎么装

从源码目录装。`package.json` 里的 `bin` 会提供一个 `localvault` 命令：

```sh
cd mcp-server
npm i -g .            # 装完就能直接用 localvault <命令>
```

不想装也可以，在 `mcp-server/` 目录里直接跑，效果一样：

```sh
node cli.js <命令>     # 例如 node cli.js init
```

> 命令在**包安装之后**叫 `localvault`；`npx localvault <命令>` 要等包发布之后才成立。
> 本页其余部分为简洁一律写成 `localvault <命令>`。

---

## 三步上手

```sh
localvault init      # 认一下这台机器，写出本机配置
localvault index     # 建索引
localvault coverage  # 先看覆盖度，再决定值不值得治理
```

`init` 会探测 `~/Desktop` 与 `~/Downloads`，把配置写到 `~/.localvault/config.json`，
索引库写到 `~/.localvault/vault.db`。代码里**不含任何具体工作区的路径、目录名或文档名** ——
它认识的是你配置里写的东西，不是它自己假设的工作区。

### 配到 agent 里

它是一个标准 **stdio MCP server**，服务器名 `localvault`。DSH 用户可以用内置命令一步生成挂载补丁：

```sh
localvault setup-dsh
```

手工配置的话，启动命令是：

```sh
node /绝对路径/node_modules/localvault/server.js
```

连上以后 agent 会看到两样东西：

1. **`initialize` 返回的 `instructions`** —— 一开工就进系统提示词的「本机地图」（索引范围、权威入口文档、
   目录用途、项目台账、你写的文件管理规则摘要）。内容是**从本机文件系统实时生成**的，不是手写的。
   它有长度上限（默认 32768 字节，代码内保守截到 24000），超了会按行截断并明确标注被截断。
2. **11 个只读工具 + 1 个只追加 + 5 个资源**（见下）。

---

## 全部命令

命令名来自 `cli.js` 的 `COMMANDS`。跑 `localvault help`（或 `node cli.js help`）可以列出同一份清单。

| 命令 | 摘要 |
| --- | --- |
| `init` | 探测这台机器，写出本机配置 |
| `setup-dsh` | 生成/安装 DSH 挂载配置（`bundle/cordis.patch.yml`） |
| `index` | 建索引（增量） |
| `reindex-cache` | 重建缓存的「地图 + instructions」 |
| `map` | 打印工作区地图 |
| `instructions` | 打印注入系统提示词的那段文字 |
| `search <关键词>` | 命令行检索 |
| `project <关键词>` | 用名称/域名/仓库/编号反查项目 |
| `audit` | 文件治理体检 |
| `organize` | 生成整理方案（**dry-run**，只出报告） |
| `coverage` | 覆盖度报告：暗区按「变亮要付什么代价」分层 |
| `doctor` | 自检：配置、索引、instructions 字节数等是否正常 |
| `ledger` | 台账相关操作 |
| `upstream` | 对接上游记忆中心的只读桥（需显式启用，默认不动） |
| `claims [目标] [--history] [--json]` | 读「你签过的判断」。`--install-guards` 装上「只可追加」触发器 |
| `help` | 列出全部命令（`--help` / `-h` 同效） |

不带任何参数时也打印这份命令清单。另有 `package.json` 的 `scripts` 别名
（`index` / `map` / `doctor` / `test` / `test:clean`）—— 那是给仓库开发者用的，不是 CLI 子命令。

---

## MCP 工具清单（12 个：11 个只读 + 1 个只追加）

工具名来自 `lib/mcp.js` 的工具注册表。在 DSH 里前缀是 `mcp__localvault__`。

| 工具 | 用途 |
| --- | --- |
| `vault_map` | 完整工作区地图：索引范围、权威入口文档、顶层目录用途、台账、规则摘要、类型分布 |
| `disk_coverage` | 覆盖度报告。暗区按**代价**分层（白捡 / 超限分块 / 格式解析 / OCR / 转录 / 解包 / 不必变亮） |
| `find_files` | 按关键词、类型、扩展名、时间、体积检索。中文按**子串**匹配，2 个字就能命中 |
| `find_project` | 用项目名 / 域名 / 仓库名 / P 编号反查项目卡片与资料目录 |
| `read_text` | 读索引内任意文本文件的正文（带行号与上限） |
| `list_directory` | 列某个目录下的条目，用于导航与盘点 |
| `recent_changes` | 最近改了什么（默认 7 天），适合接手他人在途工作 |
| `vault_audit` | 只读治理体检：`duplicates` / `stale` / `naming` / `inbox` / `root_clutter` / `links` |
| `propose_organize` | 按你的文件管理规则生成整理方案（**dry-run，只出报告**） |
| `refresh_index` | 索引过期或刚改过文件后重建（增量；默认后台跑，完成后再查） |
| `read_claims` | 读「你签过的判断」：当前状态，或 `history=true` 看完整事件流 |
| `triage` | 列待处理项，并把结论**追加**进判断记忆（L0 待签）。唯一会写东西的工具 |

前 11 个**不写任何东西**。第 12 个 `triage` 只能**往判断记忆里追加**一条机器条陈
（L0 待签）—— 不能改、不能删、不能替人签判断。数据库层有触发器兜底。

同时提供 5 个登记在册的资源：`vault://map`、`vault://guide`、`vault://projects`、`vault://recent`、`vault://claims`，
资源模板 `vault://file/{path}`，以及一个**未登记但可用**的别名 **`vault://overview`**
（与 `vault://map` 走同一个 handler，返回完全相同的内容；它不出现在 `resources/list` 里，
所以列表里看不到，但可以直接读）。

### 检索小抄

- 中文按**子串**匹配，不走分词：「上下文注入」能命中，搜「注入」也能命中。
- 多个词用空格分隔，**必须全部命中**（AND）。词越多越窄。
- 搜不到时的顺序：换同义词 → 缩短关键词 → 只搜文件名 → 加时间范围 → `refresh_index` 后再试。
- 结果里带 `matchedIn`（name / path / title / heading / body），能看出**为什么**命中。

---

## 覆盖度：谈「治理」之前先看这个

`coverage` 回答「这块盘有多黑」，并把暗区按**变亮所需的代价**分层——不按文件类型，因为类型驱动不了动作，代价才能。

引用覆盖度时**必须同时看两个数**：按文件数的覆盖率与按体量的覆盖率。它们可能差上百倍。
另有一档是**「不必变亮」**（动态库、字体、机器包、模型权重）——别把它算进分母。

---

## 索引的范围与边界

- 索引根由 `~/.localvault/config.json` 的 `roots` 决定。
- 跳过 `node_modules`、`.git`、`dist`、`build`、`site-packages` 等机器生成目录；
  `.app` 这类 bundle 只记一条元数据、不展开内部文件。
- 密钥类文件（`.env`、`*.pem`、`*.key`、`*credential*` 等）**只记录元数据，正文从未进入索引**。
- 索引库：`~/.localvault/vault.db`；配置：`~/.localvault/config.json`。

## 只读承诺

`localvault` 不会**移动、重命名或删除**任何文件。六项体检与 `organize` 全部只出报告；
要动文件必须由你逐条确认后另行操作。这是设计约束，不是当前版本的临时取舍。

## 许可

MIT —— 见包内 [`LICENSE`](./LICENSE)。

---

## 待确认

- **仓库地址待用户确认。** `package.json` 的 `repository` 目前用
  `git+https://github.com/qiuyiwu1989-star/localvault.git`，仓库名尚未最终确定。
