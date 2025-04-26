-- LuaTools需要PROJECT和VERSION这两个信息
PROJECT = "GpsWong"
VERSION = "1.0.0"

_G.sys = require("sys")
_G.sysplus = require("sysplus")
require"projectConfig"

-- 电量检测
require "vbat_adc"

-- MQTT 和 LBS
local mqtt   = require("mqtt")
local lbsLoc = require("lbsLoc")
local json   = require("json")

-- 常量
local MQTT_HOST     = _G.mqtt_mqttHostUrl
local MQTT_PORT     = _G.mqtt_port
local MQTT_CLIENTID = _G.mqtt_mqttClientId
local MQTT_USER     = _G.mqtt_username
local MQTT_PASS     = _G.mqtt_passwd
local MQTT_TOPIC    = _G.mqtt_pub_topic

local cycletime  = 1000        -- ms
local gpsrestart = 300         -- s
local lbstime    = 1800        -- s

sys.taskInit(function()
    -- 等待网络就绪
    sys.waitUntil("IP_READY")
    sys.wait(1000)

    -- 连接 MQTT
    local mqttc = mqtt.create(nil, MQTT_HOST, MQTT_PORT, false)
    mqttc:auth(MQTT_CLIENTID, MQTT_USER, MQTT_PASS, true)
    mqttc:keepalive(60)
    mqttc:autoreconn(true, 6000)
    mqttc:on(function(client, event)
        if event == "conack" then sys.publish("MQTT_READY") end
    end)
    mqttc:connect()
    sys.waitUntil("MQTT_READY")

    -- 上电并绑定 GNSS
    if pm and pm.power then pm.power(pm.GPS, true) end
    libgnss.bind(_G.uartid or 1, uart.VUART_0)
    sys.wait(200)

    -- 初始等待 AGNSS
    sys.wait(15000)

    local gpscount = 0
    local lastlbs  = os.time()

    while true do
        local d = {
            timestamp = os.time(),
            csq       = mobile.csq(),
            volt      = (_G.vbat or 0) / 1000,
            acc       = 0
        }

        -- GNSS
        if libgnss.isFix() then
            local tg = libgnss.getRmc(2)
            d.gps = {
                lat = tg.lat,
                lng = tg.lng,
                spd = tg.speed,
                dir = tg.variation
            }
            gpscount = 0
        else
            gpscount = gpscount + 1
            if gpscount > gpsrestart then sys.reboot() end
        end

        -- LBS 回落
        if not d.gps and os.time() >= lastlbs + lbstime then
            local done, lat, lng = false
            lbsLoc.request(function(res, _lat, _lng)
                if res == 0 then lat, lng = _lat, _lng end
                done = true
            end)
            for _ = 1,50 do if done then break end; sys.wait(100) end
            if lat and lng then
                d.lbs = { lat = lat, lng = lng }
                lastlbs = os.time()
            end
        end

        -- 发布
        mqttc:publish(MQTT_TOPIC, json.encode(d), 0)

        sys.wait(cycletime)
    end
end)

-- 用户代码已结束---------------------------------------------
-- 结尾总是这一句
sys.run()
-- sys.run()之后后面不要加任何语句!!!!!
