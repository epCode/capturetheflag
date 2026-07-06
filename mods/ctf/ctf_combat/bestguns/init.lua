bestguns = {
    registered_guns = {},
    registered_bullets = {},
    last_fire = {} -- Tracks cooldowns: [player_name] = timestamp
}

-- Overridable hook: return false to forbid a player from firing a given gun.
-- Used by game integrations (e.g. CTF class restrictions). Defaults to allow.
function bestguns.can_use_gun(player, gun_name)
    return true
end

function bestguns.scope(player, enable, itemstack, zoom_cancel)  
  local name = player:get_player_name()
  itemstack = itemstack or ItemStack("")
  local gundef = bestguns.registered_guns[itemstack:get_name()] or {zoom = 0.9, scope_size = 2, kick = 2.04}
  bestguns[name] = bestguns[name] or {}
  if bestguns[name].hud_removing or enable then
    bestguns[name].hud_removing = nil
    local oldhud = bestguns[name].hud or {}
    for i,hudid in pairs(oldhud) do
      player:hud_remove(hudid)
    end
    bestguns[name].hud = nil
  end
  local oldhud = bestguns[name].hud
  if oldhud and not enable then
    bestguns[name].hud_removing = 0.1
  end

  playerphysics.remove_physics_factor(player, "speed", "bestguns:aiming_speed")
  
  if enable == "kick" then
    player:set_fov((gundef.kick or 2.04)-1, true, 0.1)
    return
  end
  
  
  if not enable then zoom_cancel = true end
  if zoom_cancel then player:set_fov(0, false, 0.1) end
  if not enable then return end
  
  if not bestguns.can_fire(itemstack, player) then return end
  
  if not zoom_cancel then
    player:set_fov(gundef.zoom, true, 0.3)
  end
  
  playerphysics.add_physics_factor(player, "speed", "bestguns:aiming_speed", 0.8)
  
  
  if not gundef.zoomhud then return end
  bestguns[name].hud = {}
  bestguns[name].hud[1] = player:hud_add({
    type = "image",
    text = "bestguns_scope.png",
    position = {x=0.5, y=0.5},
    scale = {x = 20*gundef.scope_size, y = 20*gundef.scope_size},
    alignment = {x=0, y=0},
    offset = {x=0, y=0},
  })
  bestguns[name].hud[2] = player:hud_add({
    type = "image",
    text = "bestguns_scope_hud_cover.png",
    position = {x=0.5, y=0.5},
    scale = {x = 300*gundef.scope_size, y = 300*gundef.scope_size},
    alignment = {x=0, y=0},
    offset = {x=0, y=0},
  })
end

local noise_seed = math.random(9999999)
local noise_seeded = math.random(9999999)
local hi = 0
local lo = 0
function bestguns.r(num, num2)
  noise_seed = noise_seed + 1

  local random_noise = {
     offset = 0,
     scale = 0.25,
     spread = {x = 40, y = 40, z = 40},
     seed = noise_seeded,
     octaves = 5,
     persistence = 1,
  }
  local random_noise2 = table.copy(random_noise)
  random_noise2.seed = random_noise2.seed + 10
  
  local rv_noise = core.get_value_noise(random_noise):get_2d({x = noise_seed, y = 0})
  local rv_noise2 = core.get_value_noise(random_noise2):get_2d({x = noise_seed, y = 0})


  if rv_noise > hi then hi = rv_noise elseif rv_noise < lo then lo = rv_noise end
  if num2 then
    if math.random(2) == 1 then
      final_value = (rv_noise+1)/2*(num2-num)+num
    else
      final_value = (rv_noise2+1)/2*(num2-num)+num
    end
  else
    num2 = num
    num = -num2
    if math.random(2) == 1 then
      final_value = (rv_noise+1)/2*(num2-num)+num
    else
      final_value = (rv_noise2+1)/2*(num2-num)+num
    end
  end
  
  
  return final_value
end





local BULLETLOADSPEED = 1

-- Load components
local path = core.get_modpath("bestguns")
dofile(path .. "/entity.lua")





