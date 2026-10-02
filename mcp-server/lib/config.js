'use strict';

/**
 * 配置加载。配置与索引都放在 vault 之外（默认 ~/.localvault），
 * 避免索引自己被索引、也避免治理动作污染工作区。
 */

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { expandHome, ensureDir, readJsonSafe, toPosix } = require('./util');

const DEFAULT_DATA_DIR = '~/.localvault';

/**
 * 通用默认根目录：**只包含这台机器上确实存在的标准用户目录**。
 *
 * 这里不假设任何特定工作区。用户真正的根目录应由 `localvault init`
 * 写入 ~/.localvault/config.json —— 通用软件不该猜你的盘长什么样。
 *
 * 顺序即优先级：先桌面（最可能有待整理的散文件），再下载。
 */
function defaultRoots(env = process.env) {
  const home = os.homedir();
  const found = [];
  const seen = new Set();

  const add = (p, label, priority) => {
    if (!p) return;
    const abs = path.resolve(expandHome(p));
    if (seen.has(abs)) return;
    let ok = false;
    try {
      ok = fs.statSync(abs).isDirectory();
    } catch {
      ok = false;
    }
    if (!ok) return;
    seen.add(abs);
    found.push({ path: abs, label, priority });
  };

  // Linux/BSD 上 XDG 可能把这两个目录改名或移位
  const xdg = readXdgUserDirs(home, env);
  add(xdg.XDG_DESKTOP_DIR || path.join(home, 'Desktop'), '桌面', 20);
  add(xdg.XDG_DOWNLOAD_DIR || path.join(home, 'Downloads'), '下载', 30);

  // 都没有时（少见）退到文档目录，而不是主目录整棵
  if (found.length === 0) add(path.join(home, 'Documents'), '文档', 20);
  return found;
}

/** 读 ~/.config/user-dirs.dirs（Linux）。读不到就返回空对象。 */
function readXdgUserDirs(home, env) {
  const file = path.join(env.XDG_CONFIG_HOME || path.join(home, '.config'), 'user-dirs.dirs');
  let text = '';
  try {
    text = fs.readFileSync(file, 'utf8');
  } catch {
    return {};
  }
  const out = {};
  for (const line of text.split('\n')) {
    const m = /^\s*(XDG_(?:DESKTOP|DOWNLOAD)_DIR)\s*=\s*"(.*)"\s*$/.exec(line);
    if (!m) continue;
    // 值形如 $HOME/Desktop
    out[m[1]] = m[2].replace(/^\$HOME/, home);
  }
  return out;
}

/**
 * 按目录名整体跳过的机器生成目录。只列确定性噪声，
 * 名字有歧义的（out/tmp/vendor）不列，避免漏掉真实资料。
 *
 * **这份表必须与 `app/Sources/LocalVault/VaultIndexer.swift` 的 `defaultIgnoredDirs`
 * 逐字一致。** 两边各有一份、都真的在用：
 * - CLI 走这张表；
 * - App 在 config.json **没有** `ignoredDirs` 时走它自己那张
 *   （向导自己建的配置就是这种情况 —— 它只拥有 version/dataDir/roots/primaryRoot）。
 *
 * 曾经这里写着「往 config.js 加，两边同时生效」—— 那是错的：向导建的配置不带
 * `ignoredDirs`，Swift 用的是自己那张硬编码表，config.js 改它一点都影响不到。
 * 现在由 `test/ignore-lists.js` 逐字比对两张表，分叉会直接让测试红。
 */
