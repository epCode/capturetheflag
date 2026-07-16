--[[
	bestguns_ctf
	------------
	Glues the `bestguns` mod into Capture the Flag.

	What this file does:
	  * Defines the gun roster + a simple, editable rarity table.
	  * Generates guns/mags/ammo in loot chests (loaded 60%-100%, with spare
	    mags and loose bullets scaled to each gun's rarity).
	  * Makes sure the old built-in guns never spawn.
	  * Provides loaded-gun helpers used by the class loadouts.
	  * Registers ammo crafting and enforces class usage restrictions.

	To add another gun, register it in `bestguns` as usual, then add one line
	to `bestguns_ctf.gun_rarity` below. Everything else is derived from the
	gun's own definition (mag capacity, bullet, load type).
]]

-- bestguns is an optional (globally-enabled) mod. If it isn't loaded, CTF simply
-- runs without guns; do nothing here rather than erroring.
if not minetest.get_modpath("bestguns") then
	return
end

bestguns_ctf = {}

--------------------------------------------------------------------------------
-- ROSTER / RARITY TABLE  (edit me!)
--------------------------------------------------------------------------------
-- Per-chest spawn chance for each gun. Higher = more common.
-- Grouped by family; sidearms are common, rifles/snipers rare.
-- (bestguns:pistol is intentionally omitted -- disabled for now, replaced by the glock.)
bestguns_ctf.gun_rarity = {
	-- Sidearms
	["bestguns:glock"]           = 0.20,  -- by far the most common (replaced the pistol, disabled for now)
	["bestguns:snub_revolver"]   = 0.15,  -- cheap, compact .38
	["bestguns:revolver"]        = 0.12,  -- .44 Magnum
	["bestguns:deagle"]          = 0.03,  -- .44 hand cannon, uncommon

	-- Shotguns
	["bestguns:shotgun"]         = 0.06,
	["bestguns:sawed_shotgun"]   = 0.05,

	-- SMGs
	["bestguns:tommy"]           = 0.015,
	["bestguns:uzi"]             = 0.01,  -- ~20x rarer than the glock

	-- Rifles
	["bestguns:carbine"]         = 0.04,
	["bestguns:assault_rifle"]   = 0.035,
	["bestguns:ak47"]            = 0.03,
	["bestguns:semi_auto_rifle"] = 0.025,

	-- Sniper
	["bestguns:bolt_sniper"]     = 0.015,
}

-- Loot tuning (all editable). Chances below are multiplied by a gun's rarity
-- weight above, so ammo/mags for rarer guns naturally show up less often.
bestguns_ctf.loose_ammo_chance_mult = 2.0  -- chance of a loose bullet stack appearing on its own
bestguns_ctf.spare_mag_chance_mult  = 1.0  -- chance of a spare loaded magazine appearing on its own
bestguns_ctf.bundled_mag_chance     = 0.5  -- chance a spawned (mag-fed) gun also brings a spare mag

-- Loaded amount as a fraction of magazine capacity (guns & mags spawn within this range).
bestguns_ctf.min_load = 0.60
bestguns_ctf.max_load = 1.00

-- Loose bullet stacks are this fraction of magazine capacity.
bestguns_ctf.min_bullet_stack = 0.60
bestguns_ctf.max_bullet_stack = 2.00

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------
local function clampi(n)
	return math.max(1, math.floor(n + 0.5))
end

-- Random "loaded" ammo count for a gun (60%-100% of its mag capacity).
local function random_load(cap)
	return math.random(clampi(cap * bestguns_ctf.min_load), clampi(cap * bestguns_ctf.max_load))
end

-- Random loose-bullet stack size (60%-200% of the mag capacity).
local function random_bullet_count(cap)
	return math.random(clampi(cap * bestguns_ctf.min_bullet_stack), clampi(cap * bestguns_ctf.max_bullet_stack))
end

-- Build a loaded gun ItemStack (mag inserted for magazine-fed guns).
-- `ammo_count` is optional; omit for a random 60%-100% load.
function bestguns_ctf.loaded_gun(gun_name, ammo_count)
	local def = bestguns.registered_guns[gun_name]
	if not def then return ItemStack(gun_name) end

	local stack = ItemStack(gun_name)
	bestguns.fill_gun(stack, ammo_count or random_load(def.mag_capacity), def.default_bullet)
	return stack
end

-- Build a loose bullet stack (60%-200% of mag capacity) for a gun's caliber.
function bestguns_ctf.bullet_stack(gun_name)
	local def = bestguns.registered_guns[gun_name]
	if not def then return ItemStack("") end

	local stack = ItemStack(def.default_bullet)
	stack:set_count(random_bullet_count(def.mag_capacity))
	return stack
end

-- Build a spare loaded magazine (only for magazine-fed guns).
function bestguns_ctf.spare_mag(gun_name)
	local def = bestguns.registered_guns[gun_name]
	if not def then return ItemStack("") end
	return bestguns.make_mag(gun_name, random_load(def.mag_capacity), def.default_bullet)
end

-- A class starter kit for a gun: a fully-loaded gun, a spare magazine (if the
-- gun is magazine-fed) and a couple of magazines' worth of loose bullets.
-- Returns a list of ItemStacks suitable for a mode's stuff_provider.
function bestguns_ctf.class_loadout(gun_name)
	local def = bestguns.registered_guns[gun_name]
	if not def then return {gun_name} end

	local out = { bestguns_ctf.loaded_gun(gun_name, def.mag_capacity) }

	if def.load_action == "magazine" then
		table.insert(out, bestguns.make_mag(gun_name, def.mag_capacity, def.default_bullet))
	end

	local bullets = ItemStack(def.default_bullet)
	bullets:set_count(def.mag_capacity * 2)
	table.insert(out, bullets)

	return out
end

--------------------------------------------------------------------------------
-- Loot generation
--------------------------------------------------------------------------------
-- Roll bestguns loot into a single chest inventory.
function bestguns_ctf.fill_chest(inv)
	for gun_name, weight in pairs(bestguns_ctf.gun_rarity) do
		local def = bestguns.registered_guns[gun_name]
		if def then
			local uses_mag = def.load_action == "magazine"

			-- 1) The gun itself, spawned loaded. Mag-fed guns come WITH a mag
			--    (it's inserted), and may bring a spare. A few loose rounds too.
			if math.random() < weight then
				inv:add_item("main", bestguns_ctf.loaded_gun(gun_name))

				if uses_mag and math.random() < bestguns_ctf.bundled_mag_chance then
					inv:add_item("main", bestguns_ctf.spare_mag(gun_name))
				end

				inv:add_item("main", bestguns_ctf.bullet_stack(gun_name))
			end

			-- 2) Independent spare ammo / mags, scaled to the gun's rarity.
			if math.random() < weight * bestguns_ctf.loose_ammo_chance_mult then
				inv:add_item("main", bestguns_ctf.bullet_stack(gun_name))
			end

			if uses_mag and math.random() < weight * bestguns_ctf.spare_mag_chance_mult then
				inv:add_item("main", bestguns_ctf.spare_mag(gun_name))
			end
		end
	end
