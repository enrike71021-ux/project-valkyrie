--!strict
-- ©Brusha and Claude^_^
-- MinionController (только клиент): по нажатию клавиши Q просит сервер
-- призвать приспешника. Сам кубик клиент не создаёт, это делает сервер
-- (см. src/server/MinionService.luau).

local ContextActionService = game:GetService("ContextActionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SUMMON_ACTION_NAME = "SummonMinion"
local SUMMON_KEY = Enum.KeyCode.Q
local MOBILE_BUTTON_TITLE = "Миньон"

local remotesFolder = ReplicatedStorage:WaitForChild("Remotes")
local summonMinionRemote = remotesFolder:WaitForChild("SummonMinion") :: RemoteEvent

local MinionController = {}

-- Срабатывает при нажатии клавиши призыва (или кнопки на телефоне).
-- Принимает: название действия, состояние нажатия и сам ввод (их передаёт Roblox).
-- Возвращает: Sink, если нажатие обработано, и Pass, если нет.
local function handleSummonAction(
	_actionName: string,
	inputState: Enum.UserInputState,
	_inputObject: InputObject
): Enum.ContextActionResult
	-- Событие приходит и при нажатии, и при отпускании клавиши.
	-- Реагируем только на нажатие, иначе один удар по Q давал бы два запроса.
	if inputState ~= Enum.UserInputState.Begin then
		return Enum.ContextActionResult.Pass
	end

	-- Просто сообщаем серверу «хочу приспешника». Проверки лимита и перезарядки
	-- делает сервер: им на клиенте доверять нельзя, клиент может подменить читер.
	summonMinionRemote:FireServer()
	return Enum.ContextActionResult.Sink
end

-- Включает управление призывом. Вызывается один раз при старте клиента.
function MinionController.Start()
	-- ContextActionService, а не UserInputService: третий аргумент true
	-- автоматически добавляет кнопку на экран телефона, и игра сразу
	-- работает на мобильных устройствах.
	ContextActionService:BindAction(SUMMON_ACTION_NAME, handleSummonAction, true, SUMMON_KEY)
	ContextActionService:SetTitle(SUMMON_ACTION_NAME, MOBILE_BUTTON_TITLE)
end

return MinionController
