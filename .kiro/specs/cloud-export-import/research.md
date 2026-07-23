# Research & Design Decisions

## Summary
- **Feature**: `cloud-export-import`
- **Discovery Scope**: Complex Integration(向既有导出/导入流程新增 S3/WebDAV 云端传输,含安全敏感的 Sig V4 手写实现)
- **Key Findings**:
  - 现有导出 JSON 的"应用设置"机制以 prefs key 命名为准:`-creds` 后缀的 key 在 `exportSettings < 2` 时被剔除,`= 2(全部)` 时保留。新凭证只要沿用 `-creds` 命名,导出/导入"含凭证"零额外改动。
  - `AppsProvider.import(String appsJSON)` 是纯字符串入口,云端导入只需"下载一份 JSON 字符串 → 调用此方法",可完全外挂。
  - S3 唯一技术难点 AWS Signature V4 的核心是 HMAC-SHA256,已由项目现有依赖 `crypto` 提供;配 `http` 传输即可零新依赖。

## Research Log

### 现有导出/导入 JSON Schema
- **Context**: 确认新功能如何复用而非侵入现有导出逻辑。
- **Sources Consulted**: `lib/providers/apps_provider_import_export.dart`
- **Findings**:
  - `generateExportJSON()`(L17)产出 `ExportSchema`:`schemaVersion / exportedAt / appVersion / apps / settings`(`ExportSchema` L181)。
  - `settings` 是把 `prefs.getKeys()` 全量序列化;`shouldExportSettings < 2` 时 `removeWhere((k) => k.endsWith('-creds'))`(L32-34)。即 `exportSettings` 语义:`0=none / 1=excludeSecrets / 2=all`。
  - `export()`(L53)用 SAF(`shared_storage`)在导出目录创建文件,文件名 `obtainium-<ISO时间戳, 冒号→连字符>{-auto}.json`(L90-91),成功返回 `returnPath`(L98-100)。
  - `import(String appsJSON)`(L106):parse → 兼容新旧 schema → `saveApps` → `_applyImportedSettings`(L155,按类型写回 prefs)。
- **Implications**: 凭证用 `-creds` 命名 → 导出"全部"自动含、导入自动恢复,无需改 schema 与导入逻辑;云端导入只需喂 JSON 字符串。

### 凭证/设置持久化约定
- **Context**: 新增 S3/WebDAV 凭证应仿照哪种现有结构。
- **Sources Consulted**: `lib/providers/settings_provider.dart`
- **Findings**:
  - `SettingsProvider`(L62)`with ChangeNotifier`,底层 SharedPreferences;`_get<T>`(L68)+ 按类型 getter/setter + `notifyListeners()`。
  - `exportSettings` getter/setter(L698-705):值域 `0..2`,默认 `1`,存为 `prefs['exportSettings']`。
  - `getSettingString/setSettingString`、`getSettingBool/setSettingBool`(L412-429)是通用字符串/布尔设置入口。
- **Implications**: 新凭证可在 `SettingsProvider` 上新增带 `-creds` 后缀的 key,沿用现有 `prefs` + `notifyListeners` 模式;或为减少对 settings_provider 的侵入,放在独立的凭证存储里(见设计决策)。

### 导出/导入 UI 挂入点
- **Context**: 在哪挂"推送到云端 / 从云端选"最贴合现有结构。
- **Sources Consulted**: `lib/pages/import_export.dart`
- **Findings**:
  - `ExportSection`(L355)嵌入 Settings 页;`runObtainiumExport`(L377)调 `appsProvider.export()` 后仅 `showMessage`(L388)。
  - `ImportSection`(L168)嵌入 Add App 页;`runObtainiumImport`(L183)用 `FilePicker.pickFiles()` 选文件 → `appsProvider.import(data)`(L210)。
  - 表单标准组件:`GeneratedFormModal`(L233)、`GeneratedForm`(L831)用于构建动态设置表单;列表单选已有 `SelectionModal`(`onlyOneSelectionAllowed`,L539),可复用于"选一份云端文件"。
- **Implications**: 导出末尾(L388 toast 附近)、导入入口(L309 `obtainiumImport` tile 附近)各加一个新 action;凭证配置可用 `GeneratedFormModal` 弹窗或新增一个设置区块。

### i18n 约定
- **Context**: 新增 UI 文案如何接入。
- **Sources Consulted**: `pubspec.yaml`(assets/translations/)、各处 `tr('xxx')` 用法。
- **Findings**: 用 `easy_localization`,文案 key 经 `tr('key')` 引用,资产在 `assets/translations/`(多语言 JSON)。
- **Implications**: 新增若干 `cloudExport*` / `cloudImport*` 命名空间的 key,补全各语言文件。

