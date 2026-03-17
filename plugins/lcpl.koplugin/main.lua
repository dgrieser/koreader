local BD = require("ui/bidi")
local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local DocumentRegistry = require("document/documentregistry")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local JSON = require("json")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local http = require("socket.http")
local logger = require("logger")
local ltn12 = require("ltn12")
local socketutil = require("socketutil")
local url = require("socket.url")
local util = require("util")

local _ = require("gettext")
local T = require("ffi/util").template

local Lcpl = WidgetContainer:extend{
    name = "lcpl",
    is_doc_only = false,
}

-- ---------------------------------------------------------------------------
-- Crypto availability check (replaces the Kindle-only guard)
-- ---------------------------------------------------------------------------

local _crypto_available  -- nil = untested, true/false = result

local function isCryptoAvailable()
    if _crypto_available == nil then
        local ok, crypto = pcall(require, "lcp_crypto")
        if ok then
            -- Verify a real operation succeeds (library fully loaded).
            local test_ok = pcall(function() crypto.sha256("test") end)
            _crypto_available = test_ok
        else
            _crypto_available = false
        end
    end
    return _crypto_available
end

-- ---------------------------------------------------------------------------
-- Plugin lifecycle
-- ---------------------------------------------------------------------------

function Lcpl:init()
    if not isCryptoAvailable() then
        return
    end
    DocumentRegistry:addAuxProvider({
        provider_name = _("CARE DRM (LCPL)"),
        provider = self.name,
        order = 10,
        extensions = { "lcpl", "epub" },
        disable_file = true,
        disable_type = false,
    })
end

function Lcpl:isFileTypeSupported(file)
    local ext = util.getFileNameSuffix(file):lower()
    return ext == "lcpl" or ext == "epub"
end

-- ---------------------------------------------------------------------------
-- Passphrase key cache  (stores hex-encoded derived user key)
-- ---------------------------------------------------------------------------

-- Encode binary string to lowercase hex.
local function toHex(bytes)
    return (bytes:gsub(".", function(c)
        return string.format("%02x", c:byte())
    end))
end

-- Decode a hex string to raw bytes (returns nil on bad input).
local function fromHex(hex)
    if not hex or #hex % 2 ~= 0 then return nil end
    return (hex:gsub("%x%x", function(h) return string.char(tonumber(h, 16)) end))
end

--- Derive the cache keys used for a license document.
--- Returns up to three string keys: license_id, user_id, origin.
local function cacheKeysFor(license_doc)
    local keys = {}
    if license_doc.id then
        table.insert(keys, license_doc.id)
    end
    -- user_id from encryption.user_key.id
    local user_id = util.tableGetValue(license_doc, "encryption", "user_key", "id")
    if user_id then
        table.insert(keys, "uid:" .. user_id)
    end
    -- origin = hostname of the publication link
    local links = license_doc.links
    if type(links) == "table" then
        for _, link in ipairs(links) do
            if link.rel == "publication" and link.href then
                local parsed = url.parse(link.href)
                if parsed and parsed.host then
                    table.insert(keys, "origin:" .. parsed.host)
                end
                break
            end
        end
    end
    return keys
end

--- Try to load a cached user key for this license.
--- Lookup order: license_id → user_id → origin.
--- @param license_doc table
--- @return string|nil  32-byte binary user key, or nil
function Lcpl:_loadCachedKey(license_doc)
    local cache = G_reader_settings:readSetting("lcp_key_cache")
    if not cache then return nil end
    for _, k in ipairs(cacheKeysFor(license_doc)) do
        local hex = cache[k]
        if hex then
            local key = fromHex(hex)
            if key and #key == 32 then
                logger.dbg("LCP: cached key found for", k)
                return key
            end
        end
    end
    return nil
end

--- Persist the user key under all applicable cache keys for this license.
--- @param license_doc table
--- @param user_key    string  32-byte binary user key
function Lcpl:_saveCachedKey(license_doc, user_key)
    local cache = G_reader_settings:readSetting("lcp_key_cache") or {}
    local hex = toHex(user_key)
    for _, k in ipairs(cacheKeysFor(license_doc)) do
        cache[k] = hex
    end
    G_reader_settings:saveSetting("lcp_key_cache", cache)
end

