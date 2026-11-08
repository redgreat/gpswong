-- 统一告警模块（v2）：围栏 / 电量 / 光敏 三类事件从这里发出。
--
-- 所有事件统一 sys.publish("GPSWONG_ALERT", {type, severity, value, ...})，
-- mqtt_upload.publish_alert 会补 device_id / ts / schema 后发到 alarm topic。
-- 判定一律「状态翻转才发 + 滞回」，避免临界点刷屏把 PUSH_PLUS 打爆。
--
-- 严重级别与服务端约定：info 只记录不推送，warning / critical 才会进 PUSH_PLUS
-- （admin 后台 min_severity 默认 warning）。真正要提醒人的事件别标 info。

local cfg = require("config")
local geofence = require("geofence")
local alerts = {}

local BAT_KEY = "gpswong_battery_state"
local LIGHT_KEY = "gpswong_light_adc_state"

local light_cfg = cfg.light_alarm or {}
local bat_cfg = cfg.battery_alarm or {}

local last_level
local bat_state = { level = nil, charging = nil }
local adc_state = { exposed = nil }

local function publish(event)
    sys.publish("GPSWONG_ALERT", event)
end

-- ---------- 光敏 / 拆机（数字 GPIO，沿用原有行为） ----------

local function emit_light()
    local ok, level = pcall(gpio.get, light_cfg.pin)
    if not ok or level == last_level then return end
    last_level = level
    local tampered = level == light_cfg.tamper_level
    publish({
        type = tampered and "tamper_open" or "tamper_clear",
        severity = tampered and "critical" or "info",
        value = level,
    })
end

-- ---------- 电量 ----------

local function read_vbat()
    local ok, mv = pcall(adc.get, adc.CH_VBAT)
    if not ok then return nil end
    mv = tonumber(mv)
    if not mv or mv <= 0 then return nil end
    return mv
end

local function read_charging()
    if bat_cfg.charging_events == false then return nil end
    if type(misc) ~= "table" or type(misc.getVbus) ~= "function" then return nil end
    local ok, vbus = pcall(misc.getVbus)
    if not ok then return nil end
    return vbus and true or false
end

local function save_bat()
    pcall(fskv.set, BAT_KEY, bat_state)
end

local function battery_percent(mv)
    return math.max(0, math.min(100, math.floor((mv - 3300) * 100 / 900)))
end

local function sample_battery()
    local mv = read_vbat()
    if mv then
        local critical = tonumber(bat_cfg.critical_mv) or 3400
        local low = tonumber(bat_cfg.low_mv) or 3600
        local recover = tonumber(bat_cfg.recover_mv) or 3750
        local level = bat_state.level
        -- 滞回：低于 low/critical 才降档，必须回到 recover 以上才升回 normal，
        -- 中间带保持原档位，电压在阈值附近抖动时不会产生事件。
        if mv < critical then
            level = "critical"
        elseif mv < low then
            if level ~= "critical" then level = "low" end
        elseif mv >= recover then
            level = "normal"
        elseif level == nil then
            level = mv < low and "low" or "normal"
        end
        if level ~= bat_state.level then
            local previous = bat_state.level
            bat_state.level = level
            save_bat()
            if previous ~= nil or level ~= "normal" then
                local types = {
                    critical = "battery_critical",
                    low = "battery_low",
                    normal = "battery_recovered",
                }
                local severities = {
                    critical = "critical", low = "warning", normal = "info",
                }
                publish({
                    type = types[level],
                    severity = severities[level],
                    value = math.floor(mv),
                    battery_percent = battery_percent(mv),
                })
                log.info("alerts", "battery", level, math.floor(mv), "mV")
            end
        end
    end

    local charging = read_charging()
    if charging ~= nil and charging ~= bat_state.charging then
        local previous = bat_state.charging
        bat_state.charging = charging
        save_bat()
        if previous ~= nil then
            publish({
                type = charging and "charging_started" or "charging_stopped",
                severity = "info",
                value = charging and 1 or 0,
            })
        end
    end
