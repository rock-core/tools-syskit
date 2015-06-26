module Syskit
    module Test
        # Base class for testing {Actions::Profile}
        class ProfileTest < Spec
            include Syskit::Test
            include ProfileAssertions

            def self.subject_syskit_model
                if @subject_syskit_model
                    return @subject_syskit_model
                elsif desc.kind_of?(Syskit::Actions::Profile)
                    return desc
                else
                    super
                end
            end

            class << self
                def self.define_deprecated_test_form(name)
                    define_method("it_#{name}") do |*args, **options|
                        Syskit::Test.warn "class-level it_#{name} is deprecated, replace by"
                        Syskit::Test.warn "it { #{name}(a_def, another_def) }"
                        it { send(name, *args, **options) }
                    end
                    define_method("it_#{name}_all") do |**options|
                        Syskit::Test.warn "class-level it_#{name}_all is deprecated, replace by"
                        Syskit::Test.warn "it { #{name} }"
                        it { send(name, **options) }
                    end
                    define_method("it_#{name}_together") do |*args, **options|
                        Syskit::Test.warn "class-level it_#{name}_together is deprecated, replace by"
                        Syskit::Test.warn "it { #{name}(a_def, another_def) }"
                        it { send(name, *args, **options) }
                    end
                end
                define_deprecated_test_form(:can_instanciate)
                define_deprecated_test_form(:can_deploy)
                define_deprecated_test_form(:can_configure)

                # @deprecated replace by
                #   it { is_self_contained }
                #   it { is_self_contained(a_def, another_def) }
                def it_should_be_self_contained(*definitions)
                    it { is_self_contained(*definitions) }
                end

                def find_definition(name)
                    desc.resolved_definition(name)
                end

                def find_device(name)
                    desc.robot.devices[name]
                end

                def method_missing(m, *args)
                    MetaRuby::DSLs.find_through_method_missing(self, m, args, 'def' => 'find_definition', 'dev' => 'find_device') ||
                        super
                end
            end

            def method_missing(m, *args)
                MetaRuby::DSLs.find_through_method_missing(self.class, m, args, 'def' => 'find_definition', 'dev' => 'find_device') ||
                    super
            end

        end
    end
end
