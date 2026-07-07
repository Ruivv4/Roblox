-- Rue Hub | hosted main script
-- Library source: https://github.com/Eazvy/UILibs/tree/main/Librarys/Octernal

local LIBRARY_URL = "https://pastebin.com/raw/Q43KL2RS"
local PORT_MIN = 49152
local PORT_RANGE = 16384

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local RbxAnalyticsService = game:GetService("RbxAnalyticsService")

local library, pointers = loadstring(game:HttpGet(LIBRARY_URL))()

local rueConfig = getgenv().RueHubConfig or {}
getgenv().MainAccountsList = rueConfig.MainAccountsList or getgenv().MainAccountsList or {"awsomedue1234"}
getgenv().AltAccountsList = rueConfig.AltAccountsList or getgenv().AltAccountsList or {"Eiraleelin", "Eirlileen", "eirlileen"}

local function getExecutorName()
    local checks = {
        function()
            if identifyexecutor then
                local name, version = identifyexecutor()
                return version and (tostring(name) .. " " .. tostring(version)) or tostring(name)
            end
        end,
        function()
            if getexecutorname then
                return tostring(getexecutorname())
            end
        end,
    }

    for _, check in ipairs(checks) do
        local ok, result = pcall(check)
        if ok and result and result ~= "" then
            return result
        end
    end

    return "Unknown Executor"
end

local function hashString(value)
    local hash = 2166136261
    for index = 1, #value do
        hash = bit32.bxor(hash, string.byte(value, index))
        hash = (hash * 16777619) % 4294967296
    end
    return hash
end

local function getDeviceToken()
    local ok, clientId = pcall(function()
        return RbxAnalyticsService:GetClientId()
    end)
    if ok and clientId and clientId ~= "" then
        return tostring(clientId)
    end
    return getExecutorName() .. "|" .. tostring(UserInputService:GetPlatform())
end

local function getRuePort()
    local seed = getExecutorName() .. "|" .. getDeviceToken()
    return PORT_MIN + (hashString(seed) % PORT_RANGE)
end

local ruePort = getRuePort()
local selectedRole = "None"
local connectedPort = ""
local startEnabled = false
local statusText = "Idle"
local voteStatus = "Idle"
local invincibilityStatus = "Unknown"
local selectedWeaponSlot = "None"
local queueLockActive = false
local pairingRound = tonumber(rueConfig.PairingRound or getgenv().RueHubPairingRound) or 0
local voteConnections = {}
local duelVoteConnections = {}
local currentTargetPart = nil
local currentPadName = nil
local currentTeamName = nil
local activeMainTween = nil
local monitorToken = 0
local failPosition = Vector3.new(212, -682, 1184)

local ROLE_TO_TEAM = {Main = "Team1", Alt = "Team2"}
local QUEUE_PAD_NAMES = {"Queue Pad #1", "Queue Pad #2"}

local window = library:New({
    name = "Rue Hub",
    size = Vector2.new(555, 610),
    Accent = Color3.fromRGB(175, 95, 255),
})

local function notify(text)
    if window and window.notificationlist then
        window.notificationlist:AddNotification({text = tostring(text)})
    else
        warn("[Rue Hub] " .. tostring(text))
    end
end

local function setTextbox(pointer, text)
    local object = pointers and pointers[pointer]
    if not object then return end
    local value = tostring(text)
    pcall(function()
        if object.Update then
            object:Update("Text", value)
        elseif object.Set then
            object:Set(value)
        elseif object.set then
            object:set(value)
        end
    end)
end

local function getTextbox(pointer, fallback)
    local object = pointers and pointers[pointer]
    if object and object.get then
        local ok, value = pcall(function()
            return object:get()
        end)
        if ok and value ~= nil then
            return tostring(value)
        end
    end
    return fallback or ""
end

local function setControlVisible(pointer, state)
    local object = pointers and pointers[pointer]
    if not object then return end
    pcall(function()
        if object.Update then object:Update("Visible", state) end
        if object.Frame then
            object.Frame.Visible = state
        elseif object.frame then
            object.frame.Visible = state
        elseif object.Instance then
            object.Instance.Visible = state
        end
    end)
end

local function updateTracker()
    setTextbox("rue/tracker/role", selectedRole)
    setTextbox("rue/tracker/connected_port", connectedPort ~= "" and connectedPort or "None")
    setTextbox("rue/tracker/status", statusText)
    setTextbox("rue/tracker/vote", voteStatus)
    setTextbox("rue/tracker/invincible", invincibilityStatus)
    setTextbox("rue/tracker/weapon_slot", selectedWeaponSlot)
