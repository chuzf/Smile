# 微笑储蓄罐 · 设计书

- **日期**: 2026-05-23
- **平台**: iOS 17+
- **工具链**: Xcode 26.4 · Swift 6 · XcodeGen 2.45 · SwiftData
- **状态**: Draft for review

## 一、产品定位

一款**本地优先、不打扰**的 iOS 记录工具,用于归档生活中的微笑瞬间和温馨事件。核心隐喻是"储蓄罐":你存入正向时刻,在心情低落或需要被提醒"自己其实拥有很多"的时候打开它。

与系统备忘录的区别:

- **结构化**: 内置"微笑储蓄罐"和"优势储蓄罐"两个分组,贴合积极心理学常用框架
- **混合记录**: 一条记录可同时包含文本、照片、视频、语音
- **温暖治愈风**: 视觉设计是暖橙米色 + 手绘玻璃罐,日记本气质,而非工具气质
- **罐子充实感**: Lottie 罐子动画随记录数量"装满",轻量象征化,不做打卡/连续天数/统计图

## 二、核心决策一览

| 维度 | 决策 |
|---|---|
| 回顾体验 | 时间线浏览 + 罐内"随机看一颗"按钮(无物理摇晃手势) |
| 提醒通知 | **不做** |
| 数据存储 | **纯本地**(SwiftData + 文件系统),不接 iCloud |
| 隐私锁 | **不做**(依赖系统锁屏) |
| 自动标题 | 选配 AI(Claude Haiku 4.5)+ 本地兜底链 |
| 统计可视化 | 只有罐子充实动画,无数字仪表盘 |
| 分享 | 单条生成图片卡片 |
| 备份 | 全库 zip 导出(MVP 不做导入) |
| 检索 | 全文搜索 + 标签 + 时间筛选 三者并存 |
| 视觉风格 | 温暖治愈风(暖橙米色,手绘玻璃罐,圆润字体) |
| 工程生成 | XcodeGen,`project.yml` 单一可信源 |

## 三、技术栈与项目结构

### 3.1 选型

| 层 | 选型 | 理由 |
|---|---|---|
| UI | SwiftUI | 动画、列表、Sheet 都更短代码,配合 Lottie 实现罐子动画 |
| 持久化 | SwiftData + 文件系统 | SwiftData 存元数据,媒体文件存沙盒,数据库只存相对路径 |
| 语音转写 | `Speech` 框架 | 本地、免费、隐私好 |
| 媒体处理 | `PhotosUI` / `AVFoundation` | 系统组件,适配最稳 |
| AI 标题 | Anthropic SDK(`claude-haiku-4-5-20251001`) | 用户配置 API Key,Keychain 存储 |
| 通知 | 不引入 | 已决定不打扰 |
| 动画 | Lottie | 罐子充实动画需要矢量插画 |

### 3.2 仓库根目录

```
SmileJar/
├── project.yml                # XcodeGen 配置(单一可信源)
├── README.md                  # 构建说明 + AI Key 配置指引
├── .gitignore                 # 忽略 .xcodeproj、xcuserdata、DerivedData、.superpowers
├── SmileJar/                  # 源代码
│   ├── SmileJarApp.swift      # @main
│   ├── Info.plist
│   ├── Assets.xcassets/
│   ├── App/                   # 入口、根容器、全局环境
│   ├── Features/
│   │   ├── Home/              # 主屏:双罐卡 + 自定义分组列表
│   │   ├── GroupDetail/       # 分组详情:罐子大图 + 月份分段时间线
│   │   ├── EntryEditor/       # 新建/编辑 Sheet
│   │   ├── EntryDetail/       # 单条详情 + 分享卡片入口
│   │   └── Settings/          # 设置:AI Key、导出、关于
│   ├── Core/
│   │   ├── DataModel/         # SwiftData @Model 定义
│   │   ├── MediaStore/        # 文件读写、缩略图、压缩
│   │   ├── Transcription/     # 语音→文字(后台异步)
│   │   ├── AIService/         # 标题生成 + 兜底链
│   │   └── ShareCard/         # 单条记录生成图片
│   └── DesignSystem/          # 颜色、字体、Lottie 资源、复用组件
├── SmileJarTests/             # 单元 + 集成测试
└── SmileJarUITests/           # 占位,v1 不写
```

