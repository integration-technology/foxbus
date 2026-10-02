defmodule Foxbus.Disruptions do
  @moduledoc """
  Application service: checks whether any of the configured lines has an
  active notice via the configured source, and hands the notice's own text
  (or nil) to the configured sink. Nothing else knows which adapters are
  wired in.
  """

  @spec check([String.t()]) :: {:ok, String.t() | nil} | {:error, term}
  def check(lines), do: source().disrupted?(lines)

  @doc "Checks and publishes; returns what was found so the poller can log it."
  @spec check_and_publish([String.t()]) :: {:ok, String.t() | nil} | {:error, term}
  def check_and_publish(lines) do
    with {:ok, explanation} <- check(lines),
         :ok <- sink().publish(explanation) do
      {:ok, explanation}
    end
  end

  defp source, do: Application.fetch_env!(:foxbus, :disruptions_source)
  defp sink, do: Application.fetch_env!(:foxbus, :disruptions_sink)
end
