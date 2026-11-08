-- LuaTools需要PROJECT和VERSION这两个信息
PROJECT = "gpswong_780eg"
VERSION = "0.4.0"

_G.sys = require("sys")
require("sysplus")

local cfg = require("config")
log.info("main", PROJECT, VERSION, rtos.bsp(), hmeta and hmeta.model() or "")

fskv.init()
if cfg.board.adc_range_3_8 and adc.setRange then adc.setRange(adc.ADC_RANGE_3_8) end
adc.open(adc.CH_VBAT)

if cfg.board.status_led_pin then
    gpio.setup(cfg.board.status_led_pin, cfg.board.status_led_active)
end

if wdt then
    wdt.init(cfg.board.wdt_init_sec * 1000)
    sys.timerLoopStart(wdt.feed, cfg.board.wdt_feed_sec * 1000)
end

require("mqtt_upload").start()
require("alerts").start()
require("gnss").start()
sys.run()
