-- Unit tests for lcp_status.lua
describe("LCP status module", function()
    local LcpStatus

    setup(function()
        require("commonrequire")
        package.path = "plugins/lcpl.koplugin/?.lua;" .. package.path

        -- Stub G_reader_settings so the module can call readSetting / saveSetting.
        local settings_store = {}
        _G.G_reader_settings = {
            readSetting  = function(_, key) return settings_store[key] end,
            saveSetting  = function(_, key, val) settings_store[key] = val end,
        }

        -- Stub Device so getDeviceName() does not crash.
        local Device_orig = package.loaded["device"]
        if not Device_orig then
            package.loaded["device"] = { getDeviceModel = function() return "TestDevice" end }
        end

        LcpStatus = require("lcp_status")
    end)

    -- -----------------------------------------------------------------------
    -- expandUriTemplate
    -- -----------------------------------------------------------------------
    describe("expandUriTemplate", function()
        it("strips simple {?id,name} placeholder", function()
            local href = "https://example.com/register{?id,name}"
            local result = LcpStatus.expandUriTemplate(href, { id = "abc", name = "Test" })
            -- base URL has no query yet
            assert.is_true(result:sub(1, #"https://example.com/register") ==
                "https://example.com/register")
            assert.is_true(result:find("id=abc") ~= nil)
            assert.is_true(result:find("name=Test") ~= nil)
        end)

        it("appends to existing query string with &", function()
            local href = "https://example.com/register?foo=bar{&id}"
            local result = LcpStatus.expandUriTemplate(href, { id = "42" })
            assert.is_true(result:find("foo=bar") ~= nil)
            assert.is_true(result:find("id=42") ~= nil)
        end)

        it("returns bare URL when params is empty", function()
            local href = "https://example.com/status{?id}"
            local result = LcpStatus.expandUriTemplate(href, {})
            assert.are.equal("https://example.com/status", result)
        end)

        it("percent-encodes param values with spaces", function()
            local result = LcpStatus.expandUriTemplate(
                "https://example.com/r{?name}", { name = "My Device" })
            assert.is_true(result:find("My%%20Device") ~= nil or
                           result:find("My+Device") ~= nil or
                           result:find("My Device") == nil)
        end)
    end)

    -- -----------------------------------------------------------------------
    -- getDeviceId
    -- -----------------------------------------------------------------------
    describe("getDeviceId", function()
        it("returns a non-empty string", function()
            local id = LcpStatus.getDeviceId()
            assert.is_not_nil(id)
            assert.is_true(type(id) == "string")
            assert.is_true(#id > 0)
        end)

        it("is stable across calls", function()
            local id1 = LcpStatus.getDeviceId()
            local id2 = LcpStatus.getDeviceId()
            assert.are.equal(id1, id2)
        end)
    end)

    -- -----------------------------------------------------------------------
    -- getDeviceName
    -- -----------------------------------------------------------------------
    describe("getDeviceName", function()
        it("returns a non-empty string", function()
            local name = LcpStatus.getDeviceName()
            assert.is_not_nil(name)
            assert.is_true(type(name) == "string")
            assert.is_true(#name > 0)
        end)
    end)

    -- -----------------------------------------------------------------------
    -- checkStatus
    -- -----------------------------------------------------------------------
    describe("checkStatus", function()
        it("returns true for 'active' status", function()
            local ok, err = LcpStatus.checkStatus({ status = "active" })
            assert.is_true(ok == true)
            assert.is_nil(err)
        end)

        it("returns true for 'ready' status", function()
            local ok = LcpStatus.checkStatus({ status = "ready" })
            assert.is_true(ok == true)
        end)

        it("returns nil + error for 'revoked'", function()
            local ok, err = LcpStatus.checkStatus({ status = "revoked" })
            assert.is_nil(ok)
            assert.is_not_nil(err)
            assert.is_true(type(err) == "string")
            assert.is_true(err:find("revoked") ~= nil)
        end)

        it("returns nil + error for 'returned'", function()
            local ok, err = LcpStatus.checkStatus({ status = "returned" })
            assert.is_nil(ok)
            assert.is_not_nil(err)
        end)

        it("returns nil + error for 'cancelled'", function()
            local ok, err = LcpStatus.checkStatus({ status = "cancelled" })
            assert.is_nil(ok)
            assert.is_not_nil(err)
        end)

        it("returns nil + error for 'expired'", function()
            local ok, err = LcpStatus.checkStatus({ status = "expired" })
            assert.is_nil(ok)
            assert.is_not_nil(err)
        end)

        it("includes server message in the error when present", function()
            local ok, err = LcpStatus.checkStatus({
                status = "revoked",
                message = "Publisher revoked this license.",
            })
            assert.is_nil(ok)
            assert.is_true(err:find("Publisher revoked") ~= nil)
        end)

        it("returns nil + error when status field is missing", function()
            local ok, err = LcpStatus.checkStatus({})
            assert.is_nil(ok)
            assert.is_not_nil(err)
        end)
    end)
end)
