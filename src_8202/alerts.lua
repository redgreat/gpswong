local cfg = require("config")
local alerts = {}
local last_level

local function emit_light()
    local level = gpio.get(cfg.light_alarm.pin)
    if level == last_level then return end
    last_level = level
    local tampered = level == cfg.light_alarm.tamper_level
    sys.publish("GPSWONG_ALERT", {
        type = tampered and "tamper_open" or "tamper_clear",
        severity = tampered and "critical" or "info",
        value = level,
    })
end

function alerts.start()
    if not cfg.light_alarm.enabled then
        log.info("alerts", "light tamper disabled")
        return
    end
    gpio.debounce(cfg.light_alarm.pin, cfg.light_alarm.debounce_ms)
    gpio.setup(cfg.light_alarm.pin, function() sys.taskInit(emit_light) end, gpio.PULLUP)
    sys.timerStart(emit_light, 1000)
    log.info("alerts", "Air8202G light tamper enabled", cfg.light_alarm.pin)
end

return alerts
