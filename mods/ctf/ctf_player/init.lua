-- Override player_api model
player_api.registered_models["character.b3d"] = nil

player_api.register_model("character.b3d", {
	animation_speed = 30,
	-- Uses the Mineclonia player mesh (superset of the old bone rig).
	-- The mesh has two materials: layer 1 = skin, layer 2 = "Armor" overlay
	-- (shared by the carried-flag texture and the elytra wings).
	textures = {"character.png", "blank.png"},
	animations = {
		-- Standard animations (frame ranges match the Mineclonia mesh).
		stand     = {x = 0,   y = 79},
		lay       = {x = 162, y = 166, eye_height = 0.3,
			collisionbox = {-0.6, 0.0, -0.6, 0.6, 0.3, 0.6}},
		walk      = {x = 168, y = 187},
		mine      = {x = 189, y = 198},
		walk_mine = {x = 200, y = 219},
		sit       = {x = 81,  y = 160, eye_height = 0.8,
			collisionbox = {-0.3, 0.0, -0.3, 0.3, 1.0, 0.3}},
		-- Extra Mineclonia animations.
		sneak_stand      = {x = 222, y = 302},
		sneak_mine       = {x = 346, y = 365},
		sneak_walk       = {x = 304, y = 323},
		sneak_walk_mine  = {x = 325, y = 344},
		swim_walk        = {x = 368, y = 387},
		swim_walk_mine   = {x = 389, y = 408},
		swim_stand       = {x = 434, y = 434},
		swim_mine        = {x = 411, y = 430},
		run_walk         = {x = 440, y = 459},
		run_walk_mine    = {x = 461, y = 480},
		die              = {x = 498, y = 498},
		-- Elytra gliding.
		fly              = {x = 502, y = 581},
	},
	collisionbox = {-0.3, 0.01, -0.3, 0.3, 1.71, 0.3},
	stepheight = 0.6,
	eye_height = 1.47,
})

minetest.register_on_joinplayer(function(player)
	player:set_local_animation(nil, nil, nil, nil, 0)
end)

--------------------------------------------------------------------------------
-- Carried-flag visual: an external flag.glb model attached to the player's back.
-- (Replaces the old approach of painting the flag onto a player texture layer,
--  which no longer maps to a usable slot on the Mineclonia mesh.)
--------------------------------------------------------------------------------

ctf_player = ctf_player or {}

-- The flag is carried on the player's left arm. FLAG_POS/ROT are in the arm
-- bone's local space (~10 units per node, like the wield3d offsets where the
-- hand sits around y=5.5); tune them if the flag sits wrong on the arm.
local FLAG_BONE = "Arm_Left"
local FLAG_POS  = {x = 0, y = 5.4, z = 0}
local FLAG_ROT  = {x = 0, y = 0, z = 0}
local FLAG_SIZE = {x = 1, y = 1}

local flag_entities = {}                    -- [player_name] = ObjectRef

-- True while `name` is carrying a flag (the flag hangs off the left arm, so the
-- gun arm animation leaves that arm alone while a flag is attached).
function ctf_player.is_flag_carrier(name)
	return flag_entities[name] ~= nil
end

local function flag_texture(color)
	-- The mesh's single material shows a solid team-coloured cloth.
	return "wool_white.png^[colorize:" .. color .. ":255"
end

core.register_entity("ctf_player:flag", {
	initial_properties = {
		visual = "mesh",
		mesh = "flag.glb",
		textures = {"wool_white.png"},
		visual_size = FLAG_SIZE,
		physical = false,
		pointable = false,
		collide_with_objects = false,
		static_save = false,
	},
	on_step = function(self)
		-- Clean up if the carrier disappeared without a detach.
		if not self.wielder or not self.wielder:is_valid() then
			self.object:remove()
		end
	end,
})

-- Show (color = team colour string) or hide (color = nil) a player's carried flag.
function ctf_player.set_flag(player, color)
	if not player or not player:is_player() then return end
	local name = player:get_player_name()

	local existing = flag_entities[name]
	if existing and existing:get_luaentity() then
		existing:remove()
	end
	flag_entities[name] = nil

	if not color then return end

	local obj = core.add_entity(player:get_pos(), "ctf_player:flag")
	if not obj then return end
	obj:get_luaentity().wielder = player
	obj:set_properties({textures = {flag_texture(color)}})
	obj:set_attach(player, FLAG_BONE, FLAG_POS, FLAG_ROT)
	flag_entities[name] = obj
end

minetest.register_on_leaveplayer(function(player)
	ctf_player.set_flag(player, nil)
end)

-- Head/body/arm bone animation (Mineclonia-style look + gun arm posing).
dofile(minetest.get_modpath("ctf_player") .. "/player_anim.lua")