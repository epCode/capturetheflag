

function bestguns.a_smoke(user, def)
  local look_dir = user:get_look_dir()
  local pos = user:get_pos()
  pos.y = pos.y + 1.5
  def.minsmokes = def.minsmokes or 10
  def.max_smokes = def.max_smokes or 25
  
  if not def.acceleration then def.acceleration = {x=8, y=8, z=8} end
  for i=1, math.random(def.minsmokes,def.max_smokes) do
    core.add_particle({
      pos = vector.add(pos, vector.multiply(look_dir, 0.5)),
      velocity = user:get_velocity(),
      acceleration = {x=bestguns.r(def.acceleration.x), y=bestguns.r(def.acceleration.y), z=bestguns.r(def.acceleration.z)},
      expirationtime = math.random((def.expirationtime or 0.6)*10)/10,
      size = math.random(def.size or 8),
      texture = def.texture or "bestguns_smoke_"..math.random(3)..".png^[opacity:"..(def.base_opacity or 20).."^[contrast:0:"..math.random((def.smoke_min_brightness or -20), 0),
      glow = math.random(def.glow or 3)
    })
  end
end



-- Register a bullet
bestguns.register_bullet("bestguns:bullet_9mm", {
    description = "9mm Bullet",
    caliber = "9mm",
    speed = 600,
    size = 0.2,
    texture = "bestguns_bullet.png",
    inventory_image = "bestguns_9mm.png",
    damage = 51,
    recoil = 1,
    fire_sound = "bestguns_fire_9mm"
})


bestguns.register_bullet("bestguns:bullet_39mm", {
    description = "39mm Bullet",
    caliber = "39mm",
    speed = 400,
    size = 0.5,
    texturesize = 20,
    texture = "bestguns_bullet_light.png",
    inventory_image = "bestguns_39mm.png",
    damage = 39,
    recoil = 1.4,
    fire_sound = "bestguns_magnum_fire"
})


bestguns.register_bullet("bestguns:308", {
    description = ".308 Winchester",
    caliber = ".308",
    speed = 900,
    size = 2,
    texturesize = 20,
    texture = "bestguns_bullet_light.png",
    inventory_image = "bestguns_308.png",
    damage = 306,
    recoil = 15,
    fire_sound = "bestguns_sniper"
})
--[[
bestguns.register_bullet("bestguns:338", {
    description = ".338 Lapua Magnum",
    caliber = ".308",
    speed = 900,
    size = 2,
    texturesize = 20,
    texture = "bestguns_bullet_light.png",
    inventory_image = "bestguns_308.png",
    damage = 290,
    recoil = 22,
    fire_sound = "bestguns_magnum_fire"
})]]


core.register_craftitem("bestguns:12_gauge_ball", {
  description = "12 Gauge Ball",
  inventory_image = "bestguns_12_gauge_ball.png"
})


bestguns.register_bullet("bestguns:12_gauge", {
    description = "12 Gauge Shell",
    caliber = "12gauge",
    speed = 400,
    size = 0.2,
    texturesize = 20,
    shots = 9,
    drops = "bestguns:12_gauge_ball",
    texture = "bestguns_12gauge_ball.png",
    inventory_image = "bestguns_12gauge.png",
    damage = 59,
    recoil = 17,
    fire_sound = "bestguns_shotgun_fire"
})