end

local function getAccountIndex(list, player)
    local playerName = string.lower(player.Name)
    local displayName = string.lower(player.DisplayName or "")
    for index, account in ipairs(list or {}) do
        local value = string.lower(tostring(account))
        if value == playerName or value == displayName or tonumber(value) == player.UserId then
            return index
        end
    end
    return nil
end

local function listHasAccount(list, player)
    return getAccountIndex(list, player) ~= nil
end

local function getAccountRole(player)
    if listHasAccount(getgenv().MainAccountsList, player) then return "Main" end
    if listHasAccount(getgenv().AltAccountsList, player) then return "Alt" end
    return nil
end

local function getExpectedPartnerRole()
    if selectedRole == "Main" then return "Alt" end
    if selectedRole == "Alt" then return "Main" end
    return nil
end

local function getListedPlayers(role)
    local list = role == "Main" and getgenv().MainAccountsList or getgenv().AltAccountsList
    local players = {}
    for _, player in ipairs(Players:GetPlayers()) do
        local index = getAccountIndex(list, player)
        if index then
            table.insert(players, {Player = player, Index = index})
        end
    end
    table.sort(players, function(left, right)
        if left.Index == right.Index then
            return left.Player.Name < right.Player.Name
        end
        return left.Index < right.Index
    end)
    local ordered = {}
    for _, item in ipairs(players) do
        table.insert(ordered, item.Player)
    end
    return ordered
end

local function getAssignedPairForSlot(slot, mainCount, altCount)
    if mainCount <= 0 or altCount <= 0 then return nil, nil end
    if mainCount <= altCount then
        return slot, ((slot + pairingRound - 1) % altCount) + 1
    end
    return ((slot + pairingRound - 1) % mainCount) + 1, slot
end

