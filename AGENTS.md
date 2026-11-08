# AGENTS.md

本文件是 AI 编码助手（Devin / Codex / Copilot 等）的本仓库入口，用于快速建立项目
上下文。所有规则均适用于整棵目录树。

## 项目概览

gpswong 是运行在合宙（AirM2M）4G Cat.1 模组上的 LuatOS Lua 固件集合，用于 GNSS
实时定位追踪：采集 WGS84 定位点（`src_8202` 另带三轴加速度，780EG 设备没有），经 MQTT（生产建议启用 TLS）批量上报到 EMQX，
再由 `emqx_pg_ingest` 插件按 `simlive_rb` 二进制协议解码写入 PostgreSQL，最终供
AgentWong 查询轨迹。自 v0.3.2 起，`src_8202` 在设备端判定围栏、电量和光敏事件，
服务端只做归一化、去重和推送；设备端不转换坐标系。

## 目录结构与硬件变体

| 目录 | 目标硬件 | 状态 |
| --- | --- | --- |
| `src_8202/` | Air8202C/G（Air780EGG CORE） | **当前主力**，v0.3.2 |
| `src_780e_usb/` | Air780EG + USB 虚拟串口 GNSS（度云） | **v0.4.0**，与 `src_8202` 同一套流水线，无加速度计 |
| `src/` | 合宙官网 Air780EG 开发板 | **v0.4.0**，与 `src_8202` 同一套流水线，无加速度计 |
| `yed/` | 银耳达 GNSS 定位器（DTU 平台） | 银耳达 DTU 平台任务脚本 `task.lua`，单段代码，**不是 LuatOS 工程**，不套用模块结构 |
| `resource/` | LuatOS `.soc`、官方 lib、字体 | 本地资源，已被 `.gitignore` 忽略，勿提交 |

各 `src*` 目录相互独立，**不要跨目录 `require` 代码**；改动前先确认用户针对
的是哪个硬件变体。无特别说明时默认工作对象是 `src_8202/`。

**有意的代码复制**：`protocol.lua`、`spool.lua`、`mqtt_upload.lua`、`geofence.lua`
在 `src_8202/`、`src_780e_usb/`、`src/` 三处内容相同；`motion.lua`、`alerts.lua`、
`gnss.lua`、`lbs.lua`、`main.lua` 在 780EG 两个目录内相同（`main.lua` 只差 `PROJECT` 名；`src_8202`
版本依赖加速度计与光敏，有差异）。
改协议、队列、上报、围栏逻辑时**三处都要同步**，可用 `git diff --no-index` 比对。

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

`main.lua` 启动顺序即依赖顺序：`mobile.simid` 切卡 → 看门狗 → 可选 ADC 光敏
`adc.open` → `mqtt_upload` → `motion` → `alerts`（内部启动 `geofence`、电量与光敏采样）
→ `gnss` → `sys.run()`。

- 模块间通过 `sys.publish`/`sys.subscribe` 解耦，事件名前缀 `GPSWONG_`。
- `protocol.lua` 同时负责两种编码：Flash 离线队列 22B 紧凑记录
  （`encode_spool`）与上报用 80B `simlive_rb` RaceBox 记录（`encode_record`）。
  修改任一格式必须保持与 EMQX 插件解码端兼容，否则整包数据无法入库。
- `spool.lua` 管理 `/gpswong_points.bin` 环形队列，满后淘汰最旧点。
- `geofence.lua` 订阅 `GPSWONG_POINT` 做设备端围栏判定（圆形 / 多边形，连续
  `debounce_n` 次同向才确认进出），围栏列表与状态存 `fskv`。
- `alerts.lua` 统一发出 `GPSWONG_ALERT`（围栏、电量、充电、GPIO 拆机、ADC 光敏），
  均为「状态翻转才发 + 滞回」。`info` 级别服务端默认不推送，需要提醒人的事件必须标
  `warning` 或 `critical`。
- `mqtt_upload.lua` 同时处理下行 `cmd_topic`：`set_fences` 即时生效，`set_rules` 只落盘、
  重启后生效。
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
4. **Air8202C 没有光敏电阻**：`light_alarm.enabled` 和 `light_alarm.adc_enabled` 必须为
   `false`，否则 WAKEUP3 悬空会误报拆机，ADC 读数也无意义。
5. **坐标系**：设备上报 WGS84 原始值。GCJ-02 转换属于展示层职责，禁止在固件或入库
   层做坐标偏移。
6. **报警不进离线队列**：所有 `GPSWONG_ALERT`（震动、拆机、围栏、电量、光敏）在 MQTT
   离线时直接丢弃，这是有意设计；如要改需同步文档。
7. **LuatOS API 不是标准 Lua**：`sys`/`sysplus`/`mcu`/`hmeta`/`libgnss` 等均为
   模组私有 API，本地 lua 解释器跑不起来属正常，不要据此"修复"代码。
