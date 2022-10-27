# frozen_string_literal: true

module Syskit
    module DRoby
        module V5
            VERSION = 1

            @rebuild_orogen_models = false

            # Global control for {ObjectManager#rebuild_orogen_models?}
            #
            # Changes apply only to object managers created after the change was done
            def self.rebuild_orogen_models=(flag)
                @rebuild_orogen_models = flag
            end

            # Global control for {ObjectManager#rebuild_orogen_models?}
            #
            # Changes apply only to object managers created after the change was done
            def self.rebuild_orogen_models?
                @rebuild_orogen_models
            end

            class Loader < OroGen::Loaders::Base
                class Project < OroGen::Loaders::Project
                    def using_task_library(*, **); end
                end

                def project_model_from_text(text, name: nil, path: nil)
                    project = OroGen::Spec::Project.new(root_loader)
                    project.typekit = OroGen::Spec::Typekit.new(root_loader, name)
                    Project.new(project).__eval__(path, text)
                    register_project_model(project)
                    project
                end
            end

            module MarshalExtension
                def initialize(*, **)
                    super

                    @registered_projects = []
                end

                def has_orogen_project?(project_name)
                    object_manager.has_orogen_project?(project_name)
                end

                def add_orogen_project(project_name, project_text)
                    object_manager.add_orogen_project(project_name, project_text)
                end

                def orogen_task_context_model_from_name(name)
                    object_manager.orogen_task_context_model_from_name(name)
                end

                def register_orogen_model(local_model, remote_siblings)
                    object_manager.register_orogen_model(local_model, remote_siblings)
                end

                def register_typelib_model(type, interface_type:)
                    object_manager.register_typelib_model(
                        type, interface_type: interface_type
                    )
                end

                def find_local_orogen_model(droby)
                    find_local_model(droby, name: "orogen::" + droby.orogen_name)
                end

                def registered_orogen_project?(project)
                    @registered_projects.include?(project)
                end

                def register_orogen_project(project)
                    @registered_projects << project
                end
            end

            module ObjectManagerExtension
                def initialize(*)
                    super

                    @rebuild_orogen_models = V5.rebuild_orogen_models?
                end

                def use_global_loader=(flag)
                    if @orogen_loader
                        return if flag == @use_global_loader

                        raise ArgumentError,
                              "cannot change use_global_loader after the loader has "\
                              "been created"
                    end

                    @orogen_loader =
                        if flag
                            Roby.app.default_loader
                        else
                            Loader.new
                        end
                    @use_global_loader = flag
                end

                # Use Roby.app.loader instead of the local loader for pre-v1 logs
                def use_global_loader?
                    @use_global_loader
                end

                # Control whether we rebuild orogen models or not
                #
                # Disabling this helps with older log files that can't be loaded
                # anymore because they have incompatible types. Newer logs do not
                # have this issue.
                def rebuild_orogen_models=(flag)
                    @rebuild_orogen_models = flag
                end

                # Whether we try to rebuild orogen models or not
                def rebuild_orogen_models?
                    @rebuild_orogen_models
                end

                # The orogen loader on which we define orogen models transmitted by
                # our peer
                def orogen_loader
                    unless @orogen_loader
                        @use_global_loader = false
                        @orogen_loader = Loader.new
                    end

                    @orogen_loader
                end

                # The typelib registry on which we define types transmitted by
                # our peer
                attribute(:typelib_registry) { Typelib::Registry.new }

                def has_orogen_project?(project_name)
                    orogen_loader.has_project?(project_name)
                end

                def add_orogen_project(project_name, project_text)
                    orogen_loader.project_model_from_text(project_text, name: project_name)
                end

                def orogen_task_context_model_from_name(name)
                    orogen_loader.task_model_from_name(name)
                end

                def register_orogen_model(local_model, remote_siblings)
                    model_name  = local_model.name
                    orogen_name = local_model.orogen_model.name

                    if orogen_name
                        orogen_loader.register_task_context_model(local_model.orogen_model)
                        register_model(local_model, remote_siblings, name: "orogen::#{orogen_name}")
                    else
                        register_model(local_model, remote_siblings, name: model_name)
                    end
                end

                def register_typelib_model(type, interface_type:)
                    orogen_loader.register_type_model(type, interface_type)
                end
            end

            module ComBusDumper
                # Must include this, Roby uses it to know which models can be
                # dumped and which not
                include Roby::DRoby::V5::ModelDumper

                class DRoby < Roby::DRoby::V5::DRobyModel
                    attr_reader :message_type
                    attr_reader :lazy_dispatch

                    def initialize(message_type, lazy_dispatch, *args)
                        @message_type = message_type
                        @lazy_dispatch = lazy_dispatch
                        super(*args)
                    end

                    def create_new_proxy_model(peer)
                        supermodel = peer.local_model(self.supermodel)
                        # 2016-05: workaround broken log files in which types
                        #          are marshalled as strings instead of type
                        #          objects
                        if message_type.respond_to?(:to_str)
                            message_type = Roby.app.default_loader.resolve_type(self.message_type, define_dummy_type: true)
                        else
                            message_type = peer.local_object(self.message_type)
                        end

                        # We unfortunately must register the type on the global
                        # loader. We're not ready yet for a fully mixed-loader
                        # setup
                        Roby.app.default_loader.register_type_model(message_type)

                        local_model = supermodel.new_submodel(name: name, lazy_dispatch: lazy_dispatch, message_type: message_type)
                        peer.register_model(local_model, remote_siblings)
                        local_model
                    end
                end

                def droby_dump(peer)
                    DRoby.new(
                        peer.dump(message_type),
                        lazy_dispatch?,
                        name,
                        peer.known_siblings_for(self),
                        Roby::DRoby::V5::DRobyModel.dump_supermodel(peer, self),
                        Roby::DRoby::V5::DRobyModel.dump_provided_models_of(peer, self)
                    )
                end
            end

            # Module used to allow droby-marshalling of Typelib values
            #
            # The manipulated registry is Runkit.registry
            module TypelibTypeDumper
                # Marshalling representation of a typelib value
                class DRoby
                    attr_reader :byte_array
                    attr_reader :type
                    def initialize(byte_array, type)
                        @byte_array = byte_array
                        @type = type
                    end

                    def proxy(peer)
                        peer.local_object(type).from_buffer(byte_array)
                    end
                end

                def droby_dump(peer)
                    DRoby.new(to_byte_array, peer.dump(self.class))
                end
            end

            # Module used to allow droby-marshalling of Typelib types
            module TypelibTypeModelDumper
                # Class used to transfer the definition of a type
                class DRoby
                    attr_reader :name, :xml
                    def initialize(name, xml)
                        @name = name
                        @xml = xml
                    end

                    def proxy(peer)
                        if xml
                            reg = Typelib::Registry.from_xml(xml)
                            peer.object_manager.typelib_registry.merge(reg)
                        end
                        peer.object_manager.typelib_registry.get(name)
                    end
                end

                def droby_dump(peer)
                    peer_registry = peer.object_manager.typelib_registry

                    unless peer_registry.include?(name)
                        reg = registry.minimal(name)
                        xml = reg.to_xml
                        peer_registry.merge(reg)
                    end
                    DRoby.new(name, xml)
                end
            end

            module InstanceRequirementsDumper
                class DRoby
                    def initialize(name, model, arguments)
                        @name = name
                        @model = model
                        @arguments = arguments
                    end

                    def proxy(peer)
                        requirements = InstanceRequirements.new([peer.local_object(@model)])
                        requirements.name = @name
                        requirements.with_arguments(**@arguments)
                        requirements
                    end
                end

                def droby_dump(peer)
                    DRoby.new(name,
                              peer.dump(model),
                              peer.dump(arguments))
                end
            end

            module ProfileDumper
                class DRoby < Roby::DRoby::V5::DistributedObjectDumper::DRoby
                    def initialize(name, remote_siblings)
                        super(remote_siblings, [])
                        @name = name
                    end

                    def proxy(peer)
                        if !@name
                            return Actions::Profile.new
                        elsif local = peer.find_model_by_name(@name)
                            return local
                        end

                        profile =
                            begin
                                constant(@name)
                            rescue Exception
                                Actions::Profile.new(@name)
                            end

                        peer.register_model(profile)
                        profile
                    end
                end

                def droby_dump(peer)
                    peer.register_model(self)
                    DRoby.new(name, peer.known_siblings_for(self))
                end

                def clear_owners; end
            end

            module Models
                module TaskContextDumper
                    include Roby::DRoby::V5::Models::TaskDumper

                    class DRoby < Roby::DRoby::V5::Models::TaskDumper::DRoby
                        attr_reader :orogen_name

                        def initialize(
                            name, remote_siblings, arguments, supermodel, provided_models,
                            events, orogen_name, orogen_superclass_name, project_name,
                            project_text, types
                        )
                            super(name, remote_siblings, arguments,
                                  supermodel, provided_models, events)
                            @orogen_name = orogen_name
                            @orogen_superclass_name = orogen_superclass_name
                            @project_name = project_name
                            @project_text = project_text
                            @types = types
                            @version = VERSION
                        end

                        def create_new_proxy_model(peer)
                            unless (local_model = resolve_exact_orogen_model(peer))
                                syskit_supermodel = peer.local_model(supermodel)
                                local_model =
                                    syskit_supermodel
                                    .new_submodel(name: @orogen_name,
                                                  extended_state_support: false)
                                if name
                                    local_model.name = name
                                end
                                peer.register_orogen_model(local_model, remote_siblings)
                            end

                            local_model
                        end

                        def register_types(peer)
                            return unless @types

                            @types.each do |t|
                                t = peer.local_object(t)
                                peer.register_typelib_model(t, interface_type: true)
                            end
                        end

                        def resolve_exact_orogen_model(peer)
                            return unless peer.object_manager.rebuild_orogen_models?

                            if @project_text && !peer.has_orogen_project?(@project_name)
                                peer.add_orogen_project(@project_name, @project_text)
                            end

                            return unless @orogen_name
                            return unless peer.has_orogen_project?(@project_name)

                            begin
                                orogen_model =
                                    peer
                                    .orogen_task_context_model_from_name(@orogen_name)
                            rescue OroGen::TaskModelNotFound
                                return
                            end

                            local_model =
                                Syskit::TaskContext
                                .define_from_orogen(orogen_model, register: false)
                            local_model.name = name if name
                            local_model
                        end

                        def unmarshal_dependent_models(peer)
                            peer.object_manager.use_global_loader = @version.nil?
                            register_types(peer)

                            super
                        end

                        def update(peer, local_object, fresh_proxy: false)
                            register_types(peer) unless fresh_proxy

                            super
                        end
                    end

                    def self.related_types_for(type)
                        return [] unless type.contains_opaques?

                        [Roby.app.default_loader.intermediate_type_for(type)]
                    end

                    Project = Struct.new :name, :text, :types

                    # Return the marshallable information about an orogen project
                    #
                    # This is the information that is needed to un-marshal it. It
                    # It returns nil if there is no usable information about this project
                    def droby_dump_project(peer, project)
                        if peer.registered_orogen_project?(project)
                            return Project.new(nil, nil, [])
                        elsif project.name
                            begin
                                text, = project
                                        .loader.project_model_text_from_name(project.name)
                            rescue OroGen::ProjectNotFound
                            end
                        end

                        types =
                            (project.self_tasks.values + [orogen_model])
                            .map { |t| t.each_interface_type.to_a }
                            .flatten.uniq
                            .flat_map { |t| [t] + TaskContextDumper.related_types_for(t) }
                        types = types.map { |t| peer.dump(t) }
                        Project.new(project.name, text, types)
                    end

                    def droby_dump(peer)
                        project_dump = droby_dump_project(peer, orogen_model.project)

                        supermodel = Roby::DRoby::V5::DRobyModel
                                     .dump_supermodel(peer, self)
                        provided_models = Roby::DRoby::V5::DRobyModel
                                          .dump_provided_models_of(peer, self)
                        orogen_superclass_name = orogen_model.superclass&.name

                        peer.register_model(self)
                        DRoby.new(
                            name,
                            peer.known_siblings_for(self),
                            arguments,
                            supermodel,
                            provided_models,
                            each_event.map { |_, ev| [ev.symbol, ev.controlable?, ev.terminal?] },
                            orogen_model.name, orogen_superclass_name,
                            project_dump.name, project_dump.text, project_dump.types
                        )
                    end
                end
            end
        end
    end
end
