function
    sys.wait(15000)
    local nid, cycle = 1, 1
    local gpscount, lastlbs, laststat = 0, os.time(), 0
    local lbstime, gpsrestart, statetime = 1800, 300, 300
    local shake_mode, shake_counter = 0, 29
    GpsInit()
    while true do
        local d = {timestamp = os.time(), csq = mobile.csq(), acc = PerGetDiById(1), volt = PerGetVbattV() / 1000}

        if shake_mode == 0 then
            shake_counter = shake_counter + 1
            if shake_counter >= 30 then
                shake_counter = 0
                if PerGetGpsZdSta() == 1 then shake_mode = 1 end
            end
        elseif PerGetGpsZdSta() == 0 then
            shake_mode, shake_counter = 0, 0
        end

        local tg = libgnss.isFix() and libgnss.getRmc(2) or nil
        if tg and tg.valid then
            d.gps = {lat = tg.lat, lng = tg.lng, spd = tg.speed, dir = tg.course}
            gpscount = 0
        else
            gpscount = gpscount + 1
            if shake_mode == 1 and gpscount > gpsrestart / cycle then sys.reboot() end
        end

        local now = os.time()
        if not d.gps and now >= lastlbs + lbstime then
            LbsCheckLbs()
            d.lbs = {}
            d.lbs.lng, d.lbs.lat = GetLbs()
            lastlbs = now
        end

        local gps_send = d.gps and (shake_mode == 1 or now - laststat >= statetime)
        if gps_send then laststat = now end
        if (gps_send or d.lbs) and PronetGetNetSta(nid) == 1 then
            PronetSetSendCh(nid, json.encode(d))
        end
        sys.wait(cycle * 1000)
    end
end