模块边界原则: UI 与数据/服务分离,`Features/*` 只通过 `Core/*` 暴露的接口拿数据。

### 3.3 `project.yml` 关键字段

```yaml
name: SmileJar
options:
  deploymentTarget:
    iOS: "17.0"
  bundleIdPrefix: com.smilejar
settings:
  base:
    SWIFT_VERSION: "6.0"
    DEVELOPMENT_LANGUAGE: zh-Hans
targets:
  SmileJar:
    type: application
    platform: iOS
    sources: [SmileJar]
    info:
      path: SmileJar/Info.plist
      properties:
        NSCameraUsageDescription: "用于拍摄记录"
        NSPhotoLibraryUsageDescription: "用于添加照片/视频到记录"
        NSMicrophoneUsageDescription: "用于录音"
        NSSpeechRecognitionUsageDescription: "用于将录音转为文字,便于搜索"
        UILaunchScreen: {}
    dependencies:
      - package: lottie-ios
        product: Lottie
  SmileJarTests:
    type: bundle.unit-test
    platform: iOS
    sources: [SmileJarTests]
    dependencies:
      - target: SmileJar
packages:
  lottie-ios:
    url: https://github.com/airbnb/lottie-ios
    from: "4.4.0"
```

### 3.4 构建流程

```bash
cd SmileJar
xcodegen generate         # 生成 .xcodeproj
open SmileJar.xcodeproj   # 用 Xcode 打开
# 选模拟器 → Cmd+R
```

`.xcodeproj` 不入仓,由 XcodeGen 现场生成。`.gitignore` 已含。

## 四、信息架构

### 4.1 底部 TabBar(三个 Tab)

| 位置 | 名称 | 作用 |
|---|---|---|
| 左 | **罐** | Home:双罐卡 + 自定义分组列表 |
| 中 | **＋** | 弹出"新建记录"Sheet(不 push,不切 Tab) |
| 右 | **我** | 全局搜索、分组管理、设置、备份导出 |

### 4.2 主屏(Home / 罐 Tab)

```
┌─────────────────────────┐
│ 5月23日 周六             │  日期问候
│ 我的储蓄罐               │  大标题
│                         │
│ ╭───────────────────╮   │
│ │ 🍯  微笑储蓄罐  ›  │   │  内置卡 1:罐插画+名+数量+最近一条预览
│ │     47 颗          │   │
│ │     咖啡店的老板…  │   │
│ ╰───────────────────╯   │
│                         │
│ ╭───────────────────╮   │
│ │ ✦  优势储蓄罐  ›  │   │  内置卡 2
│ │     12 颗          │   │
│ │     主动帮同事…    │   │
│ ╰───────────────────╯   │
│                         │
│ 自定义分组               │
│ ● 家人          8        │  细行列表
│ ● 旅行          5        │
│ ＋ 添加分组              │
└─────────────────────────┘
    罐    ＋    我
```

设计要点:

- 两个内置罐子默认展示,不需要任何操作即可看见
- 每张内置卡显示: 罐插画 + 分组名 + 总数 + 最近一条标题预览
- 自定义分组用细行列出(避免视觉拥挤),含彩色圆点 + 名称 + 数量
- 内置分组不可删除,自定义分组可改名/换色/删除
- **空态**: 当分组 `entries.count == 0` 时,卡片预览行显示淡灰提示文字"还没有储蓄,点 ＋ 记下今天的微笑吧";罐插画显示"空罐"样式(无填充)

### 4.3 分组详情页(点主屏卡片进入)

```
┌─────────────────────────────┐
│ ‹ 罐         微笑储蓄罐  ⋯   │  ⋯ 仅自定义分组显示(改名/换色/删)
│                             │
│         ╭─────╮             │  大罐插画(Lottie)
│         │ ☺ 47│             │  + 总数
│         ╰─────╯             │
│       [随机看一颗]           │  按钮触发随机记录抽取
│                             │
│ ┌─────────────────────────┐ │
│ │ 🔍 搜索这个分组           │ │  分组内全文搜索
│ └─────────────────────────┘ │
│                             │
│ #家人  #走路  #偶遇  📅    │  标签横滑 + 时间筛选入口
│                             │
│ 2026年5月                    │  按月分段
│ ┌─────────────────────────┐ │
│ │ 5月23日                  │ │
│ │ 咖啡店的老板记得我        │ │
│ │ 📷📷  📍南京西路          │ │
│ └─────────────────────────┘ │
│ ...                          │
└─────────────────────────────┘
```

