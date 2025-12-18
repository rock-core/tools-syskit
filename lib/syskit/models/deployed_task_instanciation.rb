# frozen_string_literal: true

module Syskit
    module Models
        # Features that implement the instanciation of deployed tasks, compatible with
        # both {ConfiguredDeployment} and {Syskit::Deployment}
        module DeployedTaskInstanciation
            # Create a task from this deployment's
            #
            # @param [String] orocos_name the mapped name of the deployed task
            # @param [OroGen::Spec::DeployedTask,nil] orogen_model the orogen model of the
            #   deployed task, if known. Pass nil if it has to be resolved.
            # @param [TaskContext,nil] syskit_model the syskit model that should be used
            #   to create the task instance. It may be a submodel of the deployment's task
            #   model. Pass nil to resolve from the deployment model
            # @param [Roby::Plan,nil] plan the plan in which the task should be created
            # @return [(OroGen::Spec::DeployedTask,TaskContext)] the resolved orogen
            #   models and
            def instanciate_deployed_task(
                orocos_name, orogen_model: nil, syskit_model: nil, plan: nil
            )
                orogen_model, syskit_model =
                    instanciate_deployed_task_resolve_task_model(
                        orocos_name, orogen_model, syskit_model
                    )

                args = {
                    orogen_model: orogen_model,
                    orocos_name: orocos_name,
                    read_only: read_only?(orocos_name)
                }
                args[:plan] = plan if plan
                syskit_model.new(**args)
            end

            # Create the 'scheduler' task of a task (if needed)
            #
            # OroGen components can be explicitly triggered by another component. This
            # shows up as having a 'master' in the deployed task model. This method makes
            # sure that the scheduler component is instanciated, and sets up proper
            # relationship between the scheduled task and the scheduler task
            def task_setup_scheduler(task, existing_tasks: {})
                return unless (orogen_master_m = task.orogen_model.master)

                mapped_master_name = orogen_master_m.name
                unless (scheduler_task = existing_tasks[mapped_master_name])
                    scheduler_task =
                        instanciate_deployed_task(mapped_master_name, plan: task.plan)
                    scheduler_task.select_conf_from_name

                    existing_tasks =
                        existing_tasks.merge({ mapped_master_name => scheduler_task })
                end

                task_setup_scheduler(scheduler_task, existing_tasks: existing_tasks)

                task.depends_on scheduler_task, role: "scheduler"
                task.should_configure_after scheduler_task.start_event
                scheduler_task
            end

            # Helper for {#instanciate_deployed_task} to resolve the syskit task model
            # that should be used to represent the deployed task
            #
            # @param [String] orocos_name the mapped name of the deployed task
            # @param [OroGen::Spec::DeployedTask,nil] orogen_model the orogen model of the
            #   deployed task, if known. Pass nil if it has to be resolved.
            # @param [TaskContext,nil] syskit_model the syskit model that should be used
            #   to create the task instance. It may be a submodel of the deployment's task
            #   model. Pass nil to resolve from the deployment model
            # @return [(OroGen::Spec::DeployedTask,TaskContext)] the resolved orogen
            #   models and
            def instanciate_deployed_task_resolve_task_model(
                orocos_name, orogen_model = nil, syskit_model = nil
            )
                orogen_model ||=
                    each_orogen_deployed_task_context_model
                    .find { |m| m.name == orocos_name }

                unless orogen_model
                    raise ArgumentError, "no deployed task found for #{orocos_name}"
                end

                base_syskit_model = resolve_syskit_model_for_deployed_task(orogen_model)
                if syskit_model && !(syskit_model <= base_syskit_model) # rubocop:disable Style/InverseMethods
                    raise ArgumentError,
                          "incompatible explicit selection of task model " \
                          "#{syskit_model} for the model of #{orogen_model} in " \
                          "#{self}, expected #{base_syskit_model} " \
                          "or one of its subclasses"
                end

                [orogen_model, syskit_model || base_syskit_model]
            end

            # Resolve the syskit task context model that should be used to represent a
            # deployed task
            #
            # @param [OroGen::Spec::DeployedTask] orogen_deployed_task the model, which
            #   name has been mapped
            def resolve_syskit_model_for_deployed_task(orogen_deployed_task)
                unmapped_name = name_mappings.rassoc(orogen_deployed_task.name)&.first
                unless unmapped_name
                    raise ArgumentError,
                          "no mapping points to name #{orogen_deployed_task.name}, " \
                          "known names: #{name_mappings}. This method expects the " \
                          "mapped name as argument"
                end

                model.resolve_syskit_model_for_deployed_task(
                    orogen_deployed_task, name: unmapped_name
                )
            end
        end
    end
end
