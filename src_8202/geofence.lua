-- 设备侧地理围栏判定（v2）。
--
-- 为什么放在设备端：gpswong/<IMEI>/alarm 本来就是实时通道，围栏进出必须在
-- 事件发生当下发出去；等服务端轮询 1Hz 定位点再算，迟到 5 分钟就没有意义了。
-- 服务端（AgentWong）只负责把 gpswong.alarm.v1 归一化、去重、推送，不再重复判定。
--
-- 老通道零改动：本模块只在 GPSWONG_POINT 上订阅，产物走 GPSWONG_ALERT，
-- 不碰 gpswong/<IMEI>/data 的 80 字节二进制帧。

local cfg = require("config")
local geofence = {}

local opt = cfg.geofence or {}
local FENCES_KEY = opt.fences_key or "gpswong_fences"
local STATE_KEY = opt.state_key or "gpswong_fence_state"
local DEBOUNCE_N = math.max(1, math.floor(tonumber(opt.debounce_n) or 2))
local MAX_FENCES = 16
local EARTH_R_M = 6371008.8

local fences = {}
local state = {}

local function rad(deg) return deg * math.pi / 180 end

local function haversine_m(lat1, lng1, lat2, lng2)
    local dlat = rad(lat2 - lat1)
    local dlng = rad(lng2 - lng1)
    local a = math.sin(dlat / 2) ^ 2
        + math.cos(rad(lat1)) * math.cos(rad(lat2)) * math.sin(dlng / 2) ^ 2
    return EARTH_R_M * 2 * math.atan(math.sqrt(a), math.sqrt(1 - a))
end

-- 顶点同时兼容 {lat=,lng=} 和 {lat,lng} 两种写法，方便服务端下发。
local function vertex(p)
    if type(p) ~= "table" then return nil end
    local lat = tonumber(p.lat or p[1])
    local lng = tonumber(p.lng or p[2])
    if not lat or not lng then return nil end
    return lat, lng
end

-- 射线法：以 lng 为 x、lat 为 y。城市尺度下不投影，误差可忽略。
local function point_in_polygon(lat, lng, pts)
    if type(pts) ~= "table" or #pts < 3 then return false end
    local inside = false
    local j = #pts
    for i = 1, #pts do
        local xi, yi = vertex(pts[i])
        local xj, yj = vertex(pts[j])
        if xi and xj then
            if (yi > lat) ~= (yj > lat) then
                local dy = yj - yi
                if dy == 0 then dy = 1e-12 end
                if lng < (xj - xi) * (lat - yi) / dy + xi then
                    inside = not inside
                end
            end
        end
        j = i
    end
    return inside
end

local function contains(fence, lat, lng)
    local flat = tonumber(fence.lat)
    local flng = tonumber(fence.lng)
    if fence.shape == "polygon" or fence.shape_type == "polygon" then
        return point_in_polygon(lat, lng, fence.points or {})
    end
    if not flat or not flng then return false end
    local radius = tonumber(fence.radius_m) or 300
    return haversine_m(lat, lng, flat, flng) <= radius
end

local function save_state()
    -- 只在状态真正翻转时写 Flash，避免 1Hz 采集把 fskv 磨穿。
    pcall(fskv.set, STATE_KEY, state)
end

local function id_of(fence, index)
    return tostring(fence.id or fence.name or ("f" .. index))
end

local function load()
    fences, state = {}, {}
    local ok, stored = pcall(fskv.get, FENCES_KEY)
    local list
    if ok and type(stored) == "table" then
        list = stored
    else
        list = cfg.geofence and cfg.geofence.fences or nil
    end
    if type(list) == "table" then
        for i, f in ipairs(list) do
            if type(f) == "table" and i <= MAX_FENCES then
                fences[#fences + 1] = f
            end
        end
    end
    local ok2, saved = pcall(fskv.get, STATE_KEY)
    if ok2 and type(saved) == "table" then state = saved end
    log.info("geofence", "loaded", #fences, "fences", "debounce", DEBOUNCE_N)
end

local function emit(fence, kind, point)
    local in_fence = kind == "geofence_enter"
    -- 两个方向都是 warning：服务端 PUSH_PLUS 默认只推 warning 及以上，
    -- 标成 info 会被 min_severity 静默过滤，用户就收不到进出围栏提醒。
    sys.publish("GPSWONG_ALERT", {
        type = kind,
        severity = "warning",
        value = in_fence and 1 or 0,
        fence_id = id_of(fence, 0),
        fence_name = fence.name or "",
        lat = point.lat,
        lng = point.lng,
    })
    log.info("geofence", kind, fence.name or id_of(fence, 0))
end

-- 每个定位点跑一次。首次观测只记状态、不发事件，避免开机/重启误报；
-- 连续 DEBOUNCE_N 次同向判定才翻转，挡住边界 GPS 漂移反复横跳。
function geofence.check(point)
    if not point or point.source == "lbs" then return end
    local lat = tonumber(point.lat)
    local lng = tonumber(point.lng)
    if not lat or not lng or (lat == 0 and lng == 0) then return end
    for index, fence in ipairs(fences) do
        local id = id_of(fence, index)
        local inside = contains(fence, lat, lng)
        local s = state[id]
        if type(s) ~= "table" then s = { inside = nil, pending = nil, n = 0 } end
        if s.inside == nil then
            s.inside = inside
            state[id] = s
            save_state()
        elseif inside ~= s.inside then
            if s.pending == inside then
                s.n = (tonumber(s.n) or 0) + 1
            else
                s.pending, s.n = inside, 1
            end
            state[id] = s
            if s.n >= DEBOUNCE_N then
                s.inside, s.pending, s.n = inside, nil, 0
                save_state()
                if inside and fence.enter_alert ~= false then
                    emit(fence, "geofence_enter", point)
                elseif not inside and fence.exit_alert ~= false then
                    emit(fence, "geofence_exit", point)
                end
            end
        elseif s.pending ~= nil then
            -- 抖动回到原状态，计数清零，不落盘
            s.pending, s.n = nil, 0
            state[id] = s
        end
    end
end

-- 供 MQTT 下行 set_fences 调用：校验后写 fskv，并清空状态让新围栏重新建立基线。
function geofence.update(list)
    if type(list) ~= "table" then
        log.warn("geofence", "set_fences ignored: payload is not a list")
        return 0
    end
    local clean = {}
    for i, f in ipairs(list) do
        if type(f) == "table" and i <= MAX_FENCES then
            f.id = f.id or ("f" .. i)
            clean[#clean + 1] = f
        end
    end
    fences, state = clean, {}
    pcall(fskv.set, FENCES_KEY, fences)
    save_state()
    log.info("geofence", "set_fences applied", #fences)
    return #fences
end

function geofence.count() return #fences end

function geofence.start()
    pcall(fskv.init)
    local ok, err = pcall(load)
    if not ok then
        log.warn("geofence", "load failed; geofence disabled", err or "")
        fences, state = {}, {}
        return
    end
    if opt.enabled == false then
        log.info("geofence", "disabled by config")
        return
    end
    sys.subscribe("GPSWONG_POINT", function(point)
        local good, err2 = pcall(geofence.check, point)
        if not good then log.warn("geofence", "check failed", err2 or "") end
    end)
end

geofence.haversine_m = haversine_m
geofence.point_in_polygon = point_in_polygon
geofence.contains = contains
return geofence
