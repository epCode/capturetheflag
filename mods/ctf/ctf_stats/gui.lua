-- /stats : a visual combat-stats card for a player.
--
-- Top band of headline stat tiles (kills, K/D, accuracy, ...), then a per-gun
-- table (shots / hits / accuracy / kills / headshots), sorted by kills.

local esc = minetest.formspec_escape

--------------------------------------------------------------------------------
-- Number/format helpers
--------------------------------------------------------------------------------

-- Two-decimal number with trailing zeros trimmed: 2.00 -> "2", 1.50 -> "1.5".
local function trim(n)
	local s = string.format("%.2f", n)
	s = s:gsub("%.?0+$", "")
	return s == "" and "0" or s
end

-- Kills-per-death: divide by deaths, but treat 0 deaths as 1 so a flawless
-- record reads as its kill count rather than infinity.
local function kd(s)
	return trim(s.kills / math.max(s.deaths, 1))
end

local function pct(hit, total)
	if total <= 0 then return "0%" end
	return trim(hit / total * 100) .. "%"
end

local function fmt_time(sec)
	sec = math.floor(sec)
	local h = math.floor(sec / 3600)
	local m = math.floor((sec % 3600) / 60)
	if h > 0 then return h .. "h " .. m .. "m" end
	return m .. "m " .. (sec % 60) .. "s"
end

local function gun_desc(gun)
	local def = minetest.get_modpath("bestguns") and bestguns.registered_guns[gun]
	return (def and def.description) or gun:gsub("^.-:", ""):gsub("_", " ")
end

-- Most-killed-with weapon (tie-broken by hits), for the "favourite" tile.
local function favourite(s)
	local best, bk, bh
	for gun, g in pairs(s.guns) do
		if not best or g.kills > bk or (g.kills == bk and g.hits > bh) then
			best, bk, bh = gun, g.kills, g.hits
		end
	end
	if not best or bk == 0 then return "-" end
	return gun_desc(best)
end

--------------------------------------------------------------------------------
-- Theme (shared look with /guninfo)
--------------------------------------------------------------------------------

local COL = {
	bg    = "#12141C",
	panel = "#1B1E2A",
	head  = "#2A2F40",
	row_a = "#242838",
	row_b = "#1E2130",
	tile  = "#1E2233",
	accent= "#3D9BE5",
	kills = "#5FD08A",
	death = "#E5533D",
	name  = "#FFFFFF",
	key   = "#7E8AA3",
	value = "#EDF1F8",
	title = "#FFD54A",
	sub   = "#8A93A6",
}

--------------------------------------------------------------------------------
-- Layout
--------------------------------------------------------------------------------

local W          = 13.0
local MARGIN     = 0.5
local TILE_COLS  = 5
local TILE_GAP   = 0.2
local TILE_H     = 1.5
local TILE_W     = (W - 2 * MARGIN - (TILE_COLS - 1) * TILE_GAP) / TILE_COLS

