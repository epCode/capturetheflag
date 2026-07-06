local hud = mhud.init()

local DEFAULT_BUILD_TIME = 60 * 3

local timer = nil

ctf_modebase.build_timer = {}

local S = minetest.get_translator(minetest.get_current_modname())

local function timer_func(time_left)
	for _, player in pairs(minetest.get_connected_players()) do
		local time_str = S("Removing Barrier").."..."

		if time_left > 0 then
			time_str = S("@1m @2s until match begins!", math.floor(time_left / 60), math.floor(time_left % 60))
		end

		if not hud:exists(player, "build_timer") then
			hud:add(player, "build_timer", {
				hud_elem_type = "text",
				position = {x = 0.5, y = 0.5},
				offset = {x = 0, y = -42},
				text = time_str,
				color = 0xFFFFFF,
			})
		else
			hud:change(player, "build_timer", {
				text = time_str
			})
		end

		local pteam = ctf_teams.get(player)
		local tpos1, tpos2 = ctf_teams.get_team_territory(pteam)
		if pteam and tpos1 and not ctf_core.pos_inside(player:get_pos(), tpos1, tpos2) then
			hud_events.new(player, {
				quick = true,
				text = S("You can't cross the barrier until build time is over!"),
				color = "warning",
			})
			player:set_pos(ctf_map.current_map.teams[pteam].flag_pos)
		end
	end

	if time_left <= 0 then
		ctf_modebase.build_timer.finish()
		return
	end

	timer = minetest.after(1, timer_func, time_left - 1)
end

local function do_match_start(skip_message)
	if timer then
		timer:cancel()
		timer = nil
	end

	hud:remove_all()

	if not skip_message then
		local text = S("Build time is over!")
		minetest.chat_send_all(text)
		ctf_modebase.announce(minetest.get_translated_string("en", text))
	end

	ctf_modebase.on_match_start()

	minetest.sound_play("ctf_modebase_build_time_over", {
		gain = 1.0,
		pitch = 1.0,
	}, true)
end

-- Removes the build-time barrier (if there is a map) and starts the match.
-- skip_message is used by modes with no build time (e.g. deathmatch).
local function finish_build_timer(skip_message)
	if ctf_map.current_map then
		ctf_map.remove_barrier(ctf_map.current_map, function()
			do_match_start(skip_message)
		end)
	else
		do_match_start(skip_message)
	end
end

function ctf_modebase.build_timer.start(build_time)
	local time = build_time or ctf_modebase:get_current_mode().build_timer or DEFAULT_BUILD_TIME

	if time > 0 then
		if timer then timer:cancel() end
		timer = timer_func(time)
	else
		-- No build time: remove the barrier and start the match immediately
		finish_build_timer(true)
	end
end

function ctf_modebase.build_timer.finish()
	if timer == nil then return end

	finish_build_timer(false)
end

ctf_api.register_on_match_end(function()
	if timer == nil then return end
	timer:cancel()
	timer = nil
	hud:remove_all()
end)

local old_protected = minetest.is_protected
minetest.is_protected = function(pos, pname, ...)
	if timer == nil then
		return old_protected(pos, pname, ...)
	end

	local pteam = ctf_teams.get(pname)

	if pteam and ctf_teams.get_team_territory(pteam) and
		not ctf_core.pos_inside(pos, ctf_teams.get_team_territory(pteam))
	then
		hud_events.new(pname, {
			quick = true,
			text = S("You can't interact outside of your team territory during build time!"),
			color = "warning",
		})

		return true
	else
		return old_protected(pos, pname, ...)
	end
end

minetest.register_chatcommand("ctf_start", {
	description = S("Skip build time"),
	privs = {ctf_admin = true},
	func = function(name, param)
		minetest.log("action", string.format("[ctf_admin] %s ran /ctf_start", name))

		ctf_modebase.build_timer.finish()

		return true, S("Build time ended")
	end,
})