### 4.4 单条详情页

```
┌─────────────────────────────┐
│ ‹                  分享  ⋯  │
│                             │
│ 5月23日 周六 14:23           │
│ 咖啡店的老板记得我  ✨        │  ✨= AI 生成的标题
│                             │
│ [照片轮播,16:9]              │
│ 今天去常去的那家店,老板抬头   │
│ 就笑着说"今天还是拿铁吗"……   │
│                             │
│ ▶ ━━━━━━━━━━━ 2:18          │  语音播放条
│ 转写:"今天真的很意外……"     │  转写文本,可折叠
│                             │
│ #偶遇  #咖啡  📍南京西路     │
└─────────────────────────────┘
```

⋯ 菜单: 编辑、移动到其他分组、删除、生成分享图

### 4.5 "我"Tab

包含: 全局搜索入口、分组管理(改名/排序/删除)、设置(AI Key、关于)、数据(导出全部)。

## 五、数据模型

### 5.1 SwiftData `@Model`

```swift
@Model
final class Group {
    @Attribute(.unique) var id: UUID
    var name: String              // "微笑储蓄罐" / "优势储蓄罐" / 用户自定义
    var iconSymbol: String        // SF Symbol 名,如 "face.smiling"
    var colorHex: String          // 罐子主色
    var isBuiltIn: Bool           // 内置两个为 true,不可删除
    var sortOrder: Int            // 主屏显示顺序
    var createdAt: Date
    @Relationship(deleteRule: .cascade, inverse: \Entry.group)
    var entries: [Entry] = []
}

@Model
final class Entry {
    @Attribute(.unique) var id: UUID
    var title: String
    var titleSource: TitleSource  // .auto / .ai / .manual
    var bodyText: String
    var createdAt: Date
    var updatedAt: Date
    var group: Group?
    @Relationship(deleteRule: .cascade, inverse: \MediaAttachment.entry)
    var attachments: [MediaAttachment] = []
    @Relationship(inverse: \Tag.entries)
    var tags: [Tag] = []
}

@Model
final class MediaAttachment {
    @Attribute(.unique) var id: UUID
    var kind: MediaKind           // .photo / .video / .voice
    var relativePath: String      // App 沙盒下相对路径
    var thumbnailPath: String?    // 缩略图(photo/video 有,voice 无)
    var durationSeconds: Double?  // 视频/语音时长
    var transcript: String?       // 语音转写文本,与原音共存
    var sortOrder: Int            // 在 Entry 中的顺序
    var entry: Entry?
}

@Model
final class Tag {
    @Attribute(.unique) var name: String
    var colorHex: String
    var entries: [Entry] = []
}

enum TitleSource: String, Codable { case auto, ai, manual }
enum MediaKind: String, Codable { case photo, video, voice }
```

### 5.2 媒体文件存储

- 路径模板: `Documents/Media/<entry-uuid>/<filename>`
- 数据库**只存相对路径**,不存 blob
- 删除 Entry 触发级联,数据库记录清掉的同时,显式清理对应 `Media/<entry-uuid>/` 目录

### 5.3 首次启动 seed

仅当 `Group` 表为空时插入:

```swift
[
  Group(name: "微笑储蓄罐", iconSymbol: "face.smiling", colorHex: "#E08A4A", isBuiltIn: true, sortOrder: 0),
  Group(name: "优势储蓄罐", iconSymbol: "sparkles",     colorHex: "#7AA350", isBuiltIn: true, sortOrder: 1),
]
```

### 5.4 索引

- `Entry.createdAt`(时间线倒序、月份分段)
- `Entry.group`(分组筛选)
- `Tag.name`(标签查找)
- `MediaAttachment.entry`(详情页关联)

SwiftData 通过 `@Attribute(.unique)` 和关系自动建大部分;其余用 `#Index` 宏显式声明。

### 5.5 标签作用域

标签全局共享:同一个"家人"标签可贴在微笑罐和优势罐的记录上。不按分组隔离。

## 六、核心交互流程

### 6.1 新建/编辑

中间 ＋ 按钮触发 Sheet。布局:

