local cfg = require("config")
local mygnss = require("myGNSS")

local mqttc = nil
fskv.init()

adc.setRange(adc.ADC_RANGE_3_8) --air780E开启ADC0,1分压电阻，范围0~3.8V
adc.open(adc.CH_VBAT)
adc.open(adc.CH_CPU)
log.info("CH_VBAT=", adc.CH_VBAT, "CH_CPU=", adc.get(adc.CH_CPU))


-- 系统似乎没有现成的合并两个dict的函数，自己实现一个
local function mergeTables(...)
    local result = {}
    for _, tbl in ipairs{...} do
        for k, v in pairs(tbl) do
            if type(v) == "string" then
                result[k] = v:gsub("[\x00-\x1F\x7F-\xFF]", "") -- 过滤非打印字符
            else
                result[k] = v
            end
        end
    end
    return result
end
--系统不带深拷贝，自己实现一个深拷贝
local function deepCopy(orig)
    local copy = {}
    for k, v in pairs(orig) do
        if type(v) == "table" then
            v = deepCopy(v)
        end
        copy[k] = v
    end
    return copy
end

function upload_stat(up_cfg)
    -- 关掉省电模式，好能够使用GPS等
    pm.power(pm.WORK_MODE, 0)
    pm.power(pm.GPS, true)
    local status={
        csq = mobile.csq(),
        imei = cfg.imei,
        ip=socket.localIP(),
        vbat = adc.get(adc.CH_VBAT),
    }
    log.info("device status=",json.encode(status))

    mygnss.refresh()
    --sys.waitUntil("CELL_INFO_UPDATE")
    sys.waitUntil("GNSS_STATE",3000)
    local res = mygnss.res
    -- 最后的拼接，只保留三个字段并实现 fallback 逻辑
    local gnss_info = {
        lat = (res.lat and res.lat ~= 0) and res.lat or res.agps_lat,
        lng = (res.lng and res.lng ~= 0) and res.lng or res.agps_lng,
        gps_ts = (res.lat and res.lat ~= 0) and res.gps_ts or res.agps_ts,
    }
    log.info("gnss info=",json.encode(gnss_info))

    stat=mergeTables(status,gnss_info)
    stat.uptime=fskv.get("uptime")
    stat.up_vbat=fskv.get("up_vbat")
    if up_cfg then
        stat.cfg=cfg
    else
        stat.cfg=nil
    end
    log.info("stat", json.encode(stat))
    if mqttc and mqttc:ready() then
        local payload = json.encode(stat)
        mqttc:publish(cfg.mqtt.pub_topic, payload, 1)
    end
    if cfg.power_mode==0 then
        log.info("正常耗电模式")
    elseif cfg.power_mode==1 then
        log.info("省电模式")  --省电模式下，流量还没关，还能上网
        pm.power(pm.GPS, false)
        pm.power(pm.WORK_MODE, 1)
    else
        log.info("极省电模式，目前还不支持")
        pm.power(pm.GPS, false)
        pm.power(pm.WORK_MODE, 1)  --极度省电模式下，pm.power(pm.WORK_MODE, 2)，系统进入睡眠，等到下次唤醒时，才能继续运行，实现模式要另外处理
    end
end

sys.taskInit(function()
    sys.waitUntil("IP_READY", 15000)
    sys.waitUntil("NTP_UPDATE", 1000)
    fskv.set("uptime", os.time()) --记录下上次启动的时间
    fskv.set("up_vbat", adc.get(adc.CH_VBAT))  --记录下上次启动的电压
    mqttc = mqtt.create(nil, cfg.mqtt.broker, cfg.mqtt.port, true)
    mqttc:auth(mobile.imei(), cfg.mqtt.user, cfg.mqtt.passwd)
    log.info("mqtt", mobile.imei(), mobile.imei(), mobile.muid())
    mqttc:keepalive(30) -- 默认值240s
    mqttc:autoreconn(true, cfg.mqtt.autoreconn_interval*1000) -- 自动重连机制
    mqttc:on(function(mqtt_client, event, data, payload) -- mqtt回调注册
        --[[
            event可能出现的值有
              conack -- 服务器鉴权完成,mqtt连接已经建立, 可以订阅和发布数据了,没有附加数据
              recv   -- 接收到数据,由服务器下发, data为topic值(string), payload为业务数据(string).metas是元数据(table), 一般不处理.
                         -- metas包含以下内容
                         -- qos 取值范围0,1,2
                         -- retain 取值范围 0,1
                         -- dup 取值范围 0,1
              sent   -- 发送完成, qos0会马上通知, qos1/qos2会在服务器应答会回调, data为消息id
              disconnect -- 服务器断开连接,网络问题或服务器踢了客户端,例如clientId重复,超时未上报业务数据
              pong   -- 收到服务器心跳应答,没有附加数据
            ]]
        -- 用户自定义代码，按event处理
        if event == "conack" then
            sys.publish("mqtt_conack") -- 小写字母的topic均为sys自定义topic
            mqtt_client:subscribe(cfg.mqtt.sub_topic)
        elseif event == "sent" then -- publish成功后的事件
            log.info("mqtt", "sent", "pkgid", data)
        end
    end)
    mqttc:connect()
    sys.waitUntil("mqtt_conack")
    log.info("mqtt连接成功")
    --[[
        sys.waitUntil 是一个协程阻塞函数，只能在 sys.taskInit 创建的协程或事件回调中使用。
        upload_stat 函数被 sys.timerLoopStart 直接调用，而定时器回调默认不在协程环境中运行，导致非法调用阻塞函数。
        将 upload_stat 包装为协程就可以了
    ]]
    upload_stat()
    sys.timerLoopStart(function()  sys.taskInit(upload_stat) end, cfg.mqtt.update_interval*1000)
    while true do
        sys.wait(60*1000)
    end
    mqttc:close()
    mqttc = nil
end)

