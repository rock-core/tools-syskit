module Syskit
    module Test
        class Spec < Roby::Test::Spec
            include Test
            include Test::ActionAssertions
            include Test::NetworkManipulation

            def self.it(*args, &block)
                super(*args) do
                    begin
                        instance_eval(&block)
                    rescue Exception => e
                        if e.class.name =~ /Syskit|Roby/
                            pp e
                        end
                        raise
                    end
                end
            end

            def plan; Roby.plan end
        end
    end
end

