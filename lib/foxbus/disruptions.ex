defmodule Foxbus.Disruptions do
  @moduledoc """
  Application service: checks, for one stop, whether any of the configured
  lines has an active notice that applies to that stop, via the configured
  source, and hands the notice's own text (or nil) to the configured sink.
  Nothing else knows which adapters are wired in.
  """

  @spec check([String.t()], String.t()) :: {:ok, String.t() | nil} | {:error, term}
  def check(lines, atco_code), do: source().disrupted?(lines, atco_code)

  @doc "Checks and publishes; returns what was found so the poller can log it."
  @spec check_and_publish(atom, [String.t()], String.t()) ::
          {:ok, String.t() | nil} | {:error, term}
  def check_and_publish(stop, lines, atco_code) do
    with {:ok, explanation} <- check(lines, atco_code),
         :ok <- sink().publish_disruption(stop, explanation) do
      {:ok, explanation}
    end
  end

  defp source, do: Application.fetch_env!(:foxbus, :disruptions_source)
  defp sink, do: Application.fetch_env!(:foxbus, :disruptions_sink)
end
