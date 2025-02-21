-------------------------------------- 项目全局配置文件--------------------------------------

-- ③自建服务器(cloudwong)： 12个参数--必配--自行在自建服务器处理
_G.SRCCID = mobile.imei()
_G.mqtt_mqttClientId = mobile.imei()
_G.mqtt_username = "admin"
_G.mqtt_passwd = "123456"
_G.mqtt_mqttHostUrl = "127.0.0.1"
_G.mqtt_port = 1883
_G.mqtt_pub_topic = "Pub/780eg/" .. mobile.imei() .. "/data"
_G.mqtt_sub_topic = "Sub/780eg/" .. mobile.imei() .. "/cmd"

------------------------------以上必配，到此结束--------------------------------------

-- 程序版本号--选配
-- _G.version = "1.0.0"

--GPS模组工作模式--选配
--_G.PositioningMode="$PCAS04,1*18\r\n"      --单GPS定位
--_G.PositioningMode="$PCAS04,2*1B\r\n"      --单北斗定位
_G.PositioningMode="$PCAS04,3*1A\r\n"      --GPS+北斗双模定位 

-- 日志开启状态，默认关闭
_G.logFlag = false;

-- 设备运行模式 ，默认正常： 正常awake_normal  深度休眠restdeep_deviceupdate  主动查询restdeep_platequery
_G.devicemodel = "";

-- 扩展命令 用于回复指令 platformquery
_G.cmd_ext = "";

-- 数据上报周期--默认的15S上报:15*1000ms
_G.update_time = 15*1000

-- 深度休眠唤醒周期 10分钟
_G.deeprest_time = 10*60*1000

-- 消息传输模板
_G.REPORT_DATA_TEMPLATE = "{\"reporttime\":\"\", \"electricity\":\"--\"}"
_G.REPORT_CONTROLLACK_TEMPLATE = "{\"status\":\"success\",\"cmdtype\":\"cmd_controllack\",\"did\":\"\",\"reporttime\":\"\"}"

-- 默认的经纬度和数据源
_G.old_latitude=""
_G.old_longitude=""
_G.data_from="NoData"

-- 默认的温湿度
_G.temperature=0
_G.humidity=0

-- 电量
_G.electricity = "--";
_G.vbat = "--";
_G.vbat_max = 4100;
_G.vbat_min = 3100;

_G.mqttc = nil   
_G.uartid = 1

_G.GPS_Updata=false
_G.GPS_Get=false

--卫星信号强度和4G信号强度
_G.Gnss_Ss=0
_G.Mobile_Ss=0
_G.SatsNum=0
_G.GPS_Ggt_Topic="GPS_Get"
_G.GPS_Ggt_Topic_F="GPS_Get_F"
_G.Updata_OK="Updata_OK"
