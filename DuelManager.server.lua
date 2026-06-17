--[[
	HOT POTATO v14 - DuelManager (MODO POR EQUIPOS + PAPA ROBUSTA)
	Tipo: Script (azul) | Ubicacion: ServerScriptService
	*** REEMPLAZA por completo al DuelManager anterior ***

	QUE HACE:
	- Entrada por PLACAS fisicas. Cada equipo (Azul / Rojo) tiene placas.
	  El jugador se para en una placa del color del equipo que quiera.
	- Las placas aparecen dinamicamente: siempre hay 1 placa vacia por
	  equipo, hasta MAX_PER_TEAM. Al ocuparse, aparece la siguiente.
	- Cuando TODOS los que estan en placas dan LISTO (y cada equipo tiene
	  al menos MIN_PER_TEAM), las placas vacias extra DESAPARECEN y arranca
	  el contador "Entrando a la arena en 3... 2... 1...".
	- Solo DESPUES del contador se teletransporta, CON VERIFICACION.
	- La papa NO se entrega hasta confirmar que TODOS llegaron a la arena.
	  (arregla el bug de quedarse atascado en el lobby con la papa)
	- Guard de limites permanente: si quien tiene la papa se sale de la
	  arena o cae al vacio, se le regresa al instante.
	  (arregla el bug de escaparse del mapa con la papa)
	- Una sola papa, se pasa al tocar a CUALQUIER jugador en partida.
	  Quien la tiene cuando explota queda ELIMINADO. Sigue hasta que un
	  equipo se quede sin jugadores -> el otro equipo GANA.

	REQUISITOS DEL MAPA (ya los tienes, no hay que crear nada nuevo si
	tus zonas de duelo ya existen):
	- Cada arena de duelo (Config.DUEL_ARENAS) debe ser un Folder en
	  workspace con partes "SpawnA" y "SpawnB" (ya las tienes).
	- Las PLACAS aparecen donde esta tu zona de union de esa arena:
	  una parte dentro de workspace.Building con un StringValue "JoinDest"
	  cuyo Value sea el nombre de la arena. (ya las tienes)
	  Si por alguna razon no la encuentra, crea una parte llamada
	  "DuelPad_<NombreArena>" en workspace y ahi pondra las placas.
]]

local Players = game:GetService("Players")
local RS      = game:GetService("ReplicatedStorage")

local Config     = require(RS:WaitForChild("Modules"):WaitForChild("Config"))
local PlayerData = require(script.Parent:WaitForChild("PlayerData"))
local Bomb       = require(script.Parent:WaitForChild("BombModule"))
-- JoinManager ya no se usa aqui (las placas manejan la entrada a duelos)

local RE = RS:WaitForChild("RemoteEvents")
local RE_DuelStart = RE:WaitForChild("DuelStart")
local RE_DuelEnd   = RE:WaitForChild("DuelEnd")
local RE_DuelScore = RE:WaitForChild("DuelScore")
local RE_DuelReady = RE:WaitForChild("DuelReady")
local RE_DuelCount = RE:WaitForChild("DuelCountdown")
local RE_BombUI    = RE:WaitForChild("UpdateBombUI")
local RE_Effect    = RE:WaitForChild("PlayEffect")
local RE_Notif     = RE:WaitForChild("ShowNotif")
local RE_Stats     = RE:WaitForChild("UpdateStats")
local RE_FFAJoined = RE:WaitForChild("FFAJoined")
local RE_FFALeft   = RE:WaitForChild("FFALeft")

-- ============================================================
--  >>> AJUSTES (edita estos valores a tu gusto) <<<
-- ============================================================
local MAX_PER_TEAM      = 3      -- jugadores por equipo (1v1 hasta 3v3)
local MIN_PER_TEAM      = 1      -- minimo por equipo para poder empezar
local COUNTDOWN_SECONDS = 3      -- "Entrando en 3... 2... 1..."
local ARRIVE_RETRIES    = 5      -- reintentos de teletransporte
local TELEPORT_SETTLE   = 0.15   -- espera tras teletransportar (seg)
local BOUNDS_PADDING    = 10     -- studs extra alrededor de la arena (guard)
local ALLOW_PASS_TO_TEAMMATE = true  -- si false, solo se pasa al enemigo

