# AGENTS.md

本文件是 AI 编码助手（Devin / Codex / Copilot 等）的本仓库入口，用于快速建立项目
上下文。所有规则均适用于整棵目录树。

## 项目概览

gpswong 是运行在合宙（AirM2M）4G Cat.1 模组上的 LuatOS Lua 固件集合，用于 GNSS
实时定位追踪：采集 WGS84 定位点与三轴加速度，经 MQTT over TLS 批量上报到 EMQX，
再由 `emqx_pg_ingest` 插件按 `simlive_rb` 二进制协议解码写入 PostgreSQL，最终供
AgentWong 查询轨迹。设备端不判断围栏、不转换坐标系。

## 目录结构与硬件变体

| 目录 | 目标硬件 | 状态 |
| --- | --- | --- |
| `src_8202/` | Air8202C/G（Air780EGG CORE） | **当前主力**，v0.3.1 |
| `src_780e_usb/` | Air780E（USB 通道） | 维护中，JSON 载荷 |
| `src_new/` | Air780E | `src_780e_usb` 同源重构版 |
| `src/` | 早期 LuatOS 工程 | 历史版本，GNSS + LBS 兜底 |
| `resource/` | LuatOS `.soc`、官方 lib、字体 | 本地资源，已被 `.gitignore` 忽略，勿提交 |

各 `src*` 目录相互独立，**不要跨目录共享或 import 代码**；改动前先确认用户针对
的是哪个硬件变体。无特别说明时默认工作对象是 `src_8202/`。

## 构建与验证

- 本仓库**没有本地构建/测试管线**：LuatOS 固件只能在目标模组上运行，PC 端无模拟器。
- `src_8202/flash.ps1` 只做文件清单与凭据占位符预检，然后启动 LuaTools；实际烧录在
  LuaTools 图形界面完成（选择 Air780EGG `.soc`，勾选"添加默认 lib"）。
- 修改 Lua 代码后的验证方式：语法层面可用 `luac -p` 静态检查（若有），其余只能靠
  代码审查 + 真机 LuaTools 日志验证。不要声称"已测试通过"除非真机验证过。
- 提交前确认 `git status`：`src_8202/config.lua` 和 `resource/` 必须在 `.gitignore`
  范围内，不得入库。

## 配置与密钥规则

- 真实凭据只写 `config.lua`（已 gitignore）；修改配置结构时**同步更新**
  `config.lua.sample`，其中占位符统一用 `"xxx"`。`flash.ps1` 会拦截 `CHANGE_ME`。
- 绝不向仓库提交 MQTT host/username/password、IMEI 清单等敏感信息。

## src_8202 模块约定

`main.lua` 启动顺序即依赖顺序：`mobile.simid` 切卡 → 看门狗 → `mqtt_upload` →
`motion` → `alerts` → `gnss` → `sys.run()`。

- 模块间通过 `sys.publish`/`sys.subscribe` 解耦，事件名前缀 `GPSWONG_`。
- `protocol.lua` 同时负责两种编码：Flash 离线队列 22B 紧凑记录
  （`encode_spool`）与上报用 80B `simlive_rb` RaceBox 记录（`encode_record`）。
  修改任一格式必须保持与 EMQX 插件解码端兼容，否则整包数据无法入库。
- `spool.lua` 管理 `/gpswong_points.bin` 环形队列，满后淘汰最旧点。
- 功耗策略由 `config.lua` 的 `motion.*` 组控制；改默认值时同步更新 `src_8202/README.md`
  的"当前边界"章节。

## 已知的坑（改动前先读）

1. **SIM 卡槽**：Air8202 内置贴片卡在 SIM2，`main.lua` 必须在任何联网任务前执行
   `mobile.simid(cfg.sim.slot)`，否则报"SIM卡未插入"。不要删除或推迟这段代码。
2. **默认 lib 依赖**：`exvib.lua`（DA221 震动）和 `exair153x_wdt.lua`（Air153C 外部
   看门狗）来自 LuaTools"添加默认 lib"，均以 `pcall(require, ...)` 软依赖方式加载；
   缺失时只降级不崩溃，改动时保持这个模式。
3. **exvib 初始化是异步的**：`sensor.open()` 后约 1 秒 DA221 才就绪，读数前必须检查
   `motion.ready`。
4. **Air8202C 没有光敏电阻**：`light_alarm.enabled` 必须为 `false`，否则 WAKEUP3
   悬空会误报拆机。
5. **坐标系**：设备上报 WGS84 原始值。GCJ-02 转换属于展示层职责，禁止在固件或入库
   层做坐标偏移。
6. **报警不进离线队列**：`vibration`/`tamper_*` 报警在 MQTT 离线时直接丢弃，这是
   有意设计；如要改需同步文档。
7. **LuatOS API 不是标准 Lua**：`sys`/`sysplus`/`mcu`/`hmeta`/`libgnss` 等均为
   模组私有 API，本地 lua 解释器跑不起来属正常，不要据此"修复"代码。
8. **`sys.run()` 之后不能有任何语句**；`main.lua` 顶部的 `PROJECT`/`VERSION`
   全局变量是 LuaTools 项目管理必需字段，不能改成 local。

## 文档同步要求

修改 `src_8202/` 行为时同步更新 `src_8202/README.md`；修改任一 `src*` 目录的用途
或状态时同步更新根 `README.md` 的目录表。README 为中文。
