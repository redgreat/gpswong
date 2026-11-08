local cfg = require("config")
local motion = require("motion")
local gnss = { latest = nil }
local last_stationary_point_ms = -100000000

local function snapshot()
    if not libgnss.isFix() then return nil end
    local rmc = libgnss.getRmc(2)
    local gga = libgnss.getGga(2) or {}
    local gsa_all = libgnss.getGsa() or {}
    if not rmc or not rmc.valid or not rmc.lat or not rmc.lng then return nil end

    local gsa = gsa_all[1] or gsa_all
    local gx, gy, gz = motion.read()
    return {
        -- iTOW 在此实时点协议中只用于同秒排序；UTC 毫秒可稳定满足该用途。
        itow = ((rmc.hour or 0) * 3600 + (rmc.min or 0) * 60 + (rmc.sec or 0)) * 1000,
        year = rmc.year, month = rmc.month, day = rmc.day,
        hour = rmc.hour, min = rmc.min, sec = rmc.sec,
        -- geofence.lua 直接订阅 GPSWONG_POINT，要求 lat/lng 一定是数值；
        -- 个别固件版本 libgnss 会返回字符串，这里统一转成 number。
        lat = tonumber(rmc.lat), lng = tonumber(rmc.lng),
        speed_knots = rmc.speed or 0,
        course = rmc.course or 0,
        altitude = gga.altitude or 0,
        hdop = gga.hdop or 0,
        pdop = gsa.pdop or 0,
        satellites = gga.satellites_tracked or 0,
        fix_type = (gsa.fix_type and gsa.fix_type >= 2) and gsa.fix_type or 3,
        gforce_x = gx, gforce_y = gy, gforce_z = gz,
    }
end

function gnss.start()
    pm.power(pm.GPS, true)
    libgnss.clear()
    uart.setup(cfg.gnss.uart_id, cfg.gnss.baudrate)
    libgnss.bind(cfg.gnss.uart_id)

    sys.subscribe("GNSS_STATE", function(event)
        local on = event == "FIXED"
        gpio.set(cfg.board.status_led_pin,
            on and cfg.board.status_led_active or (1 - cfg.board.status_led_active))
        if event == "FIXED" then gnss.latest = snapshot() end
        log.info("gnss", event, gnss.latest and json.encode(gnss.latest) or "no-fix")
    end)

    sys.timerLoopStart(function()
        local moving = motion.is_moving()
        local now = mcu.ticks()
        if not moving and now - last_stationary_point_ms < cfg.motion.stationary_heartbeat_sec * 1000 then
            return
        end
        local point = snapshot()
        if point then
            point.moving = moving
            gnss.latest = point
            sys.publish("GPSWONG_POINT", point)
            if not moving then last_stationary_point_ms = now end
        elseif not cfg.gnss.require_fix then
            log.warn("gnss", "no fix; invalid points are not persisted")
        end
    end, cfg.gnss.sample_interval_sec * 1000)

    -- 震动中断只更新 motion 状态；最多 1 秒后由固定 1Hz 定时器采集，避免同秒重复点。
end

return gnss
