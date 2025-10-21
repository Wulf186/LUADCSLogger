-- DCS Logger Export integration
-- Loads custom logger and chains DCS export callbacks.

do
    if isDCSLoggerExportModuleInitialized then
        return
    end
    isDCSLoggerExportModuleInitialized = true

    local lfs = require('lfs')
    local dcsLog = log
    local LOG_INFO = dcsLog and dcsLog.INFO or 2
    local LOG_ERROR = dcsLog and dcsLog.ERROR or 1
    local TAG = 'DCSLOGGER.EXPORT'

    local function safeLog(level, message)
        if dcsLog and dcsLog.write then
            dcsLog.write(TAG, level, message)
        end
    end

    local writeDir = lfs.writedir()
    local scriptsRoot = writeDir .. 'Scripts\\'

    package.path = string.format(
        '%s;%s%s;%s%s;%s%s',
        package.path,
        scriptsRoot,
        '?.lua',
        scriptsRoot,
        '?\\init.lua',
        scriptsRoot,
        'DCSLogger\\?.lua'
    )

    local ok, core = pcall(require, 'DCSLogger.core')
    if not ok then
        safeLog(LOG_ERROR, 'Failed to load DCSLogger.core: ' .. tostring(core))
        return
    end

    safeLog(LOG_INFO, 'DCS Logger export module loaded.')

    local previousStart = LuaExportStart
    LuaExportStart = function()
        local status, err = pcall(core.start)
        if not status then
            safeLog(LOG_ERROR, 'core.start failed: ' .. tostring(err))
        end

        if previousStart then
            previousStart()
        end
    end

    local previousAfterFrame = LuaExportAfterNextFrame
    LuaExportAfterNextFrame = function()
        local status, err = pcall(core.afterNextFrame)
        if not status then
            safeLog(LOG_ERROR, 'core.afterNextFrame failed: ' .. tostring(err))
        end

        if previousAfterFrame then
            previousAfterFrame()
        end
    end

    local previousStop = LuaExportStop
    LuaExportStop = function()
        local status, err = pcall(core.stop)
        if not status then
            safeLog(LOG_ERROR, 'core.stop failed: ' .. tostring(err))
        end

        if previousStop then
            previousStop()
        end
    end
end
