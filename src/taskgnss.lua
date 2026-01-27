function 
    sys.wait(15000)
    local taskname="GetLocation"
    local nid=1
    local netsta=0
    local gpscount=0
    local gpsrestart=300
    local lastlbs=os.time()
    local lbstime=1800 
    local cycletime=1
    local shake_mode=0
    local shake_counter=29
    GpsInit()
    while true do
        local d={}
        d.timestamp=os.time()
        d.csq=mobile.csq()
        d.acc=PerGetDiById(1)
        local volt=PerGetVbattV()
        d.volt=volt/1000
        
        if shake_mode==0 then
            shake_counter=shake_counter + 1
            if shake_counter>=30 then
                shake_counter=0
                if PerGetGpsZdSta()==1 then
                    shake_mode=1
                end
            end
        else
            if PerGetGpsZdSta()==0 then
                shake_mode=0
                shake_counter=0
            end
        end

        if shake_mode==1 then
            for _=1,30,1 do
                if libgnss.isFix() then 
                    local tg=libgnss.getRmc(2)
                    d.gps={lat=tg.lat,lng=tg.lng,spd=tg.speed,dir=tg.variation}
                    gpscount=0
                    break
                else
                    if os.time()>=lbstime+lastlbs then
                        LbsCheckLbs()
                        d.lbs={}
                        d.lbs.lng,d.lbs.lat=GetLbs()
                        lastlbs=os.time()
                        local updata=json.encode(d)
                        if PronetGetNetSta(nid)==1 then
                            PronetSetSendCh(nid,updata)
                        end
                    end
                    sys.wait(1000)
                    gpscount=gpscount+1
                    if gpscount>(gpsrestart/cycletime) then
                        sys.reboot()
                    end
                end
            end
            if os.time()>=lbstime+lastlbs then
                LbsCheckLbs()
                d.lbs={}
                d.lbs.lng,d.lbs.lat=GetLbs()
                lastlbs=os.time()
            end
            local updata=json.encode(d)
            if PronetGetNetSta(nid) == 1 then
                PronetSetSendCh(nid,updata)
            end
        end
        if os.time()>=lbstime+lastlbs then
            LbsCheckLbs()
            d.lbs={}
            d.lbs.lng,d.lbs.lat=GetLbs()
            lastlbs=os.time()
            local updata=json.encode(d)
            if PronetGetNetSta(nid) == 1 then
                PronetSetSendCh(nid,updata)
            end
        end
        sys.wait(cycletime*1000)
    end
end