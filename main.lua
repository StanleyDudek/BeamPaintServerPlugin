local base64 = require("base64")

-- local BEAMPAINT_URL = "http://127.0.0.1:3030/api/v2"
local BEAMPAINT_URL = "https://beampaint.com/api/v2"

-- Maximum amount of bytes sent as values in JSON message
local MAX_DATA_VALUES_PP = 12000

local LIVERY_DATA = {}

local TEXTURE_MAP = {}
local TEXTURE_TRANSFER_PROGRESS = {}
local ACCOUNT_IDS = {}
local NOT_REGISTERED = {}
local INFORMED = {}

local ROLE_MAP = {}

-- Thanks Bouboule for this function
function httpRequest(url)
    local response = ""

    if MP.GetOSName() == "Windows" then
        response = os.execute('powershell -Command "Invoke-WebRequest -Uri ' .. url .. ' -OutFile temp.txt"')
    else
        response = os.execute("wget -q -O temp.txt " .. url)
    end

    if response then
        local file = io.open("temp.txt", "r")
        local content = file:read("*all")
        file:close()
        os.remove("temp.txt")
        return content
    else
        return nil
    end
end

function httpRequestSaveFile(url, filename)
    local response = ""

    if MP.GetOSName() == "Windows" then
        response = os.execute('powershell -Command "Invoke-WebRequest -Uri ' .. url .. ' -OutFile ' .. filename .. '"')
    else
        response = os.execute("wget -q -O " .. filename .. " " .. url)
    end

    return response
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

local function sendClientTextureData(pid, target_id)
    local data = {}
    data.target_id = target_id
    data.raw_offset = TEXTURE_TRANSFER_PROGRESS[pid][target_id].progress
    local raw = LIVERY_DATA[TEXTURE_TRANSFER_PROGRESS[pid][target_id].livery_id]:sub(data.raw_offset + 1, math.min(data.raw_offset + MAX_DATA_VALUES_PP, #LIVERY_DATA[TEXTURE_TRANSFER_PROGRESS[pid][target_id].livery_id]))
    data.raw = base64.encode(raw)
    MP.TriggerClientEventJson(pid, "BP_receiveTextureData", data)
    print("Sent client (" .. pid .. ") texture data (" .. #data.raw .. " bytes)!")
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
    if ROLE_MAP[targetPid] == nil then return end
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
        print("Client is done!")
        MP.TriggerClientEventJson(pid, "BP_markTextureComplete", { target_id = target_id })
    end
end

function BP_clientReady(pid)
    print("Client (" .. pid .. ") has marked itself as ready")

    TEXTURE_TRANSFER_PROGRESS[pid] = {}

    local pname = MP.GetPlayerName(pid)
    if NOT_REGISTERED[pname] then
        informRegistry(pid)
    end

    for serverID, liveryData in pairs(TEXTURE_MAP) do
        initSendClientTextureData(pid, serverID, liveryData.liveryID)
    end

    for tpid, role in pairs(ROLE_MAP) do
        for tvid, vdata in pairs(MP.GetPlayerVehicles(tpid) or {}) do
            print("hi " .. tpid .. "-" .. tvid)
            updatePlayerRole(pid, tpid, tvid)
        end
    end
end

function BP_setLiveryUsed(pid, data)
    local pname = MP.GetPlayerName(pid)
    if NOT_REGISTERED[pname] then
        print("haha didnt register")
    else
        local discordID = ACCOUNT_IDS[pname]
        print("pid: " .. pid)
        local resp = httpRequest(BEAMPAINT_URL .. "/user/" .. discordID)
        print(resp)
        local parsed = Util.JsonDecode(resp)
        print(parsed)
        local split = strsplit(data, ";")
        local serverID = split[1]
        local vehType = split[2]

        local liveryID = parsed["selected_liveries"][vehType]
        if liveryID ~= nil then
            FS.CreateDirectory("livery_cache")
            local liveryUrl = BEAMPAINT_URL .. "/livery/" .. liveryID .. "/livery.png"
            local liveryPath = "livery_cache/" .. liveryID .. ".png"
            httpRequestSaveFile(liveryUrl, liveryPath)
            local inp = io.open(liveryPath, "rb")
            LIVERY_DATA[liveryID] = inp:read("*all")
            inp:close()
            os.remove(liveryPath)
            TEXTURE_MAP[serverID] = { liveryID = liveryID, car = vehType }

            sendEveryoneLivery(serverID, liveryID)
        end
    end
end

function informRegistry(pid)
    if INFORMED[pid] == nil then
        print("Informing client " .. pid .. " of BeamPaint registry")
        INFORMED[pid] = true

        MP.TriggerClientEvent(pid, "BP_informSignup", "")
    end
end

function onPlayerAuth(pname, prole, is_guest, identifiers)
    if not is_guest then
        if identifiers["discord"] ~= nil then
            local discordID = identifiers["discord"]
            local accountID = httpRequest(BEAMPAINT_URL .. "/discord2id/" .. discordID)
            if #accountID == 0 then
                accountID = httpRequest(BEAMPAINT_URL .. "/beammp2id/" .. identifiers["beammp"])
                if #accountID == 0 then
                    NOT_REGISTERED[pname] = true
                else
                    ACCOUNT_IDS[pname] = accountID
                end
            else
                ACCOUNT_IDS[pname] = accountID
            end
        else
            NOT_REGISTERED[pname] = true
        end
    end
end

function onPlayerJoining(pid)
    local pname = MP.GetPlayerName(pid)
    local discordID = ACCOUNT_IDS[pname]
    if discordID then
        print("pid: " .. pid)
        local resp = httpRequest(BEAMPAINT_URL .. "/user/" .. discordID)
        print(resp)
        local parsed = Util.JsonDecode(resp)

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

function onInit()
    for pid, pname in pairs(MP.GetPlayers()) do
        local role = "" -- We don't use this anyway :3
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
MP.RegisterEvent("onVehicleSpawn", "onVehicleSpawn")
