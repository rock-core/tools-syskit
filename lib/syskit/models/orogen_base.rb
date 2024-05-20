# frozen_string_literal: true

module Syskit
    module Models
        # Base functionality for model classes that deal with oroGen models
        module OrogenBase
            # Checks whether a syskit model exists for the given orogen model
            def has_model_for?(orogen_model)
                !!each_submodel.find { |m| m.orogen_model == orogen_model }
            end

            # Finds the Syskit model that represents an oroGen model with that
            # name
            def find_model_from_orogen_name(name)
                each_submodel do |syskit_model|
                    if syskit_model.orogen_model.name == name
                        return syskit_model
                    end
                end
                nil
            end

            # Return all syskit models subclasses of self that represent the
            # given oroGen model
            #
            # @param orogen_model the oroGen model
            # @return [Array<Syskit::TaskContext,Syskit::Deployment>] the
            #   corresponding syskit model, or nil if there are none registered
            def find_all_models_by_orogen(orogen_model)
                each_submodel.find_all do |syskit_model|
                    syskit_model.orogen_model == orogen_model
                end
            end

            # Return the syskit model that represents the given oroGen model
            #
            # @param orogen_model the oroGen model
            # @return [Syskit::TaskContext,Syskit::Deployment,nil] the
            #   corresponding syskit model, or nil if there are none registered
            def find_model_by_orogen(orogen_model)
                each_submodel do |syskit_model|
                    if syskit_model.orogen_model == orogen_model
                        return syskit_model
                    end
                end
                nil
            end

            # Returns the syskit model subclass of self for the given oroGen model
            #
            # @raise ArgumentError if no syskit model exists
            # @raise ArgumentError if more than one matching syskit model exists,
            #   and Conf.syskit.strict_model_for is set to true
            def model_for(orogen_model)
                if Syskit.conf.strict_model_for?
                    strict_model_for(orogen_model)
                elsif (m = find_model_by_orogen(orogen_model))
                    m
                else
                    raise ArgumentError, "there is no Syskit model for #{orogen_model.name}"
                end
            end

            # @api private
            #
            # Implementation of {#model_for} when Syskit.conf.strict_model_for is set
            def strict_model_for(orogen_model)
                matches = find_all_models_by_orogen(orogen_model)
                if matches.size == 1
                    matches.first
                elsif matches.empty?
                    raise ArgumentError,
                          "there is no Syskit model for #{orogen_model.name}"
                else
                    raise ArgumentError,
                          "more than one Syskit model matches #{orogen_model.name}"
                end
            end
        end
    end
end
