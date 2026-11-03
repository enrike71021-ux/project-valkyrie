--!strict
-- Morievskiy
-- Metrics.spec: проверяет выборки, перцентили и кольцевой буфер телеметрии.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)

local expect = JestGlobals.expect
local describe = JestGlobals.describe
local it = JestGlobals.it

local Metrics = require(script.Parent.Metrics)

describe("Metrics", function()
	-- Перцентили на наборе, где ответ известен заранее: 1..10.
	it("computes percentiles on a known sample", function()
		local metrics = Metrics.new(100)

		for value = 1, 10 do
			metrics:Add(value)
		end

		expect(metrics:Percentile(0)).toBe(1)
		expect(metrics:Percentile(25)).toBe(3)
		expect(metrics:Percentile(50)).toBe(5)
		expect(metrics:Percentile(95)).toBe(10)
		expect(metrics:Percentile(100)).toBe(10)
	end)

	it("returns the maximum of the sample", function()
		local metrics = Metrics.new(100)

		metrics:Add(3)
		metrics:Add(9)
		metrics:Add(4)

		expect(metrics:Max()).toBe(9)
	end)

	it("counts stored samples", function()
		local metrics = Metrics.new(100)

		expect(metrics:Count()).toBe(0)

		metrics:Add(1)
		metrics:Add(2)

		expect(metrics:Count()).toBe(2)
	end)

	-- Перцентиль без единой выборки — ошибка вызывающего кода, а не «тихий» ноль.
	it("fails to compute percentiles without samples", function()
		local metrics = Metrics.new(100)

		expect(function()
			metrics:Percentile(50)
		end).toThrow()

		expect(function()
			metrics:Max()
		end).toThrow()
	end)

	-- Окно фиксированной ёмкости: новая выборка затирает самую старую.
	it("keeps only the newest values when full", function()
		local metrics = Metrics.new(3)

		for value = 1, 4 do
			metrics:Add(value)
		end

		expect(metrics:Count()).toBe(3)
		-- Окно теперь {2, 3, 4}: единица вытеснена.
		expect(metrics:Max()).toBe(4)
		expect(metrics:Percentile(50)).toBe(3)
	end)

	it("clears samples", function()
		local metrics = Metrics.new(10)

		metrics:Add(5)
		metrics:Clear()

		expect(metrics:Count()).toBe(0)
	end)
end)

describe("RingBuffer", function()
	-- Порядок выдачи — от старых к новым, даже после наматывания буфера.
	it("keeps a fixed number of items in push order", function()
		local buffer = Metrics.RingBuffer.new(2)

		buffer:Push("a")
		buffer:Push("b")
		buffer:Push("c")

		expect(buffer:Count()).toBe(2)
		expect(buffer:ToTable()).toEqual({ "b", "c" })
	end)

	it("returns an empty table when nothing was pushed", function()
		local buffer = Metrics.RingBuffer.new(4)

		expect(buffer:ToTable()).toEqual({})
	end)
end)
