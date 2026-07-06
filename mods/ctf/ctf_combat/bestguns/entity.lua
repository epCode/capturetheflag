core.register_entity("bestguns:bullet", {
    initial_properties = {
        physical = false,
        collide_with_objects = false,
        pointable = false,
        visual = "sprite",
        textures = {"blank.png"}, -- Overwritten on_activate
    },
    
    on_activate = function(self, staticdata)
      
      -- Keep bullet from dying to random entity damage
      self.object:set_armor_groups({immortal = 1})
      
      -- Load bullet properties
      local data = core.deserialize(staticdata) or {}
      self.velocity = data.velocity or {x=0, y=0, z=0}
      self.shooter_name = data.shooter_name
      self.damage = data.damage or 0
      self._item = data._item
      self._drops = data._drops or data._item

      if data.texture then
          local s = data.size or 1
          self.object:set_properties({
              textures = {data.texture},
              visual_size = {x = s, y = s}
          })
      end

      self.timer = 0
      
      
      if self._item and bestguns.registered_bullets[self._item].on_activate then
        return bestguns.registered_bullets[self._item].on_activate(self, dtime, moveresult)
      end
    end,
    
    on_step = function(self, dtime, moveresult)
        self.timer = self.timer + dtime
        if self.timer > 5.0 then -- Timeout safety fallback
            self.object:remove()
            return
        end
        
        if self._item and bestguns.registered_bullets[self._item].on_step then
          if bestguns.registered_bullets[self._item].on_step(self, dtime, moveresult) then return end
        end

        local pos = self.object:get_pos()
        
        local drag = 0.001
        
        local in_node = core.get_node(pos)
        local in_def = core.registered_nodes[in_node.name] or {}
        if in_def.liquidtype ~= "none" then
          drag = 0.4
        end
        
        self.velocity = vector.multiply(self.velocity, 1-drag)
        if vector.length(self.velocity) < 1 and self._item then
          core.add_item(pos, ItemStack(self._drops))
          self.object:remove()
          return
        end
        
        --self.object:set_velocity(self.velocity)

        local next_pos = vector.add(pos, vector.multiply(self.velocity, dtime))
        if not self.shooter_name then return end
        local shooter = core.get_player_by_name(self.shooter_name)

        -- Execute Raycast for precise high-speed hit detection
        local ray = core.raycast(pos, next_pos, true, false)
        for pointed_thing in ray do
            if pointed_thing.type == "object" then
                local obj = pointed_thing.ref
                -- Prevent the shooter from hitting themselves
                if obj and obj:is_valid() and obj ~= shooter then
                    -- Credit the shooting player so games (e.g. CTF) can attribute
                    -- kills/assists, and tag the hit as ranged damage.
                    local puncher = (shooter and shooter:is_valid()) and shooter or self.object
                    obj:punch(puncher, 1.0, {
                        full_punch_interval = 1.0,
                        damage_groups = {fleshy = self.damage, ranged = 1}
                    }, self.velocity)
                    self.object:remove()
                    return
                end
            elseif pointed_thing.type == "node" then
                local node = core.get_node(pointed_thing.under)
                local def = core.registered_nodes[node.name]
                if def and def.walkable then
                  

                  local lp = vector.add(pointed_thing.intersection_point, vector.multiply(self.velocity, -0.0001))
                  for i=1, math.random(1,self.damage*7) do
                    core.add_particle({ -- node_particles
                      pos = lp,
                      velocity = vector.offset(vector.multiply(self.velocity,0.02), bestguns.r(4), bestguns.r(4), bestguns.r(4)),
                      acceleration = {x=0, y=-8.91, z=0},
                      expirationtime = 1,
                      collisiondetection = true,
                      size = math.random(10)/10,
                      node = node
                    })
                  end
                  for i=1, math.random(3,6) do
                    core.add_particle({ -- smoke fast
                      pos = lp,
                      velocity = vector.zero,
                      acceleration = {x=bestguns.r(3), y=bestguns.r(3), z=bestguns.r(3)},
                      expirationtime = math.random(20)/10,
                      size = math.random(10),
                      texture = "bestguns_smoke_"..math.random(3)..".png^[opacity:20",
                      glow = math.random(5)
                    })
                    core.add_particle({ -- smoke stays around
                      pos = vector.offset(lp, bestguns.r(10)/10, bestguns.r(10)/10, bestguns.r(10)/10),
                      velocity = vector.zero,
                      acceleration = {x=0, y=math.random(20)/30, z=0},
                      expirationtime = math.random(10),
                      size = math.random(20),
                      texture = "bestguns_smoke_"..math.random(3)..".png^[opacity:10",
                      glow = math.random(5)
                    })
                    
                    
                  end
                  
                  function get_face_vector(pos, intersection_point)
                    local diff = vector.subtract(intersection_point, pos)
                    local abs_x, abs_y, abs_z = math.abs(diff.x), math.abs(diff.y), math.abs(diff.z)
                    
                    if abs_x > abs_y and abs_x > abs_z then
                        return {x = diff.x > 0 and 1 or -1, y = 0, z = 0}
                    elseif abs_y > abs_z then
                        return {x = 0, y = diff.y > 0 and 1 or -1, z = 0}
                    else
                        return {x = 0, y = 0, z = diff.z > 0 and 1 or -1}
                    end
                  end
                  
                  local facedir = get_face_vector(pointed_thing.under, pointed_thing.intersection_point)
                  local finaldir = vector.zero()
                  
                  for v,val in pairs(facedir) do
                    if val > 0 or val < 0 then
                      finaldir[v] = 0
                    elseif val == 0 then
                      finaldir[v] = 1
                    end
                  end
                  
                  for i=1, math.random(30) do
                    local acc, vel
                    if math.random(6) == 1 then
                      vel = vector.new(bestguns.r(0.6),bestguns.r(0.2),bestguns.r(0.6))
                      acc = vector.new(0,-9,0)
                    end
                    
                    core.add_particle({ -- node_particles
                      pos = vector.add(
                        lp,
                        vector.multiply(
                          vector.new(bestguns.r(0.3), bestguns.r(0.3), bestguns.r(0.3)),
                          finaldir
                        )
                      ),
                      collisiondetection = true,
                      velocity = vel,
                      acceleration = acc,
                      drag = vector.new(2,0,2),
                      expirationtime = math.random(8),
                      size = 3/4.5,
                      node = node,
                    })
                  end
                    
                    self.object:remove()
                    return
                end
            end
        end

        self.object:set_pos(next_pos)
    end
})