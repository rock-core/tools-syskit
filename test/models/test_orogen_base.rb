# frozen_string_literal: true

require "syskit/test/self"

module Syskit
    module Models
        describe OrogenBase do
            before do
                model = Module.new do
                    include MetaRuby::ModelAsClass
                    include OrogenBase

                    attr_accessor :orogen_model
                end
                @root_m = Class.new do
                    extend model
                end
            end

            describe "#find_all_models_by_orogen" do
                it "returns an empty array if there are no submodels" do
                    assert_equal [], @root_m.find_all_models_by_orogen(Object.new)
                end

                it "returns the list of submodels that " \
                   "have the provided orogen model" do
                    orogen_model = Object.new
                    a = @root_m.new_submodel
                    b = @root_m.new_submodel
                    @root_m.new_submodel
                    a.orogen_model = b.orogen_model = orogen_model
                    assert_equal [a, b], @root_m.find_all_models_by_orogen(orogen_model)
                end
            end

            describe "#find_model_by_orogen" do
                it "returns nil if there are no matches" do
                    assert_nil @root_m.find_model_by_orogen(Object.new)
                end

                it "returns the first submodel that matches the given orogen model" do
                    orogen_model = Object.new
                    a = @root_m.new_submodel
                    b = @root_m.new_submodel
                    @root_m.new_submodel
                    a.orogen_model = b.orogen_model = orogen_model
                    assert_equal a, @root_m.find_model_by_orogen(orogen_model)
                end
            end

            describe "#model_for" do
                before do
                    @strict_model_for = Syskit.conf.strict_model_for?
                end

                after do
                    Syskit.conf.strict_model_for = @strict_model_for
                end

                describe "without strict_model_for" do
                    before do
                        Syskit.conf.strict_model_for = false
                    end

                    it "raises if there are no matches" do
                        orogen_model = flexmock(name: "orogen::Model")
                        e = assert_raises(ArgumentError) do
                            @root_m.model_for(orogen_model)
                        end
                        assert_equal "there is no Syskit model for orogen::Model",
                                     e.message
                    end

                    it "returns the submodel that matches the given orogen model " \
                       "if only one matches" do
                        orogen_model = flexmock(name: "orogen::Model")
                        @root_m.new_submodel
                        @root_m.new_submodel
                        c = @root_m.new_submodel
                        c.orogen_model = orogen_model
                        assert_equal c, @root_m.model_for(orogen_model)
                    end

                    it "returns the first submodel that matches the given orogen model " \
                       "if there is more than one match" do
                        orogen_model = flexmock(name: "orogen::Model")
                        a = @root_m.new_submodel
                        @root_m.new_submodel
                        c = @root_m.new_submodel
                        a.orogen_model = c.orogen_model = orogen_model
                        assert_equal a, @root_m.model_for(orogen_model)
                    end
                end

                describe "with strict_model_for" do
                    before do
                        Syskit.conf.strict_model_for = true
                    end

                    it "raises if there are no matches" do
                        orogen_model = flexmock(name: "orogen::Model")
                        e = assert_raises(ArgumentError) do
                            @root_m.model_for(orogen_model)
                        end
                        assert_equal "there is no Syskit model for orogen::Model",
                                     e.message
                    end

                    it "returns the submodel that matches the given orogen model " \
                       "if only one matches" do
                        orogen_model = flexmock(name: "orogen::Model")
                        @root_m.new_submodel
                        @root_m.new_submodel
                        c = @root_m.new_submodel
                        c.orogen_model = orogen_model
                        assert_equal c, @root_m.model_for(orogen_model)
                    end

                    it "raises if there is more than one match" do
                        orogen_model = flexmock(name: "orogen::Model")
                        a = @root_m.new_submodel
                        @root_m.new_submodel
                        c = @root_m.new_submodel
                        a.orogen_model = c.orogen_model = orogen_model
                        e = assert_raises(ArgumentError) do
                            @root_m.model_for(orogen_model)
                        end
                        assert_equal "more than one Syskit model matches orogen::Model",
                                     e.message
                    end
                end
            end
        end
    end
end
