# frozen_string_literal: true

module Syskit
    module Telemetry
        module Async
            # Management class for all property updates
            class PropertyManager
                def initialize
                    @callbacks = {}
                    @registry = Typelib::Registry.new
                end

                # Add new type definitions to the internal registry
                #
                # @param [Typelib::Registry] registry
                def update_registry(registry)
                    @registry.merge(registry)
                end

                # Process updates received from the Syskit interface
                #
                # @param [Interface::V2::Protocol::PropertyUpdates] updates
                # @return [Interface::V2::Protocol::PropertyUpdates,nil]
                #    the part of the update that can't be processed because of missing
                #    types, if any. nil otherwise.
                def process_updates(updates)
                    task_updates_with_missing_types =
                        updates.task_updates.map do |task_update|
                            process_task_update(task_update)
                        end

                    task_updates_with_missing_types.compact!
                    return if task_updates_with_missing_types.empty?

                    Interface::V2::Protocol::PropertyUpdates.new(
                        time: updates.time,
                        task_updates: task_updates_with_missing_types
                    )
                end

                # @api private
                #
                # Process a single task update
                #
                # @return [nil,Interface::V2::Protocol::PropertyTaskUpdates] the updates
                #   that have missing types or nil if there aren't any
                def process_task_update(task_update)
                    ready, missing =
                        task_update.properties.partition do |property|
                            @registry.include?(property.value.type_name)
                        end

                    ready.each do |property|
                        dispatch_property_update(task_update.name, property)
                    end

                    return if missing.empty?

                    Interface::V2::Protocol::PropertyTaskUpdates
                        .new(id: task_update.id, name: task_update.name,
                             properties: missing)
                end

                # Register a callback that will be called every time a property is updated
                #
                # @param [Property] property
                # @param [#call] callback
                # @return [#dispose] a disposable that will deregister the callback
                def register_callback(property, callback)
                    task_name = property.task_context.name
                    property_name = property.name

                    task_callbacks = (@callbacks[task_name] ||= {})
                    property_callbacks = (task_callbacks[property_name] ||= [])
                    property_callbacks << callback

                    Roby.disposable do
                        deregister_callback(property, callback)
                    end
                end

                # Remove a registered callback
                #
                # Does nothing if the callback is not registered
                def deregister_callback(property, callback)
                    task_name = property.task_context.name
                    return unless (task_callbacks = @callbacks[task_name])

                    property_name = property.name
                    return unless (property_callbacks = task_callbacks[property_name])

                    property_callbacks.delete(callback)
                    task_callbacks.delete(property_name) if property_callbacks.empty?
                    @callbacks.delete(task_name) if task_callbacks.empty?
                end

                # Whether there are callbacks for the given async property
                def callback_for_property?(property)
                    @callbacks.dig(
                        property.task_context.name,
                        property.name
                    )
                end

                # Whether there are callbacks for the given task name
                def callback_for_task_by_name?(task_name)
                    @callbacks[task_name]
                end

                # Emit the callbacks associated with a given property update
                #
                # @param [String] task_name the task name
                # @param [Interface::V2::Protocol::PropertyUpdate] property_update
                def dispatch_property_update(task_name, property_update)
                    callbacks = @callbacks.dig(task_name, property_update.name)
                    return unless callbacks

                    value =
                        @registry.build(property_update.value.type_name)
                                 .from_buffer(property_update.value.bytes)
                    callbacks.each do |c|
                        c.call(value)
                    end
                end

                def dispose; end
            end
        end
    end
end
