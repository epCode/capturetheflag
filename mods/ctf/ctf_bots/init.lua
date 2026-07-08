ctf_bots = {}

-- Allow enough force-loaded blocks for every bot to stay loaded (default is 16).
if (tonumber(minetest.settings:get("max_forceloaded_blocks")) or 16) < 64 then
	minetest.settings:set("max_forceloaded_blocks", "64")
end

local BULLET       = "bestguns:bullet_9mm" -- bot ammo (reuses the real bestguns bullet)
local MOVE_SPEED   = 4.2                   -- horizontal walk speed (nodes/s)
local JUMP_SPEED   = 6.8                    -- clears a 2-node step (peak ~2.35 nodes)
local SWIM_UP      = 4.0                    -- vertical swim speed in liquids
local GRAVITY      = -9.8
local BUILD_NODE   = "ctf_bots:scaffold"    -- block bots pillar up with
local MAX_BOTS     = 24
local RESPAWN_TIME = 4
local PATH_TIMEOUT = 1.5                   -- recompute A* path at most this often
local PATH_SEARCH  = 30                    -- A* search distance (nodes)
local TARGET_RESCAN= 0.5                   -- re-pick combat target at most this often
local DEFEND_RADIUS= 18
local REACH_DIST   = 2.0                   -- "arrived at goal" threshold
local EYE          = 1.4                   -- eye height for shooting / aiming
local ROLES        = {"attack", "defend"}

-- Player-mimicking model data (mirrors ctf_player/init.lua)
local BOT_MESH     = "character.b3d"
local BOT_TEXTURES = {"character.png", "blank.png"}
local ANIM_STAND   = {x = 0,   y = 79}
local ANIM_WALK    = {x = 168, y = 187}
local ANIM_MINE    = {x = 189, y = 198}
local MINE_TIME    = 0.5                    -- seconds to mine a block pair

--------------------------------------------------------------------------------
-- Name generator API
--------------------------------------------------------------------------------
-- Editable syllable tables -> pronounceable random names like "Kaelis", "Zyndor".
ctf_bots.name_syllables = {
	start = {"ka","ze","dro","my","vy","th","bra","sko","lu","ne","gor","ix","ven","ra","qui","sy","tor","el","fa","gru"},
	mid   = {"la","ri","no","da","se","vo","ly","na","mi","tu","ke","so","ra","den","lis","mor","vyn","tas","gar","wel"},
	["end"]= {"n","r","s","x","th","l","k","dor","is","us","ar","ox","en","yn","ax","el","ir","um","ok",""},
}

