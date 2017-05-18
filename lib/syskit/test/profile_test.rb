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
                    subject_syskit_model.resolved_definition(name)
                end

                def find_device(name)
                    subject_syskit_model.robot.devices[name]
                end

                def has_through_method_missing?(m)
                    MetaRuby::DSLs.has_through_method_missing?(
                        self, m,
                        '_def' => :find_definition,
                        '_dev' => :find_device) || super
                end

                def find_through_method_missing(m, args)
                    MetaRuby::DSLs.find_through_method_missing(
                        self, m, args,
                        '_def' => :find_definition,
                        '_dev' => :find_device) || super
                end

                def respond_to_missing?(m, include_private)
                    has_through_method_missing?(m) || super
                end

                def method_missing(m, *args)
                    find_through_method_missing(m, args) || super
                end
            end

            def has_through_method_missing?(m)
                self.class.has_through_method_missing?(m) || super
            end

            def find_through_method_missing(m, args)
                self.class.find_through_method_missing(m, args) || super
            end

            def respond_to_missing?(m, include_private)
                has_through_method_missing?(m) || super
            end

            def method_missing(m, *args)
                find_through_method_missing(m, args) || super
            end

        end
    end
end