```
┌─────────────────────────────┐
│ 取消              5月23日   │  日期可点击改
│ ─────────────────────────── │
│ [自动标题占位,可手动编辑]   │  大字标题
│                             │
│ 默认分组:微笑储蓄罐  ▾     │  chip,下拉切换
│                             │
│ ┌─────────────────────────┐ │
│ │ 此刻发生了什么……         │ │  多行文本框
│ └─────────────────────────┘ │
│                             │
│ ┌────┐┌────┐                │
│ │ 📷 ││🎙 │                 │  已添加的附件
│ └────┘└────┘                │
│                             │
│ ─────────────────────────── │
│  📷   🎬   🎙   #          │  附件入口 + 标签
│                             │
│            [完成]            │
└─────────────────────────────┘
```

要点:

- 输入是纯文本,不是富文本编辑器;附件按 `sortOrder` 排列
- 📷 用 `PhotosPicker` 多选,🎬 同理或拍摄;🎙 内置录音 UI
- 长按附件拖拽排序,左滑删除
- 默认分组是"微笑储蓄罐"(最常用)
- 切到后台自动保存草稿到 `UserDefaults`
- 点"完成"才入库

### 6.2 语音转写(后台异步)

- 录完音立刻保存 `MediaAttachment`,`transcript = nil`
- 后台启动 `Speech` 转写,完成后回写 `transcript`
- UI 上"已转写"角标变化,搜索索引自动更新
- 转写失败保留原音,`transcript = nil`,搜索不命中转写
- 用户编辑模式可手动触发"重新转写"

### 6.3 语音附件生命周期

| 字段 | 状态 |
|---|---|
| `relativePath`(原音 `.m4a`) | **永久保留**,直到用户主动删除 |
| `transcript`(转写文本) | 与原音共存,转写完追加,不替换 |

删除语义: 删的是整个 `MediaAttachment`——原音 + 转写同时清掉,文件系统物理删除。不存在"只删音保留文字"或反过来的中间状态。

### 6.4 自动标题

触发时机: 文本/录音失焦时。

优先级链:

1. `titleSource == .manual` → 不动
2. AI 开启 且 有 Key → 调用 `ClaudeAIService`(超时 5s)→ 成功写入,`titleSource = .ai`
3. 兜底 `LocalTitleService`: 文本首句(≤20 字)→ 转写首句 → "{月}月{日}日 · {groupName}"

标题字段右侧 ✨ 图标表示 AI 生成,点击可重新生成。用户一旦手动编辑,`titleSource` 转为 `.manual`,后续不再被自动覆盖。

### 6.5 随机回顾

分组详情页罐子大图下方,有"随机看一颗"按钮。点击从该分组随机抽一条 Entry,以 Sheet 半屏弹出,带"再来一颗"和"看详情"两个按钮。

**空态**: 当分组无记录时,按钮置灰禁用,下方提示"还没有可以取出的微笑"。

不支持物理摇晃手势。

## 七、AI 服务

### 7.1 接口

```swift
protocol AIService {
    func generateTitle(text: String, context: TitleContext) async throws -> String
}

struct TitleContext {
    var groupName: String   // 影响 prompt 语气
    var date: Date
    var hasMedia: Bool
}
```

### 7.2 实现

| 实现 | 触发 | 失败处理 |
|---|---|---|
| `ClaudeAIService` | 设置里配置了 API Key 且 AI 标题开关 ON | 5s 超时或异常 → 抛错,上层降级到本地 |
| `LocalTitleService` | 默认实现 | 文本首句 → 转写首句 → "{月}月{日}日 · {groupName}"(如"5月23日 · 微笑储蓄罐") |

### 7.3 调用细节

- **模型**: `claude-haiku-4-5-20251001`(标题任务足够,成本最低)
- **超时**: 5 秒
- **缓存**: 相同 text 5 分钟内重复请求走内存缓存
- **重试**: 不自动重试;失败由用户主动点 ✨ 重新生成
- **隐私边界**: 只发送 `Entry.bodyText` 和 `MediaAttachment.transcript`,**永远不发送照片/视频/语音原文件**
- **API Key 存储**: Keychain(`KeychainService.set("anthropic_key", value:)`),严禁 `UserDefaults`

### 7.4 Prompt

