# Requirements Document

## Project Description (Input)
用户是 Obtainium 的长期个人 fork 维护者(可能 PR 上游)。现状:Obtainium 已实现本地导出/导入,但备份文件只能落盘到本机,换机 / 重装 / 丢手机时本地备份不可靠。该改动:为导出/导入流程增加"云端备份/恢复"能力——手动导出时除写本地文件,把同名 JSON 推送到 S3 或 WebDAV;导入时列出云端历史文件、挑一份拉回恢复。云端保留带时间戳的历史版本(不覆盖)。最高优先级约束:改动尽量"外挂式",集中在新增独立文件,不碰既有导出/导入逻辑与命名,以便长期无痛 `git merge upstream`。

## Boundary Context
- **In scope(范围内行为)**:
    - S3 与 WebDAV 两种云端目标的手动导出与手动导入
    - 云端保留带时间戳的历史文件,不覆盖先前上传的历史
    - 「同时导出应用设置」= 全部 时,把已配置的 S3/WebDAV 登录信息一并写入导出 JSON
    - 可同时配置多套凭证,每次导出由用户选定一个目标推送(不冗余推送多份)
- **Out of scope(范围外,本 spec 不做)**:
    - 自动定时后台备份(无后台调度)
    - 云端凭证加密存储 / Keystore
    - 云端历史文件的清理 / 回收策略
- **Adjacent expectations(对相邻系统的期望)**:
    - 复用现有本地导出/导入逻辑与既有文件命名,不改变其已有行为
    - 云端凭证持久化复用现有明文凭证存储机制(与 token / source 登录信息同机制)

## Requirements

### Requirement 1: 云端凭证配置
**Objective:** As a Obtainium 用户, I want 配置并保存 S3 和/或 WebDAV 的登录信息, so that 之后导出/导入时可复用而无需每次重新输入。

#### Acceptance Criteria
1. The Obtainium shall 允许用户配置 S3 连接参数(endpoint、bucket、access key、secret key、region)并持久化保存。
2. The Obtainium shall 允许用户配置 WebDAV 连接参数(URL、用户名、密码)并持久化保存。
3. The Obtainium shall 允许 S3 与 WebDAV 凭证同时保存,不因配置一方而清除另一方。
4. If 用户尚未配置任何云端目标, then the Obtainium shall 在云端导出/导入入口处提示无可用目标或禁用相应操作。
5. The Obtainium shall 以明文形式存储云端凭证,与现有 token / source 登录信息采用同一套存储机制,不进行额外加密。

### Requirement 2: 导出到云端
**Objective:** As a Obtainium 用户, I want 手动导出时把同名备份推送到选定的云端目标, so that 备份不依赖本机、换机或重装后可恢复。

#### Acceptance Criteria
1. When 用户执行导出且至少已配置一个云端目标, then the Obtainium shall 让用户选择一个目标进行推送(每次导出仅推送至用户选定的单个目标)。
2. When 用户选定目标并确认导出, then the Obtainium shall 把与本地导出文件同名的 JSON 文件上传到该目标。
3. The Obtainium shall 在云端保留每次导出产生的历史文件,不覆盖先前已上传的历史文件。
4. If 上传因网络、认证或服务端原因失败, then the Obtainium shall 向用户显示明确的错误信息,且已生成的本地导出文件不受影响。
5. Where 「同时导出应用设置」设为「全部」, the Obtainium shall 把当前已配置的 S3/WebDAV 登录信息一并写入导出 JSON。

### Requirement 3: 从云端导入
**Objective:** As a Obtainium 用户, I want 从云端列出历史备份并选一份恢复, so that 换机或重装后能拉回先前的应用与设置。

#### Acceptance Criteria
1. When 用户执行从云端导入且已配置目标, then the Obtainium shall 列出该目标上的历史导出文件,并使各文件可按时间辨识。
2. When 用户选定一份历史文件, then the Obtainium shall 下载该文件并复用现有本地导入逻辑将其恢复到本机。
3. If 下载或恢复过程失败, then the Obtainium shall 显示明确的错误信息,且不破坏本机现有应用与设置状态。
4. The Obtainium shall 经现有本地导入逻辑完成恢复,不引入与本地导入行为不一致的独立云端恢复路径。

### Requirement 4: 改动隔离与上游可合并性(用户可见的维护性预期)
**Objective:** As a fork 维护者, I want 该功能的改动尽量不侵入既有导出/导入代码与文件命名, so that 长期 `git merge upstream` 时冲突最小、可低成本跟随上游更新。

#### Acceptance Criteria
1. The Obtainium shall 不改变现有本地导出/导入的功能行为,也不改变现有导出文件命名规则。
2. Where upstream 未来更新触及现有导出/导入逻辑或文件命名, the Obtainium shall 使本功能的改动不与之耦合,从而合并上游时无需连带修改本功能。
3. The Obtainium shall 不为本功能新增第三方依赖(仅使用项目已有依赖实现 S3 与 WebDAV 传输)。