bestguns.register_gun("bestguns:pistol", {
    description = "9mm Pistol",
    default_bullet = "bestguns:bullet_9mm",
    texture_mag = "bestguns_pistol.png^bestguns_pistol_mag.png",
    texture_nomag = "bestguns_pistol.png",
    texture_mag_item = "bestguns_pistol_mag_empty.png",
    sound_fire = "bestguns_empty_click",
    sound_empty = "bestguns_empty_click",
    sound_reload = "bestguns_reload",
    sound_load_mag = "bestguns_load_bullet",
    mag_insert = "bestguns_mag_insert",
    mag_remove = "bestguns_mag_remove",
    inaccuracy = 1,
    fire_delay = 0.25,
    action = "semi",
    mag_capacity = 12,
    caliber = "9mm",
    
    -- Custom particle effect
    on_fire = function(itemstack, user, bullet_entity)
      
      
        local pos = user:get_pos()
        pos.y = pos.y + 1.5
        local look_dir = user:get_look_dir()
        
        for i=1, math.random(4,5) do
          core.add_particle({
            pos = vector.offset(vector.add(pos, vector.multiply(look_dir, 0.3)), bestguns.r(10)/100, bestguns.r(10)/100, bestguns.r(10)/100),
            expirationtime = 0.0001,
            size = math.random(9,12),
            playername = user:get_player_name(),
            texture = {name = "bestguns_muzzle_flash.png^[opacity:"..math.random(10)},
            glow = 14,
          })
        end
        
        bestguns.a_smoke(user, {
          minsmokes = 20,
          maxsmokes = 30,
          size = 10,
          base_opacity = 20,
        })
    end,
    
    -- Optional custom reload logic
    on_reload = function(itemstack, user)
      return
    end
})



-- A full-auto replica of the pistol that shares the pistol's 9mm ammo. Fires
-- 1.4x faster than its original 0.04s delay (0.04 / 1.4 ~= 0.0286).
bestguns.register_gun("bestguns:uzi", {
    description = "Uzi",
    default_bullet = "bestguns:bullet_9mm",
    texture_mag = "bestguns_uzi.png^bestguns_uzi_mag.png",
    texture_nomag = "bestguns_uzi.png",
    texture_mag_item = "bestguns_uzi_mag_empty.png",
    loaded_texture = "bestguns_red_20.png",
    sound_fire = "bestguns_empty_click",
    sound_empty = "bestguns_empty_click",
    sound_reload = "bestguns_reload",
    sound_load_mag = "bestguns_load_bullet",
    mag_insert = "bestguns_mag_insert",
    mag_remove = "bestguns_mag_remove",
    inaccuracy = 3,
    fire_delay = 0.0286,
    action = "full",
    mag_capacity = 90,
    caliber = "9mm",

    -- Custom particle effect (same muzzle flash + smoke as the pistol)
    on_fire = function(itemstack, user, bullet_entity)
        local pos = user:get_pos()
        pos.y = pos.y + 1.5
        local look_dir = user:get_look_dir()

        for i=1, math.random(4,5) do
          core.add_particle({
            pos = vector.offset(vector.add(pos, vector.multiply(look_dir, 0.3)), bestguns.r(10)/100, bestguns.r(10)/100, bestguns.r(10)/100),
            expirationtime = 0.0001,
            size = math.random(9,12),
            playername = user:get_player_name(),
            texture = {name = "bestguns_muzzle_flash.png^[opacity:"..math.random(10)},
            glow = 14,
          })
        end

        bestguns.a_smoke(user, {
          minsmokes = 20,
          maxsmokes = 30,
          size = 10,
          base_opacity = 20,
        })
    end,

    on_reload = function(itemstack, user)
      return
    end
})



bestguns.register_gun("bestguns:assault_rifle", {
    description = "Assault Rifle",
    texture_mag = "bestguns_assault_rifle.png^bestguns_assault_rifle_mag.png",
    texture_nomag = "bestguns_assault_rifle.png",
    texture_mag_item = "bestguns_assault_rifle_mag_empty.png",
    sound_fire = "bestguns_empty_click",
    sound_empty = "bestguns_empty_click",
    sound_reload = "bestguns_reload",
    sound_load_mag = "bestguns_load_bullet",
    mag_insert = "bestguns_mag_insert",
    mag_remove = "bestguns_mag_remove",
    default_bullet = "bestguns:bullet_39mm",
    inaccuracy = 1.2,
    kick = 2.1,
    
    fire_delay = 0.08,
    zoom = 0.7,
    scope_size = 2,
    zoomhud = true,
    wield_scale = vector.new(2.6,2.6,1.6),
    action = "full",
    loaded_texture = "bestguns_red_24.png",
    mag_capacity = 30,
    caliber = "39mm",

    -- Custom particle effect
    on_fire = function(itemstack, user, bullet_entity)
        local pos = user:get_pos()
        pos.y = pos.y + 1.5
        local look_dir = user:get_look_dir()
        
        for i=1, math.random(4,5) do
          core.add_particle({
            pos = vector.offset(vector.add(pos, vector.multiply(look_dir, 0.3)), bestguns.r(10)/100, bestguns.r(10)/100, bestguns.r(10)/100),
            expirationtime = 0.0001,
            size = math.random(9,12),
            playername = user:get_player_name(),
            texture = {name = "bestguns_muzzle_flash.png^[opacity:"..math.random(20)},
            glow = 14,
          })
        end
        
        bestguns.a_smoke(user, {
          minsmokes = 5,
          maxsmokes = 10,
          size = 10,
          base_opacity = 10,
        })
        bestguns.a_smoke(user, {
          minsmokes = 5,
          maxsmokes = 10,
          size = 20,
          acceleration = {x=0, y=8, z=0},
          smoke_min_brightness = -50,
          expirationtime = 10,
          base_opacity = 10,
        })

    end,
    
    -- Optional custom reload logic
    on_reload = function(itemstack, user)
      return
    end
})


