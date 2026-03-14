-- LCP (Readium Licensed Content Protection) decryption orchestration.
-- Implements the full decryption pipeline: user key derivation, passphrase
-- verification, content key extraction, and per-resource decryption.
local Archiver  = require("ffi/archiver")
local LcpCrypto = require("lcp_crypto")
local Utf8Proc  = require("ffi/utf8proc")
local logger    = require("logger")
local mime      = require("mime")
local url_mod   = require("socket.url")
local util      = require("util")

local LcpDecrypt = {}

--- Derive the user key from a passphrase.
--- LCP spec: user_key = SHA-256(UTF-8-NFC-normalise(passphrase))
--- @param passphrase string
--- @return string|nil  32-byte binary key, or nil + error string
function LcpDecrypt.deriveUserKey(passphrase)
    local normalized = Utf8Proc.normalize_NFC(passphrase)
    return LcpCrypto.sha256(normalized)
end

--- Verify the passphrase against the license's key_check field.
--- Returns true immediately when no key_check is present (older licenses).
--- @param license_doc table  parsed license JSON
--- @param user_key    string 32-byte binary user key
--- @return boolean, string|nil  true on success; false + reason on failure
function LcpDecrypt.verifyPassphrase(license_doc, user_key)
    local key_check_b64 = util.tableGetValue(
        license_doc, "encryption", "user_key", "key_check")
    if not key_check_b64 then
        -- No key_check present; proceed without verification.
        return true
    end

    local key_check = mime.unb64(key_check_b64)
    if not key_check or #key_check < 17 then
        return false, "malformed key_check in license"
    end

    local iv         = key_check:sub(1, 16)
    local ciphertext = key_check:sub(17)

    local decrypted, err = LcpCrypto.aes256cbc_decrypt(user_key, iv, ciphertext)
    if not decrypted then
        logger.dbg("LCP: key_check decryption failed:", err)
        return false, "wrong passphrase"
    end

    -- The decrypted value must equal SHA-256(license.id).
    local license_id = license_doc.id or ""
    local expected, sha_err = LcpCrypto.sha256(license_id)
    if not expected then
        return false, sha_err
    end

    if decrypted ~= expected then
        return false, "wrong passphrase"
    end
    return true
end

--- Decrypt the content key using the user key.
--- @param license_doc table  parsed license JSON
--- @param user_key    string 32-byte binary user key
--- @return string|nil  32-byte binary content key, or nil + error string
function LcpDecrypt.decryptContentKey(license_doc, user_key)
    local enc_val_b64 = util.tableGetValue(
        license_doc, "encryption", "content_key", "encrypted_value")
    if not enc_val_b64 then
        return nil, "no content_key.encrypted_value in license"
    end

    local enc_val = mime.unb64(enc_val_b64)
    if not enc_val or #enc_val < 17 then
        return nil, "malformed content_key.encrypted_value"
    end

    local iv         = enc_val:sub(1, 16)
    local ciphertext = enc_val:sub(17)
    return LcpCrypto.aes256cbc_decrypt(user_key, iv, ciphertext)
end

--- Parse META-INF/encryption.xml and return a set of encrypted resource paths.
--- Returns a table keyed by (percent-decoded) ZIP entry path → true.
--- @param xml_str string  content of encryption.xml
--- @return table
function LcpDecrypt.parseEncryptionXml(xml_str)
    local encrypted = {}
    -- Match only opening CipherReference elements, optionally namespace-prefixed (e.g. enc:CipherReference).
    for tag in xml_str:gmatch("<[%w:]*CipherReference[^>]*>") do
        local uri = tag:match('URI="([^"]*)"') or tag:match("URI='([^']*)'")
        if uri then
            -- ZIP entry paths are not percent-encoded; decode the URI for comparison.
            encrypted[url_mod.unescape(uri)] = true
        end
    end
    return encrypted
end

--- Decrypt an LCP-protected EPUB and write a plain EPUB to output_path.
--- @param lcp_epub_path string  path to the encrypted publication
--- @param content_key   string  32-byte binary content key
--- @param output_path   string  destination path for the decrypted EPUB
--- @return boolean|nil  true on success, or nil + error string
function LcpDecrypt.decryptEpub(lcp_epub_path, content_key, output_path)
    local arc = Archiver.Reader:new()
    if not arc:open(lcp_epub_path) then
        return nil, "could not open encrypted EPUB: " .. lcp_epub_path
    end

    -- Obtain the list of encrypted resources from META-INF/encryption.xml.
    local enc_xml = arc:extractToMemory("META-INF/encryption.xml")
    if not enc_xml then
        return nil, "META-INF/encryption.xml not found in LCP epub"
    end
    local encrypted_files = LcpDecrypt.parseEncryptionXml(enc_xml)

    -- Open the output EPUB for writing.
    local writer = Archiver.Writer:new{}
    if not writer:open(output_path, "epub") then
        return nil, "could not create output EPUB: " .. output_path
    end

    local mtime = os.time()

    -- EPUB spec: "mimetype" must be the first entry and stored uncompressed.
    -- Extract it by name directly — same pattern already used for encryption.xml above.
    local mimetype_data = arc:extractToMemory("mimetype")
    if mimetype_data then
        writer:setZipCompression("store")
        writer:addFileFromMemory("mimetype", mimetype_data, mtime)
    end

    -- Iterate entries one at a time, processing and writing each immediately.
    -- This keeps only one entry in memory at a time instead of buffering the whole archive.
    writer:setZipCompression("deflate")
    local ok_all, fail_reason = true, nil
    for entry in arc:iterate() do
        if entry.mode == "file" then
            local path = entry.path
            -- Skip mimetype (already written) and encryption.xml (omitted from output).
            if path ~= "mimetype" and path ~= "META-INF/encryption.xml" then
                local data = arc:extractToMemory(path)
                if data then
                    if encrypted_files[path] then
                        -- LCP-encrypted resource: IV is the first 16 bytes.
                        if #data < 17 then
                            ok_all = false
                            fail_reason = "encrypted entry too short: " .. path
                            break
                        end
                        local iv         = data:sub(1, 16)
                        local ciphertext = data:sub(17)
                        local plaintext, dec_err = LcpCrypto.aes256cbc_decrypt(
                            content_key, iv, ciphertext)
                        if not plaintext then
                            ok_all = false
                            fail_reason = "decryption failed for " .. path .. ": " .. (dec_err or "")
                            break
                        end
                        writer:addFileFromMemory(path, plaintext, mtime)
                    else
                        -- Non-encrypted resource: copy verbatim.
                        writer:addFileFromMemory(path, data, mtime)
                    end
                end
            end
        end
    end

    writer:close()

    if not ok_all then
        util.removeFile(output_path)
        return nil, fail_reason
    end

    return true
end

return LcpDecrypt
