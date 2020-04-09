# frozen_string_literal: true

module Syskit
    module Test
        # Module containing extensions to flexmock to ease testing syskit
        # objects
        module FlexMockExtension
            # Specifies that an operation is expected to be called. The mocked
            # object is the Syskit taskcontext (NOT the orocos task context)
            def should_receive_operation(*args)
                unless @obj.orocos_task
                    @obj.execution_agent.start!
                end
                flexmock_container.flexmock(@obj.orocos_task).should_receive(*args)
            end
        end
        FlexMock::PartialMockProxy.include FlexMockExtension
    end
end