-- ---------------------------------------------------------------------------
-- Helpers shared by both .lcpl and embedded-EPUB flows
-- ---------------------------------------------------------------------------

function Lcpl:_findLink(license_doc, rel_name)
    local links = license_doc and license_doc.links
    if type(links) ~= "table" then
        return nil
    end
    for _, link in ipairs(links) do
        if link.rel == rel_name then
            return link
        end
    end
    return nil
end

-- Returns the path for the encrypted intermediate file (e.g. book.lcp.epub).
function Lcpl:_deriveEncryptedFile(file, publication_link)
    local folder, base_name = util.splitFilePathName(file)
    local filename = base_name:match("(.+)%.[^%.]+$") or base_name
    local ext

    if publication_link and publication_link.type then
        ext = DocumentRegistry:mimeToExt(publication_link.type)
    end
    if not ext and publication_link and publication_link.href then
        ext = util.getFileNameSuffix(publication_link.href)
    end
    ext = ext and ext:lower() or "epub"

    return folder .. filename .. ".lcp." .. ext
end

-- Derives the final decrypted output path from the encrypted intermediate path.
-- e.g. /path/book.lcp.epub → /path/book.epub
function Lcpl:_deriveDecryptedFile(lcp_path)
    return lcp_path:gsub("%.lcp%.", ".")
end

function Lcpl:_downloadFile(local_path, remote_url)
    local file_handle, err = io.open(local_path, "wb")
    if not file_handle then
        logger.warn("LCPL: could not open file for writing", local_path, err)
        return false, err or "cannot open file"
    end

    local sink = ltn12.sink.file(file_handle)
    local ok, res, code, headers, status

    socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
    ok, res, code, headers, status = pcall(http.request, {
        url = remote_url,
        headers = {
            ["Accept-Encoding"] = "identity",
        },
        sink = sink,
    })
    socketutil:reset_timeout()

    if not ok then
        sink(nil) -- make sure the file handle is closed on error
        util.removeFile(local_path)
        logger.warn("LCPL: publication download request failed", res)
        return false, res
    end

    if code == 200 then
        return true
    end

    util.removeFile(local_path)
    logger.warn("LCPL: publication download failed", status or code, headers)
    return false, status or code
end

function Lcpl:_showPassphrasePrompt(license_doc, callback)
    local hint = util.tableGetValue(license_doc, "encryption", "user_key", "text_hint")

    local dialog
    dialog = InputDialog:new{
        title = _("LCP passphrase"),
        description = hint and T(_("Hint: %1"), hint) or nil,
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Continue"),
                    callback = function()
                        local passphrase = dialog:getInputText()
                        UIManager:close(dialog)
                        callback(passphrase)
                    end,
                },
            },
        },
        text_type = "password",
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- ---------------------------------------------------------------------------
-- Status + registration helpers
-- ---------------------------------------------------------------------------

--- Fetch status doc and check / register.  Returns false + err when the caller should abort.
--- On non-fatal errors (e.g. no status link, network timeout) returns true to allow offline use.
local function doStatusCheck(license_doc)
    local LcpStatus = require("lcp_status")
    local status_doc, fetch_err = LcpStatus.fetchStatusDoc(license_doc)
    if not status_doc then
        -- No status link or network error — warn but do not block.
        logger.warn("LCP: could not fetch status doc:", fetch_err)
        return true, nil, nil
    end

    local ok, check_err = LcpStatus.checkStatus(status_doc)
    if not ok then
        return false, check_err, nil
    end

    local reg_ok, reg_err = LcpStatus.registerDevice(license_doc, status_doc)
    if not reg_ok then
        return false, reg_err, nil
    end

    return true, nil, status_doc
end

-- ---------------------------------------------------------------------------
-- Common decrypt+open flow (used by both .lcpl and embedded-EPUB paths)
-- ---------------------------------------------------------------------------

--- Full passphrase-verification and open flow, called after we have a license_doc.
--- `on_verified` is called with (user_key) when the key is confirmed good.
local function verifyKey(license_doc, user_key, on_verified)
    local LcpDecrypt = require("lcp_decrypt")
    local pass_ok, pass_err = LcpDecrypt.verifyPassphrase(license_doc, user_key)
    if not pass_ok then
        UIManager:show(InfoMessage:new{
            text = T(_("Wrong passphrase: %1"), pass_err or "verification failed"),
        })
        return
    end
    on_verified(user_key)
