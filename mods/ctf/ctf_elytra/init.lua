--[[
	ctf_elytra
	Mineclonia-style elytra for Capture the Flag.

	- Equip by HOLDING right-click while the elytra is your wielded item.
	- Once worn, wings show on the player's back.
	- Double-jump while airborne to start gliding (same trigger as Mineclonia).
	- Gliding physics are ported directly from Mineclonia's playerphysics/elytra.lua.
	- The elytra wears down (~1/sec of flight) and breaks after ~25 seconds of use.
	- Unequip (returning the item) by holding sneak + right-click, or with /elytra.
]]

ctf_elytra = {}

local S = core.get_translator("ctf_elytra")

------------------------------------------------------------------------
-- Tunables (physics constants copied from Mineclonia)
------------------------------------------------------------------------
local GRAVITY = -1.6
local ONE_TICK = 0.05
local AIR_DRAG = 0.98
local FALL_FLYING_DRAG_HORIZ = 0.99
local FALL_FLYING_DRAG_ASCENT = 0.04
local FALL_FLYING_ACC_DESCENT = 3.2
local FALL_FLYING_ROTATION_DRAG = 0.1

local USES = 25                                   -- seconds of flight before breaking
local WEAR_PER_SEC = math.ceil(65535 / USES)      -- wear added per second of flight

local EQUIP_HOLD_TIME = 0.4                        -- seconds of RMB hold to equip
local UNEQUIP_HOLD_TIME = 0.5                      -- seconds of sneak+RMB hold to unequip
local JUMP_MIN_INTERVAL = 0.1                      -- min seconds between counted jumps

-- The Mineclonia mesh has two materials: Skin (layer 1) and Armor (layer 2).
-- The elytra wings render on the Armor layer. (The carried flag is a separate
-- attached model now, so nothing else contends for this layer.)
local WINGS_TEXTURE = "mcl_armor_elytra.png"
local OVERLAY_LAYER = 2
local SAFE_FALL_DISTANCE = 3.0

------------------------------------------------------------------------
-- Per-player state
------------------------------------------------------------------------
local equipped = {}       -- [name] = ItemStack (the worn elytra)
local flying = {}         -- [name] = elytra entity luaentity (while gliding)
local equip_hold = {}     -- [name] = seconds RMB held (equip)
local unequip_hold = {}   -- [name] = seconds sneak+RMB held (unequip)
local jump_state = {}     -- [name] = {count=, last_jump=, pressing=}
local hud = {}            -- [name] = {id=, text=} (remaining-time HUD)

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------
local function is_elytra_item(name)
	return core.get_item_group(name, "elytra") > 0
end

-- An elytra is usable until 1 unit of durability remains (mirrors Mineclonia).
local function stack_usable(stack)
	return stack and not stack:is_empty() and stack:get_wear() < (65535 - WEAR_PER_SEC)
end

-- Seconds of flight left in an elytra stack (wear only ticks while gliding).
local function remaining_seconds(stack)
	if not stack then return 0 end
	return math.max(0, (65535 - stack:get_wear()) / WEAR_PER_SEC)
end

-- Show/update/hide the remaining-flight-time HUD for a player.
local function update_hud(player)
	local name = player:get_player_name()
	local stack = equipped[name]

	if not stack then
		if hud[name] then
			player:hud_remove(hud[name].id)
			hud[name] = nil
		end
		return
	end

	local text = S("Elytra: @1s", string.format("%.1f", remaining_seconds(stack)))
	if not hud[name] then
		hud[name] = {
			id = player:hud_add({
				hud_elem_type = "text",
				position = {x = 0.5, y = 0.88},
				alignment = {x = 0, y = 0},
				offset = {x = 0, y = 0},
				text = text,
				number = 0x8FD3FF,
				z_index = 100,
			}),
			text = text,
		}
	elseif hud[name].text ~= text then
		player:hud_change(hud[name].id, "text", text)
		hud[name].text = text
	end
end

-- Show/hide the elytra wings on the Armor overlay layer.
function ctf_elytra.set_wings(player, on)
	if not player or not player:is_player() then return end
	if not player_api.players[player:get_player_name()] then return end
	player_api.set_texture(player, OVERLAY_LAYER, on and WINGS_TEXTURE or "blank.png")
end

local function equip(player, wielded)
	local name = player:get_player_name()
	-- Pull a single elytra out of the wielded stack and wear it.
	local worn = ItemStack(wielded:get_name())
	worn:set_wear(wielded:get_wear())
	wielded:take_item(1)
	player:set_wielded_item(wielded)

	equipped[name] = worn
	ctf_elytra.set_wings(player, true)
	core.chat_send_player(name, core.colorize("#8fd3ff",
		S("Elytra equipped. Double-jump in the air to glide.")))
