---
name: local-context-mcp
description: Use when a task concerns files, documents, projects, or materials on this machine — finding where something lives, what a local project is, what changed recently, what the configured roots' authoritative entry documents say, or organizing/governing local files. Covers the localvault MCP and its read-only governance checks (duplicates, stale files, version-named copies, inbox backlog, root clutter, broken links). Also use before answering any question whose answer should come from local files rather than memory or guesswork.
whenToUse: 当问题涉及本机文件、资料位置、本地项目、最近改动、目录结构、文件整理与治理时。也用于「先看看本地有什么」这类没有指明具体路径的开场请求。
---

# 本地上下文：先检索，再回答

本机有一个 `localvault` MCP，索引了用户配置的若干根目录，并把**目录地图注入系统提示词**。
它的存在只为一件事：**让「本机有什么」变成可查的事实，而不是靠印象猜。**

## 铁律

1. **凡涉及本机文件、路径、项目归属、资料位置，先调用工具，再回答。** 不要凭记忆写路径。
2. **索引是快照。** 地图里有数据基线时间；要断言"现在是什么状态"，先看基线，必要时
   `mcp__localvault__refresh_index`。
3. **工具只读。** 它不会移动、重命名、删除任何文件。所有整理动作都要另走文件操作并经用户确认。
4. **凡引用盘点类事实（服务器状态、项目清单、资产归属）必须带采集日期。** 盘点结果是某个
   时点的快照，不等于当前状态。
5. **找不到就说找不到。** 不要用常见路径反推，也不要把"应该在那里"写成"在那里"。

## 这个工作区长什么样：从 `vault_map` 拿，不要假设

**索引根、顶层目录、入口文档、台账位置、规则文档，全部由配置和磁盘内容决定，
每台机器都不一样。** 因此：

- 谈目录结构、找权威入口之前，**先调 `vault_map`**，看它实际列出了什么。
- 地图里的目录用途有两类来源，看 `noteSource`：
  - `config` —— 用户显式配置的（可信度最高）
  - 某个文件路径 —— **自动推断的**，依据是该目录下的 README/索引文档的标题。
    出现这种来源时，**引用前先扫一眼那个文件确认**，推断可能猜错。
- 地图的 `discovery` 字段会说明哪些东西是推断的、推断依据是什么、有多少项来自 config。
- **不要沿用对话历史里见过的目录名或文档名。** 换一台机器就全变了。
- 权威入口文档存在就优先读；`vault_map` 里标 `origin: config` 的是用户指定的，
  `origin: auto` 的是推断出来的。

## 什么时候用哪个工具

| 场景 | 工具 |
| --- | --- |
| 开局、确认目录结构与权威入口 | `mcp__localvault__vault_map` |
| **判断「值不值得治理」「先做哪一层」** | `mcp__localvault__disk_coverage` |
| 找资料（中文直接搜词，2 个字也能命中） | `mcp__localvault__find_files` |
| 「XX 项目是什么/在哪/域名/仓库」 | `mcp__localvault__find_project` |
| 读某个文件的正文（带行号） | `mcp__localvault__read_text` |
| 看某个目录里都有什么 | `mcp__localvault__list_directory` |
| 接手在途工作，先看最近动了什么 | `mcp__localvault__recent_changes` |
| 文件治理体检 | `mcp__localvault__vault_audit` |
| 生成整理方案（只出报告） | `mcp__localvault__propose_organize` |
| 索引过期 / 刚改过文件 | `mcp__localvault__refresh_index` |

检索技巧：

- 中文按**子串**匹配，不走分词。「上下文注入」能命中，搜「注入」也能命中。
- 多个词用空格分隔，**必须全部命中**（AND）。词越多越窄。
- 搜不到时的顺序：换同义词 → 缩短关键词 → `scope: "name"` 只搜文件名 → 加 `since` 限定时间。
- 结果里带 `matchedIn`（name/path/title/heading/body），能看出**为什么命中**，据此判断相关性。

## 覆盖度：谈"治理"之前先看这个

