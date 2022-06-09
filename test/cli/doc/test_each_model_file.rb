# frozen_string_literal: true

require "syskit/test/self"
require "syskit/cli/doc/each_model_file"

module Syskit
    module CLI
        module Doc
            describe "model file enumeration" do
                before do
                    @root_path = make_tmppath

                    @paths = [
                        @root_path / "models" / "a",
                        @root_path / "models" / "gazebo" / "b",
                        @root_path / "models" / "live" / "c"
                    ]

                    @paths.each(&:mkpath)
                end

                describe "each_model_file_for_robot" do
                    it "lists the ruby files in matching folders" do
                        (@root_path / "models" / "models.rb").write("")
                        (@root_path / "models" / "a" / "a.rb").write("")
                        (@root_path / "models" / "gazebo" / "gazebo.rb").write("")
                        (@root_path / "models" / "live" / "live.rb").write("")

                        robots = flexmock
                        robots.should_receive(:has_robot?).with("gazebo").and_return(true)
                        robots.should_receive(:has_robot?).with("live").and_return(true)
                        robots.should_receive(:has_robot?).and_return(false)
                        result = Doc.each_model_file_for_robot(
                            @root_path, %w[default gazebo], robots: robots
                        ).to_set

                        expected = [
                            @root_path / "models" / "models.rb",
                            @root_path / "models" / "a" / "a.rb",
                            @root_path / "models" / "gazebo" / "gazebo.rb"
                        ]

                        assert_equal expected.to_set, result
                    end
                end

                describe "each_model_path_for_robot" do
                    it "lists non-specific folders and specific ones if "\
                       "'default' is in the names" do
                        robots = flexmock
                        robots.should_receive(:has_robot?).with("gazebo").and_return(true)
                        robots.should_receive(:has_robot?).with("live").and_return(true)
                        robots.should_receive(:has_robot?).and_return(false)
                        result = Doc.each_model_path_for_robot(
                            @root_path, %w[default gazebo], robots: robots
                        ).to_set

                        expected = [
                            @root_path / "models",
                            @root_path / "models" / "a",
                            @root_path / "models" / "gazebo",
                            @root_path / "models" / "gazebo" / "b"
                        ]

                        assert_equal expected.to_set, result
                    end

                    it "skips non-specific folders if 'default' is not in the names" do
                        robots = flexmock
                        robots.should_receive(:has_robot?).with("gazebo").and_return(true)
                        robots.should_receive(:has_robot?).with("live").and_return(true)
                        robots.should_receive(:has_robot?).and_return(false)
                        result = Doc.each_model_path_for_robot(
                            @root_path, %w[gazebo], robots: robots
                        ).to_set

                        expected = [
                            @root_path / "models" / "gazebo",
                            @root_path / "models" / "gazebo" / "b"
                        ]

                        assert_equal expected.to_set, result
                    end
                end

                describe "each_model_path" do
                    it "lists all non-specific folders as 'default'" do
                        robots = flexmock(has_robot?: false)
                        result = Doc.each_model_path(@root_path, robots: robots).to_set

                        expected = [
                            @root_path / "models",
                            @root_path / "models" / "a",
                            @root_path / "models" / "gazebo",
                            @root_path / "models" / "gazebo" / "b",
                            @root_path / "models" / "live",
                            @root_path / "models" / "live" / "c"
                        ]

                        assert_equal expected.map { |p| [p, "default"] }.to_set, result
                    end

                    it "correctly marks specific folders and their subfolders" do
                        robots = flexmock
                        robots.should_receive(:has_robot?).with("gazebo").and_return(true)
                        robots.should_receive(:has_robot?).with("live").and_return(true)
                        robots.should_receive(:has_robot?).and_return(false)
                        result = Doc.each_model_path(@root_path, robots: robots).to_set

                        expected = [
                            [@root_path / "models", "default"],
                            [@root_path / "models" / "a", "default"],
                            [@root_path / "models" / "gazebo", "gazebo"],
                            [@root_path / "models" / "gazebo" / "b", "gazebo"],
                            [@root_path / "models" / "live", "live"],
                            [@root_path / "models" / "live" / "c", "live"]
                        ]

                        assert_equal expected.to_set, result
                    end

                    it "does not discover some subfolders if pruned" do
                        robots = flexmock
                        robots.should_receive(:has_robot?).with("gazebo").and_return(true)
                        robots.should_receive(:has_robot?).with("live").and_return(true)
                        robots.should_receive(:has_robot?).and_return(false)
                        result = Set.new
                        Doc.each_model_path(@root_path, robots: robots).each do |p, r|
                            result << [p, r]
                            Doc.prune if r == "gazebo"
                        end

                        expected = [
                            [@root_path / "models", "default"],
                            [@root_path / "models" / "a", "default"],
                            [@root_path / "models" / "gazebo", "gazebo"],
                            [@root_path / "models" / "live", "live"],
                            [@root_path / "models" / "live" / "c", "live"]
                        ]

                        assert_equal expected.to_set, result
                    end
                end
            end
        end
    end
end