end

local function unequip(player, drop_broken)
	local name = player:get_player_name()
	local worn = equipped[name]
	equipped[name] = nil
	ctf_elytra.set_wings(player, false)

	if not worn then return end
	if drop_broken then return end -- broken elytra is consumed

	-- Return the elytra to the player (or drop it if the inventory is full).
	local inv = player:get_inventory()
	local leftover = inv:add_item("main", worn)
	if leftover and not leftover:is_empty() then
		core.add_item(player:get_pos(), leftover)
	end
end

-- Stop a glide in progress (detaching handled by the entity).
local function stop_flight(player)
	local name = player:get_player_name()
	local ent = flying[name]
	if ent and ent.object and ent.object:get_luaentity() then
		ent:detach(player)
	else
		flying[name] = nil
		if player_api.player_attached then
			player_api.player_attached[name] = false
		end
	end
end

------------------------------------------------------------------------
-- Elytra glide entity (physics ported from Mineclonia)
------------------------------------------------------------------------
local function hurt(player, amt, reason)
	if not player or not player:is_valid() or amt <= 0 then return end
	local hp = player:get_hp()
	if hp <= 0 then return end
	player:set_hp(math.max(0, hp - amt), reason)
end

local function horiz_collision(moveresult)
	for _, item in ipairs(moveresult.collisions) do
		if item.axis == "x" or item.axis == "z" then
			if item.type ~= "node" or core.get_node_or_nil(item.node_pos) then
				return true, item.old_velocity, item.new_velocity
			end
		end
	end
	return false, nil
end

local cid_ignore = core.CONTENT_IGNORE

local function touching_only_ignore(moveresult)
	for _, item in pairs(moveresult.collisions) do
		if item.axis == "y" and item.old_velocity.y < 0 then
			if item.type ~= "node" then
				return false
			else
				local cid = core.get_node_raw(item.node_pos.x, item.node_pos.y, item.node_pos.z)
				if cid ~= cid_ignore then
					return false
				end
			end
		end
	end
	return true
end

local elytra_entity = {
	initial_properties = {
		visual = "mesh",
		mesh = "mcl_elytra_entity.obj",
		textures = { "blank.png" },
		visual_size = {x = 1.0, y = 1.0},
		collisionbox = {-0.25, -0.25, -0.25, 0.25, 0.25, 0.25},
		pointable = false,
		physical = true,
		collide_with_objects = false,
		static_save = false,
	},
	_horiz_collision = false,
	_damage_immune = 0,
	_timer = 0,
	_last_fall_y = nil,
	_fall_distance = 0,
}

function elytra_entity:rotate()
	local player = self.driver
	local pitch = -player:get_look_vertical()
	local yaw = player:get_look_horizontal()
	self.object:set_rotation(vector.new(pitch, yaw, 0))
end

function elytra_entity:attach(player)
	local name = player:get_player_name()
	flying[name] = self
	self.driver = player
	self.object:set_velocity(player:get_velocity())
	player:set_attach(self.object, "", vector.zero(), vector.zero())
	if player_api.player_attached then
		player_api.player_attached[name] = true
	end
	player_api.set_animation(player, "fly")
end

function elytra_entity:remove(player)
	local name = player:get_player_name()
	flying[name] = nil
	if player_api.player_attached then
		player_api.player_attached[name] = false
	end
	self.object:remove()
end

function elytra_entity:detach(player)
	local v = self.object:get_velocity()
	self:remove(player)
	if player and player:is_valid() then
		player:set_detach()
		if v then player:add_velocity(v) end
		player_api.set_animation(player, "stand")
	end
end

function elytra_entity:check_horiz_collision(moveresult)
	local player = self.driver
	self._damage_immune = math.max(self._damage_immune - 1, 0)

	local old, new
	self._horiz_collision, old, new = horiz_collision(moveresult)

	if self._horiz_collision and old and new then
		local diff = math.abs(vector.length(old) - vector.length(new))
		if diff >= 6.0 and self._damage_immune == 0 then
			hurt(player, diff * 0.5, {type = "fall", from = "mod"})
			self._damage_immune = 10
		end
	end
end

function elytra_entity:consume_durability(dtime)
	self._timer = self._timer + dtime
	if self._timer < 1.0 then return end
	self._timer = self._timer - 1.0

	local player = self.driver
	local name = player:get_player_name()

	local stack = equipped[name]
	if not stack then
		self:detach(player)
		return
	end

	local wear = stack:get_wear() + WEAR_PER_SEC
	if wear >= 65535 then
		unequip(player, true) -- consume the broken elytra
		core.chat_send_player(name, core.colorize("#ff8080", S("Your elytra broke!")))
		self:detach(player)
	else
		stack:set_wear(wear)
	end
