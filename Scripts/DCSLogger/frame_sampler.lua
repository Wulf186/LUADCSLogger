local sampler = {}

local dcsLog = log
local LOG_ERROR = dcsLog and dcsLog.ERROR or 1
local TAG = 'DCSLOGGER.SAMPLER'

local state = {
    config = nil,
    registry = nil,
    writer = nil,
    lastSampleTime = nil,
    lastRealClock = nil,
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
    state.lastRealClock = nil
end

function sampler.tick(simTime, realClock)
    if not writerAvailable() then
        return
    end

    local clockNow = realClock or os.clock()
    local now = simTime

    if type(now) ~= 'number' then
        now = nil
    end

    if not now then
        if state.lastSampleTime and state.lastRealClock and clockNow then
            now = state.lastSampleTime + math.max(0, clockNow - state.lastRealClock)
        else
            now = 0
        end
    end

    if state.lastSampleTime then
        if now < state.lastSampleTime then
            now = state.lastSampleTime + math.max(0, (clockNow or 0) - (state.lastRealClock or 0))
        end

        if state.sampleInterval > 0 and (now - state.lastSampleTime) < state.sampleInterval then
            state.writer.maybeFlush(clockNow)
            state.lastRealClock = clockNow
            return
        end
    end

    local lines = {}
    if state.registry and state.registry.captureFrame then
        local ok, result = pcall(state.registry.captureFrame, now)
        if ok and type(result) == 'table' then
            lines = result
        elseif not ok then
            safeLog(LOG_ERROR, 'registry.captureFrame failed: ' .. tostring(result))
        end
    end

    if lines and #lines > 0 then
        state.writer.appendFrame(now, lines)
    end

    state.writer.maybeFlush(clockNow)
    state.lastSampleTime = now
    state.lastRealClock = clockNow
end

function sampler.shutdown()
    state.config = nil
    state.registry = nil
    state.writer = nil
    state.lastSampleTime = nil
    state.sampleInterval = 0
end

return sampler
