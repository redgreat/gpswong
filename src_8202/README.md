# Air8202 实时定位固件

当前脚本版本为 v0.3.2。Air8202 的内置贴片卡位于 SIM2；使用通用 Air780EGG
CORE 时，本工程会在联网任务启动前执行 `mobile.simid(1)`，否则 LuaTools 会显示
“SIM卡未插入”。GPIO26 绿灯在脚本启动时点亮，随后由 GNSS 定位状态接管。

本目录是 Air8202C/G（Air780EGG）专用 LuatOS 工程。运动期间默认以 1Hz 采集有效
WGS84 GNSS 点及同一时刻的 DA221 三轴加速度；累计 10 点或最老点等待 15 秒后，
以 QoS 1 批量发布到 `gpswong/<IMEI>/data`。采样、批量和等待时间均在 `config.lua`
中配置。载荷沿用
`emqx_pg_ingest` 已支持的 `simlive_rb` 二进制协议，因此无需新增数据库表或解码器。

## 烧录前

1. 编辑 `config.lua`，填写 MQTT 地址、账号和密码；不要提交真实凭据。
2. 安装最新版 LuaTools，准备 Air780EGG 的 LuatOS `.soc`。
3. USB 连接 Air8202；低功耗固件导致 USB 不出现时，按官方 BOOT 时序进入下载模式。
4. 执行 `./flash.ps1 -LuatoolsPath D:\Luatools\Luatools_v3.exe`。
5. 在打开的项目管理中添加本目录 9 个 Lua 文件（含新增的 `geofence.lua`），勾选“添加默认 lib”（需要
   `exvib.lua` 和 `exair153x_wdt.lua`），选择
   Air780EGG core 后执行“下载底层和脚本”。

`flash.ps1` 负责文件和凭据占位符预检并启动官方工具。LuaTools 未提供稳定的公开
命令行参数，因此脚本不会伪装成无人值守烧录；最终下载动作仍在官方界面完成。

## EMQX 插件配置

在 `emqx_pg_ingest.json` 的 `topics` 中追加：

```json
{ "topic": "gpswong/+/data", "codec": "simlive_rb", "profile": "racebox_legacy", "device_from_topic": 2 }
```

重载插件后查看 `emqx_pg_ingest:stats().`，应看到 `accepted`、`written` 增长。数据写入
`imp_racebox` / `lc_racebox`，AgentWong 现有轨迹查询可直接读取。

## 实时预警（v2）

v0.3.2 新增围栏 / 电量 / 光敏三类实时预警。**判定在设备侧完成，服务端
（AgentWong）只做归一化、去重和 PUSH_PLUS 推送**，不再重复算围栏。

核心原则：`gpswong/<IMEI>/data` 的 80 字节 `simlive_rb` 帧**一个字节都不改**，
现有 `emqx_pg_ingest` 解码器零改动；所有预警走 `gpswong/<IMEI>/alarm` 的 JSON，
schema 仍是 `gpswong.alarm.v1`。

### 事件一览

| type | severity | 触发条件 | value |
|---|---|---|---|
| `geofence_enter` / `geofence_exit` | warning | 连续 `debounce_n` 次判定状态翻转；首次观测只记基线不发事件 | 1 / 0 |
| `battery_low` | warning | VBAT < `low_mv`（默认 3600） | mV |
| `battery_critical` | critical | VBAT < `critical_mv`（默认 3400） | mV |
| `battery_recovered` | info | VBAT 回到 `recover_mv`（默认 3750）以上 | mV |
| `charging_started` / `charging_stopped` | info | `misc.getVbus()` 状态翻转（固件不支持时静默跳过） | 1 / 0 |
| `tamper_open` / `tamper_clear` | critical / info | GPIO 数字拆机检测（仅 Air8202G） | GPIO level |
| `light_exposed` / `light_dark` | warning / info | ADC 光敏电压越过 `adc_threshold_mv`（默认关闭） | mV |

电量 / 光敏都带滞回，且只在**状态翻转**时发一次；档位存 `fskv`，重启不会重复报警。
`info` 级别在服务端默认不推送（PUSH_PLUS `min_severity=warning`），只留记录。

上行示例：

```json
{
  "type": "geofence_exit", "severity": "warning", "value": 0,
  "fence_id": "company", "fence_name": "公司",
  "lat": 36.0671, "lng": 120.3826,
  "device_id": "86...", "ts": 1762520000, "seq": 12,
  "schema": "gpswong.alarm.v1"
}
```

### 下行配置（不用重新烧录）

设备联网后会订阅 `gpswong/<IMEI>/cmd`（QoS 1）。向该主题发：

```json
{"cmd":"set_fences","fences":[
  {"id":"home","name":"家","shape":"circle","lat":36.0671,"lng":120.3826,
   "radius_m":300,"enter_alert":true,"exit_alert":true},
  {"id":"company","name":"公司","shape":"polygon",
   "points":[{"lat":36.07,"lng":120.39},{"lat":36.07,"lng":120.40},
             {"lat":36.08,"lng":120.40},{"lat":36.08,"lng":120.39}]}
]}
```

`set_fences` 会校验、写入 `fskv` 并清空进出状态，让新围栏重新建立基线（首次观测
不会误报）。也支持 `{"cmd":"set_rules","battery_alarm":{...}}`，规则只落盘、
**重启后生效**，不热更新运行中的阈值。未知命令只记日志，报文异常不会让 MQTT 任务退出。
烧录时也可以直接把围栏写进 `config.lua` 的 `geofence.fences`。

坐标统一 WGS84，与上报点一致；`enter_alert` / `exit_alert` 可单独关闭某一方向。

