# Product

<!-- impeccable:product-schema 1 -->

## Platform

web

## Stack

静态单文件 HTML/CSS（无构建步骤），部署在自有服务器 nginx（tiek.liangjf.com），GitHub Actions 验证自动同步。

## Users

主要用户：macOS 个人用户（开发者、知识工作者、重度截图使用者），习惯键盘操作，需要快速截屏、贴图对照、标注分享。场景：对照内容工作时把截图钉在桌面、给截图加标注发给同事、从截图里复制文字。

## Product Purpose

贴刻（TieKe）是一款免费开源的 macOS 截图贴图工具：全局快捷键截图、选区即贴图、六种标注工具（箭头/文字/马赛克/聚光灯/放大镜/方框）、样式实时可调、Vision 本机识字、重启恢复。成功 = 用户三分钟内完成"下载 → 截图 → 贴图 → 标注"完整体验。

## Positioning

功能对标知名闭源工具（PixPin），但完全开源（MIT）、无账号、无网络依赖、数据全本机——"开源 + 本地优先 + 免费"是闭源竞品无法诚实复制的组合。轻量（约 500KB DMG、无第三方依赖）。

## Operating Context

- 下载渠道仅 GitHub Releases（DMG，Apple Silicon）
- 官网与源码同仓库，落地页即 `website/index.html`
- 应用未公证：用户首次打开需右键→打开（落地页安装区已说明）
- 需要 macOS 15+，首次使用授予屏幕录制权限
- 中文为主要界面语言

## Capabilities and Constraints

- 无账号体系、无付费、无遥测——落地页不得出现"注册/购买/订阅"类 CTA
- 功能以已实现者为限：不宣传录屏、长截图、翻译、云同步
- 证据素材：一张手绘风宣传封面（website/assets/cover.jpg），无真实截图、无用户评价——不得虚构
- 发布以 GitHub Release tag 为准，当前 v1.0.0

## Brand Commitments

- 名称：贴刻 / TieKe（"贴"字可做蓝色强调处理——已有落地页惯例）
- 主色：#2f6bff 蓝（既有落地页与 README 徽章一致使用）
- 封面插画为手绘水彩风（桌面+猫+图钉贴图意象），是品牌资产
- 语气：直接、克制、不夸大

## Evidence on Hand

- 封面插画：website/assets/cover.jpg（真实品牌资产）
- DMG 产物：GitHub Release v1.0.0（469KB）
- 无用户评价、无下载量数据、无媒体引用——不得虚构

## Product Principles

1. 本地优先：一切能力在本机完成，官网也不加载第三方脚本
2. 克制真实：只说做得到的事，不放虚构证据
3. 键盘优先：宣传快捷键效率，服务重度使用者
4. 开源透明：下载、源码、许可一处可查