-- Helper: Update the Magazine item description
local function update_mag_desc(itemstack, gun_name)
    local def = bestguns.registered_guns[gun_name]
    if not def then return end
    
    local meta = itemstack:get_meta()
    local ammo = meta:get_int("ammo_count")
    local b_name = meta:get_string("bullet_name")
    local b_def = bestguns.registered_bullets[b_name]
    local mag_def = core.registered_items[itemstack:get_name()]
    local inv_image = mag_def.inventory_image
    

    local desc = def.description .. " Magazine\n"
    if ammo > 0 and b_def then
        desc = desc .. ammo .. "/" .. def.mag_capacity .. " x " .. (b_def.description or b_name)
    else
        desc = desc .. "Empty"
    end
    
    meta:set_string("description", desc)
    
    local loaded_texture = mag_def.loaded_texture or "bestguns_red.png"
    meta:set_string("wield_image", inv_image)
    inv_image = inv_image .. "^[lowpart:"..(ammo/def.mag_capacity*100)..":"..loaded_texture
    meta:set_string("inventory_image", inv_image)

end

-- Helper: Update the Gun item description and texture
local function update_gun_desc(itemstack, def)
    local meta = itemstack:get_meta()
    local has_mag = meta:get_int("has_mag") == 1
    local is_open = meta:get_int("is_open") == 1
    local ammo = meta:get_int("ammo_count")
    local inv_image = def.texture_nomag
    local wield_image
    

    local desc = def.description
    if has_mag then
      desc = desc .. "\n[" .. ammo .. "/" .. def.mag_capacity .. "]"
      inv_image = def.texture_mag
    elseif def.load_action == "direct" then
      desc = desc .. "\n[" .. ammo .. "/" .. def.mag_capacity .. "]"
      if is_open then
        wield_image = def.texture_open
        inv_image = wield_image.."^bestguns_open.png"
      end
    else
      desc = desc .. "\n[No Mag]"
    end
    meta:set_string("description", desc)
    local loaded_texture = def.loaded_texture or "bestguns_red.png"
    wield_image = wield_image or inv_image
    meta:set_string("wield_image", wield_image)
    inv_image = inv_image .. "^[lowpart:"..(ammo/def.mag_capacity*100)..":"..loaded_texture
    meta:set_string("inventory_image", inv_image)
    
    
end

-- Public helpers for external mods (loot generation, giving loaded guns, etc.)

-- Put a gun ItemStack into a loaded state. Magazine-fed guns get a magazine
-- inserted automatically. Returns the (modified) itemstack.
function bestguns.fill_gun(itemstack, ammo_count, bullet_name)
    local def = bestguns.registered_guns[itemstack:get_name()]
    if not def then return itemstack end

    local meta = itemstack:get_meta()
    meta:set_int("ammo_count", ammo_count)
    meta:set_string("bullet_name", bullet_name or def.default_bullet)
    meta:set_int("is_open", 0)
    if def.load_action == "magazine" then
        meta:set_int("has_mag", 1)
    end

    update_gun_desc(itemstack, def)
    return itemstack
end

-- Build a loaded magazine ItemStack for a magazine-fed gun.
function bestguns.make_mag(gun_name, ammo_count, bullet_name)
    local def = bestguns.registered_guns[gun_name]
    if not def or def.load_action ~= "magazine" then return ItemStack("") end

    local stack = ItemStack(gun_name .. "_mag")
    local meta = stack:get_meta()
    meta:set_int("ammo_count", ammo_count)
    meta:set_string("bullet_name", bullet_name or def.default_bullet)

    update_mag_desc(stack, gun_name)
    return stack
end

function bestguns.can_fire(itemstack, user)
  local player_name = user:get_player_name()
  local gun_name = itemstack:get_name()
  local def = bestguns.registered_guns[gun_name]
  if not def then return nil end
  
  local meta = itemstack:get_meta()
  local ammo = meta:get_int("ammo_count")
  local is_open = meta:get_int("is_open") == 1

  -- Check if empty or no magazine
  if is_open or ammo <= 0 then
      bestguns.last_fire[player_name] = now
      return false, "empty_mag_or_empty"
  elseif ammo == 1 then
    return true, "click"
  end

  local bullet_name = meta:get_string("bullet_name")
  local b_def = bestguns.registered_bullets[bullet_name]
  if not b_def then return false, "no_bullet" end
  
  
  return true
end

