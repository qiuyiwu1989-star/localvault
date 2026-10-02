# 接进 agent（MCP）

localvault 有两种用法。**只用 App**：双击打开，看地图、看判断、看治理体检。
**接进 agent**：让 Claude / Cursor / DSH 这些能调用工具的 AI **直接查你的本机文件**。

第二种才是这个工具真正值钱的地方 —— 索引建好之后，agent 就不用靠你复制粘贴资料了。

> 这份文档之前**不存在**。索引、检索、治理都做完了，唯独「怎么让 agent 用上」没写。
> 最后一公里是空的，前面做得再对也没人走到。

---

## 先确认两件事

**一、Node 版本 ≥ 22.5。**

```sh
node --version
```

低于 22.5 会直接报错退出，不会崩。原因：用了内置的 `node:sqlite`，没装任何第三方依赖。

系统里没有 node 也没关系 —— 装了 App 的话，App 里带了一份运行时：

```sh
# App 里 CLI 的路径（如果你只装了 dmg）
/Applications/本地上下文.app/Contents/Resources/CLI/cli.js
```

**二、索引已经建好了。**

MCP 服务器只是读索引，不自己建。先建一次：

```sh
node cli.js init      # 只探测 ~/Desktop 和 ~/Downloads，生成配置
node cli.js index     # 真正扫描，写入索引库
```

或者在 App 的向导里点一次。默认索引库在 `~/.localvault/vault.db`。

**没建索引也能接**，但 agent 什么都查不到 —— 而且「查不到」和「文件不存在」在工具返回值里长得不一样，别自己骗自己。

---

## 一条命令搞定（DSH 用户）

如果你用的是 DeepSeek Harness：

```sh
node cli.js setup-dsh
```

它会生成一份补丁文件并把路径给你，在 DSH 里 `Plugins → Add plugin → 粘贴路径 → Enable now` 就行。
路径是这台机器的绝对路径，**每台机器跑一次**。

下面三种是其他客户端的接法。

---

## Claude Desktop

编辑配置文件：

| 系统 | 路径 |
| --- | --- |
| macOS | `~/Library/Application Support/Claude/claude_desktop_config.json` |

在 `mcpServers` 里加一条：

```json
{
  "mcpServers": {
    "localvault": {
      "command": "/绝对路径/到/node",
      "args": ["/绝对路径/到/mcp-server/server.js"],
      "cwd": "/绝对路径/到/mcp-server"
    }
  }
}
```

**三个都要用绝对路径。** Claude Desktop 不继承你 shell 的 `PATH`，写 `node` 会找不到。
不知道 node 在哪：`which node`。

`cwd` 不写也能跑，但写了更稳 —— 服务器会以它为相对路径的基准。

改完**完全退出 Claude Desktop 再打开**（不是关窗口，是退出进程），否则配置不重载。

---

## Cursor

`.cursor/mcp.json`（项目级）或 `~/.cursor/mcp.json`（全局）：

```json
{
  "mcpServers": {
    "localvault": {
      "command": "/绝对路径/到/node",
      "args": ["/绝对路径/到/mcp-server/server.js"],
      "env": {
        "LOCALVAULT_DATA_DIR": "/Users/你的用户名/.localvault"
      }
    }
  }
}
```

`LOCALVAULT_DATA_DIR` 不写就是默认的 `~/.localvault`。**只有当你想让 agent 查一份不属于你自己的索引时才需要写**（比如演示用的一份假数据）。

---

## 任何支持 stdio 的 MCP 客户端

约定都一样：

| | |
| --- | --- |
| 传输 | **stdio**（不是 HTTP，不开端口，不监听） |
| 启动 | `<node 绝对路径> /绝对路径/到/mcp-server/server.js` |
| stdout | **只走 JSON-RPC 协议帧** —— 日志一律走 stderr |
| 环境变量 | `LOCALVAULT_DATA_DIR`（可选，默认 `~/.localvault`） |

「不开端口」这件事是刻意的：这个进程只在你本机跑，不对外监听任何东西。

