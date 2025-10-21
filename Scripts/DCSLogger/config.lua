local lfs = require('lfs')

local config = {}

local defaults = {
    outputDirectory = 'Logs\\DCSLogger\\',
    samplingRateHz = 0, -- 0 means capture every export frame (Tacview-style)
    includeExtendedTelemetry = true,
    flushIntervalSeconds = 1,
    recorderName = 'DCSLogger 0.1.0',
}

local state = {
    settings = nil,
}

local function mergeDefaults(overrides)
    local result = {}
    for key, value in pairs(defaults) do
        result[key] = value
    end

    if type(overrides) == 'table' then
        for key, value in pairs(overrides) do
            result[key] = value
        end
    end

    return result
end

local function loadOverrides()
    local overridesPath = lfs.writedir() .. 'Config\\DCSLoggerConfig.lua'
    local ok, overrides = pcall(dofile, overridesPath)
    if ok and type(overrides) == 'table' then
        return overrides
    end

    return nil
end

function config.load()
    if state.settings then
        return state.settings
    end

    local overrides = loadOverrides()
    state.settings = mergeDefaults(overrides)
    return state.settings
end

function config.get()
    return config.load()
end

return config
