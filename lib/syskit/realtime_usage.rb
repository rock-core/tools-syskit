module Syskit

    class RealtimeHandler
        #This is a counter for the plan-iteration
        #maping is idx -> Time
        attr_reader :plan_iteration

        #This Map holds all started tasks
        #mapping is model -> [[iteration,task]]
        attr_reader :start_points
        
        #This Map holds all stopped tasks
        #mapping is model -> [[iteration,task]]
        attr_reader :stop_points
        
        #This Map holds all reconfigurd tasks
        #mapping is model -> [[iteration,old-task,new-task]]
        attr_reader :reconfigure_points


        def initialize
            @plan_iteration = Array.new
            @start_points = Hash.new
            @stop_points = Hash.new
            @reconfigure_points = Hash.new
        end

        def create_plan_iteration(time = Time.new)
            plan_iteration << time
            current_iteration
        end

        def current_iteration
            plan_iteration.size
        end

        def add_task_start_point(task, iteration)
            add_task_to_runtime_change(@start_points,task,iteration)
        end
        
        def add_task_stop_point(task, iteration)
            add_task_to_runtime_change(@stop_points,task,iteration)
        end

        def add_task_to_runtime_change(array,task,iteration)
            if(array[task.model].nil?)
                array[task.model] = Array.new
            end
            array[task.model] <<  [iteration,task]
        end

        def known_task_models
            a = (@start_points.keys | @stop_points.keys).uniq
            #a.each do |t|
            #    STDOUT.puts "Class: #{t.class.name} #{t.name}"
            #end
            a
        end

        #return the start indicies for a given task
        def start_indexes(task)
            model = task
            if task.respond_to?("model") #Assume we got a task and not a model
                model = task.model
            end
            runtime_change_indexes(@start_points,model)         
        end
        
        #return the start indicies for a given task
        def stop_indexes(task)
            model = task
            if task.respond_to?("model") #Assume we got a task and not a model
                model = task.model
            end
            runtime_change_indexes(@stop_points,model)         
        end
        
        def reconfigure_indexes(task)
            #TODO
            nil
        end

        def runtime_change_indexes(list,model)
            a = Array.new
            list[model].to_a.each do |iteration,task|
                a << iteration
            end
            a
        end
    end
    
    
    Realtime = RealtimeHandler.new
end
