defmodule Foxbus.Config do
  @moduledoc """
  Runtime-editable overrides for the watched stops, kept in
  `NestGen2.Storage` so they survive a restart without a recompile+redeploy
  — mix.exs' own `env` only takes effect on the next one, too slow while
  testing against a different stop.

  Set from your computer (`platform/storage.sh foxbus put stops '[...]'`,
  `default_screen` the same way) or, once there's a settings screen for it,
  from the device itself. Any key not set in Storage, or with no value at
  all yet, falls back to mix.exs' compiled `env`. `default_screen` has no
  mix.exs fallback — it's `:splash` when unset, matching foxbus's original
  behaviour.

  Each stop now names its own provider and watched lines (previously one
  global `lines` list shared by every stop — a shared stop served by
  different providers, or wanting a different line filter, couldn't be
  expressed):

      stops: [
        %{
          key: :towards_somewhere,
          provider: :carousel,
          stop_id: "000000000001",
          title: "To Somewhere",
          lines: ["104"]
        }
      ]
      default_screen: :towards_somewhere

  `provider` is a `Foxbus.Ports.Provider` id — see `Foxbus.Ports.Provider.all/0`
  for what's available. `lines` is a list, not a single line, on purpose: a
  stop can be served by more than one route, and `Foxbus.Arrivals` filters
  the fetched board down to just these — listing several here shows all of
  them, interleaved by time; an empty list means no filtering at all.

  Before nest_gen2 0.3.0 these came from a hand-rolled file, `config.exs`
  next to the other device assets. `migrate_from_file/0`, called once at
  start (see `Foxbus.Application`), carries an existing install's values
  over into Storage without anything done by hand, then leaves the old
  file alone — it only migrates a key Storage doesn't already have, so
  it's safe to call on every boot.

  `migrate_legacy_stops/0`, also called once at start, carries Storage's
  own older `stops` shape (a flat `{key, stop_id, title}` tuple, paired
  with one global `lines` list) into the shape above — every migrated stop
  gets `provider: :carousel` (the only provider that existed before this)
  and the old global `lines` value copied onto it. A no-op once `stops` is
  already the new shape.
  """

  alias NestGen2.Storage

  @type stop :: %{
          key: atom,
          provider: atom,
          stop_id: String.t(),
          title: String.t(),
          lines: [String.t()]
        }

  @spec stops() :: [stop]
  def stops, do: get(:stops, Application.fetch_env!(:foxbus, :stops))

  @spec default_screen() :: atom
  def default_screen, do: get(:default_screen, :splash)

  @doc "The old global lines list — migration-only, see `migrate_legacy_stops/0`."
  @spec lines() :: [String.t()]
  def lines, do: get(:lines, Application.get_env(:foxbus, :lines, []))

  defp get(key, default), do: Storage.get(key, default, app: :foxbus)

  @doc """
  One-time migration from the pre-0.3.0 `config.exs` file into Storage. A
  no-op for any key Storage already has a value for, so it's safe to call
  on every boot; the old file, if any, is left untouched either way.
  """
  @spec migrate_from_file() :: :ok
  def migrate_from_file do
    case read_old_file() do
      {:ok, term} ->
        migrate_key(:stops, Keyword.get(term, :stops))
        migrate_key(:lines, Keyword.get(term, :lines))
        migrate_key(:default_screen, Keyword.get(term, :default_screen))
        :ok

      :error ->
        :ok
    end
  end

  @doc """
  One-time migration from the old flat `{key, stop_id, title}` stops shape
  into the current per-stop map shape (see this module's moduledoc). A
  no-op once `:stops` is already the new shape, or isn't a list of plain
  3-tuples at all, so it's safe to call on every boot.
  """
  @spec migrate_legacy_stops() :: :ok
  def migrate_legacy_stops do
    case Storage.get(:stops, nil, app: :foxbus) do
      [{_key, _stop_id, _title} | _] = legacy ->
        shared_lines = lines()

        migrated =
          Enum.map(legacy, fn {key, stop_id, title} ->
            %{key: key, provider: :carousel, stop_id: stop_id, title: title, lines: shared_lines}
          end)

        Storage.put(:stops, migrated, app: :foxbus)
        :ok

      _ ->
        :ok
    end
  end

  defp migrate_key(_key, nil), do: :ok

  defp migrate_key(key, value) do
    if Storage.get(key, nil, app: :foxbus) == nil do
      Storage.put(key, value, app: :foxbus)
    end

    :ok
  end

  defp read_old_file do
    path = old_path()

    with true <- File.exists?(path),
         {term, _bindings} <- Code.eval_file(path),
         true <- Keyword.keyword?(term) do
      {:ok, term}
    else
      _ -> :error
    end
  rescue
    # A hand-edited config.exs with a typo shouldn't be able to stop the
    # app from booting at all.
    _ -> :error
  end

  defp old_path do
    Application.get_env(:foxbus, :config_path) ||
      Path.join(Application.get_env(:foxbus, :assets_dir, "."), "config.exs")
  end
end
