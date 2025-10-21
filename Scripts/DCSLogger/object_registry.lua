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
    staticsSeeded = false,
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

local function normalizeHeading(value)
    local num = toNumber(value)
    if not num then
        return nil
    end

    if math.abs(num) <= (2 * math.pi + 0.001) then
        num = math.deg(num)
    end

    num = num % 360
    if num < 0 then
        num = num + 360
    end

    return num
end

local function formatField(value, pattern)
    if value == nil then
        return ''
    end
    return string.format(pattern, value)
end

local function zeroGuard(value, epsilon)
    local limit = epsilon or 1e-9
    if type(value) == 'number' and math.abs(value) < limit then
        return 0
    end
    return value
end

local function ensureCartesian(entry)
    if (entry.positionX and entry.positionZ) or not (entry.latitude and entry.longitude) then
        return
    end

    if not coord or not coord.LLtoLO then
        return
    end

    local ok, result = pcall(coord.LLtoLO, {
        lat = entry.latitude,
        lon = entry.longitude,
        alt = entry.altitude or 0,
    })

    if ok and type(result) == 'table' then
        entry.positionX = toNumber(result.x) or entry.positionX
        entry.positionZ = toNumber(result.z) or entry.positionZ
    end
end

local function ensureAltitude(entry, source)
    if entry.altitude then
        return
    end

    if source and source.Position and source.Position.y then
        entry.altitude = toNumber(source.Position.y)
    end
end

local function ensureAgl(entry)
    if entry.agl ~= nil then
        return
    end

    if not entry.altitude then
        return
    end

    if entry.positionX and entry.positionZ and land and land.getHeight then
        local ok, ground = pcall(land.getHeight, { x = entry.positionX, y = entry.positionZ })
        if ok and type(ground) == 'number' then
            entry.agl = zeroGuard(entry.altitude - ground, 1e-3)
            return
        end
    end

    entry.agl = entry.altitude
end

local function toKnots(mps)
    if type(mps) ~= 'number' then
        mps = tonumber(mps)
    end
    if type(mps) ~= 'number' then
        return nil
    end
    return mps * 1.9438444924574
end

