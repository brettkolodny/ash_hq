defmodule AshHq.Docs.Importer do
  @moduledoc """
  Builds the documentation into term files in the `priv/docs` directory.
  """

  use GenServer

  alias AshHq.Docs.LibraryVersion
  require Logger
  require Ash.Query

  def start_link(_) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def init(_) do
    send(self(), :import)
    {:ok, %{}}
  end

  defp import_periodically() do
    __MODULE__.import()
    Process.send_after(self(), :import, :timer.minutes(30))
  end

  def handle_info(:import, state) do
    import_periodically()
    {:noreply, state}
  end

  # sobelow_skip ["Misc.BinToTerm", "Traversal.FileModule"]
  def import(opts \\ []) do
    only = opts[:only] || nil

    query =
      if only do
        AshHq.Docs.Library |> Ash.Query.filter(name in ^List.wrap(only))
      else
        AshHq.Docs.Library
      end

    path_var =
      "PATH"
      |> System.get_env()
      |> String.split(":")
      |> Enum.reject(&String.starts_with?(&1, "/_build"))
      |> Enum.join(":")

    for %{name: name, latest_version: latest_version} = library <-
          AshHq.Docs.Library.read!(load: :latest_version, query: query) do
      latest_version =
        if latest_version do
          Version.parse!(latest_version)
        end

      versions =
        Finch.build(:get, "https://hex.pm/api/packages/#{name}")
        |> Finch.request(AshHq.Finch)
        |> case do
          {:ok, response} ->
            Jason.decode!(response.body)

          {:error, error} ->
            raise "Something went wrong #{inspect(error)}"
        end
        |> Map.get("releases", [])
        |> Enum.map(&Map.get(&1, "version"))
        |> filter_by_version(latest_version)
        |> Enum.reverse()

      already_defined_versions =
        AshHq.Docs.LibraryVersion.defined_for!(
          library.id,
          versions
        )

      versions
      |> Enum.reject(fn version ->
        Enum.find(already_defined_versions, &(&1.version == version))
      end)
      |> Enum.each(fn version ->
        file = Path.expand("./#{Ash.UUID.generate()}.json")

        result =
          try do
            with_retry(fn ->
              {_, 0} =
                System.cmd(
                  "elixir",
                  [
                    Path.join([:code.priv_dir(:ash_hq), "scripts", "build_dsl_docs.exs"]),
                    name,
                    version,
                    file
                  ],
                  env: %{"PATH" => path_var}
                )

              output = File.read!(file)
              :erlang.binary_to_term(Base.decode64!(String.trim(output)))
            end)
          after
            File.rm_rf!(file)
          end

        if result do
          AshHq.Repo.transaction(fn ->
            id =
              case LibraryVersion.by_version(library.id, version) do
                {:ok, version} ->
                  LibraryVersion.destroy!(version)
                  version.id

                _ ->
                  Ash.UUID.generate()
              end

            LibraryVersion.build!(
              library.id,
              version,
              %{
                timeout: :infinity,
                id: id,
                extensions: result[:extensions],
                doc: result[:doc],
                guides: add_text(result[:guides], library.name, version),
                modules: result[:modules],
                mix_tasks: result[:mix_tasks]
              }
            )
          end)
        end
      end)
    end
  end

  # sobelow_skip ["Misc.BinToTerm", "Traversal.FileModule"]
  defp add_text([], _, _), do: []

  # sobelow_skip ["Misc.BinToTerm", "Traversal.FileModule"]
  defp add_text(guides, name, version) do
    path = Path.expand("tmp")
    tarball_path = Path.expand(Path.join(["tmp", "tarballs"]))
    tar_path = Path.join(tarball_path, "#{name}-#{version}.tar")
    untar_path = Path.join(path, "#{name}-#{version}")
    contents_untar_path = Path.join(path, "#{name}-#{version}/contents")
    contents_tar_path = Path.join([path, "#{name}-#{version}", "contents.tar.gz"])

    try do
      File.rm_rf!(tar_path)
      File.rm_rf!(contents_untar_path)
      File.mkdir_p!(untar_path)
      File.mkdir_p!(contents_untar_path)

      {_, 0} =
        System.cmd(
          "curl",
          [
            "-L",
            "--create-dirs",
            "-o",
            "#{tar_path}",
            "https://repo.hex.pm/tarballs/#{name}-#{version}.tar"
          ]
        )

      {_, 0} =
        System.cmd(
          "tar",
          [
            "-xf",
            tar_path,
            "-C",
            untar_path
          ],
          cd: "tmp"
        )

      {_, 0} =
        System.cmd(
          "tar",
          [
            "-xzf",
            contents_tar_path
          ],
          cd: contents_untar_path
        )

      Enum.map(guides, fn %{path: path} = guide ->
        contents =
          contents_untar_path
          |> Path.join(path)
          |> File.read!()

        Map.put(guide, :text, contents)
      end)
    after
      File.rm_rf!(tar_path)
      File.rm_rf!(untar_path)
    end
  end

  defp with_retry(func, retries \\ 3) do
    func.()
  rescue
    e ->
      if retries == 1 do
        reraise e, __STACKTRACE__
      else
        with_retry(func, retries - 1)
      end
  end

  defp filter_by_version(versions, latest_version) do
    if latest_version do
      Enum.take_while(versions, fn version ->
        Version.match?(Version.parse!(version), "> #{latest_version}")
      end)
    else
      Enum.take(versions, 1)
    end
  end
end