-- Main firing function (Supports Semi, Full, and Manual)
function bestguns.fire_gun(itemstack, user)
    local player_name = user:get_player_name()
    local gun_name = itemstack:get_name()
    local def = bestguns.registered_guns[gun_name]
  
    
    local can_fire, reason = bestguns.can_fire(itemstack, user)
    
    if reason == "click" then
      core.after(0.3, function()
        if def.sound_empty and user and user:get_pos() then
          core.sound_play(def.sound_empty, {pos = user:get_pos(), max_hear_distance = 16}, true)
        end
      end)
    elseif not can_fire then
      return
    end


    -- Handle Fire Rate Cooldown
    local now = core.get_us_time() / 1000000
    local last_fire = bestguns.last_fire[player_name] or 0
    if now - last_fire < def.fire_delay then return nil end

    -- Respect external usage restrictions (e.g. CTF class limits)
    if not bestguns.can_use_gun(user, gun_name) then
        bestguns.last_fire[player_name] = now
        if def.sound_empty then
            core.sound_play(def.sound_empty, {pos = user:get_pos(), max_hear_distance = 16}, true)
        end
        return nil
    end

    
    if def.cancel_scope_on_fire then
      bestguns.scope(user)
    else
      if user:get_player_control().RMB then
        bestguns.scope(user, true, itemstack, true)
      else
        bestguns.scope(user, "kick", itemstack)
      end
      core.after((def.kick_time or 0.02), function()
        if user and user:get_pos() then
          if user:get_player_control().RMB then
            bestguns.scope(user, true, itemstack)
          else
            bestguns.scope(user)
          end
        end
      end)
    end

    local meta = itemstack:get_meta()
    local ammo = meta:get_int("ammo_count")
    local is_open = meta:get_int("is_open") == 1
    
    local bullet_name = meta:get_string("bullet_name")
    local b_def = bestguns.registered_bullets[bullet_name]

    -- Consume ammo
    ammo = ammo - 1
    meta:set_int("ammo_count", ammo)

    update_gun_desc(itemstack, def)
    bestguns.last_fire[player_name] = now

    -- Audio
    local snd = b_def.fire_sound or def.sound_fire
    if snd then
        core.sound_play(snd, {pitch = math.random(100)/500+1, pos = user:get_pos(), gain = 19, max_hear_distance = 100}, true)
    end

    -- Recoil
    local dir = user:get_look_dir()
    local recoil = b_def.recoil or 0
    if recoil > 0 then
        user:add_velocity(vector.multiply(dir, -recoil*0.6))
    end

    -- Spawn Bullet Entity
    local eye_height = user:get_properties().eye_height or 1.625
    local pos = vector.add(user:get_pos(), {x=0, y=eye_height, z=0})
    local bullet_vel = vector.multiply(vector.offset(dir, bestguns.r(100)/5000*def.inaccuracy, bestguns.r(100)/5000*def.inaccuracy, bestguns.r(100)/5000*def.inaccuracy), b_def.speed or 100)

    if def.on_fire then
      if def.on_fire(itemstack, user, obj) then
        if ammo == 0 then
            meta:set_string("bullet_name", "")
        end
        return itemstack
      end
    end
    
    if ammo == 0 then
        meta:set_string("bullet_name", "")
    end
    
    local obj = core.add_entity(pos, "bestguns:bullet", core.serialize({
        velocity = bullet_vel,
        shooter_name = player_name,
        _item = bullet_name,
        _drops = b_def.drops,
        damage = b_def.damage or 1,
        texture = b_def.texture,
        size = b_def.size or 1
    }))

    -- Custom on_fire callback

    return itemstack
end

-- Bullet Registration
function bestguns.register_bullet(name, def)
    bestguns.registered_bullets[name] = def
    core.register_craftitem(name, {
        description = def.description,
        inventory_image = def.inventory_image,
        groups = {bullet = 1}
    })
end



