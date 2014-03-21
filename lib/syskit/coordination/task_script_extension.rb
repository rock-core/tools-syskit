module Syskit
    module Coordination
        module TaskScriptExtension
        
	    # Waits until this data writer is {InputWriter#ready?}
        def wait_until_ready(writer)
            poll do
                if writer.ready?
                    transition!
                end
            end
        end
	    
	            #Adds a delay
        def delay(how_long)
            if(how_long == nil or how_long==0)
                return
            end
                
            start_time = nil
            poll do
                start_time = Types::Base::Time.now
                transition!
            end
           
            poll do
                current_time = Types::Base::Time.now
                if(current_time - start_time >= delay)
                    transition!
                end
            end
        end

        class Timeout < RuntimeError
        end
                
        def timeout_poll(timeout, &block)
            if not timeout
                puts "Will wait forever..."
            end
            
            start_time = Types::Base::Time.now

            poll do
                current_time = Types::Base::Time.now
                waited = current_time - start_time
                if(timeout and waited > timeout)
                    raise Timeout, "Timeout after #{waited} seconds. Configred: #{timeout}"
                end
                
                begin
                    puts "Calling block..."
                    block.call
                rescue Exception => e
                    puts "Exception in user provided block"
                    puts e
                    raise e
                end
            end
        end
           

            def method_missing(m, *args, &block)
                if m.to_s =~ /_port$/
                    instance_for(model.root).send(m, *args, &block)
                else super
                end
            end
        end
    end
end
Roby::Coordination::TaskScript.include Syskit::Coordination::TaskScriptExtension
