<% indent, open_code, close_code = ::Roby::App::GenBase.in_module(*class_name[0..-2]) %>
<%= open_code %>
<%= indent %>class <%= class_name.last %> < Syskit::Composition
<%= indent %>    # Declare an argument to the task. Use :default => VALUE to set up a default
<%= indent %>    # value. The default can be nil
<%= indent %>    # argument :arg[, :default => 1]

<%= indent %>    # Add children to this composition. The relevant files must have
<%= indent %>    # been required already at the top of this file
<%= indent %>    # add A::ProducerTask, :as => 'producer'
<%= indent %>    # add A::ConsumerTask, :as => 'consumer'

<%= indent %>    # Connect ports between the children. On each side of the connection,
<%= indent %>    # either a child or a port can be used. If a child is used, it will
<%= indent %>    # fail if the connection(s) are ambiguous
<%= indent %>    # producer_child.connect_to consumer_child.in_port

<%= indent %>    # Script. This is the recommended way to implement functionality in tasks.
<%= indent %>    # It executes instructions in sequence, in a way that is compatible with
<%= indent %>    # Roby's reactor. For instance, below, block given to 'execute' will only be
<%= indent %>    # executed once the updated event is emitted
<%= indent %>    #
<%= indent %>    # WARNING: the top level of the script is evaluated at loading time.
<%= indent %>    #
<%= indent %>    # See the documentation of Roby::Coordination::Models::TaskScript. The API
<%= indent %>    # calls are the calls available on the script
<%= indent %>    #
<%= indent %>    # script do
<%= indent %>    #   # Waits for an event to be emitted
<%= indent %>    #   wait updated_event
<%= indent %>    #   execute do
<%= indent %>    #     # The code in this block is going to be called at runtime, unlike the
<%= indent %>    #     # code at the script level
<%= indent %>    #   end
<%= indent %>    #   poll do
<%= indent %>    #     # This code is executed at each execution cycle. Call transition!
<%= indent %>    #     # to continue with the next script instruction
<%= indent %>    #   end
<%= indent %>    # end

<%= indent %>    # Declare a new event. This defines updated_event which returns a
<%= indent %>    # Roby::EventGenerator
<%= indent %>    # event :updated

<%= indent %>    # Add forwarding to say "when event X is emitted, event Y should". This is
<%= indent %>    # usually used to make a task finish when an event is emitted
<%= indent %>    # forward :X => :Y
<%= indent %>end
<%= close_code %>
