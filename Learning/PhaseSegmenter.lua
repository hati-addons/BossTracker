-- PhaseSegmenter.lua
-- Builds cheap, client-visible encounter segments. Segments are inferred from
-- HP bucket crossings and long activation gaps so timers are learned in the
-- phase where they actually occur before being promoted to boss-wide rules.

local addon = _G.BossTracker
local C = addon.Core.Constants

local PhaseSegmenter = {}
addon.Learning.PhaseSegmenter = PhaseSegmenter

local function ensureSegments(bossState)
	bossState.segments = type(bossState.segments) == "table" and bossState.segments or {}
	if bossState.currentSegmentKey and bossState.segments[bossState.currentSegmentKey] then
		return bossState.segments[bossState.currentSegmentKey]
	end

	local segment = {
		key = "pull",
		index = 1,
		reason = "pull_start",
		startedAt = bossState.startedAtSession,
		startedAtOffset = 0,
		startHpPct = bossState.lastHpPct,
		activationCount = 0,
	}
	bossState.segments.pull = segment
	bossState.currentSegmentKey = "pull"
	bossState.segmentIndex = 1
	return segment
end

local function segmentExists(bossState, key)
	return bossState.segments and bossState.segments[key] ~= nil
end

local function startSegment(bossState, key, reason, activation)
	ensureSegments(bossState)
	if segmentExists(bossState, key) then
		bossState.currentSegmentKey = key
		return bossState.segments[key]
	end

	bossState.segmentIndex = (bossState.segmentIndex or 1) + 1
	local startedAt = activation and activation.t or bossState.lastSeenAt or bossState.startedAtSession
	local segment = {
		key = key,
		index = bossState.segmentIndex,
		reason = reason,
		startedAt = startedAt,
		startedAtOffset = startedAt - (bossState.startedAtSession or startedAt),
		startHpPct = activation and activation.hpPct or bossState.lastHpPct,
		activationCount = 0,
	}
	bossState.segments[key] = segment
	bossState.currentSegmentKey = key

	if addon.Core.Logger and addon.Core.Logger.event then
		addon.Core.Logger.event({
			kind = "phase_segment_started",
			pullId = bossState.pullId,
			actorKey = bossState.actorKey,
			bossKey = bossState.bossKey,
			bossName = bossState.bossName,
			segmentKey = key,
			reason = reason,
			hp = segment.startHpPct,
			offset = segment.startedAtOffset,
		})
	end

	return segment
end

local function crossedHpBucket(bossState, hpPct)
	if not hpPct then
		return nil
	end

	local previousHp = bossState.lastHpPct
	if not previousHp then
		return nil
	end
	if hpPct >= previousHp - 1 then
		return nil
	end

	local crossed
	for index = 1, #C.PHASE_HP_BUCKETS do
		local bucket = C.PHASE_HP_BUCKETS[index]
		if previousHp > bucket and hpPct <= bucket then
			crossed = bucket
		end
	end
	return crossed
end

function PhaseSegmenter.assignSegment(bossState, activation)
	if not bossState then
		return nil
	end

	local segment = ensureSegments(bossState)
	if activation then
		local hpBucket = crossedHpBucket(bossState, activation.hpPct)
		if hpBucket then
			segment = startSegment(bossState, "hp_" .. tostring(hpBucket), "hp_bucket", activation)
		elseif bossState.lastActivationAt and activation.t - bossState.lastActivationAt >= C.PHASE_GAP_SECONDS then
			segment = startSegment(bossState, "gap_" .. tostring((bossState.segmentIndex or 1) + 1), "long_activation_gap", activation)
		end

		segment.activationCount = (segment.activationCount or 0) + 1
		segment.lastActivationAt = activation.t
		segment.lastHpPct = activation.hpPct or segment.lastHpPct
		bossState.lastActivationAt = activation.t
		bossState.lastHpPct = activation.hpPct or bossState.lastHpPct
	end

	return segment
end

function PhaseSegmenter.finishBoss(bossState)
	if not bossState or type(bossState.segments) ~= "table" then
		return
	end
	for _, segment in pairs(bossState.segments) do
		if not segment.endedAt then
			segment.endedAt = bossState.endedAtSession
			if segment.startedAt and segment.endedAt then
				segment.duration = segment.endedAt - segment.startedAt
			end
		end
	end
end

function PhaseSegmenter.start()
end
