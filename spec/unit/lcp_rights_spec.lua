-- Unit tests for lcp_rights.lua
describe("LCP rights module", function()
    local LcpRights

    setup(function()
        require("commonrequire")
        package.path = "plugins/lcpl.koplugin/?.lua;" .. package.path

        -- Stub G_reader_settings.
        local settings_store = {}
        _G.G_reader_settings = {
            readSetting = function(_, key) return settings_store[key] end,
            saveSetting = function(_, key, val) settings_store[key] = val end,
        }

        LcpRights = require("lcp_rights")
    end)

    -- -----------------------------------------------------------------------
    -- parseIso8601
    -- -----------------------------------------------------------------------
    describe("parseIso8601", function()
        it("parses a bare date", function()
            local t = LcpRights.parseIso8601("2024-06-15")
            assert.is_not_nil(t)
            assert.is_true(type(t) == "number")
            assert.is_true(t > 0)
        end)

        it("parses a full UTC datetime with Z suffix", function()
            local t = LcpRights.parseIso8601("2024-06-15T12:30:00Z")
            assert.is_not_nil(t)
            assert.is_true(type(t) == "number")
        end)

        it("returns nil for nil input", function()
            assert.is_nil(LcpRights.parseIso8601(nil))
        end)

        it("returns nil for empty string", function()
            assert.is_nil(LcpRights.parseIso8601(""))
        end)

        it("returns nil for non-date string", function()
            assert.is_nil(LcpRights.parseIso8601("not-a-date"))
        end)

        it("parses two different dates as different times", function()
            local t1 = LcpRights.parseIso8601("2020-01-01")
            local t2 = LcpRights.parseIso8601("2030-01-01")
            assert.is_not_nil(t1)
            assert.is_not_nil(t2)
            assert.is_true(t1 < t2)
        end)

        it("Z and +00:00 produce the same UTC epoch", function()
            local t_z    = LcpRights.parseIso8601("2024-03-10T08:00:00Z")
            local t_plus = LcpRights.parseIso8601("2024-03-10T08:00:00+00:00")
            assert.is_not_nil(t_z)
            assert.is_not_nil(t_plus)
            assert.are.equal(t_z, t_plus)
        end)

        it("+01:00 offset shifts epoch back by 3600 relative to Z", function()
            -- 10:00+01:00 = 09:00 UTC, so epoch should be 3600 less than 10:00Z
            local t_utc    = LcpRights.parseIso8601("2024-03-10T10:00:00Z")
            local t_offset = LcpRights.parseIso8601("2024-03-10T10:00:00+01:00")
            assert.is_not_nil(t_utc)
            assert.is_not_nil(t_offset)
            assert.are.equal(t_utc - 3600, t_offset)
        end)

        it("-05:00 offset shifts epoch forward by 18000 relative to Z", function()
            -- 10:00-05:00 = 15:00 UTC, so epoch should be 18000 more than 10:00Z
            local t_utc    = LcpRights.parseIso8601("2024-03-10T10:00:00Z")
            local t_offset = LcpRights.parseIso8601("2024-03-10T10:00:00-05:00")
            assert.is_not_nil(t_utc)
            assert.is_not_nil(t_offset)
            assert.are.equal(t_utc + 18000, t_offset)
        end)
    end)

    -- -----------------------------------------------------------------------
    -- checkDateRights
    -- -----------------------------------------------------------------------
    describe("checkDateRights", function()
        it("returns true when rights table is absent", function()
            local ok, err = LcpRights.checkDateRights({ id = "test" })
            assert.is_true(ok == true)
            assert.is_nil(err)
        end)

        it("returns true when rights has no start/end dates", function()
            local ok = LcpRights.checkDateRights({ rights = { copy = 100 } })
            assert.is_true(ok == true)
        end)

        it("returns true for a start date in the past", function()
            local ok = LcpRights.checkDateRights({
                rights = { start = "2000-01-01T00:00:00Z" },
            })
            assert.is_true(ok == true)
        end)

        it("returns nil + error for a start date in the future", function()
            local ok, err = LcpRights.checkDateRights({
                rights = { start = "2099-01-01T00:00:00Z" },
            })
            assert.is_nil(ok)
            assert.is_not_nil(err)
            assert.is_true(err:find("not yet valid") ~= nil)
        end)

        it("returns true for an end date in the future", function()
            local ok = LcpRights.checkDateRights({
                rights = { ["end"] = "2099-12-31T23:59:59Z" },
            })
            assert.is_true(ok == true)
        end)

        it("returns nil + error for an end date in the past", function()
            local ok, err = LcpRights.checkDateRights({
                rights = { ["end"] = "2000-01-01T00:00:00Z" },
            })
            assert.is_nil(ok)
            assert.is_not_nil(err)
            assert.is_true(err:find("expired") ~= nil)
        end)
    end)

    -- -----------------------------------------------------------------------
    -- initCopyRights / getCopyRemaining / decrementCopy
    -- -----------------------------------------------------------------------
    describe("copy accounting", function()
        local license_id = "test-license-copy-" .. tostring(os.time())

        it("initCopyRights seeds the counter from rights.copy", function()
            LcpRights.initCopyRights({
                id = license_id,
                rights = { copy = 200 },
            })
            local remaining = LcpRights.getCopyRemaining(license_id)
            assert.are.equal(200, remaining)
        end)

        it("initCopyRights is idempotent (second call does not reset)", function()
            LcpRights.initCopyRights({
                id = license_id,
                rights = { copy = 999 },  -- different value
            })
            -- Counter should still be at the original 200 (minus any decrements).
            local remaining = LcpRights.getCopyRemaining(license_id)
            assert.is_true(remaining <= 200)
        end)

        it("decrementCopy subtracts from the counter", function()
            local before = LcpRights.getCopyRemaining(license_id)
            local ok, err = LcpRights.decrementCopy(license_id, 10)
            assert.is_true(ok == true)
            assert.is_nil(err)
            local after = LcpRights.getCopyRemaining(license_id)
            assert.are.equal(before - 10, after)
        end)

        it("decrementCopy returns error when quota exhausted", function()
            -- Drain the counter completely.
            local remaining = LcpRights.getCopyRemaining(license_id)
            if remaining and remaining > 0 then
                LcpRights.decrementCopy(license_id, remaining)
            end
            local ok, err = LcpRights.decrementCopy(license_id, 1)
            assert.is_nil(ok)
            assert.is_not_nil(err)
        end)

        it("getCopyRemaining returns nil for an unknown license (unlimited)", function()
            local remaining = LcpRights.getCopyRemaining("nonexistent-license-xyz")
            assert.is_nil(remaining)
        end)

        it("decrementCopy returns true for a license with no copy restriction", function()
            local ok, err = LcpRights.decrementCopy("no-copy-limit-license", 9999)
            assert.is_true(ok == true)
            assert.is_nil(err)
        end)

        it("initCopyRights does nothing when rights.copy is absent", function()
            local id = "no-copy-rights-" .. tostring(os.time())
            LcpRights.initCopyRights({ id = id, rights = {} })
            assert.is_nil(LcpRights.getCopyRemaining(id))
        end)
    end)
end)
