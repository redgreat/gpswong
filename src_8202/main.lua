PROJECT = "gpswong_8202"
VERSION = "0.3.1"

_G.sys = require("sys")
require("sysplus")

local cfg = require("config")
log.info("main", PROJECT, VERSION, rtos.bsp(), hmeta and hmeta.model() or "")

-- Air8202 出厂固件默认使用 SIM2（贴片卡），通用 Air780EGG CORE 则不会。
-- 必须在 MQTT 等联网任务启动前切卡，否则界面会显示“SIM卡未插入”。
local sim_ok, sim_err = pcall(mobile.simid, cfg.sim.slot)
log.info("main", "select embedded SIM slot", cfg.sim.slot, sim_ok, sim_err or "")

-- 绿灯 GPIO26：先点亮作为脚本成功启动标志，后续由 GNSS 状态接管。
gpio.setup(cfg.board.status_led_pin, cfg.board.status_led_active)
adc.open(adc.CH_VBAT)

-- 内部看门狗防 Lua 任务死锁；Air8202 板载 Air153C 则优先交给官方扩展库。
if wdt then
    wdt.init(9000)
    sys.timerLoopStart(wdt.feed, 5000)
end
local ok, external_wdt = pcall(require, "exair153x_wdt")
if ok and external_wdt then
    external_wdt.init({
        wdt_pin = cfg.board.hardware_wdt_pin,
        auto_feed_period_s = cfg.board.hardware_wdt_feed_sec,
    })
else
    log.warn("main", "exair153x_wdt unavailable; external watchdog is not managed")
end

require("mqtt_upload").start()
require("motion").start()
require("alerts").start()
require("gnss").start()
sys.run()
