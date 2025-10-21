local registry = {}

local dcsLog = log
local LOG_ERROR = dcsLog and dcsLog.ERROR or 1
local LOG_INFO = dcsLog and dcsLog.INFO or 2
local TAG = 'DCSLOGGER.REGISTRY'

local state = {
    config = nil,
    writer = nil,
    objects = {},
    reference = nil,
    referenceCommitted = false,
    nextSyntheticId = 0,
    cleanupTtl = 5,
}

local coalitionLookup = {
    [0] = 'Neutral',
    [1] = 'Allies',
    [2] = 'Enemies',
    red = 'Enemies',
    blue = 'Allies',
    neutral = 'Neutral',
}

local coalitionColors = {
    Allies = 'Red',
    Enemies = 'Blue',
    Neutral = 'White',
}

local function safeLog(level, message)
    if dcsLog and dcsLog.write then
        dcsLog.write(TAG, level, message)
    end
end

local function sanitizeString(value)
    if value == nil then
        return nil
    end
    value = tostring(value)
    value = value:gsub('[\r\n]+', ' ')
    value = value:match('^%s*(.-)%s*$')
    if value == '' then
        return nil
    end
    return value
end

local function cloneTable(source)
    if type(source) ~= 'table' then
        return nil
    end
    local result = {}
    for key, value in pairs(source) do
        result[key] = value
    end
    return result
end

