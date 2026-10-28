--!strict
-- ©Brusha and Claude^_^
-- MinionService (только сервер): создаёт приспешников по запросу игрока,
-- катит их за ним и убирает, когда персонаж исчезает или игрок выходит.
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

-- Один приспешник: сам кубик и «мотор», который его вращает.
-- Храним мотор рядом с кубиком, чтобы не искать его каждый раз через FindFirstChild.
type Minion = {
	part: BasePart,
	rollVelocity: AngularVelocity,
}

-- Направление «вверх» в мире. Нужно для расчёта оси вращения кубика.
local UP_DIRECTION = Vector3.new(0, 1, 0)

local MinionService = {}

-- Приспешники каждого игрока: [игрок] = список его приспешников.
-- Номер в списке — это и номер места в ряду за спиной игрока.
local minionsByPlayer: { [Player]: { Minion } } = {}

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

-- Считает точку в мире, к которой должен катиться кубик с указанным номером.
-- Принимает: HumanoidRootPart игрока и номер места (1, 2, 3...). Возвращает: позицию в мире.
local function getTargetPosition(rootPart: BasePart, slotNumber: number): Vector3
	-- Ставим кубики в ряд по центру за спиной. Например, при лимите 3
	-- номера 1, 2, 3 превращаются в -1, 0, 1 и умножаются на расстояние.
	local centerSlot = (MinionConfig.MAX_MINIONS_PER_PLAYER + 1) / 2
	local sideOffset = (slotNumber - centerSlot) * MinionConfig.SPACING_BETWEEN_MINIONS

	-- У персонажа «вперёд» — это минус Z, поэтому плюс Z означает «позади».
	-- Умножение CFrame переводит смещение «относительно игрока» в координаты мира,
	-- поэтому ряд кубиков поворачивается вместе с игроком.
	local offset = CFrame.new(sideOffset, 0, MinionConfig.DISTANCE_BEHIND_PLAYER)
	return (rootPart.CFrame * offset).Position
end

-- Создаёт кубик-приспешника рядом с игроком.
-- Принимает: игрока, его HumanoidRootPart и номер места в ряду. Возвращает: нового приспешника.
local function createMinion(player: Player, rootPart: BasePart, slotNumber: number): Minion
	local part = Instance.new("Part")
	part.Name = player.Name .. "_Minion" .. slotNumber
	part.Size = MinionConfig.MINION_SIZE
	part.Color = MinionConfig.MINION_COLOR
	part.Material = MinionConfig.MINION_MATERIAL
	part.CustomPhysicalProperties = MinionConfig.MINION_PHYSICS
	-- Не закреплён (Anchored = false), чтобы его двигала физика.
	-- Сталкивается с миром (CanCollide = true), иначе провалится сквозь землю.
	part.Anchored = false
	part.CanCollide = true
	-- Появляется на своём месте на высоте игрока и падает на землю.
	part.Position = getTargetPosition(rootPart, slotNumber)

	-- Кубик катится сам за счёт вращения: мы не двигаем его, а только крутим.
	-- Трение о землю превращает вращение в движение вперёд, как у колеса.
	-- AngularVelocity — это «мотор», который держит заданную скорость вращения.
	local attachment = Instance.new("Attachment")
	attachment.Parent = part

	local rollVelocity = Instance.new("AngularVelocity")
	rollVelocity.Name = "RollVelocity"
	rollVelocity.Attachment0 = attachment
	-- Направление вращения задаём в координатах мира, а не кубика:
	-- кубик всё время переворачивается, и его собственные оси постоянно меняются.
	rollVelocity.RelativeTo = Enum.ActuatorRelativeTo.World
	rollVelocity.MaxTorque = MinionConfig.MAX_ROLL_TORQUE
	rollVelocity.AngularVelocity = Vector3.zero
	rollVelocity.Parent = part

	part.Parent = minionsFolder

	-- Отдаём расчёт физики кубика компьютеру игрока (network ownership).
	-- Тогда кубик движется плавно у того, кто его призвал. Вызывать можно
	-- только после того, как кубик оказался в Workspace.
	part:SetNetworkOwner(player)

	return {
		part = part,
		rollVelocity = rollVelocity,
	}
end

-- Поворачивает «мотор» кубика так, чтобы он катился к своей точке.
-- Принимает: приспешника и точку в мире, к которой он должен прикатиться.
local function updateMinionRolling(minion: Minion, targetPosition: Vector3)
	local toTarget = targetPosition - minion.part.Position
	-- Высоту не учитываем: кубик катится по земле, а точка висит на уровне игрока.
	local flatToTarget = Vector3.new(toTarget.X, 0, toTarget.Z)
	local distance = flatToTarget.Magnitude

	-- Кубик сильно отстал или застрял: переносим его к игроку.
	if distance > MinionConfig.TELEPORT_DISTANCE then
		minion.part.AssemblyLinearVelocity = Vector3.zero
		minion.part.AssemblyAngularVelocity = Vector3.zero
		minion.part.CFrame = CFrame.new(targetPosition)
		minion.rollVelocity.AngularVelocity = Vector3.zero
		return
	end

	-- Кубик уже на месте: мотор с нулевой скоростью работает как тормоз.
	if distance < MinionConfig.STOP_DISTANCE then
		minion.rollVelocity.AngularVelocity = Vector3.zero
		return
	end

	-- Ось вращения перпендикулярна направлению движения и лежит в горизонтальной
	-- плоскости. Её даёт векторное произведение «вверх × направление». Так же
	-- крутится колесо: ось вбок, а едет оно вперёд.
	local direction = flatToTarget.Unit
	local rollAxis = UP_DIRECTION:Cross(direction)
	local rollSpeed = math.min(distance * MinionConfig.ROLL_SPEED_PER_STUD, MinionConfig.MAX_ROLL_SPEED)

	minion.rollVelocity.AngularVelocity = rollAxis * rollSpeed
end

-- Обновляет направление качения всех приспешников всех игроков.
local function updateAllMinions()
	for player, minions in minionsByPlayer do
		local rootPart = getAliveRootPart(player)
		if rootPart then
			for slotNumber, minion in minions do
				updateMinionRolling(minion, getTargetPosition(rootPart, slotNumber))
			end
		end
	end
end

-- Удаляет всех приспешников игрока.
-- Принимает: игрока. Ничего не возвращает.
local function destroyMinions(player: Player)
	local minions = minionsByPlayer[player]
	if not minions then
		return
	end

	for _, minion in minions do
		-- Destroy удаляет и всё внутри кубика, включая мотор.
		minion.part:Destroy()
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
	-- Иначе кубики остались бы лежать на месте старого персонажа.
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

	-- Отдельный бесконечный цикл, который рулит кубиками.
	-- task.spawn запускает его «параллельно», чтобы Start() не застрял здесь навсегда.
	task.spawn(function()
		while true do
			updateAllMinions()
			task.wait(MinionConfig.UPDATE_INTERVAL_SECONDS)
		end
	end)
end

return MinionService
