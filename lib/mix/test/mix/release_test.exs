Code.require_file("../test_helper.exs", __DIR__)

defmodule Mix.ReleaseTest do
  use MixTest.Case

  import Mix.Release
  doctest Mix.Release

  Application.ensure_loaded(:eex)
  Application.ensure_loaded(:runtime_tools)

  @erts_version :erlang.system_info(:version)
  @erts_source Path.join(:code.root_dir(), "erts-#{@erts_version}")
  @elixir_version Application.spec(:elixir, :vsn)
  @kernel_version Application.spec(:kernel, :vsn)
  @runtime_tools_version Application.spec(:runtime_tools, :vsn)
  @eex_ebin Application.app_dir(:eex, "ebin")

  setup_all do
    Mix.ensure_application!(:sasl)
    Mix.ensure_application!(:crypto)
    :ok
  end

  setup do
    File.rm_rf!(tmp_path("mix_release"))
    File.mkdir_p!(tmp_path("mix_release"))
    :ok
  end

  describe "from_config!/3" do
    test "uses default configuration if no release is specified" do
      assert %Mix.Release{
               name: :mix,
               version: "0.1.0",
               path: path,
               version_path: version_path
             } = from_config!(nil, config(), [])

      assert String.ends_with?(path, "mix_release/_build/dev/rel/mix")
      assert String.ends_with?(version_path, "mix_release/_build/dev/rel/mix/releases/0.1.0")
    end

    test "provides default options" do
      release = from_config!(nil, config(), [])
      assert release.options == [overwrite: false, quiet: false, strip_beams: true]
    end

    test "allows overrides" do
      overrides = [path: "demo", version: "0.2.0", overwrite: true, quiet: true]
      release = from_config!(nil, config(), overrides)

      assert release.path == Path.absname("demo")
      assert release.version == "0.2.0"
      assert release.options[:overwrite]
      assert release.options[:quiet]
    end

    test "allows specifying the version from an application" do
      overrides = [version: {:from_app, :elixir}]
      release = from_config!(nil, config(), overrides)

      assert release.version == to_string(Application.spec(:elixir, :vsn))
    end

    test "raises when :from_app is used with an app that doesn't exist" do
      overrides = [version: {:from_app, :not_valid}]

      assert_raise Mix.Error,
                   ~r"Could not find version for :not_valid, please make sure the application exists",
                   fn -> from_config!(nil, config(), overrides) end
    end

    test "includes applications" do
      release = from_config!(nil, config(), [])
      assert release.applications.mix[:path] == to_charlist(Application.app_dir(:mix))
      refute release.applications.mix[:otp_app?]

      assert release.applications.kernel[:path] == to_charlist(Application.app_dir(:kernel))
      assert release.applications.kernel[:otp_app?]
    end

    test "does not include erts in applications" do
      release = from_config!(nil, config(releases: [foo: [applications: [erts: :permanent]]]), [])
      assert release.applications[:erts] == nil
    end

    test "allows release to be given as an anonymous function" do
      release = from_config!(:foo, config(releases: [foo: fn -> [version: "0.2.0"] end]), [])
      assert release.name == :foo
      assert release.version == "0.2.0"
    end

    test "uses chosen release via the CLI" do
      release =
        from_config!(
          :bar,
          config(releases: [foo: [version: "0.2.0"], bar: [version: "0.3.0"]]),
          []
        )

      assert release.name == :bar
      assert release.version == "0.3.0"
      assert String.ends_with?(release.path, "mix_release/_build/dev/rel/bar")

      assert String.ends_with?(
               release.version_path,
               "mix_release/_build/dev/rel/bar/releases/0.3.0"
             )
    end

    test "uses chosen release via the default_release" do
      release =
        from_config!(
          nil,
          config(
            default_release: :bar,
            releases: [foo: [version: "0.2.0"], bar: [version: "0.3.0"]]
          ),
          []
        )

      assert release.name == :bar
      assert release.version == "0.3.0"
      assert String.ends_with?(release.path, "mix_release/_build/dev/rel/bar")

      assert String.ends_with?(
               release.version_path,
               "mix_release/_build/dev/rel/bar/releases/0.3.0"
             )
    end

    test "raises for multiple releases and no name" do
      assert_raise Mix.Error,
                   ~r"\"mix release\" was invoked without a name but there are multiple releases",
                   fn -> from_config!(nil, config(releases: [foo: [], bar: []]), []) end
    end

    test "raises for unknown release" do
      assert_raise Mix.Error, "Unknown release :foo. The available releases are: []", fn ->
        from_config!(:foo, config(), [])
      end
    end

    test "uses the locked version of an app", context do
      in_tmp(context.test, fn ->
        # install newer version of the app in the custom ERTS
        custom_erts_path = Path.join([File.cwd!(), "erts-#{@erts_version}"])
        File.cp_r!(@erts_source, custom_erts_path)

        ebin_dir = Path.expand(Path.join([custom_erts_path, "..", "lib", "cowboy-2.0.0", "ebin"]))
        File.mkdir_p!(ebin_dir)
        app_resource = "{application,cowboy,[{vsn,\"2.0.0\"},{modules,[]},{applications,[]}]}."
        File.write!(Path.join(ebin_dir, "cowboy.app"), app_resource)

        # install older version of the app in the project dependencies
        project_path = Path.join(File.cwd!(), "project")
        build_path = Path.join(project_path, "_build")
        ebin_dir = Path.join([build_path, "dev", "lib", "cowboy", "ebin"])
        File.mkdir_p!(ebin_dir)
        app_resource = "{application,cowboy,[{vsn,\"1.1.2\"},{modules,[]},{applications,[]}]}."
        File.write!(Path.join(ebin_dir, "cowboy.app"), app_resource)

        File.mkdir_p!(Path.join([project_path, "deps", "cowboy"]))
        lockfile = Path.join(project_path, "mix.lock")

        File.write!(lockfile, ~S"""
        %{
          "cowboy": {:hex, :cowboy, "1.1.2"},
        }
        """)

        app_config =
          config(
            deps: [{:cowboy, "~> 1.0", path: "deps/cowvoy"}],
            releases: [demo: [include_erts: custom_erts_path, applications: [cowboy: :permanent]]]
          )

        Mix.Project.in_project(:mix, project_path, app_config, fn _ ->
          Code.prepend_path(ebin_dir)
          release = from_config!(nil, app_config, [])
          assert release.applications.cowboy[:vsn] == ~c"1.1.2"
        end)
      end)
    end

    test "uses the latest version of an app if it is not locked", context do
      in_tmp(context.test, fn ->
        test_erts_dir = Path.join(File.cwd!(), "erts-#{@erts_version}")
        test_libs_dir = Path.join(File.cwd!(), "lib")
        libs_dir = Path.join(:code.root_dir(), "lib")
        libs = File.ls!(libs_dir)

        File.cp_r!(@erts_source, test_erts_dir)

        for lib <- libs,
            source_file <- Path.wildcard(Path.join([libs_dir, lib, "ebin", "*.app"])) do
          target_dir = Path.join([test_libs_dir, lib, "ebin"])
          target_file = Path.join(target_dir, Path.basename(source_file))

          File.mkdir_p!(target_dir)
          File.cp!(source_file, target_file)
        end

        File.mkdir_p!(Path.join("lib", "compiler-1.0"))

        release = from_config!(nil, config(releases: [demo: [include_erts: test_erts_dir]]), [])

        assert Path.dirname(release.applications.compiler[:path]) == test_libs_dir
        assert release.applications.compiler[:vsn] != "1.0"
      end)
    end

    test "raises on unknown app" do
      assert_raise Mix.Error, "Could not find application :unknown", fn ->
        from_config!(nil, config(releases: [demo: [applications: [unknown: :none]]]), [])
      end
    end

    test "raises for missing version" do
      assert_raise Mix.Error, ~r"No :version found", fn ->
        from_config!(nil, config() |> Keyword.drop([:version]), [])
      end
    end

    test "raises for blank version" do
      assert_raise Mix.Error, ~r"The release :version cannot be an empty string", fn ->
        from_config!(nil, config(version: ""), [])
      end
    end

    test "raises on invalid release names" do
      assert_raise Mix.Error, ~r"Invalid release name", fn ->
        from_config!(nil, config(releases: ["invalid name": []]), [])
      end
    end

    test "raises on bad steps" do
      assert_raise Mix.Error,
                   ~r"The :steps option must be",
                   fn -> release(steps: :foo) end

      assert_raise Mix.Error,
                   ~r"The :steps option must contain the atom :assemble once, got: \[\]",
                   fn -> release(steps: []) end

      assert_raise Mix.Error,
                   ~r"The :steps option must contain the atom :assemble once",
                   fn -> release(steps: [:assemble, :assemble]) end

      assert_raise Mix.Error,
                   ~r"The :tar step must come after :assemble",
                   fn -> release(steps: [:tar, :assemble]) end

      assert_raise Mix.Error,
                   ~r"The :steps option can only contain the atom :tar once",
                   fn -> release(steps: [:assemble, :tar, :tar]) end

      assert_raise Mix.Error,
                   ~r"The :steps option must be",
                   fn -> release(steps: [:foo]) end
    end
  end

  describe "from_config!/3 + umbrella" do
    test "cannot infer for umbrella projects" do
      assert_raise Mix.Error,
                   ~r"Umbrella projects require releases to be explicitly defined",
                   fn -> from_config!(nil, config(apps_path: "apps"), []) end
    end

    test "requires apps for umbrella projects" do
      assert_raise Mix.Error,
                   ~r"Umbrella projects require releases to be explicitly defined",
                   fn -> from_config!(nil, config(apps_path: "apps", releases: [foo: []]), []) end
    end

    test "builds explicit releases with applications" do
      config = config(apps_path: "apps", releases: [foo: [applications: [mix: :permanent]]])

      assert %Mix.Release{
               name: :foo,
               version: "0.1.0",
               path: _path,
               version_path: _version_path
             } = from_config!(nil, config, [])
    end
  end

  describe "from_config!/3 + boot_scripts" do
    test "generates a start boot script with current application" do
      release = release([])

      assert release.boot_scripts.start == [
               kernel: :permanent,
               stdlib: :permanent,
               elixir: :permanent,
               sasl: :permanent,
               mix: :permanent,
               iex: :none,
               compiler: :permanent
             ]
    end

    test "includes extra application in order" do
      # Current app is always last
      release = release(applications: [eex: :permanent])

      assert release.boot_scripts.start == [
               kernel: :permanent,
               stdlib: :permanent,
               elixir: :permanent,
               sasl: :permanent,
               eex: :permanent,
               mix: :permanent,
               iex: :none,
               compiler: :permanent
             ]

      # Unless explicitly given
      release = release(applications: [mix: :permanent, eex: :permanent])

      assert release.boot_scripts.start == [
               kernel: :permanent,
               stdlib: :permanent,
               elixir: :permanent,
               sasl: :permanent,
               mix: :permanent,
               eex: :permanent,
               iex: :none,
               compiler: :permanent
             ]
    end

    test "configures other applications" do
      release = release(applications: [mix: :temporary])
      assert release.boot_scripts.start[:mix] == :temporary

      release = release(applications: [iex: :temporary])
      assert release.boot_scripts.start[:iex] == :temporary
    end

    test "configures other applications in cascade", context do
      in_tmp(context.test, fn ->
        write_app!(
          "my_sample_mode/ebin/my_sample_mode.app",
          {:application, :my_sample_mode,
           applications: [:kernel, :stdlib, :elixir, :runtime_tools, :compiler],
           description: ~c"my_sample_mode",
           modules: [],
           vsn: ~c"1.0.0"}
        )

        apps = [my_sample_mode: :temporary]
        release = release(applications: apps)
        assert release.boot_scripts.start[:my_sample_mode] == :temporary
        assert release.boot_scripts.start[:runtime_tools] == :temporary
        assert release.boot_scripts.start[:compiler] == :permanent

        apps = [my_sample_mode: :temporary, elixir: :permanent]
        release = release(applications: apps)
        assert release.boot_scripts.start[:my_sample_mode] == :temporary
        assert release.boot_scripts.start[:runtime_tools] == :temporary
        assert release.boot_scripts.start[:compiler] == :permanent

        apps = [my_sample_mode: :temporary, runtime_tools: :none, compiler: :none]
        release = release(applications: apps)
        assert release.boot_scripts.start[:my_sample_mode] == :temporary
        assert release.boot_scripts.start[:runtime_tools] == :none
        assert release.boot_scripts.start[:compiler] == :none

        apps = [my_sample_mode: :temporary, elixir: :permanent, compiler: :none]
        release = release(applications: apps)
        assert release.boot_scripts.start[:my_sample_mode] == :temporary
        assert release.boot_scripts.start[:runtime_tools] == :temporary
        assert release.boot_scripts.start[:compiler] == :none
      end)
    end

    test "generates a start_clean script with only kernel and stdlib starting up" do
      release = release([])

      assert release.boot_scripts.start_clean == [
               kernel: :permanent,
               stdlib: :permanent,
               elixir: :load,
               sasl: :load,
               mix: :load,
               iex: :none,
               compiler: :load
             ]
    end
  end

  describe "from_config!/3 + include_erts" do
    test "when true (default)" do
      release = release([])
      assert release.erts_version == @erts_version
      assert release.erts_source == to_charlist(@erts_source)
    end

    test "when false" do
      release = release(include_erts: false)
      assert release.erts_version == @erts_version
      assert release.erts_source == nil
    end

    test "when anonymous function" do
      release = release(include_erts: fn -> true end)
      assert release.erts_version == @erts_version
      assert release.erts_source == to_charlist(@erts_source)

      release = release(include_erts: fn -> false end)
      assert release.erts_version == @erts_version
      assert release.erts_source == nil
    end

    test "with valid path" do
      release = release(include_erts: @erts_source)
      assert release.erts_version == @erts_version
      assert release.erts_source == to_charlist(@erts_source)
    end

    test "with invalid path" do
      assert_raise Mix.Error, "Could not find ERTS system at \"bad\"", fn ->
        release(include_erts: "bad")
      end
    end
  end

  describe "make_boot_script/4" do
    @boot_script_path tmp_path("mix_release/start")

    test "writes .rel, .boot, and .script files" do
      release = release([])
      assert make_boot_script(release, @boot_script_path, release.boot_scripts.start) == :ok

      assert {:ok,
              [
                {:release, {~c"demo", ~c"0.1.0"}, {:erts, @erts_version},
                 [
                   {:kernel, _, :permanent},
                   {:stdlib, _, :permanent},
                   {:elixir, @elixir_version, :permanent},
                   {:sasl, _, :permanent},
                   {:mix, @elixir_version, :permanent},
                   {:iex, @elixir_version, :none},
                   {:compiler, _, :permanent}
                 ]}
              ]} = :file.consult(@boot_script_path <> ".rel")

      assert {:ok, [{:script, {~c"demo", ~c"0.1.0"}, instructions}]} =
               :file.consult(@boot_script_path <> ".script")

      assert {:path, [~c"$ROOT/lib/kernel-#{@kernel_version}/ebin"]} in instructions
      assert {:path, [~c"$RELEASE_LIB/elixir-#{@elixir_version}/ebin"]} in instructions

      assert File.read!(@boot_script_path <> ".boot") |> :erlang.binary_to_term() ==
               {:script, {~c"demo", ~c"0.1.0"}, instructions}
    end

    test "prepends relevant paths" do
      release = release([])

      assert make_boot_script(
               release,
               @boot_script_path,
               release.boot_scripts.start,
               ["$RELEASE_LIB/sample"]
             ) == :ok

      assert {:ok, [{:script, {~c"demo", ~c"0.1.0"}, instructions}]} =
               :file.consult(@boot_script_path <> ".script")

      assert {:path, [~c"$ROOT/lib/kernel-#{@kernel_version}/ebin"]} in instructions
      refute {:path, [~c"$RELEASE_LIB/elixir-#{@elixir_version}/ebin"]} in instructions

      assert {:path, [~c"$RELEASE_LIB/sample", ~c"$RELEASE_LIB/elixir-#{@elixir_version}/ebin"]} in instructions

      assert File.read!(@boot_script_path <> ".boot") |> :erlang.binary_to_term() ==
               {:script, {~c"demo", ~c"0.1.0"}, instructions}
    end

    test "works when :load/:none is set at the leaf" do
      release = release(applications: [mix: :none])
      assert make_boot_script(release, @boot_script_path, release.boot_scripts.start) == :ok
      {:ok, [{:release, _, _, rel_apps}]} = :file.consult(@boot_script_path <> ".rel")
      assert List.keyfind(rel_apps, :mix, 0) == {:mix, @elixir_version, :none}
    end

    test "works when :load/:none is set at the subtree" do
      release = release(applications: [mix: :load, elixir: :load, iex: :load])
      assert make_boot_script(release, @boot_script_path, release.boot_scripts.start) == :ok
      {:ok, [{:release, _, _, rel_apps}]} = :file.consult(@boot_script_path <> ".rel")
      assert {:elixir, _, :load} = List.keyfind(rel_apps, :elixir, 0)
      assert {:iex, _, :load} = List.keyfind(rel_apps, :iex, 0)
      assert {:mix, _, :load} = List.keyfind(rel_apps, :mix, 0)
    end

    test "raises on unknown app" do
      {:error, message} = make_boot_script(release([]), @boot_script_path, unknown: :permanent)
      assert message =~ "Unknown application :unknown"
    end

    test "raises on missing dependency" do
      {:error, message} = make_boot_script(release([]), @boot_script_path, elixir: :permanent)

      assert message =~
               "Application :elixir is listed in the release boot, but it depends on :kernel, which isn't"
    end

    test "raises on unknown mode" do
      {:error, message} = make_boot_script(release([]), @boot_script_path, mix: :what)
      assert message =~ "Unknown mode :what for :mix"
    end

    test "raises on bad load/none" do
      release = release(applications: [kernel: :load])
      {:error, message} = make_boot_script(release, @boot_script_path, release.boot_scripts.start)

      assert message =~
               "Application :stdlib has mode :permanent but it depends on :kernel which is set to :load"

      release = release(applications: [elixir: :none])
      {:error, message} = make_boot_script(release, @boot_script_path, release.boot_scripts.start)

      assert message =~
               "Application :mix has mode :permanent but it depends on :elixir which is set to :none"
    end

    test "does not raise on child unsafe mode if parent is in `skip_mode_validation_for`" do
      # `:mix` is a parent that depends on `:elixir`
      release = release(applications: [elixir: :load], skip_mode_validation_for: [:mix])
      assert make_boot_script(release, @boot_script_path, release.boot_scripts.start) == :ok
      assert make_boot_script(release, @boot_script_path, release.boot_scripts.start_clean) == :ok
    end
  end

  describe "make_cookie/1" do
    @cookie_path tmp_path("mix_release/cookie")

    test "creates a random cookie if no cookie" do
      assert make_cookie(release([]), @cookie_path) == :ok
      assert byte_size(File.read!(@cookie_path)) == 56
    end

    test "uses the given cookie" do
      release = release(cookie: "abcdefghijk")
      assert make_cookie(release, @cookie_path) == :ok
      assert File.read!(@cookie_path) == "abcdefghijk"
      assert make_cookie(release, @cookie_path) == :ok
    end

    test "asks to change if the cookie changes" do
      assert make_cookie(release(cookie: "abcdefghijk"), @cookie_path) == :ok

      send(self(), {:mix_shell_input, :yes?, false})
      assert make_cookie(release(cookie: "lmnopqrstuv"), @cookie_path) == :ok
      assert File.read!(@cookie_path) == "abcdefghijk"

      send(self(), {:mix_shell_input, :yes?, true})
      assert make_cookie(release(cookie: "lmnopqrstuv"), @cookie_path) == :ok
      assert File.read!(@cookie_path) == "lmnopqrstuv"
    end

    test "does not ask to change if set to overwrite" do
      assert make_cookie(release([]), @cookie_path) == :ok
      send(self(), {:mix_shell_input, :yes?, false})
      assert make_cookie(release([cookie: "lmnopqrstuv"], overwrite: true), @cookie_path) == :ok
      assert File.read!(@cookie_path) == "lmnopqrstuv"
    end
  end

  describe "make_start_erl/1" do
    @start_erl_path tmp_path("mix_release/start_erl.data")

    test "writes ERTS and release versions" do
      assert make_start_erl(release([]), @start_erl_path) == :ok
      assert File.read!(@start_erl_path) == "#{@erts_version} 0.1.0"
    end
  end

  describe "make_sys_config/1" do
    @sys_config tmp_path("mix_release/_build/dev/rel/demo/releases/0.1.0/sys.config")
    @providers [{Config.Reader, "/foo/bar/baz"}]

    test "writes the given sys_config" do
      assert make_sys_config(release([]), [foo: [bar: :baz]], "unused/runtime/path") == :ok
      contents = File.read!(@sys_config)
      assert contents =~ "%% RUNTIME_CONFIG=false"
      assert contents =~ "[{foo,[{bar,baz}]}]."
    end

    test "writes sys_config with encoding" do
      assert make_sys_config(
               release([]),
               [encoding: {:_μ, :"£", "£", ~c"£"}],
               "unused/runtime/path"
             ) ==
               :ok

      {:ok, contents} = :file.consult(@sys_config)
      assert contents == [[encoding: {:_μ, :"£", "£", ~c"£"}]]
    end

    test "writes the given sys_config with config providers" do
      release = release(config_providers: @providers, reboot_system_after_config: true)
      assert make_sys_config(release, [kernel: [key: :value]], "/foo/bar/bat") == :ok
      assert File.read!(@sys_config) =~ "%% RUNTIME_CONFIG=true"
      {:ok, [config]} = :file.consult(@sys_config)
      assert %Config.Provider{} = provider = config[:elixir][:config_provider_init]
      refute provider.prune_runtime_sys_config_after_boot
      assert provider.extra_config == [kernel: [start_distribution: true]]
      assert config[:kernel] == [key: :value, start_distribution: false]
    end

    test "writes the given sys_config without distribution and with pruning" do
      release =
        release(
          config_providers: @providers,
          reboot_system_after_config: true,
          start_distribution_during_config: true,
          prune_runtime_sys_config_after_boot: true
        )

      assert make_sys_config(release, [kernel: [key: :value]], "/foo/bar/bat") == :ok
      assert File.read!(@sys_config) =~ "%% RUNTIME_CONFIG=true"
      {:ok, [config]} = :file.consult(@sys_config)
      assert %Config.Provider{} = provider = config[:elixir][:config_provider_init]
      assert provider.reboot_system_after_config
      assert provider.prune_runtime_sys_config_after_boot
      assert provider.extra_config == []
      assert config[:kernel] == [key: :value]
    end

    test "writes the given sys_config without reboot" do
      release = release(config_providers: @providers, reboot_system_after_config: false)
      assert make_sys_config(release, [kernel: [key: :value]], "/foo/bar/bat") == :ok
      assert File.read!(@sys_config) =~ "%% RUNTIME_CONFIG=false"
      {:ok, [config]} = :file.consult(@sys_config)
      assert %Config.Provider{} = provider = config[:elixir][:config_provider_init]
      refute provider.reboot_system_after_config
      assert provider.extra_config == []
      assert config[:kernel] == [key: :value]
    end

    test "errors on bad config" do
      assert {:error, "Could not read configuration file." <> _} =
               make_sys_config(release([]), [foo: [bar: self()]], "unused/runtime/path")

      env = %{__ENV__ | lexical_tracker: self()}

      assert {:error, "Could not read configuration file." <> _} =
               make_sys_config(release([]), [foo: [bar: env]], "unused/runtime/path")
    end
  end

  describe "copy_erts/1" do
    test "copies to directory" do
      assert copy_erts(release(include_erts: true))
      destination = tmp_path("mix_release/_build/dev/rel/demo/erts-#{@erts_version}")
      assert File.exists?(destination)

      assert File.read!(Path.join(destination, "bin/erl")) =~
               ~s|ROOTDIR="${ERL_ROOTDIR:-"$(dirname "$(dirname "$BINDIR")")"}|

      if not match?({:win32, _}, :os.type()) do
        assert File.lstat!(Path.join(destination, "bin/erl")).mode |> rem(0o1000) == 0o755
      end

      refute File.exists?(Path.join(destination, "bin/erl.ini"))
      refute File.exists?(Path.join(destination, "doc"))

      # Now we copy from the copy using a string and without src
      new_destination = tmp_path("mix_release/_build/dev/rel/new_demo/erts-#{@erts_version}")
      File.rm_rf!(Path.join(destination, "src"))

      release = from_config!(nil, config(releases: [new_demo: [include_erts: destination]]), [])
      assert copy_erts(release)
      assert File.exists?(new_destination)
    end

    test "does not copy when include_erts is false" do
      refute copy_erts(release(include_erts: false))
      destination = tmp_path("mix_release/_build/dev/rel/demo/erts-#{@erts_version}")
      refute File.exists?(destination)
    end
  end

  describe "copy_ebin/3" do
    test "copies and strips beams" do
      assert copy_ebin(release([]), @eex_ebin, tmp_path("eex_ebin"))

      assert size!(Path.join(@eex_ebin, "Elixir.EEx.beam")) >
               size!(tmp_path("eex_ebin/Elixir.EEx.beam"))
    end

    test "copies without stripping beams" do
      assert copy_ebin(release(strip_beams: false), @eex_ebin, tmp_path("eex_ebin"))

      assert size!(Path.join(@eex_ebin, "Elixir.EEx.beam")) ==
               size!(tmp_path("eex_ebin/Elixir.EEx.beam"))
    end

    test "returns false for unknown or empty directories" do
      source = tmp_path("mix_release")
      refute copy_ebin(release([]), source, tmp_path("mix_release"))
      File.mkdir_p!(source)
      refute copy_ebin(release([]), source, tmp_path("mix_release"))
    end

    test "preserves file mode" do
      source = tmp_path("source_ebin")
      source_so_path = Path.join(source, "libtest_nif.so")

      File.mkdir_p!(source)
      File.touch!(source_so_path)
      File.chmod!(source_so_path, 0o755)

      assert copy_ebin(release([]), source, tmp_path("mix_release"))

      assert mode!(source_so_path) == mode!(tmp_path("mix_release/libtest_nif.so"))
    end
  end

  describe "copy_app/2" do
    @release_lib tmp_path("mix_release/_build/dev/rel/demo/lib")

    test "copies and strips beams" do
      assert copy_app(release(applications: [eex: :permanent]), :eex)

      assert size!(Path.join(@eex_ebin, "Elixir.EEx.beam")) >
               size!(Path.join(@release_lib, "eex-#{@elixir_version}/ebin/Elixir.EEx.beam"))
    end

    test "copies without stripping beams" do
      assert copy_app(release(strip_beams: false, applications: [eex: :permanent]), :eex)

      assert size!(Path.join(@eex_ebin, "Elixir.EEx.beam")) ==
               size!(Path.join(@release_lib, "eex-#{@elixir_version}/ebin/Elixir.EEx.beam"))
    end

    test "copies OTP apps" do
      release = release(applications: [runtime_tools: :permanent])
      assert copy_app(release, :runtime_tools)
      assert File.exists?(Path.join(@release_lib, "runtime_tools-#{@runtime_tools_version}/ebin"))
      assert File.exists?(Path.join(@release_lib, "runtime_tools-#{@runtime_tools_version}/priv"))
    end

    test "does not copy OTP app if include_erts is false" do
      release = release(include_erts: false, applications: [runtime_tools: :permanent])
      refute copy_app(release, :runtime_tools)
      refute File.exists?(Path.join(@release_lib, "runtime_tools-#{@runtime_tools_version}/ebin"))
      refute File.exists?(Path.join(@release_lib, "runtime_tools-#{@runtime_tools_version}/priv"))
    end
  end

  describe "strip_beam/1" do
    test "excludes at least docs and dbgi chunks" do
      {:ok, beam} =
        Path.join(@eex_ebin, "Elixir.EEx.beam")
        |> File.read!()
        |> strip_beam()

      assert {:error, :beam_lib, {:missing_chunk, _, ~c"Dbgi"}} =
               :beam_lib.chunks(beam, [~c"Dbgi"])

      assert {:error, :beam_lib, {:missing_chunk, _, ~c"Docs"}} =
               :beam_lib.chunks(beam, [~c"Docs"])
    end

    test "can keep docs and debug info, if requested" do
      {:ok, beam} =
        Path.join(@eex_ebin, "Elixir.EEx.beam")
        |> File.read!()
        |> strip_beam(keep: ["Docs", "Dbgi"])

      assert {:ok, {EEx, [{~c"Dbgi", _}]}} = :beam_lib.chunks(beam, [~c"Dbgi"])
      assert {:ok, {EEx, [{~c"Docs", _}]}} = :beam_lib.chunks(beam, [~c"Docs"])
    end

    test "strip beams without compression" do
      {:ok, beam} =
        Path.join(@eex_ebin, "Elixir.EEx.beam")
        |> File.read!()
        |> strip_beam(compress: false)

      assert match?(<<"FOR1", _::binary>>, beam)
    end
  end

  describe "included applications" do
    test "are included in the release", context do
      in_tmp(context.test, fn ->
        write_app!(
          "my_sample1/ebin/my_sample1.app",
          {:application, :my_sample1,
           applications: [:kernel, :stdlib, :elixir],
           description: ~c"my_sample1",
           modules: [],
           vsn: ~c"1.0.0",
           included_applications: [:runtime_tools]}
        )

        release = release(applications: [my_sample1: :permanent])
        assert release.boot_scripts.start[:runtime_tools] == :load

        release = release(applications: [my_sample1: :permanent, runtime_tools: :none])
        assert release.boot_scripts.start[:runtime_tools] == :none
      end)
    end

    test "raise on conflict", context do
      in_tmp(context.test, fn ->
        write_app!(
          "my_sample2/ebin/my_sample2.app",
          {:application, :my_sample2,
           applications: [:kernel, :stdlib, :elixir, :runtime_tools],
           description: ~c"my_sample",
           modules: [],
           vsn: ~c"1.0.0",
           included_applications: [:runtime_tools]}
        )

        assert_raise Mix.Error,
                     ":runtime_tools is listed both as a regular application and as an included application",
                     fn -> release(applications: [my_sample2: :permanent]) end
      end)
    end
  end

  describe "optional applications" do
    test "are ignored if not available", context do
      in_tmp(context.test, fn ->
        write_app!(
          "my_sample3/ebin/my_sample3.app",
          {:application, :my_sample3,
           applications: [:kernel, :stdlib, :elixir, :unknown],
           optional_applications: [:unknown],
           description: ~c"my_sample3",
           modules: [],
           vsn: ~c"1.0.0"}
        )

        release = release(applications: [my_sample3: :permanent])
        assert release.boot_scripts.start[:unknown] == nil
      end)
    end

    test "are ignored even if mode changes", context do
      in_tmp(context.test, fn ->
        write_app!(
          "has_optional/ebin/has_optional.app",
          {:application, :has_optional,
           applications: [:kernel, :stdlib, :elixir, :unknown],
           optional_applications: [:unknown],
           description: ~c"has_optional",
           modules: [],
           vsn: ~c"1.0.0"}
        )

        write_app!(
          "points_as_permanent/ebin/points_as_permanent.app",
          {:application, :points_as_permanent,
           applications: [:kernel, :stdlib, :elixir, :has_optional],
           optional_applications: [:unknown],
           description: ~c"points_as_permanent",
           modules: [],
           vsn: ~c"1.0.0"}
        )

        write_app!(
          "points_as_temporary/ebin/points_as_temporary.app",
          {:application, :points_as_temporary,
           applications: [:kernel, :stdlib, :elixir, :has_optional],
           optional_applications: [:unknown],
           description: ~c"points_as_temporary",
           modules: [],
           vsn: ~c"1.0.0"}
        )

        release =
          release(
            applications: [points_as_permanent: :permanent, points_as_temporary: :temporary]
          )

        assert release.boot_scripts.start[:has_optional] == :permanent
        assert release.boot_scripts.start[:unknown] == nil
      end)
    end
  end

  defp write_app!(path, app) do
    dir = Path.dirname(path)
    File.mkdir_p!(dir)
    Code.prepend_path(dir)
    format = :io_lib.format("%% coding: utf-8~n~p.~n", [app])
    File.write!(path, format)
  end

  defp size!(path) do
    File.stat!(path).size
  end

  defp mode!(path) do
    File.stat!(path).mode
  end

  defp release(config, overrides \\ []) do
    from_config!(nil, config(releases: [demo: config]), overrides)
  end

  defp config(extra \\ []) do
    [
      app: :mix,
      version: "0.1.0",
      build_path: tmp_path("mix_release/_build"),
      build_per_environment: true,
      config_path: tmp_path("mix_release/config/config.exs")
    ]
    |> Keyword.merge(extra)
  end

  defmodule ReleaseApp do
    def project do
      [
        app: :mix,
        version: "0.1.0",
        build_path: tmp_path("mix_release/_build"),
        build_per_environment: true,
        config_path: tmp_path("mix_release/config/config.exs")
      ]
      |> Keyword.merge(Process.get(:project))
    end
  end
end