> 如果你在 Electron 类宿主里跑（比如 DSH），可能要多加一个环境变量：
> `ELECTRON_RUN_AS_NODE: "1"`。否则 `process.execPath` 指的是 Electron 本身而不是 node。
> `setup-dsh` 生成的补丁里已经带上了。

---

## 怎么知道接通了

接好之后，在 agent 里问一句能让它去列工具的话，比如「列出 localvault 提供的工具」。

**你应该看到 10 个工具**：

| 工具 | 干什么用 | 什么时候该让 agent 用它 |
| --- | --- | --- |
| `vault_map` | 本机「本地上下文」地图：索引了哪些根、各目录用途、权威入口文档、项目台账概况、类型分布 | **每次接手新话题前先问一次** —— 它决定了后面该看哪些文件 |
| `find_files` | 在索引里检索。中文按子串匹配（两个字就能命中），同时匹配文件名、路径、标题、正文 | 「XX 相关的资料在哪」 |
| `read_text` | 读某个文本文件的正文（带行号） | 找到文件后看内容 |
| `find_project` | 用项目名 / 域名 / 仓库名 / 编号反查项目 | 「XX 项目现在什么状态」 |
| `list_directory` | 列某个目录下的条目 | 「这个目录里都有什么」 |
| `recent_changes` | 最近改动的文件（默认 7 天），按目录聚合 | **接手别人在途的工作** |
| `vault_audit` | 文件治理体检（只读）：重复文件、陈旧文件、版本化命名、待整理积压、根目录堆积、断链 | 「我的文件有没有乱」 |
| `propose_organize` | 生成整理方案（dry-run） | 想动手整理前的「先看看会怎么整」 |
| `disk_coverage` | 覆盖度报告：有多少文件真能搜到，暗区按「变亮要付什么代价」分层 | 「为什么我搜不到 XX」 |
| `refresh_index` | 增量重建索引 | **你刚改过文件，要让 agent 看到最新的** |

**还有 4 个资源**（有些客户端会单独列出来）：
`vault://map`、`vault://guide`、`vault://projects`、`vault://recent`，
以及一个模板 `vault://file/{path}` 用来按路径读文件。

### 最有用的第一句

> **「先读 vault://map，告诉我这台机器上都有什么。」**

这句话能让 agent 自己搞清楚索引范围、目录用途和入口文档，后面就不需要你一句句交代背景了。

---

## agent 能看到的和不能看到的

**能**：已索引根目录下的**文件名、路径、正文**。

**不能**（这是设计，不是缺陷）：

- **不能改你的文件。** 所有工具都是只读的；`propose_organize` 只出报告，执行要你逐条确认。
- **不能读密钥类文件。** `.env`、`*.pem`、`*.key`、`*credential*` 这一类走的是排除规则，`read_text` 会明确拒绝，不会把正文吐出来。
- **不能读索引根之外的文件。** `read_text` 对不在配置根内的路径直接拒绝，哪怕它确实存在。
- **不能上网。** 这个服务器不发任何网络请求。

一句话：**agent 看到的是你索引过的那些文件，只读，且仅限本机。**

细节见 `隐私.md`。

---

## 常见问题

**「工具列表是空的」**
服务器没起来。去看客户端的 MCP 日志（Claude Desktop 的日志在
`~/Library/Logs/Claude/mcp*.log`）。多半是 `command` 写成了裸 `node` 而不是绝对路径。

**「能列出工具，但每个都返回空」**
索引库是空的。跑一次 `node cli.js index`，然后在 agent 里调 `refresh_index`。

**「刚改的文件搜不到」**
索引是快照，不是实时。让 agent 调一次 `refresh_index`，或者你自己跑 `node cli.js index`。

**「Node 版本不够」**
会明确说 `需要 Node >= 22.5（当前 vXX）` 然后退出码 2。升级 Node，或者把 `command` 指向 App 里带的那份运行时。

**「改完配置没反应」**
完全退出客户端再打开。Claude Desktop 和 Cursor 都是启动时读一次配置。

**「能不能让 agent 整理我的文件」**
不能自动整理。`propose_organize` 出方案，你看了以后自己决定 —— 或者将来走「可审阅的操作清单 + 逐条确认」那条路（还没做）。
