ctf_core.include_files("deathmatch.lua")

-- Free-for-all variant. The shared library is defined above; the teams variant
-- lives in its own mod (ctf_mode_deathmatch_teams) so it gets a separate
-- rankings namespace.
ctf_mode_deathmatch.register("death_match", false)