local reload_timer = {}
controls.register_on_press(function(player, key)
  local ctrl = player:get_player_control()
  local wielditem = player:get_wielded_item()
  if core.get_item_group(wielditem:get_name(), "bestguns_gun") == 0 then return end
  if key == "RMB" and not ctrl.LMB and not ctrl.sneak then bestguns.scope(player, true, wielditem) end
end)
controls.register_on_release(function(player, key, length)
  if key == "RMB" then bestguns.scope(player) end
  if key ~= "RMB" then return end
  reload_timer[player:get_player_name()] = 0
  playerphysics.remove_physics_factor(player, "speed", "bestguns:loading_speed")
end)
controls.register_on_hold(function(user, key, length)
  if key ~= "RMB" then return end
  local itemstack = user:get_wielded_item()
  local stackname = itemstack:get_name() or "ignore"
  local direct = core.get_item_group(stackname, "direct_loading") ~= 0
  if core.get_item_group(stackname, "gun_magazine") == 0 and not direct then return end
    
  local name = user:get_player_name()
  reload_timer[name] = (reload_timer[name] or length)
  
  
  local gun_name = stackname:gsub("_mag", "")
  
  local def = bestguns.registered_guns[gun_name]
  
  local loadspeed = def.load_speed or BULLETLOADSPEED
  
  
  
  local meta = itemstack:get_meta()
  local inv = user:get_inventory()
  
  if direct and meta:get_int("is_open") ~= 1 then return end
  
  local ammo_count = meta:get_int("ammo_count")
  if ammo_count < def.mag_capacity then
    playerphysics.add_physics_factor(user, "speed", "bestguns:loading_speed", 0.3)
    
    if length - reload_timer[name] < loadspeed then return end
    reload_timer[name] = length -- keep loading the next bullet each loadspeed interval while RMB stays held
    
    local current_bullet = meta:get_string("bullet_name")
    local bullets_needed = 1
    local reloaded = false
    
    
    for i = 1, inv:get_size("main") do
      if bullets_needed <= 0 then break end
      local stack = inv:get_stack("main", i)
      local s_name = stack:get_name()
      local b_def = bestguns.registered_bullets[s_name]
      
      -- Must match gun caliber and not mix bullet types
      if b_def and b_def.caliber == def.caliber then
        if current_bullet == "" or current_bullet == s_name then
          current_bullet = s_name
          local to_take = math.min(stack:get_count(), bullets_needed)
          stack:take_item(to_take)
          inv:set_stack("main", i, stack)
          ammo_count = ammo_count + to_take
          bullets_needed = bullets_needed - to_take
          reloaded = true
        end
      end
    end
    
    local creative = core.is_creative_enabled(name)
    if creative then
      current_bullet = def.default_bullet
      ammo_count = def.mag_capacity
      reloaded = true
    end
    
    if reloaded then
      meta:set_int("ammo_count", ammo_count)
      meta:set_string("bullet_name", current_bullet)
      if direct then
        update_gun_desc(itemstack, def)
      else
        update_mag_desc(itemstack, gun_name)
      end
      
      if def.sound_load_mag then
        core.sound_play(def.sound_load_mag, {pos = user:get_pos(), max_hear_distance = 16}, true)
      end
      if def.load_mag then def.load_mag(itemstack, user) end
    end
  end
  user:set_wielded_item(itemstack)

end)


