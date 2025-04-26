function 
    sys.wait(15000)
    local taskname="GetLocation"
    local nid=1
    local uid=1
    local netsta=0
    local needup=1
    local count=0
    local gpscount=0
    local shake=0
    GpsInit()
    while true do 
        shake=PerGetGpsZdSta()
        if shake ~= nil then
            local d={}
            d.datetime=os.date("%Y-%m-%d %H:%M:%S")
            d.csq=mobile.csq()
            d.imei=mobile.imei()
            d.acc=PerGetDiById(1)
            d.volt=PerGetVbattV()
            d.gps={}
            d.gps.isFix=libgnss.isFix()
            if libgnss.isFix() then 
                gpscount=0
                local tg=libgnss.getRmc(2)
                local gsv=libgnss.getGsv()
                local spd = libgnss.getIntLocation(2)
                local gga = libgnss.getGga(2)
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
                d.gps.lat=tg.lat
                d.gps.lng=tg.lng
                d.gps.dir=tg.variation
                d.gps.spd=spd.speed
                d.gps.sats=LsnrNum
                d.gps.alt=gga.altitude
            else
                gpscount=gpscount+1
                if gpscount>1440 then
                    sys.reboot()
                end
            end
            if needup==1 then
                needup=0
                LbsCheckLbs()
                d.lbs={}
                d.lbs.lbslat,d.lbs.lbslng=GetLbs()
                local updata=json.encode(d)
                local netsta=PronetGetNetSta(nid)
                if netsta==1 then
                    PronetSetSendCh(nid,updata)
                end 
            end
            count=count+1
            if count>60 then 
                needup=1
                count=0
            end 
        end
        sys.wait(1000)
    end 
end