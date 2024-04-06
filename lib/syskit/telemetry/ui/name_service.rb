# frozen_string_literal: true

module Syskit
    module Telemetry
        module UI
            # Copy of Runkit's local name service to use with orocos.rb
            class NameService < Orocos::NameServiceBase
                # A new NameService instance
                #
                # @param [Hash<String,Orocos::TaskContext>] tasks The tasks which are
                #        known by the name service.
                # @note The namespace is always "Local"
                def initialize(tasks = [])
                    @registered_tasks = Concurrent::Hash.new
                    @task_added_callbacks = Concurrent::Array.new
                    @task_removed_callbacks = Concurrent::Array.new
                    tasks.each { |task| register(task) }
                end

                def names
                    @registered_tasks.keys
                end

                def include?(name)
                    @registered_tasks.key?(name)
                end

                # (see NameServiceBase#get)
                def ior(name)
                    task = @registered_tasks[name]
                    return task.ior if task.respond_to?(:ior)

                    raise Orocos::NotFound, "task context #{name} cannot be found."
                end

                # (see NameServiceBase#get)
                def get(name, **)
                    task = @registered_tasks[name]
                    return task if task

                    raise Orocos::NotFound, "task context #{name} cannot be found."
                end

                # Registers the given {Orocos::TaskContext} on the name service.
                # If a name is provided, it will be used as an alias. If no name is
                # provided, the name of the task is used. This is true even if the
                # task name is renamed later.
                #
                # @param [Orocos::TaskContext] task The task.
                # @param [String] name Optional name which is used to register the task.
                def register(task, name: task.name)
                    @registered_tasks[name] = task
                    trigger_task_added(name)
                end

                # Deregisters the given name or task from the name service.
                #
                # @param [String,TaskContext] name The name or task
                def deregister(name)
                    @registered_tasks.delete(name)
                    trigger_task_removed(name)
                end

                # (see Base#cleanup)
                def cleanup
                    names = @registered_tasks.keys
                    @registered_tasks.clear
                    names.each { trigger_task_removed(name) }
                end

                def to_async
                    self
                end

                def on_task_added(&block)
                    @task_added_callbacks << block
                    Roby.disposable { @task_added_callbacks.delete(block) }
                end

                def trigger_task_added(name)
                    error = nil
                    @task_added_callbacks.each do |block|
                        block.call(name)
                    rescue RuntimeError => e
                        error = e
                    end

                    raise error if error
                end

                def on_task_removed(&block)
                    @task_removed_callbacks << block
                    Roby.disposable { @task_removed_callbacks.delete(block) }
                end

                def trigger_task_removed(name)
                    error = nil
                    @task_removed_callbacks.each do |block|
                        block.call(name)
                    rescue RuntimeError => e
                        error = e
                    end

                    raise error if error
                end
            end
        end
    end
end
