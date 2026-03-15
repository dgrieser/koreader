-- LCP Status Document handling: fetch, validate, device registration, renew/return.
-- Pure network/logic module — no UI. Callers decide how to present errors.
local Device = require("device")
local JSON = require("json")
local http = require("socket.http")
local logger = require("logger")
local ltn12 = require("ltn12")
local socketutil = require("socketutil")
local url = require("socket.url")

local LcpStatus = {}

-- Generate a random UUID v4 string.
local function generateUUID()
    math.randomseed(os.time())
    local template = "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"
    return template:gsub("[xy]", function(c)
        local v = c == "x" and math.random(0, 15) or math.random(8, 11)
        return string.format("%x", v)
    end)
end

--- Return a stable device ID, generating and persisting one on first call.
--- @return string UUID string
function LcpStatus.getDeviceId()
    local id = G_reader_settings:readSetting("lcp_device_id")
    if not id then
        id = generateUUID()
        G_reader_settings:saveSetting("lcp_device_id", id)
    end
    return id
end

--- Return a human-readable device name.
--- @return string
function LcpStatus.getDeviceName()
    local ok, model = pcall(function() return Device:getDeviceModel() end)
    if ok and model and model ~= "" then
        return model
    end
    return "KOReader"
end

--- Expand a URI template containing `{?param,...}` placeholders.
--- Strips all `{...}` blocks from href, then appends the params table as a query string.
--- @param href   string  template URL, e.g. "https://example.com/register{?id,name}"
--- @param params table   key→value pairs to append
--- @return string        expanded URL
function LcpStatus.expandUriTemplate(href, params)
    local base = href:gsub("{[^}]*}", "")
    local parts = {}
    for k, v in pairs(params) do
        table.insert(parts, url.escape(tostring(k)) .. "=" .. url.escape(tostring(v)))
    end
    if #parts == 0 then
        return base
    end
    local sep = base:find("?") and "&" or "?"
    return base .. sep .. table.concat(parts, "&")
end

-- Perform a simple HTTP request, returning body string + status code.
local function httpGet(request_url)
    local body_parts = {}
    local ok, res, code = pcall(http.request, {
        url = request_url,
        headers = { ["Accept"] = "application/json" },
        sink = ltn12.sink.table(body_parts),
    })
    if not ok then
        return nil, nil, "request failed: " .. tostring(res)
    end
    return table.concat(body_parts), code
end

local function httpPost(request_url)
    local body_parts = {}
    local ok, res, code = pcall(http.request, {
        method = "POST",
        url = request_url,
        headers = {
            ["Content-Length"] = "0",
            ["Content-Type"] = "application/x-www-form-urlencoded",
        },
        source = ltn12.source.string(""),
        sink = ltn12.sink.table(body_parts),
    })
    if not ok then
        return nil, nil, "request failed: " .. tostring(res)
    end
    return table.concat(body_parts), code
end

local function httpPut(request_url)
    local body_parts = {}
    local ok, res, code = pcall(http.request, {
        method = "PUT",
        url = request_url,
        headers = {
            ["Content-Length"] = "0",
            ["Content-Type"] = "application/json",
        },
        source = ltn12.source.string(""),
        sink = ltn12.sink.table(body_parts),
    })
    if not ok then
        return nil, nil, "request failed: " .. tostring(res)
    end
    return table.concat(body_parts), code
end

--- Fetch and parse the LCP status document referenced in the license.
--- @param license_doc table  parsed license JSON
--- @return table|nil status_doc, string|nil err
function LcpStatus.fetchStatusDoc(license_doc)
    local links = license_doc and license_doc.links
    if type(links) ~= "table" then
        return nil, "no links in license"
    end
    local status_href
    for _, link in ipairs(links) do
        if link.rel == "status" and link.href then
            status_href = link.href
            break
        end
    end
    if not status_href then
        return nil, "no status link in license"
    end

    socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
    local body, code, net_err = httpGet(status_href)
    socketutil:reset_timeout()

    if not body then
        return nil, net_err
    end
    if code ~= 200 then
        return nil, "status server returned HTTP " .. tostring(code)
    end

    local parse_ok, status_doc = pcall(JSON.decode, body)
    if not parse_ok or type(status_doc) ~= "table" then
        return nil, "invalid status document JSON"
    end
    logger.dbg("LCP: status document fetched, status =", status_doc.status)
    return status_doc