const DEFAULT_IGNORED_DIRS = [
  'node_modules', '.git', '.svn', '.hg', '.bzr',
  '__pycache__', '.mypy_cache', '.pytest_cache', '.ruff_cache', '.tox', '.nox',
  'dist', 'build', '.build', '.next', '.nuxt', '.svelte-kit', '.output', '.turbo',
  '.parcel-cache', '.vite', '.rollup.cache', 'coverage', '.nyc_output',
  'target', '.gradle', '.m2', '.cargo', '.rustup',
  '.idea', '.vs', 'Pods', 'Carthage', 'DerivedData', '.swiftpm', '.dart_tool',
  '.cache', '.npm', '.pnpm-store', '.yarn', '.Trash', '.Trashes',
  '.terraform', '.serverless', '.aws-sam', 'site-packages', '.ipynb_checkpoints',
  '.expo', '.angular', '.eslintcache',
  '.venv', 'venv', 'virtualenv', '.virtualenv',
  // `.aws` 与 `.ssh`/`.gnupg`/`.kube`/`.docker` 同类：机器生成的凭据目录。
  // 它以前不在表里，只靠「config 没有扩展名所以不算文本」这个巧合挡着 —— 巧合不算防护。
  '.ssh', '.gnupg', '.kube', '.docker', '.aws', '.codex', '.claude', '.dsh',
  '.zsh_sessions', '.zsh_history', '.DS_Store', 'Caches', 'Containers',
];

/**
 * 把默认表叠加到用户列表上。
 *
 * 起因（2026-10-02，实测）：`deepMerge` 对**数组是整体替换**，
 * 而 CLI 的 `init` 一定会往 config.json 写一份**完整快照**。
 * 于是默认表此后怎么改都到不了这台机器 —— 新版本补的忽略项对老用户永远不生效。
 * 实测本机：老配置 62 条完全盖掉默认表，SwiftPM 的 `.build/` 被索引了 220 行 / 161MB。
 *
 * 规则：默认项**一定生效**（它们是「机器生成的噪声」，不是内容）；用户**只能加**；
 * 要取消某个默认项，在数组里写 `!名字`（如 `"!build"`）。
 * 这样「默认」才是默认，同时用户仍然拿得回控制权。
 */
function mergeListDefaults(userList, defaults) {
  if (!Array.isArray(userList)) return defaults.slice();
  const cancelled = new Set(
    userList.filter((x) => typeof x === 'string' && x.startsWith('!')).map((x) => x.slice(1))
  );
  const out = [];
  const seen = new Set();
  for (const x of [...defaults, ...userList]) {
    if (typeof x !== 'string' || x === '' || x.startsWith('!')) continue;
    if (cancelled.has(x) || seen.has(x)) continue;
    seen.add(x);
    out.push(x);
  }
  return out;
}

/** 这些后缀一律是目录型 bundle，不进入。 */
const DEFAULT_IGNORED_DIR_SUFFIXES = [
  '.app', '.framework', '.bundle', '.xcodeproj', '.xcworkspace',
  '.photoslibrary', '.lproj', '.asar', '.plugin', '.kext', '.rtfd',
  '.download', '.noindex',
];

/** 永远不读取正文的文件（只保留元数据）。密钥/凭据类。 */
const DEFAULT_DENY_READ = [
  '.env', '.env.*', '*.env', '.netrc', '.npmrc', '.pypirc',
  '*.pem', '*.key', '*.crt', '*.p12', '*.pfx', '*.jks', '*.keystore',
  'id_rsa*', 'id_dsa*', 'id_ecdsa*', 'id_ed25519*',
  '*credential*', '*secret*', '*password*', '*passwd*', '*.kdbx',
  '*-service-account*.json', '*token*.json', '.credentials.yaml',
  '*.mobileprovision', '*.ovpn',
  // 从 `*.kubeconfig` 放宽成 `*kubeconfig*`：原写法只挡带后缀的，而**裸的 `kubeconfig`**
  // 和 `kubeconfig.yaml` 都挡不住 —— 后者会真的把 token 抽进正文、还能搜出来（实测）。
  // 更根本的一条：`.kube/` 之所以安全，靠的是它在上面的 ignoredDirs 里；
  // 一旦这个文件被复制出 `.kube/`，那层保护就没了。
  // 文件的安全性不该取决于它恰好坐在哪个目录。
  // 三种写法都收：kubeconfig / kube-config / kube_config。
  // 实测过 `.kube-config-prod.yaml` 能漏过去 —— 光收 `*kubeconfig*` 不够。
  '*kubeconfig*', '*kube-config*', '*kube_config*',
];