end

-- ---------------------------------------------------------------------------
-- openFile  — main entry point
-- ---------------------------------------------------------------------------

function Lcpl:openFile(file)
    if not isCryptoAvailable() then
        UIManager:show(InfoMessage:new{
            text = _("LCP decryption is not available on this device (libcrypto not found)."),
        })
        return
    end

    local ext = util.getFileNameSuffix(file):lower()
    local is_epub = (ext == "epub")

    -- -----------------------------------------------------------------------
    -- Step 1: Obtain the license document
    -- -----------------------------------------------------------------------
    local license_doc

    if is_epub then
        local LcpDecrypt = require("lcp_decrypt")
        local lic, lic_err = LcpDecrypt.extractLicenseFromEpub(file)
        if not lic then
            -- No LCP license inside — open directly as a normal EPUB.
            logger.dbg("LCP: no embedded license in EPUB:", lic_err)
            local ReaderUI = require("apps/reader/readerui")
            ReaderUI:showReader(file)
            return
        end
        license_doc = lic
    else
        local content = util.readFromFile(file, "rb")
        if not content then
            UIManager:show(InfoMessage:new{ text = _("Unable to read LCPL file.") })
            return
        end
        local ok, doc = pcall(JSON.decode, content)
        if not ok or type(doc) ~= "table" then
            UIManager:show(InfoMessage:new{ text = _("Invalid LCPL license file.") })
            return
        end
        license_doc = doc
    end

    -- -----------------------------------------------------------------------
    -- Step 2–3: Status document fetch + check
    -- -----------------------------------------------------------------------
    local status_proceed, status_err = doStatusCheck(license_doc)
    if not status_proceed then
        UIManager:show(InfoMessage:new{
            text = T(_("LCP license error: %1"), status_err or "unknown"),
        })
        return
    end

    -- -----------------------------------------------------------------------
    -- Step 4: Rights date check (before passphrase prompt for fast fail)
    -- -----------------------------------------------------------------------
    local LcpRights = require("lcp_rights")
    local rights_ok, rights_err = LcpRights.checkDateRights(license_doc)
    if not rights_ok then
        UIManager:show(InfoMessage:new{
            text = T(_("LCP rights error: %1"), rights_err or "unknown"),
        })
        return
    end

    -- -----------------------------------------------------------------------
    -- Step 5: Key resolution (cache or passphrase prompt)
    -- -----------------------------------------------------------------------
    local cached_key = self:_loadCachedKey(license_doc)
    if cached_key then
        -- Fast path: skip prompt and jump straight to decryption.
        self:_continueWithKey(file, license_doc, cached_key, is_epub)
    else
        self:_showPassphrasePrompt(license_doc, function(passphrase)
            if not passphrase or passphrase == "" then
                UIManager:show(InfoMessage:new{
                    text = _("A passphrase is required to open LCP content."),
                })
                return
            end

            local LcpDecrypt = require("lcp_decrypt")
            local user_key, key_err = LcpDecrypt.deriveUserKey(passphrase)
            if not user_key then
                UIManager:show(InfoMessage:new{
                    text = T(_("Key derivation failed: %1"), key_err or ""),
                })
                return
            end

            verifyKey(license_doc, user_key, function(verified_key)
                self:_saveCachedKey(license_doc, verified_key)
                self:_continueWithKey(file, license_doc, verified_key, is_epub)
            end)
        end)
    end
end

-- Write data to path, silently skipping on error (sidecar write is best-effort).
local function writeSidecar(path, data)
    if not data or data == "" then return end
    local f = io.open(path, "wb")
    if f then
        f:write(data)
        f:close()
    end
end