```
你是一款记录温暖瞬间的 App。请为下面这段记录生成一个不超过 15 字的中文标题,
风格温柔、具象、不煽情。分组是"{groupName}",日期是 {date}。

记录内容:
{text}

只回标题本身,不要任何解释、引号或标点结尾。
```

### 7.5 设置项

- AI 标题开关(默认 OFF)
- API Key 输入框(脱敏显示 `sk-ant-...xxxx`)
- "测试连接"按钮
- 帮助链接(指向 console.anthropic.com)

## 八、检索

| 能力 | 入口 | 实现 |
|---|---|---|
| 全文搜索 | 分组页搜索框 + "我"Tab 全局搜索 | SwiftData `#Predicate` 对 `Entry.title`、`Entry.bodyText`、`MediaAttachment.transcript`、`Tag.name` 做 `contains`,结果按时间倒序 |
| 标签筛选 | 分组页顶部横滑 chip | 单选或多选(交集) |
| 时间筛选 | 标签栏右侧 📅 按钮 | 弹出年/月选择器或自定义区间 |

分组页搜索作用域默认是当前分组;"我"Tab 全局搜索跨所有分组。

## 九、分享与导出

### 9.1 单条分享图

详情页 → 分享 → SwiftUI `ImageRenderer` 生成 1080×1920 PNG → `ShareLink` 调系统分享面板。

布局元素: 顶部品牌行 / 主照片(无照片则纯色背景) / 大字标题 / 正文摘要 / 底部"存于 微笑储蓄罐"角标。

### 9.2 全库导出

设置 → 数据 → 导出全部记录 → 生成 zip:

```
smilejar-backup-2026-05-23.zip
├── manifest.json     # 版本号 + 导出时间
├── groups.json
├── entries.json
├── tags.json
└── media/
    └── <entry-uuid>/
        ├── photo-001.heic
        ├── voice-001.m4a
        └── ...
```

通过 `ShareLink` 让用户存到"文件" App、iCloud Drive 或 AirDrop。

导入功能 v1 不做(导出已能保证数据不丢)。

## 十、测试策略

| 层 | 覆盖 | 工具 |
|---|---|---|
| Unit | `AIService`、`LocalTitleService`、`MediaStore` 路径生成、Entry/Group seed、搜索 predicate、zip 导出 | Swift Testing(Xcode 26 内置) |
| Integration | SwiftData 持久化 + 级联删除、媒体文件与数据库一致性 | Swift Testing + 临时 in-memory `ModelContainer` |
| UI Snapshot | 主屏、分组页、详情页、分享卡片(三种态:纯文字 / 含媒体 / 满罐) | swift-snapshot-testing |
| 手动 | 录音转写、PhotosPicker、ShareLink、Lottie 动画 | 模拟器/真机 |

不做端到端 XCUITest(维护成本高于价值)。

## 十一、MVP 范围

### v1 必做

- [ ] 主屏: 双罐卡 + 自定义分组列表
- [ ] 分组详情: 罐子大图 + 月份分段时间线 + 标签筛选 + 时间筛选 + 搜索 + 随机看一颗
- [ ] 新建/编辑: 文本 + 照片 + 视频 + 语音(后台异步转写)
- [ ] 详情页 + 单条分享卡片
- [ ] 标签全局共享(创建、贴在记录上、筛选)
- [ ] 内置两个分组 + 自定义分组增删改
- [ ] AI 标题(Claude Haiku 4.5 + Keychain + 本地兜底链)
- [ ] 全库 zip 导出
- [ ] 罐子 Lottie 动画(随数量变化)

### v1 不做(留 v2)

- 进阶统计、心情趋势图
- 导入备份
- iCloud 同步、多设备
- Face ID 锁
- Widget、Live Activities
- 提醒通知
- Apple Watch
- 多语言(v1 只做简体中文)

## 十二、视觉风格

温暖治愈风:

- **主色调**: 暖橙 `#E08A4A` + 米色背景 `#FFF4E4`
- **辅色**: 优势罐用草绿 `#7AA350`,自定义分组用户自选
- **字体**: PingFang SC,标题 Semibold,正文 Regular
- **罐插画**: 手绘风玻璃罐 SVG,Lottie 动画填充,随 `entries.count` 升高
- **圆角**: 卡片 14-18px,按钮 999px(胶囊)
- **质感**: 卡片背景 `rgba(255,255,255,0.6)` 半透明叠层,营造柔和层次
