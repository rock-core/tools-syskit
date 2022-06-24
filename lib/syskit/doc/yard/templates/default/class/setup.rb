# frozen_string_literal: true

def init
    super
    sections
        .place(:type_definition, :bound_services, :dataflow, :hierarchy)
        .before(:constant_summary)
end

def type_definition
    return unless object[:syskit]
    return unless (@type = object.syskit.type)

    erb(:type_definition)
end

def bound_services
    return unless object[:syskit]
    return unless (@services = object.syskit.bound_services)

    erb(:bound_services)
end

def dataflow
    return unless object[:syskit]
    return unless (@svg = object.syskit.dataflow_graph_path)

    erb(:dataflow)
end

def hierarchy
    return unless object[:syskit]
    return unless (@svg = object.syskit.hierarchy_graph_path)

    erb(:hierarchy)
end
