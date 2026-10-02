defmodule Foxbus.Config do
  @moduledoc """
  Runtime-editable overrides for the route and stops, read from a plain .exs
  file on disk — by default `config.exs` next to the other device assets
  (`assets_dir`). mix.exs' own `env` only takes effect on the next
  recompile+redeploy, which is too slow while testing against a different
  route; editing this file and restarting the app is enough.

  The file, if present, is a single keyword list evaluated with
  `Code.eval_file/1` — the same trust level as mix.exs itself, since this is
  local device config, not user input:

      [
        disruptions_line: "104",
        default_screen: :towards_uxbridge,
        stops: [
          {:towards_uxbridge, "040000001207", "To Uxbridge"},
          {:towards_wycombe, "040000001208", "To High Wycombe"}
        ]
      ]

  Any key it doesn't set, or the file not existing at all, falls back to
  mix.exs' compiled env. `default_screen` has no mix.exs fallback — it's
  `:splash` when unset, matching foxbus's original behaviour.
  """

  @spec stops() :: [{atom, String.t(), String.t()}]
  def stops, do: get(:stops)

  @spec disruptions_line() :: String.t()
  def disruptions_line, do: get(:disruptions_line)

  @spec default_screen() :: atom
  def default_screen, do: Keyword.get(overrides(), :default_screen, :splash)

  defp get(key),
    do: Keyword.get_lazy(overrides(), key, fn -> Application.fetch_env!(:foxbus, key) end)

  defp overrides do
    path = Application.get_env(:foxbus, :config_path) || default_path()

    with true <- File.exists?(path),
         {term, _bindings} <- Code.eval_file(path),
         true <- Keyword.keyword?(term) do
      term
    else
      _ -> []
    end
  rescue
    # A hand-edited config.exs with a typo shouldn't be able to stop the app
    # from booting at all — fall back to mix.exs' env instead.
    _ -> []
  end

  defp default_path do
    Path.join(Application.get_env(:foxbus, :assets_dir, "."), "config.exs")
  end
end
