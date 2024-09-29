local base64 = require("base64")

local SERVER_VERSION_MAJOR, SERVER_VERSION_MINOR, SERVER_VERSION_PATCH = MP.GetServerVersion()

-- Fix support for older servers (certain hosts have not updated yet)
if not Util.LogInfo then
    print("This BeamMP server is outdated! Patching Util.LogInfo to point to print instead!")
    Util.LogInfo = print
end
if not Util.LogError then
    print("This BeamMP server is outdated! Patching Util.LogError to point to print instead!")
    Util.LogError = print
end

-- local BEAMPAINT_URL = "http://127.0.0.1:3030/api/v2"
local BEAMPAINT_URL = "https://beampaint.com/api/v2"

local config = {}

-- Maximum amount of bytes sent as values in JSON message
local MAX_DATA_VALUES_PP = 12000
-- The launcher still limits the incoming data so this does NOT work!
-- if SERVER_VERSION_MAJOR >= 3 and SERVER_VERSION_MINOR >= 5 then
--     MAX_DATA_VALUES_PP = 20000
-- end

local LIVERY_DATA = {}

local TEXTURE_MAP = {}
local TEXTURE_TRANSFER_PROGRESS = {}
local ACCOUNT_IDS = {}
local NOT_REGISTERED = {}

local ROLE_MAP = {}
local EXISTING_ROLES = {}

local function httpGetToFile(url, outputFile)
    local ok, err, n
    if MP.GetOSName() == "Windows" then
        ok, err, n = os.execute('powershell -Command "Invoke-WebRequest -Uri \\"' .. url .. '\\" -OutFile \\"' .. outputFile .. '\\""')
    else
        ok, err, n = os.execute("curl \"" .. url .. "\" --compressed --no-progress-meter >\"" .. outputFile .. "\"")
        if not ok then
            ok, err, n = os.execute("wget -q -O \"" .. outputFile .. "\" \"" .. url .. "\"")
        end
    end
    if not ok then
        Util.LogError("Failed to query URL '" .. url .. "': " .. err .. " (" .. tostring(n) .. ")")
        return nil
    else
        return true
    end
end

-- Returns the body of a GET to the given url
local function httpGet(url)
    local outputFile = "temp_" .. tostring(os.clock()) .. tostring(Util.RandomIntRange(1, 100000)) .. ".txt"
    local ok = httpGetToFile(url, outputFile)
    if not ok then
        Util.LogError("Failed to query URL '" .. url .. "': " .. err .. " (" .. tostring(n) .. ")")
        return nil
    else
        local file = io.open(outputFile, "r")
        if not file then
            Util.LogError("Failed to query URL '" .. url .. "': Output file not found!")
            return nil
        end
        local content = file:read("*all")
        file:close()
        os.remove(outputFile)
        return content
    end
end

local function strsplit(inputstr, sep)
    if sep == nil then
        sep = "%s"
    end
    local t = {}
    for str in string.gmatch(inputstr, "([^"..sep.."]+)") do
        table.insert(t, str)
    end
    return t
end

local function loadConfig()
    local file = io.open("beampaint_config.json", "r")
    if file then
        local content = file:read("*all")
        file:close()
        config = Util.JsonDecode(content)
    else
        -- No config !!!
        config = {}
        config.useCustomRoles = true
        config.showRegisterPopup = true
        local file = io.open("beampaint_config.json", "w")
        if not file then
            Util.LogError("Failed to create beampaint_config.json! Please make sure the server has permission to read/write files")
            return
        end
        file:write(Util.JsonPrettify(Util.JsonEncode(config)))
        file:flush()
        file:close()
    end

    -- Read environment variables
    local useCustomRolesEnv = os.getenv("BP_USE_CUSTOM_ROLES")
    if useCustomRolesEnv then
        Util.LogInfo("Found ENV variable `USE_CUSTOM_ROLES`, using this instead of config value!")
        local v = useCustomRolesEnv == "1" or useCustomRolesEnv == "TRUE" or useCustomRolesEnv == "true"
        config.useCustomRoles = v
    end

    local showRegisterPopupEnv = os.getenv("BP_SHOW_REGISTER_POPUP")
    if showRegisterPopupEnv then
        Util.LogInfo("Found ENV variable `BP_SHOW_REGISTER_POPUP`, using this instead of config value!")
        local v = showRegisterPopupEnv == "1" or showRegisterPopupEnv == "TRUE" or showRegisterPopupEnv == "true"
        config.showRegisterPopup = v
    end
end