end

function elytra_entity:step_fall_flying(dtime)
	local player = self.driver
	local v = self.object:get_velocity()
	if not v then
		self:detach(player)
		return
	end

	-- Detach if the worn elytra is gone (broke, unequipped, etc.)
	if not stack_usable(equipped[player:get_player_name()]) then
		self:detach(player)
		return
	end

	if v.y > -10.0 and self._fall_distance > 1.0 then
		self._fall_distance = 1.0
	end

	local dir = player:get_look_dir()
	local pitch = player:get_look_vertical()
	local horiz = math.sqrt(dir.x * dir.x + dir.z * dir.z)
	local movement = math.sqrt(v.x * v.x + v.z * v.z)
	local incline = math.cos(pitch)
	local v_movement = incline * incline

	local D = AIR_DRAG
	local default_b = -0.1 * v_movement
	local a = -GRAVITY * (-1.0 + v_movement * 0.75)
	local n = dtime / ONE_TICK
	local c = v.y * D ^ (n) + (a * D * ((D ^ n) - 1)) / (D - 1)
	local b = (c < 0.0 and horiz > 0.0) and default_b or 0
	local a_factor = ((b + 1) * D * ((((b + 1) * D) ^ n) - 1)) / (b * D + D - 1)
	v.y = v.y * (((b + 1) * D) ^ (n)) + a * a_factor

	D = FALL_FLYING_DRAG_HORIZ
	local h_factor = (D * ((D ^ n) - 1)) / (D - 1)

	if c < 0.0 and horiz > 0.0 then
		local d = (dir.x * (default_b * c) / horiz)
		local e = (dir.z * (default_b * c) / horiz)
		v.x = v.x * (D ^ (n)) + (d * h_factor)
		v.z = v.z * (D ^ (n)) + (e * h_factor)
	end
	if horiz > 0.0 and pitch < 0.0 then
		local arrest = movement * -math.sin(pitch) * FALL_FLYING_DRAG_ASCENT
		v.x = v.x + -dir.x * arrest / horiz * h_factor
		v.y = v.y + arrest * FALL_FLYING_ACC_DESCENT * a_factor
		v.z = v.z + -dir.z * arrest / horiz * h_factor
	end
	if horiz > 0.0 then
		v.x = v.x + (dir.x / horiz * movement - v.x) * FALL_FLYING_ROTATION_DRAG * h_factor
		v.z = v.z + (dir.z / horiz * movement - v.z) * FALL_FLYING_ROTATION_DRAG * h_factor
	end

	self.object:set_velocity(v)
end

function elytra_entity:underwater()
	local player = self.driver
	local pos = player:get_pos()
	local node = core.get_node(vector.offset(pos, 0, -0.1, 0)).name
	local def = core.registered_nodes[node]
	local liquid_type = def and (def.liquidtype or def._liquidtype)
	if liquid_type and liquid_type ~= "none" then
		self:detach(player)
		return true
	end
	return false
end

function elytra_entity:check_fall_damage(moveresult)
	local self_pos = self.object:get_pos()
	if not self_pos then return end
	local fall_y = self._last_fall_y or self_pos.y
	self._fall_distance = math.max(self._fall_distance + (fall_y - self_pos.y), 0)
	self._last_fall_y = self_pos.y

	if moveresult.touching_ground and not touching_only_ignore(moveresult) then
		if self._fall_distance > SAFE_FALL_DISTANCE and self.driver:is_valid() then
			hurt(self.driver, self._fall_distance, {type = "fall"})
		end
		self._last_fall_y = nil
		self._fall_distance = 0
	end
end

function elytra_entity:on_step(dtime, moveresult)
	if not self.driver or not self.driver:is_valid() or not moveresult then
		if self.object then self.object:remove() end
		return
	end

	self:consume_durability(dtime)
	if not self.object:is_valid() then return end

	self:check_horiz_collision(moveresult)
	if not self:underwater() then
		self:rotate()
		self:check_fall_damage(moveresult)
		self:step_fall_flying(dtime)
	end

	if not self.object:is_valid() then return end

	-- If the player got attached to something else, bail out.
	local attach = self.driver:get_attach()
	if attach and attach:get_luaentity()
			and attach:get_luaentity().name ~= "ctf_elytra:elytra_entity" then
		self:remove(self.driver)
		return
	end

	if moveresult.touching_ground then
		self:detach(self.driver)
	end