function ctf_bots.gen_name()
	local s = ctf_bots.name_syllables
	local function pick(t) return t[math.random(#t)] end
	local name = pick(s.start) .. pick(s.mid)
	if math.random() < 0.45 then name = name .. pick(s.mid) end
	name = name .. pick(s["end"])
	-- Capitalize
	return name:sub(1, 1):upper() .. name:sub(2)
end

--------------------------------------------------------------------------------
-- Skill system (1-6): maps skill -> combat stats by interpolating low<->high.
--------------------------------------------------------------------------------
local function lerp(a, b, t) return a + (b - a) * t end

function ctf_bots.skill_stats(skill)
	skill = math.min(6, math.max(1, math.floor(skill or math.random(1, 6))))
	local t = (skill - 1) / 5 -- 0 (worst) .. 1 (best)
	return {
		skill         = skill,
		view          = lerp(16,   34,   t), -- detection range
		fire_cooldown = lerp(1.1,  0.32, t), -- seconds between shots
		think         = lerp(0.34, 0.18, t), -- AI tick interval (reaction)
		inacc         = lerp(16,   2,    t), -- bullet spread (transverse velocity jitter)
		aim_chance    = lerp(0.7,  0.99, t), -- chance a shot is genuinely aimed (not a near-miss)
		lead          = lerp(0.25, 1.0,  t), -- how well it leads a moving target
	}
end

--------------------------------------------------------------------------------
-- Registry + team helpers
--------------------------------------------------------------------------------
local bots = {}      -- id -> luaentity
local next_id = 1

local function count_bots()
	local n = 0
	for _ in pairs(bots) do n = n + 1 end
	return n
end

local function team_color(team)
	local t = ctf_teams.team[team]
	return (t and t.color) or "#ffffff"
end

local function team_data(team)
	return ctf_map.current_map and ctf_map.current_map.teams and ctf_map.current_map.teams[team]
end

local function enemy_teams(team)
	local out = {}
	for _, t in ipairs(ctf_teams.current_team_list or {}) do
		if t ~= team and team_data(t) then table.insert(out, t) end
	end
	return out
end

-- Resolve the team of whoever a punch/bullet came from (player, bot, or a bot's
-- bullet entity). Returns nil if unknown. Used to cancel friendly fire.
local function attacker_team(puncher)
	if not puncher then return nil end
	if puncher.is_player and puncher:is_player() then
		return ctf_teams.get(puncher)
	end
	local le = puncher:get_luaentity()
	if not le then return nil end
	if le.name == "ctf_bots:bot" then return le.team end
	if le.name == "bestguns:bullet" then
		local s = le.shooter_name or ""
		local id = s:match("^bot:(%d+)")
		if id then
			local b = bots[tonumber(id)]
			return b and b.team
		elseif s ~= "" then
			return ctf_teams.get(s)
		end
	end
	return nil
end

--------------------------------------------------------------------------------
-- Safe flag take / capture / drop (visual-only, no scoring -- see plan)
--------------------------------------------------------------------------------
local function flag_node_pos(team)
	local td = team_data(team)
	if not td then return nil end
	return vector.offset(td.flag_pos, 0, 1, 0)
end

local function take_flag(self, enemyteam)
	if ctf_modebase.flag_taken[enemyteam] or ctf_modebase.flag_captured[enemyteam] then
		return false
	end
	local fpos = flag_node_pos(enemyteam)
	if not fpos then return false end
	minetest.load_area(fpos)
	local node = minetest.get_node(fpos)
	if node.name ~= "ctf_modebase:flag_top_" .. enemyteam then return false end

	minetest.set_node(fpos, {name = "ctf_modebase:flag_captured_top", param2 = node.param2})
	ctf_modebase.flag_taken[enemyteam] = {p = "bot:" .. self.id, t = self.team}
	self.carrying = enemyteam

	minetest.chat_send_all(minetest.colorize(team_color(self.team), self.name) ..
		" took " .. minetest.colorize(team_color(enemyteam), enemyteam) .. " team's flag!")
	return true
end

local function restore_flag(enemyteam)
	local fpos = flag_node_pos(enemyteam)
	if not fpos then return end
	minetest.load_area(fpos)
	local node = minetest.get_node(fpos)
	if node.name == "ctf_modebase:flag_captured_top" then
		minetest.set_node(fpos, {name = "ctf_modebase:flag_top_" .. enemyteam, param2 = node.param2})
	end
	ctf_modebase.flag_taken[enemyteam] = nil
end

local function drop_flag(self)
	if not self.carrying then return end
	restore_flag(self.carrying)
	self.carrying = nil
end

local function do_capture(self)
	local enemyteam = self.carrying
	if not enemyteam then return end
	restore_flag(enemyteam)
	self.carrying = nil
	minetest.chat_send_all(minetest.colorize(team_color(self.team), self.name) ..
		" [" .. self.stats.skill .. "] captured " ..
		minetest.colorize(team_color(enemyteam), enemyteam) .. " team's flag!")
	minetest.sound_play("ctf_modebase_drop_flag_positive", {gain = 1.0}, true)
end

--------------------------------------------------------------------------------
-- Combat / sensing
--------------------------------------------------------------------------------
local function eye_pos(obj)
	local p = obj:get_pos()
	if not p then return nil end
	p.y = p.y + EYE
	return p
end

-- Nearest living enemy (player or other-team bot) within range. Returns obj, pos.
local function find_target(self, mypos)
	local best, bestpos, bestd = nil, nil, self.stats.view * self.stats.view
	for _, player in ipairs(minetest.get_connected_players()) do
		local pteam = ctf_teams.get(player)
		if pteam and pteam ~= self.team and player:get_hp() > 0 then
			local pp = player:get_pos()
			local d = vector.distance(mypos, pp)
			if d * d < bestd then best, bestpos, bestd = player, pp, d * d end
		end
	end
	for _, bot in pairs(bots) do
		if bot ~= self and bot.team ~= self.team and bot.object and bot.object:get_pos() then
			local pp = bot.object:get_pos()
			local d = vector.distance(mypos, pp)
			if d * d < bestd then best, bestpos, bestd = bot.object, pp, d * d end
		end
	end
	return best, bestpos
end

local function has_los(frompos, topos)
	local ray = minetest.raycast(frompos, topos, false, false) -- nodes only
	for pt in ray do
		if pt.type == "node" then
			local def = minetest.registered_nodes[minetest.get_node(pt.under).name]
			if def and def.walkable then return false end
		end
	end
	return true
end

local function shoot(self, mypos, target, targetpos)
	-- bestguns is optional; without it bots simply don't shoot.
	local bdef = bestguns and bestguns.registered_bullets[BULLET]
	if not bdef then return end
	local from = vector.new(mypos.x, mypos.y + EYE, mypos.z)
	local speed = bdef.speed or 200
	-- Aim at centre mass (~1.0 above feet) so vertical spread stays on the body.
	local aim  = vector.new(targetpos.x, targetpos.y + 1.0, targetpos.z)

	-- Lead a moving target: offset the aim by its velocity over the bullet's
	-- time-of-flight, scaled by skill (low skill leads poorly).
	local tvel = target.get_velocity and target:get_velocity() or nil
	if tvel then
		local tof = vector.distance(from, aim) / speed
		aim = vector.add(aim, vector.multiply(tvel, tof * self.stats.lead))
	end

	-- Low skill / unaimed shots are thrown wider ("shoot near players")
	local inacc = self.stats.inacc
	if math.random() > self.stats.aim_chance then inacc = inacc * 2 end

	local dir = vector.direction(from, aim)
	local function jit() return (math.random() * 2 - 1) * inacc end
	local vel = vector.multiply(dir, speed)
	vel.x = vel.x + jit()
	vel.y = vel.y + jit()
	vel.z = vel.z + jit()

	-- Spawn slightly ahead so the bot never hits itself
	local spawnpos = vector.add(from, vector.multiply(dir, 1.2))
	minetest.add_entity(spawnpos, "bestguns:bullet", minetest.serialize({
		velocity     = vel,
		shooter_name = "bot:" .. self.id,
		damage       = bdef.damage or 10,
		texture      = bdef.texture,
		size         = bdef.size or 1,
	}))
	if bdef.fire_sound then
		minetest.sound_play(bdef.fire_sound, {pos = from, max_hear_distance = 32}, true)
	end
end

--------------------------------------------------------------------------------
-- Terrain probing + traversal abilities (build / mine / swim)
--------------------------------------------------------------------------------
-- Cheap block bots pillar up with. Easily diggable, flagged so it's identifiable.
minetest.register_node(BUILD_NODE, {
	description = "Bot Scaffold",
	tiles = {"default_wood.png^[colorize:#3a2a10:120"},
	groups = {crumbly = 3, oddly_breakable_by_hand = 3, not_in_creative_inventory = 1},
	is_ground_content = false,
})

local DIG_GROUPS = {"cracky", "crumbly", "choppy", "snappy", "oddly_breakable_by_hand"}

local function is_walkable(pos)
	local d = minetest.registered_nodes[minetest.get_node(pos).name]
	return d ~= nil and d.walkable == true
end

local function is_liquid(pos)
	local d = minetest.registered_nodes[minetest.get_node(pos).name]
	return d ~= nil and d.liquidtype ~= nil and d.liquidtype ~= "none"
end

-- A node bots may tunnel through, but only as a last resort. Excludes air,
-- liquids, and indestructible nodes (flags/barriers carry the immortal group).
local function is_diggable(pos)
	local node = minetest.get_node(pos)
	if node.name == "air" or node.name == "ignore" then return false end
	local d = minetest.registered_nodes[node.name]
	if not d or not d.walkable or d.diggable == false then return false end
	local g = d.groups or {}
	if (g.immortal or 0) > 0 then return false end
	for _, grp in ipairs(DIG_GROUPS) do
		if (g[grp] or 0) > 0 then return true end
	end
	return false
end

-- Snap a position to the nearest standable spot (a floor with air above it),
-- searching a few nodes up/down. Returns nil if none found nearby. This makes
-- find_path far more likely to succeed for points sampled in open air.
local function ground_under(pos)
	local p = vector.round(pos)
	for dy = 2, -4, -1 do
		local floor = vector.offset(p, 0, dy, 0)
		if is_walkable(floor) and not is_walkable(vector.offset(floor, 0, 1, 0)) then
			return vector.offset(floor, 0, 1, 0)
		end
	end
	return nil
end

--------------------------------------------------------------------------------
-- Navigation (engine A*)
--------------------------------------------------------------------------------
-- Find a walkable path toward the goal. If the goal itself is unreachable (too
-- far, or blocked), progressively sample points back along the line from the
-- goal toward the bot and return a path to the *closest reachable* one, so the
-- bot always gets as near as terrain allows before resorting to build/mine/swim.
local function compute_path(mypos, goal)
	local rp = vector.round(mypos)
	local direct = minetest.find_path(rp, vector.round(goal), PATH_SEARCH, 2, 3, "A*_noprefetch")
	if direct then return direct end

	local to_goal = vector.subtract(goal, mypos)
	local gdist = vector.length(to_goal)
	if gdist < 1 then return nil end
	local dirn = vector.divide(to_goal, gdist)

	-- Try farthest (closest to goal) first; break on the first reachable point.
	-- Step finely (2 nodes) so we always grab a path even a node or two closer
	-- before giving up to build/mine/swim.
	local maxd = math.min(gdist - 1, PATH_SEARCH - 2)
	local step = 2
	local d = maxd
	while d >= 2 do
		local c = ground_under(vector.add(mypos, vector.multiply(dirn, d)))
		if c then
			local p = minetest.find_path(rp, c, PATH_SEARCH, 2, 3, "A*_noprefetch")
			if p then return p end
		end
		d = d - step
	end
	return nil
end

-- Nearest door we can actually walk up to. Bots can't open doors, so they breach
-- them by mining. Returns (door_pos, path_to_an_adjacent_standable_node) or nil.
local DOOR_SEARCH = 16
local function find_reachable_door(mypos)
	local d = minetest.find_node_near(mypos, DOOR_SEARCH, {"group:door"}, true)
	if not d then return nil end
	local rp = vector.round(mypos)
	for _, o in ipairs({{x = 1, z = 0}, {x = -1, z = 0}, {x = 0, z = 1}, {x = 0, z = -1}}) do
		local nb = ground_under(vector.new(d.x + o.x, d.y, d.z + o.z))
		if nb then
			local p = minetest.find_path(rp, nb, PATH_SEARCH, 2, 3, "A*_noprefetch")
			if p then return d, p end
		end
	end
	return nil
end

-- Does a route to the goal exist if we could clear any wall (jump/build over)?
-- Used to decide build-over vs. mine-through when fully blocked.
local function can_build_over(mypos, goal)
	return minetest.find_path(vector.round(mypos), vector.round(goal),
		PATH_SEARCH, 30, 3, "A*_noprefetch") ~= nil
end

-- Returns a horizontal unit direction from mypos toward the goal, using a cached
-- A* path when possible and a straight-line fallback otherwise.
local function nav_dir(self, mypos, goal)
	local now = minetest.get_us_time() / 1e6
	local need = not self.path
		or not self.goal
		or vector.distance(self.goal, goal) > 2
		or (now - (self.path_time or 0)) > PATH_TIMEOUT

	if need then
		self.goal = vector.new(goal)
		self.path_time = now
		self.path_idx = 1
		self.path = compute_path(mypos, goal)
		self.blocked = false

		if not self.path then
			-- Can't walk any closer. Priority: head to a door to breach it; else
			-- straight-line toward the goal and breach the wall ahead (thin -> mine,
			-- thick -> build over if a route exists, otherwise mine).
			local door, dpath = find_reachable_door(mypos)
			if door then
				self.path = dpath
			else
				self.blocked = true
				self.can_build_over = can_build_over(mypos, goal)
			end
		end
	end

	local target = goal
	if self.path and self.path[self.path_idx] then
		-- Advance through reached waypoints
		while self.path[self.path_idx] and
				vector.distance({x = mypos.x, y = 0, z = mypos.z},
					{x = self.path[self.path_idx].x, y = 0, z = self.path[self.path_idx].z}) < 1.0 do
			self.path_idx = self.path_idx + 1
		end
		target = self.path[self.path_idx] or goal
	end

	local dir = vector.direction({x = mypos.x, y = 0, z = mypos.z},
		{x = target.x, y = 0, z = target.z})
	return dir
end

--------------------------------------------------------------------------------
-- Bot entity
--------------------------------------------------------------------------------
local ANIMS = {stand = ANIM_STAND, walk = ANIM_WALK, mine = ANIM_MINE}
local function set_anim(self, key)
	if self._anim == key then return end
	self._anim = key
	self.object:set_animation(ANIMS[key] or ANIM_STAND, 30, 0, true)
end

-- Keep the bot's current mapblock force-loaded so it never deactivates/despawns,
-- even with no players nearby. Re-applied as the bot crosses block boundaries.
local function keep_loaded(self, pos)
	local bhash = minetest.hash_node_position(vector.new(
		math.floor(pos.x / 16), math.floor(pos.y / 16), math.floor(pos.z / 16)))
	if bhash == self._floaded_hash then return end
	if self._floaded then minetest.forceload_free_block(self._floaded, true) end
	if minetest.forceload_block(pos, true) then
		self._floaded = vector.new(pos)
		self._floaded_hash = bhash
	else
		self._floaded, self._floaded_hash = nil, nil -- hit the forceload cap; rely on players
	end
end

local function free_loaded(self)
	if self._floaded then
		minetest.forceload_free_block(self._floaded, true)
		self._floaded, self._floaded_hash = nil, nil
	end
end

local function bot_die(self, killer)
	if self._dead then return end
	self._dead = true
	drop_flag(self)
	free_loaded(self)
	bots[self.id] = nil

	local team, role, skill, name, id = self.team, self.role, self.stats.skill, self.name, self.id
	if self.object then self.object:remove() end

	minetest.after(RESPAWN_TIME, function()
		if ctf_modebase.match_started then
			ctf_bots.spawn(team, role, skill, name, id)
		end
	end)
end

minetest.register_entity("ctf_bots:bot", {
	initial_properties = {
		hp_max = 200, -- match CTF players (PLAYER_MAX_HP_DEFAULT * 10)
		physical = true,
		collide_with_objects = true,
		collisionbox = {-0.3, 0.0, -0.3, 0.3, 1.7, 0.3},
		stepheight = 0.6,
		visual = "mesh",
		mesh = BOT_MESH,
		textures = BOT_TEXTURES,
		makes_footstep_sound = true,
	},

	on_activate = function(self, staticdata)
		local data = minetest.deserialize(staticdata) or {}
		self.team   = data.team
		self.role   = data.role or ROLES[math.random(#ROLES)]
		self.name   = data.name or ctf_bots.gen_name()
		self.stats  = ctf_bots.skill_stats(data.skill)
		self.id     = data.id or next_id
		next_id     = math.max(next_id, self.id + 1)
		self.carrying = nil
		self._think_acc = math.random() * self.stats.think -- phase-stagger
		self._fire_t = 0
		self._scan_t = 0

		-- A team is required; entities restored without a live match are removed.
		if not self.team or not team_data(self.team) then
			self.object:remove()
			return
		end

		bots[self.id] = self
		self.object:set_armor_groups({fleshy = 100})
		self.object:set_acceleration({x = 0, y = GRAVITY, z = 0})
		self.object:set_hp(200)

		set_anim(self, "stand")
	end,

	on_step = function(self, dtime)
		if self._dead then return end
		if self.object:get_hp() <= 0 then bot_die(self) return end

		-- Throttle the AI to the bot's reaction interval (skill-based).
		self._think_acc = self._think_acc + dtime
		if self._think_acc < self.stats.think then return end
		local step = self._think_acc
		self._think_acc = 0

		local mypos = self.object:get_pos()
		if not mypos then return end
		keep_loaded(self, mypos) -- never despawn, even with no players nearby

		if not ctf_modebase.match_started then
			local v = self.object:get_velocity()
			self.object:set_velocity({x = 0, y = v.y, z = 0})
			set_anim(self, "stand")
			return
		end

		local now = minetest.get_us_time() / 1e6

		-- ---- Sensing (cached) ----
		self._scan_t = self._scan_t - step
		if self._scan_t <= 0 then
			self._scan_t = TARGET_RESCAN
			self.target = find_target(self, mypos)
		end
		local target = self.target
		if target and not (target:get_pos() and target:is_valid()) then target = nil end

		local tpos = target and target:get_pos()
		local in_range = tpos and vector.distance(mypos, tpos) <= self.stats.view

		-- ---- Combat ----
		if target and in_range and has_los(eye_pos(self.object) or mypos, tpos) then
			self.object:set_yaw(vector.dir_to_rotation(vector.direction(mypos, tpos)).y)
			if now >= self._fire_t then
				self._fire_t = now + self.stats.fire_cooldown
				shoot(self, mypos, target, tpos)
			end
		end

		-- ---- Goal selection by role ----
		local goal
		local homedata = team_data(self.team)
		local homepos = homedata and homedata.flag_pos

		if self.role == "defend" then
			if tpos and homepos and vector.distance(tpos, homepos) < DEFEND_RADIUS
					and vector.distance(mypos, homepos) < DEFEND_RADIUS then
				goal = tpos
			else
				goal = homepos
			end
		else -- attack: push for the enemy flag and capture it, fighting en route
			if self.carrying then
				goal = homepos
				if homepos and vector.distance(mypos, homepos) < REACH_DIST then
					do_capture(self)
				end
			else
				-- Pick an available enemy flag to go for
				local et
				for _, e in ipairs(enemy_teams(self.team)) do
					if not ctf_modebase.flag_taken[e] and not ctf_modebase.flag_captured[e] then
						et = e break
					end
				end
				if et then
					local fp = team_data(et).flag_pos
					goal = fp
					if vector.distance(mypos, fp) < REACH_DIST then take_flag(self, et) end
				elseif tpos then
					goal = tpos -- no flag available: engage the nearest enemy
				else
					goal = ctf_map.current_map.flag_center
				end
			end
		end

		-- ---- Movement ----
		-- Prefer (in order): walk, jump small steps, swim, build up & over; only
		-- mine big thick walls as a last resort -- so no goal is ever unreachable.
		local v = self.object:get_velocity()
		local horiz_goal = goal and vector.distance(
			{x = mypos.x, y = 0, z = mypos.z}, {x = goal.x, y = 0, z = goal.z}) or 0
		local need_up = goal and (goal.y - mypos.y) > 1.2
		local need_down = goal and (goal.y - mypos.y) < -1.5

		if goal and (horiz_goal > 1.0 or need_up or need_down) then
			local feet = vector.round(mypos)
			local on_ground = math.abs(v.y) < 0.2

			-- Mining: stand still, play the mine animation for MINE_TIME, then break
			-- every queued node. No jumping while mining.
			if self._mining then
				self.object:set_velocity({x = 0, y = v.y, z = 0})
				set_anim(self, "mine")
				if now >= self._mining.t then
					for _, p in ipairs(self._mining.nodes) do
						if is_diggable(p) then minetest.remove_node(p) end
					end
					self._mining = nil
				end
				self._lastpos = mypos
				return
			end

			local dir = nav_dir(self, mypos, goal)
			local vx, vz = dir.x * MOVE_SPEED, dir.z * MOVE_SPEED
			local head = vector.offset(feet, 0, 1, 0)
			local moved = self._lastpos and vector.distance(self._lastpos, mypos) or 1
			local stuck = moved < 0.08
			self._stuck_time = stuck and (self._stuck_time or 0) + step or 0

			local function col(n) -- node column n steps ahead, at feet level
				return vector.new(
					math.floor(mypos.x + dir.x * n + 0.5), feet.y,
					math.floor(mypos.z + dir.z * n + 0.5))
			end

			-- Climb a scaffold pillar up & over the obstacle (preferred over mining).
			-- "Mine up and build up": if solid overburden caps the shaft, dig it out
			-- first, then keep pillaring -- so bots can tunnel straight up to a goal.
			local function build_up()
				local ceil = vector.offset(feet, 0, 2, 0) -- node above the bot's head
				if is_walkable(ceil) then
					if is_diggable(ceil) then
						self._mining = {t = now + MINE_TIME, nodes = {ceil}}
					end
					return
				end
				vx, vz = 0, 0
				if on_ground then v.y = JUMP_SPEED end
				local under = vector.new(feet.x, math.floor(mypos.y - 0.1), feet.z)
				if not is_walkable(under) and (mypos.y - under.y) > 0.45 then
					minetest.set_node(under, {name = BUILD_NODE})
				end
			end

			-- Hard anti-stuck (>5s): goal above -> build up; otherwise force-break
			-- whatever is in front (even non-mineable). Flags/barriers are spared.
			local forced_up = self._stuck_time > 5 and need_up
			if self._stuck_time > 5 and not need_up then
				for _, p in ipairs({col(1), vector.offset(col(1), 0, 1, 0)}) do
					local n = minetest.get_node(p)
					local nd = minetest.registered_nodes[n.name]
					if n.name ~= "air" and n.name ~= "ignore" and nd and nd.walkable
							and ((nd.groups or {}).immortal or 0) == 0 then
						minetest.remove_node(p)
					end
				end
			end

			if (is_liquid(feet) or is_liquid(head)) and not forced_up then
				-- Swim: rise when submerged, float at the surface; drift toward goal.
				v.y = is_liquid(head) and SWIM_UP or math.max(v.y, 0)
			elseif forced_up or (need_up and horiz_goal < 2.0) then
				build_up()
			elseif self.blocked and need_up and is_walkable(col(1))
					and (is_diggable(vector.offset(col(1), 0, 1, 0))
						or is_diggable(vector.offset(col(1), 0, 2, 0))) then
				-- "Mine up and straight": goal is up & ahead and we're blocked -- carve
				-- an ascending stairway (clear head + above-head ahead, leaving the
				-- foot block as a step to jump onto), advancing up and forward.
				local a1 = col(1)
				self._mining = {t = now + MINE_TIME,
					nodes = {vector.offset(a1, 0, 1, 0), vector.offset(a1, 0, 2, 0)}}
			elseif self.blocked and need_down
					and is_walkable(vector.offset(feet, 0, -1, 0))
					and is_diggable(vector.offset(feet, 0, -1, 0)) then
				-- "Mine down": goal is below and we're blocked by the floor -- dig
				-- straight down through it.
				vx, vz = 0, 0
				self._mining = {t = now + MINE_TIME, nodes = {vector.offset(feet, 0, -1, 0)}}
			elseif is_walkable(col(1)) then
				-- Solid obstacle directly ahead: measure it, then decide how to breach.
				local a1  = col(1)
				local a1h = vector.offset(a1, 0, 1, 0)
				local is_door = minetest.get_item_group(minetest.get_node(a1).name, "door") > 0
					or minetest.get_item_group(minetest.get_node(a1h).name, "door") > 0
				local diggable = is_diggable(a1) or is_diggable(a1h)
				local function mine() self._mining = {t = now + MINE_TIME, nodes = {a1, a1h}} end

				local height = 0
				while height < 8 and is_walkable(vector.offset(a1, 0, height, 0)) do
					height = height + 1
				end
				-- Must fit on top: 2 air nodes above the wall, else treat as solid.
				local top = vector.offset(a1, 0, height, 0)
				local fits_on_top = not is_walkable(top)
					and not is_walkable(vector.offset(top, 0, 1, 0))
				-- Wall thickness in travel direction (head height).
				local thick = 0
				while thick < 6 and is_walkable(vector.offset(col(1 + thick), 0, 1, 0)) do
					thick = thick + 1
				end

				-- Priority: mine doors > jump small steps > mine 1-thick walls >
				-- build up & over thick walls > mine if enclosed (no build-over route).
				if is_door and diggable then
					mine() -- bots can't open doors; tunnel straight through
				elseif height <= 2 and fits_on_top then
					if on_ground then v.y = JUMP_SPEED end
				elseif thick <= 1 and diggable then
					mine() -- one-block-thick wall: cheaper to punch through than build over
				elseif (not self.blocked or self.can_build_over) then
					build_up() -- thick wall with a route over it: build up & over (preferred)
				elseif diggable then
					mine() -- enclosed, nothing to build over: mine as the last resort
				else
					build_up()
				end
			elseif is_walkable(col(2)) and not is_walkable(vector.offset(col(2), 0, 1, 0)) then
				-- Obstacle one node further off: pre-jump to mount it smoothly.
				if on_ground then v.y = JUMP_SPEED end
			elseif on_ground and not is_walkable(vector.offset(col(1), 0, -1, 0))
					and not is_walkable(vector.offset(col(2), 0, -1, 0))
					and not is_liquid(col(1)) then
				-- Gap ahead (no floor for 2 nodes): leap across it.
				v.y = JUMP_SPEED
			elseif stuck and on_ground then
				v.y = JUMP_SPEED -- wedged: hop
			end

			self.object:set_velocity({x = vx, y = v.y, z = vz})
			if not (target and in_range) then
				self.object:set_yaw(vector.dir_to_rotation(dir).y)
			end
			set_anim(self, "walk")
		else
			self.object:set_velocity({x = 0, y = v.y, z = 0})
			set_anim(self, "stand")
			self._stuck_time = 0 -- idle/arrived, not stuck
		end
		self._lastpos = mypos
	end,

	on_punch = function(self, puncher, _, _, _, _)
		-- Friendly fire off: ignore damage from our own team (player or bot).
		local at = attacker_team(puncher)
		if at and at == self.team then return true end
		return false
	end,

	on_death = function(self, killer)
		bot_die(self, killer)
	end,

	on_deactivate = function(self)
		free_loaded(self) -- don't leak forceloads if the engine ever deactivates us
	end,

	-- Serialize identity so that if a block ever does unload/reload (e.g. the
	-- forceload cap was hit), the bot is restored instead of lost. on_activate
	-- removes it again if there's no live match, so nothing stale persists.
	get_staticdata = function(self)
		return minetest.serialize({
			team = self.team, role = self.role,
			skill = self.stats and self.stats.skill, name = self.name, id = self.id,
		})
	end,
})

--------------------------------------------------------------------------------
-- Spawning
--------------------------------------------------------------------------------
function ctf_bots.spawn(team, role, skill, name, id)
	if not ctf_modebase.in_game then return nil, "No match in progress" end
	local td = team_data(team)
	if not td then return nil, "Unknown/invalid team: " .. tostring(team) end
	if count_bots() >= MAX_BOTS then return nil, "Bot limit reached (" .. MAX_BOTS .. ")" end

	local pos = vector.offset(td.flag_pos, math.random(-1, 1), 0.5, math.random(-1, 1))
	minetest.load_area(pos)

	local newid = id or next_id
	next_id = math.max(next_id, newid + 1)

	local obj = minetest.add_entity(pos, "ctf_bots:bot", minetest.serialize({
		team = team,
		role = role,
		skill = skill,
		name = name,
		id = newid,
	}))
	if not obj then return nil, "Failed to spawn entity" end
	return obj
end

--------------------------------------------------------------------------------
-- Chat commands
--------------------------------------------------------------------------------
local function fewest_player_team()
	-- Default team = the one with the fewest connected players.
	local best, bestn
	for _, t in ipairs(ctf_teams.current_team_list or {}) do
		local n = ctf_teams.online_players[t] and ctf_teams.online_players[t].count or 0
		if not bestn or n < bestn then best, bestn = t, n end
	end
	return best
end

minetest.register_chatcommand("bot", {
	params = "[team] [attack|defend] [skill 1-6] [count]",
	description = "Spawn AI bot player(s)",
	privs = {server = true},
	func = function(name, param)
		if not ctf_modebase.in_game then
			return false, "No match is in progress."
		end
		local args = param:split(" ")
		local team, role, skill, count

		for _, a in ipairs(args) do
			if a == "" then -- skip
			elseif table.indexof(ctf_teams.current_team_list, a) ~= -1 then
				team = a
			elseif table.indexof(ROLES, a) ~= -1 then
				role = a
			elseif tonumber(a) then
				local n = math.floor(tonumber(a))
				if n >= 1 and n <= 6 and not skill then skill = n else count = n end
			else
				return false, "Unknown argument: " .. a
			end
		end

		team = team or fewest_player_team()
		count = math.max(1, count or 1)

		local spawned = 0
		for _ = 1, count do
			local obj, err = ctf_bots.spawn(team, role, skill)
			if obj then spawned = spawned + 1 else return false, err end
		end
		return true, ("Spawned %d bot(s) on team %s (%d/%d)"):format(
			spawned, team, count_bots(), MAX_BOTS)
	end,
})

minetest.register_chatcommand("startnow", {
	description = "Skip the build/gather phase and start the round immediately",
	privs = {server = true},
	func = function(name)
		if not ctf_modebase.in_game then
			return false, "No match is in progress."
		end
		if ctf_modebase.match_started then
			return false, "The match has already started."
		end
		minetest.log("action", "[ctf_bots] " .. name .. " ran /startnow")
		ctf_modebase.build_timer.finish()
		return true, "Build time ended."
	end,
})

minetest.register_chatcommand("botclear", {
	description = "Remove all AI bots",
	privs = {server = true},
	func = function()
		local n = 0
		for id, bot in pairs(bots) do
			drop_flag(bot)
			free_loaded(bot)
			if bot.object then bot.object:remove() end
			bots[id] = nil
			n = n + 1
		end
		return true, "Removed " .. n .. " bot(s)."
	end,
})

--------------------------------------------------------------------------------
-- Bot bullets vs players: CTF's own punch handler ignores non-player hitters, so
-- bot bullets deal no damage by default. Apply it here for enemy players only
-- (same-team = friendly fire, cancelled).
--------------------------------------------------------------------------------
minetest.register_on_punchplayer(function(player, hitter, _, _, _, damage)
	local le = hitter and hitter:get_luaentity()
	if not le or le.name ~= "bestguns:bullet" then return end
	if not (le.shooter_name or ""):match("^bot:%d+") then return end -- only bot bullets

	local at = attacker_team(hitter)
	local pteam = ctf_teams.get(player)
	if pteam and at ~= pteam and player:get_hp() > 0 then
		player:set_hp(player:get_hp() - (damage or le.damage or 0), {type = "punch", object = hitter})
	end
	return true -- handled (or friendly-fire cancelled); never apply engine default
end)

--------------------------------------------------------------------------------
-- Cleanup: wipe bots at match end so flag state never leaks across maps.
--------------------------------------------------------------------------------
ctf_api.register_on_match_end(function()
	for id, bot in pairs(bots) do
		free_loaded(bot)
		if bot.object then bot.object:remove() end
		bots[id] = nil
	end
end)