local TEAM_A_NAME  = "Azul"
local TEAM_B_NAME  = "Rojo"
local TEAM_A_COLOR = Color3.fromRGB(45, 120, 255)
local TEAM_B_COLOR = Color3.fromRGB(255, 60, 60)

local PLATE_SIZE = Vector3.new(6, 1, 6)
local PLATE_GAP  = 8      -- separacion entre placas del mismo equipo
local PLATE_SIDE = 9      -- separacion entre los dos equipos
-- ============================================================

-- Estado por arena de duelo
local Duels = {}
for _, name in ipairs(Config.DUEL_ARENAS) do
	Duels[name] = {
		Name = name,
		Active = false,         -- hay una partida/countdown en curso
		Anchor = nil,           -- parte (lobby) donde aparecen las placas
		Plates = { A = {}, B = {} },
		PlateOcc = {},          -- [plateParte] = player
		Assign = {},            -- [player] = "A" | "B"
		Ready = {},             -- [player] = true
		Eliminated = {},        -- [player] = true (durante una partida)
		Holder = nil,           -- player que tiene la papa
		Bomb = nil,
		LastPass = {},
		SpawnCFrames = {},      -- [player] = CFrame de su spawn en la arena
		Bounds = nil,           -- { min, max, center }
		SpectatePad = nil,
		RoundAlive = false,
	}
end

-- Declaraciones adelantadas (hay llamadas circulares)
local MatchmakingTick, StartCountdownAndMatch, RunMatch, PlayTeamMatch, EndMatch, ResetDuel, GiveBomb

-- ============================================================
-- HELPERS BASICOS
-- ============================================================
local function ApplySpeed(player, speed)
	local char = player.Character
	if not char then return end
	local hum = char:FindFirstChildOfClass("Humanoid")
	if hum and hum.Health > 0 then
		hum.WalkSpeed = speed
		hum.JumpPower = Config.JUMP_POWER
	end
end

local function WaitCharReady(player, timeout)
	timeout = timeout or 4
	local t0 = os.clock()
	while os.clock() - t0 < timeout do
		local char = player.Character
		if char then
			local hrp = char:FindFirstChild("HumanoidRootPart")
			local hum = char:FindFirstChildOfClass("Humanoid")
			if hrp and hum and hum.Health > 0 then
				return char, hrp, hum
			end
		end
		task.wait(0.1)
	end
	return nil
end

local function GetSpawnAnchor(arenaName, which)
	local folder = workspace:FindFirstChild(arenaName)
	if not folder then return nil end
	return folder:FindFirstChild(which)
end

local function TeleportToLobby(player)
	local char, hrp = WaitCharReady(player, 2)
	if not hrp then return end
	local ls = workspace:FindFirstChild("LobbySpawn")
	hrp.CFrame = ls and (ls.CFrame + Vector3.new(math.random(-4,4), 4, math.random(-4,4)))
		or CFrame.new(0, 5, 0)
	task.delay(0.2, function() ApplySpeed(player, Config.SPEED_NORMAL) end)
end

-- Teletransporte VERIFICADO: mueve, espera, comprueba, reintenta.
-- Devuelve true solo si confirma que el jugador quedo en el destino.
local function TeleportVerified(player, targetCFrame)
	for _ = 1, ARRIVE_RETRIES do
		local char, hrp = WaitCharReady(player, 3)
		if not hrp then return false end
		hrp.CFrame = targetCFrame
		task.wait(TELEPORT_SETTLE)
		local hrp2 = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
		if hrp2 and (hrp2.Position - targetCFrame.Position).Magnitude <= 14 then
			return true
		end
	end
	return false
end