### AWS Signature V4 自实现可行性
- **Context**: 验证"零新依赖手写 Sig V4"是否可行、风险如何控制。
- **Sources Consulted**: AWS Sig V4 规范、项目 `pubspec.yaml`(`crypto ^3.0.7`、`http ^1.6.0`)
- **Findings**: Sig V4 由 canonical request → string to sign → signing key(分层 HMAC-SHA256)→ 签名组成,全部可用 `crypto` 的 `Hmac`/`Sha256` 实现;本场景仅需 3 个操作(`PutObject` / `GetObject` / `ListObjectsV2`)。AWS 官方公开测试向量可用于自检。
- **Implications**: 可行;留一个基于 AWS 官方测试向量的 `assert` 自检,把"自己背签名 bug"的风险压到最低(见 risks)。

## Architecture Pattern Evaluation

| Option | Description | Strengths | Risks / Limitations | Notes |
|--------|-------------|-----------|---------------------|-------|
| 引入 `minio` 包 | 成熟 S3 客户端 | 边界情况已处理 | 新依赖 + 传递依赖 + 维护不确定性;杀鸡用牛刀 | 被否决 |
| 手写 Sig V4(选用) | 仅用现有 `crypto`+`http` 实现 3 个 S3 操作 | 零新依赖、与 WebDAV 代码统一、最贴 merge-upstream 约束 | 需自背签名正确性 | 配 AWS 官方测试向量自检 |

## Design Decisions

### Decision: 凭证 key 采用 `-creds` 后缀命名
- **Context**: 需让"导出=全部"自动含 S3/WebDAV 凭证、导入自动恢复。
- **Alternatives Considered**:
  1. 改 `ExportSchema` 新增专用字段
  2. 沿用现有 `-creds` 命名约定
- **Selected Approach**: S3/WebDAV 凭证以 prefs key 形式存储,key 以 `-creds` 结尾(如 `s3-creds` / `webdav-creds`)。
- **Rationale**: 现有 secrets 过滤逻辑(`endsWith('-creds')`)零改动即可覆盖;导入按类型回写 prefs 也零改动;最小侵入。
- **Trade-offs**: 凭证与一般设置混在 prefs 同一命名空间;可接受(本就是现有约定)。
- **Follow-up**: 确认凭证 JSON 序列化(多字段)存为单个字符串 prefs 值。

### Decision: 云端传输逻辑放独立 provider,不侵入 apps_provider_import_export
- **Context**: 最高优先级约束是 merge upstream 无痛。
- **Alternatives Considered**:
  1. 在 `apps_provider_import_export.dart` 的 `export()` 内直接加上传
  2. 新建独立 `cloud_storage_provider.dart`,导出/导入流程通过薄挂入点调用它
- **Selected Approach**: 新建独立 provider 与传输适配层(S3/WebDAV 各一文件 + 共享接口);现有文件只加极薄挂入点(导出成功后、导入入口旁)。
- **Rationale**: upstream 改动导出/导入逻辑时,冲突仅限极薄挂入点;核心实现隔离在新文件。
- **Trade-offs**: 需在现有文件插入调用点(无法完全零改动);保持挂入点最小化。
- **Follow-up**: 挂入点用清晰注释标记 fork 专有,便于 merge 时定位。

### Decision: S3 与 WebDAV 统一抽象为同一存储接口
- **Context**: 导出/导入 UI 与上层流程不应感知具体协议。
- **Alternatives Considered**:
  1. 两条完全独立路径
  2. 抽象出 `CloudStorage` 接口,两 provider 各自实现
- **Selected Approach**: 定义 `CloudStorage` 抽象(`upload / download / list`),`S3Storage` 与 `WebDAVStorage` 实现。
- **Rationale**: UI 层只面对"选目标 → 上传/下载/list";新增 provider 类型成本低;符合既有 source 抽象风格(`SourceProvider`)。
- **Trade-offs**: 抽象层少量代码;值得。

## Risks & Mitigations
- **Sig V4 签名正确性风险** — 用 AWS 官方公开测试向量写 `assert` 自检(纯函数,无网络),CI/`flutter test` 可跑;签名拼装集中在一个文件便于审查。
- **与 upstream merge 的挂入点冲突** — 挂入点最小化、加 fork 专有注释;核心逻辑全在新文件。
- **明文凭证随导出外泄** — 用户已确认接受(个人 fork,与现有 token 同机制);不额外加密(避免 Keystore 新依赖)。
- **S3 兼容服务差异(region/path-style)** — 凭证模型预留 endpoint/region/path-style 字段;默认行为兼容 AWS S3 与常见兼容服务(MinIO/R2/B2)。

## References
- `lib/providers/apps_provider_import_export.dart` — 现有导出/导入实现与 schema
- `lib/providers/settings_provider.dart` — 设置/凭证持久化约定
- `lib/pages/import_export.dart` — 导出/导入 UI 挂入点
- AWS Signature V4 规范 — Sig V4 拼装与官方测试向量