/** 允许抽取正文的扩展名（小写，含点）。 */
const TEXT_EXTENSIONS = new Set([
  '.md', '.markdown', '.mdx', '.txt', '.text', '.rst', '.org', '.adoc',
  '.json', '.json5', '.jsonc', '.ndjson', '.geojson',
  '.yml', '.yaml', '.toml', '.ini', '.cfg', '.conf', '.properties', '.env.example',
  '.xml', '.plist', '.csv', '.tsv', '.srt', '.vtt', '.log',
  '.js', '.mjs', '.cjs', '.ts', '.tsx', '.jsx', '.vue', '.svelte',
  '.py', '.rb', '.php', '.pl', '.lua', '.r',
  '.java', '.kt', '.kts', '.scala', '.groovy', '.clj',
  '.c', '.h', '.cc', '.cpp', '.hpp', '.cs', '.go', '.rs', '.swift', '.m', '.mm', '.dart',
  '.sh', '.bash', '.zsh', '.fish', '.ps1', '.bat', '.cmd',
  '.sql', '.graphql', '.gql', '.proto', '.http',
  '.html', '.htm', '.xhtml', '.css', '.scss', '.sass', '.less', '.styl',
  '.tex', '.bib', '.diff', '.patch', '.gitignore', '.gitattributes', '.editorconfig',
]);

/** 扩展名 → 大类。 */
const KIND_BY_EXT = {
  '.md': 'doc', '.markdown': 'doc', '.mdx': 'doc', '.txt': 'doc', '.text': 'doc',
  '.rst': 'doc', '.org': 'doc', '.adoc': 'doc', '.rtf': 'doc',
  '.pdf': 'doc', '.doc': 'doc', '.docx': 'doc', '.pages': 'doc', '.epub': 'doc',
  '.xls': 'sheet', '.xlsx': 'sheet', '.numbers': 'sheet', '.csv': 'sheet', '.tsv': 'sheet',
  '.ppt': 'slide', '.pptx': 'slide', '.key': 'slide',
  '.png': 'image', '.jpg': 'image', '.jpeg': 'image', '.gif': 'image', '.webp': 'image',
  '.svg': 'image', '.heic': 'image', '.tiff': 'image', '.bmp': 'image', '.ico': 'image',
  '.psd': 'image', '.ai': 'image', '.sketch': 'image', '.fig': 'image', '.xd': 'image',
  '.mp4': 'video', '.mov': 'video', '.mkv': 'video', '.avi': 'video', '.webm': 'video',
  '.m4v': 'video', '.flv': 'video', '.wmv': 'video',
  '.mp3': 'audio', '.wav': 'audio', '.m4a': 'audio', '.flac': 'audio', '.aac': 'audio',
  '.ogg': 'audio', '.aiff': 'audio', '.opus': 'audio',
  '.zip': 'archive', '.tar': 'archive', '.gz': 'archive', '.tgz': 'archive',
  '.rar': 'archive', '.7z': 'archive', '.dmg': 'archive', '.pkg': 'archive',
  '.iso': 'archive', '.jar': 'archive', '.war': 'archive',
  '.html': 'web', '.htm': 'web', '.xhtml': 'web', '.css': 'web', '.scss': 'web',
  '.sass': 'web', '.less': 'web', '.styl': 'web',
  '.json': 'data', '.json5': 'data', '.ndjson': 'data', '.geojson': 'data',
  '.yml': 'data', '.yaml': 'data', '.toml': 'data', '.ini': 'data', '.conf': 'data',
  '.xml': 'data', '.plist': 'data', '.sql': 'data', '.db': 'data', '.sqlite': 'data',
};

const CODE_EXTENSIONS = new Set([
  '.js', '.mjs', '.cjs', '.ts', '.tsx', '.jsx', '.vue', '.svelte',
  '.py', '.rb', '.php', '.pl', '.lua', '.r',
  '.java', '.kt', '.kts', '.scala', '.groovy', '.clj',
  '.c', '.h', '.cc', '.cpp', '.hpp', '.cs', '.go', '.rs', '.swift', '.m', '.mm', '.dart',
  '.sh', '.bash', '.zsh', '.fish', '.ps1', '.bat', '.cmd',
]);

