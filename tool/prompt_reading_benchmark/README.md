# 提示词阅读性能探针

`main.dart` 是独立 Flutter 入口：测量生产 `TagCatalogRepository`、中文检索及 canonical/alias 解析、50 个可见词条的批量读取，以及 `PromptReadingLayer` + `PromptCompletionWrapper` + `ThemedInput` 的引擎帧耗时。

仅在独立 ASCII 构建副本运行，不替换安装包。该副本的 runner 应使用独立 mutex/唤醒消息和窗口名，并去掉 `RegisterPlugins(...)`；探针不需要原生应用服务。保持原仓库的 Windows runner 不变。探针与正式程序不要共用原生对象缓存：若复用构建副本，恢复正式 runner 后必须强制重编（复制回旧修改时间的源码不会触发 MSBuild），并核验 EXE 插件注册导入与实际窗口标题。使用登记的 Flutter SDK：

```text
flutter build windows --release --no-pub --no-tree-shake-icons --target tool/prompt_reading_benchmark/main.dart
build/windows/x64/runner/Release/nai_launcher.exe <输出JSON绝对路径> <仓库绝对路径>
```

程序完成后自行退出。词库以只读方式打开，UI 使用合成标签和内存译名，不启动账户、用户数据迁移、网络模型或生图。输入场景持续 5 秒；长文滚动场景含 600 行。JSON 保留每帧 build/raster/total 微秒值，便于独立计算分位数。

首查只代表本进程首次查询，不清空系统文件缓存。批量读取耗时和词库查询耗时不是帧耗时；引擎 `FrameTiming` 也不等于屏幕实际呈现 FPS。该探针验证输入组件，不代表整个工作区与生图同时运行的性能。
