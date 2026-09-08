# OneStep Split（分屏）· v0.3 · iOS 越狱插件

在 iPhone 上实现「iPad 式分屏多任务」的越狱插件（rootless，仅注入 SpringBoard）。

> 开发状态：**P0 最小闭环** —— 全屏主 App + **1 个 scene-host 实时小浮窗**，点小窗切换主副。
> 交互细节（角上滑手势、双浮窗、缩放、设置面板）在真机验证 P0 后迭代（见 Roadmap）。

---

## 快速上手（30 秒学会）

安装并重启 SpringBoard 后，**无需任何设置**，操作只有 4 步：

1. **打开一个 App**（比如微信），全屏运行——这就是「主界面」。
2. 屏幕**右上角**有一个半透明「**▣**」小圆钮：点它，弹出 App 选择列表。
3. 列表里**点选第二个 App**（比如相册）→ 它立刻全屏打开；刚才的微信
   **自动缩成屏幕右下角的小浮窗**，且画面是**实时的**（视频会继续播）。
4. **点一下小浮窗** → 微信全屏回来、相册缩成小窗（主副互换）。
   - 拖动小浮窗可换位置；
   - 右上角「✕」结束分屏（回到单 App）；
   - 想再加第三个 App，直接再点「▣」另选即可（当前版本同时只保留一个小窗）。

> 出问题？看日志：`log stream --predicate 'eventMessage CONTAINS "OneStep"'`

## 它是怎么实现的（大白话）

iPhone 系统只允许「一个前台 App 真正在跑」，iPad 才有多窗口。插件用越狱手段绕开：

- **看穿系统**：`FBScene` 是 iOS 里每个 App 画面的"遥控器"。插件住在 SpringBoard
  进程里，通过遍历系统的场景管理器（`FBSceneManager` / `SBMainWorkspace` 的
  `_scenesByID` 等内部字典）找到另一个 App 的 scene。
- **把小窗画面"搬"过来**：用 `_UISceneLayerHostContainerView` 把那个 App 的
  scene 图层直接挂到我们画的小窗上 → 你看到的是它**真实画面**，不是截图。
- **骗系统别把它挂起**：App 一退后台 iOS 就会冻结它。插件每秒对它的 scene 发一次
  "保持前台"信号（`setForeground:YES`），相当于给它续命 → 视频不停、界面不冻结。
- **切主副** = 换一个 App 享受"前台 + 全屏"，另一个转去小窗续命，如此交替。

代码都在 `src/OneStepUI/`：`OSSceneKit`（找 scene/保活/挂画面）、`OSSplitManager`
（按钮、列表、切换逻辑）、`OneStepUI.xm`（入口）。每个环节都有 `[OneStep]` 日志，
真机一跑就能看到哪一步成功/失败。

> ⚠️ 当前触发是**固定的右上角胶囊**，也没有设置面板——这是 P0 简化（先把内核跑通）。
> 手势自定义、双浮窗、缩放、设置面板在 Roadmap 的 P1/P2；在那之前想改行为，
> 可直接编辑 `/var/mobile/Library/Preferences/com.onestep.ios.plist`。

## 功能（P0）
1. 屏幕右上角出现「▣」分屏胶囊。
2. 点胶囊 → 弹出 App 选择列表（排除当前主/副与系统 App）。
3. 选中某 App → 它以**全屏**启动；原前台 App 退为**右下角小浮窗**，
   小窗内容由 `_UISceneLayerHostContainerView` 实时呈现（非截图）。
4. **点小窗** → 主副互换（小窗 App 全屏、原主 App 缩成小窗）。
5. 小窗可拖动；点「✕」结束分屏。
6. 原主 App 在退后台期间由每秒 foreground keep-alive 防止挂起（“视频不停”的基础）。

## 架构

```
OneStep-iOS/
├── Makefile / control / OneStepUI.plist   # rootless 单 dylib，filter 仅 SpringBoard
├── .github/workflows/build.yml            # CI 出包（Randomblock1/theos-action）
├── layout/.../com.onestep.ios.plist       # 默认偏好
└── src/OneStepUI/
    ├── OneStepUI.xm            # 入口：延迟启动 + @try 保护（防白苹果）
    ├── OSCommon.h              # 常量 / 偏好 / 日志 / 小窗几何
    ├── OSModels.h              # OSAppItem
    ├── OSRuntime.[hm]          # 私有 API 访问层（图标 / 拉起 App）
    ├── OSAppSource.[hm]        # 已装应用枚举
    ├── OSSceneKit.[hm]         # ★ Scene 内核：FBScene 查找 / layer-host /
    │                           #   foreground 控制 / 每秒保活 / 前台识别
    └── OSSplitManager.[hm]     # ★ 编排与 UI：胶囊 / 选择器 / 挂载小窗 / 切换
```

### Scene 内核要点（参考社区通用机制，独立实现）
- **scene 查找**：`SBMainWorkspace.sceneManager` / `FBSceneManager` 的
  `_scenesByID` 等 ivar 字典多策略遍历（运行时 ivar 读取，nil 安全）。
- **实时画面**：`_UISceneLayerHostContainerView initWithScene:` → 作为浮窗内容。
- **多前台**：`scene.settings.mutableCopy → setForeground:YES →
  updateSettings:withTransitionContext:`。
- **保活**：每秒定时置 foreground（防系统挂起后台 App）。

## 构建 / 安装
- 构建：`make clean && make package`（Theos rootless），或 push 到 GitHub 走
  Actions → `onestep-deb` artifact。
- 安装（Relaxin/roothide）：**先过 RootHide Patcher**，再 Sileo 安装；重启 SpringBoard。
- 若异常：强制重启 → 按住音量- 进 Safe Mode → 卸载 `com.onestep.ios`。

## 真机验证点（每次出包后按此检查）
1. 装后不白苹果；右上角出现「▣」。
2. 在 A App 内点「▣」选 B：B 全屏、A 变右下小窗 —— **小窗画面是否实时**？
3. 小窗内播放视频是否继续？（验证 keep-alive / foreground 有效）
4. 点小窗是否切回 A 全屏、B 变小窗？来回切换是否稳定？
5. 拖动小窗、关闭分屏是否正常？
6. 日志：`log stream --predicate 'eventMessage CONTAINS "OneStep"'`
   （关注 `[SceneKit]` 是否报"未找到 scene"、"无 scene 画面"）。

## Roadmap
- P0：全屏主 + 1 实时浮窗 + 点切（当前）
- P1：角上滑手势触发、第二浮窗（主 + 2 浮窗）、小窗缩放
- P2：设置页（手势/浮窗数量/贴边）、稳定性打磨

## License / 致谢
- 交互目标参考用户侧 o2Pro（闭源）的功能形态；
- Scene 集成机制参考开源社区通用方案（MilkyWay 系列概念）；
  本仓库代码独立编写，仅供学习交流。
