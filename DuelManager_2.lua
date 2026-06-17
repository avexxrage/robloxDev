--[[
	HOT POTATO v9 - DuelManager
	Tipo: Script (azul) | Ubicacion: ServerScriptService

	Duelos 1v1 POR RONDAS:
	- Boton "LISTO" en vez de contador para empezar
	- Si no presiona LISTO en X seg, lo saca al lobby
	- Cada ronda: papa con contador; el que explota pierde la ronda
	- Gana quien pase de 5 rondas CON diferencia de 2
	  (4-5 sigue, 6-4 gana, 5-5 sigue hasta 7-5, etc.)
	- Entre rondas NO hay overlay, solo el marcador arriba
]]
local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")

local Config     = require(RS:WaitForChild("Modules"):WaitForChild("Config"))
local PlayerData = require(script.Parent:WaitForChild("PlayerData"))
local Bomb       = require(script.Parent:WaitForChild("BombModule"))
local JoinMgr    = require(script.Parent:WaitForChild("JoinManager"))

local RE = RS:WaitForChild("RemoteEvents")
local RE_DuelStart   = RE:WaitForChild("DuelStart")
local RE_DuelEnd     = RE:WaitForChild("DuelEnd")
local RE_DuelScore   = RE:WaitForChild("DuelScore")
local RE_DuelReady   = RE:WaitForChild("DuelReady")
local RE_DuelCount   = RE:WaitForChild("DuelCountdown")
local RE_BombUI      = RE:WaitForChild("UpdateBombUI")
local RE_Effect      = RE:WaitForChild("PlayEffect")
local RE_Notif       = RE:WaitForChild("ShowNotif")
local RE_Stats       = RE:WaitForChild("UpdateStats")
local RE_Join        = RE:WaitForChild("JoinArena")
local RE_FFAJoined   = RE:WaitForChild("FFAJoined")
local RE_FFALeft     = RE:WaitForChild("FFALeft")

-- Estado por arena de duelo
local Duels = {}
for _, name in ipairs(Config.DUEL_ARENAS) do
	Duels[name] = {
		Name = name,
		Waiting = {},   -- jugadores esperando (parados, deben dar LISTO)
		Ready = {},     -- { [player] = true }
		Active = false, -- duelo en curso
		pA = nil, pB = nil,
		scoreA = 0, scoreB = 0,
		holder = nil, bomb = nil,
		lastPass = {},
		roundNum = 0,
	}
end

-- decirle al JoinManager cuando un jugador esta en un duelo (esperando o jugando)
JoinMgr:RegisterBusyChecker(function(player)
	for _, duel in pairs(Duels) do
		if duel.Waiting[player] or duel.pA == player or duel.pB == player then
			return true
		end
	end
	return false
end)

local function ApplySpeed(player, speed)
	local char = player.Character
	if not char then return end
	local hum = char:FindFirstChild("Humanoid")
	if hum and hum.Health > 0 then hum.WalkSpeed = speed; hum.JumpPower = Config.JUMP_POWER end
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

local function GetSpawn(arenaName, which)
	local folder = workspace:FindFirstChild(arenaName)
	if not folder then return nil end
	return folder:FindFirstChild(which)
end

local function TeleportTo(player, arenaName, which)
	local sp = GetSpawn(arenaName, which)
	local char = player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if hrp and sp then
		hrp.CFrame = sp.CFrame + Vector3.new(0, 4, 0)
	end
	task.delay(0.2, function() ApplySpeed(player, Config.SPEED_NORMAL) end)
end

local function SendStats(player)
	local d = PlayerData:Get(player)
	if not d then return end
	RE_Stats:FireClient(player, { Coins=d.Coins, XP=d.XP, Level=d.Level, Kills=d.Kills, DuelWins=d.DuelWins })
end

local function SendScore(duel)
	local data = {
		Arena = duel.Name,
		ScoreA = duel.scoreA, ScoreB = duel.scoreB,
		NameA = duel.pA and duel.pA.Name or "?",
		NameB = duel.pB and duel.pB.Name or "?",
		Need = Config.DUEL_ROUNDS_TO_WIN,
		Round = duel.roundNum,
	}
	if duel.pA then RE_DuelScore:FireClient(duel.pA, data) end
	if duel.pB then RE_DuelScore:FireClient(duel.pB, data) end