function dataDir(config) {
  return expandHome((config && config.dataDir) || DEFAULT_DATA_DIR);
}

function defaultConfig() {
  return {
    version: 2,
    dataDir: DEFAULT_DATA_DIR,
    roots: defaultRoots(),
    ignoredDirs: [...DEFAULT_IGNORED_DIRS],
    ignoredDirSuffixes: [...DEFAULT_IGNORED_DIR_SUFFIXES],
    denyRead: [...DEFAULT_DENY_READ],
    maxTextBytes: 2 * 1024 * 1024,
    maxStoredBodyChars: 400000,
    maxDepth: 24,

    /**
     * 这三个都是**可选的覆盖项**，默认留空让系统自动发现。
     * 自动发现的结果会在 vault_map 里标注来源（据 `路径`）。
     */
    dirNotes: {},
    canonicalDocs: [],
    ledgerFile: null,
    rulesFile: null,

    /** 自动发现开关。关掉就只认上面显式写的配置。 */
    discover: {
      canonicalDocs: true,
      dirNotes: true,
      ledger: true,
      rules: true,
    },

    /**
     * 用户政策。**默认值不代表规范**，只是给检查一个起点。
     * 通用软件没有资格断言「根目录该放什么」——它只报告事实，
     * 「散文件」到底算不算问题由用户在这里定义。
     */
    policy: {
      /**
       * 根目录里被视为「导航文件」的名字模式（glob 风格）。
       * root_clutter 检查会把这部分从「散落文件」里排除。
       * 想让它严格报告根目录一切文件，设成 []。
       */
      rootNavPatterns: ['README*', 'readme*', 'INDEX*', 'index.*', '00-*', 'AGENTS.md', 'CLAUDE.md'],
      /**
       * 待整理目录名。默认 null = 不做这项检查，
       * 因为「待整理」是特定工作流的约定，不是普遍需求。
       */
      inboxDir: null,
      /**
       * 项目卡片目录（相对主根）。默认 null = 不做卡片关联。
       * 同样是可选工作流，不是普遍需求。
       */
      projectCardDir: null,
      /** 陈旧判定天数 */
      staleDays: 180,
      inboxStaleDays: 30,
      recentDays: 7,
      duplicateMaxFileBytes: 8 * 1024 * 1024,
      duplicateMaxTotalBytes: 512 * 1024 * 1024,
      /**
       * 版本化命名的词表。中英混排是默认值，用户可增删。
       * 含中文的词按「出现在文件名任意位置」匹配；
       * 纯 ASCII 的词按「落在词干末尾」匹配（`report-final.md` 命中，
       * `new-keystore.sh` 不命中）。
       */
      versionNamePatterns: [
        '最终版', '最后版', '最新版', '定稿', '终稿', '副本', '拷贝', '复件',
        '未命名', '修改版', '修订版', '备份', '旧的', '新的',
        'final', 'latest', 'copy', 'backup', 'bak', 'old', 'new', 'untitled', 'draft',
      ],
      /**
       * 是否识别操作系统的自动副本后缀：`报告 (1).md`、`方案 - 副本.md`。
       * 这是文件系统约定而非用户习惯，默认开。
       */
      detectCopySuffix: true,
    },

    /**
     * 主根。留空则取第一个索引根；多根时它只用于「相对路径」的基准，
     * 不再是「这个软件认识哪个工作区」的假设。
     */
    primaryRoot: '',
  };
}

function deepMerge(base, patch) {
  if (patch == null) return base;
  if (Array.isArray(patch)) return patch.slice();
  if (typeof patch !== 'object') return patch;
  const out = Array.isArray(base) ? base.slice() : { ...(base || {}) };
  for (const [k, v] of Object.entries(patch)) {
    if (v && typeof v === 'object' && !Array.isArray(v) && base && typeof base[k] === 'object' && !Array.isArray(base[k])) {
      out[k] = deepMerge(base[k], v);
    } else {
      out[k] = v;
    }
  }
  return out;
}

