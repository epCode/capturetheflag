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
end)

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
			win_text = S("@1 Team infected everyone and wins!", HumanReadable(team))
			summary_text = string.format(
				"Team %s infected everyone (%d player(s))",
				HumanReadable(team), #survivors
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

	-- Infection: revive a just-killed player on `new_team` right where they fell,
	-- next to whoever infected them. If new_team == old_team (a suicide or an
	-- environmental death with no valid infector) they simply respawn on their
	-- own side. Ends the round if this conversion left only one team standing.
	local function infect_player(player, new_team, old_team)
		local pname = player:get_player_name()
		local pos = dm.death_pos[pname] or player:get_pos()

		local old_color = ctf_teams.team[old_team] and ctf_teams.team[old_team].color or "#ffffff"
		local new_color = ctf_teams.team[new_team] and ctf_teams.team[new_team].color or "#ffffff"
		dm.infection_burst(pos, old_color, new_color)

		-- Switch team without tripping the mid-round spectator path in
		-- on_allocplayer. This fires on_allocplayer, which heals the player to
		-- full, re-gears them and recolours them for the new team.
		dm.converting[pname] = true
		ctf_teams.set(pname, new_team, true)
		dm.converting[pname] = nil

		-- They never stopped being an active combatant.
		dm.alive[pname] = true

		-- Revive on the spot and dismiss the death screen.
		teleport_player(player, pos)
		minetest.close_formspec(pname, "")
		ctf_modebase.give_immunity(player, INFECT_IMMUNITY_SECONDS)

		if new_team ~= old_team then
			hud_events.new(player, {
				quick = false,
				text = S("You were infected! You now fight for the @1 team", HumanReadable(new_team)),
				color = "warning",
			})
		end

		dm.death_pos[pname] = nil

		check_round_end()
	end

	-- Allocate players into teams and scatter them to hidden spawn points.
	local function allocate_teams(map_teams)
		dm.round_starting = true
		dm.round_active = false
		dm.alive = {}
		dm.converting = {}
		dm.death_pos = {}

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
			-- Every colour is a team. Colours are handed out at random, and once
			-- they run out players double up onto shared colours rather than being
			-- benched - everyone plays, nobody spectates.
			local colors = table.copy(dm.infection_teams)
			table.shuffle(colors)

			local num_teams = math.max(1, math.min(#players, #colors))

			for i = 1, num_teams do
				local tname = colors[i]
				ctf_teams.online_players[tname] = {count = 0, players = {}}
				table.insert(ctf_teams.current_team_list, tname)
			end

			-- players is already shuffled, so round-robin assignment keeps team
			-- sizes even (differing by at most one) while staying random.
			for i, p in ipairs(players) do
				local tname = colors[((i - 1) % num_teams) + 1]
				team_of[p:get_player_name()] = tname
				participants[p:get_player_name()] = true
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

		stuff_provider = function()
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
			-- Restore in case the player spectated the previous round.
			dm.restore_spectator(player)

			player:set_hp(player:get_properties().hp_max)

			ctf_modebase.update_wear.cancel_player_updates(player)
			ctf_modebase.player.remove_bound_items(player)
			ctf_modebase.player.give_initial_stuff(player)

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
			if not dm.round_starting and dm.round_active and not dm.converting[player:get_player_name()] then
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
					killer_team = ctf_teams.get(killer)
					if killer_team == victim_team then killer_team = nil end
				end

				-- Convert on the next step, once the engine has finished the death.
				minetest.after(0, function()
					local p = minetest.get_player_by_name(pname)
					if p and dm.alive[pname] then
						infect_player(p, killer_team or victim_team, victim_team)
					end
				end)
				return
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

			-- A player who is still alive respawning (e.g. died before the match
			-- started, or an Infection player who clicked respawn before the
			-- conversion ran) is sent back into the map rather than made a
			-- spectator. In Infection, keep them where they fell.
			if dm.alive[pname] then
				local pos = (is_infection and dm.death_pos[pname])
					or (ctf_map.current_map and ctf_map.current_map.flag_center)
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
			if not dm.alive[player:get_player_name()] or not dm.alive[hitter:get_player_name()] then
				return false
			end
			return features.on_punchplayer(player, hitter, damage, ...)
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
