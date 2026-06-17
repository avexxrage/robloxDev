--[[
	HOT POTATO v10 - JoinManager
	Tipo: ModuleScript (amarillo) | Ubicacion: ServerScriptService

	Detecta cuando un jugador esta sobre una JoinZone y le avisa al
	cliente para mostrar el boton "Unirse" (modos FFA / grupo).

	CAMBIO v10: las zonas que apuntan a arenas de DUELO (Config.DUEL_ARENAS)
	se IGNORAN aqui, porque ahora la entrada a duelos es por PLACAS
	(la maneja el DuelManager). Asi no se pisan los dos sistemas.
]]
local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")

local Config = require(RS:WaitForChild("Modules"):WaitForChild("Config"))
local RE = RS:WaitForChild("RemoteEvents")
local RE_ZonePrompt = RE:WaitForChild("ZonePrompt")

local ZONE_RADIUS = 14

-- set de arenas de duelo, para ignorarlas aqui
local DuelSet = {}
for _, n in ipairs(Config.DUEL_ARENAS or {}) do DuelSet[n] = true end

local Zones = {}        -- { {part, dest, mode} }
local PlayerZone = {}   -- { [player] = dest } zona actual donde esta parado

local JoinManager = {}

local function ScanZones()
	Zones = {}
	local building = workspace:FindFirstChild("Building")
	if not building then return end
	for _, part in ipairs(building:GetDescendants()) do
		if part:IsA("BasePart") and part:FindFirstChild("JoinDest") then
			local dest = part.JoinDest.Value
			-- IGNORAR zonas de arenas de duelo (las placas las manejan)
			if not DuelSet[dest] then
				table.insert(Zones, {
					part = part,
					dest = dest,
					mode = part:FindFirstChild("JoinMode") and part.JoinMode.Value or "group",
				})
			end
		end
	end
	print("[JoinManager] " .. #Zones .. " zonas de union (sin contar duelos)")
end

-- Loop de proximidad: avisa al cliente cuando entra/sale de una zona
task.spawn(function()
	task.wait(4)
	ScanZones()
	while true do
		task.wait(0.3)
		if #Zones == 0 then ScanZones(); task.wait(3); continue end
		for _, player in ipairs(Players:GetPlayers()) do
			local char = player.Character
			local hrp = char and char:FindFirstChild("HumanoidRootPart")
			if not hrp then continue end

			local inZone = nil
			for _, z in ipairs(Zones) do
				if z.part and z.part.Parent then
					local dx = math.abs(hrp.Position.X - z.part.Position.X)
					local dz = math.abs(hrp.Position.Z - z.part.Position.Z)
					if dx <= ZONE_RADIUS and dz <= ZONE_RADIUS then
						inZone = z
						break
					end
				end
			end

			if inZone and PlayerZone[player] ~= inZone.dest then
				PlayerZone[player] = inZone.dest
				RE_ZonePrompt:FireClient(player, {
					Show = true,
					Dest = inZone.dest,
					Mode = inZone.mode,
					Name = Config:DisplayName(inZone.dest),
				})
			elseif not inZone and PlayerZone[player] then
				PlayerZone[player] = nil
				RE_ZonePrompt:FireClient(player, { Show = false })
			end
		end
	end
end)

function JoinManager:GetPlayerZone(player)
	return PlayerZone[player]
end

function JoinManager:ClearZone(player)
	PlayerZone[player] = nil
	RE_ZonePrompt:FireClient(player, { Show = false })
end

Players.PlayerRemoving:Connect(function(player)
	PlayerZone[player] = nil
end)

print("[JoinManager] OK")
return JoinManager
