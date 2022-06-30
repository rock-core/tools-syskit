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
    return unless (@graph = object.syskit.dataflow_graph)

    @graph_type = "dataflow"
    @graph_title = "Dataflow"

    @error = @graph["error"]
    erb(:graph)
end

def hierarchy
    return unless object[:syskit]
    return unless (@graph = object.syskit.hierarchy_graph)

    @graph_type = "hierarchy"
    @graph_title = "Hierarchy"

    @error = @graph["error"]
    erb(:graph)
end
