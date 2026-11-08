-- GNSS 采样（1Hz）：只上传有效定位点，驱动运动判定与 GNSS 失锁预警。
-- GNSS 长时间无定位（地下车库等）时，用基站定位补一个大致点，标记 source="lbs"。
local cfg = require("config")
local motion = require("motion")
local lbs = require("lbs")
local gnss = { latest = nil }
local last_stationary_point_ms = -100000000
local last_fix_ms = mcu.ticks()
local last_lbs_ms = -100000000
local lost_alerted = false
local lbs_busy = false

local function snapshot()
    if not libgnss.isFix() then return nil end
    local rmc = libgnss.getRmc(2)
    local gga = libgnss.getGga(2) or {}
    local gsa_all = libgnss.getGsa() or {}
    if not rmc or not rmc.valid or not rmc.lat or not rmc.lng then return nil end

    local gsa = gsa_all[1] or gsa_all
    local speed_knots = rmc.speed or 0
    motion.update(speed_knots * 1.852)
    return {
        -- iTOW 在此实时点协议中只用于同秒排序；UTC 毫秒可稳定满足该用途。
        itow = ((rmc.hour or 0) * 3600 + (rmc.min or 0) * 60 + (rmc.sec or 0)) * 1000,
        year = rmc.year, month = rmc.month, day = rmc.day,
        hour = rmc.hour, min = rmc.min, sec = rmc.sec,
        -- geofence.lua 直接订阅 GPSWONG_POINT，要求 lat/lng 一定是数值。
        lat = tonumber(rmc.lat), lng = tonumber(rmc.lng),
        speed_knots = speed_knots,
        course = rmc.course or 0,
        altitude = gga.altitude or 0,
        hdop = gga.hdop or 0,
        pdop = gsa.pdop or 0,
        satellites = gga.satellites_tracked or 0,
        fix_type = (gsa.fix_type and gsa.fix_type >= 2) and gsa.fix_type or 3,
        source = "gnss",
    }
end

local function init_chip()
    for _, cmd in ipairs(cfg.gnss.init_cmds or {}) do
        uart.write(cfg.gnss.uart_id, cmd)
        sys.wait(20)
    end
end

-- 基站回落点：速度和航向置 0，fix_type=0 表示非 GNSS 定位。时间取 NTP 校准后的 UTC。
local function lbs_fix(moving)
    lbs_busy = true
    local lat, lng = lbs.locate()
    lbs_busy = false
    if not lat then return end
    local utc = os.date("!*t", os.time())
    if utc.year < 2020 then return end
    if not moving then last_stationary_point_ms = mcu.ticks() end
    log.info("gnss", "lbs point", lat, lng, moving and "moving" or "stationary")
    sys.publish("GPSWONG_POINT", {
        itow = (utc.hour * 3600 + utc.min * 60 + utc.sec) * 1000,
        year = utc.year, month = utc.month, day = utc.day,
        hour = utc.hour, min = utc.min, sec = utc.sec,
        lat = lat, lng = lng,
        speed_knots = 0, course = 0, altitude = 0, hdop = 0, pdop = 0,
        satellites = 0, fix_type = 0,
        source = "lbs", moving = moving,
    })
end

function gnss.start()
    pm.power(pm.GPS, true)
    libgnss.clear()
    uart.setup(cfg.gnss.uart_id, cfg.gnss.baudrate)
    if cfg.gnss.uart_forward then
        uart.setup(cfg.gnss.uart_forward, cfg.gnss.baudrate)
        libgnss.bind(cfg.gnss.uart_id, cfg.gnss.uart_forward)
    else
        libgnss.bind(cfg.gnss.uart_id)
    end
    sys.taskInit(init_chip)

    sys.subscribe("GNSS_STATE", function(event)
        local on = event == "FIXED"
        if cfg.board.status_led_pin then
            gpio.set(cfg.board.status_led_pin,
                on and cfg.board.status_led_active or (1 - cfg.board.status_led_active))
        end
        if on then gnss.latest = snapshot() end
        log.info("gnss", event, gnss.latest and json.encode(gnss.latest) or "no-fix")
    end)

    sys.timerLoopStart(function()
        local now = mcu.ticks()
        local point = snapshot()
        if not point then
            if not lost_alerted and cfg.gnss.lost_fix_alarm_sec > 0
                and now - last_fix_ms >= cfg.gnss.lost_fix_alarm_sec * 1000 then
                lost_alerted = true
                sys.publish("GPSWONG_ALERT", {type = "gnss_lost", severity = "warning",
                    value = math.floor((now - last_fix_ms) / 1000)})
            end
            local moving = motion.is_moving()
            if cfg.lbs.enabled and not lbs_busy
                and now - last_fix_ms >= cfg.lbs.after_no_fix_sec * 1000
                and now - last_lbs_ms >= cfg.lbs.interval_sec * 1000
                and (moving or now - last_stationary_point_ms >= cfg.motion.stationary_heartbeat_sec * 1000) then
                last_lbs_ms = now
                sys.taskInit(function() lbs_fix(moving) end)
            end
            return
        end
        last_fix_ms = now
        if lost_alerted then
            lost_alerted = false
            sys.publish("GPSWONG_ALERT", {type = "gnss_recovered", severity = "info", value = 1})
        end
        local moving = motion.is_moving()
        if not moving and now - last_stationary_point_ms < cfg.motion.stationary_heartbeat_sec * 1000 then
            return
        end
        point.moving = moving
        gnss.latest = point
        sys.publish("GPSWONG_POINT", point)
        if not moving then last_stationary_point_ms = now end
    end, cfg.gnss.sample_interval_sec * 1000)
end

return gnss