-- Limites de la arena (caja envolvente de todas sus partes + padding)
local function ComputeBounds(arenaName)
	local folder = workspace:FindFirstChild(arenaName)
	if not folder then return nil end
	local minV, maxV
	for _, p in ipairs(folder:GetDescendants()) do
		if p:IsA("BasePart") then
			local s = p.Size / 2
			local pmin = p.Position - s
			local pmax = p.Position + s
			if not minV then
				minV, maxV = pmin, pmax
			else
				minV = Vector3.new(math.min(minV.X, pmin.X), math.min(minV.Y, pmin.Y), math.min(minV.Z, pmin.Z))
				maxV = Vector3.new(math.max(maxV.X, pmax.X), math.max(maxV.Y, pmax.Y), math.max(maxV.Z, pmax.Z))
			end
		end
	end
	if not minV then return nil end
	minV = minV - Vector3.new(BOUNDS_PADDING, 0, BOUNDS_PADDING)
	maxV = maxV + Vector3.new(BOUNDS_PADDING, 0, BOUNDS_PADDING)
	return { min = minV, max = maxV, center = (minV + maxV) / 2 }
end

local function InBounds(pos, b)
	if pos.Y < b.min.Y - 30 then return false end          -- cayo al vacio
	if pos.X < b.min.X or pos.X > b.max.X then return false end
	if pos.Z < b.min.Z or pos.Z > b.max.Z then return false end
	return true
end

local function SendStats(player)
	local d = PlayerData:Get(player)
	if not d then return end
	RE_Stats:FireClient(player, { Coins=d.Coins, XP=d.XP, Level=d.Level, Kills=d.Kills, DuelWins=d.DuelWins })
end

local function RosterHas(roster, p)
	for _, t in ipairs({"A","B"}) do
		for _, pl in ipairs(roster[t]) do if pl == p then return true end end
	end
	return false
end

-- ============================================================
-- PLACAS
-- ============================================================
local function MakePlate(duel, team, index)
	local color = team == "A" and TEAM_A_COLOR or TEAM_B_COLOR
	local tname = team == "A" and TEAM_A_NAME or TEAM_B_NAME
	local anchor = duel.Anchor
	local cf = anchor.CFrame
	local right = cf.RightVector
	local fwd = cf.LookVector
	local side = team == "A" and -1 or 1

	local base = anchor.Position + right * (side * PLATE_SIDE)
	local pos = base + fwd * ((index - 1) * PLATE_GAP)
	pos = Vector3.new(pos.X, anchor.Position.Y - 1, pos.Z)

	local plate = Instance.new("Part")
	plate.Name = "DuelPlate_" .. duel.Name .. "_" .. team .. "_" .. index
	plate.Size = PLATE_SIZE
	plate.Anchored = true
	plate.CanCollide = false
	plate.Material = Enum.Material.Neon
	plate.Color = color
	plate.Transparency = 0.35
	plate.Position = pos
	plate.Parent = workspace

	local bb = Instance.new("BillboardGui")
	bb.Name = "Label"; bb.Size = UDim2.new(0, 190, 0, 56)
	bb.StudsOffset = Vector3.new(0, 4, 0); bb.AlwaysOnTop = true; bb.Parent = plate
	local lbl = Instance.new("TextLabel")
	lbl.Size = UDim2.new(1,0,1,0); lbl.BackgroundTransparency = 1
	lbl.Font = Enum.Font.FredokaOne; lbl.TextScaled = true
	lbl.TextColor3 = Color3.new(1,1,1); lbl.TextStrokeTransparency = 0.2
	lbl.Text = "EQUIPO " .. tname .. "\nPárate aquí"; lbl.Parent = bb

	return plate
end

local function PlayerOnPlate(hrp, plate)
	-- solo X/Z: el jugador esta sobre la placa sin importar la altura
	local dx = math.abs(hrp.Position.X - plate.Position.X)
	local dz = math.abs(hrp.Position.Z - plate.Position.Z)
	return dx <= plate.Size.X/2 + 1.5 and dz <= plate.Size.Z/2 + 1.5
