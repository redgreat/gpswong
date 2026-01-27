function 
    sys.wait(15000)
    local taskname="GetLocation"
    local nid=1 -- 网络端口
    local uid=1 -- uart 端口
    local netsta=0 -- 网络状态
    local needup=1 -- 上传状态
    local count=0 -- 循环次数
    local gpscount=0 -- gps 未定位成功
    local shake=0 -- 震动状态
    local cycletime=1 -- 循环时间(秒)
    local cyclecount=1 -- 循环上传次数
    local gpsrestart=1800 -- gps 未定位成功后重启时间(秒)
    GpsInit()
    while true do 
        shake=PerGetGpsZdSta()
        if shake~=nil then
            local d={}
            d.timestamp=os.time()
            d.csq=mobile.csq()
            d.acc=PerGetDiById(1)
            local volt=PerGetVbattV()
            d.volt=volt/1000
            if libgnss.isFix() then 
                gpscount=0
                local tg=libgnss.getRmc(2)
                local gsv=libgnss.getGsv()
                local spd=libgnss.getIntLocation(2)
                local gga=libgnss.getGga(2)
                local total_sats=gsv.total_sats
                local sats=gsv.sats
                local snr=nil
                local LsnrNum=0
                for i=1,total_sats do
                    snr=sats[i].snr
                    if snr>25 then 
                        LsnrNum=LsnrNum+1
                    end
                end
                d.gps={}
                d.gps.lat=tg.lat
                d.gps.lng=tg.lng
                d.gps.dir=tg.variation
                d.gps.spd=spd.speed
                d.gps.sats=LsnrNum
                d.gps.alt=gga.altitude
            else
                gpscount=gpscount+1
                if gpscount>(gpsrestart/cycletime) then
                    sys.reboot()
                end
            end
            if needup==1 then
                needup=0
                LbsCheckLbs()
                d.lbs={}
                d.lbs.lng,d.lbs.lat=GetLbs()
                local updata=json.encode(d)
                local netsta=PronetGetNetSta(nid)
                if netsta==1 then
                    PronetSetSendCh(nid,updata)
                end
            end
            count=count+1
            if count>cyclecount then
                needup=1
                count=0
            end
        end
        sys.wait(cycletime*1000)
    end
end