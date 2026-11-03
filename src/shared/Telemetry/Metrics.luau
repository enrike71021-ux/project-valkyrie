--!strict
-- Morievskiy
-- Metrics: выборки с перцентилями и кольцевой буфер для телеметрии стенда (сервер и клиент).
--
-- Задача — измерять время шага и прочие величины так, чтобы отчёт был устойчив
-- к выбросам: p50/p95/p99 говорят о поведении системы лучше, чем среднее.

export type Metrics = {
	Add: (self: Metrics, value: number) -> (),
	Count: (self: Metrics) -> number,
	Percentile: (self: Metrics, fraction: number) -> number,
	Max: (self: Metrics) -> number,
	Clear: (self: Metrics) -> (),
}

export type RingBuffer = {
	Push: (self: RingBuffer, value: any) -> (),
	Count: (self: RingBuffer) -> number,
	ToTable: (self: RingBuffer) -> { any },
}

local Metrics = {}
Metrics.__index = Metrics

-- Ёмкость задаётся при создании. Она ограничивает память: стенд работает
-- подолгу, и выборка без ограничения росла бы весь матч.
function Metrics.new(capacity: number): Metrics
	assert(capacity >= 1, "Metrics.new: capacity must be at least 1")

	local self = setmetatable({
		capacity = capacity,
		samples = {},
	}, Metrics)

	return self
end

-- Добавляет выборку. Когда ёмкость исчерпана, самая старая вытесняется.
function Metrics:Add(value: number)
	local count = #self.samples

	if count >= self.capacity then
		table.remove(self.samples, 1)
		count -= 1
	end

	table.insert(self.samples, value)
end

-- Возвращает число выборок в окне.
function Metrics:Count(): number
	return #self.samples
end

-- Возвращает выборку по перцентилю в процентах: Percentile(50) — медиана,
-- Percentile(95) — p95. Проценты выбраны вместо доли 0..1, чтобы вызов читался
-- как привычные «p50/p95» из отчётов.
-- Метод ближайшего ранга (nearest-rank): p95 из 10 значений — 10-е, p50 — 5-е.
-- Сортируется копия: исходный порядок выборок менять нельзя.
function Metrics:Percentile(percent: number): number
	local count = #self.samples
	assert(count > 0, "Metrics:Percentile: no samples")
	assert(percent >= 0 and percent <= 100, "Metrics:Percentile: percent must be within [0, 100]")

	local sorted = table.clone(self.samples)
	table.sort(sorted)

	local rank = math.max(1, math.ceil(percent / 100 * count))

	return sorted[rank]
end

-- Возвращает максимум выборки.
function Metrics:Max(): number
	local count = #self.samples
	assert(count > 0, "Metrics:Max: no samples")

	local maximum = self.samples[1]

	for _, value in self.samples do
		if value > maximum then
			maximum = value
		end
	end

	return maximum
end

-- Очищает выборки, например между сценариями.
function Metrics:Clear()
	self.samples = {}
end

local RingBuffer = {}
RingBuffer.__index = RingBuffer

-- Кольцевой буфер фиксированной ёмкости: хранит последние Push-и, старые
-- вытесняются. Нужен для строк STAND_METRIC: телеметрия не должна накапливать
-- память за долгий прогон, достаточно хвоста.
Metrics.RingBuffer = RingBuffer

-- Ёмкость задаётся при создании; она же — предел роста памяти.
function Metrics.RingBuffer.new(capacity: number)
	assert(capacity >= 1, "RingBuffer.new: capacity must be at least 1")

	local self = setmetatable({
		capacity = capacity,
		items = {},
		head = 0, -- сколько всего было Push-ов; слот записи = head % capacity + 1
	}, RingBuffer)

	return self
end

-- Добавляет значение, вытесняя самое старое при переполнении.
function RingBuffer:Push(value: any)
	local slot = (self.head % self.capacity) + 1
	self.items[slot] = value
	self.head += 1
end

-- Возвращает число значений в буфере.
function RingBuffer:Count(): number
	return math.min(self.head, self.capacity)
end

-- Возвращает копию содержимого буфера в порядке от старых к новым.
function RingBuffer:ToTable(): { any }
	local stored = math.min(self.head, self.capacity)
	local result = {}

	-- Идём от самого старого живого слота к последнему записанному.
	for offset = stored, 1, -1 do
		local slot = ((self.head - offset) % self.capacity) + 1
		table.insert(result, self.items[slot])
	end

	return result
end

return Metrics
