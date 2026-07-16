-- ctf_stats
-- ---------
-- Persistent per-player combat statistics, tracked game-wide and shown with a
-- polished /stats GUI.
--
-- Tracked per player:
--   * kills / deaths / K-D ratio
--   * current kill streak + best-ever streak
--   * shots fired / shots that hit a player / overall accuracy
--   * headshots + headshot rate
--   * time played (seconds online)
--   * per-gun breakdown: shots, hits, accuracy, kills, headshots
--   * derived favourite weapon (most kills, then most hits)
--
-- Kills/deaths come from register_on_dieplayer (works in every mode). Shooting
-- accuracy comes from the bestguns on_shot/on_hit hooks (optional dependency).
-- Everything persists in mod storage as JSON, keyed "stats_<name>".

ctf_stats = {}

local storage = minetest.get_mod_storage()

-- Dirty stats are flushed to disk (and playtime ticked) on this cadence, so a
-- burst of full-auto fire doesn't hammer the disk on every single round.
local FLUSH_INTERVAL = 15

-- A kill is credited to a specific gun only if that gun damaged the victim
-- within this many seconds of the death, so a stale earlier hit can't steal it.
local GUN_KILL_WINDOW = 12

-- [pname] = stats table. Loaded lazily; held for online players (and for any
-- offline player whose card was viewed) until flushed and dropped on leave.
local cache = {}
-- [pname] = true when a player's cached stats have unsaved changes.
local dirty = {}
-- [victim] = {attacker, gun, time}: the most recent gun damage a player took,
-- used to attribute a kill to the right gun.
local last_gun_dmg = {}

local function now()
	return minetest.get_us_time() / 1000000
end

local function new_stats()
	return {
		kills = 0, deaths = 0,
		streak = 0, best_streak = 0,
		shots = 0, hits = 0, headshots = 0,
		playtime = 0,   -- seconds online
		guns = {},      -- [gun] = {shots, hits, headshots, kills}
	}
end

-- Fetch (creating if absent) the per-gun sub-table for `gun` in stats `s`.
local function gun_row(s, gun)
	local g = s.guns[gun]
	if not g then
		g = {shots = 0, hits = 0, headshots = 0, kills = 0}
		s.guns[gun] = g
	end
	return g
end

-- True if this name has any stored/loaded stats (so /stats <name> can refuse
-- unknown names instead of showing a blank all-zero card).
local function has_record(pname)
	return cache[pname] ~= nil or storage:get_string("stats_" .. pname) ~= ""
end

-- Load a player's stats into the cache (from storage, or a fresh record).
-- Backfills any newly-added fields so old saves stay forward-compatible.
local function load(pname)
	local s = cache[pname]
	if s then return s end

	local raw = storage:get_string("stats_" .. pname)
	if raw ~= "" then
		s = minetest.parse_json(raw)
	end
	if type(s) ~= "table" then s = new_stats() end

	for k, v in pairs(new_stats()) do
		if s[k] == nil then s[k] = v end
	end
	if type(s.guns) ~= "table" then s.guns = {} end

	cache[pname] = s
	return s
end
ctf_stats.load = load
ctf_stats.has_record = has_record

local function save(pname)
	local s = cache[pname]
	if not s then return end
	storage:set_string("stats_" .. pname, minetest.write_json(s))
	dirty[pname] = nil
end

local function mark(pname)
	dirty[pname] = true
end

--------------------------------------------------------------------------------
-- Accuracy tracking (bestguns hooks)
--------------------------------------------------------------------------------

if minetest.get_modpath("bestguns") then
	-- A round left the barrel.
	function bestguns.on_shot(shooter, gun)
		local s = load(shooter)
		s.shots = s.shots + 1
		gun_row(s, gun).shots = gun_row(s, gun).shots + 1
		mark(shooter)
	end

	-- A round struck a player.
	function bestguns.on_hit(shooter, gun, target, headshot)
		local s = load(shooter)
		local g = gun_row(s, gun)
		s.hits = s.hits + 1
		g.hits = g.hits + 1
		if headshot then
			s.headshots = s.headshots + 1
			g.headshots = g.headshots + 1
		end
		mark(shooter)

		if target and target.get_player_name then
			last_gun_dmg[target:get_player_name()] = {attacker = shooter, gun = gun, time = now()}
		end
	end
end

--------------------------------------------------------------------------------
-- Kill / death tracking
--------------------------------------------------------------------------------

-- Best-effort "who killed this player". This fires for every mode, Infection
-- included: an Infection kill is a normal HP-0 death (that death is what
-- triggers the team conversion), so a gun/melee kill arrives here as a punch
-- with the killer on reason.object.
--   1. Punch death (guns, melee, ...): the puncher is the killer.
--   2. Otherwise, whoever last landed a gun hit within the kill window (our own
--      tracking, so it survives combat-mode's end_combat firing first).
--   3. Otherwise, the CTF combat mode's last hitter (environmental deaths).
local function killer_of(victim, reason)
	if reason and reason.type == "punch" and reason.object and reason.object:is_player() then
		return reason.object:get_player_name()
	end
	local ld = last_gun_dmg[victim]
	if ld and (now() - ld.time) <= GUN_KILL_WINDOW then
		return ld.attacker
	end
	if ctf_combat_mode and ctf_combat_mode.get_last_hitter then
		return (ctf_combat_mode.get_last_hitter(victim))
	end
	return nil
end

minetest.register_on_dieplayer(function(player, reason)
	local victim = player:get_player_name()
	local vs = load(victim)
	vs.deaths = vs.deaths + 1
	vs.streak = 0
	mark(victim)

	local killer = killer_of(victim, reason)
	if killer and killer ~= victim then
		local ks = load(killer)
		ks.kills = ks.kills + 1
		ks.streak = ks.streak + 1
		if ks.streak > ks.best_streak then
			ks.best_streak = ks.streak
		end

		-- Credit the kill to a gun if one recently damaged the victim.
		local ld = last_gun_dmg[victim]
		if ld and ld.attacker == killer and (now() - ld.time) <= GUN_KILL_WINDOW then
			gun_row(ks, ld.gun).kills = gun_row(ks, ld.gun).kills + 1
		end

		mark(killer)
		save(killer)
	end

	last_gun_dmg[victim] = nil
	save(victim)
end)

--------------------------------------------------------------------------------
-- Lifecycle: load on join, tick playtime, flush periodically / on leave & exit
--------------------------------------------------------------------------------

minetest.register_on_joinplayer(function(player)
	load(player:get_player_name())
end)

minetest.register_on_leaveplayer(function(player)
	local pname = player:get_player_name()
	save(pname)
	cache[pname] = nil
	last_gun_dmg[pname] = nil
end)

local flush_timer = 0
minetest.register_globalstep(function(dtime)
	for _, player in ipairs(minetest.get_connected_players()) do
		local s = cache[player:get_player_name()]
		if s then
			s.playtime = s.playtime + dtime
			dirty[player:get_player_name()] = true
		end
	end

	flush_timer = flush_timer + dtime
	if flush_timer < FLUSH_INTERVAL then return end
	flush_timer = 0
	for pname in pairs(dirty) do
		save(pname)
	end
end)

minetest.register_on_shutdown(function()
	for pname in pairs(dirty) do
		save(pname)
	end
end)

--------------------------------------------------------------------------------
-- GUI + command
--------------------------------------------------------------------------------

dofile(minetest.get_modpath("ctf_stats") .. "/gui.lua")
