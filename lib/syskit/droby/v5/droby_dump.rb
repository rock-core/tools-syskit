# frozen_string_literal: true

module Syskit
    module DRoby
        module V5
            module MarshalExtension
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

                def register_typelib_model(type)
                    object_manager.register_typelib_model(type)
                end

                def find_local_orogen_model(droby)
                    find_local_model(droby, name: "orogen::" + droby.orogen_name)
                end
            end

            module ObjectManagerExtension
                # The typelib registry on which we define types transmitted by
                # our peer
                attribute(:typelib_registry) { Typelib::Registry.new }

                # The loader used to register models transmitted by our peer
                def orogen_loader
                    Roby.app.default_loader
                end

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

                def register_typelib_model(type)
                    orogen_loader.register_type_model(type)
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
            # The manipulated registry is Orocos.registry
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

                        def initialize(name, remote_siblings, arguments, supermodel, provided_models, events,
                            orogen_name, orogen_superclass_name, project_name, project_text, types)
                            super(name, remote_siblings, arguments, supermodel, provided_models, events)
                            @orogen_name = orogen_name
                            @orogen_superclass_name = orogen_superclass_name
                            @project_name = project_name
                            @project_text = project_text
                            @types = types
                        end

                        def create_new_proxy_model(peer)
                            @types.each do |type|
                                peer.register_typelib_model(
                                    peer.local_object(type)
                                )
                            end

                            if @project_text && !peer.has_orogen_project?(@project_name)
                                peer.add_orogen_project(
                                    @project_name, @project_text
                                )
                            end

                            if @orogen_name
                                begin
                                    orogen_model = peer
                                                   .orogen_task_context_model_from_name(@orogen_name)
                                    local_model = Syskit::TaskContext
                                                  .define_from_orogen(orogen_model, register: false)
                                    if name
                                        local_model.name = name
                                    end
                                rescue OroGen::TaskModelNotFound
                                end
                            end

                            unless orogen_model
                                syskit_supermodel = peer.local_model(supermodel)
                                local_model = syskit_supermodel
                                              .new_submodel(name: @orogen_name)
                                if name
                                    local_model.name = name
                                end
                                peer.register_orogen_model(local_model, remote_siblings)
                            end

                            local_model
                        end

                        def unmarshal_dependent_models(peer)
                            @types.each do |type|
                                peer.register_typelib_model(
                                    peer.local_object(type)
                                )
                            end
                            super
                        end

                        def update(peer, local_object, fresh_proxy: false)
                            @types.each do |type|
                                peer.register_typelib_model(
                                    peer.local_object(type)
                                )
                            end
                            super
                        end
                    end

                    def droby_dump(peer)
                        types = orogen_model.each_interface_type
                                            .map { |t| peer.dump(t) }

                        supermodel = Roby::DRoby::V5::DRobyModel
                                     .dump_supermodel(peer, self)
                        provided_models = Roby::DRoby::V5::DRobyModel
                                          .dump_provided_models_of(peer, self)

                        orogen_name = orogen_model.name
                        if orogen_model.name && (project_name = orogen_model.project.name)
                            begin
                                project_text, = orogen_model.project.loader
                                                            .project_model_text_from_name(project_name)
                            rescue OroGen::ProjectNotFound
                            end
                        end

                        if orogen_model.superclass
                            orogen_superclass_name = orogen_model.superclass.name
                        end

                        peer.register_model(self)
                        DRoby.new(
                            name,
                            peer.known_siblings_for(self),
                            arguments,
                            supermodel,
                            provided_models,
                            each_event.map { |_, ev| [ev.symbol, ev.controlable?, ev.terminal?] },
                            orogen_name, orogen_superclass_name, project_name, project_text, types
                        )
                    end
                end
            end
        end
    end
end