end

-- Muestra placas 1..(ocupadas+1) por equipo; oculta el resto.
local function UpdatePlateVisibility(duel, team, onlyOccupied)
	local list = duel.Plates[team]
	local tname = team == "A" and TEAM_A_NAME or TEAM_B_NAME
	local occupied = 0
	for _, pl in ipairs(list) do if duel.PlateOcc[pl] then occupied += 1 end end
	local show = onlyOccupied and occupied or math.min(occupied + 1, MAX_PER_TEAM)
	for i, pl in ipairs(list) do
		local visible = i <= show
		pl.Transparency = visible and 0.35 or 1
		pl.CanTouch = visible
		local bb = pl:FindFirstChild("Label")
		if bb then bb.Enabled = visible end
		local occ = duel.PlateOcc[pl]
		local lbl = bb and bb:FindFirstChildOfClass("TextLabel")
		if lbl then
			lbl.Text = (occ and occ.Parent) and ("EQUIPO " .. tname .. "\n" .. occ.Name)
				or ("EQUIPO " .. tname .. "\nPárate aquí")
		end
	end
end

-- ============================================================
-- ESPECTADOR
-- ============================================================
local function EnsureSpectatePad(duel)
	if duel.SpectatePad and duel.SpectatePad.Parent then return end
	local b = duel.Bounds or ComputeBounds(duel.Name)
	if not b then return end
	local pad = Instance.new("Part")
	pad.Name = "SpectatePad_" .. duel.Name
	pad.Size = Vector3.new(30, 1, 30)
	pad.Anchored = true; pad.CanCollide = true; pad.Transparency = 1
	pad.Position = Vector3.new(b.center.X, b.max.Y + 25, b.center.Z)
	pad.Parent = workspace
	duel.SpectatePad = pad
end

local function SendToSpectate(duel, player)
	local pad = duel.SpectatePad
	local char, hrp = WaitCharReady(player, 1)
	if pad and hrp then
		hrp.CFrame = pad.CFrame + Vector3.new(math.random(-8,8), 4, math.random(-8,8))
	end
	ApplySpeed(player, Config.SPEED_NORMAL)
end

-- ============================================================
-- PAPA
-- ============================================================
function GiveBomb(duel, roster, player)
	if duel.Bomb then Bomb.Destroy(duel.Bomb); duel.Bomb = nil end

	local onTouch = function(touched)
		if duel.Holder ~= player then return end
		if not touched or duel.Eliminated[touched] then return end
		if touched == player or not RosterHas(roster, touched) then return end
		if not ALLOW_PASS_TO_TEAMMATE and duel.Assign[touched] == duel.Assign[player] then return end
		local now = tick()
		local cd = Config.PASS_COOLDOWN or 0.5
		if (duel.LastPass[player] and now - duel.LastPass[player] < cd)
			or (duel.LastPass[touched] and now - duel.LastPass[touched] < cd) then return end
		duel.LastPass[player] = now
		duel.LastPass[touched] = now
		ApplySpeed(player, Config.SPEED_NORMAL)
		GiveBomb(duel, roster, touched)
		ApplySpeed(touched, Config.SPEED_BOMB)
		RE_Notif:FireClient(touched, "¡TIENES LA PAPA!", "¡Pásala rápido!", "danger")
	end

	local bomb = Bomb.Attach(player, onTouch)
	if not bomb then return end
	duel.Bomb = bomb
	duel.Holder = player
	ApplySpeed(player, Config.SPEED_BOMB)
end

-- ============================================================
-- PARTIDA POR EQUIPOS (eliminacion)
-- ============================================================
local function teamAliveCount(duel, roster, team)
	local n = 0
	for _, p in ipairs(roster[team]) do
		if p.Parent and not duel.Eliminated[p] then n += 1 end
	end
	return n
end

