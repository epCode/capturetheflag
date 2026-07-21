local S = minetest.get_translator(minetest.get_current_modname())

-- Flat score bonus awarded to each surviving winner at the end of a round.
local WIN_BONUS = 250

-- Spawn quality tiers, by clear air above the ground (headroom):
--   IDEAL_HEADROOM+  -> "great": open land, the spawns we want.
--   MIN_HEADROOM..   -> "ok"   : usable but cramped (tunnels/overhangs), fallback.
--   below MIN        -> illegal: jammed under a barrier/in a wall, never spawned on.
-- A player is 2 nodes tall, so MIN_HEADROOM must stay >= 2.
local IDEAL_HEADROOM = 5
local MIN_HEADROOM = 2
local HEADROOM_CAP = 8  -- stop counting air past this; anything >= IDEAL is "great"

-- Target size of the candidate pool sampled per spawn computation. Bigger = more
-- room for the spread pass to work with, at a small extra sampling cost.
local POOL_TARGET = 240

-- Radius around a team's anchor that its members are clustered into.
local CLUSTER_RADIUS = 6

local MAX_HP = minetest.PLAYER_MAX_HP_DEFAULT * 10

-- HP restored to a player for getting a kill, capped at their max HP. Rewards
-- pushing through a firefight in the big deathmatch/infection HP pool.
local KILL_HEAL = 100

-- Heal `killer_name` for a kill, up to their max HP. No-op for an absent/offline
-- killer (environmental deaths with no attribution, disconnects, etc.).
local function reward_kill_hp(killer_name)
	if not killer_name or killer_name == "" then return end
	local killer = minetest.get_player_by_name(killer_name)
	if not killer then return end
	local hp_max = killer:get_properties().hp_max or MAX_HP
	killer:set_hp(math.min(killer:get_hp() + KILL_HEAL, hp_max))
end

-- Grace period at the start of each round during which participants are fully
-- immune (invulnerable + non-pointable), so nobody gets spawn-killed.
local ROUND_IMMUNITY_SECONDS = 30

-- Short grace period granted to a freshly-infected player (Infection mode) so
-- they aren't instantly re-killed the moment they switch sides.
local INFECT_IMMUNITY_SECONDS = 3

--------------------------------------------------------------------------------
-- Shared module
--------------------------------------------------------------------------------

ctf_mode_deathmatch = {
	-- [pname] = true while the player is an active (living) combatant this round
	alive = {},

	-- [pname] = saved state table while the player is a spectator
	spectators = {},

	-- true once a round is allocated and may end via elimination
	round_active = false,

	-- true only while ctf_mode_deathmatch.allocate_teams() is assigning teams
	round_starting = false,

	-- [pname] = true while an Infection team-switch is in progress. Lets
	-- on_allocplayer tell a conversion apart from a genuine mid-round join (which
	-- should spectate) so the infected player keeps fighting instead.
	converting = {},

	-- [pname] = position the player last died at (Infection revives them there,
	-- right next to whoever infected them).
	death_pos = {},

	-- [victim_pname] = { [hitter_pname] = total_damage } accumulated this life.
	-- Infection reads this on death to send the victim to the team that hurt them
	-- most, then clears the victim's entry so the next life starts fresh.
	damage_dealt = {},

	-- [tname] = pname of the player who founded that Infection colour team at round
	-- start. This is the team's permanent name for the whole round: it never
	-- changes, even if the founder is infected away onto another team and later
	-- comes back. See dm.team_label().
	team_owner = {},

	-- [pname] = the teammate a freshly-infected player should reappear beside when
	-- their respawn countdown finishes (the player who infected them). Cleared once
	-- they respawn; the target is re-validated then in case it died in the interim.
	pending_respawn = {},

	-- [pname] = saved "main" inventory list (as item strings), taken when a player
	-- dies. Infection preserves inventory across a death and respawn WITHIN a round
	-- (the shared respawn code would otherwise wipe and re-gear them), but not
	-- across rounds. See snapshot_inv()/restore_inv().
	saved_inv = {},
}
local dm = ctf_mode_deathmatch

--------------------------------------------------------------------------------
-- Infection team pool
--------------------------------------------------------------------------------

-- Infection starts every player on their own solo team, so it needs many more
-- teams than the handful of fixed colours ctf_teams ships with. dm.register_
-- infection_teams() registers a pool of distinctly-coloured teams up front; the
-- ordered list of their names lives here. They are flagged not_playing so no
-- other mode (e.g. free-for-all Death Match) ever hands them out.
dm.infection_teams = {}

-- Set form of the above, for O(1) "is this an infection team?" validation.
dm.infection_team_set = {}

-- Converts an HSV colour (h in degrees, s/v in 0..1) to a "#rrggbb" string.
local function hsv_to_hex(h, s, v)
	h = h % 360
	local c = v * s
	local x = c * (1 - math.abs((h / 60) % 2 - 1))
	local m = v - c
	local r, g, b
	if     h <  60 then r, g, b = c, x, 0
	elseif h < 120 then r, g, b = x, c, 0
	elseif h < 180 then r, g, b = 0, c, x
	elseif h < 240 then r, g, b = 0, x, c
	elseif h < 300 then r, g, b = x, 0, c
	else                r, g, b = c, 0, x end
	return string.format("#%02x%02x%02x",
		math.floor((r + m) * 255 + 0.5),
		math.floor((g + m) * 255 + 0.5),
		math.floor((b + m) * 255 + 0.5))
end

-- The ten team colours, handed out in this order. This also caps the number of
-- teams (players beyond the tenth spectate until the next round).
local INFECTION_BASE_COLORS = {
	"#ff0000", -- red
	"#00c000", -- green
	"#2050ff", -- blue
	"#ffe000", -- yellow
	"#00c4c4", -- teal
	"#8b4513", -- brown
	"#1c1c1c", -- black
	"#ffffff", -- white
	"#ff8000", -- orange
	"#9b1fff", -- purple
}

-- Registers `count` distinctly-coloured solo teams for Infection. Call once at
-- load time (idempotent). Registered late so the per-team node/registration
-- loops in ctf_teams (chests, doors, traps) don't run for these throwaway teams.
function dm.register_infection_teams(count)
	for i = 1, count do
		local tname = "infect_" .. i
		if not ctf_teams.team[tname] then
			-- Use the curated bold palette first; only once it runs out do we
			-- fall back to generated bright, fully-saturated hues.
			local color = INFECTION_BASE_COLORS[i]
			if not color then
				color = hsv_to_hex((i * 137.508) % 360, 1, 1)
			end

			ctf_teams.team[tname] = {
				color = color,
				color_hex = tonumber("0x" .. color:sub(2)),
				irc_color = 16,
				not_playing = true,
			}
			table.insert(ctf_teams.teamlist, tname)
			table.insert(dm.infection_teams, tname)
			dm.infection_team_set[tname] = true
		end
	end
end

--------------------------------------------------------------------------------
-- Infection colour preference (a persisted "favourite colour" queue)
--------------------------------------------------------------------------------

-- Per-player tally of how many rounds they have spent on each colour, saved in
-- mod storage. It's keyed by the colour's hex string (stable even if the team
-- pool or its ordering changes later), not by team name. Infection allocation
-- reads it to hand each player their most-used colour that is still free, then
-- their next-most-used, and so on down their personal queue.
local storage = minetest.get_mod_storage()

-- [pname] = { [color_hex] = count }, lazily loaded from storage.
dm.color_counts = {}

