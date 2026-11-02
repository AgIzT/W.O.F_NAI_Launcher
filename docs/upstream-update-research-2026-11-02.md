# 上游更新差异与分批吸收方案 · 2026-11-02

## 结论

当前分支与直接上游从 2026-10-23 的共同祖先分开。上游多出 144 个提交，我们有 11 个独立提交；上游并非只改版本号，包含编辑器、图库、Agent、资源小窗、存储和更新器等多轮变化。合并树预演得到 44 个冲突路径。

建议按缺陷和功能分批独立实现，不整包 merge、不按提交顺序 cherry-pick。仓库 `AGENTS.md` 也明确要求先观察差异、再实现所需功能。继续保留现有 Plana 式原文编辑、译名显示、中英文/角色补全与 Wiki 预览；不恢复自动切块、TranslationPill 或旧翻译块迁移层。

本次完成提交推送、上游抓取和源码调研，尚未将上游功能应用到工作分支。以下优先级是后续实施建议。

## 已保存与对比基线

| 项目 | 核实结果 |
|---|---|
| 自己的 fork | `AgIzT/W.O.F_NAI_Launcher`，`origin/main` |
| 已推送代码 | [`62f92082`](https://github.com/AgIzT/W.O.F_NAI_Launcher/commit/62f920820bdcbdd6dc5bf2b00f7bd88d1f7d7be8)，自动译名停顿、批处理与重试策略优化；此前 10 个本地提交一并推送 |
| 直接上游 | `z15087716457-stack/W.O.F_NAI_Launcher` |
| 原始项目 | `Aaalice233/Aaalice_NAI_Launcher`；本次差异以直接上游为准 |
| 共同祖先 | `19330c13ad02bbc317b5947d383405955da6333c`，2026-10-23 19:25:59 +08:00 |
| 上游 main | [`49e8ed31`](https://github.com/z15087716457-stack/W.O.F_NAI_Launcher/commit/49e8ed3100fbfa5896fb8467a8b9f72dae522956)，2026-11-01 |
| 本分支 / 上游版本 | `2.1.1+44` / `2.2.4+75` |
| 最新正式发布 | [`v2.2.4`](https://github.com/z15087716457-stack/W.O.F_NAI_Launcher/releases/tag/v2.2.4)，标签实际代码 `af372dc9` |

注意：精准参考附件修复 `8fe376da` 位于 `v2.2.4` 之后，属于 main 的 Unreleased，不包含在该正式分发包内。版本号相同不能说明代码完全相同。

全部统计固定以代码提交 `62f92082` 对比 `49e8ed31`，不包含本调研文档后续提交。

| 统计 | 数量与口径 |
|---|---|
| 本分支独有提交 | 11 |
| 上游独有提交 | 144，其中 127 个非合并提交、17 个合并提交 |
| 上游相对共同祖先 | 869 个路径，84,938 行新增、8,657 行删除 |
| 上游业务 / 测试路径 | `lib/` 361 个，`test/` 369 个 |
| 本分支改过的路径 | 175 |
| 双方都改过的路径 | 68 |
| 合并预演冲突路径 | 44 |

行数包含文档、生成文件、测试及 64 张 `test/.../failures` 诊断 PNG，不能据此认为缺失 144 项功能。补全和元数据有双方独立实现，也不能全部算作缺失。

抓取使用远端 URL 写入 `refs/remotes/upstream/main`，未改现有 `origin` 配置。`git merge-tree --write-tree --name-only HEAD upstream/main` 只计算合并树并写入 Git 对象，未修改索引/工作文件，也未进入真实合并状态。没有调用 `git pull`。

## 应保留的分支设计

- 原提示词维持纯文本，译名属于显示层，不进入生成参数或撤销记录。
- 现有 `PromptCompletionWrapper`、紧凑候选条、角色/作品分类、别名和 Wiki 预览继续作为唯一补全入口。
- 自动翻译沿用当前共享队列：词库/缓存立即读取，输入停顿 800ms 后请求；输入法组词中抑制请求，发出前剔除过期片段；每批最多 8 项/2,400 字符，串行处理，批间至少 300ms；保留现有退避、取消和路由切换保护。
- 上游普通手动块/临时块的可取改进可以单独评估，但不以恢复旧翻译块为前置条件，不为旧 TranslationPill 数据新增兼容债务。
- 保留 `6440d0fa` 对桥接/Agent 角色提示词的修复，包括原始图片进入本地放大前补写的角色元数据。

## 优先吸收的缺陷

### A. 精准参考附件与错误原因：优先级 P0，范围小到中

上游 [`8fe376da`](https://github.com/z15087716457-stack/W.O.F_NAI_Launcher/commit/8fe376da) 修正图生图/局部重绘切换到 multipart 后，精准参考仍在 `director_reference_images` 中传 Base64 的问题。服务端将其当作附件名查找，会产生 HTTP 400。

已核对当前 `lib/data/datasources/remote/nai_image_generation_api_service.dart`：`_requestBody` 只上传底图和蒙版，缺少精准参考附件处理；流式与非流式均调用该入口。当前源码仍具有相同缺口。本次未调用真实生成接口复现。

实施时在同一构造入口上传每张参考图，并将 JSON 数组改成对应附件名，保持顺序、参考类型、强度和保真度。同步将 API 状态和原因接入现行错误卡片；卡片截断超长原因及 Base64 回显，复制详情保留完整错误。不要用当前草稿替换请求快照。

验收：图生图/局部重绘 × 流式/非流式四条路径；多个参考图的像素、顺序和参数；纯文生图 JSON 路径保持；错误卡片和复制详情分别验证。使用合成图和替身网络，不消耗真实 Anlas。

### B. Windows 更新器：优先级 P0，范围中

上游 [`f9b813e3`](https://github.com/z15087716457-stack/W.O.F_NAI_Launcher/commit/f9b813e3)、[`10e3f7f5`](https://github.com/z15087716457-stack/W.O.F_NAI_Launcher/commit/10e3f7f5) 及 [`af372dc9`](https://github.com/z15087716457-stack/W.O.F_NAI_Launcher/commit/af372dc9) 包含几处独立问题的修复：

- Release 清单按文本解析 JSON，兼容 `application/octet-stream`；回退解析资产时保留 GitHub 提供的 SHA-256。
- 更新辅助进程从应用目录之外启动，避免自身工作目录占用旧程序目录；避免 Dart detached 启动 PowerShell 后脚本未执行的路径；脚本写 UTF-8 BOM 兼容中文路径。
- Portable 清单统一 `/` 与 `\`。否则旧受管文件被误当作用户文件复制回来，可能用旧 AOT/Agent 覆盖新包。
- 已有备份不自动清除，目录切换失败时按实际移动状态回退，保留失败备份。

已对照当前更新器和上游源码差异，当前分支尚未包含这些修复。应作为一个更新链路批次处理，不能只修下载或路径比较后就宣称升级完整可用。

验收：清单 MIME/缺失/损坏、资产摘要、续传取消；中文和特殊路径；发起父进程退出后的脚本续行；斜线/反斜线/混合清单；旧文件退役、自定义文件与 `user-data` 保留；失败后恢复旧程序。只操作隔离夹具目录。

更新器修复由旧程序执行时才生效：从旧 Portable 第一次升级到修复版本，不能指望新包修复旧进程已经生成的脚本，需要单独交付明确的升级路径。

另一个发布风险：当前 `UpdateCheckService.defaultOwner` 仍为 `z15087716457-stack`，与仓库约定一致。推送到 fork 不等于应用会更新到 fork，也不等于已创建 Release。以后发布自己的定制包，需要明确更新源策略，避免用上游原包覆盖本分支编辑器；本次没有改变更新源或发布新包。

### C. 图库首次 Ctrl 多选：优先级 P0，范围小

上游 [`2d145321`](https://github.com/z15087716457-stack/W.O.F_NAI_Launcher/commit/2d145321) 移除首次进入 Ctrl 多选时主动补选预览图的逻辑。已核对当前 `GalleryTimelineView._handleTap` 仍有这段代码：预览 A 再 Ctrl 点击 B，会把 A 一起加入真实批量操作集合，影响删除、移动和复制。

独立修正这一个交互分支，保留 Shift 范围、多选累加/取消、选择圈和 Esc。验收覆盖三种布局，并断言批量删除候选仅含明确选中的图片，不执行实际删除。

## 需要适配的更新

| 项目 | 建议 | 原因与验收重点 |
|---|---|---|
| 选区/光标可见性 | P1，单独适配 | [`3c9debe7`](https://github.com/z15087716457-stack/W.O.F_NAI_Launcher/commit/3c9debe7)、[`4d928fbb`](https://github.com/z15087716457-stack/W.O.F_NAI_Launcher/commit/4d928fbb) 处理语法底色遮住原生选区/光标。当前控制器未包含修复，但多了译名字距、字号与 reading revision 缓存。应在现有缓存外应用选区显示副本，保留译名几何；不能整文件替换。验证深浅主题、反向/跨行/Unicode 选区、长译名、缩放、光标定位和输入法。 |
| 撤销/重做和文本工具 | P1，拆出普通编辑能力 | [`dd2bb3fe`](https://github.com/z15087716457-stack/W.O.F_NAI_Launcher/commit/dd2bb3fe) 涉及分栏文档历史、Ctrl+Y、失焦撤销，另有提示词工具布局/字号改进。上游同时修改旧翻译块，需仅适配现行编辑路径。验收主/负面/角色独立历史，焦点切换、补全替换和译名回写不污染撤销栈。 |
| 图片元数据 | P1，补缺而非重做 | 上游 [`49d316f5`](https://github.com/z15087716457-stack/W.O.F_NAI_Launcher/commit/49d316f5) 与本地 `6440d0fa` 部分重复；上游扩大了统一解析、非 PNG 来源及 `params`/`Comment` 容器的保护。可吸收这些增量，但必须保住本地进入放大前的角色元数据写入，不能覆盖整个 provider 或保存工具。验证未知字段、原始容器、外部结果自身元数据优先和角色完整性。 |
| 标签共现排序 | P1，复用当前补全体系 | [`1e0f078e`](https://github.com/z15087716457-stack/W.O.F_NAI_Launcher/commit/1e0f078e)、[`7f999488`](https://github.com/z15087716457-stack/W.O.F_NAI_Launcher/commit/7f999488) 将完整邻接评分、多种子归因、分类/排除和词频加权 Jaccard 统一给编辑器与 Agent。可保留数据层改进；当前目录查询新增了角色/作品过滤和别名批读，两者都须保留。大邻接集合的读取成本仍要测量。 |
| RAG 重复核对/慢读 | P1，作为 Python 引擎完整批次 | [`a6c97e5d`](https://github.com/z15087716457-stack/W.O.F_NAI_Launcher/commit/a6c97e5d)、[`058b46fe`](https://github.com/z15087716457-stack/W.O.F_NAI_Launcher/commit/058b46fe) 最终用 SQLite 可见快照摘要稳定来源身份，物理签名仅作缓存键；完成记录使用本次已验证状态，同时批读 Wiki/别名/语义并利用原名称索引。不能只移植中间“忽略空 WAL”的修复。验收 WAL 提交/checkpoint/连接关闭/重启、真实资料变化、构建尾部变化及旧向量复用。 |
| 图库日常功能 | P1/P2，按功能切分 | 最近浏览、删除池整合、完整短语/标签搜索、搜索历史、复制图片和缩略图上限等可独立挑选。涉及物理删除与记录迁移的部分先做隔离回归，保留图片 ID、收藏、标签和现有时间线位置。 |

上游也新增了自己的中文查询与相关标签侧栏。我们已经有中英文补全、角色/作品筛选、Wiki 摘要和别名预览，不能把上游整套补全控制器叠加接线，否则会形成两套键盘事件、请求生命周期及状态来源。相关标签入口若需要，接入现有 `PromptCompletionController` 即可。

## 应单独规划的大批次

### D. 相邻数据目录与插件存储：P1 独立批次，风险高

上游 [`数据目录报告`](https://github.com/z15087716457-stack/W.O.F_NAI_Launcher/blob/49e8ed31/docs/app-data-location-review-2026-10-31.md) 的问题与我们此前独立构建启动时遇到的旧 AppData 联接归属冲突相符，值得优先安排，但不混在小修复提交中。

其实现让偏好和加密凭据直接使用当前 EXE 旁的 `user-data`，当前资料优先，不因其他安装的旧联接拒绝启动；schema 1 的旧插件文件只补缺一次并保留备份。真正首次完整迁移仍执行备份、哈希校验和源变化检查。完整旧资料迁移所需的绝对路径兼容也仍保留，并不是简单删除所有联接代码。

必须作为整体评估 `application_storage.dart`、`app_support_directory.dart`、`adjacent_app_data_migration.dart`、沙箱/启动顺序及平台依赖。还需核实文件偏好写入在多个进程/资源小窗下的所有权和中断恢复；上游单进程写队列不能直接证明跨进程安全。

验收：全新目录、已有当前数据、其他/断开的旧联接、两端不同资料、迁移源变化中断、一轮补缺与重复启动、中文路径；真实 Windows 加密插件使用合成凭据验证读取/写入/删除及目录隔离。实施阶段先备份并核对实际安装路径，不能拿正式用户数据试迁移。

### E. Agent 与 `.W.O.F/` 工作区：P2，范围大

上游增加流式思考合批、焦点/阅读位置保留、压缩后的历史回查、命令/技能/模板补全、多图拖入、MCP 配置和状态，以及 Agent 自管理与工作区收纳。

可先独立吸收界面/流式状态修复；`agent_manage`、Node 工具/技能/扩展/包、权限与 `.W.O.F/` 工作区迁移应统一设计。不能只改 Dart 目录名遗漏 Node 会话历史和附件路径，也不能覆盖本分支已经删除旧翻译块后的 Agent 块工具绑定。

验收跨 Dart/Node：历史与附件迁移备份、会话恢复、取消/失败、权限规则、多图、流式阅读位置。缓存保温可能产生模型请求和费用，需与现有设置及用户意图一致，不能随更新悄悄打开。

### F. 四类独立资源小窗：P2，范围大

图库、块、Vibe、精准参考小窗是成套功能，包含 `desktop_multi_window 0.3.1`、Windows runner、窗口几何/拖放/IPC、插件初始化、独立入口及共享图库服务，不能只复制 UI 文件。

它不是本次翻译目标的前置依赖。若后续采纳，再以完整模块实施，验证主/子窗口生命周期、关闭恢复、跨窗口资源选择、权限与独立查询状态，并重新构建 Windows runner。

## 推荐执行顺序与完成标准

1. **先修有限范围缺陷**：精准参考 multipart/错误展示、图库 Ctrl 多选、更新器分成三个提交。先用隔离测试确认当前失败路径，再实现并验证。除错误接线外尽量不碰提示词编辑器。
2. **编辑器与数据质量**：选区/光标、撤销、元数据分别适配；每项都保住当前译名、补全、角色和生成参数语义。相关改动通过后再跑仓库规定的生图接线核心回归及提示词扩展范围。
3. **标签/RAG 与存储**：共现和 RAG 分别提交；数据目录作为另一个完整批次，迁移测试和 Windows 平台验证通过后才考虑安装交付。无需为更新主动重建用户向量库。
4. **按需要扩展功能**：Agent 界面改进、工作区/自管理、资源小窗分别立项，普通块的改进与旧翻译块分离。

每批完成后记录上游来源、实际采用范围、拒绝项、测试和已知限制。采用行为相同的修复不要求整份文件与上游一致。暂不直接把版本号改成 2.2.4，以免暗示已经包含上游全部功能或正式发布。

依赖变化按实际模块添加：存储平台接口、小窗插件各自处理；锁文件由登记 SDK 解析生成，不能覆盖整个上游 `pubspec.lock`。多语言从 ARB 源合并，再按本仓库流程生成繁体与本地化代码，不能用生成文件冲突的机械选择代替翻译源合并。SDK 最低约束未变化，沿用登记 Flutter 3.47.7 / Dart 3.13.5 验证。

## 本次验证与仍待核验的边界

- 已核实远端 main SHA、正式标签实际代码、共同祖先、提交数量、变更路径、重叠路径和合并预演冲突。
- 已直接阅读关键服务/控制器差异，以及上游的请求、更新、数据迁移、图库、RAG 和发布报告；报告中的上游测试数字属于上游记录，没有当作本分支已经通过的验证。
- 本次没有应用上游代码，没有运行合并版本测试或构建，没有改用户数据、安装包、更新源或当前运行实例。
- 原有未提交文件 `test/presentation/widgets/common/thumbnail_display_test.dart` 保持原样；SHA-256 为 `07EA3A451519922BCDFF76D214886AEA7537A4CF79B249478A1BA3531A2D0DBC`，未混入代码提交。
- 本地忽略目录 `build/upstream-review-20261102/` 保存了指标、144 条提交、变更路径、68 条重叠路径、原始 merge-tree 输出和 44 条冲突列表。该目录不是随仓库发布的产物。

## 附：44 个冲突路径

其中多个是上游修改、本分支已删除的旧翻译实现。不得通过恢复这些文件来消除冲突；其余自动合并成功的文件也仍需检查业务语义。

```text
CHANGELOG.md
lib/core/tag_expansion/local_tag_expansion_service.dart
lib/core/tag_expansion/tag_expansion_providers.dart
lib/core/utils/image_save_utils.dart
lib/core/utils/pill_document_editor.dart
lib/data/models/prompt_block/pill_document.dart
lib/l10n/app_en.arb
lib/l10n/app_ja.arb
lib/l10n/app_ko.arb
lib/l10n/app_localizations.dart
lib/l10n/app_localizations_en.dart
lib/l10n/app_localizations_ja.dart
lib/l10n/app_localizations_ko.dart
lib/l10n/app_localizations_zh.dart
lib/l10n/app_zh.arb
lib/l10n/app_zh_TW.arb
lib/presentation/prompt_assistant/services/prompt_assistant_service.dart
lib/presentation/providers/image_generation_provider.dart
lib/presentation/providers/nai_agent/nai_agent_snapshot_binding.dart
lib/presentation/providers/pill_workspace_provider.dart
lib/presentation/providers/prompt_translation_provider.dart
lib/presentation/ui/gen/gen_contract.dart
lib/presentation/ui/gen/gen_prompt.dart
lib/presentation/ui/kit/ui_block_pill.dart
lib/presentation/widgets/prompt/nai_syntax_controller.dart
lib/presentation/widgets/prompt/pills/prompt_pill_editor.dart
lib/presentation/widgets/prompt/pills/translation_editing_controller.dart
lib/presentation/widgets/prompt/pills/translation_pill_editor.dart
lib/presentation/widgets/prompt/pills/translation_pill_view.dart
lib/presentation/widgets/prompt/unified/unified_prompt_input.dart
lib/presentation/wiring/generation_data_wiring.dart
lib/presentation/wiring/generation_editor_wiring.dart
lib/presentation/wiring/generation_wiring.dart
pubspec.lock
test/presentation/prompt_assistant/provider_connection_health_test.dart
test/presentation/providers/image_generation_provider_test.dart
test/presentation/providers/prompt_translation_provider_test.dart
test/presentation/ui/blocks/blocks_golden_test.dart
test/presentation/ui/channel/channel_test.dart
test/presentation/widgets/prompt/blocks/prompt_block_pill_palette_test.dart
test/presentation/widgets/prompt/pills/prompt_pill_editor_test.dart
test/presentation/widgets/prompt/pills/translation_pill_editor_test.dart
test/presentation/wiring/generation_editor_wiring_test.dart
test/presentation/wiring/image_viewer_wiring_test.dart
```
