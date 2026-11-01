# Air8202 实时定位固件

当前脚本版本为 v0.3.1。Air8202 的内置贴片卡位于 SIM2；使用通用 Air780EGG
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
5. 在打开的项目管理中添加本目录 8 个 Lua 文件，勾选“添加默认 lib”（需要
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
- 实时报警主题为 `gpswong/<IMEI>/alarm`，JSON schema 是 `gpswong.alarm.v1`。设备产生
  `vibration`、`tamper_open`、`tamper_clear`；Air8202C 必须把 `light_alarm.enabled` 设为
  `false`。报警按需求不进入离线队列，MQTT 离线时会丢弃并记录日志。
- 围栏不在设备端判断。AgentWong 后续消费定位数据判断进出围栏后，可以向同一报警处理链
  产生 `geofence_enter` / `geofence_exit` 事件。
- 坐标为 WGS84。微信地图若出现偏移，应在展示层统一转 GCJ-02，不应修改原始库数据。
- `AgentWong.skills.data_queries.location_summary()` 的今日里程和点数仍只统计
  `lc_carlocdaily`；轨迹回放和最新位置已包含 `lc_racebox`。要完整显示运动汇总，需在
  AgentWong 中把里程/点数改为多源轨迹聚合计算。
- 当前 `emqx_pg_ingest` 使用 EMQX `message.publish` hook 后异步写库，并不是真正带 ACK
  的持久订阅队列。QoS 1 只保证设备到 Broker；若要求 Broker/插件重启时也不丢点，消费
  项目还需改成稳定 client id 的持久 QoS 1 订阅，并在数据库事务成功后确认消息，配套重试、
  死信和幂等键。
- 尚未在真实 Air8202 上完成 build、flash、MQTT、入库与 AgentWong 页面验收。
