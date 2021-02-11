# frozen_string_literal: true

module Syskit
    module Queries
        module AbstractComponentBase
            def port_by_name?(name)
                @model.any? { |m| m.find_port(name) }
            end

            def find_port_by_name(name)
                ports = @model.map { |m| m.find_port(name) }.compact
                return ports.first if ports.size <= 1

                model_s = @model.map(&:to_s).join(", ")
                raise Ambiguous,
                      "more than one port named '#{name}' exist on composite model "\
                      "#{model_s}. Select a data service explicitly to disambiguate"
            end

            def find_port_matcher_by_name(name)
                return unless (port = find_port_by_name(name))

                PortMatcher.new(self).with_name(name).with_type(port.type)
            end

            # Create a {PortMatcher} to match the given port on results of this matcher
            #
            # @param [String] name the port name
            # @return [PortMatcher]
            def port_matcher_by_name(name)
                port = find_port_matcher_by_name(name)
                return port if port

                model_s = @model.map(&:to_s).join(", ")
                raise ArgumentError,
                      "no port named '#{name}' on #{model_s}, refine the "\
                      "model with .which_fullfills first"
            end

            def data_service_by_name?(name)
                @model.any? do |m|
                    m.find_data_service(name) if m.respond_to?(:find_data_service)
                end
            end

            def find_data_service_by_name(name)
                ds = @model.map do |m|
                    m.find_data_service(name) if m.respond_to?(:find_data_service)
                end.compact
                return ds.first if ds.size <= 1

                raise NotImplementedError,
                      "more than one port named #{name} on composite model "\
                      "#{model_s}. This is likely to be a Syskit bug"
            end

            def find_data_service_matcher_by_name(name)
                return unless (ds = find_data_service_by_name(name))

                DataServiceMatcher
                    .new(self)
                    .with_name(name)
                    .with_model(ds.model)
            end

            # Create a {DataServiceMatcher} to match the given port on results
            # of this matcher
            #
            # @param [String] name the port name
            # @return [DataServiceMatcher]
            def data_service_matcher_by_name(name)
                ds = find_data_service_matcher_by_name(name)
                return ds if ds

                model_s = @model.map(&:to_s).join(", ")
                raise ArgumentError,
                      "no port named '#{name}' on #{model_s}, refine the "\
                      "model with .with_model first"
            end

            include MetaRuby::DSLs::FindThroughMethodMissing

            def has_through_method_missing?(m)
                MetaRuby::DSLs.has_through_method_missing?(
                    self, m,
                    "_srv" => :data_service_by_name?,
                    "_port" => :port_by_name?
                ) || super
            end

            def find_through_method_missing(m, args)
                MetaRuby::DSLs.find_through_method_missing(
                    self, m, args,
                    "_srv" => :find_data_service_matcher_by_name,
                    "_port" => :find_port_matcher_by_name
                ) || super
            end
        end
    end
end
