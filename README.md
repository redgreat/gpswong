# gpswong

合宙（AirM2M）4G Cat.1 模组上的 LuatOS 定位追踪固件：采集 GNSS 定位点（8202 另带
三轴加速度，780EG 设备无加速度计），经 MQTT over TLS 上报到 EMQX，解码后写入 PostgreSQL，供 AgentWong
查询实时位置与历史轨迹。

## 数据链路

```
设备固件 ──MQTT/TLS──> EMQX ──emqx_pg_ingest──> PostgreSQL ──> AgentWong
         gpswong/<IMEI>/data    simlive_rb 解码    lc_racebox 轨迹表
         gpswong/<IMEI>/alarm   gpswong.alarm.v1   预警事件（围栏 / 电量 / 拆机 / 光敏）
         gpswong/<IMEI>/cmd     <── 服务端下发 set_fences / set_rules
```

## 硬件变体

| 目录 | 目标硬件 | 说明 |
| --- | --- | --- |
| `src_8202/` | Air8202C/G（Air780EGG CORE） | **当前主力固件 v0.3.2**。1Hz 定位 + DA221 加速度、震动唤醒节能、8 小时 Flash 离线轨迹、设备端围栏 / 电量 / 拆机 / 光敏预警、MQTT 下行远程配置、`simlive_rb` 二进制批量上报。详见 [src_8202/README.md](src_8202/README.md)。 |
| `src_780e_usb/` | Air780EG + USB 虚拟串口 GNSS（度云） | **v0.4.0**。与 8202 同一套流水线：1Hz 定位、离线缓存、批量 `simlive_rb` 写入 `lc_racebox`、电量 / 充电 / GNSS 失锁预警、设备端围栏。无加速度计，运动判定改用 GNSS 速度。GNSS 连续无定位时用基站回落补点（精度约百米到千米，不驱动围栏）。 |
| `src/` | 合宙官网 Air780EG 开发板 | **v0.4.0**。功能同 `src_780e_usb`，GNSS 串口 1，芯片初始化用 `$PCAS04,3`。保留基站回落：GNSS 无定位（地下车库等）时用基站补一个大致点，标记为 `fix_type=0`。 |
| `yed/` | 银耳达 GNSS 定位器（DTU 平台） | 银耳达 DTU 平台的任务脚本（`task.lua`），平台只接受一段代码，不是 LuatOS 工程，不能套用上面的模块结构。 |
| `resource/` | — | LuatOS `.soc` 底层、官方 lib、字体等本地资源（已 gitignore，不入库）。 |

## 主要特性（src_8202）

- **1Hz 有效定位采样**：只上传定位成功的 WGS84 点，室内不写 `(0,0)` 脏数据。
- **运动感知节能**：DA221 加速度计中断唤醒；开机先连续采集 5 分钟，之后仅在
  最后一次震动后 3 分钟内保持 1Hz，静止时每 5 分钟留一个心跳点。
- **离线轨迹缓存**：断网时定位点写入 22 字节紧凑 Flash 环形队列
  （`/gpswong_points.bin`），默认上限 8 小时 / 28,800 点，联网后回放为
  80 字节 RaceBox 记录批量补传。
- **批量 QoS 1 上报**：集齐 10 点或最老点等待 15 秒即发一包到
  `gpswong/<IMEI>/data`，复用 `emqx_pg_ingest` 已有解码器，无需新增表结构。
- **实时预警**：震动、拆机（Air8202G GPIO）、围栏进出、电量低 / 严重 / 恢复、充电、
  ADC 光敏（可选）经 `gpswong/<IMEI>/alarm` 即时推送，JSON schema 为 `gpswong.alarm.v1`。
- **设备端围栏**：圆形或多边形（WGS84），连续 2 次判定才确认进出，挡住边界漂移；
  首次观测只记基线，开机不误报。
- **远程下发**：`gpswong/<IMEI>/cmd` 下发 `set_fences`（即时生效）与 `set_rules`
  （重启后生效），无需重新烧录。
- **可靠性**：Lua 任务看门狗 + Air153C 外部硬件看门狗；GPIO26 绿灯指示
  脚本启动与 GNSS 定位状态；每点携带三轴 g 值入库。

## 快速开始

```powershell
cd src_8202
copy config.lua.sample config.lua   # 填入 MQTT host/账号/密码，勿提交真实凭据
./flash.ps1 -LuatoolsPath D:\Luatools\Luatools_v3.exe
```

然后在 LuaTools 中选择 Air780EGG 的 LuatOS `.soc`，加入目录内 9 个 Lua 文件（含 `geofence.lua`），
勾选"添加默认 lib"（需要 `exvib.lua` 与 `exair153x_wdt.lua`），执行
"下载底层和脚本"。完整烧录步骤、EMQX 插件配置与已知边界见
[src_8202/README.md](src_8202/README.md)。

## 服务端配套

- **EMQX 插件**：在 `emqx_pg_ingest.json` 的 `topics` 中注册
  `gpswong/+/data`（codec `simlive_rb`，profile `racebox_legacy`）。
- **下游**：轨迹写入 `imp_racebox` / `lc_racebox`，AgentWong 的轨迹回放与
  最新位置查询可直接读取；围栏判定在设备端完成，服务端负责 `gpswong.alarm.v1` 的归一化、去重和推送。
- **MQTT 主题**：服务端订阅 `gpswong/+/alarm`；向 `gpswong/<IMEI>/cmd` 发布下行命令，
  需要 EMQX ACL 允许设备账号订阅 `cmd`，并限制发布方。
- **坐标系**：库中保存 WGS84 原始值；微信/高德等地图展示层统一转 GCJ-02。

## Air780EG 工程（src / src_780e_usb）

1. 刷 LuatOS Air780EG 底包（`.soc`），用 LuaTools 新建工程，加入对应目录的 11 个 Lua 文件：
   `main`、`config`、`gnss`、`motion`、`alerts`、`geofence`、`spool`、`mqtt_upload`、`protocol`、`lbs`、`lbsLoc2`。
2. 不需要勾选“添加默认 lib”，本目录不依赖 `exvib`、`exair153x_wdt`。
3. 编辑 `config.lua`，填写 MQTT 地址、账号和密码（当前为 `"xxx"` 占位）。
4. 下载脚本，按 `gpswong/<IMEI>/data` 上报，EMQX 插件规则与 8202 相同。

## 给 AI 助手

本仓库已为 AI 编码助手准备入口文档 [AGENTS.md](AGENTS.md)，包含硬件变体说明、
构建验证方式、配置/密钥规则及常见坑，请在改动前先阅读。

## License

[MIT](LICENSE) © 2025 wongcw
