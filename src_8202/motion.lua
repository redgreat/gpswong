local cfg = require("config")
local motion = { ready = false, last_motion_ms = 0, boot_ms = mcu.ticks() }
local sensor
local last_alarm_ms = -1000000

local function on_interrupt()
    if gpio.get(cfg.motion.interrupt_pin) ~= 1 then return end
    local now = mcu.ticks()
    motion.last_motion_ms = now
    sys.publish("GPSWONG_MOTION")
    if now - last_alarm_ms >= cfg.motion.alarm_min_interval_sec * 1000 then
        last_alarm_ms = now
        sys.publish("GPSWONG_ALERT", {type="vibration", severity="info", value=1})
    end
end

function motion.start()
    if not cfg.motion.enabled then return end
    local ok, lib = pcall(require, "exvib")
    if not ok or not lib then
        log.error("motion", "exvib unavailable; check 'add default lib' in LuaTools")
        return
    end
    sensor = lib
    sensor.open(cfg.motion.mode)
    gpio.debounce(cfg.motion.interrupt_pin, 100)
    gpio.setup(cfg.motion.interrupt_pin, on_interrupt)
    -- exvib.open() 内部异步完成 GPIO23、I2C1 和 DA221 寄存器初始化。
    sys.timerStart(function()
        motion.ready = true
        log.info("motion", "DA221 ready", sensor.version and sensor.version() or "")
    end, 1000)
end

function motion.is_moving()
    if not cfg.motion.only_when_moving then return true end
    local now = mcu.ticks()
    if now - motion.boot_ms < cfg.motion.boot_active_sec * 1000 then return true end
    return now - motion.last_motion_ms < cfg.motion.moving_hold_sec * 1000
end

function motion.read()
    if not motion.ready or not sensor then return 0, 0, 0 end
    local ok, x, y, z = pcall(sensor.read_xyz)
    if not ok or type(x) ~= "number" then
        log.warn("motion", "read_xyz failed", x or "")
        return 0, 0, 0
    end
    return x, y, z -- 单位 g；静止放置时某一轴约为 +/-1g
end

return motion
