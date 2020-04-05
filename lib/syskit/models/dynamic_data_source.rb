# frozen_string_literal: true

module Syskit
    module Models
        # Model for {Syskit::DynamicDataSource}
        class DynamicDataSource
            # The underlying port model
            #
            # May either be a {Port} or a {PortMatcher}
            attr_reader :port_model

            # This resolver's data type
            attr_reader :type

            def initialize(port_model)
                @port_model = port_model
                @root_resolver = Resolver.new(self)
            end

            class NullResolver
                def __resolve(value)
                    value
                end
            end

            # @api private
            #
            # Representation of a typed field or sub-field
            class Resolver < BasicObject
                def initialize(source, type: source.type, path: [])
                    @source = source
                    @path = path
                    @type = type
                    @transform = nil
                end

                def __resolve(value)
                    resolved_path = @path.inject(value) do |v, (m, args, _)|
                        v.send(m, *args)
                    end
                    resolved_path = ::Typelib.to_ruby(resolved_path)
                    if @transform
                        @transform.call(resolved_path)
                    else
                        resolved_path
                    end
                end

                def respond_to?(m, _include_private = false)
                    if @type <= ::Typelib::CompoundType
                        @type.has_field?(m)
                    elsif @type <= ::Typelib::ArrayType ||
                          @type <= ::Typelib::ContainerType
                        m == :[]
                    end
                end

                def method_missing(m, *args, **kw) # rubocop:disable Style/MethodMissingSuper, Style/MissingRespondToMissing
                    unless kw.empty?
                        ::Kernel.raise(
                            ::ArgumentError,
                            "expected zero keyword arguments, got #{kw.size}"
                        )
                    end

                    if @transform
                        ::Kernel.raise(
                            ::ArgumentError,
                            'cannot refine a resolver once .transform has been called'
                        )
                    end

                    if @type <= ::Typelib::ArrayType || @type <= ::Typelib::ContainerType
                        __indexed_access(m, args)
                    elsif @type <= ::Typelib::CompoundType
                        __compound_access(m, args)
                    end
                end

                def __indexed_access(m, args)
                    if m != :[]
                        ::Kernel.raise ::NoMethodError.new(
                            "undefined method #{m} on #{@type}", m
                        )
                    elsif args.size != 1
                        ::Kernel.raise ::ArgumentError,
                                       "expected one argument, got #{args.size}"
                    elsif !args.first.kind_of?(::Numeric)
                        ::Kernel.raise ::TypeError,
                                       "expected an integer argument, got '#{args.first}'"
                    elsif @type <= ::Typelib::ArrayType && @type.length <= args.first
                        ::Kernel.raise ::ArgumentError,
                                       "element #{args.first} out of bound in "\
                                       "an array of #{@type.length}"
                    end

                    new_step = [:raw_get, args, @type.deference]
                    Resolver.new(
                        @source, path: @path.dup << new_step, type: new_step.last
                    )
                end

                def __compound_access(m, args)
                    if !@type.has_field?(m)
                        ::Kernel.raise ::NoMethodError.new(
                            "undefined method #{m} on #{@type}", m
                        )
                    elsif !args.empty?
                        ::Kernel.raise ::ArgumentError,
                                       "expected zero arguments, got #{args.size}"
                    end

                    new_step = [:raw_get, [m], @type[m]]
                    Resolver.new(
                        @source, path: @path.dup << new_step, type: new_step.last
                    )
                end

                def transform(&block)
                    if @transform
                        ::Kernel.raise ::ArgumentError,
                                       'this resolver already has a transform block'
                    end
                    @transform = block
                    self
                end

                def instanciate(task)
                    @source.instanciate(task, resolver: self)
                end
            end

            # Specify that the read samples should be transformed with the given block
            #
            # This is a terminal action. No subfields and no other transforms may be
            # added further
            def transform(&block)
                @root_resolver.transform(&block)
            end

            # Defined to match the {Resolver} interface
            def __resolve(value)
                value
            end

            def respond_to_missing?(m, _)
                @root_resolver.respond_to?(m)
            end

            def method_missing(m, *args, **kw) # rubocop:disable Style/MethodMissingSuper
                @root_resolver.__send__(m, *args, **kw)
            end

            def self.create(port)
                if port.respond_to?(:component_model) &&
                   port.component_model.kind_of?(CompositionChild)
                    FromCompositionChild.new(port)
                elsif port.respond_to?(:match)
                    FromMatcher.new(port.match)
                else
                    raise ArgumentError,
                          "cannot create a data source from #{port}, expected either "\
                          'a model of composition child\'s port or a port matcher'
                end
            end

            # Dynamic port resolver that is based on a plan query
            #
            # These resolvers find a running task using the given query, resolves
            # the port and yield new samples from there
            class FromMatcher < DynamicDataSource
                # Create a data source from a port matcher
                #
                # @param [#match] matcher
                def initialize(matcher)
                    matcher = matcher.match
                    unless (@type = matcher.try_resolve_type)
                        raise ArgumentError,
                              'cannot create a dynamic data source from a matcher '\
                              'whose type cannot be inferred'
                    end

                    super(matcher)
                end

                def instanciate(task, resolver: NullResolver.new)
                    Syskit::DynamicDataSource::FromMatcher
                        .new(task.plan, self, resolver: resolver)
                end
            end

            # Dynamic port resolver that is based on a composition child
            #
            # These resolvers resolve a port of a (grand)child of the root task
            class FromCompositionChild < DynamicDataSource
                def initialize(port)
                    @type = port.type
                    super(port)
                end

                def instanciate(task, resolver: NullResolver.new)
                    child = @port_model.component_model.resolve_and_bind_child_recursive(
                        task
                    )
                    port = @port_model.bind(child)
                    Syskit::DynamicDataSource::FromPort
                        .new(port, self, resolver: resolver)
                end
            end
        end
    end
end
