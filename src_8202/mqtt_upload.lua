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

local function publish_alert(event)
    if not client or not client:ready() then
        log.warn("alarm", "mqtt offline; realtime alert dropped", event.type or "unknown")
        return
    end
    event.device_id = cfg.device_id
    event.ts = os.time()
    event.schema = "gpswong.alarm.v1"
    local packet_id = client:publish(cfg.mqtt.alarm_topic, json.encode(event), 1)
    log.info("alarm", "publish", event.type or "unknown", packet_id or "rejected")
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
        client:on(function(_, event, data)
            log.info("mqtt", event, data or "")
            if event == "conack" then flush(true) end
            if event == "sent" and inflight[data] then
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
