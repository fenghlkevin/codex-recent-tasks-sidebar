# Codex 最近任务栏

一个原生 macOS 伴生小工具：直接显示最近活跃的 Codex 任务时间、运行状态和未读更新状态，按工作文件夹分组，并可精确跳转到对应任务。

它支持吸附在 Codex 左侧或右侧、跟随 Codex 前后层级，也可以切换为独立置顶窗口。应用有自己的图标和 Dock 入口。

> 非 OpenAI 官方项目。任务列表、运行状态和未读状态只读取本机 Codex 数据；剩余用量默认通过 ChatGPT / Codex 自带的官方服务联网读取。不上传任务，不修改数据库、rollout 事件流、任务备注索引或未读状态。

## 最快使用：把这段话交给任意智能体

```text
请克隆 https://github.com/chuanfan-ai/codex-recent-tasks-sidebar-skill ，完整阅读 skills/codex-recent-tasks-sidebar/SKILL.md，直接使用仓库内模板构建 Codex 最近任务栏。先运行 ./scripts/qa.sh，确认构建、签名、固定测试库、自检和脱敏扫描全部通过；再真实启动 App，验证图标与 Dock、左右吸附、跟随 Codex 前后台、单独置顶、点击任务精确跳转。未经我确认不要覆盖 /Applications 里的现有 App，也不要读取、打印、复制或上传我的真实任务内容。
```

适用于 Codex、Claude Code 及其他能读取本地文件、执行终端命令的智能体。

## 自己构建

要求：

- macOS 13 或更高版本
- 已安装并至少使用过一次 Codex / ChatGPT 桌面端
- 如需显示剩余用量，ChatGPT / Codex 需处于已登录状态
- 已安装 Xcode Command Line Tools，系统存在 `/usr/bin/swiftc`

```bash
git clone https://github.com/chuanfan-ai/codex-recent-tasks-sidebar-skill.git
cd codex-recent-tasks-sidebar-skill
./scripts/qa.sh
open "build/CodexRecentTasksSidebar.app"
```

构建产物位于 `build/CodexRecentTasksSidebar.app`，窗口和 Dock 中仍显示“Codex 最近任务”。确认无误后，可以手动拖入“应用程序”文件夹。

## 功能

- 从 `~/.codex/state_5.sqlite` 或兼容位置只读加载主任务。
- 从 `~/.codex/session_index.jsonl` 只读合并最新任务备注，改名后会在下一次 30 秒刷新时同步。
- 从任务自己的 `~/.codex/sessions/` rollout 事件流只读判断状态：运行时显示蓝色“运行中”；等待用户输入或命令授权时显示橙色“待操作”。
- 从 `~/.codex/.codex-global-state.json` 只读匹配 Codex 为当前顶层任务记录的未读更新；任务停止后才显示绿色“待查看”。内部子线程残留不会被误算到顶层任务。
- 自动排除归档任务、存在真实父子关系的子智能体和内部线程；不会因新版 Codex 的宽泛来源标签误删顶层任务。
- 按真实工作目录分组；同一文件夹保留全部近期任务。
- 文件夹和任务都按最近活动时间倒序排列。
- 每条任务使用唯一 Thread ID，通过 `codex://threads/{id}` 精确打开。
- 左右吸附 Codex，也支持拖动切换吸附侧。
- 吸附模式跟随 Codex：Codex 前置时同步前置，切换其他应用时自动后置。
- 单独置顶模式保持全局前置并可自由拖动。
- 默认显示 Codex 剩余用量百分比，不显示重置时间；读取失败不影响任务列表。
- 自带应用图标、Dock 入口、菜单栏入口和搜索；运行状态每 5 秒、任务和备注每 30 秒、用量每 60 秒刷新。

## 仓库结构

```text
.
├── README.md
├── AGENTS.md / CLAUDE.md
├── scripts/
│   ├── build_app.sh
│   └── qa.sh
└── skills/codex-recent-tasks-sidebar/
    ├── SKILL.md
    ├── agents/openai.yaml
    ├── scripts/build_app.sh
    └── assets/app-template/
        ├── Codex最近任务栏.swift
        ├── Info.plist
        └── AppIcon.icns
```

Skill 文件夹可以单独安装，也可以让智能体直接读取。完整仓库额外提供固定测试库、脱敏扫描和 GitHub Actions。

## 隐私边界

- 不提交、不复制真实 Codex 数据库。
- 不在日志中打印任务正文、Thread ID 或本机用户名路径。
- App 对 Codex 数据库只执行只读查询，并只提取 rollout 状态标记、任务备注索引和未读更新状态；不显示、保存或上传 rollout 正文。
- 剩余用量通过 ChatGPT / Codex 自带的官方 `app-server` 和当前登录状态联网读取；App 只保留内存中的百分比，不读取、输出或保存 Token 与重置时间。
- 本地仅通过 `UserDefaults` 保存窗口位置、吸附侧和显示模式。
- `build/`、SQLite、日志和本机缓存均被 `.gitignore` 排除。

## 验收

```bash
./scripts/qa.sh
```

该命令会执行：原生构建、Info.plist 校验、代码签名校验、架构检查、固定 SQLite 测试库、运行/待操作/待查看状态优先级、任务备注索引与未读状态自检、五个固定本地数据源的只读哈希比对、固定 Codex 用量协议自检、缺失程序/索引/状态/数据库边界测试和脱敏扫描。

CI 只使用仓库生成的固定测试数据和假 Codex 用量服务，不访问任何真实 Codex 任务或账号。

## 已知边界

- 仅支持 macOS；当前真实环境已在 Apple Silicon 上验证。
- 状态优先级固定为“待操作 → 运行中 → 待查看 → 普通时间”；运行中的任务即使产生未读输出也不会提前显示“待查看”。
- 绿色“待查看”准确含义是“当前顶层任务已经停止运行，并有新回复尚未查看”；它会随 Codex 的已读状态在刷新后消失，不表示对话永久完成或归档，也不会受内部子线程残留未读影响。
- Codex 如果更改本地数据库结构、未读状态格式、Bundle ID 或深链协议，需要更新模板。
- 仓库使用 ad-hoc 签名，没有 Apple Developer ID 公证；首次运行可能受本机 Gatekeeper 设置影响。

## License

[MIT](LICENSE)
