# frozen_string_literal: true

require "syskit/test/self"
require "syskit/cli/log_runtime_archive_main"
require "syskit/roby_app/tmp_root_ca"

module Syskit
    module CLI
        # Tests CLI command "archive" from syskit/cli/log_runtime_archive_main.rb
        describe LogRuntimeArchiveMain do
            describe "#watch" do
                before do
                    @root = make_tmppath
                    @archive_dir = make_tmppath

                    @mocked_files_sizes = []
                    5.times { |i| (@archive_dir / i.to_s).write(i.to_s) }
                end

                it "calls archive with the specified period" do
                    mock_files_size([])
                    mock_available_space(200) # 70 MB

                    quit = Class.new(RuntimeError)
                    called = 0
                    flexmock(LogRuntimeArchive)
                        .new_instances
                        .should_receive(:process_root_folder)
                        .pass_thru do
                            called += 1
                            raise quit if called == 3
                        end

                    tic = Time.now
                    assert_raises(quit) do
                        LogRuntimeArchiveMain.start(
                            ["watch", @root, @archive_dir, "--period", 0.5]
                        )
                    end

                    assert called == 3
                    assert_operator(Time.now - tic, :>, 0.9)
                end

                it "retries on ENOSPC" do
                    mock_files_size([])
                    mock_available_space(200) # 70 MB

                    quit = Class.new(RuntimeError)
                    called = 0
                    flexmock(LogRuntimeArchive)
                        .new_instances
                        .should_receive(:process_root_folder)
                        .pass_thru do
                            called += 1
                            raise quit if called == 3

                            raise Errno::ENOSPC
                        end

                    tic = Time.now
                    assert_raises(quit) do
                        LogRuntimeArchiveMain.start(
                            ["watch", @root, @archive_dir, "--period", 0.5]
                        )
                    end
                    assert_operator(Time.now - tic, :<, 1)
                end
            end

            describe "#archive" do
                before do
                    @root = make_tmppath
                    @archive_dir = make_tmppath
                    @mocked_files_sizes = []

                    5.times { |i| (@archive_dir / i.to_s).write(i.to_s) }
                end

                it "raises ArgumentError if the source directory does not exist" do
                    e = assert_raises ArgumentError do
                        call_archive("/does/not/exist", @archive_dir, 1, 10)
                    end
                    assert_equal "/does/not/exist does not exist, or is not a directory",
                                 e.message
                end

                it "raises ArgumentError if the target directory does not exist" do
                    e = assert_raises ArgumentError do
                        call_archive(@root, "/does/not/exist", 1, 10)
                    end
                    assert_equal "/does/not/exist does not exist, or is not a directory",
                                 e.message
                end

                it "does nothing if there is enough free space" do
                    mock_available_space(200)
                    call_archive(@root, @archive_dir, 100, 300) # 100 MB, 300 MB

                    assert_deleted_files([])
                end

                it "removes enough files to reach the freed limit" do
                    size_files = [75, 40, 90, 60, 70]
                    mock_files_size(size_files)
                    mock_available_space(70) # 70 MB

                    call_archive(@root, @archive_dir, 100, 300) # 100 MB, 300 MB
                    assert_deleted_files([0, 1, 2, 3])
                end

                it "stops removing files when there is no file in folder even if freed
                    limit is not achieved" do
                    size_files = Array.new(5, 10)
                    mock_files_size(size_files)
                    mock_available_space(80) # 80 MB

                    call_archive(@root, @archive_dir, 100, 300) # 100 MB, 300 MB
                    assert_deleted_files([0, 1, 2, 3, 4])
                end

                # Call 'archive' function instead of 'watch' to call archiver once
                def call_archive(root_path, archive_path, low_limit, freed_limit)
                    LogRuntimeArchiveMain.start(
                        ["archive", root_path, archive_path,
                         "--free-space-low-limit", low_limit,
                         "--free-space-freed-limit", freed_limit]
                    )
                end
            end

            describe "#transfer_server" do
                before do
                    @server_params = server_params
                    @server = call_create_server(make_tmppath, @server_params)
                end

                after do
                    @server.stop
                    @server.join
                end

                it "successfully creates an FTP server" do
                    Net::FTP.open(
                        @server_params[:host],
                        port: @server.port,
                        implicit_ftps: @server_params[:implicit_ftps],
                        ssl: { verify_mode: OpenSSL::SSL::VERIFY_NONE }
                    ) do |ftp|
                        ftp.login(@server_params[:user], @server_params[:password])
                    end
                end
            end

            describe "#watch_transfer" do
                before do
                    @source_dir = make_tmppath
                    @server_params = server_params
                    @max_upload_rate = rate_mbps_to_bps(10)
                    @ftp_params = LogRuntimeArchive::FTPParameters.new(
                        host: @server_params[:host], port: @server_params[:port],
                        certificate: File.read(@server_params[:certificate]),
                        user: @server_params[:user], password: @server_params[:password],
                        implicit_ftps: @server_params[:implicit_ftps],
                        max_upload_rate: @max_upload_rate
                    )

                    @server = call_create_server(make_tmppath, @server_params)
                end

                after do
                    @server.stop
                    @server.join
                end

                it "calls transfer with the specified period" do
                    quit = Class.new(RuntimeError)
                    called = 0
                    flexmock(LogRuntimeArchive)
                        .new_instances
                        .should_receive(:process_root_folder_transfer)
                        .with(
                            @ftp_params
                        )
                        .pass_thru do
                            called += 1
                            raise quit if called == 3
                        end

                    tic = Time.now
                    assert_raises(quit) do
                        updated_server_params = @server_params
                        implicit_ftps_arg =
                            if updated_server_params[:implicit_ftps]
                                "--implicit_ftps"
                            else
                                "--no-implicit_ftps"
                            end
                        updated_server_params.delete(:implicit_ftps)
                        args = [
                            "watch_transfer",
                            @source_dir,
                            *updated_server_params.values,
                            "--period", 0.5,
                            "--max_upload_rate_mbps", 10,
                            implicit_ftps_arg
                        ]
                        LogRuntimeArchiveMain.start(args)
                    end

                    assert called == 3
                    assert_operator(Time.now - tic, :>, 0.9)
                end

                # Converts rate in Mbps to bps
                def rate_mbps_to_bps(rate_mbps)
                    rate_mbps * (10**6)
                end
            end

            describe "#transfer" do
                before do
                    @server_params = server_params
                end

                it "raises ArgumentError if source_dir does not exist" do
                    e = assert_raises ArgumentError do
                        call_transfer("/does/not/exist")
                    end
                    assert_equal "/does/not/exist does not exist, or is not a directory",
                                 e.message
                end

                it "actually transfer files" do
                    dataset_tmp_path = make_tmppath
                    root_tmp_path = make_tmppath

                    server = call_create_server(root_tmp_path, @server_params)

                    dataset_a = make_dataset(dataset_tmp_path, "19981222-1301")
                    dataset_b = make_dataset(dataset_tmp_path, "19981222-1302")

                    flexmock(Roby::Application)
                        .should_receive(:log_dir_locked?)
                        .with(dataset_a.basename)
                        .and_return(false)
                    flexmock(Roby::Application)
                        .should_receive(:log_dir_locked?)
                        .with(dataset_b.basename)
                        .and_return(true)

                    call_transfer(dataset_tmp_path, server_port: server.port)
                    assert(File.exist?(root_tmp_path / "19981222-1301" / "test.0.log"))
                end

                # Call 'transfer' function instead of 'watch' to call transfer once
                def call_transfer(source_dir, server_port: nil)
                    updated_server_params = @server_params
                    implicit_ftps_arg =
                        if updated_server_params[:implicit_ftps]
                            "--implicit_ftps"
                        else
                            "--no-implicit_ftps"
                        end
                    updated_server_params.delete(:implicit_ftps)
                    updated_server_params[:port] = server_port if server_port
                    args = [
                        "transfer",
                        source_dir,
                        *updated_server_params.values,
                        implicit_ftps_arg
                    ]
                    LogRuntimeArchiveMain.start(args)
                end

                def make_dataset(path, name)
                    dataset = (path / name)
                    dataset.mkpath
                    FileUtils.touch(dataset / "info.yml")
                    make_random_file("test.0.log", root: dataset)
                    dataset
                end

                def make_random_file(name, root: @root, size: 1024)
                    content = Base64.encode64(Random.bytes(size))
                    make_in_file name, content, root: root
                    content
                end

                def make_in_file(name, content, root: @root)
                    path = (root / name)
                    path.write(content)
                    [] << path
                    path
                end
            end

            describe "#ensure_free_space" do
                before do
                    @directory = make_tmppath
                    @sub_directory = Pathname.new(@directory / "subdir")
                    @sub_directory2 = Pathname.new(@directory / "subdir_2")
                    @sub_directory.mkdir unless @sub_directory.exist?
                    @sub_directory2.mkdir unless @sub_directory2.exist?
                    @mocked_files_sizes = []

                    10.times { |i| (@sub_directory / i.to_s).write(i.to_s) }
                    10.times { |i| (@sub_directory2 / i.to_s).write(i.to_s) }

                    @archiver = LogRuntimeArchive.new(@directory)
                end

                it "removes enough files to reach the freed limit" do
                    size_files = [6, 2, 1, 6, 7, 10, 3, 5, 8, 9]
                    mock_files_size(size_files, directory: @sub_directory)
                    mock_files_size(size_files, directory: @sub_directory2)
                    mock_available_space(0, directory: @sub_directory)
                    mock_available_space(100.5, directory: @sub_directory2)
                    mock_mtime(directory: @sub_directory)
                    mock_mtime(directory: @sub_directory2)
                    mock_mtime(directory: @directory)

                    call_ensure_free_space(@directory, 101, 110)
                    assert_deleted_files(
                        [0, 1, 2, 3, 4, 5, 6, 7, 8, 9], directory: @sub_directory
                    )
                    assert_deleted_files([0, 1, 2, 3], directory: @sub_directory2)
                end

                it "removes from directories based on modification time" do
                    size_files = [6, 2, 1, 6, 7, 10, 3, 5, 8, 9]
                    mock_files_size(size_files, directory: @sub_directory)
                    mock_files_size(size_files, directory: @sub_directory2)
                    mock_available_space(0.5, directory: @sub_directory)
                    mock_available_space(0.5, directory: @sub_directory2)
                    mock_mtime(directory: @sub_directory)
                    mock_mtime(directory: @sub_directory2)
                    mock_mtime(directory: @directory, reverse_alphabetical: true)

                    call_ensure_free_space(@directory, 1, 10)
                    assert_deleted_files([0, 1, 2, 3], directory: @sub_directory2)
                    # Does not delete any file from newest directory
                    assert_equal 10, @sub_directory.each_child.select(&:file?).size
                end

                def call_ensure_free_space(source_dir, low_limit, freed_limit)
                    args = [
                        "ensure_free_space",
                        source_dir,
                        "--free-space-low-limit", low_limit,
                        "--free-space-freed-limit", freed_limit
                    ]
                    LogRuntimeArchiveMain.start(args)
                end
            end

            describe "#watch_ensure_free_space" do
                before do
                    @directory = make_tmppath
                    @sub_directory = Pathname.new(@directory / "subdir")
                    @sub_directory.mkdir unless @sub_directory.exist?

                    @mocked_files_sizes = []
                    5.times { |i| (@sub_directory / i.to_s).write(i.to_s) }
                end

                it "calls ensure free space with the specified period" do
                    mock_files_size([], directory: @sub_directory)
                    mock_available_space(200, directory: @sub_directory) # 70 MB

                    quit = Class.new(RuntimeError)
                    called = 0
                    flexmock(LogRuntimeArchive)
                        .new_instances
                        .should_receive(:ensure_free_space)
                        .pass_thru do
                            called += 1
                            raise quit if called == 3
                        end

                    tic = Time.now
                    assert_raises(quit) do
                        LogRuntimeArchiveMain.start(
                            ["watch_ensure_free_space", @directory, "--period", 0.5]
                        )
                    end

                    assert called == 3
                    assert_operator(Time.now - tic, :>, 0.9)
                end
            end

            def call_create_server(tgt_dir, server_params)
                cli = LogRuntimeArchiveMain.new
                cli.create_server(tgt_dir, *server_params.values)
            end

            def server_params
                interface = "127.0.0.1"
                ca = RobyApp::TmpRootCA.new(interface)

                { host: interface, port: 0,
                  certificate: ca.private_certificate_path,
                  user: "nilvo", password: "nilvo123",
                  implicit_ftps: true }
            end

            # Mock files sizes in bytes
            # @param [Array] size of files in MB
            def mock_files_size(sizes, directory: @archive_dir)
                @mocked_files_sizes = sizes
                @mocked_files_sizes.each_with_index do |size, i|
                    (directory / i.to_s).write(" " * size * 1e6)
                end
            end

            # Mock total disk available space in bytes
            # @param [Float] total_available_disk_space total available space in MB
            def mock_available_space(total_available_disk_space, directory: @archive_dir)
                flexmock(Sys::Filesystem)
                    .should_receive(:stat).with(directory)
                    .and_return do
                        flexmock(
                            bytes_available: total_available_disk_space * 1e6
                        )
                    end
            end

            # Mock the modification time of the files to be alphabetical order
            # @param [String] directory the directory to mock the items modification time
            # @param [Bool] reverse_alphabetical true if use reverse alphabetical order
            def mock_mtime(directory: @archive_dir, reverse_alphabetical: false)
                items = directory.children
                                 .select { |child| child.file? || child.directory? }

                items = items.sort_by(&:to_s)
                items = items.reverse if reverse_alphabetical
                items.each_with_index do |item, i|
                    File.utime(i, i, item.to_s)
                end
            end

            def assert_deleted_files(deleted_files, directory: @archive_dir)
                if deleted_files.empty?
                    files = directory.each_child.select(&:file?)
                    assert_equal 5, files.size
                else
                    (0..4).each do |i|
                        if deleted_files.include?(i)
                            refute (directory / i.to_s).exist?,
                                   "#{i} was expected to be deleted, but has not been"
                        else
                            assert (directory / i.to_s).exist?,
                                   "#{i} was expected to be present, but got deleted"
                        end
                    end
                end
            end
        end
    end
end
