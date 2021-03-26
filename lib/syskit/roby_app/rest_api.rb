# frozen_string_literal: true

require "grape"
require "syskit/roby_app/rest_deployment_manager"

module Syskit
    module RobyApp
        # Extension to Roby's REST API
        #
        # It is mounted on the /syskit namespace by default, i.e. access it with
        # /api/syskit/...
        class REST_API < Grape::API
            format :json

            rescue_from RESTDeploymentManager::NotFound do |e|
                error! e.message, 404,
                       "x-roby-error" => e.class.name.gsub(/^.*::/, "")
            end

            rescue_from RESTDeploymentManager::Forbidden do |e|
                error! e.message, 403,
                       "x-roby-error" => e.class.name.gsub(/^.*::/, "")
            end

            helpers Roby::Interface::REST::Helpers
            helpers do
                def syskit_conf
                    Syskit.conf
                end

                # The {DeploymentManager} object that manages the deployments on behalf of the API
                def deployment_manager
                    @contexts ||=
                        (roby_storage["syskit.deployment_manager"] ||= RESTDeploymentManager.new(syskit_conf))
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
                    if info.task_model_name == "logger::Logger" && (info.task_name == info.deployment_name + "_Logger")
                        info_hash[:default_logger] = true
                    end
                    info_hash
                end

                def make_configured_deployment_info(d)
                    type = find_type_from_process_server(
                        syskit_conf.process_server_config_for(d.process_server_name)
                    )
                    return unless type

                    tasks = d.each_orogen_deployed_task_context_model.map do |deployed_task|
                        Hash["task_name" => deployed_task.name,
                             "task_model_name" => deployed_task.task_model.name]
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
                    Syskit::RobyApp::RemoteProcesses::Client => "orocos",
                    UnmanagedTasksManager => "unmanaged"
                ]

                # Returns a string that describes the process server type
                #
                # @return [String,nil] the description, or nil if the given
                #   process server should not be exposed by the REST API
                def find_type_from_process_server(process_server_config)
                    PROCESS_SERVER_TYPES[process_server_config.client.class]
                end
            end

            # List the orogen deployments that are available on this app
            #
            # GET /deployments/available
            #
            # It returns status 200 and the list of available deployments:
            #
            #        {
            #           deployments: [
            #               {
            #                   # The deployment's name
            #                   name: String,
            #                   # The deployment's defining oroGen project
            #                   project_name: String,
            #                   # The deployment's tasks
            #                   tasks: [
            #                       {
            #                           task_name: String,
            #                           task_model_name: String
            #                       }, ...
            #                   ],
            #                   # If this is a default deployment, the task model that is being deployed
            #                   default_deployment_for: String | nil,
            #                   # If this deployment has a default logger, its task name
            #                   default_logger: String | nil
            #               }, ...
            #           ]
            #       }
            #
            get "/deployments/available" do
                by_deployment = {}
                roby_app.default_pkgconfig_loader.each_available_deployed_task do |info|
                    key = [info.deployment_name, info.project_name]
                    deployment_info = (by_deployment[key] ||= {})
                    deployment_info[info.task_name] = info.task_model_name
                end
                info = by_deployment.map do |(deployment_name, project_name), tasks|
                    default_deployment_for =
                        if /^orogen_default_/.match?(deployment_name)
                            tasks[deployment_name]
                        end
                    default_logger =
                        if tasks[default_logger_name = "#{deployment_name}_Logger"] == "logger::Logger"
                            default_logger_name
                        end

                    Hash[
                        name: deployment_name,
                        project_name: project_name,
                        tasks: tasks.map { |task_name, task_model_name| Hash["task_name" => task_name, "task_model_name" => task_model_name] },
                        default_deployment_for: default_deployment_for,
                        default_logger: default_logger
                    ]
                end
                { deployments: info }
            end

            # List the orogen deployments that are available on this app
            #
            # GET /deployments/registered
            #
            # It returns status 200 and the list of registered deployments:
            #
            #        {
            #           registered_deployments: [
            #               {
            #                   # The deployment numerical ID that is used in
            #                   # the other deployment manipulation endpoints
            #                   id: Integer,
            #                   # Whether this deployment was created through
            #                   # the API itself (with POST /deployments), or
            #                   # is part of the app's configuration
            #                   created: Boolean,
            #                   # The name of the deployment
            #                   deployment_name: String,
            #                   # The deployment's tasks
            #                   tasks: [
            #                       {
            #                           task_name: String,
            #                           task_model_name: String
            #                       }, ...
            #                   ],
            #                   # The deployment's process server
            #                   on: String,
            #                   # The mapping to be applied on the deployment's
            #                   # tasks
            #                   mappings: { String => String },
            #                   # The deployment type (orocos or unmanaged)
            #                   type: type
            #               }, ...
            #           ]
            #       }
            #
            get "/deployments/registered" do
                registered_info = syskit_conf.deployment_group.each_configured_deployment.map do |d|
                    next if deployment_manager.used_in_override?(d)

                    make_configured_deployment_info(d)
                end
                overriden_info = deployment_manager.each_overriden_deployment.map do |d|
                    make_configured_deployment_info(d)
                end
                Hash["registered_deployments" => (overriden_info + registered_info).compact]
            end

            # Create a new deployment
            #
            # POST /deployments?name=model_name[&as=task_name_or_prefix]
            #
            # This is functionally equivalent to calling either
            #     Syskit.conf.use_deployment(name)
            # or  Syskit.conf.use_deployment(name => as)
            #
            # Returns status 200 on success, with the ID that can be used to
            # manipulate the new deployment further.
            #
            #    { registered_deployment: id }
            #
            # On failure,
            # - status 404 is returned if 'name' is not the name of
            #   an available deployment. x-roby-error is NotFound
            # - status 403 (Forbidden) if 'name' is an orogen
            #   model name and 'as' was not provided. x-roby-error is TaskNameRequired
            # - status 409 (Conflict) if defining this deployment would create
            #   tasks whose name is already in-use. x-roby-error is TaskNameAlreadyInUse
            params do
                requires :name, type: String
                optional :as, type: String
            end
            post "/deployments" do
                begin
                    if params[:as]
                        id = deployment_manager.use_deployment(params[:name] => params[:as])
                        return Hash["registered_deployment" => id]
                    else
                        id = deployment_manager.use_deployment(params[:name])
                        return Hash["registered_deployment" => id]
                    end
                rescue OroGen::NotFound => e
                    error! "deployment name #{params[:name]} does not exist: #{e.message}", 404,
                           "x-roby-error" => "NotFound"
                rescue TaskNameRequired => e
                    error! e.message, 403,
                           "x-roby-error" => "TaskNameRequired"
                rescue TaskNameAlreadyInUse => e
                    error! "registering the deployment #{params[:name]} => #{params[:as]} would lead to a naming conflict", 409,
                           "x-roby-error" => "TaskNameAlreadyInUse"
                end
            end

            # Undefines a deployment created by POST'ing /deployments
            #
            # @param [Integer] id
            #
            # Returns status 204 on success
            #
            # On failure,
            # - status 404 if the deployment ID is invalid. x-roby-error is NotFound
            # - 403 if the deployment had not been created with 'register'
            #   x-roby-error is NotCreatedHere
            params do
                requires :id, type: Integer
            end
            delete "/deployments/:id" do
                deployment_manager.deregister_deployment(params[:id])
                body ""
            end

            # Undefines all deployments created by POST'ing /deployments
            #
            # Returns status 204 on success
            delete "/deployments" do
                deployment_manager.clear
                body ""
            end

            # Turn an existing oroGen deployment into an unmanaged task
            #
            #     PATCH /deployments/:id/unmanage
            #
            # This overrides an existing deployment definition (typically
            # defined in the robot configuration) to turn it into an equivalent
            # unmanaged task definition. This can be used if one wants to
            # start a deployment externally, but still be able to integrate
            # it into the app
            #
            # @param [Integer] id the deployment's ID as returned by
            #    /deployments/registered.
            #
            # It returns status 200 on success, and the list of newly
            # defined deployments, as
            #
            #       { overriding_deployments: [Integer] }
            #
            # On failure,
            # - status 404 if the deployment ID is invalid. x-roby-error is
            #   NotFound
            # - status 403 (Forbidden) if the deployment was already
            #   overriden (x-roby-error is AlreadyOverriden) or if it was
            #   created by another override (x-roby-error is UsedInOverride)
            params do
                requires :id, type: Integer
            end
            patch "/deployments/:id/unmanage" do
                ids = deployment_manager.make_unmanaged(params[:id])
                Hash[overriding_deployments: ids]
            end

            # The inverse of 'unmanage'
            #
            #     PATCH /deployments/:id/manage
            #
            # @param [Integer] id the deployment's ID as returned by
            #    /deployments/registered.
            #
            # It returns status 200 on success.
            #
            # On failure,
            # - status 404 if the deployment ID is invalid. x-roby-error is NotFound.
            # - status 403 if the deployment was not overriden with 'unmanage'
            #   x-roby-error is NotOverriden
            params do
                requires :id, type: Integer
            end
            patch "/deployments/:id/manage" do
                deployment_manager.deregister_override(params[:id])
                body ""
            end

            # Returns the command line needed to start a given deployment
            #
            #     GET /deployments/:id/command_line
            #
            # @param [Integer] id the deployment's ID as returned by
            #    /deployments/registered.
            # @param [Boolean] tracing whether the lttng tracing should
            #    be enabled
            # @param [String] name_serve_ip (localhost) the IP or hostname
            #    of the naming service
            #
            # It returns a status 200 on success and
            #
            #     {
            #         # Environment variables that should be set
            #         env: { String => String, ... },
            #         # The program itself
            #         command: String,
            #         # The program arguments
            #         args: [String],
            #         # The recommended working directory (i.e. the app's log dir)
            #         working_directory: String
            #     }
            #
            # On failure,
            # - status 404 is returned if the deployment ID is invalid.
            #   x-roby-error is NotFound
            # - status 403 if the deployment is not an oroGen deployment.
            #   x-roby-error is NotOrogen
            params do
                requires :id, type: Integer
                optional :tracing, type: Boolean, default: false
                optional :name_service_ip, type: String, default: "localhost"
            end
            get "/deployments/:id/command_line" do
                deployment_manager.command_line(params[:id],
                                                tracing: params[:tracing],
                                                name_service_ip: params[:name_service_ip]).to_h
            end
        end
    end
end
