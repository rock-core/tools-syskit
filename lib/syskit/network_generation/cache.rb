module Syskit
    module NetworkGeneration
        class Cache
            attr_reader :known_networks

            def initialize
                @known_networks = Hash.new
            end

            def add_followup_plan(plan)
#                binding.pry
               known_networks[plan.missions] = plan
            end

            def get_plan_for_missions(missions)
                res = known_networks[missions]
#                binding.pry
                res
            end
        end

        NetworkCache = NetworkGeneration::Cache.new
    end
end
