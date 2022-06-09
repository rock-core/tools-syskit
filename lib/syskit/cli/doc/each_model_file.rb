# frozen_string_literal: true

module Syskit
    module CLI
        module Doc # :nodoc:
            # Enumerate the model files relevant for the given robot configuration
            #
            # @yieldparam [Pathname]
            def self.each_model_file_for_robot(root_path, robot_names, robots:)
                unless block_given?
                    return enum_for(__method__, root_path, robot_names, robots: robots)
                end

                each_model_path_for_robot(root_path, robot_names, robots: robots) do |p|
                    p.each_child do |file|
                        yield(file) if file.file? && file.extname == ".rb"
                    end
                end
            end

            # Enumerate the model paths whose content should be discovered for the
            # given robot configuration
            def self.each_model_path_for_robot(root_path, robot_names, robots:)
                unless block_given?
                    return enum_for(__method__, root_path, robot_names, robots: robots)
                end

                each_model_path(root_path, robots: robots) do |path, robot|
                    if robot_names.include?(robot)
                        yield(path)
                    elsif robot != "default"
                        prune
                    end
                end
            end

            # Enumerate the model paths along with what robot configuration they
            # are part of
            #
            # @yieldparam [Pathname] path
            # @yieldparam [String] robot
            # @yieldreturn [Boolean] true if the method should discover inside the path,
            #   false if it should be pruned
            def self.each_model_path(root_path, robots:, current_robot: "default", &block)
                unless block
                    return enum_for(
                        __method__, root_path,
                        robots: robots, current_robot: current_robot
                    )
                end

                root_path.each_child do |child|
                    next unless child.directory?

                    suffix = child.basename.to_s
                    this_robot =
                        if robots.has_robot?(suffix)
                            suffix
                        else
                            current_robot
                        end

                    catch(:prune) do
                        yield(child, this_robot)
                        each_model_path(
                            child, robots: robots, current_robot: this_robot, &block
                        )
                    end
                end
            end

            def self.prune
                throw :prune
            end
        end
    end
end
