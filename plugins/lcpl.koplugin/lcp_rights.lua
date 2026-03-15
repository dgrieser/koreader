-- LCP Rights enforcement: date-window checking and persistent copy-count tracking.
-- Pure logic module — no UI, no HTTP. Callers decide how to present errors.

local LcpRights = {}

-- Compute the local timezone offset in seconds (local - UTC), cached after first call.
-- os.time(utc_fields) treats the UTC fields as local time, so the delta is the offset.
local _local_utc_offset
local function localUtcOffset()
    if not _local_utc_offset then
        local now = os.time()
        local utc_fields = os.date("!*t", now)
        -- os.time(utc_fields) interprets them as LOCAL → returns now - offset
        -- so offset = now - os.time(utc_fields)
        _local_utc_offset = os.difftime(now, os.time(utc_fields))
    end
    return _local_utc_offset
end

--- Parse an ISO 8601 date/datetime string and return os.time() integer (UTC epoch).
--- Handles: bare dates, Z suffix, and ±HH:MM / ±HHMM offsets.
--- Bare dates (no timezone marker) are assumed to be in local time.
--- @param date_str string
--- @return number|nil  seconds since epoch (UTC), or nil on parse failure
function LcpRights.parseIso8601(date_str)
    if not date_str then return nil end
    -- Capture components + optional timezone tail.
    local y, m, d, H, M, S, tz_tail = date_str:match(
        "(%d%d%d%d)-(%d%d)-(%d%d)[T ]?(%d*):?(%d*):?(%d*)(.*)")
    if not y then return nil end

    -- os.time() treats fields as local time → returns UTC epoch.
    local epoch = os.time({
        year  = tonumber(y),
        month = tonumber(m),
        day   = tonumber(d),
        hour  = H ~= "" and tonumber(H) or 0,
        min   = M ~= "" and tonumber(M) or 0,
        sec   = S ~= "" and tonumber(S) or 0,
    })

    -- If a timezone marker is present, adjust so epoch is correct UTC.
    -- Formula: utc_epoch = os.time(fields_as_local) + local_offset - parsed_offset
    --   os.time(fields_as_local) already subtracts local_offset internally,
    --   so we add it back then subtract the string's own offset.
    tz_tail = tz_tail and tz_tail:match("^%s*(.-)%s*$") or ""  -- trim whitespace
    if tz_tail ~= "" then
        local parsed_offset
        if tz_tail == "Z" or tz_tail == "z" then
            parsed_offset = 0
        else
            local sign, oh, om = tz_tail:match("^([%+%-])(%d%d):?(%d%d)")
            if sign and oh then
                parsed_offset = tonumber(oh) * 3600 + tonumber(om) * 60
                if sign == "-" then parsed_offset = -parsed_offset end
            end
        end
        if parsed_offset then
            epoch = epoch + localUtcOffset() - parsed_offset
        end
    end

    return epoch
end

--- Check that the current time falls within the license's rights window.
--- Returns true (no rights table, or rights without dates) or nil + human-readable error.
--- @param license_doc table  parsed license JSON
--- @return true|nil, string|nil
function LcpRights.checkDateRights(license_doc)
    local rights = license_doc and license_doc.rights
    if not rights then return true end

    local now = os.time()

    if rights.start then
        local start_t = LcpRights.parseIso8601(rights.start)
        if start_t and now < start_t then
            return nil, string.format(
                "License is not yet valid (valid from %s).", rights.start)
        end
    end

    if rights["end"] then
        local end_t = LcpRights.parseIso8601(rights["end"])
        if end_t and now > end_t then
            return nil, string.format(
                "License has expired (expired %s).", rights["end"])
        end
    end

    return true
end

--- Seed the copy counter for a license if `rights.copy` is present and the key is absent.
--- Idempotent — safe to call multiple times.
--- @param license_doc table  parsed license JSON
function LcpRights.initCopyRights(license_doc)
    local rights = license_doc and license_doc.rights
    if not rights or rights.copy == nil then return end
    local license_id = license_doc.id
    if not license_id then return end

    local counts = G_reader_settings:readSetting("lcp_copy_counts") or {}
    if counts[license_id] == nil then
        counts[license_id] = tonumber(rights.copy) or 0
        G_reader_settings:saveSetting("lcp_copy_counts", counts)
    end
end

--- Return the remaining copy-character quota for a license.
--- Returns nil when the license has no copy restriction (unlimited).
--- @param license_id string
--- @return number|nil
function LcpRights.getCopyRemaining(license_id)
    if not license_id then return nil end
    local counts = G_reader_settings:readSetting("lcp_copy_counts")
    if not counts then return nil end
    return counts[license_id]  -- nil = unlimited, number = remaining characters
end

--- Subtract char_count from the remaining copy quota.
--- Returns nil + error message if the quota is already exhausted or would be exceeded.
--- Sets the counter to 0 on exhaustion (does not go negative).
--- @param license_id  string
--- @param char_count  number  number of characters being copied
--- @return true|nil, string|nil
function LcpRights.decrementCopy(license_id, char_count)
    if not license_id then return true end

    local counts = G_reader_settings:readSetting("lcp_copy_counts")
    if not counts or counts[license_id] == nil then
        return true  -- unlimited
    end

    local remaining = counts[license_id]
    if remaining <= 0 then
        return nil, "Copy quota for this license has been exhausted."
    end
    if char_count > remaining then
        counts[license_id] = 0
        G_reader_settings:saveSetting("lcp_copy_counts", counts)
        return nil, string.format(
            "Copy quota exhausted (%d characters requested, %d remaining).",
            char_count, remaining)
    end

    counts[license_id] = remaining - char_count
    G_reader_settings:saveSetting("lcp_copy_counts", counts)
    return true
end

return LcpRights
