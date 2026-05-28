-- RingBuffer.lua
-- Fixed-size SavedVariables-friendly ring buffers. They avoid table.remove()
-- shifts on hot capture paths while keeping enough recent evidence for review.

local addon = _G.BossTracker
local RingBuffer = {}
addon.Core.RingBuffer = RingBuffer

function RingBuffer.ensure(buffer, maxEntries)
	if type(buffer) ~= "table" then
		buffer = {}
	end
	buffer.max = maxEntries or buffer.max or 100
	buffer.next = buffer.next or 1
	buffer.size = buffer.size or 0
	buffer.dropped = buffer.dropped or 0
	buffer.items = type(buffer.items) == "table" and buffer.items or {}
	return buffer
end

function RingBuffer.push(buffer, value, maxEntries)
	buffer = RingBuffer.ensure(buffer, maxEntries)
	buffer.items[buffer.next] = value
	buffer.next = buffer.next + 1
	if buffer.next > buffer.max then
		buffer.next = 1
	end
	if buffer.size < buffer.max then
		buffer.size = buffer.size + 1
	else
		buffer.dropped = buffer.dropped + 1
	end
	return buffer
end

function RingBuffer.clear(buffer, maxEntries)
	buffer = RingBuffer.ensure(buffer, maxEntries)
	buffer.next = 1
	buffer.size = 0
	buffer.dropped = 0
	buffer.items = {}
	return buffer
end