-- One headline stat tile. `accent` colours the value (defaults to value white).
local function tile(out, i, y, label, value, accent)
	local col = i % TILE_COLS
	local x = MARGIN + col * (TILE_W + TILE_GAP)
	out[#out + 1] = string.format("box[%f,%f;%f,%f;%s]", x, y, TILE_W, TILE_H, COL.tile)
	out[#out + 1] = "style_type[label;font=normal;font_size=*0.8;textcolor=" .. COL.key .. "]"
	out[#out + 1] = string.format("label[%f,%f;%s]", x + 0.2, y + 0.32, esc(label))
	out[#out + 1] = "style_type[label;font=bold;font_size=*1.55;textcolor=" .. (accent or COL.value) .. "]"
	out[#out + 1] = string.format("label[%f,%f;%s]", x + 0.2, y + 1.02, esc(value))
end

-- Per-gun table geometry.
local GCOLS = {
	{ id = "name",  label = "WEAPON",    w = 4.2 },
	{ id = "shots", label = "SHOTS",     w = 1.5 },
	{ id = "hits",  label = "HITS",      w = 1.5 },
	{ id = "acc",   label = "ACCURACY",  w = 2.0 },
	{ id = "kills", label = "KILLS",     w = 1.5 },
	{ id = "hs",    label = "HEADSHOTS", w = 1.3 },
}
local GX = {}
do
	local x = MARGIN + 0.15
	for _, c in ipairs(GCOLS) do
		GX[c.id] = x
		x = x + c.w
	end
end
local GROW_H = 0.62

-- Rows for every gun the player has used, most kills first.
local function gun_rows(s)
	local rows = {}
	for gun, g in pairs(s.guns) do
		if (g.shots or 0) > 0 or (g.kills or 0) > 0 then
			rows[#rows + 1] = {gun = gun, g = g}
		end
	end
	table.sort(rows, function(a, b)
		if a.g.kills ~= b.g.kills then return a.g.kills > b.g.kills end
		if a.g.hits ~= b.g.hits then return a.g.hits > b.g.hits end
		return a.g.shots > b.g.shots
	end)
	return rows
end

--------------------------------------------------------------------------------
-- Formspec
--------------------------------------------------------------------------------

local function build_formspec(target, s)
	local out = {}

	local tiles_y = 1.55
	local tiles_rows = 2
	local table_hdr_y = tiles_y + tiles_rows * (TILE_H + TILE_GAP) + 0.25
	local table_y = table_hdr_y + 0.6

	local rows = gun_rows(s)
	local VIEW_ROWS = 6
	local rows_h = #rows * GROW_H
	local rows_view_h = math.min(math.max(rows_h, GROW_H), VIEW_ROWS * GROW_H)
	local vscroll = rows_h > rows_view_h + 0.01

	local total_h = table_y + rows_view_h + 1.15

	out[#out + 1] = "formspec_version[4]"
	out[#out + 1] = string.format("size[%f,%f]", W, total_h)
	out[#out + 1] = "bgcolor[#00000000;true]"
	out[#out + 1] = string.format("box[0,0;%f,%f;%s]", W, total_h, COL.bg)

	-- Title band.
	out[#out + 1] = string.format("box[0,0;%f,1.32;%s]", W, COL.panel)
	out[#out + 1] = string.format("box[0,1.32;%f,0.03;%s]", W, COL.title)
	out[#out + 1] = "style_type[label;font=bold;font_size=*1.5;textcolor=" .. COL.title .. "]"
	out[#out + 1] = string.format("label[%f,0.48;%s]", MARGIN, esc(target))
	out[#out + 1] = "style_type[label;font=normal;font_size=*0.85;textcolor=" .. COL.sub .. "]"
	out[#out + 1] = string.format("label[%f,0.95;%s]", MARGIN, esc("Combat stats"))

	-- Headline tiles (row 1 + row 2).
	local acc = pct(s.hits, s.shots)
	local hs_rate = pct(s.headshots, s.hits)
	local r2y = tiles_y + TILE_H + TILE_GAP

	tile(out, 0, tiles_y, "KILLS", tostring(s.kills), COL.kills)
	tile(out, 1, tiles_y, "DEATHS", tostring(s.deaths), COL.death)
	tile(out, 2, tiles_y, "K/D RATIO", kd(s))
	tile(out, 3, tiles_y, "BEST STREAK", tostring(s.best_streak))
	tile(out, 4, tiles_y, "TIME PLAYED", fmt_time(s.playtime))

	tile(out, 0, r2y, "SHOTS FIRED", tostring(s.shots))
	tile(out, 1, r2y, "SHOTS HIT", tostring(s.hits))
	tile(out, 2, r2y, "ACCURACY", acc, COL.accent)
	tile(out, 3, r2y, "HEADSHOTS", tostring(s.headshots))
	tile(out, 4, r2y, "HEADSHOT %", hs_rate)

	-- Favourite weapon strip.
	out[#out + 1] = "style_type[label;font=normal;font_size=*0.85;textcolor=" .. COL.key .. "]"
	out[#out + 1] = string.format("label[%f,%f;%s]", MARGIN, table_hdr_y - 0.02,
		esc("PER-WEAPON  -  favourite: " .. favourite(s)))

	-- Per-gun table header.
	out[#out + 1] = string.format("box[%f,%f;%f,0.5;%s]", MARGIN, table_hdr_y + 0.18, W - 2 * MARGIN, COL.head)
	out[#out + 1] = "style_type[label;font=mono,bold;font_size=*0.75;textcolor=" .. COL.key .. "]"
	for _, c in ipairs(GCOLS) do
		out[#out + 1] = string.format("label[%f,%f;%s]", GX[c.id], table_hdr_y + 0.43, esc(c.label))
	end

	-- Scrolling rows.
	out[#out + 1] = string.format("scroll_container[0,%f;%f,%f;stats_v;vertical;0.1]",
		table_y, W, rows_view_h)
	if #rows == 0 then
		out[#out + 1] = "style_type[label;font=normal;font_size=*0.9;textcolor=" .. COL.sub .. "]"
		out[#out + 1] = string.format("label[%f,0.3;%s]", MARGIN + 0.15,
			esc("No gun stats yet - pick up a gun and open fire."))
	end
	for i, r in ipairs(rows) do
		local rowy = (i - 1) * GROW_H
		local g = r.g
		out[#out + 1] = string.format("box[%f,%f;%f,%f;%s]", MARGIN, rowy, W - 2 * MARGIN, GROW_H - 0.04,
			(i % 2 == 1) and COL.row_a or COL.row_b)

		out[#out + 1] = "style_type[label;font=bold;font_size=*0.95;textcolor=" .. COL.name .. "]"
		out[#out + 1] = string.format("label[%f,%f;%s]", GX.name, rowy + 0.31, esc(gun_desc(r.gun)))

		out[#out + 1] = "style_type[label;font=mono;font_size=*0.92;textcolor=" .. COL.value .. "]"
		out[#out + 1] = string.format("label[%f,%f;%s]", GX.shots, rowy + 0.31, esc(tostring(g.shots)))
		out[#out + 1] = string.format("label[%f,%f;%s]", GX.hits, rowy + 0.31, esc(tostring(g.hits)))
		out[#out + 1] = "style_type[label;font=mono,bold;font_size=*0.92;textcolor=" .. COL.accent .. "]"
		out[#out + 1] = string.format("label[%f,%f;%s]", GX.acc, rowy + 0.31, esc(pct(g.hits, g.shots)))
		out[#out + 1] = "style_type[label;font=mono,bold;font_size=*0.92;textcolor=" .. COL.kills .. "]"
		out[#out + 1] = string.format("label[%f,%f;%s]", GX.kills, rowy + 0.31, esc(tostring(g.kills)))
		out[#out + 1] = "style_type[label;font=mono;font_size=*0.92;textcolor=" .. COL.value .. "]"
		out[#out + 1] = string.format("label[%f,%f;%s]", GX.hs, rowy + 0.31, esc(tostring(g.headshots or 0)))
	end
	out[#out + 1] = "scroll_container_end[]"

	if vscroll then
		out[#out + 1] = string.format("scrollbaroptions[arrows=hide;min=0;max=%d]",
			math.ceil((rows_h - rows_view_h) * 10))
		out[#out + 1] = string.format("scrollbar[%f,%f;0.3,%f;vertical;stats_v;0]",
			W - 0.35, table_y, rows_view_h)
	end

	out[#out + 1] = "style[close;bgcolor=" .. COL.accent .. ";textcolor=#FFFFFF]"
	out[#out + 1] = string.format("button_exit[%f,%f;3,0.85;close;Close]", W - 3.4, total_h - 1.0)

	return table.concat(out)
end

--------------------------------------------------------------------------------
-- Command
--------------------------------------------------------------------------------

minetest.register_chatcommand("stats", {
	params = "[player]",
	description = "Show combat stats (kills, K/D, per-gun accuracy, ...) for yourself or another player",
	func = function(name, param)
		local target = param:gsub("%s+", "")
		if target == "" then target = name end

		if not ctf_stats.has_record(target) then
			return false, ("No stats recorded for %q yet."):format(target)
		end

		minetest.show_formspec(name, "ctf_stats:stats", build_formspec(target, ctf_stats.load(target)))
		return true
	end,
})