end

-- ============================================================
-- PAPA del duelo
-- ============================================================
local function GiveBomb(duel, player)
	if duel.bomb then Bomb.Destroy(duel.bomb); duel.bomb = nil end
	local opp = (player == duel.pA) and duel.pB or duel.pA
	-- callback de hitbox: pasa al oponente al tocarlo
	local onTouch = function(touchedPlayer)
		if touchedPlayer == opp and duel.holder == player then
			local ready = (not duel.lastPass[player] or (tick()-duel.lastPass[player]) >= Config.PASS_COOLDOWN)
				and (not duel.lastPass[opp] or (tick()-duel.lastPass[opp]) >= Config.PASS_COOLDOWN)
			if ready then
				duel.lastPass[player] = tick()
				duel.lastPass[opp] = tick()
				ApplySpeed(player, Config.SPEED_NORMAL)
				GiveBomb(duel, opp)
				ApplySpeed(opp, Config.SPEED_BOMB)
				RE_Notif:FireClient(opp, "¡TIENES LA PAPA!", "¡Devuélvela!", "danger")
			end
		end
	end
	local bomb = Bomb.Attach(player, onTouch)
	if not bomb then return end
	duel.bomb = bomb
	duel.holder = player
	ApplySpeed(player, Config.SPEED_BOMB)
end

-- ¿alguien gano la partida? (pasar de 5 con diff 2)
local function CheckMatchWinner(duel)
	local need = Config.DUEL_ROUNDS_TO_WIN
	local diff = Config.DUEL_WIN_DIFF
	local a, b = duel.scoreA, duel.scoreB
	if a > need and (a - b) >= diff then return duel.pA, duel.pB end
	if b > need and (b - a) >= diff then return duel.pB, duel.pA end
	-- caso exacto: llegar a need+algo. Tambien si llega a need y tiene diff
	if a >= need and (a - b) >= diff then return duel.pA, duel.pB end
	if b >= need and (b - a) >= diff then return duel.pB, duel.pA end
	return nil
end

local function EndMatch(duel, winner, loser)
	duel.Active = false
	if duel.bomb then Bomb.Destroy(duel.bomb); duel.bomb = nil end
	duel.holder = nil

	local wd = PlayerData:Get(winner)
	if wd then
		wd.DuelWins = (wd.DuelWins or 0) + 1
		PlayerData:AddCoins(winner, Config.COINS_DUEL_WIN)
		PlayerData:AddXP(winner, Config.XP_DUEL_WIN)
		PlayerData:Save(winner)
		SendStats(winner)
	end

	if winner.Parent then
		RE_DuelEnd:FireClient(winner, { Won=true, Opponent=loser.Name, ScoreA=duel.scoreA, ScoreB=duel.scoreB })
	end
	if loser.Parent then
		RE_DuelEnd:FireClient(loser, { Won=false, Opponent=winner.Name, ScoreA=duel.scoreA, ScoreB=duel.scoreB })
	end

	task.wait(3)
	if winner.Parent then RE_FFALeft:FireClient(winner, { Arena = duel.Name }); TeleportToLobby(winner) end
	if loser.Parent then RE_FFALeft:FireClient(loser, { Arena = duel.Name }); TeleportToLobby(loser) end

	-- reset
	duel.pA = nil; duel.pB = nil; duel.scoreA = 0; duel.scoreB = 0
	duel.roundNum = 0; duel.Ready = {}; duel.lastPass = {}
	JoinMgr = JoinMgr  -- noop
end