end

-- ---------- 光敏（ADC 模拟量，默认关闭） ----------
--
-- Air8202C 没焊光敏电阻，必须外接 GM5528 + 10K 分压到 ADC3 才能用。
-- 这里比较的是 ADC 电压（mV），不是真实照度；阈值需按实际接线标定，
-- 所以配置项叫 adc_threshold_mv 而不是 lux，避免误读。

local function sample_light_adc()
    local id = tonumber(light_cfg.adc_id) or 3
    local ok, mv = pcall(adc.get, id)
    if not ok then return end
    mv = tonumber(mv)
    if not mv then return end
    local threshold = tonumber(light_cfg.adc_threshold_mv) or 1500
    local hysteresis = math.abs(tonumber(light_cfg.hysteresis_mv) or 150)
    local exposed = adc_state.exposed
    if exposed == nil then
        exposed = mv >= threshold
    elseif exposed and mv < threshold - hysteresis then
        exposed = false
    elseif not exposed and mv > threshold + hysteresis then
        exposed = true
    end
    if exposed ~= adc_state.exposed then
        local previous = adc_state.exposed
        adc_state.exposed = exposed
        pcall(fskv.set, LIGHT_KEY, adc_state)
        if previous ~= nil then
            publish({
                type = exposed and "light_exposed" or "light_dark",
                severity = exposed and "warning" or "info",
                value = math.floor(mv),
                adc_id = id,
                threshold_mv = threshold,
            })
            log.info("alerts", "light adc", exposed and "exposed" or "dark", math.floor(mv), "mV")
        end
    end
end

function alerts.start()
    -- state 先恢复，重启后不重复报上一次的低电/见光状态。
    local ok_b, saved_b = pcall(fskv.get, BAT_KEY)
    if ok_b and type(saved_b) == "table" then bat_state = saved_b end
    local ok_l, saved_l = pcall(fskv.get, LIGHT_KEY)
    if ok_l and type(saved_l) == "table" then adc_state = saved_l end

    -- 围栏：设备侧判定，服务端只做归一化与去重。
    geofence.start()

    -- 电量：默认开，60 秒一次；只写 Flash 状态不写轨迹。
    if bat_cfg.enabled ~= false then
        local period = math.max(10, tonumber(bat_cfg.sample_sec) or 60)
        sys.timerLoopStart(function()
            local ok, err = pcall(sample_battery)
            if not ok then log.warn("alerts", "battery sample failed", err or "") end
        end, period * 1000)
        sys.timerStart(function() pcall(sample_battery) end, 3000)
        log.info("alerts", "battery alarm enabled", period, "s")
    else
        log.info("alerts", "battery alarm disabled")
    end

    -- 数字 GPIO 拆机检测：仅 Air8202G 打开。
    if light_cfg.enabled then
        gpio.debounce(light_cfg.pin, tonumber(light_cfg.debounce_ms) or 500)
        gpio.setup(light_cfg.pin, function() sys.taskInit(emit_light) end, gpio.PULLUP)
        sys.timerStart(emit_light, 1000)
        log.info("alerts", "GPIO light tamper enabled", light_cfg.pin)
    else
        log.info("alerts", "GPIO light tamper disabled")
    end

    -- ADC 光敏：需要外接光敏电阻，默认关闭。adc.open 由 main.lua 统一做。
    if light_cfg.adc_enabled then
        local period = math.max(2, tonumber(light_cfg.adc_sample_sec) or 10)
        sys.timerLoopStart(function()
            local ok, err = pcall(sample_light_adc)
            if not ok then log.warn("alerts", "light adc sample failed", err or "") end
        end, period * 1000)
        log.info("alerts", "ADC light alarm enabled", "adc", light_cfg.adc_id or 3, period, "s")
    end
end

return alerts
