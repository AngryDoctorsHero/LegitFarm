local getIdentity = getthreadidentity or get_thread_identity or (syn and syn.get_thread_identity)
local setIdentity = setthreadidentity or set_thread_identity or setidentity or (syn and syn.set_thread_identity)
local UI_IDENTITY = getIdentity and getIdentity() or nil
local function withUiIdentity(fn)
    if setIdentity and UI_IDENTITY then
        pcall(setIdentity, UI_IDENTITY)
    end
    return pcall(fn)
end

if getgenv().LegitFarmJob then
    pcall(getgenv().LegitFarmJob)
end

local Players = game:GetService("Players")
local PathfindingService = game:GetService("PathfindingService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local LocalPlayer = Players.LocalPlayer
local TreesFolder = workspace:WaitForChild("Environment"):WaitForChild("Foliage"):WaitForChild("Trees")

local JOB_NAME = "WoodCutter - Lovely Lumber"
local JOB_ID = "LumberWoodcutter" -- JobHandler._jobValue.Value
local JANITOR_NAME = "Janitor - High School"
local JANITOR_ID = "SchoolJanitor"
local TAXI_NAME = "Taxi Driver"
local TAXI_ID = "TaxiJob"
local ICE_NAME = "Seller - Ben's Ice Cream"
local ICE_ID = "BensIceCreamSeller"
local CASH_NAME = "Fast Food Worker - Cashier"
local CASH_ID = "BloxBurgersEmployee"
local PIZZA_NAME = "Pizza Planet - Pizza Baker"
local PIZZA_ID = "PizzaPlanetBaker"
local TEACHER_NAME = "Teacher - High School"
local TEACHER_ID = "HighSchoolTeacher"
local JOB_IDS = {
    [JOB_NAME] = JOB_ID, [JANITOR_NAME] = JANITOR_ID, [TAXI_NAME] = TAXI_ID, [ICE_NAME] = ICE_ID, [CASH_NAME] = CASH_ID,
    ["Fast Food Worker - Burger Cook"] = CASH_ID, [PIZZA_NAME] = PIZZA_ID, [TEACHER_NAME] = TEACHER_ID,
    ["BFF Supermarket"] = "SupermarketCashier", ["Hairdresser - Stylez Hair Studio"] = "StylezHairdresser",
    ["Fisherman - Fishing Hut"] = "HutFisherman", ["Mechanic - Mike's Motors"] = "MikesMechanic",
    ["Stocker - BFF Supermarket"] = "SupermarketStocker",
}
local CHOP_RANGE = 6
local MAX_SWINGS = 25
local TREE_COOLDOWN = 90
local BAD_TREE_COOLDOWN = 60
local TREE_CACHE_TTL = 30
local STAND_DISTANCE = 4.5

local TREE_FOLDERS = { "Spruce Tree" }

local AGENT_TRIES = {
    { AgentRadius = 1.5, AgentHeight = 5, AgentCanJump = false },
    { AgentRadius = 1, AgentHeight = 4, AgentCanJump = false },
    { AgentRadius = 1, AgentHeight = 4, AgentCanJump = true },
}

local running = true
local farming = false
local ghostOn, ghostMode, ghostLabelSet = false, nil, nil
local selectedJob = nil
local fallen = {}
local farmThread
local FarmToggle
local treeCache, treeCacheTime = {}, 0
local lastWarn = 0

-- Game modules (already loaded by the game, no heap scanning)
local okMods, DataService, HotbarUI, JobHandler = pcall(function()
    return require(ReplicatedStorage.Modules.DataService),
        require(LocalPlayer.PlayerScripts.Modules._UI.HUDHandler.HotbarUI),
        require(LocalPlayer.PlayerScripts.Modules.JobHandler)
end)
assert(okMods and DataService and HotbarUI and JobHandler, "Legit Farm Job: game modules not found")
local net = DataService

-- Detection guard
local origFireServer, origInvokeServer = DataService.FireServer, DataService.InvokeServer
local PlayerModules = LocalPlayer:WaitForChild("PlayerScripts"):WaitForChild("Modules")

local function chopSafe()
    if DataService.FireServer ~= origFireServer or DataService.InvokeServer ~= origInvokeServer then
        return false
    end
    local fn = HotbarUI.EquipData and HotbarUI.EquipData.Function
    if type(fn) ~= "function" then
        return false
    end
    if isexecutorclosure and isexecutorclosure(fn) then
        return false
    end
    local env = getfenv(fn)
    local src = env and env.script
    return typeof(src) == "Instance" and src.Parent ~= nil and src:IsDescendantOf(PlayerModules)
end

local function hatchetRootStale(root)
    local fn = HotbarUI.EquipData and HotbarUI.EquipData.Function
    if type(fn) ~= "function" or not debug.getupvalues then
        return false
    end
    local ok, ups = pcall(debug.getupvalues, fn)
    if not ok or type(ups) ~= "table" then
        return false
    end
    for _, v in pairs(ups) do
        if typeof(v) == "Instance" and v.Name == "HumanoidRootPart" then
            return v ~= root
        end
    end
    return false
end

-- Rayfield UI
local Rayfield = loadstring(game:HttpGet("https://sirius.menu/rayfield"))()

local Window = Rayfield:CreateWindow({
    Name = "Legit Farm Job [Undetected]",
    LoadingTitle = "Legit Farm Job [Undetected]",
    LoadingSubtitle = "Bloxburg",
    ConfigurationSaving = { Enabled = false },
    KeySystem = false,
})

local JobsTab = Window:CreateTab("Jobs", "briefcase")
JobsTab:CreateSection("Job Selection")

local StatusLabel
local lastStatus

local function setStatus(text)
    if ghostOn then
        return -- Ghost Patrol writes its own status in the Halloween Event tab
    end
    if StatusLabel and text ~= lastStatus then
        lastStatus = text
        withUiIdentity(function()
            StatusLabel:Set("Status: " .. text)
        end)
    end
end

-- Helpers
local function getChar()
    local char = LocalPlayer.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    local root = char and char:FindFirstChild("HumanoidRootPart")
    if hum and root and hum.Health > 0 then
        return char, hum, root
    end
end

local function isWorkingWoodcutter()
    local ok, working = pcall(function()
        return JobHandler:IsWorking() and JobHandler._jobValue.Value == JOB_ID
    end)
    return ok and working
end

local function isWorkingJob(jobId)
    if not jobId then
        return false
    end
    local ok, working = pcall(function()
        return JobHandler:IsWorking() and JobHandler._jobValue.Value == jobId
    end)
    return ok and working
end

local function isStanding(tree)
    local body, origin, leaves = tree:FindFirstChild("Body"), tree:FindFirstChild("Origin"), tree:FindFirstChild("Leaves")
    if not (body and origin and leaves) or tree.Parent == nil then
        return false
    end
    if leaves.Transparency > 0.5 then
        return false
    end
    local d = Vector3.new(body.Position.X - origin.Position.X, 0, body.Position.Z - origin.Position.Z)
    return d.Magnitude < 2
end

local function refreshTreeCache()
    table.clear(treeCache)
    for _, folderName in ipairs(TREE_FOLDERS) do
        local folder = TreesFolder:FindFirstChild(folderName)
        if folder then
            for _, m in ipairs(folder:GetChildren()) do
                if m:IsA("Model") and m:GetAttribute("_lumberjackTree") and m:FindFirstChild("Origin")
                    and m:FindFirstChild("Body") and not m:FindFirstChild("CollisionPart") then
                    table.insert(treeCache, m)
                end
            end
        end
    end
    local now = os.clock()
    for tree, untilT in pairs(fallen) do
        if untilT <= now or tree.Parent == nil then
            fallen[tree] = nil
        end
    end
    treeCacheTime = os.clock()
end

local function findTree(rootPos)
    if os.clock() - treeCacheTime > TREE_CACHE_TTL or #treeCache == 0 then
        refreshTreeCache()
    end
    local best, bestDist
    local now = os.clock()
    for _, tree in ipairs(treeCache) do
        if tree.Parent and not (fallen[tree] and fallen[tree] > now) and isStanding(tree) then
            local dist = (tree.Origin.Position - rootPos).Magnitude
            if not bestDist or dist < bestDist then
                best, bestDist = tree, dist
            end
        end
    end
    return best
end

-- Same ray the Hatchet module uses
local function rayHitsTree(root, tree)
    for i = -1, 1, 0.5 do
        local dir = (root.CFrame * CFrame.Angles(0, i * math.rad(10), 0)).LookVector * CHOP_RANGE
        local hit = workspace:FindPartOnRayWithWhitelist(Ray.new(root.Position, dir), { TreesFolder })
        if hit and (hit.Name == "Body" or hit.Name == "CollisionPart") and hit.Parent == tree then
            return true
        end
    end
    return false
end

local function groundPoint(x, z, refY, char)
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = { char, TreesFolder }
    local hit = workspace:Raycast(Vector3.new(x, refY + 30, z), Vector3.new(0, -80, 0), params)
    return hit and hit.Position or Vector3.new(x, refY, z)
end

local STALL_TIME, STALL_DIST = 0.8, 0.5
local walkAbort, walkProgress
local function makeStallCheck(root)
    local ref, refT = root.Position, os.clock()
    return function()
        local now = os.clock()
        if now - refT < STALL_TIME then
            return false
        end
        local p = root.Position
        local moved = (Vector3.new(p.X, 0, p.Z) - Vector3.new(ref.X, 0, ref.Z)).Magnitude
        ref, refT = p, now
        return moved < STALL_DIST
    end
end

local function moveToPoint(hum, pos, timeout, radius, root)
    root = root or hum.RootPart
    local stalled = makeStallCheck(root)
    if radius and root then
        local arrived = false
        local conn = hum.MoveToFinished:Connect(function(ok)
            if ok then
                arrived = true
            end
        end)
        hum:MoveTo(pos)
        local t0 = os.clock()
        local result = false
        while running and (farming or ghostOn) and os.clock() - t0 < timeout do
            local rp = root.Position
            if arrived or (Vector3.new(rp.X, 0, rp.Z) - Vector3.new(pos.X, 0, pos.Z)).Magnitude <= radius then
                result = true
                break
            end
            if stalled() or (walkAbort and walkAbort()) then
                break
            end
            RunService.Heartbeat:Wait()
        end
        conn:Disconnect()
        return result
    end
    local finished, reached = false, false
    local conn = hum.MoveToFinished:Connect(function(ok)
        finished, reached = true, ok
    end)
    hum:MoveTo(pos)
    local t0 = os.clock()
    while not finished and running and (farming or ghostOn) and os.clock() - t0 < timeout do
        if (root and stalled()) or (walkAbort and walkAbort()) then
            break
        end
        task.wait(0.05)
    end
    conn:Disconnect()
    return reached
end

local function cutBlocked(params, a, b)
    local d = b - a
    if d.Magnitude < 0.05 then
        return false
    end
    local ok, hit = pcall(function()
        return workspace:Blockcast(CFrame.new(a + Vector3.new(0, 3.1, 0)), Vector3.new(2.4, 3.2, 2.4), d, params)
    end)
    return not ok or (hit ~= nil and hit.Instance.CanCollide)
end

local walkAgents
local walkPathOK
local function computePath(from, to, noJump)
    for _, cfg in ipairs(walkAgents or AGENT_TRIES) do
        if not (noJump and cfg.AgentCanJump) then
            local path = PathfindingService:CreatePath(cfg)
            local ok = pcall(function()
                path:ComputeAsync(from, to)
            end)
            if ok and path.Status == Enum.PathStatus.Success and (not walkPathOK or walkPathOK(path)) then
                return path
            end
            task.wait(0.1)
        end
    end
end

local function walkTo(target, strict)
    if walkProgress then
        walkProgress = os.clock()
    end
    for _ = 1, 3 do
        local _, hum, root = getChar()
        if not hum then
            return false
        end
        if (Vector3.new(root.Position.X, 0, root.Position.Z) - Vector3.new(target.X, 0, target.Z)).Magnitude < 2.5 then
            return true
        end
        local path = computePath(root.Position, target, strict)
        if not path then
            return false, "no path"
        end
        local blocked = false
        local wps = path:GetWaypoints()
        if strict then
            local last = wps[#wps]
            local jumps = false
            for _, w in ipairs(wps) do
                if w.Action == Enum.PathWaypointAction.Jump then
                    jumps = true
                    break
                end
            end
            if jumps or not last
                or (Vector3.new(last.Position.X, 0, last.Position.Z) - Vector3.new(target.X, 0, target.Z)).Magnitude > 3
                or math.abs(last.Position.Y - target.Y) > 2.5 then
                return false, "no path"
            end
        end
        local castParams = RaycastParams.new()
        castParams.FilterType = Enum.RaycastFilterType.Exclude
        local ignore = {}
        for _, plr in ipairs(Players:GetPlayers()) do
            if plr.Character then
                table.insert(ignore, plr.Character)
            end
        end
        castParams.FilterDescendantsInstances = ignore
        for i, wp in ipairs(wps) do
            if not (running and (farming or ghostOn)) then
                return false
            end
            if i > 1 then
                if wp.Action == Enum.PathWaypointAction.Jump then
                    hum.Jump = true
                end
                local radius
                local nextWp = wps[i + 1]
                if nextWp and wp.Action ~= Enum.PathWaypointAction.Jump and nextWp.Action ~= Enum.PathWaypointAction.Jump then
                    radius = 2
                    local a, b = wp.Position - wps[i - 1].Position, nextWp.Position - wp.Position
                    if a.Magnitude > 0.01 and b.Magnitude > 0.01 and a.Unit:Dot(b.Unit) < 0.85 then
                        radius = 1
                    elseif cutBlocked(castParams, wps[i - 1].Position, nextWp.Position) then
                        radius = 0.8
                    end
                end
                if moveToPoint(hum, wp.Position, 3, radius, root) then
                    if walkProgress then
                        walkProgress = os.clock()
                    end
                else
                    blocked = true
                    if walkAbort and walkAbort() then
                        return false, "gave up"
                    end
                    if running and (farming or ghostOn) then
                        local back = wps[i - 1].Position
                        hum:MoveTo(back)
                        local tb = os.clock()
                        while running and (farming or ghostOn) and os.clock() - tb < 0.4 do
                            local rp = root.Position
                            if (Vector3.new(rp.X, 0, rp.Z) - Vector3.new(back.X, 0, back.Z)).Magnitude <= 1.2 then
                                break
                            end
                            RunService.Heartbeat:Wait()
                        end
                    end
                    break
                end
            end
        end
        if not blocked then
            return true
        end
        task.wait(0.1)
    end
    return false, "blocked"
end

local function chopReady()
    local data = HotbarUI.EquipData
    return data and data.Name == "Hatchet" and data.Title == "I_Chop" and type(data.Function) == "function"
end

local function swing()
    if not chopReady() then
        task.wait(0.25)
        return false
    end
    if not chopSafe() then
        farming = false
        if FarmToggle then
            withUiIdentity(function()
                FarmToggle:Set(false)
            end)
        end
        setStatus("Stopped: unsafe chop state")
        return false
    end
    local _, _, curRoot = getChar()
    if not curRoot or hatchetRootStale(curRoot) then
        task.wait(0.5)
        return false
    end
    local ok, err = pcall(HotbarUI.EquipData.Function)
    if not ok then
        if os.clock() - lastWarn > 10 then
            lastWarn = os.clock()
            warn("[Legit Farm Job] chop failed: " .. tostring(err))
        end
        task.wait(1)
        return false
    end
    task.wait(0.1 + math.random() * 0.25)
    return true
end

local function chopTree(tree)
    local startPos = tree.Body.Position
    for _ = 1, MAX_SWINGS do
        local _, hum, root = getChar()
        if not (hum and running and farming and isWorkingWoodcutter()) then
            return false
        end
        if fallen[tree] or not tree.Parent or (tree.Body.Position - startPos).Magnitude > 2 then
            return true
        end
        local tries = 0
        while not rayHitsTree(root, tree) and tries < 12 and running and farming do
            local target = Vector3.new(tree.Origin.Position.X, root.Position.Y, tree.Origin.Position.Z)
            hum:MoveTo(target)
            task.wait(0.15)
            tries += 1
        end
        hum:MoveTo(root.Position)
        if not rayHitsTree(root, tree) then
            return false
        end
        swing()
    end
    return false
end

-- Janitor - High School
local okIH, InteractionHandler = pcall(require, PlayerModules:WaitForChild("InteractionHandler"))
if not okIH then
    InteractionHandler = nil
end
local badTrash = {}
local interactRegistry

local function getInteractRegistry()
    if interactRegistry then
        return interactRegistry
    end
    if not (InteractionHandler and debug.getupvalues) then
        return nil
    end
    local ok, ups = pcall(debug.getupvalues, InteractionHandler.AddInteraction)
    if ok and type(ups) == "table" then
        for _, v in pairs(ups) do
            if type(v) == "table" and v ~= InteractionHandler then
                interactRegistry = v
                break
            end
        end
    end
    return interactRegistry
end

local function getCleanCallback(obj)
    local reg = getInteractRegistry()
    local entry = reg and reg[obj]
    local gens = entry and entry[1]
    local gen = type(gens) == "table" and gens[1]
    if type(gen) ~= "function" then
        return nil
    end
    local ok, text, _, cb = pcall(gen)
    if ok and text == "I_CleanUp" and type(cb) == "function" then
        return cb
    end
end

local function isVisibleTrash(obj)
    if obj:IsA("BasePart") and obj.Transparency < 1 then
        return true
    end
    for _, p in ipairs(obj:QueryDescendants("BasePart")) do
        if p.Transparency < 1 then
            return true
        end
    end
    for _, d in ipairs(obj:QueryDescendants("Decal")) do
        if d.Transparency < 0.95 then
            return true
        end
    end
    return false
end

local function getJanitorSpawns()
    local env = workspace:FindFirstChild("Environment")
    local loc = env and env:FindFirstChild("Locations")
    local area = loc and loc:FindFirstChild("SchoolArea")
    local school = area and area:FindFirstChild("School")
    return school and school:FindFirstChild("JanitorSpawns")
end

-- Order: one area at a time - every mess on the first floor (the floor the job teleport puts the character on), then
-- the second floor, then outside - and an area is only left once the messes it had when the character started on it are
-- all cleaned; messes that appear there meanwhile wait for the next round (seen live: new first floor messes appeared
-- about as fast as they were cleaned, 15 cleaned in 3 minutes with 2-6 always waiting, and the second floor was never
-- reached while its messes went from 10 to 14). Found live:
-- SchoolArea.School.JanitorSpawns holds 55 spawns (GroundSpawn x31, WallSpawn x24); the floor a spawn belongs to is the
-- floor under it (30 at the teleport's level y 24, 25 on the floor above at y 44); outside = no roof above it (none of
-- the 55 had open sky above, live). Within an area: the nearest mess first, as before.
local findTrash
do
local spawnArea = setmetatable({}, { __mode = "k" }) -- spawn -> 1 first floor, 2 second floor, 3 outside
local phase, round = 0, setmetatable({}, { __mode = "k" }) -- the area being cleaned, and its messes when it was started

local function areaOf(spawn)
    local a = spawnArea[spawn]
    if a then
        return a
    end
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    local ignore = { spawn.Parent }
    for _, plr in ipairs(Players:GetPlayers()) do
        if plr.Character then
            table.insert(ignore, plr.Character)
        end
    end
    params.FilterDescendantsInstances = ignore
    local p = spawn.Position
    local wall = spawn.Name == "WallSpawn"
    if not workspace:Raycast(wall and p or p + Vector3.new(0, 3, 0), Vector3.new(0, 80, 0), params) then
        a = 3
    else
        -- the floor under it (a wall spawn: the floor in front of the wall it is on)
        local floorY
        local n = Vector3.new(spawn.CFrame.UpVector.X, 0, spawn.CFrame.UpVector.Z)
        for _, off in ipairs(wall and n.Magnitude > 0.3 and { n.Unit * 3, -n.Unit * 3 } or { Vector3.zero }) do
            local h = workspace:Raycast(p + off + Vector3.new(0, 1, 0), Vector3.new(0, -30, 0), params)
            if h then
                floorY = h.Position.Y
                break
            end
        end
        local school = spawn.Parent.Parent
        local tp = school and school:FindFirstChild("WorkTeleport_SchoolJanitor")
        local baseY = tp and tp.Position.Y or 24
        a = (floorY or p.Y) < baseY + 8 and 1 or 2
    end
    spawnArea[spawn] = a
    return a
end

function findTrash(rootPos)
    local spawns = getJanitorSpawns()
    if not spawns then
        return nil
    end
    local now = os.clock()
    for o, untilT in pairs(badTrash) do
        if untilT <= now or o.Parent == nil then
            badTrash[o] = nil
        end
    end
    local found = { {}, {}, {} } -- per area: { { obj, spawn, score } }
    for _, spawn in ipairs(spawns:GetChildren()) do
        local obj = spawn:FindFirstChild("Object")
        if obj and obj.Parent == spawn and not (badTrash[obj] and badTrash[obj] > now)
            and getCleanCallback(obj) and isVisibleTrash(obj) then
            local pos = obj:GetPivot().Position
            local score = (Vector3.new(pos.X, 0, pos.Z) - Vector3.new(rootPos.X, 0, rootPos.Z)).Magnitude
                + math.abs(pos.Y - rootPos.Y) * 2
            table.insert(found[areaOf(spawn)], { obj, spawn, score })
        end
    end
    local function nearestOf(list, onlyRound)
        local b
        for _, e in ipairs(list) do
            if (not onlyRound or round[e[1]]) and (not b or e[3] < b[3]) then
                b = e
            end
        end
        return b
    end
    -- the messes of the area being cleaned that it had when it was started, the nearest first
    local b = phase > 0 and nearestOf(found[phase], true)
    if b then
        return b[1], b[2]
    end
    -- those are done: the next area in the order (first floor, second floor, outside) that has a mess, starting from
    -- the one after this (the first time: the first floor)
    for k = 1, 3 do
        local a = phase == 0 and k or (phase - 1 + k) % 3 + 1
        if #found[a] > 0 then
            phase = a
            table.clear(round)
            for _, e in ipairs(found[a]) do
                round[e[1]] = true
            end
            b = nearestOf(found[a], false)
            return b[1], b[2]
        end
    end
    return nil
end
end

local function floorBelow(x, y, z, ignore)
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = ignore
    local hit = workspace:Raycast(Vector3.new(x, y + 1, z), Vector3.new(0, -14, 0), params)
    return hit and hit.Position
end

local function trashStandPoints(spawn, obj, char, rootPos)
    local ignore = { char, obj }
    local pos = obj:GetPivot().Position
    local out = {}
    local function add(x, y, z)
        local floor = floorBelow(x, y, z, ignore)
        if floor then
            table.insert(out, floor)
        end
    end
    local away = Vector3.new(rootPos.X - pos.X, 0, rootPos.Z - pos.Z)
    away = away.Magnitude > 0.1 and away.Unit or Vector3.new(0, 0, 1)
    if spawn.Name == "WallSpawn" then
        local part = obj.PrimaryPart or spawn
        local n = part.CFrame.UpVector
        n = Vector3.new(n.X, 0, n.Z)
        if n.Magnitude > 0.3 then
            n = n.Unit
            local first, second = n, -n
            if first:Dot(away) < 0 then
                first, second = second, first
            end
            add(pos.X + first.X * 3, pos.Y, pos.Z + first.Z * 3)
            add(pos.X + second.X * 3, pos.Y, pos.Z + second.Z * 3)
        end
        add(pos.X + away.X * 3, pos.Y, pos.Z + away.Z * 3)
    else
        add(pos.X + away.X * 2.5, pos.Y + 3, pos.Z + away.Z * 2.5)
        add(pos.X, pos.Y + 3, pos.Z)
    end
    return out
end

local function cleanSafe(cb)
    if DataService.FireServer ~= origFireServer or DataService.InvokeServer ~= origInvokeServer then
        return false
    end
    if isexecutorclosure and isexecutorclosure(cb) then
        return false
    end
    local env = getfenv(cb)
    local src = env and env.script
    return typeof(src) == "Instance" and src.Parent ~= nil and src:IsDescendantOf(PlayerModules)
end

local function cleanObject(obj)
    local cb = getCleanCallback(obj)
    if not cb then
        return false
    end
    if not cleanSafe(cb) then
        farming = false
        if FarmToggle then
            withUiIdentity(function()
                FarmToggle:Set(false)
            end)
        end
        setStatus("Stopped: unsafe clean state")
        return false
    end
    pcall(cb)
    local t0 = os.clock()
    local nextCheck = t0 + 0.6
    while obj.Parent and running and farming and os.clock() - t0 < 12 do
        RunService.Heartbeat:Wait()
        local now = os.clock()
        if now >= nextCheck then
            nextCheck = now + 0.1
            if obj.Parent and getCleanCallback(obj) then
                break
            end
        end
    end
    return obj.Parent == nil
end

local function janitorStep()
    if not farming then
        task.wait(0.3)
        return
    end
    if not isWorkingJob(JANITOR_ID) then
        setStatus("Start the Janitor job first")
        task.wait(1)
        return
    end
    local char, hum, root = getChar()
    if not hum then
        setStatus("Waiting for character")
        task.wait(1)
        return
    end
    local obj, spawn = findTrash(root.Position)
    if not obj then
        setStatus("No trash found, waiting")
        task.wait(2)
        return
    end
    setStatus("Walking to trash")
    local reached, gaveUp = false, false
    local tStart = os.clock()
    walkProgress = tStart
    walkAbort = function()
        local now = os.clock()
        return now - walkProgress > 5 or now - tStart > 60
    end
    for _, stand in ipairs(trashStandPoints(spawn, obj, char, root.Position)) do
        if not (running and farming) then
            walkAbort, walkProgress = nil, nil
            return
        end
        local ok, why = walkTo(stand, true)
        if ok then
            reached = true
            break
        end
        if why == "gave up" or walkAbort() then
            gaveUp = true
            break
        end
    end
    walkAbort, walkProgress = nil, nil
    if not (running and farming) then
        return
    end
    if not reached or not obj.Parent then
        badTrash[obj] = os.clock() + (gaveUp and 120 or 300)
        setStatus("Can't reach trash, trying another")
        local _, h2, r2 = getChar()
        if h2 and r2 then
            h2:MoveTo(r2.Position) -- stop where it is
        end
        task.wait(0.2)
        return
    end
    setStatus("Cleaning trash")
    if not cleanObject(obj) and obj.Parent then
        badTrash[obj] = os.clock() + 120 -- server refused / not cleanable
    end
    task.wait(0.1 + math.random() * 0.25)
end

-- Taxi Driver
local CollectionService = game:GetService("CollectionService")
local TAXI_MAX = 48
local TAXI_CRUISE = 48
local TAXI_DECEL = 14
local taxiTask, taxiSerial, taxiSlowUntil = nil, 0, 0
local badTaxi = {}
local taxiCrumbs = {}
local taxiBadShortcut = {} -- 12-stud cell of a shortcut's end point -> true after a shortcut to there went wrong

local taxiAux = {
    ground = setmetatable({}, { __mode = "k" }),
    soft = setmetatable({}, { __mode = "k" }),
    pass = setmetatable({}, { __mode = "k" }),
}
local function taxiGroundLike(i)
    local c = taxiAux.ground[i]
    if c ~= nil then
        return c
    end
    if not taxiAux.rn or not taxiAux.rn.Parent then
        local env = workspace:FindFirstChild("Environment")
        taxiAux.rn = env and env:FindFirstChild("RoadsNetwork")
    end
    local v = i:IsA("Terrain") or i.Name == "RoadSurface"
    if not v and taxiAux.rn ~= nil and i:IsDescendantOf(taxiAux.rn) then
        local n1, n2 = i.Name:lower(), (i.Parent and i.Parent.Name or ""):lower()
        v = true
        for _, k in ipairs({ "bollard", "sign", "barrier", "beam" }) do
            if n1:find(k, 1, true) or n2:find(k, 1, true) then
                v = false
                break
            end
        end
    end
    taxiAux.ground[i] = v
    return v
end
local function taxiPass(i)
    local c = taxiAux.pass[i]
    if c ~= nil then
        return c
    end
    local v = false
    if i:IsA("BasePart") and not taxiGroundLike(i) then
        v = true
    end
    taxiAux.pass[i] = v
    return v
end
local function taxiSoft(i)
    local c = taxiAux.soft[i]
    if c ~= nil then
        return c
    end
    local v = false
    if i:IsA("BasePart") and not taxiGroundLike(i) then
        local living = false
        local cur = i.Parent
        while cur and cur ~= workspace do
            if cur:FindFirstChildOfClass("Humanoid") or cur:GetAttribute("VehicleSource") then
                living = true
                break
            end
            cur = cur.Parent
        end
        local cf, s = i.CFrame, i.Size
        local ex = math.abs(cf.RightVector.X) * s.X + math.abs(cf.UpVector.X) * s.Y + math.abs(cf.LookVector.X) * s.Z
        local ez = math.abs(cf.RightVector.Z) * s.X + math.abs(cf.UpVector.Z) * s.Y + math.abs(cf.LookVector.Z) * s.Z
        v = not living and math.max(ex, ez) <= 14
        if v then
            local env = workspace:FindFirstChild("Environment")
            local loc = env and env:FindFirstChild("Locations")
            local plots = workspace:FindFirstChild("Plots")
            v = not ((loc and i:IsDescendantOf(loc)) or (plots and i:IsDescendantOf(plots)))
        end
    end
    taxiAux.soft[i] = v
    return v
end
local controlsObj, overrideOn, moveVec = nil, false, Vector3.zero
local taxiLog = function() end

local function flat(v)
    return Vector3.new(v.X, 0, v.Z)
end

local function installDriveInput()
    if not controlsObj then
        local ok, c = pcall(function()
            return require(LocalPlayer:WaitForChild("PlayerScripts"):WaitForChild("PlayerModule")):GetControls()
        end)
        if not (ok and c) then
            return false
        end
        controlsObj = c
    end
    if not overrideOn then
        controlsObj.GetMoveVector = function()
            local v = moveVec
            return { unit = v, X = v.X, Y = v.Y, Z = v.Z, Magnitude = v.Magnitude }
        end
        overrideOn = true
    end
    return true
end

local kinState
local function kinOn(model, pp)
    if kinState then
        return
    end
    local st = { vfs = {}, tqs = {}, cc = {} }
    st.bg = pp:FindFirstChildOfClass("BodyGyro")
    st.bv = pp:FindFirstChildOfClass("BodyVelocity")
    if st.bg then
        st.bgP = st.bg.P
        st.bg.P = 0
    end
    if st.bv then
        st.bvP = st.bv.P
        st.bv.P = 0
    end
    for _, d in ipairs(model:GetDescendants()) do
        if d:IsA("VectorForce") and d.Enabled then
            d.Enabled = false
            table.insert(st.vfs, d)
        elseif d:IsA("Torque") and d.Enabled then
            d.Enabled = false
            table.insert(st.tqs, d)
        end
    end
    kinState = st
end

local function kinOff()
    local st = kinState
    kinState = nil
    if not st then
        return
    end
    pcall(function()
        if st.bg and st.bgP then
            st.bg.P = st.bgP
        end
        if st.bv and st.bvP then
            st.bv.P = st.bvP
        end
        for _, d in ipairs(st.vfs) do
            d.Enabled = true
        end
        for _, d in ipairs(st.tqs) do
            d.Enabled = true
        end
    end)
end
local NC = { parts = {}, conns = {}, model = nil, time = 0, carOk = false }
function NC.hook(d)
    if NC.conns[d] or not d:IsA("BasePart") then
        return
    end
    if d.CanCollide then
        NC.parts[d] = true
        d.CanCollide = false
    end
    NC.conns[d] = d:GetPropertyChangedSignal("CanCollide"):Connect(function()
        if d.CanCollide and NC.model and (farming or ghostOn) then
            NC.parts[d] = true
            d.CanCollide = false
        end
    end)
end
function NC.on(model)
    if NC.model ~= model then
        NC.off()
        NC.model = model
        NC.addConn = model.DescendantAdded:Connect(function(d)
            if farming or ghostOn then
                NC.hook(d)
            end
        end)
    end
    if os.clock() - NC.time < 2 then
        return
    end
    NC.time = os.clock()
    for _, d in ipairs(model:GetDescendants()) do
        NC.hook(d)
    end
end
function NC.off()
    for _, c in pairs(NC.conns) do
        pcall(function()
            c:Disconnect()
        end)
    end
    table.clear(NC.conns)
    if NC.addConn then
        pcall(function()
            NC.addConn:Disconnect()
        end)
        NC.addConn = nil
    end
    NC.model = nil
    NC.time = 0
    for d in pairs(NC.parts) do
        pcall(function()
            d.CanCollide = true -- collisions back exactly as they were
        end)
    end
    table.clear(NC.parts)
end
local function releaseDrive()
    kinOff()
    if not (farming or ghostOn) or not NC.carOk then
        NC.off()
    end
    moveVec = Vector3.zero
    if overrideOn and controlsObj then
        controlsObj.GetMoveVector = nil
    end
    overrideOn = false
end

local function setAnalog(steer, throttle)
    local sx, tz = 0, 0
    local as = math.abs(steer)
    if as > 0.02 then
        sx = (0.05 + 0.6 * math.min(as, 1)) * (steer < 0 and -1 or 1)
    end
    local at = math.abs(throttle)
    if at > 0.02 then
        tz = -(0.05 + 0.6 * math.min(at, 1)) * (throttle < 0 and -1 or 1)
    end
    moveVec = Vector3.new(sx, 0, tz)
end

local function getTaxiVehicle()
    local char = LocalPlayer.Character
    if not char then
        return nil
    end
    local ok, weld = pcall(function()
        return JobHandler.Shared.AttachService:GetAttachWeld(char)
    end)
    if not (ok and weld and weld.Part1) then
        return nil
    end
    local model = weld.Part1.Parent
    if model and model:GetAttribute("VehicleSource") == "TaxiJob" and model.PrimaryPart then
        return model, model.PrimaryPart
    end
    -- Ghost Patrol drives its Ghost Patrol Cruiser with the same driving code
    if ghostOn and model and model.Name:find("Ghost Patrol", 1, true) and model.PrimaryPart then
        return model, model.PrimaryPart
    end
end

local function scrapeTaxiTask()
    local ok, found = pcall(function()
        for _, c in ipairs(getconnections(RunService.Heartbeat)) do
            local f = c.Function
            if f and islclosure(f) and not isexecutorclosure(f) then
                local env = getfenv(f)
                if env and env.script and tostring(env.script) == "TaxiJob" then
                    for _, v in pairs(debug.getupvalues(f)) do
                        if type(v) == "table" and type(v.Path) == "table" and typeof(v.SpotCF) == "CFrame" then
                            return v
                        end
                    end
                end
            end
        end
    end)
    return ok and found or nil
end

local function currentTaxiTask()
    if taxiTask then
        return taxiTask
    end
    local t = scrapeTaxiTask()
    if t then
        taxiTask = t
        return t
    end
    local zone = workspace:FindFirstChild("TaxiZone")
    local box = zone and zone:FindFirstChild("Box")
    if box then
        return { Path = {}, SpotCF = CFrame.new(box.Position), IsPickup = true }
    end
end

local function closestOnSeg(a, b, p)
    local ab = b - a
    local l2 = ab:Dot(ab)
    if l2 < 1e-6 then
        return a, 0
    end
    local t = math.clamp((p - a):Dot(ab) / l2, 0, 1)
    return a + ab * t, t
end

-- Roads
-- road surface test: live, the deck of the Sunset Point Lift Bridge is SmoothPlastic "Grate" parts inside a
-- BridgeDeck.RoadSurface model, so the river crossing never counted as road and the route went straight over the water
function NC.isRoad(h)
    local i = h.Instance
    return i.Name == "RoadSurface" or h.Material == Enum.Material.Asphalt
        or (i.Parent ~= nil and i.Parent.Name == "RoadSurface")
end
local ROAD_STEP = 6
local function roadCell(cache, gx, gz, y0, params)
    local key = gx * 65536 + gz
    local c = cache[key]
    if c == nil then
        local h = workspace:Raycast(Vector3.new(gx * ROAD_STEP, y0 + 10, gz * ROAD_STEP), Vector3.new(0, -30, 0), params)
        c = h ~= nil and NC.isRoad(h)
        cache[key] = c
    end
    return c
end

local function cellOf(v)
    return math.floor(v.X / ROAD_STEP + 0.5), math.floor(v.Z / ROAD_STEP + 0.5)
end

local function segmentOnRoad(cache, a, b, y0, params)
    local d = (b - a).Magnitude
    local n = math.max(1, math.ceil(d / 3))
    for i = 0, n do
        local p = a:Lerp(b, i / n)
        local gx, gz = cellOf(p)
        if not roadCell(cache, gx, gz, y0, params) then
            return false
        end
    end
    return true
end

local function nearestRoadCell(cache, gx, gz, y0, params, maxR)
    for r = 0, maxR do
        local best, bd
        for dx = -r, r do
            for dz = -r, r do
                if math.max(math.abs(dx), math.abs(dz)) == r and roadCell(cache, gx + dx, gz + dz, y0, params) then
                    local d = dx * dx + dz * dz
                    if not bd or d < bd then
                        best, bd = { gx + dx, gz + dz }, d
                    end
                end
            end
        end
        if best then
            return best[1], best[2]
        end
    end
end

-- road-only polyline from `from` to `to` (both flat), or nil
local function roadConnector(from, to, y0, params, maxExpansions)
    local cache = {}
    if segmentOnRoad(cache, from, to, y0, params) then
        return { from, to }
    end
    local fx, fz = cellOf(from)
    local tx, tz = cellOf(to)
    local sx, sz = nearestRoadCell(cache, fx, fz, y0, params, 6)
    local ex, ez = nearestRoadCell(cache, tx, tz, y0, params, 6)
    if not sx or not ex then
        return nil
    end
    local minX, maxX = math.min(sx, ex) - 14, math.max(sx, ex) + 14
    local minZ, maxZ = math.min(sz, ez) - 14, math.max(sz, ez) + 14
    local heap = {}
    local function push(item)
        heap[#heap + 1] = item
        local i = #heap
        while i > 1 do
            local p = i // 2
            if heap[p][1] > heap[i][1] then
                heap[p], heap[i] = heap[i], heap[p]
                i = p
            else
                break
            end
        end
    end
    local function pop()
        local top = heap[1]
        local last = table.remove(heap)
        if #heap > 0 then
            heap[1] = last
            local i = 1
            while true do
                local l, r, m = i * 2, i * 2 + 1, i
                if l <= #heap and heap[l][1] < heap[m][1] then
                    m = l
                end
                if r <= #heap and heap[r][1] < heap[m][1] then
                    m = r
                end
                if m == i then
                    break
                end
                heap[m], heap[i] = heap[i], heap[m]
                i = m
            end
        end
        return top
    end
    local startKey, goalKey = sx * 65536 + sz, ex * 65536 + ez
    local gScore, came, coord = { [startKey] = 0 }, {}, { [startKey] = { sx, sz } }
    push({ math.abs(sx - ex) + math.abs(sz - ez), startKey })
    local expansions, found = 0, false
    while #heap > 0 and expansions < (maxExpansions or 2200) do
        local item = pop()
        local key = item[2]
        if key == goalKey then
            found = true
            break
        end
        expansions += 1
        if expansions % 120 == 0 then
            RunService.Heartbeat:Wait()
        end
        local cx, cz = coord[key][1], coord[key][2]
        for dx = -1, 1 do
            for dz = -1, 1 do
                if dx ~= 0 or dz ~= 0 then
                    local nx, nz = cx + dx, cz + dz
                    if nx >= minX and nx <= maxX and nz >= minZ and nz <= maxZ and roadCell(cache, nx, nz, y0, params) then
                        local step = (dx ~= 0 and dz ~= 0) and 1.414 or 1
                        local edge = 0
                        if not roadCell(cache, nx + 1, nz, y0, params) then edge += 1 end
                        if not roadCell(cache, nx - 1, nz, y0, params) then edge += 1 end
                        if not roadCell(cache, nx, nz + 1, y0, params) then edge += 1 end
                        if not roadCell(cache, nx, nz - 1, y0, params) then edge += 1 end
                        local ng = gScore[key] + step + edge * 1.2
                        local nkey = nx * 65536 + nz
                        if not gScore[nkey] or ng < gScore[nkey] then
                            gScore[nkey] = ng
                            came[nkey] = key
                            coord[nkey] = { nx, nz }
                            push({ ng + math.abs(nx - ex) + math.abs(nz - ez), nkey })
                        end
                    end
                end
            end
        end
    end
    if not found then
        return nil
    end
    local cells = {}
    local k = goalKey
    while k do
        table.insert(cells, 1, Vector3.new(coord[k][1] * ROAD_STEP, 0, coord[k][2] * ROAD_STEP))
        k = came[k]
    end
    local pts = { from }
    local i = 1
    while i < #cells do
        local j = #cells
        while j > i + 1 and not segmentOnRoad(cache, pts[#pts], cells[j], y0, params) do
            j -= 1
        end
        table.insert(pts, cells[j])
        i = j
    end
    table.insert(pts, to)
    return pts
end

local function buildRoute(task, carPos, y0, params)
    local zone = flat(task.SpotCF.Position)
    local pts, ys = {}, {}
    for _, p in ipairs(task.Path or {}) do
        table.insert(pts, flat(p))
        table.insert(ys, p.Y)
    end
    local route, rys = {}, {}
    if #pts >= 2 then
        local bestI, bestD, bestP = 1, math.huge, pts[1]
        for i = 1, #pts - 1 do
            local cp = closestOnSeg(pts[i], pts[i + 1], zone)
            local d = (cp - zone).Magnitude
            if d < bestD then
                bestI, bestD, bestP = i, d, cp
            end
        end
        for i = 1, bestI do
            table.insert(route, pts[i])
            table.insert(rys, ys[i])
        end
        table.insert(route, bestP)
        table.insert(rys, ys[bestI])
    elseif #pts == 1 then
        table.insert(route, pts[1])
        table.insert(rys, ys[1])
    end
    if #route == 0 or (route[#route] - zone).Magnitude > 2 then
        table.insert(route, zone)
        table.insert(rys, task.SpotCF.Position.Y)
    end
    local car = flat(carPos)
    local off, seg, proj = math.huge, 1, route[1]
    local onLevel = false
    for i = 1, #route - 1 do
        if math.min(math.abs(rys[i] - y0), math.abs(rys[i + 1] - y0)) <= 30 then
            local cp = closestOnSeg(route[i], route[i + 1], car)
            local d = (cp - car).Magnitude
            if d < off then
                off, seg, proj, onLevel = d, i, cp, true
            end
        end
    end
    if not onLevel then
        off, seg, proj = math.huge, 0, route[1]
    end
    if #route >= 2 and onLevel then
        local trimmed = { proj }
        for i = seg + 1, #route do
            table.insert(trimmed, route[i])
        end
        route = trimmed
    end
    if off > 12 and (route[1] - car).Magnitude > 12 then
        local conn = roadConnector(car, route[1], y0, params)
        if conn then
            taxiLog("connector " .. #conn .. " pts")
            local joined = {}
            for _, p in ipairs(conn) do
                table.insert(joined, p)
            end
            for i = 2, #route do
                table.insert(joined, route[i])
            end
            route = joined
        end
    end
    if off > 12 and (route[1] - car).Magnitude > 4 then
        table.insert(route, 1, car)
    end
    if #route < 2 then
        table.insert(route, zone + Vector3.new(0.5, 0, 0.5))
    end
    local function length(r)
        local l = 0
        for i = 1, #r - 1 do
            l += (r[i + 1] - r[i]).Magnitude
        end
        return l
    end
    local len = length(route)
    local pending
    if len > (zone - car).Magnitude * 1.15 + 20 then
        pending = function()
            local own = roadConnector(car, zone, y0, params, 6000)
            if own and length(own) < len * 0.9 then
                taxiLog(string.format("shortcut: %.0f studs instead of %.0f", length(own), len))
                return own
            end
        end
    end
    return route, pending
end

local function nearestSegment(route, p)
    local bestI, bestD = 1, math.huge
    for i = 1, #route - 1 do
        local cp = closestOnSeg(route[i], route[i + 1], p)
        local d = (cp - p).Magnitude
        if d < bestD then
            bestI, bestD = i, d
        end
    end
    return bestI
end
local function routeAim(route, idx, pos, dist)
    while idx < #route - 1 do
        local _, t = closestOnSeg(route[idx], route[idx + 1], pos)
        if t >= 0.999 or (route[idx + 1] - pos).Magnitude < 5 then
            idx += 1
        else
            break
        end
    end
    local proj = closestOnSeg(route[idx], route[idx + 1], pos)
    local remain, cur, i = dist, proj, idx
    while true do
        local nxt = route[i + 1]
        local d = (nxt - cur).Magnitude
        if d >= remain or i >= #route - 1 then
            local dir = d > 1e-3 and (nxt - cur).Unit or Vector3.zero
            return cur + dir * math.min(remain, d), idx, proj
        end
        remain -= d
        cur = nxt
        i += 1
    end
end

local function cornerSpeed(ang)
    return TAXI_CRUISE
end
local function routeSpeedLimit(route, idx, proj)
    local limit, acc, cur = TAXI_CRUISE, 0, proj
    for i = idx + 1, #route do
        acc += (route[i] - cur).Magnitude
        cur = route[i]
        if acc > 170 then
            break
        end
        local vc
        if i == #route then
            vc = 5
        else
            local a, b = route[i] - route[i - 1], route[i + 1] - route[i]
            if a.Magnitude > 0.1 and b.Magnitude > 0.1 then
                vc = cornerSpeed(math.acos(math.clamp(a.Unit:Dot(b.Unit), -1, 1)))
            end
        end
        if vc then
            limit = math.min(limit, math.sqrt(vc * vc + 2 * TAXI_DECEL * acc))
        end
    end
    return limit
end

local function inTaxiZone(point, margin)
    if ghostMode then
        -- Ghost Patrol: the stop circle of the current zone
        local d = (flat(point) - flat(ghostMode.goal)).Magnitude
        return d <= ghostMode.radius - (margin or 0) and math.abs(point.Y - ghostMode.goal.Y) <= 30
    end
    local zone = workspace:FindFirstChild("TaxiZone")
    local box = zone and zone:FindFirstChild("Box")
    if not box then
        return false
    end
    local rel = box.CFrame:PointToObjectSpace(point)
    local half = box.Size / 2
    margin = margin or 0
    return math.abs(rel.X) <= half.X - margin and math.abs(rel.Y) <= half.Y + 3 and math.abs(rel.Z) <= half.Z - margin
end

-- the game's rivers and lakes are Terrain water (live: surface y=-11 over a sand bed at y=-24); the ground rays
-- ignore water, so water is looked for with its own ray that does see it
-- (kept on NC: the main chunk is at Luau's 200 local limit)
NC.waterParams = RaycastParams.new()
NC.waterParams.FilterType = Enum.RaycastFilterType.Exclude
NC.waterParams.IgnoreWater = false
-- height of the real ground (terrain / road network) at p, looking through everything the car drives through
-- (live: the leaves of a tree, y=51 over flat ground at y=29, were read as a mountain and the car stood still)
function NC.groundY(p, yTop, ignore)
    local gp = RaycastParams.new()
    gp.FilterType = Enum.RaycastFilterType.Exclude
    gp.IgnoreWater = true
    local list = table.clone(ignore)
    for _ = 1, 8 do
        gp.FilterDescendantsInstances = list
        local h = workspace:Raycast(Vector3.new(p.X, yTop + 60, p.Z), Vector3.new(0, -200, 0), gp)
        if not h then
            return nil
        end
        if h.Instance:IsA("Terrain") or taxiGroundLike(h.Instance) then
            return h.Position.Y, h
        end
        table.insert(list, h.Instance)
    end
end

function NC.waterAt(p, yTop, ignore)
    NC.waterParams.FilterDescendantsInstances = ignore or { LocalPlayer.Character, workspace:FindFirstChild("MouseIgnore") }
    local h = workspace:Raycast(Vector3.new(p.X, yTop + 40, p.Z), Vector3.new(0, -160, 0), NC.waterParams)
    return h ~= nil and h.Material == Enum.Material.Water
end

local function groundHit(p, yRef, params)
    local base = params.FilterDescendantsInstances
    local list
    local result
    for _ = 1, 6 do
        local h = workspace:Raycast(Vector3.new(p.X, yRef + 4, p.Z), Vector3.new(0, -14, 0), params)
        if not h then
            break
        end
        local i = h.Instance
        -- (Ghost Patrol rides 2.8 above the ground, the taxi 3.6: the "is it below the car" margin follows that)
        if i.CanCollide and i.Transparency < 0.95 and (h.Position.Y <= yRef - (ghostMode and 2.1 or 2.9) or taxiGroundLike(i)) then
            result = h
            break
        end
        list = list or table.clone(base)
        table.insert(list, i)
        params.FilterDescendantsInstances = list
    end
    params.FilterDescendantsInstances = base
    return result
end

local function castBox(cf, size, vec, params, wide)
    local base = params.FilterDescendantsInstances
    local list
    local result
    for _ = 1, 6 do
        local ok, hit = pcall(function()
            return workspace:Blockcast(cf, size, vec, params)
        end)
        if not ok or not hit then
            break
        end
        -- Ghost Patrol: the car's own parts do not collide (noclip), so what stops it is this check. Only small things
        -- (signs, poles, lights, rocks: taxiSoft) and the road network's own curbs/sidewalks are driven through;
        -- buildings, walls, fences and other vehicles are solid, and so is a steep terrain face.
        if hit.Normal.Y > 0.92 or taxiSoft(hit.Instance) or (wide and not ghostMode and taxiPass(hit.Instance))
            or (ghostMode and hit.Instance:IsA("Terrain") and hit.Normal.Y > 0.45)
            or (ghostMode and not hit.Instance:IsA("Terrain") and taxiGroundLike(hit.Instance)) then
            list = list or table.clone(base)
            table.insert(list, hit.Instance)
            params.FilterDescendantsInstances = list
        else
            result = hit
            break
        end
    end
    params.FilterDescendantsInstances = base
    return result
end
local function sweepAlong(startPos, d, maxDist, size, params, baseY, rel)
    local flatD = Vector3.new(d.X, 0, d.Z)
    if flatD.Magnitude < 0.01 then
        return nil
    end
    flatD = flatD.Unit
    local prevY = baseY
    local travelled = 0
    while travelled < maxDist do
        local seg = math.min(14, maxDist - travelled)
        local p1 = startPos + flatD * (travelled + seg)
        local g = groundHit(Vector3.new(p1.X, prevY + rel, p1.Z), prevY + rel, params)
        local y1 = g and g.Position.Y or prevY
        local c0 = Vector3.new(startPos.X + flatD.X * travelled, prevY + rel, startPos.Z + flatD.Z * travelled)
        local c1 = Vector3.new(p1.X, y1 + rel, p1.Z)
        local v = c1 - c0
        local hit = castBox(CFrame.lookAt(c0, c0 + v), size, v, params, true)
        if hit then
            return travelled + hit.Distance, hit
        end
        travelled += seg
        prevY = y1
    end
    return nil
end

local function boxHeight(cf, params)
    local g = groundHit(cf.Position, cf.Position.Y, params)
    return (cf.Position.Y - (g and g.Position.Y or (cf.Position.Y - 3.6))) - 0.8
end

local function clearance(pp, forward, maxDist, params)
    local cf = pp.CFrame
    local dirV = forward and cf.LookVector or -cf.LookVector
    local start = cf.Position + dirV * (pp.Size.Z / 2 - 0.5)
    local below = groundHit(start, start.Y, params)
    local baseY = below and below.Position.Y or (start.Y - 3.6)
    local dist, hit = sweepAlong(start, dirV, maxDist, Vector3.new(pp.Size.X - 0.8, 2.4, 0.6), params, baseY, boxHeight(cf, params))
    if hit then
        return math.min(dist, maxDist), hit.Instance
    end
    return maxDist, nil
end

local function clearanceToward(pp, dirFlat, maxDist, params)
    if dirFlat.Magnitude < 0.01 then
        return maxDist
    end
    local d = dirFlat.Unit
    local cf = pp.CFrame
    local f = flat(cf.LookVector)
    f = f.Magnitude > 0.01 and f.Unit or d
    local start = cf.Position + f * (pp.Size.Z / 2 - 0.5)
    local below = groundHit(start, start.Y, params)
    local baseY = below and below.Position.Y or (start.Y - 3.6)
    local dist, hit = sweepAlong(start, d, maxDist, Vector3.new(pp.Size.X - 0.8, 2.4, 0.6), params, baseY, boxHeight(cf, params))
    if hit then
        return math.min(dist, maxDist)
    end
    return maxDist
end

local function clearanceRoute(pp, route, idx, pos, maxDist, params)
    local cf = pp.CFrame
    local f = flat(cf.LookVector)
    f = f.Magnitude > 0.01 and f.Unit or Vector3.new(0, 0, -1)
    local half = pp.Size.Z / 2 - 0.5
    local rel = boxHeight(cf, params)
    local size = Vector3.new(pp.Size.X - 0.8, 2.4, 0.6)
    local prev = pos + f * half
    local gn = groundHit(Vector3.new(prev.X, cf.Position.Y, prev.Z), cf.Position.Y, params)
    local prevY = gn and gn.Position.Y or (cf.Position.Y - 3.6)
    local travelled = 0
    for k = 1, 8 do
        if travelled >= maxDist then
            break
        end
        local nextPt = routeAim(route, idx, pos, half + k * 12)
        local seg = nextPt - prev
        if seg.Magnitude < 0.5 then
            break
        end
        local pieceLen = math.min(seg.Magnitude, maxDist - travelled)
        local p1 = prev + seg.Unit * pieceLen
        local g = groundHit(Vector3.new(p1.X, prevY + rel, p1.Z), prevY + rel, params)
        local y1 = g and g.Position.Y or prevY
        local c0 = Vector3.new(prev.X, prevY + rel, prev.Z)
        local v = Vector3.new(p1.X, y1 + rel, p1.Z) - c0
        local hit = castBox(CFrame.lookAt(c0, c0 + v), size, v, params, true)
        if hit then
            return travelled + hit.Distance
        end
        travelled += pieceLen
        prev, prevY = p1, y1
    end
    return maxDist
end
local function steerAuthority(speed)
    local v = math.abs(speed)
    if v <= 15 then
        return math.clamp((math.cos(math.pi * (v - 15) / 15) + 1) * 0.5, 0.3, 1)
    end
    return (math.cos(0.0233 * (v - 15)) * 0.5 + 1.5) * 0.5
end

local TAXI_ACCEL, TAXI_BRAKE = 30, 50
local TAXI_YAW = 2.6

local function routeCornerAhead(route, idx, proj, span)
    local maxAng, acc, cur = 0, 0, proj
    for i = idx + 1, #route - 1 do
        acc += (route[i] - cur).Magnitude
        if acc > span then
            break
        end
        cur = route[i]
        local a, b = route[i] - route[i - 1], route[i + 1] - route[i]
        if a.Magnitude > 0.1 and b.Magnitude > 0.1 then
            maxAng = math.max(maxAng, math.acos(math.clamp(a.Unit:Dot(b.Unit), -1, 1)))
        end
    end
    return maxAng
end

local TAXI_CORNER_R = 18
local function roundRoute(route)
    if #route < 3 then
        return route
    end
    local out = { route[1] }
    for i = 2, #route - 1 do
        local v = route[i]
        local a, b = v - route[i - 1], route[i + 1] - v
        local la, lb = a.Magnitude, b.Magnitude
        if la < 0.1 or lb < 0.1 then
            table.insert(out, v)
        else
            local ua, ub = a / la, b / lb
            local theta = math.acos(math.clamp(ua:Dot(ub), -1, 1))
            if theta < 0.2 or theta > 3.0 then
                table.insert(out, v)
            else
                local t = math.min(TAXI_CORNER_R * math.tan(theta / 2), 0.45 * math.min(la, lb))
                local p1, p2 = v - ua * t, v + ub * t
                for k = 0, 6 do
                    local u = k / 6
                    table.insert(out, p1 * (1 - u) ^ 2 + v * (2 * u * (1 - u)) + p2 * u ^ 2)
                end
            end
        end
    end
    table.insert(out, route[#route])
    return out
end
local function driveLeg(leg)
    local serial0 = taxiSerial
    local model, pp = getTaxiVehicle()
    if not pp then
        return "lost"
    end
    if not installDriveInput() then
        task.wait(1)
        return "nocontrols"
    end
    moveVec = Vector3.zero
    taxiSlowUntil = 0 -- a new leg starts at full speed
    local zone = flat(leg.SpotCF.Position)
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.RespectCanCollide = true
    local roadParams = RaycastParams.new()
    roadParams.FilterType = Enum.RaycastFilterType.Exclude
    -- water is never ground: live, the Ghost Patrol car rode off the quay onto the river surface
    roadParams.IgnoreWater = true
    local ignore = { model }
    for _, plr in ipairs(Players:GetPlayers()) do
        if plr.Character then
            table.insert(ignore, plr.Character)
        end
    end
    params.FilterDescendantsInstances = ignore
    roadParams.FilterDescendantsInstances = ignore
    local searchParams = RaycastParams.new()
    searchParams.FilterType = Enum.RaycastFilterType.Exclude
    searchParams.FilterDescendantsInstances = ignore
    local rawRoute, pendingShortcut = buildRoute(leg, pp.Position, pp.Position.Y, searchParams)
    if rawRoute[2] then
        local a, b = flat(pp.Position), rawRoute[2]
        local d = b - a
        if d.Magnitude > 10 then
            local c = Vector3.new(a.X, pp.Position.Y - 0.8, a.Z)
            local hit = castBox(CFrame.lookAt(c, c + d), Vector3.new(pp.Size.X + 0.4, 2.4, 1), d, params)
            if hit then
                local own = roadConnector(a, b, pp.Position.Y, searchParams, 6000)
                if own then
                    local joined = {}
                    for _, p in ipairs(own) do
                        table.insert(joined, p)
                    end
                    for k = 3, #rawRoute do
                        table.insert(joined, rawRoute[k])
                    end
                    rawRoute = joined
                    taxiLog("first piece crossed a building: road route used")
                end
            end
        end
    end
    local route = roundRoute(rawRoute)
    local shortcutRoute
    if pendingShortcut then
        task.spawn(function()
            local own = pendingShortcut()
            if own and taxiSerial == serial0 then
                shortcutRoute = own
            end
        end)
    end
    local idx = nearestSegment(route, flat(pp.Position))
    local lastSense, onRoad, fClear, bClear, pClear = 0, true, 60, 60, 60
    local lastAir = 0
    local waitSince, offSince, blockedSince
    local blockedCount = 0
    local backupUntil = 0
    local roadCache = {}
    local why = "free"
    local statusText = leg.IsPickup and "Driving to pickup" or "Driving to drop-off"
    setStatus(statusText)
    taxiLog("LEG start pts=" .. #route .. " idx=" .. idx .. " pickup=" .. tostring(leg.IsPickup))

    -- state the script integrates itself
    local cf0 = pp.CFrame
    local cpos = cf0.Position
    local dir = flat(cf0.LookVector)
    dir = dir.Magnitude > 0.01 and dir.Unit or Vector3.new(0, 0, -1)
    local speed = pp.AssemblyLinearVelocity:Dot(cf0.LookVector)
    local pitch = 0
    local hover
    do
        local h = groundHit(cpos, cpos.Y, roadParams)
        hover = h and (cpos.Y - h.Position.Y) or 3.6
        -- a car that sank while the game's physics had it (noclip on) measures a too low ride height: never below 3
        if hover < 3 or hover > 6 then
            hover = 3.6
        end
        if ghostMode then
            -- Ghost Patrol Cruiser: measured live under the game's own suspension, the chassis rests 2.8 above the
            -- road with the wheels on it; the taxi's 3.6 made it float ~0.75 studs with the wheels hanging in the air
            hover = 2.8
        end
    end
    kinOn(model, pp)
    NC.on(model)
    NC.driveActive = true -- from here this loop writes the car's pose (the Ghost Patrol hold lets go)
    local lastT = os.clock()
    local lastLog = 0

    local function groundBelowWide(origin)
        local base = roadParams.FilterDescendantsInstances
        local list = table.clone(base)
        local firstAny
        local found
        for _ = 1, 8 do
            roadParams.FilterDescendantsInstances = list
            local h = workspace:Raycast(origin, Vector3.new(0, -3000, 0), roadParams)
            if not h then
                break
            end
            local i = h.Instance
            if i.CanCollide and i.Transparency < 0.95 then
                firstAny = firstAny or h
                if taxiGroundLike(i) then
                    found = h
                    break
                end
            end
            table.insert(list, i)
        end
        roadParams.FilterDescendantsInstances = base
        return found or firstAny
    end

    local function roadTopAbove(p3)
        local base = roadParams.FilterDescendantsInstances
        local list = table.clone(base)
        local top
        for _ = 1, 6 do
            roadParams.FilterDescendantsInstances = list
            local h = workspace:Raycast(p3, Vector3.new(0, 30, 0), roadParams)
            if not h then
                break
            end
            local i = h.Instance
            if i.CanCollide and i.Transparency < 0.95 and not i:IsA("Terrain") and taxiGroundLike(i) then
                local sp = RaycastParams.new()
                sp.FilterType = Enum.RaycastFilterType.Include
                sp.FilterDescendantsInstances = { i }
                local t = workspace:Raycast(Vector3.new(p3.X, h.Position.Y + 6, p3.Z), Vector3.new(0, -12, 0), sp)
                top = t and t.Position.Y
                break
            end
            table.insert(list, i)
        end
        roadParams.FilterDescendantsInstances = base
        return top
    end

    local poseT, tPitch
    local goodPos, edgeStop -- the last place the car had ground under it; set when the ground ran out
    -- write the car's pose for this frame
    local function applyPose(yawRate)
        local half = pp.Size.Z / 2 - 1.5
        local yRef = cpos.Y
        local hf = groundHit(cpos + dir * half, yRef, roadParams)
        local hb = groundHit(cpos - dir * half, yRef, roadParams)
        local gy
        if hf and hb then
            gy = (hf.Position.Y + hb.Position.Y) / 2
            tPitch = math.atan2(hf.Position.Y - hb.Position.Y, half * 2)
        else
            local hc = groundHit(cpos, yRef, roadParams)
            gy = hc and hc.Position.Y
        end
        local grounded = gy ~= nil
        if not gy then
            local w = groundBelowWide(Vector3.new(cpos.X, cpos.Y + 2, cpos.Z))
            if w and cpos.Y - hover - w.Position.Y <= 12 then
                gy = w.Position.Y
                pitch = 0
                taxiLog(string.format("no ground within reach: dropped %.0f studs onto the ground", cpos.Y - hover - gy))
            elseif goodPos then
                -- Live: at the end of a Dam road segment the ground ran out and the car was dropped 90 studs into a pit it could not leave.
                -- It is not dropped any more: it goes back to the last place with ground under it and the way is planned again.
                taxiLog(string.format("no ground ahead (%.0f studs down): back to the last spot with ground", w and (cpos.Y - hover - w.Position.Y) or -1))
                cpos = goodPos
                speed = 0
                edgeStop = true
            elseif w then
                gy = w.Position.Y
                pitch = 0
                taxiLog(string.format("no ground within reach: dropped %.0f studs onto the ground", cpos.Y - hover - gy))
            end
        end
        if grounded then
            goodPos = cpos
        end
        local nowP = os.clock()
        local dtP = math.clamp(nowP - (poseT or nowP), 0.001, 0.05)
        poseT = nowP
        local aH, aP = 1 - math.exp(-dtP / 0.07), 1 - math.exp(-dtP / 0.1)
        if gy then
            local targetY = gy + hover
            local dy = targetY - cpos.Y
            local newY = math.abs(dy) > 2.5 and targetY or (cpos.Y + dy * aH)
            cpos = Vector3.new(cpos.X, math.max(newY, targetY - 0.5), cpos.Z)
        end
        if tPitch then
            pitch = math.abs(tPitch - pitch) > 0.4 and tPitch or (pitch + (tPitch - pitch) * aP)
            tPitch = nil
        end
        local fwd3 = Vector3.new(dir.X * math.cos(pitch), math.sin(pitch), dir.Z * math.cos(pitch))
        pp.CFrame = CFrame.lookAt(cpos, cpos + fwd3)
        pp.AssemblyLinearVelocity = fwd3 * speed
        pp.AssemblyAngularVelocity = Vector3.new(0, -yawRate, 0)
    end

    local dodge, detour
    local pivot, slide
    local recoverHold = 0
    local stuckTried = {} -- spot -> { offs = {}, heads = {}, n = 0 }
    local DODGE_OFFSETS = { 1, -1, 1.7, -1.7, 2.6, -2.6, 3.8, -3.8, 5.5, -5.5, 8, -8 }

    local function spotKey(p)
        return math.floor(p.X / 12) .. "," .. math.floor(p.Z / 12)
    end

    local function bodyFree(d, off, maxDist)
        local right = d:Cross(Vector3.yAxis)
        local c = cpos + right * off + Vector3.new(0, -0.8, 0)
        local hit = castBox(CFrame.lookAt(c, c + d), Vector3.new(pp.Size.X - 0.8, 2.4, pp.Size.Z - 1), d * maxDist, params)
        if hit then
            return hit.Distance
        end
        return maxDist
    end

    local wIgnore = table.clone(ignore)
    table.insert(wIgnore, workspace:FindFirstChild("MouseIgnore"))
    local function wet(p3)
        return NC.waterAt(p3, cpos.Y, wIgnore)
    end

    local function groundOk(p3)
        local h = groundHit(Vector3.new(p3.X, cpos.Y, p3.Z), cpos.Y, roadParams)
        return h ~= nil and not wet(p3) and math.abs((h.Position.Y + hover) - cpos.Y) < 3
            and (h.Normal.Y >= 0.95 or h.Instance.Name == "RoadSurface")
    end

    local function chooseWayOut(rec, need)
        local right = dir:Cross(Vector3.yAxis)
        local bestOff, bestFree
        for _, off in ipairs(DODGE_OFFSETS) do
            if not rec.offs[off] and groundOk(cpos + right * off) then
                local free = bodyFree(dir, off, need)
                if free >= need then
                    return "dodge", { off = off, right = right, dist = 0, len = need, t0 = os.clock() }
                end
                if not bestFree or free > bestFree then
                    bestOff, bestFree = off, free
                end
            end
        end
        if bestFree and bestFree >= 0.7 * need then
            return "dodge", { off = bestOff, right = right, dist = 0, len = need, t0 = os.clock() }
        end
        local bestAng, bestHeadFree, bestDir
        for _, deg in ipairs({ 25, -25, 50, -50, 80, -80, 110, -110, 140, -140, 180 }) do
            if not rec.heads[deg] then
                local d = CFrame.Angles(0, math.rad(deg), 0) * dir
                d = Vector3.new(d.X, 0, d.Z).Unit
                local free = bodyFree(d, 0, 30)
                if free >= 14 and groundOk(cpos + d * 14) and (not bestHeadFree or free > bestHeadFree) then
                    bestAng, bestHeadFree, bestDir = deg, free, d
                end
            end
        end
        if bestAng then
            rec.heads[bestAng] = true
            return "detour", { aim = flat(cpos) + bestDir * math.min(bestHeadFree - 2, 24), t0 = os.clock(), dir = bestDir }
        end
        return nil
    end

    local function corridorClear(a, b)
        local d = b - a
        local len = d.Magnitude
        if len < 25 then
            return false
        end
        local u = d / len
        local gy = {}
        local prevY = cpos.Y - hover
        -- water anywhere along the shortcut (the middle and both sides of the car, every 4 studs) rules it out
        local side = u:Cross(Vector3.yAxis) * (pp.Size.X / 2 + 1)
        for i = 0, math.ceil(len / 4) do
            local p = a + u * math.min(len, i * 4)
            local h = groundHit(Vector3.new(p.X, prevY + hover, p.Z), prevY + hover, roadParams)
            if not h or math.abs(h.Position.Y - prevY) > 2.2
                or not (h.Normal.Y >= 0.95 or h.Instance.Name == "RoadSurface") then
                return false
            end
            prevY = h.Position.Y
            gy[i] = prevY
        end
        local chunk = 20
        local k = 0
        while k * chunk < len do
            local s = a + u * (k * chunk)
            local y = gy[math.floor(k * chunk / 4)] or prevY
            local c = Vector3.new(s.X, y + hover - 0.8, s.Z)
            local hit = castBox(CFrame.lookAt(c, c + u), Vector3.new(pp.Size.X + 0.4, 2.4, 1), u * math.min(chunk + 6, len - k * chunk + 6), params)
            if hit then
                return false
            end
            k += 1
        end
        -- the whole-path water check runs last, only for a shortcut that passed the cheap checks (live: running it
        -- for every candidate every 0.9 s made the client hitch while driving)
        for i = 0, math.ceil(len / 4) do
            local p = a + u * math.min(len, i * 4)
            if wet(p) or wet(p + side) or wet(p - side) then
                return false
            end
        end
        return true
    end
    local lastShortcutTry = 0
    local noShortcutUntil, edgeStops, lastShortcutKey, lastShortcutAt = 0, 0, nil, 0
    local orbitIdx, orbitTurn = 0, 0

    local crumbs = taxiCrumbs
    local lastCrumb, retraces, retracing = 0, 0, false
    local lastRoadPos
    local function startRetrace()
        if retraces >= 3 or #crumbs < 3 then
            return false
        end
        local r = { flat(cpos) }
        local used = 0
        for i = #crumbs, 1, -1 do
            local c = flat(crumbs[i])
            if (c - r[#r]).Magnitude > 6 then
                table.insert(r, c)
            end
            used += 1
            if #r > 25 then
                break
            end
        end
        if #r < 2 then
            return false
        end
        for _ = 1, used do
            table.remove(crumbs)
        end
        retraces += 1
        route = roundRoute(r)
        idx = 1
        retracing = true
        dodge, detour, pivot, slide = nil, nil, nil, nil
        return true
    end
    while running and (farming or ghostOn) and taxiSerial == serial0 do
        if not (model.Parent and pp.Parent and getTaxiVehicle()) then
            return "lost"
        end
        if shortcutRoute then
            route = roundRoute(shortcutRoute)
            idx = nearestSegment(route, flat(cpos))
            shortcutRoute = nil
        end
        local nx = leg.Next
        if nx then
            -- Ghost Patrol hands the running drive its next route (the next stretch of road joined on, the next ghost,
            -- the cemetery, a spot after the car was in the water): the drive does not end between them
            leg.Next = nil
            local nr
            if nx.append then
                local _, sidx, sproj = routeAim(route, idx, flat(cpos), 1)
                nr = { sproj }
                for i = sidx + 1, #route do
                    table.insert(nr, route[i])
                end
            else
                nr = { flat(cpos) }
            end
            for i = 2, #nx.pts do
                table.insert(nr, flat(nx.pts[i]))
            end
            -- points on top of each other (or a number that is not valid) would break the corner maths and the car's
            -- pose (live: "Detached: Tried to move to a invalid CFrame!"): they are dropped
            local clean = {}
            for _, p in ipairs(nr) do
                if p.X == p.X and p.Z == p.Z and (#clean == 0 or (clean[#clean] - p).Magnitude > 1.5) then
                    clean[#clean + 1] = p
                end
            end
            nr = clean
            if #nr >= 2 then
                route = roundRoute(nr)
                idx = 1
                zone = flat(nx.goal)
                leg.NoEndStop = not nx.complete
                leg.Cruise = nx.cruise
                if not nx.append then
                    dodge, detour, pivot, slide = nil, nil, nil, nil
                end
            end
        end
        local now = os.clock()
        -- Ghost Patrol: live the client hitched up to 0.38 s while driving; with dt capped at 0.05 the car lost that
        -- distance and seemed to slow down / stop at random. It now covers the real time of a hitch (up to 0.2 s).
        local dt = math.clamp(now - lastT, 0.001, ghostMode and 0.2 or 0.05)
        lastT = now
        local pos = flat(cpos)
        local dZone = (zone - pos).Magnitude
        local inside = inTaxiZone(cpos, 0)
        local deep = inTaxiZone(cpos, 4)

        if edgeStop then
            edgeStop = false
            edgeStops += 1
            noShortcutUntil = now + 120
            if lastShortcutKey and now - lastShortcutAt < 45 then
                taxiBadShortcut[lastShortcutKey] = true
            end
            dodge, detour, pivot, slide = nil, nil, nil, nil
            local own = edgeStops < 3 and roadConnector(pos, zone, cpos.Y, roadParams, 6000) or nil
            if own then
                route = roundRoute(own)
                idx = 1
                taxiLog("no ground ahead: route planned again over the road")
            elseif not retracing and startRetrace() then
                edgeStops = 0
                taxiLog("no ground ahead: retracing the road")
            end
            applyPose(0)
            RunService.Heartbeat:Wait()
            continue
        end

        if now - lastSense > 0.12 then
            lastSense = now
            local down = groundHit(cpos, cpos.Y, roadParams)
            onRoad = down ~= nil and NC.isRoad(down)
            if onRoad then
                lastRoadPos = cpos
            elseif wet(cpos) and not ghostMode then
                -- in the water anyway: straight back to the last spot on the road, that shortcut is never tried
                -- again and shortcuts stay off for a while; the way on is planned over the road from there
                local back = lastRoadPos or crumbs[#crumbs]
                if lastShortcutKey then
                    taxiBadShortcut[lastShortcutKey] = true
                end
                noShortcutUntil = now + 180
                if back then
                    taxiLog("in the water: back to the last spot on the road")
                    cpos = back
                    speed, pitch, tPitch = 0, 0, nil
                    goodPos = cpos
                    dodge, detour, pivot, slide, backupUntil = nil, nil, nil, nil, 0
                    local own = roadConnector(flat(cpos), zone, cpos.Y, roadParams, 6000)
                    if own then
                        route = roundRoute(own)
                        idx = 1
                    else
                        idx = nearestSegment(route, flat(cpos))
                    end
                    applyPose(0)
                    RunService.Heartbeat:Wait()
                    continue
                end
            end
            if now - lastAir > 0.5 and not ghostMode then
                lastAir = now
                local w = groundBelowWide(Vector3.new(cpos.X, cpos.Y + 1, cpos.Z))
                if w and cpos.Y - w.Position.Y > hover + 8 then
                    taxiLog(string.format("%.0f studs above the ground: dropped back onto it", cpos.Y - hover - w.Position.Y))
                    cpos = Vector3.new(cpos.X, w.Position.Y + hover, cpos.Z)
                    pitch = 0
                end
            end
            if not onRoad and not inside and not ghostMode then
                local topY = roadTopAbove(Vector3.new(cpos.X, cpos.Y + 1, cpos.Z))
                if topY and topY > cpos.Y - hover + 1.5 then
                    taxiLog(string.format("under a road: put back on top of it (%.1f studs)", topY + hover - cpos.Y))
                    cpos = Vector3.new(cpos.X, topY + hover, cpos.Z)
                    pitch = 0
                    tPitch = nil
                end
            end
            fClear = clearance(pp, true, 40, params)
            bClear = clearance(pp, false, 12, params)
            local ahead = math.clamp(math.abs(speed) * 0.9 + 10, 14, 40)
            pClear = clearanceRoute(pp, route, idx, pos, ahead + 4, params)
            local cp = closestOnSeg(route[idx], route[idx + 1], pos)
            if onRoad or inside or dZone < 25 or (cp - pos).Magnitude < 16 or ghostMode then
                offSince = nil
            else
                offSince = offSince or now
            end
        end
        if now - lastLog > 2 then
            lastLog = now
            taxiLog(string.format("spd=%.1f why=%s road=%s fc=%.0f pc=%.0f bc=%.0f up=%.2f pitch=%.2f pos=%.0f,%.0f zone=%.0f", speed, why, tostring(onRoad), fClear, pClear, bClear, pp.CFrame.UpVector.Y, pitch, pos.X, pos.Z, dZone))
        end

        if inside and math.abs(speed) < 0.5 and (deep or dZone < 10 or fClear < 10) then
            moveVec = Vector3.zero
            waitSince = waitSince or now
            setStatus(leg.IsPickup and "Waiting for passenger" or "Waiting for drop-off")
            speed = 0
            if now - waitSince > 8 and fClear > 14 then
                -- nothing yet: roll a few studs further in, then wait again
                local t0 = os.clock()
                while running and (farming or ghostOn) and taxiSerial == serial0 and os.clock() - t0 < 0.7 do
                    local d2 = math.clamp(os.clock() - lastT, 0.001, 0.05)
                    lastT = os.clock()
                    speed = 5
                    cpos += dir * 5 * d2
                    applyPose(0)
                    RunService.Heartbeat:Wait()
                end
                speed = 0
                waitSince = os.clock()
            end
            applyPose(0)
            RunService.Heartbeat:Wait()
            continue
        end
        waitSince = nil
        setStatus(statusText)

        local aheadAim = math.clamp(math.abs(speed) * 0.5 + 6, 8, 24)
        local _, _, proj0 = routeAim(route, idx, pos, 1)
        if routeCornerAhead(route, idx, proj0, 30) > 0.35 then
            aheadAim = 9
        end
        if now - lastCrumb > 0.4 and speed > 12 and onRoad and not retracing then
            lastCrumb = now
            local last = crumbs[#crumbs]
            if not last or (last - cpos).Magnitude > 10 then
                table.insert(crumbs, cpos)
                if #crumbs > 80 then
                    table.remove(crumbs, 1)
                end
            end
        end
        if retracing and (pos - route[#route]).Magnitude < 10 then
            -- back on the road: plan again from here
            retracing = false
            local rr = buildRoute(leg, cpos, cpos.Y, searchParams)
            route = roundRoute(rr)
            idx = nearestSegment(route, pos)
            taxiLog("back on the road, route rebuilt")
        end
        local aim, nidx, proj = routeAim(route, idx, pos, aheadAim)
        idx = nidx
        if idx ~= orbitIdx then
            orbitIdx, orbitTurn = idx, 0
        elseif math.abs(orbitTurn) > 5.8 and idx < #route - 1 then
            taxiLog(string.format("circling %.1f rad around route point %d: skipping the points around it", math.abs(orbitTurn), idx + 1))
            local j = idx + 1
            while j < #route - 1 and (route[j + 1] - pos).Magnitude < 40 do
                j += 1
            end
            idx = j
            orbitIdx, orbitTurn = idx, 0
            aim, nidx, proj = routeAim(route, idx, pos, aheadAim)
        end
        if now - lastShortcutTry > 0.9 and not dodge and not detour and not retracing and now > backupUntil and not inside
            and dZone > 40 and speed > 3 and now > noShortcutUntil and not ghostMode then
            lastShortcutTry = now
            local cands, acc, cur, lastAlong = {}, 0, proj, -1000
            for i = idx + 1, #route do
                acc += (route[i] - cur).Magnitude
                cur = route[i]
                if acc > 450 then
                    break
                end
                if acc >= 50 and acc - lastAlong >= 60 then
                    table.insert(cands, { i = i, along = acc })
                    lastAlong = acc
                end
            end
            for n = #cands, math.max(1, #cands - 2), -1 do
                local c = cands[n]
                local pt = route[c.i]
                local direct = (pt - pos).Magnitude
                if c.along > direct * 1.2 + 25 and not taxiBadShortcut[spotKey(pt)] and corridorClear(pos, pt) then
                    lastShortcutKey, lastShortcutAt = spotKey(pt), now
                    local nr = { pos }
                    for i = c.i, #route do
                        table.insert(nr, route[i])
                    end
                    route = roundRoute(nr)
                    idx = 1
                    aim, nidx, proj = routeAim(route, idx, pos, aheadAim)
                    taxiLog(string.format("SHORTCUT %.0f studs instead of %.0f", direct, c.along))
                    break
                end
            end
        end
        local backToRoad = false
        if offSince and now - offSince > 1 then
            local gx, gz = cellOf(pos)
            local rx, rz = nearestRoadCell(roadCache, gx, gz, cpos.Y, roadParams, 7)
            if rx then
                aim = Vector3.new(rx * ROAD_STEP, 0, rz * ROAD_STEP)
                backToRoad = true
            end
        elseif dZone < 14 then
            aim = zone
        end
        if detour then
            if (detour.aim - pos).Magnitude < 5 or now - detour.t0 > 8 then
                detour = nil
                idx = nearestSegment(route, pos)
            else
                aim = detour.aim
            end
        elseif dodge then
            if dodge.dist > dodge.len or now - dodge.t0 > 10 then
                dodge = nil
            else
                aim = aim + dodge.right * dodge.off
            end
        end
        local toAim = aim - pos
        local ang = 0
        if toAim.Magnitude > 0.5 then
            ang = math.atan2(dir.X * toAim.Z - dir.Z * toAim.X, dir:Dot(toAim)) -- + = aim is to the right
        end

        -- a Ghost Patrol stretch that goes on (NoEndStop) does not end there: no braking toward its last point
        local target = leg.NoEndStop and (leg.Cruise or TAXI_CRUISE) or math.min(TAXI_CRUISE, routeSpeedLimit(route, idx, proj))
        if leg.NoEndStop and ghostMode then
            -- the end of this stretch is not the zone (the way on is not known yet): the car never gets to it at speed,
            -- the road may end there
            local rem = (flat(route[#route]) - pos).Magnitude
            if rem < 70 then
                target = math.min(target, math.max(6, rem * 0.35))
            end
        end
        why = "free"
        if target < TAXI_CRUISE then
            why = "route end"
        end
        if inside then
            target = math.min(target, 5)
            why = "box"
            if deep or dZone < 10 or fClear < 10 then
                target = 0
            end
        end
        if now < taxiSlowUntil and (inside or dZone < 40) then
            target = math.min(target, 6)
            why = "TaxiSlowDown"
        end
        if pClear < 8 + speed * 0.5 then
            local lim = math.max(4, (pClear - 5) * 1.5)
            if lim < target then
                target = lim
                why = "obstacle on route"
            end
        end
        if backToRoad then
            target = math.min(target, 9)
            why = "off road"
        end
        if math.abs(ang) > 1.5 and speed < 14 then
            target = math.min(target, 14)
            why = "turning around"
        end

        if target > 1 and fClear < 3 and speed < 2 then
            blockedSince = blockedSince or now
        elseif fClear >= 3 then
            blockedSince = nil
        end
        if blockedSince and now - blockedSince > 0.25 and now > backupUntil and now > recoverHold then
            setStatus("Taxi blocked, finding a way around")
            taxiLog(string.format("BLOCKED at %.0f,%.0f front=%.1f back=%.1f", pos.X, pos.Z, fClear, bClear))
            blockedSince = nil
            blockedCount += 1
            leg.BlockedAt, leg.Blocked = pos, (leg.Blocked or 0) + 1 -- Ghost Patrol learns from where the car got held up
            local key = spotKey(pos)
            local rec = stuckTried[key]
            if not rec then
                rec = { offs = {}, heads = {}, n = 0 }
                stuckTried[key] = rec
            end
            rec.n += 1
            if lastShortcutKey and now - lastShortcutAt < 45 and not onRoad then
                taxiBadShortcut[lastShortcutKey] = true
            end
            local crumb = crumbs[#crumbs]
            if not onRoad and rec.n >= 3 and crumb and (flat(crumb) - pos).Magnitude < 400 and not ghostMode then
                -- Live: stuck off the road in a pit under the Dam, the dodges and detours found nothing. The car goes back onto the
                -- last place on the road it was driving on and the way is planned again from there; shortcuts are off for a while.
                taxiLog("stuck off the road: put back on the road")
                cpos = crumb
                speed = 0
                pitch = 0
                tPitch = nil
                goodPos = cpos
                rec.n = 0
                noShortcutUntil = now + 180
                dodge, detour, pivot, slide, backupUntil = nil, nil, nil, nil, 0
                local own = roadConnector(flat(cpos), zone, cpos.Y, roadParams, 6000)
                if own then
                    route = roundRoute(own)
                    idx = 1
                end
                applyPose(0)
                RunService.Heartbeat:Wait()
                continue
            end
            if dodge then
                rec.offs[dodge.off] = true
            end
            dodge, detour, pivot, slide = nil, nil, nil, nil
            local canBack = bClear >= 2.6
            local runUp = canBack and math.min(0.9, (bClear - 1.5) / 3.4) or 0
            recoverHold = now + runUp + 1.8
            local kind, way
            if rec.n >= 3 and not retracing and startRetrace() then
                kind = "retrace"
                rec.n = 0
                backupUntil = now + runUp
                taxiLog("RETRACE the road we came in on")
            else
                kind, way = chooseWayOut(rec, math.min(fClear, 12) + pp.Size.Z + 6)
            end
            if kind == "retrace" then
                taxiLog("retracing")
            elseif kind == "dodge" then
                dodge = way
                dodge.len += runUp * 7
                backupUntil = now + runUp
                if not canBack then
                    slide = { right = way.right, rem = way.off }
                end
                taxiLog(string.format("DODGE lane %+.1f", way.off))
            elseif kind == "detour" then
                detour = way
                backupUntil = now + runUp
                pivot = { dir = way.dir, t0 = now + runUp }
                taxiLog(string.format("DETOUR to %.0f,%.0f", way.aim.X, way.aim.Z))
            else
                table.clear(rec.offs)
                table.clear(rec.heads)
                if canBack then
                    backupUntil = now + 2
                end
                local own = roadConnector(pos, zone, cpos.Y, roadParams, 6000)
                if own then
                    route = roundRoute(own)
                    idx = 1
                    taxiLog("re-planned from the blocked spot")
                end
            end
        end
        if now >= backupUntil then
            if pivot then
                local to = pivot.dir
                local turnAng = math.atan2(dir.X * to.Z - dir.Z * to.X, dir:Dot(to))
                if math.abs(turnAng) < 0.1 or now - pivot.t0 > 4 then
                    pivot = nil
                else
                    local r = math.clamp(turnAng * 3, -1.2, 1.2)
                    local turnedDir = CFrame.Angles(0, -r * dt, 0) * dir
                    dir = Vector3.new(turnedDir.X, 0, turnedDir.Z).Unit
                    speed = 0
                    applyPose(r)
                    RunService.Heartbeat:Wait()
                    continue
                end
            elseif slide then
                local sgn = slide.rem >= 0 and 1 or -1
                local step = math.min(math.abs(slide.rem), 4 * dt)
                if step < 0.02 then
                    slide = nil
                else
                    cpos += slide.right * sgn * step
                    slide.rem -= sgn * step
                    speed = 0
                    applyPose(0)
                    RunService.Heartbeat:Wait()
                    continue
                end
            end
        end
        local reversing = now < backupUntil
        if reversing then
            target = -7
            why = "backing up"
            if bClear < 2.5 then
                backupUntil = 0
            end
        end

        if speed > 20 then
            blockedCount = 0
        end

        -- speed: ramp toward the plan, never into something solid
        if speed < target then
            speed = math.min(target, speed + TAXI_ACCEL * dt)
        else
            speed = math.max(target, speed - TAXI_BRAKE * dt)
        end
        if speed > 0 and fClear < 2.5 then
            speed = 0
            why = "solid ahead"
        elseif speed < 0 and bClear < 2.5 then
            speed = 0
        end

        local rate = 0
        if math.abs(speed) > 0.3 and not reversing then
            rate = math.clamp(ang * 4, -TAXI_YAW, TAXI_YAW)
        end
        local turned = CFrame.Angles(0, -rate * dt, 0) * dir
        dir = Vector3.new(turned.X, 0, turned.Z).Unit
        if speed > 5 then
            orbitTurn += rate * dt
        end
        cpos += dir * speed * dt
        if dodge and speed > 0 then
            dodge.dist += speed * dt
        end
        applyPose(rate)
        RunService.Heartbeat:Wait()
    end
    -- hand the car back to the game's physics
    NC.driveActive = false
    speed = 0
    pcall(function()
        pp.AssemblyLinearVelocity = Vector3.zero
        pp.AssemblyAngularVelocity = Vector3.zero
    end)
    kinOff()
    moveVec = Vector3.zero
    return taxiSerial ~= serial0 and "newtask" or "stopped"
end
local dispatchBox
local function insideDispatch(point)
    if not dispatchBox then
        local city = workspace.Environment:FindFirstChild("Locations") and workspace.Environment.Locations:FindFirstChild("City")
        local td = city and city:FindFirstChild("TaxiDispatch")
        local interior = td and td:FindFirstChild("Interior")
        if not interior then
            return false
        end
        local ok, cf, size = pcall(function()
            return interior:GetBoundingBox()
        end)
        if not ok then
            return false
        end
        dispatchBox = { cf, size }
    end
    local rel = dispatchBox[1]:PointToObjectSpace(point)
    local size = dispatchBox[2]
    return math.abs(rel.X) <= size.X / 2 and math.abs(rel.Y) <= size.Y / 2 and math.abs(rel.Z) <= size.Z / 2
end

local function taxiStandPoints(part, char, rootPos)
    local out = {}
    for _, r in ipairs({ 6, 7.5, 9 }) do
        for a = 0, 315, 45 do
            local x = part.Position.X + math.cos(math.rad(a)) * r
            local z = part.Position.Z + math.sin(math.rad(a)) * r
            local floor = floorBelow(x, part.Position.Y + 2, z, { char, part.Parent })
            if floor then
                table.insert(out, { floor, (floor - rootPos).Magnitude, r })
            end
        end
    end
    table.sort(out, function(p, q)
        if p[3] ~= q[3] then
            return p[3] < q[3]
        end
        return p[2] < q[2]
    end)
    return out
end

local function enterTaxi()
    local char, hum, root = getChar()
    if not hum then
        setStatus("Waiting for character")
        task.wait(1)
        return
    end
    local stands = workspace:FindFirstChild("Environment") and workspace.Environment:FindFirstChild("TaxiStands")
    local list = {}
    local now = os.clock()
    if stands then
        for _, stand in ipairs(stands:GetChildren()) do
            local part = stand.Name == "Taxi" and stand:FindFirstChild("TaxiJobCar")
            if part then
                local sv = part:FindFirstChild("StaticVehicleObject")
                if sv and sv.Value and sv.Value:IsDescendantOf(workspace) and not (badTaxi[part] and badTaxi[part] > now) then
                    table.insert(list, {
                        part = part,
                        d = (part.Position - root.Position).Magnitude,
                        inside = insideDispatch(part.Position),
                    })
                end
            end
        end
    end
    table.sort(list, function(p, q)
        if p.inside ~= q.inside then
            return not p.inside
        end
        return p.d < q.d
    end)
    if #list == 0 then
        setStatus("No free taxi found, waiting")
        task.wait(2)
        return
    end
    local best
    for i = 1, math.min(#list, 3) do
        local part = list[i].part
        setStatus("Walking to taxi")
        for _, sp in ipairs(taxiStandPoints(part, char, root.Position)) do
            if not (running and farming) then
                return
            end
            if walkTo(sp[1], true) then
                best = part
                break
            end
        end
        if best then
            break
        end
        badTaxi[part] = os.clock() + 120
    end
    if not best then
        setStatus("Can't reach a taxi, retrying")
        task.wait(1)
        return
    end
    setStatus("Getting in the taxi")
    local module = JobHandler:GetJobModule(TAXI_ID)
    if module and module.UseTaxi then
        local entering = true
        task.spawn(function()
            while entering and running and farming do
                local v = getTaxiVehicle()
                if v then
                    NC.carOk = true
                    NC.on(v)
                    break
                end
                RunService.Heartbeat:Wait()
            end
        end)
        pcall(function()
            module:UseTaxi(best) -- same call as the "I_Use" interaction
        end)
        entering = false
    end
    local t0 = os.clock()
    while running and farming and os.clock() - t0 < 10 and not getTaxiVehicle() do
        RunService.Heartbeat:Wait()
    end
    local seated = getTaxiVehicle()
    if seated then
        NC.carOk = true
        NC.on(seated)
    end
    if not getTaxiVehicle() then
        badTaxi[best] = os.clock() + 60
    end
end

local inCarSince, lastStartTry = nil, 0

local function taxiStep()
    if not farming then
        NC.carOk = false
        releaseDrive()
        inCarSince = nil
        taxiTask, taxiSlowUntil = nil, 0
        table.clear(taxiCrumbs)
        task.wait(0.3)
        return
    end
    local model, pp = getTaxiVehicle()
    if not pp then
        NC.carOk = false
        releaseDrive()
        inCarSince = nil
        enterTaxi()
        return
    end
    NC.carOk = true
    NC.on(model)
    if not isWorkingJob(TAXI_ID) then
        releaseDrive()
        inCarSince = inCarSince or os.clock()
        setStatus("Waiting for the taxi job to start")
        if os.clock() - inCarSince > 6 and os.clock() - lastStartTry > 6 then
            lastStartTry = os.clock()
            pcall(function()
                JobHandler:StartWorking(TAXI_ID)
            end)
        end
        task.wait(0.5)
        return
    end
    inCarSince = nil
    local task_ = currentTaxiTask()
    if not task_ then
        setStatus("Waiting for passenger")
        task.wait(1)
        return
    end
    local ok, err = pcall(driveLeg, task_)
    releaseDrive()
    if not ok then
        warn("[Legit Farm Job] drive error: " .. tostring(err))
        task.wait(1)
    end
end
-- Seller - Ben's Ice Cream
local iceStep, iceCall, iceInsideArea
do
local iceSeen = setmetatable({}, { __mode = "k" })
local iceDone = setmetatable({}, { __mode = "k" })
local iceBad = setmetatable({}, { __mode = "k" }) -- customer -> retry time
local iceAssetsCache
local ICE_SCOOP_IMAGE = "rbxassetid://2132263837"

local function iceRoot()
    local env = workspace:FindFirstChild("Environment")
    local loc = env and env:FindFirstChild("Locations")
    local beach = loc and loc:FindFirstChild("Beach")
    return beach and beach:FindFirstChild("BensIceCream")
end

local function iceAssets()
    if iceAssetsCache then
        return iceAssetsCache
    end
    local gobj = ReplicatedStorage:FindFirstChild("GameObjects")
    local jobAssets = gobj and gobj:FindFirstChild("JobAssets")
    local ja = jobAssets and jobAssets:FindFirstChild("BensIceCream")
    if not ja then
        return nil
    end
    local flavors, toppings = {}, {}
    for _, n in ipairs({ "Vanilla", "Chocolate", "Strawberry" }) do
        local v = ja:FindFirstChild(n)
        if v and v:IsA("BrickColorValue") then
            flavors[n] = v.Value.Color
        end
    end
    for _, n in ipairs({ "Caramel", "Sprinkles", "Nuts" }) do
        local f = ja:FindFirstChild(n)
        local d = f and f:FindFirstChildWhichIsA("Decal", true)
        if d and d.Texture ~= "" then
            toppings[d.Texture] = n
        end
    end
    iceAssetsCache = { flavors = flavors, toppings = toppings }
    return iceAssetsCache
end

local function iceColorNear(a, b)
    return math.abs(a.R - b.R) < 0.04 and math.abs(a.G - b.G) < 0.04 and math.abs(a.B - b.B) < 0.04
end

local function iceReadOrder(npc)
    local assets = iceAssets()
    if not assets then
        return nil, "waiting"
    end
    local head = npc:FindFirstChild("Head")
    local bubble = head and head:FindFirstChild("ChatBubble")
    local body = bubble and bubble:FindFirstChild("Body")
    local iconFrame = body and body:FindFirstChild("IconFrame")
    local frame = iconFrame and iconFrame:FindFirstChild(" ")
    if not frame then
        return nil, "waiting"
    end
    local icons = {}
    for _, d in ipairs(frame:GetChildren()) do
        if d:IsA("ImageLabel") and d.Name == "Icon" and d.Visible then
            table.insert(icons, d)
        end
    end
    if #icons == 0 then
        return nil, "waiting"
    end
    table.sort(icons, function(a, b)
        if a.LayoutOrder ~= b.LayoutOrder then
            return a.LayoutOrder < b.LayoutOrder
        end
        return a.AbsolutePosition.X < b.AbsolutePosition.X
    end)
    local items, scoops, toppings = {}, 0, 0
    for _, icon in ipairs(icons) do
        if icon.Image == ICE_SCOOP_IMAGE then
            local flavor
            for n, c in pairs(assets.flavors) do
                if iceColorNear(icon.ImageColor3, c) then
                    flavor = n
                    break
                end
            end
            if not flavor then
                local c = icon.ImageColor3
                return nil, "unknown", string.format("scoop colour %.2f,%.2f,%.2f", c.R, c.G, c.B)
            end
            scoops += 1
            table.insert(items, { kind = "scoop", name = flavor })
        elseif assets.toppings[icon.Image] then
            toppings += 1
            table.insert(items, { kind = "topping", name = assets.toppings[icon.Image] })
        else
            return nil, "unknown", "icon " .. tostring(icon.Image)
        end
    end
    if scoops < 1 or scoops > 2 or toppings > 1 then
        return nil, "unknown", scoops .. " scoops and " .. toppings .. " toppings"
    end
    return items
end

local function iceDescribe(items)
    local out = {}
    for _, it in ipairs(items) do
        table.insert(out, it.name)
    end
    return table.concat(out, " + ")
end

local function iceValid(slot, npc)
    return npc.Parent ~= nil and slot.Occupied.Value == npc
end

local function iceCup()
    local ok, cup = pcall(function()
        return JobHandler.Shared.EquipmentService:GetEquipped(LocalPlayer)
    end)
    if ok and cup and cup.Name == "Ice Cream Cup" then
        return cup
    end
end

local function iceFilled(cup)
    local n = 0
    for _, name in ipairs({ "Ball1", "Ball2" }) do
        local ball = cup:FindFirstChild(name)
        if ball and ball.Transparency < 1 then
            n += 1
        end
    end
    return n
end

local function iceCallback(obj, wanted)
    local reg = getInteractRegistry()
    local entry = reg and reg[obj]
    local gens = entry and entry[1]
    if type(gens) ~= "table" then
        return nil
    end
    for _, gen in ipairs(gens) do
        if type(gen) == "function" then
            local ok, text, _, cb = pcall(gen)
            if ok and text == wanted and type(cb) == "function" then
                return cb
            end
        end
    end
end

function iceCall(cb)
    if not cleanSafe(cb) then
        farming = false
        if FarmToggle then
            withUiIdentity(function()
                FarmToggle:Set(false)
            end)
        end
        setStatus("Stopped: unsafe ice cream state")
        return false
    end
    pcall(cb)
    return true
end

local function iceDiscardCup()
    if iceCup() then
        pcall(function()
            JobHandler.Shared.EquipmentService:UnequipItem(LocalPlayer, "Ice Cream Cup", true)
        end)
        task.wait(0.3)
    end
end

local function iceStandPoints(shop, model, char)
    local origin = shop:FindFirstChild("Origin")
    local p = model:GetPivot().Position
    local c = origin and origin.Position or p
    local dir = Vector3.new(c.X - p.X, 0, c.Z - p.Z)
    dir = dir.Magnitude > 0.1 and dir.Unit or Vector3.new(0, 0, 1)
    local side = Vector3.new(-dir.Z, 0, dir.X)
    local out = {}
    for _, o in ipairs({ { 3.5, 0 }, { 4.5, 0 }, { 3, 2 }, { 3, -2 }, { 5.5, 0 } }) do
        local x = p.X + dir.X * o[1] + side.X * o[2]
        local z = p.Z + dir.Z * o[1] + side.Z * o[2]
        local floor = floorBelow(x, p.Y + 3, z, { char, model })
        if floor then
            table.insert(out, floor)
        end
    end
    return out
end

local function iceWalkNear(shop, model)
    local char, _, root = getChar()
    if not root then
        return false
    end
    local p = model:GetPivot().Position
    if (Vector3.new(root.Position.X, 0, root.Position.Z) - Vector3.new(p.X, 0, p.Z)).Magnitude <= 4.8 then
        return true
    end
    for _, sp in ipairs(iceStandPoints(shop, model, char)) do
        if not (running and farming) then
            return false
        end
        local ok, why = walkTo(sp, true)
        if ok then
            return true
        end
        if why == "gave up" then
            return false
        end
    end
    return false
end

function iceInsideArea(pos)
    local ok, inside = pcall(function()
        local mod = JobHandler:GetCurJobModule()
        local ab = mod and mod.AreaBlock
        if not ab then
            return false
        end
        local v = ab.CFrame:Inverse() * pos
        local s = ab.Size
        return math.abs(v.X) - 5 < s.X * 0.5 and math.abs(v.Y) - 5 < s.Y * 0.5 and math.abs(v.Z) - 5 < s.Z * 0.5
    end)
    return ok and inside
end

-- the shop-side window the customer is standing at (the NPC's own position; its slot when it has no body yet)
local function iceWindowOf(shop, slot, npc)
    local origins = shop:FindFirstChild("OrderOrigins")
    local body = npc and (npc:FindFirstChild("HumanoidRootPart") or npc.PrimaryPart)
    local at = body and body.Position or slot.Position
    local best, bestD
    if origins then
        for _, o in ipairs(origins:GetChildren()) do
            local d = (Vector3.new(o.Position.X, 0, o.Position.Z) - Vector3.new(at.X, 0, at.Z)).Magnitude
            if not bestD or d < bestD then
                best, bestD = o, d
            end
        end
    end
    return best
end

local function icePickCustomer(shop)
    local targets = shop:FindFirstChild("CustomerTargets")
    if not targets then
        return nil
    end
    local now = os.clock()
    local best, bestSlot, bestOrder, bestSeen
    local pending = false
    for _, slot in ipairs(targets:GetChildren()) do
        local occ = slot:FindFirstChild("Occupied")
        local npc = occ and occ.Value
        if npc and npc.Parent and not iceDone[npc] and not (iceBad[npc] and iceBad[npc] > now) then
            iceSeen[npc] = iceSeen[npc] or now
            local items, why, detail = iceReadOrder(npc)
            if items then
                if not bestSeen or iceSeen[npc] < bestSeen then
                    best, bestSlot, bestOrder, bestSeen = npc, slot, items, iceSeen[npc]
                end
            elseif why == "unknown" then
                iceDone[npc] = true
                warn("[Legit Farm Job] ice cream: unknown order item (" .. tostring(detail) .. ")")
                setStatus("Unknown order item, see console")
            elseif now - iceSeen[npc] > 5 then
                iceBad[npc] = now + 10
            else
                pending = true
            end
        end
    end
    return best, bestSlot, bestOrder, pending
end

local function iceServe(shop, slot, npc, items)
    local toTake = shop.Interior.TableObjects
    local started = os.clock()
    walkAbort = function()
        return not iceValid(slot, npc) or os.clock() - started > 60
    end
    walkProgress = nil
    local function fail(reason)
        walkAbort, walkProgress = nil, nil
        if running and farming then
            setStatus(reason)
            local _, h, r = getChar()
            if h and r then
                h:MoveTo(r.Position) -- stop where it is
            end
        end
        return false
    end

    local cup = iceCup()
    if cup and iceFilled(cup) > 0 then
        iceDiscardCup()
        cup = nil
    end
    if not cup then
        setStatus("Getting a cup")
        local cups = toTake:FindFirstChild("IceCreamCups")
        if not (cups and iceWalkNear(shop, cups)) then
            return fail("Can't reach the cups, retrying")
        end
        for _ = 1, 3 do
            local cb = iceCallback(cups, "I_Take")
            if cb and not iceCall(cb) then
                walkAbort, walkProgress = nil, nil
                return false
            end
            local t0 = os.clock()
            while running and farming and os.clock() - t0 < 2 and not iceCup() do
                task.wait(0.05)
            end
            if iceCup() then
                break
            end
        end
        cup = iceCup()
        if not cup then
            return fail("Could not take a cup, retrying")
        end
    end

    local prevItem
    for _, item in ipairs(items) do
        if not (running and farming) then
            walkAbort, walkProgress = nil, nil
            return false
        end
        if not iceValid(slot, npc) then
            return fail("Customer left, moving on")
        end
        prevItem = item.name
        local station = toTake:FindFirstChild(item.name)
        if not station then
            return fail("Station " .. item.name .. " not found")
        end
        setStatus("Adding " .. item.name)
        if not iceWalkNear(shop, station) then
            return fail("Can't reach " .. item.name .. ", retrying")
        end
        cup = iceCup()
        if not cup then
            return fail("Lost the cup, retrying")
        end
        local before = iceFilled(cup)
        local added = false
        -- a second scoop comes 0.25-0.30 s after the first one landed, same flavour or not (the player's own pace,
        -- measured live: 0.25-0.30 s between scoops)
        if item.kind == "scoop" and NC.iceLastScoop and before > 0 then
            local gap = 0.25 + math.random() * 0.05
            while running and farming and os.clock() - NC.iceLastScoop < gap do
                task.wait()
            end
        end
        for _ = 1, 8 do
            local cb = iceCallback(station, "B_Add")
            if cb then
                if not iceCall(cb) then
                    walkAbort, walkProgress = nil, nil
                    return false
                end
                if item.kind == "scoop" then
                    local t0 = os.clock()
                    while running and farming and os.clock() - t0 < 1 do
                        local c = iceCup()
                        if c and iceFilled(c) > before then
                            added = true
                            NC.iceLastScoop = os.clock()
                            break
                        end
                        task.wait(0.03)
                    end
                else
                    added = true
                end
                if added then
                    break
                end
            else
                task.wait(0.15)
            end
        end
        if not added then
            warn("[Legit Farm Job] ice cream: " .. item.name .. " was not offered by the game")
            return fail("Could not add " .. item.name .. ", retrying")
        end
        task.wait(0.15 + math.random() * 0.1)
    end

    if not iceValid(slot, npc) then
        return fail("Customer left, moving on")
    end
    setStatus("Serving customer")
    local window = iceWindowOf(shop, slot, npc)
    if not (window and iceWalkNear(shop, window)) then
        return fail("Can't reach the window, retrying")
    end
    walkAbort, walkProgress = nil, nil
    local orderValue = npc:FindFirstChild("Order")
    -- the customer's order bubble is the game's: it is removed the moment the server decides on the order (Order
    -- changes). Only a customer still waiting with this same order gets the cup; otherwise it is thrown away
    local still = orderValue and orderValue.Value == "" and iceReadOrder(npc)
    if not (still and iceDescribe(still) == iceDescribe(items)) then
        iceDiscardCup()
        return fail("Customer no longer waiting for this order, next one")
    end
    local gave = false
    for _ = 1, 6 do
        if not iceValid(slot, npc) then
            break
        end
        local cb = iceCallback(npc, "I_Give")
        if cb then
            if not iceCall(cb) then
                return false
            end
            gave = true
            break
        end
        task.wait(0.15)
    end
    if not gave then
        return fail("Customer left, moving on")
    end
    local t0 = os.clock()
    while running and farming and os.clock() - t0 < 6 and iceValid(slot, npc)
        and not (orderValue and orderValue.Value ~= "") do
        task.wait(0.05)
    end
    if orderValue and orderValue.Value == "false" then
        warn("[Legit Farm Job] ice cream: the server rejected the order " .. iceDescribe(items))
        setStatus("Order rejected, next customer")
    else
        setStatus("Order served")
    end
    return true
end

function iceStep()
    if not farming then
        task.wait(0.3)
        return
    end
    if not isWorkingJob(ICE_ID) then
        setStatus("Start the Ben's Ice Cream job first")
        task.wait(1)
        return
    end
    local char, hum, root = getChar()
    if not hum then
        setStatus("Waiting for character")
        task.wait(1)
        return
    end
    local shop = iceRoot()
    if not (shop and shop:FindFirstChild("CustomerTargets") and shop:FindFirstChild("Interior")) then
        setStatus("Ice cream shop not found, waiting")
        task.wait(2)
        return
    end
    local npc, slot, items, pending = icePickCustomer(shop)
    if not npc then
        if not (running and farming) then
            return
        end
        if pending then
            setStatus("Reading order")
            task.wait(0.1)
            return
        end
        -- nobody yet: wait at a window (the closest one)
        local origins = shop:FindFirstChild("OrderOrigins")
        local nearest, nd
        if origins then
            for _, o in ipairs(origins:GetChildren()) do
                local d = (Vector3.new(o.Position.X, 0, o.Position.Z) - Vector3.new(root.Position.X, 0, root.Position.Z)).Magnitude
                if not nd or d < nd then
                    nearest, nd = o, d
                end
            end
        end
        if nearest and nd > 7 then
            setStatus("Walking to a window")
            walkAbort = function()
                return icePickCustomer(shop) ~= nil
            end
            iceWalkNear(shop, nearest)
            walkAbort, walkProgress = nil, nil
        else
            setStatus("Waiting for customer")
            task.wait(0.25)
        end
        return
    end
    setStatus("Order: " .. iceDescribe(items))
    local served = iceServe(shop, slot, npc, items)
    walkAbort, walkProgress = nil, nil
    if served then
        iceDone[npc] = true
    elseif farming then
        if iceValid(slot, npc) then
            iceBad[npc] = os.clock() + 3
        end
        task.wait(0.3)
    end
end
end

-- Fast Food Worker - Cashier
local cashStep, cashLeave
do
local function cashStatus(text)
    if farming then
        setStatus(text)
    end
end
local cashDone = setmetatable({}, { __mode = "k" }) -- customer -> served
local cashBad = setmetatable({}, { __mode = "k" }) -- customer -> retry time
local cashSeen = setmetatable({}, { __mode = "k" })
local cashStationBad = {}
local cashAsked = setmetatable({}, { __mode = "k" })
local cashLearned = {}
local CASH_EXTRA_BURGER = {
    ["14358880695"] = "Cheese [Chopped]", ["14358886220"] = "Plantbased Patty [Cooked]",
    ["14358865402"] = "Lettuce [Chopped]", ["14358884748"] = "Tomato [Chopped]",
}
local CASH_GREEN = Color3.fromRGB(109, 189, 80)
local CASH_SIZES = { S = "Small", M = "Medium", L = "Large" }
local CASH_AGENTS = {
    { AgentRadius = 1, AgentHeight = 4, AgentCanJump = false },
    { AgentRadius = 0.5, AgentHeight = 4, AgentCanJump = false },
}

local function cashWeld()
    local char = LocalPlayer.Character
    if not char then
        return nil
    end
    local ok, weld = pcall(function()
        return JobHandler.Shared.AttachService:GetAttachWeld(char)
    end)
    return ok and weld or nil
end

local function cashSession()
    local ok, role = pcall(function()
        return JobHandler:GetCurJobModule().BloxBurgersCashier
    end)
    if not (ok and type(role) == "table" and type(role.OnStationLeave) == "function" and debug.getupvalues) then
        return nil
    end
    local ok2, ups = pcall(debug.getupvalues, role.OnStationLeave)
    if not (ok2 and type(ups) == "table") then
        return nil
    end
    local gui, state, station
    for _, v in pairs(ups) do
        if type(v) == "table" then
            if v.Pages and v.Tabs and v.Checkmark then
                gui = v
            elseif v.Frames or v.Customer or v.CurrentPage then
                state = v
            end
        elseif typeof(v) == "Instance" and v.Name:find("^Cashier_") then
            station = v
        end
    end
    return role, gui, state, station
end

function cashLeave()
    for _ = 1, 3 do
        if not cashWeld() then
            return true
        end
        local _, hum = getChar()
        if not hum then
            return false
        end
        hum.Jump = true
        local t0 = os.clock()
        while os.clock() - t0 < 1.5 and cashWeld() do
            task.wait(0.1)
        end
    end
    return cashWeld() == nil
end

local function cashPress(btn)
    if not btn then
        return false
    end
    local ok, conns = pcall(getconnections, btn.Activated)
    if not (ok and type(conns) == "table" and #conns > 0) then
        return false
    end
    for _, c in ipairs(conns) do
        local fn = c.Function
        if type(fn) ~= "function" or not cleanSafe(fn) then
            farming = false
            if FarmToggle then
                withUiIdentity(function()
                    FarmToggle:Set(false)
                end)
            end
            setStatus("Stopped: unsafe cashier state")
            return false
        end
        pcall(function()
            c:Fire()
        end)
    end
    return true
end

local function cashImageId(img)
    return tostring(img):match("%d+")
end

-- image id -> { kind, name } from the game's own buttons
local function cashIconMap(gui)
    local map = {}
    local burger = gui.Pages:FindFirstChild("Burger")
    local ing = burger and burger:FindFirstChild("Ingredients")
    if ing then
        for _, f in ipairs(ing:GetChildren()) do
            local b = f:FindFirstChild("Button")
            local ic = b and b:FindFirstChild("Icon")
            if ic and ic:IsA("ImageLabel") then
                map[cashImageId(ic.Image)] = { "burger", f.Name }
            end
        end
    end
    for id, name in pairs(CASH_EXTRA_BURGER) do
        map[id] = { "burger", name }
    end
    for _, pg in ipairs({ "Side", "Drink" }) do
        local page = gui.Pages:FindFirstChild(pg)
        local types = page and page:FindFirstChild("Type")
        if types then
            local owners, uses = {}, {}
            for _, b in ipairs(types:GetChildren()) do
                local seen = {}
                local overlay = b:FindFirstChild("Overlay")
                for _, d in ipairs(b:GetDescendants()) do
                    if d:IsA("ImageLabel") and not (overlay and d:IsDescendantOf(overlay)) then
                        local id = cashImageId(d.Image)
                        if id and not seen[id] then
                            seen[id] = true
                            uses[id] = (uses[id] or 0) + 1
                            owners[id] = b.Name
                        end
                    end
                end
            end
            for id, n in pairs(uses) do
                if n == 1 then
                    map[id] = { pg:lower(), owners[id] }
                end
            end
        end
    end
    return map
end

local function cashFrameIcons(frame)
    local icons = {}
    for _, d in ipairs(frame:GetChildren()) do
        if d:IsA("ImageLabel") and d.Name == "Icon" and d.Visible then
            table.insert(icons, d)
        end
    end
    table.sort(icons, function(a, b)
        if a.LayoutOrder ~= b.LayoutOrder then
            return a.LayoutOrder < b.LayoutOrder
        end
        return a.AbsolutePosition.X < b.AbsolutePosition.X
    end)
    return icons
end

local function cashLabelText(icon, childName)
    local c = icon:FindFirstChild(childName)
    local tl = c and c:FindFirstChildWhichIsA("TextLabel", true)
    return tl and tl.Text
end

local function cashParse(gui, state)
    local frames = state.Frames
    if type(frames) ~= "table" or #frames < 2 or not (frames[1] and frames[2]) then
        return nil, "waiting"
    end
    local hasDrink = frames[1]:GetAttribute("HasDrink")
    if hasDrink and not frames[3] then
        return nil, "waiting"
    end
    local map = cashIconMap(gui)
    local order = { burger = {} }
    local icons = cashFrameIcons(frames[1])
    if #icons == 0 then
        return nil, "waiting"
    end
    local total = 0
    local unknownIcons = {}
    for _, ic in ipairs(icons) do
        local id = cashImageId(ic.Image)
        local known = map[id] or cashLearned[id]
        if not (known and known[1] == "burger") then
            unknownIcons[id] = true
        end
    end
    local nUnknown = 0
    for _ in pairs(unknownIcons) do
        nUnknown += 1
    end
    for _, ic in ipairs(icons) do
        local id = cashImageId(ic.Image)
        local item = map[id] or cashLearned[id]
        if not (item and item[1] == "burger") then
            local candidate
            local ing = gui.Pages.Burger:FindFirstChild("Ingredients")
            if nUnknown == 1 and ing and not (cashLearned[id] and cashLearned[id][1] == "rejected") then
                local confirmed = { ["Meat Patty [Cooked]"] = true }
                for _, name in pairs(CASH_EXTRA_BURGER) do
                    confirmed[name] = true
                end
                for _, v in pairs(cashLearned) do
                    confirmed[v[2]] = true
                end
                for _, f in ipairs(ing:GetChildren()) do
                    local b = f:FindFirstChild("Button")
                    local ov = b and b:FindFirstChild("Overlay")
                    if b and not f.Name:find("Bun") and not confirmed[f.Name] and not (ov and ov.Visible) then
                        if candidate then
                            candidate = false -- more than one: no elimination
                            break
                        end
                        candidate = f.Name
                    end
                end
            end
            if not candidate then
                return nil, "unknown", "burger icon " .. tostring(ic.Image)
            end
            item = { "burger", candidate }
            order.tentative = { id = id, name = candidate }
        end
        local amount = tonumber(tostring(cashLabelText(ic, "Amount")):match("^x(%d+)$"))
        if not amount then
            return nil, "unknown", "burger amount " .. tostring(cashLabelText(ic, "Amount"))
        end
        total += amount
        table.insert(order.burger, { name = item[2], count = amount })
    end
    if total > 8 then
        return nil, "unknown", "burger with " .. total .. " ingredients"
    end
    for idx, kind in ipairs({ "side", "drink" }) do
        local frame = frames[idx + 1]
        if kind == "side" or hasDrink then
            local sicons = cashFrameIcons(frame)
            if #sicons ~= 1 then
                return nil, "unknown", kind .. " frame with " .. #sicons .. " icons"
            end
            local item = map[cashImageId(sicons[1].Image)]
            if not (item and item[1] == kind) then
                return nil, "unknown", kind .. " icon " .. tostring(sicons[1].Image)
            end
            local size = CASH_SIZES[tostring(cashLabelText(sicons[1], "Size"))]
            if not size then
                return nil, "unknown", kind .. " size " .. tostring(cashLabelText(sicons[1], "Size"))
            end
            order[kind] = { name = item[2], size = size }
        end
    end
    return order
end

local function cashDescribe(order)
    local out = {}
    for _, b in ipairs(order.burger) do
        table.insert(out, b.count .. "x " .. (b.name:gsub(" %b[]", "")))
    end
    table.insert(out, order.side.size .. " " .. (order.side.name:gsub(" %b[]", "")))
    if order.drink then
        table.insert(out, order.drink.size .. " " .. order.drink.name)
    end
    return table.concat(out, ", ")
end

local function cashCount(folder, name)
    local n = 0
    for _, c in ipairs(folder:GetChildren()) do
        if c.Name == name then
            n += 1
        end
    end
    return n
end

-- still the same customer at the same register
local function cashAlive(state, npc)
    if not (running and farming) then
        return false
    end
    local _, gui, st2 = cashSession()
    return gui ~= nil and st2 == state and state.Customer == npc and npc.Parent ~= nil
end

local function cashPause(a, b)
    task.wait(a + math.random() * (b - a))
end

local cashSaid = setmetatable({}, { __mode = "k" })
local function cashHeard(gui, state, npc)
    local bubble = state.CurrentBubble
    local body = bubble and bubble.Parent and bubble:FindFirstChild("Body")
    local iconFrame = body and body:FindFirstChild("IconFrame")
    if iconFrame then
        for _, d in ipairs(iconFrame:GetChildren()) do
            local n = d:IsA("GuiObject") and tonumber(d.Name)
            if n and n > (cashSaid[npc] or 0) then
                cashSaid[npc] = n
            end
        end
    end
    local done = gui.RepeatButton ~= nil and gui.RepeatButton:GetAttribute("CanRepeat") == true
    if done then
        cashSaid[npc] = 3
    end
    return cashSaid[npc] or 0, done
end

local function cashWaitSaid(gui, state, npc, part)
    local t0 = os.clock()
    while cashAlive(state, npc) and os.clock() - t0 < 15 do
        local n, done = cashHeard(gui, state, npc)
        if n >= part or done then
            return true
        end
        task.wait(0.1)
    end
    return cashAlive(state, npc)
end

local function cashSelectTab(gui, state, name)
    if state.CurrentPage and state.CurrentPage.Name == name then
        return true
    end
    for _ = 1, 3 do
        cashPause(0.15, 0.35)
        cashPress(gui.Tabs:FindFirstChild(name))
        local t0 = os.clock()
        while os.clock() - t0 < 1 do
            task.wait(0.05)
            if state.CurrentPage and state.CurrentPage.Name == name then
                cashPause(0.35, 0.6)
                return true
            end
        end
    end
    return false
end

local function cashAddIngredient(ing, tray, name)
    local frame = ing:FindFirstChild(name)
    local btn = frame and frame:FindFirstChild("Button")
    if not btn then
        return false, "no " .. name .. " button"
    end
    local ov = btn:FindFirstChild("Overlay")
    if ov and ov.Visible then
        return false, name .. " is locked", true
    end
    local before = cashCount(tray, name)
    if before >= 9 then
        return false, "too many " .. name
    end
    for _ = 1, 4 do
        cashPress(btn)
        local t0 = os.clock()
        while os.clock() - t0 < 0.7 do
            task.wait(0.05)
            if cashCount(tray, name) > before then
                cashPause(0.5, 0.85)
                return true
            end
        end
    end
    return false, name .. " was not added"
end

-- Type / Size button of the Side and Drink pages
local function cashPickRadio(page, group, name, last)
    local grp = page:FindFirstChild(group)
    local btn = grp and grp:FindFirstChild(name)
    if not btn then
        return false, "no " .. name .. " button"
    end
    local ov = btn:FindFirstChild("Overlay")
    if ov and ov.Visible then
        return false, name .. " is locked", true
    end
    if btn:GetAttribute("Selected") then
        return true
    end
    for _ = 1, 3 do
        cashPause(0.1, 0.25)
        cashPress(btn)
        local t0 = os.clock()
        while os.clock() - t0 < 0.8 do
            task.wait(0.05)
            if btn:GetAttribute("Selected") then
                if not last then -- (the last button of the order: nothing left to add, it is submitted right away)
                    cashPause(0.4, 0.7)
                end
                return true
            end
        end
    end
    return false, name .. " could not be selected"
end

local function cashPickSideOrDrink(gui, state, tray, pageName, item, last)
    if not cashSelectTab(gui, state, pageName) then
        return false, "could not open the " .. pageName .. " tab"
    end
    local page = gui.Pages:FindFirstChild(pageName)
    local function firstUnlocked(group, skipName)
        local grp = page:FindFirstChild(group)
        for _, b in ipairs(grp and grp:GetChildren() or {}) do
            if b:IsA("GuiButton") and b.Name ~= skipName then
                local ov = b:FindFirstChild("Overlay")
                if not (ov and ov.Visible) then
                    return b.Name
                end
            end
        end
    end
    local substituted
    local typeName, sizeName = item.name, item.size
    local ok, why, locked = cashPickRadio(page, "Type", typeName)
    if not ok and locked then
        local alt = firstUnlocked("Type", typeName)
        if not alt then
            return false, why
        end
        warn("[Legit Farm Job] cashier: " .. typeName .. " is locked, using " .. alt .. " instead")
        typeName, substituted = alt, true
        ok, why = cashPickRadio(page, "Type", typeName)
    end
    if not ok then
        return false, why
    end
    ok, why, locked = cashPickRadio(page, "Size", sizeName, last)
    if not ok and locked then
        local alt = firstUnlocked("Size", sizeName)
        if not alt then
            return false, why
        end
        warn("[Legit Farm Job] cashier: size " .. sizeName .. " is locked, using " .. alt .. " instead")
        sizeName, substituted = alt, true
        ok, why = cashPickRadio(page, "Size", sizeName, last)
    end
    if not ok then
        return false, why
    end
    local folder = tray:FindFirstChild(pageName)
    local t0 = os.clock()
    while os.clock() - t0 < 1.5 do
        local m = folder and folder:FindFirstChild(typeName)
        if m and m:GetAttribute("Size") == sizeName then
            return true, nil, substituted
        end
        task.wait(0.05)
    end
    return false, pageName .. " is not on the tray"
end

local function cashBuild(gui, state, station, npc, order)
    local tray = station:FindFirstChild("FoodTargets")
    local burgerTray = tray and tray:FindFirstChild("Burger")
    if not (burgerTray and tray:FindFirstChild("Side") and tray:FindFirstChild("Drink")) then
        return false, "no tray"
    end
    for _, f in ipairs(tray:GetChildren()) do
        if #f:GetChildren() > 0 then
            return false, "tray not empty"
        end
    end
    cashStatus("Listening to the order")
    if not cashWaitSaid(gui, state, npc, 1) then
        return false, "customer left"
    end
    cashPause(0.6, 1.1)
    cashStatus("Building the burger")
    if not cashSelectTab(gui, state, "Burger") then
        return false, "could not open the Burger tab"
    end
    local ing = gui.Pages.Burger:FindFirstChild("Ingredients")
    local ok, why = cashAddIngredient(ing, burgerTray, "Bottom Bun [Raw]")
    if not ok then
        return false, why
    end
    local degraded, skipped = false, {}
    for _, item in ipairs(order.burger) do
        for n = 1, item.count do
            if not cashAlive(state, npc) then
                return false, "customer left"
            end
            cashStatus(string.format("Adding %s (%d/%d)", (item.name:gsub(" %b[]", "")), n, item.count))
            local locked
            ok, why, locked = cashAddIngredient(ing, burgerTray, item.name)
            if not ok and locked then
                warn("[Legit Farm Job] cashier: " .. item.name .. " is locked, leaving it out")
                skipped[item.name], degraded = true, true
                break
            end
            if not ok then
                return false, why
            end
        end
    end
    ok, why = cashAddIngredient(ing, burgerTray, "Top Bun [Raw]")
    if not ok then
        return false, why
    end
    cashStatus("Listening to the side")
    if not cashWaitSaid(gui, state, npc, 2) then
        return false, "customer left"
    end
    cashStatus("Adding " .. (order.side.name:gsub(" %b[]", "")))
    local sub
    ok, why, sub = cashPickSideOrDrink(gui, state, tray, "Side", order.side, not order.drink)
    if not ok then
        return false, why
    end
    degraded = degraded or sub == true
    if order.drink then
        cashStatus("Listening to the drink")
        if not cashWaitSaid(gui, state, npc, 3) then
            return false, "customer left"
        end
        cashStatus("Adding " .. order.drink.name)
        ok, why, sub = cashPickSideOrDrink(gui, state, tray, "Drink", order.drink, true)
        if not ok then
            return false, why
        end
        degraded = degraded or sub == true
    end
    for _, item in ipairs(order.burger) do
        if cashCount(burgerTray, item.name) ~= (skipped[item.name] and 0 or item.count) then
            return false, "burger on the tray does not match"
        end
    end
    return true, nil, degraded
end

local function cashTaken(station)
    local ok, free = pcall(function()
        return JobHandler:CanUseWorkstation(station, LocalPlayer)
    end)
    if ok and free == false then
        return true
    end
    local sp = station:FindFirstChild("StationPart")
    if sp then
        for _, plr in ipairs(Players:GetPlayers()) do
            local root = plr ~= LocalPlayer and plr.Character and plr.Character:FindFirstChild("HumanoidRootPart")
            if root and (Vector3.new(root.Position.X, 0, root.Position.Z) - Vector3.new(sp.Position.X, 0, sp.Position.Z)).Magnitude < 2.5
                and math.abs(root.Position.Y - sp.Position.Y) < 8 then
                return true
            end
        end
    end
    return false
end

-- walk to a register and use it
local function cashEnter()
    local char, hum, root = getChar()
    if not hum then
        cashStatus("Waiting for character")
        task.wait(1)
        return
    end
    local env = workspace:FindFirstChild("Environment")
    local ws = env
    for _, n in ipairs({ "Locations", "City", "BloxBurgers", "Interior", "ScriptableObjects", "Cashier", "Workstations" }) do
        ws = ws and ws:FindFirstChild(n)
    end
    if not ws then
        cashStatus("Cashier registers not found, waiting")
        task.wait(2)
        return
    end
    local now = os.clock()
    local list = {}
    local anyTaken = false
    for _, s in ipairs(ws:GetChildren()) do
        local ip = s:FindFirstChild("InteractionPoint")
        if ip and not (cashStationBad[s] and cashStationBad[s] > now) then
            if cashTaken(s) then
                anyTaken = true -- someone else is at it: skipped
            else
                table.insert(list, { s = s, ip = ip, d = (ip:GetPivot().Position - root.Position).Magnitude })
            end
        end
    end
    table.sort(list, function(a, b)
        return a.d < b.d
    end)
    if #list == 0 then
        cashStatus(anyTaken and "All registers are taken, waiting" or "No free register, waiting")
        task.wait(1.5)
        return
    end
    local pick = list[1]
    cashStatus("Walking to a register")
    local ipPos = pick.ip:GetPivot().Position
    local reached = false
    local walkStart = os.clock()
    local startedInside = iceInsideArea(root.Position)
    walkAgents = CASH_AGENTS
    walkAbort = function()
        local _, _, r = getChar()
        return os.clock() - walkStart > 45 or (startedInside and r ~= nil and not iceInsideArea(r.Position))
            or cashTaken(pick.s)
    end
    walkProgress = nil
    for _, off in ipairs({ { 3, 0 }, { 4, 0 }, { 3, 2 }, { 3, -2 }, { 5, 0 } }) do
        if not (running and farming) then
            walkAbort, walkAgents = nil, nil
            return
        end
        local floor = floorBelow(ipPos.X - off[1], ipPos.Y, ipPos.Z + off[2], { char, pick.ip })
        if floor then
            local ok = walkTo(floor, true)
            if ok then
                reached = true
                break
            end
        end
    end
    walkAbort, walkProgress, walkAgents = nil, nil, nil
    if not reached then
        cashStationBad[pick.s] = os.clock() + 30
        cashStatus("Can't reach a register, trying another")
        task.wait(0.5)
        return
    end
    cashStatus("Using the register")
    local cb
    for _ = 1, 10 do
        local reg = getInteractRegistry()
        local entry = reg and reg[pick.ip]
        local gens = entry and entry[1]
        for _, gen in ipairs(type(gens) == "table" and gens or {}) do
            if type(gen) == "function" then
                local ok, text, _, f = pcall(gen)
                if ok and text and type(f) == "function" then
                    cb = f
                    break
                end
            end
        end
        if cb then
            break
        end
        task.wait(0.2)
    end
    if not cb then
        cashStationBad[pick.s] = os.clock() + 20
        cashStatus("Register is not available, trying another")
        return
    end
    if not iceCall(cb) then
        return
    end
    local t0 = os.clock()
    while running and farming and os.clock() - t0 < 8 and not cashWeld() do
        task.wait(0.2)
    end
    if not cashWeld() then
        cashStationBad[pick.s] = os.clock() + 20
        cashStatus("Could not use the register, trying another")
        return
    end
    t0 = os.clock()
    while running and farming and os.clock() - t0 < 6 do
        local _, gui = cashSession()
        if gui then
            break
        end
        task.wait(0.2)
    end
end

function cashStep()
    if not farming then
        task.wait(0.3)
        return
    end
    if not isWorkingJob(CASH_ID) then
        cashStatus("Start the Fast Food Worker job first")
        task.wait(1)
        return
    end
    local _, hum = getChar()
    if not hum then
        cashStatus("Waiting for character")
        task.wait(1)
        return
    end
    if not cashWeld() then
        cashEnter()
        return
    end
    local _, gui, state, station = cashSession()
    if not (gui and station) then
        cashStatus("Opening the register")
        task.wait(0.3)
        return
    end
    local npc = state and state.Customer
    if not npc or cashDone[npc] or (cashBad[npc] and cashBad[npc] > os.clock()) then
        cashStatus("Waiting for customer")
        task.wait(0.15)
        return
    end
    cashSeen[npc] = cashSeen[npc] or os.clock()
    local order, why, detail = cashParse(gui, state)
    if not order then
        if why == "unknown" then
            warn("[Legit Farm Job] cashier: unknown order item (" .. tostring(detail) .. ")")
            cashStatus("Unknown order item, see console")
            cashBad[npc] = os.clock() + 30
        else
            cashStatus("Listening to the order")
            if os.clock() - cashSeen[npc] > 8 and gui.RepeatButton and gui.RepeatButton:GetAttribute("CanRepeat") then
                cashStatus("Asking to repeat the order")
                cashPress(gui.RepeatButton)
                cashSeen[npc] = os.clock()
            end
            task.wait(0.2)
        end
        return
    end
    cashStatus("Order: " .. cashDescribe(order))
    local function anyLocked()
        local function isLocked(btn)
            local ov = btn and btn:FindFirstChild("Overlay")
            return ov ~= nil and ov.Visible
        end
        local ing = gui.Pages.Burger:FindFirstChild("Ingredients")
        for _, it in ipairs(order.burger) do
            local f = ing and ing:FindFirstChild(it.name)
            if isLocked(f and f:FindFirstChild("Button")) then
                return true
            end
        end
        for kind, pg in pairs({ side = "Side", drink = "Drink" }) do
            local it = order[kind]
            local types = it and gui.Pages:FindFirstChild(pg) and gui.Pages[pg]:FindFirstChild("Type")
            if types and isLocked(types:FindFirstChild(it.name)) then
                return true
            end
        end
        return false
    end
    if not cashAsked[npc] and anyLocked() then
        cashAsked[npc] = true
        cashStatus("Ordered item is locked, asking to repeat")
        local tw = os.clock()
        while cashAlive(state, npc) and os.clock() - tw < 20 and not select(2, cashHeard(gui, state, npc)) do
            task.wait(0.1)
        end
        if cashAlive(state, npc) and gui.RepeatButton:GetAttribute("CanRepeat") then
            cashPress(gui.RepeatButton)
            task.wait(0.3)
        end
        return
    end
    local ok, reason, degraded = cashBuild(gui, state, station, npc, order)
    if not (running and farming) then
        return
    end
    if not ok then
        warn("[Legit Farm Job] cashier: " .. tostring(reason))
        cashStatus("Stuck (" .. tostring(reason) .. "), resetting the register")
        cashBad[npc] = os.clock() + 3
        cashLeave()
        task.wait(0.5)
        return
    end
    cashStatus("Waiting for the customer to finish")
    local tWait = os.clock()
    while cashAlive(state, npc) and os.clock() - tWait < 20 do
        local _, finished = cashHeard(gui, state, npc)
        if finished then
            break
        end
        task.wait(0.1)
    end
    if not cashAlive(state, npc) then
        return
    end
    -- a brief look at the finished order before the checkmark (the old 0.9-1.5 s pause here stays gone)
    cashPause(0.35, 0.6)
    cashStatus("Confirming order")
    cashPress(gui.Tabs:FindFirstChild("Confirm"))
    local t0 = os.clock()
    while running and farming and os.clock() - t0 < 10 do
        local _, g2, st2 = cashSession()
        if not (g2 and st2 == state) then
            break
        end
        task.wait(0.05)
    end
    task.wait(0.1)
    cashDone[npc] = true
    local c = gui.Checkmark.BackgroundColor3
    local accepted = math.abs(c.R - CASH_GREEN.R) < 0.05 and math.abs(c.G - CASH_GREEN.G) < 0.05 and math.abs(c.B - CASH_GREEN.B) < 0.05
    if order.tentative then
        cashLearned[order.tentative.id] = accepted and { "burger", order.tentative.name } or { "rejected" }
    end
    if accepted then
        cashStatus(degraded and "Order handed over (locked item replaced)" or "Order served")
    else
        warn("[Legit Farm Job] cashier: the server rejected the order " .. cashDescribe(order))
        cashStatus("Order rejected, next customer")
    end
    task.wait(0.2)
end
end

-- Fast Food Worker - Burger Cook
NC.cook = (function()
    local C = {}
    local COOK_ID = CASH_ID
    local ICON = {
        ["14358866788"] = "Meat Patty [Cooked]",
        ["14358886220"] = "Plantbased Patty [Cooked]",
        ["14358881866"] = "Cheese [Chopped]",
        ["14358865402"] = "Lettuce [Chopped]",
        ["14358884748"] = "Tomato [Chopped]",
        ["14358879589"] = "Onion [Chopped]",
    }
    local COOK_AGENTS = {
        { AgentRadius = 1, AgentHeight = 4, AgentCanJump = false },
        { AgentRadius = 0.5, AgentHeight = 4, AgentCanJump = false },
    }
    local outerSetStatus = setStatus
    local function setStatus(text)
        if farming then
            outerSetStatus(text)
        end
    end
    local IM, LF, DS, MouseIgnore
    local hooked, origCast, origLaunch = false, nil, nil
    local autoJumpWas
    local aim = nil
    local lastProgress, lastStep = os.clock(), 0
    local handlerCache, stopDragFn = nil, nil
    local badOrder, failCount, warnedIcon = {}, {}, {}
    local side = 1
    local ReplicatedModules = ReplicatedStorage:FindFirstChild("Modules")

    local function alive()
        return running and farming and isWorkingJob(COOK_ID)
    end

    local function progress()
        lastProgress = os.clock()
    end

    local pace = 1

    local function pause(a, b)
        local t = (a + math.random() * (b - a)) * pace
        local t0 = os.clock()
        while os.clock() - t0 < t and running and farming do
            task.wait(0.03)
        end
    end

    local function unsafe(msg)
        farming = false
        if FarmToggle then
            withUiIdentity(function()
                FarmToggle:Set(false)
            end)
        end
        outerSetStatus(msg)
    end

    local function gameSafe(fn)
        if DataService.FireServer ~= origFireServer or DataService.InvokeServer ~= origInvokeServer then
            return false
        end
        if type(fn) ~= "function" or (isexecutorclosure and isexecutorclosure(fn)) then
            return false
        end
        local env = getfenv(fn)
        local src = env and env.script
        return typeof(src) == "Instance" and src.Parent ~= nil
            and (src:IsDescendantOf(PlayerModules) or (ReplicatedModules ~= nil and src:IsDescendantOf(ReplicatedModules)))
    end

    local function init()
        if IM and LF and DS and MouseIgnore then
            return true
        end
        pcall(function()
            IM = require(PlayerModules:WaitForChild("_Input", 5):WaitForChild("InputManager", 5))
            LF = require(PlayerModules:WaitForChild("_UI", 5):WaitForChild("MinigameHandler", 5):WaitForChild("LineFollow", 5))
            DS = require(ReplicatedModules:WaitForChild("_Utilities", 5):WaitForChild("DragService", 5))
            MouseIgnore = workspace:WaitForChild("MouseIgnore", 5)
        end)
        return IM ~= nil and LF ~= nil and DS ~= nil and MouseIgnore ~= nil
    end

    local function installHooks()
        if hooked then
            return
        end
        hooked = true
        origCast = IM.CastMouseRay
        IM.CastMouseRay = function(self, mouse, ignore, dist, flag)
            local a = aim
            if a and mouse then
                if type(ignore) == "table" and table.find(ignore, a.part) then
                    return nil
                end
                return a.part, a.pos, Vector3.yAxis
            end
            return origCast(self, mouse, ignore, dist, flag)
        end
        origLaunch = LF.LaunchGame
        LF.LaunchGame = function(self, cb, ...)
            local res = table.pack(origLaunch(self, cb, ...))
            task.delay(2.2 + math.random() * 1.1, function()
                if hooked and farming and LF:IsRunning() then
                    pcall(cb)
                    pcall(function()
                        LF:Cleanup()
                    end)
                end
            end)
            return table.unpack(res, 1, res.n)
        end
    end

    local function removeHooks()
        if not hooked then
            return
        end
        hooked = false
        aim = nil
        pcall(function()
            IM.CastMouseRay = origCast
            LF.LaunchGame = origLaunch
        end)
    end

    -- Stations
    local function kitchen()
        local n = workspace:FindFirstChild("Environment")
        for _, name in ipairs({ "Locations", "City", "BloxBurgers", "Interior", "ScriptableObjects", "Kitchen" }) do
            n = n and n:FindFirstChild(name)
        end
        return n
    end

    local function lineCook()
        local ok, mod = pcall(function()
            return JobHandler:GetCurJobModule()
        end)
        local lc = ok and mod and mod.BloxBurgersLineCook
        local ws = type(lc) == "table" and lc.WorkStations
        if ws and ws.Assembly and ws.Assembly.Assembly_01 and ws.Assembly.Assembly_01.StationModel then
            return lc
        end
    end

    local function stationOf(lc, root, idx)
        local r = lc.WorkStations[root]
        return r and r[root .. "_0" .. idx]
    end

    local function aiOf(st)
        return st.StationModel:FindFirstChild("ActiveIngredients")
    end

    local function myWeld()
        local char = LocalPlayer.Character
        if not char then
            return nil
        end
        local ok, w = pcall(function()
            return JobHandler.Shared.AttachService:GetAttachWeld(char)
        end)
        return ok and w or nil
    end

    local function atStation(st)
        local w = myWeld()
        return w ~= nil and w.Part1 == st.StationPart
    end

    local function playersAround(st)
        local out = {}
        local ap = st.AttachPosition
        local lt = st.LookTarget
        local f = typeof(lt) == "Instance" and Vector3.new(lt.Position.X - ap.X, 0, lt.Position.Z - ap.Z) or Vector3.new(0, 0, 3.5)
        local fd = f.Magnitude
        f = fd > 0.1 and f.Unit or Vector3.new(0, 0, 1)
        for _, plr in ipairs(Players:GetPlayers()) do
            if plr ~= LocalPlayer and plr.Character then
                local kind
                local ok, w = pcall(function()
                    return JobHandler.Shared.AttachService:GetAttachWeld(plr.Character)
                end)
                if ok and w and w.Part1 == st.StationPart then
                    kind = "using"
                else
                    local r = plr.Character:FindFirstChild("HumanoidRootPart")
                    if r and math.abs(r.Position.Y - ap.Y) < 9 then
                        local d = Vector3.new(r.Position.X - ap.X, 0, r.Position.Z - ap.Z)
                        local along = d:Dot(f)
                        if d.Magnitude < 2.2 then
                            kind = "at"
                        elseif along > fd + 0.5 and d.Magnitude < 9 and (d - f * along).Magnitude < 6 then
                            kind = "opposite"
                        elseif d.Magnitude < 6.5 then
                            kind = "next"
                        end
                    end
                end
                if kind then
                    table.insert(out, { plr = plr, kind = kind })
                end
            end
        end
        return out
    end

    local function takenByOther(st)
        for _, e in ipairs(playersAround(st)) do
            if e.kind == "using" or e.kind == "at" then
                return true, e.plr.DisplayName
            end
        end
        return false
    end

    local function crowd(st)
        local n = 0
        for _, e in ipairs(playersAround(st)) do
            if e.kind == "next" or e.kind == "opposite" then
                n += 1
            end
        end
        return n
    end

    local function callbackFor(obj, wanted)
        local reg = getInteractRegistry()
        local entry = reg and reg[obj]
        local gens = entry and entry[1]
        if type(gens) ~= "table" then
            return nil
        end
        for _, gen in ipairs(gens) do
            if type(gen) == "function" then
                local ok, text, _, cb = pcall(gen)
                if ok and text and type(cb) == "function" and (not wanted or text == wanted) then
                    return cb, text
                end
            end
        end
    end

    local function findStopDrag()
        if stopDragFn then
            return stopDragFn
        end
        for _, f in ipairs(getgc()) do
            if type(f) == "function" and islclosure(f) and not isexecutorclosure(f) and debug.info(f, "n") == "stopDrag" then
                local s = debug.info(f, "s")
                if type(s) == "string" and s:find("DragService", 1, true) then
                    stopDragFn = f
                    return f
                end
            end
        end
    end

    local function findSpawnHandler(st)
        local ai = aiOf(st)
        local best
        local okPool, pool = pcall(function()
            return filtergc("function", { IgnoreExecutor = true })
        end)
        if not (okPool and type(pool) == "table") then
            pool = getgc()
        end
        for _, f in ipairs(pool) do
            if type(f) == "function" and islclosure(f) and not isexecutorclosure(f) then
                local s = debug.info(f, "s")
                if type(s) == "string" and s:find("BloxBurgersLineCook", 1, true) then
                    local hasAi, hasIng = false, false
                    for _, v in pairs(debug.getupvalues(f)) do
                        if v == ai then
                            hasAi = true
                        elseif typeof(v) == "Instance" and v.Name == "Ingredients" then
                            hasIng = true
                        end
                    end
                    if hasAi and hasIng then
                        best = f
                    end
                end
            end
        end
        return best
    end

    local function dragContainer()
        for _, v in pairs(debug.getupvalues(DS.Enable)) do
            if typeof(v) == "Instance" then
                return v
            end
        end
    end

    local function dropObj(st)
        local f = findStopDrag()
        if f then
            if not gameSafe(f) then
                unsafe("Stopped: unsafe cook state")
                return
            end
            pcall(f)
        elseif st and aiOf(st) then
            pcall(function()
                DS:Enable(aiOf(st))
            end)
        end
        aim = nil
    end

    local function ensureDrag(st)
        local ai = aiOf(st)
        if ai and dragContainer() ~= ai then
            pcall(function()
                DS:Enable(ai)
            end)
        end
        handlerCache = nil
    end

    local function leave(st)
        if not (running and farming) then
            return myWeld() == nil
        end
        if DS and DS:GetDraggedObject() then
            dropObj(st)
        end
        for _ = 1, 3 do
            if not myWeld() then
                return true
            end
            local _, hum = getChar()
            if not hum then
                return false
            end
            hum.Jump = true
            local t0 = os.clock()
            while os.clock() - t0 < 1.5 and myWeld() do
                task.wait(0.03)
            end
        end
        return myWeld() == nil
    end

    local lastSettle = -100
    local function settle()
        local _, hum = getChar()
        local t0 = os.clock()
        while hum and hum.FloorMaterial ~= Enum.Material.Air and os.clock() - t0 < 0.3 and running and farming do
            task.wait(0.02)
        end
        t0 = os.clock()
        while hum and hum.FloorMaterial == Enum.Material.Air and os.clock() - t0 < 1.5 and running and farming do
            task.wait(0.03)
        end
        task.wait(0.06)
        lastSettle = os.clock()
    end

    local areaBoxes, areaBoxesT
    local function areaList()
        if areaBoxes and os.clock() - areaBoxesT < 5 then
            return areaBoxes
        end
        local n = workspace:FindFirstChild("Environment")
        for _, name in ipairs({ "Locations", "City", "BloxBurgers", "Interior" }) do
            n = n and n:FindFirstChild(name)
        end
        local out = {}
        for _, name in ipairs({ "_Kitchen", "_Freezer" }) do
            local m = n and n:FindFirstChild(name)
            if m and m:IsA("Model") then
                local cf, sz = m:GetBoundingBox()
                table.insert(out, { cf = cf, sz = sz })
            end
        end
        areaBoxes, areaBoxesT = out, os.clock()
        return out
    end

    local function inKitchenArea(p, margin)
        local list = areaList()
        if #list == 0 then
            return true
        end
        for _, b in ipairs(list) do
            local rel = b.cf:PointToObjectSpace(p)
            if math.abs(rel.X) <= b.sz.X / 2 + (margin or 0) and math.abs(rel.Z) <= b.sz.Z / 2 + (margin or 0) then
                return true
            end
        end
        return false
    end

    local function pathStaysInside(path)
        local seenInside = false
        local last
        for _, w in ipairs(path:GetWaypoints()) do
            last = w
            if inKitchenArea(w.Position, 0.6) then
                seenInside = true
            elseif seenInside then
                return false -- leaves the kitchen / stock room
            end
        end
        return last ~= nil and seenInside and inKitchenArea(last.Position, 0.6)
    end

    local plainWalkTo = walkTo
    local function walkToStep(target, strict)
        local ok, why = plainWalkTo(target, strict)
        if ok or why ~= "no path" then
            return ok, why
        end
        local char0, _, root0 = getChar()
        if not root0 then
            return false, "no path"
        end
        local gp = RaycastParams.new()
        gp.FilterType = Enum.RaycastFilterType.Exclude
        gp.FilterDescendantsInstances = { char0 }
        local below = workspace:Raycast(root0.Position, Vector3.new(0, -12, 0), gp)
        local onLedge = below and root0.Position.Y - below.Position.Y > 4
        if not (onLedge or os.clock() - lastSettle < 3) then
            return false, "no path"
        end
        local lcw = lineCook()
        local near
        for _, group in pairs(lcw and lcw.WorkStations or {}) do
            for _, s in pairs(group) do
                if not near or (s.AttachPosition - root0.Position).Magnitude < (near - root0.Position).Magnitude then
                    near = s.AttachPosition
                end
            end
        end
        if near and computePath(root0.Position, near, true) then
            return false, "no path"
        end
        for _, off in ipairs({ Vector3.new(3, 0, 0), Vector3.new(-3, 0, 0), Vector3.new(0, 0, 3), Vector3.new(0, 0, -3) }) do
            local _, hum1, root1 = getChar()
            if not (hum1 and root1 and running and farming) then
                break
            end
            if inKitchenArea(root1.Position + off, 0) then
                hum1:MoveTo(root1.Position + off)
                local t1 = os.clock()
                while running and farming and os.clock() - t1 < 0.9 do
                    task.wait(0.05)
                end
                settle()
                ok, why = plainWalkTo(target, strict)
                if ok or why ~= "no path" then
                    return ok, why
                end
            end
        end
        return false, "no path"
    end

    local function walkTo(target, strict)
        walkPathOK = pathStaysInside
        local res = table.pack(pcall(walkToStep, target, strict))
        walkPathOK = nil
        if not res[1] then
            error(res[2], 0)
        end
        return res[2], res[3]
    end

    local function enter(lc, st, label)
        if myWeld() then
            if atStation(st) and lc.CurrentWorkStationName == st.RootName and lc.CurrentWorkStationIndexName == st.Name then
                return true
            end
            leave(st)
            if myWeld() then
                warn("[Legit Farm Job] cook: still attached after the jump, letting go of the station with the game's detach")
                pcall(function()
                    JobHandler.Modules.CharacterHandler:Detach()
                end)
            end
            settle()
        end
        local busyBy = select(2, takenByOther(st))
        if busyBy then
            setStatus(busyBy .. " is at " .. label .. ", doing something else")
            return false, "taken"
        end
        local n = crowd(st)
        setStatus((n > 0 and (n .. " player(s) next to " .. label .. ", walking to ") or "Walking to ") .. label)
        walkAgents = COOK_AGENTS
        local nextCheck, someone = 0, false
        walkAbort = function()
            local now = os.clock()
            if now >= nextCheck then
                nextCheck = now + 0.5
                someone = takenByOther(st)
            end
            return someone
        end
        local ok = walkTo(st.AttachPosition, true)
        walkAbort, walkAgents = nil, nil
        if someone then
            return false, "taken"
        end
        if not ok then
            local _, _, r0 = getChar()
            warn("[Legit Farm Job] cook: no path from " .. tostring(r0 and r0.Position) .. " to " .. label .. " " .. tostring(st.AttachPosition))
            return false, "no path"
        end
        local okHeld, held = pcall(function()
            return JobHandler.Shared.EquipmentService:GetEquipped(LocalPlayer)
        end)
        if okHeld and held and held.Name == "Closed Cardboard Box" then
            pcall(function()
                JobHandler.Shared.EquipmentService:UnequipItem(LocalPlayer, "Closed Cardboard Box", true)
            end)
            task.wait(0.6)
        end
        local cb
        for _ = 1, 10 do
            cb = callbackFor(st.StationModel:FindFirstChild("InteractionRoot"))
            if cb then
                break
            end
            task.wait(0.2)
        end
        if not cb then
            return false, takenByOther(st) and "taken" or "no prompt"
        end
        setStatus("Using " .. label)
        if not iceCall(cb) then
            return false, "unsafe"
        end
        local t0 = os.clock()
        while alive() and os.clock() - t0 < 8 and not atStation(st) do
            task.wait(0.1)
        end
        if not atStation(st) then
            return false, "no weld"
        end
        t0 = os.clock()
        while alive() and os.clock() - t0 < 4 and lc.CurrentWorkStationName ~= st.RootName do
            task.wait(0.1)
        end
        ensureDrag(st)
        progress()
        return true
    end

    -- Containers and ingredients
    local function container(st, name)
        local c = st.StationModel:FindFirstChild("Containers")
        local m = c and (c:FindFirstChild(name) or (c:FindFirstChild("Restockable") and c.Restockable:FindFirstChild(name)))
        if not m then
            local cc = st.StationModel:FindFirstChild("Containers_Cooked")
            m = cc and cc:FindFirstChild(name)
        end
        return m
    end

    local function amountOf(st, name)
        local m = container(st, name)
        return m and (m:GetAttribute("Amount") or 0) or 0
    end

    local function freeTarget(ai, name)
        for _, t in ipairs(ai:GetChildren()) do
            if t.Name == name and t:GetAttribute("Occupied") ~= true then
                local busy = false
                for _, c in ipairs(t:GetChildren()) do
                    if c:IsA("Part") and c:GetAttribute("ModelVariant") then
                        busy = true
                    end
                end
                if not busy then
                    return t
                end
            end
        end
    end

    -- Drag primitives
    local function spawnObj(st, model)
        local fill = model and model:FindFirstChild("Fill")
        if not fill then
            return nil
        end
        if DS:GetDraggedObject() then
            dropObj(st)
            task.wait(0.1)
        end
        handlerCache = handlerCache or findSpawnHandler(st)
        local h = handlerCache
        if not h then
            return nil
        end
        if not gameSafe(h) then
            unsafe("Stopped: unsafe cook state")
            return nil
        end
        -- a minigame still open never blocks the next ingredient for good: after 5 s it is closed with the game's own
        -- Cleanup (the wait used to have no limit)
        local tLF = os.clock()
        while LF:IsRunning() and alive() do
            if os.clock() - tLF > 5 then
                warn("[Legit Farm Job] cook: a minigame stayed open for 5 s, it is closed")
                pcall(function()
                    LF:Cleanup()
                end)
                break
            end
            task.wait(0.05)
        end
        aim = { part = fill, pos = fill.Position + Vector3.new(0, 0.2, 0) }
        task.spawn(function()
            pcall(h, { UserInputType = Enum.UserInputType.MouseButton1, KeyCode = Enum.KeyCode.Unknown })
        end)
        local obj
        local t0 = os.clock()
        while os.clock() - t0 < 4 do
            obj = DS:GetDraggedObject()
            if obj and obj.Parent then
                break
            end
            obj = nil
            task.wait(0.03)
        end
        if not obj then
            aim = nil
        else
            pause(0.12, 0.3)
        end
        return obj
    end

    local function grab(st, obj)
        if DS:GetDraggedObject() then
            dropObj(st)
            task.wait(0.1)
        end
        pcall(function()
            DS:DragObject(obj)
        end)
        local t0 = os.clock()
        while os.clock() - t0 < 1 and DS:GetDraggedObject() ~= obj do
            task.wait(0.03)
        end
        return DS:GetDraggedObject() == obj
    end

    local function snapPos(obj, tgt, onItem)
        local mdl = obj:FindFirstChildOfClass("Model")
        local half = (mdl and mdl:GetExtentsSize().Y or 0.2) * 0.5
        local base
        if onItem then
            local om = tgt:FindFirstChild("ObjectModel") or tgt:FindFirstChildOfClass("Model")
            local h = 0.4
            if om then
                local sa = om:GetAttribute("SizeAxis")
                h = sa and math.abs(sa:Dot(om:GetExtentsSize())) or om:GetExtentsSize().Y
            end
            base = tgt.Position + Vector3.new(0, h * 0.5, 0)
        else
            base = tgt.Position + Vector3.new(0, math.min(tgt.Size.X, tgt.Size.Y, tgt.Size.Z) * 0.5, 0)
        end
        return base + Vector3.new(0, half, 0)
    end

    local function moveObj(obj, tgt, onItem)
        local pos = snapPos(obj, tgt, onItem)
        local from = obj.Position
        local dur = math.clamp((pos - from).Magnitude * 0.06, 0.25, 0.7) * (0.9 + math.random() * 0.3) * pace
        local t0 = os.clock()
        while alive() and obj.Parent do
            local a = math.min((os.clock() - t0) / dur, 1)
            aim = { part = tgt, pos = from:Lerp(pos, a * a * (3 - 2 * a)) }
            if a >= 1 then
                break
            end
            RunService.Heartbeat:Wait()
        end
        aim = { part = tgt, pos = pos }
        t0 = os.clock()
        while alive() and os.clock() - t0 < 2.5 and obj.Parent and (obj.Position - pos).Magnitude > 0.07 do
            task.wait(0.03)
        end
        return obj.Parent ~= nil and (obj.Position - pos).Magnitude <= 0.2
    end

    local function dropInto(st, obj, tgt, onItem)
        local ok = moveObj(obj, tgt, onItem)
        pause(0.12, 0.28) -- a short look before letting go
        dropObj(st)
        pause(0.1, 0.25)
        return ok
    end

    local function trashObj(st, obj)
        local k = kitchen()
        local cans = k and k:FindFirstChild("TrashCans") and k.TrashCans:FindFirstChild("0" .. st.Index)
        local area = cans and cans:FindFirstChild(st.RootName == "Assembly" and "Assembly" or "Frying")
        local hover = area and area:FindFirstChild("HoverArea")
        if not (hover and obj.Parent and grab(st, obj)) then
            return false
        end
        aim = { part = hover, pos = hover.Position }
        local t0 = os.clock()
        while alive() and os.clock() - t0 < 2.5 and obj.Parent and (obj.Position - hover.Position).Magnitude > 1.2 do
            task.wait(0.03)
        end
        task.wait(0.15)
        dropObj(st)
        t0 = os.clock()
        while os.clock() - t0 < 2.5 and obj.Parent do
            task.wait(0.1)
        end
        return obj.Parent == nil
    end

    local function clean(st, keepBurgers)
        local ai = aiOf(st)
        if not ai then
            return
        end
        local junk = {}
        for _, c in ipairs(ai:GetChildren()) do
            if c:IsA("Part") and (c:GetAttribute("ModelVariant") or c:GetAttribute("FinishedBurger")) then
                table.insert(junk, c) -- loose item
            elseif c:IsA("Part") and c.Name ~= "Fryer" and c.Name ~= "Tray" then
                for _, d in ipairs(c:GetChildren()) do
                    if d:IsA("Part") and (d:GetAttribute("ModelVariant") or (d:GetAttribute("FinishedBurger") and not keepBurgers)) then
                        if not (st.RootName == "Chopping" or (st.RootName == "DeepFrying" and c.Name == "Tray")) then
                            table.insert(junk, d) -- stack / wrong burger sitting on a target
                        end
                    end
                end
            elseif c.Name == "Fryer" then
                for _, d in ipairs(c:GetChildren()) do
                    if d:IsA("Part") and d:GetAttribute("ModelVariant") == "Burned" then
                        table.insert(junk, d)
                    end
                end
            end
        end
        for _, obj in ipairs(junk) do
            if not alive() or not atStation(st) then
                return
            end
            trashObj(st, obj)
            pause(0.1, 0.25)
        end
    end

    -- Restocking
    local function equippedName()
        local ok, e = pcall(function()
            return JobHandler.Shared.EquipmentService:GetEquipped(LocalPlayer)
        end)
        return ok and e and e.Name or nil
    end

    local function groundBelow(x, y, z, ignore)
        local top = 2.1
        local lc = lineCook()
        local low
        for _, group in pairs(lc and lc.WorkStations or {}) do
            for _, s in pairs(group) do
                low = low and math.min(low, s.AttachPosition.Y) or s.AttachPosition.Y
            end
        end
        if low then
            top = low + 0.7
        end
        local params = RaycastParams.new()
        params.FilterType = Enum.RaycastFilterType.Exclude
        params.FilterDescendantsInstances = ignore
        local from = Vector3.new(x, y + 1, z)
        for i = 1, 8 do
            local hit = workspace:Raycast(from, Vector3.new(0, -30, 0), params)
            if not hit then
                return nil
            end
            if hit.Position.Y <= top then
                return hit.Position, i == 1 -- (second value: open floor, nothing above it)
            end
            from = hit.Position - Vector3.new(0, 0.1, 0)
        end
    end

    -- openOnly: only spots with nothing above them. Seen live (restocking the patties at Frying_02): the first spot tried
    -- (3 studs behind the bin) was floor under the station's "Shell" at 5.8; walking there climbed onto the grill
    local function walkNear(pos, openOnly)
        local _, _, root = getChar()
        if not root then
            return false
        end
        local char = LocalPlayer.Character
        for _, o in ipairs({ { 0, 3 }, { 0, -3 }, { 3, 0 }, { -3, 0 }, { 0, 5 }, { 5, 0 }, { -5, 0 }, { 0, -5 }, { 2, 2 }, { -2, -2 } }) do
            local floor, open = groundBelow(pos.X + o[1], pos.Y + 3, pos.Z + o[2], { char })
            if floor and inKitchenArea(floor, 0) and (open or not openOnly) then
                walkAgents = COOK_AGENTS
                local ok = walkTo(floor, true)
                walkAgents = nil
                if ok then
                    return true
                end
            end
            if not alive() then
                return false
            end
        end
        return false
    end

    local function storageDoor()
        local n = workspace:FindFirstChild("Environment")
        for _, name in ipairs({ "Locations", "City", "BloxBurgers", "Interior", "_Freezer" }) do
            n = n and n:FindFirstChild(name)
        end
        if not n then
            return nil
        end
        for _, d in ipairs(n:GetChildren()) do
            local od = d.Name:find("Door") and d:FindFirstChild("ObjectData")
            if od and od:FindFirstChild("IsOpen") then
                return d, n
            end
        end
    end

    local function openStorageDoor()
        local door, room = storageDoor()
        if not door then
            return true
        end
        local isOpen = door.ObjectData.IsOpen
        local leaf = door:FindFirstChild("ObjectModel") and door.ObjectModel:FindFirstChild("Door1")
        leaf = leaf and leaf:FindFirstChild("Door")
        local function settled()
            -- the door has stopped swinging
            if not leaf then
                task.wait(1.5)
                return
            end
            local t0, last, still = os.clock(), leaf.CFrame, 0
            while alive() and os.clock() - t0 < 3 and still < 0.35 do
                task.wait(0.05)
                if (leaf.CFrame.Position - last.Position).Magnitude < 0.01 and leaf.CFrame.LookVector:Dot(last.LookVector) > 0.9999 then
                    still += 0.05
                else
                    still = 0
                end
                last = leaf.CFrame
            end
        end
        if isOpen.Value then
            return true
        end
        local char, _, root = getChar()
        if not root then
            return false
        end
        local rcf, rsz = room:GetBoundingBox()
        local rel = rcf:PointToObjectSpace(root.Position)
        local inside = math.abs(rel.X) <= rsz.X / 2 and math.abs(rel.Z) <= rsz.Z / 2
        local dp = door:GetPivot().Position
        local toDoor = Vector3.new(dp.X - rcf.Position.X, 0, dp.Z - rcf.Position.Z)
        toDoor = toDoor.Magnitude > 0.1 and toDoor.Unit or Vector3.new(1, 0, 0)
        local side = inside and -1 or 1
        local stand
        for _, dist in ipairs({ 3.5, 4.5, 5.5 }) do
            local floor = groundBelow(dp.X + toDoor.X * dist * side, dp.Y, dp.Z + toDoor.Z * dist * side, { char, door })
            if floor then
                stand = floor
                break
            end
        end
        if not stand then
            return false
        end
        setStatus("Going to the stock room door")
        walkAgents = COOK_AGENTS
        local reached = walkTo(stand, true)
        walkAgents = nil
        if not (reached or walkNear(stand)) then
            return false
        end
        for _ = 1, 3 do
            if not alive() then
                return false
            end
            local gens = JobHandler.Shared.InteractionData:GetData(door, LocalPlayer, {})
            local cb
            for _, gen in ipairs(type(gens) == "table" and gens or {}) do
                if type(gen) == "function" then
                    local ok, text, _, f = pcall(gen)
                    if ok and text == "I_Open" and type(f) == "function" then
                        cb = f
                        break
                    end
                end
            end
            if not cb then
                if isOpen.Value then
                    break
                end
                task.wait(0.3)
            else
                if not gameSafe(cb) then
                    unsafe("Stopped: unsafe cook state")
                    return false
                end
                setStatus("Opening the stock room door")
                pause(0.2, 0.4)
                pcall(cb)
                local t0 = os.clock()
                while alive() and os.clock() - t0 < 2 and not isOpen.Value do
                    task.wait(0.1)
                end
                if isOpen.Value then
                    break
                end
            end
        end
        if not isOpen.Value then
            return false
        end
        settled()
        pause(0.2, 0.4)
        return true
    end

    local function takeBox(lc, from)
        if equippedName() == "Closed Cardboard Box" then
            return true
        end
        local k = kitchen()
        local boxes = k and k:FindFirstChild("IngredientBoxes")
        if not boxes then
            return false
        end
        if myWeld() then
            leave(from)
            settle()
        end
        local _, _, root = getChar()
        if not root then
            return false
        end
        local list = {}
        for _, b in ipairs(boxes:GetChildren()) do
            local p = b:GetPivot().Position
            if p.Y < 3 then
                table.insert(list, { b = b, d = (p - root.Position).Magnitude, p = p })
            end
        end
        table.sort(list, function(a, b)
            return a.d < b.d
        end)
        setStatus("Getting a box")
        for i = 1, math.min(#list, 4) do
            if not alive() then
                return false
            end
            if not openStorageDoor() then
                return false
            end
            if walkNear(list[i].p) then
                local cb = callbackFor(list[i].b, "I_Take")
                if cb and iceCall(cb) then
                    local t0 = os.clock()
                    while os.clock() - t0 < 3 and equippedName() ~= "Closed Cardboard Box" do
                        task.wait(0.1)
                    end
                    if equippedName() == "Closed Cardboard Box" then
                        progress()
                        return true
                    end
                end
            end
        end
        return false
    end

    -- fills every container of the station's Restockable group
    local function restock(lc, st, label)
        pace = 1
        local rs = st.StationModel.Containers:FindFirstChild("Restockable")
        if not rs then
            return false
        end
        if rs:GetAttribute("Full") then
            return true
        end
        setStatus("Restocking " .. label)
        if not takeBox(lc, st) then
            return false
        end
        local anchor = rs:FindFirstChild("Interaction")
        local pos = anchor and anchor:IsA("BasePart") and anchor.Position or rs:GetPivot().Position
        -- the patties: on the open floor in front of the bin, as far out from the counter as the cook stands at the grill
        -- (live: Frying_02 bin 199.9,307.2 -> 199.9,302.7), never beside / onto the grill
        local front = false
        if st.RootName == "Frying" then
            pcall(function()
                local ap, lt = st.AttachPosition, st.LookTarget
                local L = Vector3.new(lt.Position.X - ap.X, 0, lt.Position.Z - ap.Z).Unit
                local spot = Vector3.new(pos.X, 0, pos.Z) - L * Vector3.new(pos.X - ap.X, 0, pos.Z - ap.Z):Dot(L)
                local floor, open = groundBelow(spot.X, pos.Y + 3, spot.Z, { LocalPlayer.Character })
                if floor and open then
                    walkAgents = COOK_AGENTS
                    front = walkTo(floor, true)
                    walkAgents = nil
                end
            end)
            walkAgents = nil
        end
        if not front then
            walkNear(pos, st.RootName == "Frying") -- (the patties: only on the open floor, never onto the grill)
        end
        local cb
        for _ = 1, 6 do
            cb = callbackFor(rs, "I_Restock")
            if cb then
                break
            end
            task.wait(0.2)
        end
        if not (cb and iceCall(cb)) then
            return false
        end
        local t0 = os.clock()
        while os.clock() - t0 < 4 and equippedName() == "Closed Cardboard Box" do
            task.wait(0.1)
        end
        progress()
        pause(0.2, 0.4)
        return equippedName() ~= "Closed Cardboard Box"
    end

    -- Orders
    local function readOrders(sideIdx)
        local k = kitchen()
        local screen = k and k:FindFirstChild(sideIdx == 1 and "RightOrderScreen" or "LeftOrderScreen")
        local gui = screen and screen:FindFirstChild("SurfaceGui") and screen.SurfaceGui:FindFirstChild("Background")
        local trays = k and k:FindFirstChild("Trays") and k.Trays:FindFirstChild(sideIdx == 1 and "Right" or "Left")
        local out = {}
        if not (gui and trays) then
            return out
        end
        for _, slot in ipairs(gui:GetChildren()) do
            if slot:IsA("GuiObject") then
                local bn = slot:FindFirstChild("BurgerNumber")
                local tl = bn and bn:FindFirstChildWhichIsA("TextLabel", true)
                local num = tl and tonumber(tl.Text)
                local content = slot:FindFirstChild("Ingredients") and slot.Ingredients:FindFirstChild("Content")
                local tray
                for _, t in ipairs(trays:GetChildren()) do
                    if t:GetAttribute("OrderID") == num then
                        tray = t
                    end
                end
                if num and content and tray then
                    local frames = {}
                    for i, f in ipairs(content:GetChildren()) do
                        if f.Name == "Ingredient" then
                            table.insert(frames, { f = f, i = i })
                        end
                    end
                    table.sort(frames, function(a, b)
                        if a.f.LayoutOrder ~= b.f.LayoutOrder then
                            return a.f.LayoutOrder < b.f.LayoutOrder
                        end
                        return a.i < b.i
                    end)
                    local order = { num = num, tray = tray, ingredients = {}, total = 0 }
                    for _, e in ipairs(frames) do
                        local icon = e.f:FindFirstChild("ImageLabel")
                        local id = icon and tostring(icon.Image):match("%d+")
                        local at = e.f:FindFirstChild("Amount")
                        local atl = at and at:FindFirstChildWhichIsA("TextLabel", true)
                        local count = atl and tonumber(tostring(atl.Text):match("%d+")) or 1
                        local name = id and ICON[id]
                        if not name then
                            order.unknown = id or "?"
                        else
                            table.insert(order.ingredients, { name = name, count = count })
                            order.total += count
                        end
                    end
                    local snap = tray:FindFirstChild("SideSnapTarget")
                    local sideTarget = snap and snap.Value
                    order.sideTarget = sideTarget
                    order.sideName = sideTarget and sideTarget:GetAttribute("RequiredName")
                    local oc = tray:FindFirstChild("Order Content")
                    order.needBurger = not (oc and oc:FindFirstChild("Burger"))
                    order.needSide = order.sideName ~= nil and order.sideName ~= "" and not (oc and oc:FindFirstChild(order.sideName))
                    table.insert(out, order)
                end
            end
        end
        table.sort(out, function(a, b)
            return a.num < b.num
        end)
        return out
    end

    local function describe(order)
        local parts = {}
        for _, it in ipairs(order.ingredients) do
            table.insert(parts, it.count .. "x " .. (it.name:gsub(" %b[]", "")))
        end
        return "#" .. order.num .. " " .. table.concat(parts, ", ") .. (order.sideName and (" + " .. order.sideName) or "")
    end

    -- Station jobs
    local function ensureAt(lc, st, label)
        if atStation(st) and lc.CurrentWorkStationName == st.RootName and lc.CurrentWorkStationIndexName == st.Name then
            if dragContainer() ~= aiOf(st) then
                ensureDrag(st)
            end
            return true
        end
        return enter(lc, st, label)
    end

    local function chopVeg(lc, st, wants)
        pace = 1
        local label = "the Chopping station"
        local ok, why = ensureAt(lc, st, label)
        if not ok then
            return false, why
        end
        clean(st)
        local ai = aiOf(st)
        local board = ai:FindFirstChild("CuttingBoard")
        local left = {}
        for _, c in ipairs(ai:GetChildren()) do
            if c:IsA("Part") and c:GetAttribute("ModelVariant") == "Raw" then
                table.insert(left, c)
            elseif board and c == board then
                for _, d in ipairs(c:GetChildren()) do
                    if d:IsA("Part") and d:GetAttribute("ModelVariant") == "Raw" then
                        table.insert(left, d)
                    end
                end
            end
        end
        for _, obj in ipairs(left) do
            if not alive() then
                return false
            end
            if board and obj.Parent and grab(st, obj) then
                dropInto(st, obj, board, false)
                local t0 = os.clock()
                while alive() and os.clock() - t0 < 14 and obj.Parent do
                    task.wait(0.1)
                end
            end
        end
        for name, n in pairs(wants) do
            for _ = 1, n do
                if not alive() then
                    return false
                end
                if not ensureAt(lc, st, label) then
                    return false, "lost the station"
                end
                local m = container(st, name)
                if not (m and amountOf(st, name) > 0 and board) then
                    return false, "raw vegetables are empty"
                end
                setStatus("Chopping " .. (name:gsub(" %b[]", "")))
                local obj = spawnObj(st, m)
                if not obj then
                    return false, "could not take a vegetable"
                end
                dropInto(st, obj, board, false)
                local t0 = os.clock()
                while alive() and os.clock() - t0 < 14 and obj.Parent do
                    task.wait(0.1)
                end
                if obj.Parent then
                    return false, "the vegetable was not chopped"
                end
                progress()
                pause(0.3, 0.6)
            end
        end
        return true
    end

    local function fryerButton(id)
        local main = LocalPlayer:FindFirstChild("PlayerGui") and LocalPlayer.PlayerGui:FindFirstChild("MainGUI")
        local g = main and main:FindFirstChild("ToggleDeepFryerFrame")
        local content = g and g:FindFirstChild("Content")
        local f = content and content:FindFirstChild(tostring(id))
        return f and f:FindFirstChild("Button", true)
    end

    local function basketId(st, tgt)
        local fb = st.StationModel:FindFirstChild("FryerBaskets")
        if not fb then
            return nil
        end
        for _, b in ipairs(fb:GetChildren()) do
            local d = (b:GetPivot().Position - tgt.Position) * Vector3.new(1, 0, 1)
            if d.Magnitude < 1 then
                return b:GetAttribute("ID")
            end
        end
    end

    -- Ready side to the tray that needs it
    local function deliverSide(lc, st, order)
        local label = "the Deep-Fry station"
        local entered, enterWhy = ensureAt(lc, st, label)
        if not entered then
            return false, enterWhy
        end
        local m = container(st, order.sideName .. " [Ready]")
        if not (m and amountOf(st, order.sideName .. " [Ready]") > 0 and order.sideTarget) then
            return false
        end
        setStatus("Putting " .. order.sideName .. " on tray #" .. order.num)
        pace = 0.7
        local obj = spawnObj(st, m)
        if not obj then
            return false
        end
        if obj:GetAttribute("ModelVariant") == "Burned" then
            -- burned food is never put on a tray
            warn("[Legit Farm Job] cook: a burned " .. order.sideName .. " came out of the stock, it is thrown away")
            trashObj(st, obj)
            return false
        end
        dropInto(st, obj, order.sideTarget, false)
        local oc = order.tray:FindFirstChild("Order Content")
        local t0 = os.clock()
        while alive() and os.clock() - t0 < 5 and not (oc and oc:FindFirstChild(order.sideName)) do
            task.wait(0.1)
        end
        local done = oc and oc:FindFirstChild(order.sideName) ~= nil
        if not done and obj.Parent then
            trashObj(st, obj)
        end
        progress()
        return done
    end

    local WALK_EST, LOAD_EST = 3.5, 3.2

    local function basketOfTarget(st, tgt)
        local fb = st.StationModel:FindFirstChild("FryerBaskets")
        for _, b in ipairs(fb and fb:GetChildren() or {}) do
            local d = (b:GetPivot().Position - tgt.Position) * Vector3.new(1, 0, 1)
            if d.Magnitude < 1 then
                return b
            end
        end
    end

    local function raiseBasket(b)
        local t0 = os.clock()
        while alive() and b:GetAttribute("Busy") == true and os.clock() - t0 < 4 do
            task.wait(0.1)
        end
        if b:GetAttribute("Value") ~= true then
            return true
        end
        local btn = fryerButton(b:GetAttribute("ID"))
        if not btn then
            return false
        end
        if btn:GetAttribute("Value") ~= true then
            btn:SetAttribute("Value", true)
            task.wait(0.3)
        end
        btn:SetAttribute("Value", false)
        t0 = os.clock()
        while alive() and os.clock() - t0 < 4 do
            if b:GetAttribute("Value") ~= true and b:GetAttribute("Busy") ~= true then
                pause(0.2, 0.4)
                return true
            end
            task.wait(0.1)
        end
        return false
    end

    local function freeFryTarget(st, ai, deep)
        local lowered
        for _, t in ipairs(ai:GetChildren()) do
            if t.Name == "Fryer" and t:GetAttribute("Occupied") ~= true then
                local busy = false
                for _, c in ipairs(t:GetChildren()) do
                    if c:IsA("Part") and c:GetAttribute("ModelVariant") then
                        busy = true
                    end
                end
                if not busy then
                    if not deep then
                        return t
                    end
                    local b = basketOfTarget(st, t)
                    if b and b:GetAttribute("Busy") ~= true then
                        if b:GetAttribute("Value") ~= true then
                            return t
                        end
                        lowered = lowered or t
                    end
                end
            end
        end
        return lowered
    end

    local function newJob(st, label, deep, wants, suffix)
        local j = { st = st, label = label, deep = deep, queue = {}, active = {}, fails = 0, blocked = 0, cleaned = false,
            cook = deep and 5.6 or 5, burn = deep and 10.6 or 10 }
        for name, n in pairs(wants) do
            for _ = 1, n do
                table.insert(j.queue, name .. suffix)
            end
        end
        return j
    end

    -- the first thing of this job that is done (or gone)
    local function readyEntry(j)
        for _, e in ipairs(j.active) do
            local v = e.obj.Parent and e.obj:GetAttribute("ModelVariant")
            if not e.obj.Parent or v == "Cooked" or v == "Burned" then
                return e
            end
        end
    end

    local function slack(j)
        local s = math.huge
        for _, e in ipairs(j.active) do
            s = math.min(s, e.t0 + j.burn - os.clock())
        end
        return s
    end

    local function cookIn(j)
        local s = math.huge
        for _, e in ipairs(j.active) do
            s = math.min(s, e.t0 + j.cook - os.clock())
        end
        return s
    end

    local function adopt(j)
        for _, t in ipairs(aiOf(j.st):GetChildren()) do
            if t.Name == "Fryer" then
                for _, d in ipairs(t:GetChildren()) do
                    local v = d:IsA("Part") and d:GetAttribute("ModelVariant")
                    if v == "Cooked" or v == "Raw" then
                        local known = false
                        for _, e in ipairs(j.active) do
                            if e.obj == d then
                                known = true
                            end
                        end
                        if not known then
                            local name = d.Name .. " [Raw]"
                            table.insert(j.active, {
                                obj = d, name = name, basket = j.deep and basketOfTarget(j.st, t) or nil,
                                t0 = v == "Cooked" and os.clock() - 100 or os.clock() - 1,
                            })
                            local qi = table.find(j.queue, name)
                            if qi then
                                table.remove(j.queue, qi)
                            end
                        end
                    end
                end
            end
        end
    end

    local function loadOne(j)
        pace = 0.55
        local st = j.st
        local ai = aiOf(st)
        local name = j.queue[1]
        local m = container(st, name)
        if not m or amountOf(st, name) <= 0 then
            return false, "empty"
        end
        local tgt = freeFryTarget(st, ai, j.deep)
        if not tgt then
            return false, "full"
        end
        local basket
        if j.deep then
            basket = basketOfTarget(st, tgt)
            if not (basket and raiseBasket(basket)) then
                return false, "basket"
            end
        end
        setStatus((j.deep and "Deep-frying " or "Frying ") .. (name:gsub(" %b[]", "")))
        local obj = spawnObj(st, m)
        if not obj then
            return false, "spawn"
        end
        local placed = false
        for _ = 1, 3 do
            dropInto(st, obj, tgt, false)
            local t0 = os.clock()
            while alive() and os.clock() - t0 < 1.5 and obj.Parent do
                if obj.Parent == tgt then
                    placed = true
                    break
                end
                task.wait(0.05)
            end
            if placed or not obj.Parent or not alive() then
                break
            end
            if not grab(st, obj) then
                break
            end
        end
        if not placed then
            if obj.Parent and alive() then
                trashObj(st, obj)
            end
            return false, "not placed"
        end
        table.remove(j.queue, 1)
        local e = { obj = obj, t0 = os.clock(), name = name }
        if j.deep then
            pause(0.3, 0.55)
            local btn = fryerButton(basket:GetAttribute("ID"))
            if not btn then
                table.insert(j.active, e)
                return false, "no fryer switch"
            end
            for try = 1, 2 do
                btn:SetAttribute("Value", true)
                local t0 = os.clock()
                while alive() and os.clock() - t0 < 2.5 and basket:GetAttribute("Value") ~= true do
                    task.wait(0.05)
                end
                if basket:GetAttribute("Value") == true or not alive() then
                    break
                end
                btn:SetAttribute("Value", false) -- the basket did not go down: switch again
                task.wait(0.4)
            end
            e.basket = basket
            e.t0 = os.clock()
        end
        table.insert(j.active, e)
        progress()
        return true
    end

    local function serve(j)
        pace = 0.55
        local st = j.st
        local ai = aiOf(st)
        for i = #j.active, 1, -1 do
            local e = j.active[i]
            local obj = e.obj
            local v = obj.Parent and obj:GetAttribute("ModelVariant")
            if not obj.Parent then
                table.remove(j.active, i)
            elseif v == "Cooked" then
                setStatus(j.deep and "Raising the basket" or "Taking out the cooked patty")
                pause(0.1, 0.3)
                if j.deep then
                    local btn = e.basket and fryerButton(e.basket:GetAttribute("ID"))
                    if e.basket and e.basket:GetAttribute("Value") ~= true then
                        trashObj(st, obj)
                    elseif btn then
                        btn:SetAttribute("Value", false)
                    end
                    local t0 = os.clock()
                    while os.clock() - t0 < 3 and obj.Parent do
                        task.wait(0.1)
                    end
                else
                    if grab(st, obj) then
                        if obj:GetAttribute("ModelVariant") == "Burned" then
                            trashObj(st, obj)
                            if e.name then
                                table.insert(j.queue, e.name)
                            end
                        else
                            local cont = ai:FindFirstChild("Containers_Cooked")
                            if cont then
                                dropInto(st, obj, cont, false)
                            else
                                dropObj(st)
                            end
                        end
                    end
                    local t0 = os.clock()
                    while os.clock() - t0 < 2 and obj.Parent do
                        task.wait(0.05)
                    end
                end
                table.remove(j.active, i)
                progress()
            elseif v == "Burned" then
                setStatus("Throwing away a burned " .. obj.Name)
                if j.deep then
                    local btn = e.basket and fryerButton(e.basket:GetAttribute("ID"))
                    if btn and e.basket:GetAttribute("Value") == true then
                        btn:SetAttribute("Value", false)
                    end
                    task.wait(1.2)
                    if obj.Parent then
                        trashObj(st, obj)
                    end
                else
                    trashObj(st, obj)
                end
                if e.name then
                    table.insert(j.queue, e.name)
                end
                table.remove(j.active, i)
            end
        end
    end

    local function canLoad(j)
        return #j.queue > 0 and #j.active < 4 and freeFryTarget(j.st, aiOf(j.st), j.deep) ~= nil
    end

    local function runJob(lc, j)
        local deadline = os.clock() + 120
        while alive() and os.clock() < deadline do
            if #j.queue == 0 and #j.active == 0 then
                return true
            end
            local here, hereWhy = ensureAt(lc, j.st, j.label)
            if not here then
                j.lost = (j.lost or 0) + 1
                if hereWhy == "taken" or j.lost >= 4 then
                    return false, hereWhy == "taken" and "taken" or "lost the station"
                end
                task.wait(0.4)
                continue
            end
            if j.deep then
                for _, e in ipairs(j.active) do
                    if e.basket and e.obj.Parent and e.obj:GetAttribute("ModelVariant") == "Raw"
                        and e.basket:GetAttribute("Value") ~= true and e.basket:GetAttribute("Busy") ~= true then
                        local btn = fryerButton(e.basket:GetAttribute("ID"))
                        if btn then
                            pace = 0.55
                            setStatus("Starting the deep fryer")
                            pause(0.2, 0.4)
                            btn:SetAttribute("Value", true)
                            e.t0 = os.clock()
                        end
                    end
                end
            end
            if readyEntry(j) then
                serve(j)
            elseif canLoad(j) then
                local ok, why = loadOne(j)
                if not ok then
                    if why == "empty" then
                        return false, j.deep and "raw sides are empty" or "raw patties are empty"
                    end
                    j.fails += 1
                    if why == "full" then
                        clean(j.st)
                    end
                    if j.fails >= 3 and #j.active == 0 then
                        return false, "could not load the fryer"
                    end
                    task.wait(0.2)
                else
                    j.fails = 0
                end
            else
                if #j.queue > 0 and #j.active == 0 then
                    j.fails += 1
                    clean(j.st)
                    if j.fails >= 3 then
                        return false, "could not load the fryer"
                    end
                end
                task.wait(0.1) -- cooking: waiting for it to be done
            end
        end
        return false, "the frying did not finish"
    end

    local function fryAll(lc, plans)
        local jobs = {}
        for i, pl in ipairs(plans) do
            local other = i > 1 and " on the other side" or ""
            table.insert(jobs, newJob(pl.S.fry, "the Frying station" .. other, false, pl.fryWants, ""))
            table.insert(jobs, newJob(pl.S.deep, "the Deep-Fry station" .. other, true, pl.fryRawWants, " [Raw]"))
        end
        local deadline = os.clock() + 300
        local idleSince
        while alive() and os.clock() < deadline do
            local now = os.clock()
            local nextJob, remaining
            for _, j in ipairs(jobs) do
                if #j.queue > 0 or #j.active > 0 then
                    remaining = true
                    if j.blocked <= now and not nextJob then
                        nextJob = j
                    end
                end
            end
            if not remaining then
                break
            end
            if not nextJob then
                idleSince = idleSince or now
                if now - idleSince > 12 then
                    return false, "taken"
                end
                task.wait(0.3)
            else
                idleSince = nil
                local ok, why = ensureAt(lc, nextJob.st, nextJob.label)
                if not ok then
                    nextJob.blocked = os.clock() + (why == "taken" and 4 or 2)
                    if why ~= "taken" then
                        nextJob.fails += 1
                        warn("[Legit Farm Job] cook: could not use " .. nextJob.label .. " (" .. tostring(why) .. ")")
                        if nextJob.fails >= 3 then
                            return false, "could not load the fryer"
                        end
                    end
                    task.wait(0.2)
                else
                    if not nextJob.cleaned then
                        nextJob.cleaned = true
                        clean(nextJob.st)
                        adopt(nextJob)
                    end
                    local rok, rwhy = runJob(lc, nextJob)
                    if not rok then
                        return false, rwhy
                    end
                end
            end
        end
        for _, j in ipairs(jobs) do
            if #j.queue > 0 or #j.active > 0 then
                return false, "the frying did not finish"
            end
        end
        return true
    end

    local function popupGreen(st)
        local ai = aiOf(st)
        local pop = ai and ai:FindFirstChild("FinishedTarget") and ai.FinishedTarget:FindFirstChildOfClass("BillboardGui")
        local fr = pop and pop:FindFirstChild("Frame") and pop.Frame:FindFirstChild("Frame")
        return fr ~= nil and fr.BackgroundColor3 == Color3.new(0, 1, 0)
    end

    local function addToStack(st, name, stackRoot)
        local ai = aiOf(st)
        local newStack = name == "Bottom Bun [Raw]"
        local m = container(st, name)
        if not (m and amountOf(st, name) > 0) then
            return false, name .. " is empty"
        end
        local obj = spawnObj(st, m)
        if not obj then
            return false, "could not take " .. name
        end
        local function findTop()
            local top, best = nil, 0
            for _, t in ipairs(ai:GetChildren()) do
                if t.Name == "Target" and (not stackRoot or t == stackRoot) then
                    local cur, depth = t, 0
                    while true do
                        local nxt
                        for _, c in ipairs(cur:GetChildren()) do
                            if c:IsA("Part") and c:GetAttribute("Stackable") and c:GetAttribute("ModelVariant") then
                                nxt = c
                                break
                            end
                        end
                        if not nxt then
                            break
                        end
                        cur = nxt
                        depth += 1
                    end
                    if depth > best then
                        top, best = cur, depth
                    end
                end
            end
            return top
        end
        local function rootOf(p) -- the Target a stacked part belongs to
            local c = p
            while c and c.Parent ~= ai do
                c = c.Parent
            end
            return c
        end
        for attempt = 1, 3 do
            local top = (not newStack) and findTop() or nil
            local expectedRoot
            if top then
                expectedRoot = rootOf(top)
                dropInto(st, obj, top, true)
            else
                local tgt = freeTarget(ai, "Target")
                if not tgt then
                    dropObj(st)
                    return false, "no free place on the board"
                end
                expectedRoot = tgt
                dropInto(st, obj, tgt, false)
            end
            local t0 = os.clock()
            while alive() and os.clock() - t0 < 2.5 and obj.Parent and not (obj.Parent ~= ai and obj.Parent ~= MouseIgnore and obj:GetAttribute("Snapped")) do
                task.wait(0.05)
            end
            if not obj.Parent then
                return true, nil, stackRoot
            end
            if obj:GetAttribute("Snapped") then
                if rootOf(obj) == expectedRoot then
                    return true, nil, expectedRoot
                end
                warn("[Legit Farm Job] cook: " .. name .. " snapped onto another stack, it is put down again")
            end
            if not (alive() and grab(st, obj)) then
                break
            end
            pause(0.2, 0.4)
        end
        if obj.Parent and not obj:GetAttribute("Snapped") then
            return false, name .. " did not stay on the board"
        end
        if obj.Parent then
            return false, name .. " ended up on another stack"
        end
        return true
    end

    -- Burgers
    local function burgerBurned(b)
        for _, d in ipairs(b:GetDescendants()) do
            if d:IsA("Part") and d:GetAttribute("Stackable") and d:GetAttribute("ModelVariant") == "Burned" then
                return true
            end
        end
        return false
    end

    local function leftoverBurgers(ai)
        local out = {}
        for _, c in ipairs(ai:GetChildren()) do
            if c:IsA("Part") and c:GetAttribute("FinishedBurger") then
                table.insert(out, c)
            elseif c:IsA("Part") and c.Name ~= "Fryer" and c.Name ~= "Tray" then
                for _, d in ipairs(c:GetChildren()) do
                    if d:IsA("Part") and d:GetAttribute("FinishedBurger") then
                        table.insert(out, d)
                    end
                end
            end
        end
        return out
    end

    local function popupColor(st)
        local ai = aiOf(st)
        local pop = ai and ai:FindFirstChild("FinishedTarget") and ai.FinishedTarget:FindFirstChildOfClass("BillboardGui")
        local fr = pop and pop:FindFirstChild("Frame") and pop.Frame:FindFirstChild("Frame")
        if not fr then
            return nil
        end
        if fr.BackgroundColor3 == Color3.new(0, 1, 0) then
            return "green"
        elseif fr.BackgroundColor3 == Color3.new(1, 0, 0) then
            return "red"
        end
    end

    -- finished burger -> when it appeared on the board
    local burgerSeen = setmetatable({}, { __mode = "k" })

    local function deliver(st, burger)
        local ai = aiOf(st)
        local ft = ai:FindFirstChild("FinishedTarget")
        if not (ft and burger.Parent) then
            return false, "could not pick up the burger"
        end
        -- seen live (the burger left on the board): a burger picked up 0.6 s after it appeared had its drag ended by the game
        -- at once and fell loose on the board, not on the hand-in spot, and the popup still green from the burger before
        -- counted it as handed in. So: picked up 0.8 s after it appeared at the earliest (the old pace that worked; the
        -- game keeps it Anchored until it is picked up, so that is no signal), and handed in only when it really sits on the
        -- hand-in spot (FinishedTarget) - else picked up again
        local function onSpot()
            return burger.Parent == ft or (burger.Parent ~= nil and burger.Parent.Name == "Order Content")
        end
        -- which column of the board's 4 spots it was built on, seen from the character (live: Assembly_02 T1 / T2 left,
        -- T3 / T4 right; the hand-in cubby is on the left column's side). Built on a left spot it goes straight into the
        -- cubby; built on a right spot it first goes in front of the opening (the little hop), as before
        local leftSide = false
        pcall(function()
            local root = burger
            while root.Parent and root.Parent ~= ai do
                root = root.Parent
            end
            local ap, lt = st.AttachPosition, st.LookTarget
            local f = typeof(lt) == "Instance" and Vector3.new(lt.Position.X - ap.X, 0, lt.Position.Z - ap.Z) or Vector3.zero
            if root.Parent == ai and root.Name == "Target" and f.Magnitude > 0.1 then
                local right = f.Unit:Cross(Vector3.yAxis)
                local sum, n = 0, 0
                for _, t in ipairs(ai:GetChildren()) do
                    if t.Name == "Target" and t:IsA("BasePart") then
                        sum += (t.Position - ap):Dot(right)
                        n += 1
                    end
                end
                leftSide = n > 0 and (root.Position - ap):Dot(right) < sum / n
            end
        end)
        for try = 1, 3 do
            local seen = burgerSeen[burger]
            while seen and alive() and burger.Parent and not onSpot() and os.clock() - seen < 0.8 do
                task.wait(0.03)
            end
            if not (burger.Parent and grab(st, burger)) then
                return false, "could not pick up the burger"
            end
            -- the hand-in spot sits in a cubby walled on 3 sides ("Sepreating Wall"), open toward its own board (where the
            -- character stands): live, a straight diagonal line caught the burger on the end of the wall between the two
            -- cubbies, it hung there until the move timed out and was dropped next to the spot. So it is first brought in
            -- front of the opening, then straight in
            local rel = ft.CFrame:VectorToObjectSpace(st.AttachPosition - ft.Position)
            local out = math.abs(rel.X) > math.abs(rel.Z) and ft.CFrame.RightVector * math.sign(rel.X)
                or ft.CFrame.LookVector * -math.sign(rel.Z)
            local entry = snapPos(burger, ft, false) + out * 1.4
            local from = burger.Position
            local te = os.clock()
            while not (leftSide and try == 1) and alive() and burger.Parent and os.clock() - te < 0.6 do
                local a = math.min((os.clock() - te) / 0.2, 1)
                aim = { part = ft, pos = from:Lerp(entry, a * a * (3 - 2 * a)) }
                if a >= 1 and (burger.Position - entry).Magnitude < 0.35 then
                    break
                end
                RunService.Heartbeat:Wait()
            end
            moveObj(burger, ft, false)
            pause(0.12, 0.28)
            local held = DS:GetDraggedObject() == burger
            dropObj(st)
            pause(0.1, 0.25)
            local ts = os.clock()
            while held and alive() and burger.Parent and not onSpot() and os.clock() - ts < 1.5 do
                task.wait(0.05)
            end
            if onSpot() or not burger.Parent or not alive() then
                break
            end
            warn("[Legit Farm Job] cook: the burger fell next to the hand-in spot (try " .. try .. "), it is picked up again")
        end
        if burger.Parent and not onSpot() then
            return false, "the burger is not on the hand-in spot"
        end
        local t0 = os.clock()
        local sawGreen, sawRed = false, false
        while alive() and os.clock() - t0 < 15 do
            if not burger.Parent or burger.Parent.Name == "Order Content" then
                progress()
                return true
            end
            local c = burger.Parent == ft and popupColor(st)
            if c == "green" then
                sawGreen = true
            elseif c == "red" then
                sawRed = true
            end
            if sawRed and burger.Parent == ft and os.clock() - t0 > 0.6 then
                return false, "wrong"
            end
            if not sawGreen and not sawRed and os.clock() - t0 > 4 then
                break
            end
            task.wait(0.05)
        end
        if sawGreen then
            progress()
            return true
        end
        return false, sawRed and "wrong" or "unknown"
    end

    -- the ticket of this order as it is now (nil when it is gone)
    local function openOrder(st, order)
        for _, o in ipairs(readOrders(st.Index)) do
            if o.num == order.num then
                return o
            end
        end
    end

    local rejected = setmetatable({}, { __mode = "k" })

    local function handIn(st, burger, why)
        local last
        for attempt = 1, 3 do
            local ok, res = deliver(st, burger)
            if ok then
                return true
            end
            last = res
            if res ~= "wrong" and res ~= "unknown" then
                return false, res
            end
            if res == "wrong" and attempt >= 2 then
                break
            end
            pause(0.5, 0.9)
        end
        if last == "unknown" then
            return false, "unknown"
        end
        local stack = {}
        for _, d in ipairs(burger:GetDescendants()) do
            if d:IsA("Part") and d:GetAttribute("Stackable") then
                table.insert(stack, { y = d.Position.Y, name = d.Name, variant = d:GetAttribute("ModelVariant") })
            end
        end
        table.sort(stack, function(x, y)
            return x.y < y.y
        end)
        local names, burned = {}, false
        for _, p in ipairs(stack) do
            table.insert(names, p.name .. "[" .. tostring(p.variant) .. "]")
            if p.variant == "Burned" then
                burned = true
            end
        end
        local open, matches = {}, false
        for _, o in ipairs(readOrders(st.Index)) do
            if o.needBurger then
                local it = {}
                local want = { "Bottom Bun" }
                for _, ing in ipairs(o.ingredients) do
                    table.insert(it, ing.count .. "x" .. (ing.name:gsub(" %b[]", "")))
                    for _ = 1, ing.count do
                        table.insert(want, (ing.name:gsub(" %b[]", "")))
                    end
                end
                table.insert(want, "Top Bun")
                table.insert(open, "#" .. o.num .. " " .. table.concat(it, "+"))
                if #want == #stack then
                    local same = true
                    for i, w in ipairs(want) do
                        if stack[i].name ~= w then
                            same = false
                        end
                    end
                    matches = matches or same
                end
            end
        end
        rejected[burger] = (rejected[burger] or 0) + 1
        local keep = matches and not burned and rejected[burger] < 3
        warn("[Legit Farm Job] cook: the game turned down the burger (" .. tostring(why) .. "): " .. table.concat(names, ", ")
            .. " | open orders: " .. table.concat(open, " ; ") .. " | made like an open order: " .. tostring(matches)
            .. " | turned down " .. rejected[burger] .. "x | " .. (keep and "it is kept" or "it is thrown away"))
        if keep then
            return false, "rejected"
        end
        if burger.Parent then
            trashObj(st, burger)
        end
        return false, "wrong"
    end

    local function assemble(lc, st, order)
        pace = 0.8
        local label = "the Assembly station"
        local entered, enterWhy = ensureAt(lc, st, label)
        if not entered then
            return false, enterWhy or "no station"
        end
        local cur = openOrder(st, order)
        if not cur or not cur.needBurger then
            return true
        end
        order = cur
        clean(st, true)
        local ai = aiOf(st)
        for _, b in ipairs(leftoverBurgers(ai)) do
            if not alive() then
                return false, "stopped"
            end
            if burgerBurned(b) then
                setStatus("Throwing away a burned leftover burger")
                trashObj(st, b)
            else
                setStatus("Checking a leftover burger")
                if handIn(st, b, "leftover") then
                    pause(0.3, 0.6)
                end
            end
        end
        cur = openOrder(st, order)
        if not cur or not cur.needBurger then
            progress()
            return true
        end
        order = cur
        local before = {}
        for _, b in ipairs(leftoverBurgers(ai)) do
            before[b] = true
        end
        local list = { "Bottom Bun [Raw]" }
        for _, it in ipairs(order.ingredients) do
            for _ = 1, it.count do
                table.insert(list, it.name)
            end
        end
        table.insert(list, "Top Bun [Raw]")
        for _ = 1, 3 do
            local stale = false
            for _, t in ipairs(ai:GetChildren()) do
                if t.Name == "Target" then
                    for _, c in ipairs(t:GetChildren()) do
                        if c:IsA("Part") and c:GetAttribute("ModelVariant") then
                            stale = true
                        end
                    end
                end
            end
            if not stale or not alive() then
                break
            end
            clean(st, true)
            pause(0.3, 0.5)
        end
        local stackRoot
        setStatus("Assembling " .. describe(order))
        for i, name in ipairs(list) do
            if not alive() then
                return false, "stopped"
            end
            if i > 1 and not openOrder(st, order) then
                clean(st, true)
                return true
            end
            if not ensureAt(lc, st, label) then
                return false, "lost the station"
            end
            local ok, why, r = addToStack(st, name, stackRoot)
            if not ok then
                clean(st, true)
                return false, why
            end
            stackRoot = stackRoot or r
            pause(0.3, 0.6)
        end
        local burger
        local t0 = os.clock()
        while alive() and os.clock() - t0 < 12 and not burger do
            for _, b in ipairs(leftoverBurgers(ai)) do
                if not before[b] then
                    burger = b
                    burgerSeen[b] = burgerSeen[b] or os.clock()
                    break
                end
            end
            task.wait(0.1)
        end
        if not burger then
            if alive() then
                local seen = {}
                for _, t in ipairs(ai:GetChildren()) do
                    if t.Name == "Target" then
                        local chain = {}
                        local c2 = t
                        for _ = 1, 14 do
                            local nx
                            for _, c in ipairs(c2:GetChildren()) do
                                if c:IsA("Part") and c:GetAttribute("Stackable") then
                                    nx = c
                                    break
                                end
                            end
                            if not nx then
                                break
                            end
                            table.insert(chain, nx.Name .. "[" .. tostring(nx:GetAttribute("ModelVariant")) .. "]")
                            c2 = nx
                        end
                        if #chain > 0 then
                            table.insert(seen, table.concat(chain, ">"))
                        end
                    end
                end
                warn("[Legit Farm Job] cook: no burger appeared for " .. describe(order) .. " after 12 s; the stack was: " .. table.concat(seen, " | "))
                clean(st, true)
            end
            return false, "the burger was not finished"
        end
        pause(0.1, 0.25)
        local made, madeNames = 0, {}
        for _, d in ipairs(burger:GetDescendants()) do
            if d:IsA("Part") and d:GetAttribute("ModelVariant") then
                made += 1
                table.insert(madeNames, d.Name .. "[" .. tostring(d:GetAttribute("ModelVariant")) .. "]")
            end
        end
        if made ~= #list then
            warn("[Legit Farm Job] cook: the burger for " .. describe(order) .. " holds " .. made .. " of " .. #list .. " ingredients ("
                .. table.concat(madeNames, ", ") .. "), it is thrown away")
            trashObj(st, burger)
            return false, "the burger was incomplete"
        end
        if burgerBurned(burger) then
            warn("[Legit Farm Job] cook: a burned patty ended up in the burger for " .. describe(order) .. ", it is thrown away")
            trashObj(st, burger)
            return false, "the burger had a burned patty"
        end
        local ok, why = handIn(st, burger, describe(order))
        if ok then
            progress()
            return true
        end
        if why == "wrong" or why == "rejected" then
            return false, "the burger was not accepted"
        end
        return false, "the burger was not taken (" .. tostring(why) .. ")"
    end

    -- One pass over the tickets of one side
    local function failed(order)
        failCount[order.num] = (failCount[order.num] or 0) + 1
        if failCount[order.num] >= 3 then
            badOrder[order.num] = os.clock() + 90
            failCount[order.num] = 0
        end
    end

    local function takenSides(lc)
        local n = {}
        for idx = 1, 2 do
            n[idx] = 0
            for _, root in ipairs({ "Assembly", "Chopping", "Frying", "DeepFrying" }) do
                local st = stationOf(lc, root, idx)
                if st and takenByOther(st) then
                    n[idx] += 1
                end
            end
        end
        return n
    end

    local function problem(what, why)
        if why == "taken" then
            setStatus("Another player is using the " .. what .. " station, waiting")
            progress()
        else
            setStatus(what .. " problem (" .. tostring(why) .. ")")
        end
    end

    local function needRestock(st, wants)
        for name, n in pairs(wants) do
            if amountOf(st, name) < n then
                return true
            end
        end
        return false
    end

    -- full batches, the order the player's own account (munchlaxlv100) worked in, watched live for 12 minutes
    local PATTY_FULL, CHOP_FULL, SIDE_FULL = 5, 10, 3
    local function fillFry(S, wants)
        for _, name in ipairs({ "Meat Patty [Cooked]", "Plantbased Patty [Cooked]" }) do
            local need = PATTY_FULL - amountOf(S.asm, name)
            local raw = (name:gsub("%[Cooked%]", "[Raw]"))
            if need > (wants[raw] or 0) then
                wants[raw] = need
            end
        end
    end

    local function fillChop(S, wants)
        for _, name in ipairs({ "Lettuce [Chopped]", "Tomato [Chopped]", "Onion [Chopped]" }) do
            local raws = math.floor((CHOP_FULL - amountOf(S.asm, name)) / 2)
            local raw = (name:gsub("%[Chopped%]", "[Raw]"))
            if raws > (wants[raw] or 0) then
                wants[raw] = raws
            end
        end
    end

    local function sideStations(lc, idx)
        local S = {
            asm = stationOf(lc, "Assembly", idx),
            chop = stationOf(lc, "Chopping", idx),
            fry = stationOf(lc, "Frying", idx),
            deep = stationOf(lc, "DeepFrying", idx),
        }
        if S.asm and S.chop and S.fry and S.deep then
            return S
        end
    end

    local function planSide(lc, idx)
        local S = {
            asm = stationOf(lc, "Assembly", idx),
            chop = stationOf(lc, "Chopping", idx),
            fry = stationOf(lc, "Frying", idx),
            deep = stationOf(lc, "DeepFrying", idx),
        }
        if not (S.asm and S.chop and S.fry and S.deep) then
            return nil
        end
        local now = os.clock()
        local pending = {}
        for _, o in ipairs(readOrders(idx)) do
            if o.unknown then
                if not warnedIcon[o.unknown .. ":" .. o.num] then
                    warnedIcon[o.unknown .. ":" .. o.num] = true
                    warn("[Legit Farm Job] cook: order #" .. o.num .. " has an ingredient icon the script does not know (" .. tostring(o.unknown) .. ")")
                end
                setStatus("Unknown ingredient on order #" .. o.num .. ", see console")
            elseif (o.needBurger or o.needSide) and not (badOrder[o.num] and badOrder[o.num] > now) then
                table.insert(pending, o)
            end
        end
        if #pending == 0 then
            return nil
        end
        local batch, tot = {}, {}
        for _, o in ipairs(pending) do
            local add, ok = {}, true
            if o.needBurger then
                for _, it in ipairs(o.ingredients) do
                    add[it.name] = (add[it.name] or 0) + it.count
                end
                add["Bottom Bun [Raw]"] = 1
                add["Top Bun [Raw]"] = 1
                for name, n in pairs(add) do
                    if (tot[name] or 0) + n > 10 then
                        ok = false
                    end
                end
            end
            if ok or #batch == 0 then
                for name, n in pairs(add) do
                    tot[name] = (tot[name] or 0) + n
                end
                table.insert(batch, o)
            end
            if #batch >= 4 then
                break
            end
        end
        local pl = { idx = idx, S = S, batch = batch, oldest = pending[1].num, fryWants = {}, chopWants = {}, fryRawWants = {}, rawWants = {} }
        for name, n in pairs(tot) do
            if name:find("Patty") then
                local deficit = n - amountOf(S.asm, name)
                if deficit > 0 then
                    pl.fryWants[(name:gsub("%[Cooked%]", "[Raw]"))] = deficit
                end
            elseif name:find("%[Chopped%]") and not name:find("Cheese") then
                local have = amountOf(S.asm, name)
                local deficit = n - have
                if deficit > 0 then
                    local raws = math.min(math.ceil(deficit / 2), math.max(1, math.floor((10 - have) / 2)))
                    pl.chopWants[(name:gsub("%[Chopped%]", "[Raw]"))] = raws
                end
            end
        end
        local sideNeed = {}
        for _, o in ipairs(batch) do
            if o.needSide then
                sideNeed[o.sideName] = (sideNeed[o.sideName] or 0) + 1
            end
        end
        for name, n in pairs(sideNeed) do
            local deficit = n - amountOf(S.deep, name .. " [Ready]")
            if deficit > 0 then
                -- a full fryer batch (the player's own account put 3 of a side in at once)
                local want = math.max(deficit, SIDE_FULL - amountOf(S.deep, name .. " [Ready]"))
                pl.fryRawWants[name] = want
                pl.rawWants[name .. " [Raw]"] = want
            end
        end
        -- full batches when it is cooking / chopping anyway (the player's own account: 5 meat + 5 plant-based patties on
        -- the grill, every vegetable chopped up to ~10), instead of only what these orders still need
        if next(pl.fryWants) then
            fillFry(S, pl.fryWants)
        end
        if next(pl.chopWants) then
            fillChop(S, pl.chopWants)
        end
        pl.asmWants = {}
        for name, n in pairs(tot) do
            if name:find("Bun") or name:find("Cheese") then
                pl.asmWants[name] = n
            end
        end
        return pl
    end

    local function finishSide(lc, pl)
        local S = pl.S
        local fresh = {}
        for _, o in ipairs(readOrders(pl.idx)) do
            fresh[o.num] = o
        end
        local batch, tot = {}, {}
        for _, o in ipairs(pl.batch) do
            local f = fresh[o.num]
            if f and not f.unknown and (f.needBurger or f.needSide) then
                table.insert(batch, f)
                if f.needBurger then
                    for _, it in ipairs(f.ingredients) do
                        tot[it.name] = (tot[it.name] or 0) + it.count
                    end
                    tot["Bottom Bun [Raw]"] = (tot["Bottom Bun [Raw]"] or 0) + 1
                    tot["Top Bun [Raw]"] = (tot["Top Bun [Raw]"] or 0) + 1
                end
            end
        end
        if #batch == 0 then
            return true
        end
        if not alive() then
            return false
        end
        -- 2. vegetables
        if next(pl.chopWants) then
            if needRestock(S.chop, pl.chopWants) and not restock(lc, S.chop, "the Chopping station") then
                return false
            end
            if not alive() then
                return false
            end
            local ok, why = chopVeg(lc, S.chop, pl.chopWants)
            if not ok then
                problem("Chopping", why)
                task.wait(1)
                return false
            end
        end
        if not alive() then
            return false
        end
        -- 3. buns / cheese, then every burger of this side (the player's own account: all burgers first, then the sides)
        local asmWants = {}
        for name, n in pairs(tot) do
            if name:find("Bun") or name:find("Cheese") then
                asmWants[name] = n
            end
        end
        if needRestock(S.asm, asmWants) and not restock(lc, S.asm, "the Assembly station") then
            return false
        end
        for _, o in ipairs(batch) do
            if not alive() then
                return false
            end
            if o.needBurger then
                local ok, why = assemble(lc, S.asm, o)
                if ok then
                    failCount[o.num] = 0
                elseif why == "taken" then
                    problem("Assembly", why)
                    task.wait(1)
                    return false
                else
                    setStatus("Burger problem (" .. tostring(why) .. ")")
                    failed(o)
                    task.wait(0.5)
                end
            end
        end
        if not alive() then
            return false
        end
        -- 4. then the sides that are ready go on the trays
        for _, o in ipairs(batch) do
            if not alive() then
                return false
            end
            if o.needSide then
                local ok, why = deliverSide(lc, S.deep, o)
                if not ok then
                    if why == "taken" then
                        problem("Deep-Fry", why)
                        task.wait(1)
                        return false
                    end
                    failed(o)
                end
            end
        end
        for _, e in ipairs({ { S.fry, "the Frying station", 1 }, { S.chop, "the Chopping station", 1 }, { S.deep, "the Deep-Fry station", 1 }, { S.asm, "the Assembly station", 2 } }) do
            if not alive() then
                return false
            end
            local rs = e[1].StationModel.Containers:FindFirstChild("Restockable")
            local low = false
            if rs and not rs:GetAttribute("Full") then
                for _, m in ipairs(rs:GetChildren()) do
                    local a = m:GetAttribute("Amount")
                    if a and a <= e[3] then
                        low = true
                    end
                end
            end
            if low then
                restock(lc, e[1], e[2])
            end
        end
        return true
    end

    local function cycle(lc)
        local taken = takenSides(lc)
        setStatus("Reading the orders")
        local plans = {}
        for idx = 1, 2 do
            plans[idx] = planSide(lc, idx)
        end
        if not (plans[1] or plans[2]) then
            if not stationOf(lc, "Assembly", 1) or not stationOf(lc, "Assembly", 2) then
                setStatus("Waiting for the kitchen")
                task.wait(1)
                return
            end
            setStatus("Waiting for orders")
            progress()
            task.wait(1)
            return
        end
        local order = {}
        for idx = 1, 2 do
            if plans[idx] then
                table.insert(order, idx)
            end
        end
        table.sort(order, function(a, b)
            if taken[a] ~= taken[b] then
                return taken[a] < taken[b]
            end
            local na, nb = plans[a].oldest, plans[b].oldest
            if a == side then
                na -= 3
            elseif b == side then
                nb -= 3
            end
            return na < nb
        end)
        if side ~= order[1] then
            setStatus("Switching to the other side")
        end
        side = order[1]
        local active = { plans[order[1]] }
        if order[2] and taken[order[1]] == 0 and taken[order[2]] == 0 then
            table.insert(active, plans[order[2]])
        end
        local names = {}
        for _, pl in ipairs(active) do
            local n = {}
            for _, o in ipairs(pl.batch) do
                table.insert(n, "#" .. o.num)
            end
            table.insert(names, table.concat(n, ", "))
        end
        setStatus("Orders: " .. table.concat(names, " | "))
        -- the other side's grill / chopping board right after this side's (the player's own account: Frying_01 then
        -- Frying_02, Chopping_01 then Chopping_02), when nobody else works that side
        local other
        if #active == 1 then
            local oi = active[1].idx == 1 and 2 or 1
            local OS = taken[oi] == 0 and sideStations(lc, oi)
            if OS then
                other = { idx = oi, S = OS, fryWants = {}, chopWants = {}, fryRawWants = {}, rawWants = {}, asmWants = {} }
                if next(active[1].fryWants) then
                    fillFry(OS, other.fryWants)
                end
                if next(active[1].chopWants) then
                    fillChop(OS, other.chopWants)
                end
            end
        end
        -- every station that needs a box, one box after another in one trip first (the player carried box after box)
        local trip = {}
        for _, pl in ipairs(other and { active[1], other } or active) do
            for _, e in ipairs({ { pl.S.fry, pl.fryWants, "the Frying station" }, { pl.S.deep, pl.rawWants, "the Deep-Fry station" },
                { pl.S.chop, pl.chopWants, "the Chopping station" }, { pl.S.asm, pl.asmWants, "the Assembly station" } }) do
                if next(e[2]) and needRestock(e[1], e[2]) then
                    table.insert(trip, e)
                end
            end
        end
        for _, e in ipairs(trip) do
            if not alive() then
                return
            end
            restock(lc, e[1], e[3])
        end
        local anyFry = false
        for _, pl in ipairs(active) do
            if next(pl.fryWants) and needRestock(pl.S.fry, pl.fryWants) and not restock(lc, pl.S.fry, "the Frying station") then
                return
            end
            if not alive() then
                return
            end
            if next(pl.rawWants) and needRestock(pl.S.deep, pl.rawWants) and not restock(lc, pl.S.deep, "the Deep-Fry station") then
                return
            end
            if not alive() then
                return
            end
            if next(pl.fryWants) or next(pl.fryRawWants) then
                anyFry = true
            end
        end
        if anyFry then
            local fryPlans = active
            if other and next(other.fryWants) and not needRestock(other.S.fry, other.fryWants) then
                fryPlans = { active[1], other }
            end
            local ok, why = fryAll(lc, fryPlans)
            if not ok then
                problem("Frying", why)
                task.wait(1)
                return
            end
        end
        -- the vegetables of this side, then the other side's board right after, then the burgers and sides
        if other and next(other.chopWants) and next(active[1].chopWants) and not needRestock(other.S.chop, other.chopWants) then
            if not alive() then
                return
            end
            local okC = true
            if needRestock(active[1].S.chop, active[1].chopWants) then
                okC = restock(lc, active[1].S.chop, "the Chopping station")
            end
            if okC then
                local ok1, why1 = chopVeg(lc, active[1].S.chop, active[1].chopWants)
                if ok1 then
                    active[1].chopWants = {}
                    local ok2, why2 = chopVeg(lc, other.S.chop, other.chopWants)
                    if not ok2 then
                        problem("Chopping", why2)
                    end
                else
                    problem("Chopping", why1)
                end
            end
        end
        for _, pl in ipairs(active) do
            if not alive() then
                return
            end
            if not finishSide(lc, pl) then
                return
            end
        end
        progress()
    end

    -- Entry points
    local busy = false

    -- stuck watchdog (seen: the cook stuck at the Assembly board between the ingredient bins): an ingredient / burger held
    -- in the drag for 10 s (putting one in place takes ~1-3 s) or a minigame open for 8 s is stuck. It is let go with the
    -- game's own stopDrag / LineFollow:Cleanup; the step that waited on it then fails and the cook goes on
    local watching = false
    local function startWatchdog()
        if watching then
            return
        end
        watching = true
        task.spawn(function()
            local held, heldSince, lfSince = nil, 0, nil
            while hooked and running and farming do
                local okD, obj = pcall(function()
                    return DS:GetDraggedObject()
                end)
                obj = okD and obj or nil
                if obj ~= held then
                    held, heldSince = obj, os.clock()
                elseif obj and os.clock() - heldSince > 10 then
                    warn("[Legit Farm Job] cook: " .. tostring(obj) .. " was held for 10 s (stuck), it is let go")
                    aim = nil
                    pcall(dropObj, nil)
                    held = nil
                end
                local okL, lfOn = pcall(function()
                    return LF:IsRunning()
                end)
                if okL and lfOn then
                    lfSince = lfSince or os.clock()
                    if os.clock() - lfSince > 8 then
                        warn("[Legit Farm Job] cook: a minigame stayed open for 8 s (stuck), it is closed")
                        pcall(function()
                            LF:Cleanup()
                        end)
                        lfSince = nil
                    end
                else
                    lfSince = nil
                end
                task.wait(0.5)
            end
            watching = false
        end)
    end

    local function stepInner()
        if not farming then
            task.wait(0.3)
            return
        end
        if not isWorkingJob(COOK_ID) then
            setStatus("Start the Fast Food Worker job first")
            task.wait(1)
            return
        end
        local _, hum = getChar()
        if not hum then
            setStatus("Waiting for character")
            task.wait(1)
            return
        end
        if autoJumpWas == nil then
            autoJumpWas = hum.AutoJumpEnabled
        end
        hum.AutoJumpEnabled = false
        if not init() then
            setStatus("Cook modules not found")
            task.wait(2)
            return
        end
        local lc = lineCook()
        if not lc then
            setStatus("Waiting for the kitchen")
            task.wait(1)
            return
        end
        installHooks()
        startWatchdog()
        if os.clock() - lastStep > 5 then
            progress()
        end
        lastStep = os.clock()
        if os.clock() - lastProgress > 90 then
            setStatus("Stuck, resetting")
            aim = nil
            pcall(function()
                dropObj(nil)
            end)
            leave(nil)
            table.clear(badOrder)
            table.clear(failCount)
            handlerCache = nil
            progress()
            task.wait(1)
            return
        end
        local ok, err = pcall(cycle, lc)
        if not ok then
            warn("[Legit Farm Job] cook: " .. tostring(err))
            setStatus("Error, retrying")
            aim = nil
            task.wait(1.5)
        end
        task.wait(0.1)
    end

    function C.step()
        busy = true
        local ok, err = pcall(stepInner)
        busy = false
        if not ok then
            error(err, 0)
        end
    end

    function C.forceEnd()
        local t0 = os.clock()
        while busy and os.clock() - t0 < 6 do
            task.wait(0.05)
        end
        C.stop()
        if not isWorkingJob(COOK_ID) then
            return true
        end
        local stats = ReplicatedStorage:FindFirstChild("Stats")
        stats = stats and stats:FindFirstChild(LocalPlayer.Name)
        local activity = stats and stats:FindFirstChild("Activity")
        local act0 = activity and activity.Value
        local function ended()
            if activity then
                return activity.Value ~= act0 and not isWorkingJob(COOK_ID)
            end
            return not isWorkingJob(COOK_ID)
        end
        local function attachSomewhere()
            local lc = lineCook()
            local _, _, root = getChar()
            if not (lc and root) then
                return false
            end
            local okHeld, held = pcall(function()
                return JobHandler.Shared.EquipmentService:GetEquipped(LocalPlayer)
            end)
            if okHeld and held and held.Name == "Closed Cardboard Box" then
                pcall(function()
                    JobHandler.Shared.EquipmentService:UnequipItem(LocalPlayer, "Closed Cardboard Box", true)
                end)
                task.wait(0.6)
            end
            local list = {}
            for _, group in pairs(lc.WorkStations) do
                for _, st in pairs(group) do
                    if not takenByOther(st) then
                        table.insert(list, { st = st, d = (st.AttachPosition - root.Position).Magnitude })
                    end
                end
            end
            table.sort(list, function(a, b)
                return a.d < b.d
            end)
            for i = 1, math.min(#list, 3) do
                local st = list[i].st
                local cb = callbackFor(st.StationModel:FindFirstChild("InteractionRoot"))
                if cb and gameSafe(cb) then
                    pcall(cb)
                    local t1 = os.clock()
                    while os.clock() - t1 < 4 and not atStation(st) do
                        task.wait(0.1)
                    end
                    if atStation(st) then
                        return true
                    end
                end
            end
            return false
        end
        if not myWeld() then
            local _, hum0, root0 = getChar()
            if hum0 and root0 then
                hum0:MoveTo(root0.Position)
            end
            attachSomewhere()
        end
        local done = false
        for _ = 1, 3 do
            local _, _, root = getChar()
            if not ended() then
                if not (root and iceInsideArea(root.Position)) then
                    pcall(function()
                        JobHandler:RequestStopWorking()
                    end)
                    task.wait(0.5)
                end
                if not ended() then
                    pcall(function()
                        JobHandler:StopWorking()
                    end)
                end
            end
            local t1 = os.clock()
            while os.clock() - t1 < 1.2 and not ended() do
                task.wait(0.1)
            end
            if ended() then
                done = true
                break
            end
            if not myWeld() then
                attachSomewhere()
            end
        end
        return done
    end

    function C.stop()
        pcall(function()
            if DS and DS:GetDraggedObject() then
                dropObj(nil)
            end
        end)
        removeHooks()
        handlerCache = nil
        if autoJumpWas ~= nil then
            local _, h0 = getChar()
            if h0 then
                h0.AutoJumpEnabled = autoJumpWas
            end
            autoJumpWas = nil
        end
        progress()
    end

    return C
end)()

-- Mood Station: Auto Mood, one pass on the player's own plot - bathtub + TV (Hygiene, Fun), bed (Energy),
-- fridge quick meal Pears (Hunger). Everything is the game's own menus / buttons; walking is Humanoid:MoveTo
-- along pathfinding waypoints.
NC.mood = (function()
    local M = {}
    local MOODS = { "Fun", "Hygiene", "Hunger", "Energy" }
    local target = { Fun = 100, Hygiene = 100, Hunger = 100, Energy = 100 }
    local on, gen = false, 0
    local statusLabel, lastStatus, toggleObj
    local finishing = false

    local function status(text)
        if statusLabel and text ~= lastStatus then
            lastStatus = text
            withUiIdentity(function()
                statusLabel:Set("Status: " .. text)
            end)
        end
    end

    local function moodValue(name)
        local stats = ReplicatedStorage:FindFirstChild("Stats")
        local me = stats and stats:FindFirstChild(LocalPlayer.Name)
        local md = me and me:FindFirstChild("MoodData")
        local v = md and md:FindFirstChild(name)
        return v and v.Value or nil
    end

    local function reached(name)
        local v = moodValue(name)
        return v ~= nil and v >= math.min(target[name], 99.5)
    end

    local function safe()
        return DataService.FireServer == origFireServer and DataService.InvokeServer == origInvokeServer
    end

    -- the objects on the player's own plot, by the game's item types
    local function findObjects()
        local plots = workspace:FindFirstChild("Plots")
        local plot = plots and plots:FindFirstChild("Plot_" .. LocalPlayer.Name)
        local house = plot and plot:FindFirstChild("House")
        local found = {}
        if not house then
            return found
        end
        local _, _, root = getChar()
        local function consider(kind, obj)
            local p = obj:GetPivot().Position
            local d = root and (p - root.Position).Magnitude or 0
            if not found[kind] or d < found[kind].d then
                found[kind] = { obj = obj, d = d }
            end
        end
        local function check(obj)
            local ok, it = pcall(function()
                return JobHandler.Items:GetItem(obj.Name)
            end)
            if not (ok and it) then
                return
            end
            local function is(t)
                local okT, r = pcall(function()
                    return it:IsType(t)
                end)
                return okT and r
            end
            if is("Bathtub") then
                consider("tub", obj)
            elseif is("TV") then
                consider("tv", obj)
            elseif is("Fridge") and obj:FindFirstChild("AttachPos") then
                consider("fridge", obj)
            elseif it.Type == "Beds" then
                consider("bed", obj)
            end
        end
        for _, group in ipairs(house:GetChildren()) do
            for _, obj in ipairs(group:GetChildren()) do
                if obj:FindFirstChild("ObjectModel") then
                    check(obj)
                end
                local ih = obj:FindFirstChild("ItemHolder")
                if ih then
                    for _, it in ipairs(ih:GetChildren()) do
                        if it:FindFirstChild("ObjectModel") then
                            check(it)
                        end
                    end
                end
            end
        end
        return {
            tub = found.tub and found.tub.obj,
            tv = found.tv and found.tv.obj,
            bed = found.bed and found.bed.obj,
            fridge = found.fridge and found.fridge.obj,
        }
    end

    -- Walking: Humanoid:MoveTo along PathfindingService waypoints, the next waypoint is taken before the current
    -- one is reached so it keeps walking
    local function stopWalk()
        local _, hum, root = getChar()
        if hum and root then
            hum:MoveTo(root.Position)
        end
    end

    local function walkPath(goal, alive)
        for _ = 1, 3 do
            local _, hum, root = getChar()
            if not (hum and root) or not alive() then
                return false
            end
            if (flat(root.Position) - flat(goal)).Magnitude <= 1.5 then
                return true
            end
            local path
            for _, cfg in ipairs(AGENT_TRIES) do
                local p = PathfindingService:CreatePath(cfg)
                local ok = pcall(function()
                    p:ComputeAsync(root.Position, goal)
                end)
                if ok and p.Status == Enum.PathStatus.Success then
                    path = p
                    break
                end
            end
            if not path then
                return false
            end
            local wps = path:GetWaypoints()
            local blocked = false
            for i = 2, #wps do
                local wp = wps[i].Position
                if wps[i].Action == Enum.PathWaypointAction.Jump then
                    hum.Jump = true
                end
                hum:MoveTo(wp)
                local r = i < #wps and 2 or 1.2
                local t0, ref, refT = os.clock(), root.Position, os.clock()
                while true do
                    if not alive() then
                        return false
                    end
                    if (flat(root.Position) - flat(wp)).Magnitude <= r then
                        break
                    end
                    if os.clock() - t0 > 4 then
                        blocked = true
                        break
                    end
                    if os.clock() - refT > 0.8 then
                        if (flat(root.Position) - flat(ref)).Magnitude < 0.5 then
                            blocked = true
                            break
                        end
                        ref, refT = root.Position, os.clock()
                    end
                    RunService.Heartbeat:Wait()
                end
                if blocked then
                    break
                end
            end
            if (flat(root.Position) - flat(goal)).Magnitude <= 2 then
                return true
            end
        end
        return false
    end

    -- floor spots around a point next to the object, nearest first; the first one with a path is walked
    local function walkNear(obj, center, alive)
        -- the object's own footprint (+ room for the character): spots under / inside it can't be stood on (seen
        -- live: the ring around a long tub's middle put spots under the tub, pathfinding still said Success)
        local okB, bcf, bsz = pcall(function()
            local om = obj:FindFirstChild("ObjectModel")
            if om and om:IsA("Model") then
                return om:GetBoundingBox()
            end
            return obj.CFrame, obj.Size
        end)
        local function underObj(p)
            if not (okB and bcf) then
                return false
            end
            local rel = bcf:PointToObjectSpace(p)
            return math.abs(rel.X) < bsz.X / 2 + 1.2 and math.abs(rel.Z) < bsz.Z / 2 + 1.2
        end
        -- up to 3 rounds: if no spot works, step away from the object and scan again from there
        for round = 1, 3 do
            local char, hum, root = getChar()
            if not (root and alive()) then
                return false
            end
            local params = RaycastParams.new()
            params.FilterType = Enum.RaycastFilterType.Exclude
            params.FilterDescendantsInstances = { char, obj }
            local spots = {}
            for _, r in ipairs({ 2.5, 3.5, 4.5, 5.5, 6.5 }) do
                for k = 0, 11 do
                    local a = k * math.pi / 6
                    local h = workspace:Raycast(Vector3.new(center.X + math.cos(a) * r, center.Y + 4, center.Z + math.sin(a) * r),
                        Vector3.new(0, -12, 0), params)
                    if h and h.Instance.CanCollide and h.Position.Y < center.Y + 1 and not underObj(h.Position) then
                        table.insert(spots, { p = h.Position, d = (h.Position - root.Position).Magnitude + r })
                    end
                end
            end
            table.sort(spots, function(a, b)
                return a.d < b.d
            end)
            local tries = 0
            for _, s in ipairs(spots) do
                if not alive() or tries >= 6 then
                    break
                end
                tries += 1
                if walkPath(s.p, alive) then
                    return true
                end
            end
            if round < 3 and alive() and hum then
                local away = flat(root.Position) - flat(center)
                away = away.Magnitude > 0.1 and away.Unit or Vector3.new(1, 0, 0)
                walkPath(root.Position + away * 3, alive)
            end
        end
        return false
    end

    -- the game's own interaction menu of an object
    local function closeMenu()
        pcall(function()
            InteractionHandler:CloseMenu()
        end)
    end

    local function clickMenu(obj, text)
        if not (InteractionHandler and safe()) then
            return false
        end
        closeMenu()
        local ok, m = pcall(function()
            return InteractionHandler:ShowMenu(obj)
        end)
        local idx
        if ok and type(m) == "table" and type(m.Buttons) == "table" then
            for k, v in pairs(m.Buttons) do
                if tostring(v.Text or ""):gsub("%[ICON:%d+%]", "") == text then
                    idx = k
                end
            end
        end
        if not idx then
            closeMenu()
            return false
        end
        task.spawn(function()
            pcall(function()
                m:Click(idx)
            end)
        end)
        return true
    end

    local function attached()
        local ok, w = pcall(function()
            return JobHandler.Shared.AttachService:GetAttachWeld(LocalPlayer.Character)
        end)
        return ok and w ~= nil
    end

    -- jumping while attached is the game's own way out (CharacterHandler detaches on Jump)
    local function jumpOut(alive)
        local t0 = os.clock()
        while attached() and os.clock() - t0 < 4 do
            local _, hum = getChar()
            if hum then
                hum.Jump = true
            end
            task.wait(0.3)
        end
        return not attached()
    end

    local function waitFor(cond, timeout, alive)
        local t0 = os.clock()
        while alive() and os.clock() - t0 < timeout do
            if cond() then
                return true
            end
            task.wait(0.1)
        end
        return cond()
    end

    local function tvOn(tv)
        local od = tv and tv:FindFirstChild("ObjectData")
        local v = od and od:FindFirstChild("IsOn")
        return v and v.Value == true
    end

    -- 1. bathtub + TV until Hygiene and Fun reach their targets
    local function doBath(o, alive)
        if reached("Hygiene") and reached("Fun") then
            return true
        end
        if not o.tub then
            status("No bathtub found on your plot")
            task.wait(2)
            return false
        end
        local ap = o.tub:FindFirstChild("AttachPos1")
        status("Walking to the " .. o.tub.Name)
        if not walkNear(o.tub, ap and ap.WorldPosition or o.tub:GetPivot().Position, alive) then
            status("Can't reach the " .. o.tub.Name)
            task.wait(2)
            return false
        end
        local uses = 0
        local lastFun, funT, watchAt = moodValue("Fun") or 0, os.clock(), 0
        while alive() and not (reached("Hygiene") and reached("Fun")) do
            if not attached() then
                if uses >= 3 then
                    status("Can't get in the " .. o.tub.Name)
                    task.wait(2)
                    return false
                end
                uses += 1
                status("Getting in the " .. o.tub.Name)
                clickMenu(o.tub, "Use")
                waitFor(attached, 6, alive)
                closeMenu()
                watchAt = 0
            elseif o.tv and not reached("Fun") and not tvOn(o.tv) then
                status("Turning on the TV")
                clickMenu(o.tv, "Turn On")
                waitFor(function()
                    return tvOn(o.tv)
                end, 3, alive)
                closeMenu()
                watchAt = 0
            elseif o.tv and not reached("Fun") and (watchAt == 0 or (os.clock() - funT > 5 and os.clock() - watchAt > 5)) then
                status("Watching TV")
                clickMenu(o.tv, "Watch")
                task.wait(1)
                closeMenu()
                watchAt, funT, lastFun = os.clock(), os.clock(), moodValue("Fun") or 0
            else
                local fun = moodValue("Fun") or 0
                if fun > lastFun + 0.2 then
                    lastFun, funT = fun, os.clock()
                end
                status(string.format("In the tub: Hygiene %d%%, Fun %d%%", math.floor(moodValue("Hygiene") or 0), math.floor(fun)))
                task.wait(0.3)
            end
        end
        if not alive() then
            return false
        end
        status("Getting out of the " .. o.tub.Name)
        jumpOut(alive)
        task.wait(0.6)
        if o.tv and tvOn(o.tv) then
            status("Turning off the TV")
            clickMenu(o.tv, "Turn Off")
            waitFor(function()
                return not tvOn(o.tv)
            end, 3, alive)
            closeMenu()
        end
        return true
    end

    -- 2. bed until Energy reaches its target
    local function doBed(o, alive)
        if reached("Energy") then
            return true
        end
        if not o.bed then
            status("No bed found on your plot")
            task.wait(2)
            return false
        end
        local ap = o.bed:FindFirstChild("AttachPos1")
        status("Walking to the " .. o.bed.Name)
        if not walkNear(o.bed, ap and ap.WorldPosition or o.bed:GetPivot().Position, alive) then
            status("Can't reach the " .. o.bed.Name)
            task.wait(2)
            return false
        end
        local uses = 0
        while alive() and not reached("Energy") do
            if not attached() then
                if uses >= 3 then
                    status("Can't get in the " .. o.bed.Name)
                    task.wait(2)
                    return false
                end
                uses += 1
                status("Going to sleep")
                clickMenu(o.bed, "Sleep")
                waitFor(attached, 6, alive)
                closeMenu()
            else
                status(string.format("Sleeping: Energy %d%%", math.floor(moodValue("Energy") or 0)))
                task.wait(0.3)
            end
        end
        if not alive() then
            return false
        end
        status("Getting out of the " .. o.bed.Name)
        jumpOut(alive)
        task.wait(0.6)
        return true
    end

    local function equippedName()
        local ok, eq = pcall(function()
            return JobHandler.Shared.EquipmentService:GetEquipped(LocalPlayer)
        end)
        return ok and eq and tostring(eq) or nil
    end

    local function eating()
        local ok, r = pcall(function()
            return JobHandler.Shared.FoodService:IsEating(LocalPlayer.Character)
        end)
        return ok and r
    end

    -- the Quick Meals list's own Take button of a row (the game's ListFrameHandler handler)
    -- the fridge's own "Take Quick Meal" (InteractionData) asks CookingUI:ShowQuickFoodFrame() for the pick, then
    -- sends {Type = "TakeQuickFood", Name = pick._itemName} itself. For that one call the pick is answered with the
    -- item (the same entry the list returns), so the list window (and its blur) never opens; the original function
    -- is put back right away.
    local function takeQuickMeal(fridge, item, alive)
        local CU = JobHandler.Modules and JobHandler.Modules.CookingUI
        local orig = type(CU) == "table" and rawget(CU, "ShowQuickFoodFrame")
        local okI, it = pcall(function()
            return JobHandler.Items:GetItem(item)
        end)
        if not (type(orig) == "function" and not (isexecutorclosure and isexecutorclosure(orig)) and okI and it and safe()) then
            return false
        end
        local used = false
        CU.ShowQuickFoodFrame = function()
            used = true
            CU.ShowQuickFoodFrame = orig
            -- the server first puts the character at the fridge and only then waits for the pick (seen live: an
            -- instant answer was missed and left the character stuck at the fridge), so answer after that, like a
            -- player picking from the list
            local t0 = os.clock()
            while not attached() and os.clock() - t0 < 3 do
                task.wait(0.05)
            end
            task.wait(0.4)
            return { _itemName = item }
        end
        local clicked = clickMenu(fridge, "Take Quick Meal")
        if clicked then
            waitFor(function()
                return used
            end, 4, alive)
        end
        if CU.ShowQuickFoodFrame ~= orig then
            CU.ShowQuickFoodFrame = orig
        end
        return clicked and used
    end

    -- "Eat All": the hotbar's hold action of the equipped food (the game's own Food module)
    local function eatAll()
        local ed = HotbarUI.EquipData
        local f = type(ed) == "table" and ed.HoldFunction
        if not (f and ed.Name == "Pear" and cleanSafe(f)) then
            return false
        end
        task.spawn(function()
            pcall(function()
                HotbarUI:DoEquipHoldAction()
            end)
        end)
        return true
    end

    -- 3. fridge quick meal Pears until Hunger reaches its target
    local function doFood(o, alive)
        if reached("Hunger") then
            return true
        end
        if not o.fridge then
            status("No fridge found on your plot")
            task.wait(2)
            return false
        end
        local fails = 0
        while alive() and not reached("Hunger") do
            if fails >= 3 then
                status("Can't get a Pear from the " .. o.fridge.Name)
                task.wait(2)
                return false
            end
            local _, _, root = getChar()
            local ap = o.fridge:FindFirstChild("AttachPos")
            local center = ap and ap.WorldPosition or o.fridge:GetPivot().Position
            if root and (flat(root.Position) - flat(center)).Magnitude > 5 then
                status("Walking to the " .. o.fridge.Name)
                if not walkNear(o.fridge, center, alive) then
                    status("Can't reach the " .. o.fridge.Name)
                    task.wait(2)
                    return false
                end
            end
            if equippedName() ~= "Pear" then
                status("Taking a Pear")
                local okTake = takeQuickMeal(o.fridge, "Pear", alive)
                closeMenu()
                if not (okTake and waitFor(function()
                    return equippedName() == "Pear"
                end, 5, alive)) then
                    if attached() then
                        jumpOut(alive) -- never left standing at the fridge
                    end
                    fails += 1
                    task.wait(1)
                    continue
                end
            end
            status(string.format("Eating a Pear: Hunger %d%%", math.floor(moodValue("Hunger") or 0)))
            if not eatAll() then
                fails += 1
                task.wait(1)
                continue
            end
            waitFor(eating, 3, alive)
            if waitFor(function()
                return equippedName() ~= "Pear" and not eating()
            end, 20, alive) then
                fails = 0
            else
                fails += 1
            end
            task.wait(0.3)
        end
        return alive()
    end

    local function doneText()
        local same = true
        for _, n in ipairs(MOODS) do
            if target[n] ~= target.Fun then
                same = false
            end
        end
        if same then
            return "Your moods are all at " .. target.Fun .. "%"
        end
        return string.format("Your moods are at their targets: Fun %d%%, Hygiene %d%%, Hunger %d%%, Energy %d%%",
            target.Fun, target.Hygiene, target.Hunger, target.Energy)
    end

    local function setToggle(v)
        if toggleObj then
            withUiIdentity(function()
                toggleObj:Set(v)
            end)
        end
    end

    function M.stop(text)
        on = false
        gen += 1
        closeMenu()
        stopWalk()
        if attached() then
            pcall(function()
                JobHandler.Modules.CharacterHandler:Detach()
            end)
        end
        status(text or "Idle")
    end

    function M.start()
        if on then
            return
        end
        on = true
        gen += 1
        local myGen = gen
        local function alive()
            return running and on and gen == myGen
        end
        task.spawn(function()
            local ok, err = pcall(function()
                local o = findObjects()
                local steps = { doBath, doBed, doFood }
                for _, step in ipairs(steps) do
                    if not alive() then
                        return
                    end
                    step(o, alive)
                end
                if alive() then
                    -- one pass only: done, the toggle goes off and the result stays on the status line
                    on = false
                    finishing = true
                    setToggle(false)
                    finishing = false
                    stopWalk()
                    status(doneText())
                end
            end)
            if not ok then
                warn("[Legit Farm Job] auto mood: " .. tostring(err))
                if gen == myGen then
                    M.stop("Error, stopped")
                    finishing = true
                    setToggle(false)
                    finishing = false
                end
            end
        end)
    end

    function M.shutdown()
        if on then
            M.stop()
        end
        on = false
        gen += 1
    end

    function M.buildUI(tab)
        tab:CreateSection("Mood targets")
        for _, n in ipairs(MOODS) do
            tab:CreateSlider({
                Name = n,
                Range = { 1, 100 },
                Increment = 1,
                Suffix = "%",
                CurrentValue = target[n],
                Flag = "LFJ_Mood_" .. n,
                Callback = function(v)
                    target[n] = math.clamp(math.floor(tonumber(v) or 100), 1, 100)
                end,
            })
        end
        tab:CreateSection("Auto Mood")
        toggleObj = tab:CreateToggle({
            Name = "Auto Mood",
            CurrentValue = false,
            Flag = "LFJ_AutoMood",
            Callback = function(value)
                if finishing then
                    return
                end
                if value then
                    M.start()
                elseif on then
                    M.stop("Idle")
                end
            end,
        })
        statusLabel = tab:CreateLabel("Status: Idle")
    end

    return M
end)()

-- Auto Store (food on the player's own plot)
NC.store = (function()
    local S = {}
    local CoreGui = game:GetService("CoreGui")
    local UserInputService = game:GetService("UserInputService")
    local ESP_FILL, ESP_FILL_T, ESP_LINE = Color3.fromRGB(255, 120, 120), 0.55, Color3.fromRGB(255, 190, 190)
    local HOVER_FILL, HOVER_FILL_T, HOVER_LINE = Color3.fromRGB(255, 30, 30), 0.1, Color3.fromRGB(255, 255, 255)

    local plot
    local foods, labelOf, partOf = {}, {}, {}
    local selected = {} -- food part -> true
    local known = setmetatable({}, { __mode = "k" })
    local deselectedKinds = {}
    local labelStore, labelSeq = setmetatable({}, { __mode = "k" }), {}
    local SELECT_ALL, DESELECT_ALL = "Select All", "Deselect All"
    local highlights = {}
    local dropdown, statusLabel, lastStatus
    local suppress = false
    local espOn, storing = false, false
    local plotConns, inputConns = {}, {}
    local pending = false
    local espFolder
    local hovered
    local badUntil = {} -- food part -> time it may be tried again
    local rayParams = RaycastParams.new()
    rayParams.FilterType = Enum.RaycastFilterType.Include

    local function active()
        return running and storing
    end

    local function status(text)
        if statusLabel and text ~= lastStatus then
            lastStatus = text
            withUiIdentity(function()
                statusLabel:Set("Status: " .. text)
            end)
        end
    end

    local function tr(key, fallback)
        local ok, s = pcall(function()
            return JobHandler.Modules.TranslationHandler:Format(key)
        end)
        return ok and type(s) == "string" and s ~= "" and s or fallback
    end

    -- Food on the plot
    local function foodData(part)
        if part:IsA("BasePart") and part.Parent and part.Parent.Name == "ItemHolder" then
            local ok, it = pcall(function()
                return JobHandler.Items:GetItem(part.Name)
            end)
            if ok and it and it.Type == "Food" then
                return it
            end
        end
    end

    local function findPlot()
        local plots = workspace:FindFirstChild("Plots")
        return plots and plots:FindFirstChild("Plot_" .. LocalPlayer.Name)
    end

    local function collect()
        local out = {}
        local house = plot and plot:FindFirstChild("House")
        if not house then
            return out
        end
        local function scan(holder)
            for _, f in ipairs(holder:GetChildren()) do
                if foodData(f) then
                    table.insert(out, f)
                end
            end
        end
        for _, group in ipairs(house:GetChildren()) do
            local h = group:FindFirstChild("ItemHolder")
            if h then
                scan(h)
            end
            for _, obj in ipairs(group:GetChildren()) do
                local ih = obj:FindFirstChild("ItemHolder")
                if ih then
                    scan(ih)
                end
            end
        end
        return out
    end

    local function relabel(list)
        table.sort(list, function(a, b)
            if a.Name ~= b.Name then
                return a.Name < b.Name
            end
            if math.abs(a.Position.X - b.Position.X) > 0.01 then
                return a.Position.X < b.Position.X
            end
            return a.Position.Z < b.Position.Z
        end)
        local newCount = {}
        for _, p in ipairs(list) do
            if not labelStore[p] then
                newCount[p.Name] = (newCount[p.Name] or 0) + 1
            end
        end
        for _, p in ipairs(list) do
            if not labelStore[p] then
                local seq = (labelSeq[p.Name] or 0) + 1
                labelSeq[p.Name] = seq
                labelStore[p] = (seq == 1 and newCount[p.Name] == 1) and p.Name or (p.Name .. " #" .. seq)
            end
        end
        labelOf, partOf = {}, {}
        for _, p in ipairs(list) do
            labelOf[p] = labelStore[p]
            partOf[labelStore[p]] = p
        end
        foods = list
    end

    local function dropdownFrame()
        local ok, frame = pcall(function()
            for _, root in ipairs({ gethui and gethui() or CoreGui, CoreGui }) do
                local rf = root:FindFirstChild("Rayfield")
                local el = rf and rf:FindFirstChild("Main") and rf.Main:FindFirstChild("Elements")
                local page = el and el:FindFirstChild("Auto Store")
                local d = page and page:FindFirstChild("Food on your plot")
                if d then
                    return d
                end
            end
        end)
        return ok and frame or nil
    end

    local function decorate()
        local frame = dropdownFrame()
        local list = frame and frame:FindFirstChild("List")
        if not list then
            return
        end
        for _, row in ipairs(list:GetChildren()) do
            local part = row:IsA("Frame") and partOf[row.Name]
            if part and not row:FindFirstChild("FoodIcon") then
                local ok, it = pcall(function()
                    return JobHandler.Items:GetItem(part.Name)
                end)
                local title = row:FindFirstChild("Title")
                if ok and it and it.Icon and title then
                    local img = Instance.new("ImageLabel")
                    img.Name = "FoodIcon"
                    img.BackgroundTransparency = 1
                    img.Image = "rbxassetid://" .. tostring(it.Icon)
                    img.Size = UDim2.fromOffset(26, 26)
                    img.AnchorPoint = Vector2.new(0, 0.5)
                    img.Position = UDim2.new(0, 10, 0.5, 0)
                    img.Parent = row
                    title.Position = UDim2.new(title.Position.X.Scale, title.Position.X.Offset + 34, title.Position.Y.Scale, title.Position.Y.Offset)
                    title.Size = UDim2.new(title.Size.X.Scale, title.Size.X.Offset - 34, title.Size.Y.Scale, title.Size.Y.Offset)
                end
            end
        end
    end

    local function styleNormal(h)
        h.FillColor, h.FillTransparency, h.OutlineColor, h.OutlineTransparency = ESP_FILL, ESP_FILL_T, ESP_LINE, 0.15
    end

    local function styleHover(h)
        h.FillColor, h.FillTransparency, h.OutlineColor, h.OutlineTransparency = HOVER_FILL, HOVER_FILL_T, HOVER_LINE, 0
    end

    local function setHover(p)
        if hovered == p then
            return
        end
        local old = hovered
        hovered = p
        local o = old and highlights[old]
        if o then
            styleNormal(o)
        end
        local n = p and highlights[p]
        if n then
            styleHover(n)
        end
    end

    local function rebuildRay()
        local list = {}
        for p in pairs(highlights) do
            table.insert(list, p)
        end
        rayParams.FilterDescendantsInstances = list
        if hovered and not highlights[hovered] then
            hovered = nil
        end
    end

    local function syncESP()
        for p, h in pairs(highlights) do
            if not (espOn and selected[p] and p.Parent) then
                h:Destroy()
                highlights[p] = nil
            end
        end
        if espOn then
            if not (espFolder and espFolder.Parent) then
                espFolder = Instance.new("Folder")
                espFolder.Name = "LFJ_FoodESP"
                espFolder.Parent = gethui and gethui() or CoreGui
            end
            for p in pairs(selected) do
                if p.Parent and not highlights[p] then
                    local h = Instance.new("Highlight")
                    h.Adornee = p:FindFirstChild("ObjectModel") or p
                    h.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
                    styleNormal(h)
                    h.Parent = espFolder
                    highlights[p] = h
                end
            end
        end
        rebuildRay()
        if not espOn then
            hovered = nil
        end
    end

    local function updateHover()
        if not espOn or next(highlights) == nil then
            setHover(nil)
            return
        end
        local cam = workspace.CurrentCamera
        if not cam then
            return
        end
        local loc = UserInputService:GetMouseLocation()
        local ray = cam:ViewportPointToRay(loc.X, loc.Y)
        local res = workspace:Raycast(ray.Origin, ray.Direction * 300, rayParams)
        local found
        local inst = res and res.Instance
        for _ = 1, 8 do
            if not inst then
                break
            end
            if highlights[inst] then
                found = inst
                break
            end
            inst = inst.Parent
        end
        setHover(found)
    end

    local function setDropdownSelection()
        if not dropdown then
            return
        end
        local current = {}
        for _, p in ipairs(foods) do
            if selected[p] then
                table.insert(current, labelOf[p])
            end
        end
        suppress = true
        withUiIdentity(function()
            dropdown:Set(current)
        end)
        suppress = false
    end

    local function deselect(p)
        if selected[p] then
            selected[p] = nil
            deselectedKinds[p.Name] = true
            setDropdownSelection()
            syncESP()
        end
    end

    local function selectAll(on)
        for _, p in ipairs(foods) do
            selected[p] = on or nil
            deselectedKinds[p.Name] = (not on) or nil
        end
        setDropdownSelection()
        syncESP()
    end

    local function refresh()
        pending = false
        local list = collect()
        relabel(list)
        for _, p in ipairs(list) do
            if not known[p] then
                known[p] = true
                if not deselectedKinds[p.Name] then
                    selected[p] = true
                end
            end
        end
        for p in pairs(selected) do
            if not (p.Parent and labelOf[p]) then
                selected[p] = nil
            end
        end
        if dropdown then
            local options = { SELECT_ALL, DESELECT_ALL }
            for _, p in ipairs(foods) do
                table.insert(options, labelOf[p])
            end
            suppress = true
            withUiIdentity(function()
                dropdown:Refresh(options)
            end)
            suppress = false
            decorate()
            setDropdownSelection()
        end
        syncESP()
    end

    local function scheduleRefresh()
        if pending or not running then
            return
        end
        pending = true
        task.delay(0.4, function()
            if running then
                refresh()
            else
                pending = false
            end
        end)
    end

    local function watchPlot()
        for _, c in ipairs(plotConns) do
            pcall(function()
                c:Disconnect()
            end)
        end
        table.clear(plotConns)
        plot = findPlot()
        if plot then
            table.insert(plotConns, plot.DescendantAdded:Connect(function(d)
                if d.Parent and d.Parent.Name == "ItemHolder" then
                    scheduleRefresh()
                end
            end))
            table.insert(plotConns, plot.DescendantRemoving:Connect(function(d)
                if d.Parent and d.Parent.Name == "ItemHolder" then
                    scheduleRefresh()
                end
            end))
        end
        local plots = workspace:FindFirstChild("Plots")
        if plots then
            table.insert(plotConns, plots.ChildAdded:Connect(function(c)
                if c.Name == "Plot_" .. LocalPlayer.Name then
                    watchPlot()
                end
            end))
        end
        scheduleRefresh()
    end

    local function flat(v)
        return Vector3.new(v.X, 0, v.Z)
    end

    local function walkTo(target, within)
        within = within or 2.5
        for _ = 1, 3 do
            local _, hum, root = getChar()
            if not hum then
                return false
            end
            if (flat(root.Position) - flat(target)).Magnitude <= within then
                return true
            end
            local path
            for _, cfg in ipairs(AGENT_TRIES) do
                local p = PathfindingService:CreatePath(cfg)
                local ok = pcall(function()
                    p:ComputeAsync(root.Position, target)
                end)
                if ok and p.Status == Enum.PathStatus.Success then
                    path = p
                    break
                end
                task.wait(0.1)
            end
            if not path then
                return false
            end
            local wps = path:GetWaypoints()
            for i, wp in ipairs(wps) do
                if not active() then
                    return false
                end
                if i > 1 then
                    if wp.Action == Enum.PathWaypointAction.Jump then
                        hum.Jump = true
                    end
                    local finished, reached = false, false
                    local conn = hum.MoveToFinished:Connect(function(ok)
                        finished, reached = true, ok
                    end)
                    hum:MoveTo(wp.Position)
                    local t0, refPos, refT = os.clock(), root.Position, os.clock()
                    while active() and not finished and os.clock() - t0 < 3 do
                        local rp = root.Position
                        if i < #wps and (flat(rp) - flat(wp.Position)).Magnitude <= 1.8 then
                            reached = true
                            break
                        end
                        if os.clock() - refT > 0.8 then
                            if (flat(rp) - flat(refPos)).Magnitude < 0.5 then
                                break
                            end
                            refPos, refT = rp, os.clock()
                        end
                        RunService.Heartbeat:Wait()
                    end
                    conn:Disconnect()
                    if not reached then
                        break
                    end
                end
            end
            local _, _, r2 = getChar()
            if r2 and (flat(r2.Position) - flat(target)).Magnitude <= within + 0.5 then
                return true
            end
            task.wait(0.1)
        end
        return false
    end

    local function stopWalk()
        local _, hum, root = getChar()
        if hum and root then
            hum:MoveTo(root.Position)
        end
    end

    local function holding()
        local ok, n, isTray = pcall(function()
            local ES = JobHandler.Shared.EquipmentService
            local tray = ES:HasTray(LocalPlayer)
            if tray then
                local content = tray:FindFirstChild("_trayContent")
                return content and #content:GetChildren() or 0, true
            end
            local eq = ES:GetEquipped(LocalPlayer)
            if eq then
                local it = JobHandler.Items:GetItem(tostring(eq))
                if it and it.Type == "Food" then
                    return 1, false
                end
            end
            return 0, false
        end)
        if ok then
            return n, isTray
        end
        return 0, false
    end

    local function menuOf(obj)
        pcall(function()
            InteractionHandler:CloseMenu()
        end)
        local ok, m = pcall(function()
            return InteractionHandler:ShowMenu(obj)
        end)
        return ok and type(m) == "table" and m or nil
    end

    local function buttonIndex(menu, text, exact)
        for k, v in pairs(menu.Buttons) do
            local t = tostring(v.Text or ""):gsub("%[ICON:%d+%]", "")
            if exact and t == text or (not exact and t:find(text, 1, true)) then
                return k
            end
        end
    end

    local function closeMenu()
        pcall(function()
            InteractionHandler:CloseMenu()
        end)
    end

    local function standPoints(part)
        local char, _, root = getChar()
        local out = {}
        if not root then
            return out
        end
        local params = RaycastParams.new()
        params.FilterType = Enum.RaycastFilterType.Exclude
        params.FilterDescendantsInstances = { char }
        local pos = part.Position
        for a = 0, 315, 45 do
            for _, r in ipairs({ 3, 2.2 }) do
                local x = pos.X + math.cos(math.rad(a)) * r
                local z = pos.Z + math.sin(math.rad(a)) * r
                local hit = workspace:Raycast(Vector3.new(x, pos.Y + 1, z), Vector3.new(0, -16, 0), params)
                if hit and hit.Position.Y < pos.Y - 1.5 and hit.Instance.CanCollide then
                    table.insert(out, { hit.Position, (hit.Position - root.Position).Magnitude })
                end
            end
        end
        table.sort(out, function(p, q)
            return p[2] < q[2]
        end)
        return out
    end

    local function take(part)
        local before = holding()
        for _ = 1, 3 do
            if not active() then
                return false
            end
            if not part.Parent then
                return true
            end
            local m = menuOf(part)
            local idx = m and buttonIndex(m, tr("I_Take", "Take"), true)
            if idx then
                status("Taking " .. part.Name)
                pcall(function()
                    m:Click(idx)
                end)
                local t0 = os.clock()
                while active() and os.clock() - t0 < 3 do
                    if not part.Parent or holding() > before then
                        closeMenu()
                        task.wait(0.4 + math.random() * 0.3)
                        return true
                    end
                    task.wait(0.1)
                end
            else
                task.wait(0.3)
            end
            closeMenu()
        end
        return false
    end

    local function nearestFridge()
        local house = plot and plot:FindFirstChild("House")
        local _, _, root = getChar()
        if not (house and root) then
            return nil
        end
        local best, bd
        for _, group in ipairs(house:GetChildren()) do
            for _, obj in ipairs(group:GetChildren()) do
                if obj:FindFirstChild("AttachPos") then
                    local ok, isFridge = pcall(function()
                        local it = JobHandler.Items:GetItem(obj.Name)
                        return it and it:IsType("Fridge")
                    end)
                    if ok and isFridge then
                        local d = (obj:GetPivot().Position - root.Position).Magnitude
                        if not bd or d < bd then
                            best, bd = obj, d
                        end
                    end
                end
            end
        end
        return best
    end

    local function storeAll()
        local fridge = nearestFridge()
        if not fridge then
            status("No fridge found on the plot")
            task.wait(2)
            return false
        end
        status("Walking to the fridge")
        local ap = fridge:FindFirstChild("AttachPos")
        if not (ap and walkTo(ap.WorldPosition, 1.5)) then
            return false
        end
        local m = menuOf(fridge)
        local idx = m and buttonIndex(m, tr("I_Store", "Store"), false)
        if not idx then
            closeMenu()
            task.wait(0.5)
            return false
        end
        status("Storing the food")
        pcall(function()
            m:Click(idx)
        end)
        local t0 = os.clock()
        while active() and os.clock() - t0 < 2.5 do
            local all = buttonIndex(m, tr("I_StoreAll", "Store All"), false)
            if all then
                pcall(function()
                    m:Click(all)
                end)
                break
            end
            if holding() == 0 then
                break
            end
            task.wait(0.1)
        end
        t0 = os.clock()
        while active() and os.clock() - t0 < 60 do
            local weld = JobHandler.Shared.AttachService:GetAttachWeld(LocalPlayer.Character)
            if holding() == 0 and not weld then
                break
            end
            task.wait(0.2)
        end
        closeMenu()
        return holding() == 0
    end

    local function targets()
        local out = {}
        local now = os.clock()
        for _, p in ipairs(foods) do
            if selected[p] and p.Parent and not (badUntil[p] and badUntil[p] > now) and p:GetAttribute("_updateModel") ~= -1 then
                table.insert(out, p)
            end
        end
        return out
    end

    local function loop()
        if holding() > 0 then
            storing = false
            S.setToggle(false)
            status("Put away what you are holding first")
            return
        end
        local full = false
        while active() do
            local _, hum, root = getChar()
            if not hum then
                status("Waiting for character")
                task.wait(1)
            else
                local list = targets()
                local held = holding()
                if full or (#list == 0 and held > 0) then
                    if storeAll() then
                        full = false
                    else
                        task.wait(1)
                    end
                elseif #list > 0 then
                    local best, bd
                    for _, p in ipairs(list) do
                        local d = (p.Position - root.Position).Magnitude
                        if not bd or d < bd then
                            best, bd = p, d
                        end
                    end
                    status("Walking to the " .. best.Name)
                    local reached = false
                    for _, sp in ipairs(standPoints(best)) do
                        if not active() then
                            break
                        end
                        if walkTo(sp[1], 1.2) then
                            reached = true
                            break
                        end
                    end
                    if reached and active() then
                        if not take(best) and active() then
                            if holding() > 0 then
                                full = true
                            else
                                badUntil[best] = os.clock() + 30
                            end
                        end
                    elseif active() then
                        badUntil[best] = os.clock() + 30
                    end
                else
                    status("All selected food is stored")
                    task.wait(1)
                end
            end
            task.wait()
        end
    end

    function S.stop()
        storing = false
        stopWalk()
        closeMenu()
        local ok, weld = pcall(function()
            return JobHandler.Shared.AttachService:GetAttachWeld(LocalPlayer.Character)
        end)
        if ok and weld and weld.Part1 and plot and weld.Part1:IsDescendantOf(plot) then
            pcall(function()
                JobHandler.Modules.CharacterHandler:Detach()
            end)
        end
        status("Idle")
    end

    local toggleObj
    function S.setToggle(v)
        if toggleObj then
            withUiIdentity(function()
                toggleObj:Set(v)
            end)
        end
    end

    function S.shutdown()
        storing = false
        espOn = false
        pcall(S.stop)
        syncESP()
        for _, c in ipairs(plotConns) do
            pcall(function()
                c:Disconnect()
            end)
        end
        table.clear(plotConns)
        for _, c in ipairs(inputConns) do
            pcall(function()
                c:Disconnect()
            end)
        end
        table.clear(inputConns)
        if espFolder then
            espFolder:Destroy()
            espFolder = nil
        end
    end

    function S.buildUI()
        local MoodTab = Window:CreateTab("Mood Station", "smile")
        NC.mood.buildUI(MoodTab)

        local StoreTab = Window:CreateTab("Auto Store", "package")
        StoreTab:CreateSection("Auto Store food on your plot")
        StoreTab:CreateLabel("Works on your own plot: food on a table and a fridge. Select food, then turn Auto Store on.")
        dropdown = StoreTab:CreateDropdown({
            Name = "Food on your plot",
            Options = {},
            CurrentOption = {},
            MultipleOptions = true,
            Flag = "LFJ_StoreFood",
            Callback = function(option)
                if suppress then
                    return
                end
                local opts = type(option) == "table" and option or { option }
                local set, wantAll, wantNone = {}, false, false
                for _, label in ipairs(opts) do
                    if label == SELECT_ALL then
                        wantAll = true
                    elseif label == DESELECT_ALL then
                        wantNone = true
                    else
                        set[label] = true
                    end
                end
                if wantAll or wantNone then
                    selectAll(wantAll)
                    return
                end
                for _, p in ipairs(foods) do
                    local now = set[labelOf[p]] == true
                    if selected[p] and not now then
                        deselectedKinds[p.Name] = true
                    elseif now and not selected[p] then
                        deselectedKinds[p.Name] = nil
                    end
                    selected[p] = now or nil
                end
                syncESP()
            end,
        })
        StoreTab:CreateToggle({
            Name = "Food ESP",
            CurrentValue = false,
            Flag = "LFJ_StoreESP",
            Callback = function(value)
                espOn = value
                syncESP()
                updateHover()
            end,
        })
        toggleObj = StoreTab:CreateToggle({
            Name = "Auto Store",
            CurrentValue = false,
            Flag = "LFJ_StoreRun",
            Callback = function(value)
                if value then
                    if storing then
                        return
                    end
                    storing = true
                    task.spawn(function()
                        local ok, err = pcall(loop)
                        if not ok then
                            warn("[Legit Farm Job] auto store: " .. tostring(err))
                            status("Error, stopped")
                        end
                        if storing then
                            storing = false
                            S.setToggle(false)
                        end
                    end)
                else
                    S.stop()
                end
            end,
        })
        statusLabel = StoreTab:CreateLabel("Status: Idle")

        StoreTab:CreateSection("Roommate permissions")
        StoreTab:CreateLabel("This area only works if you give me Roommate or any higher permissions.")
        NC.shared.buildUI(StoreTab)

        -- hover and Ctrl + click on a highlighted food
        local lastMove = 0
        table.insert(inputConns, UserInputService.InputChanged:Connect(function(input)
            if espOn and input.UserInputType == Enum.UserInputType.MouseMovement then
                local now = os.clock()
                if now - lastMove > 0.04 then
                    lastMove = now
                    updateHover()
                end
            end
        end))
        table.insert(inputConns, UserInputService.InputBegan:Connect(function(input)
            if espOn and hovered and input.UserInputType == Enum.UserInputType.MouseButton1
                and (UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) or UserInputService:IsKeyDown(Enum.KeyCode.RightControl)) then
                updateHover()
                if hovered then
                    deselect(hovered)
                end
            end
        end))
        watchPlot()
    end

    return S
end)()

-- Auto Store (roommate plots)
NC.shared = (function()
    local M = {}
    local CoreGui = game:GetService("CoreGui")
    local UserInputService = game:GetService("UserInputService")
    local PermissionService = require(ReplicatedStorage.Modules.PermissionService)
    local ESP_FILL, ESP_FILL_T, ESP_LINE = Color3.fromRGB(255, 120, 120), 0.55, Color3.fromRGB(255, 190, 190)
    local HOVER_FILL, HOVER_FILL_T, HOVER_LINE = Color3.fromRGB(255, 30, 30), 0.1, Color3.fromRGB(255, 255, 255)
    local ROOMMATE, OWNER = 5, 7

    local access = {}
    local target, plot
    local playerByLabel = {}
    local foods, labelOf, partOf = {}, {}, {}
    local selected, highlights, badUntil = {}, {}, {}
    local unreachable = setmetatable({}, { __mode = "k" })
    local failCount = setmetatable({}, { __mode = "k" })
    local labelStore, labelSeq = setmetatable({}, { __mode = "k" }), {}
    local known = setmetatable({}, { __mode = "k" })
    local deselectedKinds = {}
    local SELECT_ALL, DESELECT_ALL = "Select All", "Deselect All"
    local trayMax
    local TRAY_MAX = 21
    local playerDD, foodDD, espToggle, storeToggle, statusLabel, lastStatus
    local playerFrame, foodFrame, espFrame, storeFrame, statusFrame
    local suppress, espOn, storing, finishing, pending = false, false, false, false, false
    local plotConns, inputConns = {}, {}
    local espFolder, hovered
    local lastOptions = ""
    local uiDirty = false
    local generation = 0
    local toPlotAt = 0
    local rayParams = RaycastParams.new()
    rayParams.FilterType = Enum.RaycastFilterType.Include

    local function active()
        return running and (storing or finishing)
    end

    local function status(text)
        if statusLabel and text ~= lastStatus then
            lastStatus = text
            withUiIdentity(function()
                statusLabel:Set("Status: " .. text)
            end)
        end
    end

    local function tr(key, fallback)
        local ok, s = pcall(function()
            return JobHandler.Modules.TranslationHandler:Format(key)
        end)
        return ok and type(s) == "string" and s ~= "" and s or fallback
    end

    local function labelFor(plr)
        return plr.DisplayName .. " (@" .. plr.Name .. ")"
    end

    local function headshot(plr)
        return "rbxthumb://type=AvatarHeadShot&id=" .. plr.UserId .. "&w=150&h=150"
    end

    -- Permissions
    local function levelOf(plr)
        local ok, lvl = pcall(function()
            if PermissionService:IsLoaded(plr) then
                return PermissionService:GetPermission(LocalPlayer, plr)
            end
        end)
        return ok and type(lvl) == "number" and lvl or nil
    end

    local function levelName(lvl)
        local ok, names = pcall(function()
            return PermissionService:GetPermissionNames()
        end)
        return ok and type(names) == "table" and names[lvl] or tostring(lvl)
    end

    local function notify(plr, title, content)
        task.spawn(function()
            withUiIdentity(function()
                Rayfield:Notify({ Title = title, Content = content, Duration = 8 })
            end)
            task.wait(0.15)
            pcall(function()
                for _, root in ipairs({ gethui and gethui() or CoreGui, CoreGui }) do
                    local rf = root:FindFirstChild("Rayfield")
                    local box = rf and rf:FindFirstChild("Notifications")
                    local frame = box and box:FindFirstChild(title)
                    local icon = frame and frame:FindFirstChild("Icon")
                    if icon then
                        icon.Image = headshot(plr)
                        icon.ImageColor3 = Color3.new(1, 1, 1)
                        icon.Visible = true
                        return
                    end
                end
            end)
        end)
    end

    -- Food on the selected player's plot
    -- food put down on the floor is a part straight in a House group (House.Objects), not in an ItemHolder
    local function onFloor(part)
        local g = part.Parent
        return g ~= nil and g.Parent ~= nil and g.Parent.Name == "House" and g.Parent.Parent == plot
    end

    local function foodData(part)
        if part:IsA("BasePart") and part.Parent and (part.Parent.Name == "ItemHolder" or onFloor(part)) then
            local ok, it = pcall(function()
                return JobHandler.Items:GetItem(part.Name)
            end)
            if ok and it and it.Type == "Food" then
                return it
            end
        end
    end

    local function collect()
        local out = {}
        local house = plot and plot:FindFirstChild("House")
        if not house then
            return out
        end
        local function scan(holder)
            for _, f in ipairs(holder:GetChildren()) do
                if foodData(f) then
                    table.insert(out, f)
                end
            end
        end
        for _, group in ipairs(house:GetChildren()) do
            local h = group:FindFirstChild("ItemHolder")
            if h then
                scan(h)
            end
            for _, obj in ipairs(group:GetChildren()) do
                local ih = obj:FindFirstChild("ItemHolder")
                if ih then
                    scan(ih)
                elseif foodData(obj) then
                    table.insert(out, obj)
                end
            end
        end
        return out
    end

    local function relabel(list)
        -- sort keys read once per part (seen live: reading Name / Position inside the sort for 6160 foods took 348 ms,
        -- a freeze on every grab)
        local key = {}
        for _, p in ipairs(list) do
            local pos = p.Position
            key[p] = { p.Name, pos.X, pos.Z }
        end
        table.sort(list, function(a, b)
            local ka, kb = key[a], key[b]
            if ka[1] ~= kb[1] then
                return ka[1] < kb[1]
            end
            if math.abs(ka[2] - kb[2]) > 0.01 then
                return ka[2] < kb[2]
            end
            return ka[3] < kb[3]
        end)
        local newCount = {}
        for _, p in ipairs(list) do
            if not labelStore[p] then
                newCount[key[p][1]] = (newCount[key[p][1]] or 0) + 1
            end
        end
        for _, p in ipairs(list) do
            if not labelStore[p] then
                local name = key[p][1]
                local seq = (labelSeq[name] or 0) + 1
                labelSeq[name] = seq
                labelStore[p] = (seq == 1 and newCount[name] == 1) and name or (name .. " #" .. seq)
            end
        end
        labelOf, partOf = {}, {}
        for _, p in ipairs(list) do
            labelOf[p] = labelStore[p]
            partOf[labelStore[p]] = p
        end
        foods = list
    end

    local function decorateRows(frame, iconOf)
        local list = frame and frame:FindFirstChild("List")
        if not list then
            return
        end
        for _, row in ipairs(list:GetChildren()) do
            local image = row:IsA("Frame") and not row:FindFirstChild("RowIcon") and iconOf(row.Name)
            local title = row:FindFirstChild("Title")
            if image and title then
                local img = Instance.new("ImageLabel")
                img.Name = "RowIcon"
                img.BackgroundTransparency = 1
                img.Image = image
                img.Size = UDim2.fromOffset(26, 26)
                img.AnchorPoint = Vector2.new(0, 0.5)
                img.Position = UDim2.new(0, 10, 0.5, 0)
                img.Parent = row
                title.Position = UDim2.new(title.Position.X.Scale, title.Position.X.Offset + 34, title.Position.Y.Scale, title.Position.Y.Offset)
                title.Size = UDim2.new(title.Size.X.Scale, title.Size.X.Offset - 34, title.Size.Y.Scale, title.Size.Y.Offset)
            end
        end
    end

    local function decorateFood()
        decorateRows(foodFrame, function(label)
            local part = partOf[label]
            local ok, it = pcall(function()
                return part and JobHandler.Items:GetItem(part.Name)
            end)
            return ok and it and it.Icon and ("rbxassetid://" .. tostring(it.Icon)) or nil
        end)
    end

    local function decoratePlayers()
        decorateRows(playerFrame, function(label)
            local plr = playerByLabel[label]
            return plr and headshot(plr) or nil
        end)
    end

    -- box adornments: Highlight is capped at 31 and SelectionBox lags with thousands
    local function styleNormal(h)
        h.Color3, h.Transparency = ESP_FILL, ESP_FILL_T
    end

    local function styleHover(h)
        h.Color3, h.Transparency = HOVER_FILL, HOVER_FILL_T
    end

    local function setHover(p)
        if hovered == p then
            return
        end
        local old = hovered
        hovered = p
        local o = old and highlights[old]
        if o then
            styleNormal(o)
        end
        local n = p and highlights[p]
        if n then
            styleHover(n)
        end
    end

    local function rebuildRay()
        local list = {}
        for p in pairs(highlights) do
            table.insert(list, p)
        end
        rayParams.FilterDescendantsInstances = list
        if hovered and not highlights[hovered] then
            hovered = nil
        end
    end

    local function syncESP()
        for p, h in pairs(highlights) do
            if not (espOn and selected[p] and p.Parent) then
                h:Destroy()
                highlights[p] = nil
            end
        end
        if espOn then
            if not (espFolder and espFolder.Parent) then
                espFolder = Instance.new("Folder")
                espFolder.Name = "LFJ_SharedFoodESP"
                espFolder.Parent = gethui and gethui() or CoreGui
            end
            for p in pairs(selected) do
                if p.Parent and not highlights[p] then
                    local h = Instance.new("BoxHandleAdornment")
                    h.Adornee = p
                    h.AlwaysOnTop = true
                    h.ZIndex = 1
                    local model = p:FindFirstChild("ObjectModel")
                    local okBox, cf, size = pcall(function()
                        if model and model:IsA("Model") then
                            return model:GetBoundingBox()
                        end
                    end)
                    if okBox and cf and size then
                        h.CFrame = p.CFrame:ToObjectSpace(cf)
                        h.Size = size
                    else
                        h.Size = Vector3.new(1.2, 1.2, 1.2)
                    end
                    styleNormal(h)
                    h.Parent = espFolder
                    highlights[p] = h
                end
            end
        end
        rebuildRay()
        if not espOn then
            hovered = nil
        end
    end

    local function updateHover()
        if not espOn or next(highlights) == nil then
            setHover(nil)
            return
        end
        local cam = workspace.CurrentCamera
        if not cam then
            return
        end
        local loc = UserInputService:GetMouseLocation()
        local ray = cam:ViewportPointToRay(loc.X, loc.Y)
        local res = workspace:Raycast(ray.Origin, ray.Direction * 300, rayParams)
        local found
        local inst = res and res.Instance
        for _ = 1, 8 do
            if not inst then
                break
            end
            if highlights[inst] then
                found = inst
                break
            end
            inst = inst.Parent
        end
        setHover(found)
    end

    local function setFoodSelection()
        if not foodDD then
            return
        end
        local current = {}
        for _, p in ipairs(foods) do
            if selected[p] then
                table.insert(current, labelOf[p])
            end
        end
        suppress = true
        withUiIdentity(function()
            foodDD:Set(current)
        end)
        suppress = false
    end

    local function deselect(p)
        if selected[p] then
            selected[p] = nil
            deselectedKinds[p.Name] = true
            setFoodSelection()
            syncESP()
        end
    end

    local function selectAll(on)
        for _, p in ipairs(foods) do
            selected[p] = on or nil
            deselectedKinds[p.Name] = (not on) or nil
        end
        setFoodSelection()
        syncESP()
    end

    local function refreshFood()
        pending = false
        local list = collect()
        relabel(list)
        for _, p in ipairs(list) do
            if not known[p] then
                known[p] = true
                if not deselectedKinds[p.Name] then
                    selected[p] = true
                end
            end
        end
        for p in pairs(selected) do
            if not (p.Parent and labelOf[p]) then
                selected[p] = nil
            end
        end
        if foodDD then
            if active() then
                -- rebuilding thousands of dropdown rows freezes the game for seconds; do it once storing ends
                uiDirty = true
            else
                uiDirty = false
                local options = { SELECT_ALL, DESELECT_ALL }
                for _, p in ipairs(foods) do
                    table.insert(options, labelOf[p])
                end
                suppress = true
                withUiIdentity(function()
                    foodDD:Refresh(options)
                end)
                suppress = false
                decorateFood()
                setFoodSelection()
            end
        end
        syncESP()
    end

    -- food that was only taken away (a grab) is dropped from the lists without scanning / sorting the whole plot again
    -- (seen live: that full refresh was a ~400 ms freeze after every grab with 6160 foods on the plot)
    local removedPending, fullPending = {}, false
    local function quickRemove()
        pending = false
        local gone = removedPending
        removedPending = {}
        if next(gone) == nil then
            return
        end
        local keep = {}
        local list = foodFrame and foodFrame:FindFirstChild("List")
        for _, p in ipairs(foods) do
            if gone[p] then
                local l = labelOf[p]
                labelOf[p] = nil
                selected[p] = nil
                if l then
                    partOf[l] = nil
                    local row = list and list:FindFirstChild(l)
                    if row then
                        row.Visible = false -- the dropdown row of a taken food (the next full refresh rebuilds the list)
                    end
                end
            else
                keep[#keep + 1] = p
            end
        end
        foods = keep
        syncESP()
    end

    local function scheduleRefresh(removed)
        if removed then
            removedPending[removed] = true
        else
            fullPending = true
        end
        if pending or not running then
            return
        end
        pending = true
        task.delay(0.4, function()
            if running then
                if fullPending then
                    fullPending = false
                    table.clear(removedPending)
                    refreshFood()
                else
                    quickRemove()
                end
            else
                pending = false
            end
        end)
    end

    local function watchPlot()
        for _, c in ipairs(plotConns) do
            pcall(function()
                c:Disconnect()
            end)
        end
        table.clear(plotConns)
        plot = nil
        if not target then
            return
        end
        local who = target
        local plots = workspace:FindFirstChild("Plots")
        plot = plots and plots:FindFirstChild("Plot_" .. who.Name)
        if plot then
            table.insert(plotConns, plot.DescendantAdded:Connect(function(d)
                if d.Parent and (d.Parent.Name == "ItemHolder" or (d:IsA("BasePart") and onFloor(d))) then
                    scheduleRefresh()
                end
            end))
            table.insert(plotConns, plot.DescendantRemoving:Connect(function(d)
                if d.Parent and (d.Parent.Name == "ItemHolder" or (d:IsA("BasePart") and onFloor(d))) then
                    scheduleRefresh(d)
                end
            end))
        end
        if plots then
            table.insert(plotConns, plots.ChildAdded:Connect(function(c)
                if target == who and c.Name == "Plot_" .. who.Name then
                    watchPlot()
                end
            end))
        end
        scheduleRefresh()
    end

    -- Walking and the game's own menus (same as section #1)
    local function flat(v)
        return Vector3.new(v.X, 0, v.Z)
    end

    -- the fenced yard of the plot: walking never goes outside it
    local bounds
    local function plotBounds()
        if bounds and bounds.plot == plot then
            return bounds.box
        end
        local house = plot and plot:FindFirstChild("House")
        local fences = house and house:FindFirstChild("Fences")
        local x0, x1, z0, z1
        for _, d in ipairs(fences and fences:GetDescendants() or {}) do
            if d:IsA("BasePart") then
                local p, s = d.Position, d.Size
                local ex = (math.abs(d.CFrame.RightVector.X) * s.X + math.abs(d.CFrame.UpVector.X) * s.Y + math.abs(d.CFrame.LookVector.X) * s.Z) / 2
                local ez = (math.abs(d.CFrame.RightVector.Z) * s.X + math.abs(d.CFrame.UpVector.Z) * s.Y + math.abs(d.CFrame.LookVector.Z) * s.Z) / 2
                x0 = math.min(x0 or p.X - ex, p.X - ex)
                x1 = math.max(x1 or p.X + ex, p.X + ex)
                z0 = math.min(z0 or p.Z - ez, p.Z - ez)
                z1 = math.max(z1 or p.Z + ez, p.Z + ez)
            end
        end
        local box = x0 and { x0 = x0, x1 = x1, z0 = z0, z1 = z1 } or nil
        -- a few loose fence pieces are not a fenced yard: then the plot's ground is the limit
        if not box or box.x1 - box.x0 < 20 or box.z1 - box.z0 < 20 then
            local gp = plot and plot:FindFirstChild("GroundParts")
            local g = gp and gp:FindFirstChild("Ground")
            if g and g:IsA("BasePart") then
                box = { x0 = g.Position.X - g.Size.X / 2, x1 = g.Position.X + g.Size.X / 2, z0 = g.Position.Z - g.Size.Z / 2, z1 = g.Position.Z + g.Size.Z / 2 }
            end
        end
        if box then
            bounds = { plot = plot, box = box }
        end
        return box
    end

    -- a table that sits in an opening of the fence is part of the food area: while a food
    -- on it is the target, that table's footprint counts as inside
    local extraZone
    local function inside(v, pad, mainOnly)
        local b = plotBounds()
        if not b or (v.X > b.x0 + pad and v.X < b.x1 - pad and v.Z > b.z0 + pad and v.Z < b.z1 - pad) then
            return true
        end
        local z = not mainOnly and extraZone or nil
        return z ~= nil and v.X > z.x0 + pad and v.X < z.x1 - pad and v.Z > z.z0 + pad and v.Z < z.z1 - pad
    end

    local function tableZone(food)
        local obj = food.Parent and food.Parent.Name == "ItemHolder" and food.Parent.Parent
        local x0, x1, z0, z1
        for _, d in ipairs(obj and obj:GetDescendants() or {}) do
            if d.Name == "PlaceAll" and d:IsA("BasePart") then
                local cf, s = d.CFrame, d.Size
                local ex = (math.abs(cf.RightVector.X) * s.X + math.abs(cf.UpVector.X) * s.Y + math.abs(cf.LookVector.X) * s.Z) / 2
                local ez = (math.abs(cf.RightVector.Z) * s.X + math.abs(cf.UpVector.Z) * s.Y + math.abs(cf.LookVector.Z) * s.Z) / 2
                x0 = math.min(x0 or cf.X - ex, cf.X - ex)
                x1 = math.max(x1 or cf.X + ex, cf.X + ex)
                z0 = math.min(z0 or cf.Z - ez, cf.Z - ez)
                z1 = math.max(z1 or cf.Z + ez, cf.Z + ez)
            end
        end
        return x0 and { x0 = x0 - 1.5, x1 = x1 + 1.5, z0 = z0 - 1.5, z1 = z1 + 1.5 } or nil
    end

    local function pathInside(p)
        for i, wp in ipairs(p:GetWaypoints()) do
            if i > 1 and not inside(wp.Position, 0.8) then
                return false
            end
        end
        return true
    end

    -- the player's control script resets Humanoid.Jump every frame (seen live: Jump = true did nothing),
    -- so the jump state is set directly
    local function hop(hum)
        hum.Jump = true
        if hum.FloorMaterial ~= Enum.Material.Air then
            hum:ChangeState(Enum.HumanoidStateType.Jumping)
        end
    end

    local function walkTo(goal, within)
        within = within or 2.5
        local hopped = false
        for _ = 1, 3 do
            local _, hum, root = getChar()
            if not hum then
                return false
            end
            if (flat(root.Position) - flat(goal)).Magnitude <= within then
                return true
            end
            local startIn = inside(root.Position, 0)
            local path
            for _, cfg in ipairs(AGENT_TRIES) do
                local p = PathfindingService:CreatePath(cfg)
                -- a path request can hang forever (seen live): give it 4 s, then count it as no path
                local done, ok = false, false
                local from = root.Position
                task.spawn(function()
                    ok = pcall(function()
                        p:ComputeAsync(from, goal)
                    end)
                    done = true
                end)
                local tc = os.clock()
                while not done and active() and os.clock() - tc < 4 do
                    task.wait(0.05)
                end
                ok = done and ok
                if ok and p.Status == Enum.PathStatus.Success and (not startIn or pathInside(p)) then
                    path = p
                    break
                end
                task.wait(0.1)
            end
            if not path then
                -- wedged between objects (no path from here): hop toward the goal once, over or onto
                -- what is in the way, then plan again from where it lands
                if hopped then
                    return false
                end
                hopped = true
                local dir = flat(goal) - flat(root.Position)
                dir = dir.Magnitude > 0.1 and dir.Unit or root.CFrame.LookVector
                hum:MoveTo(root.Position + dir * 4)
                hop(hum)
                local th = os.clock()
                while active() and os.clock() - th < 0.9 do
                    RunService.Heartbeat:Wait()
                end
                if not active() then
                    return false
                end
                continue
            end
            local wps = path:GetWaypoints()
            for i, wp in ipairs(wps) do
                if not active() then
                    return false
                end
                if i > 1 then
                    if wp.Action == Enum.PathWaypointAction.Jump then
                        hum.Jump = true
                    end
                    local finished, reached = false, false
                    local conn = hum.MoveToFinished:Connect(function(ok)
                        finished, reached = true, ok
                    end)
                    hum:MoveTo(wp.Position)
                    local t0, refPos, refT = os.clock(), root.Position, os.clock()
                    local jumps = 0
                    while active() and not finished and os.clock() - t0 < 3 do
                        local rp = root.Position
                        if i < #wps and (flat(rp) - flat(wp.Position)).Magnitude <= 1.8 then
                            reached = true
                            break
                        end
                        if os.clock() - refT > 0.8 then
                            if (flat(rp) - flat(refPos)).Magnitude < 0.5 then
                                -- blocked by objects: jump over or onto them (twice at most), then re-plan
                                if jumps >= 2 then
                                    break
                                end
                                jumps += 1
                                hum:MoveTo(wp.Position)
                                hop(hum)
                                t0 += 0.8
                            end
                            refPos, refT = rp, os.clock()
                        end
                        RunService.Heartbeat:Wait()
                    end
                    conn:Disconnect()
                    if not reached then
                        break
                    end
                end
            end
            local _, _, r2 = getChar()
            if r2 and (flat(r2.Position) - flat(goal)).Magnitude <= within + 0.5 then
                return true
            end
            task.wait(0.1)
        end
        return false
    end

    local function stopWalk()
        local _, hum, root = getChar()
        if hum and root then
            hum:MoveTo(root.Position)
        end
    end

    local function holding()
        local ok, n, isTray = pcall(function()
            local ES = JobHandler.Shared.EquipmentService
            local tray = ES:HasTray(LocalPlayer)
            if tray then
                local content = tray:FindFirstChild("_trayContent")
                return content and #content:GetChildren() or 0, true
            end
            local eq = ES:GetEquipped(LocalPlayer)
            if eq then
                local it = JobHandler.Items:GetItem(tostring(eq))
                if it and it.Type == "Food" then
                    return 1, false
                end
            end
            return 0, false
        end)
        if ok then
            return n, isTray
        end
        return 0, false
    end

    local function menuOf(obj)
        pcall(function()
            InteractionHandler:CloseMenu()
        end)
        local ok, m = pcall(function()
            return InteractionHandler:ShowMenu(obj)
        end)
        return ok and type(m) == "table" and m or nil
    end

    local function buttonIndex(menu, text, exact)
        for k, v in pairs(menu.Buttons) do
            local t = tostring(v.Text or ""):gsub("%[ICON:%d+%]", "")
            if exact and t == text or (not exact and t:find(text, 1, true)) then
                return k
            end
        end
    end

    local function closeMenu()
        pcall(function()
            InteractionHandler:CloseMenu()
        end)
    end

    local function standPoints(part)
        local char, _, root = getChar()
        local out = {}
        if not root then
            return out
        end
        local params = RaycastParams.new()
        params.FilterType = Enum.RaycastFilterType.Exclude
        params.FilterDescendantsInstances = { char }
        local pos = part.Position
        local skip = { char }
        -- food lying on the floor sits at ground height: ground just has to be below its top
        local groundBelow = onFloor(part) and pos.Y + 0.5 or pos.Y - 0.5
        local function floorFood(inst)
            local a = inst
            while a and a ~= plot do
                if a:IsA("BasePart") and onFloor(a) and foodData(a) then
                    return a
                end
                a = a.Parent
            end
        end
        -- the game lets you take food from about 10 studs, and tables are 15 wide: the
        -- middle of a table is only reachable from the aisle 8-9 studs away.
        -- One spot per side (the closest one), so a blocked side falls back to another.
        for a = 0, 315, 45 do
            local found, top, topR = false, nil, nil
            for _, r in ipairs({ 2.2, 3, 4, 5, 6, 7, 8, 8.75 }) do
                local x = pos.X + math.cos(math.rad(a)) * r
                local z = pos.Z + math.sin(math.rad(a)) * r
                -- other food on the floor is not ground: look through it
                local hit, ff
                for _ = 1, 6 do
                    hit = workspace:Raycast(Vector3.new(x, pos.Y + 1, z), Vector3.new(0, -16, 0), params)
                    ff = hit and floorFood(hit.Instance)
                    if hit and (hit.Instance:FindFirstAncestor("ItemHolder") or ff) then
                        table.insert(skip, ff or hit.Instance)
                        params.FilterDescendantsInstances = skip
                    else
                        break
                    end
                end
                if hit and hit.Position.Y < groundBelow and hit.Instance.CanCollide and not hit.Instance:FindFirstAncestor("ItemHolder") and not ff
                    and inside(hit.Position, 1, true) then
                    table.insert(out, { hit.Position, r * 100 + (hit.Position - root.Position).Magnitude })
                    found = true
                    break
                elseif not top and extraZone and hit and hit.Instance.Name == "PlaceAll" and math.abs(hit.Position.Y - pos.Y) < 0.6
                    and inside(hit.Position, 1) then
                    top = hit.Position
                    topR = r
                end
            end
            if not found and top then
                -- food on a table that fills a fence opening: stand on that table
                table.insert(out, { top, 1000 + topR * 100 + (top - root.Position).Magnitude })
            end
        end
        table.sort(out, function(p, q)
            return p[2] < q[2]
        end)
        return out
    end

    local function take(part)
        local before = holding()
        if before >= TRAY_MAX then
            return false, "full"
        end
        local sawTake = false
        for _ = 1, 3 do
            if not active() then
                return false, "stopped"
            end
            if not part.Parent then
                return true
            end
            local m = menuOf(part)
            local idx = m and buttonIndex(m, tr("I_Take", "Take"), true)
            if idx then
                sawTake = true
                status("Taking " .. part.Name)
                pcall(function()
                    m:Click(idx)
                end)
                local t0 = os.clock()
                while active() and os.clock() - t0 < (before > 0 and 2 or 3) do
                    if not part.Parent or holding() > before then
                        closeMenu()
                        task.wait(0.4 + math.random() * 0.3)
                        return true
                    end
                    task.wait(0.1)
                end
                if before > 0 and active() then
                    -- one take with no answer is not a full tray (a slow answer / food someone else took): the loop only
                    -- calls the tray full when two different foods are refused at the same count
                    closeMenu()
                    return false, "full"
                end
            else
                task.wait(0.3)
            end
            closeMenu()
        end
        return false, sawTake and "failed" or "range"
    end

    local function nearestFridge()
        local house = plot and plot:FindFirstChild("House")
        local _, _, root = getChar()
        if not (house and root) then
            return nil
        end
        local best, bd
        for _, group in ipairs(house:GetChildren()) do
            for _, obj in ipairs(group:GetChildren()) do
                if obj:FindFirstChild("AttachPos") then
                    local ok, isFridge = pcall(function()
                        local it = JobHandler.Items:GetItem(obj.Name)
                        return it and it:IsType("Fridge")
                    end)
                    if ok and isFridge then
                        local d = (obj:GetPivot().Position - root.Position).Magnitude
                        if not bd or d < bd then
                            best, bd = obj, d
                        end
                    end
                end
            end
        end
        return best
    end

    local function storeAll()
        local fridge = nearestFridge()
        if not fridge then
            status("No fridge found on that plot")
            task.wait(2)
            return false
        end
        status("Walking to the fridge")
        local ap = fridge:FindFirstChild("AttachPos")
        if not (ap and walkTo(ap.WorldPosition, 1.5)) then
            return false
        end
        local m = menuOf(fridge)
        local idx = m and buttonIndex(m, tr("I_Store", "Store"), false)
        if not idx then
            closeMenu()
            task.wait(0.5)
            return false
        end
        status("Storing the food")
        pcall(function()
            m:Click(idx)
        end)
        local t0 = os.clock()
        while active() and os.clock() - t0 < 2.5 do
            local all = buttonIndex(m, tr("I_StoreAll", "Store All"), false)
            if all then
                pcall(function()
                    m:Click(all)
                end)
                break
            end
            if holding() == 0 then
                break
            end
            task.wait(0.1)
        end
        t0 = os.clock()
        while active() and os.clock() - t0 < 60 do
            local weld = JobHandler.Shared.AttachService:GetAttachWeld(LocalPlayer.Character)
            if holding() == 0 and not weld then
                break
            end
            task.wait(0.2)
        end
        closeMenu()
        return holding() == 0
    end

    local function targets()
        local out = {}
        local now = os.clock()
        for _, p in ipairs(foods) do
            if selected[p] and p.Parent and not unreachable[p] and not (badUntil[p] and badUntil[p] > now) and p:GetAttribute("_updateModel") ~= -1 then
                table.insert(out, p)
            end
        end
        return out
    end

    -- on the plot = over its ground (250 x 250) or near it. Seen live: the House pivot sits at the plot's edge, so the old
    -- "within 160 studs of the House pivot" said "not at the plot" next to food on the far side (1364 of 1995 objects there)
    local function plotGround()
        local gp = plot and plot:FindFirstChild("GroundParts")
        local g = gp and gp:FindFirstChild("Ground")
        return g and g:IsA("BasePart") and g or nil
    end

    local function atPlot()
        if not plot then
            return false
        end
        local _, _, root = getChar()
        local g = plotGround()
        if not (root and g) then
            return false
        end
        local rel = g.CFrame:PointToObjectSpace(root.Position)
        return math.abs(rel.X) < g.Size.X / 2 + 40 and math.abs(rel.Z) < g.Size.Z / 2 + 40
    end

    -- walking only, never a teleport: toward the plot along pathfinding waypoints
    local function goToPlot()
        if os.clock() - toPlotAt < 3 then
            return
        end
        toPlotAt = os.clock()
        local g = plotGround()
        local _, _, root = getChar()
        if not (g and root) then
            status("Walk to " .. (target and target.DisplayName or "the") .. "'s plot")
            return
        end
        status("Walking to the plot")
        local c = g.Position
        local d = flat(root.Position) - flat(c)
        local edge = d.Magnitude > 1 and flat(c) + d.Unit * math.min(d.Magnitude, g.Size.X / 2 - 10) or flat(c)
        if not walkTo(Vector3.new(edge.X, g.Position.Y + 3, edge.Z), 4) and active() then
            status("Walk to " .. (target and target.DisplayName or "the") .. "'s plot (no path from here)")
        end
    end

    local function loop()
        local full = false
        while active() do
            local _, hum, root = getChar()
            if not (target and target.Parent and access[target]) then
                status("No access to that plot")
                task.wait(1)
            elseif not hum then
                status("Waiting for character")
                task.wait(1)
            elseif not atPlot() then
                if not plot then
                    watchPlot()
                end
                goToPlot()
                task.wait(0.5)
            else
                local list = targets()
                local held = holding()
                -- the tray holds 21: at 21 it goes to the fridge, it never tries to take a 22nd ("Your tray is full")
                if held >= TRAY_MAX then
                    full = true
                end
                -- food that is only skipped for a few seconds is still to be taken: the tray is not stored half full
                local waiting = false
                if #list == 0 and held > 0 and not full then
                    local now = os.clock()
                    for _, p in ipairs(foods) do
                        if selected[p] and p.Parent and not unreachable[p] and badUntil[p] and badUntil[p] > now then
                            waiting = true
                            break
                        end
                    end
                end
                if waiting then
                    status("Waiting to try the skipped food again (" .. held .. " on the tray)")
                    task.wait(0.5)
                elseif full or (#list == 0 and held > 0) then
                    if storeAll() then
                        full = false
                        trayMax = nil
                    else
                        task.wait(1)
                    end
                elseif #list > 0 then
                    local best, bd
                    for _, p in ipairs(list) do
                        local d = (p.Position - root.Position).Magnitude
                        if not bd or d < bd then
                            best, bd = p, d
                        end
                    end
                    status("Walking to the " .. best.Name)
                    local taken, why = false, "range"
                    local tries = 0
                    extraZone = (not inside(best.Position, 0)) and tableZone(best) or nil
                    local spots = standPoints(best)
                    if #spots == 0 then
                        -- no walkable spot inside the fence
                        unreachable[best] = inside(best.Position, 0) and "blocked" or "outside"
                    end
                    for _, sp in ipairs(spots) do
                        if not active() or tries >= 4 then
                            break
                        end
                        if walkTo(sp[1], 1.2) then
                            tries += 1
                            taken, why = take(best)
                            if taken or why ~= "range" then
                                break
                            end
                        end
                    end
                    extraZone = nil
                    if not taken and active() and not unreachable[best] then
                        if why == "full" then
                            -- trayMax here: { n = tray count, p = the food refused at it }; a second, different food
                            -- refused at the same count = the tray is full
                            local n = holding()
                            if type(trayMax) == "table" and trayMax.n == n and (trayMax.p ~= best or #list <= 1) then
                                full = true
                            else
                                trayMax = { n = n, p = best }
                                badUntil[best] = os.clock() + 5
                            end
                        else
                            -- every side was tried: after 3 rounds give up on it instead of looping
                            failCount[best] = (failCount[best] or 0) + 1
                            if failCount[best] >= 3 then
                                unreachable[best] = inside(best.Position, 0) and "blocked" or "outside"
                            else
                                badUntil[best] = os.clock() + 10
                            end
                        end
                    end
                else
                    local left, outsideN, blockedN = 0, 0, 0
                    for _, p in ipairs(foods) do
                        if selected[p] and p.Parent then
                            if unreachable[p] == "outside" then
                                outsideN += 1
                            elseif unreachable[p] then
                                blockedN += 1
                            else
                                left += 1
                            end
                        end
                    end
                    local skipText = (outsideN > 0 and (outsideN .. " skipped, outside the fence") or "")
                        .. (outsideN > 0 and blockedN > 0 and ", " or "")
                        .. (blockedN > 0 and (blockedN .. " skipped, no way to reach them") or "")
                    if left == 0 and outsideN + blockedN == 0 then
                        status("All selected food is stored")
                    elseif left == 0 then
                        status("Stored everything it can reach: " .. skipText)
                    else
                        status("Can't reach " .. left .. " selected food, trying again" .. (skipText ~= "" and (", " .. skipText) or ""))
                    end
                    task.wait(1)
                end
            end
            task.wait()
        end
    end

    local function setToggle(v)
        if storeToggle then
            withUiIdentity(function()
                storeToggle:Set(v)
            end)
        end
    end

    local function stop(reason)
        storing = false
        stopWalk()
        closeMenu()
        local ok, weld = pcall(function()
            return JobHandler.Shared.AttachService:GetAttachWeld(LocalPlayer.Character)
        end)
        if ok and weld and weld.Part1 and plot and weld.Part1:IsDescendantOf(plot) then
            pcall(function()
                JobHandler.Modules.CharacterHandler:Detach()
            end)
        end
        status(reason or "Idle")
        if running and not finishing and holding() > 0 and target and target.Parent and access[target] and plot then
            finishing = true
            task.spawn(function()
                pcall(storeAll)
                finishing = false
                if not storing then
                    stopWalk()
                    status(reason or "Idle")
                    if uiDirty then
                        scheduleRefresh()
                    end
                end
            end)
        elseif uiDirty then
            scheduleRefresh()
        end
    end

    local function showTarget(on)
        for _, f in ipairs({ foodFrame, espFrame, storeFrame, statusFrame }) do
            if f then
                f.Visible = on
            end
        end
    end

    local function setTarget(plr)
        if target == plr then
            return
        end
        if storing then
            stop("Idle")
            setToggle(false)
        end
        target = plr
        table.clear(selected)
        table.clear(badUntil)
        table.clear(unreachable)
        table.clear(failCount)
        table.clear(labelStore)
        table.clear(labelSeq)
        table.clear(known)
        table.clear(deselectedKinds)
        syncESP()
        showTarget(plr ~= nil)
        watchPlot()
    end

    local function refreshPlayers()
        local list = {}
        for plr in pairs(access) do
            if plr.Parent then
                table.insert(list, plr)
            end
        end
        table.sort(list, function(a, b)
            return a.DisplayName:lower() < b.DisplayName:lower()
        end)
        local labels, key = {}, {}
        table.clear(playerByLabel)
        for _, plr in ipairs(list) do
            local label = labelFor(plr)
            playerByLabel[label] = plr
            table.insert(labels, label)
            table.insert(key, label)
        end
        local sig = table.concat(key, "|")
        if sig ~= lastOptions then
            lastOptions = sig
            if playerDD then
                suppress = true
                withUiIdentity(function()
                    playerDD:Refresh(labels)
                    if not (target and access[target]) then
                        playerDD:Set({})
                    end
                end)
                suppress = false
                decoratePlayers()
            end
        end
        if playerFrame then
            playerFrame.Visible = #list > 0
        end
        -- while Auto Store runs the target is kept (the loop waits for access), it never turns itself off
        if target and not (target.Parent and access[target]) and not (storing or finishing) then
            setTarget(nil)
        end
    end

    local function pollAccess()
        for _, plr in ipairs(Players:GetPlayers()) do
            if plr ~= LocalPlayer then
                local lvl = levelOf(plr)
                local new = lvl and lvl >= ROOMMATE and lvl < OWNER and lvl or nil
                local old = access[plr]
                if new and not old then
                    notify(plr, levelName(new) .. " access given", labelFor(plr) .. " gave you " .. levelName(new) .. " access")
                elseif new and old and new ~= old then
                    notify(plr, "Access changed", labelFor(plr) .. " changed your access: " .. levelName(old) .. " -> " .. levelName(new))
                elseif old and not new then
                    notify(plr, "Access removed", labelFor(plr) .. " took away your access" .. (lvl and (" (now " .. levelName(lvl) .. ")") or ""))
                end
                -- no answer (permissions not loaded / the call failed) is not a removal: only a real level changes it
                if lvl then
                    access[plr] = new
                end
            end
        end
    end

    -- access gone: Auto Store stays on and waits ("No access to that plot") until it is back
    local function onAccessLost(plr)
        if plr == target and (storing or finishing) then
            stopWalk()
            closeMenu()
        end
    end

    function M.shutdown()
        generation += 1
        storing, finishing, espOn = false, false, false
        stopWalk()
        closeMenu()
        syncESP()
        for _, c in ipairs(plotConns) do
            pcall(function()
                c:Disconnect()
            end)
        end
        table.clear(plotConns)
        for _, c in ipairs(inputConns) do
            pcall(function()
                c:Disconnect()
            end)
        end
        table.clear(inputConns)
        if espFolder then
            espFolder:Destroy()
            espFolder = nil
        end
    end

    function M.buildUI(StoreTab)
        local page
        for _, root in ipairs({ gethui and gethui() or CoreGui, CoreGui }) do
            local rf = root:FindFirstChild("Rayfield")
            local el = rf and rf:FindFirstChild("Main") and rf.Main:FindFirstChild("Elements")
            page = page or (el and el:FindFirstChild("Auto Store"))
        end
        local function add(create)
            local before = {}
            for _, c in ipairs(page and page:GetChildren() or {}) do
                before[c] = true
            end
            local obj = create()
            local frame
            for _, c in ipairs(page and page:GetChildren() or {}) do
                if not before[c] and c:IsA("GuiObject") then
                    frame = c
                end
            end
            return obj, frame
        end
        playerDD, playerFrame = add(function()
            return StoreTab:CreateDropdown({
                Name = "Player who gave you access",
                Options = {},
                CurrentOption = {},
                MultipleOptions = false,
                Flag = "LFJ_SharedPlayer",
                Callback = function(option)
                    if suppress then
                        return
                    end
                    local label = type(option) == "table" and option[1] or option
                    local plr = label and playerByLabel[label]
                    if plr and access[plr] then
                        setTarget(plr)
                    end
                end,
            })
        end)
        foodDD, foodFrame = add(function()
            return StoreTab:CreateDropdown({
                Name = "Food on their plot",
                Options = {},
                CurrentOption = {},
                MultipleOptions = true,
                Flag = "LFJ_SharedFood",
                Callback = function(option)
                    if suppress then
                        return
                    end
                    local opts = type(option) == "table" and option or { option }
                    local set, wantAll, wantNone = {}, false, false
                    for _, label in ipairs(opts) do
                        if label == SELECT_ALL then
                            wantAll = true
                        elseif label == DESELECT_ALL then
                            wantNone = true
                        else
                            set[label] = true
                        end
                    end
                    if wantAll or wantNone then
                        selectAll(wantAll)
                        return
                    end
                    for _, p in ipairs(foods) do
                        local now = set[labelOf[p]] == true
                        if selected[p] and not now then
                            deselectedKinds[p.Name] = true
                        elseif now and not selected[p] then
                            deselectedKinds[p.Name] = nil
                        end
                        selected[p] = now or nil
                    end
                    syncESP()
                end,
            })
        end)
        espToggle, espFrame = add(function()
            return StoreTab:CreateToggle({
                Name = "Food ESP",
                CurrentValue = false,
                Flag = "LFJ_SharedESP",
                Callback = function(value)
                    espOn = value
                    syncESP()
                    updateHover()
                end,
            })
        end)
        storeToggle, storeFrame = add(function()
            return StoreTab:CreateToggle({
                Name = "Auto Store",
                CurrentValue = false,
                Flag = "LFJ_SharedRun",
                Callback = function(value)
                    if value then
                        if storing or not (target and access[target]) then
                            if not (target and access[target]) then
                                setToggle(false)
                            end
                            return
                        end
                        storing = true
                        task.spawn(function()
                            -- an error never turns it off: the loop starts again until the toggle is turned off
                            while storing and running do
                                local ok, err = pcall(loop)
                                if not ok then
                                    warn("[Legit Farm Job] auto store (shared): " .. tostring(err))
                                    status("Error, retrying")
                                    stopWalk()
                                    closeMenu()
                                    task.wait(1)
                                end
                            end
                        end)
                    elseif storing then
                        stop("Idle")
                    end
                end,
            })
        end)
        statusLabel, statusFrame = add(function()
            return StoreTab:CreateLabel("Status: Idle")
        end)
        showTarget(false)
        if playerFrame then
            playerFrame.Visible = false
        end

        local lastMove = 0
        table.insert(inputConns, UserInputService.InputChanged:Connect(function(input)
            if espOn and input.UserInputType == Enum.UserInputType.MouseMovement then
                local now = os.clock()
                if now - lastMove > 0.04 then
                    lastMove = now
                    updateHover()
                end
            end
        end))
        table.insert(inputConns, UserInputService.InputBegan:Connect(function(input)
            if espOn and hovered and input.UserInputType == Enum.UserInputType.MouseButton1
                and (UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) or UserInputService:IsKeyDown(Enum.KeyCode.RightControl)) then
                updateHover()
                if hovered then
                    deselect(hovered)
                end
            end
        end))
        table.insert(inputConns, Players.PlayerRemoving:Connect(function(plr)
            if access[plr] then
                notify(plr, "Access ended", labelFor(plr) .. " left the game")
                access[plr] = nil
                onAccessLost(plr)
                refreshPlayers()
            end
        end))

        local myGeneration = generation
        task.spawn(function()
            while running and generation == myGeneration do
                local before = target
                local ok, err = pcall(pollAccess)
                if not ok then
                    warn("[Legit Farm Job] access check: " .. tostring(err))
                end
                if before and not access[before] then
                    onAccessLost(before)
                end
                pcall(refreshPlayers)
                task.wait(1)
            end
        end)
    end

    return M
end)()

-- Pizza Planet - Pizza Baker
NC.pizza = (function()
    local P = {}
    local TOPPING = { Ham = 4, Pepperoni = 5, Vegetable = 6 }
    local AGENTS = {
        { AgentRadius = 1, AgentHeight = 4, AgentCanJump = false },
        { AgentRadius = 0.5, AgentHeight = 4, AgentCanJump = false },
    }
    local STAND_OFFSETS = {
        Vector3.new(-6.5, 0, -5.3), Vector3.new(-5.5, 0, -4.3), Vector3.new(-7.5, 0, -6.3),
        Vector3.new(-6.5, 0, -3.3), Vector3.new(-4.5, 0, -6.3),
    }
    local outerSetStatus = setStatus
    local function setStatus(text)
        if farming then
            outerSetStatus(text)
        end
    end
    local lastProgress = os.clock()
    local standOf, crateStandOf, busyUntil, restockOff, lastWarn = {}, {}, {}, {}, {}

    local function alive()
        return running and farming and isWorkingJob(PIZZA_ID)
    end

    local function progress()
        lastProgress = os.clock()
    end

    local function pause(a, b)
        local t = a + math.random() * (b - a)
        local t0 = os.clock()
        while os.clock() - t0 < t and running and farming do
            task.wait(0.03)
        end
    end

    local function waitUntil(cond, timeout)
        local t0 = os.clock()
        while alive() and os.clock() - t0 < timeout do
            if cond() then
                return true
            end
            task.wait(0.05)
        end
        return cond()
    end

    local function warnOnce(key, text)
        if not lastWarn[key] or os.clock() - lastWarn[key] > 30 then
            lastWarn[key] = os.clock()
            warn("[Legit Farm Job] pizza: " .. text)
        end
    end

    local function unsafe()
        farming = false
        if FarmToggle then
            withUiIdentity(function()
                FarmToggle:Set(false)
            end)
        end
        outerSetStatus("Stopped: unsafe pizza state")
    end

    local function fd(a, b)
        return Vector2.new(a.X - b.X, a.Z - b.Z).Magnitude
    end

    local function jobModule()
        local ok, mod = pcall(function()
            return JobHandler:GetCurJobModule()
        end)
        return ok and type(mod) == "table" and mod or nil
    end

    -- the shift ends when the player is further than ShiftRadius from the AreaBlock, so every point stays well inside it
    local function inArea(p, margin)
        local mod = jobModule()
        local ab = mod and mod.AreaBlock
        local r = mod and mod.ShiftRadius
        if not (ab and r) then
            return false
        end
        return (ab.Position - (p + Vector3.new(0, 3.5, 0))).Magnitude <= r - margin
    end

    local function kitchen()
        local mod = jobModule()
        local model = mod and mod.Model
        if typeof(model) ~= "Instance" then
            model = workspace:FindFirstChild("Environment")
            for _, n in ipairs({ "Locations", "City", "PizzaPlanet" }) do
                model = model and model:FindFirstChild(n)
            end
        end
        local interior = model and model:FindFirstChild("Interior")
        if not interior then
            return nil
        end
        return interior:FindFirstChild("BakerWorkstations"), interior:FindFirstChild("IngredientCrates"), model
    end

    local function floorAt(x, z)
        local params = RaycastParams.new()
        params.FilterType = Enum.RaycastFilterType.Exclude
        params.FilterDescendantsInstances = { LocalPlayer.Character }
        local hit = workspace:Raycast(Vector3.new(x, 8, z), Vector3.new(0, -12, 0), params)
        return hit and hit.Position.Y or nil
    end

    local function planPath(root, target)
        for _, cfg in ipairs(AGENTS) do
            local path = PathfindingService:CreatePath(cfg)
            local ok = pcall(function()
                path:ComputeAsync(root.Position, target)
            end)
            if ok and path.Status == Enum.PathStatus.Success then
                local wps = path:GetWaypoints()
                local good = #wps > 0
                for _, wp in ipairs(wps) do
                    if wp.Action == Enum.PathWaypointAction.Jump or not inArea(wp.Position, 5) then
                        good = false
                        break
                    end
                end
                if good then
                    return wps
                end
            end
            task.wait(0.05)
        end
    end

    local function walkTo(target)
        for _ = 1, 3 do
            local _, hum, root = getChar()
            if not hum then
                return false
            end
            if fd(root.Position, target) < 1.5 then
                return true
            end
            local wps = planPath(root, target)
            if not wps then
                return false
            end
            local blocked = false
            for i, wp in ipairs(wps) do
                if not alive() then
                    return false
                end
                if i > 1 then
                    hum:MoveTo(wp.Position)
                    local t0 = os.clock()
                    local ref, refT = root.Position, t0
                    while alive() and os.clock() - t0 < 4 do
                        if fd(root.Position, wp.Position) <= 1.5 then
                            break
                        end
                        if os.clock() - refT > 0.8 then
                            if fd(root.Position, ref) < 0.5 then
                                blocked = true
                                break
                            end
                            ref, refT = root.Position, os.clock()
                        end
                        RunService.Heartbeat:Wait()
                    end
                    if blocked then
                        break
                    end
                end
            end
            progress()
            if not blocked and fd(root.Position, target) < 3 then
                return true
            end
        end
        return false
    end

    local function standPoint(w, root)
        if standOf[w] then
            return standOf[w]
        end
        local ctr = w.CounterTop.Position
        for _, off in ipairs(STAND_OFFSETS) do
            local x, z = ctr.X + off.X, ctr.Z + off.Z
            local y = floorAt(x, z)
            if y and y < 2 then
                local p = Vector3.new(x, y, z)
                if planPath(root, p) then
                    standOf[w] = p
                    return p
                end
            end
        end
    end

    local function crateStand(crate, root)
        if crateStandOf[crate] then
            return crateStandOf[crate]
        end
        local pos = crate:GetPivot().Position
        for k = 0, 7 do
            local a = k * math.pi / 4
            local x, z = pos.X + math.cos(a) * 4.5, pos.Z + math.sin(a) * 4.5
            local y = floorAt(x, z)
            if y and y < 2 then
                local p = Vector3.new(x, y, z)
                if planPath(root, p) then
                    crateStandOf[crate] = p
                    return p
                end
            end
        end
    end

    -- the game's own interaction callbacks (registered per Ingredients model: 1 Dough, 2 Sauce, 3 Cheese, 4 Ham, 5 Pepperoni,
    -- 6 Vegetables, 7 Restock; a crate has one: I_Take)
    local function callGen(obj, index)
        local reg = getInteractRegistry()
        local entry = reg and obj and reg[obj]
        local gens = entry and entry[1]
        local gen = type(gens) == "table" and gens[index]
        if type(gen) ~= "function" then
            return false
        end
        local ok, text, _, cb = pcall(gen)
        if not (ok and text and type(cb) == "function") then
            return false
        end
        if not cleanSafe(cb) then
            unsafe()
            return false
        end
        pcall(cb)
        return true
    end

    local function pressDone(w)
        local display = w:FindFirstChild("OrderDisplay")
        local main = display and display:FindFirstChild("DisplayMain")
        local gui = main and main:FindFirstChild("BakerGUI")
        local frame = gui and gui:FindFirstChild("Frame")
        local btn = frame and frame:FindFirstChild("Done")
        if not btn then
            return false
        end
        for _, c in ipairs(getconnections(btn.Activated)) do
            local fn = c.Function
            if type(fn) == "function" then
                if not cleanSafe(fn) then
                    unsafe()
                    return false
                end
                pcall(fn)
                return true
            end
        end
        return false
    end

    local function orderOf(w)
        local o = w:FindFirstChild("Order")
        return o and o.Value or ""
    end

    local function leftOf(w)
        local o = w:FindFirstChild("Order")
        local l = o and o:FindFirstChild("IngredientsLeft")
        return l and l.Value or 0
    end

    local function pending(w)
        local v = orderOf(w)
        return v ~= "" and v ~= "true" and v ~= "false"
    end

    local function shown(w, name)
        local p = w:FindFirstChild("Pizza")
        local part = p and p:FindFirstChild(name)
        return part ~= nil and part.Transparency < 0.5
    end

    local function holding()
        local ok, e = pcall(function()
            return JobHandler.Shared.EquipmentService:GetEquipped(LocalPlayer)
        end)
        return ok and e ~= nil and tostring(e) == "Ingredient Crate"
    end

    local function dropCrate()
        if holding() then
            pcall(function()
                JobHandler.Shared.EquipmentService:UnequipItem(LocalPlayer, "Ingredient Crate")
            end)
        end
    end

    local function otherUser(w)
        local iu = w:FindFirstChild("InUse")
        local u = iu and iu.Value
        if typeof(u) == "Instance" and u:IsA("Player") and u ~= LocalPlayer and u.Parent == Players then
            local r = u.Character and u.Character:FindFirstChild("HumanoidRootPart")
            if r and (r.Position - w.CounterTop.Position).Magnitude < 16 then
                return u
            end
        end
    end

    local function crowded(p)
        for _, plr in ipairs(Players:GetPlayers()) do
            if plr ~= LocalPlayer then
                local r = plr.Character and plr.Character:FindFirstChild("HumanoidRootPart")
                if r and fd(r.Position, p) < 3 then
                    return true
                end
            end
        end
        return false
    end

    -- another player working at a station: the game marks it in InUse, and a player standing at the baker side is seen as well
    local function userOf(w)
        local u = otherUser(w)
        if u then
            return u
        end
        local sp = standOf[w]
        if sp then
            for _, plr in ipairs(Players:GetPlayers()) do
                if plr ~= LocalPlayer then
                    local r = plr.Character and plr.Character:FindFirstChild("HumanoidRootPart")
                    if r and fd(r.Position, sp) < 5 and math.abs(r.Position.Y - sp.Y) < 6 then
                        return plr
                    end
                end
            end
        end
    end

    local function makePizza(w)
        local order = orderOf(w)
        local topIdx = TOPPING[order]
        if order ~= "Cheese" and not topIdx then
            return false, "unknown order " .. tostring(order)
        end
        local ing = w:FindFirstChild("Ingredients")
        if not ing then
            return false, "no ingredients"
        end
        if shown(w, "Dough") then
            callGen(ing, 1) -- the dough button toggles: an unfinished selection is cleared
            waitUntil(function()
                return not shown(w, "Dough")
            end, 2)
            if shown(w, "Dough") then
                return false, "could not clear the pizza"
            end
        end
        local steps = {
            { 1, "Dough", "Adding the dough" },
            { 2, "Sauce", "Adding the tomato sauce" },
            { 3, "Cheese", "Adding the cheese" },
        }
        if topIdx then
            steps[4] = { topIdx, order, "Adding the " .. order:lower() }
        end
        setStatus("Making a " .. order .. " pizza")
        for n, s in ipairs(steps) do
            if not alive() then
                return false, "stopped"
            end
            if orderOf(w) ~= order then
                return false, "the order changed"
            end
            local user = userOf(w)
            if user then
                return false, "used by " .. user.DisplayName
            end
            setStatus(s[3])
            if not callGen(ing, s[1]) then
                return false, "step " .. s[2] .. " not available"
            end
            if not waitUntil(function()
                return shown(w, s[2])
            end, 2.5) then
                return false, s[2] .. " was not added"
            end
            progress()
            if n < #steps then
                pause(0.4, 0.8)
            end
        end
        if not alive() then
            return false, "stopped"
        end
        pause(0.9, 1.1)
        local before = leftOf(w)
        setStatus("Submitting the " .. order .. " pizza")
        if not pressDone(w) then
            return false, "no Done button"
        end
        local result
        local t0 = os.clock()
        while alive() and os.clock() - t0 < 4 do
            local v = orderOf(w)
            if v == "true" or v == "false" then
                result = v
                break
            end
            task.wait(0.05)
        end
        waitUntil(function()
            local v = orderOf(w)
            return v ~= "true" and v ~= "false"
        end, 4)
        progress()
        if result == "true" or (result == nil and leftOf(w) < before) then
            return true
        end
        return false, result == "false" and "the pizza was not accepted" or "no answer"
    end

    local function restock(w, name)
        local before = leftOf(w)
        local _, crates = kitchen()
        local _, _, root = getChar()
        if not (crates and root) then
            return false, "no kitchen"
        end
        if not holding() then
            setStatus("Getting an Ingredient Crate")
            local list = {}
            for _, c in ipairs(crates:GetChildren()) do
                table.insert(list, { c = c, d = (c:GetPivot().Position - root.Position).Magnitude })
            end
            table.sort(list, function(a, b)
                return a.d < b.d
            end)
            local got = false
            for i = 1, math.min(#list, 3) do
                if not alive() then
                    return false, "stopped"
                end
                local c = list[i].c
                local sp = c.Parent == crates and crateStand(c, root)
                if sp and walkTo(sp) then
                    pause(0.2, 0.5)
                    if callGen(c, 1) and waitUntil(holding, 3) then
                        got = true
                        break
                    end
                end
            end
            if not got then
                return false, "no crate"
            end
        end
        setStatus("Restocking " .. name)
        local _, _, root2 = getChar()
        local sp = root2 and standPoint(w, root2)
        if not (sp and walkTo(sp)) then
            dropCrate()
            return false, "no path"
        end
        pause(0.2, 0.5)
        callGen(w:FindFirstChild("Ingredients"), 7)
        local ok = waitUntil(function()
            return leftOf(w) > before
        end, 4)
        dropCrate()
        progress()
        return ok, ok and nil or "the stock did not change"
    end

    local function serve(w, name)
        local _, _, root = getChar()
        if not root then
            return
        end
        local sp = standPoint(w, root)
        if not sp then
            setStatus("No path to " .. name)
            busyUntil[w] = os.clock() + 8
            return
        end
        if crowded(sp) then
            setStatus("Someone is next to " .. name .. ", waiting")
            busyUntil[w] = os.clock() + 3
            return
        end
        setStatus("Walking to " .. name)
        if not walkTo(sp) then
            busyUntil[w] = os.clock() + 5
            return
        end
        local user = userOf(w)
        if user then
            setStatus("Station is used by " .. user.DisplayName .. ", waiting")
            busyUntil[w] = os.clock() + 3
            return
        end
        if leftOf(w) < 1 then
            local ok, why = restock(w, name)
            if not ok then
                setStatus("Restock problem (" .. tostring(why) .. ")")
                warnOnce("restock" .. name, "restock of " .. name .. " failed: " .. tostring(why))
                busyUntil[w] = os.clock() + 6
                return
            end
        end
        if not alive() or not pending(w) then
            return
        end
        local ok, why = makePizza(w)
        if not ok then
            if alive() then
                setStatus("Pizza problem (" .. tostring(why) .. ")")
                warnOnce("make" .. name, name .. ": " .. tostring(why))
                busyUntil[w] = os.clock() + 4
            end
            return
        end
        if leftOf(w) < 1 and not (restockOff[w] and os.clock() < restockOff[w]) then
            local ok2 = restock(w, name)
            if not ok2 and leftOf(w) >= 1 then
                restockOff[w] = os.clock() + 90
            end
        end
    end

    function P.step()
        if not farming then
            task.wait(0.3)
            return
        end
        if not isWorkingJob(PIZZA_ID) then
            setStatus("Start the Pizza Planet - Pizza Baker job first")
            task.wait(1)
            return
        end
        local _, hum, root = getChar()
        if not hum then
            setStatus("Waiting for character")
            task.wait(1)
            return
        end
        local stations, _, model = kitchen()
        if not stations then
            setStatus("Waiting for the kitchen")
            task.wait(1)
            return
        end
        if os.clock() - lastProgress > 60 then
            setStatus("Stuck, resetting")
            dropCrate()
            table.clear(busyUntil)
            table.clear(restockOff)
            table.clear(standOf)
            table.clear(crateStandOf)
            local spot = model and model:FindFirstChild("WorkTeleport_PizzaPlanetBaker")
            if spot then
                walkTo(Vector3.new(spot.Position.X, spot.Position.Y, spot.Position.Z))
            end
            progress()
            task.wait(1)
            return
        end
        local now = os.clock()
        local list, usedBy = {}, nil
        for i, w in ipairs(stations:GetChildren()) do
            if pending(w) and not (busyUntil[w] and busyUntil[w] > now) then
                local u = userOf(w)
                if u then
                    usedBy = "Station " .. i .. " is used by " .. u.DisplayName
                else
                    table.insert(list, { w = w, i = i, d = (w.CounterTop.Position - root.Position).Magnitude })
                end
            end
        end
        if #list == 0 then
            setStatus(usedBy or "Waiting for orders")
            progress()
            task.wait(0.5)
            return
        end
        table.sort(list, function(a, b)
            return a.d < b.d
        end)
        serve(list[1].w, "station " .. list[1].i)
        task.wait(0.1)
    end

    function P.stop()
        pcall(dropCrate)
        table.clear(busyUntil)
        table.clear(restockOff)
        table.clear(standOf)
        table.clear(crateStandOf)
        progress()
    end

    return P
end)()

-- Teacher - High School
NC.teacher = (function()
    local T = {}
    local TASK = { DISCIPLINE = 1, HALL_PASS = 2, LECTURE = 3 }
    -- a wide agent that never jumps: the path keeps clear of desk corners and never goes over furniture
    local AGENTS = {
        { AgentRadius = 2.5, AgentHeight = 5, AgentCanJump = false },
        { AgentRadius = 2, AgentHeight = 5, AgentCanJump = false },
        { AgentRadius = 1.5, AgentHeight = 5, AgentCanJump = false },
    }
    local outerSetStatus = setStatus
    local function setStatus(text)
        if farming then
            outerSetStatus(text)
        end
    end
    local lastProgress = os.clock()
    local floorRef
    local seenAt, badUntil, warned = {}, {}, {}
    local hooked, origShapes, shapesModule
    local autoJumpWas

    local function alive()
        return running and farming and isWorkingJob(TEACHER_ID)
    end

    local function progress()
        lastProgress = os.clock()
    end

    local function pause(a, b)
        local t = a + math.random() * (b - a)
        local t0 = os.clock()
        while os.clock() - t0 < t and running and farming do
            task.wait(0.03)
        end
    end

    local function waitUntil(cond, timeout)
        local t0 = os.clock()
        while alive() and os.clock() - t0 < timeout do
            if cond() then
                return true
            end
            task.wait(0.05)
        end
        return cond()
    end

    local function warnOnce(key, text)
        if not warned[key] or os.clock() - warned[key] > 30 then
            warned[key] = os.clock()
            warn("[Legit Farm Job] teacher: " .. text)
        end
    end

    local function unsafe()
        farming = false
        if FarmToggle then
            withUiIdentity(function()
                FarmToggle:Set(false)
            end)
        end
        outerSetStatus("Stopped: unsafe teacher state")
    end

    local function fd(a, b)
        return Vector2.new(a.X - b.X, a.Z - b.Z).Magnitude
    end

    local function gameplay()
        local n = workspace:FindFirstChild("Environment")
        for _, name in ipairs({ "Locations", "SchoolArea", "School", "Interior", "Floor2", "Teacher1", "Interior", "Gameplay" }) do
            n = n and n:FindFirstChild(name)
        end
        return n
    end

    local function areaBlock()
        local ok, mod = pcall(function()
            return JobHandler:GetCurJobModule()
        end)
        if ok and type(mod) == "table" and mod.AreaBlock and mod.ShiftRadius then
            return mod.AreaBlock, mod.ShiftRadius
        end
    end

    -- inside the classroom box and well inside the shift radius (the shift ends further out)
    local function inRoom(p)
        local ab, radius = areaBlock()
        if not ab then
            return false
        end
        local v = ab.CFrame:Inverse() * p
        return math.abs(v.X) <= ab.Size.X * 0.5 + 2 and math.abs(v.Z) <= ab.Size.Z * 0.5 + 2
            and (ab.Position - (p + Vector3.new(0, 3.5, 0))).Magnitude <= radius - 5
    end

    local function castParams()
        local params = RaycastParams.new()
        params.FilterType = Enum.RaycastFilterType.Exclude
        local ignore = {}
        for _, plr in ipairs(Players:GetPlayers()) do
            if plr.Character then
                table.insert(ignore, plr.Character)
            end
        end
        local G = gameplay()
        local desks = G and G:FindFirstChild("Desks")
        if desks then
            for _, d in ipairs(desks:GetChildren()) do
                local npc = d:FindFirstChild("NPC")
                if npc then
                    table.insert(ignore, npc)
                end
            end
        end
        params.FilterDescendantsInstances = ignore
        return params
    end

    local function floorAt(x, z, params)
        local hit = workspace:Raycast(Vector3.new(x, (floorRef or 44) + 6, z), Vector3.new(0, -12, 0), params)
        return hit and hit.Position or nil
    end

    -- the body of the character (about 1.8 wide) moved from one waypoint to the next: any solid hit means a desk or chair is in the way
    local function blockedBetween(params, a, b)
        local d = b - a
        if d.Magnitude < 0.05 then
            return false
        end
        local ok, hit = pcall(function()
            return workspace:Blockcast(CFrame.new(a + Vector3.new(0, 1.8, 0)), Vector3.new(3, 2.6, 3), d, params)
        end)
        return not ok or (hit ~= nil and hit.Instance.CanCollide)
    end

    -- a path is only used when it is flat, jump free, inside the room and nothing solid is between two waypoints
    local function pathGood(wps, params)
        if #wps == 0 then
            return false
        end
        for i, wp in ipairs(wps) do
            if wp.Action == Enum.PathWaypointAction.Jump or not inRoom(wp.Position) then
                return false
            end
            if i > 1 and floorRef and math.abs(wp.Position.Y - floorRef) > 0.9 then
                return false
            end
            if i > 1 and blockedBetween(params, wps[i - 1].Position, wp.Position) then
                return false
            end
        end
        return true
    end

    local function planPath(from, target)
        local params = castParams()
        for _, cfg in ipairs(AGENTS) do
            local path = PathfindingService:CreatePath(cfg)
            local ok = pcall(function()
                path:ComputeAsync(from, target)
            end)
            if ok and path.Status == Enum.PathStatus.Success then
                local wps = path:GetWaypoints()
                if pathGood(wps, params) then
                    return wps
                end
            end
            task.wait(0.05)
        end
    end

    -- free floor points in the aisles between the desk rows and columns: a path that is blocked directly is tried through one of them
    local function buildHubs(desks)
        local xs, zs, seenX, seenZ = {}, {}, {}, {}
        for _, d in ipairs(desks:GetChildren()) do
            local o = d:FindFirstChild("Origin")
            if o then
                local x, z = math.floor(o.Position.X + 0.5), math.floor(o.Position.Z + 0.5)
                if not seenX[x] then
                    seenX[x] = true
                    table.insert(xs, o.Position.X)
                end
                if not seenZ[z] then
                    seenZ[z] = true
                    table.insert(zs, o.Position.Z)
                end
            end
        end
        table.sort(xs)
        table.sort(zs)
        local hx, hz = { xs[1] - 4.75 }, { zs[1] - 4.5 }
        for i = 1, #xs - 1 do
            table.insert(hx, (xs[i] + xs[i + 1]) / 2)
        end
        for i = 1, #zs - 1 do
            table.insert(hz, (zs[i] + zs[i + 1]) / 2)
        end
        table.insert(hx, xs[#xs] + 4.75)
        table.insert(hz, zs[#zs] + 4.5)
        local params = castParams()
        local hubs = {}
        for _, x in ipairs(hx) do
            for _, z in ipairs(hz) do
                local p = floorAt(x, z, params)
                if p and math.abs(p.Y - floorRef) <= 0.9 and inRoom(p) then
                    table.insert(hubs, p)
                end
            end
        end
        return hubs
    end

    local hubs

    local function viaHub(from, target)
        if not hubs then
            return nil
        end
        local list = {}
        for _, h in ipairs(hubs) do
            table.insert(list, { h = h, s = fd(from, h) + fd(h, target) })
        end
        table.sort(list, function(a, b)
            return a.s < b.s
        end)
        for i = 1, math.min(#list, 6) do
            local w1 = planPath(from, list[i].h)
            if w1 then
                local w2 = planPath(list[i].h, target)
                if w2 then
                    return w1, w2
                end
            end
        end
    end

    local elevated

    local function followPath(wps, abort)
        local _, hum, root = getChar()
        if not hum then
            return "stopped"
        end
        for i, wp in ipairs(wps) do
            if not alive() or (abort and abort()) then
                return "stopped"
            end
            if i > 1 then
                hum:MoveTo(wp.Position)
                local t0 = os.clock()
                local ref, refT = root.Position, t0
                while alive() and os.clock() - t0 < 4 do
                    if fd(root.Position, wp.Position) <= 1.5 then
                        break
                    end
                    if abort and abort() then
                        return "stopped"
                    end
                    -- never on or against furniture: climbing or standing higher than the floor means stop at once
                    if elevated() then
                        hum:MoveTo(root.Position)
                        return "blocked"
                    end
                    if os.clock() - refT > 0.8 then
                        if fd(root.Position, ref) < 0.5 then
                            return "blocked"
                        end
                        ref, refT = root.Position, os.clock()
                    end
                    RunService.Heartbeat:Wait()
                end
            end
        end
        progress()
        return "done"
    end

    local function attached()
        local ok, weld = pcall(function()
            return JobHandler.Shared.AttachService:GetAttachWeld(LocalPlayer.Character)
        end)
        return ok and weld ~= nil
    end

    -- on or against furniture: climbing, or standing higher than the floor allows (the board holds the character higher on purpose)
    function elevated()
        local _, hum, root = getChar()
        if not (hum and root and floorRef) or attached() then
            return false
        end
        return hum:GetState() == Enum.HumanoidStateType.Climbing or root.Position.Y > floorRef + 3.6
    end

    -- off the furniture by walking (never jumping) to the nearest aisle point; the character drops back to the floor
    local function getDown()
        local _, hum, root = getChar()
        if not (hum and root) then
            return
        end
        setStatus("Getting down from the furniture")
        hum:MoveTo(root.Position)
        local t0 = os.clock()
        while alive() and os.clock() - t0 < 0.4 and elevated() do
            task.wait(0.05)
        end
        for _ = 1, 4 do
            if not (alive() and elevated()) then
                break
            end
            local best, bd
            for _, h in ipairs(hubs or {}) do
                local d = fd(root.Position, h)
                if not bd or d < bd then
                    best, bd = h, d
                end
            end
            if best then
                hum:MoveTo(best)
            end
            local t1 = os.clock()
            while alive() and os.clock() - t1 < 1.5 and elevated() do
                task.wait(0.05)
            end
        end
        hum:MoveTo(root.Position)
        progress()
    end

    local function walkTo(target, abort, first)
        for _ = 1, 3 do
            local _, hum, root = getChar()
            if not hum then
                return false
            end
            if fd(root.Position, target) < 1.2 then
                return true
            end
            local wps = first or planPath(root.Position, target)
            first = nil
            local second
            if not wps then
                wps, second = viaHub(root.Position, target)
            end
            if not wps then
                return false, "no path"
            end
            local r = followPath(wps, abort)
            if r == "done" and second then
                r = followPath(second, abort)
            end
            if r == "stopped" then
                return false, "stopped"
            end
            if r == "done" and fd(root.Position, target) < 3 then
                return true
            end
        end
        return false
    end

    -- a free floor spot near `center`, reachable by a clean path, nearest ring first
    local function standNear(center, radii)
        local _, _, root = getChar()
        if not root then
            return nil
        end
        local params = castParams()
        local overlap = OverlapParams.new()
        overlap.FilterType = Enum.RaycastFilterType.Exclude
        overlap.FilterDescendantsInstances = params.FilterDescendantsInstances
        local cands = {}
        for _, r in ipairs(radii) do
            for k = 0, 11 do
                local a = k * math.pi / 6
                local p = floorAt(center.X + math.cos(a) * r, center.Z + math.sin(a) * r, params)
                if p and (not floorRef or math.abs(p.Y - floorRef) <= 0.9) and inRoom(p) then
                    local blocked = false
                    for _, part in ipairs(workspace:GetPartBoundsInBox(CFrame.new(p + Vector3.new(0, 2.9, 0)), Vector3.new(4.4, 4.4, 4.4), overlap)) do
                        if part.CanCollide then
                            blocked = true
                            break
                        end
                    end
                    if not blocked then
                        table.insert(cands, { p = p, s = r * 1.5 + fd(root.Position, p) * 0.3 })
                    end
                end
            end
        end
        table.sort(cands, function(x, y)
            return x.s < y.s
        end)
        for i = 1, math.min(#cands, 8) do
            local wps = planPath(root.Position, cands[i].p)
            if wps then
                return cands[i].p, wps
            end
        end
        -- no clean direct path: the walk will go through an aisle point
        return cands[1] and cands[1].p or nil
    end

    local function callByText(obj, wanted)
        local reg = getInteractRegistry()
        local entry = reg and obj and reg[obj]
        local gens = entry and entry[1]
        if type(gens) ~= "table" then
            return false
        end
        for _, gen in ipairs(gens) do
            if type(gen) == "function" then
                local ok, text, _, cb = pcall(gen)
                if ok and text and type(cb) == "function" and (not wanted or text == wanted) then
                    if not cleanSafe(cb) then
                        unsafe()
                        return false
                    end
                    pcall(cb)
                    return true, text
                end
            end
        end
        return false
    end

    local function hasHallPass()
        local ok, e = pcall(function()
            return JobHandler.Shared.EquipmentService:GetEquipped(LocalPlayer)
        end)
        return ok and e ~= nil and tostring(e) == "Hall Pass"
    end

    local function dropHallPass()
        if hasHallPass() then
            pcall(function()
                JobHandler.Shared.EquipmentService:UnequipItem(LocalPlayer, "Hall Pass")
            end)
        end
    end

    -- the board game is solved the same way the cook's line game is: after a short, human time its own callback is called
    local function installHook()
        if hooked then
            return true
        end
        local ok, LF = pcall(function()
            return require(PlayerModules:WaitForChild("_UI", 5):WaitForChild("MinigameHandler", 5):WaitForChild("LineFollow", 5))
        end)
        if not (ok and LF and type(LF.LaunchGameShapes) == "function") then
            return false
        end
        shapesModule, origShapes = LF, LF.LaunchGameShapes
        hooked = true
        LF.LaunchGameShapes = function(self, cb, ...)
            local res = table.pack(origShapes(self, cb, ...))
            task.delay(2.4 + math.random() * 1.2, function()
                if hooked and farming and LF:IsRunning() then
                    pcall(cb)
                    pcall(function()
                        LF:Cleanup()
                    end)
                end
            end)
            return table.unpack(res, 1, res.n)
        end
        return true
    end

    local function removeHook()
        if not hooked then
            return
        end
        hooked = false
        pcall(function()
            shapesModule.LaunchGameShapes = origShapes
        end)
    end

    local function taskOf(desk)
        return desk:GetAttribute("TaskID")
    end

    local function npcPos(desk)
        local npc = desk:FindFirstChild("NPC")
        local pp = npc and npc.PrimaryPart
        return pp and pp.Position or desk:GetPivot().Position
    end

    local function goNear(center, radii, abort)
        local spot, wps = standNear(center, radii)
        if not spot then
            return false, "no clear spot"
        end
        return walkTo(spot, abort, wps)
    end

    local function numberOf(desk)
        return tostring(desk:GetAttribute("ID") or "?")
    end

    local function doDiscipline(desk, G)
        local want = TASK.DISCIPLINE
        local function gone()
            return taskOf(desk) ~= want
        end
        setStatus("Walking to student " .. numberOf(desk) .. " (messing around)")
        local ok = goNear(npcPos(desk), { 4.5, 5.5 }, gone)
        if gone() then
            return true
        end
        if not ok then
            return false, "no path"
        end
        setStatus("Scolding student " .. numberOf(desk))
        if not callByText(desk, "I_Scold") then
            return false, "scold not available"
        end
        return waitUntil(function()
            return taskOf(desk) == -1
        end, 4)
    end

    local function doHallPass(desk, G)
        local want = TASK.HALL_PASS
        local function gone()
            return taskOf(desk) ~= want
        end
        if not hasHallPass() then
            local best, bd
            local _, _, root = getChar()
            for _, st in ipairs(G["Hall Pass Stations"]:GetChildren()) do
                local d = root and (st:GetPivot().Position - root.Position).Magnitude or 0
                if not bd or d < bd then
                    best, bd = st, d
                end
            end
            if not best then
                return false, "no hall pass station"
            end
            setStatus("Getting a hall pass")
            local ok = goNear(best:GetPivot().Position, { 3, 4.5, 6 }, gone)
            if gone() then
                return true
            end
            if not ok then
                return false, "no path to the hall pass station"
            end
            local got = false
            for _ = 1, 2 do
                if callByText(best, "I_Take") and waitUntil(hasHallPass, 2.5) then
                    got = true
                    break
                end
            end
            if not got then
                return false, "no hall pass received"
            end
            progress()
        end
        setStatus("Bringing the hall pass to student " .. numberOf(desk))
        local ok = goNear(npcPos(desk), { 4.5, 5.5 }, gone)
        if gone() then
            return true
        end
        if not ok then
            return false, "no path"
        end
        setStatus("Giving the hall pass to student " .. numberOf(desk))
        if not callByText(desk, "I_Give") then
            return false, "give not available"
        end
        return waitUntil(function()
            return taskOf(desk) == -1
        end, 4)
    end

    local function doLecture(desk, G)
        local want = TASK.LECTURE
        local function gone()
            return taskOf(desk) ~= want
        end
        local board = G:FindFirstChild("Board")
        if not board then
            return false, "no board"
        end
        setStatus("Walking to student " .. numberOf(desk) .. " (confused)")
        local ok = goNear(npcPos(desk), { 4.5, 5.5 }, gone)
        if gone() then
            return true
        end
        if not ok then
            return false, "no path"
        end
        -- the game starts the lecture itself once the student is close and then offers the board
        local reg = getInteractRegistry()
        if not waitUntil(function()
            return gone() or (reg and reg[board] ~= nil)
        end, 6) then
            return false, "the student did not start the lecture"
        end
        if gone() then
            return true
        end
        setStatus("Walking to the board")
        local ok2 = goNear(board:GetPivot().Position, { 4, 5.5, 7 }, gone)
        if gone() then
            return true
        end
        if not ok2 then
            return false, "no path to the board"
        end
        setStatus("Using the board for student " .. numberOf(desk))
        if not callByText(board, "B_Interact") then
            return false, "board not available"
        end
        return waitUntil(function()
            return gone()
        end, 20) and taskOf(desk) == -1
    end

    -- a request the game has no known handler for: whatever interaction the desk offers is used, otherwise it is reported
    local function doUnknown(desk, G)
        local t = taskOf(desk)
        setStatus("Checking an unknown request (" .. tostring(t) .. ") at student " .. numberOf(desk))
        warnOnce("unknown" .. tostring(t), "unknown task id " .. tostring(t) .. " at desk " .. numberOf(desk))
        goNear(npcPos(desk), { 4.5, 5.5 }, function()
            return taskOf(desk) ~= t
        end)
        if taskOf(desk) ~= t then
            return true
        end
        if callByText(desk, nil) then
            return waitUntil(function()
                return taskOf(desk) ~= t
            end, 4)
        end
        return false, "no interaction for task " .. tostring(t)
    end

    function T.step()
        if not farming then
            task.wait(0.3)
            return
        end
        if not isWorkingJob(TEACHER_ID) then
            setStatus("Start the Teacher - High School job first")
            task.wait(1)
            return
        end
        local _, hum, root = getChar()
        if not hum then
            setStatus("Waiting for character")
            task.wait(1)
            return
        end
        if autoJumpWas == nil then
            autoJumpWas = hum.AutoJumpEnabled
        end
        hum.AutoJumpEnabled = false
        local G = gameplay()
        local desks = G and G:FindFirstChild("Desks")
        if not (desks and G:FindFirstChild("Hall Pass Stations")) then
            setStatus("Waiting for the classroom")
            task.wait(1)
            return
        end
        if not installHook() then
            setStatus("Waiting for the board game")
            task.wait(1)
            return
        end
        if not floorRef then
            local first = desks:GetChildren()[1]
            local o = first and first:FindFirstChild("Origin")
            if o then
                local p = floorAt(o.Position.X + 4.7, o.Position.Z, castParams())
                floorRef = p and p.Y or o.Position.Y + 0.3
            end
            if not floorRef then
                task.wait(1)
                return
            end
        end
        if not hubs then
            hubs = buildHubs(desks)
        end
        if elevated() then
            getDown()
            return
        end
        if os.clock() - lastProgress > 60 then
            setStatus("Stuck, resetting")
            dropHallPass()
            table.clear(badUntil)
            table.clear(seenAt)
            floorRef = nil
            hubs = nil
            progress()
            task.wait(1)
            return
        end
        local now = os.clock()
        local list = {}
        for _, desk in ipairs(desks:GetChildren()) do
            local t = taskOf(desk)
            if type(t) == "number" and t > 0 then
                seenAt[desk] = seenAt[desk] or now
                if not (badUntil[desk] and badUntil[desk] > now) then
                    table.insert(list, { desk = desk, t = seenAt[desk], d = (npcPos(desk) - root.Position).Magnitude })
                end
            else
                seenAt[desk] = nil
            end
        end
        if #list == 0 then
            setStatus("Waiting for students")
            progress()
            task.wait(0.3)
            return
        end
        -- the request that has been waiting longest first
        table.sort(list, function(a, b)
            if a.t ~= b.t then
                return a.t < b.t
            end
            return a.d < b.d
        end)
        local desk = list[1].desk
        local t = taskOf(desk)
        local ok, why
        if t == TASK.DISCIPLINE then
            ok, why = doDiscipline(desk, G)
        elseif t == TASK.HALL_PASS then
            ok, why = doHallPass(desk, G)
        elseif t == TASK.LECTURE then
            ok, why = doLecture(desk, G)
        else
            ok, why = doUnknown(desk, G)
        end
        if alive() then
            if ok then
                progress()
                seenAt[desk] = nil
                pause(0.1, 0.3)
            else
                warnOnce("fail" .. numberOf(desk), "student " .. numberOf(desk) .. ": " .. tostring(why))
                setStatus("Could not reach student " .. numberOf(desk) .. " (" .. tostring(why) .. "), trying again soon")
                badUntil[desk] = os.clock() + 3
                pause(0.5, 1)
            end
        end
    end

    function T.stop()
        removeHook()
        pcall(dropHallPass)
        if autoJumpWas ~= nil then
            local _, h0 = getChar()
            if h0 then
                h0.AutoJumpEnabled = autoJumpWas
            end
            autoJumpWas = nil
        end
        table.clear(seenAt)
        table.clear(badUntil)
        floorRef = nil
        hubs = nil
        progress()
    end

    return T
end)()

-- Halloween Event: Ghost Patrol
NC.ghost = (function()
    local G = {}
    local GP_PATH = ReplicatedStorage.Modules.EventService.HalloweenService.GhostPatrolService
    local Config, statusLabel, lastText
    local runId, selectedOption = 0, false
    local teleporting, enableToggle, suppress = false, nil, false
    -- the tool panel of the game: button name -> tool it uses (GhostPatrolHandler.UI)
    local BUTTON_NAMES = { "1_Button", "2_Button", "3_Button" }
    local BUTTON_TOOL = {}

    local function alive(id)
        return running and runId == id and (ghostOn or teleporting)
    end

    local STATUS_TEXT = {
        ["Driving to pickup"] = "Driving to the ghosts",
        ["Waiting for passenger"] = "Stopped at the ghosts",
        ["Driving to drop-off"] = "Driving to the cemetery",
        ["Waiting for drop-off"] = "Stopped at the cemetery",
    }

    local function status(text)
        text = STATUS_TEXT[text] or text
        if statusLabel and text ~= lastText then
            lastText = text
            withUiIdentity(function()
                statusLabel:Set("Status: " .. text)
            end)
        end
    end

    local function handler()
        local ok, m = pcall(function()
            return require(LocalPlayer.PlayerScripts.Modules._Event.GhostPatrolHandler)
        end)
        return ok and m or nil
    end

    -- the game's own state of the running job (CaptureCount, TargetCount, LocationData ...)
    local function activity(h)
        local ok, ups = pcall(debug.getupvalues, h.TryCaptureGhost)
        if ok and type(ups) == "table" then
            for _, v in pairs(ups) do
                if type(v) == "table" and rawget(v, "TargetCount") ~= nil and rawget(v, "Vehicle") ~= nil then
                    return v
                end
            end
        end
    end

    local function service(h)
        local ok, s = pcall(function()
            return h.Shared.EventService:GetEventModule("HalloweenService").HalloweenModules.GhostPatrolService
        end)
        return ok and s or nil
    end

    local function tr(key, fallback)
        local ok, s = pcall(function()
            return JobHandler.Modules.TranslationHandler:Format(key)
        end)
        return ok and type(s) == "string" and s ~= "" and s or fallback
    end

    -- the hub window button that starts the job (HalloweenHubUI > GotoGhostPatrolButton)
    local function hubButton()
        local ok, b = pcall(function()
            return LocalPlayer.PlayerScripts.Modules._UI.HalloweenHubUI:FindFirstChild("GotoGhostPatrolButton", true)
        end)
        return ok and b or nil
    end

    -- the Ghost Patrol Cruiser of the nearest rental spot (where it is changes)
    local function findCar()
        local _, _, root = getChar()
        local game_ = workspace:FindFirstChild("_game")
        local rentals = game_ and game_:FindFirstChild("Rental Vehicles")
        if not (root and rentals) then
            return nil
        end
        local best, bd
        for _, loc in ipairs(rentals:GetChildren()) do
            local part = loc:FindFirstChild("VehicleRental")
            if part and part:IsA("BasePart") and part:FindFirstChild(Config.Vehicle.VehicleName) then
                local d = (part.Position - root.Position).Magnitude
                if not bd or d < bd then
                    best, bd = part, d
                end
            end
        end
        return best, bd
    end

    local function menuOf(obj)
        pcall(function()
            InteractionHandler:CloseMenu()
        end)
        local ok, m = pcall(function()
            return InteractionHandler:ShowMenu(obj)
        end)
        return ok and type(m) == "table" and m.Buttons and m or nil
    end

    local function buttonIndex(menu, text)
        for k, v in pairs(menu.Buttons) do
            local t = tostring(v.Text or ""):gsub("%[ICON:%d+%]", "")
            if t == text then
                return k
            end
        end
    end

    local function stopWalk()
        local _, hum, root = getChar()
        if hum and root then
            hum:MoveTo(root.Position)
        end
    end

    -- steps 1-3: the game's own teleport (the GHOST PATROL button of the hub window), then wait for the area
    local function teleportToJob(id, h)
        if not hubButton() then
            status("Ghost Patrol was not found in the Halloween Event window")
            return false
        end
        local _, _, root = getChar()
        local from = root and root.Position
        status("Teleporting to Ghost Patrol")
        local LH = h.Modules.LoadingHandler
        pcall(function()
            LH:ShowLoading("ToHalloweenActivity")
        end)
        pcall(function()
            h:TeleportToNearestVehicle()
        end)
        pcall(function()
            LH:HideLoading("ToHalloweenActivity")
        end)
        status("Waiting for the area to load")
        local t0, stableSince = os.clock(), nil
        while alive(id) and os.clock() - t0 < 40 do
            local _, hum, r = getChar()
            local part = findCar()
            local sv = part and part:FindFirstChild("StaticVehicleObject")
            local moved = r and from and ((r.Position - from).Magnitude > 30 or os.clock() - t0 > 6)
            if hum and r and part and sv and sv.Value and sv.Value:IsDescendantOf(workspace) and moved and (part.Position - r.Position).Magnitude < 200 then
                stableSince = stableSince or os.clock()
                if os.clock() - stableSince > 1 then
                    return true
                end
            else
                stableSince = nil
            end
            task.wait(0.2)
        end
        return false
    end

    -- steps 4-6: walk to the car on foot (Humanoid:MoveTo along PathfindingService waypoints), use it
    local function floorAt(x, z, fromY, ignore)
        local rp = RaycastParams.new()
        rp.FilterType = Enum.RaycastFilterType.Exclude
        rp.FilterDescendantsInstances = ignore
        local h = workspace:Raycast(Vector3.new(x, fromY + 6, z), Vector3.new(0, -24, 0), rp)
        return h and h.Instance.CanCollide and h.Position or nil
    end

    -- walks to `goal` and stands within 3.5 studs of it. A path that gets stuck is dropped and a new one is
    -- computed from where the character stands (4 tries); false when the goal can not be walked to
    local function walkOnFoot(id, goal)
        for _ = 1, 4 do
            local _, hum, root = getChar()
            if not (alive(id) and hum) then
                return false
            end
            if (flat(root.Position) - flat(goal)).Magnitude < 3.5 then
                return true
            end
            local path = PathfindingService:CreatePath({ AgentRadius = 2, AgentHeight = 5, AgentCanJump = false })
            local ok = pcall(function()
                path:ComputeAsync(root.Position, goal)
            end)
            if not (ok and path.Status == Enum.PathStatus.Success) then
                return false
            end
            local wps = path:GetWaypoints()
            for i = 2, #wps do
                local wp = wps[i].Position
                hum:MoveTo(wp)
                local t0, lastPos, lastT = os.clock(), root.Position, os.clock()
                while alive(id) do
                    task.wait(0.1)
                    if (flat(root.Position) - flat(wp)).Magnitude < (i == #wps and 1.5 or 2.5) then
                        break
                    end
                    local now = os.clock()
                    if now - lastT > 1 then
                        if (root.Position - lastPos).Magnitude < 0.6 then
                            break -- not moving: stuck
                        end
                        lastPos, lastT = root.Position, now
                    end
                    if now - t0 > 8 then
                        break
                    end
                end
                if not alive(id) then
                    return false
                end
                if (flat(root.Position) - flat(wp)).Magnitude > 4 then
                    break -- did not get there: new path from here
                end
            end
        end
        local _, _, root = getChar()
        return root ~= nil and (flat(root.Position) - flat(goal)).Magnitude < 3.5
    end

    -- onSeated(model) is called on the very frame the character sits in the car (the "Use" click itself takes ~0.8 s to
    -- return): the noclip and the drive start then, the same way the taxi code watches while it enters its car
    local function getInCar(id, onSeated)
        local char, _, root = getChar()
        local part = findCar()
        if not (part and root) then
            status("Looking for the Ghost Patrol car")
            task.wait(1)
            return false
        end
        -- spots on the floor around the car (the same distances the taxi stands at), the nearest first
        local spots = {}
        for _, r in ipairs({ 6, 7.5, 9 }) do
            for a = 0, 315, 45 do
                local p = floorAt(part.Position.X + math.cos(math.rad(a)) * r, part.Position.Z + math.sin(math.rad(a)) * r, part.Position.Y, { char, part.Parent })
                if p then
                    spots[#spots + 1] = { p, (p - root.Position).Magnitude + r * 2 }
                end
            end
        end
        table.sort(spots, function(a, b)
            return a[2] < b[2]
        end)
        status("Walking to the car")
        for _, sp in ipairs(spots) do
            if not alive(id) then
                return false
            end
            if walkOnFoot(id, sp[1]) then
                status("Getting in the car")
                local watching = true
                task.spawn(function()
                    while watching and alive(id) do
                        local seated = getTaxiVehicle()
                        if seated then
                            if onSeated then
                                onSeated(seated)
                            end
                            return
                        end
                        RunService.Heartbeat:Wait()
                    end
                end)
                local m = menuOf(part)
                local idx = m and (buttonIndex(m, tr("I_Use", "Use")) or buttonIndex(m, "Use"))
                if idx then
                    pcall(function()
                        m:Click(idx)
                    end)
                    local t0 = os.clock()
                    while alive(id) and os.clock() - t0 < 8 and not getTaxiVehicle() do
                        task.wait(0.05)
                    end
                end
                watching = false
                pcall(function()
                    InteractionHandler:CloseMenu()
                end)
                if getTaxiVehicle() then
                    return true
                end
                status("Walking to the car")
            end
        end
        status("Can't get into the car, trying again")
        task.wait(1)
        return false
    end

    -- which ghost it is: compare its parts with the three ghost designs of the game
    local function signature(model)
        local t = {}
        for _, d in ipairs(model:GetDescendants()) do
            if d:IsA("MeshPart") then
                t[d.Name .. ":" .. tostring(d.MeshId)] = true
            end
        end
        return t
    end

    local function ghostTool(ghost)
        if not ghost then
            return nil
        end
        local mine = signature(ghost)
        local best, bestScore = nil, 0
        local folder = GP_PATH:FindFirstChild("Ghosts")
        for tool, prefab in pairs(Config.Ghost.PrefabName) do
            local model = folder and folder:FindFirstChild(prefab)
            if model then
                local score = 0
                for key in pairs(signature(model)) do
                    if mine[key] then
                        score += 1
                    else
                        score -= 1
                    end
                end
                if score > bestScore then
                    best, bestScore = tool, score
                end
            end
        end
        return best
    end

    -- steps 8: press the button of the tool that matches the ghost
    local function pressTool(h, tool)
        local gui = LocalPlayer.PlayerGui:FindFirstChild("GhostPatrolUI")
        local panel = gui and gui:FindFirstChild("GhostPatrolToolPanel")
        local box = panel and panel:FindFirstChild("ButtonContainer")
        local btn
        for name, t in pairs(BUTTON_TOOL) do
            if t == tool and box then
                btn = box:FindFirstChild(name)
            end
        end
        if btn then
            local fired = false
            for _, sig in ipairs({ "Activated", "MouseButton1Click" }) do
                local ok, cons = pcall(getconnections, btn[sig])
                if ok then
                    for _, c in ipairs(cons) do
                        pcall(function()
                            c:Fire()
                        end)
                        fired = true
                    end
                end
            end
            if fired then
                return "button"
            end
        end
        pcall(function()
            h:TryCaptureGhost(tool)
        end)
        return "call"
    end

    -- presses the button of the ghost's design and waits for the game's answer (the ghost has to fly to the car
    -- first: the answer comes when it arrives). Runs beside the driving, it never holds the car.
    local function capture(id, h, act, L)
        local before = act.CaptureCount
        local design = ghostTool(L.Ghost)
        local required = L.ToolRequired
        -- the ghost's design says which button; the game's own required tool for this ghost is what the server checks,
        -- so when the two ever disagree the game's wins
        local tool = (required and required ~= Config.Tools.Invalid) and required or design or required
        for attempt = 1, 3 do
            if not alive(id) then
                return false
            end
            -- the game's tool buttons only work once its capture prompt has shown (the car slow and inside the zone):
            -- the button is pressed the moment they are connected, not earlier
            local tw = os.clock()
            local gui = LocalPlayer.PlayerGui:FindFirstChild("GhostPatrolUI")
            local box = gui and gui:FindFirstChild("GhostPatrolToolPanel") and gui.GhostPatrolToolPanel:FindFirstChild("ButtonContainer")
            while alive(id) and os.clock() - tw < 5 do
                local ready = false
                for name, t in pairs(BUTTON_TOOL) do
                    local b = t == tool and box and box:FindFirstChild(name)
                    if b then
                        local ok, cons = pcall(getconnections, b.Activated)
                        ready = ok and #cons > 0
                    end
                end
                if ready then
                    break
                end
                task.wait(0.03)
            end
            local tp = os.clock()
            pressTool(h, tool)
            while alive(id) and os.clock() - tp < 8 do
                if act.CaptureCount > before or act.LocationData ~= L then
                    return true
                end
                task.wait(0.05)
            end
            tool = design or tool -- no answer: the design's button the second time
        end
        return act.CaptureCount > before
    end

    -- ===== Ghost Patrol route planning =====
    -- The ground is a grid of 6-stud cells. A cell is road (RoadSurface / asphalt, bridges included), open ground
    -- (grass, sidewalks, curbs), water, a hard obstacle (building) or not loaded yet.
    -- The route follows roads and bridges only. Open ground is used for nothing but the way out of the parking
    -- spot and the last stretch to a zone that is not on a road; water, steep slopes and land next to water are
    -- never entered (a bridge is a road, so it is used). If the zone can not be reached, the route ends at the
    -- road point nearest to it.
    local CELL = ROAD_STEP

    local function cellKey(gx, gz)
        return (gx + 16384) * 32768 + (gz + 16384)
    end

    -- part of a vehicle or a character: it moves, so it is never part of the map
    local function isLiving(i)
        local cur = i.Parent
        while cur and cur ~= workspace do
            if cur:FindFirstChildOfClass("Humanoid") or cur:GetAttribute("VehicleSource") then
                return true
            end
            cur = cur.Parent
        end
        return false
    end

    -- mem: what the cells looked like when they were last loaded (the map around the car streams in and out, a
    -- route over roads that are not loaded now has to be planned over what was seen before, not over a blank)
    local function newPlanner(ignoreList, banned, topY, mem)
        local P = {}
        local rp = RaycastParams.new()
        rp.FilterType = Enum.RaycastFilterType.Exclude
        rp.IgnoreWater = false
        local layerCache = {}

        -- every surface under (gx, gz), top to bottom
        local function layers(gx, gz)
            local key = cellKey(gx, gz)
            local l = layerCache[key]
            if l then
                return l
            end
            l = {}
            local ign = table.clone(ignoreList)
            for _ = 1, 8 do
                rp.FilterDescendantsInstances = ign
                local h = workspace:Raycast(Vector3.new(gx * CELL, topY, gz * CELL), Vector3.new(0, -(topY + 500), 0), rp)
                if not h then
                    break
                end
                local i = h.Instance
                if i:IsA("Terrain") then
                    l[#l + 1] = { y = h.Position.Y, kind = h.Material == Enum.Material.Water and "wet" or "land" }
                    break
                elseif i.CanCollide and i.Transparency < 0.95 then
                    if taxiGroundLike(i) then
                        local road = i.Name == "RoadSurface" or h.Material == Enum.Material.Asphalt
                        l[#l + 1] = { y = h.Position.Y, kind = road and "road" or "land" }
                    elseif not taxiSoft(i) and not isLiving(i) then
                        l[#l + 1] = { y = h.Position.Y, kind = "block" }
                    end
                end
                ign[#ign + 1] = i
            end
            if mem then
                if #l > 0 then
                    mem[key] = l
                elseif mem[key] then
                    l = mem[key] -- not loaded now: what was seen there
                end
            end
            layerCache[key] = l
            return l
        end

        -- what the cell is for a car at height refY: road, land, wet, block or void (not loaded)
        local function kindAt(gx, gz, refY)
            local ban = banned[cellKey(gx, gz)]
            if ban and ban > os.clock() then
                return "block"
            end
            local l = layers(gx, gz)
            if #l == 0 then
                -- nothing under it: the map is not loaded there when the cells around are empty too, a single hole is not
                local empty = 0
                for _, d in ipairs({ { 2, 0 }, { -2, 0 }, { 0, 2 }, { 0, -2 } }) do
                    if #layers(gx + d[1], gz + d[2]) == 0 then
                        empty += 1
                    end
                end
                return empty >= 3 and "void" or "block"
            end
            -- the driving surface is the highest one the car can step up to (roads and bridges are built of stacked layers)
            local g
            for _, e in ipairs(l) do
                if e.kind ~= "block" and e.y <= refY + 3.5 and e.y >= refY - 9 and (not g or e.y > g.y) then
                    g = e
                end
            end
            if not g then
                return "block"
            end
            if g.kind == "wet" then
                return "wet", g.y
            end
            for _, e in ipairs(l) do
                if e.kind == "block" and e.y > g.y + 2.5 and e.y < g.y + 14 then
                    return "block"
                end
            end
            return g.kind, g.y
        end

        -- open ground next to water is water as far as driving goes (roads and bridges are fine)
        local function cellAt(gx, gz, refY)
            local k, y = kindAt(gx, gz, refY)
            if k == "land" then
                for dx = -1, 1 do
                    for dz = -1, 1 do
                        if (dx ~= 0 or dz ~= 0) and kindAt(gx + dx, gz + dz, y) == "wet" then
                            return "wet", y
                        end
                    end
                end
            end
            return k, y
        end

        -- Only roads and bridges are driven. Open ground is used for nothing else than leaving the parking spot (the
        -- car is not on a road there) and the last stretch to a zone that is not on a road itself (the cemetery).
        local approach = { sR = 0, gR = 0 }
        local function landOk(gx, gz)
            if approach.sR > 0 and (gx - approach.sx) ^ 2 + (gz - approach.sz) ^ 2 <= (approach.sR / CELL) ^ 2 then
                return true
            end
            return approach.gR > 0 and (gx - approach.gx) ^ 2 + (gz - approach.gz) ^ 2 <= (approach.gR / CELL) ^ 2
        end

        local function driveable(k, gx, gz)
            return k == "road" or (k == "land" and landOk(gx, gz))
        end

        -- a straight line a -> b over roads (open ground only inside the two approach circles), flat enough (3-stud steps)
        local function lineOk(a, b, refY)
            local n = math.max(1, math.ceil((b - a).Magnitude / 3))
            local prevY = refY
            for i = 1, n do
                local gx, gz = cellOf(a:Lerp(b, i / n))
                local k, y = cellAt(gx, gz, prevY)
                if not driveable(k, gx, gz) or math.abs(y - prevY) > (k == "road" and 1.4 or 0.6) then
                    return false
                end
                prevY = y
            end
            return true, prevY
        end

        -- a straight stretch ahead (to keep driving while the next target is not known)
        function P.straight(from, dir, len, groundY)
            local e = from + dir * len
            local ok, endY = lineOk(from, e, groundY)
            if ok then
                return Vector3.new(e.X, endY, e.Z)
            end
        end

        -- from (a point, groundY = the ground under it) to goal. Returns points, complete.
        -- complete=false: the goal is not loaded yet, the points end at the edge of the loaded map nearest to it
        function P.plan(from, goal, groundY)
            local sx, sz = cellOf(from)
            local gcx, gcz = cellOf(goal)
            local function hOf(gx, gz)
                return math.sqrt((gx - gcx) ^ 2 + (gz - gcz) ^ 2) * CELL
            end
            -- open ground: only to leave a parking spot that is not on a road, and to reach a zone that is not on one
            approach.sx, approach.sz, approach.gx, approach.gz = sx, sz, gcx, gcz
            approach.sR = kindAt(sx, sz, groundY) == "road" and 0 or 140
            approach.gR = (cellAt(gcx, gcz, goal.Y)) == "road" and 0 or 90
            -- the start cell (the car may sit a little off: nearest driveable cell)
            local startKey, sy
            for r = 0, 3 do
                for dx = -r, r do
                    for dz = -r, r do
                        if not startKey and math.max(math.abs(dx), math.abs(dz)) == r then
                            local k, y = kindAt(sx + dx, sz + dz, groundY)
                            if driveable(k, sx + dx, sz + dz) then
                                sx, sz, sy = sx + dx, sz + dz, y
                                startKey = cellKey(sx, sz)
                            end
                        end
                    end
                end
            end
            if not startKey then
                return nil
            end
            local heap = {}
            local function push(f, key)
                heap[#heap + 1] = { f, key }
                local i = #heap
                while i > 1 and heap[i // 2][1] > heap[i][1] do
                    heap[i // 2], heap[i] = heap[i], heap[i // 2]
                    i = i // 2
                end
            end
            local function pop()
                local top = heap[1]
                local last = table.remove(heap)
                if #heap > 0 then
                    heap[1] = last
                    local i = 1
                    while true do
                        local l, r, m = i * 2, i * 2 + 1, i
                        if l <= #heap and heap[l][1] < heap[m][1] then
                            m = l
                        end
                        if r <= #heap and heap[r][1] < heap[m][1] then
                            m = r
                        end
                        if m == i then
                            break
                        end
                        heap[m], heap[i] = heap[i], heap[m]
                        i = m
                    end
                end
                return top
            end
            local g, parent, ys, coords, closed = { [startKey] = 0 }, {}, { [startKey] = sy }, { [startKey] = { sx, sz } }, {}
            push(hOf(sx, sz), startKey)
            local endKey, complete
            local best = { h = hOf(sx, sz), key = startKey }
            local expansions = 0
            while #heap > 0 and expansions < 60000 do
                local key = pop()[2]
                if not closed[key] then
                    closed[key] = true
                    expansions += 1
                    if expansions % 150 == 0 then
                        RunService.Heartbeat:Wait()
                    end
                    local cx, cz = coords[key][1], coords[key][2]
                    local cy = ys[key]
                    local hh = hOf(cx, cz)
                    if hh < best.h then
                        best = { h = hh, key = key }
                    end
                    if hh <= CELL * 1.2 then
                        endKey, complete = key, true
                        break
                    end
                    -- the edge of the loaded map (an edge right next to the start is no progress: it is only taken when
                    -- it is at least 60 studs away)
                    if math.max(math.abs(cx - sx), math.abs(cz - sz)) * CELL >= 60 then
                        for _, d in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
                            if kindAt(cx + d[1], cz + d[2], cy) == "void" then
                                endKey, complete = key, false
                                break
                            end
                        end
                        if endKey then
                            break
                        end
                    end
                    for dx = -1, 1 do
                        for dz = -1, 1 do
                            if dx ~= 0 or dz ~= 0 then
                                local nx, nz = cx + dx, cz + dz
                                local nkey = cellKey(nx, nz)
                                if not closed[nkey] then
                                    local k, y = cellAt(nx, nz, cy)
                                    local len = CELL * ((dx ~= 0 and dz ~= 0) and 1.414 or 1)
                                    if driveable(k, nx, nz) and math.abs(y - cy) <= (k == "road" and 0.35 * len + 0.5 or 0.15 * len + 0.3) then
                                        local ng = g[key] + len * (k == "road" and 1 or 4)
                                        if not g[nkey] or ng < g[nkey] then
                                            g[nkey], parent[nkey], ys[nkey], coords[nkey] = ng, key, y, { nx, nz }
                                            push(ng + hOf(nx, nz), nkey)
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
            if not endKey then
                -- no way found: the explored cell nearest to the goal (if the start itself is it, there is nothing)
                if best.key == startKey then
                    return nil
                end
                endKey, complete = best.key, false
            end
            local cells = {}
            local k = endKey
            while k do
                cells[#cells + 1] = Vector3.new(coords[k][1] * CELL, ys[k], coords[k][2] * CELL)
                k = parent[k]
            end
            -- cells is end -> start: reverse, then pull the string tight (longest straight dry lines)
            local rev = {}
            for i = #cells, 1, -1 do
                rev[#rev + 1] = cells[i]
            end
            local pts = { Vector3.new(from.X, groundY, from.Z) }
            local i = 1
            while i < #rev do
                local j = #rev
                while j > i + 1 and not lineOk(pts[#pts], rev[j], pts[#pts].Y) do
                    j -= 1
                end
                pts[#pts + 1] = rev[j]
                i = j
            end
            if complete then
                pts[#pts + 1] = Vector3.new(goal.X, rev[#rev].Y, goal.Z)
            end
            return pts, complete
        end

        return P
    end

    -- ===== the job: one drive for the whole job, the routes are handed to it =====
    local function ignoreOf(model)
        local t = { model, LocalPlayer.Character }
        local mi = workspace:FindFirstChild("MouseIgnore")
        if mi then
            t[#t + 1] = mi
        end
        return t
    end

    local function run(id)
        Config = require(GP_PATH.Config)
        BUTTON_TOOL = {
            [BUTTON_NAMES[1]] = Config.Tools.Moneybag,
            [BUTTON_NAMES[2]] = Config.Tools.Discoball,
            [BUTTON_NAMES[3]] = Config.Tools.Frog,
        }
        local h = handler()
        if not h then
            status("Ghost Patrol is not available")
            return
        end
        local svc = service(h)
        local S = {
            leg = nil, done = true, cur = nil, planning = false, extAt = 0, endedAt = 0,
            doneL = setmetatable({}, { __mode = "k" }), banned = {}, crumbs = {}, crumbAt = 0, fronts = {}, mem = {},
        }

        -- the drive of the taxi code runs from the moment the car is entered, so the car is never left to the physics
        local function startSession(pp)
            local leg = { SpotCF = CFrame.new(pp.Position), Path = {}, IsPickup = true }
            S.leg, S.done, S.cur = leg, false, nil
            ghostMode = { goal = pp.Position, radius = Config.Zone.StopRadius }
            task.spawn(function()
                local ok, err = pcall(driveLeg, leg)
                if not ok then
                    warn("[Legit Farm Job] ghost drive: " .. tostring(err))
                end
                if S.leg == leg then
                    S.done, S.endedAt = true, os.clock()
                end
            end)
        end

        -- the frame the character is seated: noclip on and the drive running, nothing is left to the physics
        local function onSeated(m)
            NC.carOk = true
            NC.on(m)
            if m.PrimaryPart and (S.done or not S.leg) then
                startSession(m.PrimaryPart)
            end
        end

        local function post(pts, goal, complete, opts)
            opts = opts or {}
            S.leg.Next = { pts = pts, goal = goal, complete = complete, append = opts.append, cruise = opts.cruise }
            ghostMode = { goal = goal, radius = complete and Config.Zone.StopRadius or 0 }
        end

        -- the first thing a car-sized box would hit along the route (the grid only looks at the middle of each cell, a
        -- thin pole or a pump between two cell centers is not seen by it)
        local function firstBlock(model, pts, from, goal)
            local params = RaycastParams.new()
            params.FilterType = Enum.RaycastFilterType.Exclude
            params.RespectCanCollide = true
            params.FilterDescendantsInstances = ignoreOf(model)
            local width = (model.PrimaryPart and model.PrimaryPart.Size.X or 8) - 0.8
            local travelled = 0
            for i = 1, #pts - 1 do
                local a, b = pts[i], pts[i + 1]
                local seg = b - a
                local len = flat(seg).Magnitude
                local k = 0
                while k < len and travelled + k < 700 do
                    local step = math.min(30, len - k)
                    local p0 = a + seg * (k / len)
                    local p1 = a + seg * ((k + step) / len)
                    local c0 = Vector3.new(p0.X, p0.Y + 2, p0.Z)
                    local v = Vector3.new(p1.X, p1.Y + 2, p1.Z) - c0
                    -- (the parking spot and the zone themselves are left alone)
                    if v.Magnitude > 0.5 and (flat(p0) - flat(from)).Magnitude > 25 and (flat(p0) - flat(goal)).Magnitude > 25 then
                        local hit
                        for _ = 1, 5 do
                            hit = castBox(CFrame.lookAt(c0, c0 + v), Vector3.new(width, 2.4, 0.6), v, params)
                            if hit and isLiving(hit.Instance) then
                                -- a moving car or a character is not part of the map
                                local f = params.FilterDescendantsInstances
                                table.insert(f, hit.Instance)
                                params.FilterDescendantsInstances = f
                                hit = nil
                            else
                                break
                            end
                        end
                        if hit then
                            return hit.Position
                        end
                    end
                    k += step
                end
                travelled += len
            end
        end

        local function planRoute(model, from, goal, groundY)
            local pts, complete
            for _ = 1, 4 do
                local P = newPlanner(ignoreOf(model), S.banned, math.max(from.Y, goal.Y) + 400, S.mem)
                pts, complete = P.plan(from, goal, groundY)
                local at = pts and firstBlock(model, pts, from, goal)
                if not at then
                    break
                end
                -- a solid thing on the road: the cells around it are not planned over for a while, and the way is planned again
                local gx, gz = cellOf(at)
                for dx = -1, 1 do
                    for dz = -1, 1 do
                        S.banned[cellKey(gx + dx, gz + dz)] = os.clock() + 180
                    end
                end
            end
            if not pts then
                -- the taxi's own road finder as the second try (it follows roads at the car's level, tunnels too)
                local rp = RaycastParams.new()
                rp.FilterType = Enum.RaycastFilterType.Exclude
                rp.FilterDescendantsInstances = ignoreOf(model)
                local ok, rc = pcall(roadConnector, flat(from), flat(goal), from.Y, rp, 6000)
                if ok and rc and #rc >= 2 then
                    pts = {}
                    for _, p in ipairs(rc) do
                        pts[#pts + 1] = Vector3.new(p.X, groundY, p.Z)
                    end
                    complete = true
                end
            end
            return pts, complete
        end

        -- keep driving while no target is known: a short dry straight stretch, toward the target when there is one
        local function runOn(model, pp, toward)
            local look = flat(pp.CFrame.LookVector)
            look = look.Magnitude > 0.01 and look.Unit or Vector3.new(0, 0, -1)
            local base = look
            if toward then
                local d = flat(toward) - flat(pp.Position)
                if d.Magnitude > 1 then
                    base = d.Unit
                end
            end
            local P = newPlanner(ignoreOf(model), S.banned, pp.Position.Y + 400, S.mem)
            local gy = pp.Position.Y - 2.8
            local from = Vector3.new(pp.Position.X, gy, pp.Position.Z)
            for _, ang in ipairs({ 0, 25, -25, 50, -50, 80, -80, 120, -120, 180 }) do
                local c, s = math.cos(math.rad(ang)), math.sin(math.rad(ang))
                local dir = Vector3.new(base.X * c - base.Z * s, 0, base.X * s + base.Z * c)
                local e = P.straight(from, dir, 54, gy)
                if e then
                    post({ from, e }, e, false, { cruise = 10 })
                    S.cur = { key = "runon", kind = "runon", goal = e, complete = false, runOn = true }
                    return true
                end
            end
            return false
        end

        -- what the car has to drive to now: the cemetery once all ghosts are caught, else the next uncaught ghost
        local function wantedTarget(act)
            if act.TargetCount > 0 and act.CaptureCount >= act.TargetCount then
                local pos = act.DropoffCFrame and act.DropoffCFrame.Position
                    or (svc and svc.DropoffLocationPart and svc.DropoffLocationPart.Position)
                if pos then
                    return { key = "drop", kind = "drop", zone = pos }
                end
            end
            local L = act.LocationData
            if L and L.Zone and not S.doneL[L] then
                if L.ToolRequired == Config.Tools.Invalid then
                    return { key = L, kind = "drop", zone = L.Zone.Position }
                end
                return { key = L, kind = "ghost", zone = L.Zone.Position, L = L }
            end
        end

        -- water: the car in water is put back on a dry spot it drove over, and the cells there are never planned again
        local function waterCheck(model, pp)
            local rp = RaycastParams.new()
            rp.FilterType = Enum.RaycastFilterType.Exclude
            rp.IgnoreWater = false
            rp.FilterDescendantsInstances = ignoreOf(model)
            local hit = workspace:Raycast(pp.Position + Vector3.new(0, 4, 0), Vector3.new(0, -40, 0), rp)
            local wet = hit ~= nil and hit.Material == Enum.Material.Water and pp.Position.Y - hit.Position.Y < 6
            if not wet then
                -- a car already under the surface does not see the water from above: the terrain cell it is in says so
                local okV, mats, occ = pcall(function()
                    local p = pp.Position
                    return workspace.Terrain:ReadVoxels(Region3.new(p - Vector3.new(2, 4, 2), p + Vector3.new(2, 1, 2)):ExpandToGrid(4), 4)
                end)
                if okV and mats then
                    for x = 1, mats.Size.X do
                        for y = 1, mats.Size.Y do
                            for z = 1, mats.Size.Z do
                                if mats[x][y][z] == Enum.Material.Water and occ[x][y][z] > 0.5 then
                                    wet = true
                                end
                            end
                        end
                    end
                end
            end
            local now = os.clock()
            if not wet then
                local last = S.crumbs[#S.crumbs]
                if hit and now - S.crumbAt > 0.5 and (not last or (flat(pp.Position) - flat(last)).Magnitude > 15) then
                    S.crumbs[#S.crumbs + 1] = pp.Position
                    if #S.crumbs > 8 then
                        table.remove(S.crumbs, 1)
                    end
                    S.crumbAt = now
                end
                return false
            end
            -- only roads and bridges are planned, so the car should never be near water; if it is anyway it drives
            -- back over the dry spots it came over (no position is set), and those cells are never planned again
            local gx, gz = cellOf(pp.Position)
            for dx = -3, 3 do
                for dz = -3, 3 do
                    S.banned[cellKey(gx + dx, gz + dz)] = math.huge
                end
            end
            if #S.crumbs == 0 then
                return true
            end
            status("Water ahead, driving back")
            local pts = { flat(pp.Position) }
            for i = #S.crumbs, 1, -1 do
                pts[#pts + 1] = flat(S.crumbs[i])
            end
            local e = pts[#pts]
            S.leg.Next = { pts = pts, goal = e, complete = false, cruise = 8 }
            ghostMode = { goal = e, radius = 0 }
            S.cur = nil
            S.crumbs = {}
            return true
        end

        local function step()
            local model = getTaxiVehicle()
            local pp = model and model.PrimaryPart
            if not pp then
                return false
            end
            if S.done or not S.leg then
                if os.clock() - S.endedAt < 1 then
                    return true
                end
                startSession(pp)
            end
            local act = activity(h)
            if not act then
                status("Waiting for the job to start")
                return true
            end
            if waterCheck(model, pp) then
                return true
            end
            if S.capturing then
                return true -- waiting for the game's answer to the button, the car holds its place in the zone
            end
            -- held up by something the planner could not see from above (live: solid terrain right in front of a shortcut):
            -- the cells ahead are never planned over again and the route is planned again from where the car is
            do
                local c0 = S.cur
                local leg = S.leg
                if leg and (leg.Blocked or 0) ~= (S.seenBlocked or 0) then
                    S.seenBlocked = leg.Blocked
                    local at = leg.BlockedAt
                    local zoneNear = c0 and c0.zone and at and (at - flat(c0.zone)).Magnitude < 25
                    if c0 and at and not zoneNear and not c0.runOn then
                        -- the drive reports where the car was held up: the cells there and just ahead of it are never
                        -- planned over again, and the route is planned again from where the car is
                        local look = flat(pp.CFrame.LookVector)
                        look = look.Magnitude > 0.01 and look.Unit or Vector3.new(0, 0, -1)
                        local base = Vector3.new(at.X, pp.Position.Y, at.Z)
                        for _, d in ipairs({ 0, 6, 12 }) do
                            local gx, gz = cellOf(base + look * d)
                            S.banned[cellKey(gx, gz)] = os.clock() + 90 -- not planned over for a while
                        end
                        S.cur = nil
                        return true
                    end
                end
            end
            local t = wantedTarget(act)
            local cur = S.cur
            if t and not (cur and cur.key == t.key) then
                -- a new target (first ghost, the next ghost, the cemetery): the route is planned and handed to the drive
                status(t.kind == "drop" and "Driving to the cemetery" or "Driving to the ghosts")
                S.fronts = {}
                local gy = pp.Position.Y - 2.8
                if not cur or cur.kind ~= "runon" then
                    runOn(model, pp, t.zone) -- rolling toward it while the route is planned, never standing still
                end
                local pts, complete = planRoute(model, pp.Position, t.zone, gy)
                if pts and #pts >= 2 then
                    local goal = complete and t.zone or pts[#pts]
                    S.cur = { key = t.key, kind = t.kind, zone = t.zone, goal = goal, complete = complete, L = t.L }
                    post(pts, goal, complete)
                else
                    status("No dry way found, searching")
                    if not (cur and cur.runOn and (flat(pp.Position) - flat(cur.goal)).Magnitude > 15) then
                        runOn(model, pp, t.zone)
                    end
                    task.wait(0.4)
                end
                return true
            end
            if not t then
                -- nothing known to drive to yet: never stand still
                if not cur or (cur.runOn and (flat(pp.Position) - flat(cur.goal)).Magnitude < 16) or (cur and cur.kind ~= "runon") then
                    status(S.capturing and "Capturing the ghost" or "Looking for the next ghost")
                    runOn(model, pp)
                end
                return true
            end
            -- the target is the one the car is driving to
            if not cur.complete then
                -- the zone is not loaded yet: the next stretch is planned while driving and joined on
                local dEnd = (flat(pp.Position) - flat(cur.goal)).Magnitude
                -- the car got to the end of the road that was known and nothing went on from it: that end is a dead end,
                -- it is not planned over again and the way is planned again from where the car is
                if dEnd < 30 or cur.dead then
                    S.endSince = S.endSince or os.clock()
                    if (cur.dead or os.clock() - S.endSince > 3) and not S.planning then
                        local gx, gz = cellOf(cur.goal)
                        for dx = -2, 2 do
                            for dz = -2, 2 do
                                S.banned[cellKey(gx + dx, gz + dz)] = os.clock() + 300
                            end
                        end
                        S.endSince, S.cur = nil, nil
                        return true
                    end
                else
                    S.endSince = nil
                end
                -- (only when the car is near the end: what lies beyond it has been loaded by then)
                if not S.planning and os.clock() >= S.extAt and dEnd < 350 then
                    S.planning = true
                    task.spawn(function()
                        local ok, pts, complete = pcall(planRoute, model, cur.goal, cur.zone, cur.goal.Y)
                        S.planning = false
                        if S.cur == cur and ok and pts and #pts >= 2 and alive(id) then
                            -- roads do not run straight at the zone: the stretch is also taken when it ends somewhere new
                            -- (50+ studs on, not a place already driven to), the car does not circle at the end of a stretch
                            local lastPt, seen = pts[#pts], false
                            for _, f in ipairs(S.fronts) do
                                if (flat(f) - flat(lastPt)).Magnitude < 40 then
                                    seen = true
                                end
                            end
                            local better = complete
                                or (flat(cur.zone) - flat(lastPt)).Magnitude < (flat(cur.zone) - flat(cur.goal)).Magnitude - 30
                                or ((flat(lastPt) - flat(cur.goal)).Magnitude >= 50 and not seen)
                            if better then
                                table.insert(S.fronts, cur.goal)
                            end
                            if better then
                                cur.goal = complete and cur.zone or pts[#pts]
                                cur.complete = complete and true or false
                                post(pts, cur.goal, cur.complete, { append = true })
                                return
                            end
                        end
                        if S.cur == cur and ok then
                            cur.dead = true -- the road that was known ends there and nothing goes on from it
                        end
                        S.extAt = os.clock() + 1.5
                    end)
                end
                return true
            end
            -- a complete route: when the car is stopped in the zone the ghost is captured / the game releases them
            local stopped = false
            if svc then
                local ok, res = pcall(function()
                    return svc:IsVehicleStoppedInZone(act.Vehicle, cur.zone)
                end)
                stopped = ok and res and true or false
            end
            if stopped and cur.kind == "ghost" then
                -- the server sees the car a moment late: only pressed once the car has been inside the zone and slow for a
                -- full second (live: a press as the car reached the edge of the zone got no answer)
                S.restSince = S.restSince or os.clock()
                stopped = os.clock() - S.restSince >= 1
            else
                S.restSince = nil
            end
            if stopped then
                if cur.kind == "ghost" then
                    -- the game answers about 10 s after the button (the ghost has to fly to the car, the server wants
                    -- more than 10 s), and the car has to be slow and inside the zone then: it stays where it is while
                    -- the button is waiting for its answer, and goes on the moment the answer is there
                    local L = cur.L
                    S.capturing = true
                    status("Capturing the ghost")
                    task.spawn(function()
                        local got = capture(id, h, act, L)
                        if got then
                            S.doneL[L] = true
                            S.cur = nil
                        end
                        S.capturing = false
                    end)
                else
                    status("Releasing the ghosts")
                    local t0 = os.clock()
                    while alive(id) and os.clock() - t0 < 25 and act.CaptureCount >= act.TargetCount and act.TargetCount > 0 do
                        task.wait(0.1)
                    end
                    local dl = act.LocationData
                    if dl and dl.ToolRequired == Config.Tools.Invalid then
                        S.doneL[dl] = true -- the game's drop-off location is used up
                    end
                    S.cur = nil
                    status("Looking for the next ghost")
                    runOn(model, pp)
                end
            end
            return true
        end

        while alive(id) do
            local model = getTaxiVehicle()
            if not model then
                S.done, S.leg, S.cur = true, nil, nil
                -- the Teleport button already brought the character to the car; teleport again only when
                -- the car is not around
                local _, near = findCar()
                if not (near and near < 250) and not teleportToJob(id, h) then
                    task.wait(1)
                else
                    if not getInCar(id, onSeated) then
                        task.wait(0.5)
                    else
                        NC.carOk = true
                        local m = getTaxiVehicle()
                        if m then
                            NC.on(m) -- noclip is on from the moment the car is entered
                        end
                    end
                end
            else
                local ok, err = pcall(step)
                if not ok then
                    -- an error only skips this step, the job goes on
                    warn("[Legit Farm Job] ghost patrol step: " .. tostring(err))
                    task.wait(0.3)
                end
                task.wait(0.1)
            end
        end
    end

    function G.stop()
        ghostOn = false
        runId += 1
        taxiSerial += 1
        ghostMode = nil
        pcall(releaseDrive)
        NC.carOk = false
        pcall(NC.off)
        pcall(stopWalk)
        status("Idle")
    end

    local function setEnable(v)
        if enableToggle then
            suppress = true
            withUiIdentity(function()
                enableToggle:Set(v)
            end)
            suppress = false
        end
    end

    -- the Teleport button only teleports (steps 1-3); it does not start anything
    function G.teleport()
        if ghostOn then
            status("Turn Enable off before teleporting")
            return
        end
        if teleporting then
            return
        end
        if not selectedOption then
            status("Select GHOST PATROL first")
            return
        end
        runId += 1
        local id = runId
        teleporting = true
        ghostLabelSet = nil
        task.spawn(function()
            local ok, res = pcall(function()
                Config = require(GP_PATH.Config)
                local h = handler()
                return h and teleportToJob(id, h)
            end)
            teleporting = false
            if ok and res then
                status("Teleported next to the car, turn Enable on")
            elseif runId == id then
                status("Could not teleport to the car")
            end
        end)
    end

    -- the Enable toggle starts and stops the automation
    function G.start()
        if ghostOn then
            return
        end
        if not selectedOption then
            status("Select GHOST PATROL first")
            setEnable(false)
            return
        end
        runId += 1
        local id = runId
        teleporting = false
        ghostOn = true
        ghostLabelSet = status
        task.spawn(function()
            local ok, err = pcall(run, id)
            if not ok then
                warn("[Legit Farm Job] ghost patrol: " .. tostring(err))
                status("Error, stopped")
            end
            if runId == id then
                G.stop()
                setEnable(false)
            end
        end)
    end

    function G.buildUI(tab)
        tab:CreateDropdown({
            Name = "Halloween activity",
            Options = { "GHOST PATROL" },
            CurrentOption = {},
            MultipleOptions = false,
            Flag = "LFJ_HalloweenActivity",
            Callback = function(option)
                local label = type(option) == "table" and option[1] or option
                selectedOption = label == "GHOST PATROL"
            end,
        })
        tab:CreateButton({
            Name = "Teleport",
            Callback = function()
                G.teleport()
            end,
        })
        enableToggle = tab:CreateToggle({
            Name = "Enable",
            CurrentValue = false,
            Flag = "LFJ_GhostPatrolEnable",
            Callback = function(value)
                if suppress then
                    return
                end
                if value then
                    G.start()
                elseif ghostOn then
                    G.stop()
                end
            end,
        })
        statusLabel = tab:CreateLabel("Status: Idle")
    end

    return G
end)()

-- Halloween Event: Seasonal Minigames (Pumpkin Panic, Chromatic Chaos, Recipe Ritual)
NC.seasonal = (function()
    local M = {}
    local HubMod = PlayerModules:WaitForChild("_UI"):WaitForChild("HalloweenHubUI")
    local SM_AGENTS = {
        { AgentRadius = 1.5, AgentHeight = 5, AgentCanJump = false },
        { AgentRadius = 1, AgentHeight = 4, AgentCanJump = false },
    }
    local on, runId, gen, teleporting = false, 0, 0, false
    local toggleObj, suppress = nil, false
    local statusLabel, lastStatus
    local schedLabels = {}
    local lastTp = -100

    local function status(text)
        if statusLabel and text ~= lastStatus then
            lastStatus = text
            withUiIdentity(function()
                statusLabel:Set("Status: " .. text)
            end)
        end
    end

    local function handler()
        local ok, h = pcall(function()
            return require(PlayerModules._Event.HalloweenHandler).SeasonalMinigames
        end)
        return ok and h or nil
    end

    local function prettyName(name)
        local ok, s = pcall(function()
            return JobHandler.Modules.TranslationHandler:Format("T_SeasonalMinigame_" .. name)
        end)
        if ok and type(s) == "string" and s ~= "" and not s:find("T_Seasonal", 1, true) then
            return s
        end
        return (tostring(name):gsub("(%l)(%u)", "%1 %2"))
    end

    local function fmtLeft(s)
        s = math.max(0, math.floor(s))
        return string.format("%d:%02d", s // 60, s % 60)
    end

    local function clockAt(s)
        local ok, t = pcall(os.date, "%I:%M:%S %p", os.time() + math.floor(s))
        return ok and t or "?"
    end

    -- the minigame that is running now (the game's own CurrentMinigameIndex), its module and its seconds left
    local function current(SM)
        local idx = SM.CurrentMinigameIndex and SM.CurrentMinigameIndex.Value or -1
        local mg = idx >= 1 and SM._minigames[idx]
        if not mg then
            return nil
        end
        local _, elapsed = SM.Service:ResolveCycle()
        return mg.Name, mg.Module, math.max(0, SM.Config.MinigameDuration - elapsed)
    end

    -- Schedule (read from the game: BuildSchedule / ResolveCycle, the same the schedule board uses)
    local function updateSchedule()
        local SM = handler()
        local lines = { "-", "-", "-" }
        if SM then
            if SM.Overridden and SM.Overridden.Value then
                local name = current(SM)
                lines[1] = "Now: " .. (name and prettyName(name) or "-") .. " (schedule overridden by the game)"
            else
                local ok, sched = pcall(function()
                    return SM:BuildSchedule(3)
                end)
                if ok and type(sched) == "table" and sched[1] then
                    local dur = SM.Config.MinigameDuration
                    local i = 1
                    if sched[1].IsNow then
                        local name, _, left = current(SM)
                        lines[1] = "Now: " .. prettyName(name or sched[1].MinigameName) .. " - ends in " .. fmtLeft(left or 0)
                            .. " (" .. clockAt(left or 0) .. ")"
                        i = 2
                    else
                        lines[1] = "Now: no minigame running"
                    end
                    local nx, af = sched[i], sched[i + 1]
                    if nx then
                        lines[2] = "Next: " .. prettyName(nx.MinigameName) .. " - starts in " .. fmtLeft(nx.TimeLeft) .. " ("
                            .. clockAt(nx.TimeLeft) .. "), ends " .. clockAt(nx.TimeLeft + dur)
                    end
                    if af then
                        lines[3] = "After that: " .. prettyName(af.MinigameName) .. " - starts in " .. fmtLeft(af.TimeLeft)
                            .. " (" .. clockAt(af.TimeLeft) .. ")"
                    end
                end
            end
        end
        withUiIdentity(function()
            for k = 1, 3 do
                if schedLabels[k] then
                    schedLabels[k]:Set(lines[k])
                end
            end
        end)
    end

    -- Area
    local function area()
        local a = CollectionService:GetTagged("SeasonalMinigamesArea")[1]
        local tc = a and a:FindFirstChild("TouchCollider")
        return a, tc
    end

    local function nearArea()
        local _, tc = area()
        local _, _, root = getChar()
        return tc ~= nil and root ~= nil and (flat(root.Position) - flat(tc.Position)).Magnitude < 250
    end

    -- the game's own teleport function, no UI: _Event.WinterEventHandler.GoToEventArea(self, area) does
    -- ShowLoading(area), net:InvokeServer({Type = "GoToEventArea", PositionType = area}), HideLoading(area) -
    -- the same request the hub's SEASONAL MINIGAMES button sends. The request to the server comes from the
    -- game's module function (DataService only checks the direct caller), never from this script.
    local EventMod = PlayerModules:WaitForChild("_Event"):WaitForChild("WinterEventHandler")
    local function fireTeleport()
        if DataService.FireServer ~= origFireServer or DataService.InvokeServer ~= origInvokeServer then
            return false, "unsafe state"
        end
        local okE, Ev = pcall(require, EventMod)
        local f = okE and type(Ev) == "table" and Ev.GoToEventArea
        local env = type(f) == "function" and getfenv(f)
        if not (f and not (isexecutorclosure and isexecutorclosure(f)) and env and env.script == EventMod
            and type(Ev.net) == "table" and Ev.net.InvokeServer == origInvokeServer) then
            return false, "teleport not ready"
        end
        task.spawn(function()
            pcall(f, Ev, "HalloweenSeasonalMinigames")
        end)
        return true
    end

    local function teleportAndWait(alive)
        if os.clock() - lastTp < 20 then
            return false
        end
        lastTp = os.clock()
        local _, _, root0 = getChar()
        local from = root0 and root0.Position
        status("Teleporting to Seasonal Minigames")
        local ok, why = fireTeleport()
        if not ok then
            status("Teleport failed (" .. tostring(why) .. ")")
            return false
        end
        status("Waiting for the loading screen")
        local t0, stable = os.clock(), nil
        while alive() and os.clock() - t0 < 45 do
            local _, hum, root = getChar()
            local moved = root and from and (root.Position - from).Magnitude > 30
            local okL, loading = pcall(function()
                return JobHandler.Modules.LoadingHandler:IsLoadingAny()
            end)
            if hum and root and nearArea() and (moved or os.clock() - t0 > 8) and not root.Anchored and not (okL and loading) then
                stable = stable or os.clock()
                if os.clock() - stable > 1.5 then
                    return true
                end
            else
                stable = nil
            end
            task.wait(0.2)
        end
        return nearArea()
    end

    -- Walking: Humanoid:MoveTo along PathfindingService waypoints (normal walk), never a teleport
    local function fdist(a, b)
        return (Vector3.new(a.X, 0, a.Z) - Vector3.new(b.X, 0, b.Z)).Magnitude
    end

    -- Mobile only (touch screen without keyboard; getgenv().LFJ_ForceMobile = true to test it on PC): paths are
    -- planned with less of the map streamed in, so thin solid things (the lamp posts by the hay bales) can be missing
    -- from the path and walked into, and Recipe Ritual paths could leave the event area (the game removes a carried
    -- ingredient when it is carried back in)
    local UIS = game:GetService("UserInputService")
    local keepInArea = false
    local function isMobile()
        return getgenv().LFJ_ForceMobile == true or (UIS.TouchEnabled and not UIS.KeyboardEnabled)
    end

    local function inAreaBox(p, inset)
        local _, tc = area()
        if not tc then
            return true
        end
        local rel = tc.CFrame:PointToObjectSpace(p)
        return math.abs(rel.X) <= tc.Size.X / 2 - inset and math.abs(rel.Z) <= tc.Size.Z / 2 - inset
    end

    local function leavesArea(path)
        for _, w in ipairs(path:GetWaypoints()) do
            -- only a path that actually crosses the edge (a 1-stud margin refused paths along the edge too, and every
            -- refusal was a stop before the next spot: ~1 s delays grabbing ingredients near the edge)
            if not inAreaBox(w.Position, 0) then
                return true
            end
        end
        return false
    end

    local function ground(p, ignore)
        local rp = RaycastParams.new()
        rp.FilterType = Enum.RaycastFilterType.Exclude
        -- other players are never ground (seen live in a full server: a ray down on a player hits their hat / head,
        -- which put walk goals on top of people)
        local list = table.clone(ignore or { LocalPlayer.Character })
        for _, plr in ipairs(Players:GetPlayers()) do
            if plr.Character then
                table.insert(list, plr.Character)
            end
        end
        rp.FilterDescendantsInstances = list
        local h = workspace:Raycast(Vector3.new(p.X, p.Y + 8, p.Z), Vector3.new(0, -30, 0), rp)
        return h and h.Position or nil
    end

    local function stopWalk()
        local _, hum, root = getChar()
        if hum and root then
            hum:MoveTo(root.Position)
        end
    end

    -- the hotbar's own X (EquippedContainer.UnequipButton -> HotbarUI unequip) when something is still in hand, e.g. a
    -- Recipe Ritual ingredient left over when the minigame ends
    local function dropHeld()
        local ok, eq = pcall(function()
            return JobHandler.Shared.EquipmentService:GetEquipped(LocalPlayer)
        end)
        if not (ok and eq) then
            return
        end
        local pg = LocalPlayer:FindFirstChildOfClass("PlayerGui")
        local btn
        for _, d in ipairs(pg and pg:GetDescendants() or {}) do
            if d.Name == "UnequipButton" and d.Parent and d.Parent.Name == "EquippedContainer" then
                btn = d
                break
            end
        end
        local hb = PlayerModules:FindFirstChild("_UI")
        hb = hb and hb:FindFirstChild("HUDHandler")
        hb = hb and hb:FindFirstChild("HotbarUI")
        local okC, cons = pcall(getconnections, btn and btn.Activated)
        for _, c in ipairs(okC and cons or {}) do
            local f = c.Function
            if f and cleanSafe(f) and getfenv(f).script == hb then
                status("Dropping the " .. tostring(eq))
                task.spawn(function()
                    pcall(function()
                        c:Fire()
                    end)
                end)
                local t0 = os.clock()
                while os.clock() - t0 < 2 do
                    local ok2, e2 = pcall(function()
                        return JobHandler.Shared.EquipmentService:GetEquipped(LocalPlayer)
                    end)
                    if ok2 and not e2 then
                        break
                    end
                    task.wait(0.1)
                end
                return
            end
        end
    end

    -- tight: the next waypoint is only taken when the current one is reached (no corner cutting next to posts / walls)
    local function walkTo(goal, within, alive, abort, tight, agents)
        within = within or 2
        for attempt = 1, 3 do
            if not alive() or (abort and abort()) then
                return false
            end
            local _, hum, root = getChar()
            if not hum then
                return false
            end
            if fdist(root.Position, goal) <= within then
                return true
            end
            if attempt == 1 then
                -- keep walking toward the goal while the path is planned, so one walk flows into the next
                -- instead of stopping and starting again
                hum:MoveTo(goal)
            end
            local path
            local stayIn = keepInArea and isMobile() and inAreaBox(root.Position, 0)
            for _, cfg in ipairs(agents or SM_AGENTS) do
                local p = PathfindingService:CreatePath(cfg)
                local ok = pcall(function()
                    p:ComputeAsync(root.Position, goal)
                end)
                if ok and p.Status == Enum.PathStatus.Success and not (stayIn and leavesArea(p)) then
                    path = p
                    break
                end
            end
            if not path then
                if attempt == 1 then
                    stopWalk() -- no way there: don't keep walking straight at it
                end
                return false
            end
            -- follow the path by always aiming a little way ahead along it (2 studs tight, 4 otherwise) instead of
            -- MoveTo one waypoint after another: turning at every waypoint was a short stop-and-start each time
            -- (seen live: 25 speed dips in 50 s, all at waypoint switches)
            local wps = path:GetWaypoints()
            local pts = {}
            local total = 0
            for i, w in ipairs(wps) do
                pts[i] = w.Position
                if i > 1 then
                    total += fdist(pts[i], pts[i - 1])
                end
            end
            local ahead = tight and 2 or 4
            local seg = 1
            local t0 = os.clock()
            local limit = total / math.max(hum.WalkSpeed, 1) * 2 + 4
            local ref, refT = root.Position, t0
            local lastAim, lastMoveT = nil, 0
            local obsT
            local blocked = false
            while #pts >= 2 do
                if not alive() or (abort and abort()) then
                    return false
                end
                local p = root.Position
                if fdist(p, goal) <= within then
                    break
                end
                -- the segment the character is on (passed its end, or close to it -> the next one)
                while seg < #pts - 1 do
                    local a, b = flat(pts[seg]), flat(pts[seg + 1])
                    local ab = b - a
                    local l2 = ab:Dot(ab)
                    local t = l2 > 1e-6 and (flat(p) - a):Dot(ab) / l2 or 1
                    if t >= 1 or fdist(p, pts[seg + 1]) <= (tight and 1.2 or 2) then
                        seg += 1
                    else
                        break
                    end
                end
                -- the point "ahead" studs further along the path from the character's place on it
                local a, b = pts[seg], pts[seg + 1]
                local ab = flat(b) - flat(a)
                local l2 = ab:Dot(ab)
                local t = l2 > 1e-6 and math.clamp((flat(p) - flat(a)):Dot(ab) / l2, 0, 1) or 1
                local cur = a:Lerp(b, t)
                local left = ahead
                local aim = pts[#pts]
                local k = seg
                while k < #pts do
                    local nxt = pts[k + 1]
                    local d = fdist(cur, nxt)
                    if d >= left then
                        aim = cur:Lerp(nxt, d > 1e-6 and left / d or 1)
                        break
                    end
                    left -= d
                    cur = nxt
                    k += 1
                end
                -- mobile: a solid thing right ahead that the path does not know about (a lamp post streamed in
                -- after the path was planned) is stepped around on the side the character is already on
                if isMobile() and os.clock() - (obsT or 0) > 0.25 then
                    obsT = os.clock()
                    local dir = flat(aim) - flat(p)
                    if dir.Magnitude > 0.5 then
                        dir = dir.Unit
                        local op = RaycastParams.new()
                        op.FilterType = Enum.RaycastFilterType.Exclude
                        op.RespectCanCollide = true
                        local ign = {}
                        for _, plr in ipairs(Players:GetPlayers()) do
                            if plr.Character then
                                table.insert(ign, plr.Character)
                            end
                        end
                        op.FilterDescendantsInstances = ign
                        local hit = workspace:Blockcast(CFrame.new(p + Vector3.new(0, 0.5, 0)), Vector3.new(2, 3, 2), dir * 3.5, op)
                        -- only tall posts (the lamp posts are 15.8 high): never the ingredient / tomb itself or low
                        -- decor next to it (stepping around those delayed grabbing an ingredient)
                        local hm = hit and hit.Instance:FindFirstAncestorOfClass("Model")
                        local tagged = false
                        while hm and not tagged do
                            for _, tg in ipairs(CollectionService:GetTags(hm)) do
                                if tg:find("^SeasonalMinigames") then
                                    tagged = true
                                end
                            end
                            hm = hm.Parent and hm.Parent:FindFirstAncestorOfClass("Model")
                        end
                        if hit and not tagged and not hit.Instance:IsA("Terrain") and math.abs(hit.Normal.Y) < 0.5
                            and hit.Instance.Size.Y >= 6 then
                            local o = hit.Instance
                            local side = Vector3.new(-dir.Z, 0, dir.X)
                            if (flat(p) - flat(o.Position)):Dot(side) < 0 then
                                side = -side
                            end
                            local half = math.max(o.Size.X, o.Size.Z) / 2
                            local dp = flat(o.Position) + side * (half + 2.5) + dir * 1
                            dp = Vector3.new(dp.X, p.Y, dp.Z)
                            hum:MoveTo(dp)
                            local td = os.clock()
                            while os.clock() - td < 1.5 and fdist(root.Position, dp) > 1.2 do
                                if not alive() or (abort and abort()) then
                                    return false
                                end
                                RunService.Heartbeat:Wait()
                            end
                            lastAim = nil
                            ref, refT = root.Position, os.clock()
                        end
                    end
                end
                if not lastAim or fdist(aim, lastAim) > 0.3 or os.clock() - lastMoveT > 0.5 then
                    hum:MoveTo(aim)
                    lastAim, lastMoveT = aim, os.clock()
                end
                if seg >= #pts - 1 and fdist(p, pts[#pts]) <= math.max(1.5, within) then
                    break
                end
                if os.clock() - t0 > limit then
                    blocked = true
                    break
                end
                if os.clock() - refT > 0.8 then
                    if fdist(p, ref) < 0.5 then
                        blocked = true
                        break
                    end
                    ref, refT = p, os.clock()
                end
                RunService.Heartbeat:Wait()
            end
            if fdist(root.Position, goal) <= within + 0.5 then
                return true
            end
        end
        return false
    end

    -- spots on the floor around an object, nearest first (the object itself blocks the navmesh)
    local function standPoints(obj, radii)
        local char, _, root = getChar()
        local pos = obj:IsA("Model") and obj:GetPivot().Position or obj.Position
        local out = {}
        for _, r in ipairs(radii) do
            for k = 0, 7 do
                local a = k * math.pi / 4
                local g = ground(Vector3.new(pos.X + math.cos(a) * r, pos.Y + 2, pos.Z + math.sin(a) * r), { char, obj })
                if g and root then
                    table.insert(out, { p = g, d = fdist(g, root.Position) + r })
                end
            end
        end
        table.sort(out, function(x, y)
            return x.d < y.d
        end)
        return out
    end

    local function goNear(obj, radii, alive, abort)
        local tries = 0
        for _, sp in ipairs(standPoints(obj, radii)) do
            if not alive() or (abort and abort()) or tries >= 4 then
                return false
            end
            -- mobile Recipe Ritual: a spot outside the event area is skipped right away (its path would be refused)
            if keepInArea and isMobile() and not inAreaBox(sp.p, 1) then
                continue
            end
            tries += 1
            if walkTo(sp.p, 1.5, alive, abort) then
                return true
            end
        end
        return false
    end

    -- the game's own interaction callback of an object (the same as pressing its prompt)
    local function gameCallback(obj, wanted)
        local reg = getInteractRegistry()
        local entry = reg and reg[obj]
        local gens = entry and entry[1]
        if type(gens) ~= "table" then
            return nil
        end
        for _, g in ipairs(gens) do
            if type(g) == "function" then
                local ok, text, _, cb = pcall(g)
                if ok and text == wanted and type(cb) == "function" then
                    return cb
                end
            end
        end
    end

    local function useCallback(cb)
        if not cleanSafe(cb) then
            on = false
            runId += 1
            stopWalk()
            status("Stopped: unsafe state")
            if toggleObj then
                suppress = true
                withUiIdentity(function()
                    toggleObj:Set(false)
                end)
                suppress = false
            end
            return false
        end
        pcall(cb)
        return true
    end

    local function moduleOf(SM, name)
        for _, mg in pairs(SM._minigames) do
            if mg.Name == name then
                return mg.Module
            end
        end
    end

    local function selfTasks(SM)
        local pd = SM.Service.PlayerData
        local st = pd and pd.SelfTasksStat
        return st and st.Value or 0
    end

    local function tasksText(SM)
        return " (" .. selfTasks(SM) .. "/" .. tostring(SM.Config.PlayerTaskCount) .. ")"
    end

    -- walks into the minigame area (the game's TouchCollider box), a little in from the edge on the player's side
    local function enterArea(SM, alive)
        if SM._isInArea then
            return true
        end
        local _, tc = area()
        local _, _, root = getChar()
        if not (tc and root) then
            return false
        end
        local c = tc.Position
        local d = flat(root.Position) - flat(c)
        d = d.Magnitude > 0.1 and d.Unit or Vector3.new(0, 0, 1)
        -- the most direct way in: the closest point inside the box first (the game puts the character in front of the
        -- entrance arch), then points toward the middle; each goal is walked by the shortest path found to it, with a
        -- wide agent and no corner cutting so it goes through the arch instead of getting caught on a post and
        -- re-planning around the fence
        local rel = tc.CFrame:PointToObjectSpace(root.Position)
        -- all the way in, not just over the edge (seen live: it stopped at the corner of the area, 3 studs inside,
        -- even on a boulder there): the goal is the closest open-floor point 16+ studs inside every edge
        local floorY = tc.Position.Y - tc.Size.Y / 2
        local deepGoal
        for _, inset in ipairs({ 16, 19, 22 }) do
            local hx, hz = math.max(tc.Size.X / 2 - inset, 0), math.max(tc.Size.Z / 2 - inset, 0)
            for _, o in ipairs({ { 0, 0 }, { 4, 0 }, { -4, 0 }, { 0, 4 }, { 0, -4 } }) do
                local w = tc.CFrame:PointToWorldSpace(Vector3.new(math.clamp(rel.X, -hx, hx) + o[1], 0, math.clamp(rel.Z, -hz, hz) + o[2]))
                local g = ground(Vector3.new(w.X, c.Y + 4, w.Z))
                if g and g.Y < floorY + 1.5 then
                    deepGoal = g
                    break
                end
            end
            if deepGoal then
                break
            end
        end
        local function deepIn()
            local _, _, r = getChar()
            if not r then
                return false
            end
            local rr = tc.CFrame:PointToObjectSpace(r.Position)
            return math.min(tc.Size.X / 2 - math.abs(rr.X), tc.Size.Z / 2 - math.abs(rr.Z)) >= 14
        end
        -- from the entrance side: straight through the middle of the arch (CityHallPlaza, opening at 444,-106, facing
        -- the spawn) and on along its line to the left part of the red circle. Seen live: the shortest path ran 5-7
        -- studs right of the line the whole way and went round the right side of the plaza.
        local ARCH, ARCH_IN, ARCH_LEFT = Vector3.new(444, 0, -106), Vector3.new(0.7071, 0, 0.7071), Vector3.new(0.7071, 0, -0.7071)
        local fromArch = flat(root.Position) - ARCH
        if fromArch.Magnitude < 70 and fromArch:Dot(ARCH_IN) < 4 then
            local function inDeep()
                return SM._isInArea and deepIn()
            end
            -- these legs are straight lines along the walkway: when the line is clear they are walked with MoveTo
            -- only. Pathfinding right after enabling (its navigation data for the freshly loaded area is built on the
            -- first request) was the lag spike on enable (seen live: 309 ms / 3 x 50 ms frames during those path
            -- requests); pathfinding is still used when something is in the way
            local function straight(goal, within)
                local _, hum, root2 = getChar()
                if not (hum and root2) then
                    return false
                end
                local d = goal - root2.Position
                d = Vector3.new(d.X, 0, d.Z)
                if d.Magnitude > 0.5 then
                    local op = RaycastParams.new()
                    op.FilterType = Enum.RaycastFilterType.Exclude
                    op.RespectCanCollide = true
                    local ign = {}
                    for _, plr in ipairs(Players:GetPlayers()) do
                        if plr.Character then
                            table.insert(ign, plr.Character)
                        end
                    end
                    op.FilterDescendantsInstances = ign
                    if workspace:Blockcast(CFrame.new(root2.Position + Vector3.new(0, 0.5, 0)), Vector3.new(3, 3, 3), d, op) then
                        return false
                    end
                end
                hum:MoveTo(goal)
                local ref, refT, t0 = root2.Position, os.clock(), os.clock()
                while alive() and not inDeep() and fdist(root2.Position, goal) > within do
                    if os.clock() - refT > 0.8 then
                        if fdist(root2.Position, ref) < 0.5 then
                            return false
                        end
                        ref, refT = root2.Position, os.clock()
                    end
                    if os.clock() - t0 > 0.5 and os.clock() - t0 < 0.55 then
                        hum:MoveTo(goal)
                    end
                    RunService.Heartbeat:Wait()
                end
                return true
            end
            local legAgents = { { AgentRadius = 2, AgentHeight = 5, AgentCanJump = false }, SM_AGENTS[1], SM_AGENTS[2] }
            for _, k in ipairs({ 6, 40 }) do
                local g = ground(ARCH + ARCH_IN * k + Vector3.new(0, c.Y + 4, 0))
                if g and alive() and not inDeep() and not straight(g, 3) then
                    walkTo(g, 3, alive, inDeep, false, legAgents)
                end
            end
            local g = ground(ARCH + ARCH_IN * 80 + ARCH_LEFT * 4 + Vector3.new(0, c.Y + 4, 0))
            if g and g.Y < floorY + 1.5 then
                deepGoal = g
                -- straight on (walkTo keeps moving while it plans): planning several goals first was a stop here
                if alive() and not inDeep() and not straight(g, 2) then
                    walkTo(g, 2, alive, inDeep, false, legAgents)
                end
            end
            if SM._isInArea and deepIn() then
                return true
            end
        end
        local goals = {}
        local pts = {}
        if deepGoal then
            table.insert(pts, Vector3.new(deepGoal.X, c.Y + 4, deepGoal.Z))
        end
        table.insert(pts, Vector3.new(c.X + d.X * 14, c.Y + 4, c.Z + d.Z * 14))
        table.insert(pts, Vector3.new(c.X + d.X * 8, c.Y + 4, c.Z + d.Z * 8))
        for _, p in ipairs(pts) do
            local g = ground(p)
            if g then
                local len
                for _, cfg in ipairs({ { AgentRadius = 2, AgentHeight = 5, AgentCanJump = false }, SM_AGENTS[1], SM_AGENTS[2] }) do
                    local path = PathfindingService:CreatePath(cfg)
                    local ok = pcall(function()
                        path:ComputeAsync(root.Position, g)
                    end)
                    if ok and path.Status == Enum.PathStatus.Success then
                        local w = path:GetWaypoints()
                        len = 0
                        for i = 2, #w do
                            len += (w[i].Position - w[i - 1].Position).Magnitude
                        end
                        table.insert(goals, { g = g, len = len, cfg = cfg })
                        break
                    end
                end
            end
        end
        table.sort(goals, function(a, b)
            return a.len < b.len
        end)
        for _, e in ipairs(goals) do
            if walkTo(e.g, 2, alive, function()
                return SM._isInArea and deepIn()
            end, true, { e.cfg, SM_AGENTS[1], SM_AGENTS[2] }) then
                return true
            end
            if (SM._isInArea and deepIn()) or not alive() then
                return SM._isInArea
            end
        end
        return SM._isInArea
    end

    -- Pumpkin Panic: each throw puts a ShadowPart on its landing spot under the throwing NPC; the pumpkin lands 2 s
    -- after the throw. One pumpkin at a time, the nearest one that can be reached in time (a special one first).
    local function playPumpkin(SM, mod, alive)
        local tag = SM:GetObjectTag("PumpkinPanic")
        local okT, tmpl = pcall(function()
            return PlayerModules._Event.HalloweenHandler.SeasonalMinigames.PumpkinPanicHandler.ShadowPart
        end)
        local baseY = okT and tmpl and tmpl.Size.Y or 0.1
        local seen = setmetatable({}, { __mode = "k" })
        local target, targetSp
        -- the throwers take turns between the two ends of the LandingBounds (the game flips one shared flag every
        -- throw), so between throws the player waits on the end the next pumpkin goes to
        local lastSide, idle
        local route
        local skip = setmetatable({}, { __mode = "k" })
        local castParams = RaycastParams.new()
        castParams.FilterType = Enum.RaycastFilterType.Exclude
        castParams.RespectCanCollide = true
        local midR, forceRoute, moving
        local crossesMid, wayAround, moveTowards, stalled

        -- radius of the solid middle around the game's Origin: the solid parts standing there (pie, cart) and the
        -- throwers (their parts may not collide, they still block the character)
        local function measureMid(origin)
            local op = OverlapParams.new()
            op.FilterType = Enum.RaycastFilterType.Exclude
            op.RespectCanCollide = true
            op.FilterDescendantsInstances = castParams.FilterDescendantsInstances
            local r = 0
            for _, p in ipairs(workspace:GetPartBoundsInRadius(origin, 14, op)) do
                local half = Vector2.new(p.Size.X, p.Size.Z).Magnitude / 2
                if not p:IsA("Terrain") and half < 12 and p.Position.Y + p.Size.Y / 2 > origin.Y + 0.6 then
                    r = math.max(r, math.min(fdist(p.Position, origin) + half, 14))
                end
            end
            for _, npc in CollectionService:GetTagged(tag) do
                if npc:IsA("Model") then
                    local d = fdist(npc:GetPivot().Position, origin)
                    if d < 14 then
                        r = math.max(r, d + 2)
                    end
                end
            end
            return math.clamp(r + 1.5, 6, 14)
        end

        -- does the straight line a -> b go through the middle?
        function crossesMid(a, b, origin)
            local ab = flat(b) - flat(a)
            local l2 = ab:Dot(ab)
            local t = l2 > 1e-6 and math.clamp((flat(origin) - flat(a)):Dot(ab) / l2, 0, 1) or 0
            return (flat(a) + ab * t - flat(origin)).Magnitude < midR
        end

        -- points around the middle on the circle (the shorter way round), then the goal; without the middle in the
        -- way: pathfinding waypoints (or straight)
        function wayAround(a, b, origin, viaCircle)
            local y = a.Y
            if viaCircle and origin and midR then
                local o = flat(origin)
                local rad = midR + 2.5
                local a0 = math.atan2(a.Z - o.Z, a.X - o.X)
                local a1 = math.atan2(b.Z - o.Z, b.X - o.X)
                local da = (a1 - a0 + math.pi) % (2 * math.pi) - math.pi
                local pts = {}
                if fdist(a, o) < rad - 0.5 then
                    table.insert(pts, Vector3.new(o.X + math.cos(a0) * rad, y, o.Z + math.sin(a0) * rad))
                end
                local n = math.max(1, math.ceil(math.abs(da) / math.rad(25)))
                for k = 1, n - 1 do
                    local ang = a0 + da * k / n
                    table.insert(pts, Vector3.new(o.X + math.cos(ang) * rad, y, o.Z + math.sin(ang) * rad))
                end
                table.insert(pts, b)
                return pts
            end
            for _, cfg in ipairs(SM_AGENTS) do
                local p = PathfindingService:CreatePath(cfg)
                local okP = pcall(function()
                    p:ComputeAsync(a, b)
                end)
                if okP and p.Status == Enum.PathStatus.Success then
                    local pts = {}
                    for i, w in ipairs(p:GetWaypoints()) do
                        if i > 1 then
                            table.insert(pts, w.Position)
                        end
                    end
                    if origin and midR then
                        local prev = a
                        for _, q in ipairs(pts) do
                            if crossesMid(prev, q, origin) then
                                return wayAround(a, b, origin, true)
                            end
                            prev = q
                        end
                    end
                    if #pts > 0 then
                        return pts
                    end
                end
            end
            return nil
        end

        -- MoveTo with a progress check: stalled() is true once the character made no headway for 0.7 s
        function moveTowards(p)
            local _, hum, root = getChar()
            if not (hum and root) then
                return
            end
            hum:MoveTo(p)
            if not moving or fdist(moving.goal, p) > 0.5 then
                moving = { goal = p, ref = root.Position, t = os.clock() }
            end
        end

        function stalled(root)
            if not moving then
                return false
            end
            if fdist(root.Position, moving.ref) > 0.5 or fdist(root.Position, moving.goal) <= 2 then
                moving.ref, moving.t = root.Position, os.clock()
                return false
            end
            if os.clock() - moving.t > 0.7 then
                moving = nil
                return true
            end
            return false
        end

        while alive() and current(SM) == "PumpkinPanic" do
            local plChars = {}
            for _, plr in ipairs(Players:GetPlayers()) do
                if plr.Character then
                    table.insert(plChars, plr.Character)
                end
            end
            castParams.FilterDescendantsInstances = plChars
            local char, hum, root = getChar()
            if hum and root then
                if not SM._isInArea then
                    enterArea(SM, alive)
                elseif not char:FindFirstChild("Bucket") then
                    status("Pumpkin Panic: waiting for the bucket")
                else
                    local now = os.clock()
                    local origin, bounds
                    local cands = {}
                    for _, npc in CollectionService:GetTagged(tag) do
                        if npc.Name:find("NPC") then
                            local aa = npc:FindFirstAncestor("AreaAssets")
                            local o = aa and aa:FindFirstChild("Origin")
                            origin = origin or (o and o.Position)
                            bounds = bounds or (aa and aa:FindFirstChild("LandingBounds"))
                            for _, s in npc:GetChildren() do
                                if s.Name == "ShadowPart" and s:IsA("BasePart") then
                                    if not seen[s] and origin and bounds then
                                        local lv = flat(bounds.CFrame.LookVector)
                                        if lv.Magnitude > 0.01 then
                                            lastSide = (flat(s.Position) - flat(origin)):Dot(lv.Unit) >= 0 and 1 or -1
                                        end
                                    end
                                    seen[s] = seen[s] or now
                                    table.insert(cands, {
                                        s = s,
                                        d = fdist(s.Position, root.Position),
                                        left = 2 - (now - seen[s]),
                                        sp = s.Size.Y > baseY * 1.08,
                                    })
                                end
                            end
                        end
                    end
                    if target and not target.Parent then
                        target, route = nil, nil
                    end
                    local speed = math.max(hum.WalkSpeed, 1)
                    local function reachable(c, dist)
                        -- the game catches it when the bucket is within 6 studs of the falling pumpkin
                        return math.max((dist or c.d) - 5, 0) / speed <= c.left + 0.1
                    end
                    local cur
                    for _, c in cands do
                        if c.s == target then
                            cur = c
                        end
                    end
                    if target and cur then
                        -- on the way (also while switching sides): a closer pumpkin that lands first is caught first
                        for _, c in cands do
                            if c.s ~= target and not skip[c.s] and c.d < cur.d and c.left <= cur.left and reachable(c) then
                                target, targetSp, route = c.s, c.sp, nil
                                cur = c
                                break
                            end
                        end
                    end
                    if not target then
                        local best, bs
                        for _, c in cands do
                            if not skip[c.s] and reachable(c) then
                                local score = c.d - (c.sp and 1000 or 0)
                                if not bs or score < bs then
                                    best, bs = c, score
                                end
                            end
                        end
                        if best then
                            target, targetSp, route = best.s, best.sp, nil
                            cur = best
                        end
                    end
                    if origin and not midR then
                        midR = measureMid(origin)
                    end
                    if target and cur and (route == nil or now - route.t > 0.25 or forceRoute) then
                        -- the middle (pie, cart, thrower) is solid: a way that crosses it goes around it on the circle;
                        -- anything else in the way is passed on pathfinding waypoints; straight again once the line is clear
                        local crossing = midR ~= nil and crossesMid(root.Position, target.Position, origin)
                        local blocked = crossing or forceRoute
                        local dir = flat(target.Position) - flat(root.Position)
                        if not blocked and dir.Magnitude > 2 then
                            local okB, hit = pcall(function()
                                return workspace:Blockcast(CFrame.new(root.Position - Vector3.new(0, 1, 0)), Vector3.new(2, 3.6, 2), dir, castParams)
                            end)
                            blocked = okB and hit ~= nil
                        end
                        if not blocked then
                            route = nil
                        elseif forceRoute or not (route and route.s == target) then
                            local pts = wayAround(root.Position, target.Position, origin, crossing or forceRoute)
                            local len, prev = 0, root.Position
                            for _, p in ipairs(pts or {}) do
                                len += fdist(p, prev)
                                prev = p
                            end
                            local left = cur.left - (os.clock() - now)
                            if pts and math.max(len - 5, 0) / speed <= left + 0.1 then
                                route = { s = target, pts = pts, i = 1, t = os.clock() }
                            else
                                skip[target] = true -- no way around in time: left for the next one
                                target, route = nil, nil
                            end
                        else
                            route.t = os.clock()
                        end
                        forceRoute = false
                    end
                    if target then
                        idle = nil
                        status("Pumpkin Panic: catching a " .. (targetSp and "special " or "") .. "pumpkin" .. tasksText(SM))
                        local p = route and route.pts[route.i]
                        while p and route.i < #route.pts and fdist(root.Position, p) <= 1.5 do
                            route.i += 1
                            p = route.pts[route.i]
                        end
                        moveTowards(p and route.i < #route.pts and p or target.Position)
                        if stalled(root) then
                            -- not getting anywhere (held up by something): around the middle once, then that pumpkin is dropped
                            if route then
                                skip[target] = true
                                target, route = nil, nil
                            else
                                forceRoute = true
                            end
                        end
                    else
                        status("Pumpkin Panic: waiting for a throw" .. tasksText(SM))
                        local lv = bounds and flat(bounds.CFrame.LookVector)
                        if origin and lv and lv.Magnitude > 0.01 then
                            lv = lv.Unit
                            local side = lastSide and -lastSide or ((flat(root.Position) - flat(origin)):Dot(lv) >= 0 and 1 or -1)
                            local spot = Vector3.new(origin.X + lv.X * side * 28, root.Position.Y, origin.Z + lv.Z * side * 28)
                            if fdist(root.Position, spot) > 3 then
                                -- around the middle on the circle; a new throw takes over at once
                                if not (idle and idle.side == side) then
                                    local cross = midR ~= nil and crossesMid(root.Position, spot, origin)
                                    idle = { side = side, i = 1, pts = wayAround(root.Position, spot, origin, cross) or { spot } }
                                end
                                local pts = idle.pts
                                while pts[idle.i] and idle.i < #pts and fdist(root.Position, pts[idle.i]) <= 2 do
                                    idle.i += 1
                                end
                                if pts[idle.i] then
                                    moveTowards(pts[idle.i])
                                    if stalled(root) then
                                        -- held up: the way to that spot is planned again from here, around the middle
                                        idle = { side = side, i = 1, pts = wayAround(root.Position, spot, origin, true) or { spot } }
                                    end
                                end
                            else
                                moving = nil
                            end
                        end
                    end
                end
            end
            RunService.Heartbeat:Wait()
        end
        stopWalk()
    end

    -- Chromatic Chaos: the round the game runs (correctColor = the orb, tombColors / specialTombs per tomb light)
    local function ccRound(mod)
        local ok, ups = pcall(debug.getupvalues, mod.StopMinigame)
        if ok and type(ups) == "table" then
            for _, v in pairs(ups) do
                if type(v) == "table" and rawget(v, "tombColors") ~= nil then
                    return v
                end
            end
        end
    end

    -- the tomb's door faces the tomb's LookVector (OuterDarkness / SkeletonArm sit on that side): the character
    -- stands on the floor just in front of the door, never against the walls
    local function goDoor(tomb, alive, abort)
        local char, _, root = getChar()
        if not root then
            return false
        end
        local pv = tomb:GetPivot()
        local look = flat(pv.LookVector)
        look = look.Magnitude > 0.01 and look.Unit or Vector3.new(0, 0, 1)
        local side = look:Cross(Vector3.yAxis)
        local okB, bcf, bsz = pcall(function()
            return tomb:GetBoundingBox()
        end)
        local front = 5
        if okB and bcf then
            local l = bcf:VectorToObjectSpace(look)
            local half = math.abs(l.X) * bsz.X / 2 + math.abs(l.Y) * bsz.Y / 2 + math.abs(l.Z) * bsz.Z / 2
            front = (bcf.Position - pv.Position):Dot(look) + half
        end
        local spots = {}
        for _, e in ipairs({ { 1.8, 0 }, { 3, 0 }, { 1.8, 1.5 }, { 1.8, -1.5 }, { 4.5, 0 } }) do
            local p = pv.Position + look * (front + e[1]) + side * e[2]
            local g = ground(Vector3.new(p.X, pv.Position.Y + 6, p.Z), { char, tomb })
            if g then
                table.insert(spots, g)
            end
        end
        for _, g in ipairs(spots) do
            if not alive() or (abort and abort()) then
                return false
            end
            if walkTo(g, 1.2, alive, abort, true) then
                return true
            end
        end
        return false
    end

    local function playChromatic(SM, mod, alive)
        local tag = SM:GetObjectTag("ChromaticChaos")
        local roundSeen, roundT0 = nil, 0
        while alive() and current(SM) == "ChromaticChaos" do
            local _, hum, root = getChar()
            local r = mod and ccRound(mod)
            if not (hum and root) then
                task.wait(0.3)
            elseif not SM._isInArea then
                enterArea(SM, alive)
            elseif r and r.active and not r.completed then
                if r ~= roundSeen then
                    roundSeen, roundT0 = r, os.clock()
                end
                local left = roundT0 + 10 - os.clock()
                local best, bs
                for _, tomb in CollectionService:GetTagged(tag) do
                    if tomb.Name == "Tomb" then
                        local lp = tomb:FindFirstChild("LightPart", true)
                        if lp and not r.interacted[lp] then
                            local sp = r.specialTombs[lp] == true
                            if sp or r.tombColors[lp] == r.correctColor then
                                local d = fdist(tomb:GetPivot().Position, root.Position)
                                local reach = (d * 1.3) / math.max(hum.WalkSpeed, 1) + 0.8 <= left
                                local score = d - ((sp and reach) and 1000 or 0)
                                if not bs or score < bs then
                                    best, bs = { tomb = tomb, sp = sp }, score
                                end
                            end
                        end
                    end
                end
                if best then
                    status("Chromatic Chaos: going to the matching " .. (best.sp and "special " or "") .. "tomb" .. tasksText(SM))
                    local function stale()
                        return r.completed or not r.active or ccRound(mod) ~= r
                    end
                    if goDoor(best.tomb, alive, stale) and not stale() then
                        local cb = gameCallback(best.tomb, "I_Knock")
                        if cb then
                            status("Chromatic Chaos: knocking")
                            stopWalk()
                            if not useCallback(cb) then
                                return
                            end
                            task.wait(0.3)
                        end
                    end
                else
                    task.wait(0.1)
                end
            else
                status("Chromatic Chaos: waiting for the orb's color" .. tasksText(SM))
                task.wait(0.1)
            end
            task.wait()
        end
        stopWalk()
    end

    -- Recipe Ritual: the book's request and what is carried are the handler's own state; dropping it off is the
    -- game's own check of the character inside the cauldron's DropOffArea
    local function rrState(mod)
        local ok, ups = pcall(debug.getupvalues, mod.InAreaUpdate)
        local req, carry, drop
        if ok and type(ups) == "table" then
            for _, v in pairs(ups) do
                if type(v) == "function" then
                    local ok2, ups2 = pcall(debug.getupvalues, v)
                    if ok2 and type(ups2) == "table" then
                        for _, w in pairs(ups2) do
                            if type(w) == "string" then
                                req = w
                            end
                        end
                    end
                elseif type(v) == "table" and rawget(v, "Name") ~= nil and rawget(v, "IsSpecial") ~= nil then
                    carry = v
                elseif typeof(v) == "Instance" and v:IsA("BasePart") then
                    drop = v
                end
            end
        end
        return req, carry, drop
    end

    local function playRecipe(SM, mod, alive)
        local tag = SM:GetObjectTag("RecipeRitual")
        local bad = {}
        while alive() and current(SM) == "RecipeRitual" do
            local _, hum, root = getChar()
            local req, carry, drop = rrState(mod)
            if not (hum and root) then
                task.wait(0.3)
            elseif not SM._isInArea then
                enterArea(SM, alive)
            elseif carry and drop then
                status("Recipe Ritual: bringing the " .. tostring(carry.Name) .. " to the cauldron" .. tasksText(SM))
                local rel = drop.CFrame:PointToObjectSpace(root.Position)
                local h = drop.Size / 2
                local inside = drop.CFrame:PointToWorldSpace(Vector3.new(
                    math.clamp(rel.X, -math.max(h.X - 1, 0), math.max(h.X - 1, 0)), 0,
                    math.clamp(rel.Z, -math.max(h.Z - 1, 0), math.max(h.Z - 1, 0))))
                local g = ground(Vector3.new(inside.X, drop.Position.Y + 2, inside.Z), { LocalPlayer.Character, drop }) or inside
                local function done()
                    local _, c2 = rrState(mod)
                    return c2 == nil
                end
                if not walkTo(g, 1, alive, done) and not done() then
                    hum:MoveTo(Vector3.new(drop.Position.X, root.Position.Y, drop.Position.Z))
                    local t0 = os.clock()
                    while alive() and os.clock() - t0 < 1.5 and not done() do
                        RunService.Heartbeat:Wait()
                    end
                end
                if not done() then
                    task.wait(0.2)
                end
            elseif req then
                local best, bs
                local now = os.clock()
                for _, o in CollectionService:GetTagged(tag) do
                    if o:GetAttribute("Ingredient") == req and o:GetAttribute("Respawning") ~= true and not (bad[o] and bad[o] > now)
                        and (not isMobile() or inAreaBox(o:GetPivot().Position, 2)) then
                        local d = fdist(o:GetPivot().Position, root.Position)
                        local score = d - (o:GetAttribute("IsSpecial") == true and 25 or 0)
                        if not bs or score < bs then
                            best, bs = o, score
                        end
                    end
                end
                if best then
                    local sp = best:GetAttribute("IsSpecial") == true
                    status("Recipe Ritual: getting the " .. (sp and "special " or "") .. req .. tasksText(SM))
                    local function gone()
                        local r2 = rrState(mod)
                        return best:GetAttribute("Respawning") == true or r2 ~= req
                    end
                    -- take it as soon as it is in reach (4.5 studs), not only after the stand spot itself is reached
                    local function inReach()
                        local _, _, r2 = getChar()
                        local bp = best:GetPivot().Position
                        return r2 ~= nil and fdist(r2.Position, bp) <= 4.5 and math.abs(r2.Position.Y - bp.Y) < 5
                    end
                    if (goNear(best, { 3, 4.5, 6 }, alive, function()
                        return gone() or inReach()
                    end) or inReach()) and not gone() then
                        local cb = gameCallback(best, "I_Take")
                        if cb then
                            stopWalk()
                            if not useCallback(cb) then
                                return
                            end
                            -- head for the cauldron while the game hands the ingredient over (no standing still)
                            local _, _, drop0 = rrState(mod)
                            local _, hum2, root2 = getChar()
                            if drop0 and hum2 and root2 then
                                hum2:MoveTo(Vector3.new(drop0.Position.X, root2.Position.Y, drop0.Position.Z))
                            end
                            local t0 = os.clock()
                            while alive() and os.clock() - t0 < 1.5 and select(2, rrState(mod)) == nil do
                                task.wait(0.05)
                            end
                            if select(2, rrState(mod)) == nil then
                                stopWalk() -- not picked up: don't wander off toward the cauldron
                            end
                        else
                            bad[best] = os.clock() + 3
                        end
                    elseif not gone() then
                        bad[best] = os.clock() + 10 -- no way to it: skipped for a while
                    end
                else
                    status("Recipe Ritual: waiting for a " .. tostring(req))
                    task.wait(0.2)
                end
            else
                status("Recipe Ritual: waiting for the book")
                task.wait(0.2)
            end
            task.wait()
        end
        stopWalk()
    end

    local function run(id)
        local function alive()
            return running and on and runId == id
        end
        while alive() do
            local SM = handler()
            local _, hum = getChar()
            if not SM then
                status("Seasonal Minigames not available")
                task.wait(2)
            elseif not hum then
                status("Waiting for character")
                task.wait(1)
            elseif not nearArea() then
                if not teleportAndWait(alive) then
                    task.wait(1)
                end
            else
                local name, mod = current(SM)
                keepInArea = name == "RecipeRitual"
                local ok, err = true, nil
                if name == "PumpkinPanic" then
                    ok, err = pcall(playPumpkin, SM, mod, alive)
                elseif name == "ChromaticChaos" then
                    ok, err = pcall(playChromatic, SM, mod, alive)
                elseif name == "RecipeRitual" then
                    ok, err = pcall(playRecipe, SM, mod, alive)
                else
                    if not SM._isInArea then
                        status("Walking into the event area")
                        enterArea(SM, alive)
                    end
                    local s = select(2, pcall(function()
                        return SM:BuildSchedule(1)[1]
                    end))
                    status(type(s) == "table" and ("Waiting: " .. prettyName(s.MinigameName) .. " starts in " .. fmtLeft(s.TimeLeft)) or "Waiting for the next minigame")
                    task.wait(0.5)
                end
                if not ok then
                    warn("[Legit Farm Job] seasonal minigames: " .. tostring(err))
                    status("Error, retrying")
                    stopWalk()
                    task.wait(1)
                end
                if alive() and (name == "PumpkinPanic" or name == "ChromaticChaos" or name == "RecipeRitual") then
                    dropHeld()
                end
            end
            task.wait()
        end
    end

    function M.stop()
        on = false
        runId += 1
        pcall(stopWalk)
        status("Idle")
    end

    function M.start()
        if on then
            return
        end
        on = true
        runId += 1
        local id = runId
        task.spawn(function()
            local ok, err = pcall(run, id)
            if not ok then
                warn("[Legit Farm Job] seasonal minigames: " .. tostring(err))
                status("Error, stopped")
            end
            if runId == id then
                M.stop()
                if toggleObj then
                    suppress = true
                    withUiIdentity(function()
                        toggleObj:Set(false)
                    end)
                    suppress = false
                end
            end
        end)
    end

    function M.teleport()
        if teleporting then
            return
        end
        if on then
            status("Turn the toggle off before teleporting")
            return
        end
        teleporting = true
        task.spawn(function()
            local ok, err = pcall(function()
                lastTp = -100
                local r = teleportAndWait(function()
                    return running
                end)
                status(r and "At Seasonal Minigames" or "Teleport did not finish")
            end)
            if not ok then
                warn("[Legit Farm Job] seasonal teleport: " .. tostring(err))
            end
            teleporting = false
        end)
    end

    function M.shutdown()
        gen += 1
        M.stop()
    end

    function M.buildUI(tab)
        tab:CreateSection("Seasonal Minigames")
        tab:CreateButton({
            Name = "Teleport to Seasonal Minigames",
            Callback = function()
                M.teleport()
            end,
        })
        toggleObj = tab:CreateToggle({
            Name = "Auto Seasonal Minigames",
            CurrentValue = false,
            Flag = "LFJ_SeasonalMinigames",
            Callback = function(value)
                if suppress then
                    return
                end
                if value then
                    M.start()
                else
                    M.stop()
                end
            end,
        })
        statusLabel = tab:CreateLabel("Status: Idle")
        schedLabels[1] = tab:CreateLabel("Now: -")
        schedLabels[2] = tab:CreateLabel("Next: -")
        schedLabels[3] = tab:CreateLabel("After that: -")
        local myGen = gen
        task.spawn(function()
            while running and gen == myGen do
                pcall(updateSchedule)
                task.wait(1)
            end
        end)
    end

    return M
end)()

-- Halloween: Ghost Hunt. Join circle Environment.Locations.City.Graveyard.Exterior.WorldDecor.GhostHunt.GhostHuntJoinArea
-- (attributes State = ReqPlayers / IntermissionCountdown / GameCountdown / InProgress, Count = players needed or seconds).
-- The round is the game's GhostHuntService session (SessionData.CurrentRole 1 = Ghost, 2 = Hunter; a caught ghost turns
-- hunter: GhostHuntHandler.IsHunter), timer = GameStartTimestamp + GAME_DURATION. Ghosts are tagged "GhostHunt:Ghost"
-- (their character), hunters "GhostHunt:Hunter" (a backpack with CharacterRef). A ghost in prop form has an invisible head.
NC.ghunt = (function()
    local M = {}
    local Ev = PlayerModules:WaitForChild("_Event")
    local GHMod = Ev:WaitForChild("GhostHuntHandler")
    local on, gen = false, 0
    local espGhosts, espHunters = false, false
    local statusLabel, lastStatus, espFolder, espConn
    local highlights = {}
    local platform, teleporting = nil, false

    local function status(text)
        if statusLabel and text ~= lastStatus then
            lastStatus = text
            withUiIdentity(function()
                statusLabel:Set("Status: " .. text)
            end)
        end
    end

    local function service()
        local ok, s = pcall(function()
            return JobHandler.Shared.EventService:GetEventModule("GhostHuntService")
        end)
        return ok and type(s) == "table" and s or nil
    end

    local function handler()
        local ok, h = pcall(require, GHMod)
        return ok and type(h) == "table" and h or nil
    end

    local function joinArea()
        local ok, ja = pcall(function()
            return workspace.Environment.Locations.City.Graveyard.Exterior.WorldDecor.GhostHunt.GhostHuntJoinArea
        end)
        return ok and ja or nil
    end

    -- the game's own teleport (same request as the hub's GO TO ACTIVITY: GoToEventArea / PositionType "GhostHunt"),
    -- sent by the game's WinterEventHandler.GoToEventArea, no UI
    local function fireTeleport()
        if DataService.FireServer ~= origFireServer or DataService.InvokeServer ~= origInvokeServer then
            return false, "unsafe state"
        end
        local mod = Ev:FindFirstChild("WinterEventHandler")
        local okE, W = pcall(require, mod)
        local f = okE and type(W) == "table" and W.GoToEventArea
        local env = type(f) == "function" and getfenv(f)
        if not (f and not (isexecutorclosure and isexecutorclosure(f)) and env and env.script == mod
            and type(W.net) == "table" and W.net.InvokeServer == origInvokeServer) then
            return false, "teleport not ready"
        end
        task.spawn(function()
            pcall(f, W, "GhostHunt")
        end)
        return true
    end

    local function teleportAndWait(alive)
        local _, _, root0 = getChar()
        local from = root0 and root0.Position
        local ok, why = fireTeleport()
        if not ok then
            status("Teleport failed (" .. tostring(why) .. ")")
            return false
        end
        status("Teleporting to Ghost Hunt")
        local t0 = os.clock()
        task.wait(1)
        while alive() and os.clock() - t0 < 40 do
            local _, hum, root = getChar()
            local okL, loading = pcall(function()
                return JobHandler.Modules.LoadingHandler:IsLoadingAny()
            end)
            local ja = joinArea()
            if hum and root and ja and not (okL and loading) and not root.Anchored
                and (flat(root.Position) - flat(ja.Position)).Magnitude < 150
                and (not from or (root.Position - from).Magnitude > 30 or os.clock() - t0 > 8) then
                return true
            end
            task.wait(0.3)
        end
        return false
    end

    -- Walking: Humanoid:MoveTo along pathfinding waypoints, the next waypoint is taken before the current one is
    -- reached so it walks without stopping
    local AGENTS = { { AgentRadius = 1.5, AgentHeight = 5, AgentCanJump = false }, { AgentRadius = 1, AgentHeight = 4, AgentCanJump = true } }
    local function walkTo(goal, within, alive, abort, maxTime)
        local t00 = os.clock()
        for attempt = 1, 3 do
            local _, hum, root = getChar()
            if not (hum and root) or not alive() or (abort and abort()) then
                return false
            end
            if (flat(root.Position) - flat(goal)).Magnitude <= within then
                return true
            end
            if attempt == 1 then
                hum:MoveTo(goal)
            end
            local path
            for _, cfg in ipairs(AGENTS) do
                local p = PathfindingService:CreatePath(cfg)
                local ok = pcall(function()
                    p:ComputeAsync(root.Position, goal)
                end)
                if ok and p.Status == Enum.PathStatus.Success then
                    path = p
                    break
                end
            end
            if not path then
                return false
            end
            local wps = path:GetWaypoints()
            local blocked = false
            for i = 2, #wps do
                local wp = wps[i].Position
                if wps[i].Action == Enum.PathWaypointAction.Jump then
                    hum.Jump = true
                    if hum.FloorMaterial ~= Enum.Material.Air then
                        hum:ChangeState(Enum.HumanoidStateType.Jumping)
                    end
                end
                hum:MoveTo(wp)
                local t0, ref, refT = os.clock(), root.Position, os.clock()
                local r = i < #wps and 2 or math.max(1.2, within)
                while true do
                    if not alive() or (abort and abort()) then
                        return false
                    end
                    if maxTime and os.clock() - t00 > maxTime then
                        return false
                    end
                    if (flat(root.Position) - flat(wp)).Magnitude <= r or (flat(root.Position) - flat(goal)).Magnitude <= within then
                        break
                    end
                    if os.clock() - t0 > 4 then
                        blocked = true
                        break
                    end
                    if os.clock() - refT > 0.8 then
                        if (flat(root.Position) - flat(ref)).Magnitude < 0.5 then
                            blocked = true
                            break
                        end
                        ref, refT = root.Position, os.clock()
                    end
                    RunService.Heartbeat:Wait()
                end
                if blocked or (flat(root.Position) - flat(goal)).Magnitude <= within then
                    break
                end
            end
            if (flat(root.Position) - flat(goal)).Magnitude <= within + 0.5 then
                return true
            end
        end
        return false
    end

    -- players by role
    local function ghostChars(S)
        local out = {}
        for _, m in ipairs(CollectionService:GetTagged(S.GHOST_TAG)) do
            if m:IsA("Model") and m ~= LocalPlayer.Character and m:FindFirstChild("HumanoidRootPart") then
                table.insert(out, m)
            end
        end
        return out
    end

    local function hunterChars(S)
        local out = {}
        for _, b in ipairs(CollectionService:GetTagged(S.HUNTER_TAG)) do
            local cr = b:FindFirstChild("CharacterRef")
            local c = cr and cr.Value
            if c and c ~= LocalPlayer.Character and c:FindFirstChild("HumanoidRootPart") then
                table.insert(out, c)
            end
        end
        return out
    end

    -- a ghost's HumanoidRootPart is welded to its ghost body (GhostHuntItems "Part"); as a prop it is also welded to the
    -- prop's Origin (another GhostHuntItems model). Seen live: the head is invisible in both forms.
    local function inGhostForm(m)
        local hrp = m:FindFirstChild("HumanoidRootPart")
        if not hrp then
            return false
        end
        local gp = workspace:FindFirstChild("Plots")
        gp = gp and gp:FindFirstChild("Plot_[GHOSTHUNT]")
        local items = gp and gp:FindFirstChild("GhostHuntItems")
        for _, j in ipairs(hrp:GetJoints()) do
            local o = j.Part0 == hrp and j.Part1 or j.Part0
            if o and items and o:IsDescendantOf(items) then
                local top = o
                while top.Parent ~= items do
                    top = top.Parent
                end
                if top.Name ~= "Part" and top.Name ~= "HunterBackpack" then
                    return false
                end
            end
        end
        return true
    end

    -- the player's control script resets Humanoid.Jump every frame, so the jump state is set directly
    local function jump(hum)
        hum.Jump = true
        if hum.FloorMaterial ~= Enum.Material.Air then
            hum:ChangeState(Enum.HumanoidStateType.Jumping)
        end
    end

    local function healthOf(S, m)
        local plr = Players:GetPlayerFromCharacter(m)
        local mod = ReplicatedStorage:FindFirstChild("Modules")
        mod = mod and mod:FindFirstChild("EventService")
        mod = mod and mod:FindFirstChild("GhostHuntService")
        local v = plr and mod and mod:FindFirstChild(tostring(plr.UserId) .. "_Health")
        return v and v.Value or S.MAX_HEALTH
    end

    -- ESP
    local function syncESP()
        local S = service()
        local want = {}
        if S and (espGhosts or espHunters) then
            if espGhosts then
                for _, m in ipairs(ghostChars(S)) do
                    want[m] = "ghost"
                end
            end
            if espHunters then
                for _, m in ipairs(hunterChars(S)) do
                    want[m] = "hunter"
                end
            end
        end
        for m, h in pairs(highlights) do
            if want[m] ~= h.kind or not m.Parent then
                h.obj:Destroy()
                highlights[m] = nil
            end
        end
        if next(want) and not (espFolder and espFolder.Parent) then
            espFolder = Instance.new("Folder")
            espFolder.Name = "LFJ_GhostHuntESP"
            espFolder.Parent = gethui and gethui() or game:GetService("CoreGui")
        end
        for m, kind in pairs(want) do
            if not highlights[m] then
                local h = Instance.new("Highlight")
                h.Adornee = m
                h.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
                h.FillTransparency = 0.5
                h.FillColor = kind == "ghost" and Color3.fromRGB(150, 230, 255) or Color3.fromRGB(255, 70, 70)
                h.OutlineColor = Color3.new(1, 1, 1)
                h.Parent = espFolder
                highlights[m] = { obj = h, kind = kind }
            end
        end
    end

    local function updateESPLoop()
        if (espGhosts or espHunters) and not espConn then
            local acc = 0
            espConn = RunService.Heartbeat:Connect(function(dt)
                acc += dt
                if acc >= 0.5 then
                    acc = 0
                    pcall(syncESP)
                end
            end)
        elseif not (espGhosts or espHunters) and espConn then
            espConn:Disconnect()
            espConn = nil
        end
        pcall(syncESP)
    end

    local function stopWalk()
        local _, hum, root = getChar()
        if hum and root then
            hum:MoveTo(root.Position)
        end
    end

    local function removePlatform()
        if platform then
            platform:Destroy()
            platform = nil
        end
    end

    local function timeLeft(S, GH)
        if GH and GH.GameStartTimestamp then
            return math.max(0, math.floor(S.GAME_DURATION - (tick() - GH.GameStartTimestamp)))
        end
    end

    -- Ghost: under the house floor on a platform only this client has, out of reach until the round ends
    local function playGhost(S, GH, alive)
        local _, hum, root = getChar()
        if not root then
            return
        end
        if not platform or not platform.Parent then
            local x, z = root.Position.X, root.Position.Z
            -- below the lowest part of the Ghost Hunt plot (floors of every storey, the water under it), not below
            -- where the character spawned (seen live: spawning upstairs left it only just under the ground floor)
            local floorY = root.Position.Y - 3
            -- (GhostHuntItems is left out: the game stores parts far down there, at -485 live)
            local gp = workspace:FindFirstChild("Plots")
            gp = gp and gp:FindFirstChild("Plot_[GHOSTHUNT]")
            local parts = {}
            local house, water = gp and gp:FindFirstChild("House"), gp and gp:FindFirstChild("Water")
            for _, d in ipairs(house and house:GetDescendants() or {}) do
                table.insert(parts, d)
            end
            if water then
                table.insert(parts, water)
            end
            for _, d in ipairs(parts) do
                if d:IsA("BasePart") then
                    floorY = math.min(floorY, d.Position.Y - d.Size.Y / 2)
                end
            end
            floorY = math.max(floorY, workspace.FallenPartsDestroyHeight + 90)
            platform = Instance.new("Part")
            platform.Name = "LFJ_GhostHuntFloor"
            platform.Anchored = true
            platform.CanCollide = true
            platform.Transparency = 1
            platform.Size = Vector3.new(14, 1, 14)
            platform.CFrame = CFrame.new(x, floorY - 34, z)
            platform.Parent = workspace
            root.CFrame = CFrame.new(x, floorY - 30.5, z)
            root.AssemblyLinearVelocity = Vector3.zero
        elseif root.Position.Y > platform.Position.Y + 10 or (flat(root.Position) - flat(platform.Position)).Magnitude > 6 then
            root.CFrame = platform.CFrame + Vector3.new(0, 3.5, 0)
            root.AssemblyLinearVelocity = Vector3.zero
        end
        local left = timeLeft(S, GH)
        status("Ghost: hiding under the map" .. (left and (" (" .. left .. "s left)") or ""))
        task.wait(0.5)
    end

    -- Hunter: chase the nearest ghost in ghost form; with none, wait next to the prop that turns back soonest
    local function playHunter(S, GH, alive)
        local _, hum, root = getChar()
        if not root then
            return
        end
        local best, bd
        for _, m in ipairs(ghostChars(S)) do
            if inGhostForm(m) then
                local d = (m.HumanoidRootPart.Position - root.Position).Magnitude
                if not bd or d < bd then
                    best, bd = m, d
                end
            end
        end
        local left = timeLeft(S, GH)
        local tl = left and (" (" .. left .. "s left)") or ""
        if best then
            status("Hunter: chasing " .. best.Name .. tl)
            local tr = best.HumanoidRootPart
            local dy = tr.Position.Y - root.Position.Y
            local hd = (flat(tr.Position) - flat(root.Position)).Magnitude
            if hd < 12 and dy > -4 and dy < 9 then
                -- close: straight at it; jump when it is above (ghosts jump to get away) or when not getting closer
                hum:MoveTo(tr.Position)
                local p0 = root.Position
                task.wait(0.15)
                if (dy > 2 and hd < 7) or (hd > 3 and (flat(root.Position) - flat(p0)).Magnitude < 0.3) then
                    jump(hum)
                end
            else
                walkTo(tr.Position, 2, alive, function()
                    return not (best.Parent and inGhostForm(best)) or (tr.Position - root.Position).Magnitude < 8
                end, 1.5)
            end
            return
        end
        local prop, ph
        for _, m in ipairs(ghostChars(S)) do
            local h = healthOf(S, m)
            if not ph or h < ph then
                prop, ph = m, h
            end
        end
        if prop then
            status("Hunter: no ghost in ghost form, waiting by the prop that turns back soonest" .. tl)
            local pr = prop.HumanoidRootPart
            if (pr.Position - root.Position).Magnitude > 7 then
                walkTo(pr.Position, 5, alive, function()
                    for _, m in ipairs(ghostChars(S)) do
                        if inGhostForm(m) then
                            return true
                        end
                    end
                    return false
                end, 2)
            else
                task.wait(0.2)
            end
        else
            status("Hunter: no ghosts left" .. tl)
            task.wait(0.5)
        end
    end

    local function loop(alive)
        while alive() do
            local S, GH = service(), handler()
            local _, hum, root = getChar()
            local ja = joinArea()
            if not (S and GH) then
                status("Ghost Hunt not available")
                task.wait(2)
            elseif not (hum and root) then
                status("Waiting for character")
                task.wait(1)
            elseif S.SessionData then
                if root.Anchored then
                    status((GH.IsHunter and "Hunter" or "Ghost") .. ": round starting")
                    task.wait(0.3)
                elseif GH.GameOver then
                    status("Round over")
                    task.wait(0.5)
                elseif GH.IsHunter or S.SessionData.CurrentRole == S.ROLES.Hunter then
                    playHunter(S, GH, alive)
                else
                    playGhost(S, GH, alive)
                end
            elseif platform and (root.Position - platform.Position).Magnitude < 50 then
                -- the round is over but the game has not moved the character back yet: keep standing on it
                status("Round over: waiting to be sent back")
                task.wait(0.3)
            else
                removePlatform()
                if not ja or (flat(root.Position) - flat(ja.Position)).Magnitude > 300 then
                    if not teleportAndWait(alive) then
                        task.wait(2)
                    end
                elseif (flat(root.Position) - flat(ja.Position)).Magnitude > 5 then
                    status("Walking into the Ghost Hunt circle")
                    local g = ja.Position
                    local rp = RaycastParams.new()
                    rp.FilterType = Enum.RaycastFilterType.Exclude
                    local list = {}
                    for _, plr in ipairs(Players:GetPlayers()) do
                        if plr.Character then
                            table.insert(list, plr.Character)
                        end
                    end
                    rp.FilterDescendantsInstances = list
                    local h = workspace:Raycast(g + Vector3.new(0, 8, 0), Vector3.new(0, -30, 0), rp)
                    if not walkTo(h and h.Position or g, 3, alive) then
                        task.wait(1)
                    end
                else
                    local st, n = ja:GetAttribute("State"), ja:GetAttribute("Count")
                    if st == "ReqPlayers" then
                        status("In the circle: waiting for " .. tostring(n) .. " more player(s)")
                    elseif st == "IntermissionCountdown" then
                        status("In the circle: next round in " .. tostring(n) .. "s")
                    elseif st == "GameCountdown" then
                        status("In the circle: round starts in " .. tostring(n) .. "s")
                    elseif st == "InProgress" then
                        status("A round is in progress: waiting for the next one")
                    else
                        status("In the circle")
                    end
                    task.wait(0.3)
                end
            end
            task.wait()
        end
    end

    function M.stop()
        on = false
        gen += 1
        stopWalk()
        status("Idle")
        -- the platform under the map is only removed once the round is over (removing it now would drop the
        -- character into the void)
        if platform then
            local p = platform
            platform = nil
            task.spawn(function()
                local t0 = os.clock()
                while os.clock() - t0 < 240 do
                    local S = service()
                    local _, _, r = getChar()
                    if not (S and S.SessionData) and not (r and (r.Position - p.Position).Magnitude < 50) then
                        break
                    end
                    task.wait(1)
                end
                p:Destroy()
            end)
        end
    end

    function M.start()
        if on then
            return
        end
        on = true
        gen += 1
        local myGen = gen
        local function alive()
            return running and on and gen == myGen
        end
        task.spawn(function()
            local ok, err = pcall(loop, alive)
            if not ok then
                warn("[Legit Farm Job] ghost hunt: " .. tostring(err))
                if gen == myGen then
                    status("Error, stopped")
                end
            end
        end)
    end

    function M.teleport()
        if teleporting then
            return
        end
        if on then
            status("Turn Auto Ghost Hunt off before teleporting")
            return
        end
        teleporting = true
        task.spawn(function()
            local r = teleportAndWait(function()
                return running
            end)
            status(r and "At Ghost Hunt" or "Teleport did not finish")
            teleporting = false
        end)
    end

    function M.shutdown()
        if on then
            M.stop()
        end
        on = false
        gen += 1
        espGhosts, espHunters = false, false
        if espConn then
            espConn:Disconnect()
            espConn = nil
        end
        for m, h in pairs(highlights) do
            h.obj:Destroy()
            highlights[m] = nil
        end
        if espFolder then
            espFolder:Destroy()
            espFolder = nil
        end
    end

    function M.buildUI(tab)
        tab:CreateSection("Ghost Hunt")
        tab:CreateButton({
            Name = "Teleport to Ghost Hunt",
            Callback = function()
                M.teleport()
            end,
        })
        tab:CreateToggle({
            Name = "ESP Ghosts",
            CurrentValue = false,
            Flag = "LFJ_GhostHuntESPGhosts",
            Callback = function(v)
                espGhosts = v
                updateESPLoop()
            end,
        })
        tab:CreateToggle({
            Name = "ESP Hunters",
            CurrentValue = false,
            Flag = "LFJ_GhostHuntESPHunters",
            Callback = function(v)
                espHunters = v
                updateESPLoop()
            end,
        })
        tab:CreateToggle({
            Name = "Auto Ghost Hunt",
            CurrentValue = false,
            Flag = "LFJ_AutoGhostHunt",
            Callback = function(v)
                if v then
                    M.start()
                elseif on then
                    M.stop()
                end
            end,
        })
        statusLabel = tab:CreateLabel("Status: Idle")
    end

    return M
end)()

-- Troll: Remove Build Mode Barrier. A player in build mode gets Workspace.Plots.Plot_<name>.Barrier (tag "PlotBarrier",
-- made by the game's PlotService:CreateBarrier on the "CreateBarrier" event). Its "Main" part (252 x 400 x 252, collision
-- group PlotBarrier) is the one that blocks characters and vehicles; the black walls are its "Barrier" parts' Decals.
-- The barrier is made on this client by the game, so it is taken out of the workspace here (this client only) the moment
-- it appears (also every new one the server sends with "CreateBarrier": no flash) and kept; turning the toggle off puts
-- it back. Build mode itself is the game's PlotService:GetBuildPlot(player) (not the barrier); when the player leaves
-- build mode the toggle turns itself off.
NC.troll = (function()
    local M = {}
    local CS = game:GetService("CollectionService")
    local PlotService = require(ReplicatedStorage.Modules.PlotService)
    local on, gen = false, 0
    local selected
    local byLabel = {}
    local conns = {}
    local dropdown, statusLabel, lastStatus, toggleObj
    local kept -- { model = removed Barrier, plot = its plot }
    local addConn
    local suppress = false

    local function status(text)
        if statusLabel and text ~= lastStatus then
            lastStatus = text
            withUiIdentity(function()
                statusLabel:Set("Status: " .. text)
            end)
        end
    end

    local function plotOf(plr)
        local plots = workspace:FindFirstChild("Plots")
        return plots and plots:FindFirstChild("Plot_" .. plr.Name)
    end

    local function building(plr, plot)
        local ok, bp = pcall(function()
            return PlotService:GetBuildPlot(plr)
        end)
        return ok and plot ~= nil and bp == plot
    end

    -- out of the workspace, kept to be put back
    local function park(b)
        if kept and kept.model ~= b then
            pcall(function()
                kept.model:Destroy() -- an older one: the game replaced it
            end)
        end
        kept = { model = b, plot = b.Parent }
        b.Parent = nil
    end

    local function insideBox(model)
        local main = model:FindFirstChild("Main")
        local _, _, root = getChar()
        if not (main and root) then
            return false
        end
        local rel = main.CFrame:PointToObjectSpace(root.Position)
        return math.abs(rel.X) < main.Size.X / 2 + 3 and math.abs(rel.Z) < main.Size.Z / 2 + 3
    end

    -- the kept barrier goes back to its plot (only while that player is still building, and only once this character
    -- is outside it: put back around the character it would push it under the ground)
    local function restore(myGen)
        local k = kept
        if not k then
            return
        end
        task.spawn(function()
            while running and kept == k and not on and gen == myGen do
                local owner = k.plot and k.plot.Parent and Players:FindFirstChild((k.plot.Name:gsub("^Plot_", "")))
                if not (owner and building(owner, k.plot)) or k.plot:FindFirstChild("Barrier") then
                    pcall(function()
                        k.model:Destroy()
                    end)
                    kept = nil
                    return
                end
                if not insideBox(k.model) then
                    k.model.Parent = k.plot
                    kept = nil
                    status("Idle (barrier put back)")
                    return
                end
                status("Barrier comes back once you are out of the plot")
                task.wait(0.3)
            end
        end)
    end

    local function setToggle(v)
        if toggleObj then
            suppress = true
            withUiIdentity(function()
                toggleObj:Set(v)
            end)
            suppress = false
        end
    end


    local function labels()
        table.clear(byLabel)
        local out = {}
        for _, plr in ipairs(Players:GetPlayers()) do
            local l = plr.DisplayName .. " (@" .. plr.Name .. ")"
            byLabel[l] = plr
            table.insert(out, l)
        end
        table.sort(out, function(a, b)
            return a:lower() < b:lower()
        end)
        return out
    end

    local function refresh()
        local list = labels()
        if dropdown then
            withUiIdentity(function()
                dropdown:Refresh(list)
            end)
        end
    end

    function M.stop(text)
        on = false
        gen += 1
        if addConn then
            addConn:Disconnect()
            addConn = nil
        end
        status(text or "Idle")
        restore(gen)
    end

    function M.start()
        if on then
            return
        end
        local plr = selected
        local plot = plr and plr.Parent == Players and plotOf(plr)
        if not plot then
            status("Select a player first")
            setToggle(false)
            return
        end
        if not building(plr, plot) then
            status(plr.DisplayName .. " is not in build mode (no barrier)")
            setToggle(false)
            return
        end
        on = true
        gen += 1
        local myGen = gen
        -- a barrier is taken away in the same frame it is added (the server sends a new one now and then)
        addConn = CS:GetInstanceAddedSignal("PlotBarrier"):Connect(function(b)
            if on and gen == myGen and b.Name == "Barrier" and b.Parent == plot then
                pcall(park, b)
            end
        end)
        local b = plot:FindFirstChild("Barrier")
        if b and CS:HasTag(b, "PlotBarrier") then
            pcall(park, b)
        end
        status("Barrier removed for " .. plr.DisplayName)
        task.spawn(function()
            while running and on and gen == myGen do
                if selected ~= plr or plr.Parent ~= Players or not building(plr, plot) then
                    local gone = selected == plr
                    M.stop(gone and "User has gone out of build mode." or "Idle")
                    setToggle(false)
                    if gone then
                        kept = nil -- the game removes the barrier when building ends
                    end
                    return
                end
                local b2 = plot:FindFirstChild("Barrier")
                if b2 and CS:HasTag(b2, "PlotBarrier") then
                    pcall(park, b2)
                end
                task.wait(0.2)
            end
        end)
    end

    function M.shutdown()
        M.stop()
        for _, c in ipairs(conns) do
            pcall(function()
                c:Disconnect()
            end)
        end
        table.clear(conns)
    end

    function M.buildUI(tab)
        tab:CreateSection("Build Mode Barrier")
        dropdown = tab:CreateDropdown({
            Name = "Player",
            Options = labels(),
            CurrentOption = {},
            MultipleOptions = false,
            Flag = "LFJ_TrollPlayer",
            Callback = function(option)
                local l = type(option) == "table" and option[1] or option
                selected = l and byLabel[l] or nil
            end,
        })
        toggleObj = tab:CreateToggle({
            Name = "Remove Build Mode Barrier",
            CurrentValue = false,
            Flag = "LFJ_TrollBarrier",
            Callback = function(v)
                if suppress then
                    return
                end
                if v then
                    M.start()
                elseif on then
                    M.stop()
                end
            end,
        })
        statusLabel = tab:CreateLabel("Status: Idle")
        -- a build barrier left on another player's plot when nobody builds there any more (seen live: munchlaxlv100 out
        -- of build mode, PlotService:GetBuildPlot = nil, the Barrier still standing) is taken off with the game's own
        -- PlotService:RemoveBarrier, the same call its "RemoveBarriers" event uses
        task.spawn(function()
            while running do
                pcall(function()
                    local plots = workspace:FindFirstChild("Plots")
                    for _, b in ipairs(CS:GetTagged("PlotBarrier")) do
                        local plot = b.Parent
                        local owner = plot and plot.Parent == plots and b.Name == "Barrier"
                            and Players:FindFirstChild((plot.Name:gsub("^Plot_", "")))
                        if owner and owner ~= LocalPlayer then
                            local builders = PlotService:GetPlotBuilders(plot)
                            if builders and #builders == 0 then
                                PlotService:RemoveBarrier(plot)
                            end
                        end
                    end
                end)
                task.wait(1)
            end
        end)
        table.insert(conns, Players.PlayerAdded:Connect(refresh))
        table.insert(conns, Players.PlayerRemoving:Connect(function(plr)
            task.defer(refresh)
        end))
    end

    return M
end)()

-- Auto Cook (own plot). Found live: the fridge's own "Take Ingredients" (InteractionData) asks
-- CookingUI:ShowIngredientFrame() for the pick and then sends {Type = "TakeIngredient", Name = pick._itemName}; the
-- ingredients are equipped with FoodIngredient (the food) and CookProgress (the step done so far). Each step of the
-- item's CookRecipe is the counter's / stove's own menu option (Stir, Cut, Mix, Garnish ... on a counter; Fry, Boil,
-- Bake ... on a stove), done by the server while the character is attached. Steps with LeaveFood (Bake ...) leave the
-- food in the appliance (ObjectData.CookingFood); when it is done the server adds ObjectData.TakeFoodEvent and the
-- appliance offers "Take". The pop-ups while cooking are the game's QTE (MinigameHandler.QTE, net:HookFunction("QTE")):
-- the answer goes through a BindableEvent the QTE module parents to itself, fired with true on a tap / key press.
-- The finished food is put away with the fridge's own "Store".
NC.autocook = (function()
    local M = {}
    local QTEMod = PlayerModules:WaitForChild("_UI"):WaitForChild("MinigameHandler"):WaitForChild("QTE")
    -- the lock the game's own build menu shows on locked items (MainGUI.BuildMenu ... LockedLabel)
    local LOCK_IMAGE = "rbxassetid://2826726111"
    local autoStore = true
    local on, gen = false, 0
    local popupsOn = false
    local qteConn
    local selected = {} -- item name -> true
    local byLabel, labelOf, foods = {}, {}, {}
    local dropdown, statusLabel, lastStatus, toggleObj
    local suppress = false
    local lastSkill
    local qty = {} -- item name -> how many to cook (default 1)
    local runTag -- "Garden Salad 1/2" while Auto Cook runs
    local baseStatus -- the status text without the tag (the countdown redraws it every second)
    -- the food being cooked now: { it, total, doneBefore (step time already done), stepStart, stepDur }
    local cooking

    local function status(text)
        baseStatus = text
        if on and runTag then
            text = text .. " [" .. runTag .. "]"
        end
        if statusLabel and text ~= lastStatus then
            lastStatus = text
            withUiIdentity(function()
                statusLabel:Set("Status: " .. text)
            end)
        end
    end

    local function cookSkill()
        local st = ReplicatedStorage:FindFirstChild("Stats")
        st = st and st:FindFirstChild(LocalPlayer.Name)
        local sd = st and st:FindFirstChild("SkillData")
        local v = sd and sd:FindFirstChild("Cooking")
        return v and v.Value or 0
    end

    local function needLevel(it)
        return tonumber(it.CookSkill) or 0
    end

    -- the cooking pop-ups: answered after a short, human time (both the tap button and the key button)
    local function updateQTE()
        local want = popupsOn or on
        if want and not qteConn then
            qteConn = QTEMod.ChildAdded:Connect(function(b)
                if b:IsA("BindableEvent") then
                    -- answered right away: deferred so the game's QTE thread is already waiting on the event (it
                    -- reaches Event:wait() without yielding after parenting it), fired again each frame until the QTE
                    -- has taken it (it destroys the event then)
                    task.defer(function()
                        for _ = 1, 30 do
                            if not ((popupsOn or on) and b.Parent == QTEMod) then
                                return
                            end
                            pcall(function()
                                b:Fire(true)
                            end)
                            RunService.Heartbeat:Wait()
                        end
                    end)
                end
            end)
        elseif not want and qteConn then
            qteConn:Disconnect()
            qteConn = nil
        end
    end

    -- Food list (the same list the fridge shows)
    local function loadFoods()
        table.clear(foods)
        table.clear(byLabel)
        table.clear(labelOf)
        local ok = pcall(function()
            for _, it in pairs(JobHandler.Items.CookableFoods) do
                if it.CookRecipe and not it.IsQuickFood and not it:IsHidden(LocalPlayer) then
                    table.insert(foods, it)
                end
            end
        end)
        if not ok then
            return {}
        end
        table.sort(foods, function(a, b)
            if needLevel(a) ~= needLevel(b) then
                return needLevel(a) < needLevel(b)
            end
            return a.Name < b.Name
        end)
        local labels = {}
        for _, it in ipairs(foods) do
            local okN, n = pcall(function()
                return JobHandler.Modules.TranslationHandler:FormatItem(it.CookName or it.Name)
            end)
            local label = okN and type(n) == "string" and n ~= "" and n or it.Name
            if byLabel[label] then
                label = it.Name
            end
            byLabel[label], labelOf[it.Name] = it, label
            table.insert(labels, label)
        end
        return labels
    end

    local function dropdownFrame()
        for _, root in ipairs({ gethui and gethui() or game:GetService("CoreGui"), game:GetService("CoreGui") }) do
            local rf = root:FindFirstChild("Rayfield")
            local el = rf and rf:FindFirstChild("Main") and rf.Main:FindFirstChild("Elements")
            local page = el and el:FindFirstChild("Auto Cook")
            local d = page and page:FindFirstChild("Food")
            if d then
                return d
            end
        end
    end

    -- how long one of a food takes: the game's own duration of each step of its CookRecipe (FoodService.CookActions;
    -- "A/B" = the shorter one)
    local function cookTime(it)
        local total = 0
        pcall(function()
            local CA = JobHandler.Shared.FoodService.CookActions
            for _, s in ipairs(it.CookRecipe or {}) do
                local best
                for _, n in ipairs(type(s) == "table" and s or { s }) do
                    local d = CA[n] and CA[n].Duration
                    if d and (not best or d < best) then
                        best = d
                    end
                end
                total += best or 0
            end
        end)
        return total
    end

    local function fmtTime(s)
        s = math.floor(s + 0.5)
        return string.format("%d:%02d", s // 60, s % 60)
    end

    -- icon in front of every food, a lock behind the ones above the player's cooking level
    local uiIdentity
    local function decorate()
        uiIdentity()
        local frame = dropdownFrame()
        local list = frame and frame:FindFirstChild("List")
        if not list then
            return
        end
        local skill = cookSkill()
        for _, row in ipairs(list:GetChildren()) do
            local it = row:IsA("Frame") and byLabel[row.Name]
            local title = it and row:FindFirstChild("Title")
            if it and title then
                if not row:FindFirstChild("FoodIcon") and it.Icon then
                    local img = Instance.new("ImageLabel")
                    img.Name = "FoodIcon"
                    img.BackgroundTransparency = 1
                    img.Image = "rbxassetid://" .. tostring(it.Icon)
                    img.Size = UDim2.fromOffset(26, 26)
                    img.AnchorPoint = Vector2.new(0, 0.5)
                    img.Position = UDim2.new(0, 10, 0.5, 0)
                    img.Parent = row
                    title.Position = UDim2.new(title.Position.X.Scale, title.Position.X.Offset + 34, title.Position.Y.Scale, title.Position.Y.Offset)
                    title.Size = UDim2.new(title.Size.X.Scale, title.Size.X.Offset - 34, title.Size.Y.Scale, title.Size.Y.Offset)
                end
                -- cook time (the game's step durations, FoodService.CookActions) x quantity, and the quantity box of a
                -- selected food
                local timer = row:FindFirstChild("CookTimer")
                if not timer then
                    title.Size = UDim2.new(title.Size.X.Scale, title.Size.X.Offset - 110, title.Size.Y.Scale, title.Size.Y.Offset)
                    timer = Instance.new("TextLabel")
                    timer.Name = "CookTimer"
                    timer.BackgroundTransparency = 1
                    timer.Font = title.Font
                    timer.TextSize = 13
                    timer.TextColor3 = title.TextColor3
                    timer.TextTransparency = 0.25
                    timer.TextXAlignment = Enum.TextXAlignment.Right
                    timer.Size = UDim2.fromOffset(70, 20)
                    timer.AnchorPoint = Vector2.new(1, 0.5)
                    timer.Position = UDim2.new(1, -84, 0.5, 0)
                    timer.Parent = row
                    local box = Instance.new("TextBox")
                    box.Name = "CookQty"
                    box.ZIndex = 60 -- above the row's Interact button, so a click goes into the box
                    box.BackgroundColor3 = Color3.fromRGB(45, 45, 45)
                    box.BorderSizePixel = 0
                    box.Font = title.Font
                    box.TextSize = 14
                    box.TextColor3 = Color3.new(1, 1, 1)
                    box.ClearTextOnFocus = false
                    box.Text = tostring(qty[it.Name] or 1)
                    box.Size = UDim2.fromOffset(36, 24)
                    box.AnchorPoint = Vector2.new(1, 0.5)
                    box.Position = UDim2.new(1, -42, 0.5, 0)
                    Instance.new("UICorner", box).CornerRadius = UDim.new(0, 4)
                    local st = Instance.new("UIStroke", box)
                    st.Color = Color3.fromRGB(90, 90, 90)
                    st.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
                    box.Parent = row
                    box.FocusLost:Connect(function()
                        local n = math.clamp(math.floor(tonumber(box.Text) or qty[it.Name] or 1), 1, 99)
                        qty[it.Name] = n
                        box.Text = tostring(n)
                        timer.Text = fmtTime(cookTime(it) * n)
                    end)
                end
                local box = row:FindFirstChild("CookQty")
                box.Visible = selected[it.Name] == true
                if not (cooking and cooking.it == it) then -- (the food being cooked shows its countdown)
                    timer.Text = fmtTime(cookTime(it) * (selected[it.Name] and qty[it.Name] or 1))
                end
                local lock = row:FindFirstChild("LockIcon")
                if not lock then
                    lock = Instance.new("ImageLabel")
                    lock.Name = "LockIcon"
                    lock.BackgroundTransparency = 1
                    lock.Image = LOCK_IMAGE
                    lock.ImageColor3 = Color3.fromRGB(200, 200, 200)
                    lock.Size = UDim2.fromOffset(22, 22)
                    lock.AnchorPoint = Vector2.new(1, 0.5)
                    lock.Position = UDim2.new(1, -12, 0.5, 0)
                    lock.Parent = row
                end
                lock.Visible = needLevel(it) > skill
            end
        end
    end

    -- Walking: Humanoid:MoveTo along PathfindingService waypoints, the next waypoint taken before the current one
    local function stopWalk()
        local _, hum, root = getChar()
        if hum and root then
            hum:MoveTo(root.Position)
        end
    end

    local function walkTo(goal, alive)
        for _ = 1, 3 do
            local _, hum, root = getChar()
            if not (hum and root) or not alive() then
                return false
            end
            if (flat(root.Position) - flat(goal)).Magnitude <= 2 then
                return true
            end
            local wps
            for _, cfg in ipairs(AGENT_TRIES) do
                local p = PathfindingService:CreatePath(cfg)
                local ok = pcall(function()
                    p:ComputeAsync(root.Position, goal)
                end)
                if ok and p.Status == Enum.PathStatus.Success then
                    wps = p:GetWaypoints()
                    break
                end
            end
            -- no path (the goal sits right at the appliance): walk straight at it
            local pts = {}
            if wps then
                for i = 2, #wps do
                    pts[#pts + 1] = wps[i].Position
                end
            else
                pts[1] = goal
            end
            local blocked = false
            for i, wp in ipairs(pts) do
                hum:MoveTo(wp)
                local r = i < #pts and 2 or 1.2
                local ref, refT, t0 = root.Position, os.clock(), os.clock()
                while true do
                    if not alive() then
                        return false
                    end
                    if (flat(root.Position) - flat(wp)).Magnitude <= r or (flat(root.Position) - flat(goal)).Magnitude <= 2 then
                        break
                    end
                    if os.clock() - t0 > 5 then
                        blocked = true
                        break
                    end
                    if os.clock() - refT > 0.8 then
                        if (flat(root.Position) - flat(ref)).Magnitude < 0.5 then
                            blocked = true
                            break
                        end
                        ref, refT = root.Position, os.clock()
                    end
                    RunService.Heartbeat:Wait()
                end
                if blocked or (flat(root.Position) - flat(goal)).Magnitude <= 2 then
                    break
                end
            end
            if (flat(root.Position) - flat(goal)).Magnitude <= 2.5 then
                return true
            end
        end
        return false
    end

    local function walkToObj(obj, alive)
        local ap = obj:FindFirstChild("AttachPos")
        local goal = ap and ap:IsA("Attachment") and ap.WorldPosition or obj:GetPivot().Position
        return walkTo(goal, alive)
    end

    -- The game's own menus
    local function closeMenu()
        pcall(function()
            InteractionHandler:CloseMenu()
        end)
    end

    local function plain(t)
        return (tostring(t or ""):gsub("%[ICON:%d+%]", ""))
    end

    local function tr(key, fallback)
        local ok, s = pcall(function()
            return JobHandler.Modules.TranslationHandler:Format(key)
        end)
        return ok and type(s) == "string" and s ~= "" and s ~= key and s or fallback
    end

    local function clickMenu(obj, match)
        if not (InteractionHandler and DataService.FireServer == origFireServer and DataService.InvokeServer == origInvokeServer) then
            return false
        end
        closeMenu()
        local ok, m = pcall(function()
            return InteractionHandler:ShowMenu(obj)
        end)
        local idx
        if ok and type(m) == "table" and type(m.Buttons) == "table" then
            for k, v in pairs(m.Buttons) do
                if match(plain(v.Text)) then
                    idx = k
                end
            end
        end
        if not idx then
            closeMenu()
            return false
        end
        task.spawn(function()
            pcall(function()
                m:Click(idx)
            end)
        end)
        return true
    end

    -- the options an object offers right now (the game's InteractionData texts, no menu opened)
    local function options(obj)
        local out = {}
        pcall(function()
            for _, g in ipairs(JobHandler.Shared.InteractionData:GetData(obj, LocalPlayer, {}) or {}) do
                if type(g) == "function" then
                    local okG, text = pcall(g)
                    if okG and text then
                        table.insert(out, plain(text))
                    end
                end
            end
        end)
        return out
    end

    local function attached()
        local ok, w = pcall(function()
            return JobHandler.Shared.AttachService:GetAttachWeld(LocalPlayer.Character)
        end)
        return ok and w ~= nil
    end

    local function equipped()
        local ok, e = pcall(function()
            return JobHandler.Shared.EquipmentService:GetEquipped(LocalPlayer)
        end)
        return ok and e or nil
    end

    local function waitFor(cond, timeout, alive)
        local t0 = os.clock()
        while alive() and os.clock() - t0 < timeout do
            if cond() then
                return true
            end
            task.wait(0.1)
        end
        return cond()
    end

    -- Kitchen objects on the player's own plot
    local function kitchen()
        local plots = workspace:FindFirstChild("Plots")
        local plot = plots and plots:FindFirstChild("Plot_" .. LocalPlayer.Name)
        local house = plot and plot:FindFirstChild("House")
        local fridges, stations = {}, {}
        for _, group in ipairs(house and house:GetChildren() or {}) do
            for _, obj in ipairs(group:GetChildren()) do
                if obj:FindFirstChild("ObjectModel") and obj:FindFirstChild("AttachPos") then
                    local ok, it = pcall(function()
                        return JobHandler.Items:GetItem(obj.Name)
                    end)
                    if ok and it then
                        local okF, isFridge = pcall(function()
                            return it:IsType("Fridge")
                        end)
                        if okF and isFridge then
                            table.insert(fridges, obj)
                        elseif it.Type == "Counters" or it.Type == "Appliances" then
                            table.insert(stations, obj)
                        end
                    end
                end
            end
        end
        local _, _, root = getChar()
        local function byDist(a, b)
            return root and (a:GetPivot().Position - root.Position).Magnitude < (b:GetPivot().Position - root.Position).Magnitude
        end
        if root then
            table.sort(fridges, byDist)
            table.sort(stations, byDist)
        end
        return fridges[1], stations
    end

    local function stepNames(it, progress)
        local s = it.CookRecipe and it.CookRecipe[progress + 1]
        if s == nil then
            return nil
        end
        return type(s) == "table" and s or { s }
    end

    -- 1. ingredients out of the fridge (the fridge's own "Take Ingredients"; its picker is answered with the food)
    local function takeIngredients(fridge, it, alive)
        local CU = JobHandler.Modules and JobHandler.Modules.CookingUI
        local orig = type(CU) == "table" and rawget(CU, "ShowIngredientFrame")
        if not (type(orig) == "function" and not (isexecutorclosure and isexecutorclosure(orig))) then
            return false
        end
        local used = false
        CU.ShowIngredientFrame = function()
            used = true
            CU.ShowIngredientFrame = orig
            -- answered once the server has put the character at the fridge (like a player picking from the list)
            local t0 = os.clock()
            while not attached() and os.clock() - t0 < 3 do
                task.wait(0.05)
            end
            task.wait(0.4)
            return { _itemName = it.Name }
        end
        local clicked = clickMenu(fridge, function(t)
            return t == tr("I_TakeIngredients", "Take Ingredients") or t == "Take Ingredients"
        end)
        if clicked then
            waitFor(function()
                return used
            end, 4, alive)
        end
        if CU.ShowIngredientFrame ~= orig then
            CU.ShowIngredientFrame = orig
        end
        closeMenu()
        return clicked and waitFor(function()
            local e = equipped()
            local fi = e and e:FindFirstChild("FoodIngredient")
            return fi ~= nil and fi.Value == it.Name and not attached()
        end, 6, alive)
    end

    -- 2. one step of the recipe on a counter / appliance that offers it
    local function doStep(stations, it, names, alive)
        local wanted = {}
        for _, n in ipairs(names) do
            wanted[tr("I_Cooking" .. n, n)] = n
            wanted[n] = n
        end
        local station, stepName
        for _, obj in ipairs(stations) do
            for _, t in ipairs(options(obj)) do
                if wanted[t] then
                    station, stepName = obj, wanted[t]
                    break
                end
            end
            if station then
                break
            end
        end
        if not station then
            status("No counter / appliance here can " .. table.concat(names, " or ") .. " (" .. it.Name .. ")")
            return false, "no station"
        end
        local action = JobHandler.Shared.FoodService.CookActions[stepName] or {}
        status(stepName .. ": walking to the " .. station.Name)
        if not walkToObj(station, alive) then
            return false, "can't reach the " .. station.Name
        end
        local e0 = equipped()
        local cp0 = e0 and e0:FindFirstChild("CookProgress") and e0.CookProgress.Value
        status(stepName .. " (" .. it.Name .. ")")
        if not clickMenu(station, function(t)
            return wanted[t] ~= nil
        end) then
            return false, stepName .. " not offered"
        end
        local od = station:FindFirstChild("ObjectData")
        local cf = od and od:FindFirstChild("CookingFood")
        -- started: attached to it, or the food is left in it
        if not waitFor(function()
            return attached() or (cf and cf.Value ~= "") or (e0 and e0.Parent == nil)
        end, 4, alive) then
            closeMenu()
            return false, stepName .. " did not start"
        end
        if cooking then
            -- the countdown runs from here (the step has started) for the step's own duration
            cooking.stepStart, cooking.stepDur = os.clock(), action.Duration or 0
        end
        closeMenu()
        if attached() then
            status(stepName .. " (" .. it.Name .. "), answering the pop-ups")
            waitFor(function()
                return not attached()
            end, (action.Duration or 30) * 3 + 20, alive)
        end
        if cf and cf.Value ~= "" and not equipped() then
            -- left in the appliance: taken out when it is done (the appliance adds TakeFoodEvent)
            status(stepName .. ": waiting for the " .. it.Name .. " in the " .. station.Name)
            if not waitFor(function()
                return od:FindFirstChild("TakeFoodEvent") ~= nil
            end, 600, alive) then
                return false, stepName .. " did not finish"
            end
            task.wait(0.3 + math.random() * 0.3)
            if not walkToObj(station, alive) then
                return false, "can't reach the " .. station.Name
            end
            status("Taking the " .. it.Name .. " out of the " .. station.Name)
            clickMenu(station, function(t)
                return t == tr("I_Take", "Take") or t == "Take"
            end)
            waitFor(function()
                return equipped() ~= nil and not attached()
            end, 6, alive)
            closeMenu()
        end
        -- the food comes back into the hand a moment after the step ends (seen live: nothing equipped right at the end
        -- of a Fry)
        local function changed()
            local e1 = equipped()
            local cp1 = e1 and e1:FindFirstChild("CookProgress")
            return e1 ~= nil and e1 ~= e0 or (e1 ~= nil and (cp1 == nil or cp1.Value ~= cp0))
        end
        return waitFor(changed, 5, alive), stepName .. " gave nothing"
    end

    -- 3. the finished food into the fridge (the fridge's own "Store")
    local function storeFood(fridge, alive)
        status("Walking to the " .. fridge.Name)
        if not walkToObj(fridge, alive) then
            return false
        end
        status("Storing the food")
        clickMenu(fridge, function(t)
            return t == tr("I_Store", "Store") or t == "Store"
        end)
        local ok = waitFor(function()
            return equipped() == nil and not attached()
        end, 8, alive)
        closeMenu()
        return ok
    end

    local function cookOne(it, alive)
        local fridge, stations = kitchen()
        if not fridge then
            status("No fridge found on your plot")
            return false
        end
        if needLevel(it) > cookSkill() then
            status(it.Name .. " is locked (cooking level " .. needLevel(it) .. ")")
            return false
        end
        local e = equipped()
        local fi = e and e:FindFirstChild("FoodIngredient")
        -- already holding this food (its ingredients, or the cooked food itself) goes on from there
        if e and not (fi and fi.Value == it.Name) and not (tostring(e) == it.Name and not e:FindFirstChild("CookProgress")) then
            status("Put away what you are holding first")
            return false
        end
        if not e then
            status("Walking to the " .. fridge.Name)
            if not walkToObj(fridge, alive) then
                status("Can't reach the " .. fridge.Name)
                return false
            end
            status("Taking the " .. it.Name .. " ingredients")
            if not takeIngredients(fridge, it, alive) then
                if alive() then
                    status("Could not take the " .. it.Name .. " ingredients (money / level?)")
                end
                return false
            end
        end
        for _ = 1, 12 do
            if not alive() then
                return false
            end
            e = equipped()
            local cp = e and e:FindFirstChild("CookProgress")
            if not e then
                return false
            end
            if not cp then
                break -- cooked
            end
            local names = stepNames(it, cp.Value)
            if not names then
                break
            end
            local ok, why = doStep(stations, it, names, alive)
            if cooking and cooking.stepStart then
                cooking.doneBefore += cooking.stepDur
                cooking.stepStart = nil
            end
            if not ok then
                if alive() then
                    status(it.Name .. ": " .. tostring(why))
                end
                return false
            end
            task.wait(0.3 + math.random() * 0.3)
        end
        e = equipped()
        if not (e and not e:FindFirstChild("CookProgress")) then
            return false
        end
        if not autoStore then
            return true, "kept"
        end
        return storeFood(fridge, alive)
    end

    local function setToggle(v)
        if toggleObj then
            suppress = true
            withUiIdentity(function()
                toggleObj:Set(v)
            end)
            suppress = false
        end
    end

    function M.stop(text)
        on = false
        gen += 1
        updateQTE()
        closeMenu()
        stopWalk()
        status(text or "Idle")
        if cooking then
            cooking = nil
            pcall(decorate) -- the countdown row shows its cook time again
        end
    end

    function M.start()
        if on then
            return
        end
        -- each selected food as many times as its quantity, in list order (Garden Salad x2, then Gelatin Cake x5 ...)
        local list, nth = {}, {}
        for _, it in ipairs(foods) do
            if selected[it.Name] then
                local n = qty[it.Name] or 1
                for k = 1, n do
                    table.insert(list, it)
                    nth[#list] = k .. "/" .. n
                end
            end
        end
        if #list == 0 then
            status("Select food first")
            setToggle(false)
            return
        end
        on = true
        gen += 1
        local myGen = gen
        local function alive()
            return running and on and gen == myGen
        end
        updateQTE()
        task.spawn(function()
            local ok, err = pcall(function()
                local done, failed, kept = 0, 0, nil
                for i, it in ipairs(list) do
                    if not alive() then
                        return
                    end
                    local tag = it.Name .. " " .. nth[i]
                    cooking = { it = it, total = cookTime(it), doneBefore = 0 }
                    local cur = cooking
                    runTag = tag .. ", " .. fmtTime(cur.total) .. " left"
                    -- live countdown: time left on this food (runs while a step is cooking, holds while walking),
                    -- on its row in the list and in the status; it stops at 0:00 when the food is done
                    task.spawn(function()
                        while alive() and cooking == cur do
                            local used = cur.doneBefore
                            if cur.stepStart then
                                used += math.min(os.clock() - cur.stepStart, cur.stepDur)
                            end
                            local text = fmtTime(math.max(cur.total - used, 0)) .. " left"
                            runTag = tag .. ", " .. text
                            pcall(function()
                                uiIdentity()
                                local frame = dropdownFrame()
                                local row = frame and frame.List:FindFirstChild(labelOf[it.Name] or "")
                                local timer = row and row:FindFirstChild("CookTimer")
                                if timer then
                                    timer.Text = text
                                end
                            end)
                            if baseStatus then
                                status(baseStatus)
                            end
                            task.wait(0.25)
                        end
                    end)
                    local ok, how = cookOne(it, alive)
                    cooking = nil
                    pcall(decorate) -- the row shows its cook time again
                    if ok then
                        done += 1
                        if how == "kept" then
                            -- Auto Store off: the food stays in hand, and no more ingredients can be taken while holding it
                            kept = it
                            break
                        end
                    else
                        failed += 1
                        task.wait(2)
                    end
                end
                if alive() then
                    if kept then
                        M.stop("Done: " .. kept.Name .. " cooked, in your hand (Auto Store is off)"
                            .. (#list > done + failed and ", the rest needs Auto Store on" or ""))
                    else
                        M.stop(("Done: %d cooked and stored%s"):format(done, failed > 0 and (", " .. failed .. " not") or ""))
                    end
                    setToggle(false)
                end
            end)
            if not ok then
                warn("[Legit Farm Job] auto cook: " .. tostring(err))
                if gen == myGen then
                    M.stop("Error, stopped")
                    setToggle(false)
                end
            end
        end)
    end

    function M.shutdown()
        popupsOn = false
        if on then
            M.stop()
        end
        on = false
        gen += 1
        updateQTE()
    end

    -- the game calls that build the food list drop this thread's identity; Rayfield needs it back
    function uiIdentity()
        if setIdentity and UI_IDENTITY then
            pcall(setIdentity, UI_IDENTITY)
        end
    end

    function M.buildUI(tab)
        local labels = loadFoods()
        uiIdentity()
        tab:CreateSection("Auto Cook")
        dropdown = tab:CreateDropdown({
            Name = "Food",
            Options = labels,
            CurrentOption = {},
            MultipleOptions = true,
            Flag = "LFJ_CookFood",
            Callback = function(option)
                local opts = type(option) == "table" and option or { option }
                table.clear(selected)
                for _, l in ipairs(opts) do
                    local it = byLabel[l]
                    if it then
                        selected[it.Name] = true
                    end
                end
                pcall(decorate) -- quantity boxes on the selected foods
            end,
        })
        toggleObj = tab:CreateToggle({
            Name = "Auto Cook",
            CurrentValue = false,
            Flag = "LFJ_AutoCook",
            Callback = function(v)
                if suppress then
                    return
                end
                if v then
                    M.start()
                elseif on then
                    M.stop("Idle")
                end
            end,
        })
        tab:CreateToggle({
            Name = "Auto Store",
            CurrentValue = true,
            Flag = "LFJ_CookAutoStore",
            Callback = function(v)
                autoStore = v
            end,
        })
        statusLabel = tab:CreateLabel("Status: Idle")
        tab:CreateSection("Cooking pop-ups")
        tab:CreateToggle({
            Name = "Auto Complete Cooking Popups",
            CurrentValue = false,
            Flag = "LFJ_CookPopups",
            Callback = function(v)
                popupsOn = v
                updateQTE()
            end,
        })
        decorate()
        -- the locks follow the cooking level
        task.spawn(function()
            while running do
                local s = cookSkill()
                if s ~= lastSkill then
                    lastSkill = s
                    pcall(decorate)
                end
                task.wait(2)
            end
        end)
    end

    return M
end)()

-- BFF Supermarket - Cashier (job id SupermarketCashier). Found live in the game's own JobHandler.SupermarketCashier
-- module: the registers are Environment.Locations.City.Supermarket.Interior.CashierWorkstations ("Workstation" x4); the
-- shift starts by itself when the character walks into the register area. Per register: BagHolder ("I_Take" = TakeNewBag,
-- "I_Restock" = RestockBags while holding "BFF Bags" and BagsLeft is 0), Bags (a bag on the counter is open when its
-- Transparency is 0; the game lets an item be scanned while an open bag has 3 children or fewer), DroppedFood (the
-- customer's items, "I_Scan" = ScanDroppedItem), Display.Screen.CashierGUI.Frame.Done (its Activated = the game's done()),
-- Occupied (the customer; Status "" while placing, "placed" when every item is down, ScannedObjects / PlacedObjects).
-- The bag boxes are Supermarket.Geometry.Crates "BagCrate" ("I_Take" = TakeNewBags with empty hands).
NC.market = (function()
    local K = {}
    local JOB = "SupermarketCashier"
    local station -- the one register of this shift
    local outerSetStatus = setStatus
    local function setStatus(text)
        if farming then
            outerSetStatus(text)
        end
    end

    local function alive()
        return running and farming
    end

    local function pause(a, b)
        local t = a + math.random() * (b - a)
        local t0 = os.clock()
        while alive() and os.clock() - t0 < t do
            task.wait(0.03)
        end
    end

    local function waitUntil(cond, timeout)
        local t0 = os.clock()
        while alive() and os.clock() - t0 < timeout do
            if cond() then
                return true
            end
            task.wait(0.05)
        end
        return cond()
    end

    local function market()
        local env = workspace:FindFirstChild("Environment")
        local n = env
        for _, name in ipairs({ "Locations", "City", "Supermarket" }) do
            n = n and n:FindFirstChild(name)
        end
        return n
    end

    -- the game's own interaction callback of an object (only the game's closures, checked like every other job)
    local function callback(obj, wanted)
        local reg = getInteractRegistry()
        local entry = reg and obj and reg[obj]
        local gens = entry and entry[1]
        for _, gen in ipairs(type(gens) == "table" and gens or {}) do
            if type(gen) == "function" then
                local ok, text, _, cb = pcall(gen)
                if ok and text == wanted and type(cb) == "function" then
                    return cb
                end
            end
        end
    end

    local function use(cb)
        if not cleanSafe(cb) then
            farming = false
            if FarmToggle then
                withUiIdentity(function()
                    FarmToggle:Set(false)
                end)
            end
            outerSetStatus("Stopped: unsafe supermarket state")
            return false
        end
        pcall(cb)
        return true
    end

    local function floorAt(x, z, y)
        local params = RaycastParams.new()
        params.FilterType = Enum.RaycastFilterType.Exclude
        local ignore = {}
        for _, plr in ipairs(Players:GetPlayers()) do
            if plr.Character then
                table.insert(ignore, plr.Character)
            end
        end
        params.FilterDescendantsInstances = ignore
        local h = workspace:Raycast(Vector3.new(x, y + 6, z), Vector3.new(0, -14, 0), params)
        return h and h.Position
    end

    -- the cashier's spot: on the far side of the scanner from the customers (live: register 1 scanner 491.6,-710.8,
    -- customers at x 487-488, the shift started walking in at 497,-713)
    local function standOf(w)
        local scanner = w:FindFirstChild("Scanner")
        local cust = w:FindFirstChild("CustomerTarget_2") or w:FindFirstChild("CustomerTarget_1")
        if not (scanner and cust) then
            return nil
        end
        local d = Vector3.new(scanner.Position.X - cust.Position.X, 0, scanner.Position.Z - cust.Position.Z)
        d = d.Magnitude > 0.1 and d.Unit or Vector3.new(1, 0, 0)
        local p = scanner.Position + d * 3.6
        return floorAt(p.X, p.Z, scanner.Position.Y) or Vector3.new(p.X, scanner.Position.Y - 1.9, p.Z)
    end

    local function takenByOther(w)
        local u = w:FindFirstChild("InUse") and w.InUse.Value
        if typeof(u) == "Instance" and u ~= LocalPlayer and u.Parent == Players then
            return true
        end
        local sp = standOf(w)
        for _, plr in ipairs(Players:GetPlayers()) do
            local r = plr ~= LocalPlayer and plr.Character and plr.Character:FindFirstChild("HumanoidRootPart")
            if r and sp and (Vector3.new(r.Position.X, 0, r.Position.Z) - Vector3.new(sp.X, 0, sp.Z)).Magnitude < 4 then
                return true
            end
        end
        return false
    end

    -- one of the 4 registers at random (a free one), kept for the whole shift
    local function pickStation()
        local sm = market()
        local ws = sm and sm:FindFirstChild("Interior") and sm.Interior:FindFirstChild("CashierWorkstations")
        local free = {}
        for _, w in ipairs(ws and ws:GetChildren() or {}) do
            if w:FindFirstChild("BagHolder") and w:FindFirstChild("DroppedFood") and not takenByOther(w) then
                table.insert(free, w)
            end
        end
        if #free == 0 then
            return nil
        end
        return free[math.random(#free)]
    end

    local function flatDist(a, b)
        return (Vector3.new(a.X, 0, a.Z) - Vector3.new(b.X, 0, b.Z)).Magnitude
    end

    -- walking: the script's own walkTo (Humanoid:MoveTo along pathfinding waypoints, the next waypoint taken before
    -- the current one is reached, so it does not stop and start)
    local function walk(goal)
        for _ = 1, 3 do
            if not alive() then
                return false
            end
            local _, _, root = getChar()
            if root and flatDist(root.Position, goal) < 2 then
                return true
            end
            if walkTo(goal) then
                return true
            end
            task.wait(0.3)
        end
        local _, _, root = getChar()
        return root ~= nil and flatDist(root.Position, goal) < 3
    end

    local function openBag(w)
        for _, b in ipairs(w.Bags:GetChildren()) do
            if b.Transparency == 0 and #b:GetChildren() <= 3 then
                return b
            end
        end
    end

    local function equippedName()
        local ok, e = pcall(function()
            return JobHandler.Shared.EquipmentService:GetEquipped(LocalPlayer)
        end)
        return ok and e and tostring(e) or nil
    end

    -- the register is out of bags: the BAGS boxes ("BagCrate"), Take, back to the register, Restock
    local function refill(w, stand)
        local sm = market()
        local crates = sm and sm:FindFirstChild("Geometry") and sm.Geometry:FindFirstChild("Crates")
        local _, _, root = getChar()
        if not (crates and root) then
            return false
        end
        if equippedName() ~= "BFF Bags" then
            local list = {}
            for _, c in ipairs(crates:GetChildren()) do
                if c.Name == "BagCrate" then
                    table.insert(list, { c = c, d = (c:GetPivot().Position - root.Position).Magnitude })
                end
            end
            table.sort(list, function(a, b)
                return a.d < b.d
            end)
            local got = false
            for _, e in ipairs(list) do
                if not alive() or got then
                    break
                end
                local p = e.c:GetPivot().Position
                setStatus("Out of bags: walking to the BAGS boxes")
                for _, off in ipairs({ { 0, 3.5 }, { 3.5, 0 }, { -3.5, 0 }, { 0, -3.5 }, { 0, 5 }, { 5, 0 }, { -5, 0 }, { 0, -5 } }) do
                    local spot = floorAt(p.X + off[1], p.Z + off[2], p.Y)
                    if spot and math.abs(spot.Y - root.Position.Y + 3) < 2.5 and walk(spot) then
                        local cb = callback(e.c, "I_Take")
                        if cb then
                            setStatus("Taking bags")
                            pause(0.2, 0.4)
                            if not use(cb) then
                                return false
                            end
                            got = waitUntil(function()
                                return equippedName() == "BFF Bags"
                            end, 3)
                        end
                        break
                    end
                end
            end
            if not got then
                setStatus("Could not take bags, trying again")
                return false
            end
        end
        setStatus("Bringing the bags to the register")
        if not walk(stand) then
            return false
        end
        local before = w.BagsLeft.Value
        local cb
        waitUntil(function()
            cb = callback(w.BagHolder, "I_Restock")
            return cb ~= nil
        end, 3)
        if not cb then
            return false
        end
        setStatus("Restocking the bags")
        pause(0.2, 0.4)
        if not use(cb) then
            return false
        end
        return waitUntil(function()
            return w.BagsLeft.Value > before
        end, 4)
    end

    function K.step()
        if not farming then
            task.wait(0.3)
            return
        end
        local _, hum, root = getChar()
        if not hum then
            setStatus("Waiting for character")
            task.wait(1)
            return
        end
        if not (station and station.Parent) then
            -- back after Auto Farm was off: the register it worked at last, when its customer is still there (and no
            -- other player works it); otherwise one at random as before
            local last = K.last
            if last and last.Parent and last:FindFirstChild("Occupied") and last.Occupied.Value and not takenByOther(last) then
                station = last
            else
                station = pickStation()
            end
            K.last = station
            if not station then
                setStatus("No free register, waiting")
                task.wait(1.5)
                return
            end
        end
        local w = station
        local stand = standOf(w)
        if not stand then
            setStatus("Register not found, waiting")
            task.wait(1)
            return
        end
        if flatDist(root.Position, stand) > 3 then
            setStatus("Walking to the register")
            if not walk(stand) then
                setStatus("Can't reach the register, retrying")
                task.wait(1)
            end
            return
        end
        if not isWorkingJob(JOB) then
            -- the shift starts by itself at the register
            setStatus("Starting the shift at the register")
            waitUntil(function()
                return isWorkingJob(JOB)
            end, 3)
            return
        end
        local npc = w.Occupied.Value
        local items = w.DroppedFood:GetChildren()
        if w.BagsLeft.Value < 1 and not openBag(w) then
            if not refill(w, stand) then
                task.wait(1)
            end
            return
        end
        if not npc then
            setStatus("Waiting for customer")
            task.wait(0.3)
            return
        end
        local st = npc:FindFirstChild("Status")
        if not st then
            task.wait(0.2)
            return
        end
        if #items > 0 then
            -- 1. a bag (again when the open one is full: 3 items)
            if not openBag(w) then
                local cb = callback(w.BagHolder, "I_Take")
                if not cb then
                    setStatus("Waiting for a bag")
                    task.wait(0.3)
                    return
                end
                setStatus("Taking a bag")
                if not use(cb) then
                    return
                end
                waitUntil(function()
                    return openBag(w) ~= nil
                end, 3)
                pause(0.35, 0.6)
                return
            end
            -- 2. scan the items one by one, at a person's pace
            local scanned = st:FindFirstChild("ScannedObjects")
            local before = scanned and scanned.Value or 0
            for _, item in ipairs(items) do
                local cb = item.Parent and callback(item, "I_Scan")
                if cb then
                    setStatus("Scanning " .. item.Name)
                    if not use(cb) then
                        return
                    end
                    waitUntil(function()
                        return item.Parent == nil or (scanned and scanned.Value > before)
                    end, 3)
                    pause(0.45, 0.75)
                    return
                end
            end
            task.wait(0.2)
            return
        end
        -- 3. every item scanned and the customer has put everything down: Done
        local placed = st:FindFirstChild("PlacedObjects")
        local scanned = st:FindFirstChild("ScannedObjects")
        if st.Value == "placed" and placed and scanned and scanned.Value >= placed.Value then
            local done = w.Display:FindFirstChild("Screen") and w.Display.Screen:FindFirstChild("CashierGUI")
            done = done and done:FindFirstChild("Frame") and done.Frame:FindFirstChild("Done")
            local ok, conns = pcall(getconnections, done and done.Activated)
            local fn = ok and conns and conns[1] and conns[1].Function
            if not fn then
                task.wait(0.3)
                return
            end
            pause(0.4, 0.7)
            setStatus("Pressing Done")
            if not cleanSafe(fn) then
                use(fn) -- (stops Auto Farm with the unsafe status)
                return
            end
            task.spawn(function()
                pcall(fn)
            end)
            waitUntil(function()
                return w.Occupied.Value ~= npc or st.Value == "true" or st.Value == "false"
            end, 4)
            if st.Value == "false" then
                warn("[Legit Farm Job] supermarket: the order was not accepted")
                setStatus("Order not accepted, next customer")
            else
                setStatus("Order done")
            end
            waitUntil(function()
                return w.Occupied.Value ~= npc
            end, 6)
            return
        end
        setStatus("Waiting for the customer to put everything down")
        task.wait(0.2)
    end

    function K.stop()
        station = nil
    end

    return K
end)()

-- Hairdresser - Stylez Hair Studio (job id StylezHairdresser). Found live in the game's own JobHandler.StylezHairdresser:
-- stations Environment.Locations.City.StylezHairStudio.Interior.HairdresserWorkstations ("Workstation" x4: Stool, Mirror,
-- Occupied, InUse); the shift starts by itself when the character walks from the waiting area to a station. Each Mirror has
-- the HairdresserGUI.Frame with Style.Next / Style.Back, Color.Next / Color.Back and Done (their Activated = the game's
-- doAction). doAction's own upvalues hold the current customer, the sorted style list (StylezHairAssets.Styles, 10), the
-- sorted color list (StylezHairAssets.Colors, 8) and the current pick {style, color}. The request is the customer's speech
-- bubble: ChatBubble.Body.IconFrame[" "] has a style Icon (an image) and a color Icon (image 2132263837, tinted with the
-- color). The colour is matched by its tint; the style icons are not linked to the styles anywhere on the client, so they
-- were matched by sight (3 seen) and the rest is learned from the game's own answer (Order "true" / "false"), kept in
-- getgenv and in the file LFJ_HairIcons.json.
NC.hair = (function()
    local H = {}
    local JOB = "StylezHairdresser"
    local COLOR_ICON = "2132263837"
    local station
    -- set once the character stands at its station with the shift running: from then on it stays there (a customer at
    -- another station, e.g. one sent there by another player starting a shift, no longer moves it)
    local locked = false
    local outerSetStatus = setStatus
    local function setStatus(text)
        if farming then
            outerSetStatus(text)
        end
    end

    local function alive()
        return running and farming
    end

    local function pause(a, b)
        local t = a + math.random() * (b - a)
        local t0 = os.clock()
        while alive() and os.clock() - t0 < t do
            task.wait(0.03)
        end
    end

    local function waitUntil(cond, timeout)
        local t0 = os.clock()
        while alive() and os.clock() - t0 < timeout do
            if cond() then
                return true
            end
            task.wait(0.05)
        end
        return cond()
    end

    -- style icon -> style name (seen and matched live), plus whatever was learned from the game's answers
    local HttpService = game:GetService("HttpService")
    local FILE = "LFJ_HairIcons.json"
    local known = getgenv().LFJ_HairIcons
    if type(known) ~= "table" then
        known = { map = {}, wrong = {} }
        pcall(function()
            if isfile and isfile(FILE) then
                local t = HttpService:JSONDecode(readfile(FILE))
                if type(t) == "table" and type(t.map) == "table" then
                    known = { map = t.map, wrong = type(t.wrong) == "table" and t.wrong or {} }
                end
            end
        end)
        getgenv().LFJ_HairIcons = known
    end
    -- all 10 (3 matched by sight, 7 learned live from the game's answers; every one confirmed by an accepted haircut)
    for id, name in pairs({
        ["2134784092"] = "Afro", ["2134784330"] = "Bun", ["2134784513"] = "Charming", ["2134922767"] = "Combed",
        ["2134784698"] = "Curly", ["2134784889"] = "Headband", ["2134785130"] = "Long", ["2134785777"] = "Messy",
        ["2134785997"] = "Pigtails", ["2134786236"] = "Sideswept",
    }) do
        known.map[id] = known.map[id] or name
    end

    local function saveKnown()
        pcall(function()
            if writefile then
                writefile(FILE, HttpService:JSONEncode(known))
            end
        end)
    end

    local function studio()
        local n = workspace:FindFirstChild("Environment")
        for _, name in ipairs({ "Locations", "City", "StylezHairStudio" }) do
            n = n and n:FindFirstChild(name)
        end
        return n
    end

    local function frameOf(w)
        local gui = w:FindFirstChild("Mirror") and w.Mirror:FindFirstChild("HairdresserGUI")
        return gui and gui:FindFirstChild("Frame")
    end

    -- the game's handler of a button (its Activated connection), only the game's own closure
    local function buttonFn(btn)
        local ok, conns = pcall(getconnections, btn and btn.Activated)
        local c = ok and conns and conns[1]
        return c and c.Function
    end

    -- mobile (the game's InputManager:GetInputType() is not "Default", seen live on Delta: "Touch"): the mirror's buttons
    -- get no handlers; the game registers a job interaction on the Workstation model instead, "T_ChangeHair" (Style_Next),
    -- "T_ChangeHairColor" (Color_Next), "B_Done" (Done), each callback calling the same doAction. Only used when the
    -- mirror's Done button has no handler, so PC is unchanged.
    local function mobileCb(w, key)
        local reg = getInteractRegistry()
        local entry = reg and reg[w]
        for _, gen in ipairs(type(entry) == "table" and type(entry[1]) == "table" and entry[1] or {}) do
            if type(gen) == "function" then
                local ok, text, _, cb = pcall(gen)
                if ok and text == key and type(cb) == "function" then
                    return cb
                end
            end
        end
    end

    -- the game's doAction state: current customer, style list, color list, current pick
    local function stateOf(w)
        local f = frameOf(w)
        local fn = buttonFn(f and f:FindFirstChild("Done")) or mobileCb(w, "B_Done")
        if not fn then
            return nil
        end
        local okU, ups = pcall(debug.getupvalues, fn)
        local doAction
        for _, v in pairs(okU and ups or {}) do
            if type(v) == "function" then
                doAction = v
            end
        end
        if not doAction then
            return nil
        end
        local st = {}
        for _, v in pairs(debug.getupvalues(doAction)) do
            if type(v) == "table" then
                if #v == 2 and type(v[1]) == "number" and type(v[2]) == "number" then
                    st.pick = v
                elseif typeof(v[1]) == "Instance" and v[1].Parent then
                    if v[1].Parent.Name == "Styles" then
                        st.styles = v
                    elseif v[1].Parent.Name == "Colors" then
                        st.colors = v
                    end
                end
            elseif typeof(v) == "Instance" and v.Name:find("Customer") then
                st.customer = v
            end
        end
        if st.pick and st.styles and st.colors then
            return st
        end
    end

    local function floorAt(x, z, y)
        local params = RaycastParams.new()
        params.FilterType = Enum.RaycastFilterType.Exclude
        local ignore = {}
        for _, plr in ipairs(Players:GetPlayers()) do
            if plr.Character then
                table.insert(ignore, plr.Character)
            end
        end
        params.FilterDescendantsInstances = ignore
        local h = workspace:Raycast(Vector3.new(x, y + 6, z), Vector3.new(0, -14, 0), params)
        return h and h.Position
    end

    -- the hairdresser's spot: 3.5 studs behind the customer's stool (away from the mirror the customer faces)
    local function standOf(w)
        local stool, mirror = w:FindFirstChild("Stool"), w:FindFirstChild("Mirror")
        if not (stool and mirror) then
            return nil
        end
        local s = stool:GetPivot().Position
        local d = Vector3.new(s.X - mirror.Position.X, 0, s.Z - mirror.Position.Z)
        d = d.Magnitude > 0.1 and d.Unit or Vector3.new(0, 0, -1)
        local p = s + d * 3.5
        return floorAt(p.X, p.Z, s.Y) or Vector3.new(p.X, s.Y - 2, p.Z)
    end

    local function flatDist(a, b)
        return (Vector3.new(a.X, 0, a.Z) - Vector3.new(b.X, 0, b.Z)).Magnitude
    end

    local function takenByOther(w)
        local u = w:FindFirstChild("InUse") and w.InUse.Value
        if typeof(u) == "Instance" and u ~= LocalPlayer and u.Parent == Players then
            return true
        end
        local sp = standOf(w)
        for _, plr in ipairs(Players:GetPlayers()) do
            local r = plr ~= LocalPlayer and plr.Character and plr.Character:FindFirstChild("HumanoidRootPart")
            if r and sp and flatDist(r.Position, sp) < 4 then
                return true
            end
        end
        return false
    end

    local function pickStation()
        local s = studio()
        local ws = s and s:FindFirstChild("Interior") and s.Interior:FindFirstChild("HairdresserWorkstations")
        local free = {}
        for _, w in ipairs(ws and ws:GetChildren() or {}) do
            -- (the mirror's HairdresserGUI only exists once the shift has started, so it is not required here)
            if w:FindFirstChild("Mirror") and w:FindFirstChild("Stool") and w:FindFirstChild("Occupied") and not takenByOther(w) then
                table.insert(free, w)
            end
        end
        -- a customer already sitting and waiting (e.g. after Auto Farm was off and the job left): that station first
        for _, w in ipairs(free) do
            local npc = w.Occupied.Value
            local o = npc and npc:FindFirstChild("Order")
            if o and o.Value == "" then
                return w
            end
        end
        return #free > 0 and free[math.random(#free)] or nil
    end

    -- one continuous walk through all the given points (bottom opening, middle, station spot): every leg is planned
    -- first (PathfindingService), the waypoints are joined into one line, and the character follows it with
    -- Humanoid:MoveTo toward a point a little ahead on that line, so it never stops at a leg's end or a waypoint.
    -- Only when it makes no headway (stuck) is the rest planned again from where it is.
    local HAIR_AGENTS = {
        { AgentRadius = 1.5, AgentHeight = 5, AgentCanJump = false },
        { AgentRadius = 1, AgentHeight = 5, AgentCanJump = false },
    }
    local function walkVia(points, retarget)
        for _ = 1, 3 do
            if not alive() then
                return false
            end
            local _, hum, root = getChar()
            if not (hum and root) then
                return false
            end
            local goal = points[#points]
            if flatDist(root.Position, goal) < 1.5 then
                return true
            end
            -- plan every remaining leg
            local line, from = { root.Position }, root.Position
            local legEnd = {}
            for li, g in ipairs(points) do
                legEnd[li] = #line
                if flatDist(from, g) > 1 then
                    local path
                    for _, cfg in ipairs(HAIR_AGENTS) do
                        local p = PathfindingService:CreatePath(cfg)
                        local ok = pcall(function()
                            p:ComputeAsync(from, g)
                        end)
                        if ok and p.Status == Enum.PathStatus.Success then
                            path = p
                            break
                        end
                    end
                    if not path then
                        return false
                    end
                    for i, wp in ipairs(path:GetWaypoints()) do
                        if i > 1 then
                            line[#line + 1] = wp.Position
                        end
                    end
                    from = g
                end
                legEnd[li] = #line
            end
            -- follow the line: aim 3 studs ahead of the character's place on it
            local seg, stuck = 1, false
            local ref, refT = root.Position, os.clock()
            local lastAim, lastMoveT, lastCheck = nil, 0, os.clock()
            while alive() do
                local p = root.Position
                if flatDist(p, goal) <= 1.2 then
                    break
                end
                -- the customer sat at another station while walking: that walk starts at once, still moving (no stop)
                if retarget and os.clock() - lastCheck > 0.25 then
                    lastCheck = os.clock()
                    if retarget() then
                        return "retarget"
                    end
                end
                while seg < #line - 1 do
                    local a, b = line[seg], line[seg + 1]
                    local ab = Vector3.new(b.X - a.X, 0, b.Z - a.Z)
                    local l2 = ab:Dot(ab)
                    local t = l2 > 1e-6 and Vector3.new(p.X - a.X, 0, p.Z - a.Z):Dot(ab) / l2 or 1
                    if t >= 1 or flatDist(p, b) <= 1.5 then
                        seg += 1
                    else
                        break
                    end
                end
                local a, b = line[seg], line[seg + 1] or line[seg]
                local ab = Vector3.new(b.X - a.X, 0, b.Z - a.Z)
                local l2 = ab:Dot(ab)
                local t = l2 > 1e-6 and math.clamp(Vector3.new(p.X - a.X, 0, p.Z - a.Z):Dot(ab) / l2, 0, 1) or 1
                local cur, left, aim = a:Lerp(b, t), 3, line[#line]
                local k = seg
                while k < #line do
                    local nxt = line[k + 1]
                    local d = flatDist(cur, nxt)
                    if d >= left then
                        aim = cur:Lerp(nxt, d > 1e-6 and left / d or 1)
                        break
                    end
                    left -= d
                    cur = nxt
                    k += 1
                end
                if not lastAim or flatDist(aim, lastAim) > 0.3 or os.clock() - lastMoveT > 0.5 then
                    hum:MoveTo(aim)
                    lastAim, lastMoveT = aim, os.clock()
                end
                if os.clock() - refT > 0.9 then
                    if flatDist(p, ref) < 0.5 then
                        stuck = true
                        break
                    end
                    ref, refT = p, os.clock()
                end
                RunService.Heartbeat:Wait()
            end
            if not alive() then
                return false
            end
            if not stuck then
                -- the last 1.2 studs onto the spot itself
                hum:MoveTo(goal)
                local t0 = os.clock()
                while alive() and os.clock() - t0 < 1.5 and flatDist(root.Position, goal) > 0.8 do
                    RunService.Heartbeat:Wait()
                end
                return true
            end
            -- stuck: the legs not yet finished are planned again from here
            local rest = {}
            for li, g in ipairs(points) do
                if legEnd[li] > seg then
                    rest[#rest + 1] = g
                end
            end
            points = #rest > 0 and rest or { goal }
        end
        local _, _, root = getChar()
        return root ~= nil and flatDist(root.Position, points[#points]) < 3
    end

    -- the request in the customer's bubble: style icon id, color tint
    local function readRequest(npc)
        local head = npc and npc:FindFirstChild("Head")
        -- every bubble on the head (seen live after leaving and coming back: a leftover bubble without the icons next
        -- to the game's new one), else the customer's own icon frame
        local f
        for _, b in ipairs(head and head:GetChildren() or {}) do
            if b.Name == "ChatBubble" then
                f = b:FindFirstChild(" ", true)
                if f then
                    break
                end
            end
        end
        f = f or (npc and npc:FindFirstChild(" "))
        if not f then
            return nil
        end
        local styleId, tint
        for _, ic in ipairs(f:GetChildren()) do
            if ic:IsA("ImageLabel") and ic.Visible then
                local id = tostring(ic.Image):match("%d+")
                if id == COLOR_ICON then
                    tint = ic.ImageColor3
                elseif id then
                    styleId = id
                end
            end
        end
        if styleId and tint then
            return styleId, tint
        end
    end

    local function colorIndex(colors, tint)
        local best, bd
        for i, c in ipairs(colors) do
            local v = c.Value.Color
            local d = math.abs(v.R - tint.R) + math.abs(v.G - tint.G) + math.abs(v.B - tint.B)
            if not bd or d < bd then
                best, bd = i, d
            end
        end
        return best
    end

    -- the style for an icon: known, or the first style not yet tied to another icon and not already wrong for it
    local function styleIndex(styles, iconId)
        local name = known.map[iconId]
        if not name then
            local used = {}
            for _, n in pairs(known.map) do
                used[n] = true
            end
            local wrong = known.wrong[iconId] or {}
            for _, s in ipairs(styles) do
                if not used[s.Name] and not wrong[s.Name] then
                    name = s.Name
                    break
                end
            end
            if not name then
                for _, s in ipairs(styles) do
                    if not wrong[s.Name] then
                        name = s.Name
                        break
                    end
                end
            end
        end
        for i, s in ipairs(styles) do
            if s.Name == name then
                return i, known.map[iconId] ~= nil
            end
        end
        return 1, false
    end

    local function press(btn, mobileFn)
        local fn = buttonFn(btn) or mobileFn
        if not fn then
            return false
        end
        if not cleanSafe(fn) then
            farming = false
            if FarmToggle then
                withUiIdentity(function()
                    FarmToggle:Set(false)
                end)
            end
            outerSetStatus("Stopped: unsafe hairdresser state")
            return false
        end
        task.spawn(function()
            pcall(fn)
        end)
        return true
    end

    -- arrows to the wanted index (the shorter way round), at a person's pace
    local function cycle(w, group, which, want)
        local f = frameOf(w)
        local g = f and f:FindFirstChild(group)
        for _ = 1, 15 do
            if not alive() then
                return false
            end
            local st = stateOf(w)
            if not st then
                return false
            end
            local cur, n = st.pick[which], which == 1 and #st.styles or #st.colors
            if cur == want then
                return true
            end
            local fwd = (want - cur) % n
            local btn = g and g:FindFirstChild(fwd <= n - fwd and "Next" or "Back")
            -- mobile: no button handlers, only the game's "Next" interaction (forward only)
            local mob = not buttonFn(btn) and mobileCb(w, group == "Style" and "T_ChangeHair" or "T_ChangeHairColor") or nil
            if not press(btn, mob) then
                return false
            end
            waitUntil(function()
                local s2 = stateOf(w)
                return s2 and s2.pick[which] ~= cur
            end, 1)
            pause(0.3, 0.5)
        end
        local st = stateOf(w)
        return st ~= nil and st.pick[which] == want
    end

    function H.step()
        if not farming then
            task.wait(0.3)
            return
        end
        local _, hum, root = getChar()
        if not hum then
            setStatus("Waiting for character")
            task.wait(1)
            return
        end
        if not (station and station.Parent) then
            locked = false
            station = pickStation()
            if not station then
                setStatus("No free station, waiting")
                task.wait(1.5)
                return
            end
        end
        -- the customer sits where the game sends it, not always at the station picked (seen: walking through the middle
        -- sent one to station 2 while station 4 was picked): with nobody at this station, a customer waiting at another
        -- station no other player works is served there instead - only on the way in, before the character has settled
        -- at its station
        local function switchToCustomer()
            if locked or station.Occupied.Value then
                return false
            end
            local ws = station.Parent
            for i, other in ipairs(ws and ws:GetChildren() or {}) do
                local npc2 = other ~= station and other:FindFirstChild("Occupied") and other.Occupied.Value
                local o2 = npc2 and npc2:FindFirstChild("Order")
                if o2 and o2.Value == "" and other:FindFirstChild("Mirror") and other:FindFirstChild("Stool") and not takenByOther(other) then
                    station = other
                    setStatus("Customer at station " .. i .. ", going there")
                    return true
                end
            end
            return false
        end
        switchToCustomer()
        local w = station
        local stand = standOf(w)
        if not stand then
            setStatus("Station not found, waiting")
            task.wait(1)
            return
        end
        if flatDist(root.Position, stand) > 2.5 then
            setStatus("Walking to the station")
            -- seen live: the waiting area is behind a partition (x ~ -60, z -324..-340) with an opening at each end; the
            -- path finder takes the top one, which runs past station 4's drawer, and the character got stuck there
            -- (-64,-319.5) every time. So from the waiting side it walks through the bottom opening (-61,-343) and the
            -- open middle of the studio (Interior.Floor's centre); every station's spot faces the middle
            local s = studio()
            local fl = s and s:FindFirstChild("Interior") and s.Interior:FindFirstChild("Floor")
            local mid = fl and floorAt(fl.Position.X, fl.Position.Z, stand.Y + 1)
            local via = {}
            if root.Position.X > -60 then
                local gate = floorAt(-61, -343, stand.Y + 1)
                if gate then
                    via[#via + 1] = gate
                end
            end
            if mid and flatDist(root.Position, mid) > 3 then
                via[#via + 1] = mid
            end
            via[#via + 1] = stand
            -- (one continuous walk, no stop at the opening or the middle)
            if not walkVia(via, switchToCustomer) then
                setStatus("Can't reach the station, retrying")
                task.wait(1)
            end
            return
        end
        if not isWorkingJob(JOB) then
            setStatus("Starting the shift at the station")
            waitUntil(function()
                return isWorkingJob(JOB)
            end, 3)
            return
        end
        locked = true
        local npc = w.Occupied.Value
        local order = npc and npc:FindFirstChild("Order")
        if not (npc and order and order.Value == "") then
            setStatus("Waiting for customer")
            task.wait(0.3)
            return
        end
        local st = stateOf(w)
        local styleId, tint = readRequest(npc)
        if not (st and st.customer == npc and styleId and tint) then
            setStatus("Reading the request")
            task.wait(0.2)
            return
        end
        local ci = colorIndex(st.colors, tint)
        local si, sure = styleIndex(st.styles, styleId)
        local styleName, colorName = st.styles[si].Name, st.colors[ci].Name
        setStatus("Request: " .. styleName .. (sure and "" or " (trying)") .. ", " .. colorName)
        pause(0.4, 0.7)
        if not cycle(w, "Style", 1, si) then
            task.wait(0.5)
            return
        end
        pause(0.2, 0.4)
        if not cycle(w, "Color", 2, ci) then
            task.wait(0.5)
            return
        end
        pause(0.4, 0.7)
        if not (npc.Parent and order.Value == "" and w.Occupied.Value == npc) then
            return
        end
        setStatus("Pressing Done")
        local f = frameOf(w)
        if not press(f and f:FindFirstChild("Done"), mobileCb(w, "B_Done")) then
            return
        end
        waitUntil(function()
            return order.Value ~= "" or w.Occupied.Value ~= npc
        end, 5)
        if order.Value == "true" then
            if not known.map[styleId] then
                known.map[styleId] = styleName
                saveKnown()
            end
            setStatus("Haircut done")
        elseif order.Value == "false" then
            if not known.map[styleId] then
                known.wrong[styleId] = known.wrong[styleId] or {}
                known.wrong[styleId][styleName] = true
                saveKnown()
            elseif known.map[styleId] == styleName then
                warn("[Legit Farm Job] hairdresser: " .. styleName .. " / " .. colorName .. " was not accepted")
            end
            setStatus("Haircut not accepted, next customer")
        end
        waitUntil(function()
            return w.Occupied.Value ~= npc
        end, 6)
    end

    function H.stop()
        station = nil
        locked = false
    end

    return H
end)()

-- Fisherman - Fishing Hut (job id HutFisherman). Found live: the hut is Environment.Locations.Beach.FishingHut (the shift
-- starts inside it, its doorway is on the south side, no door part); the sea is west of it (sand from x -280 down to the
-- water at x -348, the way down is the dock's small stair platform). Cast / Pull is the equipped Fishing Rod's own hotbar
-- function (HotbarUI.EquipData, Title "I_Cast" / "I_Pull", module HotbarUI.EquippedModules.FishingRod): Cast only works
-- when a ray 12 studs in front of the character, 20 studs down, hits Terrain water. The bobber is the rod's Vector3Value
-- "Pos" (the server's bobber spot): a bite is Pos.Y dropping 1 stud under the water surface for ~1.1-1.8 s; a Pull then
-- catches the fish (JobHandler.HutFisherman.TasksPerformed +1, "GotFish"). Unequipping the rod ends the shift.
NC.fish = (function()
    local F = {}
    local JOB = "HutFisherman"
    local WATER_DIR = Vector3.new(-1, 0, 0)
    local AGENTS = {
        { AgentRadius = 1.5, AgentHeight = 5, AgentCanJump = false },
        { AgentRadius = 1, AgentHeight = 5, AgentCanJump = false },
    }
    local spot, watchRod, watchConn, baseY, pulled, castAt
    local outerSetStatus = setStatus
    local function setStatus(text)
        if farming then
            outerSetStatus(text)
        end
    end

    local function alive()
        return running and farming and isWorkingJob(JOB)
    end

    local function flatDist(a, b)
        return (Vector3.new(a.X, 0, a.Z) - Vector3.new(b.X, 0, b.Z)).Magnitude
    end

    local function rodData()
        local ed = HotbarUI.EquipData
        if type(ed) == "table" and ed.Name == "Fishing Rod" and type(ed.Function) == "function" then
            return ed
        end
    end

    local function caught()
        local ok, n = pcall(function()
            return JobHandler:GetCurJobModule().TasksPerformed
        end)
        return ok and tonumber(n) or 0
    end

    -- the rod's own Cast / Pull (only the game's closure)
    local function use(ed)
        if not cleanSafe(ed.Function) then
            farming = false
            if FarmToggle then
                withUiIdentity(function()
                    FarmToggle:Set(false)
                end)
            end
            outerSetStatus("Stopped: unsafe fishing state")
            return false
        end
        task.spawn(function()
            pcall(ed.Function)
        end)
        return true
    end

    -- the bobber going under: pulled the moment the rod's Pos drops under the water surface it landed on
    local function watch()
        local char = LocalPlayer.Character
        local rod = char and char:FindFirstChild("Fishing Rod")
        if rod == watchRod and watchConn then
            return
        end
        if watchConn then
            watchConn:Disconnect()
            watchConn = nil
        end
        watchRod = rod
        local pos = rod and rod:FindFirstChild("Pos")
        if not pos then
            return
        end
        watchConn = pos.Changed:Connect(function(v)
            if not (running and farming) then
                return
            end
            if v.X == 0 and v.Y == 0 and v.Z == 0 then
                baseY = nil -- line pulled in
                return
            end
            if not baseY then
                baseY = v.Y -- where the bobber landed (the water surface)
                return
            end
            if v.Y < baseY - 0.5 and not pulled then
                local ed = rodData()
                if ed and ed.Title == "I_Pull" then
                    pulled = true
                    use(ed)
                end
            end
        end)
    end

    -- the shore spot: going from the hut toward the water, the first sand spot the game's cast ray reaches water from,
    -- 2 studs further (live: x -340, the water starts at -348)
    local function findSpot()
        local n = workspace:FindFirstChild("Environment")
        for _, name in ipairs({ "Locations", "Beach", "FishingHut", "Origin" }) do
            n = n and n:FindFirstChild(name)
        end
        if not n then
            return nil
        end
        local params = RaycastParams.new()
        params.FilterType = Enum.RaycastFilterType.Exclude
        params.IgnoreWater = false
        local ignore = {}
        for _, plr in ipairs(Players:GetPlayers()) do
            if plr.Character then
                table.insert(ignore, plr.Character)
            end
        end
        params.FilterDescendantsInstances = ignore
        local base = n.Position - Vector3.new(0, 0, 3)
        for k = 20, 140 do
            local p = base + WATER_DIR * k
            local g = workspace:Raycast(Vector3.new(p.X, 60, p.Z), Vector3.new(0, -120, 0), params)
            if g and g.Instance == workspace.Terrain then
                if g.Material == Enum.Material.Water then
                    return nil
                end
                local a = Vector3.new(p.X, g.Position.Y + 3, p.Z) + WATER_DIR * 12
                local w = workspace:Raycast(a, Vector3.new(0, -20, 0), params)
                if w and w.Instance == workspace.Terrain and w.Material == Enum.Material.Water then
                    -- on toward the water to the last sand before it (live: sand -347, water from -348), half a stud
                    -- back from it: right where the sand meets the water, so the cast lands well out in the water
                    local last = g.Position
                    for s = 0.5, 30, 0.5 do
                        local q = p + WATER_DIR * s
                        local g2 = workspace:Raycast(Vector3.new(q.X, 60, q.Z), Vector3.new(0, -120, 0), params)
                        if not g2 or g2.Material == Enum.Material.Water then
                            break
                        end
                        last = g2.Position
                    end
                    return last - WATER_DIR * 0.5
                end
            end
        end
    end

    -- walking: Humanoid:MoveTo toward a point 2 studs ahead on the pathfinding line (out of the hut door, along the dock,
    -- down the stair platform, over the sand), so it never stops at a waypoint; no headway for 0.9 s -> planned again
    local function planPath(from, goal)
        for _, cfg in ipairs(AGENTS) do
            local p = PathfindingService:CreatePath(cfg)
            local ok = pcall(function()
                p:ComputeAsync(from, goal)
            end)
            if ok and p.Status == Enum.PathStatus.Success then
                local wps = p:GetWaypoints()
                local jump = false
                for _, w in ipairs(wps) do
                    if w.Action == Enum.PathWaypointAction.Jump then
                        jump = true
                    end
                end
                if not jump and #wps > 0 and flatDist(wps[#wps].Position, goal) < 3 then
                    return wps
                end
            end
        end
    end

    local function walk(goal)
        for _ = 1, 4 do
            if not alive() then
                return false
            end
            local _, hum, root = getChar()
            if not (hum and root) then
                return false
            end
            if flatDist(root.Position, goal) <= 1.2 then
                return true
            end
            local wps = planPath(root.Position, goal)
            if not wps then
                return false
            end
            local line = { root.Position }
            for i = 2, #wps do
                line[#line + 1] = wps[i].Position
            end
            local seg, stuck = 1, false
            local ref, refT = root.Position, os.clock()
            local lastAim, lastMoveT = nil, 0
            while alive() do
                local p = root.Position
                if flatDist(p, goal) <= 1.2 then
                    break
                end
                while seg < #line - 1 do
                    local a, b = line[seg], line[seg + 1]
                    local ab = Vector3.new(b.X - a.X, 0, b.Z - a.Z)
                    local l2 = ab:Dot(ab)
                    local t = l2 > 1e-6 and Vector3.new(p.X - a.X, 0, p.Z - a.Z):Dot(ab) / l2 or 1
                    if t >= 1 or flatDist(p, b) <= 1.2 then
                        seg += 1
                    else
                        break
                    end
                end
                local a, b = line[seg], line[seg + 1] or line[seg]
                local ab = Vector3.new(b.X - a.X, 0, b.Z - a.Z)
                local l2 = ab:Dot(ab)
                local t = l2 > 1e-6 and math.clamp(Vector3.new(p.X - a.X, 0, p.Z - a.Z):Dot(ab) / l2, 0, 1) or 1
                local cur, left, aim = a:Lerp(b, t), 2, line[#line]
                local k = seg
                while k < #line do
                    local nxt = line[k + 1]
                    local d = flatDist(cur, nxt)
                    if d >= left then
                        aim = cur:Lerp(nxt, d > 1e-6 and left / d or 1)
                        break
                    end
                    left -= d
                    cur = nxt
                    k += 1
                end
                if not lastAim or flatDist(aim, lastAim) > 0.3 or os.clock() - lastMoveT > 0.5 then
                    hum:MoveTo(aim)
                    lastAim, lastMoveT = aim, os.clock()
                end
                if os.clock() - refT > 0.9 then
                    if flatDist(p, ref) < 0.5 then
                        stuck = true
                        break
                    end
                    ref, refT = p, os.clock()
                end
                RunService.Heartbeat:Wait()
            end
            if not stuck then
                return alive() and flatDist(root.Position, goal) <= 1.5
            end
        end
        return false
    end

    -- turned toward the water by a short step that way (the cast goes where the character faces)
    local function face()
        local _, hum, root = getChar()
        if not (hum and root) or root.CFrame.LookVector:Dot(WATER_DIR) > 0.95 then
            return
        end
        hum:MoveTo(root.Position + WATER_DIR * 1.5)
        local t0 = os.clock()
        while alive() and os.clock() - t0 < 1 and root.CFrame.LookVector:Dot(WATER_DIR) < 0.95 do
            RunService.Heartbeat:Wait()
        end
        hum:MoveTo(root.Position)
    end

    function F.step()
        if not farming then
            task.wait(0.3)
            return
        end
        if not isWorkingJob(JOB) then
            setStatus("Start the Fisherman job first")
            task.wait(1)
            return
        end
        local _, hum, root = getChar()
        if not hum then
            setStatus("Waiting for character")
            task.wait(1)
            return
        end
        local ed = rodData()
        if not ed then
            setStatus("Waiting for the Fishing Rod")
            task.wait(0.3)
            return
        end
        watch()
        spot = spot or findSpot()
        if not spot then
            setStatus("No fishing spot found, waiting")
            task.wait(2)
            return
        end
        if flatDist(root.Position, spot) > 2.5 then
            if ed.Title == "I_Pull" then
                pulled = true
                use(ed) -- the line comes in before walking
                task.wait(1.5)
                return
            end
            setStatus("Walking to the water")
            if walk(spot) then
                face()
            elseif farming then
                setStatus("Can't reach the water, retrying")
                spot = nil
                task.wait(1)
            end
            return
        end
        if ed.Title == "I_Cast" then
            face()
            setStatus("Casting")
            baseY, pulled = nil, false
            if not use(ed) then
                return
            end
            local t0 = os.clock()
            while alive() and os.clock() - t0 < 2.5 and ed.Title == "I_Cast" and HotbarUI.EquipData == ed do
                task.wait()
            end
            if ed.Title == "I_Cast" and HotbarUI.EquipData == ed then
                -- the cast did not reach water from here: 1.5 studs closer to it (never into it)
                spot = spot + WATER_DIR * 1.5
                hum:MoveTo(spot)
                local t1 = os.clock()
                while alive() and os.clock() - t1 < 1.5 and flatDist(root.Position, spot) > 0.8 do
                    RunService.Heartbeat:Wait()
                end
            end
            castAt = os.clock()
            return
        end
        if ed.Title == "I_Pull" then
            setStatus(string.format("Waiting for a bite (%d caught)", caught()))
            if not pulled and castAt and os.clock() - castAt > 60 then
                pulled = true
                use(ed) -- no bite for a minute: in and cast again
            end
            task.wait()
            return
        end
        task.wait() -- the cast / pull animation is playing
    end

    function F.stop()
        if watchConn then
            watchConn:Disconnect()
            watchConn = nil
        end
        watchRod, spot, baseY, pulled, castAt = nil, nil, nil, nil, nil
    end

    return F
end)()

-- Mechanic - Mike's Motors (job id MikesMechanic). Found live in the game's own JobHandler.MikesMechanic: the garage is
-- Environment.Locations.City.MikesMotors.Interior. MechanicWorkstations ("Workstation" x4: Lift, Display, DrawerSmall,
-- CustomerTarget = PrimaryPart, Occupied = the customer, InUse); TireRacks (Classic / Moped / Bloxster, "I_Take" = TakeWheel,
-- the wheel in hand has the attribute _wheelType); PaintingEquipment (Green / Purple / Black / Red, "I_Take" = TakePainter,
-- the colour is the item's Can.BrickColor); OilCans ("I_Take" = TakeOil). The customer's Vehicle offers, for what is held,
-- "I_ChangeFrontWheel" / "I_Paint" / "I_FillOil" and "I_ChangeBackWheel". Done is the Display's MechanicGUI.Frame.Done (its
-- Activated = the game's done() -> JobCompleted; mobile: the Screen's "B_Done" interaction). The request is the customer's
-- speech bubble (IconFrame[" "]): icon 2132263837 tinted with the paint colour, one icon per wheel (front, then back; the
-- wheel icons were matched live: a Moped order was accepted, Classic and Bloxster follow from the refused tries), and
-- anything else there is the oil (the vehicle offers nothing else). A customer is sent to a station once the character is
-- within ~9.3 studs (flat) of its CustomerTarget (measured live; the game's own "too far" check is 10), so walking keeps
-- KEEP studs from every other station (along the wall by the paint table / oil cans when the direct way comes too close).
NC.mech = (function()
    local M = {}
    local JOB = "MikesMechanic"
    local COLOR_ICON = "2132263837"
    local WHEEL_ICON = { ["12137510276"] = "Classic", ["12137513113"] = "Moped", ["12137509899"] = "Bloxster" }
    local KEEP = 10.5
    -- a wide agent first: the path keeps clear of the drawers, stools, racks and bikes (seen live: brushing past them made
    -- the character stop and start)
    -- (radius 1.5 first: the player's way between station 1's drawer and the Classic rack is 3.8 studs wide, a radius 2
    -- agent did not fit and was sent round the far side of the rack into it)
    local AGENTS = {
        { AgentRadius = 1.5, AgentHeight = 5, AgentCanJump = false },
        { AgentRadius = 2, AgentHeight = 5, AgentCanJump = false },
        { AgentRadius = 1, AgentHeight = 5, AgentCanJump = false },
    }
    local station
    local standCache, warmed = {}, {}
    local orders = setmetatable({}, { __mode = "k" }) -- customer -> its request, read once from the bubble
    local outerSetStatus = setStatus
    local function setStatus(text)
        if farming then
            outerSetStatus(text)
        end
    end

    local function alive()
        return running and farming and isWorkingJob(JOB)
    end

    local function pause(a, b)
        local t = a + math.random() * (b - a)
        local t0 = os.clock()
        while alive() and os.clock() - t0 < t do
            task.wait(0.03)
        end
    end

    local function waitUntil(cond, timeout)
        local t0 = os.clock()
        while alive() and os.clock() - t0 < timeout do
            if cond() then
                return true
            end
            task.wait(0.05)
        end
        return cond()
    end

    local function flatDist(a, b)
        return (Vector3.new(a.X, 0, a.Z) - Vector3.new(b.X, 0, b.Z)).Magnitude
    end

    local function interior()
        local n = workspace:FindFirstChild("Environment")
        for _, name in ipairs({ "Locations", "City", "MikesMotors", "Interior" }) do
            n = n and n:FindFirstChild(name)
        end
        return n
    end

    -- station 1 is the one next to the tire racks (largest X), then on along the row
    local function stations()
        local I = interior()
        local ws = I and I:FindFirstChild("MechanicWorkstations")
        local list = {}
        for _, w in ipairs(ws and ws:GetChildren() or {}) do
            if w:FindFirstChild("CustomerTarget") and w:FindFirstChild("Lift") and w:FindFirstChild("Occupied") then
                table.insert(list, w)
            end
        end
        table.sort(list, function(a, b)
            return a.CustomerTarget.Position.X > b.CustomerTarget.Position.X
        end)
        return list
    end

    -- the game's own interaction callback of an object (only the game's closures, checked like every other job)
    local function callback(obj, wanted)
        local reg = getInteractRegistry()
        local entry = reg and obj and reg[obj]
        local gens = entry and entry[1]
        for _, gen in ipairs(type(gens) == "table" and gens or {}) do
            if type(gen) == "function" then
                local ok, text, _, cb = pcall(gen)
                if ok and text == wanted and type(cb) == "function" then
                    return cb
                end
            end
        end
    end

    local function use(cb)
        if not cleanSafe(cb) then
            farming = false
            if FarmToggle then
                withUiIdentity(function()
                    FarmToggle:Set(false)
                end)
            end
            outerSetStatus("Stopped: unsafe mechanic state")
            return false
        end
        task.spawn(function()
            pcall(cb)
        end)
        return true
    end

    local function equipped()
        local ok, e = pcall(function()
            return JobHandler.Shared.EquipmentService:GetEquipped(LocalPlayer)
        end)
        return ok and e or nil
    end

    local function ignoreList()
        local ignore = {}
        for _, plr in ipairs(Players:GetPlayers()) do
            if plr.Character then
                table.insert(ignore, plr.Character)
            end
        end
        return ignore
    end

    -- a free floor spot (nothing solid where the character would stand)
    -- the garage floor's height (the tire racks stand on it: live 0.41, the floor 0.50)
    local floorRef
    local function freeFloor(p, room)
        if not floorRef then
            local I = interior()
            local r = I and I:FindFirstChild("TireRacks") and I.TireRacks:GetChildren()[1]
            floorRef = r and r:GetPivot().Position.Y
        end
        local params = RaycastParams.new()
        params.FilterType = Enum.RaycastFilterType.Exclude
        params.FilterDescendantsInstances = ignoreList()
        local h = workspace:Raycast(Vector3.new(p.X, p.Y + 6, p.Z), Vector3.new(0, -14, 0), params)
        -- only the floor itself: a hit on top of a rack / table / stool is no spot to walk to (seen live: a corridor point
        -- on top of the Classic rack, the walk aimed at it and stood still)
        if not h or (floorRef and h.Position.Y > floorRef + 1.2) then
            return nil
        end
        local op = OverlapParams.new()
        op.FilterType = Enum.RaycastFilterType.Exclude
        op.FilterDescendantsInstances = params.FilterDescendantsInstances
        op.RespectCanCollide = true
        -- (room: the free width around the spot; walk points get 3.6 so nothing stands right next to them)
        local wdt = room or 2.4
        if #workspace:GetPartBoundsInBox(CFrame.new(h.Position + Vector3.new(0, 2.6, 0)), Vector3.new(wdt, 4, wdt), op) > 0 then
            return nil
        end
        return h.Position
    end

    local function takenByOther(w)
        local u = w:FindFirstChild("InUse") and w.InUse.Value
        if typeof(u) == "Instance" and u ~= LocalPlayer and u.Parent == Players then
            return true
        end
        for _, plr in ipairs(Players:GetPlayers()) do
            local r = plr ~= LocalPlayer and plr.Character and plr.Character:FindFirstChild("HumanoidRootPart")
            if r and flatDist(r.Position, w.CustomerTarget.Position) < 10 then
                return true
            end
        end
        return false
    end

    -- closest flat distance of a point to the CustomerTarget of every station except `own`
    local function nearOther(p, own, list)
        local best = math.huge
        for _, w in ipairs(list) do
            if w ~= own then
                best = math.min(best, flatDist(p, w.CustomerTarget.Position))
            end
        end
        return best
    end

    -- the mechanic's spot: beside the lift on the customer's side of the bike, where the player stands working it by hand
    -- (watched live at station 1: 284.2,-305.3 = 3.7 studs beside the lift's middle, 1.1 toward the customer), within reach
    -- of the Done check (10 studs of the CustomerTarget); where that is too close to another station, the nearest spot that
    -- keeps clear of it
    local function standOf(w, list)
        if standCache[w] then
            return standCache[w]
        end
        local lc, ls = w.Lift:GetBoundingBox()
        local ct = w.CustomerTarget.Position
        local best, bestScore
        for _, side in ipairs({ 1, -1 }) do
            for _, dz in ipairs({ -1.1, 0, 1.5, 3 }) do
                local p = lc.Position + lc.RightVector * side * (ls.X / 2 + 2.45) + lc.LookVector * dz
                local f = freeFloor(Vector3.new(p.X, ct.Y, p.Z))
                if f and flatDist(f, ct) <= 8.5 then
                    local clear = nearOther(f, w, list)
                    local score = clear >= KEEP + 0.5 and 100 - math.abs(dz + 1.1) + math.min(clear, 30) * 0.01 or clear
                    if not bestScore or score > bestScore then
                        best, bestScore = f, score
                    end
                end
            end
        end
        standCache[w] = best
        return best
    end

    -- in front of a rack (racks face their LookVector), or on the room side of a table item (paint, oil)
    local function rackStand(rack)
        local cf, sz = rack:GetBoundingBox()
        local look = Vector3.new(cf.LookVector.X, 0, cf.LookVector.Z)
        look = look.Magnitude > 0.01 and look.Unit or Vector3.new(-1, 0, 0)
        for _, d in ipairs({ 2, 2.6, 3.2 }) do
            local f = freeFloor(cf.Position + look * (sz.Z / 2 + d))
            if f then
                return f
            end
        end
    end

    local function tableStand(item, list)
        local p = item:GetPivot().Position
        local c = Vector3.zero
        for _, w in ipairs(list) do
            c += w.CustomerTarget.Position
        end
        c /= math.max(#list, 1)
        local d = Vector3.new(c.X - p.X, 0, c.Z - p.Z)
        d = math.abs(d.X) > math.abs(d.Z) and Vector3.new(math.sign(d.X), 0, 0) or Vector3.new(0, 0, math.sign(d.Z))
        for _, k in ipairs({ 3.2, 3.8, 4.4 }) do
            local f = freeFloor(p + d * k)
            if f then
                return f, d
            end
        end
    end

    -- Walking: the path (PathfindingService) is only used when every point on it keeps KEEP studs from the other stations
    -- (a point already closer at the start may not get closer); otherwise it goes along the wall corridor
    -- and never over the lift pad of a station it does not work at (seen live: walking over station 1's pad with a wheel
    -- started station 1 and sent a customer there), whoever works it; a pad it already stands on may be walked off
    local pads = {} -- every station's lift footprint { w, cf, size }, set each step
    local function onPad(p, own, skip)
        for _, pd in ipairs(pads) do
            if pd.w ~= own and pd ~= skip then
                local rel = pd.cf:PointToObjectSpace(p)
                if math.abs(rel.X) < pd.size.X / 2 + 1.5 and math.abs(rel.Z) < pd.size.Z / 2 + 1.5 then
                    return pd
                end
            end
        end
    end

    local function pathOK(wps, own, list, from)
        local startPad = onPad(from, own)
        for i = 2, #wps do
            if wps[i].Action == Enum.PathWaypointAction.Jump then
                return false
            end
            local a, b = wps[i - 1].Position, wps[i].Position
            local n = math.max(1, math.ceil(flatDist(a, b)))
            for k = 0, n do
                local p = a:Lerp(b, k / n)
                if onPad(p, own, startPad) then
                    return false
                end
                for _, w in ipairs(list) do
                    if w ~= own then
                        local ct = w.CustomerTarget.Position
                        if flatDist(p, ct) < math.min(KEEP, flatDist(from, ct) - 0.05) then
                            return false
                        end
                    end
                end
            end
        end
        return true
    end

    -- straight when the way is clear (a character-sized box cast along it hits nothing solid): walked like a player walks.
    -- Seen live: between station 1's drawer and the Classic rack the floor is open (x 288-291), yet every path agent was
    -- routed round the far side of the rack and into it
    local function straight(from, to, own, list)
        local d = Vector3.new(to.X - from.X, 0, to.Z - from.Z)
        if d.Magnitude < 0.5 then
            return { from, to }
        end
        local params = RaycastParams.new()
        params.FilterType = Enum.RaycastFilterType.Exclude
        params.FilterDescendantsInstances = ignoreList()
        params.RespectCanCollide = true
        local y = (floorRef or math.min(from.Y, to.Y)) + 2.6
        local ok, hit = pcall(function()
            return workspace:Blockcast(CFrame.new(from.X, y, from.Z), Vector3.new(2.2, 3.6, 2.2), d, params)
        end)
        if not ok or hit then
            return nil
        end
        local wps = {
            { Position = Vector3.new(from.X, from.Y, from.Z), Action = Enum.PathWaypointAction.Walk },
            { Position = Vector3.new(to.X, to.Y, to.Z), Action = Enum.PathWaypointAction.Walk },
        }
        if not pathOK(wps, own, list, from) then
            return nil
        end
        return { from, to }
    end

    local function plan(from, to, own, list)
        local s = straight(from, to, own, list)
        if s then
            return s
        end
        for _, cfg in ipairs(AGENTS) do
            local p = PathfindingService:CreatePath(cfg)
            local ok = pcall(function()
                p:ComputeAsync(from, to)
            end)
            if ok and p.Status == Enum.PathStatus.Success then
                local wps = p:GetWaypoints()
                if #wps > 0 and flatDist(wps[#wps].Position, to) < 3 and pathOK(wps, own, list, from) then
                    local pts = {}
                    for _, wp in ipairs(wps) do
                        pts[#pts + 1] = wp.Position
                    end
                    return pts
                end
            end
        end
    end

    local corridorZ, wallSign = nil, 1
    -- the whole line from `from` to `to`: straight when it keeps away from the other stations, else via the corridor
    local function route(from, to, own, list)
        -- to / from the paint table and the oil cans (by the wall) it always goes round by the wall, never across the middle
        -- of the garage (the player's green path); the way back is the same way
        -- (a spot on the wall side of the corridor line is the paint table / oil cans)
        local wall = corridorZ ~= nil and ((to.Z - corridorZ) * wallSign > 2 or (from.Z - corridorZ) * wallSign > 2)
        if not wall then
            local direct = plan(from, to, own, list)
            if direct or not corridorZ then
                return direct
            end
        end
        local line = { from }
        -- a corridor point on free floor with room around it (seen live: a stool stands in the wall line at x 282-286 and
        -- the Classic rack from x 290; walking to a point next to the rack ran the character into it). The line moves
        -- toward the wall beside the drawers of stations 2 / 3, like the player's own (z -294 by the racks, -291.6 there)
        local function corridorAt(x, y)
            for _, dx in ipairs({ 0, -1.5, 1.5, -3, 3, -4.5, 4.5, -6, 6 }) do
                for _, dz in ipairs({ 0, 1, 2, -1 }) do
                    local f = freeFloor(Vector3.new(x + dx, y, corridorZ + dz), 3.6)
                    if f then
                        return f
                    end
                end
            end
            return Vector3.new(x, y, corridorZ)
        end
        -- into / out of a spot from its open side (seen live: station 1 reached between its lift and its drawer came 10.45
        -- studs from station 2; round the drawer's far side it is 13.6): the spot itself first, then spots 4.5 studs around
        -- it, the one furthest from the other stations first
        -- (only spots clear of the other stations, the one on the way to `toward` first, so it is no detour)
        local function sides(p, toward)
            local out = {}
            for k = 0, 7 do
                local a = k * math.pi / 4
                local f = freeFloor(p + Vector3.new(math.cos(a) * 4.5, 0, math.sin(a) * 4.5))
                if f and nearOther(f, own, list) >= KEEP then
                    table.insert(out, { p = f, s = flatDist(f, toward) })
                end
            end
            table.sort(out, function(x, y)
                return x.s < y.s
            end)
            table.insert(out, 1, { p = p })
            -- the station's own spot is left / reached on its open side, straight out from the lift (the player's green path
            -- at station 1: out past the drawer's far end, never between the lift and the drawer)
            local mine = own and standCache[own]
            if mine and flatDist(p, mine) < 2 then
                local lc = own.Lift:GetBoundingBox()
                local outward = Vector3.new(p.X - lc.Position.X, 0, p.Z - lc.Position.Z)
                if outward.Magnitude > 0.1 then
                    -- (out from the lift and toward the wall, like the player: station 1 284,-305 -> 288.9,-301.8; straight
                    -- out from the lift is where the customers queue and stand in the way)
                    local f = freeFloor(p + outward.Unit * 5 + Vector3.new(0, 0, wallSign * 3.5), 3.6)
                    if f and nearOther(f, own, list) >= KEEP and not onPad(f, own) then
                        table.insert(out, 1, { p = f })
                    end
                end
            end
            return out
        end
        local legs = {}
        local function legTo(a, b)
            if flatDist(a, b) <= 1 then
                return { a }
            end
            return plan(a, b, own, list)
        end
        local function add(leg)
            for k = 2, #leg do
                line[#line + 1] = leg[k]
            end
        end
        -- out: from -> (side) -> corridor
        local exitC
        for i, d in ipairs(sides(from, to)) do
            if i > 5 then
                break
            end
            local c = corridorAt(d.p.X, d.p.Y)
            local l1 = legTo(from, d.p)
            local l2 = l1 and legTo(d.p, c)
            if l1 and l2 then
                table.insert(legs, l1)
                table.insert(legs, l2)
                exitC = c
                break
            end
        end
        if not exitC then
            return nil
        end
        -- in: corridor -> (side) -> to
        for i, a in ipairs(sides(to, exitC)) do
            if i > 5 then
                break
            end
            local c = corridorAt(a.p.X, a.p.Y)
            local l3 = legTo(exitC, c)
            local l4 = l3 and legTo(c, a.p)
            local l5 = l4 and legTo(a.p, to)
            if l3 and l4 and l5 then
                for _, leg in ipairs(legs) do
                    add(leg)
                end
                add(l3)
                add(l4)
                add(l5)
                return line
            end
        end
        return nil
    end

    -- planned once per pair of spots (bike <-> rack / paint / oil) and kept: a trip never stops to plan its way
    local routeCache = {}
    local function preplan(from, to, own, list)
        local key = string.format("%d,%d>%d,%d", math.floor(from.X + 0.5), math.floor(from.Z + 0.5), math.floor(to.X + 0.5), math.floor(to.Z + 0.5))
        for _, s in ipairs(list) do
            key ..= "|" .. math.floor(s.CustomerTarget.Position.X) -- (planned again when the stations kept away from change)
        end
        local h = routeCache[key]
        if h and (not h.done or h.line) then
            return h
        end
        h = { done = false }
        routeCache[key] = h
        task.spawn(function()
            local ok, line = pcall(route, from, to, own, list)
            h.line = ok and line or nil
            h.done = true
        end)
        return h
    end

    -- follows the line with Humanoid:MoveTo toward a point 3 studs ahead on it, so it never stops at a waypoint; returns
    -- once within `within` of the goal (still moving: the next walk takes over at once). No headway for 0.9 s -> planned again
    -- arrive (optional): done as soon as it is true, still walking (an item is taken once it is within reach)
    local function walk(goal, within, own, list, pre, abort, arrive)
        for attempt = 1, 4 do
            if not alive() or (abort and abort()) then
                return false
            end
            local _, hum, root = getChar()
            if not (hum and root) then
                return false
            end
            if flatDist(root.Position, goal) <= within or (arrive and arrive(root.Position)) then
                return true
            end
            local line
            if pre and attempt == 1 then
                local t0 = os.clock()
                while not pre.done and os.clock() - t0 < 3 do
                    RunService.Heartbeat:Wait()
                end
                line = pre.line
                if line and flatDist(line[1], root.Position) > 6 then
                    line = nil
                end
            end
            line = line or route(root.Position, goal, own, list)
            if not line then
                -- no way that keeps clear of the other stations from right here: a step toward the corridor, then again
                if corridorZ then
                    hum:MoveTo(Vector3.new(root.Position.X, root.Position.Y, root.Position.Z + math.sign(corridorZ - root.Position.Z) * 2))
                    task.wait(0.4)
                end
                continue
            end
            local seg, stuck = 1, false
            local ref, refT = root.Position, os.clock()
            local lastAim, lastMoveT = nil, 0
            while alive() and not (abort and abort()) do
                local p = root.Position
                if flatDist(p, goal) <= within or (arrive and arrive(p)) then
                    return true
                end
                while seg < #line - 1 do
                    local a, b = line[seg], line[seg + 1]
                    local ab = Vector3.new(b.X - a.X, 0, b.Z - a.Z)
                    local l2 = ab:Dot(ab)
                    local t = l2 > 1e-6 and Vector3.new(p.X - a.X, 0, p.Z - a.Z):Dot(ab) / l2 or 1
                    if t >= 1 or flatDist(p, b) <= 1.5 then
                        seg += 1
                    else
                        break
                    end
                end
                local a, b = line[seg], line[seg + 1] or line[seg]
                local ab = Vector3.new(b.X - a.X, 0, b.Z - a.Z)
                local l2 = ab:Dot(ab)
                local t = l2 > 1e-6 and math.clamp(Vector3.new(p.X - a.X, 0, p.Z - a.Z):Dot(ab) / l2, 0, 1) or 1
                local cur, left, aim = a:Lerp(b, t), 3, line[#line]
                local k = seg
                while k < #line do
                    local nxt = line[k + 1]
                    local d = flatDist(cur, nxt)
                    if d >= left then
                        aim = cur:Lerp(nxt, d > 1e-6 and left / d or 1)
                        break
                    end
                    left -= d
                    cur = nxt
                    k += 1
                end
                -- a point ahead right where the character already is (waypoints bunched up) is no aim: on to the next waypoint,
                -- only ever forward along the line (seen live: aiming at its own spot it stood still; picking points either way
                -- made it twitch back and forth at a corner)
                if flatDist(p, aim) < 1.5 and flatDist(p, goal) > within then
                    if seg < #line - 1 then
                        seg += 1
                        aim = line[seg + 1]
                    else
                        aim = goal -- (the path ends a little short of the goal: straight on to it)
                    end
                end
                -- the game's take / bike actions end the current MoveTo (seen live: a 0.8 s stand after every wheel): it is given
                -- again the moment the character is not moving (its speed; MoveDirection reads 0 under MoveTo here, so going by it
                -- gave a new MoveTo every frame and the character twitched)
                local spd = Vector3.new(root.AssemblyLinearVelocity.X, 0, root.AssemblyLinearVelocity.Z).Magnitude
                if not lastAim or flatDist(aim, lastAim) > 0.3 or os.clock() - lastMoveT > 0.5
                    or (spd < 2 and os.clock() - lastMoveT > 0.15) then
                    hum:MoveTo(aim)
                    lastAim, lastMoveT = aim, os.clock()
                end
                if os.clock() - refT > 0.9 then
                    if flatDist(p, ref) < 0.5 then
                        stuck = true
                        break
                    end
                    ref, refT = p, os.clock()
                end
                RunService.Heartbeat:Wait()
            end
            if not stuck then
                return false
            end
            table.clear(routeCache) -- something stands in the way now: the kept ways are planned again
        end
        return false
    end

    local function stopWalk()
        local _, hum, root = getChar()
        if hum and root then
            hum:MoveTo(root.Position)
        end
    end

    -- the request in the customer's bubble, read once: { wheels = { front, back }, color = Color3?, oil = bool }
    local function readOrder(npc)
        local head = npc:FindFirstChild("Head")
        local f
        for _, b in ipairs(head and head:GetChildren() or {}) do
            if b.Name == "ChatBubble" then
                f = b:FindFirstChild(" ", true)
                if f then
                    break
                end
            end
        end
        f = f or npc:FindFirstChild(" ")
        if not f then
            return nil
        end
        local icons = {}
        for i, ic in ipairs(f:GetChildren()) do
            if ic:IsA("ImageLabel") and ic.Visible then
                table.insert(icons, { ic = ic, i = i })
            end
        end
        if #icons == 0 then
            return nil
        end
        table.sort(icons, function(a, b)
            if a.ic.LayoutOrder ~= b.ic.LayoutOrder then
                return a.ic.LayoutOrder < b.ic.LayoutOrder
            end
            if a.ic.AbsolutePosition.X ~= b.ic.AbsolutePosition.X then
                return a.ic.AbsolutePosition.X < b.ic.AbsolutePosition.X
            end
            return a.i < b.i
        end)
        local order = { wheels = {}, oil = false }
        for _, e in ipairs(icons) do
            local id = tostring(e.ic.Image):match("%d+")
            if id == COLOR_ICON then
                order.color = e.ic.ImageColor3
            elseif WHEEL_ICON[id] then
                table.insert(order.wheels, WHEEL_ICON[id])
            else
                order.oil = true
                order.oilIcon = id
            end
        end
        return order
    end

    local function describe(order)
        local out = {}
        for i, wt in ipairs(order.wheels) do
            table.insert(out, (i == 1 and "front " or "back ") .. wt)
        end
        if order.oil then
            table.insert(out, "oil")
        end
        if order.paint then
            table.insert(out, order.paint.Name .. " paint")
        end
        return table.concat(out, ", ")
    end

    local function paintFor(I, color)
        local best, bd
        for _, p in ipairs(I.PaintingEquipment:GetChildren()) do
            local can = p:FindFirstChild("Can")
            if can then
                local c = can.BrickColor.Color
                local d = math.abs(c.R - color.R) + math.abs(c.G - color.G) + math.abs(c.B - color.B)
                if not bd or d < bd then
                    best, bd = p, d
                end
            end
        end
        return best
    end

    -- the game's handler of the Done button (only the game's closure); mobile: the Screen's "B_Done" interaction
    local function pressDone(w)
        local screen = w:FindFirstChild("Display") and w.Display:FindFirstChild("Screen")
        local gui = screen and screen:FindFirstChild("MechanicGUI")
        local btn = gui and gui:FindFirstChild("Frame") and gui.Frame:FindFirstChild("Done")
        local ok, conns = pcall(getconnections, btn and btn.Activated)
        local fn = ok and conns and conns[1] and conns[1].Function or callback(screen, "B_Done")
        if not fn then
            return false
        end
        return use(fn)
    end

    -- one trip: walk to the item, take it, straight back to the bike (no stop) and use it on the bike
    local spent -- the item last used on the bike: the game takes it out of the hand a moment later, it is never used again
    local function trip(ctx, item, stand, isHeld, action)
        local w, npc, list, bike = ctx.w, ctx.npc, ctx.list, ctx.stand
        local function gone()
            return w.Occupied.Value ~= npc or npc.Parent == nil
        end
        local function held()
            local e = equipped()
            return e ~= nil and e ~= spent and isHeld()
        end
        if not held() then
            -- both legs are planned before setting off (the way back while walking there), so nothing stops to plan
            local _, _, r0 = getChar()
            local there = r0 and preplan(flatDist(r0.Position, bike) < 4 and bike or r0.Position, stand, w, list)
            local back = preplan(stand, bike, w, list)
            setStatus("Walking to the " .. ctx.label)
            -- taken from where the player takes it by hand (watched live: racks ~4 studs, oil ~4.6, paint ~6.4 from the item)
            local itemPos = item:GetPivot().Position
            local reach = ctx.label:find("paint", 1, true) and 5.5 or 4.5
            if not walk(stand, 1.6, w, list, there, gone, function(p)
                return flatDist(p, itemPos) <= reach
            end) then
                return false, gone() and "customer left" or "can't reach the " .. ctx.label
            end
            -- a wheel / painter the game is still putting away (it unequips 1 s / 3 s after the bike is done): by the time
            -- the item is reached it is gone; only something else still in hand is put away
            if not waitUntil(function()
                return equipped() == nil
            end, 1.5) then
                pcall(function()
                    JobHandler.Shared.EquipmentService:UnequipItem(LocalPlayer, nil, false)
                end)
                waitUntil(function()
                    return equipped() == nil
                end, 1.5)
            end
            local cb
            waitUntil(function()
                cb = callback(item, "I_Take")
                return cb ~= nil
            end, 2)
            if not cb then
                return false, "the " .. ctx.label .. " can't be taken"
            end
            setStatus("Taking the " .. ctx.label)
            -- at a person's pace, like the other jobs: a short stop at the item to take it (watched live: the player stands
            -- 0.4-1.0 s at the rack / paint / oil while taking)
            stopWalk()
            pause(0.25, 0.45)
            local _, _, rT = getChar()
            local takeDist = rT and flatDist(rT.Position, item:GetPivot().Position) or -1
            if not use(cb) then
                return false, "unsafe"
            end
            pause(0.2, 0.35)
            setStatus("Bringing the " .. ctx.label .. " to the bike")
            if not walk(bike, 1.6, w, list, back, gone) then
                return false, gone() and "customer left" or "can't reach the bike"
            end
            if not waitUntil(held, 2.5) then
                local e = equipped()
                return false, string.format("the %s did not come into the hand (holding %s %s, spent %s, taken %.1f studs away)",
                    ctx.label, tostring(e), tostring(e and e:GetAttribute("_wheelType")), tostring(e ~= nil and e == spent), takeDist)
            end
        elseif flatDist(select(3, getChar()).Position, bike) > 2 then
            if not walk(bike, 1.6, w, list, nil, gone) then
                return false, "can't reach the bike"
            end
        end
        local cb
        waitUntil(function()
            cb = callback(npc:FindFirstChild("Vehicle"), action)
            return cb ~= nil or gone()
        end, 2.5)
        if not cb then
            return false, gone() and "customer left" or action .. " not offered"
        end
        stopWalk()
        pause(0.2, 0.4)
        spent = equipped()
        if not use(cb) then
            return false, "unsafe"
        end
        -- a wheel is put on with the game's ReplaceMotorcycleWheel animation (1 s, measured live): the next walk starts once
        -- it has finished and the wheel is on (seen live: walking off at 0.9 s, 1.7 studs gone before the wheel was on)
        if action == "I_ChangeFrontWheel" or action == "I_ChangeBackWheel" then
            local _, hum = getChar()
            local animator = hum and hum:FindFirstChildOfClass("Animator")
            local function fitting()
                for _, tr in ipairs(animator and animator:GetPlayingAnimationTracks() or {}) do
                    if tr.Name == "ReplaceMotorcycleWheel" then
                        return true
                    end
                end
                return false
            end
            waitUntil(fitting, 0.5)
            waitUntil(function()
                return not fitting() and equipped() ~= spent
            end, 2)
            pause(0.1, 0.2)
        end
        return true
    end

    local function serve(w, npc, order, list)
        local I = interior()
        local bike = standOf(w, list)
        local steps = {}
        local function wheelHeld(wt)
            return function()
                local e = equipped()
                return e ~= nil and e:GetAttribute("_wheelType") == wt
            end
        end
        for i, wt in ipairs(order.wheels) do
            local rack = I.TireRacks:FindFirstChild(wt)
            table.insert(steps, { item = rack, stand = rack and rackStand(rack), held = wheelHeld(wt), label = wt .. " wheel",
                action = i == 1 and "I_ChangeFrontWheel" or "I_ChangeBackWheel" })
        end
        if order.oil then
            local _, _, root = getChar()
            local can, cd
            for _, c in ipairs(I.OilCans:GetChildren()) do
                local d = root and flatDist(c:GetPivot().Position, root.Position) or 0
                if not cd or d < cd then
                    can, cd = c, d
                end
            end
            table.insert(steps, { item = can, stand = can and tableStand(can, list), label = "oil", action = "I_FillOil",
                held = function()
                    return tostring(equipped()) == "Oil Can"
                end })
        end
        if order.paint then
            -- last: the game puts the painter away 3 s after spraying, which would also take away the next item
            table.insert(steps, { item = order.paint, stand = tableStand(order.paint, list), label = order.paint.Name .. " paint",
                action = "I_Paint", held = function()
                    local e = equipped()
                    local can = e and tostring(e) == "Spray Painter" and e:FindFirstChild("Can")
                    local mine = order.paint:FindFirstChild("Can")
                    return can ~= nil and mine ~= nil and can.BrickColor == mine.BrickColor
                end })
        end
        order.step = order.step or 1
        while order.step <= #steps do
            local s = steps[order.step]
            if not (s.item and s.stand) then
                return false, "no spot for the " .. s.label
            end
            local ok, why = trip({ w = w, npc = npc, list = list, stand = bike, label = s.label }, s.item, s.stand, s.held, s.action)
            if not ok then
                return false, why
            end
            order.step += 1
        end
        -- the game finishes the last change before the order counts (wheel 1 s, paint 3 s; seen live: Done pressed earlier
        -- was ignored or turned down): it is in hand until then
        setStatus("Finishing the bike")
        waitUntil(function()
            return equipped() == nil
        end, 4.5)
        local _, _, root = getChar()
        if root and flatDist(root.Position, bike) > 2 then
            walk(bike, 1.6, w, list)
        end
        pause(0.7, 1.1) -- a look at the finished bike before Done (the player: ~1.5 s)
        if w.Occupied.Value ~= npc then
            return false, "customer left"
        end
        setStatus("Pressing Done")
        local orderValue = npc:FindFirstChild("Order")
        if not pressDone(w) then
            return false, "no Done button"
        end
        waitUntil(function()
            return not orderValue or orderValue.Value ~= "" or w.Occupied.Value ~= npc
        end, 6)
        if orderValue and orderValue.Value == "" and w.Occupied.Value == npc then
            -- no answer: the game no longer counts what was done on this bike (seen live: a customer still there from
            -- before the shift started again). The request is done once more; still no answer -> wait for the next customer
            order.noAnswer = (order.noAnswer or 0) + 1
            order.step = 1
            if order.noAnswer >= 2 then
                order.dead = true
            end
            return false, "no answer to Done"
        end
        if orderValue and orderValue.Value == "false" then
            warn("[Legit Farm Job] mechanic: the order was not accepted (" .. describe(order)
                .. (order.oilIcon and (", oil icon " .. order.oilIcon) or "") .. ")")
            setStatus("Order not accepted, next customer")
        else
            setStatus("Order done")
        end
        waitUntil(function()
            return w.Occupied.Value ~= npc
        end, 6)
        return true
    end

    function M.step()
        if not farming then
            task.wait(0.3)
            return
        end
        if not isWorkingJob(JOB) then
            setStatus("Start the Mechanic - Mike's Motors job first")
            task.wait(1)
            return
        end
        local _, hum, root = getChar()
        if not hum then
            setStatus("Waiting for character")
            task.wait(1)
            return
        end
        local I = interior()
        local list = stations()
        if not (I and #list > 0 and I:FindFirstChild("TireRacks") and I:FindFirstChild("PaintingEquipment") and I:FindFirstChild("OilCans")) then
            setStatus("Waiting for the garage")
            task.wait(1)
            return
        end
        if not corridorZ then
            local p = I.PaintingEquipment:GetChildren()[1]
            local f, d
            if p then
                f, d = tableStand(p, list)
            end
            if f then
                corridorZ = f.Z + d.Z * 4.3 -- (watched live: the player walks the wall line at z -294 .. -291.6)
                wallSign = -d.Z
            end
        end
        -- station 1 unless another player works it; back to station 1 when it is free and this one has no customer
        -- the station it works is only given up when the game marks another player on it (InUse): another player just
        -- walking past (seen live with two accounts: the other one passing station 1 on its way to the racks, 2.2 studs from
        -- its customer spot) sent this one off to station 3
        local function usedByOther(s)
            local u = s:FindFirstChild("InUse") and s.InUse.Value
            return typeof(u) == "Instance" and u ~= LocalPlayer and u.Parent == Players
        end
        local mine = station and station.Parent and not usedByOther(station)
        if mine and not station.Occupied.Value then
            -- no customer here: a station before it in the order (or the test station) that is free is used instead
            local forced = list[tonumber(getgenv().LFJ_MechStation) or 0]
            for _, s in ipairs(forced and { forced } or list) do
                if s == station then
                    break
                end
                if not takenByOther(s) and standOf(s, list) then
                    mine = false
                    break
                end
            end
        end
        if not mine then
            local pick
            -- (getgenv().LFJ_MechStation = 2 / 3 / 4: that station is tried first, used to test the other stations)
            local first = list[tonumber(getgenv().LFJ_MechStation) or 0]
            if first and not takenByOther(first) and standOf(first, list) then
                pick = first
            end
            for _, w in ipairs(pick and {} or list) do
                if not takenByOther(w) and standOf(w, list) then
                    pick = w
                    break
                end
            end
            station = pick
        end
        local w = station
        if not w then
            setStatus("No free station, waiting")
            task.wait(1.5)
            return
        end
        local idx = table.find(list, w) or 0
        local stand = standOf(w, list)
        -- the stations walking keeps away from: the free ones only (a station another player works gets no customer
        -- from this character; seen live with a player at station 1: keeping away from it made 8 s detours to the racks)
        if #pads ~= #list then
            table.clear(pads)
            for _, s in ipairs(list) do
                local cf, size = s.Lift:GetBoundingBox()
                table.insert(pads, { w = s, cf = cf, size = size })
            end
        end
        local guarded = {}
        for _, s in ipairs(list) do
            if s == w or not takenByOther(s) then
                table.insert(guarded, s)
            end
        end
        list = guarded
        local npc = w.Occupied.Value
        if not npc then
            if flatDist(root.Position, stand) > 2 then
                setStatus("Walking to station " .. idx)
                if not walk(stand, 1.2, w, list) and farming then
                    setStatus("Can't reach station " .. idx .. ", retrying")
                    standCache[w] = nil
                    task.wait(1)
                end
                return
            end
            stopWalk()
            setStatus("Waiting for customer at station " .. idx)
            -- every way from this bike to the racks, paint and oil is planned while waiting (kept for the shift)
            -- (one at a time, so the client never plans many paths at once)
            if not warmed[w] then
                warmed[w] = true
                task.spawn(function()
                    for _, folder in ipairs({ "TireRacks", "PaintingEquipment", "OilCans" }) do
                        for _, it in ipairs(I[folder]:GetChildren()) do
                            local s = folder == "TireRacks" and rackStand(it) or tableStand(it, list)
                            for _, pair in ipairs(s and { { stand, s }, { s, stand } } or {}) do
                                local h = preplan(pair[1], pair[2], w, list)
                                while running and not h.done do
                                    task.wait(0.05)
                                end
                            end
                        end
                    end
                end)
            end
            task.wait(0.3)
            return
        end
        local orderValue = npc:FindFirstChild("Order")
        if not (orderValue and orderValue.Value == "") then
            setStatus("Waiting for the next customer")
            task.wait(0.3)
            return
        end
        local order = orders[npc]
        if not order then
            order = readOrder(npc)
            if not order then
                if flatDist(root.Position, stand) > 2 then
                    walk(stand, 1.2, w, list)
                end
                setStatus("Reading the request")
                task.wait(0.2)
                return
            end
            order.paint = order.color and paintFor(I, order.color)
            orders[npc] = order
            setStatus("Request: " .. describe(order))
            -- this order's ways (bike -> item -> bike) are planned now, one after another, while the request is read (seen
            -- live: a way to the wall still being planned when the walk started = a 0.9 s stand at the bike)
            do
                local items = {}
                for _, wt in ipairs(order.wheels) do
                    local rack = I.TireRacks:FindFirstChild(wt)
                    table.insert(items, rack and rackStand(rack))
                end
                if order.oil then
                    local can, cd
                    for _, c in ipairs(I.OilCans:GetChildren()) do
                        local d = flatDist(c:GetPivot().Position, root.Position)
                        if not cd or d < cd then
                            can, cd = c, d
                        end
                    end
                    table.insert(items, can and tableStand(can, list))
                end
                if order.paint then
                    table.insert(items, (tableStand(order.paint, list)))
                end
                local glist = list
                task.spawn(function()
                    for _, s in ipairs(items) do
                        for _, pair in ipairs({ { stand, s }, { s, stand } }) do
                            local h = preplan(pair[1], pair[2], w, glist)
                            while running and not h.done do
                                task.wait(0.03)
                            end
                        end
                    end
                end)
            end
            pause(0.6, 1) -- reading the request
        end
        if order.dead then
            setStatus("Customer is not answering, waiting for the next one")
            if flatDist(root.Position, stand) > 2 then
                walk(stand, 1.2, w, list)
            end
            task.wait(0.5)
            return
        end
        setStatus("Request: " .. describe(order))
        local ok, why = serve(w, npc, order, list)
        -- seen live: after the shift was started again the game refused every take (even its own E menu); leaving the job
        -- (the game's own teleport to the plot) and coming back (the game's own GoToWork) fixes it
        if not ok and tostring(why):find("did not come into the hand", 1, true) then
            M.takeFails = (M.takeFails or 0) + 1
        elseif ok then
            M.takeFails = 0
        end
        if (M.takeFails or 0) >= 3 and farming then
            M.takeFails = 0
            setStatus("Grabbing is not working: leaving the job and coming back")
            pcall(function()
                require(PlayerModules:WaitForChild("HouseHandler")):ToPlot(LocalPlayer)
            end)
            local t0 = os.clock()
            task.wait(2)
            while running and farming and os.clock() - t0 < 30 and JobHandler.Modules.LoadingHandler:IsLoadingAny() do
                task.wait(0.5)
            end
            task.wait(1)
            if running and farming then
                pcall(function()
                    JobHandler:GoToWork(JOB)
                end)
                t0 = os.clock()
                task.wait(2)
                while running and farming and os.clock() - t0 < 30 and not (isWorkingJob(JOB) and not JobHandler.Modules.LoadingHandler:IsLoadingAny()) do
                    task.wait(0.5)
                end
            end
            M.stop()
            return
        end
        if not ok and alive() then
            setStatus("Mechanic problem (" .. tostring(why) .. "), retrying")
            warn("[Legit Farm Job] mechanic: " .. tostring(why))
            task.wait(0.5)
        end
    end

    function M.stop()
        station = nil
        table.clear(standCache)
        table.clear(warmed)
        table.clear(routeCache)
        corridorZ, spent, wallSign = nil, nil, 1
    end

    return M
end)()

-- Stocker - BFF Supermarket (job id SupermarketStocker). Found live in the game's own JobHandler.SupermarketStocker: the
-- stock room is the job's AreaBlock (JobArea_SupermarketStocker); the food crates are Environment.Locations.City.
-- Supermarket.Geometry.Crates "Crate" x24 ("BagCrate" there is the cashier's), whose "I_Take" (TakeFoodCrate) is offered
-- inside the stock room with empty hands; the shelves are Supermarket.Interior.Shelves (28: Fridge_*, Shelf_*, Aisle_*,
-- WallAisle_*), each with a BoolValue IsEmpty, whose "I_Restock" (RestockShelf) is offered outside the stock room while
-- holding "Food Crate" and IsEmpty is true. Seen live: 5 shelves are empty at a time; restocking one makes another one
-- empty (nothing changes on its own: watched 50 s). The shift ends when the character leaves Supermarket.Exterior.Floor.
-- Measured live: a crate is taken from 5.4 studs, a shelf restocked from 5.0 studs (flat, to its middle).
NC.stock = (function()
    local K = {}
    local JOB = "SupermarketStocker"
    local AGENTS = {
        { AgentRadius = 1.5, AgentHeight = 5, AgentCanJump = false },
        { AgentRadius = 1, AgentHeight = 5, AgentCanJump = false },
    }
    local target -- the shelf being stocked now (one at a time)
    local routeCache = {}
    local nextPre -- { goal, h }: the way on, planned during the take / restock, used by the next walk
    local function preFor(goal, from, preplanFn)
        if nextPre and (Vector3.new(nextPre.goal.X, 0, nextPre.goal.Z) - Vector3.new(goal.X, 0, goal.Z)).Magnitude < 1 then
            local h = nextPre.h
            nextPre = nil
            return h
        end
        return preplanFn(from, goal)
    end
    local outerSetStatus = setStatus
    local function setStatus(text)
        if farming then
            outerSetStatus(text)
        end
    end

    local function alive()
        return running and farming and isWorkingJob(JOB)
    end

    local function pause(a, b)
        local t = a + math.random() * (b - a)
        local t0 = os.clock()
        while alive() and os.clock() - t0 < t do
            task.wait(0.03)
        end
    end

    local function waitUntil(cond, timeout)
        local t0 = os.clock()
        while alive() and os.clock() - t0 < timeout do
            if cond() then
                return true
            end
            task.wait(0.05)
        end
        return cond()
    end

    local function flatDist(a, b)
        return (Vector3.new(a.X, 0, a.Z) - Vector3.new(b.X, 0, b.Z)).Magnitude
    end

    local function market()
        local n = workspace:FindFirstChild("Environment")
        for _, name in ipairs({ "Locations", "City", "Supermarket" }) do
            n = n and n:FindFirstChild(name)
        end
        return n
    end

    -- the stock room: the same box test the game's own isInWarehouse does with the job's AreaBlock
    local function inStockRoom(p)
        local ok, inside = pcall(function()
            local ab = JobHandler:GetCurJobModule().AreaBlock
            local v = ab.CFrame:Inverse() * p
            return math.abs(v.X) < ab.Size.X * 0.5 and math.abs(v.Z) < ab.Size.Z * 0.5
        end)
        return ok and inside
    end

    -- on the shop's floor (Exterior.Floor: leaving it ends the shift), `inset` studs in from its edge
    local function onShopFloor(p, inset)
        local sm = market()
        local f = sm and sm:FindFirstChild("Exterior") and sm.Exterior:FindFirstChild("Floor")
        if not f then
            return true
        end
        return math.abs(p.X - f.Position.X) < f.Size.X * 0.5 - inset and math.abs(p.Z - f.Position.Z) < f.Size.Z * 0.5 - inset
    end

    local function callback(obj, wanted)
        local reg = getInteractRegistry()
        local entry = reg and obj and reg[obj]
        local gens = entry and entry[1]
        for _, gen in ipairs(type(gens) == "table" and gens or {}) do
            if type(gen) == "function" then
                local ok, text, _, cb = pcall(gen)
                if ok and text == wanted and type(cb) == "function" then
                    return cb
                end
            end
        end
    end

    local function use(cb)
        if not cleanSafe(cb) then
            farming = false
            if FarmToggle then
                withUiIdentity(function()
                    FarmToggle:Set(false)
                end)
            end
            outerSetStatus("Stopped: unsafe stocker state")
            return false
        end
        task.spawn(function()
            pcall(cb)
        end)
        return true
    end

    local function holding()
        local ok, e = pcall(function()
            return JobHandler.Shared.EquipmentService:GetEquipped(LocalPlayer)
        end)
        return ok and tostring(e) == "Food Crate"
    end

    local function handsFree()
        local ok, e = pcall(function()
            return JobHandler.Shared.EquipmentService:GetEquipped(LocalPlayer)
        end)
        return ok and e == nil
    end

    local function ignoreList()
        local ignore = {}
        for _, plr in ipairs(Players:GetPlayers()) do
            if plr.Character then
                table.insert(ignore, plr.Character)
            end
        end
        return ignore
    end

    -- a free floor spot near p (the floor itself - live 19.7 on the shop floor, 20.1 in the stock room - nothing solid where
    -- the character would stand)
    local function freeFloor(p)
        local sm = market()
        local fl = sm and sm:FindFirstChild("Exterior") and sm.Exterior:FindFirstChild("Floor")
        local floorY = fl and fl.Position.Y + fl.Size.Y / 2 or p.Y
        local params = RaycastParams.new()
        params.FilterType = Enum.RaycastFilterType.Exclude
        params.FilterDescendantsInstances = ignoreList()
        local h = workspace:Raycast(Vector3.new(p.X, floorY + 6, p.Z), Vector3.new(0, -14, 0), params)
        if not h or math.abs(h.Position.Y - floorY) > 1.5 then
            return nil
        end
        local op = OverlapParams.new()
        op.FilterType = Enum.RaycastFilterType.Exclude
        op.FilterDescendantsInstances = params.FilterDescendantsInstances
        op.RespectCanCollide = true
        if #workspace:GetPartBoundsInBox(CFrame.new(h.Position + Vector3.new(0, 2.6, 0)), Vector3.new(2.4, 4, 2.4), op) > 0 then
            return nil
        end
        return h.Position
    end

    local function crates()
        local sm = market()
        local folder = sm and sm:FindFirstChild("Geometry") and sm.Geometry:FindFirstChild("Crates")
        local out = {}
        for _, c in ipairs(folder and folder:GetChildren() or {}) do
            if c.Name == "Crate" then
                table.insert(out, c)
            end
        end
        return out
    end

    local function emptyShelves()
        local sm = market()
        local folder = sm and sm:FindFirstChild("Interior") and sm.Interior:FindFirstChild("Shelves")
        local out = {}
        for _, s in ipairs(folder and folder:GetChildren() or {}) do
            local e = s:FindFirstChild("IsEmpty")
            if e and e.Value then
                table.insert(out, s)
            end
        end
        return out
    end

    -- where to stand for a crate: on the stock room floor beside it, the side nearest to `from`
    local function crateStand(crate, from)
        local p = crate:GetPivot().Position
        local best, bd
        for k = 0, 7 do
            local a = k * math.pi / 4
            local f = freeFloor(p + Vector3.new(math.cos(a) * 4, 0, math.sin(a) * 4))
            if f and inStockRoom(f) then
                local d = flatDist(f, from)
                if not bd or d < bd then
                    best, bd = f, d
                end
            end
        end
        return best
    end

    -- spots / shelves a walk could not reach (seen live: the side spot between two fridges by the back wall has free
    -- floor but no path in; the fridge's front does): left out for a while, the next side / shelf is used
    local badStand, badShelf = {}, setmetatable({}, { __mode = "k" })
    local function standKey(p)
        return math.floor(p.X + 0.5) .. "," .. math.floor(p.Z + 0.5)
    end

    -- where to stand for a shelf: in front of one of its sides, on the shop floor and outside the stock room, the one
    -- nearest to `from` (a wall behind a wall aisle is no spot: off the shop floor)
    -- (measured from the shelf's own surface, a ray toward it from 8 directions: the island aisles are 17 studs across and
    -- turned, their box put the spot 14 studs from the middle where Restock did nothing; 2.2 studs from the edge = 8.9 from
    -- the middle worked live). Returns the spot and the surface point it faces.
    local function shelfStand(shelf, from)
        local cf = shelf:GetBoundingBox()
        local rp = RaycastParams.new()
        rp.FilterType = Enum.RaycastFilterType.Include
        rp.FilterDescendantsInstances = { shelf }
        local best, bestHit, bd
        for k = 0, 7 do
            local a = k * math.pi / 4
            local d = Vector3.new(math.cos(a), 0, math.sin(a))
            local h = workspace:Raycast(cf.Position + d * 20, -d * 20, rp)
            if h then
                for _, gap in ipairs({ 2.2, 3 }) do
                    local f = freeFloor(h.Position + d * gap)
                    if f and onShopFloor(f, 2) and not inStockRoom(f) and not (badStand[standKey(f)] and badStand[standKey(f)] > os.clock()) then
                        local dist = flatDist(f, from)
                        if not bd or dist < bd then
                            best, bestHit, bd = f, h.Position, dist
                        end
                        break
                    end
                end
            end
        end
        return best, bestHit
    end

    -- Walking: PathfindingService waypoints followed with Humanoid:MoveTo toward a point 3 studs ahead, only ever forward
    -- along the line; MoveTo given again only when the character has stopped (its speed)
    local function plan(from, to)
        for _, cfg in ipairs(AGENTS) do
            local p = PathfindingService:CreatePath(cfg)
            local ok = pcall(function()
                p:ComputeAsync(from, to)
            end)
            if ok and p.Status == Enum.PathStatus.Success then
                local wps = p:GetWaypoints()
                if #wps > 0 and flatDist(wps[#wps].Position, to) < 3 then
                    local pts, good = {}, true
                    for _, wp in ipairs(wps) do
                        pts[#pts + 1] = wp.Position
                        if not onShopFloor(wp.Position, 0.5) then
                            good = false -- (off the shop floor the shift ends)
                        end
                    end
                    if good then
                        return pts
                    end
                end
            end
        end
    end

    -- planned before it is needed (the way on while the current walk / take / restock happens), kept per pair of spots
    local function preplan(from, to)
        local key = string.format("%d,%d>%d,%d", math.floor(from.X + 0.5), math.floor(from.Z + 0.5), math.floor(to.X + 0.5), math.floor(to.Z + 0.5))
        local h = routeCache[key]
        if h and (not h.done or h.line) then
            return h
        end
        h = { done = false }
        routeCache[key] = h
        task.spawn(function()
            local ok, line = pcall(plan, from, to)
            h.line = ok and line or nil
            h.done = true
        end)
        return h
    end

    local function walk(goal, within, pre, arrive)
        for attempt = 1, 4 do
            if not alive() then
                return false
            end
            local _, hum, root = getChar()
            if not (hum and root) then
                return false
            end
            if flatDist(root.Position, goal) <= within or (arrive and arrive(root.Position)) then
                return true
            end
            local line
            if pre and attempt == 1 then
                local t0 = os.clock()
                while not pre.done and os.clock() - t0 < 3 do
                    RunService.Heartbeat:Wait()
                end
                line = pre.line
                if line and flatDist(line[1], root.Position) > 6 then
                    line = nil
                end
            end
            line = line or plan(root.Position, goal)
            if not line then
                task.wait(0.3)
                continue
            end
            local seg, stuck = 1, false
            local ref, refT = root.Position, os.clock()
            local lastAim, lastMoveT = nil, 0
            while alive() do
                local p = root.Position
                if flatDist(p, goal) <= within or (arrive and arrive(p)) then
                    return true
                end
                while seg < #line - 1 do
                    local a, b = line[seg], line[seg + 1]
                    local ab = Vector3.new(b.X - a.X, 0, b.Z - a.Z)
                    local l2 = ab:Dot(ab)
                    local t = l2 > 1e-6 and Vector3.new(p.X - a.X, 0, p.Z - a.Z):Dot(ab) / l2 or 1
                    if t >= 1 or flatDist(p, b) <= 1.5 then
                        seg += 1
                    else
                        break
                    end
                end
                local a, b = line[seg], line[seg + 1] or line[seg]
                local ab = Vector3.new(b.X - a.X, 0, b.Z - a.Z)
                local l2 = ab:Dot(ab)
                local t = l2 > 1e-6 and math.clamp(Vector3.new(p.X - a.X, 0, p.Z - a.Z):Dot(ab) / l2, 0, 1) or 1
                local cur, left, aim = a:Lerp(b, t), 3, line[#line]
                local k = seg
                while k < #line do
                    local nxt = line[k + 1]
                    local d = flatDist(cur, nxt)
                    if d >= left then
                        aim = cur:Lerp(nxt, d > 1e-6 and left / d or 1)
                        break
                    end
                    left -= d
                    cur = nxt
                    k += 1
                end
                if flatDist(p, aim) < 1.5 and flatDist(p, goal) > within then
                    if seg < #line - 1 then
                        seg += 1
                        aim = line[seg + 1]
                    else
                        aim = goal
                    end
                end
                local spd = Vector3.new(root.AssemblyLinearVelocity.X, 0, root.AssemblyLinearVelocity.Z).Magnitude
                if not lastAim or flatDist(aim, lastAim) > 0.3 or os.clock() - lastMoveT > 0.5
                    or (spd < 2 and os.clock() - lastMoveT > 0.15) then
                    hum:MoveTo(aim)
                    lastAim, lastMoveT = aim, os.clock()
                end
                if os.clock() - refT > 0.9 then
                    if flatDist(p, ref) < 0.5 then
                        stuck = true
                        break
                    end
                    ref, refT = p, os.clock()
                end
                RunService.Heartbeat:Wait()
            end
            if not stuck then
                return false
            end
            table.clear(routeCache)
        end
        return false
    end

    local function stopWalk()
        local _, hum, root = getChar()
        if hum and root then
            hum:MoveTo(root.Position)
        end
    end

    local function nearestShelf(list, from)
        local best, bs, bh, bd
        for _, s in ipairs(list) do
            if not (badShelf[s] and badShelf[s] > os.clock()) then
                local st, hit = shelfStand(s, from)
                if st then
                    local d = flatDist(st, from)
                    if not bd or d < bd then
                        best, bs, bh, bd = s, st, hit, d
                    end
                end
            end
        end
        return best, bs, bh
    end

    -- the stock room's doorway: where the path from the last restock spot (open shop floor) to the spot the first box
    -- was taken from (open floor in the room) enters the room - live 543.0,-779.8 / 542.8,-782.1, the west wall is open
    -- from z -786 to -781 (paths from the room's / the shop's middle had no start: a crate pile / a shelf stands there).
    -- The crates all have the same name ("Crate") and no attributes; the piles by the doorway are told apart only by where
    -- they stand: left z -772..-777 and right z -792..-795 at x 541-548, the others at x 561-565 and 577-583 (the back)
    local doorway, roomSpot, shopSpot
    local function doorwayPoint()
        if doorway or not (roomSpot and shopSpot) then
            return doorway
        end
        local p = PathfindingService:CreatePath({ AgentRadius = 1.5, AgentHeight = 5, AgentCanJump = false })
        local okP = pcall(function()
            p:ComputeAsync(shopSpot, roomSpot)
        end)
        if okP and p.Status == Enum.PathStatus.Success then
            for _, wp in ipairs(p:GetWaypoints()) do
                if inStockRoom(wp.Position) then
                    doorway = wp.Position
                    break
                end
            end
        end
        return doorway
    end

    local tookOne = false -- the first box after Auto Farm is turned on is the one nearest the character
    local function nearestCrate(from)
        -- after the first box: only the piles by the doorway (within 16 studs of it; the nearest other crate is 19 away),
        -- the crate nearest the doorway (seen live: coming back from a shelf it walked to the back of the stock room)
        local door = tookOne and doorwayPoint()
        if door then
            local best, bs, bd
            for _, c in ipairs(crates()) do
                local d = flatDist(c:GetPivot().Position, door)
                if d <= 16 and (not bd or d < bd) then
                    local st = crateStand(c, door)
                    if st then
                        best, bs, bd = c, st, d
                    end
                end
            end
            if best then
                return best, bs
            end
        end
        local best, bs, bd
        for _, c in ipairs(crates()) do
            local d = flatDist(c:GetPivot().Position, from)
            if not bd or d < bd then
                local st = crateStand(c, from)
                if st then
                    best, bs, bd = c, st, d
                end
            end
        end
        return best, bs
    end

    local function isEmpty(s)
        local e = s and s.Parent and s:FindFirstChild("IsEmpty")
        return e ~= nil and e.Value
    end

    function K.step()
        if not farming then
            task.wait(0.3)
            return
        end
        if not isWorkingJob(JOB) then
            setStatus("Start the Stocker - BFF Supermarket job first")
            task.wait(1)
            return
        end
        local _, hum, root = getChar()
        if not hum then
            setStatus("Waiting for character")
            task.wait(1)
            return
        end
        if not market() then
            setStatus("Waiting for the supermarket")
            task.wait(1)
            return
        end
        if holding() then
            -- a box in hand: to the shelf being stocked (another empty one when that one was stocked meanwhile)
            if not isEmpty(target) then
                target = nil
            end
            local stand, surface
            if target then
                -- (the spot whose way was planned while taking the box)
                if nextPre and nextPre.shelf == target then
                    stand, surface = nextPre.goal, nextPre.surface
                else
                    stand, surface = shelfStand(target, root.Position)
                end
            else
                target, stand, surface = nearestShelf(emptyShelves(), root.Position)
            end
            if not (target and stand and surface) then
                setStatus("No shelf needs stock, waiting")
                task.wait(0.5)
                return
            end
            local shelf = target
            setStatus("Bringing the box to " .. shelf.Name)
            -- (restocked as soon as the shelf's surface is within reach, still walking up to it)
            if not walk(stand, 1.5, preFor(stand, root.Position, preplan), function(p)
                return flatDist(p, surface) <= 3 and not inStockRoom(p)
            end) then
                if farming and not isEmpty(shelf) then
                    target = nil -- (stocked by someone else on the way)
                elseif farming then
                    -- that spot is left out; the shelf's next side is tried, and with no side left the shelf for a while
                    badStand[standKey(stand)] = os.clock() + 60
                    nextPre = nil
                    local _, _, r2 = getChar()
                    if not (r2 and shelfStand(shelf, r2.Position)) then
                        badShelf[shelf] = os.clock() + 30
                        target = nil
                    end
                    setStatus("Can't reach " .. shelf.Name .. " from there, trying another way")
                end
                return
            end
            if not isEmpty(shelf) then
                target = nil
                return
            end
            local cb
            waitUntil(function()
                cb = callback(shelf, "I_Restock")
                return cb ~= nil
            end, 2)
            if not cb then
                setStatus("Restock is not offered at " .. shelf.Name .. ", retrying")
                task.wait(0.5)
                return
            end
            -- the next crate's way is planned while restocking (no stop to plan after it)
            shopSpot = shopSpot or stand
            local _, cs = nearestCrate(root.Position)
            if cs then
                nextPre = { goal = cs, h = preplan(root.Position, cs) }
                -- and the box after it to its shelf (seen live: a long way to a far fridge still being planned when the
                -- box was taken = a 2 s stand in the stock room)
                local others = {}
                for _, s in ipairs(emptyShelves()) do
                    if s ~= shelf then
                        table.insert(others, s)
                    end
                end
                local _, s2 = nearestShelf(others, cs)
                if s2 then
                    preplan(cs, s2)
                end
            end
            setStatus("Restocking " .. shelf.Name)
            stopWalk()
            pause(0.2, 0.35)
            if not use(cb) then
                return
            end
            waitUntil(function()
                return not isEmpty(shelf) or not holding()
            end, 3)
            if isEmpty(shelf) and holding() then
                -- not taken (too far from it): that spot is left out, another side of the shelf next
                badStand[standKey(stand)] = os.clock() + 60
                nextPre = nil
                setStatus("Restock did not take at " .. shelf.Name .. ", another side")
                return
            end
            target = nil
            return
        end
        -- empty hands: a box from the stock room, then on to the empty shelf nearest to it
        local list = emptyShelves()
        if #list == 0 then
            setStatus("No shelf needs stock, waiting")
            task.wait(0.5)
            return
        end
        if not handsFree() then
            setStatus("Put away what you are holding first")
            task.wait(1)
            return
        end
        local crate, cstand = nearestCrate(root.Position)
        if not (crate and cstand) then
            setStatus("No box found in the stock room, waiting")
            task.wait(1)
            return
        end
        local cpos = crate:GetPivot().Position
        -- the shelf for this box is chosen now and its way planned while walking to the box
        local shelf, sstand, ssurface = nearestShelf(list, cstand)
        local shelfPre = sstand and preplan(cstand, sstand)
        setStatus("Walking to the stock")
        if not walk(cstand, 1.5, preFor(cstand, root.Position, preplan), function(p)
            return flatDist(p, cpos) <= 4.5 and inStockRoom(p)
        end) then
            if farming then
                setStatus("Can't reach the stock, retrying")
                task.wait(0.5)
            end
            return
        end
        local cb
        waitUntil(function()
            cb = crate.Parent and callback(crate, "I_Take")
            return cb ~= nil
        end, 1.5)
        if not cb then
            return -- (taken by someone else / just taken: the next one)
        end
        setStatus("Taking a box")
        stopWalk()
        pause(0.2, 0.35)
        if not use(cb) then
            return
        end
        target = shelf
        tookOne = true
        roomSpot = roomSpot or cstand
        if shelfPre then
            nextPre = { goal = sstand, h = shelfPre, shelf = shelf, surface = ssurface }
        end
        if not waitUntil(holding, 2) then
            -- (seen live right after a shift starts: the game ignores the first takes for a few seconds)
            setStatus("The box was not handed over, trying again")
            task.wait(1)
        end
    end

    function K.stop()
        target = nil
        nextPre = nil
        tookOne, doorway, roomSpot, shopSpot = false, nil, nil, nil
        table.clear(routeCache)
    end

    return K
end)()

local hookConns = {}
local function hook(name, fn)
    local ok, handle = pcall(function()
        return net:HookEvent(name, fn)
    end)
    if ok and (type(handle) == "function" or typeof(handle) == "RBXScriptConnection") then
        table.insert(hookConns, handle)
    end
end

hook("TreeFalling", function(data)
    pcall(function()
        if not running or not data or not data.Tree then
            return
        end
        fallen[data.Tree] = os.clock() + TREE_COOLDOWN
    end)
end)

hook("TreeRespawning", function(data)
    pcall(function()
        if not running or not data or not data.Tree then
            return
        end
        fallen[data.Tree] = nil
    end)
end)

hook("TaxiJobPathTask", function(data)
    pcall(function()
        if running and type(data) == "table" and type(data.Path) == "table" and typeof(data.SpotCF) == "CFrame" then
            taxiTask = data
            taxiSerial += 1
            taxiSlowUntil = 0
        end
    end)
end)

hook("TaxiSlowDown", function()
    pcall(function()
        if running then
            taxiSlowUntil = os.clock() + 4
        end
    end)
end)

-- Farm loop
local function stopWalking()
    local _, hum, root = getChar()
    if hum and root then
        hum:MoveTo(root.Position)
    end
end

local endingShift = false
local function endShiftNow()
    pcall(function()
        local jobId = JOB_IDS[selectedJob]
        if not isWorkingJob(jobId) then
            return
        end
        task.wait(0.3)
        if selectedJob == "Fast Food Worker - Burger Cook" then
            NC.cook.forceEnd()
            return
        end
        if jobId == CASH_ID then
            cashLeave() -- let go of the register first
        end
        if jobId == ICE_ID or jobId == CASH_ID then
            local _, _, root = getChar()
            if root and iceInsideArea(root.Position) then
                return
            end
        end
        JobHandler:RequestStopWorking()
        task.wait(0.5)
        if isWorkingJob(jobId) then
            JobHandler:StopWorking()
        end
    end)
end

local function endShift()
    if endingShift then
        return
    end
    endingShift = true
    task.spawn(endShiftNow)
    endingShift = false
end

-- Force End Shift (any job). Found live in the game's JobHandler: every job has a client-side area part
-- (JobArea_<job>, the job module's AreaBlock) whose Touched starts the shift (StartWorking) when the character's
-- UpperTorso touches it; when a shift ends the part is put back into the world around the character and starts the
-- shift again right away (live, Pizza Baker: StopWorking -> ended, 0.07 s later started again). RequestStopWorking
-- refuses inside the area. So: the area part stops reacting to touches (CanTouch off, this client only), the game's own
-- StopWorking ends the shift, and the part reacts again once the character has walked out of the area - walking back
-- in starts a shift the normal way. No teleport.
NC.forceEndOn = false
function NC.forceEndRestore()
    local ab = NC.forceEndArea
    NC.forceEndArea = nil
    if ab then
        pcall(function()
            ab.CanTouch = true
        end)
    end
end
function NC.forceEndShift()
    task.spawn(function()
        pcall(function()
            if not JobHandler:IsWorking() then
                return
            end
            local mod = JobHandler:GetCurJobModule()
            local ab = mod and mod.AreaBlock
            NC.forceEndRestore()
            if typeof(ab) == "Instance" and ab:IsA("BasePart") then
                ab.CanTouch = false
                NC.forceEndArea = ab
            end
            -- let go of a station / seat / vehicle first (the game's own detach)
            pcall(function()
                if JobHandler.Shared.AttachService:GetAttachWeld(LocalPlayer.Character) then
                    JobHandler.Modules.CharacterHandler:Detach()
                end
            end)
            for _ = 1, 3 do
                pcall(function()
                    JobHandler:StopWorking()
                end)
                local t0 = os.clock()
                while os.clock() - t0 < 1.5 and JobHandler:IsWorking() do
                    task.wait(0.1)
                end
                if not JobHandler:IsWorking() then
                    break
                end
            end
            if not ab or NC.forceEndArea ~= ab then
                return
            end
            -- the area part reacts again once the character is out of it (re-entering starts a shift as usual)
            while running and NC.forceEndArea == ab do
                local _, _, root = getChar()
                if root and ab.Parent then
                    local rel = ab.CFrame:PointToObjectSpace(root.Position)
                    local half = ab.Size / 2
                    if math.abs(rel.X) > half.X + 3 or math.abs(rel.Y) > half.Y + 3 or math.abs(rel.Z) > half.Z + 3 then
                        NC.forceEndRestore()
                        break
                    end
                end
                task.wait(0.2)
            end
        end)
    end)
end

local function farmStep()
    if not farming then
        task.wait(0.3)
        return
    end
    if not isWorkingWoodcutter() then
        setStatus("Start the Lovely Lumber job first")
        task.wait(1)
        return
    end
    local char, hum, root = getChar()
    if not hum then
        setStatus("Waiting for character")
        task.wait(1)
        return
    end
    local tree = findTree(root.Position)
    if not tree then
        setStatus("No standing trees, waiting")
        task.wait(2)
        return
    end
    setStatus("Walking to tree")
    local origin = tree.Origin.Position
    local away = Vector3.new(root.Position.X - origin.X, 0, root.Position.Z - origin.Z)
    away = away.Magnitude > 0.1 and away.Unit or Vector3.new(0, 0, 1)
    local stand = groundPoint(origin.X + away.X * STAND_DISTANCE, origin.Z + away.Z * STAND_DISTANCE, origin.Y, char)
    local ok, reason = walkTo(stand)
    if ok then
        setStatus("Chopping tree")
        if not chopTree(tree) then
            fallen[tree] = os.clock() + 20
        end
        task.wait(0.2 + math.random() * 0.6)
    elseif farming then
        setStatus(reason == "no path" and "No path to tree, trying another" or "Got stuck, trying another tree")
        fallen[tree] = os.clock() + BAD_TREE_COOLDOWN
        task.wait(1)
    end
end

local function farmLoop()
    while running do
        local ok, err = pcall(selectedJob == JANITOR_NAME and janitorStep or selectedJob == TAXI_NAME and taxiStep
            or selectedJob == ICE_NAME and iceStep or selectedJob == CASH_NAME and cashStep
            or selectedJob == "Fast Food Worker - Burger Cook" and NC.cook.step or selectedJob == PIZZA_NAME and NC.pizza.step
            or selectedJob == TEACHER_NAME and NC.teacher.step or selectedJob == "BFF Supermarket" and NC.market.step
            or selectedJob == "Hairdresser - Stylez Hair Studio" and NC.hair.step
            or selectedJob == "Fisherman - Fishing Hut" and NC.fish.step
            or selectedJob == "Mechanic - Mike's Motors" and NC.mech.step
            or selectedJob == "Stocker - BFF Supermarket" and NC.stock.step or farmStep)
        if not ok then
            warn("[Legit Farm Job] " .. tostring(err))
            setStatus("Error, retrying")
            task.wait(2)
        else
            task.wait() -- every iteration yields at least once
        end
    end
end

-- UI
JobsTab:CreateDropdown({
    Name = "Select Job",
    Options = { JOB_NAME, JANITOR_NAME, TAXI_NAME, ICE_NAME, CASH_NAME, "Fast Food Worker - Burger Cook", PIZZA_NAME, TEACHER_NAME, "BFF Supermarket", "Hairdresser - Stylez Hair Studio", "Fisherman - Fishing Hut", "Mechanic - Mike's Motors", "Stocker - BFF Supermarket" },
    CurrentOption = {},
    MultipleOptions = false,
    Flag = "LFJ_Job",
    Callback = function(option)
        selectedJob = type(option) == "table" and option[1] or option
    end,
})

local teleporting = false

JobsTab:CreateButton({
    Name = "Teleport to Job",
    Callback = function()
        local jobId = JOB_IDS[selectedJob]
        if not jobId then
            Rayfield:Notify({
                Title = "Legit Farm Job [Undetected]",
                Content = "Select a job in the dropdown first.",
                Duration = 4,
            })
            return
        end
        if teleporting then
            return
        end
        local okOngoing, ongoing = pcall(function()
            return JobHandler:HasOngoingJob()
        end)
        if okOngoing and ongoing then
            Rayfield:Notify({
                Title = "Legit Farm Job [Undetected]",
                Content = "End your current shift first.",
                Duration = 4,
            })
            return
        end
        teleporting = true
        task.spawn(function()
            local ok, err = pcall(function()
                return JobHandler:GoToWork(jobId)
            end)
            if not ok then
                warn("[Legit Farm Job] teleport failed: " .. tostring(err))
            end
            teleporting = false
        end)
    end,
})

JobsTab:CreateSection("Farm")

FarmToggle = JobsTab:CreateToggle({
    Name = "Auto Farm",
    CurrentValue = false,
    Flag = "LFJ_Farm",
    Callback = function(value)
        if value and not JOB_IDS[selectedJob] then
            Rayfield:Notify({
                Title = "Legit Farm Job [Undetected]",
                Content = "Select a job in the dropdown first.",
                Duration = 4,
            })
            farming = false
            return
        end
        local wasFarming = farming
        farming = value
        if not value then
            releaseDrive()
            pcall(NC.cook.stop)
            pcall(NC.pizza.stop)
            pcall(NC.teacher.stop)
            pcall(NC.market.stop)
            pcall(NC.hair.stop)
            pcall(NC.fish.stop)
            pcall(NC.mech.stop)
            pcall(NC.stock.stop)
            if selectedJob ~= "Fast Food Worker - Burger Cook" then
                stopWalking()
            end
            setStatus("Idle")
            if wasFarming then
                if NC.forceEndOn then
                    NC.forceEndShift()
                else
                    endShift()
                end
            end
        end
    end,
})

JobsTab:CreateToggle({
    Name = "Force End Shift",
    CurrentValue = false,
    Flag = "LFJ_ForceEndShift",
    Callback = function(value)
        NC.forceEndOn = value
    end,
})

StatusLabel = JobsTab:CreateLabel("Status: Idle")

-- Plot tab
local PlotTab = Window:CreateTab("Plot", "map-pin")
PlotTab:CreateSection("Visit a Plot")

local playerByLabel = {}
local selectedPlayerLabel
local plotConns = {}

local function playerOptions(leaving)
    table.clear(playerByLabel)
    local labels = {}
    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= leaving then
            local label = plr.DisplayName .. " (@" .. plr.Name .. ")"
            playerByLabel[label] = plr
            table.insert(labels, label)
        end
    end
    table.sort(labels, function(a, b)
        return a:lower() < b:lower()
    end)
    return labels
end

local PlayerDropdown = PlotTab:CreateDropdown({
    Name = "Players",
    Options = playerOptions(),
    CurrentOption = {},
    MultipleOptions = false,
    Flag = "LFJ_PlotPlayer",
    Callback = function(option)
        selectedPlayerLabel = type(option) == "table" and option[1] or option
    end,
})

local function refreshPlayers(leaving)
    local labels = playerOptions(leaving)
    withUiIdentity(function()
        PlayerDropdown:Refresh(labels)
        if selectedPlayerLabel and not playerByLabel[selectedPlayerLabel] then
            selectedPlayerLabel = nil -- the selected player left
            PlayerDropdown:Set({})
        end
    end)
end

table.insert(plotConns, Players.PlayerAdded:Connect(function()
    refreshPlayers()
end))
table.insert(plotConns, Players.PlayerRemoving:Connect(function(plr)
    refreshPlayers(plr)
end))

local teleportingPlot = false
PlotTab:CreateButton({
    Name = "Teleport to Plot",
    Callback = function()
        local target = selectedPlayerLabel and playerByLabel[selectedPlayerLabel]
        if not target or target.Parent ~= Players then
            Rayfield:Notify({
                Title = "Legit Farm Job [Undetected]",
                Content = "Select a player in the dropdown first.",
                Duration = 4,
            })
            return
        end
        if teleportingPlot then
            return
        end
        teleportingPlot = true
        task.spawn(function()
            local ok, err = pcall(function()
                return require(PlayerModules:WaitForChild("HouseHandler")):ToPlot(target)
            end)
            if not ok then
                warn("[Legit Farm Job] plot teleport failed: " .. tostring(err))
            end
            teleportingPlot = false
        end)
    end,
})

-- tab order: Jobs, Plot, Mood Station, Auto Store (NC.store.buildUI), Auto Cook, Halloween Event, Troll
NC.store.buildUI()

NC.autocook.buildUI(Window:CreateTab("Auto Cook", "chef-hat"))

local HalloweenTab = Window:CreateTab("Halloween Event", "ghost")
NC.seasonal.buildUI(HalloweenTab)
NC.ghunt.buildUI(HalloweenTab)

NC.troll.buildUI(Window:CreateTab("Troll", "skull"))

-- Theme tab: Rayfield's own Window.ModifyTheme(theme table / name) recolors the open window (background, top bar, tabs,
-- elements, toggles, sliders, dropdowns, text). The window was made without a theme = Rayfield's "Default".
NC.theme = (function()
    local T = {}
    local function themed(over)
        local base = {}
        for k, v in pairs(type(Rayfield.Theme) == "table" and Rayfield.Theme.Default or {}) do
            base[k] = v
        end
        for k, v in pairs(over) do
            base[k] = v
        end
        return base
    end
    local rgb = Color3.fromRGB
    -- one dark, slightly tinted base, quiet outlines, and a single accent for what is on / selected
    -- Christmas: pine base, wine-red top bar, cranberry accent, snow-white selected tab, a thin gold ring on toggles that
    -- are on
    local CHRISTMAS = themed({
        TextColor = rgb(238, 234, 224),
        Background = rgb(12, 26, 20), Topbar = rgb(96, 22, 32), Shadow = rgb(5, 12, 9),
        NotificationBackground = rgb(12, 26, 20), NotificationActionsBackground = rgb(238, 234, 224),
        TabBackground = rgb(20, 40, 31), TabStroke = rgb(36, 62, 49), TabBackgroundSelected = rgb(238, 234, 224),
        TabTextColor = rgb(200, 212, 204), SelectedTabTextColor = rgb(96, 22, 32),
        ElementBackground = rgb(18, 36, 28), ElementBackgroundHover = rgb(23, 44, 35),
        SecondaryElementBackground = rgb(15, 31, 24), ElementStroke = rgb(34, 58, 46), SecondaryElementStroke = rgb(27, 48, 38),
        SliderBackground = rgb(92, 28, 36), SliderProgress = rgb(191, 45, 58), SliderStroke = rgb(214, 76, 88),
        ToggleBackground = rgb(14, 29, 22), ToggleEnabled = rgb(191, 45, 58), ToggleDisabled = rgb(66, 84, 75),
        ToggleEnabledStroke = rgb(214, 76, 88), ToggleDisabledStroke = rgb(86, 104, 95),
        ToggleEnabledOuterStroke = rgb(196, 164, 98), ToggleDisabledOuterStroke = rgb(36, 60, 48),
        DropdownSelected = rgb(28, 54, 42), DropdownUnselected = rgb(18, 36, 28),
        InputBackground = rgb(14, 29, 22), InputStroke = rgb(40, 66, 53), PlaceholderColor = rgb(140, 156, 147),
    })
    -- Halloween: ash-black base, burnt-pumpkin top bar, pumpkin accent, a dim violet ring on toggles that are on
    local HALLOWEEN = themed({
        TextColor = rgb(236, 226, 212),
        Background = rgb(16, 14, 17), Topbar = rgb(64, 30, 10), Shadow = rgb(7, 6, 8),
        NotificationBackground = rgb(16, 14, 17), NotificationActionsBackground = rgb(240, 126, 36),
        TabBackground = rgb(26, 22, 28), TabStroke = rgb(40, 34, 43), TabBackgroundSelected = rgb(240, 126, 36),
        TabTextColor = rgb(196, 186, 178), SelectedTabTextColor = rgb(28, 16, 6),
        ElementBackground = rgb(24, 21, 26), ElementBackgroundHover = rgb(30, 26, 33),
        SecondaryElementBackground = rgb(19, 17, 21), ElementStroke = rgb(39, 33, 43), SecondaryElementStroke = rgb(31, 27, 35),
        SliderBackground = rgb(98, 48, 16), SliderProgress = rgb(240, 126, 36), SliderStroke = rgb(255, 158, 72),
        ToggleBackground = rgb(18, 16, 20), ToggleEnabled = rgb(240, 126, 36), ToggleDisabled = rgb(72, 66, 78),
        ToggleEnabledStroke = rgb(255, 158, 72), ToggleDisabledStroke = rgb(92, 85, 99),
        ToggleEnabledOuterStroke = rgb(112, 74, 140), ToggleDisabledOuterStroke = rgb(40, 35, 45),
        DropdownSelected = rgb(36, 30, 40), DropdownUnselected = rgb(24, 21, 26),
        InputBackground = rgb(18, 16, 20), InputStroke = rgb(46, 39, 51), PlaceholderColor = rgb(150, 140, 150),
    })

    -- Rayfield's ChangeTheme leaves some parts in the old colours (found in its source): the tab buttons (only coloured
    -- when made / clicked), sliders, dropdown option rows, and it gives labels the element colour instead of the label
    -- colour. Those are repainted here with the same theme keys Rayfield uses for them.
    local current = type(Rayfield.Theme) == "table" and Rayfield.Theme.Default or nil
    local function repaint(th, prev)
        local rf
        for _, root in ipairs({ gethui and gethui() or game:GetService("CoreGui"), game:GetService("CoreGui") }) do
            rf = rf or root:FindFirstChild("Rayfield")
        end
        local main = rf and rf:FindFirstChild("Main")
        if not (main and main:FindFirstChild("Elements") and main:FindFirstChild("TabList")) then
            return
        end
        local isDefault = type(Rayfield.Theme) == "table" and th == Rayfield.Theme.Default
        local page = main.Elements:FindFirstChildOfClass("UIPageLayout")
        local cur = page and page.CurrentPage
        for _, b in ipairs(main.TabList:GetChildren()) do
            if b:IsA("Frame") and b.Name ~= "Template" and b:FindFirstChild("Title") then
                local sel = cur ~= nil and cur.Name == b.Name
                b.BackgroundColor3 = sel and th.TabBackgroundSelected or th.TabBackground
                b.Title.TextColor3 = sel and th.SelectedTabTextColor or th.TabTextColor
                if b:FindFirstChild("Image") then
                    b.Image.ImageColor3 = sel and th.SelectedTabTextColor or th.TabTextColor
                end
                if b:FindFirstChild("UIStroke") then
                    b.UIStroke.Color = th.TabStroke
                end
            end
        end
        for _, pg in ipairs(main.Elements:GetChildren()) do
            for _, el in ipairs(pg:GetChildren()) do
                if el:IsA("Frame") then
                    if el.Name == "Label" and el:FindFirstChild("UIStroke") then
                        el.BackgroundColor3 = th.SecondaryElementBackground
                        el.UIStroke.Color = th.SecondaryElementStroke
                    end
                    local m = el:FindFirstChild("Main")
                    if m and m:FindFirstChild("Progress") then
                        m.BackgroundColor3 = th.SliderBackground
                        if m:FindFirstChild("UIStroke") then
                            m.UIStroke.Color = th.SliderStroke
                        end
                        m.Progress.BackgroundColor3 = th.SliderProgress
                        if m.Progress:FindFirstChild("UIStroke") then
                            m.Progress.UIStroke.Color = th.SliderStroke
                        end
                        if m:FindFirstChild("Shadow") then
                            m.Shadow.Visible = isDefault
                        end
                    end
                    local sw = el:FindFirstChild("Switch")
                    if sw and sw:FindFirstChild("Shadow") and isDefault then
                        sw.Shadow.Visible = true
                    end
                    local list = el:FindFirstChild("List")
                    if list then
                        for _, o in ipairs(list:GetChildren()) do
                            if o:IsA("Frame") and o.Name ~= "Template" and o.Name ~= "Placeholder" then
                                local wasSel = prev ~= nil and o.BackgroundColor3 == prev.DropdownSelected
                                o.BackgroundColor3 = wasSel and th.DropdownSelected or th.DropdownUnselected
                            end
                        end
                    end
                end
            end
        end
    end

    local function apply(theme)
        withUiIdentity(function()
            local th = type(theme) == "table" and theme or (type(Rayfield.Theme) == "table" and Rayfield.Theme[theme])
            Window.ModifyTheme(theme)
            if th then
                local prev = current
                current = th
                task.delay(0.1, function()
                    withUiIdentity(function()
                        repaint(th, prev)
                    end)
                end)
            end
        end)
    end

    function T.buildUI(tab)
        tab:CreateSection("Theme")
        tab:CreateButton({
            Name = "Christmas Theme",
            Callback = function()
                apply(CHRISTMAS)
            end,
        })
        tab:CreateButton({
            Name = "Halloween Theme",
            Callback = function()
                apply(HALLOWEEN)
            end,
        })
        tab:CreateButton({
            Name = "Revert to Original Theme",
            Callback = function()
                apply("Default")
            end,
        })
    end

    return T
end)()
NC.theme.buildUI(Window:CreateTab("Theme", "palette"))

-- Anti AFK
NC.afk = (function()
    local A = {}
    local conn
    function A.stop()
        if conn then
            pcall(function()
                conn:Disconnect()
            end)
            conn = nil
        end
    end
    local bb = game:GetService("VirtualUser")
    conn = LocalPlayer.Idled:Connect(function()
        bb:CaptureController()
        bb:ClickButton2(Vector2.new())
    end)
    return A
end)()

-- On the ground at every job: found live, the game's teleport to a job (GoToWork) puts the character on the job's
-- WorkTeleport_<job> part (Environment.Locations..., 4 x 0.2 x 4, Transparency 1 but CanCollide true) lying on the floor,
-- so the character stood 0.29 studs above the floor (Pizza Baker) until it walked off. Those parts stop colliding on this
-- client only (they are invisible and only mark the teleport spot); new ones that stream in get the same.
NC.pads = (function()
    local P = {}
    local changed, conn = {}, nil
    local function fix(d)
        if d:IsA("BasePart") and d.CanCollide and d.Name:sub(1, 13) == "WorkTeleport_" then
            d.CanCollide = false
            changed[d] = true
        end
    end
    pcall(function()
        local env = workspace:WaitForChild("Environment", 10)
        for _, d in ipairs(env:GetDescendants()) do
            fix(d)
        end
        conn = env.DescendantAdded:Connect(fix)
    end)
    function P.stop()
        if conn then
            conn:Disconnect()
            conn = nil
        end
        for d in pairs(changed) do
            pcall(function()
                d.CanCollide = true
            end)
        end
        table.clear(changed)
    end
    return P
end)()

-- Cleanup
getgenv().LegitFarmJob = function()
    local wasFarming = farming
    farming = false
    releaseDrive()
    if selectedJob ~= "Fast Food Worker - Burger Cook" then
        stopWalking()
    end
    if wasFarming then
        endShiftNow()
    end
    running = false
    pcall(NC.cook.stop)
    pcall(NC.pizza.stop)
    pcall(NC.teacher.stop)
    pcall(NC.market.stop)
    pcall(NC.hair.stop)
    pcall(NC.fish.stop)
    pcall(NC.mech.stop)
    pcall(NC.stock.stop)
    pcall(NC.ghost.stop)
    pcall(NC.seasonal.shutdown)
    pcall(NC.ghunt.shutdown)
    pcall(NC.troll.shutdown)
    pcall(NC.autocook.shutdown)
    pcall(NC.mood.shutdown)
    pcall(NC.store.shutdown)
    pcall(NC.shared.shutdown)
    pcall(NC.afk.stop)
    pcall(NC.forceEndRestore)
    pcall(NC.pads.stop)
    for _, conn in ipairs(plotConns) do
        pcall(function()
            conn:Disconnect()
        end)
    end
    if selectedJob ~= "Fast Food Worker - Burger Cook" then
        stopWalking()
    end
    for _, handle in ipairs(hookConns) do
        pcall(function()
            if type(handle) == "function" then
                handle()
            else
                handle:Disconnect()
            end
        end)
    end
    table.clear(hookConns)
    if farmThread and coroutine.status(farmThread) ~= "dead" and farmThread ~= coroutine.running() then
        pcall(task.cancel, farmThread)
    end
    table.clear(treeCache)
    table.clear(fallen)
    pcall(function()
        Rayfield:Destroy()
    end)
    getgenv().LegitFarmJob = nil
end
farmThread = task.spawn(farmLoop)
