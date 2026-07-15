--------------------------------------------------------------------------------
-- Programmatic head / body / arm animation for the CTF player model.
--
-- The CTF character.b3d rig is the Mineclonia mesh, which exposes four "control"
-- bones layered on top of the baked stand/walk/mine animations:
--     Head_Control            - swivels the head (look pitch + head/body yaw split)
--     Body_Control            - steers the torso toward the movement direction
--     Arm_Right_Pitch_Control - raises/lowers the right arm (holds the gun; the
--                               wield3d item is attached to its child Arm_Right)
--     Arm_Left_Pitch_Control  - raises/lowers the left (support / flag) arm
--
-- The head/body steering is ported straight from Mineclonia's mcl_player
-- (which is not loaded in CTF). On top of that, when a player is holding a
-- bestguns gun we pose the arms differently for standing / walking / aiming /
-- reloading so guns are actually carried, aimed and reloaded on the body model.
--------------------------------------------------------------------------------

local deg = math.deg

--------------------------------------------------------------------------------
-- Bone override helper (ported from mcl_util.set_bone_position).
--
-- The character.b3d rig has "perfect 180 degree" rest rotations on several
-- control bones which the engine renders wrong unless a mirrored scale is
-- applied alongside the rotation (Luanti issue #15692). Mineclonia carries the
-- exact same workaround table for the exact same mesh, so we replicate it.
--------------------------------------------------------------------------------

local bone_workaround_scales = {
	Body_Control            = vector.new(-1, 1, -1),
	Arm_Right_Pitch_Control = vector.new(1, -1, -1),
	Arm_Left_Pitch_Control  = vector.new(1, -1, -1),
	-- Head_Control needs no scale workaround (identity rest rotation).
}

-- Set a bone's rotation (degrees) as an absolute override, only when it has
-- actually moved, so we don't spam set_bone_override every server step.
local function set_bone_rot(player, bone, rot)
	local scale = bone_workaround_scales[bone]
	local ov = player:get_bone_override(bone)
	local current_rot = vector.apply(ov.rotation.vec, deg)
	if vector.equals(vector.round(current_rot), vector.round(rot)) then
		return
	end
	player:set_bone_override(bone, {
		rotation = {vec = vector.apply(rot, math.rad), absolute = true, interpolation = 0.1},
		scale = scale and {vec = scale, absolute = true, interpolation = 0.1} or nil,
	})
end

-- Remove any override on a bone so the baked animation drives it again.
local function clear_bone(player, bone)
	player:set_bone_override(bone, {})
end

--------------------------------------------------------------------------------
-- Head/body yaw split (ported from mcl_player.animations limit_vel_yaw).
--
-- Keeps the torso pointed no more than ~40 degrees away from the look
-- direction, so strafing turns the body toward the movement direction while the
-- head keeps looking where the camera looks.
--------------------------------------------------------------------------------

local function limit_vel_yaw(player_vel_yaw, yaw)
	if player_vel_yaw < 0 then player_vel_yaw = player_vel_yaw + 360 end
	if yaw < 0 then yaw = yaw + 360 end

	if math.abs(player_vel_yaw - yaw) > 40 then
		local player_vel_yaw_nm, yaw_nm = player_vel_yaw, yaw
		if player_vel_yaw > yaw then
			player_vel_yaw_nm = player_vel_yaw - 360
		else
			yaw_nm = yaw - 360
		end
		if math.abs(player_vel_yaw_nm - yaw_nm) > 40 then
			local diff = math.abs(player_vel_yaw - yaw)
			if diff > 180 and diff < 185 or diff < 180 and diff > 175 then
				player_vel_yaw = yaw
			elseif diff < 180 then
				if player_vel_yaw < yaw then
					player_vel_yaw = yaw - 40
				else
					player_vel_yaw = yaw + 40
				end
			else
				if player_vel_yaw < yaw then
					player_vel_yaw = yaw + 40
				else
					player_vel_yaw = yaw - 40
				end
			end
		end
	end

	if player_vel_yaw < 0 then
		player_vel_yaw = player_vel_yaw + 360
	elseif player_vel_yaw > 360 then
		player_vel_yaw = player_vel_yaw - 360
	end

	return player_vel_yaw
end

--------------------------------------------------------------------------------
-- Gun arm poses.
--
-- Rotations are (pitch, yaw, roll) in degrees on the *_Pitch_Control bones.
-- `pitch` here is -look_vertical in degrees (positive = looking up), so a term
-- of `pitch + k` makes the arm track vertical aim while `pitch * f + k` tracks
-- it partially (a relaxed low/hip carry). The gun rides the right arm, so the
-- right pose does the aiming; the left is the support hand.
--------------------------------------------------------------------------------

-- Returns right-arm rot, left-arm rot for a given state and vertical aim.
local function gun_arm_poses(state, pitch, walking)
	if state == "aim" then
		-- Both arms up and forward, tracking vertical aim, gun aligned with the
		-- crosshair (mirrors Mineclonia's bow/crossbow ADS pose).
		return vector.new(pitch + 90, -0, 0), vector.new(pitch + 90, -45, 0)
	elseif state == "reload" then
		-- Gun canted down in the right hand, support hand brought up to the
		-- breech/magazine well.
		return vector.new(30, 22, 0), vector.new(88, -52, 0)
	elseif walking then
		-- Low-ready while moving: gun carried a touch lower, light aim tracking.
		return vector.new(pitch * 0.15 + 48, 30, 0), vector.new(58, -24, 0)
	else
		-- Standing at the ready: gun up a bit higher, more aim tracking.
		return vector.new(pitch * 0.15 + 48, 30, 0), vector.new(58, -24, 0)
	end
end

--------------------------------------------------------------------------------
-- Per-player state + main step
--------------------------------------------------------------------------------

local last_vel_yaw = {}
local gun_hold = {}   -- [name] = true while the arm bones are posed for a gun

-- Drop the arm-bone overrides so the baked animation drives (swings) the arms
-- again once the player stops holding a gun.
local function release_gun_hold(player, name)
	if not gun_hold[name] then return end
	clear_bone(player, "Arm_Right")
	clear_bone(player, "Arm_Left")
	gun_hold[name] = nil
end

minetest.register_on_leaveplayer(function(player)
	local name = player:get_player_name()
	last_vel_yaw[name] = nil
	gun_hold[name] = nil
end)

local function animate_player(player, name)
	local control = player:get_player_control()
	local vel = player:get_velocity()

	local pitch = -deg(player:get_look_vertical())
	local yaw = deg(player:get_look_horizontal())

	-- Movement direction, clamped to within 40 degrees of the look yaw.
	local vel_yaw = deg(core.dir_to_yaw(vel))
	if vel_yaw == 0 then
		vel_yaw = last_vel_yaw[name] or yaw
	end
	vel_yaw = limit_vel_yaw(vel_yaw, yaw)
	last_vel_yaw[name] = vel_yaw

	local state, one_handed
	if bestguns then
		state, one_handed = bestguns.player_gun_state(player)
	end

	-- Head + body steering (Mineclonia): the torso leans toward the movement
	-- direction while the head keeps facing the camera. But when aiming or firing
	-- a gun, square the whole upper body up to the look direction (zero yaw
	-- offset) so the weapon points where the player is aiming instead of leaning
	-- off toward a strafe.
	if state and (state == "aim" or control.LMB) then
		set_bone_rot(player, "Head_Control", vector.new(pitch, 0, 0))
		set_bone_rot(player, "Body_Control", vector.zero())
	else
		set_bone_rot(player, "Head_Control", vector.new(pitch, vel_yaw - yaw, 0))
		set_bone_rot(player, "Body_Control", vector.new(0, -vel_yaw + yaw, 0))
	end

	-- Arm posing. Only touch the arms when holding a bestguns gun; otherwise
	-- release them so a leftover gun pose doesn't stick and the baked
	-- stand/walk/mine animation keeps swinging the arms normally.
	if not state then
		release_gun_hold(player, name)
		return
	end

	-- Pose the ARM bones directly (Arm_Right / Arm_Left), not the Pitch_Control
	-- parents. An absolute override on the animated arm bone *replaces* its baked
	-- walk/mine motion, so the gun pose sits still; layering on the parent while
	-- the clip kept swinging the child looked jumpy. Overriding the arms also
	-- cancels the mine/walk_mine arm swing. The plain walk/stand leg clip for gun
	-- holders is chosen by the player_api.globalstep override above (control-based,
	-- so no velocity-threshold jitter) -- we must NOT set it again here, or the two
	-- calls would restart the clip every step and freeze the legs on frame 0.
	local walking = control.up or control.down or control.left or control.right

	-- Firing (LMB) points the gun forward with the same aim pose as ADS, so the
	-- weapon lines up on the target while shooting. RMB aiming already reads as
	-- "aim" via the gun state; this adds the firing case. Reload takes precedence.
	local pose_state = state
	if control.LMB and state ~= "reload" then
		pose_state = "aim"
	end

	local rpose, lpose = gun_arm_poses(pose_state, pitch, walking)
	set_bone_rot(player, "Arm_Right", rpose)
	-- The left arm is the support/loading hand. Bring it to the gun unless:
	--  * the gun is one-handed (pistols, SMGs) - held in the right hand only,
	--    EXCEPT while reloading, when the off hand loads the mag/rounds, or
	--  * the player is carrying a flag on the left arm - don't swing it around.
	local use_support_arm = not ctf_player.is_flag_carrier(name)
		and (not one_handed or pose_state == "reload")
	if use_support_arm then
		set_bone_rot(player, "Arm_Left", lpose)
	else
		clear_bone(player, "Arm_Left")
	end
	gun_hold[name] = true
end

-- Take over the base leg-animation driver (player_api.globalstep). The stock
-- version plays the "mine"/"walk_mine" clip whenever LMB or RMB is held; for a
-- player holding a bestguns gun that fights animate_player() below, which forces
-- the plain walk/stand clip and poses the arms itself. The two overwrite each
-- other every server step, restarting the clip so the legs freeze on frame 0 --
-- the jumpy walk you see while aiming (RMB) and moving. Here gun holders choose
-- the leg clip from movement alone (no LMB/RMB pickaxe swing); every other
-- player keeps the stock behaviour byte-for-byte.
local models = player_api.registered_models
local players = player_api.players
local player_attached = player_api.player_attached
function player_api.globalstep()
	for _, player in ipairs(minetest.get_connected_players()) do
		local name = player:get_player_name()
		local player_data = players[name]
		local model = player_data and models[player_data.model]
		if model and not player_attached[name] then
			local controls = player:get_player_control()
			local speed = model.animation_speed or 30
			if controls.sneak then
				speed = speed / 2
			end

			local moving = controls.up or controls.down or controls.left or controls.right
			local holding_gun = bestguns and bestguns.player_gun_state(player)

			if player:get_hp() == 0 then
				player_api.set_animation(player, "lay")
			elseif holding_gun then
				-- Gun holders: pick the leg clip from movement only so LMB/RMB
				-- never swaps in the mining clip and restarts the walk cycle.
				-- animate_player() poses the arms for the gun.
				player_api.set_animation(player, moving and "walk" or "stand", speed)
			elseif moving then
				if controls.LMB or controls.RMB then
					player_api.set_animation(player, "walk_mine", speed)
				else
					player_api.set_animation(player, "walk", speed)
				end
			elseif controls.LMB or controls.RMB then
				player_api.set_animation(player, "mine", speed)
			else
				player_api.set_animation(player, "stand", speed)
			end
		end
	end
end

minetest.register_globalstep(function()
	for _, player in ipairs(minetest.get_connected_players()) do
		local name = player:get_player_name()
		-- Skip corpses (player_api plays the flat "lay" pose) and players riding
		-- an attachment, where hand-authored bone control would fight the parent.
		if player:get_hp() > 0 and not player_api.player_attached[name] then
			animate_player(player, name)
		else
			set_bone_rot(player, "Head_Control", vector.zero())
			set_bone_rot(player, "Body_Control", vector.zero())
			release_gun_hold(player, name)
		end
	end
end)
