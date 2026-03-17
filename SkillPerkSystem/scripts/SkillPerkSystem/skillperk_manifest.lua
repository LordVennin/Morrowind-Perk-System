local function register(api)
    api.assertCompatibleApiVersion(1)
end

return {
    register = register,
    modules = {},
}
