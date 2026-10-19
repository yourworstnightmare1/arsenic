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
local Lighting = game:GetService("Lighting")

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
	DisableSurrenderEmote = function(remote, method)
		return on("DisableSurrenderEmote")
			and method == "FireServer"
			and remote.Name == "Surrender"
			and remote.Parent == ReplicatedStorage
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
					-- Crawl.lua disables Jumping for 2.8s after each jump; block that cooldown.
					-- Still allow Fist / crawl to lock jumping.
					if method == "SetStateEnabled"
						and on("DisableJumpFatigue")
						and self:IsA("Humanoid")
					then
						local state, enabled = ...
						if state == Enum.HumanoidStateType.Jumping and enabled == false then
							local character = self.Parent
							local tool = character and character:FindFirstChildOfClass("Tool")
							local fistLock = tool and tool.Name == "Fist"
							local crawling = gameShared and gameShared.IsCrawling
							if not fistLock and not crawling then
								return nil
							end
						end
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
	local root = getRoot()
	local civCars = Workspace:FindFirstChild("CivCars")
	if not civCars or (humanoid and humanoid.SeatPart) or not root then
		return
	end
	local origin = root.Position
	-- Only touch nearby cars — full CivCars GetDescendants every second hitch the whole client.
	for _, car in ipairs(civCars:GetChildren()) do
		local pivot = car:GetPivot()
		if (pivot.Position - origin).Magnitude <= 220 then
			local seat = car:FindFirstChild("DriveSeat", true) or car:FindFirstChildWhichIsA("VehicleSeat", true)
			if seat then
				for _, child in ipairs(seat:GetChildren()) do
					if child:IsA("ProximityPrompt") and not child.Enabled then
						child.Enabled = true
					end
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
local teleportMethod = "Instant"
local teleportSpeedSlider = nil

-- The server kicks for "Flying" when airborne too long and reverts single huge jumps,
-- so trips are short, fast glides hugging the ground: accelerate over TELEPORT_RAMP
-- seconds to TeleportSpeed.
local MIN_TELEPORT_SPEED = 400
local TELEPORT_START_SPEED = 600
local TELEPORT_RAMP = 0.12
local MAX_TRAVEL_FLAGS = 8
local MAX_FOOT_TRIP_SECONDS = 28
local MAX_CAR_TRIP_SECONDS = 16
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

-- preferY: when set (door / bed / prompt height), ignore roof hits above that level.
local function findGroundY(position, extraIgnore, preferY)
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
	deepRayParams.FilterDescendantsInstances = ignore

	local x, z = position.X, position.Z
	local function castFrom(startY, distance)
		return Workspace:Raycast(Vector3.new(x, startY, z), Vector3.new(0, -distance, 0), travelRayParams)
	end

	if preferY then
		-- Sample just above the intended floor so rooftops above the ray origin are skipped.
		local bestY, bestScore = nil, math.huge
		for _, up in ipairs({ 5, 10, 18, 28 }) do
			local result = castFrom(preferY + up, up + 45)
			if result then
				local y = result.Position.Y
				-- Roof / upper deck: well above the door/prompt. Street/porch/floor: near preferY.
				if y <= preferY + 5 and y >= preferY - 35 then
					local score = math.abs(y - preferY)
					if score < bestScore then
						bestScore, bestY = score, y
					end
				end
			end
		end
		if bestY then
			return bestY
		end
		-- Fallback: short cast from the preferred level itself.
		local near = castFrom(preferY + 6, 50)
		if near and near.Position.Y <= preferY + 8 then
			return near.Position.Y
		end
	end

	local result = castFrom(position.Y + 6, 60)
	if result then
		-- If we were aimed at a floor but hit a much higher surface, keep searching downward.
		if preferY and result.Position.Y > preferY + 6 then
			local lower = castFrom(preferY + 6, 50)
			if lower then
				return lower.Position.Y
			end
		end
		return result.Position.Y
	end
	-- Over rivers and gaps: look much further down and count the water surface, otherwise the
	-- glide keeps its height there and the server kicks for flying.
	result = Workspace:Raycast(Vector3.new(x, position.Y + 6, z), Vector3.new(0, -DEEP_GROUND_RAY, 0), deepRayParams)
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

-- Per-trip speed only (do not permanently tank the Teleport Speed slider — that left
-- later trips stuck at 250 studs/s and still getting pulled back).
local function slowTripSpeed(tripSpeed)
	return math.max(math.floor(tripSpeed * 0.75), MIN_TELEPORT_SPEED)
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
		-- Foot-tween after a failed Vehicle trip is what dumps people under the map.
		if teleportMethod == "Vehicle" then
			return false
		end
	end
	-- Instant: same pattern as hazura/nazuro & open-source hubs — wait out LastACPos, snap CFrame.
	if not keepSeat and teleportMethod == "Instant" then
		local instant = Arsenic._instantBypassTeleport
		if type(instant) == "function" then
			local ok, arrived = pcall(instant, goal)
			if ok and arrived then
				return true
			end
		end
		-- If the AC ate the snap, fall back to a fast map-Seat sit/snap (still ~1.5s, not a glide).
		local snap = Arsenic._seatSnapTeleport
		if type(snap) == "function" then
			local ok, arrived = pcall(snap, goal)
			if ok and arrived then
				return true
			end
		end
		return false
	end
	-- Tween (and Car + Tween finish): sit first, then move the Seat.
	local wantSeat = teleportMethod == "Tween" or (teleportMethod == "Car + Tween" and inVehicleTrip)
	if not keepSeat and wantSeat then
		local seatTravel = Arsenic._seatBypassTeleport
		if type(seatTravel) == "function" then
			local ok, arrived = pcall(seatTravel, goal)
			if ok and arrived then
				return true
			end
		end
	end
	if not keepSeat then
		exitSeat(humanoid)
	end
	local seat = keepSeat and humanoid.SeatPart or nil
	local vehicle = seat and getVehicleModel(seat)
	local mover = vehicle and seat or root
	-- TB3 road deck is ~250; never write pivots into the void / kill floor.
	local voidFloor = Workspace.FallenPartsDestroyHeight + 120
	local mapFloor = 220

	local function waitAntiCheatClear(timeout)
		local deadline = os.clock() + (timeout or 1.5)
		while LocalPlayer:GetAttribute("LastACPos") and os.clock() < deadline and not Arsenic.Destroyed do
			task.wait()
		end
	end

	local function resolve()
		if type(goal) == "function" then
			return goal()
		end
		return goal
	end
	local function getPivot()
		return vehicle and vehicle:GetPivot() or root.CFrame
	end

	local function groundedCFrame(cframe, lift)
		lift = lift or 3
		local pos = cframe.Position
		local groundY = findGroundY(Vector3.new(pos.X, math.max(pos.Y, mapFloor) + 40, pos.Z), vehicle, pos.Y)
		local y
		if groundY and groundY > voidFloor then
			y = groundY + lift
		else
			y = math.max(pos.Y, mapFloor + lift, voidFloor + 10)
		end
		y = math.max(y, voidFloor + 10, mapFloor)
		return CFrame.new(pos.X, y, pos.Z) * (cframe - pos)
	end

	local acWaitPending = true
	local function setPivot(cframe)
		cframe = groundedCFrame(cframe, vehicle and 3 or (humanoid and getStandHeight(humanoid, root) or 3))
		if acWaitPending or LocalPlayer:GetAttribute("LastACPos") then
			waitAntiCheatClear(vehicle and 0.4 or 1.5)
			acWaitPending = false
		end
		if humanoid and not vehicle then
			pcall(function()
				humanoid.PlatformStand = false
				humanoid:ChangeState(Enum.HumanoidStateType.Physics)
			end)
		end
		if vehicle then
			vehicle:PivotTo(cframe)
		else
			root.CFrame = cframe
		end
		mover.AssemblyLinearVelocity = Vector3.zero
		mover.AssemblyAngularVelocity = Vector3.zero
		if humanoid and not vehicle then
			pcall(function()
				humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
			end)
		end
		if cframe.Position.Y > mapFloor then
			lastSafeCFrame = cframe
		end
	end

	local function bailToSafety()
		if lastSafeCFrame and lastSafeCFrame.Position.Y > mapFloor then
			acWaitPending = true
			setPivot(lastSafeCFrame)
			return true
		end
		return false
	end

	local target = resolve()
	if not target then
		return false
	end
	target = groundedCFrame(target, humanoid and getStandHeight(humanoid, root) or 3)

	if teleportMethod == "Instant" then
		acWaitPending = true
		setPivot(target)
		task.wait(0.05)
		mover.AssemblyLinearVelocity = Vector3.zero
		mover.AssemblyAngularVelocity = Vector3.zero
		if (getPivot().Position - target.Position).Magnitude > 8 then
			acWaitPending = true
			waitAntiCheatClear(1.5)
			setPivot(target)
		end
		local here = getPivot().Position
		if here.Y < mapFloor then
			bailToSafety()
			return false
		end
		return (here - target.Position).Magnitude <= 12
	end

	local arrived = false
	local flags = 0
	local standOffset = nil
	local vehicleClearance = 3
	local tripSpeed = math.max(Arsenic.Values.TeleportSpeed, MIN_TELEPORT_SPEED)
	local carTripSpeed = math.max(Arsenic.Values.CarTeleportSpeed, 500)
	if not vehicle then
		standOffset = getStandHeight(humanoid, root)
	elseif seat then
		vehicleClearance = math.clamp(seat.Position.Y - (findGroundY(seat.Position, vehicle) or seat.Position.Y - 3), 2, 6)
	end
	travelling = true

	local function hugGround(position)
		local groundY = findGroundY(Vector3.new(position.X, math.max(position.Y, mapFloor) + 40, position.Z), vehicle)
		local lift = standOffset or vehicleClearance
		if groundY and groundY > voidFloor then
			return Vector3.new(position.X, groundY + lift, position.Z)
		end
		-- No ground (gap/void): hold last safe deck height instead of diving.
		local safeY = lastSafeCFrame and lastSafeCFrame.Position.Y or (mapFloor + lift)
		return Vector3.new(position.X, math.max(safeY, mapFloor + lift), position.Z)
	end

	local function land()
		local current = getPivot()
		if current.Position.Y < mapFloor then
			bailToSafety()
			return
		end
		acWaitPending = true
		setPivot(current)
	end

	local tripDeadline = os.clock() + (vehicle and MAX_CAR_TRIP_SECONDS or MAX_FOOT_TRIP_SECONDS)

	local function glide()
		local flagMark = teleportFlagCount
		local expected = getPivot().Position
		if expected.Y < mapFloor then
			bailToSafety()
			return "aborted"
		end
		local distance = (target.Position - expected).Magnitude
		local topSpeed
		if vehicle then
			topSpeed = math.max(carTripSpeed, distance / CAR_TRIP_SECONDS)
		else
			topSpeed = math.max(tripSpeed, MIN_TELEPORT_SPEED)
		end
		local startSpeed = math.min(TELEPORT_START_SPEED, topSpeed)
		local started = os.clock()
		local deadline = math.min(started + TELEPORT_RAMP + distance / math.max(topSpeed * 0.45, 80) + 3, tripDeadline)

		while not Arsenic.Destroyed do
			local dt = RunService.Heartbeat:Wait()
			local resolved = resolve()
			if not resolved or not mover.Parent or humanoid.Health <= 0 or os.clock() > deadline then
				return "aborted"
			end
			target = groundedCFrame(resolved, standOffset or vehicleClearance)
			if vehicle and humanoid.SeatPart ~= seat then
				return "aborted"
			end
			local current = getPivot().Position
			if current.Y < mapFloor then
				bailToSafety()
				return "aborted"
			end
			if (current - expected).Magnitude > 14 or teleportFlagCount ~= flagMark then
				return "flagged"
			end

			local ramp = math.clamp((os.clock() - started) / TELEPORT_RAMP, 0, 1)
			local speed = startSpeed + (topSpeed - startSpeed) * ramp * ramp
			local offset = target.Position - current
			local step = speed * math.clamp(dt, 0, 0.05)
			if offset.Magnitude <= step then
				setPivot(target)
				return "arrived"
			end
			local nextPosition = hugGround(current + offset.Unit * step)
			-- Cap vertical change, but never allow a step downward into the void.
			local maxDrop = math.min(step, math.max(0, current.Y - mapFloor))
			nextPosition = Vector3.new(
				nextPosition.X,
				math.clamp(nextPosition.Y, current.Y - maxDrop, current.Y + step),
				nextPosition.Z
			)
			if nextPosition.Y < mapFloor then
				bailToSafety()
				return "aborted"
			end
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
			acWaitPending = true
			waitAntiCheatClear(2)
			if getPivot().Position.Y < mapFloor then
				bailToSafety()
				return
			end
			land()
			if vehicle then
				carTripSpeed = slowTripSpeed(carTripSpeed)
				if flags >= 2 then
					notify(("Pulled back; retrying car at %d studs/s."):format(carTripSpeed))
				end
			else
				tripSpeed = slowTripSpeed(tripSpeed)
				if flags >= 2 then
					notify(("Pulled back; retrying glide at %d studs/s."):format(tripSpeed))
				end
			end
			task.wait(0.45 + flags * 0.1)
			local resolved = resolve()
			if not resolved or os.clock() > tripDeadline then
				return
			end
			target = groundedCFrame(resolved, standOffset or vehicleClearance)
		end
	end)
	travelling = false
	if not on("Noclip") then
		Features.Noclip.disable()
	end
	local here = getRoot()
	if here and here.Position.Y < mapFloor then
		bailToSafety()
		arrived = false
	end
	if ok and not arrived and flags >= MAX_TRAVEL_FLAGS then
		notify("Kept getting pulled back by the anti-teleport; gave up on this trip.")
	end
	return ok and arrived
end

local function teleportCharacter(goal, keepSeat)
	local arrived = protectTravel(rawTeleportCharacter, goal, keepSeat)
	if arrived or keepSeat or inVehicleTrip then
		return arrived
	end
	-- Last resort: move a map Seat (same bypass open-source hubs use).
	local bypass = Arsenic._seatBypassTeleport
	if type(bypass) == "function" then
		local ok, bypassed = pcall(function()
			return protectTravel(bypass, goal)
		end)
		if ok and bypassed then
			return true
		end
	end
	return arrived
end

-- Steal/sit approaches must not borrow another car (Vehicle method leaves you standing beside the target).
-- Prefer Instant (CFrame / seat snap). Long Tween glides trip the game's "Teleported for Teleportation" pullback.
local function teleportOnFoot(goal)
	local previous = teleportMethod
	local function distanceToGoal()
		local root = getRoot()
		if root and typeof(goal) == "CFrame" then
			return (root.Position - goal.Position).Magnitude
		end
		return math.huge
	end

	teleportMethod = "Instant"
	local ok, arrived = pcall(teleportCharacter, goal, false)
	if ok and arrived then
		teleportMethod = previous
		return true
	end

	-- Only tween a short leftover gap — never across the map.
	if distanceToGoal() < 100 then
		teleportMethod = "Tween"
		ok, arrived = pcall(teleportCharacter, goal, false)
		teleportMethod = previous
		if not ok then
			error(arrived, 0)
		end
		return arrived
	end

	teleportMethod = previous
	if not ok then
		error(arrived, 0)
	end
	return false
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
	if not camera or not on("Spectate") then
		return
	end
	local _, targetHumanoid = getTargetParts(getSelectedPlayer())
	-- Never fall back to the local humanoid here — that is what caused the camera to
	-- flicker between spectate and normal view when the target briefly failed a lookup.
	if targetHumanoid then
		Features.Spectate._subject = targetHumanoid
	end
	local subject = Features.Spectate._subject
	if subject and subject.Parent and camera.CameraSubject ~= subject then
		camera.CameraSubject = subject
	end
end

Features.Spectate = {
	enable = function()
		if not getSelectedPlayer() then
			notify("Select a player to spectate.")
			Arsenic.Enabled.Spectate = false
			return
		end
		if not Features.Spectate._savedZoom then
			Features.Spectate._savedZoom = {
				min = LocalPlayer.CameraMinZoomDistance,
				max = LocalPlayer.CameraMaxZoomDistance,
			}
			LocalPlayer.CameraMinZoomDistance = 20
			LocalPlayer.CameraMaxZoomDistance = math.max(LocalPlayer.CameraMaxZoomDistance, 64)
		end
		updateSpectate()
		if Features.Spectate._conn then
			Features.Spectate._conn:Disconnect()
		end
		-- Hold CameraSubject every frame; the default camera script resets it otherwise.
		Features.Spectate._conn = RunService.RenderStepped:Connect(function()
			if Arsenic.Destroyed or not on("Spectate") then
				return
			end
			updateSpectate()
		end)
		track(Features.Spectate._conn)
	end,
	disable = function()
		if Features.Spectate._conn then
			Features.Spectate._conn:Disconnect()
			Features.Spectate._conn = nil
		end
		Features.Spectate._subject = nil
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

--------------------------------------------------------------------------------
-- Camera (FOV / bodycam / helmet / freecam)
--------------------------------------------------------------------------------

;(function()
	local UserInputService = game:GetService("UserInputService")
	local ContextActionService = game:GetService("ContextActionService")
	Arsenic.Values.FOV = Arsenic.Values.FOV or 96
	Arsenic.Values.CameraMode = Arsenic.Values.CameraMode or "Regular Camera"
	Arsenic.Values.FreecamSpeed = Arsenic.Values.FreecamSpeed or 60
	Arsenic.Values.FreecamBoostSpeed = Arsenic.Values.FreecamBoostSpeed or 160
	Arsenic.Values.FreecamBoostKey = Arsenic.Values.FreecamBoostKey or "LeftShift"
	Arsenic.Values.FreecamSmoothing = Arsenic.Values.FreecamSmoothing or 0.15

	local freecam = {
		yaw = 0,
		pitch = 0,
		cf = nil,
		smooth = nil,
		lookX = 0,
		lookY = 0,
		savedWalk = nil,
		savedJump = nil,
		controls = nil,
	}
	-- Shared mouse-look for Bodycam / Helmet Cam (must NOT follow torso/head rotation).
	local viewCam = {
		yaw = 0,
		pitch = 0,
		lookX = 0,
		lookY = 0,
		active = false,
		hidden = {},
		savedAutoRotate = nil,
		lastCharacter = nil,
		lastMode = nil,
	}

	local SINK_ACTION = "ArsenicFreecamSink"
	local SINK_KEYS = {
		Enum.KeyCode.W,
		Enum.KeyCode.A,
		Enum.KeyCode.S,
		Enum.KeyCode.D,
		Enum.KeyCode.Up,
		Enum.KeyCode.Down,
		Enum.KeyCode.Left,
		Enum.KeyCode.Right,
		Enum.KeyCode.Space,
		Enum.KeyCode.LeftShift,
		Enum.KeyCode.RightShift,
		Enum.KeyCode.LeftControl,
		Enum.KeyCode.RightControl,
		Enum.KeyCode.Q,
		Enum.KeyCode.E,
		Enum.UserInputType.MouseButton1,
		Enum.UserInputType.MouseButton2,
		Enum.UserInputType.MouseWheel,
	}

	local function parseKey(name)
		name = tostring(name or ""):gsub("%s+", "")
		if name == "" then
			return Enum.KeyCode.LeftShift
		end
		local ok, key = pcall(function()
			return Enum.KeyCode[name]
		end)
		if ok and typeof(key) == "EnumItem" then
			return key
		end
		return Enum.KeyCode.LeftShift
	end

	local function applyFov(camera)
		local fov = tonumber(Arsenic.Values.FOV) or 96
		fov = math.clamp(fov, 1, 120)
		if camera.FieldOfView ~= fov then
			camera.FieldOfView = fov
		end
		return fov
	end

	local function torsoPart(character)
		return character:FindFirstChild("UpperTorso")
			or character:FindFirstChild("Torso")
			or character:FindFirstChild("HumanoidRootPart")
	end

	local function headPart(character)
		return character:FindFirstChild("Head")
	end

	local function modeFov(base)
		-- Pseudo-fisheye: push FOV up for body/helmet cams.
		return math.clamp(math.max(base, 105), 1, 120)
	end

	local function clearViewHidden()
		for part, _ in pairs(viewCam.hidden) do
			if part.Parent then
				part.LocalTransparencyModifier = 0
			end
		end
		table.clear(viewCam.hidden)
	end

	local function hideLocalFirstPerson(character, helmet)
		clearViewHidden()
		if not character then
			return
		end
		for _, inst in ipairs(character:GetDescendants()) do
			if inst:IsA("BasePart") then
				local hide = false
				if helmet then
					hide = inst.Name == "Head"
						or inst.Parent:IsA("Accessory")
						or inst.Parent:IsA("Hat")
				else
					-- Bodycam: hide head/accessories so they don't fill the wide FOV.
					hide = inst.Name == "Head" or inst.Parent:IsA("Accessory") or inst.Parent:IsA("Hat")
				end
				if hide then
					inst.LocalTransparencyModifier = 1
					viewCam.hidden[inst] = true
				end
			end
		end
	end

	local function beginViewCam(camera)
		if viewCam.active then
			return
		end
		viewCam.active = true
		local look = camera.CFrame.LookVector
		viewCam.yaw = math.atan2(-look.X, -look.Z)
		viewCam.pitch = math.asin(math.clamp(look.Y, -1, 1))
		viewCam.lookX = 0
		viewCam.lookY = 0
		UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
		UserInputService.MouseIconEnabled = false
	end

	local function endViewCam()
		if not viewCam.active then
			return
		end
		viewCam.active = false
		clearViewHidden()
		local humanoid = getHumanoid()
		if humanoid and viewCam.savedAutoRotate ~= nil then
			humanoid.AutoRotate = viewCam.savedAutoRotate
		end
		viewCam.savedAutoRotate = nil
		viewCam.lastCharacter = nil
		viewCam.lastMode = nil
		if not on("Freecam") then
			UserInputService.MouseBehavior = Enum.MouseBehavior.Default
			UserInputService.MouseIconEnabled = true
		end
	end

	local function consumeLookDelta()
		local dx, dy = viewCam.lookX, viewCam.lookY
		viewCam.lookX, viewCam.lookY = 0, 0
		if dx == 0 and dy == 0 then
			local delta = UserInputService:GetMouseDelta()
			dx, dy = delta.X, delta.Y
		end
		return dx, dy
	end

	local function getPlayerControls()
		local ok, controls = pcall(function()
			local scripts = LocalPlayer:FindFirstChild("PlayerScripts")
			local module = scripts and scripts:FindFirstChild("PlayerModule")
			if module then
				return require(module):GetControls()
			end
			return nil
		end)
		return ok and controls or nil
	end

	local function freezeCharacter(freeze)
		local humanoid = getHumanoid()
		local root = getRoot()
		if freeze then
			if humanoid and freecam.savedWalk == nil then
				freecam.savedWalk = humanoid.WalkSpeed
				freecam.savedJump = humanoid.JumpPower
				humanoid.WalkSpeed = 0
				humanoid.JumpPower = 0
				pcall(function()
					humanoid.JumpHeight = 0
				end)
			end
			if root then
				root.AssemblyLinearVelocity = Vector3.zero
				root.AssemblyAngularVelocity = Vector3.zero
			end
			local controls = freecam.controls or getPlayerControls()
			freecam.controls = controls
			if controls then
				pcall(function()
					controls:Disable()
				end)
			end
			pcall(function()
				ContextActionService:BindActionAtPriority(
					SINK_ACTION,
					function()
						return Enum.ContextActionResult.Sink
					end,
					false,
					Enum.ContextActionPriority.High.Value + 100,
					table.unpack(SINK_KEYS)
				)
			end)
		else
			local humanoidNow = getHumanoid()
			if humanoidNow and freecam.savedWalk ~= nil then
				humanoidNow.WalkSpeed = freecam.savedWalk
				humanoidNow.JumpPower = freecam.savedJump or 50
			end
			freecam.savedWalk = nil
			freecam.savedJump = nil
			if freecam.controls then
				pcall(function()
					freecam.controls:Enable()
				end)
			end
			freecam.controls = nil
			pcall(function()
				ContextActionService:UnbindAction(SINK_ACTION)
			end)
		end
	end

	local function restoreDefaultCamera()
		local camera = Workspace.CurrentCamera
		local humanoid = getHumanoid()
		if not camera then
			return
		end
		if on("Spectate") or on("SpectateVehicle") or on("Freecam") then
			return
		end
		if gameShared and gameShared.ViewingHome then
			return
		end
		if Arsenic.Values.CameraMode ~= "Regular Camera" then
			return
		end
		if camera.CameraType ~= Enum.CameraType.Custom then
			camera.CameraType = Enum.CameraType.Custom
		end
		if humanoid and camera.CameraSubject ~= humanoid then
			camera.CameraSubject = humanoid
		end
		applyFov(camera)
	end

	Features.Freecam = {
		enable = function()
			local camera = Workspace.CurrentCamera
			if not camera then
				Arsenic.Enabled.Freecam = false
				return
			end
			freecam.cf = camera.CFrame
			freecam.smooth = camera.CFrame
			local look = camera.CFrame.LookVector
			freecam.yaw = math.atan2(-look.X, -look.Z)
			freecam.pitch = math.asin(math.clamp(look.Y, -1, 1))
			freecam.lookX = 0
			freecam.lookY = 0
			camera.CameraType = Enum.CameraType.Scriptable
			camera.CameraSubject = nil
			UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
			UserInputService.MouseIconEnabled = false
			freezeCharacter(true)
		end,
		disable = function()
			freezeCharacter(false)
			UserInputService.MouseBehavior = Enum.MouseBehavior.Default
			UserInputService.MouseIconEnabled = true
			restoreDefaultCamera()
		end,
	}

	track(UserInputService.InputChanged:Connect(function(input)
		if UserInputService:GetFocusedTextBox() then
			return
		end
		if input.UserInputType ~= Enum.UserInputType.MouseMovement then
			return
		end
		if on("Freecam") then
			freecam.lookX += input.Delta.X
			freecam.lookY += input.Delta.Y
		elseif viewCam.active then
			viewCam.lookX += input.Delta.X
			viewCam.lookY += input.Delta.Y
		end
	end))

	track(RunService.RenderStepped:Connect(function(dt)
		if Arsenic.Destroyed then
			return
		end
		local camera = Workspace.CurrentCamera
		if not camera then
			return
		end
		dt = math.clamp(dt, 0, 0.05)

		-- Game phone home cams own the camera while ViewingHome is set.
		if gameShared and gameShared.ViewingHome then
			return
		end

		local baseFov = applyFov(camera)

		-- Freecam wins over bodycam / spectate subject.
		if on("Freecam") then
			if UserInputService:GetFocusedTextBox() then
				UserInputService.MouseBehavior = Enum.MouseBehavior.Default
				UserInputService.MouseIconEnabled = true
				return
			end
			camera.CameraType = Enum.CameraType.Scriptable
			camera.CameraSubject = nil
			UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
			UserInputService.MouseIconEnabled = false
			local humanoid = getHumanoid()
			local root = getRoot()
			if humanoid then
				humanoid.WalkSpeed = 0
				humanoid.JumpPower = 0
			end
			if root then
				root.AssemblyLinearVelocity = Vector3.zero
			end

			-- Prefer InputChanged deltas; fall back to GetMouseDelta.
			local dx, dy = freecam.lookX, freecam.lookY
			freecam.lookX, freecam.lookY = 0, 0
			if dx == 0 and dy == 0 then
				local delta = UserInputService:GetMouseDelta()
				dx, dy = delta.X, delta.Y
			end
			freecam.yaw -= dx * 0.0035
			freecam.pitch = math.clamp(freecam.pitch - dy * 0.0035, -1.4, 1.4)
			local rot = CFrame.Angles(0, freecam.yaw, 0) * CFrame.Angles(freecam.pitch, 0, 0)
			local move = Vector3.zero
			local function down(key)
				return UserInputService:IsKeyDown(key)
			end
			if down(Enum.KeyCode.W) then
				move += Vector3.new(0, 0, -1)
			end
			if down(Enum.KeyCode.S) then
				move += Vector3.new(0, 0, 1)
			end
			if down(Enum.KeyCode.A) then
				move += Vector3.new(-1, 0, 0)
			end
			if down(Enum.KeyCode.D) then
				move += Vector3.new(1, 0, 0)
			end
			if down(Enum.KeyCode.E) or down(Enum.KeyCode.Space) then
				move += Vector3.new(0, 1, 0)
			end
			if down(Enum.KeyCode.Q) or down(Enum.KeyCode.LeftControl) then
				move += Vector3.new(0, -1, 0)
			end
			local boost = down(parseKey(Arsenic.Values.FreecamBoostKey))
			local speed = boost and (tonumber(Arsenic.Values.FreecamBoostSpeed) or 160)
				or (tonumber(Arsenic.Values.FreecamSpeed) or 60)
			if move.Magnitude > 0 then
				move = move.Unit
			end
			local worldMove = rot:VectorToWorldSpace(move) * speed * dt
			freecam.cf = CFrame.new((freecam.cf or camera.CFrame).Position + worldMove) * rot
			local smooth = math.clamp(tonumber(Arsenic.Values.FreecamSmoothing) or 0.15, 0, 0.95)
			if smooth <= 0.001 then
				freecam.smooth = freecam.cf
			else
				local alpha = 1 - math.pow(smooth, dt * 60)
				freecam.smooth = (freecam.smooth or freecam.cf):Lerp(freecam.cf, alpha)
			end
			camera.CFrame = freecam.smooth
			camera.FieldOfView = baseFov
			return
		end

		if on("Spectate") or on("SpectateVehicle") then
			applyFov(camera)
			return
		end

		local mode = Arsenic.Values.CameraMode or "Regular Camera"
		if mode == "Regular Camera" then
			endViewCam()
			if camera.CameraType == Enum.CameraType.Scriptable then
				camera.CameraType = Enum.CameraType.Custom
			end
			local humanoidRest = getHumanoid()
			if humanoidRest and camera.CameraSubject ~= humanoidRest then
				camera.CameraSubject = humanoidRest
			end
			applyFov(camera)
			return
		end

		local character = getCharacter()
		local humanoid = getHumanoid()
		local root = getRoot()
		if not (character and humanoid and root) or humanoid.SeatPart then
			-- Keep regular camera in vehicles.
			endViewCam()
			if camera.CameraType == Enum.CameraType.Scriptable then
				camera.CameraType = Enum.CameraType.Custom
			end
			if humanoid and camera.CameraSubject ~= humanoid then
				camera.CameraSubject = humanoid
			end
			applyFov(camera)
			return
		end

		if UserInputService:GetFocusedTextBox() then
			UserInputService.MouseBehavior = Enum.MouseBehavior.Default
			UserInputService.MouseIconEnabled = true
			return
		end

		beginViewCam(camera)
		if viewCam.lastCharacter ~= character or viewCam.lastMode ~= mode then
			viewCam.lastCharacter = character
			viewCam.lastMode = mode
			hideLocalFirstPerson(character, mode == "Helmet Cam")
			if viewCam.savedAutoRotate == nil then
				viewCam.savedAutoRotate = humanoid.AutoRotate
			end
			-- Let PlayerModule steer from camera look; don't fight AutoRotate with root writes.
			humanoid.AutoRotate = true
		end

		local dx, dy = consumeLookDelta()
		viewCam.yaw -= dx * 0.0035
		viewCam.pitch = math.clamp(viewCam.pitch - dy * 0.0035, -1.2, 1.2)
		local rot = CFrame.Angles(0, viewCam.yaw, 0) * CFrame.Angles(viewCam.pitch, 0, 0)

		-- Position from the body, orientation from mouse only — following torso/head
		-- rotation caused the classic bodycam spin / "walk in circles" loop.
		camera.CameraType = Enum.CameraType.Scriptable
		camera.CameraSubject = nil
		UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
		UserInputService.MouseIconEnabled = false

		if mode == "Bodycam" then
			local torso = torsoPart(character)
			local pos = (torso and torso.Position or root.Position) + Vector3.new(0, 0.45, 0)
			camera.CFrame = CFrame.new(pos) * rot
		else
			local head = headPart(character)
			local pos = head and head.Position or (root.Position + Vector3.new(0, 1.5, 0))
			-- Sit outside the head mesh (forward + slightly right), not inside glasses/helmet.
			camera.CFrame = CFrame.new(pos) * rot * CFrame.new(0.28, 0.12, -0.85)
		end

		camera.FieldOfView = modeFov(baseFov)
	end))
end)()

-- Teleport To Player -----------------------------------------------------------

local function teleportToPlayer()
	local player, _, _, targetRoot = requireTarget()
	if player then
		teleportCharacter(function()
			return targetRoot.Parent and behind(targetRoot, 3) or nil
		end)
	end
end

-- Shoot Player (Kill / Ragdoll via gun) ----------------------------------------
-- Nested so helper locals do not blow the main chunk's 200-register O0 limit.
-- Real damage path: Fire/Visualize → FastCast RayHit → InflictTarget (client),
-- with a matching manual InflictTarget + MarkerEvent backup.

local killPlayer, ragdollPlayer = (function()
	local losParams = RaycastParams.new()
	losParams.FilterType = Enum.RaycastFilterType.Exclude
	losParams.IgnoreWater = true

	local KILL_MODS = {
		SpreadX = 0,
		SpreadY = 0,
		DropGravity = 0,
		WindOffset = Vector3.zero,
		ExplosiveEnabled = false,
		BulletSpeed = 1e12,
		Range = 1000,
		JamChance = 0,
	}

	local function hasLineOfSight(origin, target, ignore)
		losParams.FilterDescendantsInstances = ignore
		return Workspace:Raycast(origin, target - origin, losParams) == nil
	end

	local function zeroRootMotion(root)
		if not root then
			return
		end
		pcall(function()
			root.AssemblyLinearVelocity = Vector3.zero
			root.AssemblyAngularVelocity = Vector3.zero
		end)
		pcall(function()
			root.Velocity = Vector3.zero
			root.RotVelocity = Vector3.zero
		end)
	end

	local function waitAcClear(timeout)
		local deadline = os.clock() + (timeout or 1.25)
		while LocalPlayer:GetAttribute("LastACPos") and os.clock() < deadline and not Arsenic.Destroyed do
			RunService.Heartbeat:Wait()
		end
		RunService.Heartbeat:Wait()
	end

	local function findShootSpot(targetRoot, aimPart, ignore)
		for _, radius in ipairs({ 2.5, 4, 6, 9 }) do
			for step = 0, 7 do
				local angle = step * math.pi / 4
				local position = targetRoot.Position
					+ Vector3.new(math.cos(angle) * radius, 0, math.sin(angle) * radius)
				local eye = position + Vector3.new(0, 1.5, 0)
				if hasLineOfSight(eye, aimPart.Position, ignore) then
					return CFrame.lookAt(
						position,
						Vector3.new(targetRoot.Position.X, position.Y, targetRoot.Position.Z)
					)
				end
			end
		end
		return behind(targetRoot, 2.5)
	end

	-- InflictTarget is an UnreliableRemoteEvent in current TB3 builds (was RemoteEvent).
	local function getInflictRemote()
		for _, name in ipairs({ "InflictTarget", "InflictTargetDamage" }) do
			local remote = ReplicatedStorage:FindFirstChild(name)
			if remote and (remote:IsA("RemoteEvent") or remote:IsA("UnreliableRemoteEvent")) then
				return remote
			end
		end
		local old = ReplicatedStorage:FindFirstChild("OldInflictTarget")
		if old and (old:IsA("RemoteFunction") or old:IsA("RemoteEvent") or old:IsA("UnreliableRemoteEvent")) then
			return old
		end
		return nil
	end

	local function findBodyPart(character, names)
		for _, name in ipairs(names) do
			local part = character:FindFirstChild(name)
			if part and part:IsA("BasePart") then
				return part
			end
		end
		return nil
	end

	local function childOf(parent, name)
		return parent and parent:FindFirstChild(name) or nil
	end

	local function applyKillMods(settings)
		if not settings then
			return
		end
		for key, value in pairs(KILL_MODS) do
			setGunValue(settings, key, value)
		end
	end

	local function restoreKillMods(settings)
		if not settings then
			return
		end
		for key in pairs(KILL_MODS) do
			restoreGunValue(settings, key)
		end
	end

	local function syncMag(tool)
		pcall(refillGun, tool)
		local server = tool:FindFirstChild("GunScript_Server")
		local mag = server and server:FindFirstChild("Mag")
		local ammo = server and server:FindFirstChild("Ammo")
		local change = server and server:FindFirstChild("ChangeMagAndAmmo")
		local magValue = (mag and tonumber(mag.Value)) or 30
		local ammoValue = (ammo and tonumber(ammo.Value)) or magValue
		if magValue < 1 then
			magValue = tonumber(getGunSettings(tool) and getGunSettings(tool).AmmoPerMag) or 30
		end
		if change and (change:IsA("RemoteEvent") or change:IsA("UnreliableRemoteEvent")) then
			pcall(function()
				change:FireServer(magValue, ammoValue)
			end)
		end
	end

	local function fireInflict(inflict, tool, targetHumanoid, targetRoot, hitPart, damage, settings, origin)
		local gunServer = tool:FindFirstChild("GunScript_Server")
		local gunLocal = tool:FindFirstChild("GunScript_Local")
		local delta = hitPart.Position - origin
		local normal = delta.Magnitude > 1e-4 and delta.Unit or Vector3.new(0, 0, -1)
		local payload = {
			tool,
			LocalPlayer,
			targetHumanoid,
			targetRoot,
			damage,
			{
				settings.Knockback or 0,
				settings.Lifesteal or 0,
				settings.FlamingBullet or false,
				settings.FreezingBullet or false,
				gunServer and gunServer:FindFirstChild("IgniteScript"),
				gunServer and gunServer:FindFirstChild("IcifyScript"),
				settings.IgniteChance or 0,
				settings.IcifyChance or 0,
			},
			{
				settings.CriticalDamageEnabled or false,
				settings.CriticalBaseChance or 0,
				settings.CriticalDamageMultiplier or 1,
			},
			hitPart,
			{
				settings.GoreEffectEnabled or false,
				settings.GoreSoundIDs or {},
				settings.GoreSoundPitchMin or 1,
				settings.GoreSoundPitchMax or 1,
				settings.GoreSoundVolume or 1,
			},
			hitPart.Position,
			normal,
		}
		local ok
		if inflict:IsA("RemoteFunction") then
			ok = pcall(function()
				inflict:InvokeServer(table.unpack(payload))
			end)
		else
			ok = pcall(function()
				inflict:FireServer(table.unpack(payload))
			end)
		end
		local marker = gunLocal and gunLocal:FindFirstChild("MarkerEvent")
		if marker and marker:IsA("BindableEvent") then
			pcall(function()
				marker:Fire(hitPart.Name == "Head" and settings.HeadshotEnabled ~= false)
			end)
		end
		return ok
	end

	-- Mirror GunScript_Local.Fire → Visualize / VisualizeBullet so we don't depend on getsenv alone.
	local function fireVisualize(tool, handle, firePoint, aimPos, settings)
		local gunLocal = tool:FindFirstChild("GunScript_Local")
		local gunServer = tool:FindFirstChild("GunScript_Server")
		if not (gunLocal and settings) then
			return false
		end
		local origin = firePoint.WorldPosition
		local delta = aimPos - origin
		if delta.Magnitude < 1e-4 then
			return false
		end
		local unit = delta.Unit
		local hitEffect = childOf(gunLocal, "HitEffect")
		local bloodEffect = childOf(gunLocal, "BloodEffect")
		local tracerEffect = childOf(gunLocal, "TracerEffect")
		local particleEffect = childOf(gunLocal, "ParticleEffect")
		local explosionEffect = childOf(gunLocal, "ExplosionEffect")
		local goreEffect = childOf(gunLocal, "GoreEffect")

		local hitTbl = {
			settings.HitEffectEnabled,
			settings.HitSoundIDs,
			settings.HitSoundPitchMin,
			settings.HitSoundPitchMax,
			settings.HitSoundVolume,
			hitEffect,
			settings.CustomHitEffect,
		}
		local bloodTbl = {
			settings.BloodEnabled,
			settings.HitCharSndIDs,
			settings.HitCharSndPitchMin,
			settings.HitCharSndPitchMax,
			settings.HitCharSndVolume,
			bloodEffect,
		}
		local holeTbl = {
			settings.BulletHoleEnabled,
			settings.BulletHoleSize,
			settings.BulletHoleTexture,
			settings.PartColor,
			settings.BulletHoleVisibleTime,
			settings.BulletHoleFadeTime,
		}
		local explosiveTbl = {
			false,
			settings.ExplosionRadius,
			settings.ExplosionSoundEnabled,
			settings.ExplosionSoundIDs,
			settings.ExplosionSoundPitchMin,
			settings.ExplosionSoundPitchMax,
			settings.ExplosionSoundVolume,
			settings.CustomExplosion,
			explosionEffect,
		}
		local bulletTbl = {
			settings.BulletTracerEnabled,
			settings.BulletTracerOffset0,
			settings.BulletTracerOffset1,
			tracerEffect,
			settings.BulletParticleEnaled,
			particleEffect,
			settings.Range or 1000,
			settings.BulletSpeed or 1e12,
			0,
			settings.WindOffset or Vector3.zero,
			settings.BulletSize,
			settings.BulletColor,
			settings.BulletTransparency,
			settings.BulletMaterial,
			settings.BulletShape,
			settings.BulletMeshEnabled,
			settings.BulletMeshID,
			settings.BulletTextureID,
			settings.BulletMeshScale,
		}
		local damageTbl = {
			settings.BaseDamage,
			settings.HeadshotDamageMultiplier,
			settings.HeadshotEnabled,
		}
		local whizTbl = {
			settings.WhizSoundEnabled,
			settings.WhizSoundID,
			settings.WhizSoundVolume,
			settings.WhizSoundPitchMin,
			settings.WhizSoundPitchMax,
			settings.WhizDistance,
		}
		local lightTbl = {
			settings.BulletLightEnabled,
			settings.BulletLightBrightness,
			settings.BulletLightColor,
			settings.BulletLightRange,
			settings.BulletLightShadows,
		}
		local knockTbl = {
			settings.Knockback or 0,
			settings.Lifesteal or 0,
			settings.FlamingBullet or false,
			settings.FreezingBullet or false,
			gunServer and gunServer:FindFirstChild("IgniteScript"),
			gunServer and gunServer:FindFirstChild("IcifyScript"),
			settings.IgniteChance or 0,
			settings.IcifyChance or 0,
		}
		local critTbl = {
			settings.CriticalDamageEnabled or false,
			settings.CriticalBaseChance or 0,
			settings.CriticalDamageMultiplier or 1,
		}
		local goreTbl = {
			settings.GoreEffectEnabled or false,
			settings.GoreSoundIDs or {},
			settings.GoreSoundPitchMin or 1,
			settings.GoreSoundPitchMax or 1,
			settings.GoreSoundVolume or 1,
			goreEffect,
		}

		local scripts = LocalPlayer:FindFirstChild("PlayerScripts")
		local vizClient = scripts and scripts:FindFirstChild("BulletVisualizerClientScript")
		local visualize = vizClient and vizClient:FindFirstChild("Visualize")
		local okLocal = false
		if visualize and visualize:IsA("BindableEvent") then
			okLocal = pcall(function()
				visualize:Fire(
					tool,
					handle,
					unit,
					firePoint,
					hitTbl,
					bloodTbl,
					holeTbl,
					explosiveTbl,
					bulletTbl,
					damageTbl,
					lightTbl,
					knockTbl,
					critTbl,
					goreTbl
				)
			end)
		end

		-- Server VisualizeBullet is VFX-only: ends at light (whiz sits where client puts damage).
		local vizRemote = ReplicatedStorage:FindFirstChild("VisualizeBullet")
		if vizRemote and (vizRemote:IsA("RemoteEvent") or vizRemote:IsA("UnreliableRemoteEvent")) then
			pcall(function()
				vizRemote:FireServer(
					tool,
					handle,
					unit,
					firePoint,
					hitTbl,
					bloodTbl,
					holeTbl,
					explosiveTbl,
					bulletTbl,
					whizTbl,
					lightTbl
				)
			end)
		end
		return okLocal
	end

	local function shootPlayer(mode)
		local player, targetCharacter, targetHumanoid, targetRoot = requireTarget()
		if not player then
			return
		end
		if LocalPlayer:GetAttribute("Passive") then
			notify("Turn off Passive mode before shooting players.")
			return
		end
		local character = getCharacter()
		local humanoid = getHumanoid()
		local root = getRoot()
		local tool = character and character:FindFirstChildOfClass("Tool")
		if not isGun(tool) then
			notify("Equip a gun first.")
			return
		end
		local handle = tool:FindFirstChild("Handle")
		local firePoint = handle and handle:FindFirstChild("GunFirePoint")
		local inflict = getInflictRemote()
		local fire = getGunFunction(tool, "Fire")
		if not (handle and firePoint) then
			notify("This gun is missing its fire point.")
			return
		end
		local settings = getGunSettings(tool)
		if not (inflict or fire or settings) then
			notify("Could not find this gun's damage remote.")
			return
		end
		settings = settings or {}

		local aimNames = mode == "kill" and { "Head" }
			or {
				"LeftLowerLeg",
				"RightLowerLeg",
				"Left Leg",
				"Right Leg",
				"LeftUpperLeg",
				"RightUpperLeg",
				"LeftFoot",
				"RightFoot",
				"LowerTorso",
				"Torso",
			}
		local aimPart = findBodyPart(targetCharacter, aimNames)
		if not aimPart then
			notify(player.Name .. " has no " .. (mode == "kill" and "head" or "leg") .. " to shoot.")
			return
		end

		local base = tonumber(settings.BaseDamage) or 25
		local mult = tonumber(settings.HeadshotDamageMultiplier) or 7
		local headEnabled = settings.HeadshotEnabled ~= false
		local damage = mode == "kill" and (headEnabled and base * mult or base) or base
		local shotDelay = math.max(tonumber(settings.FireRate) or 0.1, 0.05)
		local maxShots = mode == "kill" and 48 or 8
		local maxTime = mode == "kill" and 10 or 3

		applyKillMods(settings)
		syncMag(tool)

		exitSeat(humanoid)
		local returnCFrame = root.CFrame
		local reached = teleportCharacter(function()
			local _, _, liveRoot = getTargetParts(player)
			local liveAim = player.Character and findBodyPart(player.Character, aimNames)
			if not (liveRoot and liveAim) then
				return nil
			end
			return findShootSpot(liveRoot, liveAim, { getCharacter(), player.Character, Workspace.CurrentCamera })
		end)
		if not reached then
			restoreKillMods(settings)
			notify("Could not reach " .. player.Name .. ".")
			teleportCharacter(returnCFrame)
			return
		end

		waitAcClear(1.25)
		root = getRoot()
		zeroRootMotion(root)

		local shots = 0
		local deadline = os.clock() + maxTime
		while os.clock() < deadline and shots < maxShots and not Arsenic.Destroyed do
			root = getRoot()
			character = getCharacter()
			targetCharacter = player.Character
			targetHumanoid = targetCharacter and targetCharacter:FindFirstChildOfClass("Humanoid")
			targetRoot = targetCharacter and targetCharacter:FindFirstChild("HumanoidRootPart")
			aimPart = targetCharacter and findBodyPart(targetCharacter, aimNames)
			handle = tool:FindFirstChild("Handle")
			firePoint = handle and handle:FindFirstChild("GunFirePoint")
			if not (root and character and targetHumanoid and targetRoot and aimPart and handle and firePoint) then
				break
			end
			if mode == "kill" and targetHumanoid.Health <= 0 then
				break
			end
			if tool.Parent ~= character then
				break
			end

			local ignore = { character, targetCharacter, Workspace.CurrentCamera }
			local origin = firePoint.WorldPosition
			if (aimPart.Position - origin).Magnitude > 12 or not hasLineOfSight(origin, aimPart.Position, ignore) then
				teleportCharacter(findShootSpot(targetRoot, aimPart, ignore))
				waitAcClear(0.85)
				root = getRoot()
				handle = tool:FindFirstChild("Handle")
				firePoint = handle and handle:FindFirstChild("GunFirePoint")
				if not (root and firePoint) then
					break
				end
				origin = firePoint.WorldPosition
			end

			zeroRootMotion(root)
			if targetRoot then
				root.CFrame = CFrame.lookAt(
					root.Position,
					Vector3.new(targetRoot.Position.X, root.Position.Y, targetRoot.Position.Z)
				)
				zeroRootMotion(root)
			end

			-- Prefer the gun's own Fire (Visualize + VisualizeBullet), then our Visualize mirror, then InflictTarget.
			if fire then
				pcall(fire, handle, aimPart.Position)
			end
			fireVisualize(tool, handle, firePoint, aimPart.Position, settings)
			if inflict then
				fireInflict(inflict, tool, targetHumanoid, targetRoot, aimPart, damage, settings, firePoint.WorldPosition)
			end
			syncMag(tool)
			shots += 1
			task.wait(shotDelay)
		end

		restoreKillMods(settings)
		teleportCharacter(returnCFrame)

		if mode == "kill" then
			if targetHumanoid and targetHumanoid.Health <= 0 then
				notify(player.Name .. " was killed.")
			else
				notify(("Fired %d shots at %s but they are still alive."):format(shots, player.Name))
			end
		else
			notify(("Shot %s in the leg (%d shots)."):format(player.Name, shots))
		end
	end

	return function()
		shootPlayer("kill")
	end, function()
		shootPlayer("ragdoll")
	end
end)()

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

-- Sit when the seat is already nearby. Long-range CFrame snaps onto distant cars get
-- eaten by the anti-teleport — callers should bring the car/seat to the player first.
local function instantSit(seat, maxSnap)
	local humanoid, root = getHumanoid(), getRoot()
	if not (humanoid and root) then
		return false
	end
	maxSnap = maxSnap or 45
	exitSeat(humanoid)
	seat.Disabled = false
	for _ = 1, 4 do
		if seat.Occupant or not seat.Parent then
			break
		end
		if (root.Position - seat.Position).Magnitude > maxSnap then
			return false
		end
		root.AssemblyLinearVelocity = Vector3.zero
		root.AssemblyAngularVelocity = Vector3.zero
		root.CFrame = seat.CFrame + Vector3.new(0, 1.5, 0)
		pcall(seat.Sit, seat, humanoid)
		if firetouchinterest then
			pcall(firetouchinterest, root, seat, 0)
			pcall(firetouchinterest, root, seat, 1)
		end
		local deadline = os.clock() + 0.35
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

-- Same instant teleport other TB3 scripts use (hazura/nazuro, open-source BypassTp):
-- ChangeState(0) → wait until LastACPos clears → set HumanoidRootPart.CFrame.
Arsenic._instantBypassTeleport = function(goal)
	local humanoid, root = getHumanoid(), getRoot()
	if not (humanoid and root) then
		return false
	end
	local function resolve()
		if type(goal) == "function" then
			return goal()
		end
		return goal
	end
	local target = resolve()
	if typeof(target) ~= "CFrame" then
		return false
	end
	local mapFloor = 220
	local lift = getStandHeight(humanoid, root)
	local preferY = target.Position.Y
	local groundY = findGroundY(
		Vector3.new(target.Position.X, math.max(preferY, 252) + 20, target.Position.Z),
		nil,
		preferY
	)
	if not groundY or groundY < mapFloor then
		groundY = math.max(preferY - lift, 252)
	end
	-- Never hoist the player onto a roof above the requested stand height.
	if groundY > preferY + 4 then
		groundY = preferY - lift
		if groundY < mapFloor then
			groundY = preferY
		end
	end
	local dest = CFrame.new(target.Position.X, groundY + lift, target.Position.Z) * (target - target.Position)

	exitSeat(humanoid)
	pcall(function()
		humanoid:ChangeState(0)
	end)
	local clearDeadline = os.clock() + 2
	while LocalPlayer:GetAttribute("LastACPos") and os.clock() < clearDeadline and not Arsenic.Destroyed do
		task.wait()
	end
	root.CFrame = dest
	humanoid.PlatformStand = false
	root.AssemblyLinearVelocity = Vector3.zero
	root.AssemblyAngularVelocity = Vector3.zero
	task.wait()
	root = getRoot()
	humanoid = getHumanoid()
	if not (root and humanoid) then
		return false
	end
	-- One quick retry if the AC stamped a pull-back mid-snap.
	if (root.Position - dest.Position).Magnitude > 12 then
		pcall(function()
			humanoid:ChangeState(0)
		end)
		clearDeadline = os.clock() + 1.5
		while LocalPlayer:GetAttribute("LastACPos") and os.clock() < clearDeadline and not Arsenic.Destroyed do
			task.wait()
		end
		target = resolve()
		if typeof(target) == "CFrame" then
			preferY = target.Position.Y
			groundY = findGroundY(
				Vector3.new(target.Position.X, math.max(preferY, 252) + 20, target.Position.Z),
				nil,
				preferY
			) or groundY
			if groundY > preferY + 4 then
				groundY = math.max(preferY - lift, mapFloor)
			end
			dest = CFrame.new(target.Position.X, math.max(groundY, mapFloor) + lift, target.Position.Z)
				* (target - target.Position)
		end
		root.CFrame = dest
		root.AssemblyLinearVelocity = Vector3.zero
		root.AssemblyAngularVelocity = Vector3.zero
		task.wait(0.05)
		root = getRoot()
	end
	if not root or root.Position.Y < mapFloor then
		return false
	end
	if (root.Position - dest.Position).Magnitude <= 14 then
		lastSafeCFrame = root.CFrame
		return true
	end
	return false
end

-- Fast map-Seat sit → snap → stand (X-DK style). Used when Instant CFrame gets eaten.
Arsenic._seatSnapTeleport = function(goal)
	local humanoid, root = getHumanoid(), getRoot()
	if not (humanoid and root) or root.Position.Y < 220 then
		return false
	end
	local function resolve()
		if type(goal) == "function" then
			return goal()
		end
		return goal
	end
	local target = resolve()
	if typeof(target) ~= "CFrame" then
		return false
	end
	local hub = Vector3.new(-1487.57837, 251.759018, -408.810089)
	local seat, bestDist
	for _, inst in ipairs(Workspace:GetDescendants()) do
		if inst:IsA("Seat") and inst.Parent and not inst.Occupant and not inst.Disabled then
			local dist = (inst.Position - hub).Magnitude
			if not bestDist or dist < bestDist then
				seat, bestDist = inst, dist
				if dist < 2 then
					break
				end
			end
		end
	end
	if not seat then
		return false
	end
	local home = seat.CFrame
	local preferY = target.Position.Y
	local destGround = findGroundY(
		Vector3.new(target.Position.X, math.max(preferY, 252) + 20, target.Position.Z),
		nil,
		preferY
	)
	if destGround and destGround > preferY + 4 then
		destGround = preferY
	end
	if not destGround or destGround < 220 then
		return false
	end
	local dest = Vector3.new(target.Position.X, destGround + 1, target.Position.Z)
	exitSeat(humanoid)
	local ok = pcall(function()
		local clearDeadline = os.clock() + 1.5
		while LocalPlayer:GetAttribute("LastACPos") and os.clock() < clearDeadline do
			task.wait()
		end
		seat.Disabled = false
		seat.CFrame = root.CFrame
		task.wait(0.55)
		pcall(seat.Sit, seat, humanoid)
		local sitDeadline = os.clock() + 1.2
		while humanoid.SeatPart ~= seat and os.clock() < sitDeadline do
			pcall(seat.Sit, seat, humanoid)
			RunService.Heartbeat:Wait()
		end
		if humanoid.SeatPart ~= seat then
			error("no seat", 0)
		end
		task.wait(0.55)
		target = resolve()
		if typeof(target) == "CFrame" then
			preferY = target.Position.Y
			destGround = findGroundY(
				Vector3.new(target.Position.X, math.max(preferY, 252) + 20, target.Position.Z),
				nil,
				preferY
			) or destGround
			if destGround > preferY + 4 then
				destGround = preferY
			end
			dest = Vector3.new(target.Position.X, destGround + 1, target.Position.Z)
		end
		seat.CFrame = CFrame.new(dest) * (target - target.Position)
		task.wait(0.5)
		humanoid.Sit = false
		pcall(function()
			humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
		end)
		task.wait()
		forceUnseat(humanoid, seat)
		root = getRoot()
		if root then
			root.CFrame = CFrame.new(dest.X, destGround + 3, dest.Z) * (target - target.Position)
			root.AssemblyLinearVelocity = Vector3.zero
			lastSafeCFrame = root.CFrame
		end
	end)
	pcall(function()
		if seat.Parent then
			seat.CFrame = CFrame.new(home.Position.X, home.Position.Y - 100, home.Position.Z)
			task.delay(0.8, function()
				if seat.Parent then
					seat.CFrame = home
				end
			end)
		end
	end)
	root = getRoot()
	return ok and root and root.Position.Y >= 220 and (root.Position - dest).Magnitude <= 20
end

-- With tweenLast the car only covers part of the trip and the rest is a Tween on foot.
-- Sit in a Seat (local or map), then move the seat — anti-teleport largely ignores seated players.
Arsenic._seatBypassTeleport = function(goal)
	local humanoid, root = getHumanoid(), getRoot()
	if not (humanoid and root) then
		return false
	end
	if root.Position.Y < 220 then
		if lastSafeCFrame and lastSafeCFrame.Position.Y >= 220 then
			root.CFrame = lastSafeCFrame
			root.AssemblyLinearVelocity = Vector3.zero
		end
		return false
	end
	local function resolve()
		if type(goal) == "function" then
			return goal()
		end
		return goal
	end
	local target = resolve()
	if not target then
		return false
	end

	local mapFloor = 220
	local ownedSeat = false
	local home = nil
	local seat

	-- 1) Invisible local Seat (most reliable). 2) Known map hub Seat.
	local okMake, made = pcall(function()
		local s = Instance.new("Seat")
		s.Name = "ArsenicTravelSeat"
		s.Anchored = true
		s.CanCollide = false
		s.CanTouch = false
		s.CanQuery = false
		s.Transparency = 1
		s.Size = Vector3.new(2, 0.4, 2)
		s.Disabled = false
		s.Parent = Workspace
		return s
	end)
	if okMake and made then
		seat = made
		ownedSeat = true
	else
		local hub = Vector3.new(-1487.57837, 251.759018, -408.810089)
		local bestDist
		for _, inst in ipairs(Workspace:GetDescendants()) do
			if inst:IsA("Seat") and inst.Parent and not inst.Occupant and not inst.Disabled then
				local dist = (inst.Position - hub).Magnitude
				if not bestDist or dist < bestDist then
					seat, bestDist = inst, dist
					if dist < 2 then
						break
					end
				end
			end
		end
		if seat then
			home = seat.CFrame
		end
	end
	if not seat then
		return false
	end

	exitSeat(humanoid)
	local arrived = false
	local ok = pcall(function()
		for _ = 1, 20 do
			if LocalPlayer:GetAttribute("LastACPos") then
				task.wait()
			else
				break
			end
		end
		root = getRoot()
		if not root or root.Position.Y < mapFloor then
			error("void", 0)
		end
		local standY = findGroundY(Vector3.new(root.Position.X, root.Position.Y + 40, root.Position.Z))
		if not standY or standY < mapFloor then
			standY = math.max(root.Position.Y, 252)
		end

		seat.Disabled = false
		seat.Anchored = true
		seat.CFrame = CFrame.new(root.Position.X, standY + 1.2, root.Position.Z)
		-- Brief settle so Sit sticks (open-source hubs wait ~2s here).
		task.wait(teleportMethod == "Instant" and 0.85 or 1.35)
		pcall(seat.Sit, seat, humanoid)
		local sitDeadline = os.clock() + 2.5
		while humanoid.SeatPart ~= seat and os.clock() < sitDeadline do
			root = getRoot()
			if not root or root.Position.Y < mapFloor then
				error("void", 0)
			end
			seat.CFrame = CFrame.new(root.Position.X, standY + 1.2, root.Position.Z)
			pcall(seat.Sit, seat, humanoid)
			RunService.Heartbeat:Wait()
		end
		if humanoid.SeatPart ~= seat then
			error("no seat", 0)
		end
		task.wait(0.2)

		local function destFrom(goalCf)
			local preferY = goalCf.Position.Y
			local destGround = findGroundY(
				Vector3.new(goalCf.Position.X, math.max(preferY, 252) + 20, goalCf.Position.Z),
				nil,
				preferY
			)
			if destGround and destGround > preferY + 4 then
				destGround = preferY
			end
			if not destGround or destGround < mapFloor then
				return nil
			end
			return Vector3.new(goalCf.Position.X, destGround + 1.2, goalCf.Position.Z), destGround
		end

		target = resolve()
		if not target then
			error("no goal", 0)
		end
		local dest, destGround = destFrom(target)
		if not dest then
			error("no ground", 0)
		end

		-- Instant: one seated snap. Tween: glide the Seat while still sitting.
		if teleportMethod == "Instant" then
			seat.CFrame = CFrame.new(dest) * (target - target.Position)
			task.wait(0.45)
		else
			travelling = true
			local topSpeed = math.max(Arsenic.Values.TeleportSpeed, MIN_TELEPORT_SPEED)
			local startSpeed = math.min(TELEPORT_START_SPEED, topSpeed)
			local started = os.clock()
			local deadline = os.clock() + MAX_FOOT_TRIP_SECONDS
			local expected = seat.Position
			while os.clock() < deadline and not Arsenic.Destroyed do
				local dt = RunService.Heartbeat:Wait()
				if humanoid.SeatPart ~= seat or humanoid.Health <= 0 then
					error("unsit", 0)
				end
				local resolved = resolve()
				if not resolved then
					error("no goal", 0)
				end
				target = resolved
				local nextDest, nextGround = destFrom(target)
				if not nextDest then
					error("no ground", 0)
				end
				dest, destGround = nextDest, nextGround
				local current = seat.Position
				if (current - expected).Magnitude > 18 then
					-- Soft pull-back while seated: re-anchor and continue slower.
					topSpeed = slowTripSpeed(topSpeed)
					startSpeed = math.min(startSpeed, topSpeed)
					started = os.clock()
				end
				local ramp = math.clamp((os.clock() - started) / TELEPORT_RAMP, 0, 1)
				local speed = startSpeed + (topSpeed - startSpeed) * ramp * ramp
				local offset = dest - current
				local step = speed * math.clamp(dt, 0, 0.05)
				if offset.Magnitude <= math.max(step, 4) then
					seat.CFrame = CFrame.new(dest) * (target - target.Position)
					break
				end
				local nextPos = current + offset.Unit * step
				nextPos = Vector3.new(nextPos.X, math.max(nextPos.Y, mapFloor + 1), nextPos.Z)
				-- Keep seat on ground along the path when possible.
				local midGround = findGroundY(Vector3.new(nextPos.X, nextPos.Y + 40, nextPos.Z))
				if midGround and midGround >= mapFloor then
					nextPos = Vector3.new(nextPos.X, midGround + 1.2, nextPos.Z)
				end
				local flat = Vector3.new(offset.X, 0, offset.Z)
				seat.CFrame = flat.Magnitude > 0.1 and CFrame.lookAt(nextPos, nextPos + flat) or CFrame.new(nextPos)
				seat.AssemblyLinearVelocity = Vector3.zero
				seat.AssemblyAngularVelocity = Vector3.zero
				expected = nextPos
			end
			travelling = false
		end

		task.wait(0.35)
		forceUnseat(humanoid, seat)
		task.wait(0.08)
		root = getRoot()
		if root then
			root.CFrame = CFrame.new(dest.X, destGround + 3, dest.Z) * (target - target.Position)
			root.AssemblyLinearVelocity = Vector3.zero
			lastSafeCFrame = root.CFrame
		end
		arrived = root and (root.Position - dest).Magnitude <= 22 and root.Position.Y >= mapFloor
	end)
	travelling = false

	pcall(function()
		if ownedSeat then
			if seat and seat.Parent then
				seat:Destroy()
			end
		elseif seat and seat.Parent and home then
			seat.CFrame = home
		end
	end)

	if not ok or not arrived then
		root = getRoot()
		if root and root.Position.Y < mapFloor and lastSafeCFrame then
			root.CFrame = lastSafeCFrame
			root.AssemblyLinearVelocity = Vector3.zero
		end
		return false
	end
	return true
end

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
				widenSimulationRadius()
				restoreCar = ghostCar(car)
				-- Bring the car to the player first. Snapping the character onto a distant
				-- seat is what the anti-teleport was catching (then every trip fell back to Tween).
				local rootNow = getRoot()
				if not rootNow or rootNow.Position.Y < 220 then
					return "noseat"
				end
				if (seat.Position - rootNow.Position).Magnitude > 35 then
					local bringY = findGroundY(Vector3.new(rootNow.Position.X, rootNow.Position.Y + 40, rootNow.Position.Z))
					if not bringY or bringY < 220 then
						bringY = math.max(rootNow.Position.Y, 252)
					end
					local bring = CFrame.new(rootNow.Position.X, bringY + 3, rootNow.Position.Z) * flatRotation(home)
					for _ = 1, 10 do
						if not car.Parent then
							break
						end
						car:PivotTo(bring)
						seat.AssemblyLinearVelocity = Vector3.zero
						seat.AssemblyAngularVelocity = Vector3.zero
						if (seat.Position - rootNow.Position).Magnitude <= 35 and seat.Position.Y >= 220 then
							break
						end
						RunService.Heartbeat:Wait()
					end
				end
				if seat.Position.Y < 220 then
					return "noseat"
				end
				if not instantSit(seat, 50) then
					return "noseat"
				end
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

			if restoreCar then
				restoreCar()
			end
			if ok and result == "noseat" then
				-- Try the next free car.
			else
				if not carReleased then
					-- Put the borrowed car back near its home if we did not finish cleanly.
					pcall(returnCarInBackground, car, seat, home, humanoid)
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

	Arsenic.BakedStoreItems = {
		["DeliTools"] = {
			["BlackGloves"] = { Price = 10 },
			["BluCamoGloves"] = { Price = 67 },
			["BluGloves"] = { Price = 10 },
			["BluShiestyCam"] = { Price = 67 },
			["CamoGloves"] = { Price = 10 },
			["CamoShiesty"] = { Price = 10 },
			["Dice"] = { Price = 25 },
			["PinkCamoGloves"] = { Price = 67 },
			["PurpleCamoGloves"] = { Price = 67 },
			["RawChicken"] = { Price = 10 },
			["RawSteak"] = { Price = 10 },
			["RedCamoGloves"] = { Price = 67 },
			["ReddyGloves"] = { Price = 25 },
			["RedGloves"] = { Price = 67 },
			["Shiesty"] = { Price = 25 },
			["ShiestyReddy"] = { Price = 25 },
			["Test Item"] = { Price = 100 },
			["Water"] = { Price = 10 },
			["WhiteGloves"] = { Price = 10 },
			["WhiteShiesty"] = { Price = 43 },
			["YelloCamoGloves"] = { Price = 67 },
			["YelloShiesty"] = { Price = 67 },
		},
		["ThaShop"] = {
			[".10mm"] = { Price = 45 },
			[".9mm"] = { Price = 45 },
			[".Bullets"] = { Price = 45 },
			[".Drum"] = { Price = 70 },
			[".Extended"] = { Price = 50 },
			[".FNMag"] = { Price = 45 },
			["5.56"] = { Price = 59 },
			["7.62"] = { Price = 75 },
			["Bandage"] = { Price = 350 },
			["Dice"] = { Price = 25 },
			["FakeCard"] = { Price = 700 },
			["FijiWater"] = { Price = 48 },
			["FreshWater"] = { Price = 48 },
			["Ice-Fruit Bag"] = { Price = 2500 },
			["Ice-Fruit Cupz"] = { Price = 150 },
			["Lemonade"] = { Price = 500 },
			["RawSteak"] = { Price = 10 },
			["Screw"] = { Price = 2000 },
			["Shiesty"] = { Price = 75 },
			["Sledge Hammer"] = { Price = 400 },
			["WhiteShiesty"] = { Price = 48 },
		},
		["ThaShop2"] = {
			["100Rnd Hellpup"] = { Price = 19000, GamepassId = 1784312552 },
			["308100RndAR"] = { Price = 22000, GamepassId = 1832542170 },
			["5inch 100Rnd"] = { Price = 19000, GamepassId = 1783962561 },
			["5inch Micro-ARP"] = { Price = 40000, GamepassId = 1696237544 },
			["60RMag ARP"] = { Price = 14000, GamepassId = 1831724214 },
			["60RndHellPup"] = { Price = 10000, GamepassId = 1686608581 },
			["BinaryARP"] = { Price = 30000, GamepassId = 1246733357 },
			["BinaryDrac"] = { Price = 30000, GamepassId = 1272857185 },
			["BinaryG17"] = { Price = 30000, GamepassId = 1124318872 },
			["CyanButton"] = { Price = 30000, GamepassId = 1220987746 },
			["FRT M&P"] = { Price = 15000, GamepassId = 1631200674 },
			["FRT M&P2"] = { Price = 29000, GamepassId = 1631456644 },
			["Fully-300BlackOut"] = { Price = 40000, GamepassId = 1404059560 },
			["Fully-ARB"] = { Price = 40000, GamepassId = 1517734380 },
			["Fully-BlakDrac"] = { Price = 40000, GamepassId = 1630688308 },
			["Fully-Hellpup"] = { Price = 40000, GamepassId = 1832422095 },
			["Fully-M16"] = { Price = 40000, GamepassId = 2002394253 },
			["Fully-MicroAR"] = { Price = 35000, GamepassId = 1123822489 },
			["G17Button"] = { Price = 33000, GamepassId = 1404820349 },
			["G19XButton"] = { Price = 30000, GamepassId = 1404814248 },
			["G20-FRT"] = { Price = 28000, GamepassId = 1784328459 },
			["G21Button"] = { Price = 30000, GamepassId = 1257338709 },
			["G22100Rnd"] = { Price = 7000, GamepassId = 1272697162 },
			["G22Button"] = { Price = 23000, GamepassId = 1434670388 },
			["G26Button"] = { Price = 30000, GamepassId = 1516022464 },
			["G27Button"] = { Price = 30000, GamepassId = 1434584492 },
			["G29Button"] = { Price = 33000, GamepassId = 1629892729 },
			["G29Switch"] = { Price = 33000, GamepassId = 1630952655 },
			["G40Button"] = { Price = 30000, GamepassId = 1123616883 },
			["G45Button"] = { Price = 31000, GamepassId = 1784462461 },
			["GhostButton"] = { Price = 32000, GamepassId = 2001290298 },
			["GhostSwitch"] = { Price = 32000, GamepassId = 2002172259 },
			["Glock19Button"] = { Price = 30000, GamepassId = 1517500372 },
			["Glock19x BluSwitch"] = { Price = 29000, GamepassId = 1784038465 },
			["Glock29Button"] = { Price = 29000, GamepassId = 1686946438 },
			["Grey100RNDARP"] = { Price = 23000, GamepassId = 1518246351 },
			["Incognito G20"] = { Price = 30000, GamepassId = 1630286810 },
			["M&PDrum"] = { Price = 9000, GamepassId = 1687233322 },
			["M16-100RND"] = { Price = 14000, GamepassId = 1999641303 },
			["MB47"] = { Price = 7600 },
			["MFR-Rifle"] = { Price = 8500, GamepassId = 1272327232 },
			["Micro7.62 ARPB"] = { Price = 7000, GamepassId = 1259288561 },
			["Micro7.62 ARPR"] = { Price = 7000, GamepassId = 1256928907 },
			["P80Switch"] = { Price = 29000, GamepassId = 1686600633 },
			["TX22-FRT"] = { Price = 25000, GamepassId = 1832950141 },
		},
		["2CityGuns"] = {
			[".308"] = { Price = 80 },
			[".9mm"] = { Price = 35 },
			[".Drum"] = { Price = 100 },
			[".Extended"] = { Price = 50 },
			["100Rnd308"] = { Price = 22000 },
			["4inch-BinaryARP"] = { Price = 38000 },
			["5.56"] = { Price = 80 },
			["7.62"] = { Price = 90 },
			["ARPistol"] = { Price = 6000 },
			["Bandage"] = { Price = 350 },
			["Binary-G27"] = { Price = 32000 },
			["Card"] = { Price = 4000 },
			["DDM4-100Rn"] = { Price = 14000 },
			["DDM4-D"] = { Price = 10000 },
			["DDM4-S"] = { Price = 10000 },
			["Fully ARTan"] = { Price = 38000 },
			["Fully-AK47"] = { Price = 40000 },
			["Fully-ARPR"] = { Price = 40000 },
			["G19DAGGER-BUTTON"] = { Price = 32000 },
			["G19x-FRT"] = { Price = 32000 },
			["G19XExt"] = { Price = 6000 },
			["Incognito G40"] = { Price = 32000 },
			["Kiger-9C"] = { Price = 3000 },
			["Kiger9CButton"] = { Price = 32000 },
			["Lemonade"] = { Price = 500 },
			["MPBodyGuard"] = { Price = 800 },
			["P80G19-FRT"] = { Price = 29000 },
			["PLR-16"] = { Price = 5000 },
			["PSADAGGER"] = { Price = 3000 },
			["Purple ARP Flag"] = { Price = 8000 },
			["Shiesty"] = { Price = 70 },
			["StrikePad"] = { Price = 3000 },
			["Swiss Screw"] = { Price = 2000 },
			["VP9-FRT C"] = { Price = 20000 },
		},
		["PrisonGuns"] = {
			["Blade"] = { Price = 320 },
			["Chair"] = { Price = 150 },
			["Cleaver"] = { Price = 300 },
			["Dice"] = { Price = 25 },
			["Phone"] = { Price = 250 },
			["WAKIS"] = { Price = 5 },
		},
		["NewShopTools"] = {
			["Bandage"] = { Price = 350 },
		},
		["NewShopTools5"] = {
			["223Tan"] = { Price = 7000 },
			["ARPistol"] = { Price = 6000 },
			["BlueTips / Switch"] = { Price = 30000 },
			["ClearMagARPTan"] = { Price = 7500 },
			["ClearMagDrac"] = { Price = 7000 },
			["Draco"] = { Price = 6000 },
			["G19Switch"] = { Price = 30000 },
			["G20Button"] = { Price = 30000 },
			["Glock22"] = { Price = 4500 },
			["HPBrowning Ext"] = { Price = 6000 },
			["Lemonade"] = { Price = 500 },
			["MicroARPistolP"] = { Price = 7500 },
			["OrangeButton"] = { Price = 30000 },
			["SilvaClearMagARP"] = { Price = 7500 },
			["SpringField XD"] = { Price = 4300 },
		},
		["NewShopTools6"] = {
			["FijiWater"] = { Price = 300 },
			["Seeds"] = { Price = 4500 },
			["SugarBag"] = { Price = 3300 },
		},
	}

local function getStoreItems(store, forceRefresh)
	if not store or not store.items then
		return {}
	end
	if storeItemCache[store] and not forceRefresh then
		return storeItemCache[store]
	end
	local items = {}
	local function merge(name, info)
		if type(name) ~= "string" or name == "" then
			return
		end
		local entry = type(info) == "number" and { Price = info } or (type(info) == "table" and info or {})
		local existing = items[name]
		if not existing then
			items[name] = entry
			return
		end
		if existing.Price == nil and entry.Price ~= nil then
			existing.Price = entry.Price
		end
		if existing.GamepassId == nil and entry.GamepassId ~= nil then
			existing.GamepassId = entry.GamepassId
		end
	end
	local module = ReplicatedStorage:FindFirstChild(store.items)
	if module and module:IsA("ModuleScript") then
		local ok, result = pcall(require, module)
		if ok and type(result) == "table" then
			for itemName, info in pairs(result) do
				merge(itemName, info)
			end
		end
	end
	local baked = Arsenic.BakedStoreItems and Arsenic.BakedStoreItems[store.items]
	if baked then
		for itemName, info in pairs(baked) do
			merge(itemName, info)
		end
	end
	local folder = ReplicatedStorage:FindFirstChild(store.stock or "")
	if folder then
		for _, child in ipairs(folder:GetChildren()) do
			if child:IsA("ValueBase") then
				merge(child.Name, items[child.Name])
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

local function snapshotToolsSet()
	local owned = {}
	for _, tool in ipairs(findTools(function()
		return true
	end)) do
		owned[tool] = true
	end
	return owned
end

local function clickGuiButton(button)
	if not button then
		return false
	end
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
	return pcall(function()
		button.MouseButton1Click:Fire()
	end)
end

local function getStoreGui(store)
	local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
	local gui = playerGui and store.gui and playerGui:FindFirstChild(store.gui)
	return gui and gui:IsA("ScreenGui") and gui or nil
end

-- Buy by selecting the shop list row then Buy — same path as a real click (needed for Swiss Screw).
local function purchaseItemViaShopGui(store, item)
	local gui = getStoreGui(store)
	if not gui then
		return false, "shop UI not found"
	end
	gui.Enabled = true
	task.wait(0.2)
	local list = gui:FindFirstChild("List", true)
	local selected = false
	for _, frame in ipairs(list and list:GetChildren() or {}) do
		if frame:IsA("Frame") then
			local itemLabel = frame:FindFirstChild("Item") or frame:FindFirstChild("Item", true)
			local rowButton = frame:FindFirstChild("Button") or frame:FindFirstChildWhichIsA("TextButton", true)
			if itemLabel and itemLabel:IsA("TextLabel") and itemLabel.Text == item and rowButton then
				clickGuiButton(rowButton)
				selected = true
				task.wait(0.15)
				break
			end
		end
	end
	if not selected then
		return false, item .. " was not listed in " .. store.name
	end
	local buyButton = gui:FindFirstChild("Buy", true)
	if not (buyButton and buyButton:IsA("GuiButton")) then
		local bottom = gui:FindFirstChild("Bottom", true)
		buyButton = bottom and (bottom:FindFirstChild("Buy") or bottom:FindFirstChildWhichIsA("TextButton", true))
	end
	if not buyButton then
		return false, "Buy button not found"
	end
	local ownedBefore = countOwned(item)
	local toolsBefore = snapshotToolsSet()
	clickGuiButton(buyButton)
	local deadline = os.clock() + 3
	repeat
		if countOwned(item) > ownedBefore then
			return true
		end
		-- Reject a plain "Screw" showing up when we asked for Swiss Screw.
		if item == "Swiss Screw" then
			for _, tool in ipairs(findTools(function(tool)
				return tool.Name == "Screw" and not toolsBefore[tool]
			end)) do
				return false, "shop gave a regular Screw instead of Swiss Screw"
			end
		end
		task.wait(0.1)
	until os.clock() > deadline
	return countOwned(item) > ownedBefore, item .. " did not arrive"
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
		local bought = false
		local ok, result = true, nil
		-- Swiss Screw must be bought through the shop UI row — remote-only buys often grant a regular Screw.
		if item == "Swiss Screw" then
			ok, result = purchaseItemViaShopGui(store, item)
			lastResult = result
			bought = ok == true and countOwned("Swiss Screw") > ownedBefore
			if not bought and type(result) == "string" then
				-- Fall back to remote, but only accept a real "Swiss Screw" tool name.
				local toolsBefore = snapshotToolsSet()
				ok, result = pcall(remote.InvokeServer, remote, item)
				lastResult = result
				local deadline = os.clock() + 2.5
				repeat
					if countOwned("Swiss Screw") > ownedBefore then
						bought = true
						break
					end
					for _, tool in ipairs(findTools(function(tool)
						return tool.Name == "Screw" and not toolsBefore[tool]
					end)) do
						result = "remote gave a regular Screw instead of Swiss Screw"
						bought = false
						break
					end
					if result == "remote gave a regular Screw instead of Swiss Screw" then
						break
					end
					task.wait(0.1)
				until os.clock() > deadline
			end
		else
			ok, result = pcall(remote.InvokeServer, remote, item)
			lastResult = result
			local deadline = os.clock() + 1.5
			repeat
				local stockNow = getStock(store, item)
				if countOwned(item) > ownedBefore or (stockBefore and stockNow and stockNow < stockBefore) then
					bought = true
					break
				end
				task.wait(0.1)
			until os.clock() > deadline
		end

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

-- Tries stores that sell the item, in-stock and nearest first.
-- optional preferredStoreName buys from that listing when possible.
local function buyItem(item, preferredStoreName)
	local candidates = {}
	local missingPass = nil
	for _, store in ipairs(STORES) do
		if getStoreItems(store)[item] then
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
		if preferredStoreName then
			if a.name == preferredStoreName then
				return true
			end
			if b.name == preferredStoreName then
				return false
			end
		end
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

-- One dropdown row per store listing (same item can appear multiple times).
local function getAllStoreItems(forceRefresh)
	local list = {}
	local map = {}
	for _, store in ipairs(STORES) do
		if store.items then
			for itemName, info in pairs(getStoreItems(store, forceRefresh)) do
				local price = info and tonumber(info.Price) or nil
				local label = price and ("%s — $%s · %s"):format(itemName, tostring(price), store.name)
					or ("%s · %s"):format(itemName, store.name)
				if not map[label] then
					map[label] = { item = itemName, store = store.name }
					table.insert(list, label)
				end
			end
		end
	end
	table.sort(list, function(a, b)
		return a:lower() < b:lower()
	end)
	Arsenic.BuyOptionMap = map
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
	Arsenic.Values.DupeTiming = "Normal"
	Arsenic.Values.DupeUsePing = true
	Arsenic.Values.DupeManualDelay = 0.27
	Arsenic.Values.DupeStoreDelayOffset = 0
	Arsenic.Values.DupeBackpackWait = 0.5
	Arsenic.Values.DupeRemoveWait = 2.5
	Arsenic.Values.DupeFinishWait = 1
	Arsenic.Values.DupeListPrice = 99999
	Arsenic.Values.DupeParkExtras = true
	Arsenic.Values.DupeReequip = true
	Arsenic.Values.DupeInterval = 2

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

	-- Fire without a fresh longTrip when we are already inside the prompt's range.
	local function firePromptInRange(prompt, forceInstant)
		if not (prompt and prompt.Parent) then
			return false
		end
		local position = promptPosition(prompt)
		local reach = math.max((prompt.MaxActivationDistance or 3) - 0.25, 1.25)
		if not position or distanceTo(position) > reach then
			return false
		end
		firePrompt(prompt, forceInstant)
		return true
	end

	local function usePrompt(prompt, forceInstant)
		for _ = 1, 2 do
			if not (prompt and prompt.Parent) then
				return false
			end
			local position = promptPosition(prompt)
			-- Stand closer than Max-1: GrabPrompt is only ~3 studs and used to miss the register.
			local reach = math.max((prompt.MaxActivationDistance or 3) * 0.55, 1.25)
			if not (position and goNear(position, reach)) then
				return false
			end
			local flagMark = teleportFlagCount
			firePrompt(prompt, forceInstant)
			task.wait(forceInstant and 0.05 or 0.25)
			if teleportFlagCount == flagMark and distanceTo(position) <= math.max(prompt.MaxActivationDistance or 3, reach) + 1 then
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
					local waitFor = interval
					if type(interval) == "function" then
						waitFor = interval()
					end
					task.wait(typeof(waitFor) == "number" and waitFor or 1)
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

	-- Bank / wallet / dirty stack all ceiling at $990,000 (same HUD cap). Deposits max $30k each.
	local MONEY_CAP = 990000
	local DEPOSIT_CHUNK = 30000
	local LOOP_DEPOSIT_TARGET = 900000
	-- Learned from the ATM tip label ("On cooldown") between successful deposits.
	local measuredDepositCooldown = nil
	local lastDepositSuccessAt = 0

	local function bankRoom()
		return math.max(0, MONEY_CAP - getStat("Bank"))
	end

	local function findAtmGui()
		local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
		if not playerGui then
			return nil
		end
		local direct = playerGui:FindFirstChild("ATMGui")
		if direct then
			return direct
		end
		for _, gui in ipairs(playerGui:GetChildren()) do
			if gui:IsA("ScreenGui") and (gui.Name:upper():find("ATM", 1, true) or gui.Name:upper():find("BANK", 1, true)) then
				return gui
			end
		end
		return nil
	end

	-- Tip label under Deposit/Withdraw flips to "On cooldown" while the server blocks depo/with.
	local function getAtmStatusLabel(gui)
		gui = gui or findAtmGui()
		if not gui then
			return nil
		end
		local best
		for _, node in ipairs(gui:GetDescendants()) do
			if node:IsA("TextLabel") then
				local text = tostring(node.Text or "")
				local lower = text:lower()
				if lower:find("cooldown", 1, true) or lower:find("tip:", 1, true) or lower:find("/check", 1, true) then
					best = node
					if lower:find("cooldown", 1, true) then
						return node
					end
				end
			end
		end
		return best
	end

	local function atmCooldownInfo()
		local label = getAtmStatusLabel()
		if not label then
			return false, nil, nil
		end
		local text = tostring(label.Text or "")
		local lower = text:lower()
		if not lower:find("cooldown", 1, true) then
			return false, nil, text
		end
		local seconds = tonumber(lower:match("(%d+%.?%d*)%s*s"))
			or tonumber(lower:match("(%d+%.?%d*)%s*sec"))
			or tonumber(lower:match("cooldown[^%d]*(%d+%.?%d*)"))
			or tonumber(lower:match("(%d+%.?%d*)"))
		return true, seconds, text
	end

	-- Wait out "On cooldown"; learn the exact duration the first time it clears.
	local function waitAtmCooldown(active)
		local onCooldown, seconds = atmCooldownInfo()
		if not onCooldown then
			-- Honor a measured gap even if the tip label already flipped back.
			if measuredDepositCooldown and lastDepositSuccessAt > 0 then
				local remain = measuredDepositCooldown - (os.clock() - lastDepositSuccessAt)
				if remain > 0.05 then
					notify(string.format("ATM cooldown: waiting %.1fs...", remain))
					local deadline = os.clock() + remain + 0.15
					while os.clock() < deadline do
						if active and not active() then
							return false
						end
						task.wait(0.1)
					end
				end
			end
			return true
		end

		local started = os.clock()
		if seconds and seconds > 0 then
			notify(string.format("ATM on cooldown — waiting %.1fs (from UI)...", seconds))
		elseif measuredDepositCooldown then
			notify(string.format("ATM on cooldown — waiting %.1fs (measured)...", measuredDepositCooldown))
		else
			notify("ATM on cooldown — waiting for it to clear...")
		end

		local waitFor = seconds or measuredDepositCooldown or 45
		local deadline = os.clock() + math.max(waitFor + 2, 8)
		while os.clock() < deadline do
			if active and not active() then
				return false
			end
			onCooldown, seconds = atmCooldownInfo()
			if not onCooldown then
				local elapsed = os.clock() - started
				if elapsed >= 0.4 then
					measuredDepositCooldown = math.max(0.5, tonumber(string.format("%.2f", elapsed)))
					notify(string.format("ATM cooldown measured: %.2fs", measuredDepositCooldown))
				end
				task.wait(0.1)
				return true
			end
			if seconds and seconds > 0 then
				task.wait(math.clamp(seconds, 0.15, 1.5))
			else
				task.wait(0.2)
			end
		end
		return not atmCooldownInfo()
	end

	local function openBankAtm()
		local atms = sortByDistance(findPrompts("atm", function(prompt)
			return prompt.ActionText == "Use Bank"
		end))
		if #atms == 0 then
			return false, "no ATM was found"
		end
		if not usePrompt(atms[1]) then
			return false, "could not reach an ATM"
		end
		task.wait(0.35)
		return true
	end

	local function depositRapidChunks(target, active)
		target = target or LOOP_DEPOSIT_TARGET
		local room = bankRoom()
		if room <= 0 then
			return false, 0, "bank is full at the " .. formatCash(MONEY_CAP) .. " cap (same as dirty/cash)"
		end
		local wallet = getStat("Money")
		local goal = math.min(target, wallet, room)
		if goal <= 0 then
			return false, 0, "wallet empty"
		end
		local remote = getRemote("BankAction")
		if not remote then
			return false, 0, "the bank remote was not found"
		end

		if not findAtmGui() then
			local ok, reason = openBankAtm()
			if not ok then
				return false, 0, reason
			end
		end
		if not waitAtmCooldown(active) then
			return false, 0, "stopped during ATM cooldown"
		end

		local deposited = 0
		local stalls = 0
		while deposited < goal do
			if active and not active() then
				break
			end
			room = bankRoom()
			wallet = getStat("Money")
			if room <= 0 then
				notify("Bank hit the " .. formatCash(MONEY_CAP) .. " cap — stopping deposits.")
				break
			end
			if wallet <= 0 then
				break
			end
			if not waitAtmCooldown(active) then
				break
			end

			local chunk = math.min(DEPOSIT_CHUNK, goal - deposited, wallet, room)
			local beforeBank = getStat("Bank")
			local beforeMoney = getStat("Money")
			pcall(function()
				remote:FireServer("depo", tostring(chunk))
			end)
			if waitUntil(function()
				return getStat("Bank") > beforeBank or getStat("Money") < beforeMoney
			end, 1.4) then
				local spent = beforeMoney - getStat("Money")
				local gained = getStat("Bank") - beforeBank
				deposited = deposited + (spent > 0 and spent or (gained > 0 and gained or chunk))
				if lastDepositSuccessAt > 0 then
					local gap = os.clock() - lastDepositSuccessAt
					if gap >= 0.4 and gap <= 120 then
						measuredDepositCooldown = measuredDepositCooldown and math.min(measuredDepositCooldown, gap) or gap
						measuredDepositCooldown = math.max(0.5, tonumber(string.format("%.2f", measuredDepositCooldown)))
					end
				end
				lastDepositSuccessAt = os.clock()
				stalls = 0
				-- Pace to the measured cooldown so we don't trip "On cooldown" every tap.
				if measuredDepositCooldown then
					task.wait(measuredDepositCooldown + 0.05)
				else
					task.wait(0.35)
				end
			else
				stalls = stalls + 1
				local onCooldown = atmCooldownInfo()
				if onCooldown then
					waitAtmCooldown(active)
					stalls = 0
				elseif stalls == 1 or stalls == 3 then
					openBankAtm()
					waitAtmCooldown(active)
				elseif stalls >= 10 then
					break
				else
					task.wait(0.35)
				end
			end
		end
		closeAtmGui()
		local reason = nil
		if deposited <= 0 then
			reason = atmCooldownInfo() and "ATM stayed on cooldown" or ("deposits failed; bank " .. formatCash(getStat("Bank")) .. " / cap " .. formatCash(MONEY_CAP))
		elseif bankRoom() <= 0 then
			reason = nil
		end
		return deposited > 0, deposited, reason
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

	local function sawMessage(fragment, since)
		return gameMessage.time >= since and gameMessage.text:find(fragment, 1, true) ~= nil
	end

	-- Grab Cash → MoneyReady → Put Cash In (DuffleBag) → BagOfMoney → ATMMoney Bank.
	-- ATM ObjectText is BagOfMoney. Never bank / teleport to ATM while holding MoneyReady.
	local function isMoneyReadyTool(tool)
		if not (tool and tool:IsA("Tool")) then
			return false
		end
		local name = tool.Name:lower():gsub("%s+", "")
		return name == "moneyready" or name:find("moneyready", 1, true) ~= nil
	end

	-- Only the filled laundry bag is bankable (ATMMoney prompt ObjectText = BagOfMoney).
	local function isLaundryBagTool(tool)
		if not tool or not tool:IsA("Tool") or isMoneyReadyTool(tool) then
			return false
		end
		local name = tool.Name:lower():gsub("%s+", "")
		if name == "fist" or name == "fists" or name == "phone" or name == "bread" then
			return false
		end
		return name == "bagofmoney"
			or name == "counterbag"
			or name == "dufflebag"
			or name == "duffelbag"
			or name:find("bagofmoney", 1, true) ~= nil
	end

	local function holdingMoneyReady()
		return findTools(isMoneyReadyTool)[1]
	end

	local function holdingBankableBag()
		return findTools(isLaundryBagTool)[1]
	end

	local function isGrabCashPrompt(prompt)
		if not (prompt and prompt:IsA("ProximityPrompt")) then
			return false
		end
		if prompt.Enabled == false then
			return false
		end
		local action = (prompt.ActionText or ""):lower()
		local object = (prompt.ObjectText or ""):lower()
		local combined = action .. " " .. object
		if combined:find("count money", 1, true)
			or combined:find("count bread", 1, true)
			or combined:find("put cash", 1, true)
			or prompt:FindFirstAncestor("DuffleBag") ~= nil
		then
			return false
		end
		-- CashPrompt after counting: "[E] Grab Cash" / "Counter".
		return combined:find("grab cash", 1, true) ~= nil
			or (combined:find("grab", 1, true) ~= nil and combined:find("cash", 1, true) ~= nil)
			or (prompt.Name == "CashPrompt" and object:find("counter", 1, true) ~= nil and not combined:find("count", 1, true))
	end

	-- DuffleBag GrabPrompt: Action "Duffle Bag", Object "Put Cash In" (may be disabled until MoneyReady is out).
	local function isPutCashPrompt(prompt, allowDisabled)
		if not (prompt and prompt:IsA("ProximityPrompt")) then
			return false
		end
		if not allowDisabled and prompt.Enabled == false then
			return false
		end
		local action = (prompt.ActionText or ""):lower()
		local object = (prompt.ObjectText or ""):lower()
		local combined = action .. " " .. object
		return combined:find("put cash", 1, true) ~= nil
			or (action:find("duffle", 1, true) ~= nil and object:find("put", 1, true) ~= nil)
			or (prompt.Name == "GrabPrompt" and prompt:FindFirstAncestor("DuffleBag") ~= nil)
	end

	local function isLaundryCollectPrompt(prompt)
		return isGrabCashPrompt(prompt) or isPutCashPrompt(prompt, false)
	end

	-- Prefer enabled collect prompts (Grab Cash Counter). Do NOT return the disabled
	-- GrabPrompt ("Put Cash In") early — that blocked finding the real grab.
	-- Never scan all of Workspace here — that hitch-stutters the whole client every poll.
	local laundryPromptCache = { at = 0, list = {} }

	local function laundryScanRoots(counterPrompt)
		local roots = {}
		local seen = {}
		local function addRoot(inst)
			if inst and inst.Parent and not seen[inst] then
				seen[inst] = true
				table.insert(roots, inst)
			end
		end
		addRoot(Workspace:FindFirstChild("CounterBag"))
		local counter = counterPrompt and counterPrompt:FindFirstAncestor("CounterM")
		addRoot(counter)
		if counter and counter.Parent then
			addRoot(counter.Parent)
		end
		return roots
	end

	local function collectLaundryPrompts(counterPrompt, maxDistance)
		local now = os.clock()
		if laundryPromptCache.at == 0 or now - laundryPromptCache.at >= 1.25 then
			local list = {}
			local seen = {}
			for _, root in ipairs(laundryScanRoots(counterPrompt)) do
				for _, prompt in ipairs(root:GetDescendants()) do
					if prompt:IsA("ProximityPrompt") and isLaundryCollectPrompt(prompt) and not seen[prompt] then
						seen[prompt] = true
						table.insert(list, prompt)
					end
				end
			end
			laundryPromptCache.at = now
			laundryPromptCache.list = list
		end

		local anchor = promptPosition(counterPrompt) or (getRoot() and getRoot().Position)
		local found = {}
		local range = maxDistance or 22
		for _, prompt in ipairs(laundryPromptCache.list) do
			if prompt.Parent and isLaundryCollectPrompt(prompt) then
				local pos = promptPosition(prompt)
				if not anchor or (pos and (pos - anchor).Magnitude <= range) then
					table.insert(found, prompt)
				end
			end
		end
		return sortByDistance(found)
	end

	local function findLaundryCollectPrompts(counterPrompt)
		return collectLaundryPrompts(counterPrompt, 18)
	end

	-- Stand next to a prompt with a tiny snap (no Vehicle/Tween trip).
	local function snapNearPrompt(prompt)
		local position = promptPosition(prompt)
		local root = getRoot()
		if not (position and root) then
			return false
		end
		local reach = math.max((prompt.MaxActivationDistance or 4) * 0.45, 1.2)
		if distanceTo(position) <= reach then
			return true
		end
		local stand = standNear(position, reach)
		if not stand then
			return false
		end
		root.CFrame = stand
		root.AssemblyLinearVelocity = Vector3.zero
		root.AssemblyAngularVelocity = Vector3.zero
		task.wait(0.05)
		return distanceTo(position) <= math.max(prompt.MaxActivationDistance or 4, reach) + 1
	end

	local function isCountRegisterPrompt(prompt, wanted)
		if not (prompt and prompt:IsA("ProximityPrompt") and prompt.Enabled ~= false) then
			return false
		end
		local action = tostring(prompt.ActionText or "")
		local object = tostring(prompt.ObjectText or "")
		if action == wanted or object == wanted then
			return true
		end
		-- CashPrompt layouts: Action "Counter" + Object "Count Money" (or swapped).
		if prompt.Name == "CashPrompt" or object == "Counter" or action == "Counter" then
			return action:find(wanted, 1, true) ~= nil or object:find(wanted, 1, true) ~= nil
		end
		return false
	end

	-- Registers / Grab Cash need the full HoldDuration. Instant Interact / forceInstant skips that.
	local function fireRegisterHold(prompt)
		if not (prompt and prompt.Parent) then
			return false
		end
		local savedInstant = promptHoldDurations[prompt]
		local hold = savedInstant or tonumber(prompt.HoldDuration) or 0
		if hold < 1 then
			hold = 1.42
		end
		local previous = prompt.HoldDuration
		prompt.HoldDuration = hold
		if fireproximityprompt then
			local ok = pcall(fireproximityprompt, prompt, hold)
			if not ok then
				pcall(function()
					prompt:InputHoldBegin()
					task.wait(hold + 0.08)
					prompt:InputHoldEnd()
				end)
			else
				-- Many executors return immediately; wait out the hold so the server accepts it.
				task.wait(hold + 0.08)
			end
		else
			prompt:InputHoldBegin()
			task.wait(hold + 0.08)
			prompt:InputHoldEnd()
		end
		if on("InstantInteract") then
			prompt.HoldDuration = 0
		else
			prompt.HoldDuration = savedInstant or previous
		end
		return true
	end

	-- Fire Grab Cash / Put Cash In in place — never longTrip/tween for this step.
	local function fireLaundryCollect(prompt, allowDisabledPut)
		if not (prompt and prompt.Parent) then
			return false
		end
		local putting = isPutCashPrompt(prompt, true)
		if putting then
			local ready = holdingMoneyReady()
			if not ready then
				return false
			end
			equipTool(ready)
			if allowDisabledPut and prompt.Enabled == false then
				pcall(function()
					prompt.Enabled = true
				end)
			end
		elseif prompt.Enabled == false then
			return false
		end
		snapNearPrompt(prompt)
		-- HoldDuration is ~1s; instant fire never awards MoneyReady / BagOfMoney.
		for _ = 1, 4 do
			if not prompt.Parent then
				break
			end
			if not putting and prompt.Enabled == false then
				break
			end
			if putting and prompt.Enabled == false then
				pcall(function()
					prompt.Enabled = true
				end)
			end
			fireRegisterHold(prompt)
			task.wait(0.2)
			if putting then
				-- Success = MoneyReady gone and BagOfMoney in inventory. Never succeed early on an old bag.
				if not holdingMoneyReady() and holdingBankableBag() then
					return true
				end
			elseif holdingMoneyReady() or holdingBankableBag() then
				return true
			end
		end
		return putting and (not holdingMoneyReady() and holdingBankableBag() ~= nil) or not putting
	end

	local function findPutCashPrompts(counterPrompt)
		local found = {}
		local seen = {}
		local function add(prompt)
			if prompt and prompt.Parent and isPutCashPrompt(prompt, true) and not seen[prompt] then
				seen[prompt] = true
				table.insert(found, prompt)
			end
		end
		local counter = counterPrompt and counterPrompt:FindFirstAncestor("CounterM")
		if not counter then
			local folder = Workspace:FindFirstChild("CounterBag")
			counter = folder and folder:FindFirstChild("CounterM", true)
		end
		if counter then
			local duffle = counter:FindFirstChild("DuffleBag", true)
			if duffle then
				for _, prompt in ipairs(duffle:GetDescendants()) do
					if prompt:IsA("ProximityPrompt") then
						add(prompt)
					end
				end
			end
			for _, prompt in ipairs(counter:GetDescendants()) do
				if prompt:IsA("ProximityPrompt") then
					add(prompt)
				end
			end
		end
		laundryPromptCache.at = 0
		for _, prompt in ipairs(collectLaundryPrompts(counterPrompt, 28)) do
			if isPutCashPrompt(prompt, true) then
				add(prompt)
			end
		end
		return sortByDistance(found)
	end

	-- MoneyReady → Put Cash In duffle → BagOfMoney. Does not return while MoneyReady is still held.
	local function bagMoneyReady(counterPrompt, moneyReady)
		moneyReady = moneyReady or holdingMoneyReady()
		if not moneyReady then
			return holdingBankableBag()
		end
		notify("Putting MoneyReady into the duffle (Put Cash In)...")
		local deadline = os.clock() + 50
		while os.clock() < deadline and not Arsenic.Destroyed do
			local ready = holdingMoneyReady()
			local bag = holdingBankableBag()
			-- Only done when the wad is gone AND a BagOfMoney exists.
			if not ready and bag then
				return bag
			end
			if not ready and not bag then
				bag = waitUntil(holdingBankableBag, 4) and holdingBankableBag()
				if bag then
					return bag
				end
				-- Wad consumed with no bag — stop and let caller report.
				return nil
			end
			ready = holdingMoneyReady()
			if not ready then
				task.wait(0.25)
			else
				equipTool(ready)
				local puts = findPutCashPrompts(counterPrompt)
				if #puts == 0 then
					-- Stay at the counter duffle; do not wander toward the bank.
					if counterPrompt then
						snapNearPrompt(counterPrompt)
					end
					task.wait(0.45)
				else
					for _, prompt in ipairs(puts) do
						if not holdingMoneyReady() then
							break
						end
						fireLaundryCollect(prompt, true)
						task.wait(0.25)
						if not holdingMoneyReady() and holdingBankableBag() then
							return holdingBankableBag()
						end
					end
				end
			end
			task.wait(0.3)
		end
		if holdingMoneyReady() then
			return nil
		end
		return holdingBankableBag()
	end

	-- Hard gate: never path to ATMMoney while MoneyReady is equipped / in backpack.
	local function bankBagOfMoney(bag, startTotal)
		if holdingMoneyReady() then
			return false, "moneyready"
		end
		bag = bag or holdingBankableBag()
		if not (bag and isLaundryBagTool(bag)) then
			return false, "nobag"
		end
		local atmMoney = Workspace:FindFirstChild("ATMMoney")
		local bankPrompt = atmMoney and atmMoney:FindFirstChildWhichIsA("ProximityPrompt", true)
		if not bankPrompt then
			return false, "noatm"
		end
		notify("BagOfMoney ready — cashing in at the bank ATM...")
		for _ = 1, CLEAN_STEP_ATTEMPTS do
			if holdingMoneyReady() then
				return false, "moneyready"
			end
			if not bag.Parent then
				return true, "cashed"
			end
			bag = holdingBankableBag() or bag
			if not isLaundryBagTool(bag) then
				return false, "nobag"
			end
			equipTool(bag)
			-- Re-check after equip: EquipTool must not leave MoneyReady out.
			if holdingMoneyReady() then
				local ready = holdingMoneyReady()
				if ready and ready.Parent == getCharacter() then
					return false, "moneyready"
				end
			end
			local equipped = getCharacter() and getCharacter():FindFirstChildOfClass("Tool")
			if equipped and isMoneyReadyTool(equipped) then
				return false, "moneyready"
			end
			if equipped and not isLaundryBagTool(equipped) then
				equipTool(bag)
				task.wait(0.15)
				equipped = getCharacter() and getCharacter():FindFirstChildOfClass("Tool")
				if not (equipped and isLaundryBagTool(equipped)) then
					return false, "nobag"
				end
			end
			local position = promptPosition(bankPrompt)
			if position then
				goNear(position, math.max((bankPrompt.MaxActivationDistance or 4) * 0.5, 1.5))
			end
			if holdingMoneyReady() then
				return false, "moneyready"
			end
			fireRegisterHold(bankPrompt)
			if waitUntil(function()
				return bag.Parent == nil or getStat("Money") + getStat("Bank") > startTotal
			end, 5) then
				return true, "cashed"
			end
		end
		return bag.Parent == nil, bag.Parent == nil and "cashed" or "failed"
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
		local toolsBefore = snapshotTools()

		local function finish(message)
			if message then
				notify(message)
			end
		end

		-- Re-pressed only when the press was lost to a pull-back; a press that lands is never repeated.
		local function startCounting(counterPrompt)
			for _ = 1, CLEAN_STEP_ATTEMPTS do
				if wanted == "Count Bread" then
					equipTool(getTool("Bread"))
				end
				local position = promptPosition(counterPrompt)
				local reach = math.max((counterPrompt.MaxActivationDistance or 3) - 0.2, 1.2)
				-- Already at the register: do not longTrip away. Otherwise approach closely.
				if position and distanceTo(position) > reach then
					if not goNear(position, math.max(reach * 0.5, 1.15)) then
						snapNearPrompt(counterPrompt)
					end
				else
					snapNearPrompt(counterPrompt)
				end
				if not position or distanceTo(position) > math.max(counterPrompt.MaxActivationDistance or 3, reach) + 1.5 then
					task.wait(PULLED_BACK_COOLDOWN)
				else
					local pressedAt = os.clock()
					local dirtyBefore = getStat("FilthyStack")
					fireRegisterHold(counterPrompt)
					task.wait(0.2)
					if sawMessage("already using", pressedAt) then
						return "busy"
					end
					-- FilthyStack dropping / Bread appearing means the register accepted it.
					if getStat("FilthyStack") < dirtyBefore or getTool("Bread") or sawMessage("count", pressedAt) then
						return "started"
					end
					-- Hold landed in range; treat as started even if the stat update is delayed.
					return "started"
				end
			end
			return "failed"
		end

		local counterPrompt = resuming and activeCounter or nil
		if not counterPrompt then
			laundryPromptCache.at = 0
			local counters = {}
			-- Prefer CounterBag only (full Workspace scans hitch hard during Auto Clean).
			local bagFolder = Workspace:FindFirstChild("CounterBag")
			if bagFolder then
				for _, prompt in ipairs(bagFolder:GetDescendants()) do
					if prompt:IsA("ProximityPrompt") and isCountRegisterPrompt(prompt, wanted) then
						table.insert(counters, prompt)
					end
				end
			end
			if #counters == 0 then
				for _, prompt in ipairs(findPrompts("counters", function(prompt)
					return isCountRegisterPrompt(prompt, wanted)
				end)) do
					table.insert(counters, prompt)
				end
			end
			if #counters == 0 then
				finish("No free money counter was found.")
				returnTo(startCFrame)
				return
			end
			counterPrompt = sortByDistance(counters)[1]
			local result = startCounting(counterPrompt)
			if result == "failed" then
				finish("Could not start the money counter.")
				returnTo(startCFrame)
				return
			elseif result == "busy" then
				-- Already counting somewhere from an earlier run: take whichever bag becomes ours.
				counterPrompt = nil
			end
			activeCounter = counterPrompt
		end
		notify(counterPrompt and "Counting your money..." or "Your money is already being counted; waiting for the bag...")

		-- Stay planted at the register; only snap if we drifted.
		if counterPrompt then
			local plantAt = promptPosition(counterPrompt)
			if plantAt and distanceTo(plantAt) > 4 then
				snapNearPrompt(counterPrompt)
			end
		end

		local function moneyReadyAppeared()
			return findTools(isMoneyReadyTool)[1]
		end

		-- Only bags earned this run — never treat MoneyReady or a pre-owned bag as "done".
		local function bagToolAppeared()
			return findTools(function(tool)
				return isLaundryBagTool(tool) and not toolsBefore[tool]
			end)[1]
		end

		local function nearbyGrabPrompts()
			local grabs = {}
			for _, prompt in ipairs(collectLaundryPrompts(counterPrompt, 22)) do
				if isGrabCashPrompt(prompt) then
					table.insert(grabs, prompt)
				end
			end
			return grabs
		end

		-- Step 1: wait for Grab Cash → MoneyReady (cash wad). Never bank while holding MoneyReady.
		local moneyReady = moneyReadyAppeared()
		local bag = bagToolAppeared()
		local deadline = os.clock() + COUNTING_TIMEOUT
		local lastNotify = 0
		local lastGrabNotify = 0
		local lastScan = 0
		local cachedGrabs = {}
		while not moneyReady and not bag and os.clock() < deadline and not Arsenic.Destroyed do
			moneyReady = moneyReadyAppeared()
			bag = bagToolAppeared()
			if moneyReady or bag then
				break
			end

			if os.clock() - lastScan >= 1.0 then
				lastScan = os.clock()
				cachedGrabs = nearbyGrabPrompts()
			end
			local grabs = cachedGrabs
			if #grabs > 0 then
				local before = snapshotTools()
				if os.clock() - lastGrabNotify > 6 then
					lastGrabNotify = os.clock()
					notify("Grabbing counted cash...")
				end
				for _, grab in ipairs(grabs) do
					if grab.Parent and grab.Enabled and isGrabCashPrompt(grab) then
						fireLaundryCollect(grab)
						local gainedTool = waitForNewTool(before, 1.5)
						if gainedTool and isMoneyReadyTool(gainedTool) then
							moneyReady = gainedTool
						elseif gainedTool and isLaundryBagTool(gainedTool) then
							bag = gainedTool
						end
						moneyReady = moneyReady or moneyReadyAppeared()
						bag = bag or bagToolAppeared()
						if moneyReady or bag then
							break
						end
					end
				end
				laundryPromptCache.at = 0
				cachedGrabs = {}
			elseif os.clock() - lastNotify > 8 then
				lastNotify = os.clock()
				notify("Still waiting on Grab Cash at the register...")
			end
			task.wait(0.45)
		end

		-- Step 2: MoneyReady must become BagOfMoney via Put Cash In before any bank trip.
		moneyReady = moneyReady or moneyReadyAppeared()
		if moneyReady or holdingMoneyReady() then
			bag = bagMoneyReady(counterPrompt, moneyReady or holdingMoneyReady())
		else
			bag = bag or bagToolAppeared() or holdingBankableBag()
		end

		if holdingMoneyReady() then
			finish("Stopped: still holding MoneyReady. Put Cash In on the counter duffle before banking.")
			return
		end
		if not bag or not isLaundryBagTool(bag) then
			finish(bag and ("Stopped: need BagOfMoney, still have " .. bag.Name .. ".")
				or "Grab/Put Cash never finished. Stay at the register and run Auto Clean Money again.")
			return
		end

		activeCounter = nil
		local cashed, bankReason = bankBagOfMoney(bag, startTotal)
		if bankReason == "moneyready" then
			finish("Aborted bank trip — MoneyReady was still equipped. Put it in the duffle first.")
			return
		end

		local gained = getStat("Money") + getStat("Bank") - startTotal
		if holdingMoneyReady() then
			notify("Still holding MoneyReady — Put Cash In at the duffle, then deposit BagOfMoney.")
		elseif gained > 0 or cashed then
			returnTo(startCFrame)
			notify("Cleaned " .. formatCash(math.max(gained, 0)) .. ".")
		elseif holdingBankableBag() then
			notify("BagOfMoney is ready. Deposit it at the bank ATM (ATMMoney).")
		else
			returnTo(startCFrame)
			notify("Money handed in at the bank.")
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

	-- Shop keys are FijiWater / FreshWater; hotbar labels sometimes show spaced names.
	local function getIngredientTool(name)
		local tool = getTool(name)
		if tool then
			return tool
		end
		local compact = tostring(name):lower():gsub("%s+", "")
		return findTools(function(candidate)
			return candidate.Name:lower():gsub("%s+", "") == compact
		end)[1]
	end

	local function missingIngredients()
		local missing = {}
		for _, name in ipairs(ICE_FRUIT_INGREDIENTS) do
			if not getIngredientTool(name) then
				table.insert(missing, name)
			end
		end
		return missing
	end

	-- The cup handed back by a finished cook; an empty cup bought from the shop looks the same.
	local cookedCup = nil

	local function hasRawCookIngredients()
		return getIngredientTool("FijiWater") ~= nil
			or getIngredientTool("FreshWater") ~= nil
			or getIngredientTool("Ice-Fruit Bag") ~= nil
	end

	-- Only treat the cup as cooked when raw ingredients are gone (empty shop cup must not skip cooking).
	local function hasCookedCup()
		if not (cookedCup and cookedCup.Parent and getIngredientTool(ICE_FRUIT_CUP)) then
			return false
		end
		if hasRawCookIngredients() then
			cookedCup = nil
			return false
		end
		return true
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
		return not hasRawCookIngredients()
	end

	local function getSellPrompt()
		local sellPart = Workspace:FindFirstChild("IceFruit Sell")
		return sellPart and sellPart:FindFirstChildWhichIsA("ProximityPrompt", true)
	end

	local function potPromptText(prompt)
		if not prompt then
			return ""
		end
		return ((prompt.ActionText or "") .. " " .. (prompt.ObjectText or "")):lower()
	end

	-- Picks the free pot that makes the shortest route from here to the pot and on to the seller.
	-- Prefer a pot you're already standing at so Infinite Money Loop doesn't wander off "Turn On".
	local function findFreePot()
		local folder = Workspace:FindFirstChild("CookingPots")
		local sellPosition = promptPosition(getSellPrompt())
		local best, bestScore = nil, math.huge
		local nearby, nearbyDist = nil, math.huge
		for _, pot in ipairs(folder and folder:GetChildren() or {}) do
			local cookPart = pot:FindFirstChild("CookPart")
			local prompt = cookPart and cookPart:FindFirstChildWhichIsA("ProximityPrompt")
			local owner = pot:FindFirstChild("Owner")
			local ownerValue = owner and owner:IsA("ObjectValue") and owner.Value
			if prompt and cookPart and isOnMap(cookPart.Position) and (not ownerValue or ownerValue == LocalPlayer) then
				local dist = distanceTo(cookPart.Position)
				if dist < nearbyDist then
					nearby, nearbyDist = prompt, dist
				end
				local score = dist + (sellPosition and (cookPart.Position - sellPosition).Magnitude or 0)
				if score < bestScore then
					best, bestScore = prompt, score
				end
			end
		end
		if nearby and nearbyDist <= 12 then
			return nearby
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
		text = tostring(text or ""):lower()
		if text:find("turn off", 1, true) then
			return false
		end
		for _, action in ipairs(COOK_ACTIONS) do
			if text:find(action, 1, true) then
				return true
			end
		end
		return false
	end

	-- Turn On is bare-handed. Mix Items needs one ingredient per press (waters, then bag).
	-- When the prompt returns to Turn On after mixing (or ingredients are gone), it's cooking.
	local MIX_TOOLS = { "FijiWater", "FreshWater", "Ice-Fruit Bag" }

	local function unequipHands()
		local humanoid = getHumanoid()
		if humanoid then
			pcall(function()
				humanoid:UnequipTools()
			end)
			task.wait(0.12)
		end
	end

	local function firePotPrompt(potPrompt)
		if firePromptInRange(potPrompt) then
			return true
		end
		return usePrompt(potPrompt)
	end

	local function cookIceFruit(potPrompt, active)
		local deadline = os.clock() + COOK_TIMEOUT
		local cupsBefore = snapshotCups()
		local sawMix = false
		local stoveOn = false
		local pressIndex = 0
		local lastNotify = 0
		local function cookingStarted()
			local text = potPromptText(potPrompt)
			return ingredientsUsed() or (sawMix and text:find("turn on", 1, true) ~= nil)
		end
		while not cookingStarted() do
			if os.clock() > deadline or not active() then
				return nil
			end
			if not (potPrompt and potPrompt.Parent) then
				return nil
			end
			local text = potPromptText(potPrompt)
			local isTurnOn = text:find("turn on", 1, true) ~= nil
			local isMix = text:find("mix", 1, true) ~= nil
			if isMix then
				sawMix = true
				stoveOn = true
			end

			local held
			if isMix or (stoveOn and not isTurnOn) then
				for _ = 1, #MIX_TOOLS do
					pressIndex = pressIndex % #MIX_TOOLS + 1
					held = getIngredientTool(MIX_TOOLS[pressIndex])
					if held then
						break
					end
				end
			end

			if os.clock() - lastNotify > 8 then
				lastNotify = os.clock()
				if isTurnOn and not stoveOn then
					notify("Cooking: turning stove on (no ingredient)...")
				else
					notify("Cooking: " .. (potPrompt.ActionText or "?") .. (held and (" with " .. held.Name) or ""))
				end
			end

			if potPrompt.Enabled ~= false and isCookAction(text) then
				if isTurnOn and not sawMix then
					-- Stove Turn On first — empty hands, then mix with water.
					unequipHands()
					firePotPrompt(potPrompt)
					stoveOn = true
					task.wait(0.55)
				elseif isMix or (stoveOn and held) then
					if not held then
						task.wait(0.35)
					else
						equipTool(held)
						firePotPrompt(potPrompt)
						task.wait(0.75)
					end
				elseif distanceTo(promptPosition(potPrompt)) > 6 then
					goNear(promptPosition(potPrompt), 2.5)
					task.wait(0.2)
				else
					task.wait(0.35)
				end
			elseif distanceTo(promptPosition(potPrompt)) > 6 then
				goNear(promptPosition(potPrompt), 2.5)
				task.wait(0.2)
			else
				task.wait(0.35)
			end
		end

		notify("Ice-Fruit is cooking (about a minute)...")
		-- When the cook is done the pot asks to "Fill Pitcher Cup"; that press, cup in hand, fills it.
		local function readyToFill()
			return potPrompt.Enabled ~= false and potPromptText(potPrompt):find("fill", 1, true) ~= nil
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
			local cup = getIngredientTool(ICE_FRUIT_CUP)
			if not cup then
				return nil
			end
			local cupsBeforeFill = snapshotCups()
			equipTool(cup)
			firePotPrompt(potPrompt)
			if waitUntil(function()
				return not readyToFill() or changedCup(cupsBeforeFill) ~= nil
			end, 3) then
				task.wait(0.5)
				return changedCup(cupsBefore) or getIngredientTool(ICE_FRUIT_CUP)
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

	local function infiniteMoney(loopActive)
		local flagMark = teleportFlagCount
		local function active()
			if loopActive and not loopActive() then
				return false
			end
			return not Arsenic.Destroyed and teleportFlagCount - flagMark < MAX_FLAGS_PER_RUN
		end
		local function stopped()
			if active() then
				return false
			end
			if loopActive and not loopActive() then
				return true
			end
			notify("Infinite Money stopped: the anti-teleport flagged you twice and a third time could kick you. Wait a moment, then press it again.")
			return true
		end
		if getStat("FilthyStack") >= DIRTY_CAP then
			notify("Your dirty money is already at " .. formatCash(DIRTY_CAP) .. ". Use Auto Clean Money first.")
			return
		end

		-- Empty shop cup left in cookedCup used to skip the entire stove step.
		if hasRawCookIngredients() then
			cookedCup = nil
		end

		-- Route: shop -> pot -> seller, with no trips back in between.
		if not hasCookedCup() then
			local ownedPot = findOwnedPot()
			local alreadyCooking = ownedPot ~= nil and getIngredientTool(ICE_FRUIT_CUP) ~= nil and ingredientsUsed()
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
			else
				notify("Finishing cook at your pot...")
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

	-- Infinite Money → Auto Clean → deposit $900K in $30K ATM chunks → repeat.
	loopFeature("InfiniteMoneyLoop", 2.5, function(active)
		if getStat("FilthyStack") < DIRTY_CAP then
			notify("Infinite Money Loop: farming dirty money...")
			infiniteMoney(active)
			if not active() then
				return
			end
		end

		local needsClean = getStat("FilthyStack") > 0
			or getTool("Bread") ~= nil
			or holdingMoneyReady() ~= nil
			or holdingBankableBag() ~= nil
		if needsClean then
			notify("Infinite Money Loop: cleaning money...")
			cleanMoney()
			if not active() then
				return
			end
		end

		if holdingMoneyReady() then
			notifyOnce("infloop-ready", "Infinite Money Loop: still holding MoneyReady — finish Put Cash In before it can bank.")
			return
		end

		local wallet = getStat("Money")
		if wallet <= 0 then
			notifyOnce("infloop-wallet", "Infinite Money Loop: wallet empty after clean — farming again.")
			return
		end

		local room = bankRoom()
		if room <= 0 then
			notifyOnce(
				"infloop-bankcap",
				"Infinite Money Loop: bank is full at " .. formatCash(MONEY_CAP) .. " (same cap as dirty/cash). Skipping deposit — withdraw or spend bank first."
			)
			task.wait(4)
			return
		end

		local goal = math.min(LOOP_DEPOSIT_TARGET, wallet, room)
		local cdNote = measuredDepositCooldown and string.format(", ~%.1fs cooldown", measuredDepositCooldown) or ""
		notify("Infinite Money Loop: depositing " .. formatCash(goal) .. " ($" .. DEPOSIT_CHUNK .. " chunks" .. cdNote .. ")...")
		local ok, deposited, reason = depositRapidChunks(goal, active)
		if not active() then
			return
		end
		if ok and deposited > 0 then
			local cd = measuredDepositCooldown and string.format(" (ATM cooldown %.2fs)", measuredDepositCooldown) or ""
			notify("Infinite Money Loop: deposited " .. formatCash(deposited) .. cd .. ". Starting next cycle...")
		else
			notify("Infinite Money Loop: deposit failed (" .. tostring(reason or "unknown") .. "). Retrying...")
			task.wait(2)
		end
	end)

	-- Market dupe — mirrors the working open-source TB3 timing:
	-- backpack → wait → List → delay → Store → wait → Remove → Grab → wait
	local DUPE_BAG_COOLDOWN = 1.65
	local DUPE_TIMING_BIAS = { Early = -0.04, Normal = 0, Late = 0.05 }

	local function dupeListPrice()
		local price = tonumber(Arsenic.Values.DupeListPrice) or 99999
		return math.clamp(math.floor(price), 1, 999999999)
	end

	local dupeStoreDelay
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

	dupeStoreDelay = function()
		local delay
		if Arsenic.Values.DupeUsePing ~= false then
			delay = 0.25 + ((math.clamp(getDupePingMs(), 0, 300) / 300) * 0.03)
		else
			delay = tonumber(Arsenic.Values.DupeManualDelay) or 0.27
		end
		local bias = DUPE_TIMING_BIAS[Arsenic.Values.DupeTiming] or 0
		local offset = tonumber(Arsenic.Values.DupeStoreDelayOffset) or 0
		return math.clamp(delay + bias + offset, 0.05, 1.5)
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
		task.wait(math.clamp(tonumber(Arsenic.Values.DupeBackpackWait) or 0.5, 0.1, 3))
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

		local delay = dupeStoreDelay()

		task.spawn(function()
			pcall(function()
				listRemote:FireServer(toolName, dupeListPrice())
			end)
		end)

		task.wait(delay)

		task.spawn(function()
			pcall(function()
				backpackRemote:InvokeServer("Store", toolName)
			end)
			lastBagRemoteAt = os.clock()
		end)

		task.wait(math.clamp(tonumber(Arsenic.Values.DupeRemoveWait) or 2.5, 0.5, 8))

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

		task.wait(math.clamp(tonumber(Arsenic.Values.DupeFinishWait) or 1, 0.2, 5))
		connection:Disconnect()

		-- Pull any parked extras + race results.
		pullStoredCopies(backpackRemote, toolName, active, startingCount + 6)

		local after = countNamedTools(toolName)
		if after > startingCount then
			if keepParked and Arsenic.Values.DupeParkExtras ~= false then
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
			if copy and humanoid and Arsenic.Values.DupeReequip ~= false then
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

	loopFeature("AutoDupe", function()
		return math.clamp(tonumber(Arsenic.Values.DupeInterval) or 2, 0.5, 30)
	end, function(active)
		local tool = pickDupeTool()
		if not tool then
			return
		end
		local name = tool.Name
		local ok, reason, startingCount, endingCount = dupeHeldItem(active, Arsenic.Values.DupeParkExtras ~= false)
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
	Arsenic.Values.VehicleHighlightColor = Color3.fromRGB(80, 180, 255)
	-- 0 means no limit.
	Arsenic.Values.ESPMaxRadius = 0
	Arsenic.Values.FriendESPMaxRadius = 0
	Arsenic.Values.VehicleESPMaxRadius = 0
	Arsenic.Values.SpeedUnit = Arsenic.Values.SpeedUnit or "Imperial"
	Arsenic.Values.ESPFollowFreecam = Arsenic.Values.ESPFollowFreecam == true

	local RAINBOW_PERIOD = 4
	-- Player model extents above/below the root part, for the box.
	local BOX_TOP = 3
	local BOX_BOTTOM = 3.5
	local BOX_ASPECT = 0.6
	local ESP_SWITCHES = {
		"ESP",
		"HighlightESP",
		"FriendESP",
		"FriendHighlightESP",
		"VehicleESP",
	}

	local function espColor(name)
		if on("Rainbow" .. name) then
			return Color3.fromHSV((os.clock() / RAINBOW_PERIOD) % 1, 1, 1)
		end
		return Arsenic.Values[name]
	end

	-- When freecam + follow is on, ESP range/distance use the camera, not the character.
	local function espOriginPosition()
		if Arsenic.Values.ESPFollowFreecam and on("Freecam") then
			local camera = Workspace.CurrentCamera
			if camera then
				return camera.CFrame.Position
			end
		end
		local root = getRoot()
		return root and root.Position or nil
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

	-- Project a vertical world segment to screen space. Returns nil when the target
	-- is behind the camera, outside the FOV, or would pin a fake box into the sky.
	-- Off-frustum WorldToViewportPoint coords are unreliable (sky/horizon ghosts).
	local function projectVerticalBox(camera, worldPos, topOffset, bottomOffset)
		local viewport = camera.ViewportSize
		if viewport.X < 2 or viewport.Y < 2 then
			return nil
		end
		if worldPos.Y ~= worldPos.Y or worldPos.Y < 120 or worldPos.Y > 700 then
			return nil
		end
		local camCf = camera.CFrame
		local camPos = camCf.Position
		local toTarget = worldPos - camPos
		local depth = toTarget:Dot(camCf.LookVector)
		if depth < 3 then
			return nil
		end
		local dist = toTarget.Magnitude
		if dist < 3 or dist > 2500 then
			return nil
		end
		-- Fling / streamed garbage sitting way above the local player.
		local selfRoot = getRoot()
		if selfRoot and worldPos.Y > selfRoot.Position.Y + 90 and dist > 80 then
			return nil
		end
		-- Reject targets outside a slightly generous FOV cone (W2V invents on-screen points).
		local halfFov = math.rad(math.clamp(camera.FieldOfView, 1, 120) * 0.58)
		if toTarget.Unit:Dot(camCf.LookVector) < math.cos(halfFov) then
			return nil
		end

		local root, rootOnScreen = camera:WorldToViewportPoint(worldPos)
		if not rootOnScreen or root.Z < 1 then
			return nil
		end
		if root.X ~= root.X or root.Y ~= root.Y then
			return nil
		end
		if root.X < 0 or root.X > viewport.X or root.Y < 0 or root.Y > viewport.Y then
			return nil
		end
		-- Screen ray must pass near the real world point (kills sky-pinned ghosts).
		local ray = camera:ViewportPointToRay(root.X, root.Y)
		local along = (worldPos - ray.Origin):Dot(ray.Direction)
		if along < 2 then
			return nil
		end
		local closest = ray.Origin + ray.Direction * along
		if (closest - worldPos).Magnitude > math.max(12, dist * 0.06) then
			return nil
		end

		local worldHeight = topOffset + bottomOffset
		local fov = math.rad(math.clamp(camera.FieldOfView, 1, 120))
		local height = (worldHeight / root.Z) * (viewport.Y / (2 * math.tan(fov * 0.5)))
		if height ~= height or height < 6 then
			return nil
		end
		height = math.clamp(height, 8, viewport.Y * 0.55)
		local topY = root.Y - height * (topOffset / worldHeight)
		local bottomY = topY + height
		-- Far targets must sit near/below the horizon band, not in open sky.
		if dist > 120 then
			local flatLook = Vector3.new(camCf.LookVector.X, 0, camCf.LookVector.Z)
			if flatLook.Magnitude > 0.05 then
				local horizon = camera:WorldToViewportPoint(camPos + flatLook.Unit * dist)
				if horizon.Z > 0 and root.Y < horizon.Y - math.max(18, height * 0.35) then
					return nil
				end
			end
			if topY < viewport.Y * 0.08 and height < 36 then
				return nil
			end
		end
		if topY > viewport.Y or bottomY < 0 then
			return nil
		end
		return root.X, topY, height, viewport
	end

	local function drawOverlay(esp, player, character, humanoid, root, color, tracerColor)
		local camera = Workspace.CurrentCamera
		if not camera then
			hideOverlay(esp)
			return
		end
		local centerX, topY, height, viewport = projectVerticalBox(camera, root.Position, BOX_TOP, BOX_BOTTOM)
		if not centerX then
			hideOverlay(esp)
			return
		end
		local width = height * BOX_ASPECT
		local left = centerX - width / 2

		esp.box.Position = UDim2.fromOffset(left, topY)
		esp.box.Size = UDim2.fromOffset(width, height)
		esp.stroke.Color = color
		esp.box.Visible = true

		local header = {}
		if on("ESPNames") then
			table.insert(header, player.DisplayName)
		end
		local origin = espOriginPosition()
		if on("ESPDistance") and origin then
			table.insert(header, ("[%d studs]"):format(math.floor((origin - root.Position).Magnitude)))
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
			local target = Vector2.new(centerX, topY + height)
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
		-- Drop boxes for players who already left (stale keys / late CharacterRemoving).
		if typeof(player) ~= "Instance" or player.Parent ~= Players then
			removeEsp(player)
			return
		end
		local character = player.Character
		if not (character and character.Parent) then
			if espObjects[player] then
				espObjects[player].highlight.Enabled = false
				espObjects[player].highlight.Adornee = nil
				hideOverlay(espObjects[player])
			end
			return
		end
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		local root = character:FindFirstChild("HumanoidRootPart")
		local friend = isFriend(player)
		local showEsp, showHighlight
		if friend then
			showEsp, showHighlight = on("FriendESP"), on("FriendHighlightESP")
		else
			showEsp, showHighlight = on("ESP"), on("HighlightESP")
		end
		local alive = humanoid
			and validRoot(root)
			and humanoid.Health > 0
			and root:IsDescendantOf(character)
		local origin = espOriginPosition()
		local maxRadius = friend and Arsenic.Values.FriendESPMaxRadius or Arsenic.Values.ESPMaxRadius
		local inRange = true
		if alive and maxRadius and maxRadius > 0 and origin then
			inRange = (root.Position - origin).Magnitude <= maxRadius
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
			if next(espObjects) then
				for player in pairs(espObjects) do
					removeEsp(player)
				end
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
			if not seen[player] or typeof(player) ~= "Instance" or player.Parent ~= Players then
				removeEsp(player)
			end
		end
	end

	local vehicleEspObjects = {}

	local function formatVehicleSpeed(studsPerSec)
		local unit = Arsenic.Values.SpeedUnit or "Imperial"
		local speed = math.max(studsPerSec or 0, 0)
		if unit == "Metric" then
			return ("%d km/h"):format(math.floor(speed * 1.097 + 0.5))
		elseif unit == "Studs" then
			return ("%d studs/s"):format(math.floor(speed + 0.5))
		end
		return ("%d mph"):format(math.floor(speed * 0.682 + 0.5))
	end

	local function getVehicleEsp(car)
		local esp = vehicleEspObjects[car]
		if esp then
			return esp
		end
		local folder = Instance.new("Folder")
		folder.Parent = espGui
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
			name = newLabel(folder, Vector2.new(0.5, 1), 12),
			speed = newLabel(folder, Vector2.new(0.5, 0), 11),
			healthBack = newFrame(folder),
			healthFill = nil,
			healthText = newLabel(folder, Vector2.new(1, 0.5), 11),
			highlight = highlight,
		}
		esp.healthBack.BackgroundColor3 = Color3.new(0, 0, 0)
		esp.healthBack.BackgroundTransparency = 0.3
		esp.healthBack.AnchorPoint = Vector2.new(1, 0)
		esp.healthFill = newFrame(esp.healthBack)
		esp.healthFill.AnchorPoint = Vector2.new(0, 1)
		esp.healthFill.Position = UDim2.fromScale(0, 1)
		esp.healthFill.Visible = true
		esp.healthText.TextXAlignment = Enum.TextXAlignment.Right
		vehicleEspObjects[car] = esp
		return esp
	end

	local function hideVehicleOverlay(esp)
		esp.name.Visible = false
		esp.speed.Visible = false
		esp.healthBack.Visible = false
		esp.healthText.Visible = false
	end

	local function removeVehicleEsp(car)
		local esp = vehicleEspObjects[car]
		if esp then
			vehicleEspObjects[car] = nil
			esp.folder:Destroy()
			esp.highlight:Destroy()
		end
	end

	local function vehicleAnchor(car)
		-- Only real driveable cars — skips shop/button props parked in vehicle folders.
		local seat = getDriveSeat(car)
		if seat and validRoot(seat) then
			return seat
		end
		return nil
	end

	local function vehicleHealth(car)
		local health = car:FindFirstChild("Health") or car:FindFirstChild("CarHealth")
		if health and (health:IsA("NumberValue") or health:IsA("IntValue")) then
			local maxHealth = car:FindFirstChild("MaxHealth")
			return health.Value, (maxHealth and maxHealth.Value) or 100
		end
		local hum = car:FindFirstChildWhichIsA("Humanoid", true)
		if hum then
			return hum.Health, hum.MaxHealth
		end
		return nil, nil
	end

	local function updateVehicleEsp()
		if not on("VehicleESP") then
			if next(vehicleEspObjects) then
				for car in pairs(vehicleEspObjects) do
					removeVehicleEsp(car)
				end
			end
			return
		end
		local camera = Workspace.CurrentCamera
		local origin = espOriginPosition()
		if not camera then
			return
		end
		local color = espColor("VehicleHighlightColor")
		local maxRadius = Arsenic.Values.VehicleESPMaxRadius
		local seen = {}
		for folderName in pairs(VEHICLE_FOLDERS) do
			local folder = Workspace:FindFirstChild(folderName)
			for _, car in ipairs(folder and folder:GetChildren() or {}) do
				local anchor = vehicleAnchor(car)
				if anchor and validRoot(anchor) then
					local dist = origin and (anchor.Position - origin).Magnitude or 0
					local outOfRange = maxRadius and maxRadius > 0 and origin and dist > maxRadius
					if outOfRange then
						if vehicleEspObjects[car] then
							vehicleEspObjects[car].highlight.Enabled = false
							hideVehicleOverlay(vehicleEspObjects[car])
						end
					else
						seen[car] = true
						local esp = getVehicleEsp(car)
						esp.highlight.Adornee = car
						esp.highlight.Enabled = true
						esp.highlight.OutlineColor = color
						esp.highlight.FillColor = color
						esp.highlight.OutlineTransparency = 0
						esp.highlight.FillTransparency = 0.65

						local centerX, topY, height = projectVerticalBox(camera, anchor.Position, 4, 2)
						if centerX then
							height = math.max(height, 18)
							local width = height * 1.2
							local left = centerX - width / 2

							local header = {}
							if on("VehicleESPNames") then
								table.insert(header, car.Name)
							end
							if on("VehicleESPDistance") then
								table.insert(header, ("[%d studs]"):format(math.floor(dist)))
							end
							esp.name.Text = table.concat(header, " ")
							esp.name.Position = UDim2.fromOffset(centerX, topY - 2)
							esp.name.Visible = #header > 0

							local hp, maxHp = vehicleHealth(car)
							local showHealth = on("VehicleESPHealth") and hp ~= nil
							esp.healthBack.Visible = showHealth
							esp.healthText.Visible = showHealth
							if showHealth then
								local fraction = math.clamp(hp / math.max(maxHp or 100, 1), 0, 1)
								esp.healthBack.Position = UDim2.fromOffset(left - 3, topY)
								esp.healthBack.Size = UDim2.fromOffset(3, height)
								esp.healthFill.Size = UDim2.fromScale(1, fraction)
								esp.healthFill.BackgroundColor3 =
									Color3.fromRGB(255, 60, 60):Lerp(Color3.fromRGB(60, 255, 90), fraction)
								esp.healthText.Text = tostring(math.floor(hp))
								esp.healthText.Position = UDim2.fromOffset(left - 6, topY + height * (1 - fraction))
							end

							if on("VehicleESPSpeed") then
								esp.speed.Text = formatVehicleSpeed(anchor.AssemblyLinearVelocity.Magnitude)
								esp.speed.Position = UDim2.fromOffset(centerX, topY + height + 2)
								esp.speed.Visible = true
							else
								esp.speed.Visible = false
							end
						else
							hideVehicleOverlay(esp)
						end
					end
				end
			end
		end
		for car in pairs(vehicleEspObjects) do
			if not seen[car] then
				removeVehicleEsp(car)
			end
		end
	end

	track(RunService.RenderStepped:Connect(function()
		local ok, err = pcall(updateEsp)
		if not ok then
			warn("[Arsenic] ESP: " .. tostring(err))
		end
		local okVehicle, vehicleErr = pcall(updateVehicleEsp)
		if not okVehicle then
			warn("[Arsenic] Vehicle ESP: " .. tostring(vehicleErr))
		end
	end))
	local function onEspCharacterRemoving(player)
		if espObjects[player] then
			espObjects[player].highlight.Enabled = false
			espObjects[player].highlight.Adornee = nil
			hideOverlay(espObjects[player])
		end
	end

	track(Players.PlayerRemoving:Connect(function(player)
		removeEsp(player)
		friendCache[player.UserId] = nil
	end))
	track(Players.PlayerAdded:Connect(function(player)
		track(player.CharacterRemoving:Connect(function()
			onEspCharacterRemoving(player)
		end))
	end))
	for _, player in ipairs(Players:GetPlayers()) do
		if player ~= LocalPlayer then
			track(player.CharacterRemoving:Connect(function()
				onEspCharacterRemoving(player)
			end))
		end
	end
	table.insert(Arsenic.Cleanup, function()
		for player in pairs(espObjects) do
			removeEsp(player)
		end
		for car in pairs(vehicleEspObjects) do
			removeVehicleEsp(car)
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
				Arsenic.Enabled.SpectateVehicle = false
				return
			end
			if Features.SpectateVehicle._conn then
				Features.SpectateVehicle._conn:Disconnect()
			end
			Features.SpectateVehicle._conn = RunService.RenderStepped:Connect(function()
				if Arsenic.Destroyed or not on("SpectateVehicle") then
					return
				end
				local camera = Workspace.CurrentCamera
				local seat = selectedCar and selectedCar.Parent and getDriveSeat(selectedCar)
				if seat then
					Features.SpectateVehicle._subject = seat
				end
				local subject = Features.SpectateVehicle._subject
				if camera and subject and subject.Parent and camera.CameraSubject ~= subject then
					camera.CameraSubject = subject
				end
			end)
			track(Features.SpectateVehicle._conn)
		end,
		disable = function()
			if Features.SpectateVehicle._conn then
				Features.SpectateVehicle._conn:Disconnect()
				Features.SpectateVehicle._conn = nil
			end
			Features.SpectateVehicle._subject = nil
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

	local function cityGunStore()
		for _, store in ipairs(STORES) do
			if store.name == "City Gun Store" then
				return store
			end
		end
		return nil
	end

	-- Buy StrikePad + Swiss Screw (real tool name) or regular Screw. Never rename Screw ↔ Swiss Screw.
	local function ensureStrikeTools(needBreakInTool)
		local breakTool = breakInToolName()
		local missingPad = countOwned("StrikePad") == 0
		local missingBreak = needBreakInTool and countOwned(breakTool) == 0
		if not missingPad and not missingBreak then
			return true
		end

		local function buySwissAtCityGun()
			local store = cityGunStore()
			if not store then
				return false
			end
			notify("Buying Swiss Screw at City Gun Store (shop UI)...")
			local part = store.locate and store.locate()
			local root = getRoot()
			local returnCFrame = root and root.CFrame
			if part and root and (part.Position - root.Position).Magnitude > STORE_REACH then
				local away = Vector3.new(root.Position.X - part.Position.X, 0, root.Position.Z - part.Position.Z)
				away = away.Magnitude > 1e-3 and away.Unit or Vector3.new(0, 0, 1)
				local standAt = part.Position + away * 3
				teleportCharacter(CFrame.lookAt(standAt, Vector3.new(part.Position.X, standAt.Y, part.Position.Z)))
				task.wait(0.25)
			end
			local prompt = part and part:FindFirstChildWhichIsA("ProximityPrompt", true)
			if prompt then
				firePrompt(prompt)
				task.wait(0.2)
			end
			local ownedBefore = countOwned("Swiss Screw")
			local ok, reason = purchaseItemViaShopGui(store, "Swiss Screw")
			if not ok then
				-- Last resort remote — still require the tool to be named Swiss Screw.
				ok = buyItem("Swiss Screw", "City Gun Store") == true
				reason = reason or "remote buy failed"
			end
			if returnCFrame then
				teleportCharacter(returnCFrame)
			end
			if countOwned("Swiss Screw") > ownedBefore then
				notify("Got Swiss Screw.")
				return true
			end
			notify("Could not buy Swiss Screw: " .. tostring(reason) .. " (regular Screw will not work for Strikepad mode).")
			return false
		end

		if missingPad then
			notify("Buying StrikePad...")
			buyItem("StrikePad", "City Gun Store")
		end
		if missingBreak then
			if breakTool == "Swiss Screw" then
				buySwissAtCityGun()
			else
				notify("Buying Screw...")
				buyItem("Screw")
			end
		end

		local ok = waitFor(function()
			if countOwned("StrikePad") == 0 then
				return false
			end
			if needBreakInTool and countOwned(breakTool) == 0 then
				return false
			end
			return true
		end, 4)

		if needBreakInTool and breakTool == "Swiss Screw" and countOwned("Swiss Screw") == 0 then
			notify("Auto Strike needs a real Swiss Screw in your hotbar (not a regular Screw).")
			return false
		end
		return ok
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

	-- Regular Screw → Lockpick / Unlock. Swiss Screw → Break Window (no rename, no minigame).
	local function isBreakInPrompt(prompt, swissMode)
		if not (prompt and prompt:IsA("ProximityPrompt")) then
			return false
		end
		local action = (prompt.ActionText or ""):lower()
		local object = (prompt.ObjectText or ""):lower()
		local combined = action .. " " .. object
		if swissMode then
			return combined:find("break", 1, true) ~= nil
				or combined:find("window", 1, true) ~= nil
				or action:find("lockpick", 1, true) ~= nil
				or action == "unlock"
		end
		return action:find("lockpick", 1, true) ~= nil
			or action == "unlock"
			or combined:find("break", 1, true) ~= nil
	end

	local function findBreakInPrompt(car, swissMode)
		local fallback = nil
		local breakPart = driverWindowPart(car)
		local function consider(prompt)
			if not isBreakInPrompt(prompt, swissMode) then
				return
			end
			if prompt.Enabled then
				fallback = prompt
				return true
			end
			fallback = fallback or prompt
			return false
		end
		if breakPart then
			for _, child in ipairs(breakPart:GetDescendants()) do
				if child:IsA("ProximityPrompt") and consider(child) then
					return child
				end
			end
			local onPart = breakPart:FindFirstChildWhichIsA("ProximityPrompt")
			if onPart then
				consider(onPart)
			end
		end
		for _, descendant in ipairs(car:GetDescendants()) do
			if descendant:IsA("ProximityPrompt") and consider(descendant) then
				return descendant
			end
		end
		return fallback
	end

	local function getScrewTool()
		local preferred = breakInToolName()
		local tool = getToolNamed(preferred)
		if tool then
			return tool
		end
		-- Never use a regular Screw when Strikepad mode needs Swiss Screw.
		if preferred == "Swiss Screw" then
			return nil
		end
		return getToolNamed("Screw")
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

	-- Break in with Swiss Screw (Break Window, keep tool name) or regular Screw (lockpick minigame).
	local function breakIn(car)
		if stolenByMe(car) then
			return true
		end
		local seat = getDriveSeat(car)
		local screw = getScrewTool()
		if not (seat and screw) then
			return false
		end
		local swissMode = screw.Name == "Swiss Screw"
		if not equip(screw) then
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
			local text = gameMessage.text:lower()
			if gameMessage.time ~= messageMark and (text:find("not holding", 1, true) or text:find("must be holding", 1, true)) then
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

		local function tryBreakIn(prompt)
			if not prompt then
				return false
			end
			if screw.Parent ~= getCharacter() and not equip(screw) then
				return false
			end
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
					or (gameMessage.time ~= beforeMessage and (
						gameMessage.text:lower():find("not holding", 1, true)
						or gameMessage.text:lower():find("must be holding", 1, true)
					))
					or (not swissMode and lockpickGuiOpen())
			end, math.max(STEAL_PROBE_TIME, (tonumber(prompt.HoldDuration) or 0) + 1.5))
			local msg = gameMessage.text:lower()
			if gameMessage.time ~= beforeMessage and (msg:find("not holding", 1, true) or msg:find("must be holding", 1, true)) then
				return false
			end
			if windowBroken() then
				return true
			end
			-- Regular Screw only — Swiss Screw must not enter the lockpick challenge.
			if not swissMode and lockpickGuiOpen() then
				return completeLockpickMinigame(car, windowBroken)
			end
			return windowBroken()
		end

		local probePrompt = nil
		waitFor(function()
			probePrompt = findBreakInPrompt(car, swissMode)
			return probePrompt ~= nil
		end, 2)
		if tryBreakIn(probePrompt) then
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
			if screw.Parent ~= getCharacter() and not equip(screw) then
				return false
			end
			local prompt = nil
			waitFor(function()
				prompt = findBreakInPrompt(car, swissMode)
				return prompt ~= nil
			end, 2.5)
			if tryBreakIn(prompt) then
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
			if roads and Vehicles.injectAuthoredPaths then
				pcall(Vehicles.injectAuthoredPaths, roads)
			end
		end
		while buildingRoads do
			task.wait(0.2)
		end
		if roads and Vehicles.injectAuthoredPaths and not roads.authoredInjected then
			pcall(Vehicles.injectAuthoredPaths, roads)
		end
		if Vehicles.loadPathAids then
			pcall(Vehicles.loadPathAids)
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
					if current.jumps then
						for _, jump in ipairs(current.jumps) do
							local neighbour = jump.node
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

	-- Studio pathfindingRoutes aids (refuel bays, U-turns, destination stop points).
	-- Baked for live games; Workspace.pathfindingRoutes merges when present.
	Vehicles.loadPathAids = function()
		if Vehicles.PathAids and Vehicles.PathAids.loaded then
			return Vehicles.PathAids
		end
		local aids = {
			loaded = true,
			refuelStops = {},
			uTurnPoints = {},
			destinationEnds = {},
		}
		local folderAliases = {
			["5thShop"] = "5th Shop",
			bandageStore = "Bandage Shop",
			bank = "Bank",
			bottomGunStore = "Bottom Gun Store",
			carRepair = "Car Repair",
			carSeller = "Sell Car",
			constructionJob = "Construction Job",
			dealership = "Dealership",
			freeCar = "Free Car",
			hospital = "Hospital",
			iceFruitBuyer = "Juice Seller",
			lemonadeSeller = "Tha Shop (Lemonade)",
			market = "Market",
			newCityGunStore = "City Gun Store",
			newCityMansion = "Mansion (New City)",
			prison = "Prison",
			riverParkResidence = "River Park Residence",
			sodaSeller = "Soda Seller",
			studioJob = "Studio Job",
			topGunStore = "Top Gun Store",
		}
		local function addUnique(list, position)
			if typeof(position) ~= "Vector3" then
				return
			end
			for _, existing in ipairs(list) do
				if (existing - position).Magnitude < 1.5 then
					return
				end
			end
			table.insert(list, position)
		end
		local function parsePacked(packed, list)
			for entry in string.gmatch(packed, "[^;]+") do
				local x, y, z = string.match(entry, "([^,]+),([^,]+),([^,]+)")
				x, y, z = tonumber(x), tonumber(y), tonumber(z)
				if x and y and z then
					addUnique(list, Vector3.new(x, y, z))
				end
			end
		end
		local function collectParts(container, list)
			if not container then
				return
			end
			for _, child in ipairs(container:GetDescendants()) do
				if child:IsA("BasePart") then
					addUnique(list, child.Position)
				end
			end
		end

		local root = Workspace:FindFirstChild("pathfindingRoutes")
		collectParts(root and root:FindFirstChild("refuelStopPoints"), aids.refuelStops)
		collectParts(root and (root:FindFirstChild("uTurnPoints") or root:FindFirstChild("uTurnParts")), aids.uTurnPoints)
		parsePacked("-1695.8,249.7,-1252.6;-1695.8,249.7,-1217.1;-1719.5,249.7,-1252.6;-1719.5,249.7,-1217.1;-1454.7,250.3,-4288.2;-1454.7,250.3,-4252.7;-1380.8,250.3,-4288.2;-1380.8,250.3,-4252.7;-742.4,250.6,-1154.3;-742.4,250.6,-1132.5;-714.5,250.6,-1154.3;-714.5,250.6,-1132.5;-442.7,250.6,-787.4;-442.7,250.6,-772.2;-419.8,250.6,-772.2;-419.8,250.6,-787.4;-433.1,250.6,-278.9;-433.1,250.6,-294.1;-459.5,250.6,-294.1;-459.5,250.6,-278.9;-341.5,250.6,-269.2;-341.5,250.6,-284.4;-1440.7,250.6,2937;-1421.7,250.6,2937;-1421.7,250.6,2967;-1440.7,250.6,2967;-1421.7,250.6,2860.2;-1440.7,250.6,2860.2", aids.refuelStops)
		parsePacked("-1779.3,249.7,-1304.7;-1700.5,249.7,2220.5;-1514.5,249.7,1933.5;-784.5,253.2,3214.5;59.5,249.7,1213.4;-1625.1,250.3,141.3;-1606.8,250.3,-789.7;-1293.3,250.3,-4447;-1610,250.3,-4175.7;-851.9,250.3,-3549.3;-1591.2,250.3,-3574.8;-1601.6,250.3,-3078.2;-871.1,250.3,-3078.2", aids.uTurnPoints)

		local function storeEnds(key, points)
			if not key or #points == 0 then
				return
			end
			local bucket = aids.destinationEnds[key]
			if not bucket then
				bucket = {}
				aids.destinationEnds[key] = bucket
			end
			for _, point in ipairs(points) do
				addUnique(bucket, point)
			end
		end

		local endsFolder = root and root:FindFirstChild("destinationEndPaths")
		if endsFolder then
			for _, child in ipairs(endsFolder:GetChildren()) do
				if child:IsA("Folder") or child:IsA("Model") then
					local points = {}
					collectParts(child, points)
					storeEnds(child.Name, points)
					storeEnds(folderAliases[child.Name], points)
				elseif child:IsA("BasePart") then
					storeEnds(child.Name, { child.Position })
					storeEnds(folderAliases[child.Name], { child.Position })
				end
			end
		end
		for chunk in string.gmatch("5thShop:-1422.2,251.5,2774.5|bandageStore:-436.4,251.1,-349.3|bank:-1253.4,250.2,-3644.2|bottomGunStore:-987.7,250.2,-843.6;-987.7,250.2,-774.6|carRepair:-1473.7,250.7,-4105.5|carSeller:-1445.7,250.2,2264.3|constructionJob:-1665,250.1,-1175.5|dealership:-395.8,250.1,-1132.2|dollarStore:-452.3,250.1,-1073.2|dronalds:-497.6,250.1,-952.8|exoticShop:-987.7,250.2,-873.7;-939.7,250.2,-925.7|freeCar:-1465.8,250.1,-1226.7|hospital:-1554,250.1,29|iceFruitBuyer:-7.9,280.2,-298.8|lemonadeSeller:-1468,250.1,-986.5|mainCityMansion:-758.7,250.2,1302.3|market:-497.6,250.1,-584.3|newCityDealership:-1475.1,250.2,-3852.7|newCityGunStore:-987.2,250.7,-4194.6;-877.7,250.7,-4267.6|newCityMansion:-1398.9,250.2,-3652.2;-1398.9,250.2,-3708.2;-1491.4,250.2,-3592.7;-1398.9,250.2,-3748.2|prison:-1253.4,250.2,-3334.2|riverParkResidence:-1529,250.1,-358|sledgehammerMoneyStorage:-185.2,250.2,1202.1|sodaSeller:-1414.2,250.2,-3451.2|studioJob:-60.9,280.2,-673.3|topGunStore:-276.4,280.2,-780.3", "[^|]+") do
			local name, packed = string.match(chunk, "([^:]+):(.+)")
			if name and packed then
				local points = {}
				parsePacked(packed, points)
				storeEnds(name, points)
				storeEnds(folderAliases[name], points)
			end
		end

		Vehicles.PathAids = aids
		return aids
	end

	-- Studio pathfindingRoutes → long-range A* jumps (hills / incomplete road samples).
	-- Baked coords for live games; Workspace.pathfindingRoutes.drivingRoutes merges when present.
	Vehicles.injectAuthoredPaths = function(network)
		if not network or network.authoredInjected then
			return
		end
		local baked =
			"-536.3,250.3,-735.8;-878,250.3,-164.3;-838.4,250.3,-739;-657.1,250.3,-1309.7;-401.9,265.5,-1306;-320.2,280,-1307.3;-302.1,280,-1308.9;-171.3,280,-1311.4;16.8,280,-1312.2;210.3,280,-1311.2;345.5,280,-741.9;9.5,280,-174;-395.1,264.7,-167.7;91.5,280,-740.9;219.1,280,-649.3;218.7,280,-1032.4;-161.8,280,-1085.4;26.8,280,-644.7;-87.6,280,-659.5;-216.4,280,-666.3;-100.8,280,-427.4;-296.5,280,-739.8;-119.2,280,-861.9;-401.9,265.5,-861.6;-966,250.3,-861.5;-965.9,250.3,-638;-822.9,250.3,-424;-1114.4,250.3,-737.3;-826.1,250.3,-1083.6;-687.4,250.3,-1179.1;-687.4,250.3,-978;-657.9,250.3,-749.2;-1458.2,250.3,-975.2;-1298.8,250.3,-1311.9;-1659.5,250.3,-1091.9;-1560.9,250.3,-872.8;-1186.8,250.3,-1247.9;-1205.7,243.1,-1075.6;-1224.7,232.7,-722.2;-1271.2,232.7,-744.7;-1322.5,232.7,-744.3;-1272.6,243.1,-1128.8;-1273.2,250.3,-2145.6;-1324.6,250.3,-1291.2;-1323.6,242.3,-1128.4;-1209,232.7,-625.7;-1186,238.1,-715.8;-1178.9,246.8,-766.5;-1180.5,250.1,-825.4;-1292.8,250.3,858.7;-1292.8,250.3,2471.2;-523.1,250.3,858.7;-976,250.3,-775.1;-976,250.3,-965.5;-1325.7,250.3,-2145.6;-1273.2,250.3,-3721.1;-1326,250.3,-3721.1;-1211.9,250.3,-3577.3;-1060.1,250.3,-3897.3;-847.1,250.3,-4159.2;-1225.5,250.3,-4173.1;-1059.9,250.3,-4422.8;-1124.1,250.3,-4299.4;-1248.4,250.3,-3080.3"
		local points = {}
		local seen = {}
		local function addPoint(position)
			if typeof(position) ~= "Vector3" then
				return
			end
			local key = string.format("%.0f:%.0f:%.0f", position.X, position.Y, position.Z)
			if seen[key] then
				return
			end
			seen[key] = true
			table.insert(points, position)
		end

		local folder = Workspace:FindFirstChild("pathfindingRoutes")
		local driving = folder and folder:FindFirstChild("drivingRoutes")
		if driving then
			for _, child in ipairs(driving:GetChildren()) do
				if child:IsA("BasePart") then
					addPoint(child.Position)
				end
			end
		end
		for entry in string.gmatch(baked, "[^;]+") do
			local x, y, z = string.match(entry, "([^,]+),([^,]+),([^,]+)")
			x, y, z = tonumber(x), tonumber(y), tonumber(z)
			if x and y and z then
				addPoint(Vector3.new(x, y, z))
			end
		end
		pcall(Vehicles.loadPathAids)
		if #points == 0 then
			network.authoredInjected = true
			return
		end

		-- Only keep waypoints that sit on/near real road. Never invent off-road cells that
		-- let A* cut through buildings between markers.
		local authored = {}
		for _, position in ipairs(points) do
			pcall(learnSurface, network, position, nil)
			local ix = math.round(position.X / CELL)
			local iz = math.round(position.Z / CELL)
			local node = network.cells[cellKey(ix, iz)]
			if not node then
				for dx = -2, 2 do
					for dz = -2, 2 do
						local nearby = network.cells[cellKey(ix + dx, iz + dz)]
						if nearby then
							node = nearby
							break
						end
					end
					if node then
						break
					end
				end
			end
			if node then
				if math.abs(position.Y - node.y) > 2 and math.abs(position.Y - node.y) < 40 then
					-- Prefer mapped deck height on ramps/bridges, not the road underneath.
					node.y = position.Y
				end
				node.authored = true
				node.jumps = node.jumps or {}
				table.insert(authored, node)
			end
		end

		-- Jump only when the segment stays on road and clear of walls/fences.
		local function jumpClear(a, b)
			local from = Vector3.new(a.ix * CELL, a.y + 2.4, a.iz * CELL)
			local to = Vector3.new(b.ix * CELL, b.y + 2.4, b.iz * CELL)
			local flat = Vector3.new(to.X - from.X, 0, to.Z - from.Z)
			local span = flat.Magnitude
			if span < 1 then
				return true
			end
			local dir = flat.Unit
			for _, lift in ipairs({ 1.15, 2.4, 3.8 }) do
				local origin = Vector3.new(from.X, a.y + lift, from.Z)
				local hit = Workspace:Raycast(origin, dir * span, network.clearance)
				if hit and hit.Normal.Y < GROUND_NORMAL and not isSidewalk(hit.Instance) then
					return false
				end
				if hiddenHit(origin, dir, span) then
					return false
				end
			end
			local steps = math.max(math.ceil(span / CELL), 1)
			for step = 1, steps - 1 do
				local t = step / steps
				local mid = from:Lerp(to, t)
				local expectedY = a.y + (b.y - a.y) * t
				local cell = network.cells[cellKey(math.round(mid.X / CELL), math.round(mid.Z / CELL))]
				if cell then
					if math.abs(cell.y - expectedY) > MAX_STEP_RISE * 2 then
						return false
					end
				else
					local ground = Workspace:Raycast(mid + Vector3.new(0, 6, 0), Vector3.new(0, -14, 0), network.include)
					if not ground or ground.Normal.Y < MIN_ROAD_NORMAL then
						return false
					end
					if math.abs(ground.Position.Y - expectedY) > MAX_STEP_RISE * 2 then
						return false
					end
					if obstructed(network.clearance, ground.Position) then
						return false
					end
				end
			end
			return true
		end

		-- Prefer short clear links; long jumps only when fully road-clear (hill connectors).
		local linkMax, linkSlope, neighborCap = 320, 0.55, 5
		local longLinkMax = 520
		for i, a in ipairs(authored) do
			local candidates = {}
			for j, b in ipairs(authored) do
				if i ~= j then
					local flat = math.sqrt((a.ix - b.ix) ^ 2 + (a.iz - b.iz) ^ 2) * CELL
					local rise = math.abs(a.y - b.y)
					local slopeOk = rise <= math.max(MAX_STEP_RISE * 2.5, flat * linkSlope)
					if flat > 1 and flat <= longLinkMax and slopeOk and jumpClear(a, b) then
						-- Heavy base cost so normal grid roads win unless the jump is needed.
						local cost = flat / CELL * 2.2 + rise * 0.55 + (flat > linkMax and 18 or 6)
						table.insert(candidates, { node = b, flat = flat, cost = cost })
					end
				end
			end
			table.sort(candidates, function(left, right)
				return left.flat < right.flat
			end)
			table.clear(a.jumps)
			local added = 0
			for _, candidate in ipairs(candidates) do
				if candidate.flat <= linkMax or added < 2 then
					table.insert(a.jumps, { node = candidate.node, cost = candidate.cost })
					added += 1
					if added >= neighborCap then
						break
					end
				end
			end
		end

		network.regions = nil
		network.labels = nil
		network.authoredInjected = true
		network.authoredCount = #authored
		notify(("Loaded %d on-road Studio path waypoints."):format(#authored))
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
				-- Studio-mapped hill / cross-map bridges (pathfindingRoutes.drivingRoutes).
				if node.jumps then
					for _, jump in ipairs(node.jumps) do
						local neighbour = jump.node
						if
							neighbour
							and not closed[neighbour]
							and (network.blocked[cellKey(neighbour.ix, neighbour.iz)] or 0) < os.clock()
						then
							local newCost = cost[node] + (jump.cost or 1)
							if newCost < (cost[neighbour] or math.huge) then
								cost[neighbour] = newCost
								cameFrom[neighbour] = node
								push(newCost + estimate(neighbour), neighbour)
							end
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
			local stopDist = route.exact and 5 or ARRIVE_DISTANCE
			local atEnd = not directGoal and index >= #points - 1 and remaining < stopDist
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
			-- Studio uTurnPoints / uTurnParts: force a reverse U-turn at mapped spots.
			local nearUTurn = false
			local aids = Vehicles.PathAids
			if aids and aids.uTurnPoints then
				for _, point in ipairs(aids.uTurnPoints) do
					if Vector3.new(point.X - position.X, 0, point.Z - position.Z).Magnitude < 32 then
						nearUTurn = true
						break
					end
				end
			end
			if nearUTurn and not directGoal and toGoal.Magnitude > 6 and forward:Dot(toGoal.Unit) < 0.35 then
				facingBackward = true
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
		local exact = options.exact == true and not continuous
		local function snapExact(position)
			if not network then
				return position
			end
			local node = nearestNode(network, position, 3, nil, SAME_LEVEL_RISE + 4)
				or nearestNode(network, position, 6, nil, SAME_LEVEL_RISE + 8)
			local y = node and (node.y + 2) or position.Y
			return Vector3.new(position.X, y, position.Z)
		end
		local function pinEnd(points, stop)
			if not points or #points == 0 or not stop then
				return
			end
			local last = points[#points]
			local pinned = Vector3.new(stop.X, last.Y, stop.Z)
			if flatDistance(last, pinned) <= 12 then
				points[#points] = pinned
			else
				table.insert(points, pinned)
			end
		end
		local function resolveGoal(position)
			if continuous then
				return snapToRoad(network, position)
			end
			if exact then
				return snapExact(position)
			end
			return snapToDestination(network, position)
		end
		local target = resolveGoal(destination.Position)
		local arriveDist = exact and 5 or ARRIVE_DISTANCE
		local replans = 0
		while true do
			local car, seat, humanoid = myCar()
			if not car or not active() then
				return false
			end
			local from = seat.Position - Vector3.new(0, SEAT_HEIGHT - 1, 0)
			if not continuous and flatDistance(from, target) < arriveDist then
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
			if exact then
				pinEnd(points, target)
			end
			local route = {
				points = points,
				final = complete,
				target = target,
				exact = exact,
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
						if route.exact then
							pinEnd(route.points, route.target)
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
				local goalPos = typeof(newTarget) == "CFrame" and newTarget.Position or newTarget
				local goal = resolveGoal(goalPos)
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
							if route.exact then
								pinEnd(route.points, goal)
							end
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
		local ok, arrived, reason = pcall(driveTo, destination, active, { mode = mode, adaptive = true, exact = true })
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
		-- Prefer Studio refuelStopPoints near this pump when available.
		local aids = Vehicles.PathAids or (Vehicles.loadPathAids and Vehicles.loadPathAids())
		if aids and aids.refuelStops then
			local best, bestScore = nil, math.huge
			for _, stop in ipairs(aids.refuelStops) do
				local toPump = Vector3.new(stop.X - pumpPosition.X, 0, stop.Z - pumpPosition.Z).Magnitude
				if toPump <= 70 then
					local toFrom = from and Vector3.new(stop.X - from.X, 0, stop.Z - from.Z).Magnitude or 0
					local score = toPump * 2 + toFrom * 0.15
					if score < bestScore then
						best, bestScore = stop, score
					end
				end
			end
			if best then
				local node = network and (nearestNode(network, best, 3, nil, SAME_LEVEL_RISE + 4)
					or nearestNode(network, best, 6, nil, SAME_LEVEL_RISE + 8))
				local road = Vector3.new(best.X, node and (node.y + 2) or best.Y, best.Z)
				local toward = Vector3.new(pumpPosition.X - road.X, 0, pumpPosition.Z - road.Z)
				local along = from and Vector3.new(road.X - from.X, 0, road.Z - from.Z) or toward
				if along.Magnitude < 0.1 then
					along = toward.Magnitude > 0.1 and Vector3.new(-toward.Z, 0, toward.X) or Vector3.new(0, 0, -1)
				end
				if along.Magnitude < 0.1 then
					along = Vector3.new(0, 0, -1)
				end
				return CFrame.lookAt(road, road + along.Unit)
			end
		end
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
			local arrived = driveTo(parking, active, { mode = "Civilian Mode", exact = true })
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
		-- Studio destinationEndPaths: park at the mapped stop (nearest if several).
		local aids = Vehicles.PathAids or (Vehicles.loadPathAids and Vehicles.loadPathAids())
		local ends = aids and aids.destinationEnds and aids.destinationEnds[name]
		if ends and #ends > 0 then
			local from = nil
			local seat = select(2, myCar())
			if seat then
				from = seat.Position
			end
			local best, bestDist = ends[1], math.huge
			for _, point in ipairs(ends) do
				local dist = from and Vector3.new(point.X - from.X, 0, point.Z - from.Z).Magnitude or 0
				if dist < bestDist then
					best, bestDist = point, dist
				end
			end
			return CFrame.new(best)
		end
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
		end, { exact = true })
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
								exact = true,
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

		if on("DisableJumpFatigue") then
			local humanoid = getHumanoid()
			if humanoid and character then
				local tool = character:FindFirstChildOfClass("Tool")
				local fistLock = tool and tool.Name == "Fist"
				local crawling = gameShared and gameShared.IsCrawling
				if not fistLock and not crawling then
					pcall(function()
						humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, true)
					end)
				end
				if gameShared then
					gameShared.LastJump = 0
				end
			end
		end

		-- Custom walk / jump (skip while freecam freezes the character).
		if not on("Freecam") then
			local humanoid = getHumanoid()
			if humanoid and humanoid.Health > 0 then
				local walkSpeed = tonumber(Arsenic.Values.WalkSpeed)
				if walkSpeed and walkSpeed > 0 and humanoid.WalkSpeed ~= walkSpeed then
					humanoid.WalkSpeed = walkSpeed
				end
				local jumpHeight = tonumber(Arsenic.Values.JumpHeight)
				if jumpHeight and jumpHeight > 0 then
					if humanoid.UseJumpPower then
						humanoid.UseJumpPower = false
					end
					if humanoid.JumpHeight ~= jumpHeight then
						humanoid.JumpHeight = jumpHeight
					end
				end
			end
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

		if on("UnlockAllCars") and os.clock() - lastCarSweep > 4 then
			lastCarSweep = os.clock()
			pcall(enableCarPrompts)
		end

		if anyGunModOn() and os.clock() - (Arsenic._lastGunModSweep or 0) > 1 then
			Arsenic._lastGunModSweep = os.clock()
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

		task.wait(0.5)
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
-- Disable Surrender Emote (hide emote UI button + block remote)
--------------------------------------------------------------------------------

;(function()
	local sweepConn = nil
	local hidden = {}

	local function isEmoteSurrender(inst)
		if not (inst and inst:IsA("GuiObject") and inst.Name == "Surrender") then
			return false
		end
		-- Keep SIDE UI.SurrenderUI (timer); only hide the Animations emote entry.
		return inst:FindFirstAncestor("Animations") ~= nil
	end

	local function hideSurrenderButtons()
		local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
		local anim = playerGui and playerGui:FindFirstChild("Animations")
		if not anim then
			return
		end
		for _, inst in ipairs(anim:GetDescendants()) do
			if isEmoteSurrender(inst) and inst.Visible then
				hidden[inst] = true
				inst.Visible = false
			end
		end
	end

	local function restoreSurrenderButtons()
		for inst in pairs(hidden) do
			if inst.Parent then
				inst.Visible = true
			end
		end
		table.clear(hidden)
	end

	Features.DisableSurrenderEmote = {
		enable = function()
			hideSurrenderButtons()
			if sweepConn then
				sweepConn:Disconnect()
			end
			-- Emote UI rebuilds; sweep while enabled.
			sweepConn = RunService.Heartbeat:Connect(function()
				if not on("DisableSurrenderEmote") or Arsenic.Destroyed then
					return
				end
				hideSurrenderButtons()
			end)
			track(sweepConn)
		end,
		disable = function()
			if sweepConn then
				sweepConn:Disconnect()
				sweepConn = nil
			end
			restoreSurrenderButtons()
		end,
	}
end)()

--------------------------------------------------------------------------------
-- Minimap (Studio top-down bake)
--------------------------------------------------------------------------------

;(function()
	local MINIMAP_B64 = table.concat({
		"iVBORw0KGgoAAAANSUhEUgAAAeEAAAcICAIAAACEs+4pAAEAAElEQVR42uz9Z3RlWXoeaL7f3uec6+BNABGIQPjIzMjMiEhXlVXFqiJZ9FV0I5amKbW6Jao1",
		"Uq/RzLSd7tZqaU3/6NVmNFqr1Vo9LbW8RDmORBbJYpFlWMWy6TNsRob3ASDg3b33mL2/+XEBBAIBDwTs+yhYQsJcXJx77nv2+baTM6+/CSIi2pIMDwERETOa",
		"iIiY0UREzGgiImJGExExo4mIaEsKeAi2gldffn6H/UUfXPiYLysRM5poY288jRERAM65Zf6INQYr/BGipTP6cctOAODDi2wWzeOVl54HAF2PxxJ0de7ZAcfk",
		"Qe8jAK+een4nnTavvPQ8FBBJ08Q7D0iUC6X23ljqdU3SRL2HSC6K+G7afm9tefwG35S7wyXa0eq19iyziufLNs/xcQqFCiA65+VcTihPPwoE4r3euvMAy3rb",
		"b+3LvrUy/UfsmNNGnYqYcrny2qtnioUcoO9/eN45Z8zjHh198lUFICLVuPr6K6dzuZzL3HsfnLPW7KTDssPf2rUPFGIgsmlvTFloLvirLz+vqvv3dXzrgx+p",
		"8iVb+LUU/elXP732x7nWf+uLP/vp0bGJ2tt4exJj5J/85h984dVPffP9H+24Kof85Ctvftx/5/n2gyu4q+jpr0ZZvi7vEtdd37bzDsvO9lOvfepbZ9/6wpk3",
		"7z/sE5FNaUcvnNGnnvepNv5Gmm8JXaLbv3n3bN63XtJ8tenuweDdhmo6turHGf61Wwez7uB7TS98usts58E2BuaPgm96Udl5Z4yqUVsOxuI/rO+c6Hj662E2",
		"lAYtT39+8LN3XF1VUlvfUMfWzvbiUy3tjd75H+92Tuy1kfng/NardcQjGQDPjF7oEqeS5bLySBytIaABxENp1adF7ycnqts9o6uaKbzsxDNGnbNNUT4qzfvV",
		"bIECRpjlQx/ASXUo5Vtmm2V0pjYSn+gmFiEXzOgPL15JxrLPffmIWBELZvRCGS1WjF3r0RErInLwUKcx3mznY20gAsHU/84U3ndKYouI8ap+of4FXaAaBniI",
		"iOG7aNu9wSFWIHj3nY9yzQHH3tHOlKnDzujT8AKfrdM4HiJmNG2F+gC0YPOysiEvW7hT1PqqWL6sxIwm7IilBsyEn/il5p/NHtmWfcXtXvJwzjc1l/7F0Lf5",
		"yhIzmnYMiTVp3dtS9fG2z2jvK56NaGJG0w4LacjMvx3wh/AFJa57R0REzGgiImb0jr+RN2LW/iA8kkTEjF7/gE40nkwmjObX8jipTxjTRMSMXveATtrCzmPt",
		"z3upruWhWnLtmXKiMBExo9ePFTuZjb/W8Bl7w3Z17Vvdg3R1dXXt6zrV9MZkNmGETWkiAsfeYZ2mOGfNYdvXBn4rV7en9eP9q7vePXjwAMDdvosnohNeOfiW",
		"iNiOxjpOdPZ5U2jKN6lZU60jb/KqypWriIgZvf7rUXj1a38QHkkiYkYTETGjiYiIGU1ExIwmIiJmNBERMaOJiJjRRETEjCYiYkYTEREzmoiImNFERMxoIiJi",
		"RhMRMaOJiIgZTUREzGgiImY0ERExo4mImNFERMSMJiIiZjQRETOaiIiY0UREzGgiImJGExExo4mIiBlNRETMaCIiZjQRETGjiYiY0URExIwmIiJmNBERM5qI",
		"iJjRRETMaCIiYkYTEREzmoiIGU1ERMxoIiJmNBERMaOJiIgZTUTEjCYiImY0EREzmoiImNFERMSMJiJiRhMRETOaiIgZTUREzGgiImJGExExo4mIiBlNRMSM",
		"JiIiZjQRETGjiYiY0URExIwmImJGExERM5qIiJjRRETMaCIiYkYTETGjiYiIGU1ERMxoIiJmNBERMaOJiJjRRETEjCYiImY0EREzmoiImNFERDtVwENAtPk8",
		"DwHbjcxooi2rTnkMpq5VVeFhYEYTbRkCKPQ7eciuPw4OyKm8ESOR3X40mNFEW0rTeDsPAoDh4SGRmMeBGU20xbIpHoLR3d6OzoAizwVmNNEWpMCur0g351uH",
		"dZDnAtiHSkTEjCYiImY0EREzmoiImNFERMSMJiJiRhMRETOaiIgZTUREzGgiImJGExExo4mIiBlNRMSMJiIiZjQRETGjiYiY0URExIwmImJGExERM5qIiBlN",
		"RETMaCIiYkYTETGjiYiIGU1ExIwmIiJmNBERMaOJiJjRRETEjCYiYkYTEREzmoiImNFERMxoIiJiRhMR7UYBD8EWoVCFengeCiJiRm+5gA4QRIiSoUQh2/cP",
		"8RC08PUkYkbvLBHCYYx83HIpg9vWf4hAAJXtfJkhYkbTXBZBGeURjO6AdMsh4gtKxIzGDqt1WJgiCoBu97/Fb/8/gYgZTU/HNJQdhkTEjCbCWkruK2TFQhQC",
		"t807G4gZTbTVA9prYuusm1hB2o4kQ1lcMZltjJp5BIkZTfSsAlqRFs3+hrB+GCPL/7HP7/m5+pZikiTfH/imheVxJHCeIdH6J7SIQr/1e29FUa69vX35P3ik",
		"7rmXml59ruElVfY3ENvRRM+GqjcI3/ziwd/9l+9peQU/+Pdv/K2sr2wy25Jr52EkZjTRMwzqQHIrCmgArbk9ks+QIkPGI0jMaKJnO5J9pT/iNIOmnH1JYD2a",
		"iIgZTUREzGgiImY0DwERETOaiIiY0UREzGgiImJGExExo4mIiBlNRETMaCIiZjQRET1jwasvP48Flsv1qYfGUOEmogtSWZ/jU3sc7MSdpVR4kizx+vL9RYtk",
		"tFevqvOuaO6c90GqkSqUS3Yt9PbTKEXgQ1NK/eTqHyZK4c1OXCXOqE8huySE5l/CX8MUUQpZYN07qWV0gW8mmj+jD+zrXOzrP+AhWpYUk2v58eY/OLJTj0wD",
		"YH4hr00O6bZfnFNEvHNdxw88uHZvnoSO2ub9qabv7l/ykYdkgEuXEliPpk272ZcddG8gZgvsNk7MaKL14LLcDitJi+G7hrBV9mEpH0yCglHHTo0FW4g+yHJj",
		"DeZhspaHqZ5IZCf2rRkxk8mQRqn4PMTviJ1nTVJZ2WZZ8WGHyMMv+IhQlYssddACGX33fs+8fYa1cR3Fz5XzLYFP2Ge4wPvLS5avBncO5Xrb1tJnWH7uruzE",
		"PkOjZlInNToNX+sak22+7ayKMY/u9M3/x8b9fr5dZcsHH6IxWbAcL4AHLjTtmp5VWmFG22D+pnRXZ/v9e31BnDPlAMzohTJaxXiRJFhLQAMw5dzOzGgY4zMU",
		"d8fZY4IFsjtCWRbLaIXne4kWyugPzl+e86naiOkHvY8UUFEYhWFGLzyy1fh1aAEZ3aGjZHfq3zV/M3uhKzmMwmDRsXdE7DMkItoBfYYfXPgYgBhJxrLPffkI",
		"jxEREdvRRETEjCYiYkYTEREzmoiIGU1ERMxoIiJiRhMRMaOxjZcJ5kEgImb01tzcSRIX8zgQETN6KwZ0pllrvt0rV7khImb01lsduOoqn+n6KaeOC/oSETOa",
		"tQ4iImY0+wyJiBlNRETMaCIiZjQRETGjiYiIGU1ExIwmIiJmNBERM5qIiJjR2IgJhJzeTUTM6C06dTD1SeJjziEkImb0FvsjxVTS8oH6I8ebTk4m40ZY4SGi",
		"7SHYJX9nplkxLBWCUqYZKx5ExHY0tlox2qt3DGgiYjt6E4MY80WwwIgYgRgYI0ZgBAoAUJ36gIiIGf2MxT5W+Kdj2oqpZuVEk0CDSlbOB4VMHaACiUyOJwER",
		"MaOfOQ/fnt9jEOCpprERU2cbWsLWnM13Fbvro8baNisObiQZFA4SJyJmNJ715ik+/gX5ck7y825FKJG4iQyKk7kzqgqBiEk1+Uf+b+fYlCYiZvSG7HGVePEL",
		"bRcrEAg0i2ca19y0kIiY0Rsa00YMoFg4eWfmsIgY4ebfRASOvaNlzLLhQSAiZvQWNZlx9iMRYffOM9yy2traAOlobjw78E592ODU8ZgQ0U7I6Nndfatf004F",
		"KnM+o6rzfP6pn6xVvY0Ya3ipIyJm9JMBnWnm4GRmUIfGK3qEs2fPKlRfzNSYWfkcqGZBZDXI1FiFX/QpqMmiiWwsmehrzw5KkKziDxkYGADQM3y5LmxkI5qI",
		"dkJGC8SpKwTFAgq1wc6AxK4KrHhmdzBRDGw4+7FL2vKDj7+bS+unh4gs2IoONByUnp8++KvD5yflgPT09Kz6LyoF9d5xkAkR7YiMtsYOVfp/7uBfbLzRXM3K",
		"UuttU7X1FvPNBV8w6xUtb3XN+6UGlJb8ceOK8Wl3M7t0/Mwn7v3w7lr+Iq+e0x2JaKfVOhJfjTU2MABUtYASNnBOirflfFi4Wb7Sc32iZbgLlqcTETGjn+gn",
		"NOu1A1aKwiK/KkR5ofZvwZSai82wMU8mImJGr6eZYvO++qGcTaHzFKAVYkz6qNI2UY0WeBDvvAvYiiYiZvSzkKJYsH0Fmzg1Aq8wEPzS0fcEgOrv3HgjtFkk",
		"LkVxodY0Ee1sb3zipI2mlp3/4MLHzOj5eafTFQb1TlX10seXnWYzNegwjACIAE8t3X/q1Mu1lTpU9fz5C1PfNt0Udt6mmnoExobqMtX0t699QuAB8V6Ni73K",
		"vGM81Ks6Vb/WjQLUKbzuxDsV9X637KOw0F+pXuEUboG+Eql1eCuU201MvaEWPFab9Hx0zkujG1rSDbbL6S9WSk352uEJTFCu5MJ8YAMrOn2aQ4MgEEGWOTES",
		"WKMKkakz/6OPLqsqoCImCIKZrAcQBFEQpFHDfmTJhft1L+ydCHJ1qNwYSI8mPtpXvI3icdtXtUGErPLE9c3WlZpTtOdKI0Ub1VWS0VX/fcW2vHizE5caMApv",
		"rOhOCaBF/pDAmnTeF7clj0aLRBbMaIUv5nd7tUyAFMW6vGn3qG6V9Sh9qqX2KCpEkkpX556Hvf0AbGA38nwLtktAuyS78s0HgFEgMMFYMjTy2Yme3t6nv72z",
		"szNJksHBwdp/NjQ21drA1ghE3PQw5LHRkdt37qZpBjG3UD1ydC8QAbjcUwfg+rX42HEAyYWP/PGTHefOfl/RO88F9Jqq4KFeg5e1XF71f1IA3/zed3bY+84a",
		"W6lOfvaffrr9cFsymYiRbf3neOdKpboHw7fHH6VhGHhfu8rXYrZ2Azeos/8Toqr4O4As8eJKBbt5ldyf+skfn5m6qxe31htBjHzhzc9XdOzqtfHaZ451d7LW",
		"8dSVJLTl4fRP/s77IpGqBjb4iU99+kFpAMCt23eebJGgpaVlaGjo1q3bYoxzLklSY4xX/8JzJwBc/viqMVbVWxsYI9ZaBQKbu33jIxHT0to0OjKepmkURgN9",
		"d6y1aVy++P53grDo/MwuiLOem1UYL96IMxBdwzA+DyBXH+24jDY+Crd7NM85HYMgMMZZa2fSeDqTPSCKmau1iIh6jwCQpV7c3V3nMDNzfQUIttIbQVUCESNw",
		"T5RHN/Qiceb1Nxe6eiRj2ef+5yO5psAnurkXeVW1gSm1TQ2PC0zQX+n7xc4/c+ff3XfqZpaErr1T0jSthS8gzrtHff1TDeqmVqgbGx2Z++BR04mmG/kwgTfO",
		"ZdZaiIF69apQYwLYtHe8o7/ShuSJnw3DBvfZkcnD95qvHpN3SpV4ZNV/YPrrj3ZqrWNSyz8rP9mkTSnS7b6jgnO+oanw2//gR/N+NfIjiWl6+vPZL46gMV28",
		"1uH+fyUY3e1LcKZACfZXJ7dWrWNf9Pb/cG/PyJ79B/Zs/BN40Nu/PerRIuIzHX0wMZPRY5WJuJSkaerUAXL8+JGp2sO1myLivXfOi8D5xxOsx0YG533weHIi",
		"CSq/3P1HFZcLrPjpH6lFf+pNe270f+n9s5XKRCF8MljTsYGBMS3Gtn88itO1/IHjveWdmtETftK3q4SyM5qKsnBjKs085mv/jfeVUV74ClWrR49jt2e0oDXX",
		"PjjWb3rKiLdMRmfqkMUTsVf/oPfRxnerCBC8+vLzC33RpwpUt85LaEIzc2dkMiNGXnrhZGVmLjgA4MSJozPt42vXbs0p8p2sb8yGhkSeqB0rXDC+J3/ul3ML",
		"nBcK3WsLHYglfeKTAjn0J+n3f8MGoQ1MKfOTq8+y0OzUjDbe7JJK60I9EiY0CM2TCzU+9WPGMKOn3tqBwRbaw05NYMRI7fltytMKFhoYJSqq6lLvUu9T3VJv",
		"MzHeJV69Xrj8kfOzah1QYwwgzz93HIAR0ScXzh9vbtTmxnnfI5fefHOR3zjx1lsy38qk+ZtZNnQ/82rWENAAXOLF78zhaM77XVJs9Qs0slzikfgl2tHObeTY",
		"O2s55Wpl3n3no1xzoG4TTuVg/96Ohb52/35/84H6Qmvo4q2V0YEJXGUy3xBFYeSfGEuptZ1l6huaANggDAT7u7qmu3U0TWIAp15+aXZqFEt1IoJkscncb7z6",
		"ytxD4L2NouNXPnjvSENrrsXfiCarQ6v+i1oO1YuzO7IdHXpjsh009s4veC3NR8G8d50t3Q2L1aMN4OFbN7QePTY6oV653/K2ENy4dWfBTmWPr/6/ztlIvNta",
		"A4MCG5TTsZN/9id6eh7O+VJ7e3sYhs65mZkBmXcz7ZVaVcQEwRMtPWOW02Mrc4+NijF/e6Dy9f/i3br49it7T3fubVv1X/SV/+L7O3LslRGT+spn//NPB3ts",
		"Gqfb/U9U7wv5woQbGXwwebC76/6Dntq1R6YGiCaq4x62NihfRETEO//+X38PocIvfKOswN2Nq3Qp9HNfeDMIAuecCHOac8E3q7Qlcvr06aXHOXFy1zOvdoiH",
		"d3BOndnm6686eIddM2+StkhGHz18cJFaxxf/889szVpHf6XnyJ69ZsA/VesQrc0v3JCduv4f7cWHf+P1Aw/O+O+uqdbxy3/zx3ZqrWPcT7T4ptE71dau+kcP",
		"Rrb1n9O2tzFMg3rbXN/dDGB/194nah06WpXGp3/qwH/yk0vXOn5ro2sd3nk2ordHRt/v6Vsog7z3w/cq5fHNHx/9dEYPVyaq+SRJk9l9hqoaRdFGnnmDqR+9",
		"WS4+Go6q4VoeZ+j2+I4c1yGAU/+twvfCYuCHVYrb/KZgCIHDRLOpG57nL6kmGXLzvbh3x1C/1Ni7wXQjM9pay2L0tsnoBYtkAhGxobGhEd1aGW2NsbWxd8+f",
		"rLiymR684b1vaGiyNtiwHqo/LtSj6baZ1NCU0jUM7bA7dOwdAAs7mA3p4/l427rYYRCnBu11KM5XfJ9/bI5dxtg7sXa3j72jhTJ6oXX2puYZfvnIjj8EIgLM",
		"WTl6ue8W8VJ/8Xgua07XNvYOO7kgrZFEO+dcMcZxVzNin+FGvu1clkxXR2qLLcCYqdLwe+++W+sgkqcX41AVYwpq6i63uogBvURM76S/hs1dYkZvZMNIjQ1S",
		"HwIwmhik6mHDaGqRl+m1XqbGXT/9fk3S9u69pUKkQM/DhzyfiIgZvZ4B7RAN3nn7s+0/TFIdLP3slaFO0SrECuDVNun1szfiIKp/aX/54v15SpBRXSkZHhgd",
		"XpeWpi57xiy7e4iY0bviJlxV7MPbFy2+hWpcaeouxy3Wl2vl6cyHkjy6eWssyfBSexE4NOenXRY+/FT/ZOe1uo8OtV7dv5ZtZ51moma5SwBKYIQlUSJm9O6Q",
		"K9Zp1AZNbFi4+/F1QTY9ikU6g/Dk4VLmMe+CZjZIn7t19C996W/9sw//gRwUnVnFY+X+y0//tX/xD//Ja2+8tvi3nXjppWuXLv2byX80noxEJsfJFETYBYu2",
		"YtdvoeahGXySoegl8AisMUbgEWSp/o2fu/jyochlfqHF+H7zH/zj6TWxIILaAlkr/fcv/+E/FYiBXfzf9YuXQxMZTj0gYjt6VxHN0qC9vfr1VpwMguTKo1YA",
		"z+0Z1VT7BxHHWGgjkakFQMz6XOrCMFzGzOraOFu2oImY0dtzYNTUFsvLaGyePXdBYcvD4b+tfjrN9Be6vxekbaF3QGt9U5tNrmUaihG4sgaFeR8hPR6boxOl",
		"3s6hd8bUeOiKOvSmR/WJln5W4eUH+NZSnZxQaDkrBxKy0EHEjMZ23BjNGAtozfJ+RKyUTeNzLQc/L0P7xI+2tzXX2SGRdiv51tL5XOvzOnplvkJH4eb41bH+",
		"O823jjUN71Wz+v0QLvZcWP48w7qwQcSyKU3EjN5+s8DSNHYuU/XGBEGw9KRwAUbKNnKNqWv65t2OCRNk1UKCoOfR/X2HX6rE5g8+PnBfG4Ny6emfzbIsL0Up",
		"NtbVFYIwSN3qn3lTrmX5Ge3UMaCJmNHbMqPL5UkROOcKhVIYNqjPlip6+OaWlqq2wScjtiuO72WoHx3qh9k3OmmgOtr1l/ydq0nhxZaimzOi2cJO7knujeaj",
		"SnPqJtbyzJ064fw1Itrx4zpqtQ5rAxGzzMZmYCUfaBQGR7r3BIGNAgHQ3NwUGAi0o8lGURQFaq158p8NbKB1lY57r+eu1/NMIiK2o7HMWR6qy5q2d/r0aREZ",
		"HR0CNM1cEmcAMucbGxoAOFUIktQfO3Z43pmBBSn90N1xQdWbEI7nEhExo/HMyiQQGBGIQnP5qBb0J04cW2j0yLVrNwIE+rlMrYpywDIRMaOf5S6i3juonjnz",
		"0qP+gcBaANeu37py5Xpt2y0AJ04cBXD16o3Hq/6KhoP1vlyEyXgYiYgZvc7OnTsHiFdfq5A87Ol7/dUzdY3N1hgAQRjWEtw/uedurZIiAIxO/okKypmwu4+I",
		"mNF4JkNBBu7dUfVJXO04cGSgt+cPf/PvtXV2pbmm2k40Piy2t7fV2tqqKoIkycbGxpqaW8JAANQ35fJRoCj0P+rn+UREzGis7/LzLsgDaCyUgjAolkqf/8LP",
		"N7a0Xrz1QIGx4aF0cjjYtzeJqzND42r7JXqXqVgAYyMDYWu7V3YaEhEzet15PdDdDcCrpkmsNkraTzxSn5qBQHxqc+onkvKkCcNr124A+sSGtl4aX24avTAy",
		"PBR7HePJRETg+Gis987V3jn13meZAEZE0gmblQ209/a1bHxQvQ71PfQK72vLcaA2d9HYQFQmj9/B6bp8kOOZRERsR69pbB0eD+RQMaKK06dPQzVfrBOBsdZo",
		"ql6bWtoAjIyO1r382uTYSP/9O52HT9T2wWptbYEiDG1zc5OIqqpNclmycduQExEzemc1kqc593hOi7VB5pyRmeBWQJxz3mdQqKaAvvLKmTCw1z86/+je7SxL",
		"56xHGgRTrWkYhXiunkFEzGisaEZ4ksRJEs9EcD6aKuuoal1j41hlIh+6MBBVoDwMyItHmj+67yHyYmf60c1hC/XQn//CyYGREYHv2tsyNSZadf+hY9aoVy1K",
		"6Qe4bXwE5VYJRMSMxmqWk/Yq3vsvnGkN7NSyRWmahN2NzovXJ7715IEQALw7eaTld75xViHvnLs5vSFsbSSeKFSmR0OraBTX3+7+wV77PC7xXCIiZvQKA9oa",
		"tBWd2rqLD0PoVCaLFLBYBdkCGK0aEd+yp3lkZHLq095p5gBRBBAAHoCoOBu7IM6Z5sxP8nza8YxYsSt711ixIqoiDpyPSsxozO0qfP25tnN3MrUF+GyZGwF6",
		"70WC0bHRe/d6Z3/+wP49Pk1tNmyNEZ9JuEdFjBpRw4DeHaOgzGjWXxlO6nFk+T81lAxkccWktjnXymNIzOi5nYZijIgqdPm7dkutkvHkDO/GxkJjQ2FoMIVY",
		"iFHO/951LWgzqeOfa/z5jp89dun7Z0fHRpf5g7+w79eaWhqqSeXrPb9jhSvkEDN6egizApnHDy/1w6MQjb90vPPitd6nv/nqzQejE1XVqfx+/fQxMaJZuaGU",
		"6+4+OjI8MfUF50eGxkWMsw0w6o3WRvBxzTvslpH04tQ1Bs0dTR1XwhW8cZqjtvZ8a1kmuQUlMaOnAtoYa4ypFZ3HquJVowgXrg/ofH/vyHgsYlpaiyPDZQCn",
		"jre6zF29Fqqqr1TgXX0hEAjEGhMdPbSvdzSDAjOhTruDU9dgm3534DfLXyud0GPL/8F/fut/S/vLJgtac+08jMSMhqrm84V8vui9rxWgBYj9nAHTsxaxM/kk",
		"Sy9cutvW1qrAd88Ptra0Hn/hVGCDB3dvDtx+Z/+PfymulMUYAEPl6VHVrHVgFy4c4JvD1sbWFgys4Kdacx2Sz5AiY58hgXPBp5PXe++9885555xzgvn/GfGq",
		"LrB2X1dXLpfL53JNrfu9ycMWJaoLfPjR++cSDSspqimqKZIl90eknd6azly2wh/JMk0zZUAT29GYs7EKlh+o1hhVj6ll7VShUJ1Mq3WNDRbeGkYzETGjN8Pp",
		"U6eMtblCCa46NWOltnYS5N7DR0HrgYsXLmVZJiK1rViIiJjR2MDdWM6LERuE8A4AjEVtAoyIirjMiTFsQxMRMxqbMxlRRL3GlUoQWAAuTsRMrZJkg3Dfked6",
		"e3pbW1sY00TEjMambJeVuexRf397W6sAjwYGZ3+1a//+dq0tHc2UJiJm9IYntKpaa9v3tIVBKED7nvaZzVYEiKsVCUPxnucKETGjsVlj9bI0C6xVwGWZmTUN",
		"XAB17sRzx3iUiIgZvRree2NWP9D7zJnTzmVDw4N72loBDAwO1wrTRETgHBasbQ2F2qxC7lZFRGxHL3fpmQ1Y3ebxb1HNFwpxXK2VLGozUNZh08OVPBN2JhLR",
		"tsno9NkvSqBAitSpq00H9N7XlroLrIWICERkRQ1rVQTWjIyOAWqtWeb6ZKqaIUuRZuoLpsQlpIloq2e0Ag2on/7wWbEIEy2XgjprrJXAiDESGDGTk+Xa7rHW",
		"5vN5cX4Fy0xbEwpEFcusbHuoFVuSugbfWArzCQOaiLZ4Rtean68NvY5nX+xQ78Pe2NVniKtJVkF91dpweKQPkInyeK54olEaMqjMXCxkqnr99EXFiHHqXHE8",
		"HxW86jKvLgbIkJ3IDsbv+dOf7v4uLvNkIqJtUOuIWmQmr59ZrUNFzPDkgDEmyardR49evnnLGtvZXWeNrSQmlwZQY4wVMbXBzrV18GwQPR3TIgLRscqj1Nd5",
		"XdE4aBWxR1/piLOEZxIRsc9w1q9QhEEkME5c792+wITWBEnsAQ+NqnbwUTLiXBZFhTBpdC6NwkIU5UcnHhmxcxI6CYacz0q5xtqOoiu9WqhC2GtIRBwfPc/y",
		"/HCBDat2SCAKP736vnj13jlAqvHEhBuerIydPPYJU81/3He+sb7NOze71hFJXmpdjUREzOh1X20jzRIjZm75Ymr56CAfRFGYHxzpzUfF1sZ91gYIdM7mGjwP",
		"iIgZjWe3YfMirW3vHSDV6uRkeSwKc947vupExIzeUtSYwNqA0xGJiBm9ZcvXfLmJiOt1EBERM5qIiBlNWMbQEtn6g8qJiBm9++IZ4n2WZvEaHyf1CWOaiJjR",
		"6xzQTrNivr65bt8aH6o515ZpypgmImb0OtY4TJrFVz54eOntu11dXat7kK6urq59Xaea3pjMJqxw/xciAvczXB9eXT4q7X8hNIH74FsPVvcgDx48APBB39XG",
		"qDnTjEeViJjRWMdB19ZGUbTWGkXeFNRz/DYRgbWOZ7O403osvU1ExIwmImJGExERM5qIiBlNRETMaCIiYkYTETGjiYiIGU1ExIwmIiJmNBERMaOJiJjRRETE",
		"jCYiYkYTEREzmoiImNFERMxoIiJiRhMRMaOJiIgZTUTEjOYhICJiRhMR0YoF2/0PUK+6uU9A4f2aH8ULvKzqJwVQGOWpTMSM3opyBSuCzc3oMFrrM/DFWPyq",
		"7mlE4Y2pRhDGNBEzeku1oBVBILeuTmapigE2L6OMXWtG1108ApVVBLR44/Jx9VCvpAFjmogZvbUYIz3XH+6AlyG6tbqOARFfUIPKMSdJAOH5TAT2GdJWupkw",
		"Fd9cAhvQRGxHb81yx87gm0qrq3WYkUmfj1fzs0TEjH6mRJBl/lM/f1w2+zoR5uS7X7m6lgcZ/cz51fYZAl5MHHJoBxEzeitKYo9NH3u35masxNEqM3pmdAcR",
		"MaO3Zmt6JzwHUeYsEYF9hkREzGgiImJGExExo4mIiBlNREQ7IqM5BoKImNFbN6CNcGYdETGjtx6BZN7ly6ExVkSwTisJCZj6RATOYVmfPFXVcmXMmMDawIiR",
		"tQWsAInPjEggnFJNRGxHr2VOnyB1qTW2u+n0nsLR4wdP56KC927VMW1EKi5rigu5cpiqWmN5WhARM3qlDWcA4r3LXCpGLl+5d+H85X2H9n9w6TtpmhgJdA2L",
		"4Hn1kQnUu/HyaCWe8OqFlQ8iAmsdyyxAw+Uio+rVpQ8uJdaGNm/OfPrgw55LzU1N1qqqVy/qRVc+4kNEAhskSVpfbD5w6CVRvd97PU7K1q4p94mIdkVGp3A6",
		"YoY0BJLeG2MN9Y1i5OCLZ37vX30HwAuvPacG6mxYcEEuDhCuqPNPxCRJterSjpaSRl3NTV0/ev93Cvl6I5YBTUTM6CUi1HnXmo+yILjz8UNrZGx0LLQ2isIf",
		"fu07jQ0NEPTdeATB0e4T8fjgnvbWwYkyfCqydA1HjBqxY5PDzx98rX3P4d//17/ptecT9a8DDuKMhfMqYMWDiJjRC6SoV5fLFQrVki/4Yl4AdHW0eFV1yb6O",
		"FgCAAgLonuaq94VwotBWF/UO90bhYq1ghaoXZMFEXD7Sffq9718GLp/8sTd+8LXvfPu3vnHs9aNpAu+Qi6yXjKVpImJGY779ZE2lMnn84Bk/jjSNbdjzuJdT",
		"Hk80/OQbr3qfVoYfAgL1o33jiLD4BBgbIEuCD753BUDPx5UwNGEYfvO3/rj29Q+/d632QWtz46lP7x0ux4FwxjwRMaOf5L0r5IpXb32YKwclm9vT3GCMTG18",
		"IqLGAiqQ27fviGZQY4I0KPisHkG6YKSqei/mwflxZPHe9kYAqql6+CTubGt8or0soqpX3h848YmDI6P9YRixPE1EzOinnp8NxouJVG2QF8ADuH6zB96Ld7W4",
		"PtHV5IslsWHQGAxWB0tZQRYYj2GMLVfKLx5/c+Dqu2rDhSsYAvUuLdcuFMlAWSMWO4iIGb1A7bgUROVCPFVvUD3w2p4oqX78nY8lDMPQ4NHd9MRJV18fZFqf",
		"q/PqF9ot3Hsfhbk7PVefO9HlKuXM2dk1E8jU/0EAVZel+QBBsTiaj02Z5wkRMaMXnGCikQ1qYSpG0kpSaCqOoS6oC17//PHh0cmSCXNeVNTr4vvPqjFBEpcf",
		"ZoOFqBSMRh4ekBu3H9RKG7VvOtrdAWu9mjCwI+jTigRByEIHETGjF9l7WwGo92GheP2d65N9PflCzvUll7+efvkv/sVLV35YTauBDbB0kqqxts7WQxQdSW1t",
		"juNtbZrP3/r2RYmrsEHpzuX45dd8U/NktWyRF6hCFxnbwfgmIq6pVGtEm6RSeeUnTn73K1oFmjsbwzC4eeW6sQFSXX7eeygU6qYjVmxzXV3/hC107H31k/v6",
		"hyesER2fEAiQLLoQk0IktPm1L5RquJYTEe2Ade9EkCZZ7eOReOATb554MHipVKwP7IrLESJTDfNL3/8oHu7P2SC59+hyUn3jpz6TVieXNQtGRFUfDd9Lp/J+",
		"9Saz8TrTuFSthoiY0Vt+1bu4mv7Er77U1zNirRUXNda3eNXVFRxEJIvjFz956K1vKABEKJb2XPj+lVdffXV5I7htNZ482PnC+9+/tHfv3p6enlU8h71790Jx",
		"rL37Oz1fa4pa3JrjnoiY0djUuS0yMjzZ0FhU1TRN1zQLUMR7F5aKZXVFscU9BVXv1adZspyiiRHj1Y1NjqRZNUtXWasolysAhsr3czbP0jYR7YS9sqw1aZpl",
		"2TpM0zbGTI5Xfv6XX2o/WNfWWlBVEciyGIgxYnuGbnW+aEdGRlb3BEZHR0ZHR+6Wb+RtwYO1DiLa/vuwTC31v34N8/Hx+LmX92eZu3Nu/Mzp07rcXRUVIoc6",
		"Xszlogct570HoCIyMjy40ueQN0XvGdBEtFMyet3rJ+XJGMDp06eXf5lQVWvMuXdvA1os5KeHYJvAtg0MDGBlU3W8gKuCEBEzeuGYXkU1WBUvv3yyltcAzp+/",
		"oKqeZWUi2j31aBGznH+b+vTEGGOMOX36lHApUyLaVe3oJCnrMjb2DsP8Srfg4gr+RMSMXpMsy/a0HzJLNZOdd8MjPStqTWc+U/WzUlq9AiFPCSJiRmNZ/Whi",
		"UNdYvPzWLRF84vVXFq422Lg8MuDSMFzWEGMjIuLzuTpjAlWV2Stv+Cc2ECAiYkbPP67NWonj9N1v3uhsawAw9ugWFq9c5Ja1DL8IMm+GxyvHWo/U5Rqdz/C4",
		"5KFJXGWHHxExo5ce1wax4jOp9IpphqoJwqnlSac3Y5lq8AoEolAjyZINYPU+KhX6Pr559g/+qPDlv1poSF2WyqyGe2djHc8JIgLHdSw9S9t5G+Ve+MJL6r2q",
		"GqA2gMM7p95bEQPU/te71Lt0sjL6dDtaxJhZ/0SMmCAAssqQAQIbmOkhGcYYwxEZRMR29HI3BfdZGOaOd3xaSwPeu3J1wqmHajFf79VNxmURo/DW2GK+zpjg",
		"ROlIX/lalk2v4CFqjMRx2Xk/k72qSMcqpqXhx/4v/7WRYpzEBlK7UKk6cJwHEe34jJ4e0aZrXlLZqteKDFTylfpiy+TIRJJlmUuam09Wk8lH7kKp0JBlaT4K",
		"cw3FscpogGSyMpILiwIDUfVBeSLtvVExxr5w8sTsUctNJd/c2DpZidX7cpqW48QIwiDvvYOqGIHCq+p8f4LhHuFEtJ0zWvTxtoBrnPhnk6yaxEk2KmmMtuAQ",
		"LABUJycAHG14RXXq6SfD1XjSJaLN4eEsHEuSqg2MOnvxrasdHR2BDUqFxievHFIuV62RKFcsVx+44L6YsLn9UKU6gTRnJPTwORNasXOb9ppVXZWTVIhoW2a0",
		"QBT4Jr6t6zF4LUDQn/X92da/sj/oHotHnEsfj8wAsix9/J1BuKe528PnbfF3st98iDt5X7SRGf7JR79y+G+88wfvZi41T14zjDFevfFmsqv6ew+/0R51Tj76",
		"jjGm6qsAytnkq61vHiwd894ZmNqflvh4T35v81Br4pJ5Y/rcuXNQiGGCE9FWbUcLoOs3utiISdM4SWNVnTs/ZVZKqmqSxQpv1erUViaqKj41ApGpoR+ycF1G",
		"VV0+KiQ++Wuv/095WxCRcjYZ++rsmYhOXU7zQ/2Di7ejrbVsaBPR1q9Hr8/j1JZqXt62VSIiUlv/uRbNAgCvvvJq4pLFf5FAatscjt0cqUgZ6iEGIqo6UyMR",
		"MVVXdsismAXGUAug9+7d51lFRLt6jf9n5+jJ57xmmWaZTzIXZz7OXPz4A59yjQ8iYkZvmquXPppuEc/9J7WqCRERM5qIiMA1/olWxIoVG6zwR4LaPViGjAeQ",
		"mNFEz+yuU8xI9qg8FNfj6PJ/ajB+lIVlkwUtuTYeQ9rtGV0bpMHXlZ5FC3rMjf5085/a/yvPvfvtHw0PDy3zB/9U959vbW2sxJXfvv/PA2GriHZrRp8/fyGQ",
		"IDldjVHNuQIsX1wiYkZvoRY0PHzzDw8cPfqJDw7+QRAXkWF68ve845m5UDStgFNXbxu/Mfxvy1+rO+5XUOv4t3f/cTbEWgft+oxWhTEyOjo6+sFo/Fad/RS0",
		"BCOBAcwCm9JaGANjxQpEVIwanhC0CK++KWhtaGnBwAp+qjW3R/IZUvYZ0k7MaFXv1Su81+VsrjX1UWe0B+9j5I3+STMuKpk6UQ/AiMy0nj18VaupJMPVwWbb",
		"4sK0qmWeELRka9q5bIU/kkFTKDtKaMdltKrP2UIuyCu8WaDALLNGOJlZK9WN/cK9prTxn1373xW+1pGY+WwiHbNhfmZFEYX68ezfe+GvfKf3D+oGOtrjVjkm",
		"Sz0l9YrZmwmcP39BMLUjDKsnRLRbMlqhuaBws/xxriWfuXTeYoUA5bC2a6zu3Xe4EATufTcWj91ru2jiANCcydW+L/NZU77xM/t+qjxy35igVowWkUpafm7g",
		"YFJ3KrjfUsqaRM3U2tHzbjugLrJRYMLZ3zC1hKlRQJSbIRLRLslop64uqP9g6O0f9H/bwMzp4lOBcUiM/vyVQiExsUNfuRNd986eNo1JaHwOXjG9CJ+BcT4t",
		"hKUvHPiFVr1zuWd2NVHGxm+9EJzQNnfkYP39yRBAaMy8fYpBmPt++M07Y9eLYZ1XB0C8ca/Hpd7OyXdYJyGiXVbr8OpLQV190Dg3LwXwcCWTNcuNe1HUZMNj",
		"3vRUy4W2pkpmHbzxcx4nHxR7J+7/dz/6v/1H5s/FPp1d0QiCfAWJZLh8Y+TCtUvGmGRyKE4q9peakfnZ7XoBbo1eq7rKaDY8tVmASoZq44SpR7tDhecTEe2u",
		"PkOv3sM//VmXtw1XJxpGKhUN+0fHsqF44rV9kTMFDb2Zv44cmqgxatHJDMjw5MLQM6VknyVi7dDIxHi5PDZ02ydzf3UxKJWCOp3alhyikhmTC3IMaCLi2LtZ",
		"/YQektdq78Gs4ve3nIgquc/Uf3G0degfXfrb7YW9mU/n7YHM4Iv1eyKfLdQzGIQDxlhnCsO/0t+MBhfpPNeM6W0Epp6L1lrYRETM6KlitNiKHz9RjAtxx7vt",
		"9+tc0y9W/03vP8rGksaoxflsgcUWJIVPnmuAW7Bn79UTn5IwuHfpn+eyJBO75J4yoiYJqlUz2YC9DixJExEzuiaEDGqpqzKaPozjuNqXShwaawIJ5g1WhVoJ",
		"sqz6v7z3N2o7ei282Zc2FpoiKSwZ0EZtNZw8+uj1iXOTDGgiYkY/OZE7gBs1aPN5iZBFCKG62G6KChUxe4qdS5ZSnM+Wsyujig98OFLsbTt5eOSjAZ5MRMSM",
		"fmqLAg+tzTBc3tDkzGfrOII7cOFQ6UESoF46HKcpEhEzesGJhptTGdfQ53KaZ0ATEffKwtacD6mcBE5EzOhnlLC1hT5WnbMGxhq79g0+eC4SEXb3XllixPgs",
		"mzMgb7DaZ8U25pq9uqnSiYixtjbbe8mAHvcT2eRAm+uGjVf9zMrZZMnUT4+8JqIlmzV28eXYdszd7W7JaBFxLpvwk6XGJp21sVbs4194/tcn0rG3ev6kGEyt",
		"wuGdq44O1+cbF18jycBMuskXms48/+Lr1wauDo+sJqObm5tVUVd/8ubolYItzjOpkoie3A/PqxvPJuYdKFD7ZGRykYl2RkwHu+RFdc7losLzuZf33WiKHs8R",
		"hFN39/s9XnXv6NHWxqICR/a3VfLpw2P9Nx/dNMbMeRwrwcyJYcWq+H257jvfvpXLR6t7blEugkpTruOKXiwKlzclWmporLrQhi81vAo/z5rcCoXBQPxoOB4M",
		"JdwBMb17ah0qgalWJv7wz/634azLrwD5X/4SAAs8BABc/crvB/taO77y38Bfw6yMFkjqk6GsX6YX4VMg0OC3ev9+ZDqP3HgpLKzmafX19gF4OHC5IWx0y6iu",
		"EO3yRnSi8Z6w8wv+S0kWP92R49VHQe5G88e/fe+fteU6Ms2Y0Vvr9Vuo882YXOrS65OX2/O5ORdWYy2A6VWS0JzPedWJ3/xj88uNM4UHERO7Smeh6093/EaW",
		"TS1mLYAqxCLXWXo3fhdQVR0aGlrFM68L6r1jlYNoWW9zVY2zStmVzVOjHmrVwiSLZaf0w++kPWcl1bSSlkXm3+1QxBjvhqrx3Juff/eVORMY6+KoVGid1HTm",
		"TkogqSbNYWvLYHs1K8/ZFOa9s+/l89Fa1vj36oXjIIlW0MNkDMw8bTKt7V8qHNexFQO6KWw+1fy6ejXzzmyxgpIG/2FbripY4CW0YhGGH999u/cXi3Xlstqp",
		"ArERG0qk0CSLK64y5+r94ssnBXL+/Hluw0JEzOj5xxdX0slXmj/5yezzSRabhdqkIvhPf/Jbua+q6Lzt1pF4UAPz6P6BZPJmJbMz+zgbsePp8L6024o1C1ZU",
		"2OVHRMzohUfXpT5NsngymzAL1w1kGFeq79ea3nPukZz6//PB34g0Co990TqrorPb6ZnP6sL6+EGV802IiBm92j5DLFClmlnbIzDFqA6QORmt8F5963AHIDri",
		"5ztSYYrEabbJS4QQUa2DHqpPTftS+J00gWW3zTOcNYISirkZrQqNXWVmp9qnF0MVyE7qiyDapu9fIyZn8x7+6TtmBxfanTOBZZdm9OIFEyywzimzmWgLvEU1",
		"QFD2k5V95SxLn24zeXXVQB4M3ouE8wxpnqY29uzZkyTpyMgwDwfRsyhxhCYaS0b/zpX/fqGbWlVfsKW6sGFnTApjRq+zKAq952wUomdY6wgkaM91LNLY9nA7",
		"ZoUyZjRmr5G0lh8/ffq0ql64cFE5TJroGcf0DpjkzYxe8ate9lWsQ0Wbx5KImNEL5KyH9/CLdBWYBb4mMEdz+2fKykREzOj170yIglxtwv6Cq7GIIn16Ja20",
		"wdb9V+1/7u2BcY7gICJm9Drz6vO2eHfyeq4h50NvFshZgckkReXxJEMRMbAWHtB3797UYjsTmoiY0etf5YhsNBj33+39fVm0ISyQhrBpaiQ8TJxVY1dVkbpc",
		"wSjXbyYiZvSzrHW02HYsMV8csVSnN8qq1hca/qtT/8Ot0Wv/4srf/fD6I4/e06dP87QgInBf8GfRmnaaLfJP4RMkxaS5mDTVZa1aDl4tfv7r//KP9tUdysUN",
		"4GJJRMR29CauXzqejJZMPv8njbXPdKDuMi7v27f3q3//d5pH9uo+N2tcB+vSRMSM3ihWzFg69tmun46/k/m9TmbP//dZIR8U9+6BiCogAQRQD/Wzk3pm2pKZ",
		"WtODiIgZjXXcTtjXR42JGRbVJ5a2E6mtoiQ+hQfScaiHLcCGUDcTxwVbrH1v4hPnn1rMRTG1XiJHVxMRM3qlnLr6sP7rt7/yqryWVDS0AuCV57tFpzJYgVis",
		"EWgyDgBZVaJ6BAV4JyIQ+T39V1bscDz4a/v/fLG/ruof75j14dkPVSAKBYxhUZuImNGr2gEgHxZ+eOKd7j9+rqGxXoDbI9WgvZhkCu+iKLe/uN+5bGo2tyrg",
		"oL72nwLpqT6wsCPJYF/yoN3v7TzY9eDmHQAHjh52H3rx8FNrmqr3bEsTETMaqxmf1yL1wz97qyf1BnouQfflsKtJx6ppfaHpwKG/AJ9OFTcEc4rOeVMAfGeh",
		"6+s9X0l8Yj42AMRLdqPa2NTdeHmvlwrPJyJiRq+t6AFv0qhOoAXjRXC92R492ATz2vFTiaaLDL9TeECdupzJ521husNRsiAqRXUMaCJiRq9T0UN9Ugj2fC2/",
		"x+ukGUrRbYxWrTcqyxyFPdMzKCpevVfPIjQRgXNY1oWKBN6VXygPPApsYW9oA3hYWJ4NRMSM3hq9h6lW9prhl8YApC5T0cynsoyfw9x/mPUBERFY61iXzkMR",
		"ZC2fNPe+cbvv+HUfZNfd2V+P/lLq4oVW6U98ournrHoqXjJfTVycQ4MDS9JExIxev5JHOq7NPxfqeJT4ODLRYlvJqv/3o78y71fPn78AVbPPPnzIjCYisNax",
		"bsTADS9raqACgQnm/ffqmVcExhiWO4iI7eh1Z5/YKMDDY8HRHbroSA+eS0TEjH6W/YhFW0okkAXq0VXHUgYRMaOxKRUfG2t8v+mW936+PkNV1ZahduF+tETE",
		"jMaG7wxgxWYu/Vd3/j5Eno5hhfeq/9e6/xpgShMRM3ozYlpE2nIdC311ZvFoIiJm9ObINGVGExEzGlutt9AsupOhQgXMaCJiRm98QIskLim7CbPYinfqVTXk",
		"jG+iXeqNT5y00VRn1QcXPmZGY8N2oZ1Mx59vOv3L+3+9mpStBAtlNIDhu4PKDkMiYjt6I6scGbI6W1++OzmRjdvNm3VpxDD+t8l13cLaFe53bCEKgYPjAdye",
		"E5JFBF2dex70PGJGb0JMe81Sn2Q+VTFLfO8zU3aTJalnz+TWv/EazwYro64BpeX/1Eg6lMUVk9nGqJnHcDuuGJFMZC7z9x/0iRUoXn35eWxgxWOpjPbT/3Zk",
		"LVYAB3gRyPS6oxutqbkZirriyZujVwq26Nk5uXUnOplyNvF66XMtnzp04bsfLP8q/rnWn2toKcVx/IOBb1qx8/wQ76G2bn8VsrJvP103cL8vHk4ParcEssGv",
		"14IZ/cpLz/lUpVQ19UC8MzPaCEwGKeDd776baXbm9OmNfw75XE4VLa0d17KLNhS+XbcsK+KStLvt8Avtbzy68rCvr/epb8nm/cHje5/f0942GU/8IP66eXor",
		"CQPwyrxlM9pKMu4OfLaxbn/u1teG3Hf14P6ODa54BIst9WYw+Yc+y/udutG1NTI27quntWAWen+tx29JHinER+3zfrW3txfAtf/jUkPYNKIph45g60508gGa",
		"/17y/91jvtURNs1zz7nAS/y//t2/Vc5GQ5NridriedNYkWd/xNaNaSRj2cQDSUazvOBB76OtVY/uzh2G7txtRhR76roGbwwf2F96li9yIEsdwePhi8+44k3r",
		"Y09u70p/5ET4AsIlam7DGOSx3bIpIVZMKLViNLZan+HtvltRLtix7Whrh0eGTx586Zm/yEu5N3hbhPvWbv3qpEmSyuGO4yv6qd7R3iStGBMsciaU6ko8vFvf",
		"2z+6VOyIfKZbKKMPdRx+OHxvxxZJdct01/BOdxudMyvU2dh5t/8WX2IC92EhImJGExERM5qIiBnNQ0BExIwmIiJwvQ6sbh8WVT179lxtL8PTq5lwyG57ImJG",
		"r3s6qwIQY4MAIuKcm07bZWXuuXPna4tQmxWuhUZExIxeOqAL+UJZyyNjI+MjYwD27t0rYgIbLHPKX23iSZqmk5NlnkxExIxeT977XC7f19dz/cZVEVH1D0ce",
		"GDEfXH5v2Y8hmUv3t3TzTCIiZvSzaEr7KIr2tO+p/WecxCsqLItImiU8jYiIGf0MKx5Zlk2vhGdFpKvlwDJ/9sHQfeXC/ETEjN7IyL4/eHf57WhuckhE4Pho",
		"IiJmNBERMaOJiIgZTUTEjCYiImY0EREzmoiImNFERMSMJiJiRhMRETOaiIgZTUREzGgiImJGExExo4mIiBlNRMSMJiIiZjQRETGjiYiY0URExIwmImJGExER",
		"M5qIiJjRRETMaCIiYkYTETGjiYiIGU1ERMxoIiJmNBERMaOJiJjRRETEjCYiImY0EREzmoiImNFERMxoIiJiRu/Kl8HwhdjJutsPB0HA40CrwPNmSxifGG+o",
		"b/Te81DsPB/dujRZHgvDXFtrG48GMaO3mfY9e2offHz3o8aGRuccj8kO8+lXP2Ot9d5/cPn9kK1pYq1je3FZlmUu15QzxqgqD8jOo4o0TVVVRHg0iO3obWZo",
		"aAjAlXsf1dc1sNaxI42OjLx/+e0wzLU0t/BoENvR21JdqY4BvYPt7dx36tgZHgdiRm9XDOidLcuy+4P3eByIGU1ExIwmIiJmNBERM5qIiJjRRETEjCYiYkYT",
		"EREzmoiIGU1ERMxoIiJiRhMRMaOJiIgZTUTEjCYiImY0ERExo4mImNFERMSMJiJiRhMRETOaiIiY0UREzGgiImJGExExo4mIiBlNRETMaCIiZjQRETGjiYiY",
		"0URExIwmIiJmNBERM5qIiNZVwENAm8JaC8j2es4i5nDn8R31MsgWeibD1UEU+c5gRtPab76MMcYCOu9bzXvnvV/8EVR1cGgAqtsrpkXMw57brz7/5jN45M05",
		"Dk1hy5ZKo+FkiO8vZjStNaAnJyfKlbKImS98fT5fqK+rXySm97d23+2//eOf/MJmBdNaqfT3P1rfh3SZ2/C/AjAYaRpQv2Va9A5o1Pkv/cxoomUWKEbHRp/v",
		"PtnS2qKqR48emv3VGzdui8jQ4NDHdy41NjY5N3/u3O2/LYJCgbe1j7UW2jf+l94fudPws0bjrXQzo0BVIDwjmNG02lvyOI4bGhtKpTqXZV17D8z+as+DPhME",
		"3rn4WrxIG7m7/dDd/tv37t7l8Xwcl4MbfTT2t3aLCCYEyRYrOHEcAzOa1hjTYox3zntXiStP3LB7ByequngR4/7gXWPMpZvnl3tbq1As+Jgisni7S6Gqul71",
		"6CQuv/L8J7GTBnYZsN3KjKYd5eDhg0e7D0+WJ82TJelTp04Vi8VrN67i/aUf5MUjp3pHHwLobNxX+6Dmyf+cSmZjTJZlc2K6s3Ff72hPksQLRPDjDslcLrcu",
		"f3hn4757A7d4AhAzmnbR3f39wbuqquoBGGNn3/V777IsC4Kou/3gw+H7e5u6Zn/1/uBd732pVGotto/Ew0255tmPP+knsixT9ao6Pj5uzDrcQj8Yup9lGV87",
		"YkbTLlJrBYuxAlH1M41l7113+2EAD3oeXL95s/1AE57qwBweGXrzzKetDQ6g++nHxfRDfftH38jnCzzUxIymXeHOrTtDfQOZy06fPj378+fPX7DWTkyMr+D8",
		"C4K+R31/5k//B6MDIwDu37t35d7lhvqGJI0Pth+pfU+WucAGT9ejvffFQunhg4ezP9nQ1KCK8dGxzrbWSpaOjowBCIKQrxoxo2m3NHvVO7HWqOaiCHPnthgR",
		"WWkf3YM79+rrGgBI0dSC23s3u71ciauT5Ymekd66urqZpreq5vOFj25dyFwmtfG+xoyMDOfzBTHmlz73xdGRwbcv/jDL0oMHDvOFI2Y07YqAjqJobHQ8inLq",
		"/Q9/9KO51QUjIyOjURgtmdK1tm0QBGEYArWMRRAEYRD09fWaQBCHXXv3AhgZHnvpxReixjBpSG/0XDNi8vm8qnrvVX1zc2uthW1tMDjY/8s//acGBwc/unOx",
		"9luOHX3u+YPPv3X2h+vVbUjEjKatyznX2NB47cGV89c/FGPmjp0TqPf5fKGxscm5JfrWHj3qUSAIghcPnxoZGq6vqwfQP/DoYe+DX/zJXwHgVQQaBMGnP/2p",
		"+vqSEevr3IOh+10t+y/ePF/IFwqFgve+9otUVVUnyhNRLgJQLpdnxpPlc3nnMtVou05rJGY00fJ570vFUn1dfWfjvqe/2jv60Hu/+HodClXv//1f/43b124A",
		"AkEujKAK4PNvfu7zn/mJfW0d77zzbmCMqgKai8JKuawKY+SV515R6I81fXZkZPRmz/VcLl8bEKLQvU1dPb0Pa79aRGrXD1XvvYfIE32IRMxo2tkx7b1f9dQ4",
		"r16A546cGH40awEd9VCcOPZ87fE/9/nPzwyQVtV333lHRO7du3f1+tXPf+7z+UJxZGQ0TeMje4/Vvq25pbmQL3R0fAmKzs6OL3Z+yQGdnR2d6Miy7POv/3jm",
		"fH//ozv9NwMbrteUFiJmNGHnTVOMgki9JknyiU98ojbTRNWL+tp4O0BqfY8A1LvaaDwRALq3s3PPnj1BEFYq5T95/3t79uy5cPNSsbH+0dCjn339J2Tq8Rf6",
		"vQBwsP1I31hvR0Pnxs+9JmJG0zOJVGvtej1aZ+O+ewN3eh/1GhFjZGZeic/c1JxAP5PUM5PAVczUbGVjrRiTVscG+kd+5Sd/BoAYqTzsj019oOKBl158QczT",
		"z1YvXfxIVS/euJik5cAGPb0PWppbrbVdLQceDN1fzjPvatnPWCdmNG25gE7TdHBoQLAOC0YaY+7dv9vVdeALn/rp7oP7oeqn+hV1ZuEOMUZmrakj08/jzU99",
		"qvbhW2+9ZW39ge6Gme8pPdcGwGXp8y+cMMbOV8YQhRpjfuz1H5v+O+TK3Y+rlcqd/pvOZUv2Jarq3f5b3e2HlxnoRMxo2qCAPtRxBB3r84D1jQ3jo2ONTY31",
		"9Q3PnTjpvZtJzOmlqNWInbda8daPfgRgfHy8WCpZazGdxKo6PlFuqC+pYsGVlQQvvngyyuXq6hpqKQ+go77z5sS1I3tXsKnK3f5bQRDxxCBmNG2VPUcq1QqA",
		"A93d6/WYTY1NtRJGkqZROHfun/rMuVRmwlbEmMB7b4yZmJh4+90PAiuf/9xnAXzyzTdF5K233hJgdGSooaFuqjm+WFsYXtV5X1uW7+7QvZ6BnhVldObSnZfR",
		"Ro2IWe66dwJVOJfNf1fF9fOY0YQNnq4SRlWpVMqTut4t9Pfffff1N96Qp/ZwCcNQ1adpMr2KcGpsYIwp5HOffO3F4dFypVIpFItvv/XWa6+/rt7XLiG1D8TY",
		"mbkwcx5XjHHVyvjIMIzJKmUAnzhx5hMnzijQNzC4kdtZ1cZxb50tBMvBRHmyIsbUjtsST01hrDQ1Ngqe2ilN4MuAY0wzo2njMtrn8/ne3odXrnwkZt3WXU+S",
		"5NChI6ePn5mcGJ+derUZjM7r5OR4qViEZsZaVQ+od5m1plSqE5sPggCA935yYtxlmc6UrQVhGE5PaZE52aqqJgxzhaICNowgePCwZ8PvS+C92sDm8jn1mx/T",
		"Q9VBl7o3hj776qnX48lKrf82yJmFeh4UEGvLk5V/81v/Os0qZnbfrMBXUfgUbJNoyphmRtMGNqXDMOro2LceXYYwxo5PjJ06dvxAd3eaJEFg59QiVPHWj94y",
		"RqJcDqq10R2f+MQn33n3XYWJMxkaGgLQ2dkpgosXL5155fTsHwd03uepwIULF42xQRiqqgSBiPSM9t7vufXG85/a8KSW2rVk89/5QeAmfOXjNN+R92UnYgGE",
		"OVkwo1Xf//Cs97497gAAN7fQMZTehwVSvm+Y0bSxMZ1l6dr2p5se3qxa2+GwVpqYc1utqmfPng3CoFyeiOOqMaZUqgPw3nvvTTXA4+rFSx8BaG9vr5VEVlwz",
		"UJ1p4e1t7JycGN60Ram2QLmj1pbff6QrdtXYV41YAN4tnNFQr86r9o31x+m4nT0VyGB/YzfWZfQPMaPX/VQ3xvIoLNLx6JxL07Q29q5arWC+W2FVzeWiOK7+",
		"8dvfTNP09Rc+CaBUVz+zl0qSJKOjoy+9ePLipY/6+/v3H9ifpX4F0Swmy7Kenh4Ag+V+730cJ9YGK7/g6DqOFt8aFenaDCFTu47KwqNjoFNf6mhov9s/zkRm",
		"Rm8PxgTDo4/QxiMx/3299y4Iw+72Q7XP9E/0zawsOk+DG2hqbD7YfniwOrivc3+aJJlzZz9+d3/roY6Ozqbm5pHh4ZdePNnY1LpQPffcuQvq/VR9GvrSSy8C",
		"uHjhkpip4Lnx8Kq1gUKjcBXL4GlX8/4Pr7zTPb2wNREzekuz1o6ODb90+Exbe5sR8+jRIx6TOZNWxsZHXzj40oHu7lpp4wC6Vf3TOxOKSJwkuVz+x177PFS7",
		"tOvB/Qe+oyFL0/2th5qam9IsHRmeKk2MjgzWlbqe7pGrrZlkonCqtg1cvvwxABOFRqfa41EU2tWu12Ft+PG9y5//5E/lwhwg/f18uYkZveVrtdZYAFmaseKx",
		"yD5Ys9fRqN0wK/Ts2XNPZ/pUfQQGgJ0et1vIF2sjtWsaGltq3YNnz56Tx01wiEjmfdbbP6yuvrExMIGKiHfB2FhcXzc2Onp/8C7E1MrBqxhIV3u5x0bGmpub",
		"RQxfXGJGY+sv/1ZXV3/p9vkXD53i0Zg31HJRDsD4+CiAg4cPOpc9vN9byBfk6TqHwGVZU2Pjw/s9gD4cvg/g6v3LJ/a/4L2faUTXUt4YO7X+aG0vRBFVGGPi",
		"quu/dMns2z97ty778RX3/HMAsqwahsXaWqarermz+rqGc1ffO33idb64xIzeNjFdW5ye5j04hULxZu/1saujIoJ34FxWLNZ1dx8qojjnmyuojE+M3f3j21EY",
		"KbS5qeXB0L04jp9eym50dHB09ImJJ+PZqDGmZOoBlIqFLLCzB4aFQeCmOzDX1s8l3rvm5ha+ssSM3mZJxIOwyMHJRbm9nftqNQ8RcS7reXj/qQmBAqgNgu4D",
		"B71XAFmWdrUcGJ8YwwKx+vHdi4ENj3U9B+D+w3uBtce7XgCQdOzTwhOzzON9+59coglr3ImGLysxo2lHVTxqY+9mHN13orbl1cxnav/5YOhekiQzn7w/eLe+",
		"ruHq/Y/b2tuffthCvnhwz9T4imK+ODMkbk5AA9BibvbQkdkD6VY+1puIGU3Y9kPuausyz07h2WorfD4Yujd7fMW8qzPX1gyx881E9+rvDdw50HZwamMXXWkj",
		"WVc6Pvpwx4mHww/4+hIzmra3OK7eeHgNQO1/FxKGYRCEqn7xGkQYhn19ffPOjpkZXDH74+W37gMb3nl00/llrR8d2LC7/TA32SJmNGG7F6CP7D0+4cYWSd46",
		"Ww+gZ+T+ZHnM2mDxEoIYuXznXHNTZ2fjE+tYx0nZ23Dm41VM/1PVIAgDLHO5Ub0/eJdD7ogZTdtbmiZd+/ebxdfJU4VIU3PTyPDIqn/Rc/tfmvdjLD7zeZ7h",
		"22waEzOasIuq0d57gSgWrBCrQgxm74m1MQ7uOTr7P+8O3p69OIVwSU1iRtOOFwZBz8OH2+Kpdrcemv2f3FKWtibW12i9l7LfnpRFD2JGExERM5qICKxHE+0c",
		"B1oPznx8b/AOuxCJGU27yJX7F3NRXlUPdxy/2X+vpeWk6EKbSCvEDA6eF03X4T5PAUEY5GeKzgdau/lyEDOa6Am5qBiFudo8vSjMWdGpdaQXEIUF0WC9anGz",
		"1iNlxyCWGEGuS3cGe1Uul86MJuyslZW8qq9ldO1/+7K2hdvRYU6vQP2z2L7v3uAdLFDieHqMx66qeKjCu9q4dZ1/aVanYRgBqJQruaY8lwBkRhN26h5ai6/R",
		"YYwYY9Q9q11Wseyh0/cH7+2qprd3sBbqZcHhBSIA4jQVYb2e4zpoJy6JB2BiciJzi7WRJ8vJ5OTEksst0bMa3S5T/xRqA7HB1KxRgXjnurq6zhx/ZXBwwAZs",
		"4TGjaQfpajmQZVlVyseOnqgrRn7+vb3Vqxztbj965IS1oeoG7Z/ASYbLXuVEjbUAnHO8fjKjaSfRnpGHk+WJQx1HDrV1HtpTyJzOt2werJE/+/m9/94vf3nP",
		"nr3VamWJ5ZnWI53vD97lJMPlOHX61FTdevqWiMB6NO2sW2mTuUyMeK9YYJ1PVUyUkyjTLMuedUAvb4K4csWlnTHdnxlNtMSGrXV19e9fekttqaXpeGhb5u0t",
		"VPV/5/du5Ma+beByucLmbhc5M5iaxRACax20GyqbB/ccMyKLtMZEYESNMcbI1hlTwVIIMaNpF43uWPx2WZb8jmcybvru3cHbfHUIrHUQLa7D9o1gE8oayyto",
		"yGovS7Lx156NvdcQ2anb2ihWvqnxRmX07Ue3ohxzfNE37LrcikzP6ljoVKhN0Nu+x8mr9+pV9W7/DdgigA47sFjxWr3ohlai7w7cXmR0h1dfGzTsvVvVFmKx",
		"V++dg1GRkmyBl1IgInL35t3BnoHMTW28K5Azr5xe6EfOnztvrJke12EeX3IEAHyYZjmvugO7V9WpzXkAn/zUixduXttKGS04tOcwc3gjGnEth6Yuin03DnUc",
		"BXC777qKQhQQqFoJt0V/ul8gWPNRrqtlatZ17/iwLnFlM/kw39FwYIOffN9Yz0Jfykf5jobOVT/ykb3PzXw8UO3BgvOtN5DRNIshMNYYNSLinIfo2Q/PLfzM",
		"1BjjnLt481xdfV25Mjl1RhoBUBhozvmcT/2OzOh8HPXgxqb8aXLm9Tfn/cKrp573qeZ+vpprDHyqHHq0QCaJzyWlns78jcJC32LTQUBc2LLIwwy9eVcAyYLc",
		"RL0a762ru9DCo0sb2lA4sN/7xed2qjH23r17C305NKXUT+68IxNIMdPy9eYr4dnGizeu+Uy3UK3DNsE2QxJOyl2AgxQhYzCa91Jd9cPYFlFxubF84b36x/l/",
		"yqXFslhj+sPgasSDTc/UvXv31/gIOzKgAWRa3op9hh9evJKMZZ/7tSOaQJnRC7ajoQmQYS0BDcBnXpyN8+PlXxgWL7XCtALwQFFlLGrGfh5sInBcx9Ml6cf/",
		"aJHjszbNX3+8Qubwz9wxaQhRAOKhiRrHRjQRM5o2z/iP98KLACpqvIGZ6nlTAURrTeqpBE8GebjWdDmMWnkQiBlNK5Plq+LM9LgzTizaUXJtLTC11T1pW4r7",
		"hxqPdGD4CjMau3gxC8No3qkenbqQFcuSBRBOKcc2HXs30XxXv6Gb8gIyo9dhLoAR86wWhtDpf7R971WTCNYxo7d1RgdxCJTf/tGlYkfEjN5mAZ1oUk4mG7N6",
		"BMk6PFzuyUT2QB4S8jZ5W8+R1qnpSMzobf0Ksh69HQM6Q9YQNLc2dU8EE2t/OE3h+gE7K6YVyEGGubknEfsMacWzj4KBrO/Xmv+za2dvNne33Lt7dy3jrCWE",
		"H0TLOY6D3tI6OvZEuTyg9+7e49EgZvSW5tTV26Yfjn3z0PMv9b2zHkPiLADcH70LP3cRjO7pBT1oc/X1PQLQ0NDIQ0HMaGz5OYY+L4Xb1av3bw62DHSZEOvT",
		"YegxJ6PZZ7jVjI2N8iAQM3p7xHTBlErFZhNmPBpEBO7DsgVj2nn26RHRNmlHm921tIcAhvvYE9G2yegKYkB3zSJM4iU2WZLXpjUufUdE9MwzWoGDOABAd0c/",
		"l4j4LMvXN40yoIloi2d0LZdPDD2/q47gndt9Zz5z8Du4xJOJiLZBrSNo0d3TjgZwuLm9nMY8k4hou/QZml2V0QoY9hkSETj2joiIGU1ERMxoIiJiRhMRMaOJ",
		"iIgZTUTEjCYiImY0ERExo4mImNFERMSMJsL2W2eciBmN7bvoB7cs3LG8OqeZV27WQ+B+htv2UilGVdna2pnvMROJ8WJtpqnwJSZm9Payf/9+qJxqP/nVvn/d",
		"KO08IDvP4SsvhkHw8umX/ln1fwslWoed48G6ETOaNsr9+/cBXOq/1xA2OeXm4jvQrecuuUL14+S9QMK1BnQA2F1fGEuFGU3Y8JKlt2J5HHakzCepj40LjFlb",
		"94+FTopULMwuDmkvaHIwu+iWghm9Re7eWKbEzu1ssFYCEbumXPFAUXEhauzds8uP5+hnH6CgcMxoIsI6btezHo8RKYBhPwi/S9syzbaV9Wgi2tpR77FrMxqW",
		"46OJiIgZTUREzGgiImY0ERExo4mImNFERMSMJiIiZjQRETOaiIjAeYZEG62xqSGfL+DJNb6NMT09PTw4xHY00Sarr2swYqy11praP2PEWtPQ2MKDQ2xHE20y",
		"7z1UT506NfOZs+fOq3LJfWI7mghbZkEfkZl/p069zL3NiBlNRMSMJqIVOn/+Ag8CgfVooq1BVeH91LLNIsItYIkZTbRVWBuI+I8ufTS91L5aa4wxY6NDPDjE",
		"jCbaZGPjo3hii8IAAu88jwwxo4k23+jIGA8CgX2GRETEjCYiYkYTEREzmogI7DMkItrNPvmpF23e1IbFf3Dh4y2R0TJlBSsTyO5bxGB6RsOaHmHqONceTRY8",
		"pGv/XbTxp8fUq7uWl06mFwyZ7wzZRUumzPz5sqG/9/H7c1Pa0fP+bhGIERMam5OZo7M4BQAJEQig6zoFayuvL6aKMDJLJfgSh8+GxoRGAwAw5qlv9rPWLLYs",
		"T20zJjImMmLWFqweyEEDU1u3ejdntAkFEeA28D3uYHMigUDQ1bnnQc+jDWstqar86V/71QXjVOCd/t5Xv77Mh/vSF39m+mx6Bg1V2dJnjve1i5Q8ddmS6RnD",
		"8uQ3PPmxmf5DdeqTX/2DqcP+xV/4GQCqfnab+vf/4OvMvpX6Uu1IrtN7Z6Vt4N//6lpfsi998Wdk1u/dbedA7eUDoLW3wFc3+s//xS/9jDGy0fP/BUEQhItE",
		"eKElOPbjXd7rcq4ZdXsKALpbD6z787z/sHfOFhhb8wq/5re8OpfW7me//OVfnv1KWBvWPu99BuDwsW5m7kqV6ktYp3PImHC+S/I8r6tAXJSq6NHPdUF0LWfI",
		"5crFN/Z9AunUr91t50Dt5YMCBYXg6Of2bVgeqIeJTKEpn004sRsd0/LX/9r/c8FkvN/f9h9rvjV08bIyulbf+EX8PNav1qGKKDK/+0/e3iUnYv/kgzDIz148",
		"XkTSLG4v7av9Z5qrMm3XIozzG335/lOTWXFSsnBNGe2BOvXvRsG5+rRY3cg7/S3VEgqref9rwyjoRh4Bn2m+Lbzzh0P+28UDB/ds8B8d3O/pW6hK7r0ffVip",
		"lgOfKJad0Q/xaN0zevechO2lrnk+m8OTk5KFK66tWlthozN65MF4VqhIFqw1o0uqj6JW1I8Ojz2DguL2yOi2fH7kwQTyurH1aK1OhhMD5bzmH/Q+2uD9d4IF",
		"C70CEbGhsaERXUFGhwiY0at2p/96YHNz2tFZlhzccxRTC7BZ5uz2YkOjoRExa83oUGt9htba3dxnaEODUDdyaocatZExwVRv/gZ3jgULjfITI8lY9rkvH9n0",
		"18U5bT+0N0u8mC16YhojA3fXtD90sl+stclE9SCOPRi6N88gm3m6IoloQ739o0vFjshnyjksT6STc3r8ZN2WHRasiihnv7NwRtvkESAual/kQSbOXDORuB5T",
		"+NFhlSduQlRVxKxrByURgfMM17AB81PKk34T28iL139VkS1+XZVgyVQ15ZxJrcasMhPRVs1oVRgrdaWibpVhdioi1UrsnWLhZrzqfLNOVjqW1iiMZ/uYiLZu",
		"Rltr4ji5+tHtIAh0C4xbEEiaZYePduVyofds4RLRLs5oVbVWqpVk9EEGZFfuXtn0p/Rc93Mffnyuc29bsZR3ccqFMoho19c6jADoHXtQ31Da9OfTO/awsbFu",
		"E2Z/EhFt5XEd3vktUVtQOG4qSkTgGv9ERMSMJiJiRhMRETOaiIgZTUREzGgiImJGExExo4mIiBlNRMSMJiIiZjQRETGjiYiY0URExIwmImJGExERM5qIiJjR",
		"RETM6F2CWx0SEXbLXlnbi/cucxmPAxExo7fYPYjYSjzeeyWJgvz+/V337z/gMdnxWltb84W8qj588JBHg5jRW7sFrT4K80fPNBfy+W//7gc8ILvB4OAgDwIx",
		"o7cLFbFxWnEo81gQETN6K8a0ERMYywNBROC4ji2a01AeBCJiRhMRMaOJiIgZTUREzGgiImY0ERExo4mImNFERMSMJiIiZjQRETOaiIiY0UREzGgiImJGExER",
		"M5qIiBlNRETgGv/YpKWiZd5PExExozc/ogF9MpBVocqMJiJm9OYRMamLWxv2ldye1CUyqy199uw5Y0xra9vg4ABWv8U4i047lhULCSCBQ8qjQczoZ9+WVgXk",
		"iba1QmRNjzmZjdcHjRkcD+/OM5j0xzJuXdSca+XRIGb0Rm9deOr0qYsXLq76ATv3dkLlWHv3nwx9rU5aeIR3nr964m+0NTVPJuN/5+p/H0jIA0LM6O0krjoA",
		"w+X7OZNX9TwgO8/7Qz/IJSbLMmFFi5jR287wcD+AvvKNUr4uBTN6B3p38E/iyQmbRfVRA48GMaO3pbwpejaid6iGsNlFeTGBQ8ajQeAcFmzLMjcDesfy6pw6",
		"p+wQJmY0ERFY69jdA+8UKjrnM0REzOjNzmcRE9hQ4WXW/ce5Dz+wxsgaB0gTETGj1xLQBjbNqhPxSObS2YnsXOrVJCmnkBERM3rzShyBDScqI1n2CE+2mDue",
		"z4Wh+eBbj3iUiIgZvZnLKQkAgeCpsgbrHEQEjuvAJq6pJN5n+ahUr/sOdr5UdB0z/x5cnjy670xDI6dxExHb0ZuX0plmhVxDXdSZjsetjXtnvpALen70xx/m",
		"IstjRERsR29eSEO8ZmkWpy5Js8f/Xnr5Re+995yEQkRsR29+zUMEMmeknQAce0dEbEcTETGjiYiIGU1ERMxoIiJmNBERgeM6sLXWvTt37rwxvNQRETN6s+PZ",
		"iAmCSKGzp4MbMUa47h0RMaM3M599aKOx8kAcVrz62Xl8+HRbGJnv/O5ZHiUiYkZjE+evOOcm0iE82WRWRehZ6yAiZvQWmGUYBBF0ThMbAevRRMSMxtboM3x6",
		"zVIFd8siInDsHRERM5qIiJjRREQE1qOJNrMdNDWC3kB0LeuXQ1TFANi9c6Zk6nh6OGY0Ea2PyXQyC8uSBmvKaA9kqnGuAe2T5Un4XZrRjfXN5XQil8sJLHZH",
		"Xz0zmujZOtx03OWq4uya9ib2QFG1I6j0ZUcOHtu1I4mqQ9WDTccHXE+mqYhhRhPRcu3p2JPLRap+7s7xFwTAJ994Y02PbvH2D9+FAAemPvHJN1/fVYf37bfe",
		"A6AllQtWXsHt6tViWOfVM6Np6X0Od8n1nBanforMd5aUs4k1Pr7TbHaJo1yZ3FWH17kMgEIDA1XFrlkhhxm91pmHqUs1jXkoqLap5auvnhLzTOLj1ddO7+aj",
		"++rrpwF49cWg7vez++DYO1pOC9q5rKHY0tF8pLGphQeEiNiO3uRYNrPusERsklU/eu9uFORKpfzoCI8PETGjN7HVrFk1qc6qPquIaTsmYicvf2+Uh4iImNGb",
		"Vml0Pivk6wtZu/fucX+Fx8NrN0WCxqaW0ZGhNVwAWHQionkzWkTmG7cpwuEKTxyPTLNCVF8XdqZZPHvXlTtBj7EGuqZuw4qbrAvrs900e2p3TY4Tro5Iq83o",
		"dGJkgcor4vFU/UERUSh3ghKI1yzN4tQls69qL7384sWLl7xf5TjNffv2QfF8x5FvDvxevbDjcQcGdJZCPWAQhDwetPKMVpfN/xUVdWzWzXd3AZmze6FMDbta",
		"jYcPHwLoHa8UbFHV8xDvMAoYCxiAzRxada1joTgC91HdKL2VB4VcIePd8E40swISX11in+F2lTM5lit3cFOaiHNYtvvbmG9kImJGExExo3ewDz784Pz58zwO",
		"RATWo7dGh49YK96Lh5jVrZWjumSfvloPC+UVk4iY0cuOVg0j89FbD4GH05+7u7+rK1vhADkXtS35Pc1/dKj2wZ1HN4Igml2eFnl6EKRyJBcRax20KUGoW/R5",
		"EREzmoiImNHgiFsiAuvR2ObzvpPEv/DJvc0tDWniUhe3Nuy7/N69lc6+tOkgIC5cbC2OkZ++a0JxfXLw/WP3h+/ODmFVFWNZ6yBiO5rmH5QBQAUqz7r5yuQl",
		"IrajVxfTOlVgePWVV9MseSbVCxYwiIgZvfYBeQoVnfMZIiJm9GbnsxFTG7w8e/3o8x9+aIwRrhFIRMzoTQ1oG6eVrNrvfDY7o1MXG5U4SXmMiIgZvWkljsCE",
		"k5WRJOuds7VYx4koiOTsHw/wKBERM3ozlw81JijmGub07nlFFHF4DBExo7dAUHudu3+Y95p5bipGROD46C127MRWk/K9S6MPLsT79+/nASEiZvQW4tXlosLh",
		"U21HXmm+f/8+DwgRgbUObK2F8SRzCVIO6iAiZvQWXdbDmLnraRARgbUOcCE6ImJGExERM5qIiJjRRETMaCIiYkYTETGjiYgIHB+Nrb4Ann96lxYu8k9EzOgt",
		"wdoQqrP3HlRVa3g7QkTMaGzmZMLUxW2NXSXXkbp49hLSH549a4xpa2sbGOAS0kTEjMZmrvTv1Xnvn9gZi8UOIgL7DLeqU6dP8SAQETOaiIgZTUREzGgiImJG",
		"ExExo7Hbt2PRtQ3tCAwH2BARMxrrMPxOoVPj7aZH3Xnvoyhay8M+KvcoNwogImb0WvLZiAmCKLChnfXvwvmLRlZ/GJua25pbWv7Mc39ZYPxTE82JCJzDQssL",
		"aBunlaza73w2e55h6mJjTByvNl7VBWHYXtjLPbeIiBm9+hJHYMLJykiS9c4OaAAdJ6IgkrN//HB1jzwyMgzgb3341/c07DXCvWuJiBm9ym1l1ZigmGuY09pV",
		"RRhZ4OFaHnxv6YCH40EmImb0moLaq3t6bVK/5hJF5lNj2TdARGCfIRERM5qIiJjRRETYhfXoN15/zaUe8JuxoD72t3Y/GLr3xDLNmL8fr6v5AICHw/cAWaff",
		"ryIGgDHGWmvEyNQ/mTuXhYhok/sMA4/Aw/nlBKBAFdBUUft/i32f17mjI9R6cS67eONiqZS//vAqFMe6TgC4eu/a049x4sBxADceXr+b3QDQ3X609vl5v3lF",
		"AX3iwImP73zk1RljJybKlXiymIZxmtQyWgBVGBNYE6hq7T+9Z14T0cZntNH2Hx5Z6SPmvxTURjvM/5Biqunk7bOTgYlePvXS7LHG58+fB8xPfeanAAUkzZK+",
		"8s36usaXWw/PN2A5CwJzMLc/iPMAfCEu1Qcu03m/eUVteO/jT3Z+YrR3ovaJ7r0nSnVFl7laO12hVoJqNlbNRq0JarPBoxxLRkS0Tcbeff/3ryz5PS0tLVHB",
		"GIjM2q31zJkzAERE1Z8/f8F7G5SbKuUFn2QCBMhPRX8lV6ms119g8x2lhu4W9V6A6+ceKPS1V16tXXS81wsXz4+NjY+OjvDsIaKdOT66Vsz1quap9rZ671U3",
		"t4CQZZm1xnsPTBU4kiypfcmr994LNwInol06h2XJjsINeQoicvr06aefi6iIQDgehoi2b0ZPhGWY+VvBgQ36hweapWmq93DRLsgHycPmxhbnHR5/t8w0xFU1",
		"CMMwlwOQVmOXpWLWGu/WBIOjg21oXaTLE4pDJw9d+Pa51vo9hTjkOURE2yyjs85HGmVQmW/5uCCr7z31mS9ff+sORBeJ6c//3Oc++MY3fMl7n9Ui2mnm1QlE",
		"xQZGFXCqVVUA0iRYj/a3lyBrfPRjX/iP3/32uwtdOQDx9ZPp4XuZWjzsBEe07ybj2Uh90MTjQNs7o3Nps3cJ1D692GZgg6iSGhct3oZ+7ZVXoYI4RBjCiwBO",
		"fTFoDm2kULhKtWqNkZkFlwUiImsfs2xtkKtkokusP2ezXDTZms81btg+LzOag1aetZuIAU07IaMLvYuFVxcaz3//Qj6fkyUHXYtCFOJFgkoy+ub+n272rVdv",
		"flyH0btD2TM6InvR+P1vfC8Mg4UmuCj8rffudo0cB9DW2myDMAhCiDy4f/+ZtJQF3U2HRg71BvXiM3jhWOy1XYZXPddJocZLGtVf5WWSuO7dPE1JSbI40dir",
		"9xuxFr4s/m6tfTAwOLyev9ADwP7G7nl+477U74HG2Pwe1W3Or2F1Wh+6aNLiKo8iMaMXGm6hGxZReu7c+QX6Fc0zuSJkQE57wnsm92SJSKAxcl4wCWQ8Y7GJ",
		"K4jbLBgbGy9hDw8G7fjx0VDVc+fOnzp1ygh8bRfX6Saiqjrvvd+0Ne9rK3WI+Pla02qMXf/xgQLNYOql7ovAnF+rgIGfhDp2GG7qW0WCobj/z7/8f798/4pC",
		"e3p6eExox2a0MVILwUuXLqqqiPnEa5+caT0qNLRR/6O+zdqDta+vr6GxZWx0aN6vNjS2LvSltTalHfzIgmVUsMqxqZy6Qlh8p+cH4z1JY1MLDwjt5IweGBho",
		"bGpSr2IkF0aHXznw4eAPI5tX+ForW6wZrQyVcnWbFdOLpPDY6CCeXQ2cOxpu4T0twzC6OXy1HYdGR4Z4QGiH16NHR0am1+5o/fDGuxcGflQKGnSmR0cR2KCU",
		"rxdATMB1QBeekinbrKYL0U267q5LTBfDEk882l19hiJSV2hoKbU3lprTJFWdKseqKqAT1XEFGotNTOmnxVl1mx0WgShCE62qoC/Lvgw8k8E8tW/wbC/QLhzX",
		"4b1TuOFHw1ExtIH1qgIYa4YmBr/4+peNyNfe/XdhtOWqAI2NjdaIqoqRoaGRjd+nfE9xn2yvdrSqF4ynI86ltY0UlnuGPLXg+EKsrPI8WfpXKFT9kvObiHZg",
		"RqvTYn3u7/03X/2Fv/LpQy/uq0zEarWYFmVcDnTuDxFW0zjKrf89ZlcTmnNJ6lfcqFMgEB335bsD6eZc1dRbE3SdO7bdRq+pETv2Wt/HIxfqwvpldjaoamDC",
		"5Uz2V1HnM+hKr1wCeGusEbPY4M7aHBYTMTVol9U6AIQKlXy+ENrQGhsY663PpbkSSrGrqvooiKyxxpj1nWTnvUm9ZN6sIqNhoEkZWJ81ldT6ld2kq1djPDyw",
		"nW69FRCIMxmsV+tVlx5eacSOp6N/7cTf/NbvfOPM6dOLlCM+PPuBEdv32o37ldsFW1x+b3Mg4UAy8B8d/s8+/sNrp06/vMiihh+c/cBaM9ZUHRsZZHbQbslo",
		"r94NSjWrjkwMjkwM1o0H1YnEh06rrn+0L81iUe0ffVT1xfHJiYZoXVdLEBXgp0+kK81+r/j29RDrN5ml+WuHVvFTD7E9h+jex168sPxvb8D+P7r0NWuN89ki",
		"DWSvKkbT38t14LmVPqM67Pvg/PlCPpf5zCzcXp9eEIYladpNGV0oFHKZ+fUzf/GX/t1fOPLC8SBnvVeIWh9kWTrU2wfI/+cv/UMRP3C3f2J0slb/Xccn8K1r",
		"gcx62/30iQXLF9+4Gk5taQgY4Vt10+67nmmn5iK/4tSplz/66CO+BrS7MtpYKzCNdfmmxjAe6IunmioCKETy4iBI+vpgCvWlhmq5gvWfm2Bqv8+IX0YL2iig",
		"QCSeZw89nfEffnh+JuVffe0UD8nyrosr+ObaP2Y0NnTQqWqWpUjjeYfmAXCq73541hhTjbPaPPL1G/mnNwenShYn2pxfuBbp1Vjx/WnzyOg4gBPtEC5BR3NX",
		"OJgquhNWtsrVcg+ZiiTIHLLdE9PBFrmMigjELlg+ECOqUG+MCYMgCEPArdP7So61ZVObu0Bk4fqFEe80bA+H21u9qjcq3q/bvMCRn7krfhPOOSMm9Wk1qzxd",
		"uREVn0tbv/davpoAGDowWnnptp0sqPELv9l8zuQik9P1KwMZsePpyH/w/H/4za98Y4l3pUBUoi9m98o3i7bOBXE41FR6p3nDDuZAf//Mx11dXc656V0wt+T6",
		"UCGM2eRynfe+GNZ/3377nb7vNeWanbrlZboamJzNe/XM6I0akIUlm8aqUJGgr/fhtes3jRHn/InjR9fpCQiW2yIWqEdQgAkVsAKgun5VVtngVp8RW8nKdWH9",
		"4cbnAJ07nkHhg2ysOhUzv3TyTx17vvtr//L3F3q8n/2Vn//6V/4o92Pyg0ffbAxb/DpdRKErPDK171eBQJxIVtSgzLbqus/2WcfuBQHMSioYVkWEtY6NnWho",
		"RAJrFj9njAigra2tAEpBdTLLr9fv/6llj+v46ec9yo9uNvwyGo+ce/cHiGT/fp2ZLZmmWW9v7+rfLhv9jhFV9erf6Pzc2HcWrPIXOpO+3t7WtrY7H31849yl",
		"1195faHvfHS798de++xH5pxTJ5B1+3OmW/ivnDnjdLG1WU+derkYlP5Ab0MBqKRBVl+e+NT9hbbWnNkezRR9/L3W1vU7/g2NzaAVlZhlJVVmYZ/hs9TU1DS7",
		"ySwicbUK+IGRJRqkceoBb4xpa2szyMJMapXs0dHRjT2hDHyCtAyfAZLN+kO83053XoEJ+yYf/IWX/pObf3g7y9In4nDWH5VlWe2e1Huv0EVS0qnPNPW62kKh",
		"Qj3ErNM7UAAVDVzaOobF1xz3Yuoy5Q5YxIwG0NHR4VwmIrX6hghUNcsyEUyWl5iwd+jQ4es3bkht81kEQaC1hZ6bmppGRubOw25uaSkVC849MYNQFdba8fGJ",
		"0dGRNV/4zenTpzAzm1n1/IUL2+uF9+pKQcN7g989/uqrZ3/ngyW7dQGcOn1qkQSdbgetMqAlhC3ATQJu/RpKKpKES24zLJk2J8G6N89OnXqZ+ULbKaMbGlsA",
		"eK8iOH786NQapFJbvG1Z95nPnTg+M4lAVa5fv+79AvO4tTZaRJ/eWIAveWBqeaQNYdPt8tU71/ra9BCkcnR/MXNeRKAKMQmapkqWqrWmtHlGRUCFhHCjKJ9D",
		"/hhMEZo9EZhr6k1dsoplIM4+6hz6uU/90oW33+PpQbs0o5ubm6MoqL3xTpw4VsvK2lt+Jbmps1flPH782LVrN6y1e/a0q2p//8DchszpU7NjxXt/6dJHu76b",
		"SB+Ve6fnk0OQldAQx0kuD9HESO01UjGw5vG54Z1zzuHZTNtRB9uAyfeR/6A5ax3ONUHTJzLaFWOIfnj27KnTLz2LsrzE4eTLN7Lmcajoyhf7INoJGe29eu+N",
		"tUePHln3QanOec75W+ZIdAj+6pm/FtTyV6HW28P57418V4xWPEKMff7V5lpOff/8uDW4ensYQGtrWy4Xqddn0Z8uAdwEiqfQOFAawPDjV7LWfLaof/vkH539",
		"Q2vtUkOPdZWDsURNOSeZff2V1ypusUlS58+ft5br3tFOzOjaW/vll15ecy34CbWayfVrN3TNbR9VLPwg+vj/V1GdPV1hZhbO2vqhVR53bT2zqTG18I36cnbW",
		"sO633367UMjV1g2F05l5X1kyMfNd3jsReYaTMzwkxPgv3g+r8FVARI3TfAYVBNo4EmKPqMJPHf15KxremjAX5I0zqxmdbWp/vFfozArmc27dFGrFGhOYlS5F",
		"oLtnLj3t7n3BF38fNDY2zVwAVFeQJ9+8GgKwRqV2p7vYOS1w9ePBXYRD8NmsTXJhrVlwexFduhdMoxTOTN16ZwEyu9x3ttEVzVhR1b878Denno4Xn48Lpb2l",
		"ix1BEB/dn3MwMxkoJhABkE5v+PIsyhyzPkyg8dSUILXOlvPRnSYfOGNNbQ6TtebShUuvnXl9vofxgYmivdGV8sXJwfFQopXGtEILtpgzBQ98+OGHkOnrtQoU",
		"r73yGqBWgsNfOJiY9N4/fW+Fqx0AW2F1FwEUnksYMKOXbk4/mxUvGxoK9XW5bGosh1lmH5cRFfFGUE5tpgt0QM5Uz8XARbHP4Kp4srUlIpmb//R3UfuST6P5",
		"q0cAaEOdjE2UT09Ujj4wlWjpBrXAxNGK3vwiEtno8fCUIMxHBWsEgDVGFT84NzJ9ZB6v66fPKDKCJx9aAAc4Qc4F48X8R00alAUFRSVOkiwzn/iZN9N8DD+3",
		"YuzVSWi+NfD17/R+rbt4ODThijqHFRqZ3I3yx0c7n8/S7NQvvPjOV96vLST9iS+9ocanSFQ1CuS37/zT8aHyEZxe0dlpAsjWyGhV+Hj7NaVFxEqADejwF/Hq",
		"vTrszoxWxeTEuLVm3QdXHD9+9Pq1G+odgDAwgHovXqfeGB5eax88OT5AbB20PJw2JM7Whcm9kbTsCkVbWer+MATGgfFncoaMTQAonqvLPTwFv/TCp+LMxJlr",
		"Gjp4WekSNgLxqo+qPcVx6dAGAaqJOq+zb/KzZ3SuKhAA48DYrJgWIANagRDwotbX5gcqKgCGh4bSOPiHb/8flSMPTCX39N2DV18K6o/WPZ/4eKVx6NTVh41/",
		"3PvVrz38t6LW5+P67Pm2kToA//vV/7ePMlFTq3Y3F1v2lVpXceZvlf7ibdhrY8RUXXUi7V/Rxj2r3iYobwvL331i57WjtVbWXN5Wqk/dEy96fh07cayzvQhV",
		"VYho6sLM2VoXUh4Fq1ah6mtVZD9dgZjwIo3hmLPGWg9ECwT0JrD98bOe2eXUBTb8jRP/qd1b/ONb3wBwt7e6oX+kA6pPZfRMjeqpVzvMZS11LXGYGT/vHYZ4",
		"uMTHFnPr5gr4pVLbq68LGxvQXCva66dHxu0QFK1xG3S6DaxIkaQ+zYM2LqAr2eShhhOf6vhxl8bmWca0VzVBdGPs8lt9f1IfNrgt05oONnwf62Wsgud13umi",
		"i//Yg96JOXPHM5d1tLRWT4/fdrdykhMvt964MBgMFFH08AIMiNT6wlQQZpAwDr+3r/iHrSaobI9TWPNrWJHV5cPCza/eA3Cgu3vBIRP6eOydMbKeN+wCGMDM",
		"yugF3oCjP3NXxUMF3kgsHunTT0MBA2TwE3MnOiogJVl6uxwvqZuJ/lQkAQRO4pkHk4wjOjZhmnjsk858Z8tAe5JNGLHPdLORyBajthe/8/APG8JG9hkumDpB",
		"GFpjZzrvarVm7/30fOUF47+rszjnrfvuB5ce9fRUPz/2XXyvFa0Zsjo0NGhLVk1qAxvyUDPVPherGAmiV7oqubaJLFBZYvdRWIOJRB6OLn3S2HQIEBcutoZD",
		"emA1S5CJyyCrXGPOis1ceuTnD4qKNWahXi2BibXSbY9++7e/hUV7Yj28V79uhSwVcQWt3dk4IyKLT+k2QArfJPlDQWMMJ09sRI6PswGz2A4u4otx3dlj4YPF",
		"7nDHfvKBcjXaZ7e8k85foxKV1KWZq1ZcxeBZZjQ8gEpW3oCiynbNaBFxzpfyhXy+4L2rtYYUasQkSTI6OmytXSgCBGpF5tzSigLW+L82fOpenbGqMMaNVH6m",
		"59GfOxxqFSJVBAlqjUOxHoNwaejqBE6WXAUTRhDIsuuRS33n+CtXxa3izFAT55ZYj2KByqQV69T944v/61J7/QWP4p6/fOy/fP2VN8pu0izQ1lVowRaiIBfZ",
		"aB1iWkXDTG3FteeXeVgEEmvWFdX/hfD0gJaD6edpIBn0v8u+a5Z6DcRbgIMeNtSHH1wITIBPQ8KnOpBnXWPFyntvvZ9p9sorz3LPBDVGjNliAb0Vx96p9945",
		"Nyuj1WDx5YquXbshwN07ZnbT6fVXX1CFwA1KhO4TM9+c3X/x8D8vOskqLjq999HgNf/ymWqtGZmqNldt53NpYtQsYz9D1XUbkWrKuVVltMD4tYyV3lPcu2RG",
		"i0Frvj03mRfIvGewQkMTfZD7YV/ycHxktD5sWGHPuBeBmOmAFCNpkDaPD39xqHb5MXE09zqk8rhCMt22FUgau4GwPOwrVh5ntFvmjQbbyJv1lo/hJ6C5ebqc",
		"VOBjaD049m6LjbGXWfVnFVnemD0ThDMxL8AH566YwECkqalxZOTx2njhRFK+nNTmrw0/iFpy8Yu9eSMKgVEkVuNAzca/W83qOt3X+kQzny51A+gim//h4Lc7",
		"813e+3lbowo1Nnhv4AcT6XgpqAskXHb9RaFGtJQmABAaqPdAFQpxRsr5+ceAKzSXqngIJLOSBhAVA0108vdHo78cmuHY2scZvdyjxIjeFAY9Xxnaj5MLfb0e",
		"e++h/8CB/ciY0Vt+MfLaMklPdx7W3oX37j6s/Wdra8v0VDEFzOyAfvIxxzMrqcVEztfWj671O7E5NadIV7DF62OXL418uEgFSKGNYXNz1ObVLR3QtXHQdUC9",
		"9UgLpY8f3IdzOHYQlWrOZPtNKfVVmf+ipdDA5R60SRIIJCtV0tZRyYLaJjr2ZOQTr6Izz0Gn9pBY4gJpqtHki7fw4nTj7YkFn2bNTVfO0nsmLt+52NTU7Nzc",
		"2y9r7fDw8MlDL4Ht6I1x7dr1pwd6HD9+bOY/pjaUFBEzteC3CIwxAArFUiGfT9Lk7IfnjMzpKXuirTQ4OLSCJrvCKAzfJYv2dxeDUgn1Sw4UWXwN/vmmB1oT",
		"jlXDHxw6BhFUEphiA0aPVK8k0YGFrgiioSucrxNfgEq6v5TsHZQ0UAWs1L1aF1VN3gZWV1zrMLAGVq3T4HG/hngjmZ16JgIVP3upKXrmfYbK+5uNW69DjDFP",
		"LRaq3vs0zWaPIffeZ1mmXmvB61wmxmRpOjo6Ws1FdXX1tfl+s3dOEWDt63WsbKE23UnT6JcV08+qP00hgjiBAmZ69enwB636fxp+epHSmSKlby2YwQoAjR5P",
		"3xeVymTam58c8VX7uM8QbhmtXyNmPB2LUbHj+WA8r9YDIl58Ls0ayuJMrTmu3ptyrhutDFXaaRk9PDz89CcbG5uKxUL7njZjbG0x6SzLhgYHax1TChUxTU2N",
		"Cg1srlDsMCJnz17wCusm+0eWu0ldY1OTSDgy3L9+u3VGUEAMhHe+axz8msEXMfETM8tjQCIgbtrTMiLDizWgZuZVTsevhxYlvKUj/2P5h2buDPMlxkdbsePZ",
		"6I/t+alDjUcwHI1fn1SjtSVafZDWHc6bzKooFAoXRPlvvfctvni0O+rRYoMwhGqaJCICSOacMaZW3FBVY21DY4M6Pz33TK0VKPKYXP6iA/lc/uk61yoXG8li",
		"FNtulr4IF4/ZcyhiX/Hxeh1p5h719fGUWukgQFQPz3oxPSQe+7n7ks1dEGXuB/MOL4HJSU7n20l6iXF7WeXF+jP53mJVy3WHco+3IfYifY/H5L734XsmME3N",
		"rSPDg3zxaDf0GQpU3333g+7u/dYGtf7AmQU9VBWqPvNTA++ktvyx8d7fH5WmppaRkaFl3qev6+x7gXp4V3vj61Zcl2G7xbQpz+3CS+dbF1AUokiDRfJWgeWO",
		"tHtq3+NyNgmPalY1qZmZj15rTuNxzT2Dt54vNO2SjJbpDsI7d+6eOHFielkOfWpZB1dLaGNsmiQQdDaHvcNDy/8ti88jV0htKSERXWiys0JUDfTxysGnT5+e",
		"nc7ruZ+hf/Jm3ejOH371uHwhU1k8ez5LlNa//5wkoRmdiE8kky/eWs6CU6tYGsLAPHG2THVbyqwtCk999NFHTA3aLRk9MtyvvjmXD9VNjax7aiFThRtVN7U7",
		"bZDLJWmqqpFdQbvYZW7xKTChZEVbBRD7KNHw6ZhWSM4kkXGKuCrNz/jCpb5YmZ0LphrthhPRF+Opjr8klMw+EdOitj8GYvEFiZWjI4kZvXFGR4c78h1L7Qla",
		"G7rh4f2ZM6fff/9Dv5JhqoODA4skohEdSJtujh0A9GChZ1/Un/hQZqWAquRscqvS1ZvsURe/0DZuntk66SpqnK27cFStnyq8ilaOPtj5w3JFS5cOQSBpEO8b",
		"yJrHazNTHh+XxnoZHVdTmbqrmLUex7oc99oRfu/s+y++fJKhQMzo+VcenW9+ir793qXpZfaNMSZOsp283Y8ovES3C2pmFt6TylE87sLauX94dNsAkCzv6otp",
		"+4ikwexitIw+sWC3GZkAIL4gWbzGs0Gt1yBVpDDKobjEjF6oXozr16+LyMzGgMePH4UqJBAxgMJYgYWY1fYJLbJLqbSFI9353se1jifTUERjHx0uPHiudFez",
		"uGr392ltS20zc7E4d/78Ou4mNSugp4oAkgSShLvhHl+Dsgb+ifsG65p/9/is//QSh+Of7a0dezXeVKPVlOy9wIvm0/zdjvzlfB32v996rpDPcVNwYkbPlWXO",
		"exWB85kVY+zUlnpBEI6Ojk2WYwBDQ4+HV7e0tvp1LTakGoxldYv0GQo09lHVG2RW8gHCIsSe++CdqWnGAlUYI89ox+jGPzmTtY9MPnfXVKMtsS3exkz8n38t",
		"1oIkVQhclNUWkxJd5fxsX4ih4otVNd5o0UuZWUDM6PkNDEzViz+6fOXkC8/t2bPHuWx60LERMTJrG+bm5mbvdX0bOwI1SzVRBSpwsBbJ2BF9HxqfUwcJapNv",
		"rJU4Tvr71zpNRrxR64d+9Urh5r7Cuam513bY+XxRVCSzat08Q4Z3Qi4L5lSHPVSmFtea+UpyMKke6DOVHLx5PI1FVlJKml74tPTRIZNEGmZmvFALaPZEEjN6",
		"6R1Y5tuWVrfQ2mRi4TI8/JGHNKT1E2h8MBiv/9zoas7Eobii2nKt9BH0oekPDosvVF4cqRy/Z8o5GFXjd86S8zMrrGpew3GfSwIbihGXZV6mlwrw+aSzN943",
		"GIwV1aSruwSKQlU0yqLbBhpAMqACoH/PyM/+xM9f/N55JgIxoxf04snnaxXi2n9euXI1TbMwDMwWmnKtEEGuCQqx1lTHgWj9J0irZKVqti/zOYGX8L6fqVPn",
		"L+fyl6eWoEoOadYy9sT4h23cjJ5ZxKgaDNcVbcfk0GTm0lJ9Qy6KHg9CfNQkTh4vcrTCTQPyN/eZkclZh7o6fYEoVY5ezBona2tysCRNzOil156/fv1GbRmm",
		"NHNmqy2LoW5q64FnsQSaqCRB2jqW7B2sNf2a7h+e9xuj2xLd6pgJmh0juiNyp7OAyvTUkqLHVLE4vIvwzmr/ZM1DJmd/wjeX1DoAGJiUNJTUvv7K6xXHwjQx",
		"o5caaeFVoRBRERmdbzGmrVOdeUYD0R4vXe8XvT7tuICevk5XZk3lL6/Pnzzzg5qHVCUrlZ+7m3QOShwG1rrxisyZ3jmf8+cvBIFlM5t2dUYPDHK1GszMh9bA",
		"j/zcbXjjS5X6t0+GDx2PzVokB+EaBiUz4mMNnB0vwhsjtnYtXHJDAJkayL/ixbi2Sqzz8sKM3l3U41luVDw1tiUJAdjRuvILd3BSxYsrJM3vvID+mK8AVrYf",
		"WT7Z8zDZPyDVCMZLEooXGA8xCjXGBibII5/5bN6k9uqtseMnh8a+UVnR7/W8sBIzeoN982oUGC9hARuwyZro3EGAHCa2Kl6qkoSmnJMkBHRm5otT1xS1/Pb9",
		"fxaZ/GQ29leP/bdDd/vd/PsLrLxJLPBbaiM+NqWZ0bthWx8RZE7Hfaml1UBVRAYHhzdwY8dd8T470H3AO7doqKgxJo6TR48ereCCZ3TO0noKNbBVV41dPJoO",
		"66I7zqymbsFYJGb0xvYUSmD8UBINj43u1L+xubnNmKdWIpxv2eVFl6xaW7PXObdERk9tt7Yuo4kCCYzYyHA6ODGjt9yN30prB6KYPflxB7IWhULBOb/IuEdV",
		"2MB63zr8bDYlqW3Nc+bM6UUC+sKFi+s46LP2j6FAzOg1L5IHOFOyfnLtnX4CbzQxK3lnehWjkao88w7DTZ3z6Zx/6aUXF9ke4dy58+LEe4Ya7Raf/NSLNj+V",
		"Fh9c+JgZjfk752HygT/eNKYiUBiDNNWRQWfMvA09aW61fnpnPIE6BF4DMe7ugFcTZSLVoGFFs2S8IpUExq5jh6GRLbfbyvQmOQsemlOnXt6Fm5JYsYwq2uR2",
		"9BtvvA7AGKNbb9+2ejsOFfVuatdDAYDQIjRircy+URXAK6yBEVV4gQAiPh1HgzMFUd/WqglkIMO5+OhKW5kD2U2xaGvVqSWfIQNr6zOcTCbqpcmpW+aimjxx",
		"V794U+0AygLXpSUmDWG4OgSEy/lV589fWKRQQ09vaPd0g0BERMxUJUrxTG/aPNR7r15FDfyT6ykq4EVgINLVuedBbz+AV0+9sO5T4eZtmwfznqiqWi6X/dYb",
		"2HlvIJ3eAe9xs7mtrb14qPDGG6/XXs4Zb7/9loi5dvfurKKEBSZbW0LvpyqPAvhkova123ceABBjllXG9vCAwlsbWGvb2tpmFvBbUb9+W1sbFO17Xz038E5d",
		"WO+W2h5XvPhivHU2OdxGlwureY2GfDEWs8CGW2J9EKvoh2fPKvwTW1YCF85fEJgvnfjV71/4oTFm4ZebVnwGpVmcZcn0gpez4ytI0goAEWutv3jho2e6CoWR",
		"4OQvHclyFc0nXrNZqz+oFjWViklLdx/2rN8W1ioQY8x078uy29GqKmKOH59au6ehsXlsdLFGYkPjem3xp2OjIwAaG5pGx0YaG5oWioTR0ZHGhkYBVGR0dCQX",
		"mFoBVcXNrUpY7C3leiafmO4RhJF3zga21prq6NgH4Nz5i/l8QVXTLF1WDMnUGkvGGGPMIld41cUGJ9R+rHBjX26oIxc0+CWb0ioaZloOBMnmvrdqE6N1+1wh",
		"nFSD3mZTjsTZead9G2PT6v+fvf8Okitb7wPB7zvn3Js+b7ryBmi0bwBVcAWg+73HR2/lzWikkTgT1GgVS61WsxGz0kixmp0NaRkxsYrZ2Q1KmtnVUKJWlCga",
		"kZRIiU4iHx9fdwMFoMsAaN8w5V26qkpz7znn2z9OZlb6ynJoAI0bL/oVqtLee+53PvMz/t+e+y2O3BgDNac7SO/+mxv7vlE+l4mEgy+ib+9ZZMwZHU32136X",
		"LRdjvoD5eTR5GgB2tncI9AmnBITAPrmzltg6Y1sRUXcnkgKxwVNetO8V54Tee2llvdcYjYhaa5/PHhsfr5BjARwn9GTGgY4T8cplKWVfKtnlgf19KapiVftS",
		"SWAMgABb7lkEII3R+EB47+oyhohMCKtYLCqlAGBxZQ0ACsUSANg++9iRztru6/LXrc1NY7rYz0730lzSVGAY0rT7FGHFD36k+vp9tl3REWyPsdBKKdzvxQ+6",
		"Q/gXkOFAp+dpKth6fJ2tj42NKaV8Pl9jBGdc8JWVlRdx9Vi3WIo4ibHG39cCdO3IZNJP5iNl3ksnYLReMaYmjdvH7JO9kw44MyStpCbV+8Z18eLEUT7iBx/M",
		"AYEQfHVt/UBPdLc2T73+GguGgZpv+KmpK7du3a4VE3tfTSvLstPp9N17923L+nt/76cA4Ed+5IfKrnvu7FtOLJXLNpSx/QMDWnfsU5q3rTdIQUTPkwddVapn",
		"mMoTCNC9jiIQctmtAyKv40IIIl0ql7qkxowxzvm+QRjxwGG6+9lDVgKAQqFARH/4h99pBwfsdeL6XCe+bTKiQ7yOuXbbufRTK+lVt0WXnqKZ4Xvvvp9I9v3k",
		"X/urrlfCJ7XWLl+5cOfWDABEY4l8dp9rlkimLFBhzqVSmIx7tu/q1OV2XAacmrqilNa6HueLN29Om5/CoZBt22fOnAGAcDjMCu11KX22rZTseUkS51wp9eFH",
		"nxiHxhPq6lZXeA9XCAEIvv71d3x+v/S8b3/7O1rrTrZbyFBrevvt64isnQtwk5gIA4APP/qEMTTC34zzK1euMMayma2PPvqk/l0IgHOuta7+Cn/zt3+39UV/",
		"9Id/QGv9xuuvjY2NeZ7bfSNBRCXlhx99whAJ6I3XX4vFk9nM1kcff3IIoDNVThUQdSqrCRG7kPEZQ63pzTdeQ2RPQifgiae9ngukgQC4AGEdSflRmpeqO83D",
		"IyOkFTK+u7uby2Zf1BlPqzbpfpd9eHiYCwGw145lpLVuf1MRAedM1DsN1j3K9TwASKfTAFAul6VSRjqnVUxHa7oweb6XcpsI7t6dZ4y9+cZrT9WJrc24Xnvt",
		"lf2XBWdEer8dGrXW8XjqzTegqRtrfnij5QyMjIwwxgjg6tWrAPB3/s5/1/qiN2/eRACttfS8piFwC2ARtSbLsupPdTazBQBvvP5lnnzHSXRakM+6CgIX1Twa",
		"jyrNywUgNpDBlpeWXkTkpzpGX7g0MT97r7c4roHoypXL9YS0riUVNVmpSCkHBwcHBgYA4Cf+8k8AwL27dytYH4BQYLCRlKwROyas2PxPeg5uzl7Tf4RDULGn",
		"pqaODuucnZ01Vr9PIUI0l0tHIiPPZbyoBz3RkbmsXW6rF8ezzQVHgCtTU0cW/UTGEAACfh8AcM4aem3wFNkoPp3HITgsRLSvwsbly5dNB2N6+iYSzMzMdo4X",
		"yIVg8oX059Ng2n6Yl3pxX73Q62h/VHCv1fxLSQkAE+fPP+eznmM9TBorBD/QCeOcA+KdO3d6Ceecc1MjtbZciAAZ293ZSadfoCxeHC9iNDy33KYXl7+bbhTB",
		"7Oxc95NEBHAQbnQul+9xCk1GYBAxl3smZ0f0IkV8cbyI0S+OE+XmMma6/NhZuNlbXV090Mvmn1811xfHi+NFjG7Cb2tTBgNRD1jNF1kNHBAEsvHiJLw4Xhwv",
		"YvRhZYURb38wU5H8RQSCK1cudQrTDAGQvYjSL44Xx4vjRYx+EodUihNhIe+isAJBWS5yzm/dunPl8qWWFjMxRE/Kfe08XhxP/+E4MSLqcYjAuJVJv9A8+hKO",
		"O7fnDHTTsIEuXupKPz6Ey/qLGP30H2v1PdBMVpfKo6NDnQeAqJT2PFk/qsIX08Jn8Ig6Ua1k79cu4B9uZWZyxhcXF1+czKo++El0AYkhQ86qYoHd0JlCCED2",
		"4lo85zND5vdV1FQrtFLspE774mI/0wdppZSamJjoRZCvLWyHqAJCWVrZGBnq+4qfT62P31+eiBBY2fU21jfiiVRHehHWa928uDG/CrgOZIB4+/adq9euaqVh",
		"TyTihX3o85b8sR7UvTsp68/MzBKRE0tAg/v4+MLjx19BxTl9AmoiShMic121uLT2YrE+hzF65s4c54cxIiopCnguEbiFgvD5ADQRGlIbvnA2qo9HY2OdfBsQ",
		"cXFx6fmmuCGCUioU9IVCwwjoSbm+tkbtSI+pvj6fzwaAUrF8COPzqBM3Uoizs3OdvkmTgcDs7Gw7ZYE2j+z6+P3P4OTk5KGe23OjgzGL4+jIwEksgUTCCYWC",
		"WmkAYsJaeHz4FduXjG8ctwrxVyWPPkTtk97a7HO3Pc/7IJ/B1EDE726XbNBKS08hR6D29wO1iQAGxddUUB+xHBuIFMrKyhasL/GsDg8PA4DneZ1uLSGEE0se",
		"VGj02TrOnz9///797Z3Svl9zc+NI0MOKxj8efas57oaxMS6gqjBNAxfpWN4KAfDkDK2U0sqTSmsAsI62xyit4UUefbgIva8waduj7I8qW+UV2oWCVrhb2EEg",
		"hujzi/ZNMQLGeTuSsSaiu3fv1p5Ukw1qm870cqxtB58C2puutWhbv8jszCw0KU89rYLwxxGk5EHppjuWhZpC6gDdgaXOEm4jIyPGXKJlQbKlpeUmHzXbtjso",
		"xCIAHchwoL8vYVvW3OwHnLNisbSVzj6juNtDPz2V6rNtqyY8OzQUAEAgaj3zL2J0R94skXZisUNIx+Y1ATAol6BROX5sbNTzdOv7WZa1sLDw+RcPLSHMpvrS",
		"6XEAiMfjlmXVi/5orf1+Hz0PCCGcnJzomNohHG53rFSO/f28s0kxImhNpbLxVaHOQZcayOhAjHG/zao5lDqYfbvWbWfFjNsRuWZbggCsQIxI9/vLbiFnWzwr",
		"Qy76G2qgwUHB+T8+Ld5xRl6feaSQGODObrnJBeKZkCsou57WpEkjolTq2ZwbE2MMEQAQxcFiVzbs9rEmPXOsLkRMvDG8sLbo8/nEqvciRrfmAxUFWWPTFY2E",
		"o9EoALiu63leemvrJBIyrXU8Fn35zGlo1rQV6+vr7RIf2STAhgDnJ87Pz81Di5DuMQpmplJ9rZS/RDKZ3tqCkK1sm2d2jiUUaEX/2X/1Y+nCssV9Sqmw3/43",
		"//w7bR/8J378a8WSV5P9RQCl5fy3l82d0yl7ZRxCIYEH1QwB0lob4Q6jrN/Y4a2c5omJifr4bnAdxsalvgZCRAJCUhYjRh6zg1bqJSUVhgcgv0JKK0VrZUsp",
		"NZywN3ZZX0gboOer/qHvuA9wJJGcvvdEA++xZga53HbTsPRLv/dd113rWU7AiSVy2XQuv32498qcn/+uyT/33q/dmJiYqN+5Z2ZngXD31Qf50U9s5n9NXkJg",
		"nPEKf7l6SJIHyvelVNnM9vMQo4lICJsjJ6Br165N37xFREAKAGzLsi3riDGaiMyN2pBSIWitheCppFPtwyGRtu2AsO12hAhuNWZkRmLz3r37jDOttGWJ+pYZ",
		"5wxRLq9sDPcA8IrHoplsfr24Ijg3IcekOf2BoZgT9vl9TY9fXFodGhnuiyYef/3+9tfSzp1Tu/9Qn359BIB3twbed5zkJPzBvigjWyoVi/vPXX/z7vsfAsAX",
		"Dx8XdnfOnX2rcm+/HM1ny4xjPQZ9/ttEBJPtgHEEMDc3r7VeW1s7YkudtMY6txTGDMyD7t27a66OiWmcM0Tc3i4i6mAwWJsKIuL58+eFEEs//7+5hbw/Nuic",
		"/sGAM5BbmHE3Hi70/8kUsIhiRERafbq+0ReqXNapB9l80f8+e/xHPaYtfVzCge3/EIhAcRsAtC9UAZVqTW0KgiO3pojI2PF8SbUzY6xUKi0sro6NDva0x2TT",
		"TixBBPlDeWthwYfELl+45Gq3SWI3KEK/VV5kBX9ARG+88vuvRt8aufuqJK8KC0MCffPUf/SLAAEhIBEBIkPGqA45RqCRNCnSwP3greOpzOvPS6+DgKp555Wp",
		"K7DnxzHNOI86sfwRlM+Qcc7p/v0PibRWGhAnJ85PTk7Oz9/VmupdTYm0VJLrNiekFZvlOA5jXJNmiIFAYGFhsd6vDxlLb23VAnQ8Hs9kMt3V9BlaDLm57RAr",
		"CLNsbicYiraiz0iT1oTKArKCvsjq9sKNm8sM+es9GKxAe7HWCQaWW/aKVGAgtWZFv1CqEozOnG5IuEpFVSpKXhejCdTk5ERH/3Q6nqp9eXm5nTtiwrQXkXEl",
		"PayUwQgIuVwGAEKhkG6IjHMA4H/5LzKEElHmo7uevVhenEZ+NsrL6TInshhqiSJe53q6o4vXlosAEEnFuujwJWI8nd3rIcTiqWxms0Oa1RxyzYVPKvBWV5Bz",
		"RJTpHIu8gpY1/+FHDIh0A8eyFwxi/TE4OCQEA8Dt7Z3KV0AEhGtXr34pN70mfev2B4jYY4CuhenDvyWjfSAvTBPTUSsaZqErFy4X1A4DBgAMmdTybuFdPw8Q",
		"EEeRdbe+e/CHz7mXyrJkHgMAGrRP+Oft27+//JsJkSxw7/nHR1cWJLcBYHh4aHl55VAT9jwAIRMMye/3E2nGueeVX3/1pd2drOeVGeNmJiOlt7yabRtKlhcf",
		"GIcn07qS0oPxl2t/DYZC9Slzl3DctfSlRtFz6lQYY01BCgmQAOi9/zQ7+T0vH3EUo7SbWQxY1pgCFhraRpRuWcZTfZmWTguRZhzrLY72GedhxflweGTEGFzV",
		"IDS6ziW4xTHYPICwDldjnrhURxTswdiXWv+5AxEttcnHg4gFjCjP23n02bYOsYADAGsrywNDw62vFYlECHg+11Db9SXY0qY/FXWHnHI6u4f19PlEMplqhe51",
		"ITrGPv80IYQkAsaoXLac6Pe8de5bi4/SnAnbbmqg6YPgJ1ZXXwhtd42DtgeFqjEe6MpNZsYniICgQWvQBISgFSgiIk2udnmVJ6lI29pHmjQo8+BnNUY3rTPT",
		"i2j7wKmrU9PTtwrrqyAY59wmcPEQPbgsACwurY2ODIyNj0lPWRYv7BbLu2tSWcZWdf8qe/SlfR7wBElrJ/ReCKi0B0oiIAEpSdG4L7OCjQPY8f7TA6VyuR51",
		"rrVWSs3OznWcSRIZo3QiYJyt13U83jotljL+XG4HAM6eFvceNrf8hoaGCiXXWBQe+nu17kgba3sBawsAIAwcdmgo7KsMnNsGaADQWjUFaAAwCoz5HSkdbBpw",
		"HdRIzGNc+3xv3bjFiEAI/QffWSyVSt//PR9HnIGx4ReR9MSYUXplfpKNf04HbP1gnXjvyfHl2JPuPnPb4r7a/2zhQ2Rt4yRjSFoP9SWG+lIEmEjG+pKJw71v",
		"BVFPpu9MDFnRZS84iPXXhaGVOiX8w+uB4YwGt1SAS1eHEemv/HffH4s7APDjf+0dAnXlnUEtkSFHYIiMNESc0NBosvvrX7x48bXXXlNaN8UskkUToM3P7Spi",
		"yma2llc3j3FChy18k8oOxBcOCQBEAIBIyGoPkDto7aiJKcW0ZuWy1ddnv/QSC4eddmOSp8n36gkdi8tri8trJ5GhuLtBQqPw1DFr/KrgOhjyRgBWp9k1aq2R",
		"M4hEBRBpbYUjFmBKqe2NdW5Z5VKpqaVHADbjn29sFVwPGZCG1wZSxqVQel40maJGlOxXMBSbOVVboHfVxxEBmdRlBNjZge/9M8OWGo1EPiGCnXLp7T86lM6v",
		"McYVecaKNxwNfPt3PvhwenVwcBCxXcOioQXbkmvUs0DbMULN44cHU0eMROaLU7vOeG3QGsSCEjIvxaEx2nS89zUiSQmepxDf3N1ecBPSPp6MamBwiCFWEJfP",
		"1DE6fBT6ImpNrZPWudl5wXl4ezdDRECaSBNNfzCttKo0PAA1EHuFM+QAmqH54XnG3vUOS8OpK1dqWv7TN28i4yGOWpcFYMQvWkePFmM5Hy+iNjE66eOcIwFq",
		"pnwWo2ebfXFEvBdDBK07hg0ivfpg96W3zgDVpoGoSP7bn/9dIIxGnf7Y6wis/ulK60gouPzJnWPK29qGOOo8eYNGlnDCH/CT1k1nm4hq4zXOGQBJpcNqy4cl",
		"Zvl5IOHayXQ6DQAKhKITEJY7ME2vYoFDjAEREgGgi2hZTB6bcuRKNOo4TvQrlaFolMGQ78bsDaVl0yLRROMRPnrva4hYWTA2GCA2EWkiBvw8P/ut0h84zEFk",
		"O27+haZSA4zB/HBl6opl+1fvzWQ/vRP096kWWjMCKNLnRx2fqGAbV3Lb2tVMiNJOdvj1V/wXp9yd7Sf/FXqYazXvYMdOmTGgiMGhAQQ08KHmmSHJgIhtPSBd",
		"hwNFhKmpq2Y8tfFAAaimGPTv3//dqBOLOjHpeZXpyrFjfnrFpTYJbRIi8zxvo4XVPTY+7oxPyJU7gGglTllAjInNzXXO0R9NCPABqY74gYNcF0Q66PnQngQu",
		"5fYOQ+CFkrYtEmLiW9+en7psMVWk40nfFpZWxwCcmAOkv3RMV48Q1aMfTm7k3/3T3wyG/EJYTQmB1rS2sd/MYwWu/bHvAkYM+FZpXXc4dQwYR86Bc9RfUd27",
		"kUgoD8SgfXOfM76ayanqjRSwLM4QEXiNJ/N0awYhQ58ttKYTyvlfu+5MvHL9s9kNwOZ8EwE0Kall4/ZQUXZgDJX2OrD52mfB9WQTROwsFbIP4CSXzS6vbgwP",
		"9vWSpdfoCUQ0P3+36RGfff7AdcthJ7WT23QUEKidh3M8ccYQLAtlKmxtlJkv5vR18TWPOolWfC4CbO96ED98oyMeC2eyO/5EHJEFXnnNx/UXf+ZP9t28Hf78",
		"gbR8Ih5DOwBl91iWwdjIIDw14K0nE6CXVjbwjLe6mg0EDnxrjY2Pg6GPf4AAcP369dFzp/7N3X9RQYBUX0+DIqBtvb0pN5Fwx/UKi/bIaPs23fLqZu8dvGcs",
		"Rr/76cN8eMACP3HdnN8QEYAvKJCZXhuUpSQiBNQBsbqa4TemlZRTU5efTiECLlih4MZEotYdiTnhjgEJD9NB8VmhX/6537xw/kpLgmfqcmx0QmAmNTYcEGzA",
		"CFaOqasGz85KxV3S1D5EEbRSMXtPowGghwDdrSjRm2mWSgCAbduk9U5uEwCw76xgnCvJBUskEkTA+EB5c+3z7GKMigsPP04k+2KJ/gcPHyTiCcuyACCXzw+/",
		"eSq/kG59F6W1ExEIbs+3/XBrDhuORGhkWDOw/+qPK49OcQWXJ5nNbSD93gdRRtH6qI9AGhYXVwGeWXXUg6O8ux8xJ9pJKD4ecyijcZgRUWuRioDIgKjSy6uR",
		"xDWREBYZsk+VRi49N1va8gm/rX0ExPY8Csji9iuZV0ai/3XQDqlRdf/cw7YfhqjCXHsOY7Tp6WspPXRpb4kjAAkuGGOc4eJWpuxJYAAaxpJxwZGqjf+n+at5",
		"yiWQQvCW6r15PS2vrA8MDTKFzGUHnUkppRjDYNCvcd9ZAXluCRBJk7CsxoVPzTk4YjAUqUVVBryscl//04Mcgj//0+/WHpZMpeiEhUuJCBsorMKJOoILFY2S",
		"JvngUe0DBP02FwLAV8dbRP1a/8wv/NvB1EAoGVspbnz+6YNgIPgok9ZKc8HtgP/93//W+MDp1rfWRAej/ZGGOogLESEXud1y8TvvvfY93xX61ruf/e3/IRSK",
		"7exmL/zcP/ntzx/s3rg98P3f3GUAuur6hodvVDyx9sITPrK5blHv3NdfXZpLIxJrlvhDAjKQ6HQuDQAJJ2HWRC6XTsTiBiM9VaXXIWBYRD/f/jgQDyipWL2P",
		"DANNZV3yilTSLmWyuWe012GUdWkvHaBeM01SUgVC9tjLm50I4gQL22VXeiZGB/urRGrLhp3iWPwp3XkAIB4e9OnmnCKT3QmEHGjGR/czwOTV2Of9JQb8QFsP",
		"VbMD2k9ulQjKpRIy1JoY55yLLvuB9Lz6j4EgtYYgjDC0nVgSAEl7+XyuJbbvv8XUdtah4WFdRwqtF+4slrxQyG+GbaFQsJKgISIi5ywacyDmmK/0ztvXTOMG",
		"iJAhaXXlSuXGm56eZowPxkamXrs2NDjy8b2ZWCSZHD2rlIeMc8YKheLa1ub17/nm8v1Hx6V+dH3qbP0/XcX15Us+P2xr6PutXwOkIOGaj5XXNkLf8107AEgE",
		"iNevnCWAG7fuH9pG5dkN0PF4EgAynfHy9T2EpZUNz/NMBWgJa2HjgYMvKVbGdoBjBNCEO8VU0C6V7IWC57cY5v3bidExyOHly5fqa7tHH32+tPvwi/xHJkDX",
		"SUYSMIbIGFFpgwJLQ8MjyWeRw6IBkeq6OIgd6/bp6Vuw9+3h6tQVIrB89ujoaJ3dDjHGa3Tt0+Mjz9ayM6eiNUDXQREgGo35A/b6WkXsSaC18AOP8pALQ4AO",
		"cqMKm5nIJc1ksnrbt3+wZQEi04RtbO+oHq9SKhWbxIgZst/+5Q8AIBzyAxBj/kDA73mSNUPgqcG+vbOYuBBCat0W7Gy+UVWUA6vxkq5dm6rcPWSqWbx1606t",
		"Dqji8CovODV15fadD5Y++mI8OAB5eW7sHACABwCW4YuFhdU/EGXb+iSgPkSE3NrczEVuzvUpr0TABKv0iKRiWtucfap0MhkLBv1EPc1mo068i35LLBZ7KhBH",
		"dNDx+z6Tvfom78hQ39DQkKEOrq2u5eJleO0Bd8EDry2NhaTw/eqY8Je8b3yi81HFQXlZlUrAeyNN2+ErZ99k3+JRK1bLISzbAgJQYFJyhlC2KH4cAfpJx2hE",
		"9FS5KWZbwscYb82mTYBGZFBRVKP33rthFqeUsn59WxY8N4eZHdWmZOWyCwCMC6uqxMhi0YXlx2phJzQSVEwe6CYrZ5Tnynffff/td64ZRo/mvK03MyL6A8FK",
		"JUh7mff0zWlAaMK3nzt3rll9gmBy8pyZmM/NzRtplNbPU6z7+EXV5qvsXWgiArjQyGOcnZ2tJNNUibO1Mb2wrNWllVAwGItHlZTT07cNjqpqoEdTU1Nt7lNh",
		"79ss6ga/bTqNB8itEbRMxCL0tesZQ32tGWsjqnsfFoDGLA5AhtRIvfkMdGsLZLORSORLprEQ4QmP8uv1tT3btQs2lSFqxZs6n6bA06BXLz3CUNnJjdjK4pqR",
		"awelc+3aNddrIFh9eu9+2BdhUOHBEVExV0KO6K8sRQJQxwfNEl+uzQp128wJkRVLpc2NDSfeB9oLhQJEzaYqMzOzz5NtpekI16ZkhjmdzWyGAsOMq83/2wJD",
		"LBVLPhEQ2nZBAR3gu//6z93JZ3ZeemPcY0J67uytaSQCrKBkrkxNVS/GHjqPSHPOEVEpNX3zZkXfq7r+kDGt9ezM7GQbC0EzFMILkxNz8/PtknH4Ynkvsf58",
		"qU0lsbGxDgBOPEWdSdXZzFYkHGxdOYXdkhAC0aTMpDUxxk2LAwCnp29N1Ql49Qjd7zzVoN2ChPjhi0u0Q58+Xs3/lz9x3QplPSmYiRpAGuSPfK8ilfiebxT4",
		"AWavw8PDne6L6o5LX+KQhiECUMDvHxkZbh8BiJCxYzRxd+4OFl7b4iH+Z/z/JTX28gmIIZ++c3Ph5Z9/e+SPsHfjRoYTAEkrKV3OeC35ICAO/C/Ff9L85uaN",
		"GwSwuLCwlFlz/qJUOTp27rZ4uq2LtXEtymU2ACAcDpL+CvID68fPCADBQEADaXAJPPLJt7/3QoF6wn1Hk1YiGl+x/d/lu4wa/qy+/6O3ft0dHykOvwkAb16K",
		"5Ha+kBR09c7v/vwXDK3LV65wzovFopQyFAoRAEP8/j928Z/+w38LFXzC6AHqZTy0svthJDQZw08/+fjhwy9IEzIuXdd4bYyNjZlY3BimEYisfQWusX24EZV7",
		"uPfF2YCCR0RyC6+PJOjf/xoKHSdUihSAQOQc3wEgCVpIS9Q/a58hZVuZQKi4NfZzzmxmfYnOO5oIkJWKu5ubT8iezV4NF8ayGAGppEdu/f5EQBazvv4j3wjs",
		"+srvSk0aKzUTAlBNGN2UYk0VFREBQv57l4JalXe04OLYT6p4SoKPmZ3VGtBGf0dJBS+O2rKW3J6LYa0XTIDk8s0w8VXwukXAz1c1Z+hK1e8Ezr8cS3n63376",
		"y4DwYWkTr373J4vLuJgLhfx/57/919ns7uTZxMQ3x5Ui5DA9PY2I5VJJEwX8fmOAUQvQALDweDEWj4eCAa11FxwVEXDONg5tEogAABMT59u+thNrk76+//57",
		"uztFqXTUspWSXqlEBB9+9IlSEgBGRkcZNmTNt27dBqJAIDAwOFgoutu59Ik72TO6ceejemx8qeSxzczXf+gbr/v9v//vf+/3w5Ef3th4+z/7sV96705pcXUn",
		"HAwlHaj6PPXmkA4d3BrXAWBsfOxLV0Q46Ps7sQQAHs51k2wFzOD9gUHDDMxEn1jc+c6/e3dwY9js4vWK5F37AQhATIldVfi+4Pe9X3y/s07cMxujCciQdqan",
		"b1VguYgI4Hme9OSL0Fwfp8L/crChHifyrCIIDW63GI2kgJAjlcpu1PIRqszC4p++dGnz0UJWSh8LuUAMPSVV0fMy6fy3fuVuKtVnWQgEiOj3+z3PQ8aKpVLA",
		"72+8Z+IBv797gD4up9S5ubkmL2BzJqLRSLtOCCK4m4v3VSy6qyqk5zffeA2q6qaDg4OWZdWqfiNCrTyvVCxsd4Fw0fEMxTzXI2oGQDJEnkrcn//kzPWrA9en",
		"/v7oyEel7f/fzQ+AI4wO+aR0XQ9rw97W9nfPR3Xagc+czfuR9KO7V3JEnPNyuVxhiB7w3Gp/SemCLSwVKBFoBr7nJ0YjolRuVf9BccZ2dnYymUzESZx4LvMM",
		"HsSLHQgt3Y4zQ3tD1bznRS2fp9TPfzBDiI4d3LHzjhPy+fzxfDoeqSjbG4OusbGxhcePBwYGkLGFx4+T/X3ZRsinbVlPoNxBxhjnAHDv3v36G01wTkBKSsZZ",
		"yy1PgNyOjGqUKxk5PDY+muBaaUQk0lqTcdK6ffu2CXiMC2MU+/Dhw9OnTx/Y5gohErJYG/ovdlBzblNSTN+d+yZazLZv/63/gXP2n7Lpcz/zM+QCIJR2dzbz",
		"xyZjUJl2VMI9fZkzwyc4ScIyR491+bpak23ZB98+iAjC91+h4u4X3lo4/Ap4rHRuAdizpvGP3YHPNRwVY0Yj/0WA7pARBwiLrXUzduJXAQBALJ4CAKNMtLC6",
		"lnCi/nCEtJy8cIGAxs69NXPnA891h4aGAIEzvri4GI/HpWbGmVRK6fP5AIAxvp3PNc30YvF4KBjUROzE7rdcZhMoXis7aW9TQmQim9kcGxtrjDUIAAQcAIpS",
		"DMUhyna0iigla2FWa41Y0enTknYSudcGzm/ni53j84EzQ8uyhbBGR4NEpJTeV2V/6twE/+Ih89m+sSEG4Bvqf/R3/678+ttM0+arLwcSwWK6cOwm22bz6z4d",
		"PYk4TpqgMs7t2txwokCQyx+DhlHh5U2VKqCw7sx8QKBb1R+ZYDvFLMAINOrZkK4oT7R+WlOHIQJ77Dlgi7htLe2g9pXfxGNsd4gn03XSupu+zB4EhygaS+Sz",
		"LwL03rG0vDYyPAAEgO7K3/ys2o8G1Oix0sCnr3o/paSWAF2QDw26celcfjQSlQRAhACkZHUwQqQrEqGMsZ/8G39ubffeP/t/LCullNYAsFG1ByUnDACc80w2",
		"F8cTnBim+voqQ+NsZp/XpiZ4BtZrVefy+Ug0CoAXqvgTU8zOzs4KIVZWlz+8eX+GZnUZucVq996Zl049Wlg6NTZyuP5psVgKBPwAsLNb6kW6rzId1ZpcSQCE",
		"wEIhtH1MyezKCsDQ8a4rrZTWulgodOQxANYDzo8dv6SV1LpbBdY/MOjz2QDAhJVJH3W0qBxhr/f7tB/axk8EJoXYciAAUmpEmp6ebgfQbLJk5J6USupYIpVN",
		"byotAYBY8XjbSOLJtJ6U161OrIelEtGLuFx/jBjNXEQg+5Rzpv4sKnBjiVHx5sGaX44Ta7oAtZxiZmbWnP+tra31nc8499UgCADwQ3/ySjjp+/1fmU/f8zML",
		"ADFStHyRMGAZqWtDHEFKFXVinLNMem8DPjVEj6pWL6eH9MOV5qa24KLXDJaoBqi6desWY1xr/fDRwulTY9VZE7XqWZviLZ5I0j3x8tkzyVSSNJnCDgGEEKlU",
		"ijFmtAQO6pmrTZZOxA4mkVVvY1oVnT+BQyvpeV6+ZfMz4py+QIi0BsZIyXKpgMiO3c9Qel73GE3mr0TdH9bjEb4XqfZ62kRoYvDL/+IXRwdehXyx7Hk+y+oh",
		"EybO0XPp/e0/vHrqByG9yTl/hrVJO3MJ92L3hUsT87P39l3A9YJqT49A80kcqVQqEAzWpmZj4+PwjwEArk9dNw94f/p9QBgbr3jC7u7u9mKjnstlI5FwDzP0",
		"gIUWACBwwyVJDAUjSfuH/uSVfzXzEQAEPrrkLroT3zviP7ta3lH71lKWEE2LOGJpgMpvIjZ1ImH2tLyYuH1npurjLgDAtoQJ0BVgXcveX/uFkp4G6cRiwWBI",
		"SXnlyqXbt+9UFT/2zNoPOuny2ZZWinHeo7f9hw8/n2pZyRenb89dunBCoyBkrDWsEABn3LJsTRqRKca45xoC/TG+OyPWvUFXEUJRinFutmonFjNyLN3pOZ2O",
		"ze/6HCPKVgGcHdZAQKSpllkYpUnKf3NG/2EUNmBkdKyXtff+++9zwcSGlXEfnJxVi3gOYtlBXeOO63iU/qQvOXyS34tMelhZylSBCWvu1qht5teGtaGPFTz+",
		"P/9ffq3KSduqsv6oVJSuS2zmvM8BsCRZEphZ8NDQXKzfSqnSy6LKXVFXB9RBG9QRrmHMXpCKL6XD1TjKAKBeQRSZQMRW9N7ExPn79z/kwkJkiJy00lqVy+65",
		"c+dqHRQEmJ2bO9wHKxYL6XSvAeXN0y/D5w8AgdheO3Tm6mWm1BP126gow2E9qObYUXrm9bq8ajKZ1FqXy+XNzU0AGBoeEsLSSi0tLR3uHXnJj0yjto1Y3dz8",
		"PENGVUUtBGSc7WwpnFi+2P/n1r7zgPHevF2UzgU2/SNXS0vrBF/5GG04CMeyPkgbTxyqinAe6qozmzPrpCetFy9cqPbrsYrcUjWfwNptdefOBzW++HEd/X39",
		"XHBEMOa8f/jvPgOEc6+fJ9JAHAhJA0fOBbP8xOp4vdKtdTIREBhDxrANE+WY6p+NzbxSLL8tW4alSSDKZtMcSes6FMEeDwS01gzh7FtvaK0QsaZA3fIB8aB5",
		"klJadth54k6YcV43jCJLiPXNDHgeF9xXLNdWJFeaSX2sUK79m4oE5Lkl05TXpE6OjtgljdaaGEOrpvNAoJXSR9kqUAvBtaduv/Kt/+LUX773Wx/vekVWR6wn",
		"oCuBi6u45vIMYhuFGmx3EoXFLthXSkvrpsW/Z3t0fCftecijDxxbBbeDAc4rdgzysNLp+9VqPcZhBgBZL2u6QXGMNEYFKpZKvfS5lFI+n9Wm77zX3ATL5owB",
		"IldK9fLJhcVNjkykWqOW8ijSb/3h/2dV2AyqWQfjUMrihf/r4g//xbPuLv3cP/qPdZnRSWmTrm6PIhJAvibKThUNTwKAcHhE60o5YowNEc29iZcvXmAMbYs7",
		"Ttjvs5XSHdApSESJpCMO2HDs1E+nRhEERJRSJZIxHB7I7Rb/8Ae/t247QKZ1bHDgycVIRNK6XCrsdcdPTFWjS8glIJ/PD0BjY6MAKKVpXuNR1NxK0kXNCmr3",
		"xsrv+sr9uXyzdmjfTOK17zv/ln7Tu+piRdNuz5ybWgFpRJbgY+Pj+Vwml9vG6l1QlkVXuy9i9CEvFLes7OrmrV/9xXjfgJKe9OQbP/R93DrMeXC9gifLx5Is",
		"S+UiQE2lpSGEM8Z6uEkQoYkon8tlmx7z3X/q7Jm3QpQb/s1futlLUmhq3smakhEBE+Dt7qkdIEe3pEq70vAeAQGQChtIWhG6zSpJJzc1ULn6L6OkbLqfmzRN",
		"pfSUYgS0spUvlryi8i0spV895RcWaGgvt0BE6a1cKBjtQu0+qHfnS6eGzef64tEyAXGi7ZdHN3J5n2XpxsZRYFediHJOFxbdiSOXCRAZY11MdqSUjDGlvNo8",
		"gI5g7sWZnQr2MY+HdWw0dGZLtPOhB1VWZc10a9bMGWgC1WIApYlI6/FTfWtrlluunM/+4PB2aedFjIZDi7lEuJVZWmXEpOcp9/BQ85dSbx6nJ2wHyZ5em4EE",
		"3cVcHCf+4bsbH723PjERuTA5QXDI5U4I3EascrG4hdzCGimBC4AoA2QAx1DuEUEsnshm0gdXKMd2Mk+VkLe+vvFvbv+Htwa+8bf/0WclxJ+K/+6Vrfzlf/DT",
		"xbERubvbLrusGNdKpaJOMp/batZHZWx7V2IcWoVTe/nAZ04Nf/5wiQDKG9tRQHDb0Gv7+/s4F/VCbk/M+/kkqYbYKUAjoFJq/NQpRPz8s88Q0ZM6n8s4Tqw1",
		"+ejleDnyemAudmFikiO/eWva9vtGRoYrmQfnCwsL5mfBGGt3I7Xld1+5cqVQ2J2fn99YL3LmCwYxFAoAALvH4+XyBqy/iNGHiYWe67Jk9Pv/Tz8phG2yFa3U",
		"cy/VFI3GgkG/CawcLQLdNq1FBK3JcaK5XL4FogeAIF2a+t6JjR9ZeP+frfW/EXR3tdzVpp/PLcwulH/gb42kvpHd3YmXyyVE39Fr8YMG6B6pJv2vbNhliobC",
		"fir/7/+LH4255dzYwF1Pzs3N13wn6tFXtb5lU4A2/Fi3XIg6zZKhREQdQGPm1D94uHzm9PAB3NSOtedAJwN8PhDGUGu9sLQ2NjLQ0d+zmtFzzre2tpZXDin5",
		"sri87veYn6JFWWDITO9Oa8K687BWDFKR9QfK7//++5evXK7q2lfM4s1kAdtdFwNdnZ2dNfhPAgAOWqt79z/knNs+/5nT4y9i9IE7U0oqhDp/VcTn+PvG44lw",
		"JOS5HgBNVjJo7HJywuFIJBIFAKUkNMOK4e6te6MXh8Zno1uLxcSo/+rf8qTUlYkaWSjWyyXkzPf7v/ARAAwODjLGqhpseCixreO//kNDQ3968G8CwX/9F84j",
		"0d1QFBhDtwRaGjIPFwwBibQZlu7xONrlnlLJoE9I6RHwZppGB8QRHZDk89KZAekJKfVxrYdQKFAqldiXt+w/+vhTIgoG/RcnzxnhgRbZQsYYe/DgC6MFYCL1",
		"oR1kRof7Xw+9tknbHBkiqycZzs7MElHciWYVMGRn/K/O6EUlPV2FErQ9S0YbT9ddydprEtHdu/eqYww4YoD+isbor9qhSZuJcyv/temYnJycnZ1Ve+Pp5qcg",
		"w/Kuiry2dv0vD/78T34+8Grg/NtnZ2/cNcsYEUgDqXqG2pE44kTkxGK5bPbYzwlHBAYBmwOiKm3Pzs+jlDGfPyH4tuctLK70PmSrkGHaoYM6dXWzud1Uwtk3",
		"4j7Kpl3tvZoYePDFWjKZCPgDh/6+AwMDjCEiW15ezmTSPt/gl56WIKJWynXbz9akIpBlsydyIaQ88AguEXcYwyrITy/dWLdtf5tdH4GIbFvYFlFh691fksFA",
		"uFQsMsaJiHPu9/tb+0IVZQ8NJSq0XuXLly+trq59+w+/Yzbpgf6UlGornYEvMUZj97/hizj5pUu/YgdtzzZhel9ZTdfThZzHBBLB/Zn7pCruTVR3uc2kcXZm",
		"9og8ueNluNV9OwICpcgMr0z09TyZLZXQEgDw8Sefv/7ay73k9XgoT0PqxmavHO/B2qew+b0efM0akEod5T5qIkmurq4ODQ5IpT788OMvqxUtOF9ZXfvi4eKZ",
		"06Own8Rdl9Fip2Pu7ieelAAGxEOv/ET/0IcvzczOXWgcVBjh3JWNdBAgkUxuXf/kj439zY1HKxoUUpvZKQJKkL+y/TOecvv9w98lfrCsSk0Pu337TqlU0pos",
		"S3zx8PFTkUcr1flONN29F2F6X/l+gJgv+Ux82jcn3vzg/laLitFTI2JJFXJ416x2L97Ozs4RIfr5pwurdz8p+MP4ynCgNUADgBFkaM74SANwRdprMaXsNJdL",
		"xqPUqGBjJr7xaDiT38MDCGIMfcz0WgAR8Mbi5zkHfzBy5tiohgfcSJq+WtsXoN4yOQKKxZwzp+EAWn0H6m+MDDhOzHycXC43kD5NbZ0MEbRWw8PDRlJ85M75",
		"377zG5W9nNpzXxHYueAlTSpsOXpbdToHjCERccafihit5Ul5cMCz4Bp79ENqFwHTxfVELPpix9o/uPAwqZ1uWqZA8/N3W8ehANSpUPjx/92f+ul/8M/PvdY1",
		"G11tI9mxu2MBgJTWF0vNEbCTrDY13hFfPFxmiFKpx7T1wYPPvvlSxS/c8gX07oaCqvk04roPZwoP/9z5tzMP1454DldWD/8KywuPhsdO9fX13Zm+OXrqpUO/",
		"TjxxskmJZVu1fXLpzsPR0ZEuYxhZ8TSmfUtJBvha6SwgUlmXVKG1gCICZOytN9+ApwjXcTIhOJ5I+Hx2E+jC0J+klFtbW19qXN3zZDo6jj8cSCJAAGwCepZs",
		"B76MrffMwLbP2lzK9OV3qeVPWdsSabfUOqsjIsuyELGVMWaq3Z/6u//4yYrywplTwzXbK44875T/yXvv/f0rf4qBx4VYW8twVbA1e2d8FFZL5sUGwz6xin1+",
		"iyeTShNjsLV1SNxLf39/J/ac4Uavra+380SOWbbd19fHGGOIF69crUulOz6rdgz09xPUqWQwPjAwUGXxSEP7hmYL80T2sEKYm03WP1THnKla+u4bkdseu3Kn",
		"OlFk7ccWz67nLBwMds4E4wp000aFR8DY3779gfRc1y0hYy+NDx19pymX3SN6jABAEOw6TcjjtzE5/tfUoN0e6qcTOL5YiwT8kWKJ2v0pFvDrYqm9EGhfX59l",
		"Wa2BCRG01gODqbXVnhREo06iJgYyMDhokgbP9dJ1+pn9AwOWsCxh2bbdtFaVktIrGSffLx4uVaZnAN7j8q/95f/7Jx/MIrddtwAAf+UbP/Z3fvNfnBJ9C7DA",
		"GAeAV9944zc/ee/7fvTcz//T9wE5ESWSqfRWTx97oD9l21ZlgRHqbnB6Yowlk6mtrc1YPFVra2Qzmz6/n3NGVElP97jaHZ5Vu2Gzmc1UKmXZltZ7sCIiMmM9",
		"xtieBzw0WZgfD/jScRwTOHiV/IkISuuaCusBaRasy7asNYnjE2YQT7lJNhGdP3+uHhtAAHNz8wdF4EedPXVKMpscETaZ4tBh4vT6+ho83QdnHIDm5uYRYGJy",
		"opEffhiB4I/mP2SiX4SJ219O1l8sdfkT6059biuQRATC4hfemZh5d66HymnvLYTgpAkZNpnRWEIgAyQULUa2iKQ8Ukp98vlChXGDgMwCgI8+mAMiW9hULgDA",
		"ULxfu2VlRLOIgCBg84nEmV/82RuZTLYv2efKcigUgV6HRkrKiqw2IkOGADTZaD9mjpnZOUSQ0msVH1dKMYbnz5+vmbA2PovaPqvKG/SIbK3pwuT5OnYsaaJ7",
		"9+6pE1ZGy+VyP/Zn/+Tv/Nvf2CntfnjvQwD47h/+wT/4rd9BZJMT56Gzh7rWRtgHzZVqG3jqu/Nkov+hRMIunX/jGcTeYfXc1EknHDSHvv/hR2+9+YYTHSOS",
		"jPH19c2PPvrEiUXOvfnyzs7uyXrx7W8r14zKMj8srawnksfTrVNaASBjCIC2ZQFA9X4gxhhp8hpTmLm5ediDzzUjPebm5wDwj//n3/dX//iuDf5/97OzvbTw",
		"noY+GlbuItb+HiPsJUA3BaClxaUO+l9LyWSyUzsu5oQRgTEAAqUpm9sF2InHHUWSA9NabW3lAeAf/Po/y4M7vXl3BOJEGkD7Pst+3/DIXfa+3WdNfPepuV/c",
		"CASCBzoJE+deRyBgFrdCRO0VMCYmzt+7d78ziAX39vW6W7HLs+qvwERTQMQqqKC3rGtosK8qGysWl1YP9N1/+mf+l6Av8Pjdbxmjtf/3//YPX+87FQ6G2roI",
		"GWmXWnBAAKX13pZWfXztYUSVInhyYoII+AGjCrXl0REgw68EPrravNeIqLXq70/FnDAyLBZLX1aAhuqoumlNx2NhBb58dmtkqN9c+JZ7oSt+pr1TZzaXzSaT",
		"KcbZezdumgVqlp3UmiGzbavR5MkyGZPWGgFmZmZb89Ff+Ve//d1/7EKuuI86zlGhH515ho4TM0ZXuVwO9plqpJT08vnceudW6Y//1R/79V96FwCiUSefzx3L",
		"9WWcx2LxbDsHmWyueeB5a3dj7KXgFeW4pUIt7n9v6PVSmY+U47XgCACh4TOnLrrujp775D5AiPNeb2HOGUO8e/9TBCBkRiao2+aKB9sx5+bmOWe0Dw6X5ubm",
		"L1w4/I5e2x7wgHOgWCyeQFarmxHREsrigjrbvCFiqVTWWgOiJBb2C2Rt/L0QsVgoEulAMETaTB4JEEdHR80Ee+Hx/vC7seHB54rDUotcB7lCkT1SYaXAxC66",
		"7yd0fP7Fw733RVRKAWlEpqmyto0uHSJqokQiYVql2IPzGxFxwQDgk08/xz3Fxb0MRX70ce1FjIopInpScsYDAV9TLa+1Hh8bHRsfV9IzhFzYe0ViXCw8Xvl7",
		"/+3/+tprL42NjUnpzc3Ptw3J9ZMDTcSPjzjRu2hDJr1/u/bXfuHbCBwAjitAm92X8V4zgK1SQRS3XR1eW2/4tD+aeKV+ZaaSDrnEbyeCyELYL5O7jGEyGd/a",
		"2p8f4UlVqdqBGAK3A92WOwK0JbLvsxCRdR6oYCcFgsoTFS9uqUCyh2+hicj1DqYzlc1mkokYka7Fjlgssi/BqlYJPdgOv/1quIM5C6YzGQAIhcN1VFCSUpq5",
		"6FeSZ4hAmrS3w4XYN6wiY57rZrMQjjgAcPnyxZ18ZmtrzRJW26Z20gkoJREZEDHOM+k1qTyGjPZKHhUKRUPhmJIe5zwQDD16/JBbPbUFX+4RDlpNxAAwGAzu",
		"Cx0hIiGsUrEMAK+9+vJxneZ8Lm/aAG0j12uvvWTEyQymrQcIzdMLWcll8sf1Uo4Ti0YjWiutSQh7dHSkEhYZ397ZyWYyHXiPLBwM6pwGgLCTYOT5fZbSOhiK",
		"uK5aW102jjCbWzkAiMaE2YbzmfxoINpjsEqnG3a10dFQJ3L53Nw8F7ytHS11EVMGQIaZXMczmcnmQuFIe2klBEmwb4AGgI3Nw48Qt9LZFicB20Lozt9wnHgu",
		"l4kGBQDMzMxNTE7sCxerVSezM7NHT0vEsxmigQCYFe5lyEcA3PY1tQs6eisibeUaRQt5dG19aWhopPaUtaXHw75UKWsEdr2RSH+PAbqnfN8JAfOZAt9koHfu",
		"3Ll69apB8xBrr8dFRMgqNt7HOmbZP1c9RiU2eE6w20JrpZQy1Y+smyV2H3QrrcwV38mlkwlnfSMNAFtblUvg81UYyUNDw4wzM2rLZ0AT5bOZYxZvBkCCDgEc",
		"AWh2dm5ycgKxwdiXulovLq1ujQwmzXptkjGZm5vjXACzlla2RoaeKI1LKW1UNTpFUsdxcrkMALyc1Fpr5Lz5IhIAnmzy8VXS6zjsmRwaaoC+D480iqTQkSJj",
		"IhFNp/ONM8PdPZdoREQ+fes2kAZk169cb8XTA4f33n3XCM98ZSNjNJYIh/ykG6ppo7ewr7tSf38/F7xpeRDR6urqYVaZ8gB8ExMT9aMOrenevbu1C5RMRPfi",
		"FCJTFC9SYdc1NtgAsJXOAcDq6srg4FANsWfgXCsry6NjY5rIOD+YkLG0vD4y3A8HkFVK1QfUBt2oakac77BDcy4Q9fz8XSIyOLzq7zl2nu6MDCYBABnnnO7d",
		"u1/P/ORcMM6R1BMO0HXuOu12FwJAqE07stn88HAIEe/evdtY7LIuOGDqrNnSdCyurHXQ/mPiWdageFr0TuFI9szUlEfXoB2bm5vxeEKTtizL77PLpd3SRKHx",
		"CmqW9q2/t0ZEWil1csZ3X+rRk1aDlhyZR81Q+l5mwsjMlIc62wLAcXty14vFE2eMcdH0jvFYFACGhwcR2dLScqlUrMWRRSN2XJcO9x6gl1fWh4f6a0C3mjEN",
		"URMJEwHg4ePl0+MN6qkbGxvxeEJrZVmWEGJ7e4fVbM+J9o1HO9vbVJe1UtUNGJHlstnHi6vjo4PHe6pj8aTPFpp0E6KZMbaysmJM0Ofn77Z+cGTNNNFS2WXY",
		"dmZ4kk1d0uJLz2fp4DHRnNmxsdF2s0SUUj5DBXh3gkkmk374eOn0+MjI8PDq2uL/y/r7ewo+GiUrJpdf+fW/9O43//RlJBwbHYbncVvtRasBmSCgiYnz9ffV",
		"zMxsTzh6AgOZqgNUzZ1E87z2kpnqNlw32FyNDPfXf9pMNg8AS1kYicHIyIj5UygUamrZlV13ZGiQCdHY+SdgorC7U89CjCdSDM0gGoUQWtOFyYnZuTlAdF1X",
		"CG5mMEbFQynZ198XjycYZ1uN9L9MJv3w0dLpUyN9/f0fzMyfeekA2puZunb84tLa6MiA4zgGeRaLxZLJJFVj/VFYxI1kE7JtS8oGVQ3j+A4ABNz1pMEvtYs0",
		"DT2Zff3d6ci53p35j56CXgcBE73vPGhumLaqJZ4n28JlnrN08vT4SJWKEuiHIawLeR6UBoJDtl/k8zmOHJ7+Se+J+bAgdPAjJXLiqVxmEwASiUQ6nW67Zto8",
		"94TrtGQyVekMEHGGf/+P/+1//d5vIef9/X1VsVMkrRlHqhh1AyIur6y2NOKGlnrLSGyL2xWaX4UdBohEYAm+srkSdZxoJFxDChsbXEtYXIjWyHT61Ig5QwcK",
		"0NCieTQ0NGRmofX9eiLggmuiTDp9HMK8pHUzD25mdk5rAoB8dit/AhW1qU7g2e1HIwPGsJd5PwddqUSxLfyuBd1JNDc//xx3ZSV42KCR6HnaA0LBBXv6Y/Th",
		"hsO9wSHREELaqwPrKrAh3aVteLyZyNxcdR1S5T+cs/qFrrSqaRsD4ermGgkupSyXy7ZtaU0GAWkxzjhzy2XLsnd3d9p2h3vsRyutlVLnzp1DxFZyaX0Iq6m+",
		"zczMdm8WLa9sHFp332DwTWiemDhf69zOzs6hQq318srm8FDq2BhQTaaWJ4UJRgstBkwDVXGn+AzODDsY9M3cmWsywKaNlSXm65SG+P029dACe/4kTOt+RqxY",
		"IR5L566vUbuASKt8vs3gyImlAn5RjxWtM1t56gbC+WwaAB4+fnx6fLyL/6qJ8scAkEc0kFitCbFCtTCSFPVrtQmE9wv/5nf7p656u16uEbuWTCaCVshzXcuy",
		"c+1gbaZX1ks/ug6w3pugqCERYMfQTAD6aARuAyq9MDkBDTvExN35u5bgRw/QT/hwi0Xrcvkf5f9HOS7/j2f+D//uX337+cR11O/bXUnfz7kDYdvDA7ex1+F6",
		"5BULRakk7wAA6h8YaN4SEdfX1lp9OuxGvRsD6fX5xMbGZtMQJhLyG5wf9nKhjrabHxKsUmkOgFIqlUwSUCwWsyxrY2Ojk//07s62bfss2yatgQgZc2KxneV1",
		"FbQP9M6G1QkA/f0DUsp6oaUuR19qUEBls62fG29tpX1+fxfMDh5H9mfyaJMGNkVp6cnh4eGmDXh4qM9xYpyx0Torws8+f/DKy+11SlOplG1bgFgsFDKZbCNu",
		"oSfSbP/AAJFWSqe3tvr6klopxvnGxtbxrjfHiUbCgXqpDUTGLVtJl3Qb3jwicssHBNIrmTsmbIXHQ2eklD4Reg6xd+auymW2ACDV16/KRW/1cerUKAC5ZfcY",
		"CWDP7hGmaB2yDCX5Aiz00isvRcLRViGu4eFhxrA102m6D2NO2LJ8QgjP8+rtWubm5rXWjLFkIlYViyEEJFJSyQag/uysJkol4w1pOEE47nv0xdoRRegzXZvR",
		"qb6+QCCw8Pix+U5zc3O16vLChQlzrxt0lBAVrbJkMqkBjHkY55xVCEJUkfNABIaASKSj0ej4Vrr88NGHb57nxfyJem8rJZlWpkOdbZooEgCC1tpxIj6fX+k9",
		"unWtB+84TtRxlJREdKCBuVG4TyWTXIg2ozMCxtnOzm47oa5mzp3l83d6l7aiowfKs9xyGYiyuVwiHvPblifRahQwOKY2LJdKKUUVnA8R45wDKqV1BfBOyJj5",
		"m9nImUAAUkoRERf27oz6Exf//PTdW+9+ODcyMsy4yOfzH3702fBg6nmI0QhAmoyshN/vJ4u7w6d8AT8AWJZAxnK9YfWfywSbCTE6Nor/yxgAXLt6rf5Pf/Rn",
		"/9j7770PiDs7u5m6rE1rRWQm9VDTgpmdnWvSFOLCsmyflB5jfLKOQ3VhcmJ2bt70MffCOmlEBoCTjWwrBCQiramG5yeCyesvHTlGMwD46MOPgqEQItYjeRKJ",
		"aCgUXFhYBYD+vrjt8ylFQnClNOeIyEIB/ztvX0VAk5TdvDlNAGPj40Y8oa+/XyvP57O5sIA0APT39VXuPYCvvX2ViG5M30kPDSLi4QL0QbPcUqns81udXwRz",
		"ue3RUad+00UEJeXw8DARaeUtL6+0ouVa3Gma24NE5PP7KmTR6sAQ6+C9bRVR0pnMYB1vYGSkjXz+6Ojo4uLiscBWmfClN9cAIJ3JBgL9WmvSGgAeLaycGhs6",
		"3nbi2TfPcMb9wYgmzRi37aDnFpWSyBgQ+fwhpaXnlhAQkdm+IAG5pQKAZszypNqVu5IkVmC1yBg/SoB+ynodiJp0MBQEY3rP+Td/8Ic9t3Tr1m3OeDQaYYxl",
		"9qscieC5pXJQBVNLTDXceQqINGILAwqwku1it6hBWhd2ty9duuQPhLSS9ffNxYsXyuXindt3TPASgm9uZi5/49XVLwpaU42hPjk5gSD6XtUKi34aINBVOTOK",
		"Rh0DNc1ls4eZzJlBP6BSSiv18cefKKXeeutNANCqzpRZawS9UmUBjI2NVqEQlXynwlWgvQzU77dBc0BGWl2bugyA9fwXAlBaX3/77d/5nd+5+fjx66dPHUuX",
		"fGhoqAOPXxQDfbNLn4EfO+UuJrBqrbXWtQ1ybnYOKuqegMBisdjpDh9kcHBQCAFAd+/eNafGlEHmvzUOy+zsbH2hVd+8dqLRoNh+/PhBMBzxXC8ejwq55OeF",
		"kgo2rauBgQGtFAF08pOtv7xEoKlRiIm01hgLk118mJf9DJTSOsg5RLz0tpVIxIiQMU6EsZgD+4DBN2Lx+OEKen8wqrUCIq2VZfstI7/JhVZSWH5L+LVWAEBa",
		"AYDPHzJ6bVIWEdmFyUlzse7fv6+kfH56HRcvTzBggtvVvhh5bgmRTU1NTU/fIq2CAX/meXffyuZ2u/BWDQG3sFts+tP58+dmZmaDfh8mEgdGLJl8gLPWCuSD",
		"D2a0VoBgWRZRZdQrldd2E1RQJpIrnxYJFADMzM4AQCQSNgqofp/P8+RBNQa1VoODg6m+PqxiLwiAc762umqywrHxQQAGyjNxZ2FhUQPGE4lwKFRHW0AAuDp1",
		"5cbN6crLihgQLCyuRB3HiUargLM23UYg9HZ366LP4NpaA/ptpA9LHtvKKgBIJthWWndpK3VSH0ZEYFAoF6FuGOM4USBC44knBADFnHBtklfZHasCcq3ahE3H",
		"6uqqE0sAadu2LEs0beeVFyQj/Uv1DdnaI7mwRHjw0vVTua1NWdwAvWNDcTRRLtivIhBDGBoaqoLniAtuSAwDAwNmwqS1XmuZgjCGiGhZovHka0QslDHk9EeF",
		"AOKAKL1s0AmG4uPayDEypglCoXAkEiXSyHh+e9e0SZv65kY8nWHDwLYXtIVSkrTGCjRTV8BBSiIiaVU7L9W9U7XVaHs+Z4Z1p3JvD5+aunLr1i1zCvr6Uq7r",
		"aXo+Z4YxJ5zN7SytrI8M9beLWZp1FCMHxpFzftAKXEnivKN4g8mkZufuDg0OJuJOPBY7dWp04+HnDBuyRAK18SkDsBmUq8n1OYNtmJub15oOClqPxpJONCg9",
		"r6Z5ffHihQ8+mAGocKAZ54BIrgQEBETOTAZdGTt3vQuHEhxI9fclubAA2kODGGNaesGA/fWvXeNCMMZcVzHG6sVLJQRsXlSych4Ea57NSuW1Tuea2kRa6/v3",
		"PxxY9/5I8gxp2d/fZwnBuKj1NLRWPp9fa2Xb/k5RYGJi4v69u7DPMDP94OHiS6dHx8ZG23ILCAgRPc9r2z5Op7cYH9jO72SzOwABgMDY+LgTgvJOBUEohGhj",
		"b177DcJYK66GCIACgUDTr995ZwpQGPi2eYWbN943Uh8GFnbh4uTMzKzh1hIQZ9TJE8jUc02AZQJqeyZJK4CKJwNWSFfYbrdtMTA+ydpdfMkUuyarwk7qJEQA",
		"oDwXAHxCkJSeUmZG1EZB69nOo3cAwARox4kh8mx2qw6ogJ2+oEEs9SauSk2cVyLq5BiEgOl0LpPJZrO5t69PMQTbFkSALSuHV6xRdVOidGFygguRy+Xv3/+w",
		"9/OQz25FQj6Dgp84fx4AlJQT58/Nzs4p0MmksWKypq5dRmTTt+5oOjDoQwiODIE66SQjguZChEJRk03aArTW4XAwEgkxxkql0sJyDmCPi0aETWQ/3kZrgdq2",
		"O1DrwnqhAAUAGBocUNo1S3li8jwCzs3flUptbmyOjIxofXiK1kunR51YgjreZMQYelIuLq+NDg/U/8kkDZsba59//uDll18CgKgTdcvlu4/XxsbGiOja1aku",
		"jNmbN28BAYBum5K1A/AhgFe/mKcuXzQllOu6xp2ufmQNAD6flUrGWpkUWsty0WsHkYJUMtYouguModaEjB06jCAyE7A/mJmh2r71zMZoYsB7F9gFQFV2B2xB",
		"jAkhOAEg01oZTuce4wGAVA9npTnPwqetd9IsD4948GkoAeDM7GzNIqut9DZDAETL8hERIKueiCopGAgA3n7nnVwmnc3m+/v7AsHQO1972xm0Gsi1oJc/zQKw",
		"Y6+ommlKCFpryxJCcCLFEE1oOJBno5SSc7Gyup5MJoPBoCboBDG/fOlioVgynhoEMDc3Z0ajRFDzzcBuYgu98BexVhzUf/e9L05UM9A7ejVtdDmgXSJZ4R4C",
		"NAXoWtIAACZAP3q8fGocLGEtLK2OjY9XNr3OZ+La1amjkQH22XGFYMvLm0srGyNHINQAQCweD/hASXlo7xNXlY2OMRGZS8a59XTEaDrYAxFAEzCGgtktuTR1",
		"0OjQfscBxyHSlj8ACFq16XC1PSp5AWKtsNVaE1N171XDqOHT1/MxHQlphG96r6oQGWcV94C783epmti2scvUEB+XVtAjBYRVnAao4o0dYfvqr6/PFwg7kZ2N",
		"UhEXYU+yHTW4GiIcBIE66XPIOSuWyuVyKRwOallmDIFUfQG2737LiZTn9idjwmftA+5GQMaM+wbWTdhs29ra3Lr/6GOAbDeBzzaC960Mroqo0BMAKy2vbsYT",
		"KWScMbp7917LvUacC0DcN9idGh8GgK2trbGRQXhquo5HDNBmWolo274g57zHXZ9VnFmIIR96ZfQXP/tZPw8qreAHCr/3T2Zf9738tPQ6kPe6ipry106NodZj",
		"amqKqEIuAILpW7cQcWx8vFwq7Tz6LJAcYKEIANy6c6ews8uFIE3Xrl2xbBsIUn19nDElJSJqKQHAtnyC101OEE2RQidsfHmIfS+9tr2zU0glU/6g/0DPNzjZ",
		"vr5+Eylqwb01yhOA57moEDQyjgCggQS3f/Q//xqI/t/4l7+gpYo60Xwu73mu3wqGhjaJLERGe3suHm9ojjjxNuuCyPS4ldKcadAe87aRYVMv0h/wUefGPQBI",
		"0jazlJSkCfhJ2SkSadZiZIXI5hpV1gwFEfbxg8djCdPDg6lMepOxpAGxNFFjiIAxqYl6DHYLS6tjI4PH9NGejsSIcW75wpGEmRMe5OKjJrX0yePvEj8EmgCx",
		"743Er+z+R3h6YrQQeKDYQ4fv9TREeq21z+/n42e4sNCyAODCxPlaazIcDu0J2pJWUgJCMZcTnKdiA40qDQSAi0tbyvNOjqdwuDza/XOZAmV+9Orf+k8/9zuH",
		"eJ2NjfVeHBOcWDCSFDt5WSx6nHNPFmLB13/ll3+L4C6QP5/PAEAqlbJs+5f+2e/+8b/wzUzpC86CVTQEatDzs3cB2GTN8hnq8SEfeJ5sDePYGSrLEQDaeOMh",
		"Ms9zc9nM4EASABgXNSvZRo2kbheFAZHWZ8YGEgPDkViiOzqq0qvvGc2bSqUq2AbGUEAymWSM1VAxnufVNJLqKwPZ8hlMzVSDghB1i9Vzc3OcN3/reDy+JwRK",
		"JARHRKW1UpIhSx8Q/+PEorlsPpFM2LZtTkYq1VeVJH3SwXRmZq525xEd4y1IQKS1xEYciGCgCDTtE7MJqOwVCMACq+AWbGHD0zMzfPL76NTUlYoLGhG3LK01",
		"KQVVv9Ra27GGkCEtpVcCQHd3lwBU+ylwJ2pq99KbH2NPo3ZYtg0Akbf9uz/AJTAGcOXClYIqHKy/lugTrAJ9lVJBpXULjLGa0KLWGgF/5n/+bWck+cbZ/jcm",
		"UsXdsoKC0uWrU9duTr8f8PtNPW/btgHSFoulTDbns5UquaSMfJq7r8kk6eaZsOzwc62/3NaXyJwxpYETvvvBx9UmdQ+7JiKQTiQTgnPOWbx/0PYHSLXXpSQg",
		"xpgsq53tbWTo9/ttn5+U6vYliQDA5/MRESJoTYJzyxK1j0NErush49nMlqkVAHA7l3ZijrBEMpmo7lsEhLbPJz1PK2UQ0BVFf00AONuEtENTdDcXs+FIxNSO",
		"1a9OBGBXRfV8Pn+h4OZyWz33AQgA0nVipwknogkg4Kcn2+6ottTBmB5UuH8nqQlPB3tqlQF0TKdFNCU0U1OXtVK2zzd985Ymdenyhae2MJmevrXndFA9Hw1y",
		"H1pTnXwakQKAs6++fLyFeS+mv9DNCnO7Q2kikqHYw755rZhUQOwwH9lnMcsyKC6sN/9GZCoWI2CIzBLAGEajTm5p69OSfuf61YL2CL1Hn6zZPGJm0wY1ZRJA",
		"RPzVf/l7W5ubjhOrN9Pq7+837pLYTqSQc96qlfHJwt7F+vgxb1G8q1xVrIqGa62RoSp7K59+klkM6noJBQTUKhhL+p3odn4n6kRu3JxuGlWZZRAKhcxniiYS",
		"pKjJuqUZzsiYz+djDBnjPTZetdZAdH5yon5Z1qa18/PzABgMDJnOr0FbtnZFiWhlaSEWTwaCQa0JkAnBHSdKpBFZ06SdCBjDQrHYJLpEWiulalA/rFPHZgw9",
		"z+s9QLc90rltAIjEYk8mR5uenq6WNdqUJouLi1Enns9lIk68c1nT5/f7WqAjxBhvx4GskAWaSjGDF8euZTQRIKCPBwA0AAtZ4WOL0VNTl1tmu09kX8RjCNDI",
		"GAKolccUjYlQFAB2trdrvY5IOFQL2UZm4iSQeZ2wzMeRLIAtA2VePgSmw4knAz4bQCupTDZau6Zzc3MAOhqN1ucJti/gxBwA+KV/+ntXr11HQptHDBvF3BVV",
		"xTQkomAwGBwfB4CoE62bano18iEBzM7M1eH8D5FTIGfs7t17JiE1shsmaDLbGnr1tf2qujYX+urUFQJAUAiEiCQlAXbCohgKOWfMSBoRaXMSeqcFNcRFIs4Z",
		"IpIms/sASMaq1FAEBLhy5UotmAohPv/0IwDy+3xSKs4YAnDOXLecTvdqiG7YLq3iopOTE/Pzd5umlCwioEE9lXTOA3jKaLaIrlv2XM9sTEvLlT7edi7TdS5g",
		"rl0TG7ktCFKTlp5bYsiEZfeuSGXozZK8Yn9RMAGEMxs3rePqdVhNHwVBKz08PHj8p7gpXyEAfph5w/T0rRo8o1QsVfqtW1nYygLAp58/kJ5n6r7XX3ul/omj",
		"Y6P7dR6BHVzns8cAXc996H0PI+x1hjk3O9eQXmlpiYCJQk1ywRcuTBKRzx8wyQgi3pqeprrAppRXfTxOXb1av3kjwK1bt2oFSpP4MiIqpRFhbnaeAHgNEYGI",
		"qA4ozQ75bVNhcMvmtmVt7xQRNAAwJqLt8qZ89UbN57LRaIQAbkzfAoCrU5eJYPrW7RrpeS9wUgXgNXXlUruVdsck701zC8OcLJfLUd9Oj94GisAnmGWJr719",
		"tQpu1ERN7Hi1xwhyvZdfe4Okp9wiQ7h2ZZIIpu/MAkAoHD1i6VYRFKhb6iwi9EoWXA9qoteIEIvB0+ZZhGx9fePBo6WXTo30qMiqtAbE8y0GPW3hlgxReu5O",
		"bpMLK5YYIuoZpITEkSdfGf4b/+kvhW2HPB1M2WErejwxemhooIXkvnoSe6D0GkZAmggssnjTBBG7J851UDmSSrUOxF7toI7YIxcIKy4+y+aKEsFIh+1qaXkV",
		"ERBwaGhgdGyswWKu3cE4cxznw48+O4wmOvX0EKqDdRGAJt20NFsJhOac1AJxp4uHjEnPLZfLiHju7FuBULiDmwmZXRA5ZwiF3WImk47GEkCQz6UPIhEZz9Vl",
		"Rk4s6XmFfC7b89MdREQuDFhi+tYdk0+2wvJqDOhbd2YaERRopvxYIUYTNBYElVqzt7Ta5LIGw6elqtsOsctTZLmIBm5UEZAwoCNCdizTI2xQ4BQcpYSyyz79",
		"HIj0668BQxbmaudptDQyARp6Mm/sqNeBHTwHEAXjgh18yEQAHMVgcDRmxzwprQAWsPCM8Qyx8cQwRKXU7m6BALhA0+5jyCzh61IWI1ZqnsXFJThJDevhoX0q",
		"ifrY3RNijwAP6/CLCJ70rIAvAqwt+Jc0Wba9nd/JZtO1m/wk+KnYeaszwYtbFkNkyJBVZEXz2QM7HuUaS9dctqFtalqQ/f1Jn82rMkmoiJaXN6pPzxmptqGh",
		"QSBAhq7rSUUAuklZHwBi8US9r6QBQiATWnmmoVzfcx8eHl5ZWa6bGQSJ3Lb3ewXJTgBArvS0JqUlK0Ew4GedZDuaGqb1Pi4AAHRt6tKN6TtHH6VgBQqNDW6q",
		"SqvbM2DbQMS1AkBVLNlg1fee4Fk7hof6DnSyuBlCdnIh6XrcnL75g6/8yIa3fu7Dqx++ficrt9M7OlBKDw0nnnG9DkSkGmmCuscpqWhleSmoXNIElg+eOd8n",
		"gMMZC2mgMEbScssll7UD9BJprZSweHOf7JiuEREJYXFhYQ8Vk+d5RJoUDA71FYsaEbXy8vlcPJ5gjG1t7WlBvDyissX4Vjrv1PUucrl9FGjzuUzUia+vd5x3",
		"ffHg4ZmXTgOA67qMMUasJkDx4Ucfcy4AyOfznxofBQBjlvjw0WNhWVrp8bHuORpGnUT3moAxJML5+Yq8HGPoui4RvP76q0pRwO/78uUKKq7NfGRkhGp+6M7g",
		"xb/w56t9GPhgbq72OatudRQKBGsCGmZOYLaxJ/yFllY3RwZPxKJFSQk237cp3tZcjQACLPC12DUN+oIzoX3e7gWWebx99GJZPFNRTqf6+gAZAEWqiVtbZ40n",
		"umKW19qK57YFDD1eXBkfHTooYtMme559EHUd8IDQbafQBkopv2339/evr69DDWR3csTHDjQtAiiXi0aaElFEQoyAGPMHAn5PqiZAgo9VzAb3jcttwnTUaSpZ",
		"EcCkzyZAA0C9K7Y5IpGolJ7neVLKTz/9nHGmteac155SzZdHisViW3uBfZs2ruvVFEeJyPOUMcmybZtOWHzn4GIMCmpmoRyCIVaHKK1SIrlYeLwIAE4s1jBn",
		"BpMs9AAbPu7DpjK4RbADvczzY/F4j59ucSV7Np5spNdBZfRV6WwhMk6kAVkNlV0nGQi//M9/MbOCfSl6/B+yg2dOrxU/ssEPz6HuHWBFBxCBITOif7U/2pZo",
		"Ndw8jJFpbWFR1X3j4MfK6trQ4MDZs2/0As+0hKW0OmiABkAFKgHJ/5X/j3/jjf8+ei9eYgXWVvwIQVOdvFznPHp2dhYIuBDVGgaA6MrUVE3p6xBsNyLiXBRL",
		"JSldxvmFixXOdIPuHTWDOzQdBt8TiyezmS3LEsFQEBqnOlEnXAFWkm5WAkUOQAP9/UprpUkpCUSm28uF4Jx7nspWxS2VViZA9/X1Gw0j020n0n19fVprRLa5",
		"uQFtFD6pljT09w94npfJpAcG+hmySDjk89layidGnjbgxbaWgxcmJ12pbCbDQYtqxi5yD8hx/dJZAHj/1lztitc8wKCRsBMIBK5cufzE4kPciajtYC8B2szz",
		"OUOCjgoKy6vpwT7/YIorCcmwCAY8V/lMi4pzQaiIQGvFGGPIiMio/htZE844GaV7AFaB6+0lM18Ulj5d+Pib6eGsj0EyeRSg29MVo+/cnkHkWHUvIq2QCwP+",
		"QsSLFy94nlejr87Mzh0ULQAAWinLtkXQV9HEYaillOXyISpQE3IikUgvdx1jjA6b2WrQCejzQYBatQJhT53y7vzd3jYbBKSasLrBfAhuEYEm2SouSaQJiCEj",
		"koiiXZg2CvoSERiyuk+ITbp3x5JvaSUrltKkpi6/aQQTbk7PN9eLVNtUmK7caWj7/QBw/fr12qPef/99qKj+QyQcKBbLmkhw0T8wQEQ+29Ja1KpbI+dUxXzu",
		"fc09CEHDDqRNlUAEhEBakykvnhyzmXHO7927D52EpRh87dpk9+Fll9dfXl6Kx+Odav8TOjK57UebuTOReO85Xw1oT/VsIqoAn4M+HIixYhk4omSqrJAhElFh",
		"O6NJcW4FgpFicUdLT5Mu7uYSfWPl0o5bLvp8IWMFAKQLu1kp3XoB3qCwQ/7Qrm1LgeL58TMkYoxl87tImgkulNZbyyo1Yglu2xZpUkrVoxTwoChrIiDyhcI7",
		"6U3vkyV/KEREsuzKcDg+NCw97wg6LHhwIdYDdspAEuiDNknm5uY7bRjLS5WhazwWRWSpMR+z1ObOQ4v7oSZ9R6jJZZz/wa88QOA/9Gev7LpLDH1kyFTIXLk7",
		"FL20/Hmm4Gb9Q2vegzjHQO+ySoiYzlQadm+MqY8WeF1GnIyE/bo9r4/y+RyRrki1MiwU2JtnLzAGSmM4qEXDbkjA/GUXSiUXEfyBgGXZWuvd7bxUMhAMX716",
		"FQBu3rhhAqllid1C0UjW6cpBDTQQopnZufovWLv6ihTUTQs2G7pwpo/5RLUtdra3GysXMqWSJhKc27bPsLoOfQwPjzz51k0sFmtqTO27xjg3QPu9D8s5r9a+",
		"pKuSqVRVULz74edQBe8wXueVZbQoPl0wl5FII2M+X5AA3NJurXZd30gDAGdMae2lHPE09DrwuBjh1efXcMR9XKSzGQAYHR2RWh0LwTPoOOWFR7/2D/+n5Og4",
		"ab2T3jr3PT/Qd+rPemUXj4U3ekKknYN3jxnjHd6XGrY6RCLaKW4Oht9wPyv4RnNKK2NaaFnAIeV5pe38rmVZTiSeXckEAoLIJWJEYPHQxs59MagcEhpCR+E+",
		"8Y7nq7mfoDXF44mK7sueHnszeZSAG6RaseR5HhkwVblYLBeL5imWZZVLRQTiQpx96w1AnL97r1As5nPZQMC/sb5uHPm0lg2RqHKrt0XXshr8o54DaZouphPy",
		"JBdBJtOtyz82Nio99UzZGSGQDgYDPp/ddKkRWblcbvt9XdelKrrf5LlVugACwNhw0pVw70GlHxmL8WAAtIb67qX0iogV3nmz7gtUHME554YcACegd3wMMVp6",
		"pncOXCCdgPZbLJ46PhYNKK3yWseHhp2+ftJaWHYw6tBz5+qSy2VzvQGKDWajnI48WF8iMtQ7I8nJ19fTd//gi53dTC637TixWzO/f/e97WvfPxmNlbUWiChV",
		"OR489e9/6dt/4s//wGbhQ0T70Bs1td6PAARwoVE/emZm1rIsz1P1UvdEoDWSmVlWX0iRn6EHGi3BEKRUijTZPp/RonPLRa20z/ZZtq2V1gScoVYqGolEo1HS",
		"2sgie5530FTRcWKcs0ZSIh3XFm2EdR0nxjhnCFUWUgvHoNp7QGRmhtyes97oh/KUGzhfvTo1PT1dAZtjk340L5XK7W+EfL4dbnp9uB31LJvNM8Y1UTazdcRP",
		"q7WWWh6LoLo4ltBHBMiAH/dVoapL8TGUSIlUjSNMRMrzlJSktZKeVgq+ygeiUirSL0UAsrubRH6GQuqyYPAffu7O2Ph4Jr1tgv63fi2bGhj4zm/O/MR/8zVk",
		"HIB5cvtXf+Zdzuxf/Ze/+7U/MXCMHyqf3YqGRtq13c+HQsHF5XWl3JfPDGqvDAQ+m2xLAwgi5Mw1TUhWgZkQQ+YPBD2ld/LZAA8LSwBAuVRSWvkEZ4wXi0Uj",
		"OVQRFjf65lLSAVFlBsWWy2UjkTABXJiYqMHU1DElAUZp2uy+iUTc7w8qJTvHf+oyVHddaVkVBLdivrZflZA/VeYX165ddV23VCozxmpDoJnZWQCezWaWVzd7",
		"dOAe7swNTqcz2yy5U44O+fJH+aiWEBZ/anTvDDOjznTm2I5NsA088+gvrU9AGBqf7kLRicU7DTORoVba9JRMeMrtrNpcCyYIlacKseBo0BeLOveaZHq8spvL",
		"Zv6f//2vMqGIAJBIilg8+l/99R9b2PzomBEL2L6HI6WMRsLBIAPtMkQgsDgBEhESCbXXZJBSEgAIobRXAgC/zyLtSk8CkOAgRMC0g5TnCdvmDK9cvsSFZUrj",
		"UqmEZlHvF6f3XFkZB6BYpQ8DdTq6J5KUEpHW6uzZs52opLOzc9hBSyAaC/n9PumVKoRKctt+OCR9vN46x9XHwwaPM6ypY0OviKyNocG+DmVQZDsP0BguRkdH",
		"GwS86nqG+Z1SKGAxxmraSpX/K8P3jH2znWzTlxGja4Ql2te4iQ5TTWXTm+HRkWMyXjrfY0A3hPguXPDl5VVNR437UScZCoqVlbUTCNCxaDSslcJ2YHvG0HU9",
		"E6OJCAiRg48lUPmAgFPp1//lewyF4zRLQ+Sq9l1xpybATZyzf/3//b3JiQmGSFVzFuMyV0Mjed7xCPTMzs4JwQuFEoEOhwNXL7/FGAAZBGu9BEaFP1JFVZhJ",
		"PhFog5CybQuZIE1KeqFwyNDib9y4WbfzGugenT9/vrnSalzKtfYKRwagSLf4ISMgISIyhlrRUXsdpAcHBytoS03dpXE76c/ks7shfwSQdRSgek6PaCyRz6Y7",
		"BWgAyOW245EBv49DqSLGEoknSWutCZFaahrKZ7eC/kFTsbUhuxxLHt0cIHDPqO14xaM7YYixh6nbExsfm+8yOjLcw1B78OijQERknMOJ0NmFcU2emGgjwVxj",
		"wVV0hxEEC658XOSKEWoEdv7c+dnZOQAaHR2pWCQjKxaKm5sbADA2Pqglhz10NVDzkjShEjmvKBBprbWWRw7QszVZOE96ZjCota9mZsqAgAmzcyDwYrEEgOGQ",
		"D5jgKBBdYVl1UnQaeR3YgpQBwCqlsUrmZox98MGMMWNtTuSqYI26v1DtvxMT5/dw60prIleiBhKHUO3q6M90+NQ8u7za58SscOD96blrl89/FaLz0NCQEFxr",
		"HQ2PYn0LH1lTItIXUpJZREO1xr4mjdhsrWlUvB0nVlUTbB6cHNcnF57ntiKIl5dXR4+cujbt/12IxHSMU5V9bvL5t7/xDhzMJLQHY9cjthh7BvkRaA17mvRz",
		"sw2gYF7H4tNKAvgmJiY6FMLEOR8ZGalV6vlFH5LU6NbRehDAOANALc6aJ//Yn/6eX/tXvw9Ik2YDaN5BCYH/2J/9uqt3//lP/3sAiMaS+exWMpmig8PPK3Yk",
		"oHXFqwCU0uvra7GYAwQIGtGtzT6NZEA16nLGsZLxkmasYptQx1xiTXLVyNAtuGYfAoB4POH3+4CIc97kk2LA5YyBq9CrXhC5d2Vobm5+YmICEBhgobCrNAGQ",
		"UnposE8YW5aDLycCuHrlEiLultwKD7u3htGjhZVTYw3kqR2lJTK7cudpoH0SsOXlpeHhkRaG7VIikejQlz+RfuCNGze11ko1tB2oNy1lpRVIs6h0k5B00yOl",
		"IkmElTkqIgIwNtlqN4EAhK/98OjCH2yeaNQS09O367/w1auXD0u7O2q6PXNnrmPhRgBATfYTdNjPkfAH4Cnyl8UuE6hqmYEA4AsEZmbnLk5eqK17DgKA0MKq",
		"icGB9pgaFMkQLrwm9Fr9oiSiu3fvQh28FNA8oNMpRA+2y1U/1rwRRcIDXDQnlmKca6Xn5+9OTp7XOmBZFeuNhYXFBw8ff+2dawAakbAi6UmE3MRwc/cowoBf",
		"GHfjlgWN7Z3YAAEgFk9FIkFTrJoMK+ok8+3k8DkUlzb2NEU306qGeiSCe/fuVpiiShHRhQsTjOH+Pl6IvbA8e4l9CKC1isViNSGqaoctNgqQyabD4REAIu6n",
		"jmxxjoSxeKwy3mgp5LVWQDQ9favCUSUAhGvXr9W2mhvv36hLRWhqaqrzFyTqOuy5eXPaXCYhWLN8VQ9EX4aICJMTE/UpxezsbFufdmb0phFrW+bs7GxTpnx+",
		"4nxQhG4U/+DcxEWL2UQnZYUqmsLd9PTtcqmUSPb95F/7q65X+tL9sOvkHTnuMZqoJu7W48vmMlvR8Bgg5tfW7IGBgdMv72S2eCBEXz7AiDrVswxRg1TgSeQE",
		"9OHi7NhfGV4Ty8zkhhpG3u4LbMa+9dO/d9C3bFptJ5L6E2dkHbriyGU3ERN+n10ulVxPT57dfu9GTmkCKY06ipSSC3Hj5t3r16pdBVOLsQoKuZExQp0sKBHR",
		"LZfNhqiVsm3LNto6AICQSCSIKHMQJFY2m+VcaDJJNWrSfp+PMfT7bNsWWqruS8HzVFeFWxSMH0DgRulQKBSJhIkgGgnV3qd10tDZ6EBHIpFIJNKmtxsJV7d5",
		"Vtcp1eXdAiLS3vU2c0kAYLdu3zar59q1q61TEmzej/ZWTAVjg6xcKq6vb9RvOVXXseOqV4GUEivLXizm+YPbma14ImX7eaed1c/8J40deJp4hgCArK2U5cJ+",
		"6swHSFgRAGA7MShDMU/4IDGwrNiZykgJWA8CjKvLjwaHTx2cmtK2OCXsoAdcKpY3dzLB3xgM/gYAQARG8BL89PhPRYWjQSOgDZYLhcHsGyv3ci4UAeDc2bee",
		"zJUSohvSZnZ2DoD9kbOXPY9aFasbUxvqMq7IZtIDA4NK63v37q8vPHq4aAtfgvusqpYNM3o+2zs17ogCqDH9EKBkKC9+nwbyN8Xl+nhdLBXNHXzu3LlaeJib",
		"nQMAv9/HhVCEB1JYrdf2A4D+/j7GmFaSJNNt4B57H0trXXS9tpkmAigCv8WFzXvfiWdnZ5VSLeBSQkZBVwJoIM1Ux1Ts+qU33r/zISkPq0ni1UtnAeDmnXsA",
		"oIBzYdXH+lgsHgr6d/NZM2Uxgi2lUnFraysaS3IGQnC/z9aamnpHt27dbmREGmMIMEogRHD79m2tdaG4m81kHi0sn2r8nNsH1OTqniJpwM14PxVyUCwCQCa9",
		"GRwZ7hTiy9o98dsNvjqHKbe0BgKtFAAqt6xcV0sluMU5B8ResNL1ARoApFK8p9QGpfRassWtTkSTWle0dqx/kX2TJhwdV6i0q3aXSlp4qexwJlgmKRnyJ3Yi",
		"//XP/gdm6CrYcTdMb5XsIDadqCYk2K7H635us1e5nheNRDypSHFh2a+88sbiwuea9ODg4Orq6tj4ECLMzM5dvDDR9haanZ1BBlxwoAbaQ/1VZpxLzwOgCxcm",
		"94AoAJMXJs3kB5U6hAR2SxcFEBlyxjVVugKtPixECMA7tRoRUBEXAjkesWCanZ0FovDIkPGh6eazTHTtygUAQO3Vn8DrU5MA9O50RQlkcWl1dGRwYWElGnUQ",
		"kQmrEqO1BgBj2pOvioCPjo4oJYvFUv02qZRWUpbLZcPKMTaSAGAeZnj5nidnZu6ePjVyamz4eCGMyZRjwD9Xvv76ne98qhVRIbdvLJ+bm+fIU9+Iz0/PI7Rp",
		"WB8XEvWrEqNjiVTFtjkUkSTtSKiwmYZkf8LPLZ9/a2vNc0tEJOw2sPO+/gG/39d+LoK48Pjx0FD7RROPJ8KRsEkKlFIb620wdolkKl2XdsViCQJgiK31NQK+",
		"+rOXEBEYSFcuPFoTwirxkuZSlzWwJ9ddLxVlJOzTRG0zPiLgAn/5n/1Oa17c9JuHK3s/P1hu81KZ9BaQzmQyiTNUP4lXSjrxvmJZMwDOsP3AmQgZelKWyp7P",
		"toEIzbSDyPPcmrBkzSuus5k4Hhmbr4QQZU9Krc3GRloLYXNhGbGwBj1M8Dq5h1mWWN9MR8JBo8HWVMmZ3L/VHKY1TE9OTgIRtywLXYsdwyRldGQQAMbGhjhn",
		"BMh9AYNe0cY4BtvKPdVtmRo4YwUp6zmBo6OjUsqKdlVlQstOnxqB42+uwtZmJSL/1q9Ot9NZTJipZO2cV6pIAkL9+Lc2/X4fYJvBJZFu8mX+6sboLx48KpdK",
		"wEFrOvvGG905LJbfV94p+R2HC8t2YkRaExUKeSk9gvbDB60UaaO918Y32omnOo79qgdSR0GlQMDf2M1Md3X5U4gMCTVo4VOVaVVHEQiam5vvMoGarIPlEfQg",
		"TdpszHBkPCb05IkDAIhSa/n5Zx/5fZaJprnMBgDEEn2hgKh53bbNPtNbzbtdPJE0WGpNuLGxPDg4gMiOE9HaLpgppY2ew927dw3/vg3sssI+bxNYNdH8zGyh",
		"UPD5bG4M2Jvb68g4Q0RNdZ4y0HHnUZ5n2XDs7cpqicD2JK3a3VNEzbCu+lMficUrOAE6bsOKrntwSdlA4BduU24RCY8C6Lt371bcJomZlck5y2YzQ0NDjGHl",
		"r/XzJMafijwaAZQiLQEZCAu/lOnbmZdO9aJouRc3pdKAVtSpWdAyJhjXnaKLaS9Go47jRIn01NQU1MzkEbt0pLPZTDab2RdR1zP2jpaXl3vn4xl0AXbcP2Bu",
		"/m6rC8HkxGTrSWjKEaiKlux08xzjMjCba1k5yIUlBDJkwGoqoEpJRLvLOLJtFpxJbz15uSus2wMZY+VyyZMSETnjRsbagP8sIbqcP61VqVQSXFTDcMUtERG1",
		"1ppISVVL3AYGBjjvuPc0YIQ7viP1aBs4PNS3tLwWdZzauTRg9poGVSyWaMg/GoJ081razmaccGivP3l8bY2Z2bkua3soVkKEdL55UykUS1Dncd8fBwBYy1Qm",
		"oeWyi82aKebKyKMn0ceWRyMCPt1cpXw+5ziR2i05PtYvuGjQ7KN9btd8PufEHGoUokGAXGYj4NvfRt2JJ3Pt4AHHoEbS7hW6bw9OLOmzRR1aCAlIcM4Yzs7N",
		"Ybs7lbE9K0WGDBHn5+9iZ6rucR3hcDgQDJS1CIZoabF5dMz3OLgnBoI8bgQPEXDONjfbY0VGRoY7cRGN+Ecumzv2z6WBt9dNRQJk2AVVRgRVB7iR4QGzQuoV",
		"cS1LmJFlo9OmmpufbxBF4rx+0fT39xvJ31qpYW4TJ5bIHXY2wDnnnFNj1Un1oBSAsJ1lDNLQDPre2mwYAttqDQC3sv1ViY8teJpnhgTAeEX5nZ5q8YpYPYAR",
		"ARHbUglO6kZlSFHHyedyxx5DlFIHDYpNLq61oXwg4O8ibFLjOGsipfRJSKBAO0jPvhaCJz1pPuIHaL06RBSNOjUN3uMn9R7wNRUPQNWAvLV1LNROdyG+h4+W",
		"T58afvBw8eLFpFmmQgijsbywsBCLN7iQeJ6nGyXXqw3Bhs5A2XUBIZffRgClFTLOGWD58CCK9jVo43HzQ5sAhvv3edidT8MAMNj3hFagOD7EBDzdmA78cjkr",
		"pIlz60RYQMf0tbLZTDbbY4jPHEcN17t7YfpEk19DZawZ07SxFDiBHYJ1WgwEVOUZN118ztkhvu7s7Bxg+87xtSvnTZy11E4nbVJiNgCr8XSazpuSMh6Pmwz3",
		"pdNgCWacpeq1hLKZLcdJ5KrncHV1df8GF5HW+uVXXnFd1wCiGKImymYz8XgykzmpvHWoP9zLwwb7Qk8ydHwlcB2cdoJCAISe/FsPG761Ji7E4tFQ3shwcHDQ",
		"qOe65fLm5iZ85Q+tK4PcSvezsZjbl9RX6w4zxppmPnWTH1YfYo5+nD9/9v79DzteZc5YOwUbImCMMyYODPtjLZ6wBMDQgFDr0mHskHxhl72NiILBQDgcIoJo",
		"JGiqK95CMjjo2cPKQMWMi/Hzzx4Gg0HO+dDw8EoP6fBzdnwlYrTgaFtcPfH3jcWTnHMgOBZpbUSwbKtWSz7h74JckmrzptpXZOXAl3VlOSOTBVeTU1bfV+0x",
		"RpddtxNB2WB1c0+w07K4sNhdGMg3MNAKZFtdWWl98NpaRz3FYiZ3+pUzt2fvgVbXr0x0qYlrURpb6KIXLkzOzMzpKl4FYM9k/BjZt0auy/O8YrGE7KvE5/hK",
		"xeiyDj1eLY+OdWkT4nGur7oqL5vZijnhbG4nkUwaQ+sj5Iy08Hjh5M4SMQ+11ZkgK9qGYyYteNKjhWQ0GtRKGd+sWnMTEZeWDpNktYLz4MvTANhX8Q6BNRJf",
		"SAgec5zsQUYdlsVJVZxi3r811xCY66By16+cv3FrFrBq5LHn/QUAdG7iwqTxMYAT0Xur3yZrUrovYvRzeySTqQaUG4JWUhvlFAAGqKR7Qu7G2dwOgBGo1E/z",
		"KeoSoAFgNTOY7FtgTIIWOXetzjXci/lGnuTnzGW3wiGfET9rdBZ8VmSQseZufoiARUT1wPaZ2TkiyB5wFi3C4fVsZiQUIEIuRL2Qv/Tc2vRmt6h+6E/9qV//",
		"xV9CIM54xWvVSO49qZNdkQp7uu+d5y1GI+ChMSD1qWgimfT7fL1J9RDRXu8SAEnpoBPnXNTw/5rU+tajTlzwpZWNkaG+I35thuKpScja5WiW1u0I2dwi5aFl",
		"sWAwoIue0jDe90rj8IkxxjVgPbgwnkhRq00wQjaTgaMaIyRMx9Kwt0/UyAZbx+EEiLgv7L1r7xuJKBQKhkJBztni4hI08GsSpKm+s4CImXqKZovg+qGRjjs7",
		"ZUJAKOVahsW0vEoId//FL/CJs0zr8GB/IplCIE2USacdJ8YFl1IJIU7YC5SMnWsNe0cEXyLIB9rDJUdqGuSIbHFxcXl1Y/j4YB/iSdZ2yFC6nlcsB5wIVXPY",
		"xiyozfUeHR2tKKoTAFAkPGpQ+VrX4F+9rpKL1bs6FODBcMznCyq15/rM2KJWenR0BBlr6iqMDPXFEwloNLgzP0djyV6kETvFpi6wueGRkd3d3dx+YAsu2oiA",
		"dzk+/exzIpIVixaqP/1dshVNn6wtaCIdjkS/Pv6OVmrqypVbt24ZbDVjWC6XAGBoaKjOerwZcssQjx6jEZ7QZCESDraLP8QYZwzT6fQhYE+Ie/L8rS/uRKOh",
		"ULCJ1sQYq4vRuC/D6CDGxFsm/0DEJqMpIYRC6Pf7NABDyG9lIZUCAoaYTCbNLWcA8ofyVuqp1CBAhqxYLMoqujSXfbqicyWBW1pqvnOPFZcnnrxOcjeBc6JW",
		"hnuTRFbD6+EBZDbrg+FOwQs6UkpX63o3KQIEz5NCNMz4Un19gUCgWnDhE/OIUUohs/ZFOBq/FdsWnRPPeD6Xqck5vvrKy50e2VayHQDS6XR2NxwL7VTLYY+I",
		"CsXCW1Wlvbm5ec7F2PiY9GSlLlGaAOpdYObm5giPxfI8F46ET+KkN609pTQRNRnZzM3NAVV0gg7l6g1Q1dBobd1GYzHPLSPg+Wqfd2527njz1HgiYVuW2YyV",
		"JmyUlm5AABJKAI3AqL0rIgJwIVoEEgiPxoGOOg6RAtKky4QsHgstLzFJBACxmIMoTg5796Ufl86/8XT0ozvqwqNWOhQKRiKh+p1YaXV0yeNOfDhjA2Xun8mJ",
		"CS74zMwcIgwMDJjdm4gsIaplOwLA9PSteuZnly0nnkiGw6Ea5/ugBpSIqJVbr9A2OjZqaFFSyhoI6cxLpx48fLS7W+iibh514ryHZD8YDBLR5cuXqkqqePv2",
		"ba2pr69vYACIAgxZoVyAOmhUffQhbSzi218s7OqKplmI6d12DYdmalksFj8JwlQqleKcN/V1jQkhNBiTT9y7dxfwMPRCImq5CNi03QLgZK2H04nKT0fq79q2",
		"JaVCRAuBCAJB3iZGU8Ukkj7+DF49Y+Se6pc6AUitV47DU7V2jI2Pg5Y19aKhwX7zk21btm2FwyNEtLOde55lOb/0Xkf3lX3p8uSd27OktNInRv3DBnOu5kUJ",
		"wLDSLrRt28aGSY2R6ZievlXR2DBh2pSl1BG9q7UmIqwj6cGhvMzHxsfBNCJIA4DgbGx8rMZmHR4e7kKjatJpaps3mT6vUgqI3HJZafL7bAP1QzQuXKZgoEgo",
		"yhg2FTeTExMIOhCK7O7uHqiwSMX5ZkYBwGC8tL6190nyubQTSwHopgDd19dXMe3GZmgdkR4bG21eLnUfpknVPh5PGG2omhhm7dUSiUQ6nZZKWkfGOMZjUUNY",
		"F4JzzlUdKhkRtFbJZHKrCixBbGgMmlKRiEaGB81600RN1hZNY9Me1xURTU6cJ4DZ2TnydCsxxMe5QoC3XgdATrosLMu26083ER0/AJSIjF8KwrVr1+rNOWsZ",
		"eja3e/hrEXdIU7bR6h4A4jFHQ+Wk4lEa/FUxTK0VILcsGwHW13tylB4dGngqeh1ExC0RsMJEuu26unhpUnnUKi93XDuE1qCUDEVSuexmNdC2WMZNTWlju0ut",
		"twEhout69cjT0dHRTlEpl83UjLT7+voTyWQTzMuJJTstiKGh4WIhn8/tAMDQ8JBWynygy5cv3b59p3XnSaVSvbBajLSN48RzjWFa+1Q+lw6HhggAWUXwGAGn",
		"pi4zZIzzirM2IimlCYqFQtNHmJmZ58KS0qs/Yd2rn4RjpcKltVyU692BSHl9S9Tw7EbulUiLZMrYivt8tm3bRhYOAM5PTASDASC4cXPaJPVSKq1Vpa1ecYzl",
		"+fx2rnpPDg4NCG7VqpmKbGz1ApOSyNjI6JixAx8ZGTax7Kir3sAhgDjntm3X6yYDoNY6GAp5EvK5rdHRESVVbTlUqjxjSQVVA2+kVrfvVjeihcUVZA3zTq31",
		"+NhIVT2fAWiz5yICEYQjwUxm68HDBcsSmoATBbWs5SEkZYkLux0EGwAeLyxxXrMpQaNTetBjeXV9eLAfEIH01akrBFDvUDw1dRkAbt68ZTr1Dx8tWpY4kNqS",
		"VPrqpfPrm+lUMgYADx8tWTbXHsy7H1yefDOhJ20bNzYzxxjt+vuStej88NGCZVnd15In5Vde4x+BNNk+K5fZ3NzJUQVUS91cgnD/vvYB+tEHxCsxzjiJzFsP",
		"X169wJApJRFwYnKiXHaNXQhVw/Ps7Bwi2LbdG+E7DQC5ljyalXk7jxjQigrlAiKCJn/Ab74rY4wLoaQ052J2ZpYqfnEoLNs07itFQM0stp2bvdagVCXASMXq",
		"ulsaGZI2YsjEOVeKGbKG+ZrXr19rkup3PSk4K5ZcQ2mxLUspvbG++uDRIgKcPjX66PHSJ589uHb1ciwWy5oxLBERXbt+XW+vaoIb859z8Bgox89y0rdXxxAd",
		"BT+RTmf6+vo450aBuD71mJycmJmZ1UqFQ/5QcEip5sSFCC5cuNDY3cA2NBNNpizgggHh5uZGqVTkFToP1BSFHj5eVFK9fAYie6ZZMDk5OTMzS+ZMIkiliLQC",
		"KAECIJHmnL/08nhV3261/jWHhwYePV7UWqsagIfgiwePDkGgVQ21M2KzzlkluyWivv7+haXlQqFQbbVR926meaKUChkuLa8CwOBAfypVGZBepHOaiDEUQhhS",
		"e+YIM+1HiwukFQG8NH5aa72yujY0OPB4YcnzPFXNsbqwHzp9h68Wb4cxVMrzpMuRHbKliWDWUyrVp5SqFKQEyWSqySHpOGChAFHSK9os0wsX2+ekFy9OzszM",
		"dgeQDg0OrvSgk9C+MaQJGWggk9ndvHmLgFzXtYQgosnJScY5Inie1J5XU2MYGhwEhJkPZmvMYM5bRKwaSERUF1BYqVjiQtS7IgwODgLRlSuXEUEpWWdLSoBs",
		"Y3091ddXK1NSfX0ltyIlAQCfffHwlTOnU6mUZVvFolufqd54/30kF5BjpYfAcso2UeLChQu1uDzzwUwDGqy3M9jX329sxdEY/bleU2v+0uVLc7NzjDOtUUmJ",
		"iG38p7v2+xDRXPq5+ftccCIaGep/9ZUz0HEu6rRL6AgAXjo11rFNDEBEAwMDrM7UvKND9DElVTUPtEpZS4DI3HJpbOTAPixLKxta6ZHhQRMEfMJXmbsgIeKt",
		"6TuG1M4Y48Iq2DIVCyjV0HwXnNLb6GjGOs91xsbHTMEupeuV3atXp8xQKnM0YbyvUoxG8DwVCDrFwo7Sih2cV2q8O1zXgzovK865bVnHG6DrxLnx9Etjp0Ze",
		"LpWL+5XduI9xfbXXYcSDcp0t4GZm5oCIccYYu3TpkollbE99CJTUblnalq21mp2dNX3JtbW1oaHBpc8/Hnn59aGh4VKpFAgGOOL29k6ldww8FPT1DNNkiBB1",
		"Yvkq0IKqOVHbciQaS25u7LmLbW5sOPE4Y2xhafmdt6878SRDvbm5OTY+ns1UavbsyhIgxgaHlfRv7+wEfEJLzrm1vLSYjCc0wswHM3VgpIaUp8cWiEFQUFWt",
		"npQCRCKyLYtxzoQNAFevXVfK9VxXKc0YHrq5MjY62G5qnaoAd7UyebFt23VEgVpbHBLJhJSqiy6jktKTHmmDqgSllM9nn9ytqrR2XY8hEpHPZ1cuOmIul19e",
		"3WxCCnY6olGHca6VdGIJLoTjOEJwAiStJiYmXLeyW0+cPweIBmbjet7v3fj9kf6oV+cOTAAWp7U0/vDlty2Lt5PfQtOgRyPhS8bqQCMiERp97e4fdXGlY9ta",
		"XL16pRXLZfv80zdvaVKXLl94noK0ksqy/YgMQZcKeSuaIoC624L2x04R+fy+BE8iM/8ibAeQPLZhQJ5E6wABAABJREFUPMHDB4sba9kj+skigONEc7l8dh+E",
		"aVX7udpRZoyFQ4HGOIVElMtlaiVznS8f2j4fALhumXPiHN2yW49mC4VGD0SpswQHgGi8L7D4CKUEITq7FlBbTh5nHAiikdDC48dfPHxsUkJzrC88YsLSWkfi",
		"Q9u59OyDh9cuXt149Elxd3d5a7064zae1kwwRH8Qff4Dbupaa9rj2lQ5656UFpHppTBkhZ00afIFHKXkMQqxDw0NCVHtFBubbqwODBvnBAQU8PsRsG2MVlIB",
		"QKFQzOWyAwODxVLZjFi76IEcHXJFmjzPM65gxtuwTt1UJpNJfyAAALu7xS76Ck7M0RUCBCqlIpGwcd9pawA9MTERDNhfLK71PboXiwbclhgtSbx17rwT8rmy",
		"WQ3YnFi/P8g4Z4wVdnO59Mbg2CvTN29q5Q33RH/reOGF8Ryrz8LquCHPXyqNxusTEYvFnVhiCKpMDkRUSu6XICGR9tl2XQaBPc40sV3jukvdZDggKI4H1bK2",
		"vtH9AdonWVnUg0NicScSjt68ebNZ2QTRkNqRMQASlr3weGH10cPBU6cZY27ZBYBgKFgs7u7s7GTS2aMjNEl7djSqsVuxUFuvMT/PllRtLymXywC08HhhaGhg",
		"aGgQtErEE+lMOubE4wF/KJksbW8DagA489Jpf8jnD0V1MNLf3+95MpNJH0u0aYt8Z0igNABKIn8ggohaSSGw3gX8QKCtwaEhA6+sZQxaaymJCCYmztcDMZui",
		"gYnXs7OznbKI5eWlGt5GCM4YIy0tq5uQ1tDwsMncW1vPK8sr+6UlzW3I6r8rcKxTY4NbvUmskNZSKtM+MuqmuI8DBUqp1jfXndAgYG0QCgSgkTYzW0rr/TdR",
		"PLwM8p35j9rE6FOnxuErdxAiAtH6yhfm8iMwpbyIk3BiKeoKEpyamqpBoqenbzHGFnpTHPWk10o0z6Q3/BViXqv+2QIAxN4/TQ49AQ8RVhae2GZMcDcAAGVv",
		"FzEGiIwLaBL9RLSEBQCe6yqldNkFgKqbKwWCISNOsrmRrt3YhhmYy+UOgtEhBGZa/04kLJ0oA7p25TJBR9/CSgejEqBBgogF7akrF7TylpZXh4YGhWUDKbPB",
		"ZHOZAKjSYsFz3eTo6bHx8fTiY6lKma31sdde1m7BtnmYw46CcCy1k9085iSRAJiwbb/WmjHcyW8oqf3BGNXyaGpw68YumUD1ka3Sd4whAF6YPN9bbo5Qt50k",
		"kslQKERKATbktlKpUNAPQFLK0dERA39sorMbbKhsS/gyHivGwWhvFotKKRN2ERnnAhA4gWXZDJEAOOfGlMO84PLK5vBQqmd/qD0gP+t6HhhC2fUGU/H/80/8",
		"9Rt33//i0efBYLBa62ChVP5v/uKPR0N+Typ8sqZTX0Wtv1op7Hnl2iqRVXuIHsJI3TXq+WoREXLrS2AGQS/8ugQgrOdzlqwkR4GYlUlna1mwE3OC/oAmktLb",
		"2toTa4/Fktns2sLDhzZqwz9MDI2MjY+5peLIyEg1slQSo3AoRKRj8XhvdHAkIEP4XFxcHNIAg33ALZJe2ztku8VZJgAFxgMBvw0E169fBeWCLIOws1VufWZ9",
		"TRNE40lEQZrCyT5h+eN9gxaUfJEAAn+wvOyPODsnRhao6iOzYCjpuq42AZpqjNc6/S+t6y2dnoBxkNZaS6lacmFEOHvu7PzsHCJKqbCb9hNcuDDR6DYwa3Di",
		"ra9ZIViRdl03m83U680CgFsuEJkGGgeAHgP0IfZOpXXAZyWTyfCDiKe8hs9JYFn2UbSGXsTow9EMeR2MVZ/w9vj0Oj4afWTbb0EVvKt3K80cT2xvb2fjiZhS",
		"lQw06kQQIByJmrVqWalkIr6VzsScKOM8EY9J12WMa60q4OO6dgRjzKrj2VeT305cOiaVAoB4sk88fhzklmG7QTNoEoEomUo1mc4pYkBESr99ZVL7oszNvz/d",
		"wL0eeuV1hnD27NlgOImMbL/QWuVPjQnwIk7k5u35U6+9sbG+eXS9q9nZ2U44cSJCBCk9pWSnxhdDXNvaisfi+2Jsj3Gf5wwBcXJysu1NUWNCzs7OdRi0tHuW",
		"OQnUbBwwOzdfY3gppdxyiZpnDAhk3MZpeHi46SMREed8YeGosr2ayGeJjXTuxkfzq+tLAV+ghpXSBMGA/T/985/563/hJxLRoOvJtqelotBnPirBzRs38CBK",
		"cwBw6fybLRaW9NWN0UrJerZWtRmNX9kTIoTVKlZkyUgiEHm09vFo6pVo2FFaBgJBIKrkUAhCCOEPBMMR0qS0CgQCSklDokZsmE0R0fz8XarDgZqgr7ViHe5y",
		"MxbRqrw7NgSC33j32+a+vX7lrbp82wXAgL8ZMeKiz+zD79+eu/61b1TNp2vTpFQ4GtBaRxJxrUpEWCqUASDsRAlYQUpC7o860MJJO6gNCpFq7bca5xeqQ153",
		"zw96wAIfnYFMrb8+wv1AB7B3bPWzbzcBxgrrslnil4AMvrOd2hx2thCbbfqYxo1se7f427d/77XTg407IgFANBxlHbpOMzNzRGRZlsnEtPLccskfjFRkzZfX",
		"RoYH9glHuhOH5VnARyMer18iAgBD7guGahpJiKCU4lwYp5+n357xJLTGumtdmfL7/Pnze9hVhNmZWSByXdeM+EfHxqTnIjLGeduxM0Ir+YIEFDvdueZXtz58",
		"j5h1ZXJqYHDo2+/9XtxJfPwbD2rZR9l1U8m+gVDzPbCb3fSxhG0xS1jk7ty4c4/Q4Pni+Vwml90Mh4aVksrzEDkCICNAVFICAEcEIqW8/v7U+hFS6aWlpaGh",
		"webSHmB2dh5NmAZAQK0VaT3ZKLX6gUH+ESBiuVy2LOvylcsANPPBDJl6Yh+uFWhN3ZHcs7OzVSQPYaPnLJ2Uwe1+GbzhBbRRhIW33nrTHwi2rtKZmcq0s53a",
		"HHXfQZHVajIDjmec80Q8IYTleqqLNkPbEVepXDa6skbmjIpFAMjlsvsGaAAYHxl6tnsd3dsEBw2pWis7EEwNnJLSrVvhqJSUUgruI9DPWkJNJ9qoQYam3pyb",
		"m79Qp/hDBJyzlaUVAIjH40BkNKqWlpZHRkY6iXHvn1HVIg8iAIyOjBUK5XK59OnMR8WdQsDyq+orm/hVChQxBACQSCYty0IArYlxtrqyEk8khC3ev30PmNjd",
		"2eVc1rRKKnpajfpYWMfFJgLOrdHRkXpREMZ5Lps/iifIzMwcAXC2J9fECGWT7GgVfMEEq2r2EinXGL0iIrcEECh1BJlWIkNGNy6xTbGP9apbQQAwOjpCRIyL",
		"ekUUIjKIY6yin7oJVdJR04tYoi+b3miCzJuoWpv7aYKazAsiKxQK2WzWiSWwUdPGCQc9KauUzp7uLCIQgq2srLzoR+8TwXsM1oxxAJKeq5RXn4UQECJ/Or/j",
		"3Nx8dwWMoxtj1NIE8pex1NA6iIqBdmkwIe6JKymta+53TjTaS+fUk17bSltrDQyQEJA/WFtmYme34IajydHTY9OffiAs2/AMTYugXCr5gyHz4ULBYH1g2UND",
		"Y2VvzmTSUcfJ9+BacmHy/MzsvOnqNMWSI7rqEREXYmd3J5vJVolFTigUVlKZmRgR2AI4EjCxsLAIAH39fQjaxzytiTMsl8vLy6sAMDoyZCL42NgIAAKyJt0o",
		"AJidm+vkPs45L5VLmXTGiUZ8jc2iAzW+pVQEZNWdeWRciIp0ohEGsCxhHGlnZmYNGM5IWTXftIgI2JYigvsoPeg2St+cA8C9e/cRQWlt0NamKEREy7KSyaTZ",
		"jJLJpEE957MZTyrbYkrVdP7IcGz34VXSV29mWFHXpQNXTN11fIgo2X8qn12vJGuIT+AsH30LquJsqaPR1dEaNC4v8yKTLA8AvlLU/HJbbgwMDhc2vczGEsBI",
		"NBKDFn19RFbIbwajKduyqHoj5fL5cCSi28rPknqceXT29LmB06d2lj8TUACAty6/hWtziURk8KVXisXszmbBQKa4dr/3e7+ZXt4EkAIRdgs/cOUdYNbY+CAi",
		"PHq4DIC57LbjhM14Z2FhIRZLwB7ImBCZlp6hb+RyOQDI92YrhYgXL04SmQ5k5ezOzMwiYi67BQCjIwNK6U7t46Xlte4hpRagAQA1Y8j8fp+USmtNgLoyHMU6",
		"cD0TdkgqjYxDNZOo9YtJKyDApiCyh8nHFjUYNBHT7/MNDg5W1ZpwcHAAAF3PNTXQvllk7V5r0sLO5XeBNCLmsul4PO73+xcWFlOpVCDg11rPz981RYzSCqGh",
		"F09ESqs2vQ4CYu1X+MTE+fv377emKPlsGitDZiCigM8uuJ7gzLYsQEZEliVqOC5E8AMYBsp7n8+88dIgAAeg7/+uH/613/wlJ5pwyzvpbJm6SSt/dWJ0w7wA",
		"uWC9yxZJuY9wiSkny6V8IBiugDSf+iObzSHjmXQ6lUr5bLvDbUMAMDQ8VC67+zqoOo6DyOrdnqKOEwoGGsSBiQBhkPoR0RmEgYE+xoVSXsM7V7oE+Mob55eX",
		"VzzP81dzscHBfkM41lrPzc1DnbIPIgYC4ZgTL2fyfckE7JTGxse3N/IxrUOhyPZGGkD7/X4AGH3pwk/+7Kkzo8Hcjh5J6h+/9qGfYVq+/NbAY85Qa8hs7gBA",
		"NBwGZLpK+cgewKoDuwRoz6joISfSnIvWKQXV2d22QDWwiySvcXB950+8c+PRd5LhVC6Xe/ntl8+EXvmP//S3LZ/NGF68MMGxakUCEIsnqGLqp0GrKit+7wtc",
		"vTwJADduNzsGrK122ydiTsTv98uWbQaRHT1Z+f+z96dBkiVbehh2znG/98a+R2ZG5FJbb1VdlVnV3VX95s0+WIgZEAvJMWiIAURAEAWSgEmikYYfgskkwEwb",
		"ZaRRNEmAQIMZIGKMA0DAABpAs2LmvYeZN91V1d2ZWUvv3VWV+xZbRsZy73U/+uERkbFmRi5V3f3e3B9lWZmRkTf8uh8/fs63VLqgkMVi0agY7u7uJlMp1to4",
		"bPlKhYJBpTWbndCk30J++unn3aSb3rxtcagzjhAShvXcyl2T3E4ljKVRbmrCqOn2pTxLS8vmTn7mR3+6WFgp7VekkAaa7XnNiWz+wqW8JNLDJDsNxDuXz7c3",
		"Vawe1CsncY1Z2xzOMpueysqvW8oo7JYvFgnyPXWiEs/k1KQgYTq2R5S9YokMa/Y9H88gj/CCodwGG2SUh0ZxoYmQxqmdAcSikXA42AklzKx1Z+UzdJyn8RD+",
		"he09rRtJtrCwYPpOkxNZQDLaXaw7IH98/PjDlsqw0QsFKDRKgUAQ2GcGVkZKVAErALyz8ArIMGgXRBglbe54FyfqiVAtEYTdCv+rhxdezlv/8Ncq/4//2YEj",
		"QQNpZgINROVKJRKOjpZjTRhtaES0LGkAXhsbm6NgPMxAhK7rNhoNRFRKR6NRIrv7+B+Lx0mSGPb7Bh7QdwxqDRozAJo+4WZgeym+FIUYp3Dp0VL1O42ptfzN",
		"t64HrUBAAraA0ggApWJhamoKoU23AuxopHEfgnfs66NPPv/2228CwKuvvtKD+WMW0qrWqp7rXrxwqV6vnwtEv5N3FbsMxp48W//2j9ze2tgAgHw+b1hRhupd",
		"rw+q0zAiIZKQosvQqaWEQkKMwo9PTU1prRCJCM2JYZTw9s2bC8wsBYUisX/zzm9v7tyNRuIG2LdfrfzUWz/9+ms39islpdTwQj2DEGTKO67brJzQ1otHNCRX",
		"17fk17O4zO1Ww7OVjbnZXCKRHOpT1V9+QlTKN+XmpaXlocSBhfn53bUPfQhM5C4rz31xqOUzQFvNrHRsW2tNI46cBtk2ftfU+Gp3D7upEmrlkbShg5BDABSL",
		"79/T2kMZgiFZPGqtpZQkLeX5bVPE1mMs1AvGbrFR8KLxaCQUqVT2tJGnBvj5P36d1reX6DaoxoL/yTIiQ5tQpjmXtf+7v7QN0AAgAH7nnQdwAP/lT8KXnxEA",
		"3Lz1xp07t++/9x4AVsr7o2L05OSEZdm6xcVoFZe7KEiDECLTLISPPvxYaS2F0MxCCCICYCJEongiXS7tjVkzUVqLTgPOyOktLCw/fFD+zeL1ws2eA+0FsIQw",
		"w2cAH8A6Ho8iomUJ1oqZkQCYZXsPOPXcfe2VK6wVgNXXxmGAx48f+0pppXZ39pRSfVZhQ4yMRsvdpFLpQmEvlUzgsP0Du47MZlfb3NycnJzUWrmuO2S5ICrP",
		"2/rkMxUJjf9JLUv6fus2u6rfPDyAEDZdv17YrdWrosWwBQOqq6nGXmFPEMlhuK+bN+e11oFgWApx9+49KTAVDxdOZEeAiL1c8I5v1pAYvb6xlc9NwtcAS0aI",
		"c7O5eCIVjUW08o8teWitt7a28/n8qHiIiNX9vZoL4bBzdkCfEVUCgM/Xn13JD6fUrxf38sl0uwLoDX3N0iePFl55vfPfQr0aiYRrDTdhtUoHe4WiKRT4/lGa",
		"Ozi++S/g/Pz8UNJEKx/pOa1rALKD8ZVnz2LxeCwa6TnOMwshagfVYqk8MzPj+8q2bc2sfAUItb0mQIvMuV/ej4QjUZEyp1pA/Ge//RgOuETvA6hP/EBJfAwo",
		"Ddml0wnqqDsBEyApt+k2DgBYeW6j2qiVy5YdiKeShIcSms1mMxAImO6ZUkoIrTXfXDCoQVxaWm6jf7lvnnRyGVaKiIQU1WqNBJHvH74QmydyPt3e2pqYyBIJ",
		"KchxbKWZEAgxFAmGInPAql47MA9Ca212AmDgVveBAwEHW5owPQOezabOiuQhIhI8Ip9AIiIBDI8ePR7TKqjbxpC8SiKTD0fCUqBl28r3daNMgXj3716Ym8Yh",
		"HqfMbISfhogDMOudjY11twkAY6qMtU1n5g8xvCPGTWsIBe2nG+v/8F/8g8uzmWCgRQT3lUrEU3ff/+4/2/43/6u/8FeSkcCgphIzIKDvucpHU0/HMxeMOvFa",
		"Pn36rI+1pZVaW9uYmZn+6qM0dimjaD2qSgWHtqcEAKNco9KpmNbcqFcFEp/ONHTYlcmmY8kYaL7y+st9P/r80afReEQALX12P535ESR8svvp5ETOVz4hVqqV",
		"m9ffAheSmUAN91uPFpEsVa3VPK3AygHA04NnCSt8IXvxvDhmUkrNJ8DqtU4kzAAghOzbC9gYV5fKz1bWZudmAXBldT0eTwDJcnG314sr0fndg4O6ZmhUm5kg",
		"7+/XEHU8SLWDhgbBrAJOABAQSSnfiCIxgxTESMW9QlKC57qe26xVys1iwQsGm5FIFNFAU5VSrHW331rriNCjC2ViSt8ehZZld9YCEhHimBi7RCLZXd8flXMY",
		"+TIz81hpQNZaEwlzb63bYZBCAMDbb90iJ7yz/kyznpzMKf9Q9pq19jxPEIFl99q+nSBqI+BBrSaFGDxlI1Fhd6+1aeFIUyUisu1WCQgR9/f3D+OdFQvHU8zs",
		"BENGOWTm8rX19bVYIm2q1fFEyuz0iUSSAbXW8XjCcWwisiwrGo0Ojp7SDABSCmILRruWDMd3dv97ZC9MCkon0wEn0HQZgAnJkpKIQsFIMgZ05F9Svs/M8zdu",
		"LC2+P2iOc/oFOySZYqYx/ElfGC/DWDTNz984+q5ONiSEQkjfc+kMQGtmQEJtw299719PZqfe//ju4PxouN7rszcAyHR9avVavVH3fZ+I6rWa73sOBmq1g3q4",
		"3sa6MgIKKYqF4uR0DgAuhOfOt2tsdHzaSZABP2B3bRp7BRbagChMpVKmdj202jg3Ow3cCjR9zu6Dw1vY23OVk475XoA3d/cDopmbo722PEgimSIiQeT5WC6V",
		"P9t6gGhPTeYuT74yOTlhSUuzjkRj4Ujkj/zp6abnaoBoNPzO999t8R5lCIDj8SgjkBBDesPcblAZNEPrUYITCHYU9PqAVrFYHIVE5qE9ySPW/tRkBlFoZsJW",
		"kRkB7tx+0xSFiARKp+Opw15DK+/33rkPCMj40tvzU69e8/b2tN9AIABGgDtvXNeAmgLl4k4qERctjf/DWxhHrTieSJqEpo/RZ4bCiOsXC8fLqkxMZA24hQhL",
		"xeLE5KQgqteqe1urK8+ezc7O1g/2hRCW7bTE81gbi3pzFolFw8y6XC6HglMkyAkEgLWUOMSfHqnpuppBBIPXLl08YQlh3AVNgJ6nNnc2JUabnkaAerO+U9jx",
		"fEXg7deDPI6NdUtr/dwWrBzIzpDPVDv9OnfedEcO2G3UCzurqcy00gp7t8ET1jq0ray3r/740a+8kH1JkATAa7MLAAA2AEAmMLm3WpiYmHxtZkjJ7y//F3/t",
		"X/7yP/XfLhVfq8Q+CZf+AMKR2BlHIJtJK6UEke+6S4uLsoWWQ4buc0V3IwqFIEJyvaYpHUxNTTJDN1QDW+LU0QcPP5menmm67shtUfZIwtuiKYVN4Du2BarZ",
		"HcGJWpOd2QWAlyZvmPuybRtAA7NAkpIBCGywQ+GDgyYrrfwmIq6ttZrMG5ubzPD669csaY1otPY/bWbdXV3t/uGpSSubW7uTkxOIpDQL1qY3ayxFEEkzsOd1",
		"wZhszdRsNpghHAr9b/7f/82f/Yk//adeve02Daj/8M5s2yai9c31cCgScIJaa18xaD+dSqVSSVNCdRznEJzX9WkQjLosNho1rVTLx+uwonCi8NITA43QsxRS",
		"+b5xwFz5/MNgYmpqarJaWI+k8oZA1KERMQCD6My7t9++43suQr+jMbS8niEYCrz2yssrlcrzoN8SYtPz8tnkf/4//U8Ekdm+Ak7gP/2F/4xIAOj/3/f/ALtU",
		"cEcnbuccPCUNCNziyTafb8YVT6ScgOU2G1orIqG1btT3C3vrJitEQK1UKBx1Ykk+gUoBMgMJOouf4Sjb4Lvf+71UOL4R3eW8B9s6EYyefRBsKVXrQM1K61pT",
		"CSKlNKIOhQKgucs3vXXTlWppv3yAYbfiFZvNRtpP2RZq1tgWeuQWhcGam82tra0elb8rr9Wk6oH49WTuXQuLEYHRAoBsMr5TLLfDpv7W27eA25LRCljoRqMR",
		"cGwrENFKT05OSilrbUCCFIKH0R9i8eSQ5dtfnz63bjERNJtus+m2hAe0DgZCgWBQqR5LFFPHRERpydX1ze3tQn5iEoCBJPS9jhkAvGZTJqYUAmCrYBIIBtoE",
		"Oe15/tHl6NmZvPIV91CvWbM+fSO9rXPYarghBhNTACCkdfHl69Kye6A0zAgQCtrBwFTnPAeAw/46I1Kj0VBaa+kM0+WAc4EraKUdxwqHJjoDorSKhiPmv3/p",
		"T/1Z13XVi9cmnZmd+cGIwnzk1lIuFWKxOc9ttstnBMC1arGt14G+59oBh+gEYh3MTEKsP1vd2Fg3CNAjLs9tAuD6+lo+P1ah//69+9PT085vZ+Dvg3Mhg6mz",
		"NyFAM2vmG6+98viTz9jzu+FBT7eKQWEfeOVUMF+oH4rEZ8KzAMAHdsyaBAv2dg9/Zaf61LICAH7CmR5Wps86tn1YGGltfXr89MxXClhNH9RS1eokCXScUivH",
		"6ybwm8I1tVuA2hD6Q8FgZG7OmAoppYD6Ro/DQdv3vU4NybR/Dw4OhUh9z6dzKykeunwZNo1ROxmEz5k0rc2FAymF53ttJjUOkZ0RhMCGmGcAkW04Gg9q+Q82",
		"h5uNmu04vWBuNi2+0Q6NWdt2DsXvmSVIs+7y09NaKwAIBMOzV64qpVB7szM59lzUHiH6SrfKPWYbQGyT3M3apXfeeYe1vn379jDWOvq+KhYLiUTifOV7BsN0",
		"U7ndo9xsE+7ZZSJ68fqVcnVllYd5ZX0NeoZn0PDqup48eaqUunLlcjv74I7AhRB294GtLSuDJxFr17l8bpwXW7atlR4zQAPAG2++sbW55f7kHtysNB9y8d9A",
		"aCZ6DqGi5dmtETGWyBBiqbgDAAknCQCODANAKjjdZYiXajFogZXvScsB1ojk+x7AhVQqHQjYrdynE0faYUJrdequgWGRWAjUaOwIyV5TKC2O7IC9fect3/dc",
		"Vy0uLjKz8pqAyMonku3oh2B0NZXP7JO0+2ZM5/ZJkNLa81U6nRaCto9zsTn5uXt4lLn77ruIaDsBt9mYnc69SperBzXIjkwRlK+Hlh6OTfQQQWsVCkfMZsG9",
		"/P6RWtUdyNzhkcuEXO61DTbinLx/0LAIplKhUs07qOweuL13dVCffuWlrc1NAMjlpo5t4iNhPJlmHgJPXt/YuXb1ZWb48KNP+2vxzEY5pHuGHkVFxmGb4UlK",
		"24uLi+cco/XXvh495r6FCFqp2dmZQ6F0RK9dHo3FY6yZSCBKZm0wA52PiYi+7zKrE/fmGAQ9F4kPaVnpSGI9uksTCHEcUutom2Ibzo7WfKxiHwMLacWyk/LJ",
		"M0QMkACASHhaaS3lifwHNEAwFo+3kXn9k9mA3lhDt5ZbSw1ybLapINRK12zHDjioNdo2MLx9+9ZIEgCT5YT8xsa37tySTqRW3m4e7EknEk3m9verJ0p/sL24",
		"EVFrnc1mu9cnEdVqjUql9FzyOOZmo8EA9Xqjsl+VctTsYillIOicribDmoUQ+5WK6/V7JjQbDcuy44l4uTSyBL9w6+YRAWvpgw8YGEGXSmUA2CmUWzHWrwGC",
		"9r3YxNz+xnZjZxtfeanzyUvFvWg0fMQENkwrAvAHajj5XJaBGHiwWYokLMtghJQQ1FJ6eSHy9OcWCu7de6/vrZuNRiqd/Wt//a+6XgO+ec7ffp8a3OzsrAkZ",
		"vu/bgSDImN8sSMGxRNayHAOBRETWWli2Ur4lzb51/BDfvv3WvXv3x/RlICQ+STOBNQMD+MAM4A/RvV2YXwCApeUl0022HQEMJNTRBw0kkJa88/YdBLh7915L",
		"oFYI1mooNd58663btwHg3r17RostERcAulxpBbLbt9/qsR9kllLU602t/VOoEna9iax7aj8ansznzLZgw0j6vtGF813fd+vSjiilyAqQdBBpWDp/3GbPbFgJ",
		"Dx8+ZgYi6sjjGam/ozU/T122RgCtdbHU6ontV10ph2LYwVcci0bj0cBB4/RHfyGEZD1gn0oIMDpAt/XrOjnC4FYpRL1eX/rg/tzFK7Eg2U4QiXYK+1qGAACx",
		"VimXIeQ4Fy90b5zxRKqb5t73eb/19p2t7Z0Hy8tEYm42N35M7IhMpVOJvUIpn8/zCzFr3SlWf4h078acgoPnFxPOPM9rN0LhjZs31zY2jfOs7QRtJ6S16lQ3",
		"tVJKaUvi81BXqjW8/fLeiYm12LUc2hg4BGDkl25dBYClR8usuNlsFgqFRDJT6oIkx+MJpBbaixkEEZAARFba4Bm7Cn+Gn0zj3JFmVSw247HgK6+8JgWGI8G+",
		"RhsRHhwceJ7PrAVJIU+rx90+mXq1g0Kpkk4m7Uj4iJdXd74Mp+ZEaAKFdVCtACA4aWjRc/u43gKPXqjMQggpxK1bt4xyW2cWauZHjx7x+TFP2aAbGHng9GpJ",
		"wXrks1BaI/tnWcJ8Qhn/RCJOSKw1sG7ZjLcEmLnHkljpQMCZu3gFAGwnFIxE2G+GLF09qJGvUWmOhtoCO/7s3NzKs2dKqXKpEItFRquoou/7mnloOFjb2I7F",
		"YpVheI/1zR3f8+dmc44dTMbpuav0mL0caWoyu7m184fapCeL2m2nS0RAJGSttVJaH3qy8fMEtJwsQA8gmoUQ+weNSnEPANKJ9Bd/8oO/FXuHwYv92Ezlv21m",
		"cnEAKPVyRsLhEBG2eqSAmtlg2vQQVj2Oy/wkWn/2LDcVqTfh7u/947mLF1678ce51/kNEQ8ODj788CNzeiBBh+vipPUGgH0/USugUvFmiV6KHPULwWjW89X2",
		"9lYmnSEiQiGk8Dz/2L1nJFTTqGt0NbhOWVhoy0q0IVTmoRjDEZRAwPDO/XdaatZtEsDTJ6uXo9HoaB0Ss1cbwbmeniK34uexGpBwMtPLWDQW9z2XWQMrQPQ9",
		"v1qtEgnW2rKtcDiilQJEZoVI+XxOSMkMBwcHhUIxnUzE0rlmox4MhHR32t1bfBi9nWOj0WRGrfWXT9cuXZhOJDMIWjOWS3tHLNsOAmTqP8ql/fijX/qI8QUY",
		"FvAf6kefcuS0hoAD1YZrxGGx3WE5pVnAV3eyQG2aPQRqZK1Fa8VMHecUYHYcW0rZLyY/ttAIAjDrXD6fSQcAvLf+zF8FAN9r9r4Jaq3TmYyUEhEJiXvgYnwy",
		"4wIR2KglAgHh+xxEACi/e/eDt+/c6uO1my/tSNpt1BPJVDQWq1ar5f3yQbWSn5pkDp7eAOg8fCgNPsS4dB96X7FuNqqoMXQtfeAcfCv/49/5x78FCB2G5IWL",
		"M/98c/HHq+V3Hj9rUa7boeit27eN92kbJotE0BFKJSJBRrz/sFfW+RyGFa2Zsc9u8tgtG1ErxQxtkwcEQKWUaUKTT/2NOq1YMyDatpXP54lI+b7Rm8TDviUT",
		"UTweG5O7jkQIWgoRjyccRyCIZrOFLhe96Pu+yz3g//bp3/obF/73by681YSh5aExBNiHSYi0Z7Y+RKIDA6vzSqJ/6DxnGUAKmpq5bFkBpbTWCr7eSHDNWrGv",
		"h1H7GFiBHwwG16p7m4/WYIiCAbb86lvUZ7x37z0hyGhOtUIuMwDevv3WUWtDiE4PFoClkMXiQTKmXbeBaOOoWoG09vf3y6XDxloimQoFAwNIfB7SGcYWWo1V",
		"42LkmWUJpbUlLYAogOpRSW5VcrilGcDmmVIkGmNAZh0Kh5XmIU+Z+Vjlq3M5VE1P5w2Wrpe4SEqpUmkrzKHfafzap84X2cWL1qbDotn9uyknlgjF6lihno/M",
		"792/D4DAPoBWil3PKxYKs3NzwBqQKuVKuVxKpVLhSJi1VkobtT9DDDE2Zg8fPjLfUUohwssvv9z1kVlrTqSSpUIxnU4p5ZdMfZwZAOYXbnQjPNLplLQcYNZa",
		"K78lJLmwsIBEXv1Aa/3hJ58jErP2fY2tqg533FiWlpbq9Xq5XJmcCh0LEDCOYgzaV2pp+dHFC9O9EBf3qFPs/v6VxMuXo699Z+l3ebAxhC272EF/vu50prWU",
		"+PBXOq0mBLp9q7WILLQ0YCYZ2T2nkrT8oXIC174XjaWkJUnYzUZdj5AZvHfv/pjHcsTn6AzAwJaUAQxY0mLmQ4VcRGBEn4BQK01Eli0RxJjlA6UUAxj4nSXF",
		"4dRkuHfvbg8GzejbawWAt27dWpifB2BAaVu1hau0/LHl+74lcEAgGd95510i0cdY0RpVbxVYM3jtk6ersUepx3QnybKpBAokAHsAGHVd9b3vvXvjxvVOiA7Y",
		"li0kEdbqNUEUi0S08j3fty1rIptruL4lh7Meh4Zp2zm0I3Gbza5OALBm3VnJPL61se5CJPYYCWrlas2Tzat4O6DiQlnc1D0x+qeSlz/5re/H44kOtz6TnbAt",
		"yaDb0YJdz9caoas5Zq5CoVAoFIw4p/HMnprMIkKjXnMcp9GoIUopRTAYMN4IrVKy1pZlAUAoEAxPh4xteTgc7YApqbdwZFvW+x8smrCulELEhYV5YJZClGo1",
		"V9Hbb9+p1WpEtLS0zFo36vVQKKyUMr0iRPI9Px6PCaJ8Lgcjqu9mGkYjEUS2LfvShelYPCkFK4XlcnGcHJgENXXTVQ0zu/peb9i2VnuimK1eSmEE0KmFvgff",
		"92FA4w8RL//MpcfF99+T39esALD5ljtjpZ7+1v4f5tGn1dIjUS7tHpTW4tkrth0cDNN37907gYQcAwDOzMyO+rnrus1mQ0pLCGHb9tjvzIhYOCin/+3F6fvB",
		"Rr1WODjss1sB6/r3fxR+nwGx2Wx+zE+A8Vh4iWm8aKU3NjfhUF13EhHrtVrHK50ZhBStScwdaWk2jA9mIPTvL394/z4DgO9rInrj1q3Ox3r//Q+YQQgBiH2k",
		"2Ep5r49QXd73yvtIcAAAn64eLv5SsTjq+VlSAkA0EuniLqMIouv5vudppIZXZ7dKTgRkEHTtwcOHZgUOblY3F3oo+ItLywDYbDZarTTEQCDAmudNxre4BIhE",
		"xuSQxlfMMdW0hYX54fh60NvLm8EbkY3Giqg74Ax5BxOgNzY2c7mp3Z3tU8x5I/BrUM+KoV4/cGyr4aqtrd1EMt5JDLXWtmU7jqM1d8QB+LBVA61x6Mb/WRYg",
		"AUP14CAcCnK7JuN5XiKVQcRGo/HgwQPjKcPAxWIpGAqZ4g8zsNbhSAQRfF916GP37t3vU3m7ffst5fuZTCoYcJTvTU9P+QpsyZX98eWtkRUHKAiAR1sfGMHx",
		"YMBeXTUunali8RiZw8ff+2j/yueiEWRkAVTRB7ciV4M49Ycx+pSgRc/zwpFMtVzQqr91Ztz5fM8XUlT265VyAQCSyXSxuAcAsXgSAcrl4on+YjKVsiyHWXu+",
		"t729fYp79j1FJCcmJjq/vrm5mU5nTGfIoD49zx/3YN5+1cx03lfK9/2O4XwHWLa2utb9GzMz036b/7q8vAysa7VPbdtCQCFnlcKm63b+ukkbazWXgcvFvfN9",
		"fCsrK4l4PByJ1Gv17ijJAKCZiJaWloBZ2o5WW0qpmzcXTBJGgrqPraa8O6TBj3jw2ZeoFSAyonztFSmlFGwAab5SjaZvhESUxrP3/ze2Wj3e/X8AAoYH6M6V",
		"y02dug0zN5tLplKABMCEgtlv24FDqdiPsZuZmWbWN28OR0m1R9IsFs/0DJVS5VIpFg17WncsILh9IZKUQmttKGPra+vtT5QDxNdfv2beTUoZDAbeeeeuEQHs",
		"FBoYDGcStDZvRZ7na8YTPQGtFNt+iILHckefrW4CQHAyDQDrG2Mt2LgTc5xJ1DYQE5Cjw1EZ98+vufWNidHLyw+MNmm3SNvpULfNRsV1m0JazLoj1dtx59TA",
		"xGwCNACYAB2PJ5g1IMST6ROFHq2ZtQun1VkxlGhmDb24/b293W6tUddtnnRIVtfWASCfyzHwCdUYcHUrNTOdKhe2Mxm2bSTETsREACLqvr3n4aSmmYn7/Kha",
		"IsvMutloEBERLi0tG8O6tbX1gXg3FAzOzVSi81/P85yAs7y8/PZb80JSvdEYRwru63kVC4WJbEoQPnz0AAFGacwkE8kjhp6EWFtbG/XzpuuJ3giotX78+HGt",
		"Vnvw8PHsTH5UJ7BTbq4d1LRWrHljczOeSJVLhXQ6FQgED2o1ImSAhfkbyt1ffvRpj9Y5AAAIacfiycqIFCo9FYO/c+PvwX9/7EDNzUx1cpl8bgKGyOvv5nOZ",
		"1fWdmXwWAFxXFg62D7xNch0gJhD7ujplJaOQ/yGK0dhuixt/X61b8pinwxURoYH71KqlVHZGKR8PD6UIzJaUSCKWSHXLWQwX2xzjKpeKZzQzPJuyFy8uLXVZ",
		"afCgC/MpOKXRoF8ubPeAH54/IiYei5UrlaGVx6XlpY7DrNJ6e2c3HouFwmFjknRq0qy0bENpe/f+A4MqgK+rXtgRtgNdZFqStqVdBWAMufUIeYNTCshtb21N",
		"T0+3JXbHFdLpcZVlbVARRmCn5aULvLS4tLAwb1IoAk1EWjFZdmljZ3V9eyY/kc9lDUzrCF3W9NHnlLGvhflXtO+nkzFo2dBAvhmGpUsvvzLTqb59vrTqgf9D",
		"FKPLpVIkHK7VGgboSsiBQOD0ZCEDpxKi2Tgo7W20tHcRlFZa+1Laq6tr37Ai+zDn0w6RjJkfPXrY3p9E31ozPTCzjJeHuIsNIXmPuaTh/MnxEgBIyI4eSOuA",
		"ZW4be0yQypVKuYvREIsnEalc2hsfWxVPpHa2t5PJTCAgNTNqOJ3zOvMI9zs+xwUyli/M1vYuACSSSUHUbLodL6juq1AszIRnTs1vHgqfIcSZ6dy4x0aEnpWN",
		"ZB7t0tKyKbFUa00DfV95tgYAM/mJPlL4SUdvfBW99c3d/FRmZ6fQlTdECeXcQtZNlsvenrlDj/1Xf3Ti0e9s/FDE6M4x/KDmdvtczMxM+2fic7aaSPv7e202",
		"H/q+x+0e7jdOF3vo4tnc3EwmU4a50waz9WdDiETUMkJEIgQepqfDvSk4D8mtmE2xiJ8byty8rVIKCR8+fNjZMJBQCFGtNorFkQWW/iNwi5xy1I1KgYlEoljc",
		"nZyc3NjYgjM4UgHw0tLSzZsL3Tjl8xPVO/5aW9+azk8CwJOn6xcB4vFEuVzOZDJ9Waf57xFxeIw7xmGQDB7HdqDb8LcLnVKcnY10atNa63K5DADpdPrpysaF",
		"2eNDfzqTcRyb9SBviwGw1u6WdyL12sbOdC479NiQn8p0vv7yydqli9Plyn6jTovOIz2/KWshJm1qHW+Er4bgh6Jn2KWjBd3KvynDhuj2Uuuozp+IXiWF1ZUQ",
		"avhmXp7ve55vIFP9VcjjWtL71QPbtjokB7fpDorZIxKiXn7woJ1JYbcsOgIsLz9oWxEh9rliP4dLKe12dSmZmUgcEaBHVM/QfKLeJBHP6u8zcDWaTduyTI2u",
		"TaZnADxa3Pl8++Q3b97Y2d4GgIsX8vHEocptX9w0/+W2UNxgzYRPW9I6PkD37JfY1yiGLpNvEwEAsS9AM/PQohYZQMmIkXEcJ5VKd+8K07lsLJ6AXlesTCYb",
		"DAY60Gjf9ycmJtp9MbwI2c/VkrJ8QkFAtrYjFNHwQ9EzPPTci0WCnUyIiAykv9sN0xAEDJ6RGZaGH9u5z+S4KzVkS1qnK84efWUnJrTWRg9/Z+fE1KNUKiEt",
		"RytlWdbGxvDT06svv7S+sVmpjMRjxuKJcCh4qE7a0mCGjY2Nyhh1ds/zOtuhgdB2bQ/GxYPVIUiG1zc2nqscguu6e3t7Z9vVFOHQNPr8c9vC3l42m5VSGLZI",
		"26sMDmovKkYTBSzrJK83QnE4zBmOxjz4jl/IXlpawo5bREvj9sRrcH1jJ5FIAPQn7E+fbSQSCcexb1zrd9pbXFySktbXtz//4tmPfvv27Nwsa24/IFZKzc7N",
		"Vau1YmEXAHZ3d3L5HOtDmUwp5aH1JQhQ5GttrNfUUMfc8XTy3pi/+k3Fddi42gWe3QXI8IDoBAKUSnsTExNDJTpxNIcJET3PzeUvbe5UlfLz09MdfhECHNHI",
		"HisceB4h+iM2+XFyRgavu/ien56GLsdYc5OZbPZ73/u90Sf9EpJEQNYeAJCwRjmUD702u/DUA2iBvUw2rTUX9govbDLQmel/O6cCQZ5RphKxMw2RGYDVi/nr",
		"Rix8/Nf3cWGGXrOzswO2lmgcFoYIWCGurm/N5CcnJiYsy2qPA7e7i6iUbpXj2uaZveL1rXes1epqRBcqn8uWSqXBhH1h/prtWFrpoXNGa47F41cuzwGg73l9",
		"C1T7Pnc9I/PkWjj3rpcuLS8DsAo2tG4iCgDS3GC7tb7m9na3gRrpFBwPsfVGTZ5vRoz+/FnPsymNPtiOwiDH4sl4LETEOMRily3LXl/73G02nECo+2x19msk",
		"HWO8q1zul/JaH9gzPv3sC9/3+jxS+9+nuPv8AtCLodObTS4YcAAp3+WrYCgz1YNG6bl9xueT3r6gpbe1uTk9M3Pe5SaltT62Z0hESqlwOPz6tVcRhRNw3OZh",
		"kcqgJaUUGxsbph3XZs9P+74azLECAccbbRCzsrY5Oz01AIsqZrPZUQxcBKB2AETEhfkbnQ+gNT9+9Ig1Dz8lYD8lKvTFjFSeQCIk9hpWOu0TA8CzdGbMIb0w",
		"m/9h57AcG0jo+Uj1H3sZItMR0M7j80pBqM4/TMaTgzVELn/1cbDfgqKNS/k662ExAHThKAQzhAJWcGqqyzSg3umKJxLJUCioR+SMSOg2vdMh0FfWNmPx5DlU",
		"dBAQx+r6LCzMP3r0CBFKxb1IOIiI3eyYxcUlZp1MJgej50IviQYRPvjgKI+I2emp/HR+vRcI/8WT1Xgi4Ti28WXv/tH8wo3HDz6c+OnIvZVfn1r9d6GXi2pK",
		"LoYdHo2nWsJVI2MIy09JtrF9UZXaelrOpGLwhzzDU1yLiw9u337za3VLQopkKqPPYA+BiETi3LPZWHSIXFwokOsri7NmrfVXqDq7uLiE3xzJwm5t7I7cIvUe",
		"RhCBEBmH1seZEE+NCZmdnkLQhCKRSDHz8zJvHdERHFVrHHP+dH69Ui6k0+knz9YvzuWPVq67fHGGjoSHMoHbq2N12HdhHQwGZ+fmOiKqAGjbVrPrKDAC8No8",
		"39H74YrR5+r1fr4Aw9P/Xdf1fM99LrUF5jdv3zb8vfv37hKRQSNkstmW4JJmyxIWczqdMX4CDLy3u/uiLdMQ+LwfHPZo8D/HPUYzP3r4cBC3fuPG/GAsZuYH",
		"Dx4e3dsYjLydd5mdm242PESWgmoN//QBmk82jIIoHosN3vbCwvzDhw8HQh4Py66WO3YqSAKQbs5f7WN4nfRJ3b51+wG/F+PojfkblrA1+4Ol/G7Tpb7vdF/7",
		"QW56riBBiNWme3V6gg/0Dxc++izXxpMnuYsXy6VCLDo9uvxxjHJWLBZHIQ2qoVIqnKRikCFQDMQAgyTyWCJNgoh9HG0nmEylR2eJjESvvQJt8c8kAnbj7eKJ",
		"FICWRIDAmlsKaS1ZZ+oUcJ88Xbl4YTaTze4OIE+MvfS9u3exrXOfSmeCwa4UW3uAKO3DibT3POvRoy7zUJKpJLfNz4rFE1BDc/kcITIzETVdb2d7uzMfhBAt",
		"R5tDE3EqFPbONcnslU88/M5RkzKdSjGzZg4FHc/XnucTkd8OIt3Vsw4eg5Vvmu1aa3zBKc+wPXZ5abkjADLm2wUcSzEoBdFoCABLXeK3o6IFYgseujA/3+IU",
		"Hbbc+eeb/54E0uy3TRiws48GAoExH+Af/fk3NfgIhAAe+GmRXPpXjwFOoE36bG3ja90zRAClWPs9D0srRqBcboqI6o1m4VRwq3giFVtIVcqFRDLZvci5ZQDB",
		"HWVkrUb22RPJtCDQzITGV+8kpQzURNL4JA+LLHuByUlm4BFvm0jEwqEgH4ndnp2dMQOntSIhTIyOxeKRaASYu8BMrU2JhDAhIBya7rTRteZavQEAE5OTtmVp",
		"rWsHVQDY3dmayk2brrbWWmmllDbK7u2AxcDM7Rzk+bkVH8Zcbln/cf+zTkciIe0rQONASIVCIRaPm+4cIpYKu9lsxrJsU78mEgc1t1TcicfjAtFvaeRrE+V3",
		"d/c6xeJIJNSdWwshGLhYKHx1RzkGgFA4rLRCMIKiRlWRESkWCQMwkhjscCB0+wzg2BZZyS4YFZ+IXo8Ab775xtbmdr1Rv3TpUr1eH1qrO97UAkEpvbOznZvK",
		"mKmnfL9vXQze1dOVzVg8oXULB4XSkrajla89HxAUsSVsDzxHBgCJgX3tedojpGNtMM3006wXFuYBMLAX7P5A9z64Kyzb2ICNGyhG98Pk17/y0PLiO130Z22k",
		"NrA9yRBQaWVJZyJ3yfdcONQC4p3CQ99Xk5OT3XVeQGNxrQUiMAspDTivk9tyFxJu8O59z3fdhpSWkCKXz+OA9dTa6mo6nQwGIwEn0OfHtLG+zhq01lrrPmR3",
		"m7mzbPB5Q3MHQvCVRgADGOJ2YhYKBe/du99ZpcyGpaKEwGx2QhAZUJRtOwAQDIb3K/vKV4i4vr7eAfN1/lAmm9FaD2LvpqamjgDtnaHiQUji0aNHWmtEQgQh",
		"BJKIJdLl0l40HOjAs8ywxOMxbRScGSIz08oIVAEa1TvW3tr6NgDEYjFQ+ubC/IOHjwafolKH47+8vIzGEficiN3Lyw9Ea9dsD2lCH7jHq58qrbTS8/M3jGIq",
		"My8vP2jnEEyCh/f6gBEAUezubq2urc9MHy/9E41Fu0F1DHBEQtM3HG2fMD00z+DWiWfvpCcqA2Xup7PjIFhiqlIuVcql/B8JQdB6b+NfpP+r75Z//lqukRS2",
		"9eFPOg9W3v+L9D/5perfqYNbbx78qZd/4Ur91UatUt/fTWRmtbFJG6TyAGhgARSWEVc3lfZr6qBXGF0ZJ5oTRToEeP/BR9+kGN2p2S0tLlmWnJ2b6QlgCLXq",
		"/l7hGMmhUjuamOTo5s0bDIxIluMQCSFFn88TAAsiwEORF6VU6+xpJhmD77lIRCTM96WU/mhIkJRiZ6eSTqeksPo2ej7U3Gvlot0/smwLAK79+CtPF9dvLswP",
		"PSr2CUguLi71lGwY5ucPoft4eFTvdpttXffv3QsFbeCWKsVbb1xHImADovCIGIBm52aHrANmAAiHB60GeXZ29nyBjF8+eZbNZnzVZM22bXtew4waIVZKxXgi",
		"1VWyaknxsVK9exhjG+W6tLQUDAZu3LgKzL7vm0zL81xmNkqwDx89vv76NTPynaxzfn7+0aOHfcNwdDxtPdhRyh0DOaCko3JpROBWPxGxrRtnvIg782GpfyZ0",
		"RFlBSmQGI1C3v18dT9jTV0p1ZwlHSyZgl2s6MwOStCzL9wbhVeZg0m1i0DNcA0LtBn8lBWoGItBqZHduKpvSrUMkMHPzfcWg3rjxU+5/+eZ0OCpjYQL6ibr+",
		"qas/667Uf2Hmr6JNv/bs/6ORkQQSkRCIQ2SnCCkYCDAwkQzOhv7e8n/9C5f+ir3tNFWj+zSwsLCwuLh0XpQo+Y3ogCvtX3kzYcuQkdRQWgHrYGjOsu3BU5Hv",
		"+xOTmX/2P/76e995+MrLV8wMQCGNskWj4YXCyVg822zWEXtWQwegrpkfPXp8cFA14gDrq18iUQdg7/vezNwVOBQPmdk4jlm3N4LiEY2nzPqv1+p9Jc789HQq",
		"kvh19St/8xf/68+XPuLn3Mx86/ZboKrQjS9gBWTIVIzG1eqI/jv3qwghoDoPvEcimYyEw0r5BjO7s7M7Su8mnkh32MpEVCoW19Y3Z+fmQLk3by4Y6xPjDWZo",
		"qDdu3Hj0+HHYtoG173nQssdlIgSEeCJxvS1tfOxNTiRoULV0ZmZmdXX1sBLb9T5LS0udMps5h5VKpY8/+SQUigDXX33pTQbWDAPyKrC0tEx0nPcPDt8AVte2",
		"ASCbTSlfYSCYSCavvvbK1NSkZTsjat9tQzXNCJqIzBY4YCjTk1chQrNW677DZr3uWDISzjbdJvYFXwStdTBgB5xsCy/d8tVGHMD7E2FuarJWd4tjcA42d3pW",
		"3NZPf7Hb2PrJ1/4E7+Qabg2V0sAgSWwh2TZuo2b1p4N/HhvkK88KRJxgbLiRHiJJG1gzsL/le9TcqW/k8QLDc3Qb/wbgOm7dvOn6dRGoWSIIwE23Fg7GCOVB",
		"s+55Pnfbp7LSfs22gr/5S+9GMfHTP/UTBpwQDgUZQClNAgWKZuNgb7uQmZxTvjf0MZgSS2djzM9cOpGOzIlKMa1taDAxQShUS2GIIOALQpv0WDqZPyoBfGC+",
		"/eYNoPCJ3uz+/fudsc3l8ge1ZmXAGf21OfXRs9ZSvDqnPnwmhpKASsViPJGRAiYmJ7Vx50NsMeyNAR9zPJG0LELEN99847333tdaJxIJkwMitrUBmKldPm9R",
		"b9+4JaTNWjNr1gpJfPvb375//z2lVDQaiUWjlf394TQ9Pl7ErpMat8wE2pnt4uKy0WJumzBp8/SJUGvt2BJASCEeP3rA0K9TSERC0BHbBiKwUp2/nkxlgDUz",
		"J5Jp8wIj2zY5FYyEw5FwyCjfMI8KMtzhaS8tLvGA3V87haeOfqQ5i/QHfeahZ82XLl/66ONPewe07Z3WqA8YKDMhFovFZ6ubbZXnca8YRBU0yOdmva7Za8nM",
		"sm7qJgK4qLTWqEiihYDArHSPacbhh8HWedoMb1hGJVrPe13Kb5C6G7PWrBKRiUR0glCXdhalFepMlt/77qdA4o/8qT/iNnyGp8DMA3Rbrdh2yHPrmr8WbrPU",
		"MTMeUdHUoL+5SMTuNSpomN5Nl05/98+npqa6vD2BwVR+sGOxaASxuu8uFosC8Nt37mjlmigWjcWisZjnNo0MCyJI21p5tmLMkCKRSDAUNl7dzOy5TUQCpQBg",
		"YeHG4uKS8hUARyMRY+fYWabLy8tCjIVGN68J7BXT+ekiaFCtYM/MQlCtVuvkg7F4AgACgeDszMyzZ18Ql4v7QMKyoQaD/TTEvd3dTCYz4ukga9+UTWdmZswX",
		"SqlIOBCNHLINfV/5vk+EhrqFiHcGyl9waB3HiEhE3TRu2a4TMvPa2lo2m0GAg/394epUo4frageW1IV4QwC30ej+5itXLn/0yadMBIcy/N16HdtD9fgPa/eW",
		"6+smEL+/tHhj/noftMvs9eYywbfv+VK7M4a9nT2tNT///Okbho/W2lPlQGm/xrp5I1sD0SGY0bJ0QUT+9S9/xwi5LdxcGJraMDMSPc+jyblCzfTXnL05cosx",
		"FnbT09OIoJQKBQPhcOvsP3QH4N5TLXO3ajUbbcmh/uXtoM0AyFohyre/9SN37941jnxSWuaJ12q1jY1Ng2WMRMIdL1Hsug6PbrdudhYhkdBamQOPMflj1oBi",
		"nEfoymBCHoDWQKjaZ2dmDUDFYnFtfWM6nwOA9997LxQOz87M5KenV9bWyN1675NGIHvrIj0YVypu2FMxqSu2CnRqUI97dWUVhotv9PqxEjWqB8UulNv09PSA",
		"zHrLA/fQ+vBMaq6jzEhpKCO3FaBHR0tZimC1DpeO0noZClZhAIkACO2mxmFK/c477/A1RML7H9z32b95KsuRH5wY3V3QUMoHEAjc0KKroEwKEBi2tjZzualj",
		"IjB/7cArg3mZFDIdSWyFdhFhcWl54eb8KfLYB8sPehcMA8CP/Mi3zm/L5MMq4rBBNxARo0c4zPiDj/Dk6jSNmTlkjEr5KF/Xrq667m6KMvN77713WHloS1y3",
		"Hb71EUgyUyRp7wFAJKQUzFws7IytQIBdaxvbZtje5OREbmqKCA9qdaXV22/faTQagmh2etpT2yG9dyW2NZWcXVlZoUhSA6PWXKv0hE6EGwvzI7xCboCQR8BN",
		"FhcXD3tcOHJgTYNd+ao7QB9HEn++K6VSLg5Vo47HE0cs7MDd+CzEv7fz3aESvouLy8xsfsTMt+/c6YEFjxIaYJBVrWN6MF9ZWlqG89Mn+GbEaOpKWxBRKVWv",
		"VcUE6YHMbXpmVvkuIn2ztETcATVhg6z0vmv/03d/+RTznhl4vEbGEdjBozNopXS9XicirbWUMhgI6C4xQpPz1ut1E8RNy+6IckjnFmbnZnzXP/VS54EOAff6",
		"tpSKe9FICADcZsP3fURsH/n5SDQsAuL+fvVEWkgIIBxL9z4JZm07zsrK6uMPP7SkfPnll1995RXl+wbQFo9HKTp5UPpdr7qtE7MAkFt9RqxrJLyLcxUDfo8n",
		"iKgDUX/uKu6D8AYh4Ot57hx9JWMhIVpVr8FfFoKq1VowFBgX5ssACIFftd5J3p+dnQXPePgxIi4vLTO0IKE/PDEaMzOJQq3a4X1pLYUQFmrdQh0gIAohAGFt",
		"dWV6evoY/ObXhwzZLn6VS8XVtc2ZLuEuY2oZLMZ46jQxtFIpD6r1Z7MTgYCj295a9+7dNxg1A9i4/eZr/XOQ3aOboqZCMNQFGBE0w+7ubjqdPpm+RG9EQESt",
		"/PLejtl3GTieyhyRUw9PZpntdgKVzWYNIHx5+QEg3rl9R2m/VY8eeFMjzLaysno6+XPp1fYCFmrfIqt7PzLw6lgsfghPbg9lLJ6U6uDq1WuHBwo2KTxWioXp",
		"fF4zE6GJCGeoKrRIW/FE4pjNfJhfzfjUjBeXxglRbwyB4iVSWWaNgMXi7kQw0sI14mAVRRSLe04gdyIqBotDQpBtCWlZvu8jIQLuHxxUyuUf8BhtYD3G+/1W",
		"8gqhMF9X6yUhJFlqt2kBSkT0/AajKlSbJPHH/tjPfPrg4Yu0Bz2LvRZrkz5zLJGa6f2RcR0+f/dexPfe+6BDEWatG41mIBAA5nv3H/a9/PZb14+O0aa8P8oC",
		"AwEcx8aulHllbV0rdWFuFk6iaAEMWinjWHgKHuO9e/cIsdlsdu75oFolIcynfo51ry4HiaHnh27+CEKLrNSsV2PND3NTN3zFgJxOx0uJeOlACQLRrLaqM4oB",
		"T+m5fLiDKjUzMz10Z+ojpWvmbu1QGGaVnclkXkAPHo9ydUE97HNEI0GtfASMhKeV0n0bm2bVZifoUROdR3c/2VSpEYXAQMjZ2y2lUzEhEFBWyuVPP3vy8ksX",
		"f6BidKdNdKgyhGhZllJaku2pOgATCjdc9lkD0IcHSSJRb+6/PPMjX3z4xJ6Ub9685sOz1NS1e7/98bFyBwg0mvq1LMc+zZ0lpyiXi+0KKbwAETLf9x0bXbeF",
		"WANEz/X29nancjlgtmxxmEFrDWC476xZjxpJIciQ/QY3KhOX4vGE1rqtHYqzY7DajGjC4qKxM2dAZMRoMk2CzNTA0fXTFnyXuQ8OwV1429225NPs3JxmJqL2",
		"8uQuebbu0gQnUplS4ZRCURsbm5l0qqtqf9h3evLlF8FgkJmncnmTSa+trq6uPftjPzr5/h8s53L56enpvb0yAPSxAIb2w08Rp31fCcFn9/DM5zJCCu37zztA",
		"a82ZbHp3px/EubaxnUgkkGFtfXu614WWtVJKDTP5YEQKixgAS5Q4ognMAIQ9wDtuOeECMMiQM/XqBTjQvtLVqttsetWDpq8Y2MtkMulM5lz0xeTXp2kmLG5T",
		"1yUAokDl65WVlT//P//3K/WdzmnasUId/HvdPYgGgpX1ss2VqUwQD5RsREDIoczpvkuz6oviHUA+ns297eSZOOJJDu9wBt+mqbR4vNJfCNrc2DCC0eXiTiKV",
		"LhX2JiayliW//+5DxNa9mVJDB1nBDEJQKBg61D8ZdmT2lSLApeUHADimz6FW2ryyY2feOax0oHd37rzV3Z/ilo8wAArt1bRWMhBn5ZtaKiJWqgeVQXkNZgBo",
		"NGrAWmsthZCWAADP6zHgUL6KhgMI2WJhJxaPE9ml4s6YBigAkMtNcdt+pc+MjYgmp3KHcvhar66u+UpLoYyuhVLqk08/D0gpFHi+f/G1K0io/eeS649sxjIQ",
		"4hFJNAAkU1F8IUApZrakBIBkKhUKBgGgelAvlwrTuQkjrtQXoNufAW/272pMKFzl3he/GRBB8TaV6tu/+Of+wvf+yXcHT1bUvWUzd54mAP+Z/+1fWt34bO3f",
		"7DADKz+RiCvfN2NqW5awrL0fpFqHgWkaqUYppHGp9rR++OhxsfG2QBu44zGq29hhgJJkYgzVLCckD3yv2fS0IH3kfGEQgnyvuf7sw2Q6H4oktfLaG0BLbExI",
		"UT1olEulF/PZm023XCqfwnb+VNmIDVAf4dWyAwClwh4A+EpLizQrQ4ztkOn725KjNxYjCaKUj4DMmhmMZtOxwWJtbSOeSGKvZUk45GALnwuIfO/+e9/61tva",
		"V6aAc/fde92n0tt33uY20I0AEDgasENTU70maux7HiD4nodtjAooBeZudWu/WZifX1xaYs3Fwk48nnACDnDLlmGMDHrDUA1937dty/c9BBBSDo2P1YODUrFo",
		"PKKqNe/Hf/wniJCZf+ZnfiruFvXax1qErMD+nuYxSgq8tPwAkDon08GqCDNYljRM/dm5WThStOvYdojS+gWApV579ZWPP/lMswaAYqFQPLNLwfTluf/n+//H",
		"qBUnos3q+kLpjql79CfvPEhlAUR88/Zb+jOVbk4lb2TNZFO+D4hmtBcXF0mrb2Q9GkcUepR/+D+ffQDUmono+uvXQjK539iTZA++m0XSErJa3bfDmamMqNdr",
		"1GYJdgTtBnN2pVn5vrTscnGrUtxmYET0PU/5rhMIrKz0m1FtbaxM5g5LqBtrT3LTF89rQOLxZMeAY/QKOdMCMIzz/XIhkYqzPhR/yefzJtczf0AIcVB3S4Wd",
		"Vt7KWhB5nru+vgMAMzPTJwWVM3Cj6TJzKBSsHjQrpXGXVXnwlZwiwr29vVQ6Y1kSAUqlSiwSBoSm6xqEnxBkKuO1ahUJOkooBhrc55bbmYt4aI+k2tVFHDRD",
		"isVTSMSahxbfRXMbBhyZcrnc6urqxuZmOp0aUbJnANjc3Jiaymmt4/F4uVyu1fb2m0krIAhasMXrf/LP3v/og0YTN1Y3po6bCsyMwjEJMAmhR0RPRPB9f3Jy",
		"UghxPACofee56exf/k//jOf1mBYyw//r//ZPAOC1V16Br991xAdb+eLLhJ2KWDFCalquIwLf+ta3XN8d4JFBh7ZPdMjckVJ6OXd7c33m4FLNPyCk3mmD30i9",
		"DgTwvZaUHQkQAvnQ4bErXoMPAKyYiGbn5n7v199/+4++zqB97XUfqQixEt4PJCfv/stFQexYUoN449ZNQLAsCYCa2exsfSWtB48+t5wgc2NycjJkNWpeIGQ1",
		"SQikfeYe4d1YPFUpF7oDNACYAB2LpwfJzefO5UskEgqk7/u/8dvfvXbtmpSy27dQKWVZ1q/8yq/Mzc0BwGQm4WrqKFMHA5bWCgFt2wKAeHQaABUjQKl1Bu9C",
		"3RldhoDdLtru7MzMztZqtcLe3vrGVj43yccpBw3rSrUEPAOBAJwtp+jkrYW93Vg8jogfLD1KJBLNZvOgUhBCoAysr6xMTk0S4oeffhmLxYzWysrKyuuvv26E",
		"ocvl8rVXL58uXcRDUtq4D9EA1HJTU4akZ1l2f61DSACYmsoBQCwaVUpJy5qgrLRtAn37rdua9XvvL/7mr/xGsbiTz8/orT2czo/Z5SSitbW1bDZrWdYIOScm",
		"orEgQ+0H/9N/4vbGxq5Sh9rTZyaswPNnvfExbpyAQKADnkJ/6LkQh/4PAQF99j3tPu86j/xKeoNDhmJQbx8BgD23SUjv/c4nb/+x655qEFom7ZWWBOZ0OOs1",
		"q8Dq7Z++s/h77wMTEhpmFDPD4ONB1Mqv7B9EUSBirVbjYNB1m5cuzSLg+lZJs4rFgvFYqHOz8fhM0xvyDCR5gdAsAGxvrJw5lY6bgDI7N2vIytB2pI/Fk2a9",
		"TWWThZ0NAMjPXurDhEopM5kMACD4XfAuZVtB30dEaHPMGFECSgCIJTJCCN9XLeFzRCOW1tc+CgWD4bk5YxfEWp8YBNF1MCRpnfqcEQw6DKCV3tnZNtODEJVb",
		"axwgAEgnDACg3ZYUHKLruszseZ7neQBQLBaZORaLeZ532keE5XIBALITE6c60mAvRLsVqWdnZ7sfpee5psV0/ZIoe5NsToTMWnsAwCf2EccjYDBG/EgpDgRs",
		"27ZHeicaJUgh/pd/8z8UaB1Ua1qzkAK+IdfUVE5rNWoXmbl0cee9rbpTD6iQv07hl2PH7lhdGiystZJsBUToeTeu5AvuDUoLx6T7dRXRmFB2VOQRUfl+YW+P",
		"gVceVJuNmtL6V//xr6fTsWAwqpQmRM3asmySuH9QHaB/ou04Ozs7iJhMJoUQUkq37gHAws35xQ+Wdb8cs2YeMkqekhJdBfbZh6XcxlH2wbrzuawJmhaqLlEX",
		"HABXiCECGcBac3oib15vXrO1vtrGzLSO3j2VSgQAjiedrS2Vy9nMSvmHQ2GOJnSSrEkQ5XJTwvjXqObpoS8cIxIdcrhtW0opXynP9xGgUa8TyVJxrxXptNzb",
		"2Uqn0x316ng83mw2Pc8byjEb60CgVTqdIUGs9SnoUQPVKh4Uh0ZEISiVihUKFa+2Afak2dqYdTQaicYizcb526GN+zCZtzcLguxgwO5rbv/qP/1dgK+vrsLm",
		"5kY+n9daDaC8UIPeeLL6i5f+k2AouLqx+jvvfOfXHv2Ln33jz9ibAaVGOBYiNhs1rVr0ggYwfSbSONng2nMF+8qvXKSHGZTLxz3ndtEQ2JKiUmz+wa9/aCqq",
		"HV6Z7wOSEEKy1osfLDXdpud74WBIs+6LRGatGkxYq9uuDcoM5m8cAkJWN3aJqFQqPfvii6H3lMvljp3lwi9EkxPglkrNyKgBSSTixpmtb2asbWwnU6ntjZXF",
		"v/D7N//Rj6p/v1y4tfehvsvEAIAafWpkPrziVhrf//3vCaLLly72SLp2a6K3eCuqWrVzuZz5+DeHQbiy6US5uGXLlNFR7wydKZh4vjf2GdPIg4Hv+4ZedLor",
		"kUiYln08Hjdf77QNvSxpEVE3UwARJap0Og0AmUyGmQuFghlVE6ZPNVlRaw4EA0R0UD04BcNuVHY2MTnJrO/du3fxwkVArNcb99/74OWXrlh2iDXfu3sXmJHI",
		"95obm9snMxNo1zZaGsqnDaNGfcP3/V/++79xpNtR5GsbqIWUqGB56eH8/PXuTYlZS5Jztct2w5m8mH/3537ro+J7LxVfnhdvsUZCAcBqSCsVO+0KbAGrfXgx",
		"tQ6DqSJEYzti2869u/c1qzfevPkCdHmEjcrjMUnhjUZzKjdlDuCe6waCQc/1UqkUAFT39/cKhXw+jwJj+dDS+4+uXryqPN3tS6w1l0olk0WqTt6KJ6ZKj33w",
		"x6P/ACH3WWeOQAwDtrDILWC3+UIIcl236TeOMw6nPlHgUS/+7LMtY2IihJyfvwFd4JMTPdbJ/AWllFIKEQu7G6ebG5OTk7bjRGOx9rJSpV6wzdBjZigUAgCJ",
		"PhKm0+nC9jogeFrs7e0BXO1RuR4hl8IMhLC4vNxGYLJWyoz9+WQmbPYY2Wg0mk332crq7OwskWiDZxiFaKut4dEV1SOutfXtZCp19ggyHs31a2rMXt2valY/",
		"++d+7nu/+p35+RtdYRqZueZXtfCbDbe5q6ZDF97f+oNFvEtIhpv15yJ/WYI4rpRxmAu1mQS8vPywbXx0znk0u56HCMpXROIrkU8bAzCjQHhKu4edLs1GL0II",
		"0Wg2Hz169PFHH9380Vd/93v/JiIiJjovP3jYiauXXnqtWCy++uqrAODWK5u1MgDM5IbAP/e211rK4rncEcWpTDazu7M7OgQbm9cj1PGVKT3nc9lRcR9bGE2z",
		"g3e6fChA1uv1RCJx85Ub3f5Vnfi1u7WWnZrprLHJ/AUhRDYVPf68MiBrcASfe2hHqiUx2NslO+m1tbXV+TqTSTuOMzU11XRd04pEOtx74vFkuVxsNN1wKODW",
		"K3v1ChE1m66vmnYoqLW2SGcyGaORZNKgXuMbRoB5YyrGIAjuv79sAqZjS9NeO0J76HRog7W1NQAIBgPtvLd1Q1qIlSerZ3x/rfWN66/ZttWh/j935XFgBHx+",
		"zM3TvXOxWHi6sR7bdghtDZp64TcEhCAICQUwsOu7mlvq2wo0RE5wd4QiJCJmEAQKDfrc9ToYkS5fvnRe6vXPYRogo0IvVnnmVXD/woULABgM2AEnUCiVPv30",
		"UyHE/fvvSylJ0PLyI1+pudm8+QSu6xpsFgDWarVYLEbstusBRyPbUCkmcAczC5+leZaOfVRJ2hPp4r4ftEJHT/DTgaMZtJRWs3kwGKCRiIiUUrtbaxO52U42",
		"NOZyHcwYj14gQ386BO52wisWi1mWMdBhy7aarqt81VmrSrHnNoyzMDNM5GaZWSm/09BXWpeKhXAgx9yqI5ttQymllBZCkDGCRlOvZ8exD892goRArdXa2mos",
		"lqhUSplM9uyUvO6k8+OPPw6Hw0JIrbVhqzqOY5bi519+ceXSZTibz5xtSc/3+fknuJevTm58eUBE2CekwudJtv/o40+Q6BRnmQu5fFhGq9A8Snmm5RAtjPcr",
		"M0vQ7b4NH3OeYBYk4zPJX1//laiM1XV95tuTz35n51h7prPXo/nrCHZE/emnn7W5iCClREK36TKzh3Dl8sWJiQnLsjpqNAbSYOi/iUSSCAX4mUzm/fcXy5Xy",
		"1ddenZ2d8bwhzK1avW70dFZXVzfWn+Xyc4eNiPWnU/kL0KWle+x91z3xnIr7tmU1Go2Hjx4D4PXXr0IXxNiSIhBwfF9tb6xkp2aS0WCl5oYcMc6JlVl1GD1D",
		"ij9DhH1xVKTe3Vo7FgkQTyQJhpxFLNsOBQPA2pQfNnZ6TGyLbX52uVQAgEp5CK8kXD0oLS0LEmWlcDILAPF4sFyuA8DEREaz3touAMDs3BxrLS2ni0UpEHHl",
		"2RoAVColAPAVSAmjxElOVyo19EIE+PyLzwlJSGt9Y+3axZQl5dnXSqPRePDgEXQ5w/epuXbXso7Q6zjW82zlk6JtO/FUGrplvzUIS3aRS4+sGYyROnz59BkA",
		"/tTP/sT/8Pd+6aSDocTISt17i++9/kevNbTb1J7fZW+vQb//3iJyj9uEUqpbNbcz/xcXl25NvfFbG/9qMpArqtKt8LW4P/N0dfPCCf1ivtEa/8aglVjW3/xj",
		"F2PhzLu/+VF31JBSSiln5+aMP2b3E0fE2ZkZc/oDgLqr/+E/+Adv3LxxNEShUj3EIXQHaADoDtAnqtQ8pwMgEUlb0gCHYnd3N5PNWlIy8/rqkx0pgXnTgO3G",
		"O1e2ea9dEn2EjuO0/ZhbgDIS1hdPViyJU9l00/VGpBtHjVIkHMSekJ0xgG3fh3KlPj13Ze3ZZ4OAik478ahzjG0TkQJIxuIl352dnVFax2JpI7ngu/XuD9wT",
		"ypg7h4BYPF4plwUxIbXR92cKn8w6kUy/dGVURDmYm52Dc1D0xTaMhAR1ayeh8n0GXlpaIhJC0FDzhKOf3PT0NBExMAIopZm122z2Lklre/NZpVqwpO26zZnp",
		"y8l4RilveCLMClgdOUkYmJXWpwjQACDLEcD94Ukf6+XfWPq299OD85Ztb5BWPlxIBPT9X3v3T7h/BpEYmBA9AecSoI+O0fj1SKUZkSRZiMroxEVCiadfrnYr",
		"GaVSqc3NzUQyzdoPBAJEtNDWPl9aWgJgr21IAQiFnY0b168OldM06XOrrtK1XM+XWHiKywILAARKyVKybNn5MDJLgRIRcYSS8O7OzuzsjOt6TVcFgwHf8xBx",
		"hPhvS8dqcnKCAQUhs5ISEVhrYEYUwveV9vyt7b3Ll+Y6bGnjjsF+g1EOGjt1rEAqpd0j0naldLfClRMMtnmkyjRKopEAIkbC06aGa67SGGR917bAtgCg4bsA",
		"8NJbb3567z0GNOZ4jPSssfPtb/0UFPaB+e6775pN3Ww+SqnZuTnWiplj0YjWxjOdHcdOpdJ9HsEn3VlHHZzjiaTAIkD4vIRzpbD67G8MIEoK0RFTvnfv/iiv",
		"LPOQ1jZ2pnvLcb7ySWNXMx56AIUMggiBjcWdHULmUdgtZiRSHuo6wJEq3toT0p4MhB988cVEfvJE47Dxzm4kYg8FuCCh5+ndwv7QVK3v/zPT0/6A7jG3nG54",
		"Z/ibnDlG3779Zidv+PKLLwFBK+04gZmZ6a9BjGZC0fQPAjntqSYCadZCULPpfvjxp7bVqgi/nU4DwLvvvkuEf/Ev/OLERKbZbCEc+04lS0vLpummtdLDmG+d",
		"9NmYqhltkK8sQLeHf5PXFwK44+3s4I4tbHNoRIEu1IWfaDQaHnijSqW+rxhgv1zYLxdmZ2eZORgIDGsxMTAwspSik0e3kmgEAAiGwnu7hVA4BFjmge6ggzWC",
		"IA+URzzPG2cWdSco2YkssQcAu8X9qampUCgkpTTcNgbOZDKe55V7lXlj8QQCl8eQ6/3oH/8jeeUaqFoyZKlGwwf9FgW97/+evPQKOcHDo0kLAqQ81+07LzGD",
		"1lqdgTZ548brjx9/2J2yx+OxcrliZAIR9NO9ZCKRIGTNfCjHB1gqV06Nylhb35ruimvr6+sd8HgsFhvlldXRVJoe6JcgGK2i+VHWZ+3wbS4axw4BjhRKbRVt",
		"bOukARoAGDUzLy8vDwRpNm4Jxx9KwoGolAZ617Iw7n2T5xcGZHfnXVqWwd3OzE4DfE0E8UixX65vBqyYgZD5bjOSmLh280dmsqGuQAA/89M/SUIkk8lOgIYh",
		"gtTIzNKyZqbzT5+txuPJ7qdTq9c7aIROhSWeSJZLRfiK/Fm01tnsxP/68f9hNfzp24lvNYpN0XZqRYbf++R3wzvpyOvxo5V92uzwZIvx3T8jGRiZ+eJLryWj",
		"ztO1HWOtckiNaYsWu77OBO0rl+eUf5i3ExIrb/bKQr1e971mZ7Jurj1t7XZon8iWEUUA2TMY0IODA8dxmDk9kS9srxORkIfiol1kGSwWj8mp48l0ubhXF3ZY",
		"a6XE8rtLs9N5JK4J6diWRcL3/Y31dZNjrre/ANB927zW+tGjx+f7oMvt4Fs+7P2Wznern+6Na198+eTypYuff/H0yuULsXgc+FxgV2e8SdVS2hneiMJvvXn9",
		"++9/RKfjq2pFQg4xwwVGEugeD5xvFDdj2aRS8VGlWKWel/eonJ2dOcoN5kVd0sYhfBZEzX5QRmE/plkLYcWnAoXGZ65LDTn59tvXAODdd97xXHdyctJEB2kJ",
		"rcD31dAwjQhEYio/C6AuzM2Q6DlblfcbzP2iOYTiq2yRogwEA7vra4FAKLU9gesIXT2Mi0tXGRlnAEkcK2MtaaTICxG5bqNe/URC3kTnToxmre1AmMhi0JVK",
		"ZSqbBN0EcAbP1K7b1FoBOcYEzthpC0HNg4oMn/jkvrlTMtWMZDLZyq9zs4Wd9aHiecVisU+rd3q6pyoCAOXiHgCUhPPp/bvZ3DSmJ3U296f+g5/7G3/rf3cl",
		"Pj1r2eC5X5XWTzqd3ts7qnKSSiWYsVgsdlzRz3jZtmP23Xg8bnR43717dwxw/fMaCkapKTi0VM2IyMocrXCI/OKYu2CpXB6y7cXiCQAa2m0eGLFEqcyl8uGk",
		"SsTCpcrBi4iNAF8beSo84sTPSKiUX9jYd5wZq3GwW/ykY7wuhBBCAGKjXi+VKqB1LB7rU1PqyCasr69trm/OTE+tb+zE43GkIICCQ0PSlnnVzuaKURFSyvsK",
		"h0UrLxRJBAKBXDZRV7W+vqCPPgCwx5aFY2VTzKlsfpQyfqNRDYf8gVIpArCgOmgmIoHN/YaMBAaaYJrDkRCo6jXnlwCZg1c+/jCqlFpf3wCAUChk0tgzdkc1",
		"8ygroz4x9b4AfZhNx2IAMDs3B1orX/1///GvfvuVWwDoey4iGmKU73mzszOA5D+3qI29J4tjm5BSWi2DXAZmWFxcwhP4sOCwCphnrMHL5XIsHj/an7BWqz13",
		"w0QkhuGTmBGJD+3GWZxnyHr8+GMGmJ2ehK/x9cK1SXE4FMfv8AzxKBgQavCbOhp0fv6nXjqo7gPAjeuvCxKatWYuFUtaq+EWKsyI6Pn+w0ePY7E4AORz2XK5",
		"bNu2lHL5wYNunK9BJhGhOb8MtYt/kcgNI7RP3M+huNlSql0aPDTE44lYPKqVwjYXWGuttfKHmWVorYWQU1MLjm0X9wv9nm3SRiIg8Lw1lBHm+uAJi4EtSYAy",
		"gFVABuEi0aFaMyIr/0Rgj6lswqTSAOC6bsuzWetQOGgyzlgsFgwGu0kuo66JyUm36ZVKhUwmY+ok9VrNsqQZFiEEsAHysuc2zQ7teX7LJxMOwXaECIDLyw+E",
		"oBN2agYFchG02yUrccyn2N7e6RjfGF1prfXS0tIxYRpHyipdvDBnHMrh+ZgTLi8vI1LTrXu+S0haq81g1bad22+9ObRnKFQTdR1GWiNhywMFMQ7+zvnd58zX",
		"OzqPg+s45wpLS5vUxEHq0SY9bFrgMTFeayUIM4lIB9eslG/mYyadMgiqYUl067379BgXlx7dXHhdCNHJoNvZChNRR5fnG3cxc9MD6sUzSUmdhlhf+4eAgsEI",
		"YXctnhmYhFXZ+VJ5DSRR3Hr23a0niGgHogDchwRgNvJuFgBrpr49mKR9Agw+tsI0ANSrRQDopP/K9xPJJGsdDAYty0okU6ViIZVKasZSsWDqBswcDAbr9Toz",
		"I6Fj26b11ylk7+7uzszM+L5/c2Ghe1uGYY6aDx8+NPPC4DqMMRgJOjVBDpG1hokET4X3mRwEvVdL7xYOxtEtKVdqlXIhHk9EwqFj+EHcUg9Qvp/P57FHqoKF",
		"lPV6/YsvVwDg4aPHsXhybia3vrEDRxkGnqbITAJZtTWk+Gw9w1Z7TsAP2SWfPHnaPYcQQSntOI6xhHhOefQQ2Vk8wVswg+v5XdrH2N08HLXk3njj1v5+9Xe/",
		"893u+Tqdn9jZ2fnk0y9833MCwSuX5r6GD+nUXN5AOBGJRIwyiZSt/rDbd4TnllGb0qqTx3TWPzOTtBFbzOuhFMQuUyFsLzMatGw5OkJ35qBh3HQ1tRUwF3bW",
		"O3t5OBTyNCF7Wmuzt0tLbm/tmBNPKBxWvqeVCgYDBoncxswdXrOzs57ndmplR498rdbQWgOzZdtCEAP4zRYZfczLmA/0zXbF6PvERBKVQG/M1p+pnJbLpWg0",
		"zHpMdSUwSG/sGnPVbADz5UuzAHD99WunDc2HnRtsM2XwkASEe3uHp09M2rYdOAJ0OI7ABZ5AVuoHKEaL3soAAiIqIeRz6t0Kgb3Osucato5cb++//4Hn+8zc",
		"aPT3nb79Yz/uum6luPMD9nRXV1dfe+01ZlZKtar2AO6ILjb1IuKZGQFZ++HEtBT0zh+8YwUinutvbq7PzoZ6vDuYUdg3Qv8j1p4AWKCqwFXAJAxgSwbamN0w",
		"1cM/vbO52uWVl7ackAAPANIT057nIeJnn30GAFOZRPv003pxpVwMhCLEbAUiRpIUAGr7hX6xERzPI4MBiTr2AvF4AsDqSQWOCyjVhpyeKKeSolCEnnYfg0Am",
		"qRm1FJSw9rb2oufnDAHD7dW7hFIfPHho2a36O5zKRtmcRx8+fNiWBtRmH++cR7G3c3B2IXwT36u1c+sPraxtz05PdH8BbT3LUSInzExCGPwPIq5t7k4f6fR4",
		"PjH67t37fY+w2Wik0tn/7K/9L1yv8Vwgv1/FRri0vAwAUlAklszn8303sba2Vq/Xa9X9fG7iByxM1+t1x3Hq9bpt2626KuERxgtmanZLLSvf1Yq0VkTkec3O",
		"i959995brfIiA3hNnAAn8In35y5Evv/h9mXWHwFzLJ6olEfCyCrNw/xgvzk8LSgW9gD2JicnhaAOTtTI6WnWjmPHY1G36SUT8WKXfODq6mo8Hu+41YQjEUAs",
		"HGIneGj8OjoWtnlPQ9SfYbjLn4oEfCFjhWJDa0trTSSYDWcDtktYLkc7TblQ6CyuT3Aib3gjZiIEdmT2uvfbMQWyG41mWwCAtdbBQEBp5TV9y7JMBf+0jgo8",
		"qh317gePtYadL5/ARPpchmJ2eiKdjA/W66WUvu+NAJmA7AgbIL6AAP0N4oKfG3gkGo0OOgQ+/fJz122GQuGv4U2Pa2g0bEVnkpGDSkGmJkzM6mg6G8gI9JX2",
		"EJjRqP2ZP1jYWQMGIS0w7ETmvb29RCKllTLGrO++867RigPm+/UfA0Dk0i99zyX8SAhEZDoynD3rqvY/OXnl39MC2CMhTFBYXdvqawEZbHWXjSw8ebpy8cLs",
		"if5KPJEyeiDcSTD4BNEGsVWa7w4FCAzUwi9ubG7UatUrl5PHvZk4e5lRa72/XyES09O5qamc49ha6+5g9O7de2PCoftolsWzgztahxs8EvjFnvLFyeRtp2zb",
		"GsJyZEAjRcIwG417nmeaT7FE2hTHFhaGiJksLi1zBwfNGn4gcR3w1el9tASS1p6VCuErly/07Zxav2hF1vGvdCJ88shut/kjUC5sT2UTzWbTcZxOKsqs6fhl",
		"j4DQaDZd12MgZB8ASqVCqQSJRDIcDmqljdIZExLXOjOfGVyXhRDnVzzkQSxKoVAw1Yx8Pg8A169fQ9Ddkk/mw2anZgo764FA4LBMMd5tmRhrAvQpCqFCiP26",
		"iLuFqYnsXhG6XcnZhGkAjwNvLySiwdCjJy90yxdCni/5IZFIIGGxUEwk06z8cqUMJ+kvabI7m9bIvitKBiVyJ0NiKOUrH9vKzsP1LkwxsHW2K+3FItNHF04z",
		"mSyzlpLiaBMiA5eKxT+M0eeh+0FGnJMCAWdo94PhB6cdUSruAEAimQJgOxBh5v3SbrWVHa+3fLnwUNhkYDNbO+b9S8VIOHiYHjKw6RO2MI5qZ3v7efdRmTmf",
		"z7uNA69ZIyLbkiBsYs/vmtVEtLO5KoSQlpjIzcbjCSFIa33akwnA2H7PDBANqvJ+NFhU3SH+wYNHQpB5Dwsbz7aCyWTuWGIhnkeagkixWByYg6EQEbLm8/JL",
		"DQUsQy8qnRgFb/Q6mqgbx+A6tHuKPpmxTVmYXzhCWXT5wYOxNXuBgYPBFkHAbgUS/MMYfZ6pGLMeLaWPp/XQfV6+4ABwsF8AyJ42Uhs4mhCChNUSY2o0mgxg",
		"S4F4ejJpLJ4YmRVptqSYnZurVqsnwj8cIw7EsLO5apbSZCbROW1qxgfLy/uVfQB9/fVrE7lZ0q5RFkXE7Y0VRHA9DzwPhQMklbGgP+FDy+emDuqNzhFkrAh6",
		"qHOtZb86aw9fUCs1xixTZ4rZvUYMdN787obr6/MnYJ4DLd33fdOJOSIKMwMixlMRo1ymNY967fzCvOPYnZI9M7/33vuIEEtE2g8UAZgElc5PX+kbH6MNiLUb",
		"WXRsL2jQfMhMYH0qoZxTV0g2NndyU9mjpl0rgOKDBw9u3Tq9adne3i4ATE1NGQtHQzvOZtKWkEcH6ampHCIg0X61vt/Ll62US7FIaDSGnb163bGt7NRMN0jj",
		"9Cd0QUQIYEBsrEBapBGh6bMTCF6Ynf7yybMOTVijNZlJFHc3WqQPIeuNWqm4OzU1FQpYRI4pyQwq4xwxeZRSAKi1GqGYiMfwtVpzrINU68k3x4k85XLpzKuj",
		"pw6DCMO07lp3+MmnnxuxoZdfujxeeboYT6SOs0Y8Njofp7XJkI3EdqqV8d3CEsnkOMOLCNffuPjovSc0RkP4EPXbmgtILTs7eHXholI6lYr91r985+mzjQtz",
		"uXPRvXur716VUo7z4vwM+7NJ7JteJ6AJHBXuuh59fmYWQPVN2UaDL1+6kEhlS4WTIfBWVk5J08pNZQGgVNoftdTzuSyA8bhDPgeP5M0jzap7xioWT1XKhc3N",
		"kUYSyVSGR+lZIzY9b1D56CzXxsZmNpvd2dlJp9NCiO3tjXgijYilYuuvXLrYgpE16zVgdtufjYERqVLa6x6BZCrlOA70U0v6B6SHd4FIJF5++cpnn302ZjZn",
		"SpzxeNyc0DsgV1OlyWQyvu8jUbFQgDGgFIl4vDQg7DfeGsFTuKG88vKVE70+nowQeWOIWZ9eU8lYTicCtLF9IMdr70/nJwTh0Ul0q5uq+Pd/+yEAxGNRx8Eb",
		"12+M+cHfeustRPrsywdaayKife/zL9afIALAjRsv2ZVqabfspxNnz6O7UbFfDU6c2jfSm8seXyZCRM9T29tbJlUc/AUzj4WgI5YWIpkDLIKGr+iKJzPdh+hc",
		"Pr+xvl4pF0hQJORopc9X2oZHnysR4WiVmXgiGQ45vq+Gjig/H6k0AxrzfYUt75Xhdc9R34cePF9hqGi9OqLmwKC1OlGFZHNjAwAikYgpr3USNBOjbdt2HJuE",
		"KBYKfabD09PTfUHVRJlAMNi90XYS+h4rhgEjVCIxqB9tdLHPse7d0lE9DQ8LkVmjxTRc0p0BiX3S3rfevP4H739Y0ihPgr9CPC6/QTSo59xUzpBktFZ4wrWm",
		"WWutANgD0MyEkIhHNYAmiQHnrHn03Fy/7t36xmY+N/WCI1SL28KtYM3MJFAp3lg/FzY21usNEt4hdW3EQezUHsxnv8rF3W5RkE7ewcoHdpaXH9y8uQDnjVQ/",
		"bTm6FUNGVAaeS/O148c4PhIxFk+1KzOFowU9BJk6xjExi9s9DTgBrkAh4sLCQueXFlrOtjw6C2bWGvCorkd3UzebTe3sFE6o1aXGRHkfk90nk8FAgFkbWZjA",
		"VGTwxDamkQeA4OG1Dmy1o6FlJXBi5suY6+G0iQWzvnLpurl1pfXmbt11m3ttIzcIB88ao1dX13qGBUEptbm59Zy44CfituBpWkuwuLg0mBgWi0UAWNvYOrpb",
		"SIRfH8GNVuFlDDfqUzjsESEiLi8bMSkeW0Tt8Bp0wzMK3afDc597i3Z6erpzG7Ho9KgAZ7bD4f7l2PXXEABYWg4i8eBha/RNjRoKo2U8ok2N0Cdrxy0S1nk9",
		"fd/3bMcxJtZnSq2IhCCljOAZ4Oh8efRNjq+ppP78X/nL//Lv/t3Ptrc3y9VXX77cJYf99PKlC/1bbyaufGVJqfUxYfqYyd/rHz/Uo0qKFudLIBMJrc4zSZH9",
		"yixsVLW+Dig0g2o8UTIuiYbBd9rzRvkKEdfWN6fzU72UMF8I8Wz1ND6+6XTGNOXGuXK5XFu94ZgCmfJVJGTb1uT21lYsGjniFI4AWutMOrO7d4IScN3VYcGG",
		"84qIx4uoDSnd4jCnPtb6Oeqdj79xK6WGZ2U4fBkuzM8fo90BiEjwPDegxx99cu21V4yh+xEfOpPNstatx8Aspcxms1prJNrd2TnfYTxesIN5fn7ejMoR9XE8",
		"Rvp6HE0l/KW//w+iJOITE4WGl81OGLS7bdvDxQJ3ywCQyQTssylbdNc9qMXUNTIogAiaGfThDmQkFJ2AdY6zQt67995QLvhf++t/9XlwwZ8rqm2UanAXokMh",
		"4mDZkTUjgvJPw14NhYJ7Y0NC20w/HuUaeajgjybScTKZNGIIRxxBpBDHBuhEMiUIGcBQoiulvUrJ+LOkY5GAMVDvsNHSmaxSiogKe7vxRNKSEhDcpluplNv3",
		"3x+mtWZBWD1olkoFAMhMTLLyEWl3d+ccm8rjl1FMaeRmLwB8aWnp1DGWW6I/497A9MzM2urJMC3XXnulPUtHdg/iiXQwEFDqUFNMa7YsAcDjw4eHDsLde/ee",
		"244JoXCYtaKjKhXHjK3R/tqpNwHA99ydne3uPNqy7dnpfhDF6vp2IpkMEOohco/jbkKBQIikMDxVIGTfYz6uMMLPGR+NiIT4deFun/xa39zJT2VPYzx+qj+n",
		"T+QMgYB4fMrWCSiChBWSWulzyXsY2LIcGUj6jcPKd6W0Fw3nuyG0rNlxbEAURIU9KJeK6UwG9KG+6FBMyPLysmwrdgY0BjyvRnj+fFnm5yf4gl2tt/7pwMAM",
		"H3/84Yspcx39U6211twhK5unsbi0jKhO8FEZ7t69/8Lsltyma9vWWaor7773EIWFrgKAl69c6v7RYKGjc5Yymf7y8nLL4HR+/qSYa80aOzmSbsMoO/2cgSot",
		"8zn3zOVggFZaub7/Io2yRhronOqjHhGgbduuVqtzA26NjmM3m43LF+eSqXTxhH7PxybvfSF6/EeYmZzpYLaMmDKciXlYAIB4PJlOBAhzndlJiCSIkAKh0Dt/",
		"8E7nwAGAylcmGexzOeFekYfe8pQCAH9n69n6mjd32dGNc0aiED0/6yaDH8fW3CNmQIEdgPYLzFuOgQkjwvz8jZ7VgSfLarDThMF+FdnnIfkPAI1Gw3aO4JLw",
		"sZpKgKh9v/DFFzA10ekJI0B5dEP4W3feICIiRCKttHG06XuNP9x9omVRzcwtfwnm23fudIqLPZ3Irk90/949JPrFv/Qf/V//9v/5ecVoQvR8VWvUz0JCO6d0",
		"CZnV6tp6HwypXm8cQQ4OhyPTo22DmYdPgkajqfVXhro7tt4HABvbxdxE8uxvaFnCti1gbbyglNIaQbts27YlhdVSCyVG1AxEuPrsWSqdKOz1ECiCwaBmBhFA",
		"8Nr4BDQxrlIuAwDaTtCynb0tHQor53x4UkYj9HmQbk3rf2n5gdbq1csXiYTW6pMvngopGo1mB6AdiycQ8KTHrW7qykCy/JXJD9Qbrj6oCWkVCz27bz6fz2bS",
		"PKjd2ta7YOaeqjefQCfkaKEGQBrdMzQMAQRgPTUBAI8/+vjaa68iKAD84suntVrt+utXYbThMgDEE1EiWt38opdbhLnMLB+FN8F6vW7ZtrEBGSdr9GoH/+jv",
		"/r3nmEcrrQO2nYzGhihFvcgsmpCZhRRv37l9lrx1ANM+WatV1ze381MT6UyGNQMCIRpts3g8YUmZyWSMjOSxhVRXKFuJYw1DB9QNEfjEQB+l1NlHNZlKBkMh",
		"1ioSzyilXnlpTilFSJq1p0TTVU+2XSApGutH/2nP9wVRrVoMBYPGYNCkG1qpwNaOdOyDg6pmsIDZtuFsMXp6dtbzQQomxP1qvVzchfPHfQohCABZUzSZJkKt",
		"Wcg1EgLA7Qf/nXBVCCGY9dLSUjd0cnFxCZGEEEcbCT6PK5nKaK1HqWows2U7gz2Szoc2Hi7xeLJcLp5T59Hgky1G+5hmAEpuU88ECQAgspTyxrXFYY0M5LuH",
		"TkOdMj8fJcS2sbERiyfj8egxMZoZhWStdj79VCVTz7cezczqq04qmfnO22+Wivt/4uf+bOebf/rf/VlE+smf+DEjIYbjl7EZhBSrq2uZbHZ1Y+fmrTe2N1aE",
		"FZToIyIzBALkBMO20FprAAHAQloAsL6xc4Q5xUFjVzmRUGh2/BjN8BUcTUp+eN+3Xdd7K2u0YFpdU1/LWCRksolCuUaocwlBQtTr8XKpnMtNIRIJAX4jGom7",
		"qstzi3S1erC3r8irhGxLe74QtLKyAgAwmQWARCothdjf2rQsq96mvZRLxdPVH8gIWgihmWOJNII+Pn8zhULkwb4zM8cTiY63erlUqjW8UmEnm80EAkEnEDAn",
		"SCIKeGqlu8hjVLdOmPjuVw9CQQcRldKHlBPEZrOp9DDpj85f6oF8jZWzjgog3aQY80U4lOtdLUwkKvv7hix3Y/7GET0S0rrcRvLz2AWWo7F3pBptTaUjpkJT",
		"CDsbCO406r0ck3FVDDWAN5AyMR+er3sS7O4lO05bBZERkEFGIgp+cDSVkH1/FHrDBwhHgr/z27/e+c5yG9nDzEc9GR7yDdQaAHZ3dmZy2e2NlU5DPJ7KVgrb",
		"vtYEYEwQ46mJ0t4mad3hth2x/JSPzxunaHpEZ3mHhDxIyAMIACrHc1lK2TgoBcIJRFRdxTghhBOwgdmKxaOR6GFnUDiAYEsGANdHc26Nx2O5bMLRDbdeRwTW",
		"enJiQrW7504gAAB+o0GC6sAAEItGThejAUCxIFQIsF/am56Z6T41G3+ZEWmTBoBgLyfNIB9isVhXcY+KhZ2V1fV4IhUIolKKCO/dvYdCuhvr6HEkkySgcrkg",
		"pSBEJPS8EzzxSrnk2FkpRUdsz+AdPZ9HMWuICEA/ePCwD89+NMwJAbTmof7IzP2kmO743ynIIHLbPgyPWrMM8Xi8XC6372qs0ZDyGFzdGIKCaABvAGDcz7T2",
		"jLMxj7EG517Nb362JZCsmNMo17lNP1leftCydTaNYe4lTJEAABxXk4cBwa3XwbJ/sHTveHjmywBEGIvFOo/2x378xxGxVCqclB/34MEDM/ZPnq5WqxUAuv76",
		"a7Zg3wfLstKT07Va7csvv7x48WI4HDZuTEqpycnJTCYDQ3UtGBBxYiILAFr72Wy26frn7h1uKux8jhrM2tcKwZLQRpV2Tu6ffLhscjdjbUhEJr2QTsj3fSkl",
		"ANRqtfX1dQC4fPlyOBx2bAmuFLaDJHzfJ4nBQKDF2HY9IaiyuxtNp40j1tCdLJWUhWJLhe5Kjj/fwKEBS5qaFGK8DUMkK2gi3bOnX169epWIXnvl8jgFUNP2",
		"MXve/Xv3iMis9tmZPLDqgXYwNy2boZmIx7TvR6PTpqMohGg0/VMxJNtlA8OX4ZHJVrPp9UMFWnwaPk6WQ4eCznDpZjyKqbG0tMTMcozCi7EtlJaIp8LmtNGX",
		"SDNDLB7uK5RUSlUyoOLjS3yjPiO+/eb1dz/4CAMONGqvvXwFAMw+0ZFqGQckZv4NxAPcAhE4O5srhKiYNUOHjm5mFzMYP3scdiAbTKYIkBlSk9nXfvLN3//1",
		"P/ih0L1jNpksn919tdXUYnz1lUknGNb+sQVhFoKkHK5S3x22tdaBQMD3q18+Xbt04ZzJmcYVxdzD7tbazZsLmnWns7K8+OBENDPjJjUzMzN0U0Rs5QsIwNoH",
		"wGgiq5Qy0VxrbRrcMzMzRvnTQt+KhgBDt++8+XRtd2vjGWttrN5isXgsGsm88jJa0jJqOFql02ki2ukiWVji8HwQstXQ2WjgUwDge34wGBRCQLvVXqvVWsWQ",
		"E4I9zIvfun37/fffH9UPAcRNYwxmSn+6ZUjIfIpJyMOU/EbSHLqRvyd3sVg73e8Kwr294uTk5DHAXwYhaG+3dQJIpRzLsrszJkSolA+GIdj4iEYMY8dkEmHU",
		"zwE0Q9wRO2dIBRFAA8uqjwhK84E6qCNbzXqhVIVWUS5860cuf+fXDP8WouhPprJ2JMq6XzCnP09E1EqhlKHs1DkG6G+ANiniOVRwjUsxANQOypl01LblJ597",
		"s3PYbun07wGReEYIYVlWfjI1Dnx7efmBlPLShWkjF3fugyBlS/p5aWlJkHzr9bfM35YsAZnl8Np8MpnSwNL3g8wk6Fm50vHZk71kBwYGRKXV+tpq2zk7z4yG",
		"w2ZSY8uyTEy0bdt41mkgpQ2xA4UQzXoD2i6IaKw+omHQLNqHSrKCfdGtG8DEI2g6tWqtUil1E0M6kh1EZBxYzmDQxEOniu/7zByPxRjAdV1EuHXrlik6PXr0",
		"+Cs/djLD8vKDjj9Dh8F3liMXA8QT8VOJqBz1R5PpmNmhjYL2UEUUZNZoa+HgiE4c6aZUNUBE1iV9SuTls4/XpRAaQFWaptGi6nX1y/9D7Of/UmPXBYDY9rqY",
		"zr/+4wsffO/BYRoRT8pgcEDiChBBIAw5HDIz80sv5z/7dP2HTj/63t27RlDHc10AvnHjxil4Addfv+Yq7dYpGR+rhjVmxsTAliVnZqaRxLnHaERcXV1NJhNa",
		"cygYyuZmtuZXNCMiPHU+dDbi/j2dGwhV8XjCCrSOnAaaMBGKOxauPHvGuuexVxsKB3ZCzcSt495hr8nkEUIIQ0FUGiVJQnJVHQC83QLadmCvWAcIz86y1rF4",
		"pjOAUsqdzVXFcqSjKwwxEECyLInxRNJQn7v1cYQQY+fODEja99xGDXulAnzPjYQDlpVdXHrQ9qhlIlLK931l+oee51qWjYj8QvzrPO1MJhqZaBMAPlkLDLNv",
		"ZxLEzG1PbtCaEVEIelEoEY7GY/vlyji7gkElAx2v1yGP8mFBQALWTBSH5u4pTcIM1lFbAL72ERgs5ftuvV473OJYO5LK5f14LFWuFDrkpbff/pbqhVEjAg2N",
		"0QAA2GzoycnkB4uf5nOZFxqjmZmQ4Lij0BGgPTybbbvv+w/ee+/1Wzfbohx4AlIVt6AF9QMyqr7clbmFQqHZ2dkTIToH79DzfMt6HkpvBADFYgkAQoHI37n/",
		"3838e46vkQj9txux9+aa/wRH7UnE3k6hMpGKmbnme5hOZ4QUMCB9CcxENDs3Z/7veR4AV4rbJCR0tVFyuVy9WkLEeqNZKe4o5b9+/cbiBx+EI+H4xTkiwkQ8",
		"qFm5nrAtUxIxUvGtrlD/njf8CQZC0c7XtgQn4DB3CTq3tMLxHPiqA5uTaUXYtuM4aCQ9Z2ZmfN/nFkCYTy1pYPpyDx48NOWC495q5N8ql4uWJcz9YAstZ3me",
		"Mhvn6Wba/PyNYDD0+ZPPJzMTjuMc3aNGwP32mex4XAcCAs5dyWYTc6nkxBhyC+cPe5qcnOxow2YmLnUGlwD4v/jbpQ8/1pYFAF4gZAur0fTiiQiAG09EyqWq",
		"+YS65b/DndYCM/jDns/tO3fu3btnoFMnQseZd35j/uqAqBfL8Y9CthC+rzTwcKkaAAYQhN3emn3LwTszBCJjEkYeC2/X9/MeXMFxCocnqjkuLCysbe7tbK6e",
		"r94Od7wCuydcbDLDjq+BGD1qTERmPvGfPHz0WAhx9bVX+95ht7ivtd7cLUGLqYhCjLhFBAbwXbfzsBDJ85VueuaUqjUzs++7PoLWrFnUalXLskOhYCAYBIbq",
		"/r7jBJTW6YlcwBJN/7B+d9JhYWaBanO7cPny5WCwVSERQhwcHFiWhYiu2w9bHlK1GOPv3py/bttWoVz97//hL//sv/PHXrt61XMb3CrNU/fMUkpTr6/KqCse",
		"TzuOZNZaqWw222GKmo4cAiKCEIKPNv3Bo6Ta+vwTspnk7m7xnLrKrQu66ngwQMybmJgw8E3Lkn1iMsyQTqc7Oi2G9UNERGc1IH7nvYeA8kRTaW1jdzqXsW1L",
		"KWX+ut3FM2QAsCwSQq2tgwjsRqfCzebDP3gErDtFGUls5P0UazMleFjkZdadSfHmm2+9d+/fEonZ6Ynxb9X3vKFRVxDJ8deNFLS1XXBdz0jzDAY131fJRCQa",
		"Dmql+itPzELKU9C0uhEOQsrZuTnPdbkviUYQwupbOepI2JyRu+V2vmwmZTgcJiJTbMWvgWLJzubKYPDxle+DUBq1BB99T7uAaDsWwjjnXBayf5ab/ls0kZ2c",
		"nNzc3BRCmJiyvbFCiA1fd3N5YvGYFEIKsbe3l0gmiIhIep4HUpbL5VRKMutgMKi9Zge91BleOCHerhPdeq2JsPMdy7JM4diQ34bR7vVo5FDruv/+ouv6t29d",
		"f/bsWalUMiT4Nm4WDLBHCHr8+LE2W5OUx+V6ynGCvq8ADmnEHXliJFRKrayM1FqyqMmMrE/gvIN4DuT4+/fvVw+qe9t7fR0aYTo52KcEx1JKRAPX6esDsuPY",
		"QspuwTKhA4l4xveadLZbJUR3POBjMhYqVmrTuUwyHlZKs+aFm/MDUpoMigGxsV9N52NJ20awhJBk28gMCJRyQJBmbtQPTCZNRFJKrfvDW6NW455GtyWlncsH",
		"NtbHldK8MJs/p1oHkZRiMH4xg9lmjOvBYPP2fDiLRwHR+IQqeUiCNPP2xrPJ/IVRcvJfh0J893RvJVgInu3Z2jbwXq2163kA/lDygkERAYBb35dSrq6u5nK5",
		"ThMSABzZ+mJra6sj82iCoVK60mtrUilXjGVMIpWNRoJaq/v37iIACZGdmJBSsrbKxZ1mo5mfvdjBMHU1u3j8c9/ExES1WuorCpglHo6lENHcrZRSSum5zcG3",
		"UcoDbvuHIkrLZmA9TJ+h0WgiISBSn3QcYq1e9z0fgC3LJiL2fdb+scnojRvXD4s8iN0KB8cC6ov7UNw/xrwjHo8LIQIBx+jB5vO5DldbiCHGK92kmMHjwPLy",
		"AyEEAx/UDoZ2AcvlSiyebM+BYjqddhxbKb65sNC9sg28b3Fxkbp2ZURsNOu12n4wENJajSZq4vF0CtYr44kBaKBUMmGeRT9Xsl83nonI18waKpVqMpkIBWyT",
		"ZYakxQzM2oigmjRxUPHDbL291MzzBM3KE7sz80Ctg4EE2EGu1xgABSHr3q2dgc8Mz2gLmkC1Wjm7l1epuCdFhoiEoM21p+Yud+v7h9KgAIDnoGR0dm2dlWfP",
		"vvjy2eVLrUqxb3lcFplPs6U3igTkeX4wELz0yszQ32/WKohgBaLd3zw4qAkh9verQdsKXpx58sVTZrAFUa9smjkYAUAskaqUCn2WMQAgKBsMBlCAI6UBIJpD",
		"n1LKCThba09QynZXhZlZgRwpAN937nPrrQYas21ZvvKNGioDR8JhAKhVD5Ee9arHzDNDmjNsDAcsywEA1kopv0OC6POEvnJprlQslYqleCLJzJW2wWu3HHMi",
		"lZWotX/s5n0IIBv+yvPY+2PxuFa+1vrQUAc6NuT+9PR0t2SCKTp19xi7rbZaQlVCgOZKZX80GafY5WK8NzMzo7U/ym2te7EjItm6Vj8IhiKs+kCvbBJtrRVp",
		"H1C0ukRDC+sIWqm9lfX07PFgnnKl2vk6HImOaveyAeTOzJUqVWh4pvETDoeZ+eb8DW1yAsSuT4VjFj+XlpbPS6BRnh0b52sIWPAzPzPxm7+x5Xm66fpK6QGU",
		"lbZsBCT42ly7u7uZTMYJBLgr12sbP5NSir9aQjyzgXB+9PFnnfSWLHpt+1X4rwAA6m+tS+C6VxNSDE1FHQt8DxHAb1Y78SKRiHe658waELXWpgalgQBbcGNm",
		"1koHAs7szAwzR8N5EqJeq3dXQvd2dyYnJy3LiiWzWuuNtaePHj2ezudm5+Y8z0Mkt3oAlgXMiCSlYL85yiaub7YUurSw4/FEtyW2FF3HOAYGlsZRZsDSpCUx",
		"COB5vrFdZTVg/GdqaIJm5+aM3ptpWiSTSWYgQsu2tzrOT+wjWMcu0rHNmY6sTlJE6uqReAlfKXXz5s1hbBQgxG4Fx0aj0R2UTCbo+77Wymi4mWLREQF6wNAy",
		"NTYDu1WYFIIQWBL3+yczg7TAigFEAXw0EUm7Q/IwFELipZcuVpru+aJ7eYSt+9ckWslzVHkWhNVa/aBeH3yB76tUOh4OB/2B8D08rUD+4L0lQOyrmCOAgRwM",
		"YO/4dGF6cPKVSwWzSkOhkNb6+SlhjiE1A4T42qsvdelJrcbj6UjIKeFqxs8qbqZDk/u88ulnXwghulV0y+VSuVzKZLKyI08OrH3f2Jtm0hm/LRLfNm0CQvS0",
		"PizQIzBrz9eHtTulAGB2blarFlxPKaV837Ksnc1VRKoeHABAR9xyb30r3dYgnJ6Z2d3YOEoUdLxG/852P79jYmJCtpAqOMQTgOGwNDHSxgm6CyCxeDoSDQ8L",
		"i0Ym6kUo1ZXsK5nG0jFwiWGRZWFhYXFxqVftA4Z6tEfjif1yCQBS6ZSUUiuVyaTb2EQ04n8mUrnNZqlUOt1yIyQGZk8eVIrVagVAd982s5555eIn/+I39j78",
		"kgLO1Z+58/DXfs8OBSb+xLeIRF8wz81OfPnpUxkJwolj9FHSPgYRf/n1S3vre+ViJZmMsz6HXda8eTYd29mrfMUx2jTBPR++851tzwcphlqCIjMPcwpklKIX",
		"ZoR9FpB9KObhLUce2iHE8Q0BPvz4E+X70nJeewUA4Isnq7cSqedSj2ZgBs2HALIj8VxDfoJCoMC4mkn8HaOtwG++nQTAjuaRaXg2a/vlcqlPuq++u7d3cDBz",
		"Yc5sAKy5XeJnRPSVLyzHlN4QMTs1azp+5ne3N561nojSHSssE95bjBJkuxd7+Nqt+YA5ASCOUD45LIWnZ4ee6NOOI5KpFLRrHa1sGUFrNjnvONbxRx9LFxd7",
		"zFkq5b14LKS0Xl9by+Vy6XTasMBt2/Z9n+hFYJAlnlGWB0cp2x2WbiKhaMAWJBTr9c2t3NQkteU3tdIbm5u5qQkAaDbqoXB0IEaPBUlqMYyYL+Rf0VoNbm9a",
		"aVUVpSdrD3/3t0PxRPpy6qN/+71gNJz4469PRK5IIfsw6Stiw7Iwnw8biOQpzG1hhOHt5GSksLEbT4RJ0HHCZ9wNDMcR3muI6Cs1foB+trYxqk0qz+Ww4Ctw",
		"K2AQ9INP4ljWNQ6EYCMcoZTeHEi+Jicnh24DR9+j0mpmZmZ1dRVhayJ/m5ktoREwPz1t3u3xhx+99sqVmdnZ6v6+oA1g9Tz8PkiQIGG4akb64Ahvw44weU+G",
		"VdgOh2Y0+ws3F5TSQtDjj77wG1VxiB8GPeJIHsykZzLpXD4vhQgGA+nJKUH40stXAODxR58BgH9w0AVFOETUmPpPS7uACJSazM+ZCsNkJr69VzHo9UsXL3SX",
		"JgKOw1q3TpOnuhyHbNuScgjiikgAinJx9+zdaLPg8/k8EpmDOTMTYi6XA+ZAwDl0MNBaWtLzvHOfGPFEGtgHsswz3CjzVGwyIDwGGi7HegxNQSeTyeKR7TWl",
		"ddNXiLy7u7Ox1kKCr7WJptW9tXo8ioh7myvTl6/1V3tLxdiwo0a3pkc6nexEWGXK0ANpGjICUSged0KRf+f/9DdktRqIRCKp+FzmqjJSYoQDzNCWrMx5SW/f",
		"vHlrb/vLR+9/0RLoYAaA+UG7FtNWQ5TS8n2fCM3dKK2Ocy2A8dx75ag8/2QxGk3mN4yKIKwjzZGP7Blq3QpUA37yeI7SH0i0trE7lfF6NFbaqWKnkQJtRlks",
		"OQHn70bhMTc6Xg5SCCEMNG0IqYEIuh3q1P5Go9GcyF/oCBmX9xu2bbuuOzE10+kICSFSqeEU9vr2zr7vA0Amk1VKFXa2Cu08e2t9RWtt27ZlSaUUImSnZvsz",
		"I6She/BEOraxqoLBQCAQRMRAYMKMru+5ALiwML+8/ABPa4yiNU/m57KpGPT6cgEDgn9GAnQX4oGJkLANS2YAYGlZxgZhfmG+pWeC+Ojxh03hn04W6IgrFgu7",
		"Cux2jp7yORl1pHAAwPTquuvLsdhR53FE0EqHQsFIJDLyXhDr9cbyo4+npzJTU5MAsLG5BQDXrs5tbhZ21lYvvXojEAwzcDj6uud6o9wnjMnsELWmLkuzw5/y",
		"cA1WrZT2fW2+8Pz6vg9osW4O1q9ab8W8/ODB+KPMwAy8tLgE2Aq+5vS6tLRs+hNu8+DK63m3DNKy48FAJDmlh3FtCEn5/u7OplvdDcSngBgRLeHAeRTADK7i",
		"/QcfjVXr+JFvf8txnLvv3uuz5RaE9XrTGKHzCRNtrdlxbCnFws0bjLz4/nKPPY7u4msiAsCtNxaOoFrhcbl535DduHH9wYMHynPnr1+NOcVaG3zXuwlw53Bh",
		"vl0pbsN5UDm7r2Jhd31zBxjyueyTZ2sX56aTiUixNLI7lJ8+FGkS0Vw4CgcepAYAv0drqHYuOxTkdl9Ia939Wwai5HkuAEspB/uliC1zQmxpJOk+UVAEJEHM",
		"0KoGtLpFHWHV00TpTjpAhP2+6VpHwiFBUisNpzJ+NtNSSvn2t95mZqTetiMCAmqtmXWz0QRCRPB9BczKd4/OyhFhefkBDkjNLS0vI9LQgfB8tXYQ/4U//qrr",
		"MiJ8yybf57t37wHA7NwcMGutw7Oz0Ca8DaEg9IIKdFdJanB9EAlgrhSL01MZy3YilrqcTypV36/4UtoilNjZLaRSGgH3CsVcLj8Uu2rZqJUa1FSYn5+3pL1b",
		"WEvEsuODWAxlAYgyFwSoCmAQQJ+Th4MURGY0LGkbSV5NQJalPU/a0mtiOBSFuqc8hd2KScxIhwLTKESjXq/slxxQm5sbTA3bCkxPXVHKG9FUe749QyQhqa2U",
		"3rnpUIhanrh8ws6pYYUgPFh+BADU6s4PYQe2ePGsR7uLMh/p9PrgwaOOGKQ5EN24cePGjRsWKekk3r3/Hja/3NrriS9r65sGOlYpV8rlEgCTkM9Jjb9jt3hx",
		"brpPV2gAAxs+qq2032rWb29vO44zTi4nIpHJSKQDW+5rXFuWZRTXcrkpbjNoOicuIjJSbeaQwe2rVYDKz/m+b5qNmUREoWWhbzsOwHNpsjGDEOKg1igW9gyX",
		"b2TBqKM3MlA6ND8hQiFoSM+SmYEFUX+gO7Zyx9x5t2FaPDy0P4qItjTPBAnBdaFj/MzMlXK5DdxGZo3AoVDoxo3rMExltLurOEqPdGlp2bLk1asvZ7NZYJWc",
		"mG4dkpTvOHYimSwVi0JYAJBKxIduK6YznMlkbLvXpZCBSDTcWr1RSyWlVv44YRqJtO+zx+FU8D//e7nS3mcfbr4F4AKcQ/Xf3GoylSDE7b1V13ev37qz9+kT",
		"d+2ZNTW98mwlm04+/Xj39p07qNXu1rMWS0dzC/XUFsDQWkeisXQqufL58rXXFxr1plZKDZXQNHghpNm52Uq5YjRUz9kXXCn/3K0nE8kkt7MA2xJKc7FQHOZ4",
		"Pw0AUgYASQiamZnp3Jby/aX796amJkkIx3FGrUrjTsTMujV1sO2mQAaEVD6offRJ0bE0MzaajWtXX337zluIuLKyYmqpFy9Ma32KevRY4SiTyTiO09F/YIZQ",
		"ODI0tnRIEKPcs3zfF0IYTedh+ttgDEcsSyqlldJCgFJKSrsdo4fffa1Wi0Si7VgMbSJfj2lWJ4/e2i1vrj1ptxAIgNOJV8+NtTR6qElQsbD38NHjn/npnzri",
		"AElCfPDBoilTaKUBsSMX1+PY0hXkEVErv7CzQ0SPP/qEgYWQhqTAwNZx8u2VSrlSKc/Oznie3ylAdXDKQojd3Y1jD3+mU2s4AUT02WefddhAWuuA40xOTgz2",
		"yU2A7lJP5SNmqrTk7Nxci/NA1p07dwDh3rt3GSAataPRaGsSBYOjQsHTlY1EIuE4ztLScsvt3uhgIHie6/kuIelx8Eu+YuV/92//32/+Bz+nPbe5pxlD51vq",
		"XN/YjSXDL9+4sF8oOgyfP3ofS9WD7Y1wKtk+8jEBorSa1VIolgoEo0YzfeWT99O5y6FoAhg8z2WEeqNhAorvN1sR/AiFQq3PnqPIoWRCrfXHH3/sOKGLF2cB",
		"YG1ju4Pf6ooRGonMZj8zPQnH00Z6IvIXX3xZq9evv34tk0m3zZgBEdnYODVrCAhdBC0z7Zr1BgIKIQJOYNQTFEJojQbDPzGRtaSwBHQbTGjlW5IuXZobGlwz",
		"mYznsW0LrfW4XtDMu1trRALHVmJjfQgUHf4QGZj1OM83n8/PzMwwc4/TI8Pk1KRtWVrrlgAFmFI7V6sHphOolOosg+4RiMXiLeMr899EulLaS6cSQBRPZo3K",
		"Wmlv0yjvT01fNDkq0dlS5mFDzb099B4DcqWTqfT1168ZHsfS0vLQt1SqJfyslHKML3VnDiMiaxhCumZADIRCRGSw50QCWsL8rbL0GI2HppSyXm/0HTpPVKMb",
		"tB5u4xTbvWbmpaVl6JInBADLtleePWtBEo8AoxleESAivH37TWAFDHduv3n33v1OpQuRjsjVLszmSAgTLhBRCMtkHUJIKS0cp62HyE0Xv/3yT/7Y31RUi1Ly",
		"5759p17+v1DqnDv2+VwGNHyyvDJ7YdJBkki+VoiESDO5Cc/3r7358veXfseSwZlIvFQqNXd2dqvbDDgTjqysPim4VSkoE84SCgAlhfX7i997/eJ1y7JHHegX",
		"Fha01o8fPz77TiNHwOkwFArPzrZy2OncxNB8cCjuEsY1qLaCzJlMJhh0dJfVm0kwWeu3br+JKPo6SJcvXcpkM0KQ7hIxGXrcTKXT4XBY+R6z7lsYvu9fuTwz",
		"Ozdn7LFZa+X7bMTvAbRWjkMmEx+rmsa8tPxAa+267vjArPmF+WNBY8Y6/tiu2hGykD4qZraD0VAoZFDMRgenlVysrzLzS1deBgTRxQ3pDtAAEI+F47GwGaum",
		"x8yeifuGUL619hSJlNZbG5v5fJ5Z79dcADceCZxUzmfQFppwlD4XKuVHImEppemsEvFQhq7vN3xfMXOpWJidnfY9v9ulmw9x1N22qkBEsUSCmaVte56/tr4O",
		"AIlkWiu/Uhnr3LqzszM9M1MoFMbvGQ0N/kaSt7q/b2bj3Nyc+fhGW6p9KtdCCCIEpEa9vvnsWfs0edT0CwaDQtDgIrpzu+Xy/O7de8fO/8LeXmFvL5mKAcD3",
		"3/m35i9evDyttW/cGMYT9hX5SxefPf2QSDixjEr95S/WksDe+RYbSSAza9YHjo5n0xhKBa4UtPIbWhPAXmn3+x9+3xL0Cz/6C7ncpUq18M/f/WUh7T/3xs/a",
		"Aev3l75jkfyP/+Rft6Tt++7u+qff/+i7r81dtU/lH30OMfrevft37rzVWfzrGztXr77cbQHXGd2WlGUXbcFIyxeLramZSCQQcRQGSJuChNZa61s3b3SrRRrM",
		"1qBYaH5mRvkuH4lgZAZBFA6FRge41obgum6LwYGA0MLwIoAGlZ2aAYDFxaUjMpEb8/MPlpcZQAiq1ZtLy48vzuXha3Ctr6+/9tprm5ub6Wi0ZWLi+5ZlHFHQ",
		"xGgkZKWlJecuTAHw+vqqeaDV/YrRQe1J+rVGJLN9CiEajUaxWMrlckaBiKhVRCLCzvm7tF/HaoOZJ9KxsW5a6ezUTN++ZZNSw06LU9MXNteeKN93bGtQm6Lv",
		"Smey/mhJzPffXzSu0matvfXWm8ayr6WUxtCBPx6LOIYzA1jLVQg5Q5uQh5kyEbmut76xYarAtXo9HAr1HKGOETc9/0u3n5F5eq7XZNa25YwpqOmg2Hq66u37",
		"HGO/UXIK/82l3F/8ZP3HANy+Zd6ptg/hlQ67crkcCULA1dVVrYAECRTo0caXT32trt25qgr7DeUHpFVuHKSiKWCNrCsHxf2DSiKcABQAUK81YqG4RWL/oGJJ",
		"m7UfcgKRQBQR+evCM8QW2cHwpDt1RuyY5rbX1dr69tWrr0aiEUB+8ODDmempSCSCRN0x+osvvjDJpin3vHTlSj6XbTaaY25FnufhmF4Vpn7Xlvf8YPGhka4H",
		"srpAAzSZnzO1XbMMOrYju1urRje91THgvh6oZuZHjx6SIKU0CSmFeLEB+nDkTQrc6dtkklGNqd2draBNtVptb2+PmS9fvkxEhkzUQf6nUykNqFkCoGZAIGZl",
		"AnQ8EUPTyRbCMFwi8VSj0fBqtXaRBDa6oOuxeH9J3bQQWyQdZgCOJxKE1Nm/hxE3PJ8tgcqI3hFqNYJ+qLWezF/Y3ljx3NqxI+XYlpRCptOmtnOIQ8BWFUVr",
		"Zq1RkFZMwmDSzc7NfZCSeDxZPm/Xyk4Buljhf/KrH/3H/+FrXhsmYJ6p67rFYtFYEDx79gwAZmdnDw5qbUZoy3thdW2rp+TIrc3V1Ov0oGL4Od48BoqlXQCI",
		"xaNELEgEYgFR65izc6/vDTNAW4eePeVnRaRRK6eDEb95sLNWyl74xfB6Xvt1s3d2O4h2leaMBvcx1zvvvjd/41okEpqezht4xkz+5Y6tJDPDRAaApbDsg/JB",
		"4yAcjIDv/uvf/yc71XIymjhotCjTvlYBy/7nv//LSqugFXjj0rUTbID4YrjgCN/6kR/xmg0k6tbcYOb37t+vVCpGYu3/z96fx8mVXfed4Dn33vdizVhzjVyw",
		"owAUgMRaVaSonVbLHklcJIqSKJKSZcvy+vG47c/H0/b0jLs9M55p23K7LduyLLdEiZJJmaRFWtZiS6KohVWFpZAJoIAq7Mh9iy0zMiLee/ee+eNFBCIzI3JD",
		"AkgA50t8irlExnIj3u+dd+45v5PJZIjIdZxgIPja+TNUrwnr6+tDFJOTE+Pj00rZ4jHqz5tkdwP8yKKru8u2bAMBQglGCyH1ph/IdT3P08Z4hcLqZqF4LCZV",
		"zcI0ELB3fH91M3aUxhh/KnalUjFuuWakCaB90yvtQYuJeYQI/QP9tey/EH7msZasF7hYXKoVe61IQujmLAQBFouL8VgsGutoThF0RON+kN6YQFjbV6y3UgZC",
		"vrXTZi//DQlEje1nPmzSmxBRCEQpQQgkhNFr11dsKiq5WFzK5/N9mUx5eVm7TqVSbeiy57lCQF9f79TU9E7ZIUHbLgYM2GtNKtCrd342EjOI2HBtbTSCrtoT",
		"8k+u7777rm+es3asuBD42mvndyaOpnI8EaGa5R9o7S7lHFuFVL0vA+uuh7bfV4yojQYACyAYCN3Tix2hSNkUY1Y81XtsyqHTIM/YFd+QiwBsEG86hYeF+9Xy",
		"IgpcyC5OTs1vZsTJnqGM32zil/z7e1EtLuEAyWglRdAK/O7NPxFCpmNJWu1FLmLhmCZTqpa/fvPyBvbfKypW1MPx6aGB3mfp1+F3pvmNpGTMsWNH3333Xb9U",
		"yHMdIlBWrY4NhSvIMySM8UMAffvOnYmJ8ZPHj+30ZSPG4sHeVFVRQYD3WnrioawW5b6xsfGO6LIdCJRrfSTQmF5BRMvLy7FYzHVdv0TBcRy/aGZi7J5oZO4Q",
		"tevAnoPNE/Ymp+YyfV1PL4Q25DjVSqWitfYb5JZKy0a7tm37cQqiKBTyPT09BqAnHfc9/menHtaPatmoEWvonV9DUsgXGskNQDxw4CAgZHOLvu+7Hz4/Gtdi",
		"zIoEcn0kq+M4voI05MNvh5mdGtPrft402Ihg4FFXIdZ7MR8nRqk6jue6+Xyuq6vLmBWbE0SALhIq/8IuGo2+9dbF06eHVxs71p9AIZ99Qu/p+Ni4CxHQanUd",
		"IZHfx+R3YycSCdrcNuPi0pJA9P0Itdau64p6zh4BjDHhcPjtty+eP392k15usGZapmXX+tZWetrQUOZwubo8n50slYu6XnsnAKSyc4WCIUr2dF1+8yIAnfrA",
		"WVAyt5RNJPaQrjf6C0ergFThy4sFrGdcpQoOJQ8VgtcRoKs72NPTMzMzA1sZNNPWeIfIjxqzS0VCpY1RUpLfhC39ckgMKMszulguRYPhV3r3uNpbLpdwE+kk",
		"IkIwjyPQj6vR/rm95spGBETDp04pST29+372f7/a3Z3+O397OGCrX/v1bywuOtWqLJf7iERHNGdZDqI0BPgEKrSIQAjKJKoWEugCBTPXSsMFfQ2VnJic3zuE",
		"0Wi8XIGN4nFqVNX0D+7baNd45wV6ajbXfjNQjxeuX/o7X9dQ6bn2yq988re+9SOnAOD4q8dWFucZVOCB6uzsXF707w09T7uuFwyF/DTnK0dP+J9Cz/OwWRoR",
		"E+meRp+6r+C1phUyZMiPhuLJbkQczHSPT81prX0dN8b4iuCXnK/sPMJ1wsjZlXuVfj+kbcm5qbG1w3/9TFSpQptswff38da5jeM4CLXDtfEsTw2fGKk3SSZT",
		"XVKucCvdWeJRzESKrkvNMw2IKBC0t3FvhXweAO7ce3ju7KlcNnv3/vj+vY8MbO/eHzt3ZlhZ1rZ3vCxL2UoZf4efCABOnRquN8gopZXW3uTsPd8FMBALUrES",
		"TfX87pXfLpeXskuL39L/AUD4V7/xz2N2qLur/3DnQVM1WhICRCVa4/f/LBAMxBOPNp4IlLL9lVFSKsuGnTMA9sgErcCnXvsBpSzXc23bKy0TAHzp8u9oz7Us",
		"eW/6/ncffW3PvtPamHQkbtsBMgalNOsun0A0RLal0oko+keQELMLhWcQR9dq8muj7UEIXF7W3/jGWE+P8z/+7SNSymy2ms9XEJUQQa2hq3fAluX66VHQTm+M",
		"vv7aOUdDuPLfjgzGFsXJW+OOo2MabAXQn+kEyDZ15exe1ssYIiZiKQ1ooJpUqa6eTsu2BMo1rn5znZ2dqIISPL+KTSnZSCInkvGOaMxX1XJ52XNdpVQiEVdS",
		"ac/zq7uy+cXm3SqvWgJAIP8qTzR65XWt2hobaXGlVMMY73Fq7xBBCOG16Zczhix7x47VmenpeDzR0REmQy09CYzxgoHgk3vHAzaGAkC02qPicVLHB/YNkTGr",
		"klcAsH/v4GNahhkyhujEiRP1drH6J5aIsFYTZUnbt8EK2KGyb4GAqD3T3Zm6fPPSvt4jYRVEKUrlRV9BXKMrJP6DPvRXfvZTX/wnv/2XYb5EJB7loLVf237l",
		"ypWdnP9LgICe1g/yDwBld6y/L/1KNFYVAn9q6K9aFeMZ+ms/+Ldl2YuGwppMuVK+cPctInrj+IdtqczaoSyPloikEMuOHhm9tXeo79nE0RfeftsPZ1Z/2oK9",
		"AK7rek31Yaa+16Q91zR8Cbb2+atvALYfXeonsFAJKsCHLkwCgAJjoFoE4/k9S7YtbVu2K1/bzl4KPXWN9htYwDPgadKe5xky0KpfsVEcGYunYh0hz/MymYxv",
		"IQRAnuvaQjuVZU8by1JEFIlEiahRl+1vJ0gpPc/zR80CANbT3MXsbDzd05wg9nMmuLJctzl9vDlnLWiuYOvq6rQsa1WFU62QADf1fm3+PRVi3QbaHRyt0e7T",
		"vZW7f/jwIT4aTQPtbB3jiQQ8kaeNjc23dimoeh23KRfKiWSvsoLfde57KtVKJBq6EbtfnFn4vm/9GCGFghFyasegIN0ZVGP/8cYPeY5zf3rldTbu5JSE5ks4",
		"RM/ot+/dAIIPDCePhONOeVEImVSWK9wggiUt19baeLa0DKrrE3cR8fVXaRNpACLSjyPQOxNH+67Bjy4cPBOwFj7zmfOpVJzIuK4eHIwtL4eqVa/qVIdPZCxb",
		"IuLS0nI+l13bntt++ZGkQgTjuu5yAZsqkRHQM27ZW44HEl7Nhorqk5c9QIQme7/xyWI4QgErUfVQABDR4uJio7JwC3HfE/q8bPdwWV8EHw2sIkOPtshpZqHY",
		"lQxJFUx1ZRBxeXn53r17x44d83W80dsWDAYX8x4iCjJjD6dT6U4pMBgKFfPzADSQ6czNT+Gq2nAi13URob8nVdO3NXLZ3KIlpGkpN47j2ra94ndEAOC6rhDS",
		"dSsbX5UrWXX0Zs+LuLOiuwX8q4W1JwLEVZMLVliUbXDyo9Yy+uDhRDqdfuKVR1QzC7SUTKYyjlsZiCQR8cLFC3E7HB8KLzzIEdAHXjsyOftAIBjAiG39oLkN",
		"U2g8b5FA4FOqkUKAWDACgEFlaeOS0URU1q4fxbue6xevG/TI6Ggg7Acixm9mXnlvo6OjjQZdpRTseJ/hll8b1jJf/ofryjvvGGOkFB/6oALIXrkyTQRDQ2GA",
		"WsOS61Z9Z8d8Lnf33oOu7i4hBBC9M3INEP1dDgA8dfLYyg+aAi9/OvxbILDccXR0+hUw5VUVJvXmKGp1SidEoV23t7ens7OTCBbqkz6yc5PTc/lXX33V/7Zc",
		"Liulirk5KcUmi082rM9t1aq+AybiaASSQBJvfNdwySvSuo7D/nHf1TtARJ7n+e0n9dTEo1dqmoqRG8GvEEII4TiOVGp2Zubme7eOvAKL8/MD+/cLKZWlJqYW",
		"EHFpcVHU7PxIWgFEVEoAwejVq/5O5tpZWTNzj65grt1XW7pOaez0xhOJgG23iHAR7XLRGC2Uos25wgshiBr2+dSyTnnzT3GryYSwRYD4zjuXV5UFLC0uNd2n",
		"NESEtl+Tgoj53EI0GgKA+w8m9u7pn5ic6c/0NO+UNBYmFk+PjFwplRYty3Jd19Tb/Hc8yrjyzjva6HJlqdZ2SySEnJnME9GJkycAwNMaHgVD9Gdv/WnVqfbs",
		"iweCNJG765HQXvXetYfBQOjEieNtlvEJiHf9PcdaWy420iyi3lHRPFrhxrvvNbs1nDl9pnl+i59dQCEef5yLetyrHYJMf//kxAQgCinJmJXtJ4hNzuz3H4y/",
		"//6tmmWHbWvPc10tUFwZve7P4nQ81/eJX91UTQZE8IsX9iFiYbHomUsIcPrU8cYRIgQqS67T2+L74yyXKgZkY46qP4WhpzMxPzMB9UmmhexszUKovrjTk/d7",
		"M3sbd7Xq2+1ttD62jyG5YtmA49oVgSIcDq/NR7cwFdt0mqVR2dZIYjQCQ9u24olkIh7LF4rxeFxrI6X0g+7cSu+Yvr4+U6/tQxSCXAPWVl9rKBQ22oyOjNYt",
		"fVd0hxORbVkgA9DCtRyDATufL5hyRbbZ0x8cHKwPAvdPL8YYQyjq3fMro35U/oDHFkeRbLG47W686nGbo51K2Ws+2RCQQBEKBS27x38P/G3b7NwkAEQjIQAI",
		"hzK+Cpw+dUIq2dnZtWqwQ+ONKxYW9u0dBIA7d+9rrQUiIF66dGl7F4i4fkeFP+Icle+OVk/a1kq567uL9Tbdq9eUwNk784jZ2qUMkRSKAEZHR1vaQu1s0snX",
		"gaXyEiJW3er6r5yAStUlKaUXq5h5MP4ARoQ/++YfU9PJfmE+97RnZb355pumXmPYMoLww+REIhEKhcqVSnZhAQB6e3t9ryL/Nnv3DDx8OFYrgiGwlHXh7QuB",
		"YPCN188jYrlUKuTzg0NDZMgOx5uOOgQwgHZhWRJBuaxDQWGa/MwkYtUx+UI51pf0HK/NZARAxOZxErNTYz093ZZlOVrYkohMpVTwT4ACRblcaXRbrFLkrQp0",
		"RxgXl7f8kfKbaFqehIVEnY/0/PYJ0lWr0DF00E4kkkRmHXstgTWTh7V57fU+HEohYm5+WmsdDAb9E6fraSlFJNIR7Yg1/O+MoVgsFgjHZqfGGoOrm5tcMpnM",
		"loqlmnthgsEAEV2/fh2AENCfvyelDIRjvdHE7Ozs3OSkvXLzsDsdN2DdmS8CYKfAdh3z/qllQ1XyrzNyubYVHWOFIMDqlZyengKAP4valw5E/ocJPDyfbcqn",
		"62bjUN+gUUrVsvIkkUg2xk7rlS8EAQhVJKgBoG1zUL2jYHCg1xhDgNffvUlkPM94rvuoXKe1TJt2hXd+b9LI6Oiqc78fMJGh4spPYzQSafkm+FVuVVdnc4sr",
		"WxA6rAAYAyPNvb5YL671vMHBzNjY5I4o9KXLl7XRr79y3nPF8mRVH9RtYnckICHk6X3nAwFbIIwtzAJALB6rjWuuW236eb+HY1NDg31PdZ4hitbZIdn043w+",
		"36yDa4fZDA3VnOPv3buvlAqHQ45TXePcRmvCIgQgBGOMyWYXBgcyph6kIAAK0J523MCq3Uu/t7A55lr1ZCpV7Xo6u7AQT6QE1tORBChEw0/98QmLZRGUhYrd",
		"9DRwU8kMQ+U1wyEBYKm0DADmGwBgV0UBAPL5DU7amnBVS/GKPYDVfkCVcDgspUzGo6hUdn5GSLm8XHsmrxw64Juya6Mb07KkEOXyiom0q04YLc35NjlzMpFI",
		"NplpkJIyEAw0vEZbvr+47kRtS1mBYAAIiPRal2do9Bz779Qm3qv8ol7zKCkEI4T1YXJGLfkH/eYN3ZV9pPK4KpwcuTLSLquz4Zsb7Eqtm45XNWtNbTythVCv",
		"HjsCAIVCbtuWmX6KTEjR8uMkhABwNxmX+xOX1k4sKBQXY/EErMnE1GdxgNE6mUys9i1olVpsVWXQIvCvLgggUlI1e42t4p13rhCRWzZaOLlcPpaI+7ZcQohc",
		"drHJhiwGADsi0JvS6ExvV7FQKD6eBeo67RhALXbP337rrZYX7AQQiydXfzIIUKD2loA6W71JtcQlrjE8KtSTHk+uNwEA5qo9xi1u7TLN/+AaKhTysXiyWMj5",
		"/22cCAGARHlLZvkAMDc93tnzaGjAwuwEAMxPj/kq3d036DewlYrZ5WIWhMjOo3/eMgaaT1r+UdLVO0jt3Zl3kLUiNTg0RMZUy4uLi0tKYiaTWcfea1VFczAQ",
		"lEr6jj+uq9vNORICUQr/8ktvfUJ8sfDoE/WTI/afDESyK8JwanU9us0FnJ3Lbrb+iEAIMdDfi1IZTS1cPjYdrm3vqqi9DrS4nhtbUy8PAL09nbXAQorNrFh9",
		"Xszo+vU8Rpt8Lp9IxIjonXfeIWOGTw2ve58GAIr51qpYzBdhV80F3wHjiVWtu+0vvpQQLbzlEMmQkBFAujJyDeslWf7RNTk192xfYLNAb6P8zpfm4k7YRCDC",
		"wuykR7I+1dRPxPkOdmZhdhIAUqmUFAYRPG08T/sqtboeA3DDk026s1OoIAB4znIuu8OnQNdx6qMmxFazk7OzM34WjghapqmNISHFUmm5sMVBq+0IuM5333Oe",
		"+YEmpYDamFBPArje9lO62nN3+rmpLbyKul+H2URDthBCSoVo2oYQBChQSuOffDbzUSoWF5Op5FN749SzFujV6bDNeF90RAegkc4jIGOUJWNR4+mAf0Xv2/4C",
		"onGcsYnpwf5e2GWMjI4+8a3FlVcMkXDG1zJZGwNY6zqanp5JJLvqMwcAAKpAKEQ+O7fuc6NV3656wguP4Vu7Ic05NL/lfXv30N+fMS0aZPzXIuGFoJFZWyxV",
		"87mcbymcSqXsQAAer1xgOx/7kZG1uRElpbfpmteJydmtXcXOzXXEk4vrhjgd8dRiIQsA+VweAMLhkKlXi4q60whAbf6ZH0G3nE/ygmj0vXv3/TYHKVV9WJF4",
		"8OBBY0ziOrtYiFitVo8dO+pfWQtp123JMIgYHwrtV7Nvkms0zE0+ujCvlksP7j+oTdcTuHfPnmd+2GzOCQh3VqbXyQjnc3NbPbMCwPzMBDZvE9Gza8hE6E7H",
		"cVVt7qbaW6BuxAZN9a1XpRT4hOveW3Vh0RN0Pq0P2fA7y7LZbE/v9gOXTc+yWPEU2vqJIj7RoT2LG12DLjYlpuKJlJCSCPwZOoYA696HSklEXKdc5wXRaCF8",
		"+55VmwyPiqN8h6a2l42BwMOH4w/HxgWKf/NvfxFRFIqFXHHx//n//ZvfOvBtKvelb/meD9+bNX/4z/7Y/9wHA8FgINjIeeMuaDiZnZ2F5xxEUSslbnL4EMI8",
		"kycjhDCIa6v6cJONhYCjV6+t/Yga7cKTbCkkgJGRkeFaQeET9CVY9Zn3v40n0uIxjoVCfstR5Pj4xHPx2S7ks0qi35lCALaSWhvX00JK7bmA+IR25nZdruPC",
		"hYvb+Kvz5881euU0GNep5vKFf/Vz/7ulZDhsLd+tXqIfHLl2Cwi+/ds+hCjm5+fv3LkLCGTgwoWL58+fBUBg4PGnmy/ksrvlyaytHdo8juO2qEwAENqsM2+l",
		"p6dr7TBsvyprZmZ2C31MCKNXrzYmHz2hAMJ13VAwyB/azbOw8OgqvDMZnc8t+aNOnqa35e7aM9yGsvufZsu2hcBUMproiFUqFWMMYWj4+HFEGL32rlQqEY/5",
		"vrHbOyW8zAwO9GltsMl4QQpRrjrz8wsv0svc3jWNktK0moIopUwk05sZ1zI2NtbT0/N0ZqYU8vmOaJQ/0ttO68AT87Z8ATV6VcGD/99q1anaVU9rRATyyB90",
		"ZAxqjULyZ2x7aG20WaHR1DA43CJ9vd3+vPDV88wkViru/MLC8/jxI6KTJ442/3D06ru1obSbY2dr15gXGPUs/H92Ji+MK1iRhDx5/Gg4HP7jP33L73F57bVz",
		"jWp5ZvN7PCdPHGucDt+98R5u08SSBLQYcG4MENFzvUTN35w4fuzdG+/t3jeTeZE02k/7GmMmp2YyfT2ww+MpNQCcPXt6RzS6Wq2+995t21LHXz2y6rcXL48Q",
		"gTHanyEC8LwrwjPDn6v9mHfSndljjBFCNHqvs7PjvLZPh/FWzSDMcx9HBwLBHRdo/27XXvk+RnRQd/tZuxtIZIwOBIODgwP+MDraHXUdz11OKV/ydnCA9Iu6",
		"Vlev3ZBScBTAPHGNRkQiI6XKZJ5I30cm07ezdyh8l7K1ZtNElrL27d0DAH19T7aHJZVKryxqXudQxRa2ZLv14tgvBa3b4G1/UnAbdX6sO3z+pufspre2kF8I",
		"hzMsf89xHP0cZQXaH+do6ClFbdm6l0V3T09go/atrq7u5smnWpvc7ilkW0luyW3ent3mp6K9hdRzm3xqexrekZb9J3y8CIDdPyqOaa/RVJ9NGEt0FvM7384b",
		"jaeWCjsjSX4HJ7a2YwcikkI2N3puhlgiLcVGPfsIxnNQWsaYxUI2ne4MBO2aKQ4iGXPu3LmWf3fx4kUACIYCzaKlPS+3a45rf62Sqc5maW5UMvhWCZtfz9ob",
		"1Fagt3yHu2Fx4sl0u2CZiBLJZD6X29Iriic7BW7cpel/yrfaEdrugqZmLgrQEU8vFhZYB5+vXEfNeDAeC8djQ0/iIZPxHavWTMSjnlNt5faJRMaylD9tM9H0",
		"iFV3J+KH+uzRUDgSUI9iEl/ZEKlND87Zxm3qqn1JCNHdN7h7PhChcAQAjKnA6jFmxrYt/6n6t9nkvSFVWwrQ9u7wcd83Cx/z8wZAbrWytlICEYwx0Ui4o6Nj",
		"1UduJ88THUM7ctT4jWD1oyMCz4PpyGacfJ50y/5uyXV885tvffu3f5vv3L7r99jWeX5YM59fXXInHsfaAppM6xtaA4D1HshN5gNxN30GWj/Lzp7BFQEj7rwj",
		"x9PPdZDRO/KcTx4/turnJ08cGxm9bowRvqn+Ft/Yc+fOrn+Dixcv7fh7/Pir8dSy/L7b5e27D+yATYaeSvMKVqtuV/oEANy5P2ZZaocfF2uDR4QQ/qCDreWj",
		"R0av/a2/9Te0dnd587RALC3mW+adTxw/qpQVjsZWDiWC3/jy12BHLYo+8fHv335YlOhExNGNPPCePq+88kq5XG5YEhJRJNZZrVbH7t/f6l0NDw+3LKfp7B0q",
		"l8vvvfdUa4of581qBMulxdaepSeOHw2GonYgYFaMi9sZzp8//9Je7L/99gU/tFHKGurvm5h+Grvu/b1d9x5O+edkpdQTfNyNppuq9n9odv8mtQHQxpDRa649",
		"kcgQSSLismjYjp+vJKpNn2uUdggh4Kn7/+22ugsiY4w/GWDVtEM0Whv/wm1Lj7IV07eX9bNM9RQhTU7P+V9fvnrzCT3YmRNHAGBieo7I+GEKEU08+cfdmkYj",
		"opBKSLn7TYgS6e71jwC59TmnT43F/Hxz2mTbA6V2HMdxmifd+ae6arW6vU2qllqMiK7rPuXXZdmBLU0fb3mBmuoKrnuDzbpvvPnmm4+mDW4hU0ZvvPHGS6XQ",
		"QkhAfNq1KERSiOm5nF/g+wxPj6rlweO57ovam9TV1bWjvha65ZDArYWTxvG0h4A7+9zgsfamOhrTwRtxdCAQcBxnGyF5S40momAw2NnZ+TSj6bWf6lvvv/8M",
		"W6UJQEm5+a4uz/MA4A//4A9fsii6drGBAunJR7L+/Z85cUQpeefBhK2kX4D09CPodrV3ZNt2ebn06U//BLKT57pbCpVqtben989993dse++FiISUMzMz16/f",
		"CAQC/+33/vuLuFBifXeiZ/v0vvvD34lCCmUDmKd81YiIruO8cmj/5v/k1t0HO55xel66gyzbtpR6yvHsgT39E1Ozu66ug4iEUgMDAyzE61/1OtVqR0dsRy7A",
		"gsFAKBTqH+h/URvKd09KehXhcBiF6N/p9tdN8nB8aku3DwWDA5mel/OAeyZa2XjQZxVEt98zJNrGVe1L5guHjuNqrXfIyIKMMbzmTx9jNBJMTM3R04+jt7V3",
		"NjE1+1JuHJJ/Wf8MtXLXeSqx/dBTnjfIa/7MLogQAQHp2dTPPBifImM2kRMnBFRKwUs6TOhpv+jdczJQfIwyLzNvv31BWkErEqOVdfRPAb/GSymFW0wcvYSx",
		"JHAvOMMwL22kxuxmBC8BwzAMazTDMAzDGs0wDMMazTAMw7BGMwzDsEYzDMMwrNEMwzAMazTDMAxrNMMwDMMazTAMwxrNMAzDsEYzDMMwrNEMwzCs0QzDMAxr",
		"NMMwDGs0wzAMwxrNMAzDsEYzDMOwRjMMwzCs0QzDMKzRDMMwDGs0wzAMwxrNMAzzHKN4CZ4EROR/gYi8GgzDsEbvsmVVCgAQwRgyxvCCMAzDGr1bQMRicZGM",
		"ISDLsoPBABFxQM0wDGs07IYshxCitLTkeZ4xJhrtCIdDWmteGYZhWKN3RRCttc70ZxqS7XkeB9EMw7BG7yKZdl23+VteE4ZhWKN3l0zzIjAMA1wfzTAMwxrN",
		"MAzDsEYzDMMwrNEMwzCs0QzDMAxrNMMwDGs0wzAMwxrNMAzDsEYzDMOwRjMMwzCw/V5wIgLihdgq58+fN8ZYlvX2W28R0fnXXnu8+yMAOH/+LAC8/fYFXl54",
		"ej6FBog//8wu1mhhB4E1ehsXIFISIAq5I/eGQqIQCAgA0g7y8j5NL1mUFh8BzC4eGBLqYP+f7aiqtASaTF/Pzii+svszfRPTcwBghWO8vE/znQQiIgPAhwGz",
		"S3Mdhvhab3sB2A6uG5nGf8nwQICnLtMMs7u9SfkzuktkAvntYBiG6zoYhmFYoxmGYRjgOSyw2xPXwMNZGIZhjd6dAm1Zlv+153m8IAzDsEbvIoGWUj64/9DT",
		"rkAxODTIa8IwDGv07qJarTiuK6XkpWAYhjUadtV0cK314VcOA+c6GIZhjd6dMu26Lu8ZMgzDGr17ZZoXgWEY4PpohmEY1miGYRiGNZphGIY1mpeAYRgGXoY9",
		"wzMnjvCC8jJukstXb/J7zTAcRzMMw3AcDXDmxBECEigyvV0vydpNTM1Cfc7Y9v3+iQBACAEA/X3dL8O6jU/NIHtkM8xT02j/2twXaMd1b9978DK41COANubB",
		"2MTg4CAhiu0NNkQERAAoLZfu3h83/jSWFxmSQgYCASLyPzac8WCYpxRH+wK9dzDzsq2gNhoInGp5WxOyjDYmHo+/euTQy7Ni9x9O2rbFE9oY5qlqdKa369bd",
		"BwAwODRERr8kzXVEoD0PABoN31vVaACIRqOxWOyFn85OBChEqVS6dffB3qGMnyliGObp1XX4ukzGuK738jRA+690e693+NTwyMio1lpr/TI4tSoltacFN8cz",
		"zDP060AERDx1apgXd1MyPXzyJXmlxphwOPyHX/8jznEwDHDtHcMwDGs0wzAMwxrNMAzDGs0wDMOwRjMMwzCs0QzDMKzRDMMwDGs0wzAMazTDMAzDGs0wDMOw",
		"RjMMw7BGMwzDMKzRDMMwrNEMwzAMazTDMAzDGs0wDMMazTAMw7BGMwzDsEYzDMMwrNEMwzAMazTDMAxrNMMwDMMazTAM81KgdvweiYCIjDEvy1lOiMdeMSKi",
		"F36hRkdHpVR8yDHMM9NoX2hQCKVkJBx+8RcPgQjK5TJu9w5GRkeBQEiBKADo/LlzL/BqSamElFKIl+GExDC7UaOVUgBQLBSJ6Pf/8Osv/uIRoED/bHTq9Klt",
		"qTwiYrlSMQbJeC/4ohEgQqFQUFJNTs/xsccwT1Wjx6dmArZ9/+Gk6z1ARHjxY2jQ2gQC9oc++DoBBIPhbeVJpBAiO5m9fvNWKBgy9KIniIiklHYgwKE0wzxt",
		"jUZAQ8a2rb1DmZdk7SamZvv7ugkAiIzR20zeAwBAJBx5edZtfGoGAS9fvcmHH8M8DY1uHGxnThwhoomp2Zdk7bQxfkBNAI956eBvsb4kS4eAfOAxDNfeMQzD",
		"cBzdKqB+GThz4sgTumdOAjAMw3E0wzAMazTDMAzDGs0wDMMazTAMw7BGMwzDMADwJDyVGGhlYwKPXUPNMAxrNLPDXHj7bawb45Ex5197jdeEYRjW6F0DYqVc",
		"ISJECAQCvB4MwwDno2HXZDkQwNNmfn7OcTUvCMMwHEfvqhgaiSgaDUejQ36ug9eEYRjW6F0WTbM0MwzDGr074U1ChmGA89EMwzCs0QzDMAxrNMMwDMMazTAM",
		"wxrNMAzDsEYzDMOwRjMMwzCs0QzDMAxrNMMwDGs0wzAMwxrNMAzDGs0wDMOwRjMMw7BGMwzDMKzRDMMwDGs0wzAMazTDMAzDGs0wDMMazTAMw7BGMwzDMKzR",
		"DMMwrNEMwzAMazTDMAxrNMMwDMMazTAMw7BGMwzDPPcoXoId58Lbb6/6yfnXXuNlYRiGNXq3gKJ+gUJERLwgDMOwRu8KiAgRi4VCoVAAgFQqHYmEjSEhkBeH",
		"YRjW6F1BIBDo7OwCIKkUACDrM8MwrNG7AUQkokAw2JzrQBZphmFYo3cJ5197rTkHzQLNMAxr9K6LpnkRGIYBro9mGIZhjWYYhmFYoxmGYRjWaIZhGNZohmEY",
		"hjWaYRiGNZphGIaB56U++syJI7x8T4KXeWEvX73JHwCG4TiaYRjmhY6jG7Fef1/3S7t241OzTd/Rto3yAMB3xXuZF3NixWIyDLMTveBEdOf+2Mu5cAigjXkw",
		"Njk4OAiIiNu6IkH0PfGWy+V7DyYMmZd2MQOBAB+NDNNCo8+cPIpbDwIRwJAZyPTwChpjAMB13e2c5IwxRABw7JWDL/kyTkzNAuKZk0dfknNSw3WLU/DMBhqt",
		"Pc8Q4dYDQM9zAWBwaAjIALy8FkKe6wKAUy1vU6MBBgb6txmGv0A8GJt8eUxcCUAKIQTvBjGb0Oihgb7H+XvteVrrl9nmzX/t2zzeEBDQ8zSA9zKf5xBgz2Dm",
		"pTstjU8pxcaTzBP2JkUEgTh8ahhe9hFZ2/mr4eFh/giOjIy8nOcn2sb1KwNce8cwzNO6emAY1miGYRjWaIZhGIY1mmEYhjWaYRiGYY1mGIZhWKMZhmFYoxmG",
		"YRjWaIZhGNZohmEYhjWaYRiGYY1mGIZhjWYYhmFYoxmGYVijGYZhGNZohmEYhjWaYRiGNZphGIZhjWYYeM4nzzLMU9BonvjDMNs69gSyTDMboh6MTxLRVqUW",
		"ATzPO7BvCJE/Z8wOnObvj00S0csyYJ5ISCmF3OasYual0milrG0cFpnerocT07x8zE5hW9ZLpNEAxOrMbFKjL4/e2NIfnDlxBAAmpuf4Q8bsCOnuDABcGv2C",
		"MUYI3iBhGOA9Q4ZhmOckjt7qH1y+ehMAzpw8uurK7eVdwh25POeLEoZhdkSj1wgUIoKUEl7W8ilj9LaLW0ZGRuqrCABw+tSpl3ENiThvxjA7r9G+LLmuS0QV",
		"x33ZFu7a1atQq6ASADB86uR2V5GIyBgChIuXLgPA8RMnXiqFllIiIss0w+yoRhNJKccnZ+6PTSLgv/z5z71sC/fGuZNGm0DAev38WQIIhSLbuBMhpUAcGxu7",
		"ded+IBgkQwDwUi0m1T9O4XCINwwZZodzHYhoKQUAkUj4JSxaNEJnersfK5tMBEIAgFRqqL93Ymr25VxMrkVjmB3WaH/n8KVmZ5OoxGrFMAzX3jEMw7BGMwzD",
		"MKzRDMMwrNEMwzAMazTDMAzDGs0wDMMazTAMw7BGMwzDAPewMLDdrrmXx7eeYRjW6OdDoC3Lanzrui7LNMMwrNG7RaCVUvfu3XccxxgTj8d7e3u01izTDMMA",
		"56MZhmE4jmZgHS9Az/P27dsLnOtgGIY1enfKtOu6vGfIMAxr9O6VaV4EhmGA89EMwzCs0QzDMAxrNMMwDMMazTAMwxrNMAzDsEYzDMOwRjMMwzCs0QzDMAxr",
		"NMMwDGs0wzAMwxrNMAzDGs0wDMOwRjMMwzCs0QzDMKzRDMMwDGs0wzAMazTDMAzDGs0wDMMazUvAMAzDGs0wDMOwRjMMw7BGMwzDMKzRDMMwrNEMwzAMazTD",
		"MAzDGs0wDMMazTAMw7BGMwzDsEYzDMMwuw7FS/CkISL/C0Tk1WAYhjV6dwm0ZVn+157n8YIwDMMavYsEWkp5585d13WlEPv27+M1YRgGOB/NMAzDcTSzAYio",
		"tT5wYD9wroNhGNbo3SnTruvyniHDMKzRu1emeREYhgHORzMMw7BGMwzDMKzRDMMwrNG8BAzDMKzRDMMwDGs0wzAMazTDMAzDGs0wDMMazTAMw7BGMwzDMKzR",
		"DMMwrNEMwzAMazTDMAxrNMMwDMMazTAMw7BGMwzDsEYzDMMwrNEMwzCs0QzDMAxrNMMwDMMazTAMwxrNMAzDsEYzDMOwRjMMwzCs0QzDMAxrNMMwzHOM4iXY",
		"cS68/faqn5x/7TVeFoZhWKN3DYgIAAAEAES8HgzDsEbvCogIhSgWlgqFLAAkk8loNGoMCYG8OAzDsEY/+wCaiMLhQDjcRwRCID2KqhmGYVijd0EsrZRaEVmz",
		"RDMMwxq9Szj/2mvUlIPmIJphGNZo2JVbhgzDMMD10QzDMKzRDMMwDGs0wzAMwxrNMAzDGs0wDMOwRjMMw7BGMwzDMKzRDMMwDGs0wzAMazTDMAzDGs0wDMMa",
		"zTAMw7BGMwzDsEYzDMMwrNEMwzAMazTDMAxrNMMwDMMazTAMwxrNMAzDsEYzDMMwrNEMwzCs0QzDMAxrNMMwDGs0wzAMwxrNMAzDsEYzDMOwRjMMwzCs0QzD",
		"MKzRDMMwDGs0wzAMwxrNMAzDGs0wDMOwRjMMw7BGMwzDMKzRDMMwDGs0wzAMazTDMAzDGs0wDMMazTAMw7BGMwzDMKzRDMMwrNEMwzAMazTDMAxrNMMwDMMa",
		"zTAMw7BGMwzDsEYzDMMwrNEMwzAvA+oFfm1nThwBAEAEIv8nl6/e5LecYRjW6N2hzgCAqD0PEKWUQOT/nJWaYRjW6F2B1npooA8AxiamheDEDsMwwPno3UJ/",
		"X3e5XE6mUgBQrlT6+7r5/WYYhjV6F4GAxhg/Kc0wDAOc62DgOd1ZBfA3VzlfzzCs0cwuEmgi0lojgJSS14RhWKOZXQQRoRB7Mj0AMD45g5wVYhjgfDSzO0BE",
		"1/P6e7sGh4YymYzWmteEYVijmV21rVoLp/3NVYZhgHMdzC6MqAHwzYujkWiEF4NhOI5mGIZhOI5mYKN2eYZhOI5mGIZhOI5mGj0pm7pxprfr/tgEgN+9Qh84",
		"P6yUIqDNPlj9htz2wjAvtUbzhflW0Z7ejE6PTcxoT9eq8BA9TwPiJiWagKQQXE/NMKzRzJbx3f62YhDoGaP37x3Y6gNx2wvDvOwa3Qiit2RcNzE1u+2o/PLV",
		"m88wcn9Mk2siEkJ88qe+13HczdxeoKg61Ww2p5T6YPrEJh/Fc3VvX/oXfvZLntaWZfGBxDAvexxNRHcfjMOm+zJs235p31QCyi7kHcdrWg9qv7AgBIaDUQLK",
		"LhTWv/EjjfaMsqTvLMhHEcO87BpNRAOZnq1eg0MrR+n1/2pyes6QOXPiCAEJFJneru2F6lvFnz/gP73J6Tmqj4xpF+avc1cXR25YlpRSSknNPd/riCn5/2gL",
		"nkpbujHDMC+0RvvzrgAGh4aAzMZbYQhAMLZKowkA4N6DCa29dmbSRGQpZdu2ISNQuK576+6DdslWBNDaPBibHBwc9Jv0ttvdBwBQKpXu3B8jIiBSSkkpCWjt",
		"fQpERGzI9ybzIQiotecZd12ZJiUsKbZS1MEwDGt0s5YZrT3P2+QO1aoboRAPxib37emPx+NErRSVABELhfy9B+P79gzcezixb6g/Hk8QUVtlIxCiNkNAe862",
		"LhCM0ZROp7/lg2kyWkilPbdYLExOz7UM4Sen54wxW9qjQ0TPc6tFEw2ljGlX7EFCyFDSKi4tKGURsUwzDGs0rD/Je4Xa+qKEiIh46tTw+ncyMjLaUOmGmglE",
		"bUwikeyIdRitXzt/btVfvX3hopCyUMhrY/zzAQDE4jGjvdfOn2+XIlBSVp0qENB2DYmIKBwO+U+UDAEFOjqi/f39a28mlQSAu/fH9u8dnJiaA4AzJ462jIjF",
		"ShE3oKWww4EOT7utryGIlLTmp6dUVANYWx510+aZbNnYiScMMMxzEUdr7a2+VPf0NqbNjk/OeJ72o07P81AIQGG09rRXWl6G1ZtgnlWP1gHAV2og43l67Y0b",
		"Gm0ppZTcdn7gzJnTvv4SESJeuniZ2gW6QJJk7XVNzazjUUcGSK6+iiAgbTxtvJbpDgJC9LcKtxah+89HCHz80JsIpBQIeObEEZZphtmlGk1ACDjU37dBW9sm",
		"2DPYBwATUyKfywHA4YP7AIBII8LwyZNrZ4Q3EgiRSBQAIpFI4+dtB4oTCcTHTwz41wcAcOr0cLt7u3JlxH/5oXB4YBM1iE7VdV0PAFCg47p3bjywrQkiMzzc",
		"4ipkdGQUUVTd8uHhfjBiM4LraV1eLgPA/j0DO/Xu+xu2XCjCMLs4jiZAgetNDIGtjgZfkdW1lCJD2HbP0PhDxAGgv7crnkgYQ+0zKiN+cTEgAtDjyzQAnjx5",
		"whjd7ukZYxLJ5CbvcGBPn+t4frLHNc79a9OwrvIS0Q984s9XdcFSAdd1aaO9WWMoHLbiqXQhu7BTb36mt2tsYnqdDwDDsEbvBpV+sjV860dpzSHkZk4Jhqie",
		"TV37xNG/LGhcH7S7DQAYTxsi13WVUu3CWCFEPpcbn5wZyPRMTs+20rjuu/cfkiFA+NzP/eZq1R4Y8DyvXZ5BWer//Ne/ttX1fDg+4TguIkop9w4NtHxW7RW5",
		"++79h3YgMNDX03arl2FYo3kJfE6ePHn9+rVWPz/RVteUHB+fWP9uE4lkIBiYmZ7e4GbJJIAYGRlVSp48caLVzh75P8znFkqLRUMt8tHZhfnjrx5rfHvt+rtC",
		"SETU2jv+6jEU63ayGBOLxYrFIgDcvnOvUikLFOtE3ijQGL3q4dY5wawln8seO3oEAFLpdHZhgT+BDMMavXGc1lwRgYD0+DH/5tKrtmVrvdmywvUfNh6PA0Ch",
		"UAAAITZbp0hElmX5f6uU8qsV10mPCIH+tmXzw235mgYgmUxalhVPpAt5lmmGeT41OhZPFgu5emnWJkUMASAeTxUK2Z6eXq31/PxcraivzZ34vxIoACCRSOXz",
		"2bq4rtee5z/E47/G2dkZAOjq6mrfvIdGm1gs3hy6tsSXy/0nek++ccgYI4Qw5E3ezmmvbab7xPCJ69fe9bQjY46S9p//+IcsyzbGrHPKMIZCYfviH91sqPOG",
		"T6wluVyOD0KGeb412hfoNWXTG+OrpyHTyAwQtQ1DR0dGhRR+yV0+n/UjYEQYHR1FhFXlEP6GIe509hyFWP8u21aYrJXdE8dcT/sl4o5XmblXXC8oBhw+eXKp",
		"kuvotiwVcD1vw1w8GQqE1UXgIjmG4VzHY2c3GvkGIVBKOTIyujZCpFqZHTZfjGtt/C0/X5TXNJzDju9pAsCVkVEEODl8svn8UX9Gm33MxcUlvygFUThe5fCR",
		"A52xPlc7xujVFwYEAGAp29O6UChbKrCZRyFDHvFmBsOwRq9UMKrHsC3rfBsRbjv9rFYdrU0wGGiZYHUcd6Fp86pQyBcK+e7ubtu2VhbhkRCyUqnMb7QTuK1C",
		"aSEEAcDVq9ea42sEEkJsvuxB1ENyRLSkVdZOYXmBiKKhBJF5tCdJhEJ42skvzWvtWtISYlP10eQ/H4ZhWKMbSCkQwWhDAC0b7UZHr/ry1C7xWixuYWsr3dmp",
		"lJrZaSFeh5mZGQDo7Opam5dAxMnJqe2VG0qhQglwdVEK6dpitUYjaqNdKIUiAYGSzToYhjV6m4yNjQNAJpORAq9ff7eliAshi4uLhXx+B8J2Q2QeuzkFELY4",
		"pmR+bm7HuzeFUCFpEZDjVZqzNPUGcAwHIoboCZenMwzzEuSjS8vVtjVqRMZ4WwqWN8xkPybGGKPNLlg28ttt/MIVXFON2LLgmmEY1ugt83wV0hYKedj1Wf6V",
		"XtYMw7BGP93m8u350pGhFzw5SyAU+jt/RKA92tKqCjbWYBjWaNhinwu0KpZQYuOXGYvFAVWxsNDo4W7YOu/CF7Xx7XHj8Nmy8M0/uF4sLAJALJ54/buOeC5t",
		"5hUTgbJEYcHxHxSaatgZhtlZXpDyqXU0wnGcP7z2zY3voVh4770bjW+lkkLKZ1tetlXha749bmKyjdY0/PrReKIjnuhAYYymTZ6SEMFoikSV/6A7KNAcmTPM",
		"cxNHJ5JJKSURCMQLd94LBYLHB/YYIkTwPF3I5za/axfEjaX2vffvuK7T19sdjycKhbwx1MjUxhKpYj4LAJ1dnfNz840/iSdShXw2Hk8Wns8okggCIXztO1/1",
		"vzZ6C7kOo8mKcA8Lw7yEcfSjujBljNFGG2P2xVO9wXDjW9roaceTnfFEOpHsBIBioaDrxdTxZDqeSDffsiNeM4x23arf2xKJhKHmYlormwsHA13d3X5RxL37",
		"D/zbZzIZP8ouPM+X+caA55LnkvFoqxHv4xcmPmVnWobhOPrxfe4BgHp7ewGFp7UA4TplpSQApNJpoSvZfCmRTIWDItrXUzPrBCIQArQBAYgCjCFhjEbShKoz",
		"EfHcajjWkYhHEcC2kUD29XYhSgIE8pSyFgu1RyeCgcEBRBFPpJqLHqanpwYHBwHA09q2bADo7OySSmldjsXiUgpAlcs+VlFzKpXKZrN+YJ5KdXraLRYKT3Gc",
		"79MmHk8IqXLZ+Xg8WS+AyXGug2Gehzga0bKscvahcIqBgOWW5gOhcFB6UikhVSygqTznlJedUl67Vc9zqktZpeT8xG3tOaS9qbvXEMl4TmHuoW1bhsh41cWl",
		"JSUQtFOu6EAgMDU9V11eFAKXsxOlciWR6qorvRgfG3eq1VDQDgZso7XWOpPJpNNpUx9E62ntDz/UWhcLOaVUMBi0LZFOdz5mGTUAFPJZANBaw64PSBGAHqOk",
		"moD8l1ko5Px/HEczzHOg0RdH3n3n6ntnz53zZi5H9NSp4ZOF3BwQzc1PV13HVEvF3NxiIaedUtgd35NJ7evvDFYfnj59au7aVwe6O86ePT2YwkP7+od6E3NX",
		"v3r69MkutVAZf/vLf/xbfXHdiVPVwiQR6cJDr7pojKksLhRFFGo1ZCSk399BylJNhWUUCgU9z0skEpZleZ4LAJalXMfp6+vLZhempqaqjruwML9ju2WIQliw",
		"67MG9Hh/jFyPzTDPb11HKBILhqIoMFR58Pobb8TMzPFjrxwfHu7Q0zEzc6AvHAxFpVRCqWAoiojRWBqIwtHEnlPfY7SnbLsj0YkogqFIOBqPxVKBYMgOJ0hX",
		"EaB78JBUNgBIRESptU6nU/F4wqk6qVRKE1WrVa2NnwAplyul0rLjun74fGD/vlg8obXGpmmzHR3RbbzGRCLZ09sLLZp0sgIpnkgmEslEIvnifebiiaRSyr9o",
		"YBjmudToxqhsIQQQdSeiYYVd/Qcs2wYirA9pbWSxG7fXnocoPNcpLkwDESBKKf7+B161pSSAOMy/8YEPfNf3fkQICYgy0hnSi0jGsuzBgYzrOiiE9jQZmpmZ",
		"KZWWiYhA7Nm7d2hoyDegS6XTwaCNuMLruaXBEwAc7tPpmJXqsLrj6lCvaenl0TIpbNlWLNbREevoiHU8ZhZlFxKLdViWWpmeTiaSyYnpOR4KzjDwXNTelYq5",
		"aKIIBEuFBQDIZecMUX5uspibRZSV5aVyqRjTriBZLhWAqJCdFlItzDz8/c/9z9/12X/cNfDK//DT/9yyg4uFhVIxZzynWl4ql4rLizkiGr97zXOrNspFV0UN",
		"CRRIGgCOv3oMATytLcuanJoBgI5YB9CyZVn+aYCMJqDZhQUA6EynrEBo/XlYAaRkyAEAASQ3ShjEEwkEAEApBQA4VceQQURDL5psjT18mEgkO7u6jNZaG/9s",
		"S4aQ89EM8xxoNAIRHfv2H7GDUWlZH/6hvwGIJ77jxyMdqfz85Inv+rRAGe5IxD03EkshCnHyw0JZf/5Tf6+jq1/ZgW/7gZ8KhKJ2MNI9cAgQeg9/S3LoFBkT",
		"TXYH0vs7958DIl2ctMIJBNObsBYCqVBl4WE13NnZE0CtCQqFAhFl/GHVRORb6xMdOHjw9u3bjaLp+YVsIpHwv9bG6+zs8qtAFuYfJaY1wO0ZNCIqzNKxPr3J",
		"kVGDQ0O+kL3Il29ShEKh8nI5m802TQrvGpuc5lCaYXZ7fTQi3r3wX7L3LmnP/dPf/hwQ3XrrK9XyElYX3v/ml2+/9ZtL0zfnbr9VzM0s5mdn3v+m0d7Xf/Pf",
		"FbOz1eWlb3z1F0l7+dmHN//kC9pz8uOjt9/+2vvf/Eo1e2/h7sV7l3+byNy4+AdepWgM5ecmgxYW89nxfNkz5LquNhBPJJRSqXS6L5PxtEaAu3fu3Lt79+7d",
		"u2QMgEh3ptPpdDrdadl2T09PT08PENm2CgYDoVBo7T5gLY+Bm28XLBYLxRf8Y4fYVG3JMMzzl48WUDuMHwkcGY0oUIhGd0lDAhFrM0q01oFAYCk/89bvfs5o",
		"TwgpEH3foEc5a+3t67b9F+94ZrA71BkLkSGBCMaTQgCA0ZqM8ceUCH8OLBEgokAiMMZIKYLBoG3bdsD2DZi0NqsT0wTdcdUdqfQlxebdmfz5Ly/2x871qLRU",
		"cj02RGWY595TCdf8d4PNRiKSlh1P97Vrz6jvNxLYAeHlxubKThRBkJByYX7h3v2Hp0+fFlIaIiVErn4xnkqlgGhoaEhK6bpuLBbLZDKe5yHCcqkERKNXr626",
		"TkfEqO0BgMANh7i+XDxfBrMMwxoNa+wgtDEaAIz2/G8BgIwxWhuhyRhjNBAR0KObkaHa7YmMcatlADBGG6P9oNj/ujlGBsDy3AIACGkBkBIAAKXSUj630NnZ",
		"aVmW1jqRTBmjA7ZtWVapVJqanDx77pxfe7e4uIhN4TyRISK/nE4gLi+XPTN7d056IqrM0rEMx4wMw7wIfYYAANK2lbIR0LJDAGDZAUAUylKWJZUlpaWUjSgR",
		"haVsAFR2EIVERGWHABFRWHYQAJWypbKk/1fKVv6NLfv+vIeI2vMSiTgAgHYJcFp3LHf0WsGg/0ScarVaqdiW6ohGpZTGGEDUxpRKpaWlJdd1bdtWSim/jIz8",
		"weJYXi5XyuXl5UqhkPezrsosPZ2VGxwa6unp5c80w7xI4Klzb+yemmjP85Rl/bt/+f+TfhpZKu25yrI915FKAYHWfupAEBAK6SephVTac4S0EEAbLaUiMkZr",
		"pSyjtT8Fyh93TQBKWUZ7b799wR+t5bie67pkDBEpy16YnwOA3t7equMQQT6Xjcfjhbp1RiweR4B9B484laV0Ot3b2+t5nhBYWlqq5TpQTEyMN17Rqxl9fVLW",
		"6joy+t1JucrYLxgITO/cTNuBwUGn6szOzgDAhz/yhjH0REdvBcLqd37jz3b2bscmpwWKy1dv8pHJME8p13HmxJHNizQZg0Jcvnx57uG7B/oih17/yO/90j/8",
		"v/z0P/36r/3j89//14sT16+/9XvKDuw/9tpSYSE5dAqlmLv99qvf/qNf+hc/86Ef+rvRjuQX/+lf+uG/94uF7MzbX/u5j/7Nf3Xv0n8dv3PV89zjr/253Nxk",
		"dubhh37o7375X/xM4sifD3akp6ZnOztT2oAgA4B++/fU9ExPby8QCSGSqZRpcs+oTWglNxwO+YlvImraJmwxszUds4iqllT05AcGcsKbYVijtyPNpjbvdGOJ",
		"MUS1AggCIkNAtUoJBO25qT2nxMXfJ0NUG9lNDWcfMhoRq5XSR/7S/xyNd3rFibonXk0ZiQwAGe2hkN/5qX84cuUKAERsAkAljENKkPEV1nFcqGkxEZGQsqur",
		"i4gQ0dMGyAghqlXHtgOPktHUZqoWmUSwAgSi5uQp+APHMMzuiqOJSAqZ6e3azI0npub6+7oAwKkuL+ZLYCg7Ow4A+fkpz3WSnZn8whQZ6h44sJib68hUhZbF",
		"3BwQzU/d91zHeJ6ykpYdWMzPL8yMAdFSfiE3O+F5Tmkxt5ify81NImKya0C7FwCwOPcgEu+cz+Ye6szeqLGVm06n44mk9rxDhw4h4p3bt8E3okMkY2zL0lp3",
		"ptMEoJTyPK9WbiKEn49ec9qRd2aFkTGhi6+22DPcicHjDMMA56O3FUcT0EBfz+17D77ljdfsQAC2UtThVEonXn0l2dU/9fC9zN5jM2PvJzr7g+Ho1IObRBQM",
		"dxjtBcMxRFxeyqd7BsfvXk/3DgGBHQxbdiC/MLWUn8/sPZqfn6xWlokoHI1rz3WdSu/QKwBQWJgOdyT/5I+/HgxFs0uRAC4qiwIBhSj8oPuN11+jNsmEt96+",
		"WI+SDQCdP3/O3xv0f45N47WaZdsPzMfGxqDJQzkYCs7sXD56cHCw+qzz0fF4IhgM+EMVpBCVSqWwFSNszkczzFONoyen55SyZmZmtvRX/f39RnuuUzFE1XIJ",
		"ACrlEiLOTtypLC+hEErZnudagRAiutUKEQWh7LlOIBAev/oHvUe+BQACUCYi16lWK8tAZAdCrlN1nTIZM/3+n4lob7gjaTzPGEp3LBWKVQvDr792zvMMIiCK",
		"libOiOh5plKp+Mlo27JQIADWxBCBiJaXSo3emt6EnMgaAhBI/SmRrwTi8URNuFHalhBCxBNpIL31c6vcnSXGRGTI+JkfQ0ZIm48xhtmlGo2ARGRZ1t37Y9oY",
		"3MSeoTFGSjkwMFBZWqjMC9MzNHH9j/YdPTd765vpnsHlxcL0zT8Wyho6dLqymAc4IIQozb5v+vdf/sZvDn/4s2TMjUtf7zxwbik/f+OPv/Ydg8Nufmz2wQ3t",
		"ed0H3xBOLj8/MXDg5IP3Lu995axO9YaWrh85+9ncYml2Ue7bd0rIBdAutu3dpgsXLmptqlVHSpnLLvRlMgoEAQIiECCgIcpmH0lnryq75XCpQvEwwWIFA4dj",
		"8dgqSYvFIrCtmQC7uBURDx/eDyBu376jvSofYwyzGzXav1w9c+IIEO3fO7j5uDvT20VEie69mWNnLTt4/i/8DKI4+V2fsYPhYDjWO3gIEIRUQCSkAoBkd7+y",
		"7G/75N+3AyEhxHf82P8tGO4IRWKpH/q7yrK7D7/ReeA8EEjLImP6jBECT334J4VSygqc+t6fsaSsLC191zlbBe6RiQrc3HU+YSKZ9rvDhRB+WN3iljKgLBsq",
		"VWXZRtDYw7HmX6bSadu2p6emXpCsmYqTVwAEANIYE1RBYBs7hnke+gwnpmY3f6U8MTU3MDAwcfvK5YUrp7/nJ7/4z/7Sj//DX//av/2/fvjT/6gwfvXN3/t1",
		"ZQUOn/q2xdxs37FvFUI+vPLf3vjI3/wP//ePfN9f+aeRWOfn//GPffYf/YZXnPjSv/0Hf/F//c2rf/ir929e8lzn9Lf9QHZ6bHby7vf9lX/65X/51068/j37",
		"zn//7/+bv/LKj/7sn+oTVgE/nJrv9UV3o2dYLBaTySQiSSm19srlZfR9rlvFu4XFKsnoQmGpJ7JasLQ2QC+IignV0d0xnl+OoAgC4KmOL7+bf6N5NLBQceMV",
		"+HhjmBekF9wOhDoSEUBMdfcjQKIzI6QKReOp7gGl7Gg8BWQsFUApOlJdgNjZt1dZAalUZ2aPkLLkyXTvECBG4+lUV7/nueGOhFspO04ZAFJd/ZF4WiAEO/cN",
		"daV6vVljTDhg07pWzX4joed54xNTE5PT/ZneSDQKnvHVGdtH4KiXYL0Zuy8CmmRnaK5cEYYQUAws//xy1/Gbd2sanU6nEcVCNkpPq+WSYVijt5Dx2FqfobL+",
		"+l/76T+++9+MOQgA2nfY8N05jNFGo9bGaGMMgUFCo41vZUdEQKS1BwREtZGmxviTY32/DuM3pOi6cYfnaYWAaEi08+BfOT+bQEo50N/XkG0hRDAYqhtNt9Ev",
		"EZUttYlenFQA6vz8cmcg0rf/8CsocDL6V+/PRxFqVtoLOVcbIYEFmmFelDjac6rac4DAcyr+t75fkudUQZHWnvYcv81Pew4AedWK39XiVisERGQ8pwJA2nM8",
		"t+p5rv8n2nMAwHOrRntEoL0qARpCok012RAZy1K+B3+99q42xrtlUIyEr/QagCICrd00bXilvhjMVg6n44hUBSPeKX4MYBlh1t95TcYVoMgXoqRZphnm+Z/D",
		"AgDReDocTaDAWLIbADoSXUKIsglE4ymp7FA4ZjxPKkugjHQkAUQs1SOVJYSMp3oFCiXtWLIHQYSj8Ug8pT03FI5Vo0uhpTggRqKJQDCCAsPRpDGa6h2GsCmZ",
		"pkbvIm6UsiCk96YkAKRjqjuyusJBG+N63ouyYRjrDd2w7f3Sjkioar2oApKgtmuYy/F4WYZ50TyVEFH4ZknKCvieSkTkW5X6nSZ+t4gxRkrl3wABtfakssho",
		"rbWybOPnQIAQayZNTZ0lRAROtUIAZIyUQkq5qfQDipZ7iRcvXjRaT05ONn7o+yhVTSAgqms9lXacwcHBSrU6NzsLAN/9kdefqEHI6h4WlTySfMuEToquj9t6",
		"0rbK49OKnFuOS7nsHHAPC8O8SLkOIeUf/Or/o2fw8JEPfeK3fv7vfuxv/tzv/dI//JaP/5382OjIn/6WFQgeOP6Bpfxc5/5zKOT0e386/OGf+PV/8pnv/LF/",
		"EI2lf+3/8+lP/U+/ml+Y/tMv/bMf/nv/4dabXxm7NWKMOXTyg+GOVN/RDxnPBUSBwhBdvHipUQZNhgDg/Plz6zyxCxcutp/wBaIxsWUlAfES1Ah7uawzIDC4",
		"fPeP9ux9ZNXiJ5cYhnmh5hkCgJKWEBIA/CJoZVlau10HXw8Ew0IoIQQKWUvoCgkAUiohVKVc+vN/6Z90JLsjyrMCQQAQQiplC6kC4Y7szMM/+/K/kFbAGD17",
		"++1KuTR7/6pTKZeXK9VKdZPpDkRAIVb/QxQCq9Xqcmn5SSxJMpna0uo9E3LVQQ3BgHJSMS8YsI8ckIZAKu4zZJgXclZWfWIh1scVkqFwNC6k9G0oGllgbNwM",
		"0Rgv2T2gLFt79XbB5vtBKC/lENEOhKuV5YgxRLpSqRaKiwAwODRIZv3sAPnZmKmp8VW/6O7pmW3V744AXQkkACVaz8pKpLryW0kFbCZf9KjJ8wkLNq30A3Er",
		"C9DRaQxVnSogOBUDZLR2+RhjmBdQo4VUzXE0opCWNXH3mjGkLFtIKYREEIDo30wqC8gEQtF3fu8XX//+v1mmgJ+zFkIKqYQ/OlbIQChqjHn/z74UDEdRCiEk",
		"bLGyoqXL6mwbQxICmMvXbp/KtPjDTQr05ss/mkZ3CUTaqB1n+yKOAp2q+Z6PfwAFAgEiGENVx0EAgJouH+vco5S0lFr1OGQoGFZ/9NujhSx3tTDM86jRiEuF",
		"+Ui8E4gW83MAsJifA6Lywr3FwpxlBcqlxeWlfId2JYnlpTwQFbIznueEhHznG187/T1/kcgUFqaBqFwqLBXmPdetLi8tLxZKxSwZ89Z//8LZ7/zBTgOeWw0+",
		"Dz76ZnNiqo3RunYpUHXK6/veCRSWsh8n1kYE12kuiUGFFq1cK/KouqZ2hQyhgHW2NLcwFwJ2rDyfYXYnsjczsHvqOowxZ4ePodHGTplAema+ICM98/klCKZz",
		"xWpumayOfjuxt0QdxkoUSl5+saxVbGahYMcHy66azxVivUcXK5QvlILpfbnFSqGqVEfGTu5d9EJaxSDcO5dbtBODyxRbyBUEAshApVoFgHg8DkT9/f3rPMPJ",
		"ySltTGlps0W+XR00tyjWfr0hsVSnbVuBYDAQDAaCIdtSMhAKBAKBYKD+wxb/HMfVRvtfnzpzMhqORyMt/kXCsWgkblvBSrUkUD52RqpBG2OtNQCAsuTYvblq",
		"ZfVuanFxaQdrxqdm5/kIZziO3knODR8DAiFER2ftzBHv2QtAHZ2DAKDsQCgaX/03oSgApPsP+d+lBw4BgLLsYCQGANF4GiDduG0AAIBiXbUmlGjn4NLi0iZ3",
		"22qx7NbzAxUTCorylv4kHgkBhpsjzxBubXf3za9fAYA33nij7aWAQ652bCtgjAFsDJOhp1sHvya6F7J/c+MgYIcsYhiGNRo2b6jk/39hcbmYXwCAWDxVLGSb",
		"/7si2IynAKD5Bo1vm3++OkSt/7ZFTLhFgVpcGO9IDwDA4NDQ2MOHrTpe4EA3AJRb9hkmk6lgMDg1NdnKepSEgNdefwPRt2R2Qdq4pdQLtj/vEAGi67ml8pIA",
		"aUgbAwQmYAWUsp6OTAuBhdzqZPT9hxOO696+V36s8hQCFBgMBPnYZlijn1TKo1h3r/eVtPm/K66L6z9ZdYO1X7T8q1VUq1XbsowxiLXRslgTyFrPi98LsyLf",
		"KlRzU3hLoVysSiJU0iSCbos9O2r7h9CUQCBAsTYDQGR0dbsZcgooqyu0x2+zlFIiqkBUFZbmrScv0yhEpVJNphJAoqk+Zycf4sH4lJKSD2+GNfrFQXseBgKX",
		"33mnoXr+HNumrkICFFJsKedAswVtRFSYpWRmd+w/+icgQEPGGC+V6AXA4tJsI+PxFJCIS+VKIGBb1opoNxyJwA5dkd17MA6KP9sMa/QLhOuZ5VJphWSEQ57n",
		"VatO8y6W19phYz15E5sw5IwnOsNhuz64ltCvftBuPaBF47mtXJsDsGX5Mn4zvHYdCGpDsFTKlUzBdavOYth6KrkOQxQIBBzH9bxa0bh/2eJUqyitlq900zbW",
		"lvHcYrEgalOAGYY1+kWhWMit+kk4MlQuV/P5XLs/8Tyvs7NbKWGMTqc7Fxbmt94BiAAQTyQjYVuuuDanJ5PxN57r+FNjQsFwGKNAtOhNhUMd4WDEn0Pol1U3",
		"kjANyd7BcgttTDgSyi7kWuSjHVfIx5JXAhCIwSDnoxnW6JcAse7sLCGE47iOYzo6otq0dMnDY326Hjy23fOzLUsqRUa/9tr5RsXaE6tvFL7cau057hKhRSCW",
		"y4uNATQEJIUM2CFfnYWQWHv+ZgfTLcaYeDK+attw71D/xPQc13UwDGv0Tim4KBZzABCLx/K5+ZbepO9OqoYHXotiPqoNkAWi8+fP4xNOCSOiUpbRLgjwtBdJ",
		"x2bHZyIyuXrWjFt1RdVWAcerBnVKSdsYXVFZgWKnfVnWFrRolleG2d2eSrDrigE3c8tt3H0kHLIs0d8/EA4H/aHjT8+2iojIuEWd6EhLqSwrYCnbUrZt2bYK",
		"KPkoK90wjuKPA8NwHA27rQpwR8JaI6NCL62V8UqlGgjYU1NTyWQqGAxIJQnoSYfSgIgqgADLpSLQsuNWCu5UNJLwh4c1ch1BK2zISKEoUPGwCgTCe3oyzT3c",
		"DMMavTEt21Jax9ltxFyTSHZYlizP5kEJWnNdb/x7yOWy8XgiFo8R0dOYnkUECFJKKTESiaPjBZq6Df3f+3uGiFh1l/2shO9dxTAMa/SuYXq8d/iMsmxaWVvn",
		"K+n4+DgADQwM+Fo2MDjYnPGYv3FNRzqUlP3RMgB2Rmhu2QYw7Qr2UIin6vsKoD2YnFo4cihhKnq5shSwQ9TKg0mgatSL8yeCYVijdxO9A9Mz6+9f+UoNAwMD",
		"/heP6EgAgOOZ7HIwFvBuZ6Ni7bjVZtO5bWW0yWjY1mYdAdkqYAsLQ26gEkzEu2YXxi1lt8rAszQzDGs0vLD5alotxissmEUjfN5WioO2Vw9HAACBoNXdF3s4",
		"eTtMcVeQ41RsK0Dc98EwrNEvkYgDWIKEaN1qmMtmmyJis61JCNb2ntibb76pPXfgaIdtha+98975188/jTw4wzCs0dC60zptKTRN46qIwPh2HE0W9USUz+d3",
		"8HEtNMmgK6Vpt86xeLxYKOyEpRD5/dSbj8Clsu6MLOw/iYCAtZFi+BQmbDEMwxq9duPLhEIRrc1KEcO1U6Z2VqMdEtllOxbw/PK7Vb9NpzsbfYwoBJBfIo2N",
		"J/Pa+fNbSHoYg5sLq/2Ehvb0wvzCQewEIgJyvKrtVY0xSlnPyO2JYZiXVaOJyBjz6quvNvd2r8q9Xh29uuPSRASGEJFabBgCGCIyNDU909fbUx+jK2rPgYio",
		"lsbeXMU0bi2NjiikyPT3T7xfsq1g0A4NJF71LfEW9bQxGrlphWFYo+GpZoZh1UCn1RnYJ5CQtQX1RislR7WsjiAi27b7ensAoJBdKGQXGr/qHxgQiEKqmpfo",
		"ytMJAYEhFOLRniEZIoJ1txBXyS4i1l2cDIKwrPonQfNBwTCs0dB60ugLVlfgEZYcZcl20km4QRUzIiIZY4xeG02TMc25YwQ02lsnXy2U1Tgt+TO0iAgRSHu1",
		"ejxArutgGNbolwgCWPZkUumWuQgE1Mak0ulwKKSJpBClpVIul93K1QGu8+0qd6eNagc5B80wrNGbYEesKZ8OZhMtJBJpnVIMKcTc7KyvyrFYPNoRzeX4M8kw",
		"DOw637szJ474XzycmHpy02x9K4pH/7ZLRyINALF0P+zcdGxEbNmNzTAMa/RuyQwAwlB/35MwegZAIQQK2fRv+68dqRZBd8RT295vRETdFIkXCvmmPUAWa4Zh",
		"AHZRrgNRe96egb7BoaEnoVBEFAxHVo0CqZaXtyevxUKtjHrRnzK+TbcNei602E9b83Yiw3A+ut6PYcyOV8LhSiXdKb1JpTuDQUtrr6ura25uro2fPjZ1PCZ9",
		"yTPG2AHbdR/NV00mk8aYXVha7noOIqrt9p0zDPNiaTQiIJ7fdIvds2WqsvjeyHsfevVksVBsMwCVhDBGxvw2lnAkLISojQpEbNbo3C7ZLqQVXTaWsqpFImNU",
		"krj2g2GAZ2U9F8TiCf+LLqvj5MDeeP3b1SdAQXN5fXtGNPoMtdae5x199cSRY8eMoV3oZKRs6T8pRDTkLc4vdycGUrFew7kOhuE4ercEkJtwnKv7bKznWodr",
		"Cu+klEKIG9ev+t6ku3AVxm/PdmbiykK/4Drdm6wuLXvawwB/QhiGNfpZMDIy4td+bD6qLeYWAKC7My1sO9jXt5k/9OcAlBaXajcWyrakn/RIJpMEADvturc9",
		"0JaGDCJobaRQy5WiFhoFSlTb66xp49HHMAxr9FZKFyqVqqc361URT3UXsrOz8wuxeEJIS0mZSHbmc/Mbi3ux0Pg6kUxJUUsrGK2DgUBvb+/09PSaUQBSNpUJ",
		"Gu9Rw7dQ6lEBuPFQWkRktIeAjV9ttZPw6On+/FzJuP4AQ0JUUqhWwoo156c1uNrFdhaniEQkgEcjMgxr9OayGwhABFKKhYUF2GwtRzoSCSodE5YVCEeM1obI",
		"suQ2Nkf9OSy5bNZ3v+vp7d2irR2ufCkr7LA32dpDRI8sUhGLxcVKtQpmY7s9RKGkDSvFmIiCXhKxrfWHlApCjmeWeP+RYV56jSZqLzR48cIFMgYFrvLD24y0",
		"EYABQjJaG6ONkGI75cNNf+G73z2TwmeUqlRaAhD+EzJeJEBhoPU0moiEkI5b8UJlSwVWjuwiKVXbWQFEUiiDLmc7GIY1eoNh24joeJ4xRgixpaIFIjJaK1+q",
		"ERH9YHzLpc1EpJoyErF4WuCK8YZPrurDP6NMjE9mXulYmqtKCHmeKxABQMkgbuLkIlAQmbJZtCFIze3s5N95mwUlIq4PYRjWaL9JRGsPEdvEc0RkPE/nctlY",
		"PC6kFYvHfbEFFIX8eqXK+Vwun8sBQF9vLxAhohRiYX4ettMLbgAg3dmptQkErKdTikdEiDg7l709dSe2ry+Z2Vua8jS6UOsn1LSZ6xMBxpiAHdbGFSgJiIhc",
		"r6qkvTP2JQzDvMAajYhGa9eptpsnggBam3A4FI0O1ivnAv7OmJByfY1uMFXf3xsYGNh2RjwWi0shUUjP85xNbVrShr8n3DhWtWzr1LnjUhRtK1iipS3pJAIB",
		"IoGp5NxEX0e5WkJAqaxUons++1iWWIZAsk4zzMsQRyMiovDnBLYNY7XWdVk8efIEAIyOjsLT27EkIUSxWPCLPRLJpG3Zvb19BACAxoDT0rKfmnqyPZDgCqma",
		"696EsjaThk7GO4zR2fJcNVTSpHHrIaw//LBccF3lWNIKByPohDzttLl02YBEIpnP54hFmmFesrqOtnIxPHyyTYSNz+TpBYNBy7L8E0rDS3X9fADVZqcQkMF6",
		"stfPlzTSvi3zJ/60RMerBkLBbHESvbiU9jZS6rXMSc0NhbTnbnv1OE/NMFx7t9mSuGdzMjFERGfOvgG4yTmzcOnCmwimtjVKBtoPivWHY60cOwsISERKKI24",
		"VZspBCQyHbH4cmXp0d8+ztohh88Mwxq9CaEwxiRTKa1NUwRKAFB48k2A2PjfpoUdEYuFIgrREY24jlutVoUQxphAwEYhqtVqJBLxw3JjTKPKMNEXHrs9HgxE",
		"mppTaJ34dv3NzPrdbqEWhYNmhmGN3n5RtW3ZZD2qECYgBMBUVz47twvPKoVCHgA6OqJVp9oYh5hMpqSS2YWFSCTSsHOSUvoaenv8UjSVkmXp13gIEAiCwLTq",
		"kkdRrz/xo22q67KnHcuyv+N7v+3ew2tAYIwHAJ7nguUnpFvI8MjoKII4/S1HLUtwDQfDsEZvR6CVElNTE8/jdbpoynWgQLHyWTVHuAEVsWWICBAEAGpyR66M",
		"rk0lIwqtvYpbjUZiREZrLWTDFU8Y0mTo93/rD159bb8SVsAOUxnCoZiuaoHoO0aRIUPktx1evXrVL9r75tcvHz27lweDMQxr9DZlevMkkyllKaN1MpXKZbPw",
		"TAuCV7b24arGHH9T7s033wSAU981ZAXVn/z+2wdfS0Yj8VJ46viH+q//yZRZtW2I6DhuLlfIZQsAkMlklperuSZbks7OrlA4dOvK1BtvvAEuuOSmQ0OOdLT2",
		"quXy1WvXhcCm8kcUAokoO5/709/l2boMwxoNT6VTxtOWUqZ1VIgbaSrt8KyZpi1ISwUSyaSvzUYbKWQjlP6Tr10hIzqi8d74/t/7za//6E/9iFDWtT/7yvTE",
		"9EbjFygWS0gl/XE5lqX8c5r/UqSUxpjLly75pwSppFt1HNcRAo0xATsIQsxMT/PHhmFYo58ShUJ+2yac+VWdMvi4gt2c28hmswMD/R0dHY3ObClFI6LOLSwB",
		"QEdH4o9/52J2ofCF//CfhFDCUhuWx0WjESCqVsqAQqnQ5OREOp0KhyNAhCgQ0XVdAtKerlaroVBYay+fr1n9dXVanN9gGNboXcWzzFMbAme5FApHAPDC228D",
		"1ivw6lpOxiwtFVPJ+Pz8QiKZDNnWRvluLC0tAlE2l/fzPPXGcATAN998E4DIEAoB4GWz2Z5ee4VlSs3aZGPOnDgCAJev3uQPEMOwRj9JhAQAdLJkp+BpT/OK",
		"I6Jt29VKRSqlpAKiN998E4iqjgMAiUQCEcORCBEMDsUBYMNOdCFEMBgkYwaHhqA2gzELAE61+uY330SBQIgCtaeJwL/NslPdnA0hwzCs0U+MRDKZbzkx1ngA",
		"6ikJ9EpLOQSDAAtT92/dmxjcu39wcJAIEMjz9NtvvX361Ekphee5D26OzBS9wcH+ZDIZCIc3CsxpbuxOobgYTvYkEwm/B93T+p0rF8+/dt62ba29yclJqO+m",
		"2gFbSrlFq0Ls7+2anJ4DgLMnj7buyyTiKJvhmbPw0g7Ngq2nhTs6OraR6Ugkkt09Pc3yg4+XjW4WxEJhERGVlJZt17f7ABCFxL179+TyhfmFrJRSKTk42A/1",
		"WYsbGn3Ytm1Zyt8sBYDOdFIgDg0NYj154uQm6rupnkAhmnIdtO7K+ieYarV6/+FE1XHa/dPa83M1Z04c8VMiDMNxNDyfPh1EZNAIam9b0eaKXm6jumN7qipw",
		"x86RlUplbnZFi025UpGRVG9GAYDneVIIx3U915uYmOzvzwBApeqISOf4+MTJ4ZO2bTvV6voPsbxcLmllRdOReDoYsolMteoV8gVfYT3PBcS+gycWFrIAYNlB",
		"x3Ualq3JREwgEgIAxOOpVWJdLGQtJQHg0P49G77ShxPTUnBswbBGP981ziSlCobC9QZlcKqV5t43RCBara1EIASOjY09rZ1B2kbM3o652dlrN95PJBIDfd33",
		"xyb9zsB4MtWQ145ouOJ4hex8f38mmkgLFPNzcx3xxABAdnNzwrILNcEtFRZKhRavRgp0vNqSzs/N+l/Ekp3xjrDWnl/UMTDQv7YCvSOaQcTBwcENzJuEGHv4",
		"sFqtHtq/Z2Jqlo9ehjUannNvUvloPsjKjo6RK6OAIKVs7GP51WniuQ3QUun08aOH/a/3DmZqGY96a3gkHPI83REORkMZROFbZneEM0QUi0aEFGMPx7aehU/l",
		"c9l4InF19Gp3Tzciup5OxGOLhfyDBw/37Bmqz1Cf7whnjNb+pYznNcxgT0KTGawQgsj13UHaabRlWU90PA3DsEY/s7BaWfYK42YptdZLy1XSXtOc6x3u6ibC",
		"TTvzPy7a0wAQj8cLhUIikQDAfD5X+zaZQIFgiIi0NgAG/ddrABCM8RCtbTxiPpf1raaGhgZ9Cz1ENNpLpVJrC0K0NsPDw2vv5NSpYf8Nsi1LG2O0bvcWXLky",
		"wurMsEY/B2q7zddpWc1TtIUQntb57Dw82dI7AyBhiwnxx+lhD4fDsVjMGI2IHR0RY6ijI0pE2tOIePbcWadSWSWCV66MPM7D9vf3+9MSfBM+rU0wGBwcGvJc",
		"Z2qKWwoZ5sXTaCK/z3jVjy9dvLjhGNmtWHqKVaLZ29vru3euOg34ujM/vx3Hu2vjj+LT8a2nubc0JKBQLACAMdrzVp/JEAAR/UEzOx+/a91oixkePjkyMmqM",
		"Iddt5DQYhnmhNJqItPaqlfKqnxu/w2J7FRQtcwPeilFUllKe1muD3Ybn8mNMGNxcqzgCIFy68NY6j0atHKeh1rSSLBZy/vMdPnlibcbgCQ06qVSdaCR87NhR",
		"P5U/PHwSiEavXuO8BMO8wLmOVrKISETTU1PwpDqnDRENnzy5ShNHR69uqG7b22lEgSvKh40xxtD6tR64WrMb56xiIbdtIX4cOSXSTz7ZzjCs0QzgWrlCIlx3",
		"wGE8niwUcqWl0jYeL5fNxuOJRgg8Ozu7Iye3djJN1LpK0B+Rnkymc7mFrT7c+MOxZDK12nGvfs4bG5toNMgwDMMaDc/C9y4HANnswuPY5vkh8Gbo7etZG7Qi",
		"CiKjlIUoPdcFoNWBMQEKEIqIvJa6boyJdoRDYct1tW0HAVGgASBDEgA81wHSAGAHgs1yXM9HmbXpbz8LMzjY393TJVB4nubMB8OwRkOTo1AiHAoCgOt5jVa3",
		"x6ezq0tJASgqVc+fmxWPpwho8yLbLhhvyP0G75aSn/yJj61IBBH4RW+u63ja+fKv/k6bdAwdO7P/5sgdIrXKA3X45MmRkVHPc370pz6uRLBUqhDRV379Kz/4",
		"qe//0ue/9rEf/VgwGFAWAcByqWTq0TgBBQPh3/iVrxqtjdZCikf3KpDIWJYaHBr80Z/62K/+uy+SflJuSmdOHGHjDoY1+vkz+iwW8ogJIEChtlDs0SZF0Pi5",
		"54HrVJttowuFLOxQML7JDVXX8VpuxyFK2wqdOnWSTJseEI2IKO0W5Ranzx1HCdoDTcu2jQDwyc9+HAB+5Cc+BgDGVKoVBAClArfevQUAh44d+uLnvvyJT3/0",
		"Iz/y5770K/8VAFeMQiQAQgL6gU9+T7XiEMHw8DA73jEMx9ErhW8nx3hjvWtjbnf0T7brxINXTh9ob18Ch44dRKT12m1QNOct6j04jQekQ8cO+l/88Gc+BgCW",
		"Cpw+d4IM1u+29senzh5HBMuyEeD02RPGgR0f29jf183t4AxrNDwbN6RdNsaQnqO6BdpC6+OOLNrhE490nwhriRSsnRUAd37pKpXyvYcTRBSwbT6AGWBv0qcd",
		"J65Tx/Ykr5ellARw5cqIaeLKyCgA7aA73Qs4HIaADL5/7TaZmkAT4PvXbq86GVCrvqStFgh6ntfd0/2t3/LG+TPDp4ePu54HvBfJcBz9FK/iAQCcqiMEjoyM",
		"rukMRK2fYDy7uFSJRmwiun793SbhFkLIxcWlF+ktv3W9llPesXtDOPTqofev3SYP/XzJKycPNq5L3rl8lTQKgQJRGw0ALY07NnlCUFJaSiHi6WNn/vW//3wi",
		"EedjmGGNfkq5BinVw4mpB2OTb7x+dvU1OwEKUa44T+7x87k5osSaXAEBikI+B89DdIxI/oYhCmq3cwgAuixR0fq32eQjvn/ttqlItMhPdxgtmnMdfvbjhz71",
		"0S9//jfL5YohEQpa2360mrITGSKlVGm5zK2MDGv0U5dpIfv7u6cmp2CXbTPG4wnfFm9VKx+K3aHgCO9fu00aXzl54Na7t4wWr5w4sFGzjt+fs/3tAIKaNPun",
		"h0eTzdd0oQsJ2WwWAEJ9fY9/tSU216DPMKzRsFMlro2vPa0fTkwN9ffB05pDGAoGjTE12QKszweQjbl8PrFY1BizthdbCKGkWFhYgGecJiLSaJxa3tw4ohHJ",
		"tuPm6N2WNzh8/OCGD/fFz33lR37i44ji8oVrYPDUmRM3R+8+Kr8jWJOMhkQync8t8PHGMM9xHG2I9gz0Pc1HDAWDiKvdNhARgPp6e8tVL5+bB4Curi6ttTG0",
		"yjpudPSq1iYQsAcHB8bGxnf86aXTnZ6mQn5hzWgu0trzDe9XKfWqL9rF0aSRdOsg+ta7tw4ePXD7xp32CWv65Gc/5mnzG7/8n4EQkB7dG9YKsW9dv3Xo1UOP",
		"zgGILNAM83xrdH9f9+17D1OpdCQa1uu2DhOBlHKrE636+vqEEKtiS2OIiIZPDjf/fGR01BhQSkKlNt9PG2MjItAqNT91anhkZIQMadCP1xWZxFadLLZtu8vL",
		"a2cnRiKRz//ib/zgj39/41kbY/xUjKk3ZhtDd27cPnTssP9zIiKi2zduHTx6aL3SDgQisALhV068oj1TzyeQf4cAdOfmHSIavfLu0uJyPlcYGOj3PN3SBYTq",
		"z0RrD4nzEgzzAtR1ABgyRmtj1tvMajksJZVKh8NBveYPfUEvFhc9z7MsZcxKtcDGf3HV3tTIlZFQOBSNRsvlsjEaAE8On4RWG1kjIyOPWc7WrpXckAFcNQCX",
		"vvzrX6uUqwvz2S/+8ld++DMfJSAhRDQcGblyzWg69aGjI+9cNy6NXr9uDF268O7Z88cuvf0uIqLAT/+lTwrhQdtxVIBEgB1v/8Gb4ahtZAJIE6Glqq8c3x+N",
		"BrS2L124AURCSCHUqibMZp13XPv9G1Mjly4Rwaf+4kehXryolHRdj486hnmOe1jOnTtXLpfXcftsMzOJiIjMas0gAiCSyvJ/fmpzTcnGGCHlUqnk7yKm0+kn",
		"3VmTSKTy+SwAROMpBELEYj4rEJQEAIglUsV8Np5MAwHW20SqFfc//cpXfUvVatWxlCWl+sbvvVmtOJayq5VlO2D/yGc/bow5cuLI5//9Fx3H+8Wf+yUAOH/u",
		"XLuGHUPglfPXr15Ttv2jf/lHnErZsgJC4Bd++cuO4xKRbVsoEchIib19vY1U/qpSmIDtFnK5amUZEf/Pf/Nrdn1Qmedp3utjmJehFxwBYDw33hGNCSHmF2YT",
		"yQQAnjx5YpW4G2PCodCDyYWOsOyIRvVmh4Ngs38+Ij4Zf3zo6u62lCSCqakpAOjs7AyFw0AGAOIdYWNMOBSMDA743wKA0cZoCoVCg0ND5F9woACA7EIunU5b",
		"ylpc1NoD24KF+ezf+Hs/jQKMR8oSntYL89l4IgUACILAtKxPNwRXLo/6L/1Lv/JVAPrhz3zUGA0ArmMKhVxvX/eP/eTHjYaf/X//m3g8Ho1GzJqidUMUsK1r",
		"V28QISLkstnOrs7mqyA+6hjmxffriPXE3Lll17OEEI67/ATi3KfR/+04xnE8X5RvvH/nQ+k0Gd2Yu4oAZu3UKz/7rHXDRYOI+gd6AdDz9A984lt/+Tl8gskA",
		"AGXHSURBVOfHtQv/8P/1d0qlitEkpaiUnZ/8qz8WCNgEBASX/uR6u0T/1aujf+Xv/OS//9n/AFSbFP4rv/CFn/iZH/3Epz8a7Qj/8s//xx/68e//wi99lcgM",
		"Dg0Sae2a4VPDazs2v/H1t23LAgQhxf/0v/7tX/mF/wQAk1MzfX19fMgxzEuh0cWZIoBEFAACUe7ZM7R3z/5yebnljSulfEc4/fSf5Kt74PqD2tfHhuDdh6tv",
		"EA7bU/UiP+26fsx+5szpzScELr9zBQC0NogCARcXS9oYQFFcLDVa2BHRcdxqdYMOoJGREQD4pX/9q1WHCsW5Gzff05q+o7NTCHRdN58rak97ruvbl/i98oAw",
		"MjLS3Dd45cqIUmpk5Fo+n5dSvnL44Of+3Rf9E16mr4ePN4Z58TUaEbT2+vr6/KDs1Kla+1m1WmmdxUZQgY5nY4tkmqqUTYuKZYEYi6eKhSwAHH/1iFJyq8Ou",
		"zp495bnaCEcIS1dRCHHm3AldkUKI5kfbbNMH4vKyVyjmAOCDH/xgLrtgjP78L37Jf+ZKyd/8wu8tlUr5XB4AEolEOBwiQ80yjQjG6GPHjhntFYuFvkzvZ3/m",
		"xz7381982i4iDMMaDbvJ6o3aO3kaYwRVhQxSbVYg7lwmZCt3he2KOrLN2fMdatjErSZyRkZGCUBKbPiv5rILAJDN5gBQa10oFFb9ST6f74jFXKeKIPw5A34T",
		"ppTSr4aeHBsDgJ/7334B1zelQkACY4h4LiLDvAAavcqRZ/24ExFd1+vqTNc6PjYRS46MjBCBUrJZVRFhdHS0jdDijuS83799L93Zue2qB0RAAbfevXXo2KH3",
		"r99eT+4IUJKwTLOUo6Qf+8lP/Nov/gYATE9M9Pb3Tz586LjO3gMHs9nszORkTyYzOzXZ3ZcBgPu3bwkph/btH3v4sK+vD4CuX79ujCZCKWWlUgGA+7dvK8sC",
		"gHy+0Fx8g4hAK6d5EQCi9jy/OH0TFxKEiJ42Hzx/yrKty6M3+DBmWKOf0wibDJGUwvU8x3ECAVtKAYS+68b6em3Mo6iOyK/sq81qoVZngsd3rT58cJ+Sktq4",
		"aGx4N0eGDxpdk93Dxw9uEJIiHD5xsO6pRIh45dLVX/2FL8zMzE5PTLx64oRVt2Z2iguDh46mOzvJUHdPTyAQKObzew8eAoBkMpXLZYnIcyoiFHaqVWXZnmek",
		"kslUAg4eXM7NAEC6s9NoY9uWHQh4rtNi3GJ9EUdGRoFASrnRnHUCRECeR86wRj+HGDKNI1dKEZAWAcVi0cmJKSEwEklUq1UpJQIaMlrrFmkCRK319PR042cL",
		"C6snIj7M3QOAoeQ+/9uBgYFNpaY3FVjjttX+/eu3aw3c62kXHj27//3rtxq94MZQOBp2qu7Fb14IRYK9/f2jV94BgP6hPX2ZDPX2CilnZib8l6k9LxqLFYrF",
		"ybHaBuiVS5cqleoHv/VD8wu5h/fuBoMhT3tO1Tl97mxfptfzvDe+8wOJeOy3v/I7QPbGORohSsvlfG5TE8iEFEAs0wxr9NPNLV+8eFFrg7gtl2GicDAshPAP",
		"XM91lVV7gfsP7PNcTynr1t1bX/vvvxkJRwcyg3/hO/5CuVpea+G/YVwcsINbfWo3H1Jbz+ynuHFmyAOCg0cfueIJISrLZTtgvfGtbyCKK5cuHx8etu2A1tp1",
		"XWx6kkSAQlSr1a6urnQ6bVnW9PR0b39/X18vIvZlejs701dHRk6fPWeM1sY7+frJcDj89d/+w1y2kEwlAODkyZPt1nZkZMQQ2Urlc9nrN26FwiFaNzuPiIFA",
		"gA9ghjX6qe79KUsJqbTejk+0MSYUDH3ld78yOT0eCUfyxcKnPvrpvt4+13UQ0ak6REZZVtCOdqUzlUrpwdj9x+h5o+cn30P+oNiDRw8iivHbcwCgteN4ywJl",
		"I6HziU9/VFr4G7/81eXSspTSsizwK0EIjDEDAwOGyBitlJJSCkQismx7Zmqqp69PWZbR5qf++qd/4f/45eXS8gc/9C3pTLpcLo/fe7BnaD+AGB+fjMVjgFjf",
		"WmwTFwvhV092xKKb8T7keYYMa/TTY3J6zlJqfm4OADKZPtr6NSwiGjJvnHnDcapCSK11LBbT2msKjYXnuul08rM/9OlKtbyQm0dEsZtqvqj2v608J9pAoK1g",
		"4Pj5U35SXYCSwgIAKdShU/ulsJuS7kBgPvXTn0qnU11dfaFQ2N/cu/zO5VriiAikAIA3Xn/ddb0rV96plis9fX3dPV1auwLVyIXRj//Y93Wne0vFJbfiAkAs",
		"lPztr/xWNNrxgQ++AQBOtXr16lVoM4eFCCxLTU1N3b738OC+ofGpWeSjk2F2i0YjetrbM5h5nBgVAbTWQwN7Gz/xXMeYhnlbrQ4vGgkbo4PB4NDgXtfZ5mAX",
		"IeRW/+TYHnz3Aa0/6bbegd421lz7C0S/dK21QCvbvviH33TLFT91SwACpC/IUw/fx7Vu/EDdiej8xH0bUQqpPT3YE0eJANCdOTh4qEta+M6fjjiO57pVIvr7",
		"/+h/BDSl0tJXPv/bhszkg+mhAz25hZyooH+W/diP/QWt3f/86//V8+CdKyNnz5ze8ISjlJqYnmOBZpjdotGXr948e/Ko76QxODRExjSC340v42u6VlMERHSd",
		"qjGmXt+1unHD3w/0/6u1t7putx69rx/F5yqLi0sFAOgK9Wx+1jhp2DAf7ReQXLr8Tts7NAQAJ4dPrPSqMzIgyGypTpvanQOWSqWOZBQFAoGFoF3tJygQUEpl",
		"PH3+284LKb71ez6IAsulJSIQKF577XxVL5EWh44fCgTtWtkMUbXiggRAgUCZvt5NPTd6VDxz+epNPkQZ1mjYPRNnyRjXdYXAzXQtY22EHwGRkMK3uHv9jdf9",
		"yq31Q1FErMs7AsKVKyNQ904SAlvWfvkNgfFEGvKQDHY0/7BdbkIqavp64zVwXcfT2vjldy1K/MC2FAC42m0OPYXC46eOapdWufIjouc4577zA0IqAPLTGQIU",
		"+ElmMO3CdTJE9SpDgeir7a0rD/26QKfqENHtG3cOHj0ohEAEapwfEMhQuVS+feOO/4PDrx7yCxYBaGJiavN+HazODLMb6zr8yHdzFR2ojTFGCyGlFJVKFRED",
		"AXuriWxPm7p/EWhtAMAY8NbY4yUSyY5YpCMaBICOaD/Up2oBUDw2sLRUannnV+8/+vra/Y2fWC6XX/8GA4N9P/zZj+Ka6Pu90fdbjk1BRLdSvfXutcZP6hUd",
		"ePvG7S0tVEAlmt+jw68eapkVR0RE0fxbBCQiqdSJE68+X9utDMMaDduuBVZKTk1NfePKH3z/t388EgkvLCzEYjHLshDBGNpkwcbFixfLlaqllGVb2vNmZmba",
		"3dK2Lc/1Wp4AjCGlVDKVymWzj9PDAgDxeHxty/Wqm3vu6iaX2zdutZ9rBYh4+NXDa3/e8ofr8OC92UeDuNZMUhCIrxw/fOfGAxS0RoXpk5/9ofs3plyv4jou",
		"H3IM87L0sHTEOzpTXYVCPhgM9vT0+GZsQgjf73iTgTsRVSoVrY1lKwBIJDv9GYarsCzLaH3q1HDLxItSKhgKbkejt9fzvVIi1xHodWbU3nznLrXpq0FBR07v",
		"b236gfDe1Tu0Mk1CREoEbo7cQpDvjdxZu2sghLStcLVS3aiBkGGY1TzHx8xiYZHAqA4FCFr7tstbuJL2s6ta63w+77iaCN65c7GlQNfSGtjWP4SIjG5xYohE",
		"VMuvH2VaPDeT6evp7alLp9w4ad/uX7tNuPVvv8n7WTWv1kXT9I884TiOcVG72qz8lXHRuMLvaeQJLAzzMvaCe4seRAAQX3nllWBwC41n6DdiWFZnZ6cQwnXd",
		"7zz3YSGEkkprvbCwA3Os93d5V0stvoZHG4lWuVKh+rvgj8san5wZyPS0y3V88XP/+fTZE61yFwfX/vD9a7fbxdGPdXpeo+aiNqoGW6o6H2YMw34dsE1HIyK/",
		"bhoAAnbA87zZ2R3rXtPeo8De81YE+V1dXcYQEIWCQQKI9PdrrcvLy+++dwsAxqdmGg0tiOi67r49A4NDQ67jIKKpitaiSavbC40r2xqFbCZq3mZenWEY1mgA",
		"AKhUq+ukMojM+s0m586dnZ9fIIDbt28bYza/2biVekJo6cwRCNjGEJHxS541kKUsR1mF4mI0GjGeEVJIITUZIYSfxq37V7Sexb26vdC2gkG74hkDBJxkYBjW",
		"aHgWo1i+r+8jhkh7HiLStq7ZhZREpKSsuO6FG2+GwsFMx9BTeAn+KaGxCUlEV69eEwjHXlmRsujt7Xv70jv1mm6AVo3UfrX44eG9fhx9693bR4ePXPzTd/LZ",
		"xa6uLiUV7YIolzjSZpiXMI7GxsjuNqEi1lsQWzezEHieRsSq4yilDvQczlVzT/G5U3Mc7Ae/APBwYvoD54cnJmfuj00ODAxUH10rrBMOY6wj4t/dmdeHb4ze",
		"7IiFAwFLkNg5cdzm/YyMjgKgsizPcWB7doYMwxr9nCo0IAohULTwEfZd+TdsK0+nEgAQDNie1olEMk6pQiELz8D2moQQy8vLADDU37tYqgLA3sEMABzavwcA",
		"YvGkMRpbKycS0T/+B/88nkgB0ODQfiJSlnJdr687EQgEGoPGHweBErabqpYSi8ViKBhE4KwLwzzPtXdERET+xfv6IZ0QYnl5aSo/OTk5iY1OQUBttNFaaw+A",
		"VqaDRat/WK5UKpWKpzUQENFagY4nEql0+klfqq/Kg0tByWQSVow9zEFL7ySs/aezM20ptJSIdah4zIqEMRaVQgqireejW93c0Uu33r2F23x1opDP+22Z6765",
		"nA9hmF2r0X7plhBKqc14eAqpCvnin739RzIqxYpkdGvjOFyDEAJQlMuVcqWqPd1OhW3bDth2TT7qU7N8oPFv55T65nt3bt19YCm5tmSt/X4mAWIgELDtgB0I",
		"pFOd6VRnOtHZ1dmtpPT3JNdTxVX/AFC1qAbff2Tw0LGDj5MnUUoJIYFgZGS0pVlL7f8IAODMiSN8cDLMbsl1EICQEgDGHj6MxRORcGhkZGT45Mm246RQlJdL",
		"kc5IT1cmEAjSFvasCGre9VAT2fpvjDG2bff09PjNiuWK60/sJv97REQcvXqtdg+Poj6qjwQU29hFGxkZgaZp2LZtf8e3f1CgEEIEgiIUiZDRmUzGrw7U2mup",
		"0n6Gt3GOcZr6rX3HqLbXIrY5fHy17PpTa9dGtIhq23Gu/yQmJiZSqVQwGDDG+CZWq8bIOlUHAKSSvMHIMLssH02klBqbmC6XK8pS3/rB14mMbOMUp41Wyppb",
		"mn33vWuxjpjrumht/zL+/ffeR0RAVFJOT09PFh9kYntaBXnkel7DC7SWBhZSoiQApZTrbs2JQkiJSMZo9L3j6rItpVhaKtlKzMwtAMDg4KDW2vM8pZTvqrrJ",
		"bMkW1oM22VlOj1mEeO36u8dfPTY4NCRMK8s9xGKx+P7te4cP7hufmuHMNcPssj1DIiFlNBrJ9HZ5ngcA5Wq5jXOmOXL0lfyVXEekQxvtFh0K0VYTvms9i40x",
		"iWSq3e810dzcnP+DuaXcQnHCloH9PYf++NZv7EudH3799YXbM1t6uYuL5UJ+IZPJlJaXC/l8vbGlU4hQMBhCoHQ6pZSltSEDx46eiETDRJ5uGPLR1ucg0ur5",
		"rk85/RuJxv1LpXVuY9v2xPQcCzTD7C6N9s2Cz5w4YoAmpmbH8/eNoQvvvtlOVI0xwWDIDgQ87QKA1hqF0FoTma1Hk4QoGvqbSKTz+YX1w++uaBJlVSkbAI7t",
		"/8BisXpwz+GtanQhv+CfORoCnUolEdDzXM/TgGJhIZtMpcOWrbVbqVYct0qk4/EYEQEBKqrlcAGBwHgbyRoBCkJF8MgpiUBsyeDkcUGBE9OzruutGWqD5eXy",
		"K4f2s6cHwzwPtXcIHdGYb+W8YX7ZGAIAz/MCgUA02mFZyh8XArU+Ee0Xb0Bbb9JLAAiIyWSKgABEPrcpm47OUO/D3N1EMpWWA+kkTN568Pglx/4rIiLHNZZw",
		"ErGoNI6A4MnhkzPTM4YCZCqJRNwYDSCENIdO7EdfcrV47517m1nYw8N7wdT2VxGACM2mx7c8fsajUqkABFtUSZpHW77+L9ngn2F2o0ZfvnrTT8h+8NuOGmM2",
		"U9HV2FxyPbewmA0FgqFgFxmzhXAMgYxRlkKALTl1DCX39w8MaP95bnePSzTtNFrKUpaSUkopgCwUCESep21LDQ72O44rREJJgcIiTQhw7/qYP5920ztsePfa",
		"OK2eaEvrT89qVZK+5ZZO/xkeObR/S93zDMM83z0sRCZoByfyD6dLk9Fwx+3JWyePn+ru7vM8FzfRcEFEQqBTdYrFwoYC01KVJsbH/S8GBga29xLGx8caX8/W",
		"8y09Pd1CquPHTyAiAnmehwBKSb9z3RLS9VwAZQllyCCiNsaFyvrJDgKSKC0VMKbt7TYh9SRQaKoa8gRsNmmMAMaYvr4+Y0xbDSaSUjZK3RmGeUF6wQ2Zjmhs",
		"Pjt7OHMkFAx7i+5bb77pz5w9d+7chvuHRBQMBmy7s55nqIVy/hw/1yME49drI2I6nV4VGGoShdz841z/p9OdCwurHasdxw2HFZDx6/maKgWhUq6Q38oiad+r",
		"e4kQEG5fv4uwofE0aqNL5SWgdk3zdPjkfqJ1arD9qb5w69o9JRDQkCc2E8ETgFJy7OHYuzdvBYLBtVdIQohKufzq0cN+v6Xkg5JhnmuNXmXB4bhOPJa8Pfl+",
		"vpA7ffJcXMSFwPrvqaVk+NtWfsWbUhJAtVQm2wZ/8pafEFhlTi1QOK5b2LxjZys5C4VDsNAu44vtXnx9WK4Af2D3JgNaQvDkOs1Md27cPXj0EIFZnQUBAkAB",
		"EgCJ9KHj+wAJkW5cfAD0KJpeN64mAAhHIn53+1ruPZzgQ5FhdrtGnzlxhIAE+v0i2C7xUK1Wg8FgrdOvMatJWeFwsDRfKkGphMUjA6+27CtRSmptxidyjusi",
		"VU6dGl5bZrCqdBgfVUhTs73G9WvXtN5gKJdQzQXRrd3vWr1G/+VTK/GlcCTsP7eHN2cRUJN74MiBWyP3YLtN3nUJpQPH9t26flvUelVWz2bff3QPgLl78yEC",
		"+s/MsmxqaDQZAq+NeRU1iiYnp+fMmth7oK97K+PNGIY1+lmocyMWM2Rc1/Na1XWQMZYVyMQH7sze6oh0AIIQAgiklMXF/GuvfacpOWSoOLNsjGn0E0J9vGxD",
		"M8rVqpICAXPZWYD1nNiwTYW1RCQCpVR3dzdB23bw5lng1x5sNiMi0bT32MBKpQKEgISWBwCHjh3Q2tDj+fWjAGPo3vXpoJUAg4BgyCNqTh/7uSAj0UJUft5D",
		"2tQ4jwkQe4/2a3LWRtMHXh38zf/4u/7Xmd6uianZrZw9GIY1GnaXp9JApmdZlKCV3b4xxrYD8XAsthyPRqOVctnzPERhNIUCkVvvXX/9jW9fnJk7nNnvi3Jz",
		"SpoIhEBAUTOOqImCeZwni4hKSd+5Y0defjzWIQVKKQ35SmlAiub7RgSjCcCgQEtGyND992bIkEBBaIAAiACBaGuFxkSAJLRxL7150Zf7T3zmo8a4AKI5R4Mo",
		"h17pXZu1ITLj7y+8d+29A0f3r1XbL/3qf1HK8mV+cnrOX6vLozcB4MzJIwAwOT3HxyHDPAca3d/Xffveg454cjA2qLU+d+7sqhtcunTZTzkMHzwlpRwbG4OV",
		"8wtvXLwMAPF4oqMjSmSIyE9eExlEdBx3ZmZFp0kmkyFjHt+vbqf64sKRjqmpyUwmgwAjo1dRSNM0bqsppiVEIZX0jQIB4Oy5U84yAJKQ0hDYElxttlqWbsj7",
		"xGe+H0gQEQJKYa+8PCAAEKjWZs4JjG/G3TLp/vEf+76vfuF3/XSIMcbPdTiu1yhvBzTseMcwz8ueIS4WcvGOiDG6umYO1vHjr/pSdWVkxB8f1ZJCIR+LxxDw",
		"8uV3fAnzbe6I1lYUoLd9iUZDprLsrGPW8cogvjdGa79ud4UvpRgYGCiVSkIIS0lnuRiOpYxfLkd1dQZEgUSgtXacSjAY+Pinvk+gfP/qXQBZWi6HLZpbomQ0",
		"tOWibcJgMPSL/+rzc7Pz8XjiL/+tH3dd3RSO4yNnPAAC8/DmhARZP3+YAAbHb06vvde3L1wEgP7+TCbTB4CnT58CgL/aqAgU4q23LnzjT9/kQ5Fhnq+6Dlz3",
		"an2DuHW5VCIiIYQ/NrBarfp1xDvVM+dH6MYzuVwOAOKJZMubWVtcaETUWvv3OTjY71Tl2NjY5PRcprfLv8Hg4ODY2Fgikcjn893dPQvzucGhfjJ4+/27rwzv",
		"RRG/dvXmyT7vc5crqQ7cunscGWjsoNKv/9KXfuhT3w+P6hQBm5xsCUCAcKhy4NgBAHhwc9I15YPHWuQ6vnnhrU/8+Ee+9Pn/4u9GhiPRVTeQQvBxyDAv11zw",
		"hYVaRVtXT6/RXjabXWcw+BqfzE1ZxYmmwodCPrdxq/dm+uoQpZQnDvddfX/K9TQq299ng6Z6EgDI5/N+WTE0mdUZ7d2/cWNycm583OkwAii4jfPir/3CV23L",
		"7u5JWyoARLeujTeqs5WSB44NGmN8o1QDxn9RmvySDDx47JAmd23a54c//TFt3HOvnVMysMrGiehR5TXDMC+RRjd3Xnia2huEqrUWy4/MobHtuFgiEEIIYR73",
		"6a0M7V3XVVJefX8KAKanpjeqM3k0K6tWE4OgDVUdo+TW8uMjI6NEZFkWgUbET//MJ7/wi18hIgRR63khQpD10bfYEYsQmGn0Z5Rj3Xj6/QNH96/V6Fvv3j5w",
		"ZG+7Ku5HI3QYhnkJNXp+Zj07umKhWCjk4/E4ABQKhUQ8ni8UNrzP2hQrxFx2m5MPk6kuIpPPLRCZZDJpCMjoYrFIRntEABCLxxH9SkQoFvLNOXAA6OvrlVIA",
		"iEx/v9bwpc//lw+88UGPSv5pRQjcljGsWFxcDIZsJa3ycuXs2dMEfv13YzZCrTbm5tX3picXjDF7BodQ1tI+fCAxDGv0zlMo5H119r/djEADQC6X6x8YaJh1",
		"bGfRJQSD4Y5oyPO8cDiEKAAoFosZY6QUg0NDzTeORiNSiJoUInZ3d01NTQNAKpUKRyJGawQgIFuFanmDrRdLE4BEzOfzmUgvIoQjwUuXrhDQqdNnW+QhCKpl",
		"xw5HyZBQuIkmQ4ZhWKOfJPF4HEAIIXJ159KlpaXHLAPX2qvldrWhpjJtKeXYw4d9fb3KsgAMgFwqLRdb5rsRAODU6dM74hhHBIlEqlyuhMPhX/7XX7At2xhD",
		"xgjxaHIVImhNR06+cvYDpwjMe5fuVLXrB9GaPP6cMAxr9DMCVSG/EIsnAeDu3XtVx7Ft2/N0R7Qjk+kBgMGhofXHi9QrqamRhkbE4eHhVVmCkSsj2vMAYGpq",
		"OhmP5gpLiVhHsbi46q5S8Ui2UNrZnTYUIp/PAoBtB+dmF3p7e13Xc10dCimtV2300eW3ruw7sp+okU7GoVd6BQrOLDMMazQ8o6G4tcB1//59ANDf3z8xMdFu",
		"62/dobc1QVxdF0ekLOVp7dULtnOFJQDIrxFoAMgWSm09l7alkghAxiSTqXAkIFAODg2R0VKhbVuep/0nT03O04dfPWxWtmiKx5hIyzAMa/RjVl9oAJBNrkgT",
		"ExNd3d1SqR20pr98+QoZEwoFcjno70kIZYEUYw9nNlNVfeHtt1EAEOUWS35T5dLMNACtY0WyqvpFSJHLZe1Al2WJ7/vU937tV/4LEEkpfF8qIpJSGuM9ifks",
		"DMOsw/PaPvA0Swn8IQC53Nyq6aiWUgIFERljdupVlcsVAJiYyZeW3WK+vEFwT/Do0YkAhW1ZSlmWZW05kiZKJtMf/9QPIpnM9J3Xho+dPX/WDtg+gUBAKXX3",
		"5oPmjA3DMBxHrzPa49koxa3bdxAFkXk4Ng4Ex0+8GolGdySZ4p91crlaPV82lweA8cmZgUzPOp2YgUDAd3LVRk9OjK+wIlnbZ9hqzUZGRxHRaB3tCIAwruv+",
		"2cWr9uAJy7JXNBYS2CqMKI1x15q+AkK7EVqHXz2oNe8oMszLo9FEKEQ7i4wnzaGDBwBgfGJyoD8DAOFwWEpp9Hbsj0dHRpuzx4gopYzFE8GArZQioqmpqXYW",
		"1alUMhKJAMClS5fqlxX4/q27jlM9/urRVenvR3PAlVnpZAeAAEhGk7SU9syXP/ef9+47dHfJ3aeVt1xCUIAIQFYQlVC9ezuJPL9SkADevnDJgN5/ZB8KeO/a",
		"bWo5m5wABRw6PtRuEd58800OzBnmxctH07Ntm/AFOp5ITk9NAUCmv38bbiSEdRfR2v8L160WC/nYwIDneYjY39+fyWTq/SOklDU2NgYAg4ODi0uLxhgiEihQ",
		"IBmDSIcP7QeAnp4eO2B7jrtWMVHS4ZMHG5Loed7UvenSUunmjduZ/p7+/n4hqLsz1d9nlStl4yGB5/cfVkvm7uT7nnYHDwx86fNf/dRPfULVe8EJDBGQIePJ",
		"lqH0lXdGDpwYvPD2RWyTWENA2qlkEcOwRu+OSBp2Q29bw6ZDbPHJzM/XUtv9/f2l0nI+n4snUoV8ttFr7ptkGK0bOkvNtv+I+Vw+n3vUf9jV1WVZamBgAIUw",
		"2nMdx492V2mhduSNC6sntoTDkTNnh40xfl7bcd2q4wjhD5VFBBBCeJ5GtBFRSEFE/9v/8n8AQKavVyox8d6MsFQwECs5i2JNvYrfevOff+V3HrXcr/E7NQRH",
		"XzmYTqcXFha4ZZFhnn+NRvTnYA0MDrS5SiYUcrFYyOcLu3wHs1HA1xDoBqtKMq5cudL87Z279w/s3+vXZb///p3BoSHXrQjAYrEkhIiEQ8eOHV1t30ogLHPo",
		"+KFb795aMepb+oNUpG+OtHZQmed5sXjs3Ld+9+JiSaD44c987D/+0pcBAAR94jMfvX3t3t1//wvxPftS3/E9TmkJVz4oAhIRII2NTSQSKQSda/OmuJ7e5HBy",
		"hmGNfj6Caa/tKEKSkp7QwT41PVMsFv3RAdFoR3+mFwD8xpMnvlHaeElkzp4ZtmxLa6eruzORTBjj/vBnP3r//QeF/JLxZKwj2vopCUBJh48fhBV7eocA6f1r",
		"t01VtkgoAwJQxSkUiwkppR8Xf/qnP4kArud5nj508vDyD/yAu1zVjts2Ckbfri+7bhMNl4EyzIui0RuW/Y6MjEQi4eg2Ky4IEI0xU5NTmUyfVKrmgEFgjPZD",
		"18n/f3tvGhxZdp2JnXPuey83ALlhyQVAdW1d1dVVQFX1SmoUIWkc44gZSaQkUlwkcUYjxzj8b8L+4R+OsH7a/uHwOMKj0IxMDUdki5RISiQtyRMxtoeiNFKz",
		"u7ZEoaq32rDvuQHI7b17j3/czEQikQCyCkA10H2/6KhA5/LyvQTe98479zvft7icSgzqV/eFowsLC33hyDbzoyOw0/Y8Nz2SAoBf/Y1/8v0//r9+45//eqVS",
		"9vn93/7D7/7qV3/pwXuPzr101h+wJ999IF1v19KeOy7R7R0uzmdfegFgSx7u1tx6MjkJz61c+/k3WPnu/v0d3NXOCbtMtDEwMPi0zLAwMx8kbRohnRog8GCr",
		"IGUGm5UcTg2Gw32FQhHq5nm5trHDQxpr7PDgF37zl4ABkX7ly79YLpeJRLVS/fyXfxGRzl86BwDVak1Keegz2YiCuSOfMiK5lcoHd+8hij2OaN9rGOp4AcPU",
		"BgYnj6M1PTzN2dvlfN0eZXjreM+b1y4CIIP8u9uP9RDH6HDoboOj9Wz3Yeu/ucMRITSFyUKIZu5t4+dmN3lXLRsCI3Wy1Ec4f+n8B7cf7i3g3kuksps6upHv",
		"QoZ7DQw+GbngfeGolgBkMhMda8kD8m/3FN8jNlsUv4yAV8cvE0Hmzp1atbabF8ehLEAyY6fDh4vXzhxky8ql92896qw4t9SRDJ0ijI+NZyYmAoGAjo8xMDA4",
		"wRxNiMVCrqcnyJ0SlD7uQWQMUYlZAeJa1u3v7xdCIGK54h4uRyvFu22w2+NH6NhwZoV7FcoEHUvsffHhvQf7vA6BlRFsGBiccI6eW1j2+X0zc4u7vSA9nJae",
		"fI571DG2FUFxYsA/+cFy86HenuFD/NSFhYXdnvrTP/rBF37zc3ssr7HCC+NnO3L0h3cfqCp15lIGILg4fma3K4D2vHv/1qNdXiD2W3Q0J5qBwSejH83Q2l39",
		"uKD70RZ4IAQAvPn65dYyFwQhyue8S24gaZcXALd1V5pkrRQ3IrLw2UNcGXeXJ2uZszlfDAw+lRx96+77+odrly8co5LLsvyeWq9WizNbJfOZ/ohXqqiA/znv",
		"S2urgIF9PkdK6UmJgETo8zu1akXPCn7/rb/44m/9shDEjMzYvfqaUH54/wEAnHvpRQB48N6H9d/OjUlg+OrvfCFzZ6J7v9MdVbSppQ0MPunaO3x+MhJk5pmZ",
		"xdD8IjE/+ub3m9qSh5638dpVvHbI65Z94WixkOv4VCVwyl+eala4zPy9b/3QcxURksAvfe1X72c+uPXuhBA2ESEhg/jet/5KSvVrv/Elx6lomkaEOzfvssTx",
		"q2MdCdqTzr3MLLCPAT+89+DFl8/VXL9WiChFiPitP/g+8uFo4/Y4WAMDgxPJ0dFoTCmp1HOxUqrnPwEA2H4fAfQkBppeE6zkmt9/6EqyPTjLsyNQnpJSm0SD",
		"J11B9js33xkeTo6MDgcC/vmZlb/5ydv/8L/4uWKxWCwUhhKJUqXS29v759/+zhd/q968/pNv/PkeVzkGRFTnXrrYuBSWmPnFS+f1sy+cP/1Xf/ajmbn5WDwe",
		"8Pug1TnksA/WwMDgRHJ0T2+PlN7zd0fTGVGqZa6apeTD1ijopMRiIReJxnt7gnr7hKD0TCCucE8SEQHSBPCjb/8HFKI+0ces9IsQELBYKExPz/X39xfyeZ/j",
		"ALJtO+Vy+Ud/8h/m5xaj0WgwGKzni++AIM92yh/de3jupdPff+svv/LbX6jVSn/6zR9+6WufB3AP3qlobXT3hWPFQtacewYGnxyOZiWVlFevXj0uTZdDIumh",
		"RGJpcbFZV7K2tmAmbYHUjCcU1Iyr1TtQt89Geuvrf7K+XlJKAkJfX+/oaJoIY7HY8vJyLBZ1HLtQyDfdTYG51bR6K6KQAQWfe/n8mQtnv/vNH21ulL/x+9+2",
		"bfGF3/wVZlLKq1Ms7zXJkslkWlcrsaE0z0xMIJKwRCI5yAyCaGOzak48A4NPWD96b23XSYVtWbqonJ1funZqyFUucOD1V6+1lbrbqJHhpzduXb8+blmiVq0g",
		"om1Zn/3sZ2q1SjAY7O3t+eLXPvf9t/4ym80i4Tf/4E81AevRRLIs5dYaPI+2Yzd/BlABv10uV4isd2/cPn/u9MjosJISBQQCAUAaHBogFEqpjo2OTCYDCEhk",
		"6dRHBCUlA2cmMgBYq9UAwBewf/1rv/K9b/7A9DoMDIxfx6E5GQEgWVZruMAhuv+oRgtgODVUYssnbEB458btN167vutiKRIA/4t/+bU/+v3vzHfSkn/vWz/U",
		"70CgzY3NbLZOiGtra2tra4nkEBIgovTkzPQ2IfYf/t53kMCxfY7jNDs9Pp/vG7//x8tLK+mRpJLAipVSRKSU0iPgSilN9L/+tc+99fXvra6s6a1FohHHcb7y",
		"O5//s2/+1U/fuTE6kh4ZSZXLFTbuowYGJ5Sjr1+5eCxOYOZmT8GrVomhvLLS5Gz2PDmaPqz9bCXfTc8T3XicskKkb/3Bn+52Y4Eo9FT36urqzmcr5WpvXw8A",
		"eG6lvRa+M5FMJkZGRxWrpibacWzPk5P37g+PDLPyhBD379/3PGlZFrNSUgnLYmbLtv/4332/SdAA8N6995Kp5Ft/8GeBQLAePokiFAogktF1GBicMI6+fuXi",
		"8flGSIhmpRxKJAlhNJnGBv9llBciIkFHFEAejvTtffl49+Zt1/Wq1VoulxseGZnV6VmjozPT05FIxHacmenZSCSiXz8yMvL23/3t2NVrRJS5fevV19+cn5/P",
		"5/PhcB+RGB4enp2dbb49mUyk08Mz09N+xw5HIvqeQUpJhPFYbHZmNpFIlMslKWVvb1+pVEIAf8C/ubnJrICht6++5yOjo26tujA3PTDQX615qyvTjiP05eHf",
		"/d639bi/OfEMDE5mrwMhnRj4eItoy7L0XfzI6KguqHvffHPr+3r7bQSoVquHJe5uKhz6+sLBUJCVwt0778wMSNVq7d7didTwSLlUqtfgGxsAkM/nw319+gf9",
		"+Pp6MT1yam0tCwAkrM3NTf24NlZtjCZCuVR/vFotA0AymRAE//S//urX//Uf/da/+DIRJZMJAHDdmu6c2JadzWYBIBqNvHf/fiKZWpyfu/DSpebWpKeIrJWV",
		"eiGfSiYBYGVl2ZxvBgYnlaMZeDg5NLuw9PDx9NnTo4eURfWMejv9QzPKpLq50XxWuq5lWctLS5P37gPA5ZcvdbnZ2nbdYF9f2PE5SqmBwUEppWPbtuMA894u",
		"oPVKnzA1PAIAa2v13oJmTAAoFIutr2xNC0skU4XCtpwqzd0AsLq61vYDM3/j37x19frL9UDcttc3PjeXyyeSKQBIpNLNjeuNDCVT5uwyMPjkcDQhPXw8bdn2",
		"2dOjsViMG7WnUiwESqmep6rj+ivX91hFZOZYLNbKzt20pxcKAmCr3SwEBfw+1/Vsy7ItCxGBFTO88dp1QASWXWqNDQwMDEc/D3hS6vJ5ZHRUel5L4YxaHn1M",
		"pHeao4PBQCiYBqKNjXIuuzo3N7fvOpggbqvWlVJjY2OEzSguEIIQlNrdvIgIQclgwB845OQXAwMDw9H7hPV5yWTSsi23VkVABhgbH9Nchocqdzt4J4SIKuVy",
		"834fAJLJ1MLCfPeDdtsU341jw4YlCO5eJ//03VuIVC6Xmm0HAwMDw9HPQ9GBgK7nYYOymuZqxzCKFBFX19aWppdty4qlYrpxcShNCQTUdfqeTvyEgOYP18DA",
		"cPTzrlAR4JVXrruue5yDRxFRKjk8PDwyMgIASikA9jwvlUppst7YLOUaK3jC4pY2RYeA7omJibZoFSHozdev7zbwgoTVarW1hDcwMDAcfeSa6FRi4MnM/BHE",
		"1MJRTJAjoJSy7rLfTCBUSjt3qhbjp9m8AKiv/uULcjvXE5GQUiERISASEp25dHF2dobsgFvdFDtzbBkAyetmzsXAwMBw9GFJ7hBpanahUi4fJo2S1egey8Ol",
		"6euvXEdAKT3peW31vlLq/r37rVVxLr+rPCOXywKi3+fUajWplC6937l752f+4Wd322ESQrpuwO+PxWJNsd3RzVri83XtNjAwOI4cPZwcevRk9swLwzrC1ZPe",
		"oTQ6hHAAgFlKTz5Pknmq/nMuu5ZKp1snti+MnK4uFv9+4W+14d3rLa4dSjEJVqzKG5VC4cgDtoUgVvqewUMyNG1g8CnuRyuWABAIBt1a7RCUv8xNwbL+N5PJ",
		"tC49Ng1O1XN3o+6G4omorsSr7x4D4Dvv3gIiACQSiNt6IOFInFD19PRot1LLsppTMEopz5OIaNsWAEgpNzdLgUDA8TkAsJcZN4KSSnoKpPVHv/9dQdbw8DAA",
		"uK7HzJYliEhKJaVELRVsvIuQoN71AQDw+exyubq2tmpOMwODE71miJoyD07NSIhkN/3puG5njMxKKkZAAK5UKsBAgmzb5h1S5MzEBJGARm4rAnaYZ8Gj6gCs",
		"Fwu9PaH5+fl4PB4MBhQQACEwIK0XNxktixSAajvwnt6A69Y0d7d2qxHBsoi5/iAi9vQFAEBKlxn2DipABNADhozM7CkPAAQhIDIrz1N64wCwIyIYm49IKR3H",
		"0qupu/3aiMT6xnohXzC1uoHB8dZ14NMkeewYEidhMQMiEtmN+BRGJCH8gkSl6q2urkRiA8y8VnSrtZpPeKPpRE15O3VsrBQJgUjMiplv3rz1ynaaVlLtXYRu",
		"Fbl9VqFYJ82+Xqu4vs9yXzgcofpSoVZPEyApZkACFIXcSjgSoe29ICQEZEQcHxvToVed1k4REaRUgWBICGIE6Xq1cgUF7nvjMj4+tnNrOw0CWw+9OSOamZjQ",
		"WTF7db1R7fzN6vXkZhKxgYHhaDj2Ps6gjep3nORSayQEOVxPG1Ftb1TMPp9vZGRUs8e50SQSep5bKm8Q0k7WEBZpN7hINNbbE2IlbdoKQRFIZc+TUnbq0iIA",
		"t3LoaMy72/DPOBX37q53eENrcFQoFETSXk4MSm9KXw3Y77ebjenWLeRza729Sd7N1qTxCDMQUa1a2SJSevqZ8rbtY+cbCtzi9/H9LrtqcvK+OQkNDE44RzMD",
		"Ckv4eMeanJRV3X7lLbv8zsOBzSZAuVLW7ED7LU7mc9ne3h4t3G5t1eIumTATExNtwyzS21I/ex7uu6Y4Pz8/MjrCSrY00JEQgFkQJRIJKSUAJJLJZsVKiMCC",
		"0GPgfWdbtsr/I2vXHFx+nk4MzC+uAMArYy/tszzLbMptA8PRx2c9jXcO4Anh29fV6Nq1V9qZ3avsRlKIID05PDLs1tylpaX6kHZLuc2It27f2vv+vWPdudsV",
		"oTV9NRKJ6te+8fprrQcOgErJUrmmA2HcKrB0AYHIIZTBoJ+Zuxo+xOPe9fXc2tTsQpcVvmWZFCEDw9HPsVbWNkMAQEh7Eg52MpzDp5DA7U1VCEpKpaSOAQdW",
		"JKutmxaoFKDa6v0iswJAIlSK8/lnMbDv7++3bQuJOvl6IAAQkc8hXWkuL6+0viAQSp5oIzwSNgDoFs6ZF0a7f+Ps/BKiWWs0MBwNRxuwUh/YIxJCBAIB7SW/",
		"u9EdSlnZe3MkHCLxbHFW4+PjwDxxd7LZt0WWWK+7G5cCVoQ4N7/UfFcz0OTZsFGlaGUpGdysesEynH7j9etNVUnz7sF13ZWV1XC4r638TyaTwAJBZjKZ8avj",
		"J+uPT/+KPAm6zx6JDeazy0+j2lSi0yqFgYHh6EPdAyEAYGNjg5mnZ+eUUgPxmOP4dHHamEV8qnLp8MpKtBgltHSgGUEBKkWH+Hk9PpXbELmNvsRQ3LbgnXdv",
		"AiJwMxCcAUlKOXnv/s5IgWq1FrJDiFIxZDKZq1fH9/JyajREjpUDte7hI+JTEfTx9NsyMDhJHN0sotPJwT1edvrU8PTcwqMns4hw+85dT8rXX7kWCoWuXBnX",
		"QjR9Kj5FXYx0eAODbR/KklEqQuR0OtWyFicP5Rsr1aywD5RinSKIhEoqxYqZpQKiDseVza5ls2vRWDQUDEqpbt++o4Uu42NjO29EWNVbCoiH0JpuXkeaUpOn",
		"3yYzMyu3ydSPnkxblt3V7xrBEqYfbWA4+sBeHFJ6Dx5NAe6uamDQDtHMAIismJmR0HEczUq1ao27K1URQCEKVVUUOCD3EFE8Ft2xsIjYYCIl1fbhwENAMbdE",
		"ECFEHRvY3x/XuVPvvf+B3+/XwzVNfPTgoY5e3NjYuPzypYA/APXGSKO+3C5dZgbHZhIMAO++e7dxl7KfJhrahC2trYZ6aR4IOABw48atp7ip4PouCSFaqd2y",
		"ndF0Ym5x5Sl6JQYGhqOfletIet7ocPJp3+g4TqlUmp+fJ0TFnEwmWsXI1co+byflHoijtwkqAADevnWvVWjMIBCg2fzNZDIH+ZSmPnp+YalYzCNajmOzkmfO",
		"nEbEBw8e+vz+YCgkiNqCboWwhLAAuK8v/GRq+snUtJTy7JnTIyMpBhnqk7uslXLdNHUX5mXAYFBsvy1xAdtSFlnWwHUJEaTiR48WEHFzc1MvnPJ+X2trFd8W",
		"4MDMc4srRlRnYPBcOLrhiRGLx7uX4zKAZYnKRqXqMglSUiGBaM4Xd1E53Zi4z2jV5Wi4fWUSEQDGxi7vvYWr165WytViMbu0sgZIrf1oRADJh6UtZuam9i6V",
		"HEolh/TPH3z4QGs5PKkcrrcEmu+anpkbHUkzq6YxiWa6ugYcMRzpAeB6AFcrA9aLYgbAYrFcKBTCkVhzLrCQz8bjsWAwpKRv66LIgEICyrbK2t10Qad8MUdD",
		"DgP4bFGpqmz+GQ35eM8FZ8PXBoaj4QjMkpTtOFOzCx88eIz15uWu82ZNYvc877OfeT0cCZ95YUQQAkClUnWhCt1bZTKTIB1o0jROsixLWwXt0etsZTPbsTwI",
		"KrVSqbprq9tcgVKpFB+SH5O+Znz04NH5c2eGh9NSSst2ZqanNdtWKlUh6J0btzzP+5nPvN581+hIehtfIiESYuNKxlzMb77z03utr3n9zSsts5D6ky0AKGyn",
		"VNbMjm19kB3fGLIdHmh+aaEYMcCT+SXLpwrFnDmpDAxOSh2NwGxZ1oVzp7t/19ziiiB69fqrlWpZUxiiTofSLWts8xRqM5FgxSjExsZ6Pp+PROM9oYCSColm",
		"ZqYBYGBgwOfz64zEnQS9NRPBYFnWCyP9ywtP/D4nnU7BlhcFKqUAD9riaCW/8+fOAEC1Wq25nqjWdLbszOz8hx899Pt9r71ybVv+IcCTqdkXTg0TkbYoqVYr",
		"SilEqtVq+kg811OKAZGZbVsQ0TaaZQDmtoVVnZnbyTMagZvRiy1bUV5zYzWvEaIr1QH9WggxnRho+3sA5utXLppS2sBw9CHj1t33r1+5CMxzC7tqqqRSo+lE",
		"Op1ulrepVIqZy5WNZgqrnjEk4QMQjS4xN0tCFIIsy6vWAFGLihVgMBjw+/2IyKxalys9z/P7oSNHt9WLrOpmb1v7sFW3Yut14UALV62kp7iQrxtDv/mZNwnx",
		"7bffacYbMivVUI9I6TV7ua7rnj93dvsUJVcqMpfLhcPRQiE3ONj/z/6bL5fL1YfvPzx/6fyD9z46c+H8V69c+bf/+zdh27hjroOKBYAQKjV19tILH917Ako0",
		"X+JzsF3gAQfKWdSHWalUHk/NtS4RW5YQwtI0bZoeBoajPzawahtawbaft1aZtuQNjILcSqm8nA8PDUDDzh9ZIaAQyMzAwCz/5u9vj53qF4JkfqmQX8JLF5sd",
		"Xga+OzGpNQZanvHK9WvN+4Dmzxo3b90SwpqZmQGAeP/A2upKc4blMGpqHOgfkMA+5nhf31QuT0Ram8bMp1849ejxlH6l67ozs/OCiAillAMDA/5AAFgBovSk",
		"lF4wGAyFQgDc2xtikNVazfFZL41fUJLPX3pRKe5SJKeHaIL+kGP3IlvSbVzbGMB59iPt6wtjS0mOiEiks8HOn31h5+un5xYEmVkVA8PRR1NKQ9dTiPvapEFd",
		"z2A3Ky/b599cWVn+z/8p+aUvgls3dfvslXO6Dns78z441vzMkut5FtVVzMzs+IOIxErevHmTiFAIVsq2hezmVr0zvT1rAdnyvuzaKgA8nluIVasvnj2D0cip",
		"YLDmOD39Mf2CM6dPRaPxXG5NCCGEKLk1dLlWq3pSSs+TUhKiVAoRldpquyMBIU7eeg8YLlw5hwTMCsHXjQaZmQXh/NyK8myLHIllJNrhSNoBA5GIIAzZPn3x",
		"K3m1xbVsU8cSDoekJ9tuZZjVyMhw26A/Es1MT9dq7rnTyT3uxgwMDEfDcRog5q3TWikUIhiNMwMAYVMjho2uBBIAjMRCPp8vojZI1gAgm/kxCodsn7eeq5RL",
		"dqhP+AILMwvDw8Pdh7Ns5zh+ZoqORAfyuS058Ol0cn1hUdo2K4kI7UZ6SvaFwz2hnmRycGNxuScxGPX5hVKAeO3qOBLqy4wQVN87BnIUIizOrtdqNWY7FApI",
		"T128GtRXrHAk1tx4IZ9F2La0e+PGDQCsVMrT09NKycuXL3d5XNFA0GeRUloEzSFfT5Oji4Vsb49fKTU+fqX5+kzmLiK4rtcMkalfTW37JDhBGRgYjt41xYOA",
		"WVariNjwuNi22qW7xQM9jhuMB4avlG7+31ZPePGDjH/otP/iZ92lzbfv3Lj08qVEIthQWXTLtgwciQ0opYr5tWc+AKU41OMPBOs6DUJi5nmA1Vo13ttjJxM2",
		"tJnk5SPRWDI5CAA9iUEAyFUrsVCwvt9c5/S2ElkxDA4FlQoHfAECgWT98f/5vd7egO6HNF8WCqZ0a6WFExGAA4GgviBNZCauXuvqXkcyKwX/+Oo1RPjRzZtE",
		"3CHJpmXV8monp5E7dzKGng0MThJH6zVCbrREkahWrSgEEeplKTuOBNazQkjI3Hwl/6EIhFhKsJzK6mz5J99x7f5XXxwO9AXlx5VtiMBKKaUQEZiZcHNzQz+z",
		"trbWKagljO2W00sDAwPNon63BkYk7AD2Kcmgtr4opVRbv2HnvQIJmpme6YtEw7092r16j3klAE4mkwBQAi4peVfWAKAACjyVTCaIxGaplM/lDPEaGHwyOVoh",
		"2XLTVpsAggFQ4HrZLTGk33wdPY+3B6N4UjIAeN5Iaig3P80MKAgAlPJGLl5FYQHA5nzOrdVI2ERNS5Bu+YOI1lZW4DA00leuXSPEzK1bSNiUdnREoVBoeySV",
		"GmLefw1QeczoIRAS1WpeOBK+eOH0+ron2uKymP2BwM6at5jPhft6Dx6SbsjZwOATXUezkuQotBqrYcRWRcCGVynXHIu3T/8ppbRWRNWVaqzj81jK4OkrwnZA",
		"qTfOki8Uevvv35aeTCYT3U2m1KmnlaD5eJh8duyl6M40Nvq8rNixrUsvveC5LiAd4q5fvXaVpdzZndBLwcw8OTlpzjcDgxPJ0czMwHfuZFqlE2NjYzstKBkE",
		"k6VLXkGkuCYEFaem+y6/CN52hiUkIerVMTOSmFM9abEhbOfeD/5gxRmsD9s56PQOsh1YXVkZGRlpSI+fDrSL0x7vS6MMwDx5+w4gICAzx/v728Yau7D5Q63S",
		"a/2iMpkMMJAQgOr8lTMgAsD19UBmZrABpPnrNzAwHN1VWSosixQ2FRlSSQB0HEdPrLiey61moY3C8NbNm57nelJabnX21v03xy5u26jietQhIrAS0bSSUq4u",
		"Wz3hYE+vzxfBUAxB1ZamWHHDuI6fLcC8VNqEzs7ILbMYgjs2TIAQWTXHGNsIOhKJ9PT0KCV36xMQUaVS3iyV/H5ftVprpWkkKpUqlo225WNZAbS2NlIugu0D",
		"BqC9DhoRgFUikXBdl5UyvQoDg08dR+sKtFBY13NuveHoeiE3ODiolFxcXCIkAI7393fqFCMzE5FQUtZqEAq2qLZ06xmBGSwxN7sIFAznl4BZBEKgJAtbVkpB",
		"8BbL8MGD2QsXQolgt81WJeXg4ICUkog8T+ZyOQDwvM416VrJAqgX5qstPzdRrpSz29cGp6ZnT40Ob1f4sVKMnezkmAERlGI9C95aSjODZVEutxaNRv7k3/8Z",
		"sAQW3AyX8SpsOZ7HiB1k6brkv3Hjhl5wlVIGQyHpeXsvMBoYGHwCORoRZ+eXKo+nGvw67XleJBL1+31TU9MXL15CRACLEJgZWSLotjMjICsWllhYWOgVFGjV",
		"9RKVS+U6rSs1EI/97bt3r78QE4Qeu8BgCXI9uZrf6LGtSyOD8b5g06W+G2mJEFa9T2I1l/I6L/TNr2yR8sJKhy5Kdod4Q2zPURVCMPP4+NhumSNaRIyElUql",
		"zca6MUhJ1apLBLZl17WFSB4KsTUy2DYiJN55592mlx4grqysJFNJIlLeNiFHWz3/fANyDAwMRz9Hmj53+lTzf2fmFoUQtuMAwOPHD1tsReHqG5+R1HA9BUDH",
		"QoBYNAqldQD86d3337x2CaR6e/KDajbPAP54FDzpOFbAb9uOTwhaVQ4DjPWLD2cqM9nSq+cGhEWKqJ4owt0osq25uRkA6OsLF4uFQ/82hlMJ/cNQYsixHSk9",
		"JdUeoVDasoM7BUfpw8nnsgAQifUvLsxE43EhrNXlpXA0Xsgta2sU2GaBjVJJYBYkGLhUrhYLeQBYmF8YGRlRKO/cyYyPjwNidbuNNwKAUnvImZnrDXdzyhkY",
		"nBiOrpsuATTHfBkYCdfWVgH6HZ9TKtX6egPVWk0QSoZHf/3jf5wtkGOzUhbiexvr2f54TyiAAVtJTyleL1WYledKBnZLFdd2ACAYDP3MG9elUlIqQgR2g5cv",
		"/qMrQJbNFEKAW7duAkM6ndZDhqo+s4iKWf9btw3ibSR+uASdTqcaTtB6CEUxs+u6Lc7Vz5Drt7W7Qb8dSCZ0OyiZSJCgTh5KjU9D2iyV2w6wWNwIBnxNFlae",
		"93Rp6zvQwTiQTdltYHDMtXcMw6khAFhbW00kEoX8KnCkUMiHo/1+n5UX9M1Y3/jLLyvme/ffq/hsxTQ3Nw8AfZEYIv/n2+8jgmLw2b48VyBfAIB8fotrwpGo",
		"Yv67dyeZgRBDQT+repNWKUlEiJTJTOgWsBAkpaIW2TURAWIkEsk3VMzaW+4w5YXMAEwkpJQI3KWHSXeT61iP8EVUSiVTKQUAiEpYCtCyrLmZGdhLmp3z+4cE",
		"1dslB5kARCREtcOvg0ns6NWgOUMNDEd/rGg1XarX1Isr2kF4cXGx2eot5FbtgQElhHB8dz78CADQcSxL2EpZIpbLZpGV3+dXdXEZIGJvGNe3t4kTiaRscddD",
		"3Q1oLJplMhPMUK3VgBkRHcculSp+v1OtGzqTngZk1823jJkcVqXnup5UChpE6nqVYMBHon7BeFqmzmQyiB0UgTqoUBew3OZvpzgai+Wy2b3rdWa9FtDhE9va",
		"GDvH6gVpH3BY3yizkm3XtlgsqlMc2zC/uOLz+YyhkoHh6OOO1ZWVaDzudxw9ty2I8pvl9YZXRqGQL+zXe1hcXNjZYVCSWwu31ZUtu9G1tdXh4eGVPYcJi4dR",
		"RPeFo8vL7RxkiX5hEWlbqK7nHzX/auu7qutCFxLCu7dvw9bYPACAdtd72q6FEFRP26n3hZiw4YCiB92F0DclSsmd35tuVT+amrUsq74C0VB/N020AeDa5Qtw",
		"bKwJ9CXHWFobfFo4+tbd969dvrAHF+XW1kCRLpYJcP0AZkYtAbJNBzveoxUaicTyz5rUty+KhZyOQWl9cG1tFQAi0WgoGJBqW8ulnWppu0CDtTK6tHfHfJua",
		"kRm4vroIAE/tXsKAROvrm8VioTccWy9kw5G4IFaM+dya1lMCgH5qb9NXyxLtueDMZorcwHA0HKeO9F7I5VYO8bO0S5yeUW4TrnXUsR0ddqvHLSGI6N69e7su",
		"CzIwq6/8888rRgA4P3bqB9/5i5npuT2+XGYQQszNzT31GuTuphuI9UVUzcKFlsvneuPQmgTd8WCl5L5I/6i+v9kel3Vs8WR6znEcQyIGptdxVCiXK7uRb2mz",
		"1HrBQPp4Crlazd3jCsEMQpDtWLLRZtdtgVg85nq85SKtk2SB0eJGwarCkQgDbSvPGRigkFsr5LO94VjrU3pSZovo8SgkmFDIr56svx/aYbpqYGA4+jCxursz",
		"hm41NCvKZh/gOaMbhd/IaEpJFgI1a/zab3wuEPC99fXvNi4xCMBf+K3PN684F6+eYebvffNHbX7ZdbkGRxRjMGjZtrXdUQ89VzXovsPVIhKN53PP3n3SGfAP",
		"n0xbwuLj75GrZ1yFAKP4NjAc/THCc71jvofRWJy394cQsVSqfO7Lv9gqv2DVnn/wK1/55e0lMX/vrR/+2lc/HwoF3vr6nyjFnievvnL57MVzDeE0f3Rnaqsb",
		"1RamwCoU9IWCaR28UK3Wdq6CQhc9Ltt2RtOJ+cWV4/+3wQfNGzYwMBx9YOyUghzf5LDt9+DUXS++xYCJr14dfzAxxawuvXSFEAGAa/Bg4gkwkiMvjJ8lW7UY",
		"UlOr+2gmk1Gy3g1h5q5n6zscztziiuY+o5cwMDhhHB0OR1pKPwbcxxHf4Om5npF2rhjWVecXxs41y+f3bj6CTnnBzHz37qSRYRgYfBo5uq+vt8Wlk4mEJURb",
		"plT/wIAlRHNETXtELC0tfaL5tXM1LaXkTrMkO1qrQESOI+7cngBGPecC2+TPE0B89uUXmPFp484TiUR7R4BbQoEZiKhU2iwUith1nLyBgeHoYwoppVJqbOwK",
		"AExM3GWue2u0DbMJQc17bUTonllOIhAR0fL5HNf1WpUYzPCD7/xF11+sKpeqjmMTibrhaesAIYAg/MG3/xK2depVa/kMeygftv8CsMWhEJGpO8M8AwPD0SeC",
		"jwAbyuWxsbF79yZ3LtowMzOPjV3RvJCZuNusI/v7B9QzLfIQ4urqMV3FymXXctm1f/9vvu3327/2G5/TlkyI6rvf/OHc7CIAhKOxQi7bG47sfO96Id8bienh",
		"wGI+19/fL4TVrqxjEESlzXIul+uLRFV9JFH1Bn17SPBaMnAZgMfHxjq+TDHfu3fPnIQGBieDo69fubj3qEgH+8097rW33O4ZAOL9A76AXymFnZiF9xydIaL+",
		"gcHVlXahQjgSK+SzfeFIsXDQtngkEs8fYGxSCOtXvvJV161atgsA0rU/96Wv/PHXv5HP5wq5rKbjjm9cbxme9KT0IbZxNAMgoY4yKOZzAADlMgQCvcFkNzMu",
		"2i9wNwMmPCKttYGB4Wj4eAYNkZ++9PakCkeiwWDAdT0k5Kf3QZJSBgL+/v6BXarpg7JMOBLLH2yuXVj299/6U8R6XAszMmOXI3DeRtbqienbhc7fPkM4Etej",
		"g32ODcRFZbxDDQw+rRydTg40S0sApZQSQuRy2XrvtV6T1V3+lZTRaL8gUMwIoJiFEI0WB1y9OgYAFomV/AoRO7ZOh8IuFWytWJyfz6GKwrbmaSGfPRxbJW41",
		"50tw0xIfUF8hmmoWBkbAWs1tS36Zn53d+xNm5hZH0ol4PM4AnucVWwyoNEHrJPW6+9H2iw8Ds6rbMxVr7tbDu12c0OiGDQw+oRyNRFMz86dGUgMD/Z4nAVAI",
		"0VTy6vhwKdXExF0EQKJgMFipVDyJLSafrtWIm5JSNQUejk1LSwfyt3zs3P1f/scffP1/+z9WDrs3XWhxGtKOrLBtjHCk7Uvy+XzCEjtzttr7Jy2Df5cvXXR8",
		"tiUsZg74faFAoFqrIqJSrJibEkYivDtxl1q+cAAgYRWLRdjLp7/hbqfz2oVgVubUMjD4hHC0to3ekoIpBQD+QHBzc1N6su5ZDAAA5XLF87ylpbVSqRwMBgQR",
		"ESHR6Mgp7e88Nzd79+5EMpmMx+OeJxcWlqtVNxDwA4DrHpQ1rlfH/+f/4XeP6Et48PDRubNn5heWKpXymdMv1K8KT6ZLpVJ6OE0kWkpX9jy5L0EDQOtkdk9P",
		"iJmZFSIqqQAxEAjWu806LBKIWelk8fJmiYiUYtu2hBAb6+vhcKRQyMfj/cGQf2Z6Nhzp39HqafULYX2ZjETjexfUE5m7JIQ5CQ0MTkwdLZV64dQwAMxMT8di",
		"8da+xNzcfH//ACJOTz8RwrIdZ2Z6+v0PPnrj9demp6e0fsCy7Ka1bxOaBVKJcDZ7aAMv4Ui0kD/E+BU4d/YMAKSSQ60Pnn5h9NHjJ4g4Mz3dFw4LYUnp+Xx+",
		"VuoZWur1CPCtereufWaFhUbrIxaLWZbVDDGIRqNEpBcM9W+HpQSAQn5V91oSiaFarZbNZrW36tDgoCdlU7Gez60Fkkl45qgvAwODj5Gjm+UzAxNSKjGgQ1j0",
		"g5P37l9++VI83q810dFoLB6Pc6PdzMy1ShkAPM/V1jaaowHg5ZcvSyk9KXUmk5RSqxEm70/tVXIGNypcFSBaVxQRUJEa2ox16E4cKkF3XEUEVjdu3nbdKit4",
		"8PDxubOn9bXBtoQQT+GHmUgmWKktGsRtvKjVyolEojEWRK7rNSUrTfYMh2OFQhYR1N5i86dkWx2Vq8PMDFMbGBzHOloTdLVW+/DBE71e9fBx+ezp0csvX4rF",
		"Yoqxdc2wDXNPHl5++dLOp/r7B3TZ6Pc5wGrhycNgbHBgMF6ryd1mx98/92TJzvuU3crRBLRhlb889XPuMu90MoJGp5v5QK54A4OD9bRBxGq1Njl57+rVK9m1",
		"LAB89jOv62vPz/7sz1iWVSyuF/K5Qj7XP/AU9sqWsCTIPTUYzXXUrYBbbp8N5GcXsTTGIFs32SRkZhWJRvO5nIkMNzA4jhw9nBx6PDV3+lQ6HIki1kOe/D7H",
		"8fmkJ5kZfDYiOs5Qrea20nE4Eo1cfTXfqZ71+30M/OorrzDA7NzMhauvKukhgm1xKBggEqXSZlt0XsB1gp7PB+0crWoqYNsu1GDH5MhhfQOe5xGijoMpFvKj",
		"I2lN0ACgY7qGh9MIyKx6e0I9oYBi8PYMweo41HP1aueBwK1BQQYFPHl3Eg7bYRn0ZrHzs0QCzAKjgcGx5ej5xRVdxLV2D0KpJCglpdSlFRG6rpvLZYeHR6SS",
		"2oLDsi0A6O3rlZ6nSzRCMTc3CwDlcsV13UePpqWUpXLZEmJlZSUc6S3k13fbDYmsaEtMplgxMANKYqn4iAcFty48sXgcsampUNKTKGzFUKlUQsEgICsFtZrr",
		"ODYcRTrfERxopVLRs+VKbZvx1BPg2oXZ1M8GBseXoxUrx7GfzMxXK9UL5083SkuJjnjh1GlPeo8fPyKibDYLABsbm0hCSReA/AHHtm0A2NwsEdkAgFivdi1L",
		"AHBPT1AptbJiKSUjkQgzRCJRJOwYfe0Tto3WemVdBxz2On02WcDgI9uyBIALz8mQRAF7zZU0IuH3W0KIUCg0Mz0NAMlkUkoJbMMx8ruH3YJ0i4Xc2traoWSk",
		"GRgYjobnnzALANevXFSsXhhJPZmZTyaTlm0DgOe60vP6B2KEuLAwD8DDw8OAsLG+AQznzp2v1WqpVKq3rwcAnjx+4nnyyZPHQlhameA4thAUi0UAYHp6CtHC",
		"euOYhbBYqfyOrvR0cXGRsp8dfE2Q5Sl3cuV+WdaIoWTXsoWCAB+0L8QloZGBDcyLCwvP4LPq9/ubOmJWSjGvra19+NEDx3F0c1ZKGQyGrl0da04MCmHlcwsY",
		"jcERm5Q2B3M6ruRFYoP57HLH2R/9SDjaX8itNsmaEI8usdfAwHD0UVdiOL+4wopdz9P3+FozJz3dxVAAIKWnVL0X8ejRQ6XU6uqyJvSNjQ1uaUcoJZVipVh6",
		"HgOMj11p1miZzARhnaAHBvuB6zanCPg//fx/F+2NO0tBUBtAPcF/QO+vfXQqemZ2Y/ajH75PfpJKKaWlIyKbzS4uLPSFI4iiYUgBzxB3a9uWkrJRiQohLCRc",
		"WFxKJrYp8JaWllLpdKN1UAaA3FEGd+nWk55/0UMuW6ILBkIGAE3Q4WjMsq1araa/Q+2R5DiOt5krAAwlEsywvLR4CHOYBgaGo+Hjnl5pSprHx8abxRs2FrUQ",
		"0fO85eXV6enpBhezkrLTTTIiwvj4WKuYq6kzU8z98ThoyQdsWVE//v+mZz+78v/M/u1/O/Sb38p9a7DU/08CP/9vp7915cNTfp+vZcAGAC3deDmgj5LO8758",
		"5bK21L+TmSBSnsfJxNDwyIiUsmm1r5TyPG9kZGRmZubHf/2Tyy9fOjp2ZlaWZaVSKQAOBlIA9UQVPfXeOv09PDxcKa56VQyGgkqp+qgks23bVigaj4YdW6ji",
		"YnIgurBiONrA4CTX0QycTgw+fDK9r/pKSlZKIYLtOEtLiw1bj6gQwvM81Zjs2GMzrJTj8wGA5ylL8BuvvKQrd/JHfyLvBe24bfcGnf6KIgm44cov/fYXp+7e",
		"Z/YAkJl/euM+CjrkohURAMbHxyYn7yHy/MJiMplcWFiYnZsfTqdgm1k+PBe3ZW5msmgP/v7+fikhl1sVDYYeGBhEIh8piUSEjmO1BJnXAMDyBaUnK+XK+loB",
		"rB5zmhkYnGCOHk4OPZ6aPfvCqN/n8zxvlzkInpycZOa+vt6NjY1Wm1Atv4tEIqFQMJtd2x5lDTt1ZszMDLbNQccFRmZFTs9///BfLW2uxgPRL8/9y8HgIAP/",
		"efUvUqHUxW/8l3/xy//aXhBK1ogI8WjUDy2Hub6+fuv2Hdf1pJKPp6YJ6dToMAAsLi7OzC3o69DA4NDK8tLTTIrwnTuZVm3ybt78bY9nMhmlVCAQmJmZAYB3",
		"l60AupeioemsCkh9Q7PS3x+X+oYGYGVlJRKJAsBSPQfSBssOR/qZpel4GBic4FlwpWOraQ/P+PryVa1W66imzefzPp+vm3G1Rmu1ZShD1n731X9Gdihg9xCi",
		"ZKWU57qbfl8fM9Yer+guzNEt0Ol/lJKO7Xz2s5/Zcr4AQADbcZRUiBiPx6WUjuM4jt3fPyAsgS2jILAtKnfLmImE1XAMZG1bJb1uZSrj4+N37mSa9zdnrGUA",
		"YAwH5GrzNaura632T9LzenrSzT1CBGZGxJ5QYH5+3pxvBgYnkqPrvvv7VagMsEcy4dLS0pMnT1599dWnmlhDRCWrwdzQj92/++nSRH8wtl7bHPCFf+vCL/2r",
		"m39YVep3X/2d0lQBVKPAV2pgoN+VTDrziVlJBkRmJtK9CGzb/lonnzxEJKTJycnGVQOFsJi9mssIsvWVVZdBucViIZ0erjvSMQeCgVKptLa6GokNMCtgudsB",
		"zjQ6+D3h6EYh12dZocGBhl8ddJN31Q7aVfmnpFKKlZI7R8SVGSM0MPjEZ2XtfzCW/QwjxYjE7uZQqP/SwIVKbXO4N2mh9ePF25cHXnpSmBWtFTQiADs+xwbR",
		"vKSwtl0Gxh3NYmYQu9wcKMZKtaqUQgCplGJGRMW4XthVs6EndCKRSDAU2izVtLgtn+3WKHWjkAOAd+/d/4WhnwfkhkzlqbXL+dzq3nYdO2caM5kJY8ZhYHCC",
		"OZoPaYJheDiNXbMOc/1jmRG4kg5ESPEF35mlnpWcuwlkgfR+AcfXH+eYJQAywxuvXAJUm56vJm1q9BeaDQfecRx379wGaCfuvkgcQbHyajVgYEQq5HMPHz22",
		"HUcQpVPbjOJm5xaG0/VHpmfmlJIwNYMIlmWnU4lnixOYm5vTP6fTaSV3LcB1ra2dAw/Y0EEEpUwdbWBwcnsdSN2EoXRpELHvZjKZDBEKq0mpDGj9whd+FsmB",
		"rBwMDfrc9Zq3EQoOvv3XtzWft1KOVEIxddOgRsSdSoxip1iss2dOd9zC+Njl5qje6Ei64VUS2c0cal9cvPBi0/CkizoaPc/1PK97QSEA3LmTqcsUsX75RTSD",
		"hAYGJ5ajZxeWbNtOpVLarO4I0xAbREJErlvb3KxalsXMhDQ7vjxx91s9IpivFKycdcY//LMw9q3Kj/Lnyl+0fm5qYhaomY+KzAy4vb+666ey5G7HDguF/JOp",
		"aZ/Pp5gR0PO80ZF0MBSSSuVzuZZ0lVjA7382jh4cHPL5fUpKIpqZmQkFA3vZ2DGQoJWV1dbxbsS9fFlJkPaPbUweKRRokWhegPvC4daYLgMDg5PSj9bC5yNv",
		"WmYyGa35ZcWFwpbF0jtTN+cp61M2IdbADau+H/B/XKIlKfjMWo+3Rkd/JyF0P705ZDg3v6i/l1aC1tcYqZ7RKE4pKT1XKaUUdbOS23Zns69+bmN9UylVKOSj",
		"0ZhUHPDbtYrbjAjQntTmlDMwODEcrS07mNmT8r/67X9KhM/BRFj3H9rW9yKBcA3BB7aFJFm54HlQHeZkkUqhYLCwVmnbSCQSAaSWZbSnpp5UKsWstkQgzKF0",
		"Wse7aEfpVDqt6/N0Ou150nVrer7xMHSA2GJbCq3S6b0t+3Usyx42SUSo++96Wj3gH2xt9RTy2XA4gkT5nGFqA4NPlq4jk8nggclJKUUkNjc3dPAHbMvokpKk",
		"ZJqvrMZ9vRZaAiwXPMlSdSpaHZ+v1VPp0H4ZggBgZXkZAEZGR3UmFgmham62Ydd3kPVVIhKWDZ6nqbORX7ONkZu6ZmAAEnGrTKGovzcGZOmn/X6/TmHXR09E",
		"UkohBBLVqjXbsXp6e3QLWxA6Pp/fZ5OwFOPG+mZfX0hbjhgYGHzStHfM9TnjA3dVuKOwRDB5Sv3eP/jd/zXz9UKlaAubWI8Vdnj98tLSoRzU+PhYs6SdnLyn",
		"WH3w4QMAvvDief3wa6+9duPmrW23Fwe4Iiwvb0tGn52d3fctA/GkIJSeN//4HgSiI6Ojruu2bieVSi4sLITDkVAouLS0ODAwAIArK8sAEItF/YGgWyn7/IG5",
		"+cVYpBcQ5e5KEgMDg5PJ0cyI5Lpu92bET+t4jIB5sQFAj/7jh7WUm6WNoPAxs4uegOfhH40AzMqxnddevS4sW5C202tUtnhoCa3vf/BhU9rRDVbW8rF4v/Jc",
		"CEQBoLS5qRMGtD10NNqvd1II0nU4Yl3xEonGs9m1WJwsYZXKNQDI5teFE9Cu39CF2ZZuhRkYGI42gGv3LwydjpIkxfKVjbOnSwN+4VTQHfIihbkKPBf5ITMg",
		"omXbwEANSTIhArDf79MO2sCAiOXKs++SY3ebVxuJ9jOrQj6bXVsFgEh0IJ9b8ST7EKGxftiiXuywCly/IJKVzS1pR2npebbfBwDhSLywXYOIjXfxc1k9NjAw",
		"HH24/KUsyxocHGy7W38GkOh8yC8vnc6VNjEJvvf9SfADQDQYypU2n+O9Anqel11b0xTm8/tee+X6Fn9p4wuijY3SQdIUu29nK7XNCCmfW9FiwmfpUgGwkg37",
		"Uz041N7l9yQDwAujaQCYnV8yNG1gcPLqaCHEgd3rebclvjodt9jaHTFBMzMopSYm7jaX7Fo8kmRzFe/1115rOk/duHm7HnTyrDo26cmDdIWM64aBwaeCo1vd",
		"/Rn4ndv3YD8Dtkxm4oDKPESUUoVCISJcW2snuFg8xool27F4jJkRGkZxjRZDdi17uNcbRHXv3n0hRL1MVoiWSiQSddc6VswKsINJEzRM958BwVAItg/OHJOI",
		"QTRdaQOD41ZHMzAhIeDr116emJho1Tkc4dJcPfWqHaFQj5KeUhzw+wH2udGO9/e3vIbXVlefdk+KxY3mNQBR5PNrr3zh/Nzf5AkwnRhiYK9areTWfL1h2x9g",
		"Jd959wYzH9A6Y3BwcHh4WEppWWJmZnZPggYi0ReOAfAhWz8j6o3v8MNCAHg8NWtZ1nOJMjAwMBy9dxGNOJwYnJqZV0od6ujKXpsaGx+bnLzX8TVKSinV1avj",
		"zKwtj5tPTWQm2kibmbFuTvqMaOPHvkj0wV9+FOiJg7CUnm1pRLQAwE/fuQHQ3CU+iEJcKcnc1Zxh098uFolkG6Pnu3aJefcBGNzuPKUUAOR2mOfpPwHbtodT",
		"jUnLhWX912JKaQPD0c+VnbXZm+d5Hz54/OK50y1nOe7j1tO1PRPu2QYWnarRJol0GJbZwUzZQ1EBNhANh4OOKG8AMFy7cklJqfdGm9LVPYlQVKvV5aWlcCSm",
		"dW/P1u3RcytPtyKn3Jbi2u5g/N3yDXHj97jVjWFo/V/Pk3Mzc+mGP1SLWSsDwGap9PDJjB5C9/kcQlNQGxiOfu4gpGq1evrUcCQaDQT8lhAAoEPA95R2sLBE",
		"LBbNZnNtbkR94T6lpOYLKSWz2q3eI0JmZTuOjnA9Jr8Dzi3nNzeFoOuvvgpIAO3Lep7neTV3ZW3tIJ1oAPCkKlcqggSz1/27kCgciROCYmb2gO2+cFQQKWbZ",
		"0Mkx150AqVH+9/WFi8UCIlqWGBgYQERmsCwixLGrY4IIcKvjz8xEFIvH34hG9dwQIuay2em5BSGMPNTAcPTzRSox8ODxNAD09va6taqreK+b6O1VWxtB66ZB",
		"b2/Ic716nAnub57J3CErBIBxr/7JUUnBBhNJXym/XqtKpXZ+CAO888671c3SozuZyC7+pd0jl12bvHe/+2TxdDqlCdS3PZG2JxQAYBJidmbW7xsAgFwuZ9u2",
		"fj0ipFJJAOztDUkpWbFt25qO9S2Krx61vu1bZeaA31fPi2Qmy8pls0rxwbQ8BgaGo+Egpj4KAHfGdsB+Hp6dbuK73Y7O6MNON9HchehgSvlLZKFSF6l0KF/F",
		"8uICAATtQMARvFVa1gtYVakqzxV+/+jVa8Vivi8cc2wChtW11XC4jxmIUNuPhMN9AFAoFFs3/vjJ1OkXTjUckWKMdPnlS9FojFmxUoDADMVicY/sq+ahj42N",
		"NZTayMyZzAQiA8Dy8koLe9eD23XeARF5tZqw7etXr3F9BLzub4J7BC8ATExMoNqnZ2VgYDj6YxFcHXcoAAlo2Q7I0iFu1hlIgFea/PAhCas+9AFAQlibpUrV",
		"cwO+YjEPAI5Ffr9fKTk8PAz1PEXo7e3T65xE1MrR8Xj/zGw9ciWZTAohALg3NKKUbG2/78HRmpJ3im2wcc8SsSnvqtau/dXxsZbmNAvbUUqylC03OLve6uDW",
		"bqGhZwMDjROzJjM2dgUOO5D7GS4Yp6lyGdb50b1D3JlwOMqSFfmEZQtBQgghhCUEKrnpOKonKLB+w+96LrNSij3P8zzpeVJK6bqup3+S27rMa2urm5ubzY62",
		"lNLzpOu6Uiop5aVLl/Sbnl09w7xF0LusIki3tp2gDQwMjF/HQaV7iAiKAVnphkOHfvRGASB9WB9ZaIg02nrtiUTCssB1PbRoYHCIAQShUnx1fHznBSVzJ4OI",
		"4XAEAPx+v2S2SESig/ncMjRGNNvaQQdhTr1QqFtPfeFYsZDtrBUx7GxgYDj6EIXVmcxd3WogBEZRN5rA9vTC57OStbi4GI5EAQCk1Oo0n2ML29pjDbPerMco",
		"s6rF8pucvzX17vVT/+jQqVKvAOqPKxayWnwtBN3JTOjPGh8fN39SBgaGo+EQc2+JGFECCGb2ghFVXAj5seb5lKwKy45FI9lcfufyYjgcLRRyBwmC6gtHd0ui",
		"agsPxHDY7ziK94m81e/68d98lyyKRuJHl2jTxttEQgsH2fh6GBgYjj5ctMqlE8nE0oP3pmamTo2cGhkdAQAki3Grdg4E/G2dioPIlrsfSBEkGHadQGkjxp8b",
		"+/UjXZ5tI+JmOm04HOnpCSqlzEi3gQF8etYMjxQLi9tyVRYXFgHAtvxaNo1oAdJz9hg6/Bgb1ubMW/8duNjlXQaFLKOaMzAwdTQcscwDUsmhJr1pgjusMJSP",
		"4VIsCADv3Zvc7r1H3RxIJpN5qs+S0gXwmT8qAwPD0YeGVDKhq+lkYqj54Mzs/MhwChAFkVKqtTW8d7JiJDbA0n06NkfI53Jda962RiK5u4/Y3CwjPoP78145",
		"v7s9JSynXmIz76qbMTAwMBzdJYZHRhCRlUomk0tPbg2MjAnbAeBUKsXM1comolUpb0uzfvH8uXAkzsoTwt7pDRQK2IiOjiHsMvcEkbrhaEQkosnJybYp6obO",
		"Ytc35vPP4sG0sLDwDO9Sskbku3t3shMXMwAyq53s3XoJYWaTJmBgYDgaAOCjBw+TqZRlWfWQbF9yqTnc3IJoNNb6v+FILBT0Efk7MomSkreGbvavGScm6nPV",
		"+8LzZLVaUy2Jf8xsWRYiArJSPDQ01LFvo8386ukBcNQaRqtac7UH6c4dYWDbtixB3DITjgCKlRCi6dCERHCyVwAMDAxHHwbOnzt78+Zt3XquNzd2LCcmE0N+",
		"nxOLxajpGY2olGIFVzpNPz6tnqHFKRr2SwYo7JzcHhwctCyhB8iFoN2WDHd76tBRLKwVC7Cf3DBWLGT7wrHGW7KxWDy7I6fREsIU1AaGo+FjzGHRLjzdDGVP",
		"TEwIYe1SWjEAs1La7oe65zwAaKwN9vX1jQx3eFZ3qIUlAsLfppI4ijGN/oEBv89RSnX8GjoellLMzPWd2YXR7hw4aeyweTzb/BfqK40SAD56NGVblt5RW98f",
		"GBgYjv5Y2Fk3YS1LhILB5uPv3rixG88QCRKiY4mKJIh48t79ZtoIAO9NoDvPfW0tNDKanJle6Cj8kFI13YXw6KacGwq5jt2PDt9M28jhCSc1n883mk7ML66Y",
		"QRgDg4+No+cXV7Rxe7FQZOb/9z/9uK2I3iX/mxEx12lhrbS50WxuMrPjOEIQMHcmLGZEkLKzGVBHgt7hygZHZwGolETE8fEreNgRJMe8JtVj5azU3OKKvhaZ",
		"iCwDg4+HoxUrn+NMzczXHk21EwczIp49PfpUG2wL+Y5EIqFQ8E4moy2P2z2rmRGpWq3CcR1JP7JIAdM3MDAwHL0ndGV0/cpFxcq27VMjqSM5JCFICAC8f//+",
		"zikVZiAicczGlJlVOp1G1LGw6lPehzUVtIHBx1lH37r7/vUrF5lZBz+3520jppODB9n+6tpaVDFofXKjaYuEjUKSEdHzZJurESJte0vLLhEJ5iMvQ7Vi7+jI",
		"+Zi3dyPRWD6XNSekgcHx1t7h4bBU7inP9n1djULB1NFR3POx8TzmpbkmaCIyYjsDg4+fo3e7mdX19ZOZ+QMujiHuV0Vy2wTgrgwmlfL5nHQ6fdIHKvQi5EeP",
		"phzHOW41NQIopSzbMlZ5BgbHfYYFARzbPiY7k0oMzM4vpRODJ/FXm8lkWqerNS87tn1qOKnFbccKqcTAzt6XgYGBZRaLdqvoAWBuYVmdzFvvTCYDDPUxceCt",
		"6Wrm+cUVPk7ituZXbRYMDQzMLDg884IbA9+5k2lrjhxKK1mbf+prwaFtlgGJiusbxUIetpmUCtPuNTAwHA2fDPmXLvEAQFgWMWFDGQKAnuc9ledPKxF3/k1Y",
		"FiJKKXdxI3pq+31LiGIh//5Hj2zb0m4ePscnhADmY1WrmsLZwMBw9LODCDv2SYcSQ4S7TzPuAnu3VjvizPQ0AESi0VDwcIKmdEMjFAqOpBL6kbmFZaOaMDAw",
		"HP2JAgIybJOaIIDruUNDQ0iQmZh4KmVFa2piG6bnFjc3N994/TUAyGQm2rQpz9wDUXJrutrUrQYGhqM/aR2P61cuImCr1CSVGJiaXWAAwKZXabeiwCcz89Lz",
		"iGjn286cGn74eJqQSQgbt41uI4LnSWa+cycz1skNtfuwQQMDA8PRn9i55KYCQQi6nZlEgFRiAJ7GTMq27Rd2mYCfX1whIfK5nFSw3jJT0xeOFgu5ZDJhWRYz",
		"BwIB6C5BHFu6JaZ2NjAwHP0pa4AopYBn5hef6l2IuJsKmIF9jvN4as6T26ymEGe0A1Q0FmPmn/zkb7t0f9UbQTJWSgYGhqM/lTU1HqqFBwIqVqdPpTs++3hq",
		"9sHjacSuexgIwOD4HEEmysTAwHC08WaDQxjlQOhcZTPw6VPDz7BNM7lnYHDS8f8DAxejnxFFfgcAAAAASUVORK5CYII=",
	})

	local MINIMAP_FILE = "Arsenic/minimap_v16.png"
	-- World AABB matching the generated top-down bake (top of image = north / +Z).
	local WORLD = {
		minX = -1858.72632,
		maxX = 427.092346,
		minZ = -4523.78271,
		maxZ = 4030.35742,
	}
	-- Baked image pixel size (Arsenic/minimap_v16.png).
	local MAP_PX = Vector2.new(481, 1800)
	-- Visible world window (studs). Smaller = more zoomed in.
	local VIEW_STUDS = Vector2.new(1050, 650)
	local FRAME_SIZE = Vector2.new(320, 200)
	local HUD_HEIGHT = 22
	local HUD_GAP = 6
	local LOCATION_RADIUS = 140

	local gui, mapImage, blip, viewport, conn
	local hudTime, hudFps, hudPing, hudPlace
	local otherBlips = {}
	local assetId = nil
	-- Day-cycle sampling (ClockTime often frozen when the cycle is disabled).
	local clockTrack = {
		last = Lighting.ClockTime,
		changedAt = os.clock(),
		rate = 0, -- ClockTime hours per real second
		moving = false,
	}

	local function b64decode(data)
		local decode = (crypt and (crypt.base64decode or crypt.base64_decode))
			or base64_decode
			or (base64 and base64.decode)
		if decode then
			local ok, result = pcall(decode, data)
			if ok and type(result) == "string" then
				return result
			end
		end
		local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
		local lookup = {}
		for i = 1, #alphabet do
			lookup[string.byte(alphabet, i)] = i - 1
		end
		data = string.gsub(data, "[^%w%+/=]", "")
		local out = table.create(math.floor(#data * 0.75))
		local n = 0
		for i = 1, #data, 4 do
			local a = lookup[string.byte(data, i)] or 0
			local b = lookup[string.byte(data, i + 1)] or 0
			local c = lookup[string.byte(data, i + 2)] or 0
			local d = lookup[string.byte(data, i + 3)] or 0
			local v = a * 262144 + b * 4096 + c * 64 + d
			n += 1
			out[n] = string.char(math.floor(v / 65536) % 256)
			if string.sub(data, i + 2, i + 2) ~= "=" then
				n += 1
				out[n] = string.char(math.floor(v / 256) % 256)
			end
			if string.sub(data, i + 3, i + 3) ~= "=" then
				n += 1
				out[n] = string.char(v % 256)
			end
		end
		return table.concat(out)
	end

	local function ensureAsset()
		if assetId then
			return assetId
		end
		if typeof(getcustomasset) ~= "function" or typeof(writefile) ~= "function" then
			return nil
		end
		-- Always rewrite versioned file so stale/corrupt custom assets are not reused.
		pcall(function()
			if makefolder and not (isfolder and isfolder("Arsenic")) then
				makefolder("Arsenic")
			end
			writefile(MINIMAP_FILE, b64decode(MINIMAP_B64))
		end)
		local ok, id = pcall(getcustomasset, MINIMAP_FILE)
		if ok and type(id) == "string" and id ~= "" then
			assetId = id
			return assetId
		end
		return nil
	end

	local function worldToUV(position)
		local spanX = WORLD.maxX - WORLD.minX
		local spanZ = WORLD.maxZ - WORLD.minZ
		-- v16 bake: west / minX on the left (not X-mirrored).
		local u = math.clamp((position.X - WORLD.minX) / spanX, 0, 1)
		local v = math.clamp((WORLD.maxZ - position.Z) / spanZ, 0, 1)
		return u, v
	end

	local function clearOtherBlips()
		for player, marker in pairs(otherBlips) do
			if marker then
				marker:Destroy()
			end
			otherBlips[player] = nil
		end
	end

	local function destroyGui()
		if conn then
			conn:Disconnect()
			conn = nil
		end
		clearOtherBlips()
		if gui then
			gui:Destroy()
			gui = nil
			mapImage = nil
			blip = nil
			viewport = nil
			hudTime = nil
			hudFps = nil
			hudPing = nil
			hudPlace = nil
		end
	end

	local function getOtherBlip(player)
		local marker = otherBlips[player]
		if marker and marker.Parent then
			return marker
		end
		marker = Instance.new("Frame")
		marker.Name = "P_" .. tostring(player.UserId)
		marker.AnchorPoint = Vector2.new(0.5, 0.5)
		marker.Size = UDim2.fromOffset(6, 6)
		marker.BackgroundColor3 = Color3.fromRGB(255, 220, 90)
		marker.BorderSizePixel = 0
		marker.ZIndex = 2
		marker.Visible = false
		marker.Parent = viewport
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(1, 0)
		corner.Parent = marker
		local stroke = Instance.new("UIStroke")
		stroke.Color = Color3.fromRGB(20, 20, 20)
		stroke.Thickness = 1
		stroke.Parent = marker
		otherBlips[player] = marker
		return marker
	end

	local function makeHudLabel(parent, anchor, position, align)
		local label = Instance.new("TextLabel")
		label.BackgroundTransparency = 1
		label.AnchorPoint = anchor
		label.Position = position
		label.Size = UDim2.new(0.34, 0, 1, 0)
		label.Font = Enum.Font.GothamMedium
		label.TextSize = 11
		label.TextColor3 = Color3.fromRGB(235, 230, 232)
		label.TextStrokeTransparency = 0.55
		label.TextXAlignment = align
		label.TextYAlignment = Enum.TextYAlignment.Center
		label.Text = ""
		label.Parent = parent
		return label
	end

	local function formatGameClock(clockTime)
		local h24 = math.floor(clockTime) % 24
		local mins = math.floor((clockTime % 1) * 60 + 1e-6)
		local suffix = h24 >= 12 and "PM" or "AM"
		local h12 = h24 % 12
		if h12 == 0 then
			h12 = 12
		end
		return string.format("%d:%02d %s", h12, mins, suffix)
	end

	local function formatCountdown(hours)
		local totalSec = math.max(0, math.floor(hours * 3600 + 0.5))
		local h = math.floor(totalSec / 3600)
		local m = math.floor((totalSec % 3600) / 60)
		local s = totalSec % 60
		if h > 0 then
			return string.format("%dh %dm", h, m)
		end
		if m > 0 then
			return string.format("%dm %ds", m, s)
		end
		return string.format("%ds", s)
	end

	local function updateClockTrack(dt)
		local ct = Lighting.ClockTime
		local prev = clockTrack.last
		local delta = ct - prev
		-- Wrap across midnight (23 → 0).
		if delta < -12 then
			delta += 24
		elseif delta > 12 then
			delta -= 24
		end
		if math.abs(delta) > 1e-4 then
			clockTrack.changedAt = os.clock()
			if dt > 1e-4 then
				local instant = math.abs(delta) / dt
				clockTrack.rate = clockTrack.rate > 0 and (clockTrack.rate * 0.85 + instant * 0.15) or instant
			end
			clockTrack.moving = true
		elseif os.clock() - clockTrack.changedAt > 12 then
			clockTrack.moving = false
			clockTrack.rate = 0
		end
		clockTrack.last = ct
		return ct
	end

	local function dayNightText(ct)
		-- Cycle looks active when ClockTime has moved recently.
		if clockTrack.moving and clockTrack.rate > 1e-5 then
			local isNight = ct >= 18 or ct < 6
			local target = isNight and 6 or 18
			local hoursLeft = target - ct
			if hoursLeft <= 0 then
				hoursLeft += 24
			end
			local label = isNight and "Day" or "Night"
			-- rate = game-hours / real-second → convert remaining game hours to real time.
			local realSeconds = hoursLeft / math.max(clockTrack.rate, 1e-6)
			return string.format("%s in %s", label, formatCountdown(realSeconds / 3600))
		end
		return formatGameClock(ct)
	end

	-- Fallback when Workspace.locationmarkers is missing (teleport list radius).
	local function nearestTeleportName(position)
		local list = Arsenic.Locations or Vehicles.selfDriveLocations
		if type(list) ~= "table" then
			return "Unknown"
		end
		local bestName, bestDist = nil, LOCATION_RADIUS
		local flat = Vector3.new(position.X, 0, position.Z)
		for _, entry in ipairs(list) do
			local name, cf = entry[1], entry[2]
			if type(name) == "string" and typeof(cf) == "CFrame" then
				local pos = cf.Position
				-- Skip void / placeholder teleports (e.g. Top Gun Store skybox coords).
				if math.abs(pos.X) < 8000 and math.abs(pos.Z) < 8000 and math.abs(pos.Y) < 2000 then
					local dist = (flat - Vector3.new(pos.X, 0, pos.Z)).Magnitude
					if dist < bestDist then
						bestDist = dist
						bestName = name
					end
				end
			end
		end
		return bestName or "Unknown"
	end

	-- Studio layout (either works):
	--   Workspace/locationmarkers/[District]/[Location Part]   ← nested
	--   Workspace/locationmarkers/[District Part], [Location Part]  ← flat siblings
	-- Optional: Attribute District="New City" on a location part.
	-- In a small location → "District | Location"; only in district box → "District".
	local markerCache = {
		folder = nil,
		parts = {},
		builtAt = 0,
		conns = {},
		missUntil = 0, -- skip Workspace scans until this time when folder is absent
		rebuildQueued = false,
	}
	local MARKER_FOLDER_NAMES = {
		locationmarkers = true,
		LocationMarkers = true,
		Locationmarkers = true,
		["location markers"] = true,
	}
	local MARKER_MISS_TTL = 45

	local function clearMarkerConns()
		for _, c in ipairs(markerCache.conns) do
			pcall(function()
				c:Disconnect()
			end)
		end
		markerCache.conns = {}
	end

	local function findLocationMarkersFolder(allowDeep)
		for name in pairs(MARKER_FOLDER_NAMES) do
			local folder = Workspace:FindFirstChild(name)
			if folder then
				return folder
			end
		end
		-- Deep scan is expensive on TB3's map — only when explicitly allowed and not on miss cooldown.
		if not allowDeep or os.clock() < markerCache.missUntil then
			return nil
		end
		for _, inst in ipairs(Workspace:GetDescendants()) do
			if MARKER_FOLDER_NAMES[inst.Name] and (inst:IsA("Folder") or inst:IsA("Model") or inst:IsA("Configuration")) then
				return inst
			end
		end
		markerCache.missUntil = os.clock() + MARKER_MISS_TTL
		return nil
	end

	local function partVolume(part)
		local s = part.Size
		return math.max(s.X, 0.01) * math.max(s.Y, 0.01) * math.max(s.Z, 0.01)
	end

	-- XZ only (ignore Y) so Studio boxes don't need perfect vertical placement.
	local function pointInMarker(worldPos, part)
		if not (part and part.Parent) then
			return false
		end
		local localPos = part.CFrame:PointToObjectSpace(worldPos)
		local half = part.Size * 0.5
		return math.abs(localPos.X) <= half.X + 0.05 and math.abs(localPos.Z) <= half.Z + 0.05
	end

	local function splitPipeName(name)
		local left, right = string.match(name, "^(.-)%s*|%s*(.-)$")
		if left and right and left ~= "" and right ~= "" then
			return left, right
		end
		return nil, nil
	end

	-- Direct child of locationmarkers that owns this instance (district node).
	local function districtNodeFor(inst, folder)
		local cur = inst
		while cur and cur ~= folder do
			if cur.Parent == folder then
				return cur
			end
			cur = cur.Parent
		end
		return nil
	end

	local function scheduleMarkerRebuild()
		if markerCache.rebuildQueued then
			return
		end
		markerCache.rebuildQueued = true
		task.delay(0.75, function()
			markerCache.rebuildQueued = false
			if Arsenic.Destroyed then
				return
			end
			markerCache.builtAt = 0
		end)
	end

	local function rebuildMarkerCache()
		clearMarkerConns()
		-- Prefer cheap FindFirstChild; deep-scan only if we have never found a folder this session.
		local allowDeep = markerCache.folder == nil and markerCache.builtAt == 0
		markerCache.folder = findLocationMarkersFolder(allowDeep)
		markerCache.parts = {}
		markerCache.builtAt = os.clock()
		local folder = markerCache.folder
		if not folder then
			markerCache.missUntil = math.max(markerCache.missUntil, os.clock() + MARKER_MISS_TTL)
			return
		end
		markerCache.missUntil = 0
		-- Only watch direct children — DescendantAdded on a live map folder hitch-rebuilds constantly.
		table.insert(markerCache.conns, folder.ChildAdded:Connect(scheduleMarkerRebuild))
		table.insert(markerCache.conns, folder.ChildRemoved:Connect(scheduleMarkerRebuild))

		local function addPart(part)
			if not part:IsA("BasePart") then
				return
			end
			local node = districtNodeFor(part, folder)
			local attrDistrict = nil
			pcall(function()
				attrDistrict = part:GetAttribute("District") or (node and node:GetAttribute("District"))
			end)
			if type(attrDistrict) ~= "string" or attrDistrict == "" then
				attrDistrict = nil
			end
			local districtName = attrDistrict
			if not districtName and node then
				-- If the district node itself is named "District | Location", keep the left side.
				local left = select(1, splitPipeName(node.Name))
				districtName = left or node.Name
			end
			local locLeft, locRight = splitPipeName(part.Name)
			local locationName = part.Name
			-- Part baked as "New City | Car Repair" → district/location from the name.
			if locLeft and locRight then
				districtName = districtName or locLeft
				locationName = locRight
			elseif node and part ~= node and not part:IsA("Model") then
				locationName = part.Name
			end
			table.insert(markerCache.parts, {
				part = part,
				volume = partVolume(part),
				district = districtName or part.Name,
				location = locationName,
				node = node,
			})
		end

		if folder:IsA("BasePart") then
			addPart(folder)
		end
		for _, inst in ipairs(folder:GetDescendants()) do
			addPart(inst)
		end

		-- Per-district largest volume (district hitbox vs smaller location parts).
		local largestByDistrict = {}
		for _, entry in ipairs(markerCache.parts) do
			local key = entry.district
			if not largestByDistrict[key] or entry.volume > largestByDistrict[key] then
				largestByDistrict[key] = entry.volume
			end
		end
		for _, entry in ipairs(markerCache.parts) do
			entry.districtMaxVol = largestByDistrict[entry.district] or entry.volume
			-- A part counts as a specific location when it's clearly smaller than the district box,
			-- or when its name was already "District | Location", or District attribute was set on a child.
			local namedLoc = select(1, splitPipeName(entry.part.Name)) ~= nil
			local isChildLoc = entry.node and entry.part ~= entry.node and entry.volume < entry.districtMaxVol * 0.85
			entry.isLocation = namedLoc or isChildLoc or (entry.location ~= entry.district and entry.volume < entry.districtMaxVol * 0.85)
		end
	end

	local function ensureMarkerCache()
		local now = os.clock()
		if markerCache.folder and not markerCache.folder.Parent then
			markerCache.folder = nil
			markerCache.parts = {}
			markerCache.builtAt = 0
			markerCache.missUntil = now + 5
		end
		if markerCache.builtAt == 0 then
			rebuildMarkerCache()
			return
		end
		-- Periodic refresh only if we already have a folder (no Workspace deep scan).
		if markerCache.folder and (now - markerCache.builtAt) > 12 then
			rebuildMarkerCache()
		end
	end

	local function locationFromMarkers(position)
		ensureMarkerCache()
		if not markerCache.folder or #markerCache.parts == 0 then
			return nil
		end

		local containing = {}
		for _, entry in ipairs(markerCache.parts) do
			if pointInMarker(position, entry.part) then
				table.insert(containing, entry)
			end
		end
		if #containing == 0 then
			return nil
		end

		table.sort(containing, function(a, b)
			if a.volume == b.volume then
				return a.part.Name < b.part.Name
			end
			return a.volume < b.volume
		end)

		-- Tightest box wins (specific location over huge district).
		local smallest = containing[1]
		local largest = containing[#containing]

		-- Prefer a true location part if the smallest is only a tiny non-location quirk.
		local locEntry = nil
		for _, entry in ipairs(containing) do
			if entry.isLocation then
				locEntry = entry
				break
			end
		end

		if locEntry then
			local district = locEntry.district
			local location = locEntry.location
			-- Flat siblings under locationmarkers: small part is its own node, so borrow
			-- the district name from a larger box that also contains the player.
			if locEntry.node == locEntry.part or district == location then
				for i = #containing, 1, -1 do
					local other = containing[i]
					if other.volume > locEntry.volume * 1.15 and other.district ~= location then
						district = other.district
						break
					end
				end
			end
			if location == district then
				return district
			end
			return district .. " | " .. location
		end

		-- Only inside district volume(s).
		local district = largest and largest.district or smallest.district
		return district
	end

	local function nearestLocationName(position)
		local fromMarkers = locationFromMarkers(position)
		if fromMarkers and fromMarkers ~= "" then
			return fromMarkers
		end
		return nearestTeleportName(position)
	end

	Arsenic.GetLocationLabel = nearestLocationName
	Arsenic.DebugLocationMarkers = function()
		rebuildMarkerCache()
		local folder = markerCache.folder
		return {
			folder = folder and folder:GetFullName() or nil,
			count = #markerCache.parts,
			parts = markerCache.parts,
		}
	end

	local function buildGui(image)
		destroyGui()
		local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
		if not playerGui then
			return false
		end
		gui = Instance.new("ScreenGui")
		gui.Name = "ArsenicMinimap"
		gui.ResetOnSpawn = false
		gui.IgnoreGuiInset = true
		gui.DisplayOrder = 60
		gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
		gui.Parent = playerGui

		local stack = Instance.new("Frame")
		stack.Name = "Stack"
		stack.AnchorPoint = Vector2.new(1, 1)
		stack.Position = UDim2.new(1, -14, 1, -14)
		stack.Size = UDim2.fromOffset(FRAME_SIZE.X, FRAME_SIZE.Y + HUD_HEIGHT + HUD_GAP)
		stack.BackgroundTransparency = 1
		stack.BorderSizePixel = 0
		stack.Parent = gui

		local hud = Instance.new("Frame")
		hud.Name = "Hud"
		hud.Size = UDim2.new(1, 0, 0, HUD_HEIGHT)
		hud.Position = UDim2.fromOffset(0, 0)
		hud.BackgroundColor3 = Color3.fromRGB(22, 18, 20)
		hud.BackgroundTransparency = 0.15
		hud.BorderSizePixel = 0
		hud.Parent = stack
		local hudCorner = Instance.new("UICorner")
		hudCorner.CornerRadius = UDim.new(0, 8)
		hudCorner.Parent = hud
		local hudStroke = Instance.new("UIStroke")
		hudStroke.Color = Color3.fromRGB(255, 150, 180)
		hudStroke.Thickness = 1
		hudStroke.Transparency = 0.45
		hudStroke.Parent = hud
		local hudPad = Instance.new("UIPadding")
		hudPad.PaddingLeft = UDim.new(0, 8)
		hudPad.PaddingRight = UDim.new(0, 8)
		hudPad.Parent = hud

		hudTime = makeHudLabel(hud, Vector2.new(0, 0.5), UDim2.new(0, 0, 0.5, 0), Enum.TextXAlignment.Left)
		hudTime.Size = UDim2.new(0.30, 0, 1, 0)
		hudFps = makeHudLabel(hud, Vector2.new(0.5, 0.5), UDim2.new(0.40, 0, 0.5, 0), Enum.TextXAlignment.Center)
		hudFps.Size = UDim2.new(0.12, 0, 1, 0)
		hudPing = makeHudLabel(hud, Vector2.new(0.5, 0.5), UDim2.new(0.52, 0, 0.5, 0), Enum.TextXAlignment.Center)
		hudPing.Size = UDim2.new(0.12, 0, 1, 0)
		hudPlace = makeHudLabel(hud, Vector2.new(1, 0.5), UDim2.new(1, 0, 0.5, 0), Enum.TextXAlignment.Right)
		hudPlace.Size = UDim2.new(0.46, 0, 1, 0)
		hudPlace.TextTruncate = Enum.TextTruncate.AtEnd
		hudPlace.TextSize = 10

		local frame = Instance.new("Frame")
		frame.Name = "Map"
		frame.Position = UDim2.fromOffset(0, HUD_HEIGHT + HUD_GAP)
		frame.Size = UDim2.fromOffset(FRAME_SIZE.X, FRAME_SIZE.Y)
		frame.BackgroundColor3 = Color3.fromRGB(28, 24, 26)
		frame.BorderSizePixel = 0
		frame.ClipsDescendants = true
		frame.Active = true
		frame.Parent = stack
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 10)
		corner.Parent = frame
		frame.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
				if Arsenic.WorldMap and Arsenic.WorldMap.open then
					Arsenic.WorldMap.open()
				end
			end
		end)
		local stroke = Instance.new("UIStroke")
		stroke.Color = Color3.fromRGB(255, 150, 180)
		stroke.Thickness = 1.2
		stroke.Transparency = 0.35
		stroke.Parent = frame
		local pad = Instance.new("UIPadding")
		pad.PaddingTop = UDim.new(0, 5)
		pad.PaddingBottom = UDim.new(0, 5)
		pad.PaddingLeft = UDim.new(0, 5)
		pad.PaddingRight = UDim.new(0, 5)
		pad.Parent = frame

		-- Inner clip so map can pan without using ImageRect (broken on tall custom assets).
		viewport = Instance.new("Frame")
		viewport.Name = "Viewport"
		viewport.BackgroundTransparency = 1
		viewport.Size = UDim2.fromScale(1, 1)
		viewport.ClipsDescendants = true
		viewport.Parent = frame
		local viewCorner = Instance.new("UICorner")
		viewCorner.CornerRadius = UDim.new(0, 7)
		viewCorner.Parent = viewport

		mapImage = Instance.new("ImageLabel")
		mapImage.Name = "Terrain"
		mapImage.BackgroundTransparency = 1
		mapImage.BorderSizePixel = 0
		mapImage.AnchorPoint = Vector2.new(0, 0)
		mapImage.Position = UDim2.fromOffset(0, 0)
		mapImage.Size = UDim2.fromScale(1, 1)
		mapImage.ScaleType = Enum.ScaleType.Stretch
		mapImage.Image = image
		mapImage.ImageRectOffset = Vector2.zero
		mapImage.ImageRectSize = Vector2.zero
		mapImage.Parent = viewport

		blip = Instance.new("Frame")
		blip.Name = "You"
		blip.AnchorPoint = Vector2.new(0.5, 0.5)
		blip.Position = UDim2.fromScale(0.5, 0.5)
		blip.Size = UDim2.fromOffset(9, 9)
		blip.BackgroundColor3 = Color3.fromRGB(255, 80, 120)
		blip.BorderSizePixel = 0
		blip.ZIndex = 3
		blip.Parent = viewport
		local blipCorner = Instance.new("UICorner")
		blipCorner.CornerRadius = UDim.new(1, 0)
		blipCorner.Parent = blip
		local blipStroke = Instance.new("UIStroke")
		blipStroke.Color = Color3.fromRGB(255, 255, 255)
		blipStroke.Thickness = 1.2
		blipStroke.Parent = blip

		local heading = Instance.new("Frame")
		heading.Name = "Heading"
		heading.AnchorPoint = Vector2.new(0.5, 1)
		heading.Position = UDim2.fromScale(0.5, 0.12)
		heading.Size = UDim2.fromOffset(2, 8)
		heading.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
		heading.BorderSizePixel = 0
		heading.ZIndex = 4
		heading.Parent = blip

		local fpsSmooth = 60
		local pingSmooth = 0
		local hudTick = 0

		conn = RunService.RenderStepped:Connect(function(dt)
			if Arsenic.Destroyed or not (gui and gui.Parent and mapImage and blip and viewport and viewport.Parent) then
				return
			end
			dt = math.clamp(dt, 1 / 240, 0.1)
			local ct = updateClockTrack(dt)
			fpsSmooth = fpsSmooth * 0.9 + (1 / dt) * 0.1
			hudTick += dt
			local root = getRoot()
			if hudTick >= 0.5 then
				hudTick = 0
				local pingMs = 0
				pcall(function()
					pingMs = LocalPlayer:GetNetworkPing() * 1000
				end)
				pingSmooth = pingSmooth > 0 and (pingSmooth * 0.7 + pingMs * 0.3) or pingMs
				if hudTime then
					hudTime.Text = dayNightText(ct)
				end
				if hudFps then
					hudFps.Text = string.format("%d FPS", math.floor(fpsSmooth + 0.5))
				end
				if hudPing then
					hudPing.Text = string.format("%d ms", math.floor(pingSmooth + 0.5))
				end
				if hudPlace then
					hudPlace.Text = root and nearestLocationName(root.Position) or "Unknown"
				end
			end

			if not root then
				blip.Visible = false
				return
			end
			blip.Visible = true
			local spanX = WORLD.maxX - WORLD.minX
			local spanZ = WORLD.maxZ - WORLD.minZ
			local u, v = worldToUV(root.Position)
			local viewW = math.max(1, viewport.AbsoluteSize.X)
			local viewH = math.max(1, viewport.AbsoluteSize.Y)
			-- Cover the viewport with correct world aspect; pan so the player stays centered.
			local pxPerStud = math.max(viewW / VIEW_STUDS.X, viewH / VIEW_STUDS.Y)
			local dispW = spanX * pxPerStud
			local dispH = spanZ * pxPerStud
			mapImage.Size = UDim2.fromOffset(math.floor(dispW + 0.5), math.floor(dispH + 0.5))
			mapImage.Position = UDim2.fromOffset(
				math.floor(viewW * 0.5 - u * dispW + 0.5),
				math.floor(viewH * 0.5 - v * dispH + 0.5)
			)
			blip.Position = UDim2.fromScale(0.5, 0.5)
			-- Rotation 0 = heading toward top of map (+Z / north). Previous -X/-Z inverted facing.
			local look = Vector3.new(root.CFrame.LookVector.X, 0, root.CFrame.LookVector.Z)
			if look.Magnitude > 0.1 then
				look = look.Unit
				blip.Rotation = math.deg(math.atan2(look.X, look.Z))
			end

			local seen = {}
			for _, player in ipairs(Players:GetPlayers()) do
				if player ~= LocalPlayer then
					local otherRoot = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
					if otherRoot and otherRoot:IsA("BasePart") then
						seen[player] = true
						local ou, ov = worldToUV(otherRoot.Position)
						local dx = (ou - u) * dispW
						local dy = (ov - v) * dispH
						local marker = getOtherBlip(player)
						local onView = math.abs(dx) <= viewW * 0.55 and math.abs(dy) <= viewH * 0.55
						marker.Visible = onView
						if onView then
							marker.Position = UDim2.fromOffset(
								math.floor(viewW * 0.5 + dx + 0.5),
								math.floor(viewH * 0.5 + dy + 0.5)
							)
						end
					end
				end
			end
			for player, marker in pairs(otherBlips) do
				if not seen[player] then
					marker:Destroy()
					otherBlips[player] = nil
				end
			end
		end)
		return true
	end

	local function destroyMinimap()
		destroyGui()
		clearMarkerConns()
		markerCache.builtAt = 0
		markerCache.parts = {}
		markerCache.folder = nil
	end

	Features.Minimap = {
		_ensureAsset = ensureAsset,
		enable = function()
			local image = ensureAsset()
			if not image then
				notify("Minimap needs getcustomasset/writefile support.")
				Arsenic.Enabled.Minimap = false
				return
			end
			if not buildGui(image) then
				notify("Minimap could not open PlayerGui.")
				Arsenic.Enabled.Minimap = false
				return
			end
			notify("Minimap enabled.")
		end,
		disable = function()
			destroyMinimap()
		end,
	}

	table.insert(Arsenic.Cleanup, destroyMinimap)
end)()

--------------------------------------------------------------------------------

--------------------------------------------------------------------------------
-- Homes
--------------------------------------------------------------------------------

;(function()
	local HOME_CATALOG = {
		{ p = 150, t = "Apartment", r = "Main City", x = -1007.8, y = 266.92, z = -930.88 },
		{ p = 550, t = "Townhome", r = "Main City", x = -458.06, y = 263.53, z = -698.75 },
		{ p = 3000, t = "Large Home", r = "Main City", x = -705.24, y = 280.0, z = -761.58 },
		{ p = 550, t = "Townhome", r = "Main City", x = -659.39, y = 258.62, z = -595.42 },
		{ p = 1000, t = "House", r = "Main City", x = -957.21, y = 259.56, z = -1266.1 },
		{ p = 550, t = "Townhome", r = "East Side", x = 247.9, y = 285.23, z = -1123.51 },
		{ p = 1000, t = "House", r = "Main City", x = -1070.2, y = 262.6, z = -1199.35 },
		{ p = 550, t = "Townhome", r = "East Side", x = 252.23, y = 285.29, z = -484.05 },
		{ p = 1000, t = "House", r = "Main City", x = -959.46, y = 257.73, z = -1116.86 },
		{ p = 1000, t = "House", r = "Main City", x = -977.13, y = 257.73, z = -1116.86 },
		{ p = 1000, t = "House", r = "Main City", x = -1003.63, y = 260.48, z = -1053.76 },
		{ p = 550, t = "Townhome", r = "East Side", x = 261.11, y = 287.97, z = -944.1 },
		{ p = 550, t = "Townhome", r = "Main City", x = -1079.14, y = 256.28, z = -1027.21 },
		{ p = 550, t = "Townhome", r = "East Side", x = 247.1, y = 285.29, z = -505.33 },
		{ p = 3000, t = "Large Home", r = "Main City", x = -925.54, y = 270.65, z = -1178.31 },
		{ p = 1000, t = "House", r = "Main City", x = -909.87, y = 257.77, z = -1270.34 },
		{ p = 1000, t = "House", r = "Main City", x = -1070.2, y = 262.6, z = -1183.73 },
		{ p = 500, t = "Townhome", r = "Main City", x = -233.02, y = 296.48, z = -917.77 },
		{ p = 150, t = "Apartment", r = "West Side", x = -1532.72, y = 278.68, z = -963.27 },
		{ p = 550, t = "Townhome", r = "East Side", x = 253.68, y = 285.23, z = -1128.64 },
		{ p = 500, t = "Townhome", r = "Main City", x = -913.39, y = 259.34, z = -723.97 },
		{ p = 550, t = "Townhome", r = "Main City", x = -973.68, y = 342.89, z = -289.44 },
		{ p = 500, t = "Townhome", r = "Main City", x = -923.76, y = 269.0, z = -689.28 },
		{ p = 550, t = "Townhome", r = "Main City", x = -959.39, y = 299.33, z = -546.12 },
		{ p = 500, t = "Townhome", r = "Main City", x = -722.71, y = 260.94, z = -1258.29 },
		{ p = 3000, t = "Large Home", r = "Main City", x = -109.83, y = 289.47, z = -512.23 },
		{ p = 3000, t = "Large Home", r = "Main City", x = -705.24, y = 291.17, z = -791.4 },
		{ p = 550, t = "Townhome", r = "Main City", x = -1000.39, y = 299.33, z = -552.9 },
		{ p = 550, t = "Townhome", r = "Main City", x = -1000.39, y = 299.33, z = -506.33 },
		{ p = 500, t = "Townhome", r = "Main City", x = -659.53, y = 264.32, z = -1025.6 },
		{ p = 550, t = "Townhome", r = "Main City", x = -959.34, y = 321.16, z = -546.11 },
		{ p = 550, t = "Townhome", r = "Main City", x = -959.36, y = 321.16, z = -499.54 },
		{ p = 550, t = "Townhome", r = "Main City", x = -1000.31, y = 321.16, z = -506.34 },
		{ p = 550, t = "Townhome", r = "Main City", x = -973.65, y = 277.52, z = -243.67 },
		{ p = 550, t = "Townhome", r = "Main City", x = -1000.31, y = 321.16, z = -552.9 },
		{ p = 500, t = "Townhome", r = "Main City", x = -698.4, y = 260.94, z = -1258.29 },
		{ p = 550, t = "Townhome", r = "Main City", x = -1000.39, y = 342.89, z = -506.33 },
		{ p = 3000, t = "Large Home", r = "Main City", x = -649.19, y = 276.21, z = -685.92 },
		{ p = 500, t = "Townhome", r = "Uptown", x = -1576.81, y = 257.5, z = 2288.47 },
		{ p = 550, t = "Townhome", r = "Main City", x = -959.43, y = 277.52, z = -545.33 },
		{ p = 550, t = "Townhome", r = "Main City", x = -744.98, y = 261.35, z = -945.95 },
		{ p = 150, t = "Apartment", r = "Main City", x = -996.51, y = 266.92, z = -930.88 },
		{ p = 550, t = "Townhome", r = "Main City", x = -1000.39, y = 342.89, z = -552.9 },
		{ p = 550, t = "Townhome", r = "East Side", x = 243.8, y = 285.29, z = -328.11 },
		{ p = 550, t = "Townhome", r = "Main City", x = -975.56, y = 265.66, z = -1255.56 },
		{ p = 550, t = "Townhome", r = "East Side", x = 222.53, y = 285.29, z = -322.98 },
		{ p = 3000, t = "Large Home", r = "Main City", x = -240.06, y = 446.56, z = -1096.9 },
		{ p = 700, t = "Townhome", r = "Main City", x = -959.34, y = 342.91, z = -546.11 },
		{ p = 500, t = "Townhome", r = "Main City", x = -690.82, y = 263.53, z = -1034.58 },
		{ p = 500, t = "Townhome", r = "Uptown", x = -1540.81, y = 256.78, z = 2212.15 },
		{ p = 550, t = "Townhome", r = "Main City", x = -1014.68, y = 255.64, z = -296.83 },
		{ p = 1000, t = "House", r = "Main City", x = -1058.52, y = 259.95, z = -1246.61 },
		{ p = 3000, t = "Large Home", r = "Main City", x = -626.57, y = 271.31, z = -749.88 },
		{ p = 1000, t = "House", r = "Main City", x = -943.98, y = 260.42, z = -1048.42 },
		{ p = 500, t = "Townhome", r = "Uptown", x = -1439.14, y = 256.78, z = 2285.17 },
		{ p = 500, t = "Townhome", r = "Uptown", x = -1427.54, y = 257.5, z = 2374.39 },
		{ p = 550, t = "Townhome", r = "East Side", x = 269.18, y = 285.23, z = -1128.64 },
		{ p = 550, t = "Townhome", r = "Main City", x = -458.06, y = 263.45, z = -726.86 },
		{ p = 500, t = "Townhome", r = "Main City", x = -233.02, y = 296.48, z = -978.26 },
		{ p = 3000, t = "Large Home", r = "Main City", x = -92.95, y = 295.83, z = -805.58 },
		{ p = 500, t = "Townhome", r = "Uptown", x = -1556.25, y = 257.5, z = 2385.1 },
		{ p = 500, t = "Townhome", r = "New City", x = -1084.74, y = 255.42, z = -3508.16 },
		{ p = 500, t = "Townhome", r = "Main City", x = -593.66, y = 261.98, z = -1027.55 },
		{ p = 3000, t = "Large Home", r = "Main City", x = -626.57, y = 271.31, z = -790.26 },
		{ p = 500, t = "Townhome", r = "Main City", x = -633.69, y = 262.37, z = -903.28 },
		{ p = 500, t = "Townhome", r = "Main City", x = -605.02, y = 262.11, z = -904.75 },
		{ p = 550, t = "Townhome", r = "Main City", x = -647.91, y = 258.62, z = -577.27 },
		{ p = 500, t = "Townhome", r = "New City", x = -1145.2, y = 262.03, z = -3955.1 },
		{ p = 10000, t = "Mansion", r = "Uptown", x = -793.56, y = 255.53, z = 1394.58 },
		{ p = 3000, t = "Large Home", r = "Main City", x = -705.24, y = 302.39, z = -791.4 },
		{ p = 3000, t = "Large Home", r = "Main City", x = -9.63, y = 287.34, z = -1150.33 },
		{ p = 3000, t = "Large Home", r = "Main City", x = -232.53, y = 295.87, z = -1189.99 },
		{ p = 3000, t = "Large Home", r = "Main City", x = -9.63, y = 287.34, z = -1030.4 },
		{ p = 1000, t = "House", r = "New City", x = -1584.17, y = 262.87, z = -4217.56 },
		{ p = 500, t = "Townhome", r = "Main City", x = -913.39, y = 259.34, z = -758.77 },
		{ p = 500, t = "Townhome", r = "Main City", x = -720.25, y = 262.18, z = -1040.64 },
		{ p = 550, t = "Townhome", r = "Main City", x = -1000.42, y = 277.52, z = -552.1 },
		{ p = 550, t = "Townhome", r = "Main City", x = -959.41, y = 299.33, z = -499.55 },
		{ p = 3000, t = "Large Home", r = "Main City", x = -705.24, y = 291.15, z = -761.58 },
		{ p = 550, t = "Townhome", r = "Main City", x = -693.88, y = 255.29, z = -286.78 },
		{ p = 3000, t = "Large Home", r = "Main City", x = -192.84, y = 287.23, z = -614.55 },
		{ p = 550, t = "Townhome", r = "Main City", x = -663.49, y = 255.29, z = -278.89 },
		{ p = 150, t = "Apartment", r = "West Side", x = -1614.06, y = 255.24, z = -509.92 },
		{ p = 550, t = "Townhome", r = "Main City", x = -1000.39, y = 255.64, z = -552.27 },
		{ p = 550, t = "Townhome", r = "Main City", x = -1000.34, y = 277.52, z = -505.52 },
		{ p = 150, t = "Apartment", r = "West Side", x = -1605.29, y = 255.24, z = -493.08 },
		{ p = 500, t = "Townhome", r = "Main City", x = -693.28, y = 262.45, z = -910.66 },
		{ p = 550, t = "Townhome", r = "Main City", x = -1000.39, y = 255.64, z = -505.69 },
		{ p = 550, t = "Townhome", r = "Main City", x = -973.68, y = 255.64, z = -290.08 },
		{ p = 550, t = "Townhome", r = "Main City", x = -973.68, y = 299.33, z = -242.88 },
		{ p = 550, t = "Townhome", r = "Main City", x = -1014.64, y = 277.52, z = -250.45 },
		{ p = 550, t = "Townhome", r = "Main City", x = -1014.71, y = 342.91, z = -296.24 },
		{ p = 3000, t = "Large Home", r = "Main City", x = -705.24, y = 302.39, z = -761.58 },
		{ p = 550, t = "Townhome", r = "Main City", x = -1014.66, y = 299.33, z = -296.23 },
		{ p = 550, t = "Townhome", r = "Main City", x = -959.44, y = 277.52, z = -498.73 },
		{ p = 550, t = "Townhome", r = "Main City", x = -959.39, y = 255.64, z = -498.94 },
		{ p = 550, t = "Townhome", r = "Main City", x = -973.68, y = 255.64, z = -243.51 },
		{ p = 6000, t = "Mansion", r = "Main City", x = -249.25, y = 285.68, z = -346.23 },
		{ p = 550, t = "Townhome", r = "Main City", x = -1014.71, y = 321.16, z = -296.24 },
		{ p = 550, t = "Townhome", r = "Main City", x = -973.73, y = 277.52, z = -290.26 },
		{ p = 550, t = "Townhome", r = "Main City", x = -1014.73, y = 342.91, z = -249.66 },
		{ p = 550, t = "Townhome", r = "Main City", x = -1014.68, y = 255.64, z = -250.26 },
		{ p = 550, t = "Townhome", r = "Main City", x = -1014.68, y = 299.33, z = -249.66 },
		{ p = 550, t = "Townhome", r = "Main City", x = -1014.63, y = 277.52, z = -297.05 },
		{ p = 500, t = "Townhome", r = "Uptown", x = -1443.14, y = 257.47, z = 2140.24 },
		{ p = 550, t = "Townhome", r = "Main City", x = -959.39, y = 255.64, z = -545.51 },
		{ p = 550, t = "Townhome", r = "Main City", x = -739.01, y = 261.35, z = -911.81 },
		{ p = 550, t = "Townhome", r = "Main City", x = -973.68, y = 299.33, z = -289.44 },
		{ p = 550, t = "Townhome", r = "Main City", x = -1014.73, y = 321.16, z = -249.66 },
		{ p = 1000, t = "House", r = "New City", x = -915.23, y = 262.71, z = -4216.84 },
		{ p = 500, t = "Townhome", r = "New City", x = -904.15, y = 255.42, z = -3508.16 },
		{ p = 150, t = "Apartment", r = "West Side", x = -1626.15, y = 255.33, z = -251.0 },
		{ p = 1000, t = "House", r = "New City", x = -1521.28, y = 262.87, z = -4216.78 },
		{ p = 550, t = "Townhome", r = "Main City", x = -705.96, y = 258.78, z = -501.8 },
		{ p = 3000, t = "Large Home", r = "Main City", x = -9.63, y = 287.34, z = -1090.39 },
		{ p = 15000, t = "Mansion", r = "New City", x = -1488.87, y = 478.14, z = -3745.99 },
		{ p = 550, t = "Townhome", r = "Main City", x = -685.82, y = 258.78, z = -501.8 },
		{ p = 500, t = "Townhome", r = "New City", x = -982.16, y = 261.09, z = -4130.36 },
		{ p = 1000, t = "House", r = "New City", x = -978.23, y = 262.8, z = -4368.81 },
		{ p = 1000, t = "House", r = "New City", x = -1536.91, y = 262.87, z = -4216.78 },
		{ p = 500, t = "Townhome", r = "Main City", x = -753.02, y = 263.53, z = -1034.58 },
		{ p = 550, t = "Townhome", r = "Main City", x = -711.76, y = 255.4, z = -593.79 },
		{ p = 1000, t = "House", r = "New City", x = -1599.8, y = 262.87, z = -4217.56 },
		{ p = 500, t = "Townhome", r = "New City", x = -1044.74, y = 261.98, z = -3955.1 },
		{ p = 3000, t = "Large Home", r = "Main City", x = -192.84, y = 287.23, z = -554.58 },
		{ p = 550, t = "Townhome", r = "New City", x = -904.48, y = 263.09, z = -3634.05 },
		{ p = 500, t = "Townhome", r = "New City", x = -955.48, y = 255.42, z = -3508.16 },
		{ p = 1000, t = "House", r = "New City", x = -1039.5, y = 262.71, z = -4216.84 },
		{ p = 500, t = "Townhome", r = "New City", x = -1025.08, y = 259.83, z = -3855.97 },
		{ p = 500, t = "Townhome", r = "New City", x = -1224.87, y = 263.97, z = -3759.78 },
		{ p = 500, t = "Townhome", r = "New City", x = -1211.29, y = 264.54, z = -3853.98 },
		{ p = 500, t = "Townhome", r = "New City", x = -918.87, y = 262.03, z = -3955.1 },
		{ p = 1000, t = "House", r = "New City", x = -878.35, y = 262.8, z = -4368.81 },
		{ p = 500, t = "Townhome", r = "New City", x = -1079.71, y = 261.22, z = -4131.05 },
		{ p = 550, t = "Townhome", r = "East Side", x = 203.69, y = 287.97, z = -936.64 },
		{ p = 500, t = "Townhome", r = "New City", x = -1033.3, y = 255.42, z = -3508.16 },
		{ p = 550, t = "Townhome", r = "New City", x = -1002.37, y = 263.09, z = -3634.05 },
	}

	local MAIN_MANSION = Vector3.new(-793.56, 255.53, 1394.58)
	local NEW_CITY_MANSION = Vector3.new(-1488.87, 478.14, -3745.99)

	local homeWatch = {
		conn = nil,
		breakLast = 0,
		motionLast = 0,
		backLast = 0,
		backCamPart = nil,
	}

	local function homeDoorFolder()
		return Workspace:FindFirstChild("HomeDoorSS")
	end

	local function ownerValue(door)
		local owner = door and door:FindFirstChild("Owner")
		if not owner then
			return nil
		end
		local value = owner.Value
		if typeof(value) == "Instance" then
			if value:IsA("Player") then
				return value.Name
			end
			if value:IsA("StringValue") then
				return value.Value
			end
			return value.Name
		end
		if type(value) == "string" then
			return value
		end
		if type(value) == "number" then
			return tostring(value)
		end
		return nil
	end

	local function isUnownedName(name)
		if not name or name == "" or name == "None" or name == "nil" or name == "null" then
			return true
		end
		return false
	end

	local function doorOwnedByLocal(door)
		if not (door and door:IsA("Model")) then
			return false
		end
		local owner = door:FindFirstChild("Owner")
		if not owner then
			return false
		end
		local value = owner.Value
		-- Live doors use ObjectValue → Player; the phone UI compares to .Name and stays broken.
		if value == LocalPlayer then
			return true
		end
		if typeof(value) == "Instance" and value:IsA("Player") then
			return value == LocalPlayer
		end
		local name = ownerValue(door)
		if isUnownedName(name) then
			return false
		end
		return name == LocalPlayer.Name or name == tostring(LocalPlayer.UserId)
	end

	local function getOwnedDoor()
		local folder = homeDoorFolder()
		if not folder then
			return nil
		end
		for _, door in ipairs(folder:GetChildren()) do
			if doorOwnedByLocal(door) then
				return door
			end
		end
		return nil
	end

	local function syncPhoneOwnedHomeUi(door)
		-- Game CheckCams does Owner.Value == LocalPlayer.Name; ObjectValue owners never match.
		local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
		if not playerGui then
			return
		end
		local checkCams = playerGui:FindFirstChild("CheckCams", true)
		if not (checkCams and checkCams:IsA("GuiObject")) then
			return
		end
		if door then
			if checkCams:IsA("TextLabel") or checkCams:IsA("TextButton") then
				if checkCams.Text == "NO OWNED HOUSE" or checkCams.Text == "" then
					checkCams.Text = "Check Cameras"
				end
			end
			pcall(function()
				checkCams.BackgroundColor3 = Color3.fromRGB(83, 128, 135)
			end)
		end
	end

	local function doorPosition(door)
		if not door then
			return nil
		end
		local cam = door:FindFirstChild("RingCamera3", true)
		if cam and cam:IsA("BasePart") then
			return cam.Position, cam
		end
		local doorPart = door:FindFirstChild("Door", true)
		if doorPart and doorPart:IsA("BasePart") then
			return doorPart.Position, doorPart
		end
		if doorPart and doorPart:IsA("Model") then
			local part = doorPart.PrimaryPart or doorPart:FindFirstChildWhichIsA("BasePart", true)
			if part then
				return part.Position, part
			end
			local ok, pivot = pcall(function()
				return doorPart:GetPivot().Position
			end)
			if ok and pivot then
				return pivot, nil
			end
		end
		return door:GetPivot().Position, nil
	end

	-- Prefer the actual Door mesh at the entrance (RingCamera3 can sit inside the unit).
	local function doorEntrancePosition(door)
		if not door then
			return nil
		end
		local doorModel = door:FindFirstChild("Door")
		if doorModel then
			if doorModel:IsA("BasePart") then
				return doorModel.Position
			end
			local part = doorModel.PrimaryPart or doorModel:FindFirstChildWhichIsA("BasePart", true)
			if part then
				return part.Position
			end
			local ok, pivot = pcall(function()
				return doorModel:GetPivot().Position
			end)
			if ok and pivot then
				return pivot
			end
		end
		return doorPosition(door)
	end

	local function findPromptNear(position, maxDist, predicate)
		local best, bestDist, bestPos = nil, maxDist, nil
		for _, descendant in ipairs(Workspace:GetDescendants()) do
			if descendant:IsA("ProximityPrompt") and predicate(descendant) then
				local pos = getWorldPosition(descendant.Parent)
				if pos then
					local dist = (pos - position).Magnitude
					if dist < bestDist then
						best, bestDist, bestPos = descendant, dist, pos
					end
				end
			end
		end
		return best, bestPos
	end

	local function findRentPromptAt(position, maxDist)
		return findPromptNear(position, maxDist or 35, function(prompt)
			return prompt.ObjectText == "Rent Home"
		end)
	end

	local function doorNearPosition(position, maxDist)
		local folder = homeDoorFolder()
		if not (folder and position) then
			return nil
		end
		local best, bestDist = nil, maxDist or 60
		for _, door in ipairs(folder:GetChildren()) do
			if door:IsA("Model") then
				local pos = doorPosition(door)
				if pos then
					local dist = (pos - position).Magnitude
					if dist < bestDist then
						best, bestDist = door, dist
					end
				end
			end
		end
		return best
	end

	local function standNearPrompt(prompt, promptPos)
		local humanoid, root = getHumanoid(), getRoot()
		if not (humanoid and root and promptPos) then
			return nil
		end
		local parent = prompt.Parent
		local away = Vector3.new(0, 0, 1)
		if parent and parent:IsA("BasePart") then
			local look = parent.CFrame.LookVector
			local flat = Vector3.new(look.X, 0, look.Z)
			if flat.Magnitude > 0.15 then
				away = flat.Unit
			else
				local right = parent.CFrame.RightVector
				flat = Vector3.new(right.X, 0, right.Z)
				if flat.Magnitude > 0.15 then
					away = flat.Unit
				end
			end
		end
		-- Ignore door/sign so the ray hits the sidewalk, not the elevated HitPrompt.
		local ignore = prompt:FindFirstAncestorOfClass("Model") or parent
		local standXZ = Vector3.new(promptPos.X + away.X * 3.2, 0, promptPos.Z + away.Z * 3.2)
		-- Prefer sidewalk/porch at the prompt's floor — casting from Y=320 was landing on roofs.
		local groundY = findGroundY(Vector3.new(standXZ.X, promptPos.Y + 12, standXZ.Z), ignore, promptPos.Y)
		local lift = getStandHeight(humanoid, root)
		local standY = (groundY or promptPos.Y) + lift
		if standY > promptPos.Y + 3 then
			standY = promptPos.Y + lift * 0.35
		end
		local stand = Vector3.new(standXZ.X, standY, standXZ.Z)
		return CFrame.lookAt(stand, Vector3.new(promptPos.X, stand.Y, promptPos.Z))
	end

	local function standAtDoor(door)
		local humanoid, root = getHumanoid(), getRoot()
		local entrance = door and (doorEntrancePosition(door) or doorPosition(door))
		if not (humanoid and root and entrance) then
			return nil
		end
		local groundY = findGroundY(entrance + Vector3.new(0, 12, 0), door, entrance.Y)
		local lift = getStandHeight(humanoid, root)
		local standY = (groundY or entrance.Y) + lift
		if standY > entrance.Y + 4 then
			standY = entrance.Y + lift * 0.35
		end
		-- Step slightly outside the doorway toward open space.
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = { LocalPlayer.Character, door }
		local eye = Vector3.new(entrance.X, entrance.Y + 2, entrance.Z)
		local bestDir, bestDist = Vector3.new(0, 0, -1), -1
		for _, dir in ipairs({
			Vector3.new(1, 0, 0),
			Vector3.new(-1, 0, 0),
			Vector3.new(0, 0, 1),
			Vector3.new(0, 0, -1),
		}) do
			local hit = Workspace:Raycast(eye, dir * 40, params)
			local dist = hit and hit.Distance or 40
			if dist > bestDist then
				bestDist = dist
				bestDir = dir
			end
		end
		local stand = Vector3.new(entrance.X, standY, entrance.Z) + bestDir * 3.2
		return CFrame.lookAt(stand, Vector3.new(entrance.X, stand.Y, entrance.Z))
	end

	local function buyHomeAt(position, label)
		local owned = getOwnedDoor()
		if owned then
			notify("You already own a home. Sell or leave it before buying another.")
			return false
		end
		local prompt, promptPos = findRentPromptAt(position, 40)
		if not (prompt and promptPos) then
			notify((label or "Home") .. " buy prompt was not found.")
			return false
		end
		local door = doorNearPosition(promptPos, 50)
		if door and doorOwnedByLocal(door) then
			notify("You already own this home.")
			return false
		end
		if door and not isUnownedName(ownerValue(door)) then
			notify((label or "Home") .. " is already owned by " .. tostring(ownerValue(door)) .. ".")
			return false
		end

		local savedLos = prompt.RequiresLineOfSight
		local savedDist = prompt.MaxActivationDistance
		pcall(function()
			prompt.Enabled = true
			prompt.RequiresLineOfSight = false
			if (prompt.MaxActivationDistance or 0) < 14 then
				prompt.MaxActivationDistance = 14
			end
		end)

		local goal = standNearPrompt(prompt, promptPos)
		if not goal then
			notify("Could not stand near " .. (label or "home") .. ".")
			return false
		end

		-- Homes are usually far; Instant + seat snap. Retry a few times through AC clears.
		local reached = false
		for attempt = 1, 3 do
			if teleportOnFoot(goal) then
				reached = true
				break
			end
			local clearDeadline = os.clock() + 1.6
			while LocalPlayer:GetAttribute("LastACPos") and os.clock() < clearDeadline and not Arsenic.Destroyed do
				task.wait()
			end
			goal = standNearPrompt(prompt, promptPos) or goal
			task.wait(0.2 * attempt)
		end
		if not reached then
			notify("Could not reach " .. (label or "home") .. ".")
			pcall(function()
				prompt.RequiresLineOfSight = savedLos
				prompt.MaxActivationDistance = savedDist
			end)
			return false
		end

		-- Snap again after Instant TP in case anti-cheat left us short / high.
		local root = getRoot()
		if root and (root.Position - goal.Position).Magnitude > 4 then
			pcall(function()
				root.CFrame = goal
				root.AssemblyLinearVelocity = Vector3.zero
			end)
			task.wait(0.1)
		end
		root = getRoot()
		if root and root.Position.Y > promptPos.Y + 2 then
			local grounded = standNearPrompt(prompt, promptPos)
			if grounded then
				pcall(function()
					root.CFrame = grounded
					root.AssemblyLinearVelocity = Vector3.zero
				end)
				task.wait(0.1)
			end
		end

		local bought = false
		local maxReach = math.max(prompt.MaxActivationDistance or 10, 12)
		for _ = 1, 8 do
			root = getRoot()
			if not root or (root.Position - promptPos).Magnitude > maxReach then
				local again = standNearPrompt(prompt, promptPos)
				if again then
					-- Prefer Instant reseat over a raw CFrame write the AC may eat.
					if not teleportOnFoot(again) then
						pcall(function()
							root = getRoot()
							if root then
								root.CFrame = again
								root.AssemblyLinearVelocity = Vector3.zero
							end
						end)
					end
					task.wait(0.12)
				end
			end
			firePrompt(prompt, true)
			task.wait(0.25)
			door = doorNearPosition(promptPos, 50)
			if door and doorOwnedByLocal(door) then
				bought = true
				break
			end
		end

		pcall(function()
			prompt.RequiresLineOfSight = savedLos
			prompt.MaxActivationDistance = savedDist
		end)

		if bought then
			notify("Bought " .. (label or "home") .. ".")
		else
			notify("Tried to buy " .. (label or "home") .. " — interact again if ownership did not update.")
		end
		return bought
	end

	local function listUnownedHomes()
		local open = {}
		for _, entry in ipairs(HOME_CATALOG) do
			local pos = Vector3.new(entry.x, entry.y, entry.z)
			local door = doorNearPosition(pos, 55)
			if not door or isUnownedName(ownerValue(door)) then
				table.insert(open, entry)
			end
		end
		return open
	end

	local function teleportToOwnedHome()
		local door = getOwnedDoor()
		if not door then
			notify("You do not own a home.")
			return
		end
		local goal = standAtDoor(door)
		if not goal then
			notify("Could not find your home door.")
			return
		end
		if not teleportOnFoot(goal) then
			notify("Could not teleport to your home.")
		end
	end

	local function teleportToHomeAt(position, label)
		local door = doorNearPosition(position, 55)
		local goal = door and standAtDoor(door) or nil
		if not goal then
			local prompt, promptPos = findRentPromptAt(position, 50)
			if prompt and promptPos then
				goal = standNearPrompt(prompt, promptPos)
			end
		end
		if not goal then
			local groundY = findGroundY(position + Vector3.new(0, 12, 0), nil, position.Y)
			local humanoid, root = getHumanoid(), getRoot()
			local lift = (humanoid and root and getStandHeight(humanoid, root)) or 3
			local standY = (groundY or position.Y) + lift
			goal = CFrame.new(position.X, standY, position.Z)
		end
		if not teleportOnFoot(goal) then
			notify("Could not teleport to " .. (label or "home") .. ".")
			return false
		end
		return true
	end

	local function bedBelongsToDoor(bedPos, door, doorPos)
		if not (bedPos and door and doorPos) then
			return false
		end
		local ourDist = (bedPos - doorPos).Magnitude
		-- Beds sit inside the unit; keep a tight plot radius.
		if ourDist > 85 then
			return false
		end
		local folder = homeDoorFolder()
		if not folder then
			return true
		end
		for _, other in ipairs(folder:GetChildren()) do
			if other ~= door and other:IsA("Model") then
				local otherPos = doorEntrancePosition(other) or doorPosition(other)
				if otherPos and (bedPos - otherPos).Magnitude + 2 < ourDist then
					return false
				end
			end
		end
		return true
	end

	local function sleepInOwnedBed()
		local door = getOwnedDoor()
		local humanoid, root = getHumanoid(), getRoot()
		if not door then
			notify("You do not own a home.")
			return
		end
		local anchor = doorEntrancePosition(door) or doorPosition(door)
		if not (humanoid and anchor) then
			notify("Could not find your home to sleep in.")
			return
		end
		local beds = Workspace:FindFirstChild("Beds")
		local bestPrompt, bestPos, bestDist = nil, nil, 85
		local scanRoot = beds or Workspace
		for _, descendant in ipairs(scanRoot:GetDescendants()) do
			if descendant:IsA("ProximityPrompt") then
				local text = string.lower(tostring(descendant.ActionText) .. " " .. tostring(descendant.ObjectText))
				if string.find(text, "sleep", 1, true) or descendant.ObjectText == "Bed" or descendant.ObjectText == "Sleep" then
					local pos = getWorldPosition(descendant.Parent)
					if pos and bedBelongsToDoor(pos, door, anchor) then
						local dist = (pos - anchor).Magnitude
						if dist < bestDist then
							bestPrompt, bestPos, bestDist = descendant, pos, dist
						end
					end
				end
			end
		end
		if not bestPrompt then
			notify("No bed found in your home.")
			return
		end
		local lift = getStandHeight(humanoid, root)
		local groundY = findGroundY(bestPos + Vector3.new(0, 10, 0), bestPrompt:FindFirstAncestorOfClass("Model"), bestPos.Y)
		local standY = (groundY or bestPos.Y) + lift * 0.35
		if standY > bestPos.Y + 3 then
			standY = bestPos.Y + 1.2
		end
		local goal = CFrame.new(bestPos.X, standY, bestPos.Z)
		if not teleportOnFoot(goal) then
			notify("Could not reach your bed.")
			return
		end
		task.wait(0.15)
		firePrompt(bestPrompt, true)
		notify("Sleeping.")
	end

	local function homeSupportsParty(door)
		if not door then
			return false, nil, nil
		end
		local anchor = doorPosition(door)
		if not anchor then
			return false, nil, nil
		end
		-- Only count a Host Party prompt that belongs to / sits at this home.
		local prompt, pos = findPromptNear(anchor, 90, function(p)
			if p.ActionText ~= "Host Party" then
				return false
			end
			if p:IsDescendantOf(door) then
				return true
			end
			local model = p:FindFirstAncestorOfClass("Model")
			if model and (model == door or model:IsDescendantOf(door) or door:IsDescendantOf(model)) then
				return true
			end
			-- Same plot: prompt near this door and not nearer another HomeDoor.
			local other = doorNearPosition(getWorldPosition(p.Parent) or anchor, 90)
			return other == door
		end)
		if prompt and pos then
			return true, prompt, pos
		end
		-- Some homes expose HostPartyPrompt / PartyStuff under the door model.
		for _, descendant in ipairs(door:GetDescendants()) do
			if descendant:IsA("ProximityPrompt") and descendant.ActionText == "Host Party" then
				local ppos = getWorldPosition(descendant.Parent)
				return true, descendant, ppos or anchor
			end
			if descendant.Name == "HostPartyPrompt" or descendant.Name == "PartyStuff" then
				local nested = descendant:FindFirstChildWhichIsA("ProximityPrompt", true)
				if nested and nested.ActionText == "Host Party" then
					local ppos = getWorldPosition(nested.Parent)
					return true, nested, ppos or anchor
				end
				return true, nested, getWorldPosition(descendant) or anchor
			end
		end
		return false, nil, nil
	end

	local function throwParty()
		local door = getOwnedDoor()
		if not door then
			notify("You need to own a home before throwing a party.")
			return
		end
		local supports, prompt, pos = homeSupportsParty(door)
		if not supports then
			notify("Your home does not support house parties.")
			return
		end
		if not (prompt and pos) then
			notify("Party feature found, but the Host Party prompt is missing right now.")
			return
		end
		local goal = standNearPrompt(prompt, pos) or CFrame.new(pos + Vector3.new(0, 3, 0))
		if not teleportOnFoot(goal) then
			notify("Could not reach the party prompt.")
			return
		end
		task.wait(0.15)
		firePrompt(prompt, true)
		local remote = ReplicatedStorage:FindFirstChild("BlockPartyRemote")
		if remote and remote:IsA("RemoteEvent") then
			pcall(remote.FireServer, remote)
		end
		notify("Tried to host a party.")
	end

	local function backDoorPart(door)
		if not door then
			return nil
		end
		local frontPos = doorPosition(door)
		if not frontPos then
			return nil
		end
		local best, bestDist = nil, 90
		for _, descendant in ipairs(Workspace:GetDescendants()) do
			if descendant:IsA("ProximityPrompt") and descendant.ActionText == "Back Door" then
				local pos = getWorldPosition(descendant.Parent)
				if pos and (pos - frontPos).Magnitude < bestDist then
					best, bestDist = descendant.Parent, (pos - frontPos).Magnitude
				end
			end
		end
		if best and best:IsA("BasePart") then
			return best
		end
		if best then
			return best:IsA("Model") and best.PrimaryPart or best:FindFirstChildWhichIsA("BasePart", true)
		end
		if homeWatch.backCamPart and homeWatch.backCamPart.Parent then
			return homeWatch.backCamPart
		end
		-- Synthetic rear spot opposite the Ring camera look.
		local cam = door:FindFirstChild("RingCamera3", true)
		if cam and cam:IsA("BasePart") then
			local part = Instance.new("Part")
			part.Name = "ArsenicBackCam"
			part.Anchored = true
			part.CanCollide = false
			part.Transparency = 1
			part.Size = Vector3.new(1, 1, 1)
			part.CFrame = cam.CFrame * CFrame.new(0, 0, 14) * CFrame.Angles(0, math.pi, 0)
			part.Parent = Workspace
			homeWatch.backCamPart = part
			return part
		end
		return nil
	end

	local function suppressRentGui()
		local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
		local rentGui = playerGui and playerGui:FindFirstChild("RentGui")
		if not rentGui then
			return
		end
		local frame = rentGui:FindFirstChild("Frame")
		if frame and frame:IsA("GuiObject") then
			frame.Visible = false
		end
		for _, child in ipairs(rentGui:GetDescendants()) do
			if child:IsA("LocalScript") then
				suppressScript(child, "NoRentPay")
				pcall(function()
					child:Destroy()
				end)
			end
		end
	end

	local function openBuyMap(opts)
		if Arsenic.WorldMap and Arsenic.WorldMap.open then
			Arsenic.WorldMap.open(opts or { focus = "homes" })
		else
			notify("World map is still loading — open it again in a moment.")
		end
	end

	local function closeBuyMap()
		if Arsenic.WorldMap and Arsenic.WorldMap.close then
			Arsenic.WorldMap.close()
		end
	end

	local function isBreakInPrompt(prompt)
		if not prompt or not prompt:IsA("ProximityPrompt") then
			return false
		end
		local objectText = tostring(prompt.ObjectText or "")
		local actionText = tostring(prompt.ActionText or "")
		if objectText == "Hit Door" or actionText == "Hit Door" then
			return true
		end
		return objectText == "Door" and string.find(string.lower(actionText), "hit", 1, true) ~= nil
	end

	local function promptBelongsToDoor(prompt, door)
		return door and prompt and prompt:IsDescendantOf(door)
	end

	local function onBreakInAttempt(playerName)
		local now = os.clock()
		if now - homeWatch.breakLast < 2.5 then
			return
		end
		homeWatch.breakLast = now
		if on("NotifyBreakIn") then
			notify((playerName or "Someone") .. " is trying to break into your home!")
		end
		if on("TeleportBreakIn") then
			task.spawn(teleportToOwnedHome)
		end
	end

	local function onFrontMotion(playerName)
		local now = os.clock()
		if now - homeWatch.motionLast < 4 then
			return
		end
		homeWatch.motionLast = now
		if on("TeleportMotion") then
			notify("Motion at front door" .. (playerName and (": " .. playerName) or "") .. " — teleporting.")
			task.spawn(teleportToOwnedHome)
		end
	end

	local function onBackMotion(playerName)
		local now = os.clock()
		if now - homeWatch.backLast < 4 then
			return
		end
		homeWatch.backLast = now
		if on("NotifyBackDoorMotion") then
			notify("Motion at back door" .. (playerName and (": " .. playerName) or "") .. ".")
		end
	end

	local function stopHomeWatch()
		if homeWatch.conn then
			homeWatch.conn:Disconnect()
			homeWatch.conn = nil
		end
	end

	local function homeWatchNeeded()
		return on("NotifyBreakIn")
			or on("TeleportBreakIn")
			or on("TeleportMotion")
			or on("NotifyBackDoorMotion")
	end

	local function ensureHomeWatch()
		if homeWatch.conn or not homeWatchNeeded() then
			if not homeWatchNeeded() then
				stopHomeWatch()
			end
			return
		end
		local accum = 0
		homeWatch.conn = RunService.Heartbeat:Connect(function(dt)
			if Arsenic.Destroyed or not homeWatchNeeded() then
				stopHomeWatch()
				return
			end
			accum += dt
			if accum < 0.2 then
				return
			end
			accum = 0
			local door = getOwnedDoor()
			if not door then
				return
			end

			syncPhoneOwnedHomeUi(door)

			local frontPos = doorPosition(door)
			local back = on("NotifyBackDoorMotion") and backDoorPart(door) or nil
			local backPos = back and back.Position or nil
			for _, player in ipairs(Players:GetPlayers()) do
				if player ~= LocalPlayer then
					local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
					if root then
						if frontPos and (root.Position - frontPos).Magnitude <= 10 then
							if on("TeleportMotion") or on("NotifyBreakIn") then
								-- Motion uses Ring radius; break-in also checked via prompts.
								if on("TeleportMotion") then
									onFrontMotion(player.Name)
								end
							end
						end
						if backPos and (root.Position - backPos).Magnitude <= 10 then
							onBackMotion(player.Name)
						end
					end
				end
			end

			-- Kick / break progress sounds on owned door.
			for _, descendant in ipairs(door:GetDescendants()) do
				if descendant:IsA("Sound") and descendant.Playing and (descendant.Name == "Kick" or descendant.Name == "Break" or descendant.Name == "Smack") then
					onBreakInAttempt("Someone")
					break
				end
			end
		end)
		track(homeWatch.conn)
	end

	track(ProximityPromptService.PromptButtonHoldBegan:Connect(function(prompt, player)
		if not (on("NotifyBreakIn") or on("TeleportBreakIn")) then
			return
		end
		if player == LocalPlayer or not isBreakInPrompt(prompt) then
			return
		end
		local door = getOwnedDoor()
		if promptBelongsToDoor(prompt, door) then
			onBreakInAttempt(player and player.Name or "Someone")
		end
	end))

	track(ProximityPromptService.PromptTriggered:Connect(function(prompt, player)
		if not (on("NotifyBreakIn") or on("TeleportBreakIn")) then
			return
		end
		if player == LocalPlayer or not isBreakInPrompt(prompt) then
			return
		end
		local door = getOwnedDoor()
		if promptBelongsToDoor(prompt, door) then
			onBreakInAttempt(player and player.Name or "Someone")
		end
	end))

	Features.NoRentPay = {
		enable = function()
			suppressRentGui()
		end,
		disable = function()
			restoreScripts("NoRentPay")
		end,
	}

	for _, name in ipairs({
		"NotifyBreakIn",
		"TeleportBreakIn",
		"TeleportMotion",
		"NotifyBackDoorMotion",
	}) do
		Features[name] = {
			enable = function()
				ensureHomeWatch()
			end,
			disable = function()
				ensureHomeWatch()
			end,
		}
	end

	Arsenic.Homes = {
		catalog = HOME_CATALOG,
		teleportToHomeAt = teleportToHomeAt,
		buyHomeAt = buyHomeAt,
		teleportHome = function()
			runPlayerAction(teleportToOwnedHome)
		end,
		openBuyMap = openBuyMap,
		closeBuyMap = closeBuyMap,
		buyRandom = function()
			runPlayerAction(function()
				local open = listUnownedHomes()
				if #open == 0 then
					notify("No unowned homes found.")
					return
				end
				local entry = open[math.random(1, #open)]
				buyHomeAt(Vector3.new(entry.x, entry.y, entry.z), entry.t .. " (" .. entry.r .. ")")
			end)
		end,
		buyMainMansion = function()
			runPlayerAction(function()
				buyHomeAt(MAIN_MANSION, "Main City Mansion")
			end)
		end,
		buyNewCityMansion = function()
			runPlayerAction(function()
				buyHomeAt(NEW_CITY_MANSION, "New City Mansion")
			end)
		end,
		sleepInBed = function()
			runPlayerAction(sleepInOwnedBed)
		end,
		throwParty = function()
			runPlayerAction(throwParty)
		end,
	}

	-- Keep No Rent Pay active while enabled.
	track(RunService.Heartbeat:Connect(function()
		if on("NoRentPay") then
			suppressRentGui()
		end
	end))

	table.insert(Arsenic.Cleanup, function()
		closeBuyMap()
		stopHomeWatch()
		if homeWatch.backCamPart then
			homeWatch.backCamPart:Destroy()
			homeWatch.backCamPart = nil
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
	Arsenic.ICONS = ICONS

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
		showName = "Arsenic",
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
		{ "DisableJumpFatigue", "Disable Jump Fatigue", "Jump without delay.", ICONS.fastForward },
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
		{
			"DisableSurrenderEmote",
			"Disable Surrender Emote",
			"Removes the Surrender emote from the emote UI to prevent you from accidentally selecting it and teleporting to prison.",
			ICONS.hand,
		},
		{ "Minimap", "Minimap", "Shows a top-down map of the city with your position and other players.", ICONS.map },
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

	MeTab:CreateInput({
		name = "Walkspeed",
		description = "How fast you should walk. If you set this too fast you can get kicked.",
		icon = ICONS.gauge,
		flag = "Me_WalkSpeed",
		placeholder = "16",
		numeric = true,
		callback = function(text)
			local value = tonumber(text)
			if value and value > 0 then
				Arsenic.Values.WalkSpeed = math.clamp(value, 1, 200)
			else
				Arsenic.Values.WalkSpeed = nil
			end
		end,
	})

	MeTab:CreateInput({
		name = "Jump Height",
		description = "How high you can jump. If you set this too high you can get kicked for flying.",
		icon = ICONS.fastForward,
		flag = "Me_JumpHeight",
		placeholder = "7.2",
		numeric = true,
		callback = function(text)
			local value = tonumber(text)
			if value and value > 0 then
				Arsenic.Values.JumpHeight = math.clamp(value, 0.5, 100)
			else
				Arsenic.Values.JumpHeight = nil
			end
		end,
	})

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


	-- Homes ------------------------------------------------------------------------

	local HomesTab = Window:CreateTab({ name = "Homes", icon = ICONS.building })

	HomesTab:CreateButton({
		name = "Teleport to Home",
		description = "Teleport to your house.",
		icon = ICONS.navigation,
		callback = function()
			if Arsenic.Homes then
				Arsenic.Homes.teleportHome()
			end
		end,
	})

	HomesTab:CreateButton({
		name = "Select Home to Buy",
		description = "Opens the world map focused on purchasable homes (same map as clicking the minimap).",
		icon = ICONS.map,
		callback = function()
			if Arsenic.Homes then
				Arsenic.Homes.openBuyMap({ focus = "homes" })
			end
		end,
	})

	HomesTab:CreateButton({
		name = "Buy Random House",
		description = "Buys a random unowned home.",
		icon = ICONS.refresh,
		callback = function()
			if Arsenic.Homes then
				Arsenic.Homes.buyRandom()
			end
		end,
	})

	HomesTab:CreateButton({
		name = "Buy Main City Mansion",
		description = "Buys the mansion near the main city.",
		icon = ICONS.landmark,
		callback = function()
			if Arsenic.Homes then
				Arsenic.Homes.buyMainMansion()
			end
		end,
	})

	HomesTab:CreateButton({
		name = "Buy New City Mansion",
		description = "Buys the mansion in the new city.",
		icon = ICONS.landmark,
		callback = function()
			if Arsenic.Homes then
				Arsenic.Homes.buyNewCityMansion()
			end
		end,
	})

	HomesTab:CreateToggle({
		name = "No Rent Pay",
		description = "Stops the rent payment popup and rent GUI from forcing you to pay.",
		icon = ICONS.banknote,
		flag = "Homes_NoRentPay",
		value = false,
		callback = function(value)
			setFeature("NoRentPay", value)
		end,
	})

	HomesTab:CreateButton({
		name = "Sleep in Bed",
		description = "Sleep in your bed.",
		icon = ICONS.moon,
		callback = function()
			if Arsenic.Homes then
				Arsenic.Homes.sleepInBed()
			end
		end,
	})

	HomesTab:CreateButton({
		name = "Throw Party",
		description = "Throw a house party. Only works in homes with this feature available.",
		icon = ICONS.heartHandshake,
		callback = function()
			if Arsenic.Homes then
				Arsenic.Homes.throwParty()
			end
		end,
	})

	local homeToggles = {
		{
			"NotifyBreakIn",
			"Notify On Attempted Break-In",
			"Arsenic will notify you when someone tries to break down your door.",
			ICONS.shieldAlert,
		},
		{
			"TeleportBreakIn",
			"Teleport On Attempted Break-In",
			"You will be teleported to your house when someone tries to break down your door.",
			ICONS.navigation,
		},
		{
			"TeleportMotion",
			"Teleport On Motion Detection",
			"You will be teleported to your house when someone walks in front of your Ring camera.",
			ICONS.activity,
		},
		{
			"NotifyBackDoorMotion",
			"Notify On Back Door Motion",
			"Arsenic will notify you when someone walks in front of your back door (managed by Arsenic as there is no official back door cam).",
			ICONS.eye,
		},
	}

	for _, entry in ipairs(homeToggles) do
		local feature, label, description, icon = entry[1], entry[2], entry[3], entry[4]
		HomesTab:CreateToggle({
			name = label,
			description = description,
			icon = icon,
			flag = "Homes_" .. feature,
			value = false,
			callback = function(value)
				setFeature(feature, value)
			end,
		})
	end

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

	local vehicleEspToggles = {
		{ "VehicleESP", "Vehicle ESP", "View vehicles through walls.", ICONS.car },
		{ "VehicleESPNames", "Show Vehicle Names", "Shows vehicle names above vehicle model.", ICONS.type },
		{ "VehicleESPHealth", "Show Vehicle Health", "Shows vehicle health to the left of the vehicle model.", ICONS.heart },
		{
			"VehicleESPDistance",
			"Show Vehicle Distance",
			"Shows vehicle distance in studs above vehicle model.",
			ICONS.ruler,
		},
		{
			"VehicleESPSpeed",
			"Show Vehicle Speed",
			"Shows vehicle speed below the vehicle (uses Settings → Measurement System).",
			ICONS.gauge,
		},
	}
	for _, entry in ipairs(vehicleEspToggles) do
		EspTab:CreateToggle({
			name = entry[2],
			description = entry[3],
			icon = entry[4],
			flag = "ESP_" .. entry[1],
			value = false,
			callback = function(value)
				setFeature(entry[1], value)
			end,
		})
	end

	local function radiusInput(valueName, label, description, flag)
		EspTab:CreateInput({
			name = label,
			description = description,
			icon = ICONS.ruler,
			flag = flag,
			placeholder = "0",
			numeric = true,
			callback = function(text)
				local radius = tonumber(text)
				Arsenic.Values[valueName] = radius and math.max(radius, 0) or 0
			end,
		})
	end

	radiusInput(
		"ESPMaxRadius",
		"Max Stud Radius",
		"The radius in studs that ESP will track non-friend players. Leave empty or 0 for no limit.",
		"ESP_MaxStudRadius"
	)
	radiusInput(
		"FriendESPMaxRadius",
		"Friend Max Stud Radius",
		"The radius in studs that ESP will track friends. Anything higher than this radius will not appear on ESP. Leave empty or 0 for no limit.",
		"ESP_FriendMaxStudRadius"
	)
	radiusInput(
		"VehicleESPMaxRadius",
		"Vehicle Max Stud Radius",
		"The radius in studs that ESP will track vehicles. Anything higher than this radius will not appear on ESP. Leave empty or 0 for no limit.",
		"ESP_VehicleMaxStudRadius"
	)

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
	colorOption("VehicleHighlightColor", "Vehicle Highlight Color", Color3.fromRGB(80, 180, 255))

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
		{
			"Ragdoll Player",
			"Teleports to the target, shoots them in the leg with your equipped gun, then teleports back.",
			ragdollPlayer,
			ICONS.userX,
		},
		{
			"Kill Player",
			"Teleports to the target, shoots them in the head with your equipped gun, then teleports back.",
			killPlayer,
			ICONS.skull,
		},
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

	local selectedBuyChoice = nil
	local itemDropdown

	local function refreshBuyItems()
		table.clear(storeItemCache)
		local options = getAllStoreItems(true)
		if itemDropdown then
			pcall(function()
				itemDropdown:Refresh(options)
			end)
		end
		return options
	end

	itemDropdown = BuyTab:CreateDropdown({
		name = "Item",
		description = "Every store listing of each item, with that store's price. Same item can appear more than once.",
		icon = ICONS.package,
		options = getAllStoreItems(),
		forgetState = true,
		callback = function(selection)
			if type(selection) == "table" then
				selection = selection[1]
			end
			selectedBuyChoice = (type(selection) == "string" and Arsenic.BuyOptionMap and Arsenic.BuyOptionMap[selection])
				or nil
		end,
	})

	BuyTab:CreateButton({
		name = "Refresh Items",
		description = "Reload every store catalog and update prices in the Item dropdown.",
		icon = ICONS.refresh,
		callback = function()
			local options = refreshBuyItems()
			notify(("Loaded %d store listings."):format(#options))
		end,
	})

	BuyTab:CreateButton({
		name = "Buy Item",
		description = "Buys the selected store listing (teleports there, purchases, then returns).",
		icon = ICONS.bag,
		callback = function()
			if not selectedBuyChoice then
				notify("Choose an item first.")
				return
			end
			local item = selectedBuyChoice.item
			local storeName = selectedBuyChoice.store
			runPlayerAction(function()
				buyItem(item, storeName)
			end)
		end,
	})

	task.defer(function()
		task.wait(1)
		if not Arsenic.Destroyed then
			refreshBuyItems()
		end
	end)

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

	moneyToggle(
		"InfiniteMoneyLoop",
		"Infinite Money Loop",
		"Arsenic will do Infinite Money, Auto Clean the money, then put $900K in the ATM ($30K at a time, rapidly), and keep doing it in a loop.",
		ICONS.repeatIcon
	)

	MoneyTab:CreateButton({
		name = "Auto Clean Money",
		description = "Travels to the laundromat (uses your Teleport Method), runs the cash register, grabs the bag as soon as it enables, cashes it at the bank, then returns.",
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

	-- Dupe --------------------------------------------------------------------------

	local DupeTab = Window:CreateTab({ name = "Dupe", icon = ICONS.repeatIcon })

	local function dupeToggle(feature, label, description, icon)
		DupeTab:CreateToggle({
			name = label,
			description = description,
			icon = icon,
			flag = "Dupe_" .. feature,
			forgetState = true,
			value = false,
			callback = function(value)
				setFeature(feature, value)
			end,
		})
	end

	DupeTab:CreateSection({ name = "Actions", icon = ICONS.repeatIcon })

	dupeToggle(
		"AutoDupe",
		"Auto Dupe Held Item",
		"Repeats the market dupe on the held tool. Parks extras between attempts when enabled below; turning off pulls them back.",
		ICONS.infinity
	)

	DupeTab:CreateButton({
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
	Arsenic.Locations = LOCATIONS

--------------------------------------------------------------------------------
-- World Map (full map from minimap / Homes)
--------------------------------------------------------------------------------

;(function()
	local UserInputService = game:GetService("UserInputService")
	local ContextActionService = game:GetService("ContextActionService")
	local Players = game:GetService("Players")
	local RunService = game:GetService("RunService")
	local Workspace = game:GetService("Workspace")

	local MAP_SINK = "ArsenicWorldMapSink"
	-- Must match Arsenic/minimap_v16.png pixel size.
	local MAP_ASPECT = 481 / 1800
	local MAP_WORLD = {
		minX = -1858.72632,
		maxX = 427.092346,
		minZ = -4523.78271,
		maxZ = 4030.35742,
	}

	-- Cover-fit the tall map into the viewport (GTA full-bleed). Contain-fit left
	-- huge side letterboxes and made edge blips look like they floated in the void.
	local function mapCoverSize(viewport)
		local fitW = viewport.X
		local fitH = viewport.X / MAP_ASPECT
		if fitH < viewport.Y then
			fitH = viewport.Y
			fitW = viewport.Y * MAP_ASPECT
		end
		return fitW, fitH
	end
	-- Street approaches for interior teleports (same idea as DRIVE_SPOTS).
	local STREET_OVERRIDES = {
		["Top Gun Store"] = Vector3.new(-280, 280, -900),
		["Bottom Gun Store"] = Vector3.new(-1025, 255, -810),
		["Dealership"] = Vector3.new(-455, 253, -1265),
		["Hospital"] = Vector3.new(-1540, 252, 42),
		["Market"] = Vector3.new(-450, 333, -540),
	}
	local JOB_NAMES = {
		["Deli Job"] = true,
		["Construction Job"] = true,
		["Studio Job"] = true,
		["Janitor Job"] = true,
		["Delivery Job"] = true,
	}
	local BUSINESS_NAMES = {
		["Bank"] = true,
		["Bank Vault"] = true,
		["Pawn Shop"] = true,
		["Sell Stolen Items"] = true,
		["Sell Car"] = true,
		["Car Repair"] = true,
		["Gas Station"] = true,
		["Tattoo Shop"] = true,
		["Drip Store"] = true,
		["Deli"] = true,
		["Bandage Shop"] = true,
		["5th Shop"] = true,
		["City Gun Store"] = true,
		["Prison Gun Store"] = true,
		["Bottom Gun Store"] = true,
		["Top Gun Store"] = true,
		["Tha Shop (Lemonade)"] = true,
		["Dealership"] = true,
		["Market"] = true,
		["Hospital"] = true,
		["Courthouse"] = true,
		["NYPD HQ"] = true,
		["Soda Seller"] = true,
		["Lemon Seller"] = true,
		["Juice Seller"] = true,
		["Laptop Card Swipe"] = true,
		["Free Car"] = true,
	}

	local ICONS = Arsenic.ICONS or {
		mapPin = "rbxassetid://10734886004",
		map = "rbxassetid://10734886202",
		landmark = "rbxassetid://10723417608",
		briefcase = "rbxassetid://10709782662",
		building = "rbxassetid://10709783051",
		cart = "rbxassetid://10734952479",
		dollar = "rbxassetid://10723343958",
		users = "rbxassetid://10747373426",
		user = "rbxassetid://10747373176",
		navigation = "rbxassetid://10734906744",
		heart = "rbxassetid://10723406885",
		shieldAlert = "rbxassetid://10734951173",
		sword = "rbxassetid://10734975486",
	}

	local gui, cameraLock, renderConn, inputConn
	local markerHit = false

	local function worldToMapUV(position)
		local spanX = MAP_WORLD.maxX - MAP_WORLD.minX
		local spanZ = MAP_WORLD.maxZ - MAP_WORLD.minZ
		-- Match minimap v16 bake: west / minX on the left (not X-mirrored).
		local u = math.clamp((position.X - MAP_WORLD.minX) / spanX, 0, 1)
		local v = math.clamp((MAP_WORLD.maxZ - position.Z) / spanZ, 0, 1)
		return u, v
	end

	local function mapUVToWorld(u, v)
		local spanX = MAP_WORLD.maxX - MAP_WORLD.minX
		local spanZ = MAP_WORLD.maxZ - MAP_WORLD.minZ
		local x = MAP_WORLD.minX + u * spanX
		local z = MAP_WORLD.maxZ - v * spanZ
		local y = 255
		local gy = findGroundY(Vector3.new(x, 400, z), nil, 255)
		if gy then
			y = gy + 3
		end
		return Vector3.new(x, y, z)
	end

	local function getMinimapImage()
		local ensure = Features.Minimap and Features.Minimap._ensureAsset
		if type(ensure) == "function" then
			local ok, id = pcall(ensure)
			if ok and type(id) == "string" and id ~= "" then
				return id
			end
		end
		if typeof(getcustomasset) == "function" then
			for _, name in ipairs({ "Arsenic/minimap_v16.png", "Arsenic/minimap_v11.png", "Arsenic/minimap_generated.png" }) do
				local ok, id = pcall(getcustomasset, name)
				if ok and type(id) == "string" and id ~= "" then
					return id
				end
			end
		end
		return nil
	end

	local function unlockCamera()
		pcall(function()
			ContextActionService:UnbindAction(MAP_SINK)
		end)
		if cameraLock then
			pcall(function()
				LocalPlayer.CameraMinZoomDistance = cameraLock.minZoom
				LocalPlayer.CameraMaxZoomDistance = cameraLock.maxZoom
				UserInputService.MouseBehavior = cameraLock.mouseBehavior or Enum.MouseBehavior.Default
				UserInputService.MouseIconEnabled = cameraLock.mouseIcon ~= false
				if cameraLock.cameraMode ~= nil then
					LocalPlayer.CameraMode = cameraLock.cameraMode
				end
			end)
			cameraLock = nil
		end
	end

	local function lockCamera()
		if cameraLock then
			return
		end
		local camera = Workspace.CurrentCamera
		local zoom = 16
		if camera then
			zoom = math.clamp((camera.CFrame.Position - camera.Focus.Position).Magnitude, 0.5, 128)
		end
		cameraLock = {
			minZoom = LocalPlayer.CameraMinZoomDistance,
			maxZoom = LocalPlayer.CameraMaxZoomDistance,
			mouseBehavior = UserInputService.MouseBehavior,
			mouseIcon = UserInputService.MouseIconEnabled,
			cameraMode = LocalPlayer.CameraMode,
		}
		LocalPlayer.CameraMinZoomDistance = zoom
		LocalPlayer.CameraMaxZoomDistance = zoom
		pcall(function()
			LocalPlayer.CameraMode = Enum.CameraMode.Classic
		end)
		UserInputService.MouseBehavior = Enum.MouseBehavior.Default
		UserInputService.MouseIconEnabled = true
		ContextActionService:BindActionAtPriority(
			MAP_SINK,
			function(_, state)
				if state == Enum.UserInputState.Change or state == Enum.UserInputState.Begin then
					return Enum.ContextActionResult.Sink
				end
				return Enum.ContextActionResult.Pass
			end,
			false,
			Enum.ContextActionPriority.High.Value + 100,
			Enum.UserInputType.MouseWheel
		)
	end

	local function closeWorldMap()
		if renderConn then
			renderConn:Disconnect()
			renderConn = nil
		end
		if inputConn then
			inputConn:Disconnect()
			inputConn = nil
		end
		unlockCamera()
		if gui then
			gui:Destroy()
			gui = nil
		end
	end

	local function locationPlotPos(name, cf)
		local override = STREET_OVERRIDES[name]
		if override then
			return override
		end
		local pos = cf.Position
		if math.abs(pos.X) > 8000 or math.abs(pos.Z) > 8000 or math.abs(pos.Y) > 2000 then
			return nil
		end
		return pos
	end

	local function categorizeLocations()
		local landmarks, jobs, businesses = {}, {}, {}
		local list = Arsenic.Locations
		if type(list) ~= "table" then
			return landmarks, jobs, businesses
		end
		for _, entry in ipairs(list) do
			local name, cf = entry[1], entry[2]
			if type(name) == "string" and typeof(cf) == "CFrame" then
				local pos = locationPlotPos(name, cf)
				if pos then
					local item = { name = name, pos = pos, cf = cf }
					if JOB_NAMES[name] or string.find(name, " Job", 1, true) then
						table.insert(jobs, item)
					elseif BUSINESS_NAMES[name] then
						table.insert(businesses, item)
					else
						table.insert(landmarks, item)
					end
				end
			end
		end
		return landmarks, jobs, businesses
	end

	local function playerCharges(player)
		local charges = {}
		local hasWarrant = false
		pcall(function()
			hasWarrant = player:GetAttribute("HasWarrant") == true
			for attr, value in pairs(player:GetAttributes()) do
				if type(attr) == "string" and string.sub(attr, 1, 7) == "Charge_" and value == true then
					table.insert(charges, string.sub(attr, 8))
				end
			end
		end)
		table.sort(charges)
		return hasWarrant, charges
	end

	local function corner(parent, radius)
		local c = Instance.new("UICorner")
		c.CornerRadius = UDim.new(0, radius or 8)
		c.Parent = parent
		return c
	end

	local function openWorldMap(opts)
		opts = opts or {}
		closeWorldMap()
		local image = getMinimapImage()
		local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
		if not playerGui then
			notify("PlayerGui missing.")
			return
		end

		lockCamera()

		gui = Instance.new("ScreenGui")
		gui.Name = "ArsenicWorldMap"
		gui.IgnoreGuiInset = true
		gui.ResetOnSpawn = false
		gui.DisplayOrder = 125
		gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
		gui.Parent = playerGui

		-- Full-bleed dark canvas (GTA pause-map feel).
		local root = Instance.new("Frame")
		root.Name = "Root"
		root.Size = UDim2.fromScale(1, 1)
		root.BackgroundColor3 = Color3.fromRGB(12, 12, 12)
		root.BorderSizePixel = 0
		root.Active = true
		root.Parent = gui

		local mapFrame = Instance.new("Frame")
		mapFrame.Name = "MapFrame"
		mapFrame.Size = UDim2.fromScale(1, 1)
		mapFrame.BackgroundColor3 = Color3.fromRGB(18, 18, 18)
		mapFrame.BorderSizePixel = 0
		mapFrame.ClipsDescendants = true
		mapFrame.Active = true
		mapFrame.Parent = root

		local mapImage = Instance.new("ImageLabel")
		mapImage.Name = "Map"
		mapImage.BackgroundColor3 = Color3.fromRGB(18, 18, 18)
		mapImage.BackgroundTransparency = 0
		mapImage.BorderSizePixel = 0
		mapImage.AnchorPoint = Vector2.new(0.5, 0.5)
		mapImage.Position = UDim2.fromScale(0.5, 0.5)
		mapImage.Size = UDim2.fromScale(1, 1)
		mapImage.ScaleType = Enum.ScaleType.Stretch
		mapImage.Image = image or ""
		mapImage.ImageColor3 = Color3.fromRGB(200, 200, 200)
		mapImage.ClipsDescendants = true
		mapImage.Parent = mapFrame

		local markerLayer = Instance.new("Frame")
		markerLayer.BackgroundTransparency = 1
		markerLayer.Size = UDim2.fromScale(1, 1)
		markerLayer.ClipsDescendants = true
		markerLayer.ZIndex = 2
		markerLayer.Parent = mapImage

		local playerLayer = Instance.new("Frame")
		playerLayer.BackgroundTransparency = 1
		playerLayer.Size = UDim2.fromScale(1, 1)
		playerLayer.ClipsDescendants = true
		playerLayer.ZIndex = 4
		playerLayer.Parent = mapImage

		local pinLayer = Instance.new("Frame")
		pinLayer.BackgroundTransparency = 1
		pinLayer.Size = UDim2.fromScale(1, 1)
		pinLayer.ClipsDescendants = true
		pinLayer.ZIndex = 5
		pinLayer.Parent = mapImage

		-- Small center reticle only (full-screen crosshair looked like white lines on the bridge).
		local reticle = Instance.new("Frame")
		reticle.Name = "Reticle"
		reticle.BackgroundTransparency = 1
		reticle.AnchorPoint = Vector2.new(0.5, 0.5)
		reticle.Position = UDim2.fromScale(0.5, 0.5)
		reticle.Size = UDim2.fromOffset(28, 28)
		reticle.ZIndex = 10
		reticle.Active = false
		reticle.Parent = mapFrame
		local function makeCross(axis)
			local line = Instance.new("Frame")
			line.BorderSizePixel = 0
			line.BackgroundColor3 = Color3.fromRGB(245, 245, 245)
			line.BackgroundTransparency = 0.25
			line.Active = false
			line.ZIndex = 10
			line.AnchorPoint = Vector2.new(0.5, 0.5)
			line.Position = UDim2.fromScale(0.5, 0.5)
			if axis == "h" then
				line.Size = UDim2.fromOffset(28, 1)
			else
				line.Size = UDim2.fromOffset(1, 28)
			end
			line.Parent = reticle
		end
		makeCross("h")
		makeCross("v")
		local reticleDot = Instance.new("Frame")
		reticleDot.AnchorPoint = Vector2.new(0.5, 0.5)
		reticleDot.Position = UDim2.fromScale(0.5, 0.5)
		reticleDot.Size = UDim2.fromOffset(6, 6)
		reticleDot.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
		reticleDot.BackgroundTransparency = 0.1
		reticleDot.BorderSizePixel = 0
		reticleDot.Active = false
		reticleDot.ZIndex = 11
		reticleDot.Parent = reticle
		corner(reticleDot, 1)

		-- Right legend / filter list.
		local legend = Instance.new("Frame")
		legend.Name = "Legend"
		legend.AnchorPoint = Vector2.new(1, 0.5)
		legend.Position = UDim2.new(1, -18, 0.5, -20)
		legend.Size = UDim2.fromOffset(260, 420)
		legend.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
		legend.BackgroundTransparency = 0.35
		legend.BorderSizePixel = 0
		legend.ZIndex = 20
		legend.Parent = root

		local filterBar = Instance.new("Frame")
		filterBar.BackgroundTransparency = 1
		filterBar.Size = UDim2.new(1, -12, 0, 36)
		filterBar.Position = UDim2.fromOffset(6, 6)
		filterBar.ZIndex = 21
		filterBar.Parent = legend

		local filters = {
			jobs = true,
			homes = true,
			businesses = true,
			players = true,
		}
		if opts.focus == "homes" then
			filters.jobs = false
			filters.businesses = false
			filters.homes = true
		end

		local listScroll = Instance.new("ScrollingFrame")
		listScroll.Name = "BlipList"
		listScroll.BackgroundTransparency = 1
		listScroll.BorderSizePixel = 0
		listScroll.Position = UDim2.fromOffset(0, 46)
		listScroll.Size = UDim2.new(1, 0, 1, -78)
		listScroll.ScrollBarThickness = 3
		listScroll.ScrollBarImageColor3 = Color3.fromRGB(220, 220, 220)
		listScroll.CanvasSize = UDim2.fromOffset(0, 0)
		listScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
		listScroll.ZIndex = 21
		listScroll.Parent = legend
		local listLayout = Instance.new("UIListLayout")
		listLayout.SortOrder = Enum.SortOrder.LayoutOrder
		listLayout.Padding = UDim.new(0, 1)
		listLayout.Parent = listScroll

		local counter = Instance.new("TextLabel")
		counter.BackgroundTransparency = 1
		counter.AnchorPoint = Vector2.new(0.5, 1)
		counter.Position = UDim2.new(0.5, 0, 1, -8)
		counter.Size = UDim2.new(1, -16, 0, 20)
		counter.Font = Enum.Font.GothamBold
		counter.TextSize = 13
		counter.TextColor3 = Color3.fromRGB(230, 230, 230)
		counter.Text = "0/0"
		counter.ZIndex = 21
		counter.Parent = legend

		-- Detail card under legend (player / selection info).
		local detail = Instance.new("Frame")
		detail.Name = "Detail"
		detail.AnchorPoint = Vector2.new(1, 0)
		detail.Position = UDim2.new(1, -18, 0.5, 210)
		detail.Size = UDim2.fromOffset(260, 168)
		detail.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
		detail.BackgroundTransparency = 0.35
		detail.BorderSizePixel = 0
		detail.Visible = false
		detail.ZIndex = 20
		detail.Parent = root

		local infoTitle = Instance.new("TextLabel")
		infoTitle.BackgroundTransparency = 1
		infoTitle.Position = UDim2.fromOffset(10, 8)
		infoTitle.Size = UDim2.new(1, -20, 0, 20)
		infoTitle.Font = Enum.Font.GothamBold
		infoTitle.TextSize = 14
		infoTitle.TextXAlignment = Enum.TextXAlignment.Left
		infoTitle.TextColor3 = Color3.fromRGB(255, 255, 255)
		infoTitle.Text = ""
		infoTitle.ZIndex = 21
		infoTitle.Parent = detail

		local avatar = Instance.new("ImageLabel")
		avatar.Size = UDim2.fromOffset(56, 56)
		avatar.Position = UDim2.fromOffset(10, 34)
		avatar.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
		avatar.BorderSizePixel = 0
		avatar.ScaleType = Enum.ScaleType.Fit
		avatar.Visible = false
		avatar.ZIndex = 21
		avatar.Parent = detail
		corner(avatar, 4)

		local infoBody = Instance.new("TextLabel")
		infoBody.BackgroundTransparency = 1
		infoBody.Position = UDim2.fromOffset(10, 34)
		infoBody.Size = UDim2.new(1, -20, 0, 90)
		infoBody.Font = Enum.Font.Gotham
		infoBody.TextSize = 12
		infoBody.TextXAlignment = Enum.TextXAlignment.Left
		infoBody.TextYAlignment = Enum.TextYAlignment.Top
		infoBody.TextWrapped = true
		infoBody.TextColor3 = Color3.fromRGB(220, 220, 220)
		infoBody.Text = ""
		infoBody.ZIndex = 21
		infoBody.Parent = detail

		local healthBack = Instance.new("Frame")
		healthBack.Position = UDim2.fromOffset(10, 128)
		healthBack.Size = UDim2.new(1, -20, 0, 6)
		healthBack.BackgroundColor3 = Color3.fromRGB(40, 40, 40)
		healthBack.BorderSizePixel = 0
		healthBack.Visible = false
		healthBack.ZIndex = 21
		healthBack.Parent = detail
		local healthFill = Instance.new("Frame")
		healthFill.Size = UDim2.fromScale(1, 1)
		healthFill.BackgroundColor3 = Color3.fromRGB(80, 220, 120)
		healthFill.BorderSizePixel = 0
		healthFill.ZIndex = 22
		healthFill.Parent = healthBack

		-- Bottom-left scale + district.
		local placeBox = Instance.new("Frame")
		placeBox.AnchorPoint = Vector2.new(0, 1)
		placeBox.Position = UDim2.new(0, 18, 1, -52)
		placeBox.Size = UDim2.fromOffset(200, 44)
		placeBox.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
		placeBox.BackgroundTransparency = 0.35
		placeBox.BorderSizePixel = 0
		placeBox.ZIndex = 20
		placeBox.Parent = root
		local scaleLabel = Instance.new("TextLabel")
		scaleLabel.BackgroundTransparency = 1
		scaleLabel.Position = UDim2.fromOffset(8, 4)
		scaleLabel.Size = UDim2.new(1, -16, 0, 14)
		scaleLabel.Font = Enum.Font.Gotham
		scaleLabel.TextSize = 11
		scaleLabel.TextXAlignment = Enum.TextXAlignment.Left
		scaleLabel.TextColor3 = Color3.fromRGB(210, 210, 210)
		scaleLabel.Text = "0 — 200 studs"
		scaleLabel.ZIndex = 21
		scaleLabel.Parent = placeBox
		local placeLabel = Instance.new("TextLabel")
		placeLabel.BackgroundTransparency = 1
		placeLabel.Position = UDim2.fromOffset(8, 20)
		placeLabel.Size = UDim2.new(1, -16, 0, 18)
		placeLabel.Font = Enum.Font.GothamBold
		placeLabel.TextSize = 14
		placeLabel.TextXAlignment = Enum.TextXAlignment.Left
		placeLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
		placeLabel.Text = "MAP"
		placeLabel.ZIndex = 21
		placeLabel.Parent = placeBox

		-- Bottom prompt bar.
		local promptBar = Instance.new("Frame")
		promptBar.AnchorPoint = Vector2.new(0.5, 1)
		promptBar.Position = UDim2.new(0.5, 0, 1, 0)
		promptBar.Size = UDim2.new(1, 0, 0, 40)
		promptBar.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
		promptBar.BackgroundTransparency = 0.25
		promptBar.BorderSizePixel = 0
		promptBar.ZIndex = 25
		promptBar.Parent = root

		local function promptChip(text, x)
			local lbl = Instance.new("TextLabel")
			lbl.BackgroundTransparency = 1
			lbl.Position = UDim2.fromOffset(x, 0)
			lbl.Size = UDim2.fromOffset(160, 40)
			lbl.Font = Enum.Font.GothamMedium
			lbl.TextSize = 13
			lbl.TextXAlignment = Enum.TextXAlignment.Left
			lbl.TextColor3 = Color3.fromRGB(235, 235, 235)
			lbl.Text = text
			lbl.ZIndex = 26
			lbl.Parent = promptBar
			return lbl
		end
		promptChip("Scroll  Zoom", 24)
		promptChip("Click  Select / Pin", 170)
		promptChip("T  Teleport", 360)
		promptChip("B  Buy Home", 500)
		promptChip("M  Close", 640)

		local selected = nil
		local dropPin = nil
		local scale = 1
		local offset = Vector2.zero
		local dragging = false
		local dragStart, offsetStart
		local staticMarkers = {}
		local playerMarkers = {}
		local legendEntries = {}
		local legendIndex = 0
		local refreshStaticMarkers
		local refreshLegend
		local focusUV

		local function applyTransform()
			local base = mapFrame.AbsoluteSize
			if base.X < 2 or base.Y < 2 then
				return
			end
			local fitW, fitH = mapCoverSize(base)
			mapImage.Size = UDim2.fromOffset(math.floor(fitW * scale + 0.5), math.floor(fitH * scale + 0.5))
			mapImage.Position = UDim2.new(0.5, offset.X, 0.5, offset.Y)
			local studs = math.floor((MAP_WORLD.maxX - MAP_WORLD.minX) / (fitW * scale) * 120 + 0.5)
			scaleLabel.Text = ("0 — %d studs"):format(math.max(studs, 50))
		end

		local function zoomBy(delta)
			local old = scale
			-- Cover-fit at 1.0 fills the screen; allow well below that so the full
			-- tall map can shrink into view (previously clamped at 0.85 ≈ stuck zoomed in).
			scale = math.clamp(scale + delta, 0.18, 12)
			if scale ~= old then
				applyTransform()
			end
		end

		focusUV = function(u, v)
			local base = mapFrame.AbsoluteSize
			if base.X < 2 then
				return
			end
			local fitW, fitH = mapCoverSize(base)
			local dispW = fitW * scale
			local dispH = fitH * scale
			-- Image center is at viewport center + offset; place UV under the reticle.
			offset = Vector2.new(dispW * (0.5 - u), dispH * (0.5 - v))
			applyTransform()
		end

		local function setLegendHighlight(index)
			legendIndex = index
			for i, row in ipairs(legendEntries) do
				local on = i == index
				row.bg.BackgroundColor3 = on and Color3.fromRGB(245, 245, 245) or Color3.fromRGB(0, 0, 0)
				row.bg.BackgroundTransparency = on and 0 or 0.55
				row.label.TextColor3 = on and Color3.fromRGB(10, 10, 10) or Color3.fromRGB(235, 235, 235)
				row.icon.ImageColor3 = on and Color3.fromRGB(10, 10, 10) or Color3.fromRGB(235, 235, 235)
			end
			counter.Text = (#legendEntries == 0) and "0/0" or (("%d/%d"):format(math.max(index, 1), #legendEntries))
		end

		local function clearSelectionVisual()
			for _, m in ipairs(staticMarkers) do
				if m.btn and m.btn.Parent then
					m.btn.BackgroundTransparency = 0.15
				end
			end
		end

		local function showDetail(titleText, bodyText, showAvatar, avatarId, showHealth, hpFrac)
			detail.Visible = true
			infoTitle.Text = titleText
			infoBody.Text = bodyText
			if showAvatar then
				avatar.Visible = true
				avatar.Image = ("rbxthumb://type=Avatar&id=%d&w=150&h=150"):format(avatarId)
				infoBody.Position = UDim2.fromOffset(76, 34)
				infoBody.Size = UDim2.new(1, -86, 0, 90)
			else
				avatar.Visible = false
				infoBody.Position = UDim2.fromOffset(10, 34)
				infoBody.Size = UDim2.new(1, -20, 0, 90)
			end
			healthBack.Visible = showHealth == true
			if showHealth then
				healthFill.Size = UDim2.fromScale(math.clamp(hpFrac or 0, 0, 1), 1)
				healthFill.BackgroundColor3 = Color3.fromRGB(255, 60, 60):Lerp(Color3.fromRGB(60, 255, 90), hpFrac or 0)
			end
		end

		local function showLocationPanel(item)
			selected = { kind = "location", item = item }
			showDetail(item.name, string.format("%s\n%.0f, %.0f, %.0f", item.layer or "Location", item.pos.X, item.pos.Y, item.pos.Z), false)
		end

		local function showHomePanel(entry)
			selected = { kind = "home", entry = entry }
			showDetail(
				entry.t,
				string.format(
					"%s · %s\n%s\n%.0f, %.0f",
					entry.r,
					entry.priceText or ("$" .. tostring(entry.p)),
					entry.t,
					entry.x,
					entry.z
				),
				false
			)
		end

		local function showPlayerPanel(player)
			selected = { kind = "player", player = player }
			local character = player.Character
			local humanoid = character and character:FindFirstChildOfClass("Humanoid")
			local tool = character and character:FindFirstChildOfClass("Tool")
			local hp = humanoid and humanoid.Health or 0
			local maxHp = humanoid and math.max(humanoid.MaxHealth, 1) or 100
			local warrant, charges = playerCharges(player)
			local wantedLine = warrant and "WARRANT" or (#charges > 0 and "WANTED" or "Clear")
			local chargeText = #charges > 0 and table.concat(charges, ", ") or "None"
			local titleText = player.DisplayName ~= player.Name and (player.DisplayName .. " (@" .. player.Name .. ")") or player.Name
			showDetail(
				titleText,
				string.format(
					"@%s\nHeld: %s\n%s\nCharges: %s",
					player.Name,
					tool and tool.Name or "None",
					wantedLine,
					chargeText
				),
				true,
				player.UserId,
				true,
				hp / maxHp
			)
		end

		local function showPinPanel(worldPos)
			selected = { kind = "pin", pos = worldPos }
			showDetail("Waypoint", string.format("%.1f, %.1f, %.1f\nTeleport / clear with actions.", worldPos.X, worldPos.Y, worldPos.Z), false)
		end

		local function placeDropPin(u, v)
			local worldPos = mapUVToWorld(u, v)
			if dropPin then
				dropPin:Destroy()
			end
			dropPin = Instance.new("ImageLabel")
			dropPin.AnchorPoint = Vector2.new(0.5, 1)
			dropPin.Position = UDim2.fromScale(u, v)
			dropPin.Size = UDim2.fromOffset(22, 22)
			dropPin.BackgroundTransparency = 1
			dropPin.Image = ICONS.mapPin
			dropPin.ImageColor3 = Color3.fromRGB(255, 255, 255)
			dropPin.ZIndex = 6
			dropPin.Parent = pinLayer
			showPinPanel(worldPos)
		end

		local function addLegendRow(order, name, icon, color, onSelect)
			local bg = Instance.new("TextButton")
			bg.Name = "Row"
			bg.Size = UDim2.new(1, 0, 0, 28)
			bg.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
			bg.BackgroundTransparency = 0.55
			bg.BorderSizePixel = 0
			bg.AutoButtonColor = false
			bg.Text = ""
			bg.LayoutOrder = order
			bg.ZIndex = 22
			bg.Parent = listScroll
			local label = Instance.new("TextLabel")
			label.BackgroundTransparency = 1
			label.Position = UDim2.fromOffset(10, 0)
			label.Size = UDim2.new(1, -44, 1, 0)
			label.Font = Enum.Font.GothamMedium
			label.TextSize = 13
			label.TextXAlignment = Enum.TextXAlignment.Left
			label.TextTruncate = Enum.TextTruncate.AtEnd
			label.TextColor3 = Color3.fromRGB(235, 235, 235)
			label.Text = name
			label.ZIndex = 23
			label.Parent = bg
			local iconLbl = Instance.new("ImageLabel")
			iconLbl.AnchorPoint = Vector2.new(1, 0.5)
			iconLbl.Position = UDim2.new(1, -8, 0.5, 0)
			iconLbl.Size = UDim2.fromOffset(16, 16)
			iconLbl.BackgroundTransparency = 1
			iconLbl.Image = icon
			iconLbl.ImageColor3 = color or Color3.fromRGB(235, 235, 235)
			iconLbl.ScaleType = Enum.ScaleType.Fit
			iconLbl.ZIndex = 23
			iconLbl.Parent = bg
			local entry = { bg = bg, label = label, icon = iconLbl, onSelect = onSelect }
			table.insert(legendEntries, entry)
			local index = #legendEntries
			bg.MouseButton1Click:Connect(function()
				markerHit = true
				setLegendHighlight(index)
				onSelect()
				task.defer(function()
					markerHit = false
				end)
			end)
		end

		refreshLegend = function()
			for _, row in ipairs(legendEntries) do
				row.bg:Destroy()
			end
			legendEntries = {}
			local order = 0
			local function push(name, icon, color, u, v, selectFn)
				order += 1
				addLegendRow(order, name, icon, color, function()
					focusUV(u, v)
					selectFn()
				end)
			end
			local landmarks, jobs, businesses = categorizeLocations()
			for _, item in ipairs(landmarks) do
				item.layer = "Location"
				local u, v = worldToMapUV(item.pos)
				push(item.name, ICONS.landmark, Color3.fromRGB(200, 210, 255), u, v, function()
					showLocationPanel(item)
				end)
			end
			if filters.jobs then
				for _, item in ipairs(jobs) do
					item.layer = "Job"
					local u, v = worldToMapUV(item.pos)
					push(item.name, ICONS.briefcase, Color3.fromRGB(255, 200, 120), u, v, function()
						showLocationPanel(item)
					end)
				end
			end
			if filters.businesses then
				for _, item in ipairs(businesses) do
					item.layer = "Business"
					local u, v = worldToMapUV(item.pos)
					push(item.name, ICONS.cart, Color3.fromRGB(120, 220, 160), u, v, function()
						showLocationPanel(item)
					end)
				end
			end
			if filters.homes then
				local catalog = Arsenic.Homes and Arsenic.Homes.catalog
				if type(catalog) == "table" then
					for _, entry in ipairs(catalog) do
						local u, v = worldToMapUV(Vector3.new(entry.x, entry.y, entry.z))
						local name = ("%s · %s"):format(entry.t, entry.r)
						push(name, ICONS.building, Color3.fromRGB(255, 220, 90), u, v, function()
							showHomePanel(entry)
						end)
					end
				end
			end
			if filters.players then
				for _, player in ipairs(Players:GetPlayers()) do
					if player ~= LocalPlayer then
						local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
						if root then
							local u, v = worldToMapUV(root.Position)
							local p = player
							push(player.DisplayName, ICONS.user, Color3.fromRGB(120, 190, 255), u, v, function()
								showPlayerPanel(p)
							end)
						end
					end
				end
			end
			setLegendHighlight(legendIndex > 0 and math.min(legendIndex, #legendEntries) or 0)
		end

		refreshStaticMarkers = function()
			for _, m in ipairs(staticMarkers) do
				if m.btn then
					m.btn:Destroy()
				end
			end
			staticMarkers = {}

			local function addMarker(u, v, color, icon, onClick)
				local btn = Instance.new("ImageButton")
				btn.AnchorPoint = Vector2.new(0.5, 0.5)
				btn.Position = UDim2.fromScale(u, v)
				btn.Size = UDim2.fromOffset(18, 18)
				btn.BackgroundColor3 = color
				btn.BackgroundTransparency = 0.15
				btn.Image = icon or ""
				btn.ImageColor3 = Color3.fromRGB(15, 15, 15)
				btn.ScaleType = Enum.ScaleType.Fit
				btn.ZIndex = 3
				btn.Parent = markerLayer
				corner(btn, 3)
				local stroke = Instance.new("UIStroke")
				stroke.Thickness = 1
				stroke.Color = Color3.fromRGB(255, 255, 255)
				stroke.Transparency = 0.35
				stroke.Parent = btn
				btn.MouseButton1Click:Connect(function()
					markerHit = true
					clearSelectionVisual()
					btn.BackgroundTransparency = 0
					onClick()
					task.defer(function()
						markerHit = false
					end)
				end)
				table.insert(staticMarkers, { btn = btn, baseColor = color })
			end

			local landmarks, jobs, businesses = categorizeLocations()
			for _, item in ipairs(landmarks) do
				item.layer = "Location"
				local u, v = worldToMapUV(item.pos)
				addMarker(u, v, Color3.fromRGB(180, 200, 255), ICONS.landmark, function()
					showLocationPanel(item)
				end)
			end
			if filters.jobs then
				for _, item in ipairs(jobs) do
					item.layer = "Job"
					local u, v = worldToMapUV(item.pos)
					addMarker(u, v, Color3.fromRGB(255, 200, 120), ICONS.briefcase, function()
						showLocationPanel(item)
					end)
				end
			end
			if filters.businesses then
				for _, item in ipairs(businesses) do
					item.layer = "Business"
					local u, v = worldToMapUV(item.pos)
					addMarker(u, v, Color3.fromRGB(120, 220, 160), ICONS.cart, function()
						showLocationPanel(item)
					end)
				end
			end
			if filters.homes then
				local catalog = Arsenic.Homes and Arsenic.Homes.catalog
				if type(catalog) == "table" then
					for _, entry in ipairs(catalog) do
						local u, v = worldToMapUV(Vector3.new(entry.x, entry.y, entry.z))
						addMarker(u, v, Color3.fromRGB(255, 220, 90), ICONS.building, function()
							showHomePanel(entry)
						end)
					end
				end
			end
			refreshLegend()
		end

		local function makeFilter(order, icon, key)
			local btn = Instance.new("ImageButton")
			btn.Size = UDim2.fromOffset(28, 28)
			btn.Position = UDim2.fromOffset((order - 1) * 34, 4)
			btn.BackgroundColor3 = filters[key] and Color3.fromRGB(245, 245, 245) or Color3.fromRGB(40, 40, 40)
			btn.Image = icon
			btn.ImageColor3 = filters[key] and Color3.fromRGB(10, 10, 10) or Color3.fromRGB(210, 210, 210)
			btn.ScaleType = Enum.ScaleType.Fit
			btn.ZIndex = 22
			btn.Parent = filterBar
			corner(btn, 4)
			btn.MouseButton1Click:Connect(function()
				filters[key] = not filters[key]
				btn.BackgroundColor3 = filters[key] and Color3.fromRGB(245, 245, 245) or Color3.fromRGB(40, 40, 40)
				btn.ImageColor3 = filters[key] and Color3.fromRGB(10, 10, 10) or Color3.fromRGB(210, 210, 210)
				refreshStaticMarkers()
			end)
		end
		makeFilter(1, ICONS.briefcase, "jobs")
		makeFilter(2, ICONS.building, "homes")
		makeFilter(3, ICONS.cart, "businesses")
		makeFilter(4, ICONS.users, "players")

		local function syncPlayers()
			local seen = {}
			for _, player in ipairs(Players:GetPlayers()) do
				if player ~= LocalPlayer then
					local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
					if root and root:IsA("BasePart") then
						seen[player] = true
						local u, v = worldToMapUV(root.Position)
						local pack = playerMarkers[player]
						if not pack then
							local btn = Instance.new("TextButton")
							btn.AnchorPoint = Vector2.new(0.5, 0.5)
							btn.Size = UDim2.fromOffset(10, 10)
							btn.BackgroundColor3 = Color3.fromRGB(120, 190, 255)
							btn.Text = ""
							btn.ZIndex = 5
							btn.Parent = playerLayer
							corner(btn, 1)
							local label = Instance.new("TextLabel")
							label.BackgroundTransparency = 1
							label.AnchorPoint = Vector2.new(0.5, 1)
							label.Position = UDim2.new(0.5, 0, 0, -2)
							label.Size = UDim2.fromOffset(120, 14)
							label.Font = Enum.Font.GothamBold
							label.TextSize = 11
							label.TextColor3 = Color3.new(1, 1, 1)
							label.TextStrokeTransparency = 0.35
							label.Text = player.DisplayName
							label.ZIndex = 6
							label.Parent = btn
							local p = player
							btn.MouseButton1Click:Connect(function()
								markerHit = true
								showPlayerPanel(p)
								task.defer(function()
									markerHit = false
								end)
							end)
							pack = { btn = btn, label = label }
							playerMarkers[player] = pack
						end
						pack.btn.Position = UDim2.fromScale(u, v)
						pack.label.Text = player.DisplayName
						-- Only show when the blip center is on-screen (mapFrame clips the rest).
						local show = filters.players ~= false
						if show then
							local abs = mapFrame.AbsolutePosition
							local size = mapFrame.AbsoluteSize
							local btnAbs = pack.btn.AbsolutePosition
							local btnSize = pack.btn.AbsoluteSize
							local cx = btnAbs.X + btnSize.X * 0.5
							local cy = btnAbs.Y + btnSize.Y * 0.5
							show = cx >= abs.X and cx <= abs.X + size.X and cy >= abs.Y and cy <= abs.Y + size.Y
						end
						pack.btn.Visible = show
						if selected and selected.kind == "player" and selected.player == player then
							showPlayerPanel(player)
						end
					end
				end
			end
			for player, pack in pairs(playerMarkers) do
				if not seen[player] then
					pack.btn:Destroy()
					playerMarkers[player] = nil
				end
			end
		end

		applyTransform()
		refreshStaticMarkers()

		-- Center on local player once AbsoluteSize is valid.
		task.defer(function()
			applyTransform()
			local rootPart = getRoot()
			if rootPart then
				local u, v = worldToMapUV(rootPart.Position)
				focusUV(u, v)
				local label = Arsenic.GetLocationLabel and Arsenic.GetLocationLabel(rootPart.Position)
				placeLabel.Text = (type(label) == "string" and label ~= "" and label ~= "Unknown") and string.upper(label) or "NEAR YOU"
			end
		end)

		mapFrame.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
				dragging = true
				dragStart = Vector2.new(input.Position.X, input.Position.Y)
				offsetStart = offset
			end
		end)
		mapFrame.InputEnded:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
				local moved = dragStart and (Vector2.new(input.Position.X, input.Position.Y) - dragStart).Magnitude or 0
				dragging = false
				if moved < 6 and not markerHit then
					local abs = mapImage.AbsolutePosition
					local size = mapImage.AbsoluteSize
					if size.X > 1 and size.Y > 1 then
						local u = (input.Position.X - abs.X) / size.X
						local v = (input.Position.Y - abs.Y) / size.Y
						if u >= 0 and u <= 1 and v >= 0 and v <= 1 then
							placeDropPin(u, v)
						end
					end
				end
			end
		end)
		mapFrame.MouseWheelForward:Connect(function()
			zoomBy(0.18)
		end)
		mapFrame.MouseWheelBackward:Connect(function()
			zoomBy(-0.18)
		end)

		if inputConn then
			inputConn:Disconnect()
		end
		inputConn = UserInputService.InputChanged:Connect(function(input)
			if not gui then
				return
			end
			if UserInputService.MouseBehavior ~= Enum.MouseBehavior.Default then
				UserInputService.MouseBehavior = Enum.MouseBehavior.Default
			end
			if not UserInputService.MouseIconEnabled then
				UserInputService.MouseIconEnabled = true
			end
			if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
				local delta = Vector2.new(input.Position.X, input.Position.Y) - dragStart
				offset = offsetStart + delta
				applyTransform()
			elseif input.UserInputType == Enum.UserInputType.MouseWheel then
				local z = input.Position.Z
				if z ~= 0 then
					zoomBy(z * 0.12)
				end
			end
		end)

		local function doTeleport()
			if not selected then
				notify("Select a blip or drop a pin first.")
				return
			end
			local sel = selected
			closeWorldMap()
			runPlayerAction(function()
				if sel.kind == "player" and sel.player and sel.player.Parent then
					local rootPart = sel.player.Character and sel.player.Character:FindFirstChild("HumanoidRootPart")
					if rootPart then
						teleportCharacter(function()
							return rootPart.Parent and behind(rootPart, 3) or nil
						end)
					else
						notify("Player has no character.")
					end
				elseif sel.kind == "home" and sel.entry then
					local e = sel.entry
					if Arsenic.Homes and Arsenic.Homes.teleportToHomeAt then
						Arsenic.Homes.teleportToHomeAt(Vector3.new(e.x, e.y, e.z), e.t)
					else
						teleportOnFoot(CFrame.new(e.x, e.y, e.z))
					end
				elseif sel.kind == "location" and sel.item then
					teleportOnFoot(sel.item.cf or CFrame.new(sel.item.pos))
				elseif sel.kind == "pin" and sel.pos then
					local humanoid, rootPart = getHumanoid(), getRoot()
					local lift = (humanoid and rootPart and getStandHeight(humanoid, rootPart)) or 3
					local gy = findGroundY(sel.pos + Vector3.new(0, 20, 0), nil, sel.pos.Y)
					local y = (gy or sel.pos.Y) + lift
					teleportOnFoot(CFrame.new(sel.pos.X, y, sel.pos.Z))
				end
			end)
		end

		local function doBuy()
			if not (selected and selected.kind == "home" and selected.entry) then
				notify("Select a home blip first.")
				return
			end
			local e = selected.entry
			closeWorldMap()
			runPlayerAction(function()
				if Arsenic.Homes and Arsenic.Homes.buyHomeAt then
					Arsenic.Homes.buyHomeAt(Vector3.new(e.x, e.y, e.z), e.t)
				end
			end)
		end

		local keyConn
		keyConn = UserInputService.InputBegan:Connect(function(input, processed)
			if processed or not gui then
				return
			end
			if input.KeyCode == Enum.KeyCode.M then
				closeWorldMap()
			elseif input.KeyCode == Enum.KeyCode.T then
				doTeleport()
			elseif input.KeyCode == Enum.KeyCode.B then
				doBuy()
			elseif input.KeyCode == Enum.KeyCode.Up then
				if #legendEntries > 0 then
					local i = legendIndex <= 1 and #legendEntries or (legendIndex - 1)
					setLegendHighlight(i)
					legendEntries[i].onSelect()
				end
			elseif input.KeyCode == Enum.KeyCode.Down then
				if #legendEntries > 0 then
					local i = legendIndex >= #legendEntries and 1 or (legendIndex + 1)
					setLegendHighlight(i)
					legendEntries[i].onSelect()
				end
			end
		end)
		gui.Destroying:Connect(function()
			pcall(function()
				keyConn:Disconnect()
			end)
		end)

		mapFrame:GetPropertyChangedSignal("AbsoluteSize"):Connect(applyTransform)

		if renderConn then
			renderConn:Disconnect()
		end
		renderConn = RunService.RenderStepped:Connect(function()
			if Arsenic.Destroyed or not gui then
				return
			end
			syncPlayers()
			-- District under reticle.
			local abs = mapImage.AbsolutePosition
			local size = mapImage.AbsoluteSize
			local frameAbs = mapFrame.AbsolutePosition
			local frameSize = mapFrame.AbsoluteSize
			if size.X > 1 and size.Y > 1 then
				local cx = frameAbs.X + frameSize.X * 0.5
				local cy = frameAbs.Y + frameSize.Y * 0.5
				local u = (cx - abs.X) / size.X
				local v = (cy - abs.Y) / size.Y
				if u >= 0 and u <= 1 and v >= 0 and v <= 1 then
					local world = mapUVToWorld(u, v)
					local list = Arsenic.Locations
					local best, bestDist = "OPEN WORLD", 180
					if type(list) == "table" then
						for _, entry in ipairs(list) do
							local name, cf = entry[1], entry[2]
							if type(name) == "string" and typeof(cf) == "CFrame" then
								local pos = locationPlotPos(name, cf)
								if pos then
									local d = (Vector3.new(pos.X, 0, pos.Z) - Vector3.new(world.X, 0, world.Z)).Magnitude
									if d < bestDist then
										bestDist = d
										best = name
									end
								end
							end
						end
					end
					placeLabel.Text = string.upper(best)
				end
			end
		end)

		if not image then
			showDetail("Map", "Enable Minimap once to cache the map image. Blips still work.", false)
		end
		notify("World map opened.")
	end

	Arsenic.WorldMap = {
		open = openWorldMap,
		close = closeWorldMap,
	}

	table.insert(Arsenic.Cleanup, closeWorldMap)
end)()

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

	-- Camera -----------------------------------------------------------------------

	local CameraTab = Window:CreateTab({ name = "Camera", icon = ICONS.camera })

	CameraTab:CreateInput({
		name = "FOV",
		description = "Increase/decrease field of view past limit (96).",
		icon = ICONS.eye,
		flag = "Camera_FOV",
		placeholder = "96",
		numeric = true,
		callback = function(text)
			local fov = tonumber(text)
			Arsenic.Values.FOV = fov and math.clamp(fov, 1, 120) or 96
		end,
	})

	CameraTab:CreateDropdown({
		name = "Camera Mode",
		description = "How the camera should look when on foot. Bodycam attaches to the torso; Helmet Cam attaches to the right side of the head. Both use a wide fisheye-style FOV.",
		icon = ICONS.camera,
		options = { "Regular Camera", "Bodycam", "Helmet Cam" },
		value = Arsenic.Values.CameraMode or "Regular Camera",
		flag = "Camera_Mode",
		callback = function(selection)
			if type(selection) == "table" then
				selection = selection[1]
			end
			if selection == "Bodycam" or selection == "Helmet Cam" then
				Arsenic.Values.CameraMode = selection
			else
				Arsenic.Values.CameraMode = "Regular Camera"
			end
		end,
	})

	CameraTab:CreateToggle({
		name = "Freecam",
		description = "Move the camera anywhere in the world (WASD, Space/E up, Ctrl/Q down, mouse look).",
		icon = ICONS.move,
		flag = "Camera_Freecam",
		value = false,
		callback = function(value)
			setFeature("Freecam", value)
		end,
	})

	CameraTab:CreateToggle({
		name = "Make ESP Follow Freecam",
		description = "Makes ESP follow the freecam instead of your player so you can see players in the camera's stud radius and not the player radius.",
		icon = ICONS.eye,
		flag = "Camera_ESPFollowFreecam",
		value = Arsenic.Values.ESPFollowFreecam == true,
		callback = function(value)
			Arsenic.Values.ESPFollowFreecam = value == true
		end,
	})

	CameraTab:CreateInput({
		name = "Freecam Speed",
		description = "How fast the camera should move in freecam.",
		icon = ICONS.gauge,
		flag = "Camera_FreecamSpeed",
		placeholder = "60",
		numeric = true,
		callback = function(text)
			local speed = tonumber(text)
			Arsenic.Values.FreecamSpeed = speed and math.max(speed, 1) or 60
		end,
	})

	CameraTab:CreateInput({
		name = "Freecam Boost Keybind",
		description = "Key held to use Freecam Boost Speed (e.g. LeftShift, LeftControl, Q).",
		icon = ICONS.key,
		flag = "Camera_FreecamBoostKey",
		placeholder = "LeftShift",
		callback = function(text)
			local name = tostring(text or ""):gsub("%s+", "")
			Arsenic.Values.FreecamBoostKey = name ~= "" and name or "LeftShift"
		end,
	})

	CameraTab:CreateInput({
		name = "Freecam Boost Speed",
		description = "How fast the freecam should move when using the speed boost keybind.",
		icon = ICONS.fastForward,
		flag = "Camera_FreecamBoostSpeed",
		placeholder = "160",
		numeric = true,
		callback = function(text)
			local speed = tonumber(text)
			Arsenic.Values.FreecamBoostSpeed = speed and math.max(speed, 1) or 160
		end,
	})

	CameraTab:CreateInput({
		name = "Freecam Smoothing",
		description = "Smoothness of the camera's movements in freecam (0 = none, closer to 1 = smoother/slower).",
		icon = ICONS.feather,
		flag = "Camera_FreecamSmoothing",
		placeholder = "0.15",
		numeric = true,
		callback = function(text)
			local value = tonumber(text)
			Arsenic.Values.FreecamSmoothing = value and math.clamp(value, 0, 0.95) or 0.15
		end,
	})

	-- Settings (bottom) ------------------------------------------------------------

	local SettingsTab = Window:CreateTab({ name = "Settings", icon = ICONS.wrench })

	SettingsTab:CreateSection({ name = "Teleport", icon = ICONS.navigation })

	SettingsTab:CreateDropdown({
		name = "Teleport Method",
		description = "Instant: almost immediate CFrame teleport. Tween: seated Seat glide. "
			.. "Vehicle: borrow a car. Car + Tween: drive most of the way, then seated finish.",
		icon = ICONS.navigation2,
		options = { "Instant", "Tween", "Vehicle", "Car + Tween" },
		value = "Instant",
		flag = "Settings_TeleportMethodV4",
		callback = function(selection)
			if type(selection) == "table" then
				selection = selection[1]
			end
			if selection == "Tween" or selection == "Vehicle" or selection == "Car + Tween" then
				teleportMethod = selection
			else
				teleportMethod = "Instant"
			end
		end,
	})

	teleportSpeedSlider = SettingsTab:CreateSlider({
		name = "Teleport Speed",
		description = "Top speed of seated Seat tweens (and Car + Tween finish).",
		icon = ICONS.gauge,
		range = { MIN_TELEPORT_SPEED, 6000 },
		increment = 50,
		value = Arsenic.Values.TeleportSpeed,
		suffix = " studs/s",
		flag = "Settings_TeleportSpeedV6",
		callback = function(value)
			Arsenic.Values.TeleportSpeed = value
		end,
	})

	SettingsTab:CreateSlider({
		name = "Tween After Car",
		description = "Car + Tween only: how many studs before the destination you get out and finish on foot/seat.",
		icon = ICONS.ruler,
		range = { 0, 2000 },
		increment = 10,
		value = Arsenic.Values.TweenAfterCar,
		suffix = " studs",
		flag = "Settings_TweenAfterCar",
		callback = function(value)
			Arsenic.Values.TweenAfterCar = value
		end,
	})

	SettingsTab:CreateSlider({
		name = "Car Teleport Speed",
		description = "How fast the car travels during Vehicle teleports.",
		icon = ICONS.fastForward,
		range = { 500, 10000 },
		increment = 100,
		value = Arsenic.Values.CarTeleportSpeed,
		suffix = " studs/s",
		flag = "Settings_CarTeleportSpeed",
		callback = function(value)
			Arsenic.Values.CarTeleportSpeed = value
		end,
	})

	SettingsTab:CreateSlider({
		name = "Car Exit Delay",
		description = "How long Vehicle teleports wait in the car at the destination before getting out.",
		icon = ICONS.timer,
		range = { 0, 3 },
		increment = 0.05,
		value = Arsenic.Values.CarExitDelay,
		suffix = "s",
		flag = "Settings_CarExitDelay",
		callback = function(value)
			Arsenic.Values.CarExitDelay = value
		end,
	})

	SettingsTab:CreateSection({ name = "Dupe", icon = ICONS.repeatIcon })

	SettingsTab:CreateDropdown({
		name = "Timing Bias",
		description = "Shift the List→Store race earlier or later if your ping timing misses.",
		icon = ICONS.fastForward,
		options = { "Early", "Normal", "Late" },
		value = Arsenic.Values.DupeTiming,
		flag = "Settings_DupeTimingBias",
		callback = function(selection)
			Arsenic.Values.DupeTiming = selection
		end,
	})

	SettingsTab:CreateToggle({
		name = "Use Ping Delay",
		description = "Scale the List→Store delay from your ping. Off uses Manual Delay instead.",
		icon = ICONS.activity,
		flag = "Settings_DupeUsePing",
		value = Arsenic.Values.DupeUsePing ~= false,
		callback = function(value)
			Arsenic.Values.DupeUsePing = value
		end,
	})

	SettingsTab:CreateSlider({
		name = "Manual Delay",
		description = "List→Store wait when Use Ping Delay is off.",
		icon = ICONS.timer,
		range = { 0.05, 0.8 },
		increment = 0.01,
		value = Arsenic.Values.DupeManualDelay,
		suffix = "s",
		flag = "Settings_DupeManualDelay",
		callback = function(value)
			Arsenic.Values.DupeManualDelay = value
		end,
	})

	SettingsTab:CreateSlider({
		name = "Store Delay Offset",
		description = "Extra time added on top of the calculated List→Store delay.",
		icon = ICONS.gauge,
		range = { -0.1, 0.2 },
		increment = 0.01,
		value = Arsenic.Values.DupeStoreDelayOffset,
		suffix = "s",
		flag = "Settings_DupeStoreDelayOffset",
		callback = function(value)
			Arsenic.Values.DupeStoreDelayOffset = value
		end,
	})

	SettingsTab:CreateSlider({
		name = "Backpack Wait",
		description = "How long the tool sits in the backpack before List.",
		icon = ICONS.backpack,
		range = { 0.1, 2 },
		increment = 0.05,
		value = Arsenic.Values.DupeBackpackWait,
		suffix = "s",
		flag = "Settings_DupeBackpackWait",
		callback = function(value)
			Arsenic.Values.DupeBackpackWait = value
		end,
	})

	SettingsTab:CreateSlider({
		name = "Remove Wait",
		description = "Wait after Store before Remove listing.",
		icon = ICONS.timer,
		range = { 0.5, 5 },
		increment = 0.1,
		value = Arsenic.Values.DupeRemoveWait,
		suffix = "s",
		flag = "Settings_DupeRemoveWait",
		callback = function(value)
			Arsenic.Values.DupeRemoveWait = value
		end,
	})

	SettingsTab:CreateSlider({
		name = "Finish Wait",
		description = "Wait after Grab before counting results.",
		icon = ICONS.timer,
		range = { 0.2, 3 },
		increment = 0.1,
		value = Arsenic.Values.DupeFinishWait,
		suffix = "s",
		flag = "Settings_DupeFinishWait",
		callback = function(value)
			Arsenic.Values.DupeFinishWait = value
		end,
	})

	SettingsTab:CreateToggle({
		name = "Park Extras Between Attempts",
		description = "Auto Dupe banks spare copies between attempts. Turning Auto Dupe off pulls them back.",
		icon = ICONS.bag,
		flag = "Settings_DupeParkExtras",
		value = Arsenic.Values.DupeParkExtras ~= false,
		callback = function(value)
			Arsenic.Values.DupeParkExtras = value
		end,
	})

	SettingsTab:CreateToggle({
		name = "Re-equip After Dupe",
		description = "Equip a copy again when a dupe succeeds.",
		icon = ICONS.hand,
		flag = "Settings_DupeReequip",
		value = Arsenic.Values.DupeReequip ~= false,
		callback = function(value)
			Arsenic.Values.DupeReequip = value
		end,
	})

	SettingsTab:CreateInput({
		name = "List Price",
		description = "Price used when listing the item on the market for the race.",
		icon = ICONS.dollar,
		placeholder = "99999",
		flag = "Settings_DupeListPrice",
		callback = function(text)
			local amount = tonumber((tostring(text or ""):gsub("[^%d%-%.]", "")))
			if amount then
				Arsenic.Values.DupeListPrice = math.clamp(math.floor(amount), 1, 999999999)
			end
		end,
	})

	SettingsTab:CreateSlider({
		name = "Auto Dupe Interval",
		description = "Seconds to wait between Auto Dupe attempts.",
		icon = ICONS.timer,
		range = { 0.5, 15 },
		increment = 0.5,
		value = Arsenic.Values.DupeInterval,
		suffix = "s",
		flag = "Settings_DupeInterval",
		callback = function(value)
			Arsenic.Values.DupeInterval = value
		end,
	})

	SettingsTab:CreateSection({ name = "ESP", icon = ICONS.eye })

	SettingsTab:CreateDropdown({
		name = "Measurement System",
		description = "Units used for vehicle speed ESP (mph / km/h / studs/s).",
		icon = ICONS.ruler,
		options = { "Imperial", "Metric", "Studs" },
		value = Arsenic.Values.SpeedUnit or "Imperial",
		flag = "Settings_SpeedUnit",
		callback = function(selection)
			if type(selection) == "table" then
				selection = selection[1]
			end
			if selection == "Metric" or selection == "Studs" then
				Arsenic.Values.SpeedUnit = selection
			else
				Arsenic.Values.SpeedUnit = "Imperial"
			end
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