local function collectThrottle()
    if not LoGetEngineInfo then
        return nil
    end

    local ok, info = pcall(LoGetEngineInfo)
    if not ok or type(info) ~= 'table' then
        return nil
    end

    local candidates = {}
    local function gather(tableValue)
        if type(tableValue) ~= 'table' then
            return
        end
        for _, value in pairs(tableValue) do
            if type(value) == 'number' then
                candidates[#candidates + 1] = value
            end
        end
    end

    gather(info.throttle)
    gather(info.Throttle)
    gather(info.currentThrottleInput)
    gather(info.throttleInput)

    if info.RPM then
        gather(info.RPM)
    end

    if #candidates == 0 then
        return nil
    end

    local sum = 0
    for _, value in ipairs(candidates) do
        sum = sum + value
    end

    local average = sum / #candidates
    if average > 1.5 then
        if average <= 100 then
            average = average / 100
        else
            average = average / 1000
        end
    end

    if average < 0 then
        average = 0
    elseif average > 1 then
        average = math.min(average, 1)
    end

    return average
end

local function extractFuelWeight(selfData)
    if type(selfData) ~= 'table' then
        return nil
    end

    local keys = {
        'FuelTotal',
        'FuelInternal',
        'FuelWeight',
        'fuel_total',
        'fuel',
        'fuelWeight',
    }

    for _, key in ipairs(keys) do
        local value = selfData[key]
        if type(value) == 'number' then
            return value
        end
    end

    if selfData.Weight or selfData.total_weight then
        return nil
    end

    return nil
end

local function extractPilotHeadAngles()
    if not LoGetCameraPosition then
        return nil, nil, nil
    end

    local ok, camera = pcall(LoGetCameraPosition)
    if not ok or type(camera) ~= 'table' or not camera.x or not camera.y or not camera.z then
        return nil, nil, nil
    end

    local function component(axis, coord)
        if type(axis) ~= 'table' then
            return 0
        end
        return toNumber(axis[coord]) or 0
    end

    local m11 = component(camera.x, 'x')
    local m12 = component(camera.y, 'x')
    local m13 = component(camera.z, 'x')
    local m21 = component(camera.x, 'y')
    local m22 = component(camera.y, 'y')
    local m23 = component(camera.z, 'y')
    local m31 = component(camera.x, 'z')
    local m32 = component(camera.y, 'z')
    local m33 = component(camera.z, 'z')

    local pitch = math.asin(-m31)
    local roll = math.atan2(m32, m33)
    local yaw = math.atan2(m21, m11)

    return math.deg(yaw), math.deg(pitch), math.deg(roll)
end

local function collectPlayerTelemetry(entry, selfData)
    if not state.config or state.config.includeExtendedTelemetry == false then
        return nil
    end

    local lines = {}

    local iasValue = nil
    if selfData and type(selfData.IndicatedAirSpeed) == 'number' then
        iasValue = toKnots(selfData.IndicatedAirSpeed)
    elseif LoGetIndicatedAirSpeed then
        local ok, ias = pcall(LoGetIndicatedAirSpeed)
        if ok then
            iasValue = toKnots(ias)
        end
    end

    local lineVelocity = {}
    if iasValue then
        lineVelocity[#lineVelocity + 1] = string.format('IAS=%.1f', zeroGuard(iasValue, 1e-2))
    end

    if selfData and type(selfData.MachNumber) == 'number' then
        lineVelocity[#lineVelocity + 1] = string.format('Mach=%.2f', zeroGuard(selfData.MachNumber, 1e-3))
    end

    if selfData and type(selfData.AoA) == 'number' then
        lineVelocity[#lineVelocity + 1] = string.format('AoA=%.1f', zeroGuard(math.deg(selfData.AoA), 1e-2))
    end

    local fuelWeight = extractFuelWeight(selfData)
    if fuelWeight then
        lineVelocity[#lineVelocity + 1] = string.format('FuelWeight=%.1f', zeroGuard(fuelWeight, 1e-1))
    end

    if #lineVelocity > 0 then
        lines[#lines + 1] = string.format('%s,%s', entry.acmiId, table.concat(lineVelocity, ','))
    end

    local throttle = collectThrottle()
    local headYaw, headPitch, headRoll = extractPilotHeadAngles()

    local lineControls = {}
    if throttle then
        lineControls[#lineControls + 1] = string.format('Throttle=%.2f', zeroGuard(throttle, 1e-3))
    end
    if headYaw then
        lineControls[#lineControls + 1] = string.format('PilotHeadYaw=%.2f', zeroGuard(headYaw, 1e-2))
    end
    if headPitch then
        lineControls[#lineControls + 1] = string.format('PilotHeadPitch=%.2f', zeroGuard(headPitch, 1e-2))
    end
    if headRoll then
        lineControls[#lineControls + 1] = string.format('PilotHeadRoll=%.2f', zeroGuard(headRoll, 1e-2))
    end

    if #lineControls > 0 then
        lines[#lines + 1] = string.format('%s,%s', entry.acmiId, table.concat(lineControls, ','))
    end

    if #lines == 0 then
        return nil
    end

    return lines
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

local function buildTransform(entry)
    local lonOffset, latOffset = getReferenceOffsets(entry.latitude, entry.longitude)
    lonOffset = zeroGuard(lonOffset)
    latOffset = zeroGuard(latOffset)
    local altitude = entry.altitude and zeroGuard(entry.altitude) or nil
    local pitchVal = entry.pitch and zeroGuard(entry.pitch) or nil
    local rollVal = entry.roll and zeroGuard(entry.roll) or nil
    local headingVal = entry.heading and zeroGuard(entry.heading) or nil
    local xVal = entry.positionX and zeroGuard(entry.positionX) or nil
    local zVal = entry.positionZ and zeroGuard(entry.positionZ) or nil
    local aglVal = entry.agl and zeroGuard(entry.agl) or nil

    local alt = altitude and formatField(altitude, '%.2f') or ''
    local pitch = pitchVal and formatField(pitchVal, '%.2f') or ''
    local roll = rollVal and formatField(rollVal, '%.2f') or ''
    local heading = headingVal and formatField(headingVal, '%.1f') or ''
    local xCoord = xVal and formatField(xVal, '%.2f') or ''
    local zCoord = zVal and formatField(zVal, '%.2f') or ''
    local agl = aglVal and formatField(aglVal, '%.2f') or ''

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

local function registerStaticUnit(sideName, countryName, groupName, unit, category)
    if not unit or unit.x == nil or unit.y == nil then
        return false
    end

    local lat = toNumber(unit.lat) or toNumber(unit.latitude)
    local lon = toNumber(unit.lon) or toNumber(unit.longitude)

    if coord and coord.LOtoLL then
        local ok, result = pcall(coord.LOtoLL, { x = unit.x, y = unit.alt or 0, z = unit.y })
        if ok and type(result) == 'table' then
            lat = toNumber(result.lat or result.latitude or result.Latitude or lat)
            lon = toNumber(result.lon or result.longitude or result.Longitude or lon)
        end
    end

    if not lat or not lon then
        return false
    end

    ensureReference(lat, lon)

    local keyBase = unit.unitId or unit.name or (groupName .. ':' .. tostring(unit.index or unit.num or 0))
    local sourceKey = 'STATIC:' .. tostring(keyBase)
    local entry = ensureEntry(sourceKey, unit.unitId or sourceKey)

    entry.latitude = lat
    entry.longitude = lon
    entry.altitude = toNumber(unit.alt) or 0
    entry.positionX = toNumber(unit.x)
    entry.positionZ = toNumber(unit.y)
    entry.agl = entry.altitude
    entry.heading = normalizeHeading(unit.heading)
    entry.pitch = 0
    entry.roll = 0
    entry.isStatic = true
    entry.lastSeen = 0

    entry.typeText = flattenTypeField({ category, 'Static', unit.type }) or sanitizeString(unit.type) or category
    entry.name = sanitizeString(unit.name)
    entry.group = sanitizeString(groupName)
    entry.country = sanitizeString(countryName)
    entry.pilot = 'static'

    local coalition, color = coalitionLabel(sideName)
    entry.coalition = coalition
    entry.color = color

    return true
end

local function iterateMissionStatics(collector)
    if type(collector) ~= 'function' then
        return 0
    end

    if not env or not env.mission or not env.mission.coalition then
        return 0
    end

    local total = 0
    for sideName, side in pairs(env.mission.coalition) do
        if type(side) == 'table' and side.country then
            for _, country in pairs(side.country) do
                if type(country) == 'table' then
                    local countryName = country.name or country.id
                    if country.static and country.static.group then
                        for _, group in ipairs(country.static.group) do
                            local groupName = group.name or (countryName .. '_static_group')
                            if group.units then
                                for _, unit in ipairs(group.units) do
                                    if collector(sideName, countryName, groupName, unit, 'Static') then
                                        total = total + 1
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    return total
end

local function seedStaticObjects()
    if state.staticsSeeded then
        return
    end
    state.staticsSeeded = true

    local ok, count = pcall(function()
        return iterateMissionStatics(registerStaticUnit)
    end)

    if ok and count and count > 0 then
        safeLog(LOG_INFO, string.format('Seeded %d static mission objects for logging.', count))
    end
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
        entry.positionX = toNumber(source.Position.x) or entry.positionX
        entry.positionZ = toNumber(source.Position.z) or entry.positionZ
        entry.altitude = entry.altitude or toNumber(source.Position.y)
    end

    ensureAltitude(entry, source)
    ensureCartesian(entry)

    if source.AltitudeAGL then
        entry.agl = toNumber(source.AltitudeAGL)
    else
        ensureAgl(entry)
    end

    entry.heading = toDegrees(source.Heading)
    entry.pitch = toDegrees(source.Pitch)
    entry.roll = toDegrees(source.Roll)

    if entry.heading then
        entry.heading = entry.heading % 360
    end

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

    local entry = ensureEntry(keyString, playerId or keyString)
    entry.lastSeen = simTime

    if selfData.LatLongAlt then
        entry.latitude = toNumber(selfData.LatLongAlt.Latitude or selfData.LatLongAlt.lat or selfData.LatLongAlt.Lat)
        entry.longitude = toNumber(selfData.LatLongAlt.Longitude or selfData.LatLongAlt.lon or selfData.LatLongAlt.Long)
        entry.altitude = toNumber(selfData.LatLongAlt.Altitude or selfData.LatLongAlt.alt or selfData.LatLongAlt.Alt)
        ensureReference(entry.latitude, entry.longitude)
    end

    if selfData.Position then
        entry.positionX = toNumber(selfData.Position.x) or entry.positionX
        entry.positionZ = toNumber(selfData.Position.z) or entry.positionZ
        entry.altitude = entry.altitude or toNumber(selfData.Position.y)
    end

    ensureCartesian(entry)

    if selfData.LatLongAlt and selfData.LatLongAlt.AltitudeAGL then
        entry.agl = toNumber(selfData.LatLongAlt.AltitudeAGL)
    else
        ensureAgl(entry)
    end

    entry.heading = normalizeHeading(selfData.Heading)
    entry.pitch = toDegrees(selfData.Pitch)
    entry.roll = toDegrees(selfData.Bank or selfData.Roll)

    entry.typeText = sanitizeString(selfData.Type) or 'Air'
    entry.name = sanitizeString(selfData.Name or selfData.UnitName or selfData.Type)
    entry.pilot = sanitizeString(selfData.PilotName or selfData.CallSign or 'player')
    entry.country = sanitizeString(selfData.Country)

    local coalition, color = coalitionLabel(selfData.Coalition)
    entry.coalition = coalition
    entry.color = color

    seen[keyString] = true
    local primaryLine = buildAcmiLine(entry)
    local telemetryLines = collectPlayerTelemetry(entry, selfData)
    return primaryLine, telemetryLines
end

local function pruneExpired(simTime, seen)
    if not simTime then
        return
    end

    for key, entry in pairs(state.objects) do
        if entry.isStatic then
            -- Static objects persist indefinitely.
        elseif not seen[key] then
            local lastSeen = entry.lastSeen or 0
            if (simTime - lastSeen) >= state.cleanupTtl then
                state.objects[key] = nil
            end
        end
    end
end

function registry.init(config, writerModule)
    state.config = cloneTable(config) or {}
    state.writer = writerModule
    state.objects = {}
    state.reference = nil
    state.referenceCommitted = false
    state.nextSyntheticId = 0
    state.staticsSeeded = false
end

function registry.reset()
    state.config = nil
    state.writer = nil
    state.objects = {}
    state.reference = nil
    state.referenceCommitted = false
    state.nextSyntheticId = 0
    state.staticsSeeded = false
end

function registry.captureFrame(simTime)
    if not state.staticsSeeded then
        seedStaticObjects()
    end

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

    local playerLine, telemetryLines = capturePlayerAircraft(simTime, seen)
    if playerLine then
        lines[#lines + 1] = playerLine
    end
    if telemetryLines then
        for _, telemetryLine in ipairs(telemetryLines) do
            lines[#lines + 1] = telemetryLine
        end
    end

    for key, entry in pairs(state.objects) do
        if entry.isStatic and not seen[key] then
            lines[#lines + 1] = buildAcmiLine(entry)
            seen[key] = true
        end
    end

    pruneExpired(simTime, seen)

    table.sort(lines)
    return lines
end

return registry
