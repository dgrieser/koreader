describe("document registry module", function()
    local DocSettings, DocumentRegistry

    setup(function()
        require("commonrequire")
        DocSettings = require("docsettings")
        DocumentRegistry = require("document/documentregistry")
    end)

    it("should get preferred rendering engine", function()
        assert.is_equal("crengine",
                        DocumentRegistry:getProvider("bla.epub").provider)
        assert.is_equal("mupdf",
                        DocumentRegistry:getProvider("bla.pdf").provider)
    end)

    it("should return all supported rendering engines", function()
        local providers = DocumentRegistry:getProviders("bla.epub")
        assert.is_equal("crengine",
                        providers[1].provider.provider)
        assert.is_equal("mupdf",
                        providers[2].provider.provider)
    end)

    it("should set per-document setting for rendering engine", function()
        local path = "../../foo.epub"
        local pdf_provider = DocumentRegistry:getProvider("bla.pdf")
        DocumentRegistry:setProvider(path, pdf_provider, false)

        local provider = DocumentRegistry:getProvider(path)

        assert.is_equal("mupdf", provider.provider)

        local docsettings = DocSettings:open(path)
        docsettings:purge()
    end)
    it("should set global setting for rendering engine", function()
        local path = "../../foo.fb2"
        local pdf_provider = DocumentRegistry:getProvider("bla.pdf")
        DocumentRegistry:setProvider(path, pdf_provider, true)

        local provider = DocumentRegistry:getProvider(path)

        assert.is_equal("mupdf", provider.provider)

        G_reader_settings:delSetting("provider")
    end)

    it("should return per-document setting for rendering engine", function()
        local path = "../../foofoo.epub"
        local docsettings = DocSettings:open(path)
        docsettings:saveSetting("provider", "mupdf")
        docsettings:flush()

        local provider = DocumentRegistry:getProvider(path)

        assert.is_equal("mupdf", provider.provider)

        docsettings:purge()
    end)
    it("should return global setting for rendering engine", function()
        local path = "../../foofoo.fb2"
        local provider_setting = {}
        provider_setting.fb2 = "mupdf"
        G_reader_settings:saveSetting("provider", provider_setting)

        local provider = DocumentRegistry:getProvider(path)

        assert.is_equal("mupdf", provider.provider)

        G_reader_settings:delSetting("provider")
    end)

    it("should register and resolve auxiliary provider by extension only when include_aux is true", function()
        local provider_key = "spec_aux_provider"
        local extension = "specaux"
        local backup_known = DocumentRegistry.known_providers[provider_key]
        local backup_aux = DocumentRegistry.aux_filetype_provider[extension]
        local backup_filetype = DocumentRegistry.filetype_provider[extension]

        DocumentRegistry:addAuxProvider({
            provider_name = "Spec Aux Provider",
            provider = provider_key,
            order = 999,
            extensions = { extension },
            disable_file = true,
            disable_type = false,
        })

        assert.is_false(DocumentRegistry:hasProvider("dummy." .. extension))
        assert.is_true(DocumentRegistry:hasProvider("dummy." .. extension, nil, true))

        local provider = DocumentRegistry:getProvider("dummy." .. extension, true)
        assert.is_not_nil(provider)
        assert.is_equal(provider_key, provider.provider)

        DocumentRegistry.known_providers[provider_key] = backup_known
        DocumentRegistry.aux_filetype_provider[extension] = backup_aux
        DocumentRegistry.filetype_provider[extension] = backup_filetype
    end)

    it("should keep auxiliary extension unsupported when include_aux is false", function()
        local provider_key = "spec_aux_provider_2"
        local extension = "specaux2"
        local backup_known = DocumentRegistry.known_providers[provider_key]
        local backup_aux = DocumentRegistry.aux_filetype_provider[extension]
        local backup_filetype = DocumentRegistry.filetype_provider[extension]

        DocumentRegistry:addAuxProvider({
            provider_name = "Spec Aux Provider 2",
            provider = provider_key,
            order = 998,
            extensions = { extension },
            disable_file = true,
            disable_type = false,
        })

        assert.is_false(DocumentRegistry:hasProvider("dummy." .. extension))
        assert.is_nil(DocumentRegistry:getProvider("dummy." .. extension))

        DocumentRegistry.known_providers[provider_key] = backup_known
        DocumentRegistry.aux_filetype_provider[extension] = backup_aux
        DocumentRegistry.filetype_provider[extension] = backup_filetype
    end)
end)