function configPath(cfg) {
  return path.join(dataDir(cfg || {}), 'config.json');
}

/**
 * 载入配置。优先级：环境变量 LOCALVAULT_CONFIG 指定的文件 > ~/.localvault/config.json > 默认。
 * 环境变量 LOCALVAULT_ROOTS（冒号分隔）可覆盖根目录，便于测试与临时使用。
 */
function loadConfig(overrides) {
  const envPath = process.env.LOCALVAULT_CONFIG;
  let cfg = defaultConfig();

  // 先应用能影响「配置文件位置」的环境变量，再读配置文件。
  if (process.env.LOCALVAULT_DATA_DIR) cfg.dataDir = process.env.LOCALVAULT_DATA_DIR;

  const file = envPath ? expandHome(envPath) : configPath(cfg);
  const fromFile = readJsonSafe(file);
  if (fromFile && typeof fromFile === 'object') cfg = deepMerge(cfg, fromFile);

  // 环境变量优先级高于配置文件
  if (process.env.LOCALVAULT_DATA_DIR) cfg.dataDir = process.env.LOCALVAULT_DATA_DIR;
  if (process.env.LOCALVAULT_ROOTS) {
    cfg.roots = process.env.LOCALVAULT_ROOTS.split(path.delimiter)
      .filter(Boolean)
      .map((p, i) => ({ path: p, label: `根${i + 1}`, priority: 10 + i * 10 }));
  }
  if (overrides) cfg = deepMerge(cfg, overrides);

  // 向后兼容：v1 用的键名是 governance，v2 统一叫 policy。
  // 用户文件里那份仍然生效，但代码只认 policy。
  if (fromFile && fromFile.governance && typeof fromFile.governance === 'object') {
    const legacy = { ...fromFile.governance };
    if (legacy.versionSuffixPatterns && !legacy.versionNamePatterns) {
      legacy.versionNamePatterns = legacy.versionSuffixPatterns;
    }
    delete legacy.versionSuffixPatterns;
    cfg.policy = deepMerge(cfg.policy, legacy);
  }
  if (cfg.governance && typeof cfg.governance === 'object' && fromFile && !fromFile.governance) {
    // 默认配置里已无 governance；防御性处理外部注入
    cfg.policy = deepMerge(cfg.policy, cfg.governance);
  }
  delete cfg.governance;

  // 规范化
  cfg.version = 2;

  // 两张「忽略/不读」表按**叠加**解释，不是替换。
  // 原因见 `mergeListDefaults`：数组在 deepMerge 里是整体替换，
  // 用户文件里那份快照会让默认表的后续修改永远到不了这台机器。
  // 放在最末尾：env / overrides 都应用完之后，用户写的 `!名字` 也能被看到。
  cfg.ignoredDirs = mergeListDefaults(cfg.ignoredDirs, DEFAULT_IGNORED_DIRS);
  cfg.denyRead = mergeListDefaults(cfg.denyRead, DEFAULT_DENY_READ);

  cfg.roots = (cfg.roots || []).map((r, i) => {
    const obj = typeof r === 'string' ? { path: r } : { ...r };
    obj.path = expandHome(obj.path);
    obj.label = obj.label || path.basename(obj.path) || `根${i + 1}`;
    obj.priority = Number.isFinite(obj.priority) ? obj.priority : 10 + i * 10;
    return obj;
  });
  cfg.policy = normalizePolicy(cfg.policy);
  cfg.primaryRoot = expandHome(cfg.primaryRoot || (cfg.roots[0] && cfg.roots[0].path) || '.');
  cfg.configFile = file;
  cfg.dataDirAbs = dataDir(cfg);
  cfg.dbPath = path.join(cfg.dataDirAbs, 'vault.db');
  return cfg;
}