end

local INVALID_STATUSES = {
    revoked   = "revoked by the publisher",
    returned  = "returned by the user",
    cancelled = "cancelled",
    expired   = "expired",
}

--- Validate that a status document does not indicate an unusable license.
--- @param status_doc table  parsed status document
--- @return true|nil, string|nil
function LcpStatus.checkStatus(status_doc)
    local status = status_doc and status_doc.status
    if not status then
        return nil, "missing status field in status document"
    end
    local reason = INVALID_STATUSES[status]
    if reason then
        local msg = status_doc.message
        if msg and msg ~= "" then
            return nil, string.format("License %s: %s", reason, msg)
        end
        return nil, string.format("License %s.", reason)
    end
    return true
end

--- Register this device with the license server.
--- Blocking; returns nil + error message on failure.
--- @param license_doc  table  parsed license JSON (unused currently, kept for API symmetry)
--- @param status_doc   table  parsed status document (provides the register link)
--- @return true|nil, string|nil
function LcpStatus.registerDevice(license_doc, status_doc) -- luacheck: ignore license_doc
    local links = status_doc and status_doc.links
    if type(links) ~= "table" then
        return nil, "no links in status document"
    end
    local register_href
    for _, link in ipairs(links) do
        if link.rel == "register" and link.href then
            register_href = link.href
            break
        end
    end
    if not register_href then
        -- No register link — server does not require registration.
        logger.dbg("LCP: no register link, skipping device registration")
        return true
    end

    local register_url = LcpStatus.expandUriTemplate(register_href, {
        id   = LcpStatus.getDeviceId(),
        name = LcpStatus.getDeviceName(),
    })

    socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
    local _, code, net_err = httpPost(register_url)
    socketutil:reset_timeout()

    if not code then
        return nil, "device registration failed: " .. tostring(net_err)
    end
    if code ~= 200 and code ~= 201 then
        return nil, "device registration failed with HTTP " .. tostring(code)
    end
    logger.dbg("LCP: device registered, HTTP", code)
    return true
end

--- PUT to the renew link in a freshly-fetched status document.
--- @param status_doc table
--- @return true|nil, string|nil
function LcpStatus.renewLicense(status_doc)
    local links = status_doc and status_doc.links
    if type(links) ~= "table" then
        return nil, "no links in status document"
    end
    local renew_href
    for _, link in ipairs(links) do
        if link.rel == "renew" and link.href then
            renew_href = link.href
            break
        end
    end
    if not renew_href then
        return nil, "no renew link in status document"
    end

    local renew_url = LcpStatus.expandUriTemplate(renew_href, {
        id   = LcpStatus.getDeviceId(),
        name = LcpStatus.getDeviceName(),
    })

    socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
    local _, code, net_err = httpPut(renew_url)
    socketutil:reset_timeout()

    if not code then
        return nil, "renew request failed: " .. tostring(net_err)
    end
    if code ~= 200 and code ~= 201 then
        return nil, "renew request failed with HTTP " .. tostring(code)
    end
    return true
end

--- PUT to the return link in a freshly-fetched status document.
--- @param status_doc table
--- @return true|nil, string|nil
function LcpStatus.returnContent(status_doc)
    local links = status_doc and status_doc.links
    if type(links) ~= "table" then
        return nil, "no links in status document"
    end
    local return_href
    for _, link in ipairs(links) do
        if link.rel == "return" and link.href then
            return_href = link.href
            break
        end
    end
    if not return_href then
        return nil, "no return link in status document"
    end

    local return_url = LcpStatus.expandUriTemplate(return_href, {
        id   = LcpStatus.getDeviceId(),
        name = LcpStatus.getDeviceName(),
    })

    socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
    local _, code, net_err = httpPut(return_url)
    socketutil:reset_timeout()

    if not code then
        return nil, "return request failed: " .. tostring(net_err)
    end
    if code ~= 200 and code ~= 201 then
        return nil, "return request failed with HTTP " .. tostring(code)
    end
    return true
end

return LcpStatus
