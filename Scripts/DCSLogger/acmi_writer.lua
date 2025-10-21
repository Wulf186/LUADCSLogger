local lfs = require('lfs')

local writer = {}
local state = {
    file = nil,
    path = nil,
    settings = nil,
    lastFlush = nil,
}

local dcsLog = log
local LOG_INFO = dcsLog and dcsLog.INFO or 2
local LOG_ERROR = dcsLog and dcsLog.ERROR or 1
local TAG = 'DCSLOGGER.WRITER'

local function safeLog(level, message)
    if dcsLog and dcsLog.write then
        dcsLog.write(TAG, level, message)
    end
end

local function normalizePath(path)
    return path:gsub('/', '\\')
end

local function ensureDirectory(path)
    local normalized = normalizePath(path):gsub('\\+$', '')
    if normalized == '' then
        return true
    end

    local attributes = lfs.attributes(normalized)
    if attributes and attributes.mode == 'directory' then
        return true
    end

    local parent = normalized:match('^(.*)\\[^\\]+$')
    if parent and parent ~= normalized and not parent:match('^[A-Za-z]:$') then
        local ok, err = ensureDirectory(parent)
        if not ok then
            return nil, err
        end
    end

    local ok, err = lfs.mkdir(normalized)
    if not ok and err ~= 'File exists' then
        return nil, err
    end

    return true
end

local function defaultMetadataLines(settings, metadata)
    local lines = {
        'FileType=text/acmi/tacview',
        'FileVersion=2.1',
    }

    if metadata then
        for _, line in ipairs(metadata) do
            lines[#lines + 1] = line
        end
    end

    return lines
end

function writer.resolveOutputPath(settings)
    local writeDir = lfs.writedir()
    local relative = settings.outputDirectory or 'Logs\\DCSLogger\\'
    local baseDir = normalizePath(writeDir .. relative)
    local ok, err = ensureDirectory(baseDir)
    if not ok then
        return nil, err
    end

    if baseDir:sub(-1) ~= '\\' then
        baseDir = baseDir .. '\\'
    end

    local timestamp = os.date('!%Y%m%d-%H%M%S')
    local filename = string.format('DCSLogger-%s.txt.acmi', timestamp)
    return baseDir .. filename
end

local function writeLines(lines)
    if not state.file then
        return
    end

    for _, line in ipairs(lines) do
        state.file:write(line)
        if line:sub(-1) ~= '\n' then
            state.file:write('\n')
        end
    end
end

function writer.open(settings, metadata)
    if state.file then
        return state.path
    end

    local path, err = writer.resolveOutputPath(settings)
    if not path then
        return nil, err
    end

    local handle, openErr = io.open(path, 'w')
    if not handle then
        return nil, openErr
    end

    state.file = handle
    state.path = path
    state.settings = settings
    state.lastFlush = os.clock()

    writeLines(defaultMetadataLines(settings, metadata))
    state.file:flush()

    safeLog(LOG_INFO, 'Opened ACMI log at ' .. path)
    return path
end

function writer.appendFrame(simTimeSeconds, lines)
    if not state.file then
        return
    end

    local frameLines = { string.format('#%.3f', simTimeSeconds) }
    if type(lines) == 'table' then
        for _, line in ipairs(lines) do
            frameLines[#frameLines + 1] = line
        end
    end

    writeLines(frameLines)
end

function writer.flush()
    if not state.file then
        return
    end

    state.file:flush()
    state.lastFlush = os.clock()
end

function writer.maybeFlush(now)
    if not state.file or not state.settings then
        return
    end

    local interval = state.settings.flushIntervalSeconds or 1
    if interval <= 0 then
        return
    end

    if not state.lastFlush or (now - state.lastFlush) >= interval then
        writer.flush()
    end
end

function writer.close()
    if not state.file then
        return
    end

    state.file:flush()
    state.file:close()

    safeLog(LOG_INFO, 'Closed ACMI log at ' .. tostring(state.path))

    state.file = nil
    state.path = nil
    state.settings = nil
    state.lastFlush = nil
end

function writer.isOpen()
    return state.file ~= nil
end

function writer.getPath()
    return state.path
end

return writer
