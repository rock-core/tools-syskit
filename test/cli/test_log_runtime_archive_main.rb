# frozen_string_literal: true

require "syskit/test/self"
require "syskit/cli/log_runtime_archive_main"

module Syskit
    module CLI
        describe LogRuntimeArchiveMain do
            before do
                @archive_dir = make_tmppath
                @mocked_files_sizes = []

                10.times do |i|
                    ("/dev/tools/syskit/tmp/datasets" / i.to_s).write(i.to_s)
                end

                @archiver = LogRuntimeArchiveMain.new(
                    "/dev/tools/syskit/tmp/datasets",
                    "/dev/tools/syskit/tmp/archive"
                )
            end

            it "test cli" do
                size_files = [6, 2, 1, 6, 7, 10, 3, 5, 8, 9]
                mock_files_size(size_files)
                mock_available_space(0.5)

                call_command_line(@root, @archive_dir, 1e-3, 10 * 1e-3)
                assert_deleted_files([0, 1, 2, 3])
            end

            def mock_files_size(sizes)
                @mocked_files_sizes = sizes
                @mocked_files_sizes.each_with_index do |size, i|
                    (@archive_dir / i.to_s).write(" " * size)
                end
            end

            def mock_available_space(total_disk_size)
                flexmock(Sys::Filesystem)
                    .should_receive(:stat).with(@archive_dir)
                    .and_return do
                        flexmock(
                            bytes_free: total_disk_size
                        )
                    end
            end

            def assert_deleted_files(deleted_files) # rubocop:disable Metrics/AbcSize
                if deleted_files.empty?
                    files = @archive_dir.each_child.select(&:file?)
                    assert_equal 10, files.size
                else
                    (0..9).each do |i|
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