end

core.register_entity("ctf_elytra:elytra_entity", elytra_entity)

local function start_flight(player)
	local pos = player:get_pos()
	local obj = core.add_entity(pos, "ctf_elytra:elytra_entity")
	if obj then
		player:set_pos(vector.offset(pos, 0, 1, 0))
		obj:get_luaentity():attach(player)
	end
end

------------------------------------------------------------------------
-- Item
------------------------------------------------------------------------
core.register_tool("ctf_elytra:elytra", {
	description = S("Elytra") .. "\n" ..
		core.colorize("#bbbbbb", S("Hold right-click to equip, then double-jump in the air to glide")),
	inventory_image = "mcl_armor_inv_elytra.png",
	groups = { elytra = 1, ctf_elytra = 1 },
})

------------------------------------------------------------------------
-- Main per-player loop: equip / unequip / flight launch
------------------------------------------------------------------------
core.register_globalstep(function(dtime)
	for _, player in ipairs(core.get_connected_players()) do
		local name = player:get_player_name()
		local control = player:get_player_control()
		local wielded = player:get_wielded_item()
		local holding_elytra = is_elytra_item(wielded:get_name())

		-- --- Equip (hold RMB while wielding an elytra) ---
		if not equipped[name] and holding_elytra and control.RMB and not control.sneak then
			equip_hold[name] = (equip_hold[name] or 0) + dtime
			if equip_hold[name] >= EQUIP_HOLD_TIME then
				equip(player, wielded)
				equip_hold[name] = 0
			end
		else
			equip_hold[name] = 0
		end

		-- --- Unequip (hold sneak + RMB while worn and not gliding) ---
		if equipped[name] and not flying[name] and control.sneak and control.RMB then
			unequip_hold[name] = (unequip_hold[name] or 0) + dtime
			if unequip_hold[name] >= UNEQUIP_HOLD_TIME then
				unequip(player, false)
				core.chat_send_player(name, core.colorize("#bbbbbb", S("Elytra unequipped.")))
				unequip_hold[name] = 0
			end
		else
			unequip_hold[name] = 0
		end

		-- --- Flight launch: double-jump while airborne (Mineclonia trigger) ---
		if equipped[name] and stack_usable(equipped[name]) and not flying[name]
				and not player:get_attach() then
			local js = jump_state[name]
			if not js then
				js = {count = 0, last_jump = 0, pressing = false}
				jump_state[name] = js
			end

			local vy = player:get_velocity().y
			local now = core.get_us_time() / 1e6
			if vy == 0 then
				js.count = 0
			elseif control.jump and not js.pressing
					and (now - js.last_jump) > JUMP_MIN_INTERVAL then
				js.count = js.count + 1
				js.last_jump = now
			end
			js.pressing = control.jump

			local pos = player:get_pos()
			local below = core.get_node(vector.offset(pos, 0, -0.1, 0)).name
			local bdef = core.registered_nodes[below]
			local grounded = bdef and bdef.walkable and below ~= "ignore"

			if js.count >= 2 and not grounded then
				start_flight(player)
				jump_state[name] = nil
			end
		elseif jump_state[name] and (flying[name] or player:get_attach()) then
			jump_state[name] = nil
		end

		-- --- Remaining-time HUD ---
		update_hud(player)
	end
end)

------------------------------------------------------------------------
-- Cleanup
------------------------------------------------------------------------
core.register_on_dieplayer(function(player)
	stop_flight(player)
	unequip(player, true) -- consume the elytra on death; don't return it
end)

core.register_on_leaveplayer(function(player)
	local name = player:get_player_name()
	stop_flight(player)
	equipped[name] = nil
	flying[name] = nil
	equip_hold[name] = nil
	unequip_hold[name] = nil
	jump_state[name] = nil
	hud[name] = nil
end)

core.register_chatcommand("elytra", {
	description = S("Toggle your equipped elytra off (returns the item)"),
	func = function(name)
		local player = core.get_player_by_name(name)
		if not player then return false end
		if not equipped[name] then
			return false, S("You don't have an elytra equipped.")
		end
		stop_flight(player)
		unequip(player, false)
		return true, S("Elytra unequipped.")
	end,
})

------------------------------------------------------------------------
-- Loot: rare treasure-chest item (~2%)
------------------------------------------------------------------------
if core.global_exists("ctf_map") and ctf_map.treasure and ctf_map.treasure.register_filler then
	ctf_map.treasure.register_filler(function(inv)
		if math.random() < 0.02 then
			inv:add_item("main", ItemStack("ctf_elytra:elytra"))
		end
	end)
end