--- Decrypt an embedded LCP EPUB in-place and open it in the reader.
function Lcpl:_decryptEmbeddedEpub(file, license_doc, user_key)
    local LcpDecrypt = require("lcp_decrypt")

    UIManager:show(InfoMessage:new{ text = _("Decrypting LCP EPUB…"), timeout = 1 })

    local content_key, ck_err = LcpDecrypt.decryptContentKey(license_doc, user_key)
    if not content_key then
        UIManager:show(InfoMessage:new{
            text = T(_("Could not extract content key: %1"), ck_err or ""),
        })
        return
    end

    local tmp_path = file .. ".lcp_tmp.epub"
    local dec_ok, dec_err = LcpDecrypt.decryptEpub(file, content_key, tmp_path)
    if not dec_ok then
        util.removeFile(tmp_path)
        UIManager:show(InfoMessage:new{ text = T(_("Decryption failed: %1"), dec_err or "") })
        return
    end

    local rename_ok, rename_err = os.rename(tmp_path, file)
    if not rename_ok then
        util.removeFile(tmp_path)
        UIManager:show(InfoMessage:new{
            text = T(_("Could not replace EPUB file: %1"), rename_err or ""),
        })
        return
    end

    -- Write a .lcpl sidecar so onReaderReady can attach rights/renew/return hooks.
    writeSidecar(file .. ".lcpl", JSON.encode(license_doc))

    local ReaderUI = require("apps/reader/readerui")
    ReaderUI:showReader(file)
end

--- Show the download confirmation dialog, then download, decrypt, and open the publication.
function Lcpl:_downloadAndDecryptLcpl(file, license_doc, user_key)
    local LcpDecrypt = require("lcp_decrypt")

    local publication_link = self:_findLink(license_doc, "publication")
    if not publication_link or not publication_link.href then
        UIManager:show(InfoMessage:new{ text = _("No publication link found in LCPL file.") })
        return
    end

    local parsed = url.parse(publication_link.href)
    if not parsed or (parsed.scheme ~= "http" and parsed.scheme ~= "https") then
        UIManager:show(InfoMessage:new{ text = _("Unsupported publication URL in LCPL file.") })
        return
    end

    local lcp_path       = self:_deriveEncryptedFile(file, publication_link)
    local decrypted_path = self:_deriveDecryptedFile(lcp_path)
    local title = license_doc.id
        and T(_("Download publication for license %1?"), license_doc.id)
        or _("Download protected publication now?")

    UIManager:show(ConfirmBox:new{
        text     = title .. "\n\n" .. BD.filepath(decrypted_path),
        ok_text  = _("Download"),
        ok_callback = function()
            NetworkMgr:runWhenConnected(function()
                UIManager:show(InfoMessage:new{
                    text = _("Downloading LCP publication…"), timeout = 1,
                })

                local success, dl_err = self:_downloadFile(lcp_path, publication_link.href)
                if not success then
                    UIManager:show(InfoMessage:new{
                        text = T(_("Could not download protected publication: %1"),
                            dl_err or "network unreachable"),
                    })
                    return
                end

                UIManager:show(InfoMessage:new{ text = _("Decrypting…"), timeout = 1 })

                local content_key, ck_err = LcpDecrypt.decryptContentKey(license_doc, user_key)
                if not content_key then
                    util.removeFile(lcp_path)
                    UIManager:show(InfoMessage:new{
                        text = T(_("Could not extract content key: %1"), ck_err or ""),
                    })
                    return
                end

                local dec_ok, dec_err = LcpDecrypt.decryptEpub(lcp_path, content_key, decrypted_path)
                util.removeFile(lcp_path)

                if not dec_ok then
                    UIManager:show(InfoMessage:new{
                        text = T(_("Decryption failed: %1"), dec_err or ""),
                    })
                    return
                end

                -- Write the original license JSON as a .lcpl sidecar.
                writeSidecar(decrypted_path .. ".lcpl", util.readFromFile(file, "rb"))

                local ReaderUI = require("apps/reader/readerui")
                ReaderUI:showReader(decrypted_path)
            end)
        end,
    })
end

--- Called once we have a verified user key. Dispatches to the appropriate flow.
function Lcpl:_continueWithKey(file, license_doc, user_key, is_epub)
    require("lcp_rights").initCopyRights(license_doc)  -- seed copy counter (idempotent)
    if is_epub then
        self:_decryptEmbeddedEpub(file, license_doc, user_key)
    else
        self:_downloadAndDecryptLcpl(file, license_doc, user_key)
    end
end

-- ---------------------------------------------------------------------------
-- Reader module hooks (renew/return menu + copy-count enforcement)
-- ---------------------------------------------------------------------------

-- Holds state valid for the lifetime of the currently-open document.
local _current_license_doc = nil
local _current_license_id  = nil
local _orig_setClipboardText = nil  -- saved original, used to restore on close

