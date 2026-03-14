-- FFI bindings to OpenSSL libcrypto for AES-256-CBC decryption and SHA-256 hashing.
local ffi = require("ffi")
require("ffi/loadlib")

-- Try to load libcrypto (OpenSSL is bundled via LuaSec).
local libcrypto
do
    local ok, err = pcall(ffi.load, "crypto")
    if ok then
        libcrypto = err
    else
        ok, err = pcall(ffi.load, "libcrypto.so.1.1")
        if ok then
            libcrypto = err
        else
            ok, err = pcall(ffi.load, "libcrypto.so.1.0.0")
            if ok then
                libcrypto = err
            else
                error("LCP: could not load libcrypto: " .. tostring(err))
            end
        end
    end
end

-- Guard ffi.cdef against duplicate definitions (e.g. if another module already loaded these).
local ok_cdef, cdef_err = pcall(ffi.cdef, [[
    typedef struct evp_cipher_ctx_st EVP_CIPHER_CTX;
    typedef struct evp_cipher_st     EVP_CIPHER;
    typedef struct env_md_ctx_st     EVP_MD_CTX;
    typedef struct env_md_st         EVP_MD;

    EVP_CIPHER_CTX *EVP_CIPHER_CTX_new(void);
    void            EVP_CIPHER_CTX_free(EVP_CIPHER_CTX *ctx);
    const EVP_CIPHER *EVP_aes_256_cbc(void);
    int EVP_DecryptInit_ex(EVP_CIPHER_CTX *, const EVP_CIPHER *, void *,
                           const unsigned char *, const unsigned char *);
    int EVP_DecryptUpdate(EVP_CIPHER_CTX *, unsigned char *, int *,
                          const unsigned char *, int);
    int EVP_DecryptFinal_ex(EVP_CIPHER_CTX *, unsigned char *, int *);

    EVP_MD_CTX *EVP_MD_CTX_new(void);
    void        EVP_MD_CTX_free(EVP_MD_CTX *ctx);
    const EVP_MD *EVP_sha256(void);
    int EVP_DigestInit_ex(EVP_MD_CTX *, const EVP_MD *, void *);
    int EVP_DigestUpdate(EVP_MD_CTX *, const void *, size_t);
    int EVP_DigestFinal_ex(EVP_MD_CTX *, unsigned char *, unsigned int *);
]])
if not ok_cdef and not tostring(cdef_err):find("redefine") then
    error("LCP: ffi.cdef failed: " .. tostring(cdef_err))
end

local LcpCrypto = {}

--- Compute SHA-256 of a binary string.
--- @param data string  raw bytes
--- @return string|nil  32-byte binary digest, or nil + error string
function LcpCrypto.sha256(data)
    local ctx = libcrypto.EVP_MD_CTX_new()
    if ctx == nil then return nil, "EVP_MD_CTX_new failed" end
    ffi.gc(ctx, libcrypto.EVP_MD_CTX_free)

    if libcrypto.EVP_DigestInit_ex(ctx, libcrypto.EVP_sha256(), nil) ~= 1 then
        return nil, "EVP_DigestInit_ex failed"
    end
    if libcrypto.EVP_DigestUpdate(ctx, data, #data) ~= 1 then
        return nil, "EVP_DigestUpdate failed"
    end

    local out = ffi.new("unsigned char[32]")
    local outlen = ffi.new("unsigned int[1]", 32)
    if libcrypto.EVP_DigestFinal_ex(ctx, out, outlen) ~= 1 then
        return nil, "EVP_DigestFinal_ex failed"
    end

    return ffi.string(out, 32)
end

--- AES-256-CBC decrypt.
--- @param key_bytes  string  32-byte raw key
--- @param iv_bytes   string  16-byte raw IV
--- @param ciphertext string  ciphertext (must be a multiple of 16 bytes)
--- @return string|nil  plaintext with PKCS#7 padding stripped, or nil + error string
function LcpCrypto.aes256cbc_decrypt(key_bytes, iv_bytes, ciphertext)
    local ctx = libcrypto.EVP_CIPHER_CTX_new()
    if ctx == nil then return nil, "EVP_CIPHER_CTX_new failed" end
    ffi.gc(ctx, libcrypto.EVP_CIPHER_CTX_free)

    local key_ptr = ffi.cast("const unsigned char *", key_bytes)
    local iv_ptr  = ffi.cast("const unsigned char *", iv_bytes)

    if libcrypto.EVP_DecryptInit_ex(ctx, libcrypto.EVP_aes_256_cbc(), nil, key_ptr, iv_ptr) ~= 1 then
        return nil, "EVP_DecryptInit_ex failed"
    end

    local clen   = #ciphertext
    local outbuf = ffi.new("unsigned char[?]", clen + 16) -- one extra block for final
    local outlen = ffi.new("int[1]", 0)
    local finlen = ffi.new("int[1]", 0)

    local cipher_ptr = ffi.cast("const unsigned char *", ciphertext)
    if libcrypto.EVP_DecryptUpdate(ctx, outbuf, outlen, cipher_ptr, clen) ~= 1 then
        return nil, "EVP_DecryptUpdate failed"
    end

    local written = outlen[0]
    if libcrypto.EVP_DecryptFinal_ex(ctx, outbuf + written, finlen) ~= 1 then
        return nil, "wrong passphrase or corrupted data"
    end
    written = written + finlen[0]

    return ffi.string(outbuf, written)
end

return LcpCrypto