local function sendClientTextureData(pid, target_id)
    local data = {}
    data.target_id = target_id
    data.raw_offset = TEXTURE_TRANSFER_PROGRESS[pid][target_id].progress
    local raw = LIVERY_DATA[TEXTURE_TRANSFER_PROGRESS[pid][target_id].livery_id]:sub(data.raw_offset + 1, math.min(data.raw_offset + MAX_DATA_VALUES_PP, #LIVERY_DATA[TEXTURE_TRANSFER_PROGRESS[pid][target_id].livery_id]))
    data.raw = base64.encode(raw)
    MP.TriggerClientEventJson(pid, "BP_receiveTextureData", data)
    TEXTURE_TRANSFER_PROGRESS[pid][target_id].progress = TEXTURE_TRANSFER_PROGRESS[pid][target_id].progress + MAX_DATA_VALUES_PP
end

function initSendClientTextureData(pid, target_id, livery_id)
    TEXTURE_TRANSFER_PROGRESS[pid] = TEXTURE_TRANSFER_PROGRESS[pid] or {}
    TEXTURE_TRANSFER_PROGRESS[pid][target_id] = { progress = 0, livery_id = livery_id }
    sendClientTextureData(pid, target_id)
end

function sendEveryoneLivery(serverID, liveryID)
    for pid, pname in pairs(MP.GetPlayers()) do
        initSendClientTextureData(pid, serverID, liveryID)
    end
end

function updatePlayerRole(pid, targetPid, targetVid)
    if not config.useCustomRoles then return end
    if ROLE_MAP[targetPid] == nil then return end
    if EXISTING_ROLES[MP.GetPlayerName(pid)] ~= nil then return end
    local data = {}
    data.tid = "" .. targetPid .. "-" .. targetVid
    if ROLE_MAP[targetPid] == "admin" then data["isAdmin"] = true end
    MP.TriggerClientEventJson(pid, "BP_setPremium", data)
end

function updatePlayerRoleAll(targetPid, targetVid)
    for pid, pname in pairs(MP.GetPlayers()) do
        updatePlayerRole(pid, targetPid, targetVid)
    end
end

function BP_textureDataReceived(pid, target_id)
    if TEXTURE_TRANSFER_PROGRESS[pid][target_id].progress < #LIVERY_DATA[TEXTURE_TRANSFER_PROGRESS[pid][target_id].livery_id] then
        sendClientTextureData(pid, target_id)
    else
        MP.TriggerClientEventJson(pid, "BP_markTextureComplete", { target_id = target_id })
    end
end

function BP_clientReady(pid)
    TEXTURE_TRANSFER_PROGRESS[pid] = {}

    for serverID, liveryData in pairs(TEXTURE_MAP) do
        initSendClientTextureData(pid, serverID, liveryData.liveryID)
    end

    for tpid, role in pairs(ROLE_MAP) do
        for tvid, vdata in pairs(MP.GetPlayerVehicles(tpid) or {}) do
            updatePlayerRole(pid, tpid, tvid)
        end
    end
end

function BP_setLiveryUsed(pid, data)
    local pname = MP.GetPlayerName(pid)
    if NOT_REGISTERED[pname] then
        informRegistry(pid)
    else
        local accountID = ACCOUNT_IDS[pname]
        local resp = httpGet(BEAMPAINT_URL .. "/user/" .. accountID)
        if not resp then
            Util.LogError("Failed to get livery for " .. tostring(pid) .. " because the GET request failed")
            return
        end
        local parsed = Util.JsonDecode(resp)
        local split = strsplit(data, ";")
        local serverID = split[1]
        local vehType = split[2]

        local liveryID = parsed["selected_liveries"][vehType]
        if liveryID ~= nil then
            FS.CreateDirectory("livery_cache")
            local liveryUrl = BEAMPAINT_URL .. "/livery/" .. liveryID .. "/livery.png"
            local liveryPath = "livery_cache/" .. liveryID .. ".png"
            local ok = httpGetToFile(liveryUrl, liveryPath)
            if not ok then
                Util.LogError("Failed to save livery '" .. liveryID .. "' to file '" .. liveryPath .. "'")
                return
            end
            local inp = io.open(liveryPath, "rb")
            if not inp then
                Util.LogError("Failed to open livery path '" .. liveryPath .. "'")
                return
            end
            LIVERY_DATA[liveryID] = inp:read("*all")
            inp:close()
            os.remove(liveryPath)
            TEXTURE_MAP[serverID] = { liveryID = liveryID, car = vehType }

            sendEveryoneLivery(serverID, liveryID)
        end
    end
end

function informRegistry(pid)
    if not config.showRegisterPopup then return end
    MP.TriggerClientEvent(pid, "BP_informSignup", "")
end

function onPlayerAuth(pname, prole, is_guest, identifiers)
    if not is_guest then
        EXISTING_ROLES[pname] = prole
        local discordID = identifiers["discord"]
        if discordID then
            local accountID = httpGet(BEAMPAINT_URL .. "/discord2id/" .. discordID)
            if not accountID then
                Util.LogError("Failed to get account ID (discord2id) due to failed GET request for player with discord ID '" .. tostring(discordID) .. "' (player '" .. pname .. "')")
                return
            end
            if #accountID == 0 then
                accountID = httpGet(BEAMPAINT_URL .. "/beammp2id/" .. identifiers["beammp"])
                if not accountID then
                    Util.LogError("Failed to get account ID (beammp2id) due to failed GET request for player with BeamMP id '" .. tostring(identifiers["beammp"]) .. "' (player '" .. pname .. "')")
                    return
                end
                if #accountID == 0 then
                    NOT_REGISTERED[pname] = true
                else
                    ACCOUNT_IDS[pname] = accountID
                end
            else
                ACCOUNT_IDS[pname] = accountID
            end
        else
            local accountID = httpGet(BEAMPAINT_URL .. "/beammp2id/" .. identifiers["beammp"])
            if not accountID then
                Util.LogError("Failed to get account ID (beammp2id) due to failed GET request for player with BeamMP id '" .. tostring(identifiers["beammp"]) .. "' (player '" .. pname .. "'). Didn't try discord ID since the player doesn't have a linked discord account.")
                return
            end
            if #accountID == 0 then
                NOT_REGISTERED[pname] = true
            else
                ACCOUNT_IDS[pname] = accountID
            end
        end
    end
end

function onPlayerJoining(pid)
    local pname = MP.GetPlayerName(pid)
    local accountID = ACCOUNT_IDS[pname]
    if accountID then
        local resp = httpGet(BEAMPAINT_URL .. "/user/" .. accountID)
        if not resp then
            Util.LogError("Failed to get user info for account '" .. tostring(accountID) .. "' (pid " .. tostring(pid) .. ") due to failed GET request")
            return
        end
        local parsed = Util.JsonDecode(resp)
        Util.LogInfo(parsed)

        local isAdmin = parsed["admin"] or false
        local hasPremium = parsed["premium"] or false

        if hasPremium then ROLE_MAP[pid] = "premium" end
        if isAdmin then ROLE_MAP[pid] = "admin" end
    end
end

function onPlayerDisconnect(pid)
    ROLE_MAP[pid] = nil
end

function onVehicleDeleted(pid, vid)
    local serverID = "" .. pid .. "-" .. vid
    TEXTURE_MAP[serverID] = nil
end

function onVehicleSpawn(tpid, tvid)
    updatePlayerRoleAll(tpid, tvid)
end

function postVehicleSpawn(allowed, tpid, tvid)
    if allowed then
        updatePlayerRoleAll(tpid, tvid)
    end
end

function onInit()
    loadConfig()

    for pid, pname in pairs(MP.GetPlayers()) do
        local role = EXISTING_ROLES[pname]
        local is_guest = MP.IsPlayerGuest(pid)
        local identifiers = MP.GetPlayerIdentifiers(pid)
        onPlayerAuth(pname, role, is_guest, identifiers)
    end

    for pid, pname in pairs(MP.GetPlayers()) do
        onPlayerJoining(pid)
    end
end

MP.RegisterEvent("onInit", "onInit")
MP.RegisterEvent("BP_clientReady", "BP_clientReady")
MP.RegisterEvent("BP_setLiveryUsed", "BP_setLiveryUsed")
MP.RegisterEvent("BP_textureDataReceived", "BP_textureDataReceived")
MP.RegisterEvent("onPlayerAuth", "onPlayerAuth")
MP.RegisterEvent("onVehicleDeleted", "onVehicleDeleted")
MP.RegisterEvent("onPlayerJoining", "onPlayerJoining")
MP.RegisterEvent("onPlayerDisconnect", "onPlayerDisconnect")

if SERVER_VERSION_MAJOR >= 3 and SERVER_VERSION_MINOR >= 5 then
    MP.RegisterEvent("postVehicleSpawn", "postVehicleSpawn")
else
    MP.RegisterEvent("onVehicleSpawn", "onVehicleSpawn")
end

function printDebugExecutionTime()
    local stats = Util.DebugExecutionTime()
    local pretty = "DebugExecutionTime:\n"
    local longest = 0
    for name, t in pairs(stats) do
        if #name > longest then
            longest = #name
        end
    end
    for name, t in pairs(stats) do
        pretty = pretty .. string.format("%" .. longest + 1 .. "s: %12f +/- %12f (min: %12f, max: %12f) (called %d time(s))\n", name, t.mean, t.stdev, t.min, t.max, t.n)
    end
    print(pretty)
end
