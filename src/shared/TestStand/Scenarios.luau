--!strict
-- Morievskiy
-- Scenarios: определения нагрузочных сценариев и их проверка (сервер и клиент).
--
-- Сценарий — запись в таблице, поэтому лестницу нагрузки можно менять без правки
-- логики симуляции. Каждая запись описывает начальную расстановку двух линий
-- бойцов и длительность прогона. Числа — стартовая лестница из
-- docs/TEST_STAND_PLAN.md, а не утверждённый баланс: PERF-001 открыт.

local Config = require(script.Parent.Config)

export type Scenario = {
	-- Имя сценария: "LOAD-A", "STRESS" и так далее. Совпадает с ключом реестра.
	id: string,
	-- Человекочитаемое описание для лога и HUD.
	description: string,
	-- Ссылка на требование из docs/TESTING_AND_PERFORMANCE.md, например "TEST-001".
	covers: string,
	-- Строк в линии каждой команды.
	rowsPerTeam: number,
	-- Бойцов в строке каждой команды.
	columnsPerTeam: number,
	-- Расстояние между бойцами по вертикали (X), studs.
	-- Должно быть не меньше диаметра бойца, иначе строй родится в коллизиях.
	spacingX: number,
	-- Расстояние между бойцами по горизонтали (Z), studs.
	spacingZ: number,
	-- Отступ первой линии от центра арены по X, studs.
	spawnOffsetX: number,
	-- Длительность прогона, секунды игрового времени.
	durationSeconds: number,
	-- Сколько раз цикл «спавн до последнего выжившего» повторяется.
	-- Для обычных сценариев равен 1; LEAK крутит циклы, чтобы поймать утечки.
	cycles: number,
}

-- Реестр сценариев. Порядок записей — порядок вывода в отчёте.
local SCENARIOS: { Scenario } = {
	{
		id = "LOAD-A",
		description = "Небольшая сцена и несколько отрядов",
		covers = "TEST-001",
		rowsPerTeam = 2,
		columnsPerTeam = 15,
		spacingX = 4,
		spacingZ = 6,
		spawnOffsetX = 80,
		durationSeconds = 60,
		cycles = 1,
	},
	{
		id = "LOAD-B",
		description = "Среднее число NPC и несколько игроков",
		covers = "TEST-002",
		rowsPerTeam = 4,
		columnsPerTeam = 30,
		spacingX = 4,
		spacingZ = 6,
		spawnOffsetX = 120,
		durationSeconds = 60,
		cycles = 1,
	},
	{
		id = "LOAD-C",
		description = "Большое число отрядов",
		covers = "TEST-003",
		rowsPerTeam = 20,
		columnsPerTeam = 30,
		spacingX = 4,
		spacingZ = 6,
		spawnOffsetX = 160,
		durationSeconds = 60,
		cycles = 1,
	},
	{
		id = "LOAD-E-SYNTH",
		description = "Синтетический массовый бой в одной точке (замена TEST-005 до появления матча)",
		covers = "TEST-005",
		rowsPerTeam = 20,
		columnsPerTeam = 30,
		spacingX = 2,
		spacingZ = 2,
		spawnOffsetX = 8,
		durationSeconds = 60,
		cycles = 1,
	},
	{
		id = "STRESS",
		description = "Верхняя граница лестницы: поиск точки деградации",
		covers = "PERF-001",
		rowsPerTeam = 40,
		columnsPerTeam = 30,
		spacingX = 4,
		spacingZ = 6,
		spawnOffsetX = 160,
		durationSeconds = 60,
		cycles = 1,
	},
	{
		id = "LEAK",
		description = "Длинная сессия: 20 циклов спавна и вымирания для проверки очистки",
		covers = "TEST-006",
		rowsPerTeam = 5,
		columnsPerTeam = 30,
		spacingX = 4,
		spacingZ = 6,
		spawnOffsetX = 80,
		durationSeconds = 120,
		cycles = 20,
	},
}