-- Gun Registration
function bestguns.register_gun(name, def)
  
    
    def.inaccuracy = def.inaccuracy or 0
    def.zoom = def.zoom or 0.9
    def.scope_size = def.scope_size or 1
    
    def.load_action = def.load_action or "magazine"
    local ma = def.load_action == "magazine"
    
  
    bestguns.registered_guns[name] = def
    
    local mag_name = name .. "_mag"
    -- Create specific magazine for this gun
    local rightclick_function = function(itemstack, user, pointed_thing) end
    
    if ma then
      core.register_craftitem(mag_name, {
          description = def.description .. " Magazine\nEmpty",
          inventory_image = def.texture_mag_item or def.texture_mag,
          wield_image = def.texture_mag_item or def.texture_mag,
          groups = {gun_magazine = 1},
          stack_max = 1,
          range = 0,
      })

      rightclick_function = function(itemstack, user, pointed_thing)
        local meta = itemstack:get_meta()
        local has_mag = meta:get_int("has_mag") == 1
        local inv = user:get_inventory()
        
        -- Shift + Right Click = Eject Magazine
        if user:get_player_control().sneak then
          if has_mag then
            local mag_stack = ItemStack(mag_name)
            local mag_meta = mag_stack:get_meta()
            mag_meta:set_int("ammo_count", meta:get_int("ammo_count"))
            mag_meta:set_string("bullet_name", meta:get_string("bullet_name"))
            update_mag_desc(mag_stack, name)
            
            if inv:room_for_item("main", mag_stack) then
              inv:add_item("main", mag_stack)
            else
              core.item_drop(mag_stack, user, user:get_pos())
            end
            
            meta:set_int("has_mag", 0)
            meta:set_int("ammo_count", 0)
            meta:set_string("bullet_name", "")
            update_gun_desc(itemstack, def)
            
            if def.mag_remove then
              core.sound_play(def.mag_remove, {pos = user:get_pos(), max_hear_distance = 16}, true)
            end
          end
          -- Right Click = Insert Magazine OR Top-off with loose bullets
          if not has_mag then
            local best_mag = {i=nil, stack=nil, size=-1}
            -- Insert a magazine from inventory
            for i = 1, inv:get_size("main") do
              local stack = inv:get_stack("main", i)
              if stack:get_name() == mag_name then
                local stack_meta = stack:get_meta()
                local mag_ammo_count = stack_meta:get_int("ammo_count") or 0
                if mag_ammo_count > best_mag.size then
                  best_mag = {i=i, stack=stack, size=mag_ammo_count}
                end
              end
            end
            if best_mag.size > -1 then
              local stack_meta = best_mag.stack:get_meta()
              meta:set_int("has_mag", 1)
              meta:set_int("ammo_count", stack_meta:get_int("ammo_count"))
              meta:set_string("bullet_name", stack_meta:get_string("bullet_name"))
              update_gun_desc(itemstack, def)
              
              best_mag.stack:take_item(1)
              inv:set_stack("main", best_mag.i, best_mag.stack)
              
              if def.mag_insert then
                core.sound_play(def.mag_insert, {pos = user:get_pos(), max_hear_distance = 16}, true)
              end
              if def.on_reload then def.on_reload(itemstack, user) end
            end
          end
        end
        return itemstack
      end
    elseif def.load_action == "direct" then
      rightclick_function = function(itemstack, user, pointed_thing)
        local meta = itemstack:get_meta()
        local inv = user:get_inventory()
        local is_open = meta:get_int("is_open") == 1
        
        if user:get_player_control().sneak then
          if not is_open then
            if def.sound_open then
              core.sound_play(def.sound_open, {pos = user:get_pos(), max_hear_distance = 16}, true)
            end
            meta:set_int("is_open", 1)
            reload_timer[user:get_player_name()] = 100
          else
            if def.sound_close then
              core.sound_play(def.sound_close, {pos = user:get_pos(), max_hear_distance = 16}, true)
            end
            meta:set_int("is_open", 0)
          end
        end
        update_gun_desc(itemstack, def)
        return itemstack
      end
    end
    
    local groups = {bestguns_gun = 1}
    if def.load_action == "direct" then
      groups.direct_loading = 1
    end
    
    -- Create the gun tool
    core.register_tool(name, {
        description = def.description,
        inventory_image = def.texture_nomag,
        wield_image = def.texture_nomag,
        wield_scale = def.wield_scale or vector.new(1,1,1),
        groups = groups,
        
        -- Left Click: Fire
        on_use = function(itemstack, user, pointed_thing)
            if def.action ~= "full" then
                local new_stack = bestguns.fire_gun(itemstack, user)
                return new_stack or itemstack
            end
            return itemstack
        end,
        on_place = rightclick_function,
        on_secondary_use = rightclick_function,
        range = 0,
        
    })
end

core.register_globalstep(function(dtime)
  noise_seeded = noise_seeded + dtime*1000
  for _, player in ipairs(core.get_connected_players()) do

    local name = player:get_player_name()

    if bestguns[name] and bestguns[name].hud_removing then
      local oldopacity = math.floor(bestguns[name].hud_removing * 1000)
      bestguns[name].hud_removing = bestguns[name].hud_removing - dtime
      local oldhud = bestguns[name].hud
      for i,hudid in pairs(oldhud) do
        local newopacity = math.floor(bestguns[name].hud_removing * 1000)
        local basetext = player:hud_get(hudid).text
        if not string.find(basetext, "opacity") then
          basetext = basetext .. "^[opacity:"..newopacity
        end
        basetext = basetext:gsub("acity:"..oldopacity, "acity:"..newopacity)
        player:hud_change(hudid, "text", basetext)
        if newopacity <= 0 then
          for i,hudid2 in pairs(oldhud) do
            player:hud_remove(hudid2)
          end
          bestguns[name].hud = nil
          bestguns[name].hud_removing = nil
          break
        end
      end
    end


    local control = player:get_player_control()
    -- Left mouse button down
    if control.LMB or control.dig then
      local wielded = player:get_wielded_item()
      local gun_name = wielded:get_name()
      local def = bestguns.registered_guns[gun_name]
      
      if def and def.action == "full" then
        local new_stack = bestguns.fire_gun(wielded, player)
        if new_stack then
            player:set_wielded_item(new_stack)
        end
      end
    end
  end
end)


dofile(path .. "/register.lua")