end

-- Items from the (now removed) built-in gun system that must never spawn.
local function is_blocked_loot(item)
	return item:find("^ctf_mode_classes:ranged_rifle")
end

-- Use CTF's treasure API instead of monkeypatching: block the old guns and add
-- our loot to every chest.
ctf_map.treasure.register_blocked_item(is_blocked_loot)
ctf_map.treasure.register_filler(bestguns_ctf.fill_chest)

--------------------------------------------------------------------------------
-- Class loadouts
--------------------------------------------------------------------------------
-- Expand a bestguns gun name given out by a mode's stuff_provider into a full
-- kit (loaded gun + spare mag + ammo). Lets modes list plain gun names.
ctf_modebase.register_stuff_expander(function(item)
	if bestguns.registered_guns[item] then
		return bestguns_ctf.class_loadout(item)
	end
end)

--------------------------------------------------------------------------------
-- Class usage restrictions
--------------------------------------------------------------------------------
-- Mirror the behaviour the old gun system had: let the current mode forbid guns
-- (used by the classes mode's disallowed_items list).
function bestguns.can_use_gun(player, gun_name)
	local mode = ctf_modebase:get_current_mode()
	if mode and mode.is_restricted_item then
		return not mode.is_restricted_item(player, gun_name)
	end
	return true
end

--------------------------------------------------------------------------------
-- Ammo crafting (replaces the old craftable ammo)
--------------------------------------------------------------------------------
-- output ; recipe items
local ammo_crafts = {
	{"bestguns:bullet_9mm 12",  {"default:steel_ingot", "default:coal_lump"}},
	{"bestguns:bullet_44 6",    {"default:steel_ingot", "default:coal_lump"}},
	{"bestguns:bullet_39mm 12", {"default:steel_ingot 2", "default:coal_lump"}},
	{"bestguns:bullet_45acp 10", {"default:steel_ingot 2", "default:coal_lump"}},
	{"bestguns:12_gauge 4",     {"default:steel_ingot", "default:coal_lump"}},
	{"bestguns:308 4",          {"default:steel_ingot 2", "default:coal_lump 2"}},
}

for _, c in ipairs(ammo_crafts) do
	crafting.register_recipe({
		output = c[1],
		items  = c[2],
		always_known = false,
	})
end

-- Convenience: the list of craftable ammo outputs, so modes can expose them in
-- their crafting guide (`crafts` field).
bestguns_ctf.ammo_craft_outputs = {}
for _, c in ipairs(ammo_crafts) do
	table.insert(bestguns_ctf.ammo_craft_outputs, c[1])
end
