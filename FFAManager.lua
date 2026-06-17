--[[
	HOT POTATO v9 - FFAManager
	Tipo: Script (azul) | Ubicacion: ServerScriptService

	Modo FFA CONTINUO (arena abierta, sin rondas):
	- Jugadores entran con el boton Unirse
	- Si hay >=2 jugadores, aparece la papa en uno al azar
	- La papa tiene contador; al llegar a 0 mata al portador = +1 kill al ultimo que la paso
	- A las 3 kills: fuego sobre la cabeza con el numero
	- Al morir, el jugador respawnea en el lobby (sale de la arena)
	- Es infinito mientras haya gente
]]
local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")

local Config     = require(RS:WaitForChild("Modules"):WaitForChild("Config"))
local PlayerData = require(script.Parent:WaitForChild("PlayerData"))
local Bomb       = require(script.Parent:WaitForChild("BombModule"))
local JoinMgr    = require(script.Parent:WaitForChild("JoinManager"))
local EventMgr   = require(script.Parent:WaitForChild("EventManager"))

local RE = RS:WaitForChild("RemoteEvents")
local RE_BombUI    = RE:WaitForChild("UpdateBombUI")
local RE_Passed    = RE:WaitForChild("BombPassed")
local RE_Eliminated= RE:WaitForChild("PlayerEliminated")
local RE_Stats     = RE:WaitForChild("UpdateStats")
local RE_Effect    = RE:WaitForChild("PlayEffect")
local RE_Notif     = RE:WaitForChild("ShowNotif")
local RE_Join      = RE:WaitForChild("JoinArena")
local RE_FFAJoined = RE:WaitForChild("FFAJoined")
local RE_FFALeft   = RE:WaitForChild("FFALeft")
local RE_KillUpd   = RE:WaitForChild("KillUpdate")

Players.RespawnTime = 3

-- Estado por arena
local Arenas = {}
for _, name in ipairs(Config.GROUP_ARENAS) do
	Arenas[name] = {
		Name = name,
		Players = {},     -- { [player] = true } jugadores dentro
		Kills = {},       -- { [player] = n }
		Holder = nil,     -- quien tiene la papa
		LastPasser = nil, -- quien se la paso por ultimo (para dar kill)
		Bomb = nil,
		BombTime = 0,
		BombTotal = 0,
		LastPass = {},
		Active = false,   -- hay papa en juego
	}
end

local function InArena(player)
	for _, a in pairs(Arenas) do
		if a.Players[player] then return a end
	end
	return nil
end

-- decirle al JoinManager cuando un jugador esta dentro de una arena FFA
JoinMgr:RegisterBusyChecker(function(player)
	return InArena(player) ~= nil
end)

local function ApplySpeed(player, speed)
	local char = player.Character
	if not char then return end
	local hum = char:FindFirstChild("Humanoid")
	if hum and hum.Health > 0 then
		hum.WalkSpeed = speed; hum.JumpPower = Config.JUMP_POWER
	end
end

local function TeleportToLobby(player)
	local char = player.Character
	if not char then return end
	local hrp = char:FindFirstChild("HumanoidRootPart")
	if not hrp then return end
	local ls = workspace:FindFirstChild("LobbySpawn")
	hrp.CFrame = ls and (ls.CFrame + Vector3.new(math.random(-4,4), 4, math.random(-4,4))) or CFrame.new(0,5,0)
	task.delay(0.2, function() ApplySpeed(player, Config.SPEED_NORMAL) end)
end

