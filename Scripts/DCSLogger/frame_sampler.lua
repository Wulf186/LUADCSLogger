local sampler = {}

local state = {
    config = nil,
    registry = nil,
    writer = nil,
    lastSampleTime = nil,
    sampleInterval = 0,
}

local function computeSampleInterval(config)
    local rate = config and config.samplingRateHz or 0
    if not rate or rate <= 0 then
        return 0 -- capture every export frame (matches Tacview behaviour)
    end

    return 1 / rate
end

local function writerAvailable()
    if not state.writer then
        return false
    end

    local isOpenFunc = state.writer.isOpen
    if type(isOpenFunc) ~= 'function' then
        return false
    end

    local ok, result = pcall(isOpenFunc)
    if not ok then
        return false
    end

    return result and true or false
end

function sampler.init(config, registryModule, writerModule)
    state.config = config
    state.registry = registryModule
    state.writer = writerModule
    state.sampleInterval = computeSampleInterval(config)
    state.lastSampleTime = nil
end

function sampler.tick(simTime, realClock)
    if not writerAvailable() then
        return
    end

    local now = simTime or 0
    if state.lastSampleTime
        and state.sampleInterval > 0
        and (now - state.lastSampleTime) < state.sampleInterval then
        state.writer.maybeFlush(realClock or os.clock())
        return
    end

    state.lastSampleTime = now

    -- TODO: collect object snapshots from registry and serialize them.
    state.writer.appendFrame(now, nil)
    state.writer.maybeFlush(realClock or os.clock())
end

function sampler.shutdown()
    state.config = nil
    state.registry = nil
    state.writer = nil
    state.lastSampleTime = nil
    state.sampleInterval = 0
end

return sampler