bestguns.register_gun("bestguns:shotgun", {
    description = "Shotgun",
    texture_nomag = "bestguns_shotgun.png",
    texture_open = "bestguns_shotgun_open.png",
    sound_fire = "bestguns_shotgun_trigger",
    sound_empty = "bestguns_shotgun_trigger",
    sound_reload = "bestguns_reload",
    sound_load_mag = "bestguns_shotgun_load",
    sound_open = "bestguns_shotgun_open",
    sound_close = "bestguns_shotgun_close",
    default_bullet = "bestguns:12_gauge",
    loaded_texture = "bestguns_red_20.png",
    load_speed = 0.7,
    fire_delay = 0.6,
    kick = 2.1,
    kick_time = 0.1,
    wield_scale = vector.new(2,2,2.8),
    action = "semi",
    load_action = "direct",
    mag_capacity = 2,
    caliber = "12gauge",

    -- Custom particle effect
    on_fire = function(itemstack, user, bullet_entity)
      
      local meta = itemstack:get_meta()
      local bullet_name = meta:get_string("bullet_name")
      local b_def = bestguns.registered_bullets[bullet_name]
      if not b_def then return nil end
      local eye_height = user:get_properties().eye_height or 1.625
      local pos = vector.add(user:get_pos(), {x=0, y=eye_height, z=0})
      local bullet_vel = vector.multiply(user:get_look_dir(), b_def.speed or 100)
      
      for i=1, b_def.shots do
        local obj = core.add_entity(pos, "bestguns:bullet", core.serialize({
            velocity = vector.offset(bullet_vel, bestguns.r(90), bestguns.r(90), bestguns.r(90)),
            shooter_name = user:get_player_name(),
            _item = bullet_name,
            _drops = b_def.drops,
            damage = b_def.damage or 1,
            texture = b_def.texture,
            size = b_def.size or 1
        }))
      end
      
      
      
      
      local pos = user:get_pos()
      pos.y = pos.y + 1.5
      local look_dir = user:get_look_dir()
      for i=1, math.random(4,10) do
        core.add_particle({
          pos = vector.offset(vector.add(pos, vector.multiply(look_dir, 0.3)), bestguns.r(10)/100, bestguns.r(10)/100, bestguns.r(10)/100),
          expirationtime = 0.01,
          size = math.random(9,22),
          playername = user:get_player_name(),
          texture = {name = "bestguns_muzzle_flash.png^[opacity:"..math.random(20)},
          glow = 14,
        })
      end
      
      bestguns.a_smoke(user, {
        minsmokes = 20,
        maxsmokes = 40,
        size = 10,
        base_opacity = 40,
      })
      bestguns.a_smoke(user, {
        minsmokes = 20,
        maxsmokes = 100,
        size = 40,
        smoke_min_brightness = -100,
        acceleration = {x=3, y=8, z=3},
        expirationtime = 10.,
        base_opacity = 30,
      })
      
      return true
    end,
    
    -- Optional custom reload logic
    on_reload = function(itemstack, user)
      return
    end
})



