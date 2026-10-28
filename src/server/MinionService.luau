--!strict
-- ©Brusha and Claude^_^
-- MinionService (только сервер): создаёт приспешников по запросу игрока
-- и убирает их, когда персонаж исчезает или игрок выходит.
--
-- Почему всё делает сервер: клиент только «просит» призвать кубик.
-- Если бы кубик создавал сам клиент, его видел бы только этот игрок,
-- а читер мог бы наспавнить их сколько угодно. Сервер же проверяет
-- лимит и перезарядку, и созданный им кубик видят все.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local MinionConfig = require(script.Parent.MinionConfig)

-- RemoteEvent описан в default.project.json, Rojo создаёт его сам.
local remotesFolder = ReplicatedStorage:WaitForChild("Remotes")
local summonMinionRemote = remotesFolder:WaitForChild("SummonMinion") :: RemoteEvent

local MinionService = {}

-- Приспешники каждого игрока: [игрок] = список его кубиков.
local minionsByPlayer: { [Player]: { BasePart } } = {}

-- Когда игрок призывал в последний раз (os.clock()). Нужно для перезарядки.
local lastSummonTimeByPlayer: { [Player]: number } = {}

-- Подписки на события персонажа каждого игрока.
-- Храним их, чтобы отключить при выходе игрока и не допустить утечки памяти.
local characterConnectionByPlayer: { [Player]: RBXScriptConnection } = {}

-- Папка в Workspace, куда складываем всех приспешников, чтобы не засорять мир.
local minionsFolder: Folder

-- Находит центральную деталь живого персонажа игрока.
-- Принимает: игрока. Возвращает: HumanoidRootPart или nil, если персонажа нет или он мёртв.
local function getAliveRootPart(player: Player): BasePart?
	local character = player.Character
	if not character then
		return nil
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return nil
	end

	return character:FindFirstChild("HumanoidRootPart") :: BasePart?
end

-- Считает, где должен стоять кубик с указанным номером, относительно игрока.
-- Принимает: номер места (1, 2, 3...). Возвращает: смещение в координатах игрока.
local function getFollowOffset(slotNumber: number): Vector3
	-- Ставим кубики в ряд по центру за спиной. Например, при лимите 3
	-- номера 1, 2, 3 превращаются в -1, 0, 1 и умножаются на расстояние.
	local centerSlot = (MinionConfig.MAX_MINIONS_PER_PLAYER + 1) / 2
	local sideOffset = (slotNumber - centerSlot) * MinionConfig.SPACING_BETWEEN_MINIONS

	-- У персонажа «вперёд» — это минус Z, поэтому плюс Z означает «позади».
	return Vector3.new(sideOffset, MinionConfig.HEIGHT_ABOVE_ROOT, MinionConfig.DISTANCE_BEHIND_PLAYER)
end

-- Создаёт кубик-приспешника и привязывает его к игроку.
-- Принимает: игрока, его HumanoidRootPart и номер места в ряду. Возвращает: созданный кубик.
local function createMinion(player: Player, rootPart: BasePart, slotNumber: number): BasePart
	local followOffset = getFollowOffset(slotNumber)

	local minion = Instance.new("Part")
	minion.Name = player.Name .. "_Minion" .. slotNumber
	minion.Size = MinionConfig.MINION_SIZE
	minion.Color = MinionConfig.MINION_COLOR
	minion.Material = MinionConfig.MINION_MATERIAL
	-- Не закреплён (Anchored = false), чтобы его могла двигать физика.
	minion.Anchored = false
	-- Не сталкивается ни с чем, чтобы не толкать игрока и не застревать в стенах.
	minion.CanCollide = false
	-- Сразу ставим на его место, а не в центр карты.
	minion.CFrame = rootPart.CFrame * CFrame.new(followOffset)

	-- Двигаем кубик через физические ограничения (constraints), а не меняем
	-- его позицию каждый кадр вручную. Физика Roblox сама плавно тянет кубик
	-- к цели, и это почти ничего не стоит серверу.
	--
	-- Схема: точка на кубике (minionAttachment) тянется к точке
	-- за спиной игрока (targetAttachment).
	local minionAttachment = Instance.new("Attachment")
	minionAttachment.Name = "MinionAttachment"
	minionAttachment.Parent = minion

	local targetAttachment = Instance.new("Attachment")
	targetAttachment.Name = minion.Name .. "_Target"
	targetAttachment.Position = followOffset
	targetAttachment.Parent = rootPart

	-- AlignPosition тянет кубик к точке.
	local alignPosition = Instance.new("AlignPosition")
	alignPosition.Attachment0 = minionAttachment
	alignPosition.Attachment1 = targetAttachment
	alignPosition.Responsiveness = MinionConfig.FOLLOW_RESPONSIVENESS
	-- Без большой силы кубик не удержится в воздухе и упадёт под гравитацией.
	alignPosition.MaxForce = math.huge
	alignPosition.Parent = minion

	-- AlignOrientation поворачивает кубик туда же, куда смотрит игрок.
	local alignOrientation = Instance.new("AlignOrientation")
	alignOrientation.Attachment0 = minionAttachment
	alignOrientation.Attachment1 = targetAttachment
	alignOrientation.Responsiveness = MinionConfig.FOLLOW_RESPONSIVENESS
	alignOrientation.Parent = minion

	-- Когда кубик удалят, удаляем и его точку на персонаже, чтобы не оставлять мусор.
	minion.Destroying:Connect(function()
		targetAttachment:Destroy()
	end)

	minion.Parent = minionsFolder

	-- Отдаём расчёт физики кубика компьютеру игрока (network ownership).
	-- Игрок сам двигает своего персонажа, поэтому кубик, который считается
	-- там же, следует за ним без рывков и задержек. Вызывать можно только
	-- после того, как кубик оказался в Workspace.
	minion:SetNetworkOwner(player)

	return minion