-- Una ronda del duelo
local function PlayRound(duel)
	duel.roundNum = duel.roundNum + 1
	local pA, pB = duel.pA, duel.pB
	if not pA or not pB or not pA.Parent or not pB.Parent then
		duel.Active = false
		return
	end

	-- posicionar
	TeleportTo(pA, duel.Name, "SpawnA")
	TeleportTo(pB, duel.Name, "SpawnB")
	SendScore(duel)
	task.wait(1.5)

	-- papa al azar
	local first = math.random(1,2) == 1 and pA or pB
	duel.lastPass = {}
	GiveBomb(duel, first)
	RE_Notif:FireClient(first, "¡TIENES LA PAPA!", "Ronda " .. duel.roundNum, "danger")

	local bombTotal = math.random(Config.DUEL_BOMB_MIN, Config.DUEL_BOMB_MAX)
	local timeLeft = bombTotal

	while timeLeft > 0 do
		task.wait(0.1)
		timeLeft = math.max(0, timeLeft - 0.1)
		if not pA.Parent or not pB.Parent then duel.Active = false; return end

		local holder = duel.holder
		local opp = holder == pA and pB or pA

		-- El pase lo maneja la HITBOX de la papa (al tocar al oponente).

		-- actualizar contador en papa y UI
		if duel.bomb then Bomb.SetTimer(duel.bomb, timeLeft, bombTotal) end
		local uiData = {
			TimeLeft = timeLeft, Total = bombTotal,
			Holder = duel.holder and duel.holder.Name or "",
			IsDuel = true, Arena = duel.Name,
		}
		RE_BombUI:FireClient(pA, uiData)
		RE_BombUI:FireClient(pB, uiData)
	end

	-- BOOM: el holder pierde la ronda
	local loser = duel.holder
	local winner = loser == pA and pB or pA
	if duel.bomb then Bomb.Destroy(duel.bomb); duel.bomb = nil end
	duel.holder = nil

	-- efecto
	local d = PlayerData:Get(loser)
	local effectId = d and d.EquippedEffect or "default"
	local pos = Vector3.new()
	if loser.Character then
		local hrp = loser.Character:FindFirstChild("HumanoidRootPart")
		if hrp then pos = hrp.Position end
	end
	RE_Effect:FireClient(pA, effectId, loser.Name, pos)
	RE_Effect:FireClient(pB, effectId, loser.Name, pos)

	-- sumar punto al ganador de la ronda
	if winner == pA then duel.scoreA = duel.scoreA + 1 else duel.scoreB = duel.scoreB + 1 end
	SendScore(duel)
	-- NO overlay, solo notificacion pequena
	RE_Notif:FireClient(winner, "Ganaste la ronda", duel.scoreA .. " - " .. duel.scoreB, "success")
	RE_Notif:FireClient(loser, "Perdiste la ronda", duel.scoreA .. " - " .. duel.scoreB, "danger")

	task.wait(2)
end

-- Bucle de la partida (varias rondas)
local function RunMatch(duel)
	duel.Active = true
	duel.scoreA = 0; duel.scoreB = 0; duel.roundNum = 0

	RE_DuelStart:FireClient(duel.pA, duel.pB.Name)
	RE_DuelStart:FireClient(duel.pB, duel.pA.Name)
	SendScore(duel)

	while duel.Active do
		PlayRound(duel)
		if not duel.Active then break end
		local winner, loser = CheckMatchWinner(duel)
		if winner then
			EndMatch(duel, winner, loser)
			break
		end
	end
end

-- ============================================================
-- FASE DE ESPERA con boton LISTO
-- ============================================================
local function StartReadyPhase(duel)
	local waitingList = {}
	for p in pairs(duel.Waiting) do
		if p and p.Parent then table.insert(waitingList, p) end
	end
	if #waitingList < 2 then return end

	-- tomar los primeros 2
	local pA, pB = waitingList[1], waitingList[2]
	duel.pA = pA; duel.pB = pB
	duel.Ready = {}

	-- posicionar en spawns y pedir LISTO
	TeleportTo(pA, duel.Name, "SpawnA")
	TeleportTo(pB, duel.Name, "SpawnB")
	RE_DuelReady:FireClient(pA, { Show = true, Opponent = pB.Name, Timeout = Config.DUEL_READY_TIMEOUT })
	RE_DuelReady:FireClient(pB, { Show = true, Opponent = pA.Name, Timeout = Config.DUEL_READY_TIMEOUT })

	-- contador de espera para LISTO
	local elapsed = 0
	while elapsed < Config.DUEL_READY_TIMEOUT do
		task.wait(1)
		elapsed = elapsed + 1
		local remain = Config.DUEL_READY_TIMEOUT - elapsed
		-- avisar el contador
		if duel.pA and duel.pA.Parent then RE_DuelCount:FireClient(duel.pA, { Time = remain }) end
		if duel.pB and duel.pB.Parent then RE_DuelCount:FireClient(duel.pB, { Time = remain }) end

		-- si ambos listos, empezar ya
		if duel.Ready[pA] and duel.Ready[pB] then
			RE_DuelReady:FireClient(pA, { Show = false })
			RE_DuelReady:FireClient(pB, { Show = false })
			-- sacarlos de la cola de espera
			duel.Waiting[pA] = nil; duel.Waiting[pB] = nil
			RunMatch(duel)
			return
		end

		-- si alguno se fue
		if not pA.Parent or not pB.Parent then break end
	end

	-- timeout: sacar a quien NO presiono listo
	for _, p in ipairs({pA, pB}) do
		if not duel.Ready[p] then
			RE_DuelReady:FireClient(p, { Show = false })
			RE_Notif:FireClient(p, "No presionaste LISTO", "Te sacamos al lobby", "danger")
			duel.Waiting[p] = nil
			RE_FFALeft:FireClient(p, { Arena = duel.Name })
			TeleportToLobby(p)
		else
			-- el que si presiono listo, regresa a esperar
			RE_DuelReady:FireClient(p, { Show = false })
			RE_Notif:FireClient(p, "Tu oponente no estuvo listo", "Esperando otro retador", "info")
		end
	end
	duel.pA = nil; duel.pB = nil; duel.Ready = {}
