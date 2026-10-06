# 自制破甲 · WorkBuddy 人格部署工具

> 一键把自定义「人格」（system prompt / 用户级指令）注入到本地已安装的 AI 编程客户端——
> 每个请求都带上你指定的人格，模型开局就按你的规矩干活。

- **零改包优先**：能用原生用户级指令文件（`AGENTS.md` / `SOUL.md`）的目标，绝不碰程序文件。
- **可完整还原**：所有写入前先备份，`restore` 一键回到原始状态，绝不误删用户自己的文件。
- **跨版本鲁棒**：动态扫描 bundle + 多锚点匹配，客户端小版本升级后仍能定位注入点。
- **纯 PowerShell**：无第三方依赖，Windows 原生即可运行。

---

## 一、支持的目标

| 编号 | 目标 | 版本 | 注入通道 | 生效方式 |
| :---: | :--- | :--- | :--- | :--- |
| 1 | **WorkBuddy** | 国内版 | 拦截发送层（补丁 CLI bundle） | 需重启 |
| 2 | **WorkBuddyAI** | 国际版 | 拦截发送层（补丁 CLI bundle） | 需重启 |
| 3 | **Qoder** | 国际版 | 原生 `~/.qoder/AGENTS.md` | 免重启 |
| 4 | **Qoder CN** | 国内版 | 原生 `~/.qoder-cn/AGENTS.md` | 免重启 |
| 5 | **Hermes** | — | 原生 `SOUL.md` | 免重启 |
| 6 | **Codex** | — | 全局 `AGENTS.md` | 免重启 |
| 7 | **ZCode** | — | 全局 `~/.zcode/AGENTS.md` | 免重启 |

> 「需重启」指必须重启客户端进程；「免重启」指下一会话即可生效。

---

## 二、目录结构

```
自制破甲/
├─ 部署.bat                  # 双击 → 交互式：选目标 → 选人格 → 部署
├─ 恢复.bat                  # 双击 → 交互式：选目标 → 还原原始状态
├─ 查看状态.bat              # 双击 → 只读体检，不写任何文件
├─ deploy.ps1                # 主程序：install / restore / status
├─ deploy-lib.ps1            # 核心库：路径探测、bundle 扫描、注入模板、目标菜单
├─ deploy-intl.ps1           # WorkBuddyAI 兼容入口（固定转发到 deploy.ps1）
├─ 人格.txt                  # 发送层人格正文（WorkBuddy 目标读取此文件）
├─ 人格/                      # 人格库
│  ├─ 01…11-*.txt            # 逆向/工程/文档等角色人格
│  ├─ R.txt                  # 强化协议版人格
│  ├─ README.md              # 人格矩阵索引
│  ├─ raw_templates/         # 原始提示词模板
│  └─ 角色人格/               # 标准化角色卡（Markdown 版）
├─ tests/                    # 回归 / 干跑验证脚本
├─ templates-backup/         # 部署时自动生成的模板备份（运行期产物）
├─ 修改记录.md                # 完整开发与调试记录
└─ seed_trace.txt            # 部署探针标记
```

---

## 三、快速开始

### 图形化（推荐）

1. 双击 **`部署.bat`**
2. 按菜单输入编号选择**目标**（1–7）
3. 选择要注入的**人格**文件
4. WorkBuddy 系目标重启客户端；其余目标新开一个会话即可

还原：双击 **`恢复.bat`**，选同一个目标即可。
体检：双击 **`查看状态.bat`**，只读检查当前注入状态，不修改任何文件。

### 命令行

```powershell
# 部署（目标 + 人格文件名）
.\deploy.ps1 install workbuddyai R.txt

# 查看状态
.\deploy.ps1 status workbuddyai

# 还原
.\deploy.ps1 restore workbuddyai
```

`-Target` 可选值：`workbuddy` / `workbuddyai` / `qoder` / `qodercn` / `hermes` / `codex` / `zcode`。
`-Persona` 只接受 `人格\` 目录下的**文件名**，不接受路径。

---

## 四、工作原理

### 1. 发送层拦截（WorkBuddy / WorkBuddyAI）

不跟上游的提示词拼装管线纠缠，直接在**最后一棒**拦截：

```
上游主进程拼装 34K 产品系统提示词
        │
        ▼
Completions.create() / Responses 调用点   ← 在 CLI bundle 中打补丁
        │  发送前 readFileSync("人格.txt")
        │  → 替换 / 插入 system 消息
        ▼
HTTPS POST → 远端 API 收到的 system = 人格.txt 原文
```

优点：上游怎么改模板、插件、配置、自动更新都不影响——发送口在本地脚本手里。换人格 = 改 `人格.txt`，**下一个请求立即生效**。

### 2. 原生用户级指令（Qoder / Hermes / Codex / ZCode）

这些客户端本身就支持读取用户级指令文件。本工具只往它原生支持的位置写文件，**不改任何程序包**：

| 目标 | 写入位置 |
| :--- | :--- |
| Qoder | `~/.qoder/AGENTS.md` |
| Qoder CN | `~/.qoder-cn/AGENTS.md` |
| Hermes | `~/.hermes/SOUL.md`（按版本探测） |
| Codex | `~/.codex/AGENTS.md` |
| ZCode | `~/.zcode/AGENTS.md` |

ZCode 走 `ZCODE-LOCK` 包装头 + 人格原文整体写入，声明用户级全局指令优先于工作区 `<repo>/AGENTS.md`。

### 3. 备份与还原

- **写入前**：若目标文件已有用户自有内容 → 先备份到 `*-backup\`
- **还原时**：有备份 → 还原备份；无备份 → 仅当内容**逐字节确认**为本工具注入时才删除
- **绝不误删**用户自己写的 `AGENTS.md` / `SOUL.md`

---

## 五、测试

```powershell
# 国际版结构性回归（始终可跑，不依赖是否已部署）
.\tests\regression-workbuddyai-headless.ps1

# 补丁干跑验证（不落盘，只校验锚点与预期注入点）
.\tests\verify-patch-dryrun.ps1
```

---

## 六、免责声明

- 本工具用于**在你自己拥有/自建的本地环境中**定制 AI 客户端的行为。
- 使用前请确认**不违反**对应软件的最终用户许可协议（EULA）与服务条款；由此产生的一切后果由使用者自负。
- 本仓库**不包含**任何商业客户端的二进制文件、安装包或其内容（如 `app.asar`），仅包含脚本与文本资源。
- 人格文件中的提示词内容由使用者自行负责。

---

## 七、相关文档

- [`修改记录.md`](修改记录.md) — 完整开发与调试记录（版本演进、踩坑、根因分析）
- [`人格/README.md`](人格/README.md) — 人格矩阵索引与适用场景
