defmodule Foxbus.Config do
  @moduledoc """
  Runtime-editable overrides for the route and stops, kept in
  `NestGen2.Storage` so they survive a restart without a recompile+redeploy
  — mix.exs' own `env` only takes effect on the next one, too slow while
  testing against a different route.

  Set from your computer (`platform/storage.sh foxbus put stops '[...]'`,
  and `lines`, `default_screen` the same way) or, once there's a settings
  screen for it, from the device itself. Any key not set in Storage, or
  with no value at all yet, falls back to mix.exs' compiled `env`.
  `default_screen` has no mix.exs fallback — it's `:splash` when unset,
  matching foxbus's original behaviour.

      stops: [
        {:towards_somewhere, "000000000001", "To Somewhere"},
        {:towards_elsewhere, "000000000002", "To Elsewhere"}
      ]
      lines: ["104"]
      default_screen: :towards_somewhere

  Before nest_gen2 0.3.0 these came from a hand-rolled file, `config.exs`
  next to the other device assets. `migrate_from_file/0`, called once at
  start (see `Foxbus.Application`), carries an existing install's values
  over into Storage without anything done by hand, then leaves the old
  file alone — it only migrates a key Storage doesn't already have, so
  it's safe to call on every boot.

  `lines` is a list, not a single line, on purpose: a stop can be served by
  more than one route, and `Foxbus.Arrivals` filters the scraped board down
  to just these lines — listing several here shows all of them, interleaved
  by time, rather than just the one route the board happens to mention
  first.
  """

  alias NestGen2.Storage

  @spec stops() :: [{atom, String.t(), String.t()}]
  def stops, do: get(:stops, Application.fetch_env!(:foxbus, :stops))

  @spec lines() :: [String.t()]
  def lines, do: get(:lines, Application.fetch_env!(:foxbus, :lines))

  @spec default_screen() :: atom
  def default_screen, do: get(:default_screen, :splash)

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