local function flattenTypeField(field)
    if field == nil then
        return nil
    end

    if type(field) == 'string' then
        return sanitizeString(field)
    end

    if type(field) == 'table' then
        local parts = {}
        local function append(value)
            local cleaned = sanitizeString(value)
            if cleaned then
                parts[#parts + 1] = cleaned
            end
        end

        if field.level1 or field.level2 or field.level3 or field.level4 then
            append(field.level1)
            append(field.level2)
            append(field.level3)
            append(field.level4)
        else
            for _, value in pairs(field) do
                append(value)
            end
        end

        if #parts > 0 then
            return table.concat(parts, '+')
        end
    end

    return nil
end

local function coalitionLabel(value)
    if value == nil then
        return 'Neutral', coalitionColors.Neutral
    end

    local key = value
    if type(value) == 'table' then
        key = value.side or value.name or value.coalition
    end

    if type(key) == 'string' then
        key = key:lower()
    end

    local label = coalitionLookup[key] or 'Neutral'
    local color = coalitionColors[label] or 'White'
    return label, color
end

local function generateAcmiId(sourceId)
    if type(sourceId) == 'number' then
        return string.format('%x', sourceId):lower()
    end

    state.nextSyntheticId = state.nextSyntheticId + 1
    return string.format('x%04x', state.nextSyntheticId)
end

local function ensureReference(lat, lon)
    if state.reference or not lat or not lon then
        return
    end

    local baseLat = math.floor(lat)
    local baseLon = math.floor(lon)

    state.reference = {
        latitude = baseLat,
        longitude = baseLon,
    }

    if state.writer and state.writer.addHeaderLines and not state.referenceCommitted then
        local headerLines = {
            string.format('0,ReferenceLongitude=%.6f', state.reference.longitude),
            string.format('0,ReferenceLatitude=%.6f', state.reference.latitude),
        }
        state.writer.addHeaderLines(headerLines)
        state.referenceCommitted = true
    end
end

local function getReferenceOffsets(lat, lon)
    if not state.reference or not lat or not lon then
        return nil, nil
    end

    local latOffset = lat - state.reference.latitude
    local lonOffset = lon - state.reference.longitude
    return lonOffset, latOffset
end

local function toDegrees(value)
    if type(value) ~= 'number' then
        value = tonumber(value)
    end
    if type(value) ~= 'number' then
        return nil
    end
    return math.deg(value)
end

local function toNumber(value)
    if type(value) == 'number' then
        return value
    end
    return tonumber(value)
end

local function buildPropertyString(entry)
    local properties = {}

    if entry.typeText then
        properties[#properties + 1] = 'Type=' .. entry.typeText
    end
    if entry.color then
        properties[#properties + 1] = 'Color=' .. entry.color
    end
    if entry.coalition then
        properties[#properties + 1] = 'Coalition=' .. entry.coalition
    end
    if entry.name then
        properties[#properties + 1] = 'Name=' .. entry.name
    end
    if entry.pilot then
        properties[#properties + 1] = 'Pilot=' .. entry.pilot
    end
    if entry.group then
        properties[#properties + 1] = 'Group=' .. entry.group
    end
    if entry.country then
        properties[#properties + 1] = 'Country=' .. entry.country
    end

    if #properties == 0 then
        return nil
    end

    return table.concat(properties, ',')
end

local function formatField(value, pattern)
    if value == nil then
        return ''
    end
    return string.format(pattern, value)
end

local function buildTransform(entry)
    local lonOffset, latOffset = getReferenceOffsets(entry.latitude, entry.longitude)
    local alt = entry.altitude and formatField(entry.altitude, '%.2f') or ''
    local roll = entry.roll and formatField(entry.roll, '%.2f') or ''
    local pitch = entry.pitch and formatField(entry.pitch, '%.2f') or ''
    local heading = entry.heading and formatField(entry.heading, '%.1f') or ''
    local xCoord = entry.positionX and formatField(entry.positionX, '%.2f') or ''
    local zCoord = entry.positionZ and formatField(entry.positionZ, '%.2f') or ''
    local agl = entry.agl and formatField(entry.agl, '%.2f') or ''

    local transformFields = {
        lonOffset and formatField(lonOffset, '%.7f') or '',
        latOffset and formatField(latOffset, '%.7f') or '',
        alt,
        pitch,
        roll,
        heading,
        xCoord,
        zCoord,
        agl,
    }

    return table.concat(transformFields, '|')
end

local function buildAcmiLine(entry)
    local transform = buildTransform(entry)
    local line = string.format('%s,T=%s', entry.acmiId, transform)

    local properties = buildPropertyString(entry)
    if properties then
        line = string.format('%s,%s', line, properties)
    end

    return line
end

local function pruneExpired(simTime, seen)
    if not simTime then
        return
    end

    for key, entry in pairs(state.objects) do
        if not seen[key] then
            local lastSeen = entry.lastSeen or 0
            if (simTime - lastSeen) >= state.cleanupTtl then
                state.objects[key] = nil
            end
        end
    end
end

local function updateEntryFromWorldObject(entry, source, simTime)
    if type(source) ~= 'table' then
        return nil
    end

    entry.lastSeen = simTime

    if source.LatLongAlt then
        entry.latitude = toNumber(source.LatLongAlt.Lat)
        entry.longitude = toNumber(source.LatLongAlt.Long)
        entry.altitude = toNumber(source.LatLongAlt.Alt)
        ensureReference(entry.latitude, entry.longitude)
    end

    if source.Position then
        entry.positionX = toNumber(source.Position.x)
        entry.positionZ = toNumber(source.Position.z)
    end

    if source.AltitudeAGL then
        entry.agl = toNumber(source.AltitudeAGL)
    elseif entry.altitude then
        entry.agl = entry.altitude
    else
        entry.agl = nil
    end

    entry.heading = toDegrees(source.Heading)
    entry.pitch = toDegrees(source.Pitch)
    entry.roll = toDegrees(source.Roll)

    entry.typeText = flattenTypeField(source.Type)
    entry.name = sanitizeString(source.Name or source.UnitName)
    entry.pilot = sanitizeString(source.PilotName or source.CallSign)
    entry.group = sanitizeString(source.GroupName)
    entry.country = sanitizeString(source.Country)

    local coalition, color = coalitionLabel(source.Coalition)
    entry.coalition = coalition
    entry.color = color

    return buildAcmiLine(entry)
end

local function ensureEntry(sourceKey, sourceId)
    local key = tostring(sourceKey)
    local entry = state.objects[key]
    if entry then
        return entry
    end

    entry = {
        sourceKey = key,
        sourceId = sourceId,
        acmiId = generateAcmiId(sourceId),
    }

    state.objects[key] = entry
    return entry
end

local function fetchWorldObjects()
    if not LoGetWorldObjects then
        return {}
    end

    local ok, objects = pcall(LoGetWorldObjects)
    if not ok or type(objects) ~= 'table' then
        safeLog(LOG_ERROR, 'LoGetWorldObjects failed: ' .. tostring(objects))
        return {}
    end

    return objects
end

local function capturePlayerAircraft(simTime, seen)
    if not LoGetSelfData then
        return nil
    end

    local ok, selfData = pcall(LoGetSelfData)
    if not ok or type(selfData) ~= 'table' then
        return nil
    end

    local playerId = nil
    if LoGetPlayerPlaneId then
        local idOk, planeId = pcall(LoGetPlayerPlaneId)
        if idOk and planeId then
            playerId = planeId
        end
    end

    local keyString = tostring(playerId or 'PLAYER')
    if seen[keyString] then
        return nil
    end

    local acmiSourceId = playerId or keyString
    local entry = ensureEntry(keyString, acmiSourceId)
    entry.lastSeen = simTime

    if selfData.LatLongAlt then
        entry.latitude = toNumber(selfData.LatLongAlt.Latitude or selfData.LatLongAlt.lat or selfData.LatLongAlt.Lat)
        entry.longitude = toNumber(selfData.LatLongAlt.Longitude or selfData.LatLongAlt.lon or selfData.LatLongAlt.Long)
        entry.altitude = toNumber(selfData.LatLongAlt.Altitude or selfData.LatLongAlt.alt or selfData.LatLongAlt.Alt)
        ensureReference(entry.latitude, entry.longitude)
    end

    entry.heading = toDegrees(selfData.Heading)
    entry.pitch = toDegrees(selfData.Pitch)
    entry.roll = toDegrees(selfData.Bank or selfData.Roll)

    entry.typeText = sanitizeString(selfData.Type) or 'Air'
    entry.name = sanitizeString(selfData.Name or selfData.UnitName or selfData.Type)
    entry.pilot = sanitizeString(selfData.PilotName or selfData.CallSign or 'player')
    entry.country = sanitizeString(selfData.Country)

    local coalition, color = coalitionLabel(selfData.Coalition)
    entry.coalition = coalition
    entry.color = color

    return buildAcmiLine(entry)
end

function registry.init(config, writerModule)
    state.config = cloneTable(config) or {}
    state.writer = writerModule
    state.objects = {}
    state.reference = nil
    state.referenceCommitted = false
    state.nextSyntheticId = 0
end

function registry.reset()
    state.config = nil
    state.writer = nil
    state.objects = {}
    state.reference = nil
    state.referenceCommitted = false
    state.nextSyntheticId = 0
end

function registry.captureFrame(simTime)
    local lines = {}
    local seen = {}

    local worldObjects = fetchWorldObjects()
    for sourceId, data in pairs(worldObjects) do
        local entry = ensureEntry(sourceId, sourceId)
        local line = updateEntryFromWorldObject(entry, data, simTime)
        if line then
            lines[#lines + 1] = line
        end
        seen[tostring(sourceId)] = true
    end

    local playerLine = capturePlayerAircraft(simTime, seen)
    if playerLine then
        lines[#lines + 1] = playerLine
    end

    pruneExpired(simTime, seen)

    table.sort(lines)
    return lines
end

return registry
