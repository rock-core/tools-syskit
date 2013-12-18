module Syskit
    module NetworkGeneration
        class CacheEntry
            attr_accessor :real_plan
            attr_accessor :target_missions
            attr_accessor :engine
            def initialize(real_plan,missions,engine)
                self.real_plan = real_plan 
                self.target_missions = missions 
                self.engine = engine
            end
        end
        class Cache
            attr_reader :known_transitions

            def initialize
                @known_transitions = Array.new              
            end

            def add_followup_plan(engine,reqs)
                @known_transitions << CacheEntry.new(engine.real_plan.dup,reqs,engine)
#                STDOUT.puts "!!!!!!!!!!!!!!!!!!! Caching plan with missions !!!!!!!!!!!!!!!!!!!!!!"    
#                engine.real_plan.missions.each {|m| STDOUT.puts m}
#                STDOUT.puts "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"    
            end

            def get_engine_for_missions(current_plan,missions)
                erg = @known_transitions.find_all do |cached|
                    a = true
                    if current_plan.missions.size == cached.real_plan.missions.size
                        a = current_plan.missions.all? do |new|
                            cached.real_plan.missions.find do |orig|
                                #binding.pry
                                new.fullfills?(orig)
                                #j.requirements == o.requirements
                            end
                        end
                    else
                        a = false
                    end
                    
                    b = true
                    if missions.size == cached.target_missions.size
                        b = missions.all? do |o|
                            cached.target_missions.find do |j|
                                j.fullfills?(o)
                                #o.requirements == j.requirements
                            end
                        end
                    else
                        b = false
                    end
                    STDOUT.puts "Test: #{a} -- #{b}"
                    ###Debug
#                    STDOUT.puts "############## CURRENT MISSIONS DEBUG #######################"
#                    current_plan.missions.each {|m| STDOUT.puts m}
#                    STDOUT.puts "----------------------    VS --------------------------------"
#                    cached.real_plan.missions.each {|m| STDOUT.puts m}
#                    STDOUT.puts "##############################################################"
                    ##end debug

#                    ###Debug
#                    STDOUT.puts "############## MISSIONS DEBUG #######################"
#                    missions.each {|m| STDOUT.puts m.requirements}
#                    STDOUT.puts "----------------    VS ------------------------------"
#                    cached.target_missions.each {|m| STDOUT.puts m.requirements binding.pry}
#                    STDOUT.puts "#####################################################"
#                    ##end debug
                    
#                    binding.pry if missions.to_a.size == 2 and cached.target_missions.to_a.size == 2
                    a and b 
                end

                if erg.size > 1
                    raise "Realtime Match is valid for more than one plan"
                elsif erg.size == 0
                    #No match at all
                    return nil
                end
                STDOUT.puts "We got a match"
                erg[0].engine
            end
        end

        NetworkCache = NetworkGeneration::Cache.new
    end
end