local function loadSidecarLicense(doc_path)
    local sidecar = doc_path .. ".lcpl"
    local content = util.readFromFile(sidecar, "rb")
    if not content then return nil end
    local ok, doc = pcall(JSON.decode, content)
    if ok and type(doc) == "table" then return doc end
    return nil
end

function Lcpl:onReaderReady()
    _current_license_doc = nil
    _current_license_id  = nil

    local doc_path = self.ui and self.ui.document and self.ui.document.file
    if not doc_path then return end

    local license_doc = loadSidecarLicense(doc_path)
    if not license_doc then return end

    _current_license_doc = license_doc
    _current_license_id  = license_doc.id

    -- Intercept clipboard copy to enforce copy-count rights.
    if _current_license_id and Device.input and Device.input.setClipboardText then
        local orig = Device.input.setClipboardText
        _orig_setClipboardText = orig
        local license_id = _current_license_id  -- capture for closure
        local LcpRights = require("lcp_rights")
        Device.input.setClipboardText = function(text)
            if type(text) == "string" and #text > 0 then
                local ok, err = LcpRights.decrementCopy(license_id, #text)
                if not ok then
                    UIManager:show(InfoMessage:new{
                        text = T(_("LCP copy limit reached: %1"), err or ""),
                    })
                    return  -- block the copy
                end
            end
            return orig(text)
        end
    end
end

function Lcpl:onCloseDocument()
    -- Restore original clipboard function.
    if _orig_setClipboardText and Device.input then
        Device.input.setClipboardText = _orig_setClipboardText
        _orig_setClipboardText = nil
    end
    _current_license_doc = nil
    _current_license_id  = nil
end

function Lcpl:addToMainMenu(menu_items)
    menu_items.lcp_license = {
        text = _("LCP License"),
        sorting_hint = "book",
        sub_item_table = {
            {
                text = _("Renew license"),
                keep_menu_open = false,
                callback = function()
                    if not _current_license_doc then
                        UIManager:show(InfoMessage:new{
                            text = _("No LCP license information available."),
                        })
                        return
                    end
                    NetworkMgr:runWhenConnected(function()
                        local LcpStatus = require("lcp_status")
                        local status_doc, fetch_err = LcpStatus.fetchStatusDoc(_current_license_doc)
                        if not status_doc then
                            UIManager:show(InfoMessage:new{
                                text = T(_("Could not fetch license status: %1"), fetch_err or ""),
                            })
                            return
                        end
                        local ok, err = LcpStatus.renewLicense(status_doc)
                        if ok then
                            UIManager:show(InfoMessage:new{
                                text = _("License renewed successfully."),
                            })
                        else
                            UIManager:show(InfoMessage:new{
                                text = T(_("Renew failed: %1"), err or ""),
                            })
                        end
                    end)
                end,
            },
            {
                text = _("Return content"),
                keep_menu_open = false,
                callback = function()
                    if not _current_license_doc then
                        UIManager:show(InfoMessage:new{
                            text = _("No LCP license information available."),
                        })
                        return
                    end
                    UIManager:show(ConfirmBox:new{
                        text = _("Return this content to the library? The file will be deleted."),
                        ok_text = _("Return"),
                        ok_callback = function()
                            NetworkMgr:runWhenConnected(function()
                                local LcpStatus = require("lcp_status")
                                local status_doc, fetch_err = LcpStatus.fetchStatusDoc(_current_license_doc)
                                if not status_doc then
                                    UIManager:show(InfoMessage:new{
                                        text = T(_("Could not fetch license status: %1"), fetch_err or ""),
                                    })
                                    return
                                end
                                local ok, err = LcpStatus.returnContent(status_doc)
                                if not ok then
                                    UIManager:show(InfoMessage:new{
                                        text = T(_("Return failed: %1"), err or ""),
                                    })
                                    return
                                end

                                -- Close reader and delete the file.
                                local doc_path = self.ui and self.ui.document and self.ui.document.file
                                self.ui:onClose()
                                if doc_path then
                                    util.removeFile(doc_path)
                                    util.removeFile(doc_path .. ".lcpl")
                                end
                            end)
                        end,
                    })
                end,
            },
        },
    }
end

return Lcpl