/** policy 的默认值与类型规范化。用户给的任何字段都保留，缺失的补默认。 */
function normalizePolicy(policy) {
  const base = defaultConfig().policy;
  const p = { ...base, ...(policy || {}) };
  for (const k of ['staleDays', 'inboxStaleDays', 'recentDays', 'duplicateMaxFileBytes', 'duplicateMaxTotalBytes']) {
    p[k] = Number.isFinite(Number(p[k])) ? Number(p[k]) : base[k];
  }
  if (!Array.isArray(p.versionNamePatterns)) p.versionNamePatterns = base.versionNamePatterns;
  // null 是合法值（表示不检查），只有 undefined 才回落
  if (p.inboxDir === undefined) p.inboxDir = base.inboxDir;
  if (p.projectCardDir === undefined) p.projectCardDir = base.projectCardDir;
  if (!Array.isArray(p.rootNavPatterns)) p.rootNavPatterns = base.rootNavPatterns;
  return p;
}

/** 首次运行时把默认配置落盘，方便用户改。 */
function writeDefaultConfigIfMissing(cfg) {
  const file = configPath(cfg);
  ensureDir(path.dirname(file));
  if (fs.existsSync(file)) return false;
  const snapshot = defaultConfig();
  snapshot.roots = cfg.roots.map((r) => ({ ...r, path: compressHomeish(r.path) }));
  snapshot.dataDir = cfg.dataDir;
  snapshot.primaryRoot = compressHomeish(cfg.primaryRoot);
  fs.writeFileSync(file, JSON.stringify(snapshot, null, 2) + '\n', 'utf8');
  return true;
}

function compressHomeish(p) {
  const { compressHome } = require('./util');
  return toPosix(compressHome(p));
}

/** denyRead 的 glob 匹配（只支持 * 和 ?，逐段匹配）。 */
function globToRegExp(glob) {
  let re = '';
  for (const ch of glob) {
    if (ch === '*') re += '[^/]*';
    else if (ch === '?') re += '[^/]';
    else if ('\\^$.|+()[]{}'.includes(ch)) re += '\\' + ch;
    else re += ch;
  }
  return new RegExp('^' + re + '$', 'i');
}

function buildDenyMatchers(patterns) {
  return (patterns || []).map((p) => ({ raw: p, re: globToRegExp(p.replace(/^\.\//, '')) }));
}

/** 文件是否禁止读取正文。 */
function isDeniedRead(name, matchers) {
  return matchers.some((m) => m.re.test(name));
}

/** 目录是否整体跳过。 */
function shouldSkipDir(name, cfg) {
  return skipReason(name, cfg) !== null;
}

/**
 * 目录被跳过的原因。
 * - 'ignored-name'：机器生成目录（node_modules/.git/dist…），完全不记录；
 * - 'ignored-suffix'：目录型 bundle（.app/.framework/.photoslibrary…），
 *   记录一条元数据当「这是一个包」，但不展开内部成百上千个文件。
 */
function skipReason(name, cfg) {
  if (!name) return null;
  if (cfg.ignoredDirs.includes(name)) return 'ignored-name';
  const lower = name.toLowerCase();
  if (cfg.ignoredDirSuffixes.some((s) => lower.endsWith(s))) return 'ignored-suffix';
  return null;
}

function kindOf(ext) {
  return KIND_BY_EXT[ext] || (CODE_EXTENSIONS.has(ext) ? 'code' : 'other');
}

function isTextExt(ext) {
  return TEXT_EXTENSIONS.has(ext);
}

module.exports = {
  DEFAULT_DATA_DIR,
  defaultRoots,
  DEFAULT_IGNORED_DIRS,
  DEFAULT_DENY_READ,
  TEXT_EXTENSIONS,
  CODE_EXTENSIONS,
  KIND_BY_EXT,
  defaultConfig,
  loadConfig,
  configPath,
  dataDir,
  writeDefaultConfigIfMissing,
  globToRegExp,
  buildDenyMatchers,
  isDeniedRead,
  shouldSkipDir,
  skipReason,
  kindOf,
  isTextExt,
  deepMerge,
};
