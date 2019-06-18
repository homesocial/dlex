defmodule Dlex.Repo do
  @moduledoc """
  Ecto-like repository, which allows to embed the schema

    defmodule Repo do
      use Dlex.Repo, otp_app: :my_app, modules: [User]
    end

    config :my_app, Repo,
      hostname: "localhost",
      port: 3306
  """
  alias Dlex.{Repo.Meta, Utils}

  @doc """

  """
  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts], location: :keep do
      @name opts[:name] || __MODULE__
      @meta_name :"#{@name}.Meta"
      @otp_app opts[:otp_app]
      @modules opts[:modules] || []

      def child_spec(opts) do
        %{
          id: __MODULE__,
          start: {__MODULE__, :start_link, [opts]},
          type: :supervisor
        }
      end

      def start_link(opts \\ []) do
        start_opts = %{
          module: __MODULE__,
          otp_app: @otp_app,
          name: @name,
          meta_name: @meta_name,
          modules: @modules,
          opts: opts
        }

        Dlex.Repo.Sup.start_link(start_opts)
      end

      def set(node), do: Dlex.Repo.set(@name, node)
      def set!(node), do: Dlex.Repo.set!(@name, node)

      def mutate(node), do: Dlex.Repo.mutate(@name, node)
      def mutate!(node), do: Dlex.Repo.mutate!(@name, node)

      def get(uid), do: Dlex.Repo.get(@name, meta(), uid)
      def get!(uid), do: Dlex.Repo.get!(@name, meta(), uid)

      def meta(), do: Dlex.Repo.Meta.get(@meta_name)
      def register(modules), do: Dlex.Repo.Meta.register(@meta_name, modules)
      def snapshot(), do: Dlex.Repo.snapshot(@meta_name)
      def alter_schema(snapshot \\ snapshot()), do: Dlex.Repo.alter_schema(@name, snapshot)

      def stop(timeout \\ 5000), do: Supervisor.stop(@name, :normal, timeout)
    end
  end

  def child_spec(%{module: module, otp_app: otp_app, name: name, opts: opts}) do
    opts = Keyword.merge(opts, Application.get_env(otp_app, module, []))
    Dlex.child_spec([{:name, name} | opts])
  end

  @doc """
  Build or update lookup map from module list
  """
  def build_lookup_map(lookup_map \\ %{}, modules) do
    for module <- List.wrap(modules), reduce: lookup_map do
      acc ->
        case source(module) do
          nil -> acc
          source -> Map.put(acc, source, module)
        end
    end
  end

  @doc """
  The same as `mutate!`.
  """
  def set!(conn, data), do: mutate!(conn, data)

  @doc """
  The same as `mutate`.
  """
  def set(conn, data), do: mutate(conn, data)

  @doc """
  The same as `mutate/2`, but return result of sucessful operation or raises.
  """
  def mutate!(conn, data) do
    case mutate(conn, data) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end

  @doc """
  Mutate data
  """
  def mutate(conn, %{__struct__: Ecto.Changeset, changes: changes, data: %type{uid: uid}}) do
    data = struct(type, Map.put(changes, :uid, uid))
    set(conn, data)
  end

  def mutate(conn, data) do
    data_with_ids = Utils.add_blank_ids(data, :uid)

    with {:ok, ids_map} <- Dlex.set(conn, encode(data_with_ids)) do
      {:ok, Utils.replace_ids(data_with_ids, ids_map, :uid)}
    end
  end

  def encode(%{__struct__: struct} = data) do
    data
    |> Map.from_struct()
    |> Enum.flat_map(&encode_kv(&1, struct))
    |> Map.new()
  end

  def encode(data) when is_list(data), do: Enum.map(data, &encode/1)
  def encode(data), do: data

  defp encode_kv({_key, nil}, _), do: []

  defp encode_kv({:uid, value}, struct), do: [{"uid", value}, {source(struct), "true"}]

  defp encode_kv({key, value}, struct) do
    case field(struct, key) do
      nil -> []
      string_key -> [{string_key, encode(value)}]
    end
  end

  @compile {:inline, field: 2}
  def field(_struct, "uid"), do: {:uid, :string}
  def field(struct, key), do: struct.__schema__(:field, key)
  @compile {:inline, source: 1}
  def source(struct), do: struct.__schema__(:source)

  @doc """
  The same as `get/3`, but return result or raises.
  """
  def get!(conn, meta, uid) do
    case get(conn, meta, uid) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end

  @doc """
  Get by uid
  """
  def get(conn, %{lookup: lookup}, uid) do
    statement = ["{uid_get(func: uid(", uid, ")) {uid expand(_all_)}}"]

    with {:ok, %{"uid_get" => nodes}} <- Dlex.query(conn, statement) do
      case nodes do
        [%{"uid" => _} = map] when map_size(map) <= 2 -> {:ok, nil}
        [map] -> decode(map, lookup)
      end
    end
  end

  defp decode(map, lookup) when is_map(map) and is_map(lookup) do
    case Enum.find(map, fn {key, _} -> String.starts_with?(key, "type.") end) do
      nil -> {:error, {:untyped, map}}
      {type, _} -> decode(map, Map.get(lookup, type))
    end
  end

  defp decode(map, nil), do: {:error, {:untyped, map}}

  defp decode(map, type) do
    case decode_map(map, type) do
      %_{} = struct -> {:ok, struct}
      {:error, error} -> {:error, error}
      error -> {:error, error}
    end
  end

  defp decode_map(map, type) do
    Enum.reduce_while(map, type.__struct__(), fn {key, value}, struct ->
      case field(type, key) do
        {field_name, field_type} ->
          case Ecto.Type.cast(field_type, value) do
            {:ok, casted_value} -> {:cont, Map.put(struct, field_name, casted_value)}
            error -> {:halt, error}
          end

        nil ->
          {:cont, struct}
      end
    end)
  end

  def get_by(conn, field, name) do
    statement = "query all($a: string) {all(func: eq(#{field}, $a)) {uid expand(_all_)}}"
    with %{"all" => [obj]} <- Dlex.query!(conn, statement, %{"$a" => name}), do: obj
  end

  @doc """
  Alter schema for modules
  """
  def alter_schema(conn, snapshot) do
    with {:ok, %{"schema" => schema}} <- Dlex.query_schema(conn),
         do: do_alter_schema(conn, schema, snapshot)
  end

  defp do_alter_schema(conn, schema, snapshot) do
    case snapshot -- schema do
      [] -> {:ok, 0}
      alter -> with {:ok, _} <- Dlex.alter(conn, %{schema: alter}), do: {:ok, length(alter)}
    end
  end

  @doc """
  Generate snapshot for running meta process
  """
  def snapshot(meta) do
    %{modules: modules} = Meta.get(meta)

    modules
    |> MapSet.to_list()
    |> List.wrap()
    |> expand_modules()
    |> Enum.flat_map(& &1.__schema__(:alter))
  end

  defp expand_modules(modules) do
    Enum.reduce(modules, modules, fn module, modules ->
      depends_on_modules = module.__schema__(:depends_on)
      Enum.reduce(depends_on_modules, modules, &if(Enum.member?(&2, &1), do: &2, else: [&1 | &2]))
    end)
  end
end