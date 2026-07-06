hpbar_hud = {}

local ids = {}
-- [pname] = true for players whose on-screen HP statbar should be hidden
local hidden = {}

local texture_res = 24 -- heart texture resolution

minetest.register_on_joinplayer(function(player)
	player:hud_set_flags({healthbar = false}) -- Hide the builtin HP bar
	-- Add own HP bar with the same visuals as the builtin one
	ids[player:get_player_name()] = player:hud_add({
		hud_elem_type = "statbar",
		position = {x = 0.5, y = 1},
		text = "heart.png",
		text2 = "heart_gone.png",
		number = minetest.PLAYER_MAX_HP_DEFAULT,
		item = minetest.PLAYER_MAX_HP_DEFAULT,
		direction = 0,
		size = {x = texture_res, y = texture_res},
		offset = {x = - 264, y = -(48 + texture_res + 16)},
	})
end)

minetest.register_on_leaveplayer(function(player)
	local pname = player:get_player_name()
	ids[pname] = nil
	hidden[pname] = nil
end)

-- Hide or show a player's on-screen HP statbar (e.g. while spectating).
function hpbar_hud.set_hidden(player, is_hidden)
	local pname = player:get_player_name()
	hidden[pname] = is_hidden or nil

	local id = ids[pname]
	if not id then return end

	if is_hidden then
		player:hud_change(id, "number", 0)
		player:hud_change(id, "item", 0)
	else
		player:hud_change(id, "item", math.round(player:get_properties().hp_max / 10))
		player:hud_change(id, "number", math.round(player:get_hp() / 10))
	end
end

-- HACK `register_playerevent` is not documented, but used to implement statbars by MT internally
minetest.register_playerevent(function(player, eventname)
	local pname = player:get_player_name()
	local id = ids[pname]
	if not id or hidden[pname] then return end

	if eventname == "health_changed" then
		player:hud_change(id, "number", math.round(player:get_hp() / 10))
	elseif eventname == "properties_changed" then
		-- HP max has probably changed, update HP bar background size ("item") accordingly
		player:hud_change(id, "item", math.round(player:get_properties().hp_max / 10))
	end
end)