-- Infection: a free-for-all Death Match where every player starts on their own
-- team. A killed player is converted onto their killer's team (with a little
-- particle burst) instead of being knocked out, so teams keep merging as people
-- die until only one team is left standing - that team wins. Shared logic lives
-- in the ctf_mode_deathmatch mod; the separate mod gives it its own rankings
-- namespace.

-- Pool of solo teams handed out one-per-player at round start (max 10 teams,
-- one per colour).
ctf_mode_deathmatch.register_infection_teams(10)

-- is_teams = false (everyone starts solo), is_infection = true.
ctf_mode_deathmatch.register("infection", false, true)
