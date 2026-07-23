# Brief: cloud-export-import

## Problem
Obtainium 已有本地导出/导入,但只能落盘到本机文件。换机 / 重装 / 丢手机时本地备份不可靠——用户(长期个人 fork 维护者)需要一份不依赖本机的云端备份/恢复能力。

## Current State
- 已有:`lib/providers/apps_provider_import_export.dart` 实现本地导出/导入 JSON;导出文件名形如
  `obtainium-<ISO 时间戳, 冒号→连字符>{-count-N}{-auto}.json`(天然唯一 → 历史版本)。
- 已有:`shared_preferences` 存各类凭证(token、source 登录信息),明文,无加密。
- 缺失:云端备份/恢复;无 S3/WebDAV 相关代码;无对应凭证模型。

## Desired Outcome
手动触发的"云端备份/恢复"能力,与现有本地导出/导入对称:
导出时除写本地文件,把同名 JSON 推送到 S3 或 WebDAV;导入时列出云端历史文件、挑一份拉回。
云端保留带时间戳的历史版本(不覆盖)。

## Approach
外挂式实现(集中在新文件),不改既有导出/导入逻辑与命名,以最大化 `git merge upstream` 的无痛度。
- S3:手写 AWS Signature V4(仅依赖已在 `pubspec.yaml` 中的 `crypto` + `http`,零新依赖),只实现 `PutObject` / `GetObject` / `ListObjects`;附基于 AWS 官方测试向量的最小自检。
- WebDAV:纯 `http` 手写(PROPFIND 列目录、PUT 上传、GET 下载)。
- 导入:复用现有本地导入逻辑(parse JSON → restore state),云端部分仅负责"下载一份 JSON 喂进去"。

**为什么手写而非引 minio**:确认时核验 `pubspec.yaml`,`crypto`/`http` 已在依赖,而 Sig V4 核心即 HMAC-SHA256;本场景 S3 操作 surface 极小(3 个),少一个依赖 = 少一个 upstream 冲突点与停更风险。

## Scope
- **In**:
    - S3(手写 Sig V4)+ WebDAV(纯 http),两者都做
    - 「同时导出应用设置」= 全部 时,S3/WebDAV 登录信息一并进 JSON
    - 上传文件名 = 现有本地导出文件名(天然时间戳 → 历史版本)
    - 手动触发(无后台调度 / 无 WorkManager)
    - 导入:列出云端历史文件 → 用户选一份 → 下载 → 复用现有本地导入逻辑恢复
    - 凭证明文存储(与现有 token/source 凭证同机制)
- **Out**:
    - 自动定时后台备份(WorkManager 等)
    - 凭证加密存储 / Keystore
    - 云端文件清理策略(历史无限堆积,用户自行清理)

## Boundary Candidates
- `云端传输适配层`(S3/WebDAV 的上传/下载/list,与业务无关)
- `凭证模型 + 持久化`(并入现有 settings/export JSON 的方式)
- `UI 挂入点`(在现有导出/导入流程末尾加"推送到云端"/"从云端选"两步)
- `Sig V4 签名`(纯函数,可独立自检)

## Out of Boundary
- 不做后台调度 / 定时任务
- 不做凭证加密
- 不做云端清理 / 回收
- 不改既有导出 JSON 的 schema 之外的内容(新增字段除外)

## Upstream / Downstream
- **Upstream**:现有 `apps_provider_import_export.dart`(导出/导入)、`settings_provider.dart`(凭证持久化约定)、`pages/import_export.dart` 与 `pages/apps.dart`(UI 挂入点)
- **Downstream**:未来若加自动备份(WorkManager),会依赖本 spec 的传输适配层与凭证模型

## Existing Spec Touchpoints
- **Extends**:无(kiro greenfield,本 spec 为首个)
- **Adjacent**:本地导出/导入逻辑(只复用,不改其行为)

## Constraints
- 【最高优先级】外挂式改动,集中在新增独立文件,不碰既有导出/导入逻辑与文件命名
- 代码质量往 PR 标准靠(贴合上游风格、零新依赖),但不强求 PR
- Dart SDK ^3.12.0 / Flutter >=3.44.0(见 `pubspec.yaml`)
- 接受导出 JSON 带明文凭证
- 平台:Android
