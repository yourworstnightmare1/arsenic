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

local killPlayer, ragdollPlayer
do
	local losParams = RaycastParams.new()
	losParams.FilterType = Enum.RaycastFilterType.Exclude
	losParams.IgnoreWater = true

	local function hasLineOfSight(origin, target, ignore)
		losParams.FilterDescendantsInstances = ignore
		return Workspace:Raycast(origin, target - origin, losParams) == nil
	end

	local function findShootSpot(targetRoot, aimPart, ignore)
		for _, radius in ipairs({ 5, 8, 3, 12 }) do
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
		return behind(targetRoot, 4)
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

	local function fireInflict(inflict, tool, targetHumanoid, targetRoot, hitPart, damage, settings, origin)
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
				nil,
				nil,
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
			(hitPart.Position - origin).Unit,
		}
		if inflict:IsA("RemoteFunction") then
			return pcall(function()
				inflict:InvokeServer(table.unpack(payload))
			end)
		end
		return pcall(function()
			inflict:FireServer(table.unpack(payload))
		end)
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
		if not (inflict or fire) then
			notify("Could not find this gun's damage remote.")
			return
		end

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

		local settings = getGunSettings(tool) or {}
		local base = tonumber(settings.BaseDamage) or 25
		local mult = tonumber(settings.HeadshotDamageMultiplier) or 7
		local headEnabled = settings.HeadshotEnabled ~= false
		local damage = mode == "kill" and (headEnabled and base * mult or base) or base
		local shotDelay = math.max(tonumber(settings.FireRate) or 0.1, 0.05)
		local maxShots = mode == "kill" and 40 or 6
		local maxTime = mode == "kill" and 8 or 3

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
			notify("Could not reach " .. player.Name .. ".")
			teleportCharacter(returnCFrame)
			return
		end

		local shots = 0
		local deadline = os.clock() + maxTime
		while os.clock() < deadline and shots < maxShots and not Arsenic.Destroyed do
			root = getRoot()
			character = getCharacter()
			targetCharacter = player.Character
			targetHumanoid = targetCharacter and targetCharacter:FindFirstChildOfClass("Humanoid")
			targetRoot = targetCharacter and targetCharacter:FindFirstChild("HumanoidRootPart")
			aimPart = targetCharacter and findBodyPart(targetCharacter, aimNames)
			if not (root and character and targetHumanoid and targetRoot and aimPart) then
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
			if (aimPart.Position - origin).Magnitude > 14 or not hasLineOfSight(origin, aimPart.Position, ignore) then
				teleportCharacter(findShootSpot(targetRoot, aimPart, ignore))
				RunService.Heartbeat:Wait()
				origin = firePoint.WorldPosition
				root = getRoot()
				if root and targetRoot then
					root.CFrame = CFrame.lookAt(
						root.Position,
						Vector3.new(targetRoot.Position.X, root.Position.Y, targetRoot.Position.Z)
					)
				end
			elseif root and targetRoot then
				root.CFrame = CFrame.lookAt(
					root.Position,
					Vector3.new(targetRoot.Position.X, root.Position.Y, targetRoot.Position.Z)
				)
			end

			if fire then
				pcall(fire, handle, aimPart.Position)
			end
			if inflict then
				fireInflict(inflict, tool, targetHumanoid, targetRoot, aimPart, damage, settings, origin)
			end
			shots += 1
			task.wait(shotDelay)
		end

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

	killPlayer = function()
		shootPlayer("kill")
	end
	ragdollPlayer = function()
		shootPlayer("ragdoll")
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

	local function isLaundryBagTool(tool)
		if not tool or not tool:IsA("Tool") then
			return false
		end
		local name = tool.Name:lower()
		if name == "fist" or name == "fists" or name == "phone" or name == "bread" then
			return false
		end
		-- After Grab Cash the game gives MoneyReady (cash stack), not always a duffle.
		return name == "moneyready"
			or name:find("moneyready", 1, true) ~= nil
			or name:find("bag", 1, true) ~= nil
			or name == "counterbag"
			or name == "dufflebag"
			or name == "duffelbag"
			or (name:find("money", 1, true) ~= nil and name:find("gun", 1, true) == nil)
	end

	local function isLaundryCollectPrompt(prompt)
		if not (prompt and prompt:IsA("ProximityPrompt") and prompt.Enabled) then
			return false
		end
		local action = (prompt.ActionText or ""):lower()
		local object = (prompt.ObjectText or ""):lower()
		local combined = action .. " " .. object
		-- Same CashPrompt instance often swaps from "Count Money" → "Grab Cash".
		if combined:find("count money", 1, true) or combined:find("count bread", 1, true) then
			return false
		end
		-- On-screen: "[E] Grab Cash" / "Counter". Also GrabPrompt: "Put Cash In".
		return combined:find("grab", 1, true) ~= nil
			or combined:find("pick", 1, true) ~= nil
			or combined:find("duffle", 1, true) ~= nil
			or combined:find("put cash", 1, true) ~= nil
			or (object:find("cash", 1, true) ~= nil and object:find("count", 1, true) == nil)
			or (object:find("bag", 1, true) ~= nil)
	end

	-- Prefer enabled collect prompts (Grab Cash Counter). Do NOT return the disabled
	-- GrabPrompt ("Put Cash In") early — that blocked finding the real grab.
	local function findLaundryCollectPrompts(counterPrompt)
		local found = {}
		local seen = {}
		local function add(prompt)
			if prompt and prompt.Parent and isLaundryCollectPrompt(prompt) and not seen[prompt] then
				seen[prompt] = true
				table.insert(found, prompt)
			end
		end

		local counter = counterPrompt and counterPrompt:FindFirstAncestor("CounterM")
		if counter then
			for _, prompt in ipairs(counter:GetDescendants()) do
				if prompt:IsA("ProximityPrompt") then
					add(prompt)
				end
			end
		end

		-- Cash piles / MuneyAppear sometimes sit just outside CounterM; scan nearby.
		local anchor = promptPosition(counterPrompt)
			or (counter and getWorldPosition(counter))
			or (getRoot() and getRoot().Position)
		if anchor then
			for _, prompt in ipairs(Workspace:GetDescendants()) do
				if prompt:IsA("ProximityPrompt") and isLaundryCollectPrompt(prompt) then
					local pos = promptPosition(prompt)
					if pos and (pos - anchor).Magnitude <= 18 then
						add(prompt)
					end
				end
			end
		end

		return sortByDistance(found)
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

	-- Fire collect/put-in-bag prompts in place — never longTrip/tween for this step.
	local function fireLaundryCollect(prompt)
		if not (prompt and prompt.Parent and prompt.Enabled) then
			return false
		end
		local object = (prompt.ObjectText or ""):lower()
		local action = (prompt.ActionText or ""):lower()
		-- Put Cash In needs a bag/duffle equipped.
		if object:find("put cash", 1, true) or action:find("duffle", 1, true) then
			local bagTool = findTools(function(tool)
				local name = tool.Name:lower()
				return name:find("bag", 1, true) ~= nil or name:find("duffle", 1, true) ~= nil
			end)[1]
			if bagTool then
				equipTool(bagTool)
			end
		end
		snapNearPrompt(prompt)
		-- Grab Cash HoldDuration is ~1s; instant fire never awards MoneyReady.
		for _ = 1, 4 do
			if not prompt.Parent or not prompt.Enabled then
				break
			end
			fireRegisterHold(prompt)
			task.wait(0.15)
			if findTools(isLaundryBagTool)[1] then
				return true
			end
		end
		return true
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
			promptCache.counters = nil
			local counters = {}
			for _, prompt in ipairs(findPrompts("counters", function(prompt)
				return isCountRegisterPrompt(prompt, wanted)
			end)) do
				table.insert(counters, prompt)
			end
			-- Fresh scan if the cache was empty / stale (ObjectText vs ActionText layouts).
			if #counters == 0 then
				for _, prompt in ipairs(Workspace:GetDescendants()) do
					if prompt:IsA("ProximityPrompt") and isCountRegisterPrompt(prompt, wanted) then
						table.insert(counters, prompt)
					end
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

		local function bagAppeared()
			return findTools(function(tool)
				if not isLaundryBagTool(tool) then
					return false
				end
				-- New stack/bag from this run, or MoneyReady already in hand from a manual grab.
				return not toolsBefore[tool] or tool.Name:lower():find("moneyready", 1, true) ~= nil
			end)[1]
		end

		local function nearbyGrabPrompts()
			local grabs = counterPrompt and findLaundryCollectPrompts(counterPrompt) or {}
			local seen = {}
			for _, prompt in ipairs(grabs) do
				seen[prompt] = true
			end
			local anchors = {}
			local rootPos = getRoot() and getRoot().Position
			if rootPos then
				table.insert(anchors, rootPos)
			end
			local counterPos = promptPosition(counterPrompt)
			if counterPos then
				table.insert(anchors, counterPos)
			end
			for _, prompt in ipairs(Workspace:GetDescendants()) do
				if prompt:IsA("ProximityPrompt") and isLaundryCollectPrompt(prompt) and not seen[prompt] then
					local pos = promptPosition(prompt)
					if pos then
						for _, anchor in ipairs(anchors) do
							if (pos - anchor).Magnitude <= 20 then
								seen[prompt] = true
								table.insert(grabs, prompt)
								break
							end
						end
					end
				end
			end
			return sortByDistance(grabs)
		end

		local bag = bagAppeared()
		local deadline = os.clock() + COUNTING_TIMEOUT
		local lastNotify = 0
		while not bag and os.clock() < deadline and not Arsenic.Destroyed do
			bag = bagAppeared()
			if bag then
				break
			end

			local grabs = nearbyGrabPrompts()
			if #grabs > 0 then
				local before = snapshotTools()
				for _, grab in ipairs(grabs) do
					notify("Grabbing counted cash...")
					fireLaundryCollect(grab)
					bag = waitForNewTool(before, 1.5) or bagAppeared()
					if bag then
						break
					end
				end
			else
				if os.clock() - lastNotify > 8 then
					lastNotify = os.clock()
					notify("Still waiting on Grab Cash at the register...")
				end
				task.wait(0.25)
			end
		end
		if not bag then
			finish("Grab Cash never completed. Stand at the register and run Auto Clean Money again.")
			return
		end
		activeCounter = nil
		notify("Got " .. bag.Name .. ". Cashing in at the bank...")

		local atmMoney = Workspace:FindFirstChild("ATMMoney")
		local bankPrompt = atmMoney and atmMoney:FindFirstChildWhichIsA("ProximityPrompt", true)
		local cashed = false
		if bankPrompt then
			for _ = 1, CLEAN_STEP_ATTEMPTS do
				if not bag.Parent then
					cashed = true
					break
				end
				equipTool(bag)
				-- Bank deposit also needs a real hold; instant often eats the tool with no payout.
				local position = promptPosition(bankPrompt)
				if position then
					goNear(position, math.max((bankPrompt.MaxActivationDistance or 4) * 0.5, 1.5))
				end
				fireRegisterHold(bankPrompt)
				if waitUntil(function()
					return bag.Parent == nil or getStat("Money") + getStat("Bank") > startTotal
				end, 5) then
					cashed = bag.Parent == nil or getStat("Money") + getStat("Bank") > startTotal
					break
				end
			end
		end

		local gained = getStat("Money") + getStat("Bank") - startTotal
		if gained > 0 or cashed then
			returnTo(startCFrame)
			notify("Cleaned " .. formatCash(math.max(gained, 0)) .. ".")
		elseif bag.Parent then
			-- Keep the player with MoneyReady — do not TP away and drop the run.
			notify("Cash is in your hand (" .. bag.Name .. "). Deposit it at the bank ATM.")
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
	-- is behind the camera, collapsed onto the horizon, or otherwise undrawable.
	-- (Weak Z/onScreen checks were pinning every box to the top of the viewport.)
	local function projectVerticalBox(camera, worldPos, topOffset, bottomOffset)
		local viewport = camera.ViewportSize
		if viewport.X < 2 or viewport.Y < 2 then
			return nil
		end
		local depth = (worldPos - camera.CFrame.Position):Dot(camera.CFrame.LookVector)
		if depth < 2 then
			return nil
		end
		local top = camera:WorldToViewportPoint(worldPos + Vector3.new(0, topOffset, 0))
		local bottom = camera:WorldToViewportPoint(worldPos - Vector3.new(0, bottomOffset, 0))
		local root, rootOnScreen = camera:WorldToViewportPoint(worldPos)
		if top.Z < 1 or bottom.Z < 1 or root.Z < 1 then
			return nil
		end
		if top.X ~= top.X or top.Y ~= top.Y or bottom.X ~= bottom.X or bottom.Y ~= bottom.Y then
			return nil
		end
		local centerX = (top.X + bottom.X) * 0.5
		local topY = math.min(top.Y, bottom.Y)
		local bottomY = math.max(top.Y, bottom.Y)
		local height = bottomY - topY
		local margin = 64
		if centerX < -margin or centerX > viewport.X + margin then
			return nil
		end
		if bottomY < -margin or topY > viewport.Y + margin then
			return nil
		end
		-- Require the root itself to sit in/near the viewport (not a lone tip at y=0).
		if not rootOnScreen then
			local rootMargin = 40
			if root.X < -rootMargin
				or root.X > viewport.X + rootMargin
				or root.Y < -rootMargin
				or root.Y > viewport.Y + rootMargin
			then
				return nil
			end
		end
		-- Steep look-down compresses far targets into a few pixels on the top edge.
		local worldHeight = topOffset + bottomOffset
		local fov = math.rad(math.clamp(camera.FieldOfView, 1, 120))
		local expected = (worldHeight / depth) * (viewport.Y / (2 * math.tan(fov * 0.5)))
		if expected > 18 and height < expected * 0.4 then
			return nil
		end
		if height < 12 and topY < 24 then
			return nil
		end
		height = math.max(height, 4)
		return centerX, topY, height, viewport
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
		local seat = getDriveSeat(car)
		if seat then
			return seat
		end
		return car.PrimaryPart or car:FindFirstChildWhichIsA("BasePart", true)
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
			for car in pairs(vehicleEspObjects) do
				removeVehicleEsp(car)
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
		"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",
		"DIE66SQjguZChEJRk03aArTW4XAwEgkxxkql0sJyDmCPi0aETWQ/3kZrgdq2O1DrwnqhAAUAGBocUNo1S3li8jwCzs3flUptbmyOjIxofXiK1kunR51YgjreZMQYelIuLq+NDg/U/8kkDZsba59//uDll18CgKgTdcvlu4/XxsbGiOja1aku",
		"jNmbN28BAYBum5K1A/AhgFe/mKcuXzQllOu6xp2ufmQNAD6flUrGWpkUWsty0WsHkYJUMtYouguModaEjB06jCAyE7A/mJmh2r71zMZoYsB7F9gFQFV2B2xBjAkhOAEg01oZTuce4wGAVA9npTnPwqetd9IsD4948GkoAeDM7GzNIqut9DZD",
		"AETL8hERIKueiCopGAgA3n7nnVwmnc3m+/v7AsHQO1972xm0Gsi1oJc/zQKwY6+ommlKCFpryxJCcCLFEE1oOJBno5SSc7Gyup5MJoPBoCboBDG/fOlioVgynhoEMDc3Z0ajRFDzzcBuYgu98BexVhzUf/e9L05UM9A7ejVtdDmgXSJZ4R4C",
		"NAXoWtIAACZAP3q8fGocLGEtLK2OjY9XNr3OZ+La1amjkQH22XGFYMvLm0srGyNHINQAQCweD/hASXlo7xNXlY2OMRGZS8a59XTEaDrYAxFAEzCGgtktuTR10OjQfscBxyHSlj8ACFq16XC1PSp5AWKtsNVaE1N171XDqOHT1/MxHQlphG96",
		"r6oQGWcV94C783epmti2scvUEB+XVtAjBYRVnAao4o0dYfvqr6/PFwg7kZ2NUhEXYU+yHTW4GiIcBIE66XPIOSuWyuVyKRwOallmDIFUfQG2737LiZTn9idjwmftA+5GQMaM+wbWTdhs29ra3Lr/6GOAbDeBzzaC960Mroqo0BMAKy2vbsYT",
		"KWScMbp7917LvUacC0DcN9idGh8GgK2trbGRQXhquo5HDNBmWolo274g57zHXZ9VnFmIIR96ZfQXP/tZPw8qreAHCr/3T2Zf9738tPQ6kPe6ipry106NodZjamqKqEIuAILpW7cQcWx8vFwq7Tz6LJAcYKEIANy6c6ews8uFIE3Xrl2xbBsI",
		"Un19nDElJSJqKQHAtnyC101OEE2RQidsfHmIfS+9tr2zU0glU/6g/0DPNzjZvr5+Eylqwb01yhOA57moEDQyjgCggQS3f/Q//xqI/t/4l7+gpYo60Xwu73mu3wqGhjaJLERGe3suHm9ojjjxNuuCyPS4ldKcadAe87aRYVMv0h/wUefGPQBI",
		"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",
	})

	local MINIMAP_FILE = "Arsenic/minimap_v15.png"
	-- World AABB matching the generated top-down bake (top of image = north / +Z).
	local WORLD = {
		minX = -1858.72632,
		maxX = 427.092346,
		minZ = -4523.78271,
		maxZ = 4030.35742,
	}
	-- Baked image pixel size (Arsenic/minimap_v15.png).
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

	local function nearestLocationName(position)
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
		hudTime.Size = UDim2.new(0.42, 0, 1, 0)
		hudFps = makeHudLabel(hud, Vector2.new(0.5, 0.5), UDim2.new(0.52, 0, 0.5, 0), Enum.TextXAlignment.Center)
		hudFps.Size = UDim2.new(0.16, 0, 1, 0)
		hudPing = makeHudLabel(hud, Vector2.new(0.5, 0.5), UDim2.new(0.68, 0, 0.5, 0), Enum.TextXAlignment.Center)
		hudPing.Size = UDim2.new(0.16, 0, 1, 0)
		hudPlace = makeHudLabel(hud, Vector2.new(1, 0.5), UDim2.new(1, 0, 0.5, 0), Enum.TextXAlignment.Right)
		hudPlace.Size = UDim2.new(0.34, 0, 1, 0)
		hudPlace.TextTruncate = Enum.TextTruncate.AtEnd

		local frame = Instance.new("Frame")
		frame.Name = "Map"
		frame.Position = UDim2.fromOffset(0, HUD_HEIGHT + HUD_GAP)
		frame.Size = UDim2.fromOffset(FRAME_SIZE.X, FRAME_SIZE.Y)
		frame.BackgroundColor3 = Color3.fromRGB(28, 24, 26)
		frame.BorderSizePixel = 0
		frame.ClipsDescendants = true
		frame.Parent = stack
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 10)
		corner.Parent = frame
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
			if hudTick >= 0.2 then
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
			end

			local root = getRoot()
			if not root then
				blip.Visible = false
				if hudPlace then
					hudPlace.Text = "Unknown"
				end
				return
			end
			blip.Visible = true
			if hudPlace then
				hudPlace.Text = nearestLocationName(root.Position)
			end
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
			destroyGui()
		end,
	}

	table.insert(Arsenic.Cleanup, destroyGui)
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

	local UserInputService = game:GetService("UserInputService")
	local ContextActionService = game:GetService("ContextActionService")
	local MAIN_MANSION = Vector3.new(-793.56, 255.53, 1394.58)
	local NEW_CITY_MANSION = Vector3.new(-1488.87, 478.14, -3745.99)
	local BUY_MAP_SINK = "ArsenicHomeBuyMapSink"
	local buyMapCameraLock = nil
	local MAP_WORLD = {
		minX = -1858.72632,
		maxX = 427.092346,
		minZ = -4523.78271,
		maxZ = 4030.35742,
	}

	local homeWatch = {
		conn = nil,
		breakLast = 0,
		motionLast = 0,
		backLast = 0,
		backCamPart = nil,
	}
	local buyMapGui = nil

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

	local function worldToMapUV(position)
		local spanX = MAP_WORLD.maxX - MAP_WORLD.minX
		local spanZ = MAP_WORLD.maxZ - MAP_WORLD.minZ
		local u = math.clamp((position.X - MAP_WORLD.minX) / spanX, 0, 1)
		local v = math.clamp((MAP_WORLD.maxZ - position.Z) / spanZ, 0, 1)
		return u, v
	end

	local function getMinimapImage()
		local ensure = Features.Minimap and Features.Minimap._ensureAsset
		if type(ensure) == "function" then
			local ok, id = pcall(ensure)
			if ok and type(id) == "string" and id ~= "" then
				return id
			end
		end
		-- Fallback: reuse written custom asset if present.
		if typeof(getcustomasset) == "function" then
			for _, name in ipairs({ "Arsenic/minimap_v15.png", "Arsenic/minimap_v11.png", "Arsenic/minimap_generated.png" }) do
				local ok, id = pcall(getcustomasset, name)
				if ok and type(id) == "string" and id ~= "" then
					return id
				end
			end
		end
		return nil
	end

	local function unlockBuyMapCamera()
		pcall(function()
			ContextActionService:UnbindAction(BUY_MAP_SINK)
		end)
		if buyMapCameraLock then
			pcall(function()
				LocalPlayer.CameraMinZoomDistance = buyMapCameraLock.minZoom
				LocalPlayer.CameraMaxZoomDistance = buyMapCameraLock.maxZoom
				UserInputService.MouseBehavior = buyMapCameraLock.mouseBehavior or Enum.MouseBehavior.Default
				UserInputService.MouseIconEnabled = buyMapCameraLock.mouseIcon ~= false
				if buyMapCameraLock.cameraMode ~= nil then
					LocalPlayer.CameraMode = buyMapCameraLock.cameraMode
				end
			end)
			buyMapCameraLock = nil
		end
	end

	local function lockBuyMapCamera()
		if buyMapCameraLock then
			return
		end
		local camera = Workspace.CurrentCamera
		local zoom = 16
		if camera then
			zoom = math.clamp((camera.CFrame.Position - camera.Focus.Position).Magnitude, 0.5, 128)
		end
		buyMapCameraLock = {
			minZoom = LocalPlayer.CameraMinZoomDistance,
			maxZoom = LocalPlayer.CameraMaxZoomDistance,
			mouseBehavior = UserInputService.MouseBehavior,
			mouseIcon = UserInputService.MouseIconEnabled,
			cameraMode = LocalPlayer.CameraMode,
		}
		-- Freeze third-person zoom so scroll cannot pull the camera into first person.
		LocalPlayer.CameraMinZoomDistance = zoom
		LocalPlayer.CameraMaxZoomDistance = zoom
		pcall(function()
			LocalPlayer.CameraMode = Enum.CameraMode.Classic
		end)
		UserInputService.MouseBehavior = Enum.MouseBehavior.Default
		UserInputService.MouseIconEnabled = true
		ContextActionService:BindActionAtPriority(
			BUY_MAP_SINK,
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

	local function closeBuyMap()
		unlockBuyMapCamera()
		if buyMapGui then
			buyMapGui:Destroy()
			buyMapGui = nil
		end
	end

	local function openBuyMap()
		closeBuyMap()
		local image = getMinimapImage()
		local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
		if not playerGui then
			notify("PlayerGui missing.")
			return
		end

		lockBuyMapCamera()

		local gui = Instance.new("ScreenGui")
		gui.Name = "ArsenicHomeBuyMap"
		gui.IgnoreGuiInset = true
		gui.ResetOnSpawn = false
		gui.DisplayOrder = 120
		gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
		gui.Parent = playerGui
		buyMapGui = gui

		local dim = Instance.new("Frame")
		dim.BackgroundColor3 = Color3.fromRGB(10, 8, 10)
		dim.BackgroundTransparency = 0.35
		dim.Size = UDim2.fromScale(1, 1)
		dim.BorderSizePixel = 0
		dim.Parent = gui

		local panel = Instance.new("Frame")
		panel.Name = "Panel"
		panel.AnchorPoint = Vector2.new(0.5, 0.5)
		panel.Position = UDim2.fromScale(0.5, 0.5)
		panel.Size = UDim2.fromScale(0.92, 0.88)
		panel.BackgroundColor3 = Color3.fromRGB(28, 22, 26)
		panel.BorderSizePixel = 0
		panel.Active = true
		panel.Parent = gui
		local panelCorner = Instance.new("UICorner")
		panelCorner.CornerRadius = UDim.new(0, 12)
		panelCorner.Parent = panel

		local title = Instance.new("TextLabel")
		title.BackgroundTransparency = 1
		title.Size = UDim2.new(1, -140, 0, 36)
		title.Position = UDim2.fromOffset(16, 8)
		title.Font = Enum.Font.GothamBold
		title.TextSize = 18
		title.TextXAlignment = Enum.TextXAlignment.Left
		title.TextColor3 = Color3.fromRGB(255, 230, 238)
		title.Text = "Select a Home to Buy"
		title.Parent = panel

		local closeBtn = Instance.new("TextButton")
		closeBtn.AnchorPoint = Vector2.new(1, 0)
		closeBtn.Position = UDim2.new(1, -12, 0, 10)
		closeBtn.Size = UDim2.fromOffset(96, 30)
		closeBtn.BackgroundColor3 = Color3.fromRGB(255, 130, 170)
		closeBtn.TextColor3 = Color3.fromRGB(40, 20, 30)
		closeBtn.Font = Enum.Font.GothamMedium
		closeBtn.TextSize = 14
		closeBtn.Text = "Close"
		closeBtn.Parent = panel
		local closeCorner = Instance.new("UICorner")
		closeCorner.CornerRadius = UDim.new(0, 8)
		closeCorner.Parent = closeBtn
		closeBtn.MouseButton1Click:Connect(closeBuyMap)

		local mapFrame = Instance.new("Frame")
		mapFrame.Name = "MapFrame"
		mapFrame.Position = UDim2.fromOffset(12, 48)
		mapFrame.Size = UDim2.new(0.72, -18, 1, -60)
		mapFrame.BackgroundColor3 = Color3.fromRGB(40, 48, 42)
		mapFrame.ClipsDescendants = true
		mapFrame.BorderSizePixel = 0
		mapFrame.Active = true
		mapFrame.Parent = panel
		local mapCorner = Instance.new("UICorner")
		mapCorner.CornerRadius = UDim.new(0, 8)
		mapCorner.Parent = mapFrame

		local mapImage = Instance.new("ImageLabel")
		mapImage.Name = "Map"
		mapImage.BackgroundTransparency = 1
		mapImage.BorderSizePixel = 0
		mapImage.AnchorPoint = Vector2.new(0.5, 0.5)
		mapImage.Position = UDim2.fromScale(0.5, 0.5)
		mapImage.Size = UDim2.fromScale(1, 1)
		mapImage.ScaleType = Enum.ScaleType.Fit
		mapImage.Image = image or ""
		mapImage.Parent = mapFrame

		local markerLayer = Instance.new("Frame")
		markerLayer.BackgroundTransparency = 1
		markerLayer.Size = UDim2.fromScale(1, 1)
		markerLayer.Parent = mapImage

		local info = Instance.new("Frame")
		info.Position = UDim2.new(0.72, 0, 0, 48)
		info.Size = UDim2.new(0.28, -16, 1, -60)
		info.BackgroundColor3 = Color3.fromRGB(36, 28, 32)
		info.BorderSizePixel = 0
		info.Parent = panel
		local infoCorner = Instance.new("UICorner")
		infoCorner.CornerRadius = UDim.new(0, 8)
		infoCorner.Parent = info

		local infoTitle = Instance.new("TextLabel")
		infoTitle.BackgroundTransparency = 1
		infoTitle.Position = UDim2.fromOffset(12, 12)
		infoTitle.Size = UDim2.new(1, -24, 0, 28)
		infoTitle.Font = Enum.Font.GothamBold
		infoTitle.TextSize = 16
		infoTitle.TextXAlignment = Enum.TextXAlignment.Left
		infoTitle.TextColor3 = Color3.fromRGB(255, 230, 238)
		infoTitle.Text = "No home selected"
		infoTitle.Parent = info

		local infoBody = Instance.new("TextLabel")
		infoBody.BackgroundTransparency = 1
		infoBody.Position = UDim2.fromOffset(12, 48)
		infoBody.Size = UDim2.new(1, -24, 0, 120)
		infoBody.Font = Enum.Font.Gotham
		infoBody.TextSize = 14
		infoBody.TextXAlignment = Enum.TextXAlignment.Left
		infoBody.TextYAlignment = Enum.TextYAlignment.Top
		infoBody.TextWrapped = true
		infoBody.TextColor3 = Color3.fromRGB(230, 210, 218)
		infoBody.Text = "Scroll or use +/- to zoom. Drag to pan. Click a marker to inspect a home."
		infoBody.Parent = info

		local zoomRow = Instance.new("Frame")
		zoomRow.BackgroundTransparency = 1
		zoomRow.AnchorPoint = Vector2.new(0.5, 1)
		zoomRow.Position = UDim2.new(0.5, 0, 1, -60)
		zoomRow.Size = UDim2.new(1, -24, 0, 32)
		zoomRow.Parent = info

		local function makeZoomButton(text, xScale)
			local btn = Instance.new("TextButton")
			btn.AnchorPoint = Vector2.new(0.5, 0.5)
			btn.Position = UDim2.fromScale(xScale, 0.5)
			btn.Size = UDim2.fromOffset(44, 30)
			btn.BackgroundColor3 = Color3.fromRGB(255, 160, 188)
			btn.TextColor3 = Color3.fromRGB(40, 20, 30)
			btn.Font = Enum.Font.GothamBold
			btn.TextSize = 18
			btn.Text = text
			btn.Parent = zoomRow
			local corner = Instance.new("UICorner")
			corner.CornerRadius = UDim.new(0, 8)
			corner.Parent = btn
			return btn
		end
		local zoomOutBtn = makeZoomButton("-", 0.28)
		local zoomInBtn = makeZoomButton("+", 0.72)

		local buyBtn = Instance.new("TextButton")
		buyBtn.AnchorPoint = Vector2.new(0.5, 1)
		buyBtn.Position = UDim2.new(0.5, 0, 1, -16)
		buyBtn.Size = UDim2.new(1, -24, 0, 36)
		buyBtn.BackgroundColor3 = Color3.fromRGB(255, 130, 170)
		buyBtn.TextColor3 = Color3.fromRGB(40, 20, 30)
		buyBtn.Font = Enum.Font.GothamBold
		buyBtn.TextSize = 15
		buyBtn.Text = "Buy Selected"
		buyBtn.AutoButtonColor = true
		buyBtn.Parent = info
		local buyCorner = Instance.new("UICorner")
		buyCorner.CornerRadius = UDim.new(0, 8)
		buyCorner.Parent = buyBtn

		local selected = nil
		local scale = 1
		local offset = Vector2.zero
		local dragging = false
		local dragStart = nil
		local offsetStart = nil

		local function applyTransform()
			local base = mapFrame.AbsoluteSize
			if base.X < 2 or base.Y < 2 then
				return
			end
			-- Fit map aspect (481x1800) into frame, then zoom.
			local aspect = 481 / 1800
			local fitW, fitH = base.X, base.X / aspect
			if fitH > base.Y then
				fitH = base.Y
				fitW = base.Y * aspect
			end
			mapImage.Size = UDim2.fromOffset(math.floor(fitW * scale + 0.5), math.floor(fitH * scale + 0.5))
			mapImage.Position = UDim2.new(0.5, offset.X, 0.5, offset.Y)
		end

		local function zoomBy(delta)
			local old = scale
			scale = math.clamp(scale + delta, 0.8, 6)
			if scale ~= old then
				applyTransform()
			end
		end

		local function selectEntry(entry, marker)
			selected = entry
			infoTitle.Text = entry.t
			local door = doorNearPosition(Vector3.new(entry.x, entry.y, entry.z), 55)
			local owner = door and ownerValue(door) or "None"
			local status = isUnownedName(owner) and "Unowned" or ("Owned by " .. tostring(owner))
			infoBody.Text = string.format(
				"Price: %s\nType: %s\nLocation: %s\nStatus: %s\nCoords: %.0f, %.0f",
				entry.priceText or ("$" .. tostring(entry.p)),
				entry.t,
				entry.r,
				status,
				entry.x,
				entry.z
			)
			for _, child in ipairs(markerLayer:GetChildren()) do
				if child:IsA("TextButton") then
					child.BackgroundColor3 = Color3.fromRGB(255, 220, 90)
				end
			end
			if marker then
				marker.BackgroundColor3 = Color3.fromRGB(255, 90, 140)
			end
		end

		for _, entry in ipairs(HOME_CATALOG) do
			local u, v = worldToMapUV(Vector3.new(entry.x, entry.y, entry.z))
			local marker = Instance.new("TextButton")
			marker.AnchorPoint = Vector2.new(0.5, 0.5)
			marker.Position = UDim2.fromScale(u, v)
			marker.Size = UDim2.fromOffset(10, 10)
			marker.BackgroundColor3 = Color3.fromRGB(255, 220, 90)
			marker.Text = ""
			marker.BorderSizePixel = 0
			marker.ZIndex = 3
			marker.Parent = markerLayer
			local corner = Instance.new("UICorner")
			corner.CornerRadius = UDim.new(1, 0)
			corner.Parent = marker
			local stroke = Instance.new("UIStroke")
			stroke.Thickness = 1
			stroke.Color = Color3.fromRGB(20, 20, 20)
			stroke.Parent = marker
			marker.MouseButton1Click:Connect(function()
				selectEntry(entry, marker)
			end)
		end

		mapFrame.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
				dragging = true
				dragStart = Vector2.new(input.Position.X, input.Position.Y)
				offsetStart = offset
			end
		end)
		mapFrame.InputEnded:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
				dragging = false
			end
		end)
		-- Gui-local wheel events (do not rely on camera zoom input).
		mapFrame.MouseWheelForward:Connect(function()
			zoomBy(0.18)
		end)
		mapFrame.MouseWheelBackward:Connect(function()
			zoomBy(-0.18)
		end)
		zoomInBtn.MouseButton1Click:Connect(function()
			zoomBy(0.35)
		end)
		zoomOutBtn.MouseButton1Click:Connect(function()
			zoomBy(-0.35)
		end)
		track(UserInputService.InputChanged:Connect(function(input)
			if not buyMapGui then
				return
			end
			-- Keep cursor free while the map is open.
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
				-- Fallback if Gui wheel events are unavailable; camera zoom stays frozen.
				local z = input.Position.Z
				if z ~= 0 then
					zoomBy(z * 0.12)
				end
			end
		end))
		mapFrame:GetPropertyChangedSignal("AbsoluteSize"):Connect(applyTransform)
		task.defer(applyTransform)

		buyBtn.MouseButton1Click:Connect(function()
			if not selected then
				notify("Select a home marker first.")
				return
			end
			local entry = selected
			closeBuyMap()
			runPlayerAction(function()
				buyHomeAt(Vector3.new(entry.x, entry.y, entry.z), entry.t)
			end)
		end)

		if not image then
			infoBody.Text = "Map image unavailable (enable Minimap once to cache it). Markers still work."
		end
		notify("Home buy map opened.")
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
		description = "Opens the full game map where you can select a home to buy.",
		icon = ICONS.map,
		callback = function()
			if Arsenic.Homes then
				Arsenic.Homes.openBuyMap()
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
