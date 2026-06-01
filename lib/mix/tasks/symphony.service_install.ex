defmodule Mix.Tasks.Symphony.ServiceInstall do
  use Mix.Task

  alias Symphony1.RuntimeConfig
  alias Symphony1.Service.Launchd

  @shortdoc "Generate and install a launchd plist for mix symphony.operate"

  @label "com.symphony1.operate"
  @default_repo_local_dir "tmp/service"
  @default_launch_agents_dir Path.expand("~/Library/LaunchAgents")

  @impl true
  def run(args) do
    {opts, _positional, _invalid} =
      OptionParser.parse(args,
        strict: [graph: :string, team_key: :string, acknowledge_plaintext_secret_policy: :boolean]
      )

    graph_path =
      case Keyword.get(opts, :graph) do
        nil -> Mix.raise("usage: mix symphony.service_install --graph PATH --team-key KEY")
        path -> Path.expand(path)
      end

    team_key =
      case Keyword.get(opts, :team_key) do
        nil -> Mix.raise("usage: mix symphony.service_install --graph PATH --team-key KEY")
        key -> key
      end

    api_key =
      case RuntimeConfig.linear_api_key() do
        {:ok, key} ->
          key

        {:error, :missing_linear_api_key} ->
          Mix.raise(RuntimeConfig.missing_linear_api_key_message())
      end

    config = override_config()

    mix_resolver = Map.get(config, :mix_resolver, &System.find_executable/1)

    mix_path =
      case mix_resolver.("mix") do
        nil -> Mix.raise("could not resolve absolute path to mix")
        path -> path
      end

    working_directory = Map.get(config, :working_directory, File.cwd!())
    repo_local_dir = Map.get(config, :repo_local_dir, @default_repo_local_dir)
    launch_agents_dir = Map.get(config, :launch_agents_dir, @default_launch_agents_dir)
    file_writer = Map.get(config, :file_writer, &File.write/2)
    file_copier = Map.get(config, :file_copier, &File.cp/2)

    plist_config = %{
      label: @label,
      mix_path: mix_path,
      graph_path: graph_path,
      team_key: team_key,
      working_directory: working_directory,
      stdout_log: Path.join(working_directory, "log/operate.stdout.log"),
      stderr_log: Path.join(working_directory, "log/operate.stderr.log"),
      env: %{
        "LINEAR_API_KEY" => api_key,
        "PATH" => System.get_env("PATH") || "/usr/bin:/bin"
      }
    }

    plist_content = Launchd.generate_plist(plist_config)
    repo_local_path = Path.join(repo_local_dir, "#{@label}.plist")
    install_path = Path.join(launch_agents_dir, "#{@label}.plist")

    policy_context = %{
      repo_local_path: repo_local_path,
      install_path: install_path
    }

    print_policy_notice(policy_context)
    acknowledge_policy!(opts, config, policy_context)

    File.mkdir_p!(repo_local_dir)

    case file_writer.(repo_local_path, plist_content) do
      :ok ->
        Mix.shell().info("service_install: wrote #{repo_local_path}")

      {:error, reason} ->
        Mix.raise("service_install: failed to write repo-local plist: #{inspect(reason)}")
    end

    File.mkdir_p!(launch_agents_dir)

    case file_copier.(repo_local_path, install_path) do
      :ok ->
        Mix.shell().info("service_install: installed #{install_path}")

      {:error, reason} ->
        Mix.raise("service_install: failed to install plist to LaunchAgents: #{inspect(reason)}")
    end

    Mix.shell().info("service_install: next step — run mix symphony.service_start")
  end

  defp override_config do
    Application.get_env(:symphony_1, :service_install_config, %{})
  end

  defp print_policy_notice(%{repo_local_path: repo_local_path, install_path: install_path}) do
    Mix.shell().info(
      "service_install: security policy — continuing will store LINEAR_API_KEY in plaintext in both #{repo_local_path} and #{install_path}"
    )

    Mix.shell().info("service_install: use launchd only on a trusted single-user Mac you control")

    Mix.shell().info(
      "service_install: if that trade-off is unacceptable, do not continue this install; if you previously installed the service, remove both plaintext plist copies (#{repo_local_path} and #{install_path}) and run mix symphony.operate in the foreground instead"
    )

    Mix.shell().info(
      "service_install: non-interactive installs must pass --acknowledge-plaintext-secret-policy"
    )
  end

  defp acknowledge_policy!(opts, config, policy_context) do
    if Keyword.get(opts, :acknowledge_plaintext_secret_policy, false) do
      Mix.shell().info(
        "service_install: plaintext-secret policy acknowledged via --acknowledge-plaintext-secret-policy"
      )

      :ok
    else
      policy_acknowledger =
        Map.get(config, :policy_acknowledger, &interactive_policy_acknowledger/1)

      case policy_acknowledger.(policy_context) do
        :ok ->
          :ok

        {:error, :policy_declined} ->
          Mix.raise(
            "service_install: plaintext-secret policy was not accepted; no plaintext plist files were written"
          )

        {:error, :non_interactive} ->
          Mix.raise(
            "service_install: plaintext-secret policy acknowledgement is required before install; rerun with --acknowledge-plaintext-secret-policy for a non-interactive install"
          )

        {:error, reason} ->
          Mix.raise(
            "service_install: plaintext-secret policy was not accepted: #{inspect(reason)}"
          )
      end
    end
  end

  defp interactive_policy_acknowledger(%{
         repo_local_path: repo_local_path,
         install_path: install_path
       }) do
    case IO.gets("""
         service_install: type INSTALL to accept the plaintext-secret policy for:
         service_install:   #{repo_local_path}
         service_install:   #{install_path}
         service_install: > \
         """) do
      nil ->
        {:error, :non_interactive}

      response ->
        if String.trim(response) == "INSTALL" do
          :ok
        else
          {:error, :policy_declined}
        end
    end
  end
end