bestguns.register_gun("bestguns:bolt_sniper", {
    description = "Bolt Action Rifle",
    texture_nomag = "bestguns_assault_bold_sniper.png",
    texture_open = "bestguns_assault_bold_sniper_open.png",
    sound_fire = "bestguns_shotgun_trigger",
    sound_empty = "bestguns_shotgun_trigger",
    sound_reload = "bestguns_reload",
    sound_load_mag = "bestguns_bolt_load",
    sound_open = "bestguns_bolt_open",
    sound_close = "bestguns_bolt_close",
    default_bullet = "bestguns:308",
    loaded_texture = "bestguns_red_20.png",
    load_speed = 1.2,
    zoom = 0.3,
    cancel_scope_on_fire = true,
    zoomhud = true,
    fire_delay = 0,
    wield_scale = vector.new(1.8,1.8,1.8),
    action = "semi",
    load_action = "direct",
    mag_capacity = 1,
    caliber = ".308",

    -- Custom particle effect
    on_fire = function(itemstack, user, bullet_entity)
            
      local pos = user:get_pos()
      pos.y = pos.y + 1.5
      local look_dir = user:get_look_dir()
      
      for i=1, math.random(4,12) do
        core.add_particle({
          pos = vector.offset(vector.add(pos, vector.multiply(look_dir, 0.3)), bestguns.r(10)/100, bestguns.r(10)/100, bestguns.r(10)/100),
          expirationtime = 0.0001,
          size = math.random(9,12),
          playername = user:get_player_name(),
          texture = {name = "bestguns_muzzle_flash.png^[opacity:"..math.random(20)},
          glow = 14,
        })
      end
      
      bestguns.a_smoke(user, {
        minsmokes = 20,
        maxsmokes = 40,
        size = 10,
        base_opacity = 40,
      })
      bestguns.a_smoke(user, {
        minsmokes = 20,
        maxsmokes = 100,
        size = 40,
        smoke_min_brightness = -100,
        acceleration = {x=1, y=8, z=1},
        expirationtime = 10.,
        base_opacity = 15,
      })
    end,
    
    -- Optional custom reload logic
    on_reload = function(itemstack, user)
      return
    end
})



















bestguns.register_bullet("bestguns:bullet_44", {
    description = ".44 Magnum Bullet",
    caliber = ".44",
    speed = 450,
    size = 0.35,
    texture = "bestguns_bullet_light.png",
    inventory_image = "bestguns_44.png",
    damage = 93,
    recoil = 3,
    fire_sound = "bestguns_44"
})
bestguns.register_gun("bestguns:revolver", {
    description = ".44 Magnum Revolver",
    texture_nomag = "bestguns_revolver.png",
    texture_open = "bestguns_revolver_open.png",
    sound_fire = "bestguns_empty_click",
    sound_empty = "bestguns_empty_click",
    sound_reload = "bestguns_reload",
    sound_load_mag = "bestguns_load_revolver",
    sound_open = "bestguns_revolver_open", -- Reusing open/close sounds
    sound_close = "bestguns_revolver_close",
    default_bullet = "bestguns:bullet_44",
    loaded_texture = "bestguns_red_20.png",
    inaccuracy = 0.7,
    fire_delay = 0.0,
    wield_scale = vector.new(1.1, 1.1, 1.1),
    action = "semi",
    load_action = "direct",
    mag_capacity = 6,
    caliber = ".44",

    on_fire = function(itemstack, user, bullet_entity)
        local pos = user:get_pos()
        pos.y = pos.y + 1.5
        local look_dir = user:get_look_dir()
        
        for i=1, math.random(4,5) do
          core.add_particle({
            pos = vector.offset(vector.add(pos, vector.multiply(look_dir, 0.3)), bestguns.r(10)/100, bestguns.r(10)/100, bestguns.r(10)/100),
            expirationtime = 0.0001,
            size = math.random(9,12),
            playername = user:get_player_name(),
            texture = {name = "bestguns_muzzle_flash.png^[opacity:"..math.random(20)},
            glow = 14,
          })
        end
        bestguns.a_smoke(user, {
          minsmokes = 20,
          maxsmokes = 40,
          size = 10,
          base_opacity = 40,
        })
    end
})

-- CTF integration (loot, class loadouts, combat) lives in the separate
-- bestguns_ctf mod (mods/ctf/ctf_combat/bestguns_ctf).