8. **`sys.run()` 之后不能有任何语句**；`main.lua` 顶部的 `PROJECT`/`VERSION`
   全局变量是 LuaTools 项目管理必需字段，不能改成 local。
9. **围栏坐标必须是 WGS84**：`set_fences` 的 lat/lng 若来自高德、腾讯、百度地图（GCJ-02），
   下发前需先转换，否则偏移数百米。
10. **围栏重建基线**：`set_fences` 会清空进出状态并重新建立基线，首次观测不发事件；
    因此围栏更新后，设备已在围栏内不会立即报"进入"。
11. **`set_rules` 不热更新**：规则只写入 `fskv`，重启后生效，验证阈值改动需要重启设备。
12. **`src/projectConfig.lua` 含明文密码且已入库**：应视为已泄露，需要在 EMQX 轮换。
    新的 `src/config.lua` 已改为占位符，但 git 历史中的旧值仍在。
13. **`src/main.lua` 旧版不可运行**：引用的 `MQTT_*`、`cycletime`、`lbsLoc` 等全局量从未
    定义。v0.4.0 已重写，旧文件 `lbsLoc.lua`（依赖演示 PRODUCT_KEY）、`task*.lua`、`s_mqtt_cloudwong.lua`、
    `mqttInMsg.lua`、`sleep.lua`、`vbat_adc.lua`、`projectConfig.lua` 当前未被加载，待确认后清理。
14. **`src_780e_usb/myGNSS.lua`、`myMQTT.lua` 为旧版死代码**，未被 `main.lua` 加载。
15. **`encode_records` 的文件名前缀仍为 `8202_`**：780EG 目录沿用同一协议。服务端
    `emqx_pg_ingest` 若校验该前缀需要调整，目前未核实其解码源码。
16. **基站点的编码约定**：`source="lbs"` 点在 22B Flash 队列里用航向字段 `0xFFFF` 作哨兵，
    `protocol.encode_spool` 与 `spool_to_record` 必须同时改，回放时 `fix_type=0`、航向为 0。
    `emqx_pg_ingest` 对 `fix_type=0` 的处理（保留、过滤或降权）**尚未核实**，上线前需要确认，
    否则基站点可能被当作无效数据丢弃。
17. **`lbsLoc2` 是官方测试服务**（免 key，`free.bs.air32.cn` / `bs.openluat.com`），不保证 SLA，
    返回空即视为失败。基站坐标精度约百米到千米，展示层应按精度处理，不要当作 GNSS 点。

## src_780e_usb / src（Air780EG 工程，无加速度计）

- 新增合宙设备时新建独立文件夹，并同步本文件与根 README 的目录表。

- 启动顺序：`adc.open(CH_VBAT)` → 看门狗 → `mqtt_upload` → `alerts`（内部启动 `geofence`
  与电量采样）→ `gnss` → `sys.run()`。没有 `exvib`、没有 `mobile.simid`、没有光敏。
- **运动判定用 GNSS 速度**（`motion.lua`，阈值 `motion.speed_kmh`）。这两款设备**没有三轴加速度计**，
  代码里不得出现读取传感器的逻辑。`gforce_x/y/z` 不由 GNSS 或 motion 提供，`protocol.lua`
  取 `or 0` 默认值写入 80B 帧与离线队列（保留格式是为了和 8202 共用解码器）。
- `gnss.lua` 上电后按 `gnss.init_cmds` 发送芯片指令（`src_780e_usb` 用 `$CFGSYS`，`src` 合宙开发板用
  `$PCAS04`）；发指令要放在 `sys.taskInit` 中，因为内部用了 `sys.wait`。
- GNSS 失锁预警：`gnss_lost` / `gnss_recovered` 由 `gnss.lua` 发出，`lost_fix_alarm_sec = 0` 关闭。
- **基站回落**：`lbs.lua` 封装内置的 `lbsLoc2.lua`（免 key）。GNSS 连续无定位超过
  `lbs.after_no_fix_sec` 后，每 `lbs.interval_sec` 查一次基站，补一个 `source="lbs"`、
  `fix_type=0` 的点。这类点入轨迹，但**不驱动围栏**（`geofence.check` 直接返回），也**不更新运动判定**。
  查询放在 `sys.taskInit` 中执行，并受 `lbs_busy` 保护，不会并发。
- 电量预警同 `src_8202`（`battery_low` / `battery_critical` / `battery_recovered` /
  `charging_*`），但 ADC 换算依赖 `board.adc_range_3_8`，两个目录取值不同，换板子时先实测。
- `config.lua` 为 **git 跟踪文件**且当前为 `"xxx"` 占位，填真实凭据前先
  `git rm --cached` 或改为 `skip-worktree`，否则 `git add .` 会把凭据提交上去。

## 文档同步要求

修改 `src_8202/` 行为时同步更新 `src_8202/README.md`；修改任一 `src*` 目录的用途
或状态时同步更新根 `README.md` 的目录表。README 为中文。
