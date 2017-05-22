return {
    -- init parameters:
    -- ai: a reference to the ai engine so recruit has access to ai functions
    --   It is also possible to pass an ai table directly to the execution function, which will then override the value passed here
    --
    -- Next steps: during the daytime move to high defence terrain instead of towards the enemy
    init = function(ai)
        local ai_cas = {} -- this is returned to Wesnoth and is used later to call CA functions from
        local H = wesnoth.require "lua/helper.lua"
        local LS = wesnoth.require "lua/location_set.lua"
        local AH = wesnoth.require "~/add-ons/AI-demos/lua/ai_helper.lua"
        local BC = wesnoth.require "~/add-ons/AI-demos/lua/battle_calcs.lua"
        local is_me = function(unit, other) return unit and other and other.x == unit.x and other.y == unit.y end
        local fighter_type = "Skeleton Archer" -- FIXME: Replace with optimal recruitment algo from python AI
        local scout_type = "Ghost"             -- FIXME: Replace with optimal recruitment algo from python AI
        local enemy_attack_map = nil
        local bounty_enemies = nil

        function is_blocked(unit, loc)
            local blocking = wesnoth.get_unit(loc[1], loc[2])
            return (blocking and not is_me(unit, blocking))
        end 

        function close_to_enemy(loc)
            local distance, enemy_loc = AH.get_closest_enemy(loc)
            local enemy = wesnoth.get_unit(enemy_loc.x, enemy_loc.y)
            local hitpoint_bonus = 0.0
            if distance < 2 then hitpoint_bonus = 1.0 - (enemy.hitpoints / enemy.max_hitpoints) end
            return 0.5 * (1.0 / distance)
                 + 0.5 * hitpoint_bonus
        end

        function attack_bounty_enemies(unit, loc)
            for xa,ya in H.adjacent_tiles(loc[1], loc[2]) do 
                local bounty = bounty_enemies:get(xa, ya)
                if bounty then
                    return 1.0 + bounty -- highest bounties first
                end
            end
            return 0.0
        end

        function update_enemy_attack_map()
            local enemies = AH.get_live_units {{ "filter_side", {{"enemy_of", {side = wesnoth.current.side}}}}}
            enemy_attack_map = BC.get_attack_map(enemies)
        end

        function update_bounty_enemies()
            local leaders = wesnoth.get_units { side = wesnoth.current.side, canrecruit = 'yes' }
            local enemies = AH.get_live_units {{ "filter_side", {{"enemy_of", {side = wesnoth.current.side}}}}}
            bounty_enemies = LS.create()
            for _, leader in ipairs(leaders) do
                for _, enemy in ipairs(enemies) do
                    local enemy_attacks = BC.get_attack_map_unit(enemy)
                    if enemy_attacks.units:get(leader.x, leader.y) then
                         bounty_enemies:insert(enemy.x, enemy.y, 1.0 / H.distance_between(leader.x, leader.y, enemy.x, enemy.y)) -- bounty is highest for closest enemies
                    end
                end
            end
        end

        function attackable_by_enemy_count(loc)
            local enemy_count = enemy_attack_map.units:get(loc[1], loc[2]) or 0
            return enemy_count
        end

        function distance_from_scouts(scouts, loc)
            distance = 0.0
            for _, scout in ipairs(scouts) do
                distance = distance + math.min(20, H.distance_between(loc[1], loc[2], scout.x, scout.y)) / 20.0
            end
            return distance / #scouts
        end

        function close_to_untaken_village(unit, loc)
            local villages = wesnoth.get_villages()
            local closest_untaken = function(pos, village)
                if is_blocked(unit, village) then return 0.0 end
                local owner = wesnoth.get_village_owner(village[1], village[2])
                local baseline = 0.01
                if not owner then baseline = 0.5 end
                if owner and wesnoth.is_enemy(owner, wesnoth.current.side) then baseline = 1.0 end
                return baseline/(1.0 + H.distance_between(pos[1], pos[2], village[1], village[2]))
            end
            closest, score = choose_best(closest_untaken, loc, villages)
            return score
        end

        function used_movement(_, loc)
            return 1.0 / (1.0 + loc[3])
        end

        function choose_best(eval, data, list)
            local best_index = nil
            local best_value = nil
            for i, item in ipairs(list) do
                local value = eval(data, item)
                if (best_value == nil or value > best_value) then
                    best_index = i
                    best_value = value
                end
            end
            return list[best_index], best_value
        end

        function move_units(eval, units)
            for _, unit in ipairs(units) do
                update_enemy_attack_map()
                update_bounty_enemies()
                local reach = wesnoth.find_reach(unit)
                local loc, score = choose_best(eval, unit, reach)
                print(unit.type .. " (" .. unit.x .."," .. unit.y .. ") to (" .. loc[1] .. "," .. loc[2] .. "): " .. score);
                if loc[1] ~= unit.x or loc[2] ~= unit.y then
                    ai.move_full(unit, loc[1], loc[2])
                end
                if (unit.type ~= scout_type) then -- scouts shouldn't waste HP attacking - should leaders?
                    attack_with_unit(unit) -- always check to see if you can attack after finishing a move
                end
            end
        end

        function attacks(unit)
            -- returns a set enemies that can be attacked from unit's position
            local tiles = H.adjacent_tiles(unit.x, unit.y)
            local result = {}
            for xa,ya in tiles do
                local enemy = wesnoth.get_unit(xa, ya)
                if (enemy and enemy.side ~= wesnoth.current.side) then
                    result[enemy] = true
                end
            end
            return result
        end

        function attack_with_unit(fighter)
            local enemies = attacks(fighter)

            for enemy, _ in pairs(enemies) do
                print(fighter.type .. " attack from " .. fighter.x .. "," .. fighter.y);
                ai.attack(fighter, enemy)
                break
            end
        end

        function is_keep(loc)
            local terrain = wesnoth.get_terrain(loc[1], loc[2])
            local info = wesnoth.get_terrain_info(terrain)
            return info.keep
        end

        function is_village(loc)
            local terrain = wesnoth.get_terrain(loc[1], loc[2])
            local info = wesnoth.get_terrain_info(terrain)
            return info.village
        end

        function safety(unit, loc)
            local terrain = wesnoth.get_terrain(loc[1], loc[2])
            local info = wesnoth.get_terrain_info(terrain)
            if info.village then
                return 1.0
            else
                return (100.0 - wesnoth.unit_defense(unit, terrain))/100.0
            end
        end

        function good_leader_village(unit, loc)
            local terrain = wesnoth.get_terrain(loc[1], loc[2])
            local info = wesnoth.get_terrain_info(terrain)
            if info.village and not is_blocked(unit, loc) and (wesnoth.current.turn < 2 or unit.hitpoints < unit.max_hitpoints) then
                return (100.0 - wesnoth.unit_defense(unit, terrain))/100.0
            else
                return 0.0
            end
        end

        function safe_empty_keep(unit, loc)
            local terrain = wesnoth.get_terrain(loc[1], loc[2])
            local info = wesnoth.get_terrain_info(terrain)
            if info.keep and not is_blocked(unit, loc) then
                return (100.0 - wesnoth.unit_defense(unit, terrain))/100.0
            else
                return 0.0
            end
        end

        function hop_between_village_and_keep(unit, loc)
            local unit_loc = {unit.x, unit.y}
            if (unit_loc[1] == loc[1]) and (unit_loc[2] == loc[2]) then
                return 0.1 -- if we can't find a good village or keep then better to stay put than wander randomly
            end
            if is_keep(unit_loc) then
                return good_leader_village(unit, loc)
            else
                return safe_empty_keep(unit, loc)
            end
        end

        function ai_cas:scouts_eval()
            return 3
        end

        function ai_cas:scouts_exec()
            local scouts = wesnoth.get_units { side = wesnoth.current.side, type = scout_type }

            local scout_score = function(unit, loc)
                if is_blocked(unit, loc) then return 0.0 end
                
                local safe_factor = 1.0
                if attackable_by_enemy_count(loc) > 2 then safe_factor = safety(unit, loc) end

                local spread_factor = 0.1
                if wesnoth.current.turn < 3 then spread_factor = 1.0 end

                return   1.00 * close_to_untaken_village(unit, loc)
                       + spread_factor * distance_from_scouts(scouts, loc)
                       + 0.50 * safe_factor
                       - 0.01 * used_movement(unit, loc) -- prefer nearby untaken villages
            end

            move_units(scout_score, scouts)
        end

        function ai_cas:fighters_eval()
            return 4
        end

        function ai_cas:fighters_exec()
            local fighters = wesnoth.get_units { side = wesnoth.current.side, { "not", { type = scout_type}}, canrecruit = 'no' }
            local fighter_score = function(unit, loc)
                if is_blocked(unit, loc) then return 0.0 end
                local safe_factor = 1.0
                if attackable_by_enemy_count(loc) > 0 then safe_factor = safety(unit, loc) end
                return math.max(10.0 * attack_bounty_enemies(unit, loc),
                                 0.5 * close_to_untaken_village(unit, loc), -- TESTME: is this the right balance?
                                 2.0 * close_to_enemy(loc))
                       + 0.10 * used_movement(unit, loc)
                       + 0.5 * safe_factor
            end

            move_units(fighter_score, fighters)
        end

        function ai_cas:leader_recruit_eval()
            local leaders = wesnoth.get_units { side = wesnoth.current.side, canrecruit = 'yes' }
            if is_village({leaders[1].x, leaders[1].y}) then
                return 0 -- if our primary leader is on a village and not a keep, don't try to recruit yet
            else
                return 2
            end
        end

        function ai_cas:leader_recruit_exec()
            local scouts = wesnoth.get_units { side = wesnoth.current.side, type = scout_type }
            if #scouts < 2 then
                ai.recruit(scout_type)
            else
                ai.recruit(fighter_type)
            end
        end

        function ai_cas:leader_village_eval()
            return 1
        end

        function ai_cas:leader_village_exec()
            local leaders = wesnoth.get_units { side = wesnoth.current.side, canrecruit = 'yes' }
            move_units(hop_between_village_and_keep, leaders)
        end

        return ai_cas
    end -- init()
}

