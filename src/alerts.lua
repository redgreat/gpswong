-- 硬件预警（780EG）：电量滞回三档 + 充电翻转。
-- 围栏在 geofence.lua，GNSS 失锁在 gnss.lua，统一经 GPSWONG_ALERT 发出。
-- 判定一律「状态翻转才发 + 滞回」，避免临界点刷屏。
-- info 级别服务端默认不推送，需要提醒人的事件必须标 warning 或 critical。
local cfg = require("config")
local geofence = require("geofence")
local alerts = {}

local BAT_KEY = "gpswong_battery_state"
local bat_cfg = cfg.battery_alarm or {}
local bat_state = { level = nil, charging = nil }

local function publish(event) sys.publish("GPSWONG_ALERT", event) end

local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end

local function battery_percent(mv)
    -- 单节锂电池的保守线性近似，仅用于事件里的百分比展示。
    return math.floor(clamp((mv - 3300) * 100 / 900, 0, 100))
end

local function save_state() pcall(fskv.set, BAT_KEY, bat_state) end

local function read_vbat()
    local ok, mv = pcall(adc.get, adc.CH_VBAT)
    mv = ok and tonumber(mv) or nil
    return (mv and mv > 0) and mv or nil
end

local function read_charging()
    if bat_cfg.charging_events == false then return nil end
    if type(misc) ~= "table" or type(misc.getVbus) ~= "function" then return nil end
    local ok, vbus = pcall(misc.getVbus)
    if not ok then return nil end
    return vbus and true or false
end

local function sample_battery()
    local mv = read_vbat()
    if mv then
        local critical, low, recover = bat_cfg.critical_mv or 3400, bat_cfg.low_mv or 3600, bat_cfg.recover_mv or 3750
        local level = bat_state.level
        if mv < critical then
            level = "critical"
        elseif mv < low then
            if level ~= "critical" then level = "low" end
        elseif mv >= recover then
            level = "normal"
        elseif level == nil then
            level = "normal"
        end
        if level ~= bat_state.level then
            local previous = bat_state.level
            bat_state.level = level
            save_state()
            if previous ~= nil or level ~= "normal" then
                local types = {critical = "battery_critical", low = "battery_low", normal = "battery_recovered"}
                local severities = {critical = "critical", low = "warning", normal = "info"}
                publish({
                    type = types[level], severity = severities[level],
                    value = math.floor(mv), battery_percent = battery_percent(mv),
                })
                log.info("alerts", "battery", level, math.floor(mv), "mV")
            end
        end
    end

    local charging = read_charging()
    if charging ~= nil and charging ~= bat_state.charging then
        local previous = bat_state.charging
        bat_state.charging = charging
        save_state()
        if previous ~= nil then
            publish({
                type = charging and "charging_started" or "charging_stopped",
                severity = "info", value = charging and 1 or 0,
            })
        end
    end
end

function alerts.start()
    local ok, saved = pcall(fskv.get, BAT_KEY)
    if ok and type(saved) == "table" then bat_state = saved end

    geofence.start()

    if bat_cfg.enabled ~= false then
        local period = math.max(10, tonumber(bat_cfg.sample_sec) or 60)
        sys.timerLoopStart(function()
            local ok2, err = pcall(sample_battery)
            if not ok2 then log.warn("alerts", "battery sample failed", err or "") end
        end, period * 1000)
        sys.timerStart(function() pcall(sample_battery) end, 3000)
        log.info("alerts", "battery alarm enabled", period, "s")
    else
        log.info("alerts", "battery alarm disabled")
    end
end

return alerts
