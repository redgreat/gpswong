local protocol = {}
local cfg = require("config")

local function clamp(value, low, high)
    value = math.floor(tonumber(value) or 0)
    if value < low then return low end
    if value > high then return high end
    return value
end

local function crc16_ccitt(data)
    local crc = 0xFFFF
    for i = 1, #data do
        crc = crc ~ (string.byte(data, i) << 8)
        for _ = 1, 8 do
            if (crc & 0x8000) ~= 0 then
                crc = ((crc << 1) ~ 0x1021) & 0xFFFF
            else
                crc = (crc << 1) & 0xFFFF
            end
        end
    end
    return crc
end

local function battery_percent(mv)
    -- 单节锂电池的保守线性近似，仅用于协议 battery 快照。
    return clamp(((tonumber(mv) or 3300) - 3300) * 100 / 900, 0, 100)
end

local function utc_name(point)
    return string.format("%04d%02d%02d%02d%02d%02d",
        point.year, point.month, point.day, point.hour, point.min, point.sec)
end

-- Flash 离线队列紧凑记录：22B/点。
-- epoch(4) + lat/lng(8) + speed/course(4) + xyz(6)。
function protocol.encode_spool(point)
    local epoch = os.time({year=point.year, month=point.month, day=point.day,
        hour=point.hour, min=point.min, sec=point.sec})
    local speed_kmh = (tonumber(point.speed_knots) or 0) * 1.852
    return string.pack("<I4i4i4I2I2i2i2i2",
        clamp(epoch, 0, 0xFFFFFFFF),
        clamp((tonumber(point.lat) or 0) * 1e7, -2147483648, 2147483647),
        clamp((tonumber(point.lng) or 0) * 1e7, -2147483648, 2147483647),
        clamp(speed_kmh * 100, 0, 65535),
        clamp((tonumber(point.course) or 0) * 100, 0, 65535),
        clamp((tonumber(point.gforce_x) or 0) * 1000, -32768, 32767),
        clamp((tonumber(point.gforce_y) or 0) * 1000, -32768, 32767),
        clamp((tonumber(point.gforce_z) or 0) * 1000, -32768, 32767))
end

function protocol.spool_to_record(data, vbat_mv)
    local epoch, lat, lng, speed100, course100, gx, gy, gz =
        string.unpack("<I4i4i4I2I2i2i2i2", data)
    local dt = os.date("!*t", epoch)
    return protocol.encode_record({
        itow = (dt.hour * 3600 + dt.min * 60 + dt.sec) * 1000,
        year=dt.year, month=dt.month, day=dt.day,
        hour=dt.hour, min=dt.min, sec=dt.sec,
        lat=lat / 1e7, lng=lng / 1e7,
        speed_knots=(speed100 / 100) / 1.852,
        course=course100 / 100,
        fix_type=3, satellites=0, altitude=0, hdop=0, pdop=0,
        gforce_x=gx / 1000, gforce_y=gy / 1000, gforce_z=gz / 1000,
    }, vbat_mv)
end

function protocol.encode_record(point, vbat_mv)
    -- 与 emqx_pg_ingest 的 simlive_rb 80 字节记录完全一致。
    local speed_kmh = (tonumber(point.speed_knots) or 0) * 1.852
    local record = string.pack("<I4I2BBBBBBI4i4BBBBi4i4i4i4I4I4i4i4I4I4I2BBi2i2i2i2i2i2",
        clamp(point.itow, 0, 0xFFFFFFFF),
        clamp(point.year, 0, 65535),
        clamp(point.month, 1, 12), clamp(point.day, 1, 31),
        clamp(point.hour, 0, 23), clamp(point.min, 0, 59),
        clamp(point.sec, 0, 60), 1,
        0, 0, clamp(point.fix_type, 0, 255), 0, 0,
        clamp(point.satellites, 0, 255),
        clamp((tonumber(point.lng) or 0) * 1e7, -2147483648, 2147483647),
        clamp((tonumber(point.lat) or 0) * 1e7, -2147483648, 2147483647),
        clamp((tonumber(point.altitude) or 0) * 1000, -2147483648, 2147483647),
        clamp((tonumber(point.altitude) or 0) * 1000, -2147483648, 2147483647),
        clamp((tonumber(point.hdop) or 0) * 1000, 0, 0xFFFFFFFF),
        0,
        clamp(speed_kmh / 60 * 100, -2147483648, 2147483647),
        clamp((tonumber(point.course) or 0) * 1e5, -2147483648, 2147483647),
        0, 0,
        clamp((tonumber(point.pdop) or 0) * 100, 0, 65535),
        0, battery_percent(vbat_mv),
        clamp((tonumber(point.gforce_x) or 0) * 1000, -32768, 32767),
        clamp((tonumber(point.gforce_y) or 0) * 1000, -32768, 32767),
        clamp((tonumber(point.gforce_z) or 0) * 1000, -32768, 32767),
        0, 0, 0)

    assert(#record == 80, "simlive record must be 80 bytes")
    return record
end

local function record_time(record)
    local _, year, month, day, hour, minute, second = string.unpack("<I4I2BBBBBB", record)
    return {year=year, month=month, day=day, hour=hour, min=minute, sec=second}
end

function protocol.encode_records(records, device_id)
    assert(type(records) == "table" and #records > 0, "records must not be empty")
    local first, last = record_time(records[1]), record_time(records[#records])
    local name = string.format("8202_%s_%s_%s", device_id, utc_name(first), utc_name(last))
    assert(#name <= 255, "file name too long")
    local duration = math.max(0, #records - 1) * cfg.gnss.sample_interval_sec
    local body = "RB" .. string.pack("<BBB", 1, 1, #name) .. name
        .. string.pack("<I4I2", duration, #records) .. table.concat(records)
    return body .. string.pack("<I2", crc16_ccitt(body)), name
end

function protocol.encode(points, device_id, vbat_mv)
    local records = {}
    for i, point in ipairs(points) do records[i] = protocol.encode_record(point, vbat_mv) end
    return protocol.encode_records(records, device_id)
end

protocol.crc16_ccitt = crc16_ccitt
return protocol
