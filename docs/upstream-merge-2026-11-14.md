# Plana 2.3.4 上游合并与发布核验

日期：2026-11-14（Asia/Shanghai）。在 `migration/plana` 上，从定制提交 `7e0a0f6f00eaebc65a73c2a01181f6f243c17834` 合入上游 `5cb759b3d5349de6305847f93e9b361c78ed1950`，更新前落后 2 个上游提交：

- `f6ff6c00`：准备 W.O.F NAI Studio 2.3.4。
- `5cb759b3`：上游 Windows 与 Mac 通用包发布核验记录。

定制版版本为 `2.3.4+103`，保留双方 Git 历史。上游自带的 `docs/release-2.3.4-2026-11-13.md` 仅描述上游产物，本定制版的验证以本文为准。

## 合并交点

- 纳入积木多图预览与独立裁切、外部 Agent 会话和画布通知、Agent 图片历史压缩、缓存保温、空回处理、精准参考弹窗、普通增强尺寸对齐及在线大图顶栏拖窗。
- 解决 8 个文件的合并冲突。积木存储、保存与复制沿用新的多图语义，同时保持本分支已退役的翻译块字段和引导移除；图像回归保留双方已有的局部变化区域。
- 保留中英文标签／角色／作品补全、Wiki 与别名预览、只读标签和自然语言译名、共享翻译队列，以及设置中的自动模型翻译开关。
- 保留 `AgIzT/W.O.F_NAI_Launcher` 应用内更新源、原项目归属，以及生成前嵌入角色字幕的本地放大修复。没有恢复自动切块或 TranslationPill。
- 同步中英文 README 和本次 CHANGELOG，下载链接指向本仓库。

## 发布前验证

使用登记的 Flutter 3.47.7 / Dart 3.13.5，通过 ASCII 工作路径执行：

| 检查 | 结果 |
| --- | --- |
| 代码生成与本地化生成 | 通过 |
| `flutter analyze --no-pub lib` | 0 问题 |
| 受影响及定制 Flutter 回归 | 61 个套件，921 项通过，0 跳过，0 失败 |
| 台湾正体资源 | 4 项通过 |
| Agent Node 回归 | 160 项通过，0 跳过，0 失败 |
| Windows 发布载荷单元检查 | 3 项通过 |
| 4 个内置数据库来源与清单 | 通过 |
| Git LFS 完整性 | 通过 |

Flutter 范围包括上游新增／修改测试，以及补全、只读译名、自动翻译开关、角色字幕、更新服务和生图接线的交点回归；没有重复运行整仓测试。原始日志与套件清单保存在忽略目录 `build/upstream-sync-2.3.4/`。测试使用隔离数据及生成替身，没有调用真实模型／NAI 生图，也没有安装或启动用户程序。

## 发布状态

`v2.3.4` 固定源码 `9882017c7d1744d9ee909914614c7d760ccedb70`，通过本仓库双平台工作流发布，未重写任何既有发布标签：

- [正式发布页](https://github.com/AgIzT/W.O.F_NAI_Launcher/releases/tag/v2.3.4)
- [成功的 Windows、Mac 与发布工作流](https://github.com/AgIzT/W.O.F_NAI_Launcher/actions/runs/43559418355)
- [更新清单](https://github.com/AgIzT/W.O.F_NAI_Launcher/releases/download/v2.3.4/release_manifest.json)
- [公开 SHA-256](https://github.com/AgIzT/W.O.F_NAI_Launcher/releases/download/v2.3.4/checksums.txt)

Release 为最新稳定版，9 个附件齐全。更新清单版本为 `2.3.4+103`，三类资产的大小、SHA-256 与 GitHub 摘要相符，下载地址均指向本仓库；公开正文与附带更新说明一致，包含本次上游更新及 Plana 定制保留说明。

| 文件 | 字节数 | SHA-256 |
| --- | ---: | --- |
| `WOF_NAI_Studio_Windows_2.3.4_Setup.exe` | 200,707,916 | `eb6113938c281adf3ee1397189b00514408f64f29e827bd86ae381ff0a59f485` |
| `WOF_NAI_Studio_Windows_2.3.4_Portable.zip` | 323,784,033 | `5b4c660e377fffb0d1e7dbd03940a5115646e0008b4aa24a3f224282e84a5a73` |
| `WOF_NAI_Studio_macOS_2.3.4_Portable.zip` | 409,765,766 | `135bb58c30e5024dd7ada9e6ad3f346ec2474ae3246e552d5feb1f235cf118d5` |

三份成品从本次成功构建下载，实际文件大小与 SHA-256 均和正式发布资产、更新清单、公开总校验及单独校验文件一致。

Windows 便携包 15,558 个文件，15,556 个文件的内部清单及 15,557 条内部 SHA-256 全部通过。46 个 Agent 生产源文件按换行规范与发布源码一致，包含四个新增模块；版本、源码提交、AOT、Node 24.18.0、Pi 1.5.0 及 4 个数据库哈希、SQLite `quick_check` 通过。主程序存储身份为 `com.example/nai_launcher`，显示名为 W.O.F NAI Studio。Setup 成品的实际哈希与公开校验一致，没有运行安装器或启动、替换用户程序。

Mac 包包含 17,643 个文件，46 个 Agent 生产源文件按换行规范核对一致；版本、源码提交、AOT、Node 24.18.0、Pi 1.5.0 及 4 个数据库哈希通过。检查了 41 个 Mach-O 文件，共用文件包含 arm64／x86_64，架构专用 npm 模块按目标提供。最低 macOS 13.5，仍为临时签名，未做 Mac 实机启动验收。

发布后再次拉取上游，目标仍为 `5cb759b3`，落后 0 个提交。核验记录作为普通后续文档提交补入 `migration/plana`，发布标签保持不变；完整本地证据在忽略目录 `build/upstream-sync-2.3.4/`。