local Scenarios = {}

-- Возвращает копию реестра: вызывающий код не может менять общий список.
-- Порядок обхода фиксированный (ipairs), поэтому список детерминирован.
function Scenarios.All(): { Scenario }
	local copy = {}

	for _, scenario in ipairs(SCENARIOS) do
		table.insert(copy, table.clone(scenario))
	end

	return copy
end

-- Возвращает сценарий по id. Бросает ошибку для неизвестного id:
-- молча вернуть nil — значит позволить опечатке дойти до симуляции.
function Scenarios.Get(id: string): Scenario
	for _, scenario in ipairs(SCENARIOS) do
		if scenario.id == id then
			return table.clone(scenario)
		end
	end

	error(string.format("Scenarios.Get: unknown scenario id %q", id))
end

-- Проверяет один сценарий. Возвращает true/false и текст первой найденной проблемы.
-- Проверки — барьер между описанием сценария и симуляцией: порочные числа
-- останавливаются здесь, а не в шаге симуляции.
function Scenarios.Validate(scenario: Scenario): (boolean, string?)
	if scenario.id == nil or scenario.id == "" then
		return false, "scenario id is missing"
	end

	if scenario.description == nil or scenario.description == "" then
		return false, "scenario description is missing"
	end

	if scenario.covers == nil or scenario.covers == "" then
		return false, "scenario coverage link (covers) is missing"
	end

	for key, value in
		{
			rowsPerTeam = scenario.rowsPerTeam,
			columnsPerTeam = scenario.columnsPerTeam,
			spacingX = scenario.spacingX,
			spacingZ = scenario.spacingZ,
			spawnOffsetX = scenario.spawnOffsetX,
			durationSeconds = scenario.durationSeconds,
			cycles = scenario.cycles,
		}
	do
		if type(value) ~= "number" or value <= 0 then
			return false, string.format("field %q must be a positive number", key)
		end

		if key ~= "spawnOffsetX" and value ~= math.floor(value) then
			return false, string.format("field %q must be an integer", key)
		end
	end

	if scenario.spawnOffsetX > Config.ARENA_HALF_SIZE then
		return false, "spawnOffsetX places the first line outside the arena"
	end

	-- Ширина строя обязана уложиться в арену, иначе часть бойцов родится за
	-- границей и начальная нагрузка окажется меньше заявленной.
	local halfWidth = (scenario.columnsPerTeam - 1) * scenario.spacingZ / 2

	if halfWidth >= Config.ARENA_HALF_SIZE then
		return false, "formation width does not fit the arena"
	end

	-- Расстояние между бойцами не меньше диаметра: сепарация не должна
	-- мгновенно разводить родившийся строй.
	local minimumSpacing = 2 * Config.FIGHTER_RADIUS

	if scenario.spacingX < minimumSpacing or scenario.spacingZ < minimumSpacing then
		return false, string.format("spacing must be at least the fighter diameter (%g)", minimumSpacing)
	end

	-- Длительность кратна шагу симуляции: ScenarioRunner меряет в шагах.
	local steps = scenario.durationSeconds / Config.STEP_SECONDS

	if steps ~= math.floor(steps) then
		return false, "durationSeconds must be a multiple of STEP_SECONDS"
	end

	return true, nil
end

-- Проверяет весь реестр. Возвращает true/false и текст первой проблемы.
function Scenarios.ValidateAll(): (boolean, string?)
	local seenIds = {}

	for _, scenario in ipairs(SCENARIOS) do
		local isValid, problem = Scenarios.Validate(scenario)

		if not isValid then
			return false, string.format("%s: %s", scenario.id, problem)
		end

		if seenIds[scenario.id] then
			return false, string.format("duplicate scenario id %q", scenario.id)
		end

		seenIds[scenario.id] = true
	end

	return true, nil
end

return Scenarios
