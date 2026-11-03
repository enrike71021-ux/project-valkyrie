--!strict
-- Morievskiy
-- Random: детерминированный PRNG с seed для тестового стенда (сервер и клиент).
--
-- math.random не подходит для стенда: он глобальный, не воспроизводится между
-- прогонами и не даёт два независимых потока случайных чисел. Свой PRNG
-- возвращает одинаковую последовательность для одного seed — это основа
-- воспроизводимых нагрузочных сценариев и проверки чек-сумм.
--
-- Реализация: 32-битный LCG (константы Numerical Recipes) + xorshift-перемешивание
-- выходных битов. 32-битная арифметика выбрана потому, что числа Luau — double
-- с 53-битной мантиссой: произведение 64-битных констант теряет младшие биты, а
-- (2^32-1) * 1664525 < 2^53, поэтому каждый шаг LCG остаётся точным.

local Random = {}

export type Random = {
	Next: (self: Random) -> number,
	NextInteger: (self: Random, minimum: number, maximum: number) -> number,
	NextNumber: (self: Random, minimum: number, maximum: number) -> number,
}

local MULTIPLIER = 1664525
local INCREMENT = 1013904223
local MODULUS = 0x100000000 -- 2^32
local TWO_POW_32 = 0x100000000

local RandomClass = {}
RandomClass.__index = RandomClass

-- Конструктор принимает seed — целое число от 1 и выше.
-- Возвращает объект генератора.
function Random.new(seed: number): Random
	-- Seed обязан быть натуральным: дробный seed сместил бы последовательность
	-- незаметно для вызывающего кода, а ноль даёт вырожденные хвосты у xorshift.
	assert(seed == math.floor(seed), "Random.new: seed must be an integer")
	assert(seed >= 1, "Random.new: seed must be at least 1")

	local self = setmetatable({
		state = seed % MODULUS,
	}, RandomClass)

	return self
end

-- Возвращает следующее число в [0, 1).
function RandomClass:Next(): number
	-- LCG-шаг. Произведение гарантированно меньше 2^53, поэтому шаг точен в double.
	self.state = (self.state * MULTIPLIER + INCREMENT) % MODULUS

	-- xorshift32 (13, 17, 5) через bit32: перемешивание, чтобы слабые младшие
	-- биты LCG не выходили наружу. bit32 — стандарт Roblox/Luau для битовой
	-- арифметики в 32 битах.
	local mixed = self.state
	mixed = bit32.bxor(mixed, bit32.lshift(mixed, 13))
	mixed = bit32.bxor(mixed, bit32.rshift(mixed, 17))
	mixed = bit32.bxor(mixed, bit32.lshift(mixed, 5))

	return mixed / TWO_POW_32
end

-- Возвращает целое число в [minimum, maximum], включительно.
function RandomClass:NextInteger(minimum: number, maximum: number): number
	assert(minimum == math.floor(minimum), "Random:NextInteger: minimum must be an integer")
	assert(maximum == math.floor(maximum), "Random:NextInteger: maximum must be an integer")
	assert(minimum <= maximum, "Random:NextInteger: minimum must not exceed maximum")

	if minimum == maximum then
		return minimum
	end

	local span = maximum - minimum + 1
	return minimum + math.floor(self:Next() * span)
end

-- Возвращает число в [minimum, maximum).
function RandomClass:NextNumber(minimum: number, maximum: number): number
	assert(minimum <= maximum, "Random:NextNumber: minimum must not exceed maximum")

	return minimum + self:Next() * (maximum - minimum)
end

return Random
