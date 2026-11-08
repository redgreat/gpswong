local cfg = require("config")
local protocol = require("protocol")
local spool = require("spool")
local uploader = {}
local client
local flushing = false
local oldest_pending_ms
local inflight = {}

local function flush(force)
    local pending = spool.count()
    if flushing or next(inflight) or pending == 0 or not client or not client:ready() then return end
    local old_enough = oldest_pending_ms and
        (mcu.ticks() - oldest_pending_ms) >= cfg.upload.max_wait_sec * 1000
    if not force and pending < cfg.upload.batch_points and not old_enough then return end
    flushing = true
    local batch = spool.peek(cfg.upload.batch_points)
    if #batch > 0 then
        local records = {}
        local vbat = adc.get(adc.CH_VBAT)
        for i, compact in ipairs(batch) do
            records[i] = protocol.spool_to_record(compact, vbat)
        end
        local payload, name = protocol.encode_records(records, cfg.device_id)
        local packet_id = client:publish(cfg.mqtt.topic, payload, 1)
        if packet_id then
            inflight[packet_id] = #batch
            log.info("mqtt", "publish batch", name, "points", #batch,
                "bytes", #payload, "packet", packet_id)
        else
            log.warn("mqtt", "publish rejected; keep batch", name)
        end
    end
    flushing = false
end

local function enqueue(point)
    local was_empty = spool.count() == 0
    spool.push(protocol.encode_spool(point))
    if was_empty then oldest_pending_ms = mcu.ticks() end
    flush(false)
end

local alert_seq = 0

local function publish_alert(event)
    if not client or not client:ready() then
        log.warn("alarm", "mqtt offline; realtime alert dropped", event.type or "unknown")
        return
    end
    alert_seq = alert_seq + 1
    event.device_id = cfg.device_id
    event.ts = os.time()
    -- seq / ticks 让同一秒内的多条事件在服务端可区分；当前服务端 dedup_key
    -- 仍用 ts，未来若出现「同时进出多个围栏」的碰撞，可直接把 seq 拼进 dedup。
    event.seq = alert_seq
    event.ticks = mcu.ticks()
    event.schema = "gpswong.alarm.v1"
    local packet_id = client:publish(cfg.mqtt.alarm_topic, json.encode(event), 1)
    log.info("alarm", "publish", event.type or "unknown", packet_id or "rejected")
end

-- 下行配置：围栏与阈值远程下发，避免每次调整围栏都要重新烧录。
-- 任何异常都只记日志，绝不让 MQTT 事件回调退出。
local function handle_cmd(payload)
    if type(payload) ~= "string" or #payload == 0 then
        log.warn("cmd", "empty payload")
        return
    end
    local ok, msg = pcall(json.decode, payload)
    if not ok or type(msg) ~= "table" then
        log.warn("cmd", "invalid json")
        return
    end
    if msg.cmd == "set_fences" then
        local applied, count = pcall(function()
            return require("geofence").update(msg.fences)
        end)
        if applied then
            log.info("cmd", "set_fences applied", count or 0)
        else
            log.warn("cmd", "set_fences failed", count or "")
        end
    elseif msg.cmd == "set_rules" then
        -- 规则只落盘，重启后生效；运行中的阈值不热更新，避免与采集定时器互相踩。
        pcall(fskv.set, "gpswong_rules", msg)
        log.info("cmd", "set_rules saved; effective after reboot")
    else
        log.warn("cmd", "unknown command", tostring(msg.cmd))
    end
end

function uploader.start()
    spool.init()
    if spool.count() > 0 then oldest_pending_ms = mcu.ticks() end
    sys.taskInit(function()
        if not sys.waitUntil("IP_READY", 120000) then log.error("mqtt", "IP_READY timeout") end
        socket.sntp()
        sys.waitUntil("NTP_UPDATE", 15000)
        client = mqtt.create(nil, cfg.mqtt.host, cfg.mqtt.port, cfg.mqtt.tls)
        client:auth(cfg.mqtt.client_id, cfg.mqtt.username, cfg.mqtt.password)
        client:keepalive(cfg.mqtt.keepalive_sec)
        client:autoreconn(true, cfg.mqtt.reconnect_sec * 1000)
        -- recv 回调的第 4 个参数才是报文体：data=topic, payload=body。
        client:on(function(_, event, data, payload)
            log.info("mqtt", event, data or "")
            if event == "conack" then
                if cfg.mqtt.cmd_topic then
                    local ok, err = pcall(function()
                        client:subscribe({[cfg.mqtt.cmd_topic] = 1})
                    end)
                    if ok then log.info("mqtt", "subscribed cmd", cfg.mqtt.cmd_topic)
                    else log.warn("mqtt", "subscribe cmd failed", err or "") end
                end
                flush(true)
            elseif event == "recv" then
                local ok, err = pcall(handle_cmd, payload)
                if not ok then log.warn("mqtt", "cmd handler failed", err or "") end
            elseif event == "sent" and inflight[data] then
                spool.ack(inflight[data])
                inflight[data] = nil
                oldest_pending_ms = spool.count() > 0 and mcu.ticks() or nil
                flush(true)
            elseif event == "disconnect" then
                -- Broker 未确认的记录仍在 Flash，重连后重发。
                inflight = {}
            end
        end)
        client:connect()
    end)
    sys.subscribe("GPSWONG_POINT", enqueue)
    sys.subscribe("GPSWONG_ALERT", publish_alert)
    sys.timerLoopStart(function() flush(false) end, 1000)
end

return uploader
