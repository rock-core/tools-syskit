module Syskit
    module NetworkGeneration
        class Cache
            attr_reader :known_networks

            def initialize
                @known_networks = Hash.new
            end

            def add_followup_plan(plan)
               known_networks[plan.missions] = plan
            end

            def get_plan_for_missions(missions)
                known_networks[missions]
            end
        end

        NetworkCache = NetworkGeneration::Cache.new
    end
end
