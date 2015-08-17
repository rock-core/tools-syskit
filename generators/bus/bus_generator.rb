require 'roby/app/gen'
class BusGenerator < Roby::App::GenModelClass
    def initialize(runtime_args, runtime_options = Hash.new)
        @model_type = ['devices', 'bus']
        super
    end

    def has_test?; true end
end

