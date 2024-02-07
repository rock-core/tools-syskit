# frozen_string_literal: true

require "syskit/test/self"
require "syskit/cli/log_runtime_archive_main"

module Syskit
    module CLI
        # Tests CLI command "archive" from syskit/cli/log_runtime_archive_main.rb
        describe CLIArchiveMain do
            it "raises ArgumentError if some of the directories do not exist" do
                root = "make_tmppath"

                e = assert_raises ArgumentError do
                    call_command_line(root, @archive_dir, 1, 10)
                end
                assert_equal "#{root} does not exist, or is not a directory", e.message
            end

            describe "#ensure_free_space" do
                before do
                    @root = make_tmppath
                    @archive_dir = make_tmppath
                    @mocked_files_sizes = []

                    5.times { |i| (@archive_dir / i.to_s).write(i.to_s) }

                    @archiver = LogRuntimeArchive.new(@root, @archive_dir)
                end

                it "does nothing if there is enough free space" do
                    mock_available_space(200)
                    call_command_line(@root, @archive_dir, 100, 300) # 100 MB, 300 MB

                    assert_deleted_files([])
                end

                it "removes enough files to reach the freed limit" do
                    size_files = [75, 40, 90, 60, 70]
                    mock_files_size(size_files)
                    mock_available_space(70) # 70 MB

                    call_command_line(@root, @archive_dir, 100, 300) # 100 MB, 300 MB
                    assert_deleted_files([0, 1, 2, 3])
                end

                it "stops removing files when there is no file in folder even if freed
                    limit is not achieved" do
                    size_files = Array.new(5, 10)
                    mock_files_size(size_files)
                    mock_available_space(80) # 80 MB

                    call_command_line(@root, @archive_dir, 100, 300) # 100 MB, 300 MB
                    assert_deleted_files([0, 1, 2, 3, 4])
                end

                # Mock files sizes in bytes
                # @param [Array] size of files in MB
                def mock_files_size(sizes)
                    @mocked_files_sizes = sizes
                    @mocked_files_sizes.each_with_index do |size, i|
                        (@archive_dir / i.to_s).write(" " * size * 1e6)
                    end
                end

                # Mock total disk available space in bytes
                # @param [Float] total_available_disk_space total available space in MB
                def mock_available_space(total_available_disk_space)
                    flexmock(Sys::Filesystem)
                        .should_receive(:stat).with(@archive_dir)
                        .and_return do
                            flexmock(
                                bytes_free: total_available_disk_space * 1e6
                            )
                        end
                end

                def assert_deleted_files(deleted_files) # rubocop:disable Metrics/AbcSize
                    if deleted_files.empty?
                        files = @archive_dir.each_child.select(&:file?)
                        assert_equal 5, files.size
                    else
                        (0..4).each do |i|
                            if deleted_files.include?(i)
                                refute (@archive_dir / i.to_s).exist?,
                                       "#{i} was expected to be deleted, but has not been"
                            else
                                assert (@archive_dir / i.to_s).exist?,
                                       "#{i} was expected to be present, but got deleted"
                            end
                        end
                    end
                end
            end

            # Call 'archive' function instead of 'watch' to call archiver once
            def call_command_line(root_path, archive_path, low_limit, freed_limit)
                Syskit::CLI::CLIArchiveMain.start(
                    ["archive", root_path, archive_path,
                     "--free-space-low-limit", low_limit,
                     "--free-space-freed-limit", freed_limit]
                )
            end
        end
    end
end
