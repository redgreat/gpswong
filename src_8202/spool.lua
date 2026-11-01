local cfg = require("config")
local spool = {}
local RECORD_SIZE = 22
local FORMAT_VERSION = 2
local path = cfg.upload.spool_path
local max_records = math.floor(cfg.upload.offline_hours * 3600 / cfg.gnss.sample_interval_sec)
local head, count = 0, 0

local function save_meta()
    fskv.set("gpswong_spool_meta", {version=FORMAT_VERSION, head=head, count=count})
end

local function write_slot(index, record)
    local f = io.open(path, "r+b") or io.open(path, "w+b")
    assert(f, "open spool failed")
    assert(f:seek("set", index * RECORD_SIZE), "seek spool failed")
    f:write(record)
    f:close()
end

local function read_slot(index)
    local f = io.open(path, "rb")
    if not f then return nil end
    f:seek("set", index * RECORD_SIZE)
    local record = f:read(RECORD_SIZE)
    f:close()
    return record and #record == RECORD_SIZE and record or nil
end

function spool.init()
    fskv.init()
    local meta = fskv.get("gpswong_spool_meta")
    if type(meta) ~= "table" or meta.version ~= FORMAT_VERSION then
        os.remove(path) -- v1 的 80B/旧偏移格式不能与 22B 环形队列混用
        head, count = 0, 0
        save_meta()
    else
        head = math.max(0, math.min(tonumber(meta.head) or 0, max_records - 1))
        count = math.max(0, math.min(tonumber(meta.count) or 0, max_records))
    end
    log.info("spool", "ring ready", "points", count, "max", max_records,
        "capacity_bytes", max_records * RECORD_SIZE, "head", head)
end

function spool.count() return count end

function spool.push(record)
    assert(type(record) == "string" and #record == RECORD_SIZE, "bad spool record")
    local index
    if count < max_records then
        index = (head + count) % max_records
        count = count + 1
    else
        index = head
        head = (head + 1) % max_records
        log.warn("spool", "8-hour queue full; overwrite oldest point")
    end
    write_slot(index, record)
    save_meta()
end

function spool.peek(limit)
    local n = math.min(count, limit)
    local out = {}
    for i = 0, n - 1 do
        local record = read_slot((head + i) % max_records)
        if not record then break end
        out[#out + 1] = record
    end
    return out
end

function spool.ack(n)
    n = math.min(tonumber(n) or 0, count)
    if n <= 0 then return end
    head = (head + n) % max_records
    count = count - n
    if count == 0 then head = 0; os.remove(path) end
    save_meta()
end

function spool.max_records() return max_records end
return spool
