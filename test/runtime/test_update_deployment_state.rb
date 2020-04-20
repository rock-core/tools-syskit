# frozen_string_literal: true

require "syskit/test/self"

module Syskit
    module Runtime
        describe ".update_deployment_states" do
            it "calls #dead! on the dead deployments" do
                client = flexmock
                flexmock(Syskit.conf).should_receive(:each_process_server_config)
                                     .and_return([flexmock(client: client)])
                client.should_receive(:wait_termination).and_return([[p = flexmock, s = flexmock]])
                flexmock(Deployment).should_receive(:deployment_by_process).with(p)
                                    .and_return(d = flexmock(finishing?: true))
                d.should_receive(:dead!).with(s).once
                Runtime.update_deployment_states(plan)
            end
        end
    end
end
