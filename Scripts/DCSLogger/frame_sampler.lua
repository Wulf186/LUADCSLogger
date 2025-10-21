local sampler = {}

local dcsLog = log
local LOG_ERROR = dcsLog and dcsLog.ERROR or 1
local TAG = 'DCSLOGGER.SAMPLER'

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

local function safeLog(level, message)
    if dcsLog and dcsLog.write then
        dcsLog.write(TAG, level, message)
    end
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

    local lines = {}
    if state.registry and state.registry.captureFrame then
        local ok, result = pcall(state.registry.captureFrame, now)
        if ok and type(result) == 'table' then
            lines = result
        elseif not ok then
            safeLog(LOG_ERROR, 'registry.captureFrame failed: ' .. tostring(result))
        end
    end

    state.writer.appendFrame(now, lines)
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
