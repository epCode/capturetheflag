local TREASURE_VERSION = 1

ctf_map.treasure = {}

-- Extension points so other mods can shape chest loot without monkeypatching:
--   * blockers: fns(item_name) -> true to keep a base treasure item from spawning
--   * fillers:  fns(inv) that add their own items to a chest after base loot
ctf_map.treasure.registered_blockers = {}
ctf_map.treasure.registered_fillers = {}

-- Register a predicate that excludes matching items from base map treasures.
function ctf_map.treasure.register_blocked_item(func)
	table.insert(ctf_map.treasure.registered_blockers, func)
end

-- Register a function that adds extra items to each treasure chest inventory.
function ctf_map.treasure.register_filler(func)
	table.insert(ctf_map.treasure.registered_fillers, func)
end

local function is_blocked(item)
	for _, blocker in ipairs(ctf_map.treasure.registered_blockers) do
		if blocker(item) then return true end
	end
	return false
end

function ctf_map.treasure.treasurefy_node(inv, map_treasures)
	for item, def in pairs(map_treasures) do
		if not is_blocked(item) then
			local treasure = ItemStack(item)

			for c = 1, def.max_stacks or 1, 1 do
				if math.random() < (def.rarity or 0.5) then
					treasure:set_count(math.random(def.min_count or 1, def.max_count or 1))
					inv:add_item("main", treasure)
				end
			end
		end
	end

	for _, filler in ipairs(ctf_map.treasure.registered_fillers) do
		filler(inv)
	end
end

-- name ; min_count ; max_count ; max_stacks ; rarity ;;
function ctf_map.treasure.treasure_from_string(str)
	if not str then return {} end

	local out = {}

	for name, min_count, max_count, max_stacks, rarity in str:gmatch("([^%;]+);(%d*);(%d*);(%d*);([%d.]*);%d;") do
		out[name] = {
			min_count  = tonumber(min_count)  or 1,
			max_count  = tonumber(max_count)  or 1,
			max_stacks = tonumber(max_stacks) or 1,
			rarity     = tonumber(rarity)     or 0.5,
			TREASURE_VERSION,
		}
	end

	return out
end

function ctf_map.treasure.treasure_to_string(treasures)
	if not treasures then return "" end

	local out = ""

	for name, t in pairs(treasures) do
		out = string.format("%s%s;%s;%s;%s;%s;%d;",
			out, name,
			t.min_count or 1,
			t.max_count or 1,
			t.max_stacks or 1,
			t.rarity or 0.5,
			TREASURE_VERSION
		)
	end

	return out
end