local function alivePlayers(duel, roster)
	local list = {}
	for _, t in ipairs({"A","B"}) do
		for _, p in ipairs(roster[t]) do
			if p.Parent and not duel.Eliminated[p] then table.insert(list, p) end
		end
	end
	return list
end

function PlayTeamMatch(duel, roster)
	duel.RoundAlive = true

	-- GUARD DE LIMITES: regresa al portador si se sale de la arena
	task.spawn(function()
		while duel.RoundAlive do
			task.wait(0.15)
			local holder = duel.Holder
			if holder and holder.Parent and not duel.Eliminated[holder] then
				local char = holder.Character
				local hrp = char and char:FindFirstChild("HumanoidRootPart")
				if hrp and duel.Bounds and not InBounds(hrp.Position, duel.Bounds) then
					local cf = duel.SpawnCFrames[holder]
					if cf then hrp.CFrame = cf end
					RE_Notif:FireClient(holder, "¡Vuelve a la arena!", "No puedes salir con la papa", "danger")
				end
			end
		end
	end)

	-- bucle de eliminaciones
	while duel.RoundAlive do
		if teamAliveCount(duel, roster, "A") == 0 or teamAliveCount(duel, roster, "B") == 0 then break end
		local alive = alivePlayers(duel, roster)
		if #alive <= 1 then break end

		-- portador inicial al azar
		duel.LastPass = {}
		GiveBomb(duel, roster, alive[math.random(1, #alive)])

		local bombTotal = math.random(Config.DUEL_BOMB_MIN or 5, Config.DUEL_BOMB_MAX or 12)
		local timeLeft = bombTotal

		while timeLeft > 0 and duel.RoundAlive do
			task.wait(0.1)
			timeLeft = math.max(0, timeLeft - 0.1)

			-- si el portador se desconecto a media ronda, reasignar
			if not duel.Holder or not duel.Holder.Parent or duel.Eliminated[duel.Holder] then
				local a2 = alivePlayers(duel, roster)
				if #a2 == 0 then break end
				GiveBomb(duel, roster, a2[math.random(1, #a2)])
			end

			if duel.Bomb then Bomb.SetTimer(duel.Bomb, timeLeft, bombTotal) end
			for _, p in ipairs(alivePlayers(duel, roster)) do
				RE_BombUI:FireClient(p, {
					TimeLeft = timeLeft, Total = bombTotal,
					Holder = duel.Holder and duel.Holder.Name or "",
					IsDuel = true, Arena = duel.Name,
					TeamA = teamAliveCount(duel, roster, "A"),
					TeamB = teamAliveCount(duel, roster, "B"),
					TeamAName = TEAM_A_NAME, TeamBName = TEAM_B_NAME,
				})
			end
		end
		if not duel.RoundAlive then break end

		-- BOOM: el portador queda eliminado
		local loser = duel.Holder
		if duel.Bomb then Bomb.Destroy(duel.Bomb); duel.Bomb = nil end
		duel.Holder = nil
		if loser and loser.Parent then
			duel.Eliminated[loser] = true
			local d = PlayerData:Get(loser)
			local effectId = d and d.EquippedEffect or "default"
			local pos = Vector3.new()
			local hrp = loser.Character and loser.Character:FindFirstChild("HumanoidRootPart")
			if hrp then pos = hrp.Position end
			for _, p in ipairs(Players:GetPlayers()) do
				if RosterHas(roster, p) then RE_Effect:FireClient(p, effectId, loser.Name, pos) end
			end
			RE_Notif:FireClient(loser, "¡Explotaste!", "Eliminado", "danger")
			SendToSpectate(duel, loser)
		end
		task.wait(1.5)
	end

	duel.RoundAlive = false

	-- equipo ganador = el que tenga jugadores vivos
	local aAlive = teamAliveCount(duel, roster, "A")
	local bAlive = teamAliveCount(duel, roster, "B")
	local winners, losers, winName
	if aAlive >= bAlive then
		winners, losers, winName = roster.A, roster.B, TEAM_A_NAME
	else
		winners, losers, winName = roster.B, roster.A, TEAM_B_NAME
	end
	EndMatch(duel, roster, winners, losers, winName)
end

function RunMatch(duel, roster)
	duel.Bounds = ComputeBounds(duel.Name)
	EnsureSpectatePad(duel)

	local anchorA = GetSpawnAnchor(duel.Name, "SpawnA")
	local anchorB = GetSpawnAnchor(duel.Name, "SpawnB")
	if not anchorA or not anchorB then
		warn("[DuelManager] Faltan SpawnA/SpawnB en la arena: " .. duel.Name)
		for _, t in ipairs({"A","B"}) do for _, p in ipairs(roster[t]) do if p.Parent then TeleportToLobby(p) end end end
		ResetDuel(duel)
		return
	end

	duel.Eliminated = {}
	duel.SpawnCFrames = {}

	-- spawns repartidos por equipo (en fila, separados 5 studs)
	local function spreadCFrame(anchor, i, total)
		return anchor.CFrame * CFrame.new((i - (total + 1) / 2) * 5, 4, 0)
	end
	for i, p in ipairs(roster.A) do duel.SpawnCFrames[p] = spreadCFrame(anchorA, i, #roster.A) end
	for i, p in ipairs(roster.B) do duel.SpawnCFrames[p] = spreadCFrame(anchorB, i, #roster.B) end

	-- teletransportar a todos CON VERIFICACION
	local all = {}
	for _, t in ipairs({"A","B"}) do for _, p in ipairs(roster[t]) do table.insert(all, p) end end

	local arrived = {}
	for _, p in ipairs(all) do
		if p.Parent then
			local ok = TeleportVerified(p, duel.SpawnCFrames[p])
			arrived[p] = ok
			if ok then ApplySpeed(p, Config.SPEED_NORMAL) end
		end
	end

	-- CONFIRMAR que TODOS llegaron. Si alguno no, se aborta y NADIE recibe papa.
	for _, p in ipairs(all) do
		if p.Parent and not arrived[p] then
			for _, q in ipairs(all) do
				if q.Parent then
					RE_Notif:FireClient(q, "Error al entrar", "Reintenta el duelo", "danger")
					TeleportToLobby(q)
				end
			end
			ResetDuel(duel)
			return
		end
	end

	for _, p in ipairs(all) do
		if p.Parent then
			RE_DuelStart:FireClient(p, { Mode = "team", Arena = duel.Name, Opponent = "" })
			RE_DuelReady:FireClient(p, { Show = false })
		end
	end

	PlayTeamMatch(duel, roster)
end

function EndMatch(duel, roster, winners, losers, winName)
	if duel.Bomb then Bomb.Destroy(duel.Bomb); duel.Bomb = nil end
	duel.Holder = nil

	for _, p in ipairs(winners) do
		if p.Parent then
			local wd = PlayerData:Get(p)
			if wd then
				wd.DuelWins = (wd.DuelWins or 0) + 1
				PlayerData:AddCoins(p, Config.COINS_DUEL_WIN)
				PlayerData:AddXP(p, Config.XP_DUEL_WIN)
				PlayerData:Save(p)
				SendStats(p)
			end
			RE_DuelEnd:FireClient(p, { Won = true, Team = winName })
		end
	end
	for _, p in ipairs(losers) do
		if p.Parent then RE_DuelEnd:FireClient(p, { Won = false, Team = winName }) end
	end

	task.wait(3)
	for _, t in ipairs({"A","B"}) do
		for _, p in ipairs(roster[t]) do
			if p.Parent then
				RE_FFALeft:FireClient(p, { Arena = duel.Name })
				TeleportToLobby(p)
			end
		end
	end
	ResetDuel(duel)
end

function ResetDuel(duel)
	duel.Active = false
	duel.RoundAlive = false
	duel.Holder = nil
	if duel.Bomb then Bomb.Destroy(duel.Bomb); duel.Bomb = nil end
	duel.Eliminated = {}
	duel.LastPass = {}
	duel.SpawnCFrames = {}
	for plate in pairs(duel.PlateOcc) do duel.PlateOcc[plate] = nil end
	for p in pairs(duel.Assign) do duel.Assign[p] = nil end
	for p in pairs(duel.Ready) do duel.Ready[p] = nil end
	UpdatePlateVisibility(duel, "A")
	UpdatePlateVisibility(duel, "B")
end

-- ============================================================
-- CONTADOR + ARRANQUE (corre en su propio hilo por arena)
-- ============================================================
function StartCountdownAndMatch(duel)
	if duel.Active then return end
	duel.Active = true

	task.spawn(function()
		-- congelar roster con quienes estan en placas
		local roster = { A = {}, B = {} }
		for plate, player in pairs(duel.PlateOcc) do
			if player and player.Parent and duel.Assign[player] then
				table.insert(roster[duel.Assign[player]], player)
			end
		end

		-- ocultar placas vacias (efecto: "la otra placa desaparece")
		UpdatePlateVisibility(duel, "A", true)
		UpdatePlateVisibility(duel, "B", true)

		local function teamValid()
			local a, b = 0, 0
			for _, p in ipairs(roster.A) do if p.Parent then a += 1 end end
			for _, p in ipairs(roster.B) do if p.Parent then b += 1 end end
			return a >= MIN_PER_TEAM and b >= MIN_PER_TEAM
		end

		-- CONTADOR
		for c = COUNTDOWN_SECONDS, 1, -1 do
			for _, t in ipairs({"A","B"}) do
				for _, p in ipairs(roster[t]) do
					if p.Parent then
						RE_DuelCount:FireClient(p, { Time = c, Entering = true })
						RE_Notif:FireClient(p, "Entrando a la arena", "en " .. c .. "...", "info")
					end
				end
			end
			task.wait(1)
			if not teamValid() then
				for _, t in ipairs({"A","B"}) do
					for _, p in ipairs(roster[t]) do
						if p.Parent then
							RE_Notif:FireClient(p, "Se canceló", "Un jugador salió de la placa", "danger")
							RE_DuelReady:FireClient(p, { Show = false })
						end
					end
				end
				ResetDuel(duel)
				return
			end
		end

		RunMatch(duel, roster)
	end)
end

-- ============================================================
-- MATCHMAKING (loop rapido, NO bloquea)
-- ============================================================
function MatchmakingTick(duel)
	-- liberar placas cuyo ocupante se fue o se movio
	for plate, player in pairs(duel.PlateOcc) do
		local ok = false
		if player and player.Parent then
			local char = player.Character
			local hrp = char and char:FindFirstChild("HumanoidRootPart")
			if hrp and plate.Parent and plate.Transparency < 1 and PlayerOnPlate(hrp, plate) then ok = true end
		end
		if not ok then
			duel.PlateOcc[plate] = nil
			if player then
				duel.Assign[player] = nil
				duel.Ready[player] = nil
				if player.Parent then RE_DuelReady:FireClient(player, { Show = false }) end
			end
		end
	end

	-- asignar jugadores nuevos parados en una placa vacia visible
	for _, player in ipairs(Players:GetPlayers()) do
		if not duel.Assign[player] then
			local inOther = false
			for _, d in pairs(Duels) do
				if d ~= duel and d.Assign[player] then inOther = true break end
			end
			if not inOther then
				local char = player.Character
				local hrp = char and char:FindFirstChild("HumanoidRootPart")
				if hrp then
					for _, team in ipairs({"A","B"}) do
						for _, plate in ipairs(duel.Plates[team]) do
							if plate.Transparency < 1 and not duel.PlateOcc[plate] and PlayerOnPlate(hrp, plate) then
								duel.PlateOcc[plate] = player
								duel.Assign[player] = team
								local tn = team == "A" and TEAM_A_NAME or TEAM_B_NAME
								RE_DuelReady:FireClient(player, { Show = true, Team = tn, Arena = duel.Name, Opponent = "" })
								RE_Notif:FireClient(player, "Equipo " .. tn, "Presiona LISTO para empezar", "info")
								break
							end
						end
						if duel.Assign[player] then break end
					end
				end
			end
		end
	end

	UpdatePlateVisibility(duel, "A")
	UpdatePlateVisibility(duel, "B")

	-- condicion de inicio: todos los que estan en placas dieron LISTO,
	-- y cada equipo tiene al menos MIN_PER_TEAM listos.
	local aReady, bReady, anyOcc, allReady = 0, 0, false, true
	for plate, player in pairs(duel.PlateOcc) do
		if player and player.Parent then
			anyOcc = true
			if duel.Ready[player] then
				if duel.Assign[player] == "A" then aReady += 1 else bReady += 1 end
			else
				allReady = false
			end
		end
	end
	if anyOcc and allReady and aReady >= MIN_PER_TEAM and bReady >= MIN_PER_TEAM then
		StartCountdownAndMatch(duel)
	end
end

-- ============================================================
-- SETUP DE ARENAS
-- ============================================================
local function FindDuelAnchor(arenaName)
	local building = workspace:FindFirstChild("Building")
	if building then
		for _, part in ipairs(building:GetDescendants()) do
			if part:IsA("BasePart") and part:FindFirstChild("JoinDest")
				and part.JoinDest.Value == arenaName then
				return part
			end
		end
	end
	local fb = workspace:FindFirstChild("DuelPad_" .. arenaName)
	if fb and fb:IsA("BasePart") then return fb end
	return nil
end

local function SetupDuel(duel)
	local anchor = FindDuelAnchor(duel.Name)
	if not anchor then
		warn("[DuelManager] No encontre zona para la arena de duelo '" .. duel.Name ..
			"'. Pon una parte con JoinDest='" .. duel.Name .. "' en workspace.Building, " ..
			"o una parte llamada 'DuelPad_" .. duel.Name .. "' en workspace.")
		return false
	end
	duel.Anchor = anchor
	for _, team in ipairs({"A","B"}) do
		duel.Plates[team] = {}
		for i = 1, MAX_PER_TEAM do
			local p = MakePlate(duel, team, i)
			p.Transparency = 1; p.CanTouch = false
			local bb = p:FindFirstChild("Label"); if bb then bb.Enabled = false end
			table.insert(duel.Plates[team], p)
		end
	end
	UpdatePlateVisibility(duel, "A")
	UpdatePlateVisibility(duel, "B")
	return true
end

-- ============================================================
-- MAIN
-- ============================================================
task.spawn(function()
	task.wait(4) -- esperar a que cargue el mapa
	for _, name in ipairs(Config.DUEL_ARENAS) do
		SetupDuel(Duels[name])
	end
	while true do
		task.wait(0.3)
		for _, name in ipairs(Config.DUEL_ARENAS) do
			local duel = Duels[name]
			if duel.Anchor and not duel.Active then
				MatchmakingTick(duel)
			end
		end
	end
end)

-- ============================================================
-- EVENTOS
-- ============================================================
RE_DuelReady.OnServerEvent:Connect(function(player)
	for _, duel in pairs(Duels) do
		if duel.Assign[player] and not duel.Active then
			duel.Ready[player] = true
			RE_Notif:FireClient(player, "¡LISTO!", "Esperando a los demás...", "success")
			return
		end
	end
end)

Players.PlayerRemoving:Connect(function(player)
	for _, duel in pairs(Duels) do
		for plate, pl in pairs(duel.PlateOcc) do
			if pl == player then duel.PlateOcc[plate] = nil end
		end
		duel.Assign[player] = nil
		duel.Ready[player] = nil
		if duel.Active then
			duel.Eliminated[player] = true
			-- el bucle de la partida detecta si su equipo quedo vacio y termina
		end
	end
end)

print("[DuelManager] OK - modo EQUIPOS por placas (" .. #Config.DUEL_ARENAS .. " arenas)")
