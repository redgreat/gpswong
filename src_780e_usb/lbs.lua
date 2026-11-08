-- 基站定位回落：GNSS 连续无定位（地下车库、室内）时，用当前基站给出大致位置。
-- 精度约数百米到 1 公里，坐标 WGS84。只用于补轨迹点，不驱动围栏（见 geofence.lua）。
-- 使用免 key 的 lbsLoc2 服务，当前处于官方“测试状态”，失败时返回 nil，不影响主流程。
local cfg = require("config")
local lbsLoc2 = require("lbsLoc2")
local lbs = {}

-- 必须在协程中调用（内部会 sys.waitUntil）。返回 lat, lng（number）或 nil。
function lbs.locate()
    if not cfg.lbs.enabled then return nil end
    mobile.reqCellInfo(15)
    sys.waitUntil("CELL_INFO_UPDATE", 6000)
    local lat, lng = lbsLoc2.request(cfg.lbs.timeout_ms)
    lat, lng = tonumber(lat), tonumber(lng)
    if not lat or not lng or (lat == 0 and lng == 0) then return nil end
    return lat, lng
end

return lbs
