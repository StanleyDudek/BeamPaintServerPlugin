local base64 = require("base64")

-- local BEAMPAINT_URL = "http://127.0.0.1:3030"
local BEAMPAINT_URL = "https://beampaint.com"

-- Maximum amount of bytes sent as values in JSON message
local MAX_DATA_VALUES_PP = 12000

-- local TEST_DATA = {}
-- local inp = io.open("Resources/Server/BeamPaintServerPlugin/covet_skin_gradient_striped_1k_png.png", "rb")
-- TEST_DATA = inp:read("*all")
-- inp:close()
-- print("TEST_DATA size: " .. #TEST_DATA)

local LIVERY_DATA = {}

local TEXTURE_MAP = {}
local TEXTURE_TRANSFER_PROGRESS = {}
local DISCORD_IDS = {}
local NOT_REGISTERED = {}

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
    -- data.raw = {}
    -- for i=data.raw_offset,math.min(data.raw_offset + MAX_DATA_VALUES_PP, #TEST_DATA) do
    --     table.insert(data.raw, TEST_DATA[i])
    --     -- table.insert(data.raw, 1)
    -- end
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

    for serverID, liveryData in pairs(TEXTURE_MAP) do
        initSendClientTextureData(pid, serverID, liveryData.liveryID)
    end
end

function BP_informRegistry()
    for pid, idc in pairs(NOT_REGISTERED) do
        MP.SendChatMessage(pid, "You have not linked your Discord account to your BeamMP account!")
        MP.SendChatMessage(pid, "See https://beampaint.com/onboarding/ for more info.")
    end
end

function BP_setLiveryUsed(pid, data)
    local pname = MP.GetPlayerName(pid)
    if NOT_REGISTERED[pname] then
        print("haha didnt register")
    else
        local discordID = DISCORD_IDS[pname]
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
            -- print("LIVERY YEAHHHHHHH " .. liveryID)
            FS.CreateDirectory("livery_cache")
            local liveryUrl = BEAMPAINT_URL .. "/cdn/" .. liveryID .. "/livery.png"
            local liveryPath = "livery_cache/" .. liveryID .. ".png"
            httpRequestSaveFile(liveryUrl, liveryPath)
            local inp = io.open(liveryPath, "rb")
            LIVERY_DATA[liveryID] = inp:read("*all")
            inp:close()
            os.remove(liveryPath)
            TEXTURE_MAP[serverID] = { liveryID = liveryID, car = vehType }

            sendEveryoneLivery(serverID, liveryID)
            -- initSendClientTextureData(pid, serverID, liveryID)
        end
    end
end

function onPlayerAuth(pname, prole, is_guest, identifiers)
    if not is_guest then
        if identifiers["discord"] ~= nil then
            DISCORD_IDS[pname] = identifiers["discord"]
        else
            -- table.insert(NOT_REGISTERED, pname)
            NOT_REGISTERED[pname] = true
        end
    end
end

function onVehicleDeleted(pid, vid)
    local serverID = "" .. pid .. "-" .. vid
    TEXTURE_MAP[serverID] = nil
end

MP.RegisterEvent("BP_clientReady", "BP_clientReady")
MP.RegisterEvent("BP_setLiveryUsed", "BP_setLiveryUsed")
MP.RegisterEvent("BP_textureDataReceived", "BP_textureDataReceived")
MP.RegisterEvent("BP_informRegistry", "BP_informRegistry")
MP.RegisterEvent("onPlayerAuth", "onPlayerAuth")
MP.RegisterEvent("onVehicleDeleted", "onVehicleDeleted")

MP.CancelEventTimer("BP_informRegistry")
MP.CreateEventTimer("BP_informRegistry", 5000)