local function TeleportToArena(player, arenaName)
	local folder = workspace:FindFirstChild(arenaName)
	if not folder then return false end
	local char = player.Character
	if not char then return false end
	local hrp = char:FindFirstChild("HumanoidRootPart")
	if not hrp then return false end
	local spawns = {}
	for _, v in ipairs(folder:GetChildren()) do
		if v:IsA("BasePart") and v.Name:match("^Spawn%d+$") then table.insert(spawns, v) end
	end
	if #spawns == 0 then return false end
	local sp = spawns[math.random(1, #spawns)]
	hrp.CFrame = sp.CFrame + Vector3.new(0, 4, 0)
	task.delay(0.2, function() ApplySpeed(player, Config.SPEED_NORMAL) end)
	return true
end

local function SendStats(player)
	local d = PlayerData:Get(player)
	if not d then return end
	RE_Stats:FireClient(player, {
		Coins=d.Coins, XP=d.XP, Level=d.Level, Kills=d.Kills, DuelWins=d.DuelWins,
		OwnedEffects=d.OwnedEffects, EquippedEffect=d.EquippedEffect,
	})
end

-- ============================================================
-- FUEGO DE KILLS sobre la cabeza
-- ============================================================
local function UpdateKillFire(arena, player)
	local char = player.Character
	if not char then return end
	local head = char:FindFirstChild("Head")
	if not head then return end

	local kills = arena.Kills[player] or 0
	local existing = head:FindFirstChild("KillFire")

	if kills >= Config.FIRE_KILLS then
		if not existing then
			local att = Instance.new("Attachment")
			att.Name = "KillFire"
			att.Position = Vector3.new(0, 1.2, 0)
			att.Parent = head

			local fire = Instance.new("Fire")
			fire.Size = 5; fire.Heat = 8
			fire.Color = Color3.fromRGB(255, 110, 0)
			fire.SecondaryColor = Color3.fromRGB(255, 220, 60)
			fire.Parent = att

			local bb = Instance.new("BillboardGui")
			bb.Name = "KillCount"
			bb.Size = UDim2.new(0, 60, 0, 30)
			bb.StudsOffset = Vector3.new(0, 2.8, 0)
			bb.AlwaysOnTop = true
			bb.Parent = head

			local lbl = Instance.new("TextLabel")
			lbl.Name = "Lbl"
			lbl.Size = UDim2.new(1,0,1,0)
			lbl.BackgroundTransparency = 1
			lbl.Text = "🔥 " .. kills
			lbl.TextColor3 = Color3.fromRGB(255, 180, 40)
			lbl.Font = Enum.Font.FredokaOne
			lbl.TextScaled = true
			lbl.TextStrokeTransparency = 0.2
			lbl.Parent = bb
		else
			local bb = head:FindFirstChild("KillCount")
			if bb and bb:FindFirstChild("Lbl") then
				bb.Lbl.Text = "🔥 " .. kills
			end
		end
	end
end

local function ClearKillFire(player)
	local char = player.Character
	if not char then return end
	local head = char:FindFirstChild("Head")
	if not head then return end
	local att = head:FindFirstChild("KillFire")
	if att then att:Destroy() end
	local bb = head:FindFirstChild("KillCount")
	if bb then bb:Destroy() end
end

-- ============================================================
-- PAPA
-- ============================================================
local PassBomb  -- forward declaration

local function GiveBomb(arena, player)
	if arena.Bomb then Bomb.Destroy(arena.Bomb); arena.Bomb = nil end
	-- callback de hitbox: solo pasa si el tocado esta DENTRO de la arena
	local onTouch = function(touchedPlayer)
		if arena.Players[touchedPlayer] then
			PassBomb(arena, player, touchedPlayer)
		end
	end
	local bomb = Bomb.Attach(player, onTouch)
	if not bomb then return end
	arena.Bomb = bomb
	arena.Holder = player
	ApplySpeed(player, Config.SPEED_BOMB)
end

local function ListPlayers(arena)
	local t = {}
	for p in pairs(arena.Players) do
		if p and p.Parent then table.insert(t, p) end
	end
	return t
end

local function SendBombUI(arena)
	local list = ListPlayers(arena)
	for _, p in ipairs(list) do
		RE_BombUI:FireClient(p, {
			Active = arena.Active,
			TimeLeft = arena.BombTime,
			Total = arena.BombTotal,
			Holder = arena.Holder and arena.Holder.Name or "",
			Count = #list,
			Arena = arena.Name,
			FFA = true,
		})
	end
end

-- ============================================================
-- PASE
-- ============================================================
PassBomb = function(arena, from, to)
	local now = tick()
	if arena.LastPass[from] and (now - arena.LastPass[from]) < Config.PASS_COOLDOWN then return end
	if not arena.Players[to] or to == from then return end
	if arena.Holder ~= from then return end

	-- validar distancia real (anti-pase a traves del cristal):
	-- la hitbox toca, pero confirmamos que esten cerca de verdad
	local fc = from.Character and from.Character:FindFirstChild("HumanoidRootPart")
	local tc = to.Character and to.Character:FindFirstChild("HumanoidRootPart")
	if fc and tc then
		local d = (fc.Position - tc.Position).Magnitude
		if d > (Config.PASS_HITBOX + 4) then return end  -- demasiado lejos = bug, ignorar
	end

	arena.LastPass[from] = now
	arena.LastPass[to] = now
	arena.LastPasser = from
	ApplySpeed(from, Config.SPEED_NORMAL)
	GiveBomb(arena, to)

	RE_Passed:FireClient(to, to.Name)
	RE_Notif:FireClient(to, "¡TIENES LA PAPA!", "¡Tócala a alguien para pasarla!", "danger")

	local d = PlayerData:Get(from)
	if d then PlayerData:AddCoins(from, Config.COINS_PASS) end
end

-- ============================================================
-- FUNCION CENTRAL: limpiar jugador de la arena
-- ============================================================
local function RemoveFromArena(player, arenaToClear)
	local arena = arenaToClear or InArena(player)
	if not arena then return end
	if not arena.Players[player] then return end

	arena.Players[player] = nil
	arena.Kills[player] = nil
	ClearKillFire(player)

	if arena.Holder == player then
		if arena.Bomb then Bomb.Destroy(arena.Bomb); arena.Bomb = nil end
		arena.Holder = nil
		arena.LastPasser = nil
		arena.Active = false
	end

	-- limpiar Tool del jugador
	pcall(function()
		local char = player.Character
		if char then
			for _, t in ipairs(char:GetChildren()) do
				if t:IsA("Tool") and t.Name == "🥔 Papa Caliente" then t:Destroy() end
			end
		end
		local bp = player:FindFirstChildOfClass("Backpack")
		if bp then
			for _, t in ipairs(bp:GetChildren()) do
				if t:IsA("Tool") and t.Name == "🥔 Papa Caliente" then t:Destroy() end
			end
		end
	end)

	RE_FFALeft:FireClient(player, { Arena = arena.Name })
	JoinMgr:ClearZone(player)
end

-- ============================================================
-- EXPLOSION = KILL
-- ============================================================
local RemoveFromArena  -- forward declaration (definida despues de PlayerAdded)

local function Explode(arena)
	local victim = arena.Holder
	if not victim then return end

	-- dar kill al ultimo que paso la papa
	local killer = arena.LastPasser
	if killer and killer ~= victim and arena.Players[killer] then
		local kills = (arena.Kills[killer] or 0) + 1
		arena.Kills[killer] = kills
		PlayerData:AddKill(killer)
		PlayerData:AddCoins(killer, Config.COINS_KILL)
		PlayerData:AddXP(killer, Config.XP_KILL)
		SendStats(killer)
		UpdateKillFire(arena, killer)
		RE_KillUpd:FireClient(killer, { Kills = kills })
		RE_Notif:FireClient(killer, "💀 ¡KILL!", "Eliminaste a " .. victim.Name .. " (+1)", "success")
	end

	-- efecto de muerte
	local d = PlayerData:Get(victim)
	local effectId = d and d.EquippedEffect or "default"
	local pos = Vector3.new()
	if victim.Character then
		local hrp = victim.Character:FindFirstChild("HumanoidRootPart")
		if hrp then pos = hrp.Position end
	end
	for _, p in ipairs(ListPlayers(arena)) do
		RE_Effect:FireClient(p, effectId, victim.Name, pos)
	end
	RE_Notif:FireClient(victim, "💥 ¡EXPLOTASTE!", "Vuelves al lobby", "danger")

	-- limpiar bomba del estado de arena ANTES de RemoveFromArena
	-- (para que RemoveFromArena no intente destruirla dos veces)
	if arena.Bomb then Bomb.Destroy(arena.Bomb); arena.Bomb = nil end
	arena.Holder = nil; arena.LastPasser = nil; arena.Active = false

	-- sacar al jugador (limpia Tool, estado, manda FFALeft)
	RemoveFromArena(victim, arena)

	if victim.Character then
		local hum = victim.Character:FindFirstChild("Humanoid")
		if hum then hum.Health = 0 end
	end
end

-- ============================================================
-- LOOP POR ARENA
-- ============================================================
local function ArenaLoop(arena)
	while true do
		task.wait(0.1)
		local list = ListPlayers(arena)

		-- limpiar jugadores que ya no estan
		for p in pairs(arena.Players) do
			if not p or not p.Parent then
				arena.Players[p] = nil
				arena.Kills[p] = nil
			end
		end

		if #list < Config.FFA_MIN_TO_START then
			-- no hay suficiente gente, sin papa
			if arena.Active then
				if arena.Bomb then Bomb.Destroy(arena.Bomb); arena.Bomb = nil end
				arena.Holder = nil; arena.Active = false
			end
			SendBombUI(arena)
			continue
		end

		-- si no hay papa activa, darla a alguien al azar
		if not arena.Active then
			arena.Active = true
			arena.BombTotal = math.random(Config.BOMB_MIN_TIME, Config.BOMB_MAX_TIME)
			arena.BombTime = arena.BombTotal
			arena.LastPasser = nil
			local holder = list[math.random(1, #list)]
			GiveBomb(arena, holder)
			RE_Notif:FireClient(holder, "¡TIENES LA PAPA!", "Acercate a alguien para pasarla", "danger")
		end

		-- contador de la papa
		local pct = arena.BombTime / arena.BombTotal
		local dt = 0.1
		if pct <= Config.RUSH_PCT then dt = dt * Config.RUSH_SPEED end
		arena.BombTime = math.max(0, arena.BombTime - dt)
		if arena.Bomb then Bomb.SetTimer(arena.Bomb, arena.BombTime, arena.BombTotal) end

		-- El pase ahora lo maneja la HITBOX de la papa (BombModule),
		-- que solo pasa a jugadores DENTRO de la arena al tocarlos.


		SendBombUI(arena)

		-- BOOM
		if arena.BombTime <= 0 then
			Explode(arena)
		end
	end
end

-- ============================================================
-- ENTRAR / SALIR
-- ============================================================
RE_Join.OnServerEvent:Connect(function(player, arenaName)
	if not arenaName or not Arenas[arenaName] then return end
	-- no entrar si ya esta en otra arena
	if InArena(player) then return end
	local arena = Arenas[arenaName]
	if TeleportToArena(player, arenaName) then
		arena.Players[player] = true
		arena.Kills[player] = 0
		JoinMgr:ClearZone(player)
		RE_FFAJoined:FireClient(player, { Arena = arenaName, Name = Config:DisplayName(arenaName) })
		RE_Notif:FireClient(player, "Entraste a " .. Config:DisplayName(arenaName), "¡Evita explotar!", "success")
	end
end)

-- ============================================================
-- EVENTOS DE JUGADORES
-- ============================================================
Players.PlayerAdded:Connect(function(player)
	PlayerData:Load(player)
	player.CharacterAdded:Connect(function(character)
		-- Al respawnear: SIEMPRE limpiar el estado de arena del jugador
		-- Resuelve el bug de no poder unirse despues de morir/resetear
		RemoveFromArena(player)

		task.wait(0.4)
		SendStats(player)
		local hum = character:FindFirstChild("Humanoid")
		if hum then
			hum.WalkSpeed = Config.SPEED_NORMAL
			hum.JumpPower = Config.JUMP_POWER

			-- detectar muerte natural (reset, caida al vacio, daño externo)
			hum.Died:Connect(function()
				task.wait(0.1)
				RemoveFromArena(player)
			end)
		end
	end)
end)

Players.PlayerRemoving:Connect(function(player)
	RemoveFromArena(player)
	PlayerData:Save(player)
	PlayerData:Remove(player)
end)

task.spawn(function()
	while true do
		task.wait(Config.AUTOSAVE)
		for _, p in ipairs(Players:GetPlayers()) do pcall(function() PlayerData:Save(p) end) end
	end
end)

for _, p in ipairs(Players:GetPlayers()) do PlayerData:Load(p) end
for _, name in ipairs(Config.GROUP_ARENAS) do task.spawn(ArenaLoop, Arenas[name]) end

-- ============================================================
-- EVENTOS ALEATORIOS
-- ============================================================
local function KillByEvent(arena, player, cause)
	if not arena.Players[player] then return end
	local d = PlayerData:Get(player)
	local effectId = d and d.EquippedEffect or "default"
	local pos = Vector3.new()
	if player.Character then
		local hrp = player.Character:FindFirstChild("HumanoidRootPart")
		if hrp then pos = hrp.Position end
	end
	for _, p in ipairs(ListPlayers(arena)) do
		RE_Effect:FireClient(p, effectId, player.Name, pos)
	end
	RE_Notif:FireClient(player, "💀 Moriste", "Causa: " .. cause, "danger")
	arena.Players[player] = nil
	arena.Kills[player] = nil
	ClearKillFire(player)
	if arena.Holder == player then
		if arena.Bomb then Bomb.Destroy(arena.Bomb); arena.Bomb = nil end
		arena.Holder = nil; arena.Active = false
	end
	RE_FFALeft:FireClient(player, { Arena = arena.Name })
	if player.Character then
		local hum = player.Character:FindFirstChild("Humanoid")
		if hum then hum.Health = 0 end
	end
end

for _, name in ipairs(Config.GROUP_ARENAS) do
	task.spawn(function()
		local arena = Arenas[name]
		while true do
			task.wait(math.random(45, 75))
			local function getPlayers() return ListPlayers(arena) end
			local function killP(pl, cause) KillByEvent(arena, pl, cause) end
			if #getPlayers() >= 2 then
				EventMgr:TriggerRandom(arena, getPlayers, killP)
			end
		end
	end)
end

print("[FFAManager] OK - " .. #Config.GROUP_ARENAS .. " arenas FFA continuas")
