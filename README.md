# 微笑储蓄罐 (Smile)

一款本地优先、不打扰的 iOS 记录工具,用于归档生活中的微笑瞬间与温馨事件。

## 特性

- 两个内置分组:**微笑储蓄罐** / **优势储蓄罐**,可添加自定义分组
- 文本(类备忘录富文本编辑器)+ 照片(支持裁剪)+ 视频 + 语音的混合记录
- 语音自动转写(本地 Speech 框架)
- 可选 AI 自动标题(Claude Haiku 4.5,需自备 API Key)
- 全文搜索 + 标签 + 时间筛选
- **随机回忆**:随机取出一颗过往的微笑
- 单条记录生成分享图
- 全库 zip 备份**导出 / 导入恢复**,支持从其他 App「打开方式」直接导入备份
- 纯本地存储,不接 iCloud,无任何提醒推送
- 罐子充实动画随记录数量变化

## 技术栈

- iOS 17+ · Swift 5.10 · SwiftUI · SwiftData
- Xcode 26+ · XcodeGen
- ZIPFoundation(备份导出/导入)
- Anthropic API(可选)

## 构建

需要 macOS + Xcode 26+。一次性安装 XcodeGen:

```bash
brew install xcodegen
```

然后:

```bash
xcodegen generate
open Smile.xcodeproj
```

Xcode 中选择任一 iOS 17+ 模拟器,Cmd+R 运行。

## 配置 AI 自动标题(可选)

1. 在 [console.anthropic.com](https://console.anthropic.com) 创建 API Key
2. App 内进入"我 → 设置 → AI 自动标题"
3. 启用开关,粘贴 Key,点击"测试连接"

API Key 存于设备 Keychain,不离开本机。AI 调用仅发送文字和语音转写,**不发送照片/视频/语音原文件**。

## 项目结构

```
Smile/
├── App/                # 入口、Tab 容器
├── Features/           # 按业务功能分组的 UI
├── Core/               # 数据模型、服务层
└── DesignSystem/       # 颜色、罐子动画、复用组件
```

详见 `docs/superpowers/specs/2026-05-23-smile-jar-design.md`。

## 测试

```bash
xcodebuild -project Smile.xcodeproj -scheme Smile \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

覆盖:数据模型 + 全部 Core 服务 + 关键视图 snapshot。

## 数据安全

- 所有记录与媒体文件**仅存于本机沙盒**
- 媒体文件路径:`Documents/Media/<entry-uuid>/`
- 不接入 iCloud,手动备份/恢复:
  - 导出:"我 → 设置 → 导出全部记录",生成 zip
  - 导入:"我 → 设置 → 导入备份",或在其他 App 中对备份 zip 选择「打开方式 → 微笑储蓄罐」
- App 本身不加锁,依赖系统锁屏保护

## License

MIT
