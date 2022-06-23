# frozen_string_literal: true

def init
    super
    sections.place(:graphs).after(:header)
end

def graphs
    return unless object[:syskit]
    return unless (@graphs = object.syskit.graphs)
    return if @graphs.empty?

    erb(:graphs)
end
