local config = require('DCSLogger.config')
local registry = require('DCSLogger.object_registry')
local sampler = require('DCSLogger.frame_sampler')
local writer = require('DCSLogger.acmi_writer')

local core = {}

local dcsLog = log
local LOG_INFO = dcsLog and dcsLog.INFO or 2
local LOG_ERROR = dcsLog and dcsLog.ERROR or 1
local TAG = 'DCSLOGGER.CORE'

local state = {
    started = false,
    settings = nil,
}

local function safeLog(level, message)
    if dcsLog and dcsLog.write then
        dcsLog.write(TAG, level, message)
    end
end

local function sanitize(text)
    if text == nil then
        return ''
    end

    local value = tostring(text)
    value = value:gsub('[\r\n]+', ' ')
    return value
end

local function collectMetadata(settings)
    local metadata = {}

    local missionTitle = (DCS and DCS.getMissionName and DCS.getMissionName()) or 'DCS Mission'
    metadata[#metadata + 1] = '0,Title=' .. sanitize(missionTitle)

    local missionBriefing = (DCS and DCS.getMissionDescription and DCS.getMissionDescription()) or ''
    if missionBriefing ~= '' then
        metadata[#metadata + 1] = '0,Briefing=' .. sanitize(missionBriefing)
    end

    metadata[#metadata + 1] = '0,RecordingTime=' .. os.date('!%Y-%m-%dT%H:%M:%SZ')
    metadata[#metadata + 1] = '0,DataRecorder=' .. sanitize(settings.recorderName or 'DCSLogger')
    metadata[#metadata + 1] = '0,DataSource=DCS'

    return metadata
end

function core.start()
    if state.started then
        return
    end

    state.settings = config.load()

    local metadata = collectMetadata(state.settings)
    local path, err = writer.open(state.settings, metadata)
    if not path then
        safeLog(LOG_ERROR, 'Failed to open ACMI writer: ' .. tostring(err))
        return
    end

    registry.init(state.settings, writer)
    sampler.init(state.settings, registry, writer)

    state.started = true
    safeLog(LOG_INFO, 'Logger started; output file: ' .. tostring(path))
end

function core.afterNextFrame()
    if not state.started then
        return
    end

    local simTime = 0
    if DCS and DCS.getModelTime then
        local ok, result = pcall(DCS.getModelTime)
        if ok then
            simTime = result or 0
        end
    end

    sampler.tick(simTime, os.clock())
end

function core.stop()
    if not state.started then
        return
    end

    local ok, err = pcall(sampler.shutdown)
    if not ok then
        safeLog(LOG_ERROR, 'sampler.shutdown failed: ' .. tostring(err))
    end

    writer.close()
    registry.reset()

    state.started = false
    state.settings = nil

    safeLog(LOG_INFO, 'Logger stopped.')
end

return core
