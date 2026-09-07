# OneStep for iOS（一步）· 越狱插件 · v0.2

把锤子科技「一步（OneStep）」的交互移植到 iPhone 的越狱插件。
参考上游开源实现 [SmartisanTech/packages_apps_OneStep](https://github.com/SmartisanTech/packages_apps_OneStep)
（Android 系统级应用）的**交互与信息架构**，针对 iOS 用 tweak 技术从零重写，
Java/Android 代码不可直接复用。

> ⚠️ 免责声明：本项目为个人学习用途的越狱插件，请在越狱设备上自行承担风险。
> 涉及大量 iOS 私有 API，**需要真机调试打磨**，发布前请逐项核对（见文末清单）。

> **v0.2 变更**：修复 v0.1 白苹果（启动循环）问题 + 新增面板内设置页。详见「版本记录」。

---

## 1. 这是什么

| OneStep（Android 原版） | 本插件（iOS 越狱版） |
|---|---|
| 系统级侧边悬浮窗，常驻屏幕右侧 | SpringBoard 内浮层窗口（windowLevel 位于状态栏之下） |
| 顶部托盘：最近图片 / 文件 / 剪贴板文字 | 展开面板的顶部托盘：**最近剪贴板文字** + **最近图片** |
| 侧边栏：常用 App / 联系人 / 分享目标 | 应用 3 列网格（固定 App 置顶）+ 快捷动作行（搜索 / 分享 / 邮件） |
| 拖拽内容到目标 App 图标 → 一步直达 | 长按托盘条目拖到 App 图标 → 写入剪贴板 → 拉起 App → **自动粘贴** |
| 拖到联系人 → 直达对话 | 快捷动作：Safari 搜索 / 系统分享面板 / 邮件（`mailto:` 预填） |

核心交互（对应 OneStep「拖一下，少走四步」）：

1. 屏幕右缘中部有一个半透明**把手条**：点一下或向左滑 → 面板展开。
2. 面板上部是**托盘**：
   - 「最近剪贴板」：最近复制过的文字，**点一下 = 复制回去**，**长按 = 拖出去**；
   - 「最近图片」：相册最近照片（需授权一次），**长按 = 拖出去**，点一下 = 复制图片。
3. 面板下部是**应用网格**（按固定 App → 名称排序）与**快捷动作行**。
4. 长按托盘条目拖到某个 App 上松手：
   - 内容被写入系统剪贴板并记录到**命名剪贴板**（含“你原来的剪贴板”快照）；
   - 目标 App 被拉起；
   - 目标 App 进程里的 **Paster 助手**检测到输入框已聚焦 → 自动粘贴；
   - 若尚未聚焦输入框 → 显示悬浮胶囊「点此粘贴」，等你点输入框键盘出现后**自动粘贴**；
   - 粘贴成功后**还原你原来的剪贴板内容**。
5. 面板标题行右侧 **⚙️** 进入**设置页**（总开关 / 粘贴后还原剪贴板 / 自动粘贴延时 / 历史上限）。

---

## 2. 工程结构

```
OneStep-iOS/
├── Makefile                     # Theos：rootless、双 dylib、ARC、iOS 15+
├── control                      # 包元数据（com.onestep.ios）
├── OneStepUI.plist              # 注入过滤：仅 SpringBoard
├── OneStepPaster.plist          # 注入过滤：常用 App 白名单（v0.2 起，非全局注入！）
├── layout/var/mobile/Library/Preferences/
│   └── com.onestep.ios.plist    # 默认偏好
├── .github/workflows/build.yml  # GitHub Actions 远程打包（无需 Mac）
└── src/
    ├── Shared/                  # 两个注入器共用
    │   ├── OSCommon.h           #   偏好键 / Darwin 通知名 / 命名剪贴板协议 / 历史文件路径
    │   └── OSPasteHistory.[hm]  #   剪贴板文本历史（命名剪贴板存储 + 文件镜像）
    ├── OneStepUI/               # 注入 SpringBoard（dylib 1）
    │   ├── OneStepUI.xm         #   启动入口（v0.2：延迟 2.5s、@try 保护，无剪贴板 hook）
    │   ├── OSRuntime.[hm]       #   私有 API 访问层（图标/拉起 App/相册）
    │   ├── OSModels.[hm]        #   数据模型 + 拖拽载荷
    │   ├── OSAppSource.[hm]     #   已安装应用枚举
    │   ├── OSPhotosSource.[hm]  #   相册授权与最近图片
    │   ├── OSPanelController.[hm] # 面板 UI（托盘 + 网格 + 动作行 + v0.2 设置页）
    │   ├── OSDragController.[hm]  # 拖拽状态机（跟手浮层/高亮/松手分发）
    │   ├── OSActionPlanner.[hm]   # 执行链（写剪贴板/载荷 → 拉起 → 广播）
    │   └── OSUIManager.[hm]       # 主控：窗口/生命周期/数据流/toast
    └── OneStepPaster/           # 注入白名单 App 进程（dylib 2）
        └── OneStepPaster.xm     #   自动粘贴引擎 + 兜底气泡 + 剪贴板上报
```

### 跨进程协议（重要）

由于 iOS 通知不能携带负载，SpringBoard 与各 App 之间这样协作：

```
[SpringBoard 侧]                                   [目标 App 进程]
拖放命中 App 图标
  │ ① 快照用户「原剪贴板」→ 稍后还原用
  │ ② 写入 general 剪贴板（粘贴要消费的内容）
  │ ③ payload = {目标bundleID, 内容, ts} → 序列化写入命名剪贴板 com.onestep.ios.payload
  │    原剪贴板内容作为该命名板的第二个 item 原样存放（不归档，兼容图片等类型）
  │ ④ 拉起目标 App
  │ ⑤ 广播 Darwin 通知 OSNotifyDragLaunched
  └────────────────────────────────────────────►  didBecomeActive / 通知到达
                                                    │ 校验 target==自身 & ts<15s & token 去重
                                                    ├─ 有输入框聚焦 → sendAction paste: → 成功
                                                    │    → 还原原剪贴板 → 清空载荷 → 广播 OSNotifyPasteFinished
                                                    └─ 无输入框 → 悬浮胶囊；键盘出现 → 自动粘贴

[白名单 App 进程] 拷贝文本 → hook UIPasteboard → 写历史 → 广播 OSNotifyClipboardChanged
                                                                    │
[SpringBoard 侧] 收通知 → 重读历史 → 托盘刷新 ◄──────────────────────┘
```

---

## 3. 构建

### 3.1 本地构建（需要 macOS 或 Linux + Theos）

```bash
export THEOS=~/theos
make clean
make package        # 产物在 packages/com.onestep.ios_*.deb
```

### 3.2 没有 Mac？用 GitHub Actions 远程打包

1. push 到 GitHub；2. Actions → **Build OneStep deb**；3. 下载 Artifact 的 deb。

> 本工程在无 iOS 设备环境下开发，编译问题由 CI 负责兜底，**功能需真机验证**。

---

## 4. 安装（Relaxin / RootHide 环境，iOS 17.0–17.3.1）

你的环境：**iOS 17.1.1 + Relaxin（roothide / rootless，ElleKit 注入，Sileo）**。

1. 先装依赖：**ElleKit**、**PreferenceLoader**（Sileo 添加源安装）。
2. **必须先用 RootHide Patcher 处理 deb**，再安装 —— Relaxin 的 roothide 环境与普通
   rootless 布局不同，**v0.1 直接 dpkg 安装是白苹果（启动循环）的主因之一**。
   Patcher 用法：打开 RootHide Patcher → 选 deb → 按提示重打包 → 用 Sileo 安装。
3. 安装后重启 SpringBoard。若异常，**自救**：强制重启（电源+音量下）→ 按住音量-
   进 **Safe Mode** → 在 Sileo 卸载 `com.onestep.ios`。
4. 屏幕右缘中部出现**把手条** = 生效。

### Paster 生效范围（白名单，v0.2 起）

为避免注入系统进程导致启动循环，`OneStepPaster.plist` 采用**白名单注入**，自动粘贴与
剪贴板历史上报仅在下列 App 内生效（也可自行增删后重新编译）：

备忘录、提醒事项、信息、邮件、Safari、微信、QQ、钉钉、Telegram、WhatsApp、设置。

> 想加其它 App：把它的 bundle id（如知乎 `com.zhihu.ios`）加进
> `OneStepPaster.plist` 的 `Bundles` 数组 → push → Actions 重新出包。
> 不在白名单的 App：拖放内容仍会“打开 + 复制到剪贴板”，只是不会自动粘贴。

---

## 5. 使用方法（速查）

| 操作 | 效果 |
|---|---|
| 点 / 左滑右缘把手条 | 展开 / 收起面板 |
| 点剪贴板历史某一行 | 复制回剪贴板 |
| 长按剪贴板行 → 拖到 App | 发送文本并自动粘贴（白名单 App） |
| 长按相册缩略图 → 拖到 App | 发送图片并自动粘贴（目标需支持粘贴图片） |
| 拖到「搜索」 | Safari 搜索该文本 |
| 拖到「分享」 | 系统分享面板 |
| 拖到「邮件」 | 新建邮件预填正文 |
| 点相册缩略图 | 复制该图片到剪贴板 |
| 面板标题行 ⚙️ | 打开**设置页** |
| 设置页 | 总开关（重启生效）/ 粘贴后还原剪贴板 / 自动粘贴延时 / 剪贴板历史上限 |

常用偏好键（设置页直接改；也可编辑
`/var/mobile/Library/Preferences/com.onestep.ios.plist`）：

| 键 | 默认 | 含义 |
|---|---|---|
| `Enabled` | `true` | 总开关（关闭后重启不再加载 UI） |
| `RestoreClipboardAfterPaste` | `true` | 粘贴后还原原剪贴板 |
| `AutoPasteDelay` | `0.45` | 自动粘贴延时（秒，0.1–2.0） |
| `MaxClipboardHistory` | `12` | 剪贴板历史上限（1–50） |
| `MaxRecentPhotos` | `9` | 托盘最近图片数（0–24） |
| `PinnedBundleIDs` | 备忘录/信息/邮件/Safari | 固定置顶 App |
| `SearchTemplate` | `https://www.bing.com/search?q=%@` | 搜索 URL 模板 |

---

## 6. 与 OneStep 的差距（诚实清单）

- **“拖到具体联系人直达对话”**：iOS 上从 SpringBoard 读通讯录触发 TCC 授权，v0.2 仍用
  「邮件 / 系统分享」替代（`OSContactsSource` 预留位）。
- **自动粘贴只覆盖白名单 App**（见第 4 节）：这是 v0.2 为稳定性做的取舍。
- **自动粘贴不是魔法**：只对「打开后有输入框可聚焦」的 App 全自动；图片粘贴依赖目标
  App 输入框支持富文本。微信/QQ 等仍需你先选好会话（iOS 无公开深链）。
- iOS 16+ 系统会在跨 App 粘贴时显示「粘贴自其他 App」横幅，属系统行为。

---

## 7. 版本记录

- **v0.2.0**：① 修白苹果——OneStepPaster 由全局注入改为**白名单**、移除 SpringBoard 内
  UIPasteboard 重复 hook、启动延迟 + @try 自保护；② 新增**面板内设置页**（无 PreferenceLoader
  依赖）；③ 文档补 Patcher 必须流程与白苹果自救。
- **v0.1.0**：首个可编译版本（全套交互 + CI 出包；真机出现白苹果，见上）。

---

## 8. 已知限制与待真机验证的私有 API（发布前清单）

| # | 位置 | 说明 |
|---|---|---|
| 1 | `OSRuntime.m` 拉起 App | SBSLaunchApplicationWithIdentifier / FBSSystemService 在 iOS 17 是否可用 |
| 2 | `OSRuntime.m` App 图标 | `_applicationIconImageForBundleIdentifier:format:scale:` 的 format 取值 |
| 3 | `OSUIManager.m` 浮层窗口 | SpringBoard scene 模式下窗口创建与层级 |
| 4 | `OSPanelController` 手势 | 右缘把手与系统手势冲突面 |
| 5 | `OSPhotosSource` 授权 | SpringBoard 进程请求相册权限的 TCC 体验 |
| 6 | `OneStepPaster` 白名单注入 | 各白名单 App 内自动粘贴成功率（备忘录/微信/QQ…） |
| 7 | `sendAction: paste:` | iOS 17 自动粘贴成功率 |
| 8 | `UIPasteboard` hook | 是否覆盖各 App 拷贝路径 |
| 9 | 命名剪贴板跨进程 | Relaxin/roothide 下 `pasteboardWithName:` 读写 |
| 10 | v0.2 设置页 | UISwitch/UISlider 在 SB 浮层内的交互与偏好写入 |

排查：`log stream --predicate 'eventMessage CONTAINS "OneStep"'`。

---

## 9. 未来工作

- [ ] 联系人侧栏（先解决 TCC 授权）
- [ ] 大爆炸（Big Bang）分词移植
- [ ] 设置页外置为系统「设置」入口（PreferenceLoader bundle）
- [ ] 长按 App 图标固定 / 移除
- [ ] Paster 白名单改为可运行时配置

---

## 10. License / 致谢

- 交互与信息架构参考：SmartisanTech 开源 OneStep
  （Apache-2.0，见 [仓库](https://github.com/SmartisanTech/packages_apps_OneStep)）。
- 本仓库代码为独立实现，供学习交流。
