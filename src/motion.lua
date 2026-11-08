-- 运动判定：设备无加速度计，仅用 GNSS 速度判断是否运动。
local cfg = require("config")
local motion = { last_motion_ms = 0, boot_ms = mcu.ticks() }

function motion.update(speed_kmh)
    if speed_kmh >= cfg.motion.speed_kmh then motion.last_motion_ms = mcu.ticks() end
end

function motion.is_moving()
    if not cfg.motion.only_when_moving then return true end
    local now = mcu.ticks()
    if now - motion.boot_ms < cfg.motion.boot_active_sec * 1000 then return true end
    return now - motion.last_motion_ms < cfg.motion.moving_hold_sec * 1000
end

return motion
