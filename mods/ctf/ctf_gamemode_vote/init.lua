local S = minetest.get_translator(minetest.get_current_modname())

local PAGE = "ctf_gamemode_vote:vote"

-- The fraction of online players that must agree before the mode is switched.
local THRESHOLD_NUM = 2
local THRESHOLD_DEN = 3

-- votes[player name] = mode technical name they voted for
local votes = {}

-- Set while a forced switch is in progress so we don't trigger it twice.
local switching = false

--- Number of human players currently connected (bots are entities, not clients).
local function player_count()
	return #minetest.get_connected_players()
end

--- How many equal votes are needed to force a switch, given who is online.
local function needed_votes()
	return math.ceil(player_count() * THRESHOLD_NUM / THRESHOLD_DEN)
end

--- counts[mode] = number of players currently voting for that mode
local function tally()
	local counts = {}
	for _, mode in pairs(votes) do
		counts[mode] = (counts[mode] or 0) + 1
	end
	return counts
end

--- Redraw the Vote tab for anyone who currently has it open.
local function refresh_voters()
	for _, player in ipairs(minetest.get_connected_players()) do
		if sfinv.get_page(player) == PAGE then
			sfinv.set_player_inventory_formspec(player)
		end
	end
end

--- If any (non-current) mode has reached the vote threshold, switch to it.
local function check_and_switch()
	if switching then return end

	-- Mirror /ctf_skip: don't try to switch while a map is still loading.
	if not ctf_modebase.in_game then return end

	local needed = needed_votes()
	if needed < 1 then return end

	local current = ctf_modebase.current_mode
	local counts = tally()

	for mode, count in pairs(counts) do
		if mode ~= current and count >= needed then
			switching = true
			votes = {}

			minetest.chat_send_all(minetest.colorize("#00ffff", S(
				"[Vote] @1 votes reached: switching the gamemode to @2...",
				count, HumanReadable(mode)
			)))

			-- Force the next match to use the voted mode (same path as /ctf_next -f).
			ctf_modebase.mode_on_next_match = mode
			ctf_modebase.start_new_match()
			return
		end
	end
end

--- Record a player's vote, announce it, and re-check the threshold.
local function player_vote(name, mode)
	votes[name] = mode

	local counts = tally()

	minetest.chat_send_all(minetest.colorize("#ffcc00", S(
		"[Vote] @1 wants to switch the gamemode to @2 (@3/@4 votes). "..
		"Open your inventory and pick the \"Vote\" tab to vote too!",
		name, HumanReadable(mode), counts[mode] or 0, needed_votes()
	)))

	refresh_voters()
	check_and_switch()
end

sfinv.register_page(PAGE, {
	title = S("Vote"),
	get = function(self, player, context)
		local pname = player:get_player_name()
		local counts = tally()
		local myvote = votes[pname]
		local current = ctf_modebase.current_mode

		local fs = {
			string.format("label[0,0.1;%s]", minetest.formspec_escape(
				S("Vote to switch the gamemode"))),
			string.format("label[0,0.5;%s]", minetest.formspec_escape(
				S("@1/@2 of online players must agree. Need @3 of @4 votes.",
					THRESHOLD_NUM, THRESHOLD_DEN, needed_votes(), player_count()))),
		}

		local y = 1.2
		for _, mode in ipairs(ctf_modebase.modelist) do
			local human = HumanReadable(mode)

			if mode == current then
				fs[#fs + 1] = string.format("label[0.1,%f;%s]", y + 0.2,
					minetest.formspec_escape(S("@1  (current mode)", human)))
			else
				local label = string.format("%s  [%d]", human, counts[mode] or 0)
				if myvote == mode then
					label = label .. "   " .. S("<-- your vote")
				end
				fs[#fs + 1] = string.format("button[0,%f;5,0.6;vote_%s;%s]",
					y, mode, minetest.formspec_escape(label))
			end

			y = y + 0.75
		end

		if myvote then
			fs[#fs + 1] = string.format("button[0,%f;5,0.6;clear_vote;%s]",
				y + 0.15, minetest.formspec_escape(S("Clear my vote")))
		end

		return sfinv.make_formspec(player, context, table.concat(fs), false)
	end,
	on_player_receive_fields = function(self, player, context, fields)
		local pname = player:get_player_name()

		if fields.clear_vote then
			votes[pname] = nil
			refresh_voters()
			return true
		end

		for _, mode in ipairs(ctf_modebase.modelist) do
			if fields["vote_" .. mode] then
				-- Voting for the current mode does nothing (there's nothing to switch to).
				if mode ~= ctf_modebase.current_mode then
					player_vote(pname, mode)
				end
				return true
			end
		end
	end,
})

-- Clear all votes at the start of each match so a fresh vote begins each round.
ctf_api.register_on_new_match(function()
	votes = {}
	switching = false
	refresh_voters()
end)

-- When a player leaves, drop their vote and re-check: fewer players means a
-- lower threshold, so an existing vote may now be enough to switch.
minetest.register_on_leaveplayer(function(player)
	votes[player:get_player_name()] = nil

	-- Defer so get_connected_players() no longer counts the leaving player.
	minetest.after(0, function()
		refresh_voters()
		check_and_switch()
	end)
end)
