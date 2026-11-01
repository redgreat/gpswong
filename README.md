# gpswong

合宙（AirM2M）4G Cat.1 模组上的 LuatOS 定位追踪固件：采集 GNSS 定位点与
三轴加速度，经 MQTT over TLS 上报到 EMQX，解码后写入 PostgreSQL，供 AgentWong
查询实时位置与历史轨迹。

## 数据链路

```
设备固件 ──MQTT/TLS──> EMQX ──emqx_pg_ingest──> PostgreSQL ──> AgentWong
         gpswong/<IMEI>/data    simlive_rb 解码    lc_racebox 轨迹表
         gpswong/<IMEI>/alarm   gpswong.alarm.v1   报警事件
```

## 硬件变体

| 目录 | 目标硬件 | 说明 |
| --- | --- | --- |
| `src_8202/` | Air8202C/G（Air780EGG CORE） | **当前主力固件 v0.3.1**。1Hz 定位 + DA221 加速度、震动唤醒节能、8 小时 Flash 离线轨迹、防拆光敏报警、`simlive_rb` 二进制批量上报。详见 [src_8202/README.md](src_8202/README.md)。 |
| `src_780e_usb/` | Air780E | USB 通道版本，JSON 载荷上报定位/基站信息及电量、信号、内存等状态（示例见 `payload.json`）。 |
| `src_new/` | Air780E | 与 `src_780e_usb` 同源的模块化重构版（myGNSS / myMQTT / myWIFI）。 |
| `src/` | 早期 LuatOS 工程 | 最初实现：GNSS + LBS 基站兜底 + MQTT，保留作参考。 |
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
- **实时报警**：震动与拆机（仅 Air8202G 光敏）事件经
  `gpswong/<IMEI>/alarm` 即时推送，JSON schema 为 `gpswong.alarm.v1`。
- **可靠性**：Lua 任务看门狗 + Air153C 外部硬件看门狗；GPIO26 绿灯指示
  脚本启动与 GNSS 定位状态；每点携带三轴 g 值入库。

## 快速开始

```powershell
cd src_8202
copy config.lua.sample config.lua   # 填入 MQTT host/账号/密码，勿提交真实凭据
./flash.ps1 -LuatoolsPath D:\Luatools\Luatools_v3.exe
```

然后在 LuaTools 中选择 Air780EGG 的 LuatOS `.soc`，加入目录内 8 个 Lua 文件，
勾选"添加默认 lib"（需要 `exvib.lua` 与 `exair153x_wdt.lua`），执行
"下载底层和脚本"。完整烧录步骤、EMQX 插件配置与已知边界见
[src_8202/README.md](src_8202/README.md)。

## 服务端配套

- **EMQX 插件**：在 `emqx_pg_ingest.json` 的 `topics` 中注册
  `gpswong/+/data`（codec `simlive_rb`，profile `racebox_legacy`）。
- **下游**：轨迹写入 `imp_racebox` / `lc_racebox`，AgentWong 的轨迹回放与
  最新位置查询可直接读取；围栏判定由服务端完成，设备端不参与。
- **坐标系**：库中保存 WGS84 原始值；微信/高德等地图展示层统一转 GCJ-02。

## 给 AI 助手

本仓库已为 AI 编码助手准备入口文档 [AGENTS.md](AGENTS.md)，包含硬件变体说明、
构建验证方式、配置/密钥规则及常见坑，请在改动前先阅读。

## License

[MIT](LICENSE) © 2025 wongcw
