--[[
	Arsenic | Tha Bronx 3
	UI: Rayfield Gen2 (https://docs.sirius.menu/rayfield-gen2)
]]

local genv = (getgenv and getgenv()) or _G
if genv.ArsenicTB3 and genv.ArsenicTB3.Destroy then
	pcall(genv.ArsenicTB3.Destroy)
end

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ProximityPromptService = game:GetService("ProximityPromptService")
local MarketplaceService = game:GetService("MarketplaceService")

local LocalPlayer = Players.LocalPlayer
-- The game keeps its state (Wokeness, Sleeping, ...) in its own `shared`, not the executor's.
local gameShared = (getrenv and getrenv().shared) or shared

local Arsenic = {
	Enabled = {},
	Connections = {},
	Cleanup = {},
	Destroyed = false,
}
genv.ArsenicTB3 = Arsenic

local Window = nil

local function track(connection)
	table.insert(Arsenic.Connections, connection)
	return connection
end

local function on(feature)
	return Arsenic.Enabled[feature] == true and not Arsenic.Destroyed
end

local function getCharacter()
	return LocalPlayer.Character
end

local function getHumanoid()
	local character = LocalPlayer.Character
	return character and character:FindFirstChildOfClass("Humanoid")
end

local function getRoot()
	local character = LocalPlayer.Character
	return character and character:FindFirstChild("HumanoidRootPart")
end

local function getWorldPosition(instance)
	if not instance then
		return nil
	elseif instance:IsA("BasePart") then
		return instance.Position
	elseif instance:IsA("Attachment") then
		return instance.WorldPosition
	elseif instance:IsA("Model") then
		return instance:GetPivot().Position
	end
	return nil
end

--------------------------------------------------------------------------------
-- Game script suppression (disabled LocalScripts stop their loops/connections,
-- re-enabling them restarts them from scratch)
--------------------------------------------------------------------------------

local suppressedScripts = setmetatable({}, { __mode = "k" })

local function suppressScript(scriptInstance, feature)
	if not scriptInstance or not scriptInstance.Parent or suppressedScripts[scriptInstance] then
		return
	end
	local ok = pcall(function()
		scriptInstance.Enabled = false
	end)
	if not ok then
		pcall(function()
			scriptInstance.Disabled = true
		end)
	end
	suppressedScripts[scriptInstance] = feature
end

local function restoreScripts(feature)
	for scriptInstance, owner in pairs(suppressedScripts) do
		if owner == feature then
			suppressedScripts[scriptInstance] = nil
			if scriptInstance.Parent then
				local ok = pcall(function()
					scriptInstance.Enabled = true
				end)
				if not ok then
					pcall(function()
						scriptInstance.Disabled = false
					end)
				end
			end
		end
	end
end

local function findPlayerGuiScript(guiName, scriptName)
	local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
	local gui = playerGui and playerGui:FindFirstChild(guiName)
	return gui and gui:FindFirstChild(scriptName, true)
end

local function fillBar(barScript)
	local bar = barScript and barScript.Parent
	if bar and bar:IsA("GuiObject") then
		bar.Size = UDim2.new(1, 0, 1, 0)
	end
end

--------------------------------------------------------------------------------
-- Remote blocking
--------------------------------------------------------------------------------

-- Until this time a teleport is in progress or just ended (see protectTravel).
local travelSafetyUntil = 0

local remoteBlocks = {
	TravelSafety = function(remote, method)
		local parent = remote.Parent
		return os.clock() < travelSafetyUntil and method == "FireServer" and remote.Name == "Damage" and parent ~= nil and parent.Name == "FallDamageRagdoll"
	end,
	NoHunger = function(remote, method)
		return on("NoHunger") and method == "InvokeServer" and remote.Name == "DamagePlayer" and remote.Parent == ReplicatedStorage
	end,
	NoFallDamage = function(remote, method)
		local parent = remote.Parent
		return on("NoFallDamage") and method == "FireServer" and remote.Name == "Damage" and parent ~= nil and parent.Name == "FallDamageRagdoll"
	end,
	AntiLoseItems = function(remote, method)
		return on("AntiLoseItems") and method == "FireServer" and remote.Name == "Died" and remote.Parent == ReplicatedStorage
	end,
}

-- Set by the Buy section; returns true when it takes over a store purchase.
local storeRedirect = nil

local hookInstalled = false
do
	local wrap = newcclosure or function(fn)
		return fn
	end
	if hookmetamethod and getnamecallmethod then
		local ok = pcall(function()
			local oldNamecall
			oldNamecall = hookmetamethod(game, "__namecall", wrap(function(self, ...)
				if not Arsenic.Destroyed and typeof(self) == "Instance" then
					local method = getnamecallmethod()
					if self == LocalPlayer and (method == "Kick" or method == "kick") and on("AntiKick") then
						return nil
					end
					if method == "FireServer" or method == "InvokeServer" then
						for _, shouldBlock in pairs(remoteBlocks) do
							if shouldBlock(self, method) then
								return nil
							end
						end
						if method == "InvokeServer" and storeRedirect and storeRedirect(self, ...) then
							return nil
						end
					end
				end
				return oldNamecall(self, ...)
			end))
		end)
		hookInstalled = ok
	end
	-- Kicks are only blockable when the client itself calls Kick; server kicks still go through.
	if hookfunction then
		pcall(function()
			local oldKick
			oldKick = hookfunction(LocalPlayer.Kick, wrap(function(self, ...)
				if self == LocalPlayer and not Arsenic.Destroyed and on("AntiKick") then
					return nil
				end
				return oldKick(self, ...)
			end))
		end)
	end
end

--------------------------------------------------------------------------------
-- Features
--------------------------------------------------------------------------------

local Features = {}

-- Noclip -----------------------------------------------------------------------

local noclipParts = setmetatable({}, { __mode = "k" })
-- True while teleportCharacter is gliding the character; forces noclip on for the trip.
local travelling = false

local groundParams = RaycastParams.new()
groundParams.FilterType = Enum.RaycastFilterType.Exclude
groundParams.IgnoreWater = true
pcall(function()
	groundParams.RespectCanCollide = true
end)

local function getStandHeight(humanoid, root)
	if humanoid.RigType == Enum.HumanoidRigType.R6 then
		return 2 + root.Size.Y / 2
	end
	return humanoid.HipHeight + root.Size.Y / 2
end

Features.Noclip = {
	disable = function()
		for part in pairs(noclipParts) do
			if part.Parent then
				part.CanCollide = true
			end
		end
		table.clear(noclipParts)
	end,
}

track(RunService.Stepped:Connect(function()
	if not (on("Noclip") or travelling) then
		return
	end
	local character = getCharacter()
	if not character then
		return
	end
	for _, part in ipairs(character:GetChildren()) do
		if part:IsA("BasePart") and part.CanCollide then
			noclipParts[part] = true
			part.CanCollide = false
		end
	end
end))

track(RunService.Heartbeat:Connect(function()
	if not on("Noclip") or travelling then
		return
	end
	local character, humanoid, root = getCharacter(), getHumanoid(), getRoot()
	if not (character and humanoid and root) or humanoid.SeatPart or humanoid.Health <= 0 or root.Anchored then
		return
	end

	groundParams.FilterDescendantsInstances = { character }
	local standHeight = getStandHeight(humanoid, root)
	local origin = root.Position + Vector3.new(0, 1.5, 0)
	local result = Workspace:Raycast(origin, Vector3.new(0, -(standHeight + 6.5), 0), groundParams)
	if not result then
		return
	end

	local targetY = result.Position.Y + standHeight
	local offset = targetY - root.Position.Y
	if offset > 0.05 then
		root.CFrame = root.CFrame + Vector3.new(0, offset, 0)
		local velocity = root.AssemblyLinearVelocity
		if velocity.Y < 0 then
			root.AssemblyLinearVelocity = Vector3.new(velocity.X, 0, velocity.Z)
		end
	end
end))

-- Fast Respawn / Respawn Where You Died / Anti Lose Items ----------------------

local lastDeath = nil
local respawnLoopRunning = false

local function startFastRespawn(character)
	if respawnLoopRunning then
		return
	end
	respawnLoopRunning = true
	task.spawn(function()
		task.wait(1.1)
		while on("FastRespawn") and LocalPlayer.Character == character do
			local loadCharacter = ReplicatedStorage:FindFirstChild("LoadCharacter")
			if loadCharacter then
				loadCharacter:FireServer()
			end
			task.wait(1.5)
		end
		respawnLoopRunning = false
	end)
end

Features.FastRespawn = {
	enable = function()
		local character, humanoid = getCharacter(), getHumanoid()
		if character and humanoid and humanoid.Health <= 0 then
			startFastRespawn(character)
		end
	end,
}

local function uprightAt(position, lookVector)
	local flat = Vector3.new(lookVector.X, 0, lookVector.Z)
	if flat.Magnitude < 1e-3 then
		return CFrame.new(position)
	end
	return CFrame.lookAt(position, position + flat.Unit)
end

local function onDied(character, humanoid)
	local root = character:FindFirstChild("HumanoidRootPart")
	if root and root.Position.Y > Workspace.FallenPartsDestroyHeight + 25 then
		lastDeath = {
			cframe = uprightAt(root.Position + Vector3.new(0, 3, 0), root.CFrame.LookVector),
			time = os.clock(),
		}
	end
	if on("AntiLoseItems") then
		pcall(function()
			humanoid:UnequipTools()
		end)
	end
	if on("FastRespawn") then
		startFastRespawn(character)
	end
end

-- Unlock All Cars --------------------------------------------------------------

local function forceSit(seat)
	local humanoid, root = getHumanoid(), getRoot()
	if not (humanoid and root) or humanoid.Health <= 0 or humanoid.SeatPart or seat.Occupant then
		return
	end
	if (seat.Position - root.Position).Magnitude > 20 then
		return
	end

	local wasDisabled = seat.Disabled
	seat.Disabled = false
	pcall(function()
		seat:Sit(humanoid)
	end)
	task.wait(0.25)
	if not humanoid.SeatPart then
		root.CFrame = seat.CFrame + Vector3.new(0, 2, 0)
		pcall(function()
			seat:Sit(humanoid)
		end)
		task.wait(0.25)
	end
	if seat.Parent and humanoid.SeatPart ~= seat then
		seat.Disabled = wasDisabled
	end
end

track(ProximityPromptService.PromptTriggered:Connect(function(prompt, player)
	if player ~= LocalPlayer or not on("UnlockAllCars") then
		return
	end
	local civCars = Workspace:FindFirstChild("CivCars")
	local seat = prompt.Parent
	if not (civCars and prompt:IsDescendantOf(civCars)) then
		return
	end
	if not (seat and (seat:IsA("VehicleSeat") or seat:IsA("Seat"))) then
		return
	end
	task.delay(0.4, function()
		if on("UnlockAllCars") and seat.Parent then
			forceSit(seat)
		end
	end)
end))

local function enableCarPrompts()
	local humanoid = getHumanoid()
	local civCars = Workspace:FindFirstChild("CivCars")
	if not civCars or (humanoid and humanoid.SeatPart) then
		return
	end
	for _, car in ipairs(civCars:GetChildren()) do
		for _, descendant in ipairs(car:GetDescendants()) do
			if descendant:IsA("ProximityPrompt") and not descendant.Enabled then
				local seat = descendant.Parent
				if seat and (seat:IsA("VehicleSeat") or seat:IsA("Seat")) then
					descendant.Enabled = true
				end
			end
		end
	end
end

-- Instant Interact -------------------------------------------------------------

local promptHoldDurations = setmetatable({}, { __mode = "k" })

local function makeInstant(prompt)
	if prompt.HoldDuration > 0 then
		if promptHoldDurations[prompt] == nil then
			promptHoldDurations[prompt] = prompt.HoldDuration
		end
		prompt.HoldDuration = 0
	end
end

track(ProximityPromptService.PromptShown:Connect(function(prompt)
	if on("InstantInteract") then
		makeInstant(prompt)
	end
end))

track(ProximityPromptService.PromptButtonHoldBegan:Connect(function(prompt)
	if on("InstantInteract") then
		makeInstant(prompt)
	end
end))

Features.InstantInteract = {
	disable = function()
		for prompt, duration in pairs(promptHoldDurations) do
			if prompt.Parent then
				prompt.HoldDuration = duration
			end
		end
		table.clear(promptHoldDurations)
	end,
}

-- Auto Pickup Bags -------------------------------------------------------------

local pickupCooldowns = setmetatable({}, { __mode = "k" })
local pickupCandidates = setmetatable({}, { __mode = "k" })

local function isPickupName(name)
	name = name:lower()
	return name:find("bag") or name:find("money") or name:find("cash") or name:find("dolla")
end

track(Workspace.ChildAdded:Connect(function(child)
	if not isPickupName(child.Name) then
		return
	end
	if Players:GetPlayerFromCharacter(child) or child:FindFirstChildOfClass("Humanoid") then
		return
	end
	pickupCandidates[child] = true
end))

local function firePrompt(prompt, forceInstant)
	if not prompt then
		return
	end
	local hold = tonumber(prompt.HoldDuration) or 0
	local savedHold = hold
	if forceInstant and hold > 0 then
		prompt.HoldDuration = 0
		hold = 0
	end
	if fireproximityprompt then
		-- Most executors accept (prompt) or (prompt, duration). Prefer one clean call.
		if hold > 0 then
			local ok = pcall(fireproximityprompt, prompt, hold)
			if not ok then
				pcall(fireproximityprompt, prompt)
			end
		else
			pcall(fireproximityprompt, prompt)
		end
	else
		prompt:InputHoldBegin()
		if hold > 0 then
			task.wait(hold + 0.05)
		else
			task.wait()
		end
		prompt:InputHoldEnd()
	end
	if forceInstant and prompt.Parent then
		prompt.HoldDuration = savedHold
	end
end

local function unequipTools()
	local humanoid, character = getHumanoid(), getCharacter()
	if humanoid then
		pcall(function()
			humanoid:UnequipTools()
		end)
	end
	local backpack = LocalPlayer:FindFirstChild("Backpack")
	if character and backpack then
		for _, child in ipairs(character:GetChildren()) do
			if child:IsA("Tool") then
				child.Parent = backpack
			end
		end
	end
end

local function tryPickup(root, instance)
	local now = os.clock()
	if (pickupCooldowns[instance] or 0) > now then
		return
	end

	if instance:IsA("ProximityPrompt") then
		local position = getWorldPosition(instance.Parent)
		if instance.Enabled and position and (position - root.Position).Magnitude <= instance.MaxActivationDistance then
			pickupCooldowns[instance] = now + 0.75
			firePrompt(instance)
		end
	elseif instance:IsA("ClickDetector") then
		local position = getWorldPosition(instance.Parent)
		if fireclickdetector and position and (position - root.Position).Magnitude <= instance.MaxActivationDistance then
			pickupCooldowns[instance] = now + 0.75
			pcall(fireclickdetector, instance)
		end
	elseif instance:IsA("TouchTransmitter") then
		local part = instance.Parent
		if firetouchinterest and part and part:IsA("BasePart") and (part.Position - root.Position).Magnitude <= 15 then
			pickupCooldowns[instance] = now + 0.75
			pcall(firetouchinterest, root, part, 0)
			pcall(firetouchinterest, root, part, 1)
		end
	end
end

local function scanPickups()
	local root, humanoid = getRoot(), getHumanoid()
	if not (root and humanoid) or humanoid.Health <= 0 then
		return
	end

	local dollas = Workspace:FindFirstChild("Dollas")
	if dollas then
		for _, descendant in ipairs(dollas:GetDescendants()) do
			tryPickup(root, descendant)
		end
	end

	for candidate in pairs(pickupCandidates) do
		if candidate.Parent then
			tryPickup(root, candidate)
			for _, descendant in ipairs(candidate:GetDescendants()) do
				tryPickup(root, descendant)
			end
		else
			pickupCandidates[candidate] = nil
		end
	end
end

-- No Knockback -----------------------------------------------------------------

local KNOCKBACK_MOVERS = {
	"BodyVelocity",
	"BodyPosition",
	"BodyThrust",
	"BodyForce",
	"BodyAngularVelocity",
	"LinearVelocity",
	"VectorForce",
	"AlignPosition",
}

local function isKnockbackMover(instance)
	for _, className in ipairs(KNOCKBACK_MOVERS) do
		if instance:IsA(className) then
			local name = instance.Name:lower()
			return not (name:find("adonis") or name:find("gun"))
		end
	end
	return false
end

track(RunService.Heartbeat:Connect(function()
	if not on("NoKnockback") then
		return
	end
	local humanoid, root = getHumanoid(), getRoot()
	if not (humanoid and root) or humanoid.SeatPart or humanoid.Health <= 0 or root.Anchored then
		return
	end

	local velocity = root.AssemblyLinearVelocity
	local horizontal = Vector3.new(velocity.X, 0, velocity.Z)
	local limit = math.max(humanoid.WalkSpeed, 16) * 1.6
	if horizontal.Magnitude > limit or velocity.Y > 75 then
		local desired = humanoid.MoveDirection * humanoid.WalkSpeed
		root.AssemblyLinearVelocity = Vector3.new(desired.X, math.min(velocity.Y, 50), desired.Z)
	end
	if root.AssemblyAngularVelocity.Magnitude > 15 then
		root.AssemblyAngularVelocity = Vector3.zero
	end
end))

track(RunService.Stepped:Connect(function()
	if not on("NoKnockback") then
		return
	end
	for _, player in ipairs(Players:GetPlayers()) do
		local character = player ~= LocalPlayer and player.Character
		local theirRoot = character and character:FindFirstChild("HumanoidRootPart")
		if theirRoot and (theirRoot.AssemblyAngularVelocity.Magnitude > 40 or theirRoot.AssemblyLinearVelocity.Magnitude > 120) then
			for _, part in ipairs(character:GetDescendants()) do
				if part:IsA("BasePart") then
					part.CanCollide = false
				end
			end
		end
	end
end))

-- Disable Camera Bobbing -------------------------------------------------------

local function resetCameraOffset()
	local humanoid = getHumanoid()
	if humanoid and humanoid.CameraOffset.Magnitude < 1.6 then
		humanoid.CameraOffset = Vector3.zero
	end
end

Features.NoCameraBob = {
	disable = function()
		restoreScripts("NoCameraBob")
	end,
}

-- Script-backed toggles --------------------------------------------------------

Features.NoHunger = {
	disable = function()
		restoreScripts("NoHunger")
	end,
}

Features.InfiniteStamina = {
	disable = function()
		restoreScripts("InfiniteStamina")
	end,
}

Features.NoFallDamage = {
	disable = function()
		restoreScripts("NoFallDamage")
	end,
}

--------------------------------------------------------------------------------
-- Shared helpers for tools / players
--------------------------------------------------------------------------------

local function notify(content)
	if Window then
		pcall(function()
			Window:Notify({ title = "Arsenic", content = content })
		end)
	end
end

local function findTools(predicate)
	local found = {}
	local containers = { getCharacter(), LocalPlayer:FindFirstChildOfClass("Backpack") }
	for index = 1, 2 do
		local container = containers[index]
		if container then
			for _, child in ipairs(container:GetChildren()) do
				if child:IsA("Tool") and predicate(child) then
					table.insert(found, child)
				end
			end
		end
	end
	return found
end

local function exitSeat(humanoid)
	if not humanoid.SeatPart then
		return
	end
	humanoid.Sit = false
	humanoid.Jump = true
	local deadline = os.clock() + 1
	while humanoid.SeatPart and os.clock() < deadline do
		task.wait()
	end
end

Arsenic.Values = Arsenic.Values or {}
Arsenic.Values.TeleportSpeed = 2000
Arsenic.Values.TweenAfterCar = 150
local teleportMethod = "Vehicle"
local teleportSpeedSlider = nil

-- The server kicks for "Flying" when airborne too long and reverts single huge jumps,
-- so trips are short, fast glides hugging the ground: accelerate over TELEPORT_RAMP
-- seconds to TeleportSpeed.
local MIN_TELEPORT_SPEED = 250
local TELEPORT_START_SPEED = 600
local TELEPORT_RAMP = 0.08
local MAX_TRAVEL_FLAGS = 5
local MAX_FOOT_TRIP_SECONDS = 20
local MAX_CAR_TRIP_SECONDS = 12
-- Long car trips speed up past CarTeleportSpeed so they never take longer than this.
local CAR_TRIP_SECONDS = 3
-- Within this horizontal distance of the goal, stop hugging the ground and go straight in.
local GROUND_FOLLOW_CUTOFF = 25

local travelRayParams = RaycastParams.new()
travelRayParams.FilterType = Enum.RaycastFilterType.Exclude
travelRayParams.IgnoreWater = true
pcall(function()
	travelRayParams.RespectCanCollide = true
end)

local DEEP_GROUND_RAY = 600
local deepRayParams = RaycastParams.new()
deepRayParams.FilterType = Enum.RaycastFilterType.Exclude
deepRayParams.IgnoreWater = false
pcall(function()
	deepRayParams.RespectCanCollide = true
end)

local function findGroundY(position, extraIgnore)
	local ignore = { Workspace.CurrentCamera }
	if extraIgnore then
		if typeof(extraIgnore) == "Instance" then
			table.insert(ignore, extraIgnore)
		else
			for _, inst in ipairs(extraIgnore) do
				table.insert(ignore, inst)
			end
		end
	end
	for _, player in ipairs(Players:GetPlayers()) do
		if player.Character then
			table.insert(ignore, player.Character)
		end
	end
	travelRayParams.FilterDescendantsInstances = ignore
	local result = Workspace:Raycast(position + Vector3.new(0, 6, 0), Vector3.new(0, -60, 0), travelRayParams)
	if result then
		return result.Position.Y
	end
	-- Over rivers and gaps: look much further down and count the water surface, otherwise the
	-- glide keeps its height there and the server kicks for flying.
	deepRayParams.FilterDescendantsInstances = ignore
	result = Workspace:Raycast(position + Vector3.new(0, 6, 0), Vector3.new(0, -DEEP_GROUND_RAY, 0), deepRayParams)
	return result and result.Position.Y or nil
end

-- Bumped whenever the game shows its "Teleported for Teleportation" notice.
local teleportFlagCount = 0
-- Latest on-screen game message (e.g. "Already using another!"), lowercased.
local gameMessage = { text = "", time = 0 }
-- os.clock() time when the game next lets us steal a car, from its "Must wait 4m 1s before stealing again!".
-- Kept in genv so re-running the script remembers it.
local stealReadyAt = genv.ArsenicStealReadyAt or 0

local function readStealCooldown(text)
	local wait = text:match("must wait (.-) before stealing")
	if not wait then
		return
	end
	local minutes = tonumber(wait:match("(%d+)%s*m")) or 0
	local seconds = tonumber(wait:match("(%d+)%s*s")) or 0
	stealReadyAt = math.max(stealReadyAt, os.clock() + minutes * 60 + seconds + 1)
	genv.ArsenicStealReadyAt = stealReadyAt
end

local function watchFlagLabel(label)
	if not (label:IsA("TextLabel") and label.Name == "TextLabel") then
		return
	end
	local function check()
		local text = label.Text:lower()
		if text:find("teleported for", 1, true) then
			teleportFlagCount = teleportFlagCount + 1
		end
		if text ~= "" then
			readStealCooldown(text)
			gameMessage.text = text
			gameMessage.time = os.clock()
		end
	end
	track(label:GetPropertyChangedSignal("Text"):Connect(check))
	check()
end

task.spawn(function()
	if not LocalPlayer then
		return
	end
	local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui") or LocalPlayer:WaitForChild("PlayerGui", 30)
	if not playerGui or Arsenic.Destroyed then
		return
	end
	for _, descendant in ipairs(playerGui:GetDescendants()) do
		watchFlagLabel(descendant)
	end
	track(playerGui.DescendantAdded:Connect(watchFlagLabel))
end)

local function slowDownAfterFlag()
	local slower = math.max(math.floor(Arsenic.Values.TeleportSpeed * 0.85), MIN_TELEPORT_SPEED)
	Arsenic.Values.TeleportSpeed = slower
	if teleportSpeedSlider then
		pcall(function()
			teleportSpeedSlider:Set(slower, true)
		end)
	end
	return slower
end

local VEHICLE_FOLDERS = { CivCars = true, WorkTrucks = true, PoliceCars = true }

local function getVehicleModel(seat)
	local node = seat
	while node and node.Parent do
		if node.Parent.Parent == Workspace and VEHICLE_FOLDERS[node.Parent.Name] then
			return node
		end
		node = node.Parent
	end
	return nil
end

-- Seated vehicles are not checked by the anti-teleport, so cars travel at their own speed.
Arsenic.Values.CarTeleportSpeed = 3000
local vehicleTeleport = nil
local inVehicleTrip = false

-- The game's FallDamageRagdoll script reports damage from the downward speed on any state change,
-- so leaving a fast car or being pushed out of a wall right after a trip can count as a fatal fall.
-- While a trip runs (and briefly after) that script is paused, its report is blocked, and
-- falls/flings outside a seat are slowed down.
local TRAVEL_SAFETY_GRACE = 3
local SAFE_FALL_SPEED = 40
local MAX_SAFE_SPEED = 150
local travelSafetyDepth = 0
local travelSafetyConnection = nil

-- Below the destroy height the game deletes the character, which looks like vanishing and respawning.
local VOID_MARGIN = 75
local lastSafeCFrame = nil

local function guardVelocity()
	local humanoid, root = getHumanoid(), getRoot()
	if not (humanoid and root) or humanoid.Health <= 0 then
		return
	end
	if root.Position.Y < Workspace.FallenPartsDestroyHeight + VOID_MARGIN then
		if lastSafeCFrame then
			if humanoid.SeatPart then
				exitSeat(humanoid)
			end
			root.AssemblyLinearVelocity = Vector3.zero
			root.AssemblyAngularVelocity = Vector3.zero
			root.CFrame = lastSafeCFrame
		end
		return
	end
	if humanoid.SeatPart then
		return
	end
	if humanoid.FloorMaterial ~= Enum.Material.Air then
		lastSafeCFrame = root.CFrame
	end
	local velocity = root.AssemblyLinearVelocity
	if velocity.Magnitude > MAX_SAFE_SPEED then
		root.AssemblyLinearVelocity = Vector3.zero
		root.AssemblyAngularVelocity = Vector3.zero
	elseif velocity.Y < -SAFE_FALL_SPEED then
		root.AssemblyLinearVelocity = Vector3.new(velocity.X, -SAFE_FALL_SPEED, velocity.Z)
	end
end

local function beginTravelSafety()
	travelSafetyDepth += 1
	travelSafetyUntil = math.huge
	local root = getRoot()
	if travelSafetyDepth == 1 and root then
		lastSafeCFrame = root.CFrame
	end
	local character = getCharacter()
	if character then
		suppressScript(character:FindFirstChild("FallDamageRagdoll"), "TravelSafety")
	end
	if not travelSafetyConnection then
		travelSafetyConnection = RunService.Heartbeat:Connect(guardVelocity)
	end
end

local function endTravelSafety()
	travelSafetyDepth = math.max(travelSafetyDepth - 1, 0)
	if travelSafetyDepth > 0 then
		return
	end
	local expires = os.clock() + TRAVEL_SAFETY_GRACE
	travelSafetyUntil = expires
	task.delay(TRAVEL_SAFETY_GRACE, function()
		if travelSafetyUntil ~= expires or travelSafetyDepth > 0 then
			return
		end
		if travelSafetyConnection then
			travelSafetyConnection:Disconnect()
			travelSafetyConnection = nil
		end
		restoreScripts("TravelSafety")
	end)
end

local function protectTravel(fn, ...)
	beginTravelSafety()
	local results = table.pack(pcall(fn, ...))
	endTravelSafety()
	if not results[1] then
		error(results[2], 0)
	end
	return table.unpack(results, 2, results.n)
end

-- `goal` is a CFrame or a function returning one (nil aborts), so moving targets can be followed.
-- With keepSeat while driving, the whole vehicle is moved instead of the character.
-- "Tween" glides in a straight line (noclipped), ramping up to TeleportSpeed so the trip is
-- near-instant; if the server pulls the character back it lowers the speed and resumes.
-- "Vehicle" borrows a nearby car and drives it there instead (see vehicleTeleport).
local function rawTeleportCharacter(goal, keepSeat)
	local character, humanoid, root = getCharacter(), getHumanoid(), getRoot()
	if not (character and humanoid and root) then
		return false
	end
	local usesCar = teleportMethod == "Vehicle" or teleportMethod == "Car + Tween"
	if usesCar and vehicleTeleport and not inVehicleTrip and not (keepSeat and humanoid.SeatPart) then
		local handled, arrived = vehicleTeleport(goal, teleportMethod == "Car + Tween")
		if handled then
			return arrived
		end
	end
	if not keepSeat then
		exitSeat(humanoid)
	end
	local seat = keepSeat and humanoid.SeatPart or nil
	local vehicle = seat and getVehicleModel(seat)
	local mover = vehicle and seat or root

	local function resolve()
		if type(goal) == "function" then
			return goal()
		end
		return goal
	end
	local function getPivot()
		return vehicle and vehicle:GetPivot() or root.CFrame
	end
	local function setPivot(cframe)
		if vehicle then
			vehicle:PivotTo(cframe)
		else
			root.CFrame = cframe
		end
		mover.AssemblyLinearVelocity = Vector3.zero
		mover.AssemblyAngularVelocity = Vector3.zero
	end

	local target = resolve()
	if not target then
		return false
	end
	if teleportMethod == "Instant" then
		setPivot(target)
		return true
	end

	local arrived = false
	local flags = 0
	local standOffset = nil
	local vehicleClearance = 3
	if not vehicle then
		standOffset = getStandHeight(humanoid, root)
	elseif seat then
		-- Keep the chassis roughly this far above the road while gliding.
		vehicleClearance = math.clamp(seat.Position.Y - (findGroundY(seat.Position, vehicle) or seat.Position.Y - 3), 2, 6)
	end
	travelling = true

	local function hugGround(position)
		local flat = Vector3.new(target.Position.X - position.X, 0, target.Position.Z - position.Z)
		if flat.Magnitude < GROUND_FOLLOW_CUTOFF then
			return position
		end
		local groundY = findGroundY(position, vehicle)
		if not groundY then
			return position
		end
		if standOffset then
			return Vector3.new(position.X, groundY + standOffset, position.Z)
		end
		-- Vehicle trips used to fly in a straight line → void / flying kicks on sell teleports.
		return Vector3.new(position.X, groundY + vehicleClearance, position.Z)
	end

	local function land()
		local current = getPivot()
		local groundY = findGroundY(current.Position, vehicle)
		if groundY then
			local lift = standOffset or vehicleClearance
			setPivot(CFrame.new(current.Position.X, groundY + lift, current.Position.Z) * (current - current.Position))
		end
	end

	-- Hard cap for the whole trip including retries, so nothing can hang in the air.
	local tripDeadline = os.clock() + (vehicle and MAX_CAR_TRIP_SECONDS or MAX_FOOT_TRIP_SECONDS)

	-- Returns "arrived", "flagged" or "aborted".
	local function glide()
		local flagMark = teleportFlagCount
		local expected = getPivot().Position
		local distance = (target.Position - expected).Magnitude
		local topSpeed
		if vehicle then
			topSpeed = math.max(Arsenic.Values.CarTeleportSpeed, distance / CAR_TRIP_SECONDS)
		else
			topSpeed = math.max(Arsenic.Values.TeleportSpeed, MIN_TELEPORT_SPEED)
		end
		local started = os.clock()
		local deadline = math.min(started + TELEPORT_RAMP + distance / (topSpeed * 0.5) + 2, tripDeadline)

		while not Arsenic.Destroyed do
			local dt = RunService.Heartbeat:Wait()
			target = resolve()
			if not target or not mover.Parent or humanoid.Health <= 0 or os.clock() > deadline then
				return "aborted"
			end
			if vehicle and humanoid.SeatPart ~= seat then
				return "aborted"
			end
			local current = getPivot().Position
			if (current - expected).Magnitude > 6 or teleportFlagCount ~= flagMark then
				return "flagged"
			end

			local ramp = math.clamp((os.clock() - started) / TELEPORT_RAMP, 0, 1)
			local speed = TELEPORT_START_SPEED + (topSpeed - TELEPORT_START_SPEED) * ramp * ramp
			local offset = target.Position - current
			local step = speed * dt
			if offset.Magnitude <= step then
				setPivot(target)
				return "arrived"
			end
			local nextPosition = hugGround(current + offset.Unit * step)
			nextPosition = Vector3.new(
				nextPosition.X,
				math.clamp(nextPosition.Y, current.Y - step, current.Y + step),
				nextPosition.Z
			)
			local flat = Vector3.new(offset.X, 0, offset.Z)
			setPivot(flat.Magnitude > 0.1 and CFrame.lookAt(nextPosition, nextPosition + flat) or CFrame.new(nextPosition) * target.Rotation)
			expected = nextPosition
		end
		return "aborted"
	end

	local ok = pcall(function()
		while flags < MAX_TRAVEL_FLAGS do
			local result = glide()
			if result ~= "flagged" then
				arrived = result == "arrived"
				return
			end
			flags = flags + 1
			-- Touch down so the fly check resets, then keep going; only slow down on repeat pull-backs.
			land()
			if flags >= 2 then
				local slower = slowDownAfterFlag()
				notify(("Pulled back by the anti-teleport; retrying at %d studs/s."):format(slower))
			end
			task.wait(0.25)
			target = resolve()
			if not target or os.clock() > tripDeadline then
				return
			end
		end
	end)
	travelling = false
	if not on("Noclip") then
		Features.Noclip.disable()
	end
	if ok and not arrived and flags >= MAX_TRAVEL_FLAGS then
		notify("Kept getting pulled back by the anti-teleport; gave up on this trip.")
	end
	return ok and arrived
end

local function teleportCharacter(goal, keepSeat)
	return protectTravel(rawTeleportCharacter, goal, keepSeat)
end

-- Steal/sit approaches must not borrow another car (Vehicle method leaves you standing beside the target).
local function teleportOnFoot(goal)
	local previous = teleportMethod
	local root = getRoot()
	local distance = root and typeof(goal) == "CFrame" and (root.Position - goal.Position).Magnitude or math.huge
	teleportMethod = distance < 90 and "Instant" or "Tween"
	local ok, arrived = pcall(teleportCharacter, goal, false)
	teleportMethod = previous
	if not ok then
		error(arrived, 0)
	end
	return arrived
end

local function behind(targetRoot, distance)
	local position = (targetRoot.CFrame * CFrame.new(0, 0, distance)).Position
	return CFrame.lookAt(position, Vector3.new(targetRoot.Position.X, position.Y, targetRoot.Position.Z))
end

--------------------------------------------------------------------------------
-- Weapons
--------------------------------------------------------------------------------

local getUpvalues = genv.getupvalues or rawget(debug, "getupvalues")
local setUpvalue = genv.setupvalue or rawget(debug, "setupvalue")

Arsenic.Values.FireRate = 0.1
Arsenic.Values.ReloadTime = 1

-- Keys of each gun's `Setting` module that every toggle overrides.
local GUN_MODS = {
	NoGunJam = { JamChance = 0 },
	NoSpread = { SpreadX = 0, SpreadY = 0 },
	AutoGun = { Auto = true },
	NoRecoil = { Recoil = 0, CameraRecoilingEnabled = false },
	CustomFireRate = {
		FireRate = function()
			return Arsenic.Values.FireRate
		end,
	},
	CustomReloadSpeed = {
		ReloadTime = function()
			return Arsenic.Values.ReloadTime
		end,
	},
}

local gunEnvs = setmetatable({}, { __mode = "k" })
local gunSettings = setmetatable({}, { __mode = "k" })
local gunOriginals = setmetatable({}, { __mode = "k" })

local function isGun(tool)
	return tool ~= nil and tool:IsA("Tool") and tool:FindFirstChild("GunScript_Local") ~= nil
end

local function getGunEnv(tool)
	if gunEnvs[tool] then
		return gunEnvs[tool]
	end
	local localScript = tool:FindFirstChild("GunScript_Local")
	if not (getsenv and localScript) then
		return nil
	end
	local ok, env = pcall(getsenv, localScript)
	if ok and type(env) == "table" then
		gunEnvs[tool] = env
		return env
	end
	return nil
end

local function getGunFunction(tool, name)
	local env = getGunEnv(tool)
	if not env then
		return nil
	end
	local ok, fn = pcall(function()
		return env[name]
	end)
	return ok and type(fn) == "function" and fn or nil
end

local function isSettingTable(value)
	return type(value) == "table" and rawget(value, "FireRate") ~= nil and rawget(value, "AmmoPerMag") ~= nil
end

-- The gun script's own (already required) Setting table lives in Fire's upvalues;
-- writing to it changes the live gun. require() is only a fallback.
local function getGunSettings(tool)
	if gunSettings[tool] then
		return gunSettings[tool]
	end
	local settings
	local fire = getGunFunction(tool, "Fire")
	if fire and getUpvalues then
		local ok, upvalues = pcall(getUpvalues, fire)
		if ok and type(upvalues) == "table" then
			for _, value in pairs(upvalues) do
				if isSettingTable(value) then
					settings = value
					break
				end
			end
		end
	end
	if not settings then
		local module = tool:FindFirstChild("Setting")
		if module and module:IsA("ModuleScript") then
			local ok, result = pcall(require, module)
			if ok and isSettingTable(result) then
				settings = result
			end
		end
	end
	gunSettings[tool] = settings
	return settings
end

local function setGunValue(settings, key, value)
	local saved = gunOriginals[settings]
	if not saved then
		saved = {}
		gunOriginals[settings] = saved
	end
	if not saved[key] then
		saved[key] = { settings[key] }
	end
	if settings[key] ~= value then
		settings[key] = value
	end
end

local function restoreGunValue(settings, key)
	local saved = gunOriginals[settings]
	local entry = saved and saved[key]
	if entry then
		settings[key] = entry[1]
		saved[key] = nil
	end
end

local function anyGunModOn()
	for feature in pairs(GUN_MODS) do
		if on(feature) then
			return true
		end
	end
	return false
end

local function updateGunMods()
	for _, tool in ipairs(findTools(isGun)) do
		local settings = getGunSettings(tool)
		if settings then
			for feature, mods in pairs(GUN_MODS) do
				local enabled = on(feature)
				for key, mod in pairs(mods) do
					if enabled then
						local value = mod
						if type(mod) == "function" then
							value = mod()
						end
						setGunValue(settings, key, value)
					else
						restoreGunValue(settings, key)
					end
				end
			end
		end
	end
end

local function restoreGunFeature(feature)
	for settings in pairs(gunOriginals) do
		for key in pairs(GUN_MODS[feature]) do
			restoreGunValue(settings, key)
		end
	end
end

for feature in pairs(GUN_MODS) do
	Features[feature] = {
		disable = function()
			restoreGunFeature(feature)
		end,
	}
end

-- Infinite Ammo: the magazine (`Value`) and reserve (`Value2`) are locals of the gun
-- script; they are the first two numeric upvalues of its Reload function.
local INFINITE_AMMO = 9999
local lastAmmoTool = nil

local function refillGun(tool)
	local reload = getGunFunction(tool, "Reload")
	if not (reload and getUpvalues and setUpvalue) then
		return false
	end
	local ok, upvalues = pcall(getUpvalues, reload)
	if not ok or type(upvalues) ~= "table" then
		return false
	end
	local indices = {}
	for index, value in pairs(upvalues) do
		if type(index) == "number" and type(value) == "number" then
			table.insert(indices, index)
		end
	end
	table.sort(indices)
	if #indices < 2 then
		return false
	end
	for i = 1, 2 do
		pcall(setUpvalue, reload, indices[i], INFINITE_AMMO)
	end
	local updateGui = getGunFunction(tool, "UpdateGUI")
	if updateGui then
		pcall(updateGui)
	end
	return true
end

Features.InfiniteAmmo = {
	enable = function()
		lastAmmoTool = nil
		if not (getsenv and getUpvalues and setUpvalue) then
			notify("Infinite Ammo needs getsenv and debug.setupvalue, which this executor does not provide.")
		end
	end,
}

--------------------------------------------------------------------------------
-- Players
--------------------------------------------------------------------------------

local selectedPlayerName = nil
local spawnCarMethod = "Owned Cars"
local playerActionBusy = false

local function getSelectedPlayer()
	local player = selectedPlayerName and Players:FindFirstChild(selectedPlayerName)
	if player and player:IsA("Player") and player ~= LocalPlayer then
		return player
	end
	return nil
end

local function getTargetParts(player)
	local character = player and player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return character, humanoid, root
end

local function requireTarget()
	local player = getSelectedPlayer()
	if not player then
		notify("Select a player first.")
		return nil
	end
	local character, humanoid, root = getTargetParts(player)
	if not (character and humanoid and root) or humanoid.Health <= 0 then
		notify(player.Name .. " has no living character right now.")
		return nil
	end
	local myHumanoid = getHumanoid()
	if not (myHumanoid and getRoot()) or myHumanoid.Health <= 0 then
		notify("You need to be alive to do that.")
		return nil
	end
	return player, character, humanoid, root
end

local function runPlayerAction(action)
	if playerActionBusy then
		notify("Another action is still running.")
		return
	end
	playerActionBusy = true
	task.spawn(function()
		local ok, err = pcall(action)
		playerActionBusy = false
		if not ok then
			notify("Action failed: " .. tostring(err))
		end
	end)
end

-- Spectate ---------------------------------------------------------------------

local function updateSpectate()
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end
	local _, targetHumanoid = getTargetParts(getSelectedPlayer())
	local subject = targetHumanoid or getHumanoid()
	if subject and camera.CameraSubject ~= subject then
		camera.CameraSubject = subject
	end
	-- Zoom out while spectating (values stored on Features to avoid main-chunk locals).
	if on("Spectate") then
		local zoom = Features.Spectate
		if zoom and not zoom._savedZoom then
			zoom._savedZoom = {
				min = LocalPlayer.CameraMinZoomDistance,
				max = LocalPlayer.CameraMaxZoomDistance,
			}
		end
		LocalPlayer.CameraMinZoomDistance = 20
		LocalPlayer.CameraMaxZoomDistance = math.max(LocalPlayer.CameraMaxZoomDistance, 64)
	end
end

Features.Spectate = {
	enable = function()
		if not getSelectedPlayer() then
			notify("Select a player to spectate.")
		end
		updateSpectate()
	end,
	disable = function()
		local camera, humanoid = Workspace.CurrentCamera, getHumanoid()
		if camera and humanoid then
			camera.CameraSubject = humanoid
		end
		local zoom = Features.Spectate._savedZoom
		if zoom then
			LocalPlayer.CameraMinZoomDistance = zoom.min
			LocalPlayer.CameraMaxZoomDistance = zoom.max
			Features.Spectate._savedZoom = nil
		end
	end,
}

-- Teleport To Player -----------------------------------------------------------

local function teleportToPlayer()
	local player, _, _, targetRoot = requireTarget()
	if player then
		teleportCharacter(function()
			return targetRoot.Parent and behind(targetRoot, 3) or nil
		end)
	end
end

-- Ragdoll Player (fist tackle) -------------------------------------------------

local TACKLE_COOLDOWN = 50

local function getAttackRequest(tool)
	local system = tool:FindFirstChild("MeleeSystem")
	local remote = system and system:FindFirstChild("AttackRequest")
	return remote and remote:IsA("RemoteEvent") and remote or nil
end

local function ragdollPlayer()
	local player, _, targetHumanoid, targetRoot = requireTarget()
	if not player then
		return
	end
	if LocalPlayer:GetAttribute("Passive") then
		notify("Turn off Passive mode before ragdolling players.")
		return
	end
	local fist = findTools(function(tool)
		return getAttackRequest(tool) ~= nil
	end)[1]
	if not fist then
		notify("You need your Fist in your inventory to ragdoll players.")
		return
	end
	local remaining = TACKLE_COOLDOWN - (Workspace:GetServerTimeNow() - (LocalPlayer:GetAttribute("LastTackle") or 0))
	if remaining > 0 then
		notify(("Tackle is on cooldown for %d more seconds."):format(math.ceil(remaining)))
		return
	end

	local character, humanoid, root = getCharacter(), getHumanoid(), getRoot()
	local previousTool = character:FindFirstChildOfClass("Tool")
	local returnCFrame = root.CFrame
	local savedSpeed = humanoid.WalkSpeed

	exitSeat(humanoid)
	-- Tackle only registers when walk speed is at least 8.
	humanoid.WalkSpeed = math.max(savedSpeed, 16)
	if fist.Parent ~= character then
		humanoid:EquipTool(fist)
		task.wait(0.35)
	end

	local reached = teleportCharacter(function()
		return targetRoot.Parent and behind(targetRoot, 2.5) or nil
	end)
	if not reached then
		humanoid.WalkSpeed = savedSpeed
		notify("Could not reach " .. player.Name .. ".")
		teleportCharacter(returnCFrame)
		return
	end

	local attackRequest = getAttackRequest(fist)
	local attackId = math.floor(os.clock() * 1000)
	attackRequest:FireServer({ Mode = "Start", AttackId = attackId, DidTackle = true })
	-- Stay behind them facing their back through the whole hit window (~0.18s).
	local deadline = os.clock() + 0.22
	while os.clock() < deadline do
		if targetRoot.Parent and root.Parent then
			root.CFrame = behind(targetRoot, 2.5)
			root.AssemblyLinearVelocity = targetRoot.CFrame.LookVector * -12
		end
		RunService.Heartbeat:Wait()
	end
	attackRequest:FireServer({
		Mode = "Hits",
		Speed = math.max(humanoid.WalkSpeed, 16),
		DidTackle = true,
		AttackId = attackId,
		Targets = { targetHumanoid },
	})
	-- Second hit packet in case the first was early for the server's window.
	task.wait(0.05)
	if targetRoot.Parent and root.Parent then
		root.CFrame = behind(targetRoot, 2.5)
	end
	attackRequest:FireServer({
		Mode = "Hits",
		Speed = math.max(humanoid.WalkSpeed, 16),
		DidTackle = true,
		AttackId = attackId,
		Targets = { targetHumanoid },
	})

	task.wait(0.25)
	humanoid.WalkSpeed = savedSpeed
	teleportCharacter(returnCFrame)
	if previousTool and previousTool ~= fist and previousTool.Parent then
		humanoid:EquipTool(previousTool)
	elseif not previousTool then
		humanoid:UnequipTools()
	end
end

-- Kill Player ------------------------------------------------------------------

local losParams = RaycastParams.new()
losParams.FilterType = Enum.RaycastFilterType.Exclude
losParams.IgnoreWater = true

local function hasLineOfSight(origin, target, ignore)
	losParams.FilterDescendantsInstances = ignore
	return Workspace:Raycast(origin, target - origin, losParams) == nil
end

local function findShootSpot(targetRoot, head, ignore)
	for _, radius in ipairs({ 6, 10, 3 }) do
		for step = 0, 7 do
			local angle = step * math.pi / 4
			local position = targetRoot.Position + Vector3.new(math.cos(angle) * radius, 0, math.sin(angle) * radius)
			if hasLineOfSight(position + Vector3.new(0, 1.5, 0), head.Position, ignore) then
				return CFrame.lookAt(position, Vector3.new(targetRoot.Position.X, position.Y, targetRoot.Position.Z))
			end
		end
	end
	return behind(targetRoot, 4)
end

local function killPlayer()
	local player, targetCharacter, targetHumanoid = requireTarget()
	if not player then
		return
	end
	local character = getCharacter()
	local tool = character:FindFirstChildOfClass("Tool")
	if not isGun(tool) then
		notify("Equip a gun first.")
		return
	end
	local handle = tool:FindFirstChild("Handle")
	local firePoint = handle and handle:FindFirstChild("GunFirePoint")
	local inflict = ReplicatedStorage:FindFirstChild("InflictTarget")
	if not (handle and firePoint and inflict and inflict:IsA("RemoteEvent")) then
		notify("Could not find this gun's damage remote.")
		return
	end

	local settings = getGunSettings(tool) or {}
	local base = tonumber(settings.BaseDamage) or 25
	local mult = tonumber(settings.HeadshotDamageMultiplier) or 7
	local headEnabled = settings.HeadshotEnabled ~= false
	local damage = headEnabled and base * mult or base
	local shotDelay = math.max(tonumber(settings.FireRate) or 0.1, 0.05)
	local fire = getGunFunction(tool, "Fire")
	local range = tonumber(settings.Range) or 300

	local returnCFrame = nil
	local shots = 0
	local deadline = os.clock() + 8
	while os.clock() < deadline and shots < 40 and not Arsenic.Destroyed do
		local root = getRoot()
		local head = targetCharacter:FindFirstChild("Head")
		local targetRoot = targetCharacter:FindFirstChild("HumanoidRootPart")
		if not (root and head and targetRoot) or targetHumanoid.Health <= 0 then
			break
		end
		if player.Character ~= targetCharacter or tool.Parent ~= getCharacter() then
			break
		end

		local ignore = { getCharacter(), targetCharacter, Workspace.CurrentCamera }
		local origin = firePoint.WorldPosition
		if (head.Position - origin).Magnitude > range * 0.9 or not hasLineOfSight(origin, head.Position, ignore) then
			returnCFrame = returnCFrame or root.CFrame
			teleportCharacter(findShootSpot(targetRoot, head, ignore))
			RunService.Heartbeat:Wait()
			origin = firePoint.WorldPosition
		end

		-- Same payload the bullet visualizer sends when a headshot lands.
		pcall(function()
			inflict:FireServer(tool, LocalPlayer, targetHumanoid, targetRoot, damage, {
				settings.Knockback or 0,
				settings.Lifesteal or 0,
				settings.FlamingBullet or false,
				settings.FreezingBullet or false,
				nil,
				nil,
				settings.IgniteChance or 0,
				settings.IcifyChance or 0,
			}, {
				settings.CriticalDamageEnabled or false,
				settings.CriticalBaseChance or 0,
				settings.CriticalDamageMultiplier or 1,
			}, head, {
				settings.GoreEffectEnabled or false,
				settings.GoreSoundIDs or {},
				settings.GoreSoundPitchMin or 1,
				settings.GoreSoundPitchMax or 1,
				settings.GoreSoundVolume or 1,
			}, head.Position, (origin - head.Position).Unit)
		end)
		if fire then
			pcall(fire, handle, head.Position)
		end
		shots = shots + 1
		task.wait(shotDelay)
	end

	if returnCFrame then
		teleportCharacter(returnCFrame)
	end
	if targetHumanoid.Health <= 0 then
		notify(player.Name .. " was killed.")
	else
		notify(("Fired %d shots at %s but they are still alive."):format(shots, player.Name))
	end
end

-- Spawn Cars on Player ---------------------------------------------------------

local function getDriveSeat(car)
	local seat = car:FindFirstChild("DriveSeat", true)
	if seat and (seat:IsA("VehicleSeat") or seat:IsA("Seat")) then
		return seat
	end
	return nil
end

-- A car pushed through buildings takes crash damage (and so does its driver) until the game deletes
-- it, so while we move one it does not collide or register touches. Returns the undo function.
local function ghostCar(car)
	local saved = {}
	for _, part in ipairs(car:GetDescendants()) do
		if part:IsA("BasePart") then
			saved[part] = { part.CanCollide, part.CanTouch }
			part.CanCollide = false
			part.CanTouch = false
		end
	end
	local restored = false
	return function()
		if restored then
			return
		end
		restored = true
		for part, state in pairs(saved) do
			if part.Parent then
				part.CanCollide = state[1]
				part.CanTouch = state[2]
			end
		end
	end
end

local function getCarOwner(car)
	local owner = car:FindFirstChild("Owner")
	return owner and owner:IsA("StringValue") and owner.Value or ""
end

local function getOwnedCar()
	local civCars = Workspace:FindFirstChild("CivCars")
	for _, car in ipairs(civCars and civCars:GetChildren() or {}) do
		if getCarOwner(car) == LocalPlayer.Name then
			return car
		end
	end
	return nil
end

-- Jump onto the seat and sit in the same frame; the anti-teleport leaves seated players alone,
-- so this works from any distance without gliding.
local function instantSit(seat)
	local humanoid, root = getHumanoid(), getRoot()
	if not (humanoid and root) then
		return false
	end
	exitSeat(humanoid)
	seat.Disabled = false
	for _ = 1, 3 do
		if seat.Occupant or not seat.Parent then
			break
		end
		root.AssemblyLinearVelocity = Vector3.zero
		root.AssemblyAngularVelocity = Vector3.zero
		root.CFrame = seat.CFrame + Vector3.new(0, 1.5, 0)
		pcall(seat.Sit, seat, humanoid)
		if firetouchinterest then
			pcall(firetouchinterest, root, seat, 0)
			pcall(firetouchinterest, root, seat, 1)
		end
		local deadline = os.clock() + 0.3
		while humanoid.SeatPart ~= seat and os.clock() < deadline do
			RunService.Heartbeat:Wait()
		end
		if humanoid.SeatPart == seat then
			return true
		end
	end
	return humanoid.SeatPart == seat
end

local function enterSeat(seat)
	local humanoid = getHumanoid()
	if not humanoid or seat.Occupant then
		return false
	end
	if humanoid.SeatPart == seat then
		return true
	end
	if instantSit(seat) then
		return true
	end
	local wasInTrip = inVehicleTrip
	inVehicleTrip = true
	teleportCharacter(seat.CFrame + Vector3.new(0, 3, 0))
	inVehicleTrip = wasInTrip
	task.wait(0.15)
	local prompt = seat:FindFirstChildWhichIsA("ProximityPrompt", true)
	if prompt then
		firePrompt(prompt)
	end
	local deadline = os.clock() + 1.5
	while humanoid.SeatPart ~= seat and os.clock() < deadline do
		task.wait(0.1)
	end
	if humanoid.SeatPart ~= seat then
		forceSit(seat)
	end
	return humanoid.SeatPart == seat
end

-- Vehicle Teleport --------------------------------------------------------------

-- The game's own exit puts you 4 studs to the driver's left, so the driver seat parks there.
local SEAT_FROM_TARGET = CFrame.new(4, 0, 0)
-- Our own car wins over other cars that are up to this many studs closer, since theirs may be locked.
local OWN_CAR_BONUS = 150
local MAX_CAR_ATTEMPTS = 3
local CAR_RETURN_TIMEOUT = 4
local CAR_RETURN_ATTEMPTS = 3
-- Frames the car must be held at home while we control its physics for the move to reach the server.
local CAR_RETURN_FRAMES = 15
local CAR_FORCE_RETURN_TIME = 0.75
Arsenic.Values.CarExitDelay = 0.75

local isNetworkOwner = genv.isnetworkowner
local setSimulationRadius = genv.setsimulationradius
local setHiddenProperty = genv.sethiddenproperty

-- A car being stolen must never be sat in before the break-in, so trips cannot borrow it.
local avoidTravelCar = nil

-- Nearest free cars first, from anywhere on the map.
local function findTravelCars()
	local root = getRoot()
	local civCars = Workspace:FindFirstChild("CivCars")
	local cars = {}
	if not (root and civCars) then
		return cars
	end
	for _, car in ipairs(civCars:GetChildren()) do
		local seat = getDriveSeat(car)
		if seat and not seat.Occupant and car ~= avoidTravelCar then
			local score = (seat.Position - root.Position).Magnitude
			if getCarOwner(car) == LocalPlayer.Name then
				score = score - OWN_CAR_BONUS
			end
			table.insert(cars, { car = car, seat = seat, score = score })
		end
	end
	table.sort(cars, function(a, b)
		return a.score < b.score
	end)
	return cars
end

local function widenSimulationRadius()
	pcall(function()
		if setSimulationRadius then
			setSimulationRadius(1e9, 1e9)
		elseif setHiddenProperty then
			setHiddenProperty(LocalPlayer, "SimulationRadius", 1e9)
		end
	end)
end

local function controlsPhysics(part)
	if isNetworkOwner then
		local ok, owned = pcall(isNetworkOwner, part)
		if ok then
			return owned == true
		end
	end
	-- Parts we simulate ourselves never receive physics updates from the server.
	local ok, age = pcall(function()
		return part.ReceiveAge
	end)
	return not ok or age == 0
end

-- Once we hop out the game decides who simulates the car; moving it only reaches the server
-- while that is us, so keep it pinned at home until enough of those frames have gone through,
-- then check it actually stayed there and try again if it did not.
local function returnCarHome(car, seat, home, humanoid)
	-- Occupant still points at us until the server processes the exit, so only someone else counts.
	-- We count too if we are somehow still sitting in it, so the car never carries us back.
	local function weldedToUs()
		local character = humanoid.Parent
		for _, child in ipairs(seat:GetChildren()) do
			if child:IsA("JointInstance") and child.Part1 and character and child.Part1:IsDescendantOf(character) then
				return true
			end
		end
		return false
	end
	local function takenByOther()
		return (seat.Occupant ~= nil and seat.Occupant ~= humanoid) or humanoid.SeatPart == seat or weldedToUs()
	end
	local function pinHome()
		car:PivotTo(home)
		seat.AssemblyLinearVelocity = Vector3.zero
		seat.AssemblyAngularVelocity = Vector3.zero
	end

	widenSimulationRadius()
	-- The server owns the seat weld; moving the car before it is gone would drag us along with it
	-- (and can pull the character out of the world).
	local weldGone = os.clock() + 3
	while weldedToUs() and os.clock() < weldGone do
		RunService.Heartbeat:Wait()
	end
	if weldedToUs() then
		return false
	end
	-- Right after hopping out we still simulate the car, so move it home straight away.
	local forced = os.clock() + CAR_FORCE_RETURN_TIME
	while os.clock() < forced and car.Parent and not takenByOther() and not Arsenic.Destroyed do
		pinHome()
		RunService.Heartbeat:Wait()
	end

	for _ = 1, CAR_RETURN_ATTEMPTS do
		local deadline = os.clock() + CAR_RETURN_TIMEOUT
		local homeFrames = 0
		while os.clock() < deadline and homeFrames < CAR_RETURN_FRAMES do
			if not car.Parent or takenByOther() or Arsenic.Destroyed then
				return true
			end
			if controlsPhysics(seat) then
				pinHome()
				homeFrames = homeFrames + 1
			end
			RunService.Heartbeat:Wait()
		end
		task.wait(1)
		if not car.Parent or takenByOther() then
			return true
		end
		if (car:GetPivot().Position - home.Position).Magnitude < 15 then
			return true
		end
	end
	return false
end

local function flatRotation(cframe)
	local look = Vector3.new(cframe.LookVector.X, 0, cframe.LookVector.Z)
	if look.Magnitude < 0.01 then
		look = Vector3.new(0, 0, -1)
	end
	return CFrame.lookAt(cframe.Position, cframe.Position + look)
end

local function forceUnseat(humanoid, seat)
	humanoid:SetAttribute("LastCarJump", tick())
	humanoid.Sit = false
	local deadline = os.clock() + 0.5
	while humanoid.SeatPart and os.clock() < deadline do
		task.wait()
	end
	if humanoid.SeatPart then
		exitSeat(humanoid)
	end
	if humanoid.SeatPart then
		local weld = seat and seat:FindFirstChild("SeatWeld")
		if weld then
			weld:Destroy()
		end
		humanoid.Sit = false
		task.wait(0.1)
	end
end

-- Any instant jump right after getting out is caught by the anti-teleport, so the last few
-- studs to the target are walked (noclipped, at walking pace) instead.
local WALK_OFF_SPEED = 16

local function walkOffTo(humanoid, target, maxSeconds)
	local root = getRoot()
	if not (root and target) then
		return
	end
	travelling = true
	local deadline = os.clock() + (maxSeconds or 1.5)
	while os.clock() < deadline and root.Parent and humanoid.Health > 0 do
		local dt = RunService.Heartbeat:Wait()
		local offset = target.Position - root.Position
		local step = WALK_OFF_SPEED * dt
		root.AssemblyLinearVelocity = Vector3.zero
		root.AssemblyAngularVelocity = Vector3.zero
		if offset.Magnitude <= step then
			root.CFrame = target
			break
		end
		local nextPosition = root.Position + offset.Unit * step
		local flat = Vector3.new(offset.X, 0, offset.Z)
		root.CFrame = flat.Magnitude > 0.1 and CFrame.lookAt(nextPosition, nextPosition + flat) or CFrame.new(nextPosition) * target.Rotation
	end
	travelling = false
	if not on("Noclip") then
		Features.Noclip.disable()
	end
end

-- Debug Pathfinding: client-only neon lines and markers. They never collide, are skipped by
-- raycasts, and are only drawn while the toggle is on.
local PathDebug = {}
do
	local folder = nil
	local named = {}

	local function newPart(color)
		if not (folder and folder.Parent) then
			folder = Instance.new("Folder")
			folder.Name = "ArsenicPathDebug"
			folder.Parent = Workspace
		end
		local part = Instance.new("Part")
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.CastShadow = false
		part.Material = Enum.Material.Neon
		part.Color = color
		part.Transparency = 0.25
		part.Parent = folder
		return part
	end

	local function placeLine(part, a, b, thickness)
		if (b - a).Magnitude < 0.05 then
			b = a + Vector3.new(0, 0, 0.05)
		end
		part.Size = Vector3.new(thickness, thickness, (b - a).Magnitude)
		part.CFrame = CFrame.lookAt((a + b) / 2, b)
	end

	function PathDebug.enabled()
		return on("DebugPathfinding")
	end

	function PathDebug.clear(name)
		local parts = named[name]
		if parts then
			for _, part in ipairs(parts) do
				part:Destroy()
			end
			named[name] = nil
		end
	end

	function PathDebug.clearPrefix(prefix)
		for name in pairs(named) do
			if name:sub(1, #prefix) == prefix then
				PathDebug.clear(name)
			end
		end
	end

	function PathDebug.clearAll()
		for name in pairs(named) do
			PathDebug.clear(name)
		end
		if folder then
			folder:Destroy()
			folder = nil
		end
	end

	-- A route as a line through its points, replacing any earlier route with the same name.
	function PathDebug.path(name, points, color)
		PathDebug.clear(name)
		if not PathDebug.enabled() or #points < 2 then
			return
		end
		local parts = {}
		local lift = Vector3.new(0, 0.6, 0)
		for i = 2, #points do
			local part = newPart(color)
			placeLine(part, points[i - 1] + lift, points[i] + lift, 0.35)
			table.insert(parts, part)
		end
		named[name] = parts
	end

	-- A single line that is moved on every call, for things that change each frame.
	function PathDebug.line(name, a, b, color)
		if not PathDebug.enabled() then
			PathDebug.clear(name)
			return
		end
		local part = named[name] and named[name][1]
		if not part then
			part = newPart(color)
			named[name] = { part }
		end
		part.Color = color
		placeLine(part, a, b, 0.2)
	end

	function PathDebug.marker(name, position, color, size, ball)
		if not PathDebug.enabled() then
			PathDebug.clear(name)
			return
		end
		local part = named[name] and named[name][1]
		if not part then
			part = newPart(color)
			if ball then
				part.Shape = Enum.PartType.Ball
			end
			named[name] = { part }
		end
		part.Color = color
		part.Size = size
		part.CFrame = CFrame.new(position)
	end

	Features.DebugPathfinding = {
		disable = PathDebug.clearAll,
	}
	table.insert(Arsenic.Cleanup, PathDebug.clearAll)
end

-- Real walking along a pathfinding route (around walls, up stairs), so the last stretch of a trip
-- looks like a player walking instead of a glide through buildings.
local Pathing = {}
do
	local PathfindingService = game:GetService("PathfindingService")
	local WAYPOINT_REACHED = 2
	local STUCK_TIME = 1.2
	local MAX_STUCK = 3
	local WALK_PACE = 14

	function Pathing.compute(from, to, agent)
		local path = PathfindingService:CreatePath(agent or {
			AgentRadius = 2,
			AgentHeight = 5,
			AgentCanJump = true,
			WaypointSpacing = 4,
		})
		local ok = pcall(function()
			path:ComputeAsync(from, to)
		end)
		if not ok or path.Status ~= Enum.PathStatus.Success then
			return nil
		end
		return path:GetWaypoints()
	end

	function Pathing.length(waypoints)
		local total = 0
		for i = 2, #waypoints do
			total += (waypoints[i].Position - waypoints[i - 1].Position).Magnitude
		end
		return total
	end

	-- Walks the route with Humanoid:MoveTo. Returns false if there is no route or we got stuck.
	function Pathing.walk(humanoid, target, maxSeconds)
		local root = getRoot()
		if not (root and target) then
			return false
		end
		local waypoints = Pathing.compute(root.Position, target.Position)
		if not waypoints then
			return false
		end
		if PathDebug.enabled() then
			local points = {}
			for _, waypoint in ipairs(waypoints) do
				table.insert(points, waypoint.Position)
			end
			PathDebug.path("walk", points, Color3.fromRGB(0, 200, 255))
		end
		if travelling or not on("Noclip") then
			travelling = false
			Features.Noclip.disable()
		end
		local deadline = os.clock() + (maxSeconds or Pathing.length(waypoints) / WALK_PACE + 4)
		local stuckCount = 0
		for i = 2, #waypoints do
			local waypoint = waypoints[i]
			if waypoint.Action == Enum.PathWaypointAction.Jump then
				humanoid.Jump = true
			end
			humanoid:MoveTo(waypoint.Position)
			local lastPosition, lastMoved = root.Position, os.clock()
			while true do
				RunService.Heartbeat:Wait()
				if Arsenic.Destroyed or os.clock() > deadline or humanoid.Health <= 0 or not root.Parent or humanoid.SeatPart then
					humanoid:MoveTo(root.Position)
					return false
				end
				local flat = Vector3.new(waypoint.Position.X - root.Position.X, 0, waypoint.Position.Z - root.Position.Z)
				if flat.Magnitude <= WAYPOINT_REACHED then
					break
				end
				if (root.Position - lastPosition).Magnitude > 0.5 then
					lastPosition, lastMoved = root.Position, os.clock()
				elseif os.clock() - lastMoved > STUCK_TIME then
					stuckCount += 1
					if stuckCount > MAX_STUCK then
						humanoid:MoveTo(root.Position)
						return false
					end
					humanoid.Jump = true
					humanoid:MoveTo(waypoint.Position)
					lastMoved = os.clock()
				end
			end
		end
		return true
	end

	local STOP_DISTANCES = { 30, 20 }
	local STOP_ANGLES = { 0, 40, -40, 80, -80, 130, -130, 180 }

	-- Where to park a car short of `target` so the rest can be walked: same level as the target,
	-- room for the car, and a walkable route. Returns the driver seat CFrame, or nil.
	function Pathing.carStop(car, seat, target, from)
		local boxCFrame, size = car:GetBoundingBox()
		local boxFromSeat = seat.CFrame:ToObjectSpace(boxCFrame)
		local targetGround = findGroundY(target.Position) or target.Position.Y - 3
		local toStart = Vector3.new(from.X - target.Position.X, 0, from.Z - target.Position.Z)
		toStart = toStart.Magnitude > 0.1 and toStart.Unit or Vector3.new(1, 0, 0)
		local ignore = { car }
		for _, player in ipairs(Players:GetPlayers()) do
			if player.Character then
				table.insert(ignore, player.Character)
			end
		end
		local params = OverlapParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = ignore
		for _, distance in ipairs(STOP_DISTANCES) do
			for _, angle in ipairs(STOP_ANGLES) do
				local direction = CFrame.Angles(0, math.rad(angle), 0):VectorToWorldSpace(toStart)
				local spot = target.Position + direction * distance
				local groundY = findGroundY(Vector3.new(spot.X, targetGround + 6, spot.Z))
				if groundY and math.abs(groundY - targetGround) < 6 then
					local seatPosition = Vector3.new(spot.X, groundY + 3, spot.Z)
					local seatCFrame = CFrame.lookAt(seatPosition, Vector3.new(target.Position.X, seatPosition.Y, target.Position.Z))
					local blocked = false
					for _, part in ipairs(Workspace:GetPartBoundsInBox(seatCFrame * boxFromSeat + Vector3.new(0, 0.5, 0), size, params)) do
						if part.CanCollide and part.Transparency < 1 then
							blocked = true
							break
						end
					end
					if not blocked then
						local waypoints = Pathing.compute(seatPosition, target.Position)
						if waypoints and Pathing.length(waypoints) <= distance * 2.5 + 10 then
							return seatCFrame
						end
					end
				end
			end
		end
		return nil
	end

	-- Path-walk to the target, finishing (or falling back) with a slow straight walk.
	function Pathing.walkTo(humanoid, target, maxSeconds)
		local root = getRoot()
		if not (root and target) then
			return
		end
		if (root.Position - target.Position).Magnitude > 4 then
			Pathing.walk(humanoid, target, maxSeconds)
			PathDebug.clear("walk")
		end
		root = getRoot()
		if root then
			local left = (root.Position - target.Position).Magnitude
			walkOffTo(humanoid, target, math.max(left / WALK_OFF_SPEED + 0.5, 1.5))
		end
	end
end

-- Puts a car that stopped mid-air back on the ground before we get out of it.
local function landCar(car, seat)
	local pivot = car:GetPivot()
	local ignore = { Workspace.CurrentCamera, car }
	for _, player in ipairs(Players:GetPlayers()) do
		if player.Character then
			table.insert(ignore, player.Character)
		end
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = ignore
	params.IgnoreWater = true
	local result = Workspace:Raycast(pivot.Position + Vector3.new(0, 5, 0), Vector3.new(0, -5000, 0), params)
	if not result then
		return
	end
	local groundY = result.Position.Y
	local seatOffset = seat.Position.Y - pivot.Y
	car:PivotTo(flatRotation(pivot) + Vector3.new(0, groundY + 3 - seatOffset - pivot.Y, 0))
	seat.AssemblyLinearVelocity = Vector3.zero
	seat.AssemblyAngularVelocity = Vector3.zero
end

local function getInNearestVehicle()
	local cars = findTravelCars()
	local entry = cars[1]
	if not entry then
		notify("No free vehicle nearby.")
		return
	end
	if enterSeat(entry.seat) then
		notify("Sat in " .. entry.car.Name .. ".")
	else
		notify("Could not get into " .. entry.car.Name .. ".")
	end
end

local function bringNearestVehicle()
	local root = getRoot()
	local humanoid = getHumanoid()
	local cars = findTravelCars()
	local entry = cars[1]
	if not (root and humanoid and entry) then
		notify("No free vehicle nearby.")
		return
	end
	local car, seat = entry.car, entry.seat
	local destination = CFrame.new(root.Position + root.CFrame.LookVector * 8) * root.CFrame.Rotation
	-- Sitting gives us simulation rights so the move reaches the server.
	if not enterSeat(seat) then
		notify("Could not get into " .. car.Name .. " to bring it.")
		return
	end
	local restoreCar = ghostCar(car)
	widenSimulationRadius()
	local pinned = 0
	local deadline = os.clock() + 4
	while os.clock() < deadline and pinned < 18 and car.Parent and humanoid.SeatPart == seat do
		car:PivotTo(destination)
		seat.AssemblyLinearVelocity = Vector3.zero
		seat.AssemblyAngularVelocity = Vector3.zero
		if controlsPhysics(seat) or pinned < 5 then
			pinned += 1
		end
		RunService.Heartbeat:Wait()
	end
	restoreCar()
	landCar(car, seat)
	car:PivotTo(destination)
	forceUnseat(humanoid, seat)
	if pinned >= 3 then
		notify("Brought " .. car.Name .. " to you.")
	else
		notify("Could not fully bring " .. car.Name .. " (no network ownership).")
	end
end

-- Returns (handled, arrived). Not handled means no car could be used and the caller
-- should fall back to a Tween.
-- Where the driver seat stops on a "Car + Tween" trip: TweenAfterCar studs short of the target,
-- on the ground and facing it. Trips shorter than that leave the car where it is.
local function hybridSeatCFrame(startPosition, target)
	local flat = Vector3.new(target.Position.X - startPosition.X, 0, target.Position.Z - startPosition.Z)
	local tweenDistance = Arsenic.Values.TweenAfterCar
	local stop = startPosition
	if flat.Magnitude > tweenDistance then
		stop = target.Position - flat.Unit * tweenDistance
		local alpha = 1 - tweenDistance / flat.Magnitude
		local y = startPosition.Y + (target.Position.Y - startPosition.Y) * alpha
		local groundY = findGroundY(Vector3.new(stop.X, math.max(startPosition.Y, target.Position.Y) + 40, stop.Z))
		stop = Vector3.new(stop.X, groundY and groundY + 3 or y, stop.Z)
	end
	if flat.Magnitude < 0.1 then
		return CFrame.new(stop)
	end
	return CFrame.lookAt(stop, stop + flat)
end

local function returnCarInBackground(car, seat, home, humanoid, failNotice)
	task.spawn(function()
		local ok, returned = pcall(returnCarHome, car, seat, home, humanoid)
		if not (ok and returned) and failNotice ~= false then
			notify(failNotice or "Could not send the car back; it was left at the destination.")
		end
	end)
end

-- With tweenLast the car only covers part of the trip and the rest is a Tween on foot.
vehicleTeleport = function(goal, tweenLast)
	local humanoid = getHumanoid()
	if not humanoid then
		return false, false
	end

	local function resolve()
		if type(goal) == "function" then
			return goal()
		end
		return goal
	end
	local cars = findTravelCars()
	for attempt = 1, math.min(#cars, MAX_CAR_ATTEMPTS) do
		local car, seat = cars[attempt].car, cars[attempt].seat
		if car.Parent and not seat.Occupant then
			local home = car:GetPivot()
			local startSeat = seat.Position
			local pivotFromSeat = seat.CFrame:ToObjectSpace(home)
			-- Fixed destinations: park a short walk away and walk the rest along a real route.
			local walkStop = nil
			if not tweenLast and type(goal) ~= "function" then
				local okStop, stop = pcall(Pathing.carStop, car, seat, goal, startSeat)
				walkStop = okStop and stop or nil
			end
			local function seatGoal()
				local target = resolve()
				if not target then
					return nil
				end
				if tweenLast then
					return hybridSeatCFrame(startSeat, target)
				end
				if walkStop then
					return walkStop
				end
				return flatRotation(target) * SEAT_FROM_TARGET
			end
			local function carGoal()
				local seatCFrame = seatGoal()
				return seatCFrame and seatCFrame * pivotFromSeat or nil
			end

			local carReleased = false
			local restoreCar = nil
			inVehicleTrip = true
			local ok, result = pcall(function()
				if not instantSit(seat) then
					return "noseat"
				end
				restoreCar = ghostCar(car)
				local drove = teleportCharacter(carGoal, true)
				-- Only the drive itself sweeps through buildings; a parked car without collisions sinks.
				restoreCar()
				if not drove then
					if humanoid.SeatPart == seat then
						landCar(car, seat)
						task.wait(0.2)
					end
					forceUnseat(humanoid, seat)
					return "failed"
				end
				-- Sit still at the stop for a moment so the server settles before we get out.
				local settle = os.clock() + Arsenic.Values.CarExitDelay
				while os.clock() < settle and humanoid.SeatPart == seat do
					local goalCFrame = carGoal()
					if goalCFrame then
						car:PivotTo(goalCFrame)
						seat.AssemblyLinearVelocity = Vector3.zero
						seat.AssemblyAngularVelocity = Vector3.zero
					end
					RunService.Heartbeat:Wait()
				end

				forceUnseat(humanoid, seat)
				carReleased = true
				returnCarInBackground(car, seat, home, humanoid)
				if not tweenLast then
					if walkStop then
						Pathing.walkTo(humanoid, resolve())
					else
						walkOffTo(humanoid, resolve())
					end
					return "arrived"
				end
				-- inVehicleTrip is still set, so this is a plain Tween.
				if teleportCharacter(goal) then
					return "arrived"
				end
				return "failed"
			end)
			inVehicleTrip = false

			if not (ok and result == "noseat") then
				if restoreCar then
					restoreCar()
				end
				if not carReleased then
					returnCarInBackground(car, seat, home, humanoid)
				end
				return true, ok and result == "arrived"
			end
		end
	end

	if #cars == 0 then
		notify("No free car on the map to travel in; using Tween instead.")
	else
		notify("Could not get into a car; using Tween instead.")
	end
	return false, false
end

local function dropCarOn(car, seat, player)
	local humanoid = getHumanoid()
	if not (humanoid and enterSeat(seat)) then
		return false
	end
	local function aboveTarget()
		local _, _, targetRoot = getTargetParts(player)
		return targetRoot and CFrame.new(targetRoot.Position + Vector3.new(0, 10, 0)) * targetRoot.CFrame.Rotation or nil
	end
	-- Vehicle tween often fails mid-map; pin the car onto the target while we still simulate it.
	local restoreCar = ghostCar(car)
	widenSimulationRadius()
	local goal
	local pinned = 0
	local deadline = os.clock() + 4
	while os.clock() < deadline and pinned < 20 and car.Parent and humanoid.SeatPart == seat do
		goal = aboveTarget()
		if not goal then
			break
		end
		car:PivotTo(goal)
		seat.AssemblyLinearVelocity = Vector3.zero
		seat.AssemblyAngularVelocity = Vector3.zero
		if controlsPhysics(seat) or pinned < 5 then
			pinned += 1
		end
		RunService.Heartbeat:Wait()
	end
	restoreCar()
	if not goal or pinned < 3 then
		exitSeat(humanoid)
		return false
	end
	-- Park it on the ground on top of them so it is not deleted as a crash wreck.
	landCar(car, seat)
	goal = aboveTarget() or goal
	car:PivotTo(goal)
	local parked = car:GetPivot()
	forceUnseat(humanoid, seat)
	returnCarInBackground(car, seat, parked, humanoid, false)
	return true
end

local function findDealerGui()
	local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
	for _, gui in ipairs(playerGui and playerGui:GetChildren() or {}) do
		local remote = gui:FindFirstChild("DealerRemote")
		if remote and remote:IsA("RemoteEvent") then
			return gui, remote
		end
	end
	return nil
end

local function findOwnedDealerCar(gui)
	local best
	for _, button in ipairs(gui:GetDescendants()) do
		if button:IsA("TextButton") and button:GetAttribute("DealerCar") and button:GetAttribute("Owned") == true then
			if not best or button.LayoutOrder < best.LayoutOrder then
				best = button
			end
		end
	end
	return best and best.Name
end

local function openDealer()
	local gui, remote = findDealerGui()
	if gui then
		return gui, remote
	end
	local dealer = Workspace:FindFirstChild("CARDealerP") or Workspace:FindFirstChild("CARDealerP2")
	if not (dealer and dealer:IsA("BasePart")) then
		return nil
	end
	teleportCharacter(dealer.CFrame + Vector3.new(0, 3, 0))
	local deadline = os.clock() + 4
	repeat
		local root = getRoot()
		if firetouchinterest and root then
			pcall(firetouchinterest, root, dealer, 0)
			pcall(firetouchinterest, root, dealer, 1)
		end
		task.wait(0.25)
		gui, remote = findDealerGui()
	until gui or os.clock() > deadline
	return gui, remote
end

local function spawnOwnedCar()
	local existing = getOwnedCar()
	if existing then
		return existing
	end
	local gui, remote = openDealer()
	if not gui then
		notify("Could not open the car dealership.")
		return nil
	end
	local carName
	local deadline = os.clock() + 3
	repeat
		carName = findOwnedDealerCar(gui)
		if not carName then
			task.wait(0.2)
		end
	until carName or os.clock() > deadline
	if not carName then
		pcall(remote.FireServer, remote, "Close")
		notify("You do not own any cars at the dealership.")
		return nil
	end

	remote:FireServer("Buy", carName)
	local car
	deadline = os.clock() + 6
	repeat
		task.wait(0.2)
		car = getOwnedCar()
	until car or os.clock() > deadline
	if gui.Parent then
		pcall(remote.FireServer, remote, "Close")
	end
	if not car then
		notify("The dealership did not spawn your " .. carName .. ".")
	end
	return car
end

local MAX_STOLEN_CARS = 10

local function spawnCarsOnPlayer()
	local player = requireTarget()
	if not player then
		return
	end
	local returnCFrame = getRoot().CFrame
	local dropped = 0

	-- Get near the target first so spawned / stolen cars are not left on us at the dealer.
	local reached = teleportCharacter(function()
		local _, _, targetRoot = getTargetParts(player)
		return targetRoot and behind(targetRoot, 10) or nil
	end)
	if not reached then
		notify("Could not reach " .. player.Name .. " to drop cars on them.")
		return
	end

	if spawnCarMethod == "All Cars" then
		local civCars = Workspace:FindFirstChild("CivCars")
		for _, car in ipairs(civCars and civCars:GetChildren() or {}) do
			if dropped >= MAX_STOLEN_CARS or Arsenic.Destroyed then
				break
			end
			local _, targetHumanoid = getTargetParts(player)
			if not targetHumanoid or targetHumanoid.Health <= 0 or not player.Parent then
				break
			end
			local owner = getCarOwner(car)
			local seat = getDriveSeat(car)
			if seat and not seat.Occupant and owner ~= "" and owner ~= LocalPlayer.Name then
				if dropCarOn(car, seat, player) then
					dropped = dropped + 1
				end
			end
		end
	else
		local car = spawnOwnedCar()
		local seat = car and getDriveSeat(car)
		if seat and dropCarOn(car, seat, player) then
			dropped = 1
		end
	end

	teleportCharacter(returnCFrame)
	if dropped > 0 then
		notify(("Dropped %d car(s) on %s."):format(dropped, player.Name))
	elseif spawnCarMethod == "All Cars" then
		notify("No other players' cars could be entered.")
	end
end

--------------------------------------------------------------------------------
-- Buy
--------------------------------------------------------------------------------

local function nearestPart(parts)
	local root = getRoot()
	local best, bestDistance = nil, math.huge
	for _, part in ipairs(parts) do
		if part:IsA("BasePart") then
			local distance = root and (part.Position - root.Position).Magnitude or 0
			if distance < bestDistance then
				best, bestDistance = part, distance
			end
		end
	end
	return best
end

local function workspacePart(name)
	return function()
		local part = Workspace:FindFirstChild(name)
		return part and part:IsA("BasePart") and part or nil
	end
end

-- gui: ScreenGui in PlayerGui; remote: ReplicatedStorage RemoteFunction taking the item name;
-- items: ReplicatedStorage ModuleScript of { [itemName] = { Price, MaxStock? } };
-- stock: ReplicatedStorage folder of per-item stock values; locate: the store's prompt part.
local STORES = {
	{
		name = "Deli",
		gui = "ShopGUI",
		remote = "ShopRemote",
		items = "DeliTools",
		stock = "DeliStock",
		locate = function()
			local shopList = Workspace:FindFirstChild("ShopList")
			local parts = {}
			for _, child in ipairs(shopList and shopList:GetChildren() or {}) do
				if child.Name == "Shop1" then
					table.insert(parts, child)
				end
			end
			return nearestPart(parts)
		end,
	},
	{
		name = "Tha Shop",
		gui = "ThaShop",
		remote = "ExoticShopRemote",
		items = "ThaShop",
		stock = "ExoticStock",
		locate = workspacePart("ThaShop2"),
	},
	{
		name = "Exotic Gun Store",
		gui = "ThaShop2",
		remote = "ExoticShopRemote2",
		items = "ThaShop2",
		stock = "ExoticStock2",
		locate = workspacePart("ThaShop3"),
	},
	{
		name = "City Gun Store",
		gui = "2CityGun",
		remote = "CityShopRemote",
		items = "2CityGuns",
		stock = "CityStock",
		locate = workspacePart("2CityGun"),
	},
	{
		name = "Prison Gun Store",
		gui = "PrisonGun",
		remote = "PrisonShopRemote",
		items = "PrisonGuns",
		stock = "PrisonStock",
		locate = workspacePart("PrisonGui Tools"),
	},
	{
		name = "Bandage Shop",
		gui = "NewShopGUI",
		remote = "ShopRemote2",
		items = "NewShopTools",
		stock = "NewShopStock",
		locate = workspacePart("ThaShop4"),
	},
	{
		name = "5th Shop",
		gui = "5TH SHOP",
		remote = "ShopRemote5",
		items = "NewShopTools5",
		stock = "NewShopStock5",
		locate = workspacePart("ThaShop5"),
	},
	{
		name = "Soda Machine",
		gui = "6TH SHOP",
		remote = "ShopRemote6",
		items = "NewShopTools6",
		stock = "NewShopStock6",
		locate = function()
			local machine = Workspace:FindFirstChild("SodaMachine")
			local part = machine and machine:FindFirstChild("Buy")
			return part and part:IsA("BasePart") and part or nil
		end,
	},
	{
		name = "Car Dealership",
		dealer = true,
	},
}

local STORE_REACH = 10

local storesByRemote = {}
for _, store in ipairs(STORES) do
	if store.remote then
		storesByRemote[store.remote] = store
	end
end

local storeItemCache = {}

local function getStoreItems(store)
	if not store.items then
		return {}
	end
	if storeItemCache[store] then
		return storeItemCache[store]
	end
	local items = {}
	local module = ReplicatedStorage:FindFirstChild(store.items)
	if module and module:IsA("ModuleScript") then
		local ok, result = pcall(require, module)
		if ok and type(result) == "table" then
			for itemName, info in pairs(result) do
				if type(itemName) == "string" and type(info) == "table" then
					items[itemName] = info
				end
			end
		end
	end
	storeItemCache[store] = items
	return items
end

local function getStock(store, item)
	local folder = ReplicatedStorage:FindFirstChild(store.stock or "")
	local value = folder and folder:FindFirstChild(item)
	if value and value:IsA("ValueBase") and type(value.Value) == "number" then
		return value.Value
	end
	return nil
end

local function countOwned(item)
	return #findTools(function(tool)
		return tool.Name == item
	end)
end

local function getStoreGui(store)
	local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
	local gui = playerGui and store.gui and playerGui:FindFirstChild(store.gui)
	return gui and gui:IsA("ScreenGui") and gui or nil
end

local function distanceToStore(store)
	local part, root = store.locate and store.locate(), getRoot()
	if not (part and root) then
		return math.huge
	end
	return (part.Position - root.Position).Magnitude
end

-- Only ownership is cached; a missing pass is re-checked in case it gets bought mid-session.
local ownedGamepasses = {}
local gamepassNames = {}

local function ownsGamepass(id)
	if ownedGamepasses[id] then
		return true
	end
	local ok, owned = pcall(MarketplaceService.UserOwnsGamePassAsync, MarketplaceService, LocalPlayer.UserId, id)
	if not ok then
		return true -- let the server decide if Roblox cannot be reached
	end
	if owned then
		ownedGamepasses[id] = true
	end
	return owned == true
end

local function getGamepassName(id)
	if gamepassNames[id] == nil then
		local ok, info = pcall(MarketplaceService.GetProductInfo, MarketplaceService, id, Enum.InfoType.GamePass)
		gamepassNames[id] = ok and type(info) == "table" and info.Name or false
	end
	return gamepassNames[id] or nil
end

-- The gamepass this store needs for the item that we do not own, if any.
local function missingGamepass(store, item)
	local info = getStoreItems(store)[item]
	local id = info and tonumber(info.GamepassId)
	if id and id > 0 and not ownsGamepass(id) then
		return id
	end
	return nil
end

local function gamepassMessage(item, id)
	local name = getGamepassName(id)
	if name then
		return ("%s cannot be purchased because you are missing the \"%s\" gamepass."):format(item, name)
	end
	return ("%s cannot be purchased because you are missing its gamepass."):format(item)
end

-- One trip to the store: buy every item, then teleport back once (avoids anti-teleport kicks).
-- Returns success, reason.
local function purchaseManyAt(store, items)
	local part = store.locate()
	local remote = ReplicatedStorage:FindFirstChild(store.remote)
	local root = getRoot()
	if not (part and remote and remote:IsA("RemoteFunction") and root) then
		return false, store.name .. " is not available"
	end
	if type(items) ~= "table" or #items == 0 then
		return true, nil
	end

	for _, item in ipairs(items) do
		local stockBefore = getStock(store, item)
		if stockBefore and stockBefore <= 0 then
			return false, item .. " is out of stock at " .. store.name
		end
	end

	local returnCFrame = root.CFrame
	local moved = false
	if (part.Position - root.Position).Magnitude > STORE_REACH then
		local away = Vector3.new(root.Position.X - part.Position.X, 0, root.Position.Z - part.Position.Z)
		away = away.Magnitude > 1e-3 and away.Unit or Vector3.new(0, 0, 1)
		local standAt = part.Position + away * 3
		moved = true
		if not teleportCharacter(CFrame.lookAt(standAt, Vector3.new(part.Position.X, standAt.Y, part.Position.Z))) then
			teleportCharacter(returnCFrame)
			return false, "could not reach " .. store.name
		end
		task.wait(0.2)
	end

	local gui = getStoreGui(store)
	local guiWasOpen = gui and gui.Enabled
	local prompt = part:FindFirstChildWhichIsA("ProximityPrompt", true)
	if prompt then
		firePrompt(prompt)
		task.wait(0.15)
	end

	local boughtNames, failures, lastResult = {}, {}, nil
	for index, item in ipairs(items) do
		local stockBefore = getStock(store, item)
		local ownedBefore = countOwned(item)
		local ok, result = pcall(remote.InvokeServer, remote, item)
		lastResult = result
		local bought = false
		local deadline = os.clock() + 1.5
		repeat
			local stockNow = getStock(store, item)
			if countOwned(item) > ownedBefore or (stockBefore and stockNow and stockNow < stockBefore) then
				bought = true
				break
			end
			task.wait(0.1)
		until os.clock() > deadline

		if bought then
			table.insert(boughtNames, item)
		elseif not ok then
			table.insert(failures, tostring(result))
		elseif type(result) == "string" and result ~= "" then
			table.insert(failures, result)
		else
			table.insert(failures, item .. " was not confirmed at " .. store.name)
		end
		if index < #items then
			task.wait(0.15)
		end
	end

	if gui and not guiWasOpen then
		gui.Enabled = false
	end
	if moved then
		teleportCharacter(returnCFrame)
	end

	if #failures == 0 then
		return true, nil
	end
	if #boughtNames == 0 and type(lastResult) == "string" and lastResult ~= "" and #items == 1 then
		return false, lastResult
	end
	if #boughtNames > 0 then
		return false, ("bought %s but failed: %s"):format(table.concat(boughtNames, ", "), table.concat(failures, "; "))
	end
	return false, table.concat(failures, "; ")
end

-- Walks up to the store if needed, buys through its remote, and confirms the purchase
-- by watching the stock value / inventory. Returns success, reason.
local function purchaseAt(store, item)
	return purchaseManyAt(store, { item })
end

-- Tries every store that sells the item, in-stock and nearest first.
local function buyItem(item)
	local candidates = {}
	local sellers, missingPass = 0, nil
	for _, store in ipairs(STORES) do
		if getStoreItems(store)[item] then
			sellers = sellers + 1
			local passId = missingGamepass(store, item)
			if passId then
				missingPass = missingPass or passId
			else
				local stock = getStock(store, item)
				if stock == nil or stock > 0 then
					table.insert(candidates, store)
				end
			end
		end
	end
	if #candidates == 0 and missingPass then
		notify(gamepassMessage(item, missingPass))
		return false
	end
	if #candidates == 0 then
		notify(item .. " is out of stock everywhere.")
		return false
	end
	table.sort(candidates, function(a, b)
		return distanceToStore(a) < distanceToStore(b)
	end)

	local reasons = {}
	for _, store in ipairs(candidates) do
		local ok, reason = purchaseAt(store, item)
		if ok then
			notify(("Bought %s at %s."):format(item, store.name))
			return true
		end
		table.insert(reasons, reason)
	end
	notify(("Could not buy %s: %s."):format(item, table.concat(reasons, "; ")))
	return false
end

-- Buy several items in one store visit (one teleport out and back).
local function buyItems(items)
	local needed = {}
	for _, item in ipairs(items) do
		if countOwned(item) == 0 then
			table.insert(needed, item)
		end
	end
	if #needed == 0 then
		return true
	end
	if #needed == 1 then
		return buyItem(needed[1]) == true
	end

	local candidates, missingPass = {}, nil
	for _, store in ipairs(STORES) do
		local sellsAll = true
		for _, item in ipairs(needed) do
			if not getStoreItems(store)[item] then
				sellsAll = false
				break
			end
			local passId = missingGamepass(store, item)
			if passId then
				missingPass = missingPass or passId
				sellsAll = false
				break
			end
			local stock = getStock(store, item)
			if stock ~= nil and stock <= 0 then
				sellsAll = false
				break
			end
		end
		if sellsAll then
			table.insert(candidates, store)
		end
	end
	if #candidates == 0 and missingPass then
		notify(gamepassMessage(needed[1], missingPass))
		return false
	end
	if #candidates == 0 then
		-- No single store has everything; fall back per-item (may teleport more than once).
		for _, item in ipairs(needed) do
			if not buyItem(item) then
				return false
			end
		end
		return true
	end
	table.sort(candidates, function(a, b)
		return distanceToStore(a) < distanceToStore(b)
	end)

	local reasons = {}
	for _, store in ipairs(candidates) do
		local ok, reason = purchaseManyAt(store, needed)
		if ok then
			notify(("Bought %s at %s."):format(table.concat(needed, " and "), store.name))
			return true
		end
		table.insert(reasons, reason)
	end
	notify(("Could not buy %s: %s."):format(table.concat(needed, " and "), table.concat(reasons, "; ")))
	return false
end

local function getAllStoreItems()
	local seen, list = {}, {}
	for _, store in ipairs(STORES) do
		for itemName in pairs(getStoreItems(store)) do
			if not seen[itemName] then
				seen[itemName] = true
				table.insert(list, itemName)
			end
		end
	end
	table.sort(list, function(a, b)
		return a:lower() < b:lower()
	end)
	return list
end

local function openStoreUi(storeName)
	local store
	for _, candidate in ipairs(STORES) do
		if candidate.name == storeName then
			store = candidate
		end
	end
	if not store then
		return
	end

	if store.dealer then
		runPlayerAction(function()
			if findDealerGui() then
				return
			end
			local returnCFrame = getRoot() and getRoot().CFrame
			local gui = openDealer()
			if returnCFrame then
				teleportCharacter(returnCFrame)
			end
			if not gui then
				notify("Could not open the car dealership.")
			end
		end)
		return
	end

	local gui = getStoreGui(store)
	if not gui then
		notify(store.name .. " UI was not found.")
		return
	end
	gui.Enabled = true
end

-- A Buy click in a store UI opened from far away is taken over: walk there, buy, walk back.
storeRedirect = function(remote, item)
	if Arsenic.Destroyed or type(item) ~= "string" or remote.Parent ~= ReplicatedStorage then
		return false
	end
	local store = storesByRemote[remote.Name]
	if not store or distanceToStore(store) <= STORE_REACH then
		return false
	end
	runPlayerAction(function()
		local passId = missingGamepass(store, item)
		if passId then
			notify(gamepassMessage(item, passId))
			return
		end
		local ok, reason = purchaseAt(store, item)
		if ok then
			notify(("Bought %s at %s."):format(item, store.name))
		else
			notify(("Could not buy %s: %s."):format(item, reason or "unknown error"))
		end
	end)
	return true
end

--------------------------------------------------------------------------------
-- Money
--------------------------------------------------------------------------------

local Money = {}

-- Own function scope: the main chunk is close to Luau's 200-register limit.
;(function()
	Arsenic.Values.DropAmount = 0
	Arsenic.Values.DepositAmount = 0
	Arsenic.Values.WithdrawAmount = 0

	local DROP_LIMIT = 10000
	local STUDIO_SESSION_COST = 15000
	-- Hops shorter than this are glided on foot; longer ones use the selected teleport method.
	local SHORT_HOP = 60
	-- The server pulls back anything much faster than the game's sprint speed (16, 17.8 with soda).
	local SHORT_HOP_SPEED = 18
	local WALK_SPEED_AFTER_FLAG = 12
	local ARRIVAL_SETTLE_TIME = 0.6
	local PULLED_BACK_COOLDOWN = 2
	local MAX_APPROACHES = 3
	-- Long trips back to back are what turn pull-backs into a "Teleportation Detected!" kick.
	local TRIP_GAP = 3
	local MAX_TRIP_GAP = 20
	local CLEAN_STEP_ATTEMPTS = 3
	local COUNTING_TIMEOUT = 120
	-- Copies of some job props are parked off-map (around Y 460); never travel to those.
	local MAX_MAP_HEIGHT = 400

	local function getStat(name)
		local stored = LocalPlayer:FindFirstChild("stored")
		local value = stored and stored:FindFirstChild(name)
		return value and tonumber(value.Value) or 0
	end

	local function formatCash(amount)
		local text = tostring(math.floor(amount))
		local count
		repeat
			text, count = text:gsub("^(-?%d+)(%d%d%d)", "%1,%2")
		until count == 0
		return "$" .. text
	end

	local function parseAmount(text)
		local number = tonumber((tostring(text or ""):gsub("[%$,%s]", "")))
		if number and number > 0 then
			return math.floor(number)
		end
		return 0
	end

	local function waitUntil(condition, timeout)
		local deadline = os.clock() + timeout
		while os.clock() < deadline and not Arsenic.Destroyed do
			if condition() then
				return true
			end
			task.wait(0.1)
		end
		return condition() and true or false
	end

	local noticeCooldowns = {}
	local function notifyOnce(key, text, cooldown)
		local now = os.clock()
		if (noticeCooldowns[key] or 0) <= now then
			noticeCooldowns[key] = now + (cooldown or 30)
			notify(text)
		end
	end

	local function getRemote(name)
		return ReplicatedStorage:FindFirstChild(name)
	end

	local function isOnMap(position)
		return position ~= nil and position.Y < MAX_MAP_HEIGHT
	end

	local function distanceTo(position)
		local root = getRoot()
		return root and position and (root.Position - position).Magnitude or math.huge
	end

	local function promptPosition(prompt)
		return prompt and getWorldPosition(prompt.Parent)
	end

	local function sortByDistance(prompts)
		table.sort(prompts, function(a, b)
			return distanceTo(promptPosition(a)) < distanceTo(promptPosition(b))
		end)
		return prompts
	end

	-- Full-map prompt scans are expensive, so results are cached for a while.
	local promptCache = {}
	local function findPrompts(key, filter)
		local cached = promptCache[key]
		if cached and os.clock() - cached.time < 20 then
			local alive = {}
			for _, prompt in ipairs(cached.list) do
				if prompt.Parent then
					table.insert(alive, prompt)
				end
			end
			return alive
		end
		local list = {}
		for _, descendant in ipairs(Workspace:GetDescendants()) do
			if descendant:IsA("ProximityPrompt") and filter(descendant) and isOnMap(promptPosition(descendant)) then
				table.insert(list, descendant)
			end
		end
		promptCache[key] = { time = os.clock(), list = list }
		return list
	end

	-- Noclipped glide at a jogging pace for short hops between job props.
	local function rawGlideTo(target, speed)
		local root, humanoid = getRoot(), getHumanoid()
		if not (root and humanoid) then
			return
		end
		speed = speed or SHORT_HOP_SPEED
		exitSeat(humanoid)
		travelling = true
		local deadline = os.clock() + (target.Position - root.Position).Magnitude / speed + 1
		while os.clock() < deadline and root.Parent and humanoid.Health > 0 do
			local dt = RunService.Heartbeat:Wait()
			local offset = target.Position - root.Position
			local step = speed * dt
			root.AssemblyLinearVelocity = Vector3.zero
			root.AssemblyAngularVelocity = Vector3.zero
			if offset.Magnitude <= step then
				root.CFrame = target
				break
			end
			root.CFrame = target.Rotation + (root.Position + offset.Unit * step)
		end
		travelling = false
		if not on("Noclip") then
			Features.Noclip.disable()
		end
	end

	local function glideTo(target, speed)
		return protectTravel(rawGlideTo, target, speed)
	end

	-- Where to stand to be within `reach` of a point: on the ground, on our side of it, facing it.
	local function standNear(position, reach)
		local root, humanoid = getRoot(), getHumanoid()
		if not (root and humanoid) then
			return nil
		end
		local flat = Vector3.new(root.Position.X - position.X, 0, root.Position.Z - position.Z)
		local away = flat.Magnitude > 0.1 and flat.Unit or Vector3.new(0, 0, 1)
		local spot = position + away * math.min(reach * 0.6, 3)
		local groundY = findGroundY(spot)
		local y = groundY and groundY + getStandHeight(humanoid, root) or spot.Y
		if math.abs(y - position.Y) > reach then
			y = position.Y
		end
		local standPosition = Vector3.new(spot.X, y, spot.Z)
		return CFrame.lookAt(standPosition, Vector3.new(position.X, y, position.Z))
	end

	-- After arriving, stay put briefly: the anti-teleport snaps us back a moment after a move it
	-- dislikes, and a prompt fired before that lands from the wrong place.
	local function settledNear(position, reach, flagMark)
		local deadline = os.clock() + ARRIVAL_SETTLE_TIME
		repeat
			task.wait(0.1)
			if teleportFlagCount ~= flagMark or distanceTo(position) > reach + 1 then
				return false
			end
		until os.clock() >= deadline
		return true
	end

	-- The gap grows after every pull-back and shrinks back after clean trips, so farms that chain
	-- long trips slow down before the pull-backs pile up.
	local lastTripEnded = 0
	local tripGap = TRIP_GAP
	local function notePullBack()
		tripGap = math.min(tripGap * 2, MAX_TRIP_GAP)
	end

	local function longTrip(cframe)
		local wait = tripGap - (os.clock() - lastTripEnded)
		if wait > 0 then
			task.wait(wait)
		end
		local flagMark = teleportFlagCount
		local arrived = teleportCharacter(cframe)
		lastTripEnded = os.clock()
		if teleportFlagCount ~= flagMark then
			notePullBack()
		else
			tripGap = math.max(tripGap * 0.75, TRIP_GAP)
		end
		return arrived
	end

	local function goNear(position, reach)
		local pulledBack = false
		for _ = 1, MAX_APPROACHES do
			local root = getRoot()
			if not root then
				return false
			end
			local flagMark = teleportFlagCount
			if (root.Position - position).Magnitude > reach then
				local stand = standNear(position, reach)
				if not stand then
					return false
				end
				if (root.Position - stand.Position).Magnitude <= SHORT_HOP then
					glideTo(stand, pulledBack and WALK_SPEED_AFTER_FLAG or nil)
				else
					longTrip(stand)
				end
				if distanceTo(position) <= reach + 1 and settledNear(position, reach, flagMark) then
					return true
				end
				if teleportFlagCount ~= flagMark then
					notePullBack()
				end
				pulledBack = true
				task.wait(PULLED_BACK_COOLDOWN)
			else
				return true
			end
		end
		return false
	end

	local function usePrompt(prompt, forceInstant)
		for _ = 1, 2 do
			if not (prompt and prompt.Parent) then
				return false
			end
			local position = promptPosition(prompt)
			local reach = math.max(prompt.MaxActivationDistance - 1, 1.5)
			if not (position and goNear(position, reach)) then
				return false
			end
			local flagMark = teleportFlagCount
			firePrompt(prompt, forceInstant)
			task.wait(forceInstant and 0.05 or 0.25)
			if teleportFlagCount == flagMark and distanceTo(position) <= reach + 1 then
				return true
			end
			task.wait(PULLED_BACK_COOLDOWN)
		end
		return false
	end

	local function returnTo(cframe)
		if cframe and distanceTo(cframe.Position) > 8 then
			longTrip(cframe)
		end
	end

	local function getTool(name)
		return findTools(function(tool)
			return tool.Name == name
		end)[1]
	end

	local function snapshotTools()
		local owned = {}
		for _, tool in ipairs(findTools(function()
			return true
		end)) do
			owned[tool] = true
		end
		return owned
	end

	local function waitForNewTool(before, timeout)
		local found
		waitUntil(function()
			found = findTools(function(tool)
				return not before[tool]
			end)[1]
			return found ~= nil
		end, timeout)
		return found
	end

	local function equipTool(tool)
		local character, humanoid = getCharacter(), getHumanoid()
		if tool and humanoid and tool.Parent ~= character then
			humanoid:EquipTool(tool)
			task.wait(0.2)
		end
		return tool
	end

	-- Farm loops share the action lock with the buttons, so only one thing moves the player at a time.
	local function runFarmStep(step, active)
		if playerActionBusy then
			return
		end
		playerActionBusy = true
		local ok, err = pcall(step, active)
		playerActionBusy = false
		if not ok then
			warn("[Arsenic] " .. tostring(err))
		end
	end

	local loopGenerations = {}
	local function loopFeature(feature, interval, step)
		Features[feature] = {
			enable = function()
				local generation = (loopGenerations[feature] or 0) + 1
				loopGenerations[feature] = generation
				local function active()
					return on(feature) and loopGenerations[feature] == generation
				end
				while active() do
					local humanoid = getHumanoid()
					if humanoid and humanoid.Health > 0 then
						runFarmStep(step, active)
					end
					task.wait(interval)
				end
			end,
			disable = function()
				loopGenerations[feature] = (loopGenerations[feature] or 0) + 1
			end,
		}
	end

	-- Dropping ---------------------------------------------------------------------

	local function dropMoney(amount)
		local remote = getRemote("BankProcessRemote")
		if not remote then
			return false, "the drop remote was not found"
		end
		if amount <= 0 then
			return false, "set a drop amount first"
		end
		local wallet = getStat("Money")
		if wallet < amount then
			return false, "you only have " .. formatCash(wallet)
		end
		local remaining = amount
		while remaining > 0 do
			local chunk = math.min(remaining, DROP_LIMIT)
			local ok = pcall(function()
				remote:InvokeServer("Drop", tostring(chunk))
			end)
			if not ok then
				return false, "the server rejected the drop"
			end
			remaining = remaining - chunk
			if remaining > 0 then
				task.wait(0.5)
			end
		end
		return true
	end

	loopFeature("AutoDropMoney", 1.5, function()
		local amount = Arsenic.Values.DropAmount
		if amount <= 0 then
			notifyOnce("drop", "Set a Drop Amount for Auto Drop Money.")
			return
		end
		if getStat("Money") < amount then
			notifyOnce("drop", "Auto Drop Money is waiting: not enough cash in your wallet.")
			return
		end
		dropMoney(amount)
	end)

	-- Cash pickup ------------------------------------------------------------------

	local cashPrompts = setmetatable({}, { __mode = "k" })
	local cashCooldowns = setmetatable({}, { __mode = "k" })

	local function isCashPrompt(prompt)
		if not prompt:IsA("ProximityPrompt") or prompt:FindFirstAncestor("DelieveryRob") then
			return false
		end
		local dollas = Workspace:FindFirstChild("Dollas")
		if dollas and prompt:IsDescendantOf(dollas) then
			return true
		end
		local action = prompt.ActionText:lower()
		return prompt.ObjectText:sub(1, 1) == "$" and not action:find("buy") and not action:find("purchase")
	end

	track(Workspace.DescendantAdded:Connect(function(descendant)
		if descendant:IsA("ProximityPrompt") then
			task.defer(function()
				if descendant.Parent and isCashPrompt(descendant) then
					cashPrompts[descendant] = true
				end
			end)
		end
	end))

	local function getCashTargets()
		local targets = {}
		for prompt in pairs(cashPrompts) do
			if prompt.Parent then
				table.insert(targets, prompt)
			else
				cashPrompts[prompt] = nil
			end
		end
		local dollas = Workspace:FindFirstChild("Dollas")
		if dollas then
			for _, descendant in ipairs(dollas:GetDescendants()) do
				local kind = descendant:IsA("ProximityPrompt") or descendant:IsA("ClickDetector") or descendant:IsA("TouchTransmitter")
				if kind and not cashPrompts[descendant] then
					table.insert(targets, descendant)
				end
			end
		end
		local now, ready = os.clock(), {}
		for _, target in ipairs(targets) do
			local position = getWorldPosition(target.Parent)
			local enabled = not target:IsA("ProximityPrompt") or target.Enabled
			if enabled and isOnMap(position) and (cashCooldowns[target] or 0) <= now then
				table.insert(ready, target)
			end
		end
		return sortByDistance(ready)
	end

	loopFeature("AutoPickupCash", 0.5, function(active)
		local targets = getCashTargets()
		if #targets == 0 then
			return
		end
		local root = getRoot()
		local startCFrame = root and root.CFrame
		for index = 1, math.min(#targets, 10) do
			if not active() then
				break
			end
			local target = targets[index]
			cashCooldowns[target] = os.clock() + 3
			if target.Parent then
				if target:IsA("ProximityPrompt") then
					usePrompt(target)
				else
					local position = getWorldPosition(target.Parent)
					if position and goNear(position, 3) then
						tryPickup(getRoot(), target)
					end
				end
				task.wait(0.3)
			end
		end
		returnTo(startCFrame)
	end)

	local enableCashPickup = Features.AutoPickupCash.enable
	Features.AutoPickupCash.enable = function()
		for _, descendant in ipairs(Workspace:GetDescendants()) do
			if descendant:IsA("ProximityPrompt") and isCashPrompt(descendant) then
				cashPrompts[descendant] = true
			end
		end
		enableCashPickup()
	end

	-- ATM --------------------------------------------------------------------------

	local function closeAtmGui()
		local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
		if not playerGui then
			return
		end
		for _, gui in ipairs(playerGui:GetChildren()) do
			if gui.Name:upper():find("ATM") then
				local close = gui:FindFirstChild("close", true)
				if close and close:IsA("RemoteEvent") then
					pcall(function()
						close:FireServer()
					end)
				elseif gui:IsA("ScreenGui") then
					gui.Enabled = false
				end
			end
		end
	end

	-- Tries the bank remote where we stand first; only walks to an ATM if the server wants one.
	local function bankTransfer(action, amount)
		local remote = getRemote("BankAction")
		if not remote then
			return false, "the bank remote was not found"
		end
		local statName = action == "depo" and "Bank" or "Money"
		local function attempt()
			local before = getStat(statName)
			remote:FireServer(action, tostring(amount))
			return waitUntil(function()
				return getStat(statName) ~= before
			end, 1.5)
		end
		if attempt() then
			return true
		end

		local atms = sortByDistance(findPrompts("atm", function(prompt)
			return prompt.ActionText == "Use Bank"
		end))
		if #atms == 0 then
			return false, "no ATM was found"
		end
		local root = getRoot()
		local startCFrame = root and root.CFrame
		if not usePrompt(atms[1]) then
			return false, "could not reach an ATM"
		end
		task.wait(0.4)
		local ok = attempt()
		closeAtmGui()
		returnTo(startCFrame)
		if not ok then
			return false, "the bank did not accept it"
		end
		return true
	end

	local function deposit(amount)
		local wallet = getStat("Money")
		amount = amount > 0 and amount or wallet
		if amount <= 0 or wallet < amount then
			return false, "you only have " .. formatCash(wallet) .. " in your wallet"
		end
		return bankTransfer("depo", amount)
	end

	local function withdraw(amount)
		local bank = getStat("Bank")
		amount = amount > 0 and amount or bank
		if amount <= 0 or bank < amount then
			return false, "you only have " .. formatCash(bank) .. " in the bank"
		end
		return bankTransfer("with", amount)
	end

	-- Deposits the Deposit Amount whenever the wallet holds it (the whole wallet when no amount is set).
	loopFeature("AutoDeposit", 3, function()
		local amount = Arsenic.Values.DepositAmount
		local wallet = getStat("Money")
		if wallet <= 0 or (amount > 0 and wallet < amount) then
			return
		end
		local ok, reason = deposit(amount)
		if not ok then
			notifyOnce("deposit", "Auto Deposit: " .. tostring(reason) .. ".")
		end
	end)

	-- Keeps the wallet topped up to the Withdraw Amount from the bank.
	loopFeature("AutoWithdraw", 3, function()
		local target = Arsenic.Values.WithdrawAmount
		if target <= 0 then
			notifyOnce("withdraw", "Set a Withdraw Amount for Auto Withdraw Money.")
			return
		end
		local missing = target - getStat("Money")
		local amount = math.min(missing, getStat("Bank"))
		if missing <= 0 or amount <= 0 then
			return
		end
		local ok, reason = withdraw(amount)
		if not ok then
			notifyOnce("withdraw", "Auto Withdraw: " .. tostring(reason) .. ".")
		end
	end)

	-- Cleaning ---------------------------------------------------------------------

	-- The counter the server is counting our money at. It refuses to start a second one
	-- ("Already using another!"), so the bag has to be collected from this one.
	local activeCounter = nil

	local function counterGrab(counterPrompt)
		local counter = counterPrompt and counterPrompt:FindFirstAncestor("CounterM")
		return counter and counter:FindFirstChild("GrabPrompt", true)
	end

	local function sawMessage(fragment, since)
		return gameMessage.time >= since and gameMessage.text:find(fragment, 1, true) ~= nil
	end

	-- Count the dirty stack at a laundromat counter, bag it, and cash the bag in at the bank.
	local function cleanMoney()
		local dirty = getStat("FilthyStack")
		local bread = getTool("Bread")
		local resuming = activeCounter ~= nil and activeCounter.Parent ~= nil
		if dirty <= 0 and not bread and not resuming then
			notify("You have no dirty money to clean.")
			return
		end
		local wanted = dirty > 0 and "Count Money" or "Count Bread"
		local root = getRoot()
		local startCFrame = root and root.CFrame
		local startTotal = getStat("Money") + getStat("Bank")

		-- Re-pressed only when the press was lost to a pull-back; a press that lands is never repeated.
		local function startCounting(counterPrompt)
			for _ = 1, CLEAN_STEP_ATTEMPTS do
				if wanted == "Count Bread" then
					equipTool(getTool("Bread"))
				end
				local pressedAt = os.clock()
				if usePrompt(counterPrompt) then
					task.wait(0.5)
					return sawMessage("already using", pressedAt) and "busy" or "started"
				end
			end
			return "failed"
		end

		local counterPrompt = resuming and activeCounter or nil
		if not counterPrompt then
			local counters = {}
			for _, prompt in ipairs(findPrompts("counters", function(prompt)
				return prompt.Name == "CashPrompt"
			end)) do
				if prompt.ObjectText == wanted and prompt.Enabled and counterGrab(prompt) then
					table.insert(counters, prompt)
				end
			end
			if #counters == 0 then
				notify("No free money counter was found.")
				return
			end
			counterPrompt = sortByDistance(counters)[1]
			local result = startCounting(counterPrompt)
			if result == "failed" then
				notify("Could not reach the money counter (the anti-teleport kept pulling you back).")
				returnTo(startCFrame)
				return
			elseif result == "busy" then
				-- Already counting somewhere from an earlier run: take whichever bag becomes ours.
				counterPrompt = nil
			end
			activeCounter = counterPrompt
		end
		notify(counterPrompt and "Counting your money..." or "Your money is already being counted; waiting for the bag...")

		local function readyGrabs()
			local grabs = {}
			if counterPrompt then
				local grab = counterGrab(counterPrompt)
				if grab and grab.Enabled then
					table.insert(grabs, grab)
				end
				return grabs
			end
			for _, grab in ipairs(findPrompts("bags", function(prompt)
				return prompt.Name == "GrabPrompt" and prompt:FindFirstAncestor("CounterM") ~= nil
			end)) do
				if grab.Enabled then
					table.insert(grabs, grab)
				end
			end
			return sortByDistance(grabs)
		end

		local bag
		local deadline = os.clock() + COUNTING_TIMEOUT
		while not bag and os.clock() < deadline and not Arsenic.Destroyed do
			for _, grab in ipairs(readyGrabs()) do
				local before = snapshotTools()
				if usePrompt(grab) then
					bag = waitForNewTool(before, 3)
				end
				if bag then
					break
				end
			end
			if not bag then
				task.wait(1)
			end
		end
		if not bag then
			notify("The money bag was not ready yet. Run Auto Clean Money again to collect it.")
			returnTo(startCFrame)
			return
		end
		activeCounter = nil

		local atmMoney = Workspace:FindFirstChild("ATMMoney")
		local bankPrompt = atmMoney and atmMoney:FindFirstChildWhichIsA("ProximityPrompt", true)
		if bankPrompt then
			for _ = 1, CLEAN_STEP_ATTEMPTS do
				equipTool(bag)
				if usePrompt(bankPrompt) and waitUntil(function()
					return bag.Parent == nil or getStat("Money") + getStat("Bank") > startTotal
				end, 5) then
					break
				end
			end
		end
		returnTo(startCFrame)

		local gained = getStat("Money") + getStat("Bank") - startTotal
		if gained > 0 then
			notify("Cleaned " .. formatCash(gained) .. ".")
		elseif bag.Parent then
			notify("The bank did not take the money bag; it is still in your inventory.")
		else
			notify("Money bag handed in at the bank.")
		end
	end

	-- Jobs -------------------------------------------------------------------------

	local function childPrompt(parent, childName)
		local child = parent and parent:FindFirstChild(childName)
		return child and child:FindFirstChildWhichIsA("ProximityPrompt", true)
	end

	-- `toggles` jobs quit through their start prompt ("Start/End Job", "Start / Quit"); the others
	-- are only quit when their prompt offers it while working.
	local JOBS = {
		{
			key = "construction",
			name = "Construction",
			toggles = true,
			active = function()
				return LocalPlayer:GetAttribute("WorkingJob") == true
			end,
			prompt = function()
				return childPrompt(Workspace:FindFirstChild("ConstructionStuff"), "Start Job")
			end,
		},
		{
			key = "deli",
			name = "Deli",
			toggles = true,
			active = function()
				return LocalPlayer:GetAttribute("IsWorkingDeli") == true
			end,
			prompt = function()
				return childPrompt(Workspace:FindFirstChild("DeliJob"), "Start")
			end,
		},
		{
			key = "janitor",
			name = "Janitor",
			active = function()
				return findTools(function(tool)
					return tool.Name:lower():find("mop") ~= nil
				end)[1] ~= nil
			end,
			prompt = function()
				local bucket = Workspace:FindFirstChild("Janitor Bucket")
				return bucket and bucket:FindFirstChildWhichIsA("ProximityPrompt", true)
			end,
		},
		{
			key = "delivery",
			name = "Delivery",
			active = function()
				local target = LocalPlayer:FindFirstChild("TargetWall")
				return target ~= nil and target.Value ~= nil
			end,
			prompt = function()
				local rob = Workspace:FindFirstChild("DelieveryRob")
				return rob and rob:FindFirstChild("StartJob", true)
			end,
		},
	}

	local function offersQuit(job, prompt)
		if job.toggles then
			return true
		end
		local text = (prompt.ActionText .. " " .. prompt.ObjectText):lower()
		return text:find("quit", 1, true) or text:find("end", 1, true) or text:find("stop", 1, true)
	end

	-- Filled in with the deli autofarm (must finish the current grill before quitting).
	local deliJobControl = {}

	-- Some jobs block starting another while they are active, so quit every other one first.
	local function endOtherJobs(current)
		for _, job in ipairs(JOBS) do
			if job.key ~= current and job.active() then
				if job.key == "deli" and deliJobControl.finishThenQuit then
					notify("Finishing the deli grill before quitting...")
					if not deliJobControl.finishThenQuit() then
						notifyOnce("quit_deli", "Could not quit the Deli job; quit it manually.")
						return false
					end
				else
					local prompt = job.prompt()
					if prompt and prompt:IsA("ProximityPrompt") and offersQuit(job, prompt) then
						notify("Quitting the " .. job.name .. " job first...")
						usePrompt(prompt)
						if not waitUntil(function()
							return not job.active()
						end, 4) then
							notifyOnce("quit_" .. job.key, "Could not quit the " .. job.name .. " job; quit it manually.")
							return false
						end
					end
				end
			end
		end
		return true
	end

	local constructionIndex = 1
	local woodNames = {}

	local function findWood()
		return findTools(function(tool)
			local name = tool.Name:lower()
			return woodNames[tool.Name] or name:find("wood") or name:find("ply") or name:find("plank") or name:find("board")
		end)[1]
	end

	loopFeature("AutoConstruction", 0.3, function(active)
		local stuff = Workspace:FindFirstChild("ConstructionStuff")
		if not stuff then
			notifyOnce("construction", "The construction site was not found.")
			return
		end
		if not endOtherJobs("construction") then
			return
		end
		local function prompt(name)
			local part = stuff:FindFirstChild(name)
			return part and part:FindFirstChildWhichIsA("ProximityPrompt")
		end

		if not LocalPlayer:GetAttribute("WorkingJob") then
			usePrompt(prompt("Start Job"), true)
			if not waitUntil(function()
				return LocalPlayer:GetAttribute("WorkingJob")
			end, 3) then
				notifyOnce("construction", "Could not start the construction job.")
				return
			end
		end

		local wood = findWood()
		if not wood then
			local before = snapshotTools()
			usePrompt(prompt("Grab Wood"), true)
			wood = waitForNewTool(before, 3)
			if not wood then
				return
			end
			woodNames[wood.Name] = true
		end
		equipTool(wood)

		local walls = {}
		for _, child in ipairs(stuff:GetChildren()) do
			if child.Name:match("^Wall%d+ Prompt") then
				local wallPrompt = child:FindFirstChildWhichIsA("ProximityPrompt")
				if wallPrompt then
					table.insert(walls, wallPrompt)
				end
			end
		end
		-- Closest walls to the wood pile first, so each round trip stays short.
		local woodPosition = promptPosition(prompt("Grab Wood"))
		table.sort(walls, function(a, b)
			local aPosition, bPosition = promptPosition(a), promptPosition(b)
			if woodPosition and aPosition and bPosition then
				return (aPosition - woodPosition).Magnitude < (bPosition - woodPosition).Magnitude
			end
			return a.Parent.Name < b.Parent.Name
		end)
		-- Stay on the wall that last worked; move on when it stops taking wood.
		for attempt = 0, #walls - 1 do
			if not active() then
				return
			end
			local index = (constructionIndex + attempt - 1) % #walls + 1
			local placed = LocalPlayer:GetAttribute("PlacedBlocks") or 0
			if walls[index].Enabled and usePrompt(walls[index], true) then
				if waitUntil(function()
					return (LocalPlayer:GetAttribute("PlacedBlocks") or 0) ~= placed or wood.Parent == nil
				end, 2.5) then
					constructionIndex = index
					return
				end
			end
		end
	end)

	local studioState = { phase = "idle", recordingEnds = 0 }
	local studioConnection = nil

	local function hookStudioRemote()
		if studioConnection then
			return
		end
		local remote = getRemote("StudioJobRemote")
		if not remote then
			return
		end
		studioConnection = track(remote.OnClientEvent:Connect(function(kind, data)
			if not on("AutoStudio") then
				return
			end
			if kind == "OpenBoxes" then
				studioState.phase = "boxes"
				task.delay(0.6, function()
					pcall(function()
						remote:FireServer("Pick", math.random(1, 5))
					end)
				end)
			elseif kind == "Recording" then
				studioState.phase = "recording"
				studioState.recordingEnds = os.clock() + (tonumber(data) or 15) + 2
			elseif kind == "Reveal" then
				studioState.phase = "idle"
				local pay = type(data) == "table" and tonumber(data.Pay)
				if pay then
					notify("Studio session paid " .. formatCash(pay) .. ".")
				end
			elseif kind == "Failed" then
				studioState.phase = "idle"
			end
		end))
	end

	-- Everything happens inside the RapZone; the session fails if the character moves while recording.
	loopFeature("AutoStudio", 0.5, function(active)
		hookStudioRemote()
		local studio = Workspace:FindFirstChild("StudioJobV1")
		if not studio then
			notifyOnce("studio", "The studio was not found.")
			return
		end
		local zone = studio:FindFirstChild("RapZone")
		local startPart, recordPart = studio:FindFirstChild("StartSess"), studio:FindFirstChild("RecordSession")
		local startPrompt = startPart and startPart:FindFirstChildWhichIsA("ProximityPrompt", true)
		local recordPrompt = recordPart and recordPart:FindFirstChildWhichIsA("ProximityPrompt", true)
		if not (zone and startPrompt and recordPrompt) then
			return
		end
		if studioState.phase == "idle" and not endOtherJobs("studio") then
			return
		end
		if not goNear(zone.Position, 3) then
			return
		end

		if studioState.phase == "recording" then
			waitUntil(function()
				return studioState.phase ~= "recording" or not active()
			end, math.max(studioState.recordingEnds - os.clock(), 0))
			if studioState.phase == "recording" and os.clock() >= studioState.recordingEnds then
				studioState.phase = "idle"
			end
			return
		end
		if recordPrompt.Enabled then
			firePrompt(recordPrompt)
			waitUntil(function()
				return studioState.phase == "recording"
			end, 5)
			return
		end
		if studioState.phase == "boxes" then
			waitUntil(function()
				return recordPrompt.Enabled or studioState.phase ~= "boxes"
			end, 8)
			studioState.phase = "idle"
			return
		end
		if getStat("Money") < STUDIO_SESSION_COST then
			notifyOnce("studio", "A studio session costs " .. formatCash(STUDIO_SESSION_COST) .. "; you don't have enough cash.")
			return
		end
		firePrompt(startPrompt)
		waitUntil(function()
			return studioState.phase ~= "idle" or recordPrompt.Enabled
		end, 8)
	end)

	loopFeature("AutoJanitor", 0.5, function(active)
		local team = LocalPlayer.Team
		if not (team and team.Name:lower():find("prison")) then
			notifyOnce("janitor", "The janitor job only works while you are in prison.")
			return
		end
		if not endOtherJobs("janitor") then
			return
		end
		local mop = findTools(function(tool)
			return tool.Name:lower():find("mop") ~= nil
		end)[1]
		if not mop then
			local bucket = Workspace:FindFirstChild("Janitor Bucket")
			local before = snapshotTools()
			usePrompt(bucket and bucket:FindFirstChildWhichIsA("ProximityPrompt", true))
			mop = waitForNewTool(before, 3)
		end
		if mop then
			equipTool(mop)
		end

		local cleaned = 0
		for _, folder in ipairs(Workspace:GetChildren()) do
			if folder.Name == "DirtPiles" then
				for _, pilePrompt in ipairs(folder:GetDescendants()) do
					if not active() then
						return
					end
					if pilePrompt:IsA("ProximityPrompt") and pilePrompt.Enabled and usePrompt(pilePrompt) then
						cleaned = cleaned + 1
						task.wait(0.8)
					end
				end
			end
		end
		if cleaned == 0 then
			task.wait(2)
		end
	end)

	local function enabledPrompts(container)
		local list = {}
		if container then
			for _, descendant in ipairs(container:GetDescendants()) do
				if descendant:IsA("ProximityPrompt") and descendant.Enabled then
					table.insert(list, descendant)
				end
			end
		end
		return list
	end

	-- Start job -> smash the target wall -> grab the bread -> throw it in the crate (dirty money).
	loopFeature("AutoDelivery", 0.5, function(active)
		local rob = Workspace:FindFirstChild("DelieveryRob")
		if not rob then
			notifyOnce("delivery", "The delivery job was not found.")
			return
		end
		if not endOtherJobs("delivery") then
			return
		end
		local targetValue = LocalPlayer:FindFirstChild("TargetWall")
		local spot = targetValue and targetValue.Value
		local breakPrompt = spot and spot:FindFirstChild("BreakWall", true)
		local spotBusy = spot and ((breakPrompt and breakPrompt.Enabled) or #enabledPrompts(spot:FindFirstChild("Cash")) > 0)

		local breads = findTools(function(tool)
			return tool.Name == "Bread"
		end)
		if #breads > 0 and not spotBusy then
			local crate = rob:FindFirstChild("Crate1")
			local fill = crate and crate:FindFirstChild("Fill", true)
			if not fill then
				return
			end
			if not fill.Enabled then
				notifyOnce("crate", "The delivery crate is full; waiting for it to reset.", 60)
				task.wait(3)
				return
			end
			for _, bread in ipairs(breads) do
				if not active() then
					return
				end
				equipTool(bread)
				usePrompt(fill)
				if not waitUntil(function()
					return bread.Parent == nil
				end, 2.5) then
					return
				end
			end
			return
		end

		local hammer = getTool("Sledge Hammer")
		if not hammer then
			notify("Buying a Sledge Hammer for the delivery job...")
			buyItem("Sledge Hammer")
			hammer = getTool("Sledge Hammer")
			if not hammer then
				task.wait(5)
				return
			end
		end

		if not spot then
			usePrompt(rob:FindFirstChild("StartJob", true))
			waitUntil(function()
				local value = LocalPlayer:FindFirstChild("TargetWall")
				return value and value.Value ~= nil
			end, 4)
			targetValue = LocalPlayer:FindFirstChild("TargetWall")
			spot = targetValue and targetValue.Value
			if not spot then
				notifyOnce("delivery", "Could not start the delivery job (it may be on cooldown).")
				task.wait(5)
				return
			end
			breakPrompt = spot:FindFirstChild("BreakWall", true)
		end

		for _ = 1, 12 do
			if not (active() and breakPrompt and breakPrompt.Parent and breakPrompt.Enabled) then
				break
			end
			equipTool(hammer)
			usePrompt(breakPrompt)
			task.wait(0.6)
		end

		local cash = spot:FindFirstChild("Cash")
		waitUntil(function()
			return #enabledPrompts(cash) > 0
		end, 3)
		for _, cashPrompt in ipairs(enabledPrompts(cash)) do
			if not active() then
				return
			end
			usePrompt(cashPrompt)
			task.wait(0.3)
		end
	end)

	local deliFood = { ["Chop Cheese"] = true, ChopCheese = true }
	local deliIngredients = {}
	local deliLoopGen = 0
	local deliFinishing = false

	local function isMine(owner)
		return owner ~= nil and (owner == LocalPlayer or tostring(owner) == LocalPlayer.Name or tostring(owner) == tostring(LocalPlayer.UserId))
	end

	local function deliSite()
		local deli = Workspace:FindFirstChild("DeliJob")
		local grills = deli and deli:FindFirstChild("Grills")
		return deli, grills
	end

	local function deliChildPrompt(deli, name)
		local part = deli and deli:FindFirstChild(name)
		return part and part:FindFirstChildWhichIsA("ProximityPrompt")
	end

	local function classifyDeliGrills(grills)
		local finishedList, cookingPrompt, freeList = {}, nil, {}
		if not grills then
			return finishedList, cookingPrompt, freeList
		end
		for _, grill in ipairs(grills:GetChildren()) do
			local smoke = grill:FindFirstChild("GrillSmoke")
			local grillPrompt = smoke and smoke:FindFirstChildWhichIsA("ProximityPrompt")
			if grillPrompt and smoke:IsA("BasePart") and isOnMap(smoke.Position) then
				local owner = smoke:GetAttribute("Owner")
				if isMine(owner) and smoke:GetAttribute("Finished") then
					table.insert(finishedList, grillPrompt)
				elseif isMine(owner) and smoke:GetAttribute("Cooking") then
					cookingPrompt = cookingPrompt or grillPrompt
				elseif (owner == nil or owner == "" or owner == false or owner == 0)
					and not smoke:GetAttribute("Cooking")
					and not smoke:GetAttribute("Finished")
				then
					table.insert(freeList, grillPrompt)
				end
			end
		end
		return finishedList, cookingPrompt, freeList
	end

	local function heldDeliFood()
		return findTools(function(tool)
			return deliFood[tool.Name] == true
		end)
	end

	local function deliHasPendingWork(grills)
		local finishedList, cookingPrompt = classifyDeliGrills(grills)
		return cookingPrompt ~= nil or #finishedList > 0 or #heldDeliFood() > 0
	end

	local function collectDeliFinished(grills, keepGoing)
		local finishedList = classifyDeliGrills(grills)
		for _, grillPrompt in ipairs(finishedList) do
			if keepGoing and not keepGoing() then
				return false
			end
			local before = snapshotTools()
			if usePrompt(grillPrompt) then
				local item = waitForNewTool(before, 3)
				if item then
					deliFood[item.Name] = true
				end
			end
		end
		return true
	end

	local function sellDeliFood(deli, keepGoing)
		local food = heldDeliFood()
		if #food == 0 then
			return true
		end
		local sellPrompt = deliChildPrompt(deli, "Sell")
		for _, item in ipairs(food) do
			if keepGoing and not keepGoing() then
				return false
			end
			equipTool(item)
			usePrompt(sellPrompt)
			waitUntil(function()
				return item.Parent == nil
			end, 2)
		end
		return true
	end

	local function quitDeliJob()
		if not LocalPlayer:GetAttribute("IsWorkingDeli") then
			return true
		end
		local startPrompt = deliChildPrompt(select(1, deliSite()), "Start")
		if not startPrompt then
			return false
		end
		usePrompt(startPrompt)
		return waitUntil(function()
			return not LocalPlayer:GetAttribute("IsWorkingDeli")
		end, 4)
	end

	-- Wait out the current grill, counter the food, then quit. Never quit mid-cook.
	local function finishDeliThenQuit(keepGoing)
		keepGoing = keepGoing or function()
			return true
		end
		local deli, grills = deliSite()
		if LocalPlayer:GetAttribute("IsWorkingDeli") and grills and deliHasPendingWork(grills) then
			notify("Finishing the current grill before quitting deli...")
			local deadline = os.clock() + 120
			while keepGoing() and os.clock() < deadline do
				local _, cookingPrompt = classifyDeliGrills(grills)
				if not cookingPrompt then
					break
				end
				goNear(promptPosition(cookingPrompt), 3)
				task.wait(0.35)
			end
			if not collectDeliFinished(grills, keepGoing) then
				return false
			end
			if not sellDeliFood(deli, keepGoing) then
				return false
			end
		elseif #heldDeliFood() > 0 then
			if not sellDeliFood(deli, keepGoing) then
				return false
			end
		end
		return quitDeliJob()
	end

	function deliJobControl.finishThenQuit()
		deliFinishing = true
		Arsenic.Enabled.AutoDeli = false
		deliLoopGen = deliLoopGen + 1
		local ok = finishDeliThenQuit()
		deliFinishing = false
		return ok
	end

	-- Start -> cook -> pick up ALL finished -> counter -> start next.
	-- Turning the toggle off waits for the current grill + counter before quitting.
	Features.AutoDeli = {
		enable = function()
			deliFinishing = false
			local generation = deliLoopGen + 1
			deliLoopGen = generation
			local function alive()
				return deliLoopGen == generation and (on("AutoDeli") or deliFinishing)
			end
			local function farming()
				return deliLoopGen == generation and on("AutoDeli") and not deliFinishing
			end
			while alive() do
				local humanoid = getHumanoid()
				if humanoid and humanoid.Health > 0 then
					runFarmStep(function()
						if deliFinishing or not on("AutoDeli") then
							if LocalPlayer:GetAttribute("IsWorkingDeli") or #heldDeliFood() > 0 then
								finishDeliThenQuit(alive)
							end
							deliFinishing = false
							deliLoopGen = deliLoopGen + 1
							return
						end

						local deli, grills = deliSite()
						if not grills then
							notifyOnce("deli", "The deli was not found.")
							return
						end
						if not endOtherJobs("deli") then
							return
						end

						if not LocalPlayer:GetAttribute("IsWorkingDeli") then
							usePrompt(deliChildPrompt(deli, "Start"))
							if not waitUntil(function()
								return LocalPlayer:GetAttribute("IsWorkingDeli")
							end, 3) then
								notifyOnce("deli", "Could not start the deli job.")
								return
							end
						end

						-- 1) Pick up every finished chop cheese on our grills.
						if not collectDeliFinished(grills, farming) then
							return
						end

						-- 2) Take all held chop cheese to the counter.
						if not sellDeliFood(deli, farming) then
							return
						end
						if not farming() then
							return
						end

						-- 3) Start another sandwich on a free grill.
						local _, cookingPrompt, freeList = classifyDeliGrills(grills)
						local free = freeList[1]
						if free then
							local ingredient = findTools(function(tool)
								return deliIngredients[tool.Name] == true
							end)[1]
							if not ingredient then
								local before = snapshotTools()
								usePrompt(deliChildPrompt(deli, "GrabIngridence"))
								ingredient = waitForNewTool(before, 3)
								if ingredient then
									deliIngredients[ingredient.Name] = true
								end
							end
							if ingredient and farming() then
								equipTool(ingredient)
								usePrompt(free)
								waitUntil(function()
									local smoke = free.Parent
									return smoke and (smoke:GetAttribute("Cooking") or isMine(smoke:GetAttribute("Owner")))
								end, 3)
								return
							end
						end

						if cookingPrompt then
							goNear(promptPosition(cookingPrompt), 3)
							task.wait(0.35)
						end
					end)
				end
				task.wait(0.3)
			end
		end,
		disable = function()
			if deliFinishing then
				return
			end
			local _, grills = deliSite()
			local pending = LocalPlayer:GetAttribute("IsWorkingDeli") and grills and deliHasPendingWork(grills)
			if pending then
				-- Keep the farm loop alive until the current grill is done and sold.
				deliFinishing = true
				notify("Finishing the current grill before quitting deli...")
			else
				deliLoopGen = deliLoopGen + 1
				if LocalPlayer:GetAttribute("IsWorkingDeli") or #heldDeliFood() > 0 then
					task.spawn(function()
						local waited = 0
						while playerActionBusy and waited < 10 do
							task.wait(0.1)
							waited = waited + 0.1
						end
						if playerActionBusy then
							return
						end
						playerActionBusy = true
						local ok, err = pcall(finishDeliThenQuit)
						playerActionBusy = false
						if not ok then
							warn("[Arsenic] " .. tostring(err))
						end
					end)
				end
			end
		end,
	}

	-- Trash ------------------------------------------------------------------------

	local TRASH_FLAGGED_COOLDOWN = 300
	local trashCooldowns = setmetatable({}, { __mode = "k" })
	local pawnNames = nil

	local function getPawnNames()
		if pawnNames then
			return pawnNames
		end
		pawnNames = {}
		local module = ReplicatedStorage:FindFirstChild("PawnTools")
		local ok, list = pcall(function()
			return require(module)
		end)
		if ok and type(list) == "table" then
			for name in pairs(list) do
				pawnNames[name] = true
			end
		end
		return pawnNames
	end

	loopFeature("AutoFarmTrash", 0.3, function()
		local now, ready = os.clock(), {}
		for _, prompt in ipairs(findPrompts("dumpsters", function(prompt)
			return prompt.Parent ~= nil and prompt.Parent.Name == "DumpsterPromt"
		end)) do
			if prompt.Enabled and (trashCooldowns[prompt] or 0) <= now then
				table.insert(ready, prompt)
			end
		end
		if #ready == 0 then
			task.wait(2)
			return
		end
		local dumpster = sortByDistance(ready)[1]
		local before = snapshotTools()
		local flagMark = teleportFlagCount
		usePrompt(dumpster)
		local loot = waitForNewTool(before, 2)
		if teleportFlagCount ~= flagMark and not loot then
			-- Some dumpsters sit where the anti-teleport always pulls us back; leave those for a while.
			trashCooldowns[dumpster] = os.clock() + TRASH_FLAGGED_COOLDOWN
		else
			trashCooldowns[dumpster] = os.clock() + (loot and 30 or 90)
		end
	end)

	loopFeature("AutoSellTrash", 2, function(active)
		local names = getPawnNames()
		local items = findTools(function(tool)
			return names[tool.Name] == true
		end)
		local pawn = Workspace:FindFirstChild("SellPawn")
		local remote = getRemote("PawnRemote")
		if #items == 0 or not (pawn and remote) then
			return
		end
		local root = getRoot()
		local startCFrame = root and root.CFrame
		if not goNear(getWorldPosition(pawn), 6) then
			return
		end
		for _, item in ipairs(items) do
			if not active() then
				break
			end
			if item.Parent then
				remote:FireServer(item.Name)
				waitUntil(function()
					return item.Parent == nil
				end, 1)
				task.wait(0.55)
			end
		end
		if not on("AutoFarmTrash") then
			returnTo(startCFrame)
		end
	end)

	-- Infinite money ----------------------------------------------------------------

	local ICE_FRUIT_CUP = "Ice-Fruit Cupz"
	local ICE_FRUIT_INGREDIENTS = { "FijiWater", "FreshWater", "Ice-Fruit Bag", ICE_FRUIT_CUP }
	local DIRTY_CAP = 990000
	local MIX_ORDER = { "FijiWater", "FreshWater", "Ice-Fruit Bag", ICE_FRUIT_CUP }
	local COOK_TIMEOUT = 180
	local SALE_VALUE = 5800
	local SELL_EXTRA_PRESSES = 40
	local SELL_PRESSES_PER_FRAME = 25
	local SELL_FLOOD_TIME = 4
	local MAX_FLAGS_PER_RUN = 2
	-- Pot prompt texts that move the recipe forward; anything else (e.g. "Turn Off") is left alone.
	local COOK_ACTIONS = { "turn on", "mix", "add", "put", "pour", "fill", "collect", "take", "grab", "bottle" }

	local function missingIngredients()
		local missing = {}
		for _, name in ipairs(ICE_FRUIT_INGREDIENTS) do
			if not getTool(name) then
				table.insert(missing, name)
			end
		end
		return missing
	end

	-- The cup handed back by a finished cook; an empty cup bought from the shop looks the same.
	local cookedCup = nil

	local function hasCookedCup()
		return cookedCup ~= nil and cookedCup.Parent ~= nil and getTool(ICE_FRUIT_CUP) ~= nil
	end

	local function cupSignature(tool)
		local parts = { "tip=" .. tool.ToolTip, "tex=" .. tool.TextureId }
		for name, value in pairs(tool:GetAttributes()) do
			table.insert(parts, name .. "=" .. tostring(value))
		end
		for _, child in ipairs(tool:GetChildren()) do
			table.insert(parts, child.ClassName .. ":" .. child.Name)
		end
		table.sort(parts)
		return table.concat(parts, "|")
	end

	local function snapshotCups()
		local cups = {}
		for _, tool in ipairs(findTools(function(tool)
			return tool.Name == ICE_FRUIT_CUP
		end)) do
			cups[tool] = cupSignature(tool)
		end
		return cups
	end

	-- A cup that is new or has changed since `before` is the filled one.
	local function changedCup(before)
		return findTools(function(tool)
			return tool.Name == ICE_FRUIT_CUP and before[tool] ~= cupSignature(tool)
		end)[1]
	end

	-- Mixing puts everything except the cup into the pot.
	local function ingredientsUsed()
		return not getTool("FijiWater") and not getTool("FreshWater") and not getTool("Ice-Fruit Bag")
	end

	local function getSellPrompt()
		local sellPart = Workspace:FindFirstChild("IceFruit Sell")
		return sellPart and sellPart:FindFirstChildWhichIsA("ProximityPrompt", true)
	end

	-- Picks the free pot that makes the shortest route from here to the pot and on to the seller.
	local function findFreePot()
		local folder = Workspace:FindFirstChild("CookingPots")
		local sellPosition = promptPosition(getSellPrompt())
		local best, bestScore = nil, math.huge
		for _, pot in ipairs(folder and folder:GetChildren() or {}) do
			local cookPart = pot:FindFirstChild("CookPart")
			local prompt = cookPart and cookPart:FindFirstChildWhichIsA("ProximityPrompt")
			local owner = pot:FindFirstChild("Owner")
			local ownerValue = owner and owner:IsA("ObjectValue") and owner.Value
			if prompt and isOnMap(cookPart.Position) and (not ownerValue or ownerValue == LocalPlayer) then
				local score = distanceTo(cookPart.Position)
					+ (sellPosition and (cookPart.Position - sellPosition).Magnitude or 0)
				if score < bestScore then
					best, bestScore = prompt, score
				end
			end
		end
		return best
	end

	local function findOwnedPot()
		local folder = Workspace:FindFirstChild("CookingPots")
		local owned = {}
		for _, pot in ipairs(folder and folder:GetChildren() or {}) do
			local owner = pot:FindFirstChild("Owner")
			local cookPart = pot:FindFirstChild("CookPart")
			local prompt = cookPart and cookPart:FindFirstChildWhichIsA("ProximityPrompt")
			if prompt and owner and owner:IsA("ObjectValue") and owner.Value == LocalPlayer then
				table.insert(owned, prompt)
			end
		end
		return sortByDistance(owned)[1]
	end

	-- Everything comes from Tha Shop, so buy it all in one visit instead of one round trip per item.
	local function buyIngredients(missing, active)
		local shop
		for _, store in ipairs(STORES) do
			if store.name == "Tha Shop" then
				shop = store
			end
		end
		local part = shop and shop.locate()
		if not (part and goNear(part.Position, STORE_REACH - 2)) then
			return
		end
		for _, item in ipairs(missing) do
			if not active() then
				return
			end
			local passId = missingGamepass(shop, item)
			if passId then
				notify(gamepassMessage(item, passId))
			else
				local ok, reason = purchaseAt(shop, item)
				if not ok then
					notify(("Could not buy %s: %s."):format(item, tostring(reason)))
				end
			end
		end
	end

	local function isCookAction(text)
		text = text:lower()
		for _, action in ipairs(COOK_ACTIONS) do
			if text:find(action, 1, true) then
				return true
			end
		end
		return false
	end

	-- Every pot press needs an ingredient in hand ("Not holding any tool out!"): Turn On, then one
	-- Mix Items press per ingredient, waters first and the bag last. When the prompt is back on
	-- Turn On after mixing (or the ingredients are gone), the pot is cooking. It shows nothing
	-- while it cooks, so the cook is over when the cup changes, the ingredients get used up, or
	-- the usual cooking time has passed. Returns the cup.
	local function cookIceFruit(potPrompt, active)
		local deadline = os.clock() + COOK_TIMEOUT
		local cupsBefore = snapshotCups()
		local sawMix = false
		local pressIndex = 0
		local function cookingStarted()
			return ingredientsUsed() or (sawMix and potPrompt.ActionText:lower():find("turn on", 1, true) ~= nil)
		end
		while not cookingStarted() do
			if os.clock() > deadline or not active() then
				return nil
			end
			local action = potPrompt.ActionText:lower()
			if action:find("mix", 1, true) then
				sawMix = true
			end
			local held
			for _ = 1, #MIX_ORDER do
				pressIndex = pressIndex % #MIX_ORDER + 1
				held = getTool(MIX_ORDER[pressIndex])
				if held then
					break
				end
			end
			if potPrompt.Enabled and isCookAction(action) and held then
				equipTool(held)
				usePrompt(potPrompt)
				task.wait(0.9)
			else
				task.wait(1)
			end
		end

		notify("Ice-Fruit is cooking (about a minute)...")
		-- When the cook is done the pot asks to "Fill Pitcher Cup"; that press, cup in hand, fills it.
		local function readyToFill()
			return potPrompt.Enabled and potPrompt.ActionText:lower():find("fill", 1, true) ~= nil
		end
		local fillDeadline = os.clock() + COOK_TIMEOUT
		while active() and not readyToFill() do
			if os.clock() > fillDeadline then
				return nil
			end
			task.wait(0.5)
		end
		for _ = 1, 4 do
			if not active() then
				return nil
			end
			local cup = getTool(ICE_FRUIT_CUP)
			if not cup then
				return nil
			end
			local cupsBeforeFill = snapshotCups()
			equipTool(cup)
			usePrompt(potPrompt)
			if waitUntil(function()
				return not readyToFill() or changedCup(cupsBeforeFill) ~= nil
			end, 3) then
				task.wait(0.5)
				return changedCup(cupsBefore) or getTool(ICE_FRUIT_CUP)
			end
		end
		return nil
	end

	-- The first sale starts the server's countdown to take the cup away, and only presses that
	-- arrive before it runs out pay. So every press needed to reach the cap is sent at once,
	-- topped up every frame, with no pause after the first sale.
	local function burstSell(cup, active)
		local sellPrompt = getSellPrompt()
		if not (sellPrompt and cup and cup.Parent) then
			return 0, "the cooked cup or the seller was not found"
		end
		local position = promptPosition(sellPrompt)
		if not (position and goNear(position, math.max(sellPrompt.MaxActivationDistance - 1, 1.5))) then
			return 0, "could not reach the seller"
		end
		local function total()
			return getStat("Money") + getStat("FilthyStack")
		end
		local startTotal = total()
		equipTool(cup)
		task.wait(0.3)

		local needed = math.ceil((DIRTY_CAP - getStat("FilthyStack")) / SALE_VALUE)
		for _ = 1, needed + SELL_EXTRA_PRESSES do
			task.spawn(firePrompt, sellPrompt)
		end
		local deadline = os.clock() + SELL_FLOOD_TIME
		while active() and cup.Parent and getStat("FilthyStack") < DIRTY_CAP and os.clock() < deadline do
			if cup.Parent ~= getCharacter() then
				equipTool(cup)
			end
			for _ = 1, SELL_PRESSES_PER_FRAME do
				task.spawn(firePrompt, sellPrompt)
			end
			RunService.Heartbeat:Wait()
		end
		task.wait(1)

		local gained = total() - startTotal
		if gained <= 0 then
			return 0, "the seller would not buy the cup"
		end
		return gained, nil
	end

	local function infiniteMoney()
		local flagMark = teleportFlagCount
		local function active()
			return not Arsenic.Destroyed and teleportFlagCount - flagMark < MAX_FLAGS_PER_RUN
		end
		local function stopped()
			if active() then
				return false
			end
			notify("Infinite Money stopped: the anti-teleport flagged you twice and a third time could kick you. Wait a moment, then press it again.")
			return true
		end
		if getStat("FilthyStack") >= DIRTY_CAP then
			notify("Your dirty money is already at " .. formatCash(DIRTY_CAP) .. ". Use Auto Clean Money first.")
			return
		end

		-- Route: shop -> pot -> seller, with no trips back in between.
		if not hasCookedCup() then
			local ownedPot = findOwnedPot()
			local alreadyCooking = ownedPot ~= nil and getTool(ICE_FRUIT_CUP) ~= nil and ingredientsUsed()
			local missing = alreadyCooking and {} or missingIngredients()
			if #missing > 0 then
				buyIngredients(missing, active)
				if stopped() then
					return
				end
				missing = missingIngredients()
				if #missing > 0 then
					notify("Infinite Money: could not buy " .. table.concat(missing, ", ") .. ".")
					return
				end
			end
			local pot = alreadyCooking and ownedPot or findFreePot()
			if not pot then
				notify("Infinite Money: no free cooking pot was found.")
				return
			end
			if not alreadyCooking then
				notify("Starting to cook Ice-Fruit...")
			end
			cookedCup = cookIceFruit(pot, active)
			if stopped() then
				return
			end
			if not cookedCup then
				notify("Infinite Money: cooking did not finish. Press the button again to retry.")
				return
			end
			notify("Ice-Fruit is done cooking.")
		end

		notify("Selling Ice-Fruit...")
		local gained, reason = burstSell(cookedCup, active)
		if stopped() then
			return
		end
		if gained > 0 then
			notify("Infinite Money: +" .. formatCash(gained) .. " (dirty money is " .. formatCash(getStat("FilthyStack")) .. ").")
		else
			notify("Infinite Money: the sale did not go through (" .. tostring(reason) .. ").")
		end
		if gained <= 0 or not (cookedCup and cookedCup.Parent) then
			cookedCup = nil
		end
	end

	-- Market dupe — mirrors the working open-source TB3 timing:
	-- backpack → wait 0.5 → List → ping delay → Store → wait 2.5 → Remove → Grab → wait 1
	local DUPE_LIST_PRICE = 99999
	local DUPE_BAG_COOLDOWN = 1.65
	local marketBlacklistCache = nil
	local lastDupeToolName = nil
	local lastBagRemoteAt = 0

	local function getMarketBlacklist()
		if marketBlacklistCache then
			return marketBlacklistCache
		end
		marketBlacklistCache = {
			Fist = true,
			Fists = true,
			Phone = true,
		}
		local module = ReplicatedStorage:FindFirstChild("BlacklistedMarketTools")
		local ok, data = pcall(function()
			return require(module)
		end)
		if ok and type(data) == "table" and type(data.Blacklisted) == "table" then
			for _, name in ipairs(data.Blacklisted) do
				marketBlacklistCache[name] = true
			end
		end
		return marketBlacklistCache
	end

	local function countNamedTools(name)
		return #findTools(function(tool)
			return tool.Name == name
		end)
	end

	local function isDupeableTool(tool)
		return tool and tool:IsA("Tool") and not getMarketBlacklist()[tool.Name]
	end

	local function findOwnMarketListing(itemName)
		local marketItems = ReplicatedStorage:FindFirstChild("MarketItems")
		if not marketItems then
			return nil
		end
		for _, child in ipairs(marketItems:GetChildren()) do
			if child.Name == itemName and child:IsA("IntValue") then
				local owner = child:FindFirstChild("owner")
				if owner and tostring(owner.Value) == LocalPlayer.Name then
					return child
				end
			end
		end
		return nil
	end

	local function getDupePingMs()
		local ok, ping = pcall(function()
			local raw = LocalPlayer:GetNetworkPing()
			if type(raw) == "number" then
				-- Roblox returns seconds; some executors return a string.
				return raw < 10 and math.floor(raw * 1000) or math.floor(raw)
			end
			return tonumber(tostring(raw):match("%d+"))
		end)
		if ok and type(ping) == "number" and ping > 0 then
			return math.clamp(ping, 50, 300)
		end
		local t0 = os.clock()
		local temp = Instance.new("BoolValue")
		temp.Name = "ArsenicPing_" .. tostring(math.random(10000, 99999))
		temp.Parent = ReplicatedStorage
		task.wait(0.1)
		local ms = (os.clock() - t0) * 1000
		temp:Destroy()
		return math.clamp(ms, 50, 300)
	end

	local function waitBagCooldown(active)
		local waitFor = DUPE_BAG_COOLDOWN - (os.clock() - lastBagRemoteAt)
		if waitFor <= 0 then
			return true
		end
		local deadline = os.clock() + waitFor
		while os.clock() < deadline do
			if active and not active() then
				return false
			end
			task.wait(0.05)
		end
		return true
	end

	local function bagInvoke(backpackRemote, action, toolName, active)
		if not waitBagCooldown(active) then
			return false, "stopped"
		end
		local ok, result = pcall(function()
			return backpackRemote:InvokeServer(action, toolName)
		end)
		lastBagRemoteAt = os.clock()
		if not ok then
			return false, tostring(result)
		end
		if type(result) == "string" and result ~= "" and result ~= "Success" then
			local lower = result:lower()
			if lower:find("must wait", 1, true) then
				task.wait(DUPE_BAG_COOLDOWN)
				ok, result = pcall(function()
					return backpackRemote:InvokeServer(action, toolName)
				end)
				lastBagRemoteAt = os.clock()
				if ok and result == "Success" then
					return true, result
				end
				return false, type(result) == "string" and result or "bag cooldown"
			end
			return false, result
		end
		return true, result
	end

	local function pickDupeTool()
		local character = getCharacter()
		local backpack = LocalPlayer:FindFirstChildOfClass("Backpack")
		if character then
			local held = character:FindFirstChildOfClass("Tool")
			if isDupeableTool(held) then
				return held
			end
		end
		if lastDupeToolName then
			local named = findTools(function(tool)
				return tool.Name == lastDupeToolName
			end)[1]
			if named then
				return named
			end
		end
		if backpack then
			for _, child in ipairs(backpack:GetChildren()) do
				if isDupeableTool(child) then
					return child
				end
			end
		end
		return nil
	end

	local function pullStoredCopies(backpackRemote, toolName, active, maxGrabs)
		maxGrabs = maxGrabs or 12
		local idle = 0
		for _ = 1, maxGrabs do
			if active and not active() then
				return
			end
			local before = countNamedTools(toolName)
			local ok = bagInvoke(backpackRemote, "Grab", toolName, active)
			if not ok then
				return
			end
			task.wait(0.05)
			if countNamedTools(toolName) <= before then
				idle += 1
				if idle >= 2 then
					return
				end
			else
				idle = 0
			end
		end
	end

	local function bankExtras(backpackRemote, toolName, active)
		local humanoid = getHumanoid()
		if humanoid then
			pcall(function()
				humanoid:UnequipTools()
			end)
			task.wait(0.1)
		end
		local banked = 0
		while countNamedTools(toolName) > 1 do
			if active and not active() then
				return false, "stopped", banked
			end
			local ok, err = bagInvoke(backpackRemote, "Store", toolName, active)
			if not ok then
				if type(err) == "string" and err:lower():find("not in your bag", 1, true) then
					break
				end
				return false, err or "could not bank extras", banked
			end
			banked += 1
		end
		return countNamedTools(toolName) == 1, "need one copy left", banked
	end

	-- Exact open-source race. keepParked banks extras between Auto Dupe attempts only.
	local function dupeHeldItem(active, keepParked)
		active = active or function()
			return true
		end
		keepParked = keepParked == true
		local character = getCharacter()
		local backpack = LocalPlayer:FindFirstChildOfClass("Backpack")
		local humanoid = getHumanoid()
		if not (character and backpack) then
			return false, "character not ready"
		end

		local tool = pickDupeTool()
		if not tool then
			return false, "equip the item you want to dupe"
		end

		local listRemote = getRemote("ListWeaponRemote")
		local buyRemote = getRemote("BuyItemRemote")
		local backpackRemote = getRemote("BackpackRemote")
		local marketItems = ReplicatedStorage:FindFirstChild("MarketItems")
		if not (
			listRemote
			and listRemote:IsA("RemoteEvent")
			and buyRemote
			and buyRemote:IsA("RemoteEvent")
			and backpackRemote
			and backpackRemote:IsA("RemoteFunction")
			and marketItems
		) then
			return false, "market remotes were not found"
		end

		local toolName = tool.Name
		lastDupeToolName = toolName
		local startingCount = countNamedTools(toolName)
		if startingCount <= 0 then
			return false, "you do not have " .. toolName
		end

		-- Clear a leftover listing so List can run cleanly.
		local leftover = findOwnMarketListing(toolName)
		if leftover then
			pcall(function()
				buyRemote:FireServer(toolName, "Remove", leftover:GetAttribute("SpecialId"))
			end)
			task.wait(0.35)
		end

		-- Multi-copy: park extras, then wait bag cooldown so the race Store is not blocked.
		if startingCount > 1 then
			local ok, err = bankExtras(backpackRemote, toolName, active)
			if not ok then
				pullStoredCopies(backpackRemote, toolName, active, startingCount + 2)
				return false, err, startingCount, countNamedTools(toolName)
			end
			if not waitBagCooldown(active) then
				return false, "stopped", startingCount, countNamedTools(toolName)
			end
		end

		-- Open-source step: tool must sit in the backpack for 0.5s before List.
		tool = findTools(function(candidate)
			return candidate.Name == toolName
		end)[1]
		if not tool then
			pullStoredCopies(backpackRemote, toolName, active, 4)
			return false, "tool missing before race", startingCount, countNamedTools(toolName)
		end
		if tool.Parent ~= backpack then
			pcall(function()
				if humanoid then
					humanoid:UnequipTools()
				end
				tool.Parent = backpack
			end)
		end
		task.wait(0.5)
		if not active() then
			return false, "stopped", startingCount, countNamedTools(toolName)
		end
		if not backpack:FindFirstChild(toolName) then
			return false, "tool not in backpack", startingCount, countNamedTools(toolName)
		end

		local toolId = nil
		local connection = marketItems.ChildAdded:Connect(function(item)
			if item.Name ~= toolName then
				return
			end
			local owner = item:WaitForChild("owner", 2)
			if owner and owner.Value == LocalPlayer.Name then
				toolId = item:GetAttribute("SpecialId")
			end
		end)

		local delay = 0.25 + ((math.clamp(getDupePingMs(), 0, 300) / 300) * 0.03)

		task.spawn(function()
			pcall(function()
				listRemote:FireServer(toolName, DUPE_LIST_PRICE)
			end)
		end)

		task.wait(delay)

		task.spawn(function()
			pcall(function()
				backpackRemote:InvokeServer("Store", toolName)
			end)
			lastBagRemoteAt = os.clock()
		end)

		task.wait(2.5)

		if not toolId then
			local listing = findOwnMarketListing(toolName)
			if listing then
				toolId = listing:GetAttribute("SpecialId")
			end
		end
		if toolId then
			task.spawn(function()
				pcall(function()
					buyRemote:FireServer(toolName, "Remove", toolId)
				end)
			end)
		end

		task.spawn(function()
			pcall(function()
				backpackRemote:InvokeServer("Grab", toolName)
			end)
			lastBagRemoteAt = os.clock()
		end)

		task.wait(1)
		connection:Disconnect()

		-- Pull any parked extras + race results.
		pullStoredCopies(backpackRemote, toolName, active, startingCount + 6)

		local after = countNamedTools(toolName)
		if after > startingCount then
			if keepParked then
				-- Leave one out for the next race; bank the rest.
				while countNamedTools(toolName) > 1 do
					local ok = bagInvoke(backpackRemote, "Store", toolName, active)
					if not ok then
						break
					end
				end
			end
			local copy = findTools(function(candidate)
				return candidate.Name == toolName
			end)[1]
			if copy and humanoid then
				pcall(function()
					humanoid:EquipTool(copy)
				end)
			end
			return true, nil, startingCount, after
		end

		-- Recover listing if the race missed.
		local listing = findOwnMarketListing(toolName)
		if listing then
			pcall(function()
				buyRemote:FireServer(toolName, "Remove", listing:GetAttribute("SpecialId"))
			end)
			task.wait(0.3)
			task.spawn(function()
				pcall(function()
					backpackRemote:InvokeServer("Grab", toolName)
				end)
			end)
			task.wait(0.5)
			pullStoredCopies(backpackRemote, toolName, active, 4)
		end
		return false, "timing missed (try again)", startingCount, countNamedTools(toolName)
	end

	local function dupeItem(itemName, active)
		if type(itemName) ~= "string" or itemName == "" then
			return false, "no item selected"
		end
		lastDupeToolName = itemName
		local tool = findTools(function(candidate)
			return candidate.Name == itemName
		end)[1]
		if not tool then
			return false, "you do not have " .. itemName
		end
		local humanoid = getHumanoid()
		if humanoid and tool.Parent ~= getCharacter() then
			pcall(function()
				humanoid:EquipTool(tool)
			end)
			task.wait(0.2)
		end
		return dupeHeldItem(active, false)
	end

	loopFeature("AutoDupe", 2, function(active)
		local tool = pickDupeTool()
		if not tool then
			return
		end
		local name = tool.Name
		local ok, reason, startingCount, endingCount = dupeHeldItem(active, true)
		if ok then
			notify(("Duped %s (%d → %d)."):format(name, startingCount or "?", endingCount or countNamedTools(name)))
		elseif reason and reason ~= "stopped" and reason ~= "equip the item you want to dupe" then
			notifyOnce("dupe_" .. name, "Dupe failed: " .. tostring(reason), 8)
		end
	end)

	do
		local previousDisable = Features.AutoDupe.disable
		Features.AutoDupe.disable = function()
			if previousDisable then
				previousDisable()
			end
			local name = lastDupeToolName
			local backpackRemote = getRemote("BackpackRemote")
			task.spawn(function()
				if name and backpackRemote then
					notify("Pulling banked " .. name .. " copies back...")
					pullStoredCopies(backpackRemote, name, function()
						return true
					end, 24)
					notify("Auto Dupe stopped — inventory restored.")
				end
			end)
		end
	end

	Money.getStat = getStat
	Money.formatCash = formatCash
	Money.parseAmount = parseAmount
	Money.dropMoney = dropMoney
	Money.deposit = deposit
	Money.withdraw = withdraw
	Money.cleanMoney = cleanMoney
	Money.infiniteMoney = infiniteMoney
	Money.dupeHeldItem = function(active)
		return dupeHeldItem(active, false)
	end
	Money.dupeItem = dupeItem
end)()

--------------------------------------------------------------------------------
-- Anti Taser / ESP
--------------------------------------------------------------------------------

-- Own function scope: the main chunk is close to Luau's 200-register limit.
;(function()
	-- Anti Taser -------------------------------------------------------------------

	-- Public spots to run to; the nearest one at least MIN_ESCAPE_DISTANCE away is used.
	local SAFE_SPOTS = {
		Vector3.new(-1513.2, 253.3, -616.7), -- River Park Residence
		Vector3.new(-1556.3, 253.4, 18.3), -- Hospital
		Vector3.new(-407.9, 253.4, -1240.7), -- Dealership
		Vector3.new(-449.6, 255.7, -267.5), -- Gas Station
		Vector3.new(-743.3, 254.1, -473.9), -- Tattoo Shop
		Vector3.new(-1447.8, 255.7, 2190.6), -- 5th Shop
		Vector3.new(-1419.4, 254.0, 2785.7), -- Sell Car
	}
	local MIN_ESCAPE_DISTANCE = 300
	local escaping = false

	local function escapeTaser()
		if escaping or not on("AntiTaser") then
			return
		end
		escaping = true
		task.spawn(function()
			local humanoid, root = getHumanoid(), getRoot()
			if humanoid and root and humanoid.Health > 0 then
				humanoid.PlatformStand = false
				pcall(humanoid.ChangeState, humanoid, Enum.HumanoidStateType.GettingUp)
				local best, bestDistance = nil, math.huge
				for _, spot in ipairs(SAFE_SPOTS) do
					local distance = (spot - root.Position).Magnitude
					if distance >= MIN_ESCAPE_DISTANCE and distance < bestDistance then
						best, bestDistance = spot, distance
					end
				end
				if best then
					notify("You were tased; teleporting to safety.")
					local ok, err = pcall(teleportCharacter, CFrame.new(best))
					if not ok then
						warn("[Arsenic] " .. tostring(err))
					end
				end
			end
			escaping = false
		end)
	end

	track(LocalPlayer:GetAttributeChangedSignal("Tased"):Connect(function()
		if LocalPlayer:GetAttribute("Tased") then
			escapeTaser()
		end
	end))

	Features.AntiTaser = {
		enable = function()
			if LocalPlayer:GetAttribute("Tased") then
				escapeTaser()
			end
		end,
	}

	-- ESP --------------------------------------------------------------------------

	Arsenic.Values.HighlightColor = Color3.fromRGB(255, 0, 0)
	Arsenic.Values.FriendHighlightColor = Color3.fromRGB(0, 255, 0)
	Arsenic.Values.TracerColor = Color3.fromRGB(255, 255, 255)
	-- 0 means no limit.
	Arsenic.Values.ESPMaxRadius = 0

	local RAINBOW_PERIOD = 4
	-- Player model extents above/below the root part, for the box.
	local BOX_TOP = 3
	local BOX_BOTTOM = 3.5
	local BOX_ASPECT = 0.6
	local ESP_SWITCHES = { "ESP", "HighlightESP", "FriendESP", "FriendHighlightESP" }

	local function espColor(name)
		if on("Rainbow" .. name) then
			return Color3.fromHSV((os.clock() / RAINBOW_PERIOD) % 1, 1, 1)
		end
		return Arsenic.Values[name]
	end

	local espGui = Instance.new("ScreenGui")
	espGui.Name = tostring(math.random(1e6, 1e7))
	espGui.IgnoreGuiInset = true
	espGui.ResetOnSpawn = false
	local guiParented = pcall(function()
		espGui.Parent = (gethui and gethui()) or game:GetService("CoreGui")
	end)
	if not guiParented or not espGui.Parent then
		espGui.Parent = LocalPlayer:WaitForChild("PlayerGui")
	end

	local highlightParent = espGui
	pcall(function()
		highlightParent = game:GetService("CoreGui")
	end)

	local friendCache = {}
	local function isFriend(player)
		local cached = friendCache[player.UserId]
		if cached == nil then
			friendCache[player.UserId] = false
			task.spawn(function()
				local ok, result = pcall(LocalPlayer.IsFriendsWith, LocalPlayer, player.UserId)
				friendCache[player.UserId] = ok and result == true
			end)
			return false
		end
		return cached
	end

	local function newFrame(parent)
		local frame = Instance.new("Frame")
		frame.BorderSizePixel = 0
		frame.Visible = false
		frame.Parent = parent
		return frame
	end

	local function newLabel(parent, anchor, size)
		local label = Instance.new("TextLabel")
		label.BackgroundTransparency = 1
		label.Font = Enum.Font.GothamBold
		label.TextSize = size
		label.TextColor3 = Color3.new(1, 1, 1)
		label.TextStrokeTransparency = 0.3
		label.AnchorPoint = anchor
		label.Size = UDim2.fromOffset(240, size + 4)
		label.Visible = false
		label.Parent = parent
		return label
	end

	local espObjects = {}

	local function getEsp(player)
		local esp = espObjects[player]
		if esp then
			return esp
		end
		local folder = Instance.new("Folder")
		folder.Parent = espGui
		local box = newFrame(folder)
		box.BackgroundTransparency = 1
		local stroke = Instance.new("UIStroke")
		stroke.Thickness = 1.5
		stroke.Parent = box
		local healthBack = newFrame(folder)
		healthBack.BackgroundColor3 = Color3.new(0, 0, 0)
		healthBack.BackgroundTransparency = 0.3
		healthBack.AnchorPoint = Vector2.new(1, 0)
		local healthFill = newFrame(healthBack)
		healthFill.AnchorPoint = Vector2.new(0, 1)
		healthFill.Position = UDim2.fromScale(0, 1)
		healthFill.Visible = true
		local healthText = newLabel(folder, Vector2.new(1, 0.5), 11)
		healthText.TextXAlignment = Enum.TextXAlignment.Right
		local highlight = Instance.new("Highlight")
		highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
		highlight.Enabled = false
		if not pcall(function()
			highlight.Parent = highlightParent
		end) then
			highlight.Parent = espGui
		end
		esp = {
			folder = folder,
			box = box,
			stroke = stroke,
			name = newLabel(folder, Vector2.new(0.5, 1), 13),
			item = newLabel(folder, Vector2.new(0.5, 0), 12),
			healthBack = healthBack,
			healthFill = healthFill,
			healthText = healthText,
			tracer = newFrame(folder),
			highlight = highlight,
		}
		esp.tracer.AnchorPoint = Vector2.new(0.5, 0.5)
		espObjects[player] = esp
		return esp
	end

	local function hideOverlay(esp)
		esp.box.Visible = false
		esp.name.Visible = false
		esp.item.Visible = false
		esp.healthBack.Visible = false
		esp.healthText.Visible = false
		esp.tracer.Visible = false
	end

	local function removeEsp(player)
		local esp = espObjects[player]
		if esp then
			espObjects[player] = nil
			esp.folder:Destroy()
			esp.highlight:Destroy()
		end
	end

	local function validRoot(root)
		if not (root and root:IsA("BasePart") and root:IsDescendantOf(Workspace)) then
			return false
		end
		local position = root.Position
		return position.X == position.X and position.Y == position.Y and position.Z == position.Z
			and math.abs(position.X) < 1e6
			and math.abs(position.Y) < 1e6
			and math.abs(position.Z) < 1e6
	end

	local function drawOverlay(esp, player, character, humanoid, root, color, tracerColor)
		local camera = Workspace.CurrentCamera
		if not camera then
			hideOverlay(esp)
			return
		end
		local top, topOnScreen = camera:WorldToViewportPoint(root.Position + Vector3.new(0, BOX_TOP, 0))
		local bottom, bottomOnScreen = camera:WorldToViewportPoint(root.Position - Vector3.new(0, BOX_BOTTOM, 0))
		-- Behind the camera or fully off-screen: hide so the last frame isn't left stuck.
		if top.Z <= 0 or bottom.Z <= 0 or not (topOnScreen or bottomOnScreen) then
			hideOverlay(esp)
			return
		end
		local viewport = camera.ViewportSize
		local margin = 80
		local onScreen = top.X > -margin
			and top.X < viewport.X + margin
			and bottom.X > -margin
			and bottom.X < viewport.X + margin
			and top.Y > -margin
			and bottom.Y < viewport.Y + margin
		if not onScreen then
			hideOverlay(esp)
			return
		end
		local height = math.max(math.abs(bottom.Y - top.Y), 4)
		local width = height * BOX_ASPECT
		local centerX = (top.X + bottom.X) / 2
		local topY = math.min(top.Y, bottom.Y)
		local left = centerX - width / 2

		esp.box.Position = UDim2.fromOffset(left, topY)
		esp.box.Size = UDim2.fromOffset(width, height)
		esp.stroke.Color = color
		esp.box.Visible = true

		local header = {}
		if on("ESPNames") then
			table.insert(header, player.DisplayName)
		end
		local myRoot = getRoot()
		if on("ESPDistance") and myRoot then
			table.insert(header, ("[%d studs]"):format(math.floor((myRoot.Position - root.Position).Magnitude)))
		end
		esp.name.Text = table.concat(header, " ")
		esp.name.Position = UDim2.fromOffset(centerX, topY - 2)
		esp.name.Visible = #header > 0

		local tool = on("ESPItem") and character:FindFirstChildOfClass("Tool")
		esp.item.Text = tool and tool.Name or ""
		esp.item.Position = UDim2.fromOffset(centerX, topY + height + 2)
		esp.item.Visible = tool ~= nil and tool ~= false

		local showHealth = on("ESPHealth")
		esp.healthBack.Visible = showHealth
		esp.healthText.Visible = showHealth
		if showHealth then
			local fraction = math.clamp(humanoid.Health / math.max(humanoid.MaxHealth, 1), 0, 1)
			esp.healthBack.Position = UDim2.fromOffset(left - 3, topY)
			esp.healthBack.Size = UDim2.fromOffset(3, height)
			esp.healthFill.Size = UDim2.fromScale(1, fraction)
			esp.healthFill.BackgroundColor3 = Color3.fromRGB(255, 60, 60):Lerp(Color3.fromRGB(60, 255, 90), fraction)
			esp.healthText.Text = tostring(math.floor(humanoid.Health))
			esp.healthText.Position = UDim2.fromOffset(left - 6, topY + height * (1 - fraction))
		end

		if on("Tracers") then
			local from = Vector2.new(viewport.X / 2, viewport.Y)
			local target = Vector2.new((top.X + bottom.X) / 2, topY + height)
			local delta = target - from
			local middle = from + delta / 2
			esp.tracer.Position = UDim2.fromOffset(middle.X, middle.Y)
			esp.tracer.Size = UDim2.fromOffset(math.max(delta.Magnitude, 1), 1.5)
			esp.tracer.Rotation = math.deg(math.atan2(delta.Y, delta.X))
			esp.tracer.BackgroundColor3 = tracerColor
			esp.tracer.Visible = true
		else
			esp.tracer.Visible = false
		end
	end

	local function updatePlayerEsp(player, enemyColor, friendColor, tracerColor)
		if player == LocalPlayer then
			return
		end
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		local root = character and character:FindFirstChild("HumanoidRootPart")
		local friend = isFriend(player)
		local showEsp, showHighlight
		if friend then
			showEsp, showHighlight = on("FriendESP"), on("FriendHighlightESP")
		else
			showEsp, showHighlight = on("ESP"), on("HighlightESP")
		end
		local alive = character
			and humanoid
			and validRoot(root)
			and humanoid.Health > 0
			and root:IsDescendantOf(character)
		local myRoot = getRoot()
		local maxRadius = Arsenic.Values.ESPMaxRadius
		local inRange = true
		if alive and maxRadius and maxRadius > 0 and myRoot then
			inRange = (root.Position - myRoot.Position).Magnitude <= maxRadius
		end
		if alive and inRange and (showEsp or showHighlight) then
			local esp = getEsp(player)
			local color = friend and friendColor or enemyColor
			esp.highlight.Adornee = character
			esp.highlight.Enabled = showHighlight == true
			if showHighlight then
				esp.highlight.OutlineColor = color
				esp.highlight.FillColor = color
				esp.highlight.OutlineTransparency = 0
				-- Friends are outlined only; everyone else is filled too.
				esp.highlight.FillTransparency = friend and 1 or 0.5
			end
			if showEsp then
				drawOverlay(esp, player, character, humanoid, root, color, tracerColor)
			else
				hideOverlay(esp)
			end
		elseif espObjects[player] then
			espObjects[player].highlight.Enabled = false
			espObjects[player].highlight.Adornee = nil
			hideOverlay(espObjects[player])
		end
	end

	local function updateEsp()
		local anyOn = false
		for _, switch in ipairs(ESP_SWITCHES) do
			if on(switch) then
				anyOn = true
				break
			end
		end
		if not anyOn then
			for player in pairs(espObjects) do
				removeEsp(player)
			end
			return
		end

		local enemyColor = espColor("HighlightColor")
		local friendColor = espColor("FriendHighlightColor")
		local tracerColor = espColor("TracerColor")
		local seen = {}
		for _, player in ipairs(Players:GetPlayers()) do
			seen[player] = true
			-- One bad player must not freeze every other box/tracer on screen.
			local ok, err = pcall(updatePlayerEsp, player, enemyColor, friendColor, tracerColor)
			if not ok then
				if espObjects[player] then
					espObjects[player].highlight.Enabled = false
					hideOverlay(espObjects[player])
				end
				warn("[Arsenic] ESP player: " .. tostring(err))
			end
		end
		for player in pairs(espObjects) do
			if not seen[player] then
				removeEsp(player)
			end
		end
	end

	track(RunService.RenderStepped:Connect(function()
		local ok, err = pcall(updateEsp)
		if not ok then
			warn("[Arsenic] ESP: " .. tostring(err))
		end
	end))
	track(Players.PlayerRemoving:Connect(removeEsp))
	track(Players.PlayerAdded:Connect(function(player)
		track(player.CharacterRemoving:Connect(function()
			if espObjects[player] then
				espObjects[player].highlight.Enabled = false
				espObjects[player].highlight.Adornee = nil
				hideOverlay(espObjects[player])
			end
		end))
	end))
	for _, player in ipairs(Players:GetPlayers()) do
		if player ~= LocalPlayer then
			track(player.CharacterRemoving:Connect(function()
				if espObjects[player] then
					espObjects[player].highlight.Enabled = false
					espObjects[player].highlight.Adornee = nil
					hideOverlay(espObjects[player])
				end
			end))
		end
	end
	table.insert(Arsenic.Cleanup, function()
		for player in pairs(espObjects) do
			removeEsp(player)
		end
		espGui:Destroy()
	end)
end)()

--------------------------------------------------------------------------------
-- Vehicles
--------------------------------------------------------------------------------

local Vehicles = {}

-- Own function scope: the main chunk is close to Luau's 200-register limit.
;(function()
	local UserInputService = game:GetService("UserInputService")

	local function waitFor(condition, timeout)
		local deadline = os.clock() + timeout
		while os.clock() < deadline and not Arsenic.Destroyed do
			if condition() then
				return true
			end
			task.wait(0.1)
		end
		return condition() and true or false
	end

	local function getStat(name)
		local stored = LocalPlayer:FindFirstChild("stored")
		local value = stored and stored:FindFirstChild(name)
		return value and tonumber(value.Value) or 0
	end

	-- Fly Cars ---------------------------------------------------------------------

	Arsenic.Values.FlySpeed = 80
	-- A/D turn the car at this rate (degrees per second).
	local FLY_TURN_RATE = math.rad(110)
	local flyConnection = nil
	-- The car's heading is kept here rather than taken from the camera: the car camera turns with
	-- the car, so steering by it feeds back into itself and spins the car.
	local flySeat, flyHeading = nil, 0

	local function flyStep(dt)
		local humanoid = getHumanoid()
		local seat = humanoid and humanoid.SeatPart
		local car = seat and getVehicleModel(seat)
		if not (car and seat:IsA("VehicleSeat")) then
			flySeat = nil
			return
		end
		if seat ~= flySeat then
			flySeat = seat
			local look = seat.CFrame.LookVector
			flyHeading = math.atan2(-look.X, -look.Z)
		end
		local keyDown = function(...)
			if UserInputService:GetFocusedTextBox() then
				return false
			end
			for _, key in ipairs({ ... }) do
				if UserInputService:IsKeyDown(key) then
					return true
				end
			end
			return false
		end
		if keyDown(Enum.KeyCode.A, Enum.KeyCode.Left) then
			flyHeading += FLY_TURN_RATE * dt
		end
		if keyDown(Enum.KeyCode.D, Enum.KeyCode.Right) then
			flyHeading -= FLY_TURN_RATE * dt
		end
		local facing = CFrame.Angles(0, flyHeading, 0).LookVector
		local move = Vector3.zero
		if keyDown(Enum.KeyCode.W, Enum.KeyCode.Up) then
			move += facing
		end
		if keyDown(Enum.KeyCode.S, Enum.KeyCode.Down) then
			move -= facing
		end
		if keyDown(Enum.KeyCode.Space, Enum.KeyCode.E) then
			move += Vector3.yAxis
		end
		if keyDown(Enum.KeyCode.LeftShift, Enum.KeyCode.Q) then
			move -= Vector3.yAxis
		end
		if move.Magnitude > 0 then
			move = move.Unit
		end
		local seatPosition = seat.Position + move * math.max(Arsenic.Values.FlySpeed, 1) * dt
		local pivotFromSeat = seat.CFrame:ToObjectSpace(car:GetPivot())
		car:PivotTo(CFrame.lookAt(seatPosition, seatPosition + facing) * pivotFromSeat)
		-- Hovering: no gravity build-up while no key is held.
		seat.AssemblyLinearVelocity = Vector3.zero
		seat.AssemblyAngularVelocity = Vector3.zero
	end

	Features.FlyCars = {
		enable = function()
			if not flyConnection then
				flyConnection = track(RunService.Heartbeat:Connect(flyStep))
			end
		end,
		disable = function()
			if flyConnection then
				flyConnection:Disconnect()
				flyConnection = nil
			end
			flySeat = nil
		end,
	}

	-- Vehicle list -----------------------------------------------------------------

	local function getCivCars()
		local civCars = Workspace:FindFirstChild("CivCars")
		return civCars and civCars:GetChildren() or {}
	end

	local function hasPassengers(car, driveSeat)
		for _, descendant in ipairs(car:GetDescendants()) do
			if descendant:IsA("Seat") and descendant ~= driveSeat and descendant.Occupant then
				return true
			end
		end
		return false
	end

	local labelToCar = {}
	local selectedCar = nil

	function Vehicles.buildOptions()
		table.clear(labelToCar)
		local entries = {}
		local seen = {}
		for _, car in ipairs(getCivCars()) do
			local seat = getDriveSeat(car)
			if seat then
				local owner = getCarOwner(car)
				local base = ("%s (%s)"):format(car.Name, owner ~= "" and owner or "no owner")
				seen[base] = (seen[base] or 0) + 1
				local label = seen[base] > 1 and ("%s #%d"):format(base, seen[base]) or base
				local tags = {}
				if seat.Occupant then
					table.insert(tags, "[D]")
				end
				if hasPassengers(car, seat) then
					table.insert(tags, "[P]")
				end
				if #tags > 0 then
					label = label .. " " .. table.concat(tags, " ")
				end
				labelToCar[label] = car
				table.insert(entries, label)
			end
		end
		table.sort(entries, function(a, b)
			return a:lower() < b:lower()
		end)
		return entries
	end

	function Vehicles.select(label)
		if type(label) == "table" then
			label = label[1]
		end
		selectedCar = label and labelToCar[label] or nil
	end

	local function getSelectedCar()
		if selectedCar and selectedCar.Parent and getDriveSeat(selectedCar) then
			return selectedCar
		end
		notify("Select a vehicle first.")
		return nil
	end

	-- Spectate Vehicle --------------------------------------------------------------

	Features.SpectateVehicle = {
		enable = function()
			if not (selectedCar and selectedCar.Parent) then
				notify("Select a vehicle to spectate.")
			end
			while on("SpectateVehicle") do
				local camera = Workspace.CurrentCamera
				local seat = selectedCar and selectedCar.Parent and getDriveSeat(selectedCar)
				local subject = seat or getHumanoid()
				if camera and subject and camera.CameraSubject ~= subject then
					camera.CameraSubject = subject
				end
				task.wait(0.25)
			end
		end,
		disable = function()
			local camera, humanoid = Workspace.CurrentCamera, getHumanoid()
			if camera and humanoid then
				camera.CameraSubject = humanoid
			end
		end,
	}

	function Vehicles.teleportToSelected()
		local car = getSelectedCar()
		if not car then
			return
		end
		local arrived = teleportCharacter(function()
			local seat = car.Parent and getDriveSeat(car)
			-- Beside the driver's door, where the game's own exit puts you.
			return seat and flatRotation(seat.CFrame) * CFrame.new(-5, 0, 0) or nil
		end)
		if not arrived then
			notify("Could not reach " .. car.Name .. ".")
		end
	end

	-- Striking ---------------------------------------------------------------------

	-- The game's robbery cooldown (LastSRob, server time) covers car break-ins.
	local ROB_COOLDOWN = 180
	-- Assumed wait after a break-in until the game says otherwise.
	local STEAL_COOLDOWN = 300
	local STEAL_PROBE_TIME = 1.5
	local SELLER_DISTANCE = 3
	local PARK_DISTANCES = { 10, 14, 18 }
	local FREE_CAR_POSITION = Vector3.new(-1542.5, 258.2, -1175.4)
	local FREE_CAR_RADIUS = 40
	local EXPENSIVE_SHARE = 0.6
	local FAILED_CAR_COOLDOWN = 300
	local STRIKE_CONNECT_TIME = 7.3
	local STRIKE_MENU_TIMEOUT = 15
	local WINDOW_DISTANCE = 2.5
	local WINDOW_STAGING_DISTANCE = 10
	-- Closer than this we walk instead of teleporting.
	local WINDOW_WALK_DISTANCE = 14
	-- Pull-backs while going for one car before we give up on it.
	local MAX_STEAL_FLAGS = 2
	-- Rest after a car caused pull-backs, so the anti-teleport doesn't escalate to a kick.
	local FLAG_REST_TIME = 30
	local WINDOW_APPROACHES = 3
	local MOVING_CAR_SPEED = 3
	local SCREW_ATTEMPTS = 3

	local failedCars = setmetatable({}, { __mode = "k" })

	local function carValue(car)
		local value = car:FindFirstChild("CarStealPrice")
		return value and tonumber(value.Value) or 0
	end

	local function isFreeCar(car)
		return carValue(car) <= 0 or (car:GetPivot().Position - FREE_CAR_POSITION).Magnitude < FREE_CAR_RADIUS
	end

	local function stolenByMe(car)
		local seat = getDriveSeat(car)
		local stolen = seat and seat:FindFirstChild("Stolen")
		return stolen ~= nil and stolen.Value == LocalPlayer.Name
	end

	local function isStriked(car)
		return car:GetAttribute("Striked") ~= nil and car:GetAttribute("Striked") ~= false
	end

	local function robCooldownLeft()
		local last = LocalPlayer:GetAttribute("LastSRob") or 0
		return math.max(ROB_COOLDOWN - (Workspace:GetServerTimeNow() - last), stealReadyAt - os.clock(), 0)
	end

	local function getToolNamed(name)
		return findTools(function(tool)
			return tool.Name == name
		end)[1]
	end

	local function equip(tool)
		local humanoid, character = getHumanoid(), getCharacter()
		if not (tool and humanoid and character) then
			return false
		end
		if tool.Parent ~= character then
			humanoid:EquipTool(tool)
		end
		return waitFor(function()
			return tool.Parent == character
		end, 2)
	end

	Arsenic.Values.StrikeBreakInMode = Arsenic.Values.StrikeBreakInMode or "Strikepad"

	local function strikeBreakInMode()
		local mode = Arsenic.Values.StrikeBreakInMode
		if mode == "Screw" then
			return "Screw"
		end
		return "Strikepad"
	end

	local function breakInToolName()
		return strikeBreakInMode() == "Screw" and "Screw" or "Swiss Screw"
	end

	-- Buy StrikePad plus the selected break-in tool in as few store trips as possible.
	local function ensureStrikeTools(needBreakInTool)
		local missing = {}
		if countOwned("StrikePad") == 0 then
			table.insert(missing, "StrikePad")
		end
		local breakTool = breakInToolName()
		if needBreakInTool and countOwned(breakTool) == 0 then
			table.insert(missing, breakTool)
		end
		if #missing == 0 then
			return true
		end
		notify("Buying " .. table.concat(missing, " and ") .. "...")
		if not buyItems(missing) then
			return false
		end
		return waitFor(function()
			if countOwned("StrikePad") == 0 then
				return false
			end
			if needBreakInTool and countOwned(breakTool) == 0 then
				return false
			end
			return true
		end, 3)
	end

	-- Anyone sitting anywhere in the car, or the car still rolling, means someone is driving it.
	local function hasDriver(car)
		local seat = getDriveSeat(car)
		if not seat or seat.Occupant or hasPassengers(car, seat) then
			return true
		end
		for _, player in ipairs(Players:GetPlayers()) do
			local character = player.Character
			local humanoid = character and character:FindFirstChildOfClass("Humanoid")
			if player ~= LocalPlayer and humanoid and humanoid.SeatPart and humanoid.SeatPart:IsDescendantOf(car) then
				return true
			end
		end
		return seat.AssemblyLinearVelocity.Magnitude > MOVING_CAR_SPEED
	end

	-- The game only offers "Break Window" on cars that are still locked; an unlocked car was
	-- already broken into and can't be stolen properly any more.
	local function strikeable(car)
		local seat = car.Parent and getDriveSeat(car)
		return seat ~= nil
			and (seat:FindFirstChild("Locked") ~= nil or stolenByMe(car))
			and not hasDriver(car)
			and getCarOwner(car) ~= LocalPlayer.Name
			and not isFreeCar(car)
			and not isStriked(car)
	end

	local function driverWindowPart(car)
		local body = car:FindFirstChild("Body")
		local breakPart = body and body:FindFirstChild("BreakInPart")
		return breakPart and breakPart:IsA("BasePart") and breakPart or nil
	end

	local function driverWindow(car)
		local breakPart = driverWindowPart(car)
		if breakPart then
			return breakPart.Position
		end
		local seat = getDriveSeat(car)
		return (seat.CFrame * CFrame.new(-1.5, 2, 0)).Position
	end

	-- Where the thief stands: on the ground just outside the driver's window (left of the driver
	-- seat), facing it, close enough for the screw to reach.
	local function driverDoorCFrame(car)
		local seat = getDriveSeat(car)
		if not seat then
			return nil
		end
		local window = driverWindow(car)
		local out = Vector3.new(window.X - seat.Position.X, 0, window.Z - seat.Position.Z)
		if out.Magnitude < 0.5 then
			out = -flatRotation(seat.CFrame).RightVector
		end
		out = out.Unit
		local stand = window + out * WINDOW_DISTANCE
		local groundY = findGroundY(stand + Vector3.new(0, 4, 0))
		local humanoid, root = getHumanoid(), getRoot()
		if groundY and humanoid and root then
			stand = Vector3.new(stand.X, groundY + getStandHeight(humanoid, root), stand.Z)
		end
		return CFrame.lookAt(stand, Vector3.new(window.X, stand.Y, window.Z))
	end

	-- Gets to the window and stays there; the anti-teleport snaps us back a moment after a bad move,
	-- and anything done from the old spot is wasted.
	local function reachWindow(car)
		local flagsAtStart = teleportFlagCount
		for _ = 1, WINDOW_APPROACHES do
			local spot = driverDoorCFrame(car)
			local humanoid, root = getHumanoid(), getRoot()
			if not (spot and humanoid and root) then
				return false
			end
			-- Arrive a little way out from the door, then walk the last bit at walking pace;
			-- fast moves right next to the car are what the anti-teleport catches.
			if (root.Position - spot.Position).Magnitude > WINDOW_WALK_DISTANCE then
				local staging = spot.Position - spot.LookVector * WINDOW_STAGING_DISTANCE
				local groundY = findGroundY(staging + Vector3.new(0, 4, 0))
				if groundY then
					staging = Vector3.new(staging.X, groundY + getStandHeight(humanoid, root), staging.Z)
				end
				teleportOnFoot(CFrame.lookAt(staging, Vector3.new(spot.Position.X, staging.Y, spot.Position.Z)))
				task.wait(0.4)
			end
			local flagMark = teleportFlagCount
			root = getRoot()
			if root and (root.Position - spot.Position).Magnitude > 3 then
				Pathing.walkTo(humanoid, spot)
			end
			task.wait(0.8)
			root = getRoot()
			if root and teleportFlagCount == flagMark and (root.Position - spot.Position).Magnitude <= 4 then
				return true
			end
			if teleportFlagCount - flagsAtStart >= MAX_STEAL_FLAGS then
				return false
			end
			task.wait(3)
		end
		return false
	end

	-- Game LockPick prompts only accept a tool named exactly "Screw" (see NEW LOCKPICK).
	-- Swiss Screw is the shop item we buy; rename it for the interaction, then restore.
	local function isLockPickPrompt(prompt)
		local action = prompt.ActionText:lower()
		return action:find("lockpick", 1, true) ~= nil or action == "unlock"
	end

	local function findLockPickPrompt(car)
		local fallback = nil
		local breakPart = driverWindowPart(car)
		if breakPart then
			for _, child in ipairs(breakPart:GetDescendants()) do
				if child:IsA("ProximityPrompt") and isLockPickPrompt(child) then
					if child.Enabled then
						return child
					end
					fallback = fallback or child
				end
			end
			local onPart = breakPart:FindFirstChildWhichIsA("ProximityPrompt")
			if onPart and isLockPickPrompt(onPart) then
				fallback = fallback or onPart
			end
		end
		for _, descendant in ipairs(car:GetDescendants()) do
			if descendant:IsA("ProximityPrompt") and isLockPickPrompt(descendant) then
				if descendant.Enabled then
					return descendant
				end
				fallback = fallback or descendant
			end
		end
		return fallback
	end

	local function getScrewTool()
		local preferred = breakInToolName()
		return getToolNamed(preferred) or getToolNamed("Screw") or getToolNamed("Swiss Screw")
	end

	-- NEW LOCKPICK uses Character:FindFirstChild("Screw"); Swiss Screw must present as "Screw".
	local function withGameScrewName(tool, fn)
		if not tool then
			return fn(nil)
		end
		local original = tool.Name
		if original ~= "Screw" then
			pcall(function()
				tool.Name = "Screw"
			end)
		end
		local ok, result = pcall(fn, tool)
		if tool.Parent and tool.Name == "Screw" and original ~= "Screw" then
			pcall(function()
				tool.Name = original
			end)
		end
		if not ok then
			error(result, 0)
		end
		return result
	end

	-- NEW LOCKPICK: 3 skill-checks (moving RedBar vs WhiteBar). Press F while aligned.
	local function completeLockpickMinigame(car, windowBroken)
		local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
		local gui = playerGui and playerGui:FindFirstChild("NEW LOCKPICK")
		local red = gui and gui:FindFirstChild("RedBar", true)
		local white = gui and gui:FindFirstChild("WhiteBar", true)
		local remote = ReplicatedStorage:FindFirstChild("Lockpick_Handler")
		local ownerValue = car:FindFirstChild("Owner")
		local ownerPlayer = ownerValue and Players:FindFirstChild(ownerValue.Value)
		if not (gui and red and white) then
			return windowBroken()
		end

		local function pressConfirm()
			pcall(function()
				local vim = game:GetService("VirtualInputManager")
				vim:SendKeyEvent(true, Enum.KeyCode.F, false, game)
				vim:SendKeyEvent(false, Enum.KeyCode.F, false, game)
			end)
		end

		local function alignBars()
			-- IsInFrame accepts either mirrored (360-red) or direct red≈white (±16°).
			pcall(function()
				white.Rotation = red.Rotation
			end)
		end

		local stages = 0
		local lastPress = 0
		local deadline = os.clock() + 18
		local connection = RunService.Heartbeat:Connect(function()
			if not gui.Parent or windowBroken() or stealReadyAt > os.clock() or os.clock() > deadline then
				return
			end
			if not gui.Enabled then
				return
			end
			alignBars()
			if red.Visible and os.clock() - lastPress > 0.35 then
				lastPress = os.clock()
				pressConfirm()
				stages += 1
				if remote and ownerPlayer then
					pcall(function()
						remote:FireServer(math.clamp(stages, 1, 3), ownerPlayer)
					end)
				end
			end
		end)

		waitFor(function()
			return windowBroken() or stealReadyAt > os.clock() or os.clock() > deadline or (stages >= 3 and not red.Visible and not gui.Enabled)
		end, 18)
		connection:Disconnect()

		if not windowBroken() and remote and ownerPlayer then
			for stage = 1, 3 do
				if windowBroken() then
					break
				end
				alignBars()
				pressConfirm()
				pcall(function()
					remote:FireServer(stage, ownerPlayer)
				end)
				task.wait(0.15)
			end
		end
		return waitFor(windowBroken, 2.5)
	end

	-- LockPick on BreakInPart with the selected screw tool. Sitting before this marks the car stolen.
	local function breakIn(car)
		if stolenByMe(car) then
			return true
		end
		local seat = getDriveSeat(car)
		local screw = getScrewTool()
		if not (seat and screw) then
			return false
		end

		return withGameScrewName(screw, function(gameScrew)
			if not equip(gameScrew) then
				return false
			end
			local messageMark = gameMessage.time
			local lockedAtStart = seat:FindFirstChild("Locked") ~= nil
			local function windowBroken()
				if stolenByMe(car) then
					return true
				end
				if lockedAtStart and not seat:FindFirstChild("Locked") then
					return true
				end
				local text = gameMessage.text
				if gameMessage.time ~= messageMark and text:find("not holding out a screw", 1, true) then
					return false
				end
				return gameMessage.time ~= messageMark
					and (
						text:find("window broken", 1, true) ~= nil
						or text:find("lockpick", 1, true) ~= nil
						or text:find("unlocked", 1, true) ~= nil
						or text:find("broke", 1, true) ~= nil
					)
			end

			local function tryLockPick(prompt)
				if not prompt then
					return false
				end
				-- Let the game's Screw ChildAdded enable it; only nudge distance/LOS.
				if prompt.MaxActivationDistance < 8 then
					prompt.MaxActivationDistance = 8
				end
				prompt.RequiresLineOfSight = false
				if not prompt.Enabled then
					prompt.Enabled = true
				end
				local beforeMessage = gameMessage.time
				local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
				local function lockpickGuiOpen()
					local gui = playerGui and playerGui:FindFirstChild("NEW LOCKPICK")
					return gui ~= nil and gui.Enabled == true
				end
				firePrompt(prompt)
				waitFor(function()
					return windowBroken()
						or stealReadyAt > os.clock()
						or (gameMessage.time ~= beforeMessage and gameMessage.text:find("not holding out a screw", 1, true) ~= nil)
						or lockpickGuiOpen()
				end, math.max(STEAL_PROBE_TIME, (tonumber(prompt.HoldDuration) or 0) + 1.5))
				if gameMessage.time ~= beforeMessage and gameMessage.text:find("not holding out a screw", 1, true) then
					return false
				end
				if windowBroken() then
					return true
				end
				if lockpickGuiOpen() then
					return completeLockpickMinigame(car, windowBroken)
				end
				return windowBroken()
			end

			-- Probe from where we stand first (cooldown / lockpick without walking up).
			local probePrompt = nil
			waitFor(function()
				probePrompt = findLockPickPrompt(car)
				return probePrompt ~= nil
			end, 2)
			if tryLockPick(probePrompt) then
				stealReadyAt = math.max(stealReadyAt, os.clock() + STEAL_COOLDOWN)
				genv.ArsenicStealReadyAt = stealReadyAt
				return true
			end
			if stealReadyAt > os.clock() then
				return false
			end

			if not reachWindow(car) then
				return false
			end
			for _ = 1, SCREW_ATTEMPTS do
				if seat.Occupant then
					return false
				end
				if gameScrew.Parent ~= getCharacter() and not equip(gameScrew) then
					return false
				end
				local prompt = nil
				waitFor(function()
					prompt = findLockPickPrompt(car)
					return prompt ~= nil
				end, 2.5)
				if tryLockPick(prompt) then
					stealReadyAt = math.max(stealReadyAt, os.clock() + STEAL_COOLDOWN)
					genv.ArsenicStealReadyAt = stealReadyAt
					return true
				end
				if stealReadyAt > os.clock() then
					return false
				end
				task.wait(0.5)
			end
			return windowBroken()
		end)
	end

	-- Gets in through the seat's own prompt, the way a player does, so the game records the theft.
	local function enterDriverSeat(car)
		local seat = getDriveSeat(car)
		local humanoid = getHumanoid()
		if not (seat and humanoid) then
			return false
		end
		if humanoid.SeatPart == seat then
			return true
		end
		-- Real other driver only — don't abort on parked-car velocity jitter.
		if seat.Occupant and seat.Occupant ~= humanoid then
			return false
		end
		local prompt = seat:FindFirstChildWhichIsA("ProximityPrompt", true)
		for _ = 1, 6 do
			-- Holding Swiss Screw / StrikePad blocks Sit on this game.
			unequipTools()
			seat.Disabled = false
			if prompt then
				prompt.Enabled = true
				prompt.RequiresLineOfSight = false
				if prompt.MaxActivationDistance < 10 then
					prompt.MaxActivationDistance = 10
				end
			end
			local root = getRoot()
			local approach = driverDoorCFrame(car) or (seat.CFrame * CFrame.new(-2.2, 0.5, 0.2))
			local groundY = findGroundY(approach.Position + Vector3.new(0, 4, 0), car)
			if groundY and root then
				local stand = Vector3.new(approach.Position.X, groundY + getStandHeight(humanoid, root), approach.Position.Z)
				approach = CFrame.lookAt(stand, Vector3.new(seat.Position.X, stand.Y, seat.Position.Z))
			end
			root = getRoot()
			if root and (root.Position - approach.Position).Magnitude > 3.5 then
				if (root.Position - approach.Position).Magnitude > WINDOW_WALK_DISTANCE then
					teleportOnFoot(approach)
				else
					Pathing.walkTo(humanoid, approach)
				end
			end
			unequipTools()
			task.wait(0.1)
			if prompt then
				-- Sit HoldDuration is 1s; instantize so fireproximityprompt always completes.
				firePrompt(prompt, true)
			end
			if waitFor(function()
				return humanoid.SeatPart == seat
			end, 1.8) then
				return true
			end
			-- Sit API from the door (not a Vehicle teleport — that borrows other cars).
			root = getRoot()
			if root then
				root.AssemblyLinearVelocity = Vector3.zero
				root.CFrame = seat.CFrame * CFrame.new(-1.4, 0.6, 0)
				pcall(function()
					seat:Sit(humanoid)
				end)
				if firetouchinterest then
					pcall(firetouchinterest, root, seat, 0)
					task.wait()
					pcall(firetouchinterest, root, seat, 1)
				end
			end
			if waitFor(function()
				return humanoid.SeatPart == seat
			end, 1) then
				return true
			end
			if instantSit(seat) then
				return true
			end
			forceSit(seat)
			if humanoid.SeatPart == seat then
				return true
			end
			task.wait(0.2)
		end
		return humanoid.SeatPart == seat
	end
	Vehicles.enterDriverSeat = enterDriverSeat

	local function findStrikeButton(carName)
		local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
		local gui = playerGui and playerGui:FindFirstChild("STRIKUH")
		local list = gui and gui:FindFirstChildWhichIsA("ScrollingFrame", true)
		for _, entry in ipairs(list and list:GetChildren() or {}) do
			local inner = entry:FindFirstChild("Frame")
			local label = inner and inner:FindFirstChild("TextLabel")
			local button = inner and inner:FindFirstChild("TextButton")
			if label and button and label.Text == carName then
				return button
			end
		end
		return nil
	end

	local function clickButton(button)
		if firesignal then
			return pcall(firesignal, button.MouseButton1Click)
		end
		if getconnections then
			local clicked = false
			for _, connection in ipairs(getconnections(button.MouseButton1Click)) do
				clicked = pcall(function()
					connection:Fire()
				end) or clicked
			end
			return clicked
		end
		return false
	end

	-- Equipping the StrikePad in a stolen car opens the game's strike UI; we pick the right car in it.
	local function strike(car)
		if isStriked(car) then
			return true
		end
		local pad = getToolNamed("StrikePad")
		if not equip(pad) then
			return false
		end
		local messageMark = gameMessage.time
		local clicked = false
		local deadline = os.clock() + STRIKE_MENU_TIMEOUT
		while os.clock() < deadline and not clicked and not Arsenic.Destroyed do
			local button = findStrikeButton(car.Name)
			if button then
				clicked = clickButton(button)
			end
			task.wait(0.1)
		end
		if not clicked then
			local remote = ReplicatedStorage:FindFirstChild("CarStealRemote")
			if remote then
				remote:FireServer("StartConnecting", car.Name)
				task.wait(STRIKE_CONNECT_TIME)
				remote:FireServer("ConnectCar", car.Name)
			end
		end
		return waitFor(function()
			return isStriked(car) or (gameMessage.time ~= messageMark and gameMessage.text:find("connected", 1, true) ~= nil)
		end, 15)
	end

	-- A clear spot on the seller's floor, beside the seller, big enough for the car. Returns the pivot.
	local function findParkingSpot(car, seller)
		local boxCFrame, size = car:GetBoundingBox()
		local pivotFromBox = boxCFrame:ToObjectSpace(car:GetPivot())
		local floorY = findGroundY(seller.Position, car) or seller.Position.Y
		local ignore = { car }
		for _, player in ipairs(Players:GetPlayers()) do
			if player.Character then
				table.insert(ignore, player.Character)
			end
		end
		local params = OverlapParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = ignore
		for _, distance in ipairs(PARK_DISTANCES) do
			for step = 0, 7 do
				local angle = step * math.pi / 4
				local direction = Vector3.new(math.cos(angle), 0, math.sin(angle))
				local spot = seller.Position + direction * distance
				local groundY = findGroundY(Vector3.new(spot.X, floorY + 8, spot.Z), car)
				if groundY and math.abs(groundY - floorY) < 8 then
					local clearance = math.clamp(size.Y / 2, 2, 5)
					local center = Vector3.new(spot.X, groundY + clearance + 0.3, spot.Z)
					-- Side-on to the seller, so the driver's door ends up near them.
					local across = direction:Cross(Vector3.yAxis)
					if across.Magnitude < 0.1 then
						across = Vector3.new(1, 0, 0)
					end
					local box = CFrame.lookAt(center, center + across.Unit)
					local blocked = false
					for _, part in ipairs(Workspace:GetPartBoundsInBox(box, size * Vector3.new(0.85, 0.7, 0.85), params)) do
						if part.CanCollide and part.Transparency < 1 then
							blocked = true
							break
						end
					end
					if not blocked then
						return box * pivotFromBox
					end
				end
			end
		end
		-- Last resort: grounded offset next to the seller (never a void Y).
		local fallback = seller.Position + Vector3.new(12, 0, 0)
		local groundY = findGroundY(fallback + Vector3.new(0, 8, 0), car) or floorY
		local clearance = math.clamp(size.Y / 2, 2, 5)
		local center = Vector3.new(fallback.X, groundY + clearance, fallback.Z)
		return CFrame.lookAt(center, Vector3.new(seller.Position.X, center.Y, seller.Position.Z)) * pivotFromBox
	end

	local function flatDist(a, b)
		return Vector3.new(a.X - b.X, 0, a.Z - b.Z).Magnitude
	end

	-- Drive the car into the seller's garage, get out, and sell it at the "SellCar" prompt on foot.
	local function sellCar(car)
		local seat = getDriveSeat(car)
		local seller = Workspace:FindFirstChild("CarSeller")
		local prompt = seller and seller:FindFirstChildWhichIsA("ProximityPrompt", true)
		local humanoid = getHumanoid()
		if not (seat and prompt and humanoid and seller:IsA("BasePart")) then
			return false, "the car seller was not found"
		end
		if humanoid.SeatPart ~= seat and not enterDriverSeat(car) then
			return false, "could not get back in the car"
		end
		local sellerPos = seller.Position
		-- Long airborne glides to the seller delete the car / kick for flying. Drive when far;
		-- only short grounded hops into the garage.
		if flatDist(seat.Position, sellerPos) > 100 then
			if not on("FlyCars") and Vehicles.selfDriveTo then
				notify("Self Driving the car to the car seller.")
				Vehicles.selfDriveTo(CFrame.new(sellerPos))
				if humanoid.SeatPart ~= seat then
					return false, "left the car on the way to the car seller"
				end
			end
		end
		if flatDist(seat.Position, sellerPos) > 180 then
			return false, "still too far from the car seller (enable Self Driving or drive closer)"
		end
		local parking = findParkingSpot(car, seller)
		if not parking then
			return false, "no room to park next to the car seller"
		end
		local parkGround = findGroundY(parking.Position, car)
		if not parkGround or parkGround < Workspace.FallenPartsDestroyHeight + 50 then
			return false, "car seller parking spot is off the map"
		end
		-- Keep the hop near ground height (bad pivot math used to launch into the void).
		parking = CFrame.new(parking.Position.X, parkGround + 3, parking.Position.Z) * (parking - parking.Position)
		local restoreCar = ghostCar(car)
		local arrived = teleportCharacter(parking, true)
		restoreCar()
		if not arrived then
			return false, "could not drive to the car seller"
		end
		landCar(car, seat)
		task.wait(0.5)
		forceUnseat(humanoid, seat)
		task.wait(0.3)

		-- Walk to the seller; any fast move right after getting out gets pulled back.
		local root = getRoot()
		if root then
			local away = Vector3.new(root.Position.X - seller.Position.X, 0, root.Position.Z - seller.Position.Z)
			away = away.Magnitude > 0.1 and away.Unit or Vector3.new(1, 0, 0)
			local stand = seller.Position + away * SELLER_DISTANCE
			local groundY = findGroundY(stand, car)
			if groundY then
				stand = Vector3.new(stand.X, groundY + getStandHeight(humanoid, root), stand.Z)
			end
			local standCF = CFrame.lookAt(stand, Vector3.new(seller.Position.X, stand.Y, seller.Position.Z))
			if (root.Position - stand).Magnitude > 12 then
				teleportOnFoot(standCF)
			else
				Pathing.walkTo(humanoid, standCF)
			end
		end

		local messageMark = gameMessage.time
		local dirtyBefore, cleanBefore = getStat("FilthyStack"), getStat("Money")
		local function sold()
			return not car.Parent
				or (gameMessage.time ~= messageMark and gameMessage.text:find("stolen car", 1, true) ~= nil)
				or getStat("FilthyStack") > dirtyBefore
				or getStat("Money") > cleanBefore
		end
		for _ = 1, 4 do
			firePrompt(prompt)
			if waitFor(sold, math.max(4, (tonumber(prompt.HoldDuration) or 0) + 1.5)) then
				return true
			end
		end
		return false, "the car seller did not take the car"
	end

	local function formatWait(seconds)
		seconds = math.ceil(seconds)
		return seconds >= 60 and ("%dm %ds"):format(seconds // 60, seconds % 60) or ("%ds"):format(seconds)
	end

	-- Break in, strike and sell one car. Returns success, reason, and whether it only failed on the cooldown.
	local function stealCarSteps(car)
		if not strikeable(car) then
			return false, "that car cannot be struck (already unlocked, someone is in it, it is yours, or already struck)"
		end
		local cooldown = robCooldownLeft()
		if cooldown > 0 and not stolenByMe(car) then
			return false, ("steal cooldown, %s left"):format(formatWait(cooldown)), true
		end
		local needBreakIn = not stolenByMe(car)
		local breakTool = breakInToolName()
		if not ensureStrikeTools(needBreakIn) then
			if countOwned("StrikePad") == 0 then
				return false, "could not get a StrikePad"
			end
			if needBreakIn and countOwned(breakTool) == 0 then
				return false, ("could not get a %s (needed to get in)"):format(breakTool)
			end
			return false, "could not buy strike tools"
		end
		-- Trips may still borrow other cars (long walks get kicked for flying), but never this one.
		avoidTravelCar = car
		local ok, brokeIn, entered = pcall(function()
			local broke = breakIn(car)
			if not broke then
				return false, false
			end
			-- Hands must be empty before Sit; give the server a moment to clear Locked.
			unequipTools()
			task.wait(0.35)
			local seatNow = getDriveSeat(car)
			waitFor(function()
				return stolenByMe(car) or (seatNow and not seatNow:FindFirstChild("Locked"))
			end, 2.5)
			-- Don't skip enter on velocity jitter from hasDriver().
			return true, enterDriverSeat(car)
		end)
		avoidTravelCar = nil
		if not ok then
			error(brokeIn, 0)
		end
		if not brokeIn then
			local cooldownNow = robCooldownLeft()
			if cooldownNow > 0 then
				return false, ("steal cooldown, %s left"):format(formatWait(cooldownNow)), true
			end
			return false, ("%s did not lockpick the car"):format(breakTool)
		end
		if not entered then
			unequipTools()
			entered = enterDriverSeat(car)
		end
		if not entered then
			return false, "could not get into the car"
		end
		waitFor(function()
			return stolenByMe(car)
		end, 3)
		if not strike(car) then
			local humanoid = getHumanoid()
			if humanoid and humanoid.SeatPart then
				forceUnseat(humanoid, humanoid.SeatPart)
			end
			return false, "the strike did not connect"
		end
		local value = carValue(car)
		local soldOk, reason = sellCar(car)
		if not soldOk then
			return false, reason
		end
		notify(("Sold %s for about $%d."):format(car.Name, value))
		return true
	end

	-- Self Driving stands by while a steal is in progress so it doesn't drive off with the car.
	local function stealCar(car)
		Vehicles.externalDrive = true
		local results = table.pack(pcall(stealCarSteps, car))
		Vehicles.externalDrive = false
		if not results[1] then
			error(results[2], 0)
		end
		return table.unpack(results, 2, results.n)
	end

	function Vehicles.strikeSelected()
		local car = getSelectedCar()
		if not car then
			return
		end
		local ok, reason = stealCar(car)
		if not ok then
			notify("Could not strike " .. car.Name .. ": " .. tostring(reason) .. ".")
		end
	end

	local function pickTarget()
		local candidates, highest = {}, 0
		for _, car in ipairs(getCivCars()) do
			if strikeable(car) and (failedCars[car] or 0) <= os.clock() then
				table.insert(candidates, car)
				highest = math.max(highest, carValue(car))
			end
		end
		if on("StrikeExpensiveOnly") then
			local filtered = {}
			for _, car in ipairs(candidates) do
				if carValue(car) >= highest * EXPENSIVE_SHARE then
					table.insert(filtered, car)
				end
			end
			candidates = filtered
		end
		local root = getRoot()
		table.sort(candidates, function(a, b)
			if not root then
				return carValue(a) > carValue(b)
			end
			return (a:GetPivot().Position - root.Position).Magnitude < (b:GetPivot().Position - root.Position).Magnitude
		end)
		return candidates[1]
	end

	local strikeGeneration = 0
	Features.AutoStrikeCars = {
		enable = function()
			strikeGeneration += 1
			local generation = strikeGeneration
			local function active()
				return on("AutoStrikeCars") and strikeGeneration == generation
			end
			local announcedWait = false
			while active() do
				local humanoid = getHumanoid()
				local cooldown = robCooldownLeft()
				if cooldown > 0 then
					if not announcedWait then
						announcedWait = true
						notify(("Next car steal in %s."):format(formatWait(cooldown)))
					end
					task.wait(math.min(cooldown, 5))
				elseif humanoid and humanoid.Health > 0 and not playerActionBusy then
					announcedWait = false
					local car = pickTarget()
					if not car then
						task.wait(5)
					else
						playerActionBusy = true
						local flagMark = teleportFlagCount
						local ok, success, reason, onCooldown = pcall(stealCar, car)
						playerActionBusy = false
						if not (ok and success) and not (ok and onCooldown) then
							failedCars[car] = os.clock() + FAILED_CAR_COOLDOWN
							notify(("Skipping %s: %s."):format(car.Name, tostring(ok and reason or success)))
						end
						if teleportFlagCount - flagMark >= MAX_STEAL_FLAGS then
							notify(("Pulled back by the anti-teleport; waiting %ds before the next car."):format(FLAG_REST_TIME))
							local restUntil = os.clock() + FLAG_REST_TIME
							while active() and os.clock() < restUntil do
								task.wait(1)
							end
						end
					end
				end
				task.wait(1)
			end
		end,
		disable = function()
			strikeGeneration += 1
		end,
	}
end)()

-- Self Driving -----------------------------------------------------------------
-- Routes come from Roblox's route planner with a car-sized agent (sidewalks and grass cost more,
-- tunnels and under-map routes are rejected), falling back to A* over a grid sampled from the map's
-- road parts. A-Chassis only reads the keyboard, so the car is driven by setting its speed and turn
-- rate and letting its own physics keep it on the ground.

Vehicles.selfDriveLocations = {}
Arsenic.Values.SelfDriveDestination = "Drive Around Map"
Arsenic.Values.SelfDriveSpeed = 60
Arsenic.Values.SelfDriveTurn = 1
Arsenic.Values.SelfDriveMode = "Civilian Mode"
Arsenic.Values.TaxiDropOff = "Gas Station"
Vehicles.externalDrive = false
;(function()
	local DRIVE_AROUND = "Drive Around Map"
	local UserInputService = game:GetService("UserInputService")
	-- How far ahead along the route the car steers towards.
	local LOOKAHEAD = 11
	-- Feelers ahead of the bumper that slow the car and steer it away from walls and parked cars.
	local FEELER_ANGLE = math.rad(32)
	-- Low enough to catch curbs, so the car treats the sidewalk edge as a wall.
	local FEELER_HEIGHT = 1.15
	-- Cap feeler length at speed — uncapped reach made distant trees/buildings look like walls.
	local FEELER_REACH_BASE = 12
	local FEELER_REACH_PER_SPEED = 0.22
	local FEELER_REACH_MAX = 22
	-- Pinned this close to something for this long counts as blocked.
	local BLOCK_DISTANCE = 4
	local BLOCK_TIME = 0.9
	local DEBUG_ROUTE = Color3.fromRGB(60, 255, 120)
	local DEBUG_TARGET = Color3.fromRGB(255, 220, 40)
	local DEBUG_CLEAR = Color3.fromRGB(255, 255, 255)
	local DEBUG_HIT = Color3.fromRGB(255, 50, 50)
	local ARRIVE_DISTANCE = 8
	local SEAT_HEIGHT = 3
	-- Places a car can't drive up to (rooftops, sky stores, inside tall buildings).
	-- Upper-city roads (Market ~333, Construction ~370) sit above the old 300 cap.
	local MAX_DRIVE_HEIGHT = 420
	local CELL = 12
	-- Studs of climb allowed per grid step (and per seam hop). Stepped HitBoxRoad stairs and
	-- StreetRain2 wedges need more than a flat-road gap.
	local MAX_STEP_RISE = 14
	-- Empty cells a route may hop between road pieces (upper-city ramps leave 2-cell gaps).
	local MAX_SEAM_HOP = 3
	-- Head room a car needs above the road surface.
	local CAR_CLEARANCE = 7
	-- Where each road cell is checked for obstructions: its middle and four spots around it.
	local CELL_SAMPLES = {
		Vector3.zero,
		Vector3.new(4, 0, 0),
		Vector3.new(-4, 0, 0),
		Vector3.new(0, 0, 4),
		Vector3.new(0, 0, -4),
	}
	-- Cells the car got blocked in are avoided for this long.
	local BLOCKED_TIME = 120
	local LEG_LENGTH = 900
	-- A route this far below both ends, under a ceiling, is a tunnel or under the map.
	local UNDERGROUND_DROP = 12
	local ACCELERATION = 25
	local BRAKING = 45
	local STEER_GAIN = 6
	local MAX_YAW_RATE = math.rad(170)
	-- Slowest the car takes a right-angle corner; gentler bends are taken proportionally faster.
	local MIN_CORNER_SPEED = 22
	-- Share of the way the car's travel direction leans into the turn ahead of its nose, like tyres
	-- gripping through a corner; keeps it on the line instead of swinging wide.
	local TRACK_BLEND = 0.35
	local DEFAULT_SPEED = 60
	-- How each driving mode drives: multipliers on top speed and turning, corner speed, pedal
	-- response, how hard it leans into the line, how much the feelers can pull it, and drifting.
	local MODES = {
		["Civilian Mode"] = { speed = 1, turn = 1, corner = MIN_CORNER_SPEED, accel = ACCELERATION, brake = BRAKING, blend = TRACK_BLEND, feeler = 0.5, reverse = 1 },
		["Chase Mode"] = { speed = 1.5, turn = 1.5, corner = 38, accel = 45, brake = 75, blend = 0.45, feeler = 0.35, reverse = 2.6 },
		["Slide Mode"] = { speed = 1.35, turn = 1.7, corner = 32, accel = 40, brake = 60, blend = 0.2, feeler = 0.9, slide = true, reverse = 3 },
		-- Used on its own while the car is damaged (and nobody is shooting at us).
		Careful = { speed = 0.7, turn = 0.9, corner = 16, accel = 18, brake = 50, blend = TRACK_BLEND, feeler = 0.7, reverse = 0.85 },
	}
	-- Slide Mode: how quickly the car's travel catches up with where it points (lower = longer
	-- slides), and the widest angle it slides at before the tyres bite.
	local SLIDE_GRIP = 5
	local MAX_SLIP = math.rad(30)
	-- Steering looks further ahead the faster the car goes, so fast driving doesn't weave.
	local LOOKAHEAD_PER_SPEED = 0.22
	-- Further from its route than this, the car is off it and a fresh route is planned from the car.
	-- Grows a little with speed so fast driving doesn't constantly "leave" the line and U-turn.
	local OFF_ROUTE = 25
	local OFF_ROUTE_PER_SPEED = 0.12
	-- Background replans join the current route this far ahead of the car (at least), and only
	-- the first stretch of routes that will be replaced soon anyway gets centered.
	local JOIN_AHEAD = 30
	-- Off-road checks: sample spacing, steepest climb a car route may take (stairs are steeper),
	-- and how far from either end of a planner route it may be off the road.
	local ROAD_SAMPLE = 6
	local MAX_SLOPE = 0.7
	local PLANNER_GRACE = 30
	-- Nearest road spots checked for a clear view of a destination.
	local SIGHT_CHECKS = 80
	-- Hitting something this close to the destination still counts as seeing it (its door or front).
	local SIGHT_SLACK = 10
	-- Drive Around Map exploring: region size, fewest road spots for a region to count, nearest
	-- target, preferred trip length, and how strongly visits (and being picked) count against a region.
	local EXPLORE_REGION = 250
	local EXPLORE_MIN_NODES = 12
	local EXPLORE_MIN_DISTANCE = 300
	local EXPLORE_IDEAL_DISTANCE = 900
	local EXPLORE_VISIT_WEIGHT = 0.5
	local EXPLORE_PICK_VISITS = 6
	local QUICK_CENTER = 1000
	-- Damage: someone in the car losing health puts us under fire for UNDER_FIRE_TIME (drive like
	-- Chase Mode, away from players); the car taking damage or crashing hard means driving
	-- carefully for CAREFUL_TIME. LOW_HEALTH or a car at WRECKED of its health breaks off chases.
	local UNDER_FIRE_TIME = 15
	local CAREFUL_TIME = 8
	local LOW_HEALTH = 40
	local WRECKED = 0.3
	local IMPACT_SPEED = 35
	-- After anyone in the car shoots, drive in Slide Mode this long.
	local SHOOTING_TIME = 6
	-- Car/occupant damage keeps Chase Mode this long; severity boosts speed/turn up to this much.
	local DAMAGE_CHASE_TIME = 14
	local DAMAGE_BOOST_MAX = 0.85
	-- World adaptation: players and cars this close change speed and turning.
	local WORLD_ADAPT_RADIUS = 140
	-- Players this close count as a threat (Chase Mode escapes them; adaptive drives switch to Chase).
	local THREAT_RADIUS = 600
	local ADAPT_RADIUS = 150
	local FOLLOW_PLAYER = "Follow Selected Player"
	local TAXI_PLAYER = "Taxi Selected Player"
	local TAXI_WAIT = 45
	-- Chase Mode re-picks where to escape to this often; Slide Mode re-plans towards its target this often.
	local ESCAPE_REPLAN = 10
	-- Slide chases need fresh road ahead of the car; 2.5s left it on a stub path into curbs.
	local CHASE_REPLAN = 0.7
	-- Within this distance Slide Mode drives straight at its target instead of planning a route.
	-- Kept short so chases don't cut through blocks; longer gaps stay on the road grid.
	local CLOSE_CHASE = 55
	-- Continuous chase: replan from the car when less than this much path remains.
	local CHASE_MIN_PATH = 90
	-- Parking lots are only driven through to start or finish a trip; each lot cell costs this much.
	local LOT_COST = 8
	-- Extra cost for hopping a one-cell seam between road pieces.
	local GAP_COST = 3
	-- Added to the score of road spots behind the car when a route starts.
	local BEHIND_PENALTY = 90
	local BEHIND_TRIM = 55
	-- How often route-change notices may fire (avoids spam while chasing/replanning).
	local ROUTE_NOTICE_GAP = 4
	local ROUTE_WHYS = {
		short = "path running out",
		["end"] = "nearing end of path",
		due = "refreshing path",
		hurt = "taking damage",
		offroute = "left the route",
		stuck = "got stuck",
		destination = "destination changed",
		chase = "chasing target",
		blocked = "road blocked",
		uturn = "correcting a U-turn",
		plan = "new route",
		extend = "extending route",
	}
	-- Start planning the next stretch this far before the current one ends.
	local EXTEND_AHEAD = 250
	-- At speed, the next stretch is planned this many seconds of driving ahead, and replans join
	-- the current route this many seconds ahead of the car (so faster driving plans further out).
	local EXTEND_SECONDS = 6
	local JOIN_SECONDS = 1.5
	local MAX_LEGS = 20
	local REVERSE_SPEED = 24
	local REVERSE_TIME = 0.9
	-- After a reverse, wait this long before reversing again (stops reverse/spin loops).
	local REVERSE_COOLDOWN = 1.1
	local STUCK_TIME = 1.25
	local MAX_STUCK = 5
	local MAX_REPLANS = 8
	local SIDEWALK_NAMES = {
		sidewalk556 = true,
		sidewalk_corner = true,
		sidewalk_01_a = true,
		sidewalk_01_ate = true,
		sidewalk123 = true,
		sidewalks = true,
		sidewalkv2 = true,
		sidewalkv3 = true,
		sidewalkv5 = true,
	}

	local function isSidewalk(part)
		if not part then
			return false
		end
		local name = part.Name:lower()
		return SIDEWALK_NAMES[name] or name:find("sidewalk", 1, true) ~= nil
	end

	-- Thin tall collidable slabs (hospital/map barriers like wa3w) that sit on the roadside.
	local function isBarrierWall(part)
		if not (part and part:IsA("BasePart") and part.CanCollide) then
			return false
		end
		local size = part.Size
		local a, b, c = size.X, size.Y, size.Z
		if a > b then
			a, b = b, a
		end
		if b > c then
			b, c = c, b
		end
		if a > b then
			a, b = b, a
		end
		-- a = thinnest, c = longest
		if a > 2.5 or b < 4 or c < 12 then
			return false
		end
		local name = part.Name:lower()
		return part.Transparency >= 0.2
			or not part.CanQuery
			or name:find("wa3", 1, true) ~= nil
			or name == "default"
			or name:find("barrier", 1, true) ~= nil
			or name:find("invisible", 1, true) ~= nil
	end
	local CAR_AGENT = {
		AgentRadius = 4,
		AgentHeight = 6,
		AgentCanJump = false,
		WaypointSpacing = 8,
		Costs = { Water = math.huge, Sidewalk = 8, Grass = 4, LeafyGrass = 4, Mud = 4, Sand = 4 },
	}
	-- Extra cost for the outermost and second-outermost road cells, so routes keep to the middle.
	local EDGE_COSTS = { 12, 5, 1.5 }
	-- Route centering: probe spacing across the road, how far to look for an edge, point spacing
	-- along the route, and the largest sideways correction.
	local CENTER_STEP = 3
	local CENTER_SCAN = 50
	local CENTER_SPACING = 16
	local MAX_CENTER_SHIFT = 20
	-- Roads wider than this (highways) have no single middle and are left as routed. Centering
	-- shifts are averaged over this many points either side, change by at most MAX_SHIFT_STEP
	-- per point, and fade out over SHIFT_FADE points where the road edges can't be found.
	local WIDE_ROAD = 60
	local SHIFT_WINDOW = 2
	local MAX_SHIFT_STEP = 3
	local SHIFT_FADE = 3
	local START_SNAP_CELLS = 12
	local GOAL_SNAP_CELLS = 25
	local ROAD_NAMES = {
		hitboxroad = true,
		street = true,
		road = true,
		road44 = true,
		streetrain2 = true,
		["street part"] = true,
		crosswalk_01_a = true,
		roadmark = true,
		-- Highway decks and ramps.
		free = true,
		wgite = true,
	}
	local DIRECTIONS = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 }, { 1, 1 }, { 1, -1 }, { -1, 1 }, { -1, -1 } }
	local OPPOSITE = { 2, 1, 4, 3, 8, 7, 6, 5 }
	-- Heights above the road checked for fences and walls between road cells.
	local LINK_HEIGHTS = { 2, 3.5 }
	-- Hidden solid parts: bin size for looking them up, and the smallest one worth tracking.
	local HIDDEN_BIN = 48
	local HIDDEN_MIN_SIZE = 1.5
	-- Route starts only snap to road this close to the car's height. Unmapped surfaces the car is
	-- on are learned as road if at least LEARN_MIN_WIDTH across, within LEARN_RADIUS of the car.
	-- Same deck first (bridge vs highway under it), then a wider rise for real ramps/hills.
	local SAME_LEVEL_RISE = 10
	local START_MAX_RISE = 28
	-- Goal spots tried before giving up on a route, at least this many cells apart.
	local GOAL_ATTEMPTS = 6
	local GOAL_RETRY_SPACING = 6
	local LEARN_MIN_WIDTH = 16
	local LEARN_RADIUS = 600
	local MIN_ROAD_WIDTH = 6
	-- Named HitBoxRoad stair/ramp strips are often only a couple studs wide.
	local MIN_HITBOX_ROAD_WIDTH = 1.5
	local GENERIC_SURFACES = {
		[Enum.Material.Asphalt] = true,
		[Enum.Material.Concrete] = true,
		[Enum.Material.Pavement] = true,
		[Enum.Material.Slate] = true,
	}
	local GENERIC_MIN_WIDTH = 20
	local GENERIC_MIN_LENGTH = 40
	-- Road surfaces steeper than this (normal's up component; about 18 degrees) are embankments
	-- and walls, not roads.
	local MIN_ROAD_NORMAL = 0.95
	-- Road cells linked into a network at least this big count as the real road network
	-- (smaller ones are rooftops, courtyards and cut-off scraps).
	local MAJOR_NETWORK = 150
	local NOT_ROAD_MATERIALS = {
		[Enum.Material.Grass] = true,
		[Enum.Material.LeafyGrass] = true,
		[Enum.Material.Ground] = true,
		[Enum.Material.Mud] = true,
		[Enum.Material.Sand] = true,
		[Enum.Material.Metal] = true,
		[Enum.Material.DiamondPlate] = true,
	}
	-- Surfaces the car drives slower on.
	local ROUGH_MATERIALS = {
		[Enum.Material.Grass] = true,
		[Enum.Material.LeafyGrass] = true,
		[Enum.Material.Ground] = true,
		[Enum.Material.Mud] = true,
		[Enum.Material.Sand] = true,
		[Enum.Material.Snow] = true,
	}
	local ROUGH_SPEED = 0.75
	-- Hits facing up more than this are ground or ramps, not obstacles.
	-- Lower than 0.6 so angled feelers into the road deck don't read as walls.
	local GROUND_NORMAL = 0.42
	-- Hills: least speed carried into a climb (plus this much per unit of grade), extra pedal for
	-- climbing, how much to ease off downhill, and the grade below which the road counts as flat.
	local HILL_SPEED = 28
	local HILL_SPEED_PER_GRADE = 90
	local HILL_ACCEL = 3
	local DOWNHILL_EASE = 0.8
	local FLAT_GRADE = 0.05
	-- A climb that stalls backs down this long for a run-up instead of avoiding the hill.
	local RUN_UP_TIME = 1.6
	local HILL_RETRIES = 3

	local driveGeneration = 0
	local threatsNear
	local lastRouteNotice = 0
	local function notifyRoute(why)
		-- Quiet reasons fire every few seconds; only toast meaningful driver-facing events.
		if why == "short" or why == "end" or why == "due" or why == "plan" or why == "extend" or why == "chase" or why == "blocked" then
			return
		end
		local label = ROUTE_WHYS[why] or why or "updating path"
		if os.clock() - lastRouteNotice < ROUTE_NOTICE_GAP then
			return
		end
		lastRouteNotice = os.clock()
		notify("Self Driving: " .. label .. ".")
	end
	-- nil = not built yet, false = no roads found, otherwise { cells, include }.
	local roads = nil
	-- Solid parts raycasts can't see (CanQuery off: invisible walls, gates, glass), binned by area
	-- so they can be checked with plain geometry.
	local hiddenBins = {}
	local buildingRoads = false

	local function cellKey(ix, iz)
		return ix * 65536 + iz
	end

	local function isRoadPart(part)
		if not part:IsA("BasePart") or part.Position.Y > MAX_DRIVE_HEIGHT or isSidewalk(part) then
			return false
		end
		if ROAD_NAMES[part.Name:lower()] then
			-- Some stairs (treads, risers, rails) and a grass hill are named like roads too: a road
			-- has a car-sized top and isn't grass or metal.
			if NOT_ROAD_MATERIALS[part.Material] then
				return false
			end
			local cf, half = part.CFrame, part.Size / 2
			local right, up, back = cf.RightVector, cf.UpVector, cf.LookVector
			local extentX = math.abs(right.X) * half.X + math.abs(up.X) * half.Y + math.abs(back.X) * half.Z
			local extentZ = math.abs(right.Z) * half.X + math.abs(up.Z) * half.Y + math.abs(back.Z) * half.Z
			local width = math.min(extentX, extentZ) * 2
			local length = math.max(extentX, extentZ) * 2
			-- Thin HitBoxRoad stair strips still count if they're long enough to drive along.
			if part.Name:lower() == "hitboxroad" then
				return length >= MIN_ROAD_WIDTH and width >= MIN_HITBOX_ROAD_WIDTH
			end
			return width >= MIN_ROAD_WIDTH
		end
		-- Large flat unnamed slabs (asphalt, concrete, pavement, slate) are parking lots,
		-- forecourts and roads the map doesn't name; they're used, but routes prefer named roads.
		if GENERIC_SURFACES[part.Material] and part.CanCollide and part.CanQuery and part.Transparency < 0.9 then
			local cf, half = part.CFrame, part.Size / 2
			local right, up, back = cf.RightVector, cf.UpVector, cf.LookVector
			local extentX = math.abs(right.X) * half.X + math.abs(up.X) * half.Y + math.abs(back.X) * half.Z
			local extentY = math.abs(right.Y) * half.X + math.abs(up.Y) * half.Y + math.abs(back.Y) * half.Z
			local extentZ = math.abs(right.Z) * half.X + math.abs(up.Z) * half.Y + math.abs(back.Z) * half.Z
			if extentY * 2 < 6 and math.min(extentX, extentZ) * 2 >= GENERIC_MIN_WIDTH and math.max(extentX, extentZ) * 2 >= GENERIC_MIN_LENGTH then
				return true, true
			end
		end
		return false
	end

	local function hiddenBin(x, z)
		return cellKey(math.floor(x / HIDDEN_BIN), math.floor(z / HIDDEN_BIN))
	end

	local function addHidden(part)
		local cf, half = part.CFrame, part.Size / 2
		local right, up, back = cf.RightVector, cf.UpVector, cf.LookVector
		local extentX = math.abs(right.X) * half.X + math.abs(up.X) * half.Y + math.abs(back.X) * half.Z
		local extentZ = math.abs(right.Z) * half.X + math.abs(up.Z) * half.Y + math.abs(back.Z) * half.Z
		local center = cf.Position
		for bx = math.floor((center.X - extentX) / HIDDEN_BIN), math.floor((center.X + extentX) / HIDDEN_BIN) do
			for bz = math.floor((center.Z - extentZ) / HIDDEN_BIN), math.floor((center.Z + extentZ) / HIDDEN_BIN) do
				local key = cellKey(bx, bz)
				local bin = hiddenBins[key]
				if not bin then
					bin = {}
					hiddenBins[key] = bin
				end
				table.insert(bin, part)
			end
		end
	end

	-- How far along `direction` (a unit vector) a hidden solid part is, up to `length`; nil if none.
	local function hiddenHit(origin, direction, length)
		if next(hiddenBins) == nil then
			return nil
		end
		local seen, nearest = {}, nil
		local steps = math.max(math.ceil(length / (HIDDEN_BIN * 0.5)), 1)
		for step = 0, steps do
			local point = origin + direction * (length * step / steps)
			for _, part in ipairs(hiddenBins[hiddenBin(point.X, point.Z)] or {}) do
				if not seen[part] then
					seen[part] = true
					if part.Parent and part.CanCollide and not isSidewalk(part) and not isRoadPart(part) then
						-- Only skip thin horizontal toppers. Size.Y < 8 wrongly ignored upright
						-- fences/hedges (~4–7 studs tall) and let Slide Mode route through them.
						local cf0 = part.CFrame
						local thickY = (math.abs(cf0.RightVector.Y) * part.Size.X
							+ math.abs(cf0.UpVector.Y) * part.Size.Y
							+ math.abs(cf0.LookVector.Y) * part.Size.Z)
						if cf0.UpVector.Y > 0.7 and thickY < 2.5 then
							continue
						end
						-- Ray against the part's box, in the part's own space.
						local cf, half = part.CFrame, part.Size / 2
						local o = cf:PointToObjectSpace(origin)
						local d = cf:VectorToObjectSpace(direction * length)
						local enter, leave = 0, 1
						for _, axis in ipairs({ "X", "Y", "Z" }) do
							local oa, da, ha = o[axis], d[axis], half[axis]
							if math.abs(da) < 1e-6 then
								if math.abs(oa) > ha then
									enter, leave = 1, 0
									break
								end
							else
								local t1, t2 = (-ha - oa) / da, (ha - oa) / da
								if t1 > t2 then
									t1, t2 = t2, t1
								end
								enter, leave = math.max(enter, t1), math.min(leave, t2)
								if enter > leave then
									break
								end
							end
						end
						if enter <= leave then
							local distance = enter * length
							if not nearest or distance < nearest then
								nearest = distance
							end
						end
					end
				end
			end
		end
		return nearest
	end

	-- Anything solid sitting on the road surface at `surface` (sidewalks laid over street parts,
	-- walls, fences, poles), looking down from car height so we never start inside it. Many
	-- sidewalks and walls can't be raycast, so the hidden parts are checked too.
	local function obstructed(clearance, surface)
		local origin = surface + Vector3.new(0, CAR_CLEARANCE, 0)
		if Workspace:Raycast(origin, Vector3.new(0, -(CAR_CLEARANCE - 0.3), 0), clearance) then
			return true
		end
		return hiddenHit(origin, Vector3.new(0, -1, 0), CAR_CLEARANCE - 0.3) ~= nil
	end

	-- Whether a car can drive straight from road cell `a` to road cell `b`: nothing solid (fence,
	-- wall, barrier) across the way at bumper or roof height. On hills the probe rides above the
	-- slope so the road deck / stair faces don't read as walls.
	local function linkOpen(clearance, a, b)
		local rise = math.abs((b.y or 0) - (a.y or 0))
		for _, height in ipairs(LINK_HEIGHTS) do
			local clear = height + rise * 0.35 + 0.5
			local from = Vector3.new(a.ix * CELL, a.y + clear, a.iz * CELL)
			local to = Vector3.new(b.ix * CELL, b.y + clear, b.iz * CELL)
			if Workspace:Raycast(from, to - from, clearance) then
				return false
			end
			local span = (to - from).Magnitude
			if span > 1e-3 and hiddenHit(from, (to - from) / span, span) then
				return false
			end
		end
		return true
	end

	local function buildRoads()
		local map = Workspace:FindFirstChild("1# Map") or Workspace
		table.clear(hiddenBins)
		local parts = {}
		local lotParts = {}
		local barriers = {}
		for i, descendant in ipairs(map:GetDescendants()) do
			local road, lot = isRoadPart(descendant)
			if road then
				table.insert(parts, descendant)
				if lot then
					lotParts[descendant] = true
				end
			elseif descendant:IsA("BasePart") and isSidewalk(descendant) then
				-- Sidewalks are often CanQuery=false; never treat them as invisible walls.
			elseif descendant:IsA("BasePart") and isBarrierWall(descendant) and descendant.Position.Y < MAX_DRIVE_HEIGHT then
				table.insert(barriers, descendant)
				if not descendant.CanQuery then
					addHidden(descendant)
				end
			elseif descendant:IsA("BasePart") and not descendant.CanQuery and descendant.CanCollide
				and descendant.Position.Y < MAX_DRIVE_HEIGHT and math.max(descendant.Size.X, descendant.Size.Y, descendant.Size.Z) >= HIDDEN_MIN_SIZE
				and not isSidewalk(descendant) then
				addHidden(descendant)
			end
			if i % 20000 == 0 then
				task.wait()
			end
		end
		if #parts == 0 then
			return false
		end
		-- Invisible walls can live outside the map folder too (map edges, barriers).
		if map ~= Workspace then
			for _, child in ipairs(Workspace:GetChildren()) do
				if child ~= map and not VEHICLE_FOLDERS[child.Name] and not Players:GetPlayerFromCharacter(child) and child ~= Workspace.CurrentCamera then
					for i, descendant in ipairs(child:GetDescendants()) do
						if descendant:IsA("BasePart") and not descendant.CanQuery and descendant.CanCollide
							and descendant.Position.Y < MAX_DRIVE_HEIGHT and math.max(descendant.Size.X, descendant.Size.Y, descendant.Size.Z) >= HIDDEN_MIN_SIZE
							and not isSidewalk(descendant) then
							addHidden(descendant)
						end
						if i % 20000 == 0 then
							task.wait()
						end
					end
				end
			end
		end

		local include = RaycastParams.new()
		include.FilterType = Enum.RaycastFilterType.Include
		include.FilterDescendantsInstances = parts
		local ignore = { Workspace.CurrentCamera }
		for name in pairs(VEHICLE_FOLDERS) do
			local folder = Workspace:FindFirstChild(name)
			if folder then
				table.insert(ignore, folder)
			end
		end
		for _, player in ipairs(Players:GetPlayers()) do
			if player.Character then
				table.insert(ignore, player.Character)
			end
		end
		for _, part in ipairs(parts) do
			table.insert(ignore, part)
		end
		local clearance = RaycastParams.new()
		clearance.FilterType = Enum.RaycastFilterType.Exclude
		clearance.FilterDescendantsInstances = ignore
		pcall(function()
			clearance.RespectCanCollide = true
		end)

		local cells = {}
		local rays = 0
		for _, part in ipairs(parts) do
			local cf, half = part.CFrame, part.Size / 2
			local right, up, back = cf.RightVector, cf.UpVector, cf.LookVector
			local extentX = math.abs(right.X) * half.X + math.abs(up.X) * half.Y + math.abs(back.X) * half.Z
			local extentY = math.abs(right.Y) * half.X + math.abs(up.Y) * half.Y + math.abs(back.Y) * half.Z
			local extentZ = math.abs(right.Z) * half.X + math.abs(up.Z) * half.Y + math.abs(back.Z) * half.Z
			local center = cf.Position
			for ix = math.ceil((center.X - extentX) / CELL), math.floor((center.X + extentX) / CELL) do
				for iz = math.ceil((center.Z - extentZ) / CELL), math.floor((center.Z + extentZ) / CELL) do
					local key = cellKey(ix, iz)
					if cells[key] == nil then
						rays += 1
						if rays % 3000 == 0 then
							task.wait()
						end
						local top = Vector3.new(ix * CELL, center.Y + extentY + 2, iz * CELL)
						local hit = Workspace:Raycast(top, Vector3.new(0, -(extentY * 2 + 4), 0), include)
						if hit and hit.Normal.Y < MIN_ROAD_NORMAL then
							cells[key] = false
						elseif hit then
							local open = true
							for _, offset in ipairs(CELL_SAMPLES) do
								-- Check from the road's own height at each sample, so hills aren't mistaken for walls.
								local sample = hit.Position + offset
								local surface = Workspace:Raycast(sample + Vector3.new(0, 4, 0), Vector3.new(0, -8, 0), include)
								if obstructed(clearance, surface and surface.Position or sample) then
									open = false
									break
								end
							end
							cells[key] = open
									and { ix = ix, iz = iz, y = hit.Position.Y, edge = 0, lot = lotParts[hit.Instance] == true }
								or false
						end
					end
				end
			end
		end

		-- Which neighbouring cells are really connected; a fence between two road cells (which the
		-- spot checks can miss) cuts that step.
		local linkRays = 0
		for _, node in pairs(cells) do
			if node then
				node.links = {}
				for index, direction in ipairs(DIRECTIONS) do
					local neighbour = cells[cellKey(node.ix + direction[1], node.iz + direction[2])]
					if neighbour then
						local known = neighbour.links and neighbour.links[OPPOSITE[index]]
						if known == nil then
							linkRays += 1
							if linkRays % 1500 == 0 then
								task.wait()
							end
							known = linkOpen(clearance, node, neighbour)
						end
						node.links[index] = known
					end
				end
			end
		end

		-- Mark the road's outer rings of cells so routes stay off the curb.
		for ring = 1, #EDGE_COSTS do
			local marked = {}
			for _, node in pairs(cells) do
				if node and node.edge == 0 then
					for _, direction in ipairs(DIRECTIONS) do
						local neighbour = cells[cellKey(node.ix + direction[1], node.iz + direction[2])]
						if not neighbour or (ring > 1 and neighbour.edge == ring - 1) then
							table.insert(marked, node)
							break
						end
					end
				end
			end
			for _, node in ipairs(marked) do
				node.edge = ring
			end
		end
		local seamParams = RaycastParams.new()
		seamParams.FilterType = Enum.RaycastFilterType.Exclude
		local seamIgnore = { Workspace.CurrentCamera }
		for name in pairs(VEHICLE_FOLDERS) do
			local folder = Workspace:FindFirstChild(name)
			if folder then
				table.insert(seamIgnore, folder)
			end
		end
		seamParams.FilterDescendantsInstances = seamIgnore
		pcall(function()
			seamParams.RespectCanCollide = true
		end)
		-- Drop road cells that sit against thin hospital/map walls so routes never aim into them.
		local cleared = 0
		for _, wall in ipairs(barriers) do
			local cf, half = wall.CFrame, wall.Size / 2
			local right, up, back = cf.RightVector, cf.UpVector, cf.LookVector
			local extentX = math.abs(right.X) * half.X + math.abs(up.X) * half.Y + math.abs(back.X) * half.Z
			local extentZ = math.abs(right.Z) * half.X + math.abs(up.Z) * half.Y + math.abs(back.Z) * half.Z
			local pad = CELL * 1.25
			local center = cf.Position
			for ix = math.floor((center.X - extentX - pad) / CELL), math.ceil((center.X + extentX + pad) / CELL) do
				for iz = math.floor((center.Z - extentZ - pad) / CELL), math.ceil((center.Z + extentZ + pad) / CELL) do
					local key = cellKey(ix, iz)
					local node = cells[key]
					if node then
						local sample = Vector3.new(ix * CELL, node.y + 2.5, iz * CELL)
						local toWall = wall.Position - sample
						local flat = Vector3.new(toWall.X, 0, toWall.Z)
						if flat.Magnitude < CELL * 2.2 then
							-- Cell is within a car-width of the wall footprint.
							local hit = Workspace:Raycast(sample, flat.Unit * math.min(flat.Magnitude + 2, CELL * 2), clearance)
							local hidden = flat.Magnitude > 1e-3 and hiddenHit(sample, flat.Unit, math.min(flat.Magnitude + 2, CELL * 2))
							if (hit and hit.Instance == wall) or hidden then
								cells[key] = false
								cleared += 1
							elseif flat.Magnitude < CELL * 0.85 then
								cells[key] = false
								cleared += 1
							end
						end
					end
				end
			end
			if cleared % 200 == 0 then
				task.wait()
			end
		end

		local partSet = {}
		for _, part in ipairs(parts) do
			partSet[part] = true
		end
		return {
			cells = cells,
			include = include,
			parts = parts,
			partSet = partSet,
			clearance = clearance,
			seamParams = seamParams,
			blocked = {},
		}
	end

	local function getRoads()
		if roads == nil and not buildingRoads then
			buildingRoads = true
			notify("Mapping the roads for Self Driving (first time only)...")
			local ok, result = pcall(buildRoads)
			roads = ok and result or false
			buildingRoads = false
		end
		while buildingRoads do
			task.wait(0.2)
		end
		return roads or nil
	end

	-- With `ahead` (the car's flat facing), spots behind the car are avoided so a new route doesn't
	-- start by turning around.
	-- Which connected road network each cell belongs to (by open links), and each network's size;
	-- worked out once and again after new road is learned.
	local function networkLabels(network)
		if network.labels then
			return network.labels, network.labelSizes
		end
		local labels, sizes = {}, {}
		local nextLabel, visited = 0, 0
		for _, node in pairs(network.cells) do
			if node and not labels[node] then
				nextLabel += 1
				labels[node] = nextLabel
				local queue, head = { node }, 1
				while head <= #queue do
					local current = queue[head]
					head += 1
					visited += 1
					if visited % 5000 == 0 then
						task.wait()
					end
					for index, direction in ipairs(DIRECTIONS) do
						if current.links and current.links[index] then
							local neighbour = network.cells[cellKey(current.ix + direction[1], current.iz + direction[2])]
							if neighbour and not labels[neighbour] then
								labels[neighbour] = nextLabel
								table.insert(queue, neighbour)
							end
						end
					end
				end
				sizes[nextLabel] = #queue
			end
		end
		network.labels, network.labelSizes = labels, sizes
		return labels, sizes
	end

	local function onMajorNetwork(network, node)
		local labels, sizes = networkLabels(network)
		return (sizes[labels[node]] or 0) >= MAJOR_NETWORK
	end

	-- How many cells (up to the deepest curb ring) a road cell is from the road's edge; 0 = middle.
	local function edgeRing(network, node)
		for ring = 1, #EDGE_COSTS do
			for dx = -ring, ring do
				for dz = -ring, ring do
					if math.max(math.abs(dx), math.abs(dz)) == ring and not network.cells[cellKey(node.ix + dx, node.iz + dz)] then
						return ring
					end
				end
			end
		end
		return 0
	end

	-- A car can be on a road surface the map doesn't name as one (a bridge deck, a ramp): if the
	-- ground under it is a wide, solid, non-grass, non-sidewalk part, it is added to the road map
	-- (cells, links and curb rings) around the car. Returns true if anything was added.
	local function learnSurface(network, position, car)
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		local ignore = { car, Workspace.CurrentCamera }
		for _, player in ipairs(Players:GetPlayers()) do
			if player.Character then
				table.insert(ignore, player.Character)
			end
		end
		params.FilterDescendantsInstances = ignore
		pcall(function()
			params.RespectCanCollide = true
		end)
		local hit = Workspace:Raycast(position + Vector3.new(0, 1, 0), Vector3.new(0, -(SEAT_HEIGHT + 8), 0), params)
		local part = hit and hit.Instance
		if not part or network.partSet[part] or hit.Normal.Y < 0.8 or not part:IsA("BasePart") then
			return false
		end
		network.partSet[part] = true
		if isSidewalk(part) or NOT_ROAD_MATERIALS[part.Material] or part.Position.Y > MAX_DRIVE_HEIGHT then
			return false
		end
		local cf, half = part.CFrame, part.Size / 2
		local right, up, back = cf.RightVector, cf.UpVector, cf.LookVector
		local extentX = math.abs(right.X) * half.X + math.abs(up.X) * half.Y + math.abs(back.X) * half.Z
		local extentY = math.abs(right.Y) * half.X + math.abs(up.Y) * half.Y + math.abs(back.Y) * half.Z
		local extentZ = math.abs(right.Z) * half.X + math.abs(up.Z) * half.Y + math.abs(back.Z) * half.Z
		if math.min(extentX, extentZ) * 2 < LEARN_MIN_WIDTH then
			return false
		end
		table.insert(network.parts, part)
		local ok = pcall(function()
			network.include:AddToFilter(part)
			network.clearance:AddToFilter(part)
		end)
		if not ok then
			network.include.FilterDescendantsInstances = network.parts
		end
		local center = cf.Position
		local added = {}
		local function clampIndex(value, low, high)
			return math.clamp(value, math.ceil(low / CELL), math.floor(high / CELL))
		end
		local x0 = clampIndex(math.ceil((position.X - LEARN_RADIUS) / CELL), center.X - extentX, center.X + extentX)
		local x1 = clampIndex(math.floor((position.X + LEARN_RADIUS) / CELL), center.X - extentX, center.X + extentX)
		local z0 = clampIndex(math.ceil((position.Z - LEARN_RADIUS) / CELL), center.Z - extentZ, center.Z + extentZ)
		local z1 = clampIndex(math.floor((position.Z + LEARN_RADIUS) / CELL), center.Z - extentZ, center.Z + extentZ)
		local rays = 0
		for ix = x0, x1 do
			for iz = z0, z1 do
				local key = cellKey(ix, iz)
				if not network.cells[key] then
					rays += 1
					if rays % 400 == 0 then
						task.wait()
					end
					local top = Vector3.new(ix * CELL, center.Y + extentY + 2, iz * CELL)
					local surface = Workspace:Raycast(top, Vector3.new(0, -(extentY * 2 + 4), 0), network.include)
					if surface and surface.Instance == part and surface.Normal.Y >= MIN_ROAD_NORMAL then
						local open = true
						for _, offset in ipairs(CELL_SAMPLES) do
							local sample = surface.Position + offset
							local below = Workspace:Raycast(sample + Vector3.new(0, 4, 0), Vector3.new(0, -8, 0), network.include)
							if obstructed(network.clearance, below and below.Position or sample) then
								open = false
								break
							end
						end
						if open then
							local node = { ix = ix, iz = iz, y = surface.Position.Y, edge = 0, lot = false, links = {} }
							network.cells[key] = node
							table.insert(added, node)
						end
					end
				end
			end
		end
		if #added == 0 then
			return false
		end
		for _, node in ipairs(added) do
			for index, direction in ipairs(DIRECTIONS) do
				local neighbour = network.cells[cellKey(node.ix + direction[1], node.iz + direction[2])]
				if neighbour then
					local open = linkOpen(network.clearance, node, neighbour)
					node.links[index] = open
					neighbour.links = neighbour.links or {}
					neighbour.links[OPPOSITE[index]] = open
				end
			end
		end
		-- Curb rings change for the new cells and the road around them.
		local seen = {}
		for _, node in ipairs(added) do
			for dx = -#EDGE_COSTS, #EDGE_COSTS do
				for dz = -#EDGE_COSTS, #EDGE_COSTS do
					local other = network.cells[cellKey(node.ix + dx, node.iz + dz)]
					if other and not seen[other] then
						seen[other] = true
						other.edge = edgeRing(network, other)
					end
				end
			end
		end
		network.regions = nil
		network.labels = nil
		return true
	end

	-- With `maxRise`, only road spots about level with `position` count (a car on a bridge
	-- doesn't start its route on the road underneath).
	local function nearestNode(network, position, radius, ahead, maxRise, avoid, accept)
		local cx, cz = math.round(position.X / CELL), math.round(position.Z / CELL)
		local best, bestScore = nil, math.huge
		local refY = position.Y
		for ix = cx - radius, cx + radius do
			for iz = cz - radius, cz + radius do
				local node = network.cells[cellKey(ix, iz)]
				local skip = false
				for _, other in ipairs(avoid or {}) do
					if math.max(math.abs(other.ix - ix), math.abs(other.iz - iz)) <= GOAL_RETRY_SPACING then
						skip = true
						break
					end
				end
				local rise = node and math.abs(node.y - refY) or 0
				if node and not skip and (not maxRise or rise <= maxRise) and (not accept or accept(node)) then
					local offset = Vector3.new(ix * CELL - position.X, 0, iz * CELL - position.Z)
					-- Heavy height cost so parallel decks (bridge vs highway) don't win on flat distance.
					local score = offset.Magnitude + rise * 18 + node.edge * 6
					if ahead and offset:Dot(ahead) < -CELL then
						score += BEHIND_PENALTY
					end
					if score < bestScore then
						best, bestScore = node, score
					end
				end
			end
		end
		return best
	end

	-- Prefer road on the same deck as `position`, then allow a hill-sized drop if nothing is there.
	local function nearestNodeLeveled(network, position, radius, ahead, avoid, accept)
		return nearestNode(network, position, radius, ahead, SAME_LEVEL_RISE, avoid, accept)
			or nearestNode(network, position, radius, ahead, START_MAX_RISE, avoid, accept)
	end

	-- A seam of empty cells is drivable if nothing stands across it and there is ground at road
	-- level along the hop (upper-city ramps often leave 2 empty cells between road pieces).
	local function seamDrivable(network, a, b)
		if not linkOpen(network.clearance, a, b) then
			return false
		end
		local steps = math.max(math.abs(b.ix - a.ix), math.abs(b.iz - a.iz), 1)
		for step = 1, steps - 1 do
			local t = step / steps
			local mid = Vector3.new(
				(a.ix + (b.ix - a.ix) * t) * CELL,
				a.y + (b.y - a.y) * t,
				(a.iz + (b.iz - a.iz) * t) * CELL
			)
			local ground = Workspace:Raycast(mid + Vector3.new(0, 6, 0), Vector3.new(0, -14, 0), network.seamParams)
			if not ground or ground.Normal.Y < GROUND_NORMAL then
				return false
			end
		end
		return true
	end

	local function findRoute(network, startNode, goalNode)
		local cells = network.cells
		local heap, size = {}, 0
		local function push(priority, node)
			size += 1
			local i = size
			heap[i] = { priority, node }
			while i > 1 do
				local parent = i // 2
				if heap[parent][1] <= heap[i][1] then
					break
				end
				heap[parent], heap[i] = heap[i], heap[parent]
				i = parent
			end
		end
		local function pop()
			local top = heap[1]
			heap[1] = heap[size]
			heap[size] = nil
			size -= 1
			local i = 1
			while true do
				local left, rightChild, smallest = i * 2, i * 2 + 1, i
				if left <= size and heap[left][1] < heap[smallest][1] then
					smallest = left
				end
				if rightChild <= size and heap[rightChild][1] < heap[smallest][1] then
					smallest = rightChild
				end
				if smallest == i then
					break
				end
				heap[i], heap[smallest] = heap[smallest], heap[i]
				i = smallest
			end
			return top[2]
		end
		local function estimate(node)
			return math.sqrt((node.ix - goalNode.ix) ^ 2 + (node.iz - goalNode.iz) ^ 2)
		end

		local cost, cameFrom, closed = { [startNode] = 0 }, {}, {}
		push(estimate(startNode), startNode)
		local expanded = 0
		while size > 0 do
			local node = pop()
			if node == goalNode then
				local route = {}
				while node do
					table.insert(route, 1, node)
					node = cameFrom[node]
				end
				return route
			end
			if not closed[node] then
				closed[node] = true
				expanded += 1
				if expanded % 4000 == 0 then
					task.wait()
				end
				for index, direction in ipairs(DIRECTIONS) do
					local diagonal = direction[1] ~= 0 and direction[2] ~= 0
					local key = cellKey(node.ix + direction[1], node.iz + direction[2])
					local neighbour = cells[key]
					local reach, extra = 1, 0
					if neighbour and not node.links[index] then
						neighbour = nil
					elseif neighbour == nil then
						-- Seams between road pieces leave unsampled cells; hop over those, but never
						-- over an obstructed gap, a fence, or a drop between two roads.
						node.hops = node.hops or {}
						for hop = 2, MAX_SEAM_HOP do
							local beyond = cells[cellKey(node.ix + direction[1] * hop, node.iz + direction[2] * hop)]
							if beyond and math.abs(beyond.y - node.y) <= MAX_STEP_RISE * hop then
								local hopKey = index + hop * 10
								if node.hops[hopKey] == nil then
									node.hops[hopKey] = seamDrivable(network, node, beyond)
								end
								if node.hops[hopKey] then
									neighbour, reach, extra = beyond, hop, GAP_COST * (hop - 1)
									break
								end
							end
						end
					end
					if
						neighbour
						and not closed[neighbour]
						and math.abs(neighbour.y - node.y) <= MAX_STEP_RISE * reach
						and (network.blocked[cellKey(neighbour.ix, neighbour.iz)] or 0) < os.clock()
					then
						local newCost = cost[node]
							+ (diagonal and 1.4142 or 1) * reach
							+ extra
							+ (EDGE_COSTS[neighbour.edge] or 0)
							+ (neighbour.lot and LOT_COST or 0)
						if newCost < (cost[neighbour] or math.huge) then
							cost[neighbour] = newCost
							cameFrom[neighbour] = node
							push(newCost + estimate(neighbour), neighbour)
						end
					end
				end
			end
		end
		return nil
	end

	local function myCar()
		local humanoid = getHumanoid()
		local seat = humanoid and humanoid.SeatPart
		if not (seat and seat:IsA("VehicleSeat")) then
			return nil
		end
		local car = getVehicleModel(seat)
		return car, seat, humanoid
	end

	local function flatDistance(a, b)
		return Vector2.new(a.X - b.X, a.Z - b.Z).Magnitude
	end

	local overheadParams = RaycastParams.new()
	overheadParams.FilterType = Enum.RaycastFilterType.Exclude
	pcall(function()
		overheadParams.RespectCanCollide = true
	end)

	-- Tunnels, sewers and gaps under the map: well below both ends of the trip with a ceiling above.
	local function goesUnderground(waypoints, from, to)
		local ignore = { Workspace.CurrentCamera }
		for name in pairs(VEHICLE_FOLDERS) do
			local folder = Workspace:FindFirstChild(name)
			if folder then
				table.insert(ignore, folder)
			end
		end
		for _, player in ipairs(Players:GetPlayers()) do
			if player.Character then
				table.insert(ignore, player.Character)
			end
		end
		overheadParams.FilterDescendantsInstances = ignore
		local floor = math.min(from.Y, to.Y) - UNDERGROUND_DROP
		for _, waypoint in ipairs(waypoints) do
			local position = waypoint.Position
			if position.Y < floor and Workspace:Raycast(position + Vector3.new(0, 2, 0), Vector3.new(0, 80, 0), overheadParams) then
				return true
			end
		end
		return false
	end

	-- Whether every few studs between `a` and `b` is open road (or lot), skipping anything within
	-- `grace` of `graceFrom`/`graceTo` (pulling out of or into a spot off the road).
	-- Also probes horizontally for fences/buildings (deck-only checks let Slide Mode path through them).
	local function onRoad(network, a, b, grace, graceFrom, graceTo)
		local pieces = math.max(math.ceil(flatDistance(a, b) / ROAD_SAMPLE), 1)
		for piece = 1, pieces do
			local point = a:Lerp(b, piece / pieces)
			local excused = grace and (flatDistance(point, graceFrom) < grace or flatDistance(point, graceTo) < grace)
			if not excused then
				local surface = Workspace:Raycast(point + Vector3.new(0, 5, 0), Vector3.new(0, -12, 0), network.include)
				if not surface or obstructed(network.clearance, surface.Position) then
					return false
				end
			end
		end
		local flat = Vector3.new(b.X - a.X, 0, b.Z - a.Z)
		local span = flat.Magnitude
		if span >= 2 then
			local dir = flat.Unit
			local baseY = (a.Y + b.Y) * 0.5
			for _, lift in ipairs({ 1.0, 2.2, 3.8 }) do
				local origin = Vector3.new(a.X, baseY + lift, a.Z)
				local hit = Workspace:Raycast(origin, dir * span, network.clearance)
				if hit and hit.Normal.Y < GROUND_NORMAL and not isSidewalk(hit.Instance) then
					return false
				end
				if hiddenHit(origin, dir, span) then
					return false
				end
			end
		end
		return true
	end

	-- Roblox's route planner with a car-sized agent; nil if it has no above-ground route, or (with
	-- a road map) if its route leaves the road or climbs stairs or steep slopes (it will happily
	-- take a car up stairs, across grass and along walkways).
	local function plannerRoute(from, to, network)
		local waypoints = Pathing.compute(from, to, CAR_AGENT)
		if not waypoints or goesUnderground(waypoints, from, to) then
			return nil
		end
		local points = {}
		for _, waypoint in ipairs(waypoints) do
			table.insert(points, waypoint.Position)
		end
		if network then
			for i = 2, #points do
				local a, b = points[i - 1], points[i]
				if math.abs(b.Y - a.Y) > math.max(flatDistance(a, b) * MAX_SLOPE, MAX_STEP_RISE) then
					return nil
				end
				if not onRoad(network, a, b, PLANNER_GRACE, points[1], points[#points]) then
					return nil
				end
			end
		end
		return points
	end

	-- True if a straight line between two road cells stays on the road, away from the curb.
	local function clearLine(network, a, b)
		local dx, dz = b.ix - a.ix, b.iz - a.iz
		local steps = math.max(math.abs(dx), math.abs(dz)) * 2
		for step = 1, steps - 1 do
			local t = step / steps
			local node = network.cells[cellKey(math.round(a.ix + dx * t), math.round(a.iz + dz * t))]
			if not node or node.edge == 1 or math.abs(node.y - (a.y + (b.y - a.y) * t)) > 2 then
				return false
			end
		end
		return linkOpen(network.clearance, a, b)
	end

	-- Drops grid zig-zags: keeps only the corners where a straight line would leave the road.
	local function straighten(network, route)
		local kept = { route[1] }
		local anchor = 1
		for i = 2, #route do
			if i == #route or i - anchor >= 25 or not clearLine(network, route[anchor], route[i + 1]) then
				table.insert(kept, route[i])
				anchor = i
			end
		end
		return kept
	end

	local function gridRoute(network, from, to, ahead)
		-- Start on road ahead of the car if there is any (starting behind it turns it in circles).
		-- Same-level first so an overpass doesn't begin on the highway under it.
		-- Prefer a start the car can actually reach (no fence/building between nose and cell).
		local function usableStart(node)
			local spot = Vector3.new(node.ix * CELL, node.y + 2, node.iz * CELL)
			return onRoad(network, from, spot, CELL, from, spot)
		end
		local start = ahead and nearestNodeLeveled(network, from, START_SNAP_CELLS, nil, nil, function(node)
			return Vector3.new(node.ix * CELL - from.X, 0, node.iz * CELL - from.Z):Dot(ahead) >= -CELL * 0.5
				and usableStart(node)
		end) or nearestNodeLeveled(network, from, START_SNAP_CELLS, ahead, nil, usableStart)
		if not start then
			start = ahead and nearestNodeLeveled(network, from, START_SNAP_CELLS, nil, nil, function(node)
				return Vector3.new(node.ix * CELL - from.X, 0, node.iz * CELL - from.Z):Dot(ahead) >= -CELL * 0.5
			end) or nearestNodeLeveled(network, from, START_SNAP_CELLS, ahead)
		end
		if not start then
			return nil
		end
		local labels = networkLabels(network)
		local startLabel = labels[start]
		-- The road nearest the goal may not connect to ours (a cut-off stretch, a rooftop); then try
		-- other road around the goal, away from the spots already tried. Uphill destinations often
		-- sit on a small plateau — keep trying other snaps instead of giving up on the first miss.
		local tried = {}
		local route = nil
		local snapRadius = GOAL_SNAP_CELLS + (math.abs(to.Y - from.Y) > 20 and 15 or 0)
		local goalRise = math.max(SAME_LEVEL_RISE, math.abs(to.Y - from.Y) + SAME_LEVEL_RISE)
		for attempt = 1, GOAL_ATTEMPTS do
			local goal
			if attempt == 1 then
				goal = nearestNode(network, to, snapRadius, nil, goalRise, nil, function(node)
					return labels[node] == startLabel
				end)
			elseif attempt == 2 then
				-- Still prefer the destination's deck before grabbing a road far below/above.
				goal = nearestNode(network, to, snapRadius, nil, goalRise, tried)
			else
				goal = nearestNode(network, to, snapRadius, nil, nil, tried)
			end
			if goal then
				route = findRoute(network, start, goal)
				if route then
					break
				end
				table.insert(tried, goal)
			end
		end
		if not route then
			return nil
		end
		local points = {}
		for _, node in ipairs(straighten(network, route)) do
			table.insert(points, Vector3.new(node.ix * CELL, node.y, node.iz * CELL))
		end
		return points
	end

	-- Road edges are found by stepping sideways from the route over the road map's cells (no
	-- raycasts, so planning stays quick even for long routes).
	local function roadExtent(network, position, direction)
		local reach = 0
		while reach < CENTER_SCAN do
			local probe = position + direction * (reach + CENTER_STEP)
			local node = network.cells[cellKey(math.round(probe.X / CELL), math.round(probe.Z / CELL))]
			if not node or math.abs(node.y - position.Y) > MAX_STEP_RISE then
				break
			end
			reach += CENTER_STEP
		end
		return reach
	end

	-- Moves the route onto the middle of the road: resample it, shift every point halfway between
	-- the road edges on either side, then smooth so intersections don't make it swerve.
	local function centerRoute(network, points, limit)
		local dense = { points[1] }
		for i = 2, #points do
			local a, b = points[i - 1], points[i]
			local pieces = math.max(math.floor((b - a).Magnitude / CENTER_SPACING), 1)
			for piece = 1, pieces do
				table.insert(dense, a:Lerp(b, piece / pieces))
			end
		end
		if #dense < 3 then
			return dense
		end
		-- Sideways shift onto the middle of the road at each point (nil = unknown: an intersection,
		-- open ground, a road too wide to have one middle, or past `limit`).
		local shifts = {}
		local covered = 0
		for i = 2, #dense - 1 do
			if i % 20 == 0 then
				task.wait()
			end
			local point = dense[i]
			covered += flatDistance(point, dense[i - 1])
			local along = Vector3.new(dense[i + 1].X - dense[i - 1].X, 0, dense[i + 1].Z - dense[i - 1].Z)
			if along.Magnitude > 0.1 and covered <= (limit or math.huge) then
				local side = Vector3.new(-along.Unit.Z, 0, along.Unit.X)
				local left, right = roadExtent(network, point, side), roadExtent(network, point, -side)
				if left < CENTER_SCAN and right < CENTER_SCAN and left + right <= WIDE_ROAD then
					shifts[i] = side * math.clamp((left - right) / 2, -MAX_CENTER_SHIFT, MAX_CENTER_SHIFT)
				end
			end
		end
		-- Unknown shifts blend between the known ones on either side (instead of snapping back to
		-- the raw route, which made sudden bends), fading out near the ends.
		local filled = {}
		local lastKnown = nil
		for i = 1, #dense do
			if shifts[i] then
				lastKnown = i
			end
			filled[i] = lastKnown
		end
		local nextKnown = nil
		local shift = {}
		for i = #dense, 1, -1 do
			if shifts[i] then
				nextKnown = i
			end
			local before, after = filled[i], nextKnown
			if shifts[i] then
				shift[i] = shifts[i]
			elseif before and after then
				shift[i] = shifts[before]:Lerp(shifts[after], (i - before) / (after - before))
			elseif before and i - before <= SHIFT_FADE then
				shift[i] = shifts[before] * (1 - (i - before) / (SHIFT_FADE + 1))
			elseif after and after - i <= SHIFT_FADE then
				shift[i] = shifts[after] * (1 - (after - i) / (SHIFT_FADE + 1))
			else
				shift[i] = Vector3.zero
			end
		end
		shift[1], shift[#dense] = Vector3.zero, Vector3.zero
		-- Average the shifts over neighbouring points, then limit how fast they change, so the
		-- route eases across the road rather than kinking.
		local averaged = {}
		for i = 1, #dense do
			local total, count = Vector3.zero, 0
			for j = math.max(i - SHIFT_WINDOW, 1), math.min(i + SHIFT_WINDOW, #dense) do
				total += shift[j]
				count += 1
			end
			averaged[i] = total / count
		end
		averaged[1], averaged[#dense] = Vector3.zero, Vector3.zero
		for pass = 1, 2 do
			local from, to, step = 2, #dense, 1
			if pass == 2 then
				from, to, step = #dense - 1, 1, -1
			end
			for i = from, to, step do
				local previous = averaged[i - step]
				local change = averaged[i] - previous
				if change.Magnitude > MAX_SHIFT_STEP then
					averaged[i] = previous + change.Unit * MAX_SHIFT_STEP
				end
			end
		end
		local centered = {}
		for i = 1, #dense do
			centered[i] = dense[i] + averaged[i]
		end
		centered[1], centered[#dense] = dense[1], dense[#dense]
		local smoothed = centered
		for _ = 1, 2 do
			local nextPass = { smoothed[1] }
			for i = 2, #smoothed - 1 do
				nextPass[i] = (smoothed[i - 1] + smoothed[i] * 2 + smoothed[i + 1]) / 4
			end
			nextPass[#smoothed] = smoothed[#smoothed]
			smoothed = nextPass
		end
		return smoothed
	end

	-- The next stretch to drive: the road grid's route (roads only), or when that has none, the
	-- route planner's (split into legs on long trips, each ending on a road). Returns points, reachesGoal.
	local function planDrive(network, from, to, ahead, centerLimit)
		local points = network and gridRoute(network, from, to, ahead)
		if points then
			return centerRoute(network, points, centerLimit), true
		end
		points = plannerRoute(from, to, network)
		if points then
			return network and centerRoute(network, points, centerLimit) or points, true
		end
		local flat = Vector3.new(to.X - from.X, 0, to.Z - from.Z)
		if network and flat.Magnitude > LEG_LENGTH * 0.5 then
			local forward = flat.Unit
			local side = forward:Cross(Vector3.yAxis)
			for _, legLength in ipairs({ LEG_LENGTH, LEG_LENGTH * 0.5 }) do
				for _, sideways in ipairs({ 0, 80, -80, 200, -200 }) do
					local node = nearestNode(network, from + forward * legLength + side * sideways, 8)
					if node then
						points = plannerRoute(from, Vector3.new(node.ix * CELL, node.y + 2, node.iz * CELL), network)
						if points then
							return centerRoute(network, points, centerLimit), false
						end
					end
				end
			end
		end
		return nil, false
	end

	-- Drives the car with its own physics (collisions, gravity, suspension): we only set its forward
	-- speed and how fast it turns, like a driver on the pedals and wheel. Returns arrived, reason.
	local function playerRoot(player)
		local character = player and player.Character
		return character and character:FindFirstChild("HumanoidRootPart")
	end

	local function playerVehicle(player)
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		local seat = humanoid and humanoid.SeatPart
		return seat and getVehicleModel(seat) or nil
	end

	-- Positions of other players within `radius`.
	function threatsNear(position, radius)
		local found = {}
		for _, player in ipairs(Players:GetPlayers()) do
			local root = player ~= LocalPlayer and playerRoot(player)
			if root and (root.Position - position).Magnitude < radius then
				table.insert(found, root.Position)
			end
		end
		return found
	end

	-- Watches the car and everyone sitting in it for damage / shooting while Self Driving drives.
	local Condition = { hurtAt = 0, damagedAt = 0, shootAt = 0, severity = 0, lowHealth = false, wrecked = false }
	do
		local watchedCar, seats, carValues = nil, {}, {}
		local occupantHealth, carHealth, carBest = {}, {}, {}
		local nextUpdate, nextNotice = 0, 0

		local function isHealthName(name)
			name = name:lower()
			return name:find("health") ~= nil or name == "hp" or name:find("durab") ~= nil
		end

		local function watch(car)
			watchedCar, seats, carValues = car, {}, {}
			occupantHealth, carHealth, carBest = {}, {}, {}
			Condition.lowHealth, Condition.wrecked, Condition.severity = false, false, 0
			for _, descendant in ipairs(car:GetDescendants()) do
				if descendant:IsA("Seat") or descendant:IsA("VehicleSeat") then
					table.insert(seats, descendant)
				elseif (descendant:IsA("NumberValue") or descendant:IsA("IntValue")) and isHealthName(descendant.Name) then
					table.insert(carValues, descendant)
				end
			end
		end

		local function readCarHealth(car)
			local values = {}
			for _, holder in ipairs({ car, car.PrimaryPart or car }) do
				for name, value in pairs(holder:GetAttributes()) do
					if type(value) == "number" and isHealthName(name) then
						values[holder:GetFullName() .. "@" .. name] = value
					end
				end
			end
			for _, object in ipairs(carValues) do
				if object.Parent then
					values[object] = object.Value
				end
			end
			return values
		end

		local function addSeverity(amount)
			Condition.severity = math.clamp(Condition.severity + math.max(amount, 0), 0, 1.5)
		end

		local function underFire()
			return os.clock() - Condition.hurtAt < UNDER_FIRE_TIME
		end
		Condition.underFire = underFire
		function Condition.careful()
			return Condition.wrecked or os.clock() - Condition.damagedAt < CAREFUL_TIME
		end
		function Condition.damageChase()
			return underFire() or os.clock() - Condition.damagedAt < DAMAGE_CHASE_TIME
		end
		function Condition.shooting()
			return os.clock() - Condition.shootAt < SHOOTING_TIME
		end
		-- Extra speed/turn from how hard we've been hit recently (0 .. DAMAGE_BOOST_MAX).
		function Condition.damageBoost()
			if not Condition.damageChase() then
				return 0
			end
			local age = math.min(os.clock() - Condition.hurtAt, os.clock() - Condition.damagedAt)
			local fade = math.clamp(1 - age / DAMAGE_CHASE_TIME, 0.25, 1)
			return math.clamp(Condition.severity, 0, 1) * DAMAGE_BOOST_MAX * fade
		end
		function Condition.retreat()
			return Condition.lowHealth or Condition.wrecked
		end

		local function carDamaged(why, amount)
			local fresh = os.clock() - Condition.damagedAt >= DAMAGE_CHASE_TIME
			Condition.damagedAt = os.clock()
			addSeverity(amount or 0.2)
			if fresh and os.clock() >= nextNotice then
				nextNotice = os.clock() + 5
				notify("Self Driving: " .. why .. ", switching to Chase Mode.")
			end
		end
		function Condition.impact()
			carDamaged("hard crash", 0.35)
		end

		local function firingGun(character)
			if not character then
				return false
			end
			local tool = character:FindFirstChildOfClass("Tool")
			if not isGun(tool) then
				return false
			end
			local pressing = UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1)
			if not pressing then
				pcall(function()
					pressing = UserInputService:IsGamepadButtonDown(Enum.UserInputType.Gamepad1, Enum.KeyCode.ButtonR2)
				end)
			end
			return pressing
		end

		function Condition.update(car)
			if car ~= watchedCar then
				watch(car)
			end
			if os.clock() < nextUpdate then
				return
			end
			nextUpdate = os.clock() + 0.2
			Condition.severity = math.max(Condition.severity - 0.03, 0)
			local hurt, lowest = false, math.huge
			local lost = 0
			for _, seat in ipairs(seats) do
				local occupant = seat.Parent and seat.Occupant
				if occupant then
					local before = occupantHealth[occupant]
					if before and occupant.Health < before - 0.5 then
						hurt = true
						lost += before - occupant.Health
					end
					occupantHealth[occupant] = occupant.Health
					lowest = math.min(lowest, occupant.Health)
					if firingGun(occupant.Parent) then
						local wasShooting = Condition.shooting()
						Condition.shootAt = os.clock()
						if not wasShooting and os.clock() >= nextNotice then
							nextNotice = os.clock() + 4
							notify("Self Driving: gunfire detected, switching to Slide Mode.")
						end
					end
				end
			end
			-- Driver may be LocalPlayer even if Occupant lag; also check our character.
			if firingGun(getCharacter()) then
				Condition.shootAt = os.clock()
			end
			local wasLow = Condition.lowHealth
			Condition.lowHealth = lowest <= LOW_HEALTH
			if hurt then
				local fresh = not underFire()
				Condition.hurtAt = os.clock()
				addSeverity(lost / 40)
				if fresh then
					notify("Self Driving: taking damage, Chase Mode + escaping.")
				end
			end
			if Condition.lowHealth and not wasLow then
				notify("Self Driving: health is low, breaking off any chase.")
			end
			for key, value in pairs(readCarHealth(car)) do
				local before = carHealth[key]
				carBest[key] = math.max(carBest[key] or value, value)
				if before and value < before - 0.01 then
					local fraction = carBest[key] > 0 and (before - value) / carBest[key] or 0.2
					carDamaged("the car is taking damage", fraction)
				end
				carHealth[key] = value
				if carBest[key] > 0 and value / carBest[key] <= WRECKED and not Condition.wrecked then
					Condition.wrecked = true
					notify("Self Driving: the car is badly damaged.")
				end
			end
		end
	end

	-- Nearby players raise speed/turn; cars ahead on the road slow us down and tighten steering.
	local function worldSituation(position, forward)
		local speedMul, turnMul = 1, 1
		local threats = threatsNear(position, WORLD_ADAPT_RADIUS)
		if #threats > 0 then
			local n = math.min(#threats, 5)
			speedMul += n * 0.09
			turnMul += n * 0.07
		end
		local civCars = Workspace:FindFirstChild("CivCars")
		if civCars and forward and forward.Magnitude > 0.1 then
			local face = forward.Unit
			local slow = 0
			for _, other in ipairs(civCars:GetChildren()) do
				local otherSeat = getDriveSeat(other)
				if otherSeat then
					local offset = otherSeat.Position - position
					local distance = offset.Magnitude
					if distance > 6 and distance < WORLD_ADAPT_RADIUS then
						local flat = Vector3.new(offset.X, 0, offset.Z)
						if flat.Magnitude > 1 and flat.Unit:Dot(face) > 0.55 then
							slow = math.max(slow, 1 - distance / WORLD_ADAPT_RADIUS)
						end
					end
				end
			end
			if slow > 0 then
				speedMul *= 1 - slow * 0.5
				turnMul *= 1 + slow * 0.2
			end
		end
		return speedMul, turnMul
	end

	-- `route.points` may grow while driving (the next stretch is planned in the background), so the
	-- car never stops between stretches.
	local function follow(network, car, seat, humanoid, route, active)
		local points = route.points
		if #points < 2 and route.final then
			return true
		end
		local extents = car:GetExtentsSize()
		local halfLength = math.max(extents.X, extents.Z) / 2
		local feelerIgnore = { car, Workspace.CurrentCamera }
		for _, player in ipairs(Players:GetPlayers()) do
			if player.Character then
				table.insert(feelerIgnore, player.Character)
			end
		end
		for _, instance in ipairs(route.ignore or {}) do
			table.insert(feelerIgnore, instance)
		end
		local groundParams = RaycastParams.new()
		groundParams.FilterType = Enum.RaycastFilterType.Exclude
		groundParams.FilterDescendantsInstances = table.clone(feelerIgnore)
		pcall(function()
			groundParams.RespectCanCollide = true
		end)
		for _, part in ipairs(network and network.parts or {}) do
			table.insert(feelerIgnore, part)
		end
		local feelerParams = RaycastParams.new()
		feelerParams.FilterType = Enum.RaycastFilterType.Exclude
		feelerParams.FilterDescendantsInstances = feelerIgnore
		pcall(function()
			feelerParams.RespectCanCollide = true
		end)
		if seat.CFrame.UpVector.Y < 0.7 then
			landCar(car, seat)
		end
		-- Drop route points just behind the car (a route snapped to road it already passed would
		-- otherwise make it turn back round in a circle).
		do
			local look = seat.CFrame.LookVector
			local facing = Vector3.new(look.X, 0, look.Z)
			local trim = math.max(BEHIND_TRIM, math.abs(seat.AssemblyLinearVelocity.Magnitude) * 0.85 + 25)
			while #points > 2 and facing.Magnitude > 0.1 do
				local offset = Vector3.new(points[2].X - seat.Position.X, 0, points[2].Z - seat.Position.Z)
				if offset.Magnitude < 1e-3 then
					table.remove(points, 1)
				elseif offset:Dot(facing.Unit) < 0.05 and offset.Magnitude < trim then
					table.remove(points, 1)
				else
					break
				end
			end
		end
		local index = 1
		local speed = math.max(seat.AssemblyLinearVelocity:Dot(seat.CFrame.LookVector), 0)
		local lastProgress, lastMoved = seat.Position, os.clock()
		local stuckCount = 0
		local reverseUntil = 0
		local reverseCooldownUntil = 0
		local function brake()
			if seat.Parent then
				seat.AssemblyLinearVelocity = Vector3.new(0, seat.AssemblyLinearVelocity.Y, 0)
				seat.AssemblyAngularVelocity = Vector3.zero
			end
		end
		-- Full stop held for a moment so momentum doesn't carry the car into people or props.
		local function hardStop()
			speed = 0
			local untilTime = os.clock() + 0.45
			while seat.Parent and humanoid.SeatPart == seat and os.clock() < untilTime do
				seat.AssemblyLinearVelocity = Vector3.zero
				seat.AssemblyAngularVelocity = Vector3.zero
				RunService.Heartbeat:Wait()
			end
			brake()
		end
		-- Hands the car back still rolling, but without the last steering input (so it doesn't spin).
		local function straightenUp()
			if seat.Parent then
				local spin = seat.AssemblyAngularVelocity
				seat.AssemblyAngularVelocity = Vector3.new(spin.X, 0, spin.Z)
			end
		end

		local function flat(vector)
			return Vector3.new(vector.X, 0, vector.Z)
		end
		-- The point `distance` further along the route than the car's spot on it.
		local function alongRoute(position, distance)
			while index < #points - 1 do
				local a, b = points[index], points[index + 1]
				local segment = flat(b - a)
				if segment:Dot(flat(position - a)) / math.max(segment:Dot(segment), 1e-3) >= 1 then
					index += 1
				else
					break
				end
			end
			local a, b = points[index], points[index + 1]
			local segment = flat(b - a)
			local t = math.clamp(segment:Dot(flat(position - a)) / math.max(segment:Dot(segment), 1e-3), 0, 1)
			local current = a + (b - a) * t
			local i = index
			while true do
				local nextPoint = points[i + 1]
				local length = flatDistance(nextPoint, current)
				if length >= distance or i + 1 >= #points then
					return length < 1e-3 and nextPoint or current + (nextPoint - current) * math.min(distance / length, 1)
				end
				distance -= length
				current = nextPoint
				i += 1
			end
		end

		-- If the car drifted off or the route index fell behind, snap to the nearest segment
		-- that still lies ahead of the nose (stops mid-road U-turns toward old points).
		local function resnapRoute(position, facing)
			local bestIndex, bestScore = index, math.huge
			for i = 1, #points - 1 do
				local a, b = points[i], points[i + 1]
				local segment = flat(b - a)
				local length2 = segment:Dot(segment)
				if length2 > 1e-3 then
					local t = math.clamp(segment:Dot(flat(position - a)) / length2, 0, 1)
					local closest = a:Lerp(b, t)
					local away = flatDistance(closest, position)
					local along = segment.Unit:Dot(facing)
					-- Prefer segments going the same way as the car; never favor points behind the nose.
					local score = away + (along < 0.25 and 80 or 0) + (along < 0 and 120 or 0) + (i + 1 < index and 35 or 0)
					if score < bestScore then
						bestScore, bestIndex = score, i
					end
				end
			end
			index = bestIndex
		end
		-- route._deckY updated each tick so feelers can ignore road-deck grazing.
		route._deckY = seat.Position.Y - SEAT_HEIGHT
		local function feel(name, origin, direction, length)
			local hit = Workspace:Raycast(origin, direction * length, feelerParams)
			if hit then
				local inst = hit.Instance
				-- Ground, ramps, sidewalks, and road parts — not obstacles.
				if hit.Normal.Y > GROUND_NORMAL or isSidewalk(inst) or isRoadPart(inst) then
					hit = nil
				elseif hit.Position.Y < (route._deckY or 0) + 2.4 and hit.Normal.Y > 0.35 then
					-- Angled feeler clipping the deck / curb top.
					hit = nil
				end
			end
			local distance = hit and (hit.Position - origin).Magnitude or nil
			-- Hidden solids: only trust close wall-like hits (far false decks caused "road blocked").
			local hidden = hiddenHit(origin, direction, length)
			if hidden and hidden < length * 0.85 and (not distance or hidden < distance) then
				if hidden < BLOCK_DISTANCE + 6 then
					distance = hidden
				end
			end
			PathDebug.line(name, origin, origin + direction * (distance or length), distance and DEBUG_HIT or DEBUG_CLEAR)
			return distance
		end
		-- Remembers the road cell an obstruction is in (and a short strip into it) so the next
		-- route goes around invisible walls instead of retrying the same cell.
		local function markBlocked(position, into)
			if not network then
				return
			end
			local base = Vector3.new(position.X, 0, position.Z)
			local step = Vector3.zero
			if into and into.Magnitude > 0.1 then
				step = Vector3.new(into.X, 0, into.Z).Unit * CELL
			end
			for i = 0, 2 do
				local point = base + step * i
				for _, offset in ipairs({ Vector3.zero, Vector3.new(CELL, 0, 0), Vector3.new(-CELL, 0, 0), Vector3.new(0, 0, CELL), Vector3.new(0, 0, -CELL) }) do
					if i == 0 or offset == Vector3.zero then
						local ix = math.round((point.X + offset.X) / CELL)
						local iz = math.round((point.Z + offset.Z) / CELL)
						local key = cellKey(ix, iz)
						local node = network.cells[key]
						if node then
							network.blocked[key] = os.clock() + BLOCKED_TIME
							PathDebug.marker("blocked" .. key, Vector3.new(ix * CELL, node.y + 0.3, iz * CELL), DEBUG_HIT, Vector3.new(CELL - 1, 0.3, CELL - 1))
						end
					end
				end
			end
		end
		local blockedSince = nil
		local drawnPoints = #points
		PathDebug.path("drive", points, DEBUG_ROUTE)
		local lastTravel = nil
		local threatened, nextThreatCheck = false, 0
		local commandedSpeed, ramming = 0, false
		-- Shooting → Slide; damage / under fire → Chase (faster the more damage); nearby threats and
		-- traffic also scale speed and turning.
		local function currentProfile(position, forward)
			local name = route.mode or Arsenic.Values.SelfDriveMode
			if route.adaptive and os.clock() >= nextThreatCheck then
				nextThreatCheck = os.clock() + 0.5
				threatened = #threatsNear(position, ADAPT_RADIUS) > 0
			end
			if Condition.shooting() then
				name = "Slide Mode"
			elseif Condition.damageChase() or (route.adaptive and threatened) then
				name = "Chase Mode"
			end
			local base = MODES[name] or MODES["Civilian Mode"]
			local profile = {
				speed = base.speed,
				turn = base.turn,
				corner = base.corner,
				accel = base.accel,
				brake = base.brake,
				blend = base.blend,
				feeler = base.feeler,
				slide = base.slide,
				reverse = base.reverse or 1,
			}
			local boost = Condition.damageBoost()
			if boost > 0 and name == "Chase Mode" then
				profile.speed += boost
				profile.turn += boost
				profile.accel += boost * 20
			end
			local worldSpeed, worldTurn = worldSituation(position, forward)
			profile.speed *= worldSpeed
			profile.turn *= worldTurn
			return profile
		end

		while active() and humanoid.SeatPart == seat and car.Parent do
			local dt = RunService.Heartbeat:Wait()
			local position = seat.Position
			if route.deadline and os.clock() > route.deadline then
				straightenUp()
				return false, "replan"
			end
			Condition.update(car)
			-- Our own braking only changes the speed we set, so losing most of it at once is a crash.
			local actual = Vector3.new(seat.AssemblyLinearVelocity.X, 0, seat.AssemblyLinearVelocity.Z).Magnitude
			if commandedSpeed > IMPACT_SPEED and actual < commandedSpeed * 0.35 and not ramming then
				Condition.impact()
			end
			if route.resetIndex then
				route.resetIndex = nil
				index = 1
			end
			route.index, route.speed = index, speed
			if route.onTick then
				local stop = route.onTick(position)
				if stop then
					straightenUp()
					return false, stop
				end
			end
			if #points ~= drawnPoints or route.redraw then
				route.redraw = nil
				drawnPoints = #points
				PathDebug.path("drive", points, DEBUG_ROUTE)
			end
			local lookahead = LOOKAHEAD + math.abs(speed) * LOOKAHEAD_PER_SPEED
			local offLimit = OFF_ROUTE + math.abs(speed) * OFF_ROUTE_PER_SPEED
			route.offRoute = flatDistance(alongRoute(position, 0), position) > offLimit
			-- Close chases (or while a fresh route is planned) steer straight at a point instead.
			local directGoal, directSpeed = nil, nil
			if route.direct then
				directGoal, directSpeed = route.direct(position, route.offRoute)
			end
			-- Hitting the car we're chasing is on purpose, not damage to drive carefully about.
			ramming = directGoal ~= nil and flatDistance(directGoal, position) < 30
			local goal = directGoal or alongRoute(position, lookahead)
			PathDebug.marker("target", goal + Vector3.new(0, 1, 0), DEBUG_TARGET, Vector3.new(1.5, 1.5, 1.5), true)
			local remaining = flatDistance(points[#points], position)
			if not route.final and not route.extending and not route.failed and remaining < math.max(EXTEND_AHEAD, speed * EXTEND_SECONDS) then
				route.extend()
			end
			local atEnd = not directGoal and index >= #points - 1 and remaining < ARRIVE_DISTANCE
			if atEnd and route.final and not route.continuous then
				-- Always hard-stop at a real destination so the car doesn't coast into people/objects.
				hardStop()
				return true
			end
			if atEnd and route.failed then
				hardStop()
				return false, route.reason or "no road leads there"
			end
			if seat.CFrame.UpVector.Y < 0.3 then
				-- Rolled over: put it back on its wheels.
				landCar(car, seat)
				speed = 0
			end

			local look = seat.CFrame.LookVector
			local forward = Vector3.new(look.X, 0, look.Z)
			forward = forward.Magnitude > 0.1 and forward.Unit or Vector3.new(0, 0, -1)
			local profile = currentProfile(position, forward)
			local turnScale = profile.turn * Arsenic.Values.SelfDriveTurn
			local maxYaw = MAX_YAW_RATE * turnScale
			if not directGoal and (route.offRoute or flatDistance(alongRoute(position, 0), position) > 12) then
				resnapRoute(position, forward)
				goal = alongRoute(position, lookahead)
			end
			local toGoal = Vector3.new(goal.X - position.X, 0, goal.Z - position.Z)
			-- Route goal behind the nose: prefer a forward point on the route; otherwise reverse/turn
			-- instead of instantly aborting as "stuck" (that caused stop → new route → stop loops).
			local facingBackward = false
			if not directGoal and toGoal.Magnitude > 0.1 and forward:Dot(toGoal.Unit) < -0.15 then
				resnapRoute(position, forward)
				facingBackward = true
				for _, extra in ipairs({ 20, 40, 70, 110, 160, 220 }) do
					local candidate = alongRoute(position, lookahead + extra)
					local offset = Vector3.new(candidate.X - position.X, 0, candidate.Z - position.Z)
					if offset.Magnitude > 4 and forward:Dot(offset.Unit) > 0.2 then
						goal = candidate
						toGoal = offset
						facingBackward = false
						break
					end
				end
			end
			if facingBackward then
				route._uturnAt = route._uturnAt or os.clock()
			else
				route._uturnAt = nil
			end
			local desired = toGoal.Magnitude > 0.1 and toGoal.Unit or forward
			local angle = math.acos(math.clamp(forward:Dot(desired), -1, 1))
			local side = forward:Cross(desired).Y >= 0 and 1 or -1
			-- Brake ahead of corners: how sharply the road itself turns between the steering point
			-- and a point further on (not how far the car is pointing off the route).
			local preview = alongRoute(position, lookahead + math.abs(speed) * 0.9 + 6)
			local beyond = Vector3.new(preview.X - goal.X, 0, preview.Z - goal.Z)
			local roadTurn = 0
			if not directGoal and beyond.Magnitude > 0.5 and toGoal.Magnitude > 0.5 then
				roadTurn = math.acos(math.clamp(toGoal.Unit:Dot(beyond.Unit), -1, 1))
			end

			-- The ground under the car: its slope (grade along the way we're heading) and surface.
			local ground = Workspace:Raycast(position + Vector3.new(0, 1, 0), Vector3.new(0, -(SEAT_HEIGHT + 6), 0), groundParams)
			local grade = 0
			if ground and ground.Normal.Y > 0.5 then
				grade = -(ground.Normal.X * forward.X + ground.Normal.Z * forward.Z) / ground.Normal.Y
			end
			local climb = grade
			local onHill = grade > FLAT_GRADE * 2 or climb > FLAT_GRADE * 2
			local targetSpeed, yawRate
			-- Chasing someone who is right behind us: back round towards them instead of circling.
			local turnBack = directGoal and angle > math.rad(125) and toGoal.Magnitude < 25
			local reversing = os.clock() < reverseUntil or turnBack
			-- Shared road height for nose and tail feelers.
			local nose = position + forward * halfLength
			local tail = position - forward * halfLength
			local roadHitNose = network and Workspace:Raycast(nose + Vector3.new(0, 2, 0), Vector3.new(0, -14, 0), network.include)
			local roadHitTail = network and Workspace:Raycast(tail + Vector3.new(0, 2, 0), Vector3.new(0, -14, 0), network.include)
			local roadSurface = roadHitNose and roadHitNose.Position.Y or (position.Y - SEAT_HEIGHT)
			local rearSurface = roadHitTail and roadHitTail.Position.Y or roadSurface
			route._deckY = roadSurface
			local bumper = Vector3.new(nose.X, roadSurface + FEELER_HEIGHT, nose.Z)
			local rearBumper = Vector3.new(tail.X, rearSurface + FEELER_HEIGHT, tail.Z)
			local reach = math.min(FEELER_REACH_BASE + math.abs(speed) * FEELER_REACH_PER_SPEED, FEELER_REACH_MAX)
			local rearReach = math.min(10 + math.abs(speed) * 0.2, 18)
			-- Only treat obstacles inside stopping distance as something to steer around.
			local brakeHorizon = math.abs(speed) > 1 and (speed * speed / (2 * math.max(profile.brake, 1)) + 8) or 8
			local reactWithin = math.min(reach, math.max(brakeHorizon, BLOCK_DISTANCE + 4))
			local climbHint = climb
			local farHit = network and Workspace:Raycast(nose + forward * reach + Vector3.new(0, reach * 0.85 + 3, 0), Vector3.new(0, -(reach * 1.5 + 8), 0), network.include)
			if farHit then
				climbHint = math.clamp((farHit.Position.Y - roadSurface) / reach, -0.7, 0.85)
			end
			local function sloped(direction)
				return (direction + Vector3.new(0, math.max(climbHint, grade) + (onHill and 0.08 or 0), 0)).Unit
			end
			-- Rear collision feelers (always on so reverse and coast-back don't hit people/walls).
			local behind = feel("feelerBehind", rearBumper, sloped(-forward), rearReach)
			local backLeft = feel("feelerBackLeft", rearBumper, sloped(CFrame.Angles(0, FEELER_ANGLE, 0):VectorToWorldSpace(-forward)), rearReach * 0.8)
			local backRight = feel("feelerBackRight", rearBumper, sloped(CFrame.Angles(0, -FEELER_ANGLE, 0):VectorToWorldSpace(-forward)), rearReach * 0.8)

			local reverseSpeed = REVERSE_SPEED * (profile.reverse or 1)
			local sliding = profile.slide == true
			-- Never reverse hard into a wall/curb (Slide's 3x reverse made this slam into fences).
			local rearClear = not behind or behind > BLOCK_DISTANCE + 3
			-- Path only behind us: reverse+steer when the rear is open; otherwise keep turning.
			if facingBackward and not reversing and rearClear and not sliding and os.clock() >= reverseCooldownUntil then
				reverseUntil = os.clock() + REVERSE_TIME
				reversing = true
				notifyRoute("uturn")
			elseif facingBackward and not reversing then
				notifyRoute("uturn")
			end
			if facingBackward and route._uturnAt and os.clock() - route._uturnAt > 2.2 then
				-- Soft replan after trying reverse/turn — don't freeze mid-road forever.
				brake()
				return false, "stuck"
			end
			if reversing and not rearClear then
				reverseUntil = 0
				reversing = (turnBack or facingBackward) and rearClear
			end
			if reversing then
				targetSpeed = -reverseSpeed
				if facingBackward or turnBack then
					-- Swing the nose toward the route while backing up.
					yawRate = side * math.min(angle * STEER_GAIN * 0.6 * turnScale, maxYaw * 0.9)
				elseif onHill then
					yawRate = 0
				else
					yawRate = 0
				end
				-- Don't reverse into whatever is behind the car.
				if behind then
					targetSpeed = math.max(targetSpeed, -math.max((behind - 3) * 2, 4))
					if behind < BLOCK_DISTANCE + 2 then
						targetSpeed = 0
						speed = 0
						reverseUntil = 0
						-- Pivot toward the open rear quarter instead of chewing the wall.
						local leftRoom, rightRoom = backLeft or rearReach, backRight or rearReach
						yawRate = (leftRoom > rightRoom and 1 or -1) * maxYaw
					elseif math.abs((backLeft or rearReach) - (backRight or rearReach)) > 1 then
						local leftRoom, rightRoom = backLeft or rearReach, backRight or rearReach
						yawRate = (leftRoom > rightRoom and -1 or 1) * maxYaw * 0.7
					end
				end
			else
				-- Slow for corners; keep rolling while correcting heading so we don't stop to U-turn.
				local topSpeed = Arsenic.Values.SelfDriveSpeed * profile.speed
				local slowest = profile.corner * (Arsenic.Values.SelfDriveSpeed / DEFAULT_SPEED) * math.sqrt(Arsenic.Values.SelfDriveTurn)
				local cornerSpeed = topSpeed + (math.min(slowest, topSpeed) - topSpeed) * math.clamp(roadTurn / (math.pi / 2), 0, 1)
				local headingSpeed = angle > math.rad(100) and math.max(slowest, 16)
					or topSpeed * math.clamp(math.cos(angle), 0.45, 1)
				-- Only ease off at the end of a stretch if the next one isn't ready yet.
				local endSpeed = topSpeed
				if directGoal then
					endSpeed = directSpeed or topSpeed
				elseif route.final and not route.continuous then
					-- Brake hard into the stop so we arrive nearly still.
					endSpeed = math.max(remaining * 0.55, 3)
				elseif route.extending or route.failed or route.final then
					endSpeed = remaining * 0.8 + 4
				end
				targetSpeed = math.min(cornerSpeed, headingSpeed, endSpeed)
				yawRate = side * math.min(angle * STEER_GAIN * turnScale, maxYaw) * math.clamp(math.abs(speed) / 6, 0.85, 1)
				if facingBackward then
					-- Rear blocked: pivot and crawl instead of stopping.
					yawRate = side * maxYaw
					targetSpeed = math.min(math.max(targetSpeed, 9), 16)
				end

				climb = climbHint
				onHill = onHill or climb > FLAT_GRADE * 2
				local ahead = feel("feelerAhead", bumper, sloped(forward), reach)
				local leftward = CFrame.Angles(0, FEELER_ANGLE, 0):VectorToWorldSpace(forward)
				local rightward = CFrame.Angles(0, -FEELER_ANGLE, 0):VectorToWorldSpace(forward)
				local towardsLeft = feel("feelerLeft", bumper, sloped(leftward), reactWithin)
				local towardsRight = feel("feelerRight", bumper, sloped(rightward), reactWithin)
				-- Distant hits only ease speed; steering/blocking only for obstacles we must stop for.
				local closeHit = ahead and ahead < reactWithin
				if ahead then
					-- On climbs keep enough speed to make the hill; only crawl for true walls.
					local floorSpeed = onHill and 14 or 4
					if closeHit then
						targetSpeed = math.min(targetSpeed, math.max((ahead - 3) * 2, floorSpeed))
						if speed > 0 and ahead < brakeHorizon then
							speed = math.min(speed, math.max((ahead - 3) * 2, floorSpeed))
						end
					elseif ahead < reach then
						-- Far roadside clutter: slight ease-off only, don't yank the wheel.
						targetSpeed = math.min(targetSpeed, math.max(targetSpeed * 0.92, topSpeed * 0.75))
					end
					if closeHit and ahead < reactWithin * 0.85 then
						local leftRoom, rightRoom = towardsLeft or reactWithin, towardsRight or reactWithin
						-- Prefer the side that still leads toward the route, not off the map.
						local openSide = leftRoom > rightRoom and 1 or -1
						if math.abs(leftRoom - rightRoom) > 2 then
							if openSide == side or not onHill then
								yawRate += openSide * maxYaw * profile.feeler * 0.65 * (1 - ahead / reactWithin)
							else
								yawRate += side * maxYaw * 0.4
							end
						end
					end
				end
				-- Pinned: scan for an open side and turn into it. Reverse when boxed and the rear
				-- is clear, then keep driving (do not abort as stuck — that caused stop loops).
				local moving = seat.AssemblyLinearVelocity.Magnitude
				local canReverse = os.clock() >= reverseCooldownUntil and rearClear and not sliding
				if closeHit and ahead < BLOCK_DISTANCE + 1.5 and moving < 5 then
					blockedSince = blockedSince or os.clock()
					if os.clock() - blockedSince > (onHill and BLOCK_TIME * 1.5 or BLOCK_TIME) then
						-- Poison cells for walls/fences (Slide included — it was driving through them).
						if not onHill and ahead < BLOCK_DISTANCE * 0.85 then
							markBlocked(bumper + forward * (ahead + CELL * 0.5), forward)
						end
						local openSide, openRoom = 0, ahead
						for _, degrees in ipairs({ 40, 65, 90, 120, 150 }) do
							local leftDir = CFrame.Angles(0, math.rad(degrees), 0):VectorToWorldSpace(forward)
							local rightDir = CFrame.Angles(0, -math.rad(degrees), 0):VectorToWorldSpace(forward)
							local leftRoom = feel("scanLeft", bumper, sloped(leftDir), reach) or reach
							local rightRoom = feel("scanRight", bumper, sloped(rightDir), reach) or reach
							if leftRoom > openRoom then
								openRoom, openSide = leftRoom, 1
							end
							if rightRoom > openRoom then
								openRoom, openSide = rightRoom, -1
							end
						end
						if openSide ~= 0 and openRoom > ahead + 2 then
							blockedSince = nil
							yawRate = openSide * maxYaw
							targetSpeed = math.min(math.max(targetSpeed, 10), 18)
						elseif canReverse then
							blockedSince = nil
							reverseUntil = os.clock() + REVERSE_TIME
							reverseCooldownUntil = reverseUntil + REVERSE_COOLDOWN
							local backUntil = reverseUntil
							local back = -forward * reverseSpeed
							local swing = side * maxYaw * 0.75
							while os.clock() < backUntil and humanoid.SeatPart == seat and car.Parent do
								RunService.Heartbeat:Wait()
								local rearHit = feel("feelerBehind", rearBumper, sloped(-forward), rearReach)
								if rearHit and rearHit < BLOCK_DISTANCE + 2 then
									break
								end
								seat.AssemblyLinearVelocity = Vector3.new(back.X, seat.AssemblyLinearVelocity.Y, back.Z)
								seat.AssemblyAngularVelocity = Vector3.new(0, swing, 0)
							end
							lastMoved = os.clock()
							lastProgress = seat.Position
							speed = 0
							-- Continue the route instead of forcing a full replan.
						else
							-- Boxed with no reverse room: pivot toward the openest side and crawl.
							blockedSince = nil
							yawRate = (openSide ~= 0 and openSide or side) * maxYaw
							targetSpeed = math.max(targetSpeed, onHill and HILL_SPEED or 12)
							-- Slide into a fence/building: replan around the blocked cell.
							if sliding and openRoom < ahead + 3 then
								brake()
								return false, "stuck"
							end
						end
					end
				else
					blockedSince = nil
				end
				-- Terrain: carry speed into climbs (a car crawling up a hill slides back down), ease
				-- off downhill, and slow down on grass, sand or mud.
				local steepest = math.max(climb, grade)
				if steepest > FLAT_GRADE and angle < math.rad(40) then
					targetSpeed = math.max(targetSpeed, math.min(topSpeed, HILL_SPEED + steepest * HILL_SPEED_PER_GRADE))
				elseif math.min(climb, grade) < -FLAT_GRADE then
					targetSpeed = math.min(targetSpeed, topSpeed * math.max(1 + math.min(climb, grade) * DOWNHILL_EASE, 0.5))
				end
				if ground and ROUGH_MATERIALS[ground.Material] then
					targetSpeed *= ROUGH_SPEED
				end
				-- Side feelers: ignore pushes that fight the route (those shove the car off-map).
				-- On hills, railings shove even harder — trust the route more than the sides.
				local avoid = 0
				local sideScale = onHill and 0.35 or 0.85
				local sideRef = math.max(reactWithin, 8)
				if towardsLeft and towardsLeft < sideRef then
					avoid -= maxYaw * profile.feeler * sideScale * (1 - towardsLeft / sideRef)
				end
				if towardsRight and towardsRight < sideRef then
					avoid += maxYaw * profile.feeler * sideScale * (1 - towardsRight / sideRef)
				end
				if avoid * side < 0 then
					avoid *= onHill and 0.05 or 0.2
				end
				yawRate += avoid
				yawRate = math.clamp(yawRate, -maxYaw, maxYaw)
			end
			speed += math.clamp(targetSpeed - speed, -profile.brake * dt, profile.accel * (1 + math.max(climb, grade, 0) * HILL_ACCEL) * dt)

			local velocity = seat.AssemblyLinearVelocity
			local travel = forward
			if speed > 0 and angle < math.rad(60) then
				travel = (forward + desired * profile.blend).Unit
			end
			-- Slide Mode: the car's travel lags behind where it points, so it drifts through turns.
			if profile.slide and speed > 15 and lastTravel and os.clock() >= reverseUntil then
				local hold = math.exp(-dt * SLIDE_GRIP)
				local blended = lastTravel * hold + travel * (1 - hold)
				if blended.Magnitude > 0.1 then
					travel = blended.Unit
					-- Past the widest slide angle the tyres bite: travel stays within MAX_SLIP of the nose.
					local along = travel:Dot(forward)
					if along < math.cos(MAX_SLIP) then
						local across = travel - forward * along
						across = across.Magnitude > 1e-3 and across.Unit or Vector3.zero
						travel = (forward * math.cos(MAX_SLIP) + across * math.sin(MAX_SLIP)).Unit
					end
				end
			end
			lastTravel = travel
			commandedSpeed = math.abs(speed)
			local horizontal = travel * speed
			-- Climbing: give the car the upward speed the slope needs, plus what gravity takes away
			-- this frame (downhill, gravity handles it).
			local climbSpeed = velocity.Y
			if ground and ground.Normal.Y > 0.5 then
				local normal = ground.Normal
				local slopeSpeed = -(normal.X * horizontal.X + normal.Z * horizontal.Z) / normal.Y
				if slopeSpeed > 0 then
					slopeSpeed += Workspace.Gravity * dt
				end
				if slopeSpeed > climbSpeed then
					climbSpeed = slopeSpeed
				end
			end
			seat.AssemblyLinearVelocity = Vector3.new(horizontal.X, climbSpeed, horizontal.Z)
			local spin = seat.AssemblyAngularVelocity
			seat.AssemblyAngularVelocity = Vector3.new(spin.X * 0.8, yawRate, spin.Z * 0.8)

			-- Stuck on something: back up and try again, then give up and let the caller replan.
			-- Only progress the way the car is pointing counts, so rolling back down a hill is stuck too.
			if (position - lastProgress):Dot(forward) > 2 or (not onHill and (position - lastProgress).Magnitude > 2) then
				lastProgress, lastMoved = position, os.clock()
			elseif os.clock() - lastMoved > (onHill and STUCK_TIME * 1.6 or (sliding and STUCK_TIME * 0.7 or STUCK_TIME))
				and os.clock() >= reverseUntil and os.clock() >= reverseCooldownUntil then
				stuckCount += 1
				local stuckLimit = MAX_STUCK + (onHill and HILL_RETRIES or 0) - (sliding and 1 or 0)
				if stuckCount > stuckLimit or (sliding and not rearClear) then
					-- A hill the car couldn't climb isn't an obstacle to route around.
					if not onHill and not sliding then
						markBlocked(position + forward * (halfLength + CELL * 0.5), forward)
					end
					brake()
					return false, "stuck"
				end
				if sliding and not rearClear then
					brake()
					return false, "stuck"
				end
				-- Stalled on a climb: back straight down for a run-up (no yaw — that spins the car).
				-- Slide: only a short reverse when the rear is open, then replan.
				reverseUntil = os.clock() + (onHill and RUN_UP_TIME or (sliding and 0.25 or REVERSE_TIME))
				reverseCooldownUntil = reverseUntil + (sliding and REVERSE_COOLDOWN * 0.6 or REVERSE_COOLDOWN)
				lastMoved = reverseUntil
				lastProgress = position
				speed = -reverseSpeed * (onHill and 0.85 or (sliding and 0.55 or 0.6))
			end
		end
		brake()
		return false
	end

	-- Drives to the road spot nearest `destination`. Returns success, reason.
	-- options: keepRolling (don't stop at the destination), maxSeconds (return "replan" after this
	-- long), ignore (instances the feelers ignore), mode (driving mode override), adaptive,
	-- liveDestination (polled while driving: nil keep, Vector3/CFrame retarget, false →
	-- "destination_changed").
	-- Continuous drives never finish on their own: nextTarget(position, why) is asked for a new
	-- target near the end of the route ("end"), every retargetEvery seconds ("due") and when
	-- someone in the car gets hurt ("hurt"); it returns a position, nil to keep going, or false to
	-- stop (the drive then returns false, "stop"). direct(position, offRoute) may return a point
	-- (and speed) to steer straight at instead of following the route.
	local function snapToRoad(network, position)
		if not network then
			return position
		end
		-- Keep bridge traffic on the bridge: same deck first, then any nearby major road.
		local node = nearestNode(network, position, GOAL_SNAP_CELLS, nil, SAME_LEVEL_RISE, nil, function(candidate)
			return onMajorNetwork(network, candidate)
		end) or nearestNode(network, position, GOAL_SNAP_CELLS, nil, SAME_LEVEL_RISE) or nearestNode(
			network,
			position,
			GOAL_SNAP_CELLS,
			nil,
			nil,
			nil,
			function(candidate)
				return onMajorNetwork(network, candidate)
			end
		) or nearestNode(network, position, GOAL_SNAP_CELLS)
		return node and Vector3.new(node.ix * CELL, node.y + 2, node.iz * CELL) or position
	end

	-- For destinations (shops, spots): the closest road spot that can actually see the place, so
	-- the car pulls up out front rather than on a side street behind a wall.
	local function wallHug(network, spot)
		local eye = spot + Vector3.new(0, 2.5, 0)
		for _, dir in ipairs({
			Vector3.new(1, 0, 0),
			Vector3.new(-1, 0, 0),
			Vector3.new(0, 0, 1),
			Vector3.new(0, 0, -1),
		}) do
			local hit = Workspace:Raycast(eye, dir * 8, network.clearance)
			if hit and hit.Normal.Y < 0.45 and (hit.Position - eye).Magnitude < 7 then
				return true
			end
			local hidden = hiddenHit(eye, dir, 8)
			if hidden and hidden < 7 then
				return true
			end
		end
		return false
	end

	local function snapToDestination(network, position)
		if not network then
			return position
		end
		local cx, cz = math.round(position.X / CELL), math.round(position.Z / CELL)
		-- Uphill spots (Top Gun, Market) often sit past the usual snap radius from the ramp road.
		local radius = GOAL_SNAP_CELLS + 20
		local candidates, seen = {}, {}
		local function consider(node, majorOnly)
			if not node or node.lot or seen[node] then
				return
			end
			if majorOnly and not onMajorNetwork(network, node) then
				return
			end
			seen[node] = true
			local spot = Vector3.new(node.ix * CELL, node.y, node.iz * CELL)
			-- Prefer road at a similar height so we don't park under a bridge or at the hill base.
			local score = flatDistance(spot, position) + math.abs(node.y - position.Y) * 18 + node.edge * 14
			local hugging = wallHug(network, spot)
			if hugging then
				score += 80
			end
			table.insert(candidates, { node, score, hugging })
		end
		for ix = cx - radius, cx + radius do
			for iz = cz - radius, cz + radius do
				local node = network.cells[cellKey(ix, iz)]
				if node and math.abs(node.y - position.Y) <= SAME_LEVEL_RISE + 6 then
					consider(node, true)
				end
			end
		end
		-- Plateau scraps / other decks only if this deck has almost nothing.
		if #candidates < 8 then
			for ix = cx - radius, cx + radius do
				for iz = cz - radius, cz + radius do
					consider(network.cells[cellKey(ix, iz)], true)
				end
			end
		end
		if #candidates < 8 then
			for ix = cx - radius, cx + radius do
				for iz = cz - radius, cz + radius do
					consider(network.cells[cellKey(ix, iz)], false)
				end
			end
		end
		table.sort(candidates, function(a, b)
			return a[2] < b[2]
		end)
		for i = 1, math.min(#candidates, SIGHT_CHECKS) do
			local entry = candidates[i]
			if not entry[3] then
				local node = entry[1]
				local eye = Vector3.new(node.ix * CELL, node.y + 3, node.iz * CELL)
				local hit = Workspace:Raycast(eye, position + Vector3.new(0, 1, 0) - eye, network.clearance)
				if not hit or (hit.Position - position).Magnitude < SIGHT_SLACK then
					return eye - Vector3.new(0, 1, 0)
				end
			end
		end
		-- Fall back: best non-hugging road spot, then any snap.
		for i = 1, math.min(#candidates, SIGHT_CHECKS) do
			if not candidates[i][3] then
				local node = candidates[i][1]
				return Vector3.new(node.ix * CELL, node.y + 2, node.iz * CELL)
			end
		end
		if candidates[1] then
			local node = candidates[1][1]
			return Vector3.new(node.ix * CELL, node.y + 2, node.iz * CELL)
		end
		return snapToRoad(network, position)
	end

	local function unitOrNil(vector)
		vector = Vector3.new(vector.X, 0, vector.Z)
		return vector.Magnitude > 0.1 and vector.Unit or nil
	end

	local function driveTo(destination, active, options)
		options = options or {}
		local deadline = options.maxSeconds and os.clock() + options.maxSeconds or nil
		local network = getRoads()
		local continuous = options.nextTarget ~= nil
		local target = continuous and snapToRoad(network, destination.Position) or snapToDestination(network, destination.Position)
		local replans = 0
		while true do
			local car, seat, humanoid = myCar()
			if not car or not active() then
				return false
			end
			local from = seat.Position - Vector3.new(0, SEAT_HEIGHT - 1, 0)
			if not continuous and flatDistance(from, target) < ARRIVE_DISTANCE then
				return true
			end
			if network then
				learnSurface(network, seat.Position, car)
			end
			local points, complete = planDrive(network, from, target, unitOrNil(seat.CFrame.LookVector), continuous and QUICK_CENTER or nil)
			if not points then
				if not (options.direct and network and onRoad(network, from, target)) then
					return false, "no road leads there"
				end
				points, complete = { from, target }, true
			end
			if #points < 2 then
				table.insert(points, 1, from)
			end
			local route = {
				points = points,
				final = complete,
				target = target,
				keepRolling = options.keepRolling,
				continuous = continuous,
				direct = options.direct,
				deadline = deadline,
				ignore = options.ignore,
				mode = options.mode,
				adaptive = options.adaptive,
				chase = options.chase,
			}
			local legs = 1
			local planGeneration = 0
			function route.extend()
				legs += 1
				if legs > MAX_LEGS then
					route.failed, route.reason = true, "the trip took too many legs"
					return
				end
				-- Slide chase prefers a full retarget over stitching onto a stale stub.
				if route.chase then
					return
				end
				route.extending = true
				local generation = planGeneration
				task.spawn(function()
					local last = route.points[#route.points]
					local before = route.points[#route.points - 1] or last
					local heading = Vector3.new(last.X - before.X, 0, last.Z - before.Z)
					local ok, more, done = pcall(planDrive, network, last, route.target, heading.Magnitude > 0.1 and heading.Unit or nil)
					if generation == planGeneration and ok and more and #more >= 2 then
						for i = 2, #more do
							table.insert(route.points, more[i])
						end
						route.final = done
					elseif generation == planGeneration then
						route.failed = true
					end
					if generation == planGeneration then
						route.extending = false
					end
				end)
			end
			-- Plans towards `newTarget` in the background while the car keeps driving the current
			-- route. The new route joins it a little ahead of the car, or (fromCar, or when the car
			-- is about to run out of route) starts just ahead of the car and replaces it.
			function route.retarget(newTarget, fromCar, why)
				-- Chase may interrupt a slow extend so the path doesn't die at a curb.
				if route.extending and not route.chase then
					return
				end
				planGeneration += 1
				local generation = planGeneration
				route.extending = true
				route.replanWhy = why
				-- Fixed destinations park out front; continuous drives (roam/chase) snap to road.
				local goal = continuous and snapToRoad(network, newTarget) or snapToDestination(network, newTarget)
				task.spawn(function()
					local current = route.points
					local carNow = seat.Position - Vector3.new(0, SEAT_HEIGHT - 1, 0)
					local heading = unitOrNil(seat.CFrame.LookVector)
					local lead = math.max(JOIN_AHEAD, math.abs(route.speed or 0) * (route.chase and 2.2 or JOIN_SECONDS))
					local join = nil
					-- Prefer joining ahead on the current path; never join behind the nose.
					if not fromCar then
						local travelled, previous = 0, carNow
						for i = (route.index or 1) + 1, #current do
							local step = Vector3.new(current[i].X - previous.X, 0, current[i].Z - previous.Z)
							if heading and step.Magnitude > 1 and step.Unit:Dot(heading) < -0.1 then
								break
							end
							travelled += flatDistance(current[i], previous)
							previous = current[i]
							if travelled >= lead then
								join = i
								break
							end
						end
					end
					local from
					if join then
						from, heading = current[join], unitOrNil(current[join] - current[join - 1]) or heading
					elseif route.chase then
						-- Don't invent a start past fences/buildings (lead jumps caused wall paths).
						from = carNow
					else
						from = carNow + (heading or Vector3.zero) * lead
					end
					local ok, more, done = pcall(planDrive, network, from, goal, heading, QUICK_CENTER)
					local applied = false
					if generation == planGeneration and ok and more and #more >= 2 and route.points == current then
						applied = true
						if join and (route.index or 1) < join then
							for i = #current, join + 1, -1 do
								table.remove(current, i)
							end
							for i = 2, #more do
								table.insert(current, more[i])
							end
						elseif not join then
							table.clear(current)
							table.insert(current, carNow)
							-- Drop any planned points that sit behind the car (prevents instant U-turns).
							for _, point in ipairs(more) do
								local offset = Vector3.new(point.X - carNow.X, 0, point.Z - carNow.Z)
								if not heading or offset.Magnitude < 2 or offset.Unit:Dot(heading) > -0.05 then
									table.insert(current, point)
								end
							end
							-- Skip waypoints the car can't reach without clipping a wall/fence.
							while #current >= 3 and network and not onRoad(network, current[1], current[2], CELL, current[1], current[2]) do
								table.remove(current, 2)
							end
							if #current < 2 or (network and not onRoad(network, current[1], current[2], CELL, current[1], current[2])) then
								applied = false
							else
								route.resetIndex = true
							end
						else
							-- The car already passed where the new route joins; the next tick asks again.
							applied = false
						end
					end
					if generation == planGeneration then
						if applied then
							route.target, route.final, route.failed = goal, done, false
							route.redraw = true
							notifyRoute(why or (route.chase and "chase" or "due"))
						end
						route.extending = false
					end
				end)
			end
			if continuous then
				local every = options.retargetEvery or math.huge
				local minPath = options.minPath or CHASE_MIN_PATH
				local lastAsked, nextDue, lastHurt = os.clock(), os.clock() + every, Condition.hurtAt
				function route.onTick(position)
					if options.visit then
						options.visit(position)
					end
					-- Chase still needs a new path while a background extend is running; don't stall.
					local busy = route.extending and not route.chase
					if busy then
						return nil
					end
					local remaining = flatDistance(route.points[#route.points], position)
					local why = nil
					if Condition.hurtAt > lastHurt then
						lastHurt, why = Condition.hurtAt, "hurt"
					elseif remaining < math.max(minPath, math.abs(route.speed or 0) * 2.5)
						or #route.points < 4 then
						why = "short"
					elseif route.final and os.clock() - lastAsked > 0.5 and remaining < math.max(EXTEND_AHEAD, math.abs(route.speed or 0) * EXTEND_SECONDS) then
						why = "end"
					elseif os.clock() >= nextDue then
						why = "due"
					end
					if why then
						lastAsked, nextDue = os.clock(), os.clock() + every
						local nextTarget = options.nextTarget(position, why)
						if nextTarget == false then
							return "stop"
						elseif nextTarget then
							-- Short/stale stubs: rebuild from the car so the path isn't a curb dead-end.
							route.retarget(
								nextTarget,
								route.offRoute or why == "short" or why == "hurt" or options.chase,
								why
							)
							return nil
						end
					end
					if route.offRoute and os.clock() - lastAsked > 0.8 then
						lastAsked = os.clock()
						route.retarget(route.target, true, "offroute")
					end
					return nil
				end
			end
			-- liveDestination(): nil keep going, Vector3/CFrame retarget now, false abort ("destination_changed").
			-- Lets the Self Driving dropdown switch goals without toggling the feature off/on.
			if options.liveDestination then
				local lastLive, priorTick = 0, route.onTick
				function route.onTick(position)
					if priorTick then
						local stop = priorTick(position)
						if stop then
							return stop
						end
					end
					if route.extending or os.clock() - lastLive < 0.25 then
						return nil
					end
					lastLive = os.clock()
					local ok, result = pcall(options.liveDestination, position, route.target)
					if not ok then
						return nil
					end
					if result == false then
						return "destination_changed"
					end
					local point = typeof(result) == "CFrame" and result.Position
						or (typeof(result) == "Vector3" and result or nil)
					if point and flatDistance(point, route.target) > ARRIVE_DISTANCE then
						route.retarget(point, true, "destination")
					end
					return nil
				end
			end
			local arrived, reason = follow(network, car, seat, humanoid, route, active)
			if arrived then
				return true
			end
			target = route.target
			if reason ~= "stuck" then
				return false, reason
			end
			replans += 1
			if replans > MAX_REPLANS then
				notifyRoute("stuck")
				return false, "the car kept getting stuck"
			end
		end
	end

	local function drivable(entry)
		return entry[2].Position.Y < MAX_DRIVE_HEIGHT
	end

	local function clearDriveDebug()
		for _, name in ipairs({
			"drive",
			"target",
			"feelerAhead",
			"feelerLeft",
			"feelerRight",
			"feelerBehind",
			"feelerBackLeft",
			"feelerBackRight",
			"scanLeft",
			"scanRight",
		}) do
			PathDebug.clear(name)
		end
		PathDebug.clearPrefix("blocked")
	end

	local function stopSelfDriving()
		clearDriveDebug()
		Arsenic.Enabled.SelfDriving = false
		if Vehicles.selfDriveToggle then
			pcall(function()
				Vehicles.selfDriveToggle:Set(false)
			end)
		end
	end

	-- Chase Mode: a destination far from nearby players (and not back through them).
	local function escapeDestination(position)
		local nearby = threatsNear(position, THREAT_RADIUS)
		local best, bestScore = nil, -math.huge
		for _, entry in ipairs(Vehicles.selfDriveLocations) do
			local spot = entry[2].Position
			local away = (spot - position).Magnitude
			if drivable(entry) and away > 150 then
				local score
				if #nearby == 0 then
					score = math.random() * 1000
				else
					local closest = math.huge
					for _, threat in ipairs(nearby) do
						closest = math.min(closest, (spot - threat).Magnitude)
					end
					score = closest - away * 0.25
				end
				if score > bestScore then
					best, bestScore = entry, score
				end
			end
		end
		return best
	end

	-- Slide Mode's target: the player picked in the Players tab, otherwise the nearest player driving.
	local function slideTarget(from)
		local selected = getSelectedPlayer()
		if selected and selected ~= LocalPlayer and playerRoot(selected) then
			return selected
		end
		local best, bestDistance = nil, math.huge
		for _, player in ipairs(Players:GetPlayers()) do
			local root = player ~= LocalPlayer and playerVehicle(player) and playerRoot(player)
			if root and (root.Position - from).Magnitude < bestDistance then
				best, bestDistance = player, (root.Position - from).Magnitude
			end
		end
		return best
	end

	-- Chases `player` (Slide Mode) as one continuous drive: the route towards where they're heading
	-- is replanned in the background every CHASE_REPLAN seconds, and up close (or while the car is
	-- off its route) it steers straight at them. Returns when the chase ends.
	local function chase(player, active)
		local _, seat = myCar()
		if not seat then
			return
		end
		local function lead(position)
			local root = player.Parent and playerRoot(player)
			if not root then
				return nil
			end
			local distance = flatDistance(root.Position, position)
			-- Aim further ahead so the road plan stays longer than a curb stub.
			local predict = math.clamp(distance / 70, 0.35, 2.4)
			return root.Position + root.AssemblyLinearVelocity * predict, distance, root
		end
		local first = lead(seat.Position)
		if not first then
			task.wait(0.5)
			return
		end
		local ignore = { player.Character }
		local theirCar = playerVehicle(player)
		if theirCar then
			table.insert(ignore, theirCar)
		end
		local close = false
		local network = getRoads()
		local clearUntil, clearPath = 0, false
		-- Straight at them only on open road with a clear corridor (no fences/buildings in the way).
		local function straightLineOpen(position, point)
			if not network then
				return false
			end
			if os.clock() >= clearUntil then
				clearUntil = os.clock() + 0.15
				local ground = position - Vector3.new(0, SEAT_HEIGHT - 1, 0)
				local goal = Vector3.new(point.X, ground.Y, point.Z)
				clearPath = onRoad(network, ground, goal, ROAD_SAMPLE, ground, point)
			end
			return clearPath
		end
		local _, reason = driveTo(CFrame.new(first), active, {
			keepRolling = true,
			ignore = ignore,
			chase = true,
			retargetEvery = CHASE_REPLAN,
			minPath = CHASE_MIN_PATH,
			mode = "Slide Mode",
			nextTarget = function(position)
				if Arsenic.Values.SelfDriveMode ~= "Slide Mode" or Condition.retreat() or slideTarget(position) ~= player then
					return false
				end
				return lead(position) or false
			end,
			direct = function(position, offRoute)
				local point, distance, root = lead(position)
				if not point then
					return nil
				end
				close = distance < (close and CLOSE_CHASE * 1.35 or CLOSE_CHASE)
				if not straightLineOpen(position, point) then
					return nil
				end
				if close then
					-- Close the gap quickly, then match their speed instead of overshooting them.
					local theirSpeed = root.AssemblyLinearVelocity.Magnitude
					return point, theirSpeed + math.max(distance - 10, 0) * 1.5 + 8
				end
				-- Off-route: stay on the road plan instead of cutting through props/fences.
				return nil
			end,
		})
		if reason and reason ~= "stop" then
			task.wait(0.25)
		end
	end

	-- Exploring: the map's roads are split into square regions; Drive Around Map remembers how
	-- long it has spent in each and heads for little-visited road regions a fair drive away.
	local visits = {}
	local nextVisit = 0
	local function regionKey(x, z)
		return cellKey(math.floor(x / EXPLORE_REGION), math.floor(z / EXPLORE_REGION))
	end

	local function recordVisit(position)
		if os.clock() >= nextVisit then
			nextVisit = os.clock() + 0.5
			local key = regionKey(position.X, position.Z)
			visits[key] = (visits[key] or 0) + 1
		end
	end

	-- Road spots grouped by region (middle-of-road spots only, so targets sit on the road).
	local function roadRegions(network)
		if network.regions then
			return network.regions
		end
		local regions = {}
		for _, node in pairs(network.cells) do
			if node and not node.lot and node.edge == 0 and onMajorNetwork(network, node) then
				local key = regionKey(node.ix * CELL, node.iz * CELL)
				local region = regions[key]
				if not region then
					region = { key = key, nodes = {} }
					regions[key] = region
				end
				table.insert(region.nodes, node)
			end
		end
		local list = {}
		for _, region in pairs(regions) do
			if #region.nodes >= EXPLORE_MIN_NODES then
				table.insert(list, region)
			end
		end
		network.regions = list
		return list
	end

	local function exploreTarget(position)
		local network = getRoads()
		if not network then
			return nil
		end
		local best, bestScore = nil, math.huge
		for _, region in ipairs(roadRegions(network)) do
			local node = region.nodes[math.random(1, #region.nodes)]
			local spot = Vector3.new(node.ix * CELL, node.y + 2, node.iz * CELL)
			local distance = flatDistance(spot, position)
			if distance > EXPLORE_MIN_DISTANCE and spot.Y < MAX_DRIVE_HEIGHT then
				-- Fewest visits first; among those, a drive of a sensible length, with some chance.
				local score = (visits[region.key] or 0) * EXPLORE_VISIT_WEIGHT
					+ math.abs(distance - EXPLORE_IDEAL_DISTANCE) / EXPLORE_IDEAL_DISTANCE
					+ math.random() * 2
				if score < bestScore then
					best, bestScore = { region, spot }, score
				end
			end
		end
		if not best then
			return nil
		end
		-- Count picking it as a visit too, so a region the car can't reach isn't picked forever.
		visits[best[1].key] = (visits[best[1].key] or 0) + EXPLORE_PICK_VISITS
		return best[2]
	end

	-- Where Drive Around Map heads next: away from players in Chase Mode, under fire, or when
	-- breaking off a Slide Mode chase; otherwise somewhere it hasn't explored much. false = stop roaming.
	local function roamTarget(position, why)
		local mode = Arsenic.Values.SelfDriveMode
		if mode == "Slide Mode" then
			if not Condition.retreat() then
				return false
			end
		elseif Arsenic.Values.SelfDriveDestination ~= DRIVE_AROUND
			and Arsenic.Values.SelfDriveDestination ~= FOLLOW_PLAYER
			and Arsenic.Values.SelfDriveDestination ~= TAXI_PLAYER then
			return false
		elseif Arsenic.Values.SelfDriveDestination == FOLLOW_PLAYER
			or Arsenic.Values.SelfDriveDestination == TAXI_PLAYER then
			return false
		end
		if mode ~= "Civilian Mode" or Condition.underFire() then
			local entry = escapeDestination(position)
			if entry then
				return entry[2].Position
			end
		end
		if why ~= "end" then
			return nil
		end
		local spot = exploreTarget(position)
		if spot then
			return spot
		end
		local options = {}
		for _, candidate in ipairs(Vehicles.selfDriveLocations) do
			if drivable(candidate) and flatDistance(candidate[2].Position, position) > 150 then
				table.insert(options, candidate)
			end
		end
		local entry = options[math.random(1, math.max(#options, 1))]
		return entry and entry[2].Position or nil
	end

	-- For other features (Auto Strike): drive the car we're in to `destination`, adapting to
	-- players nearby and to damage. Returns arrived, reason.
	function Vehicles.selfDriveTo(destination)
		local function active()
			return not Arsenic.Destroyed and myCar() ~= nil and not on("FlyCars")
		end
		local mode = Arsenic.Values.SelfDriveMode == "Slide Mode" and "Civilian Mode" or Arsenic.Values.SelfDriveMode
		local ok, arrived, reason = pcall(driveTo, destination, active, { mode = mode, adaptive = true })
		clearDriveDebug()
		if not ok then
			return false, tostring(arrived)
		end
		return arrived, reason
	end

	local function isGasPrompt(prompt)
		if not (prompt and prompt:IsA("ProximityPrompt") and prompt.Enabled) then
			return false
		end
		if prompt.ActionText == "Buy Gas" then
			return true
		end
		local parent = prompt.Parent
		return parent and parent.Name == "BuyGas123" and (prompt.ObjectText == "Gas" or prompt.ActionText:lower():find("gas", 1, true) ~= nil)
	end

	local function gasPromptPosition(prompt)
		return getWorldPosition(prompt.Parent) or (prompt.Parent and prompt.Parent:IsA("BasePart") and prompt.Parent.Position)
	end

	-- Nearest on-map Buy Gas pump (skips sky/interior copies).
	local function findNearestGasPump(from)
		local best, bestDistance = nil, math.huge
		local map = Workspace:FindFirstChild("1# Map") or Workspace
		for _, descendant in ipairs(map:GetDescendants()) do
			if isGasPrompt(descendant) then
				local position = gasPromptPosition(descendant)
				if position and position.Y > 180 and position.Y < 450 and math.abs(position.X) < 8000 and math.abs(position.Z) < 8000 then
					local distance = (position - from).Magnitude
					if distance < bestDistance then
						best, bestDistance = descendant, distance
					end
				end
			end
		end
		return best, bestDistance
	end

	local function carFuelAmount(car)
		if not car then
			return nil
		end
		local attribute = car:GetAttribute("Fuel") or car:GetAttribute("fuel") or car:GetAttribute("Gas")
		if type(attribute) == "number" then
			return attribute
		end
		local value = car:FindFirstChild("Fuel", true) or car:FindFirstChild("Gas", true)
		if value and value:IsA("NumberValue") then
			return value.Value
		end
		return nil
	end

	-- Roadside bay next to a pump: close enough to use Buy Gas after getting out, not into the pump.
	local function parkSpotBesidePump(network, pumpPosition, from)
		local road = snapToDestination(network, pumpPosition)
		local toward = Vector3.new(pumpPosition.X - road.X, 0, pumpPosition.Z - road.Z)
		if toward.Magnitude > 1 then
			-- Pull toward the pump until ~8 studs out (prompt reach), staying on road.
			for _, standOff in ipairs({ 8, 10, 12, 6, 14 }) do
				if toward.Magnitude > standOff then
					local candidate = snapToRoad(network, pumpPosition - toward.Unit * standOff)
					if candidate and flatDistance(candidate, pumpPosition) <= 16 then
						road = candidate
						break
					end
				end
			end
		end
		local along = Vector3.new(road.X - (from and from.X or road.X), 0, road.Z - (from and from.Z or road.Z))
		if along.Magnitude < 1 then
			along = Vector3.new(-toward.Z, 0, toward.X)
		end
		if along.Magnitude < 0.1 then
			along = Vector3.new(0, 0, -1)
		end
		return CFrame.lookAt(road, road + along.Unit)
	end

	-- Drive to the nearest gas pump, park beside it, buy gas, get back in.
	function Vehicles.refuelVehicle()
		local car, seat, humanoid = myCar()
		if not (car and seat and humanoid) then
			return false, "get in a driver's seat first"
		end
		if on("FlyCars") then
			return false, "turn off Fly Cars first"
		end
		local prompt = select(1, findNearestGasPump(seat.Position))
		if not prompt then
			return false, "no gas pump was found"
		end
		local pumpPosition = gasPromptPosition(prompt)
		if not pumpPosition then
			return false, "no gas pump was found"
		end

		Vehicles.externalDrive = true
		local results = table.pack(pcall(function()
			local network = getRoads()
			local parking = parkSpotBesidePump(network, pumpPosition, seat.Position)
			notify("Self Driving to the nearest gas pump.")
			local function active()
				local current = select(1, myCar())
				return not Arsenic.Destroyed and current == car and humanoid.SeatPart == seat and not on("FlyCars")
			end
			local arrived = driveTo(parking, active, { mode = "Civilian Mode" })
			car, seat, humanoid = myCar()
			if not (car and seat and humanoid and humanoid.SeatPart == seat) then
				return false, "left the car on the way to the pump"
			end
			-- Nudge into the bay if pathfinding stopped a little short of the pump.
			if flatDistance(seat.Position, pumpPosition) > 14 then
				local restore = ghostCar(car)
				car:PivotTo(parking * CFrame.new(0, 2, 0))
				restore()
				landCar(car, seat)
				task.wait(0.35)
			elseif not arrived then
				return false, "could not reach the gas pump"
			end

			forceUnseat(humanoid, seat)
			task.wait(0.25)
			local root = getRoot()
			if not root then
				return false, "character was lost while refueling"
			end
			local away = Vector3.new(root.Position.X - pumpPosition.X, 0, root.Position.Z - pumpPosition.Z)
			if away.Magnitude < 0.1 then
				away = Vector3.new(parking.LookVector.X, 0, parking.LookVector.Z)
			end
			if away.Magnitude < 0.1 then
				away = Vector3.new(1, 0, 0)
			end
			local stand = pumpPosition + away.Unit * 3
			local groundY = findGroundY(stand)
			if groundY then
				stand = Vector3.new(stand.X, groundY + getStandHeight(humanoid, root), stand.Z)
			end
			Pathing.walkTo(humanoid, CFrame.lookAt(stand, Vector3.new(pumpPosition.X, stand.Y, pumpPosition.Z)), 6)

			local fuelBefore = carFuelAmount(car)
			local moneyBefore = Money.getStat and Money.getStat("Money") or nil
			local messageMark = gameMessage.time
			local function refueled()
				local fuelNow = carFuelAmount(car)
				if fuelBefore and fuelNow and fuelNow > fuelBefore + 0.5 then
					return true
				end
				if moneyBefore and Money.getStat and Money.getStat("Money") < moneyBefore then
					return true
				end
				if gameMessage.time ~= messageMark then
					local text = gameMessage.text:lower()
					if text:find("gas", 1, true) or text:find("fuel", 1, true) or text:find("refuel", 1, true) then
						return true
					end
				end
				return false
			end
			local bought = false
			local function waitRefuel(seconds)
				local deadline = os.clock() + seconds
				while os.clock() < deadline do
					if refueled() then
						return true
					end
					task.wait(0.1)
				end
				return refueled()
			end
			for _ = 1, 5 do
				if not (prompt and prompt.Parent and isGasPrompt(prompt)) then
					prompt = select(1, findNearestGasPump(root.Position))
				end
				if prompt then
					firePrompt(prompt)
				end
				if waitRefuel(2) then
					bought = true
					break
				end
			end
			if not bought then
				-- Still try to finish the trip; some servers don't surface a clear fuel signal.
				if prompt then
					firePrompt(prompt)
				end
				task.wait(0.8)
			end

			if not (Vehicles.enterDriverSeat and Vehicles.enterDriverSeat(car)) then
				return false, "could not get back in the car after refueling"
			end
			return true
		end))
		Vehicles.externalDrive = false
		clearDriveDebug()
		if not results[1] then
			return false, tostring(results[2])
		end
		return table.unpack(results, 2, results.n)
	end

	-- Places whose teleport spot is inside a separate interior: drive to the street entrance.
	local DRIVE_SPOTS = {
		-- StreetRain2 / crosswalk approach on the upper city (interior teleport is elsewhere).
		["Top Gun Store"] = CFrame.new(-280, 280, -900),
		-- Real Enter Gunshop (old coords sat next to the dealership ATM).
		["Bottom Gun Store"] = CFrame.new(-1025, 255, -810),
		-- Street approach, not the dealership parking lot.
		["Dealership"] = CFrame.new(-455, 253, -1265),
		-- Street in front of the hospital, away from the thin roadside wall (wa3w).
		["Hospital"] = CFrame.new(-1540, 252, 42),
		-- Road in front of Market (teleport sits above driveable height on the plaza).
		["Market"] = CFrame.new(-450, 333, -540),
	}

	local function findLocation(name)
		if DRIVE_SPOTS[name] then
			return DRIVE_SPOTS[name]
		end
		for _, entry in ipairs(Vehicles.selfDriveLocations) do
			if entry[1] == name then
				return entry[2]
			end
		end
		return nil
	end

	-- Road near a player (or their vehicle), never their exact spot inside a building.
	local function roadNearPlayer(player, from)
		local root = player and player.Parent and playerRoot(player)
		if not root then
			return nil
		end
		local network = getRoads()
		local aim = root.Position
		local theirCar = playerVehicle(player)
		if theirCar then
			local seat = getDriveSeat(theirCar)
			aim = seat and seat.Position or theirCar:GetPivot().Position
		end
		local velocity = Vector3.new(root.AssemblyLinearVelocity.X, 0, root.AssemblyLinearVelocity.Z)
		local lead = aim + velocity * math.clamp((aim - (from or aim)).Magnitude / 80, 0.2, 1.2)
		-- Prefer a road cell a little short of them so we don't path into walls/interiors.
		local spot = snapToRoad(network, lead)
		if network and from and flatDistance(spot, from) < 8 then
			local node = nearestNodeLeveled(network, lead, GOAL_SNAP_CELLS, nil, nil, function(candidate)
				return onMajorNetwork(network, candidate) and not candidate.lot
			end)
			if node then
				spot = Vector3.new(node.ix * CELL, node.y + 2, node.iz * CELL)
			end
		end
		return spot
	end

	local function playerInCar(player, car)
		if not (player and car) then
			return false
		end
		for _, descendant in ipairs(car:GetDescendants()) do
			if (descendant:IsA("Seat") or descendant:IsA("VehicleSeat")) and descendant.Occupant then
				local character = descendant.Occupant.Parent
				if Players:GetPlayerFromCharacter(character) == player then
					return true
				end
			end
		end
		return false
	end

	-- Follows the Players-tab target on road (character or vehicle), never into buildings.
	local function followPlayer(player, active)
		local _, seat = myCar()
		if not (seat and player) then
			return
		end
		local first = roadNearPlayer(player, seat.Position)
		if not first then
			notify("Follow: no road near " .. player.Name .. ".")
			task.wait(0.5)
			return
		end
		driveTo(CFrame.new(first), active, {
			keepRolling = true,
			retargetEvery = 2.5,
			nextTarget = function(position)
				if Arsenic.Values.SelfDriveDestination ~= FOLLOW_PLAYER then
					return false
				end
				if not player.Parent or not playerRoot(player) then
					return false
				end
				return roadNearPlayer(player, position) or false
			end,
			liveDestination = function()
				if Arsenic.Values.SelfDriveDestination ~= FOLLOW_PLAYER then
					return false
				end
				return nil
			end,
		})
	end

	-- Picks up the selected player on road, waits for them to sit, then drives to the taxi drop-off.
	local function taxiPlayer(player, active)
		local dropName = Arsenic.Values.TaxiDropOff
		local drop = findLocation(dropName)
		if not drop then
			notify("Taxi: choose a drop-off location first.")
			return
		end
		if not player then
			notify("Taxi: select a player in the Players tab first.")
			return
		end
		local car, seat = myCar()
		if not seat then
			return
		end
		local pickup = roadNearPlayer(player, seat.Position)
		if not pickup then
			notify("Taxi: no road near " .. player.Name .. ".")
			return
		end
		notify("Taxi: driving to pick up " .. player.Name .. ".")
		local arrived = driveTo(CFrame.new(pickup), function()
			return active() and Arsenic.Values.SelfDriveDestination == TAXI_PLAYER
		end, { mode = "Civilian Mode" })
		if not arrived or not active() then
			return
		end
		if playerInCar(player, select(1, myCar())) then
			notify("Taxi: " .. player.Name .. " is already in the car.")
		else
			notify("Taxi: waiting for " .. player.Name .. " to get in (" .. TAXI_WAIT .. "s)...")
			local deadline = os.clock() + TAXI_WAIT
			while active() and Arsenic.Values.SelfDriveDestination == TAXI_PLAYER and os.clock() < deadline do
				car = myCar()
				if playerInCar(player, car) then
					break
				end
				-- Nudge closer if they moved, without leaving the road.
				local _, nowSeat = myCar()
				local nearer = nowSeat and roadNearPlayer(player, nowSeat.Position)
				if nearer and flatDistance(nearer, nowSeat.Position) > 18 then
					driveTo(CFrame.new(nearer), function()
						return active() and Arsenic.Values.SelfDriveDestination == TAXI_PLAYER and not playerInCar(player, select(1, myCar()))
					end, { mode = "Civilian Mode", maxSeconds = 8 })
				end
				task.wait(0.4)
			end
			if not playerInCar(player, select(1, myCar())) then
				notify("Taxi: " .. player.Name .. " did not get in.")
				return
			end
		end
		notify("Taxi: taking " .. player.Name .. " to " .. dropName .. ".")
		local done = driveTo(drop, function()
			return active() and Arsenic.Values.SelfDriveDestination == TAXI_PLAYER
		end)
		if done then
			notify("Taxi: arrived at " .. dropName .. ".")
		end
	end

	Features.SelfDriving = {
		enable = function()
			driveGeneration += 1
			local generation = driveGeneration
			local function alive()
				return on("SelfDriving") and driveGeneration == generation
			end
			-- Other features (Auto Strike) take the wheel while they need the car.
			local function active()
				return alive() and not on("FlyCars") and not Vehicles.externalDrive
			end
			local waitingNotice, noTargetNotice = false, false
			local failures = 0
			local finished = false
			while alive() and not finished do
				if on("FlyCars") then
					notify("Turn off Fly Cars first.")
					finished = true
				elseif Vehicles.externalDrive or not myCar() then
					if not waitingNotice and not Vehicles.externalDrive then
						waitingNotice = true
						notify("Self Driving takes over when you get in a driver's seat.")
					end
					task.wait(0.5)
				else
					waitingNotice = false
					local car, seat = myCar()
					Condition.update(car)
					local mode = Arsenic.Values.SelfDriveMode
					local choice = Arsenic.Values.SelfDriveDestination
					local roam = false
					if mode == "Slide Mode" and not Condition.retreat() then
						local target = slideTarget(seat.Position)
						if target then
							noTargetNotice = false
							chase(target, active)
						else
							if not noTargetNotice then
								noTargetNotice = true
								notify("Slide Mode: no player in a vehicle to chase. Pick one in the Players tab.")
							end
							task.wait(1)
						end
					elseif mode ~= "Slide Mode" and choice == FOLLOW_PLAYER then
						local target = getSelectedPlayer()
						if target then
							noTargetNotice = false
							followPlayer(target, active)
						else
							if not noTargetNotice then
								noTargetNotice = true
								notify("Follow: select a player in the Players tab first.")
							end
							task.wait(1)
						end
					elseif mode ~= "Slide Mode" and choice == TAXI_PLAYER then
						local target = getSelectedPlayer()
						if target then
							noTargetNotice = false
							taxiPlayer(target, active)
							if active() and Arsenic.Values.SelfDriveDestination == TAXI_PLAYER then
								finished = true
							end
						else
							if not noTargetNotice then
								noTargetNotice = true
								notify("Taxi: select a player in the Players tab first.")
							end
							task.wait(1)
						end
					elseif mode ~= "Slide Mode" and choice ~= DRIVE_AROUND then
						local destination = findLocation(choice)
						if not destination then
							notify("Choose a destination first.")
							finished = true
						else
							-- Retarget live when the dropdown changes; abort into the outer loop for
							-- Drive Around / Follow / Taxi / Slide so those modes take over.
							local trip = { name = choice }
							local arrived, reason = driveTo(destination, active, {
								liveDestination = function()
									local now = Arsenic.Values.SelfDriveDestination
									if now == trip.name then
										return nil
									end
									if Arsenic.Values.SelfDriveMode == "Slide Mode"
										or now == DRIVE_AROUND
										or now == FOLLOW_PLAYER
										or now == TAXI_PLAYER then
										return false
									end
									local nextDest = findLocation(now)
									if not nextDest then
										return false
									end
									trip.name = now
									return nextDest
								end,
							})
							if arrived then
								notify("Arrived at " .. trip.name .. ".")
								finished = true
							elseif reason == "destination_changed" or reason == "stop" then
								failures = 0
							elseif active() then
								notify(("Could not drive to %s: %s."):format(trip.name, reason or "the drive was interrupted"))
								finished = true
							end
						end
					else
						roam = true
					end
					if roam then
						local first = roamTarget(seat.Position, "end")
						if not first then
							finished = true
						else
							local _, reason = driveTo(CFrame.new(first), active, {
								keepRolling = true,
								nextTarget = roamTarget,
								retargetEvery = ESCAPE_REPLAN,
								visit = recordVisit,
								liveDestination = function()
									if Arsenic.Values.SelfDriveDestination ~= DRIVE_AROUND then
										return false
									end
									if Arsenic.Values.SelfDriveMode == "Slide Mode" and not Condition.retreat() then
										return false
									end
									return nil
								end,
							})
							if reason == "stop" or reason == "destination_changed" or not reason then
								failures = 0
							elseif active() then
								failures += 1
								if failures >= 5 or reason == "no roads were found on the map" or reason == "your car is not near a road" then
									notify("Self Driving stopped: " .. reason .. ".")
									finished = true
								end
							end
						end
					end
				end
				-- Every pass yields at least a frame, even when a drive ends straight away.
				RunService.Heartbeat:Wait()
			end
			if finished and driveGeneration == generation then
				stopSelfDriving()
			end
		end,
		disable = function()
			driveGeneration += 1
			clearDriveDebug()
		end,
	}
end)()

--------------------------------------------------------------------------------
-- Character lifecycle
--------------------------------------------------------------------------------

local characterConnections = {}

local function onCharacterAdded(character)
	for _, connection in ipairs(characterConnections) do
		connection:Disconnect()
	end
	table.clear(characterConnections)
	table.clear(noclipParts)

	table.insert(characterConnections, character.DescendantAdded:Connect(function(descendant)
		if on("NoKnockback") and isKnockbackMover(descendant) then
			task.defer(function()
				if descendant.Parent then
					descendant:Destroy()
				end
			end)
		end
	end))

	task.spawn(function()
		local humanoid = character:WaitForChild("Humanoid", 15)
		local root = character:WaitForChild("HumanoidRootPart", 15)
		if not (humanoid and root) or Arsenic.Destroyed then
			return
		end

		table.insert(characterConnections, humanoid.Died:Connect(function()
			onDied(character, humanoid)
		end))

		local death = lastDeath
		lastDeath = nil
		if on("RespawnWhereDied") and death and os.clock() - death.time < 300 then
			task.wait(0.5)
			for _ = 1, 3 do
				if not character.Parent or humanoid.Health <= 0 then
					break
				end
				character:PivotTo(death.cframe)
				root.AssemblyLinearVelocity = Vector3.zero
				task.wait(0.25)
			end
		end
	end)
end

track(LocalPlayer.CharacterAdded:Connect(onCharacterAdded))
if LocalPlayer.Character then
	onCharacterAdded(LocalPlayer.Character)
end

--------------------------------------------------------------------------------
-- Maintenance loop
--------------------------------------------------------------------------------

task.spawn(function()
	local lastCarSweep = 0
	while not Arsenic.Destroyed do
		local character = getCharacter()

		if on("NoSleep") and gameShared and not gameShared.Sleeping then
			if (gameShared.Wokeness or 100) < 100 then
				gameShared.Wokeness = 100
			end
		end

		if on("NoHunger") then
			local hungerScript = findPlayerGuiScript("Hunger", "HungerBarScript")
			suppressScript(hungerScript, "NoHunger")
			fillBar(hungerScript)
		end

		if on("InfiniteStamina") then
			local staminaScript = findPlayerGuiScript("Run", "StaminaBarScript")
			suppressScript(staminaScript, "InfiniteStamina")
			fillBar(staminaScript)
		end

		if on("NoFallDamage") and character then
			suppressScript(character:FindFirstChild("FallDamageRagdoll"), "NoFallDamage")
		end

		if on("NoCameraBob") and character then
			suppressScript(character:FindFirstChild("CameraBobbing"), "NoCameraBob")
			resetCameraOffset()
		end

		if on("AutoPickupBags") then
			scanPickups()
		end

		if on("UnlockAllCars") and os.clock() - lastCarSweep > 1 then
			lastCarSweep = os.clock()
			enableCarPrompts()
		end

		if anyGunModOn() then
			updateGunMods()
		end

		if on("InfiniteAmmo") then
			local tool = character and character:FindFirstChildOfClass("Tool")
			if isGun(tool) then
				if tool ~= lastAmmoTool and refillGun(tool) then
					lastAmmoTool = tool
				end
			else
				lastAmmoTool = nil
			end
		end

		if on("Spectate") then
			updateSpectate()
		end

		task.wait(0.25)
	end
end)

--------------------------------------------------------------------------------
-- Prison
--------------------------------------------------------------------------------

;(function()
	local Teams = game:GetService("Teams")
	-- Yard / cell block around the Tha Bronx 3 prison.
	local PRISON_CENTER = Vector3.new(-1100, 260, -3340)
	local PRISON_RADIUS = 300

	local barrierState = setmetatable({}, { __mode = "k" })
	local doorState = setmetatable({}, { __mode = "k" })
	local zoneState = setmetatable({}, { __mode = "k" })
	local prisonConnections = {}
	local teamSpoofConnection = nil
	local savedTeam = nil

	local function inPrisonArea(position)
		local offset = Vector3.new(position.X - PRISON_CENTER.X, 0, position.Z - PRISON_CENTER.Z)
		return offset.Magnitude <= PRISON_RADIUS and position.Y > 230 and position.Y < 330
	end

	local function disconnectPrison()
		for _, connection in ipairs(prisonConnections) do
			connection:Disconnect()
		end
		table.clear(prisonConnections)
	end

	local function trackPrison(connection)
		table.insert(prisonConnections, connection)
		table.insert(Arsenic.Connections, connection)
		return connection
	end

	local function isThinInvisibleWall(part)
		if not (part:IsA("BasePart") and part.CanCollide and inPrisonArea(part.Position)) then
			return false
		end
		if part.Name == "PrisonDoor" or part.Name == "PrisonGate" then
			return false
		end
		local size = part.Size
		local thin = math.min(size.X, size.Y, size.Z)
		local tall = math.max(size.X, size.Y, size.Z)
		if thin > 0.25 or tall < 3.5 then
			return false
		end
		local name = part.Name:lower()
		return part.Transparency >= 0.45
			or not part.CanQuery
			or name:find("barrier", 1, true) ~= nil
			or name:find("invisible", 1, true) ~= nil
			or name:find("wa3", 1, true) ~= nil
			or name == "conc3"
			or name == "glass"
	end

	local function isCellDoor(part)
		if not part:IsA("BasePart") then
			return false
		end
		local name = part.Name
		if name == "PrisonDoor" then
			return true
		end
		-- Gate model leaves / bars that block cells and the yard exit.
		if name == "PrisonGate" or (part.Parent and part.Parent.Name == "PrisonGate") then
			return part.CanCollide
		end
		return false
	end

	local function isEscapeZone(part)
		if not part:IsA("BasePart") then
			return false
		end
		local name = part.Name
		if not inPrisonArea(part.Position) and name ~= "PrisZone" and name ~= "PrisZone2" then
			return false
		end
		return name == "PrisZone"
			or name == "PrisZone2"
			or name == "JailTP"
			or name == "ReleaseJ"
			or name == "TeleportBack"
			or name == "ZoneVic"
			or name:lower():find("priszone", 1, true) ~= nil
			or name:lower():find("jailtp", 1, true) ~= nil
	end

	local function applyBarrier(part)
		if barrierState[part] or not isThinInvisibleWall(part) then
			return
		end
		barrierState[part] = { part.CanCollide, part.CanQuery }
		part.CanCollide = false
		part.CanQuery = false
	end

	local function restoreBarriers()
		for part, state in pairs(barrierState) do
			if part.Parent then
				part.CanCollide = state[1]
				part.CanQuery = state[2]
			end
			barrierState[part] = nil
		end
	end

	local function applyDoor(part)
		if not isCellDoor(part) then
			return
		end
		if not doorState[part] then
			doorState[part] = { part.CanCollide, part.CanTouch }
		end
		part.CanCollide = false
		part.CanTouch = false
	end

	local function restoreDoors()
		for part, state in pairs(doorState) do
			if part.Parent then
				part.CanCollide = state[1]
				part.CanTouch = state[2]
			end
			doorState[part] = nil
		end
	end

	local function muteZone(part)
		if zoneState[part] or not isEscapeZone(part) then
			return
		end
		zoneState[part] = { part.CanTouch, part.CanQuery }
		part.CanTouch = false
		part.CanQuery = false
		for _, child in ipairs(part:GetChildren()) do
			if child:IsA("TouchTransmitter") then
				pcall(function()
					child:Destroy()
				end)
			end
		end
		if getconnections then
			pcall(function()
				for _, connection in ipairs(getconnections(part.Touched)) do
					pcall(function()
						connection:Disable()
					end)
				end
			end)
		end
	end

	local function restoreZones()
		for part, state in pairs(zoneState) do
			if part.Parent then
				part.CanTouch = state[1]
				part.CanQuery = state[2]
			end
			zoneState[part] = nil
		end
	end

	local function scanPrisonMap(handler)
		local map = Workspace:FindFirstChild("1# Map") or Workspace
		for _, descendant in ipairs(map:GetDescendants()) do
			handler(descendant)
		end
	end

	local function doorsWanted()
		return on("DisablePrisonDoorTimer") or on("DisableCellDoorCollisions")
	end

	local function refreshPrisonParts()
		if on("DisablePrisonBarriers") then
			scanPrisonMap(applyBarrier)
		end
		if doorsWanted() then
			scanPrisonMap(applyDoor)
		end
		if on("DisablePrisonEscapeDetection") then
			scanPrisonMap(muteZone)
		end
	end

	local function ensurePrisonHeartbeat()
		if prisonConnections.heartbeat then
			return
		end
		prisonConnections.heartbeat = true
		trackPrison(RunService.Heartbeat:Connect(function()
			if Arsenic.Destroyed then
				return
			end
			if not (on("DisablePrisonBarriers") or doorsWanted() or on("DisablePrisonEscapeDetection")) then
				return
			end
			-- Timers / zone scripts re-enable collisions; keep ours off while toggles are on.
			if on("DisablePrisonBarriers") then
				for part in pairs(barrierState) do
					if part.Parent and part.CanCollide then
						part.CanCollide = false
					end
				end
			end
			if doorsWanted() then
				for part in pairs(doorState) do
					if part.Parent then
						if part.CanCollide then
							part.CanCollide = false
						end
						if part.CanTouch then
							part.CanTouch = false
						end
					end
				end
				-- Catch doors streamed in / reset by the timer.
				scanPrisonMap(applyDoor)
			end
			if on("DisablePrisonEscapeDetection") then
				for part in pairs(zoneState) do
					if part.Parent and part.CanTouch then
						part.CanTouch = false
					end
				end
			end
		end))
		trackPrison(Workspace.DescendantAdded:Connect(function(descendant)
			if Arsenic.Destroyed then
				return
			end
			task.defer(function()
				if on("DisablePrisonBarriers") then
					applyBarrier(descendant)
				end
				if doorsWanted() then
					applyDoor(descendant)
				end
				if on("DisablePrisonEscapeDetection") then
					muteZone(descendant)
				end
			end)
		end))
	end

	Features.DisablePrisonBarriers = {
		enable = function()
			ensurePrisonHeartbeat()
			refreshPrisonParts()
		end,
		disable = function()
			restoreBarriers()
			if not (doorsWanted() or on("DisablePrisonEscapeDetection")) then
				disconnectPrison()
				prisonConnections.heartbeat = nil
			end
		end,
	}

	Features.DisablePrisonDoorTimer = {
		enable = function()
			ensurePrisonHeartbeat()
			refreshPrisonParts()
		end,
		disable = function()
			if not on("DisableCellDoorCollisions") then
				restoreDoors()
			end
			if not (on("DisablePrisonBarriers") or on("DisableCellDoorCollisions") or on("DisablePrisonEscapeDetection")) then
				disconnectPrison()
				prisonConnections.heartbeat = nil
			end
		end,
	}

	Features.DisableCellDoorCollisions = {
		enable = function()
			ensurePrisonHeartbeat()
			refreshPrisonParts()
		end,
		disable = function()
			if not on("DisablePrisonDoorTimer") then
				restoreDoors()
			end
			if not (on("DisablePrisonBarriers") or on("DisablePrisonDoorTimer") or on("DisablePrisonEscapeDetection")) then
				disconnectPrison()
				prisonConnections.heartbeat = nil
			end
		end,
	}

	Features.DisablePrisonEscapeDetection = {
		enable = function()
			ensurePrisonHeartbeat()
			refreshPrisonParts()
			notify("Prison escape detection muted locally. Server checks may still teleport you back.")
		end,
		disable = function()
			restoreZones()
			if not (on("DisablePrisonBarriers") or doorsWanted()) then
				disconnectPrison()
				prisonConnections.heartbeat = nil
			end
		end,
	}

	local function nonPrisonerTeam()
		for _, name in ipairs({ "Neutral", "Civilian", "Criminal", "Police", "EMS" }) do
			local team = Teams:FindFirstChild(name)
			if team then
				return team
			end
		end
		for _, team in ipairs(Teams:GetTeams()) do
			if not team.Name:lower():find("prison", 1, true) then
				return team
			end
		end
		return nil
	end

	Features.AllowPrisonPurchases = {
		enable = function()
			savedTeam = LocalPlayer.Team
			local target = nonPrisonerTeam()
			if target and LocalPlayer.Team and LocalPlayer.Team.Name:lower():find("prison", 1, true) then
				pcall(function()
					LocalPlayer.Team = target
				end)
			end
			if teamSpoofConnection then
				teamSpoofConnection:Disconnect()
			end
			teamSpoofConnection = track(RunService.Heartbeat:Connect(function()
				if not on("AllowPrisonPurchases") or Arsenic.Destroyed then
					return
				end
				local team = LocalPlayer.Team
				if team and team.Name:lower():find("prison", 1, true) then
					local spoof = nonPrisonerTeam()
					if spoof then
						pcall(function()
							LocalPlayer.Team = spoof
						end)
					end
				end
			end))
			-- Prison gun store UI is always valid for inmates; unlock other shop GUIs client-side.
			local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
			if playerGui then
				for _, name in ipairs({ "PrisonGun", "2CityGun", "NewShopGUI", "5TH SHOP" }) do
					local gui = playerGui:FindFirstChild(name)
					if gui then
						pcall(function()
							gui.Enabled = gui.Enabled
						end)
					end
				end
			end
			notify("Prison purchases: client team spoof on. Server may still block restricted items.")
		end,
		disable = function()
			if teamSpoofConnection then
				teamSpoofConnection:Disconnect()
				teamSpoofConnection = nil
			end
			if savedTeam and savedTeam.Parent then
				pcall(function()
					LocalPlayer.Team = savedTeam
				end)
			end
			savedTeam = nil
		end,
	}

	table.insert(Arsenic.Cleanup, function()
		restoreBarriers()
		restoreDoors()
		restoreZones()
		disconnectPrison()
		if teamSpoofConnection then
			teamSpoofConnection:Disconnect()
			teamSpoofConnection = nil
		end
	end)
end)()

--------------------------------------------------------------------------------
-- Feature toggling / teardown
--------------------------------------------------------------------------------

local function setFeature(feature, value)
	value = value == true
	if Arsenic.Enabled[feature] == value then
		return
	end
	Arsenic.Enabled[feature] = value
	local handlers = Features[feature]
	local handler = handlers and (value and handlers.enable or handlers.disable)
	if handler then
		task.spawn(handler)
	end
end

function Arsenic.Destroy()
	if Arsenic.Destroyed then
		return
	end
	for feature in pairs(Arsenic.Enabled) do
		setFeature(feature, false)
	end
	Arsenic.Destroyed = true
	for _, connection in ipairs(Arsenic.Connections) do
		connection:Disconnect()
	end
	for _, connection in ipairs(characterConnections) do
		connection:Disconnect()
	end
	table.clear(Arsenic.Connections)
	table.clear(characterConnections)
	for _, cleanup in ipairs(Arsenic.Cleanup) do
		pcall(cleanup)
	end
	table.clear(Arsenic.Cleanup)
	if Window then
		pcall(function()
			Window:Unload()
		end)
	end
	if genv.ArsenicTB3 == Arsenic then
		genv.ArsenicTB3 = nil
	end
end

--------------------------------------------------------------------------------
-- UI
--------------------------------------------------------------------------------

local RAYFIELD_URL = "https://sirius.menu/gen2"
local RAYFIELD_CACHE = "Arsenic/rayfield_gen2.lua"

local function runLibrary(source, origin)
	if type(source) ~= "string" or #source < 1000 then
		return nil, origin .. " was empty"
	end
	local chunk, compileError = loadstring(source)
	if not chunk then
		return nil, origin .. " did not compile: " .. tostring(compileError)
	end
	local ok, library = pcall(chunk)
	if not ok then
		return nil, origin .. " errored: " .. tostring(library)
	end
	if type(library) ~= "table" then
		return nil, origin .. " returned " .. typeof(library)
	end
	return library
end

-- The download fails now and then, so retry and fall back to the copy saved by the last good load.
local function loadRayfield()
	local reasons = {}
	for _ = 1, 3 do
		local ok, source = pcall(function()
			return game:HttpGet(RAYFIELD_URL)
		end)
		local library, reason
		if ok then
			library, reason = runLibrary(source, "download")
		else
			reason = "download failed: " .. tostring(source)
		end
		if library then
			if writefile then
				pcall(function()
					if makefolder and not (isfolder and isfolder("Arsenic")) then
						makefolder("Arsenic")
					end
					writefile(RAYFIELD_CACHE, source)
				end)
			end
			return library
		end
		table.insert(reasons, reason)
		task.wait(1)
	end
	if readfile and isfile then
		local ok, source = pcall(function()
			return isfile(RAYFIELD_CACHE) and readfile(RAYFIELD_CACHE) or nil
		end)
		if ok and source then
			local library, reason = runLibrary(source, "cached copy")
			if library then
				return library
			end
			table.insert(reasons, reason)
		end
	end
	return nil, table.concat(reasons, " | ")
end

local Rayfield, rayfieldError = loadRayfield()
if not Rayfield then
	warn("[Arsenic] Failed to load Rayfield Gen2: " .. tostring(rayfieldError))
	pcall(function()
		game:GetService("StarterGui"):SetCore("SendNotification", {
			Title = "Arsenic failed to load",
			Text = "Rayfield UI: " .. tostring(rayfieldError),
			Duration = 15,
		})
	end)
	Arsenic.Destroy()
	return
end

-- Own function scope: the main chunk is close to Luau's 200-register limit.
;(function()
	-- Lucide icons (single-image uploads, as used by the Fluent UI library).
	local ICONS = {
		user = "rbxassetid://10747373176",
		users = "rbxassetid://10747373426",
		crosshair = "rbxassetid://10709818534",
		cart = "rbxassetid://10734952479",
		mapPin = "rbxassetid://10734886004",
		map = "rbxassetid://10734886202",
		ghost = "rbxassetid://10723396107",
		rotateCcw = "rbxassetid://10734940376",
		rotateCw = "rbxassetid://10734940654",
		moon = "rbxassetid://10734897102",
		utensils = "rbxassetid://10747373821",
		battery = "rbxassetid://10709774206",
		pointer = "rbxassetid://10734929723",
		dollar = "rbxassetid://10723343958",
		unlock = "rbxassetid://10747366027",
		feather = "rbxassetid://10723354671",
		shield = "rbxassetid://10734951847",
		flag = "rbxassetid://10723375890",
		camera = "rbxassetid://10709789686",
		backpack = "rbxassetid://10709769841",
		refresh = "rbxassetid://10734933222",
		eye = "rbxassetid://10723346959",
		navigation = "rbxassetid://10734906744",
		navigation2 = "rbxassetid://10734906332",
		userX = "rbxassetid://10747372992",
		skull = "rbxassetid://10734962068",
		car = "rbxassetid://10709789810",
		list = "rbxassetid://10723433811",
		gauge = "rbxassetid://10723395708",
		ruler = "rbxassetid://10734941018",
		fastForward = "rbxassetid://10723354521",
		timer = "rbxassetid://10734984606",
		infinity = "rbxassetid://10723415766",
		wrench = "rbxassetid://10747383470",
		target = "rbxassetid://10734977012",
		repeatIcon = "rbxassetid://10734933966",
		move = "rbxassetid://10734900011",
		flame = "rbxassetid://10723376114",
		building = "rbxassetid://10709783051",
		package = "rbxassetid://10734909540",
		bag = "rbxassetid://10734952273",
		heartPulse = "rbxassetid://10723406795",
		soda = "rbxassetid://10709818763",
		banknote = "rbxassetid://10709770178",
		landmark = "rbxassetid://10723417608",
		coins = "rbxassetid://10709811110",
		wallet = "rbxassetid://10747376205",
		piggyBank = "rbxassetid://10734921935",
		download = "rbxassetid://10723344270",
		upload = "rbxassetid://10747366434",
		pencil = "rbxassetid://10734919691",
		droplets = "rbxassetid://10734883356",
		hand = "rbxassetid://10723405649",
		briefcase = "rbxassetid://10709782662",
		hammer = "rbxassetid://10723405360",
		mic = "rbxassetid://10734888864",
		brush = "rbxassetid://10709782758",
		truck = "rbxassetid://10747364031",
		chefHat = "rbxassetid://10709790757",
		trash = "rbxassetid://10747362241",
		recycle = "rbxassetid://10734932295",
		cloudLightning = "rbxassetid://10709805727",
		key = "rbxassetid://10723416652",
		shieldAlert = "rbxassetid://10734951173",
		scanFace = "rbxassetid://10734942198",
		highlighter = "rbxassetid://10723407192",
		userCheck = "rbxassetid://10747371901",
		heartHandshake = "rbxassetid://10723406480",
		activity = "rbxassetid://10709752035",
		type = "rbxassetid://10747364761",
		heart = "rbxassetid://10723406885",
		sword = "rbxassetid://10734975486",
		palette = "rbxassetid://10734910430",
		paintbrush = "rbxassetid://10734910187",
	}

	-- Rayfield Gen1's "Bloom" palette rebuilt as a Gen2 light theme.
	local BLOOM_THEME = {
		WindowColor = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 240, 245)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(250, 226, 235)),
		}),
		ShadowColor = Color3.fromRGB(200, 150, 168),
		LiveAnimation = false,
		ElementTransparency = 0,
		ElementStroke = Color3.fromRGB(240, 205, 218),
		ElementGradient = ColorSequence.new(Color3.fromRGB(255, 236, 242)),
		ElementStrokeGradient = ColorSequence.new(Color3.fromRGB(238, 200, 214), Color3.fromRGB(245, 214, 226)),
		ElementStrokeTransparency = 0.1,
		ElementStrokeHoverTransparency = 0,
		ElementStrokeHover = Color3.fromRGB(255, 140, 170),
		DarkToggleOverlay = false,
		TabColor = Color3.fromRGB(80, 40, 60),
		TabBackground = ColorSequence.new(Color3.fromRGB(255, 160, 188), Color3.fromRGB(240, 125, 162)),
		TabStroke = ColorSequence.new(Color3.fromRGB(255, 195, 214), Color3.fromRGB(240, 135, 168)),
		SliderBackground = Color3.fromRGB(245, 215, 226),
		SliderBackgroundHover = Color3.fromRGB(238, 203, 216),
		SliderProgress = ColorSequence.new(Color3.fromRGB(255, 150, 180), Color3.fromRGB(240, 120, 160)),
		SliderStroke = Color3.fromRGB(230, 190, 205),
		SliderHandle = Color3.fromRGB(90, 50, 70),
		AccentColor = Color3.fromRGB(255, 130, 170),
		AccentStroke = Color3.fromRGB(255, 182, 206),
		AccentGlow = 0.85,
		StatBackground = Color3.fromRGB(255, 245, 248),
		ToggleTrack = Color3.fromRGB(240, 205, 218),
		ToggleTrackTransparency = 0,
		ToggleKnobOffTransparency = 0.05,
		FieldBackground = Color3.fromRGB(248, 222, 232),
		FieldTransparency = 0,
		FieldGlow = Color3.fromRGB(200, 140, 165),
		PlaceholderColor = Color3.fromRGB(170, 120, 140),
		SurfaceStroke = Color3.fromRGB(235, 200, 214),
		NeutralButton = Color3.fromRGB(248, 222, 232),
		NeutralButtonHover = Color3.fromRGB(240, 208, 220),
		NeutralButtonStroke = Color3.fromRGB(255, 240, 245),
		ActionColor = Color3.fromRGB(110, 60, 85),
		TitlingColor = Color3.fromRGB(60, 30, 45),
		ContentColor = Color3.fromRGB(70, 40, 55),
		ElementTextHoverColor = Color3.fromRGB(40, 20, 30),
		DropdownHighlight = Color3.fromRGB(255, 130, 170),
		ErrorColor = Color3.fromRGB(200, 60, 55),
		ErrorStrokeColor = Color3.fromRGB(240, 80, 70),
	}

	Window = Rayfield:CreateWindow({
		name = "Arsenic",
		subtitle = "Tha Bronx 3",
		theme = BLOOM_THEME,
		sidebarLayout = true,
		configuration = {
			autoSave = true,
			autoLoad = true,
			fileName = "TheBronx3",
			folder = "Arsenic",
		},
	})

	local function findPlayerGui(name)
		local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
		return playerGui and playerGui:FindFirstChild(name) or nil
	end

	local function findSafeModel()
		for _, child in ipairs(Workspace:GetDescendants()) do
			if child:IsA("ProximityPrompt") and child.ActionText == "Open Safe" then
				local model = child:FindFirstAncestorOfClass("Model") or child.Parent
				if model then
					return model
				end
			end
		end
		return nil
	end

	local function fireClientOpen(remote, ...)
		local getConnections = genv.getconnections or genv.get_signal_cons
		if not (remote and getConnections) then
			return false
		end
		local ok, connections = pcall(getConnections, remote.OnClientEvent)
		if not (ok and type(connections) == "table") then
			return false
		end
		for _, connection in ipairs(connections) do
			if connection.Fire then
				pcall(connection.Fire, connection, ...)
			elseif connection.Function then
				pcall(connection.Function, ...)
			end
		end
		return #connections > 0
	end

	local function viewBackpackUI()
		if type(shared.OpenBackp) == "function" then
			pcall(shared.OpenBackp, true)
			notify("Opened backpack UI.")
			return
		end
		local gui = findPlayerGui("BACKPACK UI")
		if not gui then
			notify("Backpack UI is not loaded yet.")
			return
		end
		gui.Enabled = true
		local frame = gui:FindFirstChild("Gui")
		if frame then
			frame.Visible = true
		end
		local remote = ReplicatedStorage:FindFirstChild("BACKPACK_REMOTE")
		if remote and remote:IsA("RemoteEvent") then
			pcall(remote.FireServer, remote, "Update")
		end
		notify("Opened backpack UI.")
	end

	local function viewSafeUI()
		local inventory = ReplicatedStorage:FindFirstChild("Inventory")
		local safe = findSafeModel()
		if inventory and inventory:IsA("RemoteEvent") and fireClientOpen(inventory, "OpenInv", safe) then
			notify("Opened safe UI.")
			return
		end
		local gui = findPlayerGui("Inventory")
		if not gui then
			notify("Safe UI is not loaded yet.")
			return
		end
		local safeValue = gui:FindFirstChild("SafeModel", true)
		if safeValue and safeValue:IsA("ObjectValue") then
			safeValue.Value = safe
		end
		local background = gui:FindFirstChild("Background")
		if background then
			background.Visible = true
		end
		gui.Enabled = true
		notify(safe and "Opened safe UI." or "Opened safe UI (no nearby safe model found).")
	end

	local function viewTrunkUI()
		local gui = findPlayerGui("TRUNK STORAGE")
		if not gui then
			notify("Trunk UI is not loaded yet.")
			return
		end
		if type(shared.CloseSafe) == "function" then
			pcall(shared.CloseSafe)
		end
		if type(shared.CloseBackpack) == "function" then
			pcall(shared.CloseBackpack)
		end
		gui.Enabled = true
		local remote = ReplicatedStorage:FindFirstChild("TrunkStorage")
		if remote and remote:IsA("RemoteEvent") then
			pcall(remote.FireServer, remote, "GetData")
		end
		notify("Opened trunk UI.")
	end

	local MeTab = Window:CreateTab({ name = "Me", icon = ICONS.user })

	local meToggles = {
		{ "Noclip", "Noclip", "Walk through solid objects.", ICONS.ghost },
		{ "FastRespawn", "Fast Respawn", "Respawn quicker without waiting 30 seconds.", ICONS.rotateCcw },
		{ "NoSleep", "No Sleep", "Disables sleep.", ICONS.moon },
		{ "NoHunger", "No Hunger", "Disables hunger.", ICONS.utensils },
		{ "InfiniteStamina", "Infinite Stamina", "Disables stamina and lets you run forever.", ICONS.battery },
		{ "InstantInteract", "Instant Interact", "Skips interaction delay.", ICONS.pointer },
		{ "AutoPickupBags", "Auto Pickup Bags", "Auto picks up money bags off the ground.", ICONS.dollar },
		{ "UnlockAllCars", "Unlock All Cars", "Enter cars even if they are locked.", ICONS.unlock },
		{ "NoFallDamage", "Disable Fall Damage", "You will not take fall damage.", ICONS.feather },
		{
			"NoKnockback",
			"No Knockback",
			"You will not be knocked back when hit or shot. Prevents cheaters from using scripts to knock you back at high speed.",
			ICONS.shield,
		},
		{ "RespawnWhereDied", "Respawn Where You Died", "Respawn at the place you died at.", ICONS.flag },
		{ "NoCameraBob", "Disable Camera Bobbing", "Stops your camera from moving up/down when you move.", ICONS.camera },
		{ "AntiLoseItems", "Anti Lose Items", "You will not lose items on death. This is not going to always work.", ICONS.backpack },
		{ "AntiTaser", "Anti Taser", "When you are tased, you will be automatically teleported away to safety.", ICONS.cloudLightning },
		{ "AntiKick", "Anti Kick", "Prevents you from being kicked. May not always work as intended.", ICONS.shieldAlert },
	}

	for _, entry in ipairs(meToggles) do
		local feature, label, description = entry[1], entry[2], entry[3]
		MeTab:CreateToggle({
			name = label,
			description = description,
			icon = entry[4],
			flag = "Me_" .. feature,
			value = false,
			callback = function(value)
				setFeature(feature, value)
			end,
		})
	end

	MeTab:CreateButton({
		name = "View Backpack UI",
		description = "Open your backpack without having a physical backpack.",
		icon = ICONS.backpack,
		callback = viewBackpackUI,
	})
	MeTab:CreateButton({
		name = "View Safe UI",
		description = "Open your safe without being near a safe/owning a home.",
		icon = ICONS.package,
		callback = viewSafeUI,
	})
	MeTab:CreateButton({
		name = "View Trunk UI",
		description = "Open your trunk without being near your personal vehicle.",
		icon = ICONS.briefcase,
		callback = viewTrunkUI,
	})

	-- Prison -----------------------------------------------------------------------

	local PrisonTab = Window:CreateTab({ name = "Prison", icon = ICONS.building })

	local prisonToggles = {
		{
			"DisablePrisonBarriers",
			"Disable Prison Invisible Barriers",
			"Disables the invisible walls placed around the prison.",
			ICONS.ghost,
		},
		{
			"DisablePrisonDoorTimer",
			"Disable Prison Door Timer",
			"Allows you to go through your prison cell doors without waiting for the timer. This can also be done with noclip.",
			ICONS.timer,
		},
		{
			"DisableCellDoorCollisions",
			"Disable Cell Door Collisions",
			"Allows you to enter other people's cells.",
			ICONS.unlock,
		},
		{
			"DisablePrisonEscapeDetection",
			"Disable Prison Escape Detection",
			"Allows you to exit the prison without being teleported back by anticheat. May not always work if the server enforces it.",
			ICONS.shieldAlert,
		},
		{
			"AllowPrisonPurchases",
			"Allow Purchasing Items as Prisoner",
			"Allows you to purchase weapons and other restricted items as a prisoner. May not always work if the server blocks it.",
			ICONS.cart,
		},
	}

	for _, entry in ipairs(prisonToggles) do
		local feature, label, description = entry[1], entry[2], entry[3]
		PrisonTab:CreateToggle({
			name = label,
			description = description,
			icon = entry[4],
			flag = "Prison_" .. feature,
			value = false,
			callback = function(value)
				setFeature(feature, value)
			end,
		})
	end

	-- Shared with Autofarms; both toggles drive the same feature and stay in sync.
	local janitorToggles = {}
	local function createJanitorToggle(tab, flagPrefix)
		local toggle
		toggle = tab:CreateToggle({
			name = "Autofarm Janitor Job",
			description = "Arsenic will do the janitor job for you (you must be in prison).",
			icon = ICONS.brush,
			flag = flagPrefix .. "_AutoJanitor",
			forgetState = true,
			value = false,
			callback = function(value)
				setFeature("AutoJanitor", value)
				for _, other in ipairs(janitorToggles) do
					if other ~= toggle then
						pcall(function()
							other:Set(value, true)
						end)
					end
				end
			end,
		})
		table.insert(janitorToggles, toggle)
		return toggle
	end

	PrisonTab:CreateSection({ name = "Jobs", icon = ICONS.briefcase })
	createJanitorToggle(PrisonTab, "Prison")

	-- ESP --------------------------------------------------------------------------

	local EspTab = Window:CreateTab({ name = "ESP", icon = ICONS.eye })

	local espToggles = {
		{ "ESP", "ESP", "See players through walls.", ICONS.eye },
		{ "HighlightESP", "Highlight ESP", "Highlights players with a color.", ICONS.highlighter },
		{ "FriendESP", "Friend ESP", "Enable ESP on your friends.", ICONS.userCheck },
		{ "FriendHighlightESP", "Friend Highlight ESP", "Outlines friends with a color.", ICONS.heartHandshake },
		{ "Tracers", "Tracers", "Show lines at the bottom of the screen pointing to locations of players.", ICONS.activity },
		{ "ESPNames", "Show Player Names", "Shows player names above player model.", ICONS.type },
		{ "ESPHealth", "Show Player Health", "Shows player health to the left of the player model.", ICONS.heart },
		{
			"ESPDistance",
			"Show Player Distance",
			"Shows player distance in studs above player model (shown to the right of player name if enabled).",
			ICONS.ruler,
		},
		{ "ESPItem", "Show Player Equipped Item", "Shows player's current equipped item/weapon name under player model.", ICONS.sword },
	}

	for _, entry in ipairs(espToggles) do
		local feature = entry[1]
		EspTab:CreateToggle({
			name = entry[2],
			description = entry[3],
			icon = entry[4],
			flag = "ESP_" .. feature,
			value = false,
			callback = function(value)
				setFeature(feature, value)
			end,
		})
	end

	EspTab:CreateInput({
		name = "Max Stud Radius",
		description = "The radius in studs that ESP will track. Anything higher than this radius will not appear on ESP. Leave empty or 0 for no limit.",
		icon = ICONS.ruler,
		flag = "ESP_MaxStudRadius",
		placeholder = "0",
		numeric = true,
		callback = function(text)
			local radius = tonumber(text)
			Arsenic.Values.ESPMaxRadius = radius and math.max(radius, 0) or 0
		end,
	})

	local function colorOption(valueName, label, color)
		Arsenic.Values[valueName] = color
		EspTab:CreateColorPicker({
			name = label,
			icon = ICONS.palette,
			flag = "ESP_" .. valueName,
			color = color,
			callback = function(value)
				if typeof(value) == "Color3" then
					Arsenic.Values[valueName] = value
				end
			end,
		})
		EspTab:CreateToggle({
			name = "Rainbow " .. label,
			description = "Cycles the " .. label:lower() .. " through every color.",
			icon = ICONS.paintbrush,
			flag = "ESP_Rainbow" .. valueName,
			value = false,
			callback = function(value)
				setFeature("Rainbow" .. valueName, value)
			end,
		})
	end

	colorOption("HighlightColor", "Highlight Color", Color3.fromRGB(255, 0, 0))
	colorOption("FriendHighlightColor", "Friend Highlight Color", Color3.fromRGB(0, 255, 0))
	colorOption("TracerColor", "Tracer Color", Color3.fromRGB(255, 255, 255))

	-- Players ----------------------------------------------------------------------

	local PlayersTab = Window:CreateTab({ name = "Players", icon = ICONS.users })

	local labelToName = {}

	local function playerLabel(player)
		if player.DisplayName ~= player.Name then
			return ("%s (@%s)"):format(player.DisplayName, player.Name)
		end
		return player.Name
	end

	local function buildPlayerOptions()
		table.clear(labelToName)
		local options = {}
		for _, player in ipairs(Players:GetPlayers()) do
			if player ~= LocalPlayer then
				local label = playerLabel(player)
				labelToName[label] = player.Name
				table.insert(options, label)
			end
		end
		table.sort(options, function(a, b)
			return a:lower() < b:lower()
		end)
		return options
	end

	local previewText, previewImage

	local function updatePreview(player)
		if not previewText then
			return
		end
		if not player then
			previewText:SetTitle("No player selected")
			previewText:Set("Pick a player above to see their avatar.")
			if previewImage then
				previewImage.Visible = false
			end
			return
		end
		previewText:SetTitle(playerLabel(player))
		previewText:Set(("@%s  •  UserId %d  •  Account age %d days"):format(player.Name, player.UserId, player.AccountAge))
		if previewImage then
			previewImage.Image = ("rbxthumb://type=Avatar&id=%d&w=150&h=150"):format(player.UserId)
			previewImage.Visible = true
		end
	end

	local function selectPlayer(label)
		if type(label) == "table" then
			label = label[1]
		end
		selectedPlayerName = label and labelToName[label] or nil
		updatePreview(getSelectedPlayer())
		if on("Spectate") then
			updateSpectate()
		end
	end

	local playerDropdown = PlayersTab:CreateDropdown({
		name = "Select Player",
		description = "Choose the target player.",
		icon = ICONS.user,
		options = buildPlayerOptions(),
		forgetState = true,
		callback = selectPlayer,
	})

	local refreshPlayerList

	PlayersTab:CreateButton({
		name = "Refresh Players",
		description = "Reload the player list.",
		icon = ICONS.refresh,
		callback = function()
			if selectedPlayerName and not Players:FindFirstChild(selectedPlayerName) then
				selectedPlayerName = nil
				updatePreview(nil)
			end
			refreshPlayerList()
			notify(("Player list refreshed (%d players)."):format(math.max(#Players:GetPlayers() - 1, 0)))
		end,
	})

	previewText = PlayersTab:CreateText({
		name = "No player selected",
		text = "Pick a player above to see their avatar.",
	})

	if previewText and typeof(previewText.main) == "Instance" then
		previewImage = Instance.new("ImageLabel")
		previewImage.Name = "AvatarPreview"
		previewImage.Size = UDim2.fromOffset(120, 120)
		previewImage.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
		previewImage.BackgroundTransparency = 0.7
		previewImage.BorderSizePixel = 0
		previewImage.ScaleType = Enum.ScaleType.Fit
		previewImage.LayoutOrder = 3
		previewImage.Visible = false
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 10)
		corner.Parent = previewImage
		previewImage.Parent = previewText.main
	end

	refreshPlayerList = function()
		if playerDropdown then
			pcall(function()
				playerDropdown:Refresh(buildPlayerOptions())
			end)
		end
	end

	track(Players.PlayerAdded:Connect(refreshPlayerList))
	track(Players.PlayerRemoving:Connect(function(player)
		if player.Name == selectedPlayerName then
			selectedPlayerName = nil
			updatePreview(nil)
		end
		task.defer(refreshPlayerList)
	end))

	PlayersTab:CreateToggle({
		name = "Spectate Player",
		description = "Spectate the target player.",
		icon = ICONS.eye,
		value = false,
		forgetState = true,
		callback = function(value)
			setFeature("Spectate", value)
		end,
	})

	local playerActions = {
		{ "Teleport To Player", "Teleport to the target player.", teleportToPlayer, ICONS.navigation },
		{ "Ragdoll Player", "Will make the target player fall on command.", ragdollPlayer, ICONS.userX },
		{ "Kill Player", "Will shoot the target player in the head with your equipped weapon.", killPlayer, ICONS.skull },
		{ "Spawn Cars on Player", "Spawn cars on top of the target player.", spawnCarsOnPlayer, ICONS.car },
	}

	for _, entry in ipairs(playerActions) do
		local action = entry[3]
		PlayersTab:CreateButton({
			name = entry[1],
			description = entry[2],
			icon = entry[4],
			callback = function()
				runPlayerAction(action)
			end,
		})
	end

	PlayersTab:CreateDropdown({
		name = "Spawn Car Method",
		description = "Owned Cars: Opens dealership UI and auto spawns a vehicle at your location, then moves it on top of the target player. "
			.. "All Cars: Teleports you inside of other players cars, then puts that car on top of the target player.",
		icon = ICONS.list,
		options = { "Owned Cars", "All Cars" },
		value = "Owned Cars",
		flag = "Players_SpawnCarMethod",
		callback = function(selection)
			if type(selection) == "table" then
				selection = selection[1]
			end
			spawnCarMethod = selection == "All Cars" and "All Cars" or "Owned Cars"
		end,
	})

	PlayersTab:CreateDropdown({
		name = "Teleport Method",
		description = "Vehicle: hops into the nearest free car, drives it to the destination, drops you off and sends the car back. "
			.. "Car + Tween: drives most of the way, gets out, then glides the last stretch on foot. "
			.. "Tween: glides you there on foot, but the game may pull you back. "
			.. "Instant: jumps straight there, but the game usually teleports you back.",
		icon = ICONS.navigation2,
		options = { "Vehicle", "Car + Tween", "Tween", "Instant" },
		value = "Vehicle",
		flag = "Players_TeleportMethodV2",
		callback = function(selection)
			if type(selection) == "table" then
				selection = selection[1]
			end
			if selection == "Instant" or selection == "Tween" or selection == "Car + Tween" then
				teleportMethod = selection
			else
				teleportMethod = "Vehicle"
			end
		end,
	})

	teleportSpeedSlider = PlayersTab:CreateSlider({
		name = "Teleport Speed",
		description = "Top speed of Tween teleports (and the on-foot part of Car + Tween). Too slow gets you kicked for flying; "
			.. "too fast gets you pulled back. Drops automatically if the game pulls you back.",
		icon = ICONS.gauge,
		range = { MIN_TELEPORT_SPEED, 6000 },
		increment = 50,
		value = Arsenic.Values.TeleportSpeed,
		suffix = " studs/s",
		flag = "Players_TeleportSpeedV5",
		callback = function(value)
			Arsenic.Values.TeleportSpeed = value
		end,
	})

	PlayersTab:CreateSlider({
		name = "Tween After Car",
		description = "Car + Tween only: how many studs before the destination you get out of the car and start gliding. "
			.. "Shorter trips skip the drive and glide the whole way after sitting in the car.",
		icon = ICONS.ruler,
		range = { 0, 2000 },
		increment = 10,
		value = Arsenic.Values.TweenAfterCar,
		suffix = " studs",
		flag = "Players_TweenAfterCar",
		callback = function(value)
			Arsenic.Values.TweenAfterCar = value
		end,
	})

	PlayersTab:CreateSlider({
		name = "Car Teleport Speed",
		description = "How fast the car travels during Vehicle teleports. Lower it if the car gets pulled back on the way.",
		icon = ICONS.fastForward,
		range = { 500, 10000 },
		increment = 100,
		value = Arsenic.Values.CarTeleportSpeed,
		suffix = " studs/s",
		flag = "Players_CarTeleportSpeed",
		callback = function(value)
			Arsenic.Values.CarTeleportSpeed = value
		end,
	})

	PlayersTab:CreateSlider({
		name = "Car Exit Delay",
		description = "How long Vehicle teleports wait in the car at the destination before getting out. "
			.. "Raise it if the game still pulls you back after arriving.",
		icon = ICONS.timer,
		range = { 0, 3 },
		increment = 0.05,
		value = Arsenic.Values.CarExitDelay,
		suffix = "s",
		flag = "Players_CarExitDelay",
		callback = function(value)
			Arsenic.Values.CarExitDelay = value
		end,
	})

	-- Weapons ----------------------------------------------------------------------

	local WeaponsTab = Window:CreateTab({ name = "Weapons", icon = ICONS.crosshair })

	local function weaponToggle(feature, label, description, icon)
		WeaponsTab:CreateToggle({
			name = label,
			description = description,
			icon = icon,
			flag = "Weapons_" .. feature,
			value = false,
			callback = function(value)
				setFeature(feature, value)
			end,
		})
	end

	weaponToggle(
		"InfiniteAmmo",
		"Infinite Ammo",
		"Your gun will get 9999 bullets. Unequip and equip weapon again for it to apply.",
		ICONS.infinity
	)
	weaponToggle("NoGunJam", "Disable Gun Jamming", "Guns will not be able to jam.", ICONS.wrench)
	weaponToggle("NoSpread", "No Bullet Spread", "Gun bullets will always go exactly where you're aiming.", ICONS.target)
	weaponToggle("AutoGun", "Make Gun Automatic", "Makes weapons shoot without clicking.", ICONS.repeatIcon)
	weaponToggle("NoRecoil", "No Recoil", "Removes kick from guns.", ICONS.move)

	weaponToggle("CustomFireRate", "Change Fire Rate", "Enable changing weapon fire rate.", ICONS.flame)
	WeaponsTab:CreateSlider({
		name = "Fire Rate",
		description = "Change weapon firerate. Lower is faster.",
		icon = ICONS.gauge,
		range = { 0.01, 1 },
		increment = 0.01,
		value = Arsenic.Values.FireRate,
		suffix = "s",
		flag = "Weapons_FireRateValue",
		callback = function(value)
			Arsenic.Values.FireRate = value
		end,
	})

	weaponToggle("CustomReloadSpeed", "Change Reload Speed", "Enable changing gun reload speed.", ICONS.rotateCw)
	WeaponsTab:CreateSlider({
		name = "Reload Speed",
		description = "Change gun reload speed. Lower is faster.",
		icon = ICONS.timer,
		range = { 0, 5 },
		increment = 0.1,
		value = Arsenic.Values.ReloadTime,
		suffix = "s",
		flag = "Weapons_ReloadSpeedValue",
		callback = function(value)
			Arsenic.Values.ReloadTime = value
		end,
	})

	-- Buy --------------------------------------------------------------------------

	local BuyTab = Window:CreateTab({ name = "Buy", icon = ICONS.cart })

	local storeNames = {}
	for _, store in ipairs(STORES) do
		table.insert(storeNames, store.name)
	end

	local storeDropdown
	storeDropdown = BuyTab:CreateDropdown({
		name = "Open Store UI",
		description = "Open store UIs like gunstore and dealership UIs and purchase without being at the physical location.",
		icon = ICONS.building,
		options = storeNames,
		forgetState = true,
		callback = function(selection)
			if type(selection) == "table" then
				selection = selection[1]
			end
			if type(selection) ~= "string" or selection == "" then
				return
			end
			openStoreUi(selection)
			-- Clear the pick so the same store can be opened again.
			task.defer(function()
				if storeDropdown then
					pcall(function()
						storeDropdown:Set({}, true)
					end)
				end
			end)
		end,
	})

	local selectedBuyItem = nil

	BuyTab:CreateDropdown({
		name = "Item",
		description = "Choose the weapon or item to buy.",
		icon = ICONS.package,
		options = getAllStoreItems(),
		forgetState = true,
		callback = function(selection)
			if type(selection) == "table" then
				selection = selection[1]
			end
			selectedBuyItem = (type(selection) == "string" and selection ~= "") and selection or nil
		end,
	})

	BuyTab:CreateButton({
		name = "Buy Item",
		description = "Buy a weapon or item from any shop, you will teleport there and the game will purchase the gun for you then teleport you back to where you were.",
		icon = ICONS.bag,
		callback = function()
			if not selectedBuyItem then
				notify("Choose an item first.")
				return
			end
			local item = selectedBuyItem
			runPlayerAction(function()
				buyItem(item)
			end)
		end,
	})

	BuyTab:CreateButton({
		name = "Buy Bandage",
		description = "Purchases a bandage. If it is out of stock, we will try every store until we find one that has the item in stock.",
		icon = ICONS.heartPulse,
		callback = function()
			runPlayerAction(function()
				buyItem("Bandage")
			end)
		end,
	})

	BuyTab:CreateButton({
		name = "Buy Lemonade",
		description = "Purchases lemonade. If it is out of stock, we will try every store until we find one that has the item in stock.",
		icon = ICONS.soda,
		callback = function()
			runPlayerAction(function()
				buyItem("Lemonade")
			end)
		end,
	})

	-- Money ------------------------------------------------------------------------

	local MoneyTab = Window:CreateTab({ name = "Money", icon = ICONS.dollar })

	local function moneyToggle(feature, label, description, icon)
		MoneyTab:CreateToggle({
			name = label,
			description = description,
			icon = icon,
			flag = "Money_" .. feature,
			-- Never saved: a saved automation would start travelling the moment the script runs.
			forgetState = true,
			value = false,
			callback = function(value)
				setFeature(feature, value)
			end,
		})
	end

	local function amountInput(valueName, label, description, icon)
		MoneyTab:CreateInput({
			name = label,
			description = description,
			icon = icon,
			flag = "Money_" .. valueName,
			placeholder = "Amount",
			numeric = true,
			callback = function(text)
				Arsenic.Values[valueName] = Money.parseAmount(text)
			end,
		})
	end

	MoneyTab:CreateSection({ name = "Cash", icon = ICONS.banknote })

	MoneyTab:CreateButton({
		name = "Infinite Money",
		description = "Buys Ice-Fruit ingredients, cooks them at a pot, and burst-sells the cup up to $990,000 dirty money.",
		icon = ICONS.infinity,
		callback = function()
			runPlayerAction(Money.infiniteMoney)
		end,
	})

	MoneyTab:CreateButton({
		name = "Auto Clean Money",
		description = "Teleports you to the laundromat, cleans your dirty money, cashes the bag in at the bank, then brings you back.",
		icon = ICONS.droplets,
		callback = function()
			runPlayerAction(Money.cleanMoney)
		end,
	})

	amountInput("DropAmount", "Drop Amount", "Amount of money to drop.", ICONS.pencil)

	MoneyTab:CreateButton({
		name = "Drop Money Amount",
		description = "Drops the selected amount of money.",
		icon = ICONS.download,
		callback = function()
			runPlayerAction(function()
				local amount = Arsenic.Values.DropAmount
				local ok, reason = Money.dropMoney(amount)
				notify(ok and ("Dropped " .. Money.formatCash(amount) .. ".") or ("Could not drop money: " .. tostring(reason) .. "."))
			end)
		end,
	})

	moneyToggle("AutoDropMoney", "Auto Drop Money", "Keeps dropping the Drop Amount on the ground (how money drops are done).", ICONS.coins)
	moneyToggle("AutoPickupCash", "Auto Pickup Cash", "Travels to cash piles on the ground and picks them up.", ICONS.hand)

	MoneyTab:CreateSection({ name = "Bank", icon = ICONS.landmark })

	moneyToggle("AutoDeposit", "Auto Deposit Money", "Deposits the Deposit Amount whenever your wallet has it (whole wallet if no amount is set).", ICONS.piggyBank)
	moneyToggle("AutoWithdraw", "Auto Withdraw Money", "Keeps your wallet topped up to the Withdraw Amount from the bank.", ICONS.wallet)
	amountInput("DepositAmount", "Deposit Amount", "Amount to deposit (leave empty for your whole wallet).", ICONS.pencil)
	amountInput("WithdrawAmount", "Withdraw Amount", "Amount to withdraw (leave empty for your whole bank).", ICONS.pencil)

	MoneyTab:CreateButton({
		name = "Deposit Selected Amount",
		description = "Deposits the Deposit Amount into the bank.",
		icon = ICONS.upload,
		callback = function()
			runPlayerAction(function()
				local before = Money.getStat("Bank")
				local ok, reason = Money.deposit(Arsenic.Values.DepositAmount)
				notify(ok and ("Deposited " .. Money.formatCash(Money.getStat("Bank") - before) .. ".") or ("Could not deposit: " .. tostring(reason) .. "."))
			end)
		end,
	})

	MoneyTab:CreateButton({
		name = "Withdraw Selected Amount",
		description = "Withdraws the Withdraw Amount to your wallet.",
		icon = ICONS.download,
		callback = function()
			runPlayerAction(function()
				local before = Money.getStat("Money")
				local ok, reason = Money.withdraw(Arsenic.Values.WithdrawAmount)
				notify(ok and ("Withdrew " .. Money.formatCash(Money.getStat("Money") - before) .. ".") or ("Could not withdraw: " .. tostring(reason) .. "."))
			end)
		end,
	})

	MoneyTab:CreateSection({ name = "Dupe", icon = ICONS.repeatIcon })

	moneyToggle(
		"AutoDupe",
		"Auto Dupe Held Item",
		"Market dupe on the held tool (list → store → remove → grab). Parks extras between attempts; turning off pulls them back. May take a few tries.",
		ICONS.infinity
	)

	MoneyTab:CreateButton({
		name = "Dupe Held Item",
		description = "One-shot market dupe (backpack → list → store → remove → grab). Equip the item first; retry if timing misses.",
		icon = ICONS.repeatIcon,
		callback = function()
			runPlayerAction(function()
				local tool = nil
				local character = getCharacter()
				if character then
					for _, child in ipairs(character:GetChildren()) do
						if child:IsA("Tool") and child.Name ~= "Fist" and child.Name ~= "Fists" and child.Name ~= "Phone" then
							tool = child
							break
						end
					end
				end
				if not tool then
					notify("Equip the item you want to dupe first.")
					return
				end
				local ok, reason, startingCount, endingCount = Money.dupeHeldItem()
				if ok then
					notify(("Duped %s (%d → %d)."):format(tool.Name, startingCount or "?", endingCount or "?"))
				else
					notify("Dupe failed: " .. tostring(reason) .. ".")
				end
			end)
		end,
	})

	-- Autofarms --------------------------------------------------------------------

	local AutofarmsTab = Window:CreateTab({ name = "Autofarms", icon = ICONS.briefcase })

	local function farmToggle(feature, label, description, icon)
		AutofarmsTab:CreateToggle({
			name = label,
			description = description,
			icon = icon,
			flag = "Autofarms_" .. feature,
			forgetState = true,
			value = false,
			callback = function(value)
				setFeature(feature, value)
			end,
		})
	end

	AutofarmsTab:CreateSection({ name = "Jobs", icon = ICONS.briefcase })

	farmToggle("AutoConstruction", "Autofarm Construction Job", "Arsenic will do the construction job for you.", ICONS.hammer)
	farmToggle("AutoStudio", "Autofarm Studio Job", "Arsenic will do the studio job for you (each session costs $15,000; don't move while recording).", ICONS.mic)
	createJanitorToggle(AutofarmsTab, "Autofarms")
	farmToggle("AutoDelivery", "Autofarm Delivery Job", "Arsenic will do the delivery job for you. Buys a Sledge Hammer if you don't have one.", ICONS.truck)
	farmToggle("AutoDeli", "Autofarm Deli Job", "Arsenic will do the deli job for you.", ICONS.chefHat)

	AutofarmsTab:CreateSection({ name = "Trash", icon = ICONS.trash })

	farmToggle("AutoFarmTrash", "Auto Farm Trash", "Travels to every lootable dumpster and searches it.", ICONS.trash)
	farmToggle("AutoSellTrash", "Auto Sell Trash", "Sells your trash at the pawn shop.", ICONS.recycle)

	-- Vehicle ----------------------------------------------------------------------

	-- Spots taken from the map's interaction prompts; the character stands at the prompt.
	local function spot(x, y, z)
		return CFrame.new(x, y, z)
	end

	local LOCATIONS = {
		{ "River Park Residence", CFrame.new(-1513.19531, 253.300781, -616.714844, 0.564782739, 5.50963293e-08, -0.825239658, -1.70484231e-08, 1, 5.50963293e-08, 0.825239658, -1.70484231e-08, 0.564782739) },
		{ "Hospital", CFrame.new(-1556.25317, 253.429688, 18.2620468, -0.865074635, -1.02409601e-07, -0.50164336, -5.89966724e-08, 1, -1.02409601e-07, 0.50164336, -5.8996644e-08, -0.865074635) },
		{ "Market", CFrame.new(-450.94809, 333.396973, -569.778809, -0.945302248, 0.00926982798, -0.32606408, 0.321737885, -0.138197899, -0.9366889, -0.0537443124, -0.990361273, 0.127656326) },
		{ "Dealership", CFrame.new(-407.908752, 253.414062, -1240.69507, 0.999694884, -1.45000068e-10, -0.0247044768, 1.41461107e-10, 1, -1.44999915e-10, 0.024704475, 1.41460926e-10, 0.999694884) },
		-- Street outside Enter Gunshop (SecondGun488); old point was by the dealership ATM.
		{ "Bottom Gun Store", spot(-1024.6, 254.6, -792.2) },
		{ "Tha Shop (Lemonade)", CFrame.new(-1517.44531, 270.507812, -982.417969, -0.807752788, -1.04788178e-07, -0.589521289, -5.32505808e-08, 0.999999821, -1.04788164e-07, 0.589521289, -5.32505808e-08, -0.807752669) },
		{ "Top Gun Store", CFrame.new(66191.5312, 123615.891, 5748.35449, 0.596415579, 1.74448385e-08, 0.802675784, -5.27273087e-08, 1, 1.74448438e-08, -0.802675784, -5.27273123e-08, 0.596415579) },
		{ "Prison", CFrame.new(-1217.25012, 253.890625, -3347.10059, -0.50353843, -1.03487203e-07, -0.863972962, -2.79563004e-08, 1, -1.03487217e-07, 0.863972962, -2.79562951e-08, -0.50353843) },
		{ "NYPD HQ", CFrame.new(-1410.04968, 253.79689, -3114.52246, -0.991480708, -8.13568093e-08, 0.130253822, -9.27439601e-08, 1, -8.13568093e-08, -0.130253822, -9.27439601e-08, -0.991480708) },
		{ "Soda Seller", CFrame.new(-1450.39062, 253.84375, -3423.10156, -0.110603355, -9.19892145e-08, -0.993864596, -5.10280529e-09, 0.999999881, -9.19892074e-08, 0.993864596, -5.10280529e-09, -0.11060334) },
		{ "Mansion (New City)", CFrame.new(-1491.25781, 463.539062, -3667.32031, 0.994074881, 4.49232118e-09, 0.108697444, -5.01031128e-09, 1, 4.49232074e-09, -0.108697444, -5.01031128e-09, 0.994074881) },
		{ "Free Car", CFrame.new(-1542.48657, 258.203125, -1175.37903, -0.566320121, -3.24294334e-08, 0.824185431, -1.04459062e-07, 1, -3.24293907e-08, -0.824185431, -1.04459041e-07, -0.566320121) },

		{ "Bank", spot(-1216.6, 254.4, -3630) },
		{ "Bank Vault", spot(-1151.4, 256.0, -3643.3) },
		{ "Pawn Shop", spot(-1049.5, 253.9, -807.6) },
		{ "Sell Stolen Items", spot(-1568.3, 259.0, -1174.5) },
		{ "Sell Car", spot(-1419.4, 254.0, 2785.7) },
		{ "Car Repair", spot(-1485.2, 253.6, -4100.6) },
		{ "Gas Station", spot(-449.6, 255.7, -267.5) },
		{ "Tattoo Shop", spot(-743.3, 254.1, -473.9) },
		{ "Drip Store", spot(-592.7, 255.2, -1005.2) },
		{ "Deli", spot(-383.3, 255.2, -295.6) },
		{ "Bandage Shop", spot(-352.6, 255.3, -418.7) },
		{ "5th Shop", spot(-1447.8, 255.7, 2190.6) },
		{ "City Gun Store", spot(-966.5, 260.6, -4260.1) },
		{ "Prison Gun Store", spot(-969.9, 253.7, -3406.9) },
		{ "Courthouse", spot(-1222.3, 254.9, -3326.0) },
		{ "Deli Job", spot(-750.6, 256.1, -707.4) },
		{ "Construction Job", spot(-1725.5, 370.7, -1171.3) },
		{ "Studio Job", spot(9.6, 285.7, -715.9) },
		{ "Janitor Job", spot(-1111.5, 253.8, -3379.0) },
		{ "Delivery Job", spot(-1012.9, 262.7, 54.8) },
		{ "Lemon Seller", spot(-1424.6, 252.8, 2032.4) },
		{ "Juice Seller", spot(28.6, 286.6, -341.6) },
		{ "Laptop Card Swipe", spot(-1000.6, 341.3, -261.7) },
		{ "Store Robbery", spot(-378.9, 254.1, -785.2) },
		{ "ATM Robbery", spot(-431.8, 253.8, -950.1) },
		{ "House Robbery", spot(-626.1, 255.9, -787.0) },
		{ "Sewer", spot(-777.9, 233.4, -521.3) },
		{ "Rooftop", spot(-1619.7, 411.9, -1230.2) },
	}

	local locationNames = {}
	local locationsByName = {}
	for _, entry in ipairs(LOCATIONS) do
		table.insert(locationNames, entry[1])
		locationsByName[entry[1]] = flatRotation(entry[2])
	end

	Vehicles.selfDriveLocations = LOCATIONS

	local VehicleTab = Window:CreateTab({ name = "Vehicle", icon = ICONS.car })

	VehicleTab:CreateToggle({
		name = "Fly Cars",
		description = "Allows you to fly with cars: W/S forward and back, A/D turn, Space/E up, Shift/Q down. This is currently mostly undetected unless you go extremely fast or jump out the car while you're high in the air.",
		icon = ICONS.feather,
		flag = "Vehicle_FlyCars",
		value = false,
		callback = function(value)
			setFeature("FlyCars", value)
		end,
	})

	VehicleTab:CreateInput({
		name = "Fly Speed",
		description = "Studs per second while flying (WASD to move, Space/E up, Shift/Q down).",
		icon = ICONS.gauge,
		flag = "Vehicle_FlySpeed",
		placeholder = "80",
		numeric = true,
		callback = function(text)
			local speed = tonumber(text)
			Arsenic.Values.FlySpeed = speed and speed > 0 and speed or 80
		end,
	})

	VehicleTab:CreateButton({
		name = "Get in Nearest Vehicle",
		description = "Teleports you to the nearest vehicle and puts you in the driver seat.",
		icon = ICONS.car,
		callback = function()
			task.spawn(getInNearestVehicle)
		end,
	})
	VehicleTab:CreateButton({
		name = "Bring Nearest Vehicle To Me",
		description = "Brings the nearest vehicle to your current location.",
		icon = ICONS.navigation,
		callback = function()
			task.spawn(bringNearestVehicle)
		end,
	})
	VehicleTab:CreateButton({
		name = "Refuel Vehicle",
		description = "Self driving will take your car to the nearest gas station, and Arsenic will handle refueling, then put you back in the car.",
		icon = ICONS.droplets,
		callback = function()
			runPlayerAction(function()
				local ok, reason = Vehicles.refuelVehicle()
				if ok then
					notify("Refueled and you're back in the car.")
				else
					notify("Could not refuel: " .. tostring(reason) .. ".")
				end
			end)
		end,
	})

	VehicleTab:CreateToggle({
		name = "Auto Strike Cars",
		description = "Buys the tools for your selected break-in mode, teleports to empty cars, breaks in, strikes with the StrikePad, then sells. The free car next to the lemonade dealer is excluded.",
		icon = ICONS.key,
		flag = "Vehicle_AutoStrikeCars",
		forgetState = true,
		value = false,
		callback = function(value)
			setFeature("AutoStrikeCars", value)
		end,
	})

	VehicleTab:CreateDropdown({
		name = "Auto Strike Break-In Mode",
		description = "Strikepad: StrikePad + Swiss Screw. Screw: regular Screw for break-in (automates the lockpick challenge) + StrikePad to strike/sell.",
		icon = ICONS.key,
		options = { "Strikepad", "Screw" },
		value = Arsenic.Values.StrikeBreakInMode,
		forgetState = true,
		callback = function(selection)
			if type(selection) == "table" then
				selection = selection[1]
			end
			if selection == "Strikepad" or selection == "Screw" then
				Arsenic.Values.StrikeBreakInMode = selection
			end
		end,
	})

	VehicleTab:CreateToggle({
		name = "Only Target Expensive Vehicles",
		description = "Auto Strike Cars will only target vehicles with high sell values and ignore those that are low. The free car next to lemonade dealer is already excluded as it has no sell value.",
		icon = ICONS.dollar,
		flag = "Vehicle_StrikeExpensiveOnly",
		value = false,
		callback = function(value)
			setFeature("StrikeExpensiveOnly", value)
		end,
	})

	Vehicles.selfDriveToggle = VehicleTab:CreateToggle({
		name = "Self Driving",
		description = "Arsenic will have your car self drive to a location. You can also choose to self drive around the map instead.",
		icon = ICONS.navigation,
		flag = "Vehicle_SelfDriving",
		forgetState = true,
		value = false,
		callback = function(value)
			setFeature("SelfDriving", value)
		end,
	})

	local selfDriveOptions = { "Drive Around Map", "Follow Selected Player", "Taxi Selected Player" }
	for _, name in ipairs(locationNames) do
		table.insert(selfDriveOptions, name)
	end
	VehicleTab:CreateDropdown({
		name = "Self Driving Destination",
		description = "Where Self Driving takes your car. Changing this while driving replans the route live. Follow/Taxi use the player selected in the Players tab (roadside pickup, never into buildings).",
		icon = ICONS.map,
		options = selfDriveOptions,
		forgetState = true,
		callback = function(selection)
			if type(selection) == "table" then
				selection = selection[1]
			end
			if type(selection) == "string" then
				Arsenic.Values.SelfDriveDestination = selection
			end
		end,
	})

	VehicleTab:CreateDropdown({
		name = "Taxi Drop-off",
		description = "Where Taxi Selected Player drives after the passenger gets in.",
		icon = ICONS.mapPin,
		options = locationNames,
		value = Arsenic.Values.TaxiDropOff,
		forgetState = true,
		callback = function(selection)
			if type(selection) == "table" then
				selection = selection[1]
			end
			if type(selection) == "string" then
				Arsenic.Values.TaxiDropOff = selection
			end
		end,
	})

	VehicleTab:CreateDropdown({
		name = "Driving Mode",
		description = "Civilian Mode drives normally. Chase Mode is faster and escapes threats. Slide Mode chases vehicles and drifts. Damage auto-switches to Chase (faster with more damage); shooting from the car auto-switches to Slide. Nearby players/cars also change speed and turning.",
		icon = ICONS.car,
		options = { "Civilian Mode", "Chase Mode", "Slide Mode" },
		forgetState = true,
		callback = function(selection)
			if type(selection) == "table" then
				selection = selection[1]
			end
			if type(selection) == "string" then
				Arsenic.Values.SelfDriveMode = selection
			end
		end,
	})

	local MIN_DRIVE_SPEED, MAX_DRIVE_SPEED, DRIVE_SPEED_STEP = 20, 350, 10
	local MIN_TURN, MAX_TURN, TURN_STEP = 0.4, 2.5, 1.15
	local function driveCommand(name, description, icon, apply)
		VehicleTab:CreateButton({
			name = name,
			description = description,
			icon = icon,
			callback = apply,
		})
	end
	local function setDriveSpeed(speed)
		Arsenic.Values.SelfDriveSpeed = math.clamp(speed, MIN_DRIVE_SPEED, MAX_DRIVE_SPEED)
		notify(("Self Driving top speed: %d studs/s."):format(Arsenic.Values.SelfDriveSpeed))
	end
	local function setTurnRate(rate)
		Arsenic.Values.SelfDriveTurn = math.clamp(rate, MIN_TURN, MAX_TURN)
		notify(("Self Driving turning: %d%%."):format(math.round(Arsenic.Values.SelfDriveTurn * 100)))
	end
	driveCommand("Drive Faster", "Raises Self Driving's top speed.", ICONS.gauge, function()
		setDriveSpeed(Arsenic.Values.SelfDriveSpeed + DRIVE_SPEED_STEP)
	end)
	driveCommand("Drive Slower", "Lowers Self Driving's top speed.", ICONS.gauge, function()
		setDriveSpeed(Arsenic.Values.SelfDriveSpeed - DRIVE_SPEED_STEP)
	end)
	driveCommand("Turn Faster", "Makes Self Driving steer harder and take corners quicker.", ICONS.navigation, function()
		setTurnRate(Arsenic.Values.SelfDriveTurn * TURN_STEP)
	end)
	driveCommand("Turn Slower", "Makes Self Driving steer gentler and take corners slower.", ICONS.navigation, function()
		setTurnRate(Arsenic.Values.SelfDriveTurn / TURN_STEP)
	end)

	VehicleTab:CreateToggle({
		name = "Debug Pathfinding",
		description = "Renders a line that shows the path of self-driving/pathfinding systems so you know exactly where Arsenic is taking you and how it is processing obstructions.",
		icon = ICONS.activity,
		flag = "Vehicle_DebugPathfinding",
		value = false,
		callback = function(value)
			setFeature("DebugPathfinding", value)
		end,
	})

	local vehicleDropdown = VehicleTab:CreateDropdown({
		name = "Vehicle Selector",
		description = "Select a vehicle from the list below. [D] = has driver, [P] = has passengers",
		icon = ICONS.list,
		options = Vehicles.buildOptions(),
		forgetState = true,
		callback = Vehicles.select,
	})

	local lastVehicleOptions = ""
	local function refreshVehicleList()
		local options = Vehicles.buildOptions()
		local signature = table.concat(options, "\n")
		if signature ~= lastVehicleOptions and vehicleDropdown then
			lastVehicleOptions = signature
			pcall(function()
				vehicleDropdown:Refresh(options)
			end)
		end
	end
	task.spawn(function()
		while not Arsenic.Destroyed do
			task.wait(3)
			pcall(refreshVehicleList)
		end
	end)

	VehicleTab:CreateToggle({
		name = "Spectate Vehicle",
		description = "Watch the vehicle without physically being near it.",
		icon = ICONS.eye,
		flag = "Vehicle_SpectateVehicle",
		forgetState = true,
		value = false,
		callback = function(value)
			setFeature("SpectateVehicle", value)
		end,
	})

	VehicleTab:CreateButton({
		name = "Teleport to Vehicle",
		description = "Teleport to the target vehicle.",
		icon = ICONS.mapPin,
		callback = function()
			runPlayerAction(Vehicles.teleportToSelected)
		end,
	})

	VehicleTab:CreateButton({
		name = "Strike Selected Vehicle",
		description = "Strike the selected vehicle; Arsenic will handle it for you.",
		icon = ICONS.key,
		callback = function()
			runPlayerAction(Vehicles.strikeSelected)
		end,
	})

	local function buyButton(item, description)
		VehicleTab:CreateButton({
			name = "Buy " .. item,
			description = description,
			icon = ICONS.cart,
			callback = function()
				runPlayerAction(function()
					buyItem(item)
				end)
			end,
		})
	end

	buyButton("StrikePad", "Buys a StrikePad at the City Gun Store.")
	buyButton("Swiss Screw", "Buys a Swiss Screw at the City Gun Store.")
	buyButton("Screw", "Buys a regular Screw for the Screw break-in mode (lockpick challenge is automated by Auto Strike).")

	-- Teleport ---------------------------------------------------------------------

	local TeleportTab = Window:CreateTab({ name = "Teleport", icon = ICONS.navigation })

	local selectedLocation = nil

	TeleportTab:CreateDropdown({
		name = "Location",
		description = "Choose a location, then press Teleport Now.",
		icon = ICONS.map,
		options = locationNames,
		forgetState = true,
		callback = function(selection)
			if type(selection) == "table" then
				selection = selection[1]
			end
			selectedLocation = (type(selection) == "string" and locationsByName[selection]) and selection or nil
		end,
	})

	TeleportTab:CreateButton({
		name = "Teleport Now",
		description = "Teleport to the selected location.",
		icon = ICONS.mapPin,
		callback = function()
			local name = selectedLocation
			if not name then
				notify("Choose a location first.")
				return
			end
			runPlayerAction(function()
				if not teleportCharacter(locationsByName[name]) then
					notify("Could not reach " .. name .. ".")
				end
			end)
		end,
	})

	-- Search field at the top of the sidebar, above the tab/section list.
	do
		local sidebar = Window.sidebar
		local tabList = Window.tabList
		if typeof(sidebar) == "Instance" and typeof(tabList) == "Instance" then
			local searchHeight = 32
			local padding = tabList:FindFirstChildOfClass("UIPadding")
			if padding then
				padding.PaddingTop = UDim.new(0, padding.PaddingTop.Offset + searchHeight + 6)
			end

			local bar = Instance.new("Frame")
			bar.Name = "ArsenicSidebarSearch"
			bar.BackgroundColor3 = Color3.fromRGB(248, 222, 232)
			bar.BackgroundTransparency = 0.08
			bar.BorderSizePixel = 0
			bar.AnchorPoint = Vector2.new(0.5, 0)
			bar.Position = UDim2.new(0.5, 0, 0, 4)
			bar.Size = UDim2.new(1, -20, 0, searchHeight)
			bar.ZIndex = 25
			bar.Parent = sidebar

			local corner = Instance.new("UICorner")
			corner.CornerRadius = UDim.new(0, 10)
			corner.Parent = bar

			local stroke = Instance.new("UIStroke")
			stroke.Color = Color3.fromRGB(230, 190, 205)
			stroke.Transparency = 0.3
			stroke.Thickness = 1
			stroke.Parent = bar

			local icon = Instance.new("ImageLabel")
			icon.Name = "Icon"
			icon.BackgroundTransparency = 1
			icon.Image = "rbxassetid://100604009889706"
			icon.ImageColor3 = Color3.fromRGB(110, 60, 85)
			icon.ImageTransparency = 0.2
			icon.AnchorPoint = Vector2.new(0, 0.5)
			icon.Position = UDim2.new(0, 10, 0.5, 0)
			icon.Size = UDim2.fromOffset(14, 14)
			icon.ZIndex = 26
			icon.Parent = bar

			local box = Instance.new("TextBox")
			box.Name = "Query"
			box.BackgroundTransparency = 1
			box.ClearTextOnFocus = false
			box.Text = ""
			box.PlaceholderText = "Search..."
			box.PlaceholderColor3 = Color3.fromRGB(170, 120, 140)
			box.TextColor3 = Color3.fromRGB(60, 30, 45)
			box.TextSize = 14
			box.Font = Enum.Font.GothamMedium
			box.TextXAlignment = Enum.TextXAlignment.Left
			box.TextTruncate = Enum.TextTruncate.AtEnd
			box.AnchorPoint = Vector2.new(0, 0.5)
			box.Position = UDim2.new(0, 30, 0.5, 0)
			box.Size = UDim2.new(1, -38, 1, -4)
			box.ZIndex = 26
			box.Parent = bar

			local function tabLabel(tab)
				return string.lower(tostring(tab.name or tab.Name or ""))
			end

			local function setTabVisible(tab, visible)
				-- Prefer the outer pill (topbarItem). Hiding only topbarItemContainer left an
				-- empty selected pink bar in the rail.
				local item = tab.topbarItem or tab.topbarItemContainer
				if typeof(item) == "Instance" then
					item.Visible = visible
				end
				if typeof(tab.topbarItemContainer) == "Instance" and tab.topbarItemContainer ~= item then
					tab.topbarItemContainer.Visible = visible
				end
			end

			local function applySidebarFilter(query)
				query = string.lower(query or "")
				query = query:gsub("^%s+", ""):gsub("%s+$", "")
				local owned = {}
				for _, tab in ipairs(Window.tabs or {}) do
					if tab.topbarItem then
						owned[tab.topbarItem] = true
					end
					if tab.topbarItemContainer then
						owned[tab.topbarItemContainer] = true
					end
					if not tab.neglectSelector then
						local label = tabLabel(tab)
						setTabVisible(tab, query == "" or string.find(label, query, 1, true) ~= nil)
					end
				end
				-- Window:CreateSection headers live in the same rail (never keep blank frames).
				for _, child in ipairs(tabList:GetChildren()) do
					if child:IsA("GuiObject") and not owned[child] and not child:IsA("UIListLayout") and not child:IsA("UIPadding") then
						local label = child:FindFirstChildWhichIsA("TextLabel", true)
						local text = label and string.lower(label.Text) or ""
						child.Visible = query == "" or (text ~= "" and string.find(text, query, 1, true) ~= nil)
					end
				end
			end

			box:GetPropertyChangedSignal("Text"):Connect(function()
				applySidebarFilter(box.Text)
			end)
		end
	end

	if not hookInstalled then
		Window:Notify({
			title = "Arsenic",
			content = "hookmetamethod is unavailable; No Hunger, Disable Fall Damage and Anti Lose Items will run in a reduced mode.",
		})
	end
end)()
