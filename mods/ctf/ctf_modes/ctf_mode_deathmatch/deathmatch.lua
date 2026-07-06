local S = minetest.get_translator(minetest.get_current_modname())

-- Flat score bonus awarded to each surviving winner at the end of a round.
local WIN_BONUS = 250

-- Minimum spacing between team spawn anchors, and the range within which a clear
-- line of sight between two anchors is considered "they can see each other".
local MIN_ANCHOR_DIST = 24
local VIS_DIST = 140

-- Radius around a team's anchor that its members are clustered into.
local CLUSTER_RADIUS = 6

local MAX_HP = minetest.PLAYER_MAX_HP_DEFAULT * 10

-- Grace period at the start of each round during which participants are fully
-- immune (invulnerable + non-pointable), so nobody gets spawn-killed.
local ROUND_IMMUNITY_SECONDS = 30

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
}
local dm = ctf_mode_deathmatch

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
	-- x,z, skipping past barriers/canopies, or nil if the column is unsuitable.
	-- Guarantees two nodes of clear air above the ground so the player has room
	-- to stand and walk (never embedded in the ground or a wall).
	local function surface_at(x, z)
		if x < field1.x or x > field2.x or z < field1.z or z > field2.z then
			return nil
		end

		-- Scan strictly inside the field so we never land on the ceiling/walls.
		for y = field2.y - 1, field1.y + 1, -1 do
			local result = classify(data[area:index(x, y, z)])
			if result == "ground" then
				-- Need genuine air for the feet and head, otherwise the spot is
				-- jammed under a barrier/overhang.
				if data[area:index(x, y + 1, z)] == c_air and
				   data[area:index(x, y + 2, z)] == c_air then
					return vector.new(x, y + 1, z)
				end
				return nil
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

-- Picks `count` positions from `pool` that are spread out and, where possible,
-- cannot see each other (no clear line of sight). Falls back to maximal spacing.
local function pick_spread_anchors(pool, count)
	local chosen = {}

	for _, c in ipairs(pool) do
		if #chosen >= count then break end

		local ok = true
		for _, s in ipairs(chosen) do
			local d = vector.distance(c, s)
			if d < MIN_ANCHOR_DIST then
				ok = false
				break
			end
			if d < VIS_DIST and minetest.line_of_sight(
				vector.offset(c, 0, 1.5, 0), vector.offset(s, 0, 1.5, 0)
			) then
				ok = false
				break
			end
		end

		if ok then
			table.insert(chosen, c)
		end
	end

	-- Not enough mutually-hidden spots: relax the LOS rule and just maximise distance.
	if #chosen < count then
		for _, c in ipairs(pool) do
			if #chosen >= count then break end

			local too_close = false
			local duplicate = false
			for _, s in ipairs(chosen) do
				if vector.equals(c, s) then
					duplicate = true
					break
				end
				if vector.distance(c, s) < MIN_ANCHOR_DIST / 2 then
					too_close = true
					break
				end
			end

			if not duplicate and not too_close then
				table.insert(chosen, c)
			end
		end
	end

	return chosen
end

-- team_members: { teamname = {pname, ...}, ... }
-- Returns { [pname] = position } for every alive player passed in.
function dm.compute_spawns(map, team_members)
	local surface_at, b1, b2 = make_surface_finder(map)

	local function random_surface()
		for _ = 1, 60 do
			local x = math.random(b1.x, b2.x)
			local z = math.random(b1.z, b2.z)
			local p = surface_at(x, z)
			if p then return p end
		end
		return nil
	end

	-- Build a pool of candidate ground positions to choose anchors from.
	local pool = {}
	for _ = 1, 600 do
		if #pool >= 220 then break end
		local p = random_surface()
		if p then table.insert(pool, p) end
	end
	table.shuffle(pool)

	local teamnames = {}
	for tname in pairs(team_members) do
		table.insert(teamnames, tname)
	end
	table.sort(teamnames)

	local anchors = pick_spread_anchors(pool, #teamnames)
	-- Last-resort anchor: a real surface near the field centre, else the centre.
	local fallback = random_surface() or
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
end)

--------------------------------------------------------------------------------
-- Mode factory
--------------------------------------------------------------------------------

-- def: {is_teams, rankings, recent_rankings, features, treasures, crafts,
--       team_chest_items, summary_ranks}
function dm.make_mode(def)
	local is_teams = def.is_teams
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

		if is_teams then
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

	-- Allocate players into teams and scatter them to hidden spawn points.
	local function allocate_teams(map_teams)
		dm.round_starting = true
		dm.round_active = false
		dm.alive = {}

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
		else
			-- Free-for-all: every player gets their own colour (capped by the number
			-- of available colours). Extra players spectate until the next round.
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

			-- A player joining while a round is underway sits it out.
			if not dm.round_starting and dm.round_active then
				dm.make_spectator(player, true)
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
			-- started) is sent back into the map rather than made a spectator.
			if dm.alive[pname] then
				if ctf_map.current_map then
					player:set_pos(ctf_map.current_map.flag_center)
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
function dm.register(name, is_teams)
	local rankings = ctf_rankings:init(dm.RANKLIST)
	local recent_rankings = ctf_modebase.recent_rankings(rankings)
	local features = ctf_modebase.features(rankings, recent_rankings)

	ctf_modebase.register_mode(name, dm.make_mode({
		is_teams = is_teams,
		rankings = rankings,
		recent_rankings = recent_rankings,
		features = features,
		treasures = dm.treasures,
		crafts = dm.crafts,
		team_chest_items = dm.team_chest_items,
		summary_ranks = dm.RANKLIST,
	}))
end