-- The colour-hex key a team is tracked under (falls back to the team name).
local function team_color_key(tname)
	local team = ctf_teams.team[tname]
	return (team and team.color) or tname
end

local function load_color_counts(pname)
	local c = dm.color_counts[pname]
	if c then return c end

	c = {}
	local raw = storage:get_string("colorcount_" .. pname)
	if raw ~= "" then
		local parsed = minetest.parse_json(raw)
		if type(parsed) == "table" then c = parsed end
	end

	dm.color_counts[pname] = c
	return c
end

-- The player's lifetime count for the colour of team `tname` (0 if never).
local function color_use_count(pname, tname)
	return load_color_counts(pname)[team_color_key(tname)] or 0
end

-- Record that `pname` was given team `tname`'s colour for a round, and persist.
local function record_color_use(pname, tname)
	local c = load_color_counts(pname)
	local key = team_color_key(tname)
	c[key] = (c[key] or 0) + 1
	storage:set_string("colorcount_" .. pname, minetest.write_json(c))
end

--------------------------------------------------------------------------------
-- Spawn point generation (players spawn where they can't see one another)
--------------------------------------------------------------------------------

-- How far inside the play-field walls spawns are kept.
local FIELD_MARGIN = 8

-- Reads the play field once and returns a surface finder plus the horizontal
-- bounds (inset from the walls) that spawns should be sampled within.
local function make_surface_finder(map)
	-- The barrier_area is the actual enclosed play field; fall back to the map
	-- bounds for old maps that don't define one.
	local field1 = map.barrier_area and map.barrier_area.pos1 or map.pos1
	local field2 = map.barrier_area and map.barrier_area.pos2 or map.pos2
	field1, field2 = vector.sort(field1, field2)

	local vm = VoxelManip()
	local emin, emax = vm:read_from_map(field1, field2)
	local area = VoxelArea:new({MinEdge = emin, MaxEdge = emax})
	local data = vm:get_data()

	local c_air = minetest.CONTENT_AIR
	local c_ignore = minetest.CONTENT_IGNORE

	-- Classifies a node for spawning purposes:
	--   "ground" -> stand on top of it
	--   "block"  -> unsafe column, don't spawn here at all (liquids, hazards)
	--   "skip"   -> ignore and keep scanning downward (air, barriers, plants...)
	local class_cache = {}
	local function classify(cid)
		if cid == c_air or cid == c_ignore then
			return "skip"
		end

		local cached = class_cache[cid]
		if cached then
			return cached
		end

		local name = minetest.get_name_from_content_id(cid)
		local def = minetest.registered_nodes[name]
		local result

		if not def then
			result = "skip"
		elseif (def.groups and (def.groups.immortal or def.groups.leaves)) or name:find("ctf_map:ind") then
			-- Map boundary/indestructible barriers (the "roof"/walls) and tree
			-- canopies: scan past them to the real ground below.
			result = "skip"
		elseif def.liquidtype and def.liquidtype ~= "none" then
			result = "block"
		elseif def.damage_per_second and def.damage_per_second > 0 then
			result = "block"
		elseif def.walkable and def.drawtype ~= "airlike" then
			result = "ground"
		else
			result = "skip"
		end

		class_cache[cid] = result
		return result
	end

	-- Returns the standing position (feet) on the first solid, safe ground at
	-- x,z, skipping past barriers/canopies, plus the headroom (count of clear air
	-- nodes above the ground, capped at HEADROOM_CAP). Returns nil for unsuitable
	-- columns: outside the field, over a hazard, or with less than MIN_HEADROOM
	-- air (jammed under a barrier/overhang, i.e. an illegal in-the-wall spot).
	local function surface_at(x, z)
		if x < field1.x or x > field2.x or z < field1.z or z > field2.z then
			return nil
		end

		-- Scan strictly inside the field so we never land on the ceiling/walls.
		for y = field2.y - 1, field1.y + 1, -1 do
			local result = classify(data[area:index(x, y, z)])
			if result == "ground" then
				-- Measure the clear-air column above the ground. This is the spawn
				-- quality signal: open sky scores high, a 2-node tunnel scores low,
				-- anything under MIN_HEADROOM is rejected outright.
				local air = 0
				for h = 1, HEADROOM_CAP do
					local yy = y + h
					if yy > field2.y or data[area:index(x, yy, z)] ~= c_air then
						break
					end
					air = air + 1
				end

				if air < MIN_HEADROOM then
					return nil
				end
				return vector.new(x, y + 1, z), air
			elseif result == "block" then
				return nil
			end
		end

		return nil
	end

	-- Bounds spawns should be sampled within (inset from the field walls).
	local b1 = vector.new(field1.x + FIELD_MARGIN, field1.y, field1.z + FIELD_MARGIN)
	local b2 = vector.new(field2.x - FIELD_MARGIN, field2.y, field2.z - FIELD_MARGIN)

	return surface_at, b1, b2
end

-- Farthest-point sampling: greedily grows `chosen` (a list of positions) until
-- it holds `want` of them, each time adding the pool candidate whose distance to
-- the nearest already-chosen point is largest. This maximises the minimum spacing
-- between spawns -> players end up as spread out as the map allows, on opposite
-- sides rather than clumped. Candidates are {pos = vector, air = headroom}.
-- Seeds (when `chosen` is empty) from the most open candidate so the spread grows
-- out from the best spot.
local function farthest_point_select(pool, want, chosen)
	chosen = chosen or {}
	if #pool == 0 then
		return chosen
	end

	if #chosen == 0 then
		local best = pool[1]
		for _, c in ipairs(pool) do
			if c.air > best.air then best = c end
		end
		table.insert(chosen, best.pos)
	end

	while #chosen < want do
		local best_pos, best_d = nil, -1
		for _, c in ipairs(pool) do
			-- Distance to the nearest spawn already committed.
			local nearest = math.huge
			for _, s in ipairs(chosen) do
				local d = vector.distance(c.pos, s)
				if d < nearest then nearest = d end
			end
			if nearest > best_d then
				best_d, best_pos = nearest, c.pos
			end
		end
		if not best_pos then break end
		table.insert(chosen, best_pos)
	end

	return chosen
end

-- team_members: { teamname = {pname, ...}, ... }
-- Returns { [pname] = position } for every alive player passed in.
function dm.compute_spawns(map, team_members)
	local surface_at, b1, b2 = make_surface_finder(map)

	-- Sample random columns and bucket the legal ones by quality. `great` = open
	-- land (>= IDEAL_HEADROOM air), `ok` = cramped-but-usable. Illegal columns
	-- (in walls, over hazards, jammed under barriers) are dropped by surface_at.
	-- Positions are de-duplicated by x,z so the spread pass sees distinct spots.
	local great, ok = {}, {}
	local seen = {}
	for _ = 1, POOL_TARGET * 5 do
		if #great + #ok >= POOL_TARGET then break end
		local x = math.random(b1.x, b2.x)
		local z = math.random(b1.z, b2.z)
		local key = x * 100000 + z
		if not seen[key] then
			seen[key] = true
			local p, air = surface_at(x, z)
			if p then
				local cand = {pos = p, air = air}
				if air >= IDEAL_HEADROOM then
					table.insert(great, cand)
				else
					table.insert(ok, cand)
				end
			end
		end
	end

	local teamnames = {}
	for tname in pairs(team_members) do
		table.insert(teamnames, tname)
	end
	table.sort(teamnames)
	local count = #teamnames

	-- Prefer the "great" pool: spread anchors across the open-land spots. Only if
	-- there aren't enough of them do we top up from "ok", continuing the same
	-- spread pass so the cramped fallbacks still sit far from everyone else.
	local anchors
	if #great >= count then
		anchors = farthest_point_select(great, count)
	else
		anchors = farthest_point_select(great, #great)
		anchors = farthest_point_select(ok, count, anchors)
	end

	-- Last-resort anchor: the most open candidate found, then the field centre.
	local best_any = great[1] or ok[1]
	local fallback = (best_any and best_any.pos) or
		surface_at(math.floor((b1.x + b2.x) / 2), math.floor((b1.z + b2.z) / 2)) or
		map.flag_center

	local result = {}
	for i, tname in ipairs(teamnames) do
		local anchor = anchors[i] or fallback

		for _, pname in ipairs(team_members[tname]) do
			local pos = anchor

			-- Cluster teammates near the anchor (members > 1).
			if #team_members[tname] > 1 then
				for _ = 1, 20 do
					local cand = surface_at(
						anchor.x + math.random(-CLUSTER_RADIUS, CLUSTER_RADIUS),
						anchor.z + math.random(-CLUSTER_RADIUS, CLUSTER_RADIUS)
					)
					if cand and math.abs(cand.y - anchor.y) <= CLUSTER_RADIUS then
						pos = cand
						break
					end
				end
			end

			result[pname] = pos
		end
	end

	return result
end

local function teleport_player(player, pos)
	local function apply()
		if player:is_player() then
			player:set_pos(vector.offset(pos, 0, 0.5, 0))
		end
	end

	apply()
	-- Re-apply shortly after to defeat the engine respawn-position race.
	minetest.after(0.1, apply)
end

-- Is `pos` (feet) a safe place to stand: solid, non-hazard ground underneath and
-- two nodes of clear air for the player's body? Reads the live map, so it only
-- works where the area is loaded (always true right next to another player).
local function is_safe_standing(pos)
	local below = minetest.registered_nodes[minetest.get_node(vector.offset(pos, 0, -1, 0)).name]
	local feet  = minetest.registered_nodes[minetest.get_node(pos).name]
	local head  = minetest.registered_nodes[minetest.get_node(vector.offset(pos, 0, 1, 0)).name]
	if not (below and feet and head) then return false end
	if not below.walkable or below.drawtype == "airlike" then return false end
	if below.damage_per_second and below.damage_per_second > 0 then return false end
	if below.liquidtype and below.liquidtype ~= "none" then return false end
	if feet.walkable or head.walkable then return false end
	return true
end

-- Finds a safe standing spot within `radius` of `center` (a teammate's position),
-- so an infected player reappears beside them without landing in a wall or on a
-- hazard. Returns nil if nothing suitable turned up nearby.
local function safe_spot_near(center, radius)
	radius = radius or CLUSTER_RADIUS
	for _ = 1, 30 do
		local x = center.x + math.random(-radius, radius)
		local z = center.z + math.random(-radius, radius)
		for y = math.ceil(center.y) + 3, math.floor(center.y) - 8, -1 do
			local p = vector.new(x, y, z)
			if is_safe_standing(p) then
				return p
			end
		end
	end
	return nil
end

-- The name an Infection team goes by: its founder, fixed for the whole round.
-- Falls back to the raw team name only if the team was somehow never founded.
function dm.team_label(tname)
	return dm.team_owner[tname] or HumanReadable(tname)
end

-- Save a player's current "main" inventory (as item strings, preserving metadata
-- such as loaded magazines) so it can be brought back after the shared respawn /
-- new-match code wipes it.
local function snapshot_inv(pname)
	local player = minetest.get_player_by_name(pname)
	if not player then return end

	local out = {}
	for i, stack in ipairs(player:get_inventory():get_list("main")) do
		out[i] = stack:to_string()
	end
	dm.saved_inv[pname] = out
end

-- Authoritatively set a player's "main" inventory to their saved snapshot (empty
-- if none). Used in Infection where there is no initial stuff: it both restores
-- what they had and guarantees the shared "give initial stuff" is undone.
local function restore_inv(player)
	player:get_inventory():set_list("main", dm.saved_inv[player:get_player_name()] or {})
end

-- Infection has no spectators: a player who joins mid-round is dropped straight
-- into the field on a (random) existing team with a short immunity, instead of
-- being benched until the next round.
local function infection_join_midround(player)
	local pname = player:get_player_name()
	dm.alive[pname] = true

	local map = ctf_map.current_map
	if map then
		local team = ctf_teams.get(pname)
		local spawns = team and dm.compute_spawns(map, {[team] = {pname}})
		local pos = spawns and spawns[pname]
		if pos then
			teleport_player(player, pos)
		elseif map.flag_center then
			player:set_pos(map.flag_center)
		end
	end

	ctf_modebase.give_immunity(player, INFECT_IMMUNITY_SECONDS)

	dm.update_roster_hud()
end

-- Two-colour particle burst played when a player is infected: a puff in their
-- old team colour and one in the colour of the team they just joined.
function dm.infection_burst(pos, old_color, new_color)
	pos = vector.offset(pos, 0, 1, 0)

	local function puff(color)
		minetest.add_particlespawner({
			amount = 35,
			time = 0.1,
			minpos = vector.offset(pos, -0.3, -0.3, -0.3),
			maxpos = vector.offset(pos, 0.3, 0.3, 0.3),
			minvel = {x = -3, y = 1, z = -3},
			maxvel = {x = 3, y = 5, z = 3},
			minacc = {x = 0, y = -6, z = 0},
			maxacc = {x = 0, y = -9, z = 0},
			minexptime = 0.4,
			maxexptime = 1.0,
			minsize = 1.5,
			maxsize = 3.5,
			texture = "default_item_smoke.png^[colorize:" .. color .. ":220",
			glow = 8,
		})
	end

	puff(old_color or "#ffffff")
	puff(new_color or "#ffffff")
end

--------------------------------------------------------------------------------
-- Spectator handling (dead players + mid-round joiners sit out the round)
--------------------------------------------------------------------------------

local function grant_spectator_privs(pname)
	local privs = minetest.get_player_privs(pname)
	local saved = {fly = privs.fly, noclip = privs.noclip, interact = privs.interact}

	privs.fly = true
	privs.noclip = true
	-- Revoke interact so spectators can't dig, place, take from chests or fire weapons.
	privs.interact = nil
	minetest.set_player_privs(pname, privs)

	return saved
end

local function restore_privs(pname, saved)
	local privs = minetest.get_player_privs(pname)

	if not saved.fly then privs.fly = nil end
	if not saved.noclip then privs.noclip = nil end
	if saved.interact then privs.interact = true end

	minetest.set_player_privs(pname, privs)
end

function dm.make_spectator(player, mid_join)
	local pname = player:get_player_name()

	dm.alive[pname] = nil

	if not dm.spectators[pname] then
		local props = player:get_properties()
		dm.spectators[pname] = {
			privs = grant_spectator_privs(pname),
			visual_size = props.visual_size,
			makes_footstep_sound = props.makes_footstep_sound,
		}
	end

	ctf_modebase.remove_immunity(player)

	player:set_properties({
		hp_max = MAX_HP,
		pointable = false,
		collide_with_objects = false,
		makes_footstep_sound = false,
		visual_size = {x = 0, y = 0, z = 0},
	})
	player:set_hp(MAX_HP)
	player:set_armor_groups({immortal = 1})
	player:get_inventory():set_list("main", {})

	-- Hide health displays while spectating (they are immortal anyway): both the
	-- over-head HP bar and the on-screen HP statbar.
	if hpbar then hpbar.set_hidden(player, true) end
	if hpbar_hud then hpbar_hud.set_hidden(player, true) end

	-- Float in place so they can drift around and watch.
	physics.set(pname, "ctf_mode_deathmatch:spectator", {gravity = 0, speed = 1.5, jump = 1})

	playertag.set(player, playertag.TYPE_BUILTIN, {a = 0, r = 255, g = 255, b = 255})
	player:set_nametag_attributes({text = " ", color = {a = 0, r = 255, g = 255, b = 255}})

	-- Dismiss the death screen if it is showing
	minetest.close_formspec(pname, "")

	hud_events.new(player, {
		quick = false,
		text = mid_join and S("Round in progress - you will join the next round")
			or S("You are out! Spectating until the next round"),
		color = "warning",
	})

	if ctf_map.current_map then
		player:set_pos(vector.offset(ctf_map.current_map.flag_center, 0, 12, 0))
	end
end

function dm.restore_spectator(player)
	local pname = player:get_player_name()
	local saved = dm.spectators[pname]
	if not saved then return end

	dm.spectators[pname] = nil

	physics.remove(pname, "ctf_mode_deathmatch:spectator")
	restore_privs(pname, saved.privs)

	player:set_properties({
		hp_max = MAX_HP,
		pointable = true,
		collide_with_objects = true,
		makes_footstep_sound = saved.makes_footstep_sound ~= false,
		visual_size = saved.visual_size or {x = 1, y = 1, z = 1},
	})
	player:set_armor_groups({fleshy = 100})
	if hpbar then hpbar.set_hidden(player, false) end
	if hpbar_hud then hpbar_hud.set_hidden(player, false) end
end

-- Restore everyone to a normal state when a match ends (for any mode).
ctf_api.register_on_match_end(function()
	dm.round_active = false

	dm.clear_roster_hud()

	for pname in pairs(table.copy(dm.spectators)) do
		local player = minetest.get_player_by_name(pname)
		if player then
			dm.restore_spectator(player)
		else
			dm.spectators[pname] = nil
		end
	end

	dm.spectators = {}
	dm.alive = {}
	dm.converting = {}
	dm.death_pos = {}
	dm.damage_dealt = {}
	dm.team_owner = {}
	dm.pending_respawn = {}
	dm.saved_inv = {}
end)

--------------------------------------------------------------------------------
-- Infection team roster HUD (top-right list of teams + their living members)
--------------------------------------------------------------------------------

-- One header element plus a fixed pool of line elements per player. We reuse the
-- same elements across updates (hud_change) rather than removing/re-adding them,
-- so the roster never flickers. [pname] = {header = id, lines = {id, ...}}
dm.roster_hud = {}

-- Caps the number of teams shown; matches the Infection team pool size.
local ROSTER_MAX_LINES = 10
-- Vertical spacing between roster lines, in pixels.
local ROSTER_LINE_H = 18
-- Distance the whole roster is nudged in from the top-right corner.
local ROSTER_INSET_X = -10
local ROSTER_INSET_Y = 12

-- Lazily create (once) the HUD elements this player's roster is drawn with.
local function ensure_roster_hud(player)
	local pname = player:get_player_name()
	local h = dm.roster_hud[pname]
	if h then return h end

	h = {lines = {}}

	h.header = player:hud_add({
		hud_elem_type = "text",
		position = {x = 1, y = 0},
		alignment = {x = -1, y = 1},
		offset = {x = ROSTER_INSET_X, y = ROSTER_INSET_Y},
		text = "",
		number = 0xFFFFFF,
		style = 1, -- bold
		z_index = 100,
	})

	for i = 1, ROSTER_MAX_LINES do
		h.lines[i] = player:hud_add({
			hud_elem_type = "text",
			position = {x = 1, y = 0},
			alignment = {x = -1, y = 1},
			offset = {x = ROSTER_INSET_X, y = ROSTER_INSET_Y + i * ROSTER_LINE_H},
			text = "",
			number = 0xFFFFFF,
			z_index = 100,
		})
	end

	dm.roster_hud[pname] = h
	return h
end

-- Rebuilds the "who is on which team" roster and pushes it to every connected
-- player. Each team gets one line, listing its living members, drawn in that
-- team's colour so the colour itself identifies the team. Called from Infection
-- whenever team membership changes (round start, infection, join, leave).
function dm.update_roster_hud()
	-- Group living players by team.
	local members = {}
	for pname in pairs(dm.alive) do
		local team = ctf_teams.get(pname)
		if team then
			members[team] = members[team] or {}
			table.insert(members[team], pname)
		end
	end

	-- Only list teams that still have players, in the stable team-list order.
	local order = {}
	for _, tname in ipairs(ctf_teams.current_team_list) do
		if members[tname] then
			table.sort(members[tname])
			table.insert(order, tname)
		end
	end

	for _, player in ipairs(minetest.get_connected_players()) do
		local h = ensure_roster_hud(player)

		player:hud_change(h.header, "text", #order > 0 and "Teams" or "")

		for i = 1, ROSTER_MAX_LINES do
			local tname = order[i]
			if tname then
				local team = ctf_teams.team[tname]
				-- Each team is titled by its founder (fixed for the round), then its
				-- current living members.
				local text = dm.team_label(tname) .. ": " .. table.concat(members[tname], ", ")
				player:hud_change(h.lines[i], "number", (team and team.color_hex) or 0xFFFFFF)
				player:hud_change(h.lines[i], "text", text)
			else
				player:hud_change(h.lines[i], "text", "")
			end
		end
	end
end

-- Removes the roster HUD from one player and forgets their elements.
local function clear_roster_hud_player(player)
	local pname = player:get_player_name()
	local h = dm.roster_hud[pname]
	if not h then return end

	player:hud_remove(h.header)
	for _, id in ipairs(h.lines) do
		player:hud_remove(id)
	end
	dm.roster_hud[pname] = nil
end

-- Tears down the roster for everyone (round/match end, mode switch).
function dm.clear_roster_hud()
	for _, player in ipairs(minetest.get_connected_players()) do
		clear_roster_hud_player(player)
	end
	dm.roster_hud = {}
end

--------------------------------------------------------------------------------
-- Mode factory
--------------------------------------------------------------------------------

-- def: {is_teams, rankings, recent_rankings, features, treasures, crafts,
--       team_chest_items, summary_ranks}
function dm.make_mode(def)
	local is_teams = def.is_teams
	-- Infection: instead of eliminating a killed player, convert them onto their
	-- killer's team. The round ends when only one team has players left.
	local is_infection = def.is_infection
	local rankings = def.rankings
	local recent_rankings = def.recent_rankings
	local features = def.features

	-- Killscore mirrors ctf_modebase.features so environmental kills are rewarded
	-- consistently with melee/ranged kills.
	local function killscore(pname)
		local match_rank = recent_rankings.players()[pname] or {}
		local kd = (match_rank.kills or 1) / (match_rank.deaths or 1)
		return math.max(1, math.round(kd * 7))
	end

	-- Scores a non-punch death (lava, drowning, fall, suicide...). Punch deaths are
	-- already scored inside features.on_punchplayer before the player dies.
	local function score_environmental_death(pname)
		recent_rankings.add(pname, {deaths = 1}, true)

		local killer, weapon_image = ctf_combat_mode.get_last_hitter(pname)

		if killer and killer ~= pname and ctf_teams.get(killer) and dm.alive[killer] then
			local score = killscore(pname)
			recent_rankings.add(killer, {kills = 1, score = score})
			ctf_kill_list.add(killer, pname, weapon_image, " (Suicide)")

			local hitters = ctf_combat_mode.get_other_hitters(pname, killer)
			for _, hname in ipairs(hitters) do
				recent_rankings.add(hname, {
					kill_assists = 1,
					score = math.ceil(score / #hitters),
				})
			end
		else
			ctf_kill_list.add("", pname, "ctf_modebase_skull.png")
		end

		ctf_combat_mode.end_combat(pname)
	end

	local function show_summary(win_text)
		local match_rankings, special_rankings, rank_values, formdef = ctf_modebase.summary.get()
		formdef.title = win_text

		for _, p in ipairs(minetest.get_connected_players()) do
			ctf_modebase.summary.show_gui(
				p:get_player_name(), match_rankings, special_rankings, rank_values, formdef
			)
		end
	end

	local function declare_winner(team)
		dm.round_active = false

		dm.clear_roster_hud()

		local survivors = {}
		for pname in pairs(dm.alive) do
			if ctf_teams.get(pname) == team then
				table.insert(survivors, pname)
			end
		end

		for _, pname in ipairs(survivors) do
			recent_rankings.add(pname, {score = WIN_BONUS})
		end

		local tcolor = ctf_teams.team[team] and ctf_teams.team[team].color or "#ffffff"
		local win_text, summary_text

		if is_infection then
			local label = dm.team_label(team)
			win_text = S("@1's Team infected everyone and wins!", label)
			summary_text = string.format(
				"Team %s infected everyone (%d player(s))",
				label, #survivors
			)
		elseif is_teams then
			win_text = S("@1 Team Wins!", HumanReadable(team))
			summary_text = string.format(
				"Team %s won the deathmatch with %d player(s) standing",
				HumanReadable(team), #survivors
			)
		else
			local winner = survivors[1]
			win_text = S("@1 Wins the Death Match!", winner or "?")
			summary_text = string.format(
				"%s won the deathmatch", minetest.colorize(tcolor, winner or "?")
			)
		end

		ctf_modebase.summary.set_winner(summary_text)
		show_summary(win_text)

		minetest.chat_send_all(minetest.colorize(tcolor, win_text))
		ctf_modebase.announce(minetest.get_translated_string("en", win_text))

		ctf_modebase.start_new_match(5)
	end

	local function declare_draw()
		dm.round_active = false

		dm.clear_roster_hud()

		ctf_modebase.summary.set_winner(S("Nobody survived - it's a draw!"))
		show_summary(S("Draw - Nobody survived!"))
		ctf_modebase.announce("Deathmatch ended in a draw")

		ctf_modebase.start_new_match(5)
	end

	-- Ends the round if one or zero teams have living players left.
	local function check_round_end()
		if not dm.round_active or not ctf_modebase.match_started then return end

		local alive_teams = {}
		local team_count = 0
		local last_team
		for pname in pairs(dm.alive) do
			local team = ctf_teams.get(pname)
			if team and not alive_teams[team] then
				alive_teams[team] = true
				team_count = team_count + 1
				last_team = team
			end
		end

		if team_count > 1 then
			return
		elseif team_count == 1 then
			declare_winner(last_team)
		else
			declare_draw()
		end
	end

	-- Safety net: poll every SAFETY_INTERVAL seconds while a round is active and
	-- run the same end-of-round test. The round normally ends the instant a
	-- conversion/leave leaves one team standing (check_round_end is called at
	-- those points), but this guards against a missed call ever leaving a round
	-- stuck with everyone already on one team. A generation token makes sure only
	-- the current round's loop runs, so rounds never stack timers.
	local SAFETY_INTERVAL = 2
	local function safety_tick(gen)
		if gen ~= dm.safety_gen or not dm.round_active then return end
		check_round_end()
		-- check_round_end may have ended the round; only continue if it is still on.
		if gen == dm.safety_gen and dm.round_active then
			minetest.after(SAFETY_INTERVAL, safety_tick, gen)
		end
	end
	local function start_safety_loop()
		dm.safety_gen = (dm.safety_gen or 0) + 1
		minetest.after(SAFETY_INTERVAL, safety_tick, dm.safety_gen)
	end

	-- True if team `tname` still has a living member other than `except` — i.e. it
	-- has not been eradicated down to (at most) that one player. Players must never
	-- be sent to, or respawn as, an eradicated team.
	local function team_has_other_living(tname, except)
		for other in pairs(dm.alive) do
			if other ~= except and ctf_teams.get(other) == tname then
				return true
			end
		end
		return false
	end

	-- The still-living team with the most members, ignoring `except_team` and not
	-- counting `except_player`. Used to move a player off an eradicated team.
	local function biggest_other_team(except_team, except_player)
		local counts = {}
		for other in pairs(dm.alive) do
			if other ~= except_player then
				local t = ctf_teams.get(other)
				if t and t ~= except_team then
					counts[t] = (counts[t] or 0) + 1
				end
			end
		end
		local best, best_n
		for t, n in pairs(counts) do
			if not best_n or n > best_n then best, best_n = t, n end
		end
		return best
	end

	-- Infection: choose the team a just-killed player is converted onto. They
	-- MUST leave their old team AND land on a team that is still alive, so
	-- victim_team and any eradicated team are never returned while another team is
	-- still in play. Preference order:
	--   1. The killer's (last hitter's) current team — whoever landed the final
	--      hit takes the infection.
	--   2. The team that dealt the victim the most damage this life (tallied by
	--      each hitter's *current* team, so merged teams pool their damage). Used
	--      only when there is no valid killer team (e.g. environmental deaths).
	--   3. Any other team still fighting, chosen at random.
	-- Only if the victim's team is the sole team left does it stay put (the round
	-- is about to end anyway).
	local function pick_infection_team(pname, victim_team, killer_team)
		-- 1. The killer's team, if it is a genuinely different, still-living one.
		if killer_team and killer_team ~= victim_team
		and team_has_other_living(killer_team, pname) then
			return killer_team
		end

		-- 2. Most-damaging team, aggregated by the hitter's current team. Only
		-- teams that are still alive (have a living member other than the victim)
		-- are eligible.
		local dmg = dm.damage_dealt[pname]
		if dmg then
			local by_team = {}
			for hitter, amount in pairs(dmg) do
				local hteam = ctf_teams.get(hitter)
				if hteam and hteam ~= victim_team and team_has_other_living(hteam, pname) then
					by_team[hteam] = (by_team[hteam] or 0) + amount
				end
			end
			local best_team, best_dmg
			for team, amount in pairs(by_team) do
				if not best_dmg or amount > best_dmg then
					best_dmg, best_team = amount, team
				end
			end
			if best_team then return best_team end
		end

		-- 3. Any other team with living players, picked at random.
		local others = {}
		for other in pairs(dm.alive) do
			if other ~= pname then
				local team = ctf_teams.get(other)
				if team and team ~= victim_team then
					others[team] = true
				end
			end
		end
		local other_list = {}
		for team in pairs(others) do
			table.insert(other_list, team)
		end
		if #other_list > 0 then
			return other_list[math.random(#other_list)]
		end

		-- 4. Nobody else left; stay put (round ends this step).
		return victim_team
	end

	-- Infection: switch a just-killed player onto `new_team` and drop them into the
	-- normal CTF respawn state (dead + frozen countdown) rather than reviving them
	-- on the spot. `anchor` is the teammate they should reappear next to when they
	-- respawn (see on_respawnplayer). They keep counting as a living member of the
	-- new team throughout, so the roster and win check see the merge immediately.
	-- Ends the round if this conversion left only one team standing.
	local function infect_player(player, new_team, old_team, anchor)
		local pname = player:get_player_name()
		local pos = dm.death_pos[pname] or player:get_pos()

		local old_color = ctf_teams.team[old_team] and ctf_teams.team[old_team].color or "#ffffff"
		local new_color = ctf_teams.team[new_team] and ctf_teams.team[new_team].color or "#ffffff"
		dm.infection_burst(pos, old_color, new_color)

		-- Switch team without tripping the mid-round spectator path in
		-- on_allocplayer. This fires on_allocplayer, which re-gears and recolours
		-- the player for the new team; the converting flag also tells it NOT to
		-- heal them, so they stay dead and go through the respawn countdown.
		dm.converting[pname] = true
		ctf_teams.set(pname, new_team, true)
		dm.converting[pname] = nil

		-- They never stopped being an active combatant.
		dm.alive[pname] = true

		-- Where to reappear on respawn: next to whoever infected them.
		dm.pending_respawn[pname] = anchor

		if new_team ~= old_team then
			hud_events.new(player, {
				quick = false,
				text = S("You were infected! You now fight for the @1 team",
					dm.team_label(new_team)),
				color = "warning",
			})
		end

		-- Damage from the life that just ended no longer applies.
		dm.damage_dealt[pname] = nil

		-- Enter the normal respawn state: brief death screen, then a frozen
		-- countdown, then on_respawnplayer teleports them beside their new team.
		ctf_modebase.prepare_respawn_delay(player)

		dm.update_roster_hud()

		check_round_end()
	end

	-- Infection: where a player reappears when their respawn countdown finishes.
	-- Prefers a safe spot beside the teammate who infected them; if that teammate
	-- has since been killed or left, beside any other living teammate; and failing
	-- that, a fresh safe spawn somewhere on the map.
	local function infection_respawn_pos(pname, team)
		local anchor = dm.pending_respawn[pname]
		if anchor and anchor ~= pname and dm.alive[anchor] and ctf_teams.get(anchor) == team then
			local ap = minetest.get_player_by_name(anchor)
			if ap then
				return safe_spot_near(ap:get_pos()) or ap:get_pos()
			end
		end

		for other in pairs(dm.alive) do
			if other ~= pname and ctf_teams.get(other) == team then
				local op = minetest.get_player_by_name(other)
				if op then
					return safe_spot_near(op:get_pos()) or op:get_pos()
				end
			end
		end

		if ctf_map.current_map then
			local spawns = dm.compute_spawns(ctf_map.current_map, {[team] = {pname}})
			return spawns and spawns[pname]
		end
	end

	-- Allocate players into teams and scatter them to hidden spawn points.
	local function allocate_teams(map_teams)
		dm.round_starting = true
		dm.round_active = false
		dm.alive = {}
		dm.converting = {}
		dm.death_pos = {}
		dm.damage_dealt = {}
		dm.team_owner = {}
		dm.pending_respawn = {}
		-- Inventory is never carried across rounds, so start the round with no
		-- saved snapshots (they only bridge a death->respawn within a round).
		dm.saved_inv = {}

		-- Reset team state (mirrors ctf_teams.allocate_teams)
		ctf_teams.player_team = {}
		ctf_teams.online_players = {}
		ctf_teams.current_team_list = {}

		local players = {}
		for _, p in ipairs(minetest.get_connected_players()) do
			table.insert(players, p)
		end
		table.shuffle(players)

		local team_of = {}     -- pname -> team
		local participants = {} -- pname -> true (players actually fighting this round)

		if is_teams then
			local teamnames = {}
			for tname in pairs(map_teams) do
				table.insert(teamnames, tname)
			end
			table.sort(teamnames)

			for _, tname in ipairs(teamnames) do
				ctf_teams.online_players[tname] = {count = 0, players = {}}
				table.insert(ctf_teams.current_team_list, tname)
			end

			local idx = 1
			for _, p in ipairs(players) do
				local tname = teamnames[idx]
				team_of[p:get_player_name()] = tname
				participants[p:get_player_name()] = true
				idx = idx % #teamnames + 1
			end
		elseif is_infection then
			-- Every colour is a team, handed out by each player's persisted colour
			-- preference: they get the most-used colour still free, then their next,
			-- and so on. Once every colour is in use the remaining players double up
			-- onto whichever in-play colour they've used most (ties broken toward the
			-- smallest team). Everyone plays, nobody spectates.
			local all_colors = table.copy(dm.infection_teams)
			table.shuffle(all_colors) -- random tiebreak among equally-used colours

			local num_teams = math.min(#players, #all_colors)

			-- Strongest-preference-first: someone who has mained a colour for many
			-- rounds gets first dibs on it over someone who's barely touched it.
			local function top_pref(p)
				local best = 0
				for _, tname in ipairs(all_colors) do
					best = math.max(best, color_use_count(p:get_player_name(), tname))
				end
				return best
			end
			table.sort(players, function(a, b) return top_pref(a) > top_pref(b) end)

			local available = {}
			for _, tname in ipairs(all_colors) do available[tname] = true end

			-- The still-free colour this player has used the most.
			local function best_available(pname)
				local pick, pick_n
				for _, tname in ipairs(all_colors) do
					if available[tname] then
						local n = color_use_count(pname, tname)
						if not pick_n or n > pick_n then
							pick, pick_n = tname, n
						end
					end
				end
				return pick
			end

			local used_teams = {}
			local team_size = {}

			-- Phase 1: give the first `num_teams` players a distinct favourite colour.
			for i = 1, num_teams do
				local p = players[i]
				if not p then break end
				local pname = p:get_player_name()
				local tname = best_available(pname)
				available[tname] = nil
				ctf_teams.online_players[tname] = {count = 0, players = {}}
				table.insert(ctf_teams.current_team_list, tname)
				table.insert(used_teams, tname)
				team_size[tname] = 1
				team_of[pname] = tname
				participants[pname] = true
				-- Founder of this colour's team; names it for the whole round.
				dm.team_owner[tname] = pname
			end

			-- Phase 2: everyone left doubles up on their most-used in-play colour,
			-- breaking ties toward the smallest team so sizes stay even.
			for i = num_teams + 1, #players do
				local pname = players[i]:get_player_name()
				local pick, pick_n, pick_sz
				for _, tname in ipairs(used_teams) do
					local n = color_use_count(pname, tname)
					local sz = team_size[tname]
					if not pick or n > pick_n or (n == pick_n and sz < pick_sz) then
						pick, pick_n, pick_sz = tname, n, sz
					end
				end
				if pick then
					team_size[pick] = team_size[pick] + 1
					team_of[pname] = pick
					participants[pname] = true
				end
			end

			-- Bank each player's colour so their preference builds over time.
			for pname in pairs(participants) do
				record_color_use(pname, team_of[pname])
			end
		else
			-- Free-for-all Death Match: every player gets their own standard team
			-- colour; players beyond the available colours spectate this round.
			local colors = {}
			for _, c in ipairs(ctf_teams.teamlist) do
				if not ctf_teams.team[c].not_playing then
					table.insert(colors, c)
				end
			end
			table.sort(colors)

			for i, p in ipairs(players) do
				local pname = p:get_player_name()
				if i <= #colors then
					local tname = colors[i]
					ctf_teams.online_players[tname] = {count = 0, players = {}}
					table.insert(ctf_teams.current_team_list, tname)
					team_of[pname] = tname
					participants[pname] = true
				else
					-- Bench the surplus player on an existing colour (infra only).
					team_of[pname] = colors[((i - 1) % #colors) + 1]
				end
			end
		end

		-- Assign teams. This fires on_allocplayer for each player.
		for pname, tname in pairs(team_of) do
			if participants[pname] then
				dm.alive[pname] = true
			end
			ctf_teams.set(pname, tname, true)
		end

		dm.round_starting = false

		-- Build per-team member lists for the alive participants.
		local team_members = {}
		for pname in pairs(participants) do
			local tname = team_of[pname]
			team_members[tname] = team_members[tname] or {}
			table.insert(team_members[tname], pname)
		end

		local spawns = dm.compute_spawns(ctf_map.current_map, team_members)
		for pname, pos in pairs(spawns) do
			local player = minetest.get_player_by_name(pname)
			if player then
				teleport_player(player, pos)
				-- Overrides the shorter respawn immunity from on_allocplayer with a
				-- full round-start grace period.
				ctf_modebase.give_immunity(player, ROUND_IMMUNITY_SECONDS)
			end
		end

		-- Bench surplus players as spectators.
		for _, p in ipairs(players) do
			local pname = p:get_player_name()
			if not participants[pname] then
				dm.make_spectator(p, true)
			end
		end

		dm.round_active = true

		-- Start the periodic safety check that ends the round if everyone ends up
		-- on one team (bumps the generation token so any prior loop stops).
		start_safety_loop()

		-- Show the starting teams in the top-right corner (Infection only).
		if is_infection then
			dm.update_roster_hud()
		end
	end

	return {
		-- Infection converts a killed player instead of eliminating them, so they
		-- keep their inventory through the death rather than dropping it.
		keep_inventory_on_death = is_infection or nil,

		treasures = def.treasures,
		crafts = def.crafts,
		team_chest_items = def.team_chest_items,
		physics = {sneak_glitch = true, new_move = true},
		rankings = rankings,
		recent_rankings = recent_rankings,
		summary_ranks = def.summary_ranks,

		-- No prep time, no border.
		build_timer = 0,
		-- Playable on every map.
		any_map = true,

		-- Infection gives no initial stuff at all - players start each round empty
		-- and build up their own inventory, which persists through a death and
		-- respawn within the round but not across rounds. Every other mode gets the
		-- standard starter kit.
		stuff_provider = function()
			if is_infection then
				return {}
			end
			return {
				"ctf_melee:sword_steel",
				"default:pick_stone",
				"default:cobble 10",
				"default:apple 3",
			}
		end,
		initial_stuff_item_levels = features.initial_stuff_item_levels,

		on_mode_start = function() end,
		on_mode_end = function() end,

		on_new_match = features.on_new_match,
		on_match_end = features.on_match_end,

		allocate_teams = allocate_teams,
		team_allocator = function()
			-- Infection: mid-round joiners double up on a random existing team and
			-- spawn straight in (see on_allocplayer).
			if is_infection then
				local list = ctf_teams.current_team_list
				if #list > 0 then
					return list[math.random(#list)]
				end
				return nil
			end

			-- Used for mid-round joins: drop them on the least-populated existing
			-- team (purely for infra; they are turned into a spectator immediately).
			local best, best_count
			for _, tname in ipairs(ctf_teams.current_team_list) do
				local count = ctf_teams.online_players[tname].count
				if not best_count or count < best_count then
					best_count = count
					best = tname
				end
			end
			return best or ctf_teams.current_team_list[1]
		end,

		on_allocplayer = function(player, new_team)
			local pname = player:get_player_name()
			local converting = dm.converting[pname]

			-- Restore in case the player spectated the previous round.
			dm.restore_spectator(player)

			-- Normally healed to full on (re)allocation. During an Infection
			-- death-conversion the player must STAY dead so they go through the
			-- respawn countdown, so skip the heal in that case.
			if not converting then
				player:set_hp(player:get_properties().hp_max)
			end

			ctf_modebase.update_wear.cancel_player_updates(player)

			if is_infection then
				-- No initial stuff in Infection, and nothing is carried across
				-- rounds: a fresh allocation (round start or mid-round join) starts
				-- with an empty inventory and no elytra. A mid-round conversion
				-- (converting) instead leaves the player's current inventory
				-- untouched so they keep everything they were holding when infected.
				if not converting then
					player:get_inventory():set_list("main", {})
					if ctf_elytra and ctf_elytra.reset then
						ctf_elytra.reset(player)
					end
				end
			else
				ctf_modebase.player.remove_bound_items(player)
				ctf_modebase.player.give_initial_stuff(player)
			end

			local tcolor = ctf_teams.team[new_team].color
			player:hud_set_hotbar_image("gui_hotbar.png^[colorize:" .. tcolor .. ":128")
			player:hud_set_hotbar_selected_image("gui_hotbar_selected.png^[multiply:" .. tcolor)

			if player_api.players[player:get_player_name()] then
				player_api.set_texture(player, 1, ctf_cosmetics.get_skin(player))
			end

			recent_rankings.set_team(player, new_team)

			playertag.set(player, playertag.TYPE_ENTITY)
			if player.set_observers then
				ctf_modebase.update_playertags()
			end

			-- A player joining while a round is underway. An Infection team-switch
			-- also routes through here, but must keep fighting rather than spectate,
			-- so conversions (converting flag) are skipped.
			if not dm.round_starting and dm.round_active and not converting then
				if is_infection then
					-- Infection has no spectators: spawn the joiner straight in.
					infection_join_midround(player)
				else
					dm.make_spectator(player, true)
				end
			end
		end,

		on_leaveplayer = function(player)
			local pname = player:get_player_name()

			features.on_leaveplayer(player)

			local was_alive = dm.alive[pname]
			dm.alive[pname] = nil

			local spec = dm.spectators[pname]
			if spec then
				physics.remove(pname, "ctf_mode_deathmatch:spectator")
				restore_privs(pname, spec.privs)
				dm.spectators[pname] = nil
			end

			-- Drop the leaver from the roster and refresh it for everyone else.
			dm.roster_hud[pname] = nil
			if is_infection and dm.round_active then
				dm.update_roster_hud()
			end

			if was_alive then
				check_round_end()
			end
		end,

		on_dieplayer = function(player, reason)
			if not ctf_modebase.match_started then return end

			local pname = player:get_player_name()
			if not dm.alive[pname] then return end

			if is_infection then
				local victim_team = ctf_teams.get(pname)
				dm.death_pos[pname] = player:get_pos()

				-- Remember the inventory they died with (kept through the death) so
				-- it can be brought back after the shared respawn code wipes it.
				snapshot_inv(pname)

				-- Work out who infected the victim. For punch deaths the killer is
				-- on the damage reason (combat mode has already ended and scored
				-- the kill by this point). For everything else, blame the last
				-- hitter and score it like a normal environmental death.
				local killer
				if reason.type == "punch" and reason.object and reason.object:is_player() then
					killer = reason.object:get_player_name()
				else
					killer = ctf_combat_mode.get_last_hitter(pname)
					score_environmental_death(pname)
				end

				local killer_team
				if killer and killer ~= pname and dm.alive[killer] then
					reward_kill_hp(killer)
					killer_team = ctf_teams.get(killer)
					if killer_team == victim_team then killer_team = nil end
				end

				-- A killed player MUST switch teams: send them to whoever hurt them
				-- most, then the killer, then any other surviving team.
				local new_team = pick_infection_team(pname, victim_team, killer_team)

				-- The teammate they'll reappear beside on respawn: the player who
				-- infected them, if that player is now on the same (new) team.
				local anchor
				if killer and killer ~= pname and dm.alive[killer]
				and ctf_teams.get(killer) == new_team then
					anchor = killer
				end

				-- Switch teams and enter the respawn state now, while the engine has
				-- the player marked dead. infect_player keeps them dead (no revive) so
				-- the standard respawn countdown runs, exactly like a normal CTF death.
				infect_player(player, new_team, victim_team, anchor)
				return
			end

			-- Reward the killer with a heal (any kill type). The puncher for a direct
			-- kill, otherwise whoever last damaged the victim (fall/lava after a hit).
			local killer
			if reason.type == "punch" and reason.object and reason.object:is_player() then
				killer = reason.object:get_player_name()
			else
				killer = ctf_combat_mode.get_last_hitter(pname)
			end
			if killer and killer ~= pname and dm.alive[killer] then
				reward_kill_hp(killer)
			end

			-- Punch kills are scored in on_punchplayer; only score other deaths here.
			if reason.type ~= "punch" then
				score_environmental_death(pname)
			end

			dm.alive[pname] = nil

			check_round_end()

			-- Turn the player into a spectator on the next step (after the engine
			-- finishes processing the death). make_spectator revives them to full
			-- HP and dismisses the death screen, so they never get stuck "dead".
			minetest.after(0, function()
				local p = minetest.get_player_by_name(pname)
				if p and not dm.alive[pname] then
					dm.make_spectator(p, false)
				end
			end)
		end,

		on_respawnplayer = function(player)
			local pname = player:get_player_name()

			-- Infection: an infected player's respawn countdown just finished. Drop
			-- them back into the fight beside the teammate who infected them (or
			-- another teammate / a fresh spawn if that one is already gone).
			if is_infection and dm.alive[pname] then
				local team = ctf_teams.get(pname)

				-- Their team may have been eradicated (everyone else on it infected
				-- away) while they were down. Never respawn as a wiped-out team: move
				-- onto the largest still-living team instead.
				if team and not team_has_other_living(team, pname) then
					local newteam = biggest_other_team(team, pname)
					if newteam then
						dm.converting[pname] = true
						ctf_teams.set(pname, newteam, true)
						dm.converting[pname] = nil
						team = newteam
						dm.update_roster_hud()
					end
				end

				local pos = team and infection_respawn_pos(pname, team)
				if pos then
					teleport_player(player, pos)
				elseif ctf_map.current_map then
					player:set_pos(ctf_map.current_map.flag_center)
				end

				-- Bring back the inventory they had before dying (the shared respawn
				-- handler just emptied it and would otherwise leave them with nothing).
				restore_inv(player)

				dm.pending_respawn[pname] = nil
				dm.death_pos[pname] = nil
				return
			end

			-- Non-infection player still alive (e.g. died before the match started)
			-- respawns back into the map rather than spectating.
			if dm.alive[pname] then
				local pos = ctf_map.current_map and ctf_map.current_map.flag_center
				if pos then
					player:set_pos(pos)
				end
				return
			end

			-- In deathmatch you do not respawn during a round.
			dm.make_spectator(player, false)
		end,

		-- Flags are disabled; the round is won by elimination.
		can_take_flag = function()
			return S("Flags are disabled in Death Match")
		end,
		on_flag_take = function() end,
		on_flag_drop = function() end,
		on_flag_capture = function() end,
		on_flag_rightclick = function() end,

		get_chest_access = features.get_chest_access,

		can_punchplayer = function(player, hitter)
			if not dm.alive[player:get_player_name()] or not dm.alive[hitter:get_player_name()] then
				return false
			end
			return features.can_punchplayer(player, hitter)
		end,
		on_punchplayer = function(player, hitter, damage, ...)
			local pname = player:get_player_name()
			local hname = hitter:get_player_name()
			if not dm.alive[pname] or not dm.alive[hname] then
				return false
			end

			local real_damage, err = features.on_punchplayer(player, hitter, damage, ...)

			-- Infection: remember how much each attacker has hurt this player so
			-- that, on death, they can be sent to the team that hurt them most.
			if is_infection and type(real_damage) == "number" and real_damage > 0
			and hname ~= pname then
				local tally = dm.damage_dealt[pname]
				if not tally then
					tally = {}
					dm.damage_dealt[pname] = tally
				end
				tally[hname] = (tally[hname] or 0) + real_damage
			end

			return real_damage, err
		end,
		on_healplayer = features.on_healplayer,

		calculate_knockback = function()
			return 0
		end,
	}
end

--------------------------------------------------------------------------------
-- Shared loot/ranking config + registration helper
--------------------------------------------------------------------------------

dm.RANKLIST = {
	_sort = "score",
	"score",
	"kills", "kill_assists", "bounty_kills",
	"deaths",
	"hp_healed",
	"reward_given_to_enemy"
}

dm.treasures = {
	["default:ladder_wood" ] = {                max_count = 20, rarity = 0.3, max_stacks = 5},
	["default:torch"       ] = {                max_count = 20, rarity = 0.3, max_stacks = 5},

	["default:cobble"      ] = {min_count = 20, max_count = 99, rarity = 0.3, max_stacks = 2},
	["default:wood"        ] = {min_count = 20, max_count = 99, rarity = 0.2, max_stacks = 2},

	["ctf_teams:door_steel"] = {rarity = 0.2, max_stacks = 3},

	["default:pick_steel"  ] = {rarity = 0.4, max_stacks = 3},
	["default:shovel_steel"] = {rarity = 0.4, max_stacks = 2},
	["default:axe_steel"   ] = {rarity = 0.4, max_stacks = 2},

	["ctf_melee:sword_steel"] = {rarity = 0.3, max_stacks = 2},
	["ctf_melee:sword_mese" ] = {rarity = 0.1, max_stacks = 1},

	-- Guns, magazines and ammo are added by bestguns_ctf (see its rarity table).

	["default:apple"   ] = {min_count = 6, max_count = 16, rarity = 0.2, max_stacks = 2},

	["ctf_healing:bandage"] = {rarity = 0.1, max_stacks = 2},

	["ctf_grenades:frag" ] = {rarity = 0.1, max_stacks = 1},
	["ctf_grenades:smoke"] = {rarity = 0.2, max_stacks = 2},
}

dm.crafts = {
	"bestguns:bullet_9mm 12", "bestguns:bullet_44 6", "bestguns:bullet_39mm 12",
	"bestguns:12_gauge 4", "bestguns:308 4",
	"ctf_melee:sword_steel", "ctf_melee:sword_mese", "ctf_melee:sword_diamond",
}

dm.team_chest_items = {
	"default:cobble 99", "default:wood 99", "default:torch 30", "ctf_teams:door_steel 2",
}

-- Registers a deathmatch mode. Call this from each mode's own mod so that the
-- persistent rankings get a per-mod namespace (see ctf_rankings:init).
--
-- is_infection: variant where killed players switch to their killer's team
-- instead of being eliminated; implies a team-based game.
function dm.register(name, is_teams, is_infection)
	local rankings = ctf_rankings:init(dm.RANKLIST)
	local recent_rankings = ctf_modebase.recent_rankings(rankings)
	local features = ctf_modebase.features(rankings, recent_rankings)

	ctf_modebase.register_mode(name, dm.make_mode({
		is_teams = is_teams,
		is_infection = is_infection,
		rankings = rankings,
		recent_rankings = recent_rankings,
		features = features,
		treasures = dm.treasures,
		crafts = dm.crafts,
		team_chest_items = dm.team_chest_items,
		summary_ranks = dm.RANKLIST,
	}))
end