`disk_coverage` 回答"这块盘有多黑"，并把暗区**按变亮所需的代价**分层——不是按文件类型。
因为类型驱动不了动作，代价才能：

| 档位 | 代价 | 该怎么用 |
| --- | --- | --- |
| 已有正文 | — | 已可搜 |
| 白捡（抽取 bug） | 零 | 有就先修，不需要任何架构改动 |
| 超限分块 | 零 | 调大上限或分块 |
| 需要格式解析（PDF/Office） | 零（算力） | 确定性解析，不调模型 |
| 需要 OCR（图片） | 本地免费 / 云端花钱 | 先问值不值得 |
| 需要转录（音视频） | 花钱 + 耗时 | 体量最大的一档，最该慎重 |
| 需要解包 | 低，但常常不值得 | 解包后往往又是几千个文件 |
| **不必变亮** | — | 动态库/字体/机器包/模型权重；**别把它们算进分母** |

**引用覆盖度时必须同时说两个数**：按文件数的覆盖率与按体量的覆盖率。它们能差上百倍。

**"不必变亮"那一档是这份报告最容易被误读的地方**：扣掉它之后的分母才是真正需要讨论的。
不驱动动作的"暗"，和不驱动动作的维度一样，都是装饰。

## 文件治理：怎么用这份体检报告

`vault_audit` 可以跑六项：`duplicates`（内容哈希去重）、`stale`（陈旧）、`naming`
（版本化命名）、`inbox`（收集目录积压）、`root_clutter`（根目录散文件）、`links`（Markdown 断链）。
可按需只跑其中几项。

**这些检查判定"什么算问题"用的是用户在 `policy` 里定义的标准，不是通行规范。**
所以：

- `inbox` 未配置时（默认）会显示「未配置，已跳过」——**这是正常的，不是故障**。
  用户没有「固定收集目录」这种工作流时就不该检查这项。不要把它当成缺失项去补。
- `root_clutter` 只报告根目录有多少文件、多少目录。**它不判定这些文件该不该在根目录。**
- `naming` 的词表来自 `policy.versionNamePatterns`。**不要把命中说成"命名违规"** ——
  那是用户自己的词表命中，换个词表结果就变。

**呈现给用户时的规矩：**

- 报告是**建议，不是待办**。先说结论数字，再问用户要不要看某一部分的明细。
- 一次只推进一类，不要一口气把六项都倒给用户。
- **不要自行执行任何整理动作。** 拿到 `propose_organize` 的清单后，逐条和用户确认；
  真正改动时走正常文件操作，并遵守下面的红线。
- 判断顺序（与硬脑决策层一致）：先看 再生性（丢了能不能重新拿到），再看 归属，
  再看 时效。**"价值"不是一个可以直接判定的维度。**

## 红线

1. **零删除。** 整理只做移动与归档，不做物理删除。删除只能由用户自己执行。
2. **能撤的动作先备份再动手。** 移动前记录原路径清单。
3. **不驱动动作的维度不要建。** 不要为了"信息完整"给用户加字段、加评分、加分类。
4. **宁可不判，也不要给一个自信的错答案。** 置信度不足就写"待判"，交给用户拍板。
5. **不假装有数据。** 界面上、报告里凡是推断出来的，标明是推断及依据。

## 索引范围与边界

- 索引根由 `~/.localvault/config.json` 的 `roots` 决定。**实际值看 `vault_map`，不要背。**
- 跳过：`node_modules`、`.git`、`dist`、`build` 等机器生成目录；`.app` 这类 bundle
  目录只记一条元数据、不展开内部文件。
- 密钥类文件（`.env`、`*.pem`、`*.key`、`*credential*` 等）**只记录元数据，正文从未进入索引**。
- 索引库：`~/.localvault/vault.db`；配置：`~/.localvault/config.json`。
- 不联网、不上传。全部在本机。

## 如果工具不可用

先确认 MCP 是否连上（工具名前缀 `mcp__localvault__`）。连不上时退回普通文件工具，
但要**明确告诉用户这次没有走索引**，不要静默降级成猜测。
