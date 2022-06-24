# frozen_string_literal: true

def init
    super
    sections.place(:ports, :provided_services, :interface).before(:constant_summary)
end

def provided_services
    return unless object[:syskit]
    return unless (@services = object.syskit.provided_services)

    erb(:provided_services)
end

def ports
    return unless object[:syskit]
    return unless (@ports = object.syskit.ports)

    erb(:ports)
end

def interface
    return unless object[:syskit]
    return unless (@svg = object.syskit.interface_graph_path)

    erb(:interface)
end
