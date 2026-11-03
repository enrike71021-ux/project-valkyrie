--!strict
-- Morievskiy
-- Scenarios.spec: проверяет полноту лестницы нагрузки и отбраковку порочных сценариев.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)

local expect = JestGlobals.expect
local describe = JestGlobals.describe
local it = JestGlobals.it

local Scenarios = require(script.Parent.Scenarios)

-- Вся лестница из docs/TEST_STAND_PLAN.md, отсортированная по алфавиту id.
local EXPECTED_IDS = { "LEAK", "LOAD-A", "LOAD-B", "LOAD-C", "LOAD-E-SYNTH", "STRESS" }

-- Помощник: сценарий считается порочным, если проверка вернула false с объяснением.
local function expectInvalid(scenario: Scenarios.Scenario)
	local isValid, problem = Scenarios.Validate(scenario)

	expect(isValid).toBe(false)
	expect(problem ~= nil).toBe(true)
end

describe("Scenarios", function()
	-- Лестница нагрузки фиксируется тестом: потерянный сценарий — провал настройки.
	it("keeps the whole load ladder", function()
		local ids = {}

		for _, scenario in ipairs(Scenarios.All()) do
			table.insert(ids, scenario.id)
		end
		table.sort(ids)

		expect(ids).toEqual(EXPECTED_IDS)
	end)

	it("passes validation for every stored scenario", function()
		local isValid, problem = Scenarios.ValidateAll()

		expect(isValid).toBe(true)
		expect(problem).toBe(nil)
	end)

	it("returns a scenario by id", function()
		local scenario = Scenarios.Get("LOAD-A")

		expect(scenario.id).toBe("LOAD-A")
		expect(scenario.covers).toBe("TEST-001")
	end)

	it("errors on an unknown id", function()
		expect(function()
			Scenarios.Get("NOT-A-SCENARIO")
		end).toThrow()
	end)

	-- Отбраковка порочных чисел: нулевые размеры и шаги не должны дойти до симуляции.
	it("rejects scenarios with non-positive numbers", function()
		local scenario = Scenarios.Get("LOAD-A")

		local zeroSpacingX = table.clone(scenario)
		zeroSpacingX.spacingX = 0
		expectInvalid(zeroSpacingX)

		local zeroRows = table.clone(scenario)
		zeroRows.rowsPerTeam = 0
		expectInvalid(zeroRows)

		local zeroDuration = table.clone(scenario)
		zeroDuration.durationSeconds = 0
		expectInvalid(zeroDuration)
	end)

	-- Строй, вылезающий за границы арены, дал бы нагрузку меньше заявленной.
	it("rejects a formation that does not fit the arena", function()
		local scenario = Scenarios.Get("LOAD-A")

		local oversized = table.clone(scenario)
		oversized.spawnOffsetX = 300 -- заведомо за границей арены (256)

		expectInvalid(oversized)
	end)

	-- Сценарий утечек обязан держать заявленную нагрузку: 300 бойцов за цикл, 20 циклов.
	it("spawns 300 fighters per cycle in LEAK and repeats 20 cycles", function()
		local leak = Scenarios.Get("LEAK")

		expect(leak.rowsPerTeam * leak.columnsPerTeam * 2).toBe(300)
		expect(leak.cycles).toBe(20)
	end)

	-- Учебное правило: у каждого сценария есть человекочитаемое описание и ссылка на TEST-xxx.
	it("gives every scenario a readable description and a coverage link", function()
		for _, scenario in ipairs(Scenarios.All()) do
			expect(#scenario.description > 0).toBe(true)
			expect(#scenario.covers > 0).toBe(true)
		end
	end)
end)