end

-- Удаляет всех приспешников игрока.
-- Принимает: игрока. Ничего не возвращает.
local function destroyMinions(player: Player)
	local minions = minionsByPlayer[player]
	if not minions then
		return
	end

	for _, minion in minions do
		minion:Destroy()
	end
	minionsByPlayer[player] = nil
end

-- Проверяет, можно ли игроку сейчас призвать ещё одного приспешника.
-- Принимает: игрока. Возвращает: true, если можно.
local function canSummon(player: Player): boolean
	local lastSummonTime = lastSummonTimeByPlayer[player]
	if lastSummonTime and os.clock() - lastSummonTime < MinionConfig.SUMMON_COOLDOWN_SECONDS then
		return false
	end

	local minions = minionsByPlayer[player]
	if minions and #minions >= MinionConfig.MAX_MINIONS_PER_PLAYER then
		return false
	end

	return true
end

-- Срабатывает, когда клиент присылает запрос на призыв.
-- Принимает: игрока, который прислал запрос. Его подставляет сам Roblox,
-- подделать его клиент не может.
local function onSummonRequested(player: Player)
	-- Клиент может прислать вместе с запросом что угодно, поэтому никаких
	-- данных от него мы не берём. Всё решаем сами по состоянию на сервере.
	if not canSummon(player) then
		return
	end

	local rootPart = getAliveRootPart(player)
	if not rootPart then
		return
	end

	local minions = minionsByPlayer[player] or {}
	local slotNumber = #minions + 1

	table.insert(minions, createMinion(player, rootPart, slotNumber))
	minionsByPlayer[player] = minions
	lastSummonTimeByPlayer[player] = os.clock()
end

-- Подписывается на события нового игрока.
-- Принимает: игрока, который зашёл.
local function onPlayerAdded(player: Player)
	-- Когда персонаж исчезает (смерть, респавн), убираем его приспешников.
	-- Иначе кубики остались бы висеть на месте старого персонажа.
	characterConnectionByPlayer[player] = player.CharacterRemoving:Connect(function()
		destroyMinions(player)
	end)
end

-- Убирает всё, что связано с ушедшим игроком.
-- Принимает: игрока, который вышел.
local function onPlayerRemoving(player: Player)
	destroyMinions(player)
	lastSummonTimeByPlayer[player] = nil

	local characterConnection = characterConnectionByPlayer[player]
	if characterConnection then
		characterConnection:Disconnect()
		characterConnectionByPlayer[player] = nil
	end
end

-- Запускает систему приспешников. Вызывается один раз при старте сервера.
function MinionService.Start()
	minionsFolder = Instance.new("Folder")
	minionsFolder.Name = "Minions"
	minionsFolder.Parent = Workspace

	summonMinionRemote.OnServerEvent:Connect(onSummonRequested)

	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)

	-- Игроки, которые успели зайти до запуска этого кода (бывает в Studio),
	-- уже пропустили событие PlayerAdded, поэтому подключаем их вручную.
	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end
end

return MinionService
