module Syskit
    module Test
        # Base class for testing {Actions::Profile}
        class ProfileTest < Spec
            include Syskit::Test
            include ProfileAssertions
            extend ProfileModelAssertions

            def assert_is_self_contained(definition, options = Hash.new)
                options, instanciate_options = Kernel.filter_options options,
                    :message => "#{definition.name}_def is not self contained"
                message = options[:message]
                engine, _ = try_instanciate([definition],
                                            instanciate_options.merge(
                                                compute_policies: false,
                                                compute_deployments: false,
                                                validate_generated_network: false))
                still_abstract = plan.find_local_tasks(Syskit::Component).
                    abstract.to_a
                tags, other = still_abstract.partition { |task| task.class <= Actions::Profile::Tag }
                tags_from_other = tags.find_all { |task| task.class.profile != self.class.desc }
                if !other.empty?
                    raise Roby::Assertion.new(TaskAllocationFailed.new(engine, other)), message
                elsif !tags_from_other.empty?
                    other_profiles = tags_from_other.map { |t| t.class.profile }.uniq
                    raise Roby::Assertion.new(TaskAllocationFailed.new(engine, tags)), "#{definition.name} contains tags from another profile (found #{other_profiles.map(&:name).sort.join(", ")}, expected #{self.class.desc})"
                end
            end

            # Tests that the only variation points left in all definitions are
            # profile tags
            def self.it_should_be_self_contained(*definitions)
                if definitions.empty?
                    definitions = desc.definitions.values
                end
                definitions.each do |d|
                    it "#{d.name}_def should be self-contained" do
                        assert_is_self_contained(d)
                    end
                end
            end

            def self.method_missing(m, *args)
                MetaRuby::DSLs.find_through_method_missing(desc, m, args, 'def' => 'definition') ||
                    super
            end
        end
    end
end
