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
local socket = require("socket")
local socketutil = require("socketutil")
local url = require("socket.url")
local util = require("util")

local _ = require("gettext")
local T = require("ffi/util").template

local Lcpl = WidgetContainer:extend{
    name = "lcpl",
    is_doc_only = false,
}


function Lcpl:init()
    if not Device:isKindle() then
        return
    end
    DocumentRegistry:addAuxProvider({
        provider_name = _("CARE DRM (LCPL)"),
        provider = self.name,
        order = 10,
        extensions = { "lcpl" },
        disable_file = true,
        disable_type = false,
    })
end

function Lcpl:isFileTypeSupported(file)
    return util.getFileNameSuffix(file):lower() == "lcpl"
end

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

function Lcpl:openFile(file)
    if not Device:isKindle() then
        UIManager:show(InfoMessage:new{ text = _("LCPL support is currently implemented for Kindle only.") })
        return
    end

    local content = util.readFromFile(file, "rb")
    if not content then
        UIManager:show(InfoMessage:new{ text = _("Unable to read LCPL file.") })
        return
    end

    local ok, license_doc = pcall(JSON.decode, content)
    if not ok or type(license_doc) ~= "table" then
        UIManager:show(InfoMessage:new{ text = _("Invalid LCPL license file.") })
        return
    end

    local publication_link = self:_findLink(license_doc, "publication")
    if not publication_link or not publication_link.href then
        UIManager:show(InfoMessage:new{ text = _("No publication link found in LCPL file.") })
        return
    end

    -- Prompt for passphrase first so we can fail fast before any download.
    self:_showPassphrasePrompt(license_doc, function(passphrase)
        if not passphrase or passphrase == "" then
            UIManager:show(InfoMessage:new{ text = _("A passphrase is required to open LCP content.") })
            return
        end

        local parsed = url.parse(publication_link.href)
        if not parsed or (parsed.scheme ~= "http" and parsed.scheme ~= "https") then
            UIManager:show(InfoMessage:new{ text = _("Unsupported publication URL in LCPL file.") })
            return
        end

        -- Derive the user key and verify the passphrase before downloading.
        local LcpDecrypt = require("lcp_decrypt")
        local user_key, key_err = LcpDecrypt.deriveUserKey(passphrase)
        if not user_key then
            UIManager:show(InfoMessage:new{ text = T(_("Key derivation failed: %1"), key_err or "") })
            return
        end

        local pass_ok, pass_err = LcpDecrypt.verifyPassphrase(license_doc, user_key)
        if not pass_ok then
            UIManager:show(InfoMessage:new{
                text = T(_("Wrong passphrase: %1"), pass_err or "verification failed"),
            })
            return
        end

        local lcp_path      = self:_deriveEncryptedFile(file, publication_link)
        local decrypted_path = self:_deriveDecryptedFile(lcp_path)
        local title = license_doc.id and T(_("Download publication for license %1?"), license_doc.id)
            or _("Download protected publication now?")

        UIManager:show(ConfirmBox:new{
            text = title .. "\n\n" .. BD.filepath(decrypted_path),
            ok_text = _("Download"),
            ok_callback = function()
                NetworkMgr:runWhenConnected(function()
                    UIManager:show(InfoMessage:new{
                        text = _("Downloading LCP publication…"),
                        timeout = 1,
                    })

                    local success, dl_err = self:_downloadFile(lcp_path, publication_link.href)
                    if not success then
                        UIManager:show(InfoMessage:new{
                            text = T(_("Could not download protected publication: %1"),
                                dl_err or "network unreachable"),
                        })
                        return
                    end

                    UIManager:show(InfoMessage:new{
                        text = _("Decrypting…"),
                        timeout = 1,
                    })

                    -- Derive the content key and decrypt the EPUB.
                    local content_key, ck_err = LcpDecrypt.decryptContentKey(license_doc, user_key)
                    if not content_key then
                        util.removeFile(lcp_path)
                        UIManager:show(InfoMessage:new{
                            text = T(_("Could not extract content key: %1"), ck_err or ""),
                        })
                        return
                    end

                    local dec_ok, dec_err = LcpDecrypt.decryptEpub(lcp_path, content_key, decrypted_path)
                    -- Remove the intermediate encrypted file regardless of outcome.
                    util.removeFile(lcp_path)

                    if not dec_ok then
                        UIManager:show(InfoMessage:new{
                            text = T(_("Decryption failed: %1"), dec_err or ""),
                        })
                        return
                    end

                    -- Open the decrypted EPUB.
                    local ReaderUI = require("apps/reader/readerui")
                    ReaderUI:showReader(decrypted_path)
                end)
            end,
        })
    end)
end

return Lcpl