local function getAssignedPartner()
    local localPlayer = Players.LocalPlayer
    local mains = getListedPlayers("Main")
    local alts = getListedPlayers("Alt")
    local pairCount = math.min(#mains, #alts)

    if not localPlayer or selectedRole == "None" then
        return nil, "Pick Main or Alt"
    end
    if pairCount <= 0 then
        return nil, "No listed partner in server"
    end

    for slot = 1, pairCount do
        local mainIndex, altIndex = getAssignedPairForSlot(slot, #mains, #alts)
        local mainPlayer = mains[mainIndex]
        local altPlayer = alts[altIndex]
        if selectedRole == "Main" and mainPlayer == localPlayer then
            return altPlayer, altPlayer and ("Assigned Alt: " .. altPlayer.Name) or "Assigned Alt missing"
        elseif selectedRole == "Alt" and altPlayer == localPlayer then
            return mainPlayer, mainPlayer and ("Assigned Main: " .. mainPlayer.Name) or "Assigned Main missing"
        end
    end

    return nil, "Waiting turn | Round " .. tostring(pairingRound)
end

local function isExpectedPartner(player)
    local assignedPartner = getAssignedPartner()
    return assignedPartner ~= nil and player == assignedPartner
end

local function getPlayerByAccountRole(role)
    local assignedPartner = getAssignedPartner()
    if assignedPartner and getAccountRole(assignedPartner) == role then
        return assignedPartner
    end
    return nil
end

local function validatePort(value)
    local port = tonumber(value)
    if not port then return false, "Invalid Port" end
    port = math.floor(port)
    if port < PORT_MIN or port > PORT_MIN + PORT_RANGE - 1 then return false, "Invalid Port" end
    if port == ruePort then return false, "Self Port" end
    return true, tostring(port)
end

local function connectPort()
    local typed = getTextbox("rue/info/connect_port", connectedPort)
    local ok, result = validatePort(typed)
    if ok then
        connectedPort = result
        statusText = "Connected Port"
    else
        statusText = result
    end
    updateTracker()
    notify(statusText)
end

local function voteArena(reason)
    local voteRemote = ReplicatedStorage:FindFirstChild("Remotes")
        and ReplicatedStorage.Remotes:FindFirstChild("Duels")
        and ReplicatedStorage.Remotes.Duels:FindFirstChild("Vote")
    if not voteRemote then
        voteStatus = "Vote remote missing"
        updateTracker()
        return false
    end
    voteRemote:FireServer("Arena")
    voteStatus = reason and ("Voted Arena: " .. reason) or "Voted Arena"
    updateTracker()
    notify(voteStatus)
    return true
end

local function disconnectConnections(connections)
    for _, connection in ipairs(connections) do
        pcall(function() connection:Disconnect() end)
    end
    table.clear(connections)
end

local function clearDuelVoteConnections()
    disconnectConnections(duelVoteConnections)
end

local function clearVoteConnections()
    disconnectConnections(voteConnections)
    clearDuelVoteConnections()
end

local function getSpectateController()
    local localPlayer = Players.LocalPlayer
    local playerScripts = localPlayer and localPlayer:FindFirstChild("PlayerScripts")
    local controllers = playerScripts and playerScripts:FindFirstChild("Controllers")
    local module = controllers and controllers:FindFirstChild("SpectateController")
    if not module then return nil end
    local ok, controller = pcall(require, module)
    return ok and controller or nil
end

local tweenAltToMain

local function hookInvincibility(duelSubject)
    local localDueler = duelSubject and duelSubject.LocalDueler
    local clientFighter = localDueler and localDueler.ClientFighter
    local entity = clientFighter and clientFighter.Entity
    local lastInvincible = nil

    local function updateInvincibility()
        local ok, value = pcall(function()
            return entity and entity:Get("IsInvincible")
        end)
        if ok and value ~= nil then
            invincibilityStatus = value and "Yes" or "No"
            if lastInvincible == true and value == false then
                tweenAltToMain()
            end
            lastInvincible = value
        else
            invincibilityStatus = "Unavailable"
        end
        updateTracker()
    end

    if clientFighter and clientFighter.InvincibilityChanged then
        table.insert(duelVoteConnections, clientFighter.InvincibilityChanged:Connect(updateInvincibility))
    end
    if entity then
        local okSignal, signal = pcall(function()
            return entity:GetDataChangedSignal("IsInvincible")
        end)
        if okSignal and signal then
            table.insert(duelVoteConnections, signal:Connect(updateInvincibility))
        end
    end
    updateInvincibility()
end

local function hookDuelSubject(duelSubject)
    clearDuelVoteConnections()
    if not duelSubject then
        voteStatus = startEnabled and "Waiting for match" or "Idle"
        updateTracker()
        return
    end

    hookInvincibility(duelSubject)

    local function updateDuelStatus(reason)
        local status = nil
        local hasVoteOptions = nil
        pcall(function()
            status = duelSubject:Get("Status")
            hasVoteOptions = duelSubject:Get("VoteOptions") ~= nil
        end)
        if status then
            statusText = "Match: " .. tostring(status)
            if tostring(status) ~= "GameOver" then
                queueLockActive = true
            end
        end
        if hasVoteOptions then
            queueLockActive = true
            voteArena(reason or "VoteOptions")
        else
            voteStatus = status and ("Match: " .. tostring(status)) or "Match detected"
            updateTracker()
        end
    end

    local okStatus, statusSignal = pcall(function()
        return duelSubject:GetDataChangedSignal("Status")
    end)
    if okStatus and statusSignal then
        table.insert(duelVoteConnections, statusSignal:Connect(function() updateDuelStatus("Status") end))
    end
    local okVote, voteSignal = pcall(function()
        return duelSubject:GetDataChangedSignal("VoteOptions")
    end)
    if okVote and voteSignal then
        table.insert(duelVoteConnections, voteSignal:Connect(function() updateDuelStatus("VoteOptions") end))
    end
    updateDuelStatus("Match")
end

local function startMatchDetector()
    local controller = getSpectateController()
    if not controller then
        voteStatus = "Detector unavailable"
        updateTracker()
        return false
    end
    if controller.DuelSubjectChanged then
        table.insert(voteConnections, controller.DuelSubjectChanged:Connect(function()
            hookDuelSubject(controller.CurrentDuelSubject)
        end))
    end
    hookDuelSubject(controller.CurrentDuelSubject)
    return true
end

local function getLocalCharacterRoot()
    local player = Players.LocalPlayer
    if not player then return nil end
    local character = player.Character or player.CharacterAdded:Wait()
    return character:FindFirstChild("HumanoidRootPart") or character:WaitForChild("HumanoidRootPart", 5)
end

tweenAltToMain = function()
    if selectedRole ~= "Alt" or not startEnabled then return false end
    local mainPlayer = getPlayerByAccountRole("Main")
    local mainCharacter = mainPlayer and mainPlayer.Character
    local mainRoot = mainCharacter and mainCharacter:FindFirstChild("HumanoidRootPart")
    local altRoot = getLocalCharacterRoot()
    if not mainRoot or not altRoot then
        statusText = "Main target missing"
        updateTracker()
        notify(statusText)
        return false
    end
    if activeMainTween then pcall(function() activeMainTween:Cancel() end) end
    local frontPosition = mainRoot.Position + (mainRoot.CFrame.LookVector * 3)
    local targetCFrame = CFrame.lookAt(frontPosition, mainRoot.Position)
    activeMainTween = TweenService:Create(
        altRoot,
        TweenInfo.new(1.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
        {CFrame = targetCFrame}
    )
    statusText = "Alt tweening in front of Main"
    updateTracker()
    notify(statusText)
    activeMainTween:Play()
    return true
end

local function getDuelsFolder()
    local lobby = workspace:FindFirstChild("Lobby")
    local hub = lobby and lobby:FindFirstChild("Hub")
    local important = hub and hub:FindFirstChild("Important")
    return important and important:FindFirstChild("Duels")
end

local function getTeamPart(padName, teamName)
    local duels = getDuelsFolder()
    local pad = duels and duels:FindFirstChild(padName)
    local important = pad and pad:FindFirstChild("Important")
    local part = important and important:FindFirstChild(teamName)
    return part and part:IsA("BasePart") and part or nil
end

local function getOppositeTeamName(teamName)
    return teamName == "Team1" and "Team2" or "Team1"
end

local function getPadParts(padName, teamName)
    return getTeamPart(padName, teamName), getTeamPart(padName, getOppositeTeamName(teamName))
end

local function isRootOnPart(root, part)
    local localPosition = part.CFrame:PointToObjectSpace(root.Position)
    local half = part.Size * 0.5
    local yLimit = half.Y + 8
    return math.abs(localPosition.X) <= half.X + 2
        and math.abs(localPosition.Z) <= half.Z + 2
        and math.abs(localPosition.Y) <= yLimit
end

local function getOccupyingPlayer(part)
    local localPlayer = Players.LocalPlayer
    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= localPlayer then
            local character = player.Character
            local root = character and character:FindFirstChild("HumanoidRootPart")
            if root and isRootOnPart(root, part) then
                return player
            end
        end
    end
    return nil
end

local function getDetectedPlayersText()
    local rows = {}
    local localPlayer = Players.LocalPlayer
    for _, player in ipairs(Players:GetPlayers()) do
        local role = getAccountRole(player) or "Unlisted"
        local label = player.Name .. ":" .. role
        if player == localPlayer then label ..= "(You)" end
        table.insert(rows, label)
    end
    return #rows > 0 and table.concat(rows, ", ") or "none"
end

local function hasPartnerInServer()
    local partner, reason = getAssignedPartner()
    if partner and partner ~= Players.LocalPlayer then
        return true, partner
    end
    return false, reason
end

local function stepAwayFromPart()
    local root = getLocalCharacterRoot()
    if not root then
        statusText = "No character"
        updateTracker()
        notify(statusText)
        return
    end
    root.CFrame = CFrame.new(failPosition)
end

local function teleportToPart(part)
    local root = getLocalCharacterRoot()
    if not root then
        statusText = "No character"
        updateTracker()
        notify(statusText)
        return false
    end
    root.CFrame = part.CFrame + Vector3.new(0, 5, 0)
    return true
end

local function moveToSelectedQueue()
    local teamName = ROLE_TO_TEAM[selectedRole]
    if not teamName then
        statusText = "Pick Main or Alt"
        updateTracker()
        notify(statusText)
        return false
    end

    local hasPartner, partnerOrReason = hasPartnerInServer()
    if not hasPartner then
        local expectedRole = getExpectedPartnerRole() or "partner"
        statusText = "Waiting for " .. expectedRole .. " | " .. tostring(partnerOrReason or "No assigned partner") .. " | Seen: " .. getDetectedPlayersText()
        updateTracker()
        return false
    end

    local foundPad = false
    local lastBlocker = nil
    for _, padName in ipairs(QUEUE_PAD_NAMES) do
        local targetPart, oppositePart = getPadParts(padName, teamName)
        if targetPart and oppositePart then
            foundPad = true
            local targetOccupant = getOccupyingPlayer(targetPart)
            local oppositeOccupant = getOccupyingPlayer(oppositePart)
            local blocker = targetOccupant
            if oppositeOccupant and not isExpectedPartner(oppositeOccupant) then
                blocker = oppositeOccupant
            end
            if blocker then
                lastBlocker = blocker
            else
                if oppositeOccupant and isExpectedPartner(oppositeOccupant) then
                    queueLockActive = true
                    statusText = "Partner on " .. padName
                    updateTracker()
                end
                if teleportToPart(targetPart) then
                    currentTargetPart = targetPart
                    currentPadName = padName
                    currentTeamName = teamName
                    statusText = selectedRole .. " -> " .. padName .. " " .. teamName
                    updateTracker()
                    notify(statusText)
                    task.delay(1, function()
                        if startEnabled then voteArena("Queued") end
                    end)
                    return true
                end
                return false
            end
        end
    end

    currentTargetPart = nil
    currentPadName = nil
    currentTeamName = nil
    statusText = foundPad and (lastBlocker and ("Waiting: " .. lastBlocker.Name) or "Waiting for clear pad") or "Queue pad missing"
    updateTracker()
    return false
end

local function startPadMonitor()
    monitorToken += 1
    local thisToken = monitorToken
    task.spawn(function()
        while startEnabled and thisToken == monitorToken do
            if queueLockActive then
                updateTracker()
            elseif not currentTargetPart or not currentPadName or not currentTeamName then
                moveToSelectedQueue()
            else
                local oppositePart = getTeamPart(currentPadName, getOppositeTeamName(currentTeamName))
                local targetOccupant = getOccupyingPlayer(currentTargetPart)
                local oppositeOccupant = oppositePart and getOccupyingPlayer(oppositePart)
                local blocker = targetOccupant
                if oppositeOccupant and not isExpectedPartner(oppositeOccupant) then
                    blocker = oppositeOccupant
                end
                if blocker then
                    statusText = "Blocked: " .. blocker.Name
                    stepAwayFromPart()
                    currentTargetPart = nil
                    currentPadName = nil
                    currentTeamName = nil
                    updateTracker()
                    notify(statusText)
                    task.wait(0.25)
                    moveToSelectedQueue()
                end
            end
            task.wait(0.5)
        end
    end)
end

local updateWeaponSlotVisibility

local function setRole(role, enabled)
    if enabled then
        selectedRole = role
        currentTargetPart = nil
        currentPadName = nil
        currentTeamName = nil
        queueLockActive = false
        statusText = startEnabled and "Waiting to start" or (role .. " selected")
    elseif selectedRole == role then
        selectedRole = "None"
        currentTargetPart = nil
        currentPadName = nil
        currentTeamName = nil
        queueLockActive = false
        statusText = startEnabled and "Pick Main or Alt" or "Idle"
    end
    updateWeaponSlotVisibility()
    updateTracker()
    notify(statusText)
end

updateWeaponSlotVisibility = function()
    local isMain = selectedRole == "Main"
    setControlVisible("rue/auto/weapon_slot", isMain)
    if not isMain and selectedWeaponSlot ~= "None" then
        selectedWeaponSlot = "None"
        setTextbox("rue/tracker/weapon_slot", selectedWeaponSlot)
    end
end

local function setWeaponSlot(slot)
    local slotText = tostring(slot or "None")
    if slotText ~= "1" and slotText ~= "2" and slotText ~= "3" and slotText ~= "4" then
        slotText = "None"
    end
    if selectedRole ~= "Main" and slotText ~= "None" then
        selectedWeaponSlot = "None"
        statusText = "Weapon slot is Main only"
    else
        selectedWeaponSlot = slotText
        statusText = slotText == "None" and "Weapon slot cleared" or ("Weapon slot " .. slotText .. " selected")
    end
    updateTracker()
    notify(statusText)
end

local mainPage = window:Page({name = "Main", size = 80})
do
    local infoSection = mainPage:Section({name = "Information", side = "Left"})
    infoSection:Textbox({pointer = "rue/info/port", placeholder = "Port", text = tostring(ruePort), middle = true, reset_on_focus = false})
    infoSection:Button({name = "Copy Port", callback = function()
        if setclipboard then setclipboard(tostring(ruePort)) end
        notify("Port: " .. tostring(ruePort))
    end})
    infoSection:Textbox({pointer = "rue/info/connect_port", placeholder = "Connect Port", text = "", middle = true, reset_on_focus = false, callback = function(value)
        connectedPort = tostring(value or "")
    end})
    infoSection:Button({name = "Connect Port", callback = connectPort})

    local autoSection = mainPage:Section({name = "AUTO", side = "Right"})
    autoSection:Toggle({pointer = "rue/auto/start", name = "Start", default = false, callback = function(state)
        startEnabled = state
        currentTargetPart = nil
        currentPadName = nil
        currentTeamName = nil
        queueLockActive = false
        if state then
            statusText = "Waiting to start"
            voteStatus = "Waiting for match"
            updateTracker()
            startMatchDetector()
            startPadMonitor()
        else
            monitorToken += 1
            clearVoteConnections()
            if activeMainTween then pcall(function() activeMainTween:Cancel() end) end
            statusText = "Stopped"
            voteStatus = "Idle"
            invincibilityStatus = "Unknown"
            updateTracker()
        end
        notify(statusText)
    end})
    autoSection:Toggle({pointer = "rue/auto/main", name = "Main", default = false, callback = function(state) setRole("Main", state) end})
    autoSection:Toggle({pointer = "rue/auto/alt", name = "Alt", default = false, callback = function(state) setRole("Alt", state) end})
    autoSection:Dropdown({
        pointer = "rue/auto/weapon_slot",
        Pointer = "rue/auto/weapon_slot",
        name = "Weapon Slot",
        Name = "Weapon Slot",
        options = {"None", "1", "2", "3", "4"},
        Options = {"None", "1", "2", "3", "4"},
        default = "None",
        Default = "None",
        callback = function(choice) setWeaponSlot(choice) end,
    })
    updateWeaponSlotVisibility()
    autoSection:Textbox({pointer = "rue/tracker/role", placeholder = "Role", text = selectedRole, middle = true, reset_on_focus = false})
    autoSection:Textbox({pointer = "rue/tracker/connected_port", placeholder = "Connected Port", text = "None", middle = true, reset_on_focus = false})
    autoSection:Textbox({pointer = "rue/tracker/status", placeholder = "Status", text = statusText, middle = true, reset_on_focus = false})
    autoSection:Textbox({pointer = "rue/tracker/vote", placeholder = "Vote", text = voteStatus, middle = true, reset_on_focus = false})
    autoSection:Textbox({pointer = "rue/tracker/invincible", placeholder = "Invincible", text = invincibilityStatus, middle = true, reset_on_focus = false})
    autoSection:Textbox({pointer = "rue/tracker/weapon_slot", placeholder = "Weapon Slot", text = selectedWeaponSlot, middle = true, reset_on_focus = false})
end

local settingsPage = window:Page({name = "Settings", side = "Left", size = 100})
do
    local menuSection = settingsPage:Section({name = "Menu", side = "Left"})
    menuSection:Keybind({pointer = "rue/settings/menu_bind", name = "Bind", default = Enum.KeyCode.RightShift, callback = function(key)
        window.uibind = key
    end})
    menuSection:Toggle({pointer = "rue/settings/watermark", name = "Watermark", default = true, callback = function(state)
        if window.watermark then window.watermark:Update("Visible", state) end
    end})
    menuSection:Button({name = "Unload", confirmation = true, callback = function()
        monitorToken += 1
        if activeMainTween then pcall(function() activeMainTween:Cancel() end) end
        window:Unload()
    end})

    local themeSection = settingsPage:Section({name = "Theme", side = "Right"})
    themeSection:Dropdown({
        Name = "Accent",
        Options = {"Rue", "Mint", "Red", "Blue", "White"},
        Default = "Rue",
        Pointer = "rue/settings/accent",
        callback = function(choice)
            local colors = {
                Rue = Color3.fromRGB(175, 95, 255),
                Mint = Color3.fromRGB(0, 255, 139),
                Red = Color3.fromRGB(250, 47, 47),
                Blue = Color3.fromRGB(70, 140, 255),
                White = Color3.fromRGB(235, 235, 235),
            }
            library:UpdateColor("Accent", colors[choice] or colors.Rue)
        end,
    })
    themeSection:Colorpicker({pointer = "rue/settings/custom_accent", name = "Custom Accent", default = Color3.fromRGB(175, 95, 255), callback = function(color)
        library:UpdateColor("Accent", color)
    end})
end

window.uibind = Enum.KeyCode.RightShift
window:Initialize()
notify("Rue Hub loaded | Port: " .. tostring(ruePort))