end

-- Loop de matchmaking por arena duelo
for _, name in ipairs(Config.DUEL_ARENAS) do
	task.spawn(function()
		local duel = Duels[name]
		while true do
			task.wait(1)
			if duel.Active then continue end
			-- limpiar desconectados
			for p in pairs(duel.Waiting) do
				if not p or not p.Parent then duel.Waiting[p] = nil end
			end
			local count = 0
			for p in pairs(duel.Waiting) do if p and p.Parent then count = count + 1 end end
			if count >= 2 and not duel.pA then
				StartReadyPhase(duel)
			end
		end
	end)
end

-- ============================================================
-- EVENTOS
-- ============================================================
RE_Join.OnServerEvent:Connect(function(player, arenaName)
	if not arenaName or not Duels[arenaName] then return end
	local duel = Duels[arenaName]
	-- no entrar si ya esta esperando o jugando en algun duelo
	for _, d in pairs(Duels) do
		if d.Waiting[player] or d.pA == player or d.pB == player then return end
	end
	duel.Waiting[player] = true
	JoinMgr:ClearZone(player)
	TeleportTo(player, arenaName, "SpawnA")
	RE_FFAJoined:FireClient(player, { Arena = arenaName, Name = Config:DisplayName(arenaName), IsDuel = true })
	RE_Notif:FireClient(player, "Entraste a " .. Config:DisplayName(arenaName), "Esperando oponente...", "info")
end)

RE_DuelReady.OnServerEvent:Connect(function(player)
	for _, duel in pairs(Duels) do
		if duel.pA == player or duel.pB == player then
			duel.Ready[player] = true
			RE_Notif:FireClient(player, "¡LISTO!", "Esperando al oponente...", "success")
			return
		end
	end
end)

-- limpiar jugador de cualquier estado de duelo
local function RemoveFromDuel(player)
	for _, duel in pairs(Duels) do
		duel.Waiting[player] = nil
		duel.Ready[player] = nil
		if duel.pA == player or duel.pB == player then
			local opp = duel.pA == player and duel.pB or duel.pA
			if duel.Active and opp and opp.Parent then
				task.spawn(function() EndMatch(duel, opp, player) end)
			else
				duel.pA = nil; duel.pB = nil; duel.Active = false
				if duel.bomb then Bomb.Destroy(duel.bomb); duel.bomb = nil end
				duel.Ready = {}
			end
		end
	end
end

Players.PlayerAdded:Connect(function(player)
	player.CharacterAdded:Connect(function(character)
		-- limpiar estado al respawnear (igual que FFA)
		RemoveFromDuel(player)

		local hum = character:FindFirstChild("Humanoid")
		if hum then
			hum.Died:Connect(function()
				task.wait(0.1)
				RemoveFromDuel(player)
			end)
		end
	end)
end)

Players.PlayerRemoving:Connect(function(player)
	RemoveFromDuel(player)
end)

print("[DuelManager] OK - " .. #Config.DUEL_ARENAS .. " arenas duelo por rondas")
