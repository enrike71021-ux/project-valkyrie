--!strict
-- Morievskiy
-- Random.spec: проверяет детерминизм и границы генератора случайных чисел стенда.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)

local expect = JestGlobals.expect
local describe = JestGlobals.describe
local it = JestGlobals.it

local Random = require(script.Parent.Random)

local TEST_SEED = 42
local DRAW_COUNT = 1000

describe("Random", function()
	-- Детерминизм — основа стенда: один seed обязан давать одну и ту же последовательность.
	it("same seed gives the same sequence", function()
		local first = Random.new(TEST_SEED)
		local second = Random.new(TEST_SEED)

		for _ = 1, 10 do
			expect(first:Next()).toBe(second:Next())
		end
	end)

	it("different seeds give different sequences", function()
		local first = Random.new(1)
		local second = Random.new(2)

		expect(first:Next()).never.toBe(second:Next())
	end)

	-- Все значения Next() обязаны лежать в [0, 1): на это опираются NextInteger и NextNumber.
	it("values stay inside [0, 1)", function()
		local random = Random.new(TEST_SEED)

		for _ = 1, DRAW_COUNT do
			local value = random:Next()
			expect(value >= 0).toBe(true)
			expect(value < 1).toBe(true)
		end
	end)

	it("NextInteger returns integers inside inclusive bounds", function()
		local random = Random.new(TEST_SEED)

		for _ = 1, DRAW_COUNT do
			local value = random:NextInteger(1, 6)
			expect(value).toBe(math.floor(value))
			expect(value >= 1).toBe(true)
			expect(value <= 6).toBe(true)
		end
	end)

	-- Границы совпадают: диапазон из одного значения всегда даёт его же.
	it("NextInteger with equal bounds always returns that bound", function()
		local random = Random.new(TEST_SEED)

		for _ = 1, 100 do
			expect(random:NextInteger(3, 3)).toBe(3)
		end
	end)

	it("NextNumber returns values inside [min, max)", function()
		local random = Random.new(TEST_SEED)

		for _ = 1, DRAW_COUNT do
			local value = random:NextNumber(5, 10)
			expect(value >= 5).toBe(true)
			expect(value < 10).toBe(true)
		end
	end)

	-- Дробный или неположительный seed сломал бы воспроизводимость — конструктор обязан упасть.
	it("rejects a seed that is not a positive integer", function()
		expect(function()
			return Random.new(0)
		end).toThrow()

		expect(function()
			return Random.new(-5)
		end).toThrow()

		expect(function()
			return Random.new(1.5)
		end).toThrow()
	end)
end)