### 光敏硬件前提

Air8202C **没有焊光敏电阻**，`light_alarm.enabled` 和 `adc_enabled` 都必须保持
`false`。要用 ADC 光敏需外接 GM5528 + 10K 分压到 ADC3 并在 `main.lua` 打开
`adc.open(3)`；比较的是 ADC 电压 mV，不是真实照度，阈值必须按接线标定，
所以配置项叫 `adc_threshold_mv` 而不是 lux。Air8202G 的 GPIO 数字拆机检测保持不变。

### 提到 5Hz 的完整步骤

通勤算里程 / 时长 1Hz 已足够，默认不动。确需 5Hz 时必须同时做：

1. 提高 `gnss.baudrate`，并向 CASIC 芯片写倍频指令（参考官方
   `demo/gps/Air820/自适应/autoGPS.lua` 的 `$PCAS06,0*` 系列）；
2. `gnss.lua` 定时器改 200ms，并给 `itow` 补亚秒序号，否则同秒 5 点时间戳重复；
3. `upload.batch_points` 相应调大、`offline_hours` **必须下调**：5Hz 下 8 小时
   约 144000 点 ≈ 3.17MB，远超 Air780EGG 约 800KB 用户文件系统；
4. `motion.only_when_moving` 的软件门控（静止 5 分钟 1 点）会直接压掉高频采集，
   需要一并调整。

`protocol.lua` 的 `duration` 已改为 `math.floor`，浮点周期不会再让
`string.pack("<I4")` 抛错。

### 服务端接入（链路闭环）

`.../alarm` 的 JSON 必须由 EMQX 转发到 AgentWong 才会真正推送。推荐用 EMQX
规则引擎的 HTTP 动作（或 WebHook）：

- 规则 SQL：`SELECT payload, topic FROM "gpswong/+/alarm"`
- HTTP 动作：`POST http://<cron_scheduler>:8102/internal/gps-alarm`，
  body 形如 `{"payload": ${payload}, "topic": ${topic}}`

`cron_scheduler` 的 `/internal/gps-alarm` 会校验 `gpswong.alarm.v1`、写
`alert_events`（`dedup_key` 幂等），然后**立即**经 PUSH_PLUS 推送；每 5 分钟的
`__gps_alert_watch` 定时任务只作为兜底和类 A（智梦行 / 图强）扫描。
端点兼容原始 JSON、WebHook envelope 的文本 payload 和 base64 payload。

该端点与 `/internal/reload`、`/internal/trigger` 一样没有应用层鉴权，
生产必须由网关 / 反向代理限制来源，不要暴露到公网。

PUSH_PLUS token 在 admin 后台「系统设置 → 推送配置」填写，加密存
`system_settings(key='push_plus')`；支持启用开关、群组 topic、最低告警级别、
冷却分钟和「发送测试消息」。

## 当前边界

- 固件只上传有效 GNSS 点；室内未定位不会写入 `(0,0)` 脏数据。
- 每个定位点携带 DA221 的 X/Y/Z 加速度（单位 g），插件会分别写入
  `lc_racebox.gforce_x/gforce_y/gforce_z`；静止时受重力影响，某一轴接近 +/-1g 是正常现象。
- 默认开机前 5 分钟持续采集；之后仅在最后一次震动后的 3 分钟内保持 1Hz，静止时每
  5 分钟留一个心跳定位点。GNSS 当前保持开启以便震动后 1 秒内恢复采样；若以后追求更低
  功耗，可改成静止时关闭 GNSS，但重新定位会产生延迟。
- 定位记录先写 `/gpswong_points.bin` 固定 22 字节紧凑 Flash 队列。默认最多 8 小时，即
  28,800 点、纯记录约 633,600 字节；达到上限后淘汰最旧点。联网回放时还原为 80 字节
  RaceBox 记录。紧凑队列保留 UTC、经纬度、速度、航向、三轴；高度、卫星数、精度不进入
  离线记录。Air780EGG 官方标称用户文件系统约 800KB，实际剩余容量和持续写入寿命仍必须
  在所选 `.soc` 固件及真机上确认。
- 实时报警主题为 `gpswong/<IMEI>/alarm`，JSON schema 是 `gpswong.alarm.v1`。
  v0.3.2 起设备自行产生围栏 / 电量 / 光敏事件（见「实时预警（v2）」）。报警不进入
  离线队列，MQTT 离线时会丢弃并记日志 —— 这是当前一个真实缺口：断网期间的预警
  不会补发，要求可靠告警时需改成持久化队列。
- 围栏判定已移到设备端（防抖 + 状态机 + fskv 持久化），服务端只做归一化与去重；
  服务端仍保留对智梦行 / 图强的围栏判定，两条链路互不重复。
- 坐标为 WGS84。微信地图若出现偏移，应在展示层统一转 GCJ-02，不应修改原始库数据。
- `AgentWong.skills.data_queries.location_summary()` 的今日里程和点数仍只统计
  `lc_carlocdaily`；轨迹回放和最新位置已包含 `lc_racebox`。要完整显示运动汇总，需在
  AgentWong 中把里程/点数改为多源轨迹聚合计算。
- 当前 `emqx_pg_ingest` 使用 EMQX `message.publish` hook 后异步写库，并不是真正带 ACK
  的持久订阅队列。QoS 1 只保证设备到 Broker；若要求 Broker/插件重启时也不丢点，消费
  项目还需改成稳定 client id 的持久 QoS 1 订阅，并在数据库事务成功后确认消息，配套重试、
  死信和幂等键。
- 尚未在真实 Air8202 上完成 build、flash、MQTT、入库与 AgentWong 页面验收。
