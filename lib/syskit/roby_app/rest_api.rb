require 'grape'
require 'syskit/roby_app/rest_deployment_manager'

module Syskit
    module RobyApp
        class REST_API < Grape::API
            format :json
            
            rescue_from RESTDeploymentManager::NotFound do |e|
                error! e.message, 404
            end

            rescue_from RESTDeploymentManager::Forbidden do |e|
                error! e.message, 403
            end

            helpers Roby::Interface::REST::Helpers
            helpers do
                def syskit_conf
                    Syskit.conf
                end

                # The {DeploymentManager} object that manages the deployments on behalf of the API
                def deployment_manager
                    @contexts ||=
                        (roby_storage['syskit.deployment_manager'] ||= RESTDeploymentManager.new(syskit_conf))
                end

                # @api private
                #
                # Transforms orogen's deployed task information object into the
                # hash that is to be returned by the API
                def make_basic_deployed_task_info_hash(info)
                    info_hash = info.to_h
                    if /^orogen_default_/.match?(info.task_name)
                        info_hash[:default_deployment] = true
                    end
                    if info.task_model_name == 'logger::Logger' && (info.task_name == info.deployment_name + "_Logger")
                        info_hash[:default_logger] = true
                    end
                    info_hash
                end

                def make_configured_deployment_info(d)
                    type = find_type_from_process_server(
                        syskit_conf.process_server_config_for(d.process_server_name))
                    return if !type

                    tasks = d.each_orogen_deployed_task_context_model.map do |deployed_task|
                        Hash['task_name' => deployed_task.name,
                             'task_model_name' => deployed_task.task_model.name]
                    end

                    Hash[id: d.object_id,
                         created: deployment_manager.created_here?(d),
                         deployment_name: d.process_name,
                         tasks: tasks,
                         on: d.process_server_name,
                         mappings: d.name_mappings,
                         type: type]
                end

                PROCESS_SERVER_TYPES = Hash[
                    Orocos::RemoteProcesses::Client => 'orocos',
                    UnmanagedTasksManager => 'unmanaged'
                ]

                # Returns a string that describes the process server type
                #
                # @return [String,nil] the description, or nil if the given
                #   process server should not be exposed by the REST API
                def find_type_from_process_server(process_server_config)
                    PROCESS_SERVER_TYPES[process_server_config.client.class]
                end
            end

            get '/deployments/available' do
                by_deployment = Hash.new
                roby_app.default_pkgconfig_loader.each_available_deployed_task do |info|
                    key = [info.deployment_name, info.project_name]
                    deployment_info = (by_deployment[key] ||= Hash.new)
                    deployment_info[info.task_name] = info.task_model_name
                end
                info = by_deployment.map do |(deployment_name, project_name), tasks|
                    default_deployment_for =
                        if /^orogen_default_/.match?(deployment_name)
                            tasks[deployment_name]
                        end
                    default_logger =
                        if tasks[default_logger_name = "#{deployment_name}_Logger"] == 'logger::Logger'
                            default_logger_name
                        end

                    Hash[
                        name: deployment_name,
                        project_name: project_name,
                        tasks: tasks.map { |task_name, task_model_name| Hash['task_name' => task_name, 'task_model_name' => task_model_name] },
                        default_deployment_for: default_deployment_for,
                        default_logger: default_logger
                    ]
                end
                { deployments: info }
            end

            get '/deployments/registered' do
                registered_info = syskit_conf.each_configured_deployment.map do |d|
                    next if deployment_manager.used_in_override?(d)
                    make_configured_deployment_info(d)
                end
                overriden_info = deployment_manager.each_overriden_deployment.map do |d|
                    make_configured_deployment_info(d)
                end
                Hash['registered_deployments' => (overriden_info + registered_info).compact]
            end

            params do
                requires :name, type: String
                optional :as, type: String
            end
            post '/deployments' do
                begin
                    if params[:as]
                        id = deployment_manager.use_deployment(params[:name] => params[:as])
                        return Hash['registered_deployment' => id]
                    else
                        id = deployment_manager.use_deployment(params[:name])
                        return Hash['registered_deployment' => id]
                    end
                rescue Orocos::NotFound => e
                    error! "deployment name #{params[:name]} does not exist: #{e.message}", 404
                rescue TaskNameAlreadyInUse => e
                    error! "registering the deployment #{params[:name]} => #{params[:as]} would lead to a naming conflict", 409
                end
            end

            params do
                requires :id, type: Integer
            end
            delete '/deployments/:id' do
                deployment_manager.deregister_deployment(params[:id])
                body ''
            end

            delete '/deployments' do
                deployment_manager.clear
                body ''
            end

            params do
                requires :id, type: Integer
            end
            patch '/deployments/:id/unmanage' do
                ids = deployment_manager.make_unmanaged(params[:id])
                Hash[overriding_deployments: ids]
            end

            params do
                requires :id, type: Integer
            end
            patch '/deployments/:id/manage' do
                deployment_manager.deregister_override(params[:id])
                body ''
            end

            params do
                requires :id, type: Integer
                optional :tracing, type: Boolean, default: false
                optional :name_service_ip, type: String, default: 'localhost'
                optional :log_dir, type: String
            end
            get '/deployments/:id/command_line' do
                deployment_manager.command_line(params[:id],
                    tracing: params[:tracing],
                    name_service_ip: params[:name_service_ip],
                    log_dir: params[:log_dir] || roby_app.log_dir).to_h
            end
        end
    end
end
